#!/usr/bin/env bash
# tests/operator-paths/test-operator-paths.sh — scripts/lib/operator-paths.sh is
# the one place that names this project's operator-local places, and the
# scripts read it from there.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe, no broadcast pathway.
# Never runs proton. Every HOME is a temp dir, and every run of the pre-flight
# has ALL its path overrides (FYP_KEYSTORE_TESTNET, FYP_KEYSTORE_MAINNET,
# FYP_PQ_KEY_DIR, FYP_MAINNET_CFG, FYP_REHEARSAL_CFG, FYP_IDENTITY_KEY, ...)
# pointed at temp dirs, with the traps of tests/lib/real-home-fence.sh first on
# PATH (a trap call fails the case). No case reaches the real login home's
# keystore dirs: the pre-flight's defaults are checked as source text (P2).
# (Until 2026-11-26, P2 and P8 ran the pre-flight without FYP_KEYSTORE_*; a
# mutant without the HOME check then read the real keystores' proton-cli.json.)
#
# Cases:
#   P1  every name in the definition has its value, spelled out here (a change
#       of the definition fails this on purpose)
#   P2  the pre-flight's default places are <login home>/<definition name>
#       (source text: the default lines use ${LOGIN_HOME}/${FYD_..._REL};
#       the values themselves are P1's)
#   P3  the quoted heredoc of scripts/cycle-transition.sh (fyct__phase_rows)
#       names the testnet keystore at stop 3 and the mainnet one at stop 4
#   P4  unit 7a's lines use the testnet name; units 7b and 7c the mainnet one
#   P5  identity-pq.sh's default key dir is ${HOME}/<definition>
#   P6  cycle-transition.sh's default config dir is ${HOME}/<definition>
#   P7  the pre-flight refuses a HOME that is the MAINNET keystore (exit 8)
#   P8  the pre-flight refuses a HOME named like the former testnet keystore
#       (no fallback to the former place); its re-invoke hint names the
#       definition's testnet keystore
#   P9  no former place name is left in bin/ or scripts/ code lines
#   P10 identity-pq.sh stops when the definition cannot be read (fail-closed,
#       no FY_PQ_KEY_DIR): the three path functions print nothing and return 1,
#       and pq-identity-lock.sh (the one that deletes) stops with a non-zero
#       status before touching anything. The tree holds a copy of the
#       library WITHOUT operator-paths.sh (T3a) or WITH an empty one (T3b);
#       HOME is a temp dir, the real key places are never named.
#   P11 no file under tests/ (1) spells the real operator-local dir, (2) joins
#       the login home to a definition name or to .config/metal.freedom-yield.com
#       on one line, or (3) sets HOME to the login home outside
#       tests/lib/real-home-fence.sh
#
# Usage: bash tests/operator-paths/test-operator-paths.sh
# Exit:  0 all pass / 1 any fail
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATHS_LIB="${REPO_ROOT}/scripts/lib/operator-paths.sh"
PREFLIGHT="${OPERATOR_PATHS_PREFLIGHT_UNDER_TEST:-${REPO_ROOT}/scripts/install-rehearsal-preflight.sh}"
ORCH="${OPERATOR_PATHS_ORCH_UNDER_TEST:-${REPO_ROOT}/scripts/cycle-transition.sh}"
IPQ_LIB="${OPERATOR_PATHS_IPQ_UNDER_TEST:-${REPO_ROOT}/scripts/lib/identity-pq.sh}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d -t operator-paths-test.XXXXXX)"
# An empty WORK would turn every "${WORK}/x" below into "/x": stop instead.
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "FATAL: could not create the temp work dir" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=scripts/lib/operator-paths.sh
. "${OPERATOR_PATHS_LIB_UNDER_TEST:-$PATHS_LIB}"

# ---- P1 the values, spelled out --------------------------------------------
check_value() { # <name> <expected value>
	local got
	got="$(eval "printf '%s' \"\${$1-<unset>}\"")"
	if [ "$got" = "$2" ]; then ok "P1 $1 = $2"; else bad "P1 $1 is [$got], expected [$2]"; fi
}
check_value FYD_PROJECT_CONFIG_REL          ".config/metal.freedom-yield.com"
check_value FYD_KEY_DIR_REL                 ".config/metal.freedom-yield.com/key"
check_value FYD_KEYSTORE_MAINNET_REL        ".config/metal.freedom-yield.com/key/mainnet"
check_value FYD_KEYSTORE_TESTNET_REL        ".config/metal.freedom-yield.com/key/testnet"
check_value FYD_IDENTITY_KEY_DIR_REL        ".config/metal.freedom-yield.com/key/identity"
check_value FYD_BROADCAST_DIR_REL           ".config/metal.freedom-yield.com/key/broadcast"
check_value FYD_BROADCAST_CONFIG_REL        ".config/metal.freedom-yield.com/key/broadcast/config"
check_value FYD_NOTIFY_RELAY_DIR_REL        ".config/metal.freedom-yield.com/key/notify-relay"
check_value FYD_OWNER_PUBCHECK_REL          ".config/metal.freedom-yield.com/key/owner-pubcheck"
check_value FYD_REHEARSAL_CONFIG_REL        ".config/metal.freedom-yield.com/key/rehearsal"
check_value FYD_BACKUP_DIR_REL              ".config/metal.freedom-yield.com/backup"
check_value FYD_BROADCAST_AUDIT_LOG_BASENAME ".fyd-broadcast-audit.log"
check_value FYD_BROADCAST_AUDIT_LOG_REL     ".config/metal.freedom-yield.com/backup/.fyd-broadcast-audit.log"
check_value FYD_TESTNET_RECEIPT_REL         ".config/metal.freedom-yield.com/backup/.fya-testnet-receipt.json"
check_value FYD_TESTNET_DRYRUN_LOG_REL      ".config/metal.freedom-yield.com/backup/.fya-testnet-dryrun-log.json"
check_value FYD_RESTORE_DRILL_LOG_REL       ".config/metal.freedom-yield.com/backup/fy-restore-drill.log"
if [ "$FYD_KEYSTORE_MAINNET_REL" != "$FYD_KEYSTORE_TESTNET_REL" ]; then
	ok "P1 the mainnet and testnet keystore names differ"
else
	bad "P1 the mainnet and testnet keystore names are the same"
fi

# Read the definition the scripts use (not the one above, which a mutant run
# may have replaced) for the expectations below.
DEF_TESTNET="$(bash -c '. "$1"; printf "%s" "$FYD_KEYSTORE_TESTNET_REL"' _ "$PATHS_LIB")"
DEF_MAINNET="$(bash -c '. "$1"; printf "%s" "$FYD_KEYSTORE_MAINNET_REL"' _ "$PATHS_LIB")"
DEF_IDENTITY="$(bash -c '. "$1"; printf "%s" "$FYD_IDENTITY_KEY_DIR_REL"' _ "$PATHS_LIB")"

# The traps of the fence (one trap writer for all tests): a pre-flight run that
# calls proton, jq, curl, ... got past the check under test.
# shellcheck source=tests/lib/real-home-fence.sh
. "${REPO_ROOT}/tests/lib/real-home-fence.sh"
PF_TRAP_DIR="${WORK}/${FENCE_TRAP_DIR_NAME}"
PF_TRAP_MARK="${WORK}/${FENCE_TRAP_MARK_NAME}"
if ! fence_write_traps "$PF_TRAP_DIR" "$PF_TRAP_MARK" || ! fence_traps_first "$PF_TRAP_DIR"; then
	echo "FATAL: the traps are not first on PATH" >&2; exit 1
fi

# run_preflight <home> <out-file> [VAR=value ...] — exit code of the pre-flight,
# or FENCE_TRAP_EXIT if a trap was called. The keystores are temp dirs unless a
# VAR=value after them names others (still temp dirs: P7).
run_preflight() {
	local home="$1" out="$2" rc; shift 2
	rm -f "$PF_TRAP_MARK"
	env -u FY_PQ_KEY_DIR \
		HOME="$home" \
		PATH="${PF_TRAP_DIR}:${PATH}" \
		FYP_KEYSTORE_TESTNET="${WORK}/ks-test" \
		FYP_KEYSTORE_MAINNET="${WORK}/ks-main" \
		FYP_PQ_KEY_DIR="${WORK}/pq-key-dir" \
		FYP_MAINNET_CFG="${WORK}/mainnet-cfg" \
		FYP_REHEARSAL_CFG="${WORK}/rehearsal-cfg" \
		FYP_IDENTITY_KEY="${WORK}/identity-key" \
		FY_CONFIG_DIR="${WORK}/fy-config" \
		FYD_RELAY_TOKEN_DIR="${WORK}/relay" \
		"$@" bash "$PREFLIGHT" --expect-cycle=1 </dev/null >"$out" 2>&1
	rc=$?
	if [ -e "$PF_TRAP_MARK" ]; then rc="$FENCE_TRAP_EXIT"; fi
	return "$rc"
}

# ---- P2 the pre-flight's default places (source text) -----------------------
# The pre-flight is NOT run here: its defaults name the real login home. Each
# default line must build its place as ${LOGIN_HOME}/${FYD_<name>_REL}, and
# LOGIN_HOME must be fyd_login_home's answer. (The `\$` below are escaped:
# these are patterns of source text, not paths.)
# shellcheck disable=SC2016
P2_LINES='LOGIN_HOME="\$\(fyd_login_home\)"
REHEARSAL_CFG="\$\{FYP_REHEARSAL_CFG:-\$\{LOGIN_HOME\}/\$\{FYD_REHEARSAL_CONFIG_REL\}\}"
MAINNET_CFG="\$\{FYP_MAINNET_CFG:-\$\{LOGIN_HOME\}/\$\{FYD_BROADCAST_CONFIG_REL\}\}"
FY_PQ_KEY_DIR="\$\{FYP_PQ_KEY_DIR:-\$\{FY_PQ_KEY_DIR:-\$\{LOGIN_HOME\}/\$\{FYD_IDENTITY_KEY_DIR_REL\}\}\}"
KEYSTORE_TESTNET="\$\{FYP_KEYSTORE_TESTNET:-\$\{LOGIN_HOME\}/\$\{FYD_KEYSTORE_TESTNET_REL\}\}"
KEYSTORE_MAINNET="\$\{FYP_KEYSTORE_MAINNET:-\$\{LOGIN_HOME\}/\$\{FYD_KEYSTORE_MAINNET_REL\}\}"'
# The loop must see all six patterns: an input that could not be read (no
# heredoc, an emptied list) is a FAIL, never a silent pass.
P2_EXPECTED_PATTERNS=6
P2_SEEN=0
while IFS= read -r P2_RE; do
	P2_SEEN=$((P2_SEEN + 1))
	P2_NAME="${P2_RE%%=*}"
	P2_N="$(grep -cxE "$P2_RE" "$PREFLIGHT")"
	if [ "$P2_N" -eq 1 ]; then
		ok "P2 pre-flight source line ${P2_NAME}= has the definition-name form (1 line)"
	else
		bad "P2 pre-flight default ${P2_NAME}: $P2_N lines of the expected source text (expected 1)"
	fi
done <<P2_EOF
$P2_LINES
P2_EOF
if [ "$P2_SEEN" -eq "$P2_EXPECTED_PATTERNS" ]; then
	ok "P2 all ${P2_EXPECTED_PATTERNS} source-text patterns were checked"
else
	bad "P2 checked $P2_SEEN source-text patterns (expected ${P2_EXPECTED_PATTERNS})"
fi

# ---- P3 the quoted heredoc of fyct__phase_rows ------------------------------
PHASE_ROWS="$(sed -n "/^	cat <<'FYCT_PHASE_EOF'\$/,/^FYCT_PHASE_EOF\$/p" "$ORCH")"
STOP3_ROW="$(printf '%s\n' "$PHASE_ROWS" | awk -F'|' '$3 == "3"')"
STOP4_ROW="$(printf '%s\n' "$PHASE_ROWS" | awk -F'|' '$3 == "4"')"
case "$STOP3_ROW" in
	*"(HOME=~/${DEF_TESTNET})"*) ok "P3 phase row of stop 3 names HOME=~/${DEF_TESTNET}" ;;
	*) bad "P3 phase row of stop 3 does not name HOME=~/${DEF_TESTNET}" ;;
esac
case "$STOP3_ROW" in
	*"HOME=~/${DEF_MAINNET}"*) bad "P3 phase row of stop 3 names the mainnet keystore" ;;
	*) ok "P3 phase row of stop 3 does not name the mainnet keystore" ;;
esac
case "$STOP4_ROW" in
	*"(HOME=~/${DEF_MAINNET})"*) ok "P3 phase row of stop 4 names HOME=~/${DEF_MAINNET}" ;;
	*) bad "P3 phase row of stop 4 does not name HOME=~/${DEF_MAINNET}" ;;
esac
case "$STOP4_ROW" in
	*"HOME=~/${DEF_TESTNET}"*) bad "P3 phase row of stop 4 names the testnet keystore" ;;
	*) ok "P3 phase row of stop 4 does not name the testnet keystore" ;;
esac

# ---- P4 units 7a / 7b / 7c ------------------------------------------------------
# unit_block <label> — the source lines of one `<label>)` arm of the unit printer.
unit_block() { awk -v want="	$1)" '$0 == want {f=1; next} f && /^		;;$/ {exit} f' "$ORCH"; }
U7A="$(unit_block 7a)"; U7B="$(unit_block 7b)"; U7C="$(unit_block 7c)"
# shellcheck disable=SC2016  # the variable names are matched as source text
T_REF='HOME=~/${FYD_KEYSTORE_TESTNET_REL} '
# shellcheck disable=SC2016
M_REF='HOME=~/${FYD_KEYSTORE_MAINNET_REL} '
n7a_t="$(printf '%s\n' "$U7A" | grep -cF "$T_REF")"; n7a_m="$(printf '%s\n' "$U7A" | grep -cF "$M_REF")"
n7b_t="$(printf '%s\n' "$U7B" | grep -cF "$T_REF")"; n7b_m="$(printf '%s\n' "$U7B" | grep -cF "$M_REF")"
n7c_t="$(printf '%s\n' "$U7C" | grep -cF "$T_REF")"; n7c_m="$(printf '%s\n' "$U7C" | grep -cF "$M_REF")"
if [ "$n7a_t" -eq 2 ] && [ "$n7a_m" -eq 0 ]; then ok "P4 unit 7a: 2 testnet lines, 0 mainnet"; else bad "P4 unit 7a keystore lines: testnet=$n7a_t mainnet=$n7a_m (expected 2 / 0)"; fi
if [ "$n7b_t" -eq 0 ] && [ "$n7b_m" -eq 2 ]; then ok "P4 unit 7b: 0 testnet lines, 2 mainnet"; else bad "P4 unit 7b keystore lines: testnet=$n7b_t mainnet=$n7b_m (expected 0 / 2)"; fi
if [ "$n7c_t" -eq 0 ] && [ "$n7c_m" -eq 2 ]; then ok "P4 unit 7c: 0 testnet lines, 2 mainnet"; else bad "P4 unit 7c keystore lines: testnet=$n7c_t mainnet=$n7c_m (expected 0 / 2)"; fi

# ---- P5 identity-pq.sh's default key dir -----------------------------------
mkdir -p "${WORK}/ipq-home"
IPQ_DIR="$(env -u FY_PQ_KEY_DIR HOME="${WORK}/ipq-home" bash -c '. "$1"; fyipq__key_dir' _ "$IPQ_LIB" 2>/dev/null)"
if [ "$IPQ_DIR" = "${WORK}/ipq-home/${DEF_IDENTITY}" ]; then
	ok "P5 fyipq__key_dir default = \${HOME}/${DEF_IDENTITY}"
else
	bad "P5 fyipq__key_dir default is [${IPQ_DIR#"${WORK}/ipq-home"}] under HOME (expected /${DEF_IDENTITY})"
fi

# ---- P6 cycle-transition.sh's default config dir ---------------------------
# shellcheck disable=SC2016
if grep -qxF '	CFG="${FY_CONFIG_DIR:-${HOME}/${FYD_BROADCAST_CONFIG_REL}}"' "$ORCH"; then
	ok "P6 cycle-transition.sh default CFG = \${HOME}/\${FYD_BROADCAST_CONFIG_REL}"
else
	bad "P6 cycle-transition.sh default CFG is not \${HOME}/\${FYD_BROADCAST_CONFIG_REL}"
fi

# ---- P7 the pre-flight refuses the MAINNET keystore as HOME -----------------
mkdir -p "${WORK}/ks-mainnet" "${WORK}/ks-testnet"
run_preflight "${WORK}/ks-mainnet" "${WORK}/p7.out" \
	FYP_KEYSTORE_MAINNET="${WORK}/ks-mainnet" FYP_KEYSTORE_TESTNET="${WORK}/ks-testnet"; RC=$?
if [ "$RC" -eq 8 ] && grep -qF "That is the MAINNET keystore." "${WORK}/p7.out"; then
	ok "P7 pre-flight with HOME = mainnet keystore -> exit 8, names the MAINNET keystore"
else
	bad "P7 pre-flight with HOME = mainnet keystore -> rc=$RC (expected 8 and the MAINNET keystore line)"
fi

# ---- P8 no fallback to the former testnet keystore name ---------------------
# HOME is named like the former testnet keystore; the keystores are temp dirs
# (ks-test / ks-main), so the HOME check under test is the only thing that can
# stop the run, and nothing past it is reachable from here.
mkdir -p "${WORK}/.metal-fy-proton-test" "${WORK}/ks-test" "${WORK}/ks-main"
run_preflight "${WORK}/.metal-fy-proton-test" "${WORK}/p8.out" \
	FYP_KEYSTORE_TESTNET="${WORK}/ks-test" FYP_KEYSTORE_MAINNET="${WORK}/ks-main"; RC=$?
if [ "$RC" -eq 8 ]; then
	ok "P8 pre-flight with HOME named like the former testnet keystore -> exit 8"
else
	bad "P8 pre-flight with HOME named like the former testnet keystore -> rc=$RC (expected 8)"
fi
if grep -qF "HOME=~/${DEF_TESTNET} bash" "${WORK}/p8.out"; then
	ok "P8 pre-flight re-invoke hint names HOME=~/${DEF_TESTNET}"
else
	bad "P8 pre-flight re-invoke hint does not name HOME=~/${DEF_TESTNET}"
fi

# ---- P9 no former place name in bin/ or scripts/ code lines -----------------
FORMER_RE='\.metal-fy-proton|\.metal-fy-notify-relay|\.freedom-yield-identity|\.fy-mainnet-broadcast|\.metal-owner-pubcheck|freedom-yield-rehearsal-config'
FORMER_HITS="$(git -C "$REPO_ROOT" grep -n -E "$FORMER_RE" -- bin scripts ':!*.md' 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -z "$FORMER_HITS" ]; then
	ok "P9 no former place name in bin/ or scripts/ code lines"
else
	bad "P9 former place names remain in code lines: $(printf '%s\n' "$FORMER_HITS" | cut -d: -f1,2 | tr '\n' ' ')"
fi

# ---- P10 an unreadable definition stops the identity key paths --------------
# mk_ipq_tree <root> <none|empty>: scripts/lib/identity-pq.sh and
# scripts/operator-local/pq-identity-lock.sh copied in; operator-paths.sh is
# absent (none) or an empty file (empty).
mk_ipq_tree() {
	mkdir -p "$1/scripts/lib" "$1/scripts/operator-local"
	cp "$IPQ_LIB" "$1/scripts/lib/identity-pq.sh"
	cp "${REPO_ROOT}/scripts/operator-local/pq-identity-lock.sh" "$1/scripts/operator-local/pq-identity-lock.sh"
	if [ "$2" = "empty" ]; then : > "$1/scripts/lib/operator-paths.sh"; fi
}
mkdir -p "${WORK}/p10-home"
for KIND in none empty; do
	TREE="${WORK}/p10-${KIND}"
	mk_ipq_tree "$TREE" "$KIND"
	for FN in fyipq__key_dir fyipq__enc_path fyipq__unlocked_path; do
		# `set -u` like the strict callers: the unset name must not abort with
		# "unbound variable" — the library's own message must be the one printed.
		P10_OUT="$(env -u FY_PQ_KEY_DIR HOME="${WORK}/p10-home" bash -u -c '. "$1"; "$2"' _ "${TREE}/scripts/lib/identity-pq.sh" "$FN" 2>"${WORK}/p10.err")"; RC=$?
		if [ "$RC" -eq 1 ] && [ -z "$P10_OUT" ] && grep -qF 'FYD_IDENTITY_KEY_DIR_REL is unset or empty' "${WORK}/p10.err" && grep -qF 'scripts/lib/operator-paths.sh' "${WORK}/p10.err"; then
			ok "P10 T1/T2 ($KIND) $FN -> exit 1, stdout empty, the library's own stderr line names the definition file"
		else
			bad "P10 T1/T2 ($KIND) $FN -> rc=$RC stdout=[$P10_OUT] stderr=[$(head -c 200 "${WORK}/p10.err")] (expected 1, empty, the definition file named)"
		fi
	done
	# T3: the deleting script must stop non-zero and change nothing.
	BEFORE="$(find "$WORK" -mindepth 1 -not -name 'p10.err' -not -name 'p10-lock.*' | LC_ALL=C sort)"
	P10_LOCK_OUT="$(env -u FY_PQ_KEY_DIR HOME="${WORK}/p10-home" bash "${TREE}/scripts/operator-local/pq-identity-lock.sh" 2>&1)"; RC=$?
	AFTER="$(find "$WORK" -mindepth 1 -not -name 'p10.err' -not -name 'p10-lock.*' | LC_ALL=C sort)"
	# With an EMPTY definition file the source succeeds, so only the library's
	# own check can stop the script: its message must be in the output.
	P10_OWN="ok"
	if [ "$KIND" = "empty" ] && ! printf '%s' "$P10_LOCK_OUT" | grep -qF 'FYD_IDENTITY_KEY_DIR_REL is unset or empty'; then P10_OWN="missing"; fi
	if [ "$RC" -ne 0 ] && [ "$BEFORE" = "$AFTER" ] && [ "$P10_OWN" = "ok" ] && ! printf '%s' "$P10_LOCK_OUT" | grep -qE '^(locked|already locked):'; then
		ok "P10 T3 ($KIND) pq-identity-lock.sh without FY_PQ_KEY_DIR -> exit $RC, no 'locked' line, file list unchanged"
	else
		bad "P10 T3 ($KIND) pq-identity-lock.sh -> rc=$RC, listing changed=$([ "$BEFORE" = "$AFTER" ] && echo no || echo yes), output=[$(printf '%s' "$P10_LOCK_OUT" | head -c 200)] (expected non-zero, no 'locked' line, unchanged)"
	fi
done

# ---- P11 no test names or enters the real operator-local dir -----------------
# Counts every file under tests/ (tracked or not, text or not). The only file
# left out, and only of (3), is the fence itself. The patterns are written so
# they do not match their own lines (`hom[e]`, `[[:space:]]`, escaped `$`).
P11_TESTS_REL="tests"
P11_FENCE_REL="tests/lib/real-home-fence.sh"
# The real dir is built in two lines, so this file does not join the login
# home lookup to the project config dir on one line (that is what (2) counts).
P11_ACCOUNT_DIR="$(eval echo "~$(id -un)" 2>/dev/null)"
P11_REAL_DIR="${P11_ACCOUNT_DIR}/${FYD_PROJECT_CONFIG_REL:-}"
# p11_lines <grep args...> — every hit under tests/ as "<file>:<line>:<text>".
# A scan that could not run prints one "<scan failed ...>" line instead, which
# every part below counts as a hit (never a silent 0).
p11_lines() {
	local out rc
	out="$(cd "$REPO_ROOT" && grep -rna "$@" -- "$P11_TESTS_REL" 2>/dev/null)"; rc=$?
	case "$rc" in
		0) printf '%s\n' "$out" ;;
		1) ;;
		*) printf '<scan failed rc=%s>\n' "$rc" ;;
	esac
}
p11_loc() { cut -d: -f1,2; }
# (0) the scan itself works: it must see the fence's own function name
if [ -n "$(p11_lines -F "run_with_real_login_home" | grep -v '^<scan failed')" ]; then
	ok "P11-0 the scan of tests/ sees the fence (it reads the files)"
else
	bad "P11-0 the scan of tests/ does not see the fence — nothing below would be counted"
fi
# (1) the real dir's absolute path, spelled out
case "$P11_REAL_DIR" in
	/*/.config/*) P11_HITS1="$(p11_lines -F "$P11_REAL_DIR" | p11_loc)" ;;
	*)            P11_HITS1="<the login home or the definition cannot be resolved here>" ;;
esac
# (2) the login home (an unescaped $LOGIN_HOME / ${LOGIN_HOME...}, or its
# lookup: fyd_login_hom[e], `eval echo ~`, `id -un`) joined, on the same line,
# to a definition name or to the project config dir
P11_LH_RE='(^|[^\\])\$\{?LOGIN_HOME|fyd_login_hom[e]|eval[[:space:]]+echo[[:space:]]+"?~|id[[:space:]]+-un'
P11_DEF_RE='FYD_[A-Z_]*_REL|\.config/metal\.freedom-yield\.com|^<scan failed'
P11_HITS2="$(p11_lines -E "$P11_LH_RE" | grep -aE -- "$P11_DEF_RE" | p11_loc)"
# (3) HOME set to the login home: `HOME=` followed, anywhere later on the line,
# by a *LOGIN_HOM[E]* name or the lookup itself
P11_HOME_RE="(^|[^A-Za-z0-9_])HOME=.*(LOGIN_HOM[E]|eval[[:space:]]+echo|id[[:space:]]+-un|fyd_login_hom[e])"
P11_HITS3="$(p11_lines -E "$P11_HOME_RE" | grep -vF "${P11_FENCE_REL}:" | p11_loc)"
# p11_report <part> <hits> — ok when empty, else every <file>:<line>.
p11_report() {
	if [ -z "$2" ]; then
		ok "P11-$1 0 lines under tests/"
	else
		bad "P11-$1 $(printf '%s\n' "$2" | grep -c .) line(s): $(printf '%s\n' "$2" | tr '\n' ' ')"
	fi
}
p11_report 1 "$P11_HITS1"
p11_report 2 "$P11_HITS2"
p11_report 3 "$P11_HITS3"

echo "test-operator-paths summary: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "RESULT: FAIL"; exit 1; }
echo "RESULT: PASS"
