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

# Run from the repo under test. The guard derives its own REPO_ROOT from the
# CWD (`git rev-parse --show-toplevel`, falling back to `pwd`), so the caller's
# directory silently decided the outcome of the Write/Edit assertions: launched
# from an unrelated directory -- or from one that is not a git repository at
# all, such as a scratch dir -- four expected-block cases returned rc=0 and so
# "passed" without testing anything. Assertions that genuinely care about the
# CWD set it explicitly through run_json_cwd instead.
cd "$REPO_ROOT" || { echo "FATAL: cannot cd to $REPO_ROOT" >&2; exit 1; }

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
SKIP=0

run_text() {
	local name="$1" exp="$2" flag="$3" text="$4" rc
	printf '%s' "$text" | bash "$GUARD" $flag >/dev/null 2>&1
	rc=$?
	if [ "$rc" -eq "$exp" ]; then printf 'PASS  %-62s (rc=%d)\n' "$name" "$rc"; PASS=$((PASS+1))
	else printf 'FAIL  %-62s (rc=%d, want %d)\n' "$name" "$rc" "$exp" >&2; FAIL=$((FAIL+1)); fi
}
run_json() {
	local name="$1" exp="$2" json="$3" rc
	# An empty payload is never a legitimate case: it means the jq that was
	# supposed to build it failed (e.g. the macOS /bin/bash 3.2 nested-quote
	# quirk noted below), and the guard would then exit 0 on empty stdin --
	# turning a broken assertion into a silent PASS for every expected-0 case.
	if [ -z "$json" ]; then
		printf 'FAIL  %-62s (empty JSON payload: the case never ran)\n' "$name" >&2
		FAIL=$((FAIL+1)); return
	fi
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

echo "== Bash hook-bypass R4-A: bundled short-option clusters containing n -> block =="
# Round-4 (2026-08-06): -n bundled with other boolean short options is a REAL,
# executable git invocation (verified in a throwaway repo with a genuine
# pre-commit hook: the hook was SKIPPED and the commit landed for every form
# below). The pre-round-4 check only recognised a BARE -n token, so all of
# these silently passed.
run_json "R4-A1 -nm with a message value -> block"   2 "$(jq -nc --arg c "git commit -nm msg" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-A2 -an (= -a -n) -> block"              2 "$(jq -nc --arg c "git commit -an -m msg" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-A3 -nam with a message value -> block"  2 "$(jq -nc --arg c "git commit -nam msg" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-A4 -nm\"attached quoted value\" -> block" 2 "$(jq -nc --arg c 'git commit -nm"msg"' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-A5 -nmmsg (attached bare value) -> block" 2 "$(jq -nc --arg c "git commit -nmmsg" '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass R4-B: split-quote concatenation -> block (tokenizer path) =="
# The shell concatenates adjacent quoted/unquoted fragments into ONE word, so
# these all execute as the real flag. A raw substring scan cannot see them
# (the literal characters are interrupted); only exact-token matching over a
# tokenizer resolves them. This is why round 4 ORs a tokenizer check IN rather
# than (as round 1 did) replacing the substring scan with one.
NV_A="$(printf -- '--no-ver""%s' 'ify')"
NV_B="$(printf -- '--no-ver"%s"' 'ify')"
NV_C="$(printf -- '--"no-ver%s"' 'ify')"
NV_D="$(printf -- '--no-ve%srify' "''")"
NV_E="$(printf -- '--no-ver\\%s' 'ify')"
run_json "R4-B1 --no-ver\"\"ify -> block"  2 "$(jq -nc --arg c "git commit -m x $NV_A" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-B2 --no-ver\"ify\" -> block"  2 "$(jq -nc --arg c "git commit -m x $NV_B" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-B3 --\"no-verify\" -> block"  2 "$(jq -nc --arg c "git commit -m x $NV_C" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-B4 --no-ve''rify -> block"    2 "$(jq -nc --arg c "git commit -m x $NV_D" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-B5 --no-ver\\ify (backslash inside the word) -> block" 2 "$(jq -nc --arg c "git commit -m x $NV_E" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-B6 -'n' -> block"             2 "$(jq -nc --arg c "git commit -m x -'n'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-B7 '-'n -> block"             2 "$(jq -nc --arg c "git commit -m x '-'n" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-B8 \"-\"n -> block"           2 "$(jq -nc --arg c 'git commit -m x "-"n' '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass R4-C: the git-subcommand test must read the RAW text =="
# The quote-masking that fixes the "bash -n in a message" false positive must
# NEVER be applied to the `git commit|push` detection itself: masking the
# contents of quotes would let a quoted command hide the subcommand entirely.
# Round 4 briefly added a left word-boundary to that test and this exact case
# caught it before it shipped.
run_json "R4-C1 eval \"git commit FLAG\" (quoted command) -> block" 2 \
	"$(jq -nc --arg c "eval \"git commit ${NOVERIFY_FLAG}\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-C2 \$(git commit FLAG) subshell -> block" 2 \
	"$(jq -nc --arg c "\$(git commit -m x ${NOVERIFY_FLAG})" '{tool_name:"Bash",tool_input:{command:$c}}')"
# Global options may sit between `git` and the subcommand. `git -C <dir>` is a
# routine form in this project (the Bash tool discourages `cd`), and it was
# never even examined by the pre-round-4 `git\s+(commit|push)` test.
run_json "R4-C3 git -C <dir> commit FLAG -> block" 2 \
	"$(jq -nc --arg c "git -C /tmp/repo commit -m x ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-C4 git -C <dir> commit -n -> block" 2 \
	"$(jq -nc --arg c "git -C /tmp/repo commit -m x ${DASH_N}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-C5 git -c k=v commit FLAG -> block" 2 \
	"$(jq -nc --arg c "git -c user.name=x commit -m y ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-C6 git --no-pager commit FLAG -> block" 2 \
	"$(jq -nc --arg c "git --no-pager commit -m x ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass R4-D: the two bypasses round 3 opened -> block =="
# Both verified as TRUE bypasses by real execution (hook SKIPPED, commit
# landed) before the round-4 rewrite.
run_json "R4-D1 quoted '-sm' x FLAG 'y' -> block" 2 \
	"$(jq -nc --arg c "git commit '-sm' x ${NOVERIFY_FLAG} 'y'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-D2 -nm FLAG -> block" 2 \
	"$(jq -nc --arg c "git commit -nm ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-D3 quoted '-sm' x -n 'y' -> block" 2 \
	"$(jq -nc --arg c "git commit '-sm' x ${DASH_N} 'y'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-D4 -nm -n -> block" 2 \
	"$(jq -nc --arg c "git commit -nm ${DASH_N}" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-D5 ANSI-C quoted \$'-n' -> block" 2 \
	"$(jq -nc --arg c "git commit -m x \$'${DASH_N}'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-D6 escaped dash \\-n -> block" 2 \
	"$(jq -nc --arg c "git commit -m x \\${DASH_N}" '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass R4-E: additional real-world commands that must stay allowed =="
run_json "R4-E1 commit --dry-run -> allow"   0 "$(jq -nc --arg c 'git commit -m "fix" --dry-run' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-E2 multibyte message mentioning bash -n -> allow" 0 \
	"$(jq -nc --arg c "git commit -m \"日本語メッセージ bash ${DASH_N} を含む\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
# Assigned first, not inlined: an apostrophe inside an inline command
# substitution trips the macOS /bin/bash 3.2 quirk documented above, jq then
# fails, and the empty payload would have PASSED vacuously for these two
# expected-allow cases (caught by the empty-payload check in run_json).
E3_CMD="$(printf 'git commit -m "msg with %snested%s quotes and bash %s"' "'" "'" "$DASH_N")"
E3_JSON="$(jq -nc --arg c "$E3_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-E3 nested single quotes inside a double-quoted message -> allow" 0 "$E3_JSON"
E4_CMD="$(printf 'git commit -m "don%st break this"' "'")"
E4_JSON="$(jq -nc --arg c "$E4_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-E4 apostrophe inside a double-quoted message -> allow" 0 "$E4_JSON"
run_json "R4-E5 message says 'no-verify' without the leading dashes -> allow" 0 \
	"$(jq -nc --arg c 'git commit -m "wrap-up: no-verify policy notes"' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-E6 amend --no-edit -> allow"    0 "$(jq -nc --arg c 'git commit --amend --no-edit' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-E7 push --set-upstream to a branch containing -n -> allow" 0 \
	"$(jq -nc --arg c 'git push --set-upstream origin feature/add-notify-nag' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-E8 tail -n20 (no git subcommand) -> allow" 0 "$(jq -nc --arg c 'tail -n20 log.txt' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-E9 plain push -> allow"         0 "$(jq -nc --arg c 'git push origin main' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-E10 -F message file -> allow"   0 "$(jq -nc --arg c 'git commit -F /tmp/msg.txt' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-E11 message mentioning a path with -n in it -> allow" 0 \
	"$(jq -nc --arg c 'git commit -m "see docs/run-nightly.md"' '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass R4-F: broken perl matrix -> always fail closed =="
# I1 above covers "exit 1, no output". The trust signal is the EXACT stdout
# marker, so every other way perl can malfunction must also fall through to the
# raw substring scan rather than being read as a decision.
R4F_JSON="$(jq -nc --arg c "git commit -m x ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
r4f_check() {
	local name="$1" body="$2" mode="${3:-755}" dir rc
	dir="$(mktemp -d -t pubguard-r4f.XXXXXX)"
	printf '%s' "$body" > "$dir/perl"
	chmod "$mode" "$dir/perl"
	printf '%s' "$R4F_JSON" | PATH="$dir:$PATH" bash "$GUARD" >/dev/null 2>&1
	rc=$?
	rm -rf "$dir"
	if [ "$rc" -eq 2 ]; then printf 'PASS  %-62s (rc=%d)\n' "$name" "$rc"; PASS=$((PASS+1))
	else printf 'FAIL  %-62s (rc=%d, want 2)\n' "$name" "$rc" >&2; FAIL=$((FAIL+1)); fi
}
r4f_check "R4-F1 perl exits 0 silently -> fail closed"        '#!/bin/sh
exit 0
'
r4f_check "R4-F2 perl pollutes stdout before ALLOW -> fail closed" '#!/bin/sh
printf "warning: x\nALLOW"
exit 0
'
r4f_check "R4-F3 perl prints garbage -> fail closed"          '#!/bin/sh
printf xyzzy
'
r4f_check "R4-F4 perl prints truncated marker -> fail closed" '#!/bin/sh
printf ALLO
'
r4f_check "R4-F5 perl interpreter missing -> fail closed"     '#!/bin/sh
exec /nonexistent/perl "$@"
'
r4f_check "R4-F6 perl killed by a signal -> fail closed"      '#!/bin/sh
kill -9 $$
'
r4f_check "R4-F7 perl not executable -> fail closed"          '#!/bin/sh
printf ALLOW
' 644

echo "== Bash hook-bypass R4-G: no catastrophic backtracking on pathological input =="
# The masker is a \G-anchored scan with mutually exclusive branches and the
# scans are linear, but a regression here would hang the PreToolUse hook (and
# therefore the whole session), so it is asserted rather than assumed.
r4g_check() {
	local name="$1" cmd="$2" json t0 t1 el
	json="$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
	t0="$(date +%s)"
	printf '%s' "$json" | bash "$GUARD" >/dev/null 2>&1
	t1="$(date +%s)"
	el=$((t1 - t0))
	if [ "$el" -lt 10 ]; then printf 'PASS  %-62s (%ds)\n' "$name" "$el"; PASS=$((PASS+1))
	else printf 'FAIL  %-62s (%ds, want <10)\n' "$name" "$el" >&2; FAIL=$((FAIL+1)); fi
}
BIG_A="$(perl -e 'print "a" x 300000')"
BIG_Q="$(perl -e 'print q{"ab"} x 4000')"
BIG_U="$(perl -e 'print q{"} x 4001')"
BIG_B="$(perl -e 'print qq{\\\\} x 100000')"
BIG_E="$(perl -e 'print q{\"} x 30000')"
r4g_check "R4-G1 300k plain characters"        "git commit -m $BIG_A"
r4g_check "R4-G2 4000 balanced quote pairs"    "git commit -m $BIG_Q"
r4g_check "R4-G3 4001 unbalanced quotes"       "git commit -m $BIG_U"
r4g_check "R4-G4 100k backslashes"             "git commit -m $BIG_B"
r4g_check "R4-G5 30k escaped quotes in one string" "git commit -m \"$BIG_E\""

echo "== Bash hook-bypass R4-I: a quoted region that is ITSELF a git command -> block =="
# Review finding F1 (2026-08-06), each verified as a real bypass with actual
# commits: round 4's own quote-masking collapsed `eval "git commit -m x -n"` to
# a placeholder, so P2 lost the payload and the tokenizer saw one opaque token.
# r2 blocked these; r3 and r4 did not. `bash -c 'cd x && git commit -nm y'` is
# an ordinary agent invocation, not an adversarial one. The masker now recurses
# into a quoted region whose contents are themselves a git commit|push.
# NOTE these use the SHORT flag: R4-C1 only exercised the long one, which is
# exactly why the gap survived round 4's own battery.
run_json "R4-I1 eval \"git commit ... -n\" -> block" 2 \
	"$(jq -nc --arg c "eval \"git commit -m x ${DASH_N}\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-I2 eval 'git commit ... -n' -> block" 2 \
	"$(jq -nc --arg c "eval 'git commit -m x ${DASH_N}'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-I3 bash -c \"git commit ... -n\" -> block" 2 \
	"$(jq -nc --arg c "bash -c \"git commit -m x ${DASH_N}\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-I4 bash -c 'git commit ... -n' -> block" 2 \
	"$(jq -nc --arg c "bash -c 'git commit -m x ${DASH_N}'" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-I5 sh -c \"git commit -n -m x\" -> block" 2 \
	"$(jq -nc --arg c "sh -c \"git commit ${DASH_N} -m x\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-I6 eval \"git commit -an -m x\" (bundled) -> block" 2 \
	"$(jq -nc --arg c 'eval "git commit -an -m x"' '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-I7 bash -c 'cd x && git commit -nm y' -> block" 2 \
	"$(jq -nc --arg c "bash -c 'cd x && git commit -nm y'" '{tool_name:"Bash",tool_input:{command:$c}}')"
# The recursion must not swallow the false-positive fix: a MESSAGE that merely
# mentions a syntax-check flag contains no `git commit`, so it is still masked.
I8_CMD="$(printf 'bash -c %sgit commit -m "note bash %s here"%s' "'" "$DASH_N" "'")"
I8_JSON="$(jq -nc --arg c "$I8_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-I8 wrapper whose message merely mentions bash -n -> allow" 0 "$I8_JSON"
I9_CMD="$(printf 'bash -c "git commit -m %sdocs mention bash %s%s"' "'" "$DASH_N" "'")"
I9_JSON="$(jq -nc --arg c "$I9_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')"
run_json "R4-I9 nested quoting, message only -> allow" 0 "$I9_JSON"

echo "== Bash hook-bypass R4-N: line continuation between git and the subcommand -> block =="
# Review finding F6: `git \<newline> commit ...` was never recognised as a git
# invocation at all, in every round including r0. One-character fix: the
# separators now accept a backslash.
N1_CMD="$(printf 'git \\\ncommit -m x %s' "$NOVERIFY_FLAG")"
run_json "R4-N1 line continuation before the subcommand -> block" 2 \
	"$(jq -nc --arg c "$N1_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')"
N2_CMD="$(printf 'git \\\ncommit -m x %s' "$DASH_N")"
run_json "R4-N2 same, short flag -> block" 2 \
	"$(jq -nc --arg c "$N2_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')"

echo "== Bash hook-bypass R4-M: the raw long-flag scan runs even when perl says ALLOW =="
# Review finding F7: the exact-marker contract cannot tell a working perl from
# a stand-in that prints ALLOW, and the realistic cause is an accident (a
# broken PATH), not an attacker. The raw grep for the long flag is now
# unconditional -- one grep, and perl no longer has to be trusted for it.
M_DIR="$(mktemp -d -t pubguard-r4m.XXXXXX)"
printf '#!/bin/sh\nprintf ALLOW\n' > "$M_DIR/perl"
chmod 755 "$M_DIR/perl"
M1_JSON="$(jq -nc --arg c "git commit -m x ${NOVERIFY_FLAG}" '{tool_name:"Bash",tool_input:{command:$c}}')"
printf '%s' "$M1_JSON" | PATH="$M_DIR:$PATH" bash "$GUARD" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && { printf 'PASS  %-62s (rc=%d)\n' "R4-M1 perl says ALLOW but the long flag is real -> block" "$rc"; PASS=$((PASS+1)); } \
	|| { printf 'FAIL  %-62s (rc=%d, want 2)\n' "R4-M1 perl says ALLOW but the long flag is real -> block" "$rc" >&2; FAIL=$((FAIL+1)); }
# ...and it must NOT be extended to -n, which would resurrect the reported FP.
M2_JSON="$(jq -nc --arg c "git commit -m \"docs: mention bash ${DASH_N} check\"" '{tool_name:"Bash",tool_input:{command:$c}}')"
printf '%s' "$M2_JSON" | PATH="$M_DIR:$PATH" bash "$GUARD" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && { printf 'PASS  %-62s (rc=%d)\n' "R4-M2 same stand-in perl, FP message -> still allow" "$rc"; PASS=$((PASS+1)); } \
	|| { printf 'FAIL  %-62s (rc=%d, want 0)\n' "R4-M2 same stand-in perl, FP message -> still allow" "$rc" >&2; FAIL=$((FAIL+1)); }
rm -rf "$M_DIR"

echo "== R4-L: the CONTENT scanner must fail closed, in every mode =="
# Review finding F3: round 4's "8 modes fail closed" covered only the Bash
# branch. With perl broken, a Write carrying a real public IP returned 0 --
# and so did --diff, which is the layer-2 pre-commit backstop that makes
# "nothing reaches history" true. Completion is now proved by a trailing
# marker, the same positive-marker contract the Bash branch already used.
r4l_check() {
	local name="$1" exp="$2" body="$3" mode="$4" bin="$5" dir rc
	dir="$(mktemp -d -t pubguard-r4l.XXXXXX)"
	printf '%s' "$body" > "$dir/$bin"
	chmod 755 "$dir/$bin"
	if [ "$mode" = "write" ]; then
		jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}' \
			| PATH="$dir:$PATH" bash "$GUARD" >/dev/null 2>&1
	elif [ "$mode" = "diff" ]; then
		printf -- '+++ b/x.md\n+host %s\n ctx' "$PUB_IP" \
			| PATH="$dir:$PATH" bash "$GUARD" --diff >/dev/null 2>&1
	else
		printf 'host %s:9651' "$PUB_IP" | PATH="$dir:$PATH" bash "$GUARD" --text >/dev/null 2>&1
	fi
	rc=$?
	rm -rf "$dir"
	if [ "$rc" -eq "$exp" ]; then printf 'PASS  %-62s (rc=%d)\n' "$name" "$rc"; PASS=$((PASS+1))
	else printf 'FAIL  %-62s (rc=%d, want %d)\n' "$name" "$rc" "$exp" >&2; FAIL=$((FAIL+1)); fi
}
PERL_DEAD='#!/bin/sh
exit 1
'
PERL_MUTE='#!/bin/sh
exit 0
'
PERL_JUNK='#!/bin/sh
printf zzz
'
r4l_check "R4-L1 --text, perl crashes -> block"           1 "$PERL_DEAD" text  perl
r4l_check "R4-L2 --text, perl silent -> block"            1 "$PERL_MUTE" text  perl
r4l_check "R4-L3 --text, perl garbage -> block"           1 "$PERL_JUNK" text  perl
r4l_check "R4-L4 --diff (layer 2), perl crashes -> block" 1 "$PERL_DEAD" diff  perl
r4l_check "R4-L5 --diff (layer 2), perl silent -> block"  1 "$PERL_MUTE" diff  perl
r4l_check "R4-L6 Write, perl crashes -> block"            2 "$PERL_DEAD" write perl
r4l_check "R4-L7 Write, perl silent -> block"             2 "$PERL_MUTE" write perl
# A jq that exists but does not parse used to yield a garbage tool name, which
# fell through "other tools -> allow" and let every call past unexamined.
r4l_check "R4-L8 Write, jq silent -> block"               2 "$PERL_MUTE" write jq
r4l_check "R4-L9 Write, jq garbage -> block"              2 "$PERL_JUNK" write jq
# A WORKING scanner must still allow clean content (no blanket over-block).
run_text "R4-L10 working scanner, clean text -> allow"    0 --text "the validator is healthy"
run_text "R4-L11 working scanner, clean diff -> allow"    0 --diff "$(printf '+++ b/x.md\n+all good\n ctx')"

echo "== Write/Edit =="
run_json "write public IP -> tracked README block" 2 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
run_json "write phone -> tracked README block"     2 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "tel $FAKE_PHONE" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
run_json "write clean -> tracked allow"            0 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "all good" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
run_json "write IP -> path OUTSIDE repo allow"     0 "$(jq -nc --arg fp "/tmp/x.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
run_json "edit forbidden word -> tracked block"    2 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "$TEST_WORD" '{tool_name:"Edit",tool_input:{file_path:$fp,new_string:$c}}')"
run_json "multiedit public IP -> block"            2 "$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "host $PUB_IP" '{tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[{old_string:"a",new_string:"b"},{old_string:"c",new_string:$c}]}}')"
run_json "read tool -> allow"                      0 "$(jq -nc '{tool_name:"Read",tool_input:{file_path:"/x"}}')"

echo "== gitignore-skip =="
# info/exclude always lives in the repo's *common* git dir, shared across
# worktrees. In a normal clone that is "$REPO_ROOT/.git/info/exclude", but
# inside a `git worktree`, "$REPO_ROOT/.git" is a FILE (a gitdir pointer),
# not a directory, so a literal "$REPO_ROOT/.git/info/exclude" path fails
# with "Not a directory" -- which made this single assertion silently FAIL
# whenever the suite ran from a worktree. Ask git itself to resolve it so the
# same code path works for both a normal clone and a worktree checkout.
#
# H1 and X2 fixed this defect independently and simultaneously; this is the
# union of both. `--git-path info/exclude` and `--git-common-dir` + /info/
# resolve to the same file, and the mkdir covers a common dir that has no
# info/ directory yet.
EXCL_REL="$(cd "$REPO_ROOT" && git rev-parse --git-path info/exclude)"
case "$EXCL_REL" in
	/*) EXCL="$EXCL_REL" ;;
	*)  EXCL="$REPO_ROOT/$EXCL_REL" ;;
esac
mkdir -p "$(dirname "$EXCL")"
# Snapshot the exact pre-test state (content, or "did not exist") so it can
# be restored byte-for-byte afterward regardless of what was in it.
EXCL_EXISTED=0
EXCL_BACKUP=""
if [ -f "$EXCL" ]; then
	EXCL_EXISTED=1
	EXCL_BACKUP="$(mktemp -t pubguard-exclude-backup.XXXXXX)"
	cp "$EXCL" "$EXCL_BACKUP"
fi
IGN_NAME="guardtest-ignored-$$.md"
printf '%s\n' "$IGN_NAME" >> "$EXCL"
run_json "write IP into gitignored file -> allow"  0 "$(jq -nc --arg fp "$REPO_ROOT/$IGN_NAME" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
if [ "$EXCL_EXISTED" -eq 1 ]; then
	mv "$EXCL_BACKUP" "$EXCL"
else
	rm -f "$EXCL"
fi

echo "== R4-H: repo membership must survive path aliasing (else the write is never scanned) =="
# Round-4 triage (2026-08-06). Membership used to be a raw string prefix
# compare of tool_input.file_path against `git rev-parse --show-toplevel`,
# which is derived from the CWD. Any aliasing between the two spellings made
# the guard skip the file entirely -- silently, with rc=0. All four cases below
# were reproduced with a real public IPv4 payload that then went unscanned.
run_json_cwd() {
	local name="$1" exp="$2" cwd="$3" json="$4" rc
	if [ -z "$json" ]; then
		printf 'FAIL  %-62s (empty JSON payload: the case never ran)\n' "$name" >&2
		FAIL=$((FAIL+1)); return
	fi
	rc=0
	printf '%s' "$json" | ( cd "$cwd" 2>/dev/null && bash "$GUARD" ) >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq "$exp" ]; then printf 'PASS  %-62s (rc=%d)\n' "$name" "$rc"; PASS=$((PASS+1))
	else printf 'FAIL  %-62s (rc=%d, want %d)\n' "$name" "$rc" "$exp" >&2; FAIL=$((FAIL+1)); fi
}
H_ROOT="$(mktemp -d -t pubguard-h.XXXXXX)"
# mktemp on macOS hands back a path under /var, itself a symlink to /private/var,
# so this exercises the logical-vs-physical mismatch with no special setup.
H_PHYS="$( cd "$H_ROOT" && pwd -P )"
(
	cd "$H_ROOT" || exit 0
	git init -q main-checkout 2>/dev/null
	cd main-checkout || exit 0
	git -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m seed 2>/dev/null
	git worktree add -q ../linked-wt -b guardtest-h 2>/dev/null
) >/dev/null 2>&1
H_MAIN="$H_ROOT/main-checkout"
H_WT="$H_ROOT/linked-wt"
H_OTHER="$H_ROOT/unrelated-repo"
mkdir -p "$H_OTHER" && (cd "$H_OTHER" && git init -q .) >/dev/null 2>&1
if [ -d "$H_WT" ] && [ -d "$H_OTHER/.git" ]; then
	# 1. logical vs physical spelling of the very same file
	run_json_cwd "R4-H1 logical path (via symlinked ancestor) -> block" 2 "$H_MAIN" \
		"$(jq -nc --arg fp "$H_MAIN/leak.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
	run_json_cwd "R4-H2 physical path of the same file -> block" 2 "$H_PHYS/main-checkout" \
		"$(jq -nc --arg fp "$H_PHYS/main-checkout/leak.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
	# 2. a LINKED WORKTREE of the same repository, hook running from the main
	#    checkout -- this project's standard subagent workflow, and the case
	#    where every agent write was previously skipped
	run_json_cwd "R4-H3 write into a linked worktree, cwd = main checkout -> block" 2 "$H_MAIN" \
		"$(jq -nc --arg fp "$H_WT/leak.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
	run_json_cwd "R4-H4 edit into a linked worktree, cwd = main checkout -> block" 2 "$H_MAIN" \
		"$(jq -nc --arg fp "$H_WT/leak.md" --arg c "host $PUB_IP" '{tool_name:"Edit",tool_input:{file_path:$fp,new_string:$c}}')"
	run_json_cwd "R4-H5 worktree subdir that does not exist yet -> block" 2 "$H_MAIN" \
		"$(jq -nc --arg fp "$H_WT/no/such/dir/leak.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
	# 3. the fix must NOT over-reach: a genuinely unrelated repository and
	#    ordinary out-of-repo scratch paths stay skipped
	run_json_cwd "R4-H6 unrelated repository -> allow" 0 "$H_MAIN" \
		"$(jq -nc --arg fp "$H_OTHER/notes.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
	run_json_cwd "R4-H7 out-of-repo scratch path -> allow" 0 "$H_MAIN" \
		"$(jq -nc --arg fp "$H_ROOT/scratch.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
	# 4. this repository's own tracked file must be scanned when the hook runs
	#    from the MAIN checkout of the same repository -- the real deployment
	#    (CLAUDE_PROJECT_DIR) whenever the suite or an agent works in a
	#    worktree. Four Write/Edit assertions above silently flipped to PASS
	#    with rc=0 depending on the caller's directory before this was fixed.
	SELF_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
	case "$SELF_COMMON" in
		/*) : ;;
		*)  SELF_COMMON="$REPO_ROOT/${SELF_COMMON:-.git}" ;;
	esac
	SELF_MAIN="$(dirname "$SELF_COMMON")"
	run_json_cwd "R4-H8 tracked README block holds with cwd = the main checkout" 2 "$SELF_MAIN" \
		"$(jq -nc --arg fp "$REPO_ROOT/README.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"

	# 5. a gitignored file INSIDE a linked worktree must stay skipped. This
	#    pins the worktree-local check-ignore attempt: without it the file is
	#    unresolvable from the main checkout and would newly be scanned
	#    (measured: rc=0 -> rc=2). Nothing else in the suite covers it.
	printf '%s\n' "guardtest-ignored-wt.md" > "$H_WT/.gitignore"
	run_json_cwd "R4-H9 gitignored file inside a linked worktree -> allow" 0 "$H_MAIN" \
		"$(jq -nc --arg fp "$H_WT/guardtest-ignored-wt.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
	# ...while a NON-ignored sibling in the same worktree is still scanned, so
	#    the assertion above cannot pass by skipping the whole worktree.
	run_json_cwd "R4-H10 non-ignored sibling in that worktree -> block" 2 "$H_MAIN" \
		"$(jq -nc --arg fp "$H_WT/not-ignored.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"

	# 6. case aliasing. Inside the guard `pwd -P` resolves symlinks but leaves
	#    the CASE exactly as typed (measured with `bash -x`), so on a
	#    case-insensitive volume two spellings of one directory canonicalise to
	#    two different strings and the guard reported "outside": rc=0,
	#    unscanned, in r3 and in round 4 as first shipped. Membership is now
	#    decided by inode identity instead.
	#
	#    The SHAPE matters. `git rev-parse --git-common-dir` answers with an
	#    absolute path from a linked WORKTREE -- which re-normalises the case by
	#    accident -- but with a bare `.git` from a MAIN checkout, where it is
	#    resolved relative to the already-aliased directory and the alias
	#    survives. Only the main-checkout shape escapes, so that is the shape
	#    asserted here: an assertion built on the worktree passes even with the
	#    fix reverted, i.e. pins nothing. Skipped (never silently passed) where
	#    the filesystem is case-sensitive and the premise does not hold.
	pg_case_alias() {
		local base="$1" cand
		for cand in "$(printf '%s' "$base" | tr 'A-Z' 'a-z')" \
		            "$(printf '%s' "$base" | tr 'a-z' 'A-Z')"; do
			if [ "$cand" != "$base" ] && [ -d "$cand" ] && [ "$cand" -ef "$base" ]; then
				printf '%s' "$cand"; return 0
			fi
		done
		return 1
	}
	H_ALIAS="$(pg_case_alias "$H_MAIN" || true)"
	S_ALIAS="$(pg_case_alias "$SELF_MAIN" || true)"
	if [ -n "$H_ALIAS" ]; then
		run_json_cwd "R4-H11 case-aliased path in a plain checkout -> block" 2 "$H_MAIN" \
			"$(jq -nc --arg fp "$H_ALIAS/leak.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
	else
		printf 'SKIP  %-62s (case-sensitive filesystem)\n' "R4-H11 case-aliased path in a plain checkout"
		SKIP=$((SKIP+1))
	fi
	if [ -n "$S_ALIAS" ]; then
		# The reviewer's exact measurement, against this repository's own main
		# checkout: rc=0 and unscanned before the fix.
		run_json_cwd "R4-H12 case-aliased path in THIS repo's main checkout -> block" 2 "$SELF_MAIN" \
			"$(jq -nc --arg fp "$S_ALIAS/README.md" --arg c "host $PUB_IP" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}')"
	else
		printf 'SKIP  %-62s (case-sensitive filesystem)\n' "R4-H12 case-aliased path in this repo's main checkout"
		SKIP=$((SKIP+1))
	fi
else
	printf 'FAIL  %-62s (fixture setup failed)\n' "R4-H fixture (worktree + unrelated repo)" >&2
	FAIL=$((FAIL+1))
fi
(cd "$H_MAIN" 2>/dev/null && git worktree remove --force ../linked-wt) >/dev/null 2>&1
rm -rf "$H_ROOT"

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
if [ "$SKIP" -gt 0 ]; then
	echo "test-publish-guard.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
else
	echo "test-publish-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
fi
if [ "$FAIL" -gt 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
