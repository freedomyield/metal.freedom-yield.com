#!/usr/bin/env bash
# install-anchor-watch-alert-only.sh — re-enable the anchor-watch cron in
# DETECTION / ALERT-ONLY mode (option a). Run as root on the validator host.
#
# Points watch-anchor-events.sh's DRIVER at notify-anchor-transition.sh via the
# ANCHOR_DRIVER env, so a presence transition fires an ntfy push (run the MANUAL
# anchor from the Mac) instead of the stranded the validator host auto-broadcast path.
# BROADCASTS NOTHING. Idempotent. Removes the .disabled-cycle-transition marker.
#
# 2026-07-08: the generated cron redirected straight to /var/log/anchor-watch.log
# — the same class of failure that caused the 2026-06-19 metal-evidence incident
# (deploy user cannot create files under /var/log/). Reworked to the
# project-local logs/ pattern documented in docs/CRON_CONVENTIONS.md: the chain
# is brace-wrapped so the redirect covers every command, start/end markers +
# rc=$? capture make each run auditable, and the log lives under the repo's own
# logs/ dir (deploy:deploy owned). The generated file is linted with
# check-cron-file.sh before every install — a lint failure aborts the install.
#
# 2026-08-06: env header now carries FY_LIVE=1. scripts/lib/side-effects.sh
# (the C3 rollout) gates every production side effect — notify.sh,
# push-to-web-host.sh, /var/lib/freedom-yield state writes — behind
# FY_LIVE=1; anything else is a loud dry no-op. This cron's chain notifies
# and writes anchor-watcher-state.json, so it must carry the flag now, ahead
# of watch-anchor-events.sh's own callers migrating onto the lib — landing
# the flag first avoids the cron silently going dry the day that migration
# lands. Enforced by check-cron-file.sh Rule 6.
#
# Env overrides (test-time):
#   FYD_ANCHOR_WATCH_CRON  target cron path (default /etc/cron.d/metal-anchor-watch).
#                          When overridden, the root requirement and root/deploy
#                          ownership enforcement are waived (test harness mode).
#   REPO                   repo checkout on the host (default
#                          /home/deploy/metal.freedom-yield.com) — also where
#                          logs/anchor-watch.log is created.
#   FYD_CRON_CHECKER       path to check-cron-file.sh used for the pre-flight
#                          lint (default: the copy next to this script).
#
# Exit codes:
#   0  installed
#   1  prerequisite missing (driver/notify script), or generated file failed
#      the check-cron-file.sh pre-flight lint
#   2  not root (and FYD_ANCHOR_WATCH_CRON not overridden)
set -euo pipefail

REPO="${REPO:-/home/deploy/metal.freedom-yield.com}"
CRON="${FYD_ANCHOR_WATCH_CRON:-/etc/cron.d/metal-anchor-watch}"
DRIVER="${REPO}/scripts/notify-anchor-transition.sh"
NOTIFY="${REPO}/scripts/notify.sh"
TOPIC=/etc/freedom-yield/ntfy-topic

if [ "$CRON" = "/etc/cron.d/metal-anchor-watch" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: must run as root to write ${CRON} (usage: sudo bash $0)" >&2
	exit 2
fi

# --- prerequisites (fail closed if the alert-only driver is not deployed) ---
# sync-to-validator-host.sh does not preserve the +x bit, so ensure it here
# (watch-anchor-events.sh execs the driver directly and requires it executable).
[ -f "$DRIVER" ] || { echo "ERROR: notify driver missing: $DRIVER" >&2
                      echo "       run  sync-to-validator-host.sh  from the Mac first." >&2; exit 1; }
chmod +x "$DRIVER" "${REPO}/scripts/watch-anchor-events.sh"
[ -x "$DRIVER" ] || { echo "ERROR: could not make notify driver executable: $DRIVER" >&2; exit 1; }
[ -x "$NOTIFY" ] || { echo "ERROR: notify.sh missing/not executable: $NOTIFY" >&2; exit 1; }
if [ ! -r "$TOPIC" ] || [ ! -s "$TOPIC" ]; then
	echo "WARN: ntfy topic not configured at $TOPIC — alerts will no-op (non-fatal)." >&2
fi

# --- write the cron in alert-only mode ---
TMP="$(mktemp)"
cat > "$TMP" <<EOF
# Phase α anchor watcher — DETECTION / ALERT-ONLY mode (2026-07-04).
# Polls metalgo for our NodeID validator-presence flag every 5 min. On a
# transition (cyclestart / cycleend) it dispatches to notify-anchor-transition.sh,
# which fires an ntfy push telling the operator to run the MANUAL anchor from the
# Mac. BROADCASTS NOTHING from this host — metalfreedom@anchor key is Mac-only.
# State file: /var/lib/freedom-yield/anchor-watcher-state.json
#
# Log path is project-local (logs/), not /var/log/ — see docs/CRON_CONVENTIONS.md.
# The chain is brace-wrapped with start/end markers + rc capture (rules 1-3 of
# that doc) and this file is linted by check-cron-file.sh before every install.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
ANCHOR_DRIVER=${DRIVER}
*/5 * * * * deploy { echo "=== metal-anchor-watch start \$(date -u +\%FT\%TZ) ==="; cd ${REPO} && bash scripts/watch-anchor-events.sh; rc=\$?; echo "=== metal-anchor-watch end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> ${REPO}/logs/anchor-watch.log 2>&1
EOF

CHECKER="${FYD_CRON_CHECKER:-$(cd "$(dirname "$0")" && pwd)/check-cron-file.sh}"
if [ -x "$CHECKER" ]; then
	if ! bash "$CHECKER" "$TMP"; then
		echo "ERROR: proposed cron file failed check-cron-file.sh pre-flight — not installing" >&2
		rm -f "$TMP"
		exit 1
	fi
fi

# Ensure the project-local log directory + file exist ahead of the first
# firing — an absent logs/ dir would make the cron's redirect fail before
# watch-anchor-events.sh ever runs (same failure class this rework fixes).
# logs/ is tracked via logs/.gitkeep so a checkout normally already has it;
# this is belt-and-suspenders. Real-target ownership (deploy:deploy) is only
# enforced when installing to the actual cron.d path.
LOG_DIR="${REPO}/logs"
LOG_FILE="${LOG_DIR}/anchor-watch.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
if [ "$CRON" = "/etc/cron.d/metal-anchor-watch" ]; then
	chown deploy:deploy "$LOG_DIR" "$LOG_FILE" 2>/dev/null || true
	install -o root -g root -m 644 "$TMP" "$CRON"
	rm -f "$TMP"
else
	# test harness mode: no root ownership enforcement
	install -m 644 "$TMP" "$CRON"
	rm -f "$TMP"
fi
echo "✓ wrote $CRON (alert-only, ANCHOR_DRIVER=notify-anchor-transition.sh)"

# --- remove disabled marker(s) left by the transition ---
shopt -s nullglob
for f in "${CRON}".disabled-cycle-transition-*; do
	rm -f "$f"; echo "✓ removed disabled marker: $f"
done
shopt -u nullglob

echo
echo "── active cron (comments stripped) ──"
grep -vE '^[[:space:]]*#' "$CRON" | sed 's/^/  /'
echo
echo "Re-enabled in ALERT-ONLY mode. Next presence transition → ntfy push (no broadcast)."
echo "Anchors remain Mac-signed + manually broadcast."
echo "Log:       $LOG_FILE"
