#!/usr/bin/env bash
# tests/notify/test-strict-exit-classification.sh
#
# Verifies scripts/notify.sh exit-code classification under NOTIFY_STRICT_EXIT=1.
#
# This test does NOT call the real ntfy.sh transport. It substitutes a stub
# `curl` on PATH that yields the desired HTTP status code or transport failure
# mode, then invokes notify.sh and asserts the resulting exit code matches the
# classification contract.
#
# Default-mode behaviour (= byte-identical to historical) is exercised by
# test-default-mode-byte-identical.sh in the same directory.
#
# Pre-conditions enforced by the test harness:
#   - No production state, lock, counter, marker, or quarantine file is read or
#     written. All paths live under a per-test mktemp dir.
#   - Production /etc/freedom-yield/ntfy-topic is NOT read. A throwaway topic
#     file is created in $TMP and pointed at via NTFY_TOPIC_FILE.
#   - Real ntfy.sh is NEVER contacted. The stub curl never connects.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
NOTIFY="$REPO/scripts/notify.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILURES=()

# Topic file under $TMP — production /etc/* is never read.
TOPIC_FILE="$TMP/topic"
echo "test-topic-string" > "$TOPIC_FILE"
export NTFY_TOPIC_FILE="$TOPIC_FILE"

# Make a fake validator.json so the uptime footer code path doesn't crash on
# the test env. Empty body is fine.
mkdir -p "$TMP/public/api"
echo '{}' > "$TMP/public/api/validator.json"

# === stub-curl factory ====================================================
# write_stub_curl <http_code> [<curl_exit>]
#   Writes a small shell script to $TMP/bin/curl that mimics curl just well
#   enough for notify.sh: it consumes all argv silently and prints the given
#   HTTP status to stdout (= what `-w "%{http_code}"` emits when the real
#   curl runs). curl_exit defaults to 0; pass 28 to simulate timeout, etc.
mkdir -p "$TMP/bin"
write_stub_curl() {
  local code="$1"
  local rc="${2:-0}"
  cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
# Stub curl for notify.sh tests. Ignores argv, prints status to stdout.
# Real curl writes %{http_code} via -w; notify.sh captures stdout as HTTP_CODE.
printf '%s' "${code}"
exit ${rc}
EOF
  chmod +x "$TMP/bin/curl"
}

run_strict() {
  # Run notify.sh in strict mode with the stub curl on PATH. Hide stdout to
  # keep test output readable; rely on exit code only.
  PATH="$TMP/bin:$PATH" \
  NOTIFY_STRICT_EXIT=1 \
  NTFY_TOPIC_FILE="$TOPIC_FILE" \
  bash "$NOTIFY" default "title" "body" >/dev/null 2>&1
  return $?
}

assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %-50s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$label (expected=$expected, actual=$actual)")
    printf '  FAIL  %-50s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  fi
}

echo "=== C3b strict-mode exit-code classification ==="

# === HTTP 2xx → exit 0 ====================================================
write_stub_curl 200 0; run_strict; assert_rc "HTTP 200"               0 $?
write_stub_curl 201 0; run_strict; assert_rc "HTTP 201"               0 $?
write_stub_curl 299 0; run_strict; assert_rc "HTTP 299"               0 $?

# === HTTP 429 → exit 4 (retryable, distinct from generic 4xx) =============
write_stub_curl 429 0; run_strict; assert_rc "HTTP 429 (retryable)"   4 $?

# === HTTP 4xx (non-429) → exit 3 (no retry) ==============================
write_stub_curl 400 0; run_strict; assert_rc "HTTP 400"               3 $?
write_stub_curl 401 0; run_strict; assert_rc "HTTP 401"               3 $?
write_stub_curl 403 0; run_strict; assert_rc "HTTP 403"               3 $?
write_stub_curl 404 0; run_strict; assert_rc "HTTP 404"               3 $?

# === HTTP 5xx → exit 5 (retryable) =======================================
write_stub_curl 500 0; run_strict; assert_rc "HTTP 500"               5 $?
write_stub_curl 502 0; run_strict; assert_rc "HTTP 502"               5 $?
write_stub_curl 503 0; run_strict; assert_rc "HTTP 503"               5 $?
write_stub_curl 504 0; run_strict; assert_rc "HTTP 504"               5 $?

# === curl-level transport failures → exit 2 (retryable) ==================
write_stub_curl 000 28; run_strict; assert_rc "curl timeout (rc=28)"  2 $?
write_stub_curl 000 7;  run_strict; assert_rc "curl conn refused (rc=7)" 2 $?
write_stub_curl 000 6;  run_strict; assert_rc "curl DNS fail (rc=6)"  2 $?
write_stub_curl "" 0;   run_strict; assert_rc "empty body (no exchange)" 2 $?

# === unexpected codes (1xx, 3xx) → exit 2 (retryable, transport ambiguous)
write_stub_curl 100 0; run_strict; assert_rc "HTTP 100 (unexpected)"  2 $?
write_stub_curl 301 0; run_strict; assert_rc "HTTP 301 (unexpected)"  2 $?

# === topic file missing → exit 1 (fatal, NOT retryable) ==================
rm -f "$TOPIC_FILE"
write_stub_curl 200 0; run_strict; assert_rc "topic file missing"     1 $?

# Recreate topic for the next test.
echo "test-topic-string" > "$TOPIC_FILE"

# === topic file empty → exit 1 (fatal) ===================================
: > "$TOPIC_FILE"
write_stub_curl 200 0; run_strict; assert_rc "topic file empty"       1 $?

# Recreate for cleanliness.
echo "test-topic-string" > "$TOPIC_FILE"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
