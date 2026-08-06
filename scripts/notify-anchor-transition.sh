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
#     ANCHOR_NOTIFY       path to notify.sh (default: <script dir>/notify.sh).
#                         Resolved by scripts/lib/side-effects.sh, not here —
#                         the spelling and its precedence are unchanged.
#     NOTIFY_RETRY_SLEEP  seconds to wait before the single in-run retry
#                         (default: 5; tests override to 0)
#     FY_LIVE=1           REQUIRED before the alert actually reaches ntfy.
#                         Anything else is a loud dry no-op that prints one
#                         "DRY: would notify …" line and reports CONFIRMED
#                         (exit 0) to the caller (scripts/lib/side-effects.sh,
#                         C3 rollout 2026-08-06). The cron env header for
#                         metal-anchor-watch carries it; tests deliberately do
#                         not. NOTE this is a test/prod boundary and is NOT the
#                         same knob as --dry-run, which is the caller-facing
#                         rehearsal flag and stays exactly as it was.
#
#                         Reporting a suppressed send as CONFIRMED is correct
#                         ONLY because watch-anchor-events.sh gates its own
#                         state advance on the same FY_LIVE: under a dry run
#                         the send is suppressed AND the watcher baseline stays
#                         put, so the transition is re-detected next tick. The
#                         two must stay in lock step — see the CONTRACT section
#                         of scripts/lib/side-effects.sh ("a caller that turns
#                         rc 0 into a state transition must gate that state
#                         write with the same FY_LIVE").
# Exit:
#     0  alert CONFIRMED delivered (notify.sh strict-mode HTTP 2xx), or --dry-run,
#        or suppressed by a dry FY_LIVE (see above)
#     2  nothing to do (missing/unrecognized --event-type) — treated as OK by the watcher
#     3  scripts/lib/side-effects.sh missing (structural — refuse rather than run
#        an alert driver whose alerts cannot be delivered)
#     5  notify.sh failed to confirm delivery (transport / 429 / 5xx, retried once;
#        or a non-retryable 4xx / missing topic / missing notify.sh). The caller
#        (watch-anchor-events.sh) MUST NOT advance its transition state on this
#        exit, so the same cyclestart/cycleend transition is re-detected and this
#        driver re-invoked on its next poll — the once-per-cycle signal is
#        retried until it is actually delivered, instead of being silently
#        dropped on a transient ntfy outage at a cycle boundary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FYD_LIB="${SCRIPT_DIR}/lib/side-effects.sh"
if [ ! -r "$FYD_LIB" ]; then
	echo "notify-anchor-transition: FATAL: side-effects library not readable at $FYD_LIB" >&2
	exit 3
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

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

# Delivery-confirmed dispatch (reuses the notify_or_keep pattern from
# check-anomalies.sh): strict mode so a non-2xx / transport failure is
# classified rather than swallowed, one in-run retry on the retryable
# classes, and the driver's own exit communicates delivery — NOT just
# "we tried" — to the caller so it can gate its state advance on it.
#
# stdout is still discarded; stderr is NOT (it used to be). A suppressed dry
# send announces itself on stderr, and swallowing that would recreate exactly
# the silent-no-op failure the C3 rollout exists to prevent.
#
# The old "notify.sh not executable → exit 5" pre-check is gone: the library
# validates the delegate itself and returns 64. 64 is non-retryable under
# retryable_notify_rc() and lands on the same `exit 5` below, so the exit
# contract this driver publishes to watch-anchor-events.sh is unchanged.
attempt_notify() {
	local rc=0
	fyd_notify --strict "high" "$TITLE" "$MSG" >/dev/null || rc=$?
	return "$rc"
}
retryable_notify_rc() {
	case "$1" in
		2|4|5) return 0 ;;   # transport / 429 / 5xx
		*)     return 1 ;;
	esac
}

RC=0
attempt_notify || RC=$?
if [ "$RC" -ne 0 ] && retryable_notify_rc "$RC"; then
	sleep "${NOTIFY_RETRY_SLEEP:-5}"
	RC=0
	attempt_notify || RC=$?
fi

if [ "$RC" -ne 0 ]; then
	echo "notify-anchor-transition: notify.sh failed to confirm delivery (rc=${RC}); NOT confirming dispatch" >&2
	exit 5
fi

exit 0
