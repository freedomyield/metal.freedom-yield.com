#!/usr/bin/env bash
# test-schema-validate-ajv-path.sh — schema_validate_or_die's ajv path.
#
# Invariant: ajv-cli 5 chooses its parser from the data file's extension, so
# the function must hand ajv a ".json" copy of the (extension-less) mktemp
# data file; a non-conforming document must fail on the ajv path; a failure
# to prepare the copy must fail closed; temp files must not leak.
#
# The function is duplicated in 4 scripts (no cross-script sourcing). This
# test extracts each copy and runs it against a fake `ajv` on PATH.
#
# Usage: bash tests/schema-validate-ajv-path/test-schema-validate-ajv-path.sh
# Exit: 0 all PASS, 1 any FAIL.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS=(
	scripts/gen-anchor-source.sh
	scripts/gen-anchor-receipt.sh
	scripts/append-anchor-history.sh
	scripts/operator-local/commit-anchor-source.sh
)

TEST_DIR="$(mktemp -d -t schema-ajv-path.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/fn" "$TEST_DIR/tmp"

# Fake ajv: mimics ajv-cli 5's extension-based parsing. Schema = {"required":[..]}.
cat > "$TEST_DIR/bin/ajv" <<'STUB'
#!/usr/bin/env bash
data=""; schema=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-d) data="$2"; shift 2 ;;
		-s) schema="$2"; shift 2 ;;
		*) shift ;;
	esac
done
case "$data" in
	*.json) ;;
	*) echo "error: Unexpected token ':' in $data" >&2; exit 1 ;;
esac
if [ "${FAKE_AJV_VERDICT:-}" = "invalid" ]; then
	echo "$data invalid" >&2; exit 1
fi
# ajv could not read the data even though it is a .json file
if [ "${FAKE_AJV_VERDICT:-}" = "unreadable" ]; then
	echo "error: Unexpected token ':' in JSON at position 3" >&2; exit 1
fi
python3 - "$schema" "$data" <<'PY'
import json, sys
schema = json.load(open(sys.argv[1]))
data = json.load(open(sys.argv[2]))
missing = [k for k in schema.get("required", []) if k not in data]
if missing:
	print("invalid: missing", missing, file=sys.stderr); sys.exit(1)
print("valid")
PY
STUB
chmod +x "$TEST_DIR/bin/ajv"

# Fake mktemp: BSD and GNU mktemp differ on whether TMPDIR is honoured for a
# bare `mktemp -d`; force every temp dir the function makes into $TEST_DIR/tmp
# so leaks are countable on both.
REAL_MKTEMP="$(command -v mktemp)"
cat > "$TEST_DIR/bin/mktemp" <<STUB
#!/usr/bin/env bash
[ -n "\${FAKE_MKTEMP_FAIL:-}" ] && exit 1
exec "$REAL_MKTEMP" -d "$TEST_DIR/tmp/x.XXXXXX"
STUB
chmod +x "$TEST_DIR/bin/mktemp"

printf '{"required":["a"]}' > "$TEST_DIR/schema.json"
printf '{"a":1}'  > "$TEST_DIR/good"   # no extension, like mktemp output
printf '{"b":1}'  > "$TEST_DIR/bad"
printf '%s' 'not json' > "$TEST_DIR/garbage"

PASS=0; FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
ng()   { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { # name expected_rc actual_rc
	if [ "$2" = "$3" ]; then ok "$1 (rc=$3)"; else ng "$1 (expected rc=$2 got rc=$3)"; fi
}
nonzero() { # name actual_rc
	if [ "$2" != "0" ]; then ok "$1 (rc=$2)"; else ng "$1 (expected non-zero, got 0)"; fi
}

extract_fn() { # script out
	awk '/^schema_validate_or_die\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO_ROOT/$1" > "$2"
}

# call <fnfile> <data> [extra-path-dir]  -> rc ; stderr in $TEST_DIR/err
call() {
	local fnfile="$1" data="$2" extra="${3:-}"
	PATH="${extra:+$extra:}$TEST_DIR/bin:$PATH" TMPDIR="$TEST_DIR/tmp" \
		bash -c 'source "$1"; schema_validate_or_die "$2" "$3" "t"' _ \
		"$fnfile" "$TEST_DIR/schema.json" "$data" >/dev/null 2>"$TEST_DIR/err"
}

leaks() { find "$TEST_DIR/tmp" -mindepth 1 | wc -l | tr -d ' '; }

run_suite() { # label dir-of-fn-files
	local label="$1" d="$2" i s fn rc
	for i in "${!SCRIPTS[@]}"; do
		s="${SCRIPTS[$i]}"; fn="$d/$i.fn"
		call "$fn" "$TEST_DIR/good"; rc=$?
		check "$label $s: conforming extension-less data passes via ajv" 0 "$rc"
		call "$fn" "$TEST_DIR/bad"; rc=$?
		check "$label $s: non-conforming data fails via ajv" 6 "$rc"
		FAKE_AJV_VERDICT=invalid call "$fn" "$TEST_DIR/good"; rc=$?
		check "$label $s: ajv 'invalid' verdict gives non-zero" 6 "$rc"
		FAKE_AJV_VERDICT=unreadable call "$fn" "$TEST_DIR/good"; rc=$?
		check "$label $s: ajv 'Unexpected token' (could not read) is not a pass" 6 "$rc"
		FAKE_MKTEMP_FAIL=1 call "$fn" "$TEST_DIR/good"; rc=$?
		check "$label $s: mktemp failure is not a pass" 6 "$rc"
		call "$fn" "$TEST_DIR/garbage"; rc=$?
		nonzero "$label $s: unparseable data is not a pass" "$rc"
		if [ "$(leaks)" = "0" ]; then ok "$label $s: no temp files leaked"; else ng "$label $s: temp files leaked"; rm -rf "$TEST_DIR/tmp"; mkdir -p "$TEST_DIR/tmp"; fi
	done
}

for i in "${!SCRIPTS[@]}"; do
	extract_fn "${SCRIPTS[$i]}" "$TEST_DIR/fn/$i.fn"
	[ -s "$TEST_DIR/fn/$i.fn" ] || { echo "FATAL: function missing in ${SCRIPTS[$i]}" >&2; exit 1; }
done

run_suite "real" "$TEST_DIR/fn"

# Fail closed when the .json copy cannot be made (fake cp that fails).
mkdir -p "$TEST_DIR/failcp"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_DIR/failcp/cp"; chmod +x "$TEST_DIR/failcp/cp"
for i in "${!SCRIPTS[@]}"; do
	call "$TEST_DIR/fn/$i.fn" "$TEST_DIR/good" "$TEST_DIR/failcp"; rc=$?
	check "${SCRIPTS[$i]}: cp failure fails closed" 6 "$rc"
done
if [ "$(leaks)" = "0" ]; then ok "cp failure: no temp dir leaked"; else ng "cp failure: temp dir leaked"; fi

# (d) the ajv branch must be byte-identical across the 4 copies.
# Only the exit-status label "ERROR (6):" vs "ERROR:" legitimately differs
# between copies; normalise it, compare everything else.
branch() { awk '/command -v ajv/{p=1} p{print} p&&/^\tfi$/{exit}' "$1" | sed -e 's/ERROR ([0-9]):/ERROR:/'; }
branch "$TEST_DIR/fn/0.fn" > "$TEST_DIR/branch.0"
[ -s "$TEST_DIR/branch.0" ] || ng "ajv branch extraction empty"
for i in 1 2 3; do
	branch "$TEST_DIR/fn/$i.fn" > "$TEST_DIR/branch.$i"
	if diff -q "$TEST_DIR/branch.0" "$TEST_DIR/branch.$i" >/dev/null; then ok "ajv branch of ${SCRIPTS[$i]} identical to ${SCRIPTS[0]}"; else ng "ajv branch of ${SCRIPTS[$i]} differs"; fi
done

# ---- Mutants: each must make the suite fail ----
mutant() { # name sed-expr
	local name="$1" expr="$2" i md="$TEST_DIR/mut"
	rm -rf "$md"; mkdir -p "$md"
	for i in "${!SCRIPTS[@]}"; do sed -e "$expr" "$TEST_DIR/fn/$i.fn" > "$md/$i.fn"; done
	if cmp -s "$TEST_DIR/fn/0.fn" "$md/0.fn"; then ng "mutant '$name' changed nothing"; return; fi
	local saved_pass="$PASS" saved_fail="$FAIL"
	run_suite "mutant" "$md" >/dev/null 2>&1
	local mfail=$((FAIL - saved_fail))
	PASS="$saved_pass"; FAIL="$saved_fail"
	rm -rf "$TEST_DIR/tmp"; mkdir -p "$TEST_DIR/tmp"
	if [ "$mfail" -gt 0 ]; then ok "mutant '$name' caught ($mfail checks failed)"; else ng "mutant '$name' NOT caught"; fi
}
mutant "pass the extension-less file to ajv (no .json copy)" 's|-d "\$ajv_data"|-d "$data_file"|'
mutant "ajv verdict ignored (always pass)" 's|-d "\$ajv_data" 2>&1)"; then|-d "$ajv_data" 2>\&1)" \|\| true; then|'
mutant "ajv 'Unexpected' (unreadable) treated as pass" '/failed schema validation against \$schema (ajv)/i\
		case "$out" in *Unexpected*) return 0 ;; esac'
mutant "mktemp failure treated as pass" '/cannot create a temp dir/{n;s/return 6/return 0/;}'
mutant "temp dir never removed" 's|rm -rf "\$ajv_dir"|:|'

echo
echo "----------------------------------------"
echo "test-schema-validate-ajv-path.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
