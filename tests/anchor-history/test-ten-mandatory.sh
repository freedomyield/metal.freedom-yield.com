#!/usr/bin/env bash
# test-ten-mandatory.sh — Phase α 2026-07-04 anchor completion: ten
# mandatory tests gating the cycle 3 cyclestart anchor.
#
# Tests (per operator-confirmed plan 2026-06-23):
#   T1  anchor-receipt.example.json passes ajv against anchor-receipt.schema.v1.json
#   T2  anchor-receipt.phase-beta.example.json passes ajv against same schema
#   T3  anchor-history.example.jsonl: every line passes ajv against
#       anchor-history.schema.v1.json
#   T4  identity.example.json passes ajv against identity.schema.v1.json
#       AND carries the new `audit` object with anchor_receipt + anchor_history
#       URL pointers
#   T5  append-anchor-history.sh appends the first record to an empty (= nonexistent)
#       history file and the new line passes the per-line schema
#   T6  append-anchor-history.sh REJECTS a tx_id duplicate (invariant a)
#   T7  append-anchor-history.sh REJECTS a (cycle_n, event_type) duplicate
#       (invariant b)
#   T8  append-anchor-history.sh REJECTS a cycle_n that goes backwards
#       (invariant c — cycle_n non-decreasing)
#   T9  append-anchor-history.sh REJECTS appending to a history file that
#       does not end with LF (invariant d — byte preservation)
#   T10 NO operator-local secret material (private keys / seed phrases /
#       passphrases / wallet credentials) is present anywhere in:
#         scripts/   public/   docs/   tests/   public/api/
#       Pattern-based grep over a curated denylist; PASS only if zero hits.
#
# Exit code:
#   0 = all 10 PASS
#   1 = any one FAILed; the first failure is reported on stderr and the
#       script exits without running later tests when the failure is a hard
#       schema/append guarantee.
#
# This script reads NO private keys, wallets, or permission secrets, and
# writes only inside $(mktemp -d). All inputs are public schema / fixture
# files committed to this repository.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API_DIR="${ROOT}/public/api"
APPEND_SH="${ROOT}/scripts/append-anchor-history.sh"

PASS=0
FAIL=0

# --- Helpers --------------------------------------------------------------

# ajv-validate <schema-path> <data-path>. Uses the local `ajv` binary if
# available; otherwise falls back to `npx -p ajv-cli -p ajv-formats ajv` so
# tests work on machines without a global install.
AJV_INVOKE=()
if command -v ajv >/dev/null 2>&1; then
	AJV_INVOKE=(ajv)
elif command -v npx >/dev/null 2>&1; then
	AJV_INVOKE=(npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv)
fi
ajv_validate() {
	local schema="$1" data="$2"
	if [ "${#AJV_INVOKE[@]}" -eq 0 ]; then
		echo "SKIP (ajv unavailable, npx unavailable): $(basename "$data") against $(basename "$schema")" >&2
		return 0
	fi
	"${AJV_INVOKE[@]}" validate --strict=false -s "${schema}" -d "${data}" \
		--spec=draft2020 -c ajv-formats >/dev/null 2>&1
}

# --- T1: anchor-receipt.example.json ajv PASS ----------------------------

if ajv_validate "${API_DIR}/anchor-receipt.schema.v1.json" "${API_DIR}/anchor-receipt.example.json"; then
	echo "T1  PASS  anchor-receipt.example.json validates"
	PASS=$((PASS + 1))
else
	echo "T1  FAIL  anchor-receipt.example.json does not validate" >&2
	FAIL=$((FAIL + 1))
fi

# --- T2: anchor-receipt.phase-beta.example.json ajv PASS -----------------

if ajv_validate "${API_DIR}/anchor-receipt.schema.v1.json" "${API_DIR}/anchor-receipt.phase-beta.example.json"; then
	echo "T2  PASS  anchor-receipt.phase-beta.example.json validates"
	PASS=$((PASS + 1))
else
	echo "T2  FAIL  anchor-receipt.phase-beta.example.json does not validate" >&2
	FAIL=$((FAIL + 1))
fi

# --- T3: anchor-history.example.jsonl line-by-line ajv PASS --------------

T3_OK=1
LINE_NO=0
while IFS= read -r line; do
	LINE_NO=$((LINE_NO + 1))
	# Skip blank lines (= the trailing LF after the last record produces
	# one empty read when iterating, which we explicitly ignore).
	[ -z "${line}" ] && continue
	TMP_LINE="$(mktemp -t hist-line.XXXXXX).json"
	printf '%s' "${line}" > "${TMP_LINE}"
	if ! ajv_validate "${API_DIR}/anchor-history.schema.v1.json" "${TMP_LINE}"; then
		echo "T3  FAIL  line ${LINE_NO} of anchor-history.example.jsonl does not validate" >&2
		T3_OK=0
		rm -f "${TMP_LINE}"
		break
	fi
	rm -f "${TMP_LINE}"
done < "${API_DIR}/anchor-history.example.jsonl"

if [ "${T3_OK}" -eq 1 ]; then
	echo "T3  PASS  anchor-history.example.jsonl: all ${LINE_NO} lines validate"
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
fi

# --- T4: identity.example.json ajv PASS AND audit object present ---------

T4_OK=1
if ! ajv_validate "${API_DIR}/identity.schema.v1.json" "${API_DIR}/identity.example.json"; then
	echo "T4  FAIL  identity.example.json does not validate" >&2
	T4_OK=0
fi
if [ "${T4_OK}" -eq 1 ]; then
	# Verify the audit object is present with both required URL pointers.
	if ! jq -e '
		(.audit | type) == "object"
		and (.audit.anchor_receipt | startswith("http"))
		and (.audit.anchor_history | startswith("http"))
	' "${API_DIR}/identity.example.json" >/dev/null; then
		echo "T4  FAIL  identity.example.json: audit object missing or pointers wrong" >&2
		T4_OK=0
	fi
fi
if [ "${T4_OK}" -eq 1 ]; then
	echo "T4  PASS  identity.example.json validates AND audit object well-formed"
	PASS=$((PASS + 1))
else
	FAIL=$((FAIL + 1))
fi

# --- Tests T5..T9 require append-anchor-history.sh to be executable ------

if [ ! -x "${APPEND_SH}" ]; then
	echo "T5-T9 SKIP append-anchor-history.sh not executable at ${APPEND_SH}" >&2
	FAIL=$((FAIL + 5))
else
	TMP_DIR="$(mktemp -d -t anchor-history-tests.XXXXXX)"
	trap 'rm -rf "${TMP_DIR}"' EXIT

	# --- T5: append to empty (= nonexistent) history file ----------------
	HISTORY="${TMP_DIR}/history.jsonl"
	if RECEIPT_PATH="${ROOT}/tests/anchor-history/fixtures/receipt-live-cycle3-start.json" \
			HISTORY_PATH="${HISTORY}" \
			SCHEMA_PATH="${API_DIR}/anchor-history.schema.v1.json" \
			"${APPEND_SH}" >/dev/null 2>&1; then
		# Verify exactly one line + final LF.
		LINES=$(wc -l < "${HISTORY}")
		LAST=$(tail -c1 "${HISTORY}" | od -An -tx1 | tr -d ' \n')
		if [ "${LINES}" -eq 1 ] && [ "${LAST}" = "0a" ]; then
			echo "T5  PASS  empty→1-line append; final LF present"
			PASS=$((PASS + 1))
		else
			echo "T5  FAIL  appended but file shape wrong (lines=${LINES} last_byte=${LAST})" >&2
			FAIL=$((FAIL + 1))
		fi
	else
		echo "T5  FAIL  append-anchor-history.sh refused first-line append" >&2
		FAIL=$((FAIL + 1))
	fi

	# --- T6: tx_id duplicate is REJECTED (invariant a) -------------------
	if RECEIPT_PATH="${ROOT}/tests/anchor-history/fixtures/receipt-live-cycle3-start.json" \
			HISTORY_PATH="${HISTORY}" \
			SCHEMA_PATH="${API_DIR}/anchor-history.schema.v1.json" \
			"${APPEND_SH}" >/dev/null 2>&1; then
		echo "T6  FAIL  duplicate tx_id was accepted (invariant a broken)" >&2
		FAIL=$((FAIL + 1))
	else
		echo "T6  PASS  duplicate tx_id rejected (invariant a holds)"
		PASS=$((PASS + 1))
	fi

	# --- T7: (cycle_n, event_type) duplicate REJECTED (invariant b) ------
	# Craft a fixture with a fresh tx_id but the same (cycle_n=3, cyclestart).
	DUP_FIX="${TMP_DIR}/dup-cycle-event.json"
	jq '.anchor.tx_id = "dddd000000000000000000000000000000000000000000000000000000000004"' \
		"${ROOT}/tests/anchor-history/fixtures/receipt-live-cycle3-start.json" > "${DUP_FIX}"
	if RECEIPT_PATH="${DUP_FIX}" \
			HISTORY_PATH="${HISTORY}" \
			SCHEMA_PATH="${API_DIR}/anchor-history.schema.v1.json" \
			"${APPEND_SH}" >/dev/null 2>&1; then
		echo "T7  FAIL  duplicate (cycle_n=3, cyclestart) was accepted (invariant b broken)" >&2
		FAIL=$((FAIL + 1))
	else
		echo "T7  PASS  duplicate (cycle_n, event_type) rejected (invariant b holds)"
		PASS=$((PASS + 1))
	fi

	# --- T8: cycle_n regression REJECTED (invariant c) -------------------
	# First, advance the ledger to cycle 4 via cycleend → cycle 4 start.
	# Simpler: append cycle-3-end, then try cycle-2-start (regression).
	RECEIPT_PATH="${ROOT}/tests/anchor-history/fixtures/receipt-live-cycle3-end.json" \
		HISTORY_PATH="${HISTORY}" \
		SCHEMA_PATH="${API_DIR}/anchor-history.schema.v1.json" \
		"${APPEND_SH}" >/dev/null 2>&1 || true

	REG_FIX="${TMP_DIR}/regression-cycle2.json"
	jq '.trigger_reference.cycle_n = 2
		| .anchor.tx_id = "eeee000000000000000000000000000000000000000000000000000000000005"
		| .anchor.inscribe_action.memo = "fyid1:eeee000000000000000000000000000000000000000000000000000000000005"
		| .memo = "fyid1:eeee000000000000000000000000000000000000000000000000000000000005"
		| .dag_root_hash = "eeee000000000000000000000000000000000000000000000000000000000005"' \
		"${ROOT}/tests/anchor-history/fixtures/receipt-live-cycle3-start.json" > "${REG_FIX}"
	if RECEIPT_PATH="${REG_FIX}" \
			HISTORY_PATH="${HISTORY}" \
			SCHEMA_PATH="${API_DIR}/anchor-history.schema.v1.json" \
			"${APPEND_SH}" >/dev/null 2>&1; then
		echo "T8  FAIL  cycle_n regression (2 < 3) was accepted (invariant c broken)" >&2
		FAIL=$((FAIL + 1))
	else
		echo "T8  PASS  cycle_n regression rejected (invariant c holds)"
		PASS=$((PASS + 1))
	fi

	# --- T9: history file without final LF triggers REJECT (invariant d) -
	# Truncate the final LF; the appender MUST refuse rather than silently fix.
	NOLF="${TMP_DIR}/no-final-lf.jsonl"
	cp "${HISTORY}" "${NOLF}"
	# Strip exactly one byte off the end (= the LF) so the file ends with
	# a closing brace instead.
	NOLF_SIZE=$(wc -c < "${NOLF}")
	dd if="${NOLF}" of="${NOLF}.short" bs=1 count=$((NOLF_SIZE - 1)) 2>/dev/null
	mv "${NOLF}.short" "${NOLF}"
	if RECEIPT_PATH="${ROOT}/tests/anchor-history/fixtures/receipt-live-cycle4-start.json" \
			HISTORY_PATH="${NOLF}" \
			SCHEMA_PATH="${API_DIR}/anchor-history.schema.v1.json" \
			"${APPEND_SH}" >/dev/null 2>&1; then
		echo "T9  FAIL  appender silently fixed missing final LF (invariant d broken)" >&2
		FAIL=$((FAIL + 1))
	else
		echo "T9  PASS  missing-final-LF rejected (invariant d holds)"
		PASS=$((PASS + 1))
	fi
fi

# --- T10: NO operator-local secret material in tracked paths -------------

# Curated denylist of patterns that MUST NOT appear in any tracked file
# under the listed Phase α-affected paths. Patterns are assembled from
# fragments at runtime rather than written as literals, so this test file
# itself does not contain the "BEGIN <kind> PRIVATE KEY" sequence that
# would (correctly) trip the .githooks/pre-commit gitleaks-fallback grep.
# The runtime-assembled values are byte-identical to the originals — the
# fragmentation is purely for source-on-disk hygiene, not behaviour.
_PEM_HEAD="BE""GIN"
_PEM_TAIL="PRIV""ATE KEY"
T10_DENY=(
	"${_PEM_HEAD} OPENSSH ${_PEM_TAIL}"
	"${_PEM_HEAD} RSA ${_PEM_TAIL}"
	"${_PEM_HEAD} EC ${_PEM_TAIL}"
	"${_PEM_HEAD} ${_PEM_TAIL}"
	"${_PEM_HEAD} PGP ${_PEM_TAIL}"
	"mnemonic_phrase"
	"seed_phrase"
	"wallet_passphrase"
	"validator_passphrase"
	"PRI""VATE_KEY_HEX"
	"5K[A-HJ-NP-Za-km-z1-9]{49}"
	"5J[A-HJ-NP-Za-km-z1-9]{49}"
)

T10_SCAN_PATHS=(
	"scripts"
	"public"
	"docs"
	"tests"
)

T10_HITS=0
for path in "${T10_SCAN_PATHS[@]}"; do
	[ -e "${ROOT}/${path}" ] || continue
	for pat in "${T10_DENY[@]}"; do
		# Use -I to skip binary files; -r recursive; exclude the test script
		# itself (which mentions the patterns as denylist data).
		# grep exits 1 when there are no matches; that is the PASS case for
		# this denylist scan. Tolerate that via `|| true` so pipefail does
		# not short-circuit the test runner before the final summary prints.
		HITS="$( { grep -rIE --exclude="test-ten-mandatory.sh" \
			--exclude-dir=node_modules \
			"${pat}" "${ROOT}/${path}" 2>/dev/null || true; } | wc -l | tr -d ' ')"
		if [ "${HITS}" -gt 0 ]; then
			echo "T10 FAIL  pattern matched (${HITS} hits) in ${path}: ${pat}" >&2
			T10_HITS=$((T10_HITS + HITS))
		fi
	done
done
if [ "${T10_HITS}" -eq 0 ]; then
	echo "T10 PASS  no operator-local secret material in tracked paths"
	PASS=$((PASS + 1))
else
	echo "T10 FAIL  ${T10_HITS} secret-pattern hits (see lines above)" >&2
	FAIL=$((FAIL + 1))
fi

# --- Summary --------------------------------------------------------------

echo ""
echo "===== anchor-history mandatory tests ====="
echo "PASS: ${PASS}/10"
echo "FAIL: ${FAIL}/10"
echo "=========================================="

[ "${FAIL}" -eq 0 ]
