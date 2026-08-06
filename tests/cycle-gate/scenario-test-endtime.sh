#!/usr/bin/env bash
# tests/cycle-gate/scenario-test-endtime.sh
#
# Real-time scenario test: verify all 8 cycle-related cron scripts auto-stop
# at the specified endTime.
#
# This test matches the operator's mental model of "set endTime → wait → see
# crons stop". It exercises the full pipeline:
#
#   1. set up cycle-gate-state.json approved for current cycle signature
#   2. start a time-aware mock RPC that serves "validator present" before
#      endTime and "validator absent" at/after endTime
#   3. Phase A — run all 8 cycle scripts NOW (= before endTime) and verify
#      none of them prints a "deferred by cycle-gate" log (= gate green)
#   4. wait until endTime + 30 sec cushion
#   5. Phase B — run all 8 cycle scripts (= after endTime) and verify all of
#      them print a "deferred by cycle-gate" / "suppressed" log (= gate
#      deferred, scripts skip)
#
# Usage:
#   bash scenario-test-endtime.sh <ENDTIME_UNIX>
#
# Output: log lines to stdout. Exits 0 on full PASS, non-zero on any FAIL.

set -u

ENDTIME_UNIX="${1:?ENDTIME_UNIX argument required (= unix epoch seconds)}"
NOW=$(date +%s)
WAIT_TO=$((ENDTIME_UNIX + 30))
REMAINING=$((WAIT_TO - NOW))

if [ "${REMAINING}" -le 0 ]; then
	echo "ERROR: ENDTIME_UNIX (${ENDTIME_UNIX}) is already in the past; this test needs future endTime" >&2
	exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="${TEST_DIR}/fixtures"

# macOS flock shim PATH (= same pattern as run-tests.sh)
if ! command -v flock >/dev/null 2>&1; then
	export PATH="${TEST_DIR}/bin:${PATH}"
fi

# --- find a free port + start time-aware mock RPC ---
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
python3 "${TEST_DIR}/mock-rpc-timed.py" "${PORT}" "${ENDTIME_UNIX}" >/dev/null 2>&1 &
MOCK_PID=$!

cleanup() {
	[ -n "${MOCK_PID:-}" ] && kill "${MOCK_PID}" 2>/dev/null
	rm -rf "${TMP_STATE_DIR:-/nonexistent}" "${TMP_REPO_BASE:-/nonexistent}"
}
trap cleanup EXIT

# wait for mock to be ready
for _ in 1 2 3 4 5; do
	if curl -sS -o /dev/null -w "%{http_code}" -X POST -d '{}' \
		"http://127.0.0.1:${PORT}/ext/bc/P" 2>/dev/null | grep -qE '^(200|404|500)$'; then
		break
	fi
	sleep 0.2
done

# --- set up state file + tmp repo base ---
TMP_STATE_DIR="$(mktemp -d -t scen_state.XXXXXX)"
TMP_REPO_BASE="$(mktemp -d -t scen_repo.XXXXXX)"
mkdir -p "${TMP_REPO_BASE}/public/api" "${TMP_REPO_BASE}/scripts" "${TMP_REPO_BASE}/state"

# approved cycle signature matches chain when validator is present
cat > "${TMP_STATE_DIR}/cycle-gate-state.json" <<EOF
{
  "schemaVersion": 1,
  "approved_cycle_signature": "NodeID-TEST123-1700000000",
  "approved_dag_root_hash": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
  "approved_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# symlink cycle-gate + the 7 cycle scripts into tmp scripts dir so REPO_BASE
# isolation works correctly.
for s in cycle-gate.sh gen-cycle-history.sh \
		 uptime-history.sh gen-evidence.sh gen-renewal-ics.sh \
		 node-info.sh check-anomalies.sh daily-status.sh; do
	ln -s "${REPO_ROOT}/scripts/${s}" "${TMP_REPO_BASE}/scripts/${s}"
done
# check-anomalies.sh / daily-status.sh source scripts/lib/side-effects.sh
# relative to the repo root they are invoked from (C3 rollout, 2026-08-06) and
# refuse to run without it, so the isolated REPO_BASE needs it too. FY_LIVE is
# deliberately NOT set anywhere in this scenario: it asserts the cycle-gate
# DEFERRAL markers, and the scripts must reach their gate consultation without
# performing a single production side effect on the way.
mkdir -p "${TMP_REPO_BASE}/scripts/lib"
ln -s "${REPO_ROOT}/scripts/lib/side-effects.sh" "${TMP_REPO_BASE}/scripts/lib/side-effects.sh"

# Minimal fixture data so scripts that read these don't crash before
# reaching their cycle-gate consultation.
cat > "${TMP_REPO_BASE}/public/api/validator.json" <<'VALJSON'
{
  "nodeId": "NodeID-TEST123",
  "startTime": 1700000000,
  "endTime": 9999999999,
  "uptime": { "network": 99.5 },
  "stake": { "self": "5900", "totalReceived": "0" },
  "bootstrap": { "pChain": true, "xChain": true, "cChain": true },
  "delegationFee": { "percent": "3.0" },
  "observedAt": "2026-06-29T00:00:00Z"
}
VALJSON
cat > "${TMP_REPO_BASE}/public/api/server-status.json" <<'STATJSON'
{
  "host": { "cpu": { "usedPercent": 10 }, "memory": { "usedPercent": 20 }, "disk": { "usedPercent": 30 } },
  "metalgo": { "peerCount": 100, "containerStatus": "running" },
  "caddy": { "containerStatus": "running" }
}
STATJSON
echo '{"cycles":[]}' > "${TMP_REPO_BASE}/public/api/uptime-cycles.json"
echo '{"incidents":[]}' > "${TMP_REPO_BASE}/public/api/incidents.json"

ENV_BASE=(
	FY_STATE_DIR="${TMP_STATE_DIR}"
	METALGO_RPC="http://127.0.0.1:${PORT}"
	METALGO_API="http://127.0.0.1:${PORT}"
	PUBLIC_BASE="http://127.0.0.1:${PORT}"
	NODE_ID="NodeID-TEST123"
	FY_RPC_TIMEOUT=3
	REPO_BASE="${TMP_REPO_BASE}"
	REPO_ROOT="${TMP_REPO_BASE}"
	UPTIME_STATE_DIR="${TMP_REPO_BASE}/state"
	ANOMALY_STATE_DIR="${TMP_REPO_BASE}/state"
)

# Scripts to test (all take no args).
SIMPLE_SCRIPTS=(
	gen-cycle-history.sh
	uptime-history.sh
	gen-evidence.sh
	gen-renewal-ics.sh
	node-info.sh
	check-anomalies.sh
	daily-status.sh
)

# --- run one script and return its stderr; treat any exit code as informational ---
# Args after script name are passed to the script itself.
run_one() {
	local script="$1"
	shift
	env "${ENV_BASE[@]}" \
		bash "${TMP_REPO_BASE}/scripts/${script}" "$@" 2>&1 || true
}

# --- run all 8 scripts; return aggregated stderr ---
# Provide minimal env shims so each script reaches its gate check before
# erroring on missing operational config (= the gate marker is what we
# assert on; per-script downstream errors after the gate are out of scope).
run_all() {
	local label="$1"
	for s in "${SIMPLE_SCRIPTS[@]}"; do
		echo "--- $label: $s ---"
		run_one "$s" | sed 's/^/    /'
	done
}

# --- Phase A: before endTime ---
NOW=$(date +%s)
ENDTIME_JST=$(TZ=Asia/Tokyo date -r "${ENDTIME_UNIX}" '+%Y-%m-%d %H:%M:%S JST')
NOW_JST=$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S JST')
echo "================================================================"
echo "scenario test: endTime = ${ENDTIME_JST} (= unix ${ENDTIME_UNIX})"
echo "starting Phase A at ${NOW_JST}"
echo "  expecting: all 8 cycle scripts proceed normally (gate green)"
echo "================================================================"

PHASE_A_OUT="$(mktemp -t phase_a.XXXXXX)"
run_all "PhaseA" > "${PHASE_A_OUT}" 2>&1

# Count "deferred" log markers in Phase A — expect ZERO
PHASE_A_DEFERRED=$(grep -cE "deferred by cycle-gate|cycle-related alerts suppressed|skip digest push" "${PHASE_A_OUT}" || true)
echo ""
echo "Phase A summary:"
echo "  total 'deferred / suppressed / skip' markers: ${PHASE_A_DEFERRED}"
if [ "${PHASE_A_DEFERRED}" -eq 0 ]; then
	echo "  ✓ PASS Phase A — all 8 scripts proceeded (no deferred markers)"
	PHASE_A_PASS=1
else
	echo "  ✗ FAIL Phase A — some scripts deferred unexpectedly"
	grep -E "deferred by cycle-gate|cycle-related alerts suppressed|skip digest push" "${PHASE_A_OUT}" | head -10
	PHASE_A_PASS=0
fi

# --- WAIT until endTime + 30 sec cushion ---
NOW=$(date +%s)
WAIT_SECS=$((WAIT_TO - NOW))
if [ "${WAIT_SECS}" -gt 0 ]; then
	echo ""
	echo "================================================================"
	echo "waiting ${WAIT_SECS} seconds until $(TZ=Asia/Tokyo date -r ${WAIT_TO} '+%H:%M:%S JST') before Phase B ..."
	echo "================================================================"
	# Progress dots every 30 sec
	while [ "$(date +%s)" -lt "${WAIT_TO}" ]; do
		REMAINING=$((WAIT_TO - $(date +%s)))
		[ "${REMAINING}" -le 0 ] && break
		printf '  [%s JST] %d sec remaining (= %d min %d sec)\n' \
			"$(TZ=Asia/Tokyo date '+%H:%M:%S')" \
			"${REMAINING}" "$((REMAINING / 60))" "$((REMAINING % 60))"
		sleep 30
	done
fi

# --- Phase B: at/after endTime ---
NOW_JST=$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S JST')
echo ""
echo "================================================================"
echo "starting Phase B at ${NOW_JST}"
echo "  expecting: all 8 cycle scripts skip (gate deferred, validator absent)"
echo "================================================================"

PHASE_B_OUT="$(mktemp -t phase_b.XXXXXX)"
run_all "PhaseB" > "${PHASE_B_OUT}" 2>&1

# Count per-script "deferred" markers in Phase B — expect at least 1 per script
echo ""
echo "Phase B summary (= 'deferred / suppressed / skip' marker per script):"
PHASE_B_PASS_COUNT=0
PHASE_B_FAIL_LIST=()
# Each script's expected "skip" marker on a deferred gate.
declare -a PHASE_B_SCRIPTS=(
	"${SIMPLE_SCRIPTS[@]}"
)
for script in "${PHASE_B_SCRIPTS[@]}"; do
	# Extract the per-script section (= between "--- PhaseB: <script> ---" and
	# the next "--- " marker), then grep for any known skip marker.
	SECTION=$(awk -v target="--- PhaseB: ${script} ---" '
		$0 == target { in_section = 1; next }
		in_section && /^--- / { exit }
		in_section { print }
	' "${PHASE_B_OUT}")
	if printf '%s\n' "${SECTION}" | grep -qE "deferred by cycle-gate|cycle-related alerts suppressed|skip digest push|fail-closed|deferred \(validator absent\)"; then
		echo "  ✓ ${script}: deferred marker present"
		PHASE_B_PASS_COUNT=$((PHASE_B_PASS_COUNT + 1))
	else
		echo "  ✗ ${script}: no deferred marker found"
		PHASE_B_FAIL_LIST+=("${script}")
	fi
done

PHASE_B_TOTAL=${#PHASE_B_SCRIPTS[@]}
echo ""
echo "Phase B: ${PHASE_B_PASS_COUNT}/${PHASE_B_TOTAL} scripts skipped on gate deferred"
if [ "${PHASE_B_PASS_COUNT}" -eq "${PHASE_B_TOTAL}" ]; then
	echo "  ✓ PASS Phase B — all ${PHASE_B_TOTAL} scripts auto-stopped after endTime"
	PHASE_B_PASS=1
else
	echo "  ✗ FAIL Phase B — missing: ${PHASE_B_FAIL_LIST[*]:-<none>}"
	echo ""
	echo "Phase B full stderr (= for debugging):"
	cat "${PHASE_B_OUT}"
	PHASE_B_PASS=0
fi

# --- Final result ---
echo ""
echo "================================================================"
if [ "${PHASE_A_PASS}" -eq 1 ] && [ "${PHASE_B_PASS}" -eq 1 ]; then
	echo "SCENARIO TEST RESULT: ✓ PASS"
	echo "  - Phase A (before endTime ${ENDTIME_JST}): all 8 scripts proceeded"
	echo "  - Phase B (after  endTime ${ENDTIME_JST}): all 8 scripts auto-stopped"
	echo "================================================================"
	exit 0
else
	echo "SCENARIO TEST RESULT: ✗ FAIL"
	echo "  - Phase A pass: ${PHASE_A_PASS}"
	echo "  - Phase B pass: ${PHASE_B_PASS}"
	echo "================================================================"
	exit 1
fi
