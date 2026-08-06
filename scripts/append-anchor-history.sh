#!/usr/bin/env bash
# append-anchor-history.sh v2 — Append v2 receipt as new JSONL line to
# /api/anchor-history.jsonl with append-only invariants enforced.
#
# CHAIN: none — pure file operation.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast).
#
# 2026-07-01 rewrite: consumes v2 receipt (schema_version=2,
# hc_single_4_action_pack, memo_prefix fya<S>c<N>). Emits v2 jsonl lines
# per anchor-history.schema.v2.json.
#
# Invariants enforced:
#   1. tx_id unique across all lines
#   2. For cyclestart/cycleend: (cycle_number, event_type) pair unique
#   3. For idrotate: (key_seq, "idrotate") pair unique
#   4. cycle_number strictly non-decreasing across lines that carry it
#   5. block_num strictly non-decreasing across all lines
#   6. prev_anchor_tx_id of new line == tx_id of last line (or null if
#      genesis line)
#   7. existing lines are byte-for-byte immutable (only legal write is
#      appending a new line)
#   8. file terminates with LF on the final line
#
# Exit codes:
#   0  appended successfully
#   1  usage / arg error
#   2  receipt file unreadable / invalid
#   3  receipt verification_status != "live"
#   4  invariant violation (with detail on stderr)
#   5  atomic write failed
#   6  R13: the newly composed line failed schema validation against
#      public/api/anchor-history.schema.v2.json (or the schema file
#      itself is unreadable)
#   7  R13: no JSON schema validator available (ajv absent AND python3's
#      jsonschema module absent) — fail-closed rather than silently skip
#      validation. Provision one: `npm i -g ajv-cli ajv-formats` or
#      `pip3 install jsonschema` on the host that runs this script.
#
# Usage:
#   append-anchor-history.sh --receipt=<anchor-receipt.json>
#                            [--history=<anchor-history.jsonl>]
#                            [--event-type=<cyclestart|cycleend|idrotate|heartbeat>]
#                            [--key-seq=<int>]
#
# R18 publication (2026-08-06): after a successful append, this script also
# pushes the two per-anchor archive files (archived_source_path /
# archived_receipt_path, composed below) to the web host via
# push-to-web-host.sh, so the URL the new history line advertises is live
# the moment the line becomes visible — never a gap where the line exists
# but the archive it points at 404s. This is a best-effort side effect: a
# publish failure (file missing locally, SSH/network failure, ...) is
# reported loudly (stderr + notify.sh alert if available) but NEVER changes
# this script's exit code — the append-only chain record must not be held
# hostage by a downstream publish problem. See the R18 comment block below
# for why this lives here and not in gen-anchor-source.sh /
# gen-anchor-receipt.sh (orphan avoidance).
#
# Env overrides (all optional; defaults match production layout):
#   FYD_PUSH_TO_WEB_HOST   path to push-to-web-host.sh (default: repo's own)
#   ANCHOR_ARCHIVE_DIR     WHERE THIS SCRIPT LOOKS to decide "does the local
#                          archive file exist" (default: dirname(--history)/
#                          archive, matching gen-anchor-source.sh /
#                          gen-anchor-receipt.sh's own default). Test-only
#                          readability probe, not a redirect of what gets
#                          pushed: the actual push source path is resolved
#                          independently, inside push-to-web-host.sh itself,
#                          from ITS OWN REPO_BASE (or that script's own
#                          REPO_BASE env override) — never from this var. If
#                          the two ever disagree, this script confirms
#                          existence against A but push-to-web-host.sh reads
#                          from B, so only override this for test isolation
#                          (pointing at a scratch dir with no real
#                          push-to-web-host.sh downstream of it), never in
#                          production.
#   FYD_NOTIFY             notifier script for the publish-failure alert
#                          (default: <repo>/scripts/notify.sh). Resolved by
#                          scripts/lib/side-effects.sh, not here.
#   FYD_PUBLISH_ARCHIVES   set to 0 to skip the R18 publish step entirely —
#                          no push-to-web-host.sh invocation, no notify
#                          alert, just the two manual commands printed to
#                          stderr. Kill switch for a rehearsal/dry-run
#                          caller that wants zero outbound calls without
#                          constructing stub scripts. Default: enabled (1).
#   FY_LIVE=1              REQUIRED before the R18 push and the publish-failure
#                          alert leave this machine. Anything else is a loud
#                          dry no-op printing one "DRY: would …" line per
#                          suppressed effect, PLUS the exact manual push
#                          commands (scripts/lib/side-effects.sh, C3 rollout
#                          2026-08-06).
#
#                          THE APPEND ITSELF IS DELIBERATELY NOT GATED. This
#                          script is the writer of an append-only chain
#                          record that an operator runs by hand at a cycle
#                          transition; a forgotten FY_LIVE must cost a
#                          deferred publish (recoverable, and the command to
#                          recover is printed), never a missing line in the
#                          ledger (not recoverable — the receipt it was
#                          derived from is one-shot). Same reasoning as the
#                          existing rule that a push failure never changes
#                          this script's exit code, one step earlier.
#
#                          For a real cycle transition, set it — on the
#                          pipeline, which passes it down:
#                            FY_LIVE=1 bash scripts/run-anchor-pipeline.sh …
#
# Exit codes: 1 usage, 2 receipt unreadable/wrong schema, 3 not verification_
# status=live, 4 append-only invariant violated, 5 tmp write / rename failed,
# 6 schema validation failed, 7 no JSON-schema validator available,
# 8 scripts/lib/side-effects.sh missing (structural).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_VERSION="2.0"
FYD_LIB="${REPO_ROOT}/scripts/lib/side-effects.sh"
if [ ! -r "$FYD_LIB" ]; then
	echo "append-anchor-history: FATAL: side-effects library not readable at $FYD_LIB" >&2
	exit 8
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

RECEIPT=""
# History file target. Env override (FYD_HISTORY_FILE) takes precedence
# over the default repo path so tests and rehearsals can point at a tmp
# file without polluting production data. --history=<path> arg overrides
# both.
HISTORY="${FYD_HISTORY_FILE:-${REPO_ROOT}/public/api/anchor-history.jsonl}"
EVENT_TYPE=""
KEY_SEQ=""
# R13: LOCAL schema file used to self-validate each newly composed line
# before it is appended (see schema_validate_or_die below).
SCHEMA_FILE="${SCHEMA_FILE:-${REPO_ROOT}/public/api/anchor-history.schema.v2.json}"

for arg in "$@"; do
	case "$arg" in
		--receipt=*)     RECEIPT="${arg#*=}" ;;
		--history=*)     HISTORY="${arg#*=}" ;;
		--event-type=*)  EVENT_TYPE="${arg#*=}" ;;
		--key-seq=*)     KEY_SEQ="${arg#*=}" ;;
		-h|--help)       sed -n '2,36p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)               echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if [ -z "$RECEIPT" ]; then
	echo "ERROR: --receipt=<file> required" >&2
	exit 1
fi
if [ ! -r "$RECEIPT" ]; then
	echo "ERROR (2): receipt not readable: $RECEIPT" >&2
	exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "ERROR: jq required" >&2
	exit 1
fi

# ---- receipt parse + verify ----
if ! jq -e '.schema_version == 2' "$RECEIPT" >/dev/null 2>&1; then
	echo "ERROR (2): receipt schema_version must be 2 (got $(jq -r .schema_version "$RECEIPT"))" >&2
	exit 2
fi
if ! jq -e '.verification_status == "live"' "$RECEIPT" >/dev/null 2>&1; then
	STATUS="$(jq -r '.verification_status // "unknown"' "$RECEIPT")"
	echo "ERROR (3): receipt verification_status must be 'live', got: $STATUS" >&2
	exit 3
fi

TX_ID="$(jq -r '.anchor.tx_id' "$RECEIPT")"
BLOCK_NUM="$(jq -r '.anchor.block_num' "$RECEIPT")"
BLOCK_TIME="$(jq -r '.anchor.block_time' "$RECEIPT")"
CYCLE_NUMBER="$(jq -r '.cycle_number // empty' "$RECEIPT")"
DAG_ROOT="$(jq -r '.dag_root_hash' "$RECEIPT")"
MEMO_PREFIX="$(jq -r '.memo_prefix' "$RECEIPT")"
NETWORK="$(jq -r '.anchor.network' "$RECEIPT")"
CHAIN_BACKEND="$(jq -r '.anchor.chain_backend // "pulsevm"' "$RECEIPT")"
METHOD="$(jq -r '.anchor.method' "$RECEIPT")"
EXPLORER_URL="$(jq -r '.anchor.explorer_url' "$RECEIPT")"
ACTOR="$(jq -r '.signing_actor // .anchor.authorization.actor' "$RECEIPT")"
PERMISSION="$(jq -r '.signing_permission // .anchor.authorization.permission' "$RECEIPT")"
VERIFIED_AT="$(jq -r '.verified_at' "$RECEIPT")"
PREV_TX_ID_JSON="$(jq -c '.prev_anchor_tx_id // null' "$RECEIPT")"

# EVENT_TYPE default: derive from trigger_event on receipt if not provided.
if [ -z "$EVENT_TYPE" ]; then
	EVENT_TYPE="$(jq -r '.trigger_event // "manual"' "$RECEIPT")"
fi
case "$EVENT_TYPE" in
	cyclestart|cycleend|idrotate|heartbeat) ;;
	*) echo "ERROR: --event-type must be cyclestart|cycleend|idrotate|heartbeat, got: $EVENT_TYPE" >&2; exit 1 ;;
esac

# idrotate requires key_seq.
if [ "$EVENT_TYPE" = "idrotate" ] && [ -z "$KEY_SEQ" ]; then
	echo "ERROR: --key-seq=<int> required for --event-type=idrotate" >&2
	exit 1
fi
# cyclestart/cycleend require cycle_number on receipt.
if [ "$EVENT_TYPE" = "cyclestart" ] || [ "$EVENT_TYPE" = "cycleend" ]; then
	if [ -z "$CYCLE_NUMBER" ]; then
		echo "ERROR (4): receipt missing cycle_number for event_type=$EVENT_TYPE" >&2
		exit 4
	fi
fi

# ---- invariant checks against existing history ----
if [ -f "$HISTORY" ] && [ -s "$HISTORY" ]; then
	# Invariant 1: tx_id unique.
	if grep -q "\"tx_id\":\"${TX_ID}\"" "$HISTORY"; then
		echo "ERROR (4): invariant 1 — tx_id $TX_ID already present in $HISTORY" >&2
		exit 4
	fi

	LAST_LINE="$(tail -n 1 "$HISTORY")"
	LAST_TX_ID="$(echo "$LAST_LINE" | jq -r '.tx_id')"
	LAST_BLOCK_NUM="$(echo "$LAST_LINE" | jq -r '.block_num')"
	LAST_CYCLE_NUM="$(echo "$LAST_LINE" | jq -r '.cycle_number // empty')"

	# Invariant 2/3: (cycle_number, event_type) or (key_seq, idrotate) uniqueness.
	case "$EVENT_TYPE" in
		cyclestart|cycleend)
			# grep -c always prints a count; exit 1 when 0 matches. A naive
			# `|| echo 0` fallback then APPENDS a second "0" line to stdout
			# (grep's own "0\n" plus echo's "0\n"), producing DUP_COUNT="0\n0"
			# — not a valid integer, so the `-gt` test below throws "integer
			# expression expected" on every append of a genuinely new
			# cycle_number (the common case). Use the same `|| true` idiom as
			# gen-anchor-source.sh's INCIDENT_COUNT (see its comment ~line
			# 526-528): `|| true` swallows the non-zero exit without adding a
			# duplicate line, then the explicit blank-check covers the (rare)
			# case grep emits nothing at all (e.g. read error).
			DUP_COUNT="$(grep -c "\"cycle_number\":${CYCLE_NUMBER}[,}]" "$HISTORY" || true)"
			[ -z "$DUP_COUNT" ] && DUP_COUNT=0
			# Confirm the dup is same event_type via jq walk.
			if [ "$DUP_COUNT" -gt 0 ]; then
				if awk -v cn="$CYCLE_NUMBER" -v et="$EVENT_TYPE" '
					{
						line=$0
						if (index(line, "\"cycle_number\":" cn) && index(line, "\"event_type\":\"" et "\"")) exit 1
					}' "$HISTORY"; then
					:
				else
					echo "ERROR (4): invariant 2 — (cycle_number=$CYCLE_NUMBER, event_type=$EVENT_TYPE) pair already present" >&2
					exit 4
				fi
			fi
			;;
		idrotate)
			if grep -q "\"key_seq\":${KEY_SEQ}[,}].*\"event_type\":\"idrotate\"" "$HISTORY"; then
				echo "ERROR (4): invariant 3 — (key_seq=$KEY_SEQ, idrotate) pair already present" >&2
				exit 4
			fi
			;;
	esac

	# Invariant 4: cycle_number non-decreasing.
	if [ -n "$CYCLE_NUMBER" ] && [ -n "$LAST_CYCLE_NUM" ]; then
		if [ "$CYCLE_NUMBER" -lt "$LAST_CYCLE_NUM" ]; then
			echo "ERROR (4): invariant 4 — new cycle_number $CYCLE_NUMBER < last $LAST_CYCLE_NUM" >&2
			exit 4
		fi
	fi

	# Invariant 5: block_num non-decreasing.
	if [ "$BLOCK_NUM" -lt "$LAST_BLOCK_NUM" ]; then
		echo "ERROR (4): invariant 5 — new block_num $BLOCK_NUM < last $LAST_BLOCK_NUM" >&2
		exit 4
	fi

	# Invariant 6: prev_anchor_tx_id must equal last line's tx_id.
	PREV_TX_ID_VAL="$(echo "$PREV_TX_ID_JSON" | jq -r '. // ""')"
	if [ "$PREV_TX_ID_VAL" != "$LAST_TX_ID" ]; then
		echo "ERROR (4): invariant 6 — receipt.prev_anchor_tx_id (=$PREV_TX_ID_VAL) != last history tx_id (=$LAST_TX_ID)" >&2
		exit 4
	fi
else
	# Genesis line: prev_anchor_tx_id MUST be null.
	if [ "$PREV_TX_ID_JSON" != "null" ]; then
		echo "ERROR (4): invariant 6 (genesis) — receipt.prev_anchor_tx_id must be null for the first line, got: $PREV_TX_ID_JSON" >&2
		exit 4
	fi
fi

# ---- compose new line ----
# R18: archived_source_path / archived_receipt_path are ADDITIVE index
# fields (anchor-history.schema.v2.json is "additionalProperties": true,
# "x-stability": "additive-only-within-v2") pointing at the per-anchor,
# content-addressed archive copies gen-anchor-source.sh and
# gen-anchor-receipt.sh each write under public/api/archive/ — see the R18
# comment blocks in those two scripts for the naming convention
# (anchor-source-<dag_root_hash>.json / anchor-receipt-<tx_id>.json). Both
# dag_root_hash and tx_id are already available on every line regardless
# of event_type, so both fields are always populated; this script does not
# verify the archive files actually exist (that is gen-anchor-source.sh /
# gen-anchor-receipt.sh's job at write time) — this is purely the
# conventional pointer an evaluator follows.
#
# PUBLICATION: writing the archive file is necessary but not sufficient.
# Both archives live under public/api/archive/, which is push-owned (never
# git-tracked, see .gitignore + deploy/feed-excludes.txt), so each one only
# becomes reachable at the URL this field advertises after it is pushed via
#
#   bash scripts/push-to-web-host.sh archive/anchor-source-<dag_root_hash>.json
#   bash scripts/push-to-web-host.sh archive/anchor-receipt-<tx_id>.json
#
# The subdirectory push shape was added 2026-08-05 (push-to-web-host.sh's
# allowlist was flat-filename-only before that, so this field pointed at a
# permanent 404 for every anchor event — the receiving wrapper on the web
# host must also carry the matching subdirectory allowlist, see
# scripts/install-xserver-subdir-allowlist.sh; sender and receiver enforce
# it independently). Until 2026-08-06 the push above was a manual step the
# operator had to remember to run after every anchor event — easy to forget
# (it was), and the failure mode is silent (a 404 nobody notices until an
# evaluator hits it). As of 2026-08-06 THIS SCRIPT runs both pushes itself,
# automatically, right after the atomic append below succeeds — see the
# "R18 publication" block near the end of the file. Publishing from here
# rather than from gen-anchor-source.sh (which runs before signing/
# broadcast) is deliberate: gen-anchor-source.sh writes a fresh archive copy
# for every draft it composes, including ones later abandoned before
# broadcast (this happened 2026-08-04 — dag_root 8a4361f4… was generated but
# never signed), so publishing at generation time would leak orphaned drafts
# to the public archive. Publishing here instead only ever happens for a
# receipt that already passed the verification_status=="live" check above
# AND whose append-only invariants above just succeeded — i.e. strictly
# confirmed, chain-recorded anchors only. Since 2026-08-06 (C3) the push also
# needs FY_LIVE=1; without it the two pushes are announced-and-skipped and the
# manual commands are printed. The APPEND is not gated — see the FY_LIVE entry
# in the header for why the ledger must not depend on that opt-in.
ARCHIVED_SOURCE_PATH="api/archive/anchor-source-${DAG_ROOT}.json"
ARCHIVED_RECEIPT_PATH="api/archive/anchor-receipt-${TX_ID}.json"

if [ "$EVENT_TYPE" = "idrotate" ]; then
	# idrotate: omit cycle_number, include key_seq.
	NEW_LINE_JSON="$(jq -nc \
		--argjson key_seq "$KEY_SEQ" \
		--arg dag_root_hash "$DAG_ROOT" \
		--arg memo_prefix "$MEMO_PREFIX" \
		--arg network "$NETWORK" \
		--arg chain_backend "$CHAIN_BACKEND" \
		--arg method "$METHOD" \
		--arg tx_id "$TX_ID" \
		--argjson block_num "$BLOCK_NUM" \
		--arg block_time "$BLOCK_TIME" \
		--arg explorer_url "$EXPLORER_URL" \
		--arg actor "$ACTOR" \
		--arg permission "$PERMISSION" \
		--arg verified_at "$VERIFIED_AT" \
		--argjson prev_anchor_tx_id "$PREV_TX_ID_JSON" \
		--arg archived_source_path "$ARCHIVED_SOURCE_PATH" \
		--arg archived_receipt_path "$ARCHIVED_RECEIPT_PATH" \
		--arg script_ver "append-anchor-history.sh v${SCRIPT_VERSION}" \
		'{
			schema_version: 2, event_type: "idrotate", key_seq: $key_seq,
			dag_root_hash: $dag_root_hash, memo_prefix: $memo_prefix,
			network: $network, chain: "metal-a-chain", chain_backend: $chain_backend,
			method: $method, tx_id: $tx_id, block_num: $block_num, block_time: $block_time,
			explorer_url: $explorer_url, signing_actor: $actor, signing_permission: $permission,
			verification_status: "live", verified_at: $verified_at,
			prev_anchor_tx_id: $prev_anchor_tx_id,
			archived_source_path: $archived_source_path,
			archived_receipt_path: $archived_receipt_path,
			generated_by_script_version: $script_ver
		}')"
else
	NEW_LINE_JSON="$(jq -nc \
		--arg event_type "$EVENT_TYPE" \
		--argjson cycle_number "$CYCLE_NUMBER" \
		--arg dag_root_hash "$DAG_ROOT" \
		--arg memo_prefix "$MEMO_PREFIX" \
		--arg network "$NETWORK" \
		--arg chain_backend "$CHAIN_BACKEND" \
		--arg method "$METHOD" \
		--arg tx_id "$TX_ID" \
		--argjson block_num "$BLOCK_NUM" \
		--arg block_time "$BLOCK_TIME" \
		--arg explorer_url "$EXPLORER_URL" \
		--arg actor "$ACTOR" \
		--arg permission "$PERMISSION" \
		--arg verified_at "$VERIFIED_AT" \
		--argjson prev_anchor_tx_id "$PREV_TX_ID_JSON" \
		--arg archived_source_path "$ARCHIVED_SOURCE_PATH" \
		--arg archived_receipt_path "$ARCHIVED_RECEIPT_PATH" \
		--arg script_ver "append-anchor-history.sh v${SCRIPT_VERSION}" \
		'{
			schema_version: 2, event_type: $event_type, cycle_number: $cycle_number,
			dag_root_hash: $dag_root_hash, memo_prefix: $memo_prefix,
			network: $network, chain: "metal-a-chain", chain_backend: $chain_backend,
			method: $method, tx_id: $tx_id, block_num: $block_num, block_time: $block_time,
			explorer_url: $explorer_url, signing_actor: $actor, signing_permission: $permission,
			verification_status: "live", verified_at: $verified_at,
			prev_anchor_tx_id: $prev_anchor_tx_id,
			archived_source_path: $archived_source_path,
			archived_receipt_path: $archived_receipt_path,
			generated_by_script_version: $script_ver
		}')"
fi

# ---- R13: mandatory schema validation (fail closed) ------------------------
# Try ajv (local binary, no network) first, then python3's `jsonschema`
# module (also local, no network). If NEITHER is available, refuse to
# append (exit 7) rather than let an unvalidated line join the append-only
# ledger. Duplicated (not sourced) in gen-anchor-source.sh and
# gen-anchor-receipt.sh — no cross-script sourcing convention exists in
# this repo; keep the three in sync if you touch the logic.
schema_validate_or_die() {
	local schema="$1" data_file="$2" label="$3" out
	if [ ! -r "$schema" ]; then
		echo "ERROR (6): schema file not readable: $schema (cannot validate $label)" >&2
		return 6
	fi
	if command -v ajv >/dev/null 2>&1; then
		if out="$(ajv --spec=draft2020 --strict=false validate -s "$schema" -d "$data_file" 2>&1)"; then
			echo "OK: $label schema-valid (ajv)" >&2
			return 0
		fi
		echo "ERROR (6): $label failed schema validation against $schema (ajv)" >&2
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
		echo "ERROR (6): $label failed schema validation against $schema (python3+jsonschema)" >&2
		printf '%s\n' "$out" >&2
		return 6
	fi
	echo "ERROR (7): no JSON schema validator available (ajv absent; python3+jsonschema absent) — refusing to skip validation for $label. Install ajv-cli (npm i -g ajv-cli ajv-formats) or 'pip3 install jsonschema'." >&2
	return 7
}

TMP_VAL="$(mktemp)"
printf '%s' "$NEW_LINE_JSON" > "$TMP_VAL"
if schema_validate_or_die "$SCHEMA_FILE" "$TMP_VAL" "anchor-history line"; then
	rm -f "$TMP_VAL"
else
	schema_rc=$?
	rm -f "$TMP_VAL"
	exit "$schema_rc"
fi

# ---- atomic append (write new file, rename over history) ----
TMP_OUT="$(mktemp -p "$(dirname "$HISTORY")" .anchor-history.XXXXXX)"
if [ -f "$HISTORY" ]; then
	cp "$HISTORY" "$TMP_OUT"
fi
printf '%s\n' "$NEW_LINE_JSON" >> "$TMP_OUT" || {
	echo "ERROR (5): tmp write failed" >&2
	rm -f "$TMP_OUT"
	exit 5
}
mv "$TMP_OUT" "$HISTORY" || {
	echo "ERROR (5): atomic rename failed" >&2
	rm -f "$TMP_OUT"
	exit 5
}

# NOTE (2026-08-06, review round 2): the append-confirmation echo used to
# sit HERE, between the atomic append and the R18 publication block below.
# `|| true` alone (round 1) only protects against a closed-fd write error
# (EBADF, e.g. `bash append-anchor-history.sh >&-`) — that's a normal
# nonzero-exit builtin failure `set -e`/`||` can intercept. It does NOT
# protect against a broken PIPE (e.g. `bash append-anchor-history.sh |
# true`, a reader that exits without reading): writing to a pipe with no
# reader delivers SIGPIPE, which kills this bash process outright — a
# signal death bypasses `||` entirely, `set -e` never gets a chance to
# apply. Reproduced (round 2): under `| true`, history landed but the
# publish block never ran (0 push attempts) — the exact bug this feature
# exists to prevent, and `|| true` alone doesn't close it. The structural
# fix (simpler than a trap): the confirmation echo now runs LAST, after
# publish — see the very end of this file. That way, by the time this
# stdout write could fail (for ANY reason, EBADF or SIGPIPE alike), the
# publish attempts have already happened; reordering, not error-catching,
# is what makes this print's fate irrelevant to whether archives get
# published.

# ---- R18 publication: push the two per-anchor archives (best-effort) ------
# Runs strictly AFTER the append above already succeeded (mv landed) — this
# section can only add a warning, it can never turn a successful append into
# a failed one. See the R18 comment block above ("PUBLICATION") for why this
# runs here and not in the generators (orphan avoidance) and for the
# FYD_PUSH_TO_WEB_HOST / ANCHOR_ARCHIVE_DIR / FYD_NOTIFY env overrides
# (documented in the file header too). Idempotent: re-running this script's
# publish step (or re-pushing by hand with the printed command) just
# overwrites the same bytes at the same remote path.
# PUSH_HINT_BIN is TEXT FOR THE OPERATOR, not an invocation target — the push
# itself goes through fyd_push, which resolves the delegate from the same
# FYD_PUSH_TO_WEB_HOST spelling. It is computed here only so the manual retry
# command printed below names the path the operator would actually run.
PUSH_HINT_BIN="${FYD_PUSH_TO_WEB_HOST:-${REPO_ROOT}/scripts/push-to-web-host.sh}"

# retry_hint <push_arg> — the ONE formatter for the copy-pasteable manual push
# command, so the three places that print it cannot drift. Built through
# printf with the command word inside a format string rather than written
# inline, so that operator guidance which merely NAMES the delegate can never
# be read as an invocation of it — by a human skimming, or by the static gate
# in tests/side-effects-callers/test-anchor-cycle-side-effects.sh.
retry_hint() {
	printf "bash '%s' '%s'" "$PUSH_HINT_BIN" "$1"
}
# ARCHIVE_DIR only decides what THIS SCRIPT treats as "the local archive
# file exists" — see the ANCHOR_ARCHIVE_DIR header comment. It does NOT
# redirect what push-to-web-host.sh actually reads: that script resolves
# its own source path independently from its own REPO_BASE. Test-only.
ARCHIVE_DIR="${ANCHOR_ARCHIVE_DIR:-$(dirname "$HISTORY")/archive}"

alert() {
	# Best-effort: a broken/missing notifier must never mask (or be conflated
	# with) the publish failure it's reporting — mirrors run-anchor-pipeline.sh
	# and gen-*.sh's alert()/notify patterns in this repo.
	#
	# Delivery is gated on FY_LIVE by fyd_notify; the delegate is resolved
	# from FYD_NOTIFY exactly as before. The "notifier not found" branch is
	# gone — the library validates the delegate and returns 64, which lands on
	# the same WARN line.
	fyd_notify "$1" "$2" "$3" >&2 || echo "WARN: notify failed (alert was: $2 — $3)" >&2
}

# publish_archive <local_path> <push_arg> <label>
# Fail-open by design (per the header note): every exit path here is
# non-fatal to this script — a missing local file or a push failure is
# reported loudly (stderr + alert) with the exact manual retry command, and
# the function always returns 0.
#
# Under a dry FY_LIVE, fyd_push suppresses the send and returns 0. That must
# NOT be reported as "OK: published" — a dry run that claims publication is
# the silent-success failure this rollout exists to end — so the confirmation
# branch asks fyd_is_live and prints the manual command instead.
publish_archive() {
	local local_path="$1" push_arg="$2" label="$3" hint
	hint="$(retry_hint "$push_arg")"
	if [ ! -r "$local_path" ]; then
		echo "WARN: R18 publish skipped — $label archive not found locally at $local_path" >&2
		echo "      (history line already recorded its URL; publish once the file exists:)" >&2
		echo "      ${hint}" >&2
		alert high "anchor archive publish skipped: $label missing" \
			"tx_id=$TX_ID dag_root=$DAG_ROOT — $local_path not found locally. Manual command once available: ${hint}"
		return 0
	fi
	if fyd_push "$push_arg" >&2; then
		if fyd_is_live; then
			echo "OK: published $label ($push_arg)" >&2
		else
			echo "DEFERRED: R18 publish of $label ($push_arg) was suppressed (FY_LIVE is not 1)" >&2
			echo "      (history line already recorded its URL; publish it with:)" >&2
			echo "      ${hint}" >&2
		fi
	else
		echo "WARN: R18 publish FAILED for $label ($push_arg)" >&2
		echo "      (history line already recorded its URL; retry manually:)" >&2
		echo "      ${hint}" >&2
		alert high "anchor archive publish failed: $label" \
			"tx_id=$TX_ID dag_root=$DAG_ROOT — push-to-web-host.sh failed. Manual retry: ${hint}"
	fi
	return 0
}

# Kill switch (2026-08-06, review round 1 defense-in-depth): every existing
# caller either stubs FYD_PUSH_TO_WEB_HOST/FYD_NOTIFY (tests) or genuinely
# wants the real push (production pipeline), so this defaults to ON and
# changes nothing for either. It exists for a caller that wants neither —
# a future test or rehearsal script that exercises append-anchor-history.sh
# for its append-only-invariant behavior without wanting ANY outbound call
# attempted, without having to construct stub scripts first.
if [ "${FYD_PUBLISH_ARCHIVES:-1}" = "0" ]; then
	echo "SKIP: R18 archive publish disabled (FYD_PUBLISH_ARCHIVES=0) — history line already recorded the URLs; publish manually when ready:" >&2
	echo "      $(retry_hint "archive/anchor-source-${DAG_ROOT}.json")" >&2
	echo "      $(retry_hint "archive/anchor-receipt-${TX_ID}.json")" >&2
else
	publish_archive "${ARCHIVE_DIR}/anchor-source-${DAG_ROOT}.json" "archive/anchor-source-${DAG_ROOT}.json" "anchor-source"
	publish_archive "${ARCHIVE_DIR}/anchor-receipt-${TX_ID}.json" "archive/anchor-receipt-${TX_ID}.json" "anchor-receipt"
fi

# Confirmation print — deliberately LAST (see the note above, where this
# echo used to sit): every consequential step (append, then publish) has
# already happened by this point, so nothing downstream depends on this
# statement completing. `|| true` still guards the plain EBADF case
# (closed fd, no signal); a SIGPIPE death here (piped stdout, no reader)
# would still kill the process at this final line, but that no longer
# costs the invariant this feature protects — publish already ran.
echo "OK: appended line to $HISTORY (tx_id=$TX_ID)" || true
