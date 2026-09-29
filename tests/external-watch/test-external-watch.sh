#!/usr/bin/env bash
# tests/external-watch/test-external-watch.sh
#
# scripts/external-watch.sh — off-host watchdog. Every external boundary is
# stubbed: curl (public RPC), notify (WATCH_NOTIFY), sleep, and timeout (to
# make the first p2p probe fail). The p2p probe itself runs against a real
# loopback listener / a closed loopback port. WATCH_LIVE=1 is only ever set
# together with the stub notifier, so nothing is ever sent for real.
# No GNU date dependency: the script uses jq for all time conversion.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${WATCH_SCRIPT_UNDER_TEST:-$REPO/scripts/external-watch.sh}"
TMP="$(mktemp -d)"
LISTENER_PID=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() { [ -n "$LISTENER_PID" ] && { kill "$LISTENER_PID"; wait "$LISTENER_PID"; } 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# A SKIP must never read as green in CI (GitHub sets CI=true): there a
# missing tool is a failure, locally it is a loud SKIP.
skip_or_fail() {
  if [ -n "${CI:-}" ]; then echo "FAIL: $1 (CI must run this suite)"; exit 1; fi
  echo "SKIP: $1"; exit 0
}
for t in jq python3 timeout; do
  command -v "$t" >/dev/null 2>&1 || skip_or_fail "$t not available"
done
REAL_TIMEOUT="$(command -v timeout)"

PASS=0; FAIL=0; FAILURES=()
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1 ($2)"); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected='$2' actual='$3'"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing '$2' in '$3'" ;; esac; }
absent() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "exists: $2"; fi; }
count_files() { find "$1" -maxdepth 1 -name "$2" | wc -l | tr -d " "; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "unexpected '$2' in '$3'" ;; *) ok "$1" ;; esac; }

# --- stubs ----------------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CURL_LOG"
n=0; [ -s "$STUB_CURL_COUNTER" ] && n=$(cat "$STUB_CURL_COUNTER")
printf '%s' "$((n + 1))" > "$STUB_CURL_COUNTER"
printf '%s' "${STUB_CURL_BODY:-}"
exit "${STUB_CURL_RC:-0}"
STUB
cat > "$BIN/notify" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tr '\n' '\001' >> "$STUB_NOTIFY_LOG"; printf '\n' >> "$STUB_NOTIFY_LOG"
exit "${STUB_NOTIFY_RC:-0}"
STUB
cat > "$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_SLEEP_LOG"
STUB
cat > "$BIN/timeout" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${STUB_TIMEOUT_ARGV_LOG:-/dev/null}"
# STUB_TIMEOUT_FAIL_FIRST=1: the first invocation (first p2p probe) fails.
if [ "\${STUB_TIMEOUT_FAIL_FIRST:-0}" = 1 ]; then
  n=0; [ -s "\$STUB_TIMEOUT_COUNTER" ] && n=\$(cat "\$STUB_TIMEOUT_COUNTER")
  printf '%s' "\$((n + 1))" > "\$STUB_TIMEOUT_COUNTER"
  [ "\$n" = 0 ] && exit 1
fi
exec "$REAL_TIMEOUT" "\$@"
STUB
# No real flock (e.g. macOS dev box): a no-op stub lets every non-lock case run;
# only the real lock-contention case needs the real thing and SKIPs loudly.
HAVE_REAL_FLOCK=0
if command -v flock >/dev/null 2>&1; then HAVE_REAL_FLOCK=1; else
  printf '#!/bin/sh\nexit 0\n' > "$BIN/flock"
fi
chmod +x "$BIN"/*

# --- loopback listener / closed port -----------------------------------------
python3 - "$TMP/port" > /dev/null <<'PY' &
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(16)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
s.settimeout(1)
end = time.time() + 300
while time.time() < end:
    try: c, _ = s.accept(); c.close()
    except Exception: pass
PY
LISTENER_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; /bin/sleep 0.1; done
OPEN_PORT="$(cat "$TMP/port")"
CLOSED_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"

# --- case fixtures ------------------------------------------------------------
NOW=1790000000
FAKE_NODE="NodeID-TestFakeNode111"
BODY_CONNECTED='{"result":{"validators":[{"nodeID":"'$FAKE_NODE'","connected":true}]}}'
BODY_DISCONNECTED='{"result":{"validators":[{"nodeID":"'$FAKE_NODE'","connected":false}]}}'
BODY_ABSENT='{"result":{"validators":[]}}'

new_case() { # sets C, HOMEDIR; p2p defaults to the open port
  C="$(mktemp -d "$TMP/case.XXXXXX")"
  mkdir -p "$C/etc"
  printf 'fy-test-topic\n' > "$C/topic"; chmod 600 "$C/topic"
  P2P_PORT="$OPEN_PORT"
  write_config
  : > "$C/notify.log"; : > "$C/sleep.log"; : > "$C/curl.log"; : > "$C/timeout.argv"; rm -f "$C/curl.count" "$C/timeout.count"
  JSON_AGE=""; JSON_END=""; RPC_BODY="$BODY_CONNECTED"; RPC_RC=0; NOTIFY_RC=0; LIVE=1; FAIL_FIRST=0; EXTRA_PATH=""
}
write_config() {
  cat > "$C/etc/watch.env" <<CFG
# test config
VALIDATOR_HOST=127.0.0.1
VALIDATOR_P2P_PORT=$P2P_PORT

VALIDATOR_JSON=$C/validator.json
NTFY_TOPIC_FILE=$C/topic
NODE_ID=$FAKE_NODE
RPC_URL=https://rpc.invalid/ext/bc/P
CFG
}
make_json() { # age_seconds [endTime]  (age is re-applied relative to each run's clock)
  JSON_AGE="$1"; JSON_END="${2:-}"; write_json "$NOW"
}
write_json() {
  [ -n "$JSON_AGE" ] || return 0
  local obs; obs="$(jq -nr --argjson t "$(($1 - JSON_AGE))" '$t|todate')"
  if [ -n "$JSON_END" ]; then
    printf '{"observedAt":"%s","endTime":%s}\n' "$obs" "$JSON_END" > "$C/validator.json"
  else
    printf '{"observedAt":"%s"}\n' "$obs" > "$C/validator.json"
  fi
}
run_watch() { # [NOW override]; sets RC, ERR
  local now="${1:-$NOW}"
  write_json "$now"
  local live_env=(); [ "$LIVE" = 1 ] && live_env=(WATCH_LIVE=1)
  ERR="$(env ${live_env[@]+"${live_env[@]}"} PATH="${EXTRA_PATH:+$EXTRA_PATH:}$BIN:$PATH" WATCH_HOME="$C/home" WATCH_CONFIG="$C/etc/watch.env" \
    WATCH_NOTIFY="$BIN/notify" WATCH_NOW_EPOCH="$now" P2P_REPROBE_SLEEP=7 WATCH_NOTIFY_RETRY_SLEEP=5 \
    STUB_CURL_LOG="$C/curl.log" STUB_CURL_COUNTER="$C/curl.count" STUB_CURL_BODY="$RPC_BODY" STUB_CURL_RC="$RPC_RC" \
    STUB_NOTIFY_LOG="$C/notify.log" STUB_NOTIFY_RC="$NOTIFY_RC" STUB_SLEEP_LOG="$C/sleep.log" \
    STUB_TIMEOUT_FAIL_FIRST="$FAIL_FIRST" STUB_TIMEOUT_COUNTER="$C/timeout.count" STUB_TIMEOUT_ARGV_LOG="$C/timeout.argv" \
    bash "$SCRIPT" 2>&1 >/dev/null)"
  RC=$?
}
pushes() { grep -c . "$C/notify.log"; }
last_log() { tail -n 1 "$C/home/log/watch.log" 2>/dev/null; }
st() { jq -r ".$1.$2" "$C/home/state/state.json" 2>/dev/null; }
curl_calls() { grep -c . "$C/curl.log"; }

# ============================ 1. config ============================
echo "== config parser =="
new_case; MARK="$C/pwned"
for bad_line in "VALIDATOR_JSON=$MARK\$(touch $MARK).json" 'VALIDATOR_JSON=/x`touch '"$MARK"'`' "VALIDATOR_JSON=/x;touch $MARK" "EVIL=\$(touch $MARK)" 'EVIL=`touch '"$MARK"'`' "VALIDATOR_HOST=127.0.0.1;touch $MARK" "X=a|b" "X=a&b" "X=a>b"; do
  new_case
  printf '%s\n' "$bad_line" >> "$C/etc/watch.env"; make_json 10
  run_watch
  assert_eq "reject injection line: ${bad_line:0:20}" "1" "$RC"
  absent "  not executed" "$MARK"
  assert_eq "  no push on config error" "0" "$(pushes)"
done
new_case; echo 'SURPRISE_KEY=1' >> "$C/etc/watch.env"; make_json 10; run_watch
assert_eq "unknown key rejected" "1" "$RC"
assert_contains "  names the key" "SURPRISE_KEY" "$ERR"
new_case; chmod 644 "$C/topic"; make_json 10; run_watch
assert_eq "topic file mode 644 rejected" "1" "$RC"
new_case; chmod 400 "$C/topic"; make_json 10; run_watch
assert_eq "topic file mode 400 accepted" "0" "$RC"
new_case; grep -v '^VALIDATOR_HOST' "$C/etc/watch.env" > "$C/x" && mv "$C/x" "$C/etc/watch.env"; make_json 10; run_watch
assert_eq "missing VALIDATOR_HOST rejected" "1" "$RC"
new_case; chmod 644 "$C/topic"; make_json 10; run_watch
absent "loose topic file: no probe ran (no state)" "$C/home/state/state.json"
assert_eq "  no curl call either" "0" "$(curl_calls)"

# ============================ 2. fresh ============================
echo "== fresh =="
new_case; make_json 100; run_watch
assert_eq "fresh PASS rc" "0" "$RC"
assert_contains "fresh PASS log" "fresh=PASS(100s)" "$(last_log)"
new_case; make_json 900; run_watch
assert_contains "age == 900 is PASS (strictly greater)" "fresh=PASS(900s)" "$(last_log)"
new_case; make_json 901; run_watch
assert_contains "age 901 is FAIL" "fresh=FAIL(901s)" "$(last_log)"
assert_eq "  fail counter 1, no push yet" "1|0" "$(st fresh fails)|$(pushes)"
new_case; run_watch
assert_contains "missing file is FAIL" "fresh=FAIL" "$(last_log)"
new_case; echo 'not json' > "$C/validator.json"; run_watch
assert_contains "unparseable is FAIL" "fresh=FAIL" "$(last_log)"
new_case; echo '{"other":1}' > "$C/validator.json"; run_watch
assert_contains "observedAt missing is FAIL" "fresh=FAIL" "$(last_log)"
new_case; echo '{"observedAt":"garbage"}' > "$C/validator.json"; run_watch
assert_contains "observedAt unparseable is FAIL" "fresh=FAIL" "$(last_log)"
new_case; make_json 5000 "$((NOW + 100))"; run_watch; run_watch "$((NOW + 300))"
assert_contains "renewal window: stale is UNKNOWN" "fresh=UNKNOWN(5000s)" "$(head -n 1 "$C/home/log/watch.log")"
assert_eq "  counter untouched, no push" "0|0" "$(st fresh fails)|$(pushes)"
new_case; make_json 5000 "$((NOW + 1800))"; run_watch
assert_contains "window lower bound inclusive (end-1800)" "fresh=UNKNOWN" "$(last_log)"
new_case; make_json 5000 "$((NOW + 1801))"; run_watch
assert_contains "just before window is FAIL" "fresh=FAIL" "$(last_log)"
new_case; make_json 30000 "$((NOW - 21600))"; run_watch
assert_contains "window upper bound inclusive (end+21600)" "fresh=UNKNOWN" "$(last_log)"
new_case; make_json 30000 "$((NOW - 21601))"; run_watch
assert_contains "just after window is FAIL" "fresh=FAIL" "$(last_log)"

# ============================ 3. p2p ============================
echo "== p2p =="
new_case; make_json 10; run_watch
assert_contains "p2p PASS against listener" "p2p=PASS" "$(last_log)"
assert_eq "  no re-probe sleep (sleep never called)" "" "$(cat "$C/sleep.log")"
assert_eq "  probe ran (timeout called)" "1" "$(grep -c . "$C/timeout.argv")"
assert_not_contains "  host not in the probe's argv" "127.0.0.1" "$(cat "$C/timeout.argv")"
assert_not_contains "  port not in the probe's argv" "$OPEN_PORT" "$(cat "$C/timeout.argv")"
new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; run_watch
assert_contains "p2p FAIL against closed port" "p2p=FAIL" "$(last_log)"
assert_eq "  re-probe waited P2P_REPROBE_SLEEP once" "7" "$(cat "$C/sleep.log")"
new_case; FAIL_FIRST=1; make_json 10; run_watch
assert_contains "first probe fails, re-probe passes => PASS" "p2p=PASS" "$(last_log)"
assert_eq "  probe attempted twice" "2" "$(cat "$C/timeout.count")"

# ============================ 4. chain ============================
echo "== chain =="
new_case; make_json 10; RPC_BODY="$BODY_DISCONNECTED"; run_watch
assert_contains "connected=false is FAIL" "chain=FAIL" "$(last_log)"
new_case; make_json 10; run_watch
assert_contains "connected=true is PASS" "chain=PASS" "$(last_log)"
assert_contains "  request filters by nodeIDs" "nodeIDs" "$(cat "$C/curl.log")"
assert_contains "  request has max-time 10" "--max-time 10" "$(cat "$C/curl.log")"
assert_contains "  request pinned to https" "--proto =https" "$(cat "$C/curl.log")"
assert_contains "  response size capped" "--max-filesize 1048576" "$(cat "$C/curl.log")"
new_case; make_json 10; RPC_RC=28; RPC_BODY=""; run_watch
assert_contains "curl error is UNKNOWN" "chain=UNKNOWN" "$(last_log)"
assert_eq "  no counter change" "0" "$(st chain fails)"
new_case; make_json 10; RPC_BODY='<html>oops'; run_watch
assert_contains "invalid JSON is UNKNOWN" "chain=UNKNOWN" "$(last_log)"
absent "  invalid response not cached" "$C/home/state/rpc-cache.json"
new_case; make_json 10; RPC_BODY='{"error":{"code":-1}}'; run_watch
assert_contains "RPC error object is UNKNOWN" "chain=UNKNOWN" "$(last_log)"
absent "  RPC error object not cached" "$C/home/state/rpc-cache.json"
new_case; make_json 10; RPC_BODY="$BODY_ABSENT"; run_watch
assert_contains "validator absent is UNKNOWN" "chain=UNKNOWN" "$(last_log)"
assert_eq "  no counter change" "0" "$(st chain fails)"
new_case; make_json 10; run_watch; make_json 10; run_watch "$((NOW + 899))"
assert_eq "cache honoured within 900 s (1 curl call)" "1" "$(curl_calls)"
make_json 10; run_watch "$((NOW + 900))"
assert_eq "cache expired at 900 s (2 curl calls)" "2" "$(curl_calls)"
new_case; make_json 10; mkdir -p "$C/home/state"
printf '%s\n' "$(jq -c --argjson t "$((NOW + 1000))" '. + {fetchedAt:$t}' <<<"$BODY_DISCONNECTED")" > "$C/home/state/rpc-cache.json"
run_watch
assert_eq "cache stamped in the future is ignored (fresh RPC call)" "1" "$(curl_calls)"
assert_contains "  and the fresh sample is used" "chain=PASS" "$(last_log)"

# ============================ 5. 2-consecutive + push ============================
echo "== 2-consecutive rule =="
new_case; make_json 10; RPC_BODY="$BODY_DISCONNECTED"
run_watch; assert_eq "run 1: no push" "0" "$(pushes)"
run_watch "$((NOW + 900))"; assert_eq "run 2 (new observation): exactly one push" "1" "$(pushes)"
assert_contains "  urgent + chain title" "urgent" "$(cat "$C/notify.log")"
assert_contains "  chain title text" "外部見張り: ネットワーク上で未接続 (connected=false)" "$(cat "$C/notify.log")"
assert_eq "  status alerting" "alerting" "$(st chain status)"
run_watch "$((NOW + 1200))"; assert_eq "run 3 (cached): no second push" "1" "$(pushes)"
assert_eq "  cached sample not counted again" "2" "$(st chain fails)"
assert_eq "  state file mode 600" "600" "$( (stat -c %a "$C/home/state/state.json" 2>/dev/null || stat -f %Lp "$C/home/state/state.json"))"
assert_eq "  no temp leftovers in state dir" "0" "$(count_files "$C/home/state" 'state.??????')"

echo "== cached observation counts once =="
new_case; make_json 10; RPC_BODY="$BODY_DISCONNECTED"
run_watch; run_watch "$((NOW + 300))"; run_watch "$((NOW + 600))"
assert_eq "one cached false sample over 3 runs: no push" "0" "$(pushes)"
assert_eq "  counted once" "1" "$(st chain fails)"
assert_contains "  log marks it cached" "chain=FAIL(cached)" "$(last_log)"
run_watch "$((NOW + 900))"
assert_eq "second distinct false observation: push" "1" "$(pushes)"
new_case; make_json 10; RPC_BODY="$BODY_DISCONNECTED"
run_watch; run_watch "$((NOW + 900))"; RPC_BODY="$BODY_CONNECTED"; run_watch "$((NOW + 1000))"
assert_eq "cached FAIL then no recovery from stale cache" "alerting" "$(st chain status)"
run_watch "$((NOW + 1800))"
assert_eq "new PASS observation recovers" "ok" "$(st chain status)"

new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10
run_watch; run_watch "$((NOW + 300))"
assert_contains "p2p push title" "外部見張り: validator に外から届かない" "$(cat "$C/notify.log")"
new_case; make_json 901
run_watch; run_watch "$((NOW + 300))"
assert_contains "fresh push is high with its title" "high	外部見張り: validator.json の更新が止まっている" "$(tr '\001' ' ' < "$C/notify.log" | sed 's/^/&/')"

echo "== recovery =="
new_case; RPC_BODY="$BODY_DISCONNECTED"
make_json 10; run_watch; make_json 10; run_watch "$((NOW + 900))"
RPC_BODY="$BODY_CONNECTED"
make_json 10; run_watch "$((NOW + 1800))"
assert_eq "recovery push sent (2 pushes total)" "2" "$(pushes)"
assert_contains "  recovery title" "外部見張り: 復旧 (chain)" "$(cat "$C/notify.log")"
assert_contains "  default priority" "default" "$(tail -n 1 "$C/notify.log")"
assert_contains "  duration 30分 (no hours)" "30分" "$(tail -n 1 "$C/notify.log")"
assert_not_contains "  no '0時間'" "0時間" "$(tail -n 1 "$C/notify.log")"
assert_eq "  state reset" "ok|0" "$(st chain status)|$(st chain fails)"
make_json 10; run_watch "$((NOW + 2100))"
assert_eq "  no repeat recovery" "2" "$(pushes)"
new_case; RPC_BODY="$BODY_DISCONNECTED"
make_json 10; run_watch; make_json 10; run_watch "$((NOW + 900))"
RPC_BODY="$BODY_CONNECTED"; make_json 10; run_watch "$((NOW + 7500))"
assert_contains "  duration 2時間5分" "2時間5分" "$(tail -n 1 "$C/notify.log")"
assert_contains "  since (UTC ISO)" "$(jq -nr --argjson t "$NOW" '$t|todate')" "$(tail -n 1 "$C/notify.log")"
new_case; make_json 10; RPC_BODY="$BODY_DISCONNECTED"; run_watch
RPC_BODY="$BODY_CONNECTED"; make_json 10; run_watch "$((NOW + 1000))"
assert_eq "PASS after 1 fail (never alerted): no push, counter reset" "0|0" "$(pushes)|$(st chain fails)"
new_case; make_json 10; RPC_BODY="$BODY_DISCONNECTED"; run_watch; RPC_BODY="$BODY_ABSENT"; make_json 10; run_watch "$((NOW + 1000))"
assert_eq "UNKNOWN between fails leaves counter (still 1)" "1" "$(st chain fails)"

# ============================ 6. push failure ============================
echo "== push failure =="
new_case; make_json 10; RPC_BODY="$BODY_DISCONNECTED"; NOTIFY_RC=3
run_watch; run_watch "$((NOW + 900))"
assert_eq "permanent failure exits 6" "6" "$RC"
assert_eq "  state not advanced (still ok)" "ok" "$(st chain status)"
assert_eq "  4xx not retried (1 attempt)" "1" "$(pushes)"
NOTIFY_RC=0; make_json 10; run_watch "$((NOW + 1200))"
assert_eq "  next run (cached sample) retries the push and succeeds" "0" "$RC"
assert_eq "  now alerting" "alerting" "$(st chain status)"
new_case; make_json 10; RPC_BODY="$BODY_DISCONNECTED"; NOTIFY_RC=2
run_watch; run_watch "$((NOW + 900))"
assert_eq "transport failure retried once (2 attempts)" "2" "$(pushes)"
assert_contains "  retry waited 5 s" "5" "$(cat "$C/sleep.log")"
assert_eq "  exit 6" "6" "$RC"

echo "== recovery push failure keeps alerting =="
new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10
run_watch; run_watch "$((NOW + 300))"
assert_eq "p2p alerting after 2 fails" "alerting" "$(st p2p status)"
P2P_PORT="$OPEN_PORT"; write_config; NOTIFY_RC=3
run_watch "$((NOW + 600))"
assert_eq "failed recovery push: exit 6" "6" "$RC"
assert_eq "  status still alerting (not cleared)" "alerting" "$(st p2p status)"
NOTIFY_RC=0; run_watch "$((NOW + 900))"
assert_eq "  next PASS retries the recovery push" "外部見張り: 復旧 (p2p)" "$(tail -n 1 "$C/notify.log" | cut -f2)"
assert_eq "  and only then clears" "ok|0" "$(st p2p status)|$(st p2p fails)"

echo "== state cannot be saved (B2) =="
# A state dir the watch can no longer write to (disk full, quota, perms).
# chmod is stubbed so the watch's own `chmod 700 state` cannot undo it.
if [ "$(id -u)" = 0 ]; then
  [ -n "${CI:-}" ] && bad "state-save case" "root ignores dir modes; run as non-root in CI"
  echo "  SKIP  state-save failure (root ignores directory modes)"
else
  NOCHMOD="$TMP/nochmod"; mkdir -p "$NOCHMOD"; printf '#!/bin/sh\nexit 0\n' > "$NOCHMOD/chmod"; chmod +x "$NOCHMOD/chmod"
  new_case; make_json 10                      # every check PASSes: the only push is the save alert
  run_watch                                   # creates state/ and the lock file
  chmod 500 "$C/home/state"; EXTRA_PATH="$NOCHMOD"
  : > "$C/notify.log"
  run_watch "$((NOW + 300))"
  assert_eq "state unwritable: exit 7" "7" "$RC"
  assert_eq "  exactly one push" "1" "$(pushes)"
  assert_eq "  urgent, fixed title" "urgent	外部見張り: 状態を保存できない (ディスク等)" "$(cut -f1,2 "$C/notify.log")"
  assert_contains "  stderr says so" "state save failed" "$ERR"
  assert_eq "  no temp left behind" "0" "$(count_files "$C/home/state" 'state.??????')"
  SAVEALL="$(cat "$C/notify.log" "$C/home/log/watch.log")$ERR"
  assert_not_contains "  no host in push/log/stderr" "127.0.0.1" "$SAVEALL"
  assert_not_contains "  no port in push/log/stderr" "$P2P_PORT" "$SAVEALL"
  assert_not_contains "  no path in push/log/stderr" "$C" "$(cat "$C/notify.log")"
  run_watch "$((NOW + 600))"
  assert_eq "  not debounced: next run pushes again" "7|2" "$RC|$(grep -c '状態を保存できない' "$C/notify.log")"
  NOTIFY_RC=3; run_watch "$((NOW + 900))"
  assert_eq "  that push failing too: exit 6" "6" "$RC"
  NOTIFY_RC=0; LIVE=0; : > "$C/notify.log"; run_watch "$((NOW + 1200))"
  assert_eq "  DRY: exit 7, nothing sent" "7|0" "$RC|$(pushes)"
  assert_contains "  DRY: would-notify line" "DRY: would notify urgent 外部見張り: 状態を保存できない" "$ERR"
  chmod 700 "$C/home/state"; EXTRA_PATH=""; LIVE=1
  run_watch "$((NOW + 1500))"
  assert_eq "  writable again: back to normal exit" "0" "$RC"
fi

# ============================ 7. DRY ============================
echo "== side-effect gate =="
new_case; LIVE=0; make_json 901
run_watch; assert_eq "DRY run 1: no line yet" "" "$(printf '%s' "$ERR" | grep DRY)"
run_watch "$((NOW + 300))"
assert_contains "DRY run 2 (unseeded) reaches the alert path" "DRY: would notify high 外部見張り: validator.json の更新が止まっている" "$ERR"
assert_eq "  notifier never called" "0" "$(pushes)"
assert_eq "  fails persisted, status never alerting" "2|ok" "$(st fresh fails)|$(st fresh status)"
new_case; LIVE=0; make_json 10; mkdir -p "$C/home/state"
echo '{"fresh":{"status":"alerting","fails":3,"first_fail_at":1},"p2p":{"status":"ok","fails":0,"first_fail_at":null},"chain":{"status":"ok","fails":0,"first_fail_at":null}}' > "$C/home/state/state.json"
run_watch
assert_contains "DRY pass on alerting prints would-recover" "DRY: would notify default 外部見張り: 復旧 (fresh)" "$ERR"
assert_eq "  DRY pass does not clear alerting" "alerting|3" "$(st fresh status)|$(st fresh fails)"

# ============================ 8. no host leak ============================
echo "== no host/topic leak =="
new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 901; RPC_BODY="$BODY_DISCONNECTED"
run_watch; run_watch "$((NOW + 300))"
LOGALL="$(cat "$C/home/log/watch.log")"
assert_not_contains "log has no host" "127.0.0.1" "$LOGALL"
assert_not_contains "log has no port" "$CLOSED_PORT" "$LOGALL"
assert_not_contains "log has no rpc host" "rpc.invalid" "$LOGALL"
PUSHALL="$(cat "$C/notify.log")"
assert_not_contains "push has no host" "127.0.0.1" "$PUSHALL"
assert_not_contains "push has no port" "$CLOSED_PORT" "$PUSHALL"
assert_not_contains "push has no topic" "fy-test-topic" "$PUSHALL"
assert_not_contains "push has no path" "$C" "$PUSHALL"
assert_contains "push says detected from outside" "validator host の外 (web host) から検知" "$PUSHALL"
assert_not_contains "stderr has no host" "127.0.0.1" "$ERR"

# Every other text path: log notes (rpc unavailable, validator absent, state
# corrupt), the DRY stderr line and the permanent-push-failure stderr line.
leak_check() { # label -> asserts on log + stderr + pushes of the current case
  local all; all="$(cat "$C/home/log/watch.log" "$C/notify.log" 2>/dev/null)$ERR"
  assert_not_contains "$1: no host" "127.0.0.1" "$all"
  assert_not_contains "$1: no port" "$P2P_PORT" "$all"
  assert_not_contains "$1: no rpc host" "rpc.invalid" "$all"
  assert_not_contains "$1: no topic" "fy-test-topic" "$all"
}
new_case; make_json 10; RPC_RC=28; RPC_BODY=""; run_watch
assert_contains "note rpc unavailable written" "note: chain rpc unavailable" "$(cat "$C/home/log/watch.log")"
leak_check "note rpc unavailable"
new_case; make_json 10; RPC_BODY="$BODY_ABSENT"; run_watch
assert_contains "note validator absent written" "note: chain: validator absent" "$(cat "$C/home/log/watch.log")"
leak_check "note validator absent"
new_case; make_json 10; mkdir -p "$C/home/state"; echo '{garbage' > "$C/home/state/state.json"; run_watch
leak_check "note state corrupt"
new_case; LIVE=0; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; run_watch; run_watch "$((NOW + 300))"
assert_contains "DRY line printed" "DRY: would notify urgent" "$ERR"
leak_check "DRY stderr"
new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; NOTIFY_RC=3; run_watch; run_watch "$((NOW + 300))"
assert_contains "permanent-fail line printed" "notify permanent fail" "$ERR"
leak_check "permanent-fail stderr"

echo "== WATCH_NOW_EPOCH is digits only =="
new_case; make_json 10
# shellcheck disable=SC2016  # the payload must reach the script unexpanded
run_watch 'x[$(touch '"$C"'/pwned)]'
assert_eq "non-digit WATCH_NOW_EPOCH: exit 1" "1" "$RC"
absent "  arithmetic payload not executed" "$C/pwned"

# ============================ 9. lock ============================
echo "== lock =="
if [ "$HAVE_REAL_FLOCK" = 1 ]; then
  new_case; make_json 10; mkdir -p "$C/home/state"
  python3 -c 'import fcntl,time,sys;f=open(sys.argv[1],"a");fcntl.flock(f,fcntl.LOCK_EX);time.sleep(6)' "$C/home/state/lock" &
  HOLDER=$!; /bin/sleep 1
  run_watch
  assert_eq "lock held: exit 0" "0" "$RC"
  absent "  silent: no run happened" "$C/home/log/watch.log"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  run_watch
  assert_eq "after release the run proceeds" "1" "$(grep -c . "$C/home/log/watch.log")"
else
  [ -n "${CI:-}" ] && bad "lock contention" "no real flock in CI"
  echo "  SKIP  lock contention (no real flock on this host; verified on Linux CI)"
fi

# ============================ 9b. preflight ============================
echo "== dependency preflight =="
for missing in jq curl timeout flock; do
  new_case; make_json 10
  PF="$C/pfbin"; mkdir -p "$PF"
  for t in dirname stat id jq curl timeout flock; do
    [ "$t" = "$missing" ] && continue
    src="$(PATH="$BIN:$PATH" command -v "$t")"; ln -s "$src" "$PF/$t"
  done
  ERR="$(env PATH="$PF" WATCH_LIVE=1 WATCH_HOME="$C/home" WATCH_CONFIG="$C/etc/watch.env" WATCH_NOTIFY="$BIN/notify" \
    STUB_NOTIFY_LOG="$C/notify.log" "$(command -v bash)" "$SCRIPT" 2>&1 >/dev/null)"; RC=$?
  assert_eq "missing $missing: exit 1" "1" "$RC"
  assert_eq "  names only the tool" "external-watch: missing dependency: $missing" "$ERR"
  absent "  nothing created before the check" "$C/home"
done

# ============================ 10. state / log housekeeping ============================
echo "== corrupt state / log trim =="
new_case; make_json 10; mkdir -p "$C/home/state"; echo '{garbage' > "$C/home/state/state.json"
run_watch
assert_eq "corrupt state: rc 0" "0" "$RC"
assert_eq "  moved aside" "1" "$(count_files "$C/home/state" "state.json.corrupt-$NOW")"
assert_eq "  re-initialised" "ok" "$(st chain status)"
assert_contains "  logged" "state corrupt" "$(cat "$C/home/log/watch.log")"
new_case; make_json 10; mkdir -p "$C/home/log"; for i in $(seq 1 6000); do echo "old line $i"; done > "$C/home/log/watch.log"
run_watch
assert_eq "log trimmed to 5000 lines when > 6000" "5000" "$(wc -l < "$C/home/log/watch.log" | tr -d ' ')"
assert_contains "  newest line kept" "fresh=PASS" "$(last_log)"
new_case; make_json 10; mkdir -p "$C/home/log"; for i in $(seq 1 5999); do echo "old line $i"; done > "$C/home/log/watch.log"
run_watch
assert_eq "log not trimmed at exactly 6000" "6000" "$(wc -l < "$C/home/log/watch.log" | tr -d ' ')"

echo
echo "RESULT: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then printf ' - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
