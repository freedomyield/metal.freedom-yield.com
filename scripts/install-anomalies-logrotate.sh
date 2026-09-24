#!/usr/bin/env bash
# install-anomalies-logrotate.sh — install /etc/logrotate.d/anomalies: 90-day
# retention for the anomaly detector's cron log and the public-site probe's
# diagnostics + blip logs, and provision those two logs deploy-writable.
#
# CHAIN: none — writes one logrotate config and touches log files.
# PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway here or downstream.
#
# Why (docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# §3.5, goal G5): the 2026-09-21/23 public-site alerts could not be explained
# after the fact, partly because /var/log/anomalies.log kept only 7 days. The
# new diagnostics log (anomalies-web-diag.log) and incident log
# (anomalies-web-blips.log) are what a later digest or a hosting-provider
# support inquiry reads, so all three are kept 90 days.
#
# Single source: scripts/vps-bootstrap.sh calls this installer instead of
# carrying its own heredoc, so a fresh host and a remediated host cannot
# drift apart.
#
# Why this installer also provisions the two new logs: check-anomalies.sh runs
# as `deploy` and /var/log is root-owned, so `deploy` cannot create a file
# there (the 2026-06-19 metal-evidence failure, docs/CRON_CONVENTIONS.md
# Rule 1). They are created once here as root, owned by the deploy user,
# 0644 — the same pre-provisioning vps-bootstrap.sh does for anomalies.log.
# An existing log is never truncated.
#
# Backups of a differing prior config go to FYD_BACKUP_DIR, never next to the
# target: logrotate reads every file in /etc/logrotate.d, and a
# "*.bak-<stamp>" sidecar is not on its taboo-extension list, so it would be
# loaded as a second config for the same logs.
#
# Usage (validator host, as root):
#   sudo bash scripts/install-anomalies-logrotate.sh
#
# Env overrides (test harness):
#   FYD_LOGROTATE_TARGET  config file to write (default /etc/logrotate.d/anomalies).
#                         When overridden, the root requirement is waived and
#                         no ownership is enforced.
#   FYD_LOG_DIR           directory holding the three logs (default /var/log)
#   FYD_DEPLOY_USER       owner of the logs and of logrotate's `create`
#                         (default deploy)
#   FYD_BACKUP_DIR        backup destination (default /var/backups)
#
# Exit codes:
#   0  installed or already up to date
#   2  not root (and FYD_LOGROTATE_TARGET not overridden)
#   3  log directory missing
#   4  generated config failed `logrotate -d` (nothing changed)
#
# Operator-gated: committed so the host action is one command; running it on
# the host follows operator approval (Constitution §5 / Operating Model W7).

set -euo pipefail

PROD_TARGET="/etc/logrotate.d/anomalies"
TARGET="${FYD_LOGROTATE_TARGET:-$PROD_TARGET}"
LOG_DIR="${FYD_LOG_DIR:-/var/log}"
DEPLOY_USER="${FYD_DEPLOY_USER:-deploy}"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups}"

if [ "$TARGET" = "$PROD_TARGET" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (writes /etc/logrotate.d/ and provisions /var/log files)" >&2
	echo "       usage: sudo bash scripts/install-anomalies-logrotate.sh" >&2
	exit 2
fi
if [ ! -d "$LOG_DIR" ]; then
	echo "ERROR: log directory missing: ${LOG_DIR}" >&2
	exit 3
fi

read -r -d '' EXPECTED <<CONF || true
# Managed by scripts/install-anomalies-logrotate.sh — edit the installer, not this file.
# 90-day retention: web-probe design spec 2026-09-24 §3.5 (G5).
${LOG_DIR}/anomalies.log ${LOG_DIR}/anomalies-web-diag.log ${LOG_DIR}/anomalies-web-blips.log {
  daily
  rotate 90
  compress
  missingok
  notifempty
  create 644 ${DEPLOY_USER} ${DEPLOY_USER}
}
CONF

TMP="$(mktemp)"
trap 'rm -f "$TMP" "${TMP}.state"' EXIT
printf '%s\n' "$EXPECTED" >"$TMP"

# Parse check with logrotate itself (debug mode changes nothing; a scratch
# state file keeps /var/lib/logrotate/status untouched). Only for the real
# target: that is where the `create` owner is guaranteed to exist and where
# the config will actually be read; test harnesses have neither.
if [ "$TARGET" = "$PROD_TARGET" ] && command -v logrotate >/dev/null 2>&1; then
	if ! logrotate -d -s "${TMP}.state" "$TMP" >/dev/null 2>&1; then
		echo "ERROR: generated config failed 'logrotate -d' — nothing changed" >&2
		logrotate -d -s "${TMP}.state" "$TMP" 2>&1 | tail -5 >&2 || true
		exit 4
	fi
fi

for name in anomalies.log anomalies-web-diag.log anomalies-web-blips.log; do
	f="${LOG_DIR}/${name}"
	if [ ! -e "$f" ]; then
		: >"$f"
		echo "provisioned: ${f}"
	fi
	if [ "$TARGET" = "$PROD_TARGET" ]; then
		chown "${DEPLOY_USER}:${DEPLOY_USER}" "$f"
	fi
	chmod 0644 "$f"
done

if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$EXPECTED" ]; then
	echo "ok: ${TARGET} already up to date (no change)"
	exit 0
fi

if [ -f "$TARGET" ]; then
	STAMP="$(date -u +%Y%m%d-%H%M%S)"
	mkdir -p "$BACKUP_DIR"
	cp -p "$TARGET" "${BACKUP_DIR}/logrotate-$(basename "$TARGET").bak-${STAMP}"
	echo "backed up prior target to ${BACKUP_DIR}/logrotate-$(basename "$TARGET").bak-${STAMP}"
fi

if [ "$TARGET" = "$PROD_TARGET" ]; then
	install -m 0644 -o root -g root "$TMP" "$TARGET"
else
	install -m 0644 "$TMP" "$TARGET"
fi
echo "installed: ${TARGET} (daily, rotate 90, compress; create 644 ${DEPLOY_USER} ${DEPLOY_USER})"
echo "logs:      ${LOG_DIR}/anomalies.log ${LOG_DIR}/anomalies-web-diag.log ${LOG_DIR}/anomalies-web-blips.log"
