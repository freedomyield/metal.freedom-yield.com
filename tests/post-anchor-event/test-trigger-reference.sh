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
# Regression tests for the M-1 audit fix (= post-anchor-event.sh MUST NOT
# derive cycle_n from branches.cycles.leaf_count). Three cases:
#
# Case A: leaf_count=2, target cycle=3, no --cycle-n given
#         expected: no trigger_reference (or empty); no cycle_n=2; schema PASS.
# Case B: --cycle-n=3 explicit
#         expected: trigger_reference.cycle_n == 3 (number type); schema PASS.
# Case C: leaf_count ∈ {0, 5, missing}, no --cycle-n given
#         expected: no cycle_n in any field, in any of the three sub-cases.
#
# The test uses a stub signer (fixtures/stub-signer.sh) so no proton-cli /
# network call happens, and a file:// URL fixture for cycles-history.json
# so no live web fetch happens. The driver is run with --dry-run so no
# local file is installed and no push is attempted.
#
# Exit 0 on all PASS; exit 1 on first FAIL.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER="${ROOT}/scripts/post-anchor-event.sh"
STUB_SIGNER="${ROOT}/tests/post-anchor-event/fixtures/stub-signer.sh"
SCHEMA="${ROOT}/public/api/anchor-receipt.schema.v1.json"
TMP_STATE="$(mktemp -d -t post-anchor-state.XXXXXX)"
trap 'rm -rf "${TMP_STATE}"' EXIT

run_case() {
	local label="$1" fixture_dir="$2"
	shift 2
	# Remaining args are passed to the driver.
	local pub_base="file://${ROOT}/tests/post-anchor-event/${fixture_dir}"

	local out
	out="$(ANCHOR_SIGNER="${STUB_SIGNER}" \
	       PUBLIC_BASE="${pub_base}" \
	       FY_STATE_DIR="${TMP_STATE}" \
	       REPO_ROOT="${ROOT}" \
	       "${DRIVER}" --dry-run "$@" 2>/dev/null)"

	# Validate the emitted JSON parses.
	if ! printf '%s' "${out}" | jq empty >/dev/null 2>&1; then
		echo "  FAIL ${label}: driver emitted non-JSON on stdout"
		echo "  ----- driver stdout: -----"
		printf '%s\n' "${out}"
		exit 1
	fi

	# Always schema-validate the composed receipt.
	if command -v npx >/dev/null 2>&1; then
		echo "${out}" > "${TMP_STATE}/out-${label}.json"
		if ! npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv validate \
			--strict=false -c=ajv-formats --spec=draft2020 \
			-s "${SCHEMA}" -d "${TMP_STATE}/out-${label}.json" >/dev/null 2>&1
		then
			echo "  FAIL ${label}: composed receipt fails schema validation"
			exit 1
		fi
	fi

	printf '%s' "${out}"
}

assert_no_cycle_n() {
	local label="$1" body="$2"
	# trigger_reference may be absent entirely (preferred) OR present but
	# empty {} (also acceptable). The value cycle_n MUST NOT appear
	# anywhere on the object, and crucially MUST NOT equal the
	# leaf_count or leaf_count+1 of the fixture.
	if printf '%s' "${body}" | jq -e '.trigger_reference // {} | has("cycle_n")' >/dev/null 2>&1; then
		echo "  FAIL ${label}: trigger_reference.cycle_n present when no canonical input"
		echo "  body: $(printf '%s' "${body}" | jq -c '.trigger_reference // null')"
		exit 1
	fi
	echo "  OK   ${label}: trigger_reference has no cycle_n (canonical-source absent)"
}

assert_cycle_n_equals() {
	local label="$1" body="$2" expected="$3"
	local actual
	actual="$(printf '%s' "${body}" | jq -r '.trigger_reference.cycle_n // empty')"
	if [ "${actual}" != "${expected}" ]; then
		echo "  FAIL ${label}: trigger_reference.cycle_n=${actual:-<absent>}, expected ${expected}"
		exit 1
	fi
	local type
	type="$(printf '%s' "${body}" | jq -r '.trigger_reference.cycle_n | type')"
	if [ "${type}" != "number" ]; then
		echo "  FAIL ${label}: trigger_reference.cycle_n is type ${type}, expected number"
		exit 1
	fi
	echo "  OK   ${label}: trigger_reference.cycle_n == ${actual} (number type, canonical-source)"
}

echo "=== Case A: leaf_count=2, target=3, no --cycle-n given ==="
BODY="$(run_case A fixtures-2closed --event-type=cyclestart)"
assert_no_cycle_n A "${BODY}"

echo
echo "=== Case B: --cycle-n=3 explicit ==="
BODY="$(run_case B fixtures-2closed --event-type=cyclestart --cycle-n 3)"
assert_cycle_n_equals B "${BODY}" 3

echo
echo "=== Case C: leaf_count varies (0 / 5 / missing) — no derivation ==="
for variant in fixtures-0closed fixtures-5closed fixtures-noleafcount; do
	BODY="$(run_case "C-${variant}" "${variant}" --event-type=cyclestart)"
	assert_no_cycle_n "C-${variant}" "${BODY}"
done

echo
echo "=== Case D (= bonus): idrotate with --key-seq=2 ==="
BODY="$(run_case D fixtures-2closed --event-type=idrotate --key-seq 2)"
KEY_SEQ_OUT="$(printf '%s' "${BODY}" | jq -r '.trigger_reference.key_seq // empty')"
if [ "${KEY_SEQ_OUT}" = "2" ]; then
	echo "  OK   D: trigger_reference.key_seq == 2 for idrotate (canonical-source)"
else
	echo "  FAIL D: trigger_reference.key_seq=${KEY_SEQ_OUT:-<absent>}, expected 2"
	exit 1
fi
# And cycle_n absent.
assert_no_cycle_n "D-no-cycle_n" "${BODY}"

echo
echo "=== Case E (= bonus): manual event has no trigger_reference ==="
# manual not supported as --event-type today (cyclestart/cycleend/idrotate only).
# Use cycleend without --cycle-n as the closest analog to "manual recovery".
BODY="$(run_case E fixtures-2closed --event-type=cycleend)"
assert_no_cycle_n E "${BODY}"

echo
echo "ALL M-1 regression cases PASS"
