#!/usr/bin/env bash
# tests/run-all-tests.sh — orchestrator for all repo test suites.
#
# CHAIN: none — all sub-suites are non-broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Discovers and runs every executable test-*.sh under tests/, reports
# per-suite PASS/FAIL, exits 0 iff every suite exits 0.
#
# Usage:
#   bash tests/run-all-tests.sh [--pattern=<glob>]
#
# Options:
#   --pattern=<glob>   Only run test files matching the glob.
#                      Default: 'test-*.sh'
#   --verbose          Show sub-suite stdout inline (default: summary only).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_ROOT="${REPO_ROOT}/tests"
PATTERN="test-*.sh"
VERBOSE=0

for arg in "$@"; do
	case "$arg" in
		--pattern=*)  PATTERN="${arg#*=}" ;;
		--verbose)    VERBOSE=1 ;;
		-h|--help)    sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)            echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

SUITES_TOTAL=0
SUITES_PASS=0
SUITES_FAIL=0
FAILED_SUITES=()

echo "== running test suites under ${TESTS_ROOT} =="
echo

# Iterate depth-first, deterministic order.
while IFS= read -r -d '' test_file; do
	SUITES_TOTAL=$((SUITES_TOTAL + 1))
	rel_path="${test_file#${REPO_ROOT}/}"
	printf '=== %-55s === ' "$rel_path"
	if [ "$VERBOSE" = "1" ]; then
		echo
		bash "$test_file"
		rc=$?
	else
		out="$(bash "$test_file" 2>&1)"
		rc=$?
	fi
	if [ "$rc" -eq 0 ]; then
		if [ "$VERBOSE" = "0" ]; then
			# extract just the summary line
			echo "PASS ($(echo "$out" | grep -E '^test-.*summary:' | head -1))"
		else
			echo "=== $rel_path: PASS ==="
		fi
		SUITES_PASS=$((SUITES_PASS + 1))
	else
		echo "FAIL (rc=$rc)"
		if [ "$VERBOSE" = "0" ]; then
			echo "--- $rel_path stderr / stdout ---"
			echo "$out" | tail -30
			echo "--- end ---"
		fi
		SUITES_FAIL=$((SUITES_FAIL + 1))
		FAILED_SUITES+=("$rel_path")
	fi
done < <(find "$TESTS_ROOT" -name "$PATTERN" -type f -perm -u+x -print0 | sort -z)

echo
echo "=========================================="
echo "OVERALL: total=$SUITES_TOTAL  pass=$SUITES_PASS  fail=$SUITES_FAIL"
if [ "$SUITES_FAIL" -gt 0 ]; then
	echo "FAILED SUITES:"
	for f in "${FAILED_SUITES[@]}"; do
		echo "  - $f"
	done
	exit 1
fi
echo "RESULT: ALL PASS"
exit 0
