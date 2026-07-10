#!/usr/bin/env bash
# install-metal-host-advance-cron.sh — install the /etc/cron.d/ entry that
# runs advance-host-checkout.sh daily on the validator host.
#
# Runs as root; writes to /etc/cron.d/metal-host-advance.
# Idempotent: if the file already contains the same content, no change.
# The generated file carries the SHELL/PATH headers required by
# docs/CRON_CONVENTIONS.md (check-cron-file.sh rule 5) and logs via logger
# (rule: no redirect into /var/log paths the deploy user cannot create).
#
# Schedule: 04:45 UTC daily — BEFORE check-host-drift.sh's 05:15 UTC tripwire
# (scripts/install-metal-host-drift-cron.sh). This ordering is deliberate: a
# healthy auto-advance run clears any behind-origin drift 30 minutes before
# the read-only backstop samples host state, so the tripwire only ever fires
# when the self-heal itself has stopped working (see docs/superpowers/specs/
# 2026-07-09-host-checkout-auto-advance-design.md §2, "Reconcile the existing
# tripwire").
#
# Usage (validator host):
#   sudo bash scripts/install-metal-host-advance-cron.sh
#
# Env overrides:
#   FYD_REPO_PATH     repo path on the host (default /home/deploy/metal.freedom-yield.com)
#   FYD_CRON_TARGET   cron file to write (default /etc/cron.d/metal-host-advance).
#                     When overridden, the root requirement is waived (test
#                     harness mode) and the file is written without root
#                     ownership enforcement.
#   FYD_BACKUP_DIR    backup destination for a differing pre-existing target
#                     (default /var/backups)
#
# Exit codes:
#   0  installed or already up to date
#   2  not root (and FYD_CRON_TARGET not overridden)
#   3  advance-host-checkout.sh missing at FYD_REPO_PATH
#   4  generated cron file failed the check-cron-file.sh pre-flight
#
# Out of scope (operator-gated, per the design spec §3.7): this script only
# generates the installer. It does not install the cron on the real host —
# that is a separate operator-approved action.

set -euo pipefail

CRON_TARGET="${FYD_CRON_TARGET:-/etc/cron.d/metal-host-advance}"
REPO_PATH="${FYD_REPO_PATH:-/home/deploy/metal.freedom-yield.com}"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups}"

if [ "$CRON_TARGET" = "/etc/cron.d/metal-host-advance" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (needs to write /etc/cron.d/)" >&2
	echo "       usage: sudo bash scripts/install-metal-host-advance-cron.sh" >&2
	exit 2
fi

if [ ! -f "${REPO_PATH}/scripts/advance-host-checkout.sh" ]; then
	echo "ERROR: ${REPO_PATH}/scripts/advance-host-checkout.sh missing" >&2
	echo "       ensure the repo is up to date at ${REPO_PATH} (or override with FYD_REPO_PATH=...)" >&2
	exit 3
fi

read -r -d '' EXPECTED <<CRON || true
# Daily self-heal: FF-only advance the validator-host git checkout to
# origin/main (never authors — refuses if the host is ever ahead). Scheduled
# at 04:45 UTC, 30 minutes BEFORE check-host-drift.sh's 05:15 UTC tripwire
# (scripts/install-metal-host-drift-cron.sh) so a healthy run clears drift
# before the read-only backstop samples it. See
# scripts/advance-host-checkout.sh and docs/superpowers/specs/
# 2026-07-09-host-checkout-auto-advance-design.md.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
45 4 * * * deploy bash ${REPO_PATH}/scripts/advance-host-checkout.sh 2>&1 | logger -t host-advance
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

# Back up a pre-existing, differing target before overwrite (auditability,
# same pattern as install-metal-host-drift-cron.sh). Content is regenerable,
# but the prior bytes are kept.
if [ -f "$CRON_TARGET" ]; then
	STAMP="$(date -u +%Y%m%d-%H%M%S)"
	mkdir -p "$BACKUP_DIR"
	cp -p "$CRON_TARGET" "${BACKUP_DIR}/$(basename "$CRON_TARGET").bak-${STAMP}"
	echo "backed up prior target to ${BACKUP_DIR}/$(basename "$CRON_TARGET").bak-${STAMP}"
fi

if [ "$CRON_TARGET" = "/etc/cron.d/metal-host-advance" ]; then
	install -m 0644 -o root -g root "$TMP" "$CRON_TARGET"
	rm -f "$TMP"
else
	# test harness mode: no root ownership enforcement
	install -m 0644 "$TMP" "$CRON_TARGET"
	rm -f "$TMP"
fi
echo "installed: ${CRON_TARGET} (daily 04:45 UTC, self-heal)"
