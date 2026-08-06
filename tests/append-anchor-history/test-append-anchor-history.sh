#!/usr/bin/env bash
# test-append-anchor-history.sh — regression suite for
# scripts/append-anchor-history.sh (v2 receipt → jsonl append).
#
# CHAIN: none — pure file operations, no broadcast.
#
# Covers the 6 append-only invariants + happy-path shape assertions.
#
# R13 note: append-anchor-history.sh now mandatorily schema-validates each
# newly composed line (ajv, else python3+jsonschema, else fail-closed) — see
# tests/append-anchor-history/test-r13-schema-validate.sh for that behavior
# specifically. The happy-path cases in THIS file need a validator to reach
# exit 0 at all, so a stub `ajv` that always reports "valid" is prepended to
# PATH below; this proves the (unmodified) invariant logic still governs the
# exit-0/exit-4 outcome exactly as before, it does not re-test R13 itself.
#
# Usage:
#   bash tests/append-anchor-history/test-append-anchor-history.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/append-anchor-history.sh"
V2_EXAMPLE="${REPO_ROOT}/public/api/anchor-receipt.v2.example.json"

if [ ! -x "$SCRIPT" ]; then
	echo "FATAL: script not executable at $SCRIPT" >&2
	exit 1
fi
if [ ! -r "$V2_EXAMPLE" ]; then
	echo "FATAL: v2 example receipt missing at $V2_EXAMPLE" >&2
	exit 1
fi

TEST_DIR="$(mktemp -d -t append-history-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Stub ajv (always "valid") ahead of PATH so the R13 validation step never
# falls through to the (slower, network/interpreter-dependent) python3
# fallback in this suite; see the R13 note above.
STUB_AJV_DIR="$TEST_DIR/bin"
mkdir -p "$STUB_AJV_DIR"
cat > "$STUB_AJV_DIR/ajv" <<'AJVEOF'
#!/usr/bin/env bash
exit 0
AJVEOF
chmod +x "$STUB_AJV_DIR/ajv"
PATH="$STUB_AJV_DIR:$PATH"

# Pin no-op stubs for the R18 publish side effect (review round 1,
# 2026-08-06): none of the fixtures below ever create a real archive/
# file, so every successful append here falls into the "archive not found
# locally" WARN+alert path added by that change. Without this pin, that
# path calls the REAL scripts/notify.sh — which, on a host that has
# /etc/freedom-yield/ntfy-topic configured (i.e. the validator host, not
# just this dev machine), fires an actual ntfy.sh push notification per
# invocation. This suite alone would have fired 6 real notifications.
# Pinning both env vars to no-op stubs makes this suite hermetic
# regardless of host — see tests/append-anchor-history/test-r18-archive-
# publish.sh for the dedicated coverage of the publish behavior itself.
STUB_NOOP_DIR="$TEST_DIR/noop"
mkdir -p "$STUB_NOOP_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_NOOP_DIR/push.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_NOOP_DIR/notify.sh"
chmod +x "$STUB_NOOP_DIR/push.sh" "$STUB_NOOP_DIR/notify.sh"
export FYD_PUSH_TO_WEB_HOST="$STUB_NOOP_DIR/push.sh" FYD_NOTIFY="$STUB_NOOP_DIR/notify.sh"

PASS=0
FAIL=0

run_case() {
	local name="$1"
	local expected_rc="$2"
	shift 2
	local rc
	if [ "$#" -eq 0 ]; then
		bash "$SCRIPT" >/dev/null 2>&1
	else
		bash "$SCRIPT" "$@" >/dev/null 2>&1
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

check_expr() {
	local name="$1" expected="$2" actual="$3"
	if [ "$actual" = "$expected" ]; then
		printf 'PASS  %-70s (value=%s)\n' "$name" "$actual"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %-70s (actual=%s, expected=%s)\n' "$name" "$actual" "$expected" >&2
		FAIL=$((FAIL + 1))
	fi
}

if command -v sha256sum >/dev/null 2>&1; then
	history_hash() { sha256sum "$1" | awk '{print $1}'; }
else
	history_hash() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

# Helper: build a synthetic v2 receipt from a template with
# {tx_id, block_num, cycle_number, dag_root_hash, prev_anchor_tx_id, event_type}.
make_receipt() {
	local out="$1" tx_id="$2" block_num="$3" cycle_number="$4" dag_root_hash="$5" prev_anchor_tx_id_json="$6" trigger_event="$7"
	jq \
		--arg tx_id "$tx_id" \
		--argjson block_num "$block_num" \
		--argjson cycle_number "$cycle_number" \
		--arg dag_root_hash "$dag_root_hash" \
		--argjson prev_anchor_tx_id "$prev_anchor_tx_id_json" \
		--arg trigger_event "$trigger_event" \
		'.anchor.tx_id = $tx_id
		 | .anchor.block_num = $block_num
		 | .cycle_number = $cycle_number
		 | .dag_root_hash = $dag_root_hash
		 | .anchor.actions[3].root_hex = $dag_root_hash
		 | .anchor.actions[3].memo = "\(.memo_prefix):\($dag_root_hash)"
		 | .prev_anchor_tx_id = $prev_anchor_tx_id
		 | .trigger_event = $trigger_event
		 | .verification_status = "live"' \
		"$V2_EXAMPLE" > "$out"
}

# ---- arg validation (exit 1) ----
run_case "arg: no args" 1
run_case "arg: --receipt missing" 1 --history="$TEST_DIR/h.jsonl"
run_case "arg: --event-type invalid" 1 --receipt="$V2_EXAMPLE" --event-type=badevent

# ---- receipt shape refusal ----
BAD_STATUS_RECEIPT="$TEST_DIR/bad-status.json"
jq '.verification_status = "scheduled"' "$V2_EXAMPLE" > "$BAD_STATUS_RECEIPT"
run_case "receipt refusal: verification_status != live" 3 \
	--receipt="$BAD_STATUS_RECEIPT" --history="$TEST_DIR/h.jsonl" --event-type=cyclestart

BAD_SCHEMA_RECEIPT="$TEST_DIR/bad-schema.json"
jq '.schema_version = 1' "$V2_EXAMPLE" > "$BAD_SCHEMA_RECEIPT"
run_case "receipt refusal: schema_version != 2" 2 \
	--receipt="$BAD_SCHEMA_RECEIPT" --history="$TEST_DIR/h.jsonl" --event-type=cyclestart

# ---- genesis append (happy path) ----
GENESIS_HIST="$TEST_DIR/genesis.jsonl"
GENESIS_RECEIPT="$TEST_DIR/genesis-receipt.json"
make_receipt "$GENESIS_RECEIPT" \
	"1111111111111111111111111111111111111111111111111111111111111111" \
	100000001 3 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
	"null" "cyclestart"
run_case "genesis append (prev_anchor_tx_id null, cyclestart)" 0 \
	--receipt="$GENESIS_RECEIPT" --history="$GENESIS_HIST" --event-type=cyclestart
check_expr "genesis: 1 line appended" "1" "$(wc -l < "$GENESIS_HIST" | tr -d ' ')"
check_expr "genesis: tx_id in line"    "1111111111111111111111111111111111111111111111111111111111111111" \
	"$(jq -r .tx_id "$GENESIS_HIST")"
check_expr "genesis: event_type"       "cyclestart" \
	"$(jq -r .event_type "$GENESIS_HIST")"
check_expr "genesis: prev_anchor_tx_id null" "true" \
	"$(jq '.prev_anchor_tx_id == null' "$GENESIS_HIST")"

# ---- invariant 6 (genesis line must have prev_anchor_tx_id null) ----
BAD_GENESIS_HIST="$TEST_DIR/bad-genesis.jsonl"
BAD_GENESIS_RECEIPT="$TEST_DIR/bad-genesis-receipt.json"
make_receipt "$BAD_GENESIS_RECEIPT" \
	"2222222222222222222222222222222222222222222222222222222222222222" \
	100000002 3 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
	"\"0000000000000000000000000000000000000000000000000000000000000000\"" "cyclestart"
run_case "invariant 6 refusal: genesis line with non-null prev_anchor_tx_id" 4 \
	--receipt="$BAD_GENESIS_RECEIPT" --history="$BAD_GENESIS_HIST" --event-type=cyclestart

# ---- second append (happy path with prev_anchor_tx_id chain) ----
SECOND_RECEIPT="$TEST_DIR/second-receipt.json"
make_receipt "$SECOND_RECEIPT" \
	"3333333333333333333333333333333333333333333333333333333333333333" \
	100000010 3 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
	"\"1111111111111111111111111111111111111111111111111111111111111111\"" "cycleend"
run_case "second append (cycleend, prev_anchor_tx_id chains from genesis)" 0 \
	--receipt="$SECOND_RECEIPT" --history="$GENESIS_HIST" --event-type=cycleend
check_expr "after 2 appends: line count" "2" "$(wc -l < "$GENESIS_HIST" | tr -d ' ')"

# ---- invariant 1 (tx_id unique) ----
DUP_TX_RECEIPT="$TEST_DIR/dup-tx-receipt.json"
make_receipt "$DUP_TX_RECEIPT" \
	"1111111111111111111111111111111111111111111111111111111111111111" \
	100000020 4 "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" \
	"\"3333333333333333333333333333333333333333333333333333333333333333\"" "cyclestart"
run_case "invariant 1 refusal: tx_id duplicate" 4 \
	--receipt="$DUP_TX_RECEIPT" --history="$GENESIS_HIST" --event-type=cyclestart

# ---- invariant 5 (block_num non-decreasing) ----
BACK_BLOCK_RECEIPT="$TEST_DIR/back-block-receipt.json"
make_receipt "$BACK_BLOCK_RECEIPT" \
	"4444444444444444444444444444444444444444444444444444444444444444" \
	100000005 3 "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" \
	"\"3333333333333333333333333333333333333333333333333333333333333333\"" "cyclestart"
run_case "invariant 5 refusal: block_num decreasing" 4 \
	--receipt="$BACK_BLOCK_RECEIPT" --history="$GENESIS_HIST" --event-type=cyclestart

# ---- invariant 6 (prev_anchor_tx_id must match last tx_id) ----
BAD_PREV_RECEIPT="$TEST_DIR/bad-prev-receipt.json"
make_receipt "$BAD_PREV_RECEIPT" \
	"5555555555555555555555555555555555555555555555555555555555555555" \
	100000030 4 "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
	"\"9999999999999999999999999999999999999999999999999999999999999999\"" "cyclestart"
run_case "invariant 6 refusal: prev_anchor_tx_id != last tx_id" 4 \
	--receipt="$BAD_PREV_RECEIPT" --history="$GENESIS_HIST" --event-type=cyclestart

# ---- regression: grep -c 0-match idiom must not pollute stderr (2026-08-04) ----
# Fixed in scripts/append-anchor-history.sh's invariant 2/3 dup check: the
# original `DUP_COUNT="$(grep -c ... || echo 0)"` idiom relied on grep -c's
# quirk of printing "0" AND exiting 1 on zero matches. `|| echo 0` then ran
# BECAUSE of that exit 1, appending a second "0" line, so DUP_COUNT became
# the two-line string "0\n0" — not a valid integer — and the following
# `[ "$DUP_COUNT" -gt 0 ]` threw "integer expression expected" to stderr.
# This fired on every append whose cycle_number was genuinely new (not a
# duplicate), i.e. the common case, even though the append itself still
# succeeded. GENESIS_HIST here has 2 lines, both cycle_number=3; appending
# cycle_number=4 (never seen before) exercises exactly the 0-match path.
FRESH_CYCLE_RECEIPT="$TEST_DIR/fresh-cycle-receipt.json"
make_receipt "$FRESH_CYCLE_RECEIPT" \
	"6666666666666666666666666666666666666666666666666666666666666666" \
	100000020 4 "7777777777777777777777777777777777777777777777777777777777777777" \
	"\"3333333333333333333333333333333333333333333333333333333333333333\"" "cyclestart"
FRESH_CYCLE_STDERR="$TEST_DIR/fresh-cycle-stderr.txt"
if bash "$SCRIPT" --receipt="$FRESH_CYCLE_RECEIPT" --history="$GENESIS_HIST" --event-type=cyclestart \
		>/dev/null 2>"$FRESH_CYCLE_STDERR"; then
	printf 'PASS  %-70s (rc=0)\n' "fresh (non-dup) cycle_number append succeeds"
	PASS=$((PASS + 1))
else
	printf 'FAIL  %-70s (rc=%d)\n' "fresh (non-dup) cycle_number append succeeds" "$?" >&2
	FAIL=$((FAIL + 1))
fi
if grep -qi "integer expression" "$FRESH_CYCLE_STDERR"; then
	echo "FAIL  fresh cycle_number append: stderr polluted with 'integer expression' error" >&2
	sed 's/^/       stderr: /' "$FRESH_CYCLE_STDERR" >&2
	FAIL=$((FAIL + 1))
else
	echo "PASS  fresh cycle_number append: stderr clean of 'integer expression' error"
	PASS=$((PASS + 1))
fi

# ---- coverage: invariant 2 must still REJECT a genuine (cycle_number,
# event_type) duplicate (2026-08-04 fix round 1) ----
# The grep -c fix above only changes how the 0-match (non-duplicate) case
# behaves; this proves the >0-match (genuine duplicate) refusal path it sits
# next to is untouched. GENESIS_HIST now has 3 lines, the last being
# cycle_number=4/cyclestart/tx=6666... (from the fresh-cycle append just
# above). This receipt reuses cycle_number=4 + event_type=cyclestart (a true
# duplicate of that line) while satisfying every OTHER invariant (fresh
# tx_id, block_num >= last, prev_anchor_tx_id == last tx_id, cycle_number not
# decreasing) so the rejection is unambiguously invariant 2, not some other
# invariant firing first.
GENESIS_LINES_BEFORE_DUP="$(wc -l < "$GENESIS_HIST" | tr -d ' ')"
GENESIS_HASH_BEFORE_DUP="$(history_hash "$GENESIS_HIST")"
DUP_EVENT_RECEIPT="$TEST_DIR/dup-cycle-event-receipt.json"
make_receipt "$DUP_EVENT_RECEIPT" \
	"8888888888888888888888888888888888888888888888888888888888888888" \
	100000025 4 "9999999999999999999999999999999999999999999999999999999999999999" \
	"\"6666666666666666666666666666666666666666666666666666666666666666\"" "cyclestart"
run_case "invariant 2 refusal: genuine (cycle_number=4, cyclestart) duplicate" 4 \
	--receipt="$DUP_EVENT_RECEIPT" --history="$GENESIS_HIST" --event-type=cyclestart
GENESIS_LINES_AFTER_DUP="$(wc -l < "$GENESIS_HIST" | tr -d ' ')"
GENESIS_HASH_AFTER_DUP="$(history_hash "$GENESIS_HIST")"
if [ "$GENESIS_LINES_BEFORE_DUP" = "$GENESIS_LINES_AFTER_DUP" ] && [ "$GENESIS_HASH_BEFORE_DUP" = "$GENESIS_HASH_AFTER_DUP" ]; then
	printf 'PASS  %-70s (lines=%s, unchanged)\n' "invariant 2 refusal: history unchanged after rejected dup" "$GENESIS_LINES_AFTER_DUP"
	PASS=$((PASS + 1))
else
	printf 'FAIL  %-70s (lines before=%s after=%s)\n' "invariant 2 refusal: history unchanged after rejected dup" \
		"$GENESIS_LINES_BEFORE_DUP" "$GENESIS_LINES_AFTER_DUP" >&2
	FAIL=$((FAIL + 1))
fi

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-append-anchor-history.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
