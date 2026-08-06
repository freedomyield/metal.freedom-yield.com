#!/usr/bin/env bash
# test-check-watch-validators.sh — suite for scripts/check-watch-validators.sh
# (salvaged to the repo + repointed to the private host-local watch list,
# 2026-07-06; notification design reworked 2026-07-07 after the 01:00 JST
# incident: one batched notification per run at min/low priority, and an
# explorer sanity gate so an API fault can never fabricate a mass departure).
#
# CHAIN: none — the explorer API is a file:// stub, the notifier is a
#        recording stub, and all paths live in a tempdir harness. No real
#        RPC / explorer / ntfy is ever touched.
#
# Usage:
#   bash tests/watch-validators/test-check-watch-validators.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-watch-validators.sh"

if [ ! -f "$CHECKER" ]; then
	echo "FATAL: checker not found at $CHECKER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

NID="NodeID-testwatch1111111111111111111111111"
NID2="NodeID-testwatch2222222222222222222222222"

BASE=""; STUB_LOG=""
setup() {
	BASE="$(mktemp -d -t watch-test.XXXXXX)"
	STUB_LOG="$BASE/notify.log"
	mkdir -p "$BASE/state"
	# Each invocation records one CALL| line (priority|title) followed by the
	# raw message body — the body may be multi-line, so call count is the
	# number of ^CALL| lines, not the number of log lines.
	cat > "$BASE/notify-stub.sh" <<STUBEOF
#!/usr/bin/env bash
printf 'CALL|%s|%s\n%s\n' "\$1" "\$2" "\$3" >> "$STUB_LOG"
STUBEOF
	chmod +x "$BASE/notify-stub.sh"
	printf '[\n  "%s"\n]\n' "$NID" > "$BASE/watch-list.json"
}
teardown() { rm -rf "$BASE"; BASE=""; }

# explorer_stub <json> — write the explorer response the checker will curl.
explorer_stub() { printf '%s' "$1" > "$BASE/explorer.json"; }

# FY_LIVE=1 is what makes the recording stub actually get called and the
# baseline actually get written: since the C3 inversion
# (scripts/lib/side-effects.sh, 2026-08-06) every side effect is opt-in, so a
# run without it is a loud dry no-op. That default-dry behaviour has its own
# coverage in tests/side-effects-callers/test-monitoring-side-effects.sh; here
# we opt in because these cases are about WHAT is notified and persisted.
# Note FY_LIVE and --dry-run are different knobs: --dry-run stays an
# operator-facing "detect and report" flag and is still exercised by case 8.
run_checker() {
	FY_LIVE=1 \
	WATCH_LIST_FILE="$BASE/watch-list.json" \
	WATCH_STATE_DIR="$BASE/state" \
	EXPLORER_API="file://$BASE/explorer.json" \
	EXPLORER_MIN_VALIDATORS="${FLOOR_OVERRIDE:-0}" \
	WATCH_NOTIFY="${NOTIFY_OVERRIDE:-$BASE/notify-stub.sh}" \
	NOTIFY_RETRY_SLEEP=0 \
	bash "$CHECKER" "$@"
}
alerts() { cat "$STUB_LOG" 2>/dev/null; }
ncalls() { grep -c '^CALL|' "$STUB_LOG" 2>/dev/null || echo 0; }
state()  { cat "$BASE/state/watch-prev-state.json" 2>/dev/null; }

# ---- case 1: list missing → graceful no-op, no state created --------------------
setup
rm "$BASE/watch-list.json"
OUT="$(run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "no list: exit 0" \
	|| bad "no list: exit 0 (actual=$RC)"
echo "$OUT" | grep -q 'no watch list' \
	&& ok "no list: graceful message" \
	|| bad "no list: graceful message (out: $OUT)"
[ -f "$BASE/state/watch-prev-state.json" ] \
	&& bad "no list: no state written" \
	|| ok "no list: no state written"
teardown

# ---- case 2: empty/malformed list → graceful no-op --------------------------------
setup
echo '{}' > "$BASE/watch-list.json"
OUT="$(run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'watch list is empty' \
	&& ok "malformed list: graceful empty handling (exit 0)" \
	|| bad "malformed list: graceful empty handling (rc=$RC out: $OUT)"
teardown

# ---- case 3: first run = silent baseline, state persisted -------------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
OUT="$(run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "baseline: exit 0" \
	|| bad "baseline: exit 0 (actual=$RC)"
[ -s "$STUB_LOG" ] \
	&& bad "baseline: silent (no notify)" \
	|| ok "baseline: silent (no notify)"
state | jq -e --arg n "$NID" '.[$n].active == true' >/dev/null \
	&& ok "baseline: state persisted with active=true" \
	|| bad "baseline: state persisted with active=true (state: $(state))"
teardown

# ---- case 4: name_appeared → single low-priority batched notify --------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[{\"nodeId\": \"$NID\", \"name\": \"Acme Validator\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
alerts | grep -qF "CALL|low|Watch validators: 1 change(s)" \
	&& ok "name_appeared: one low-priority batched notify" \
	|| bad "name_appeared: one low-priority batched notify (alerts: $(alerts))"
alerts | grep -qF "named: $NID → Acme Validator" \
	&& ok "name_appeared: body carries the name line" \
	|| bad "name_appeared: body carries the name line (alerts: $(alerts))"
state | jq -e --arg n "$NID" '.[$n].name == "Acme Validator"' >/dev/null \
	&& ok "name_appeared: state carries the new name" \
	|| bad "name_appeared: state carries the new name"
teardown

# ---- case 5: first_delegation → single low-priority batched notify ------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": [{\"x\": 1}, {\"x\": 2}]}]"
run_checker >/dev/null 2>&1
alerts | grep -qF "CALL|low|Watch validators: 1 change(s)" \
	&& ok "first_delegation: one low-priority batched notify" \
	|| bad "first_delegation: one low-priority batched notify (alerts: $(alerts))"
alerts | grep -qF "first delegation: $NID (2 delegator(s))" \
	&& ok "first_delegation: body carries the count" \
	|| bad "first_delegation: body carries the count (alerts: $(alerts))"
teardown

# ---- case 6: departed → single min-priority batched notify ---------------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[]"
run_checker >/dev/null 2>&1
alerts | grep -qF "CALL|min|Watch validators: 1 change(s)" \
	&& ok "departed: one min-priority batched notify" \
	|| bad "departed: one min-priority batched notify (alerts: $(alerts))"
alerts | grep -qF "left active set: $NID" \
	&& ok "departed: body carries the departure line" \
	|| bad "departed: body carries the departure line (alerts: $(alerts))"
teardown

# ---- case 7: rejoined → single min-priority batched notify ----------------------------
setup
printf '{"%s": {"active": false}}' "$NID" > "$BASE/state/watch-prev-state.json"
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": [{\"x\": 1}]}]"
run_checker >/dev/null 2>&1
alerts | grep -qF "CALL|min|Watch validators: 1 change(s)" \
	&& ok "rejoined: one min-priority batched notify" \
	|| bad "rejoined: one min-priority batched notify (alerts: $(alerts))"
alerts | grep -qF "rejoined active set: $NID (delegators: 1)" \
	&& ok "rejoined: body carries the rejoin line" \
	|| bad "rejoined: body carries the rejoin line (alerts: $(alerts))"
teardown

# ---- case 8: --dry-run detects but does not notify --------------------------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[{\"nodeId\": \"$NID\", \"name\": \"Acme\", \"delegators\": []}]"
OUT="$(run_checker --dry-run 2>&1)"
echo "$OUT" | grep -q '1 change(s) detected' \
	&& ok "dry-run: change detected and reported" \
	|| bad "dry-run: change detected and reported (out: $OUT)"
[ -s "$STUB_LOG" ] \
	&& bad "dry-run: no notify fired" \
	|| ok "dry-run: no notify fired"
state | jq -e --arg n "$NID" '.[$n].name == null' >/dev/null \
	&& ok "dry-run: baseline state NOT overwritten (pending alert preserved)" \
	|| bad "dry-run: baseline state NOT overwritten (state: $(state))"
run_checker >/dev/null 2>&1
alerts | grep -q '^CALL|low|' \
	&& ok "dry-run then real run: pending alert still fires" \
	|| bad "dry-run then real run: pending alert still fires (alerts: $(alerts))"
teardown

# ---- case 9: multiple changes in one run → exactly ONE notification ----------------------
# This is the 2026-07-07 01:00 JST incident shape: several watched validators
# change state in the same tick. The old design pushed one notification per
# validator (4 pushes at night); the reworked design batches them into a
# single message. Priority is the max class present (name/delegation = low,
# departure/rejoin = min).
setup
printf '[\n  "%s",\n  "%s"\n]\n' "$NID" "$NID2" > "$BASE/watch-list.json"
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}, {\"nodeId\": \"$NID2\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[{\"nodeId\": \"$NID2\", \"name\": \"Acme\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
[ "$(ncalls)" -eq 1 ] \
	&& ok "batch: exactly one notify call for 2 changes" \
	|| bad "batch: exactly one notify call for 2 changes (calls=$(ncalls) alerts: $(alerts))"
alerts | grep -qF "CALL|low|Watch validators: 2 change(s)" \
	&& ok "batch: title counts 2 changes, priority = low (max class)" \
	|| bad "batch: title counts 2 changes, priority = low (alerts: $(alerts))"
alerts | grep -qF "left active set: $NID" && alerts | grep -qF "named: $NID2 → Acme" \
	&& ok "batch: body carries both change lines" \
	|| bad "batch: body carries both change lines (alerts: $(alerts))"
teardown

# ---- case 10: explorer fetch failure → skip run, state untouched, no alerts ---------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
BEFORE="$(state)"
rm "$BASE/explorer.json"          # curl file:// now fails → transport error
OUT="$(run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "fetch failure: exit 0 (cron stays green)" \
	|| bad "fetch failure: exit 0 (actual=$RC)"
echo "$OUT" | grep -qi 'skipping' \
	&& ok "fetch failure: skip is logged" \
	|| bad "fetch failure: skip is logged (out: $OUT)"
[ "$(ncalls)" -eq 0 ] \
	&& ok "fetch failure: no departed alerts fabricated" \
	|| bad "fetch failure: no departed alerts fabricated (alerts: $(alerts))"
[ "$(state)" = "$BEFORE" ] \
	&& ok "fetch failure: baseline state untouched" \
	|| bad "fetch failure: baseline state untouched"
teardown

# ---- case 11: non-array explorer response → skip run, state untouched ---------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
BEFORE="$(state)"
explorer_stub '{"error": "maintenance"}'
OUT="$(run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -qi 'skipping' \
	&& ok "non-array response: skipped gracefully" \
	|| bad "non-array response: skipped gracefully (rc=$RC out: $OUT)"
[ "$(ncalls)" -eq 0 ] && [ "$(state)" = "$BEFORE" ] \
	&& ok "non-array response: no alerts, state untouched" \
	|| bad "non-array response: no alerts, state untouched (alerts: $(alerts))"
teardown

# ---- case 12: response below sanity floor → skip run (API fault, not mass exodus) ----------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
BEFORE="$(state)"
explorer_stub "[]"
OUT="$(FLOOR_OVERRIDE=3 run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -qi 'skipping' \
	&& ok "below floor: skipped as API fault" \
	|| bad "below floor: skipped as API fault (rc=$RC out: $OUT)"
[ "$(ncalls)" -eq 0 ] && [ "$(state)" = "$BEFORE" ] \
	&& ok "below floor: no mass-departure alerts, state untouched" \
	|| bad "below floor: no mass-departure alerts, state untouched (alerts: $(alerts))"
teardown

# ---- case 13 (R5): notify permanently fails → baseline NOT advanced, re-detected next run ---
# A stub that always exits 3 (= notify.sh strict-mode HTTP 4xx non-429 —
# no-retry classification) so exactly one call happens and it never succeeds.
setup
cat > "$BASE/notify-fail-stub.sh" <<STUBEOF
#!/usr/bin/env bash
printf 'CALL|%s|%s\n%s\n' "\$1" "\$2" "\$3" >> "$STUB_LOG"
exit 3
STUBEOF
chmod +x "$BASE/notify-fail-stub.sh"
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
BEFORE="$(state)"
explorer_stub "[{\"nodeId\": \"$NID\", \"name\": \"Acme\", \"delegators\": []}]"
OUT="$(NOTIFY_OVERRIDE="$BASE/notify-fail-stub.sh" run_checker 2>&1)"
[ "$(ncalls)" -eq 1 ] \
	&& ok "R5 permanent fail: exactly 1 notify attempt (no retry on non-retryable rc)" \
	|| bad "R5 permanent fail: exactly 1 notify attempt (calls=$(ncalls))"
echo "$OUT" | grep -qi 'not confirmed' \
	&& ok "R5 permanent fail: logs non-confirmation" \
	|| bad "R5 permanent fail: logs non-confirmation (out: $OUT)"
[ "$(state)" = "$BEFORE" ] \
	&& ok "R5 permanent fail: baseline state NOT advanced" \
	|| bad "R5 permanent fail: baseline state NOT advanced (before: $BEFORE after: $(state))"
# Next run with a working notifier must still see (and fire) the same pending change.
run_checker >/dev/null 2>&1
alerts | grep -qF "named: $NID → Acme" \
	&& ok "R5 permanent fail: pending change re-detected and delivered on next run" \
	|| bad "R5 permanent fail: pending change re-detected and delivered on next run (alerts: $(alerts))"
state | jq -e --arg n "$NID" '.[$n].name == "Acme"' >/dev/null \
	&& ok "R5 permanent fail: baseline advances once delivery is confirmed" \
	|| bad "R5 permanent fail: baseline advances once delivery is confirmed (state: $(state))"
teardown

# ---- case 14 (R5): notify fails once (retryable) then succeeds → 2 attempts, state advances --
setup
cat > "$BASE/notify-flaky-stub.sh" <<STUBEOF
#!/usr/bin/env bash
printf 'CALL|%s|%s\n%s\n' "\$1" "\$2" "\$3" >> "$STUB_LOG"
n=0
[ -f "$BASE/flaky-ctr" ] && n=\$(cat "$BASE/flaky-ctr")
n=\$((n + 1))
echo "\$n" > "$BASE/flaky-ctr"
if [ "\$n" -eq 1 ]; then exit 5; else exit 0; fi
STUBEOF
chmod +x "$BASE/notify-flaky-stub.sh"
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[{\"nodeId\": \"$NID\", \"name\": \"Acme\", \"delegators\": []}]"
NOTIFY_OVERRIDE="$BASE/notify-flaky-stub.sh" run_checker >/dev/null 2>&1
[ "$(ncalls)" -eq 2 ] \
	&& ok "R5 retryable fail then success: 2 attempts (1 initial + 1 retry)" \
	|| bad "R5 retryable fail then success: 2 attempts (calls=$(ncalls))"
state | jq -e --arg n "$NID" '.[$n].name == "Acme"' >/dev/null \
	&& ok "R5 retryable fail then success: baseline advances in the SAME run" \
	|| bad "R5 retryable fail then success: baseline advances in the SAME run (state: $(state))"
teardown

# ---- summary ------------------------------------------------------------------------------
echo "test-check-watch-validators.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
