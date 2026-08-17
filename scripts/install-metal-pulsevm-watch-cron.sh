#!/usr/bin/env bash
# install-metal-pulsevm-watch-cron.sh — install /etc/cron.d/metal-pulsevm-watch,
# the daily run of check-pulsevm-upstream.sh on the validator host.
#
# CHAIN: none — writes a cron file. The checker it schedules performs
#        read-only HTTP GETs against public third-party URLs only.
# PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway here or downstream.
#
# Why daily, and not every 15 minutes like the anchor-publish-health cron:
#   Everything this watch reads moves on a scale of weeks. Releases land
#   roughly weekly; the docs site is a community developer's Vercel
#   deployment; A-Chain Alpine's head block did not advance at all across
#   repeated samples on 2026-08-17. Two of the four sources are also
#   rate-limited or owned by someone else — GitHub's unauthenticated API
#   allows 60 requests/hour per IP and answers 403 once that is spent — so a
#   sub-daily cadence would spend a third party's budget to learn nothing.
#   Four GETs a day is the polite-external-access floor that still catches a
#   change within one working day of it landing.
#
# Why 02:00 UTC:
#   = 11:00 JST, inside the operator's working hours, so the one thing this
#   cron can page about arrives when it can be acted on. 01:00 UTC is already
#   taken by metal-identity-pins; staggering avoids two crons contending for
#   the same minute on a host that also serves the validator.
#
# Alert discipline (why this is safe to run daily):
#   check-pulsevm-upstream.sh notifies only when one of its four triggers
#   fires, plus once on the very first run (no prior state = fail open toward
#   alerting), plus once per outage if a source stays unreachable for three
#   consecutive runs. A new release tag is recorded, never pushed. Steady
#   state is therefore zero notifications.
#
# FY_LIVE=1 in the env header is mandatory: scripts/lib/side-effects.sh (the
#   C3 rollout, 2026-08-06) makes every production side effect opt-in, and
#   this checker routes its ntfy push, its state write, AND its file log
#   through it. Without the line the daily run still checks and still exits
#   non-zero, but it writes no state — so it would re-baseline every day and
#   the diff that IS the detection would never be computed. check-cron-file.sh
#   Rule 6 enforces the line (dynamically: it sees the checker sources
#   side-effects.sh, so no allowlist entry is needed).
#
# Usage:
#   sudo bash scripts/install-metal-pulsevm-watch-cron.sh
#
# Env overrides:
#   FYD_REPO_PATH     repo path on the host (default /home/deploy/metal.freedom-yield.com)
#   FYD_CRON_TARGET   cron file to write (default /etc/cron.d/metal-pulsevm-watch).
#                     When overridden, the root requirement is waived (test
#                     harness mode) and root ownership is not enforced.
#   FYD_BACKUP_DIR    backup destination for a differing pre-existing target
#                     (default /var/backups)
#
# Exit codes:
#   0  installed or already up to date
#   2  not root (and FYD_CRON_TARGET not overridden)
#   3  check-pulsevm-upstream.sh missing at FYD_REPO_PATH
#   4  generated cron file failed the check-cron-file.sh pre-flight
#
# Operator-gated: this installer is committed so the host action is one
# command; running it on the host is an operator-approved step (Constitution
# §5 / Operating Model W7), not something CI or an AI session performs.

set -euo pipefail

CRON_TARGET="${FYD_CRON_TARGET:-/etc/cron.d/metal-pulsevm-watch}"
REPO_PATH="${FYD_REPO_PATH:-/home/deploy/metal.freedom-yield.com}"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups}"

if [ "$CRON_TARGET" = "/etc/cron.d/metal-pulsevm-watch" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (needs to write /etc/cron.d/)" >&2
	echo "       usage: sudo bash scripts/install-metal-pulsevm-watch-cron.sh" >&2
	exit 2
fi

if [ ! -f "${REPO_PATH}/scripts/check-pulsevm-upstream.sh" ]; then
	echo "ERROR: ${REPO_PATH}/scripts/check-pulsevm-upstream.sh missing" >&2
	echo "       ensure the repo is up to date at ${REPO_PATH} (or override with FYD_REPO_PATH=...)" >&2
	exit 3
fi

read -r -d '' EXPECTED <<CRON || true
# Daily, watch the PulseVM upstream for the four changes that would oblige
# this project to act: the "third-party node sync is not yet supported"
# notice disappearing (we could run our own node), a mainnet section or a
# new chain id appearing on the endpoints page (migration, or another Alpine
# reset), a new documentation page (the site announces before anything else
# changes), and A-Chain Alpine's head block actually advancing.
#
# Why this matters here: PulseVM's docs describe it as the future basis of
# A-Chain, which is where this project's cycle anchors live. If A-Chain moves
# onto it, bin/safe-broadcast's gate 1 (/v1/history/get_transaction) and
# gate 3 (proton chain:info) both lose their endpoints, and under the Prime
# Directive a permanently-failing gate 1 means no mainnet anchor can be sent
# at all. No date has been published, so this is a watch, not a countdown.
#
# 02:00 UTC = 11:00 JST: inside operator working hours, and off the 01:00
# slot metal-identity-pins already holds. Daily rather than sub-daily because
# two of the four sources belong to third parties (a community Vercel
# deployment and GitHub's 60/hour unauthenticated API).
#
# Read-only HTTP GETs; no broadcast, no push, no recovery. Steady state is
# silent. Exit codes: 0 no change, 3 trigger fired (pushes high), 4 a source
# was unreachable, 5 a body could not be parsed, 6 side-effects lib missing.
#
# FY_LIVE=1 is required for the ntfy push, the state write, AND the file log
# (scripts/lib/side-effects.sh, C3 rollout 2026-08-06). Without it the state
# is never written, so the day-over-day diff that IS the detection would
# never be computed. check-cron-file.sh Rule 6 enforces the line.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
0 2 * * * deploy bash ${REPO_PATH}/scripts/check-pulsevm-upstream.sh 2>&1 | logger -t pulsevm-upstream
CRON

if [ -f "$CRON_TARGET" ] && [ "$(cat "$CRON_TARGET")" = "$EXPECTED" ]; then
	echo "ok: ${CRON_TARGET} already up to date (no change)"
	exit 0
fi

TMP="$(mktemp)"
printf '%s\n' "$EXPECTED" > "$TMP"

# Pre-flight lint when the repo's linter is available. FYD_CRON_SCRIPTS_DIR
# points Rule 6's dynamic resolution at the checkout being installed FROM, so
# the rule can read check-pulsevm-upstream.sh and see that it sources
# side-effects.sh — without it the linter would resolve against its own
# directory, which is the same place here but need not be under FYD_REPO_PATH.
if [ -x "${REPO_PATH}/scripts/check-cron-file.sh" ]; then
	if ! FYD_CRON_SCRIPTS_DIR="${REPO_PATH}/scripts" bash "${REPO_PATH}/scripts/check-cron-file.sh" "$TMP"; then
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

if [ "$CRON_TARGET" = "/etc/cron.d/metal-pulsevm-watch" ]; then
	install -m 0644 -o root -g root "$TMP" "$CRON_TARGET"
	rm -f "$TMP"
else
	# test harness mode: no root ownership enforcement
	install -m 0644 "$TMP" "$CRON_TARGET"
	rm -f "$TMP"
fi
echo "installed: ${CRON_TARGET} (daily 02:00 UTC = 11:00 JST)"
echo "alerts:    high-priority ntfy push only on a trigger (T1-T4) or the first-run baseline"
echo "log:       ${REPO_PATH}/logs/pulsevm-upstream.log + journalctl -t pulsevm-upstream"
echo "state:     ${REPO_PATH}/logs/pulsevm-upstream-state.json (gitignored; the diff basis)"
echo "note:      logs/ must be deploy-writable — scripts/install-host-log-dir.sh provisions it"
