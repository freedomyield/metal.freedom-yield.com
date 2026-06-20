#!/usr/bin/env bash
# Verify that gen-identity.sh::compute_merkle_root (= shell, portable)
# produces the same branch_root as generate.py (= Python reference) for
# every test vector. This pins the cross-implementation equivalence
# claim in docs/MERKLE_DAG_SPEC.md §3.
#
# Auditor usage:
#   bash tests/identity-verification-vectors/verify-shell-equivalence.sh
#
# Exits non-zero on any mismatch.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${ROOT}/../.." && pwd)"

# Portable sha256.
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

# Inlined copy of scripts/operator-local/gen-identity.sh::compute_merkle_root
# (lines 186-230, sha-pinned to the spec). If the canonical function
# changes, this copy must be updated in lockstep.
compute_merkle_root() {
	local cur nxt left right parent count
	cur="$(mktemp -t merkle.XXXXXX)"
	nxt="$(mktemp -t merkle.XXXXXX)"
	cat > "${cur}"

	count="$(wc -l < "${cur}" | tr -d ' ')"
	if [ "${count}" -eq 0 ]; then
		rm -f "${cur}" "${nxt}"
		# Empty branch: sentinel hash per MERKLE_DAG_SPEC.md §5.
		printf '' | sha256_of_stdin
		return 0
	fi

	while [ "${count}" -gt 1 ]; do
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

# For a given JSONL file, emit one leaf hash per line in file order
# (= matches generate.py::jsonl_leaves: non-empty lines only, leaf bytes
# include the trailing '\n' on intermediate lines).
jsonl_to_leaf_hashes() {
	local file="$1"
	# Use awk to print each line with its terminator, then pipe each
	# line individually through sha256. We pass each line as-emitted
	# (no extra newline) and rely on the file having lines that end
	# with '\n' for intermediates, no trailing '\n' for the last line.
	# Most generators (including ours) emit a trailing newline after
	# the last line as well. The Python reference treats either case
	# consistently because it strips empty pieces.
	python3 -c '
import sys, hashlib
data = open(sys.argv[1], "rb").read()
pieces, cur = [], bytearray()
for b in data:
    cur.append(b)
    if b == 0x0A:
        pieces.append(bytes(cur)); cur = bytearray()
if cur:
    pieces.append(bytes(cur))
for p in pieces:
    if p.rstrip(b"\n").strip():
        print(hashlib.sha256(p).hexdigest())
' "${file}"
}

dag_combine() {
	local id_root="$1" cy_root="$2"
	{ printf '%s' "${id_root}" | xxd -r -p
	  printf '%s' "${cy_root}" | xxd -r -p
	} | sha256_of_stdin
}

FAIL=0
PASS=0

for vec_dir in "${ROOT}"/v0*-*/; do
	vec_name="$(basename "${vec_dir}")"
	expected_json="${vec_dir}expected.json"
	[ -f "${expected_json}" ] || { echo "SKIP ${vec_name}: no expected.json"; continue; }

	# Single-branch vectors carry one of {identity-history.jsonl, cycle-history.jsonl}.
	# Full-DAG vector carries both.
	if [ -f "${vec_dir}identity-history.jsonl" ] && [ -f "${vec_dir}cycle-history.jsonl" ]; then
		id_leaves="$(jsonl_to_leaf_hashes "${vec_dir}identity-history.jsonl")"
		cy_leaves="$(jsonl_to_leaf_hashes "${vec_dir}cycle-history.jsonl")"
		id_root="$(printf '%s\n' "${id_leaves}" | sed '/^$/d' | compute_merkle_root)"
		cy_root="$(printf '%s\n' "${cy_leaves}" | sed '/^$/d' | compute_merkle_root)"
		dag="$(dag_combine "${id_root}" "${cy_root}")"
		expected_dag="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['dag_root_hash'])" "${expected_json}")"
		expected_id="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['identity_branch']['branch_root'])" "${expected_json}")"
		expected_cy="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['cycles_branch']['branch_root'])" "${expected_json}")"
		if [ "${id_root}" = "${expected_id}" ] && [ "${cy_root}" = "${expected_cy}" ] && [ "${dag}" = "${expected_dag}" ]; then
			echo "OK   ${vec_name}: shell id=${id_root:0:12}…, cy=${cy_root:0:12}…, dag=${dag:0:12}…"
			PASS=$((PASS+1))
		else
			echo "FAIL ${vec_name}: shell-derived roots differ from Python expected"
			echo "  expected id=${expected_id} cy=${expected_cy} dag=${expected_dag}"
			echo "  got      id=${id_root} cy=${cy_root} dag=${dag}"
			FAIL=$((FAIL+1))
		fi
	else
		# Single-branch vector
		src=""
		[ -f "${vec_dir}identity-history.jsonl" ] && src="${vec_dir}identity-history.jsonl"
		[ -f "${vec_dir}cycle-history.jsonl" ] && src="${vec_dir}cycle-history.jsonl"
		[ -n "${src}" ] || { echo "SKIP ${vec_name}: no source jsonl"; continue; }
		leaves="$(jsonl_to_leaf_hashes "${src}")"
		root="$(printf '%s\n' "${leaves}" | sed '/^$/d' | compute_merkle_root)"
		expected_root="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['branch_root'])" "${expected_json}")"
		if [ "${root}" = "${expected_root}" ]; then
			echo "OK   ${vec_name}: shell branch_root=${root:0:12}… matches Python"
			PASS=$((PASS+1))
		else
			echo "FAIL ${vec_name}: shell branch_root differs"
			echo "  expected ${expected_root}"
			echo "  got      ${root}"
			FAIL=$((FAIL+1))
		fi
	fi
done

echo ""
echo "Result: ${PASS} pass, ${FAIL} fail"
[ "${FAIL}" -eq 0 ]
