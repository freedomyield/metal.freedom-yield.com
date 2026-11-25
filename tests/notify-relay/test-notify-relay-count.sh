#!/usr/bin/env bash
# tests/notify-relay/test-notify-relay-count.sh — contract of scripts/notify-relay-count.sh.
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. Fake journalctl + fake cron dir in a temp dir; no network.
# COUNT_OVERRIDE: test-time path of the script under test (used by the mutant runs).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
COUNTER="${COUNT_OVERRIDE:-$REPO_ROOT/scripts/notify-relay-count.sh}"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected [$2] got [$3])"; fi; }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else fail "$1 (missing [$2])"; fi; }

TMP_ROOT="$(mktemp -d "$REPO_ROOT/.count-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT:?}"' EXIT
CRON="$TMP_ROOT/cron"
JOURNAL="$TMP_ROOT/journal.txt"
ARGV="$TMP_ROOT/journalctl.argv"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
mkdir -p "$CRON"

# fake journalctl: records its argv, prints $JOURNAL, exits with FAKE_JC_RC.
cat > "$TMP_ROOT/journalctl" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_ARGV"
if [ "${FAKE_JC_RC:-0}" != 0 ]; then exit "$FAKE_JC_RC"; fi
cat "$FAKE_JOURNAL"
FAKE
chmod +x "$TMP_ROOT/journalctl"

run() { # args...
  FYD_JOURNALCTL="$TMP_ROOT/journalctl" FYD_CRON_DIR="$CRON" FAKE_ARGV="$ARGV" FAKE_JOURNAL="$JOURNAL" \
    bash "$COUNTER" "$@" > "$OUT" 2> "$ERR" < /dev/null
  RC=$?
}

# cron fixtures: 2 with env + 1 without + .bak with env + spaced env line  => 3 counted
printf 'FYD_NOTIFY=/x/put.sh\n* * * * * root true\n' > "$CRON/metal-a"
printf 'MAILTO=x\nFYD_NOTIFY=/x/put.sh\n* * * * * root true\n' > "$CRON/metal-b"
printf '* * * * * root true\n' > "$CRON/metal-c"
printf 'FYD_NOTIFY=/x/put.sh\n' > "$CRON/metal-a.bak"
printf 'FYD_NOTIFY = x\n* * * * * root true\n' > "$CRON/freedom-yield-d"

{
  for _ in 1 2 3; do echo 'notify-relay: put 204'; done
  echo 'notify-relay: fallback http_503'
  echo 'notify-relay: fallback http_503'
  echo 'notify-relay: fallback too_long'
  echo 'something else entirely'
} > "$JOURNAL"

run
eq "exit 0 on normal run" 0 "$RC"
has "put 204 is 3" "put 204｜3" "$OUT"
has "http_503 is 2" "fallback http_503｜2" "$OUT"
has "too_long is 1" "fallback too_long｜1" "$OUT"
has "other is 1" "その他｜1" "$OUT"
has "total is 7" "合計｜7" "$OUT"
has "default since is today" "since today" "$OUT"
has "cron count is 3" "FYD_NOTIFY を持つ cron｜3 本" "$OUT"
has "cron names listed" "metal-a" "$OUT"
has "spaced env file listed" "freedom-yield-d" "$OUT"
if grep -qF 'metal-a.bak' "$OUT"; then fail ".bak name must not appear"; else ok ".bak name does not appear"; fi
if grep -qF 'http_503' "$OUT" && [ "$(grep -c 'http_503' "$OUT")" = 1 ]; then ok "http_503 listed once"; else fail "http_503 listed once"; fi
if [ "$(wc -l < "$OUT")" -le 24 ]; then ok "fits 24 lines"; else fail "fits 24 lines"; fi
if grep -qF 'something else' "$OUT"; then fail "raw journal line leaked"; else ok "raw journal line not echoed"; fi

# order: higher count first
fb_first="$(grep -n 'fallback' "$OUT" | head -1)"
case "$fb_first" in *http_503*) ok "fallback sorted by count desc" ;; *) fail "fallback sorted by count desc" ;; esac

# journalctl argv
run --since 2026-11-25
eq "since passed verbatim" 1 "$(grep -cx -- '2026-11-25' "$ARGV")"
has "tag passed" "notify-relay" "$ARGV"
has "since shown in header" "since 2026-11-25" "$OUT"

# empty journal
: > "$JOURNAL"
run
eq "empty journal exit 0" 0 "$RC"
has "empty: put 204 zero" "put 204｜0" "$OUT"
has "empty: other zero" "その他｜0" "$OUT"
has "empty: total zero" "合計｜0" "$OUT"

# journalctl fails
FAKE_JC_RC=1 run
eq "journalctl failure exit 1" 1 "$RC"
eq "journalctl failure one line" 1 "$(cat "$OUT" "$ERR" | wc -l | tr -d ' ')"

# cron dir missing
FYD_CRON_DIR="$TMP_ROOT/nope" FYD_JOURNALCTL="$TMP_ROOT/journalctl" FAKE_ARGV="$ARGV" FAKE_JOURNAL="$JOURNAL" \
  bash "$COUNTER" > "$OUT" 2> "$ERR" < /dev/null
eq "missing cron dir exit 1" 1 "$?"
eq "missing cron dir one line" 1 "$(cat "$OUT" "$ERR" | wc -l | tr -d ' ')"

# writes nothing
snap() { (cd "$TMP_ROOT" && find cron -type f | LC_ALL=C sort | while read -r f; do shasum "$f"; done; find cron | LC_ALL=C sort); }
before="$(snap)"
echo 'notify-relay: put 204' > "$JOURNAL"
run
after="$(snap)"
eq "cron dir untouched" "$before" "$after"

echo "passed: $PASS failed: $FAIL"
[ "$FAIL" = 0 ]
