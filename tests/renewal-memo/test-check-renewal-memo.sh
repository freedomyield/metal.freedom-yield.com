#!/usr/bin/env bash
# tests/renewal-memo/test-check-renewal-memo.sh — suite for
# scripts/check-renewal-memo.sh (cycle transition unit 11, the completion
# criterion added by the operator decision of 2026-10-08).
#
# CHAIN: none — every case builds its memo and ledger fixtures in a mktemp
#        dir and points --memo-dir= / --history= at them. The real
#        docs/tasks/ is git-ignored and absent in CI; this suite never reads it.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction at all).
#
# Cases:
#   1. complete memo (via --history= and via --anchor-tx=)  -> 0
#   2. memo missing / memo dir missing                      -> 3
#   3. memo without the anchor tx (key absent)              -> 4
#   4. memo with the PREVIOUS cycle's anchor tx             -> 4
#   5. memo with a stale State (Current phase: 1)           -> 4
#   6. memo with a <placeholder> outcome value              -> 4
#   7. ledger without a mainnet line for the cycle          -> 5
#   8. usage errors                                         -> 2
#   M. MUTATION: each check is disabled in a copy of the script and the case
#      that guards it must flip — proof the cases above are not tautologies.
#      Each mutation first asserts its target line was found exactly once, so
#      a reformat of the script turns this suite red instead of silently
#      testing an unmutated copy.
#
# Usage:
#   bash tests/renewal-memo/test-check-renewal-memo.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-renewal-memo.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

finish() {
	echo "test-check-renewal-memo.sh summary: PASS=$PASS  FAIL=$FAIL"
	if [ "$FAIL" -eq 0 ]; then
		echo "RESULT: PASS"
		exit 0
	fi
	echo "RESULT: FAIL"
	exit 1
}

[ -r "$CHECKER" ] || { bad "scripts/check-renewal-memo.sh not readable"; finish; }
command -v jq >/dev/null 2>&1 || { bad "jq is required for this suite"; finish; }

TMP="$(mktemp -d -t check-renewal-memo-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

CYCLE=7
TX_NEW="$(printf 'c%.0s' $(seq 1 64))"
TX_OLD="$(printf 'b%.0s' $(seq 1 64))"
TX_TESTNET="$(printf 'e%.0s' $(seq 1 64))"

# Synthetic ledger: cycle 6 (previous), cycle 7 on mainnet, and a cycle-7
# TESTNET line that must be ignored (otherwise "exactly one tx id" fails).
LEDGER="${TMP}/anchor-history.jsonl"
cat > "$LEDGER" <<EOF
{"cycle_number":6,"network":"mainnet-a","tx_id":"${TX_OLD}"}
{"cycle_number":7,"network":"mainnet-a","tx_id":"${TX_NEW}"}
{"cycle_number":7,"network":"testnet-a","tx_id":"${TX_TESTNET}"}
EOF
LEDGER_SHORT="${TMP}/anchor-history-short.jsonl"
head -1 "$LEDGER" > "$LEDGER_SHORT"

# write_memo <dir> <phase> <anchor tx line value | __OMIT__> [keys-locked value]
write_memo() {
	local dir="$1" phase="$2" tx="$3" locked="${4:-testnet + mainnet locked、identity 鍵は agent から削除済}"
	mkdir -p "$dir"
	{
		printf '# Validator Renew — Cycle %s\n\n' "$CYCLE"
		printf '## State\n- Current phase: %s\n- Last update: 2026-11-06T06:00Z\n\n' "$phase"
		printf '## Phase 1: 準備 check\n- PASS fixture\n\n'
		printf '## 結果\n'
		printf -- '- registration tx: 2Fixture1111111111111111111111111111111111111111\n'
		printf -- '- self stake: 1 METAL (fixture)\n'
		printf -- '- endTime: 1800000000 (fixture)\n'
		[ "$tx" = "__OMIT__" ] || printf -- '- anchor tx: %s\n' "$tx"
		printf -- '- verification: 完了判定 ①〜⑤ PASS (fixture)\n'
		printf -- '- keys locked: %s\n' "$locked"
	} > "${dir}/validator-renew-cycle-${CYCLE}.md"
}

# expect <name> <want-rc> <checker> <args...>
expect() {
	local name="$1" want="$2" checker="$3" rc
	shift 3
	bash "$checker" "$@" > "${TMP}/out.txt" 2> "${TMP}/err.txt"
	rc=$?
	if [ "$rc" -eq "$want" ]; then
		ok "${name} -> exit ${rc}"
	else
		bad "${name}: expected exit ${want}, got ${rc}: $(head -3 "${TMP}/err.txt" | tr '\n' ' ')"
	fi
}

D_OK="${TMP}/ok"; write_memo "$D_OK" "完了 (cycle 7 転換完了)" "${TX_NEW} (fya1c7)"
D_NOTX="${TMP}/notx"; write_memo "$D_NOTX" "完了" "__OMIT__"
D_OLDTX="${TMP}/oldtx"; write_memo "$D_OLDTX" "完了" "$TX_OLD"
D_STALE="${TMP}/stale"; write_memo "$D_STALE" "1 (完了判定 待ち)" "$TX_NEW"
D_PH="${TMP}/placeholder"; write_memo "$D_PH" "完了" "$TX_NEW" "<testnet / mainnet>"
D_EMPTY="${TMP}/empty-dir"; mkdir -p "$D_EMPTY"

# ---- 1. complete --------------------------------------------------------------
expect "complete memo, tx resolved from --history=" 0 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_OK"
grep -q '^RESULT: COMPLETE' "${TMP}/out.txt" && ok "complete memo prints RESULT: COMPLETE" || bad "complete memo did not print RESULT: COMPLETE"
expect "complete memo, tx given as --anchor-tx=" 0 "$CHECKER" "$CYCLE" --anchor-tx="$TX_NEW" --memo-dir="$D_OK"

# ---- 2. missing ----------------------------------------------------------------
expect "memo file missing" 3 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_EMPTY"
grep -q 'validator-renew-cycle-7.md' "${TMP}/err.txt" && ok "missing memo names the path it looked for" || bad "missing memo message does not name the path"
expect "memo dir missing (docs/tasks/ absent, as in CI)" 3 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="${TMP}/no-such-dir"

# ---- 3/4. anchor tx -------------------------------------------------------------
expect "memo without the anchor tx line" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_NOTX"
grep -q "anchor tx" "${TMP}/err.txt" && ok "the missing-tx failure names the 'anchor tx' key" || bad "the missing-tx failure does not name the key"
expect "memo with the previous cycle's anchor tx" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_OLDTX"

# ---- 5. stale State ---------------------------------------------------------------
expect "memo with stale State (Current phase: 1)" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_STALE"
grep -q 'State is stale' "${TMP}/err.txt" && ok "the stale-State failure says so" || bad "the stale-State failure is not reported as such"

# ---- 6. placeholder value ---------------------------------------------------------
expect "memo with a <placeholder> outcome value" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_PH"

# ---- 7. ledger cannot resolve the cycle ---------------------------------------------
expect "ledger has no mainnet line for the cycle" 5 "$CHECKER" "$CYCLE" --history="$LEDGER_SHORT" --memo-dir="$D_OK"
expect "ledger unreadable" 5 "$CHECKER" "$CYCLE" --history="${TMP}/nope.jsonl" --memo-dir="$D_OK"

# ---- 8. usage ----------------------------------------------------------------------
expect "no expected tx source" 2 "$CHECKER" "$CYCLE" --memo-dir="$D_OK"
expect "non-numeric cycle" 2 "$CHECKER" "x" --anchor-tx="$TX_NEW" --memo-dir="$D_OK"
expect "short --anchor-tx" 2 "$CHECKER" "$CYCLE" --anchor-tx=abc --memo-dir="$D_OK"

# ---- M. mutation proof ----------------------------------------------------------------
# mutate <tag> <sed-expr> <case-name> <want-rc-of-mutant> <args...>
# The mutant is the checker with the line tagged "# MUT:<tag>" rewritten; the
# guarding case, which exits 3/4 against the real script, must now exit with
# <want-rc-of-mutant> instead.
mutate() {
	local tag="$1" expr="$2" name="$3" want="$4" mut rc hits
	shift 4
	hits="$(grep -c "# MUT:${tag}\$" "$CHECKER" || true)"
	if [ "$hits" -ne 1 ]; then
		bad "mutation ${tag}: target line found ${hits} times, expected 1 — the mutant would not be testing anything"
		return
	fi
	mut="${TMP}/mutant-${tag}.sh"
	sed "/# MUT:${tag}\$/${expr}" "$CHECKER" > "$mut"
	if cmp -s "$CHECKER" "$mut"; then
		bad "mutation ${tag}: sed changed nothing"
		return
	fi
	bash "$mut" "$@" > /dev/null 2>&1
	rc=$?
	if [ "$rc" -eq "$want" ]; then
		ok "mutation ${tag}: with the check disabled, '${name}' flips to exit ${rc} (the case is not a tautology)"
	else
		bad "MUTATION NOT CAUGHT ${tag}: '${name}' exits ${rc} with the check disabled, expected ${want}"
	fi
}

# exists: drop the file-existence check -> the missing memo is no longer exit 3.
mutate exists 's/\[ ! -f "\$MEMO" \]/false/' "memo file missing" 4 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_EMPTY"
# state: accept any Current phase -> the stale memo passes.
mutate state 's/完了\*)/*)/' "memo with stale State" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_STALE"
# keys: never flag a missing key -> the placeholder memo passes.
mutate keys 's/if ! is_real_value "\$v"; then/if false; then/' "memo with a <placeholder> outcome value" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_PH"
# tx: accept any anchor tx value -> the previous cycle's tx passes.
mutate tx 's/\*"\$ANCHOR_TX"\*)/*)/' "memo with the previous cycle's anchor tx" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_OLDTX"

# The checker is read-only: the fixture memo must be byte-identical afterwards.
SUM_BEFORE="$(cksum < "${D_OK}/validator-renew-cycle-${CYCLE}.md")"
bash "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_OK" > /dev/null 2>&1
SUM_AFTER="$(cksum < "${D_OK}/validator-renew-cycle-${CYCLE}.md")"
[ "$SUM_BEFORE" = "$SUM_AFTER" ] && ok "the checker leaves the memo untouched" || bad "the checker modified the memo"

finish
