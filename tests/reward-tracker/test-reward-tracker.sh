#!/usr/bin/env bash
# tests/reward-tracker/test-reward-tracker.sh — end-to-end behavior test for
# scripts/reward-tracker.sh against a stub metalgo RPC (curl) and a stub
# ntfy delivery (also curl, intercepted by the same stub — see below).
#
# CHAIN: none. No real P-Chain node, no real ntfy.sh delivery — the ONLY
# `curl` on PATH during these runs is the stub built below, which never
# makes a network connection. Per the task brief, P-Chain is never contacted
# for real (not available on this Mac); every scenario is a fixture.
#
# Covers (per the reward-tracker.sh task brief):
#   1. append 1-line shape (schema fields present)
#   2. append-only: a re-run against the same matured cycle does not
#      duplicate the line, including the "append happened, state advance
#      didn't" crash-recovery shape
#   3. maturity detection fires exactly when the tracked AddValidatorTx
#      disappears from getCurrentValidators AND uptime-cycles.json's most
#      recently closed row confirms the same end_unix
#   4. digest-line format (累積 first, per the operator's ordering
#      requirement; projection segment; milestone tail)
#   5. numeric non-leak: reward-tracker.sh's own combined stdout+stderr,
#      across every scenario below, never contains a METAL amount — proven
#      with a mutation-kill check (a MUTANT copy with one added debug echo
#      of the reward amount must fail this exact grep)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TRACKER="$REPO/scripts/reward-tracker.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILURES=()

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %-65s expected=%s actual=%s\n' "$label" "$expected" "$actual"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected=$expected, actual=$actual)")
		printf '  FAIL  %-65s expected=%s actual=%s\n' "$label" "$expected" "$actual"
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
# Fixture UTXO hex — hand-built the same way tests/reward-tracker/
# test-reward-utxo-decode.sh does (see that file for the byte-layout
# citation): self-reward 50.5 METAL + delegatee-fee-reward 12.25 METAL,
# both under the tracked validator's own AddValidatorTx (TX1) — the exact
# shape metalgo's rewardValidatorTx() produces (see reward-tracker.sh's own
# header for the citation).
# ===========================================================================
build_utxo_hex() {
	python3 - "$1" <<'PY'
import sys
amt = int(sys.argv[1])
parts = [
    b'\x00\x00', bytes([0x11]) * 32, (0).to_bytes(4, 'big'),
    bytes([0x22]) * 32, (7).to_bytes(4, 'big'), amt.to_bytes(8, 'big'),
    (0).to_bytes(8, 'big'), (1).to_bytes(4, 'big'), (1).to_bytes(4, 'big'),
    bytes([0x33]) * 20,
]
print('0x' + b''.join(parts).hex())
PY
}
SELF_REWARD_HEX="$(build_utxo_hex 50500000000)"   # 50.5 METAL
FEE_REWARD_HEX="$(build_utxo_hex 12250000000)"    # 12.25 METAL
# Expected combined reward for TX1's maturity: 50.5 + 12.25 = 62.75 METAL
EXPECTED_REWARD="62.750000000"

# ===========================================================================
# Sandbox layout
# ===========================================================================
STATE_DIR="$TMP/state"
UPTIME_STATE_DIR="$TMP/uptime-state"
mkdir -p "$STATE_DIR" "$UPTIME_STATE_DIR" "$TMP/public" "$TMP/bin" "$TMP/record"

VALIDATOR_JSON="$TMP/public/validator.json"
UPTIME_CYCLES_JSON="$TMP/public/uptime-cycles.json"
FIX_DIR="$TMP/fixtures"
mkdir -p "$FIX_DIR"

REWARDS_HISTORY="$STATE_DIR/rewards-history.jsonl"
TRACKER_STATE="$STATE_DIR/reward-tracker-state.json"
DIGEST_FILE="$STATE_DIR/reward-digest-line.txt"
NTFY_LOG="$TMP/record/ntfy-bodies.log"

NODE_ID="NodeID-testFixtureNode11111111111"
TX1="tx1FixtureAddValidator1111111111111"
TX2="tx2FixtureAddValidator2222222222222"
TX_BACKFILL="txBackfillHistoricalCycle33333"

TRACKED_START=1700000000
TRACKED_END=$((TRACKED_START + 2849105))   # same duration as the calculator fixture
CYCLE2_END=$((TRACKED_END + 2800000))

echo "{\"nodeId\":\"$NODE_ID\",\"stake\":{\"self\":2000}}" > "$VALIDATOR_JSON"
printf '{"cycles":[]}\n' > "$UPTIME_CYCLES_JSON"
echo '{"cycle_n":7}' > "$STATE_DIR/current-cycle-state.json"

# ---- stub curl -------------------------------------------------------------
# Routes by scanning argv for the first http(s) URL (position varies between
# reward-tracker's own RPC calls and notify.sh's ntfy.sh call — see header)
# and, for the RPC route, by the JSON body's "method" field. ntfy posts are
# recorded (never sent) so the notification test can assert on body content
# without a real ntfy.sh delivery.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
URL=""
DATA=""
HEADERS=""
prev=""
for a in "$@"; do
	case "$prev" in
		-d|--data) DATA="$a" ;;
		-H) HEADERS="${HEADERS}${a}
" ;;
	esac
	case "$a" in
		http*://*) URL="$a" ;;
	esac
	prev="$a"
done

if [[ "$URL" == *"ntfy.sh"* ]]; then
	{
		echo "---"
		printf '%s' "$HEADERS"
		printf '%s\n' "$DATA"
	} >> "$STUB_RECORD_DIR/ntfy-bodies.log"
	echo "ntfy POST: 200"
	exit 0
fi

METHOD=$(printf '%s' "$DATA" | grep -oE '"method":"[a-zA-Z.]+"' | head -1 | sed -E 's/.*:"([a-zA-Z.]+)"/\1/')
case "$METHOD" in
	platform.getCurrentValidators) cat "$STUB_FIXTURE_DIR/getCurrentValidators.json" ;;
	platform.getRewardUTXOs)       cat "$STUB_FIXTURE_DIR/getRewardUTXOs.json" ;;
	platform.getCurrentSupply)     cat "$STUB_FIXTURE_DIR/getCurrentSupply.json" ;;
	*)
		echo "stub curl: unrecognized method in body: $DATA" >&2
		exit 1
		;;
esac
exit 0
STUB
chmod +x "$TMP/bin/curl"

# Test-local stand-in for util-linux flock, installed ONLY when the host has
# none (macOS has no flock by default) — same pattern as
# tests/side-effects-callers/test-monitoring-side-effects.sh (see that
# suite's header). It always reports "acquired" and does NOT implement real
# locking, so this suite can only verify reward-tracker.sh's flock CALL
# SHAPE (lock file gets created under state/locks/, the script runs to
# completion through the -n flock call rather than dying on it) — not real
# cross-process exclusion, which needs a genuine flock and belongs in a
# Linux-only integration suite if ever added. See the dedicated "flock"
# section below for the one thing this stand-in DOES let us assert: on a
# host with a REAL flock, holding the lock file open externally makes
# reward-tracker.sh's own flock -n fail and the run skip cleanly (exit 0,
# no state mutated) — that case is SKIPped, not faked, when only the
# stand-in is available.
if ! command -v flock >/dev/null 2>&1; then
	cat > "$TMP/bin/flock" <<'FLOCKEOF'
#!/usr/bin/env bash
exit 0
FLOCKEOF
	chmod +x "$TMP/bin/flock"
fi

echo "test-topic" > "$TMP/ntfy-topic"

# write_getCurrentValidators <txID> <start> <end> <weight_nmetal> <fee_pct> <delegators_json_array>
write_getCurrentValidators() {
	local tx="$1" su="$2" eu="$3" w="$4" fee="$5" delegators="$6"
	cat > "$FIX_DIR/getCurrentValidators.json" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"validators":[{"nodeID":"$NODE_ID","txID":"$tx","startTime":"$su","endTime":"$eu","weight":"$w","delegationFee":$fee,"delegators":$delegators}]}}
JSON
}

write_getCurrentValidators_absent() {
	echo '{"jsonrpc":"2.0","id":1,"result":{"validators":[]}}' > "$FIX_DIR/getCurrentValidators.json"
}

write_getRewardUTXOs() {
	# $1 = space-separated hex strings (may be empty for a 0-reward cycle)
	local hexes="$1" json_arr="[]"
	if [ -n "$hexes" ]; then
		json_arr=$(python3 -c "
import json, sys
print(json.dumps(sys.argv[1:]))
" $hexes)
	fi
	cat > "$FIX_DIR/getRewardUTXOs.json" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"numFetched":"$(echo "$hexes" | wc -w | tr -d ' ')","utxos":$json_arr,"encoding":"hex"}}
JSON
}

write_getCurrentSupply() {
	local supply_n="$1"
	echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"supply\":\"$supply_n\",\"height\":\"12345\"}}" > "$FIX_DIR/getCurrentSupply.json"
}

# run_tracker <FY_LIVE 0|1> [args...] — invokes reward-tracker.sh in the
# sandbox, capturing combined stdout+stderr to $LAST_OUT and rc to $LAST_RC.
LAST_OUT=""
LAST_RC=0
run_tracker() {
	local live="$1"; shift
	LAST_OUT="$TMP/record/out-$$-$RANDOM.txt"
	set +e
	STUB_FIXTURE_DIR="$FIX_DIR" STUB_RECORD_DIR="$TMP/record" \
		PATH="$TMP/bin:$PATH" \
		METALGO_RPC="http://127.0.0.1:9650" \
		VALIDATOR_JSON="$VALIDATOR_JSON" \
		UPTIME_CYCLES_JSON="$UPTIME_CYCLES_JSON" \
		FY_STATE_DIR="$STATE_DIR" \
		UPTIME_STATE_DIR="$UPTIME_STATE_DIR" \
		NTFY_TOPIC_FILE="$TMP/ntfy-topic" \
		FY_LIVE="$live" \
		bash "$TRACKER" "$@" > "$LAST_OUT" 2>&1
	LAST_RC=$?
	set -e
}

echo "=== bootstrap run (no prior state) ==="
write_getCurrentValidators "$TX1" "$TRACKED_START" "$TRACKED_END" "2000000000000" "3.0" \
	"[{\"weight\":\"8845000000000\",\"startTime\":\"$TRACKED_START\",\"endTime\":\"$TRACKED_END\"}]"
write_getCurrentSupply "350000000000000000"
run_tracker 1
assert_eq "bootstrap run exits 0" "0" "$LAST_RC"
TRACKED_TX_AFTER_BOOTSTRAP="$(jq -r '.tracked_tx' "$TRACKER_STATE" 2>/dev/null)"
assert_eq "state now tracks TX1" "$TX1" "$TRACKED_TX_AFTER_BOOTSTRAP"
assert_true "no rewards-history.jsonl yet (nothing matured)" "$([ ! -s "$REWARDS_HISTORY" ] && echo 1 || echo 0)"
assert_true "digest file was written" "$([ -s "$DIGEST_FILE" ] && echo 1 || echo 0)"

echo ""
echo "=== flock (K-4-style non-blocking exclusion) ==="
LOCK_FILE_PATH="$STATE_DIR/locks/reward-tracker.lock"
assert_true "lock file was created under state/locks/" "$([ -e "$LOCK_FILE_PATH" ] && echo 1 || echo 0)"

# Real cross-process contention needs a genuine flock (see the stand-in's
# own note above this file's fixture setup) — this Mac almost certainly
# does not have one. Run the case for real wherever flock IS genuine
# (e.g. the Linux validator host, or a Linux CI runner) rather than fake
# it with the always-succeed stand-in, which would prove nothing.
if command -v flock >/dev/null 2>&1 && [ "$(command -v flock)" != "$TMP/bin/flock" ]; then
	# Hold the SAME lock file open in this shell (fd 8), non-blocking, so
	# reward-tracker.sh's own -n flock on fd 9 must fail while we hold it.
	exec 8>"$LOCK_FILE_PATH"
	flock -n 8
	PRE_LINES="$(wc -l < "$REWARDS_HISTORY" 2>/dev/null | tr -d " ")"
	[ -z "$PRE_LINES" ] && PRE_LINES=0
	run_tracker 1
	assert_eq "held-lock run exits 0 (skip, not an error)" "0" "$LAST_RC"
	assert_true "held-lock run logged a skip, not a normal completion" "$(grep -q 'still holds the lock' "$LAST_OUT" && echo 1 || echo 0)"
	POST_LINES="$(wc -l < "$REWARDS_HISTORY" 2>/dev/null | tr -d " ")"
	[ -z "$POST_LINES" ] && POST_LINES=0
	assert_eq "held-lock run did not append (state untouched)" "$PRE_LINES" "$POST_LINES"
	exec 8>&-
else
	echo "  SKIP  real-lock contention case (no genuine flock on this host — see the stand-in note)"
fi

echo ""
echo "=== same-cycle re-run (TX1 still current) ==="
run_tracker 1
assert_eq "same-cycle run exits 0" "0" "$LAST_RC"
assert_true "still no rewards-history.jsonl (nothing matured)" "$([ ! -s "$REWARDS_HISTORY" ] && echo 1 || echo 0)"

echo ""
echo "=== digest line format ==="
DIGEST_CONTENT="$(cat "$DIGEST_FILE")"
echo "  (captured, format-checked below — not printed raw to avoid a false leak-check trip in THIS echo; see the grep assertions)"
CUM_FIRST_OK=$(printf '%s' "$DIGEST_CONTENT" | grep -qE '^累積 [0-9,]+ METAL' && echo 1 || echo 0)
assert_true "digest line starts with 累積 (cumulative-first ordering)" "$CUM_FIRST_OK"
PROJECTION_OK=$(printf '%s' "$DIGEST_CONTENT" | grep -qE 'Cycle 7 見込み \+[0-9.]+ \([0-9]+/[0-9]+ days\)' && echo 1 || echo 0)
assert_true "digest line carries the Cycle N 見込み +X.X (d/D days) segment" "$PROJECTION_OK"
MILESTONE_OK=$(printf '%s' "$DIGEST_CONTENT" | grep -qE '25,000 (まで残り [0-9,.]+|到達 🎉)$' && echo 1 || echo 0)
assert_true "digest line ends with the 25,000 milestone tail" "$MILESTONE_OK"

echo ""
echo "=== maturity: TX1 disappears, TX2 takes over, uptime-cycles.json NOT yet updated ==="
write_getCurrentValidators "$TX2" "$TRACKED_END" "$CYCLE2_END" "2000000000000" "3.0" "[]"
run_tracker 1
assert_eq "run with stale uptime-cycles.json still exits 0 (defers, not an error)" "0" "$LAST_RC"
STILL_TX1="$(jq -r '.tracked_tx' "$TRACKER_STATE")"
assert_eq "state NOT advanced while uptime-cycles.json is stale (retries next run)" "$TX1" "$STILL_TX1"
assert_true "no reward recorded yet (deferred, correctly)" "$([ ! -s "$REWARDS_HISTORY" ] && echo 1 || echo 0)"

echo ""
echo "=== uptime-cycles.json catches up; maturity now resolves ==="
cat > "$UPTIME_CYCLES_JSON" <<JSON
{"cycles":[{"cycle_n":7,"start_unix":$TRACKED_START,"end_unix":$TRACKED_END,"final_self_stake_metal":2000}]}
JSON
write_getRewardUTXOs "$SELF_REWARD_HEX $FEE_REWARD_HEX"
echo '{"cycle_n":8}' > "$STATE_DIR/current-cycle-state.json"

echo ""
echo "=== dry mode (FY_LIVE unset): a real maturity is detectable but every"
echo "    side effect must be suppressed ==="
# Fixtures at this point already describe a genuine, resolvable maturity
# (uptime-cycles.json caught up two lines above, getRewardUTXOs set) — dry
# mode must recognize it (same detection logic) but touch nothing durable.
DRY_PRE_HISTORY_LINES=$([ -f "$REWARDS_HISTORY" ] && wc -l < "$REWARDS_HISTORY" | tr -d ' ' || echo 0)
DRY_PRE_TRACKED_TX="$(jq -r '.tracked_tx' "$TRACKER_STATE")"
DRY_PRE_NTFY_LINES=$([ -f "$NTFY_LOG" ] && wc -l < "$NTFY_LOG" | tr -d ' ' || echo 0)
DRY_PRE_DIGEST_MTIME=""
[ -f "$DIGEST_FILE" ] && DRY_PRE_DIGEST_MTIME="$(stat -f '%m' "$DIGEST_FILE" 2>/dev/null || stat -c '%Y' "$DIGEST_FILE" 2>/dev/null)"

run_tracker 0
assert_eq "dry run exits 0" "0" "$LAST_RC"

# (a) no append
DRY_POST_HISTORY_LINES=$([ -f "$REWARDS_HISTORY" ] && wc -l < "$REWARDS_HISTORY" | tr -d ' ' || echo 0)
assert_eq "(a) dry run: rewards-history.jsonl line count unchanged" "$DRY_PRE_HISTORY_LINES" "$DRY_POST_HISTORY_LINES"

# state file itself: fyd_live_write's dry path leaves it byte-for-byte
# untouched (see scripts/lib/side-effects.sh), so tracked_tx must still read
# whatever it was before this dry run (TX1 — the maturity was DETECTED, per
# the "DRY:" note in stdout below, but never recorded).
DRY_POST_TRACKED_TX="$(jq -r '.tracked_tx' "$TRACKER_STATE")"
assert_eq "(a) dry run: tracked_tx state file left untouched" "$DRY_PRE_TRACKED_TX" "$DRY_POST_TRACKED_TX"

# (b) no notify
DRY_POST_NTFY_LINES=$([ -f "$NTFY_LOG" ] && wc -l < "$NTFY_LOG" | tr -d ' ' || echo 0)
assert_eq "(b) dry run: no ntfy push recorded (fyd_notify never invokes the delegate when dry)" "$DRY_PRE_NTFY_LINES" "$DRY_POST_NTFY_LINES"

# (c) no digest write — fyd_live_write's dry path never creates a file that
# did not already exist, and never touches the mtime of one that did.
if [ -n "$DRY_PRE_DIGEST_MTIME" ]; then
	DRY_POST_DIGEST_MTIME="$(stat -f '%m' "$DIGEST_FILE" 2>/dev/null || stat -c '%Y' "$DIGEST_FILE" 2>/dev/null)"
	assert_eq "(c) dry run: digest file mtime unchanged (not rewritten)" "$DRY_PRE_DIGEST_MTIME" "$DRY_POST_DIGEST_MTIME"
else
	assert_true "(c) dry run: digest file still does not exist (never created while dry)" "$([ ! -e "$DIGEST_FILE" ] && echo 1 || echo 0)"
fi

# The run DID recognize the maturity (a real "would append" DRY note), so
# this is not just "dry mode does nothing" — confirm the detection path was
# actually reached, distinguishing "correctly suppressed" from "never ran".
assert_true "dry run's own log shows it reached the append/notify DRY path (not a silent no-op)" "$(grep -q 'DRY:' "$LAST_OUT" && echo 1 || echo 0)"

# (d) no numeric leak, in dry mode specifically (mirrors the live-mode
# non-leak check further down, scoped to just this one dry invocation).
DRY_LEAK_HITS=$(grep -oE '[0-9][0-9,]*\.[0-9]+' "$LAST_OUT" || true)
assert_true "(d) dry run: zero decimal-number matches in stdout+stderr" "$([ -z "$DRY_LEAK_HITS" ] && echo 1 || echo 0)"

run_tracker 1
assert_eq "maturity run exits 0" "0" "$LAST_RC"
assert_eq "rewards-history.jsonl now has exactly 1 line" "1" "$(wc -l < "$REWARDS_HISTORY" | tr -d ' ')"

LINE1_JSON="$(sed -n '1p' "$REWARDS_HISTORY")"
assert_eq "line: cycle_n" "7" "$(echo "$LINE1_JSON" | jq -r '.cycle_n')"
assert_eq "line: reward_metal (self 50.5 + fee 12.25)" "$EXPECTED_REWARD" "$(echo "$LINE1_JSON" | jq -r '.reward_metal')"
assert_eq "line: self_stake_metal (tracked weight 2000 METAL)" "2000.000000000" "$(echo "$LINE1_JSON" | jq -r '.self_stake_metal')"
assert_eq "line: start_unix" "$TRACKED_START" "$(echo "$LINE1_JSON" | jq -r '.start_unix')"
assert_eq "line: end_unix" "$TRACKED_END" "$(echo "$LINE1_JSON" | jq -r '.end_unix')"
assert_eq "line: add_validator_tx" "$TX1" "$(echo "$LINE1_JSON" | jq -r '.add_validator_tx')"
HAS_OBSERVED_AT=$(echo "$LINE1_JSON" | jq -r 'has("observed_at")')
assert_eq "line: has observed_at" "true" "$HAS_OBSERVED_AT"

NEW_TRACKED="$(jq -r '.tracked_tx' "$TRACKER_STATE")"
assert_eq "state advanced to TX2 after recording TX1's maturity" "$TX2" "$NEW_TRACKED"

assert_true "ntfy body was recorded (notify fired)" "$([ -s "$NTFY_LOG" ] && echo 1 || echo 0)"
CUM_BEFORE_THIS_CYCLE_OK=$(grep -qE '累積 [0-9,.]+ METAL \(\+[0-9,.]+ this cycle\)' "$NTFY_LOG" && echo 1 || echo 0)
assert_true "notify body: 累積 comes before this-cycle delta (operator's ordering requirement)" "$CUM_BEFORE_THIS_CYCLE_OK"
assert_true "notify body: names Cycle 7" "$(grep -q 'Cycle 7 reward' "$NTFY_LOG" && echo 1 || echo 0)"

echo ""
echo "=== append-only: re-run against the now-matured TX1 does not duplicate ==="
run_tracker 1
assert_eq "re-run (TX2 still current) exits 0" "0" "$LAST_RC"
assert_eq "rewards-history.jsonl STILL has exactly 1 line (no duplicate)" "1" "$(wc -l < "$REWARDS_HISTORY" | tr -d ' ')"

echo ""
echo "=== crash-recovery shape: append succeeded once, simulate state not having advanced ==="
jq --arg tx "$TX1" '.tracked_tx = $tx | .tracked_end_unix = '"$TRACKED_END" "$TRACKER_STATE" > "$TRACKER_STATE.tmp" && mv "$TRACKER_STATE.tmp" "$TRACKER_STATE"
run_tracker 1
assert_eq "recovery run exits 0" "0" "$LAST_RC"
assert_eq "rewards-history.jsonl STILL exactly 1 line (dedupe via history_has_tx)" "1" "$(wc -l < "$REWARDS_HISTORY" | tr -d ' ')"
RECOVERED_TX="$(jq -r '.tracked_tx' "$TRACKER_STATE")"
assert_eq "state re-advanced to TX2 without a second append" "$TX2" "$RECOVERED_TX"

echo ""
echo "=== --backfill ==="
write_getRewardUTXOs "$(build_utxo_hex 9990000000)"   # 9.99 METAL, single UTXO
cat > "$UPTIME_CYCLES_JSON" <<JSON
{"cycles":[{"cycle_n":7,"start_unix":$TRACKED_START,"end_unix":$TRACKED_END,"final_self_stake_metal":2000},{"cycle_n":3,"start_unix":1600000000,"end_unix":1602800000,"final_self_stake_metal":1500}]}
JSON
run_tracker 1 --backfill "$TX_BACKFILL" 3
assert_eq "backfill run exits 0" "0" "$LAST_RC"
assert_eq "rewards-history.jsonl now has 2 lines" "2" "$(wc -l < "$REWARDS_HISTORY" | tr -d ' ')"
LINE2_JSON="$(sed -n '2p' "$REWARDS_HISTORY")"
assert_eq "backfilled line: cycle_n=3" "3" "$(echo "$LINE2_JSON" | jq -r '.cycle_n')"
assert_eq "backfilled line: reward_metal=9.99 METAL" "9.990000000" "$(echo "$LINE2_JSON" | jq -r '.reward_metal')"
assert_eq "backfilled line: self_stake_metal from uptime-cycles.json (1500)" "1500" "$(echo "$LINE2_JSON" | jq -r '.self_stake_metal')"
NTFY_COUNT_BEFORE_BACKFILL=$(grep -c '^---$' "$NTFY_LOG" || true)

run_tracker 1 --backfill "$TX_BACKFILL" 3
assert_eq "re-running the SAME backfill exits 0 (idempotent no-op)" "0" "$LAST_RC"
assert_eq "rewards-history.jsonl still 2 lines after repeat backfill" "2" "$(wc -l < "$REWARDS_HISTORY" | tr -d ' ')"
NTFY_COUNT_AFTER_BACKFILL=$(grep -c '^---$' "$NTFY_LOG" || true)
assert_eq "backfill never sends a notification (see header rationale)" "$NTFY_COUNT_BEFORE_BACKFILL" "$NTFY_COUNT_AFTER_BACKFILL"

echo ""
echo "=== zero-reward maturity: no tada, no 🎉, warning-tagged push ==="
# TX2 (currently tracked, per the crash-recovery section above) matures with
# ZERO reward UTXOs — the shape metalgo produces when the 80% uptime
# requirement was missed for that cycle (see reward-tracker.sh's own
# header note on why this is never a "not yet paid" race). TX3 replaces it.
TX3="tx3FixtureAddValidator3333333333333"
CYCLE3_END=$((CYCLE2_END + 2800000))
cat > "$UPTIME_CYCLES_JSON" <<JSON
{"cycles":[{"cycle_n":7,"start_unix":$TRACKED_START,"end_unix":$TRACKED_END,"final_self_stake_metal":2000},{"cycle_n":8,"start_unix":$TRACKED_END,"end_unix":$CYCLE2_END,"final_self_stake_metal":2000}]}
JSON
write_getCurrentValidators "$TX3" "$CYCLE2_END" "$CYCLE3_END" "2000000000000" "3.0" "[]"
write_getRewardUTXOs ""
NTFY_LINES_BEFORE_ZERO=$(wc -l < "$NTFY_LOG" | tr -d ' ')
run_tracker 1
assert_eq "zero-reward maturity run exits 0" "0" "$LAST_RC"
assert_eq "rewards-history.jsonl now has 3 lines" "3" "$(wc -l < "$REWARDS_HISTORY" | tr -d ' ')"
LINE3_JSON="$(sed -n '3p' "$REWARDS_HISTORY")"
assert_eq "zero-reward line: cycle_n=8" "8" "$(echo "$LINE3_JSON" | jq -r '.cycle_n')"
assert_eq "zero-reward line: reward_metal=0 (jq-normalized, not 0E-9)" "0" "$(echo "$LINE3_JSON" | jq -r '.reward_metal')"
assert_eq "zero-reward line: add_validator_tx=TX2" "$TX2" "$(echo "$LINE3_JSON" | jq -r '.add_validator_tx')"

ZERO_PUSH="$(tail -n +"$((NTFY_LINES_BEFORE_ZERO + 1))" "$NTFY_LOG")"
assert_true "zero-reward push recorded" "$([ -n "$ZERO_PUSH" ] && echo 1 || echo 0)"
assert_true "zero-reward push title carries no 🎉" "$(printf '%s' "$ZERO_PUSH" | grep -q '🎉' && echo 0 || echo 1)"
assert_true "zero-reward push body: '0 METAL — check uptime'" "$(printf '%s' "$ZERO_PUSH" | grep -q 'reward: 0 METAL — check uptime' && echo 1 || echo 0)"
assert_true "zero-reward push Tags header is NOT tada" "$(printf '%s' "$ZERO_PUSH" | grep -qx 'Tags: tada' && echo 0 || echo 1)"
# No --tags override was passed, so notify.sh falls back to its own
# priority-derived default for "high" — see notify.sh's TAGS case block.
assert_true "zero-reward push Tags header falls back to priority-derived 'warning'" "$(printf '%s' "$ZERO_PUSH" | grep -qx 'Tags: warning' && echo 1 || echo 0)"

# Mutation kill check: a mutant that always treats REWARD_METAL as non-zero
# (comment out the guard) must send the celebratory push instead — proving
# the assertions above actually exercise the branch, not just its absence.
ZERO_MUTANT_ROOT="$TMP/zero-mutant-root"
mkdir -p "$ZERO_MUTANT_ROOT/scripts"
ln -s "$REPO/scripts/lib" "$ZERO_MUTANT_ROOT/scripts/lib"
# fyd_notify resolves its delegate as ${FYD_SCRIPTS_DIR}/notify.sh, where
# FYD_SCRIPTS_DIR is the PARENT of side-effects.sh's own directory — i.e.
# this mutant root's own scripts/, not the real repo's. Without this
# symlink fyd_notify fails closed ("delegate not readable") and NO push
# is ever attempted, which would make this mutation-kill check pass for
# the wrong reason (silence, not a wrongly-celebratory push).
ln -s "$REPO/scripts/notify.sh" "$ZERO_MUTANT_ROOT/scripts/notify.sh"
ZERO_MUTANT="$ZERO_MUTANT_ROOT/scripts/reward-tracker.sh"
sed 's/if \[ "\$REWARD_IS_ZERO" = "1" \]; then/if [ "0" = "1" ]; then/' "$TRACKER" > "$ZERO_MUTANT"
chmod +x "$ZERO_MUTANT"
if diff -q "$TRACKER" "$ZERO_MUTANT" >/dev/null 2>&1; then
	FAIL=$((FAIL + 1))
	FAILURES+=("zero-reward mutation kill check: sed produced no diff — guard not matched")
	echo "  FAIL  zero-reward mutant sed produced no diff — guard not matched"
else
	# Re-run the SAME zero-reward scenario one more cycle forward (TX3 -> TX4)
	# against the MUTANT binary, so the guard is disabled but everything else
	# (fixtures, state) is realistic.
	TX4="tx4FixtureAddValidator4444444444444"
	CYCLE4_END=$((CYCLE3_END + 2800000))
	cat > "$UPTIME_CYCLES_JSON" <<JSON
{"cycles":[{"cycle_n":7,"start_unix":$TRACKED_START,"end_unix":$TRACKED_END,"final_self_stake_metal":2000},{"cycle_n":8,"start_unix":$TRACKED_END,"end_unix":$CYCLE2_END,"final_self_stake_metal":2000},{"cycle_n":9,"start_unix":$CYCLE2_END,"end_unix":$CYCLE3_END,"final_self_stake_metal":2000}]}
JSON
	write_getCurrentValidators "$TX4" "$CYCLE3_END" "$CYCLE4_END" "2000000000000" "3.0" "[]"
	write_getRewardUTXOs ""
	NTFY_LINES_BEFORE_MUTANT=$(wc -l < "$NTFY_LOG" | tr -d ' ')
	set +e
	STUB_FIXTURE_DIR="$FIX_DIR" STUB_RECORD_DIR="$TMP/record" PATH="$TMP/bin:$PATH" \
		METALGO_RPC="http://127.0.0.1:9650" VALIDATOR_JSON="$VALIDATOR_JSON" \
		UPTIME_CYCLES_JSON="$UPTIME_CYCLES_JSON" FY_STATE_DIR="$STATE_DIR" \
		UPTIME_STATE_DIR="$UPTIME_STATE_DIR" NTFY_TOPIC_FILE="$TMP/ntfy-topic" \
		FY_LIVE=1 bash "$ZERO_MUTANT" > "$TMP/zero-mutant-out.txt" 2>&1
	ZERO_MUTANT_RC=$?
	set -e
	assert_eq "zero-reward mutant ran to completion (rc=0, not crashed)" "0" "$ZERO_MUTANT_RC"
	MUTANT_ZERO_PUSH="$(tail -n +"$((NTFY_LINES_BEFORE_MUTANT + 1))" "$NTFY_LOG")"
	if printf '%s' "$MUTANT_ZERO_PUSH" | grep -q '🎉'; then
		PASS=$((PASS + 1))
		printf '  PASS  mutant (REWARD_IS_ZERO guard disabled) sends the celebratory 🎉 push for a 0-METAL cycle — the guard is load-bearing\n'
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("zero-reward mutation kill check: mutant still did not celebrate a 0-METAL cycle")
		echo "  FAIL  zero-reward mutant unexpectedly still sent the non-celebratory push"
	fi
fi


echo ""
echo "=== numeric non-leak: no METAL amount ever appears in stdout/stderr ==="
# Re-run the full scenario sequence once more end-to-end, capturing every
# invocation's combined output into one aggregate log, then grep it. A
# METAL amount looks like one or more digits, optionally comma-grouped,
# optionally with a decimal fraction — checked broadly (not just "X.YY
# METAL") because the constitution's ask is "no METAL number", not "no
# number shaped exactly like the notify body's own formatting".
AGG_LOG="$TMP/record/aggregate-leak-check.log"
: > "$AGG_LOG"

replay_full_scenario() {
	local out_dir="$1" tracker_bin="$2"
	local st="$out_dir/state" ust="$out_dir/uptime-state" fx="$out_dir/fixtures"
	mkdir -p "$st" "$ust" "$fx"
	echo "{\"nodeId\":\"$NODE_ID\",\"stake\":{\"self\":2000}}" > "$out_dir/validator.json"
	echo '{"cycle_n":7}' > "$st/current-cycle-state.json"
	printf '{"cycles":[]}\n' > "$out_dir/uptime-cycles.json"

	cat > "$fx/getCurrentValidators.json" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"validators":[{"nodeID":"$NODE_ID","txID":"$TX1","startTime":"$TRACKED_START","endTime":"$TRACKED_END","weight":"2000000000000","delegationFee":3.0,"delegators":[{"weight":"8845000000000","startTime":"$TRACKED_START","endTime":"$TRACKED_END"}]}]}}
JSON
	echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"supply\":\"350000000000000000\",\"height\":\"1\"}}" > "$fx/getCurrentSupply.json"

	local out1="$out_dir/o1.txt"
	STUB_FIXTURE_DIR="$fx" STUB_RECORD_DIR="$out_dir" PATH="$TMP/bin:$PATH" \
		METALGO_RPC="http://127.0.0.1:9650" VALIDATOR_JSON="$out_dir/validator.json" \
		UPTIME_CYCLES_JSON="$out_dir/uptime-cycles.json" FY_STATE_DIR="$st" \
		UPTIME_STATE_DIR="$ust" NTFY_TOPIC_FILE="$TMP/ntfy-topic" FY_LIVE=1 \
		bash "$tracker_bin" > "$out1" 2>&1
	cat "$out1" >> "$AGG_LOG"

	cat > "$fx/getCurrentValidators.json" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"validators":[{"nodeID":"$NODE_ID","txID":"$TX2","startTime":"$TRACKED_END","endTime":"$CYCLE2_END","weight":"2000000000000","delegationFee":3.0,"delegators":[]}]}}
JSON
	cat > "$out_dir/uptime-cycles.json" <<JSON
{"cycles":[{"cycle_n":7,"start_unix":$TRACKED_START,"end_unix":$TRACKED_END,"final_self_stake_metal":2000}]}
JSON
	python3 -c "
import json
print(json.dumps({'jsonrpc':'2.0','id':1,'result':{'numFetched':'2','utxos':['$SELF_REWARD_HEX','$FEE_REWARD_HEX'],'encoding':'hex'}}))
" > "$fx/getRewardUTXOs.json"
	local out2="$out_dir/o2.txt"
	STUB_FIXTURE_DIR="$fx" STUB_RECORD_DIR="$out_dir" PATH="$TMP/bin:$PATH" \
		METALGO_RPC="http://127.0.0.1:9650" VALIDATOR_JSON="$out_dir/validator.json" \
		UPTIME_CYCLES_JSON="$out_dir/uptime-cycles.json" FY_STATE_DIR="$st" \
		UPTIME_STATE_DIR="$ust" NTFY_TOPIC_FILE="$TMP/ntfy-topic" FY_LIVE=1 \
		bash "$tracker_bin" > "$out2" 2>&1
	cat "$out2" >> "$AGG_LOG"
}

REAL_DIR="$TMP/leak-real"
mkdir -p "$REAL_DIR"
replay_full_scenario "$REAL_DIR" "$TRACKER"

LEAK_RE='[0-9][0-9,]*\.[0-9]+'
LEAK_HITS=$(grep -oE "$LEAK_RE" "$AGG_LOG" || true)
assert_true "real script: zero decimal-number matches across full replay (a cycle_n like '7' or a count don't match this pattern; only a decimal amount does)" "$([ -z "$LEAK_HITS" ] && echo 1 || echo 0)"
if [ -n "$LEAK_HITS" ]; then
	echo "  (leaked-looking tokens found in real-script run — should be none):"
	printf '%s\n' "$LEAK_HITS" | sed 's/^/    /'
fi

echo ""
echo "=== mutation kill check: non-leak grep must actually catch a real leak ==="
echo "(a MUTANT copy of reward-tracker.sh with one added debug echo of"
echo " REWARD_METAL must fail the same grep the real script passes above.)"
# The mutant must live at scripts/reward-tracker.sh under SOME root whose
# scripts/lib/ resolves to the real libraries — reward-tracker.sh computes
# its own ROOT from $0's dirname (self-locating, like every script in this
# repo), so a mutant copy dropped in a bare tmp file would resolve ROOT to
# the wrong place and fail at the side-effects.sh readability check before
# ever reaching the mutated line. Mirror the real layout with a symlink
# instead of copying scripts/lib/ wholesale.
MUTANT_ROOT="$TMP/mutant-root"
mkdir -p "$MUTANT_ROOT/scripts"
ln -s "$REPO/scripts/lib" "$MUTANT_ROOT/scripts/lib"
# Same reasoning as the zero-reward mutant root below: fyd_notify needs
# notify.sh reachable at THIS root's own scripts/, not just scripts/lib/.
ln -s "$REPO/scripts/notify.sh" "$MUTANT_ROOT/scripts/notify.sh"
MUTANT="$MUTANT_ROOT/scripts/reward-tracker.sh"
sed 's/echo "reward-tracker: appended matured cycle record"/echo "reward-tracker: appended matured cycle record (DEBUG reward=${REWARD_METAL} METAL)"/' \
	"$TRACKER" > "$MUTANT"
chmod +x "$MUTANT"
if diff -q "$TRACKER" "$MUTANT" >/dev/null 2>&1; then
	FAIL=$((FAIL + 1))
	FAILURES+=("mutation kill check: sed produced no diff — target line not found, mutation not actually applied")
	echo "  FAIL  mutant sed produced no diff — target echo not matched"
else
	MUTANT_DIR="$TMP/leak-mutant"
	mkdir -p "$MUTANT_DIR"
	AGG_LOG="$TMP/record/aggregate-leak-check-mutant.log"
	: > "$AGG_LOG"
	replay_full_scenario "$MUTANT_DIR" "$MUTANT"
	MUTANT_LEAK_HITS=$(grep -oE "$LEAK_RE" "$AGG_LOG" || true)
	if [ -n "$MUTANT_LEAK_HITS" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  mutant (debug echo of REWARD_METAL added) DOES leak a decimal amount (%s) — the non-leak check has teeth\n' "$(printf '%s' "$MUTANT_LEAK_HITS" | head -1)"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("mutation kill check: mutant still produced zero leak matches — the non-leak grep is not sensitive")
		echo "  FAIL  mutant unexpectedly leaked nothing — non-leak check is not sensitive"
	fi
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
