#!/usr/bin/env bash
# scripts/notify-relay-put.sh — relay put delegate (P1). Same argv/env as scripts/notify.sh.
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No broadcast, no AI call; one HTTPS PUT-like POST at most.
#
# Sends the cron notice to ops once (put). Only an HTTP 204 ends it. Anything else
# (missing/loose secrets, bad shapes, too long, any other answer) falls back to
# `exec bash <this dir>/notify.sh "$@"` with the original argv and env.
# Secrets are read from files, handed to curl through -K (never argv/env/log); the text goes by stdin.
#
# Where to connect: a caller (cron, external watch) runs this instead of notify.sh.
# How to remove: call notify.sh again; this file and lib/notify-text.sh can be deleted.
set -u -o pipefail

# --- definition table
RELAY_PUT_TIMEOUT_SECONDS=10
RELAY_PUT_MAX_BYTES=8192
RELAY_TEXT_MAX_CHARS=2000
RELAY_TEXT_MAX_LINES=30
RELAY_PUT_SCHEMA='notify.relay.put'
RELAY_PUT_SCHEMA_VERSION=1
RELAY_SUCCESS_HTTP_CODE='204'
RELAY_LOG_TAG='notify-relay'
# shellcheck disable=SC2034  # documentation of the closed set of reasons
RELAY_FALLBACK_REASONS='no_lib no_relay_dir no_token bad_token bad_token_perms no_url bad_url bad_url_perms no_topic_file no_curl no_jq bad_text too_long http_<3 digits> curl_<number>'
RELAY_NOTIFY_SH_NAME='notify.sh'
RELAY_LIB_REL_PATH='lib/notify-text.sh'
RELAY_STDOUT_LINE='relay PUT: 204'
RELAY_STRICT_QUIET_VALUE='1'

RELAY_SELF_DIR=''
RELAY_REPO_ROOT=''
RELAY_FAIL_REASON=''
RELAY_DIR=''
RELAY_TOPIC_GID=''
RELAY_VALUE=''
RELAY_TOKEN=''
RELAY_URL=''
RELAY_BODY=''
RELAY_HTTP_CODE=''

relay_put_fail() {
  RELAY_FAIL_REASON="$1"
  return 1
}

# relay_put_log <line> — same line to stderr and logger (a missing/failing logger changes nothing).
relay_put_log() {
  printf '%s\n' "$1" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -t "$RELAY_LOG_TAG" "$1" >/dev/null 2>&1 || true
  fi
  return 0
}

# relay_put_perms_ok <path> — 0 only when ALL hold: owner uid 0; no other read/write; no group write;
# group read only when the path's gid equals RELAY_TOPIC_GID. Any stat/find failure = not ok.
relay_put_perms_ok() {
  local ug uid gid found
  ug="$(fyd_relay_owner_group "$1")" || return 1
  uid="${ug% *}"
  gid="${ug#* }"
  [ "$uid" = 0 ] || return 1
  found="$(find "$1" -prune \( -perm -0004 -o -perm -0002 -o -perm -0020 \) -print 2>/dev/null)" || return 1
  [ -z "$found" ] || return 1
  found="$(find "$1" -prune -perm -0040 -print 2>/dev/null)" || return 1
  if [ -n "$found" ]; then
    [ "$gid" = "$RELAY_TOPIC_GID" ] || return 1
  fi
  return 0
}

# relay_put_read_value <file> — RELAY_VALUE = content minus exactly one trailing newline.
# rc 1 unreadable, 2 empty, 3 NUL/odd bytes.
relay_put_read_value() {
  local raw size
  { [ -f "$1" ] && [ -r "$1" ]; } || return 1
  # braces + 2>/dev/null: bash 5 warns on stderr about a NUL byte here; stderr must stay one fixed line
  { raw="$(cat "$1"; printf x)"; } 2>/dev/null || return 1
  raw="${raw%x}"
  [ -n "$raw" ] || return 2
  size="$(LC_ALL=C wc -c < "$1")" || return 1
  [ "$((size + 0))" -eq "${#raw}" ] || return 3
  RELAY_VALUE="${raw%$'\n'}"
  return 0
}

relay_put_token_ok() {
  fyd_relay_token_is_valid "$1"
}

relay_put_url_ok() {
  fyd_relay_url_is_valid "$1"
}

relay_put_text_roundtrips() {
  [ "$1" = "$2" ]
}

relay_put_load_lib() {
  # shellcheck source-path=SCRIPTDIR source=lib/notify-text.sh
  . "$RELAY_SELF_DIR/$RELAY_LIB_REL_PATH" 2>/dev/null || return 1
  command -v fyd_relay_render_text >/dev/null 2>&1 || return 1
  return 0
}

relay_put_check_dir() {
  local relay_dir
  relay_dir="$(fyd_relay_dir)" || { relay_put_fail no_relay_dir; return 1; }
  { [ -d "$relay_dir" ] && [ -r "$relay_dir" ] && [ -x "$relay_dir" ]; } || { relay_put_fail no_relay_dir; return 1; }
  RELAY_TOPIC_GID="$(fyd_relay_owner_group "$(fyd_relay_topic_file)")" || { relay_put_fail no_topic_file; return 1; }
  RELAY_TOPIC_GID="${RELAY_TOPIC_GID#* }"
  relay_put_perms_ok "$relay_dir" || { relay_put_fail bad_token_perms; return 1; }
  RELAY_DIR="$relay_dir"
  return 0
}

relay_put_load_token() {
  local token_path="$RELAY_DIR/$RELAY_TOKEN_FILE_NAME" read_rc
  relay_put_read_value "$token_path"
  read_rc=$?
  case "$read_rc" in
    0) ;;
    1|2) relay_put_fail no_token; return 1 ;;
    *) relay_put_fail bad_token; return 1 ;;
  esac
  relay_put_token_ok "$RELAY_VALUE" || { relay_put_fail bad_token; return 1; }
  relay_put_perms_ok "$token_path" || { relay_put_fail bad_token_perms; return 1; }
  RELAY_TOKEN="$RELAY_VALUE"
  return 0
}

relay_put_load_url() {
  local url_path="$RELAY_DIR/$RELAY_URL_FILE_NAME" read_rc
  relay_put_read_value "$url_path"
  read_rc=$?
  case "$read_rc" in
    0) ;;
    1|2) relay_put_fail no_url; return 1 ;;
    *) relay_put_fail bad_url; return 1 ;;
  esac
  relay_put_url_ok "$RELAY_VALUE" || { relay_put_fail bad_url; return 1; }
  relay_put_perms_ok "$url_path" || { relay_put_fail bad_url_perms; return 1; }
  RELAY_URL="$RELAY_VALUE"
  return 0
}

relay_put_check_tools() {
  command -v curl >/dev/null 2>&1 || { relay_put_fail no_curl; return 1; }
  command -v jq >/dev/null 2>&1 || { relay_put_fail no_jq; return 1; }
  return 0
}

# relay_put_build_body <notify args...> — RELAY_BODY (JSON) from the rendered text, or bad_text.
relay_put_build_body() {
  local built back
  fyd_relay_render_text "$RELAY_REPO_ROOT" "$@" || { relay_put_fail bad_text; return 1; }
  built="$(printf '%s' "$FYD_RELAY_TEXT" | jq -Rsjc --arg s "$RELAY_PUT_SCHEMA" --argjson v "$RELAY_PUT_SCHEMA_VERSION" '{schema:$s,schema_version:$v,text:.}' && printf x)" || { relay_put_fail bad_text; return 1; }
  RELAY_BODY="${built%x}"
  back="$(printf '%s' "$RELAY_BODY" | jq -j '.text' && printf x)" || { relay_put_fail bad_text; return 1; }
  back="${back%x}"
  relay_put_text_roundtrips "$FYD_RELAY_TEXT" "$back" || { relay_put_fail bad_text; return 1; }
  return 0
}

# relay_put_check_limits — lines / chars / JSON bytes; never cuts.
relay_put_check_limits() {
  local counts lines chars bytes
  counts="$(printf '%s' "$FYD_RELAY_TEXT" | jq -Rsr '"\(split("\n") | length) \(length)"')" || { relay_put_fail bad_text; return 1; }
  lines="${counts% *}"
  chars="${counts#* }"
  [[ "$lines" =~ ^[0-9]+$ ]] || { relay_put_fail bad_text; return 1; }
  [[ "$chars" =~ ^[0-9]+$ ]] || { relay_put_fail bad_text; return 1; }
  bytes="$(printf '%s' "$RELAY_BODY" | LC_ALL=C wc -c)" || { relay_put_fail bad_text; return 1; }
  bytes="$((bytes + 0))"
  if [ "$lines" -le "$RELAY_TEXT_MAX_LINES" ] && [ "$chars" -le "$RELAY_TEXT_MAX_CHARS" ] && [ "$bytes" -le "$RELAY_PUT_MAX_BYTES" ]; then
    return 0
  fi
  relay_put_fail too_long
  return 1
}

# relay_put_write_config <url> <token> — curl -K config; printf is a builtin so nothing reaches argv.
relay_put_write_config() {
  printf 'url = "%s"\n' "$1"
  printf 'header = "Authorization: Bearer %s"\n' "$2"
  printf 'header = "X-Ops-Token: %s"\n' "$2"
  printf 'header = "Content-Type: application/json"\n'
}

# relay_put_send — one put; 0 only on the success code.
relay_put_send() {
  local curl_rc
  RELAY_HTTP_CODE="$(printf '%s' "$RELAY_BODY" | curl -q -K <(relay_put_write_config "$RELAY_URL" "$RELAY_TOKEN") -sS -o /dev/null -w '%{http_code}' --max-time "$RELAY_PUT_TIMEOUT_SECONDS" --data-binary @- 2>/dev/null)"
  curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then relay_put_fail "curl_$curl_rc"; return 1; fi
  if [[ "$RELAY_HTTP_CODE" == "$RELAY_SUCCESS_HTTP_CODE" ]]; then return 0; fi
  if [[ "$RELAY_HTTP_CODE" =~ ^[1-9][0-9]{2}$ ]]; then relay_put_fail "http_$RELAY_HTTP_CODE"; return 1; fi
  relay_put_fail "curl_$curl_rc"
  return 1
}

# relay_put_try <notify args...> — 0 only after a 204; otherwise RELAY_FAIL_REASON is set.
relay_put_try() {
  relay_put_load_lib || { relay_put_fail no_lib; return 1; }
  relay_put_check_dir || return 1
  relay_put_load_token || return 1
  relay_put_load_url || return 1
  relay_put_check_tools || return 1
  relay_put_build_body "$@" || return 1
  relay_put_check_limits || return 1
  relay_put_send || return 1
  return 0
}

relay_put_main() {
  RELAY_SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" || RELAY_SELF_DIR="$(dirname -- "$0")"
  RELAY_REPO_ROOT="$RELAY_SELF_DIR/.."
  if relay_put_try "$@"; then
    relay_put_log "$RELAY_LOG_TAG: put $RELAY_SUCCESS_HTTP_CODE"
    if [ "${NOTIFY_STRICT_EXIT:-}" != "$RELAY_STRICT_QUIET_VALUE" ]; then
      printf '%s\n' "$RELAY_STDOUT_LINE"
    fi
    exit 0
  fi
  if [ ! -f "$RELAY_SELF_DIR/$RELAY_NOTIFY_SH_NAME" ]; then
    relay_put_log "$RELAY_LOG_TAG: fallback no_notify_sh"
    exit 1
  fi
  relay_put_log "$RELAY_LOG_TAG: fallback $RELAY_FAIL_REASON"
  exec bash "$RELAY_SELF_DIR/$RELAY_NOTIFY_SH_NAME" "$@"
}

relay_put_main "$@"
