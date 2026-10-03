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
# WATCH_KEEP_DRAFTS WATCH_MTR WATCH_MTR_TIMEOUT WATCH_STATUS_MAX_BYTES
#
# Public status file (optional): when watch.env sets WATCH_PUBLIC_STATUS to an
# absolute *.json path (the site's api/watch-status.json), every run rewrites
# it from watch.log (last 24 h) plus the current alert state, for the phone
# status page. Host-free by construction (see status_json). Publishing runs
# after every push of the run and in a subshell: it can never block, delay or
# alter an alert, nor change the exit code; a failure is one log note.
#
# `external-watch.sh --classify-mtr < report` prints the path class of an mtr
# report (see classify_mtr) and exits; no config is read.

set -uo pipefail

WATCH_HOME="${WATCH_HOME:-$HOME/metal-fy-watch}"
WATCH_CONFIG="${WATCH_CONFIG:-$WATCH_HOME/etc/watch.env}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="${WATCH_NOTIFY:-$SCRIPT_DIR/notify.sh}"

# --- path classification (pure: mtr report text on stdin -> one line) -------
# classify_mtr reads an `mtr -r -n` report and prints exactly one line:
#   reaches-host                                   the last hop (the target) answers:
#                                                  the path is fine, the problem is
#                                                  on the host or the port
#   provider-edge last_answering_hop=N first_silent_hop=M
#                                                  some hops answer, then every hop
#                                                  from M to the end is silent
#   no-route-at-all                                no hop answers
#   unknown                                        no hop lines (mtr missing, cut
#                                                  off, or unparseable output)
# A hop "answers" when it has an address (not ???) and loss below 100 %.
# 2026-09-24..28 shape: hops inside the provider answered, 100 % loss from the
# first hop outside it to the end -> provider-edge.
# Kept pure (no I/O besides stdin/stdout) so tests feed fixtures through
# `external-watch.sh --classify-mtr < fixture`.
classify_mtr() {
  awk '
    $1 ~ /^[0-9]+\.[|`]/ && NF >= 3 {
      n = $1; sub(/\..*/, "", n)
      loss = $3; sub(/%$/, "", loss)
      h++; idx[h] = n
      ans[h] = ($2 != "???" && loss ~ /^[0-9.]+$/ && loss + 0 < 100) ? 1 : 0
      if (ans[h]) last = h
    }
    END {
      if (h == 0) { print "unknown"; exit }
      if (ans[h]) { print "reaches-host"; exit }
      if (last == 0) { print "no-route-at-all"; exit }
      printf "provider-edge last_answering_hop=%s first_silent_hop=%s\n", idx[last], idx[last + 1]
    }'
}
if [ "${1:-}" = "--classify-mtr" ]; then classify_mtr; exit 0; fi

# --- size caps: shared helpers ---------------------------------------------
# Every file this script writes on the shared host has an upper bound. The
# overrides exist for tests; production runs on the defaults. A value that is
# not a positive integer falls back to the default.
DEFAULT_MAX_BYTES=1048576
DEFAULT_KEEP=10
cap_value() { # env-value default
  if [[ "$1" =~ ^[1-9][0-9]{0,14}$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
file_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
# file_id path -> "<device>:<inode>:<link count>" (GNU stat, BSD fallback). On
# GNU a failed `stat -c` falls through to `stat -f` (file-system status), whose
# output never ends in ":1", so a failure always reads as "refuse".
file_id() { stat -c '%d:%i:%h' "$1" 2>/dev/null || stat -f '%d:%i:%l' "$1" 2>/dev/null; }

# trim_tail file max: when the file exceeds max bytes keep only its newest
# max/2 bytes, cut at a line boundary; if the newest line alone is longer
# than that, its tail is kept verbatim (a partial first line) rather than
# emptying the file. The file is rewritten IN PLACE (cat tmp > file, never
# mv): cron.err is held open with O_APPEND by the cron shell for the whole
# run, and replacing the inode would orphan that descriptor and lose this
# run's stderr. Because the write goes to the inode, the file must be a
# regular file with exactly one link, reached through no symlink (file or
# its directory): a hard link would make the write truncate another file of
# the account. Refusals: symlink -> 0 (silently skipped); link count != 1 ->
# 1 (the caller reports it). Temp files go next to the file (.trim.XXXXXX).
trim_tail() {
  local f="$1" max="$2" d="${1%/*}" id size half raw kept rc=1
  [ -f "$f" ] && [ ! -L "$f" ] && [ ! -L "$d" ] || return 0
  id="$(file_id "$f")"
  [[ "$id" =~ ^[0-9]+:[0-9]+:1$ ]] || return 1
  size="$(file_size "$f")"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  [ "$size" -gt "$max" ] || return 0
  half=$((max / 2))
  raw="$(mktemp "$d/.trim.XXXXXX")" || return 1
  kept="$(mktemp "$d/.trim.XXXXXX")" || { rm -f "$raw"; return 1; }
  # One byte more than half: if it is a newline, the rest starts on a line.
  if tail -c $((half + 1)) "$f" > "$raw" 2>/dev/null; then
    if [ "$(head -c 1 "$raw" | od -An -tx1 | tr -d ' \n')" = "0a" ]; then
      tail -c +2 "$raw" > "$kept"
    else
      tail -n +2 "$raw" > "$kept"
    fi
    # A last line longer than half the cap (or unterminated) would leave
    # nothing: keep the newest half verbatim rather than lose the newest line.
    [ -s "$kept" ] || tail -c "$half" "$f" > "$kept" 2>/dev/null
    # Re-verify immediately before the write (narrows the check-to-write
    # window to this one line): still the same singly linked inode, reached
    # through no symlink. `< kept` is opened first, so a vanished temp can
    # never truncate the file to nothing.
    if [ -s "$kept" ] && [ ! -L "$d" ] && [ ! -L "$f" ] && [ -f "$f" ] \
       && [ "$(file_id "$f")" = "$id" ]; then
      cat < "$kept" > "$f" && rc=0
    fi
  fi
  rm -f "$raw" "$kept"
  return "$rc"
}

# cron.err first, before anything that can exit: a run that dies before
# housekeeping (config error, missing dependency, set -u abort) still keeps
# cron.err bounded. Never creates a directory, never fails the run.
early_trim_cronerr() {
  local d="$WATCH_HOME/log"
  [ -d "$d" ] && [ ! -L "$d" ] || return 0
  trim_tail "$d/cron.err" "$(cap_value "${WATCH_CRONERR_MAX_BYTES:-}" "$DEFAULT_MAX_BYTES")"
}
( early_trim_cronerr ) >/dev/null 2>&1 || true

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
  WATCH_PUBLIC_STATUS=""
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
      # Validated at publish time, not here: a bad value must disable only the
      # status file (one log note per run), never the alerting (exit 1).
      WATCH_PUBLIC_STATUS) WATCH_PUBLIC_STATUS="$val" ;;
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

# --- p2p diagnosis: mtr + provider ticket draft ----------------------------
# Runs only on the transition into a p2p alert (from apply_check, right
# before the alert push), never on the 5-minute runs while still failing.
# The 2026-09-24 outage lasted ~100 h because nobody escalated; the draft is
# ready to paste into the provider's "Public Network issue" ticket.
#
# Same command shape as web_mtr_capture in scripts/lib/web-probe.sh (that lib
# is not shipped to the web host by the installer, so the few lines are
# mirrored here). mtr needs the target in its argv for the ~5-25 s it runs;
# the draft file necessarily holds the raw report (addresses), so it is
# mode 600 in the 700 log/ dir and never pushed. The push carries only the
# class, hop indices and the draft's file name.
#
# Sets DIAG_LINE (Japanese, host-free) for the alert body. Never fails.
DIAG_LINE=""
mtr_capture() { # outfile
  local out="$1" mtr="${WATCH_MTR:-mtr}" rc=0
  {
    if ! command -v "$mtr" >/dev/null 2>&1; then
      echo "mtr unavailable (not installed)"
    else
      # -k 5: an mtr that ignores SIGTERM is SIGKILLed 5 s later, so it can
      # never hold the run's flock (GNU coreutils and busybox both take -k).
      timeout -k 5 "${WATCH_MTR_TIMEOUT:-25}" "$mtr" -r -n -c 5 -w "$VALIDATOR_HOST" 2>&1 || rc=$?
      [ "$rc" -eq 0 ] || echo "(mtr exited rc=${rc}; 124 = cut off by timeout ${WATCH_MTR_TIMEOUT:-25}s, 137 = killed after ignoring it)"
    fi
  } > "$out" 2>/dev/null || true
  return 0
}

p2p_diagnose() { # first_fail_epoch
  local first="$1" raw class ts name tmp max mtrnote=""
  DIAG_LINE=""
  if [ "$LIVE" != "1" ]; then
    echo "DRY: would capture mtr and write a ticket draft" >&2
    DIAG_LINE="経路 (mtr): DRY のため未取得"
    return 0
  fi
  raw="$(mktemp "$LOG_DIR/.trim.XXXXXX")" || { DIAG_LINE="経路 (mtr): 取得失敗 (一時ファイル)"; return 0; }
  mtr_capture "$raw"
  class="$(classify_mtr < "$raw")"
  grep -q '^mtr unavailable' "$raw" 2>/dev/null && mtrnote=" (mtr unavailable)"
  local hop_n hop_m
  hop_n="$(sed -n 's/.*last_answering_hop=\([0-9]*\).*/\1/p' <<<"$class")"
  hop_m="$(sed -n 's/.*first_silent_hop=\([0-9]*\).*/\1/p' <<<"$class")"
  case "$class" in
    provider-edge*)
      DIAG_LINE="$(printf '経路 (mtr): provider-edge — 応答する最後の hop %s / 無応答の最初の hop %s (以降すべて無応答)' "$hop_n" "$hop_m")" ;;
    reaches-host) DIAG_LINE="経路 (mtr): reaches-host — 経路は届いている (host/port 側の問題)" ;;
    no-route-at-all) DIAG_LINE="経路 (mtr): no-route-at-all — どの hop も応答なし" ;;
    *) DIAG_LINE="経路 (mtr): unknown${mtrnote}" ;;
  esac
  ts="$(jq -nr --argjson t "$NOW" '$t | strftime("%Y%m%dT%H%M%SZ")')"
  name="ticket-draft-$ts.txt"
  max="$(cap_value "${WATCH_LOG_MAX_BYTES:-}" "$DEFAULT_MAX_BYTES")"
  tmp="$(mktemp "$LOG_DIR/.trim.XXXXXX")" || { rm -f "$raw"; DIAG_LINE="$DIAG_LINE"$'\n'"下書き: 作成失敗"; return 0; }
  # The cap closes the pipe early on an oversized report, so the writer side
  # may die of SIGPIPE; under pipefail that would read as a failed write.
  # Only head's status (the actual write to the file) decides.
  local hrc
  {
       # The trace runs from a third-party vantage point (the web host) toward
       # the validator host and the classifier knows no ASNs, so the draft
       # states only what the report shows; it never asserts whose network
       # the silent section is in, nor anything about the server it did not
       # measure (the operator confirms that before sending).
       case "$class" in
         reaches-host)
           printf '*** PROBABLY NOT A NETWORK TICKET (operator: read before sending) ***\n'
           printf 'The server answers ICMP from our external vantage point, so the network path\n'
           printf 'looks fine and the issue is likely at the host or port level (metalgo, firewall).\n'
           printf 'Check the host first; send this only if that rules the host out.\n\n' ;;
         provider-edge*) ;;
         *)
           printf '*** operator: the trace does not locate the break; check the web host'"'"'s own\n'
           printf 'network and the provider console before sending ***\n\n' ;;
       esac
       printf 'Subject: Public Network issue - server unreachable from our external monitor\n\n'
       printf 'Hello,\n\n'
       printf 'Our external monitor, which probes the server from another network every\n'
       printf '5 minutes, has been unable to connect to it since %s (UTC, first failed check).\n' "$(iso "$first")"
       printf '[operator: confirm no changes were made to the server]\n\n'
       printf 'Path classification: %s%s\n' "$class" "$mtrnote"
       case "$class" in
         provider-edge*)
           printf 'From an external vantage point, hops answer up to hop %s and are silent from\n' "$hop_n"
           printf 'hop %s onward, through to the server.\n\n' "$hop_m" ;;
         reaches-host)
           printf 'From an external vantage point, the server itself answers ICMP.\n\n' ;;
         no-route-at-all)
           printf 'From an external vantage point, no hop answered.\n\n' ;;
         *)
           printf 'The trace from our external vantage point produced no usable hop lines.\n\n' ;;
       esac
       printf 'mtr report from our external monitor (%s UTC):\n\n' "$(iso "$NOW")"
       cat "$raw"
       case "$class" in
         provider-edge*) printf '\nCould you please check the upstream path toward this server?\n' ;;
         *) printf '\nCould you please check whether this server is reachable from your side?\n' ;;
       esac
       printf 'Thank you.\n'
     } 2>/dev/null | head -c "$max" > "$tmp"
  hrc="${PIPESTATUS[1]}"
  if [ "$hrc" -eq 0 ] && chmod 600 "$tmp" && mv "$tmp" "$LOG_DIR/$name"; then
    DIAG_LINE="$DIAG_LINE"$'\n'"下書き: ${WATCH_HOME##*/}/log/$name (Public Network issue チケット用)"
  else
    rm -f "$tmp"
    DIAG_LINE="$DIAG_LINE"$'\n'"下書き: 作成失敗"
  fi
  rm -f "$raw"
  log_note "p2p diagnosis: $class$mtrnote, draft $name"
  return 0
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
        # p2p: diagnose the path once, on the transition (a held-back push
        # would be retried next run anyway, so skip the work when blocked).
        if [ "$check" = p2p ] && [ "$SAVE_BLOCKED" != "1" ]; then
          p2p_diagnose "$first"
          body="$body"$'\n'"$DIAG_LINE"
        fi
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

# --- public status file ---------------------------------------------------
# /api/watch-status.json for the phone status page (contract: schema 1):
#   {"schema":1,"generated_at":ISO,"interval_sec":300,
#    "last":{"t":ISO,"fresh":b,"p2p":b,"chain":b,"alerting":[names]},
#    "checks":[{"t":ISO,"fresh":b,"p2p":b,"chain":b}, ...]}  last 24 h, oldest first
# A check is false only when the watch logged FAIL; UNKNOWN (renewal window,
# RPC unavailable) is not a failure for the watch either, so it reads true.
# "alerting" = checks whose state status is "alerting" after this run.
# Built ONLY from the log line's fixed tokens (time + PASS/FAIL/UNKNOWN) and
# the check names: no host, address, topic, mtr text, ticket or log path can
# reach it. Note lines and anything not matching the exact format are skipped.
STATUS_INTERVAL=300
STATUS_WINDOW=86400
STATUS_MAX_CHECKS=400   # 24 h at 5 min = 288; headroom for manual runs
DEFAULT_STATUS_MAX_BYTES=262144
status_json() {
  local alerting
  alerting="$(jq -c '[("fresh","p2p","chain") as $c | select(.[$c].status == "alerting") | $c]' <<<"$STATE")" \
    || return 1
  jq -R -n -c --argjson now "$NOW" --argjson win "$STATUS_WINDOW" --argjson iv "$STATUS_INTERVAL" \
    --argjson max "$STATUS_MAX_CHECKS" --argjson alerting "$alerting" '
    [ inputs
      | capture("^(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) fresh=(?<f>PASS|FAIL|UNKNOWN)\\([^)]*\\) p2p=(?<p>PASS|FAIL|UNKNOWN) chain=(?<c>PASS|FAIL|UNKNOWN)(\\(cached\\))? pushes=[0-9]+$")?
      | (.t | fromdateiso8601) as $e
      | select($e > $now - $win and $e <= $now)
      | {t: .t, fresh: (.f != "FAIL"), p2p: (.p != "FAIL"), chain: (.c != "FAIL")} ]
    | sort_by(.t) | .[-$max:]
    | if length == 0 then error("no checks in window") else . end
    | {schema: 1, generated_at: ($now | todate), interval_sec: $iv,
       last: (.[-1] + {alerting: $alerting}), checks: .}' < "$LOG_FILE"
}

# publish_status: write WATCH_PUBLIC_STATUS atomically (temp in the same dir,
# mode 644, rename). Same file-safety stance as trim_tail: the directory must
# not be a symlink, and an existing target must be a regular, singly linked
# file (re-checked right before the rename). Returns non-zero on any refusal
# or failure; the caller turns that into one log note.
publish_status() {
  local out="$WATCH_PUBLIC_STATUS" d tmp max json
  [[ "$out" =~ ^/[A-Za-z0-9._/-]+\.json$ ]] || return 1
  case "$out" in */../*|*/./*|*//*) return 1 ;; esac
  d="${out%/*}"; [ -n "$d" ] || return 1
  target_ok() {
    [ -d "$d" ] && [ ! -L "$d" ] || return 1
    if [ -e "$out" ] || [ -L "$out" ]; then
      [ -f "$out" ] && [ ! -L "$out" ] && [[ "$(file_id "$out")" =~ ^[0-9]+:[0-9]+:1$ ]] || return 1
    fi
  }
  target_ok || return 1
  max="$(cap_value "${WATCH_STATUS_MAX_BYTES:-}" "$DEFAULT_STATUS_MAX_BYTES")"
  json="$(status_json)" || return 1
  [ -n "$json" ] && [ "$(printf '%s\n' "$json" | wc -c | tr -d ' ')" -le "$max" ] || return 1
  # A killed run's temp (exact mktemp shape, regular files only). Runs under
  # the lock; nothing else writes this name.
  find "$d" -maxdepth 1 -type f -name '.watch-status.??????' -delete 2>/dev/null
  tmp="$(mktemp "$d/.watch-status.XXXXXX")" || return 1
  if printf '%s\n' "$json" > "$tmp" && chmod 644 "$tmp" && target_ok && mv -f "$tmp" "$out"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# --- housekeeping (size caps) --------------------------------------------
# cap_value / file_size / file_id / trim_tail and the defaults live at the top
# of the script (the cron.err trim runs before the config is parsed).
file_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null; }

# prune_dir dir pattern keep: delete all but the newest KEEP regular files
# (not symlinks, not directories) directly inside dir whose name matches
# pattern. The deletions run inside a subshell that has changed into dir and
# verified that it really is <physical parent>/<name> (not a symlink swapped
# in after the listing), and they remove "./<name>", so a race can at most
# make the prune refuse, never delete in another directory.
prune_dir() {
  local dir="$1" pat="$2" keep="$3" list ordered f m parent want rc=0
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  parent="${dir%/*}"; [ -n "$parent" ] || parent=/
  parent="$(cd -P -- "$parent" 2>/dev/null && pwd -P)" || return 1
  want="${parent%/}/${dir##*/}"
  list="$(mktemp "$LOG_DIR/.trim.XXXXXX")" || return 1
  ordered="$(mktemp "$LOG_DIR/.trim.XXXXXX")" || { rm -f "$list"; return 1; }
  if ! find "$dir" -maxdepth 1 -type f -name "$pat" -print0 > "$list" 2>/dev/null; then
    rm -f "$list" "$ordered"; return 1
  fi
  while IFS= read -r -d '' f; do
    case "$f" in *$'\n'*|*$'\t'*) continue ;; esac   # never act on odd names (the tab is our field separator)
    m="$(file_mtime "$f")"; [[ "$m" =~ ^[0-9]+$ ]] || continue
    printf '%s\t%s\n' "$m" "$f"
  done < "$list" | sort -t $'\t' -k1,1nr -k2,2r > "$ordered"
  tail -n +$((keep + 1)) "$ordered" | (
    cd -P -- "$dir" 2>/dev/null && [ "$(pwd -P)" = "$want" ] || exit 1
    r=0
    while IFS=$'\t' read -r _ f; do
      rm -f -- "./${f##*/}" || r=1
    done
    exit "$r"
  ) || rc=1
  rm -f "$list" "$ordered"
  return "$rc"
}

# Housekeeping must never change alerting or the exit code: every failure is
# folded into one host-free note line.
housekeeping() {
  local max_log max_err keep_bak keep_cor keep_drf bad=0
  max_log="$(cap_value "${WATCH_LOG_MAX_BYTES:-}" "$DEFAULT_MAX_BYTES")"
  max_err="$(cap_value "${WATCH_CRONERR_MAX_BYTES:-}" "$DEFAULT_MAX_BYTES")"
  keep_bak="$(cap_value "${WATCH_KEEP_BACKUPS:-}" "$DEFAULT_KEEP")"
  keep_cor="$(cap_value "${WATCH_KEEP_CORRUPT:-}" "$DEFAULT_KEEP")"
  keep_drf="$(cap_value "${WATCH_KEEP_DRAFTS:-}" "$DEFAULT_KEEP")"
  # A run killed mid-write leaves its temp files behind; sweep exactly the
  # name shapes this script creates (mktemp's 6-character suffix), regular
  # files only, so symlinks are never followed. -delete unlinks relative to
  # the directory find walked. This runs under the lock; every state/ temp is
  # created under the lock, so no running instance's state/ temp is hit. The
  # early cron.err trim of an overlapping run creates log/ temps outside the
  # lock; if this sweep removes them, that trim refuses or keeps the verbatim
  # tail (trim_tail never writes an empty file) — nothing outside log/ is hit.
  find "$LOG_DIR" -maxdepth 1 -type f -name '.trim.??????' -delete 2>/dev/null || bad=1
  find "$STATE_DIR" -maxdepth 1 -type f \( -name 'state.??????' -o -name 'rpc-cache.??????' \) \
    -delete 2>/dev/null || bad=1
  trim_tail "$LOG_FILE" "$max_log" 2>/dev/null || bad=1
  trim_tail "$LOG_DIR/cron.err" "$max_err" 2>/dev/null || bad=1
  # Only the names the installer writes there (<file>.bak-<timestamp>).
  prune_dir "$WATCH_HOME/backup" '*.bak-*' "$keep_bak" 2>/dev/null || bad=1
  prune_dir "$STATE_DIR" 'state.json.corrupt-*' "$keep_cor" 2>/dev/null || bad=1
  # p2p ticket drafts (log/ticket-draft-<UTC>.txt): newest 10; each is capped
  # at the watch.log size cap when written.
  prune_dir "$LOG_DIR" 'ticket-draft-*.txt' "$keep_drf" 2>/dev/null || bad=1
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
# After every push of this run, in a subshell: cannot delay or alter an alert,
# cannot change the exit code; a failure is one host-free note.
if [ -n "$WATCH_PUBLIC_STATUS" ]; then
  ( publish_status ) >/dev/null 2>&1 || log_note "status publish failed" 2>/dev/null
fi
housekeeping || true

[ "$PUSH_FAILED" = "1" ] && exit 6
[ "$STATE_SAVE_FAILED" = "1" ] && exit 7
exit 0
