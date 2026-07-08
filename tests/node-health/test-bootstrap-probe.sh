#!/usr/bin/env bash
# tests/node-health/test-bootstrap-probe.sh
#
# R10: scripts/node-health-daily.sh used to write a hardcoded
# bootstrap:{p,x,c}=true into the permanent history AND the public API,
# regardless of actual metalgo state. This test verifies the real
# probe_bootstrapped() function (extracted verbatim from the live script
# via `awk`, so this test cannot silently drift from the shipped code)
# returns the actually-probed boolean, and — critically — "null" (never a
# fabricated true/false) whenever the RPC is unreachable, malformed, or
# missing the expected field.
#
# Hard constraints:
#   - No production state, host, or metalgo instance is touched.
#   - Real ntfy.sh / metalgo RPC is NEVER contacted. A stub `curl` on PATH
#     answers every call.
#   - The full node-health-daily.sh script is NOT invoked (it has no env
#     override for its public-output path, so an end-to-end run would write
#     into the tracked public/api/node-health-recent.json). This test
#     exercises the extracted probe function in isolation instead.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/node-health-daily.sh"

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

# === extract the real probe_bootstrapped() from the live script ==========
FN_FILE="$TMP/probe_bootstrapped.sh"
awk '/^probe_bootstrapped\(\) \{/,/^}/' "$SCRIPT" > "$FN_FILE"
if [ ! -s "$FN_FILE" ]; then
  echo "FAIL: could not extract probe_bootstrapped() from $SCRIPT (function renamed/moved?)" >&2
  exit 2
fi

# === no hardcoded true/false literal survives in the source ==============
# Guards against a regression that reintroduces `bootstrap: { p: true, ... }`
# anywhere in the assembled jq filter.
if grep -q 'p: true, x: true, c: true' "$SCRIPT"; then
  FAIL=$((FAIL + 1))
  FAILURES+=("source still contains hardcoded bootstrap:{p:true,x:true,c:true}")
  printf '  FAIL  %-55s\n' "no hardcoded bootstrap true literal in source"
else
  PASS=$((PASS + 1))
  printf '  PASS  %-55s\n' "no hardcoded bootstrap true literal in source"
fi

# === stub-curl factory ====================================================
mkdir -p "$TMP/bin"
write_stub_curl_body() {
  local body="$1" rc="${2:-0}"
  cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s' '${body}'
exit ${rc}
EOF
  chmod +x "$TMP/bin/curl"
}

run_probe() {
  local chain="$1"
  PATH="$TMP/bin:$PATH" API="http://127.0.0.1:9650" bash -c "
    set -uo pipefail
    $(cat "$FN_FILE")
    probe_bootstrapped '$chain'
  "
}

echo "=== R10 probe_bootstrapped() classification ==="

# --- real RPC success: isBootstrapped true/false --------------------------
write_stub_curl_body '{"jsonrpc":"2.0","id":1,"result":{"isBootstrapped":true}}' 0
assert_eq "RPC result true -> \"true\""  "true"  "$(run_probe P)"

write_stub_curl_body '{"jsonrpc":"2.0","id":1,"result":{"isBootstrapped":false}}' 0
assert_eq "RPC result false -> \"false\"" "false" "$(run_probe C)"

# --- unprobeable: never fabricate, always surface null ---------------------
write_stub_curl_body '' 28   # curl timeout, empty body
assert_eq "curl transport failure -> \"null\"" "null" "$(run_probe X)"

write_stub_curl_body 'not json at all' 0
assert_eq "unparseable body -> \"null\"" "null" "$(run_probe P)"

write_stub_curl_body '{"jsonrpc":"2.0","id":1,"result":{}}' 0
assert_eq "missing isBootstrapped field -> \"null\"" "null" "$(run_probe X)"

write_stub_curl_body '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"chain not found"}}' 0
assert_eq "RPC error object -> \"null\"" "null" "$(run_probe C)"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
