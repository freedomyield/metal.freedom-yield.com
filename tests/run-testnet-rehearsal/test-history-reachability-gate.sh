#!/usr/bin/env bash
# test-history-reachability-gate.sh — the testnet rehearsal must prove the
# post-broadcast receipt step can resolve its transaction BEFORE it broadcasts
# (PulseVM migration-readiness plan, P3 / Task 5, 2026-09-30).
#
# WHAT THIS PINS (scripts/run-testnet-rehearsal.sh step 4/10):
#   G1  history down -> exit 1 with the reachability message, BEFORE the
#       keystore unlock probe and before step 5/10 (compose)
#   G2  history up -> the check prints REACHABLE and the run continues to the
#       unlock probe (so G1 is not a blanket refusal)
#   G3  XPR_TESTNET_RPC that is an allowlisted NODE host but not one of the
#       testnet profile's history_bases -> refused before any history request
#       (the receipt at step 9/10 would refuse it AFTER the broadcast)
#   G4  XPR_TESTNET_RPC exactly a listed history base -> accepted
#   G5  a testnet profile whose values are not published (pulsevm-testnet)
#       -> exit 1 at step 3/10 with no chain call and no proton call
#   G6  static order: the check is invoked before the broadcast token is
#       written and before the broadcast wrapper is called
#   G7  the proton-cli network name and the default RPCs come from the
#       profile (chain:set receives the profile's proton_network)
#
# CHAIN: none. proton, curl and id are PATH stubs; every get_account /
#        get_info / get_actions answer is fabricated. The proton stub FAILS
#        the `proton account` unlock probe on purpose, so no case can ever
#        reach step 5/10 (compose), 6/10 (token) or 7/10 (the broadcast
#        wrapper) — a suite must never drive the broadcast path, not even a
#        stubbed one. Hermetic config dir: same `id` stub technique as
#        test-locked-keystore-diagnosis.sh (see its header).
#
# Usage: bash tests/run-testnet-rehearsal/test-history-reachability-gate.sh
# Exit codes: 0 all PASS / 1 any FAIL

# shellcheck disable=SC2016  # grep patterns below are literal, not expansions
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REHEARSAL_SCRIPT="${REHEARSAL_SCRIPT:-${REPO_ROOT}/scripts/run-testnet-rehearsal.sh}"
PUBKEY_HELPER="${REPO_ROOT}/scripts/lib/eosio-pubkey-raw-hex.js"
CFG_FILE="${REPO_ROOT}/config/a-chain-profiles.json"

for f in "$REHEARSAL_SCRIPT" "$PUBKEY_HELPER" "$CFG_FILE"; do
	[ -r "$f" ] || { echo "FATAL: expected file missing: $f" >&2; exit 1; }
done
for c in node jq timeout; do
	command -v "$c" >/dev/null 2>&1 || { echo "FATAL: $c required for this suite" >&2; exit 1; }
done
TIMEOUT_BIN="$(command -v timeout)"

PASS=0
FAIL=0
pass() { printf 'PASS  %-72s%s\n' "$1" "${2:+ ($2)}"; PASS=$((PASS + 1)); }
fail_case() { printf 'FAIL  %-72s%s\n' "$1" "${2:+ ($2)}" >&2; FAIL=$((FAIL + 1)); }

BOGUS_USER="fyd-test-fixture-user-does-not-exist-67890"
FAKE_ACCOUNT="rehearsaltst"   # fabricated, never a real on-chain account
TESTNET_CID="$(jq -r '.profiles["xpr-testnet"].chain_id' "$CFG_FILE")"
TESTNET_NET="$(jq -r '.profiles["xpr-testnet"].proton_network' "$CFG_FILE")"
TESTNET_BASE="$(jq -r '.profiles["xpr-testnet"].history_bases[0]' "$CFG_FILE")"
TESTNET_NODE="$(jq -r '.profiles["xpr-testnet"].node_hosts[0]' "$CFG_FILE")"
TESTNET_EXPLORER="$(jq -r '.profiles["xpr-testnet"].explorer_base' "$CFG_FILE")"

WORK="$(mktemp -d -t rehearsal-hist-work.XXXXXX)"
STUB_DIR="$(mktemp -d -t rehearsal-hist-stub.XXXXXX)"
TEST_HOME="$(mktemp -d -t rehearsal-hist-home.XXXXXX)"
CALLS="${WORK}/calls.log"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -rf "$WORK" "$STUB_DIR" "$TEST_HOME"; }
trap cleanup EXIT

CFG_DIR="${WORK}/~${BOGUS_USER}/freedom-yield-rehearsal-config"
mkdir -p "$CFG_DIR"
printf '%s' "$FAKE_ACCOUNT" > "${CFG_DIR}/xpr-account"
printf 'fyhistorystub'      > "${CFG_DIR}/anchor-sink"
printf '%s' "$TESTNET_NET"  > "${CFG_DIR}/xpr-chain"

SYNTH_CHAIN_PUB="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("02"+"55".repeat(32),"hex"), "EOS"));
' "$PUBKEY_HELPER")"
SYNTH_KEYSTORE_PUB="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("02"+"55".repeat(32),"hex"), "PUB_K1_"));
' "$PUBKEY_HELPER")"
[ -n "$SYNTH_CHAIN_PUB" ] && [ -n "$SYNTH_KEYSTORE_PUB" ] || { echo "FATAL: could not build synthetic pubkeys" >&2; exit 1; }
BLOCK_ID="$(printf 'b%.0s' $(seq 1 64))"

cat > "${STUB_DIR}/id" <<STUB
#!/usr/bin/env bash
echo "${BOGUS_USER}"
STUB

# curl stub: logs every call; answers get_account (step 3/10) always, and the
# history reads of the reachability check only when STUB_HISTORY=up.
cat > "${STUB_DIR}/curl" <<STUB
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
printf 'curl %s\n' "\$url" >> "${CALLS}"
case "\$url" in
  */v1/chain/get_account)
    printf '%s' '{"account_name":"${FAKE_ACCOUNT}","permissions":[{"perm_name":"anchor","required_auth":{"keys":[{"key":"${SYNTH_CHAIN_PUB}","weight":1}]}}]}'
    exit 0 ;;
  */v1/chain/get_info)
    [ "\${STUB_HISTORY:-down}" = up ] || exit 22
    printf '%s' '{"chain_id":"${TESTNET_CID}","head_block_num":5000}'
    exit 0 ;;
  */v2/history/get_actions*)
    [ "\${STUB_HISTORY:-down}" = up ] || exit 22
    printf '%s' '{"actions":[{"block_num":4999,"block_id":"${BLOCK_ID}","trx_id":"$(printf 'c%.0s' $(seq 1 64))"}]}'
    exit 0 ;;
esac
echo "curl stub: unexpected URL: \$url" >&2
exit 6
STUB

# proton stub: the `account` unlock probe FAILS by design (hard stop inside
# step 4/10). Every call is logged so the order can be asserted.
cat > "${STUB_DIR}/proton" <<STUB
#!/usr/bin/env bash
printf 'proton %s\n' "\$*" >> "${CALLS}"
case "\${1:-}" in
  key:list)   echo '["${SYNTH_KEYSTORE_PUB}"]' ;;
  chain:set)  exit 0 ;;
  chain:info) echo '{"chain_id":"${TESTNET_CID}","head_block_num":5000}' ;;
  account)    echo "stub: account probe refused (suite stops here by design)" >&2; exit 1 ;;
  *)          echo "stub: unexpected proton subcommand: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${STUB_DIR}/id" "${STUB_DIR}/curl" "${STUB_DIR}/proton"

run_rehearsal() { # env assignments may precede the call
	: > "$CALLS"
	( cd "$WORK" && PATH="${STUB_DIR}:${PATH}" HOME="$TEST_HOME" \
		"$TIMEOUT_BIN" 60 bash "$REHEARSAL_SCRIPT" </dev/null 2>&1 )
}
never_past_step4() { ! printf '%s' "$1" | grep -qE "step (5|6|7|8|9|10)/10"; }
line_of() { grep -nE -- "$1" "$CALLS" | head -n 1 | cut -d: -f1; }

# ---- G1: history down -> stop before the unlock probe and before compose ----
OUT="$(STUB_HISTORY=down run_rehearsal)"; RC=$?
if [ "$RC" -eq 1 ] \
	&& printf '%s' "$OUT" | grep -qF "pre-broadcast history reachability check failed" \
	&& printf '%s' "$OUT" | grep -qF "Nothing was composed, signed or broadcast" \
	&& ! grep -q '^proton account' "$CALLS" \
	&& never_past_step4 "$OUT"; then
	pass "G1 history down -> exit 1 before the unlock probe and before step 5/10" "rc=$RC"
else
	fail_case "G1 history down -> exit 1 before the unlock probe and before step 5/10" "rc=$RC out=[$(printf '%s' "$OUT" | tail -5 | tr '\n' '|')]"
fi

# ---- G2: history up -> REACHABLE, then the unlock probe (stub stops there) --
OUT="$(STUB_HISTORY=up run_rehearsal)"; RC=$?
if [ "$RC" -eq 2 ] \
	&& printf '%s' "$OUT" | grep -qE "^REACHABLE profile=xpr-testnet chain_id=${TESTNET_CID} base=${TESTNET_BASE} mode=liveness" \
	&& [ -n "$(line_of '/v2/history/get_actions')" ] && [ -n "$(line_of '^proton account')" ] \
	&& [ "$(line_of '/v2/history/get_actions')" -lt "$(line_of '^proton account')" ] \
	&& never_past_step4 "$OUT"; then
	pass "G2 history up -> REACHABLE (liveness, profile base), then the unlock probe" "rc=$RC"
else
	fail_case "G2 history up -> REACHABLE (liveness, profile base), then the unlock probe" "rc=$RC out=[$(printf '%s' "$OUT" | tail -6 | tr '\n' '|')]"
fi

# ---- G3: XPR_TESTNET_RPC = a node host that is not a history base ----------
OUT="$(STUB_HISTORY=up XPR_TESTNET_RPC="https://${TESTNET_NODE}" run_rehearsal)"; RC=$?
if [ "$RC" -eq 1 ] \
	&& printf '%s' "$OUT" | grep -qF "is not one of profile xpr-testnet's history_bases" \
	&& printf '%s' "$OUT" | grep -qF "must EXACTLY equal one of: ${TESTNET_BASE}" \
	&& ! grep -qE '/v2/history|/v1/chain/get_info' "$CALLS" \
	&& ! grep -q '^proton account' "$CALLS" \
	&& never_past_step4 "$OUT"; then
	pass "G3 unlisted XPR_TESTNET_RPC refused before any history request and before the broadcast" "rc=$RC"
else
	fail_case "G3 unlisted XPR_TESTNET_RPC refused before any history request and before the broadcast" "rc=$RC out=[$(printf '%s' "$OUT" | tail -6 | tr '\n' '|')]"
fi

# ---- G4: XPR_TESTNET_RPC = exactly the listed base -> accepted -------------
OUT="$(STUB_HISTORY=up XPR_TESTNET_RPC="$TESTNET_BASE" run_rehearsal)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qE "^REACHABLE .*base=${TESTNET_BASE} "; then
	pass "G4 XPR_TESTNET_RPC equal to a listed history base is accepted" "rc=$RC"
else
	fail_case "G4 XPR_TESTNET_RPC equal to a listed history base is accepted" "rc=$RC out=[$(printf '%s' "$OUT" | tail -4 | tr '\n' '|')]"
fi

# ---- G5: unpublished testnet profile -> refuse at step 3, nothing contacted -
OUT="$(STUB_HISTORY=up FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet run_rehearsal)"; RC=$?
if [ "$RC" -eq 1 ] \
	&& printf '%s' "$OUT" | grep -qF "has no proton_network" \
	&& [ ! -s "$CALLS" ] \
	&& never_past_step4 "$OUT"; then
	pass "G5 pulsevm-testnet (values unpublished) -> exit 1 at step 3, no chain or proton call" "rc=$RC"
else
	fail_case "G5 pulsevm-testnet (values unpublished) -> exit 1 at step 3, no chain or proton call" "rc=$RC calls=[$(tr '\n' '|' < "$CALLS")]"
fi

# ---- G6: static order in the script ----------------------------------------
L_CHECK="$(grep -nE '^bash "\$\{REPO_ROOT\}/scripts/check-anchor-history-reachable\.sh"' "$REHEARSAL_SCRIPT" | head -n1 | cut -d: -f1)"
L_TOKEN="$(grep -nE '> "\$TOKEN_FILE"' "$REHEARSAL_SCRIPT" | head -n1 | cut -d: -f1)"
L_BCAST="$(grep -nE 'bash "\$\{REPO_ROOT\}/bin/safe-broadcast"' "$REHEARSAL_SCRIPT" | head -n1 | cut -d: -f1)"
if [ -n "$L_CHECK" ] && [ -n "$L_TOKEN" ] && [ -n "$L_BCAST" ] \
	&& [ "$L_CHECK" -lt "$L_TOKEN" ] && [ "$L_CHECK" -lt "$L_BCAST" ] \
	&& grep -qE -- '--chain=testnet-a --rpc="\$TESTNET_RPC"' "$REHEARSAL_SCRIPT"; then
	pass "G6 the check (with --rpc=\$TESTNET_RPC) precedes the token write and the broadcast call" "check:${L_CHECK} token:${L_TOKEN} broadcast:${L_BCAST}"
else
	fail_case "G6 the check (with --rpc=\$TESTNET_RPC) precedes the token write and the broadcast call" "check:${L_CHECK:-none} token:${L_TOKEN:-none} broadcast:${L_BCAST:-none}"
fi

# ---- G7: values come from the profile --------------------------------------
OUT="$(STUB_HISTORY=up run_rehearsal)"; RC=$?
if grep -qxF "proton chain:set ${TESTNET_NET}" "$CALLS" \
	&& grep -qF "curl https://${TESTNET_NODE}/v1/chain/get_account" "$CALLS" \
	&& grep -qF 'explorer URL:        ${TESTNET_EXPLORER}/${TX_ID}' "$REHEARSAL_SCRIPT" \
	&& [ -n "$TESTNET_EXPLORER" ]; then
	pass "G7 chain:set / get_account host / explorer come from the xpr-testnet profile"
else
	fail_case "G7 chain:set / get_account host / explorer come from the xpr-testnet profile" "calls=[$(tr '\n' '|' < "$CALLS")]"
fi

echo
echo "test-history-reachability-gate.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
