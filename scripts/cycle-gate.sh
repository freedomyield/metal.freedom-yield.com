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
#   3  structural — scripts/lib/side-effects.sh missing. Every consumer treats
#                   any non-zero as "skip", so this is fail-closed like 1/2.
#                   Only the state-consulting paths can reach it: `observe`
#                   and `cycle-artifact-write` return green BEFORE the library
#                   is sourced, on purpose — a missing library must never be
#                   able to switch observation off.
#
# THIS SCRIPT PERFORMS NO SIDE EFFECT AND IS THEREFORE NOT GATED ON FY_LIVE.
# It reads a state file and the metalgo RPC and returns a verdict; a verdict
# is not a side effect. Seven scripts consult this gate before deciding
# whether to write or notify, so a gate that went quiet under a dry run would
# stop every recording path on transition day — the opposite of the C3 intent.
# The library is sourced solely so the state directory has ONE spelling
# (fyd_state_dir cycle) shared with resume-after-cycle-start.sh, which writes
# the very file this script reads. A second inline default here would let the
# writer and the reader drift onto different paths silently.
#
# Side-effect type semantics:
#   broadcast            — A-chain inscription (IRREV). Signature-gated: a stale
#                          dag must never be inscribed. THE ONLY genuinely gated
#                          side effect.
#   cycle-artifact-write — write to a cycle-affecting artifact / state file
#                          (cycle-history.jsonl, uptime-cycles.json,
#                          validator.json, evidence.json, renewal-ics).
#                          ALWAYS GREEN. Recording a *closed* cycle is
#                          backward-looking and can never be premature (the cycle
#                          already ended). Gating it only created the transition
#                          deadlock (node-info → uptime Job B → gen-cycle-history
#                          all deferred exactly when the just-closed cycle needed
#                          recording). See docs/audits/constitution-2026-07-04-
#                          design-stocktake.md trouble #2. Distinct log marker.
#   cycle-aware-notify   — validator-presence based notification (ntfy).
#                          Same gate logic as broadcast; distinct log marker.
#                          (Ungating this is a separate open decision — it changes
#                          anomaly-alert suppression during transitions.)
#   observe              — read-only observation. Always green.
#
# Behavior matrix (= invariants from docs/CYCLE_GATE.md):
#   observe                                   → always green
#   cycle-artifact-write                      → always green (never gated)
#   state file absent                         → green (= backward compat)
#   broadcast/cycle-aware-notify + signature matches approved → green
#   broadcast/cycle-aware-notify + signature differs         → deferred
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

# observe and cycle-artifact-write are unconditionally green — no state read, no
# RPC. Observation streams must never be gated; and recording a *closed* cycle is
# backward-looking (the cycle already ended) so it can never be premature. Gating
# cycle-artifact-write only produced the transition deadlock. Only `broadcast`
# (and, pending a separate decision, `cycle-aware-notify`) consult the signature.
case "${SIDE_EFFECT}" in
	observe|cycle-artifact-write)
		echo "[cycle-gate] ${SIDE_EFFECT} → green (never gated)" >&2
		exit 0 ;;
esac

# ---- config -----------------------------------------------------------------
# Sourced HERE, after the unconditionally-green verdicts above, so a missing
# library can never suppress observation (see the exit-3 note in the header).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FYD_LIB="${SCRIPT_DIR}/lib/side-effects.sh"
if [ ! -r "${FYD_LIB}" ]; then
	echo "[cycle-gate] ERROR: side-effects library not readable at ${FYD_LIB} → fail-closed (deferred)" >&2
	exit 3
fi
# shellcheck source=scripts/lib/side-effects.sh
. "${FYD_LIB}"
STATE_DIR="$(fyd_state_dir cycle)" || exit $?
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
# schemaVersion validation (T-9). A state file written under a different schema
# could carry legacy semantics or use different field names, and consuming it
# with the current jq paths could produce false-green decisions on stale state.
# The current file schema is version 1; other values → fail-closed.
STATE_SCHEMA_VERSION="$(jq -r '.schemaVersion // empty' "${STATE_FILE}")"
if [ -z "${STATE_SCHEMA_VERSION}" ]; then
	echo "[cycle-gate] ERROR: state file at ${STATE_FILE} missing schemaVersion → fail-closed (deferred)" >&2
	exit 1
fi
if [ "${STATE_SCHEMA_VERSION}" != "1" ]; then
	echo "[cycle-gate] ERROR: state file schemaVersion=${STATE_SCHEMA_VERSION} is not the expected 1 → fail-closed (deferred). Migrate the state file (resume-after-cycle-start.sh) before continuing." >&2
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
