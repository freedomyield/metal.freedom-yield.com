#!/usr/bin/env bash
# test-locked-keystore-diagnosis.sh — regression suite for the 2026-07-31
# day-of walkthrough audit finding I3.
#
# WHAT WENT WRONG: step 3/10 of scripts/run-testnet-rehearsal.sh runs
# `proton key:list` BEFORE step 4/10's unlock probe. With a LOCKED keystore
# that call prompts for a passphrase and hangs (killed by `timeout`, rc 124)
# or exits non-zero, and the old code folded both into `|| echo '[]'` and then
# reported "no public keys found … must be imported before rehearsal" — which
# sends the operator to the key ROTATION runbook when the real fix is one
# `proton key:unlock`. On cycle-transition day that is a self-inflicted delay
# in front of a time-boxed broadcast window.
#
# WHAT THIS SUITE PINS:
#   A. a timed-out key:list (locked, hanging) → exit 2 + "unlock" guidance,
#      never the "imported" diagnosis
#   B. a non-zero key:list (locked, fails fast) → same
#   C. a CLEAN key:list that really lists no keys → still fatal, but the
#      message names unlock FIRST and the rotation runbook second
#   D. a clean key:list WITH keys → step 3 proceeds past the lock check and
#      reaches the real pubkey comparison (proves A-C are not blanket
#      refusals)
#   E. missing timeout(1) → its own explicit diagnosis, not a lock/import one
#
# CHAIN: none. Every proton and curl call is served by a PATH stub; the
#        get_account response is fabricated from synthetic key bytes. No
#        network, no real keystore, no broadcast — this suite cannot reach
#        step 7/10 (safe-broadcast) because step 3/10 or 4/10 always
#        terminates it first.
#
# HERMETICITY (how the rehearsal config dir is faked without touching the
# operator's real ~/freedom-yield-rehearsal-config): run-testnet-rehearsal.sh
# resolves REHEARSAL_CFG from fyd_login_home() = `eval echo ~$(id -un)`, NOT
# from $HOME (that is the point of the §3.5 guard). This suite stubs `id` to
# print a guaranteed-nonexistent username, so bash's tilde expansion yields
# the LITERAL, RELATIVE path "~<bogus-user>" — measured, see the sibling
# suite test-source-selection-and-pubkey-decode.sh's header. Creating a
# directory of exactly that literal name inside a throwaway cwd therefore
# satisfies step 2/10's config check while touching nothing under the real
# login home.
#
# Usage:
#   bash tests/run-testnet-rehearsal/test-locked-keystore-diagnosis.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REHEARSAL_SCRIPT="${REPO_ROOT}/scripts/run-testnet-rehearsal.sh"
PUBKEY_HELPER="${REPO_ROOT}/scripts/lib/eosio-pubkey-raw-hex.js"

for f in "$REHEARSAL_SCRIPT" "$PUBKEY_HELPER"; do
	if [ ! -r "$f" ]; then
		echo "FATAL: expected file missing: $f" >&2
		exit 1
	fi
done
for c in node jq timeout; do
	if ! command -v "$c" >/dev/null 2>&1; then
		echo "FATAL: $c required for this suite" >&2
		exit 1
	fi
done
# Absolute path: case E runs the script with a PATH that deliberately has no
# timeout(1), so the harness's own bound must not be resolved through PATH.
TIMEOUT_BIN="$(command -v timeout)"

PASS=0
FAIL=0
pass() { printf 'PASS  %-72s%s\n' "$1" "${2:+ ($2)}"; PASS=$((PASS + 1)); }
fail_case() { printf 'FAIL  %-72s%s\n' "$1" "${2:+ ($2)}" >&2; FAIL=$((FAIL + 1)); }

BOGUS_USER="fyd-test-fixture-user-does-not-exist-12345"
# Fabricated account name (never a real on-chain account — repo sanitize
# policy). The chain stub answers for exactly this name.
FAKE_ACCOUNT="rehearsaltst"

WORK="$(mktemp -d -t rehearsal-locked-work.XXXXXX)"
STUB_DIR="$(mktemp -d -t rehearsal-locked-stub.XXXXXX)"
TEST_HOME="$(mktemp -d -t rehearsal-locked-home.XXXXXX)"
cleanup() { rm -rf "$WORK" "$STUB_DIR" "$TEST_HOME"; }
trap cleanup EXIT

# ---- fake rehearsal config dir at the literal relative path ----
CFG_DIR="${WORK}/~${BOGUS_USER}/freedom-yield-rehearsal-config"
mkdir -p "$CFG_DIR"
printf '%s' "$FAKE_ACCOUNT"  > "${CFG_DIR}/xpr-account"
printf 'fyhistorystub'       > "${CFG_DIR}/anchor-sink"
printf 'proton-test'         > "${CFG_DIR}/xpr-chain"

# ---- synthetic key material (fabricated bytes; never real key material) ----
SYNTH_CHAIN_PUB="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("02"+"44".repeat(32),"hex"), "EOS"));
' "$PUBKEY_HELPER")"
SYNTH_KEYSTORE_PUB="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("02"+"44".repeat(32),"hex"), "PUB_K1_"));
' "$PUBKEY_HELPER")"
if [ -z "$SYNTH_CHAIN_PUB" ] || [ -z "$SYNTH_KEYSTORE_PUB" ]; then
	echo "FATAL: could not build synthetic pubkeys" >&2
	exit 1
fi

# ---- stubs ----
cat > "${STUB_DIR}/id" <<STUB
#!/usr/bin/env bash
# Always report a guaranteed-nonexistent username (see file header).
echo "${BOGUS_USER}"
STUB

cat > "${STUB_DIR}/curl" <<STUB
#!/usr/bin/env bash
# Serves ONLY the read-only get_account shape step 3/10 asks for. Any other
# URL is refused loudly so a future edit cannot silently reach the network.
for a in "\$@"; do
  case "\$a" in
    *"/v1/chain/get_account")
      cat <<'JSON'
{"account_name":"${FAKE_ACCOUNT}","permissions":[{"perm_name":"anchor","required_auth":{"keys":[{"key":"${SYNTH_CHAIN_PUB}","weight":1}]}}]}
JSON
      exit 0 ;;
  esac
done
echo "curl stub: unexpected URL in args: \$*" >&2
exit 6
STUB

chmod +x "${STUB_DIR}/id" "${STUB_DIR}/curl"

# proton stub — behavior selected by \$STUB_PROTON_MODE at run time.
cat > "${STUB_DIR}/proton" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  key:list)
    case "\${STUB_PROTON_MODE:-keys}" in
      hang)     sleep 30 ;;                      # locked keystore: prompts, hangs
      rc)       echo "keystore is locked" >&2; exit 1 ;;
      nokeys)   echo "[]" ;;                     # clean listing, genuinely empty
      *)        echo '["${SYNTH_KEYSTORE_PUB}"]' ;;
    esac
    ;;
  chain:set)
    # HARD STOP for this suite: step 4/10 aborts here, which keeps every
    # case strictly BEFORE step 5/10 (compose), step 6/10 (broadcast token
    # creation) and step 7/10 (bin/safe-broadcast). A test suite must never
    # drive any part of the broadcast path, not even a stubbed one.
    echo "stub: chain:set refused (suite stops here by design)" >&2
    exit 1 ;;
  chain:info) echo '{"chain_id":"stub","head_block_num":1}' ;;
  account)   exit 0 ;;
  *)         echo "stub: unexpected proton subcommand: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${STUB_DIR}/proton"

run_rehearsal() {
	# cwd = $WORK so the literal "~<bogus-user>/…" config path resolves.
	# HOME = throwaway dir so the §3.5 keystore guard passes.
	# timeout 25 belt-and-suspenders: case A deliberately makes proton hang,
	# and the script's own `timeout 5` must be what ends it.
	# No script args: every case here is driven by $STUB_PROTON_MODE, and the
	# flag surface (--source / --allow-fixture / --expect-cycle) is covered by
	# the sibling suite test-source-selection-and-pubkey-decode.sh.
	( cd "$WORK" && PATH="${STUB_DIR}:${PATH}" HOME="$TEST_HOME" \
		"$TIMEOUT_BIN" 25 bash "$REHEARSAL_SCRIPT" </dev/null 2>&1 )
}

# ============================================================
# A. locked + hanging key:list -> exit 2, "unlock" guidance
# ============================================================
OUT_A="$(STUB_PROTON_MODE=hang run_rehearsal)"; RC_A=$?
if [ "$RC_A" -eq 2 ] \
   && printf '%s' "$OUT_A" | grep -qi "keystore is LOCKED" \
   && printf '%s' "$OUT_A" | grep -qF -- "proton key:unlock" \
   && ! printf '%s' "$OUT_A" | grep -qi "must be imported"; then
	pass "locked keystore (key:list hangs) -> exit 2 + unlock guidance" "rc=$RC_A"
else
	fail_case "locked keystore (key:list hangs) -> exit 2 + unlock guidance" "rc=$RC_A out=[$(printf '%s' "$OUT_A" | tr '\n' '|')]"
fi

# ============================================================
# B. locked + fast non-zero key:list -> exit 2, same guidance
# ============================================================
OUT_B="$(STUB_PROTON_MODE=rc run_rehearsal)"; RC_B=$?
if [ "$RC_B" -eq 2 ] \
   && printf '%s' "$OUT_B" | grep -qi "LOCKED keystore is the usual cause" \
   && printf '%s' "$OUT_B" | grep -qF -- "proton key:unlock" \
   && ! printf '%s' "$OUT_B" | grep -qi "must be imported"; then
	pass "locked keystore (key:list rc!=0) -> exit 2 + unlock guidance" "rc=$RC_B"
else
	fail_case "locked keystore (key:list rc!=0) -> exit 2 + unlock guidance" "rc=$RC_B out=[$(printf '%s' "$OUT_B" | tr '\n' '|')]"
fi

# ============================================================
# C. clean key:list, genuinely no keys -> fatal, unlock named FIRST
# ============================================================
OUT_C="$(STUB_PROTON_MODE=nokeys run_rehearsal)"; RC_C=$?
if [ "$RC_C" -eq 1 ] \
   && printf '%s' "$OUT_C" | grep -qi "listed no public keys" \
   && printf '%s' "$OUT_C" | grep -qi "UNLOCKED" \
   && printf '%s' "$OUT_C" | grep -qF "ANCHOR_ACCOUNT_KEY_ROTATION.md"; then
	pass "clean but keyless listing -> fatal, unlock named before rotation runbook" "rc=$RC_C"
else
	fail_case "clean but keyless listing -> fatal, unlock named before rotation runbook" "rc=$RC_C out=[$(printf '%s' "$OUT_C" | tr '\n' '|')]"
fi

# ============================================================
# D. clean key:list WITH the matching key -> lock check does not fire;
#    step 3/10 completes the real comparison and the run reaches step 4/10,
#    where the proton stub deliberately refuses `chain:set` so nothing
#    downstream (compose / token / safe-broadcast) is ever exercised.
# ============================================================
OUT_D="$(STUB_PROTON_MODE=keys run_rehearsal)"; RC_D=$?
if [ "$RC_D" -eq 1 ] \
   && printf '%s' "$OUT_D" | grep -qi "matches current on-chain key" \
   && ! printf '%s' "$OUT_D" | grep -qi "keystore is LOCKED" \
   && ! printf '%s' "$OUT_D" | grep -qi "listed no public keys" \
   && printf '%s' "$OUT_D" | grep -q "step 4/10" \
   && printf '%s' "$OUT_D" | grep -qi "chain:set proton-test failed" \
   && ! printf '%s' "$OUT_D" | grep -qE "step (5|6|7)/10"; then
	pass "unlocked keystore with matching key -> step 3 passes, halts inside step 4" "rc=$RC_D"
else
	fail_case "unlocked keystore with matching key -> step 3 passes, halts inside step 4" "rc=$RC_D out=[$(printf '%s' "$OUT_D" | tr '\n' '|')]"
fi

# ============================================================
# E. timeout(1) absent -> its own explicit diagnosis (not lock/import)
# ============================================================
# A PATH containing only the stub dir + a minimal dir of the real tools the
# script needs BEFORE the timeout check, deliberately excluding timeout.
NOTIMEOUT_DIR="$(mktemp -d -t rehearsal-locked-notimeout.XXXXXX)"
for c in bash sh env node jq sed grep awk tr cat mktemp rm printf basename dirname sort head cut; do
	p="$(command -v "$c" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "${NOTIMEOUT_DIR}/${c}" 2>/dev/null
done
OUT_E="$( cd "$WORK" && "$TIMEOUT_BIN" 25 env PATH="${STUB_DIR}:${NOTIMEOUT_DIR}" HOME="$TEST_HOME" \
	bash "$REHEARSAL_SCRIPT" </dev/null 2>&1 )"; RC_E=$?
rm -rf "$NOTIMEOUT_DIR"
if [ "$RC_E" -eq 1 ] \
   && printf '%s' "$OUT_E" | grep -qi "timeout(1) not on PATH" \
   && ! printf '%s' "$OUT_E" | grep -qi "must be imported"; then
	pass "timeout(1) missing -> explicit prerequisite failure, not a lock/import claim" "rc=$RC_E"
else
	fail_case "timeout(1) missing -> explicit prerequisite failure, not a lock/import claim" "rc=$RC_E out=[$(printf '%s' "$OUT_E" | tr '\n' '|')]"
fi

echo
echo "----------------------------------------"
echo "test-locked-keystore-diagnosis.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
