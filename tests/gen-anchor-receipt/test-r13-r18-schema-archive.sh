#!/usr/bin/env bash
# tests/gen-anchor-receipt/test-r13-r18-schema-archive.sh — R13 (mandatory
# schema self-validation, fail-closed) + R18 (durable per-anchor archive)
# coverage for scripts/gen-anchor-receipt.sh.
#
# test-gen-anchor-receipt.sh (the pre-existing suite) deliberately never
# reaches exit 0 — by its own header comment, "the RPC-fetch path (gates
# 1-7) is exercised in the testnet full E2E rehearsal", not unit-tested
# here. That means the R13/R18 code (which runs strictly AFTER gate 7
# passes, right before the atomic write) is otherwise completely
# untested. This file closes that gap with a full happy-path run: a stub
# `curl` returns a Hyperion v2 response shaped to satisfy all 7 verify
# gates for a fixed, self-consistent 4-action pack (dag_root_hash ==
# sha256(id_root||ob_root||ar_root), matching memos, matching
# authorization), so the script proceeds past gate 7 into the R13/R18
# code under test.
#
# CHAIN: none. The stub curl never touches the network; gen-anchor-receipt.sh
#        itself never broadcasts (it only reads + composes JSON).
#        PRIME_DIRECTIVE: safe.
#
# Usage:
#   bash tests/gen-anchor-receipt/test-r13-r18-schema-archive.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/gen-anchor-receipt.sh"

if [ ! -x "$SCRIPT" ]; then
	echo "FATAL: script not executable at $SCRIPT" >&2
	exit 1
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$label"
	else
		fail "$label (expected='$expected' actual='$actual')"
	fi
}

TMP="$(mktemp -d -t gen-anchor-receipt-r13r18.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/out"

# === fixed, self-consistent 4-action pack input =============================
# dag_root_hash MUST equal sha256(id_root || ob_root || ar_root) hex-concat
# (gate 6) — these four were computed once offline and are pinned here.
ID_ROOT="b4d5a3eb0b3ec2706bcc2685320ca970c07dabb9412befa8465793666a928df8"
OB_ROOT="c2f5fb3e78a0527aa993a1beaa601a1acf4bc74c80a1f08a22aee47e44306c49"
AR_ROOT="8ad3a424779b937615987a7ea7a384b32cda6dfbe778f220c8da7ce6a9b4b84f"
DAG_ROOT="168a3abd5f657b639dd095b228cc5fc62e5a3c7c1fa3559c20669048d2a54511"
TX_ID="d1f94312e950b813f4f52476027340e442665a92cc4a80971086feb5c8768fc9"
ACTOR="metalfreedom"
PERMISSION="anchor"
MEMO_PREFIX="fya1c9"

INPUT_JSON="$TMP/input.json"
cat > "$INPUT_JSON" <<EOF
{
  "tx_id": "$TX_ID",
  "chain": "metal-a-chain",
  "network": "testnet-a",
  "method": "hc_single_4_action_pack",
  "schema_version": 1,
  "cycle_number": 9,
  "memo_prefix": "$MEMO_PREFIX",
  "actions": [
    {"branch": "identity", "memo": "${MEMO_PREFIX}-id:${ID_ROOT}", "root_hex": "$ID_ROOT"},
    {"branch": "observations", "memo": "${MEMO_PREFIX}-ob:${OB_ROOT}", "root_hex": "$OB_ROOT"},
    {"branch": "artifacts", "memo": "${MEMO_PREFIX}-ar:${AR_ROOT}", "root_hex": "$AR_ROOT"},
    {"branch": "dag_root_summary", "memo": "${MEMO_PREFIX}:${DAG_ROOT}", "root_hex": "$DAG_ROOT"}
  ],
  "authorization": {"actor": "$ACTOR", "permission": "$PERMISSION"},
  "sink": "fyhistory",
  "quantity": "0.0001 XPR"
}
EOF

ANCHOR_SOURCE_FIXTURE="$TMP/anchor-source-fixture.json"
printf '{"fixture":"anchor-source"}\n' > "$ANCHOR_SOURCE_FIXTURE"

# Hyperion v2 get_actions shape: 4 eosio.token::transfer actions, all
# matching authorization + the expected memo set, sharing one block_num.
cat > "$TMP/hyperion-response.json" <<EOF
{
  "actions": [
    {"trx_id": "$TX_ID", "block_num": 12345678, "timestamp": "2026-07-08T00:00:00.000Z",
     "act": {"account": "eosio.token", "name": "transfer", "authorization": [{"actor": "$ACTOR", "permission": "$PERMISSION"}], "data": {"memo": "${MEMO_PREFIX}-id:${ID_ROOT}"}}},
    {"trx_id": "$TX_ID", "block_num": 12345678, "timestamp": "2026-07-08T00:00:00.000Z",
     "act": {"account": "eosio.token", "name": "transfer", "authorization": [{"actor": "$ACTOR", "permission": "$PERMISSION"}], "data": {"memo": "${MEMO_PREFIX}-ob:${OB_ROOT}"}}},
    {"trx_id": "$TX_ID", "block_num": 12345678, "timestamp": "2026-07-08T00:00:00.000Z",
     "act": {"account": "eosio.token", "name": "transfer", "authorization": [{"actor": "$ACTOR", "permission": "$PERMISSION"}], "data": {"memo": "${MEMO_PREFIX}-ar:${AR_ROOT}"}}},
    {"trx_id": "$TX_ID", "block_num": 12345678, "timestamp": "2026-07-08T00:00:00.000Z",
     "act": {"account": "eosio.token", "name": "transfer", "authorization": [{"actor": "$ACTOR", "permission": "$PERMISSION"}], "data": {"memo": "${MEMO_PREFIX}:${DAG_ROOT}"}}}
  ]
}
EOF

cat > "$TMP/bin/curl" <<STUBEOF
#!/usr/bin/env bash
for a in "\$@"; do
	case "\$a" in
		*v2/history/get_actions*) cat "$TMP/hyperion-response.json"; exit 0 ;;
	esac
done
echo "STUB CURL: unmatched: \$*" >&2
exit 22
STUBEOF
chmod +x "$TMP/bin/curl"

# --- PATH farm WITH a stub ajv that always reports "valid" ------------------
FARM_VALID="$TMP/bin-valid"
mkdir -p "$FARM_VALID"
cat > "$FARM_VALID/ajv" <<'AJVEOF'
#!/usr/bin/env bash
exit 0
AJVEOF
chmod +x "$FARM_VALID/ajv"
cp "$TMP/bin/curl" "$FARM_VALID/curl"

# --- PATH farm WITH a stub ajv that always reports "invalid" ----------------
FARM_INVALID="$TMP/bin-invalid"
mkdir -p "$FARM_INVALID"
cat > "$FARM_INVALID/ajv" <<'AJVEOF'
#!/usr/bin/env bash
echo "stub: forced invalid" >&2
exit 1
AJVEOF
chmod +x "$FARM_INVALID/ajv"
cp "$TMP/bin/curl" "$FARM_INVALID/curl"

# --- PATH farm WITHOUT ajv/npx/python3 (R13 "no validator available") ------
FARM_NO_VALIDATOR="$TMP/bin-no-validator"
mkdir -p "$FARM_NO_VALIDATOR"
for t in bash jq awk grep sed tr head tail cat mktemp rm mv cp dirname basename \
         sha256sum shasum printf date env cut sort wc; do
	p="$(command -v "$t" 2>/dev/null || true)"
	[ -n "$p" ] && ln -sf "$p" "$FARM_NO_VALIDATOR/$t"
done
cp "$TMP/bin/curl" "$FARM_NO_VALIDATOR/curl"
for absent_tool in ajv npx python3; do
	if PATH="$FARM_NO_VALIDATOR" command -v "$absent_tool" >/dev/null 2>&1; then
		fail "harness leaked $absent_tool into the no-validator farm — refusing to run that case"
	fi
done

run_gen_anchor_receipt() {
	local farm="$1" out="$2"
	PATH="${farm}:${PATH}" bash "$SCRIPT" \
		--input="$INPUT_JSON" --anchor-source="$ANCHOR_SOURCE_FIXTURE" \
		--out="$out" --rpc=https://fixture.invalid --trigger=cyclestart
}

# ---- case 1: happy path (validator says "valid") ---------------------------
OUT1="$TMP/out/anchor-receipt-run1.json"
run_gen_anchor_receipt "$FARM_VALID" "$OUT1" >"$TMP/out/run1.stdout" 2>"$TMP/out/run1.stderr"
RC1=$?
check_eq "happy path: exit 0 (7-PASS + schema-valid)" "0" "$RC1"
if [ "$RC1" -eq 0 ]; then
	[ -r "$OUT1" ] && pass "happy path: canonical receipt written" || fail "happy path: canonical receipt NOT written"
	check_eq "happy path: tx_id round-trips" "$TX_ID" "$(jq -r .anchor.tx_id "$OUT1" 2>/dev/null)"
	check_eq "happy path: dag_root_hash round-trips" "$DAG_ROOT" "$(jq -r .dag_root_hash "$OUT1" 2>/dev/null)"

	# ---- chain_backend: published label must match what the script observes --
	# The receipt is composed unconditionally: chain_backend is a hardcoded
	# literal, not derived from the RPC response, so nothing else in this repo
	# can catch it drifting from reality. From ac2ef0c (2026-06-23) to
	# 2026-08-17 it read "pulsevm" — an announced future execution engine, not
	# the protocol family this script observes — so every receipt published
	# from the first anchor (2026-07-04) onward carried a forward-looking label
	# as present-tense fact, with no test asserting on it. Pin the value: a
	# regression must be a red test, not a public claim.
	ACTUAL_BACKEND="$(jq -r '.anchor.chain_backend' "$OUT1" 2>/dev/null)"
	if [ "$ACTUAL_BACKEND" = "antelope" ]; then
		pass "chain_backend: receipt names the observed protocol family"
	elif [ "$ACTUAL_BACKEND" = "pulsevm" ]; then
		fail "chain_backend: regressed to 'pulsevm' — an announced engine, not the family this script observes (see the WHEN TO CHANGE THIS note in scripts/gen-anchor-receipt.sh)"
	else
		fail "chain_backend: unexpected value '$ACTUAL_BACKEND' (expected 'antelope')"
	fi
	check_eq "chain_backend: chain field unchanged alongside the backend fix" \
		"metal-a-chain" "$(jq -r '.anchor.chain' "$OUT1" 2>/dev/null)"

	# ---- R18: archive copy is byte-identical, keyed by tx_id --------------
	ARCHIVE1="$(dirname "$OUT1")/archive/anchor-receipt-${TX_ID}.json"
	if [ -r "$ARCHIVE1" ]; then
		pass "R18: archive copy exists at content-addressed (tx_id) path"
		if diff -q "$OUT1" "$ARCHIVE1" >/dev/null 2>&1; then
			pass "R18: archive copy is byte-identical to the canonical --out file"
		else
			fail "R18: archive copy differs from the canonical --out file"
		fi
	else
		fail "R18: archive copy NOT found at $ARCHIVE1"
	fi
else
	fail "happy path: script failed unexpectedly; stderr: $(cat "$TMP/out/run1.stderr" 2>/dev/null | tr '\n' '|')"
fi

# ---- the same label on every PUBLISHED example artifact --------------------
# These four files are kind=static / git-deploy in deploy/publication.json: they
# are served from /api/ byte-for-byte as written here, so each one is a public
# claim in its own right. Measured 2026-08-17 at 9d284bb, before this block
# existed: reverting anchor-receipt.example.json,
# anchor-receipt.phase-beta.example.json AND anchor-history.example.jsonl to
# "pulsevm" all at once still produced total=94 pass=94 fail=0 across the whole
# runner. Only anchor-receipt.v2.example.json was covered, and only
# incidentally, because tests/append-anchor-history/ uses it as a receipt
# template. Assert the value directly so "the published examples agree with
# what the generator writes" is a test rather than a coincidence.
EXPECTED_BACKEND="antelope"
API_DIR="${REPO_ROOT}/public/api"
for ex in anchor-receipt.example.json anchor-receipt.v2.example.json anchor-receipt.phase-beta.example.json; do
	check_eq "published example: ${ex} chain_backend" \
		"$EXPECTED_BACKEND" \
		"$(jq -r '.anchor.chain_backend // "MISSING"' "${API_DIR}/${ex}" 2>/dev/null)"
done
# jq streams each JSONL line; sort -u collapses to one token only when every
# line agrees, so a single stale line breaks the comparison.
check_eq "published example: anchor-history.example.jsonl chain_backend (every line)" \
	"$EXPECTED_BACKEND" \
	"$(jq -r '.chain_backend // "MISSING"' "${API_DIR}/anchor-history.example.jsonl" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ *$//')"

# ---- case 2: validator says "invalid" -> exit 6, nothing written ----------
OUT2="$TMP/out/anchor-receipt-run2.json"
run_gen_anchor_receipt "$FARM_INVALID" "$OUT2" >/dev/null 2>"$TMP/out/run2.stderr"
RC2=$?
check_eq "R13: schema validation failed -> exit 6" "6" "$RC2"
if [ -e "$OUT2" ]; then
	fail "R13: invalid case must NOT write $OUT2"
else
	pass "R13: invalid case did not write the canonical file"
fi
grep -q "failed schema validation" "$TMP/out/run2.stderr" \
	&& pass "R13: invalid case emits a clear schema-validation error message" \
	|| fail "R13: invalid case error message missing/unclear"

# ---- case 3: no validator available -> exit 7, nothing written ------------
OUT3="$TMP/out/anchor-receipt-run3.json"
PATH="$FARM_NO_VALIDATOR" bash "$SCRIPT" \
	--input="$INPUT_JSON" --anchor-source="$ANCHOR_SOURCE_FIXTURE" \
	--out="$OUT3" --rpc=https://fixture.invalid --trigger=cyclestart \
	>/dev/null 2>"$TMP/out/run3.stderr"
RC3=$?
check_eq "R13: no validator available -> exit 7 (fail-closed, not silent skip)" "7" "$RC3"
if [ -e "$OUT3" ]; then
	fail "R13: no-validator case must NOT write $OUT3"
else
	pass "R13: no-validator case did not write the canonical file"
fi
grep -q "no JSON schema validator available" "$TMP/out/run3.stderr" \
	&& pass "R13: no-validator case emits a clear fail-closed error message" \
	|| fail "R13: no-validator case error message missing/unclear"

# ---- summary -----------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-r13-r18-schema-archive.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
