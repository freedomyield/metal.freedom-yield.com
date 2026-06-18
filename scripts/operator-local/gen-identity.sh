#!/usr/bin/env bash
# scripts/operator-local/gen-identity.sh
#
# Generate and sign the operator identity manifest for Freedom Yield Metal.
#
# MUST NOT BE RUN ON VALIDATOR HOST OR WEB HOST.
# This helper is for the operator's local Mac only.
# It must never read validator keys, staking keys, BLS keys, signer.key, or staker.key.
#
# Sync exclusion:
#   scripts/sync-to-validator-host.sh excludes operator-local/ so this file
#   is never shipped to the validator host or web host. Verify with --dry-run.
#
# What this helper does:
#   1. Composes identity.json from a pinned schema (matches public/api/identity.example.json).
#   2. Validates JSON with `jq -e empty`.
#   3. Signs with `ssh-keygen -Y sign` using namespace freedom-yield/validator-identity.
#   4. Self-verifies with `ssh-keygen -Y verify` before publishing.
#   5. Atomically places identity.json and identity.json.sig in public/api/.
#
# What this helper does NOT do:
#   - It does not generate the ed25519 key. Generate it on the operator Mac:
#       ssh-keygen -t ed25519 -f ~/.ssh/freedom_yield_operator \
#                  -C "freedom-yield-operator-identity"
#     and never commit the private file.
#   - It does not commit anything. Run git add / git diff / git commit yourself.
#   - It does not copy the .pub into public/.well-known/. Do that manually so
#     the operator reviews exactly which bytes go public.
#
# Required env:
#   OPERATOR_IDENTITY_KEY   path to the operator's local private ed25519 key
#                           (mandatory; no hardcoded default — fail loud if absent).
#                           The corresponding .pub file is expected next to it.
#
# Optional env:
#   REPO_ROOT               path to repo (default: two levels above this script).
#   NODE_ID                 NodeID string (default: pinned mainnet NodeID).
#   NETWORK                 network label (default: metal-mainnet).
#   SITE                    canonical site URL (default: https://metal.freedom-yield.com/).
#   KEY_IAT                 issued-at ISO-8601 UTC (default: now).
#   KEY_EXP                 expiry ISO-8601 UTC (default: KEY_IAT + 365 days).
#   PRINCIPAL               allowed_signers principal (default: freedom-yield).
#
# Usage:
#   export OPERATOR_IDENTITY_KEY=~/.ssh/freedom_yield_operator
#   bash scripts/operator-local/gen-identity.sh

set -euo pipefail

# ---- 1. Refuse to run anywhere except the operator's local Mac. -------------

# Hostname guard.
HN="$(hostname -s 2>/dev/null || hostname)"
case "$HN" in
	*validator*|*hetzner*|*sin1*|*web*|*xserver*|*-prod*|*deploy*)
		echo "REFUSE: gen-identity.sh on production-looking host '$HN'." >&2
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

# ---- 2. Resolve inputs. -----------------------------------------------------

: "${OPERATOR_IDENTITY_KEY:?Set OPERATOR_IDENTITY_KEY to your local private key path}"

if [[ ! -f "${OPERATOR_IDENTITY_KEY}" ]]; then
	echo "ERROR: private key not found: ${OPERATOR_IDENTITY_KEY}" >&2
	exit 1
fi
if [[ ! -f "${OPERATOR_IDENTITY_KEY}.pub" ]]; then
	echo "ERROR: public key not found alongside private key: ${OPERATOR_IDENTITY_KEY}.pub" >&2
	exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT_DIR="${REPO_ROOT}/public/api"
OUT_JSON="${OUT_DIR}/identity.json"
OUT_SIG="${OUT_DIR}/identity.json.sig"

[[ -d "${OUT_DIR}" ]] || { echo "ERROR: ${OUT_DIR} not found — wrong REPO_ROOT?" >&2; exit 1; }

# Key-path-in-repo guard — refuse if the key file appears to live inside the repo.
KEY_REAL="$(cd "$(dirname "${OPERATOR_IDENTITY_KEY}")" && pwd)/$(basename "${OPERATOR_IDENTITY_KEY}")"
case "${KEY_REAL}" in
	"${REPO_ROOT}"/*|*"/public/"*)
		echo "REFUSE: operator identity private key path looks like it lives inside the repo:" >&2
		echo "        ${KEY_REAL}" >&2
		echo "        Move the key out of the repo before running." >&2
		exit 98
		;;
esac

NODE_ID="${NODE_ID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
NETWORK="${NETWORK:-metal-mainnet}"
SITE="${SITE:-https://metal.freedom-yield.com/}"
PRINCIPAL="${PRINCIPAL:-freedom-yield}"
NAMESPACE="freedom-yield/validator-identity"

NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
KEY_IAT="${KEY_IAT:-${NOW_UTC}}"
if [[ -z "${KEY_EXP:-}" ]]; then
	if date -j -v+365d -u +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
		# BSD date (macOS).
		KEY_EXP="$(date -j -v+365d -f "%Y-%m-%dT%H:%M:%SZ" "${KEY_IAT}" -u +%Y-%m-%dT%H:%M:%SZ)"
	else
		# GNU date (Linux).
		KEY_EXP="$(date -u -d "${KEY_IAT} +365 days" +%Y-%m-%dT%H:%M:%SZ)"
	fi
fi

# ---- 3. Compute the SHA256:base64 SSH fingerprint. --------------------------
# ssh-keygen -l -f <pub> emits:  "<bits> SHA256:<base64> <comment> (ED25519)"
FP_LINE="$(ssh-keygen -l -f "${OPERATOR_IDENTITY_KEY}.pub")"
FP="$(printf '%s\n' "${FP_LINE}" | awk '{print $2}')"
case "${FP}" in
	SHA256:*) ;;
	*)
		echo "ERROR: unexpected fingerprint format from ssh-keygen -l: ${FP_LINE}" >&2
		exit 1
		;;
esac

# ---- 4. Compose identity.json into a tmp file. ------------------------------

TMP_JSON="$(mktemp -t identity.XXXXXX)"
trap 'rm -f "${TMP_JSON}" "${TMP_JSON}.sig"' EXIT

COMMENT_TEXT="Operator identity manifest for Freedom Yield Metal Blockchain validator. Signed with the operator identity key whose public form is at /.well-known/operator-identity.pub. Verification uses ssh-keygen -Y verify (OpenSSH 8.0+). The validator's staker.key / BLS signer.key are NOT used in this signature. The runtime file is regenerated by scripts/operator-local/gen-identity.sh on the operator's local Mac."

jq -n \
	--arg comment "${COMMENT_TEXT}" \
	--arg brand "Freedom Yield" \
	--arg node_id "${NODE_ID}" \
	--arg node_id_authority "https://explorer.metalblockchain.org/" \
	--arg network "${NETWORK}" \
	--arg site "${SITE}" \
	--arg pubkey_url "https://metal.freedom-yield.com/.well-known/operator-identity.pub" \
	--arg fp "${FP}" \
	--arg iat "${KEY_IAT}" \
	--arg exp "${KEY_EXP}" \
	--arg principal "${PRINCIPAL}" \
	--arg namespace "${NAMESPACE}" \
	--arg generated_at "${NOW_UTC}" \
	'{
		_comment: $comment,
		schema_version: 1,
		brand: $brand,
		node_id: $node_id,
		node_id_authority: $node_id_authority,
		network: $network,
		site: $site,
		operator_identity_pubkey_url: $pubkey_url,
		operator_identity_pubkey_fingerprint: $fp,
		key_iat: $iat,
		key_exp: $exp,
		revoked: false,
		revoked_at: null,
		revocation_reason: null,
		verification: {
			method: "ssh-keygen -Y verify",
			minimum_openssh_version: "8.0",
			namespace: $namespace,
			principal: $principal,
			signature_url: "https://metal.freedom-yield.com/api/identity.json.sig"
		},
		generated_at: $generated_at
	}' > "${TMP_JSON}"

# Validate the JSON we just wrote.
jq -e empty "${TMP_JSON}" >/dev/null

# ---- 5. Sign with ssh-keygen -Y sign. ---------------------------------------

# Use the file form: ssh-keygen -Y sign writes to <file>.sig in the same dir.
ssh-keygen -Y sign -f "${OPERATOR_IDENTITY_KEY}" -n "${NAMESPACE}" "${TMP_JSON}" >/dev/null

[[ -f "${TMP_JSON}.sig" ]] || { echo "ERROR: ssh-keygen did not produce ${TMP_JSON}.sig" >&2; exit 2; }

# ---- 6. Self-verify before publishing. --------------------------------------

ALLOWED="$(mktemp -t allowed_signers.XXXXXX)"
trap 'rm -f "${TMP_JSON}" "${TMP_JSON}.sig" "${ALLOWED}"' EXIT
PUB_LINE="$(cat "${OPERATOR_IDENTITY_KEY}.pub")"
printf '%s %s\n' "${PRINCIPAL}" "${PUB_LINE}" > "${ALLOWED}"

if ! ssh-keygen -Y verify \
	-f "${ALLOWED}" \
	-I "${PRINCIPAL}" \
	-n "${NAMESPACE}" \
	-s "${TMP_JSON}.sig" < "${TMP_JSON}"; then
	echo "ERROR: self-verify failed — refusing to publish." >&2
	exit 2
fi

# ---- 7. Atomic publish. -----------------------------------------------------

mv "${TMP_JSON}"     "${OUT_JSON}"
mv "${TMP_JSON}.sig" "${OUT_SIG}"
chmod 644 "${OUT_JSON}" "${OUT_SIG}"
trap - EXIT
rm -f "${ALLOWED}"

echo "✓ wrote ${OUT_JSON}"
echo "✓ wrote ${OUT_SIG}"
echo "  fingerprint: ${FP}"
echo "  namespace:   ${NAMESPACE}"
echo "  principal:   ${PRINCIPAL}"
echo "  iat / exp:   ${KEY_IAT} / ${KEY_EXP}"
echo ""
echo "Next steps (manual):"
echo "  1. If not done yet, copy the public key into the repo:"
echo "       cp ${OPERATOR_IDENTITY_KEY}.pub ${REPO_ROOT}/public/.well-known/operator-identity.pub"
echo "  2. git add public/api/identity.json public/api/identity.json.sig \\"
echo "             public/.well-known/operator-identity.pub"
echo "  3. Review the diff and commit."
echo "  4. After deploy, verify the live URLs with the command in docs/IDENTITY_VERIFICATION.md."
