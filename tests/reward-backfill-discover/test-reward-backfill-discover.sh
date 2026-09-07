#!/usr/bin/env bash
# tests/reward-backfill-discover/test-reward-backfill-discover.sh —
# end-to-end behavior test for scripts/reward-backfill-discover.sh against
# a stub metalgo RPC (curl), same harness pattern as
# tests/reward-tracker/test-reward-tracker.sh.
#
# CHAIN: none. No real P-Chain node — the ONLY `curl` on PATH during these
# runs is the stub built below, which never makes a network connection.
# Every scenario is a fixture; every txID / address in them is fictional.
#
# Covers (per the reward-backfill-discover task brief):
#   (a) all 4 closed cycles found along a straight input chain, exit 0
#   (b) an intermediate non-staking BaseTx is walked straight through
#       (cycles 1-3 are ONLY reachable through it in this topology)
#   (c) a closed cycle nobody's staking tx matches -> NOT-FOUND + exit 4
#       (also exercised via MAX_DEPTH truncation)
#   (d) RPC transport failure / unreadable root tx -> fail-closed non-zero
#   (e) OUTPUT HYGIENE: the fixture leak-canary address never appears in
#       any captured stdout/stderr — proven to have teeth with a
#       mutation-kill run (a MUTANT that echoes the raw getTx response
#       must trip the same grep)
#   (f) the script contains no broadcast-shape string, and the only RPC
#       methods it can form are the two read-only ones

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/reward-backfill-discover.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILURES=()

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %-70s expected=%s actual=%s\n' "$label" "$expected" "$actual"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected=$expected, actual=$actual)")
		printf '  FAIL  %-70s expected=%s actual=%s\n' "$label" "$expected" "$actual"
	fi
}

assert_true() {
	local label="$1" cond="$2"
	if [ "$cond" = "1" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label")
		printf '  FAIL  %s\n' "$label"
	fi
}

# ===========================================================================
# Fixture identities — ALL FICTIONAL (constitution sanitize rule: no real
# on-chain account/address/txID in fixtures). The address doubles as the
# leak canary for case (e).
# ===========================================================================
NODE_ID="NodeID-fixtureDiscover11111111111111"
TX5="txFix5CurrentInFlightAAAAAAAAAAAAA"   # in-flight cycle 5 (no closed row)
TX4="txFix4ClosedCycleBBBBBBBBBBBBBBBBB"
TXBASE="txFixBaseIntermediateCCCCCCCCCCCC"  # non-staking hop between 4 and 3
TX3="txFix3ClosedCycleDDDDDDDDDDDDDDDDD"
TX2="txFix2ClosedCycleEEEEEEEEEEEEEEEEE"
TX1="txFix1ClosedCycleFFFFFFFFFFFFFFFFF"
TXIMPORT="txFixImportDeadEndGGGGGGGGGGGGGG"  # no fixture -> RPC "not found"
TXGHOST="txFixGhostRootHHHHHHHHHHHHHHHHHHH"  # unreadable BFS root for (d)
LEAK_ADDR="P-metal1fixtureleakcanaryzzzzzzzzzzzz"

DUR=2764800   # 32 days, fictional
C1S=1710000000; C1E=$((C1S + DUR))
C2S=$C1E;       C2E=$((C2S + DUR))
C3S=$C2E;       C3E=$((C3S + DUR))
C4S=$C3E;       C4E=$((C4S + DUR))
C5S=$C4E;       C5E=$((C5S + DUR))

FIX_DIR="$TMP/fixtures"
mkdir -p "$FIX_DIR" "$TMP/bin" "$TMP/record"

VALIDATOR_JSON="$TMP/validator.json"
UPTIME_CYCLES_JSON="$TMP/uptime-cycles.json"
echo "{\"nodeId\":\"$NODE_ID\"}" > "$VALIDATOR_JSON"
cat > "$UPTIME_CYCLES_JSON" <<JSON
{"cycles":[
 {"cycle_n":1,"start_unix":$C1S,"end_unix":$C1E,"final_self_stake_metal":5900},
 {"cycle_n":2,"start_unix":$C2S,"end_unix":$C2E,"final_self_stake_metal":5900},
 {"cycle_n":3,"start_unix":$C3S,"end_unix":$C3E,"final_self_stake_metal":21640},
 {"cycle_n":4,"start_unix":$C4S,"end_unix":$C4E,"final_self_stake_metal":23750}
]}
JSON

# ---- stub curl -------------------------------------------------------------
# Routes by the JSON body's "method"; platform.getTx is further routed by
# the body's txID to a per-tx fixture file (missing file -> the JSON-RPC
# "not found" error shape, which the script must treat as a dead-end for a
# parent and as fatal for the BFS root). STUB_FAIL=1 simulates a transport
# failure: no output, non-zero exit — exactly what a dead node looks like
# through `curl ... 2>/dev/null`.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_FAIL:-0}" = "1" ]; then
	exit 7
fi
DATA=""
prev=""
for a in "$@"; do
	case "$prev" in
		-d|--data) DATA="$a" ;;
	esac
	prev="$a"
done
METHOD=$(printf '%s' "$DATA" | grep -oE '"method":"[a-zA-Z.]+"' | head -1 | sed -E 's/.*:"([a-zA-Z.]+)"/\1/')
case "$METHOD" in
	platform.getCurrentValidators)
		cat "$STUB_FIXTURE_DIR/getCurrentValidators.json"
		;;
	platform.getTx)
		TXID=$(printf '%s' "$DATA" | grep -oE '"txID":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')
		if [ -f "$STUB_FIXTURE_DIR/tx-$TXID.json" ]; then
			cat "$STUB_FIXTURE_DIR/tx-$TXID.json"
		else
			echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"tx not found"}}'
		fi
		;;
	*)
		echo "stub curl: unrecognized method in body: $DATA" >&2
		exit 1
		;;
esac
exit 0
STUB
chmod +x "$TMP/bin/curl"

# write_cv <root_txid> — getCurrentValidators fixture naming the BFS root
write_cv() {
	cat > "$FIX_DIR/getCurrentValidators.json" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"validators":[{"nodeID":"$NODE_ID","txID":"$1","startTime":"$C5S","endTime":"$C5E","weight":"23750000000000","delegationFee":3.0,"delegators":[]}]}}
JSON
}

# write_staking_tx <txid> <parent_txid_or_empty> <start> <end>
# Realistic AddValidatorTx json-encoding shape: validator times are STRINGS
# (metalgo marshals uint64 as strings) — the script must tonumber them.
# rewardsOwner / stake / outputs all carry the leak-canary address.
write_staking_tx() {
	local tx="$1" parent="$2" s="$3" e="$4" inputs="[]"
	if [ -n "$parent" ]; then
		inputs="[{\"txID\":\"$parent\",\"outputIndex\":0,\"assetID\":\"fixAssetIDzzzz\",\"fxID\":\"fixFxIDzzzz\",\"input\":{\"amount\":1,\"signatureIndices\":[0]}}]"
	fi
	cat > "$FIX_DIR/tx-$tx.json" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"tx":{"unsignedTx":{"networkID":1,"blockchainID":"11111111111111111111111111111111LpoYY","outputs":[{"assetID":"fixAssetIDzzzz","fxID":"fixFxIDzzzz","output":{"addresses":["$LEAK_ADDR"],"amount":1,"locktime":0,"threshold":1}}],"inputs":$inputs,"memo":"0x","validator":{"nodeID":"$NODE_ID","start":"$s","end":"$e","weight":"23750000000000"},"stake":[{"assetID":"fixAssetIDzzzz","fxID":"fixFxIDzzzz","output":{"addresses":["$LEAK_ADDR"],"amount":1,"locktime":0,"threshold":1}}],"rewardsOwner":{"addresses":["$LEAK_ADDR"],"locktime":0,"threshold":1},"shares":30000},"credentials":[],"id":"$tx"},"encoding":"json"}}
JSON
}

# write_base_tx <txid> <parent_txid> — non-staking intermediate (no
# validator object), still carrying input references and the canary.
write_base_tx() {
	local tx="$1" parent="$2"
	cat > "$FIX_DIR/tx-$tx.json" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"tx":{"unsignedTx":{"networkID":1,"blockchainID":"11111111111111111111111111111111LpoYY","outputs":[{"assetID":"fixAssetIDzzzz","fxID":"fixFxIDzzzz","output":{"addresses":["$LEAK_ADDR"],"amount":1,"locktime":0,"threshold":1}}],"inputs":[{"txID":"$parent","outputIndex":0,"assetID":"fixAssetIDzzzz","fxID":"fixFxIDzzzz","input":{"amount":1,"signatureIndices":[0]}}],"memo":"0x"},"credentials":[],"id":"$tx"},"encoding":"json"}}
JSON
}

# Topology: TX5 -> TX4 -> TXBASE -> TX3 -> TX2 -> TX1 -> TXIMPORT(dead-end).
# Cycles 1-3 are reachable ONLY through the BaseTx hop — case (b).
write_cv "$TX5"
write_staking_tx "$TX5" "$TX4"     "$C5S" "$C5E"
write_staking_tx "$TX4" "$TXBASE"  "$C4S" "$C4E"
write_base_tx    "$TXBASE" "$TX3"
write_staking_tx "$TX3" "$TX2"     "$C3S" "$C3E"
write_staking_tx "$TX2" "$TX1"     "$C2S" "$C2E"
write_staking_tx "$TX1" "$TXIMPORT" "$C1S" "$C1E"

# run_discover <script_path> [extra VAR=val ...] — stdout/stderr captured
# separately (format checks need pure stdout), both appended to the
# aggregate leak-check log.
AGG_LOG="$TMP/record/aggregate-output.log"
: > "$AGG_LOG"
LAST_OUT=""
LAST_ERR=""
LAST_RC=0
run_discover() {
	local bin="$1"; shift
	LAST_OUT="$TMP/record/out-$$-$RANDOM.txt"
	LAST_ERR="$TMP/record/err-$$-$RANDOM.txt"
	set +e
	# NOTE: caller-supplied overrides ("$@") come LAST — env(1) lets a later
	# duplicate assignment win, so an override like UPTIME_CYCLES_JSON=…
	# must follow the fixed defaults, never precede them.
	env \
		STUB_FIXTURE_DIR="$FIX_DIR" \
		PATH="$TMP/bin:$PATH" \
		METALGO_RPC="http://127.0.0.1:9650" \
		VALIDATOR_JSON="$VALIDATOR_JSON" \
		UPTIME_CYCLES_JSON="$UPTIME_CYCLES_JSON" \
		"$@" \
		bash "$bin" > "$LAST_OUT" 2> "$LAST_ERR"
	LAST_RC=$?
	set -e
	cat "$LAST_OUT" "$LAST_ERR" >> "$AGG_LOG"
}

has_line() {
	# has_line <file> <exact line> -> echoes 1/0
	grep -qxF "$2" "$1" && echo 1 || echo 0
}

echo "=== (a)+(b) happy path: 4 closed cycles along the chain, BaseTx hop ==="
run_discover "$SCRIPT"
assert_eq "happy path exits 0" "0" "$LAST_RC"
assert_true "cycle 4 -> TX4 matched row" "$(has_line "$LAST_OUT" "$(printf '4\t%s\t%s\t%s\tmatched' "$TX4" "$C4S" "$C4E")")"
assert_true "cycle 3 -> TX3 matched row (reached THROUGH the BaseTx hop)" "$(has_line "$LAST_OUT" "$(printf '3\t%s\t%s\t%s\tmatched' "$TX3" "$C3S" "$C3E")")"
assert_true "cycle 2 -> TX2 matched row" "$(has_line "$LAST_OUT" "$(printf '2\t%s\t%s\t%s\tmatched' "$TX2" "$C2S" "$C2E")")"
assert_true "cycle 1 -> TX1 matched row" "$(has_line "$LAST_OUT" "$(printf '1\t%s\t%s\t%s\tmatched' "$TX1" "$C1S" "$C1E")")"
assert_true "in-flight TX5 listed as UNMATCHED (no closed row for cycle 5)" "$(has_line "$LAST_OUT" "$(printf 'UNMATCHED\t%s\t%s\t%s\tunmatched' "$TX5" "$C5S" "$C5E")")"
assert_eq "no NOT-FOUND row" "0" "$(grep -c 'NOT-FOUND' "$LAST_OUT" || true)"
assert_eq "exactly 4 matched rows" "4" "$(grep -c $'\tmatched$' "$LAST_OUT" || true)"
assert_true "dead-end (ImportTx ancestor) was skipped, not fatal" "$(grep -qF "dead-end at $TXIMPORT" "$LAST_ERR" && echo 1 || echo 0)"
assert_true "stderr summary counts 5 candidates / 4 matched" "$(grep -qF 'found 5 staking candidate(s), matched 4 closed cycle(s)' "$LAST_ERR" && echo 1 || echo 0)"
FORMAT_OK=$(awk -F'\t' '!( NF == 5 || (NF == 2 && $2 == "NOT-FOUND") ) { bad = 1 } END { exit bad }' "$LAST_OUT" && echo 1 || echo 0)
assert_true "every stdout row is 5 tab-fields (or the 2-field NOT-FOUND shape)" "$FORMAT_OK"

echo ""
echo "=== (c-1) MAX_DEPTH=1: only the newest closed cycle is reachable ==="
run_discover "$SCRIPT" MAX_DEPTH=1
assert_eq "depth-capped run exits 4 (cycles missing)" "4" "$LAST_RC"
assert_true "cycle 4 still matched at depth 1" "$(has_line "$LAST_OUT" "$(printf '4\t%s\t%s\t%s\tmatched' "$TX4" "$C4S" "$C4E")")"
assert_true "cycle 3 NOT-FOUND" "$(has_line "$LAST_OUT" "$(printf '3\tNOT-FOUND')")"
assert_true "cycle 2 NOT-FOUND" "$(has_line "$LAST_OUT" "$(printf '2\tNOT-FOUND')")"
assert_true "cycle 1 NOT-FOUND" "$(has_line "$LAST_OUT" "$(printf '1\tNOT-FOUND')")"

echo ""
echo "=== (c-2) a closed cycle no candidate matches -> NOT-FOUND + exit 4 ==="
UPTIME_WITH_ORPHAN="$TMP/uptime-cycles-orphan.json"
jq '.cycles = ([{"cycle_n":0,"start_unix":1600000000,"end_unix":1600100000,"final_self_stake_metal":5900}] + .cycles)' \
	"$UPTIME_CYCLES_JSON" > "$UPTIME_WITH_ORPHAN"
run_discover "$SCRIPT" UPTIME_CYCLES_JSON="$UPTIME_WITH_ORPHAN"
assert_eq "orphan-cycle run exits 4" "4" "$LAST_RC"
assert_true "orphan cycle 0 reported NOT-FOUND" "$(has_line "$LAST_OUT" "$(printf '0\tNOT-FOUND')")"
assert_eq "the 4 real cycles still matched" "4" "$(grep -c $'\tmatched$' "$LAST_OUT" || true)"

echo ""
echo "=== (d-1) RPC transport failure -> fail-closed ==="
run_discover "$SCRIPT" STUB_FAIL=1
assert_eq "transport-failure run exits 2" "2" "$LAST_RC"
assert_true "transport failure is loud on stderr (fail-closed)" "$(grep -q 'fail-closed' "$LAST_ERR" && echo 1 || echo 0)"
assert_true "transport failure prints NO result rows" "$([ ! -s "$LAST_OUT" ] && echo 1 || echo 0)"

echo ""
echo "=== (d-2) BFS root tx unreadable -> fail-closed ==="
write_cv "$TXGHOST"
run_discover "$SCRIPT"
assert_eq "ghost-root run exits 2" "2" "$LAST_RC"
assert_true "ghost root is loud on stderr (fail-closed)" "$(grep -q 'fail-closed' "$LAST_ERR" && echo 1 || echo 0)"
write_cv "$TX5"   # restore for later scenarios

echo ""
echo "=== (e) OUTPUT HYGIENE: leak canary never in any captured output ==="
# The canary address is present in EVERY tx fixture (outputs, stake,
# rewardsOwner), so any code path that echoes raw tx JSON — or any address
# field — trips this grep over the aggregate of every run above.
LEAK_HITS=$(grep -cF 'fixtureleakcanary' "$AGG_LOG" || true)
assert_eq "canary address absent from all captured stdout+stderr" "0" "$LEAK_HITS"
RAWJSON_HITS=$(grep -cF 'rewardsOwner' "$AGG_LOG" || true)
assert_eq "no raw tx JSON marker (rewardsOwner) in any captured output" "0" "$RAWJSON_HITS"

echo ""
echo "=== (e) mutation kill: the hygiene grep must catch a real leak ==="
# MUTANT: replace the script's own in-memory-only marker comment with a
# printf of the raw getTx response. If the grep above cannot catch THAT,
# it is not protecting anything.
MUTANT="$TMP/mutant-reward-backfill-discover.sh"
sed 's|# (tx JSON handled in-memory only; never echoed — see OUTPUT HYGIENE)|printf "MUTANT-RAW %s\\n" "$RESP"|' \
	"$SCRIPT" > "$MUTANT"
if diff -q "$SCRIPT" "$MUTANT" >/dev/null 2>&1; then
	FAIL=$((FAIL + 1))
	FAILURES+=("mutation kill: sed produced no diff — marker comment not matched, mutation not applied")
	echo "  FAIL  mutant sed produced no diff — marker comment not matched"
else
	MUT_AGG="$TMP/record/aggregate-mutant.log"
	SAVE_AGG="$AGG_LOG"
	AGG_LOG="$MUT_AGG"
	: > "$AGG_LOG"
	run_discover "$MUTANT"
	AGG_LOG="$SAVE_AGG"
	assert_eq "mutant still exits 0 on the happy path (leak, not crash)" "0" "$LAST_RC"
	MUT_HITS=$(grep -cF 'fixtureleakcanary' "$MUT_AGG" || true)
	if [ "$MUT_HITS" -gt 0 ]; then
		PASS=$((PASS + 1))
		printf '  PASS  mutant (raw-response printf) DOES leak the canary (%s hits) — the hygiene grep has teeth\n' "$MUT_HITS"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("mutation kill: mutant leaked nothing — the hygiene grep is not sensitive")
		echo "  FAIL  mutant unexpectedly leaked nothing — hygiene grep is not sensitive"
	fi
fi

echo ""
echo "=== (f) no broadcast-shape string; method allowlist is exactly 2 ==="
# Needles are concatenated so THIS file never contains them either (same
# idiom as tests/cycle-context/test-cycle-context.sh T12).
FORBIDDEN_A="pro""ton"
FORBIDDEN_B="cle""os"
FORBIDDEN_C="safe-""broadcast"
FORBIDDEN_D="push_""transaction"
FORBIDDEN_E="issue""Tx"
FORBIDDEN_F="eth_""sendRawTransaction"
FORBIDDEN_G="send_""transaction"
for needle in "$FORBIDDEN_A" "$FORBIDDEN_B" "$FORBIDDEN_C" "$FORBIDDEN_D" "$FORBIDDEN_E" "$FORBIDDEN_F" "$FORBIDDEN_G"; do
	if grep -qF -- "$needle" "$SCRIPT"; then
		FAIL=$((FAIL + 1))
		FAILURES+=("forbidden string '$needle' present in scripts/reward-backfill-discover.sh")
		printf '  FAIL  forbidden string %s present in the script\n' "$needle"
	else
		PASS=$((PASS + 1))
		printf '  PASS  forbidden string %s absent from the script\n' "$needle"
	fi
done
METHODS_FOUND=$(grep -ohE 'platform\.[A-Za-z]+' "$SCRIPT" | sort -u | tr '\n' ' ')
assert_eq "only the two read-only RPC methods appear in the script" \
	"platform.getCurrentValidators platform.getTx " "$METHODS_FOUND"

echo ""
echo "test-reward-backfill-discover.sh summary: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
