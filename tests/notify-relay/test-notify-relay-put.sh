#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2319,SC2043,SC2209  # eval strings and check "$(cond; echo $?)" are intentional
# tests/notify-relay/test-notify-relay-put.sh — contract of scripts/notify-relay-put.sh (P1).
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. Fake curl/notify.sh/logger in a temp dir; no network.
# RELAY_P1_UNDER_TEST=<path> tries another copy of P1 (the mutation net uses it).
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P1_UNDER_TEST="${RELAY_P1_UNDER_TEST:-$REPO_ROOT/scripts/notify-relay-put.sh}"
# shellcheck source=tests/notify-relay/lib-fakes.sh
. "$REPO_ROOT/tests/notify-relay/lib-fakes.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { # name cond_rc [detail]
  if [ "$2" -eq 0 ]; then ok "$1"; else fail "$1 ${3:-}"; fi
}

TMP_ROOT="$(mktemp -d "$REPO_ROOT/.relay-put-test.XXXXXX")"
cleanup_all() { relay_fake_cleanup; chmod -R u+rwx "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"; }
trap cleanup_all EXIT

unset NTFY_TAGS NOTIFY_STRICT_EXIT NOTIFY_UPTIME_SUFFIX NTFY_TOPIC_FILE
PATH_MODE=default
P1_ENV=''
P1_RC=0
ARGS=()
export FAKE_REC FAKE_CURL_CODE FAKE_CURL_RC FAKE_NOTIFY_RC FAKE_LOGGER_RC

fresh() { # [extra setup commands run after the fixture exists]
  relay_fake_cleanup
  relay_fake_setup "$TMP_ROOT" "$P1_UNDER_TEST"
  PATH_MODE=default
  P1_ENV="NTFY_TOPIC_FILE=$FAKE_TOPIC_FILE"
  FAKE_CURL_CODE=204; FAKE_CURL_RC=0; FAKE_NOTIFY_RC=0; FAKE_LOGGER_RC=0
}

# run_p1 — runs the fixture's P1 directly (no `bash` prefix) with ARGS; sets P1_RC, rec/p1.out, rec/p1.err.
run_p1() {
  relay_fake_reset_rec
  # shellcheck disable=SC2086  # P1_ENV is a list of NAME=value words without spaces
  env PATH="$(relay_fake_path "$PATH_MODE")" $P1_ENV "$FAKE_P1" ${ARGS[@]+"${ARGS[@]}"} > "$FAKE_REC/p1.out" 2> "$FAKE_REC/p1.err"
  P1_RC=$?
}

set_args() {
  case "$1" in
    0) ARGS=() ;;
    1) ARGS=("high") ;;
    2) ARGS=("high" "" "msg") ;;
    3) ARGS=("default" "T" "hello  world" "x") ;;
    4) ARGS=("low" "title" $'line1\nline2\n') ;;
    5) ARGS=("urgent" "t" "body") ;;
  esac
}

expected_argv_file() { # path
  if [ "${#ARGS[@]}" -eq 0 ]; then : > "$1"; else printf '%s\0' "${ARGS[@]}" > "$1"; fi
}

expected_env_file() { # path
  local name found word
  : > "$1"
  for name in NTFY_TAGS NOTIFY_STRICT_EXIT NTFY_TOPIC_FILE NOTIFY_UPTIME_SUFFIX; do
    found='unset'
    for word in $P1_ENV; do
      case "$word" in "$name="*) found="set:${word#*=}" ;; esac
    done
    printf '%s=%s\n' "$name" "$found" >> "$1"
  done
}

count_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# fallback_run_one <reason> <variant j> — one run in the current fixture; prints problems (empty = fine).
fallback_run_one() {
  local reason="$1" j="$2" problems=''
  FAKE_NOTIFY_RC=$((j % 6))
  if [ $((j % 2)) -eq 1 ]; then P1_ENV="NTFY_TOPIC_FILE=$FAKE_TOPIC_FILE NTFY_TAGS=tada NOTIFY_STRICT_EXIT=1 NOTIFY_UPTIME_SUFFIX="; else P1_ENV="NTFY_TOPIC_FILE=$FAKE_TOPIC_FILE"; fi
  run_p1
  [ "$P1_RC" -eq "$FAKE_NOTIFY_RC" ] || problems="$problems rc($P1_RC!=$FAKE_NOTIFY_RC)"
  [ "$(cat "$FAKE_REC/p1.err")" = "notify-relay: fallback $reason" ] || problems="$problems stderr[$(head -c 80 "$FAKE_REC/p1.err")]"
  [ "$(count_lines "$FAKE_REC/notify.count")" = 1 ] || problems="$problems notify-count"
  expected_argv_file "$FAKE_REC/exp.argv"; cmp -s "$FAKE_REC/exp.argv" "$FAKE_REC/notify.argv" || problems="$problems argv"
  expected_env_file "$FAKE_REC/exp.env"; cmp -s "$FAKE_REC/exp.env" "$FAKE_REC/notify.env" || problems="$problems env"
  if [ -s "$FAKE_REC/p1.out" ]; then problems="$problems stdout"; fi
  printf '%s' "$problems"
}

# scenario <name> <reason> <setup commands> — a broken fixture must fall back with <reason>; fake curl never called.
scenario() {
  local name="$1" reason="$2" j problems='' one
  fresh
  eval "$3"
  for j in 0 1 2 3 4 5; do
    set_args "$j"
    one="$(fallback_run_one "$reason" "$j")"
    [ -z "$one" ] || problems="$problems [args$j:$one]"
    [ ! -f "$FAKE_REC/curl.count" ] || problems="$problems [args$j:curl-called]"
  done
  check "fallback $reason: $name" "$([ -z "$problems" ]; echo $?)" "$problems"
  chmod -R u+rwx "$FAKE_DIR" 2>/dev/null
}

# ---- 1. 204 ends it
fresh; set_args 2; run_p1
check "204: exit 0" "$([ "$P1_RC" -eq 0 ]; echo $?)" "rc=$P1_RC"
check "204: stdout is relay PUT: 204" "$([ "$(cat "$FAKE_REC/p1.out")" = 'relay PUT: 204' ]; echo $?)"
check "204: stderr is the fixed line" "$([ "$(cat "$FAKE_REC/p1.err")" = 'notify-relay: put 204' ]; echo $?)"
check "204: notify.sh not called" "$([ ! -f "$FAKE_REC/notify.count" ]; echo $?)"
check "204: logger got the same line with the tag" "$([ "$(cat "$FAKE_REC/logger.log")" = '-t notify-relay notify-relay: put 204' ]; echo $?)"
for strict in 1; do
  P1_ENV="$P1_ENV NOTIFY_STRICT_EXIT=$strict"; run_p1
  check "204 strict=1: stdout empty" "$([ ! -s "$FAKE_REC/p1.out" ]; echo $?)"
  check "204 strict=1: exit 0, stderr line kept" "$([ "$P1_RC" -eq 0 ] && [ "$(cat "$FAKE_REC/p1.err")" = 'notify-relay: put 204' ]; echo $?)"
done
for strict in 0 2 ''; do
  fresh; P1_ENV="$P1_ENV NOTIFY_STRICT_EXIT=$strict"; run_p1
  check "204 strict=[$strict]: stdout shows the line" "$([ "$(cat "$FAKE_REC/p1.out")" = 'relay PUT: 204' ]; echo $?)"
done

# ---- 2. other http codes
for code in 200 201 202 301 400 401 429 503; do
  fresh; FAKE_CURL_CODE=$code; set_args 3
  problems="$(fallback_run_one "http_$code" 1)"
  check "http $code falls back" "$([ -z "$problems" ]; echo $?)" "$problems"
done

# ---- 3. curl failures
for rcv in 7 28 52 56 60; do
  fresh; FAKE_CURL_CODE=000; FAKE_CURL_RC=$rcv; set_args 1
  problems="$(fallback_run_one "curl_$rcv" 2)"
  check "curl exit $rcv falls back" "$([ -z "$problems" ]; echo $?)" "$problems"
done
fresh; FAKE_CURL_CODE=204; FAKE_CURL_RC=7; set_args 1
problems="$(fallback_run_one curl_7 3)"
check "curl exit 7 beats a printed 204" "$([ -z "$problems" ]; echo $?)" "$problems"
for weird in 000 '' abc 20 2040; do
  fresh; FAKE_CURL_CODE="$weird"; FAKE_CURL_RC=0; set_args 1
  problems="$(fallback_run_one curl_0 4)"
  check "curl exit 0 with code [$weird] -> curl_0" "$([ -z "$problems" ]; echo $?)" "$problems"
done

# ---- 4/5. the safe-side table; each runs 6 arg sets x 6 notify exit codes x env variants
scenario "no lib" no_lib 'rm "$FAKE_DIR/scripts/lib/notify-text.sh"'
scenario "relay dir missing" no_relay_dir 'rm -rf "$FAKE_RELAY_DIR"'
scenario "relay dir is a file" no_relay_dir 'rm -rf "$FAKE_RELAY_DIR"; : > "$FAKE_RELAY_DIR"'
scenario "relay dir unreadable" no_relay_dir 'chmod 000 "$FAKE_RELAY_DIR"'
scenario "relay dir 755" bad_token_perms 'chmod 755 "$FAKE_RELAY_DIR"'
scenario "relay dir 750, gid differs" bad_token_perms 'chmod 750 "$FAKE_RELAY_DIR"; FAKE_STAT_GID_DIR=99999'
scenario "relay dir 700, owner not root" bad_token_perms 'FAKE_STAT_UID_REAL=dir'
scenario "relay dir 770 (group write)" bad_token_perms 'chmod 770 "$FAKE_RELAY_DIR"'
scenario "topic file missing" no_topic_file 'rm "$FAKE_TOPIC_FILE"'
scenario "token file 640, gid differs" bad_token_perms 'chmod 640 "$FAKE_RELAY_DIR/token"; FAKE_STAT_GID_TOKEN=99999'
scenario "url file 640, gid differs" bad_url_perms 'chmod 640 "$FAKE_RELAY_DIR/url"; FAKE_STAT_GID_URL=99999'
scenario "token file 600, owner not root" bad_token_perms 'FAKE_STAT_UID_REAL=token'
scenario "url file 600, owner not root" bad_url_perms 'FAKE_STAT_UID_REAL=url'
scenario "token file 660 (group write)" bad_token_perms 'chmod 660 "$FAKE_RELAY_DIR/token"'
scenario "relay dir 702" bad_token_perms 'chmod 702 "$FAKE_RELAY_DIR"'
scenario "token missing" no_token 'rm "$FAKE_RELAY_DIR/token"'
scenario "token empty" no_token ': > "$FAKE_RELAY_DIR/token"'
scenario "token 42 chars" bad_token 'printf "%s\n" "${FAKE_TOKEN%?}" > "$FAKE_RELAY_DIR/token"'
scenario "token 44 chars" bad_token 'printf "%sA\n" "$FAKE_TOKEN" > "$FAKE_RELAY_DIR/token"'
scenario "token 2 lines" bad_token 'printf "%s\n%s\n" "$FAKE_TOKEN" "$FAKE_TOKEN" > "$FAKE_RELAY_DIR/token"'
scenario "token CRLF" bad_token 'printf "%s\r\n" "$FAKE_TOKEN" > "$FAKE_RELAY_DIR/token"'
scenario "token plus 2 newlines" bad_token 'printf "%s\n\n" "$FAKE_TOKEN" > "$FAKE_RELAY_DIR/token"'
scenario "token with trailing space" bad_token 'printf "%s \n" "$FAKE_TOKEN" > "$FAKE_RELAY_DIR/token"'
scenario "token file 644" bad_token_perms 'chmod 644 "$FAKE_RELAY_DIR/token"'
scenario "token file 660" bad_token_perms 'chmod 660 "$FAKE_RELAY_DIR/token"'
scenario "token file 602" bad_token_perms 'chmod 602 "$FAKE_RELAY_DIR/token"'
scenario "url missing" no_url 'rm "$FAKE_RELAY_DIR/url"'
scenario "url empty" no_url ': > "$FAKE_RELAY_DIR/url"'
scenario "url http other host" bad_url 'printf "http://127.0.0.2:80/notify-relay/put\n" > "$FAKE_RELAY_DIR/url"'
scenario "url 2 lines" bad_url 'printf "%s\n%s\n" "$FAKE_URL" "$FAKE_URL" > "$FAKE_RELAY_DIR/url"'
scenario "url with quotes" bad_url 'printf "\"%s\"\n" "$FAKE_URL" > "$FAKE_RELAY_DIR/url"'
scenario "url with a space" bad_url 'printf "https://a b/notify-relay/put\n" > "$FAKE_RELAY_DIR/url"'
scenario "url other path" bad_url 'printf "http://127.0.0.1:80/other\n" > "$FAKE_RELAY_DIR/url"'
scenario "url file 644" bad_url_perms 'chmod 644 "$FAKE_RELAY_DIR/url"'
scenario "relay dir 720 (group write only)" bad_token_perms 'chmod 720 "$FAKE_RELAY_DIR"'
scenario "relay dir 704 (other read only)" bad_token_perms 'chmod 704 "$FAKE_RELAY_DIR"'
scenario "token file 620 (group write only)" bad_token_perms 'chmod 620 "$FAKE_RELAY_DIR/token"'
scenario "token file 604 (other read only)" bad_token_perms 'chmod 604 "$FAKE_RELAY_DIR/token"'
scenario "url file 620 (group write only)" bad_url_perms 'chmod 620 "$FAKE_RELAY_DIR/url"'
scenario "url file 604 (other read only)" bad_url_perms 'chmod 604 "$FAKE_RELAY_DIR/url"'
scenario "token with a NUL byte" bad_token 'printf "%s\0\n" "$FAKE_TOKEN" > "$FAKE_RELAY_DIR/token"'
scenario "url with a NUL byte" bad_url 'printf "%s\0\n" "$FAKE_URL" > "$FAKE_RELAY_DIR/url"'
scenario "no curl on PATH" no_curl 'PATH_MODE=nocurl'
scenario "no jq on PATH" no_jq 'PATH_MODE=nojq'

# ---- 5b. group read is allowed (750 dir / 640 files) only with the topic file's gid
fresh; chmod 750 "$FAKE_RELAY_DIR"; chmod 640 "$FAKE_RELAY_DIR/token" "$FAKE_RELAY_DIR/url"; set_args 2; run_p1
check "750/640 same gid: put sent" "$([ "$P1_RC" -eq 0 ] && [ "$(count_lines "$FAKE_REC/curl.count")" = 1 ] && [ ! -f "$FAKE_REC/notify.count" ]; echo $?)" "rc=$P1_RC err=$(cat "$FAKE_REC/p1.err")"
fresh; set_args 2; run_p1
check "700/600 still sent" "$([ "$P1_RC" -eq 0 ] && [ "$(count_lines "$FAKE_REC/curl.count")" = 1 ]; echo $?)"

# ---- 6. 43 chars + one newline is accepted; 8. body shape
fresh; set_args 2; run_p1
check "token 43 chars + newline: put sent" "$([ "$(count_lines "$FAKE_REC/curl.count")" = 1 ] && [ "$P1_RC" -eq 0 ]; echo $?)"
body="$(cat "$FAKE_REC/curl.stdin")"
check "body keys are exactly the 3" "$([ "$(printf '%s' "$body" | jq -c 'keys')" = '["schema","schema_version","text"]' ]; echo $?)"
check "body schema/version" "$([ "$(printf '%s' "$body" | jq -c '[.schema,.schema_version]')" = '["notify.relay.put",1]' ]; echo $?)"
check "body text is the rendered text" "$([ "$(printf '%s' "$body" | jq -j '.text')" = "$(printf '【高】Freedom Yield ops\nmsg')" ]; echo $?)"
cfg="$FAKE_REC/curl.config"
check "config: url line" "$(grep -qFx "url = \"$FAKE_URL\"" "$cfg"; echo $?)"
check "config: Authorization line" "$(grep -qFx "header = \"Authorization: Bearer $FAKE_TOKEN\"" "$cfg"; echo $?)"
check "config: X-Ops-Token line" "$(grep -qFx "header = \"X-Ops-Token: $FAKE_TOKEN\"" "$cfg"; echo $?)"
check "config: content type line" "$(grep -qFx 'header = "Content-Type: application/json"' "$cfg"; echo $?)"
check "argv: first is -q" "$([ "$(sed -n 1p "$FAKE_REC/curl.argv")" = '-q' ]; echo $?)"
check "argv: no -L" "$(! grep -qxE -- '-L|--location' "$FAKE_REC/curl.argv"; echo $?)"
check "argv: --max-time 10" "$([ "$(grep -A1 -x -- '--max-time' "$FAKE_REC/curl.argv" | tail -1)" = 10 ]; echo $?)"
check "argv: -K present" "$(grep -qx -- '-K' "$FAKE_REC/curl.argv"; echo $?)"

# ---- 7. secrets never in argv / env / stdout / stderr / logger
leak=''
for secret in "$FAKE_TOKEN" "$FAKE_URL"; do
  for f in curl.argv curl.env p1.out p1.err logger.log; do
    [ -f "$FAKE_REC/$f" ] && grep -qF -- "$secret" "$FAKE_REC/$f" && leak="$leak $f"
  done
done
check "204 run: token and url are not in argv/env/stdout/stderr/logger" "$([ -z "$leak" ]; echo $?)" "$leak"
fresh; FAKE_CURL_CODE=500; set_args 2; run_p1; leak=''
for secret in "$FAKE_TOKEN" "$FAKE_URL"; do
  for f in curl.argv curl.env p1.out p1.err logger.log notify.argv notify.env; do
    [ -f "$FAKE_REC/$f" ] && grep -qF -- "$secret" "$FAKE_REC/$f" && leak="$leak $f"
  done
done
check "fallback run: token and url are not in argv/env/stdout/stderr/logger/notify" "$([ -z "$leak" ]; echo $?)" "$leak"

# ---- 9. limits (never cut, never sent)
rep() { local out; out="$(printf '%*s' "$2" '' | sed "s/ /$1/g")"; printf '%s' "$out"; }
join_lines() { local n="$1" i out=''; for i in $(seq 1 "$n"); do out="$out${out:+$'\n'}L$i"; done; printf '%s' "$out"; }
limit_case() { # name expect(send|too_long) body
  fresh; ARGS=("default" "t" "$3"); run_p1
  if [ "$2" = send ]; then
    check "limit $1: sent" "$([ "$P1_RC" -eq 0 ] && [ "$(count_lines "$FAKE_REC/curl.count")" = 1 ] && [ ! -f "$FAKE_REC/notify.count" ]; echo $?)" "rc=$P1_RC err=$(cat "$FAKE_REC/p1.err")"
  else
    check "limit $1: too_long, no put" "$([ "$(cat "$FAKE_REC/p1.err")" = 'notify-relay: fallback too_long' ] && [ ! -f "$FAKE_REC/curl.count" ] && [ "$(count_lines "$FAKE_REC/notify.count")" = 1 ]; echo $?)" "err=$(cat "$FAKE_REC/p1.err")"
  fi
}
limit_case "30 lines" send "$(join_lines 29)"
limit_case "31 lines" too_long "$(join_lines 30)"
limit_case "2000 chars (multibyte)" send "$(rep あ 1994)"
limit_case "2001 chars" too_long "$(rep あ 1995)"
json_bytes() { printf '%s' "$1" | jq -Rsjc '{schema:"notify.relay.put",schema_version:1,text:.}' | LC_ALL=C wc -c | tr -d ' '; }
ctl="$(printf '\001')"
base_body="$(rep "$ctl" 1300)"
base_text="$(printf '【通常】t\n%s' "$base_body")"
pad=$((8192 - $(json_bytes "$base_text")))
check "limit setup: padding is positive and chars stay <= 2000" "$([ "$pad" -gt 0 ] && [ $((1300 + pad + 6)) -le 2000 ]; echo $?)" "pad=$pad"
limit_case "8192 bytes exactly" send "$base_body$(rep a "$pad")"
limit_case "8193 bytes" too_long "$base_body$(rep a $((pad + 1)))"
fresh; ARGS=("default" "t" "$(join_lines 30)"); relay_fake_reset_rec
problems="$(fallback_run_one too_long 5)"
check "too_long: notify.sh gets same argv/env/rc" "$([ -z "$problems" ]; echo $?)" "$problems"

# ---- 10. invalid UTF-8
fresh; ARGS=("high" "t" $'bad\xffbyte')
problems="$(fallback_run_one bad_text 3)"
check "invalid UTF-8 -> bad_text, curl not called, notify args same" "$([ -z "$problems" ] && [ ! -f "$FAKE_REC/curl.count" ]; echo $?)" "$problems"

# ---- 11. notify.sh missing next to P1
fresh; rm "$FAKE_DIR/scripts/notify.sh"; FAKE_CURL_CODE=500; set_args 1; run_p1
check "no notify.sh: exit 1 and one fixed stderr line" "$([ "$P1_RC" -eq 1 ] && [ "$(cat "$FAKE_REC/p1.err")" = 'notify-relay: fallback no_notify_sh' ]; echo $?)" "rc=$P1_RC"

# ---- 12. logger failure changes nothing
fresh; FAKE_LOGGER_RC=1; set_args 2; run_p1
check "logger fails: 204 path same" "$([ "$P1_RC" -eq 0 ] && [ "$(cat "$FAKE_REC/p1.out")" = 'relay PUT: 204' ]; echo $?)"
fresh; FAKE_LOGGER_RC=1; FAKE_CURL_CODE=503; set_args 2
problems="$(fallback_run_one http_503 3)"
check "logger fails: fallback path same" "$([ -z "$problems" ]; echo $?)" "$problems"

# ---- 14. CDPATH set + relative path: same behaviour (204 and fallback)
cdpath_run() { # sets P1_RC; CDPATH points at a decoy dir that also has a scripts/ dir
  local decoy="$TMP_ROOT/decoy"
  mkdir -p "$decoy/scripts"
  relay_fake_reset_rec
  (cd "$FAKE_DIR" && env CDPATH="$decoy" PATH="$(relay_fake_path default)" NTFY_TOPIC_FILE="$FAKE_TOPIC_FILE" scripts/notify-relay-put.sh high t msg > "$FAKE_REC/p1.out" 2> "$FAKE_REC/p1.err")
  P1_RC=$?
}
fresh; cdpath_run
check "CDPATH + relative path: 204 same" "$([ "$P1_RC" -eq 0 ] && [ "$(cat "$FAKE_REC/p1.out")" = 'relay PUT: 204' ] && [ "$(cat "$FAKE_REC/p1.err")" = 'notify-relay: put 204' ]; echo $?)" "rc=$P1_RC out=$(cat "$FAKE_REC/p1.out")"
fresh; FAKE_CURL_CODE=503; FAKE_NOTIFY_RC=3; cdpath_run
check "CDPATH + relative path: fallback same" "$([ "$P1_RC" -eq 3 ] && [ "$(cat "$FAKE_REC/p1.err")" = 'notify-relay: fallback http_503' ] && [ "$(count_lines "$FAKE_REC/notify.count")" = 1 ]; echo $?)" "rc=$P1_RC"

# ---- 15. cd into the script dir fails: still the fixed fallback line, not a silent exit
fresh
relay_fake_reset_rec
bash -c "$(cat "$FAKE_P1")" "$FAKE_DIR/gone/notify-relay-put.sh" high t msg > "$FAKE_REC/p1.out" 2> "$FAKE_REC/p1.err"
P1_RC=$?
check "cd fails: exit 1 with the fixed no_notify_sh line" "$([ "$P1_RC" -eq 1 ] && [ "$(cat "$FAKE_REC/p1.err")" = 'notify-relay: fallback no_notify_sh' ]; echo $?)" "rc=$P1_RC err=$(cat "$FAKE_REC/p1.err")"

# ---- 16. lib loads but fyd_relay_dir fails -> no_relay_dir (never an empty reason)
fresh
printf '%s\n' 'fyd_relay_render_text() { :; }' 'fyd_relay_dir() { return 1; }' > "$FAKE_DIR/scripts/lib/notify-text.sh"
set_args 3
problems="$(fallback_run_one no_relay_dir 1)"
check "fyd_relay_dir fails -> no_relay_dir" "$([ -z "$problems" ] && [ ! -f "$FAKE_REC/curl.count" ]; echo $?)" "$problems"

# ---- 13. direct execution (external watch runs it without `bash`)
check "repo P1 is executable" "$([ -x "$REPO_ROOT/scripts/notify-relay-put.sh" ]; echo $?)"
check "repo P1 shebang is bash" "$([ "$(head -1 "$REPO_ROOT/scripts/notify-relay-put.sh")" = '#!/usr/bin/env bash' ]; echo $?)"

echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
