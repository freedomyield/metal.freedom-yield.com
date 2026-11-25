#!/usr/bin/env bash
# test-rehearsal-wrapper-exits.sh — how scripts/run-testnet-rehearsal.sh reads the
# exit code and stdout of the broadcast wrapper, and how it passes the testnet-only
# override flag (double-inscription guard, design 2026-10-16 sections 4 and 7 S2;
# lane T3).
#
# CHAIN: none. Unlike the older suites in this directory, this one runs the
#        rehearsal THROUGH step 7 (the wrapper call) and on to step 10, so it
#        guarantees by construction that no real sender is reachable:
#          - the run uses a COPY of the scripts in a throwaway tree; the tree's
#            bin/safe-broadcast, check-anchor-history-reachable.sh and
#            gen-anchor-receipt.sh are stamped stubs ("# T3-STUB-WRAPPER" on their
#            second line); the suite stops with FATAL if one of them is not the
#            stamped stub or equals the repository's file;
#          - proton, curl and id are PATH stubs; a proton call whose subcommand
#            starts with "transaction" or "action" is recorded and fails, and
#            every case asserts that the record is empty;
#          - every path the rehearsal writes is under a throwaway dir (the login
#            home is a made-up user, the token and the sign output are redirected).
#        PRIME_DIRECTIVE: TESTNET-FIRST — nothing here can send anything.
#
# Properties (case names start with the id; the lane report maps mutations):
#   S2  the class of the wrapper result decides the exit:
#         rc 0 + exactly one 64-hex line -> 0, the sentinel line, the receipt step runs once
#         rc 0 + any other stdout        -> 9  (OUTCOME UNKNOWN)
#         rc 2..8                        -> 1  (nothing landed)
#         rc 9, 10, any unlisted rc      -> 9
#         rc 11                          -> 10 (already inscribed on testnet; the flag text)
#         rc 12, 13                      -> 11
#       For 9, 10 and 11 the receipt step is not run and no sentinel line is printed.
#   S2-flag  --allow-existing-cycle-anchor reaches the wrapper only when given, once, last.
#   S2-pass  the wrapper's "expiration=" line and its WARNING lines reach the operator.
#   R6       the token goes to FYD_BROADCAST_TOKEN_FILE (the wrapper's own definition).
#   S1-realpaths  the real operator paths are untouched.
#
# The rc lists below are the same as tests/sign-anchor-event/
# test-sign-anchor-event-wrapper-exits.sh, which is what ties the two class tables together.
#
# Usage: bash tests/run-testnet-rehearsal/test-rehearsal-wrapper-exits.sh
# Exit codes: 0 all PASS / 1 any FAIL

# shellcheck disable=SC2016  # fixture text below is literal, not an expansion
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUBKEY_HELPER="${REPO_ROOT}/scripts/lib/eosio-pubkey-raw-hex.js"
PROFILES="${REPO_ROOT}/config/a-chain-profiles.json"
ANCHOR_EXAMPLE="${REPO_ROOT}/public/api/anchor-source.example.json"
REAL_WRAPPER="${REPO_ROOT}/bin/safe-broadcast"
STUB_STAMP="# T3-STUB-WRAPPER"
# the rehearsal script that is copied into the tree (a lane may point it at a patched copy)
REHEARSAL_SCRIPT_SRC="${REHEARSAL_SCRIPT_SRC:-${REPO_ROOT}/scripts/run-testnet-rehearsal.sh}"

for f in "$REHEARSAL_SCRIPT_SRC" "${REPO_ROOT}/scripts/sign-anchor-event.sh" \
	"${REPO_ROOT}/scripts/lib/require-keystore-home.sh" "${REPO_ROOT}/scripts/lib/operator-paths.sh" "${REPO_ROOT}/scripts/lib/a-chain-profile.sh" \
	"$PUBKEY_HELPER" "$PROFILES" "$ANCHOR_EXAMPLE" "$REAL_WRAPPER"; do
	[ -r "$f" ] || { echo "FATAL: expected file missing: $f" >&2; exit 1; }
done
for c in node jq timeout; do
	command -v "$c" >/dev/null 2>&1 || { echo "FATAL: $c required for this suite" >&2; exit 1; }
done
TIMEOUT_BIN="$(command -v timeout)"

# shellcheck source=tests/lib/assert.sh
. "${REPO_ROOT}/tests/lib/assert.sh"

# ---- the same rc lists as the sign-anchor-event suite --------------------------
RC_NOT_SENT="2 3 4 5 6 7 8"
RC_UNKNOWN="9 10"
RC_UNLISTED="1 14 126 127 130"

WORK="$(mktemp -d -t fya-t3-reh-work.XXXXXX)"
TEST_HOME="$(mktemp -d -t fya-t3-reh-home.XXXXXX)"
OUTDIR="$(mktemp -d -t fya-t3-reh-out.XXXXXX)"
TOKEN_PATH="${WORK}/token-file"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -rf "$WORK" "$TEST_HOME" "$OUTDIR"; }
trap cleanup EXIT

TREE="${WORK}/tree"
STUB="${WORK}/stub"
PATHSTUB="${WORK}/pathstub"
BOGUS_USER="fyd-test-fixture-user-does-not-exist-67890"
mkdir -p "${TREE}/scripts/lib" "${TREE}/bin" "${TREE}/config" "$STUB" "$PATHSTUB" "${WORK}/src"

# ---- copy what the rehearsal and sign-anchor-event run, from the real files ----
cp "$REHEARSAL_SCRIPT_SRC" "${TREE}/scripts/run-testnet-rehearsal.sh"
cp "${REPO_ROOT}/scripts/sign-anchor-event.sh" "${TREE}/scripts/"
cp "${REPO_ROOT}/scripts/lib/require-keystore-home.sh" "${REPO_ROOT}/scripts/lib/operator-paths.sh" "${REPO_ROOT}/scripts/lib/a-chain-profile.sh" \
	"$PUBKEY_HELPER" "${TREE}/scripts/lib/"
cp "$PROFILES" "${TREE}/config/"
cp "$ANCHOR_EXAMPLE" "${WORK}/src/anchor-source.example.json"

# ---- stamped stubs inside the tree ---------------------------------------------
cat > "${TREE}/bin/safe-broadcast" <<STUBEOF
#!/usr/bin/env bash
${STUB_STAMP}
S="${STUB}"
( IFS=\$'\\t'; printf '%s\\n' "\$*" ) >> "\${S}/calls"
[ -r "\${S}/stderr" ] && cat "\${S}/stderr" >&2
[ -r "\${S}/stdout" ] && cat "\${S}/stdout"
rc=0
[ -r "\${S}/rc" ] && rc="\$(cat "\${S}/rc")"
exit "\$rc"
STUBEOF
cat > "${TREE}/scripts/check-anchor-history-reachable.sh" <<STUBEOF
#!/usr/bin/env bash
${STUB_STAMP}
printf '%s\\n' "\$*" >> "${STUB}/history-calls"
echo "REACHABLE stub"
exit 0
STUBEOF
cat > "${TREE}/scripts/gen-anchor-receipt.sh" <<STUBEOF
#!/usr/bin/env bash
${STUB_STAMP}
printf '%s\\n' "\$*" >> "${STUB}/receipt-calls"
exit 0
STUBEOF
chmod 755 "${TREE}/bin/safe-broadcast" "${TREE}/scripts/check-anchor-history-reachable.sh" "${TREE}/scripts/gen-anchor-receipt.sh"

# ---- FATAL unless every sender-side file of the tree is a stamped stub ---------
for pair in "bin/safe-broadcast:${REAL_WRAPPER}" \
	"scripts/check-anchor-history-reachable.sh:${REPO_ROOT}/scripts/check-anchor-history-reachable.sh" \
	"scripts/gen-anchor-receipt.sh:${REPO_ROOT}/scripts/gen-anchor-receipt.sh"; do
	rel="${pair%%:*}"
	real="${pair#*:}"
	if ! sed -n '2p' "${TREE}/${rel}" | grep -qxF -- "$STUB_STAMP" || { [ -r "$real" ] && cmp -s "${TREE}/${rel}" "$real"; }; then
		echo "FATAL: the tree's ${rel} is not the stamped stub (or equals the real one)" >&2
		exit 1
	fi
done

# ---- fixtures ------------------------------------------------------------------
FAKE_ACCOUNT="fxanchor"
FAKE_SINK="fxsink"
TESTNET_CID="$(jq -r '.profiles["xpr-testnet"].chain_id' "$PROFILES")"
TESTNET_NET="$(jq -r '.profiles["xpr-testnet"].proton_network' "$PROFILES")"
# The rehearsal config dir and the dry-run log / receipt dir are the definition's
# names under the (unresolvable) login home.
# shellcheck source=scripts/lib/operator-paths.sh
. "${REPO_ROOT}/scripts/lib/operator-paths.sh"
CFG_DIR="${WORK}/~${BOGUS_USER}/${FYD_REHEARSAL_CONFIG_REL}"
mkdir -p "$CFG_DIR" "${WORK}/~${BOGUS_USER}/${FYD_BACKUP_DIR_REL}"
printf '%s' "$FAKE_ACCOUNT" > "${CFG_DIR}/xpr-account"
printf '%s' "$FAKE_SINK" > "${CFG_DIR}/anchor-sink"
printf '%s' "$TESTNET_NET" > "${CFG_DIR}/xpr-chain"
SYNTH_CHAIN_PUB="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("02"+"55".repeat(32),"hex"), "EOS"));
' "$PUBKEY_HELPER")"
SYNTH_KEYSTORE_PUB="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("02"+"55".repeat(32),"hex"), "PUB_K1_"));
' "$PUBKEY_HELPER")"
[ -n "$SYNTH_CHAIN_PUB" ] && [ -n "$SYNTH_KEYSTORE_PUB" ] || { echo "FATAL: could not build synthetic pubkeys" >&2; exit 1; }
SAMPLE_TX="$(printf 'ab12cd34%.0s' 1 2 3 4 5 6 7 8)"
EXPIRATION_LINE="expiration=2026-01-02T03:04:05"
WARNING_LINE_1="WARNING (check A): sample first warning line"
WARNING_LINE_2="WARNING (check A): sample second warning line"

cat > "${PATHSTUB}/id" <<STUBEOF
#!/usr/bin/env bash
echo "${BOGUS_USER}"
STUBEOF
cat > "${PATHSTUB}/curl" <<STUBEOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
printf 'curl %s\\n' "\$url" >> "${STUB}/curl-calls"
case "\$url" in
  */v1/chain/get_account)
    printf '%s' '{"account_name":"${FAKE_ACCOUNT}","permissions":[{"perm_name":"anchor","required_auth":{"keys":[{"key":"${SYNTH_CHAIN_PUB}","weight":1}]}}]}'
    exit 0 ;;
esac
echo "curl stub: unexpected URL: \$url" >&2
exit 6
STUBEOF
cat > "${PATHSTUB}/proton" <<STUBEOF
#!/usr/bin/env bash
case "\${1:-}" in
  key:list)   echo '["${SYNTH_KEYSTORE_PUB}"]' ;;
  chain:set)  exit 0 ;;
  chain:info) echo '{"chain_id":"${TESTNET_CID}","head_block_num":5000}' ;;
  account)    exit 0 ;;
  transaction*|action*) printf 'proton %s\\n' "\$*" >> "${STUB}/proton-send-calls"; exit 1 ;;
  *)          printf 'proton %s\\n' "\$*" >> "${STUB}/proton-other-calls"; exit 1 ;;
esac
STUBEOF
chmod 755 "${PATHSTUB}/id" "${PATHSTUB}/curl" "${PATHSTUB}/proton"

# ---- the real operator paths: snapshot now, compare at the end -----------------
if command -v sha256sum >/dev/null 2>&1; then
	real_hash() { [ -r "$1" ] && sha256sum "$1" | awk '{print $1}' || echo "ABSENT"; }
else
	real_hash() { [ -r "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "ABSENT"; }
fi
REAL_PATHS="/tmp/fya-testnet-sign-output.json /tmp/fya-mainnet-sign-output.json /tmp/fyd-broadcast-token"
REAL_BEFORE=""
for p in $REAL_PATHS; do REAL_BEFORE="${REAL_BEFORE}$(real_hash "$p") "; done

# ---- the runner ----------------------------------------------------------------
# run_reh <rc> <stdout-text|@absent> <stderr-mode> [rehearsal args...]
#   stderr-mode: plain | pass (expiration + two WARNING lines + 40 filler lines) | none
#   sets: GOT_RC, OUT_FILE, ERR_FILE
run_reh() {
	local rc="$1" text="$2" emode="$3" i
	shift 3
	rm -f "${STUB}/calls" "${STUB}/rc" "${STUB}/stdout" "${STUB}/stderr" "${STUB}/history-calls" \
		"${STUB}/receipt-calls" "${STUB}/curl-calls" "${STUB}/proton-send-calls" "${STUB}/proton-other-calls"
	rm -f "$TOKEN_PATH"
	rm -f "${OUTDIR}"/*.json
	printf '%s' "$rc" > "${STUB}/rc"
	[ "$text" = "@absent" ] || printf '%s' "$text" > "${STUB}/stdout"
	case "$emode" in
		plain) printf '%s\n' "stub-wrapper-stderr-line" > "${STUB}/stderr" ;;
		pass)
			{
				printf '%s\n' "$EXPIRATION_LINE"
				printf '%s\n' "$WARNING_LINE_1"
				i=0
				while [ "$i" -lt 40 ]; do printf 'filler-line-%s\n' "$i"; i=$((i + 1)); done
				printf '%s\n' "$WARNING_LINE_2"
			} > "${STUB}/stderr" ;;
		none) : ;;
	esac
	OUT_FILE="${WORK}/last.out"
	ERR_FILE="${WORK}/last.err"
	( cd "$WORK" && PATH="${PATHSTUB}:${PATH}" HOME="$TEST_HOME" FY_SIGN_OUTPUT_DIR="$OUTDIR" \
		FYD_BROADCAST_TOKEN_FILE="$TOKEN_PATH" \
		"$TIMEOUT_BIN" 120 bash "${TREE}/scripts/run-testnet-rehearsal.sh" \
		--source="${WORK}/src/anchor-source.example.json" --allow-fixture "$@" \
		> "$OUT_FILE" 2> "$ERR_FILE" </dev/null )
	GOT_RC=$?
}

count_lines() { [ -s "$1" ] && grep -c '' "$1" || echo 0; }
wrapper_calls() { count_lines "${STUB}/calls"; }
receipt_calls() { count_lines "${STUB}/receipt-calls"; }
send_calls() { count_lines "${STUB}/proton-send-calls"; }
# the n-th field (1-based, TAB separated) of the first wrapper call line
wrapper_arg() { head -n 1 "${STUB}/calls" | awk -F'\t' -v n="$1" '{print $n}'; }
sentinel_present() { grep -qF "TESTNET REHEARSAL COMPLETE testnet_tx_id=" "$OUT_FILE"; }

# did the run reach the wrapper (step 7) at all? (a case that never got there proves nothing)
reached_wrapper() { [ "$(wrapper_calls)" = "1" ]; }

# why_not <expected-exit> <receipt-calls-want> <word>… — empty when every fact holds
why_not() {
	local want="$1" rcalls="$2" w
	shift 2
	[ "$GOT_RC" = "$want" ] || { printf 'rc=%s want %s (tail: %s)' "$GOT_RC" "$want" "$(tail -n 2 "$ERR_FILE" | tr '\n' '|')"; return; }
	reached_wrapper || { printf 'the wrapper stub was called %s times' "$(wrapper_calls)"; return; }
	[ "$(receipt_calls)" = "$rcalls" ] || { printf 'receipt stub called %s times want %s' "$(receipt_calls)" "$rcalls"; return; }
	[ "$(send_calls)" = "0" ] || { printf 'proton was asked to send'; return; }
	for w in "$@"; do
		grep -qF -- "$w" "$ERR_FILE" || { printf 'stderr lacks: %s' "$w"; return; }
	done
}

case_fail() { # <name> <want-exit> <rc> <stdout> <word>…   (the receipt step must not run)
	local name="$1" want="$2" rc="$3" text="$4" why
	shift 4
	run_reh "$rc" "$text" plain
	why="$(why_not "$want" 0 "$@")"
	if [ -z "$why" ] && sentinel_present; then why="the sentinel line was printed"; fi
	if [ -z "$why" ]; then t_pass "$name"; else t_fail "$name" "$why"; fi
}

rc_word_for_not_sent() { printf '%s' "safe-broadcast refused or the chain rejected the tx — nothing landed"; }

# ---- control: the stubs record what they are called with ------------------------
run_reh 0 "${SAMPLE_TX}
" plain
if [ "$GOT_RC" = "0" ] && reached_wrapper && [ "$(receipt_calls)" = "1" ] && [ -s "${STUB}/history-calls" ]; then
	t_pass "S2-control: the run reaches the wrapper stub, the history-check stub and the receipt stub once"
else
	t_fail "S2-control: the run reaches the wrapper stub, the history-check stub and the receipt stub once" \
		"rc=$GOT_RC wrapper=$(wrapper_calls) receipt=$(receipt_calls) tail=$(tail -n 3 "$ERR_FILE" | tr '\n' '|')"
fi
"${PATHSTUB}/proton" transaction control-probe >/dev/null 2>&1
if [ "$(send_calls)" = "1" ]; then
	t_pass "S2-control: the stub proton records a send-shaped call, so a 0 count means it was never asked"
else
	t_fail "S2-control: the stub proton records a send-shaped call, so a 0 count means it was never asked" "count=$(send_calls)"
fi

# ---- S2: rc 0 with one valid 64-hex line -> 0 -----------------------------------
run_reh 0 "${SAMPLE_TX}
" plain
if [ "$GOT_RC" = "0" ] && grep -qF "TESTNET REHEARSAL COMPLETE testnet_tx_id=${SAMPLE_TX}" "$OUT_FILE" \
	&& [ "$(receipt_calls)" = "1" ] && [ "$(send_calls)" = "0" ] && reached_wrapper; then
	t_pass "S2-rc0-valid-tx-id -> 0, the sentinel line carries the tx id, the receipt step ran once"
else
	t_fail "S2-rc0-valid-tx-id -> 0, the sentinel line carries the tx id, the receipt step ran once" "rc=$GOT_RC receipt=$(receipt_calls)"
fi

# ---- S2: rc 0 with a stdout that is not exactly one 64-hex id -> 9 --------------
HEX63="${SAMPLE_TX%?}"
HEX65="${SAMPLE_TX}a"
UPPER="A${SAMPLE_TX#?}"
FULLWIDTH="１${SAMPLE_TX#?}"
W9="FAIL (9): OUTCOME UNKNOWN — the testnet push MAY have landed"
WAIT9="do not re-run 7a until the expiration printed above is irreversibly past"
case_fail "S2-rc0-empty-stdout -> 9" 9 0 "" "$W9" "wrapper exit 0" "$WAIT9"
case_fail "S2-rc0-63-hex -> 9" 9 0 "$HEX63" "$W9"
case_fail "S2-rc0-65-hex -> 9" 9 0 "$HEX65" "$W9"
case_fail "S2-rc0-uppercase-hex -> 9" 9 0 "$UPPER" "$W9"
case_fail "S2-rc0-fullwidth-digit-in-64-chars -> 9" 9 0 "$FULLWIDTH" "$W9"
case_fail "S2-rc0-two-lines (a line before the id) -> 9" 9 0 "a-line-before
${SAMPLE_TX}" "$W9"
case_fail "S2-rc0-two-lines (a line after the id) -> 9" 9 0 "${SAMPLE_TX}
a-line-after" "$W9"
case_fail "S2-rc0-id-then-trailing-text-on-the-line -> 9" 9 0 "${SAMPLE_TX} trailing" "$W9"
case_fail "S2-rc0-no-stdout-at-all -> 9" 9 0 "@absent" "$W9"

# ---- S2: rc 2..8 -> 1 -----------------------------------------------------------
for rc in $RC_NOT_SENT; do
	case_fail "S2-wrapper-rc${rc} -> 1, nothing landed" 1 "$rc" "" \
		"$(rc_word_for_not_sent)" "wrapper exit ${rc}"
done

# ---- S2: rc 9, 10 and the unlisted rcs -> 9 -------------------------------------
for rc in $RC_UNKNOWN $RC_UNLISTED; do
	case_fail "S2-wrapper-rc${rc} -> 9 OUTCOME UNKNOWN" 9 "$rc" "" "$W9" "wrapper exit ${rc}" "$WAIT9"
done
case_fail "S2-wrapper-rc10-with-a-valid-id-on-stdout -> 9" 9 10 "$SAMPLE_TX" "$W9"
case_fail "S2-wrapper-rc6-with-a-valid-id-on-stdout -> 1" 1 6 "$SAMPLE_TX" "nothing landed"

# ---- S2: rc 11 -> 10, rc 12 -> 11, rc 13 -> 11 ----------------------------------
case_fail "S2-wrapper-rc11 -> 10 ALREADY INSCRIBED ON TESTNET, names the flag" 10 11 "" \
	"FAIL (10): ALREADY INSCRIBED ON TESTNET" "wrapper exit 11" "--allow-existing-cycle-anchor"
case_fail "S2-wrapper-rc12 -> 11 absence cannot be proven, names the flag for the empty-history case" 11 12 "" \
	"FAIL (11): NOT SENT — cannot prove the cycle is absent on testnet" "wrapper exit 12" "wait and re-run" \
	"--allow-existing-cycle-anchor"
case_fail "S2-wrapper-rc13 -> 11 an earlier attempt may still land" 11 13 "" \
	"FAIL (11): NOT SENT — an earlier attempt for this memo prefix may still land" "wrapper exit 13" \
	"wait until its expiration is irreversibly past"

# ---- S2-flag: the override flag reaches the wrapper only when given, once, last ---
run_reh 0 "${SAMPLE_TX}
" plain
if reached_wrapper && [ "$(wrapper_arg 4)" = "" ] && [ "$(wrapper_arg 3)" = "--non-interactive" ] \
	&& ! grep -qF -- "--allow-existing-cycle-anchor" "${STUB}/calls" \
	&& ! grep -qF "testnet only" "$OUT_FILE"; then
	t_pass "S2-flag-absent: no flag in the wrapper call, no override line in the output"
else
	t_fail "S2-flag-absent: no flag in the wrapper call, no override line in the output" "calls=$(tr '\t' ' ' < "${STUB}/calls")"
fi
run_reh 0 "${SAMPLE_TX}
" plain --allow-existing-cycle-anchor
if [ "$GOT_RC" = "0" ] && reached_wrapper && [ "$(wrapper_arg 1 | cut -c1-5)" = "--tx=" ] \
	&& [ "$(wrapper_arg 2)" = "--chain=testnet-a" ] && [ "$(wrapper_arg 3)" = "--non-interactive" ] \
	&& [ "$(wrapper_arg 4)" = "--allow-existing-cycle-anchor" ] && [ "$(wrapper_arg 5)" = "" ] \
	&& [ "$(grep -o -- '--allow-existing-cycle-anchor' "${STUB}/calls" | grep -c '')" = "1" ] \
	&& grep -qF -- "--allow-existing-cycle-anchor passed to the wrapper (testnet only" "$OUT_FILE"; then
	t_pass "S2-flag-given: the wrapper gets the flag once, as the last argument; the output says so"
else
	t_fail "S2-flag-given: the wrapper gets the flag once, as the last argument; the output says so" \
		"rc=$GOT_RC calls=$(tr '\t' ' ' < "${STUB}/calls")"
fi
run_reh 0 "${SAMPLE_TX}
" plain --allow-existing-cycle-anchor --allow-existing-cycle-anchor
if [ "$GOT_RC" = "0" ] && reached_wrapper \
	&& [ "$(grep -o -- '--allow-existing-cycle-anchor' "${STUB}/calls" | grep -c '')" = "1" ]; then
	t_pass "S2-flag-twice: written twice, the wrapper still gets it once"
else
	t_fail "S2-flag-twice: written twice, the wrapper still gets it once" "rc=$GOT_RC calls=$(tr '\t' ' ' < "${STUB}/calls")"
fi
run_reh 0 "${SAMPLE_TX}
" plain --allow-existing-cycle-anchor=x
if [ "$GOT_RC" = "1" ] && [ "$(wrapper_calls)" = "0" ] && [ "$(receipt_calls)" = "0" ] \
	&& grep -qF "unknown arg: --allow-existing-cycle-anchor=x" "$ERR_FILE"; then
	t_pass "S2-flag-with-value: --allow-existing-cycle-anchor=x is an unknown argument (exit 1), the wrapper is not called"
else
	t_fail "S2-flag-with-value: --allow-existing-cycle-anchor=x is an unknown argument (exit 1), the wrapper is not called" "rc=$GOT_RC wrapper=$(wrapper_calls)"
fi

# ---- S2-pass: the wrapper's expiration line and WARNING lines reach the operator --
run_reh 0 "${SAMPLE_TX}
" pass
if [ "$GOT_RC" = "0" ] && grep -qF "$EXPIRATION_LINE" "$ERR_FILE" \
	&& grep -qF "$WARNING_LINE_1" "$ERR_FILE" && grep -qF "$WARNING_LINE_2" "$ERR_FILE"; then
	t_pass "S2-pass-rc0: the expiration line and both WARNING lines are in the rehearsal's own output"
else
	t_fail "S2-pass-rc0: the expiration line and both WARNING lines are in the rehearsal's own output" "rc=$GOT_RC"
fi
run_reh 9 "" pass
if [ "$GOT_RC" = "9" ] && grep -qF "$EXPIRATION_LINE" "$ERR_FILE"; then
	t_pass "S2-pass-rc9: the expiration line is printed even when the outcome is unknown"
else
	t_fail "S2-pass-rc9: the expiration line is printed even when the outcome is unknown" "rc=$GOT_RC"
fi
run_reh 0 "${SAMPLE_TX}
" plain
if [ "$GOT_RC" = "0" ] && ! grep -qF "expiration=" "$ERR_FILE" && ! grep -qF "WARNING (check A)" "$ERR_FILE"; then
	t_pass "S2-pass-none: a wrapper that printed no expiration or WARNING line adds none"
else
	t_fail "S2-pass-none: a wrapper that printed no expiration or WARNING line adds none" "rc=$GOT_RC"
fi

# ---- R6: the token goes where the wrapper reads it -------------------------------
run_reh 0 "${SAMPLE_TX}
" plain
if [ "$GOT_RC" = "0" ] && [ -s "$TOKEN_PATH" ] && [ "$(jq -r '.chain' "$TOKEN_PATH" 2>/dev/null)" = "testnet-a" ]; then
	t_pass "R6-token: the token is written to FYD_BROADCAST_TOKEN_FILE, bound to chain testnet-a"
else
	t_fail "R6-token: the token is written to FYD_BROADCAST_TOKEN_FILE, bound to chain testnet-a" "rc=$GOT_RC"
fi

# ---- S1-realpaths: the real operator paths are untouched -------------------------
REAL_AFTER=""
for p in $REAL_PATHS; do REAL_AFTER="${REAL_AFTER}$(real_hash "$p") "; done
if [ "$REAL_BEFORE" = "$REAL_AFTER" ]; then
	t_pass "S1-realpaths: the real sign-output files and the real token are unchanged"
else
	t_fail "S1-realpaths: the real sign-output files and the real token are unchanged" "before=[$REAL_BEFORE] after=[$REAL_AFTER]"
fi

echo
t_summary rehearsal-wrapper-exits || :
if [ "$FAIL" -gt 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
