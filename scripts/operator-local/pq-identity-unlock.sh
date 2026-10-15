#!/usr/bin/env bash
# scripts/operator-local/pq-identity-unlock.sh
#
# Decrypt the operator identity ML-DSA-87 key for signing. gen-identity.sh deletes the unlocked file after signing. After 2 hours gen-identity.sh REFUSES the file (exit 5), but the plaintext seed stays in the key dir until gen-identity.sh consumes it or pq-identity-lock.sh removes it.
#
# MUST NOT BE RUN ON VALIDATOR HOST OR WEB HOST (operator's local Mac only).
# Never reads validator keys. The passphrase is typed by the operator at the
# OpenSSL prompt; the AI never sees it. (Tests only: FY_PQ_PASSIN=file:<path>.)
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway.
#
# Exit codes: 0 ok; 2 wrong passphrase / cannot decrypt; 4 no TTY and no FY_PQ_PASSIN; 5 key does not match the committed public key
#   99  refusing to run: this looks like the validator host or the web host
#   1   no usable OpenSSL >= 3.5 (not LibreSSL)

set -euo pipefail

# ---- 1. Refuse to run anywhere except the operator's local Mac. -------------

HN="$(hostname -s 2>/dev/null || hostname)"
case "$HN" in
	*validator*|*web*|*-prod*|*deploy*)
		echo "REFUSE: pq-identity-unlock.sh on production-looking host '$HN'." >&2
		echo "        This script must only run on the operator's local Mac." >&2
		exit 99
		;;
esac

# Filesystem guards — anything that looks like the validator or web host.
if [[ -f /etc/freedom-yield/web-host || -f /etc/freedom-yield/validator-host ]]; then
	echo "REFUSE: detected /etc/freedom-yield/{web-host,validator-host} — server detected." >&2
	exit 99
fi
if [[ -d /home/deploy ]] && id deploy >/dev/null 2>&1; then
	echo "REFUSE: detected 'deploy' user — refusing to run on what looks like a server." >&2
	exit 99
fi

SCRIPT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_REPO_ROOT}"
# shellcheck source=../lib/identity-pq.sh
. "${SCRIPT_REPO_ROOT}/scripts/lib/identity-pq.sh"

O="$(fyipq__resolve_openssl)" || { echo "ERROR: no OpenSSL >= ${FYIPQ_MIN_OPENSSL} (Homebrew: brew install openssl@3; LibreSSL is not enough)." >&2; exit 1; }
# FY_PQ_PASSIN exists for tests only. The TTY requirement is an operator-safety
# guard; the security boundary is that the passphrase exists only in the
# operator's Dashlane and the AI never receives it. Only `file:<absolute path
# to an existing regular file>` is accepted: pass:/env:/fd:/stdin etc. would
# expose or mis-route the passphrase, so they are refused (exit 4).
if [ -n "${FY_PQ_PASSIN:-}" ]; then
	case "$FY_PQ_PASSIN" in
		file:/*) [ -f "${FY_PQ_PASSIN#file:}" ] || { echo "ERROR: FY_PQ_PASSIN file does not exist or is not a regular file." >&2; exit 4; } ;;
		*) echo "ERROR: FY_PQ_PASSIN accepts only file:<absolute path> (tests only); refusing." >&2; exit 4 ;;
	esac
fi
PASSIN_ARGS=(); PASSOUT_ARGS=()
if [ -n "${FY_PQ_PASSIN:-}" ]; then
	PASSIN_ARGS=(-passin "$FY_PQ_PASSIN"); PASSOUT_ARGS=(-passout "$FY_PQ_PASSIN")
fi
umask 077

ENC="$(fyipq__enc_path)"; UNL="$(fyipq__unlocked_path)"
PUB="${REPO_ROOT}/${FYIPQ_PUB_REL}"
if [ -z "${FY_PQ_PASSIN:-}" ] && [ ! -t 0 ]; then
	echo "ERROR: no terminal for the passphrase prompt — run this yourself at a terminal." >&2
	exit 4
fi
[ -f "$ENC" ] || { echo "ERROR: encrypted key not found: $ENC (run pq-identity-keygen.sh first)." >&2; exit 2; }
want="$(fyipq__pub_fingerprint "$PUB")" || { echo "ERROR: committed public key unreadable or malformed: $PUB" >&2; exit 5; }
trap 'rm -f "$UNL.tmp" "$UNL.tmp.pub"' EXIT
rm -f "$UNL.tmp" "$UNL.tmp.pub"

rc=0
if [ -n "${FY_PQ_PASSIN:-}" ]; then
	"$O" pkey -in "$ENC" ${PASSIN_ARGS[@]+"${PASSIN_ARGS[@]}"} -provparam ml-dsa.output_formats=seed-only -out "$UNL.tmp" </dev/null 2>/dev/null || rc=$?
else
	"$O" pkey -in "$ENC" -provparam ml-dsa.output_formats=seed-only -out "$UNL.tmp" || rc=$?
fi
if [ "$rc" -ne 0 ] || [ ! -s "$UNL.tmp" ]; then
	echo "ERROR: could not decrypt $ENC (wrong passphrase?)." >&2
	exit 2
fi
"$O" pkey -in "$UNL.tmp" -pubout -out "$UNL.tmp.pub" </dev/null
got="$(fyipq__pub_fingerprint "$UNL.tmp.pub")" || got=""
if [ "$got" != "$want" ]; then
	echo "ERROR: this key does not match the committed public key ($PUB)." >&2
	exit 5
fi
mv "$UNL.tmp" "$UNL"
chmod 600 "$UNL"
echo "Unlocked until gen-identity.sh consumes it. After 2 hours gen-identity.sh refuses it, but the file stays here until it is used or you run pq-identity-lock.sh."
