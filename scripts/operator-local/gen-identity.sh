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
#   1. Probes each artifact URL (curl) and computes content sha256.
#   2. Computes the SHA-256 Merkle root over the artifact_manifest leaves
#      (alphabetical key order, odd-duplicate, raw-bytes binary tree —
#      matches the algorithm documented in identity.schema.v1.json).
#   3. Composes identity.json with artifact_manifest + artifact_root.
#   4. Validates JSON with `jq empty`.
#   5. Signs with `ssh-keygen -Y sign` using namespace freedom-yield/validator-identity.
#   6. Self-verifies with `ssh-keygen -Y verify` before publishing.
#   7. Atomically places identity.json and identity.json.sig in public/api/.
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
#   ARTIFACT_BASE           URL prefix for leaf artifacts (default:
#                           https://metal.freedom-yield.com).
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

# ---- 1.5. Retired env guard. -----------------------------------------------
#
# The CHAIN_ANCHOR_TX_ID and CHAIN_ANCHOR_EXPLORER environment variables
# were retired 2026-06-20 when the P-Chain memo anchor model was abandoned
# (the current Avalanche / Metal protocol rules forbid non-empty memos on
# AddPermissionlessValidatorTx). See docs/IDENTITY_SCHEMA_CHANGELOG.md.
#
# If either variable is set in the environment when gen-identity.sh is
# invoked, the operator's mental model still expects an anchored output.
# Continuing silently would risk publishing a manifest under a misperceived
# shape. Halt before any output is produced and ask the operator to unset
# the retired variables.
for retired_env in CHAIN_ANCHOR_TX_ID CHAIN_ANCHOR_EXPLORER; do
	if [ -n "${!retired_env:-}" ]; then
		echo "ERROR: ${retired_env} is set but was retired 2026-06-20." >&2
		echo "       The P-Chain memo anchor model was abandoned because the" >&2
		echo "       current protocol rules forbid non-empty memos on" >&2
		echo "       AddPermissionlessValidatorTx. See" >&2
		echo "       docs/IDENTITY_SCHEMA_CHANGELOG.md. To proceed:" >&2
		echo "         unset CHAIN_ANCHOR_TX_ID CHAIN_ANCHOR_EXPLORER" >&2
		echo "       then re-run." >&2
		exit 6
	fi
done

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

# ---- 3.5. Build artifact_manifest + artifact_root. --------------------------
#
# Probe each leaf artifact + its companion schema (where applicable). Skip
# 4xx/5xx leaves (e.g., cycle-history.jsonl is HOLD until Task #28 / D10 gate
# clears) — they will be picked up automatically once they go live, and the
# Merkle root will change accordingly.

ARTIFACT_BASE="${ARTIFACT_BASE:-https://metal.freedom-yield.com}"

# Portable sha256: macOS ships `shasum`, Linux usually ships both; prefer
# `shasum -a 256` for cross-platform behaviour.
sha256_of_stdin() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		echo "ERROR: neither shasum nor sha256sum is installed" >&2
		exit 1
	fi
}

# Merkle root over hex sha256 leaves read from stdin (one per line, already
# in the desired alphabetical-key order). Output: 64-hex root on stdout.
#
# Convention (must match identity.schema.v1.json description and
# docs/IDENTITY_VERIFICATION.md Step 6):
#   - odd counts duplicate the LAST leaf at each level
#   - parent = SHA-256( raw_bytes(left) || raw_bytes(right) )
#   - single-leaf input returns that leaf unchanged
compute_merkle_root() {
	local cur nxt left right parent count
	cur="$(mktemp -t merkle.XXXXXX)"
	nxt="$(mktemp -t merkle.XXXXXX)"
	cat > "${cur}"

	count="$(wc -l < "${cur}" | tr -d ' ')"
	if [ "${count}" -eq 0 ]; then
		rm -f "${cur}" "${nxt}"
		echo "ERROR: compute_merkle_root received no leaves on stdin" >&2
		return 1
	fi

	while [ "${count}" -gt 1 ]; do
		# Duplicate last leaf if odd.
		if [ $((count % 2)) -eq 1 ]; then
			tail -n 1 "${cur}" >> "${cur}"
		fi

		: > "${nxt}"
		while IFS= read -r left && IFS= read -r right; do
			parent="$(
				{ printf '%s' "${left}"  | xxd -r -p
				  printf '%s' "${right}" | xxd -r -p
				} | sha256_of_stdin
			)"
			printf '%s\n' "${parent}" >> "${nxt}"
		done < "${cur}"

		mv "${nxt}" "${cur}"
		nxt="$(mktemp -t merkle.XXXXXX)"
		count="$(wc -l < "${cur}" | tr -d ' ')"
	done

	cat "${cur}"
	rm -f "${cur}" "${nxt}"
}

# Leaf catalog: <key>|<url>|<schema_url>
# Empty <schema_url> = no formal schema yet (manifest entry without schema_url
# is honest about that state; see identity.schema.v1.json artifact_manifest
# description "(where applicable)").
LEAF_CATALOG="evidence_json|${ARTIFACT_BASE}/api/evidence.json|${ARTIFACT_BASE}/api/evidence.schema.v1.json
validator_json|${ARTIFACT_BASE}/api/validator.json|${ARTIFACT_BASE}/api/validator.schema.v1.json
cycle_history_jsonl|${ARTIFACT_BASE}/api/cycle-history.jsonl|${ARTIFACT_BASE}/api/cycle-history.schema.v1.json
uptime_cycles_json|${ARTIFACT_BASE}/api/uptime-cycles.json|
incidents_json|${ARTIFACT_BASE}/api/incidents.json|"

LEAVES_TMP="$(mktemp -t leaves.XXXXXX)"      # sorted leaf body
MANIFEST_TMP="$(mktemp -t manifest.XXXXXX)"  # incremental manifest JSON
printf '%s' '{}' > "${MANIFEST_TMP}"

while IFS='|' read -r LEAF_KEY LEAF_URL LEAF_SCHEMA_URL; do
	[ -z "${LEAF_KEY}" ] && continue

	# Probe leaf URL.
	LEAF_CODE="$(curl -sSLI -o /dev/null -w "%{http_code}" "${LEAF_URL}")"
	if [ "${LEAF_CODE}" != "200" ]; then
		echo "  skip ${LEAF_KEY}: HTTP ${LEAF_CODE} at ${LEAF_URL}" >&2
		continue
	fi

	# Fetch + sha256 of leaf body.
	LEAF_BODY="$(mktemp -t leaf.XXXXXX)"
	if ! curl -sSLf -o "${LEAF_BODY}" "${LEAF_URL}"; then
		rm -f "${LEAF_BODY}"
		echo "  skip ${LEAF_KEY}: fetch failed at ${LEAF_URL}" >&2
		continue
	fi
	LEAF_SHA="$(sha256_of_stdin < "${LEAF_BODY}")"
	rm -f "${LEAF_BODY}"

	# Optional schema probe + sha256.
	LEAF_SCHEMA_SHA=""
	if [ -n "${LEAF_SCHEMA_URL}" ]; then
		SCHEMA_CODE="$(curl -sSLI -o /dev/null -w "%{http_code}" "${LEAF_SCHEMA_URL}")"
		if [ "${SCHEMA_CODE}" = "200" ]; then
			SCHEMA_BODY="$(mktemp -t schema.XXXXXX)"
			curl -sSLf -o "${SCHEMA_BODY}" "${LEAF_SCHEMA_URL}"
			LEAF_SCHEMA_SHA="$(sha256_of_stdin < "${SCHEMA_BODY}")"
			rm -f "${SCHEMA_BODY}"
		else
			echo "  warn ${LEAF_KEY}: schema URL HTTP ${SCHEMA_CODE}; dropping schema fields for this leaf" >&2
			LEAF_SCHEMA_URL=""
		fi
	fi

	# Record sorted leaf line (key + sha256), and merge into manifest JSON.
	printf '%s\t%s\n' "${LEAF_KEY}" "${LEAF_SHA}" >> "${LEAVES_TMP}"

	if [ -n "${LEAF_SCHEMA_URL}" ]; then
		jq --arg key "${LEAF_KEY}" \
		   --arg url "${LEAF_URL}" \
		   --arg sha "${LEAF_SHA}" \
		   --arg surl "${LEAF_SCHEMA_URL}" \
		   --arg ssha "${LEAF_SCHEMA_SHA}" \
		   '.[$key] = {url: $url, sha256: $sha, schema_url: $surl, schema_sha256: $ssha}' \
		   "${MANIFEST_TMP}" > "${MANIFEST_TMP}.next"
	else
		jq --arg key "${LEAF_KEY}" \
		   --arg url "${LEAF_URL}" \
		   --arg sha "${LEAF_SHA}" \
		   '.[$key] = {url: $url, sha256: $sha}' \
		   "${MANIFEST_TMP}" > "${MANIFEST_TMP}.next"
	fi
	mv "${MANIFEST_TMP}.next" "${MANIFEST_TMP}"
done <<EOF
${LEAF_CATALOG}
EOF

# Require at least one leaf so the Merkle tree is well-defined.
if [ ! -s "${LEAVES_TMP}" ]; then
	echo "ERROR: no live leaves found at ${ARTIFACT_BASE}/api/* — refusing to publish empty artifact_manifest." >&2
	rm -f "${LEAVES_TMP}" "${MANIFEST_TMP}"
	exit 3
fi

# Merkle root over leaves sorted alphabetically by key.
ARTIFACT_ROOT="$(sort -t '	' -k1,1 "${LEAVES_TMP}" | awk -F'\t' '{print $2}' | compute_merkle_root)"
case "${ARTIFACT_ROOT}" in
	*[!a-f0-9]*|"") echo "ERROR: computed artifact_root is not 64-hex: ${ARTIFACT_ROOT}" >&2; exit 4 ;;
esac
if [ "${#ARTIFACT_ROOT}" -ne 64 ]; then
	echo "ERROR: computed artifact_root is not 64 chars: ${ARTIFACT_ROOT}" >&2
	exit 4
fi

ARTIFACT_MANIFEST_JSON="$(cat "${MANIFEST_TMP}")"
rm -f "${LEAVES_TMP}" "${MANIFEST_TMP}"

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
	--argjson artifact_manifest "${ARTIFACT_MANIFEST_JSON}" \
	--arg artifact_root "${ARTIFACT_ROOT}" \
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
		artifact_manifest: $artifact_manifest,
		artifact_root: $artifact_root,
		generated_at: $generated_at
	}' > "${TMP_JSON}"

# Validate the JSON we just wrote. (`jq empty` exits 0 on valid parse, non-zero
# on parse error. Do NOT use `jq -e empty` — the `empty` filter produces no
# output, and `-e` reads that as "no result" and returns exit code 4.)
jq empty "${TMP_JSON}" >/dev/null

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

LEAF_COUNT="$(jq -r '.artifact_manifest | length' "${OUT_JSON}")"

echo "✓ wrote ${OUT_JSON}"
echo "✓ wrote ${OUT_SIG}"
echo "  fingerprint:     ${FP}"
echo "  namespace:       ${NAMESPACE}"
echo "  principal:       ${PRINCIPAL}"
echo "  iat / exp:       ${KEY_IAT} / ${KEY_EXP}"
echo "  leaves bound:    ${LEAF_COUNT}"
echo "  artifact_root:   ${ARTIFACT_ROOT}"
echo ""
echo "Next steps (manual):"
echo "  1. If not done yet, copy the public key into the repo:"
echo "       cp ${OPERATOR_IDENTITY_KEY}.pub ${REPO_ROOT}/public/.well-known/operator-identity.pub"
echo "  2. git add public/api/identity.json public/api/identity.json.sig \\"
echo "             public/.well-known/operator-identity.pub"
echo "  3. Review the diff and commit."
echo "  4. After deploy, verify the live URLs with the command in docs/IDENTITY_VERIFICATION.md."
echo ""
echo "⚠ HOLD reminder: per project_merkle_dag_identity_anchor_design memory,"
echo "  identity.json + .sig + operator-identity.pub publish (git add / commit)"
echo "  is gated on Task #28 cron auto-fire PASS + Task #25 D11 Phase 3."
echo "  Do not commit these files until both gates clear."
