#!/usr/bin/env bash
# tests/append-anchor-history/test-r13-r18-schema-archive.sh — R13
# (mandatory schema self-validation, fail-closed) + R18 (archived_source_path
# / archived_receipt_path index fields) coverage for
# scripts/append-anchor-history.sh.
#
# CHAIN: none — pure file operations, no broadcast. PRIME_DIRECTIVE: safe.
#
# Usage:
#   bash tests/append-anchor-history/test-r13-r18-schema-archive.sh
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

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$label"
	else
		fail "$label (expected='$expected' actual='$actual')"
	fi
}

TMP="$(mktemp -d -t append-history-r13r18-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Pin no-op stubs for the R18 publish side effect (review round 1,
# 2026-08-06): case 1 below is a happy-path append but never creates a real
# archive/ file, so it falls into the "archive not found locally" WARN+alert
# path added by that change. Without this pin, that path calls the REAL
# scripts/notify.sh — which fires an actual ntfy.sh push on any host that
# has /etc/freedom-yield/ntfy-topic configured (the validator host). See
# tests/append-anchor-history/test-r18-archive-publish.sh for the dedicated
# coverage of the publish behavior itself.
STUB_NOOP_DIR="$TMP/noop"
mkdir -p "$STUB_NOOP_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_NOOP_DIR/push.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_NOOP_DIR/notify.sh"
chmod +x "$STUB_NOOP_DIR/push.sh" "$STUB_NOOP_DIR/notify.sh"
export FYD_PUSH_TO_WEB_HOST="$STUB_NOOP_DIR/push.sh" FYD_NOTIFY="$STUB_NOOP_DIR/notify.sh"

TX_ID="2222222222222222222222222222222222222222222222222222222222222222"
DAG_ROOT="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RECEIPT="$TMP/receipt.json"
jq \
	--arg tx_id "$TX_ID" \
	--arg dag_root "$DAG_ROOT" \
	'.anchor.tx_id = $tx_id
	 | .anchor.block_num = 100000005
	 | .cycle_number = 5
	 | .dag_root_hash = $dag_root
	 | .anchor.actions[3].root_hex = $dag_root
	 | .anchor.actions[3].memo = "\(.memo_prefix):\($dag_root)"
	 | .prev_anchor_tx_id = null
	 | .trigger_event = "cyclestart"
	 | .verification_status = "live"' \
	"$V2_EXAMPLE" > "$RECEIPT"

# --- stub ajv farms ---
FARM_VALID="$TMP/bin-valid"
mkdir -p "$FARM_VALID"
cat > "$FARM_VALID/ajv" <<'AJVEOF'
#!/usr/bin/env bash
exit 0
AJVEOF
chmod +x "$FARM_VALID/ajv"

FARM_INVALID="$TMP/bin-invalid"
mkdir -p "$FARM_INVALID"
cat > "$FARM_INVALID/ajv" <<'AJVEOF'
#!/usr/bin/env bash
echo "stub: forced invalid" >&2
exit 1
AJVEOF
chmod +x "$FARM_INVALID/ajv"

# --- PATH farm WITHOUT ajv/npx/python3 (R13 "no validator available") ------
FARM_NO_VALIDATOR="$TMP/bin-no-validator"
mkdir -p "$FARM_NO_VALIDATOR"
for t in bash jq awk grep sed tr head tail cat mktemp rm mv cp dirname basename \
         sha256sum shasum printf date env cut sort wc; do
	p="$(command -v "$t" 2>/dev/null || true)"
	[ -n "$p" ] && ln -sf "$p" "$FARM_NO_VALIDATOR/$t"
done
for absent_tool in ajv npx python3; do
	if PATH="$FARM_NO_VALIDATOR" command -v "$absent_tool" >/dev/null 2>&1; then
		fail "harness leaked $absent_tool into the no-validator farm — refusing to run that case"
	fi
done

# ---- case 1: happy path (validator says "valid") -> R18 fields present ----
HIST1="$TMP/history1.jsonl"
PATH="$FARM_VALID:$PATH" bash "$SCRIPT" --receipt="$RECEIPT" --history="$HIST1" --event-type=cyclestart \
	>"$TMP/run1.stdout" 2>"$TMP/run1.stderr"
RC1=$?
check_eq "happy path: exit 0" "0" "$RC1"
if [ "$RC1" -eq 0 ]; then
	check_eq "R18: archived_source_path == api/archive/anchor-source-<dag_root>.json" \
		"api/archive/anchor-source-${DAG_ROOT}.json" "$(jq -r .archived_source_path "$HIST1" 2>/dev/null)"
	check_eq "R18: archived_receipt_path == api/archive/anchor-receipt-<tx_id>.json" \
		"api/archive/anchor-receipt-${TX_ID}.json" "$(jq -r .archived_receipt_path "$HIST1" 2>/dev/null)"
else
	fail "happy path: script failed unexpectedly; stderr: $(cat "$TMP/run1.stderr" 2>/dev/null | tr '\n' '|')"
fi

# ---- case 2: validator says "invalid" -> exit 6, nothing appended ---------
HIST2="$TMP/history2.jsonl"
PATH="$FARM_INVALID:$PATH" bash "$SCRIPT" --receipt="$RECEIPT" --history="$HIST2" --event-type=cyclestart \
	>/dev/null 2>"$TMP/run2.stderr"
RC2=$?
check_eq "R13: schema validation failed -> exit 6" "6" "$RC2"
if [ -e "$HIST2" ]; then
	fail "R13: invalid case must NOT create/append $HIST2"
else
	pass "R13: invalid case did not append to history"
fi
grep -q "failed schema validation" "$TMP/run2.stderr" \
	&& pass "R13: invalid case emits a clear schema-validation error message" \
	|| fail "R13: invalid case error message missing/unclear"

# ---- case 3: no validator available -> exit 7, nothing appended -----------
HIST3="$TMP/history3.jsonl"
PATH="$FARM_NO_VALIDATOR" bash "$SCRIPT" --receipt="$RECEIPT" --history="$HIST3" --event-type=cyclestart \
	>/dev/null 2>"$TMP/run3.stderr"
RC3=$?
check_eq "R13: no validator available -> exit 7 (fail-closed, not silent skip)" "7" "$RC3"
if [ -e "$HIST3" ]; then
	fail "R13: no-validator case must NOT create/append $HIST3"
else
	pass "R13: no-validator case did not append to history"
fi
grep -q "no JSON schema validator available" "$TMP/run3.stderr" \
	&& pass "R13: no-validator case emits a clear fail-closed error message" \
	|| fail "R13: no-validator case error message missing/unclear"

# ---- summary -----------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-r13-r18-schema-archive.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
