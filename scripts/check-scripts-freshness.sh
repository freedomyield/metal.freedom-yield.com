#!/usr/bin/env bash
# check-scripts-freshness.sh — read-only fail-closed freshness checker.
#
# CHAIN: none — this script never broadcasts, pulls, resets, or edits
# anything. It only fetches origin/main and compares commit counts.
#
# Motivation: broadcast-critical pipelines (anchor generation, cycle-gate,
# etc.) must never run against a checkout that is behind origin/main — a
# stale checkout can carry an already-fixed bug or a stale anchor-source
# value forward into a live broadcast. This script is the read-only library
# check other scripts call before proceeding; it does not decide policy and
# it does not alert — the CALLER owns what to do with a stale/undetermined
# verdict (see scripts/check-host-drift.sh's cron-based alerting for the
# passive/periodic side of this, and Task 4's anchor-pipeline wiring for the
# active/fail-closed side).
#
# What it does (read-only; NEVER pulls, resets, checks out, or edits
# anything):
#   1. git fetch origin main (quiet)
#   2. behind count — commits on origin/main not yet in local HEAD
#
# Usage:
#   bash scripts/check-scripts-freshness.sh
#
# Env overrides:
#   FYD_REPO_DIR   repo checkout to inspect (default: this script's repo root)
#
# Exit codes:
#   0  fresh: local HEAD == origin/main (stdout: "fresh: HEAD == origin/main")
#   1  stale: local HEAD is behind origin/main (stderr: STALE message with count)
#   3  fetch failed — freshness could not be determined (stderr: error message)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${FYD_REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

if ! git -C "$REPO_DIR" fetch --quiet origin main 2>/dev/null; then
	echo "ERROR: git fetch origin main failed in $REPO_DIR — cannot determine freshness" >&2
	exit 3
fi

BEHIND="$(git -C "$REPO_DIR" rev-list --count HEAD..origin/main)"

if [ "$BEHIND" -gt 0 ]; then
	echo "STALE: local HEAD is ${BEHIND} commit(s) behind origin/main; run advance-host-checkout.sh before proceeding" >&2
	exit 1
fi

echo "fresh: HEAD == origin/main"
exit 0
