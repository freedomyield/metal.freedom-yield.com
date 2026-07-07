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
# Idempotent: identical content → no change. A differing existing file is
# backed up beside the target as <name>.bak-<UTC ts>. File mode 0644 root
# (cron.d requirement).
#
# Usage (validator host, as root):
#   sudo bash scripts/install-watch-cron.sh [--dry-run]
#
# Env overrides (test-time):
#   FYD_CRON_FILE   target path (default /etc/cron.d/metal-watch-validators).
#                   When overridden, the root requirement and root ownership
#                   are waived (test harness mode).
#   FYD_REPO_DIR    repo checkout on the host
#                   (default /home/deploy/metal.freedom-yield.com)
#
# Exit codes:
#   0  installed / already up to date / dry-run
#   1  usage error
#   2  not root (and FYD_CRON_FILE not overridden)

set -euo pipefail

CRON_FILE="${FYD_CRON_FILE:-/etc/cron.d/metal-watch-validators}"
REPO_DIR="${FYD_REPO_DIR:-/home/deploy/metal.freedom-yield.com}"

DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		-h|--help) sed -n '2,32p' "$0" | sed 's/^# \?//'; exit 0 ;;
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
# Managed by scripts/install-watch-cron.sh — edit there, not here.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
NTFY_TOPIC_FILE=/etc/freedom-yield/ntfy-topic
0 0,4,8,12 * * * deploy cd ${REPO_DIR} && bash scripts/check-watch-validators.sh >> /var/log/check-watch.log 2>&1
EOF
)"

if [ "$DRY_RUN" -eq 1 ]; then
	echo "DRY-RUN: would write ${CRON_FILE}:"
	printf '%s\n' "$CONTENT"
	exit 0
fi

if [ -f "$CRON_FILE" ] && [ "$(cat "$CRON_FILE")" = "$CONTENT" ]; then
	echo "ok: ${CRON_FILE} already up to date (no change)"
	exit 0
fi

if [ -f "$CRON_FILE" ]; then
	STAMP="$(date -u +%Y%m%d-%H%M%S)"
	cp -p "$CRON_FILE" "${CRON_FILE}.bak-${STAMP}"
	echo "backed up prior cron to ${CRON_FILE}.bak-${STAMP}"
fi

TMP="$(mktemp)"
printf '%s\n' "$CONTENT" > "$TMP"
chmod 644 "$TMP"
if [ "$CRON_FILE" = "/etc/cron.d/metal-watch-validators" ]; then
	chown root:root "$TMP"
fi
mv "$TMP" "$CRON_FILE"
echo "installed: ${CRON_FILE} (schedule: 0 0,4,8,12 * * * UTC = 09/13/17/21 JST)"
