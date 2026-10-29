#!/usr/bin/env bash
# test-pq-identity-tools.sh — pq-identity-keygen/unlock/lock.sh properties.
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe, no broadcast pathway.
set -u
REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
OL="${REPO_SRC}/scripts/operator-local"
. "${REPO_SRC}/tests/lib/pq-test-key.sh"
PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip_pass() { echo "SKIP: $1"; echo "RESULT: PASS"; exit 0; }
fy_pq_prereq_or_skip skip_pass
OSSL="$(fyipq__resolve_openssl)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
KD="$WORK/keys"; FR="$WORK/repo"; mkdir -p "$FR/public/.well-known"
printf 'test-passphrase-only\n' > "$WORK/pw"; chmod 600 "$WORK/pw"
printf 'a-different-passphrase\n' > "$WORK/pw-wrong"; chmod 600 "$WORK/pw-wrong"
ENC="$KD/${FYIPQ_ENC_BASENAME}"; UNL="$KD/${FYIPQ_UNLOCKED_BASENAME}"; PUB="$FR/${FYIPQ_PUB_REL}"
OUTALL="$WORK/all-output"; : > "$OUTALL"
run() { # run <script> [env...] ; captures into $WORK/out, appends to OUTALL
	local s="$1"; shift
	env FY_PQ_KEY_DIR="$KD" REPO_ROOT="$FR" "$@" bash "$OL/$s" >"$WORK/out" 2>&1 </dev/null
	local rc=$?; cat "$WORK/out" >> "$OUTALL"; return $rc
}
PW="FY_PQ_PASSIN=file:$WORK/pw"

# T1 keygen
run pq-identity-keygen.sh "$PW"; rc=$?
hdr="-----BEG""IN ENC""RYPTED PRI""VATE KEY-----"
if [ "$rc" -eq 0 ] && [ "$(head -n 1 "$ENC" 2>/dev/null)" = "$hdr" ] \
   && "$OSSL" asn1parse -in "$ENC" 2>/dev/null </dev/null | grep -q scrypt \
   && ! "$OSSL" asn1parse -in "$ENC" 2>/dev/null </dev/null | grep -qi pbkdf2; then
	pass "T1 keygen: encrypted PKCS#8 with scrypt"
else bad "MUTATION NOT CAUGHT: T1 keygen rc=$rc header/scrypt wrong"; fi
# T2 public algorithm
[ "$(fyipq__pub_algorithm "$OSSL" "$PUB")" = "ML-DSA-87" ] && pass "T2 published pub is ML-DSA-87" || bad "T2 pub algorithm"
# T3 no overwrite
h1="$(fyipq__sha256_hex < "$ENC")"
run pq-identity-keygen.sh "$PW"; rc=$?
[ "$rc" -eq 3 ] && [ "$(fyipq__sha256_hex < "$ENC")" = "$h1" ] && pass "T3 second keygen exit 3, key unchanged" || bad "T3 rc=$rc"
# T4 unlock
run pq-identity-unlock.sh "$PW"; rc=$?
mode="$(stat -c %a "$UNL" 2>/dev/null)"
case "$mode" in ''|*[!0-9]*) mode="$(stat -f %Lp "$UNL" 2>/dev/null)";; esac
printf 'msg\n' > "$WORK/msg"
if [ "$rc" -eq 0 ] && [ "$mode" = "600" ] && fyipq__sign "$OSSL" "$UNL" "$WORK/msg" "$WORK/sig" && fyipq__verify "$OSSL" "$PUB" "$WORK/msg" "$WORK/sig"; then
	pass "T4 unlock: mode 600, signs, verifies against published pub"
else bad "T4 rc=$rc mode=$mode"; fi
UNLBODY="$(sed -n 2p "$UNL")"
rm -f "$UNL"
# T5 wrong passphrase
run pq-identity-unlock.sh "FY_PQ_PASSIN=file:$WORK/pw-wrong"; rc=$?
left="$(ls "$KD" | grep -c 'unlocked' || true)"
[ "$rc" -eq 2 ] && [ "$left" = "0" ] && pass "T5 wrong passphrase: exit 2, nothing left" || bad "T5 rc=$rc left=$left"
# T6 mismatched committed pub
cp "$PUB" "$WORK/pub.good"
"$OSSL" genpkey -algorithm "$FYIPQ_ALGORITHM" -provparam ml-dsa.output_formats=seed-only -out "$WORK/other.pem" </dev/null
"$OSSL" pkey -in "$WORK/other.pem" -pubout -out "$PUB" </dev/null
run pq-identity-unlock.sh "$PW"; rc=$?
left="$(ls "$KD" | grep -c 'unlocked' || true)"
[ "$rc" -eq 5 ] && [ "$left" = "0" ] && pass "T6 mismatched pub: exit 5, nothing left" || bad "MUTATION NOT CAUGHT: T6 rc=$rc left=$left"
cp "$WORK/pub.good" "$PUB"
# T7 no TTY, no passin
run pq-identity-unlock.sh; rc=$?
[ "$rc" -eq 4 ] && pass "T7 no TTY / no FY_PQ_PASSIN: exit 4" || bad "T7 rc=$rc"
# T8 lock
run pq-identity-unlock.sh "$PW"
run pq-identity-lock.sh; rc1=$?; o1="$(cat "$WORK/out")"
run pq-identity-lock.sh; rc2=$?; o2="$(cat "$WORK/out")"
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ ! -e "$UNL" ] && [ "$o1" = "locked: $UNL" ] && [ "$o2" = "already locked: $UNL" ] \
	&& pass "T8 lock deletes; second lock says already locked" || bad "T8 rc=$rc1/$rc2 o1=$o1 o2=$o2"
# T8b lock on a directory that holds no encrypted key: warn, exit 3, name the path
EMPTYD="$WORK/not-a-key-dir"; mkdir -p "$EMPTYD"
for cand in "$EMPTYD" "$WORK/nonexistent-dir"; do
	env FY_PQ_KEY_DIR="$cand" bash "$OL/pq-identity-lock.sh" >"$WORK/out" 2>&1 </dev/null; rc=$?
	if [ "$rc" -eq 3 ] && grep -qF "WARNING: $cand holds no encrypted ML-DSA key" "$WORK/out" && grep -qF "already locked: $cand/${FYIPQ_UNLOCKED_BASENAME}" "$WORK/out"; then
		pass "T8b lock on $(basename "$cand"): exit 3, warning, path printed"
	else bad "MUTATION NOT CAUGHT: T8b lock on $(basename "$cand") rc=$rc out=$(cat "$WORK/out")"; fi
done
# T9 no key body in any output
if [ -n "$UNLBODY" ] && ! grep -qF "$UNLBODY" "$OUTALL" && ! grep -qF "test-passphrase-only" "$OUTALL"; then
	pass "T9 no key material or passphrase in command output"
else bad "T9 leak or empty probe"; fi

# T10 FY_PQ_PASSIN whitelist: only file:<absolute existing file>
KD0="$KD"; FR0="$FR"; KD="$WORK/keys2"; FR="$WORK/repo2"; mkdir -p "$FR/public/.well-known"
ENC="$KD/${FYIPQ_ENC_BASENAME}"; PUB="$FR/${FYIPQ_PUB_REL}"
for src in "pass:x" "env:FOO" "file:relative-pw" "file:$WORK/nonexistent"; do
	for sc in pq-identity-keygen.sh pq-identity-unlock.sh; do
		FOO=x run "$sc" "FY_PQ_PASSIN=$src"; rc=$?
		if [ "$rc" -eq 4 ] && [ ! -e "$KD" ] && [ ! -e "$PUB" ]; then pass "T10 $sc refuses $src (exit 4, nothing created)"
		else bad "MUTATION NOT CAUGHT: T10 $sc accepted $src rc=$rc"; fi
	done
done
# T11 keygen whose pub step fails leaves neither file, re-run succeeds
chmod 500 "$FR/public/.well-known"
run pq-identity-keygen.sh "$PW"; rc=$?
leftover="$(ls "$KD" 2>/dev/null | wc -l | tr -d ' ')"
chmod 700 "$FR/public/.well-known"
if [ "$rc" -ne 0 ] && [ "$leftover" = "0" ] && [ ! -e "$PUB" ] && [ ! -e "$PUB.tmp" ]; then
	pass "T11 failed pub derivation: non-zero, no enc/tmp left"
else bad "MUTATION NOT CAUGHT: T11 rc=$rc leftover=$leftover"; fi
run pq-identity-keygen.sh "$PW"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$ENC" ] && [ -f "$PUB" ] && pass "T11 re-run keygen succeeds" || bad "T11 re-run rc=$rc"
KD="$KD0"; FR="$FR0"

echo "test-pq-identity-tools.sh summary: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
