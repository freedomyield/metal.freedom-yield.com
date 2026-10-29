#!/usr/bin/env bash
# --- LEGACY GUARD (added 2026-07-01) ---
# This test targets the pre-2026-07-01 anchor design (single-action
# eosio.token::transfer with memo "fyid1:<hash>"). The 2026-07-01
# revision replaced that with the HC-single 4-action pack (memo
# prefix fya<S>c<N>-*). See docs/ANCHOR_SOURCE.md + memory/
# project_merkle_dag_identity_anchor_design_20260701.md.
#
# The v2 pipeline has its own tests (tests/sign-anchor-event/,
# tests/gen-anchor-receipt/, tests/append-anchor-history/,
# tests/broadcast-guard/, tests/safe-broadcast/). Legacy tests
# here are retained for git-history traceability but skipped by
# default so run-all-tests.sh stays green under the new pipeline.
#
# To opt in and exercise the deprecated flow:  RUN_LEGACY_TESTS=1
if [ "${RUN_LEGACY_TESTS:-0}" != "1" ]; then
	echo "SKIP: legacy test — pre-2026-07-01 anchor design; set RUN_LEGACY_TESTS=1 to run"
	exit 0
fi
# Regression suite for sign-anchor-event.sh xpr-account configuration
# (= audit-C/F-E2 follow-up). Confirms:
#   - file missing → fail-closed exit 2
#   - file empty → fail-closed exit 2
#   - multi-line (≥2 newlines) → fail-closed exit 2
#   - invalid chars (uppercase, digit 0/6-9, hyphen) → fail-closed exit 2
#   - length > 12 → fail-closed exit 2
#   - mainnet value 'metalfreedom' (12 chars) → accepted; receipt carries it
#   - testnet throwaway 'fytest1' (7 chars) → accepted; receipt carries it
#   - receipt's inscribe_action.from + .permission.actor BOTH equal xpr-account
#   - proton CLI is invoked with ${XPR_ACCOUNT}@anchor (= NOT hardcoded metalfreedom@anchor)
#
# All cases run with --dry-run. Proton CLI is stubbed via PATH override
# so no real network call happens.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/sign-anchor-event.sh"
[ -x "${SCRIPT}" ] || { echo "FAIL: ${SCRIPT} not executable" >&2; exit 1; }

TMP="$(mktemp -d -t xpr-acct.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

STUB_BIN="${TMP}/bin"
mkdir -p "${STUB_BIN}"
# Stub that emits a synthetic tx_id + block fields so the script reaches
# the receipt-emit step (= where we inspect the from/actor fields).
LAST_AUTH_LOG="${TMP}/proton-auth.log"
: > "${LAST_AUTH_LOG}"
cat > "${STUB_BIN}/proton" <<STUB
#!/bin/bash
case "\$1" in
	--help|help)
		echo "available commands: action chain:set get_transaction"
		exit 0
		;;
	chain:set) exit 0 ;;
	action)
		# Record the authorization arg (the 5th positional after action <ctr> <act> '<json>' <auth>).
		# Layout: action <contract> <action_name> <data_json> <auth>
		printf 'AUTH=%s\n' "\$5" >> "${LAST_AUTH_LOG}"
		# Emit a transaction_id-shaped line.
		echo "transaction_id: a000000000000000000000000000000000000000000000000000000000000001"
		exit 0
		;;
	get_transaction)
		printf '{"block_num":42,"block_time":"2026-06-21T00:00:00"}\n'
		exit 0
		;;
esac
exit 0
STUB
chmod +x "${STUB_BIN}/proton"

DAG="0000000000000000000000000000000000000000000000000000000000000000"

write_baseline_config() {
	local dir="$1"
	mkdir -p "${dir}"
	printf '%s' 'fyhistory'    > "${dir}/anchor-sink"
	printf '%s' 'proton-test' > "${dir}/xpr-chain"
}

run_signer() {
	local cfgdir="$1"; shift
	local out err rc
	out="$(mktemp)"; err="$(mktemp)"
	rc=0
	FY_CONFIG_DIR="${cfgdir}" \
	PATH="${STUB_BIN}:${PATH}" \
	"${SCRIPT}" cyclestart "${DAG}" "$@" \
		> "${out}" 2> "${err}" || rc=$?
	printf '%s\n%s\n%s\n' "${rc}" "${out}" "${err}"
}

PASS=0
FAIL=0

# -------- Case A: xpr-account file missing --------
echo "=== Case A: xpr-account file missing → fail-closed ==="
CFG_A="${TMP}/cfg-a"; write_baseline_config "${CFG_A}"
RESULT="$(run_signer "${CFG_A}")"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
ERR_FILE="$(printf '%s' "${RESULT}" | sed -n '3p')"
if [ "${RC}" = "2" ] && grep -q 'xpr-account.*missing' "${ERR_FILE}"; then
	echo "  PASS A rc=2, missing-file error"; PASS=$((PASS+1))
else
	echo "  FAIL A rc=${RC}; stderr: $(head -n 1 "${ERR_FILE}")"; FAIL=$((FAIL+1))
fi
rm -f "$(printf '%s' "${RESULT}" | sed -n '2p')" "${ERR_FILE}"

# -------- Case B: empty file --------
echo "=== Case B: xpr-account empty → fail-closed ==="
CFG_B="${TMP}/cfg-b"; write_baseline_config "${CFG_B}"
: > "${CFG_B}/xpr-account"
RESULT="$(run_signer "${CFG_B}")"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
ERR_FILE="$(printf '%s' "${RESULT}" | sed -n '3p')"
if [ "${RC}" = "2" ] && grep -qE 'xpr-account.*(empty|whitespace)' "${ERR_FILE}"; then
	echo "  PASS B rc=2, empty error"; PASS=$((PASS+1))
else
	echo "  FAIL B rc=${RC}; stderr: $(head -n 1 "${ERR_FILE}")"; FAIL=$((FAIL+1))
fi
rm -f "$(printf '%s' "${RESULT}" | sed -n '2p')" "${ERR_FILE}"

# -------- Case C: multi-line file --------
echo "=== Case C: xpr-account multi-line → fail-closed ==="
CFG_C="${TMP}/cfg-c"; write_baseline_config "${CFG_C}"
printf 'metalfreedom\nfytest1\n' > "${CFG_C}/xpr-account"
RESULT="$(run_signer "${CFG_C}")"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
ERR_FILE="$(printf '%s' "${RESULT}" | sed -n '3p')"
if [ "${RC}" = "2" ] && grep -q 'exactly one line' "${ERR_FILE}"; then
	echo "  PASS C rc=2, multi-line rejected"; PASS=$((PASS+1))
else
	echo "  FAIL C rc=${RC}; stderr: $(head -n 1 "${ERR_FILE}")"; FAIL=$((FAIL+1))
fi
rm -f "$(printf '%s' "${RESULT}" | sed -n '2p')" "${ERR_FILE}"

# -------- Case D: invalid chars --------
echo "=== Case D: invalid chars (uppercase/digit 0/hyphen) → fail-closed ==="
for bad in 'FreeDomYield' 'fy0test' 'fy-test'; do
	CFG_D="${TMP}/cfg-d-${RANDOM}"; write_baseline_config "${CFG_D}"
	printf '%s' "${bad}" > "${CFG_D}/xpr-account"
	RESULT="$(run_signer "${CFG_D}")"
	RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
	ERR_FILE="$(printf '%s' "${RESULT}" | sed -n '3p')"
	if [ "${RC}" = "2" ] && grep -qE 'characters outside' "${ERR_FILE}"; then
		echo "  PASS D[${bad}] rc=2, invalid-chars rejected"; PASS=$((PASS+1))
	else
		echo "  FAIL D[${bad}] rc=${RC}; stderr: $(head -n 1 "${ERR_FILE}")"; FAIL=$((FAIL+1))
	fi
	rm -f "$(printf '%s' "${RESULT}" | sed -n '2p')" "${ERR_FILE}"
done

# -------- Case E: length > 12 --------
echo "=== Case E: length > 12 → fail-closed ==="
CFG_E="${TMP}/cfg-e"; write_baseline_config "${CFG_E}"
printf 'aaaaaaaaaaaaa' > "${CFG_E}/xpr-account"  # 13 chars
RESULT="$(run_signer "${CFG_E}")"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
ERR_FILE="$(printf '%s' "${RESULT}" | sed -n '3p')"
if [ "${RC}" = "2" ] && grep -q 'length must be 1..12' "${ERR_FILE}"; then
	echo "  PASS E rc=2, length>12 rejected"; PASS=$((PASS+1))
else
	echo "  FAIL E rc=${RC}; stderr: $(head -n 1 "${ERR_FILE}")"; FAIL=$((FAIL+1))
fi
rm -f "$(printf '%s' "${RESULT}" | sed -n '2p')" "${ERR_FILE}"

# -------- Case F: mainnet 'metalfreedom' → receipt carries it --------
echo "=== Case F: mainnet 'metalfreedom' (12 chars) → accepted, receipt carries it ==="
CFG_F="${TMP}/cfg-f"; write_baseline_config "${CFG_F}"
printf 'metalfreedom' > "${CFG_F}/xpr-account"
: > "${LAST_AUTH_LOG}"
RESULT="$(run_signer "${CFG_F}")"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
OUT_FILE="$(printf '%s' "${RESULT}" | sed -n '2p')"
ERR_FILE="$(printf '%s' "${RESULT}" | sed -n '3p')"
if [ "${RC}" = "0" ] && jq empty "${OUT_FILE}" >/dev/null 2>&1; then
	FROM="$(jq -r .inscribe_action.from "${OUT_FILE}")"
	ACTOR="$(jq -r .inscribe_action.permission.actor "${OUT_FILE}")"
	AUTH="$(tail -n 1 "${LAST_AUTH_LOG}")"
	if [ "${FROM}" = "metalfreedom" ] && [ "${ACTOR}" = "metalfreedom" ] && [ "${AUTH}" = "AUTH=metalfreedom@anchor" ]; then
		echo "  PASS F mainnet receipt: from=${FROM}, actor=${ACTOR}, proton auth=${AUTH}"; PASS=$((PASS+1))
	else
		echo "  FAIL F mainnet mismatch: from=${FROM}, actor=${ACTOR}, auth=${AUTH}"; FAIL=$((FAIL+1))
	fi
else
	echo "  FAIL F rc=${RC}"; FAIL=$((FAIL+1))
fi
rm -f "${OUT_FILE}" "${ERR_FILE}"

# -------- Case G: testnet 'fytest1' → receipt carries it, NOT metalfreedom --------
echo "=== Case G: testnet 'fytest1' → receipt carries throwaway, NOT metalfreedom ==="
CFG_G="${TMP}/cfg-g"; write_baseline_config "${CFG_G}"
printf 'fytest1' > "${CFG_G}/xpr-account"
: > "${LAST_AUTH_LOG}"
RESULT="$(run_signer "${CFG_G}")"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
OUT_FILE="$(printf '%s' "${RESULT}" | sed -n '2p')"
if [ "${RC}" = "0" ] && jq empty "${OUT_FILE}" >/dev/null 2>&1; then
	FROM="$(jq -r .inscribe_action.from "${OUT_FILE}")"
	ACTOR="$(jq -r .inscribe_action.permission.actor "${OUT_FILE}")"
	AUTH="$(tail -n 1 "${LAST_AUTH_LOG}")"
	if [ "${FROM}" = "fytest1" ] && [ "${ACTOR}" = "fytest1" ] && [ "${AUTH}" = "AUTH=fytest1@anchor" ] && ! grep -q 'metalfreedom' "${OUT_FILE}"; then
		echo "  PASS G testnet receipt: from=${FROM}, actor=${ACTOR}, proton auth=${AUTH}; no 'metalfreedom' literal"; PASS=$((PASS+1))
	else
		echo "  FAIL G testnet mismatch or metalfreedom leak: from=${FROM}, actor=${ACTOR}, auth=${AUTH}"; FAIL=$((FAIL+1))
	fi
else
	echo "  FAIL G rc=${RC}"; FAIL=$((FAIL+1))
fi
rm -f "${OUT_FILE}" "$(printf '%s' "${RESULT}" | sed -n '3p')"

# -------- Case H: sink == xpr-account → self-transfer rejected --------
echo "=== Case H: sink == xpr-account → BLOCK-1 rejection ==="
CFG_H="${TMP}/cfg-h"; write_baseline_config "${CFG_H}"
printf 'fytest1' > "${CFG_H}/xpr-account"
printf 'fytest1' > "${CFG_H}/anchor-sink"  # same as xpr-account → BLOCK-1
RESULT="$(run_signer "${CFG_H}")"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
ERR_FILE="$(printf '%s' "${RESULT}" | sed -n '3p')"
if [ "${RC}" = "2" ] && grep -qE 'sink MUST NOT equal' "${ERR_FILE}"; then
	echo "  PASS H self-transfer rejected"; PASS=$((PASS+1))
else
	echo "  FAIL H rc=${RC}; stderr: $(head -n 1 "${ERR_FILE}")"; FAIL=$((FAIL+1))
fi
rm -f "$(printf '%s' "${RESULT}" | sed -n '2p')" "${ERR_FILE}"

echo ""
echo "Result: ${PASS} pass, ${FAIL} fail"
[ "${FAIL}" -eq 0 ]
