#!/usr/bin/env bash
# test-cron-filename-guard.sh — cross-file consistency suite for
# scripts/lib/cron-filename-guard.sh (is_cron_executed_filename()).
#
# CHAIN: none — every case either greps repo source (read-only) or operates
#        on a throwaway tmpdir copy. No /etc/cron.d path, real or
#        simulated, is touched.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction at all).
#
# WHY THIS SUITE EXISTS (2026-08-06, H3 task): is_cron_executed_filename()
# was defined identically in THREE places — scripts/lib/cron-filename-
# guard.sh, plus inline copies inside scripts/install-cron-env-headers.sh
# and scripts/install-repoint-publish-crons.sh. Each inline copy carried a
# comment claiming a "lock-step consistency check" in
# tests/install-cron-env-headers/ and tests/install-repoint-publish-crons/
# kept the two installer copies in sync. That test never existed — each
# suite only ran a self-contained mutation check against its OWN inline
# copy (see e.g. test-install-cron-env-headers.sh's case 19), which proves
# the guard logic works but proves nothing about the three definitions
# staying identical. Editing exactly one of the three would have gone
# undetected by every existing suite.
#
# The H3 fix is structural: both installers now source
# scripts/lib/cron-filename-guard.sh instead of defining the function
# themselves. This suite is what makes "exactly one definition" a tested
# invariant rather than a comment (case 4), proves that assertion is not a
# tautology (case 6, five separate mutation shapes), and is explicit about
# exactly how far the guarantee reaches (see "SCOPE OF THE GUARANTEE"
# below — case 7 tests the boundary itself, not just the happy path).
#
# REVISION (same day, post-review): the first version of this suite used
# `grep -l '^is_cron_executed_filename() {' --include='*.sh' "$REPO_ROOT"`
# — anchored at COLUMN 0 (no leading whitespace) and restricted to *.sh.
# An independent review found that pattern catches only ONE specific
# syntax shape and one extension, and demonstrated four ways to define the
# function that slip past it undetected: `function is_cron_executed_
# filename() {`, `is_cron_executed_filename () {` (space before the
# parens), the opening brace on its own line, and a definition in a file
# with no `.sh` extension (e.g. a hypothetical bin/ script). The review's
# point: a comment claiming "this is the ONLY definition in the repo" that
# is actually only true for one syntax shape and one extension is the same
# category of overclaim this whole task exists to remove. This revision
# fixes that two ways at once (independent review's recommended approach):
# (a) broadens DEF_PATTERN to catch all five shapes above, regardless of
#     extension, proven by mutation-testing each shape individually
#     (case 6a-6e);
# (b) narrows the SCOPE claim to what is actually checked — see below —
#     instead of leaving "repo-wide"/"the ONLY definition in the repo" as
#     an unqualified claim.
#
# SCOPE OF THE GUARANTEE (read this before trusting a green case 4):
#   Directories scanned: scripts/, .githooks/, bin/ — the three places this
#   repo actually ships executable code from (scripts/+.githooks/ is
#   .github/workflows/validate.yml's own shellcheck job scope; bin/ is
#   added here because bin/safe-broadcast is real shipped code with no
#   file extension at all, the exact "non-.sh" case the review raised).
#   tests/ and docs/ are OUT of scope for this scan, on purpose: three
#   existing, already-reviewed suites (tests/install-cron-env-headers/,
#   tests/install-repoint-publish-crons/, tests/install-cron-audit-markers/)
#   legitimately embed their OWN throwaway inline copy of this exact
#   function inside a `bash -c '...'` string for self-contained mutation
#   testing (their case 19 / T15 / case 16) — under the broadened
#   DEF_PATTERN below, those WOULD register as "definitions" if scanned.
#   Case 7 proves this deliberately: it shows the same pattern inside a
#   synthetic tests/ fixture is NOT counted by count_definitions when given
#   the real scan roots, and IS counted if the caller widens the scan roots
#   to include tests/ — i.e. the exclusion is a directory-scope decision
#   made once, here, not a per-shape coincidence the way "no leading
#   whitespace" was.
#   What this suite does NOT prove: that the string "is_cron_executed_
#   filename" cannot appear a second time ANYWHERE in the repository (it
#   appears throughout docs/comments/test-assertion messages by design),
#   or that no one could hide a definition inside e.g. docs/ prose that
#   later gets copy-pasted into shipping code — only that scripts/,
#   .githooks/, and bin/ as they exist right now carry exactly one.
#
# Usage:
#   bash tests/cron-filename-guard/test-cron-filename-guard.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/cron-filename-guard.sh"
ENV_HEADERS="${REPO_ROOT}/scripts/install-cron-env-headers.sh"
REPOINT="${REPO_ROOT}/scripts/install-repoint-publish-crons.sh"

for f in "$LIB" "$ENV_HEADERS" "$REPOINT"; do
	if [ ! -f "$f" ]; then
		echo "FATAL: expected file missing: $f" >&2
		exit 1
	fi
done

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# Matches a bash function DEFINITION of is_cron_executed_filename in any of
# five shapes, regardless of file extension:
#   is_cron_executed_filename() {          (the shape used today)
#   is_cron_executed_filename () {         (space before the parens)
#   is_cron_executed_filename()<newline>{  (brace on the next line — this
#                                           regex matches the first line;
#                                           it does not need to see the
#                                           brace at all)
#   function is_cron_executed_filename() {
#   function is_cron_executed_filename {   (function keyword, no parens)
#
# Anchored on trimmed-line-START (`^[[:space:]]*` then immediately either
# the `function` keyword or the bare name), not "appears anywhere in the
# line" — a CALL site is always `is_cron_executed_filename "$arg"` (no
# parens, no `function` keyword), and every comment/test-assertion mention
# in this repo ("# is_cron_executed_filename() sidecar guard", `ok "...
# defines is_cron_executed_filename()"`) starts with `#`/`ok`/`echo`/etc.,
# not with the name or `function` — so neither is mistaken for a
# definition. Verified empirically in case 2 (no false positive against
# this repo's own comments) and case 6f (a comment-only fixture does not
# match).
DEF_PATTERN='^[[:space:]]*(function[[:space:]]+is_cron_executed_filename\b|is_cron_executed_filename[[:space:]]*\([[:space:]]*\))'

# count_definitions <dir> [<dir> ...] — paths (one per line) whose files,
# ANY extension, contain a DEF_PATTERN match, restricted to whichever of
# the given directories actually exist (so callers can pass a partial tree,
# e.g. a mutation tmpdir that only has scripts/). See "SCOPE OF THE
# GUARANTEE" above for which directories case 4 passes.
count_definitions() {
	local d
	local existing=()
	for d in "$@"; do
		[ -d "$d" ] && existing+=("$d")
	done
	[ "${#existing[@]}" -eq 0 ] && return 0
	grep -rlE --binary-files=without-match "$DEF_PATTERN" "${existing[@]}" 2>/dev/null || true
}

count_files() {
	if [ -z "$1" ]; then
		printf '0'
	else
		printf '%s\n' "$1" | grep -c .
	fi
}

# ---- case 1: the shared lib defines the function -----------------------------
grep -qF 'is_cron_executed_filename() {' "$LIB" \
	&& ok "lib: scripts/lib/cron-filename-guard.sh defines is_cron_executed_filename()" \
	|| bad "lib: scripts/lib/cron-filename-guard.sh defines is_cron_executed_filename()"

# ---- case 2: neither installer defines it inline anymore (any of the 5 shapes)
grep -qE "$DEF_PATTERN" "$ENV_HEADERS" \
	&& bad "reuse: install-cron-env-headers.sh does NOT re-define is_cron_executed_filename() itself" \
	|| ok "reuse: install-cron-env-headers.sh does NOT re-define is_cron_executed_filename() itself"
grep -qE "$DEF_PATTERN" "$REPOINT" \
	&& bad "reuse: install-repoint-publish-crons.sh does NOT re-define is_cron_executed_filename() itself" \
	|| ok "reuse: install-repoint-publish-crons.sh does NOT re-define is_cron_executed_filename() itself"

# ---- case 3: both installers source the shared lib ----------------------------
grep -qE '^\s*\.\s+"\$\{SCRIPT_DIR\}/lib/cron-filename-guard\.sh"' "$ENV_HEADERS" \
	&& ok "reuse: install-cron-env-headers.sh sources the shared lib" \
	|| bad "reuse: install-cron-env-headers.sh sources the shared lib"
grep -qE '^\s*\.\s+"\$\{SCRIPT_DIR\}/lib/cron-filename-guard\.sh"' "$REPOINT" \
	&& ok "reuse: install-repoint-publish-crons.sh sources the shared lib" \
	|| bad "reuse: install-repoint-publish-crons.sh sources the shared lib"

# ---- case 4 (real SoT, real invariant): exactly ONE definition, in scope -----
# Scope = scripts/ + .githooks/ + bin/ (see "SCOPE OF THE GUARANTEE" above).
SCAN_ROOTS=("${REPO_ROOT}/scripts" "${REPO_ROOT}/.githooks" "${REPO_ROOT}/bin")
MATCHES="$(count_definitions "${SCAN_ROOTS[@]}")"
NUM_MATCHES="$(count_files "$MATCHES")"
if [ "$NUM_MATCHES" -eq 1 ]; then
	ok "SoT: is_cron_executed_filename() is defined in exactly 1 file across scripts/+.githooks/+bin/"
else
	bad "SoT: is_cron_executed_filename() is defined in exactly 1 file across scripts/+.githooks/+bin/ (found ${NUM_MATCHES}: $(printf '%s' "$MATCHES" | tr '\n' ' '))"
fi
if [ "$MATCHES" = "$LIB" ]; then
	ok "SoT: the one definition is scripts/lib/cron-filename-guard.sh"
else
	bad "SoT: the one definition is scripts/lib/cron-filename-guard.sh (found: $MATCHES)"
fi

# ---- case 5: the real, sourced lib rejects sidecar names, accepts a normal one
if bash -c ". '$LIB'
	is_cron_executed_filename 'metal-node-info.bak-20260101-000000' && exit 1
	is_cron_executed_filename 'metal-node-info.disabled' && exit 1
	is_cron_executed_filename 'metal-node-info.orig' && exit 1
	is_cron_executed_filename 'metal-node-info.dpkg-old' && exit 1
	is_cron_executed_filename 'metal-node-info~' && exit 1
	is_cron_executed_filename 'metal-node-info' || exit 1
	is_cron_executed_filename 'freedom-yield-peer-geo' || exit 1
	exit 0
"; then
	ok "guard: the real sourced lib rejects sidecar names, accepts normal ones"
else
	bad "guard: the real sourced lib rejects sidecar names, accepts normal ones"
fi

# ---- case 6 (mutation, 5 shapes): reintroducing a 2nd definition turns
# case 4 red, no matter which of the 5 syntax shapes it uses. Proves case 4
# is a real check, not a tautology, and that the broadened DEF_PATTERN
# actually broadened (not just re-added the one shape it already caught).
# Each mutation: copy the real scripts/lib + both installers into a fresh
# throwaway tmpdir, inject ONE shape into a copy of one installer (or a new
# extension-less file), rescan that tmpdir's scripts/ only, and require the
# count to flip from 1 to 2. Nothing under REPO_ROOT is touched.
MUTDIR="$(mktemp -d -t cron-filename-guard-mut.XXXXXX)"
cleanup() { rm -rf "$MUTDIR"; }
trap cleanup EXIT

reset_mutdir_scripts() {
	rm -rf "$MUTDIR/scripts"
	mkdir -p "$MUTDIR/scripts/lib"
	cp "$LIB" "$MUTDIR/scripts/lib/"
	cp "$ENV_HEADERS" "$MUTDIR/scripts/"
	cp "$REPOINT" "$MUTDIR/scripts/"
}

mutdir_count() {
	count_files "$(count_definitions "$MUTDIR/scripts")"
}

# control: unmutated copy must read 1 before every mutation case below.
reset_mutdir_scripts
if [ "$(mutdir_count)" -eq 1 ]; then
	ok "mutation control: unmutated tmpdir copy reads count 1 before injection"
else
	bad "mutation control: unmutated tmpdir copy reads count 1 before injection (actual: $(mutdir_count))"
fi

# 6a: same-line form (the shape the original grep already caught) — kept as
# a regression control so this revision cannot silently lose coverage the
# first version had.
reset_mutdir_scripts
{
	printf '\n'
	printf 'is_cron_executed_filename() {\n\tcase "$1" in\n\t\t*[!A-Za-z0-9_-]*) return 1 ;;\n\t\t*) return 0 ;;\n\tesac\n}\n'
} >> "$MUTDIR/scripts/install-cron-env-headers.sh"
[ "$(mutdir_count)" -eq 2 ] \
	&& ok "mutation 6a: same-line 'name() {' duplicate detected (1->2)" \
	|| bad "mutation 6a: same-line 'name() {' duplicate detected (actual: $(mutdir_count))"

# 6b: `function name() {`
reset_mutdir_scripts
{
	printf '\n'
	printf 'function is_cron_executed_filename() {\n\tcase "$1" in\n\t\t*[!A-Za-z0-9_-]*) return 1 ;;\n\t\t*) return 0 ;;\n\tesac\n}\n'
} >> "$MUTDIR/scripts/install-cron-env-headers.sh"
[ "$(mutdir_count)" -eq 2 ] \
	&& ok "mutation 6b: 'function name() {' duplicate detected (1->2)" \
	|| bad "mutation 6b: 'function name() {' duplicate detected (actual: $(mutdir_count))"

# 6c: space before the parens
reset_mutdir_scripts
{
	printf '\n'
	printf 'is_cron_executed_filename () {\n\tcase "$1" in\n\t\t*[!A-Za-z0-9_-]*) return 1 ;;\n\t\t*) return 0 ;;\n\tesac\n}\n'
} >> "$MUTDIR/scripts/install-cron-env-headers.sh"
[ "$(mutdir_count)" -eq 2 ] \
	&& ok "mutation 6c: space-before-parens 'name () {' duplicate detected (1->2)" \
	|| bad "mutation 6c: space-before-parens 'name () {' duplicate detected (actual: $(mutdir_count))"

# 6d: brace on the next line
reset_mutdir_scripts
{
	printf '\n'
	printf 'is_cron_executed_filename()\n{\n\tcase "$1" in\n\t\t*[!A-Za-z0-9_-]*) return 1 ;;\n\t\t*) return 0 ;;\n\tesac\n}\n'
} >> "$MUTDIR/scripts/install-cron-env-headers.sh"
[ "$(mutdir_count)" -eq 2 ] \
	&& ok "mutation 6d: brace-on-next-line duplicate detected (1->2)" \
	|| bad "mutation 6d: brace-on-next-line duplicate detected (actual: $(mutdir_count))"

# 6e: non-.sh extension (no extension at all, mirroring bin/safe-broadcast)
reset_mutdir_scripts
{
	printf 'is_cron_executed_filename() {\n\tcase "$1" in\n\t\t*[!A-Za-z0-9_-]*) return 1 ;;\n\t\t*) return 0 ;;\n\tesac\n}\n'
} > "$MUTDIR/scripts/cron-helper-noext"
[ "$(mutdir_count)" -eq 2 ] \
	&& ok "mutation 6e: definition in an extension-less file detected (1->2)" \
	|| bad "mutation 6e: definition in an extension-less file detected (actual: $(mutdir_count))"

# ---- case 7: the tests/ exclusion is a deliberate scope decision, verified
# both ways — NOT counted when scanning the real (scripts/.githooks/bin)
# roots, but the SAME fixture IS counted if a caller widens the scan to
# include tests/. This is what makes the "SCOPE OF THE GUARANTEE" comment
# above a tested claim instead of an assertion nobody checked.
rm -rf "$MUTDIR/scripts" "$MUTDIR/tests"
mkdir -p "$MUTDIR/scripts/lib" "$MUTDIR/tests/some-suite"
cp "$LIB" "$MUTDIR/scripts/lib/"
cp "$ENV_HEADERS" "$MUTDIR/scripts/"
cp "$REPOINT" "$MUTDIR/scripts/"
cat > "$MUTDIR/tests/some-suite/test-fixture.sh" <<'EOF'
# Synthetic stand-in for the real pattern used by
# tests/install-cron-env-headers/, tests/install-repoint-publish-crons/,
# and tests/install-cron-audit-markers/: a throwaway inline copy embedded
# in a bash -c string for self-contained mutation testing.
if bash -c '
	is_cron_executed_filename() {
		case "$1" in
			*[!A-Za-z0-9_-]*) return 1 ;;
			*) return 0 ;;
		esac
	}
	is_cron_executed_filename "x.bak-1" && exit 1
	exit 0
'; then echo ok; fi
EOF
IN_SCOPE="$(count_files "$(count_definitions "$MUTDIR/scripts")")"
WITH_TESTS="$(count_files "$(count_definitions "$MUTDIR/scripts" "$MUTDIR/tests")")"
if [ "$IN_SCOPE" -eq 1 ]; then
	ok "scope: a tests/-style throwaway inline copy is NOT counted when scanning scripts/ only"
else
	bad "scope: a tests/-style throwaway inline copy is NOT counted when scanning scripts/ only (actual: $IN_SCOPE)"
fi
if [ "$WITH_TESTS" -eq 2 ]; then
	ok "scope: the same fixture IS counted if the caller widens the scan to include tests/ (proves case 4 isn't silently blind, it's scoped on purpose)"
else
	bad "scope: the same fixture IS counted if the caller widens the scan to include tests/ (actual: $WITH_TESTS)"
fi

# ---- summary ------------------------------------------------------------------
echo "test-cron-filename-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
