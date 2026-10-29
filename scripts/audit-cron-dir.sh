#!/usr/bin/env bash
# audit-cron-dir.sh — assert "check-cron-file.sh lint exit 0" across every
# project cron file in a directory, in one command.
#
# Motivation (2026-08-06, H2 task): the design spec (docs/superpowers/specs/
# 2026-08-06-single-source-of-truth-design.md §8) wants check-cron-file.sh's
# exit code usable as a binary merge/deploy/reconciler signal. Getting there
# needed two fixes (the generators in scripts/vps-bootstrap.sh and the
# scripts/install-*-cron.sh family; the already-deployed files via
# scripts/install-cron-audit-markers.sh + scripts/install-cron-env-headers.sh)
# and one assertion tool: something that answers "is EVERY project cron file
# in this directory lint-clean right now", not just one file at a time. This
# script is that tool. It never writes anything — pure read/report.
#
# Read-only, no root required. Reads only; never touches /etc/cron.d.
#
# Usage:
#   bash scripts/audit-cron-dir.sh [<cron-dir>]     # default: /etc/cron.d
#
# Intended call sites (placement decision — see the H2 task report for the
# full reasoning):
#   1. Coordinator-run, manually, immediately after applying
#      install-cron-audit-markers.sh / install-cron-env-headers.sh on the
#      validator host, as the direct pre/post remediation comparison this
#      command was written for.
#   2. A future daily reconciler (docs/superpowers/specs/
#      2026-08-06-single-source-of-truth-design.md §8 already anticipates
#      one for registry drift) can shell out to this script as one more
#      check — not wired in here, since that reconciler does not exist yet
#      and standing up/installing a NEW production cron is outside this
#      task's "never touch the host" constraint.
#   3. tests/cron-generators-lint/ covers the REPO side (generator output)
#      on every test run already; this script is the PRODUCTION side,
#      which a repo-only test suite structurally cannot reach (7 of the 15
#      live cron files have no repo installer at all).
#
# Exit codes:
#   0  every scanned file is lint-clean (or no files matched)
#   1  at least one scanned file has a lint violation
#   2  usage error / checker missing

set -euo pipefail

CRON_DIR="${1:-/etc/cron.d}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="${FYD_CRON_CHECKER:-${SCRIPT_DIR}/check-cron-file.sh}"

if [ ! -x "$CHECKER" ]; then
	echo "ERROR: check-cron-file.sh not found/executable at $CHECKER" >&2
	exit 2
fi

# shellcheck source=SCRIPTDIR/lib/cron-filename-guard.sh
. "${SCRIPT_DIR}/lib/cron-filename-guard.sh"

TOTAL=0
CLEAN=0
DIRTY=0
DIRTY_FILES=()
SKIPPED_NOT_CRON=0

for f in "$CRON_DIR"/metal-* "$CRON_DIR"/freedom-yield-*; do
	[ -f "$f" ] || continue
	bn="$(basename "$f")"

	if ! is_cron_executed_filename "$bn"; then
		SKIPPED_NOT_CRON=$((SKIPPED_NOT_CRON + 1))
		echo "skipped (not a cron-executed filename): $bn"
		continue
	fi

	TOTAL=$((TOTAL + 1))
	if bash "$CHECKER" "$f" >/dev/null 2>&1; then
		CLEAN=$((CLEAN + 1))
		echo "clean: $bn"
	else
		DIRTY=$((DIRTY + 1))
		DIRTY_FILES+=("$bn")
		echo "VIOLATIONS: $bn (run: bash ${CHECKER} $f)"
	fi
done

echo ""
echo "summary: ${TOTAL} scanned, ${CLEAN} clean, ${DIRTY} with violations, ${SKIPPED_NOT_CRON} skipped (not cron-executed)"
if [ "$DIRTY" -gt 0 ]; then
	echo "still violating: ${DIRTY_FILES[*]}"
	exit 1
fi
exit 0
