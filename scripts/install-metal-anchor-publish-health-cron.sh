#!/usr/bin/env bash
# install-metal-anchor-publish-health-cron.sh — install the /etc/cron.d/
# entry that runs check-anchor-publish-health.sh every 15 minutes on the
# validator host.
#
# Runs as root; writes to /etc/cron.d/metal-anchor-publish-health.
# Idempotent: if the file already contains the same content, no change.
#
# 2026-08-06: env header now carries FY_LIVE=1. scripts/lib/side-effects.sh
# (the C3 rollout) gates the production side effects that route THROUGH it —
# a fyd_notify-wrapped ntfy push, a /var/lib/freedom-yield state write — behind
# FY_LIVE=1; anything else is a loud dry no-op. check-anchor-publish-health.sh
# fires a notify.sh alert on failure, so this cron must carry the flag now,
# ahead of that script's own callers migrating onto the lib — landing the
# flag first avoids the cron silently going dry the day that migration
# lands. Enforced by check-cron-file.sh Rule 6.

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
# Every 15 minutes, content-verify that the PUBLIC anchor-source.json is
# served (HTTP 200) and its dag_root_computed matches the on-chain anchored
# root recorded in anchor-receipt.json. Alert-only: on any failure (exit
# 2/3/4/5) the checker itself fires one high-priority ntfy push via
# notify.sh naming the exit code, so the operator is alerted regardless of
# cron's own (non-functional — no MTA on this host) mail delivery. The
# \`2>&1 | logger\` here is a second, independent channel: if notify.sh itself
# cannot reach ntfy (e.g. the topic file is unreadable), the run's stderr is
# still captured via journalctl/syslog instead of vanishing into cron's dead
# mail queue. Non-broadcast, read-only HTTP GETs; see
# scripts/check-anchor-publish-health.sh for the full comparison logic and
# exit-code table.
#
# Motivation: this cron sat with zero output redirect and the checker had no
# notify call — a RED run could go unnoticed for days. Fixed 2026-07-08.
#
# The script performs NO recovery/regeneration; regeneration is
# operator-authorized (broadcast timing coupling).
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
*/15 * * * * deploy bash ${REPO_PATH}/scripts/check-anchor-publish-health.sh 2>&1 | logger -t anchor-publish-health
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
echo "alerts:    high-priority ntfy push on any failure (exit 2/3/4/5), via notify.sh"
echo "log:       ${REPO_PATH}/logs/anchor-publish-health.log (repo-local; when writable) + journalctl -t anchor-publish-health"
