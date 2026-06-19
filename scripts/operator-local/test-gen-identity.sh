#!/usr/bin/env bash
# scripts/operator-local/test-gen-identity.sh
#
# Synthetic-key test harness for gen-identity.sh.
#
# Generates a throwaway ed25519 key in a tmp dir, runs gen-identity.sh against
# a fake REPO_ROOT skeleton, then independently re-verifies the artifact_root
# the script computed. Used to confirm Phase 3 Merkle DAG logic is correct
# WITHOUT touching the real operator identity key or the real repo's
# public/api/identity.json.
#
# Why this exists:
#   - Phase 3 (Merkle DAG computation) must be testable now, but the real
#     operator identity key (Task #25 / D11 Phase 3) is still HOLD pending
#     Task #28 cron auto-fire confirmation.
#   - Producing a real signed identity.json here would risk leaking
#     synthetic-key-signed bytes into public/api/.
#   - This harness routes everything through /tmp and prints PASS/FAIL only.
#
# Usage:
#   bash scripts/operator-local/test-gen-identity.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_REPO="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TEST_ROOT="$(mktemp -d -t fy-test-gen-identity.XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

# 1. Synthetic ed25519 key in tmp.
SYN_KEY="${TEST_ROOT}/synthetic-operator-key"
ssh-keygen -t ed25519 -N "" -C "synthetic-test-key DO-NOT-USE" -f "${SYN_KEY}" -q

# 2. Fake REPO_ROOT skeleton: just an empty public/api/ dir is enough.
FAKE_REPO="${TEST_ROOT}/fake-repo"
mkdir -p "${FAKE_REPO}/public/api"

# 3. Run gen-identity.sh against the fake repo + synthetic key.
echo "=== running gen-identity.sh against synthetic key + fake repo ==="
OPERATOR_IDENTITY_KEY="${SYN_KEY}" \
REPO_ROOT="${FAKE_REPO}" \
KEY_IAT="2026-06-19T00:00:00Z" \
KEY_EXP="2027-06-19T00:00:00Z" \
bash "${SCRIPT_DIR}/gen-identity.sh"

OUT_JSON="${FAKE_REPO}/public/api/identity.json"
OUT_SIG="${FAKE_REPO}/public/api/identity.json.sig"

if [ ! -f "${OUT_JSON}" ] || [ ! -f "${OUT_SIG}" ]; then
	echo "FAIL: gen-identity.sh did not produce both output files" >&2
	exit 1
fi

# 4. Independently re-fetch each leaf in the manifest and re-hash.
echo
echo "=== independent re-hash of each leaf in artifact_manifest ==="
HAS_ERROR=0
KEYS="$(jq -r '.artifact_manifest | keys[]' "${OUT_JSON}" | sort)"
for k in ${KEYS}; do
	url="$(jq -r --arg k "${k}" '.artifact_manifest[$k].url' "${OUT_JSON}")"
	claimed_sha="$(jq -r --arg k "${k}" '.artifact_manifest[$k].sha256' "${OUT_JSON}")"
	actual_sha="$(curl -sSLf "${url}" | shasum -a 256 | awk '{print $1}')"
	if [ "${claimed_sha}" = "${actual_sha}" ]; then
		echo "  OK   ${k}  sha256=${claimed_sha:0:16}…"
	else
		echo "  FAIL ${k}  claimed=${claimed_sha}  actual=${actual_sha}" >&2
		HAS_ERROR=1
	fi
done

# 5. Independently recompute Merkle root and compare.
echo
echo "=== independent Merkle root recompute ==="
INDEP_LEAVES="$(mktemp -t indep-leaves.XXXXXX)"
jq -r '.artifact_manifest | to_entries | sort_by(.key) | .[] | "\(.key)\t\(.value.sha256)"' "${OUT_JSON}" \
	> "${INDEP_LEAVES}"

merkle_root_independent() {
	local cur nxt left right parent count
	cur="$(mktemp -t indep-merkle.XXXXXX)"
	awk -F'\t' '{print $2}' "${INDEP_LEAVES}" > "${cur}"
	count="$(wc -l < "${cur}" | tr -d ' ')"
	while [ "${count}" -gt 1 ]; do
		if [ $((count % 2)) -eq 1 ]; then
			tail -n 1 "${cur}" >> "${cur}"
		fi
		nxt="$(mktemp -t indep-merkle.XXXXXX)"
		while IFS= read -r left && IFS= read -r right; do
			parent="$(
				{ printf '%s' "${left}"  | xxd -r -p
				  printf '%s' "${right}" | xxd -r -p
				} | shasum -a 256 | awk '{print $1}'
			)"
			printf '%s\n' "${parent}" >> "${nxt}"
		done < "${cur}"
		mv "${nxt}" "${cur}"
		count="$(wc -l < "${cur}" | tr -d ' ')"
	done
	cat "${cur}"
	rm -f "${cur}"
}

INDEP_ROOT="$(merkle_root_independent)"
CLAIMED_ROOT="$(jq -r '.artifact_root' "${OUT_JSON}")"

if [ "${INDEP_ROOT}" = "${CLAIMED_ROOT}" ]; then
	echo "  OK   artifact_root matches: ${CLAIMED_ROOT}"
else
	echo "  FAIL artifact_root mismatch" >&2
	echo "       script-claimed:   ${CLAIMED_ROOT}" >&2
	echo "       independent calc: ${INDEP_ROOT}" >&2
	HAS_ERROR=1
fi
rm -f "${INDEP_LEAVES}"

# 6. ssh-keygen -Y verify against synthetic pubkey.
echo
echo "=== ssh-keygen -Y verify against synthetic key ==="
ALLOWED="$(mktemp -t allowed.XXXXXX)"
printf 'freedom-yield %s\n' "$(cat "${SYN_KEY}.pub")" > "${ALLOWED}"
if ssh-keygen -Y verify \
		-f "${ALLOWED}" \
		-I "freedom-yield" \
		-n "freedom-yield/validator-identity" \
		-s "${OUT_SIG}" < "${OUT_JSON}" >/dev/null 2>&1; then
	echo "  OK   signature verifies against synthetic pubkey"
else
	echo "  FAIL signature verify against synthetic pubkey" >&2
	HAS_ERROR=1
fi
rm -f "${ALLOWED}"

# 7. Validate output against the live identity schema v1 (ajv if available).
echo
echo "=== schema validation against live identity.schema.v1.json ==="
SCHEMA_TMP="$(mktemp -t identity-schema.XXXXXX)"
curl -sSLf "https://metal.freedom-yield.com/api/identity.schema.v1.json" -o "${SCHEMA_TMP}"
if command -v ajv >/dev/null 2>&1; then
	if ajv validate \
			--spec=draft2020 \
			--strict=false \
			-c=ajv-formats \
			-s "${SCHEMA_TMP}" \
			-d "${OUT_JSON}" >/dev/null 2>&1; then
		echo "  OK   identity.json validates against live identity.schema.v1.json (ajv)"
	else
		echo "  FAIL schema validation failed:" >&2
		ajv validate --spec=draft2020 --strict=false -c=ajv-formats \
			-s "${SCHEMA_TMP}" -d "${OUT_JSON}" >&2 || true
		HAS_ERROR=1
	fi
else
	echo "  SKIP ajv not installed; install with 'npm i -g ajv-cli ajv-formats' for full schema check"
fi
rm -f "${SCHEMA_TMP}"

echo
if [ "${HAS_ERROR}" -eq 0 ]; then
	echo "PASS: gen-identity.sh Phase 3 Merkle DAG output is internally consistent"
	echo "      (leaves re-hash match, Merkle root reproducible, signature verifies)"
	exit 0
else
	echo "FAIL: see errors above" >&2
	exit 1
fi
