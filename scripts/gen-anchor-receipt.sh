#!/usr/bin/env bash
# gen-anchor-receipt.sh v2 — HC-single 4-action pack receipt generator.
#
# CHAIN: none — this script fetches an already-broadcast tx from a public
#        Hyperion / XPRNetwork RPC and re-derives every receipt field
#        independently, then writes /api/anchor-receipt.json.
# PRIME_DIRECTIVE: TESTNET-FIRST — this script does not broadcast; it
#                  reads. Safe under tier-1 hook.
#
# 2026-07-01 rewrite: consumes new sign-anchor-event.sh v2 output
# (tx_id + actions[4] + memo_prefix), emits v2 receipt matching
# public/api/anchor-receipt.schema.v2.json. Replaces the single-action
# fyid1:<hash> verify pipeline.
#
# 2026-09-30 (PulseVM migration readiness, Task 4): chain-aware.
#   * The history base comes from the selected A-Chain profile
#     (config/a-chain-profiles.json via scripts/lib/a-chain-profile.sh), not
#     from a literal. --rpc must be one of that profile's history_bases;
#     --allow-unlisted-rpc accepts another base for the TESTNET role only
#     (rehearsal escape hatch, loud WARN) and is refused for mainnet.
#   * The tx is resolved by scripts/lib/anchor-history-read.sh — the same
#     code scripts/check-anchor-history-reachable.sh runs BEFORE signing, so
#     a history outage is caught before the irreversible broadcast (P3).
#     The v1 fallback now parses `traces` (it used to expect `.actions`,
#     which /v1/history/get_transaction never returns).
#   * The receipt records anchor.chain_id (the profile's, reconciled with
#     FYD_<ROLE>_CHAIN_ID), anchor.chain_profile, anchor.history_base and
#     anchor.block_id (from history, else /v1/chain/get_block).
#   * Receipt schema: v2 by default when the selected profile is the role's
#     default (xpr-mainnet / xpr-testnet) — the new fields are ADDITIVE v2
#     fields (anchor-receipt.schema.v2.json is additive-only-within-v2), and
#     block_id is best-effort (omitted with a WARN when history serves none),
#     so the legacy-chain path adds no new failure after a broadcast.
#     --receipt-schema=v3 produces a v3 receipt (schema_version 3, block_id
#     REQUIRED) on any profile, including the legacy chain. A non-default
#     profile (pulsevm-*) REQUIRES v3: v2 is refused, so no v2-only consumer
#     can mistake a post-migration receipt for a legacy one.
#
# 7 verify gates (all must PASS or exit 4):
#   1. tx reachable via tx_id at a history base of the selected profile
#   2. tx has exactly 4 actions
#   3. all 4 actions are eosio.token::transfer
#   4. all 4 authorizations match expected actor@permission
#   5. memo set matches expected {prefix}-{id|ob|ar|(summary)}:<hex>
#   6. dag_root_summary root_hex == sha256(id_root || ob_root || ar_root)
#   7. block_num + block_time present on tx (v3: block_id too)
#
# Exit codes:
#   0  success — 7-PASS verified, receipt written to --out
#   1  usage / arg error, including: the chain profile is unavailable or
#      refuses the network (e.g. a pulsevm profile whose chain_id is not yet
#      published), --rpc not in the profile's history_bases, or
#      --receipt-schema=v2 with a non-default profile. Nothing was fetched.
#   2  input parse error
#   3  RPC unreachable / tx_id not found at any history base
#      (v3: also block_id not obtainable)
#   4  one of the 7 verify gates failed
#   5  atomic write failed (canonical --out file OR the R18 archive copy)
#   6  R13: receipt failed schema validation against
#      public/api/anchor-receipt.schema.v2.json / .v3.json (or the schema
#      file itself is unreadable)
#   7  R13: no JSON schema validator available (ajv absent AND python3's
#      jsonschema module absent) — fail-closed rather than silently skip
#      validation. Provision one: `npm i -g ajv-cli ajv-formats` or
#      `pip3 install jsonschema` on the host that runs this script.
#
# Usage:
#   gen-anchor-receipt.sh --input=<sign-anchor-event.json>
#                         --anchor-source=<anchor-source.json>
#                         [--out=<path>] [--rpc=<history base url>]
#                         [--allow-unlisted-rpc]   (testnet only)
#                         [--receipt-schema=<v2|v3>]
#                         [--explorer-base=<url>]
#                         [--trigger=<cyclestart|cycleend|idrotate|heartbeat|manual>]
#                         [--schema-url=<url>]
#                         [--prev-anchor-tx-id=<64hex|null>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_VERSION="2.0"

INPUT_FILE=""
ANCHOR_SOURCE=""
OUT_FILE="${REPO_ROOT}/public/api/anchor-receipt.json"
RPC_OVERRIDE=""
# Empty = the selected chain profile's explorer_base (resolved below).
EXPLORER_BASE="${EXPLORER_BASE:-}"
TRIGGER="manual"
SCHEMA_URL=""   # empty = the published URL of the selected receipt schema
# R13: LOCAL schema file used to self-validate the composed receipt before
# it is written (see schema_validate_or_die below). Distinct from
# $SCHEMA_URL, which is only the "$schema" field value embedded in the
# receipt for downstream consumers.
# Empty = public/api/anchor-receipt.schema.<v2|v3>.json for the selected version.
SCHEMA_FILE="${SCHEMA_FILE:-}"
PREV_ANCHOR_TX_ID_ARG=""
ALLOW_UNLISTED_RPC=0
RECEIPT_SCHEMA=""

for arg in "$@"; do
	case "$arg" in
		--input=*)               INPUT_FILE="${arg#*=}" ;;
		--anchor-source=*)       ANCHOR_SOURCE="${arg#*=}" ;;
		--out=*)                 OUT_FILE="${arg#*=}" ;;
		--rpc=*)                 RPC_OVERRIDE="${arg#*=}" ;;
		--allow-unlisted-rpc)    ALLOW_UNLISTED_RPC=1 ;;
		--receipt-schema=*)      RECEIPT_SCHEMA="${arg#*=}" ;;
		--explorer-base=*)       EXPLORER_BASE="${arg#*=}" ;;
		--trigger=*)             TRIGGER="${arg#*=}" ;;
		--schema-url=*)          SCHEMA_URL="${arg#*=}" ;;
		--prev-anchor-tx-id=*)   PREV_ANCHOR_TX_ID_ARG="${arg#*=}" ;;
		-h|--help)               sed -n '2,76p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)                       echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

# Read --input from file, or from stdin if unspecified.
if [ -z "$INPUT_FILE" ]; then
	INPUT_JSON="$(cat)"
elif [ ! -r "$INPUT_FILE" ]; then
	echo "ERROR (2): input file not readable: $INPUT_FILE" >&2
	exit 2
else
	INPUT_JSON="$(cat "$INPUT_FILE")"
fi

if [ -z "$ANCHOR_SOURCE" ]; then
	echo "ERROR: --anchor-source=<file> required" >&2
	exit 1
fi
if [ ! -r "$ANCHOR_SOURCE" ]; then
	echo "ERROR (2): anchor-source not readable: $ANCHOR_SOURCE" >&2
	exit 2
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
	echo "ERROR: jq + curl required" >&2
	exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
	if command -v shasum >/dev/null 2>&1; then
		sha256_pipe() { shasum -a 256 | awk '{print $1}'; }
	else
		echo "ERROR: sha256sum or shasum required" >&2
		exit 1
	fi
else
	sha256_pipe() { sha256sum | awk '{print $1}'; }
fi

case "$TRIGGER" in
	cyclestart|cycleend|idrotate|heartbeat|manual) ;;
	*) echo "ERROR: --trigger must be cyclestart|cycleend|idrotate|heartbeat|manual, got: $TRIGGER" >&2; exit 1 ;;
esac

if [ -z "$PREV_ANCHOR_TX_ID_ARG" ] || [ "$PREV_ANCHOR_TX_ID_ARG" = "null" ]; then
	PREV_ANCHOR_TX_ID_JSON="null"
elif echo "$PREV_ANCHOR_TX_ID_ARG" | grep -qE '^[a-f0-9]{64}$'; then
	PREV_ANCHOR_TX_ID_JSON="\"$PREV_ANCHOR_TX_ID_ARG\""
else
	echo "ERROR: --prev-anchor-tx-id must be 64-hex or 'null', got: $PREV_ANCHOR_TX_ID_ARG" >&2
	exit 1
fi

# ---- parse sign-anchor-event JSON input ----
if ! echo "$INPUT_JSON" | jq -e '.tx_id and .actions and .memo_prefix' >/dev/null 2>&1; then
	echo "ERROR (2): input JSON missing required fields (tx_id / actions / memo_prefix)" >&2
	exit 2
fi

TX_ID="$(echo "$INPUT_JSON" | jq -r '.tx_id')"
NETWORK="$(echo "$INPUT_JSON" | jq -r '.network')"
MEMO_PREFIX="$(echo "$INPUT_JSON" | jq -r '.memo_prefix')"
CYCLE_NUM="$(echo "$INPUT_JSON" | jq -r '.cycle_number')"
SCHEMA_VER_SRC="$(echo "$INPUT_JSON" | jq -r '.schema_version')"
ACTOR="$(echo "$INPUT_JSON" | jq -r '.authorization.actor')"
PERMISSION="$(echo "$INPUT_JSON" | jq -r '.authorization.permission')"
SINK="$(echo "$INPUT_JSON" | jq -r '.sink')"
QUANTITY="$(echo "$INPUT_JSON" | jq -r '.quantity')"
DAG_ROOT="$(echo "$INPUT_JSON" | jq -r '.actions[] | select(.branch == "dag_root_summary") | .root_hex')"
ID_ROOT="$(echo "$INPUT_JSON" | jq -r '.actions[] | select(.branch == "identity") | .root_hex')"
OB_ROOT="$(echo "$INPUT_JSON" | jq -r '.actions[] | select(.branch == "observations") | .root_hex')"
AR_ROOT="$(echo "$INPUT_JSON" | jq -r '.actions[] | select(.branch == "artifacts") | .root_hex')"

# ---- chain profile: role, chain_id, history bases, receipt schema --------
# Everything chain-specific comes from the selected profile. Every failure
# here is exit 1 and happens BEFORE any network request.
for lib in a-chain-profile.sh anchor-history-read.sh; do
	if [ ! -r "${REPO_ROOT}/scripts/lib/${lib}" ]; then
		echo "ERROR: required library not readable: scripts/lib/${lib} (is the checkout complete? config/ and scripts/lib/ arrive together)" >&2
		exit 1
	fi
done
# shellcheck source=scripts/lib/a-chain-profile.sh
. "${REPO_ROOT}/scripts/lib/a-chain-profile.sh" || { echo "ERROR: cannot load scripts/lib/a-chain-profile.sh" >&2; exit 1; }
# shellcheck source=scripts/lib/anchor-history-read.sh
. "${REPO_ROOT}/scripts/lib/anchor-history-read.sh"

ROLE="$(acp_role_of_chain "$NETWORK")" \
	|| { echo "ERROR: unknown network for RPC selection: $NETWORK" >&2; exit 1; }
CHAIN_PROFILE="$(acp_profile_name "$ROLE")" \
	|| { echo "ERROR: no usable A-Chain profile for role $ROLE (see a-chain-profile message above)" >&2; exit 1; }
CHAIN_ID="$(acp_expected_chain_id "$ROLE")" \
	|| { echo "ERROR: profile $CHAIN_PROFILE has no usable chain_id for role $ROLE — refusing to write a receipt that cannot name its chain" >&2; exit 1; }
if [ "$ROLE" = "mainnet" ]; then DEFAULT_PROFILE="$ACP_DEFAULT_MAINNET"; else DEFAULT_PROFILE="$ACP_DEFAULT_TESTNET"; fi

case "$RECEIPT_SCHEMA" in
	"")
		if [ "$CHAIN_PROFILE" = "$DEFAULT_PROFILE" ]; then RECEIPT_SCHEMA=v2; else RECEIPT_SCHEMA=v3; fi ;;
	v2)
		if [ "$CHAIN_PROFILE" != "$DEFAULT_PROFILE" ]; then
			echo "ERROR: --receipt-schema=v2 refused for non-default profile $CHAIN_PROFILE — a post-migration receipt must be v3 so v2-only consumers cannot mistake it for a legacy-chain receipt" >&2
			exit 1
		fi ;;
	v3) ;;
	*) echo "ERROR: --receipt-schema must be v2 or v3, got: $RECEIPT_SCHEMA" >&2; exit 1 ;;
esac
RECEIPT_SCHEMA_VERSION="${RECEIPT_SCHEMA#v}"
[ -n "$SCHEMA_URL" ]  || SCHEMA_URL="https://metal.freedom-yield.com/api/anchor-receipt.schema.${RECEIPT_SCHEMA}.json"
[ -n "$SCHEMA_FILE" ] || SCHEMA_FILE="${REPO_ROOT}/public/api/anchor-receipt.schema.${RECEIPT_SCHEMA}.json"

if [ -z "$EXPLORER_BASE" ]; then
	EXPLORER_BASE="$(acp_explorer_base "$ROLE")" \
		|| { echo "ERROR: profile $CHAIN_PROFILE has no explorer_base; pass --explorer-base=<url>" >&2; exit 1; }
fi

BASES="$(ahr_select_bases "$ROLE" "$RPC_OVERRIDE" "$ALLOW_UNLISTED_RPC")" \
	|| { echo "ERROR: no permitted history base for profile $CHAIN_PROFILE (see message above)" >&2; exit 1; }

# ---- gate 1: fetch tx by tx_id ----
# scripts/lib/anchor-history-read.sh ahr_resolve_tx: Hyperion v2
# get_actions (account-scoped) → Hyperion v2 get_transaction → v1
# get_transaction (traces). The first base that resolves the tx wins.
TX_JSON=""
RPC=""
for base in $BASES; do
	if TX_JSON="$(ahr_resolve_tx "$base" "$TX_ID" "$ACTOR")"; then
		RPC="$base"
		break
	fi
	TX_JSON=""
done

if [ -z "$TX_JSON" ] || ! echo "$TX_JSON" | jq -e '.actions | length > 0' >/dev/null 2>&1; then
	echo "ERROR (3): gate 1 — tx_id $TX_ID not resolvable at $(printf '%s' "$BASES" | tr '\n' ' ')(profile $CHAIN_PROFILE; tried Hyperion v2 get_actions + get_transaction + v1)" >&2
	exit 3
fi
FETCHED_ACTIONS_LEN="$(echo "$TX_JSON" | jq '.actions | length')"
echo "OK: gate 1 — resolved at $RPC via $(echo "$TX_JSON" | jq -r .via)" >&2

if [ "$FETCHED_ACTIONS_LEN" -ne 4 ]; then
	echo "ERROR (4): gate 2 — expected 4 actions, got: $FETCHED_ACTIONS_LEN" >&2
	exit 4
fi

NON_TRANSFER_COUNT="$(echo "$TX_JSON" | jq '[.actions[] | select(.act.account != "eosio.token" or .act.name != "transfer")] | length')"
if [ "$NON_TRANSFER_COUNT" -ne 0 ]; then
	echo "ERROR (4): gate 3 — $NON_TRANSFER_COUNT action(s) are not eosio.token::transfer" >&2
	exit 4
fi

BAD_AUTH_COUNT="$(echo "$TX_JSON" | jq --arg a "$ACTOR" --arg p "$PERMISSION" \
	'[.actions[] | select(.act.authorization[0].actor != $a or .act.authorization[0].permission != $p)] | length')"
if [ "$BAD_AUTH_COUNT" -ne 0 ]; then
	echo "ERROR (4): gate 4 — $BAD_AUTH_COUNT action(s) have unexpected authorization" >&2
	exit 4
fi

EXPECTED_MEMOS="$(jq -n \
	--arg p "$MEMO_PREFIX" \
	--arg id "$ID_ROOT" --arg ob "$OB_ROOT" --arg ar "$AR_ROOT" --arg dg "$DAG_ROOT" \
	'["\($p)-id:\($id)","\($p)-ob:\($ob)","\($p)-ar:\($ar)","\($p):\($dg)"] | sort')"
ACTUAL_MEMOS="$(echo "$TX_JSON" | jq '[.actions[] | .act.data.memo] | sort')"
if [ "$EXPECTED_MEMOS" != "$ACTUAL_MEMOS" ]; then
	echo "ERROR (4): gate 5 — memo set mismatch" >&2
	echo "  expected: $(echo "$EXPECTED_MEMOS" | jq -c .)" >&2
	echo "  actual:   $(echo "$ACTUAL_MEMOS" | jq -c .)" >&2
	exit 4
fi

COMPUTED_DAG="$(printf '%s%s%s' "$ID_ROOT" "$OB_ROOT" "$AR_ROOT" | sha256_pipe)"
if [ "$COMPUTED_DAG" != "$DAG_ROOT" ]; then
	echo "ERROR (4): gate 6 — dag_root_summary != sha256(id||ob||ar)" >&2
	echo "  computed: $COMPUTED_DAG" >&2
	echo "  claimed:  $DAG_ROOT" >&2
	exit 4
fi

BLOCK_NUM="$(echo "$TX_JSON" | jq -r '.block_num // empty')"
BLOCK_TIME_RAW="$(echo "$TX_JSON" | jq -r '.block_time // empty')"
if [ -z "$BLOCK_NUM" ] || [ -z "$BLOCK_TIME_RAW" ]; then
	echo "ERROR (4): gate 7 — block_num or block_time missing from RPC response" >&2
	exit 4
fi
BLOCK_TIME="${BLOCK_TIME_RAW}"
case "$BLOCK_TIME" in
	*Z|*+*|*-*) ;;
	*) BLOCK_TIME="${BLOCK_TIME}Z" ;;
esac

# ---- block_id: from history, else /v1/chain/get_block on the same base ----
# v2 (legacy default): best-effort — a missing block_id is a WARN and the
#   field is omitted, so the XPR path gains no new post-broadcast failure.
# v3: required — exit 3 (like an unresolvable tx: re-run later, do NOT
#   re-broadcast). check-anchor-history-reachable.sh proves before signing
#   that the base serves it.
BLOCK_ID="$(echo "$TX_JSON" | jq -r '.block_id // empty')"
if [ -z "$BLOCK_ID" ]; then
	BLOCK_ID="$(ahr_block_id "$RPC" "$BLOCK_NUM" || true)"
fi
if [ -z "$BLOCK_ID" ]; then
	if [ "$RECEIPT_SCHEMA" = "v3" ]; then
		echo "ERROR (3): gate 7 — block_id for block $BLOCK_NUM not served by $RPC (history nor get_block); a v3 receipt requires it. The broadcast itself is NOT in question — re-run later, do NOT re-broadcast." >&2
		exit 3
	fi
	echo "WARN: block_id for block $BLOCK_NUM not served by $RPC — omitted from this v2 receipt" >&2
fi

# ---- compose receipt (v2 by default; v3 on request / non-default profile) ----
ANCHOR_SOURCE_URL="https://metal.freedom-yield.com/api/anchor-source.json"
ANCHOR_SOURCE_SHA256="$(sha256_pipe < "$ANCHOR_SOURCE")"
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EXPLORER_URL="${EXPLORER_BASE}/${TX_ID}"

RECEIPT_JSON="$(jq -n \
	--arg schema_url "$SCHEMA_URL" \
	--argjson schema_version_of_source "$SCHEMA_VER_SRC" \
	--argjson cycle_number "$CYCLE_NUM" \
	--arg dag_root_hash "$DAG_ROOT" \
	--arg memo_prefix "$MEMO_PREFIX" \
	--arg tx_id "$TX_ID" \
	--argjson block_num "$BLOCK_NUM" \
	--arg block_time "$BLOCK_TIME" \
	--arg explorer_url "$EXPLORER_URL" \
	--arg network "$NETWORK" \
	--arg actor "$ACTOR" \
	--arg perm "$PERMISSION" \
	--arg sink "$SINK" \
	--arg qty "$QUANTITY" \
	--arg id_root "$ID_ROOT" \
	--arg ob_root "$OB_ROOT" \
	--arg ar_root "$AR_ROOT" \
	--arg anchor_source_url "$ANCHOR_SOURCE_URL" \
	--arg anchor_source_sha256 "$ANCHOR_SOURCE_SHA256" \
	--argjson prev_anchor_tx_id "$PREV_ANCHOR_TX_ID_JSON" \
	--arg trigger "$TRIGGER" \
	--arg now "$NOW" \
	--argjson schema_version "$RECEIPT_SCHEMA_VERSION" \
	--arg chain_id "$CHAIN_ID" \
	--arg chain_profile "$CHAIN_PROFILE" \
	--arg history_base "$RPC" \
	--arg block_id "$BLOCK_ID" \
	--arg script_ver "gen-anchor-receipt.sh v${SCRIPT_VERSION}" \
	'{
		"$schema": $schema_url,
		schema_version: $schema_version,
		schema_version_of_source: $schema_version_of_source,
		cycle_number: $cycle_number,
		dag_root_hash: $dag_root_hash,
		memo_prefix: $memo_prefix,
		anchor: ({
			chain: "metal-a-chain",
			# chain_backend names the PROTOCOL FAMILY this script observes, not an
			# execution engine. Evidenced by the dependencies of this very script:
			# the tx is resolved through Antelope/EOSIO history interfaces (Hyperion
			# /v2/history/get_actions or get_transaction, then
			# /v1/history/get_transaction — scripts/lib/anchor-history-read.sh) and gates
			# 3-4 above assert the Antelope action model (eosio.token::transfer with
			# actor@permission authorization). Everything published here is something
			# the script actually checked.
			#
			# WHEN TO CHANGE THIS: family and engine are different axes, so a new
			# engine underneath (PulseVM is the one announced for this chain) does
			# NOT by itself make "antelope" false — it stays true for as long as the
			# two gates above keep passing on Antelope-shaped actions. Change the
			# literal only when this script can observe the difference: i.e. when
			# the resolution path above stops being an Antelope/EOSIO interface, or
			# when the script is extended to read an engine identifier from the
			# chain (it reads none today — it never calls /v1/chain/get_info). Do
			# not substitute an engine name for the family name on the strength of
			# an announcement; that is the exact defect this literal used to carry.
			# Changing it means updating, in the same commit:
			#   scripts/append-anchor-history.sh   (fallback default)
			#   tests/gen-anchor-receipt/test-r13-r18-schema-archive.sh   (pinned value)
			#   tests/append-anchor-history/test-append-anchor-history.sh (pinned value)
			#   public/api/anchor-{receipt,history}.schema.v{1,2,3}.json  (description)
			#   public/api/anchor-receipt*.example.json, anchor-history.example.jsonl
			chain_backend: "antelope",
			network: $network,
			method: "hc_single_4_action_pack",
			tx_id: $tx_id,
			block_num: $block_num,
			block_time: $block_time,
			explorer_url: $explorer_url,
			actions: [
				{branch: "identity",         memo: "\($memo_prefix)-id:\($id_root)",  root_hex: $id_root},
				{branch: "observations",     memo: "\($memo_prefix)-ob:\($ob_root)",  root_hex: $ob_root},
				{branch: "artifacts",        memo: "\($memo_prefix)-ar:\($ar_root)",  root_hex: $ar_root},
				{branch: "dag_root_summary", memo: "\($memo_prefix):\($dag_root_hash)",   root_hex: $dag_root_hash}
			],
			authorization: {actor: $actor, permission: $perm},
			sink: $sink,
			quantity: $qty
		} + {
			# 2026-09-30 chain discrimination (additive in v2, required in v3):
			# which chain this tx is on, which reviewed profile said so, which
			# history base verified it, and the block that holds it.
			chain_id: $chain_id,
			chain_profile: $chain_profile,
			history_base: $history_base
		} + (if $block_id == "" then {} else {block_id: $block_id} end)),
		anchor_source_url: $anchor_source_url,
		anchor_source_sha256: $anchor_source_sha256,
		prev_anchor_tx_id: $prev_anchor_tx_id,
		trigger_event: $trigger,
		signing_actor: $actor,
		signing_permission: $perm,
		verification_status: "live",
		verified_at: $now,
		generated_at: $now,
		generated_by_script_version: $script_ver
	}')"

# ---- R13: mandatory schema validation (fail closed) --------------------
# Try ajv (local binary, no network) first, then python3's `jsonschema`
# module (also local, no network). If NEITHER is available, refuse to
# proceed (exit 7) rather than let an unvalidated receipt reach the anchor
# ledger. Duplicated (not sourced) in gen-anchor-source.sh and
# append-anchor-history.sh — no cross-script sourcing convention exists in
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
printf '%s' "$RECEIPT_JSON" > "$TMP_VAL"
if schema_validate_or_die "$SCHEMA_FILE" "$TMP_VAL" "anchor-receipt.json"; then
	rm -f "$TMP_VAL"
else
	schema_rc=$?
	rm -f "$TMP_VAL"
	exit "$schema_rc"
fi

if [ "$OUT_FILE" = "-" ]; then
	printf '%s\n' "$RECEIPT_JSON"
	exit 0
fi

TMP_OUT="$(mktemp -p "$(dirname "$OUT_FILE")" .anchor-receipt.XXXXXX)"
printf '%s\n' "$RECEIPT_JSON" > "$TMP_OUT" || {
	echo "ERROR (5): tmp write failed" >&2
	rm -f "$TMP_OUT"
	exit 5
}
mv "$TMP_OUT" "$OUT_FILE" || {
	echo "ERROR (5): atomic rename failed" >&2
	rm -f "$TMP_OUT"
	exit 5
}

echo "OK: 7-PASS verified, receipt written to $OUT_FILE (tx_id=$TX_ID)"

# ---- R18: durable per-anchor archive copy ------------------------------
# $OUT_FILE (public/api/anchor-receipt.json) is the CANONICAL "current"
# receipt — the next anchor event overwrites it, so without this, a past
# cycle's receipt is lost and can no longer be independently re-verified
# against its on-chain tx. Archive a byte-identical copy keyed by tx_id
# (content-addressed: unique per anchor event by construction — the same
# tx_id can never legally recur, see append-anchor-history.sh invariant 1
# — and it's exactly the value an evaluator already has from the explorer
# link). This runs strictly after the canonical write above succeeds and
# archives the SAME $RECEIPT_JSON bytes already validated + written to
# $OUT_FILE — it never re-derives or alters the composed content.
ARCHIVE_DIR="${ANCHOR_RECEIPT_ARCHIVE_DIR:-$(dirname "$OUT_FILE")/archive}"
mkdir -p "$ARCHIVE_DIR" || {
	echo "ERROR (5): cannot create archive dir: $ARCHIVE_DIR" >&2
	exit 5
}
ARCHIVE_FILE="${ARCHIVE_DIR}/anchor-receipt-${TX_ID}.json"
TMP_ARCHIVE="$(mktemp -p "$ARCHIVE_DIR" .anchor-receipt-archive.XXXXXX)"
printf '%s\n' "$RECEIPT_JSON" > "$TMP_ARCHIVE" || {
	echo "ERROR (5): archive temp write failed" >&2
	rm -f "$TMP_ARCHIVE"
	exit 5
}
mv "$TMP_ARCHIVE" "$ARCHIVE_FILE" || {
	echo "ERROR (5): archive atomic rename failed" >&2
	rm -f "$TMP_ARCHIVE"
	exit 5
}
echo "OK: archived $ARCHIVE_FILE"
