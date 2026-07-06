#!/usr/bin/env bash
# scripts/operator-local/test-gen-identity.sh
#
# Synthetic-key test harness for gen-identity.sh.
#
# Generates a throwaway ed25519 key in a tmp dir, runs gen-identity.sh against
# a fake REPO_ROOT skeleton, then independently re-verifies the artifact_root
# the script computed. Used to confirm artifact_root computation is correct
# WITHOUT touching the real operator identity key or the real repo's
# public/api/identity.json.
#
# Why this exists:
#   - Merkle-rooted artifact manifest computation must be testable now, but
#     the real operator identity key (Task #25 / D11 Phase 3) is still HOLD
#     pending Task #28 cron auto-fire confirmation.
#   - Producing a real signed identity.json here would risk leaking
#     synthetic-key-signed bytes into public/api/.
#   - This harness routes everything through /tmp and prints PASS/FAIL only.
#
# Pre-commit validation policy: ALL schema validations in this script use the
# LOCAL revised schema at canonical-repo public/api/identity.schema.v1.json.
# We do NOT fetch the live URL — pre-deploy, the live URL still serves the
# pre-revision content and would not exercise the revised contract.
#
# Usage:
#   bash scripts/operator-local/test-gen-identity.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_REPO="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOCAL_SCHEMA="${REAL_REPO}/public/api/identity.schema.v1.json"
LOCAL_EXAMPLE="${REAL_REPO}/public/api/identity.example.json"

# Pinned AJV combination. Versions empirically verified to compile draft-2020-12,
# validate documents, and enforce uri / date-time format checks. Update both
# values in one place if changing.
AJV_CLI_VERSION="5.0.0"
AJV_FORMATS_VERSION="3.0.1"

TEST_ROOT="$(mktemp -d -t fy-test-gen-identity.XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

# 1. Synthetic ed25519 key in tmp.
SYN_KEY="${TEST_ROOT}/synthetic-operator-key"
ssh-keygen -t ed25519 -N "" -C "synthetic-test-key DO-NOT-USE" -f "${SYN_KEY}" -q

# 2. Fake REPO_ROOT skeleton: just an empty public/api/ dir is enough.
FAKE_REPO="${TEST_ROOT}/fake-repo"
mkdir -p "${FAKE_REPO}/public/api"

HAS_ERROR=0

# Helper: pinned AJV command as a bash array. Reused for compile + validate so
# the version pins and flags cannot drift across invocations.
AJV_CMD=(
	npx --yes --quiet
	--package "ajv-cli@${AJV_CLI_VERSION}"
	--package "ajv-formats@${AJV_FORMATS_VERSION}"
	ajv
)

if ! command -v npx >/dev/null 2>&1; then
	echo "FAIL: npx not installed; pinned AJV is mandatory for this test." >&2
	echo "      Install Node.js + npm, then re-run." >&2
	exit 1
fi

# 0. Compile local revised schema (mandatory).
echo "=== 0. compile local revised schema (mandatory) ==="
if "${AJV_CMD[@]}" compile \
		--spec=draft2020 \
		--strict=false \
		-c=ajv-formats \
		-s "${LOCAL_SCHEMA}" >/dev/null 2>&1; then
	echo "  OK   ${LOCAL_SCHEMA##*/} compiles cleanly (ajv-cli@${AJV_CLI_VERSION} + ajv-formats@${AJV_FORMATS_VERSION})"
else
	echo "  FAIL ${LOCAL_SCHEMA##*/} does NOT compile:" >&2
	"${AJV_CMD[@]}" compile --spec=draft2020 --strict=false -c=ajv-formats \
		-s "${LOCAL_SCHEMA}" >&2 || true
	HAS_ERROR=1
fi

# 1. Validate LOCAL example against LOCAL revised schema (mandatory).
echo
echo "=== 1. validate LOCAL example against LOCAL revised schema (mandatory) ==="
if "${AJV_CMD[@]}" validate \
		--spec=draft2020 \
		--strict=false \
		-c=ajv-formats \
		-s "${LOCAL_SCHEMA}" \
		-d "${LOCAL_EXAMPLE}" >/dev/null 2>&1; then
	echo "  OK   ${LOCAL_EXAMPLE##*/} validates against revised schema"
else
	echo "  FAIL ${LOCAL_EXAMPLE##*/} does NOT validate:" >&2
	"${AJV_CMD[@]}" validate --spec=draft2020 --strict=false -c=ajv-formats \
		-s "${LOCAL_SCHEMA}" -d "${LOCAL_EXAMPLE}" >&2 || true
	HAS_ERROR=1
fi

# 3. Run gen-identity.sh against the fake repo + synthetic key.
echo
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

# 3.5. Assert NO chain_anchor field in the output (removed 2026-06-20).
echo
echo "=== 3.5. assert no chain_anchor field in output ==="
if [ "$(jq -r 'has("chain_anchor")' "${OUT_JSON}")" = "false" ]; then
	echo "  OK   identity.json has no chain_anchor field"
else
	echo "  FAIL identity.json still carries chain_anchor field" >&2
	HAS_ERROR=1
fi

# 3.6. Assert identity.json's evidence-pointer fields are present, and — as of
# the 2026-07-06 DAG-root collapse (design-stocktake #1) — assert identity.json
# NO LONGER carries dag_root_hash. The pre-v2 2-branch root was advertised here
# with a (false) "anchored via fyid1:" claim; the value actually inscribed
# on-chain is anchor-receipt.json.dag_root_hash (3-branch dag_root_computed,
# memo fya<S>c<N>:). identity.json now reaches the on-chain evidence purely via
# anchor_receipt_url / audit, not a competing root. See docs/IDENTITY_SCHEMA_CHANGELOG.md.
echo
echo "=== 3.6. assert evidence-pointer fields + dag_root_hash retired on identity.json ==="
for field in cycles_history_url anchor_receipt_url; do
	val="$(jq -r --arg f "${field}" '.[$f] // ""' "${OUT_JSON}")"
	if [ -n "${val}" ]; then
		echo "  OK   ${field} present: ${val}"
	else
		echo "  FAIL ${field} missing from identity.json" >&2
		HAS_ERROR=1
	fi
done

# dag_root_hash MUST be absent from identity.json (collapse invariant).
if [ "$(jq -r 'has("dag_root_hash")' "${OUT_JSON}")" = "false" ]; then
	echo "  OK   dag_root_hash absent (retired — on-chain root lives in anchor-receipt.json)"
else
	echo "  FAIL identity.json still carries dag_root_hash: $(jq -r '.dag_root_hash' "${OUT_JSON}")" >&2
	HAS_ERROR=1
fi

# 3.7. Assert cycles-history.json sibling was produced.
echo
echo "=== 3.7. assert cycles-history.json sibling output ==="
OUT_CYCLES_HISTORY="${FAKE_REPO}/public/api/cycles-history.json"
if [ ! -f "${OUT_CYCLES_HISTORY}" ]; then
	echo "  FAIL gen-identity.sh did not produce cycles-history.json" >&2
	HAS_ERROR=1
else
	if jq empty "${OUT_CYCLES_HISTORY}" >/dev/null 2>&1; then
		CY_DAG="$(jq -r '.dag_root_hash // ""' "${OUT_CYCLES_HISTORY}")"
		# cycles-history.json retains the 2-branch DAG summary root; identity.json
		# no longer duplicates it (collapse #1). Assert it is well-formed 64-hex.
		case "${CY_DAG}" in
			*[!a-f0-9]*|"") echo "  FAIL cycles-history.json dag_root_hash not 64-hex: ${CY_DAG}" >&2; HAS_ERROR=1 ;;
			*)
				if [ "${#CY_DAG}" -ne 64 ]; then
					echo "  FAIL cycles-history.json dag_root_hash is ${#CY_DAG} chars, expected 64" >&2; HAS_ERROR=1
				else
					echo "  OK   cycles-history.json present + dag_root_hash 64-hex (2-branch summary)"
				fi
				;;
		esac
	else
		echo "  FAIL cycles-history.json is not valid JSON" >&2
		HAS_ERROR=1
	fi
fi

# 3.8. Assert identity-history.jsonl was bootstrapped on first run.
echo
echo "=== 3.8. assert identity-history.jsonl bootstrap ==="
OUT_ID_HIST="${FAKE_REPO}/public/api/identity-history.jsonl"
if [ ! -s "${OUT_ID_HIST}" ]; then
	echo "  FAIL gen-identity.sh did not bootstrap identity-history.jsonl" >&2
	HAS_ERROR=1
else
	LINE_COUNT="$(wc -l < "${OUT_ID_HIST}" | tr -d ' ')"
	if [ "${LINE_COUNT}" -ge 1 ]; then
		# First line must parse as JSON with key_seq=1.
		FIRST_LINE="$(head -n 1 "${OUT_ID_HIST}")"
		if printf '%s' "${FIRST_LINE}" | jq empty >/dev/null 2>&1 \
			&& [ "$(printf '%s' "${FIRST_LINE}" | jq -r '.key_seq // ""')" = "1" ]; then
			echo "  OK   identity-history.jsonl bootstrapped with key_seq=1"
		else
			echo "  FAIL identity-history.jsonl first line is not key_seq=1 JSON: ${FIRST_LINE}" >&2
			HAS_ERROR=1
		fi
	else
		echo "  FAIL identity-history.jsonl is empty" >&2
		HAS_ERROR=1
	fi
fi

# 4. Independently re-fetch each leaf in the manifest and re-hash.
echo
echo "=== independent re-hash of each leaf in artifact_manifest ==="
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
ALLOWED="$(mktemp -t allowed_signers.XXXXXX)"
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

# 7. Validate synthetic gen-identity output against LOCAL revised schema (mandatory).
#    Pre-commit test uses LOCAL revised schema, NEVER the live URL — the live
#    URL still serves the pre-revision content until deploy.
echo
echo "=== 7. validate synthetic output against LOCAL revised schema (mandatory) ==="
if "${AJV_CMD[@]}" validate \
		--spec=draft2020 \
		--strict=false \
		-c=ajv-formats \
		-s "${LOCAL_SCHEMA}" \
		-d "${OUT_JSON}" >/dev/null 2>&1; then
	echo "  OK   synthetic identity.json validates against revised schema"
else
	echo "  FAIL synthetic identity.json does NOT validate:" >&2
	"${AJV_CMD[@]}" validate --spec=draft2020 --strict=false -c=ajv-formats \
		-s "${LOCAL_SCHEMA}" -d "${OUT_JSON}" >&2 || true
	HAS_ERROR=1
fi

# 8. Retired-env test: set CHAIN_ANCHOR_TX_ID, expect ERROR + exit 6,
#    expect NO output file (script exits before main work).
echo
echo "=== 8. retired-env test (CHAIN_ANCHOR_TX_ID set, expect ERROR + exit 6) ==="
ENV_TEST_REPO="${TEST_ROOT}/env-test-repo"
ENV_TEST_STDOUT="${TEST_ROOT}/env-test-stdout"
ENV_TEST_STDERR="${TEST_ROOT}/env-test-stderr"
mkdir -p "${ENV_TEST_REPO}/public/api"

ENV_RC=0
if CHAIN_ANCHOR_TX_ID="deadbeefcafebabe1234567890abcdef0123456789abcdefdeadbeef12345678" \
   OPERATOR_IDENTITY_KEY="${SYN_KEY}" \
   REPO_ROOT="${ENV_TEST_REPO}" \
   KEY_IAT="2026-06-19T00:00:00Z" \
   KEY_EXP="2027-06-19T00:00:00Z" \
   bash "${SCRIPT_DIR}/gen-identity.sh" \
       >"${ENV_TEST_STDOUT}" 2>"${ENV_TEST_STDERR}"; then
	ENV_RC=0
else
	ENV_RC=$?
fi

if [ "${ENV_RC}" -eq 6 ]; then
	echo "  OK   exit code 6 (retired env detected, no output produced)"
else
	echo "  FAIL expected exit 6, got ${ENV_RC}" >&2
	HAS_ERROR=1
fi

if grep -q "CHAIN_ANCHOR_TX_ID is set but was retired" "${ENV_TEST_STDERR}"; then
	echo "  OK   ERROR line emitted on stderr"
else
	echo "  FAIL retired-env ERROR line missing on stderr" >&2
	echo "       --- stderr was: ---" >&2
	cat "${ENV_TEST_STDERR}" >&2 || true
	HAS_ERROR=1
fi

if grep -q "unset CHAIN_ANCHOR_TX_ID CHAIN_ANCHOR_EXPLORER" "${ENV_TEST_STDERR}"; then
	echo "  OK   unset hint emitted on stderr"
else
	echo "  FAIL unset hint missing on stderr" >&2
	HAS_ERROR=1
fi

if [ -f "${ENV_TEST_REPO}/public/api/identity.json" ]; then
	echo "  FAIL output file created despite ERROR exit" >&2
	HAS_ERROR=1
else
	echo "  OK   no output file created"
fi

if [ -f "${ENV_TEST_REPO}/public/api/identity.json.sig" ]; then
	echo "  FAIL signature file created despite ERROR exit" >&2
	HAS_ERROR=1
else
	echo "  OK   no signature file created"
fi

echo
if [ "${HAS_ERROR}" -eq 0 ]; then
	echo "PASS: gen-identity.sh artifact_root computation is internally consistent"
	echo "      (revised schema compiles; example validates; synthetic output"
	echo "       validates; no chain_anchor field; leaves re-hash match; Merkle"
	echo "       root reproducible; signature verifies; retired env produces"
	echo "       ERROR + exit 6 with no output)"
	exit 0
else
	echo "FAIL: see errors above" >&2
	exit 1
fi
