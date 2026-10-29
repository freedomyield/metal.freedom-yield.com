#!/usr/bin/env bash
# Regression tests for notify-anchor-transition.sh — the DETECTION/ALERT-ONLY
# driver for watch-anchor-events.sh under Mac-only signing. Verifies it fires
# notify on transitions, NEVER invokes a signer/broadcast/proton, writes no
# pending marker, and returns watcher-friendly exit codes. Uses a stub notify.sh
# so no real ntfy call happens. Exit 0 all PASS; exit 1 on first FAIL.
#
# FY_LIVE=1 is set on EVERY case, including the ones that assert notify was
# NOT called. Since the C3 rollout (2026-08-06) a dry FY_LIVE suppresses the
# send by itself, so a "no notify happened" assertion made without the opt-in
# would pass for the wrong reason — it would be measuring the library's gate
# instead of this driver's own event-type / --dry-run logic, which is what
# these cases exist to check. The dry side is covered separately by
# tests/side-effects-callers/test-anchor-cycle-side-effects.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER="${ROOT}/scripts/notify-anchor-transition.sh"
TMP="$(mktemp -d -t notify-anchor-transition.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# Stub notify.sh: records "PRIO|TITLE|MSG" to $NOTIFY_LOG so we can assert on it.
STUB="${TMP}/stub-notify.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "${*:3}" >> "${NOTIFY_LOG}"
EOF
chmod +x "$STUB"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Case 1: cyclestart → notify called (high, Mac guidance), exit 0
NOTIFY_LOG="${TMP}/n1.log"; : > "$NOTIFY_LOG"; rc=0
FY_LIVE=1 ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=cyclestart || rc=$?
[ "$rc" -eq 0 ] || fail "cyclestart exit=$rc (want 0)"
[ -s "$NOTIFY_LOG" ] || fail "cyclestart did not call notify"
grep -qi 'high' "$NOTIFY_LOG" || fail "cyclestart priority not high"
grep -qi 'mac'  "$NOTIFY_LOG" || fail "cyclestart msg missing Mac guidance"
pass "cyclestart notifies (high, Mac guidance), exit 0"

# Case 2: cycleend → notify called, exit 0
NOTIFY_LOG="${TMP}/n2.log"; : > "$NOTIFY_LOG"; rc=0
FY_LIVE=1 ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=cycleend || rc=$?
[ "$rc" -eq 0 ] || fail "cycleend exit=$rc (want 0)"
[ -s "$NOTIFY_LOG" ] || fail "cycleend did not call notify"
pass "cycleend notifies, exit 0"

# Case 3: no event-type → exit 2, notify NOT called
NOTIFY_LOG="${TMP}/n3.log"; : > "$NOTIFY_LOG"; rc=0
FY_LIVE=1 ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" || rc=$?
[ "$rc" -eq 2 ] || fail "empty event-type exit=$rc (want 2)"
[ ! -s "$NOTIFY_LOG" ] || fail "empty event-type should not notify"
pass "no event-type → exit 2, no notify"

# Case 4: unknown event-type → exit 2, no notify
NOTIFY_LOG="${TMP}/n4.log"; : > "$NOTIFY_LOG"; rc=0
FY_LIVE=1 ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=bogus || rc=$?
[ "$rc" -eq 2 ] || fail "unknown event-type exit=$rc (want 2)"
[ ! -s "$NOTIFY_LOG" ] || fail "unknown event-type should not notify"
pass "unknown event-type → exit 2, no notify"

# Case 5: --dry-run → exit 0, notify NOT actually called (prints intent)
NOTIFY_LOG="${TMP}/n5.log"; : > "$NOTIFY_LOG"; rc=0
out=$(FY_LIVE=1 ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=cyclestart --dry-run) || rc=$?
[ "$rc" -eq 0 ] || fail "dry-run exit=$rc (want 0)"
[ ! -s "$NOTIFY_LOG" ] || fail "dry-run should not actually notify"
echo "$out" | grep -qi 'DRY-RUN' || fail "dry-run should print intent"
pass "--dry-run → prints intent, no real notify, exit 0"

# Case 6: STATIC — alert-only invariant. Check the CODE (comment lines stripped, so
# the header's explanatory mentions of the legacy signer don't false-positive) for
# any actual signer/broadcast/proton/pending invocation.
CODE="$(grep -vE '^[[:space:]]*#' "$DRIVER")"
for forbidden in 'sign-anchor-event' 'safe-broadcast' 'transaction:push' 'anchor-pending'; do
	if printf '%s\n' "$CODE" | grep -qE "$forbidden"; then fail "driver code invokes forbidden '$forbidden' (must be alert-only)"; fi
done
if printf '%s\n' "$CODE" | grep -qE '(^|[^a-zA-Z.-])proton[[:space:]]+(action|transaction|chain:set|key:)'; then
	fail "driver code invokes a proton subcommand (must be alert-only)"
fi
pass "driver code invokes no signer/broadcast/proton/pending (alert-only)"

# Case 7: tolerate --cycle-n (watcher/legacy-arg compat), still notifies
NOTIFY_LOG="${TMP}/n7.log"; : > "$NOTIFY_LOG"; rc=0
FY_LIVE=1 ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=cyclestart --cycle-n=4 || rc=$?
[ "$rc" -eq 0 ] || fail "--cycle-n tolerated exit=$rc (want 0)"
[ -s "$NOTIFY_LOG" ] || fail "--cycle-n case did not notify"
pass "tolerates --cycle-n, still notifies"

# Case 8 (R5): notify.sh strict-mode failure that is NOT retryable (e.g. HTTP
# 4xx non-429) → exactly 1 call, driver exits 5 so the watcher can withhold
# its state advance instead of treating this as a confirmed dispatch.
NOTIFY_LOG="${TMP}/n8.log"; : > "$NOTIFY_LOG"; STUB8="${TMP}/stub8.sh"; rc=0
cat > "$STUB8" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\${*:3}" >> "${NOTIFY_LOG}"
exit 3
EOF
chmod +x "$STUB8"
FY_LIVE=1 ANCHOR_NOTIFY="$STUB8" NOTIFY_RETRY_SLEEP=0 bash "$DRIVER" --event-type=cyclestart || rc=$?
[ "$rc" -eq 5 ] || fail "non-retryable notify failure exit=$rc (want 5)"
[ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" -eq 1 ] || fail "non-retryable notify failure should attempt exactly once (log: $(cat "$NOTIFY_LOG"))"
pass "notify.sh non-retryable failure → driver exit 5, no retry"

# Case 9 (R5): notify.sh strict-mode failure that IS retryable (transport /
# 429 / 5xx) but never succeeds → 1 initial + 1 retry = 2 calls, exit 5.
NOTIFY_LOG="${TMP}/n9.log"; : > "$NOTIFY_LOG"; STUB9="${TMP}/stub9.sh"; rc=0
cat > "$STUB9" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\${*:3}" >> "${NOTIFY_LOG}"
exit 5
EOF
chmod +x "$STUB9"
FY_LIVE=1 ANCHOR_NOTIFY="$STUB9" NOTIFY_RETRY_SLEEP=0 bash "$DRIVER" --event-type=cycleend || rc=$?
[ "$rc" -eq 5 ] || fail "retryable-but-permanent notify failure exit=$rc (want 5)"
[ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" -eq 2 ] || fail "retryable notify failure should attempt twice (log: $(cat "$NOTIFY_LOG"))"
pass "notify.sh retryable failure (never succeeds) → 1 retry, driver exit 5"

# Case 10 (R5): notify.sh fails once (retryable) then succeeds on retry →
# 2 calls, driver exit 0 (= confirmed delivery within this invocation).
NOTIFY_LOG="${TMP}/n10.log"; : > "$NOTIFY_LOG"; STUB10="${TMP}/stub10.sh"; CTR10="${TMP}/ctr10"; rc=0
rm -f "$CTR10"
cat > "$STUB10" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\${*:3}" >> "${NOTIFY_LOG}"
n=0
[ -f "${CTR10}" ] && n=\$(cat "${CTR10}")
n=\$((n + 1))
echo "\$n" > "${CTR10}"
if [ "\$n" -eq 1 ]; then exit 5; else exit 0; fi
EOF
chmod +x "$STUB10"
FY_LIVE=1 ANCHOR_NOTIFY="$STUB10" NOTIFY_RETRY_SLEEP=0 bash "$DRIVER" --event-type=cyclestart || rc=$?
[ "$rc" -eq 0 ] || fail "flaky-then-success notify exit=$rc (want 0)"
[ "$(cat "$CTR10")" -eq 2 ] || fail "flaky-then-success notify should attempt twice (ctr: $(cat "$CTR10"))"
pass "notify.sh fails once then succeeds on retry → driver exit 0 (confirmed within this run)"

echo "ALL PASS (notify-anchor-transition)"
exit 0
