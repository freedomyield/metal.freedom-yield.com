#!/usr/bin/env bash
# test-orchestrator-guard.sh — CI grep test proving the future cycle-
# transition orchestrator (scripts/cycle-transition.sh) never contains a
# literal broadcast-tool invocation string.
#
# WHY: docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md
# §5 ("broadcast を orchestrator に持たせない") specifies that orchestrator
# phase 4/5 print a fully-resolved command and STOP — the orchestrator
# itself must never call proton / cleos / bin/safe-broadcast, because an
# unattended script cannot obtain the Prime Directive's per-invocation
# operator authorization (docs/CONSTITUTION.md PRIME DIRECTIVE). The spec
# names the enforcement mechanism directly: "`proton` / `cleos` /
# `safe-broadcast` の文字列が orchestrator に存在しないことを CI の grep
# test で恒久保証する". This suite is that guarantee.
#
# scripts/cycle-transition.sh does not exist yet (as of this suite's
# addition) — it is a separate, not-yet-scheduled workstream. A test that
# silently reports green "because the target file isn't there" is exactly
# the failure class this repo spent 2026-08 eliminating (see git log:
# the 2026-08-10 roster-reconciliation fix, and the test-runner-truncation
# fix the day before this suite was added). So this suite:
#
#   1. Scans the REAL target path (scripts/cycle-transition.sh) if and when
#      it exists, and FAILS if `proton` / `cleos` / `safe-broadcast` appear
#      anywhere in it. If the file does not exist yet, that is reported as
#      an EXPLICIT "MISSING" case — never silently folded into a generic
#      PASS — so a reviewer can tell "not created yet" apart from "created
#      and verified clean" by reading the suite's own output.
#   2. Self-tests the SAME scan function against synthetic temp files
#      (never touching the real scripts/ directory) to prove it actually
#      discriminates missing / clean / forbidden content. This is the
#      mutation evidence that makes case 1's eventual FAIL — once the real
#      file exists with a violation — trustworthy, rather than a check that
#      has never been proven capable of firing. Both required mutations
#      (an empty orchestrator, and one containing a broadcast string) are
#      exercised below.
#
# Deliberately in scope of THIS file only: scripts/cycle-transition.sh.
# Existing phase-implementation scripts (scripts/preview-cycle-anchor-
# broadcast.sh, scripts/run-testnet-rehearsal.sh) legitimately contain
# "proton" many times over — printing the resolved command for the
# operator IS their job, and each already has its own test suite. The
# orchestrator's job per the spec is only to sequence phases and translate
# exit codes; the broadcast-command text lives in those phase scripts, not
# in the orchestrator that calls them.
#
# CHAIN: none — static text scan only, no chain reads, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (read-only; scans text, never
#                  executes anything found in the target).
#
# Usage:
#   bash tests/orchestrator-guard/test-orchestrator-guard.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ORCHESTRATOR="${REPO_ROOT}/scripts/cycle-transition.sh"

PASS=0
FAIL=0

pass() { printf 'PASS  %-70s%s\n' "$1" "${2:+ ($2)}"; PASS=$((PASS + 1)); }
fail_case() { printf 'FAIL  %-70s%s\n' "$1" "${2:+ ($2)}" >&2; FAIL=$((FAIL + 1)); }

# scan_target <path> -> prints exactly one of: MISSING | CLEAN | HIT:<line>
#
# Callers must key off the PRINTED WORD, not a bash exit status: "no file to
# scan" and "scanned, found nothing" both need to reach the caller as
# distinguishable outcomes (that is the whole point of this suite), and
# collapsing them onto a single 0/1 rc would silently re-introduce the
# "absent target reads as a vacuous pass" failure mode this suite exists to
# rule out.
scan_target() {
	local path="$1"
	if [ ! -f "$path" ]; then
		echo "MISSING"
		return
	fi
	local hit
	hit="$(grep -inE '(^|[^A-Za-z0-9_.-])(proton|cleos|safe-broadcast)([^A-Za-z0-9_.-]|$)' "$path" | head -1)"
	if [ -n "$hit" ]; then
		echo "HIT:${hit}"
	else
		echo "CLEAN"
	fi
}

# ============================================================
# Part 1: self-test the scanner against synthetic content in a scratch dir,
# so the real-target assertion in Part 2 is trustworthy evidence rather
# than a check that has never been proven capable of firing.
# ============================================================

TMPDIR_SELFTEST="$(mktemp -d -t orchestrator-guard-selftest.XXXXXX)"
cleanup() { rm -rf "$TMPDIR_SELFTEST"; }
trap cleanup EXIT

# 1a. Absent file -> MISSING (not CLEAN). Proves the function tells the two
# apart instead of treating "nothing to scan" as "scanned and safe".
ABSENT_PATH="${TMPDIR_SELFTEST}/does-not-exist.sh"
RESULT="$(scan_target "$ABSENT_PATH")"
if [ "$RESULT" = "MISSING" ]; then
	pass "scan_target: absent file -> MISSING (distinct from CLEAN)"
else
	fail_case "scan_target: absent file -> MISSING (distinct from CLEAN)" "got: $RESULT"
fi

# 1b. Mutation (required by task acceptance criteria): orchestrator created
# as an EMPTY file -> CLEAN.
EMPTY_PATH="${TMPDIR_SELFTEST}/empty-orchestrator.sh"
: > "$EMPTY_PATH"
RESULT="$(scan_target "$EMPTY_PATH")"
if [ "$RESULT" = "CLEAN" ]; then
	pass "scan_target: empty orchestrator file -> CLEAN"
else
	fail_case "scan_target: empty orchestrator file -> CLEAN" "got: $RESULT"
fi

# 1c. Benign print-and-stop content, no broadcast-tool literal -> CLEAN.
BENIGN_PATH="${TMPDIR_SELFTEST}/benign-orchestrator.sh"
cat > "$BENIGN_PATH" <<'EOF'
#!/usr/bin/env bash
echo "Phase 4: run the rehearsal script, then STOP."
echo "Phase 5: run the preview script, then STOP."
EOF
RESULT="$(scan_target "$BENIGN_PATH")"
if [ "$RESULT" = "CLEAN" ]; then
	pass "scan_target: benign print-and-stop content -> CLEAN"
else
	fail_case "scan_target: benign print-and-stop content -> CLEAN" "got: $RESULT"
fi

# 1d. Mutation (required by task acceptance criteria): content containing a
# broadcast string -> HIT. Case: literal `proton` invocation.
PROTON_PATH="${TMPDIR_SELFTEST}/proton-orchestrator.sh"
cat > "$PROTON_PATH" <<'EOF'
#!/usr/bin/env bash
proton transaction:push "$TX"
EOF
RESULT="$(scan_target "$PROTON_PATH")"
case "$RESULT" in
	HIT:*) pass "scan_target: 'proton transaction:push' content -> HIT (mutation caught)" ;;
	*) fail_case "scan_target: 'proton transaction:push' content -> HIT (mutation caught)" "got: $RESULT" ;;
esac

# 1e. Mutation: literal `cleos` invocation -> HIT.
CLEOS_PATH="${TMPDIR_SELFTEST}/cleos-orchestrator.sh"
cat > "$CLEOS_PATH" <<'EOF'
#!/usr/bin/env bash
cleos push action eosio.token transfer "$ARGS"
EOF
RESULT="$(scan_target "$CLEOS_PATH")"
case "$RESULT" in
	HIT:*) pass "scan_target: 'cleos push action' content -> HIT (mutation caught)" ;;
	*) fail_case "scan_target: 'cleos push action' content -> HIT (mutation caught)" "got: $RESULT" ;;
esac

# 1f. Mutation: content merely NAMING the sanctioned wrapper -> HIT. The
# orchestrator must not tell the operator to paste a safe-broadcast
# invocation either — per memory/feedback_no_operator_paste_execution.md
# the operator's only sanctioned manual actions are proton unlock/lock; any
# other command (including safe-broadcast) is AI's to run under per-
# invocation chat authorization, never the operator's to copy-paste from an
# orchestrator's stdout.
WRAPPER_PATH="${TMPDIR_SELFTEST}/wrapper-orchestrator.sh"
cat > "$WRAPPER_PATH" <<'EOF'
#!/usr/bin/env bash
echo "Now run: bin/safe-broadcast --chain mainnet-a ..."
EOF
RESULT="$(scan_target "$WRAPPER_PATH")"
case "$RESULT" in
	HIT:*) pass "scan_target: 'bin/safe-broadcast' mention -> HIT (mutation caught)" ;;
	*) fail_case "scan_target: 'bin/safe-broadcast' mention -> HIT (mutation caught)" "got: $RESULT" ;;
esac

# ============================================================
# Part 2: the real, enforced assertion against this repo's actual
# scripts/cycle-transition.sh. This is the check that gates CI — Part 1
# only proves it is capable of firing.
# ============================================================

REAL_RESULT="$(scan_target "$ORCHESTRATOR")"
case "$REAL_RESULT" in
	MISSING)
		# Explicit, visible, non-silent: the orchestrator has not been
		# created yet. Legitimate today — NOT a vacuous pass folded into
		# "clean". The moment scripts/cycle-transition.sh is committed,
		# this same assertion (unmodified) starts actually scanning it.
		pass "scripts/cycle-transition.sh: not yet created — nothing to scan (expected until it exists)"
		;;
	CLEAN)
		pass "scripts/cycle-transition.sh: exists and contains no proton/cleos/safe-broadcast literal"
		;;
	HIT:*)
		fail_case "scripts/cycle-transition.sh: contains a forbidden broadcast-tool literal" "${REAL_RESULT#HIT:}"
		;;
	*)
		fail_case "scripts/cycle-transition.sh: scan_target returned an unrecognized result" "$REAL_RESULT"
		;;
esac

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-orchestrator-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
