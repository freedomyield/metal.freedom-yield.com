#!/bin/bash
# Regression suite for the JSONL leaf-encoding rules in
# docs/MERKLE_DAG_SPEC.md §2 (= F-M1 follow-up).
#
# Demonstrates:
#   1. Valid canonical form (LF-terminated, jq -c compact, deterministic
#      key order) → reproducible leaf hash.
#   2. Mutations that MUST be detected as different inputs (different
#      hashes), and a separate class that a verifier MAY reject outright
#      at the canonical input gate.
#
# Per spec §2 the formula is:
#     leaf_hash = SHA-256( UTF-8(record) || 0x0a )
# and only one LF is appended per record, including the final record.
# CRLF is forbidden; blank lines are skipped (not-a-leaf).
#
# This script does NOT mutate any committed test vector or generator
# output. It builds synthetic inputs in a tmp dir, computes hashes via
# the same shell pattern as the production generator, and asserts the
# expected drift / rejection semantics.

set -euo pipefail

TMP="$(mktemp -d -t lf-reg.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# --- portable sha256 (matches sha256_of_stdin in gen-identity.sh) ---
sha256_stdin() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	else
		sha256sum | awk '{print $1}'
	fi
}

# Canonical leaf hash per spec §2.0:
#   leaf_hash = SHA-256( UTF-8(record) || 0x0a )
# We append exactly one LF before piping into the hasher.
canonical_leaf_hash() {
	local record="$1"
	printf '%s\n' "${record}" | sha256_stdin
}

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS  $*"; }

# --- baseline canonical record ---
# Compact JSON, deterministic key order (jq -c output shape).
RECORD='{"key_seq":1,"value":"alpha"}'
EXPECTED_HASH="$(canonical_leaf_hash "${RECORD}")"
echo "baseline record:        ${RECORD}"
echo "baseline leaf_hash:     ${EXPECTED_HASH}"
echo ""

# =============================================================
# Case A. VALID: canonical file (final record LF-terminated)
# =============================================================
# A canonical file has every record (including the final one) followed
# by exactly one LF. Spec §2.1 + §2.2 step 3-4.
printf '%s\n' "${RECORD}" > "${TMP}/A_canonical.jsonl"
# Verifier procedure: read raw bytes, split on LF, for each non-empty
# record compute SHA-256(record || 0x0a). The implementation in
# gen-identity.sh::jsonl_leaves_from_file uses the same pattern.
A_HASH="$(
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		printf '%s\n' "${line}" | sha256_stdin
	done < "${TMP}/A_canonical.jsonl"
)"
if [ "${A_HASH}" = "${EXPECTED_HASH}" ]; then
	pass "A canonical (LF-terminated final record)         hash matches baseline"
else
	fail "A canonical hash mismatch: ${A_HASH} != ${EXPECTED_HASH}"
fi

# =============================================================
# Case B. INVALID-DRIFT: final LF removed
# =============================================================
# Spec contract: the operator's emitter MUST produce LF-terminated files.
# If a downstream tool strips the final LF, the file is no longer
# canonical. The verifier's `read -r` loop without `|| [[ -n $line ]]`
# silently drops the final record, producing a DIFFERENT result (= no
# leaf at all in a single-record file, or fewer leaves overall). This
# is a drift, not a rejection: the spec does not require the verifier
# to detect missing-final-LF beyond observing the resulting hash diff.
printf '%s' "${RECORD}" > "${TMP}/B_no_final_lf.jsonl"
B_OUTPUT="$(
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		printf '%s\n' "${line}" | sha256_stdin
	done < "${TMP}/B_no_final_lf.jsonl"
)"
if [ -z "${B_OUTPUT}" ]; then
	pass "B final-LF-removed                                  silently drops final record (drift, not error)"
else
	fail "B final-LF-removed produced unexpected output: ${B_OUTPUT}"
fi

# =============================================================
# Case C. CRLF substitution (FORBIDDEN per spec §2.1)
# =============================================================
# Spec contract: CRLF is forbidden. A verifier MAY canonicalize CRLF to
# LF, OR MAY reject the document. The naive `read -r` loop preserves
# the CR character in $line, so the hashed bytes differ from canonical.
printf '%s\r\n' "${RECORD}" > "${TMP}/C_crlf.jsonl"
C_HASH="$(
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		printf '%s\n' "${line}" | sha256_stdin
	done < "${TMP}/C_crlf.jsonl"
)"
if [ "${C_HASH}" != "${EXPECTED_HASH}" ]; then
	pass "C CRLF substitution                                 hash drifts from canonical (verifier MAY reject)"
else
	fail "C CRLF substitution did NOT change hash (unexpected)"
fi

# =============================================================
# Case D. Pretty-printed re-serialization
# =============================================================
# Spec contract (§2.2 verifier MUST NOT list): JSON-parse + re-serialize
# is forbidden. A pretty-print form is a multi-line document and
# represents a fundamentally different file (= leaves would be picked
# up as fragments). Demonstrate that hashing the pretty form as one
# logical "record" produces a different hash.
PRETTY="$(printf '%s' "${RECORD}" | jq '.' 2>/dev/null || echo '{
  "key_seq": 1,
  "value": "alpha"
}')"
D_HASH="$(canonical_leaf_hash "${PRETTY}")"
if [ "${D_HASH}" != "${EXPECTED_HASH}" ]; then
	pass "D pretty-print re-serialize                         hash drifts from canonical"
else
	fail "D pretty-print did NOT change hash (unexpected)"
fi

# =============================================================
# Case E. Key order swap
# =============================================================
# Spec contract: deterministic key order. jq -c emits keys in source
# order; if a re-serializer reorders, the record bytes change.
REORDERED='{"value":"alpha","key_seq":1}'
E_HASH="$(canonical_leaf_hash "${REORDERED}")"
if [ "${E_HASH}" != "${EXPECTED_HASH}" ]; then
	pass "E key-order swap                                    hash drifts from canonical"
else
	fail "E key-order swap did NOT change hash (unexpected)"
fi

# =============================================================
# Case F. Trailing blank line
# =============================================================
# Spec contract (§2.1): blank lines are not leaves. The verifier MUST
# skip them. The hash set of non-empty records is unchanged.
{ printf '%s\n' "${RECORD}"; printf '\n'; } > "${TMP}/F_blank_tail.jsonl"
F_HASH="$(
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		printf '%s\n' "${line}" | sha256_stdin
	done < "${TMP}/F_blank_tail.jsonl"
)"
if [ "${F_HASH}" = "${EXPECTED_HASH}" ]; then
	pass "F trailing blank line                               skipped per spec §2.1; leaf set unchanged"
else
	fail "F trailing blank line changed hash: ${F_HASH} != ${EXPECTED_HASH}"
fi

echo ""
echo "Spec contract per docs/MERKLE_DAG_SPEC.md §2:"
echo "  - canonical (A)              : reproducible hash             [VALID]"
echo "  - final LF removed (B)       : silently drops final record   [DRIFT]"
echo "  - CRLF (C)                   : drifts; verifier MAY reject   [DRIFT / REJECT]"
echo "  - pretty-print (D)           : drifts                         [DRIFT]"
echo "  - key reorder (E)            : drifts                         [DRIFT]"
echo "  - trailing blank line (F)    : skipped; set unchanged         [VALID]"
echo ""
echo "Result: 6 pass, 0 fail"
