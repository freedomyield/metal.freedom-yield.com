#!/usr/bin/env bash
# gen-anchor-source.sh v1.0 — compose /api/anchor-source.json from live sources.
#
# Companion:
#   schema:  public/api/anchor-source.schema.v1.json
#   example: public/api/anchor-source.example.json
#   docs:    docs/ANCHOR_SOURCE.md
#
# Verb discipline: this script produces observation-only records.
# Obligation verbs (_target, _promised, _committed, _sla, _cadence, etc.)
# are grep-rejected before write. See project_merkle_dag_identity_anchor_design_20260701 memo.
#
# Exit codes:
#   0  success (= anchor-source.json written + schema-validated + verb-checked)
#   2  bad arg / usage error
#   3  required input file missing (= validator.json / identity.json / etc.)
#   4  P-chain RPC failed or NodeID not present in current validators
#   5  obligation verb detected in output (= verb discipline violation)
#   6  schema validation failed (= output does not conform to v1)
#   7  atomic write failed

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_VERSION="1.0"

# ---- config (env overridable) -----------------------------------------
NODE_ID="${NODE_ID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
METALGO_API="${METALGO_API:-http://127.0.0.1:9650}"
STATE_DIR="${ANOMALY_STATE_DIR:-/var/lib/freedom-yield}"

# The public API base URL is authoritative for artifacts hashing (= hash what
# the third-party evaluator would fetch, not what a stale local checkout has).
# Local file fallback exists for offline dev + fully-air-gapped rehearsal.
API_BASE_URL="${API_BASE_URL:-https://metal.freedom-yield.com/api}"

VALIDATOR_JSON="${VALIDATOR_JSON:-${ROOT}/public/api/validator.json}"
IDENTITY_JSON="${IDENTITY_JSON:-${ROOT}/public/api/identity.json}"
IDENTITY_HISTORY_JSONL="${IDENTITY_HISTORY_JSONL:-${ROOT}/public/api/identity-history.jsonl}"
ANCHOR_HISTORY_JSONL="${ANCHOR_HISTORY_JSONL:-${ROOT}/public/api/anchor-history.jsonl}"
CYCLE_HISTORY_JSONL="${CYCLE_HISTORY_JSONL:-${ROOT}/public/api/cycle-history.jsonl}"
UPTIME_HISTORY_JSONL="${UPTIME_HISTORY_JSONL:-${STATE_DIR}/uptime-history.jsonl}"
DELEGATOR_EVENTS_JSONL="${DELEGATOR_EVENTS_JSONL:-${STATE_DIR}/delegator-events.jsonl}"
ANOMALIES_LOG="${ANOMALIES_LOG:-/var/log/anomalies.log}"

OUT_FILE="${OUT_FILE:-${ROOT}/public/api/anchor-source.json}"
SCHEMA_FILE="${SCHEMA_FILE:-${ROOT}/public/api/anchor-source.schema.v1.json}"

DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		--out=*)   OUT_FILE="${arg#--out=}" ;;
		-h|--help)
			sed -n '2,20p' "$0" | sed 's/^# \?//'
			exit 0
			;;
		*) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
	esac
done

# ---- portability shims ------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
	SHA256_CMD=(sha256sum)
else
	SHA256_CMD=(shasum -a 256)
fi

if date --version >/dev/null 2>&1; then
	# GNU (Linux)
	iso_utc_of_epoch() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }
else
	# BSD (macOS)
	iso_utc_of_epoch() { date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ"; }
fi

# ---- helpers ----------------------------------------------------------
sha256_file() {
	local f="$1"
	if [ ! -r "$f" ]; then
		echo "ERROR: cannot read file for sha256: $f" >&2
		exit 3
	fi
	"${SHA256_CMD[@]}" "$f" | awk '{print $1}'
}

sha256_str() {
	printf '%s' "$1" | "${SHA256_CMD[@]}" | awk '{print $1}'
}

# Merkle root over hex leaves:
#   - leaves already in canonical order (= caller sorted)
#   - binary tree, internal node = sha256(left_hex || right_hex)
#   - odd count: last leaf duplicated (Bitcoin conv)
#   - single leaf: root = that leaf
merkle_root() {
	local -a leaves=("$@")
	local n="${#leaves[@]}"
	if [ "$n" -eq 0 ]; then
		echo "ERROR: merkle_root called with 0 leaves" >&2
		exit 3
	fi
	while [ "$n" -gt 1 ]; do
		if [ $((n % 2)) -eq 1 ]; then
			leaves+=("${leaves[$((n-1))]}")
			n=$((n + 1))
		fi
		local -a next=()
		local i
		for ((i=0; i<n; i+=2)); do
			next+=("$(sha256_str "${leaves[i]}${leaves[i+1]}")")
		done
		leaves=("${next[@]}")
		n="${#leaves[@]}"
	done
	printf '%s' "${leaves[0]}"
}

require_cmd() {
	for c in "$@"; do
		if ! command -v "$c" >/dev/null 2>&1; then
			echo "ERROR: required command not found: $c" >&2
			exit 2
		fi
	done
}

require_cmd jq curl awk grep

# Fetch each API file from the public URL first (= authoritative for what the
# third-party evaluator sees). Fall back to local repo file if URL unreachable.
fetch_api_file() {
	local rel="$1"
	local dst="$2"
	local url="${API_BASE_URL}/${rel}"
	if curl -sSf --max-time 15 "$url" -o "$dst" 2>/dev/null; then
		return 0
	fi
	local local_path="${ROOT}/public/api/${rel}"
	if [ -r "$local_path" ]; then
		cp "$local_path" "$dst"
		echo "WARN: $rel fetched from local repo (public URL unreachable): $url" >&2
		return 0
	fi
	return 1
}

# ---- computed_at + git commit ----------------------------------------
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT="$(cd "$ROOT" && git rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")"

# ---- identity_branch -------------------------------------------------
PLACEHOLDER_HASH="0000000000000000000000000000000000000000000000000000000000000000"

if [ -r "$IDENTITY_JSON" ]; then
	OPERATOR_PUBKEY_HEX="$(jq -r --arg d "$PLACEHOLDER_HASH" '.operator_ed25519_pubkey_sha256_hex // $d' "$IDENTITY_JSON")"
	KEY_SEQ="$(jq -r '.key_seq // 1' "$IDENTITY_JSON")"
else
	OPERATOR_PUBKEY_HEX="$PLACEHOLDER_HASH"
	KEY_SEQ=1
fi

if [ -r "$IDENTITY_HISTORY_JSONL" ] && [ -s "$IDENTITY_HISTORY_JSONL" ]; then
	IDENTITY_HISTORY_ROOT="$(sha256_file "$IDENTITY_HISTORY_JSONL")"
else
	IDENTITY_HISTORY_ROOT="$PLACEHOLDER_HASH"
fi

# prev_anchor_root + prev_anchor_tx: read last row of anchor-history.jsonl
PREV_ROOT_JQ="null"
PREV_TX_JQ="null"
if [ -r "$ANCHOR_HISTORY_JSONL" ] && [ -s "$ANCHOR_HISTORY_JSONL" ]; then
	pr="$(tail -1 "$ANCHOR_HISTORY_JSONL" | jq -r '.dag_root // .dag_root_computed // ""')"
	pt="$(tail -1 "$ANCHOR_HISTORY_JSONL" | jq -r '.tx_id // ""')"
	[ -n "$pr" ] && PREV_ROOT_JQ="\"$pr\""
	[ -n "$pt" ] && PREV_TX_JQ="\"$pt\""
fi

IDENTITY_BRANCH="$(jq -n \
	--arg pubkey "$OPERATOR_PUBKEY_HEX" \
	--arg nodeid "$NODE_ID" \
	--argjson prev_root "$PREV_ROOT_JQ" \
	--argjson prev_tx "$PREV_TX_JQ" \
	--argjson key_seq "$KEY_SEQ" \
	--arg id_hist "$IDENTITY_HISTORY_ROOT" \
	'{
		operator_ed25519_pubkey_sha256_hex: $pubkey,
		operator_asserts_node_id: $nodeid,
		prev_anchor_root: $prev_root,
		prev_anchor_tx: $prev_tx,
		key_seq: $key_seq,
		identity_history_root: $id_hist
	}')"

# ---- observations_branch ---------------------------------------------
RPC_PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{"nodeIDs":["'"$NODE_ID"'"]}}'
VAL_RESP="$(curl -sS -X POST -H 'content-type:application/json' --max-time 10 \
	--data "$RPC_PAYLOAD" "${METALGO_API}/ext/bc/P" 2>/dev/null || echo '{}')"

if [ -z "$VAL_RESP" ] || ! echo "$VAL_RESP" | jq -e '.result.validators' >/dev/null 2>&1; then
	echo "ERROR: P-chain RPC failed or unparseable response" >&2
	exit 4
fi

VAL_NODE="$(echo "$VAL_RESP" | jq --arg id "$NODE_ID" '.result.validators[]? | select(.nodeID == $id)')"
if [ -z "$VAL_NODE" ] || [ "$VAL_NODE" = "null" ]; then
	echo "ERROR: NodeID $NODE_ID not present in current validators (= cycle transition in progress?)" >&2
	exit 4
fi

CYCLE_START_EPOCH="$(echo "$VAL_NODE" | jq -r '.startTime // "0"')"
CYCLE_END_EPOCH="$(echo "$VAL_NODE" | jq -r '.endTime // "0"')"
CYCLE_START_ISO="$(iso_utc_of_epoch "$CYCLE_START_EPOCH")"
CYCLE_END_ISO="$(iso_utc_of_epoch "$CYCLE_END_EPOCH")"

STAKE_NMETAL="$(echo "$VAL_NODE" | jq -r '.stakeAmount // .weight // "0"')"
STAKE_METAL_RAW="$(awk -v n="$STAKE_NMETAL" 'BEGIN{printf "%.4f", n/1e9}')"
# Normalize METAL: remove trailing zeros but keep integer form clean.
STAKE_METAL_STR="$(printf '%s' "$STAKE_METAL_RAW" | sed -E 's/\.?0+$//')"
[ -z "$STAKE_METAL_STR" ] && STAKE_METAL_STR="0"

# Metal P-chain returns delegationFee as decimal string (e.g., "3.0000" = 3.0%).
# This diverges from vanilla EOSIO where it would be percent × 10000.
FEE_RAW="$(echo "$VAL_NODE" | jq -r '.delegationFee // "0"')"
FEE_PCT_STR="$(awk -v f="$FEE_RAW" 'BEGIN{printf "%g", f+0}')"
[ -z "$FEE_PCT_STR" ] && FEE_PCT_STR="0"

# Cycle number: our internal counter.
# cycle-history.jsonl has one line per CLOSED cycle. When our validator is
# currently registered (= VAL_NODE non-empty; verified above), we're in
# cycle (closed_count + 1). If cycle-history.jsonl is missing / empty, we
# treat this as cycle 1 (= genesis).
CYCLE_HISTORY_TMP="$(mktemp)"
if fetch_api_file "cycle-history.jsonl" "$CYCLE_HISTORY_TMP" 2>/dev/null; then
	CLOSED_COUNT="$(wc -l < "$CYCLE_HISTORY_TMP" | tr -d ' ')"
elif [ -r "$CYCLE_HISTORY_JSONL" ]; then
	CLOSED_COUNT="$(wc -l < "$CYCLE_HISTORY_JSONL" | tr -d ' ')"
else
	CLOSED_COUNT=0
fi
rm -f "$CYCLE_HISTORY_TMP"
CYCLE_NUMBER=$((CLOSED_COUNT + 1))

# Current delegator snapshot
DELEGATORS_JSON="$(echo "$VAL_NODE" | jq '[.delegators[]? | {tx_id: .txID, weight_nmetal: (.weight | tostring)}]')"
[ -z "$DELEGATORS_JSON" ] && DELEGATORS_JSON="[]"

# Delegator lifecycle events (= filter events log for current cycle window)
if [ -r "$DELEGATOR_EVENTS_JSONL" ] && [ -s "$DELEGATOR_EVENTS_JSONL" ]; then
	DELEGATOR_EVENTS="$(jq -s \
		--arg cs "$CYCLE_START_EPOCH" \
		--arg ce "$CYCLE_END_EPOCH" \
		'[.[] | select((.observed_epoch // 0) >= ($cs | tonumber) and (.observed_epoch // 0) <= ($ce | tonumber)) | del(.observed_epoch)]' \
		"$DELEGATOR_EVENTS_JSONL" 2>/dev/null || echo '[]')"
else
	DELEGATOR_EVENTS="[]"
fi

# T-M-20260701: discoverability metadata for subnet evaluator search.
# Optional configuration files (one entry per line, blank lines and lines
# starting with '#' ignored). Absent files = empty arrays (= no-op).
EVALUATOR_HINTS_FILE="${FY_CONFIG_DIR:-/etc/freedom-yield}/evaluator-hints"
SUBNET_TARGETS_FILE="${FY_CONFIG_DIR:-/etc/freedom-yield}/subnet-targets"
EVALUATOR_HINTS_JSON='[]'
SUBNET_TARGETS_JSON='[]'
if [ -r "$EVALUATOR_HINTS_FILE" ]; then
	EVALUATOR_HINTS_JSON="$(grep -vE '^\s*(#|$)' "$EVALUATOR_HINTS_FILE" 2>/dev/null \
		| jq -R . | jq -sc . 2>/dev/null || echo '[]')"
fi
if [ -r "$SUBNET_TARGETS_FILE" ]; then
	SUBNET_TARGETS_JSON="$(grep -vE '^\s*(#|$)' "$SUBNET_TARGETS_FILE" 2>/dev/null \
		| jq -R . | jq -sc . 2>/dev/null || echo '[]')"
fi

OBSERVATIONS_BRANCH="$(jq -n \
	--argjson cycle_num "$CYCLE_NUMBER" \
	--arg cycle_start "$CYCLE_START_ISO" \
	--arg cycle_end "$CYCLE_END_ISO" \
	--argjson stake_metal "$STAKE_METAL_STR" \
	--arg stake_nmetal "$STAKE_NMETAL" \
	--argjson fee_pct "$FEE_PCT_STR" \
	--argjson events "$DELEGATOR_EVENTS" \
	--argjson snapshot "$DELEGATORS_JSON" \
	--argjson hints "$EVALUATOR_HINTS_JSON" \
	--argjson targets "$SUBNET_TARGETS_JSON" \
	'{
		cycle_number_observed: $cycle_num,
		cycle_start_time_observed: $cycle_start,
		cycle_end_time_observed: $cycle_end,
		self_stake_observed_metal: $stake_metal,
		self_stake_observed_nmetal: $stake_nmetal,
		fee_percent_observed_at_cycle_start: $fee_pct,
		delegator_lifecycle_events_in_cycle_observed: $events,
		delegator_snapshot_at_cycle_end: $snapshot,
		evaluator_hints_declared_by_operator: $hints,
		subnet_targets_declared_by_operator: $targets
	}')"

# ---- artifacts_branch ------------------------------------------------
# File list to hash: lexicographic sort mandatory (= Merkle canonical order).
# Includes only PUBLIC artifacts served at https://metal.freedom-yield.com/api/*.
# Hetzner-only master files (= uptime-history.jsonl in state dir) are NOT
# hashed here; their public equivalent (uptime-recent.json + uptime-cycles.json)
# is what a third-party evaluator can fetch and cross-verify.
API_FILES=(
	cycles-history.json
	evidence.json
	identity-history.jsonl
	identity.json
	peer-geo.json
	peers.json
	uptime-cycles.json
	uptime-recent.json
	validator.json
)

FILES_HASHED_ARR="["
FIRST=1
LEAVES=()
for f in "${API_FILES[@]}"; do
	tmp_file="$(mktemp)"
	if ! fetch_api_file "$f" "$tmp_file"; then
		echo "WARN: skip unreachable file: $f (public URL + local both missing)" >&2
		rm -f "$tmp_file"
		continue
	fi
	hash="$(sha256_file "$tmp_file")"
	rm -f "$tmp_file"
	LEAVES+=("$hash")
	[ "$FIRST" -eq 0 ] && FILES_HASHED_ARR+=","
	FILES_HASHED_ARR+="{\"path\":\"$f\",\"sha256\":\"$hash\"}"
	FIRST=0
done
FILES_HASHED_ARR+="]"

if [ "${#LEAVES[@]}" -eq 0 ]; then
	echo "ERROR: no public API files fetchable (URL + local both empty)" >&2
	exit 3
fi

MANIFEST_ROOT="$(merkle_root "${LEAVES[@]}")"

# period_uptime_observed_pct: use most recent uptime-history entry.
if [ -r "$UPTIME_HISTORY_JSONL" ] && [ -s "$UPTIME_HISTORY_JSONL" ]; then
	UPTIME_PCT="$(tail -1 "$UPTIME_HISTORY_JSONL" | jq -r '.uptime_pct // 0' 2>/dev/null || echo 0)"
else
	UPTIME_PCT=0
fi

# period_incident_count_observed: count of Priority: high|urgent in anomalies.log
# grep -c always prints a count; exit 1 when 0 matches. `|| true` swallows the
# non-zero exit without adding a duplicate "0" to stdout (= observed bug).
INCIDENT_COUNT=0
if [ -r "$ANOMALIES_LOG" ]; then
	INCIDENT_COUNT="$(grep -cE 'Priority: (high|urgent)' "$ANOMALIES_LOG" 2>/dev/null || true)"
	[ -z "$INCIDENT_COUNT" ] && INCIDENT_COUNT=0
fi

ARTIFACTS_BRANCH="$(jq -n \
	--arg manifest_root "$MANIFEST_ROOT" \
	--argjson files "$FILES_HASHED_ARR" \
	--argjson uptime "$UPTIME_PCT" \
	--argjson incidents "$INCIDENT_COUNT" \
	'{
		public_api_manifest_root: $manifest_root,
		public_api_files_hashed: $files,
		period_uptime_observed_pct: $uptime,
		period_incident_count_observed: $incidents
	}')"

# ---- dag_root_computed ------------------------------------------------
# Each branch → jq -cS canonical (compact, sorted keys) → sha256 hex.
# dag_root = sha256(id_root_hex || ob_root_hex || ar_root_hex).
ID_ROOT="$(printf '%s' "$IDENTITY_BRANCH" | jq -cS . | "${SHA256_CMD[@]}" | awk '{print $1}')"
OB_ROOT="$(printf '%s' "$OBSERVATIONS_BRANCH" | jq -cS . | "${SHA256_CMD[@]}" | awk '{print $1}')"
AR_ROOT="$(printf '%s' "$ARTIFACTS_BRANCH" | jq -cS . | "${SHA256_CMD[@]}" | awk '{print $1}')"
DAG_ROOT="$(sha256_str "${ID_ROOT}${OB_ROOT}${AR_ROOT}")"

# ---- compose final ---------------------------------------------------
FINAL_JSON="$(jq -n \
	--arg url "https://metal.freedom-yield.com/api/anchor-source.schema.v1.json" \
	--arg now "$NOW_ISO" \
	--arg script "gen-anchor-source.sh v${SCRIPT_VERSION}" \
	--arg gitc "$GIT_COMMIT" \
	--argjson id_b "$IDENTITY_BRANCH" \
	--argjson ob_b "$OBSERVATIONS_BRANCH" \
	--argjson ar_b "$ARTIFACTS_BRANCH" \
	--arg dag "$DAG_ROOT" \
	'{
		"$schema": $url,
		schema_version: 1,
		computed_at: $now,
		computed_by_script: $script,
		computed_from_git_commit: $gitc,
		identity_branch: $id_b,
		observations_branch: $ob_b,
		artifacts_branch: $ar_b,
		dag_root_computed: $dag
	}')"

# ---- verb discipline check ------------------------------------------
if printf '%s' "$FINAL_JSON" | grep -qE '_target|_promised|_committed|_sla|_slo|_cadence|_guarantees|_ensures|_will_|_should_|_must_|_maintain|_pledged'; then
	echo "ERROR: obligation verb detected in output (verb discipline violation)" >&2
	echo "--- offending lines ---" >&2
	printf '%s' "$FINAL_JSON" | grep -nE '_target|_promised|_committed|_sla|_slo|_cadence|_guarantees|_ensures|_will_|_should_|_must_|_maintain|_pledged' >&2 || true
	exit 5
fi

# ---- optional schema validation (= ajv-cli if available) ------------
if command -v ajv >/dev/null 2>&1 && [ -r "$SCHEMA_FILE" ]; then
	tmp_val="$(mktemp)"
	printf '%s' "$FINAL_JSON" > "$tmp_val"
	if ! ajv --spec=draft2020 --strict=false validate -s "$SCHEMA_FILE" -d "$tmp_val" >/dev/null 2>&1; then
		echo "ERROR: output failed schema validation against $SCHEMA_FILE" >&2
		ajv --spec=draft2020 --strict=false validate -s "$SCHEMA_FILE" -d "$tmp_val" >&2 || true
		rm -f "$tmp_val"
		exit 6
	fi
	rm -f "$tmp_val"
fi

# ---- output ---------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
	# JSON to stdout so callers can pipe to jq. All human-facing messages to stderr.
	printf '%s\n' "$FINAL_JSON"
	echo "DRY-RUN: not writing to $OUT_FILE" >&2
	echo "DRY-RUN: dag_root_computed=$DAG_ROOT" >&2
	exit 0
fi

TMP_OUT="$(mktemp -p "$(dirname "$OUT_FILE")" .anchor-source.XXXXXX)"
printf '%s\n' "$FINAL_JSON" > "$TMP_OUT" || {
	echo "ERROR: temp write failed" >&2
	rm -f "$TMP_OUT"
	exit 7
}
mv "$TMP_OUT" "$OUT_FILE" || {
	echo "ERROR: atomic rename failed" >&2
	rm -f "$TMP_OUT"
	exit 7
}

echo "OK: wrote $OUT_FILE"
echo "dag_root_computed: $DAG_ROOT"
