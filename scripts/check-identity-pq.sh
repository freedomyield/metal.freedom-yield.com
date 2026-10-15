#!/usr/bin/env bash
# check-identity-pq.sh — repo-mode check of the ML-DSA-65 (FIPS 204) signature
# over public/api/identity.json. Read-only; no alerting (check-identity-pins.sh
# is the alerting checker and is deliberately separate).
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway.
#
# Usage: bash scripts/check-identity-pq.sh [--require-sig-verify]
#   env FYD_REPO_ROOT  repo root (default: this script's repo)
#   env FY_OPENSSL     explicit OpenSSL >= 3.5 binary (see scripts/lib/identity-pq.sh)
#
# Exit codes:
#   0  manifest is schema v1 (no PQ signature expected) or v2 and fully valid
#   2  cannot run (jq missing, manifest unreadable / invalid JSON, bad usage)
#   3  v2 manifest but a check failed (files missing, verification_pq fields,
#      fingerprint mismatch, signature invalid)
#   4  --require-sig-verify given but no OpenSSL >= 3.5 is available
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${FYD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=lib/identity-pq.sh
. "$SCRIPT_DIR/lib/identity-pq.sh"

REQUIRE=0
for a in "$@"; do
	case "$a" in
		--require-sig-verify) REQUIRE=1 ;;
		*) echo "usage: $0 [--require-sig-verify]" >&2; exit 2 ;;
	esac
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 2; }
MANIFEST="$REPO/public/api/identity.json"
[ -r "$MANIFEST" ] || { echo "ERROR: cannot read $MANIFEST" >&2; exit 2; }
SV="$(jq -r '.schema_version' "$MANIFEST" 2>/dev/null)" || { echo "ERROR: $MANIFEST is not valid JSON" >&2; exit 2; }

if [ "$SV" = "1" ]; then
	echo "schema_version 1: no ML-DSA signature expected"
	exit 0
fi
if [ "$SV" != "2" ]; then
	echo "FAIL: unsupported schema_version '$SV'" >&2
	exit 3
fi

OSSL=""
OSSL="$(fyipq__resolve_openssl)" || OSSL=""
if [ -z "$OSSL" ] && [ "$REQUIRE" = "1" ]; then
	echo "ERROR: --require-sig-verify but no OpenSSL >= ${FYIPQ_MIN_OPENSSL} available" >&2
	exit 4
fi

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

PUB="$REPO/$FYIPQ_PUB_REL"
SIG="$REPO/$FYIPQ_SIG_REL"
[ -f "$PUB" ] || fail "missing $FYIPQ_PUB_REL"
[ -f "$SIG" ] || fail "missing $FYIPQ_SIG_REL"

# verification_pq fields must equal the library constants (not the method string).
chk_field() { # field expected
	local got
	got="$(jq -r --arg k "$1" '.verification_pq[$k]' "$MANIFEST")"
	[ "$got" = "$2" ] || fail "verification_pq.$1 is '${got}', expected '$2'"
}
chk_field algorithm "$FYIPQ_ALGORITHM"
chk_field standard "$FYIPQ_STANDARD"
chk_field context_string "$FYIPQ_CONTEXT"
chk_field pubkey_url "$FYIPQ_PUB_URL"
chk_field signature_url "$FYIPQ_SIG_URL"
chk_field minimum_openssl_version "$FYIPQ_MIN_OPENSSL"

if [ -f "$PUB" ]; then
	WANT_FP="$(jq -r '.verification_pq.pubkey_fingerprint' "$MANIFEST")"
	GOT_FP="$(fyipq__pub_fingerprint "$PUB")" || GOT_FP=""
	if [ -z "$GOT_FP" ]; then
		fail "cannot compute fingerprint of $FYIPQ_PUB_REL"
	elif [ "$GOT_FP" != "$WANT_FP" ]; then
		fail "pubkey_fingerprint mismatch: manifest '${WANT_FP}' vs $FYIPQ_PUB_REL '${GOT_FP}'"
	fi
fi

if [ -n "$OSSL" ]; then
	if [ -f "$PUB" ] && [ -f "$SIG" ]; then
		fyipq__verify "$OSSL" "$PUB" "$MANIFEST" "$SIG" || fail "ML-DSA-65 signature does not verify"
	fi
else
	echo "signature not verified (no OpenSSL >= ${FYIPQ_MIN_OPENSSL})"
fi

if [ "$FAILS" -ne 0 ]; then exit 3; fi
echo "OK: schema_version 2, ML-DSA-65 identity checks passed"
exit 0
