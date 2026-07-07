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

# Anchor cwd at the repo root. When run-all-tests is invoked from an ssh
# session where the login shell's cwd is a directory the running user cannot
# read (e.g. `sudo -u deploy` from a shell whose cwd is /root), some sub-suite
# tools — notably GNU find with -exec — refuse to run and return non-zero
# because they cannot "restore initial working directory". This is
# environmental, not a real regression, and the anchor-state sub-suite's T11
# check (init --clear-quarantine → find -exec rm) hits it. Anchoring cwd at
# the repo root here removes that failure mode for every downstream test.
cd "$REPO_ROOT" || exit 2

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

# Extra suites that carry their own runner and do NOT match the test-*.sh glob
# (so the find below never discovers them). The cycle-gate suite lives at
# tests/cycle-gate/run-tests.sh and bundles 20 scenario tests — historically it
# was silently excluded from the aggregate. Listed explicitly so the default
# full run always covers it. Only appended when running the default pattern; a
# caller-supplied --pattern is honoured verbatim.
EXTRA_SUITES=(
	"${TESTS_ROOT}/cycle-gate/run-tests.sh"
)

run_suite() {
	# $1 = absolute path to an executable suite runner.
	local test_file="$1" rel_path rc out
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
			# extract just the summary line (per-suite formats vary:
			# `test-*.sh summary: ...` or cycle-gate's `RESULTS: N PASS / M FAIL`)
			echo "PASS ($(echo "$out" | grep -E '^(test-.*summary:|RESULTS:)' | head -1))"
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
}

echo "== running test suites under ${TESTS_ROOT} =="
echo

# Iterate glob-discovered suites depth-first, deterministic order.
while IFS= read -r -d '' test_file; do
	run_suite "$test_file"
done < <(find "$TESTS_ROOT" -name "$PATTERN" -type f -perm -u+x -print0 | sort -z)

# Append the explicitly-listed extra suites (default pattern only).
if [ "$PATTERN" = "test-*.sh" ]; then
	for extra in "${EXTRA_SUITES[@]}"; do
		if [ -f "$extra" ]; then
			run_suite "$extra"
		else
			echo "WARN: extra suite not found, skipping: ${extra#${REPO_ROOT}/}" >&2
		fi
	done
fi

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
