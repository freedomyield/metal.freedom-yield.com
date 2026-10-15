#!/usr/bin/env bash
# pq-test-key.sh — throwaway ML-DSA-65 keys for tests. Sourced.
# Requires scripts/lib/identity-pq.sh to be sourced first OR sources it.
_FY_PQ_TK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${_FY_PQ_TK_REPO}/scripts/lib/identity-pq.sh"

# fy_pq_prereq_or_skip <skip_fn>
fy_pq_prereq_or_skip() {
	if fyipq__resolve_openssl >/dev/null; then return 0; fi
	if [ "${FY_REQUIRE_PQ:-0}" = "1" ]; then
		echo "FATAL: FY_REQUIRE_PQ=1 but no OpenSSL >= ${FYIPQ_MIN_OPENSSL} found" >&2
		exit 1
	fi
	"$1" "no OpenSSL >= ${FYIPQ_MIN_OPENSSL} (set FY_REQUIRE_PQ=1 to make this a failure)"
}

fy_pq_make_master() {
	local o; o="$(fyipq__resolve_openssl)" || return 1
	"$o" genpkey -algorithm "$FYIPQ_ALGORITHM" -provparam ml-dsa.output_formats=seed-only \
		-out "$1/master.pem" </dev/null
	chmod 600 "$1/master.pem"
}

# fy_pq_install <keydir> <fake_repo> — (re)creates the unlocked key and the
# committed public key. Call before EVERY gen-identity.sh run: the script
# deletes the unlocked key on exit.
fy_pq_install() {
	local o; o="$(fyipq__resolve_openssl)" || return 1
	cp "$1/master.pem" "$1/${FYIPQ_UNLOCKED_BASENAME}"
	chmod 600 "$1/${FYIPQ_UNLOCKED_BASENAME}"
	mkdir -p "$2/public/.well-known"
	"$o" pkey -in "$1/master.pem" -pubout -out "$2/${FYIPQ_PUB_REL}" </dev/null
}
