#!/usr/bin/env bash
# test-gen-anchor-receipt.sh — regression suite for
# scripts/gen-anchor-receipt.sh (v2 receipt generator).
#
# CHAIN: none — this test only exercises arg validation + input JSON
#        parsing. The RPC-fetch path (gates 1-7) is exercised in the
#        testnet full E2E rehearsal (T-I-20260701) where a real tx
#        exists on chain.
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

# ---- RPC unreachable (exit 3) via bogus RPC endpoint ----
run_case "RPC unreachable: bogus endpoint for gate 1" 3 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" \
	--rpc=https://nonexistent.invalid.example.local

# ---- prev-anchor-tx-id valid null path (arg accepted; will fail at RPC) ----
# Not testing exit 0 here since that requires real RPC + tx.
run_case "prev-anchor-tx-id: null (accepted before RPC)" 3 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" \
	--rpc=https://nonexistent.invalid.example.local --prev-anchor-tx-id=null

run_case "prev-anchor-tx-id: 64-hex (accepted before RPC)" 3 \
	--input="$GOOD_INPUT" --anchor-source="$V2_SOURCE" \
	--rpc=https://nonexistent.invalid.example.local \
	--prev-anchor-tx-id=1111111111111111111111111111111111111111111111111111111111111111

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
