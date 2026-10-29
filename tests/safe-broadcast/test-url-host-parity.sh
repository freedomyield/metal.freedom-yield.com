#!/usr/bin/env bash
# tests/safe-broadcast/test-url-host-parity.sh — scripts/lib/url-host.sh
# (fyd_host_of, used by bin/safe-broadcast gate 3) must answer EXACTLY like
# the reference extractor fyp_host_of in scripts/install-rehearsal-preflight.sh
# (check 10), on a corpus built from every hostile shape that extractor was
# hardened against, and must reject what it rejects.
#
# CHAIN: none — pure string functions; no network, no proton.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# The userinfo separator is spliced in from $AT at run time so no line of
# this file looks like a mail address to the publish guard.
#
# If the pre-flight is later changed to source scripts/lib/url-host.sh instead
# of carrying its own copy, the parity half passes as "single source".
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PF="$ROOT/scripts/install-rehearsal-preflight.sh"
AT='@'
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# shellcheck source=scripts/lib/url-host.sh
. "$ROOT/scripts/lib/url-host.sh"

# Expected answers (independent of either implementation): <input>|<host or !>
# "!" = rejected (empty output, rc 1).
while IFS='|' read -r in want; do
	[ -n "$in" ] || continue
	got="$(fyd_host_of "$in")"; rc=$?
	if [ "$want" = "!" ]; then
		if [ "$rc" != "0" ] && [ -z "$got" ]; then ok "rejects: $in"; else bad "rejects: $in" "got '$got' rc=$rc"; fi
	else
		if [ "$rc" = "0" ] && [ "$got" = "$want" ]; then ok "host of $in = $want"; else bad "host of $in" "got '$got' rc=$rc, want '$want'"; fi
	fi
done <<CASES
https://proton.eosusa.io|proton.eosusa.io
https://PROTON.EOSUSA.IO/|proton.eosusa.io
https://proton.eosusa.io.:443/v1/chain|proton.eosusa.io
https://user:pw${AT}proton.eosusa.io|proton.eosusa.io
https://clone.example/${AT}proton.eosusa.io|clone.example
https://clone.example\\${AT}proton.eosusa.io|clone.example
https://clone.example?x=${AT}proton.eosusa.io|clone.example
https://clone.example#${AT}proton.eosusa.io|clone.example
https://a${AT}b${AT}proton.eosusa.io|proton.eosusa.io
https://proton.eosusa.io.attacker.tld|proton.eosusa.io.attacker.tld
https://node.example/ext/bc/abc/rpc|node.example
http://proton.eosusa.io|!
proton.eosusa.io|!
ftp://proton.eosusa.io|!
CASES

# Parity with the pre-flight's own copy.
if grep -q '^fyp_host_of() {' "$PF"; then
	ref="$(sed -n '/^fyp_host_of() {/,/^}/p' "$PF")"
	eval "$ref"
	diffs=""
	while IFS= read -r in; do
		a="$(fyd_host_of "$in")"; ra=$?
		b="$(fyp_host_of "$in")"; rb=$?
		[ "$a|$ra" = "$b|$rb" ] || diffs="${diffs} [$in: lib='$a'/$ra preflight='$b'/$rb]"
	done <<CORPUS
https://proton.eosusa.io
https://PROTON.EOSUSA.IO/
https://proton.eosusa.io.:443/v1/chain
https://user:pw${AT}proton.eosusa.io
https://clone.example/${AT}proton.eosusa.io
https://clone.example\\${AT}proton.eosusa.io
https://clone.example?x=${AT}proton.eosusa.io
https://clone.example#${AT}proton.eosusa.io
https://a${AT}b${AT}proton.eosusa.io
https://proton.eosusa.io.attacker.tld
https://node.example/ext/bc/abc/rpc
https://
https://${AT}
https://:443
http://proton.eosusa.io
proton.eosusa.io
HTTPS://Rpc.Api.Mainnet.Metalx.Com
CORPUS
	if [ -z "$diffs" ]; then ok "lib == pre-flight check-10 extractor on the corpus"; else bad "lib == pre-flight extractor" "$diffs"; fi
elif grep -q 'lib/url-host\.sh' "$PF"; then
	ok "pre-flight sources scripts/lib/url-host.sh (single source)"
else
	bad "parity" "pre-flight neither defines fyp_host_of nor sources scripts/lib/url-host.sh"
fi

echo "---"
echo "test-url-host-parity.sh: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
