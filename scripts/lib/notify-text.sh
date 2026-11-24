# shellcheck shell=bash
# scripts/lib/notify-text.sh — shared text/format parts for the notify relay put (P2).
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No network, no broadcast, no AI call.
#
# Sourced, never executed; it does not change shell options (no `set`).
#
# Why this lives in two places: scripts/notify.sh builds the same title,
# priority and body (with the "[Uptime]" footer) and must stay untouched, so
# the relay put (P1) cannot source notify.sh. The lib repeats those few rules,
# and tests/notify-relay/test-notify-text.sh runs the real notify.sh beside it
# and fails if the two ever differ (design doc 7.6 / 13-8).
#
# Where to connect: P1 sources this file and calls fyd_relay_render_text.
# How to remove: delete this file and its test; notify.sh is unaffected.

# --- definition table (values are exact; not readonly so tests can re-source)
FYD_NTFY_TOPIC_FILE_DEFAULT='/etc/freedom-yield/ntfy-topic'
FYD_NOTIFY_TITLE_DEFAULT='Freedom Yield ops'
FYD_NOTIFY_MESSAGE_DEFAULT='(no message)'
FYD_VALIDATOR_JSON_REL='public/api/validator.json'
RELAY_DIR_NAME='notify-relay'
# shellcheck disable=SC2034  # used by P1/P3
RELAY_TOKEN_FILE_NAME='token'
# shellcheck disable=SC2034  # used by P1/P3
RELAY_URL_FILE_NAME='url'
RELAY_PRIORITY_WORDS='urgent=緊急 high=高 default=通常 low=低 min=最低'
RELAY_TOKEN_PATTERN='^[A-Za-z0-9_-]{43}$'
RELAY_URL_PATTERN_HTTPS='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/notify-relay/put$'
RELAY_URL_PATTERN_BENCH='^http://127\.0\.0\.1:[0-9]{1,5}/notify-relay/put$'

# fyd_notify_normalize_priority <prio> — one of urgent|high|default|low|min, else default.
fyd_notify_normalize_priority() {
  case "${1:-}" in
    urgent|high|default|low|min) printf '%s' "$1" ;;
    *) printf 'default' ;;
  esac
}

# fyd_relay_priority_word <prio> — the Japanese word for the normalized priority.
fyd_relay_priority_word() {
  local prio pair
  prio="$(fyd_notify_normalize_priority "${1:-}")"
  for pair in $RELAY_PRIORITY_WORDS; do
    if [ "${pair%%=*}" = "$prio" ]; then
      printf '%s' "${pair#*=}"
      return 0
    fi
  done
  return 1
}

# fyd_notify_uptime_footer <repo_root> — "[Uptime] N%<suffix>" or nothing (same jq as notify.sh).
fyd_notify_uptime_footer() {
  local json_path="${1:-}/${FYD_VALIDATOR_JSON_REL}" uptime_value
  [ -r "$json_path" ] || return 0
  uptime_value="$(jq -r '.uptime.network // empty' "$json_path" 2>/dev/null)" || return 0
  if [ -n "$uptime_value" ] && [ "$uptime_value" != "null" ]; then
    printf '[Uptime] %s%%%s' "$uptime_value" "${NOTIFY_UPTIME_SUFFIX:-}"
  fi
  return 0
}

# fyd_relay_dir — directory of the relay's token/url files.
fyd_relay_dir() {
  local topic_file_path="${NTFY_TOPIC_FILE:-$FYD_NTFY_TOPIC_FILE_DEFAULT}"
  printf '%s/%s' "$(dirname "$topic_file_path")" "$RELAY_DIR_NAME"
}

# fyd_relay_url_is_valid <url> — 0 only for the two allowed URL shapes.
fyd_relay_url_is_valid() {
  [[ "${1:-}" =~ $RELAY_URL_PATTERN_HTTPS ]] && return 0
  [[ "${1:-}" =~ $RELAY_URL_PATTERN_BENCH ]] && return 0
  return 1
}

# fyd_relay_token_is_valid <token> — 0 only for a 43-char base64url token.
fyd_relay_token_is_valid() {
  [[ "${1:-}" =~ $RELAY_TOKEN_PATTERN ]]
}

# fyd_relay_render_text <repo_root> [prio [title [message...]]]
# Sets FYD_RELAY_TEXT to "【word】title\nbody[\n\nfooter]" (not printed: $(...) would drop trailing newlines).
fyd_relay_render_text() {
  local repo_root="${1:-}" priority_word title_text body_text footer_text
  local IFS=$' \t\n'
  [ "$#" -gt 0 ] && shift
  priority_word="$(fyd_relay_priority_word "${1:-default}")"
  title_text="${2:-$FYD_NOTIFY_TITLE_DEFAULT}"
  body_text=""
  if [ "$#" -ge 3 ]; then
    shift 2
    body_text="$*"
  fi
  [ -n "$body_text" ] || body_text="$FYD_NOTIFY_MESSAGE_DEFAULT"
  footer_text="$(fyd_notify_uptime_footer "$repo_root")"
  printf -v FYD_RELAY_TEXT '【%s】%s\n%s' "$priority_word" "$title_text" "$body_text"
  if [ -n "$footer_text" ]; then
    printf -v FYD_RELAY_TEXT '%s\n\n%s' "$FYD_RELAY_TEXT" "$footer_text"
  fi
  return 0
}
