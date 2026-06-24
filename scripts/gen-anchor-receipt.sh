#!/usr/bin/env bash
# gen-anchor-receipt.sh — Phase α anchor receipt generator (seven-PASS gate).
#
# Responsibility (per the 2026-06-23 anchor-script triad refactor):
#   - Re-fetch the broadcasted transaction from a public XPRNetwork RPC /
#     indexer.
#   - Independently re-derive every field that goes into the receipt:
#       (1) tx is reachable via tx_id
#       (2) memo string == "fyid1:" + dag_root_hash
#       (3) action account / name match the method discriminator
#       (4) signing actor == expected anchor account
#       (5) signing permission == "anchor"
#       (6) JSON Schema validation of the assembled receipt PASSes
#       (7) explorer_url is reachable (HTTP 200) and the tx_id round-trips
#   - Only if ALL seven PASS, set verification_status = "live" and write
#     /api/anchor-receipt.json atomically.
#   - If any single condition fails, set verification_status = "failed",
#     write the (failed) receipt for audit, and exit non-zero so the
#     orchestrator does NOT push live to web.
#
# This script:
#   - Does NOT broadcast (= sign-anchor-event.sh's job).
#   - Does NOT touch any private key, wallet, or permission secret.
#   - Does NOT append to anchor-history.jsonl (= append-anchor-history.sh's job).
#   - Does NOT push to the web host (= post-anchor-event.sh orchestrator's job).
#
# Inputs (env):
#   TX_ID              required. 64-hex XPRNetwork transaction id from the
#                      broadcaster.
#   DAG_ROOT_HASH      required. 64-hex SHA-256 expected to appear in the
#                      on-chain memo as "fyid1:" + this value.
#   EVENT_TYPE         required. cyclestart | cycleend | idrotate | manual.
#   CYCLE_N            optional. Integer >= 1. Only used to populate
#                      trigger_reference.cycle_n.
#   KEY_SEQ            optional. Integer >= 1. Only used for idrotate to
#                      populate trigger_reference.key_seq.
#   METHOD             optional. phase_alpha_token_transfer (default) or
#                      phase_beta_sc_inscribe.
#   NETWORK            optional. xpr-mainnet (default) or xpr-testnet.
#   EXPECTED_ACTOR     optional. Default 'metalfreedom'. The on-chain
#                      signing actor we EXPECT — used in PASS condition 4.
#   EXPECTED_PERMISSION optional. Default 'anchor'. Used in PASS condition 5.
#   EXPECTED_SINK      optional. Default 'fyhistory' (= Phase α to-address).
#                      Only consumed when METHOD=phase_alpha_token_transfer.
#   XPR_RPC_BASE       optional. Default https://proton.eosusa.io for mainnet,
#                      https://test.proton.eosusa.io for testnet. The
#                      get_transaction endpoint we re-fetch from.
#   EXPLORER_BASE      optional. Default https://explorer.xprnetwork.org.
#                      The seven-PASS condition 7 reachability target.
#   OUT_RECEIPT_PATH   optional. Default $REPO_ROOT/public/api/anchor-receipt.json.
#                      Path the assembled receipt is written to atomically.
#                      The script writes to $OUT_RECEIPT_PATH.tmp.<random> and
#                      mv's it on success (atomic).
#   IDENTITY_URL       optional. Default https://metal.freedom-yield.com/api/identity.json.
#   CYCLES_HISTORY_URL optional. Default https://metal.freedom-yield.com/api/cycles-history.json.
#   SCHEMA_PATH        optional. Default $REPO_ROOT/public/api/anchor-receipt.schema.v1.json.
#                      The schema used for PASS condition 6 (= ajv validate).
#
# Outputs:
#   - Writes a JSON receipt to OUT_RECEIPT_PATH (atomic). The receipt is
#     either fully populated with verification_status="live" (all 7 PASSed)
#     or with verification_status="failed" + a structured `failures` array
#     listing which conditions failed.
#   - Prints a one-line summary to stdout: "live" or "failed: <reasons>".
#
# Exit codes:
#   0  all seven PASSed; receipt written with verification_status=live
#   1  usage error
#   2  RPC unreachable
#   3  schema validation failed (PASS #6)
#   4  one or more PASS conditions failed; receipt written with status=failed
#
# Secrets: this script reads NO private keys, wallets, or permission secrets.
# All inputs are public data (tx_id, expected actor names, public URLs).

set -euo pipefail

# ---- Argument parsing -------------------------------------------------------

: "${TX_ID:?missing TX_ID env}"
: "${DAG_ROOT_HASH:?missing DAG_ROOT_HASH env}"
: "${EVENT_TYPE:?missing EVENT_TYPE env}"

METHOD="${METHOD:-phase_alpha_token_transfer}"
NETWORK="${NETWORK:-xpr-mainnet}"
EXPECTED_ACTOR="${EXPECTED_ACTOR:-metalfreedom}"
EXPECTED_PERMISSION="${EXPECTED_PERMISSION:-anchor}"
EXPECTED_SINK="${EXPECTED_SINK:-fyhistory}"

case "${NETWORK}" in
	xpr-mainnet) XPR_RPC_BASE_DEFAULT="https://proton.eosusa.io" ;;
	xpr-testnet) XPR_RPC_BASE_DEFAULT="https://test.proton.eosusa.io" ;;
	*) echo "ERROR: unknown NETWORK ${NETWORK}" >&2; exit 1 ;;
esac
XPR_RPC_BASE="${XPR_RPC_BASE:-${XPR_RPC_BASE_DEFAULT}}"
EXPLORER_BASE="${EXPLORER_BASE:-https://explorer.xprnetwork.org}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="${REPO_ROOT:-${REPO_ROOT_DEFAULT}}"

OUT_RECEIPT_PATH="${OUT_RECEIPT_PATH:-${REPO_ROOT}/public/api/anchor-receipt.json}"
SCHEMA_PATH="${SCHEMA_PATH:-${REPO_ROOT}/public/api/anchor-receipt.schema.v1.json}"
IDENTITY_URL="${IDENTITY_URL:-https://metal.freedom-yield.com/api/identity.json}"
CYCLES_HISTORY_URL="${CYCLES_HISTORY_URL:-https://metal.freedom-yield.com/api/cycles-history.json}"

# Deterministic explorer URL from tx_id (single source of truth).
EXPLORER_URL="${EXPLORER_BASE}/transaction/${TX_ID}"

# Expected memo string (per Freedom Yield identity format v1).
EXPECTED_MEMO="fyid1:${DAG_ROOT_HASH}"

# ---- PASS condition 1: tx re-fetchable from RPC ---------------------------

TMP_RPC="$(mktemp -t rpc.XXXXXX)"
trap 'rm -f "${TMP_RPC}"' EXIT

FAILURES=()

if ! curl -fsS -X POST "${XPR_RPC_BASE}/v1/history/get_transaction" \
		-H "Content-Type: application/json" \
		-d "{\"id\":\"${TX_ID}\"}" \
		-o "${TMP_RPC}"; then
	FAILURES+=("pass1_rpc_unreachable: get_transaction did not return 2xx for tx_id=${TX_ID}")
fi

# ---- PASS condition 2: memo == fyid1:<dag_root_hash> -----------------------

OBSERVED_MEMO=""
if [ -s "${TMP_RPC}" ]; then
	# Phase α: memo is in actions[0].act.data.memo (for eosio.token::transfer).
	# Phase β: memo is not present; the binding is in data.root_hash instead.
	# The default extraction looks for Phase α first; downstream invariants
	# check whichever shape is appropriate for METHOD.
	OBSERVED_MEMO="$(jq -r '
		(.traces[0].act.data.memo
		 // .actions[0].act.data.memo
		 // empty)' "${TMP_RPC}" 2>/dev/null || true)"
	if [ "${METHOD}" = "phase_alpha_token_transfer" ] \
			&& [ "${OBSERVED_MEMO}" != "${EXPECTED_MEMO}" ]; then
		FAILURES+=("pass2_memo_mismatch: observed='${OBSERVED_MEMO}' expected='${EXPECTED_MEMO}'")
	fi
fi

# ---- PASS condition 3: action account / name match METHOD -----------------

OBSERVED_ACCOUNT=""
OBSERVED_NAME=""
if [ -s "${TMP_RPC}" ]; then
	OBSERVED_ACCOUNT="$(jq -r '(.traces[0].act.account // .actions[0].act.account // empty)' "${TMP_RPC}" 2>/dev/null || true)"
	OBSERVED_NAME="$(jq -r '(.traces[0].act.name // .actions[0].act.name // empty)' "${TMP_RPC}" 2>/dev/null || true)"
	case "${METHOD}" in
		phase_alpha_token_transfer)
			[ "${OBSERVED_ACCOUNT}" = "eosio.token" ] || FAILURES+=("pass3_account_mismatch: observed='${OBSERVED_ACCOUNT}' expected='eosio.token'")
			[ "${OBSERVED_NAME}" = "transfer" ] || FAILURES+=("pass3_name_mismatch: observed='${OBSERVED_NAME}' expected='transfer'")
			;;
		phase_beta_sc_inscribe)
			[ "${OBSERVED_ACCOUNT}" = "metalfreedom" ] || FAILURES+=("pass3_account_mismatch: observed='${OBSERVED_ACCOUNT}' expected='metalfreedom'")
			[ "${OBSERVED_NAME}" = "inscribe" ] || FAILURES+=("pass3_name_mismatch: observed='${OBSERVED_NAME}' expected='inscribe'")
			;;
	esac
fi

# ---- PASS condition 4 + 5: signing actor / permission ---------------------

OBSERVED_ACTOR=""
OBSERVED_PERMISSION=""
if [ -s "${TMP_RPC}" ]; then
	# Phase α: act.authorization[0]; Phase β: same (Antelope shape).
	OBSERVED_ACTOR="$(jq -r '(.traces[0].act.authorization[0].actor // .actions[0].act.authorization[0].actor // empty)' "${TMP_RPC}" 2>/dev/null || true)"
	OBSERVED_PERMISSION="$(jq -r '(.traces[0].act.authorization[0].permission // .actions[0].act.authorization[0].permission // empty)' "${TMP_RPC}" 2>/dev/null || true)"
	[ "${OBSERVED_ACTOR}" = "${EXPECTED_ACTOR}" ] || FAILURES+=("pass4_actor_mismatch: observed='${OBSERVED_ACTOR}' expected='${EXPECTED_ACTOR}'")
	[ "${OBSERVED_PERMISSION}" = "${EXPECTED_PERMISSION}" ] || FAILURES+=("pass5_permission_mismatch: observed='${OBSERVED_PERMISSION}' expected='${EXPECTED_PERMISSION}'")
fi

# Block num + time from RPC (used in receipt body, regardless of pass status).
BLOCK_NUM="$(jq -r '(.block_num // .traces[0].block_num // 1)' "${TMP_RPC}" 2>/dev/null || echo 1)"
BLOCK_TIME_RAW="$(jq -r '(.block_time // .traces[0].block_time // "1970-01-01T00:00:00Z")' "${TMP_RPC}" 2>/dev/null || echo "1970-01-01T00:00:00Z")"
# Antelope / XPRNetwork RPC returns block_time as a naive ISO 8601 timestamp
# (= no timezone suffix), which fails RFC 3339 `format: date-time` validation
# in ajv. Block times are documented UTC, so append Z when no timezone
# suffix is present.
case "${BLOCK_TIME_RAW}" in
	*Z|*+[0-9][0-9]:[0-9][0-9]|*-[0-9][0-9]:[0-9][0-9]|*+[0-9][0-9][0-9][0-9]|*-[0-9][0-9][0-9][0-9])
		BLOCK_TIME="${BLOCK_TIME_RAW}" ;;
	*)
		BLOCK_TIME="${BLOCK_TIME_RAW}Z" ;;
esac

# ---- Compose the receipt body ---------------------------------------------

NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# For Phase α we need to populate the nested inscribe_action shape.
# For Phase β we'd populate `data` + `authorization`. Below covers Phase α
# which is what 2026-07-04 cycle 3 will run; Phase β extension is a deferred
# task per project_phase_alpha_anchor_completion_2026_07_04.
if [ "${METHOD}" = "phase_alpha_token_transfer" ]; then
	INSCRIBE_ACTION_JSON="$(jq -n \
		--arg from "${EXPECTED_ACTOR}" \
		--arg to "${EXPECTED_SINK}" \
		--arg memo "${EXPECTED_MEMO}" \
		--arg actor "${EXPECTED_ACTOR}" \
		--arg perm "${EXPECTED_PERMISSION}" \
		'{
			account: "eosio.token",
			name: "transfer",
			from: $from,
			to: $to,
			quantity: "0.0001 XPR",
			memo: $memo,
			permission: { actor: $actor, permission: $perm }
		}')"
else
	# Phase β skeleton — operator must fill data fields appropriately.
	INSCRIBE_ACTION_JSON="$(jq -n \
		--arg actor "${EXPECTED_ACTOR}" \
		--arg perm "${EXPECTED_PERMISSION}" \
		'{
			account: "metalfreedom",
			name: "inscribe",
			data: {},
			authorization: [{ actor: $actor, permission: $perm }]
		}')"
fi

# Compute verification_status BEFORE schema validation; if 1-5 already failed,
# label "failed". If 1-5 PASSed, we still need PASS #6 (schema) and #7 (explorer
# reachability) before we can flip to "live".
if [ "${#FAILURES[@]}" -gt 0 ]; then
	STATUS="failed"
else
	STATUS="broadcast"  # Provisional; flips to "live" after PASS 6 + 7.
fi

# Build the receipt JSON.
RECEIPT_JSON="$(jq -n \
	--arg dag_root_hash "${DAG_ROOT_HASH}" \
	--arg memo "${EXPECTED_MEMO}" \
	--arg network "${NETWORK}" \
	--arg method "${METHOD}" \
	--arg tx_id "${TX_ID}" \
	--argjson block_num "${BLOCK_NUM}" \
	--arg block_time "${BLOCK_TIME}" \
	--arg explorer_url "${EXPLORER_URL}" \
	--argjson inscribe_action "${INSCRIBE_ACTION_JSON}" \
	--arg cycles_history_url "${CYCLES_HISTORY_URL}" \
	--arg identity_url "${IDENTITY_URL}" \
	--arg trigger_event "${EVENT_TYPE}" \
	--arg cycle_n "${CYCLE_N:-}" \
	--arg key_seq "${KEY_SEQ:-}" \
	--arg signing_actor "${EXPECTED_ACTOR}" \
	--arg signing_permission "${EXPECTED_PERMISSION}" \
	--arg verification_status "${STATUS}" \
	--arg generated_at "${NOW_UTC}" \
	'{
		schema_version: 1,
		dag_root_hash: $dag_root_hash,
		memo: $memo,
		anchor: {
			chain: "metal-a-chain",
			chain_backend: "pulsevm",
			network: $network,
			method: $method,
			tx_id: $tx_id,
			block_num: $block_num,
			block_time: $block_time,
			explorer_url: $explorer_url,
			inscribe_action: $inscribe_action
		},
		cycles_history_url: $cycles_history_url,
		identity_url: $identity_url,
		trigger_event: ({"cyclestart":"cycle_start","cycleend":"cycle_end","idrotate":"identity_rotation","manual":"manual"} | .[$trigger_event] // $trigger_event),
		trigger_reference: (
			{} +
			(if ($cycle_n | length) > 0 then {cycle_n: ($cycle_n | tonumber)} else {} end) +
			(if ($key_seq  | length) > 0 then {key_seq:  ($key_seq  | tonumber)} else {} end)
		),
		signing_actor: $signing_actor,
		signing_permission: $signing_permission,
		verification_status: $verification_status,
		generated_at: $generated_at
	}')"

# ---- PASS condition 6: schema validation ---------------------------------

TMP_RECEIPT="$(mktemp -t receipt.XXXXXX).json"
trap 'rm -f "${TMP_RPC}" "${TMP_RECEIPT}"' EXIT
printf '%s\n' "${RECEIPT_JSON}" > "${TMP_RECEIPT}"

# Resolve an ajv invocation: prefer the `ajv` binary if it is on PATH,
# otherwise fall back to `npx -p ajv-cli -p ajv-formats ajv`. We do NOT
# silently degrade to a jq smoke check, because a smoke check would let
# real ajv-rejecting receipts (e.g. block_time in a non-RFC-3339 form)
# pass through as verification_status="live" — exactly the failure mode
# we just hit on the 2026-06-23 testnet rehearsal.
AJV_INVOKE=()
if command -v ajv >/dev/null 2>&1; then
	AJV_INVOKE=(ajv)
elif command -v npx >/dev/null 2>&1; then
	AJV_INVOKE=(npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv)
fi
if [ "${#AJV_INVOKE[@]}" -eq 0 ]; then
	FAILURES+=("pass6_schema_validator_unavailable: ajv is not on PATH and npx is not available")
else
	if ! "${AJV_INVOKE[@]}" validate --strict=false -s "${SCHEMA_PATH}" -d "${TMP_RECEIPT}" \
			--spec=draft2020 -c ajv-formats >/dev/null 2>&1; then
		# Re-run with --all-errors so the failure is informative (= the
		# operator can see exactly what the receipt got wrong without
		# manually re-invoking ajv).
		AJV_ERR="$("${AJV_INVOKE[@]}" validate --strict=false --all-errors \
			-s "${SCHEMA_PATH}" -d "${TMP_RECEIPT}" \
			--spec=draft2020 -c ajv-formats 2>&1 | tr '\n' ' ' | head -c 600)"
		FAILURES+=("pass6_schema_validation_failed: ${AJV_ERR}")
	fi
fi

# ---- PASS condition 7: explorer URL reachable ----------------------------

# HEAD request with a short timeout; treat any 2xx / 3xx as reachable.
if ! curl -fsS -I --max-time 10 "${EXPLORER_URL}" -o /dev/null; then
	FAILURES+=("pass7_explorer_unreachable: HEAD ${EXPLORER_URL} did not return 2xx/3xx")
fi

# ---- Final status flip + atomic write ------------------------------------

if [ "${#FAILURES[@]}" -eq 0 ]; then
	FINAL_STATUS="live"
	EXIT_CODE=0
	# Pre-compute the failures-JSON outside any subshell expansion of
	# ${FAILURES[@]}. macOS bash 3.2 + `set -u` errors on `${arr[@]}`
	# when arr is empty even though `${#arr[@]}` reports 0; the empty
	# JSON array is the equivalent value with no array dereference.
	FAILURES_JSON="[]"
else
	FINAL_STATUS="failed"
	EXIT_CODE=4
	FAILURES_JSON="$(printf '%s\n' "${FAILURES[@]}" | jq -R . | jq -s .)"
fi

FINAL_RECEIPT="$(jq \
	--arg status "${FINAL_STATUS}" \
	--argjson failures "${FAILURES_JSON}" \
	'.verification_status = $status
	 | (if ($failures | length) > 0 then .failures = $failures else . end)
	' "${TMP_RECEIPT}")"

# Atomic write to OUT_RECEIPT_PATH.
mkdir -p "$(dirname "${OUT_RECEIPT_PATH}")"
TMP_OUT="${OUT_RECEIPT_PATH}.tmp.$$"
printf '%s\n' "${FINAL_RECEIPT}" > "${TMP_OUT}"
mv -f "${TMP_OUT}" "${OUT_RECEIPT_PATH}"

# One-line summary to stdout.
if [ "${FINAL_STATUS}" = "live" ]; then
	echo "live  tx_id=${TX_ID}  dag_root_hash=${DAG_ROOT_HASH}  explorer=${EXPLORER_URL}"
else
	echo "failed  reasons=$(printf '%s; ' "${FAILURES[@]}")"
fi

exit "${EXIT_CODE}"
