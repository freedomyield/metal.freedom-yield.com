#!/usr/bin/env bash
# install-metal-identity-pins-cron.sh — install /etc/cron.d/metal-identity-pins,
# the daily run of check-identity-pins.sh --mode=live on the validator host.
#
# CHAIN: none — writes a cron file. The checker it schedules performs
#        read-only HTTP GETs only.
# PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway here or downstream.
#
# Why daily and why 01:00 UTC:
#   A git-tracked artifact pin can only break when a commit lands and deploys,
#   so a sub-daily cadence buys nothing. 01:00 UTC = 10:00 JST puts any push
#   inside the operator's working hours (09:30–18:30 JST) rather than at
#   night — the same reasoning that moved the anchor-watch cron off its
#   original overnight slot.
#
# Alert discipline (the reason this is safe to run daily):
#   check-identity-pins.sh alerts ONLY on a NEW break of a git-tracked pin.
#   The three push-owned feed pins that are permanently stale by construction
#   (evidence.json / validator.json / uptime-cycles.json) are logged and never
#   pushed, and the one known-broken tracked pin is acknowledged in
#   deploy/identity-pin-baseline.json. A steady state therefore produces zero
#   notifications. See the script header for the full alert/silence split.
#
# Usage:
#   sudo bash scripts/install-metal-identity-pins-cron.sh
#
# Env overrides:
#   FYD_REPO_PATH     repo path on the host (default /home/deploy/metal.freedom-yield.com)
#   FYD_CRON_TARGET   cron file to write (default /etc/cron.d/metal-identity-pins).
#                     When overridden, the root requirement is waived (test
#                     harness mode) and root ownership is not enforced.
#   FYD_BACKUP_DIR    backup destination for a differing pre-existing target
#                     (default /var/backups)
#
# Exit codes:
#   0  installed or already up to date
#   2  not root (and FYD_CRON_TARGET not overridden)
#   3  check-identity-pins.sh missing at FYD_REPO_PATH
#   4  generated cron file failed the check-cron-file.sh pre-flight
#
# Operator-gated: this installer is committed so the host action is one
# command; running it on the host is an operator-approved step (Constitution
# §5 / Operating Model W7), not something CI or an AI session performs.

set -euo pipefail

CRON_TARGET="${FYD_CRON_TARGET:-/etc/cron.d/metal-identity-pins}"
REPO_PATH="${FYD_REPO_PATH:-/home/deploy/metal.freedom-yield.com}"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups}"

if [ "$CRON_TARGET" = "/etc/cron.d/metal-identity-pins" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (needs to write /etc/cron.d/)" >&2
	echo "       usage: sudo bash scripts/install-metal-identity-pins-cron.sh" >&2
	exit 2
fi

if [ ! -f "${REPO_PATH}/scripts/check-identity-pins.sh" ]; then
	echo "ERROR: ${REPO_PATH}/scripts/check-identity-pins.sh missing" >&2
	echo "       ensure the repo is up to date at ${REPO_PATH} (or override with FYD_REPO_PATH=...)" >&2
	exit 3
fi

read -r -d '' EXPECTED <<CRON || true
# Daily, verify that every artifact pin inside the operator-SIGNED
# public/api/identity.json still describes the bytes actually served. A
# git-tracked pin can only break when a commit changes the pinned file, and
# on 2026-08-05 exactly that happened (7dfc3c4 edited
# cycle-history.schema.v1.json one day after 90bcdd9 signed a manifest
# pinning its previous bytes) with nothing in CI or cron noticing for two
# days. This cron is the ops half of that fix; the CI half is the
# --mode=repo gate in validate.yml + ci-main.yml.
#
# Alert discipline: only a NEW break of a GIT-TRACKED pin pushes (high).
# Push-owned feeds (evidence/validator/uptime-cycles) drift by construction
# and are logged silently; the known-broken tracked pin is acknowledged in
# deploy/identity-pin-baseline.json. Steady state = zero notifications.
#
# 01:00 UTC = 10:00 JST so any push lands inside operator working hours.
# Read-only HTTP GETs; no broadcast, no recovery. Exit codes: 0 clean,
# 3 new tracked break, 4 unverifiable, 2 cannot run.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 1 * * * deploy bash ${REPO_PATH}/scripts/check-identity-pins.sh --mode=live 2>&1 | logger -t identity-pin-drift
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

if [ -f "$CRON_TARGET" ]; then
	STAMP="$(date -u +%Y%m%d-%H%M%S)"
	mkdir -p "$BACKUP_DIR"
	cp -p "$CRON_TARGET" "${BACKUP_DIR}/$(basename "$CRON_TARGET").bak-${STAMP}"
	echo "backed up prior target to ${BACKUP_DIR}/$(basename "$CRON_TARGET").bak-${STAMP}"
fi

if [ "$CRON_TARGET" = "/etc/cron.d/metal-identity-pins" ]; then
	install -m 0644 -o root -g root "$TMP" "$CRON_TARGET"
	rm -f "$TMP"
else
	# test harness mode: no root ownership enforcement
	install -m 0644 "$TMP" "$CRON_TARGET"
	rm -f "$TMP"
fi
echo "installed: ${CRON_TARGET} (daily 01:00 UTC = 10:00 JST)"
echo "alerts:    high-priority ntfy push ONLY on a new git-tracked pin break"
echo "log:       ${REPO_PATH}/logs/identity-pin-drift.log + journalctl -t identity-pin-drift"
