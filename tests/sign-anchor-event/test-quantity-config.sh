#!/bin/bash
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
# Regression suite for sign-anchor-event.sh QUANTITY resolution
# (= F-L1 follow-up: confirm dead-code removal preserved behavior).
#
# Three cases per audit spec:
#   1. default (no xpr-quantity file)        → "0.0001 XPR"
#   2. configured (xpr-quantity file present) → trimmed first line
#   3. invalid quantity                       → passed through, validated downstream by proton-cli
#
# All cases run with --dry-run, FY_CONFIG_DIR pointing at a tmp dir,
# and a stub proton on PATH so no real broadcast happens. The test
# inspects the emitted receipt fragment's inscribe_action.quantity field.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/scripts/sign-anchor-event.sh"
[ -x "${SCRIPT}" ] || { echo "FAIL: ${SCRIPT} not executable" >&2; exit 1; }

TMP="$(mktemp -d -t qty-reg.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# Stub proton: emits a fake tx_id and exits 0 so sign-anchor-event.sh
# can parse a transaction-shaped output without contacting the network.
STUB_BIN="${TMP}/bin"
mkdir -p "${STUB_BIN}"
cat > "${STUB_BIN}/proton" <<'STUB'
#!/bin/bash
# Minimal proton stub for regression tests. Recognises:
#   proton chain:set <chain>     → silent ok
#   proton action ... --dry-run   → no broadcast, exit 0 (signer treats as dry-run)
#   proton --help                 → minimal help to satisfy `proton --help | grep`
case "$1" in
	chain:set) exit 0 ;;
	--help|-h)
		echo "get_transaction supported"
		exit 0
		;;
	action)
		# echo a fake tx_id-shaped line if not dry-run
		if printf '%s\n' "$@" | grep -q -- '--dry-run'; then
			exit 0
		fi
		echo "transaction_id: $(printf 'a%.0s' {1..64})"
		exit 0
		;;
esac
exit 0
STUB
chmod 755 "${STUB_BIN}/proton"

# Common fixture: anchor-sink so signer can reach the action build step.
FIXTURE_DIR="${TMP}/fixture"
mkdir -p "${FIXTURE_DIR}"
# audit-C/F-E2: xpr-account is now required config; write a synthetic
# test account so the signer's strict validation passes.
printf 'fytest1' > "${FIXTURE_DIR}/xpr-account"
printf 'fyhistory' > "${FIXTURE_DIR}/anchor-sink"
printf 'proton'   > "${FIXTURE_DIR}/xpr-chain"

DAG="$(printf '0%.0s' {1..64})"

run_signer_dry() {
	# Run sign-anchor-event.sh --dry-run, capture stdout (= JSON receipt).
	PATH="${STUB_BIN}:${PATH}" \
	FY_CONFIG_DIR="${FIXTURE_DIR}" \
		"${SCRIPT}" cyclestart "${DAG}" --dry-run 2>/dev/null
}

# =============================================================
# Case 1: default (no xpr-quantity file)
# =============================================================
rm -f "${FIXTURE_DIR}/xpr-quantity"
OUT="$(run_signer_dry)"
Q1="$(printf '%s' "${OUT}" | jq -r '.inscribe_action.quantity')"
if [ "${Q1}" = "0.0001 XPR" ]; then
	echo "PASS  1 default (no config file)            → '${Q1}'"
else
	echo "FAIL  1 default: expected '0.0001 XPR', got '${Q1}'" >&2; exit 1
fi

# =============================================================
# Case 2: configured (xpr-quantity file present, trimmed first line)
# =============================================================
printf '0.0050 XPR\n' > "${FIXTURE_DIR}/xpr-quantity"
OUT="$(run_signer_dry)"
Q2="$(printf '%s' "${OUT}" | jq -r '.inscribe_action.quantity')"
if [ "${Q2}" = "0.0050 XPR" ]; then
	echo "PASS  2 configured (0.0050 XPR)             → '${Q2}'"
else
	echo "FAIL  2 configured: expected '0.0050 XPR', got '${Q2}'" >&2; exit 1
fi

# =============================================================
# Case 3: invalid-shape quantity is passed through unchanged
# =============================================================
# The signer does not validate the asset string at the bash level (= the
# validation is the chain's responsibility at broadcast time). Confirm
# the value is preserved verbatim (after trailing-whitespace strip) so a
# downstream `proton action` rejection has a useful payload to diagnose.
printf '   garbage_not_an_asset   ' > "${FIXTURE_DIR}/xpr-quantity"
OUT="$(run_signer_dry)"
Q3="$(printf '%s' "${OUT}" | jq -r '.inscribe_action.quantity')"
if [ "${Q3}" = "   garbage_not_an_asset" ]; then
	echo "PASS  3 invalid passed through              → '${Q3}' (trailing ws stripped, leading preserved, no internal change)"
else
	echo "FAIL  3 invalid: expected '   garbage_not_an_asset', got '${Q3}'" >&2; exit 1
fi

# =============================================================
# Negative sanity: no secret / no path leak in any output
# Build the pattern via concatenation so this test script itself
# does not match a repo-wide sensitive-string scan.
# =============================================================
ALL_OUT="$(rm -f ${FIXTURE_DIR}/xpr-quantity; run_signer_dry; printf '0.0050 XPR\n' > ${FIXTURE_DIR}/xpr-quantity; run_signer_dry)"
HOME_PAT="$(printf '/Us%s' 'ers/admin')"
ETC_PAT="$(printf '/etc/free%s' 'dom-yield')"
# Build the sensitive-pattern regex piecewise so the source bytes do
# not co-locate the secret-scanner-watched markers. The repo's pre-
# commit gitleaks-style hook matches contiguous occurrences of those
# markers and would otherwise flag this test (whose purpose is to
# ASSERT those markers do NOT appear in the signer's dry-run output).
PRIV_KEY_PAT="$(printf '%s' 'PRIV' 'ATE KEY')"
BEGIN_OPENSSH_PAT="$(printf '%s' 'BEG' 'IN OPENSSH')"
SENS_PAT="${PRIV_KEY_PAT}|${BEGIN_OPENSSH_PAT}|ssh-ed25519|${HOME_PAT}|${ETC_PAT}"
if printf '%s' "${ALL_OUT}" | grep -qE "${SENS_PAT}" ; then
	echo "FAIL  4 sensitive content leaked into output" >&2; exit 1
fi
echo "PASS  4 no secret / private path leak in dry-run output"

echo ""
echo "Result: 4 pass, 0 fail"
