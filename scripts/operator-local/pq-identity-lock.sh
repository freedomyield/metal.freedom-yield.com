#!/usr/bin/env bash
# scripts/operator-local/pq-identity-lock.sh
#
# Delete the unlocked operator identity ML-DSA-87 key (re-lock). Idempotent.
# Always prints the full path it checked. Exit 3 + WARNING if that directory
# holds no encrypted ML-DSA key (wrong HOME / FY_PQ_KEY_DIR).
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway.
set -euo pipefail
SCRIPT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/identity-pq.sh
. "${SCRIPT_REPO_ROOT}/scripts/lib/identity-pq.sh"
UNL="$(fyipq__unlocked_path)"
KD="$(fyipq__key_dir)"
if [ -e "$UNL" ]; then
	fyipq__drop_unlocked "$UNL"
	echo "locked: $UNL"
else
	echo "already locked: $UNL"
fi
# The lock resolves ${HOME}/.freedom-yield-identity unless FY_PQ_KEY_DIR is set,
# so under a different HOME it can look in the wrong place and report
# "already locked" about a directory that never held the key. A directory with
# no encrypted ML-DSA key is not the PQ key dir: say so, loudly.
if [ ! -e "${KD}/${FYIPQ_ENC_BASENAME}" ]; then
	echo "WARNING: ${KD} holds no encrypted ML-DSA key — is HOME/FY_PQ_KEY_DIR right?" >&2
	exit 3
fi
