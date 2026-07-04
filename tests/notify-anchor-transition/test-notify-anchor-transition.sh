#!/usr/bin/env bash
# Regression tests for notify-anchor-transition.sh — the DETECTION/ALERT-ONLY
# driver for watch-anchor-events.sh under Mac-only signing. Verifies it fires
# notify on transitions, NEVER invokes a signer/broadcast/proton, writes no
# pending marker, and returns watcher-friendly exit codes. Uses a stub notify.sh
# so no real ntfy call happens. Exit 0 all PASS; exit 1 on first FAIL.
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
ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=cyclestart || rc=$?
[ "$rc" -eq 0 ] || fail "cyclestart exit=$rc (want 0)"
[ -s "$NOTIFY_LOG" ] || fail "cyclestart did not call notify"
grep -qi 'high' "$NOTIFY_LOG" || fail "cyclestart priority not high"
grep -qi 'mac'  "$NOTIFY_LOG" || fail "cyclestart msg missing Mac guidance"
pass "cyclestart notifies (high, Mac guidance), exit 0"

# Case 2: cycleend → notify called, exit 0
NOTIFY_LOG="${TMP}/n2.log"; : > "$NOTIFY_LOG"; rc=0
ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=cycleend || rc=$?
[ "$rc" -eq 0 ] || fail "cycleend exit=$rc (want 0)"
[ -s "$NOTIFY_LOG" ] || fail "cycleend did not call notify"
pass "cycleend notifies, exit 0"

# Case 3: no event-type → exit 2, notify NOT called
NOTIFY_LOG="${TMP}/n3.log"; : > "$NOTIFY_LOG"; rc=0
ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" || rc=$?
[ "$rc" -eq 2 ] || fail "empty event-type exit=$rc (want 2)"
[ ! -s "$NOTIFY_LOG" ] || fail "empty event-type should not notify"
pass "no event-type → exit 2, no notify"

# Case 4: unknown event-type → exit 2, no notify
NOTIFY_LOG="${TMP}/n4.log"; : > "$NOTIFY_LOG"; rc=0
ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=bogus || rc=$?
[ "$rc" -eq 2 ] || fail "unknown event-type exit=$rc (want 2)"
[ ! -s "$NOTIFY_LOG" ] || fail "unknown event-type should not notify"
pass "unknown event-type → exit 2, no notify"

# Case 5: --dry-run → exit 0, notify NOT actually called (prints intent)
NOTIFY_LOG="${TMP}/n5.log"; : > "$NOTIFY_LOG"; rc=0
out=$(ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=cyclestart --dry-run) || rc=$?
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
ANCHOR_NOTIFY="$STUB" NOTIFY_LOG="$NOTIFY_LOG" bash "$DRIVER" --event-type=cyclestart --cycle-n=4 || rc=$?
[ "$rc" -eq 0 ] || fail "--cycle-n tolerated exit=$rc (want 0)"
[ -s "$NOTIFY_LOG" ] || fail "--cycle-n case did not notify"
pass "tolerates --cycle-n, still notifies"

echo "ALL PASS (notify-anchor-transition)"
exit 0
