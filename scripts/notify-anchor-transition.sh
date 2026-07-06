#!/usr/bin/env bash
# notify-anchor-transition.sh — DETECTION / ALERT-ONLY driver for watch-anchor-events.sh.
#
# On a validator presence transition (cyclestart / cycleend), fires an ntfy push
# telling the operator to run the MANUAL anchor from their Mac. This is the correct
# driver under Mac-only signing: the metalfreedom@anchor key is NOT on this validator
# host, so anchors are composed here but SIGNED + BROADCAST from the operator's Mac.
#
# BROADCASTS NOTHING. Invokes no sign-anchor-event / safe-broadcast / proton. Writes
# no anchor-pending marker (so it can never strand a later manual anchor at exit 8).
# Replaces the legacy post-anchor-event.sh driver, which chained to the v2-incompatible
# signer and, being validator-host-side, could never sign a Mac-only key. See memory/
# project_cycle3_anchor_broadcast_complete_20260704.md (findings A + B) for why the
# The validator host auto-broadcast path is architecturally stranded under Mac-only signing.
#
# Wiring: set ANCHOR_DRIVER=<this script> in /etc/cron.d/metal-anchor-watch so
# watch-anchor-events.sh dispatches here instead of post-anchor-event.sh.
#
# Interface (called by watch-anchor-events.sh):
#     notify-anchor-transition.sh --event-type=<cyclestart|cycleend> [--cycle-n=<n>] [--dry-run]
# Env:
#     ANCHOR_NOTIFY   path to notify.sh (default: <script dir>/notify.sh)
# Exit:
#     0  alert dispatched (best-effort; a notify.sh failure is logged, non-fatal)
#     2  nothing to do (missing/unrecognized --event-type) — treated as OK by the watcher
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="${ANCHOR_NOTIFY:-${SCRIPT_DIR}/notify.sh}"

EVENT_TYPE=""
DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--event-type=*) EVENT_TYPE="${arg#*=}" ;;
		--cycle-n=*)    : ;;   # tolerated, unused (this is a presence-only driver)
		--dry-run)      DRY_RUN=1 ;;
		*)              : ;;   # tolerate unknown flags for forward-compat
	esac
done

case "$EVENT_TYPE" in
	cyclestart) HEADLINE="cycle START detected — validator entered the active set" ;;
	cycleend)   HEADLINE="cycle END detected — validator left the active set" ;;
	"")  echo "notify-anchor-transition: no --event-type given; nothing to do" >&2; exit 2 ;;
	*)   echo "notify-anchor-transition: unrecognized --event-type='${EVENT_TYPE}'; nothing to do" >&2; exit 2 ;;
esac

TITLE="🔗 Anchor: manual action required"
MSG="${HEADLINE}. Metal A-chain anchor is signed on the operator Mac only — this validator host holds no anchor key and will NOT broadcast. Run the manual anchor: compose on the host, then sign + broadcast from the Mac (see the anchor runbook)."

if [ "$DRY_RUN" -eq 1 ]; then
	echo "DRY-RUN: would notify [high] \"${TITLE}\": ${MSG}"
	exit 0
fi

if [ -x "$NOTIFY" ]; then
	bash "$NOTIFY" "high" "$TITLE" "$MSG" || echo "notify-anchor-transition: notify.sh returned non-zero (non-fatal)" >&2
else
	echo "notify-anchor-transition: notify.sh not executable at ${NOTIFY}" >&2
fi
exit 0
