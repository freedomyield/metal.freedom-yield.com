#!/usr/bin/env bash
# shellcheck disable=SC2016  # sed expressions are literal on purpose
# tests/notify-relay/test-notify-relay-mutants.sh — mutation net for scripts/notify-relay-put.sh (P1, tier 3).
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. Edits only temp copies; runs the P1 test against each.
# PASS = every mutant makes test-notify-relay-put.sh FAIL, and every sed really changed the copy.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P1_REPO="$REPO_ROOT/scripts/notify-relay-put.sh"
P1_TEST="$REPO_ROOT/tests/notify-relay/test-notify-relay-put.sh"
WORK="$(mktemp -d "$REPO_ROOT/.relay-mutants.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

KILLED=0
SURVIVED=0
NOOP=0
SURVIVOR_NAMES=''

# mutant <name> <sed expression> — applies the expression to a copy and runs the P1 test on it.
mutant() {
  local name="$1" expr="$2" copy log fails
  copy="$WORK/p1-$KILLED-$SURVIVED-$NOOP.sh"
  log="$WORK/log-$KILLED-$SURVIVED-$NOOP.txt"
  sed -e "$expr" "$P1_REPO" > "$copy"
  chmod 755 "$copy"
  if cmp -s "$P1_REPO" "$copy"; then
    echo "FAIL - mutant [$name]: the sed did not change the copy (net would be empty)"
    NOOP=$((NOOP + 1)); SURVIVOR_NAMES="$SURVIVOR_NAMES $name(noop)"
    return
  fi
  if RELAY_P1_UNDER_TEST="$copy" bash "$P1_TEST" > "$log" 2>&1; then
    echo "FAIL - mutant [$name] SURVIVED (all tests passed)"
    SURVIVED=$((SURVIVED + 1)); SURVIVOR_NAMES="$SURVIVOR_NAMES $name"
  else
    fails="$(grep -c '^FAIL' "$log")"
    echo "ok   - mutant [$name] killed ($fails failing checks)"
    KILLED=$((KILLED + 1))
  fi
}

# the unmutated P1 must pass first, otherwise "killed" means nothing
if ! bash "$P1_TEST" > "$WORK/baseline.txt" 2>&1; then
  echo "FAIL - baseline: the unmutated P1 does not pass its own tests"
  tail -5 "$WORK/baseline.txt"
  exit 1
fi
echo "ok   - baseline passes"

mutant "204 compare widened to 2xx"       's/== "\$RELAY_SUCCESS_HTTP_CODE"/== 2*/'
mutant "-K replaced by -H in argv"        's/-K <(relay_put_write_config "\$RELAY_URL" "\$RELAY_TOKEN")/-H "Authorization: Bearer $RELAY_TOKEN"/'
mutant "permission check removed"         's/^relay_put_is_loose() {$/relay_put_is_loose() { return 1;/'
mutant "url shape check always true"      's/^relay_put_url_ok() {$/relay_put_url_ok() { return 0;/'
mutant "token shape check always true"    's/^relay_put_token_ok() {$/relay_put_token_ok() { return 0;/'
mutant "line limit -le 31"                's/^RELAY_TEXT_MAX_LINES=30$/RELAY_TEXT_MAX_LINES=31/'
mutant "char limit 2001"                  's/^RELAY_TEXT_MAX_CHARS=2000$/RELAY_TEXT_MAX_CHARS=2001/'
mutant "byte limit 8193"                  's/^RELAY_PUT_MAX_BYTES=8192$/RELAY_PUT_MAX_BYTES=8193/'
mutant "-L added"                         's/ -sS / -L -sS /'
mutant "--max-time removed"               's/ --max-time "\$RELAY_PUT_TIMEOUT_SECONDS"//'
mutant "argv first arg dropped on exec"   's/^  exec bash /  shift; exec bash /'
mutant "bad_text check removed"           's/^relay_put_text_roundtrips() {$/relay_put_text_roundtrips() { return 0;/'
mutant "line compare -le -> -lt"          's/"\$lines" -le /"$lines" -lt /'
mutant "char compare -le -> -lt"          's/"\$chars" -le /"$chars" -lt /'
mutant "byte compare -le -> -lt"          's/"\$bytes" -le /"$bytes" -lt /'
mutant "curl exit ignored"                's/-ne 0 \]; then relay_put_fail "curl_\$curl_rc"; return 1; fi/-ne 99 ]; then relay_put_fail "curl_$curl_rc"; return 1; fi/'
mutant "token newline strip loosened"     's/RELAY_VALUE="\${raw%\$.\\n.}"/RELAY_VALUE="$(printf %s "$raw")"/'
mutant "success quiet flag ignored"       's/!= "\$RELAY_STRICT_QUIET_VALUE"/!= "never"/'
mutant "other code passed as success"     's/relay_put_fail "http_\$RELAY_HTTP_CODE"; return 1; fi/return 0; fi/'
mutant "notify.sh missing exit code 0"    's/relay_put_log "\$RELAY_LOG_TAG: fallback no_notify_sh"/relay_put_log "$RELAY_LOG_TAG: fallback no_notify_sh"; exit 0/'

echo "SUMMARY: $KILLED killed, $SURVIVED survived, $NOOP no-op"
if [ "$SURVIVED" -eq 0 ] && [ "$NOOP" -eq 0 ]; then
  echo "PASS - every mutant was caught"
  exit 0
fi
echo "FAIL - not caught:$SURVIVOR_NAMES"
exit 1
