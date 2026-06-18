#!/usr/bin/env bash
# operator-local/gen-identity.sh
#
# Generate and sign the operator identity manifest for Freedom Yield Metal.
#
# MUST NOT BE RUN ON VALIDATOR HOST OR WEB HOST.
# This helper is for the operator's local Mac only.
# It must never read validator keys, staking keys, BLS keys, signer.key, or staker.key.
#
# Why operator-local/ (not scripts/):
#   scripts/sync-to-validator-host.sh rsyncs scripts/ to the validator host.
#   This helper lives at the repo root under operator-local/ so it is never
#   shipped to the validator host or web host.
#
# What this helper does:
#   1. Composes identity.json from a small set of pinned fields.
#   2. Validates JSON with `jq empty`.
#   3. Detached-signs the JSON with ssh-keygen -Y sign, namespace validator-identity.
#   4. Verifies locally with ssh-keygen -Y verify before publishing.
#   5. Places identity.json and identity.json.sig in public/api/ for commit.
#
# What this helper does NOT do:
#   - It does not generate the ed25519 key. Generate it manually first:
#       ssh-keygen -t ed25519 -f ~/.ssh/freedom-yield-operator-identity \
#                  -C "freedom-yield operator identity"
#     and never commit the private file.
#   - It does not commit anything. Run git status / git add / git commit yourself.
#   - It does not touch /.well-known/operator-identity.pub. Copy the .pub file
#     into public/.well-known/operator-identity.pub manually so the operator
#     reviews exactly which key bytes go public.
#
# Required env:
#   OPERATOR_IDENTITY_KEY   path to the local private ed25519 key (mandatory).
#                           The corresponding .pub file is expected next to it.
#
# Optional env:
#   REPO_ROOT               path to repo (default: parent of this script's dir).
#   NODE_ID                 NodeID string (default: pinned mainnet NodeID).
#   NETWORK                 network label (default: metal-mainnet).
#   SITE                    canonical site URL (default: https://metal.freedom-yield.com/).
#   KEY_IAT                 issued-at ISO-8601 (default: now, UTC).
#   KEY_EXP                 expiry ISO-8601 (default: KEY_IAT + 365 days).
#   PRINCIPAL               allowed-signers principal (default: freedom-yield).
#
# Usage:
#   export OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity
#   bash operator-local/gen-identity.sh

set -euo pipefail

: "${OPERATOR_IDENTITY_KEY:?Set OPERATOR_IDENTITY_KEY to your local private key path}"

if [ ! -f "${OPERATOR_IDENTITY_KEY}" ]; then
  echo "ERROR: private key not found: ${OPERATOR_IDENTITY_KEY}" >&2
  exit 1
fi
if [ ! -f "${OPERATOR_IDENTITY_KEY}.pub" ]; then
  echo "ERROR: public key not found alongside private key: ${OPERATOR_IDENTITY_KEY}.pub" >&2
  exit 1
fi

# Refuse to run on hosts that look like the validator or the web host.
case "$(hostname -s 2>/dev/null || echo)" in
  *validator*|*hetzner*|*xserver*|*web*)
    echo "ERROR: this helper must not run on validator or web hosts" >&2
    echo "  hostname matched a server pattern: $(hostname -s)" >&2
    exit 1
    ;;
esac
if [ -f /etc/freedom-yield/web-host ] || [ -f /etc/freedom-yield/validator-host ]; then
  echo "ERROR: detected operator-host-specific config under /etc/freedom-yield/." >&2
  echo "  This helper must only run on the operator's local Mac." >&2
  exit 1
fi
if [ -d /home/deploy ] && id deploy >/dev/null 2>&1; then
  echo "ERROR: detected 'deploy' user — refusing to run on what looks like a server." >&2
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT_DIR="${REPO_ROOT}/public/api"
OUT_JSON="${OUT_DIR}/identity.json"
OUT_SIG="${OUT_DIR}/identity.json.sig"

[ -d "${OUT_DIR}" ] || { echo "ERROR: ${OUT_DIR} not found — wrong REPO_ROOT?" >&2; exit 1; }

NODE_ID="${NODE_ID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
NETWORK="${NETWORK:-metal-mainnet}"
SITE="${SITE:-https://metal.freedom-yield.com/}"
PRINCIPAL="${PRINCIPAL:-freedom-yield}"
NAMESPACE="validator-identity"

NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
KEY_IAT="${KEY_IAT:-${NOW_UTC}}"
# Default expiry = iat + 365 days, computed cross-platform.
if [ -z "${KEY_EXP:-}" ]; then
  if date -j -v+365d -u +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    KEY_EXP="$(date -j -v+365d -f %Y-%m-%dT%H:%M:%SZ "${KEY_IAT}" -u +%Y-%m-%dT%H:%M:%SZ)"
  else
    KEY_EXP="$(date -u -d "${KEY_IAT} +365 days" +%Y-%m-%dT%H:%M:%SZ)"
  fi
fi

# Compute SHA-256 fingerprint of the public key file (hex, deterministic).
if command -v shasum >/dev/null 2>&1; then
  PUBKEY_FP="$(shasum -a 256 "${OPERATOR_IDENTITY_KEY}.pub" | awk '{print $1}')"
else
  PUBKEY_FP="$(sha256sum "${OPERATOR_IDENTITY_KEY}.pub" | awk '{print $1}')"
fi

TMP_JSON="$(mktemp -t identity.XXXXXX).json"
trap 'rm -f "${TMP_JSON}"' EXIT

jq -n \
  --arg brand "Freedom Yield" \
  --arg node_id "${NODE_ID}" \
  --arg network "${NETWORK}" \
  --arg site "${SITE}" \
  --arg fp "${PUBKEY_FP}" \
  --arg pubkey_url "https://metal.freedom-yield.com/.well-known/operator-identity.pub" \
  --arg iat "${KEY_IAT}" \
  --arg exp "${KEY_EXP}" \
  --arg principal "${PRINCIPAL}" \
  --arg generated_at "${NOW_UTC}" \
  '{
    schema_version: 1,
    brand: $brand,
    node_id: $node_id,
    network: $network,
    site: $site,
    operator_identity_pubkey_fingerprint_sha256: $fp,
    operator_identity_pubkey_url: $pubkey_url,
    key_iat: $iat,
    key_exp: $exp,
    revoked: false,
    verification: {
      method: "ssh-keygen -Y verify",
      namespace: "validator-identity",
      principal: $principal,
      signature_url: "https://metal.freedom-yield.com/api/identity.json.sig"
    },
    generated_at: $generated_at
  }' > "${TMP_JSON}"

jq -e empty "${TMP_JSON}" >/dev/null

# Detached signature with the validator-identity namespace.
SIG_TMP="${TMP_JSON}.sig"
ssh-keygen -Y sign -f "${OPERATOR_IDENTITY_KEY}" -n "${NAMESPACE}" < "${TMP_JSON}" > "${SIG_TMP}"

# Local verification before publishing.
ALLOWED_SIGNERS_TMP="$(mktemp -t allowed_signers.XXXXXX)"
PUB_CONTENT="$(cat "${OPERATOR_IDENTITY_KEY}.pub")"
printf '%s %s\n' "${PRINCIPAL}" "${PUB_CONTENT}" > "${ALLOWED_SIGNERS_TMP}"
if ! ssh-keygen -Y verify \
      -f "${ALLOWED_SIGNERS_TMP}" \
      -I "${PRINCIPAL}" \
      -n "${NAMESPACE}" \
      -s "${SIG_TMP}" < "${TMP_JSON}"; then
  echo "ERROR: local ssh-keygen -Y verify failed — refusing to publish." >&2
  rm -f "${ALLOWED_SIGNERS_TMP}" "${SIG_TMP}"
  exit 2
fi
rm -f "${ALLOWED_SIGNERS_TMP}"

# Publish to the repo.
mv "${TMP_JSON}" "${OUT_JSON}"
mv "${SIG_TMP}" "${OUT_SIG}"
trap - EXIT

echo "✓ wrote ${OUT_JSON}"
echo "✓ wrote ${OUT_SIG}"
echo ""
echo "Next steps (manual):"
echo "  1. Copy your public key into public/.well-known/operator-identity.pub:"
echo "       cp ${OPERATOR_IDENTITY_KEY}.pub ${REPO_ROOT}/public/.well-known/operator-identity.pub"
echo "  2. git add public/api/identity.json public/api/identity.json.sig public/.well-known/operator-identity.pub"
echo "  3. Review the diff and commit."
echo "  4. After deploy, verify the live URLs with the command in docs/IDENTITY_VERIFICATION.md."
