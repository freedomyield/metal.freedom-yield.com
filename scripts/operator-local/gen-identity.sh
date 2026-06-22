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

# Hostname guard. Match production-shaped hostnames by role / lifecycle,
# not by provider-name. Defense in depth: the filesystem + deploy-user
# guards below catch hosts whose hostnames do not match these patterns.
HN="$(hostname -s 2>/dev/null || hostname)"
case "$HN" in
	*validator*|*web*|*-prod*|*deploy*)
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
# ID_HISTORY_FILE is referenced from §2 (KEY_IAT / KEY_EXP resolution),
# §3.6 (Merkle DAG branch building + bootstrap path), and §5-prime
# (self-check before signing). Single source of truth here.
ID_HISTORY_FILE="${OUT_DIR}/identity-history.jsonl"

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

# ---- 3. Compute the SHA256:base64 SSH fingerprint. --------------------------
# ssh-keygen -l -f <pub> emits:  "<bits> SHA256:<base64> <comment> (ED25519)"
# This block was moved up from after §2 (= where it sat in the original
# layout) so the fingerprint is available to the §2 KEY_IAT / KEY_EXP
# ledger-lookup logic below. Early format validation also catches a
# corrupt pubkey before the ledger lookup runs (which uses ${FP}).
FP_LINE="$(ssh-keygen -l -f "${OPERATOR_IDENTITY_KEY}.pub")"
FP="$(printf '%s\n' "${FP_LINE}" | awk '{print $2}')"
case "${FP}" in
	SHA256:*) ;;
	*)
		echo "ERROR: unexpected fingerprint format from ssh-keygen -l: ${FP_LINE}" >&2
		exit 1
		;;
esac

# ---- 2.5. Resolve KEY_IAT / KEY_EXP from the ledger. ------------------------
# Semantics: key_iat = "issued at *the key*", NOT "manifest reissue moment".
# Therefore on a regeneration the value must come from the existing ledger
# entry for this exact pubkey, not from the regen wallclock. This fixes the
# HIGH-1 finding from the 2026-06-22 audit (= identity.json.key_iat drifted
# on every gen-identity.sh re-run, diverging from identity-history.jsonl).
#
# Resolution order: explicit env override > ledger match > NOW_UTC.
#   - env override: operator-forced (e.g. genuine key rotation prep).
#   - ledger match: pubkey matches a non-revoked entry; reuse its key_iat
#     and key_exp byte-for-byte so the manifest cannot diverge from the
#     ledger.
#   - NOW_UTC: first-time bootstrap, OR a genuinely new key whose entry
#     is about to be appended to the ledger (= rotation case).
LEDGER_KEY_IAT=""
LEDGER_KEY_EXP=""
if [ -f "${ID_HISTORY_FILE}" ]; then
	# Find the latest non-revoked ledger entry whose fingerprint matches.
	# `-R` reads the file line-by-line as raw strings, `(fromjson? // empty)`
	# parses each line and silently skips malformed JSONL lines (= the
	# robustness improvement requested by re-audit F4; without this, jq
	# dies on the first parse error and the lookup falls through to
	# NOW_UTC, where the §4.5 self-check then refuses to sign as a safe
	# fail-loud). `tail -n 1` handles the (out-of-spec) case where multiple
	# active entries share the same fingerprint by preferring the most recent.
	LEDGER_MATCH="$(jq -Rc --arg fp "${FP}" '
		(fromjson? // empty)
		| select(.revoked == false and .operator_identity_pubkey_fingerprint == $fp)
	' "${ID_HISTORY_FILE}" 2>/dev/null | tail -n 1)"
	if [ -n "${LEDGER_MATCH}" ]; then
		LEDGER_KEY_IAT="$(printf '%s' "${LEDGER_MATCH}" | jq -r '.key_iat // empty')"
		LEDGER_KEY_EXP="$(printf '%s' "${LEDGER_MATCH}" | jq -r '.key_exp // empty')"
	fi
fi

KEY_IAT="${KEY_IAT:-${LEDGER_KEY_IAT:-${NOW_UTC}}}"
if [[ -z "${KEY_EXP:-}" ]]; then
	if [ -n "${LEDGER_KEY_EXP}" ] && [ "${KEY_IAT}" = "${LEDGER_KEY_IAT}" ]; then
		# Reuse ledger's key_exp verbatim — guarantees byte-for-byte
		# identity with the published identity-history.jsonl entry.
		KEY_EXP="${LEDGER_KEY_EXP}"
	# LC_ALL=C forces POSIX locale so date does not emit a localized fallback
	# (= ja_JP would emit "2027年 6月22日 火曜日 ..." if the explicit +fmt
	# is not applied for any reason). -u placed BEFORE -f because macOS BSD
	# date treats -u as an option flag that must precede positional args.
	elif LC_ALL=C date -u -j -v+365d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
		# BSD date (macOS).
		KEY_EXP="$(LC_ALL=C date -u -j -v+365d -f "%Y-%m-%dT%H:%M:%SZ" "${KEY_IAT}" +%Y-%m-%dT%H:%M:%SZ)"
	else
		# GNU date (Linux).
		KEY_EXP="$(LC_ALL=C date -u -d "${KEY_IAT} +365 days" +%Y-%m-%dT%H:%M:%SZ)"
	fi
fi

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

# ---- 3.6. Build Merkle DAG branch roots + dag_root_hash + cycles-history.json
#
# Per docs/MERKLE_DAG_SPEC.md §2-§5. Reuses the compute_merkle_root function
# defined above (= identical algorithm; bit-for-bit equivalent to the Python
# reference at tests/identity-verification-vectors/generate.py).
#
# Inputs (= published JSONL leaf sources):
#   /api/identity-history.jsonl   bootstrapped here if absent in repo (= first
#                                 Phase α run); maintained as append-only
#                                 afterwards by the operator (key rotations).
#   /api/cycle-history.jsonl      fetched from ARTIFACT_BASE; absent ⇒ treat
#                                 the cycles branch as empty (= sentinel root).
#
# Outputs:
#   identity_branch_root, cycles_branch_root, dag_root_hash (= 64-hex each).
#   /api/cycles-history.json (= DAG summary, written here in OUT_DIR).
#   Additive fields in identity.json (= composed in §4 below).

NULL_BRANCH_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# Bootstrap identity-history.jsonl if absent (= first Phase α run).
# (ID_HISTORY_FILE is defined once at the top of the script alongside
# OUT_JSON / OUT_SIG; see §2.)
if [ ! -f "${ID_HISTORY_FILE}" ]; then
	echo "  bootstrap: ${ID_HISTORY_FILE} not present; writing key_seq=1 line" >&2
	# Single canonical line via jq -c (compact + sorted not enforced; the
	# bytes published here become the leaf forever, so any subsequent
	# re-format would break verification — operator MUST treat this file
	# as byte-for-byte append-only after the bootstrap commit).
	jq -nc \
		--arg fp        "${FP}" \
		--arg pub_url   "https://metal.freedom-yield.com/.well-known/operator-identity.pub" \
		--arg iat       "${KEY_IAT}" \
		--arg exp       "${KEY_EXP}" \
		'{
			schema_version: 1,
			key_seq: 1,
			operator_identity_pubkey_fingerprint: $fp,
			operator_identity_pubkey_url: $pub_url,
			key_iat: $iat,
			key_exp: $exp,
			revoked: false,
			revoked_at: null,
			revocation_reason: null,
			superseded_by_key_seq: null,
			comment: "initial Phase α operator identity key — bootstrapped by gen-identity.sh"
		}' > "${ID_HISTORY_FILE}"
	echo "  IMPORTANT: review ${ID_HISTORY_FILE} and git add it alongside identity.json." >&2
fi

# Per-line leaf hashes (= SHA-256 of each non-empty published line, including
# the trailing '\n' that separates it from the next line; matches the spec's
# rule that we hash the bytes "as served"). Uses portable shell only —
# `printf '%s\n' "$line"` reproduces the publication form (= line + LF) when
# the file is emitted by `printf '%s\n'` or `jq -c` followed by a newline,
# which is the convention here and in gen-cycle-history.sh.
jsonl_leaves_from_file() {
	local file="$1" line
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		printf '%s\n' "${line}" | sha256_of_stdin
	done < "${file}"
}

# Identity branch.
ID_LEAVES_TMP="$(mktemp -t id_leaves.XXXXXX)"
jsonl_leaves_from_file "${ID_HISTORY_FILE}" > "${ID_LEAVES_TMP}"
ID_LEAF_COUNT="$(wc -l < "${ID_LEAVES_TMP}" | tr -d ' ')"
if [ "${ID_LEAF_COUNT}" -eq 0 ]; then
	IDENTITY_BRANCH_ROOT="${NULL_BRANCH_HASH}"
else
	IDENTITY_BRANCH_ROOT="$(cat "${ID_LEAVES_TMP}" | compute_merkle_root)"
fi
rm -f "${ID_LEAVES_TMP}"

ID_SHA="$(sha256_of_stdin < "${ID_HISTORY_FILE}")"

# Cycles branch — fetch /api/cycle-history.jsonl from the published web host.
CY_BODY_TMP="$(mktemp -t cy_body.XXXXXX)"
CY_URL="${ARTIFACT_BASE}/api/cycle-history.jsonl"
CY_CODE="$(curl -sSLI -o /dev/null -w "%{http_code}" "${CY_URL}")"
if [ "${CY_CODE}" = "200" ] && curl -sSLf -o "${CY_BODY_TMP}" "${CY_URL}"; then
	CY_LEAVES_TMP="$(mktemp -t cy_leaves.XXXXXX)"
	jsonl_leaves_from_file "${CY_BODY_TMP}" > "${CY_LEAVES_TMP}"
	CY_LEAF_COUNT="$(wc -l < "${CY_LEAVES_TMP}" | tr -d ' ')"
	if [ "${CY_LEAF_COUNT}" -eq 0 ]; then
		CYCLES_BRANCH_ROOT="${NULL_BRANCH_HASH}"
	else
		CYCLES_BRANCH_ROOT="$(cat "${CY_LEAVES_TMP}" | compute_merkle_root)"
	fi
	rm -f "${CY_LEAVES_TMP}"
	CY_SHA="$(sha256_of_stdin < "${CY_BODY_TMP}")"
else
	echo "  warn: ${CY_URL} not live (HTTP ${CY_CODE}); cycles branch treated as empty" >&2
	CYCLES_BRANCH_ROOT="${NULL_BRANCH_HASH}"
	CY_LEAF_COUNT=0
	CY_SHA=""
fi
rm -f "${CY_BODY_TMP}"

# DAG root = SHA-256( raw(id_root) || raw(cy_root) ).
DAG_ROOT_HASH="$(
	{ printf '%s' "${IDENTITY_BRANCH_ROOT}" | xxd -r -p
	  printf '%s' "${CYCLES_BRANCH_ROOT}"   | xxd -r -p
	} | sha256_of_stdin
)"
case "${DAG_ROOT_HASH}" in
	*[!a-f0-9]*|"") echo "ERROR: computed dag_root_hash is not 64-hex: ${DAG_ROOT_HASH}" >&2; exit 4 ;;
esac
if [ "${#DAG_ROOT_HASH}" -ne 64 ]; then
	echo "ERROR: computed dag_root_hash is not 64 chars: ${DAG_ROOT_HASH}" >&2; exit 4
fi

# Write cycles-history.json (DAG snapshot).
OUT_CYCLES_HISTORY="${OUT_DIR}/cycles-history.json"
TMP_CYCLES="$(mktemp -t cycleshistory.XXXXXX)"
jq -n \
	--arg dag_root_hash "${DAG_ROOT_HASH}" \
	--arg id_url        "https://metal.freedom-yield.com/api/identity-history.jsonl" \
	--arg id_sha        "${ID_SHA}" \
	--arg id_schema     "https://metal.freedom-yield.com/api/identity-history.schema.v1.json" \
	--argjson id_count  "${ID_LEAF_COUNT}" \
	--arg id_root       "${IDENTITY_BRANCH_ROOT}" \
	--arg cy_url        "${ARTIFACT_BASE}/api/cycle-history.jsonl" \
	--arg cy_sha        "${CY_SHA}" \
	--arg cy_schema     "https://metal.freedom-yield.com/api/cycle-history.schema.v1.json" \
	--argjson cy_count  "${CY_LEAF_COUNT}" \
	--arg cy_root       "${CYCLES_BRANCH_ROOT}" \
	--arg identity_url  "https://metal.freedom-yield.com/api/identity.json" \
	--arg receipt_url   "https://metal.freedom-yield.com/api/anchor-receipt.json" \
	--arg generated_at  "${NOW_UTC}" \
	'{
		_comment: "Merkle DAG snapshot generated by scripts/operator-local/gen-identity.sh per docs/MERKLE_DAG_SPEC.md.",
		"$schema": "https://metal.freedom-yield.com/api/cycles-history.schema.v1.json",
		schema_version: 1,
		dag_root_hash: $dag_root_hash,
		branches: {
			identity: ({
				leaf_source_url: $id_url,
				leaf_source_sha256: $id_sha,
				leaf_source_schema_url: $id_schema,
				leaf_count: $id_count,
				branch_root: $id_root
			}),
			cycles: ({
				leaf_source_url: $cy_url,
				leaf_source_sha256: $cy_sha,
				leaf_source_schema_url: $cy_schema,
				leaf_count: $cy_count,
				branch_root: $cy_root
			})
		},
		anchor_receipt_url: $receipt_url,
		identity_url: $identity_url,
		generated_at: $generated_at
	}' > "${TMP_CYCLES}"
jq empty "${TMP_CYCLES}" >/dev/null
mv "${TMP_CYCLES}" "${OUT_CYCLES_HISTORY}"
chmod 644 "${OUT_CYCLES_HISTORY}"

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
	--arg dag_root_hash "${DAG_ROOT_HASH}" \
	--arg cycles_history_url "https://metal.freedom-yield.com/api/cycles-history.json" \
	--arg anchor_receipt_url "https://metal.freedom-yield.com/api/anchor-receipt.json" \
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
		dag_root_hash: $dag_root_hash,
		cycles_history_url: $cycles_history_url,
		anchor_receipt_url: $anchor_receipt_url,
		generated_at: $generated_at
	}' > "${TMP_JSON}"

# Validate the JSON we just wrote. (`jq empty` exits 0 on valid parse, non-zero
# on parse error. Do NOT use `jq -e empty` — the `empty` filter produces no
# output, and `-e` reads that as "no result" and returns exit code 4.)
jq empty "${TMP_JSON}" >/dev/null

# ---- 4.5. Self-check: payload must not diverge from the ledger. -------------
# Defense-in-depth gate against the HIGH-1 finding from the 2026-06-22 audit
# (= KEY_IAT silently re-derived from NOW_UTC on non-rotation regen,
# producing an identity.json whose key_iat disagreed with the published
# identity-history.jsonl). If §2 / §2.5 ever regress, this gate catches it
# before the signature is produced rather than after publication.
#
# Outcomes:
#   - ledger has an active entry for ${FP} and its key_iat matches: pass
#   - ledger has no active entry for ${FP}: pass (= rotation / bootstrap)
#   - ledger has an active entry but its key_iat ≠ ${KEY_IAT}: refuse
if [ -f "${ID_HISTORY_FILE}" ]; then
	LEDGER_ACTIVE_IAT="$(jq -Rr --arg fp "${FP}" '
		(fromjson? // empty)
		| select(.revoked == false and .operator_identity_pubkey_fingerprint == $fp)
		| .key_iat
	' "${ID_HISTORY_FILE}" 2>/dev/null | tail -n 1)"
	if [ -n "${LEDGER_ACTIVE_IAT}" ] && [ "${KEY_IAT}" != "${LEDGER_ACTIVE_IAT}" ]; then
		echo "ERROR: KEY_IAT=${KEY_IAT} diverges from ledger active entry for ${FP}:" >&2
		echo "       ledger says key_iat=${LEDGER_ACTIVE_IAT}" >&2
		echo "       Refusing to sign — this would reproduce the HIGH-1 divergence." >&2
		echo "       To proceed with a genuine rotation, append a new key_seq=N+1" >&2
		echo "       entry to ${ID_HISTORY_FILE} first (and supersede the old)." >&2
		echo "       To force-override without a rotation, run with explicit" >&2
		echo "       KEY_IAT=<value> matching your intent." >&2
		exit 8
	fi
fi

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
echo "✓ wrote ${OUT_CYCLES_HISTORY}"
echo "  fingerprint:          ${FP}"
echo "  namespace:            ${NAMESPACE}"
echo "  principal:            ${PRINCIPAL}"
echo "  iat / exp:            ${KEY_IAT} / ${KEY_EXP}"
echo "  artifact leaves:      ${LEAF_COUNT}"
echo "  artifact_root:        ${ARTIFACT_ROOT}"
echo "  identity_branch_root: ${IDENTITY_BRANCH_ROOT} (${ID_LEAF_COUNT} leaves)"
echo "  cycles_branch_root:   ${CYCLES_BRANCH_ROOT} (${CY_LEAF_COUNT} leaves)"
echo "  dag_root_hash:        ${DAG_ROOT_HASH}"
echo "  anchor memo:          fyid1:${DAG_ROOT_HASH}"
echo ""
echo "Next steps (manual):"
echo "  1. If not done yet, copy the public key into the repo:"
echo "       cp ${OPERATOR_IDENTITY_KEY}.pub ${REPO_ROOT}/public/.well-known/operator-identity.pub"
echo "  2. Stage all five files produced by this run + the .pub copy."
echo "     Phase α requires cycles-history.json + identity-history.jsonl"
echo "     on the live web (deploy ownership matrix + verifier branch root recompute)."
echo "       git add public/api/identity.json \\"
echo "               public/api/identity.json.sig \\"
echo "               public/api/cycles-history.json \\"
echo "               public/api/identity-history.jsonl \\"
echo "               public/.well-known/operator-identity.pub"
echo "  3. Review the diff and commit."
echo "  4. After deploy, verify the live URLs with the command in docs/IDENTITY_VERIFICATION.md."
echo ""
echo "⚠ HOLD reminder: per project_merkle_dag_identity_anchor_design memory,"
echo "  identity.json + .sig + cycles-history.json + identity-history.jsonl"
echo "  + operator-identity.pub publish (git add / commit) is gated on"
echo "  Task #28 cron auto-fire PASS + Task #25 D11 Phase 3."
echo "  Do not commit these files until both gates clear."
