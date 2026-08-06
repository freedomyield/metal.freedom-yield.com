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
PUB_IP6_3="$(printf '%s::%s' 2000 1)"
PUB_IP6_4="$(printf '%s:%s::%s' 2620 fe fe)"
FAKE_PHONE="$(printf '090%s' 12345678)"
FAKE_PHONE_H="$(printf '090-%s-%s' 1234 5678)"
FAKE_EMAIL="$(printf 'user@%s' badactor.io)"
# The literal bypass-flag text, assembled at runtime so this tracked test
# file never contains the raw flag string (which would itself trip the
# Bash-tool PreToolUse hook when *this file* is committed/edited by an
# agent session with that hook wired in -- see round-2 review notes).
NOVERIFY_FLAG="$(printf -- '--no-ver%s' ify)"
DASH_N="$(printf -- '-%s' n)"

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
run_text "public IPv6 (assembled, reviewer-tested case A) -> block" 1 --text "host ${PUB_IP6_3} up"
run_text "public IPv6 (assembled, reviewer-tested case B, Quad9) -> block" 1 --text "host ${PUB_IP6_4} up"

echo "== IPv6 false-positive: CSS/code '::' syntax (not an address) =="
# Real-world regression (2026-08-05/06): these all false-positived as
# "public-IPv6 literal" before the minimum-specificity fix, because a single
# hex-looking char/word adjacent to "::" is syntactically valid (if absurdly
# minimal) compressed IPv6 shorthand.
#
# NOTE (round-2 review, I3): ".foo::before" / ".foo::after" do NOT exercise
# the regex at all (the 'o' immediately before "::" is not a hex character,
# so no candidate address is even matched) -- they passed vacuously
# regardless of any gate logic and gave false confidence. Replaced with the
# ACTUAL selectors found in public/styles.css, where the preceding character
# genuinely is hex (h3::before's "3", "-badge::before"'s "e", etc.) and the
# regex genuinely matches a candidate that the gate must then correctly
# exclude.
run_text "CSS pseudo-element (reported repro, pre::-webkit-scrollbar) -> allow" 0 --text "pre::-webkit-scrollbar { display:none }"
run_text "real selector public/styles.css: h3::before -> allow"  0 --text ".footer-brand h3::before { content:'' }"
run_text "real selector public/styles.css: .status-badge::before -> allow" 0 --text ".status-badge::before { content:'' }"
run_text "real selector public/styles.css: .commitment-card::before -> allow" 0 --text ".commitment-card::before { content:'' }"
run_text "real selector public/styles.css: td::before -> allow"  0 --text ".evidence-table tbody td::before { content:'' }"
run_text "real selector public/styles.css: .nav-dropdown-toggle::before -> allow" 0 --text ".nav-dropdown > .nav-dropdown-toggle::before { content:'' }"
run_text "C++ namespace std::vector -> allow"      0 --text "std::vector<int> v;"
run_text "namespace Foo::Bar -> allow"             0 --text "Foo::Bar::method()"
run_text "generic a::b code -> allow"              0 --text "let x = a::b;"
run_text "mutation-guard: real IPv6 amid CSS '::' syntax -> still block" 1 --text "selector::before { content:'host ${PUB_IP6}' }"

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

echo "== Bash hook-bypass false-positive: '-n' inside message prose (not a flag) =="
# Real-world regression (2026-08-05/06): a commit message that merely mentions
# the literal text "bash -n" (e.g. documenting a syntax-check step) was
# refused as if -n/--no-verify had been passed as an actual flag.
run_json "msg mentions 'bash -n' (double-quoted) -> allow" 0 "$(jq -nc --arg c 'git commit -m "docs: mention bash -n check"' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "msg mentions 'bash -n' (single-quoted) -> allow" 0 "$(jq -nc --arg c "git commit -m 'bash -n check'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "msg mentions 'bash -n' (escaped double-quote) -> allow" 0 "$(jq -nc --arg c 'git commit -m "she said \"bash -n\" then"' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "unrelated -n from a different subcommand's own flag -> allow" 0 "$(jq -nc --arg c 'git log --oneline -n 5' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "empty command -> allow"                  0 "$(jq -nc --arg c '' '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass mutation-guard: real flag still caught (incl. hidden in quotes) =="
run_json "mutation-guard: --no-verify hidden inside quotes (evasion attempt) -> block" 2 "$(jq -nc --arg c 'git commit -m x "--no-verify"' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "mutation-guard: -n hidden inside single quotes (evasion attempt) -> block" 2 "$(jq -nc --arg c "git push origin main '-n'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "mutation-guard: msg mentions -n AND a real -n flag is also present -> block" 2 "$(jq -nc --arg c 'git commit -m "used bash -n earlier" -n' '{tool_name:"Bash",tool_input:{command:$c}}')"
# (assigned to a var first, not inlined: an odd embedded-quote count inline
# as a positional arg trips a macOS /bin/bash 3.2 command-substitution
# parsing quirk unrelated to publish-guard.sh; assignment form is unaffected)
UNBAL_JSON="$(jq -nc --arg c 'git commit -m "unterminated --no-verify' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "mutation-guard: unbalanced quote -> fail-closed fallback still blocks" 2 "$UNBAL_JSON"

echo "== Bash hook-bypass C1: six real, verified evasion forms must still BLOCK =="
# Round-2 review (2026-08-06): a prior fix (Text::ParseWords tokenization)
# eliminated the false positive above but opened six REAL, verified
# hook-bypass forms -- confirmed with actual hook execution in a throwaway
# repo (git's own pre-commit hook genuinely did not fire for any of these;
# see round-2 report for the transcript). A real shell expands every one of
# these to the literal flag at execution time; a static tokenizer resolves
# none of them. The fix reverted to a blind substring scan (which does not
# need to resolve any of this) plus narrow value-stripping for message
# options only.
run_json "C1-1 ANSI-C quoting \$'--no-verify' -> block" 2 \
	"$(jq -nc --arg c "git commit -m x \$'${NOVERIFY_FLAG}'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "C1-2 variable indirection F=--no-verify; ... \$F -> block" 2 \
	"$(jq -nc --arg c "F=${NOVERIFY_FLAG}; git commit -m x \$F" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "C1-3 command substitution \$(echo --no-verify) -> block" 2 \
	"$(jq -nc --arg c "git commit -m x \$(echo ${NOVERIFY_FLAG})" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "C1-4 backtick \`echo --no-verify\` -> block" 2 \
	"$(jq -nc --arg c "git commit -m x \`echo ${NOVERIFY_FLAG}\`" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "C1-5 parameter expansion default \${Q:---no-verify} -> block" 2 \
	"$(jq -nc --arg c "git commit -m x \${Q:-${NOVERIFY_FLAG}}" '{tool_name:"Bash",tool_input:{command:$c}}')"
LINECONT_CMD="$(printf 'git commit -m x \\\n%s' "$NOVERIFY_FLAG")"
run_json "C1-6 backslash-newline line continuation -> block" 2 \
	"$(jq -nc --arg c "$LINECONT_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass N1: value-stripper must not eat a real flag after an arbitrary -m/-F/-c/-C/-t-ending token ==="
# Round-3 review (2026-08-06): the round-2 stripper excluded only "preceded
# by another dash" (?<!-), not a full left word-boundary. Any token ending
# in -m/-F/-c/-C/-t (e.g. "file-c", "foo-m", "A-F") misparsed as a real
# short flag, and the value branch then ate the NEXT, genuine token as its
# bogus "value" -- silently swallowing a real --no-verify/-n sitting right
# after it. Confirmed with real hook execution: git COMMITTED and the real
# pre-commit hook was SKIPPED for every one of these before the fix.
run_json "N1-1 file-c eats a real --no-verify -> block" 2 \
	"$(jq -nc --arg c "git commit -m x file-c ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N1-2 foo-m eats a real --no-verify -> block" 2 \
	"$(jq -nc --arg c "git commit -m x foo-m ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N1-3 pre-t eats a real --no-verify -> block" 2 \
	"$(jq -nc --arg c "git commit -m x pre-t ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N1-4 A-F eats a real --no-verify -> block" 2 \
	"$(jq -nc --arg c "git commit -m x A-F ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N1-5 A-C eats a real --no-verify -> block" 2 \
	"$(jq -nc --arg c "git commit -m x A-C ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N1-6 file-c eats a real -n -> block" 2 \
	"$(jq -nc --arg c "git commit -m x file-c ${DASH_N}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N1-7 file-c eats a quoted --no-verify -> block" 2 \
	"$(jq -nc --arg c "git commit -m x file-c \"${NOVERIFY_FLAG}\"" '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass N2: bundled short options (-am/-sm/-qm) must still strip the message value ==="
# Round-3 review (2026-08-06): the round-2 stripper only recognized a bare
# -m, not -m bundled with another boolean short flag in the same token
# (e.g. "-am" = -a + -m). "git commit -am \"...\"" is one of the single most
# common invocations, so the ORIGINALLY reported false-positive class (a
# message mentioning "bash -n") was reintroduced under this form, and the
# round-2 -n boundary widening made it worse (a bare -n followed only by
# the messages own closing quote, no space, newly matched too). Fixed by
# recognizing bundled forms (-[A-Za-z]*[mFcCt]) and narrowing the -n
# boundary back down (see gap-closure section above).
run_json "N2-1 -am bundled -> allow" 0 \
	"$(jq -nc --arg c "git commit -am \"docs: mention bash ${DASH_N} check\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N2-2 -sm bundled -> allow" 0 \
	"$(jq -nc --arg c "git commit -sm \"docs: mention bash ${DASH_N} check\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N2-3 -qm bundled -> allow" 0 \
	"$(jq -nc --arg c "git commit -qm \"docs: mention bash ${DASH_N} check\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N2-4 -am bundled, single-quoted message -> allow" 0 \
	"$(jq -nc --arg c "git commit -am 'bash ${DASH_N} check'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N2-5 -am bundled, -n at the very end of the message -> allow" 0 \
	"$(jq -nc --arg c "git commit -am \"docs mention bash ${DASH_N}\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N2-6 --amend -am bundled -> allow" 0 \
	"$(jq -nc --arg c "git commit --amend -am \"docs: mention bash ${DASH_N} check\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "N2-7 -am bundled, -n mid-message -> allow" 0 \
	"$(jq -nc --arg c "git commit -am \"first ${DASH_N} second\"" '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass gap closure: a lone -n fully wrapped in matching quotes -> block =="
# Round-3 (2026-08-06): the -n boundary went through two shapes. Round 2
# widened it to "any adjacent quote counts as a boundary", which itself
# reintroduced a false positive (see N2 below: an unstripped messages own
# closing quote, sitting right after "-n" deep in prose, satisfied it).
# Round 3 narrowed it back to whitespace/start/end PLUS two explicit
# alternatives for a lone -n wrapped in a MATCHED quote pair ('-n' / "-n"
# as a whole standalone token) -- precise enough to still catch this
# deliberate-quoting case without the prose false positive.
run_json "-n hidden in single quotes -> block"     2 "$(jq -nc --arg c "git push origin main '${DASH_N}'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "-n hidden in double quotes -> block"     2 "$(jq -nc --arg c "git push origin main \"${DASH_N}\"" '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass value-stripping precision (regression guards for the stripper itself) =="
# These caught real bugs in earlier drafts of the value-stripping regex:
# (a) "--message" contains the substring "-m", which without a (?<!-)
#     lookbehind got misidentified as a bare short "-m" flag; (b) splitting
#     the stripping into separate sequential passes let an already-bare flag
#     get re-matched by a later pass, swallowing an unrelated SUBSEQUENT
#     flag as if it were that flag's "value".
run_json "long --message= form, real -n flag follows -> block" 2 \
	"$(jq -nc --arg c "git commit --message=\"text with ${DASH_N} inside\" ${DASH_N}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "attached -mVALUE (no space), real flag follows -> block" 2 \
	"$(jq -nc --arg c "git commit -mx ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "attached -m\"quoted value\", real flag follows -> block" 2 \
	"$(jq -nc --arg c "git commit -m\"prose bash ${DASH_N}\" ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "-F value, real -n flag follows -> block" 2 \
	"$(jq -nc --arg c "git commit -F somefile.txt ${DASH_N}" '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass sanity: widened -n boundary must not false-positive on ordinary hyphenated text =="
run_json "sanity: -n1 attached (not a bare -n token) -> allow" 0 "$(jq -nc --arg c 'git status -n1' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "sanity: -n substring inside an ordinary word -> allow" 0 "$(jq -nc --arg c 'echo hyphenated-nomenclature-here' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "sanity: hyphenated filename positional arg -> allow" 0 "$(jq -nc --arg c 'git commit -m x path/to/co-narrator-file.txt' '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass I1: perl unavailable/misbehaving must still fail-closed (never silently allow) =="
# Round-2 review (2026-08-06): the trust signal for "did the value-stripper
# actually run" must not be the perl exit code alone -- a broken/replaced
# "perl" that merely exits 0 or 1 (the same two codes a clean run uses)
# would be indistinguishable from a genuine decision and silently let a real
# --no-verify through. Verified here by shadowing "perl" on PATH with a
# minimal broken stand-in for the duration of a single invocation only (no
# system perl is touched or modified).
I1_FAKEBIN="$(mktemp -d -t pubguard-i1fakebin.XXXXXX)"
printf '#!/bin/sh\nexit 1\n' > "$I1_FAKEBIN/perl"
chmod +x "$I1_FAKEBIN/perl"
I1_JSON="$(jq -nc --arg c "git commit -m x ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
printf '%s' "$I1_JSON" | PATH="$I1_FAKEBIN:$PATH" bash "$GUARD" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then printf 'PASS  %-62s (rc=%d)\n' "I1: real --no-verify blocked even with broken perl on PATH" "$rc"; PASS=$((PASS+1))
else printf 'FAIL  %-62s (rc=%d, want 2)\n' "I1: real --no-verify blocked even with broken perl on PATH" "$rc" >&2; FAIL=$((FAIL+1)); fi
rm -rf "$I1_FAKEBIN"

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
