#!/usr/bin/env bash
# test-safe-broadcast.sh — regression suite for bin/safe-broadcast
# (tier-2 mechanical enforcement of PRIME DIRECTIVE).
#
# CHAIN: none — this test drives arg validation and gate refusal paths only.
#        It does NOT invoke any real proton broadcast. Cases that would
#        reach the `proton transaction:push` call are skipped without a
#        running proton-cli + configured keystore; those are covered by
#        the testnet full E2E rehearsal (T-I-20260701) instead.
#
# Usage:
#   bash tests/safe-broadcast/test-safe-broadcast.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/bin/safe-broadcast"

if [ ! -x "$WRAPPER" ]; then
	echo "FATAL: safe-broadcast not executable at $WRAPPER" >&2
	exit 1
fi

# ---- isolate token + audit log ----
TEST_TOKEN="$(mktemp -t safe-bcast-token.XXXXXX)"
TEST_AUDIT="$(mktemp -t safe-bcast-audit.XXXXXX)"
TEST_TX_VALID="$(mktemp -t safe-bcast-tx.XXXXXX)"
TEST_TX_EMPTY="$(mktemp -t safe-bcast-tx.XXXXXX)"
TEST_DRY_LOG="$(mktemp -t safe-bcast-dryrun.XXXXXX)"
export FYD_BROADCAST_TOKEN_FILE="$TEST_TOKEN"
export FYD_BROADCAST_AUDIT_LOG="$TEST_AUDIT"

cleanup() {
	rm -f "$TEST_TOKEN" "$TEST_AUDIT" "$TEST_TX_VALID" "$TEST_TX_EMPTY" "$TEST_DRY_LOG"
}
trap cleanup EXIT

# Prepare test fixtures.
cat > "$TEST_TX_VALID" <<'JSON'
{
  "actions": [
    {
      "account": "eosio.token",
      "name": "transfer",
      "authorization": [{"actor": "metalfreedom", "permission": "anchor"}],
      "data": {"from": "metalfreedom", "to": "fyhistory", "quantity": "0.0001 XPR", "memo": "fya1c3-test"}
    }
  ]
}
JSON
echo '{}' > "$TEST_TX_EMPTY"
echo 'dry-run log content' > "$TEST_DRY_LOG"

PASS=0
FAIL=0

run_case() {
	local name="$1"
	local expected_rc="$2"
	shift 2
	local args=("$@")
	local rc
	if [ "${#args[@]}" -eq 0 ]; then
		bash "$WRAPPER" </dev/null >/dev/null 2>&1
	else
		bash "$WRAPPER" "${args[@]}" </dev/null >/dev/null 2>&1
	fi
	rc=$?
	if [ "$rc" -eq "$expected_rc" ]; then
		printf 'PASS  %-70s (rc=%d)\n' "$name" "$rc"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %-70s (rc=%d, expected %d)\n' "$name" "$rc" "$expected_rc" >&2
		FAIL=$((FAIL + 1))
	fi
}

# ---- arg validation (exit 2) ----
run_case "arg: no args" 2
run_case "arg: --tx missing" 2 --chain=testnet-a
run_case "arg: --chain missing" 2 --tx="$TEST_TX_VALID"
run_case "arg: --chain invalid" 2 --tx="$TEST_TX_VALID" --chain=mainnet-c
run_case "arg: --tx file not readable" 2 --tx=/nonexistent/path --chain=testnet-a
run_case "arg: --tx missing .actions" 2 --tx="$TEST_TX_EMPTY" --chain=testnet-a
run_case "arg: unknown flag" 2 --tx="$TEST_TX_VALID" --chain=testnet-a --foo

# ---- gate 2 (token) failure paths (exit 3) ----
rm -f "$TEST_TOKEN"
run_case "gate 2: testnet, token missing" 3 --tx="$TEST_TX_VALID" --chain=testnet-a --non-interactive

# Expired token (400s old > 300s TTL and > 60s tight TTL).
touch "$TEST_TOKEN"
if OLD_TS_UTC="$(date -u -d '@0' +%Y%m%d%H%M 2>/dev/null)"; then
	OLD_TS="$(date -u -d '-400 seconds' +%Y%m%d%H%M)"
else
	OLD_TS="$(date -u -v-400S +%Y%m%d%H%M)"
fi
touch -t "$OLD_TS" "$TEST_TOKEN"
run_case "gate 2: testnet, token stale (400s > 60s tight TTL)" 3 --tx="$TEST_TX_VALID" --chain=testnet-a --non-interactive
run_case "gate 2: testnet, token stale (400s > 300s TTL)" 3 --tx="$TEST_TX_VALID" --chain=testnet-a

# ---- gate 1 + 4 (mainnet-only) failure paths (exit 3) ----
# Fresh token for these tests so gate 2 doesn't short-circuit them.
touch "$TEST_TOKEN"
run_case "gate 1: mainnet, no --testnet-tx-id" 3 --tx="$TEST_TX_VALID" --chain=mainnet-a --non-interactive
run_case "gate 1: mainnet, --testnet-tx-id malformed (not hex)" 3 --tx="$TEST_TX_VALID" --chain=mainnet-a --testnet-tx-id=nothex --non-interactive
run_case "gate 1: mainnet, --testnet-tx-id wrong length (32 hex)" 3 --tx="$TEST_TX_VALID" --chain=mainnet-a --testnet-tx-id=00112233445566778899aabbccddeeff --non-interactive

# Valid-shape testnet-tx-id but nonexistent on chain → resolve fails → exit 3.
# Note: this hits the network. If offline, curl will fail and the wrapper
# will still exit 3, so the test remains deterministic.
run_case "gate 1: mainnet, --testnet-tx-id shape-valid but unresolvable" 3 \
	--tx="$TEST_TX_VALID" \
	--chain=mainnet-a \
	--testnet-tx-id=0000000000000000000000000000000000000000000000000000000000000000 \
	--dry-run-log="$TEST_DRY_LOG" \
	--non-interactive

# ---- audit log: no line written on gate refusal (pre-log happens only after gates pass) ----
if [ ! -s "$TEST_AUDIT" ]; then
	printf 'PASS  %-70s (empty)\n' "audit log: no lines on gate refusal"
	PASS=$((PASS + 1))
else
	printf 'FAIL  %-70s (unexpected content: %d bytes)\n' "audit log: no lines on gate refusal" "$(wc -c < "$TEST_AUDIT")" >&2
	FAIL=$((FAIL + 1))
fi

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-safe-broadcast.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
