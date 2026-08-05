#!/usr/bin/env bash
# tests/gen-anchor-source/test-gen-anchor-source.sh — DIRECT unit test for
# scripts/gen-anchor-source.sh (R13 + R18 package).
#
# Before this test existed, gen-anchor-source.sh was covered only
# INDIRECTLY (via tests/anchor-pipeline/test-run-anchor-pipeline.sh, which
# stubs the script out entirely and never runs its real body). This test
# runs the REAL script end to end against fully fixed inputs — a stub
# `curl` that routes every fetch (pubkey URL, identity-history.jsonl,
# cycle-history.jsonl, the 8 public_api_files_hashed entries, and the
# P-chain RPC POST) to canned fixture bytes — so every field the script
# computes is deterministic and reproducible.
#
# CHAIN: none. The stub curl never touches the network; the real
#        gen-anchor-source.sh performs no broadcast of its own (it only
#        composes a JSON artifact). PRIME_DIRECTIVE: safe.
#
# R13 coverage (mandatory schema validation, fail-closed):
#   - a stub `ajv` that reports "valid"   -> exit 0, artifact written
#   - a stub `ajv` that reports "invalid" -> exit 6, NOTHING written
#   - a PATH farm with neither ajv nor python3+jsonschema (the R13
#     "no validator available" case)      -> exit 8, NOTHING written
#
# R18 coverage (durable per-anchor archive):
#   - the canonical --out file and public/api/archive/anchor-source-<dag
#     root>.json archive copy are BYTE-IDENTICAL to each other
#   - a second archive-triggering run with the SAME fixed inputs produces
#     the SAME archive filename (content-addressed by dag_root_computed)
#     and does not touch the first run's canonical file
#
# CRITICAL INVARIANT (R13/R18 package instructions): the additions in this
# package must not alter canonicalization, composed content, or computed
# roots in any way. The pinned EXPECTED_DAG_ROOT below was captured from a
# real run of the (already R13/R18-modified) script against these fixed
# inputs; every future run of this test re-proves that value is unchanged,
# which is exactly the "prove dag_root_computed for a fixed input is
# unchanged" regression this test is required to carry.
#
# Usage:
#   bash tests/gen-anchor-source/test-gen-anchor-source.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/gen-anchor-source.sh"

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

TMP="$(mktemp -d -t gen-anchor-source-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fixtures" "$TMP/cfg" "$TMP/state" "$TMP/out" "$TMP/bin-curl-only"

# === fixed inputs (pinned; NEVER regenerated at test time) ==================

# Pinned ed25519 OpenSSH pubkey (synthetic, DO-NOT-USE key; generated once
# offline). Semantic C: sha256(last 32 bytes of the base64-decoded wire
# record) must equal $EXPECTED_PUBKEY_HASH below.
cat > "$TMP/fixtures/operator-identity.pub" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHbSbydeQ7/AxLU4BUaqA6rXTMb5y6wcTW2+nRtV/gnj fixture-test-key
EOF

printf '{"seq":1,"note":"fixture-identity-history"}\n' > "$TMP/fixtures/identity-history.jsonl"
: > "$TMP/fixtures/cycle-history.jsonl"                 # empty -> cycle_number_observed=1
printf '{"fixture":"evidence"}\n'            > "$TMP/fixtures/evidence.json"
printf '{"fixture":"identity-api-file"}\n'   > "$TMP/fixtures/identity.json"
printf '{"fixture":"peer-geo"}\n'            > "$TMP/fixtures/peer-geo.json"
printf '{"fixture":"peers"}\n'               > "$TMP/fixtures/peers.json"
printf '{"fixture":"uptime-cycles"}\n'       > "$TMP/fixtures/uptime-cycles.json"
printf '{"fixture":"uptime-recent"}\n'       > "$TMP/fixtures/uptime-recent.json"
printf '{"fixture":"validator"}\n'           > "$TMP/fixtures/validator.json"

cat > "$TMP/fixtures/rpc-response.json" <<'EOF'
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "validators": [
      {
        "nodeID": "NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v",
        "startTime": "1750000000",
        "endTime": "1752592000",
        "stakeAmount": "2000000000000",
        "delegationFee": "3.0000",
        "delegators": [
          {"txID": "fixturetxid00000000000000000000", "weight": "500000000000"}
        ]
      }
    ]
  }
}
EOF

# local identity.json read directly for KEY_SEQ (decoupled from the fetched
# "identity.json" API-file fixture above, which is only used for the
# public_api_manifest_root hash).
printf '{"key_seq": 1}\n' > "$TMP/fixtures/local-identity.json"

# === stub curl: routes every fetch to a fixture by URL suffix; the P-chain
# RPC POST (identified by the literal "POST" method arg) returns the fixed
# validators response. Any unmatched URL exits 22 (curl-like failure) so an
# accidental real network call in the script would show up as a fast, loud
# test failure rather than a silent pass or a real HTTP request. ==========
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<STUBEOF
#!/usr/bin/env bash
FIX="$TMP/fixtures"
URL=""
OUTFILE=""
IS_POST=0
prev=""
for a in "\$@"; do
	case "\$a" in
		http*) URL="\$a" ;;
	esac
	if [ "\$prev" = "-o" ]; then OUTFILE="\$a"; fi
	if [ "\$a" = "POST" ]; then IS_POST=1; fi
	prev="\$a"
done

if [ "\$IS_POST" -eq 1 ]; then
	cat "\$FIX/rpc-response.json"
	exit 0
fi

case "\$URL" in
	*/operator-identity.pub)   cp "\$FIX/operator-identity.pub" "\$OUTFILE"; exit 0 ;;
	*/identity-history.jsonl)  cp "\$FIX/identity-history.jsonl" "\$OUTFILE"; exit 0 ;;
	*/cycle-history.jsonl)     cp "\$FIX/cycle-history.jsonl" "\$OUTFILE"; exit 0 ;;
	*/evidence.json)           cp "\$FIX/evidence.json" "\$OUTFILE"; exit 0 ;;
	*/peer-geo.json)           cp "\$FIX/peer-geo.json" "\$OUTFILE"; exit 0 ;;
	*/peers.json)              cp "\$FIX/peers.json" "\$OUTFILE"; exit 0 ;;
	*/uptime-cycles.json)      cp "\$FIX/uptime-cycles.json" "\$OUTFILE"; exit 0 ;;
	*/uptime-recent.json)      cp "\$FIX/uptime-recent.json" "\$OUTFILE"; exit 0 ;;
	*/validator.json)          cp "\$FIX/validator.json" "\$OUTFILE"; exit 0 ;;
	*/identity.json)           cp "\$FIX/identity.json" "\$OUTFILE"; exit 0 ;;
	*) echo "STUB CURL: unmatched URL: \$URL" >&2; exit 22 ;;
esac
STUBEOF
chmod +x "$TMP/bin/curl"

# --- PATH farm WITHOUT ajv/npx/python3 (R13 "no validator available" case).
# Mirrors tests/sign-anchor-event/test-signing-host-assertion.sh: symlink
# exactly the tools the script needs, deliberately omitting the ones under
# test, so the guard fires deterministically regardless of what's installed
# on the host actually running this suite.
FARM_NO_VALIDATOR="$TMP/bin-no-validator"
mkdir -p "$FARM_NO_VALIDATOR"
for t in bash jq awk grep sed tr head tail cat mktemp rm mv cp dirname basename \
         sha256sum shasum printf date env cut sort wc git mkdir base64; do
	p="$(command -v "$t" 2>/dev/null || true)"
	[ -n "$p" ] && ln -sf "$p" "$FARM_NO_VALIDATOR/$t"
done
cp "$TMP/bin/curl" "$FARM_NO_VALIDATOR/curl"

# Harness sanity: ajv/npx/python3 MUST be unreachable via the scrubbed PATH,
# otherwise the "no validator" case below would not actually exercise R13.
for absent_tool in ajv npx python3; do
	if PATH="$FARM_NO_VALIDATOR" command -v "$absent_tool" >/dev/null 2>&1; then
		fail "harness leaked $absent_tool into the no-validator farm — refusing to run that case"
	fi
done

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

# === common env: fixed inputs, isolated from any real repo/host state ======
export NODE_ID="NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
export API_BASE_URL="https://fixture.invalid/api"
export PUBKEY_URL="https://fixture.invalid/.well-known/operator-identity.pub"
export METALGO_API="http://127.0.0.1:9650"
export IDENTITY_JSON="$TMP/fixtures/local-identity.json"
export IDENTITY_HISTORY_JSONL="$TMP/fixtures/nonexistent-identity-history.jsonl"
export ANCHOR_HISTORY_JSONL="$TMP/fixtures/nonexistent-anchor-history.jsonl"
export CYCLE_HISTORY_JSONL="$TMP/fixtures/nonexistent-cycle-history.jsonl"
export ANOMALY_STATE_DIR="$TMP/state"
export UPTIME_HISTORY_JSONL="$TMP/state/nonexistent-uptime-history.jsonl"
export DELEGATOR_EVENTS_JSONL="$TMP/state/nonexistent-delegator-events.jsonl"
export ANOMALIES_LOG="$TMP/state/nonexistent-anomalies.log"
export FY_CONFIG_DIR="$TMP/cfg"

# === pinned expected values (captured from a real run against the fixed
# inputs above; see the CRITICAL INVARIANT note in the header) ==============
EXPECTED_DAG_ROOT="16df65e6a2165ba877a195e2c9dcd6d1ebb17f2bd25cb08e2cce45b57447fa83"
EXPECTED_PUBKEY_HASH="69200e7737ebb191d19facfc2027ead0d07c890dab9f5f5fb03162f32cb321d3"
EXPECTED_IDENTITY_HISTORY_ROOT="2b109e9efc10c2e1ce223be763cbc21031ea90bb53b26c3b65ced72ff883e0b9"
EXPECTED_MANIFEST_ROOT="f073e2d4af04dbe10df9dbd59f5332ad8a5ac985f91a0d90815ab00e0f0572fd"

# ---- case 1: happy path (validator says "valid") --------------------------
OUT1="$TMP/out/anchor-source-run1.json"
STDERR1="$TMP/out/run1.stderr"
PATH="$FARM_VALID:$PATH" bash "$SCRIPT" --out="$OUT1" >"$TMP/out/run1.stdout" 2>"$STDERR1"
RC1=$?
check_eq "happy path: exit 0" "0" "$RC1"
if [ "$RC1" -eq 0 ]; then
	[ -r "$OUT1" ] && pass "happy path: canonical file written" || fail "happy path: canonical file NOT written"
	check_eq "happy path: dag_root_computed matches pinned value" \
		"$EXPECTED_DAG_ROOT" "$(jq -r .dag_root_computed "$OUT1" 2>/dev/null)"
	check_eq "happy path: operator_ed25519_pubkey_sha256_hex matches pinned value" \
		"$EXPECTED_PUBKEY_HASH" "$(jq -r .identity_branch.operator_ed25519_pubkey_sha256_hex "$OUT1" 2>/dev/null)"
	check_eq "happy path: identity_history_root matches pinned value" \
		"$EXPECTED_IDENTITY_HISTORY_ROOT" "$(jq -r .identity_branch.identity_history_root "$OUT1" 2>/dev/null)"
	check_eq "happy path: public_api_manifest_root matches pinned value" \
		"$EXPECTED_MANIFEST_ROOT" "$(jq -r .artifacts_branch.public_api_manifest_root "$OUT1" 2>/dev/null)"
	check_eq "happy path: cycle_number_observed = 1 (empty cycle-history.jsonl)" \
		"1" "$(jq -r .observations_branch.cycle_number_observed "$OUT1" 2>/dev/null)"
	check_eq "happy path: self_stake_observed_metal = 2000 (2e12 nmetal / 1e9)" \
		"2000" "$(jq -r .observations_branch.self_stake_observed_metal "$OUT1" 2>/dev/null)"
	check_eq "happy path: fee_percent_observed_at_cycle_start = 3" \
		"3" "$(jq -r .observations_branch.fee_percent_observed_at_cycle_start "$OUT1" 2>/dev/null)"
	check_eq "happy path: prev_anchor_root null (genesis, no anchor-history file)" \
		"null" "$(jq -r '.identity_branch.prev_anchor_root // "null"' "$OUT1" 2>/dev/null)"

	# ---- R18: archive copy is byte-identical to the canonical file --------
	# The archive dir is derived from $(dirname "$OUT_FILE")/archive (see
	# scripts/gen-anchor-source.sh), so pointing --out at a tmp path (as
	# this test does throughout) keeps the archive write isolated from the
	# real repo's public/api/archive/ — never touches production state.
	ARCHIVE1="$(dirname "$OUT1")/archive/anchor-source-${EXPECTED_DAG_ROOT}.json"
	if [ -r "$ARCHIVE1" ]; then
		pass "R18: archive copy exists at content-addressed path"
		if diff -q "$OUT1" "$ARCHIVE1" >/dev/null 2>&1; then
			pass "R18: archive copy is byte-identical to the canonical --out file"
		else
			fail "R18: archive copy differs from the canonical --out file"
		fi
	else
		fail "R18: archive copy NOT found at $ARCHIVE1"
	fi
else
	fail "happy path: script failed unexpectedly; stderr: $(cat "$STDERR1" 2>/dev/null | tr '\n' '|')"
fi

# ---- case 2: repeat run with IDENTICAL fixed inputs -> same dag_root ------
# This is the "prove dag_root_computed for a fixed input is unchanged"
# regression: two independent invocations of the (R13/R18-modified) script
# against byte-identical inputs must compose byte-identical branches (and
# therefore an identical dag_root_computed), and the archive write must be
# idempotent (same content-addressed filename, no error on re-write).
OUT2="$TMP/out/anchor-source-run2.json"
PATH="$FARM_VALID:$PATH" bash "$SCRIPT" --out="$OUT2" >/dev/null 2>"$TMP/out/run2.stderr"
RC2=$?
check_eq "determinism: second run exit 0" "0" "$RC2"
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ]; then
	check_eq "determinism: dag_root_computed identical across two runs" \
		"$(jq -r .dag_root_computed "$OUT1")" "$(jq -r .dag_root_computed "$OUT2")"
	# Branches (everything except the computed_at/git-commit metadata) must
	# be byte-identical too, not merely the summary root.
	check_eq "determinism: identity_branch + observations_branch + artifacts_branch identical" \
		"$(jq -cS 'del(.computed_at)' "$OUT1")" "$(jq -cS 'del(.computed_at)' "$OUT2")"
fi

# ---- case 3: validator says "invalid" -> exit 6, nothing written ----------
OUT3="$TMP/out/anchor-source-run3.json"
PATH="$FARM_INVALID:$PATH" bash "$SCRIPT" --out="$OUT3" >/dev/null 2>"$TMP/out/run3.stderr"
RC3=$?
check_eq "R13: schema validation failed -> exit 6" "6" "$RC3"
if [ -e "$OUT3" ]; then
	fail "R13: invalid case must NOT write $OUT3"
else
	pass "R13: invalid case did not write the canonical file"
fi
grep -q "failed schema validation" "$TMP/out/run3.stderr" \
	&& pass "R13: invalid case emits a clear schema-validation error message" \
	|| fail "R13: invalid case error message missing/unclear"

# ---- case 4: no validator available (ajv AND python3+jsonschema absent) ---
OUT4="$TMP/out/anchor-source-run4.json"
PATH="$FARM_NO_VALIDATOR" bash "$SCRIPT" --out="$OUT4" >/dev/null 2>"$TMP/out/run4.stderr"
RC4=$?
check_eq "R13: no validator available -> exit 8 (fail-closed, not silent skip)" "8" "$RC4"
if [ -e "$OUT4" ]; then
	fail "R13: no-validator case must NOT write $OUT4"
else
	pass "R13: no-validator case did not write the canonical file"
fi
grep -q "no JSON schema validator available" "$TMP/out/run4.stderr" \
	&& pass "R13: no-validator case emits a clear fail-closed error message" \
	|| fail "R13: no-validator case error message missing/unclear"

# ---- case 5: prev_anchor_root / prev_anchor_tx populated from a real
# non-genesis anchor-history.jsonl tail line (regression for the
# dag_root_hash/dag_root field-name mismatch between the writer,
# scripts/append-anchor-history.sh (writes "dag_root_hash" — see its
# jq templates around lines 239 and 271), and gen-anchor-source.sh's
# reader, which looked only for ".dag_root // .dag_root_computed" and so
# silently produced prev_anchor_root: null / prev_anchor_tx: null on every
# non-genesis run — masked through cycle 3 because cycle 3 was genesis
# (empty anchor-history.jsonl), first live-fired at the cycle 3 -> cycle 4
# transition. The fixture below intentionally uses the SAME field names
# append-anchor-history.sh actually writes, so this case would have failed
# loudly (instead of silently passing) had it existed before the bug.
FIXTURE_PREV_ROOT="9999999999999999999999999999999999999999999999999999999999999999"
FIXTURE_PREV_TX="8888888888888888888888888888888888888888888888888888888888888888"
ANCHOR_HISTORY_FIXTURE="$TMP/fixtures/anchor-history-with-tail.jsonl"
cat > "$ANCHOR_HISTORY_FIXTURE" <<EOF
{"schema_version":2,"event_type":"cyclestart","cycle_number":1,"dag_root_hash":"$FIXTURE_PREV_ROOT","memo_prefix":"fya1c1","tx_id":"$FIXTURE_PREV_TX","block_num":100000001,"block_time":"2026-07-04T04:00:00Z","verification_status":"live","prev_anchor_tx_id":null}
EOF

OUT5="$TMP/out/anchor-source-run5.json"
STDERR5="$TMP/out/run5.stderr"
PATH="$FARM_VALID:$PATH" ANCHOR_HISTORY_JSONL="$ANCHOR_HISTORY_FIXTURE" \
	bash "$SCRIPT" --out="$OUT5" >"$TMP/out/run5.stdout" 2>"$STDERR5"
RC5=$?
check_eq "prev-root regression: exit 0" "0" "$RC5"
if [ "$RC5" -eq 0 ]; then
	check_eq "prev-root regression: prev_anchor_root reads writer's dag_root_hash field" \
		"$FIXTURE_PREV_ROOT" "$(jq -r '.identity_branch.prev_anchor_root // "null"' "$OUT5" 2>/dev/null)"
	check_eq "prev-root regression: prev_anchor_tx reads writer's tx_id field" \
		"$FIXTURE_PREV_TX" "$(jq -r '.identity_branch.prev_anchor_tx // "null"' "$OUT5" 2>/dev/null)"
else
	fail "prev-root regression: script failed unexpectedly; stderr: $(cat "$STDERR5" 2>/dev/null | tr '\n' '|')"
fi

# ---- case 6: MULTI-LINE anchor-history.jsonl (cycle 3 + cycle 4) -> the
# TAIL (cycle 4) line's root/tx are selected, not the first line. M-2
# regression extension: case 5 above only ever fixtured a single line, which
# cannot distinguish "reads the last line" from "reads the only line". This
# fixture uses two real-shaped lines so a regression to "always reads line
# 1" (or any non-tail line) would fail loudly here.
ROOT_C3="$(printf 'a3%.0s' {1..32})"   # 64 hex chars
TX_C3="$(printf 'b3%.0s' {1..32})"
ROOT_C4="$(printf 'a4%.0s' {1..32})"
TX_C4="$(printf 'b4%.0s' {1..32})"
ANCHOR_HISTORY_MULTI="$TMP/fixtures/anchor-history-multi.jsonl"
cat > "$ANCHOR_HISTORY_MULTI" <<EOF
{"schema_version":2,"event_type":"cyclestart","cycle_number":3,"dag_root_hash":"$ROOT_C3","memo_prefix":"fya1c3","tx_id":"$TX_C3","block_num":100000001,"block_time":"2026-07-04T04:00:00Z","verification_status":"live","prev_anchor_tx_id":null}
{"schema_version":2,"event_type":"cyclestart","cycle_number":4,"dag_root_hash":"$ROOT_C4","memo_prefix":"fya1c4","tx_id":"$TX_C4","block_num":100000050,"block_time":"2026-08-04T04:00:00Z","verification_status":"live","prev_anchor_tx_id":"$TX_C3"}
EOF

OUT6="$TMP/out/anchor-source-run6.json"
STDERR6="$TMP/out/run6.stderr"
PATH="$FARM_VALID:$PATH" ANCHOR_HISTORY_JSONL="$ANCHOR_HISTORY_MULTI" \
	bash "$SCRIPT" --out="$OUT6" >"$TMP/out/run6.stdout" 2>"$STDERR6"
RC6=$?
check_eq "multi-line history: exit 0" "0" "$RC6"
if [ "$RC6" -eq 0 ]; then
	check_eq "multi-line history: prev_anchor_root reads the TAIL (cycle 4) line, not cycle 3" \
		"$ROOT_C4" "$(jq -r '.identity_branch.prev_anchor_root // "null"' "$OUT6" 2>/dev/null)"
	check_eq "multi-line history: prev_anchor_tx reads the TAIL (cycle 4) line, not cycle 3" \
		"$TX_C4" "$(jq -r '.identity_branch.prev_anchor_tx // "null"' "$OUT6" 2>/dev/null)"
else
	fail "multi-line history: script failed unexpectedly; stderr: $(cat "$STDERR6" 2>/dev/null | tr '\n' '|')"
fi

# ---- case 7: multi-line history with a TRAILING BLANK LINE (LF LF at EOF)
# -> must still resolve to the same cycle-4 root/tx as case 6, not silently
# degrade to null. This is the exact M-2 bug shape: `tail -1` on a file
# ending in a blank line returns "", which the old code accepted as "no
# prev anchor" instead of failing loudly or skipping the blank line.
ANCHOR_HISTORY_TRAILING_BLANK="$TMP/fixtures/anchor-history-trailing-blank.jsonl"
printf '%s\n\n' "$(cat "$ANCHOR_HISTORY_MULTI")" > "$ANCHOR_HISTORY_TRAILING_BLANK"
# Harness sanity: confirm the fixture really does end in a blank line
# (otherwise this case would not exercise the bug at all).
if [ -n "$(tail -1 "$ANCHOR_HISTORY_TRAILING_BLANK")" ]; then
	fail "harness: trailing-blank fixture does not actually end in a blank line — refusing to trust case 7"
fi

OUT7="$TMP/out/anchor-source-run7.json"
STDERR7="$TMP/out/run7.stderr"
PATH="$FARM_VALID:$PATH" ANCHOR_HISTORY_JSONL="$ANCHOR_HISTORY_TRAILING_BLANK" \
	bash "$SCRIPT" --out="$OUT7" >"$TMP/out/run7.stdout" 2>"$STDERR7"
RC7=$?
check_eq "trailing-blank-line history: exit 0" "0" "$RC7"
if [ "$RC7" -eq 0 ]; then
	check_eq "trailing-blank-line history: prev_anchor_root still reads the last VALID (cycle 4) line" \
		"$ROOT_C4" "$(jq -r '.identity_branch.prev_anchor_root // "null"' "$OUT7" 2>/dev/null)"
	check_eq "trailing-blank-line history: prev_anchor_tx still reads the last VALID (cycle 4) line" \
		"$TX_C4" "$(jq -r '.identity_branch.prev_anchor_tx // "null"' "$OUT7" 2>/dev/null)"
else
	fail "trailing-blank-line history: script failed unexpectedly (M-2 regression); stderr: $(cat "$STDERR7" 2>/dev/null | tr '\n' '|')"
fi

# ---- case 8: NON-EMPTY history + UNKNOWN field names -> new M-2 fail-closed
# exit code (10), NOT a silent prev_anchor_root: null. This is the other half
# of the M-2 bug shape: a writer/reader field-name drift must be loud, not
# silently indistinguishable from genesis.
ANCHOR_HISTORY_UNKNOWN_FIELDS="$TMP/fixtures/anchor-history-unknown-fields.jsonl"
cat > "$ANCHOR_HISTORY_UNKNOWN_FIELDS" <<'EOF'
{"schema_version":2,"event_type":"cyclestart","cycle_number":4,"some_future_hash_field":"deadbeef","transaction_ref":"deadbeef"}
EOF

OUT8="$TMP/out/anchor-source-run8.json"
STDERR8="$TMP/out/run8.stderr"
PATH="$FARM_VALID:$PATH" ANCHOR_HISTORY_JSONL="$ANCHOR_HISTORY_UNKNOWN_FIELDS" \
	bash "$SCRIPT" --out="$OUT8" >"$TMP/out/run8.stdout" 2>"$STDERR8"
RC8=$?
check_eq "unknown-field history: fail-closed exit 10 (M-2), not silent null" "10" "$RC8"
if [ -e "$OUT8" ]; then
	fail "unknown-field history: must NOT write $OUT8"
else
	pass "unknown-field history: did not write the canonical file"
fi
grep -q "fail-closed" "$STDERR8" \
	&& pass "unknown-field history: error message identifies the fail-closed guard" \
	|| fail "unknown-field history: fail-closed message missing; got: $(cat "$STDERR8" 2>/dev/null | tr '\n' '|')"

# ---- case 9: GENUINELY EMPTY (0-byte, touched) anchor-history.jsonl file ->
# still genesis (null), exit 0 — distinct from case 8 (non-empty history
# where extraction fails) and from the "file absent entirely" happy-path
# case 1 above. Both empty-file and absent-file must take the same
# behavior: the `[ -s "$ANCHOR_HISTORY_JSONL" ]` size check in the script
# treats them identically.
ANCHOR_HISTORY_EMPTY_FILE="$TMP/fixtures/anchor-history-empty.jsonl"
: > "$ANCHOR_HISTORY_EMPTY_FILE"

OUT9="$TMP/out/anchor-source-run9.json"
STDERR9="$TMP/out/run9.stderr"
PATH="$FARM_VALID:$PATH" ANCHOR_HISTORY_JSONL="$ANCHOR_HISTORY_EMPTY_FILE" \
	bash "$SCRIPT" --out="$OUT9" >"$TMP/out/run9.stdout" 2>"$STDERR9"
RC9=$?
check_eq "empty (0-byte) history file: exit 0 (genesis, unchanged behavior)" "0" "$RC9"
if [ "$RC9" -eq 0 ]; then
	check_eq "empty (0-byte) history file: prev_anchor_root null" \
		"null" "$(jq -r '.identity_branch.prev_anchor_root // "null"' "$OUT9" 2>/dev/null)"
	check_eq "empty (0-byte) history file: prev_anchor_tx null" \
		"null" "$(jq -r '.identity_branch.prev_anchor_tx // "null"' "$OUT9" 2>/dev/null)"
else
	fail "empty (0-byte) history file: script failed unexpectedly; stderr: $(cat "$STDERR9" 2>/dev/null | tr '\n' '|')"
fi

# ---- case 10: WHITESPACE-ONLY (non-zero-size, but no non-blank line at all)
# anchor-history.jsonl -> fail-closed exit 10, NOT the same silent-genesis
# treatment as the genuinely-empty (0-byte) case 9 above. Review round 1
# finding: the fall-through for "file has bytes but only blank lines" used
# to be a no-op comment (implicit fall-through to genesis null), which is
# the exact M-2 bug shape applied to a different trigger (whitespace-only
# content instead of an unrecognized field name) — a truncated or
# partially-written history file must not be silently indistinguishable
# from genuine genesis either.
ANCHOR_HISTORY_WHITESPACE_ONLY="$TMP/fixtures/anchor-history-whitespace-only.jsonl"
printf '\n\n   \n\t\n' > "$ANCHOR_HISTORY_WHITESPACE_ONLY"
# Harness sanity: confirm the fixture really is non-zero-size (otherwise
# this case would degrade into a duplicate of case 9, not case 10).
if [ ! -s "$ANCHOR_HISTORY_WHITESPACE_ONLY" ]; then
	fail "harness: whitespace-only fixture is unexpectedly 0 bytes — refusing to trust case 10"
fi

OUT10="$TMP/out/anchor-source-run10.json"
STDERR10="$TMP/out/run10.stderr"
PATH="$FARM_VALID:$PATH" ANCHOR_HISTORY_JSONL="$ANCHOR_HISTORY_WHITESPACE_ONLY" \
	bash "$SCRIPT" --out="$OUT10" >"$TMP/out/run10.stdout" 2>"$STDERR10"
RC10=$?
check_eq "whitespace-only history: fail-closed exit 10 (M-2), not silent genesis" "10" "$RC10"
if [ -e "$OUT10" ]; then
	fail "whitespace-only history: must NOT write $OUT10"
else
	pass "whitespace-only history: did not write the canonical file"
fi
grep -q "fail-closed" "$STDERR10" \
	&& pass "whitespace-only history: error message identifies the fail-closed guard" \
	|| fail "whitespace-only history: fail-closed message missing; got: $(cat "$STDERR10" 2>/dev/null | tr '\n' '|')"
grep -q "whitespace-only content is not genesis" "$STDERR10" \
	&& pass "whitespace-only history: error message explicitly distinguishes from genuine genesis" \
	|| fail "whitespace-only history: message does not distinguish from genesis; got: $(cat "$STDERR10" 2>/dev/null | tr '\n' '|')"

# ---- summary -----------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-gen-anchor-source.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
