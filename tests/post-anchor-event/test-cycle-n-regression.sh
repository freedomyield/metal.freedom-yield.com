#!/bin/bash
# Regression suite for post-anchor-event.sh trigger_reference handling
# (= M-1 follow-up: confirm cycle_n is NOT derived from
# branches.cycles.leaf_count, and is set ONLY from canonical
# --cycle-n / --key-seq CLI input).
#
# Cases:
#   1. cyclestart  + --cycle-n 5    → trigger_reference: {cycle_n: 5}
#   2. cyclestart  (no --cycle-n)    → trigger_reference omitted
#   3. cycleend    + --cycle-n 7    → trigger_reference: {cycle_n: 7}
#   4. idrotate    + --key-seq 2    → trigger_reference: {key_seq: 2}
#   5. idrotate    (no --key-seq)    → trigger_reference omitted
#   6. cyclestart  + --key-seq 2    → ERROR (mismatch)
#   7. idrotate    + --cycle-n 5    → ERROR (mismatch)
#   8. fixtures-5closed (leaf_count=5) + no --cycle-n  → trigger_reference omitted
#      (= confirms the driver does NOT silently derive cycle_n from leaf_count)
#
# All cases use --dry-run so no real broadcast or web-push occurs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/post-anchor-event.sh"
[ -x "${SCRIPT}" ] || { echo "FAIL: ${SCRIPT} not executable" >&2; exit 1; }

TMP="$(mktemp -d -t cycle-n-reg.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

STATE_DIR="${TMP}/state"
mkdir -p "${STATE_DIR}"

STUB_SIGNER="${REPO_ROOT}/tests/post-anchor-event/fixtures/stub-signer.sh"
[ -x "${STUB_SIGNER}" ] || chmod 755 "${STUB_SIGNER}" 2>/dev/null || true

# Pick a fixture: 5closed gives leaf_count=5 (= the "trap" the M-1 fix
# was designed to NOT fall into). Use file:// URL so no network access.
FIXTURE_BASE="file://${REPO_ROOT}/tests/post-anchor-event/fixtures-5closed"

DAG="9999999999999999999999999999999999999999999999999999999999999999"

run_driver() {
	# usage: run_driver --event-type X [--cycle-n N] [--key-seq K] [...]
	ANCHOR_SIGNER="${STUB_SIGNER}" \
	PUBLIC_BASE="${FIXTURE_BASE}" \
	FY_STATE_DIR="${STATE_DIR}" \
		"${SCRIPT}" "$@" --dry-run 2>"${TMP}/stderr" || echo "__EXIT_$?__"
}

extract_trigger_ref() {
	# stdin: receipt JSON (or "" if error path). Print
	# trigger_reference as compact JSON or "<absent>".
	local input="$1"
	if [ -z "${input}" ] || ! printf '%s' "${input}" | jq empty >/dev/null 2>&1; then
		echo "<not-json>"; return
	fi
	if printf '%s' "${input}" | jq -e 'has("trigger_reference")' >/dev/null 2>&1; then
		printf '%s' "${input}" | jq -c '.trigger_reference'
	else
		echo "<absent>"
	fi
}

# =============================================================
# Case 1: cyclestart + --cycle-n 5
# =============================================================
OUT="$(run_driver --event-type cyclestart --cycle-n 5)"
TR="$(extract_trigger_ref "${OUT}")"
EXPECT='{"cycle_n":5}'
if [ "${TR}" = "${EXPECT}" ]; then
	echo "PASS  1 cyclestart + --cycle-n 5            → ${TR}"
else
	echo "FAIL  1 expected '${EXPECT}', got '${TR}'" >&2; exit 1
fi
rm -f "${STATE_DIR}/last-anchored-root"

# =============================================================
# Case 2: cyclestart, no --cycle-n
# =============================================================
OUT="$(run_driver --event-type cyclestart)"
TR="$(extract_trigger_ref "${OUT}")"
if [ "${TR}" = "<absent>" ]; then
	echo "PASS  2 cyclestart (no --cycle-n)           → trigger_reference omitted"
else
	echo "FAIL  2 expected absent, got '${TR}'" >&2; exit 1
fi
rm -f "${STATE_DIR}/last-anchored-root"

# =============================================================
# Case 3: cycleend + --cycle-n 7
# =============================================================
OUT="$(run_driver --event-type cycleend --cycle-n 7)"
TR="$(extract_trigger_ref "${OUT}")"
EXPECT='{"cycle_n":7}'
if [ "${TR}" = "${EXPECT}" ]; then
	echo "PASS  3 cycleend + --cycle-n 7              → ${TR}"
else
	echo "FAIL  3 expected '${EXPECT}', got '${TR}'" >&2; exit 1
fi
rm -f "${STATE_DIR}/last-anchored-root"

# =============================================================
# Case 4: idrotate + --key-seq 2
# =============================================================
OUT="$(run_driver --event-type idrotate --key-seq 2)"
TR="$(extract_trigger_ref "${OUT}")"
EXPECT='{"key_seq":2}'
if [ "${TR}" = "${EXPECT}" ]; then
	echo "PASS  4 idrotate + --key-seq 2              → ${TR}"
else
	echo "FAIL  4 expected '${EXPECT}', got '${TR}'" >&2; exit 1
fi
rm -f "${STATE_DIR}/last-anchored-root"

# =============================================================
# Case 5: idrotate, no --key-seq
# =============================================================
OUT="$(run_driver --event-type idrotate)"
TR="$(extract_trigger_ref "${OUT}")"
if [ "${TR}" = "<absent>" ]; then
	echo "PASS  5 idrotate (no --key-seq)             → trigger_reference omitted"
else
	echo "FAIL  5 expected absent, got '${TR}'" >&2; exit 1
fi
rm -f "${STATE_DIR}/last-anchored-root"

# =============================================================
# Case 6: cyclestart + --key-seq → ERROR
# =============================================================
OUT="$(run_driver --event-type cyclestart --key-seq 2 || true)"
if grep -q "ERROR: --key-seq is not valid for event_type 'cyclestart'" "${TMP}/stderr"; then
	echo "PASS  6 cyclestart + --key-seq              → ERROR (mismatch rejected loudly)"
else
	echo "FAIL  6 expected ERROR, stderr was:" >&2; cat "${TMP}/stderr" >&2; exit 1
fi
rm -f "${STATE_DIR}/last-anchored-root"

# =============================================================
# Case 7: idrotate + --cycle-n → ERROR
# =============================================================
OUT="$(run_driver --event-type idrotate --cycle-n 5 || true)"
if grep -q "ERROR: --cycle-n is not valid for event_type 'idrotate'" "${TMP}/stderr"; then
	echo "PASS  7 idrotate + --cycle-n                → ERROR (mismatch rejected loudly)"
else
	echo "FAIL  7 expected ERROR, stderr was:" >&2; cat "${TMP}/stderr" >&2; exit 1
fi
rm -f "${STATE_DIR}/last-anchored-root"

# =============================================================
# Case 8: fixtures-5closed (leaf_count=5) + no --cycle-n
#         → trigger_reference omitted (= the M-1 trap demonstration)
# =============================================================
OUT="$(run_driver --event-type cyclestart)"
TR="$(extract_trigger_ref "${OUT}")"
# Also assert the receipt does NOT contain {cycle_n:5} or {cycle_n:6}
# anywhere (= confirm leaf_count was not used as a derivation source).
if [ "${TR}" = "<absent>" ] && \
   ! printf '%s' "${OUT}" | grep -qE '"cycle_n"[[:space:]]*:[[:space:]]*[56]'; then
	echo "PASS  8 leaf_count=5 + no --cycle-n         → no cycle_n derivation, no {cycle_n:5} / {cycle_n:6} in output"
else
	echo "FAIL  8 cycle_n derivation detected or trigger_reference present" >&2
	echo "TR='${TR}'" >&2
	printf '%s' "${OUT}" | head -40 >&2
	exit 1
fi

echo ""
echo "Result: 8 pass, 0 fail"
echo "Confirms M-1 fix: cycle_n is set ONLY from canonical --cycle-n CLI input,"
echo "NEVER derived from branches.cycles.leaf_count or any other branch summary."
