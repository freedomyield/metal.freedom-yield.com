#!/usr/bin/env bash
# tests/gen-renewal-ics/test-gen-renewal-ics.sh — regression for the dynamic
# renewal-number fix to scripts/gen-renewal-ics.sh.
#
# Before this fix, the script unconditionally hardcoded "Renewal #1 (初回)"
# / "#2" / "#3" for every run, so the public .ics calendar kept announcing
# the FIRST renewal + its initial-only verification checklist forever, even
# after real renewals had already happened (3 recorded as of this fix).
#
# The fix derives the next renewal number from CLOSED_COUNT = the number of
# lines on cycle-history.jsonl (one line per closed cycle — see
# scripts/gen-anchor-source.sh's identical CLOSED_COUNT idiom for
# FY_EXPECT_CYCLE), and only shows the "初回" (first-time) checklist copy
# when CLOSED_COUNT is 0.
#
# CHAIN: none. gen-renewal-ics.sh performs no broadcast (it only writes an
#        .ics file); the real scripts/cycle-gate.sh is called for
#        --side-effect=cycle-artifact-write, which is unconditionally green
#        (no RPC, no state read — see scripts/cycle-gate.sh's own header).
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No broadcast pathway involved.
#
# Platform note: gen-renewal-ics.sh's date formatting helpers (fmt_jst /
# fmt_date / fmt_human) call GNU `date -d "@<epoch>"` unconditionally (no
# BSD-date fallback exists in that script, unlike gen-anchor-source.sh's
# portability shim). This is pre-existing behavior, out of scope for this
# fix. On a host without GNU date -d (e.g. a bare macOS shell), this suite
# SKIPs (reports PASS) rather than fail on an unrelated platform gap — see
# the capability probe below. It runs for real on the validator host / any
# GNU-date-equipped CI runner.
#
# Usage:
#   bash tests/gen-renewal-ics/test-gen-renewal-ics.sh
#
# Exit codes:
#   0  all cases PASS (or capability-probe SKIP)
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/gen-renewal-ics.sh"

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

skip_pass() {
	echo "SKIP: $1"
	echo
	echo "test-gen-renewal-ics.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: PASS"
	exit 0
}

[ -f "$SCRIPT" ] || { echo "FATAL: script not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || skip_pass "jq unavailable"

# Capability probe: gen-renewal-ics.sh's date helpers require GNU `date -d`.
# Confirm it actually works on THIS host before trusting any case below —
# otherwise every case would fail for a reason unrelated to the fix under
# test.
if ! date -u -d "@0" +%Y >/dev/null 2>&1; then
	skip_pass "GNU 'date -d' unavailable on this host (gen-renewal-ics.sh has no BSD-date fallback; pre-existing, out of scope for this fix)"
fi

WORK="$(mktemp -d -t fya-gen-renewal-ics.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Fixed token: 16-64 hex chars (script enforces this pattern).
TOKEN="deadbeefdeadbeefdeadbeef"
TOKEN_FILE="$WORK/calendar-token"
printf '%s' "$TOKEN" > "$TOKEN_FILE"

# Fixture validator.json: numeric epoch strings (matches real node-info.sh
# output shape), so to_epoch() takes its fast numeric path and never itself
# needs `date -d`.
FIXTURE_VALIDATOR_JSON="$WORK/validator.json"
cat > "$FIXTURE_VALIDATOR_JSON" <<'EOF'
{"nodeId":"NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v","startTime":"1750000000","endTime":"1752592000"}
EOF

# run_ics <case_name> <cycle_history_line_count|"absent">
# Runs the real script with an isolated CALENDAR_OUT_DIR per case so cases
# never clobber each other's output, and with CYCLE_HISTORY_JSONL pointed at
# a fixture with the requested number of closed-cycle lines (or a
# nonexistent path when "absent"). Sets the global LAST_ICS to the expected
# output path and RETURNS the real script exit code (do not rely on `$?`
# after a `VAR=$(run_ics ...)` capture — that only reflects the assignment,
# never the function's real exit status).
LAST_ICS=""
run_ics() {
	local case_name="$1" lines="$2"
	local out_dir="$WORK/out-$case_name"
	mkdir -p "$out_dir"
	local cyc_jsonl="$WORK/cycle-history-$case_name.jsonl"
	if [ "$lines" != "absent" ]; then
		: > "$cyc_jsonl"
		local i=1
		while [ "$i" -le "$lines" ]; do
			printf '{"cycle_n":%s,"cycle_status":"closed"}\n' "$i" >> "$cyc_jsonl"
			i=$((i + 1))
		done
	else
		cyc_jsonl="$WORK/nonexistent-cycle-history.jsonl"
	fi
	LAST_ICS="$out_dir/${TOKEN}.ics"
	VALIDATOR_JSON="$FIXTURE_VALIDATOR_JSON" \
		CALENDAR_OUT_DIR="$out_dir" \
		CALENDAR_TOKEN_FILE="$TOKEN_FILE" \
		CYCLE_HISTORY_JSONL="$cyc_jsonl" \
		bash "$SCRIPT" >"$out_dir/stdout.log" 2>"$out_dir/stderr.log"
	return $?
}

# ---- case 1: no cycle-history.jsonl (bootstrap) -> Renewal #1, 初回 -------
run_ics case1 absent
RC1=$?
OUT1_ICS="$LAST_ICS"
if [ "$RC1" -ne 0 ] || [ ! -r "$OUT1_ICS" ]; then
	fail "bootstrap (no cycle-history): script did not produce an .ics file (rc=$RC1); stderr: $(cat "$WORK/out-case1/stderr.log" 2>/dev/null | tr '\n' '|')"
else
	pass "bootstrap (no cycle-history): script exited 0 and wrote the .ics file"
	grep -q "Renewal #1, 初回" "$OUT1_ICS" \
		&& pass "bootstrap: current event labeled 'Renewal #1, 初回'" \
		|| fail "bootstrap: 'Renewal #1, 初回' label missing"
	grep -q "初回 renewal: 入念に検証" "$OUT1_ICS" \
		&& pass "bootstrap: initial-only verification checklist text present" \
		|| fail "bootstrap: initial-only checklist text missing"
	grep -q "UID:metal-renewal-1-${TOKEN}@" "$OUT1_ICS" \
		&& pass "bootstrap: renewal UID uses n=1" \
		|| fail "bootstrap: renewal UID does not use n=1"
	grep -q "Renewal #2, 推定" "$OUT1_ICS" \
		&& pass "bootstrap: next estimated renewal is #2" \
		|| fail "bootstrap: '#2' estimated renewal missing"
	grep -q "Renewal #3, 推定" "$OUT1_ICS" \
		&& pass "bootstrap: second estimated renewal is #3" \
		|| fail "bootstrap: '#3' estimated renewal missing"
fi

# ---- case 2: cycle-history.jsonl with 3 closed cycles -> Renewal #4, no
# 初回 checklist. This is the regression this suite exists to catch: before
# the fix, this case would ALSO have produced "Renewal #1, 初回" — wrong,
# because 3 renewals have already happened.
run_ics case2 3
RC2=$?
OUT2_ICS="$LAST_ICS"
if [ "$RC2" -ne 0 ] || [ ! -r "$OUT2_ICS" ]; then
	fail "3-closed-cycles: script did not produce an .ics file (rc=$RC2); stderr: $(cat "$WORK/out-case2/stderr.log" 2>/dev/null | tr '\n' '|')"
else
	pass "3-closed-cycles: script exited 0 and wrote the .ics file"
	grep -q "Renewal #4)" "$OUT2_ICS" \
		&& pass "3-closed-cycles: current event labeled plain 'Renewal #4' (no 初回 suffix)" \
		|| fail "3-closed-cycles: 'Renewal #4)' plain label missing; got: $(grep 'Renewal #4' "$OUT2_ICS" | tr '\n' '|')"
	if grep -q "初回" "$OUT2_ICS"; then
		fail "3-closed-cycles: initial-only (初回) text must NOT appear — this is the 4th renewal, not the first"
	else
		pass "3-closed-cycles: no 初回 (first-time) text present"
	fi
	if grep -q "Renewal #1" "$OUT2_ICS"; then
		fail "3-closed-cycles: stale hardcoded 'Renewal #1' must NOT appear anywhere in the output"
	else
		pass "3-closed-cycles: no stale hardcoded 'Renewal #1' anywhere in the output"
	fi
	grep -q "UID:metal-renewal-4-${TOKEN}@" "$OUT2_ICS" \
		&& pass "3-closed-cycles: renewal UID uses n=4 (CLOSED_COUNT+1), not n=1" \
		|| fail "3-closed-cycles: renewal UID does not use n=4"
	grep -q "Renewal #5, 推定" "$OUT2_ICS" \
		&& pass "3-closed-cycles: next estimated renewal is #5" \
		|| fail "3-closed-cycles: '#5' estimated renewal missing"
	grep -q "Renewal #6, 推定" "$OUT2_ICS" \
		&& pass "3-closed-cycles: second estimated renewal is #6" \
		|| fail "3-closed-cycles: '#6' estimated renewal missing"
	grep -q "dates は #4 確定後に再計算されます" "$OUT2_ICS" \
		&& pass "3-closed-cycles: estimated-renewal note references #4 (the real current renewal), not #1" \
		|| fail "3-closed-cycles: estimated-renewal note does not reference #4"
fi

echo
echo "----------------------------------------"
echo "test-gen-renewal-ics.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
