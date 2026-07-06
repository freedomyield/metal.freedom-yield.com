#!/usr/bin/env bash
# resume-after-cycle-start.sh — Active operator command run after a new
# validator cycle is confirmed on chain. Records the cycle-gate approval
# state for the new cycle so the passive cycle-gate.sh (cycle-aware-notify)
# recognizes the transition.
#
# v2 scope note (2026-07-06): the anchor broadcast + receipt verification are
# NO LONGER part of this script. In the v2 3-branch model the anchor is
# produced entirely by the separate signing pipeline:
#   gen-anchor-source.sh → sign-anchor-event.sh (→ bin/safe-broadcast)
#   → gen-anchor-receipt.sh (7-gate verify) → append-anchor-history.sh
# gen-anchor-receipt.sh already verifies the four v2 memos + dag_root_computed
# at receipt time, so a second post-hoc check here is redundant. The retired
# v1 Phase 3 (post-anchor-event.sh broadcast trigger) and Phase 4 (fyid1:
# receipt field-match) have been removed. This script's sole remaining job is
# to (Phase 1) confirm the new cycle on chain + published artifacts, and
# (Phase 2) write the approval state the live cycle-aware-notify gate reads.
#
# Architecture: 2-component design (= docs/CYCLE_GATE.md).
# This is the ACTIVE half. The PASSIVE half is cycle-gate.sh which reads
# the approval state this script writes.
#
# Default invocation (= model α, AI-orchestrated):
#   AI runs this on the validator host via SSH after a confirmed cycle start.
#
# Emergency fallback (= AI unavailable):
#   Operator runs this directly via SSH (= the polling logic in Phase 1
#   tolerates uncertain deploy timing):
#     ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
#       'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --apply'
#
# Phases:
#   Phase 1  verify (= RPC own-entry + anchor-source freshness + identity sig)
#   Phase 2  atomic cycle-gate-state.json write
#   Phase 3  report
#
# Args:
#   --dry-run    run Phase 1 only; emit "would do" line for Phase 2
#   --apply      execute full sequence
#
# Exit codes:
#   0   PASS (= state updated)
#       OR  --dry-run completed Phase 1 verification successfully
#       OR  idempotent skip (= this cycle already approved)
#   1   usage error
#   2   Phase 1 verification failed (= RPC unreachable, validator absent,
#                                      signature invalid, etc.)
#   3   Phase 1 polling timeout (= anchor-source.json not fresh after max wait)
#   4   Phase 2 state write failed
#
# Env overrides (= test-time + ops):
#   FY_STATE_DIR        dir holding cycle-gate-state.json
#                       default /var/lib/freedom-yield
#   METALGO_RPC         metalgo RPC base URL (default http://127.0.0.1:9650)
#   PUBLIC_BASE         Xserver base URL (default https://metal.freedom-yield.com)
#   NODE_ID             validator NodeID (default pinned mainnet NodeID)
#   FY_RPC_TIMEOUT      curl --max-time seconds (default 6)
#   FY_POLL_INTERVAL    polling interval seconds (default 30)
#   FY_POLL_MAX_SEC     max polling duration seconds (default 600 = 10 min)

set -uo pipefail

# ---- args -------------------------------------------------------------------
MODE=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--dry-run) MODE="dry-run"; shift ;;
		--apply)   MODE="apply"; shift ;;
		--help|-h)
			sed -n '1,/^set -uo pipefail$/p' "$0" >&2
			exit 0 ;;
		*) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
	esac
done

if [ -z "${MODE}" ]; then
	echo "ERROR: --dry-run or --apply is required" >&2
	exit 1
fi

# ---- config -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
STATE_DIR="${FY_STATE_DIR:-/var/lib/freedom-yield}"
STATE_FILE="${STATE_DIR}/cycle-gate-state.json"
METALGO_RPC="${METALGO_RPC:-http://127.0.0.1:9650}"
PUBLIC_BASE="${PUBLIC_BASE:-https://metal.freedom-yield.com}"
NODE_ID="${NODE_ID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
RPC_TIMEOUT="${FY_RPC_TIMEOUT:-6}"
POLL_INTERVAL="${FY_POLL_INTERVAL:-30}"
POLL_MAX_SEC="${FY_POLL_MAX_SEC:-600}"
PUBKEY_URL="${PUBKEY_URL:-${PUBLIC_BASE}/.well-known/operator-identity.pub}"

log()       { printf '[resume] %s\n' "$*" >&2; }
log_phase() { printf '\n[resume] ==== %s ====\n' "$*" >&2; }

[ -d "${STATE_DIR}" ] || mkdir -p "${STATE_DIR}"

# Temp files for fetched artifacts. Single trap covers all of them so the
# cleanup runs whether we exit at Phase 1 or Phase 2.
IDENTITY_TMP="$(mktemp -t identity.XXXXXX)"
ANCHORSRC_TMP="$(mktemp -t anchorsrc.XXXXXX)"
PUBKEY_TMP="$(mktemp -t pubkey.XXXXXX)"
SIG_TMP="$(mktemp -t sig.XXXXXX)"
ALLOWED_TMP="$(mktemp -t allowed.XXXXXX)"
trap 'rm -f "${IDENTITY_TMP}" "${ANCHORSRC_TMP}" "${PUBKEY_TMP}" "${SIG_TMP}" "${ALLOWED_TMP}"' EXIT

# ============================================================================
# Phase 1: verify
# ============================================================================
log_phase "Phase 1: verify"

# (1) Read existing approved state (= for idempotency + freshness comparison).
PRIOR_APPROVED_SIG=""
PRIOR_APPROVED_DAG=""
if [ -r "${STATE_FILE}" ] && jq empty "${STATE_FILE}" >/dev/null 2>&1; then
	PRIOR_APPROVED_SIG="$(jq -r '.approved_cycle_signature // empty' "${STATE_FILE}")"
	PRIOR_APPROVED_DAG="$(jq -r '.approved_dag_root_hash // empty' "${STATE_FILE}")"
fi
log "prior approved: signature=${PRIOR_APPROVED_SIG:-<none>} dag=${PRIOR_APPROVED_DAG:0:12}…"

# (2) Query chain for own validator entry.
log "querying metalgo RPC ..."
RPC_RESP="$(curl -sS --max-time "${RPC_TIMEOUT}" -X POST -H "Content-Type: application/json" \
	--data '{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{}}' \
	"${METALGO_RPC}/ext/bc/P" 2>/dev/null)"
RPC_RC=$?
if [ "${RPC_RC}" -ne 0 ] || [ -z "${RPC_RESP}" ]; then
	log "FAIL: metalgo RPC unreachable (curl rc=${RPC_RC})"
	exit 2
fi
if ! echo "${RPC_RESP}" | jq -e '.result.validators' >/dev/null 2>&1; then
	log "FAIL: metalgo RPC returned unparseable response"
	exit 2
fi
OWN_ENTRY="$(echo "${RPC_RESP}" | jq -c --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id)')"
if [ -z "${OWN_ENTRY}" ]; then
	log "FAIL: NodeID=${NODE_ID} not in current validators (= AddValidator tx not yet observed?)"
	exit 2
fi
OBS_START_TIME="$(echo "${OWN_ENTRY}" | jq -r '.startTime // empty')"
OBS_END_TIME="$(echo "${OWN_ENTRY}" | jq -r '.endTime // empty')"
if [ -z "${OBS_START_TIME}" ] || [ -z "${OBS_END_TIME}" ]; then
	log "FAIL: own validator entry missing startTime or endTime"
	exit 2
fi
OBS_SIG="${NODE_ID}-${OBS_START_TIME}"
log "chain reports: startTime=${OBS_START_TIME} endTime=${OBS_END_TIME}"
log "computed cycle signature: ${OBS_SIG}"

# (3) Idempotency check.
if [ -n "${PRIOR_APPROVED_SIG}" ] && [ "${PRIOR_APPROVED_SIG}" = "${OBS_SIG}" ]; then
	log "INFO: this cycle (${OBS_SIG}) is already approved; nothing to do."
	log "PASS: idempotent skip."
	exit 0
fi

# (4) Fail-fast: endTime must be in the future. A past endTime would mean we
#     are trying to approve an already-closed cycle (= no new cycle yet, or
#     the chain entry is stale).
NOW="$(date +%s)"
if [ "${OBS_END_TIME}" -lt "${NOW}" ]; then
	log "FAIL: chain endTime=${OBS_END_TIME} is in the past (now=${NOW}) — not a fresh cycle"
	exit 2
fi

# (5) Poll Xserver anchor-source.json until dag_root_computed differs from the
#     prior approved value (= the new cycle's v2 3-branch DAG source has been
#     regenerated + published). Default invocation (AI-orchestrated) finds
#     fresh data on attempt #1; the polling loop only matters for the emergency
#     fallback path where the operator runs this without knowing exact timing.
log "polling ${PUBLIC_BASE}/api/anchor-source.json for fresh dag_root_computed (interval=${POLL_INTERVAL}s max=${POLL_MAX_SEC}s)"
POLL_DEADLINE=$(( NOW + POLL_MAX_SEC ))
FRESH_FOUND=0
ATTEMPT=0
while [ "$(date +%s)" -lt "${POLL_DEADLINE}" ]; do
	ATTEMPT=$((ATTEMPT + 1))
	if curl -sSLf -o "${ANCHORSRC_TMP}" --max-time "${RPC_TIMEOUT}" \
			"${PUBLIC_BASE}/api/anchor-source.json" 2>/dev/null \
		&& jq empty "${ANCHORSRC_TMP}" >/dev/null 2>&1; then
		CUR_DAG="$(jq -r '.dag_root_computed // empty' "${ANCHORSRC_TMP}")"
		if [ -n "${CUR_DAG}" ] && [ "${CUR_DAG}" != "${PRIOR_APPROVED_DAG}" ]; then
			log "  attempt ${ATTEMPT}: anchor-source.json dag_root_computed=${CUR_DAG:0:12}… (fresh)"
			FRESH_FOUND=1
			break
		else
			log "  attempt ${ATTEMPT}: anchor-source.json dag_root_computed unchanged (still=${CUR_DAG:0:12}…)"
		fi
	else
		log "  attempt ${ATTEMPT}: fetch / parse failed; retrying"
	fi
	sleep "${POLL_INTERVAL}"
done
if [ "${FRESH_FOUND}" -ne 1 ]; then
	log "FAIL: polling timeout after ${POLL_MAX_SEC}s — anchor-source.json still stale (prior dag=${PRIOR_APPROVED_DAG:0:12}…)"
	exit 3
fi
NEW_DAG="$(jq -r '.dag_root_computed // empty' "${ANCHORSRC_TMP}")"

# (6) Verify the operator identity signature on identity.json (= ssh-keygen -Y
#     verify against /.well-known/operator-identity.pub). This is an integrity
#     gate: we only approve a cycle whose published identity manifest is validly
#     signed by the operator identity key. identity.json no longer carries the
#     DAG root in v2 (that lives in anchor-source.json), so we read no dag field
#     from it here — the signature check is the point.
log "verifying identity.json signature ..."
IDENTITY_URL="${PUBLIC_BASE}/api/identity.json"
SIG_URL="${PUBLIC_BASE}/api/identity.json.sig"
if ! curl -sSLf -o "${IDENTITY_TMP}" --max-time "${RPC_TIMEOUT}" "${IDENTITY_URL}"; then
	log "FAIL: cannot fetch identity.json from ${IDENTITY_URL}"
	exit 2
fi
if ! jq empty "${IDENTITY_TMP}" >/dev/null 2>&1; then
	log "FAIL: identity.json is not valid JSON"
	exit 2
fi
if ! curl -sSLf -o "${PUBKEY_TMP}" --max-time "${RPC_TIMEOUT}" "${PUBKEY_URL}"; then
	log "FAIL: cannot fetch pubkey from ${PUBKEY_URL}"
	exit 2
fi
if ! curl -sSLf -o "${SIG_TMP}" --max-time "${RPC_TIMEOUT}" "${SIG_URL}"; then
	log "FAIL: cannot fetch signature from ${SIG_URL}"
	exit 2
fi
PRINCIPAL="$(jq -r '.verification.principal // "freedom-yield"' "${IDENTITY_TMP}")"
NAMESPACE="$(jq -r '.verification.namespace // "freedom-yield/validator-identity"' "${IDENTITY_TMP}")"
printf '%s %s\n' "${PRINCIPAL}" "$(cat "${PUBKEY_TMP}")" > "${ALLOWED_TMP}"
if ! ssh-keygen -Y verify \
		-f "${ALLOWED_TMP}" \
		-I "${PRINCIPAL}" \
		-n "${NAMESPACE}" \
		-s "${SIG_TMP}" < "${IDENTITY_TMP}" >/dev/null 2>&1; then
	log "FAIL: identity.json signature verification failed"
	exit 2
fi
log "  signature OK (principal=${PRINCIPAL} namespace=${NAMESPACE})"
log "Phase 1 PASS"

# ============================================================================
# Phase 2: atomic state write
# ============================================================================
log_phase "Phase 2: atomic state write"
if [ "${MODE}" = "dry-run" ]; then
	log "DRY-RUN: would write cycle-gate-state.json with:"
	log "  approved_cycle_signature=${OBS_SIG}"
	log "  approved_dag_root_hash=${NEW_DAG}"
	log "Phase 2 SKIPPED (dry-run)"
else
	STATE_TMP="${STATE_FILE}.new"
	NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	if ! jq -n \
			--arg sig "${OBS_SIG}" \
			--arg dag "${NEW_DAG}" \
			--arg ts  "${NOW_ISO}" \
			'{
				schemaVersion: 1,
				approved_cycle_signature: $sig,
				approved_dag_root_hash:   $dag,
				approved_at:              $ts
			}' > "${STATE_TMP}"; then
		log "FAIL: jq failed to compose state file"
		exit 4
	fi
	if ! mv "${STATE_TMP}" "${STATE_FILE}"; then
		log "FAIL: mv failed for ${STATE_FILE}"
		exit 4
	fi
	chmod 644 "${STATE_FILE}"
	log "wrote ${STATE_FILE}"
	log "Phase 2 PASS"
fi

# ============================================================================
# Phase 3: report
# ============================================================================
log_phase "Phase 3: report"
if [ "${MODE}" = "dry-run" ]; then
	log "DRY-RUN summary: Phase 1 verification PASS. Run --apply to write state."
	exit 0
else
	log "✓ ALL PHASES PASS"
	log "  cycle signature    : ${OBS_SIG}"
	log "  dag_root_computed  : ${NEW_DAG}"
	log "  → the cycle's on-chain anchor is produced + verified by the signing"
	log "    pipeline (sign-anchor-event.sh → gen-anchor-receipt.sh); this script"
	log "    only records cycle-gate approval state."
	exit 0
fi
