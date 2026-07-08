#!/usr/bin/env bash
# tests/setup-schema-validator/test-setup-schema-validator.sh — unit test for
# scripts/setup-schema-validator.sh.
#
# Why this exists: a prior crashed session, faced with a host missing a
# JSON-schema validator, improvised by replacing the machine's real python3
# interpreter with a scratchpad shim; the venv vanished on crash and broke
# every python3 invocation on that machine. setup-schema-validator.sh is the
# sanctioned, package-manager-only replacement for that improvisation, and
# this test proves it never touches a real interpreter/binary/symlink while
# still making a validator "appear" for every combination the script can
# face on a real host.
#
# CHAIN: none. PRIME_DIRECTIVE: safe — this test never invokes a real
#        network install. npm/pip3/ajv/python3 are all stubbed on synthetic
#        PATH farms scoped to this test's own tmp dir; the real npm/pip3/
#        python3/ajv on this host (if any) are never consulted.
#
# Coverage:
#   1. already-have-ajv                  -> exit 0, npm/pip3 never invoked
#   2. already-have-jsonschema            -> exit 0, npm/pip3 never invoked
#   3. neither-present-npm-installs       -> npm invoked (not pip3), exit 0
#   4. neither-present-only-pip-installs  -> npm absent, pip3 invoked, exit 0
#   5. neither-present-no-installer       -> npm+pip3 both absent, exit
#                                             non-zero, message names both
#                                             manual install commands
#   6. (bonus) SETUP_VALIDATOR_PREFER=python flips the preference order
#      when both npm and pip3 are present
#   7. static safety: the script source never shims / symlink-retargets a
#      system path (the entire point of this task)
#   8. sandbox hygiene: none of the above ever wrote outside this test's
#      own temp fixtures (HOME is redirected to an empty canary dir for
#      the whole run and asserted still-empty at the end)
#
# Usage:
#   bash tests/setup-schema-validator/test-setup-schema-validator.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/setup-schema-validator.sh"

if [ ! -x "$SCRIPT" ]; then
	echo "FATAL: script not executable at $SCRIPT" >&2
	exit 1
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$label"
	else
		fail "$label (expected='$expected' actual='$actual')"
	fi
}

TMP="$(mktemp -d -t setup-schema-validator-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Redirect HOME to an empty canary dir for the whole run (case 8 below
# asserts it is still empty at the end) — a real npm/pip3 would touch
# dotfiles under HOME, so this also doubles as a tripwire in case a future
# edit to this test ever lets a real installer run instead of a stub.
CANARY_HOME="$TMP/canary-home"
mkdir -p "$CANARY_HOME"
export HOME="$CANARY_HOME"

# === stub builders ===========================================================

# Every farm needs its own `bash` so that `PATH="$farm" bash "$SCRIPT"`
# can resolve "bash" at all — a prefix PATH assignment changes command-word
# resolution for that same command, not just its own environment (verified
# empirically; mirrors the `bash` entry in the FARM_NO_VALIDATOR loop in
# tests/gen-anchor-source/test-gen-anchor-source.sh). This symlink only
# ever points at THIS host's real bash from inside a disposable tmp farm
# dir — it never touches, replaces, or retargets any real system path,
# which is the distinction the script under test exists to enforce.
new_farm() {
	mkdir -p "$1"
	ln -sf "$(command -v bash)" "$1/bash"
}

# Present-but-never-actually-run ajv: the script only does `command -v ajv`
# in the already-available branch, it never executes ajv itself.
stub_ajv_present() {
	cat > "$1/ajv" <<'EOF'
#!/usr/bin/env bash
echo "STUB ajv: should never actually be executed by setup-schema-validator.sh" >&2
exit 1
EOF
	chmod +x "$1/ajv"
}

# Call-recorder stubs: touch a marker file when invoked, so a case can
# assert whether npm/pip3 were called at all.
stub_npm_recorder() {
	local dir="$1" marker="$2"
	cat > "$dir/npm" <<EOF
#!/usr/bin/env bash
: >> "$marker"
echo "STUB npm called with: \$*" >&2
exit 0
EOF
	chmod +x "$dir/npm"
}

stub_pip3_recorder() {
	local dir="$1" marker="$2"
	cat > "$dir/pip3" <<EOF
#!/usr/bin/env bash
: >> "$marker"
echo "STUB pip3 called with: \$*" >&2
exit 0
EOF
	chmod +x "$dir/pip3"
}

# npm stub that actually "installs" ajv by dropping an ajv executable into
# the same farm dir (i.e. onto PATH) — simulates a real `npm i -g` making
# ajv resolvable afterward, with no real network/install.
stub_npm_installs_ajv() {
	local dir="$1" marker="$2"
	cat > "$dir/npm" <<EOF
#!/usr/bin/env bash
: >> "$marker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/ajv"
chmod +x "$dir/ajv"
exit 0
EOF
	chmod +x "$dir/npm"
}

# pip3 stub that "installs" jsonschema by writing installed_marker, which
# the paired python3 stub consults to decide whether the import succeeds.
stub_pip3_installs_jsonschema() {
	local dir="$1" call_marker="$2" installed_marker="$3"
	cat > "$dir/pip3" <<EOF
#!/usr/bin/env bash
: >> "$call_marker"
: >> "$installed_marker"
exit 0
EOF
	chmod +x "$dir/pip3"
}

# python3 stub: `import jsonschema` succeeds iff installed_marker exists.
# Any other invocation shape is refused loudly so an unexpected call shape
# shows up as a fast, visible test failure rather than a silent pass.
stub_python3_conditional() {
	local dir="$1" installed_marker="$2"
	cat > "$dir/python3" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-c" ] && [ "\$2" = "import jsonschema" ]; then
	[ -e "$installed_marker" ] && exit 0 || exit 1
fi
echo "STUB python3: unexpected invocation: \$*" >&2
exit 1
EOF
	chmod +x "$dir/python3"
}

# python3 stub that always fails the jsonschema import — used when a farm
# needs to resemble a real host that has python3 but not the module.
stub_python3_no_jsonschema() {
	cat > "$1/python3" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "import jsonschema" ]; then
	exit 1
fi
echo "STUB python3: unexpected invocation: $*" >&2
exit 1
EOF
	chmod +x "$1/python3"
}

# Harness sanity: the named tools must be genuinely absent via this farm's
# PATH, otherwise the case using it would not test what it claims to.
assert_farm_clean() {
	local farm="$1"; shift
	for t in "$@"; do
		if PATH="$farm" command -v "$t" >/dev/null 2>&1; then
			fail "harness leaked $t into farm $farm — refusing to trust this case"
		fi
	done
}

# =====================================================================
# case 1: already-have-ajv -> exit 0, npm/pip3 never invoked
# =====================================================================
F1="$TMP/farm1"; new_farm "$F1"
stub_ajv_present "$F1"
NPM1_MARKER="$TMP/farm1-npm-called"
PIP1_MARKER="$TMP/farm1-pip3-called"
stub_npm_recorder "$F1" "$NPM1_MARKER"
stub_pip3_recorder "$F1" "$PIP1_MARKER"

OUT1="$(PATH="$F1" bash "$SCRIPT" 2>"$TMP/case1.stderr")"
RC1=$?
check_eq "case1 already-have-ajv: exit 0" "0" "$RC1"
echo "$OUT1" | grep -q "ajv already available" \
	&& pass "case1: prints 'ajv already available'" \
	|| fail "case1: missing expected message (got: $OUT1)"
[ -e "$NPM1_MARKER" ] && fail "case1: npm was invoked but must not be" || pass "case1: npm never invoked"
[ -e "$PIP1_MARKER" ] && fail "case1: pip3 was invoked but must not be" || pass "case1: pip3 never invoked"

# =====================================================================
# case 2: already-have-jsonschema (ajv absent) -> exit 0, npm/pip3 never
# invoked
# =====================================================================
F2="$TMP/farm2"; new_farm "$F2"
INSTALLED2_MARKER="$TMP/farm2-jsonschema-installed"
: > "$INSTALLED2_MARKER"   # pre-mark "already installed"
stub_python3_conditional "$F2" "$INSTALLED2_MARKER"
NPM2_MARKER="$TMP/farm2-npm-called"
PIP2_MARKER="$TMP/farm2-pip3-called"
stub_npm_recorder "$F2" "$NPM2_MARKER"
stub_pip3_recorder "$F2" "$PIP2_MARKER"
assert_farm_clean "$F2" ajv

OUT2="$(PATH="$F2" bash "$SCRIPT" 2>"$TMP/case2.stderr")"
RC2=$?
check_eq "case2 already-have-jsonschema: exit 0" "0" "$RC2"
echo "$OUT2" | grep -q "python3+jsonschema already available" \
	&& pass "case2: prints 'python3+jsonschema already available'" \
	|| fail "case2: missing expected message (got: $OUT2)"
[ -e "$NPM2_MARKER" ] && fail "case2: npm was invoked but must not be" || pass "case2: npm never invoked"
[ -e "$PIP2_MARKER" ] && fail "case2: pip3 was invoked but must not be" || pass "case2: pip3 never invoked"

# =====================================================================
# case 3: neither present, both npm and pip3 present -> default
# prefer=ajv must choose npm, and the install must make ajv resolvable
# =====================================================================
F3="$TMP/farm3"; new_farm "$F3"
stub_python3_no_jsonschema "$F3"
NPM3_MARKER="$TMP/farm3-npm-called"
PIP3_MARKER="$TMP/farm3-pip3-called"
assert_farm_clean "$F3" ajv
stub_npm_installs_ajv "$F3" "$NPM3_MARKER"
stub_pip3_recorder "$F3" "$PIP3_MARKER"

OUT3="$(PATH="$F3" bash "$SCRIPT" 2>"$TMP/case3.stderr")"
RC3=$?
check_eq "case3 neither-present-npm-installs: exit 0" "0" "$RC3"
[ -e "$NPM3_MARKER" ] && pass "case3: npm was invoked" || fail "case3: npm never invoked"
[ -e "$PIP3_MARKER" ] && fail "case3: pip3 was invoked but must not be (npm preferred+available)" || pass "case3: pip3 never invoked"
echo "$OUT3" | grep -qi "ajv now available" \
	&& pass "case3: reports ajv available after install" \
	|| fail "case3: missing post-install confirmation (got: $OUT3)"

# =====================================================================
# case 4: neither present, npm ABSENT, pip3 installs jsonschema
# =====================================================================
F4="$TMP/farm4"; new_farm "$F4"
INSTALLED4_MARKER="$TMP/farm4-jsonschema-installed"
PIP4_MARKER="$TMP/farm4-pip3-called"
stub_python3_conditional "$F4" "$INSTALLED4_MARKER"
assert_farm_clean "$F4" ajv npm
stub_pip3_installs_jsonschema "$F4" "$PIP4_MARKER" "$INSTALLED4_MARKER"

OUT4="$(PATH="$F4" bash "$SCRIPT" 2>"$TMP/case4.stderr")"
RC4=$?
check_eq "case4 neither-present-only-pip-installs: exit 0" "0" "$RC4"
[ -e "$PIP4_MARKER" ] && pass "case4: pip3 was invoked" || fail "case4: pip3 never invoked"
echo "$OUT4" | grep -qi "jsonschema now available" \
	&& pass "case4: reports jsonschema available after install" \
	|| fail "case4: missing post-install confirmation (got: $OUT4)"

# =====================================================================
# case 5: neither present, no installer at all -> exit non-zero, message
# names both manual install commands
# =====================================================================
F5="$TMP/farm5"; new_farm "$F5"
assert_farm_clean "$F5" ajv npm pip3 python3

OUT5="$(PATH="$F5" bash "$SCRIPT" 2>"$TMP/case5.stderr")"
RC5=$?
if [ "$RC5" -ne 0 ]; then
	pass "case5 neither-present-no-installer: exit non-zero (rc=$RC5)"
else
	fail "case5 neither-present-no-installer: exit 0 (expected non-zero)"
fi
ERR5="$(cat "$TMP/case5.stderr")"
echo "$ERR5" | grep -q "npm i -g ajv-cli ajv-formats" \
	&& pass "case5: message names the npm manual option" \
	|| fail "case5: missing npm manual-option text (got: $ERR5)"
echo "$ERR5" | grep -q "pip3 install --break-system-packages jsonschema" \
	&& pass "case5: message names the pip3 manual option" \
	|| fail "case5: missing pip3 manual-option text (got: $ERR5)"
[ -e "$TMP/farm5/ajv" ] && fail "case5: ajv must not have been created" || pass "case5: no ajv created"

# =====================================================================
# case 6 (bonus): SETUP_VALIDATOR_PREFER=python flips the order when both
# managers are present -> pip3 chosen, npm left uninvoked. This is the
# "never fail solely because the preferred one is missing" contract's
# mirror image (here both ARE present, so the preference itself decides).
# =====================================================================
F6="$TMP/farm6"; new_farm "$F6"
INSTALLED6_MARKER="$TMP/farm6-jsonschema-installed"
NPM6_MARKER="$TMP/farm6-npm-called"
PIP6_MARKER="$TMP/farm6-pip3-called"
stub_python3_conditional "$F6" "$INSTALLED6_MARKER"
assert_farm_clean "$F6" ajv
stub_npm_recorder "$F6" "$NPM6_MARKER"
stub_pip3_installs_jsonschema "$F6" "$PIP6_MARKER" "$INSTALLED6_MARKER"

OUT6="$(SETUP_VALIDATOR_PREFER=python PATH="$F6" bash "$SCRIPT" 2>"$TMP/case6.stderr")"
RC6=$?
check_eq "case6 prefer=python: exit 0" "0" "$RC6"
[ -e "$PIP6_MARKER" ] && pass "case6: pip3 was invoked (preferred)" || fail "case6: pip3 never invoked"
[ -e "$NPM6_MARKER" ] && fail "case6: npm was invoked but must not be (pip3 preferred+available)" || pass "case6: npm never invoked"

# =====================================================================
# case 7: static safety — the script must never shim / symlink-retarget a
# system path, or touch homebrew/framework paths. This is the entire
# point of this task (see the Global Constraints this script was written
# against): a validator may ONLY be made available via package managers.
# =====================================================================
if grep -qE 'ln[[:space:]]+-[a-zA-Z]*s' "$SCRIPT"; then
	fail "static: script must never create a symlink (found 'ln -s...')"
else
	pass "static: script contains no 'ln -s...' (no symlink retargeting)"
fi
if grep -qE '/opt/homebrew|\.framework' "$SCRIPT"; then
	fail "static: script references /opt/homebrew or a .framework path"
else
	pass "static: script never references /opt/homebrew or a .framework path"
fi
if grep -qE '(^|[^#])\s*(sudo[[:space:]]+)?(cp|mv)[[:space:]]' "$SCRIPT"; then
	fail "static: script must never cp/mv a file (would risk overwriting a system path)"
else
	pass "static: script contains no cp/mv (only ever shells out to npm/pip3)"
fi

# =====================================================================
# case 8: sandbox hygiene — none of the above cases wrote anything outside
# this test's own temp fixtures. HOME was redirected to an empty canary
# dir for the whole run (see top of file); it must still be empty now.
# =====================================================================
if [ -z "$(ls -A "$CANARY_HOME" 2>/dev/null)" ]; then
	pass "sandbox hygiene: HOME (canary) received zero writes across all cases"
else
	fail "sandbox hygiene: unexpected files appeared under HOME: $(ls -A "$CANARY_HOME")"
fi

# ---- summary -----------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-setup-schema-validator.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
