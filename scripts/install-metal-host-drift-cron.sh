#!/usr/bin/env bash
# install-metal-host-drift-cron.sh — install the /etc/cron.d/ entry that runs
# check-host-drift.sh daily on the validator host.
#
# Runs as root; writes to /etc/cron.d/metal-host-drift.
# Idempotent: if the file already contains the same content, no change.
# The generated file carries the SHELL/PATH headers required by
# docs/CRON_CONVENTIONS.md (check-cron-file.sh rule 5) and logs via logger
# (rule: no redirect into /var/log paths the deploy user cannot create).
#
# Schedule: 05:15 UTC daily — after the 04:00 feed batch and the deploy
# window, so a healthy day reads "in sync" exactly once.
#
# Usage (validator host):
#   sudo bash scripts/install-metal-host-drift-cron.sh
#
# Env overrides:
#   FYD_REPO_PATH   repo path on the host (default /home/deploy/metal.freedom-yield.com)

set -euo pipefail

CRON_TARGET=/etc/cron.d/metal-host-drift
REPO_PATH="${FYD_REPO_PATH:-/home/deploy/metal.freedom-yield.com}"

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (needs to write /etc/cron.d/)" >&2
	echo "       usage: sudo bash scripts/install-metal-host-drift-cron.sh" >&2
	exit 2
fi

if [ ! -f "${REPO_PATH}/scripts/check-host-drift.sh" ]; then
	echo "ERROR: ${REPO_PATH}/scripts/check-host-drift.sh missing" >&2
	echo "       ensure the repo is up to date at ${REPO_PATH} (or override with FYD_REPO_PATH=...)" >&2
	exit 3
fi

read -r -d '' EXPECTED <<CRON || true
# Daily tripwire: alert (ntfy) if the validator-host checkout diverges from
# origin/main — local commits, code-zone content drift (scripts/docs/tests/
# deploy; public/ excluded by design), or falling far behind. Read-only:
# never pulls or resets. Motivation: the 2026-07-06 reconcile found the host
# 205 ahead / 258 behind after an unwatched history rewrite; this cron keeps
# that from rebuilding silently. See scripts/check-host-drift.sh.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
15 5 * * * deploy bash ${REPO_PATH}/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
CRON

if [ -f "$CRON_TARGET" ] && [ "$(cat "$CRON_TARGET")" = "$EXPECTED" ]; then
	echo "ok: ${CRON_TARGET} already up to date (no change)"
	exit 0
fi

TMP="$(mktemp)"
printf '%s\n' "$EXPECTED" > "$TMP"

# Pre-flight lint when the repo's linter is available.
if [ -x "${REPO_PATH}/scripts/check-cron-file.sh" ]; then
	if ! bash "${REPO_PATH}/scripts/check-cron-file.sh" "$TMP"; then
		echo "ERROR: proposed cron file failed check-cron-file.sh — not installing" >&2
		rm -f "$TMP"
		exit 4
	fi
fi

install -m 0644 -o root -g root "$TMP" "$CRON_TARGET"
rm -f "$TMP"
echo "installed: ${CRON_TARGET} (daily 05:15 UTC, alert-only)"
