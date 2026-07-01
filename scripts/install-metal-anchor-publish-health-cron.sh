#!/usr/bin/env bash
# install-metal-anchor-publish-health-cron.sh — install the /etc/cron.d/
# entry that runs check-anchor-publish-health.sh every 15 minutes on the
# Hetzner validator host.
#
# Runs as root; writes to /etc/cron.d/metal-anchor-publish-health.
# Idempotent: if the file already contains the same content, no change.

set -euo pipefail

CRON_TARGET=/etc/cron.d/metal-anchor-publish-health
REPO_PATH="${FYD_REPO_PATH:-/home/deploy/metal.freedom-yield.com}"

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (needs to write /etc/cron.d/)" >&2
	echo "       usage: sudo bash scripts/install-metal-anchor-publish-health-cron.sh" >&2
	exit 2
fi

if [ ! -x "${REPO_PATH}/scripts/check-anchor-publish-health.sh" ]; then
	echo "ERROR: ${REPO_PATH}/scripts/check-anchor-publish-health.sh missing or not executable" >&2
	echo "       ensure the repo is up to date at ${REPO_PATH} (or override with FYD_REPO_PATH=...)" >&2
	exit 3
fi

read -r -d '' EXPECTED <<CRON || true
# Every 15 minutes, verify that https://metal.freedom-yield.com/api/anchor-source.json
# returns 200. On non-200, auto-recover by pushing the Hetzner-local
# public/api/anchor-source.json via push-to-xserver.sh. All events (including
# successful recoveries) are appended to /var/log/anchor-publish-health.log.
#
# Motivation: GitHub Actions rsync used to delete the runtime anchor-source.json
# on every deploy (fixed by --exclude in deploy.yml), but a monitor gives us
# a durable safety net for any future publish-path regressions.
#
# The script does NOT regenerate; regeneration is operator-authorized (broadcast
# timing coupling). Auto-recover only re-pushes an existing local file.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/15 * * * * deploy bash ${REPO_PATH}/scripts/check-anchor-publish-health.sh
CRON

if [ -f "$CRON_TARGET" ] && diff -q "$CRON_TARGET" <(printf '%s\n' "$EXPECTED") >/dev/null 2>&1; then
	echo "OK: ${CRON_TARGET} already up to date — no changes"
	exit 0
fi

if [ -f "$CRON_TARGET" ]; then
	BAK="${CRON_TARGET}.bak-$(date +%Y%m%d-%H%M%S)"
	cp -p "$CRON_TARGET" "$BAK"
	echo "backup: $BAK"
fi

printf '%s\n' "$EXPECTED" > "$CRON_TARGET"
chmod 644 "$CRON_TARGET"
chown root:root "$CRON_TARGET"

# Trigger cron reload (Ubuntu cron re-reads /etc/cron.d on next minute anyway,
# but touch the parent dir so any watching mtime is bumped).
touch /etc/cron.d/

echo "OK: wrote ${CRON_TARGET}"
echo "next fire: within 15 minutes"
echo "log:       /var/log/anchor-publish-health.log"
