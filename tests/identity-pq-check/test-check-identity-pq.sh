#!/usr/bin/env bash
# test-check-identity-pq.sh — properties of scripts/check-identity-pq.sh.
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe, no broadcast pathway.
set -u
REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="${REPO_SRC}/scripts/check-identity-pq.sh"
. "${REPO_SRC}/tests/lib/pq-test-key.sh"
PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip_pass() { echo "SKIP: $1"; echo "RESULT: PASS"; exit 0; }
fy_pq_prereq_or_skip skip_pass
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq missing" >&2; exit 1; }
OSSL="$(fyipq__resolve_openssl)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/keys"; chmod 700 "$WORK/keys"
fy_pq_make_master "$WORK/keys"

# build_repo <dir> <schema_version> — fresh fixture repo; v2 gets verification_pq, pub, sig.
build_repo() {
	local r="$1" v="$2" fp
	rm -rf "$r"; mkdir -p "$r/public/api" "$r/public/.well-known"
	fy_pq_install "$WORK/keys" "$r"
	rm -f "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
	if [ "$v" = "1" ]; then
		rm -f "$r/${FYIPQ_PUB_REL}"
		jq -n '{schema_version:1, verification:{}}' > "$r/public/api/identity.json"
		return 0
	fi
	fp="$(fyipq__pub_fingerprint "$r/${FYIPQ_PUB_REL}")"
	jq -n --arg a "$FYIPQ_ALGORITHM" --arg s "$FYIPQ_STANDARD" --arg c "$FYIPQ_CONTEXT" \
		--arg pu "$FYIPQ_PUB_URL" --arg su "$FYIPQ_SIG_URL" --arg fp "$fp" --arg m "$FYIPQ_MIN_OPENSSL" \
		'{schema_version:2, verification:{}, verification_pq:{algorithm:$a, standard:$s, context_string:$c,
		  pubkey_url:$pu, pubkey_fingerprint:$fp, signature_url:$su, method:"openssl pkeyutl -verify ...",
		  minimum_openssl_version:$m}}' > "$r/public/api/identity.json"
	cp "$WORK/keys/master.pem" "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
	fyipq__sign "$OSSL" "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}" "$r/public/api/identity.json" "$r/${FYIPQ_SIG_REL}"
	rm -f "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
}
# run <repo> [args...] — sets RC and OUT
run() { local r="$1"; shift; OUT="$(FYD_REPO_ROOT="$r" bash "$CHECK" "$@" 2>&1)"; RC=$?; }
expect() { # name want_rc
	if [ "$RC" = "$2" ]; then pass "$1 (rc=$RC)"; else bad "$1 want rc=$2 got rc=$RC: $OUT"; fi
}
R="$WORK/repo"

build_repo "$R" 1; run "$R"; expect "C1 v1 manifest" 0
case "$OUT" in *"schema_version 1: no ML-DSA signature expected"*) pass "C1 line printed" ;; *) bad "C1 line missing: $OUT" ;; esac

build_repo "$R" 2; run "$R" --require-sig-verify; expect "C2 valid v2" 0

build_repo "$R" 2; rm -f "$R/${FYIPQ_SIG_REL}"; run "$R"; expect "C3 sig deleted" 3

build_repo "$R" 2; printf '\x00' | dd of="$R/${FYIPQ_SIG_REL}" bs=1 seek=100 conv=notrunc 2>/dev/null
# a second, different byte so the flip cannot be a no-op if byte 100 was already 00
printf '\xff' | dd of="$R/${FYIPQ_SIG_REL}" bs=1 seek=101 conv=notrunc 2>/dev/null
run "$R"; expect "C4 sig byte flipped" 3

build_repo "$R" 2
fp="$(jq -r .verification_pq.pubkey_fingerprint "$R/public/api/identity.json")"
last="${fp: -1}"; new=a; [ "$last" = "a" ] && new=b
jq --arg f "${fp%?}${new}" '.verification_pq.pubkey_fingerprint=$f' "$R/public/api/identity.json" > "$WORK/m.json" && cp "$WORK/m.json" "$R/public/api/identity.json"
run "$R" --require-sig-verify; expect "C5 fingerprint changed" 3
# C5 must be the fingerprint check itself, not the signature check: re-sign the edited manifest
cp "$WORK/keys/master.pem" "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
fyipq__sign "$OSSL" "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}" "$R/public/api/identity.json" "$R/${FYIPQ_SIG_REL}"
rm -f "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
run "$R"; expect "C5b fingerprint changed, signature valid" 3
case "$OUT" in *fingerprint*) pass "C5b names fingerprint" ;; *) bad "C5b output lacks fingerprint: $OUT" ;; esac

build_repo "$R" 2
jq '.verification_pq.context_string="other/context"' "$R/public/api/identity.json" > "$WORK/m.json" && cp "$WORK/m.json" "$R/public/api/identity.json"
cp "$WORK/keys/master.pem" "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
fyipq__sign "$OSSL" "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}" "$R/public/api/identity.json" "$R/${FYIPQ_SIG_REL}"
rm -f "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
run "$R"; expect "C6 context_string changed" 3

build_repo "$R" 2
OUT="$(FY_OPENSSL=/usr/bin/false FYD_REPO_ROOT="$R" bash "$CHECK" --require-sig-verify 2>&1)"; RC=$?
expect "C7a no openssl + --require-sig-verify" 4
OUT="$(FY_OPENSSL=/usr/bin/false FYD_REPO_ROOT="$R" bash "$CHECK" 2>&1)"; RC=$?
expect "C7b no openssl, no flag" 0
case "$OUT" in *"signature not verified (no OpenSSL >= 3.5)"*) pass "C7b line printed" ;; *) bad "C7b line missing: $OUT" ;; esac

# C9 manifest claims the previous parameter set (re-signed so only the field
# differs) -> 3. "ML-DSA-65" is the 2026-10-15 value, used here as the
# negative fixture: the checker must require the CURRENT algorithm.
build_repo "$R" 2
jq '.verification_pq.algorithm="ML-DSA-65"' "$R/public/api/identity.json" > "$WORK/m.json" && cp "$WORK/m.json" "$R/public/api/identity.json"
cp "$WORK/keys/master.pem" "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
fyipq__sign "$OSSL" "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}" "$R/public/api/identity.json" "$R/${FYIPQ_SIG_REL}"
rm -f "$WORK/keys/${FYIPQ_UNLOCKED_BASENAME}"
run "$R" --require-sig-verify; expect "C9 verification_pq.algorithm ML-DSA-65" 3
case "$OUT" in *"verification_pq.algorithm is 'ML-DSA-65', expected 'ML-DSA-87'"*) pass "C9 names the algorithm field" ;; *) bad "C9 output lacks the algorithm field: $OUT" ;; esac

# C10 the committed key is an ML-DSA-65 key, everything else self-consistent
# (fingerprint of that key, signature by that key, manifest fields current)
# -> 3: a valid signature by another ML-DSA level is not the identity key.
build_repo "$R" 2
"$OSSL" genpkey -algorithm ML-DSA-65 -out "$WORK/k65.pem" </dev/null 2>/dev/null
"$OSSL" pkey -in "$WORK/k65.pem" -pubout -out "$R/${FYIPQ_PUB_REL}" </dev/null
jq --arg f "$(fyipq__pub_fingerprint "$R/${FYIPQ_PUB_REL}")" '.verification_pq.pubkey_fingerprint=$f' \
	"$R/public/api/identity.json" > "$WORK/m.json" && cp "$WORK/m.json" "$R/public/api/identity.json"
fyipq__sign "$OSSL" "$WORK/k65.pem" "$R/public/api/identity.json" "$R/${FYIPQ_SIG_REL}"
fyipq__verify "$OSSL" "$R/${FYIPQ_PUB_REL}" "$R/public/api/identity.json" "$R/${FYIPQ_SIG_REL}" \
	&& pass "C10 fixture: the ML-DSA-65 signature itself verifies" || bad "C10 fixture broken: 65 signature does not verify"
run "$R" --require-sig-verify; expect "C10 committed key is ML-DSA-65" 3
case "$OUT" in *"is a 'ML-DSA-65' key, expected 'ML-DSA-87'"*) pass "C10 names the key's algorithm" ;; *) bad "C10 output lacks the key algorithm: $OUT" ;; esac

# C8 unreadable / invalid manifest -> 2
build_repo "$R" 2; printf 'not json' > "$R/public/api/identity.json"; run "$R"; expect "C8 invalid JSON" 2

echo "passed=$PASS failed=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
