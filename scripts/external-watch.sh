#!/usr/bin/env bash
# external-watch.sh — off-host watchdog for the validator host ("外部見張り").
#
# Runs on a DIFFERENT server (the web host) every 5 minutes. Every monitor
# that lives on the validator host is blind to that host losing connectivity
# (2026-09-24: ~100 h outage, no alert delivered), so this script observes
# the validator strictly from the outside:
#
#   fresh  observedAt of the pushed validator.json (local file on this host)
#   p2p    TCP connect to the validator p2p port
#   chain  public P-chain RPC: is the validator .connected ?
#
# It holds no credentials toward the validator host, never listens on a
# port, and reads only a local file, one TCP port and one public RPC.
#
# Alerting discipline (no false urgency): a push fires only after the SAME
# check failed on 2 consecutive runs; a recovery push fires on the first
# passing run after an alert. State advances only if the push succeeded.
# Nothing is sent unless WATCH_LIVE=1 (otherwise "DRY: would notify ..." on
# stderr, and state is NOT persisted so a dry run cannot mute a real alert).
#
# Config: ${WATCH_CONFIG:-$HOME/metal-fy-watch/etc/watch.env}, strict
# KEY=VALUE lines, never sourced. See parse_config below for the keys.
#
# Exit: 0 ok | 1 config error | 6 a push failed permanently.
#
# Test/ops overrides (env): WATCH_HOME WATCH_CONFIG WATCH_LIVE WATCH_NOTIFY
# WATCH_NOW_EPOCH P2P_REPROBE_SLEEP WATCH_NOTIFY_RETRY_SLEEP

set -uo pipefail

WATCH_HOME="${WATCH_HOME:-$HOME/metal-fy-watch}"
WATCH_CONFIG="${WATCH_CONFIG:-$WATCH_HOME/etc/watch.env}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="${WATCH_NOTIFY:-$SCRIPT_DIR/notify.sh}"

FRESH_MAX_AGE=900
RPC_CACHE_TTL=900
RENEW_BEFORE=1800
RENEW_AFTER=21600

die_config() {
  echo "[external-watch] config error: $*" >&2
  exit 1
}

# --- config ---------------------------------------------------------------
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
file_uid() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null; }

parse_config() {
  [ -r "$WATCH_CONFIG" ] || die_config "config file not readable"
  VALIDATOR_HOST="" VALIDATOR_P2P_PORT=9651 VALIDATOR_JSON="" NTFY_TOPIC_FILE=""
  NODE_ID="NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
  RPC_URL="https://api.metalblockchain.org/ext/bc/P"
  local line key val n=0
  local re='^[A-Z_][A-Z0-9_]*=[^$`;|&<>]*$'
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ $re ]] || die_config "line $n: not a plain KEY=VALUE"
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      VALIDATOR_HOST) VALIDATOR_HOST="$val" ;;
      VALIDATOR_P2P_PORT) VALIDATOR_P2P_PORT="$val" ;;
      VALIDATOR_JSON) VALIDATOR_JSON="$val" ;;
      NTFY_TOPIC_FILE) NTFY_TOPIC_FILE="$val" ;;
      NODE_ID) NODE_ID="$val" ;;
      RPC_URL) RPC_URL="$val" ;;
      *) die_config "line $n: unknown key $key" ;;
    esac
  done < "$WATCH_CONFIG"

  [ -n "$VALIDATOR_HOST" ] || die_config "VALIDATOR_HOST required"
  [[ "$VALIDATOR_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die_config "VALIDATOR_HOST malformed"
  [[ "$VALIDATOR_P2P_PORT" =~ ^[0-9]{1,5}$ ]] || die_config "VALIDATOR_P2P_PORT malformed"
  [ -n "$VALIDATOR_JSON" ] || die_config "VALIDATOR_JSON required"
  [[ "$VALIDATOR_JSON" == /* ]] || die_config "VALIDATOR_JSON must be absolute"
  [ -n "$NTFY_TOPIC_FILE" ] || die_config "NTFY_TOPIC_FILE required"
  [[ "$NTFY_TOPIC_FILE" == /* ]] || die_config "NTFY_TOPIC_FILE must be absolute"
  [[ "$NODE_ID" =~ ^NodeID-[A-Za-z0-9]+$ ]] || die_config "NODE_ID malformed"
  [[ "$RPC_URL" =~ ^https://[^[:space:]]+$ ]] || die_config "RPC_URL must be https"

  [ -f "$NTFY_TOPIC_FILE" ] || die_config "topic file missing"
  local mode uid
  mode="$(file_mode "$NTFY_TOPIC_FILE")"
  uid="$(file_uid "$NTFY_TOPIC_FILE")"
  case "$mode" in 600|400) ;; *) die_config "topic file mode must be 600 or 400" ;; esac
  [ "$uid" = "$(id -u)" ] || die_config "topic file must be owned by the running user"
}

parse_config

# --- runtime dirs + lock --------------------------------------------------
STATE_DIR="$WATCH_HOME/state"
LOG_DIR="$WATCH_HOME/log"
umask 077
mkdir -p "$STATE_DIR" "$LOG_DIR" || die_config "cannot create runtime dirs"
chmod 700 "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/state.json"
CACHE_FILE="$STATE_DIR/rpc-cache.json"
LOG_FILE="$LOG_DIR/watch.log"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$STATE_DIR/lock"
  flock -n 9 || exit 0
else
  # Fallback for hosts without flock (the web host has it; dev Macs may not).
  mkdir "$STATE_DIR/lock.d" 2>/dev/null || exit 0
  trap 'rmdir "$STATE_DIR/lock.d" 2>/dev/null' EXIT
fi

NOW="${WATCH_NOW_EPOCH:-$(date +%s)}"
LIVE="${WATCH_LIVE:-0}"

iso() { jq -nr --argjson t "$1" '$t | todate'; }
log_note() { printf '%s note: %s\n' "$(iso "$NOW")" "$1" >> "$LOG_FILE"; }

# --- state ----------------------------------------------------------------
STATE_INIT='{"fresh":{"status":"ok","fails":0,"first_fail_at":null},"p2p":{"status":"ok","fails":0,"first_fail_at":null},"chain":{"status":"ok","fails":0,"first_fail_at":null}}'
STATE_VALID_FILTER='[.fresh,.p2p,.chain] | all(.[]; (.status=="ok" or .status=="alerting") and (.fails|type=="number") and (.first_fail_at==null or (.first_fail_at|type=="number")))'

load_state() {
  if [ ! -e "$STATE_FILE" ]; then STATE="$STATE_INIT"; return; fi
  if jq -e "$STATE_VALID_FILTER" "$STATE_FILE" >/dev/null 2>&1; then
    STATE="$(jq -c . "$STATE_FILE")"
  else
    mv "$STATE_FILE" "$STATE_FILE.corrupt-$NOW" 2>/dev/null
    log_note "state corrupt, moved aside and re-initialised"
    STATE="$STATE_INIT"
  fi
}

commit_state() {
  [ "$LIVE" = "1" ] || return 0
  local tmp
  tmp="$(mktemp "$STATE_DIR/state.XXXXXX")" || return 1
  printf '%s\n' "$STATE" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$STATE_FILE"
}

st_get() { jq -r --arg c "$1" --arg f "$2" '.[$c][$f] // empty' <<<"$STATE"; }
st_set() { # check status fails first_fail_at(number|null)
  STATE="$(jq -c --arg c "$1" --arg s "$2" --argjson n "$3" --argjson t "$4" \
    '.[$c] = {status:$s, fails:$n, first_fail_at:$t}' <<<"$STATE")"
}

# --- notify ---------------------------------------------------------------
PUSHES=0
PUSH_FAILED=0

attempt_notify() {
  NTFY_TOPIC_FILE="$NTFY_TOPIC_FILE" NOTIFY_STRICT_EXIT=1 "$NOTIFY" "$1" "$2" "$3" >/dev/null 2>&1
}

# notify_or_keep prio title body -> 0 delivered (or DRY), non-zero = kept
notify_or_keep() {
  local prio="$1" title="$2" body="$3" rc
  if [ "$LIVE" != "1" ]; then
    echo "DRY: would notify $prio $title" >&2
    return 0
  fi
  attempt_notify "$prio" "$title" "$body"; rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      2|4|5)
        sleep "${WATCH_NOTIFY_RETRY_SLEEP:-5}"
        attempt_notify "$prio" "$title" "$body"; rc=$?
        ;;
    esac
  fi
  if [ "$rc" -eq 0 ]; then
    PUSHES=$((PUSHES + 1))
    return 0
  fi
  echo "[external-watch] notify permanent fail (rc=$rc, prio=$prio)" >&2
  PUSH_FAILED=1
  return "$rc"
}

fmt_duration() {
  local s="$1" h m
  [ "$s" -lt 0 ] && s=0
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then printf '%d時間%d分' "$h" "$m"; else printf '%d分' "$m"; fi
}

# --- checks ---------------------------------------------------------------
FRESH_RES=UNKNOWN FRESH_AGE=na
P2P_RES=UNKNOWN
CHAIN_RES=UNKNOWN

check_fresh() {
  local obs end
  if [ ! -r "$VALIDATOR_JSON" ]; then FRESH_RES=FAIL; return; fi
  obs="$(jq -r 'if (.observedAt|type)=="string" then (.observedAt | sub("\\.[0-9]+";"") | fromdateiso8601) else empty end' \
    "$VALIDATOR_JSON" 2>/dev/null)"
  if ! [[ "$obs" =~ ^[0-9]+$ ]]; then FRESH_RES=FAIL; return; fi
  FRESH_AGE=$((NOW - obs))
  end="$(jq -r 'if (.endTime|type)=="number" then .endTime else empty end' "$VALIDATOR_JSON" 2>/dev/null)"
  if [[ "$end" =~ ^[0-9]+$ ]] \
     && [ "$NOW" -ge $((end - RENEW_BEFORE)) ] && [ "$NOW" -le $((end + RENEW_AFTER)) ]; then
    FRESH_RES=UNKNOWN   # renewal window: node-info.sh legitimately stops refreshing
    return
  fi
  if [ "$FRESH_AGE" -gt "$FRESH_MAX_AGE" ]; then FRESH_RES=FAIL; else FRESH_RES=PASS; fi
}

p2p_probe() {
  # shellcheck disable=SC2016  # $0/$1 expand inside the child bash, by design
  timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$VALIDATOR_HOST" "$VALIDATOR_P2P_PORT" >/dev/null 2>&1
}

check_p2p() {
  if p2p_probe; then P2P_RES=PASS; return; fi
  sleep "${P2P_REPROBE_SLEEP:-10}"
  if p2p_probe; then P2P_RES=PASS; else P2P_RES=FAIL; fi
}

# The cache file is the raw RPC response plus a fetchedAt stamp; the response
# keys (.result...) belong to the external RPC, not to this artifact's own schema.
cache_body() { jq -c 'del(.fetchedAt)' "$CACHE_FILE" 2>/dev/null; }

rpc_response() { # prints a valid cached-or-fresh response, or returns 1
  local fetched resp
  if [ -r "$CACHE_FILE" ]; then
    fetched="$(jq -r '.fetchedAt // empty' "$CACHE_FILE" 2>/dev/null)"
    if [[ "$fetched" =~ ^[0-9]+$ ]] && [ "$((NOW - fetched))" -ge 0 ] \
       && [ "$((NOW - fetched))" -lt "$RPC_CACHE_TTL" ]; then
      resp="$(cache_body)"
      if [ -n "$resp" ]; then printf '%s' "$resp"; return 0; fi
    fi
  fi
  resp="$(curl -sS -X POST -H 'content-type:application/json' --max-time 10 \
    --data "$(jq -nc --arg id "$NODE_ID" '{jsonrpc:"2.0",id:1,method:"platform.getCurrentValidators",params:{nodeIDs:[$id]}}')" \
    "$RPC_URL" 2>/dev/null)" || return 1
  jq -e '.result.validators | type=="array"' <<<"$resp" >/dev/null 2>&1 || return 1
  local tmp
  tmp="$(mktemp "$STATE_DIR/rpc-cache.XXXXXX")" \
    && jq -c --argjson t "$NOW" '. + {fetchedAt:$t}' <<<"$resp" > "$tmp" \
    && mv "$tmp" "$CACHE_FILE"
  printf '%s' "$resp"
}

check_chain() {
  local resp conn
  if ! resp="$(rpc_response)"; then
    CHAIN_RES=UNKNOWN; log_note "chain rpc unavailable or invalid"; return
  fi
  conn="$(jq -r --arg id "$NODE_ID" \
    '[.result.validators[] | select(.nodeID==$id)] | if length==0 then "absent" else (.[0].connected | tostring) end' \
    <<<"$resp" 2>/dev/null)"
  case "$conn" in
    false) CHAIN_RES=FAIL ;;
    true) CHAIN_RES=PASS ;;
    absent) CHAIN_RES=UNKNOWN; log_note "chain: validator absent from rpc response" ;;
    *) CHAIN_RES=UNKNOWN; log_note "chain: connected not boolean" ;;
  esac
}

# --- transitions ----------------------------------------------------------
alert_text() { # check -> prio|title|label
  case "$1" in
    p2p) echo "urgent|外部見張り: validator に外から届かない|p2p (TCP 到達)" ;;
    chain) echo "urgent|外部見張り: ネットワーク上で未接続 (connected=false)|chain (公開 RPC の connected)" ;;
    fresh) echo "high|外部見張り: validator.json の更新が止まっている|fresh (validator.json の更新)" ;;
  esac
}

apply_check() { # check result
  local check="$1" res="$2" status fails first spec prio title label body dur
  status="$(st_get "$check" status)"
  fails="$(st_get "$check" fails)"
  first="$(st_get "$check" first_fail_at)"
  case "$res" in
    FAIL)
      fails=$((fails + 1))
      [ -n "$first" ] || first="$NOW"
      if [ "$fails" -ge 2 ] && [ "$status" = "ok" ]; then
        spec="$(alert_text "$check")"
        prio="${spec%%|*}"; spec="${spec#*|}"; title="${spec%%|*}"; label="${spec#*|}"
        body="$(printf 'チェック: %s\n開始: %s (UTC)\nvalidator host の外 (web host) から検知' "$label" "$(iso "$first")")"
        if notify_or_keep "$prio" "$title" "$body"; then status=alerting; fi
      fi
      st_set "$check" "$status" "$fails" "$first"
      ;;
    PASS)
      if [ "$status" = "alerting" ]; then
        spec="$(alert_text "$check")"; label="${spec##*|}"
        dur="$(fmt_duration $((NOW - ${first:-$NOW})))"
        body="$(printf 'チェック: %s\n開始: %s (UTC)\n停止期間: %s\nvalidator host の外 (web host) から検知' "$label" "$(iso "${first:-$NOW}")" "$dur")"
        if notify_or_keep default "外部見張り: 復旧 ($check)" "$body"; then
          st_set "$check" ok 0 null
        fi
      else
        st_set "$check" ok 0 null
      fi
      ;;
    *) : ;;  # UNKNOWN: no change
  esac
}

# --- run ------------------------------------------------------------------
load_state
check_fresh
check_p2p
check_chain
apply_check fresh "$FRESH_RES"
apply_check p2p "$P2P_RES"
apply_check chain "$CHAIN_RES"
commit_state

printf '%s fresh=%s(%ss) p2p=%s chain=%s pushes=%d\n' "$(iso "$NOW")" \
  "$FRESH_RES" "$FRESH_AGE" "$P2P_RES" "$CHAIN_RES" "$PUSHES" >> "$LOG_FILE"
if [ "$(wc -l < "$LOG_FILE")" -gt 6000 ]; then
  tail -n 5000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

[ "$PUSH_FAILED" = "1" ] && exit 6
exit 0
