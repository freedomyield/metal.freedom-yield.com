#!/usr/bin/env bash
# tests/anchor-source-canonicalizer/test-canonicalizer-newline.sh
#
# SPEC-1 regression: the canonical form the anchor pipeline hashes is the
# `jq -cS` output *including* the trailing newline that jq appends. Verifiers
# using RFC-8785 / Python json.dumps / JavaScript JSON.stringify produce
# byte-identical canonical strings but *omit* the trailing newline, which
# yields a different sha256. This test proves — cross-canonicalizer — that:
#
#   1. Three canonicalizers (jq -cS, Python, Node.js) emit the same canonical
#      string (byte-for-byte).
#   2. sha256(canonical bytes)         → hash A (the "no newline" hash)
#   3. sha256(canonical bytes + "\n")  → hash B (the "with newline" hash)
#   4. hash B == the on-chain memo hex (matches the anchor pipeline's own
#      `jq -cS | sha256sum` output).
#   5. hash A != hash B, and hash A appears as the mismatch value that a
#      naive RFC-8785 verifier would compute.
#
# Fixture: tests/fixtures/anchor-source.substantive.json's identity_branch,
# which S11 rehearsal inscribed on testnet with root
#   840665c70f72f55ae110a9ebd5dc6e397985c76b543af6e4ca6330fb5dacf763
# (see project_anchor_testnet_s11_semantic_c_20260701). Moved out of
# public/api/ on 2026-08-05 (audit finding: an unanchored cycle-2
# snapshot sitting in the public API tree risked evaluator misreading
# it as live data) — the fixture's content and hashes are unchanged,
# only its location.
#
# Skips Node.js sub-check if `node` is not installed on the test host
# (the shell + Python sub-checks alone still prove the newline-sensitivity
# invariant, which is the actual spec regression this test guards).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUBSTANTIVE="${REPO_ROOT}/tests/fixtures/anchor-source.substantive.json"

# --- expected values pinned from the S11 broadcast material ------------------
EXPECTED_HASH_WITH_NEWLINE="840665c70f72f55ae110a9ebd5dc6e397985c76b543af6e4ca6330fb5dacf763"
EXPECTED_HASH_NO_NEWLINE="01d25505b26294db62f0830ed2d4be95e0d58132f6c26104c492fb4442b708f3"

PASS=0
FAIL=0
FAIL_LINES=()

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		printf '  ✓ PASS: %s\n' "$label"
		PASS=$((PASS + 1))
	else
		printf '  ✗ FAIL: %s\n' "$label"
		printf '         expected: %s\n' "$expected"
		printf '         actual:   %s\n' "$actual"
		FAIL=$((FAIL + 1))
		FAIL_LINES+=("$label")
	fi
}

assert_neq() {
	local label="$1" a="$2" b="$3"
	if [ "$a" != "$b" ]; then
		printf '  ✓ PASS: %s\n' "$label"
		PASS=$((PASS + 1))
	else
		printf '  ✗ FAIL: %s (values were equal)\n' "$label"
		FAIL=$((FAIL + 1))
		FAIL_LINES+=("$label")
	fi
}

echo "== test-canonicalizer-newline.sh =="
echo "fixture: $SUBSTANTIVE"

if [ ! -r "$SUBSTANTIVE" ]; then
	echo "  ✗ SETUP: substantive.json not readable at $SUBSTANTIVE" >&2
	exit 1
fi

# --- Canonicalizer 1: jq -cS (shell reference implementation) ----------------

JQ_CANONICAL="$(jq -cS '.identity_branch' "$SUBSTANTIVE")"
JQ_WITH_NEWLINE_HASH="$(printf '%s\n' "$JQ_CANONICAL" | shasum -a 256 | awk '{print $1}')"
# printf %s (no trailing newline) — canonical bytes only, no 0x0a appended
JQ_NO_NEWLINE_HASH="$(printf '%s' "$JQ_CANONICAL" | shasum -a 256 | awk '{print $1}')"

assert_eq "jq -cS + newline == on-chain memo hex" "$EXPECTED_HASH_WITH_NEWLINE" "$JQ_WITH_NEWLINE_HASH"
assert_eq "jq -cS without newline == naive RFC-8785 hash" "$EXPECTED_HASH_NO_NEWLINE" "$JQ_NO_NEWLINE_HASH"
assert_neq "the two hashes differ (newline sensitivity is real)" "$JQ_WITH_NEWLINE_HASH" "$JQ_NO_NEWLINE_HASH"

# --- Canonicalizer 2: Python json.dumps(sort_keys=True) ----------------------

if command -v python3 >/dev/null 2>&1; then
	PY_OUT="$(python3 - "$SUBSTANTIVE" <<'PYEOF'
import json, hashlib, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    obj = json.load(f)
canonical = json.dumps(
    obj["identity_branch"],
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=False,
)
# emit "STRING|SHA_NO_NEWLINE|SHA_WITH_NEWLINE"
enc = canonical.encode("utf-8")
h_no = hashlib.sha256(enc).hexdigest()
h_yes = hashlib.sha256(enc + b"\n").hexdigest()
print(f"{canonical}|{h_no}|{h_yes}")
PYEOF
	)"
	PY_CANONICAL="${PY_OUT%%|*}"
	PY_REST="${PY_OUT#*|}"
	PY_NO_NEWLINE_HASH="${PY_REST%%|*}"
	PY_WITH_NEWLINE_HASH="${PY_REST##*|}"

	assert_eq "Python canonical string == jq -cS canonical string" "$JQ_CANONICAL" "$PY_CANONICAL"
	assert_eq "Python + newline == on-chain memo hex" "$EXPECTED_HASH_WITH_NEWLINE" "$PY_WITH_NEWLINE_HASH"
	assert_eq "Python without newline == naive RFC-8785 hash" "$EXPECTED_HASH_NO_NEWLINE" "$PY_NO_NEWLINE_HASH"
else
	printf '  SKIP: python3 not on PATH (Python cross-check skipped)\n'
fi

# --- Canonicalizer 3: Node.js JSON.stringify(sortDeep) ----------------------

if command -v node >/dev/null 2>&1; then
	NODE_OUT="$(node - "$SUBSTANTIVE" <<'NODEEOF'
const fs = require('fs');
const crypto = require('crypto');
function sortDeep(v) {
  if (Array.isArray(v)) return v.map(sortDeep);
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v).sort()) out[k] = sortDeep(v[k]);
    return out;
  }
  return v;
}
const path = process.argv[2];
const obj = JSON.parse(fs.readFileSync(path, 'utf-8'));
const canonical = JSON.stringify(sortDeep(obj.identity_branch));
const enc = Buffer.from(canonical, 'utf-8');
const hNo  = crypto.createHash('sha256').update(enc).digest('hex');
const hYes = crypto.createHash('sha256').update(Buffer.concat([enc, Buffer.from([0x0a])])).digest('hex');
process.stdout.write(`${canonical}|${hNo}|${hYes}`);
NODEEOF
	)"
	NODE_CANONICAL="${NODE_OUT%%|*}"
	NODE_REST="${NODE_OUT#*|}"
	NODE_NO_NEWLINE_HASH="${NODE_REST%%|*}"
	NODE_WITH_NEWLINE_HASH="${NODE_REST##*|}"

	assert_eq "Node canonical string == jq -cS canonical string" "$JQ_CANONICAL" "$NODE_CANONICAL"
	assert_eq "Node + newline == on-chain memo hex" "$EXPECTED_HASH_WITH_NEWLINE" "$NODE_WITH_NEWLINE_HASH"
	assert_eq "Node without newline == naive RFC-8785 hash" "$EXPECTED_HASH_NO_NEWLINE" "$NODE_NO_NEWLINE_HASH"
else
	printf '  SKIP: node not on PATH (Node.js cross-check skipped)\n'
fi

# --- summary -----------------------------------------------------------------

printf '\n%s summary: PASS=%d  FAIL=%d\n' "$(basename "$0")" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf 'failed cases:\n'
	for l in "${FAIL_LINES[@]}"; do printf '  - %s\n' "$l"; done
	exit 1
fi
exit 0
