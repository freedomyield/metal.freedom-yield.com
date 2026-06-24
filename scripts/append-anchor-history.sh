#!/usr/bin/env bash
# append-anchor-history.sh — Append a verified anchor receipt as a new
# line on /api/anchor-history.jsonl with append-only invariants enforced.
#
# Responsibility (per the 2026-06-23 anchor-script triad refactor):
#   - Read a live anchor-receipt.json (= verification_status == "live" or
#     "failed" — both are appendable; "live" is the normal case, "failed"
#     records an abandoned anchor for audit).
#   - Project the receipt onto the smaller per-line anchor-history schema
#     (= persistent identity of the anchor, no volatile pointer metadata).
#   - Enforce append-only invariants against the existing JSONL ledger:
#       (a) tx_id is globally unique across all lines
#       (b) (cycle_n, event_type) pair is unique across all lines
#       (c) cycle_n is non-decreasing line-to-line
#       (d) existing lines are byte-for-byte preserved (= never rewritten)
#       (e) the file terminates with a single LF on the final line
#   - JSON-Schema-validate the new line against
#     /api/anchor-history.schema.v1.json before appending.
#   - Atomically rewrite the file with the new line appended on success.
#
# This script:
#   - Does NOT broadcast (= sign-anchor-event.sh's job).
#   - Does NOT generate the receipt (= gen-anchor-receipt.sh's job).
#   - Does NOT push to the web host (= post-anchor-event.sh orchestrator's job).
#   - Does NOT touch any private key, wallet, or permission secret.
#
# Inputs (env):
#   RECEIPT_PATH       optional. Default $REPO_ROOT/public/api/anchor-receipt.json.
#   HISTORY_PATH       optional. Default $REPO_ROOT/public/api/anchor-history.jsonl.
#   SCHEMA_PATH        optional. Default $REPO_ROOT/public/api/anchor-history.schema.v1.json.
#   CYCLE_N            optional override. Integer >= 1. If absent, reads
#                      receipt.trigger_reference.cycle_n.
#   EVENT_TYPE         optional override. cyclestart | cycleend | idrotate | manual.
#                      If absent, derived from receipt.trigger_event.
#   SCRIPT_VERSION     optional. Identifier written to generated_by_script_version.
#                      Default: short git SHA at the script directory, or "unknown".
#
# Exit codes:
#   0  appended successfully
#   1  usage / parse error (RECEIPT_PATH missing or malformed)
#   2  invariant violation (tx_id dup / cycle dup / cycle ordering / byte preservation)
#   3  schema validation failed (new line rejected by per-line schema)
#   4  receipt verification_status not in {live, failed} (= not appendable)
#
# Secrets: this script reads NO private keys, wallets, or permission secrets.
# All inputs are public data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="${REPO_ROOT:-${REPO_ROOT_DEFAULT}}"

RECEIPT_PATH="${RECEIPT_PATH:-${REPO_ROOT}/public/api/anchor-receipt.json}"
HISTORY_PATH="${HISTORY_PATH:-${REPO_ROOT}/public/api/anchor-history.jsonl}"
SCHEMA_PATH="${SCHEMA_PATH:-${REPO_ROOT}/public/api/anchor-history.schema.v1.json}"

if [ ! -f "${RECEIPT_PATH}" ]; then
	echo "ERROR: receipt not found at ${RECEIPT_PATH}" >&2
	exit 1
fi
if ! jq empty "${RECEIPT_PATH}" >/dev/null 2>&1; then
	echo "ERROR: receipt is not valid JSON: ${RECEIPT_PATH}" >&2
	exit 1
fi

# ---- Read receipt + check verification_status is appendable ---------------

STATUS="$(jq -r '.verification_status // empty' "${RECEIPT_PATH}")"
case "${STATUS}" in
	live|failed) : ;;
	"") echo "ERROR: receipt has no verification_status (expected 'live' or 'failed')" >&2; exit 4 ;;
	*)  echo "ERROR: receipt verification_status='${STATUS}' is not appendable" >&2; exit 4 ;;
esac

# ---- Project receipt → history line shape --------------------------------

RECEIPT_TRIGGER="$(jq -r '.trigger_event // empty' "${RECEIPT_PATH}")"
case "${RECEIPT_TRIGGER}" in
	cycle_start) EVENT_TYPE_DEFAULT="cyclestart" ;;
	cycle_end)   EVENT_TYPE_DEFAULT="cycleend" ;;
	identity_rotation) EVENT_TYPE_DEFAULT="idrotate" ;;
	manual|"") EVENT_TYPE_DEFAULT="manual" ;;
	*) EVENT_TYPE_DEFAULT="${RECEIPT_TRIGGER}" ;;
esac
EVENT_TYPE="${EVENT_TYPE:-${EVENT_TYPE_DEFAULT}}"

CYCLE_N_DEFAULT="$(jq -r '(.trigger_reference.cycle_n // empty)' "${RECEIPT_PATH}")"
CYCLE_N="${CYCLE_N:-${CYCLE_N_DEFAULT}}"
if [ -z "${CYCLE_N}" ]; then
	echo "ERROR: cycle_n missing (neither CYCLE_N env nor receipt.trigger_reference.cycle_n)" >&2
	exit 1
fi

if [ -z "${SCRIPT_VERSION:-}" ]; then
	SCRIPT_VERSION="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

NEW_LINE_JSON="$(jq \
	--argjson cycle_n "${CYCLE_N}" \
	--arg event_type "${EVENT_TYPE}" \
	--arg verified_at "${NOW_UTC}" \
	--arg script_version "${SCRIPT_VERSION}" \
	'{
		schema_version: 1,
		cycle_n: $cycle_n,
		event_type: $event_type,
		dag_root_hash: .dag_root_hash,
		memo: .memo,
		network: .anchor.network,
		chain: .anchor.chain,
		chain_backend: (.anchor.chain_backend // "pulsevm"),
		method: .anchor.method,
		tx_id: .anchor.tx_id,
		block_num: .anchor.block_num,
		block_time: .anchor.block_time,
		explorer_url: .anchor.explorer_url,
		signing_actor: .signing_actor,
		signing_permission: .signing_permission,
		verification_status: .verification_status,
		verified_at: $verified_at,
		generated_by_script_version: $script_version
	}' "${RECEIPT_PATH}")"

NEW_LINE="$(printf '%s' "${NEW_LINE_JSON}" | jq -c .)"
NEW_TX_ID="$(printf '%s' "${NEW_LINE}" | jq -r .tx_id)"

# ---- Invariant (a): tx_id globally unique --------------------------------

if [ -f "${HISTORY_PATH}" ] && [ -s "${HISTORY_PATH}" ]; then
	if grep -q "\"tx_id\":\"${NEW_TX_ID}\"" "${HISTORY_PATH}"; then
		echo "REJECTED: invariant_a_tx_id_duplicate tx_id=${NEW_TX_ID} already present" >&2
		exit 2
	fi
fi

# ---- Invariant (b): (cycle_n, event_type) pair unique --------------------

if [ -f "${HISTORY_PATH}" ] && [ -s "${HISTORY_PATH}" ]; then
	DUP="$(jq -Rr --arg cn "${CYCLE_N}" --arg et "${EVENT_TYPE}" '
		(fromjson? // empty)
		| select(.cycle_n == ($cn | tonumber) and .event_type == $et)
		| .tx_id
	' "${HISTORY_PATH}" 2>/dev/null | head -n 1)"
	if [ -n "${DUP}" ]; then
		echo "REJECTED: invariant_b_cycle_event_duplicate (cycle_n=${CYCLE_N}, event_type=${EVENT_TYPE}) already present with tx_id=${DUP}" >&2
		exit 2
	fi
fi

# ---- Invariant (c): cycle_n non-decreasing ------------------------------

if [ -f "${HISTORY_PATH}" ] && [ -s "${HISTORY_PATH}" ]; then
	LAST_CYCLE_N="$(jq -Rr 'fromjson? | .cycle_n' "${HISTORY_PATH}" 2>/dev/null | tail -n 1)"
	if [ -n "${LAST_CYCLE_N}" ] && [ "${CYCLE_N}" -lt "${LAST_CYCLE_N}" ]; then
		echo "REJECTED: invariant_c_cycle_n_decreased new=${CYCLE_N} < last=${LAST_CYCLE_N}" >&2
		exit 2
	fi
fi

# ---- Schema validation --------------------------------------------------

TMP_LINE="$(mktemp -t historyline.XXXXXX).json"
trap 'rm -f "${TMP_LINE}"' EXIT
printf '%s' "${NEW_LINE}" > "${TMP_LINE}"

# Resolve an ajv invocation: prefer the `ajv` binary if it is on PATH,
# otherwise fall back to `npx -p ajv-cli -p ajv-formats ajv`. We do NOT
# silently degrade to a jq smoke check — a smoke check would let real
# schema-invalid lines (e.g. naive block_time without timezone) get
# appended as if valid, which is exactly the regression that broke the
# 2026-06-23 testnet rehearsal.
AJV_INVOKE=()
if command -v ajv >/dev/null 2>&1; then
	AJV_INVOKE=(ajv)
elif command -v npx >/dev/null 2>&1; then
	AJV_INVOKE=(npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv)
fi
if [ "${#AJV_INVOKE[@]}" -eq 0 ]; then
	echo "REJECTED: schema_validator_unavailable ajv is not on PATH and npx is not available" >&2
	exit 3
fi
if ! "${AJV_INVOKE[@]}" validate --strict=false -s "${SCHEMA_PATH}" -d "${TMP_LINE}" \
		--spec=draft2020 -c ajv-formats >/dev/null 2>&1; then
	AJV_ERR="$("${AJV_INVOKE[@]}" validate --strict=false --all-errors \
		-s "${SCHEMA_PATH}" -d "${TMP_LINE}" \
		--spec=draft2020 -c ajv-formats 2>&1 | tr '\n' ' ' | head -c 600)"
	echo "REJECTED: schema_validation_failed ${AJV_ERR}" >&2
	exit 3
fi

# ---- Atomic append: invariant (d) byte preservation + (e) final LF ------

mkdir -p "$(dirname "${HISTORY_PATH}")"
TMP_OUT="${HISTORY_PATH}.tmp.$$"

if [ -f "${HISTORY_PATH}" ] && [ -s "${HISTORY_PATH}" ]; then
	LAST_BYTE="$(tail -c1 "${HISTORY_PATH}" | od -An -tx1 | tr -d ' \n')"
	if [ "${LAST_BYTE}" != "0a" ]; then
		echo "REJECTED: invariant_d_byte_preservation existing history file does not end with LF — refusing to silently fix" >&2
		exit 2
	fi
	cat "${HISTORY_PATH}" > "${TMP_OUT}"
fi

printf '%s\n' "${NEW_LINE}" >> "${TMP_OUT}"
mv -f "${TMP_OUT}" "${HISTORY_PATH}"

echo "appended tx_id=${NEW_TX_ID} cycle_n=${CYCLE_N} event_type=${EVENT_TYPE} status=${STATUS}"
