#!/usr/bin/env bash
# tests/notify/test-default-mode-byte-identical.sh
#
# Verifies that scripts/notify.sh without NOTIFY_STRICT_EXIT=1 preserves the
# historical behaviour expected by existing callers (= check-anomalies.sh
# notify() wrapper, daily-status.sh, notify-evidence-health.sh, K-3.5
# best-effort paths).
#
# Contract under default mode:
#   - exit 0 on every HTTP code (= curl itself returns 0 on connection
#     success, regardless of HTTP status)
#   - exit 1 only when topic file is missing/empty OR curl itself fails
#     (= set -euo pipefail propagates curl's non-zero exit)
#   - The script prints "ntfy POST: <code>" to stdout (= -w format)
#
# This test does NOT call real ntfy.sh. A stub curl on PATH plays the role
# of the network.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
NOTIFY="$REPO/scripts/notify.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILURES=()

TOPIC_FILE="$TMP/topic"
echo "test-topic-string" > "$TOPIC_FILE"
export NTFY_TOPIC_FILE="$TOPIC_FILE"

mkdir -p "$TMP/public/api"
echo '{}' > "$TMP/public/api/validator.json"

mkdir -p "$TMP/bin"
write_stub_curl() {
  local code="$1"
  local rc="${2:-0}"
  cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
# Stub. In default mode notify.sh uses -w "ntfy POST: %{http_code}\n" so
# the stub mimics that string. Test asserts on exit code + stdout shape.
printf 'ntfy POST: %s\n' "${code}"
exit ${rc}
EOF
  chmod +x "$TMP/bin/curl"
}

run_default() {
  PATH="$TMP/bin:$PATH" \
  NTFY_TOPIC_FILE="$TOPIC_FILE" \
  bash "$NOTIFY" default "title" "body" 2>/dev/null
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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  PASS  %-50s needle=%s\n' "$label" "$needle"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$label (needle '$needle' not found in '$haystack')")
    printf '  FAIL  %-50s needle=%s NOT in output\n' "$label" "$needle"
  fi
}

echo "=== C3b default-mode preservation (= byte-identical historical contract) ==="

# === Successful HTTP exchange → exit 0 (any code) ========================
for code in 200 201 400 404 429 500 503; do
  write_stub_curl "$code" 0
  out=$(run_default); rc=$?
  assert_rc "default mode HTTP $code → exit 0" 0 $rc
  assert_contains "default mode prints 'ntfy POST: $code'" "ntfy POST: $code" "$out"
done

# === curl-level failure → non-zero exit via set -euo pipefail ============
# Historical contract: curl's own exit code propagates (= set -e doesn't
# transform to "1", it just aborts on non-zero). Callers all tolerate
# non-zero either via `|| true` or by being end-of-script.
write_stub_curl 000 28
run_default >/dev/null; rc=$?
if [ "$rc" -ne 0 ]; then
  PASS=$((PASS + 1))
  printf '  PASS  %-50s rc=%s (non-zero)\n' "default mode curl rc=28 → non-zero exit" "$rc"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("default mode curl rc=28 should be non-zero, was $rc")
  printf '  FAIL  %-50s rc=%s\n' "default mode curl rc=28 → non-zero exit" "$rc"
fi

# === topic file missing → exit 1 =========================================
rm -f "$TOPIC_FILE"
write_stub_curl 200 0
run_default >/dev/null; rc=$?
assert_rc "default mode topic missing → exit 1" 1 $rc
echo "test-topic-string" > "$TOPIC_FILE"

# === topic file empty → exit 1 ===========================================
: > "$TOPIC_FILE"
write_stub_curl 200 0
run_default >/dev/null; rc=$?
assert_rc "default mode topic empty → exit 1" 1 $rc
echo "test-topic-string" > "$TOPIC_FILE"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
