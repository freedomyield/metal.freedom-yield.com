#!/usr/bin/env bash
# test-documented-pq-command.sh — the ML-DSA-65 verify block published in
# docs/IDENTITY_VERIFICATION.md must be the command that actually verifies:
# its URLs equal the library constants, and its openssl line, run VERBATIM
# against fixtures, prints "Signature Verified Successfully". The EN and JA
# public pages must carry the same openssl line.
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe, no broadcast pathway.
set -u
REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
. "${REPO_SRC}/tests/lib/pq-test-key.sh"
PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip_pass() { echo "SKIP: $1"; echo "RESULT: PASS"; exit 0; }
DOC="${REPO_SRC}/docs/IDENTITY_VERIFICATION.md"
ID_URL="https://metal.freedom-yield.com/api/identity.json"

# extract_block <doc> — lines of the fenced block between the markers
extract_block() {
	sed -n '/<!-- pq-verify:begin -->/,/<!-- pq-verify:end -->/p' "$1" |
		grep -v -e '<!--' -e '^```'
}

# --- structure (no OpenSSL needed) ---
BLOCK="$(extract_block "$DOC")"
n_curl="$(printf '%s\n' "$BLOCK" | grep -c '^curl ')"
n_ossl="$(printf '%s\n' "$BLOCK" | grep -c '^openssl ')"
[ "$n_curl" = "3" ] && pass "D1 block has exactly three curl lines" || bad "D1 curl lines=$n_curl"
[ "$n_ossl" = "1" ] && pass "D2 block has exactly one openssl line" || bad "D2 openssl lines=$n_ossl"
urls="$(printf '%s\n' "$BLOCK" | grep '^curl ' | awk '{print $NF}' | sort | tr '\n' ' ')"
want_urls="$(printf '%s\n' "$ID_URL" "$FYIPQ_SIG_URL" "$FYIPQ_PUB_URL" | sort | tr '\n' ' ')"
[ "$urls" = "$want_urls" ] && pass "D3 curl URLs equal identity.json + FYIPQ_SIG_URL + FYIPQ_PUB_URL" || bad "D3 urls=[$urls] want=[$want_urls]"
OSSL_LINE="$(printf '%s\n' "$BLOCK" | grep '^openssl ')"

# An empty line would make every grep -F below pass vacuously.
if [ -z "$OSSL_LINE" ] || [ "$n_ossl" != "1" ]; then
	echo "passed=$PASS failed=$FAIL"; echo "RESULT: FAIL"; exit 1
fi

# public pages carry the same openssl line (HTML text: &lt; etc. absent in this line)
for p in public/verify/index.html public/ja/verify/index.html; do
	grep -qF -- "$OSSL_LINE" "${REPO_SRC}/$p" && pass "D4 $p carries the documented openssl line" || bad "D4 $p lacks the documented openssl line"
done

# --- run the documented line verbatim ---
fy_pq_prereq_or_skip skip_pass
OSSL="$(fyipq__resolve_openssl)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/keys" "$WORK/repo" "$WORK/run"; chmod 700 "$WORK/keys"
fy_pq_make_master "$WORK/keys"
fy_pq_install "$WORK/keys" "$WORK/repo"
printf '{"fixture":true}\n' > "$WORK/run/identity.json"
"$OSSL" pkeyutl -sign -inkey "$WORK/keys/master.pem" -rawin -in "$WORK/run/identity.json" \
	-pkeyopt "context-string:${FYIPQ_CONTEXT}" -out "$WORK/run/identity.json.mldsa65.sig" </dev/null
cp "$WORK/repo/${FYIPQ_PUB_REL}" "$WORK/run/operator-identity-mldsa65.pub"

run_line() { # <line>
	( cd "$WORK/run" && PATH="$(dirname "$OSSL"):$PATH" bash -c "$1" </dev/null 2>&1 )
}
out="$(run_line "$OSSL_LINE")"
case "$out" in *"Signature Verified Successfully"*) pass "D5 documented openssl line verifies the fixture" ;; *) bad "D5 output: $out" ;; esac

# --- mutation: a wrong context string in the doc copy must fail to verify ---
mut_line="$(printf '%s\n' "$OSSL_LINE" | sed "s#${FYIPQ_CONTEXT}#freedom-yield/other-context#")"
mout="$(run_line "$mut_line")"
case "$mout" in *"Signature Verified Successfully"*) bad "MUTATION NOT CAUGHT: D6 wrong context still verifies" ;; *) pass "D6m wrong context string does not verify" ;; esac
# mutation: an extra byte in the manifest must fail
printf 'x' >> "$WORK/run/identity.json"
mout2="$(run_line "$OSSL_LINE")"
case "$mout2" in *"Signature Verified Successfully"*) bad "MUTATION NOT CAUGHT: D7 tampered manifest verifies" ;; *) pass "D7m tampered manifest does not verify" ;; esac

echo "passed=$PASS failed=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
