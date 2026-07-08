#!/usr/bin/env bash
# watch-anchor-events.sh — Phase α validator-transition watcher (C2 T-12).
#
# Cron-driven (recommended every 5 min, parallel to check-anomalies.sh).
# Polls the local metalgo RPC for our NodeID's presence in
# getCurrentValidators. When the presence flag transitions, invokes
# scripts/post-anchor-event.sh with the matching event_type. The watcher
# itself never broadcasts anything on chain; it only dispatches.
#
# Independence from check-anomalies.sh:
#   This script does NOT modify check-anomalies.sh — that file's sha
#   71938eda… is pinned pending authorization 4B.5.2-A. Phase α anchor
#   dispatch uses a sibling watcher with its own state file so the two
#   evolve independently.
#
# State files (in FY_STATE_DIR, default /var/lib/freedom-yield/):
#   anchor-watcher-state.json   tracks {node_id, is_present, last_check}.
#                               First run leaves is_present unset (= no
#                               transition can be inferred without a prior).
#                               Updated atomically after each poll THAT EITHER
#                               (a) detected no transition, or (b) detected a
#                               transition and the driver CONFIRMED delivery
#                               (exit 0, or exit 2 = nothing-to-do). When a
#                               transition is detected but the driver cannot
#                               confirm delivery (any other exit — see R5 /
#                               notify-anchor-transition.sh's exit contract),
#                               the state file is left untouched on purpose:
#                               is_present stays at its prior value so the
#                               same transition is re-detected — and the
#                               driver re-invoked — on the next poll, instead
#                               of the once-per-cycle signal being silently
#                               and permanently dropped by a transient
#                               notify failure at the cycle boundary.
#
# Constitution alignment:
#   - §2 #1: the metalgo RPC poll is read-only (platform.getCurrentValidators
#     with our NodeID filter), 10 s timeout, no resource-heavy queries.
#     Same call pattern that check-anomalies.sh already issues on the
#     same cron cadence — net additional metalgo load: one filtered call
#     per 5 min, well below any meaningful contribution to consensus load.
#   - §4.1 secrets: nothing is logged that wasn't already public (NodeID
#     is public; presence flag is public).
#   - §5: validator-host deploy is operator-approved.
#
# Exit codes:
#   0  success — either no transition (no-op) or transition dispatched
#   1  usage error
#   2  RPC failed (= alert via cron logging; state file not updated, next
#      tick will retry)
#   3  state-file write failed
#   4  driver invocation did not confirm delivery (= state file is
#      deliberately NOT updated — is_present stays at its prior value so
#      the same transition is re-detected and the driver re-invoked on the
#      next tick, until delivery is confirmed. See R5.)
#
# Usage:
#   watch-anchor-events.sh [--dry-run]
#     --dry-run   poll + detect transition + print the dispatch command
#                 but do not invoke post-anchor-event.sh and do not update
#                 the state file. Useful for cron-installation rehearsal.
#
# Cron snippet (= operator installs):
#   */5 * * * *  /home/deploy/metal.freedom-yield.com/scripts/watch-anchor-events.sh \
#                >> /home/deploy/metal.freedom-yield.com/logs/watch-anchor-events.log 2>&1

set -euo pipefail

# -------- args --------
DRY_RUN=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1; shift ;;
		--help|-h)
			sed -n '1,/^set -euo pipefail$/p' "$0" >&2
			exit 0
			;;
		*) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
	esac
done

# -------- config --------
NODE_ID="${NODE_ID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
METALGO_RPC="${METALGO_RPC:-http://127.0.0.1:9650}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Dispatch target on a presence transition. DETECTION/ALERT-ONLY: the default
# driver notify-anchor-transition.sh raises an ntfy alert and broadcasts nothing.
# The v2 anchor is produced by the separate signing pipeline (gen-anchor-source.sh
# → sign-anchor-event.sh → gen-anchor-receipt.sh), Mac-side; the retired
# validator-host auto-broadcast (post-anchor-event.sh) has been removed. The live
# cron also sets ANCHOR_DRIVER explicitly to the same alert-only driver.
DRIVER="${ANCHOR_DRIVER:-${SCRIPT_DIR}/notify-anchor-transition.sh}"
STATE_DIR="${FY_STATE_DIR:-/var/lib/freedom-yield}"
STATE_FILE="${STATE_DIR}/anchor-watcher-state.json"

case "${NODE_ID}" in
	NodeID-*) ;;
	*) echo "ERROR: NODE_ID must start with 'NodeID-' (got '${NODE_ID}')" >&2; exit 1 ;;
esac

if [ ! -x "${DRIVER}" ]; then
	echo "ERROR: driver not executable: ${DRIVER}" >&2; exit 1
fi
[ -d "${STATE_DIR}" ] || mkdir -p "${STATE_DIR}"

# -------- poll metalgo --------
RPC_REQ="$(jq -nc --arg id "${NODE_ID}" '{
	jsonrpc: "2.0",
	id: 1,
	method: "platform.getCurrentValidators",
	params: {subnetID: null, nodeIDs: [$id]}
}')"

RESP="$(curl -sS -X POST \
	-H 'content-type: application/json' \
	--data "${RPC_REQ}" \
	--max-time 10 \
	"${METALGO_RPC}/ext/bc/P" 2>/dev/null || true)"

if [ -z "${RESP}" ] || ! printf '%s' "${RESP}" | jq empty >/dev/null 2>&1; then
	echo "ERROR: metalgo RPC failed or returned non-JSON" >&2
	# Do NOT update state — next tick retries.
	exit 2
fi

# Check for RPC-level error.
if printf '%s' "${RESP}" | jq -e '.error' >/dev/null 2>&1; then
	ERR_MSG="$(printf '%s' "${RESP}" | jq -r '.error.message // ""')"
	echo "ERROR: metalgo RPC returned error: ${ERR_MSG}" >&2
	exit 2
fi

# Determine presence: is our NodeID listed in .result.validators[]?
COUNT="$(printf '%s' "${RESP}" \
	| jq -r --arg id "${NODE_ID}" \
		'[.result.validators[]? | select(.nodeID == $id)] | length')"
IS_PRESENT=0
[ "${COUNT}" -gt 0 ] && IS_PRESENT=1

# -------- read prior state --------
WAS_PRESENT_RAW=""
if [ -r "${STATE_FILE}" ]; then
	WAS_PRESENT_RAW="$(jq -r '.is_present // empty' "${STATE_FILE}" 2>/dev/null || true)"
fi

# Normalize: '' (= first run, no prior) | "0" | "1"
case "${WAS_PRESENT_RAW}" in
	"true"|1)  WAS_PRESENT=1 ;;
	"false"|0) WAS_PRESENT=0 ;;
	*)         WAS_PRESENT="" ;;
esac

# -------- transition detection --------
EVENT=""
if [ -n "${WAS_PRESENT}" ]; then
	if [ "${WAS_PRESENT}" = "0" ] && [ "${IS_PRESENT}" = "1" ]; then
		EVENT="cyclestart"
	elif [ "${WAS_PRESENT}" = "1" ] && [ "${IS_PRESENT}" = "0" ]; then
		EVENT="cycleend"
	fi
fi

NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -z "${EVENT}" ]; then
	if [ -z "${WAS_PRESENT}" ]; then
		echo "no-op: first run; recording is_present=${IS_PRESENT}, no transition inferred"
	else
		echo "no-op: is_present unchanged (was=${WAS_PRESENT} now=${IS_PRESENT})"
	fi
else
	echo "transition: was=${WAS_PRESENT} now=${IS_PRESENT} → event=${EVENT}"
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "DRY-RUN: would invoke ${DRIVER} --event-type=${EVENT}"
	else
		# Synchronous invocation. Exit 0 or 2 (nothing-to-do) is a CONFIRMED
		# outcome and advances state below. Any other exit means the driver
		# could not confirm delivery (see notify-anchor-transition.sh's exit
		# contract, R5) — SKIP_STATE_WRITE below leaves is_present at its
		# prior value so this same transition is re-detected and the driver
		# re-invoked on the next poll, instead of the once-per-cycle signal
		# being permanently dropped by a transient notify failure.
		DRIVER_EXIT=0
		"${DRIVER}" --event-type="${EVENT}" || DRIVER_EXIT=$?
		if [ "${DRIVER_EXIT}" -ne 0 ] && [ "${DRIVER_EXIT}" -ne 2 ]; then
			echo "ERROR: driver did not confirm delivery (exit ${DRIVER_EXIT})" >&2
			echo "NOT advancing watcher state: is_present stays '${WAS_PRESENT}' so event=${EVENT} is re-detected and re-dispatched next poll" >&2
			SKIP_STATE_WRITE=1
			LATER_EXIT=4
		fi
	fi
fi

# -------- state file update --------
# Skipped only when a transition was detected this tick and the driver
# failed to confirm delivery (see SKIP_STATE_WRITE above). Every other path
# (no transition, first run, transition + confirmed delivery, --dry-run's
# own guard) updates normally.
if [ "${DRY_RUN}" -eq 0 ] && [ "${SKIP_STATE_WRITE:-0}" -eq 0 ]; then
	if ! jq -n \
		--arg node_id "${NODE_ID}" \
		--argjson is_present "${IS_PRESENT}" \
		--arg last_check "${NOW_UTC}" \
		--arg last_event "${EVENT:-none}" \
		'{node_id: $node_id, is_present: $is_present, last_check: $last_check, last_event: $last_event}' \
		> "${STATE_FILE}.new"
	then
		echo "ERROR: failed to write ${STATE_FILE}.new" >&2; exit 3
	fi
	mv "${STATE_FILE}.new" "${STATE_FILE}"
fi

exit "${LATER_EXIT:-0}"
