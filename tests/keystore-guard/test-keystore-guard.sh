#!/usr/bin/env bash
# test-keystore-guard.sh — regression suite for the §3.5 keystore separation
# guard (scripts/lib/require-keystore-home.sh) and its integration into the
# executable scripts that invoke proton-cli.
#
# Constitution §3.5 (docs/CONSTITUTION.md) prohibits using the default
# (shared) proton-cli keystore for this project. bin/safe-broadcast and
# scripts/sign-anchor-event.sh each already have dedicated suites
# (tests/safe-broadcast/, tests/sign-anchor-event/) that were extended in
# place with guard cases (they have hermetic proton stubs already). This
# suite covers what those two don't:
#   1. The shared guard FUNCTION in isolation (source + call directly).
#   2. scripts/run-testnet-rehearsal.sh and
#      scripts/preview-cycle3-anchor-broadcast.sh, which have no prior
#      automated test suite (preview-cycle3-anchor-broadcast.sh is
#      documented as "no automated test by design" since a full run
#      regenerates public/api/anchor-source.json). For these two, this
#      suite verifies ONLY:
#        (a) the REFUSE path (HOME=login home) — deterministic, zero side
#            effects, since the guard is the first thing either script does
#            (before any file write, before `cd`, before the first proton
#            call).
#        (b) that a non-login HOME passes THROUGH the guard to a later,
#            distinct failure — WITHOUT letting either script reach a real
#            side-effecting operation (gen-anchor-source.sh, a real
#            keystore read, etc.). See the per-case comments below for how
#            each pass-through case stays side-effect-free.
#
# CHAIN: none — no case in this suite invokes proton for real, reaches
#        bin/safe-broadcast's actual broadcast step, or writes to this
#        repo's tracked files (public/api/anchor-source.json is never
#        touched: the preview-cycle3 pass-through case deliberately leaves
#        $REPO unset so the script's own `cd "$REPO"` fails BEFORE
#        gen-anchor-source.sh would ever run).
#
# Usage:
#   bash tests/keystore-guard/test-keystore-guard.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/require-keystore-home.sh"
REHEARSAL_SCRIPT="${REPO_ROOT}/scripts/run-testnet-rehearsal.sh"
PREVIEW_SCRIPT="${REPO_ROOT}/scripts/preview-cycle3-anchor-broadcast.sh"

for f in "$LIB" "$REHEARSAL_SCRIPT" "$PREVIEW_SCRIPT"; do
	if [ ! -r "$f" ]; then
		echo "FATAL: expected file missing: $f" >&2
		exit 1
	fi
done

LOGIN_HOME="$(eval echo "~$(id -un)" 2>/dev/null || true)"
TEST_HOME="$(mktemp -d -t keystore-guard-home.XXXXXX)"

# Baseline the tracked anchor-source.json before any case runs, so Part 3
# can confirm the preview-cycle3-anchor-broadcast.sh pass-through case
# below truly never reached gen-anchor-source.sh (which would rewrite it).
ANCHOR_SRC="${REPO_ROOT}/public/api/anchor-source.json"
ANCHOR_SRC_SHA_BEFORE=""
if [ -r "$ANCHOR_SRC" ]; then
	ANCHOR_SRC_SHA_BEFORE="$(sha256sum "$ANCHOR_SRC" 2>/dev/null || shasum -a 256 "$ANCHOR_SRC" 2>/dev/null)"
fi

cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT

PASS=0
FAIL=0
SKIP=0

pass() { printf 'PASS  %-70s%s\n' "$1" "${2:+ ($2)}"; PASS=$((PASS + 1)); }
fail_case() { printf 'FAIL  %-70s%s\n' "$1" "${2:+ ($2)}" >&2; FAIL=$((FAIL + 1)); }
skip_case() { printf 'SKIP  %-70s%s\n' "$1" "${2:+ ($2)}"; SKIP=$((SKIP + 1)); }

# ============================================================
# Part 1: the shared guard function in isolation
# ============================================================

# 1a. Sourcing must not error and must define the function.
(
	set -u
	# shellcheck source=scripts/lib/require-keystore-home.sh
	. "$LIB"
	if declare -f require_project_keystore_home >/dev/null 2>&1; then
		exit 0
	fi
	exit 1
)
if [ "$?" -eq 0 ]; then
	pass "lib: sourcing defines require_project_keystore_home"
else
	fail_case "lib: sourcing defines require_project_keystore_home"
fi

if [ -n "$LOGIN_HOME" ]; then
	# 1b. HOME=login home → function returns 1 and prints a §3.5-citing
	# message to stderr (no broadcast, no side effect — pure function call).
	STDERR_OUT="$(
		set -u
		. "$LIB"
		HOME="$LOGIN_HOME" bash -c '. "'"$LIB"'"; require_project_keystore_home "unit-test"' 2>&1 1>/dev/null
		echo "RC=$?"
	)"
	RC="$(printf '%s' "$STDERR_OUT" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)"
	if [ "$RC" = "1" ] && printf '%s' "$STDERR_OUT" | grep -q '§3.5'; then
		pass "lib: HOME=login home → returns 1, message cites §3.5" "rc=$RC"
	else
		fail_case "lib: HOME=login home → returns 1, message cites §3.5" "rc=${RC:-?}"
	fi

	# 1c. Corrected-invocation examples are present (both mainnet + testnet
	# keystore paths), so an operator reading the error knows exactly what
	# to re-run.
	if printf '%s' "$STDERR_OUT" | grep -q 'HOME=~/.metal-fy-proton ' \
	   && printf '%s' "$STDERR_OUT" | grep -q 'HOME=~/.metal-fy-proton-test '; then
		pass "lib: refusal message shows both mainnet + testnet corrected examples"
	else
		fail_case "lib: refusal message shows both mainnet + testnet corrected examples"
	fi
else
	skip_case "lib: HOME=login home → returns 1" "login home not resolvable in this environment"
	skip_case "lib: refusal message shows corrected examples" "login home not resolvable in this environment"
fi

# 1d. HOME=project fixture dir (not the login home) → function returns 0,
# silent (no stderr output).
FIXTURE_STDERR="$(
	set -u
	HOME="$TEST_HOME" bash -c '. "'"$LIB"'"; require_project_keystore_home "unit-test"' 2>&1 1>/dev/null
	echo "RC=$?"
)"
FIXTURE_RC="$(printf '%s' "$FIXTURE_STDERR" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)"
FIXTURE_MSG="$(printf '%s' "$FIXTURE_STDERR" | grep -v '^RC=' || true)"
if [ "$FIXTURE_RC" = "0" ] && [ -z "$FIXTURE_MSG" ]; then
	pass "lib: HOME=project fixture dir → returns 0, silent"
else
	fail_case "lib: HOME=project fixture dir → returns 0, silent" "rc=${FIXTURE_RC:-?} msg=[${FIXTURE_MSG}]"
fi

# ============================================================
# Part 2: scripts/run-testnet-rehearsal.sh integration
# ============================================================

if [ -n "$LOGIN_HOME" ]; then
	# 2a. REFUSE path: guard is the very first thing this script does after
	# its helper-function definitions — before step 1 (`proton key:list`),
	# so this is deterministic and side-effect-free regardless of whether a
	# real proton binary or rehearsal config dir exists on this machine.
	RC=0
	OUT="$(HOME="$LOGIN_HOME" bash "$REHEARSAL_SCRIPT" </dev/null 2>&1)" || RC=$?
	if [ "$RC" -eq 8 ] && printf '%s' "$OUT" | grep -q '§3.5'; then
		pass "run-testnet-rehearsal.sh: HOME=login home → refuse (exit 8)" "rc=$RC"
	else
		fail_case "run-testnet-rehearsal.sh: HOME=login home → refuse (exit 8)" "rc=$RC"
	fi
else
	skip_case "run-testnet-rehearsal.sh: HOME=login home → refuse" "login home not resolvable"
fi

# 2b. PASS-THROUGH: HOME=project fixture dir (no real proton on PATH
# required — this script calls `proton key:list` directly without a
# pre-flight `command -v proton` check, so a missing binary just yields an
# empty key list via its own `|| echo '[]'` fallback). The script's step 1
# then fails closed on the first missing testnet pubkey (its OWN
# pre-existing `fail()` helper, exit 1) — a later, distinct failure from the
# guard's exit 8, reached with zero file writes.
RC=0
OUT="$(HOME="$TEST_HOME" bash "$REHEARSAL_SCRIPT" </dev/null 2>&1)" || RC=$?
if [ "$RC" -ne 8 ] && ! printf '%s' "$OUT" | grep -q 'keystore guard'; then
	pass "run-testnet-rehearsal.sh: HOME=project fixture dir → passes guard" "rc=$RC (not 8)"
else
	fail_case "run-testnet-rehearsal.sh: HOME=project fixture dir → passes guard" "rc=$RC"
fi

# ============================================================
# Part 3: scripts/preview-cycle3-anchor-broadcast.sh integration
# ============================================================

if [ -n "$LOGIN_HOME" ]; then
	# 3a. REFUSE path: guard runs before $REPO is even read, so `cd "$REPO"`
	# and gen-anchor-source.sh never execute — zero side effects on this
	# repo's tracked files.
	RC=0
	OUT="$(HOME="$LOGIN_HOME" bash "$PREVIEW_SCRIPT" </dev/null 2>&1)" || RC=$?
	if [ "$RC" -eq 8 ] && printf '%s' "$OUT" | grep -q '§3.5'; then
		pass "preview-cycle3-anchor-broadcast.sh: HOME=login home → refuse (exit 8)" "rc=$RC"
	else
		fail_case "preview-cycle3-anchor-broadcast.sh: HOME=login home → refuse (exit 8)" "rc=$RC"
	fi
else
	skip_case "preview-cycle3-anchor-broadcast.sh: HOME=login home → refuse" "login home not resolvable"
fi

# 3b. PASS-THROUGH: HOME=project fixture dir, $REPO deliberately left
# UNSET/default (/home/deploy/metal.freedom-yield.com, which does not exist
# on this machine) so `cd "$REPO"` fails immediately under `set -euo
# pipefail` — a later, distinct failure from the guard's exit 8 — WITHOUT
# ever reaching gen-anchor-source.sh (which would rewrite this repo's
# public/api/anchor-source.json). This intentionally does NOT prove the
# script's happy path works; it only proves the guard does not block a
# correctly-scoped HOME.
RC=0
OUT="$(HOME="$TEST_HOME" bash "$PREVIEW_SCRIPT" </dev/null 2>&1)" || RC=$?
if [ "$RC" -ne 8 ] && ! printf '%s' "$OUT" | grep -q 'keystore guard'; then
	pass "preview-cycle3-anchor-broadcast.sh: HOME=project fixture dir → passes guard" "rc=$RC (not 8)"
else
	fail_case "preview-cycle3-anchor-broadcast.sh: HOME=project fixture dir → passes guard" "rc=$RC"
fi

# Belt-and-suspenders: confirm no case above (in particular the
# preview-cycle3-anchor-broadcast.sh pass-through case, 3b) touched the
# real tracked public/api/anchor-source.json.
if [ -r "$ANCHOR_SRC" ]; then
	ANCHOR_SRC_SHA_AFTER="$(sha256sum "$ANCHOR_SRC" 2>/dev/null || shasum -a 256 "$ANCHOR_SRC" 2>/dev/null)"
	if [ "$ANCHOR_SRC_SHA_AFTER" = "$ANCHOR_SRC_SHA_BEFORE" ]; then
		pass "side-effect check: public/api/anchor-source.json unchanged by this suite"
	else
		fail_case "side-effect check: public/api/anchor-source.json unchanged by this suite" "sha256 changed!"
	fi
else
	skip_case "side-effect check: public/api/anchor-source.json unchanged by this suite" "file does not exist in this checkout"
fi

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-keystore-guard.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
