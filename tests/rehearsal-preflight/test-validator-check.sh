#!/usr/bin/env bash
# test-validator-check.sh — check 11 of scripts/install-rehearsal-preflight.sh
# (a JSON-schema validator is available: ajv, or python3 that can import
# jsonschema). Added after the 2026-11-01 nightly upgrade moved python3 to a
# version without jsonschema and the loss surfaced only on transition day.
#
# CHAIN: none. Every case runs the pre-flight on a synthetic PATH whose first
#        entry holds stub python3/ajv/timeout/proton/curl; every published-
#        artifact URL points at a nonexistent LOCAL path, so no case does any
#        network I/O. The suite asserts only on the "[11]" line, so it does not
#        depend on checks 1-10 being green.
#
# Cases: (a) python3 cannot import, no ajv      -> FAIL [11] + fix hint
#        (b) python3 can import                 -> PASS [11]
#        (b2) ajv present, python3 cannot import -> PASS [11]
#        (a2) python3 errors in another way     -> FAIL [11] (fail-closed)
#        (c) mutant: check 11 always passes     -> case (a) must catch it
#
# Usage: bash tests/rehearsal-preflight/test-validator-check.sh
# Exit: 0 all PASS, 1 any FAIL

set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFLIGHT_REL="scripts/install-rehearsal-preflight.sh"

# shellcheck source=../lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh"
pass() { t_pass "$1"; }
bad()  { t_fail "$1${2:+ ($2)}"; }

BASE="$(mktemp -d -t fya-validator-check.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT

# mk_stubs <dir> <python3 mode: ok|noimport|broken|none> <ajv: yes|no>
mk_stubs() {
	local d="$1" py="$2" ajv="$3"
	mkdir -p "$d"
	printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$d/timeout"
	printf '#!/usr/bin/env bash\nexit 90\n' > "$d/proton"
	printf '#!/usr/bin/env bash\nexit 7\n' > "$d/curl-stub"
	case "$py" in
		ok)       printf '#!/usr/bin/env bash\nexit 0\n' > "$d/python3" ;;
		noimport) printf '#!/usr/bin/env bash\necho "ModuleNotFoundError: No module named jsonschema" >&2\nexit 1\n' > "$d/python3" ;;
		broken)   printf '#!/usr/bin/env bash\nexit 139\n' > "$d/python3" ;;
		none)     : ;;
	esac
	if [ "$ajv" = "yes" ]; then printf '#!/usr/bin/env bash\nexit 0\n' > "$d/ajv"; fi
	chmod +x "$d"/*
}

# run_pf <script-path> <stub-dir> — prints the whole output. HOME and the
# keystore overrides point at one empty dir so the §3.5 guard passes.
run_pf() {
	local script="$1" stubs="$2" ks="${BASE}/ks"
	mkdir -p "$ks" "${BASE}/cfg"
	env PATH="${stubs}:/usr/bin:/bin:/usr/sbin:/sbin" \
		HOME="$ks" \
		FYP_KEYSTORE_TESTNET="$ks" FYP_KEYSTORE_MAINNET="${BASE}/ks-main" \
		FYP_REHEARSAL_CFG="${BASE}/cfg" FYP_MAINNET_CFG="${BASE}/cfg" \
		FYP_IDENTITY_KEY="${BASE}/none" FYP_PQ_KEY_DIR="${BASE}/none" FYP_PQ_PUB="${BASE}/none" \
		FYP_LEDGER_URL="${BASE}/none" FYP_ANCHOR_SOURCE_URL="${BASE}/none" \
		FYP_ANCHOR_HISTORY_URL="${BASE}/none" FYP_VALIDATOR_URL="${BASE}/none" \
		FYP_CURL="${stubs}/curl-stub" \
		bash "$script" --expect-cycle=1 --source="${BASE}/none" </dev/null 2>&1
}

assert_fail11() { # <label> <script> <stub-dir>
	local out
	out="$(run_pf "$2" "$3")"
	if printf '%s' "$out" | grep -q '^  FAIL  \[11\]' \
	   && ! printf '%s' "$out" | grep -q '^  PASS  \[11\]' \
	   && printf '%s' "$out" | grep -qF 'SETUP_VALIDATOR_PREFER=python bash scripts/setup-schema-validator.sh'; then
		pass "$1"
	else
		bad "$1" "$(printf '%s' "$out" | grep -E '\[11\]' | tr '\n' ' ' | cut -c1-120)"
		return 1
	fi
}
assert_pass11() { # <label> <script> <stub-dir>
	local out
	out="$(run_pf "$2" "$3")"
	if printf '%s' "$out" | grep -q '^  PASS  \[11\]' && ! printf '%s' "$out" | grep -q '^  FAIL  \[11\]'; then
		pass "$1"
	else
		bad "$1" "$(printf '%s' "$out" | grep -E '\[11\]' | tr '\n' ' ' | cut -c1-120)"
		return 1
	fi
}

REAL="${REPO_ROOT}/${PREFLIGHT_REL}"
mk_stubs "${BASE}/s-noimport" noimport no
mk_stubs "${BASE}/s-ok"       ok       no
mk_stubs "${BASE}/s-ajv"      noimport yes
mk_stubs "${BASE}/s-broken"   broken   no

assert_fail11 "(a)  python3 cannot import jsonschema, no ajv -> FAIL [11] with fix line" "$REAL" "${BASE}/s-noimport"
assert_pass11 "(b)  python3 can import jsonschema            -> PASS [11]"              "$REAL" "${BASE}/s-ok"
assert_pass11 "(b2) ajv present (python3 cannot import)      -> PASS [11]"              "$REAL" "${BASE}/s-ajv"
assert_fail11 "(a2) python3 dies abnormally, no ajv           -> FAIL [11] (fail-closed)" "$REAL" "${BASE}/s-broken"

# (c) mutant: a copy of the pre-flight whose check 11 failure branch is turned
# into a pass. Run in a mirror tree (REPO_ROOT is derived from the script path;
# every other file is symlinked to the real one). Case (a) MUST fail on it.
MUT="${BASE}/mut"
mkdir -p "${MUT}/scripts"
for e in "${REPO_ROOT}"/*; do
	[ "$(basename "$e")" = "scripts" ] || ln -s "$e" "${MUT}/$(basename "$e")"
done
for e in "${REPO_ROOT}"/scripts/*; do
	[ "$(basename "$e")" = "install-rehearsal-preflight.sh" ] || ln -s "$e" "${MUT}/scripts/$(basename "$e")"
done
sed 's/^\tchk_fail 11 2 .*/\tchk_pass 11 "mutant: always pass" \\/' "$REAL" > "${MUT}/${PREFLIGHT_REL}"
if cmp -s "$REAL" "${MUT}/${PREFLIGHT_REL}"; then
	bad "(c)  mutant was not applied (sed matched nothing)"
elif ( assert_fail11 "mutant-probe" "${MUT}/${PREFLIGHT_REL}" "${BASE}/s-noimport" ) >/dev/null 2>&1; then
	bad "(c)  mutant 'check 11 always passes' was NOT caught by case (a)"
else
	pass "(c)  mutant 'check 11 always passes' is caught (case (a) fails on it)"
fi

t_summary validator-check
