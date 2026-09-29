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
# stderr). A DRY run persists fails/first_fail_at (so the alert path is
# reachable) but never moves status to alerting and never clears an existing
# alerting status, so it can neither mute nor fake a real alert.
#
# Chain observations come from a 900 s cached RPC sample: a cached sample is
# counted once (fetchedAt is remembered in state as last_counted), so 2
# consecutive chain failures always mean 2 distinct observations.
#
# Config: ${WATCH_CONFIG:-$HOME/metal-fy-watch/etc/watch.env}, strict
# KEY=VALUE lines, never sourced. See parse_config below for the keys.
#
# Exit: 0 ok | 1 config error | 6 a push failed permanently (including the
# state-save alert below) | 7 state could not be saved (disk full, quota,
# permissions): one urgent push was sent, NOT debounced, on every such run —
# without saved state the 2-consecutive rule can never fire, so staying quiet
# would silently disable every alert.
#
# Test/ops overrides (env): WATCH_HOME WATCH_CONFIG WATCH_LIVE WATCH_NOTIFY
# WATCH_NOW_EPOCH P2P_REPROBE_SLEEP WATCH_NOTIFY_RETRY_SLEEP
# WATCH_LOG_MAX_BYTES WATCH_CRONERR_MAX_BYTES WATCH_KEEP_BACKUPS WATCH_KEEP_CORRUPT

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

# Preflight: every dependency is required; a missing one must never degrade
# into a silent no-op or a false alert.
for dep in jq curl timeout flock; do
  command -v "$dep" >/dev/null 2>&1 || {
    echo "external-watch: missing dependency: $dep" >&2
    exit 1
  }
done

# --- runtime dirs + lock --------------------------------------------------
STATE_DIR="$WATCH_HOME/state"
LOG_DIR="$WATCH_HOME/log"
umask 077
mkdir -p "$STATE_DIR" "$LOG_DIR" || die_config "cannot create runtime dirs"
chmod 700 "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/state.json"
CACHE_FILE="$STATE_DIR/rpc-cache.json"
LOG_FILE="$LOG_DIR/watch.log"

exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0

NOW="${WATCH_NOW_EPOCH:-$(date +%s)}"
# Digits only: NOW is used in $((...)), which would evaluate any expression.
[[ "$NOW" =~ ^[0-9]+$ ]] || die_config "WATCH_NOW_EPOCH must be digits"
LIVE="${WATCH_LIVE:-0}"

iso() { jq -nr --argjson t "$1" '$t | todate'; }
log_note() { printf '%s note: %s\n' "$(iso "$NOW")" "$1" >> "$LOG_FILE"; }

# --- state ----------------------------------------------------------------
STATE_INIT='{"fresh":{"status":"ok","fails":0,"first_fail_at":null},"p2p":{"status":"ok","fails":0,"first_fail_at":null},"chain":{"status":"ok","fails":0,"first_fail_at":null}}'
STATE_VALID_FILTER='[.fresh,.p2p,.chain] | all(.[]; (.status=="ok" or .status=="alerting") and (.fails|type=="number") and (.first_fail_at==null or (.first_fail_at|type=="number")) and ((.last_counted // null)==null or (.last_counted|type=="number")))'

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
  local tmp
  tmp="$(mktemp "$STATE_DIR/state.XXXXXX")" || return 1
  if printf '%s\n' "$STATE" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$STATE_FILE"; then
    return 0
  fi
  rm -f "$tmp"   # a half-written temp must not pile up (e.g. disk full)
  return 1
}

# state_writable: same first steps as commit_state, without committing. When it
# fails, this run cannot record anything, so the per-check pushes are held back
# (see check_push) and the state-save alert is the only push.
state_writable() {
  local tmp
  tmp="$(mktemp "$STATE_DIR/state.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$STATE" > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  return 1
}

st_get() { jq -r --arg c "$1" --arg f "$2" '.[$c][$f] // empty' <<<"$STATE"; }
st_mark() { # check observation-epoch
  STATE="$(jq -c --arg c "$1" --argjson o "$2" '.[$c].last_counted = $o' <<<"$STATE")"
}
st_set() { # check status fails first_fail_at(number|null)
  STATE="$(jq -c --arg c "$1" --arg s "$2" --argjson n "$3" --argjson t "$4" \
    '.[$c] += {status:$s, fails:$n, first_fail_at:$t}' <<<"$STATE")"
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
CHAIN_RES=UNKNOWN CHAIN_OBS="" CHAIN_NOTE=""

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
  # Host and port travel in the environment (readable only by this UID), not
  # in argv (readable by every local user on the shared web host).
  # shellcheck disable=SC2016  # $H/$P expand inside the child bash, by design
  H="$VALIDATOR_HOST" P="$VALIDATOR_P2P_PORT" timeout 5 bash -c 'exec 3<>"/dev/tcp/$H/$P"' >/dev/null 2>&1
}

check_p2p() {
  if p2p_probe; then P2P_RES=PASS; return; fi
  sleep "${P2P_REPROBE_SLEEP:-10}"
  if p2p_probe; then P2P_RES=PASS; else P2P_RES=FAIL; fi
}

# The cache file is the raw RPC response plus a fetchedAt stamp; the response
# keys (.result...) belong to the external RPC, not to this artifact's own schema.
cache_body() { jq -c 'del(.fetchedAt)' "$CACHE_FILE" 2>/dev/null; }

# rpc_response: sets RPC_RESP (valid cached-or-fresh response) and RPC_OBS
# (epoch at which that sample was really taken), or returns 1.
RPC_RESP="" RPC_OBS=""
rpc_response() {
  local fetched resp
  if [ -r "$CACHE_FILE" ]; then
    fetched="$(jq -r '.fetchedAt // empty' "$CACHE_FILE" 2>/dev/null)"
    if [[ "$fetched" =~ ^[0-9]+$ ]] && [ "$((NOW - fetched))" -ge 0 ] \
       && [ "$((NOW - fetched))" -lt "$RPC_CACHE_TTL" ]; then
      resp="$(cache_body)"
      if [ -n "$resp" ]; then RPC_RESP="$resp"; RPC_OBS="$fetched"; return 0; fi
    fi
  fi
  resp="$(curl -sS -X POST -H 'content-type:application/json' --max-time 10 \
    --proto =https --max-filesize 1048576 \
    --data "$(jq -nc --arg id "$NODE_ID" '{jsonrpc:"2.0",id:1,method:"platform.getCurrentValidators",params:{nodeIDs:[$id]}}')" \
    "$RPC_URL" 2>/dev/null)" || return 1
  jq -e '.result.validators | type=="array"' <<<"$resp" >/dev/null 2>&1 || return 1
  local tmp
  tmp="$(mktemp "$STATE_DIR/rpc-cache.XXXXXX")" \
    && jq -c --argjson t "$NOW" '. + {fetchedAt:$t}' <<<"$resp" > "$tmp" \
    && mv "$tmp" "$CACHE_FILE"
  RPC_RESP="$resp"; RPC_OBS="$NOW"
}

check_chain() {
  local resp conn
  if ! rpc_response; then
    CHAIN_RES=UNKNOWN; log_note "chain rpc unavailable or invalid"; return
  fi
  resp="$RPC_RESP"; CHAIN_OBS="$RPC_OBS"
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

# check_push: a per-check alert/recovery push. Held back (returns non-zero, so
# the status change is not made) when this run cannot save state: the alert
# would repeat on every run and could not be recorded, so the single
# state-save push is the only message.
SAVE_BLOCKED=0
check_push() {
  [ "$SAVE_BLOCKED" = "1" ] && return 1
  notify_or_keep "$@"
}

apply_check() { # check result [observation-epoch]
  local check="$1" res="$2" obs="${3:-}" status fails first spec prio title label body dur newobs=1
  status="$(st_get "$check" status)"
  fails="$(st_get "$check" fails)"
  first="$(st_get "$check" first_fail_at)"
  # A cached sample already counted must not count again (2-consecutive rule).
  if [ -n "$obs" ] && [ "$(st_get "$check" last_counted)" = "$obs" ]; then
    newobs=0
    [ "$check" = chain ] && CHAIN_NOTE="(cached)"
  fi
  case "$res" in
    FAIL)
      [ "$newobs" = 1 ] && fails=$((fails + 1))
      [ -n "$first" ] || first="$NOW"
      if [ "$fails" -ge 2 ] && [ "$status" = "ok" ]; then
        spec="$(alert_text "$check")"
        prio="${spec%%|*}"; spec="${spec#*|}"; title="${spec%%|*}"; label="${spec#*|}"
        body="$(printf 'チェック: %s\n開始: %s (UTC)\nvalidator host の外 (web host) から検知' "$label" "$(iso "$first")")"
        if check_push "$prio" "$title" "$body" && [ "$LIVE" = "1" ]; then status=alerting; fi
      fi
      st_set "$check" "$status" "$fails" "$first"
      [ -n "$obs" ] && st_mark "$check" "$obs"
      ;;
    PASS)
      if [ "$status" = "alerting" ]; then
        spec="$(alert_text "$check")"; label="${spec##*|}"
        dur="$(fmt_duration $((NOW - ${first:-$NOW})))"
        body="$(printf 'チェック: %s\n開始: %s (UTC)\n停止期間: %s\nvalidator host の外 (web host) から検知' "$label" "$(iso "${first:-$NOW}")" "$dur")"
        if check_push default "外部見張り: 復旧 ($check)" "$body" && [ "$LIVE" = "1" ]; then
          st_set "$check" ok 0 null
        fi
      else
        st_set "$check" ok 0 null
      fi
      # No PASS marker needed: a PASS is not counted (reset is idempotent and a
      # recovery push retry on a cached sample is desired), so dedup has no
      # observable effect on the PASS side.
      ;;
    *) : ;;  # UNKNOWN: no change
  esac
}

# --- housekeeping (size caps) --------------------------------------------
# Every file this script writes on the shared host has an upper bound. The
# overrides exist for tests; production runs on the defaults. A value that is
# not a positive integer falls back to the default.
cap_value() { # env-value default
  if [[ "$1" =~ ^[1-9][0-9]{0,14}$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
file_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
file_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null; }

# trim_tail file max: when the file exceeds max bytes keep only its newest
# half, cut at a line boundary (no partial first line). The file is rewritten
# IN PLACE (cat tmp > file, never mv): cron.err is held open with O_APPEND by
# the cron shell for the whole run, and replacing the inode would orphan that
# descriptor and lose this run's stderr.
trim_tail() {
  local f="$1" max="$2" size half raw kept rc=1
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  size="$(file_size "$f")"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  [ "$size" -gt "$max" ] || return 0
  half=$((max / 2))
  raw="$(mktemp "$LOG_DIR/.trim.XXXXXX")" || return 1
  kept="$(mktemp "$LOG_DIR/.trim.XXXXXX")" || { rm -f "$raw"; return 1; }
  # One byte more than half: if it is a newline, the rest starts on a line.
  if tail -c $((half + 1)) "$f" > "$raw" 2>/dev/null; then
    if [ "$(head -c 1 "$raw" | od -An -tx1 | tr -d ' \n')" = "0a" ]; then
      tail -c +2 "$raw" > "$kept"
    else
      tail -n +2 "$raw" > "$kept"
    fi
    cat "$kept" > "$f" && rc=0
  fi
  rm -f "$raw" "$kept"
  return "$rc"
}

# prune_dir dir pattern keep: delete all but the newest KEEP regular files
# (not symlinks, not directories) directly inside dir whose name matches
# pattern. Nothing outside dir is ever touched.
prune_dir() {
  local dir="$1" pat="$2" keep="$3" list ordered f m rc=0
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  list="$(mktemp "$LOG_DIR/.trim.XXXXXX")" || return 1
  ordered="$(mktemp "$LOG_DIR/.trim.XXXXXX")" || { rm -f "$list"; return 1; }
  if ! find "$dir" -maxdepth 1 -type f -name "$pat" -print0 > "$list" 2>/dev/null; then
    rm -f "$list" "$ordered"; return 1
  fi
  while IFS= read -r -d '' f; do
    case "$f" in *$'\n'*) continue ;; esac   # never act on odd names
    m="$(file_mtime "$f")"; [[ "$m" =~ ^[0-9]+$ ]] || continue
    printf '%s\t%s\n' "$m" "$f"
  done < "$list" | sort -t $'\t' -k1,1nr -k2,2r > "$ordered"
  while IFS=$'\t' read -r _ f; do
    rm -f -- "$f" || rc=1
  done < <(tail -n +$((keep + 1)) "$ordered")
  rm -f "$list" "$ordered"
  return "$rc"
}

# Housekeeping must never change alerting or the exit code: every failure is
# folded into one host-free note line.
housekeeping() {
  local max_log max_err keep_bak keep_cor bad=0
  max_log="$(cap_value "${WATCH_LOG_MAX_BYTES:-}" 1048576)"
  max_err="$(cap_value "${WATCH_CRONERR_MAX_BYTES:-}" 1048576)"
  keep_bak="$(cap_value "${WATCH_KEEP_BACKUPS:-}" 10)"
  keep_cor="$(cap_value "${WATCH_KEEP_CORRUPT:-}" 10)"
  trim_tail "$LOG_FILE" "$max_log" 2>/dev/null || bad=1
  trim_tail "$LOG_DIR/cron.err" "$max_err" 2>/dev/null || bad=1
  prune_dir "$WATCH_HOME/backup" '*' "$keep_bak" 2>/dev/null || bad=1
  prune_dir "$STATE_DIR" 'state.json.corrupt-*' "$keep_cor" 2>/dev/null || bad=1
  [ "$bad" = 0 ] || log_note "housekeeping incomplete" 2>/dev/null
  return 0
}

# --- run ------------------------------------------------------------------
load_state
state_writable || SAVE_BLOCKED=1
check_fresh
check_p2p
check_chain
apply_check fresh "$FRESH_RES"
apply_check p2p "$P2P_RES"
apply_check chain "$CHAIN_RES" "$CHAIN_OBS"
STATE_SAVE_FAILED=0
if [ "$SAVE_BLOCKED" = "1" ] || ! commit_state 2>/dev/null; then
  # Without saved state every run re-reads the old counters, so no check can
  # ever reach 2 consecutive failures: alerting is silently dead. Say so on
  # every such run (deliberately not debounced or deduplicated: there is no
  # state to dedupe with). The body names no host, path or value.
  STATE_SAVE_FAILED=1
  echo "[external-watch] state save failed" >&2
  log_note "state save failed" 2>/dev/null
  # Per-check pushes were held back for this run (check_push), so name the
  # checks failing right now here. Names only: no host, port, path or value.
  FAILING=""
  [ "$FRESH_RES" = FAIL ] && FAILING="fresh"
  [ "$P2P_RES" = FAIL ] && FAILING="${FAILING:+$FAILING, }p2p"
  [ "$CHAIN_RES" = FAIL ] && FAILING="${FAILING:+$FAILING, }chain"
  notify_or_keep urgent "外部見張り: 状態を保存できない (ディスク等)" \
    "$(printf '見張りの状態を保存できず、警報を出せない状態です。\n失敗中の確認: %s\nweb host の空き容量・権限を確認してください。\nvalidator host の外 (web host) から検知' "${FAILING:-なし}")"
fi

printf '%s fresh=%s(%ss) p2p=%s chain=%s pushes=%d\n' "$(iso "$NOW")" \
  "$FRESH_RES" "$FRESH_AGE" "$P2P_RES" "$CHAIN_RES$CHAIN_NOTE" "$PUSHES" >> "$LOG_FILE"
housekeeping || true

[ "$PUSH_FAILED" = "1" ] && exit 6
[ "$STATE_SAVE_FAILED" = "1" ] && exit 7
exit 0
