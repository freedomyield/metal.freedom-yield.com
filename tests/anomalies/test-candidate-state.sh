#!/usr/bin/env bash
# tests/anomalies/test-candidate-state.sh
#
# Unit tests for K-3 candidate-state model + GLOBAL_RC priority helper +
# notify retry classification + commit-skip behaviour.
#
# Strategy: extract the K-3 helpers from check-anomalies.sh into a sourcable
# file, then exercise each one in this test's own subshell (= no nested
# `bash -c` so $TMP / $NOTIFY / etc. propagate correctly).
#
# Hard constraints:
#   - No production state, lock, counter, marker, or quarantine file is read
#     or written. Everything lives under a per-test mktemp dir.
#   - No real ntfy.sh transport. Stub scripts on disk return controllable
#     exit codes.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export TMP

PASS=0
FAIL=0
FAILURES=()

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

mkdir -p "$TMP/state" "$TMP/bin"
export STATE_DIR="$TMP/state"
export STATE_FILE="$STATE_DIR/anomaly-state.json"

# Baseline state.
cat > "$STATE_FILE" <<'EOF'
{
  "metalgo": "running",
  "caddy": "running",
  "disk": "ok",
  "memory": "ok",
  "peers": "ok",
  "web": "ok",
  "api_freshness": "ok",
  "validator_present": "yes",
  "last_known_end_time": null,
  "delegator_count": null,
  "delegator_total_nmetal": null,
  "period_alert_sent": { "7": false, "1": false, "0": false, "10min": false }
}
EOF

# === K-3 helpers (verbatim copy from scripts/check-anomalies.sh) ===
cat > "$TMP/k3-helpers.sh" <<'BASH'
GLOBAL_RC=0
rc_priority_set() {
  local new="$1"
  case "$new" in
    8) GLOBAL_RC=8 ;;
    7) [ "$GLOBAL_RC" -lt 7 ] && GLOBAL_RC=7 ;;
    6) [ "$GLOBAL_RC" -lt 6 ] && GLOBAL_RC=6 ;;
    5) [ "$GLOBAL_RC" -lt 5 ] && GLOBAL_RC=5 ;;
    4) [ "$GLOBAL_RC" -lt 4 ] && GLOBAL_RC=4 ;;
    3) [ "$GLOBAL_RC" -lt 3 ] && GLOBAL_RC=3 ;;
    2) [ "$GLOBAL_RC" -lt 2 ] && GLOBAL_RC=2 ;;
    0) : ;;
    *) [ "$GLOBAL_RC" -lt "$new" ] && GLOBAL_RC="$new" ;;
  esac
}

orig_get() { jq -r "$1" "$ORIGINAL_STATE" 2>/dev/null; }
candidate_set() {
  local path="$1" val="$2"
  local tmp="${CANDIDATE_STATE}.swp"
  if ! jq "$path = $val" "$CANDIDATE_STATE" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    rc_priority_set 8
    return 1
  fi
  if ! mv "$tmp" "$CANDIDATE_STATE" 2>/dev/null; then
    rm -f "$tmp"
    rc_priority_set 8
    return 1
  fi
  return 0
}

attempt_notify() {
  local prio="$1" title="$2" body="$3"
  if [ ! -x "$NOTIFY" ]; then
    return 100
  fi
  NOTIFY_STRICT_EXIT=1 bash "$NOTIFY" "$prio" "$title" "$body" >/dev/null 2>&1
  return $?
}

retryable_notify_rc() {
  case "$1" in
    2|4|5) return 0 ;;
    *) return 1 ;;
  esac
}

notify_or_keep() {
  local prio="$1" title="$2" body="$3" rc
  attempt_notify "$prio" "$title" "$body"; rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if retryable_notify_rc "$rc"; then
    sleep 0   # 0 in tests; 5 in production
    attempt_notify "$prio" "$title" "$body"; rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
  fi
  rc_priority_set 6
  return "$rc"
}

bootstrap_candidate() {
  ORIGINAL_STATE=$(mktemp -p "$STATE_DIR" .original.XXXXXX)
  CANDIDATE_STATE=$(mktemp -p "$STATE_DIR" .candidate.XXXXXX)
  cp "$STATE_FILE" "$ORIGINAL_STATE"
  cp "$ORIGINAL_STATE" "$CANDIDATE_STATE"
}

cleanup_k3_tmp() {
  rm -f "$ORIGINAL_STATE" "$CANDIDATE_STATE" "${CANDIDATE_STATE}.swp" 2>/dev/null || true
}
BASH

# Stub notify factories — each returns the configured exit code.
make_stub() {
  local name="$1" body="$2"
  cat > "$TMP/bin/$name" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$TMP/bin/$name"
}

make_stub stub-ok.sh    'exit 0'
make_stub stub-1.sh     'exit 1'    # topic missing/empty
make_stub stub-2.sh     'exit 2'    # transport
make_stub stub-3.sh     'exit 3'    # 4xx
make_stub stub-4.sh     'exit 4'    # 429
make_stub stub-5.sh     'exit 5'    # 5xx
# Counter-aware stubs.
make_stub stub-flaky-5then0.sh '
n=0
[ -f "$STUB_CTR" ] && n=$(cat "$STUB_CTR")
n=$((n + 1))
echo "$n" > "$STUB_CTR"
if [ "$n" -eq 1 ]; then exit 5; else exit 0; fi
'
make_stub stub-flaky-4then0.sh '
n=0
[ -f "$STUB_CTR" ] && n=$(cat "$STUB_CTR")
n=$((n + 1))
echo "$n" > "$STUB_CTR"
if [ "$n" -eq 1 ]; then exit 4; else exit 0; fi
'
make_stub stub-flaky-2then0.sh '
n=0
[ -f "$STUB_CTR" ] && n=$(cat "$STUB_CTR")
n=$((n + 1))
echo "$n" > "$STUB_CTR"
if [ "$n" -eq 1 ]; then exit 2; else exit 0; fi
'
make_stub stub-count.sh '
n=0
[ -f "$STUB_CTR" ] && n=$(cat "$STUB_CTR")
n=$((n + 1))
echo "$n" > "$STUB_CTR"
case "$n" in
  1) exit 0 ;;
  2) exit 3 ;;
  3) exit 0 ;;
esac
exit 0
'

# Per-test helper that runs a block in a subshell. Each test gets a clean
# bootstrap_candidate so GLOBAL_RC / candidate / original are fresh.
run_isolated() {
  # $1 = the test body. All env (TMP, STATE_DIR, STATE_FILE, NOTIFY, STUB_CTR)
  # propagates because we're using a subshell (= no `bash -c`).
  ( source "$TMP/k3-helpers.sh"; bootstrap_candidate; "$@"; cleanup_k3_tmp )
}

echo "=== C4 GLOBAL_RC priority helper ==="

t1() { rc_priority_set 0; rc_priority_set 2; rc_priority_set 3; echo "RC=$GLOBAL_RC"; }
out=$(run_isolated t1)
assert_eq "rc_priority_set 0→2→3 yields GLOBAL_RC=3"           "RC=3" "$out"

t2() { rc_priority_set 6; rc_priority_set 3; echo "RC=$GLOBAL_RC"; }
out=$(run_isolated t2)
assert_eq "rc_priority_set 6→3 stays GLOBAL_RC=6 (no downgrade)" "RC=6" "$out"

t3() { rc_priority_set 6; rc_priority_set 7; rc_priority_set 8; rc_priority_set 2; echo "RC=$GLOBAL_RC"; }
out=$(run_isolated t3)
assert_eq "rc_priority_set 6→7→8→2 ends GLOBAL_RC=8"          "RC=8" "$out"

t4() { rc_priority_set 4; rc_priority_set 0; echo "RC=$GLOBAL_RC"; }
out=$(run_isolated t4)
assert_eq "rc_priority_set 4→0 keeps GLOBAL_RC=4"               "RC=4" "$out"

echo ""
echo "=== C4 retryable_notify_rc classification ==="

test_retry() {
  for code in 0 1 2 3 4 5 100; do
    if retryable_notify_rc "$code"; then
      echo "$code retryable"
    else
      echo "$code not-retryable"
    fi
  done
}
retry_out=$(run_isolated test_retry)
expected_lines="0 not-retryable
1 not-retryable
2 retryable
3 not-retryable
4 retryable
5 retryable
100 not-retryable"
idx=0
while IFS= read -r expected_line; do
  idx=$((idx + 1))
  actual_line=$(echo "$retry_out" | sed -n "${idx}p")
  code=$(echo "$expected_line" | awk '{print $1}')
  assert_eq "retryable_notify_rc[$code]" "$expected_line" "$actual_line"
done <<<"$expected_lines"

echo ""
echo "=== C4 candidate-state transition gating ==="

# === notify success → candidate advances ===
test_notify_success() {
  export NOTIFY="$TMP/bin/stub-ok.sh"
  if notify_or_keep urgent "test" "body"; then
    candidate_set '.metalgo' '"stopped"'
  fi
  echo "metalgo=$(jq -r '.metalgo' "$CANDIDATE_STATE")"
  echo "RC=$GLOBAL_RC"
}
out=$(NOTIFY="$TMP/bin/stub-ok.sh" run_isolated test_notify_success)
assert_eq "notify success → candidate.metalgo = stopped"  "metalgo=stopped" "$(echo "$out" | sed -n '1p')"
assert_eq "notify success → GLOBAL_RC = 0"                "RC=0"            "$(echo "$out" | sed -n '2p')"

# === HTTP 5xx → retry → success → candidate advances ===
test_5xx_retry_success() {
  export STUB_CTR="$TMP/ctr-5xx"
  rm -f "$STUB_CTR"
  export NOTIFY="$TMP/bin/stub-flaky-5then0.sh"
  if notify_or_keep high "test" "body"; then
    candidate_set '.caddy' '"stopped"'
  fi
  echo "caddy=$(jq -r '.caddy' "$CANDIDATE_STATE")"
  echo "RC=$GLOBAL_RC"
  echo "TRIES=$(cat "$STUB_CTR")"
}
out=$(run_isolated test_5xx_retry_success)
assert_eq "5xx + retry success → candidate.caddy = stopped"  "caddy=stopped" "$(echo "$out" | sed -n '1p')"
assert_eq "5xx + retry success → GLOBAL_RC = 0"              "RC=0"          "$(echo "$out" | sed -n '2p')"
assert_eq "5xx + retry success → 2 attempts (1 initial + 1 retry)" "TRIES=2" "$(echo "$out" | sed -n '3p')"

# === HTTP 429 → retry → success ===
test_429_retry_success() {
  export STUB_CTR="$TMP/ctr-429"
  rm -f "$STUB_CTR"
  export NOTIFY="$TMP/bin/stub-flaky-4then0.sh"
  if notify_or_keep high "test" "body"; then
    candidate_set '.peers' '"warn"'
  fi
  echo "peers=$(jq -r '.peers' "$CANDIDATE_STATE")"
  echo "RC=$GLOBAL_RC"
  echo "TRIES=$(cat "$STUB_CTR")"
}
out=$(run_isolated test_429_retry_success)
assert_eq "429 + retry success → candidate.peers = warn"     "peers=warn" "$(echo "$out" | sed -n '1p')"
assert_eq "429 + retry success → GLOBAL_RC = 0"              "RC=0"       "$(echo "$out" | sed -n '2p')"
assert_eq "429 + retry success → 2 attempts"                 "TRIES=2"    "$(echo "$out" | sed -n '3p')"

# === transport (rc=2) → retry → success ===
test_transport_retry_success() {
  export STUB_CTR="$TMP/ctr-tx"
  rm -f "$STUB_CTR"
  export NOTIFY="$TMP/bin/stub-flaky-2then0.sh"
  if notify_or_keep high "test" "body"; then
    candidate_set '.memory' '"warn"'
  fi
  echo "memory=$(jq -r '.memory' "$CANDIDATE_STATE")"
  echo "RC=$GLOBAL_RC"
  echo "TRIES=$(cat "$STUB_CTR")"
}
out=$(run_isolated test_transport_retry_success)
assert_eq "transport (rc=2) + retry success → candidate.memory = warn"  "memory=warn" "$(echo "$out" | sed -n '1p')"
assert_eq "transport (rc=2) + retry success → GLOBAL_RC = 0"            "RC=0"        "$(echo "$out" | sed -n '2p')"
assert_eq "transport (rc=2) + retry success → 2 attempts"               "TRIES=2"     "$(echo "$out" | sed -n '3p')"

# === HTTP 4xx (non-429) → no retry → candidate unchanged ===
test_4xx_no_retry() {
  export STUB_CTR="$TMP/ctr-4xx"
  rm -f "$STUB_CTR"
  # Wrap stub-3.sh in a counter wrapper.
  cat > "$TMP/bin/stub-3-counted.sh" <<EOF
#!/usr/bin/env bash
n=0
[ -f "\$STUB_CTR" ] && n=\$(cat "\$STUB_CTR")
echo \$((n + 1)) > "\$STUB_CTR"
exit 3
EOF
  chmod +x "$TMP/bin/stub-3-counted.sh"
  export NOTIFY="$TMP/bin/stub-3-counted.sh"
  if notify_or_keep high "test" "body"; then
    candidate_set '.disk' '"warn"'
  fi
  echo "disk=$(jq -r '.disk' "$CANDIDATE_STATE")"
  echo "RC=$GLOBAL_RC"
  echo "TRIES=$(cat "$STUB_CTR")"
}
out=$(run_isolated test_4xx_no_retry)
assert_eq "4xx (non-429) → candidate.disk unchanged (= ok)"  "disk=ok" "$(echo "$out" | sed -n '1p')"
assert_eq "4xx (non-429) → GLOBAL_RC = 6"                    "RC=6"    "$(echo "$out" | sed -n '2p')"
assert_eq "4xx (non-429) → 1 attempt (no retry)"             "TRIES=1" "$(echo "$out" | sed -n '3p')"

# === topic missing (rc=1) → no retry, GLOBAL_RC=6 ===
test_topic_missing() {
  export STUB_CTR="$TMP/ctr-1"
  rm -f "$STUB_CTR"
  cat > "$TMP/bin/stub-1-counted.sh" <<EOF
#!/usr/bin/env bash
n=0
[ -f "\$STUB_CTR" ] && n=\$(cat "\$STUB_CTR")
echo \$((n + 1)) > "\$STUB_CTR"
exit 1
EOF
  chmod +x "$TMP/bin/stub-1-counted.sh"
  export NOTIFY="$TMP/bin/stub-1-counted.sh"
  if notify_or_keep high "test" "body"; then
    candidate_set '.peers' '"warn"'
  fi
  echo "peers=$(jq -r '.peers' "$CANDIDATE_STATE")"
  echo "RC=$GLOBAL_RC"
  echo "TRIES=$(cat "$STUB_CTR")"
}
out=$(run_isolated test_topic_missing)
assert_eq "topic missing (rc=1) → candidate.peers unchanged"  "peers=ok" "$(echo "$out" | sed -n '1p')"
assert_eq "topic missing (rc=1) → GLOBAL_RC = 6"              "RC=6"     "$(echo "$out" | sed -n '2p')"
assert_eq "topic missing (rc=1) → 1 attempt (no retry)"       "TRIES=1"  "$(echo "$out" | sed -n '3p')"

# === NOTIFY missing → rc=100 → no retry, GLOBAL_RC=6 ===
test_notify_missing() {
  export NOTIFY="/nonexistent/path"
  if notify_or_keep high "test" "body"; then
    candidate_set '.metalgo' '"stopped"'
  fi
  echo "metalgo=$(jq -r '.metalgo' "$CANDIDATE_STATE")"
  echo "RC=$GLOBAL_RC"
}
out=$(run_isolated test_notify_missing)
assert_eq "NOTIFY missing → candidate unchanged (= running)"   "metalgo=running" "$(echo "$out" | sed -n '1p')"
assert_eq "NOTIFY missing → GLOBAL_RC = 6"                     "RC=6"            "$(echo "$out" | sed -n '2p')"

echo ""
echo "=== C4 commit-skip behaviour (candidate == original canonical) ==="

# === no transitions → canonical equal ===
test_no_change() {
  ORIG=$(jq -S . "$ORIGINAL_STATE")
  CAND=$(jq -S . "$CANDIDATE_STATE")
  [ "$ORIG" = "$CAND" ] && echo EQUAL || echo DIFFER
}
out=$(run_isolated test_no_change)
assert_eq "no transitions → canonical equal → commit skipped"  "EQUAL" "$out"

# === candidate_set same value → canonical still equal ===
test_same_value() {
  candidate_set '.metalgo' '"running"'
  ORIG=$(jq -S . "$ORIGINAL_STATE")
  CAND=$(jq -S . "$CANDIDATE_STATE")
  [ "$ORIG" = "$CAND" ] && echo EQUAL || echo DIFFER
}
out=$(run_isolated test_same_value)
assert_eq "candidate_set same value → canonical still equal (mtime preserved)" "EQUAL" "$out"

# === candidate_set new value → canonical differs ===
test_real_change() {
  candidate_set '.metalgo' '"stopped"'
  ORIG=$(jq -S . "$ORIGINAL_STATE")
  CAND=$(jq -S . "$CANDIDATE_STATE")
  [ "$ORIG" = "$CAND" ] && echo EQUAL || echo DIFFER
}
out=$(run_isolated test_real_change)
assert_eq "candidate_set new value → canonical differs (commit fires)" "DIFFER" "$out"

# === key-reordered same content → canonical equal (= jq -S sorts) ===
test_reorder_no_diff() {
  # Manually rewrite candidate with reordered keys but same content.
  cat > "$CANDIDATE_STATE" <<'EOF'
{
  "validator_present": "yes",
  "metalgo": "running",
  "caddy": "running",
  "disk": "ok",
  "memory": "ok",
  "peers": "ok",
  "web": "ok",
  "api_freshness": "ok",
  "last_known_end_time": null,
  "delegator_count": null,
  "delegator_total_nmetal": null,
  "period_alert_sent": { "0": false, "1": false, "10min": false, "7": false }
}
EOF
  ORIG=$(jq -S . "$ORIGINAL_STATE")
  CAND=$(jq -S . "$CANDIDATE_STATE")
  [ "$ORIG" = "$CAND" ] && echo EQUAL || echo DIFFER
}
out=$(run_isolated test_reorder_no_diff)
assert_eq "key-reordered same content → canonical equal"  "EQUAL" "$out"

echo ""
echo "=== C4 multi-transition independence ==="

test_multi() {
  export STUB_CTR="$TMP/ctr-multi"
  rm -f "$STUB_CTR"
  export NOTIFY="$TMP/bin/stub-count.sh"
  # call 1: rc=0 → metalgo advances
  if notify_or_keep urgent "metalgo" "b"; then candidate_set '.metalgo' '"stopped"'; fi
  # call 2: rc=3 → caddy stays
  if notify_or_keep high "caddy" "b"; then candidate_set '.caddy' '"stopped"'; fi
  # call 3: rc=0 → disk advances
  if notify_or_keep high "disk" "b"; then candidate_set '.disk' '"warn"'; fi
  echo "metalgo=$(jq -r '.metalgo' "$CANDIDATE_STATE")"
  echo "caddy=$(jq -r '.caddy' "$CANDIDATE_STATE")"
  echo "disk=$(jq -r '.disk' "$CANDIDATE_STATE")"
  echo "RC=$GLOBAL_RC"
  echo "TRIES=$(cat "$STUB_CTR")"
}
out=$(run_isolated test_multi)
assert_eq "multi: 1st (metalgo) success → candidate=stopped"     "metalgo=stopped" "$(echo "$out" | sed -n '1p')"
assert_eq "multi: 2nd (caddy 4xx fail) → candidate unchanged"    "caddy=running"   "$(echo "$out" | sed -n '2p')"
assert_eq "multi: 3rd (disk) success → candidate=warn"           "disk=warn"       "$(echo "$out" | sed -n '3p')"
assert_eq "multi: GLOBAL_RC = 6 (from caddy permanent fail)"     "RC=6"            "$(echo "$out" | sed -n '4p')"
assert_eq "multi: total 3 attempts (no retry on 4xx)"            "TRIES=3"         "$(echo "$out" | sed -n '5p')"

echo ""
echo "=== C4 ORIGINAL_STATE immutability + STATE_FILE not touched ==="

test_orig_immutable() {
  ORIG_BEFORE=$(sha256sum "$ORIGINAL_STATE" | awk '{print $1}')
  candidate_set '.metalgo' '"stopped"'
  candidate_set '.disk' '"warn"'
  candidate_set '.delegator_count' '5'
  ORIG_AFTER=$(sha256sum "$ORIGINAL_STATE" | awk '{print $1}')
  [ "$ORIG_BEFORE" = "$ORIG_AFTER" ] && echo IMMUTABLE || echo MUTATED
}
out=$(run_isolated test_orig_immutable)
assert_eq "ORIGINAL_STATE bytes unchanged after 3 candidate_set" "IMMUTABLE" "$out"

test_state_untouched() {
  STATE_BEFORE=$(sha256sum "$STATE_FILE" | awk '{print $1}')
  candidate_set '.metalgo' '"stopped"'
  candidate_set '.disk' '"warn"'
  STATE_AFTER=$(sha256sum "$STATE_FILE" | awk '{print $1}')
  [ "$STATE_BEFORE" = "$STATE_AFTER" ] && echo UNTOUCHED || echo TOUCHED
}
out=$(run_isolated test_state_untouched)
assert_eq "STATE_FILE bytes unchanged during transition processing" "UNTOUCHED" "$out"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
