#!/usr/bin/env bash
# tests/run-all-tests-preflight/test-preflight-guard.sh — unit test for the
# preflight guard added to tests/run-all-tests.sh on 2026-07-08
# (preflight_check_interpreter_integrity / preflight_check_validator_presence
# / run_preflight).
#
# Why this exists: a crashed prior session, faced with a host missing a
# JSON-schema validator, replaced the machine's real python3 interpreter
# with a scratchpad shell-script shim to fake one. The test suite still
# reported GREEN against that corrupted interpreter — nothing detected it.
# The preflight guard exists so that failure mode can never pass as green
# again: it inspects (never touches) whatever python3 resolves to, and it
# refuses to let any suite run if no JSON-schema validator is available at
# all. This test proves the guard actually fires — and, just as
# importantly, that it does NOT fire on a legitimately clean host (no
# python3 at all, or a real working one) — without requiring the real
# machine to be broken.
#
# CHAIN: none. PRIME_DIRECTIVE: safe — this test never touches this host's
#        real python3/ajv/pip3/npm. Every case below runs the guard via
#        `tests/run-all-tests.sh --preflight-only` against a synthetic PATH
#        farm (a disposable tmp dir containing only symlinks to this
#        host's own bash/dirname/grep/head plus, per case, stub
#        python3/ajv scripts) — mirrors the farm pattern in
#        tests/setup-schema-validator/test-setup-schema-validator.sh.
#
# Coverage:
#   1. shimmed python3 (a shell script that execs a /tmp path) with ajv
#      ALSO present -> guard FAILs, message names the shim shape. ajv's
#      presence isolates that the failure is the interpreter check, not
#      validator-presence.
#   2. broken (non-shim-shaped) python3 that errors on every invocation
#      -> guard FAILs via the "python3 -c ... fails to run" branch,
#      independent of the static shim-shape detector.
#   3. python3 present+working but jsonschema absent, ajv absent -> guard
#      FAILs and points at scripts/setup-schema-validator.sh; interpreter
#      integrity is independently reported OK (isolates the failure to
#      validator-presence).
#   4. clean env: python3 absent entirely (legitimate on some hosts), ajv
#      present as the stub validator -> guard PASSes.
#   5. clean env: python3 present+working+jsonschema, ajv absent -> guard
#      PASSes via the python3+jsonschema branch.
#   6. isolation: --preflight-only never reaches suite discovery/summary
#      output, on either a PASS or a FAIL run.
#   7. wiring: the SAME failing preflight also aborts the real (non-
#      --preflight-only) orchestrator entry point before any suite runs
#      or is counted in the OVERALL summary — proves the guard isn't only
#      reachable in isolation.
#   8. shim + no ajv: validator-presence FAILs without re-invoking the
#      already-flagged-bad python3 a second time for the jsonschema
#      probe — proven via a marker the shim only touches if executed.
#
# Usage:
#   bash tests/run-all-tests-preflight/test-preflight-guard.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD_SCRIPT="${REPO_ROOT}/tests/run-all-tests.sh"

if [ ! -f "$GUARD_SCRIPT" ]; then
	echo "FATAL: guard script not found at $GUARD_SCRIPT" >&2
	exit 1
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d -t preflight-guard-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# === farm builder ============================================================
# Every farm needs its own bash (a prefix `PATH=... bash ...` assignment
# changes command-word resolution for that same "bash" word, not just its
# own environment — see the identical note in
# tests/setup-schema-validator/test-setup-schema-validator.sh) plus the
# handful of coreutils the guard itself calls before any suite-discovery
# code path is reached: dirname (for $0 resolution) and grep+head (for the
# interpreter shim-shape check). These are symlinks to THIS host's own
# real binaries from inside a disposable tmp dir — never a replacement of
# any real system path, which is the exact distinction the guard exists
# to enforce.
new_farm() {
	mkdir -p "$1"
	ln -sf "$(command -v bash)" "$1/bash"
	ln -sf "$(command -v dirname)" "$1/dirname"
	ln -sf "$(command -v grep)" "$1/grep"
	ln -sf "$(command -v head)" "$1/head"
}

# Present-but-never-actually-run ajv stub: the guard only does
# `command -v ajv`, it never executes ajv itself.
stub_ajv_present() {
	cat > "$1/ajv" <<'EOF'
#!/usr/bin/env bash
echo "STUB ajv: should never actually be executed by the preflight guard" >&2
exit 1
EOF
	chmod +x "$1/ajv"
}

# Working (non-shim) python3 stub: answers the guard's two `-c` probes for
# real. $2 controls whether `import jsonschema` succeeds (0) or fails (1).
stub_python3_working() {
	local dir="$1" jsonschema_rc="$2"
	cat > "$dir/python3" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-c" ] && [ "\$2" = "import sys; print(sys.executable)" ]; then
	echo "${dir}/python3-real-stub"
	exit 0
fi
if [ "\$1" = "-c" ] && [ "\$2" = "import jsonschema" ]; then
	exit ${jsonschema_rc}
fi
echo "STUB python3: unexpected invocation: \$*" >&2
exit 1
EOF
	chmod +x "$dir/python3"
}

# Shim python3: a shell script that execs a /tmp path — exactly the shape
# of the 2026-07-08 incident. Never actually reached at exec time in this
# test: the guard's static shim-shape check must catch it and return
# before invoking it.
stub_python3_shim() {
	cat > "$1/python3" <<'EOF'
#!/bin/sh
exec /tmp/some-scratchpad-venv/bin/python3 "$@"
EOF
	chmod +x "$1/python3"
}

# Broken (non-shim-shaped) python3: a normal-looking script that simply
# errors on every invocation, regardless of args. Covers the "python3 -c
# ... fails to run" OR-branch of the interpreter-integrity check
# independent of the static shim-shape detector (no /tmp, scratchpad, or
# venv path appears anywhere in this stub's body).
stub_python3_broken() {
	cat > "$1/python3" <<'EOF'
#!/bin/sh
echo "broken interpreter stub: nothing answers here" >&2
exit 127
EOF
	chmod +x "$1/python3"
}

# Shim python3 that also touches a marker file the instant it is actually
# executed — lets a case prove the shim was NEVER invoked a second time
# (e.g. by the validator-presence check's jsonschema probe) after the
# interpreter-integrity check already flagged it via the static
# shim-shape detector.
stub_python3_shim_with_marker() {
	local dir="$1" marker="$2"
	cat > "$dir/python3" <<EOF
#!/bin/sh
: >> "$marker"
exec /tmp/some-scratchpad-venv/bin/python3 "\$@"
EOF
	chmod +x "$dir/python3"
}

run_guard() {
	# $1 = farm dir, remaining = extra args to the guard script.
	local farm="$1"; shift
	PATH="$farm" bash "$GUARD_SCRIPT" "$@"
}

# =====================================================================
# case 1: shimmed python3 (execs a /tmp path) + ajv ALSO present -> guard
# must still FAIL. ajv's presence isolates that the failure comes from
# the interpreter-integrity check, not validator-presence.
# =====================================================================
F1="$TMP/farm1"; new_farm "$F1"
stub_python3_shim "$F1"
stub_ajv_present "$F1"
OUT1="$(run_guard "$F1" --preflight-only 2>&1)"; RC1=$?
if [ "$RC1" -ne 0 ]; then
	pass "case1 shimmed python3: guard exits non-zero (rc=$RC1)"
else
	fail "case1 shimmed python3: guard exited 0 (expected FAIL)"
fi
echo "$OUT1" | grep -q "shell script that execs" \
	&& pass "case1: message names the shim shape" \
	|| fail "case1: missing shim-shape message (got: $OUT1)"

# =====================================================================
# case 2: broken (non-shim-shaped) python3 -> guard must FAIL via the
# execution-check branch.
# =====================================================================
F2="$TMP/farm2"; new_farm "$F2"
stub_python3_broken "$F2"
stub_ajv_present "$F2"
OUT2="$(run_guard "$F2" --preflight-only 2>&1)"; RC2=$?
if [ "$RC2" -ne 0 ]; then
	pass "case2 broken python3: guard exits non-zero (rc=$RC2)"
else
	fail "case2 broken python3: guard exited 0 (expected FAIL)"
fi
echo "$OUT2" | grep -q "failed to run" \
	&& pass "case2: message names the execution failure" \
	|| fail "case2: missing execution-failure message (got: $OUT2)"

# =====================================================================
# case 3: validator missing (no ajv; python3 present+working but no
# jsonschema) -> guard must FAIL and point at setup-schema-validator.sh.
# Interpreter integrity independently reports OK, isolating this to the
# validator-presence check.
# =====================================================================
F3="$TMP/farm3"; new_farm "$F3"
stub_python3_working "$F3" 1
OUT3="$(run_guard "$F3" --preflight-only 2>&1)"; RC3=$?
if [ "$RC3" -ne 0 ]; then
	pass "case3 no validator available: guard exits non-zero (rc=$RC3)"
else
	fail "case3 no validator available: guard exited 0 (expected FAIL)"
fi
echo "$OUT3" | grep -q "setup-schema-validator.sh" \
	&& pass "case3: message points to scripts/setup-schema-validator.sh" \
	|| fail "case3: missing installer pointer (got: $OUT3)"
echo "$OUT3" | grep -qi "interpreter integrity OK" \
	&& pass "case3: interpreter integrity independently OK (isolates the validator-only failure)" \
	|| fail "case3: expected interpreter check to have passed (got: $OUT3)"

# =====================================================================
# case 4: clean env — python3 absent entirely (legitimate on some hosts),
# ajv present as the stub validator -> guard must PASS.
# =====================================================================
F4="$TMP/farm4"; new_farm "$F4"
stub_ajv_present "$F4"
OUT4="$(run_guard "$F4" --preflight-only 2>&1)"; RC4=$?
if [ "$RC4" -eq 0 ]; then
	pass "case4 clean env + ajv, no python3: guard exits 0"
else
	fail "case4 clean env + ajv, no python3: guard exited non-zero (rc=$RC4): $OUT4"
fi
echo "$OUT4" | grep -q "python3 not on PATH" \
	&& pass "case4: absence of python3 reported as non-failure info" \
	|| fail "case4: missing python3-absent info line (got: $OUT4)"
echo "$OUT4" | grep -q "== preflight: PASS ==" \
	&& pass "case4: preflight banner reports PASS" \
	|| fail "case4: missing PASS banner (got: $OUT4)"

# =====================================================================
# case 5: clean env — working python3 + jsonschema present, ajv absent ->
# guard must PASS via the python3+jsonschema branch.
# =====================================================================
F5="$TMP/farm5"; new_farm "$F5"
stub_python3_working "$F5" 0
OUT5="$(run_guard "$F5" --preflight-only 2>&1)"; RC5=$?
if [ "$RC5" -eq 0 ]; then
	pass "case5 clean env + python3+jsonschema: guard exits 0"
else
	fail "case5 clean env + python3+jsonschema: guard exited non-zero (rc=$RC5): $OUT5"
fi
echo "$OUT5" | grep -q "python3+jsonschema" \
	&& pass "case5: message names the python3+jsonschema branch" \
	|| fail "case5: missing python3+jsonschema message (got: $OUT5)"

# =====================================================================
# case 6: --preflight-only never reaches suite discovery/summary output,
# on either a PASS run (case4's output) or a FAIL run (case1's output).
# =====================================================================
echo "$OUT4" | grep -q "OVERALL:" \
	&& fail "case6: --preflight-only PASS run reached the suite OVERALL summary (should never run suites)" \
	|| pass "case6: --preflight-only PASS run never reached the suite OVERALL summary"
echo "$OUT1" | grep -q "running test suites" \
	&& fail "case6: --preflight-only FAIL run reached the suite-discovery banner" \
	|| pass "case6: --preflight-only FAIL run never reached the suite-discovery banner"

# =====================================================================
# case 7: wiring — the SAME failing preflight also aborts the real
# (non---preflight-only) orchestrator entry point, before any suite runs
# or is counted. --pattern is set to a glob nothing can match so a
# passing case can't accidentally mask a real suite failure.
# =====================================================================
F7="$TMP/farm7"; new_farm "$F7"
stub_python3_shim "$F7"
stub_ajv_present "$F7"
OUT7="$(run_guard "$F7" --pattern="no-such-test-*.sh" 2>&1)"; RC7=$?
if [ "$RC7" -ne 0 ]; then
	pass "case7 normal-mode wiring: guard failure aborts the real orchestrator (rc=$RC7)"
else
	fail "case7 normal-mode wiring: orchestrator exited 0 despite a shimmed python3"
fi
echo "$OUT7" | grep -q "OVERALL:" \
	&& fail "case7: orchestrator reached the OVERALL summary despite preflight failure (a suite ran or was counted)" \
	|| pass "case7: orchestrator never reached the OVERALL summary (no suite was ever counted)"

# =====================================================================
# case 8: shim + no ajv -> validator-presence must FAIL WITHOUT
# re-invoking the already-flagged-bad python3 a second time for the
# jsonschema probe. Proven by a marker the shim touches only if actually
# executed; it must still not exist after the run.
# =====================================================================
F8="$TMP/farm8"; new_farm "$F8"
MARKER8="$TMP/farm8-shim-executed"
stub_python3_shim_with_marker "$F8" "$MARKER8"
OUT8="$(run_guard "$F8" --preflight-only 2>&1)"; RC8=$?
if [ "$RC8" -ne 0 ]; then
	pass "case8 shim + no ajv: guard exits non-zero (rc=$RC8)"
else
	fail "case8 shim + no ajv: guard exited 0 (expected FAIL)"
fi
if [ -e "$MARKER8" ]; then
	fail "case8: shimmed python3 was actually executed by the validator-presence probe (marker exists) — should rely on ajv-only once interpreter is already flagged bad"
else
	pass "case8: shimmed python3 was never re-invoked by the validator-presence probe"
fi
echo "$OUT8" | grep -q "not re-invoked" \
	&& pass "case8: message explains why python3 was not re-invoked" \
	|| fail "case8: missing not-re-invoked explanation (got: $OUT8)"

# ---- summary -----------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-preflight-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
