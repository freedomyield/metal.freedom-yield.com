#!/usr/bin/env bash
# test-gen-anchor-receipt.sh — regression suite for
# scripts/gen-anchor-receipt.sh (v2 receipt generator).
#
# CHAIN: none — this test only exercises arg validation + input JSON
#        parsing. The RPC-fetch path (gates 1-7) is exercised in the
#        testnet full E2E rehearsal (T-I-20260701) where a real tx
#        exists on chain.
#
# 2026-09-30: no network at all. `curl` is a stub on PATH that records its
# calls and always fails (the "unreachable" answer), and the --rpc values
# are the xpr-testnet profile's history base — until 2026-09-30 these cases
# used https://nonexistent.invalid.example.local and relied on a real DNS
# failure. That host is now refused BEFORE any request (it is not in the
# profile's history_bases), which the new cases below pin.
#
# Usage:
#   bash tests/gen-anchor-receipt/test-gen-anchor-receipt.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/gen-anchor-receipt.sh"
V2_SOURCE="${REPO_ROOT}/public/api/anchor-source.example.json"

if [ ! -x "$SCRIPT" ]; then
	echo "FATAL: script not executable at $SCRIPT" >&2
	exit 1
fi

TEST_DIR="$(mktemp -d -t gen-receipt-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Failing curl stub: every request is "unreachable"; each call is logged.
mkdir -p "$TEST_DIR/bin"
CURL_LOG="$TEST_DIR/curl.log"
cat > "$TEST_DIR/bin/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CURL_LOG"
exit 6
STUB
chmod +x "$TEST_DIR/bin/curl"
PATH="$TEST_DIR/bin:$PATH"
export PATH
TESTNET_HISTORY="https://test.proton.eosusa.io"

PASS=0
FAIL=0

run_case() {
	local name="$1"
	local expected_rc="$2"
	shift 2
	local rc
	if [ "$#" -eq 0 ]; then
		bash "$SCRIPT" </dev/null >/dev/null 2>&1
	else
		bash "$SCRIPT" "$@" </dev/null >/dev/null 2>&1
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

# Valid sign-anchor-event output shape (from --dry-run structure of v2 rewrite).
GOOD_INPUT="$TEST_DIR/good-input.json"
cat > "$GOOD_INPUT" <<'JSON'
{
  "tx_id": "1111111111111111111111111111111111111111111111111111111111111111",
  "chain": "metal-a-chain",
  "network": "testnet-a",
  "method": "hc_single_4_action_pack",
  "schema_version": 1,
  "cycle_number": 2,
  "memo_prefix": "fya1c2",
  "actions": [
    {"branch": "identity", "memo": "fya1c2-id:aaaa", "root_hex": "f5e8f4e688e3962769eaf8cbbea844da18d7f42192711c61a6052c35f30eb3d5"},
    {"branch": "observations", "memo": "fya1c2-ob:bbbb", "root_hex": "3d6f697cdbcaa3d0ae6d786f46e4d26cf3eb03677240dc78f9779f8cb219db24"},
    {"branch": "artifacts", "memo": "fya1c2-ar:cccc", "root_hex": "3784dbcd1316755bce7ebfb1372f87d8e489538dc423aaf15125c0d38c48bbe9"},
    {"branch": "dag_root_summary", "memo": "fya1c2:efd1", "root_hex": "efd1bd78dc20c7ba3b9e3838679f38757ce5273ed1f2d66f383943ef83ea329a"}
  ],
  "authorization": {"actor": "metalfreedom", "permission": "anchor"},
  "sink": "fyhistory",
  "quantity": "0.0001 XPR"
}
JSON

# ---- arg validation (exit 1) ----
run_case "arg: no args (missing --anchor-source)" 1
run_case "arg: --trigger invalid" 1 --input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" --trigger=badevent
run_case "arg: --prev-anchor-tx-id malformed" 1 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" --prev-anchor-tx-id=nothex

# ---- input parse errors (exit 2) ----
BAD_INPUT_EMPTY="$TEST_DIR/empty.json"
echo '{}' > "$BAD_INPUT_EMPTY"
run_case "input parse: empty JSON (no tx_id/actions/memo_prefix)" 2 \
	--input="$BAD_INPUT_EMPTY" --anchor-source="$V2_SOURCE"

BAD_INPUT_NO_TX="$TEST_DIR/no-tx.json"
jq 'del(.tx_id)' "$GOOD_INPUT" > "$BAD_INPUT_NO_TX"
run_case "input parse: missing tx_id" 2 \
	--input="$BAD_INPUT_NO_TX" --anchor-source="$V2_SOURCE"

run_case "input parse: --input file unreadable" 2 \
	--input=/nonexistent --anchor-source="$V2_SOURCE"

run_case "input parse: --anchor-source unreadable" 2 \
	--input="$GOOD_INPUT" --anchor-source=/nonexistent

# ---- RPC unreachable (exit 3): allowlisted base, stub curl fails ----
run_case "RPC unreachable: profile history base down for gate 1" 3 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" \
	--rpc="$TESTNET_HISTORY"
run_case "RPC unreachable: no --rpc (profile default base) down" 3 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE"

# ---- prev-anchor-tx-id valid null path (arg accepted; will fail at RPC) ----
# Not testing exit 0 here since that requires real RPC + tx.
run_case "prev-anchor-tx-id: null (accepted before RPC)" 3 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" \
	--rpc="$TESTNET_HISTORY" --prev-anchor-tx-id=null

run_case "prev-anchor-tx-id: 64-hex (accepted before RPC)" 3 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" \
	--rpc="$TESTNET_HISTORY" \
	--prev-anchor-tx-id=1111111111111111111111111111111111111111111111111111111111111111

# ---- 2026-09-30: --rpc must be one of the profile's history_bases ----
MAINNET_INPUT="$TEST_DIR/mainnet-input.json"
jq '.network = "mainnet-a"' "$GOOD_INPUT" > "$MAINNET_INPUT"
: > "$CURL_LOG"
run_case "rpc allowlist: unlisted --rpc refused before any request" 1 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" \
	--rpc=https://nonexistent.invalid.example.local
if [ -s "$CURL_LOG" ]; then
	printf 'FAIL  %-70s\n' "rpc allowlist: refused run made NO request" >&2; FAIL=$((FAIL + 1))
else
	printf 'PASS  %-70s\n' "rpc allowlist: refused run made NO request"; PASS=$((PASS + 1))
fi
run_case "rpc allowlist: other role's base refused (testnet base, mainnet tx)" 1 \
	--input="$MAINNET_INPUT" --anchor-source="$V2_SOURCE" --rpc="$TESTNET_HISTORY"
run_case "rpc allowlist: trailing-slash variant refused (exact match)" 1 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" --rpc="${TESTNET_HISTORY}/"
run_case "rpc escape hatch: --allow-unlisted-rpc accepted for testnet (reaches fetch)" 3 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" \
	--rpc=https://rehearsal.example.org --allow-unlisted-rpc
run_case "rpc escape hatch: --allow-unlisted-rpc refused for mainnet" 1 \
	--input="$MAINNET_INPUT" --anchor-source="$V2_SOURCE" \
	--rpc=https://rehearsal.example.org --allow-unlisted-rpc
run_case "receipt schema: unknown --receipt-schema value" 1 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" --receipt-schema=v9
# A selected profile whose chain_id is not yet published (pulsevm-testnet)
# must refuse before any request: a receipt that cannot name its chain is
# never written.
: > "$CURL_LOG"
FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet run_case "profile: pulsevm-testnet (chain_id null) refused" 1 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE"
if [ -s "$CURL_LOG" ]; then
	printf 'FAIL  %-70s\n' "profile: null-chain_id refusal made NO request" >&2; FAIL=$((FAIL + 1))
else
	printf 'PASS  %-70s\n' "profile: null-chain_id refusal made NO request"; PASS=$((PASS + 1))
fi

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-gen-anchor-receipt.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
