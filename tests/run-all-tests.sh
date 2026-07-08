#!/usr/bin/env bash
# tests/run-all-tests.sh — orchestrator for all repo test suites.
#
# CHAIN: none — all sub-suites are non-broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Discovers and runs every executable test-*.sh under tests/, reports
# per-suite PASS/FAIL, exits 0 iff every suite exits 0.
#
# Before any suite runs, a preflight guard (added 2026-07-08) inspects the
# environment itself: it refuses to proceed if python3 resolves to a shim
# (a crashed prior session once replaced the machine's real python3 with a
# scratchpad shell-script shim to fake a JSON-schema validator, and the
# suite still reported GREEN against that corrupted interpreter — nothing
# detected it), and it refuses to proceed if no JSON-schema validator (ajv
# or python3+jsonschema) is available at all, instead of letting
# validator-dependent suites silently skip or pass. See
# preflight_check_interpreter_integrity / preflight_check_validator_presence
# below for the exact checks the guard performs.
#
# Usage:
#   bash tests/run-all-tests.sh [--pattern=<glob>] [--preflight-only]
#
# Options:
#   --pattern=<glob>    Only run test files matching the glob.
#                       Default: 'test-*.sh'
#   --verbose           Show sub-suite stdout inline (default: summary only).
#   --preflight-only    Run ONLY the preflight guard (no suites), then exit
#                       with its result (0 pass / 1 fail). Exists so the
#                       guard is testable in isolation against a synthetic
#                       PATH without needing the real machine to be broken
#                       — see tests/run-all-tests-preflight/.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_ROOT="${REPO_ROOT}/tests"
PATTERN="test-*.sh"
VERBOSE=0
PREFLIGHT_ONLY=0

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
		--pattern=*)      PATTERN="${arg#*=}" ;;
		--verbose)        VERBOSE=1 ;;
		--preflight-only) PREFLIGHT_ONLY=1 ;;
		-h|--help)        sed -n '2,32p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)                echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

# ---- preflight guard (2026-07-08) --------------------------------------
# NEVER SHIM: everything below only INSPECTS and reports; it must never
# write, replace, symlink, or otherwise touch any binary or interpreter
# path — doing so would repeat exactly the incident this guard exists to
# catch. Factored as plain functions rather than a separate sourced lib
# file — this repo has no cross-script sourcing convention (see the R13
# comment in scripts/gen-anchor-source.sh, where schema_validate_or_die is
# deliberately duplicated instead of shared) — so --preflight-only above is
# how tests/run-all-tests-preflight/test-preflight-guard.sh exercises this
# logic against a synthetic PATH in isolation.

# preflight_check_interpreter_integrity — FAIL LOUD (rc=1) only if python3
# resolves to a shim, or resolves to something that errors when actually
# invoked. python3 being ABSENT from PATH is NOT a failure by itself (some
# hosts legitimately lack it) — only a shim or a broken/erroring python3
# fails this check.
preflight_check_interpreter_integrity() {
	if ! command -v python3 >/dev/null 2>&1; then
		echo "PREFLIGHT: python3 not on PATH — skipping interpreter-integrity check (absence alone is not a failure)" >&2
		return 0
	fi

	local resolved first2
	resolved="$(command -v python3)"

	# Static shim shape: a shim is specifically a SHELL SCRIPT (starts with
	# a '#!' shebang — a real python3 binary is ELF/Mach-O machine code and
	# never starts with those two bytes) whose body execs into a throwaway
	# or ephemeral path. This is exactly the shape of the 2026-07-08
	# incident: a scratchpad shell script that `exec`'d a venv python3
	# under /tmp.
	first2="$(head -c 2 -- "$resolved" 2>/dev/null || true)"
	if [ "$first2" = "#!" ] && grep -aEq 'exec[[:space:]]+.*(/tmp/|/private/tmp/|scratchpad|venv)' -- "$resolved" 2>/dev/null; then
		echo "PREFLIGHT FAIL: python3 (resolved: $resolved) is a shell script that execs a /tmp, /private/tmp, scratchpad, or venv path — that is the shape of a shim, not a real interpreter." >&2
		echo "PREFLIGHT FAIL: refusing to run any suite against a shimmed interpreter. Restore the real python3 (or remove the shim) before re-running." >&2
		return 1
	fi

	# Runtime check: a real interpreter must answer. Catches an interpreter
	# that is broken in a way the static shape check above does not
	# recognize (e.g. a shim whose exec target has already vanished).
	local out
	if ! out="$(python3 -c 'import sys; print(sys.executable)' 2>&1)" || [ -z "$out" ]; then
		echo "PREFLIGHT FAIL: python3 (resolved: $resolved) failed to run 'import sys; print(sys.executable)' — a real interpreter must answer:" >&2
		echo "$out" >&2
		return 1
	fi

	echo "PREFLIGHT: python3 interpreter integrity OK (resolved: $resolved -> sys.executable: $out)" >&2
	return 0
}

# preflight_check_validator_presence — FAIL LOUD (rc=1) if neither ajv nor
# python3+jsonschema is available. Mirrors schema_validate_or_die's own
# detection order (scripts/gen-anchor-source.sh, scripts/gen-anchor-receipt.sh,
# scripts/append-anchor-history.sh) so the guard's verdict always matches
# what those scripts will actually find at runtime. Never a silent skip:
# a missing validator is reported here as an explicit, non-green failure,
# not folded into the existing legitimate Linux-only anomalies SKIP.
#
# $1 (optional): pass a non-zero value when
# preflight_check_interpreter_integrity has already failed for this run.
# When set, this check does not also invoke python3 a second time for the
# jsonschema probe — a python3 already flagged as a shim/broken is not
# re-run just to answer this question; it relies on ajv alone instead.
preflight_check_validator_presence() {
	local interpreter_already_bad="${1:-0}"
	if command -v ajv >/dev/null 2>&1; then
		echo "PREFLIGHT: schema validator present (ajv)" >&2
		return 0
	fi
	if [ "$interpreter_already_bad" -eq 0 ] \
		&& command -v python3 >/dev/null 2>&1 \
		&& python3 -c 'import jsonschema' >/dev/null 2>&1; then
		echo "PREFLIGHT: schema validator present (python3+jsonschema)" >&2
		return 0
	fi
	if [ "$interpreter_already_bad" -ne 0 ]; then
		echo "PREFLIGHT FAIL: no JSON-schema validator available (ajv absent; python3 already flagged unhealthy above, so it was not re-invoked for the jsonschema probe)." >&2
	else
		echo "PREFLIGHT FAIL: no JSON-schema validator available (ajv absent; python3+jsonschema absent)." >&2
	fi
	echo "PREFLIGHT FAIL: run scripts/setup-schema-validator.sh to install one. Validator-dependent suites must never silently skip or pass without it." >&2
	return 1
}

run_preflight() {
	local rc=0 interp_rc=0
	echo "== preflight: interpreter integrity + schema-validator presence ==" >&2
	preflight_check_interpreter_integrity || { interp_rc=1; rc=1; }
	preflight_check_validator_presence "$interp_rc" || rc=1
	if [ "$rc" -eq 0 ]; then
		echo "== preflight: PASS ==" >&2
	else
		echo "== preflight: FAIL ==" >&2
	fi
	return "$rc"
}

if [ "$PREFLIGHT_ONLY" = "1" ]; then
	run_preflight
	exit $?
fi

run_preflight || exit 2

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
