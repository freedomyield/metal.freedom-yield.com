#!/usr/bin/env bash
# shellcheck disable=SC2016  # sed expressions are literal on purpose
# tests/notify-relay/mutants-notify-relay-put.sh — mutation net for scripts/notify-relay-put.sh (P1, tier 3).
# What: breaks a temp copy of P1 one way at a time (see the mutant list) and runs test-notify-relay-put.sh on it; every break must make it FAIL.
# Gate: run `bash tests/notify-relay/mutants-notify-relay-put.sh` by hand before merging and see PASS (a pre-merge gate, not a unit test).
# Not in CI: the name is not test-*.sh so tests/run-all-tests.sh skips it; a run takes minutes (mutants run in parallel, RELAY_MUTANT_JOBS=8).
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. Edits only temp copies; runs the P1 test against each.
# PASS = every mutant makes test-notify-relay-put.sh FAIL, and every sed really changed the copy.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P1_REPO="$REPO_ROOT/scripts/notify-relay-put.sh"
P1_TEST="$REPO_ROOT/tests/notify-relay/test-notify-relay-put.sh"
WORK="$(mktemp -d "$REPO_ROOT/.relay-mutants.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MUTANT_JOBS="${RELAY_MUTANT_JOBS:-8}"
MUTANT_INDEX=0
MUTANT_ONLY="${RELAY_MUTANT_ONLY:-}"   # a mutant name: run only that one (empty = all)

# mutant <name> <sed expression> — applies the expression to a copy and runs the P1 test on it.
# Mutants run in parallel (up to MUTANT_JOBS); each writes its verdict to $WORK/res-<n>, summed after `wait`.
mutant() {
  local name="$1" expr="$2" index
  if [ -n "$MUTANT_ONLY" ] && [ "$name" != "$MUTANT_ONLY" ]; then return 0; fi
  MUTANT_INDEX=$((MUTANT_INDEX + 1))
  index="$MUTANT_INDEX"
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$MUTANT_JOBS" ]; do sleep 1; done
  mutant_run "$index" "$name" "$expr" &
}

mutant_run() { # <index> <name> <expr>
  local index="$1" name="$2" expr="$3" copy log fails
  copy="$WORK/p1-$index.sh"
  log="$WORK/log-$index.txt"
  sed -e "$expr" "$P1_REPO" > "$copy"
  chmod 755 "$copy"
  if cmp -s "$P1_REPO" "$copy"; then
    echo "FAIL - mutant [$name]: the sed did not change the copy (net would be empty)"
    echo "noop $name" > "$WORK/res-$index"
    return
  fi
  if RELAY_P1_UNDER_TEST="$copy" bash "$P1_TEST" > "$log" 2>&1; then
    echo "FAIL - mutant [$name] SURVIVED (all tests passed)"
    echo "survived $name" > "$WORK/res-$index"
  else
    fails="$(grep -c '^FAIL' "$log")"
    echo "ok   - mutant [$name] killed ($fails failing checks)"
    echo "killed $name" > "$WORK/res-$index"
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
mutant "permission check removed"         's/^relay_put_perms_ok() {$/relay_put_perms_ok() { return 0;/'
mutant "url shape check always true"      's/^relay_put_url_ok() {$/relay_put_url_ok() { return 0;/'
mutant "token shape check always true"    's/^relay_put_token_ok() {$/relay_put_token_ok() { return 0;/'
mutant "char limit 2001"                  's/^RELAY_TEXT_MAX_CHARS=2000$/RELAY_TEXT_MAX_CHARS=2001/'
mutant "project value changed"            "s/^RELAY_PUT_PROJECT='Metal'\$/RELAY_PUT_PROJECT='Other'/"
mutant "title and body swapped"           's/--arg t "\$FYD_RELAY_TITLE" --arg b "\$FYD_RELAY_BODY" .{project/--arg t "$FYD_RELAY_BODY" --arg b "$FYD_RELAY_TITLE" '"'"'{project/'
mutant "key body renamed to text"         's/body:\$b}/text:$b}/'
mutant "key title renamed to subject"     's/title:\$t,/subject:$t,/'
mutant "char count without the project mark" 's/("【" + \$p + "】" + \$t/(\$t/'
mutant "char count without the newline"   's/"】" + \$t + "\\n" + \$b/"】" + $t + $b/'
mutant "title readback check removed"     's/relay_put_text_roundtrips "\$FYD_RELAY_TITLE" "\${back_title%x}" ||/true ||/'
mutant "body readback check removed"      's/relay_put_text_roundtrips "\$FYD_RELAY_BODY" "\${back_body%x}" ||/true ||/'
mutant "byte limit 8193"                  's/^RELAY_PUT_MAX_BYTES=8192$/RELAY_PUT_MAX_BYTES=8193/'
mutant "-L added"                         's/ -sS / -L -sS /'
mutant "--max-time removed"               's/ --max-time "\$RELAY_PUT_TIMEOUT_SECONDS"//'
mutant "argv first arg dropped on exec"   's/^  exec bash /  shift; exec bash /'
mutant "bad_text check removed"           's/^relay_put_text_roundtrips() {$/relay_put_text_roundtrips() { return 0;/'
mutant "char compare -le -> -lt"          's/"\$chars" -le /"$chars" -lt /'
mutant "byte compare -le -> -lt"          's/"\$bytes" -le /"$bytes" -lt /'
mutant "curl exit ignored"                's/-ne 0 \]; then relay_put_fail "curl_\$curl_rc"; return 1; fi/-ne 99 ]; then relay_put_fail "curl_$curl_rc"; return 1; fi/'
mutant "token newline strip loosened"     's/RELAY_VALUE="\${raw%\$.\\n.}"/RELAY_VALUE="$(printf %s "$raw")"/'
mutant "success quiet flag ignored"       's/!= "\$RELAY_STRICT_QUIET_VALUE"/!= "never"/'
mutant "other code passed as success"     's/relay_put_fail "http_\$RELAY_HTTP_CODE"; return 1; fi/return 0; fi/'
mutant "notify.sh missing exit code 0"    's/relay_put_log "\$RELAY_LOG_TAG: fallback no_notify_sh"/relay_put_log "$RELAY_LOG_TAG: fallback no_notify_sh"; exit 0/'
mutant "CDPATH not cleared for cd"        "s/CDPATH='' cd --/cd --/"
mutant "cd failure exits silently"        's/ || RELAY_SELF_DIR="\$(dirname -- "\$0")"/ || exit 1/'
mutant "fyd_relay_dir failure no reason"  's/relay_dir="\$(fyd_relay_dir)" || { relay_put_fail no_relay_dir; return 1; }/relay_dir="$(fyd_relay_dir)" || return 1/'
mutant "perm term -0004 removed"          's/-perm -0004 -o //'
mutant "perm term -0002 removed"          's/ -o -perm -0002//'
mutant "perm term -0020 (group write) removed" 's/ -o -perm -0020//'
mutant "group gid compare always true"    's/\[ "\$gid" = "\$RELAY_TOPIC_GID" \] || return 1/:/'
mutant "group compare uses runner gid"    's/\[ "\$gid" = "\$RELAY_TOPIC_GID" \] || return 1/[ "$gid" = "$(id -g)" ] || return 1/'
mutant "group read gate removed"          's/^  if \[ -n "\$found" \]; then$/  if false; then/'
mutant "owner check removed"              's/\[ "\$uid" = 0 \] || return 1/:/'
mutant "owner compare always true"        's/"\$uid" = 0 \]/"$uid" = "$uid" ]/'
mutant "topic gid unreadable passes"      's/ || { relay_put_fail no_topic_file; return 1; }/ || true/'
mutant "size check against NUL removed"   's/\[ "\$((size + 0))" -eq "\${#raw}" \] || return 3/:/'

wait
KILLED=0; SURVIVED=0; NOOP=0; SURVIVOR_NAMES=''
for res in "$WORK"/res-*; do
  [ -f "$res" ] || continue
  verdict="$(cut -d' ' -f1 "$res")"
  case "$verdict" in
    killed) KILLED=$((KILLED + 1)) ;;
    survived) SURVIVED=$((SURVIVED + 1)); SURVIVOR_NAMES="$SURVIVOR_NAMES $(cut -d' ' -f2- "$res")" ;;
    *) NOOP=$((NOOP + 1)); SURVIVOR_NAMES="$SURVIVOR_NAMES $(cut -d' ' -f2- "$res")(noop)" ;;
  esac
done
# every launched mutant must have left a verdict (a crashed job must not count as caught)
if [ "$((KILLED + SURVIVED + NOOP))" -ne "$MUTANT_INDEX" ]; then
  NOOP=$((NOOP + MUTANT_INDEX - KILLED - SURVIVED - NOOP)); SURVIVOR_NAMES="$SURVIVOR_NAMES (missing verdicts)"
fi
echo "SUMMARY: $KILLED killed, $SURVIVED survived, $NOOP no-op"
if [ "$SURVIVED" -eq 0 ] && [ "$NOOP" -eq 0 ]; then
  echo "PASS - every mutant was caught"
  exit 0
fi
echo "FAIL - not caught:$SURVIVOR_NAMES"
exit 1
