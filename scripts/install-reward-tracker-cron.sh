#!/usr/bin/env bash
# install-reward-tracker-cron.sh — install /etc/cron.d/metal-reward-tracker,
# the daily run of scripts/reward-tracker.sh on the validator host.
#
# CHAIN: none — writes a cron file. The script it schedules performs
#        read-only P-Chain RPC calls against the LOCAL metalgo node only
#        (platform.getCurrentValidators / getRewardUTXOs / getCurrentSupply)
#        and, once a cycle matures, an append to a local JSONL ledger plus
#        one ntfy push. No broadcast pathway anywhere in this chain.
# PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway here or downstream.
#
# Why 07:35 JST (= 22:35 UTC, the previous day):
#   The brief asks for "毎日07:35 JST相当". 07:35 JST is inside the
#   operator's normal wake-adjacent hours and, per
#   docs/CRON_CONVENTIONS.md's existing stagger discipline (see e.g.
#   install-metal-pulsevm-watch-cron.sh's 02:00 UTC slot note), sits clear
#   of this project's other daily crons (uptime-history.sh at ~03:30 UTC,
#   metal-identity-pins at 01:00 UTC, metal-pulsevm-watch at 02:00 UTC).
#   07:35 JST on day D is 22:35 UTC on day D-1 — cron's day-of-month field
#   is evaluated in the HOST's local time, which on this project's validator
#   host is UTC, so the crontab line below reads "22 35" but the wall-clock
#   effect for the operator is the intended 07:35 JST every day.
#
# Why AFTER uptime-history.sh (~03:30 UTC), not before:
#   reward-tracker.sh's maturity detection cross-checks the tracked cycle's
#   end_unix against public/api/uptime-cycles.json's most recently closed
#   row (see reward-tracker.sh's own header). If this cron ran before
#   uptime-history.sh had written that day's close row, maturity detection
#   would defer for a day rather than fail — safe, but needlessly slow.
#   22:35 UTC is a full cron cycle after uptime-history.sh's ~03:30 UTC run
#   on the same calendar day, so a cycle that closed earlier that day is
#   already reflected by the time this cron runs.
#
# Alert discipline (why this is safe to run daily):
#   Steady state (no cycle matured today) sends ZERO notifications — see
#   reward-tracker.sh's header. The digest-line regeneration
#   (reward-digest-line.txt) is a local file write, not a push; daily-
#   status.sh's own morning slot is what surfaces it to the operator, once
#   per day, folded into an existing push rather than a second one.
#
# FY_LIVE=1 in the env header is mandatory: scripts/lib/side-effects.sh (the
#   C3 rollout, 2026-08-06) makes every production side effect opt-in, and
#   reward-tracker.sh routes its rewards-history.jsonl append, its
#   in-flight state write, its digest-file write, AND its ntfy push through
#   it. Without the line the daily run still checks and still exits
#   non-zero on a real error, but every write is suppressed — a matured
#   cycle's reward would never be recorded. check-cron-file.sh Rule 6
#   enforces the line (dynamically: it sees reward-tracker.sh sources
#   side-effects.sh, so no allowlist entry is needed).
# Usage:
#   sudo bash scripts/install-reward-tracker-cron.sh
#
# Env overrides:
#   FYD_REPO_PATH     repo path on the host (default /home/deploy/metal.freedom-yield.com)
#   FYD_CRON_TARGET   cron file to write (default /etc/cron.d/metal-reward-tracker).
#                     When overridden, the root requirement is waived (test
#                     harness mode) and root ownership is not enforced.
#   FYD_BACKUP_DIR    backup destination for a differing pre-existing target
#                     (default /var/backups)
#
# Exit codes:
#   0  installed or already up to date
#   2  not root (and FYD_CRON_TARGET not overridden)
#   3  scripts/reward-tracker.sh missing at FYD_REPO_PATH
#   4  generated cron file failed the check-cron-file.sh pre-flight
#
# Operator-gated: this installer is committed so the host action is one
# command; running it on the host is an operator-approved step (Constitution
# §5 / Operating Model W7), not something CI or an AI session performs.

set -euo pipefail

CRON_TARGET="${FYD_CRON_TARGET:-/etc/cron.d/metal-reward-tracker}"
REPO_PATH="${FYD_REPO_PATH:-/home/deploy/metal.freedom-yield.com}"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups}"

if [ "$CRON_TARGET" = "/etc/cron.d/metal-reward-tracker" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (needs to write /etc/cron.d/)" >&2
	echo "       usage: sudo bash scripts/install-reward-tracker-cron.sh" >&2
	exit 2
fi

if [ ! -f "${REPO_PATH}/scripts/reward-tracker.sh" ]; then
	echo "ERROR: ${REPO_PATH}/scripts/reward-tracker.sh missing" >&2
	echo "       ensure the repo is up to date at ${REPO_PATH} (or override with FYD_REPO_PATH=...)" >&2
	exit 3
fi
read -r -d '' EXPECTED <<CRON || true
# Daily, detect a matured validator cycle's confirmed reward (self-stake
# reward + delegation-fee income, combined — see reward-tracker.sh's own
# header for why they are not split), record it append-only to
# /var/lib/freedom-yield/rewards-history.jsonl, push one "🎉 cycle reward"
# ntfy notification on maturity, and regenerate the one-line morning-digest
# projection daily-status.sh's morning slot includes.
#
# Why this matters here: this is the only automated observer of confirmed
# validator + delegation-fee reward income for this project (Constitution
# §0 "積極監視" posture on the reward stream) — see project memory
# reference_cycle_gate_monitoring and the phase1 accumulation plan for the
# self-stake growth context the 25,000 METAL milestone tracks.
#
# 22:35 UTC = 07:35 JST, after uptime-history.sh's ~03:30 UTC daily close
# (so the same-day maturity cross-check against uptime-cycles.json resolves
# same-day rather than deferring one extra day) and clear of this project's
# other daily cron slots (01:00 UTC metal-identity-pins, 02:00 UTC
# metal-pulsevm-watch). See this installer's own header for the fuller
# staggering rationale.
#
# Read-only P-Chain RPC (getCurrentValidators / getRewardUTXOs /
# getCurrentSupply) against the LOCAL node only; no broadcast. Steady state
# (no cycle matured today) sends zero notifications.
#
# FY_LIVE=1 is required for the rewards-history append, the in-flight
# tracking-state write, the digest-file write, AND the ntfy push
# (scripts/lib/side-effects.sh, C3 rollout 2026-08-06). Without it a
# matured cycle's reward would never be recorded. check-cron-file.sh Rule 6
# enforces the line.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
35 22 * * * deploy bash ${REPO_PATH}/scripts/reward-tracker.sh 2>&1 | logger -t reward-tracker
CRON
if [ -f "$CRON_TARGET" ] && [ "$(cat "$CRON_TARGET")" = "$EXPECTED" ]; then
	echo "ok: ${CRON_TARGET} already up to date (no change)"
	exit 0
fi

TMP="$(mktemp)"
printf '%s\n' "$EXPECTED" > "$TMP"

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

if [ "$CRON_TARGET" = "/etc/cron.d/metal-reward-tracker" ]; then
	install -m 0644 -o root -g root "$TMP" "$CRON_TARGET"
	rm -f "$TMP"
else
	# test harness mode: no root ownership enforcement
	install -m 0644 "$TMP" "$CRON_TARGET"
	rm -f "$TMP"
fi
echo "installed: ${CRON_TARGET} (daily 22:35 UTC = 07:35 JST)"
echo "alerts:    high-priority ntfy push only when a tracked cycle actually matures (zero otherwise)"
echo "ledger:    /var/lib/freedom-yield/rewards-history.jsonl (append-only)"
echo "digest:    /var/lib/freedom-yield/reward-digest-line.txt (regenerated every run; consumed by daily-status.sh's morning slot)"
echo "note:      run AFTER scripts/install-host-log-dir.sh + FY_STATE_DIR must be writable by 'deploy' (default /var/lib/freedom-yield, shared with uptime-history.sh)"
