#!/usr/bin/env bash
# scripts/operator-local/pq-identity-keygen.sh
#
# Create the operator identity ML-DSA-87 key: scrypt-encrypted seed-only PEM outside the repo, public key into public/.well-known/.
#
# MUST NOT BE RUN ON VALIDATOR HOST OR WEB HOST (operator's local Mac only).
# Never reads validator keys. The passphrase is typed by the operator at the
# OpenSSL prompt; the AI never sees it. On a terminal OpenSSL asks THREE times:
# to encrypt the key, to verify it, and again to derive the public key.
# (Tests only: FY_PQ_PASSIN=file:<path>.)
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway.
#
# Exit codes: 0 ok; 3 encrypted key already exists (never overwritten); 4 no TTY and no FY_PQ_PASSIN
#   99  refusing to run: this looks like the validator host or the web host
#   1   no usable OpenSSL >= 3.5 (not LibreSSL)

set -euo pipefail

# ---- 1. Refuse to run anywhere except the operator's local Mac. -------------

HN="$(hostname -s 2>/dev/null || hostname)"
case "$HN" in
	*validator*|*web*|*-prod*|*deploy*)
		echo "REFUSE: pq-identity-keygen.sh on production-looking host '$HN'." >&2
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

ENC="$(fyipq__enc_path)"; KD="$(fyipq__key_dir)"
PUB="${REPO_ROOT}/${FYIPQ_PUB_REL}"
if [ -e "$ENC" ]; then
	echo "ERROR: $ENC already exists — never overwritten. Move it aside deliberately if you really want a new key." >&2
	exit 3
fi
if [ -z "${FY_PQ_PASSIN:-}" ] && [ ! -t 0 ]; then
	echo "ERROR: no terminal for the passphrase prompt — run this yourself at a terminal." >&2
	exit 4
fi
mkdir -p "$KD"; chmod 700 "$KD"
mkdir -p "$(dirname "$PUB")"
rm -f "$ENC.tmp" "$PUB.tmp"
trap 'rm -f "$ENC.tmp" "$PUB.tmp"' EXIT

# Generate + encrypt in one pipe: no plaintext key ever touches the disk.
"$O" genpkey -algorithm "$FYIPQ_ALGORITHM" -provparam ml-dsa.output_formats=seed-only </dev/null \
	| "$O" pkcs8 -topk8 -v2 aes-256-cbc -scrypt ${PASSOUT_ARGS[@]+"${PASSOUT_ARGS[@]}"} \
		-provparam ml-dsa.output_formats=seed-only -out "$ENC.tmp"
# Public key from the temp file FIRST (asks for the passphrase again on a
# terminal): a failure here leaves neither file, so keygen can simply be re-run.
if [ -n "${FY_PQ_PASSIN:-}" ]; then
	"$O" pkey -in "$ENC.tmp" ${PASSIN_ARGS[@]+"${PASSIN_ARGS[@]}"} -pubout -out "$PUB.tmp" </dev/null
else
	"$O" pkey -in "$ENC.tmp" -pubout -out "$PUB.tmp"
fi
mv "$PUB.tmp" "$PUB"
mv "$ENC.tmp" "$ENC"
chmod 600 "$ENC"

echo "algorithm:   $FYIPQ_ALGORITHM"
echo "fingerprint: $(fyipq__pub_fingerprint "$PUB")"
echo "public key:  $PUB"
echo "encrypted:   $ENC"
echo "Back up the encrypted key file to the Dashlane entry named in the AI's ping (the passphrase too)."
