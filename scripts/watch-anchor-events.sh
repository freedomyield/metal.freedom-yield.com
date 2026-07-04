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
#                               Updated atomically after each poll regardless
#                               of dispatch outcome (= prevents duplicate
#                               dispatch on the same transition).
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
#   4  driver invocation failed (= state file IS updated to prevent
#      re-dispatch storm; the driver has its own idempotency on
#      LAST_ANCHORED_ROOT, but its exit code is surfaced for alerting)
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
# Dispatch target on a presence transition. Env-overridable so the cron can point
# at notify-anchor-transition.sh (DETECTION/ALERT-ONLY) under Mac-only signing,
# where post-anchor-event.sh's Hetzner-side auto-broadcast can never sign the
# Mac-held anchor key. Default preserved for backward compat / other callers.
DRIVER="${ANCHOR_DRIVER:-${SCRIPT_DIR}/post-anchor-event.sh}"
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
		# Synchronous invocation. post-anchor-event.sh has its own
		# idempotency on LAST_ANCHORED_ROOT, so even if the watcher's
		# state-file update below fails, a future re-dispatch of the
		# same transition is a no-op at the driver level (exit 2).
		DRIVER_EXIT=0
		"${DRIVER}" --event-type="${EVENT}" || DRIVER_EXIT=$?
		if [ "${DRIVER_EXIT}" -ne 0 ] && [ "${DRIVER_EXIT}" -ne 2 ]; then
			echo "ERROR: driver returned non-zero exit ${DRIVER_EXIT}" >&2
			# Update state anyway (= record what we observed); the driver's
			# own state file will retry the broadcast on the next call.
			LATER_EXIT=4
		fi
	fi
fi

# -------- state file update --------
if [ "${DRY_RUN}" -eq 0 ]; then
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
