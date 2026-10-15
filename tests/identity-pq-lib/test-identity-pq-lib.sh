#!/usr/bin/env bash
# test-identity-pq-lib.sh — properties of scripts/lib/identity-pq.sh.
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe, no broadcast pathway.
set -u
REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO_SRC}/scripts/lib/identity-pq.sh"
. "${REPO_SRC}/tests/lib/pq-test-key.sh"
PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip_pass() { echo "SKIP: $1"; [ "$FAIL" -eq 0 ] || { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: PASS"; exit 0; }
[ -r "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 1; }
. "$LIB"
# L0 the current parameter set and every name derived from it, stated as
# literals here ON PURPOSE: comparing the library with itself could not catch
# a change of algorithm. Runs before the OpenSSL skip so it always runs.
for pair in \
	"FYIPQ_ALGORITHM|ML-DSA-87" \
	"FYIPQ_PUB_REL|public/.well-known/operator-identity-mldsa87.pub" \
	"FYIPQ_SIG_REL|public/api/identity.json.mldsa87.sig" \
	"FYIPQ_PUB_URL|https://metal.freedom-yield.com/.well-known/operator-identity-mldsa87.pub" \
	"FYIPQ_SIG_URL|https://metal.freedom-yield.com/api/identity.json.mldsa87.sig" \
	"FYIPQ_ENC_BASENAME|operator-identity-mldsa87.enc.pem" \
	"FYIPQ_UNLOCKED_BASENAME|operator-identity-mldsa87.unlocked.pem"; do
	k="${pair%%|*}"; w="${pair#*|}"; g="${!k}"
	[ "$g" = "$w" ] && pass "L0 $k = $w" || bad "L0 $k is '$g', expected '$w'"
done
fy_pq_prereq_or_skip skip_pass
OSSL="$(fyipq__resolve_openssl)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/public/.well-known" "$WORK/keys"; chmod 700 "$WORK/keys"
fy_pq_make_master "$WORK/keys"
fy_pq_install "$WORK/keys" "$WORK/repo"
PUB="$WORK/repo/${FYIPQ_PUB_REL}"
UNL="$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
printf 'payload\n' > "$WORK/msg"

# L1 fingerprint without OpenSSL equals OpenSSL's DER digest
want="sha256:$("$OSSL" pkey -pubin -in "$PUB" -outform DER </dev/null | fyipq__sha256_hex)"
got="$(fyipq__pub_fingerprint "$PUB")"
[ "$got" = "$want" ] && pass "L1 fingerprint matches OpenSSL DER digest" || bad "L1 got=$got want=$want"
# L1-mutation: a PEM with one changed body char must give a different fingerprint
sed '2s/^./A/' "$PUB" > "$WORK/mut.pub"
[ "$(fyipq__pub_fingerprint "$WORK/mut.pub" 2>/dev/null)" != "$want" ] && pass "L1m body change changes fingerprint" || bad "MUTATION NOT CAUGHT: L1m"
# L2 malformed input rejected
printf 'not a key\n' > "$WORK/junk.pub"
fyipq__pub_fingerprint "$WORK/junk.pub" >/dev/null 2>&1 && bad "L2 junk accepted" || pass "L2 junk PEM rejected"
# L2b valid charset but undecodable or empty DER must be rejected, not hashed
printf -- '-----BEGIN PUBLIC KEY-----\n====\n-----END PUBLIC KEY-----\n' > "$WORK/eq.pub"
printf -- '-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----\n' > "$WORK/aaa.pub"
for f in "$WORK/eq.pub" "$WORK/aaa.pub"; do
	out="$(fyipq__pub_fingerprint "$f" 2>/dev/null)"; rc=$?
	if [ "$rc" -ne 0 ] && [ -z "$out" ]; then pass "L2b bad body rejected: $(basename "$f")"
	else bad "L2b bad body accepted: $(basename "$f") rc=$rc out=$out"; fi
done
# L3 LibreSSL / old OpenSSL never accepted; FY_OPENSSL is exclusive
cat > "$WORK/fake-libressl" <<'EOF'
#!/bin/sh
echo "LibreSSL 3.3.6"
EOF
cat > "$WORK/fake-ossl30" <<'EOF'
#!/bin/sh
echo "OpenSSL 3.0.13 30 Jan 2024 (Library: OpenSSL 3.0.13 30 Jan 2024)"
EOF
chmod +x "$WORK/fake-libressl" "$WORK/fake-ossl30"
fyipq__openssl_ok "$WORK/fake-libressl" && bad "L3 LibreSSL accepted" || pass "L3 LibreSSL rejected"
fyipq__openssl_ok "$WORK/fake-ossl30" && bad "L3 OpenSSL 3.0 accepted" || pass "L3 OpenSSL 3.0 rejected"
( FY_OPENSSL="$WORK/fake-libressl" fyipq__resolve_openssl >/dev/null ) && bad "L3 FY_OPENSSL fallthrough" || pass "L3 bad FY_OPENSSL is not silently replaced"
# L4 sign/verify round trip; wrong context rejected
fyipq__sign "$OSSL" "$UNL" "$WORK/msg" "$WORK/sig" && fyipq__verify "$OSSL" "$PUB" "$WORK/msg" "$WORK/sig" \
  && pass "L4 sign/verify round trip" || bad "L4 round trip failed"
"$OSSL" pkeyutl -sign -inkey "$UNL" -rawin -in "$WORK/msg" -pkeyopt context-string:other -out "$WORK/sig-other" </dev/null
fyipq__verify "$OSSL" "$PUB" "$WORK/msg" "$WORK/sig-other" && bad "MUTATION NOT CAUGHT: L4 other context verified" || pass "L4 other context rejected"
# L5 algorithm label
[ "$(fyipq__pub_algorithm "$OSSL" "$PUB")" = "ML-DSA-87" ] && pass "L5 algorithm ML-DSA-87" || bad "L5 algorithm"
# L6 unlocked checks: ok, inside repo, wrong basename, stale
fyipq__check_unlocked "$UNL" "$WORK/repo" 2>/dev/null && pass "L6 fresh unlocked key accepted" || bad "L6 fresh rejected"
cp "$UNL" "$WORK/repo/${FYIPQ_UNLOCKED_BASENAME}"
fyipq__check_unlocked "$WORK/repo/${FYIPQ_UNLOCKED_BASENAME}" "$WORK/repo" 2>/dev/null && bad "L6 in-repo accepted" || pass "L6 in-repo rejected"
cp "$UNL" "$WORK/keys/other.pem"
fyipq__check_unlocked "$WORK/keys/other.pem" "$WORK/repo" 2>/dev/null && bad "L6 wrong basename accepted" || pass "L6 wrong basename rejected"
touch -t 202001010000 "$UNL"
fyipq__check_unlocked "$UNL" "$WORK/repo" 2>/dev/null && bad "L6 stale accepted" || pass "L6 stale rejected"
# L8-L11 mtime portability and fail-closed staleness
mkfake() { # <dir> <script body>
	mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$2" > "$1/stat"; chmod +x "$1/stat"
}
mkfake "$WORK/gnu" 'case "$1" in -f) echo "  File: \"x\""; exit 1;; -c) echo 1700000000; exit 0;; esac; exit 2'
mkfake "$WORK/gnu2" 'case "$1" in -f) echo 42; exit 0;; -c) echo 1700000002; exit 0;; esac; exit 2'
mkfake "$WORK/bsd" 'case "$1" in -c) echo "stat: invalid option" >&2; exit 1;; -f) echo 1700000001; exit 0;; esac; exit 2'
mkfake "$WORK/junk" 'echo "  File: junk"; exit 0'
r="$(PATH="$WORK/gnu:$PATH" fyipq__mtime "$UNL")"; [ "$r" = "1700000000" ] && pass "L8 GNU-like stat" || bad "MUTATION NOT CAUGHT: L8 GNU-like stat got '$r'"
r="$(PATH="$WORK/gnu2:$PATH" fyipq__mtime "$UNL")"; [ "$r" = "1700000002" ] && pass "L8 GNU stat tried before BSD (-f yields digits)" || bad "MUTATION NOT CAUGHT: L8 BSD-first order got '$r'"
r="$(PATH="$WORK/bsd:$PATH" fyipq__mtime "$UNL")"; [ "$r" = "1700000001" ] && pass "L8 BSD-like stat" || bad "L8 BSD-like stat got '$r'"
touch "$UNL"
PATH="$WORK/junk:$PATH" fyipq__mtime "$UNL" >/dev/null; rc=$?
[ "$rc" -eq 1 ] && pass "L9 non-numeric mtime -> 1" || bad "L9 mtime rc=$rc"
err="$(PATH="$WORK/junk:$PATH" fyipq__check_unlocked "$UNL" "$WORK/repo" 2>&1 >/dev/null)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q '^ERROR:'; } && pass "L9 check_unlocked fail-closed with ERROR" || bad "L9 check_unlocked rc=$rc err=$err"
FY_PQ_UNLOCK_MAX_AGE_SEC=abc fyipq__check_unlocked "$UNL" "$WORK/repo" 2>/dev/null \
  && bad "MUTATION NOT CAUGHT: L10 non-numeric max age accepted" || pass "L10 non-numeric max age rejected"
touch -t "$(( $(date +%Y) + 1 ))06010000" "$UNL"
fyipq__check_unlocked "$UNL" "$WORK/repo" 2>/dev/null && bad "L11 future mtime accepted" || pass "L11 future mtime rejected"
touch "$UNL"
# L7 drop_unlocked never deletes another basename
fyipq__drop_unlocked "$WORK/keys/other.pem"; [ -f "$WORK/keys/other.pem" ] && pass "L7 other file kept" || bad "L7 deleted a non-unlocked file"
fyipq__drop_unlocked "$UNL"; [ ! -e "$UNL" ] && pass "L7 unlocked file deleted" || bad "L7 unlocked not deleted"

echo "test-identity-pq-lib.sh summary: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
