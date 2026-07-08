#!/usr/bin/env bash
# test-publish-guard.sh — regression suite for scripts/publish-guard.sh
# (host-identifier + operator-PII publish guard).
#
# SAFETY: this test never embeds any real forbidden value (host IP, handle,
# real name, company, phone, personal email). It uses:
#   - benign words/CJK via FYD_PUBLISH_WORD_HASHES / FYD_PUBLISH_CJK_HASHES
#     set to the hash of a throwaway test token computed at runtime;
#   - public IPs / phones / emails ASSEMBLED from parts at runtime, so no
#     flaggable literal ever appears in this tracked file;
#   - FYD_PUBLISH_DENYLIST=/dev/null so the machine's real denylist is not read
#     (denylist behaviour is exercised separately with a temp file).
#
# Usage:  bash tests/publish-guard/test-publish-guard.sh
# Exit:   0 all pass / 1 any fail

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_ROOT}/scripts/publish-guard.sh"

if [ ! -x "$GUARD" ]; then
	echo "FATAL: publish-guard not executable at $GUARD" >&2
	exit 1
fi

# Isolate from the machine's real denylist.
export FYD_PUBLISH_DENYLIST=/dev/null

# Benign forbidden tokens (never the real ones).
TEST_WORD="zzguardtestzz"
TEST_WORD_HASH="$(printf '%s' "$TEST_WORD" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex(lc $_)')"
export FYD_PUBLISH_WORD_HASHES="$TEST_WORD_HASH"
TEST_CJK="偽データ標本"
TEST_CJK_HASH="$(printf '%s' "$TEST_CJK" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')"
export FYD_PUBLISH_CJK_HASHES="$TEST_CJK_HASH"

# Values assembled at runtime (no literal in this file).
PUB_IP="$(printf '%d.%d.%d.%d' 8 8 8 8)"
PUB_IP2="$(printf '%d.%d.%d.%d' 1 1 1 1)"
PUB_IP6="$(printf '%s:%s:%s::%s' 2606 4700 4700 1111)"
PUB_IP6_2="$(printf '%s:%s:%s:%s:%s:%s:%s:%s' 2607 f8b0 4004 c07 0 0 0 64)"
FAKE_PHONE="$(printf '090%s' 12345678)"
FAKE_PHONE_H="$(printf '090-%s-%s' 1234 5678)"
FAKE_EMAIL="$(printf 'user@%s' badactor.io)"

PASS=0
FAIL=0

run_text() {
	local name="$1" exp="$2" flag="$3" text="$4" rc
	printf '%s' "$text" | bash "$GUARD" $flag >/dev/null 2>&1
	rc=$?
	if [ "$rc" -eq "$exp" ]; then printf 'PASS  %-62s (rc=%d)\n' "$name" "$rc"; PASS=$((PASS+1))
	else printf 'FAIL  %-62s (rc=%d, want %d)\n' "$name" "$rc" "$exp" >&2; FAIL=$((FAIL+1)); fi
}
run_json() {
	local name="$1" exp="$2" json="$3" rc
	printf '%s' "$json" | bash "$GUARD" >/dev/null 2>&1
	rc=$?
	if [ "$rc" -eq "$exp" ]; then printf 'PASS  %-62s (rc=%d)\n' "$name" "$rc"; PASS=$((PASS+1))
	else printf 'FAIL  %-62s (rc=%d, want %d)\n' "$name" "$rc" "$exp" >&2; FAIL=$((FAIL+1)); fi
}

echo "== IP =="
run_text "clean prose -> allow"                    0 --text "the validator is healthy"
run_text "public IPv4 -> block"                    1 --text "host ${PUB_IP}:9651"
run_text "public IPv4 (second, assembled) -> block" 1 --text "dns ${PUB_IP2}"
run_text "RFC5737 doc IP -> allow"                 0 --text "example 203.0.113.10"
run_text "private 10/8 -> allow"                   0 --text "internal 10.1.2.3"
run_text "private 192.168 -> allow"                0 --text "lan 192.168.1.1"
run_text "loopback -> allow"                       0 --text "bind 127.0.0.1"
run_text "octet >255 not an IP -> allow"           0 --text "ver 300.1.2.3"
run_text "block-height number -> allow"            0 --text "block 393061488 height"

echo "== IPv6 =="
run_text "public IPv6 (assembled) -> block"         1 --text "host ${PUB_IP6} up"
run_text "public IPv6 uncompressed (assembled) -> block" 1 --text "addr ${PUB_IP6_2} up"
run_text "doc 2001:db8::/32 -> allow"               0 --text "example 2001:db8::1"
run_text "link-local fe80::/10 -> allow"            0 --text "iface fe80::1"
run_text "loopback ::1 -> allow"                    0 --text "bind ::1"
run_text "unique-local fc00::/7 -> allow"           0 --text "internal fc00::1"
run_text "multicast ff00::/8 -> allow"              0 --text "mcast ff02::1"
run_text "MAC address (not IPv6) -> allow"          0 --text "mac 00:1a:2b:3c:4d:5e"
run_text "time-like colon string -> allow"          0 --text "at 14:32:10 today"
run_text "diff: added public IPv6 -> block"         1 --diff "$(printf '+++ b/x.md\n+host %s\n ctx' "$PUB_IP6")"

echo "== phone =="
run_text "JP mobile (no sep) -> block"             1 --text "call ${FAKE_PHONE} now"
run_text "JP mobile (hyphen) -> block"             1 --text "tel ${FAKE_PHONE_H}"
run_text "9-digit non-phone -> allow"              0 --text "id 123456789 ok"

echo "== email =="
run_text "non-allowlisted email -> block"          1 --text "reply ${FAKE_EMAIL}"
run_text "public contact email -> allow"           0 --text "contact info@metal.freedom-yield.com"
run_text "anthropic trailer email -> allow"        0 --text "Co-Authored-By: X <noreply@anthropic.com>"
run_text "example.com email -> allow"              0 --text "demo user@example.com"
run_text "reserved-TLD .invalid email -> allow"    0 --text "ph x@host.invalid"
run_text "reserved-TLD .local email -> allow"      0 --text "mdns box@printer.local"

echo "== forbidden word (hash) =="
run_text "forbidden word -> block"                 1 --text "signed by ${TEST_WORD} today"
run_text "forbidden word case-insensitive -> block" 1 --text "ZZGUARDTESTZZ"
run_text "benign word -> allow"                    0 --text "operator placeholder handle"

echo "== forbidden CJK (hash) =="
run_text "forbidden CJK standalone -> block"       1 --text "$TEST_CJK"
run_text "benign CJK -> allow"                     0 --text "正常稼働中です"

echo "== diff mode =="
run_text "diff: added public IP -> block"          1 --diff "$(printf '+++ b/x.md\n+host %s\n ctx' "$PUB_IP")"
run_text "diff: removed-only public IP -> allow"   0 --diff "$(printf -- '--- a/x\n-old %s\n+clean' "$PUB_IP")"

echo "== Bash hook-bypass =="
run_json "git commit --no-verify -> block"         2 "$(jq -nc --arg c 'git commit -m x --no-verify' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "git push -n -> block"                    2 "$(jq -nc --arg c 'git push origin main -n' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "normal git commit -> allow"              0 "$(jq -nc --arg c 'git commit -m x' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "unrelated command -> allow"              0 "$(jq -nc --arg c 'ls -la' '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Write/Edit =="
run_json "write public IP -> tracked README block" 2 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
run_json "write phone -> tracked README block"     2 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "tel $FAKE_PHONE" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
run_json "write clean -> tracked allow"            0 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "all good" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
run_json "write IP -> path OUTSIDE repo allow"     0 "$(jq -nc --arg fp "/tmp/x.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
run_json "edit forbidden word -> tracked block"    2 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "$TEST_WORD" '{tool_name:"Edit",tool_input:{file_path:$fp,new_string:$c}}')"
run_json "multiedit public IP -> block"            2 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "host $PUB_IP" '{tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[{old_string:"a",new_string:"b"},{old_string:"c",new_string:$c}]}}')"
run_json "read tool -> allow"                      0 "$(jq -nc '{tool_name:"Read",tool_input:{file_path:"/x"}}')"

echo "== gitignore-skip =="
EXCL="$REPO_ROOT/.git/info/exclude"
IGN_NAME="guardtest-ignored-$$.md"
printf '%s\n' "$IGN_NAME" >> "$EXCL"
run_json "write IP into gitignored file -> allow"  0 "$(jq -nc --arg fp "$REPO_ROOT/$IGN_NAME" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
grep -vF "$IGN_NAME" "$EXCL" > "$EXCL.tmp" 2>/dev/null && mv "$EXCL.tmp" "$EXCL"

echo "== local denylist (exact substring, incl. embedded) =="
DENY_TMP="$(mktemp -t pubguard-deny.XXXXXX)"
printf '%s\n' "# c" "SecretHostAlias" > "$DENY_TMP"
FYD_PUBLISH_DENYLIST="$DENY_TMP" bash "$GUARD" --text >/dev/null 2>&1 <<<"connect SecretHostAlias xyz"; rc=$?
[ "$rc" -eq 1 ] && { printf 'PASS  %-62s (rc=%d)\n' "denylist substring embedded -> block" "$rc"; PASS=$((PASS+1)); } \
	|| { printf 'FAIL  %-62s (rc=%d, want 1)\n' "denylist substring embedded -> block" "$rc" >&2; FAIL=$((FAIL+1)); }
FYD_PUBLISH_DENYLIST="$DENY_TMP" bash "$GUARD" --text >/dev/null 2>&1 <<<"nothing here"; rc=$?
[ "$rc" -eq 0 ] && { printf 'PASS  %-62s (rc=%d)\n' "denylist clean -> allow" "$rc"; PASS=$((PASS+1)); } \
	|| { printf 'FAIL  %-62s (rc=%d, want 0)\n' "denylist clean -> allow" "$rc" >&2; FAIL=$((FAIL+1)); }
rm -f "$DENY_TMP"

echo
echo "----------------------------------------"
echo "test-publish-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
