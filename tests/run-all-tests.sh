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
# (so the find below never discovers them). Listed explicitly so the default
# full run always covers them — do NOT let a new non-matching suite go
# silently unrun; either make it match test-*.sh, or register it here.
#   - tests/cycle-gate/run-tests.sh bundles 20 scenario tests; historically
#     silently excluded from the aggregate (fixed 2026-07-07).
#   - tests/anomalies/integration-linux.sh is the K-1..K-4 end-to-end
#     integration suite. It refuses itself (exit 2) off real Linux (needs
#     flock + GNU date), so it is only appended to the aggregate run when
#     this host can actually execute it — see the uname check below. Off
#     Linux we still print a visible line so the suite is never silently
#     absent from the run's output.
# Only appended when running the default pattern; a caller-supplied
# --pattern is honoured verbatim.
EXTRA_SUITES=(
	"${TESTS_ROOT}/cycle-gate/run-tests.sh"
)
if [ "$(uname)" = "Linux" ]; then
	EXTRA_SUITES+=("${TESTS_ROOT}/anomalies/integration-linux.sh")
fi

# Extra suites whose own interpreter is not bash (e.g. a python3 unittest
# module) — kept in a separate array of "interpreter:path" pairs since
# run_suite's default invocation is `bash <path>`, which cannot execute a
# non-shell file. tests/ops/test_b6_enable_cron.py was previously
# unreachable by both the test-*.sh glob (underscore + .py, not -*.sh) and
# EXTRA_SUITES (needs python3, not bash) — silently skipped end to end.
EXTRA_SUITES_OTHER=(
	"python3:${TESTS_ROOT}/ops/test_b6_enable_cron.py"
)

run_suite() {
	# $1 = absolute path to an executable suite runner.
	# $2 = interpreter to invoke it with (default: bash). Used for suites
	#      that are not themselves bash scripts.
	local test_file="$1" interpreter="${2:-bash}" rel_path rc out
	SUITES_TOTAL=$((SUITES_TOTAL + 1))
	rel_path="${test_file#${REPO_ROOT}/}"
	printf '=== %-55s === ' "$rel_path"
	if [ "$VERBOSE" = "1" ]; then
		echo
		"$interpreter" "$test_file"
		rc=$?
	else
		out="$("$interpreter" "$test_file" 2>&1)"
		rc=$?
	fi
	if [ "$rc" -eq 0 ]; then
		if [ "$VERBOSE" = "0" ]; then
			# extract just the summary line (per-suite formats vary:
			# `test-*.sh summary: ...`, cycle-gate's `RESULTS: N PASS / M FAIL`,
			# or python unittest's `Ran N tests in ...s`)
			echo "PASS ($(echo "$out" | grep -E '^(test-.*summary:|RESULTS:|Ran [0-9]+ tests? in)' | head -1))"
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
	if [ "$(uname)" != "Linux" ]; then
		echo "SKIP: tests/anomalies/integration-linux.sh — requires Linux (flock + GNU date); not counted in this host's run" >&2
	fi
	for extra in "${EXTRA_SUITES[@]}"; do
		if [ -f "$extra" ]; then
			run_suite "$extra"
		else
			echo "WARN: extra suite not found, skipping: ${extra#${REPO_ROOT}/}" >&2
		fi
	done
	for entry in "${EXTRA_SUITES_OTHER[@]}"; do
		interp="${entry%%:*}"
		path="${entry#*:}"
		if [ -f "$path" ]; then
			run_suite "$path" "$interp"
		else
			echo "WARN: extra suite not found, skipping: ${path#${REPO_ROOT}/}" >&2
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
