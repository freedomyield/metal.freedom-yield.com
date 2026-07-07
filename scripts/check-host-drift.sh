#!/usr/bin/env bash
# check-host-drift.sh — daily detector for validator-host checkout drift
# against origin/main.
#
# Motivation: on 2026-07-06 the validator-host checkout was found 205 commits
# ahead / 258 behind origin on an orphaned lineage — the 2026-07-03 repo
# re-creation (history rewrite) was never followed by a re-clone, and nothing
# watched for the divergence. After the reconcile (reset --hard origin/main,
# FF-only discipline) this script is the tripwire that keeps the problem from
# rebuilding silently.
#
# What it checks (read-only; NEVER pulls, resets, or edits anything):
#   1. fetch origin/main (quiet)
#   2. ahead count  — local commits origin does not have (should be 0:
#      the host is a deploy target, never an author)
#   3. behind count — origin commits not yet pulled (informational; alert
#      only past a threshold, since "push then pull later" is normal)
#   4. content drift in the code zones (scripts/ docs/ tests/ deploy/) —
#      working-tree files differing from the local HEAD (uncommitted edits
#      to tracked files) plus non-hidden untracked additions. Measured
#      against HEAD, not origin/main, so merely being behind is never
#      miscounted as drift. public/ is EXCLUDED by design: deploy stamps
#      cache-busters (?v=<commit>) into HTML and runtime feeds live there,
#      so public/ diffs are structural, not drift. Hidden paths (dot-dirs
#      like scripts/.retired-*) are installer backups, also excluded.
#
# On any alert condition, fires one ntfy push via notify.sh and exits 1
# (so cron logging shows the failure too). Healthy runs log one line, exit 0.
# A fetch failure alerts at default priority and exits 2 (could be transient
# network; the next tick retries).
#
# Usage:
#   bash scripts/check-host-drift.sh
#
# Env overrides (test-time + ops):
#   FYD_REPO_DIR        repo checkout to inspect (default: this script's repo)
#   FYD_NOTIFY          notifier to invoke (default: <script dir>/notify.sh)
#   FYD_BEHIND_MAX      alert when behind-count exceeds this (default 10)
#   FYD_DRIFT_PATHS     space-separated code zones (default "scripts docs tests deploy")
#
# Exit codes:
#   0  in sync (or behind within threshold)
#   1  drift detected (ahead commits / code-zone content drift / behind > max)
#   2  fetch failed
#
# Cron: daily via /etc/cron.d/metal-host-drift (see
#       scripts/install-metal-host-drift-cron.sh).

# No `-e`: the drift logic deliberately leans on non-zero exits as data —
# `[ cond ] && VAR=…` idioms (DRIFT_COUNT, PROBLEMS) evaluate false on the
# HEALTHY path, and grep-with-no-match / `git … || echo '?'` are expected
# non-zero. Under `set -e` any of these would abort the script mid-check.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${FYD_REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
NOTIFY="${FYD_NOTIFY:-${SCRIPT_DIR}/notify.sh}"
BEHIND_MAX="${FYD_BEHIND_MAX:-10}"
DRIFT_PATHS="${FYD_DRIFT_PATHS:-scripts docs tests deploy}"

log() { printf '[check-host-drift] %s\n' "$*"; }

alert() {
	# alert <priority> <title> <message>
	if [ -x "$NOTIFY" ] || [ -f "$NOTIFY" ]; then
		bash "$NOTIFY" "$1" "$2" "$3" || log "WARN: notify failed (alert was: $2 — $3)"
	else
		log "WARN: notifier not found at $NOTIFY (alert was: $2 — $3)"
	fi
}

if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	log "ERROR: not a git checkout: $REPO_DIR"
	exit 2
fi

if ! git -C "$REPO_DIR" fetch --quiet origin main 2>/dev/null; then
	log "ERROR: git fetch origin main failed"
	alert default "host-drift: fetch failed" "git fetch origin main failed on the validator host; next tick retries."
	exit 2
fi

AHEAD="$(git -C "$REPO_DIR" rev-list --count origin/main..HEAD 2>/dev/null || echo '?')"
BEHIND="$(git -C "$REPO_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo '?')"

# Content drift limited to the code zones, measured against the LOCAL HEAD:
# uncommitted edits to tracked files + non-hidden untracked additions.
# (Being behind origin is handled by the behind counter, not counted here.)
# Note: the hidden-path filter below applies to UNTRACKED entries only — a
# tracked, modified file under a dot-dir is still caught by the HEAD diff.
# That asymmetry is deliberate: .retired-* installer backups are untracked
# by nature, while anything tracked is code and must stay watched.
# shellcheck disable=SC2086
TRACKED_DRIFT="$(git -C "$REPO_DIR" diff HEAD --name-only -- $DRIFT_PATHS 2>/dev/null || true)"
# shellcheck disable=SC2086
UNTRACKED_DRIFT="$(git -C "$REPO_DIR" status --porcelain -- $DRIFT_PATHS 2>/dev/null \
	| awk '$1 == "??" {print $2}' | grep -vE '(^|/)\.' || true)"
DRIFT_FILES="$(printf '%s\n%s\n' "$TRACKED_DRIFT" "$UNTRACKED_DRIFT" | grep -v '^$' || true)"
DRIFT_COUNT=0
[ -n "$DRIFT_FILES" ] && DRIFT_COUNT="$(printf '%s\n' "$DRIFT_FILES" | wc -l | tr -d ' ')"

PROBLEMS=""
[ "$AHEAD" != "0" ] && PROBLEMS="ahead=${AHEAD}"
[ "$DRIFT_COUNT" != "0" ] && PROBLEMS="${PROBLEMS:+$PROBLEMS }code-drift=${DRIFT_COUNT}"
if [ "$BEHIND" != "0" ] && [ "$BEHIND" -gt "$BEHIND_MAX" ] 2>/dev/null; then
	PROBLEMS="${PROBLEMS:+$PROBLEMS }behind=${BEHIND}(>${BEHIND_MAX})"
fi

if [ -z "$PROBLEMS" ]; then
	log "in sync: ahead=${AHEAD} behind=${BEHIND} code-drift=0"
	exit 0
fi

DETAIL="${PROBLEMS} (ahead=${AHEAD} behind=${BEHIND} code-drift=${DRIFT_COUNT})"
if [ "$DRIFT_COUNT" != "0" ]; then
	FIRST_FILES="$(printf '%s\n' "$DRIFT_FILES" | head -5 | tr '\n' ' ')"
	DETAIL="${DETAIL} files: ${FIRST_FILES}"
fi
log "DRIFT: ${DETAIL}"
alert high "host-drift: checkout diverging" "${DETAIL}— host must stay a clean FF-only mirror of origin/main; do not edit on the host."
exit 1
