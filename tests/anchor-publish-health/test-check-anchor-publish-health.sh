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
if printf '%s' "$url" | grep -q 'anchor-source'; then
	body="${SRC_BODY_FILE:-/dev/null}"; code="${SRC_CODE:-200}"
else
	body="${RCPT_BODY_FILE:-/dev/null}"; code="${RCPT_CODE:-200}"
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
	FYD_CURL="$STUB" \
	FYD_NOTIFY="$NOTIFY_STUB" \
	ANCHOR_PUBLISH_HEALTH_LOG="$LOG" \
	ANCHOR_SOURCE_URL="https://example.test/api/anchor-source.json" \
	ANCHOR_RECEIPT_URL="https://example.test/api/anchor-receipt.json" \
	SRC_BODY_FILE="${SRC_BODY_FILE:-}" SRC_CODE="${SRC_CODE:-200}" \
	RCPT_BODY_FILE="${RCPT_BODY_FILE:-}" RCPT_CODE="${RCPT_CODE:-200}" \
		bash "$CHECKER" "$@"
}
alerts() { cat "$NOTIFY_LOG" 2>/dev/null; }

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
