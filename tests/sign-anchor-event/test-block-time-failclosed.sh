#!/usr/bin/env bash
# Regression suite for sign-anchor-event.sh block_time / block_num
# fail-closed semantics (= audit-C/F-E4 follow-up).
#
# Per audit:
#   - proton-cli get_transaction provides block_time AND block_num → emit
#   - RPC fallback provides them → emit
#   - both paths fail → script MUST exit non-zero (no fabrication)
#   - local current time MUST NOT be used as block_time
#   - partial receipt MUST NOT be emitted on stdout
#
# Cases:
#   1. proton get_transaction success      → script exits 0 + emits receipt with chain block_time
#   2. proton lacks get_transaction; RPC OK → script exits 0 + emits receipt with chain block_time
#   3. proton + RPC both empty             → script exits NON-ZERO + NO receipt JSON on stdout
#   4. local clock time MUST NOT appear in receipt under any case
#
# Stubs proton + curl via PATH override; no real proton-cli or network.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/sign-anchor-event.sh"
[ -x "${SCRIPT}" ] || { echo "FAIL: ${SCRIPT} not executable" >&2; exit 1; }

TMP="$(mktemp -d -t bt-failclosed.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

CONFIG_DIR="${TMP}/etc"
mkdir -p "${CONFIG_DIR}"
printf '%s' 'fyldsink'    > "${CONFIG_DIR}/anchor-sink"
printf '%s' 'proton-test' > "${CONFIG_DIR}/xpr-chain"

STUB_BIN="${TMP}/bin"
mkdir -p "${STUB_BIN}"

# Stub TX_ID we will echo back from proton.
STUB_TX="aaaa000000000000000000000000000000000000000000000000000000000000"
# Reference block fields used in the success cases (= what we want the
# receipt to carry through, MUST NOT match the local clock).
REF_BLOCK_NUM=1234567
REF_BLOCK_TIME="2026-06-21T12:34:56"

# --- helper: write a proton stub that exposes get_transaction with the
# block fields populated, AND echoes a tx_id when invoked as `action`.
make_proton_with_gettx() {
	cat > "${STUB_BIN}/proton" <<STUB
#!/bin/bash
case "\$1" in
	--help|help)
		# advertise the get_transaction subcommand
		echo "available commands: action chain:set key:add key:list get_transaction"
		exit 0
		;;
	chain:set) exit 0 ;;
	action)
		# emit a tx_id matching the production extractor's primary pattern
		echo "transaction_id: ${STUB_TX}"
		exit 0
		;;
	get_transaction)
		# return chain-style JSON with the reference block fields
		printf '{"block_num":%s,"block_time":"%s","traces":[]}\n' "${REF_BLOCK_NUM}" "${REF_BLOCK_TIME}"
		exit 0
		;;
esac
exit 0
STUB
	chmod +x "${STUB_BIN}/proton"
}

# --- helper: write a proton stub without get_transaction support; the
# script falls back to curl-RPC for block fields.
make_proton_without_gettx() {
	cat > "${STUB_BIN}/proton" <<STUB
#!/bin/bash
case "\$1" in
	--help|help)
		# do NOT advertise get_transaction
		echo "available commands: action chain:set key:add key:list"
		exit 0
		;;
	chain:set) exit 0 ;;
	action)
		echo "transaction_id: ${STUB_TX}"
		exit 0
		;;
esac
exit 0
STUB
	chmod +x "${STUB_BIN}/proton"
}

# --- helper: write a curl stub that returns the given JSON body verbatim.
make_curl_returning() {
	local body="$1"
	cat > "${STUB_BIN}/curl" <<STUB
#!/bin/bash
# Stub curl. Ignores args, prints the canned body, exits 0.
cat <<'BODY'
${body}
BODY
exit 0
STUB
	chmod +x "${STUB_BIN}/curl"
}

run_signer() {
	local stdout stderr rc
	stdout="$(mktemp)"; stderr="$(mktemp)"
	rc=0
	FY_CONFIG_DIR="${CONFIG_DIR}" \
	PATH="${STUB_BIN}:${PATH}" \
	"${SCRIPT}" cyclestart 0000000000000000000000000000000000000000000000000000000000000000 \
		> "${stdout}" 2> "${stderr}" || rc=$?
	printf '%s\n%s\n%s\n' "${rc}" "${stdout}" "${stderr}"
}

PASS=0
FAIL=0

# -------- Case 1: proton get_transaction success --------
echo "=== Case 1: proton get_transaction provides block_time + block_num ==="
make_proton_with_gettx
# curl stub not needed (proton path succeeds), but keep one returning
# empty JSON so any unexpected RPC call doesn't actually hit the network.
make_curl_returning '{}'
RESULT="$(run_signer)"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
STDOUT_FILE="$(printf '%s' "${RESULT}" | sed -n '2p')"
if [ "${RC}" = "0" ] && jq empty "${STDOUT_FILE}" >/dev/null 2>&1; then
	GOT_BLOCK_TIME="$(jq -r '.block_time' "${STDOUT_FILE}")"
	GOT_BLOCK_NUM="$(jq -r '.block_num'  "${STDOUT_FILE}")"
	# Accept the value with or without trailing Z (the normalizer adds Z).
	case "${GOT_BLOCK_TIME}" in
		"${REF_BLOCK_TIME}Z")
			if [ "${GOT_BLOCK_NUM}" = "${REF_BLOCK_NUM}" ]; then
				echo "  PASS 1 chain block_time=${GOT_BLOCK_TIME} block_num=${GOT_BLOCK_NUM}"
				PASS=$((PASS+1))
			else
				echo "  FAIL 1 block_num mismatch: got ${GOT_BLOCK_NUM}, expected ${REF_BLOCK_NUM}"
				FAIL=$((FAIL+1))
			fi
			;;
		*)
			echo "  FAIL 1 block_time mismatch: got '${GOT_BLOCK_TIME}', expected '${REF_BLOCK_TIME}Z'"
			FAIL=$((FAIL+1))
			;;
	esac
else
	echo "  FAIL 1 expected exit 0 + valid JSON; got rc=${RC}"
	FAIL=$((FAIL+1))
fi
rm -f "${STDOUT_FILE}"

# -------- Case 2: proton lacks get_transaction; RPC fallback OK --------
echo "=== Case 2: proton without get_transaction, RPC provides block fields ==="
make_proton_without_gettx
make_curl_returning "{\"block_num\":${REF_BLOCK_NUM},\"block_time\":\"${REF_BLOCK_TIME}\"}"
RESULT="$(run_signer)"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
STDOUT_FILE="$(printf '%s' "${RESULT}" | sed -n '2p')"
if [ "${RC}" = "0" ] && jq empty "${STDOUT_FILE}" >/dev/null 2>&1; then
	GOT_BLOCK_TIME="$(jq -r '.block_time' "${STDOUT_FILE}")"
	GOT_BLOCK_NUM="$(jq -r '.block_num'  "${STDOUT_FILE}")"
	if [ "${GOT_BLOCK_TIME}" = "${REF_BLOCK_TIME}Z" ] && [ "${GOT_BLOCK_NUM}" = "${REF_BLOCK_NUM}" ]; then
		echo "  PASS 2 RPC-fallback block_time=${GOT_BLOCK_TIME} block_num=${GOT_BLOCK_NUM}"
		PASS=$((PASS+1))
	else
		echo "  FAIL 2 mismatch: block_time='${GOT_BLOCK_TIME}' block_num='${GOT_BLOCK_NUM}'"
		FAIL=$((FAIL+1))
	fi
else
	echo "  FAIL 2 expected exit 0 + valid JSON; got rc=${RC}"
	FAIL=$((FAIL+1))
fi
rm -f "${STDOUT_FILE}"

# -------- Case 3: both proton + RPC empty → fail-closed --------
echo "=== Case 3: proton + RPC both empty → exit non-zero, NO receipt on stdout ==="
make_proton_without_gettx
make_curl_returning '{}'
RESULT="$(run_signer)"
RC="$(printf '%s' "${RESULT}" | sed -n '1p')"
STDOUT_FILE="$(printf '%s' "${RESULT}" | sed -n '2p')"
STDERR_FILE="$(printf '%s' "${RESULT}" | sed -n '3p')"
if [ "${RC}" != "0" ] && [ ! -s "${STDOUT_FILE}" ]; then
	# stderr should mention "block_num" or "block_time" cannot be derived
	if grep -qE 'block_(num|time).*could not be derived' "${STDERR_FILE}"; then
		echo "  PASS 3 fail-closed: rc=${RC}, no stdout, clear stderr"
		PASS=$((PASS+1))
	else
		echo "  FAIL 3 fail-closed but stderr did not name the missing field"
		echo "  stderr was:"
		head -n 5 "${STDERR_FILE}"
		FAIL=$((FAIL+1))
	fi
else
	echo "  FAIL 3 expected non-zero rc + empty stdout; got rc=${RC}, stdout=$(wc -c <"${STDOUT_FILE}") bytes"
	cat "${STDOUT_FILE}"
	FAIL=$((FAIL+1))
fi
rm -f "${STDOUT_FILE}" "${STDERR_FILE}"

# -------- Case 4: local clock never appears in receipt --------
echo "=== Case 4: local clock seconds-precision time MUST NOT appear in receipt block_time ==="
make_proton_with_gettx
make_curl_returning '{}'
NOW_PREFIX="$(date -u +%Y-%m-%dT%H:%M)"
RESULT="$(run_signer)"
STDOUT_FILE="$(printf '%s' "${RESULT}" | sed -n '2p')"
if [ -s "${STDOUT_FILE}" ] && jq empty "${STDOUT_FILE}" >/dev/null 2>&1; then
	BT="$(jq -r '.block_time' "${STDOUT_FILE}")"
	case "${BT}" in
		${NOW_PREFIX}*)
			echo "  FAIL 4 receipt block_time matches local clock prefix ${NOW_PREFIX}"
			FAIL=$((FAIL+1))
			;;
		*)
			echo "  PASS 4 receipt block_time=${BT} is chain-derived (does not match local clock prefix)"
			PASS=$((PASS+1))
			;;
	esac
else
	echo "  FAIL 4 expected receipt JSON; got empty stdout"
	FAIL=$((FAIL+1))
fi
rm -f "${STDOUT_FILE}"

echo ""
echo "Result: ${PASS} pass, ${FAIL} fail"
[ "${FAIL}" -eq 0 ]
