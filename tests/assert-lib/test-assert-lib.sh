#!/usr/bin/env bash
# test-assert-lib.sh — suite for tests/lib/assert.sh.
# FY_ASSERT_LIB_UNDER_TEST overrides the library path (used to run mutations).
set -u
_T_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${FY_ASSERT_LIB_UNDER_TEST:-${_T_REPO}/tests/lib/assert.sh}"
SCR="$(mktemp -d "${TMPDIR:-/tmp}/assert-lib.XXXXXX")"
trap 'rm -rf "$SCR"' EXIT
P=0 F=0
ok()  { P=$((P + 1)); printf 'PASS  %s\n' "$1"; }
bad() { F=$((F + 1)); printf 'FAIL  %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1  (want=[$2] got=[$3])"; fi; }

# run_snip <snippet>: sources the lib in a fresh bash, runs the snippet.
# Sets OUT, ERR, RC.
run_snip() {
	printf '%s\n' ". \"$LIB\"" "$1" >"$SCR/snip.sh"
	bash "$SCR/snip.sh" >"$SCR/out" 2>"$SCR/err" </dev/null
	RC=$?
	OUT="$(cat "$SCR/out"; printf x)"; OUT="${OUT%x}"
	ERR="$(cat "$SCR/err"; printf x)"; ERR="${ERR%x}"
}
NL='
'

# t_pass
run_snip 't_pass alpha'
eq "t_pass: stdout is 'PASS  NAME' (two spaces)" "PASS  alpha${NL}" "$OUT"
eq "t_pass: nothing on stderr" "" "$ERR"
eq "t_pass: returns 0" "0" "$RC"
run_snip 't_pass a; t_pass b; echo "P=$PASS F=$FAIL"'
eq "t_pass: counter increments" "PASS  a${NL}PASS  b${NL}P=2 F=0${NL}" "$OUT"

# t_fail
run_snip 't_fail beta'
eq "t_fail: stderr is 'FAIL  NAME'" "FAIL  beta${NL}" "$ERR"
eq "t_fail: nothing on stdout" "" "$OUT"
run_snip 't_fail beta "because"'
eq "t_fail: WHY appended as '  (WHY)'" "FAIL  beta  (because)${NL}" "$ERR"
run_snip 't_fail a; t_fail b w; echo "P=$PASS F=$FAIL"'
eq "t_fail: counter increments" "P=0 F=2${NL}" "$OUT"

# t_assert_eq
run_snip 't_assert_eq same x x'
eq "t_assert_eq equal: PASS line" "PASS  same${NL}" "$OUT"
eq "t_assert_eq equal: stderr empty" "" "$ERR"
run_snip 't_assert_eq diff x y'
eq "t_assert_eq unequal: FAIL line with want/got" "FAIL  diff  (want=x got=y)${NL}" "$ERR"
eq "t_assert_eq unequal: stdout empty" "" "$OUT"
run_snip 't_assert_eq empty "" ""'
eq "t_assert_eq both empty: PASS" "PASS  empty${NL}" "$OUT"
run_snip 't_assert_eq e1 "" "x"'
eq "t_assert_eq want empty got x: FAIL" "FAIL  e1  (want= got=x)${NL}" "$ERR"
run_snip 't_assert_eq e2 "x" ""'
eq "t_assert_eq want x got empty: FAIL" "FAIL  e2  (want=x got=)${NL}" "$ERR"
run_snip 't_assert_eq sp "a b" "a b"'
eq "t_assert_eq equal with spaces: PASS" "PASS  sp${NL}" "$OUT"
run_snip 't_assert_eq sp2 "a b" "a  b"'
eq "t_assert_eq differing only in spaces: FAIL" "FAIL  sp2  (want=a b got=a  b)${NL}" "$ERR"
run_snip 't_assert_eq "has space name" 1 1'
eq "t_assert_eq name may contain spaces" "PASS  has space name${NL}" "$OUT"
run_snip 't_assert_eq c1 x x; t_assert_eq c2 x y; echo "P=$PASS F=$FAIL"'
eq "t_assert_eq: counters follow outcome" "PASS  c1${NL}P=1 F=1${NL}" "$OUT"

# t_summary
run_snip 't_pass a; t_pass b; t_summary mysuite; echo "rc=$?"'
eq "t_summary: line format, rc 0 when FAIL=0" "PASS  a${NL}PASS  b${NL}test-mysuite summary: PASS=2 FAIL=0${NL}rc=0${NL}" "$OUT"
run_snip 't_pass a; t_fail b; t_summary mysuite; echo "rc=$?"'
eq "t_summary: summary on stdout with FAIL=1" "PASS  a${NL}test-mysuite summary: PASS=1 FAIL=1${NL}rc=1${NL}" "$OUT"
run_snip 't_summary empty; echo "rc=$?"'
eq "t_summary: zero cases is PASS=0 FAIL=0, rc 0" "test-empty summary: PASS=0 FAIL=0${NL}rc=0${NL}" "$OUT"
run_snip 't_fail a; t_summary s >/dev/null; echo "rc=$?"' 
eq "t_summary: nonzero rc with FAIL>0" "rc=1${NL}" "$OUT"
run_snip 't_summary s'
if printf '%s' "$OUT" | grep -Eq '^test-.*summary:'; then ok "t_summary: line matches runner pattern ^test-.*summary:"; else bad "t_summary: line matches runner pattern"; fi

# sourcing
run_snip 'echo "P=$PASS F=$FAIL"'
eq "source: counters default to 0 and nothing else prints" "P=0 F=0${NL}" "$OUT"
run_snip 'set -u; unset PASS FAIL; . "'"$LIB"'"; t_pass a; echo "P=$PASS F=$FAIL"'
eq "source under set -u with PASS/FAIL unset" "PASS  a${NL}P=1 F=0${NL}" "$OUT"
eq "source under set -u: no stderr" "" "$ERR"
printf '%s\n' 'PASS=5; FAIL=2; . "'"$LIB"'"; echo "P=$PASS F=$FAIL"' >"$SCR/pre.sh"
OUT="$(bash "$SCR/pre.sh" 2>&1 </dev/null)"
eq "source keeps counters set before sourcing" "P=5 F=2" "$OUT"
run_snip 't_fail a; t_summary s >/dev/null; echo "still-alive"'
eq "never exits the caller" "still-alive${NL}" "$OUT"

# G3 suite-mode line pattern (Task 2 Decisions)
CASE_RE='^[[:space:]]*(PASS|FAIL|✓|✗)[[:space:]]+(.+)$'
run_snip 't_pass "case one"'
if printf '%s' "$OUT" | grep -Eq "$CASE_RE"; then ok "t_pass line matches G3 case-line pattern"; else bad "t_pass line matches G3 case-line pattern"; fi
run_snip 't_fail "case two" why'
if printf '%s' "$ERR" | grep -Eq "$CASE_RE"; then ok "t_fail line matches G3 case-line pattern"; else bad "t_fail line matches G3 case-line pattern"; fi
run_snip 't_pass "case one"'
name="$(printf '%s' "$OUT" | sed -E 's/^[[:space:]]*(PASS|FAIL|✓|✗)[[:space:]]+(.+)$/\2/' | sed -E 's/[[:space:]]+$//')"
eq "G3 would read the name back unchanged" "case one" "$name"

printf 'test-assert-lib summary: PASS=%d FAIL=%d\n' "$P" "$F"
[ "$F" -eq 0 ]
