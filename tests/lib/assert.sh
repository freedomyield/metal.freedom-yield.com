#!/usr/bin/env bash
# assert.sh — shared test assertions. Sourced; never exits the caller.
#   t_pass NAME              stdout "PASS  NAME", PASS+=1
#   t_fail NAME [WHY]        stderr "FAIL  NAME" or "FAIL  NAME  (WHY)", FAIL+=1
#   t_assert_eq NAME WANT GOT
#   t_summary SUITE          stdout "test-SUITE summary: PASS=<n> FAIL=<m>"; rc 0 iff FAIL=0
PASS=${PASS:-0}
FAIL=${FAIL:-0}

t_pass() {
	PASS=$((PASS + 1))
	printf 'PASS  %s\n' "$1"
}

t_fail() {
	FAIL=$((FAIL + 1))
	if [ "$#" -ge 2 ]; then
		printf 'FAIL  %s  (%s)\n' "$1" "$2" >&2
	else
		printf 'FAIL  %s\n' "$1" >&2
	fi
	return 0
}

t_assert_eq() {
	if [ "$2" = "$3" ]; then
		t_pass "$1"
	else
		t_fail "$1" "want=$2 got=$3"
	fi
}

t_summary() {
	printf 'test-%s summary: PASS=%d FAIL=%d\n' "$1" "$PASS" "$FAIL"
	[ "$FAIL" -eq 0 ]
}
