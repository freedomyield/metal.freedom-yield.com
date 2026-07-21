#!/usr/bin/env bash
# tests/notify/test-tags-override.sh
#
# Verifies the NTFY_TAGS per-notification override in scripts/notify.sh:
#   (a) NTFY_TAGS=tada        → the Tags header sent to curl is "tada"
#   (b) NTFY_TAGS unset       → priority-derived default (high → "warning")
#   (c) NTFY_TAGS="" (empty)  → falls back to the priority-derived default
#
# This test does NOT call real ntfy.sh. A stub curl on PATH records its
# argv so the test can assert on the exact "Tags: ..." header value.
#
# Pre-conditions enforced by the test harness:
#   - Production /etc/freedom-yield/ntfy-topic is NOT read. A throwaway
#     topic file is created in $TMP and pointed at via NTFY_TOPIC_FILE.
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

mkdir -p "$TMP/public/api"
echo '{}' > "$TMP/public/api/validator.json"

# === stub curl: record argv, one arg per line ============================
# notify.sh passes headers as `-H "Tags: <value>"`, so the Tags header
# appears as a single "Tags: <value>" line in the recorded argv.
ARGS_FILE="$TMP/curl-args"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
# Stub curl for notify.sh tests. Records argv (one per line), never connects.
printf '%s\n' "\$@" > "$ARGS_FILE"
printf 'ntfy POST: 200\n'
exit 0
EOF
chmod +x "$TMP/bin/curl"

# run_notify <priority> [env VAR=VALUE ...]
run_notify() {
  local prio="$1"; shift
  : > "$ARGS_FILE"
  env PATH="$TMP/bin:$PATH" NTFY_TOPIC_FILE="$TOPIC_FILE" "$@" \
    bash "$NOTIFY" "$prio" "title" "body" >/dev/null 2>&1
}

sent_tags() {
  sed -n 's/^Tags: //p' "$ARGS_FILE"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %-55s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$label (expected=$expected, actual=$actual)")
    printf '  FAIL  %-55s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  fi
}

echo "=== NTFY_TAGS per-notification override ==="

# === (a) NTFY_TAGS=tada overrides the priority-derived default ===========
run_notify high NTFY_TAGS=tada
assert_eq "NTFY_TAGS=tada, prio=high → Tags: tada" "tada" "$(sent_tags)"

run_notify urgent NTFY_TAGS=tada
assert_eq "NTFY_TAGS=tada, prio=urgent → Tags: tada" "tada" "$(sent_tags)"

# === (b) NTFY_TAGS unset → priority-derived default ======================
run_notify high
assert_eq "NTFY_TAGS unset, prio=high → Tags: warning" "warning" "$(sent_tags)"

run_notify urgent
assert_eq "NTFY_TAGS unset, prio=urgent → Tags: rotating_light" "rotating_light" "$(sent_tags)"

run_notify default
assert_eq "NTFY_TAGS unset, prio=default → Tags: information_source" "information_source" "$(sent_tags)"

# === (c) NTFY_TAGS="" (empty) → falls back to the default ================
run_notify high NTFY_TAGS=
assert_eq "NTFY_TAGS empty, prio=high → Tags: warning" "warning" "$(sent_tags)"

run_notify default NTFY_TAGS=
assert_eq "NTFY_TAGS empty, prio=default → Tags: information_source" "information_source" "$(sent_tags)"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
