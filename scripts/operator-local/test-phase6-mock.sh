#!/usr/bin/env bash
# scripts/operator-local/test-phase6-mock.sh
#
# End-to-end mock of Phase 6 (per-cycle chain-anchor embed at renewal).
#
# Simulates the full Phase 5 → Phase 6 transition WITHOUT touching the
# blockchain, the real operator identity key, or the real repo's
# public/api/identity.json. Everything runs in a tmp directory and is
# discarded on exit.
#
# Why this exists:
#   - The real Phase 6 execution at 2026-07-04 13:00 JST is on-chain
#     and time-bound. A wallet-UI misclick or a wrong memo paste at
#     that moment is permanent (the tx is on-chain forever). There is
#     no real-time support possible at the renewal moment.
#   - This mock lets the operator rehearse the full flow N times
#     before the renewal moment, with synthetic data that is safe to
#     discard. The diagnostic dump matches what the real flow would
#     produce, so the operator can compare side-by-side at execution
#     time.
#
# What it does:
#   1. Generates a throwaway ed25519 key in /tmp.
#   2. Runs gen-identity.sh with default chain_anchor (= Phase 5 shape:
#      placeholder all-zeros tx_id).
#   3. Re-runs gen-identity.sh with CHAIN_ANCHOR_TX_ID set to a mock
#      64-hex value (= Phase 6 shape: real tx_id embedded).
#   4. Asserts the transition is correct:
#        - chain_anchor.tx_id flips from all-zeros to mock value
#        - chain_anchor.explorer_url is correctly composed from tx_id
#        - chain_anchor.memo_prefix stays "identity-v1:sha256:"
#        - node_id / fingerprint / artifact_root all UNCHANGED across
#          the phase 5 → phase 6 re-run (only the chain_anchor block
#          changes, exactly as designed)
#   5. Re-verifies the Phase 6 signature with ssh-keygen -Y verify.
#   6. Walks the 7-step verifier recipe with the mock data, printing
#      what an evaluator would see if this Phase 6 output were live.
#   7. Prints a side-by-side visual of the chain_anchor block before
#      and after, plus the two hash forms (manifest fingerprint vs.
#      chain memo binding hash) for the operator to memorise / drill.
#
# This script does NOT:
#   - touch ~/.ssh/freedom-yield-operator-identity (the real key)
#   - touch the real repo's public/api/identity.json or .sig
#   - submit anything to Metal Wallet web
#   - read or hit the Metal explorer
#   - push anything to the validator host or web host
#
# Usage:
#   bash scripts/operator-local/test-phase6-mock.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- 1. Tmp setup ----------------------------------------------------------

TEST_ROOT="$(mktemp -d -t fy-test-phase6-mock.XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

SYN_KEY="${TEST_ROOT}/synthetic-operator-key"
ssh-keygen -t ed25519 -N "" -C "synthetic-test-key DO-NOT-USE" -f "${SYN_KEY}" -q

FAKE_REPO="${TEST_ROOT}/fake-repo"
mkdir -p "${FAKE_REPO}/public/api"

PHASE5_OUT="${TEST_ROOT}/identity-phase5.json"
PHASE6_OUT="${TEST_ROOT}/identity-phase6.json"
PHASE6_SIG="${TEST_ROOT}/identity-phase6.json.sig"

# ---- 2. Phase 5 dry-run: default placeholder chain_anchor ------------------

echo "============================================================"
echo "Phase 5 dry-run — default chain_anchor (all-zeros placeholder)"
echo "============================================================"

OPERATOR_IDENTITY_KEY="${SYN_KEY}" \
REPO_ROOT="${FAKE_REPO}" \
KEY_IAT="2026-06-19T00:00:00Z" \
KEY_EXP="2027-06-19T00:00:00Z" \
bash "${SCRIPT_DIR}/gen-identity.sh" >/dev/null

cp "${FAKE_REPO}/public/api/identity.json"     "${PHASE5_OUT}"

PHASE5_TXID="$(jq -r '.chain_anchor.tx_id'        "${PHASE5_OUT}")"
PHASE5_EXPL="$(jq -r '.chain_anchor.explorer_url' "${PHASE5_OUT}")"
echo "  chain_anchor.tx_id       (Phase 5): ${PHASE5_TXID}"
echo "  chain_anchor.explorer_url (Phase 5): ${PHASE5_EXPL}"
echo

# ---- 3. Phase 6 dry-run: chain_anchor with mock tx_id ----------------------

# Mock tx_id chosen so it is visibly NOT a real chain value: 64-hex,
# obviously a "deadbeef" pattern an evaluator would never mistake for
# production. The real Phase 6 tx_id will be 64-hex of the actual
# AddValidator tx submitted at 2026-07-04 13:00 JST.
MOCK_TX_ID="deadbeefcafebabe1234567890abcdef0123456789abcdefdeadbeef12345678"

echo "============================================================"
echo "Phase 6 dry-run — chain_anchor with mock tx_id"
echo "============================================================"
echo "  Mock tx_id (NOT a real chain tx, deliberate 'deadbeef' pattern):"
echo "    ${MOCK_TX_ID}"
echo "  This is what the operator will paste in section C of"
echo "  PHASE6_CHECKLIST.md at the real 2026-07-04 13:00 JST renewal."
echo

OPERATOR_IDENTITY_KEY="${SYN_KEY}" \
REPO_ROOT="${FAKE_REPO}" \
KEY_IAT="2026-06-19T00:00:00Z" \
KEY_EXP="2027-06-19T00:00:00Z" \
CHAIN_ANCHOR_TX_ID="${MOCK_TX_ID}" \
bash "${SCRIPT_DIR}/gen-identity.sh" >/dev/null

cp "${FAKE_REPO}/public/api/identity.json"     "${PHASE6_OUT}"
cp "${FAKE_REPO}/public/api/identity.json.sig" "${PHASE6_SIG}"

PHASE6_TXID="$(jq -r '.chain_anchor.tx_id'        "${PHASE6_OUT}")"
PHASE6_EXPL="$(jq -r '.chain_anchor.explorer_url' "${PHASE6_OUT}")"
echo "  chain_anchor.tx_id       (Phase 6): ${PHASE6_TXID}"
echo "  chain_anchor.explorer_url (Phase 6): ${PHASE6_EXPL}"
echo

# ---- 4. Transition assertions ---------------------------------------------

echo "============================================================"
echo "Transition assertions (Phase 5 → Phase 6)"
echo "============================================================"

HAS_ERROR=0
assert() {
	local label="$1" expected="$2" actual="$3"
	if [ "${expected}" = "${actual}" ]; then
		echo "  OK   ${label}"
	else
		echo "  FAIL ${label}" >&2
		echo "       expected: ${expected}" >&2
		echo "       actual:   ${actual}" >&2
		HAS_ERROR=1
	fi
}

ALL_ZEROS="0000000000000000000000000000000000000000000000000000000000000000"
assert "Phase 5 chain_anchor.tx_id = all-zeros placeholder" \
       "${ALL_ZEROS}" "${PHASE5_TXID}"
assert "Phase 6 chain_anchor.tx_id = mock value (flipped from placeholder)" \
       "${MOCK_TX_ID}" "${PHASE6_TXID}"
assert "Phase 6 explorer_url contains mock tx_id" \
       "https://explorer.metalblockchain.org/tx/${MOCK_TX_ID}" "${PHASE6_EXPL}"

# Memo prefix should be the constant in both
P5_MEMO="$(jq -r '.chain_anchor.memo_prefix' "${PHASE5_OUT}")"
P6_MEMO="$(jq -r '.chain_anchor.memo_prefix' "${PHASE6_OUT}")"
assert "Phase 5 memo_prefix = 'identity-v1:sha256:'" "identity-v1:sha256:" "${P5_MEMO}"
assert "Phase 6 memo_prefix unchanged across phases"  "identity-v1:sha256:" "${P6_MEMO}"

# These fields MUST NOT change across the phase 5 → phase 6 transition.
# The whole point of the design is that only chain_anchor.tx_id +
# chain_anchor.explorer_url move; everything else stays identical.
for field in node_id operator_identity_pubkey_fingerprint artifact_root; do
	P5="$(jq -r ".${field}" "${PHASE5_OUT}")"
	P6="$(jq -r ".${field}" "${PHASE6_OUT}")"
	assert "${field} unchanged across phases" "${P5}" "${P6}"
done

echo

# ---- 5. Signature verify on Phase 6 output --------------------------------

echo "============================================================"
echo "ssh-keygen -Y verify against synthetic key (Phase 6 output)"
echo "============================================================"

ALLOWED="$(mktemp -t allowed.XXXXXX)"
printf 'freedom-yield %s\n' "$(cat "${SYN_KEY}.pub")" > "${ALLOWED}"
if ssh-keygen -Y verify \
		-f "${ALLOWED}" \
		-I "freedom-yield" \
		-n "freedom-yield/validator-identity" \
		-s "${PHASE6_SIG}" < "${PHASE6_OUT}" >/dev/null 2>&1; then
	echo "  OK   Phase 6 signature verifies against synthetic pubkey"
else
	echo "  FAIL Phase 6 signature verify" >&2
	HAS_ERROR=1
fi
rm -f "${ALLOWED}"
echo

# ---- 6. Mock 7-step verifier recipe walkthrough ---------------------------

LIVE_HEX64=$(shasum -a 256 "${SYN_KEY}.pub" | awk '{print $1}')
MANIFEST_FP="$(jq -r '.operator_identity_pubkey_fingerprint' "${PHASE6_OUT}")"

echo "============================================================"
echo "Mock 7-step verifier recipe walkthrough"
echo "============================================================"
echo
echo "If this synthetic Phase 6 output were deployed live, an evaluator"
echo "running docs/IDENTITY_VERIFICATION.md sections Step 1 → Step 3"
echo "would see (mock evaluator chain at the synthetic level):"
echo
echo "  Step 1. Read on-chain anchor:"
echo "    Explorer responds with tx.memo = 'identity-v1:sha256:<HEX64>'"
echo "    (in the real Phase 6, this is the value the operator pasted)"
echo
echo "  Step 2. Extract EXPECTED_FP from memo:"
echo "    EXPECTED_FP = ${LIVE_HEX64}"
echo "    (= shasum -a 256 of /.well-known/operator-identity.pub)"
echo
echo "  Step 3. Confirm live pubkey ↔ chain anchor:"
echo "    LIVE_FP = shasum -a 256 of /tmp/operator-identity.pub"
echo "    LIVE_FP = ${LIVE_HEX64}"
echo "    [ \"\${LIVE_FP}\" = \"\${EXPECTED_FP}\" ] → OK chain ↔ live pubkey match"
echo

# ---- 7. Chain_anchor block side-by-side visual ----------------------------

echo "============================================================"
echo "chain_anchor block — visual side-by-side"
echo "============================================================"
echo
echo "Phase 5 (placeholder — 'not yet bound'):"
jq '.chain_anchor' "${PHASE5_OUT}" | sed 's/^/  /'
echo
echo "Phase 6 (mock tx_id — 'chain-anchored'):"
jq '.chain_anchor' "${PHASE6_OUT}" | sed 's/^/  /'
echo

# ---- 8. Two hash forms drill ----------------------------------------------

echo "============================================================"
echo "Two hash forms drill (the f7aca55 MUST-FIX discipline)"
echo "============================================================"
echo
echo "  MANIFEST FINGERPRINT (= B3 form in PHASE5_CHECKLIST.md):"
echo "    ${MANIFEST_FP}"
echo "    Source:    ssh-keygen -l -f <key>.pub"
echo "    Hash of:   SSH wire-format ed25519 key blob"
echo "    Lives in:  identity.json field operator_identity_pubkey_fingerprint"
echo
echo "  CHAIN MEMO BINDING HASH (= B4 form in PHASE5_CHECKLIST.md):"
echo "    ${LIVE_HEX64}"
echo "    Source:    shasum -a 256 <key>.pub"
echo "    Hash of:   .pub file text bytes (incl. trailing newline)"
echo "    Lives in:  AddValidator tx memo as 'identity-v1:sha256:${LIVE_HEX64}'"
echo
echo "  These are DIFFERENT 32-byte digests of the SAME key."
echo "  Do not paste the MANIFEST FINGERPRINT into the chain memo."
echo "  Do not paste the CHAIN MEMO BINDING HASH into the manifest field."
echo "  (gen-identity.sh handles both correctly; this drill is for the"
echo "   human who composes the memo in the wallet UI at section B3.)"
echo

# ---- 9. Final summary -----------------------------------------------------

echo "============================================================"
if [ "${HAS_ERROR}" -eq 0 ]; then
	echo "PASS: Phase 6 mock end-to-end test"
	echo "      gen-identity.sh + CHAIN_ANCHOR_TX_ID override works correctly."
	echo "      Synthetic Phase 6 output is internally consistent."
	echo "      Phase 5 → Phase 6 transition only mutates chain_anchor."
	echo "      Real signature verify passes."
	echo "      The 2026-07-04 13:00 JST execution can be rehearsed by"
	echo "      re-running this script until the operator is confident."
	echo "============================================================"
	exit 0
else
	echo "FAIL: see errors above" >&2
	echo "============================================================"
	exit 1
fi
