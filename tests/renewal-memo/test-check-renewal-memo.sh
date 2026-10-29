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
#   4. anchor tx: previous cycle's / two ids / a 65-hex run -> 4; upper-case
#      copy of the right id                                 -> 0
#   5. State: stale (Current phase: 1), 完了していない, 完了 (未完了…) -> 4
#   6. memo with a <placeholder> outcome value              -> 4
#  6b. day-of memo whose value says nothing was recorded
#      (記録なし / 未確認 / unknown / TBD / - / N/A …)        -> 4, key named;
#      a CB58 registration id that happens to contain "tbD" -> 0
#  6c. the same values with the exact retroactive marker in State -> 0;
#      a malformed marker, or the marker outside State       -> 4
#  6d. retroactive memo without a real registration / anchor id,
#      day-of memo whose registration tx is not CB58         -> 4
#  6e. THE STEP 11 TEMPLATE, extracted from docs/CYCLE_GATE.md: copied
#      verbatim -> 4 with every key named; with its <> stripped -> 4 with
#      every outcome key named; with every <…> filled in      -> 0
#   7. ledger: no mainnet line for the cycle / unreadable / a malformed
#      JSON line                                             -> 5
#   8. usage errors                                         -> 2
#   M. MUTATION: each check is disabled in a copy of the script and the case
#      that guards it must flip — proof the cases above are not tautologies.
#      Each mutation first asserts its target line was found exactly once, so
#      a reformat of the script turns this suite red instead of silently
#      testing an unmutated copy.
#
# Usage:
#   bash tests/renewal-memo/test-check-renewal-memo.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-renewal-memo.sh"
CYCLE_GATE_DOC="${REPO_ROOT}/docs/CYCLE_GATE.md"

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
[ -r "$CYCLE_GATE_DOC" ] || { bad "docs/CYCLE_GATE.md not readable"; finish; }
command -v jq >/dev/null 2>&1 || { bad "jq is required for this suite"; finish; }

TMP="$(mktemp -d -t check-renewal-memo-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

CYCLE=7
TX_NEW="$(printf 'c%.0s' $(seq 1 64))"
TX_OLD="$(printf 'b%.0s' $(seq 1 64))"
TX_TESTNET="$(printf 'e%.0s' $(seq 1 64))"
REG_OK="2Fixture1111111111111111111111111111111111111111"

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
LEDGER_BROKEN="${TMP}/anchor-history-broken.jsonl"
{ cat "$LEDGER"; printf '{"cycle_number":8,"network":"mainnet-a","tx_id":"%s"\n' "$TX_OLD"; } > "$LEDGER_BROKEN"

# write_memo <dir> <phase> <anchor tx line value | __OMIT__> [keys-locked value]
write_memo() {
	local dir="$1" phase="$2" tx="$3" locked="${4:-testnet + mainnet locked、identity 鍵は agent から削除済}"
	mkdir -p "$dir"
	{
		printf '# Validator Renew — Cycle %s\n\n' "$CYCLE"
		printf '## State\n- Current phase: %s\n- Last update: 2026-11-06T06:00Z\n' "$phase"
		[ -z "${MEMO_RETRO:-}" ] || printf -- '%s\n' "$MEMO_RETRO"
		printf '\n## Phase 1: 準備 check\n- PASS fixture\n\n'
		printf '## 結果\n'
		printf -- '- registration tx: %s\n' "${MEMO_REG:-$REG_OK}"
		printf -- '- self stake: 1 METAL (fixture)\n'
		printf -- '- endTime: 1800000000 (fixture)\n'
		[ "$tx" = "__OMIT__" ] || printf -- '- anchor tx: %s\n' "$tx"
		printf -- '- verification: %s\n' "${MEMO_VERIF:-完了判定 ①〜⑤ PASS (fixture)}"
		printf -- '- keys locked: %s\n' "$locked"
	} > "${dir}/validator-renew-cycle-${CYCLE}.md"
}

# expect <name> <want-rc> <checker> <args...>
expect() {
	local name="$1" want="$2" checker="$3" rc=0
	shift 3
	bash "$checker" "$@" > "${TMP}/out.txt" 2> "${TMP}/err.txt" || rc=$?
	if [ "$rc" -eq "$want" ]; then
		ok "${name} -> exit ${rc}"
	else
		bad "${name}: expected exit ${want}, got ${rc}: $(head -3 "${TMP}/err.txt" | tr '\n' ' ')"
	fi
}

# names <label> <key>... — the last run's stderr names every key given.
names() {
	local label="$1" k missing=""
	shift
	for k in "$@"; do
		grep -qF -- "'${k}:'" "${TMP}/err.txt" || missing="${missing} '${k}'"
	done
	if [ -z "$missing" ]; then
		ok "${label}: the failure names every key ($*)"
	else
		bad "${label}: the failure does not name${missing}"
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
names "missing anchor tx" "anchor tx"
expect "memo with the previous cycle's anchor tx" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_OLDTX"
D_TWOTX="${TMP}/twotx"; write_memo "$D_TWOTX" "完了" "${TX_OLD} (not ${TX_NEW})"
expect "anchor tx naming the previous id AND this cycle's (no substring match)" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_TWOTX"
D_LONGTX="${TMP}/longtx"; write_memo "$D_LONGTX" "完了" "c${TX_NEW}"
expect "anchor tx that is a 65-hex run containing this cycle's id" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_LONGTX"
D_UPTX="${TMP}/uptx"; write_memo "$D_UPTX" "完了" "$(printf '%s' "$TX_NEW" | tr 'a-f' 'A-F')"
expect "anchor tx written in upper case is still this cycle's id" 0 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_UPTX"

# ---- 5. State ---------------------------------------------------------------------
expect "memo with stale State (Current phase: 1)" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_STALE"
grep -q 'State is stale' "${TMP}/err.txt" && ok "the stale-State failure says so" || bad "the stale-State failure is not reported as such"
D_NEG1="${TMP}/neg1"; write_memo "$D_NEG1" "完了していない" "$TX_NEW"
expect "Current phase: 完了していない" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_NEG1"
D_NEG2="${TMP}/neg2"; write_memo "$D_NEG2" "完了 (未完了の項目あり)" "$TX_NEW"
expect "Current phase: 完了 (未完了の項目あり)" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_NEG2"
grep -q 'negates completion' "${TMP}/err.txt" && ok "the negated State is reported as such" || bad "the negated State is not reported as such"
D_FW="${TMP}/fullwidth"; write_memo "$D_FW" "完了（cycle 7 転換完了）" "$TX_NEW"
expect "Current phase: 完了（…） with a full-width bracket" 0 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_FW"

# ---- 6. placeholder value ---------------------------------------------------------
expect "memo with a <placeholder> outcome value" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_PH"
names "<placeholder> value" "keys locked"

# ---- 6b. "nothing recorded" values: red on a day-of memo -------------------------
RETRO_LINE='- Retroactive: yes (事後作成 2026-10-08)'
i=0
for ph in '記録なし' '未確認' 'unknown' 'Unknown (not captured)' 'TBD' '-' 'N/A' 'testnet lock は記録なし'; do
	i=$((i + 1))
	d="${TMP}/dayof-ph-${i}"
	write_memo "$d" "完了" "$TX_NEW" "$ph"
	expect "day-of memo with keys locked: '${ph}'" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$d"
	names "day-of '${ph}'" "keys locked"
done
D_PH_VERIF="${TMP}/dayof-ph-verif"
MEMO_VERIF='①〜⑤ の実測値は記録なし' write_memo "$D_PH_VERIF" "完了" "$TX_NEW"
expect "day-of memo with verification: '…記録なし'" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_PH_VERIF"
# A CB58 id may contain "tbd" by chance; that is not a placeholder.
REG_TBD="2tbD$(printf '1%.0s' $(seq 1 44))"
D_REG_TBD="${TMP}/reg-tbd"
MEMO_REG="$REG_TBD" write_memo "$D_REG_TBD" "完了" "$TX_NEW"
expect "day-of memo whose CB58 registration id contains 'tbD'" 0 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_REG_TBD"

# ---- 6c. the same values pass ONLY with the exact retroactive marker --------------
D_RETRO="${TMP}/retro-ok"
MEMO_RETRO="$RETRO_LINE" MEMO_VERIF='checklist 5/5、項目ごとの値は記録なし' \
	write_memo "$D_RETRO" "完了 (事後作成)" "$TX_NEW" 'mainnet locked、testnet は未確認'
expect "retroactive memo with '記録なし' / '未確認' values" 0 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_RETRO"
D_RETRO_BAD="${TMP}/retro-malformed"
MEMO_RETRO='- Retroactive: yes' MEMO_VERIF='記録なし' write_memo "$D_RETRO_BAD" "完了" "$TX_NEW"
expect "malformed retroactive marker does not unlock placeholders" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_RETRO_BAD"
grep -q 'malformed retroactive marker' "${TMP}/err.txt" && ok "the malformed marker is reported as such" || bad "the malformed marker is not reported"
D_RETRO_OUT="${TMP}/retro-outside-state"
MEMO_VERIF='記録なし' write_memo "$D_RETRO_OUT" "完了" "$TX_NEW"
printf '\n%s\n' "$RETRO_LINE" >> "${D_RETRO_OUT}/validator-renew-cycle-${CYCLE}.md"
expect "the marker outside the State section does not count" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_RETRO_OUT"

# ---- 6d. the IDs must be real even in a retroactive memo ---------------------------
D_RETRO_NOREG="${TMP}/retro-noreg"
MEMO_RETRO="$RETRO_LINE" MEMO_REG='記録なし' write_memo "$D_RETRO_NOREG" "完了" "$TX_NEW"
expect "retroactive memo with registration tx '記録なし'" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_RETRO_NOREG"
names "retroactive without a registration id" "registration tx"
D_RETRO_NOTX="${TMP}/retro-notx"
MEMO_RETRO="$RETRO_LINE" write_memo "$D_RETRO_NOTX" "完了" "記録なし"
expect "retroactive memo with anchor tx '記録なし'" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_RETRO_NOTX"
D_DAYOF_SHORTREG="${TMP}/dayof-shortreg"
MEMO_REG='2abc (fixture)' write_memo "$D_DAYOF_SHORTREG" "完了" "$TX_NEW"
expect "day-of memo whose registration tx is not a CB58 id" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_DAYOF_SHORTREG"

# ---- 6e. the step 11 template itself, taken from docs/CYCLE_GATE.md -----------------
# Extracted, not transcribed: the first ```markdown block after step 11's
# heading, de-indented. If the doc's template changes, these cases follow it.
TEMPLATE="$(awk '
	/^11\. \*\*Mac — record the outcome in the working memo\.\*\*/ { s = 1; next }
	s && /^   ```markdown$/ { f = 1; next }
	f && /^   ```$/ { exit }
	f { sub(/^   /, ""); print }
' "$CYCLE_GATE_DOC")"
if printf '%s\n' "$TEMPLATE" | grep -q '^## 結果$' && printf '%s\n' "$TEMPLATE" | grep -q '^## State$'; then
	ok "extracted the step 11 memo template from docs/CYCLE_GATE.md ($(printf '%s\n' "$TEMPLATE" | grep -c '^- ') key lines)"
else
	bad "could not extract the step 11 memo template from docs/CYCLE_GATE.md — the template cases would be vacuous"
fi
OUT_KEYS=("registration tx" "self stake" "endTime" "anchor tx" "verification" "keys locked")
write_template() { # <dir> <body>
	mkdir -p "$1"
	printf '# Validator Renew — Cycle %s\n\n%s\n' "$CYCLE" "$2" > "${1}/validator-renew-cycle-${CYCLE}.md"
}
D_TPL="${TMP}/template-verbatim"
write_template "$D_TPL" "$TEMPLATE"
expect "the step 11 template copied verbatim" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_TPL"
names "verbatim template" "${OUT_KEYS[@]}"
grep -q "'Current phase:' still holds a template placeholder" "${TMP}/err.txt" && \
	ok "verbatim template: the <N+1> in 'Current phase:' is reported" || \
	bad "verbatim template: the <N+1> in 'Current phase:' is not reported"
D_TPL_STRIP="${TMP}/template-stripped"
write_template "$D_TPL_STRIP" "$(printf '%s\n' "$TEMPLATE" | tr -d '<>')"
expect "the step 11 template with its <> stripped" 4 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_TPL_STRIP"
names "stripped template" "${OUT_KEYS[@]}"
# Filled in, the same template passes — it is a usable template, not a trap.
FILLED="$(printf '%s\n' "$TEMPLATE" | sed \
	-e "s/^- Current phase: .*/- Current phase: 完了 (cycle ${CYCLE} 転換完了)/" \
	-e "s/^- Last update: .*/- Last update: 2026-11-06T06:00Z/" \
	-e "s/^- registration tx: .*/- registration tx: ${REG_OK}/" \
	-e "s/^- self stake: .*/- self stake: 1 METAL/" \
	-e "s/^- endTime: .*/- endTime: 1800000000 (2027-01-15 17:00 JST)/" \
	-e "s/^- anchor tx: .*/- anchor tx: ${TX_NEW}/" \
	-e "s/^- verification: .*/- verification: ①〜⑤ PASS/" \
	-e "s/^- keys locked: .*/- keys locked: testnet + mainnet locked、identity 鍵は削除済/")"
D_TPL_FILLED="${TMP}/template-filled"
write_template "$D_TPL_FILLED" "$FILLED"
expect "the step 11 template with every <…> filled in" 0 "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_TPL_FILLED"

# ---- 7. ledger cannot resolve the cycle ---------------------------------------------
expect "ledger has no mainnet line for the cycle" 5 "$CHECKER" "$CYCLE" --history="$LEDGER_SHORT" --memo-dir="$D_OK"
expect "ledger unreadable" 5 "$CHECKER" "$CYCLE" --history="${TMP}/nope.jsonl" --memo-dir="$D_OK"
expect "ledger with a malformed JSON line (after the line that would resolve)" 5 "$CHECKER" "$CYCLE" --history="$LEDGER_BROKEN" --memo-dir="$D_OK"
grep -q 'is not valid JSON lines' "${TMP}/err.txt" && ok "the malformed ledger is reported as such" || bad "the malformed ledger is not reported as such"

# ---- 8. usage ----------------------------------------------------------------------
expect "no expected tx source" 2 "$CHECKER" "$CYCLE" --memo-dir="$D_OK"
expect "non-numeric cycle" 2 "$CHECKER" "x" --anchor-tx="$TX_NEW" --memo-dir="$D_OK"
expect "short --anchor-tx" 2 "$CHECKER" "$CYCLE" --anchor-tx=abc --memo-dir="$D_OK"

# ---- M. mutation proof ----------------------------------------------------------------
# make_mutant <tag> <sed-expr> — sets MUT_PATH to the checker with the line
# tagged "# MUT:<tag>" rewritten, or to "" (and records a FAIL) if the target
# is not there exactly once or the edit changed nothing. Not called in a
# command substitution, so its FAILs count.
make_mutant() {
	local tag="$1" expr="$2" hits
	MUT_PATH=""
	hits="$(grep -c "# MUT:${tag}\$" "$CHECKER" || true)"
	if [ "$hits" -ne 1 ]; then
		bad "mutation ${tag}: target line found ${hits} times, expected 1 — the mutant would not be testing anything"
		return 0
	fi
	sed "/# MUT:${tag}\$/${expr}" "$CHECKER" > "${TMP}/mutant-${tag}.sh"
	if cmp -s "$CHECKER" "${TMP}/mutant-${tag}.sh"; then
		bad "mutation ${tag}: sed changed nothing"
		return 0
	fi
	MUT_PATH="${TMP}/mutant-${tag}.sh"
}

# mutate <tag> <sed-expr> <case-name> <want> <args...>
# <want> is the mutant's exit code, or "!N" for "anything but N".
mutate() {
	local tag="$1" expr="$2" name="$3" want="$4" mut rc=0 hit=0
	shift 4
	make_mutant "$tag" "$expr"
	mut="$MUT_PATH"
	[ -n "$mut" ] || return 0
	bash "$mut" "$@" > /dev/null 2>&1 || rc=$?
	case "$want" in
	!*) [ "$rc" -ne "${want#!}" ] && hit=1 ;;
	*) [ "$rc" -eq "$want" ] && hit=1 ;;
	esac
	if [ "$hit" -eq 1 ]; then
		ok "mutation ${tag}: with the check disabled, '${name}' flips to exit ${rc} (the case is not a tautology)"
	else
		bad "MUTATION NOT CAUGHT ${tag}: '${name}' exits ${rc} with the check disabled, expected ${want}"
	fi
}

# mutate_unnamed <tag> <sed-expr> <case-name> <key> <args...> — the real
# checker names <key> for this case; the mutant must not. For checks backed
# by another check on the same key (the exit code alone would not move).
mutate_unnamed() {
	local tag="$1" expr="$2" name="$3" key="$4" mut
	shift 4
	make_mutant "$tag" "$expr"
	mut="$MUT_PATH"
	[ -n "$mut" ] || return 0
	bash "$mut" "$@" > /dev/null 2> "${TMP}/mut-err.txt" || true
	if grep -qF -- "$key" "${TMP}/mut-err.txt"; then
		bad "MUTATION NOT CAUGHT ${tag}: '${name}' still reports '${key}' with the check disabled"
	else
		ok "mutation ${tag}: with the check disabled, '${name}' no longer reports '${key}' (the case is not a tautology)"
	fi
}

mutate exists 's/\[ ! -f "\$MEMO" \]/false/' "memo file missing" '!3' \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_EMPTY"
mutate state "s/grep -qE .*; then/true; then/" "memo with stale State" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_STALE"
mutate negation "s/grep -qiE .*; then/false; then/" "Current phase: 完了 (未完了の項目あり)" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_NEG2"
mutate keys 's/if \[ -z "\$v" \]; then/if false; then/' "memo without the anchor tx line" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_NOTX"
mutate angle 's/grep -qE .*$/false/' "memo with a <placeholder> outcome value" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_PH"
mutate_unnamed angle 's/grep -qE .*$/false/' "the step 11 template copied verbatim" "'verification:' still holds a template placeholder" \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_TPL"
mutate_unnamed wording 's/return 0/:/' "the step 11 template with its <> stripped" "'verification:' still holds the step 11 template's wording" \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_TPL_STRIP"
mutate placeholder 's/\*記録なし\*/*NEVER-MATCHES*/' "day-of memo with verification '…記録なし'" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_PH_VERIF"
mutate wholeword "s/grep -qE .*\$/grep -qE '(unknown|tbd|n\\/a)'/" "day-of memo whose CB58 registration id contains 'tbD'" 4 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_REG_TBD"
mutate retro 's/if printf .*; then/if true; then/' "day-of memo with verification '…記録なし'" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_PH_VERIF"
mutate regid 's/&& ! printf .*; then/\&\& false; then/' "retroactive memo with registration tx '記録なし'" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_RETRO_NOREG"
mutate tx 's/if .*; then/if false; then/' "anchor tx naming the previous id AND this cycle's" 0 \
	"$CYCLE" --history="$LEDGER" --memo-dir="$D_TWOTX"
mutate_unnamed jsonparse 's/if ! JQ_ERR=.*; then/if false; then/' "ledger with a malformed JSON line" "is not valid JSON lines" \
	"$CYCLE" --history="$LEDGER_BROKEN" --memo-dir="$D_OK"

# The checker is read-only: the fixture memo must be byte-identical afterwards.
SUM_BEFORE="$(cksum < "${D_OK}/validator-renew-cycle-${CYCLE}.md")"
bash "$CHECKER" "$CYCLE" --history="$LEDGER" --memo-dir="$D_OK" > /dev/null 2>&1 || true
SUM_AFTER="$(cksum < "${D_OK}/validator-renew-cycle-${CYCLE}.md")"
[ "$SUM_BEFORE" = "$SUM_AFTER" ] && ok "the checker leaves the memo untouched" || bad "the checker modified the memo"

finish
