#!/usr/bin/env bash
# identity-pq.sh — the single home of the operator identity's post-quantum
# (ML-DSA, FIPS 204) constants and primitives. Sourced, never executed.
# Spec: docs/superpowers/specs/2026-10-15-identity-pq-signature-design.md.
# Must stay bash 3.2 compatible (macOS /bin/bash).
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway.

FYIPQ_ALGORITHM="ML-DSA-65"
FYIPQ_STANDARD="FIPS 204"
FYIPQ_CONTEXT="freedom-yield/validator-identity"
FYIPQ_MIN_OPENSSL="3.5"
FYIPQ_PUB_REL="public/.well-known/operator-identity-mldsa65.pub"
FYIPQ_SIG_REL="public/api/identity.json.mldsa65.sig"
FYIPQ_PUB_URL="https://metal.freedom-yield.com/.well-known/operator-identity-mldsa65.pub"
FYIPQ_SIG_URL="https://metal.freedom-yield.com/api/identity.json.mldsa65.sig"
FYIPQ_ENC_BASENAME="operator-identity-mldsa65.enc.pem"
FYIPQ_UNLOCKED_BASENAME="operator-identity-mldsa65.unlocked.pem"
FYIPQ_UNLOCK_MAX_AGE_SEC_DEFAULT=7200

fyipq__key_dir()       { printf '%s\n' "${FY_PQ_KEY_DIR:-${HOME}/.freedom-yield-identity}"; }
fyipq__enc_path()      { printf '%s/%s\n' "$(fyipq__key_dir)" "$FYIPQ_ENC_BASENAME"; }
fyipq__unlocked_path() { printf '%s/%s\n' "$(fyipq__key_dir)" "$FYIPQ_UNLOCKED_BASENAME"; }

# OpenSSL (not LibreSSL) >= 3.5 — ML-DSA arrived in 3.5.
fyipq__openssl_ok() {
	local v num maj rest min
	[ -n "${1:-}" ] && [ -x "$1" ] || return 1
	v="$("$1" version 2>/dev/null </dev/null)" || return 1
	case "$v" in "OpenSSL "*) ;; *) return 1 ;; esac
	num="${v#OpenSSL }"; num="${num%% *}"
	maj="${num%%.*}"; rest="${num#*.}"; min="${rest%%.*}"
	case "${maj}${min}" in ""|*[!0-9]*) return 1 ;; esac
	[ "$maj" -gt 3 ] && return 0
	[ "$maj" -eq 3 ] && [ "$min" -ge 5 ]
}

# FY_OPENSSL, when set, is the ONLY candidate: an explicit choice that is
# wrong must fail, not be silently replaced by another binary.
fyipq__resolve_openssl() {
	local c
	if [ -n "${FY_OPENSSL:-}" ]; then
		fyipq__openssl_ok "$FY_OPENSSL" && { printf '%s\n' "$FY_OPENSSL"; return 0; }
		return 1
	fi
	for c in /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl 2>/dev/null)"; do
		fyipq__openssl_ok "$c" && { printf '%s\n' "$c"; return 0; }
	done
	return 1
}

fyipq__sha256_hex() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
	else shasum -a 256 | awk '{print $1}'; fi
}

# DER = base64 body of the single PUBLIC KEY block. No OpenSSL needed, so
# this also works where OpenSSL predates ML-DSA.
fyipq__pub_fingerprint() {
	local f="$1" begins body hex tmp
	[ -r "$f" ] || return 1
	begins="$(grep -c '^-----BEGIN ' "$f")"
	[ "$begins" = "1" ] || return 1
	grep -q '^-----BEGIN PUBLIC KEY-----$' "$f" || return 1
	body="$(sed -n '/^-----BEGIN PUBLIC KEY-----$/,/^-----END PUBLIC KEY-----$/p' "$f" | sed '1d;$d' | tr -d '\r\n')"
	[ -n "$body" ] || return 1
	case "$body" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
	# base64 must be a whole number of 4-char groups.
	[ $(( ${#body} % 4 )) -eq 0 ] || return 1
	# Decode to a temp file so base64's OWN exit status is checked: in a pipe
	# only the last command's status is seen, and a bad body would otherwise
	# hash the empty input.
	tmp="$(mktemp)" || return 1
	if ! printf '%s' "$body" | base64 -d >"$tmp" 2>/dev/null; then
		rm -f "$tmp"; return 1
	fi
	if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
	hex="$(fyipq__sha256_hex < "$tmp")"
	rm -f "$tmp"
	case "$hex" in [0-9a-f]*) ;; *) return 1 ;; esac
	[ "${#hex}" -eq 64 ] || return 1
	printf 'sha256:%s\n' "$hex"
}

fyipq__pub_algorithm() {
	"$1" pkey -pubin -in "$2" -noout -text </dev/null 2>/dev/null | head -n 1 | sed 's/ Public-Key:.*$//'
}

fyipq__sign() {
	"$1" pkeyutl -sign -inkey "$2" -rawin -in "$3" \
		-pkeyopt "context-string:${FYIPQ_CONTEXT}" -out "$4" </dev/null
}

fyipq__verify() {
	"$1" pkeyutl -verify -pubin -inkey "$2" -rawin -in "$3" -sigfile "$4" \
		-pkeyopt "context-string:${FYIPQ_CONTEXT}" </dev/null >/dev/null 2>&1
}

fyipq__mtime() {
	# GNU first: on GNU coreutils `-f` means file-system status, not mtime.
	local out
	out="$(stat -c %Y "$1" 2>/dev/null)" && case "$out" in ''|*[!0-9]*) ;; *) printf '%s\n' "$out"; return 0 ;; esac
	out="$(stat -f %m "$1" 2>/dev/null)" && case "$out" in ''|*[!0-9]*) ;; *) printf '%s\n' "$out"; return 0 ;; esac
	return 1
}

# fyipq__check_unlocked <path> <repo_root>...
fyipq__check_unlocked() {
	local p="$1" real root now mt max age
	shift
	if [ ! -f "$p" ]; then
		echo "ERROR: unlocked ML-DSA key not found: $p — run scripts/operator-local/pq-identity-unlock.sh first." >&2
		return 1
	fi
	if [ "$(basename "$p")" != "$FYIPQ_UNLOCKED_BASENAME" ]; then
		echo "ERROR: unlocked ML-DSA key must be named $FYIPQ_UNLOCKED_BASENAME (got $(basename "$p"))." >&2
		return 1
	fi
	real="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
	case "$real" in */public/*)
		echo "ERROR: unlocked ML-DSA key is under a public/ path: $real" >&2; return 1 ;;
	esac
	for root in "$@"; do
		[ -n "$root" ] || continue
		root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
		case "$real" in "$root"/*)
			echo "ERROR: unlocked ML-DSA key is inside the repo: $real" >&2; return 1 ;;
		esac
	done
	now="$(date +%s)"
	mt="$(fyipq__mtime "$p")" || { echo "ERROR: cannot read mtime of unlocked ML-DSA key: $p" >&2; return 1; }
	max="${FY_PQ_UNLOCK_MAX_AGE_SEC:-$FYIPQ_UNLOCK_MAX_AGE_SEC_DEFAULT}"
	case "$max" in ''|*[!0-9]*)
		echo "ERROR: FY_PQ_UNLOCK_MAX_AGE_SEC must be a non-negative integer (got '$max')." >&2; return 1 ;;
	esac
	age=$((now - mt))
	if [ "$age" -lt -60 ]; then
		echo "ERROR: unlocked ML-DSA key mtime is ${age}s in the future — refusing." >&2
		return 1
	fi
	if [ "$age" -gt "$max" ]; then
		echo "ERROR: unlocked ML-DSA key is ${age}s old (limit ${max}s) — run pq-identity-unlock.sh again." >&2
		return 1
	fi
	return 0
}

fyipq__drop_unlocked() {
	[ -n "${1:-}" ] || return 0
	[ "$(basename "$1")" = "$FYIPQ_UNLOCKED_BASENAME" ] || return 0
	rm -f "$1"
}
