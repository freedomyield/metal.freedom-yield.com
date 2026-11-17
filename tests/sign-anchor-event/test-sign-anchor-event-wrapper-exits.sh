#!/usr/bin/env bash
# test-sign-anchor-event-wrapper-exits.sh — how scripts/sign-anchor-event.sh
# reads the exit code and stdout of the broadcast wrapper (double-inscription
# guard, design 2026-10-16 section 4 "sign-anchor-event.sh mapping"; lane T3).
#
# CHAIN: none. The wrapper is a STUB inside a throwaway tree (its second line is
#        the stamp "# T3-STUB-WRAPPER"); the real bin/safe-broadcast, the real
#        proton-cli and curl are never called. A stub proton on PATH records any
#        call and fails, so "nothing was signed" is a measured fact per case.
#        PRIME_DIRECTIVE: TESTNET-FIRST — nothing here can send anything.
#
# Properties (case names start with the id; the lane report maps mutations):
#   S1  the class of the wrapper result decides the exit:
#         rc 0 + exactly one 64-hex line      -> 0, the receipt JSON, output file
#         rc 0 + any other stdout             -> 9  (OUTCOME UNKNOWN)
#         rc 2..8                             -> 5  (nothing was sent / rejected)
#         rc 9, 10, and any unlisted rc       -> 9
#         rc 11                               -> 10 (already inscribed)
#         rc 12, 13                           -> 11 (not sent, absence unproven / attempt live)
#       Every non-zero outcome prints nothing on stdout, writes no output file,
#       calls the wrapper exactly once with the three expected arguments and never
#       calls proton. The override flag of the rehearsal script is NOT accepted here.
#   X2  --help prints the header up to its last line (the exit table with 9, 10, 11).
#   S1-realpaths  the real operator paths are untouched.
#
# The rc lists below are the same as tests/run-testnet-rehearsal/
# test-rehearsal-wrapper-exits.sh, which is what ties the two class tables together.
#
# Usage: bash tests/sign-anchor-event/test-sign-anchor-event-wrapper-exits.sh
# Exit codes: 0 all PASS / 1 any FAIL

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_SRC="${REPO_ROOT}/scripts/sign-anchor-event.sh"
KEYSTORE_LIB_SRC="${REPO_ROOT}/scripts/lib/require-keystore-home.sh"
WRAPPER_SRC="${REPO_ROOT}/bin/safe-broadcast"
ANCHOR_SOURCE="${REPO_ROOT}/public/api/anchor-source.example.json"
PROFILES="${REPO_ROOT}/config/a-chain-profiles.json"
STUB_STAMP="# T3-STUB-WRAPPER"

for f in "$SCRIPT_SRC" "$KEYSTORE_LIB_SRC" "$WRAPPER_SRC" "$ANCHOR_SOURCE" "$PROFILES"; do
	[ -r "$f" ] || { echo "FATAL: expected file missing: $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }

# shellcheck source=../lib/assert.sh
. "${REPO_ROOT}/tests/lib/assert.sh"

# ---- the same rc lists as the rehearsal suite ---------------------------------
RC_NOT_SENT="2 3 4 5 6 7 8"
RC_UNKNOWN="9 10"
RC_UNLISTED="1 14 126 127 130"

TREE="$(mktemp -d -t fya-t3-sae-tree.XXXXXX)"
STUB="${TREE}/stub"
TEST_HOME="$(mktemp -d -t fya-t3-sae-home.XXXXXX)"
CFG="$(mktemp -d -t fya-t3-sae-cfg.XXXXXX)"
OUTDIR="$(mktemp -d -t fya-t3-sae-out.XXXXXX)"
TOKEN_PATH="$(mktemp -u -t fya-t3-sae-token.XXXXXX)"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { rm -rf "$TREE" "$TEST_HOME" "$CFG" "$OUTDIR"; }
trap cleanup EXIT

mkdir -p "${TREE}/scripts/lib" "${TREE}/bin" "$STUB"
cp "$SCRIPT_SRC" "${TREE}/scripts/sign-anchor-event.sh"
cp "$KEYSTORE_LIB_SRC" "${TREE}/scripts/lib/require-keystore-home.sh"
chmod 755 "${TREE}/scripts/sign-anchor-event.sh"

# the stub wrapper: records its arguments (TAB separated), answers from the stub dir
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
chmod 755 "${TREE}/bin/safe-broadcast"

# the stub proton: records a call and fails (never succeeds at anything)
mkdir -p "${TREE}/pathstub"
cat > "${TREE}/pathstub/proton" <<STUBEOF
#!/usr/bin/env bash
printf 'proton %s\\n' "\$*" >> "${STUB}/proton-calls"
exit 1
STUBEOF
chmod 755 "${TREE}/pathstub/proton"

# ---- FATAL if the tree's wrapper is not the stamped stub -----------------------
TREE_WRAPPER="${TREE}/bin/safe-broadcast"
if ! sed -n '2p' "$TREE_WRAPPER" | grep -qxF -- "$STUB_STAMP" \
	|| cmp -s "$TREE_WRAPPER" "$WRAPPER_SRC"; then
	echo "FATAL: the tree's bin/safe-broadcast is not the stamped stub (or equals the real one)" >&2
	exit 1
fi

# ---- the real operator paths: snapshot now, compare at the end -----------------
if command -v sha256sum >/dev/null 2>&1; then
	real_hash() { [ -r "$1" ] && sha256sum "$1" | awk '{print $1}' || echo "ABSENT"; }
else
	real_hash() { [ -r "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "ABSENT"; }
fi
REAL_PATHS="/tmp/fya-testnet-sign-output.json /tmp/fya-mainnet-sign-output.json /tmp/fyd-broadcast-token"
REAL_BEFORE=""
for p in $REAL_PATHS; do REAL_BEFORE="${REAL_BEFORE}$(real_hash "$p") "; done

# ---- fixtures -----------------------------------------------------------------
ACTOR="fxanchor"
SINK="fxsink"
printf '%s\n' "$ACTOR" > "${CFG}/xpr-account"
printf '%s\n' "$SINK" > "${CFG}/anchor-sink"
TESTNET_CHAIN="testnet-a"
MAINNET_CHAIN="mainnet-a"
# a made-up tx id made only of hex digits (a sample, not a real transaction)
SAMPLE_TX="$(printf 'ab12cd34%.0s' 1 2 3 4 5 6 7 8)"
STUB_STDERR_LINE="stub-wrapper-stderr-line"

# run_sae <rc> <stdout-text|@absent> <chain> [extra args...]
#   sets: GOT_RC, OUT_FILE, ERR_FILE, OUTPUT_JSON (the default --output path)
run_sae() {
	local rc="$1" text="$2" chain="$3"
	shift 3
	rm -f "${STUB}/calls" "${STUB}/proton-calls" "${STUB}/rc" "${STUB}/stdout" "${STUB}/stderr"
	rm -f "${OUTDIR}"/*.json
	printf '%s' "$rc" > "${STUB}/rc"
	[ "$text" = "@absent" ] || printf '%s' "$text" > "${STUB}/stdout"
	printf '%s\n' "$STUB_STDERR_LINE" > "${STUB}/stderr"
	OUT_FILE="${TREE}/last.out"
	ERR_FILE="${TREE}/last.err"
	OUTPUT_JSON="${OUTDIR}/fya-${chain%-a}-sign-output.json"
	PATH="${TREE}/pathstub:${PATH}" HOME="$TEST_HOME" FY_CONFIG_DIR="$CFG" \
		FY_SIGN_OUTPUT_DIR="$OUTDIR" FYD_BROADCAST_TOKEN_FILE="$TOKEN_PATH" \
		bash "${TREE}/scripts/sign-anchor-event.sh" --chain="$chain" \
		--anchor-source="$ANCHOR_SOURCE" --non-interactive "$@" \
		> "$OUT_FILE" 2> "$ERR_FILE" </dev/null
	GOT_RC=$?
}

call_count() { [ -s "${STUB}/calls" ] && grep -c '' "${STUB}/calls" || echo 0; }
proton_count() { [ -s "${STUB}/proton-calls" ] && grep -c '' "${STUB}/proton-calls" || echo 0; }

# the wrapper was called once with exactly --tx=…, --chain=<chain>, --non-interactive
args_ok() {
	local chain="$1" a1 a2 a3 a4
	[ "$(call_count)" = "1" ] || return 1
	IFS=$'\t' read -r a1 a2 a3 a4 < "${STUB}/calls"
	case "$a1" in --tx=?*) ;; *) return 1 ;; esac
	[ "$a2" = "--chain=${chain}" ] && [ "$a3" = "--non-interactive" ] && [ -z "$a4" ]
}

# why_not <expected-exit> <chain> <word>… — empty when every fact holds, else the first miss
why_not() {
	local want="$1" chain="$2" w
	shift 2
	[ "$GOT_RC" = "$want" ] || { printf 'rc=%s want %s' "$GOT_RC" "$want"; return; }
	[ ! -s "$OUT_FILE" ] || { printf 'stdout is not empty'; return; }
	[ ! -e "$OUTPUT_JSON" ] || { printf 'the output file exists'; return; }
	args_ok "$chain" || { printf 'wrapper calls=%s or its arguments differ' "$(call_count)"; return; }
	[ "$(proton_count)" = "0" ] || { printf 'proton was called'; return; }
	for w in "$@"; do
		grep -qF -- "$w" "$ERR_FILE" || { printf 'stderr lacks: %s' "$w"; return; }
	done
}

case_nonzero() { # <name> <want-exit> <chain> <rc> <stdout> <word>…
	local name="$1" want="$2" chain="$3" rc="$4" text="$5" why
	shift 5
	run_sae "$rc" "$text" "$chain"
	why="$(why_not "$want" "$chain" "$@")"
	if [ -z "$why" ]; then t_pass "$name"; else t_fail "$name" "$why"; fi
}

rc_words() { # the per-rc words of the not-sent message
	case "$1" in
		2) printf 'bad argument or transaction shape' ;;
		3) printf 'PRIME DIRECTIVE gate' ;;
		4) printf 'chain, profile or library check' ;;
		5) printf 'aborted at the confirmation prompt' ;;
		6) printf 'REJECTED' ;;
		7) printf 'audit log could not be written' ;;
		8) printf 'keystore guard' ;;
	esac
}

# ---- positive control: the stubs record what they are called with --------------
run_sae 0 "$SAMPLE_TX" "$TESTNET_CHAIN"
if [ "$(call_count)" = "1" ] && args_ok "$TESTNET_CHAIN"; then
	t_pass "S1-control: the stub wrapper records its one call with the three arguments"
else
	t_fail "S1-control: the stub wrapper records its one call with the three arguments" "calls=$(call_count)"
fi
PATH="${TREE}/pathstub:${PATH}" proton control-probe >/dev/null 2>&1
if [ "$(proton_count)" = "1" ]; then
	t_pass "S1-control: the stub proton records a call, so a 0 count means it was never called"
else
	t_fail "S1-control: the stub proton records a call, so a 0 count means it was never called" "count=$(proton_count)"
fi

# ---- S1: rc 0 with one valid 64-hex line ----------------------------------------
for chain in "$TESTNET_CHAIN" "$MAINNET_CHAIN"; do
	run_sae 0 "${SAMPLE_TX}
" "$chain"
	if [ "$GOT_RC" = "0" ] && [ "$(jq -r '.tx_id' "$OUT_FILE" 2>/dev/null)" = "$SAMPLE_TX" ] \
		&& [ "$(jq -r '.network' "$OUT_FILE" 2>/dev/null)" = "$chain" ] \
		&& [ -s "$OUTPUT_JSON" ] && [ "$(jq -r '.tx_id' "$OUTPUT_JSON" 2>/dev/null)" = "$SAMPLE_TX" ] \
		&& args_ok "$chain" && [ "$(proton_count)" = "0" ]; then
		t_pass "S1-rc0-valid-tx-id (${chain}) -> 0, the receipt JSON on stdout and in the output file"
	else
		t_fail "S1-rc0-valid-tx-id (${chain}) -> 0, the receipt JSON on stdout and in the output file" "rc=$GOT_RC"
	fi
done

# ---- S1: rc 0 with a stdout that is not exactly one 64-hex id -> 9 ---------------
HEX63="${SAMPLE_TX%?}"
HEX65="${SAMPLE_TX}a"
UPPER="A${SAMPLE_TX#?}"
FULLWIDTH="１${SAMPLE_TX#?}"
W9="ERROR (9): OUTCOME UNKNOWN — the broadcast MAY have landed"
case_nonzero "S1-rc0-empty-stdout -> 9" 9 "$TESTNET_CHAIN" 0 "" "$W9" "wrapper exit 0" "stdout is not one 64-hex tx id"
case_nonzero "S1-rc0-63-hex -> 9" 9 "$TESTNET_CHAIN" 0 "$HEX63" "$W9" "stdout is not one 64-hex tx id"
case_nonzero "S1-rc0-65-hex -> 9" 9 "$TESTNET_CHAIN" 0 "$HEX65" "$W9" "stdout is not one 64-hex tx id"
case_nonzero "S1-rc0-uppercase-hex -> 9" 9 "$TESTNET_CHAIN" 0 "$UPPER" "$W9" "stdout is not one 64-hex tx id"
case_nonzero "S1-rc0-fullwidth-digit-in-64-chars -> 9" 9 "$TESTNET_CHAIN" 0 "$FULLWIDTH" "$W9" "stdout is not one 64-hex tx id"
case_nonzero "S1-rc0-another-line-before-the-id -> 9" 9 "$TESTNET_CHAIN" 0 "a-line-before
${SAMPLE_TX}" "$W9"
case_nonzero "S1-rc0-another-line-after-the-id -> 9" 9 "$TESTNET_CHAIN" 0 "${SAMPLE_TX}
a-line-after" "$W9"
case_nonzero "S1-rc0-id-then-trailing-text-on-the-line -> 9" 9 "$TESTNET_CHAIN" 0 "${SAMPLE_TX} trailing" "$W9"
case_nonzero "S1-rc0-no-stdout-at-all -> 9" 9 "$TESTNET_CHAIN" 0 "@absent" "$W9"

# ---- S1: rc 2..8 -> 5 ------------------------------------------------------------
for rc in $RC_NOT_SENT; do
	if [ "$rc" = "6" ]; then
		head_words="ERROR (5): REJECTED by the chain — nothing will land"
	else
		head_words="ERROR (5): nothing was sent"
	fi
	case_nonzero "S1-wrapper-rc${rc} -> 5, ${head_words%% —*}" 5 "$TESTNET_CHAIN" "$rc" "" \
		"$head_words" "wrapper exit ${rc}" "$(rc_words "$rc")" \
		"a retry needs a NEW per-invocation authorization and a new token"
done

# ---- S1: rc 9, 10 and the unlisted rcs -> 9 --------------------------------------
for rc in $RC_UNKNOWN $RC_UNLISTED; do
	case_nonzero "S1-wrapper-rc${rc} -> 9 OUTCOME UNKNOWN" 9 "$TESTNET_CHAIN" "$rc" "" \
		"$W9" "wrapper exit ${rc}" "do NOT re-authorize or re-run" \
		"last irreversible block time is past the expiration"
done
# an id on stdout does not turn a non-zero rc into a success
case_nonzero "S1-wrapper-rc10-with-a-valid-id-on-stdout -> 9" 9 "$TESTNET_CHAIN" 10 "$SAMPLE_TX" "$W9"
case_nonzero "S1-wrapper-rc6-with-a-valid-id-on-stdout -> 5" 5 "$TESTNET_CHAIN" 6 "$SAMPLE_TX" "ERROR (5): REJECTED"

# ---- S1: rc 11 -> 10, rc 12 -> 11, rc 13 -> 11 ----------------------------------
case_nonzero "S1-wrapper-rc11 -> 10 ALREADY INSCRIBED (testnet-a)" 10 "$TESTNET_CHAIN" 11 "" \
	"ERROR (10): ALREADY INSCRIBED" "wrapper exit 11" "nothing was signed" "step 8"
case_nonzero "S1-wrapper-rc11 -> 10 ALREADY INSCRIBED (mainnet-a)" 10 "$MAINNET_CHAIN" 11 "" \
	"ERROR (10): ALREADY INSCRIBED" "wrapper exit 11" "nothing was signed" "step 8"
case_nonzero "S1-wrapper-rc12 -> 11 absence cannot be proven" 11 "$TESTNET_CHAIN" 12 "" \
	"ERROR (11): NOT SENT — cannot prove the cycle is absent" "wrapper exit 12" "wait and re-run"
case_nonzero "S1-wrapper-rc13 -> 11 an earlier attempt may still land" 11 "$TESTNET_CHAIN" 13 "" \
	"ERROR (11): NOT SENT — an earlier attempt for this memo prefix may still land" "wrapper exit 13" \
	"wait until its expiration is irreversibly past"

# ---- S1: the rehearsal-only flag is not accepted here ----------------------------
run_sae 0 "$SAMPLE_TX" "$TESTNET_CHAIN" --allow-existing-cycle-anchor
if [ "$GOT_RC" = "1" ] && [ "$(call_count)" = "0" ] && [ "$(proton_count)" = "0" ] && [ ! -s "$OUT_FILE" ] \
	&& grep -qF "unknown arg: --allow-existing-cycle-anchor" "$ERR_FILE"; then
	t_pass "S1-flag: --allow-existing-cycle-anchor is an unknown argument (exit 1), the wrapper is not called"
else
	t_fail "S1-flag: --allow-existing-cycle-anchor is an unknown argument (exit 1), the wrapper is not called" "rc=$GOT_RC calls=$(call_count)"
fi

# ---- S1: no wrapper call carries the flag in any case above ----------------------
# (args_ok pins the exact three arguments in every case; this case shows the flag
# check can fail: a call line that does carry it is not accepted)
printf '%s\t%s\t%s\t%s\n' "--tx=x" "--chain=${TESTNET_CHAIN}" "--non-interactive" "--allow-existing-cycle-anchor" > "${STUB}/calls"
if args_ok "$TESTNET_CHAIN"; then
	t_fail "S1-flag-control: a wrapper call with the extra flag is refused by the argument check"
else
	t_pass "S1-flag-control: a wrapper call with the extra flag is refused by the argument check"
fi

# ---- X2: --help prints the header through its last line --------------------------
# the comment marker may or may not be stripped (BSD sed ignores the \? of the script's own
# filter), so the check normalizes both forms itself
HELP="$(bash "${TREE}/scripts/sign-anchor-event.sh" --help 2>&1 | sed 's/^#* *//')"
if printf '%s\n' "$HELP" | grep -qE '^11  NOT SENT' \
	&& printf '%s\n' "$HELP" | grep -qE '^10  ALREADY INSCRIBED' \
	&& printf '%s\n' "$HELP" | grep -qE '^9  OUTCOME UNKNOWN' \
	&& [ "$(printf '%s\n' "$HELP" | tail -n 1)" = "}" ] \
	&& ! printf '%s\n' "$HELP" | grep -qF 'set -euo pipefail'; then
	t_pass "X2-help: --help shows the exit 9, 10 and 11 rows and ends at the last header line, before the code"
else
	t_fail "X2-help: --help shows the exit 9, 10 and 11 rows and ends at the last header line, before the code" "last=[$(printf '%s\n' "$HELP" | tail -n 1)]"
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
t_summary sign-anchor-event-wrapper-exits || :
if [ "$FAIL" -gt 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
