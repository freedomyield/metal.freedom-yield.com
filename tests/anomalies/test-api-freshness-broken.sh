#!/usr/bin/env bash
# tests/anomalies/test-api-freshness-broken.sh
#
# R11: the api_freshness watchdog in scripts/check-anomalies.sh used to only
# alert on STALE /api/validator.json (observedAt too old) and stayed
# completely silent when the endpoint itself was broken — missing,
# unreachable, HTTP error, or unparseable JSON — even though the site root
# (/health) was healthy. This test extracts the real transition block
# verbatim (via `sed`, anchored on its marker comments, so this test cannot
# silently drift from the shipped code) and exercises it against a stub
# `curl` covering: HTTP 200 fresh / HTTP 200 stale / HTTP 500 / curl
# transport failure / HTTP 200 with invalid JSON body / HTTP 200 with valid
# JSON missing observedAt — verifying every broken case fires exactly one
# alert (ok -> warn) and none of them alert twice (warn -> warn, dedup).
#
# Strategy mirrors tests/anomalies/test-candidate-state.sh: no real
# ntfy.sh call, no production state/lock file, no flock dependency (this
# extracted block doesn't touch the K-4 lock), so it runs on macOS too.
#
# GNU-date dependency: the extracted block uses `date -d` (GNU). On Linux
# the system `date` already provides this. On macOS, `gdate` (coreutils via
# Homebrew) is required; if neither is available the suite SKIPs with a
# clear reason instead of silently testing wrong semantics.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/check-anomalies.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILURES=()

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %-55s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$label (expected='$expected', actual='$actual')")
    printf '  FAIL  %-55s expected=%s actual=%s\n' "$label" "$expected" "$actual"
  fi
}

# === GNU date resolution (Linux native / macOS via gdate) ================
if [ "$(uname)" = "Linux" ]; then
  DATE_REAL="$(command -v date)"
elif command -v gdate >/dev/null 2>&1; then
  DATE_REAL="$(command -v gdate)"
else
  echo "SKIP: test-api-freshness-broken.sh requires GNU date (Linux 'date' or macOS 'gdate' via Homebrew coreutils)"
  exit 0
fi

# === extract the real api_freshness transition block from the live script
BLOCK_FILE="$TMP/api_freshness_block.sh"
sed -n '/^# === transition: api_freshness/,/^fi$/p' "$SCRIPT" > "$BLOCK_FILE"
if [ ! -s "$BLOCK_FILE" ]; then
  echo "FAIL: could not extract api_freshness transition block from $SCRIPT (markers moved/renamed?)" >&2
  exit 2
fi
# Sanity: the extracted block must contain the R11 "broken" branch, or this
# test is exercising stale pre-R11 code without knowing it.
if ! grep -q "endpoint 破損" "$BLOCK_FILE"; then
  echo "FAIL: extracted block missing the R11 'endpoint 破損' broken-alert branch" >&2
  exit 2
fi

mkdir -p "$TMP/bin"

# === stub curl: honours -o <file> and -w '%{http_code}', matching the
# exact invocation shape used by the extracted block. Controlled via env:
#   STUB_CURL_BODY  content written to the -o target (default: empty)
#   STUB_CURL_HTTP  string printed to stdout as the http_code (default: 200)
#   STUB_CURL_RC    curl's own exit code (default: 0)
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
outfile=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then outfile="$a"; fi
  prev="$a"
done
if [ -n "$outfile" ]; then
  printf '%s' "${STUB_CURL_BODY:-}" > "$outfile"
fi
printf '%s' "${STUB_CURL_HTTP:-200}"
exit "${STUB_CURL_RC:-0}"
EOF
chmod +x "$TMP/bin/curl"

# === stub date: forwards to the resolved GNU date binary regardless of
# which literal name ("date" vs "gdate") the test host provides it under.
cat > "$TMP/bin/date" <<EOF
#!/usr/bin/env bash
exec "$DATE_REAL" "\$@"
EOF
chmod +x "$TMP/bin/date"

# set_stub_curl <http_code> <body> [<curl_rc>] — the stub curl is invoked
# from a `bash -c` child process spawned inside run_case (a real exec, not
# a plain subshell), so these must be genuinely exported to cross that
# process boundary — plain prefix-assignment on an assignment-only command
# line ("VAR=x OUT=$(...)") does NOT export, it only sets a shell-local var.
export STUB_CURL_HTTP STUB_CURL_BODY STUB_CURL_RC
set_stub_curl() {
  STUB_CURL_HTTP="$1"
  STUB_CURL_BODY="$2"
  STUB_CURL_RC="${3:-0}"
}

# run_case <orig_fresh> <web_status> -> prints "candidate_field=<val|none> notify_calls=<n> notify_titles=<t1;t2;...>"
run_case() {
  local orig_fresh="$1" web_status="$2"
  PATH="$TMP/bin:$PATH" bash -c '
    set -uo pipefail
    ORIG_FRESH_FIXTURE="'"$orig_fresh"'"
    OBS_WEB_STATUS="'"$web_status"'"
    WEB_URL="https://example.invalid"

    orig_get() { printf "%s" "$ORIG_FRESH_FIXTURE"; }
    NOTIFY_CALLS=0
    NOTIFY_TITLES=""
    notify_or_keep() {
      local prio="$1" title="$2" body="$3"
      NOTIFY_CALLS=$((NOTIFY_CALLS + 1))
      NOTIFY_TITLES="${NOTIFY_TITLES}${NOTIFY_TITLES:+;}${title}"
      return 0
    }
    CANDIDATE_FIELD_VAL="none"
    candidate_set() {
      local path="$1" val="$2"
      if [ "$path" = ".api_freshness" ]; then CANDIDATE_FIELD_VAL="$val"; fi
      return 0
    }

    '"$(cat "$BLOCK_FILE")"'

    printf "candidate_field=%s notify_calls=%s notify_titles=%s\n" \
      "$CANDIDATE_FIELD_VAL" "$NOTIFY_CALLS" "$NOTIFY_TITLES"
  '
}

field_of() { echo "$1" | sed -n 's/.*candidate_field=\([^ ]*\).*/\1/p'; }
calls_of() { echo "$1" | sed -n 's/.*notify_calls=\([^ ]*\).*/\1/p'; }

echo "=== R11 api_freshness broken-endpoint classification ==="

NOW_ISO_REAL=$("$DATE_REAL" -u +%Y-%m-%dT%H:%M:%SZ)

# --- baseline: healthy, fresh observedAt -> no transition, no alert ------
set_stub_curl 200 "{\"observedAt\":\"${NOW_ISO_REAL}\"}"
OUT=$(run_case ok 200)
assert_eq "fresh+ok: candidate untouched" "none" "$(field_of "$OUT")"
assert_eq "fresh+ok: no notify"           "0"    "$(calls_of "$OUT")"

# --- pre-existing STALE behaviour still works (regression guard) ---------
OLD_ISO_REAL=$("$DATE_REAL" -u -d '@'"$(( $("$DATE_REAL" +%s) - 1200 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || "$DATE_REAL" -u -r "$(( $("$DATE_REAL" +%s) - 1200 ))" +%Y-%m-%dT%H:%M:%SZ)
set_stub_curl 200 "{\"observedAt\":\"${OLD_ISO_REAL}\"}"
OUT=$(run_case ok 200)
assert_eq "stale (20min)+ok: candidate -> warn" '"warn"' "$(field_of "$OUT")"
assert_eq "stale (20min)+ok: 1 notify"           "1"      "$(calls_of "$OUT")"

# --- R11: HTTP 500 from the endpoint (site root healthy) -> broken alert -
set_stub_curl 500 "<html>error</html>"
OUT=$(run_case ok 200)
assert_eq "HTTP 500+ok: candidate -> warn" '"warn"' "$(field_of "$OUT")"
assert_eq "HTTP 500+ok: 1 notify"          "1"      "$(calls_of "$OUT")"

# --- R11: curl transport failure -> broken alert --------------------------
set_stub_curl 000 "" 7
OUT=$(run_case ok 200)
assert_eq "curl fail+ok: candidate -> warn" '"warn"' "$(field_of "$OUT")"
assert_eq "curl fail+ok: 1 notify"          "1"      "$(calls_of "$OUT")"

# --- R11: HTTP 200 but invalid JSON body -> broken alert ------------------
set_stub_curl 200 "not json at all"
OUT=$(run_case ok 200)
assert_eq "invalid JSON+ok: candidate -> warn" '"warn"' "$(field_of "$OUT")"
assert_eq "invalid JSON+ok: 1 notify"          "1"      "$(calls_of "$OUT")"

# --- R11: HTTP 200, valid JSON, but observedAt missing -> broken alert ---
set_stub_curl 200 '{"someOtherField":true}'
OUT=$(run_case ok 200)
assert_eq "missing observedAt+ok: candidate -> warn" '"warn"' "$(field_of "$OUT")"
assert_eq "missing observedAt+ok: 1 notify"          "1"      "$(calls_of "$OUT")"

# --- dedup: already warn (broken again) -> no re-notify, no re-set -------
set_stub_curl 500 "<html>error</html>"
OUT=$(run_case warn 200)
assert_eq "HTTP 500+already-warn: no re-notify" "0"    "$(calls_of "$OUT")"
assert_eq "HTTP 500+already-warn: candidate untouched" "none" "$(field_of "$OUT")"

# --- recovery: was warn, now fresh+valid -> candidate -> ok --------------
set_stub_curl 200 "{\"observedAt\":\"${NOW_ISO_REAL}\"}"
OUT=$(run_case warn 200)
assert_eq "recovery: candidate -> ok" '"ok"' "$(field_of "$OUT")"
assert_eq "recovery: 1 notify"        "1"    "$(calls_of "$OUT")"

# --- web-gated: site root itself down -> api_freshness check skipped -----
set_stub_curl 500 "<html>error</html>"
OUT=$(run_case ok 000)
assert_eq "site down: api_freshness untouched" "none" "$(field_of "$OUT")"
assert_eq "site down: no notify"               "0"    "$(calls_of "$OUT")"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
