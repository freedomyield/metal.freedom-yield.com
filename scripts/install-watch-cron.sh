#!/usr/bin/env bash
# install-watch-cron.sh — install /etc/cron.d/metal-watch-validators, the
# schedule for scripts/check-watch-validators.sh.
#
# Why this exists: the cron file was previously host-only (never tracked in
# the repo — same orphan class as the 2026-07-04 publish-cron naming split)
# and ran `0 */4 * * *` UTC, which lands two of six daily ticks at
# 01:00/05:00 JST. The watch monitor is slow-moving third-party
# intelligence, never urgent, so the schedule is JST-daytime only:
#
#   0 0,4,8,12 * * * UTC  =  09:00 / 13:00 / 17:00 / 21:00 JST
#
# (2026-07-07 rework after four "departed" pushes landed at 01:00 JST.)
#
# 2026-07-08: the generated cron redirected straight to /var/log/check-watch.log
# — the same class of failure that caused the 2026-06-19 metal-evidence incident
# (deploy user cannot create files under /var/log/). Reworked to the
# project-local logs/ pattern documented in docs/CRON_CONVENTIONS.md: the
# command chain is brace-wrapped so the redirect covers every command, start/end
# markers + rc=$? capture make each run auditable, and the log target is under
# the repo's own logs/ dir (deploy:deploy owned). The generated file is linted
# with check-cron-file.sh before every install — a lint failure aborts the
# install instead of writing a non-compliant cron.
#
# 2026-08-06: env header now also carries FY_LIVE=1. scripts/lib/side-effects.sh
# (the C3 rollout) gates the production side effects that route THROUGH it —
# a fyd_notify-wrapped ntfy push, a /var/lib/freedom-yield state write — behind
# FY_LIVE=1; anything else is a loud dry no-op. check-watch-validators.sh
# routes its push through the library's fyd_notify and its WATCH_STATE_DIR
# writes through fyd_live_* (measured 2026-08-17: 1 fyd_notify call site,
# 5 fyd_live_*/fyd_state_dir), so without the flag on this cron both go dry.
# Enforced by check-cron-file.sh Rule 6.
#
# Idempotent: identical content → no change. A differing existing file is
# backed up OUTSIDE cron.d — under ${FYD_BACKUP_DIR:-/var/backups/metal-cron}
# as <name>.bak-<UTC ts> — because a *.bak sidecar left in /etc/cron.d is
# clutter at best and a stray executable cron at worst (mirrors the
# out-of-cron.d backup discipline of install-repoint-publish-crons.sh).
# File mode 0644 root (cron.d requirement).
#
# Usage (validator host, as root):
#   sudo bash scripts/install-watch-cron.sh [--dry-run]
#
# Env overrides (test-time):
#   FYD_CRON_FILE   target path (default /etc/cron.d/metal-watch-validators).
#                   When overridden, the root requirement and root ownership
#                   are waived (test harness mode).
#   FYD_REPO_DIR    repo checkout on the host — also where logs/check-watch.log
#                   is created (default /home/deploy/metal.freedom-yield.com)
#   FYD_BACKUP_DIR  where a differing prior cron is backed up, OUTSIDE
#                   cron.d (default /var/backups/metal-cron)
#   FYD_CRON_CHECKER  path to check-cron-file.sh used for the pre-flight lint
#                   (default: the copy next to this script). Test-only knob.
#
# Exit codes:
#   0  installed / already up to date / dry-run
#   1  usage error
#   2  not root (and FYD_CRON_FILE not overridden)
#   3  generated cron file failed the check-cron-file.sh pre-flight lint

set -euo pipefail

CRON_FILE="${FYD_CRON_FILE:-/etc/cron.d/metal-watch-validators}"
REPO_DIR="${FYD_REPO_DIR:-/home/deploy/metal.freedom-yield.com}"
# Backups live OUTSIDE cron.d so a *.bak sidecar never sits in /etc/cron.d.
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups/metal-cron}"

DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		-h|--help) sed -n '2,45p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)         echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if [ "$CRON_FILE" = "/etc/cron.d/metal-watch-validators" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: must run as root to write ${CRON_FILE} (usage: sudo bash $0)" >&2
	exit 2
fi

CONTENT="$(cat <<EOF
# Watch monitor for the private host-local validator list
# (/etc/freedom-yield/watch-list.json, installed by install-watch-list.sh).
# One batched min/low-priority ntfy per run — intelligence, not alerts.
#
# Schedule is JST-daytime only: 0,4,8,12 UTC = 09/13/17/21 JST. Do NOT
# widen back to */4 — that lands ticks at 01:00/05:00 JST and this feed
# never justifies waking the operator (2026-07-07 incident).
#
# Log path is project-local (logs/), not /var/log/ — see docs/CRON_CONVENTIONS.md.
# The chain is brace-wrapped with start/end markers + rc capture (rules 1-3 of
# that doc) and this file is linted by check-cron-file.sh before every install.
#
# Managed by scripts/install-watch-cron.sh — edit there, not here.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
NTFY_TOPIC_FILE=/etc/freedom-yield/ntfy-topic
0 0,4,8,12 * * * deploy { echo "=== metal-watch-validators start \$(date -u +\%FT\%TZ) ==="; cd ${REPO_DIR} && bash scripts/check-watch-validators.sh; rc=\$?; echo "=== metal-watch-validators end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> ${REPO_DIR}/logs/check-watch.log 2>&1
EOF
)"

TMP="$(mktemp)"
printf '%s\n' "$CONTENT" > "$TMP"

CHECKER="${FYD_CRON_CHECKER:-$(cd "$(dirname "$0")" && pwd)/check-cron-file.sh}"
if [ -x "$CHECKER" ]; then
	if ! bash "$CHECKER" "$TMP"; then
		echo "ERROR: proposed cron file failed check-cron-file.sh pre-flight — not installing" >&2
		rm -f "$TMP"
		exit 3
	fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
	echo "DRY-RUN: would write ${CRON_FILE}:"
	printf '%s\n' "$CONTENT"
	rm -f "$TMP"
	exit 0
fi

# Ensure the project-local log directory + file exist ahead of the first
# firing — an absent logs/ dir would make the cron's redirect fail before
# check-watch-validators.sh ever runs (same failure class this rework fixes).
# logs/ is tracked via logs/.gitkeep so a checkout normally already has it;
# this is belt-and-suspenders. Real-target ownership (deploy:deploy) is only
# enforced when installing to the actual cron.d path — test harness mode
# (FYD_CRON_FILE overridden) skips chown so it never needs root or a real
# `deploy` account.
LOG_DIR="${REPO_DIR}/logs"
LOG_FILE="${LOG_DIR}/check-watch.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
if [ "$CRON_FILE" = "/etc/cron.d/metal-watch-validators" ]; then
	chown deploy:deploy "$LOG_DIR" "$LOG_FILE" 2>/dev/null || true
fi

if [ -f "$CRON_FILE" ] && [ "$(cat "$CRON_FILE")" = "$CONTENT" ]; then
	echo "ok: ${CRON_FILE} already up to date (no change)"
	rm -f "$TMP"
	exit 0
fi

if [ -f "$CRON_FILE" ]; then
	STAMP="$(date -u +%Y%m%d-%H%M%S)"
	mkdir -p "$BACKUP_DIR"
	BACKUP_FILE="${BACKUP_DIR}/$(basename "$CRON_FILE").bak-${STAMP}"
	cp -p "$CRON_FILE" "$BACKUP_FILE"
	echo "backed up prior cron to ${BACKUP_FILE}"
fi

chmod 644 "$TMP"
if [ "$CRON_FILE" = "/etc/cron.d/metal-watch-validators" ]; then
	chown root:root "$TMP"
fi
mv "$TMP" "$CRON_FILE"
echo "installed: ${CRON_FILE} (schedule: 0 0,4,8,12 * * * UTC = 09/13/17/21 JST)"
echo "log:       ${LOG_FILE}"
