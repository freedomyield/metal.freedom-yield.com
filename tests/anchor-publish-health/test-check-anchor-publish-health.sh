#!/usr/bin/env bash
# test-check-anchor-publish-health.sh — suite for
# scripts/check-anchor-publish-health.sh.
#
# CHAIN: none — no network. A recording curl stub (FYD_CURL) serves fixture
#        bodies + HTTP codes from tempfiles; no real HTTP, no broadcast, no push.
#
# Verifies the content-verify contract the liveness-only monitor lacked:
#   - 200 + dag_root_computed matching the on-chain anchored root  -> OK   (exit 0)
#   - 200 + dag_root_computed MISMATCH (the stale-publish case)     -> alert(exit 3)
#   - source not served (non-200)                                  -> alert(exit 2)
#   - source 200 but receipt unavailable (cannot content-verify)   -> warn (exit 4)
#   - source 200 but source body unparseable                       -> alert(exit 5)
# Also asserts the dead auto-recover is gone (no push-to-web-host.sh call).
#
# Also verifies the notify.sh wiring added after the checker sat RED for days
# with no phone signal (2026-07-08): every failure exit (2/3/4/5) must fire a
# high-priority alert via a recording FYD_NOTIFY stub, the alert message must
# name the exit code, and the healthy path must fire no alert at all.
#
# Also verifies the retry-hardened fetch() added 2026-07-16 (D1: a single
# transient blip must not escalate to a phone alarm) and the repo-local LOG
# default (D2: /var/log is not deploy-writable on the host):
#   - a transient failure followed by a 200 within FYD_FETCH_ATTEMPTS  -> OK,
#     no alert, no exit-2 escalation
#   - a 200 on the first attempt fires exactly one curl call (no needless
#     retry)
#   - all FYD_FETCH_ATTEMPTS attempts failing to return 200               -> the
#     existing exit-2 failure branch, exactly one alert
#   - the retry applies to the receipt fetch too (the exit-4 path)
#   - exit 3 (content mismatch) is never masked by the retry: a served
#     (200-on-first-try) but stale source still alerts immediately
#   - the default log path (when ANCHOR_PUBLISH_HEALTH_LOG is unset) resolves
#     under the repo-local logs/ dir, not the deploy-unwritable /var/log
#
# Usage:
#   bash tests/anchor-publish-health/test-check-anchor-publish-health.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-anchor-publish-health.sh"

if [ ! -f "$CHECKER" ]; then
	echo "FATAL: checker not found at $CHECKER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

ROOT_MATCH="ad7405814683fca7dc001f11ed9c031871f7e944235694ae1a11bd17fc653369"
ROOT_STALE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

BASE=""; STUB=""; LOG=""; NOTIFY_STUB=""; NOTIFY_LOG=""
setup() {
	BASE="$(mktemp -d -t anchor-publish-health-test.XXXXXX)"
	STUB="$BASE/curl-stub.sh"
	LOG="$BASE/health.log"
	NOTIFY_STUB="$BASE/notify-stub.sh"
	NOTIFY_LOG="$BASE/notify.log"
	# Recording notify stub: emulates `notify.sh <priority> <title> <message>`
	# by appending one pipe-delimited line per call. No real ntfy network call.
	cat > "$NOTIFY_STUB" <<NOTIFYEOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$NOTIFY_LOG"
NOTIFYEOF
	chmod +x "$NOTIFY_STUB"
	# Recording curl stub. Emulates:
	#   curl -sS -o <outfile> -w "%{http_code}" --max-time N <url>
	# Serves per-URL fixture body + code from env set by each case:
	#   SRC_BODY_FILE / SRC_CODE  and  RCPT_BODY_FILE / RCPT_CODE
	# For simulating a retry sequence (transient-then-success, or all-fail),
	# a case may instead set SRC_CODE_SEQ / RCPT_CODE_SEQ — a space-separated
	# list of codes, one per successive attempt against that URL (the last
	# entry repeats if the checker makes more attempts than the list has
	# entries). Each URL's attempt count is recorded to
	# $STUB_STATE_DIR/{src,rcpt}.count so tests can assert exactly how many
	# curl calls fetch()'s retry loop made (e.g. "no needless retry" on a
	# first-attempt 200, or "exactly FYD_FETCH_ATTEMPTS calls" on all-fail).
	cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
outfile=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) outfile="$2"; shift 2 ;;
		-w|--max-time) shift 2 ;;
		-sS|-s|-S) shift ;;
		http*|file*) url="$1"; shift ;;
		*) shift ;;
	esac
done
statedir="${STUB_STATE_DIR:-.}"
if printf '%s' "$url" | grep -q 'anchor-source'; then
	body="${SRC_BODY_FILE:-/dev/null}"; code="${SRC_CODE:-200}"; seq="${SRC_CODE_SEQ:-}"
	countfile="$statedir/src.count"
else
	body="${RCPT_BODY_FILE:-/dev/null}"; code="${RCPT_CODE:-200}"; seq="${RCPT_CODE_SEQ:-}"
	countfile="$statedir/rcpt.count"
fi
n=0
[ -f "$countfile" ] && n="$(cat "$countfile")"
n=$((n + 1))
printf '%s' "$n" > "$countfile"
if [ -n "$seq" ]; then
	picked="$(printf '%s\n' $seq | sed -n "${n}p")"
	[ -n "$picked" ] && code="$picked" || code="$(printf '%s\n' $seq | tail -n1)"
fi
if [ -n "$outfile" ] && [ -f "$body" ]; then cat "$body" > "$outfile"; fi
printf '%s' "$code"
STUBEOF
	chmod +x "$STUB"
}
teardown() { rm -rf "$BASE"; BASE=""; }

# write_source <outfile> <dag_root_computed_hex>
write_source() {
	cat > "$1" <<JSON
{
  "schema_version": 1,
  "dag_root_computed": "$2"
}
JSON
}

# write_receipt <outfile> <anchored_hex>  (combined memo fya1c3:<hex> + dag_root_hash)
write_receipt() {
	cat > "$1" <<JSON
{
  "schema_version": 2,
  "cycle_number": 3,
  "dag_root_hash": "$2",
  "memo_prefix": "fya1c3",
  "anchor": {
    "actions": [
      {"branch": "identity",         "memo": "fya1c3-id:1111", "root_hex": "1111"},
      {"branch": "dag_root_summary", "memo": "fya1c3:$2", "root_hex": "$2"}
    ]
  }
}
JSON
}

run_checker() {
	# All fixture wiring comes through env; the checker never touches the network.
	# FYD_RETRY_SLEEP=0 always: the suite must never actually sleep between
	# retry attempts. STUB_STATE_DIR=$BASE gives the stub a place to record
	# per-URL attempt counts (see the stub above).
	FYD_CURL="$STUB" \
	FYD_NOTIFY="$NOTIFY_STUB" \
	ANCHOR_PUBLISH_HEALTH_LOG="$LOG" \
	ANCHOR_SOURCE_URL="https://example.test/api/anchor-source.json" \
	ANCHOR_RECEIPT_URL="https://example.test/api/anchor-receipt.json" \
	SRC_BODY_FILE="${SRC_BODY_FILE:-}" SRC_CODE="${SRC_CODE:-200}" SRC_CODE_SEQ="${SRC_CODE_SEQ:-}" \
	RCPT_BODY_FILE="${RCPT_BODY_FILE:-}" RCPT_CODE="${RCPT_CODE:-200}" RCPT_CODE_SEQ="${RCPT_CODE_SEQ:-}" \
	STUB_STATE_DIR="$BASE" \
	FYD_RETRY_SLEEP=0 \
	FYD_FETCH_ATTEMPTS="${FYD_FETCH_ATTEMPTS:-3}" \
		bash "$CHECKER" "$@"
}
alerts() { cat "$NOTIFY_LOG" 2>/dev/null; }
src_calls()  { cat "$BASE/src.count"  2>/dev/null || echo 0; }
rcpt_calls() { cat "$BASE/rcpt.count" 2>/dev/null || echo 0; }

# ---- case 1: 200 + dag matches on-chain anchored root -> OK (exit 0) ----------
setup
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
write_source  "$SRC_BODY_FILE"  "$ROOT_MATCH"
write_receipt "$RCPT_BODY_FILE" "$ROOT_MATCH"
SRC_CODE=200 RCPT_CODE=200 run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "match: 200 + dag matches -> exit 0" \
	|| bad "match: expected exit 0, got $RC"
[ -s "$NOTIFY_LOG" ] \
	&& bad "match: no alert fired on the healthy path (alerts: $(alerts))" \
	|| ok "match: no alert fired on the healthy path"
[ "$(src_calls)" -eq 1 ] \
	&& ok "match: first-attempt 200 makes exactly 1 curl call (no needless retry)" \
	|| bad "match: expected 1 source curl call, got $(src_calls)"
teardown

# ---- case 2: 200 but dag MISMATCH (the stale-publish case) -> alert exit 3 ----
setup
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
write_source  "$SRC_BODY_FILE"  "$ROOT_STALE"   # served file is stale
write_receipt "$RCPT_BODY_FILE" "$ROOT_MATCH"   # on-chain anchored the real root
OUT="$(SRC_CODE=200 RCPT_CODE=200 run_checker 2>&1)"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "stale: 200 + dag mismatch -> exit 3" \
	|| bad "stale: expected exit 3, got $RC"
echo "$OUT" | grep -q 'content mismatch' \
	&& ok "stale: alert says content mismatch" \
	|| bad "stale: alert missing 'content mismatch' (out: $OUT)"
[ -s "$LOG" ] && grep -q 'ERROR content mismatch' "$LOG" \
	&& ok "stale: mismatch persisted to log" \
	|| bad "stale: mismatch not in log"
alerts | grep -q '^high|' \
	&& ok "stale: high-priority alert fired" \
	|| bad "stale: high-priority alert fired (alerts: $(alerts))"
alerts | grep -q 'exit 3' \
	&& ok "stale: alert surfaces exit code 3" \
	|| bad "stale: alert surfaces exit code 3 (alerts: $(alerts))"
[ "$(src_calls)" -eq 1 ] \
	&& ok "stale: content mismatch is not masked/delayed by the retry loop (1 curl call, immediate exit 3)" \
	|| bad "stale: expected 1 source curl call (200 on first try), got $(src_calls)"
teardown

# ---- case 3: source not served (non-200) -> alert exit 2, no recover ----------
setup
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
write_source  "$SRC_BODY_FILE"  "$ROOT_MATCH"
write_receipt "$RCPT_BODY_FILE" "$ROOT_MATCH"
OUT="$(SRC_CODE=404 RCPT_CODE=200 run_checker 2>&1)"
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "not-served: non-200 -> exit 2" \
	|| bad "not-served: expected exit 2, got $RC"
echo "$OUT" | grep -q 'no host recover' \
	&& ok "not-served: alert states alert-only (no recover)" \
	|| bad "not-served: alert missing no-recover note (out: $OUT)"
alerts | grep -q '^high|' \
	&& ok "not-served: high-priority alert fired" \
	|| bad "not-served: high-priority alert fired (alerts: $(alerts))"
alerts | grep -q 'exit 2' \
	&& ok "not-served: alert surfaces exit code 2" \
	|| bad "not-served: alert surfaces exit code 2 (alerts: $(alerts))"
[ "$(src_calls)" -eq 3 ] \
	&& ok "not-served: constant non-200 exhausts all FYD_FETCH_ATTEMPTS (3) before failing" \
	|| bad "not-served: expected 3 source curl calls, got $(src_calls)"
[ "$(alerts | wc -l | tr -d ' ')" -eq 1 ] \
	&& ok "not-served: exactly one alert fired (retries do not alert per-attempt)" \
	|| bad "not-served: expected exactly 1 alert, got $(alerts | wc -l | tr -d ' ') (alerts: $(alerts))"
teardown

# ---- case 4: source 200 but receipt unavailable -> warn exit 4 ----------------
setup
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
write_source  "$SRC_BODY_FILE"  "$ROOT_MATCH"
write_receipt "$RCPT_BODY_FILE" "$ROOT_MATCH"
OUT="$(SRC_CODE=200 RCPT_CODE=503 run_checker 2>&1)"
RC=$?
[ "$RC" -eq 4 ] \
	&& ok "no-receipt: cannot content-verify -> exit 4" \
	|| bad "no-receipt: expected exit 4, got $RC"
echo "$OUT" | grep -q 'cannot content-verify' \
	&& ok "no-receipt: alert says cannot content-verify" \
	|| bad "no-receipt: alert missing (out: $OUT)"
alerts | grep -q '^high|' \
	&& ok "no-receipt: high-priority alert fired" \
	|| bad "no-receipt: high-priority alert fired (alerts: $(alerts))"
alerts | grep -q 'exit 4' \
	&& ok "no-receipt: alert surfaces exit code 4" \
	|| bad "no-receipt: alert surfaces exit code 4 (alerts: $(alerts))"
teardown

# ---- case 5: source 200 but body unparseable -> alert exit 5 ------------------
setup
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
printf 'not json at all' > "$SRC_BODY_FILE"
write_receipt "$RCPT_BODY_FILE" "$ROOT_MATCH"
RC=0; SRC_CODE=200 RCPT_CODE=200 run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 5 ] \
	&& ok "corrupt-source: unparseable -> exit 5" \
	|| bad "corrupt-source: expected exit 5, got $RC"
alerts | grep -q '^high|' \
	&& ok "corrupt-source: high-priority alert fired" \
	|| bad "corrupt-source: high-priority alert fired (alerts: $(alerts))"
alerts | grep -q 'exit 5' \
	&& ok "corrupt-source: alert surfaces exit code 5" \
	|| bad "corrupt-source: alert surfaces exit code 5 (alerts: $(alerts))"
teardown

# ---- case 6: receipt fallback to dag_root_hash (no dag_root_summary action) ---
setup
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
write_source "$SRC_BODY_FILE" "$ROOT_MATCH"
cat > "$RCPT_BODY_FILE" <<JSON
{ "schema_version": 2, "dag_root_hash": "$ROOT_MATCH", "anchor": { "actions": [] } }
JSON
SRC_CODE=200 RCPT_CODE=200 run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "fallback: dag_root_hash used when no summary action -> exit 0" \
	|| bad "fallback: expected exit 0, got $RC"
[ -s "$NOTIFY_LOG" ] \
	&& bad "fallback: no alert fired on the healthy path (alerts: $(alerts))" \
	|| ok "fallback: no alert fired on the healthy path"
teardown

# ---- case 8 (D1): transient-then-success on the SOURCE fetch -> exit 0, no alert
# First attempt curl-fails (000), second attempt is 200 with a matching body.
# One success within FYD_FETCH_ATTEMPTS must heal silently — this is the exact
# 2026-07-15 16:00 UTC false-alarm scenario (single cross-region blip).
setup
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
write_source  "$SRC_BODY_FILE"  "$ROOT_MATCH"
write_receipt "$RCPT_BODY_FILE" "$ROOT_MATCH"
SRC_CODE_SEQ="000 200" RCPT_CODE=200 run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "transient-source: 000 then 200 heals silently -> exit 0" \
	|| bad "transient-source: expected exit 0, got $RC"
[ -s "$NOTIFY_LOG" ] \
	&& bad "transient-source: no alert fired after the retry heals (alerts: $(alerts))" \
	|| ok "transient-source: no alert fired after the retry heals"
[ "$(src_calls)" -eq 2 ] \
	&& ok "transient-source: exactly 2 curl calls (stopped retrying once 200 arrived)" \
	|| bad "transient-source: expected 2 source curl calls, got $(src_calls)"
teardown

# ---- case 9 (D1): all FYD_FETCH_ATTEMPTS fail on the SOURCE fetch -> exit 2 ---
# Every attempt curl-fails (000) — the persistent-outage case, distinct from
# case 8's single blip. Must still alert exactly once after exhausting retries.
setup
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
write_source  "$SRC_BODY_FILE"  "$ROOT_MATCH"
write_receipt "$RCPT_BODY_FILE" "$ROOT_MATCH"
OUT="$(SRC_CODE_SEQ="000 000 000" RCPT_CODE=200 run_checker 2>&1)"
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "persistent-outage: 000 on every attempt -> exit 2" \
	|| bad "persistent-outage: expected exit 2, got $RC"
echo "$OUT" | grep -q 'HTTP=000' \
	&& ok "persistent-outage: alert/log names the final attempt's HTTP=000" \
	|| bad "persistent-outage: alert/log missing HTTP=000 (out: $OUT)"
[ "$(src_calls)" -eq 3 ] \
	&& ok "persistent-outage: exhausted exactly FYD_FETCH_ATTEMPTS (3) source curl calls" \
	|| bad "persistent-outage: expected 3 source curl calls, got $(src_calls)"
[ "$(alerts | wc -l | tr -d ' ')" -eq 1 ] \
	&& ok "persistent-outage: exactly one alert fired" \
	|| bad "persistent-outage: expected exactly 1 alert, got $(alerts | wc -l | tr -d ' ') (alerts: $(alerts))"
teardown

# ---- case 10 (D1): retry also applies to the RECEIPT fetch (exit-4 path) ------
setup
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
write_source  "$SRC_BODY_FILE"  "$ROOT_MATCH"
write_receipt "$RCPT_BODY_FILE" "$ROOT_MATCH"
SRC_CODE=200 RCPT_CODE_SEQ="000 200" run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "transient-receipt: 000 then 200 on the receipt heals silently -> exit 0" \
	|| bad "transient-receipt: expected exit 0, got $RC"
[ -s "$NOTIFY_LOG" ] \
	&& bad "transient-receipt: no alert fired after the retry heals (alerts: $(alerts))" \
	|| ok "transient-receipt: no alert fired after the retry heals"
[ "$(rcpt_calls)" -eq 2 ] \
	&& ok "transient-receipt: exactly 2 curl calls on the receipt fetch" \
	|| bad "transient-receipt: expected 2 receipt curl calls, got $(rcpt_calls)"
teardown

# ---- case 11 (D2): default LOG path is repo-local, not /var/log ---------------
# Unset ANCHOR_PUBLISH_HEALTH_LOG entirely so the checker's own default
# applies. /var/log is not deploy-writable on the host (the historical bug);
# the repo-local logs/ dir (provisioned deploy:deploy by
# install-host-log-dir.sh) must be used instead, and must actually receive
# the write.
setup
DEFAULT_LOG="${REPO_ROOT}/logs/anchor-publish-health.log"
rm -f "$DEFAULT_LOG"
SRC_BODY_FILE="$BASE/src.json"; RCPT_BODY_FILE="$BASE/rcpt.json"
write_source  "$SRC_BODY_FILE"  "$ROOT_MATCH"
write_receipt "$RCPT_BODY_FILE" "$ROOT_MATCH"
FYD_CURL="$STUB" FYD_NOTIFY="$NOTIFY_STUB" \
ANCHOR_SOURCE_URL="https://example.test/api/anchor-source.json" \
ANCHOR_RECEIPT_URL="https://example.test/api/anchor-receipt.json" \
SRC_BODY_FILE="$SRC_BODY_FILE" SRC_CODE=404 SRC_CODE_SEQ="" \
RCPT_BODY_FILE="$RCPT_BODY_FILE" RCPT_CODE=200 RCPT_CODE_SEQ="" \
STUB_STATE_DIR="$BASE" FYD_RETRY_SLEEP=0 FYD_FETCH_ATTEMPTS=1 \
	bash "$CHECKER" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "default-log: unrelated sanity check, still exit 2 on not-served" \
	|| bad "default-log: expected exit 2, got $RC"
if [ -w "$(dirname "$DEFAULT_LOG")" ]; then
	[ -f "$DEFAULT_LOG" ] && grep -q 'not served' "$DEFAULT_LOG" \
		&& ok "default-log: default LOG path (repo-local logs/) actually received the write" \
		|| bad "default-log: expected $DEFAULT_LOG to contain the failure line"
else
	echo "SKIP  default-log: ${REPO_ROOT}/logs not writable in this environment (unexpected in a dev checkout)"
fi
rm -f "$DEFAULT_LOG"
teardown

# ---- case 7: dead auto-recover removed (no live push-to-web-host invocation) --
# The header comment may still NAME push-to-web-host.sh to explain why recovery
# was removed; what must be gone is any executable (non-comment) call to it.
if grep -vE '^\s*#' "$CHECKER" | grep -q 'push-to-web-host'; then
	bad "dead-recover: live push-to-web-host.sh invocation still present in checker"
else
	ok "dead-recover: no executable push-to-web-host.sh call (auto-recover removed)"
fi

# ---- summary -----------------------------------------------------------------
echo "test-check-anchor-publish-health.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
