#!/usr/bin/env bash
# test-cron-filename-guard.sh — cross-file consistency suite for
# scripts/lib/cron-filename-guard.sh (is_cron_executed_filename()).
#
# CHAIN: none — every case either greps repo source, sources the lib in a
#        subshell, or operates on a throwaway tmpdir copy of scripts/. No
#        /etc/cron.d path, real or simulated, is touched.
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
# themselves, so there is exactly one definition, period — no convention to
# maintain. This suite is what makes that a tested invariant rather than a
# comment: it asserts the repo-wide definition count is 1 (case 3), and
# proves that assertion is not a tautology by actually reintroducing a
# second definition into a throwaway copy of scripts/ and watching the
# check turn red (case 5).
#
# Per-file mutation coverage for the GUARD'S OWN LOGIC (does it correctly
# reject sidecar names / accept normal ones) already exists and stays as-is
# in tests/install-cron-env-headers/, tests/install-repoint-publish-crons/,
# and tests/install-cron-audit-markers/ — not duplicated at length here.
# Case 4 below re-confirms it once, directly against the real sourced lib
# (not a self-contained inline copy), since that combination — "the actual
# SoT, sourced the way production sources it" — was not exercised by any
# existing suite before this one.
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

# Anchored at column 0 (no leading whitespace) on purpose: the per-file
# mutation tests in tests/install-cron-env-headers/,
# tests/install-repoint-publish-crons/, and tests/install-cron-audit-markers/
# each embed an INDENTED copy of this same case pattern inside a `bash -c`
# string for their own isolated mutation checks — those are deliberate,
# throwaway, single-suite copies, not a fourth production definition, and
# must NOT be flagged by this check. Anchoring on "no leading whitespace"
# is what tells the two apart: a real top-level function definition in a
# .sh file is never indented, while every existing inline-mutation copy
# lives inside an indented heredoc/`bash -c` block.
DEF_PATTERN='^is_cron_executed_filename() {'

# repo-wide count_definitions <dir> — paths (one per line) under <dir> whose
# *.sh files contain a column-0 is_cron_executed_filename() definition.
count_definitions() {
	grep -rl "$DEF_PATTERN" --include='*.sh' "$1" 2>/dev/null || true
}

# ---- case 1: the shared lib defines the function -----------------------------
grep -qF 'is_cron_executed_filename() {' "$LIB" \
	&& ok "lib: scripts/lib/cron-filename-guard.sh defines is_cron_executed_filename()" \
	|| bad "lib: scripts/lib/cron-filename-guard.sh defines is_cron_executed_filename()"

# ---- case 2: neither installer defines it inline anymore ---------------------
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

# ---- case 4 (real SoT, real invariant): exactly ONE definition repo-wide -----
MATCHES="$(count_definitions "$REPO_ROOT")"
NUM_MATCHES=0
[ -n "$MATCHES" ] && NUM_MATCHES="$(printf '%s\n' "$MATCHES" | grep -c .)"
if [ "$NUM_MATCHES" -eq 1 ]; then
	ok "SoT: is_cron_executed_filename() is defined in exactly 1 file repo-wide"
else
	bad "SoT: is_cron_executed_filename() is defined in exactly 1 file repo-wide (found ${NUM_MATCHES}: $(printf '%s' "$MATCHES" | tr '\n' ' '))"
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

# ---- case 6 (mutation): reintroducing a 2nd definition turns case 4 red ------
# Proves case 4 is a real check, not a tautology: copy scripts/ into a
# throwaway tmpdir, append a second (functionally identical) definition to
# a COPY of one installer, and confirm the same repo-wide count check now
# reports 2, not 1. Nothing under REPO_ROOT is touched.
MUTDIR="$(mktemp -d -t cron-filename-guard-mut.XXXXXX)"
cleanup() { rm -rf "$MUTDIR"; }
trap cleanup EXIT

mkdir -p "$MUTDIR/scripts/lib"
cp "$LIB" "$MUTDIR/scripts/lib/"
cp "$ENV_HEADERS" "$MUTDIR/scripts/"
cp "$REPOINT" "$MUTDIR/scripts/"
{
	printf '\n'
	printf 'is_cron_executed_filename() {\n'
	printf '\tcase "$1" in\n'
	printf '\t\t*[!A-Za-z0-9_-]*) return 1 ;;\n'
	printf '\t\t*) return 0 ;;\n'
	printf '\tesac\n'
	printf '}\n'
} >> "$MUTDIR/scripts/install-cron-env-headers.sh"

MUT_MATCHES="$(count_definitions "$MUTDIR")"
MUT_NUM=0
[ -n "$MUT_MATCHES" ] && MUT_NUM="$(printf '%s\n' "$MUT_MATCHES" | grep -c .)"
if [ "$MUT_NUM" -eq 2 ]; then
	ok "mutation: reintroducing a 2nd definition flips the repo-wide count from 1 to 2 (detected)"
else
	bad "mutation: reintroducing a 2nd definition flips the repo-wide count from 1 to 2 (actual count: ${MUT_NUM})"
fi

# unmutated control, same tmpdir tree minus the injected copy, must still read 1
rm -rf "$MUTDIR/scripts"
mkdir -p "$MUTDIR/scripts/lib"
cp "$LIB" "$MUTDIR/scripts/lib/"
cp "$ENV_HEADERS" "$MUTDIR/scripts/"
cp "$REPOINT" "$MUTDIR/scripts/"
CONTROL_MATCHES="$(count_definitions "$MUTDIR")"
CONTROL_NUM=0
[ -n "$CONTROL_MATCHES" ] && CONTROL_NUM="$(printf '%s\n' "$CONTROL_MATCHES" | grep -c .)"
if [ "$CONTROL_NUM" -eq 1 ]; then
	ok "mutation: control copy (no injected duplicate) still reads count 1"
else
	bad "mutation: control copy (no injected duplicate) still reads count 1 (actual: ${CONTROL_NUM})"
fi

# ---- summary ------------------------------------------------------------------
echo "test-cron-filename-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
