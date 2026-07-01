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
# 7 verify gates (all must PASS or exit 4):
#   1. tx reachable via tx_id at RPC
#   2. tx has exactly 4 actions
#   3. all 4 actions are eosio.token::transfer
#   4. all 4 authorizations match expected actor@permission
#   5. memo set matches expected {prefix}-{id|ob|ar|(summary)}:<hex>
#   6. dag_root_summary root_hex == sha256(id_root || ob_root || ar_root)
#   7. block_num + block_time present on tx
#
# Exit codes:
#   0  success — 7-PASS verified, receipt written to --out
#   1  usage / arg error
#   2  input parse error
#   3  RPC unreachable / tx_id not found
#   4  one of the 7 verify gates failed
#   5  atomic write failed
#
# Usage:
#   gen-anchor-receipt.sh --input=<sign-anchor-event.json>
#                         --anchor-source=<anchor-source.json>
#                         [--out=<path>] [--rpc=<hyperion-url>]
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
EXPLORER_BASE="${EXPLORER_BASE:-https://explorer.xprnetwork.org/transaction}"
TRIGGER="manual"
SCHEMA_URL="https://metal.freedom-yield.com/api/anchor-receipt.schema.v2.json"
PREV_ANCHOR_TX_ID_ARG=""

for arg in "$@"; do
	case "$arg" in
		--input=*)               INPUT_FILE="${arg#*=}" ;;
		--anchor-source=*)       ANCHOR_SOURCE="${arg#*=}" ;;
		--out=*)                 OUT_FILE="${arg#*=}" ;;
		--rpc=*)                 RPC_OVERRIDE="${arg#*=}" ;;
		--explorer-base=*)       EXPLORER_BASE="${arg#*=}" ;;
		--trigger=*)             TRIGGER="${arg#*=}" ;;
		--schema-url=*)          SCHEMA_URL="${arg#*=}" ;;
		--prev-anchor-tx-id=*)   PREV_ANCHOR_TX_ID_ARG="${arg#*=}" ;;
		-h|--help)               sed -n '2,42p' "$0" | sed 's/^# \?//'; exit 0 ;;
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

if [ -n "$RPC_OVERRIDE" ]; then
	RPC="$RPC_OVERRIDE"
else
	case "$NETWORK" in
		mainnet-a|xpr-mainnet|proton) RPC="https://proton.eosusa.io" ;;
		testnet-a|xpr-testnet|proton-test) RPC="https://test.proton.eosusa.io" ;;
		*) echo "ERROR: unknown network for RPC selection: $NETWORK" >&2; exit 1 ;;
	esac
fi

# ---- gate 1: fetch tx by tx_id ----
TX_JSON="$(curl -sSf --max-time 15 \
	-X POST -H 'content-type:application/json' \
	-d "{\"id\":\"${TX_ID}\"}" \
	"${RPC}/v1/history/get_transaction" 2>/dev/null || echo '{}')"

if ! echo "$TX_JSON" | jq -e '.id == "'"${TX_ID}"'"' >/dev/null 2>&1; then
	echo "ERROR (3): gate 1 — tx_id $TX_ID not resolvable at $RPC" >&2
	exit 3
fi

FETCHED_ACTIONS_LEN="$(echo "$TX_JSON" | jq '.actions | length')"
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

# ---- compose v2 receipt ----
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
	--arg script_ver "gen-anchor-receipt.sh v${SCRIPT_VERSION}" \
	'{
		"$schema": $schema_url,
		schema_version: 2,
		schema_version_of_source: $schema_version_of_source,
		cycle_number: $cycle_number,
		dag_root_hash: $dag_root_hash,
		memo_prefix: $memo_prefix,
		anchor: {
			chain: "metal-a-chain",
			chain_backend: "pulsevm",
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
		},
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
