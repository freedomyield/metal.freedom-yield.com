#!/usr/bin/env bash
# tests/gen-renewal-ics/test-gen-renewal-ics.sh — regression for the dynamic
# renewal-number fix to scripts/gen-renewal-ics.sh (+ review round 1 fixes).
#
# Before this fix, the script unconditionally hardcoded "Renewal #1 (初回)"
# / "#2" / "#3" for every run, so the public .ics calendar kept announcing
# the FIRST renewal + its initial-only verification checklist forever, even
# after real renewals had already happened (3 recorded as of this fix).
#
# The fix derives the next renewal number from CLOSED_COUNT = the number of
# (non-blank) lines on cycle-history.jsonl (one line per closed cycle — see
# scripts/gen-anchor-source.sh's identical CLOSED_COUNT idiom for
# FY_EXPECT_CYCLE).
#
# Review round 1, item 2: a naive "cycle-history.jsonl absent/unreadable ->
# CLOSED_COUNT=0" is the SAME silent-genesis failure shape the M-2 sibling
# fix (gen-anchor-source.sh) closes for prev_anchor_root — an unreadable
# file is NOT evidence that zero cycles have closed. The fix distinguishes
# three CLOSED_COUNT_SOURCE states: "confirmed" (file readable, count is
# trustworthy — 0 is a legitimate confirmed bootstrap value here),
# "cached" (file unreadable, falls back to the last CONFIRMED count
# persisted at $CLOSED_COUNT_CACHE_FILE), and "unconfirmed" (file
# unreadable AND no cache exists yet — assumes 0 but does NOT claim it is
# confirmed). The "初回" (first-time) checklist text is shown ONLY on a
# CONFIRMED zero — never on a cached or unconfirmed fallback, even when
# that fallback also happens to be 0. This suite covers all four
# combinations (cases 1-4 below), plus the independent wc-l-undercounts-by-
# one-without-a-trailing-newline bug (review round 1, item 5; case 5).
#
# CHAIN: none. gen-renewal-ics.sh performs no broadcast (it only writes an
#        .ics file); the real scripts/cycle-gate.sh is called for
#        --side-effect=cycle-artifact-write, which is unconditionally green
#        (no RPC, no state read — see scripts/cycle-gate.sh's own header).
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No broadcast pathway involved.
#
# Platform note (review round 1, item 1): gen-renewal-ics.sh previously
# called GNU `date -d` unconditionally with no fallback, so this suite
# could only SKIP (report a vacuous PASS=0/FAIL=0 "green") on a non-GNU-date
# host such as a bare macOS shell — an assertion!=verification gap that
# run-all-tests.sh silently counted as a normal pass. The script now probes
# `date --version` and uses BSD `date -r` when GNU `date -d` is unavailable
# (mirrors scripts/gen-anchor-source.sh's identical portability shim), so
# this suite runs its real assertions on every host — no SKIP path remains.
#
# Review round 2: the round-1 BSD fallback for to_epoch()'s rare
# non-numeric (ISO 8601) input branch, `date -j -f "%Y-%m-%dT%H:%M:%SZ" ...`,
# parsed the input in the process's LOCAL timezone instead of UTC — BSD
# strptime treats the format string's trailing "Z" as a literal character,
# not a UTC indicator (unlike GNU `date -d`, which does recognize it).
# Reviewer-verified a 9-hour discrepancy under TZ=Asia/Tokyo. Fixed by
# adding `-u` to the BSD branch. Case 6 below proves the fix two ways: (a)
# drives the REAL script end-to-end with an ISO-string (not numeric)
# validator.json under TZ=Asia/Tokyo and asserts the rendered JST time is
# the correct one, not the 9-hours-off value the bug produced; (b) directly
# computes the epoch via whichever date flavor this host actually has
# (GNU or BSD) and cross-checks it against a Python (`calendar.timegm`)
# ground truth, which is the transitive form of "GNU and BSD agree" that
# works on any single host regardless of which one it natively has.
#
# Usage:
#   bash tests/gen-renewal-ics/test-gen-renewal-ics.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/gen-renewal-ics.sh"

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

[ -f "$SCRIPT" ] || { echo "FATAL: script not found at $SCRIPT" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
	echo "FATAL: jq unavailable — cannot run this suite" >&2
	exit 1
fi

WORK="$(mktemp -d -t fya-gen-renewal-ics.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Fixed token: 16-64 hex chars (script enforces this pattern).
TOKEN="deadbeefdeadbeefdeadbeef"
TOKEN_FILE="$WORK/calendar-token"
printf '%s' "$TOKEN" > "$TOKEN_FILE"

# Fixture validator.json: numeric epoch strings (matches real node-info.sh
# output shape), so to_epoch() takes its fast numeric path.
FIXTURE_VALIDATOR_JSON="$WORK/validator.json"
cat > "$FIXTURE_VALIDATOR_JSON" <<'EOF'
{"nodeId":"NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v","startTime":"1750000000","endTime":"1752592000"}
EOF

# run_ics <case_name> <cycle_history_line_count|"absent"> [no_trailing_newline]
# Runs the real script with an isolated CALENDAR_OUT_DIR (and therefore an
# isolated CLOSED_COUNT_CACHE_FILE, since that defaults under
# CALENDAR_OUT_DIR) per case, so cases never clobber each other's output OR
# cache. CYCLE_HISTORY_JSONL points at a fixture with the requested number
# of closed-cycle lines, or a nonexistent path when "absent". Pass
# "no_trailing_newline" as the 3rd arg to omit the final line's trailing
# newline (review round 1, item 5 regression). Sets the global LAST_ICS /
# LAST_OUT_DIR and RETURNS the real script exit code (do not rely on `$?`
# after a `VAR=$(run_ics ...)` capture — that only reflects the assignment,
# never the function's real exit status).
LAST_ICS=""
LAST_OUT_DIR=""
run_ics() {
	local case_name="$1" lines="$2" no_trailing_nl="${3:-}"
	local out_dir="$WORK/out-$case_name"
	mkdir -p "$out_dir"
	local cyc_jsonl="$WORK/cycle-history-$case_name.jsonl"
	if [ "$lines" != "absent" ]; then
		: > "$cyc_jsonl"
		local i=1
		while [ "$i" -le "$lines" ]; do
			if [ "$i" -eq "$lines" ] && [ "$no_trailing_nl" = "no_trailing_newline" ]; then
				printf '{"cycle_n":%s,"cycle_status":"closed"}' "$i" >> "$cyc_jsonl"
			else
				printf '{"cycle_n":%s,"cycle_status":"closed"}\n' "$i" >> "$cyc_jsonl"
			fi
			i=$((i + 1))
		done
	else
		cyc_jsonl="$WORK/nonexistent-cycle-history-$case_name.jsonl"
	fi
	LAST_ICS="$out_dir/${TOKEN}.ics"
	LAST_OUT_DIR="$out_dir"
	VALIDATOR_JSON="$FIXTURE_VALIDATOR_JSON" \
		CALENDAR_OUT_DIR="$out_dir" \
		CALENDAR_TOKEN_FILE="$TOKEN_FILE" \
		CYCLE_HISTORY_JSONL="$cyc_jsonl" \
		bash "$SCRIPT" >"$out_dir/stdout.log" 2>"$out_dir/stderr.log"
	return $?
}

# ---- case 1: cycle-history.jsonl EXISTS and is readable with 0 lines
# (CONFIRMED zero = genuine pre-first-cycle bootstrap) -> Renewal #1, 初回.
# This is the ONLY state that may show the initial-only checklist text.
run_ics case1 0
RC1=$?
OUT1_ICS="$LAST_ICS"
if [ "$RC1" -ne 0 ] || [ ! -r "$OUT1_ICS" ]; then
	fail "confirmed-zero bootstrap: script did not produce an .ics file (rc=$RC1); stderr: $(cat "$LAST_OUT_DIR/stderr.log" 2>/dev/null | tr '\n' '|')"
else
	pass "confirmed-zero bootstrap: script exited 0 and wrote the .ics file"
	grep -q "Renewal #1, 初回" "$OUT1_ICS" \
		&& pass "confirmed-zero bootstrap: current event labeled 'Renewal #1, 初回'" \
		|| fail "confirmed-zero bootstrap: 'Renewal #1, 初回' label missing"
	grep -q "初回 renewal: 入念に検証" "$OUT1_ICS" \
		&& pass "confirmed-zero bootstrap: initial-only verification checklist text present" \
		|| fail "confirmed-zero bootstrap: initial-only checklist text missing"
	grep -q "UID:metal-renewal-1-${TOKEN}@" "$OUT1_ICS" \
		&& pass "confirmed-zero bootstrap: renewal UID uses n=1" \
		|| fail "confirmed-zero bootstrap: renewal UID does not use n=1"
	grep -q "Renewal #2, 推定" "$OUT1_ICS" \
		&& pass "confirmed-zero bootstrap: next estimated renewal is #2" \
		|| fail "confirmed-zero bootstrap: '#2' estimated renewal missing"
	grep -q "Renewal #3, 推定" "$OUT1_ICS" \
		&& pass "confirmed-zero bootstrap: second estimated renewal is #3" \
		|| fail "confirmed-zero bootstrap: '#3' estimated renewal missing"
fi

# ---- case 2: cycle-history.jsonl ABSENT + no cache -> UNCONFIRMED zero.
# Review round 1, item 2 regression: before the fix, absent/unreadable
# silently produced the SAME "Renewal #1, 初回" as a confirmed bootstrap —
# a false claim of confirmation. Now: still generates a usable .ics
# (fail-SAFE, not fail-closed — the cron chain into push must not break),
# still numbers it #1 (best available guess), but the 初回 checklist text
# must NOT appear, and a WARN must be emitted naming the guard.
run_ics case2 absent
RC2=$?
OUT2_ICS="$LAST_ICS"
if [ "$RC2" -ne 0 ] || [ ! -r "$OUT2_ICS" ]; then
	fail "absent+no-cache: script did not produce an .ics file (rc=$RC2); stderr: $(cat "$LAST_OUT_DIR/stderr.log" 2>/dev/null | tr '\n' '|')"
else
	pass "absent+no-cache: script exited 0 and still wrote an .ics file (fail-safe, not fail-closed)"
	if grep -q "初回" "$OUT2_ICS"; then
		fail "absent+no-cache: initial-only (初回) text must NOT appear — the zero here was never confirmed"
	else
		pass "absent+no-cache: no 初回 (first-time) text present (unconfirmed zero, not a claimed-confirmed one)"
	fi
	grep -q "次回 (Renewal #1)" "$OUT2_ICS" \
		&& pass "absent+no-cache: current event still gets a best-available plain 'Renewal #1' label" \
		|| fail "absent+no-cache: plain 'Renewal #1' label missing; got: $(grep 'Renewal #1' "$OUT2_ICS" | tr '\n' '|')"
	grep -q "UNCONFIRMED" "$LAST_OUT_DIR/stderr.log" \
		&& pass "absent+no-cache: WARN identifies the value as UNCONFIRMED" \
		|| fail "absent+no-cache: WARN missing UNCONFIRMED marker; stderr: $(cat "$LAST_OUT_DIR/stderr.log" 2>/dev/null | tr '\n' '|')"
fi

# ---- case 3: cycle-history.jsonl with 3 closed cycles (CONFIRMED) ->
# Renewal #4, no 初回 checklist, no stale "Renewal #1" anywhere. This is
# the core regression the original fix (before review round 1) exists to
# catch: before it, this case ALSO produced "Renewal #1, 初回" — wrong,
# because 3 renewals have already happened.
run_ics case3 3
RC3=$?
OUT3_ICS="$LAST_ICS"
if [ "$RC3" -ne 0 ] || [ ! -r "$OUT3_ICS" ]; then
	fail "3-closed-cycles: script did not produce an .ics file (rc=$RC3); stderr: $(cat "$LAST_OUT_DIR/stderr.log" 2>/dev/null | tr '\n' '|')"
else
	pass "3-closed-cycles: script exited 0 and wrote the .ics file"
	grep -q "Renewal #4)" "$OUT3_ICS" \
		&& pass "3-closed-cycles: current event labeled plain 'Renewal #4' (no 初回 suffix)" \
		|| fail "3-closed-cycles: 'Renewal #4)' plain label missing; got: $(grep 'Renewal #4' "$OUT3_ICS" | tr '\n' '|')"
	if grep -q "初回" "$OUT3_ICS"; then
		fail "3-closed-cycles: initial-only (初回) text must NOT appear — this is the 4th renewal, not the first"
	else
		pass "3-closed-cycles: no 初回 (first-time) text present"
	fi
	if grep -q "Renewal #1" "$OUT3_ICS"; then
		fail "3-closed-cycles: stale hardcoded 'Renewal #1' must NOT appear anywhere in the output"
	else
		pass "3-closed-cycles: no stale hardcoded 'Renewal #1' anywhere in the output"
	fi
	grep -q "UID:metal-renewal-4-${TOKEN}@" "$OUT3_ICS" \
		&& pass "3-closed-cycles: renewal UID uses n=4 (CLOSED_COUNT+1), not n=1" \
		|| fail "3-closed-cycles: renewal UID does not use n=4"
	grep -q "Renewal #5, 推定" "$OUT3_ICS" \
		&& pass "3-closed-cycles: next estimated renewal is #5" \
		|| fail "3-closed-cycles: '#5' estimated renewal missing"
	grep -q "Renewal #6, 推定" "$OUT3_ICS" \
		&& pass "3-closed-cycles: second estimated renewal is #6" \
		|| fail "3-closed-cycles: '#6' estimated renewal missing"
	grep -q "dates は #4 確定後に再計算されます" "$OUT3_ICS" \
		&& pass "3-closed-cycles: estimated-renewal note references #4 (the real current renewal), not #1" \
		|| fail "3-closed-cycles: estimated-renewal note does not reference #4"

	CACHE_FILE_3="$LAST_OUT_DIR/.last-closed-count"
	if [ -r "$CACHE_FILE_3" ] && [ "$(tr -d '[:space:]' < "$CACHE_FILE_3")" = "3" ]; then
		pass "3-closed-cycles: CONFIRMED count 3 persisted to the cache file"
	else
		fail "3-closed-cycles: cache file missing or wrong; got: $(cat "$CACHE_FILE_3" 2>/dev/null || echo '<absent>')"
	fi

	# ---- case 4: SAME out_dir (so it inherits case 3's cache), but
	# cycle-history.jsonl now made unreadable -> must use the CACHED
	# CONFIRMED count (3), NOT reset to 0. This is the "retain the previous
	# value" half of review round 1, item 2's fix: an operational hiccup
	# reading cycle-history.jsonl AFTER cycles have already closed must
	# not silently regress the public calendar back to "Renewal #1".
	NONEXISTENT_CH="$WORK/nonexistent-for-case4.jsonl"
	STDOUT4="$LAST_OUT_DIR/stdout-case4.log"
	STDERR4="$LAST_OUT_DIR/stderr-case4.log"
	VALIDATOR_JSON="$FIXTURE_VALIDATOR_JSON" \
		CALENDAR_OUT_DIR="$LAST_OUT_DIR" \
		CALENDAR_TOKEN_FILE="$TOKEN_FILE" \
		CYCLE_HISTORY_JSONL="$NONEXISTENT_CH" \
		bash "$SCRIPT" >"$STDOUT4" 2>"$STDERR4"
	RC4=$?
	OUT4_ICS="$LAST_OUT_DIR/${TOKEN}.ics"
	if [ "$RC4" -ne 0 ] || [ ! -r "$OUT4_ICS" ]; then
		fail "absent+cached-3: script did not produce an .ics file (rc=$RC4); stderr: $(cat "$STDERR4" 2>/dev/null | tr '\n' '|')"
	else
		pass "absent+cached-3: script exited 0 and wrote the .ics file"
		grep -q "UID:metal-renewal-4-${TOKEN}@" "$OUT4_ICS" \
			&& pass "absent+cached-3: renewal UID STILL uses n=4 (retained the cached CONFIRMED count, not reset to 0/n=1)" \
			|| fail "absent+cached-3: renewal UID regressed away from n=4; got: $(grep 'UID:metal-renewal' "$OUT4_ICS" | tr '\n' '|')"
		if grep -q "初回" "$OUT4_ICS"; then
			fail "absent+cached-3: initial-only (初回) text must NOT appear — this run's count is CACHED, not freshly confirmed"
		else
			pass "absent+cached-3: no 初回 text (cached fallback correctly not treated as a fresh confirmation)"
		fi
		grep -qi "cached" "$STDERR4" \
			&& pass "absent+cached-3: WARN identifies the count as cached / not freshly confirmed" \
			|| fail "absent+cached-3: WARN missing cached-value marker; stderr: $(cat "$STDERR4" 2>/dev/null | tr '\n' '|')"
	fi
fi

# ---- case 5: cycle-history.jsonl with 3 closed-cycle lines where the LAST
# line has NO trailing newline -> CLOSED_COUNT must still be 3, not 2.
# Review round 1, item 5 regression: `wc -l` counts newline BYTES, so a
# file whose last line lacks a trailing \n undercounts by exactly one —
# independent of (but adjacent to) the M-2 blank-line-tolerance fix this
# script's CLOSED_COUNT derivation was unified with.
run_ics case5 3 no_trailing_newline
RC5=$?
OUT5_ICS="$LAST_ICS"
if [ "$RC5" -ne 0 ] || [ ! -r "$OUT5_ICS" ]; then
	fail "no-trailing-newline: script did not produce an .ics file (rc=$RC5); stderr: $(cat "$LAST_OUT_DIR/stderr.log" 2>/dev/null | tr '\n' '|')"
else
	# Harness sanity: confirm the fixture really does lack a trailing
	# newline (otherwise this case would silently degrade into a duplicate
	# of case 3, not exercise the undercount bug at all).
	LAST_BYTE="$(tail -c 1 "$WORK/cycle-history-case5.jsonl" | od -An -c | tr -d ' ')"
	if [ "$LAST_BYTE" = "\\n" ]; then
		fail "harness: no-trailing-newline fixture unexpectedly ends in a newline — refusing to trust case 5"
	fi
	grep -q "UID:metal-renewal-4-${TOKEN}@" "$OUT5_ICS" \
		&& pass "no-trailing-newline: CLOSED_COUNT correctly counted as 3 (renewal UID uses n=4), not undercounted to 2" \
		|| fail "no-trailing-newline: renewal UID does not use n=4 (wc -l undercount regression); got: $(grep 'UID:metal-renewal' "$OUT5_ICS" | tr '\n' '|')"
fi

# ---- case 6: review round 2 — BSD date_from_iso() must parse "...Z" ISO
# input as UTC, not local time. (a) drives the REAL script end to end with
# an ISO-string (non-numeric) validator.json under TZ=Asia/Tokyo forced for
# the whole process (date_from_iso() carries no TZ override of its own, so
# the bug depended on the AMBIENT TZ at the moment it ran — forcing it here
# makes the bug reproduce deterministically on any host, not just one whose
# local zone happens to be non-UTC). (b) directly cross-checks the epoch
# produced by whichever date flavor(s) this host actually has against a
# Python (`calendar.timegm`) ground truth, which is the transitive form of
# "GNU and BSD branches agree" that works on a single host — plus a
# negative control proving the pre-fix BSD form WOULD have been caught by
# this same ground-truth comparison (so the check has teeth, not just
# vacuous agreement).
ISO_VALIDATOR_JSON="$WORK/validator-iso.json"
cat > "$ISO_VALIDATOR_JSON" <<'EOF'
{"nodeId":"NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v","startTime":"2026-07-01T00:00:00Z","endTime":"2026-07-16T00:00:00Z"}
EOF
ISO_OUT_DIR="$WORK/out-iso"
mkdir -p "$ISO_OUT_DIR"
ISO_STDERR="$ISO_OUT_DIR/stderr.log"
TZ=Asia/Tokyo \
	VALIDATOR_JSON="$ISO_VALIDATOR_JSON" \
	CALENDAR_OUT_DIR="$ISO_OUT_DIR" \
	CALENDAR_TOKEN_FILE="$TOKEN_FILE" \
	CYCLE_HISTORY_JSONL="$WORK/nonexistent-cycle-history-iso.jsonl" \
	bash "$SCRIPT" >"$ISO_OUT_DIR/stdout.log" 2>"$ISO_STDERR"
RC6=$?
OUT6_ICS="$ISO_OUT_DIR/${TOKEN}.ics"
if [ "$RC6" -ne 0 ] || [ ! -r "$OUT6_ICS" ]; then
	fail "ISO-string date parsing: script did not produce an .ics file (rc=$RC6); stderr: $(cat "$ISO_STDERR" 2>/dev/null | tr '\n' '|')"
else
	pass "ISO-string date parsing: script exited 0 and wrote the .ics file"
	# Correct: 2026-07-16T00:00:00Z rendered in JST is 09:00 (UTC+9). The
	# pre-round-2 bug (BSD date_from_iso without -u, under TZ=Asia/Tokyo
	# ambient) would instead have produced "07/16 00:00 JST" here — a
	# silent 9-hour shift, not a crash, so only a value-level assertion can
	# catch it.
	grep -q "endTime: 07/16 09:00 JST" "$OUT6_ICS" \
		&& pass "ISO-string date parsing: endTime renders as the correct 07/16 09:00 JST (UTC+9 of 00:00 UTC)" \
		|| fail "ISO-string date parsing: endTime did not render correctly; got: $(grep 'endTime:' "$OUT6_ICS" | tr '\n' '|')"
	if grep -q "endTime: 07/16 00:00 JST" "$OUT6_ICS"; then
		fail "ISO-string date parsing: endTime shows the review-round-2 bug's 9-hours-off value (07/16 00:00 JST) — BSD date_from_iso() is parsing 'Z' input as local time, not UTC"
	else
		pass "ISO-string date parsing: the review-round-2 buggy 9-hours-off value is absent"
	fi
fi

# (b) direct epoch-level parity check.
ISO_INPUT="2026-07-16T00:00:00Z"
EXPECTED_EPOCH="$(python3 -c "import calendar,time; print(calendar.timegm(time.strptime('${ISO_INPUT}','%Y-%m-%dT%H:%M:%SZ')))" 2>/dev/null || true)"
if [ -z "$EXPECTED_EPOCH" ]; then
	echo "SKIP: python3 unavailable — cannot compute the ground-truth epoch for the GNU/BSD parity check" >&2
else
	GNU_EPOCH=""
	# Prefer this host's native `date` if it is GNU; otherwise probe common
	# Homebrew coreutils gnubin locations so the direct GNU-vs-BSD
	# comparison actually runs (not just the ground-truth comparison) on a
	# macOS dev machine that happens to have coreutils installed, without
	# altering this suite's own PATH/behavior anywhere else.
	if date --version >/dev/null 2>&1; then
		GNU_DATE_BIN="date"
	else
		GNU_DATE_BIN=""
		for cand in /opt/homebrew/opt/coreutils/libexec/gnubin/date /usr/local/opt/coreutils/libexec/gnubin/date; do
			if [ -x "$cand" ] && "$cand" --version >/dev/null 2>&1; then
				GNU_DATE_BIN="$cand"
				break
			fi
		done
	fi
	if [ -n "$GNU_DATE_BIN" ]; then
		GNU_EPOCH="$("$GNU_DATE_BIN" -d "$ISO_INPUT" +%s)"
		if [ "$GNU_EPOCH" = "$EXPECTED_EPOCH" ]; then
			pass "GNU date_from_iso form ($GNU_DATE_BIN -d) matches ground-truth epoch for $ISO_INPUT"
		else
			fail "GNU date_from_iso form disagrees with ground truth: got=$GNU_EPOCH expected=$EXPECTED_EPOCH"
		fi
	fi
	BSD_EPOCH=""
	if date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ISO_INPUT" +%s >/dev/null 2>&1; then
		BSD_EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ISO_INPUT" +%s)"
		if [ "$BSD_EPOCH" = "$EXPECTED_EPOCH" ]; then
			pass "BSD (fixed, -j -u -f) date_from_iso form matches ground-truth epoch for $ISO_INPUT"
		else
			fail "BSD (fixed, -j -u -f) date_from_iso form disagrees with ground truth: got=$BSD_EPOCH expected=$EXPECTED_EPOCH"
		fi
		# Negative control: prove the round-2 bug WOULD have been caught by
		# this same ground-truth comparison (this check has teeth, it is not
		# vacuously agreeing because both sides are wrong the same way).
		BSD_EPOCH_BUGGY="$(TZ=Asia/Tokyo date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ISO_INPUT" +%s 2>/dev/null || true)"
		if [ -n "$BSD_EPOCH_BUGGY" ] && [ "$BSD_EPOCH_BUGGY" != "$EXPECTED_EPOCH" ]; then
			pass "negative control: the pre-fix BSD form (no -u, TZ=Asia/Tokyo) DOES disagree with ground truth — confirms this check has teeth"
		else
			fail "negative control: expected the pre-fix BSD form to disagree with ground truth under TZ=Asia/Tokyo, but it did not (got=$BSD_EPOCH_BUGGY expected=$EXPECTED_EPOCH) — this parity check may not actually be discriminating"
		fi
	fi
	if [ -n "$GNU_EPOCH" ] && [ -n "$BSD_EPOCH" ]; then
		if [ "$GNU_EPOCH" = "$BSD_EPOCH" ]; then
			pass "GNU and BSD date_from_iso forms produce the IDENTICAL epoch for the same ISO input (direct cross-branch parity)"
		else
			fail "GNU and BSD date_from_iso forms DISAGREE: GNU=$GNU_EPOCH BSD=$BSD_EPOCH"
		fi
	fi
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
