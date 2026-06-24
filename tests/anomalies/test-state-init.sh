#!/usr/bin/env bash
# tests/anomalies/test-state-init.sh
#
# Unit tests for scripts/anomaly-state-init.sh covering operator-side
# guarantees: argument validation, lock acquisition failure paths, marker
# deletion ordering invariant, permission and symlink handling, optional
# clear actions.
#
# Tests that require a working `flock` (= the lock-held / lock-acquired
# happy path) are guarded with `is_linux` and printed as SKIP on macOS.
# Full success-path verification runs in the C6 Linux integration suite.
#
# Hard constraints:
#   - No production state, lock, counter, marker, or quarantine file is
#     read or written.
#   - All paths live under a per-test mktemp dir.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
INIT="$REPO/scripts/anomaly-state-init.sh"

TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0
FAILURES=()

is_linux() { [ "$(uname)" = "Linux" ]; }

assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %-60s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$label (expected=$expected, actual=$actual)")
    printf '  FAIL  %-60s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %-60s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$label (expected='$expected', actual='$actual')")
    printf '  FAIL  %-60s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  fi
}

skip() {
  SKIP=$((SKIP + 1))
  printf '  SKIP  %-60s (requires Linux flock)\n' "$1"
}

# new_env <name> — set up a per-case mktemp env, return paths via globals.
new_env() {
  local name="$1"
  CASE_DIR=$(mktemp -d -p "$TMP" "case-${name}.XXXX")
  STATE_DIR="$CASE_DIR/state"
  LOCK_DIR="$CASE_DIR/locks"
  COUNTER="$CASE_DIR/counter"
  STATE_FILE="$STATE_DIR/anomaly-state.json"
  MARKER="$STATE_DIR/.missing-notified.marker"
  LOCK_FILE="$LOCK_DIR/check-anomalies.lock"
  mkdir -p "$STATE_DIR" "$LOCK_DIR"
}

run_init() {
  # Caller sets STATE_DIR / LOCK_FILE / COUNTER. Pass args after env.
  ANOMALY_STATE_DIR="$STATE_DIR" \
  ANOMALY_LOCK_FILE="$LOCK_FILE" \
  ANOMALY_CONTENTION_COUNTER="$COUNTER" \
  bash "$INIT" "$@" 2>"$CASE_DIR/stderr" >"$CASE_DIR/stdout"
  echo $?
}

echo "=== C5-A argument validation (run-anywhere, no flock dependency) ==="

# === T1: --confirm absent → exit 1, no state written ====================
new_env t1
rc=$(run_init --baseline-status=running)
assert_rc "T1: --confirm absent → exit 1"                              1 "$rc"
[ -f "$STATE_FILE" ] && state_exists=yes || state_exists=no
assert_eq "T1: state file NOT written (= no mutation without --confirm)" "no" "$state_exists"

# === T2: --baseline-status missing → exit 1 =============================
new_env t2
rc=$(run_init --confirm)
assert_rc "T2: --baseline-status missing → exit 1"                     1 "$rc"
[ -f "$STATE_FILE" ] && state_exists=yes || state_exists=no
assert_eq "T2: state file NOT written"                                  "no" "$state_exists"

# === T3: invalid --baseline-status value → exit 1 =======================
new_env t3
rc=$(run_init --confirm --baseline-status=unknown)
assert_rc "T3: invalid --baseline-status=unknown → exit 1"             1 "$rc"
[ -f "$STATE_FILE" ] && state_exists=yes || state_exists=no
assert_eq "T3: state file NOT written"                                  "no" "$state_exists"

# === T4: unknown option → exit 1 ========================================
new_env t4
rc=$(run_init --confirm --baseline-status=running --gimme-cookies)
assert_rc "T4: unknown option --gimme-cookies → exit 1"                1 "$rc"
[ -f "$STATE_FILE" ] && state_exists=yes || state_exists=no
assert_eq "T4: state file NOT written"                                  "no" "$state_exists"

# === T5: lock dir missing → exit 2 ======================================
new_env t5
rm -rf "$LOCK_DIR"   # parent of LOCK_FILE no longer exists
rc=$(run_init --confirm --baseline-status=running)
assert_rc "T5: lock dir missing → exit 2"                              2 "$rc"
[ -f "$STATE_FILE" ] && state_exists=yes || state_exists=no
assert_eq "T5: state file NOT written"                                  "no" "$state_exists"

# === T6: bad lock dir permission (cannot open file for write) → exit 2 ==
# On macOS chmod 0500 on dir still allows root to traverse; sub-tests run
# as the operator user. We use a missing parent to force the open failure.
new_env t6
chmod 0500 "$LOCK_DIR"
rc=$(run_init --confirm --baseline-status=running)
chmod 0700 "$LOCK_DIR"   # restore so cleanup works
# Expectation: exit 2 (file cannot be opened for write). On macOS/Linux
# both, "exec 9>file" in a non-writable dir fails.
assert_rc "T6: lock dir non-writable → exit 2 (open failure)"          2 "$rc"

# === T7: state dir non-writable for mktemp → mismatch path =============
# Force mktemp inside STATE_DIR to fail by making STATE_DIR read-only AFTER
# the script's own mkdir -p succeeds. This requires that flock returns ok,
# so it's Linux-only.
if is_linux; then
  new_env t7
  chmod 0500 "$STATE_DIR"
  rc=$(run_init --confirm --baseline-status=running)
  chmod 0700 "$STATE_DIR"
  assert_rc "T7: state dir non-writable → exit 4 (mktemp/state write fail)" 4 "$rc"
else
  skip "T7: state dir non-writable → exit 4"
fi

echo ""
echo "=== C5-A marker deletion ordering invariant ==="

# === T8: marker deletion happens AFTER successful state write ===========
# Invariant: missing-marker MUST NOT be removed if state write failed.
# Simulate state write failure (= non-writable STATE_DIR) with marker
# pre-placed. After failed init, marker must still be present.
if is_linux; then
  new_env t8
  : > "$MARKER"   # pre-place marker
  chmod 0500 "$STATE_DIR"
  rc=$(run_init --confirm --baseline-status=running)
  chmod 0700 "$STATE_DIR"
  assert_rc "T8: state write fail → exit 4"                            4 "$rc"
  [ -f "$MARKER" ] && marker_state=present || marker_state=removed
  assert_eq "T8: state write fail → marker MUST STILL BE PRESENT (invariant)" "present" "$marker_state"
else
  skip "T8: marker NOT removed when state write fails"
fi

# === T9: marker removed only after state write succeeds =================
if is_linux; then
  new_env t9
  : > "$MARKER"
  rc=$(run_init --confirm --baseline-status=running)
  assert_rc "T9: success → exit 0"                                     0 "$rc"
  [ -f "$STATE_FILE" ] && state_written=yes || state_written=no
  [ -f "$MARKER" ] && marker_state=present || marker_state=removed
  assert_eq "T9: success → state file written"                          "yes" "$state_written"
  assert_eq "T9: success → marker removed (= unblocks future re-notify)" "removed" "$marker_state"
else
  skip "T9: marker removed only after state write success"
fi

echo ""
echo "=== C5-A symlink handling ==="

# === T10: STATE_FILE is a symlink → mv replaces symlink, target untouched
if is_linux; then
  new_env t10
  TARGET="$CASE_DIR/symlink-target"
  echo 'original-target-content' > "$TARGET"
  TARGET_HASH_BEFORE=$(sha256sum "$TARGET" | awk '{print $1}')
  ln -s "$TARGET" "$STATE_FILE"
  rc=$(run_init --confirm --baseline-status=running)
  assert_rc "T10: symlink + init → exit 0"                             0 "$rc"
  # After mv, STATE_FILE should be a regular file (= the symlink itself
  # was replaced, NOT followed).
  if [ -L "$STATE_FILE" ]; then state_type=symlink
  elif [ -f "$STATE_FILE" ]; then state_type=regular
  else state_type=missing
  fi
  assert_eq "T10: symlink replaced by regular file"                     "regular" "$state_type"
  TARGET_HASH_AFTER=$(sha256sum "$TARGET" | awk '{print $1}')
  assert_eq "T10: symlink target file bytes UNCHANGED (safety)"         "$TARGET_HASH_BEFORE" "$TARGET_HASH_AFTER"
else
  skip "T10: symlink replaced by regular file, target untouched"
fi

echo ""
echo "=== C5-A optional clear actions ==="

# === T11: --clear-quarantine removes existing quarantine dirs ===========
if is_linux; then
  new_env t11
  mkdir -p "$STATE_DIR/quarantine/abc123" "$STATE_DIR/quarantine/def456"
  : > "$STATE_DIR/quarantine/abc123/state.json"
  rc=$(run_init --confirm --baseline-status=running --clear-quarantine)
  assert_rc "T11: --clear-quarantine + init → exit 0"                  0 "$rc"
  rem_dirs=$(find "$STATE_DIR/quarantine" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "T11: quarantine dirs removed"                              "0" "$rem_dirs"
else
  skip "T11: --clear-quarantine removes existing dirs"
fi

# === T12: --clear-counter resets counter to 0 ===========================
if is_linux; then
  new_env t12
  echo '42' > "$COUNTER"
  rc=$(run_init --confirm --baseline-status=running --clear-counter)
  assert_rc "T12: --clear-counter + init → exit 0"                     0 "$rc"
  ctr_val=$(cat "$COUNTER" 2>/dev/null || echo missing)
  assert_eq "T12: counter reset to 0"                                   "0" "$ctr_val"
else
  skip "T12: --clear-counter resets to 0"
fi

# === T13: --clear-quarantine on non-existent dir → no error ============
if is_linux; then
  new_env t13
  # No quarantine dir created.
  rc=$(run_init --confirm --baseline-status=running --clear-quarantine)
  assert_rc "T13: --clear-quarantine on absent dir → still exit 0"     0 "$rc"
else
  skip "T13: --clear-quarantine on absent dir"
fi

# === T14: quarantine clear mid-failure → state still committed =========
# Simulate non-removable quarantine entry (= chmod 0500 on subdir means
# rm -rf inside it fails). State write must succeed first; warn logged
# but exit still 0 because state IS committed.
if is_linux; then
  new_env t14
  mkdir -p "$STATE_DIR/quarantine/keepme"
  : > "$STATE_DIR/quarantine/keepme/state.json"
  chmod 0500 "$STATE_DIR/quarantine/keepme"
  rc=$(run_init --confirm --baseline-status=running --clear-quarantine)
  chmod 0700 "$STATE_DIR/quarantine/keepme" 2>/dev/null
  # state SHOULD be committed regardless of quarantine clear outcome.
  [ -f "$STATE_FILE" ] && state_written=yes || state_written=no
  assert_eq "T14: state committed despite quarantine clear failure"    "yes" "$state_written"
  # Whether exit 0 or non-zero depends on whether the find -exec returns
  # non-zero. The script logs WARN and continues; final exit 0 expected.
  assert_rc "T14: exit 0 (state success, quarantine warn-only)"        0 "$rc"
else
  skip "T14: quarantine clear mid-failure → state still committed"
fi

echo ""
echo "=== C5-A lock-held path (Linux flock required) ==="

# === T15: lock held by another process → exit 3 =========================
if is_linux; then
  new_env t15
  # Acquire the lock in background and hold it for ~3s.
  ( flock -x 200; sleep 3 ) 200>"$LOCK_FILE" &
  HOLDER=$!
  sleep 0.3
  rc=$(run_init --confirm --baseline-status=running)
  wait $HOLDER 2>/dev/null
  assert_rc "T15: lock held by another process → exit 3"               3 "$rc"
  [ -f "$STATE_FILE" ] && state_written=yes || state_written=no
  assert_eq "T15: state NOT written when lock held"                     "no" "$state_written"
else
  skip "T15: lock held by another process → exit 3"
fi

echo ""
echo "=== C5-A lock file persists across runs (NEVER deleted) ==="

# === T16: lock file persists after successful init ======================
if is_linux; then
  new_env t16
  rc=$(run_init --confirm --baseline-status=running)
  assert_rc "T16: init success → exit 0"                               0 "$rc"
  [ -f "$LOCK_FILE" ] && lock_state=present || lock_state=removed
  assert_eq "T16: lock file PRESENT after init (= never deleted)"      "present" "$lock_state"
else
  skip "T16: lock file persists after init"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
