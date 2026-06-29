#!/usr/bin/env bash
# cycle-gate.sh — passive gate consulted by cron scripts before executing
# cycle-dependent side effects.
#
# Architecture: 2-component design (= docs/CYCLE_GATE.md).
# This is the PASSIVE half. The ACTIVE half is resume-after-cycle-start.sh
# which writes the approval state this script reads.
#
# Args:
#   --side-effect=<type>   broadcast | cycle-artifact-write | cycle-aware-notify | observe
#
# Exit codes:
#   0  green     — side effect safe to execute
#   1  deferred  — transition window or unapproved cycle; skip the side effect
#   2  error     — usage error / invalid input
#
# Side-effect type semantics:
#   broadcast            — A-chain inscription (IRREV). post-anchor-event.sh.
#   cycle-artifact-write — write to a cycle-affecting artifact / state file
#                          (cycle-history.jsonl, uptime-cycles.json,
#                          validator.json, evidence.json, renewal-ics).
#                          Same gate logic as broadcast; distinct log marker.
#   cycle-aware-notify   — validator-presence based notification (ntfy).
#                          Same gate logic; distinct log marker.
#   observe              — read-only observation. Always green.
#
# Behavior matrix (= invariants from docs/CYCLE_GATE.md):
#   observe                                   → always green
#   state file absent                         → green (= backward compat)
#   state file present + chain signature matches approved → green
#   state file present + chain signature differs from approved → deferred
#   state file corrupt                        → fail-closed (deferred)
#   metalgo RPC unreachable                   → fail-closed (deferred)
#   validator absent from chain               → deferred
#
# State file schema (no SECRET; public-fingerprint class):
#   ${FY_STATE_DIR}/cycle-gate-state.json
#   {
#     "schemaVersion": 1,
#     "approved_cycle_signature": "<NodeID>-<startTime_epoch>",
#     "approved_dag_root_hash":   "<64-hex>",
#     "approved_at":              "<ISO 8601 UTC>"
#   }
#
# Env overrides (= test-time + ops):
#   FY_STATE_DIR     dir holding cycle-gate-state.json (default /var/lib/freedom-yield)
#   METALGO_RPC      metalgo RPC base URL          (default http://127.0.0.1:9650)
#   NODE_ID          validator NodeID              (default pinned mainnet NodeID)
#   FY_RPC_TIMEOUT   curl --max-time seconds       (default 6)

set -uo pipefail

# ---- args -------------------------------------------------------------------
SIDE_EFFECT=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--side-effect)
			[ "$#" -ge 2 ] || { echo "ERROR: --side-effect requires a value" >&2; exit 2; }
			SIDE_EFFECT="$2"; shift 2 ;;
		--side-effect=*) SIDE_EFFECT="${1#*=}"; shift ;;
		--help|-h)
			sed -n '1,/^set -uo pipefail$/p' "$0" >&2
			exit 0 ;;
		*) echo "ERROR: unknown arg '$1'" >&2; exit 2 ;;
	esac
done

case "${SIDE_EFFECT}" in
	broadcast|cycle-artifact-write|cycle-aware-notify|observe) ;;
	"")
		echo "ERROR: --side-effect=<broadcast|cycle-artifact-write|cycle-aware-notify|observe> is required" >&2
		exit 2 ;;
	*)
		echo "ERROR: invalid --side-effect '${SIDE_EFFECT}'" >&2
		exit 2 ;;
esac

# observe is unconditionally green. Observation streams must never be gated
# (= invariant from docs/CYCLE_GATE.md). This also short-circuits the RPC
# call for the most-common gate consultation type.
if [ "${SIDE_EFFECT}" = "observe" ]; then
	echo "[cycle-gate] observe → green" >&2
	exit 0
fi

# ---- config -----------------------------------------------------------------
STATE_DIR="${FY_STATE_DIR:-/var/lib/freedom-yield}"
STATE_FILE="${STATE_DIR}/cycle-gate-state.json"
METALGO_RPC="${METALGO_RPC:-http://127.0.0.1:9650}"
NODE_ID="${NODE_ID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
RPC_TIMEOUT="${FY_RPC_TIMEOUT:-6}"

# ---- backward compat: state file absent -------------------------------------
# Without a state file there is nothing to enforce. Returning green preserves
# the pre-cycle-gate behavior (= cron unmodified deploys continue to broadcast
# as before). The state file is written by resume-after-cycle-start.sh; until
# it has been run for the first time, gating is dormant by construction.
if [ ! -r "${STATE_FILE}" ]; then
	echo "[cycle-gate] state file absent at ${STATE_FILE} → green (backward compat)" >&2
	exit 0
fi

# ---- read approved state ----------------------------------------------------
if ! jq empty "${STATE_FILE}" >/dev/null 2>&1; then
	echo "[cycle-gate] ERROR: state file at ${STATE_FILE} is not valid JSON → fail-closed (deferred)" >&2
	exit 1
fi
APPROVED_SIG="$(jq -r '.approved_cycle_signature // empty' "${STATE_FILE}")"
APPROVED_DAG="$(jq -r '.approved_dag_root_hash // empty' "${STATE_FILE}")"
if [ -z "${APPROVED_SIG}" ] || [ -z "${APPROVED_DAG}" ]; then
	echo "[cycle-gate] ERROR: state file missing approved_cycle_signature or approved_dag_root_hash → fail-closed (deferred)" >&2
	exit 1
fi

# ---- query chain ------------------------------------------------------------
RPC_RESP="$(curl -sS --max-time "${RPC_TIMEOUT}" -X POST -H "Content-Type: application/json" \
	--data '{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{}}' \
	"${METALGO_RPC}/ext/bc/P" 2>/dev/null)"
RPC_RC=$?

if [ "${RPC_RC}" -ne 0 ] || [ -z "${RPC_RESP}" ]; then
	echo "[cycle-gate] ERROR: metalgo RPC unreachable (curl rc=${RPC_RC}) → fail-closed (deferred)" >&2
	exit 1
fi
if ! echo "${RPC_RESP}" | jq -e '.result.validators' >/dev/null 2>&1; then
	echo "[cycle-gate] ERROR: metalgo RPC returned unparseable response → fail-closed (deferred)" >&2
	exit 1
fi

OWN_ENTRY="$(echo "${RPC_RESP}" | jq -c --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id)')"

if [ -z "${OWN_ENTRY}" ]; then
	echo "[cycle-gate] NodeID=${NODE_ID} absent from current validators → deferred (validator absent)" >&2
	exit 1
fi

OBS_START_TIME="$(echo "${OWN_ENTRY}" | jq -r '.startTime // empty')"
if [ -z "${OBS_START_TIME}" ]; then
	echo "[cycle-gate] ERROR: own validator entry has no startTime field → fail-closed (deferred)" >&2
	exit 1
fi

# ---- compute current chain signature + compare -----------------------------
OBS_SIG="${NODE_ID}-${OBS_START_TIME}"

if [ "${OBS_SIG}" = "${APPROVED_SIG}" ]; then
	echo "[cycle-gate] ${SIDE_EFFECT} → green (approved=${APPROVED_SIG})" >&2
	exit 0
else
	echo "[cycle-gate] ${SIDE_EFFECT} → deferred (chain=${OBS_SIG} approved=${APPROVED_SIG}; operator must run resume-after-cycle-start.sh)" >&2
	exit 1
fi
