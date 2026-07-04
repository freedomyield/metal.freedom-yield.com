#!/usr/bin/env bash
# tests/cycle-gate/run-tests.sh
# Scenario tests for cycle-gate.sh + resume-after-cycle-start.sh.
#
# Run from repo root or test dir:
#   bash tests/cycle-gate/run-tests.sh
#
# Exits 0 on full PASS, 1 on any FAIL.
#
# Requires: python3, jq, curl on PATH.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="${TEST_DIR}/fixtures"
SCRIPT_GATE="${REPO_ROOT}/scripts/cycle-gate.sh"
SCRIPT_RESUME="${REPO_ROOT}/scripts/resume-after-cycle-start.sh"
# Snapshot the real post-anchor-event.sh path BEFORE any per-test REPO_ROOT
# override. T16/T17/T18 override REPO_ROOT with a temp dir (= for write
# isolation), which would otherwise make ${REPO_ROOT}/scripts/post-anchor-event.sh
# resolve to a nonexistent path inside the tmp dir (= exit 127).
ABS_POSTANCHOR_PATH="${REPO_ROOT}/scripts/post-anchor-event.sh"

# macOS does not ship flock(1) by default. Prepend a tests-local PATH that
# carries a no-op flock shim so post-anchor-event.sh's lock acquisition
# succeeds during tests. Production runs on Linux where flock is native;
# concurrency semantics are not exercised by this test harness.
if ! command -v flock >/dev/null 2>&1; then
	export PATH="${TEST_DIR}/bin:${PATH}"
fi

PASS=0
FAIL=0
FAIL_LINES=()
MOCK_PID=""
PORT=""

find_free_port() {
	python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
}

start_mock() {
	local fixture="$1"
	PORT="$(find_free_port)"
	python3 "${TEST_DIR}/mock-rpc.py" "${PORT}" "${fixture}" >/dev/null 2>&1 &
	MOCK_PID=$!
	# Wait for server to bind. /ext/bc/P returns 500 if rpc_response missing,
	# or 200; either response means server is listening.
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		if curl -sS -o /dev/null -w "%{http_code}" \
		     -X POST -d '{}' "http://127.0.0.1:${PORT}/ext/bc/P" 2>/dev/null \
		   | grep -qE '^(200|500|404)$'; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

stop_mock() {
	if [ -n "${MOCK_PID}" ]; then
		kill "${MOCK_PID}" 2>/dev/null
		wait "${MOCK_PID}" 2>/dev/null
		MOCK_PID=""
	fi
}

assert_exit() {
	local label="$1" expected="$2" actual="$3"
	if [ "${actual}" = "${expected}" ]; then
		printf '  ✓ PASS: %s (exit=%s)\n' "${label}" "${actual}"
		PASS=$((PASS + 1))
	else
		printf '  ✗ FAIL: %s (expected exit=%s, got %s)\n' "${label}" "${expected}" "${actual}"
		FAIL=$((FAIL + 1))
		FAIL_LINES+=("${label}")
	fi
}

run_gate() {
	# wrapper that swallows stderr unless DEBUG is set
	if [ "${DEBUG:-0}" = "1" ]; then
		bash "${SCRIPT_GATE}" "$@"
	else
		bash "${SCRIPT_GATE}" "$@" 2>/dev/null
	fi
}

run_resume() {
	if [ "${DEBUG:-0}" = "1" ]; then
		bash "${SCRIPT_RESUME}" "$@"
	else
		bash "${SCRIPT_RESUME}" "$@" 2>/dev/null
	fi
}

trap 'stop_mock; rm -rf "${STATE_DIR:-/nonexistent}"' EXIT

echo "================================================================"
echo "cycle-gate.sh + resume-after-cycle-start.sh — scenario tests"
echo "================================================================"

# ==== T1: cycle-gate observe → green (no RPC needed) ====================
echo "[T1] cycle-gate observe → green (no state, no RPC)"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	run_gate --side-effect=observe
assert_exit "T1 observe → green" 0 $?
rm -rf "${STATE_DIR}"

# ==== T2: cycle-gate broadcast + state file absent → green ==============
echo "[T2] cycle-gate broadcast + state file absent → green (backward compat)"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	run_gate --side-effect=broadcast
assert_exit "T2 broadcast + no state → green" 0 $?
rm -rf "${STATE_DIR}"

# ==== T3: cycle-gate broadcast + state matches chain → green ============
echo "[T3] cycle-gate broadcast + state matches chain → green"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cp "${FIXTURE_DIR}/state-matches.json" "${STATE_DIR}/cycle-gate-state.json"
start_mock "${FIXTURE_DIR}/chain-matches.json"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	run_gate --side-effect=broadcast
RC=$?
stop_mock
assert_exit "T3 broadcast + match → green" 0 ${RC}
rm -rf "${STATE_DIR}"

# ==== T4: cycle-gate broadcast + state mismatch → deferred ==============
echo "[T4] cycle-gate broadcast + state mismatch → deferred"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
start_mock "${FIXTURE_DIR}/chain-matches.json"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	run_gate --side-effect=broadcast
RC=$?
stop_mock
assert_exit "T4 broadcast + mismatch → deferred" 1 ${RC}
rm -rf "${STATE_DIR}"

# ==== T5: cycle-gate broadcast + RPC unreachable → fail-closed ==========
echo "[T5] cycle-gate broadcast + RPC unreachable → fail-closed deferred"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	run_gate --side-effect=broadcast
assert_exit "T5 broadcast + RPC down → deferred" 1 $?
rm -rf "${STATE_DIR}"

# ==== T6: cycle-gate observe + RPC unreachable → green ==================
echo "[T6] cycle-gate observe + RPC unreachable → green (observe never gated)"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	run_gate --side-effect=observe
assert_exit "T6 observe + RPC down → green" 0 $?
rm -rf "${STATE_DIR}"

# ==== T7: cycle-gate broadcast + validator absent → deferred ============
echo "[T7] cycle-gate broadcast + validator absent on chain → deferred"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
start_mock "${FIXTURE_DIR}/chain-empty.json"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	run_gate --side-effect=broadcast
RC=$?
stop_mock
assert_exit "T7 broadcast + validator absent → deferred" 1 ${RC}
rm -rf "${STATE_DIR}"

# ==== T8: cycle-gate state file corrupt → fail-closed ===================
echo "[T8] cycle-gate broadcast + state file corrupt → fail-closed deferred"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
printf '%s\n' 'not valid json {' > "${STATE_DIR}/cycle-gate-state.json"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	run_gate --side-effect=broadcast
assert_exit "T8 broadcast + state corrupt → deferred" 1 $?
rm -rf "${STATE_DIR}"

# ==== T8a: cycle-gate state file missing schemaVersion → fail-closed ====
# T-9: a state file that parses as JSON but omits schemaVersion must be
# rejected, otherwise a legacy/foreign state file could pass the JSON-valid
# check and lead to a false-green decision on stale semantics.
echo "[T8a] cycle-gate broadcast + state file missing schemaVersion → fail-closed deferred"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cat > "${STATE_DIR}/cycle-gate-state.json" <<'JSON'
{
  "approved_cycle_signature": "NodeID-TEST-1000",
  "approved_dag_root_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "approved_at": "2026-07-01T00:00:00Z"
}
JSON
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	run_gate --side-effect=broadcast
assert_exit "T8a broadcast + state missing schemaVersion → deferred" 1 $?
rm -rf "${STATE_DIR}"

# ==== T8b: cycle-gate state file with wrong schemaVersion → fail-closed ==
# Same reasoning as T8a: a schemaVersion the current script doesn't know how
# to consume must not be treated as green just because the JSON parses.
echo "[T8b] cycle-gate broadcast + state file wrong schemaVersion → fail-closed deferred"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cat > "${STATE_DIR}/cycle-gate-state.json" <<'JSON'
{
  "schemaVersion": 2,
  "approved_cycle_signature": "NodeID-TEST-1000",
  "approved_dag_root_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "approved_at": "2026-07-01T00:00:00Z"
}
JSON
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	run_gate --side-effect=broadcast
assert_exit "T8b broadcast + state schemaVersion=2 → deferred" 1 $?
rm -rf "${STATE_DIR}"

# ==== T9: resume idempotent skip ========================================
echo "[T9] resume --dry-run + same cycle approved → idempotent exit 0"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cp "${FIXTURE_DIR}/state-matches.json" "${STATE_DIR}/cycle-gate-state.json"
start_mock "${FIXTURE_DIR}/chain-matches.json"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	run_resume --dry-run
RC=$?
stop_mock
assert_exit "T9 resume idempotent skip" 0 ${RC}
rm -rf "${STATE_DIR}"

# ==== T10: resume --dry-run + RPC unreachable → exit 2 ==================
echo "[T10] resume --dry-run + RPC unreachable → exit 2"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	run_resume --dry-run
assert_exit "T10 resume + RPC down → exit 2" 2 $?
rm -rf "${STATE_DIR}"

# ==========================================================================
# T-5.5 extension: T11-T18 cover Phase 1 polling / signature verify, full
# --apply path (Phase 2-5), and post-anchor-event ⇄ cycle-gate integration.
# ==========================================================================

TEST_KEY="${FIXTURE_DIR}/test-identity-key"

setup_test_key() {
	if [ ! -f "${TEST_KEY}" ]; then
		ssh-keygen -t ed25519 -f "${TEST_KEY}" -N "" -C "test-cycle-gate" >/dev/null 2>&1
	fi
}

# compose_signed_identity <dag_root_hash> <out_dir>
# Produces:
#   <out_dir>/identity.json
#   <out_dir>/identity.json.sig
# matching the test_key's signature. The .pub content is also written so it
# can be referenced by the mock config.
compose_signed_identity() {
	local dag="$1" outdir="$2"
	setup_test_key
	jq -n --arg dag "${dag}" '{
		schema_version: 1,
		brand: "Freedom Yield",
		node_id: "NodeID-TEST123",
		network: "metal-mainnet",
		operator_identity_pubkey_url: "https://example.test/operator-identity.pub",
		operator_identity_pubkey_fingerprint: "SHA256:test",
		key_iat: "2026-01-01T00:00:00Z",
		key_exp: "2027-01-01T00:00:00Z",
		revoked: false,
		verification: {
			method: "ssh-keygen -Y verify",
			namespace: "freedom-yield/validator-identity",
			principal: "freedom-yield"
		},
		dag_root_hash: $dag
	}' > "${outdir}/identity.json"
	ssh-keygen -Y sign \
		-f "${TEST_KEY}" \
		-n "freedom-yield/validator-identity" \
		"${outdir}/identity.json" >/dev/null 2>&1
}

# build_resume_scenario_config <out_config_json> <chain_start_time>
#                              <id_dag> <cycles_dag> <leaf_count>
#                              <out_dir_for_identity_files>
build_resume_scenario_config() {
	local out="$1" start="$2" id_dag="$3" cy_dag="$4" leaves="$5" iddir="$6"
	compose_signed_identity "${id_dag}" "${iddir}"
	local pub_content sig_content id_content
	pub_content="$(cat "${TEST_KEY}.pub")"
	sig_content="$(cat "${iddir}/identity.json.sig")"
	# IMPORTANT: bash command substitution strips trailing newlines, but
	# ssh-keygen -Y sign signed the file bytes INCLUDING the trailing newline.
	# Append it explicitly so the mock serves byte-exact what was signed.
	id_content="$(cat "${iddir}/identity.json")"$'\n'
	local receipt
	receipt=$(jq -n --arg dag "${id_dag}" '{
		"$schema": "https://metal.freedom-yield.com/api/anchor-receipt.schema.v1.json",
		schema_version: 1,
		dag_root_hash: $dag,
		memo: "fyid1:\($dag)",
		anchor: {
			tx_id: "mocktx_test_abcdef",
			explorer_url: "https://explorer.xprnetwork.org/transaction/mocktx_test_abcdef"
		},
		signing_actor: "metalfreedom",
		signing_permission: "anchor"
	}')
	# identity.json MUST be passed as --arg (= string), not --argjson (= reparsed),
	# so the mock server returns the byte-exact JSON that was signed by
	# ssh-keygen -Y sign. Otherwise jq would re-serialize the dict and the
	# whitespace / key-order delta would break ssh-keygen -Y verify (= byte-exact).
	# .sig and .pub were already --arg; receipt stays --argjson because schema
	# check only inspects fields, not bytes.
	jq -n \
		--arg start "${start}" \
		--arg id "${id_content}" \
		--arg sig "${sig_content}" \
		--arg pub "${pub_content}" \
		--arg cy_dag "${cy_dag}" \
		--argjson leaves "${leaves}" \
		--argjson receipt "${receipt}" \
		'{
			rpc_response: {
				jsonrpc: "2.0",
				id: 1,
				result: {
					validators: [
						{
							nodeID: "NodeID-TEST123",
							startTime: $start,
							endTime: "9999999999",
							weight: "5900000000000"
						}
					]
				}
			},
			files: {
				"/api/identity.json": $id,
				"/api/identity.json.sig": $sig,
				"/.well-known/operator-identity.pub": $pub,
				"/api/cycles-history.json": {
					dag_root_hash: $cy_dag,
					branches: { cycles: { leaf_count: $leaves } }
				},
				"/api/anchor-receipt.json": $receipt
			}
		}' > "${out}"
}

# ==== T11: resume Phase 1 polling timeout → exit 3 =======================
echo "[T11] resume Phase 1 polling timeout (= identity.json stays stale) → exit 3"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
ID_DIR="$(mktemp -d -t iddir.XXXXXX)"
SCEN="$(mktemp -t scen.XXXXXX).json"
# state-old has approved_dag = 00...00; we serve identity.json with same dag.
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
build_resume_scenario_config "${SCEN}" "1700000000" \
	"0000000000000000000000000000000000000000000000000000000000000000" \
	"0000000000000000000000000000000000000000000000000000000000000000" \
	2 "${ID_DIR}"
start_mock "${SCEN}"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	PUBLIC_BASE="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_POLL_INTERVAL=1 FY_POLL_MAX_SEC=3 FY_RPC_TIMEOUT=2 \
	run_resume --dry-run
RC=$?
stop_mock
assert_exit "T11 resume polling timeout → exit 3" 3 ${RC}
rm -rf "${STATE_DIR}" "${ID_DIR}" "${SCEN}"

# ==== T12: resume Phase 1 dag mismatch → exit 2 ==========================
echo "[T12] resume Phase 1 identity.dag != cycles-history.dag → exit 2"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
ID_DIR="$(mktemp -d -t iddir.XXXXXX)"
SCEN="$(mktemp -t scen.XXXXXX).json"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
# identity.dag fresh = aaaa…, cycles-history.dag = bbbb… (mismatch).
build_resume_scenario_config "${SCEN}" "1700000000" \
	"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
	"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
	2 "${ID_DIR}"
start_mock "${SCEN}"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	PUBLIC_BASE="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_POLL_INTERVAL=1 FY_POLL_MAX_SEC=10 FY_RPC_TIMEOUT=2 \
	run_resume --dry-run
RC=$?
stop_mock
assert_exit "T12 resume dag mismatch → exit 2" 2 ${RC}
rm -rf "${STATE_DIR}" "${ID_DIR}" "${SCEN}"

# ==== T13: resume Phase 1 signature verify (= test key) → Phase 1 PASS ====
echo "[T13] resume Phase 1 signature verify with test ed25519 key → PASS"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
ID_DIR="$(mktemp -d -t iddir.XXXXXX)"
SCEN="$(mktemp -t scen.XXXXXX).json"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
build_resume_scenario_config "${SCEN}" "1700000000" \
	"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
	"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
	2 "${ID_DIR}"
start_mock "${SCEN}"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	PUBLIC_BASE="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_POLL_INTERVAL=1 FY_POLL_MAX_SEC=10 FY_RPC_TIMEOUT=2 \
	run_resume --dry-run
RC=$?
stop_mock
assert_exit "T13 resume Phase 1 signature PASS → dry-run exit 0" 0 ${RC}
rm -rf "${STATE_DIR}" "${ID_DIR}" "${SCEN}"

# ==== T14: resume --apply end-to-end → all phases PASS, exit 0 ===========
echo "[T14] resume --apply end-to-end (= mock POSTANCHOR exit 0) → exit 0"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
ID_DIR="$(mktemp -d -t iddir.XXXXXX)"
SCEN="$(mktemp -t scen.XXXXXX).json"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
build_resume_scenario_config "${SCEN}" "1700000000" \
	"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" \
	"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" \
	2 "${ID_DIR}"
start_mock "${SCEN}"
POSTANCHOR_LOG="$(mktemp -t pa.XXXXXX)"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	PUBLIC_BASE="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_POLL_INTERVAL=1 FY_POLL_MAX_SEC=10 FY_RPC_TIMEOUT=2 \
	POSTANCHOR="${TEST_DIR}/mock-postanchor.sh" \
	MOCK_POSTANCHOR_EXIT=0 \
	MOCK_POSTANCHOR_LOGFILE="${POSTANCHOR_LOG}" \
	run_resume --apply
RC=$?
stop_mock
assert_exit "T14 resume --apply end-to-end → exit 0" 0 ${RC}
# Confirm state file was written + POSTANCHOR was invoked with cyclestart.
if [ -f "${STATE_DIR}/cycle-gate-state.json" ] \
	&& grep -q "NodeID-TEST123-1700000000" "${STATE_DIR}/cycle-gate-state.json" \
	&& grep -q "cyclestart" "${POSTANCHOR_LOG}"; then
	PASS=$((PASS + 1))
	printf '  ✓ PASS: T14 side-effects (state written + POSTANCHOR called with cyclestart)\n'
else
	FAIL=$((FAIL + 1))
	FAIL_LINES+=("T14 side-effects verification")
	printf '  ✗ FAIL: T14 side-effects not as expected\n'
fi
rm -rf "${STATE_DIR}" "${ID_DIR}" "${SCEN}" "${POSTANCHOR_LOG}"

# ==== T15: resume --apply with Phase 3 stub failure → exit 5 =============
echo "[T15] resume --apply + POSTANCHOR exits non-zero → exit 5"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
ID_DIR="$(mktemp -d -t iddir.XXXXXX)"
SCEN="$(mktemp -t scen.XXXXXX).json"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
build_resume_scenario_config "${SCEN}" "1700000000" \
	"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" \
	"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" \
	2 "${ID_DIR}"
start_mock "${SCEN}"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	PUBLIC_BASE="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_POLL_INTERVAL=1 FY_POLL_MAX_SEC=10 FY_RPC_TIMEOUT=2 \
	POSTANCHOR="${TEST_DIR}/mock-postanchor.sh" \
	MOCK_POSTANCHOR_EXIT=4 \
	run_resume --apply
RC=$?
stop_mock
assert_exit "T15 resume + POSTANCHOR fail → exit 5" 5 ${RC}
rm -rf "${STATE_DIR}" "${ID_DIR}" "${SCEN}"

# ==========================================================================
# T16-T18: post-anchor-event.sh ⇄ cycle-gate.sh integration.
# These directly invoke post-anchor-event.sh with stubs for signer / pusher /
# history appender. The cycle-gate.sh consultation is exercised in-context.
# ==========================================================================

# Helper: build a mock-rpc config carrying only cycles-history.json (= what
# post-anchor-event.sh fetches). Resume's identity-related artifacts are not
# needed because post-anchor-event.sh doesn't fetch them.
build_postanchor_scenario_config() {
	local out="$1" cy_dag="$2"
	jq -n --arg cy_dag "${cy_dag}" '{
		rpc_response: null,
		files: {
			"/api/cycles-history.json": {
				dag_root_hash: $cy_dag,
				branches: { cycles: { leaf_count: 2 } }
			}
		}
	}' > "${out}"
}

run_postanchor() {
	# Use ABS_POSTANCHOR_PATH (= captured at script init) so the per-test
	# REPO_ROOT override does NOT redirect the script lookup into the test's
	# tmp dir. REPO_ROOT env override still applies inside the script for its
	# own use (= AJV schema lookup, receipt write location).
	if [ "${DEBUG:-0}" = "1" ]; then
		bash "${ABS_POSTANCHOR_PATH}" "$@"
	else
		bash "${ABS_POSTANCHOR_PATH}" "$@" 2>&1
	fi
}

# ==== T16: post-anchor-event + cycle-gate green → signer called → exit 0 ==
echo "[T16] post-anchor-event + cycle-gate green → signer invoked, exit 0"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
SCEN="$(mktemp -t scen.XXXXXX).json"
TMP_REPO_ROOT="$(mktemp -d -t repo.XXXXXX)"
mkdir -p "${TMP_REPO_ROOT}/public/api"
# cycle-gate state matches chain (= signature TEST123-1700000000).
cp "${FIXTURE_DIR}/state-matches.json" "${STATE_DIR}/cycle-gate-state.json"
# Compose a chain scenario whose RPC matches state-matches.json, plus a
# cycles-history.json with a NEW dag (= different from any prior anchor).
jq -n '{
	rpc_response: {
		jsonrpc: "2.0", id: 1,
		result: { validators: [ { nodeID: "NodeID-TEST123",
			startTime: "1700000000", endTime: "9999999999",
			weight: "5900000000000" } ] }
	},
	files: {
		"/api/cycles-history.json": {
			dag_root_hash: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
			branches: { cycles: { leaf_count: 2 } }
		}
	}
}' > "${SCEN}"
start_mock "${SCEN}"
OUTPUT="$(mktemp -t out.XXXXXX)"
FY_STATE_DIR="${STATE_DIR}" \
	METALGO_RPC="http://127.0.0.1:${PORT}" \
	PUBLIC_BASE="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_RPC_TIMEOUT=2 \
	ANCHOR_SIGNER="${TEST_DIR}/mock-signer.sh" \
	ANCHOR_PUSHER="${TEST_DIR}/mock-pusher.sh" \
	ANCHOR_HISTORY_APPENDER="${TEST_DIR}/mock-history-appender.sh" \
	REPO_ROOT="${TMP_REPO_ROOT}" \
	run_postanchor --event-type cyclestart --cycle-n 3 > "${OUTPUT}" 2>&1
RC=$?
stop_mock
assert_exit "T16 post-anchor-event + gate green → exit 0" 0 ${RC}
# Signer invocation marker — mock-signer's chain/network strings appear when
# its JSON fragment is consumed by post-anchor-event (= "anchoring event_type"
# line precedes the signer call; presence of network=xpr-mainnet in receipt
# proves signer ran).
if grep -q "anchoring event_type" "${OUTPUT}" && grep -q "xpr-mainnet" "${OUTPUT}"; then
	PASS=$((PASS + 1))
	printf '  ✓ PASS: T16 signer was invoked (= gate green path proven)\n'
else
	FAIL=$((FAIL + 1))
	FAIL_LINES+=("T16 signer invocation")
	printf '  ✗ FAIL: T16 signer evidence NOT in output\n'
fi
rm -rf "${STATE_DIR}" "${SCEN}" "${OUTPUT}" "${TMP_REPO_ROOT}"

# ==== T17: post-anchor-event + cycle-gate deferred → exit 11, no signer ===
echo "[T17] post-anchor-event + cycle-gate deferred → exit 11, signer NOT called"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
SCEN="$(mktemp -t scen.XXXXXX).json"
TMP_REPO_ROOT="$(mktemp -d -t repo.XXXXXX)"
mkdir -p "${TMP_REPO_ROOT}/public/api"
# state-old has signature NodeID-TEST123-1600000000; chain returns 1700000000.
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
jq -n '{
	rpc_response: {
		jsonrpc: "2.0", id: 1,
		result: { validators: [ { nodeID: "NodeID-TEST123",
			startTime: "1700000000", endTime: "9999999999",
			weight: "5900000000000" } ] }
	},
	files: {
		"/api/cycles-history.json": {
			dag_root_hash: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
			branches: { cycles: { leaf_count: 2 } }
		}
	}
}' > "${SCEN}"
start_mock "${SCEN}"
OUTPUT="$(mktemp -t out.XXXXXX)"
FY_STATE_DIR="${STATE_DIR}" \
	METALGO_RPC="http://127.0.0.1:${PORT}" \
	PUBLIC_BASE="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_RPC_TIMEOUT=2 \
	ANCHOR_SIGNER="${TEST_DIR}/mock-signer.sh" \
	ANCHOR_PUSHER="${TEST_DIR}/mock-pusher.sh" \
	ANCHOR_HISTORY_APPENDER="${TEST_DIR}/mock-history-appender.sh" \
	REPO_ROOT="${TMP_REPO_ROOT}" \
	run_postanchor --event-type cyclestart --cycle-n 3 > "${OUTPUT}" 2>&1
RC=$?
stop_mock
assert_exit "T17 post-anchor-event + gate deferred → exit 11" 11 ${RC}
# Signer evidence MUST be absent (= "anchoring event_type" precedes signer).
if grep -q "anchoring event_type" "${OUTPUT}"; then
	FAIL=$((FAIL + 1))
	FAIL_LINES+=("T17 signer was invoked despite gate deferred")
	printf '  ✗ FAIL: T17 signer WAS invoked (= gate did not block)\n'
else
	PASS=$((PASS + 1))
	printf '  ✓ PASS: T17 signer NOT invoked (= gate blocked broadcast)\n'
fi
rm -rf "${STATE_DIR}" "${SCEN}" "${OUTPUT}" "${TMP_REPO_ROOT}"

# ==== T18: post-anchor-event end-to-end → receipt assembled + state finalized
echo "[T18] post-anchor-event end-to-end → last-anchored-root + receipt updated"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
SCEN="$(mktemp -t scen.XXXXXX).json"
TMP_REPO_ROOT="$(mktemp -d -t repo.XXXXXX)"
mkdir -p "${TMP_REPO_ROOT}/public/api"
cp "${FIXTURE_DIR}/state-matches.json" "${STATE_DIR}/cycle-gate-state.json"
jq -n '{
	rpc_response: {
		jsonrpc: "2.0", id: 1,
		result: { validators: [ { nodeID: "NodeID-TEST123",
			startTime: "1700000000", endTime: "9999999999",
			weight: "5900000000000" } ] }
	},
	files: {
		"/api/cycles-history.json": {
			dag_root_hash: "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100",
			branches: { cycles: { leaf_count: 2 } }
		}
	}
}' > "${SCEN}"
start_mock "${SCEN}"
FY_STATE_DIR="${STATE_DIR}" \
	METALGO_RPC="http://127.0.0.1:${PORT}" \
	PUBLIC_BASE="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_RPC_TIMEOUT=2 \
	ANCHOR_SIGNER="${TEST_DIR}/mock-signer.sh" \
	ANCHOR_PUSHER="${TEST_DIR}/mock-pusher.sh" \
	ANCHOR_HISTORY_APPENDER="${TEST_DIR}/mock-history-appender.sh" \
	REPO_ROOT="${TMP_REPO_ROOT}" \
	run_postanchor --event-type cyclestart --cycle-n 3 >/dev/null 2>&1
RC=$?
stop_mock
assert_exit "T18 post-anchor-event end-to-end → exit 0" 0 ${RC}
# Side-effects verification:
EXPECTED_DAG="ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"
LAST_ANCHORED_FILE="${STATE_DIR}/last-anchored-root"
RECEIPT_FILE="${TMP_REPO_ROOT}/public/api/anchor-receipt.json"
if [ -f "${LAST_ANCHORED_FILE}" ] \
	&& grep -q "${EXPECTED_DAG}" "${LAST_ANCHORED_FILE}" \
	&& [ -f "${RECEIPT_FILE}" ] \
	&& jq -e --arg dag "${EXPECTED_DAG}" '.dag_root_hash == $dag' "${RECEIPT_FILE}" >/dev/null 2>&1; then
	PASS=$((PASS + 1))
	printf '  ✓ PASS: T18 last-anchored-root + receipt both finalized with new dag\n'
else
	FAIL=$((FAIL + 1))
	FAIL_LINES+=("T18 side-effects verification")
	printf '  ✗ FAIL: T18 side-effects not as expected (state=%s receipt=%s)\n' \
		"$([ -f "${LAST_ANCHORED_FILE}" ] && echo "exists" || echo "missing")" \
		"$([ -f "${RECEIPT_FILE}" ] && echo "exists" || echo "missing")"
fi
rm -rf "${STATE_DIR}" "${SCEN}" "${TMP_REPO_ROOT}"

# ==========================================================================
# T-RD2 extension: T19-T23 cover cycle-artifact-write type, fail-closed of
# post-anchor-event.sh when cycle-gate.sh missing, and all 7 cycle scripts
# correctly skip on deferred gate.
# ==========================================================================

# ==== T19: cycle-gate cycle-artifact-write + state matches → green =======
echo "[T19] cycle-gate cycle-artifact-write + state matches → green"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cp "${FIXTURE_DIR}/state-matches.json" "${STATE_DIR}/cycle-gate-state.json"
start_mock "${FIXTURE_DIR}/chain-matches.json"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	run_gate --side-effect=cycle-artifact-write
RC=$?
stop_mock
assert_exit "T19 cycle-artifact-write + match → green" 0 ${RC}
rm -rf "${STATE_DIR}"

# ==== T20: cycle-gate cycle-artifact-write is UNCONDITIONALLY green =======
# (design-stocktake #2) Recording a closed cycle is backward-looking and can
# never be premature, so cycle-artifact-write is never gated — proven green even
# with a mismatched state file AND RPC unreachable (= it short-circuits before
# reading state or hitting the chain, exactly like observe).
echo "[T20] cycle-gate cycle-artifact-write + mismatch state + RPC down → green (never gated)"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
FY_STATE_DIR="${STATE_DIR}" METALGO_RPC="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	run_gate --side-effect=cycle-artifact-write
assert_exit "T20 cycle-artifact-write never gated → green" 0 $?
rm -rf "${STATE_DIR}"

# ==== T21: post-anchor-event + cycle-gate.sh MISSING → exit 11 ==========
# T-RD2 Q3 fix: backward compat removed, fail-closed for missing gate script.
echo "[T21] post-anchor-event + cycle-gate.sh MISSING → exit 11 (fail-closed)"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
SCEN="$(mktemp -t scen.XXXXXX).json"
TMP_REPO_ROOT="$(mktemp -d -t repo.XXXXXX)"
TMP_SCRIPT_DIR="$(mktemp -d -t scripts.XXXXXX)"
mkdir -p "${TMP_REPO_ROOT}/public/api"
# Place post-anchor-event.sh in a fresh dir WITHOUT cycle-gate.sh sibling.
cp "${REPO_ROOT}/scripts/post-anchor-event.sh" "${TMP_SCRIPT_DIR}/"
chmod +x "${TMP_SCRIPT_DIR}/post-anchor-event.sh"
# (= cycle-gate.sh intentionally NOT copied → fail-closed path)
cp "${FIXTURE_DIR}/state-matches.json" "${STATE_DIR}/cycle-gate-state.json"
jq -n '{
	rpc_response: null,
	files: { "/api/cycles-history.json": {
		dag_root_hash: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
		branches: { cycles: { leaf_count: 2 } }
	} }
}' > "${SCEN}"
start_mock "${SCEN}"
FY_STATE_DIR="${STATE_DIR}" \
	METALGO_RPC="http://127.0.0.1:${PORT}" \
	PUBLIC_BASE="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_RPC_TIMEOUT=2 \
	ANCHOR_SIGNER="${TEST_DIR}/mock-signer.sh" \
	ANCHOR_PUSHER="${TEST_DIR}/mock-pusher.sh" \
	ANCHOR_HISTORY_APPENDER="${TEST_DIR}/mock-history-appender.sh" \
	REPO_ROOT="${TMP_REPO_ROOT}" \
	bash "${TMP_SCRIPT_DIR}/post-anchor-event.sh" --event-type cyclestart --cycle-n 3 2>&1 >/dev/null
RC=$?
stop_mock
assert_exit "T21 fail-closed when cycle-gate.sh missing → exit 11" 11 ${RC}
rm -rf "${STATE_DIR}" "${SCEN}" "${TMP_REPO_ROOT}" "${TMP_SCRIPT_DIR}"

# ==== T22: 5 cycle-artifact-write scripts are NOT deferred (ungated) ======
# (design-stocktake #2) cycle-artifact-write is unconditionally green, so the 5
# scripts that consult it must proceed past the gate even with a mismatched state
# — none may print the "deferred by cycle-gate" skip marker.
echo "[T22] all 5 cycle-artifact-write scripts proceed past ungated gate (not deferred)"
T22_LOG="$(mktemp -t t22.XXXXXX)"
T22_PASS=0
T22_FAIL=0
for script_name in gen-cycle-history.sh gen-evidence.sh gen-renewal-ics.sh node-info.sh uptime-history.sh; do
	STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
	cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
	start_mock "${FIXTURE_DIR}/chain-matches.json"
	# Use empty REPO_BASE override so internal file paths point to tmp;
	# we only care that the gate-skip path is taken before any file work.
	TMP_REPO_BASE="$(mktemp -d -t repobase.XXXXXX)"
	mkdir -p "${TMP_REPO_BASE}/public/api" "${TMP_REPO_BASE}/scripts"
	# Symlink cycle-gate.sh + the target script into tmp scripts dir so
	# ROOT/scripts/cycle-gate.sh resolves correctly.
	ln -s "${REPO_ROOT}/scripts/cycle-gate.sh" "${TMP_REPO_BASE}/scripts/cycle-gate.sh"
	ln -s "${REPO_ROOT}/scripts/${script_name}" "${TMP_REPO_BASE}/scripts/${script_name}"
	# Create minimal validator.json + uptime-cycles.json + incidents.json
	# so scripts that read these don't error before reaching gate check.
	# Richer validator.json needed for uptime-history.sh Job A (= which runs
	# UNCONDITIONALLY before reaching the cycle-gate-checked Job B).
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
	# uptime-history.sh defaults UPTIME_STATE_DIR to a literal path; redirect
	# to a tmp dir so Job A doesn't fail with permission denied BEFORE the
	# Job B gate-check is reached.
	mkdir -p "${TMP_REPO_BASE}/state"
	OUT="$(FY_STATE_DIR="${STATE_DIR}" \
		METALGO_RPC="http://127.0.0.1:${PORT}" \
		METALGO_API="http://127.0.0.1:${PORT}" \
		NODE_ID="NodeID-TEST123" \
		FY_RPC_TIMEOUT=2 \
		REPO_BASE="${TMP_REPO_BASE}" \
		UPTIME_STATE_DIR="${TMP_REPO_BASE}/state" \
		bash "${TMP_REPO_BASE}/scripts/${script_name}" 2>&1 || true)"
	RC=$?
	if echo "${OUT}" | grep -q "deferred by cycle-gate"; then
		printf '  ✗ FAIL: T22[%s] STILL deferred (cycle-artifact-write must never gate)\n' \
			"${script_name}"
		T22_FAIL=$((T22_FAIL + 1))
		echo "${OUT}" | head -3 >&2
	else
		printf '  ✓ PASS: T22[%s] proceeds past ungated gate (not deferred)\n' "${script_name}"
		T22_PASS=$((T22_PASS + 1))
	fi
	rm -rf "${STATE_DIR}" "${TMP_REPO_BASE}"
	stop_mock
done
if [ "${T22_FAIL}" -eq 0 ]; then
	PASS=$((PASS + 1))
	printf '  ✓ PASS: T22 all %d cycle-artifact-write scripts proceed past ungated gate\n' "${T22_PASS}"
else
	FAIL=$((FAIL + 1))
	FAIL_LINES+=("T22 cycle-artifact-write scripts still deferred (${T22_FAIL} of 5)")
fi

# ==== T23: check-anomalies.sh partial gate (= cycle-section wrap) =======
echo "[T23] check-anomalies.sh cycle-section wrap on gate deferred"
STATE_DIR="$(mktemp -d -t cgstate.XXXXXX)"
cp "${FIXTURE_DIR}/state-old.json" "${STATE_DIR}/cycle-gate-state.json"
start_mock "${FIXTURE_DIR}/chain-matches.json"
TMP_REPO_BASE="$(mktemp -d -t repobase.XXXXXX)"
mkdir -p "${TMP_REPO_BASE}/public/api" "${TMP_REPO_BASE}/scripts"
ln -s "${REPO_ROOT}/scripts/cycle-gate.sh" "${TMP_REPO_BASE}/scripts/cycle-gate.sh"
ln -s "${REPO_ROOT}/scripts/check-anomalies.sh" "${TMP_REPO_BASE}/scripts/check-anomalies.sh"
echo '{}' > "${TMP_REPO_BASE}/public/api/validator.json"
OUT="$(FY_STATE_DIR="${STATE_DIR}" \
	METALGO_RPC="http://127.0.0.1:${PORT}" \
	NODE_ID="NodeID-TEST123" \
	FY_RPC_TIMEOUT=2 \
	REPO_BASE="${TMP_REPO_BASE}" \
	bash "${TMP_REPO_BASE}/scripts/check-anomalies.sh" 2>&1 || true)"
stop_mock
if echo "${OUT}" | grep -q "cycle-related alerts suppressed"; then
	PASS=$((PASS + 1))
	printf '  ✓ PASS: T23 check-anomalies cycle-section suppressed on deferred gate\n'
else
	FAIL=$((FAIL + 1))
	FAIL_LINES+=("T23 check-anomalies gate suppress")
	printf '  ✗ FAIL: T23 no "cycle-related alerts suppressed" in stderr\n'
fi
rm -rf "${STATE_DIR}" "${TMP_REPO_BASE}"

echo ""
echo "================================================================"
printf 'RESULTS: %s PASS / %s FAIL (total %s)\n' "${PASS}" "${FAIL}" "$((PASS + FAIL))"
if [ "${FAIL}" -gt 0 ]; then
	echo "Failed tests:"
	for line in "${FAIL_LINES[@]}"; do
		echo "  - ${line}"
	done
	exit 1
fi
echo "================================================================"
exit 0
