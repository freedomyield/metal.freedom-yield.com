#!/usr/bin/env bash
# tests/append-anchor-history/test-r18-archive-publish.sh — R18 archive
# AUTO-PUBLICATION coverage for scripts/append-anchor-history.sh.
#
# CHAIN: none — pure file operations + stubbed push/notify, no broadcast,
# no network, no real SSH. PRIME_DIRECTIVE: safe.
#
# Background: append-anchor-history.sh writes archived_source_path /
# archived_receipt_path into every history line (R18), but until
# 2026-08-06 nothing actually pushed the two archive files those pointers
# name — an operator had to remember to run push-to-web-host.sh by hand
# after every anchor event, and forgetting it (which happened, 2026-08-04)
# left the advertised URL 404ing. append-anchor-history.sh now pushes both
# archives itself, automatically, immediately after a successful append —
# see the "R18 publication" block at the tail of the script.
#
# This suite covers the 4 properties the design commits to:
#   (a) a successful append triggers exactly 2 push-to-web-host.sh calls,
#       with the exact expected archive/<basename> args, in source-then-
#       receipt order
#   (b) a push failure never fails the append — the history line still
#       lands, the failure is reported loudly (stderr + notify alert) with
#       an exact, copy-pasteable manual retry command
#   (c) idempotency: (c1) re-running the identical append is rejected by
#       the pre-existing invariant-1 (tx_id uniqueness) check BEFORE the
#       publish step is ever reached, so a retry of the same append never
#       double-pushes; (c2) the manual retry command printed in (b) is
#       itself safe to re-run any number of times (fails identically while
#       the transport is down, succeeds once it's fixed) without touching
#       the already-appended history file
#   (d) design decision: when a local archive file is simply missing (not
#       a push failure — the file never got there), the script WARNS and
#       SKIPS that push rather than failing closed. Rationale: by the time
#       append-anchor-history.sh runs (pipeline step 4), gen-anchor-
#       source.sh (step 1) and gen-anchor-receipt.sh (step 3) have already
#       run and normally left the archive files in place; a missing file
#       at this point is an anomaly worth alerting on, but the append-only
#       chain record (the far more valuable invariant) must never be held
#       hostage by a publish-layer problem — same fail-open posture as a
#       push failure, for the same reason.
#
# Usage:
#   bash tests/append-anchor-history/test-r18-archive-publish.sh
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

TMP="$(mktemp -d -t append-history-r18-publish.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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

# ---- stub ajv (always "valid") — isolates R13 schema validation from what
# this suite actually tests (R18 publication) ----
AJV_FARM="$TMP/bin-ajv-valid"
mkdir -p "$AJV_FARM"
cat > "$AJV_FARM/ajv" <<'AJVEOF'
#!/usr/bin/env bash
exit 0
AJVEOF
chmod +x "$AJV_FARM/ajv"

# ---- receipt builder (same shape as tests/append-anchor-history/
# test-append-anchor-history.sh's make_receipt — no cross-test sourcing
# convention exists in this repo, so duplicated deliberately) ----
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

# ---- stub generators ----
# push stub: logs its sole arg (the archive/<basename> path) to $2, one line
# per invocation. $3 controls success (0) or forced failure (1).
make_push_stub() {
	local path="$1" log="$2" rc="$3"
	cat > "$path" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$log"
EOF
	if [ "$rc" -ne 0 ]; then
		echo 'echo "stub: forced push failure" >&2' >> "$path"
	fi
	echo "exit $rc" >> "$path"
	chmod +x "$path"
}

# notify stub: records priority|title|message lines, mirroring
# tests/anchor-pipeline/test-run-anchor-pipeline.sh's NOTIFY_STUB pattern.
make_notify_stub() {
	local path="$1" log="$2"
	cat > "$path" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$log"
exit 0
EOF
	chmod +x "$path"
}

# 64-lowercase-hex synthetic identifiers, distinct per case (literal, no
# python3/seq dependency — this repo's preflight explicitly treats python3
# as optionally absent).
TX_ID_A="a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
DAG_ROOT_A="b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
TX_ID_B="c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"
DAG_ROOT_B="d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4"
TX_ID_D="e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"
DAG_ROOT_D="f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6"

# =============================================================================
# case (a): happy path — successful append triggers exactly 2 correct pushes
# =============================================================================
RECEIPT_A="$TMP/receipt-a.json"
make_receipt "$RECEIPT_A" "$TX_ID_A" 100000001 3 "$DAG_ROOT_A" "null" "cyclestart"

HIST_A="$TMP/history-a.jsonl"
ARCHIVE_DIR_A="$TMP/archive-a"
mkdir -p "$ARCHIVE_DIR_A"
echo '{}' > "${ARCHIVE_DIR_A}/anchor-source-${DAG_ROOT_A}.json"
echo '{}' > "${ARCHIVE_DIR_A}/anchor-receipt-${TX_ID_A}.json"

PUSH_LOG_A="$TMP/push-a.log"
PUSH_STUB_A="$TMP/push-stub-success-a.sh"
make_push_stub "$PUSH_STUB_A" "$PUSH_LOG_A" 0
NOTIFY_LOG_A="$TMP/notify-a.log"
NOTIFY_STUB_A="$TMP/notify-stub-a.sh"
make_notify_stub "$NOTIFY_STUB_A" "$NOTIFY_LOG_A"

STDOUT_A="$TMP/run-a.stdout"
STDERR_A="$TMP/run-a.stderr"
PATH="$AJV_FARM:$PATH" \
	ANCHOR_ARCHIVE_DIR="$ARCHIVE_DIR_A" \
	FYD_PUSH_TO_WEB_HOST="$PUSH_STUB_A" \
	FYD_NOTIFY="$NOTIFY_STUB_A" \
	bash "$SCRIPT" --receipt="$RECEIPT_A" --history="$HIST_A" --event-type=cyclestart \
	>"$STDOUT_A" 2>"$STDERR_A"
RC_A=$?
check_eq "(a) happy path: exit 0" "0" "$RC_A"
check_eq "(a) history line appended" "1" "$(wc -l < "$HIST_A" 2>/dev/null | tr -d ' ')"

if [ -f "$PUSH_LOG_A" ]; then
	check_eq "(a) push called exactly twice" "2" "$(wc -l < "$PUSH_LOG_A" | tr -d ' ')"
	check_eq "(a) push call 1 = source archive, correct arg" \
		"archive/anchor-source-${DAG_ROOT_A}.json" "$(sed -n '1p' "$PUSH_LOG_A")"
	check_eq "(a) push call 2 = receipt archive, correct arg" \
		"archive/anchor-receipt-${TX_ID_A}.json" "$(sed -n '2p' "$PUSH_LOG_A")"
else
	fail "(a) push stub was never invoked (expected 2 calls)"
fi

grep -q 'OK: published anchor-source' "$STDERR_A" \
	&& pass "(a) stderr reports anchor-source published" \
	|| fail "(a) stderr missing anchor-source published confirmation"
grep -q 'OK: published anchor-receipt' "$STDERR_A" \
	&& pass "(a) stderr reports anchor-receipt published" \
	|| fail "(a) stderr missing anchor-receipt published confirmation"

if [ -f "$NOTIFY_LOG_A" ] && [ -s "$NOTIFY_LOG_A" ]; then
	fail "(a) notify stub fired on a successful publish (should be silent)"
else
	pass "(a) notify stub silent on successful publish"
fi

check_eq "(a) archived_source_path recorded correctly" \
	"api/archive/anchor-source-${DAG_ROOT_A}.json" "$(jq -r .archived_source_path "$HIST_A" 2>/dev/null)"
check_eq "(a) archived_receipt_path recorded correctly" \
	"api/archive/anchor-receipt-${TX_ID_A}.json" "$(jq -r .archived_receipt_path "$HIST_A" 2>/dev/null)"

# =============================================================================
# case (b): push fails for both archives — append still succeeds, failure is
# loud (stderr + notify alert) and carries an exact manual retry command
# =============================================================================
RECEIPT_B="$TMP/receipt-b.json"
make_receipt "$RECEIPT_B" "$TX_ID_B" 200000001 5 "$DAG_ROOT_B" "null" "cyclestart"

HIST_B="$TMP/history-b.jsonl"
ARCHIVE_DIR_B="$TMP/archive-b"
mkdir -p "$ARCHIVE_DIR_B"
echo '{}' > "${ARCHIVE_DIR_B}/anchor-source-${DAG_ROOT_B}.json"
echo '{}' > "${ARCHIVE_DIR_B}/anchor-receipt-${TX_ID_B}.json"

PUSH_LOG_B="$TMP/push-b.log"
PUSH_STUB_B="$TMP/push-stub-fail-b.sh"
make_push_stub "$PUSH_STUB_B" "$PUSH_LOG_B" 1
NOTIFY_LOG_B="$TMP/notify-b.log"
NOTIFY_STUB_B="$TMP/notify-stub-b.sh"
make_notify_stub "$NOTIFY_STUB_B" "$NOTIFY_LOG_B"

STDOUT_B="$TMP/run-b.stdout"
STDERR_B="$TMP/run-b.stderr"
PATH="$AJV_FARM:$PATH" \
	ANCHOR_ARCHIVE_DIR="$ARCHIVE_DIR_B" \
	FYD_PUSH_TO_WEB_HOST="$PUSH_STUB_B" \
	FYD_NOTIFY="$NOTIFY_STUB_B" \
	bash "$SCRIPT" --receipt="$RECEIPT_B" --history="$HIST_B" --event-type=cyclestart \
	>"$STDOUT_B" 2>"$STDERR_B"
RC_B=$?
check_eq "(b) push failure does NOT fail the append: exit 0" "0" "$RC_B"
check_eq "(b) history line still appended despite push failure" "1" "$(wc -l < "$HIST_B" 2>/dev/null | tr -d ' ')"
check_eq "(b) archived_source_path still recorded despite push failure" \
	"api/archive/anchor-source-${DAG_ROOT_B}.json" "$(jq -r .archived_source_path "$HIST_B" 2>/dev/null)"

if [ -f "$PUSH_LOG_B" ]; then
	check_eq "(b) both pushes were attempted" "2" "$(wc -l < "$PUSH_LOG_B" | tr -d ' ')"
else
	fail "(b) push stub was never invoked (expected 2 attempts)"
fi

grep -q 'R18 publish FAILED for anchor-source' "$STDERR_B" \
	&& pass "(b) stderr loudly reports anchor-source publish failure" \
	|| fail "(b) stderr missing anchor-source publish-failure report"
grep -q 'R18 publish FAILED for anchor-receipt' "$STDERR_B" \
	&& pass "(b) stderr loudly reports anchor-receipt publish failure" \
	|| fail "(b) stderr missing anchor-receipt publish-failure report"

RETRY_CMD_SOURCE="$(grep -o "bash \"${PUSH_STUB_B}\" \"archive/anchor-source-${DAG_ROOT_B}.json\"" "$STDERR_B" | head -n1)"
check_eq "(b) exact retry command printed for anchor-source" \
	"bash \"${PUSH_STUB_B}\" \"archive/anchor-source-${DAG_ROOT_B}.json\"" "$RETRY_CMD_SOURCE"
RETRY_CMD_RECEIPT="$(grep -o "bash \"${PUSH_STUB_B}\" \"archive/anchor-receipt-${TX_ID_B}.json\"" "$STDERR_B" | head -n1)"
check_eq "(b) exact retry command printed for anchor-receipt" \
	"bash \"${PUSH_STUB_B}\" \"archive/anchor-receipt-${TX_ID_B}.json\"" "$RETRY_CMD_RECEIPT"

if [ -f "$NOTIFY_LOG_B" ]; then
	check_eq "(b) notify alert fired once per failed archive" "2" "$(wc -l < "$NOTIFY_LOG_B" | tr -d ' ')"
	grep -q '^high|anchor archive publish failed: anchor-source|' "$NOTIFY_LOG_B" \
		&& pass "(b) notify alert: correct priority+title for anchor-source" \
		|| fail "(b) notify alert: missing/incorrect priority+title for anchor-source"
	grep -q "tx_id=${TX_ID_B}" "$NOTIFY_LOG_B" && grep -q "dag_root=${DAG_ROOT_B}" "$NOTIFY_LOG_B" \
		&& pass "(b) notify alert body carries tx_id + dag_root" \
		|| fail "(b) notify alert body missing tx_id/dag_root"
else
	fail "(b) notify stub was never invoked (expected 2 alerts)"
fi

# =============================================================================
# case (c1): idempotency — re-running the IDENTICAL append is rejected by the
# pre-existing invariant-1 (tx_id uniqueness) check before publish is ever
# reached, so a naive retry can never double-push.
# =============================================================================
PUSH_COUNT_BEFORE_RERUN="$(wc -l < "$PUSH_LOG_A" | tr -d ' ')"
HIST_A_LINES_BEFORE="$(wc -l < "$HIST_A" | tr -d ' ')"
STDERR_A_RERUN="$TMP/run-a-rerun.stderr"
PATH="$AJV_FARM:$PATH" \
	ANCHOR_ARCHIVE_DIR="$ARCHIVE_DIR_A" \
	FYD_PUSH_TO_WEB_HOST="$PUSH_STUB_A" \
	FYD_NOTIFY="$NOTIFY_STUB_A" \
	bash "$SCRIPT" --receipt="$RECEIPT_A" --history="$HIST_A" --event-type=cyclestart \
	>/dev/null 2>"$STDERR_A_RERUN"
RC_A_RERUN=$?
check_eq "(c1) identical re-run rejected (invariant 1, exit 4)" "4" "$RC_A_RERUN"
check_eq "(c1) history unchanged after rejected re-run" "$HIST_A_LINES_BEFORE" "$(wc -l < "$HIST_A" | tr -d ' ')"
check_eq "(c1) publish step never reached — push call count unchanged" \
	"$PUSH_COUNT_BEFORE_RERUN" "$(wc -l < "$PUSH_LOG_A" | tr -d ' ')"

# =============================================================================
# case (c2): idempotency — the exact manual retry command printed in (b) is
# itself safe to run repeatedly: it fails identically while the transport is
# down, and succeeds once fixed, all without touching the already-appended
# history file.
# =============================================================================
HIST_B_HASH_BEFORE_RETRIES="$(cat "$HIST_B")"
# Two manual retries while still down (stub still forces failure) — proves
# re-running the printed command is not itself destructive.
eval "$RETRY_CMD_SOURCE" >/dev/null 2>&1
RC_RETRY_1=$?
eval "$RETRY_CMD_SOURCE" >/dev/null 2>&1
RC_RETRY_2=$?
check_eq "(c2) manual retry #1 (still down) fails the same way" "1" "$RC_RETRY_1"
check_eq "(c2) manual retry #2 (still down) fails the same way" "1" "$RC_RETRY_2"
check_eq "(c2) push log grew by exactly 2 (one per manual retry)" "4" "$(wc -l < "$PUSH_LOG_B" | tr -d ' ')"

# "Operator fixes connectivity": flip the SAME stub path to succeed, then
# run the SAME captured retry command again.
make_push_stub "$PUSH_STUB_B" "$PUSH_LOG_B" 0
eval "$RETRY_CMD_SOURCE" >/dev/null 2>&1
RC_RETRY_3=$?
check_eq "(c2) manual retry #3 (fixed) succeeds" "0" "$RC_RETRY_3"
check_eq "(c2) push log grew by 1 more (successful retry logged too)" "5" "$(wc -l < "$PUSH_LOG_B" | tr -d ' ')"
check_eq "(c2) history file untouched by any manual retry" "$HIST_B_HASH_BEFORE_RETRIES" "$(cat "$HIST_B")"

# =============================================================================
# case (d): design decision — local archive file missing entirely (not a
# push failure) WARNS and SKIPS rather than failing the append closed.
# =============================================================================
RECEIPT_D="$TMP/receipt-d.json"
make_receipt "$RECEIPT_D" "$TX_ID_D" 300000001 7 "$DAG_ROOT_D" "null" "cyclestart"

HIST_D="$TMP/history-d.jsonl"
ARCHIVE_DIR_D="$TMP/archive-d-empty"
mkdir -p "$ARCHIVE_DIR_D"
# Deliberately do NOT create anchor-source-<hash>.json / anchor-receipt-<hash>.json.

PUSH_LOG_D="$TMP/push-d.log"
PUSH_STUB_D="$TMP/push-stub-success-d.sh"
make_push_stub "$PUSH_STUB_D" "$PUSH_LOG_D" 0
NOTIFY_LOG_D="$TMP/notify-d.log"
NOTIFY_STUB_D="$TMP/notify-stub-d.sh"
make_notify_stub "$NOTIFY_STUB_D" "$NOTIFY_LOG_D"

STDOUT_D="$TMP/run-d.stdout"
STDERR_D="$TMP/run-d.stderr"
PATH="$AJV_FARM:$PATH" \
	ANCHOR_ARCHIVE_DIR="$ARCHIVE_DIR_D" \
	FYD_PUSH_TO_WEB_HOST="$PUSH_STUB_D" \
	FYD_NOTIFY="$NOTIFY_STUB_D" \
	bash "$SCRIPT" --receipt="$RECEIPT_D" --history="$HIST_D" --event-type=cyclestart \
	>"$STDOUT_D" 2>"$STDERR_D"
RC_D=$?
check_eq "(d) missing local archive files: append still succeeds (exit 0, fail-open)" "0" "$RC_D"
check_eq "(d) history line still appended despite missing archive files" "1" "$(wc -l < "$HIST_D" 2>/dev/null | tr -d ' ')"
check_eq "(d) archived_source_path still recorded (pointer written regardless)" \
	"api/archive/anchor-source-${DAG_ROOT_D}.json" "$(jq -r .archived_source_path "$HIST_D" 2>/dev/null)"

if [ -f "$PUSH_LOG_D" ]; then
	fail "(d) push stub was invoked even though the local archive file does not exist (expected 0 calls)"
else
	pass "(d) push never attempted for a nonexistent local archive file"
fi

grep -q 'R18 publish skipped' "$STDERR_D" \
	&& pass "(d) stderr reports publish skipped (not a hard failure)" \
	|| fail "(d) stderr missing publish-skipped report"
SKIP_COUNT_D="$(grep -c 'R18 publish skipped' "$STDERR_D" || true)"
[ -z "$SKIP_COUNT_D" ] && SKIP_COUNT_D=0
check_eq "(d) both missing archives reported (source + receipt)" "2" "$SKIP_COUNT_D"

if [ -f "$NOTIFY_LOG_D" ]; then
	check_eq "(d) notify alert fired once per missing archive" "2" "$(wc -l < "$NOTIFY_LOG_D" | tr -d ' ')"
	grep -q 'missing' "$NOTIFY_LOG_D" \
		&& pass "(d) notify alert title mentions the archive is missing" \
		|| fail "(d) notify alert title does not mention missing archive"
else
	fail "(d) notify stub was never invoked (expected 2 alerts for missing archives)"
fi

# ---- summary -----------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-r18-archive-publish.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
