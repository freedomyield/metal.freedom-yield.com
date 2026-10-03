#!/usr/bin/env bash
# tests/external-watch/test-external-watch.sh
#
# scripts/external-watch.sh — off-host watchdog. Every external boundary is
# stubbed: curl (public RPC), notify (WATCH_NOTIFY), sleep, and timeout (to
# make the first p2p probe fail). The p2p probe itself runs against a real
# loopback listener / a closed loopback port. WATCH_LIVE=1 is only ever set
# together with the stub notifier, so nothing is ever sent for real.
# No GNU date dependency: the script uses jq for all time conversion.

# shellcheck disable=SC2012,SC2015,SC2329  # ls -i for inodes; A&&ok||bad reporters; hooks called indirectly
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
# mtr: logs its argv (one line per call) and prints the case's fixture.
cat > "$BIN/mtr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_MTR_LOG"
[ -n "${STUB_MTR_FIXTURE:-}" ] && cat "$STUB_MTR_FIXTURE"
exit 0
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
  : > "$C/notify.log"; : > "$C/sleep.log"; : > "$C/curl.log"; : > "$C/timeout.argv"; : > "$C/mtr.log"; rm -f "$C/curl.count" "$C/timeout.count"
  JSON_AGE=""; JSON_END=""; RPC_BODY="$BODY_CONNECTED"; RPC_RC=0; NOTIFY_RC=0; LIVE=1; FAIL_FIRST=0; EXTRA_PATH=""; HK_ENV=(); MTR_CMD="$BIN/mtr"; MTR_FIXTURE=""
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
    WATCH_MTR="$MTR_CMD" STUB_MTR_LOG="$C/mtr.log" STUB_MTR_FIXTURE="$MTR_FIXTURE" \
    ${HK_ENV[@]+"${HK_ENV[@]}"} bash "$SCRIPT" 2>&1 >/dev/null)"
  RC=$?
}
pushes() { grep -c . "$C/notify.log"; }
last_log() { tail -n 1 "$C/home/log/watch.log" 2>/dev/null; }
st() { jq -r ".$1.$2" "$C/home/state/state.json" 2>/dev/null; }
curl_calls() { grep -c . "$C/curl.log"; }

# ============================ 13. public status file (watch-status.json) ============================
# Contract consumed by public/status/: {"schema":1,"generated_at","interval_sec":300,
# "last":{t,fresh,p2p,chain,alerting[]},"checks":[{t,fresh,p2p,chain}...]} last 24 h,
# oldest first. Defined here, called at the end of the suite;
# WATCH_TEST_ONLY_STATUS=1 runs only this section (fast mutation loop).
file_mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
isoat() { jq -nr --argjson t "$1" '$t | todate'; }
enable_status() { # [path]  sets SPATH; a stand-in for the site's api/ dir, outside WATCH_HOME
  mkdir -p "$C/pub/api"
  SPATH="${1:-$C/pub/api/watch-status.json}"
  printf 'WATCH_PUBLIC_STATUS=%s\n' "$SPATH" >> "$C/etc/watch.env"
}
sj() { jq -c "$1" "$SPATH" 2>/dev/null; }
# Fixture log: in-window PASS/FAIL/UNKNOWN/cached lines, a ~2 h gap, a note
# line carrying host-like text, malformed lines, one line exactly 24 h old
# (excluded), one a second newer (included), one in the future (excluded).
seed_log() {
  mkdir -p "$C/home/log"
  {
    printf '%s fresh=PASS(10s) p2p=PASS chain=PASS pushes=0\n' "$(isoat $((NOW - 86400)))"
    printf '%s fresh=PASS(10s) p2p=PASS chain=PASS pushes=0\n' "$(isoat $((NOW - 86399)))"
    printf '%s fresh=FAIL(nas) p2p=PASS chain=PASS pushes=0\n' "$(isoat $((NOW - 20000)))"
    printf '%s note: p2p diagnosis: provider-edge, draft ticket-draft-x.txt 127.0.0.1 10.9.8.7\n' "$(isoat $((NOW - 19990)))"
    printf '%s fresh=PASS(20s) p2p=FAIL chain=FAIL(cached) pushes=1\n' "$(isoat $((NOW - 19700)))"
    printf '%s fresh=UNKNOWN(5000s) p2p=PASS chain=UNKNOWN pushes=0\n' "$(isoat $((NOW - 12500)))"
    printf 'garbage fresh=PASS p2p=PASS chain=PASS\n'
    printf '%s fresh=PASS(10s) p2p=PASS chain=PASS pushes=0 extra\n' "$(isoat $((NOW - 600)))"
    printf '%s fresh=PASS(10s) p2p=PASS chain=PASS pushes=0\n' "$(isoat $((NOW + 999)))"
  } > "$C/home/log/watch.log"
}
status_config() { # closed|open  rewrite watch.env keeping the status key
  if [ "$1" = closed ]; then P2P_PORT="$CLOSED_PORT"; else P2P_PORT="$OPEN_PORT"; fi
  write_config; printf 'WATCH_PUBLIC_STATUS=%s\n' "$SPATH" >> "$C/etc/watch.env"
}

status_suite() {
FIX="$REPO/tests/external-watch/fixtures"
echo "== public status file: schema, window, mapping =="
new_case; enable_status; seed_log; make_json 10; run_watch
assert_eq "status: run rc unaffected" "0" "$RC"
assert_eq "status: top-level keys exactly the contract" '["checks","generated_at","interval_sec","last","schema"]' "$(sj 'keys')"
assert_eq "  schema / interval / generated_at" "1|300|$(isoat "$NOW")" "$(sj '.schema')|$(sj '.interval_sec')|$(jq -r .generated_at "$SPATH" 2>/dev/null)"
assert_eq "  every check has exactly t,fresh,p2p,chain (booleans)" "true" \
  "$(sj '[.checks[] | (keys == ["chain","fresh","p2p","t"]) and ([.fresh,.p2p,.chain] | all(type == "boolean"))] | all')"
assert_eq "  last keys exactly t,fresh,p2p,chain,alerting" '["alerting","chain","fresh","p2p","t"]' "$(sj '.last | keys')"
assert_eq "  24 h window, oldest first; 24h-old, future, note, malformed lines excluded; gap not filled" \
  "$(isoat $((NOW - 86399)))|$(isoat $((NOW - 20000)))|$(isoat $((NOW - 19700)))|$(isoat $((NOW - 12500)))|$(isoat "$NOW")" \
  "$(jq -r '[.checks[].t] | join("|")' "$SPATH" 2>/dev/null)"
assert_eq "  FAIL -> false; PASS, UNKNOWN, cached -> true" \
  '[[true,true,true],[false,true,true],[true,false,false],[true,true,true],[true,true,true]]' \
  "$(sj '[.checks[] | [.fresh,.p2p,.chain]]')"
assert_eq "  last = this run, nothing alerting" "$(isoat "$NOW")|[]" "$(jq -r '.last.t' "$SPATH" 2>/dev/null)|$(sj '.last.alerting')"
assert_eq "  mode 644" "644" "$(file_mode_of "$SPATH")"
assert_eq "  no publish note" "0" "$(grep -c 'status publish failed' "$C/home/log/watch.log")"
SJ="$(cat "$SPATH" 2>/dev/null)"
for leak in 127.0.0.1 10.9.8.7 "$P2P_PORT" fy-test-topic ticket draft mtr provider-edge note "$C" validator.json "$FAKE_NODE" rpc.invalid log/; do
  assert_not_contains "  no host/path/topic string: $leak" "$leak" "$SJ"
done

echo "== public status file: alerting mirrors the state =="
new_case; enable_status; status_config closed; make_json 10; MTR_FIXTURE="$FIX/mtr-provider-edge.txt"
run_watch
assert_eq "1st failing run: p2p false, not alerting yet" "false|[]" "$(sj '.last.p2p')|$(sj '.last.alerting')"
run_watch "$((NOW + 300))"
assert_eq "2nd failing run: state alerting -> alerting [p2p]" "alerting|[\"p2p\"]" "$(st p2p status)|$(sj '.last.alerting')"
assert_eq "  two checks, oldest first" "$(isoat "$NOW")|$(isoat $((NOW + 300)))" "$(jq -r '[.checks[].t]|join("|")' "$SPATH" 2>/dev/null)"
status_config open; run_watch "$((NOW + 600))"
assert_eq "recovery: alerting [] and p2p true" "[]|true" "$(sj '.last.alerting')|$(sj '.last.p2p')"
new_case; LIVE=0; enable_status; status_config closed; make_json 10; run_watch; run_watch "$((NOW + 300))"
assert_eq "DRY never moves state to alerting -> alerting [] (state, not the fail count)" "ok|2|[]" "$(st p2p status)|$(st p2p fails)|$(sj '.last.alerting')"

echo "== public status file: atomic write and file safety =="
new_case; enable_status; make_json 10
printf 'old\n' > "$SPATH"; chmod 644 "$SPATH"; INO0="$(ls -i "$SPATH" | awk '{print $1}')"
: > "$C/pub/api/.watch-status.AbC123"
run_watch
INO1="$(ls -i "$SPATH" | awk '{print $1}')"
if [ "$INO0" != "$INO1" ]; then ok "replaced by rename (new inode), not rewritten in place"; else bad "replaced by rename" "same inode $INO0"; fi
assert_eq "  no temp left behind (a killed run's temp is swept)" "0" "$(count_files "$C/pub/api" '.watch-status.*')"
assert_eq "  content is the new JSON" "1" "$(sj '.schema')"
new_case; enable_status; make_json 10; printf 'precious\n' > "$C/victim"; ln -s "$C/victim" "$SPATH"; run_watch
assert_eq "symlink target refused: victim untouched, link kept, rc 0" "precious|link|0" \
  "$(cat "$C/victim")|$([ -L "$SPATH" ] && echo link)|$RC"
assert_contains "  one publish note" "note: status publish failed" "$(cat "$C/home/log/watch.log")"
new_case; enable_status; make_json 10; printf 'precious\n' > "$C/victim"; ln "$C/victim" "$SPATH"; run_watch
assert_eq "hard-linked target refused: both names keep the old bytes" "precious|precious|1" \
  "$(cat "$C/victim")|$(cat "$SPATH")|$(grep -c 'status publish failed' "$C/home/log/watch.log")"
new_case; mkdir -p "$C/real"; ln -s "$C/real" "$C/linkdir"; enable_status "$C/linkdir/watch-status.json"; make_json 10; run_watch
absent "symlinked directory refused" "$C/real/watch-status.json"
new_case; enable_status; make_json 10; seed_log
printf 'keep\n' > "$SPATH"; HK_ENV=(WATCH_STATUS_MAX_BYTES=200); run_watch
assert_eq "over the size cap: refused, previous file kept, note" "keep|1" "$(cat "$SPATH")|$(grep -c 'status publish failed' "$C/home/log/watch.log")"
new_case; enable_status; make_json 10; seed_log; run_watch
assert_eq "default cap: the 24 h file is written" "1" "$(sj '.schema')"

echo "== public status file: disabled when unset =="
new_case; mkdir -p "$C/pub/api"; make_json 10; run_watch
assert_eq "unset: rc 0, no file anywhere, no note" "0|0|0" \
  "$RC|$(find "$C" -name 'watch-status.json' | wc -l | tr -d ' ')|$(grep -c 'status publish' "$C/home/log/watch.log")"
new_case; printf 'WATCH_PUBLIC_STATUS=\n' >> "$C/etc/watch.env"; make_json 10; run_watch
assert_eq "empty value: disabled, rc 0, no note" "0|0" "$RC|$(grep -c 'status publish' "$C/home/log/watch.log")"

echo "== public status file: a publish failure never suppresses an alert =="
for badpath in "@C@/nodir/api/watch-status.json" "relative/watch-status.json" "@C@/pub/api/../api/watch-status.json" "@C@/pub/api/status.txt"; do
  new_case; mkdir -p "$C/pub/api"; SPATH="${badpath//@C@/$C}"; status_config closed
  make_json 10; MTR_FIXTURE="$FIX/mtr-provider-edge.txt"
  run_watch; run_watch "$((NOW + 300))"
  assert_eq "bad target '${badpath#@C@}': alert delivered, alerting, rc 0" "1|alerting|0" "$(pushes)|$(st p2p status)|$RC"
  assert_eq "  one note per run" "2" "$(grep -c 'note: status publish failed' "$C/home/log/watch.log")"
done
new_case; enable_status; status_config closed; make_json 10; MTR_FIXTURE="$FIX/mtr-provider-edge.txt"; NOTIFY_RC=3
run_watch; run_watch "$((NOW + 300))"
assert_eq "push failure: exit 6 kept, status still published, not alerting" "6|[]|false" "$RC|$(sj '.last.alerting')|$(sj '.last.p2p')"
}
if [ "${WATCH_TEST_ONLY_STATUS:-0}" = 1 ]; then
  status_suite
  echo; echo "RESULT: $PASS passed, $FAIL failed"
  if [ "$FAIL" -ne 0 ]; then printf ' - %s\n' "${FAILURES[@]}"; exit 1; fi
  exit 0
fi

# WATCH_TEST_ONLY_CAPS=1 runs only the size-cap sections (10 onwards): the
# fast loop for mutation runs against the housekeeping code. CI and
# run-all-tests.sh never set it, so the full suite always runs there.
if [ "${WATCH_TEST_ONLY_CAPS:-0}" != 1 ]; then
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

  # I-1: a check already failing on disk must not add its own push on top of the
  # save alert. Run 1 (writable) records fails=1; runs 2 and 3 cannot save.
  new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10
  run_watch                                   # p2p fails=1 saved
  chmod 500 "$C/home/state"; EXTRA_PATH="$NOCHMOD"
  : > "$C/notify.log"
  run_watch "$((NOW + 300))"
  assert_eq "  p2p failing + unwritable: exit 7, exactly one push" "7|1" "$RC|$(pushes)"
  assert_eq "  it is the save alert" "urgent	外部見張り: 状態を保存できない (ディスク等)" "$(cut -f1,2 "$C/notify.log")"
  assert_contains "  body lists p2p" "失敗中の確認: p2p" "$(cut -f3 "$C/notify.log")"
  assert_not_contains "  no per-check alert" "validator に外から届かない" "$(cat "$C/notify.log")"
  assert_not_contains "  body names no port/host" "$CLOSED_PORT" "$(cat "$C/notify.log")"
  : > "$C/notify.log"
  run_watch "$((NOW + 600))"
  assert_eq "  consecutive run: still exactly one push" "7|1" "$RC|$(pushes)"
  assert_contains "  and it lists p2p again" "失敗中の確認: p2p" "$(cut -f3 "$C/notify.log")"
  chmod 700 "$C/home/state"; EXTRA_PATH=""

  # All checks passing + unwritable: one push, body says none failing.
  new_case; make_json 10
  run_watch
  chmod 500 "$C/home/state"; EXTRA_PATH="$NOCHMOD"
  : > "$C/notify.log"
  run_watch "$((NOW + 300))"
  assert_eq "  all pass + unwritable: exit 7, one push" "7|1" "$RC|$(pushes)"
  assert_contains "  body says none failing" "失敗中の確認: なし" "$(cut -f3 "$C/notify.log")"
  chmod 700 "$C/home/state"; EXTRA_PATH=""
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

fi   # WATCH_TEST_ONLY_CAPS

# ============================ 10. state / log housekeeping ============================
echo "== corrupt state / log trim =="
new_case; make_json 10; mkdir -p "$C/home/state"; echo '{garbage' > "$C/home/state/state.json"
run_watch
assert_eq "corrupt state: rc 0" "0" "$RC"
assert_eq "  moved aside" "1" "$(count_files "$C/home/state" "state.json.corrupt-$NOW")"
assert_eq "  re-initialised" "ok" "$(st chain status)"
assert_contains "  logged" "state corrupt" "$(cat "$C/home/log/watch.log")"
# ---- size caps (C1-C7): small override values keep the fixtures tiny ----
inode_of() { ls -i "$1" | awk '{print $1}'; }
size_of() { wc -c < "$1" | tr -d ' '; }
mk_files() { # dir count  -> hk-01.bak-t..hk-NN.bak-t (the installer's <file>.bak-<ts> shape), higher NN = newer mtime
  local d="$1" n="$2" i
  for i in $(seq 1 "$n"); do
    printf 'x%s\n' "$i" > "$d/hk-$(printf %02d "$i").bak-t"
    touch -t "$(printf '20260101%02d00' "$i")" "$d/hk-$(printf %02d "$i").bak-t"
  done
}
echo "== log caps: watch.log =="
new_case; make_json 10; mkdir -p "$C/home/log"; for i in $(seq 1 300); do echo "old line $i"; done > "$C/home/log/watch.log"
HK_ENV=(WATCH_LOG_MAX_BYTES=2000); run_watch
assert_eq "watch.log over cap: rc 0" "0" "$RC"
[ "$(size_of "$C/home/log/watch.log")" -le 2000 ] && ok "  size <= cap" || bad "  size <= cap" "$(size_of "$C/home/log/watch.log")"
[ "$(size_of "$C/home/log/watch.log")" -gt 500 ] && ok "  keeps a real tail (not emptied)" || bad "  keeps a real tail" "$(size_of "$C/home/log/watch.log")"
assert_contains "  newest line kept" "fresh=PASS" "$(last_log)"
FIRST="$(head -n 1 "$C/home/log/watch.log")"
case "$FIRST" in "old line "[0-9]*) ok "  first line complete" ;; *) bad "  first line complete" "'$FIRST'" ;; esac
assert_eq "  old line 300 (last before this run) kept" "old line 300" "$(grep -x 'old line 300' "$C/home/log/watch.log")"
new_case; make_json 10; mkdir -p "$C/home/log"; for i in $(seq 1 30); do echo "old line $i"; done > "$C/home/log/watch.log"
HK_ENV=(WATCH_LOG_MAX_BYTES=2000); run_watch
assert_eq "watch.log under cap: untouched (31 lines)" "31" "$(wc -l < "$C/home/log/watch.log" | tr -d ' ')"
new_case; make_json 10; mkdir -p "$C/home/log"; for i in $(seq 1 30); do echo "old line $i"; done > "$C/home/log/watch.log"
run_watch
assert_eq "default cap is large: small log untouched" "31" "$(wc -l < "$C/home/log/watch.log" | tr -d ' ')"

echo "== log caps: cron.err trimmed in place =="
new_case; make_json 10; mkdir -p "$C/home/log"; for i in $(seq 1 300); do echo "err line $i"; done > "$C/home/log/cron.err"
INO_BEFORE="$(inode_of "$C/home/log/cron.err")"
exec 8>>"$C/home/log/cron.err"
HK_ENV=(WATCH_CRONERR_MAX_BYTES=2000); run_watch
echo "LATE WRITE" >&8; exec 8>&-
assert_eq "cron.err over cap: rc 0" "0" "$RC"
assert_eq "  same inode (in place)" "$INO_BEFORE" "$(inode_of "$C/home/log/cron.err")"
[ "$(size_of "$C/home/log/cron.err")" -le 2100 ] && ok "  size near cap (cap + late write)" || bad "  size near cap" "$(size_of "$C/home/log/cron.err")"
assert_eq "  descriptor opened before the trim still lands its write" "LATE WRITE" "$(tail -n 1 "$C/home/log/cron.err")"
FIRST="$(head -n 1 "$C/home/log/cron.err")"
case "$FIRST" in "err line "[0-9]*) ok "  first line complete" ;; *) bad "  first line complete" "'$FIRST'" ;; esac
assert_eq "  no temp left in log/" "0" "$(count_files "$C/home/log" '.trim.*')"

echo "== backup/ retention =="
new_case; make_json 10; mkdir -p "$C/home/backup/keepdir"; mk_files "$C/home/backup" 12
run_watch
assert_eq "12 backups -> newest 10 kept" "10" "$(count_files "$C/home/backup" 'hk-*')"
absent "  oldest gone" "$C/home/backup/hk-01.bak-t"; absent "  2nd oldest gone" "$C/home/backup/hk-02.bak-t"
[ -e "$C/home/backup/hk-03.bak-t" ] && [ -e "$C/home/backup/hk-12.bak-t" ] && ok "  newest 10 survive" || bad "  newest 10 survive" "hk-03/hk-12 missing"
[ -d "$C/home/backup/keepdir" ] && ok "  directory untouched" || bad "  directory untouched" "gone"
# order is by mtime, not by name: name order reversed against age
new_case; make_json 10; mkdir -p "$C/home/backup"
for i in $(seq 1 12); do n="$(printf %02d $((13 - i)))"; echo x > "$C/home/backup/rv-$n.bak-t"; touch -t "$(printf '20260101%02d00' "$i")" "$C/home/backup/rv-$n.bak-t"; done
run_watch
absent "mtime order: rv-12 (oldest mtime) gone" "$C/home/backup/rv-12.bak-t"; absent "  rv-11 gone" "$C/home/backup/rv-11.bak-t"
[ -e "$C/home/backup/rv-01.bak-t" ] && ok "  rv-01 (newest mtime) kept" || bad "  rv-01 kept" "gone"
new_case; make_json 10; mkdir -p "$C/home/backup"; mk_files "$C/home/backup" 5
HK_ENV=(WATCH_KEEP_BACKUPS=2); run_watch
assert_eq "override WATCH_KEEP_BACKUPS=2 honoured" "2" "$(count_files "$C/home/backup" 'hk-*')"

echo "== backup/ symlinks are never followed =="
new_case; make_json 10; mkdir -p "$C/home/backup" "$C/outside/d"; echo precious > "$C/outside/file"; echo precious > "$C/outside/d/inner"
touch -t 200001010000 "$C/outside/file"
ln -s "$C/outside/file" "$C/home/backup/aa-link-file.bak-t"; ln -s "$C/outside/d" "$C/home/backup/aa-link-dir.bak-t"
touch -h -t 200001010000 "$C/home/backup/aa-link-file.bak-t" "$C/home/backup/aa-link-dir.bak-t" 2>/dev/null
mk_files "$C/home/backup" 12
run_watch
assert_eq "  12 regular files -> 10 kept, links not counted" "10" "$(count_files "$C/home/backup" 'hk-*')"
[ "$(cat "$C/outside/file")" = precious ] && [ "$(cat "$C/outside/d/inner")" = precious ] && ok "  link targets survive" || bad "  link targets survive" "deleted"
[ -L "$C/home/backup/aa-link-file.bak-t" ] && [ -L "$C/home/backup/aa-link-dir.bak-t" ] && ok "  links themselves untouched" || bad "  links themselves untouched" "removed"
new_case; make_json 10; mkdir -p "$C/home" "$C/outside2"; mk_files "$C/outside2" 12; ln -s "$C/outside2" "$C/home/backup"
run_watch
assert_eq "backup/ itself a symlink: nothing outside deleted" "12" "$(count_files "$C/outside2" 'hk-*')"
assert_eq "  rc 0" "0" "$RC"

echo "== state/ corrupt-file retention =="
new_case; make_json 10; mkdir -p "$C/home/state"
for i in $(seq 1 12); do echo '{}' > "$C/home/state/state.json.corrupt-$(printf 179000%04d "$i")"; touch -t "$(printf '20260101%02d00' "$i")" "$C/home/state/state.json.corrupt-$(printf 179000%04d "$i")"; done
echo '{}' > "$C/home/state/rpc-cache.json"; echo keep > "$C/home/state/other.keep"; echo keep > "$C/home/state/state.json.old"
touch -t 200001010000 "$C/home/state/other.keep" "$C/home/state/state.json.old" "$C/home/state/rpc-cache.json"
run_watch
assert_eq "12 corrupt -> newest 10 kept" "10" "$(count_files "$C/home/state" 'state.json.corrupt-*')"
absent "  oldest corrupt gone" "$C/home/state/state.json.corrupt-1790000001"
[ -e "$C/home/state/state.json.corrupt-1790000012" ] && ok "  newest corrupt kept" || bad "  newest corrupt kept" "gone"
[ -e "$C/home/state/state.json" ] && [ -e "$C/home/state/lock" ] && [ -e "$C/home/state/rpc-cache.json" ] && ok "  state.json / lock / rpc-cache.json untouched" || bad "  state files" "missing"
[ -e "$C/home/state/other.keep" ] && [ -e "$C/home/state/state.json.old" ] && ok "  other state/ files untouched" || bad "  other state/ files" "missing"
new_case; make_json 10; mkdir -p "$C/home/state"; for i in $(seq 1 12); do echo '{}' > "$C/home/state/state.json.corrupt-$i"; touch -t "$(printf '20260101%02d00' "$i")" "$C/home/state/state.json.corrupt-$i"; done
HK_ENV=(WATCH_KEEP_CORRUPT=3); run_watch
assert_eq "override WATCH_KEEP_CORRUPT=3 honoured" "3" "$(count_files "$C/home/state" 'state.json.corrupt-*')"

echo "== invalid overrides fall back to defaults =="
for badv in abc 0 -5 1e3 "" " 7" 99999999999999999999; do
  new_case; make_json 10; mkdir -p "$C/home/log" "$C/home/backup"; for i in $(seq 1 300); do echo "old line $i"; done > "$C/home/log/watch.log"; mk_files "$C/home/backup" 12
  HK_ENV=("WATCH_LOG_MAX_BYTES=$badv" "WATCH_KEEP_BACKUPS=$badv"); run_watch
  assert_eq "override '$badv': rc 0" "0" "$RC"
  assert_eq "  log cap default (not trimmed)" "301" "$(wc -l < "$C/home/log/watch.log" | tr -d ' ')"
  assert_eq "  keep default 10" "10" "$(count_files "$C/home/backup" 'hk-*')"
done

echo "== housekeeping failure never changes alerting or exit code =="
hk_scenario() { # label extra-setup-fn -> prints "rc pushes status"
  new_case; make_json 10; P2P_PORT="$CLOSED_PORT"; write_config; mkdir -p "$C/home/backup"; mk_files "$C/home/backup" 12
  "$1"
  run_watch; run_watch
  echo "$RC $(pushes) $(st p2p status)"
}
hk_none() { :; }
hk_break_find() { mkdir -p "$C/fbin"; printf '#!/bin/sh\nexit 1\n' > "$C/fbin/find"; chmod +x "$C/fbin/find"; EXTRA_PATH="$C/fbin"; }
CTRL="$(hk_scenario hk_none)"
BROKE="$(hk_scenario hk_break_find)"
assert_eq "control: p2p alert pushed, rc 0" "0 1 alerting" "$CTRL"
assert_eq "housekeeping failing (find broken): identical rc/pushes/status" "$CTRL" "$BROKE"
new_case; make_json 10; P2P_PORT="$CLOSED_PORT"; write_config; hk_break_find; run_watch; run_watch
assert_eq "  exactly one note per failing run (2 runs -> 2)" "2" "$(grep -c 'note: housekeeping incomplete' "$C/home/log/watch.log")"
assert_not_contains "  note names no host/path" "$C" "$(grep 'housekeeping incomplete' "$C/home/log/watch.log")"
if [ "$(id -u)" != 0 ]; then
  new_case; make_json 10; mkdir -p "$C/home/backup"; mk_files "$C/home/backup" 12; chmod 000 "$C/home/backup"
  run_watch; chmod 700 "$C/home/backup"
  assert_eq "unreadable backup dir: rc 0" "0" "$RC"
  assert_contains "  note logged" "housekeeping incomplete" "$(cat "$C/home/log/watch.log")"
  assert_eq "  backups untouched" "12" "$(count_files "$C/home/backup" 'hk-*')"
else
  echo "  SKIP  unreadable backup dir (running as root; covered by the find-stub case)"
fi

echo "== housekeeping fix round 1 =="
new_case; make_json 10; mkdir -p "$C/home/log"; echo keepme > "$C/home/log/other.txt"; echo a > "$C/home/log/.trim.AbC123"; echo b > "$C/home/log/.trim.xYz789"
echo "old" > "$C/home/log/cron.err"; echo outside > "$C/outside_t"; ln -s "$C/outside_t" "$C/home/log/.trim.LNK000"
run_watch
absent "stale .trim temp 1 swept" "$C/home/log/.trim.AbC123"; absent "  stale .trim temp 2 swept" "$C/home/log/.trim.xYz789"
assert_eq "  unrelated file untouched" "keepme" "$(cat "$C/home/log/other.txt")"
assert_eq "  cron.err untouched" "old" "$(cat "$C/home/log/cron.err")"
assert_eq "  symlink target survives" "outside" "$(cat "$C/outside_t")"
[ -L "$C/home/log/.trim.LNK000" ] && ok "  symlink named like a temp is not followed or removed" || bad "  symlink temp" "removed"
new_case; make_json 10; mkdir -p "$C/home/backup"; mk_files "$C/home/backup" 12
TABNAME="$C/home/backup/$(printf 'aa.bak-tab\t')"; echo x > "$TABNAME"; touch -t 200001010000 "$TABNAME"
echo innocent > "$C/home/backup/aa.bak-tab"; touch -t 203001010000 "$C/home/backup/aa.bak-tab"   # what a mangled (tab-stripped) name would hit
run_watch
[ -e "$TABNAME" ] && ok "tab-suffixed name skipped (not pruned)" || bad "tab name skipped" "gone"
assert_eq "  tab-stripped twin (newest file) not deleted by mistake" "innocent" "$(cat "$C/home/backup/aa.bak-tab")"
assert_eq "  regular files still pruned (13 -> 10)" "9" "$(count_files "$C/home/backup" 'hk-*')"
new_case; make_json 10; mkdir -p "$C/home/log"; { printf 'short\n'; head -c 1500 /dev/zero | tr '\0' 'z'; } > "$C/home/log/cron.err"
HK_ENV=(WATCH_CRONERR_MAX_BYTES=1000); run_watch
[ -s "$C/home/log/cron.err" ] && ok "line longer than cap/2: file not emptied" || bad "long last line" "empty"
[ "$(size_of "$C/home/log/cron.err")" -le 1000 ] && ok "  size <= cap" || bad "  size <= cap" "$(size_of "$C/home/log/cron.err")"
assert_eq "  ends with that line's tail" "zzzzzzzzzz" "$(tail -c 10 "$C/home/log/cron.err")"

# ============================ 11. final-audit fixes ============================
# Helpers: a co-tenant file of 300 lines, a PATH shim that runs once before
# the real tool (race injection), and a cksum shortcut.
sum_of() { cksum < "$1"; }
mk_cotenant() { for i in $(seq 1 300); do echo "cotenant line $i"; done > "$1"; }
race_shim() { # tool action-script  -> EXTRA_PATH shim: runs action once, then the real tool
  local real; real="$(command -v "$1")"; mkdir -p "$C/racebin"
  printf '#!/usr/bin/env bash\nif [ ! -e "%s/raced" ]; then : > "%s/raced"; %s; fi\nexec "%s" "$@"\n' \
    "$C" "$C" "$2" "$real" > "$C/racebin/$1"
  chmod +x "$C/racebin/$1"; EXTRA_PATH="$C/racebin"
}

echo "== hard links are never trimmed through (F1) =="
new_case; make_json 10; mkdir -p "$C/home/log"; mk_cotenant "$C/cotenant"; SUM="$(sum_of "$C/cotenant")"
ln "$C/cotenant" "$C/home/log/cron.err"
HK_ENV=(WATCH_CRONERR_MAX_BYTES=2000); run_watch
assert_eq "cron.err hard-linked to a co-tenant file: co-tenant byte-identical" "$SUM" "$(sum_of "$C/cotenant")"
assert_eq "  rc 0" "0" "$RC"
assert_contains "  refusal reported as a note" "housekeeping incomplete" "$(cat "$C/home/log/watch.log")"
new_case; make_json 10; mkdir -p "$C/home/log"; mk_cotenant "$C/cotenant"
ln "$C/cotenant" "$C/home/log/watch.log"
HK_ENV=(WATCH_LOG_MAX_BYTES=2000); run_watch
assert_eq "watch.log hard-linked: co-tenant first line kept (not trimmed)" "cotenant line 1" "$(head -n 1 "$C/cotenant")"
assert_eq "  co-tenant only gained this run's appends (run line + note)" "302" "$(wc -l < "$C/cotenant" | tr -d ' ')"

echo "== cron.err stays bounded when the run dies before housekeeping (F2) =="
new_case; printf 'BROKEN LINE;\n' >> "$C/etc/watch.env"
early_env=(PATH="$BIN:$PATH" WATCH_HOME="$C/home" WATCH_CONFIG="$C/etc/watch.env" WATCH_CRONERR_MAX_BYTES=1000)
PER="$(env "${early_env[@]}" bash "$SCRIPT" 2>&1 | wc -c | tr -d ' ')"   # one run's output; no log/ yet
absent "  config-error run creates nothing (early trim never mkdirs)" "$C/home"
mkdir -p "$C/home/log"
for _ in $(seq 1 200); do env "${early_env[@]}" bash "$SCRIPT" >> "$C/home/log/cron.err" 2>&1; RC=$?; done
assert_eq "200 config-error runs: every run still exits 1" "1" "$RC"
SZ="$(size_of "$C/home/log/cron.err")"
[ "$SZ" -le $((1000 + PER)) ] && ok "  cron.err <= cap + one run's output ($SZ <= 1000+$PER; unbounded would be $((200 * PER)))" \
  || bad "  cron.err bounded" "$SZ > 1000+$PER"
assert_contains "  newest message kept" "config error" "$(tail -n 1 "$C/home/log/cron.err")"
assert_eq "  no temp left in log/" "0" "$(count_files "$C/home/log" '.trim.*')"

echo "== backup/ prunes only <file>.bak-<ts> names (F3) =="
new_case; make_json 10; mkdir -p "$C/home/backup"; mk_files "$C/home/backup" 12
echo keep > "$C/home/backup/notes.txt"; touch -t 200001010000 "$C/home/backup/notes.txt"
run_watch
assert_eq "unrelated (and oldest) file in backup/ survives" "keep" "$(cat "$C/home/backup/notes.txt" 2>/dev/null)"
assert_eq "  .bak- files still pruned to 10" "10" "$(count_files "$C/home/backup" 'hk-*')"

echo "== races: a swap after the check is refused (F4) =="
for kind in "ln -s" "ln"; do
  new_case; make_json 10; mkdir -p "$C/home/log"; for i in $(seq 1 300); do echo "err line $i"; done > "$C/home/log/cron.err"
  mk_cotenant "$C/cotenant"; SUM="$(sum_of "$C/cotenant")"
  race_shim od "mv '$C/home/log/cron.err' '$C/home/log/cron.err.orig'; $kind '$C/cotenant' '$C/home/log/cron.err'"
  HK_ENV=(WATCH_CRONERR_MAX_BYTES=2000); run_watch
  [ -e "$C/raced" ] && ok "cron.err swapped mid-trim ($kind): race injected" || bad "race injected ($kind)" "shim never ran"
  assert_eq "  co-tenant byte-identical" "$SUM" "$(sum_of "$C/cotenant")"
  assert_eq "  rc 0" "0" "$RC"
done
new_case; make_json 10; mkdir -p "$C/home/backup" "$C/outside3"; mk_files "$C/home/backup" 12; mk_files "$C/outside3" 12
race_shim sort "mv '$C/home/backup' '$C/home/backup.real'; ln -s '$C/outside3' '$C/home/backup'"
run_watch
[ -e "$C/raced" ] && ok "backup/ swapped for a symlink after the listing: race injected" || bad "race injected (sort)" "shim never ran"
assert_eq "  nothing deleted in the swapped-in directory" "12" "$(count_files "$C/outside3" 'hk-*')"
assert_contains "  refusal reported as a note" "housekeeping incomplete" "$(cat "$C/home/log/watch.log")"
assert_eq "  rc 0" "0" "$RC"

echo "== state/ temp sweep (F5) =="
new_case; make_json 10; mkdir -p "$C/home/state"; echo outside > "$C/outside_s"
for n in state.AbC123 rpc-cache.xYz789 state.AbC1234 rpc-cache.ab12 state.json.old other.keep; do echo x > "$C/home/state/$n"; done
ln -s "$C/outside_s" "$C/home/state/state.LNK000"
run_watch
absent "leaked state.XXXXXX swept" "$C/home/state/state.AbC123"; absent "  leaked rpc-cache.XXXXXX swept" "$C/home/state/rpc-cache.xYz789"
[ -e "$C/home/state/state.AbC1234" ] && [ -e "$C/home/state/rpc-cache.ab12" ] && ok "  other suffix lengths untouched" || bad "  suffix width" "removed"
[ -e "$C/home/state/state.json.old" ] && [ -e "$C/home/state/other.keep" ] && [ -e "$C/home/state/state.json" ] && ok "  state.json and other files untouched" || bad "  state/ files" "removed"
[ -L "$C/home/state/state.LNK000" ] && [ "$(cat "$C/outside_s")" = outside ] && ok "  symlink named like a temp: neither it nor its target touched" || bad "  symlink temp" "touched"

echo "== size-cap test gaps (F7) =="
# exact-cap boundary (cron.err gets no line from the run itself)
new_case; make_json 10; mkdir -p "$C/home/log"; yes 'e123456789' | head -c 2000 > "$C/home/log/cron.err"; SUM="$(sum_of "$C/home/log/cron.err")"
HK_ENV=(WATCH_CRONERR_MAX_BYTES=2000); run_watch
assert_eq "cron.err exactly at the cap: byte-identical" "$SUM" "$(sum_of "$C/home/log/cron.err")"
new_case; make_json 10; mkdir -p "$C/home/log"; yes 'e123456789' | head -c 2001 > "$C/home/log/cron.err"
HK_ENV=(WATCH_CRONERR_MAX_BYTES=2000); run_watch
[ "$(size_of "$C/home/log/cron.err")" -le 1000 ] && ok "cron.err one byte over: trimmed to <= cap/2" || bad "cap+1 trimmed" "$(size_of "$C/home/log/cron.err")"
# aligned 10-byte lines: exactly cap/2 bytes (100 whole lines) are kept
new_case; make_json 10; mkdir -p "$C/home/log"; for i in $(seq 1 300); do printf 'e%08d\n' "$i"; done > "$C/home/log/cron.err"
HK_ENV=(WATCH_CRONERR_MAX_BYTES=2000); run_watch
assert_eq "aligned cut: exactly cap/2 bytes kept" "1000" "$(size_of "$C/home/log/cron.err")"
assert_eq "  first kept line is the aligned one (not dropped)" "e00000201" "$(head -n 1 "$C/home/log/cron.err")"
# symlinked watch.log / cron.err: the target is never trimmed
new_case; make_json 10; mkdir -p "$C/home/log"; mk_cotenant "$C/cotenant"; SUM="$(sum_of "$C/cotenant")"
ln -s "$C/cotenant" "$C/home/log/cron.err"
HK_ENV=(WATCH_CRONERR_MAX_BYTES=2000); run_watch
assert_eq "cron.err a symlink: target byte-identical" "$SUM" "$(sum_of "$C/cotenant")"
new_case; make_json 10; mkdir -p "$C/home/log"; mk_cotenant "$C/cotenant"
ln -s "$C/cotenant" "$C/home/log/watch.log"
HK_ENV=(WATCH_LOG_MAX_BYTES=2000); run_watch
assert_eq "watch.log a symlink: target not trimmed (first line kept)" "cotenant line 1" "$(head -n 1 "$C/cotenant")"
# sweep glob width: exactly .trim. + 6 characters
new_case; make_json 10; mkdir -p "$C/home/log"; for n in .trim.ab12CD .trim.ABCDEFG .trim.abc; do echo x > "$C/home/log/$n"; done
run_watch
absent "sweep: .trim.<6 chars> removed" "$C/home/log/.trim.ab12CD"
[ -e "$C/home/log/.trim.ABCDEFG" ] && [ -e "$C/home/log/.trim.abc" ] && ok "  .trim.<7 chars> and .trim.<3 chars> untouched" || bad "  sweep glob width" "removed"
# nested directories are never descended into
new_case; make_json 10; mkdir -p "$C/home/backup/sub"; mk_files "$C/home/backup" 12; mk_files "$C/home/backup/sub" 12
touch -t 200001010000 "$C/home/backup/sub"/*
run_watch
assert_eq "backup/sub/: nested files (all older) untouched" "12" "$(count_files "$C/home/backup/sub" 'hk-*')"
assert_eq "  top level pruned to 10" "10" "$(count_files "$C/home/backup" 'hk-*')"
# a failing temp sweep alone is reported
new_case; make_json 10; mkdir -p "$C/fbin"
printf '#!/usr/bin/env bash\ncase "$*" in *.trim.*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v find)" > "$C/fbin/find"; chmod +x "$C/fbin/find"; EXTRA_PATH="$C/fbin"
run_watch
assert_contains "temp sweep failing: note logged" "housekeeping incomplete" "$(cat "$C/home/log/watch.log")"
assert_eq "  rc 0" "0" "$RC"
# production defaults (no overrides): 1048576 bytes, exact boundary
new_case; make_json 10; mkdir -p "$C/home/log"; yes 'default cap filler line' | head -c 1048576 > "$C/home/log/cron.err"; SUM="$(sum_of "$C/home/log/cron.err")"
run_watch
assert_eq "default cron.err cap: exactly 1048576 bytes untouched" "$SUM" "$(sum_of "$C/home/log/cron.err")"
new_case; make_json 10; mkdir -p "$C/home/log"; yes 'default cap filler line' | head -c 1048577 > "$C/home/log/cron.err"
run_watch
[ "$(size_of "$C/home/log/cron.err")" -le 524288 ] && ok "  1048577 bytes: trimmed to <= 524288" || bad "  default cron.err cap" "$(size_of "$C/home/log/cron.err")"
new_case; make_json 10; run_watch; L="$(size_of "$C/home/log/watch.log")"   # one run's log line, deterministic
new_case; make_json 10; mkdir -p "$C/home/log"; yes 'default cap filler line' | head -c $((1048576 - L)) > "$C/home/log/watch.log"
run_watch
assert_eq "default watch.log cap: exactly 1048576 after this run's line, untouched" "1048576" "$(size_of "$C/home/log/watch.log")"
new_case; make_json 10; mkdir -p "$C/home/log"; yes 'default cap filler line' | head -c $((1048577 - L)) > "$C/home/log/watch.log"
run_watch
[ "$(size_of "$C/home/log/watch.log")" -le 524288 ] && ok "  one byte more: trimmed to <= 524288" || bad "  default watch.log cap" "$(size_of "$C/home/log/watch.log")"

# ============================ 12. p2p path diagnosis (mtr + ticket draft) ============================
# 2026-09-24..28: ~100 h unreachable, the break was at the provider's edge and
# nobody escalated. On the transition into the p2p alert the watch classifies
# the path from an mtr report and writes a provider ticket draft.
FIX="$REPO/tests/external-watch/fixtures"
echo "== classify_mtr (pure, fixtures) =="
classify() { bash "$SCRIPT" --classify-mtr < "$1"; }
assert_eq "provider-edge: break after the last answering hop" \
  "provider-edge last_answering_hop=3 first_silent_hop=4" "$(classify "$FIX/mtr-provider-edge.txt")"
assert_eq "provider-edge: a silent hop in the middle does not move the break; 100% with an address is silent" \
  "provider-edge last_answering_hop=3 first_silent_hop=4" "$(classify "$FIX/mtr-provider-edge-gap.txt")"
assert_eq "no-route-at-all: nothing answers" "no-route-at-all" "$(classify "$FIX/mtr-no-route.txt")"
assert_eq "reaches-host: the target answers" "reaches-host" "$(classify "$FIX/mtr-reaches-host.txt")"
assert_eq "unknown: no hop lines" "unknown" "$(classify "$FIX/mtr-garbage.txt")"
assert_eq "unknown: empty input" "unknown" "$(classify /dev/null)"
assert_eq "unknown: 'mtr unavailable' line" "unknown" "$(printf 'mtr unavailable (not installed)\n' | bash "$SCRIPT" --classify-mtr)"
assert_eq "--classify-mtr reads no config" "0" "$(WATCH_CONFIG=/nonexistent bash "$SCRIPT" --classify-mtr < /dev/null >/dev/null 2>&1; echo $?)"

echo "== p2p alert: mtr + ticket draft on the transition only =="
draft_name() { printf 'ticket-draft-%s.txt' "$(jq -nr --argjson t "$1" '$t | strftime("%Y%m%dT%H%M%SZ")')"; }
new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; MTR_FIXTURE="$FIX/mtr-provider-edge.txt"
run_watch
assert_eq "run 1 (no alert yet): mtr not run" "0" "$(grep -c . "$C/mtr.log")"
run_watch "$((NOW + 300))"
D="$C/home/log/$(draft_name "$((NOW + 300))")"
BODY="$(tail -n 1 "$C/notify.log" | tr '\001' '\n')"
assert_eq "alert run: exactly one push, mtr run once" "1|1" "$(pushes)|$(grep -c . "$C/mtr.log")"
assert_eq "  mtr shape: report, numeric, 5 cycles, wide, toward the host" "-r -n -c 5 -w 127.0.0.1" "$(cat "$C/mtr.log")"
assert_contains "  push carries the class with hop indices" \
  "経路 (mtr): provider-edge — 応答する最後の hop 3 / 無応答の最初の hop 4 (以降すべて無応答)" "$BODY"
assert_contains "  push names the draft file" "下書き: home/log/$(draft_name "$((NOW + 300))") (Public Network issue チケット用)" "$BODY"
assert_contains "  existing alert lines kept" "チェック: p2p (TCP 到達)" "$BODY"
for ip in 192.0.2.1 198.51.100.17 198.51.100.33 127.0.0.1; do
  assert_not_contains "  push has no hop/host address $ip" "$ip" "$(cat "$C/notify.log")"
done
assert_not_contains "  push has no path" "$C" "$(cat "$C/notify.log")"
assert_not_contains "  watch.log has no hop address" "198.51.100" "$(cat "$C/home/log/watch.log")"
assert_contains "  watch.log notes the diagnosis" "note: p2p diagnosis: provider-edge" "$(cat "$C/home/log/watch.log")"
if [ -f "$D" ]; then ok "  draft written"; else bad "  draft written" "missing $D"; fi
DRAFT="$(cat "$D" 2>/dev/null)"
assert_contains "  draft: ticket subject" "Subject: Public Network issue" "$DRAFT"
assert_contains "  draft: start = first FAIL observed (run 1), not the alert run" \
  "unable to connect to it since $(jq -nr --argjson t "$NOW" '$t|todate') (UTC" "$DRAFT"
assert_contains "  draft: classification line" "Path classification: provider-edge last_answering_hop=3 first_silent_hop=4" "$DRAFT"
assert_contains "  draft: raw mtr report verbatim" "$(sed -n 5p "$FIX/mtr-provider-edge.txt")" "$DRAFT"
assert_contains "  draft: observation only, from the external vantage point" \
  "From an external vantage point, hops answer up to hop 3 and are silent from
hop 4 onward" "$DRAFT"
assert_contains "  draft: asks for the upstream path" "Could you please check the upstream path toward this server?" "$DRAFT"
for claim in "has not been changed" "uplink" "up to your network" "outside it"; do
  assert_not_contains "  draft asserts nothing unmeasured: '$claim'" "$claim" "$DRAFT"
done
assert_contains "  draft: server-unchanged is an operator placeholder" "[operator: confirm no changes were made to the server]" "$DRAFT"
assert_not_contains "  provider-edge draft has no 'not a network ticket' label" "NOT A NETWORK TICKET" "$DRAFT"
assert_eq "  draft is English only (no non-ASCII bytes)" "0" "$(LC_ALL=C grep -c '[^ -~]' "$D")"
assert_eq "  draft mode 600" "600" "$( (stat -c %a "$D" 2>/dev/null || stat -f %Lp "$D"))"
run_watch "$((NOW + 600))"; run_watch "$((NOW + 900))"
assert_eq "still failing (2 more runs): no new push, no new mtr, no new draft" "1|1|1" \
  "$(pushes)|$(grep -c . "$C/mtr.log")|$(count_files "$C/home/log" 'ticket-draft-*.txt')"
P2P_PORT="$OPEN_PORT"; write_config; run_watch "$((NOW + 1200))"
P2P_PORT="$CLOSED_PORT"; write_config; run_watch "$((NOW + 1500))"; run_watch "$((NOW + 1800))"
assert_eq "recover then fail again: a second transition diagnoses again" "2|2" \
  "$(grep -c . "$C/mtr.log")|$(count_files "$C/home/log" 'ticket-draft-*.txt')"

for pair in "no-route:no-route-at-all — どの hop も応答なし" "reaches-host:reaches-host — 経路は届いている (host/port 側の問題)" "garbage:unknown"; do
  new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; MTR_FIXTURE="$FIX/mtr-${pair%%:*}.txt"
  run_watch; run_watch "$((NOW + 300))"
  assert_contains "push class line for ${pair%%:*}" "経路 (mtr): ${pair#*:}" "$(tr '\001' '\n' < "$C/notify.log")"
  DRAFT="$(cat "$C/home/log/$(draft_name "$((NOW + 300))")" 2>/dev/null)"
  for claim in "upstream" "uplink" "hops answer up to" "has not been changed"; do
    assert_not_contains "  ${pair%%:*} draft: no '$claim' claim" "$claim" "$DRAFT"
  done
  assert_contains "  ${pair%%:*} draft: neutral request" "check whether this server is reachable from your side?" "$DRAFT"
  assert_contains "  ${pair%%:*} draft: operator placeholder" "[operator: confirm no changes were made to the server]" "$DRAFT"
  if [ "${pair%%:*}" = reaches-host ]; then
    assert_contains "  reaches-host draft: labelled probably not a network ticket" "PROBABLY NOT A NETWORK TICKET" "$DRAFT"
    assert_contains "  reaches-host draft: says the target answers ICMP" "The server answers ICMP from our external vantage point" "$DRAFT"
  else
    assert_not_contains "  ${pair%%:*} draft: no 'not a network ticket' label" "NOT A NETWORK TICKET" "$DRAFT"
    assert_contains "  ${pair%%:*} draft: tells the operator the break is not located" "the trace does not locate the break" "$DRAFT"
  fi
done

new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; MTR_CMD="fy-no-such-mtr"
run_watch; run_watch "$((NOW + 300))"
assert_eq "mtr missing: the alert still goes out" "1|0" "$(pushes)|$RC"
assert_contains "  push says mtr unavailable" "経路 (mtr): unknown (mtr unavailable)" "$(tr '\001' '\n' < "$C/notify.log")"
assert_contains "  draft says mtr unavailable" "mtr unavailable (not installed)" "$(cat "$C/home/log/$(draft_name "$((NOW + 300))")" 2>/dev/null)"

echo "== mtr ignoring SIGTERM cannot hold the run (timeout -k) =="
# The stub ignores TERM (inherited by its child sleep); only a KILL ends it.
# The outer real timeout bounds the test itself if -k is ever dropped.
cat > "$BIN/mtr-hang" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_MTR_LOG"
trap '' TERM
/bin/sleep 60
STUB
chmod +x "$BIN/mtr-hang"
new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; MTR_CMD="$BIN/mtr-hang"
run_watch
T0="$(date +%s)"
ERR="$(WATCH_MTR_TIMEOUT=1 "$REAL_TIMEOUT" 30 env WATCH_LIVE=1 PATH="$BIN:$PATH" WATCH_HOME="$C/home" WATCH_CONFIG="$C/etc/watch.env" \
  WATCH_NOTIFY="$BIN/notify" WATCH_NOW_EPOCH="$((NOW + 300))" P2P_REPROBE_SLEEP=7 WATCH_NOTIFY_RETRY_SLEEP=5 \
  STUB_CURL_LOG="$C/curl.log" STUB_CURL_COUNTER="$C/curl.count" STUB_CURL_BODY="$RPC_BODY" STUB_CURL_RC=0 \
  STUB_NOTIFY_LOG="$C/notify.log" STUB_NOTIFY_RC=0 STUB_SLEEP_LOG="$C/sleep.log" STUB_TIMEOUT_ARGV_LOG="$C/timeout.argv" \
  WATCH_MTR="$MTR_CMD" STUB_MTR_LOG="$C/mtr.log" bash "$SCRIPT" 2>&1 >/dev/null)"; RC=$?
T1="$(date +%s)"
assert_eq "TERM-ignoring mtr: run finishes on its own and the alert goes out" "0|1" "$RC|$(pushes)"
if [ "$((T1 - T0))" -lt 20 ]; then ok "  bounded by timeout + kill-after ($((T1 - T0)) s)"; else bad "  bounded by timeout + kill-after" "took $((T1 - T0)) s"; fi
assert_contains "  mtr wrapped with -k 5" "-k 5 1 $BIN/mtr-hang -r -n -c 5 -w 127.0.0.1" "$(cat "$C/timeout.argv")"
assert_contains "  draft records the kill" "(mtr exited rc=137" "$(cat "$C/home/log/$(draft_name "$((NOW + 300))")" 2>/dev/null)"

new_case; RPC_BODY="$BODY_DISCONNECTED"; make_json 901; MTR_FIXTURE="$FIX/mtr-provider-edge.txt"
run_watch; run_watch "$((NOW + 900))"
assert_eq "chain + fresh alerts: no mtr, no draft" "2|0|0" \
  "$(pushes)|$(grep -c . "$C/mtr.log")|$(count_files "$C/home/log" 'ticket-draft-*.txt')"

new_case; LIVE=0; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; MTR_FIXTURE="$FIX/mtr-provider-edge.txt"
run_watch; run_watch "$((NOW + 300))"
assert_contains "DRY: says it would capture" "DRY: would capture mtr and write a ticket draft" "$ERR"
assert_eq "  DRY: mtr never run, no draft" "0|0" "$(grep -c . "$C/mtr.log")|$(count_files "$C/home/log" 'ticket-draft-*.txt')"

new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; MTR_FIXTURE="$FIX/mtr-provider-edge.txt"; NOTIFY_RC=3
run_watch; run_watch "$((NOW + 300))"; NOTIFY_RC=0; run_watch "$((NOW + 600))"
assert_eq "push failed then retried: alert delivered, status alerting" "alerting" "$(st p2p status)"
run_watch "$((NOW + 900))"
assert_eq "  after delivery no further diagnosis (1 failed try + 1 retry)" "2" "$(grep -c . "$C/mtr.log")"

echo "== ticket drafts are bounded =="
new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10; MTR_FIXTURE="$FIX/mtr-provider-edge.txt"
mkdir -p "$C/home/log"
for i in $(seq -w 1 12); do echo old > "$C/home/log/ticket-draft-200001${i}T000000Z.txt"; touch -t "2000${i}010000" "$C/home/log/ticket-draft-200001${i}T000000Z.txt"; done
echo keep > "$C/home/log/other-note.txt"; touch -t 200001010000 "$C/home/log/other-note.txt"
run_watch; run_watch "$((NOW + 300))"
assert_eq "12 old + 1 new: newest 10 kept" "10" "$(count_files "$C/home/log" 'ticket-draft-*.txt')"
if [ -f "$C/home/log/$(draft_name "$((NOW + 300))")" ]; then ok "  the new draft is among them"; else bad "  new draft kept" "pruned"; fi
absent "  the oldest is gone" "$C/home/log/ticket-draft-20000101T000000Z.txt"
if [ -f "$C/home/log/other-note.txt" ]; then ok "  other names in log/ untouched"; else bad "  other names untouched" "deleted"; fi
new_case; P2P_PORT="$CLOSED_PORT"; write_config; make_json 10
# Report larger than a pipe buffer (64 KiB): the writer is still blocked when
# the cap closes the pipe, so it always takes SIGPIPE. The draft must still be
# written (truncated), not reported as failed (pipefail regression, 2026-10-02).
for i in $(seq 1 3000); do echo "  $i.|-- ???                       100.0     5    0.0   0.0   0.0   0.0   0.0"; done > "$C/bigmtr"; MTR_FIXTURE="$C/bigmtr"
HK_ENV=(WATCH_LOG_MAX_BYTES=4000); run_watch; run_watch "$((NOW + 300))"
DSIZE="$(size_of "$C/home/log/$(draft_name "$((NOW + 300))")" 2>/dev/null)"
if [ -n "$DSIZE" ] && [ "$DSIZE" -gt 0 ] && [ "$DSIZE" -le 4000 ]; then ok "oversized report: draft written and capped at the log cap (4000)"
else bad "oversized report: draft written and capped" "size='$DSIZE'"; fi
assert_not_contains "  push does not report a failed draft" "下書き: 作成失敗" "$(tr '\001' '\n' < "$C/notify.log")"

status_suite

echo
echo "RESULT: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then printf ' - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
