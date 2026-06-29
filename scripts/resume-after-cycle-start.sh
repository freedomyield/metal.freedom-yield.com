#!/usr/bin/env bash
# resume-after-cycle-start.sh — Active operator command run after a new
# validator cycle is confirmed on chain. Updates the cycle-gate approval
# state, triggers the anchor broadcast for the new cycle, and runs the
# 7-condition PASS check on the resulting receipt.
#
# Architecture: 2-component design (= docs/CYCLE_GATE.md).
# This is the ACTIVE half. The PASSIVE half is cycle-gate.sh which reads
# the approval state this script writes.
#
# Default invocation (= model α, AI-orchestrated):
#   AI runs this on the validator host via SSH after completing all
#   prerequisites (= Mac gen-identity.sh + git push + GitHub Actions deploy).
#
# Emergency fallback (= AI unavailable):
#   Operator runs this directly via SSH (= the polling logic in Phase 1
#   tolerates uncertain deploy timing):
#     ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
#       'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --apply'
#
# Phases:
#   Phase 1  verify (= RPC + identity.json + cycles-history.json + dag match)
#   Phase 2  atomic cycle-gate-state.json write
#   Phase 3  post-anchor-event.sh sync trigger
#   Phase 4  7-condition PASS check (= invariant 3 from
#            [[phase-alpha-anchor-completion-2026-07-04]])
#   Phase 5  report
#
# Args:
#   --dry-run    run Phase 1 only; emit "would do" lines for Phases 2-4
#   --apply      execute full sequence
#
# Exit codes:
#   0   PASS (= state updated, broadcast complete, 7-condition PASS)
#       OR  --dry-run completed Phase 1 verification successfully
#       OR  idempotent skip (= this cycle already approved)
#   1   usage error
#   2   Phase 1 verification failed (= RPC unreachable, validator absent,
#                                      signature invalid, dag mismatch, etc.)
#   3   Phase 1 polling timeout (= identity.json not fresh after max wait)
#   4   Phase 2 state write failed
#   5   Phase 3 post-anchor-event.sh failed
#   6   Phase 4 7-condition check failed
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
#   POSTANCHOR          path to post-anchor-event.sh (default <SCRIPT_DIR>/post-anchor-event.sh)
#                       Test harnesses set this to a stub that emits expected
#                       success / failure without invoking the real broadcaster.

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
POSTANCHOR="${POSTANCHOR:-${SCRIPT_DIR}/post-anchor-event.sh}"

log()       { printf '[resume] %s\n' "$*" >&2; }
log_phase() { printf '\n[resume] ==== %s ====\n' "$*" >&2; }

[ -d "${STATE_DIR}" ] || mkdir -p "${STATE_DIR}"

# Temp files for fetched artifacts. Single trap covers all of them so the
# cleanup runs whether we exit at Phase 1 or Phase 4.
IDENTITY_TMP="$(mktemp -t identity.XXXXXX)"
CYCLES_TMP="$(mktemp -t cycles.XXXXXX)"
PUBKEY_TMP="$(mktemp -t pubkey.XXXXXX)"
SIG_TMP="$(mktemp -t sig.XXXXXX)"
ALLOWED_TMP="$(mktemp -t allowed.XXXXXX)"
RECEIPT_TMP="$(mktemp -t receipt.XXXXXX)"
trap 'rm -f "${IDENTITY_TMP}" "${CYCLES_TMP}" "${PUBKEY_TMP}" "${SIG_TMP}" "${ALLOWED_TMP}" "${RECEIPT_TMP}"' EXIT

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

# (5) Poll Xserver identity.json until dag_root_hash differs from the prior
#     approved value (= GitHub Actions deploy has propagated the freshly
#     signed identity.json). Default invocation (AI-orchestrated) finds fresh
#     data on attempt #1; the polling loop only matters for the emergency
#     fallback path where the operator runs this without knowing exact
#     deploy timing.
log "polling ${PUBLIC_BASE}/api/identity.json for fresh dag_root_hash (interval=${POLL_INTERVAL}s max=${POLL_MAX_SEC}s)"
POLL_DEADLINE=$(( NOW + POLL_MAX_SEC ))
FRESH_FOUND=0
ATTEMPT=0
while [ "$(date +%s)" -lt "${POLL_DEADLINE}" ]; do
	ATTEMPT=$((ATTEMPT + 1))
	if curl -sSLf -o "${IDENTITY_TMP}" --max-time "${RPC_TIMEOUT}" \
			"${PUBLIC_BASE}/api/identity.json" 2>/dev/null \
		&& jq empty "${IDENTITY_TMP}" >/dev/null 2>&1; then
		CUR_DAG="$(jq -r '.dag_root_hash // empty' "${IDENTITY_TMP}")"
		if [ -n "${CUR_DAG}" ] && [ "${CUR_DAG}" != "${PRIOR_APPROVED_DAG}" ]; then
			log "  attempt ${ATTEMPT}: identity.json dag_root_hash=${CUR_DAG:0:12}… (fresh)"
			FRESH_FOUND=1
			break
		else
			log "  attempt ${ATTEMPT}: identity.json dag_root_hash unchanged (still=${CUR_DAG:0:12}…)"
		fi
	else
		log "  attempt ${ATTEMPT}: fetch / parse failed; retrying"
	fi
	sleep "${POLL_INTERVAL}"
done
if [ "${FRESH_FOUND}" -ne 1 ]; then
	log "FAIL: polling timeout after ${POLL_MAX_SEC}s — identity.json still stale (prior dag=${PRIOR_APPROVED_DAG:0:12}…)"
	exit 3
fi
NEW_DAG="$(jq -r '.dag_root_hash // empty' "${IDENTITY_TMP}")"

# (6) Verify identity.json signature (= ssh-keygen -Y verify against
#     /.well-known/operator-identity.pub).
log "verifying identity.json signature ..."
SIG_URL="${PUBLIC_BASE}/api/identity.json.sig"
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

# (7) Fetch cycles-history.json and verify it agrees on dag_root_hash with
#     identity.json. They are independently produced by gen-identity.sh and
#     post-anchor-event.sh consumes the latter; this cross-check catches
#     deploy-time drift between the two artifacts.
log "fetching cycles-history.json ..."
if ! curl -sSLf -o "${CYCLES_TMP}" --max-time "${RPC_TIMEOUT}" \
		"${PUBLIC_BASE}/api/cycles-history.json"; then
	log "FAIL: cannot fetch ${PUBLIC_BASE}/api/cycles-history.json"
	exit 2
fi
if ! jq empty "${CYCLES_TMP}" >/dev/null 2>&1; then
	log "FAIL: cycles-history.json is not valid JSON"
	exit 2
fi
CYCLES_DAG="$(jq -r '.dag_root_hash // empty' "${CYCLES_TMP}")"
if [ "${CYCLES_DAG}" != "${NEW_DAG}" ]; then
	log "FAIL: dag_root_hash mismatch (identity.json=${NEW_DAG} cycles-history.json=${CYCLES_DAG})"
	exit 2
fi
CY_LEAF_COUNT="$(jq -r '.branches.cycles.leaf_count // 0' "${CYCLES_TMP}")"
log "  dag_root_hash consistent across identity.json and cycles-history.json"
log "  cycles branch leaf_count=${CY_LEAF_COUNT}"
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
# Phase 3: post-anchor-event.sh sync trigger
# ============================================================================
log_phase "Phase 3: post-anchor-event.sh trigger"
NEW_CYCLE_N=$((CY_LEAF_COUNT + 1))
if [ "${MODE}" = "dry-run" ]; then
	log "DRY-RUN: would invoke ${POSTANCHOR} --event-type cyclestart --cycle-n ${NEW_CYCLE_N}"
	log "Phase 3 SKIPPED (dry-run)"
else
	if [ ! -x "${POSTANCHOR}" ]; then
		log "FAIL: post-anchor-event.sh not executable at ${POSTANCHOR}"
		exit 5
	fi
	# cycle_n derivation: cycles branch leaf_count + 1 (= the in-progress
	# cycle that just started). post-anchor-event.sh consumes this as the
	# canonical caller input for trigger_reference.cycle_n.
	log "invoking ${POSTANCHOR} --event-type cyclestart --cycle-n ${NEW_CYCLE_N}"
	POSTANCHOR_RC=0
	"${POSTANCHOR}" --event-type cyclestart --cycle-n "${NEW_CYCLE_N}" || POSTANCHOR_RC=$?
	case "${POSTANCHOR_RC}" in
		0)
			log "Phase 3 PASS (anchor broadcast complete)" ;;
		2)
			log "INFO: post-anchor-event.sh reported no-op (= dag_root_hash unchanged since last anchor); treating as PASS"
			log "Phase 3 PASS (no-op)" ;;
		*)
			log "FAIL: post-anchor-event.sh exited ${POSTANCHOR_RC}"
			exit 5 ;;
	esac
fi

# ============================================================================
# Phase 4: 7-condition PASS check
# ============================================================================
log_phase "Phase 4: 7-condition PASS check"
if [ "${MODE}" = "dry-run" ]; then
	log "DRY-RUN: would verify 7 conditions against fresh anchor-receipt.json"
	log "Phase 4 SKIPPED (dry-run)"
else
	if ! curl -sSLf -o "${RECEIPT_TMP}" --max-time "${RPC_TIMEOUT}" \
			"${PUBLIC_BASE}/api/anchor-receipt.json"; then
		log "FAIL: cannot fetch anchor-receipt.json"
		exit 6
	fi
	if ! jq empty "${RECEIPT_TMP}" >/dev/null 2>&1; then
		log "FAIL: anchor-receipt.json is not valid JSON"
		exit 6
	fi
	RX_TX_ID="$(jq -r '.anchor.tx_id // empty'             "${RECEIPT_TMP}")"
	RX_MEMO="$(jq -r '.memo // empty'                       "${RECEIPT_TMP}")"
	RX_ACTOR="$(jq -r '.signing_actor // empty'             "${RECEIPT_TMP}")"
	RX_PERM="$(jq -r '.signing_permission // empty'         "${RECEIPT_TMP}")"
	RX_DAG="$(jq -r '.dag_root_hash // empty'               "${RECEIPT_TMP}")"
	RX_EXPL="$(jq -r '.anchor.explorer_url // empty'        "${RECEIPT_TMP}")"
	RX_SCHEMA="$(jq -r '.["$schema"] // empty'              "${RECEIPT_TMP}")"

	PASS=0
	FAILS=()
	chk() {
		local label="$1" ok="$2" actual="$3"
		if [ "${ok}" = "1" ]; then
			log "  ✓ ${label} (${actual})"
			PASS=$((PASS + 1))
		else
			log "  ✗ ${label} (got: ${actual})"
			FAILS+=("${label}")
		fi
	}

	# C1: tx_id present
	[ -n "${RX_TX_ID}" ] && chk "C1 tx_id present"            1 "${RX_TX_ID}" \
	                     || chk "C1 tx_id present"            0 "(empty)"
	# C2: memo == fyid1:<dag>
	EXPECTED_MEMO="fyid1:${NEW_DAG}"
	[ "${RX_MEMO}" = "${EXPECTED_MEMO}" ] \
		&& chk "C2 memo == fyid1:<dag>"   1 "${RX_MEMO}" \
		|| chk "C2 memo == fyid1:<dag>"   0 "${RX_MEMO} (expected ${EXPECTED_MEMO})"
	# C3: signing_actor in {metalfreedom, freedomyield}
	case "${RX_ACTOR}" in
		metalfreedom|freedomyield) chk "C3 signing_actor"        1 "${RX_ACTOR}" ;;
		*)                          chk "C3 signing_actor"        0 "${RX_ACTOR}" ;;
	esac
	# C4: signing_permission == anchor
	[ "${RX_PERM}" = "anchor" ] \
		&& chk "C4 signing_permission == anchor"  1 "${RX_PERM}" \
		|| chk "C4 signing_permission == anchor"  0 "${RX_PERM}"
	# C5: dag_root_hash matches
	[ "${RX_DAG}" = "${NEW_DAG}" ] \
		&& chk "C5 dag_root_hash matches"         1 "${RX_DAG}" \
		|| chk "C5 dag_root_hash matches"         0 "${RX_DAG} (expected ${NEW_DAG})"
	# C6: schema field present (= AJV validation already enforced by
	#     post-anchor-event.sh; here we just confirm the URL is present)
	[ -n "${RX_SCHEMA}" ] \
		&& chk "C6 schema field present"          1 "${RX_SCHEMA}" \
		|| chk "C6 schema field present"          0 "(missing)"
	# C7: explorer URL reachable
	if [ -n "${RX_EXPL}" ]; then
		EXPL_CODE="$(curl -sSI -o /dev/null -w "%{http_code}" --max-time "${RPC_TIMEOUT}" "${RX_EXPL}" 2>/dev/null)"
		case "${EXPL_CODE}" in
			200|301|302) chk "C7 explorer URL reachable" 1 "HTTP ${EXPL_CODE} @ ${RX_EXPL}" ;;
			*)            chk "C7 explorer URL reachable" 0 "HTTP ${EXPL_CODE:-no-response} @ ${RX_EXPL}" ;;
		esac
	else
		chk "C7 explorer URL reachable" 0 "(empty explorer_url)"
	fi

	log ""
	log "Phase 4: ${PASS}/7 conditions PASS"
	if [ "${PASS}" -ne 7 ]; then
		log "FAIL: 7-condition check did not PASS — missing: ${FAILS[*]:-<none>}"
		exit 6
	fi
fi

# ============================================================================
# Phase 5: report
# ============================================================================
log_phase "Phase 5: report"
if [ "${MODE}" = "dry-run" ]; then
	log "DRY-RUN summary: Phase 1 verification PASS. Run --apply to execute."
	exit 0
else
	log "✓ ALL PHASES PASS"
	log "  cycle signature : ${OBS_SIG}"
	log "  dag_root_hash   : ${NEW_DAG}"
	log "  cycle leaf_count: ${CY_LEAF_COUNT}"
	log "  cycle_n         : ${NEW_CYCLE_N}"
	log "  → next operator step: visually verify the explorer URL above on the XPR explorer."
	exit 0
fi
