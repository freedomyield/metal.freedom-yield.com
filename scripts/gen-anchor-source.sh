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
#   6  schema validation failed (= output does not conform to v1, or the
#      schema file itself is unreadable)
#   7  atomic write failed (canonical public/api/anchor-source.json OR the
#      R18 per-anchor archive copy under public/api/archive/)
#   8  R13: no JSON schema validator available (ajv absent AND python3's
#      jsonschema module absent) — fail-closed rather than silently skip
#      validation. Provision one: `npm i -g ajv-cli ajv-formats` or
#      `pip3 install jsonschema` on the host that runs this script.
#   9  FY_EXPECT_CYCLE ordering guard: cycle-history.jsonl's CLOSED_COUNT
#      does not match the just-closed cycle the caller declared. NOTE: this
#      is a DIFFERENT code than gen-identity.sh's analogous ordering guard,
#      which uses exit 7 there — that code was already taken here (see exit
#      7 above, "atomic write failed"). One code, one meaning within this
#      script; do not conflate the two scripts' exit-7/9 by number alone.
#  10  M-2: anchor-history.jsonl is non-empty (>=1 valid JSON line) but
#      prev_anchor_root / prev_anchor_tx could not both be extracted as
#      64-hex from its last valid line. Fail-closed guard added 2026-08-xx
#      after the 08-04-incident-class bug where a trailing blank line (LF
#      LF at EOF) or an unrecognized field name made `tail -1` / the jq
#      lookup silently resolve to "", which the old code then wrote as
#      prev_anchor_root: null — indistinguishable from genuine genesis. A
#      GENUINELY empty/absent history file is still genesis and exits 0
#      with null, unchanged.

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

# Operator identity pubkey URL. Semantic C (schema §identity_branch.operator_ed25519_pubkey_sha256_hex):
# fetch the OpenSSH-format pubkey file, extract the base64 body (2nd whitespace-
# separated token), base64-decode to the 51-byte RFC 4716 wire record, extract
# the trailing 32 bytes (= raw ed25519 pubkey), and SHA-256 that. Evaluators
# reproduce with `curl <URL> | awk '{print $2}' | base64 -d | tail -c 32 | sha256sum`.
PUBKEY_URL="${PUBKEY_URL:-https://metal.freedom-yield.com/.well-known/operator-identity.pub}"

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
#
# Sets $FETCH_API_FILE_SOURCE on success (= "public URL (...)" or "local repo
# fallback (...)") so callers that need to know WHICH source answered (e.g.
# the FY_EXPECT_CYCLE ordering guard below, which must tell the operator
# whether a cycle-count mismatch was read from the public site or from a
# possibly-stale local checkout) can report it without re-deriving it.
fetch_api_file() {
	local rel="$1"
	local dst="$2"
	local url="${API_BASE_URL}/${rel}"
	if curl -sSf --max-time 15 "$url" -o "$dst" 2>/dev/null; then
		FETCH_API_FILE_SOURCE="public URL ($url)"
		return 0
	fi
	local local_path="${ROOT}/public/api/${rel}"
	if [ -r "$local_path" ]; then
		cp "$local_path" "$dst"
		FETCH_API_FILE_SOURCE="local repo fallback ($local_path; public URL unreachable: $url)"
		echo "WARN: $rel fetched from local repo (public URL unreachable): $url" >&2
		return 0
	fi
	FETCH_API_FILE_SOURCE=""
	return 1
}

# ---- computed_at + git commit ----------------------------------------
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT="$(cd "$ROOT" && git rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")"

# ---- identity_branch -------------------------------------------------
PLACEHOLDER_HASH="0000000000000000000000000000000000000000000000000000000000000000"

# operator_ed25519_pubkey_sha256_hex (semantic C):
# authoritative source is the public pubkey URL. The evaluator can
# reproduce this from HTTPS-fetched pubkey. Local identity.json is NOT
# authoritative for this field — it may cache a stale value or omit the
# canonical form entirely. Fail-closed when URL unreachable (exit 4)
# rather than silently emitting a placeholder that would poison the anchor.
TMP_PUBKEY="$(mktemp -t fya-pubkey.XXXXXX)"
trap 'rm -f "$TMP_PUBKEY"' EXIT
if ! curl -sSf --max-time 15 "$PUBKEY_URL" -o "$TMP_PUBKEY" 2>/dev/null; then
	echo "ERROR: cannot fetch operator pubkey from $PUBKEY_URL (semantic C requires reachable URL)" >&2
	rm -f "$TMP_PUBKEY"
	exit 4
fi
OPERATOR_PUBKEY_HEX="$(awk '{print $2}' "$TMP_PUBKEY" | base64 -d 2>/dev/null | tail -c 32 | "${SHA256_CMD[@]}" | awk '{print $1}')"
if ! printf '%s' "$OPERATOR_PUBKEY_HEX" | grep -qE '^[0-9a-f]{64}$'; then
	echo "ERROR: semantic C hash extraction from $PUBKEY_URL failed (got: '$OPERATOR_PUBKEY_HEX')" >&2
	rm -f "$TMP_PUBKEY"
	exit 5
fi
rm -f "$TMP_PUBKEY"

# key_seq: default 1 unless identity.json exports it explicitly. In practice
# key rotation would increment this via the identity manifest regeneration
# workflow (out of scope for gen-anchor-source). Absent identity.json = 1.
if [ -r "$IDENTITY_JSON" ]; then
	KEY_SEQ="$(jq -r '.key_seq // 1' "$IDENTITY_JSON")"
else
	KEY_SEQ=1
fi

# identity_history_root: sha256 of the authoritative identity-history.jsonl
# file. Same source-of-truth pattern as identity_branch pubkey — fetch the
# public URL, fail-closed on unreachable. Local file is checked only as an
# offline-dev fallback.
IDENTITY_HISTORY_URL="${API_BASE_URL}/identity-history.jsonl"
TMP_HIST="$(mktemp -t fya-idhist.XXXXXX)"
trap 'rm -f "$TMP_PUBKEY" "$TMP_HIST"' EXIT
if curl -sSf --max-time 15 "$IDENTITY_HISTORY_URL" -o "$TMP_HIST" 2>/dev/null && [ -s "$TMP_HIST" ]; then
	IDENTITY_HISTORY_ROOT="$(sha256_file "$TMP_HIST")"
elif [ -r "$IDENTITY_HISTORY_JSONL" ] && [ -s "$IDENTITY_HISTORY_JSONL" ]; then
	IDENTITY_HISTORY_ROOT="$(sha256_file "$IDENTITY_HISTORY_JSONL")"
	echo "WARN: identity-history.jsonl fetched from local repo (public URL unreachable): $IDENTITY_HISTORY_URL" >&2
else
	echo "ERROR: cannot fetch identity-history.jsonl from $IDENTITY_HISTORY_URL and no local fallback" >&2
	rm -f "$TMP_PUBKEY" "$TMP_HIST"
	exit 3
fi
rm -f "$TMP_HIST"

# prev_anchor_root + prev_anchor_tx: read last row of anchor-history.jsonl.
# The writer (scripts/append-anchor-history.sh:239,271) names this field
# "dag_root_hash" — that is the primary key to read; the other two
# alternatives are defensive fallbacks only, not the authoritative name.
#
# Fail-closed invariant (M-2, 08-04-incident-class defense): if the history
# file is non-empty (>= 1 valid JSON line), prev_anchor_root AND
# prev_anchor_tx MUST both resolve to 64-hex — anything else (a blank tail
# line from a trailing double newline, an unrecognized field name, a
# malformed value) used to silently produce "prev_anchor_root: null",
# indistinguishable from genuine genesis, and would let a non-genesis
# anchor re-inscribe as if it were the first. Only a GENUINELY empty/
# absent history file (no valid JSON line at all) is genesis and exits 0
# with null, unchanged from prior behavior.
PREV_ROOT_JQ="null"
PREV_TX_JQ="null"
if [ -r "$ANCHOR_HISTORY_JSONL" ] && [ -s "$ANCHOR_HISTORY_JSONL" ]; then
	# Strip blank lines before taking the tail: a trailing double newline
	# (LF LF at EOF) otherwise makes `tail -1` return an empty string,
	# which used to silently resolve to null (the M-2 bug) instead of
	# reading the last VALID JSON line.
	LAST_HISTORY_LINE="$(grep -vE '^[[:space:]]*$' "$ANCHOR_HISTORY_JSONL" | tail -1)"
	if [ -n "$LAST_HISTORY_LINE" ]; then
		pr="$(printf '%s\n' "$LAST_HISTORY_LINE" | jq -r '.dag_root_hash // .dag_root // .dag_root_computed // ""' 2>/dev/null)"
		pt="$(printf '%s\n' "$LAST_HISTORY_LINE" | jq -r '.tx_id // ""' 2>/dev/null)"
		if printf '%s' "$pr" | grep -qE '^[0-9a-f]{64}$' && printf '%s' "$pt" | grep -qE '^[0-9a-f]{64}$'; then
			PREV_ROOT_JQ="\"$pr\""
			PREV_TX_JQ="\"$pt\""
		else
			echo "ERROR: anchor-history.jsonl ($ANCHOR_HISTORY_JSONL) is non-empty but prev_anchor_root/prev_anchor_tx could not be extracted as 64-hex from its last valid line — fail-closed (M-2, 2026-08-04-incident-class guard: a writer/reader field-name mismatch or malformed tail line must NEVER silently degrade to prev_anchor_root: null, which is indistinguishable from genuine genesis)." >&2
			echo "  last valid line read: $LAST_HISTORY_LINE" >&2
			echo "  extracted prev_anchor_root='$pr' prev_anchor_tx='$pt' (both must match ^[0-9a-f]{64}\$)" >&2
			exit 10
		fi
	fi
	# else: file has bytes but only blank lines -> treated as empty/genesis,
	# falls through with PREV_ROOT_JQ/PREV_TX_JQ left at "null".
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

# ---- cycle-history ordering guard (FY_EXPECT_CYCLE) --------------------
# CLOSED_COUNT = number of CLOSED cycles already on cycle-history.jsonl (one
# line per closed cycle). CYCLE_NUMBER = CLOSED_COUNT + 1 becomes the memo
# prefix fya1c<CYCLE_NUMBER> at anchor time (sign-anchor-event.sh). Computed
# and guarded HERE — before the P-chain RPC call below — so a mismatch fails
# fast without depending on RPC/metalgo reachability, and so this guard is
# unit-testable without a live node (see
# tests/test-gen-anchor-source-ordering-guard.sh).
#
# Ordering guard (mirrors scripts/operator-local/gen-identity.sh's
# FY_EXPECT_CYCLE guard, design-stocktake #6): if this script composes
# anchor-source.json BEFORE the just-closed cycle's record is published to
# cycle-history.jsonl, CLOSED_COUNT under-counts by one and CYCLE_NUMBER
# derives the cycle that is CURRENTLY still open — anchoring under that
# number re-inscribes the memo prefix (fya1c<N>) a second time, which is
# unrecoverable on an append-only chain (the incident this guard exists to
# prevent). Set FY_EXPECT_CYCLE=<the cycle that should already be closed> to
# make "the cycle record is already published" a machine-checked
# precondition instead of operator vigilance.
#
# Exit code note: this guard exits 9, NOT 7. gen-identity.sh's analogous
# guard uses exit 7 there, but exit 7 already means "atomic write failed"
# in THIS script's own exit-code table (see header) — one code, one
# meaning within a single script wins over verbatim parity between the two
# scripts' guards, so operators should not read "exit 7" and "exit 9" here
# as the same condition just because gen-identity.sh's guard is 7.
CYCLE_HISTORY_TMP="$(mktemp)"
FETCH_API_FILE_SOURCE=""
if fetch_api_file "cycle-history.jsonl" "$CYCLE_HISTORY_TMP" 2>/dev/null; then
	CLOSED_COUNT="$(wc -l < "$CYCLE_HISTORY_TMP" | tr -d ' ')"
	CYCLE_HISTORY_SOURCE="$FETCH_API_FILE_SOURCE"
elif [ -r "$CYCLE_HISTORY_JSONL" ]; then
	CLOSED_COUNT="$(wc -l < "$CYCLE_HISTORY_JSONL" | tr -d ' ')"
	CYCLE_HISTORY_SOURCE="local repo fallback (\$CYCLE_HISTORY_JSONL=$CYCLE_HISTORY_JSONL; public URL ${API_BASE_URL}/cycle-history.jsonl and its repo-local mirror were both unreachable)"
else
	CLOSED_COUNT=0
	CYCLE_HISTORY_SOURCE="no source reachable (public URL, its repo-local mirror, and \$CYCLE_HISTORY_JSONL all unavailable — treated as pre-genesis)"
fi
rm -f "$CYCLE_HISTORY_TMP"
CYCLE_NUMBER=$((CLOSED_COUNT + 1))

echo "  cycle-history: CLOSED_COUNT=${CLOSED_COUNT} (source: ${CYCLE_HISTORY_SOURCE}) -> CYCLE_NUMBER=${CYCLE_NUMBER}" >&2
if [ -n "${FY_EXPECT_CYCLE:-}" ]; then
	if [ "$CLOSED_COUNT" != "$FY_EXPECT_CYCLE" ]; then
		echo "ERROR: FY_EXPECT_CYCLE=${FY_EXPECT_CYCLE} but cycle-history.jsonl's CLOSED_COUNT is ${CLOSED_COUNT} (source: ${CYCLE_HISTORY_SOURCE})." >&2
		echo "       Composing now would derive CYCLE_NUMBER=$((CLOSED_COUNT + 1)), not $((FY_EXPECT_CYCLE + 1)) — the just-closed cycle is not on the published ledger yet, so the memo prefix would not advance (or would re-inscribe one already used)." >&2
		echo "       Record + publish cycle ${FY_EXPECT_CYCLE} first (uptime-history.sh -> gen-cycle-history.sh -> git-deploy publish), confirm CDN propagation (curl ${API_BASE_URL}/cycle-history.jsonl), then re-run." >&2
		echo "       (exit 9, not 7: gen-identity.sh's analogous ordering guard uses exit 7, but that code already means \"atomic write failed\" in this script — see the header's exit-code table.)" >&2
		exit 9
	fi
	echo "  ✓ ordering guard: cycle-history CLOSED_COUNT is fresh to expected cycle ${FY_EXPECT_CYCLE}" >&2
else
	# FY_EXPECT_CYCLE unset — the machine-checked ordering guard above cannot
	# run (nothing to compare the live ledger against), so this run is NOT
	# protected against composing anchor-source.json before the just-closed
	# cycle is on the published ledger. Intentionally NOT a hard-stop:
	# first-run / bootstrap invocations (before any cycle has closed) have no
	# cycle to name yet, so exit behavior here is unchanged. Loud stderr
	# banner only — mirrors gen-identity.sh's disabled-guard warning.
	echo "  ################################################################" >&2
	echo "  #  WARNING: ordering guard DISABLED (FY_EXPECT_CYCLE unset)  #" >&2
	echo "  #  This run is NOT verifying the just-closed cycle is on the #" >&2
	echo "  #  published cycle-history.jsonl before composing anchor-source. #" >&2
	echo "  #  At a cycle transition, re-run with:                       #" >&2
	echo "  #    FY_EXPECT_CYCLE=<the cycle that should already be closed> #" >&2
	echo "  #  See docs/CYCLE_GATE.md, 'Operator runbook' section.       #" >&2
	echo "  ################################################################" >&2
fi

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

# Cycle number: CLOSED_COUNT / CYCLE_NUMBER are computed earlier, above the
# RPC call, alongside the FY_EXPECT_CYCLE ordering guard (see that section
# for rationale). Both are already in scope here.

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

# S8-20260701: delegator lifecycle observation window boundary.
# Config file contains a single ISO 8601 UTC timestamp (one line, no comment).
# Represents when the operator's event-capture feed began emitting delegator
# lifecycle events for this validator. Events with observed_at earlier than
# this timestamp are outside the feed's window and NOT present in
# delegator_lifecycle_events_in_cycle_observed. Absent config = field omitted
# (evaluators must assume undefined = partial-observation risk).
# See feed_started_at semantics in docs/ANCHOR_SOURCE.md.
FEED_STARTED_AT_FILE="${FY_CONFIG_DIR:-/etc/freedom-yield}/delegator-feed-started-at"
FEED_STARTED_AT=""
if [ -r "$FEED_STARTED_AT_FILE" ]; then
	FEED_STARTED_AT="$(head -1 "$FEED_STARTED_AT_FILE" | tr -d '[:space:]')"
	if ! printf '%s' "$FEED_STARTED_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
		echo "ERROR: $FEED_STARTED_AT_FILE contents not ISO 8601 UTC (YYYY-MM-DDTHH:MM:SSZ): '$FEED_STARTED_AT'" >&2
		exit 2
	fi
else
	echo "WARN: $FEED_STARTED_AT_FILE not present — delegator_lifecycle_observation_window_started_at will be omitted (partial-observation risk visible to evaluators)" >&2
fi

# Compose observations_branch. When FEED_STARTED_AT is non-empty, insert the
# window field immediately before delegator_lifecycle_events_in_cycle_observed
# so the field order in the composed JSON mirrors the schema property order.
# jq -cS canonicalization sorts keys anyway, so field order is not
# semantically load-bearing for hash computation, but human-readable ordering
# is preserved for the pretty-printed output file.
if [ -n "$FEED_STARTED_AT" ]; then
	OBSERVATIONS_BRANCH="$(jq -n \
		--argjson cycle_num "$CYCLE_NUMBER" \
		--arg cycle_start "$CYCLE_START_ISO" \
		--arg cycle_end "$CYCLE_END_ISO" \
		--argjson stake_metal "$STAKE_METAL_STR" \
		--arg stake_nmetal "$STAKE_NMETAL" \
		--argjson fee_pct "$FEE_PCT_STR" \
		--arg feed_started "$FEED_STARTED_AT" \
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
			delegator_lifecycle_observation_window_started_at: $feed_started,
			delegator_lifecycle_events_in_cycle_observed: $events,
			delegator_snapshot_at_cycle_end: $snapshot,
			evaluator_hints_declared_by_operator: $hints,
			subnet_targets_declared_by_operator: $targets
		}')"
else
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
fi

# ---- artifacts_branch ------------------------------------------------
# File list to hash: lexicographic sort mandatory (= Merkle canonical order).
# Includes only PUBLIC artifacts served at https://metal.freedom-yield.com/api/*.
# validator-host-only master files (= uptime-history.jsonl in state dir) are NOT
# hashed here; their public equivalent (uptime-recent.json + uptime-cycles.json)
# is what a third-party evaluator can fetch and cross-verify.
API_FILES=(
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
# Obligation verbs are forbidden in observation output. Whitelist exception:
# T-M-designed field names that carry an explicit "declared_by_operator" suffix
# neutralize the obligation semantic (= declaration verb, not promise). Grep -E
# lacks lookahead, so filter false positives via a post-grep -v chain.
VERB_HITS="$(printf '%s' "$FINAL_JSON" \
	| grep -nE '_target|_promised|_committed|_sla|_slo|_cadence|_guarantees|_ensures|_will_|_should_|_must_|_maintain|_pledged' \
	| grep -vE 'subnet_targets_declared_by_operator' \
	|| true)"
if [ -n "$VERB_HITS" ]; then
	echo "ERROR: obligation verb detected in output (verb discipline violation)" >&2
	echo "--- offending lines ---" >&2
	printf '%s\n' "$VERB_HITS" >&2
	exit 5
fi

# ---- mandatory schema validation (R13) --------------------------------
# Previously this step only ran `if command -v ajv`, so a host without ajv
# silently skipped validation and let a malformed artifact reach the anchor
# pipeline unchecked. Now validation is mandatory: try ajv (local binary,
# no network) first, then python3's `jsonschema` module (also local, no
# network). If NEITHER is available, fail closed (exit 8) instead of
# silently accepting unvalidated output. This function is duplicated
# (not sourced from a shared lib — no cross-script sourcing convention
# exists in this repo) in gen-anchor-receipt.sh and
# append-anchor-history.sh; keep the three in sync if you touch the logic.
schema_validate_or_die() {
	local schema="$1" data_file="$2" label="$3" out
	if [ ! -r "$schema" ]; then
		echo "ERROR: schema file not readable: $schema (cannot validate $label)" >&2
		return 6
	fi
	if command -v ajv >/dev/null 2>&1; then
		if out="$(ajv --spec=draft2020 --strict=false validate -s "$schema" -d "$data_file" 2>&1)"; then
			echo "OK: $label schema-valid (ajv)" >&2
			return 0
		fi
		echo "ERROR: $label failed schema validation against $schema (ajv)" >&2
		printf '%s\n' "$out" >&2
		return 6
	fi
	if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
		if out="$(python3 - "$schema" "$data_file" <<'PYEOF' 2>&1
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1], encoding="utf-8"))
data = json.load(open(sys.argv[2], encoding="utf-8"))
jsonschema.validate(instance=data, schema=schema, format_checker=jsonschema.FormatChecker())
PYEOF
		)"; then
			echo "OK: $label schema-valid (python3+jsonschema)" >&2
			return 0
		fi
		echo "ERROR: $label failed schema validation against $schema (python3+jsonschema)" >&2
		printf '%s\n' "$out" >&2
		return 6
	fi
	echo "ERROR: no JSON schema validator available (ajv absent; python3+jsonschema absent) — refusing to skip validation for $label. Install ajv-cli (npm i -g ajv-cli ajv-formats) or 'pip3 install jsonschema'." >&2
	return 8
}

tmp_val="$(mktemp)"
printf '%s' "$FINAL_JSON" > "$tmp_val"
if schema_validate_or_die "$SCHEMA_FILE" "$tmp_val" "anchor-source.json"; then
	rm -f "$tmp_val"
else
	schema_rc=$?
	rm -f "$tmp_val"
	exit "$schema_rc"
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

# ---- R18: durable per-anchor archive copy ------------------------------
# $OUT_FILE (public/api/anchor-source.json) is the CANONICAL "current"
# file — every subsequent cycle's run overwrites it, so without this, a
# past cycle's pre-image is lost the moment the next cycle regenerates the
# file, and it can no longer be independently content-verified against its
# on-chain memos. Archive a byte-identical copy keyed by dag_root_computed
# (content-addressed: the exact value inscribed in the dag_root_summary
# on-chain memo, so an evaluator holding a memo hex can locate its
# pre-image directly). Content-addressing also makes this safe when
# multiple anchors share one cycle_number (cyclestart + heartbeat(s) +
# cycleend all reuse the same cycle_number but produce distinct dag roots)
# — each gets its own archive entry, none collide or overwrite another.
# This block runs strictly after the canonical write above succeeds and
# writes the SAME $FINAL_JSON bytes already validated + written to
# $OUT_FILE — it never re-derives or alters the composed content.
ARCHIVE_DIR="${ANCHOR_SOURCE_ARCHIVE_DIR:-$(dirname "$OUT_FILE")/archive}"
mkdir -p "$ARCHIVE_DIR" || {
	echo "ERROR: cannot create archive dir: $ARCHIVE_DIR" >&2
	exit 7
}
ARCHIVE_FILE="${ARCHIVE_DIR}/anchor-source-${DAG_ROOT}.json"
TMP_ARCHIVE="$(mktemp -p "$ARCHIVE_DIR" .anchor-source-archive.XXXXXX)"
printf '%s\n' "$FINAL_JSON" > "$TMP_ARCHIVE" || {
	echo "ERROR: archive temp write failed" >&2
	rm -f "$TMP_ARCHIVE"
	exit 7
}
mv "$TMP_ARCHIVE" "$ARCHIVE_FILE" || {
	echo "ERROR: archive atomic rename failed" >&2
	rm -f "$TMP_ARCHIVE"
	exit 7
}
echo "OK: archived $ARCHIVE_FILE"
