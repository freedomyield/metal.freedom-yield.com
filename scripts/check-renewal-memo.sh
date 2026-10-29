#!/usr/bin/env bash
# check-renewal-memo.sh — the last completion criterion of a cycle transition:
# the local working memo docs/tasks/validator-renew-cycle-<C>.md records the
# day's outcome and its State header says the transition is complete.
#
# WHY THIS EXISTS (operator decision 2026-10-08). On 2026-09-04 and 2026-10-07
# the second half of the transition was driven directly via docs/CYCLE_GATE.md
# rather than by the validator-renew agent, and the working memo was left
# behind: the cycle-5 memo was never written and the cycle-6 memo stopped at
# Phase 1, although the on-chain and public records were complete. From the
# 2026-11-06 transition on, a transition is NOT complete until this check
# passes — whoever drove it (the agent or the parent session).
#
# CHAIN: none — READ ONLY. Reads one local markdown file and, optionally, a
#        local copy of the published anchor-history.jsonl. No network, no SSH,
#        no writes, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction at all).
#
# docs/tasks/ is git-ignored on purpose (the memo is local working state). It
# is therefore absent in CI and in any fresh clone; this script treats an
# absent directory exactly like an absent memo (exit 3, with the path it
# looked at), and its tests point --memo-dir= at a temp dir.
#
# WHAT "COMPLETE" MEANS (canon: docs/CYCLE_GATE.md step 11, which carries the
# memo template):
#   1. the memo exists: <memo-dir>/validator-renew-cycle-<C>.md
#   2. its "## State" section has a "Current phase:" line whose value is
#      "完了" alone or "完了" followed by a space or a bracket — "Current phase:
#      1" is STALE (the cycle-6 state of 2026-10-07), and so is anything that
#      negates it (完了していない, 未完了, …)
#   3. its "## 結果" (outcome) section carries every one of these keys as a
#      "- <key>: <value>" line with a real value:
#        registration tx / self stake / endTime / anchor tx / verification /
#        keys locked
#      No value (and not "Current phase:") may still hold a template
#      placeholder "<…>" or the template's own instruction wording — copying
#      the step 11 template verbatim, or with the brackets stripped, fails.
#      No value may say that nothing was recorded (記録なし / 未確認 / 未記入 /
#      不明 / unknown / TBD / N/A / a bare "-" or 未) — UNLESS the State
#      section carries the exact line
#        - Retroactive: yes (事後作成 YYYY-MM-DD)
#      i.e. the memo was written after the day from records, and says so.
#      The Latin placeholder words are matched as whole words only, so an ID
#      that contains "tbd" by chance (CB58 can) is not mistaken for one.
#   4. the IDs are real, retroactive or not: "registration tx:" carries a
#      P-Chain tx id (CB58, 48-52 base58 characters), and "anchor tx:" carries
#      exactly one 64-hex id, equal to THE cycle-<C> anchor tx id — taken from
#      --anchor-tx=, or resolved from --history= (the mainnet line whose
#      cycle_number is C). A second, different 64-hex id in the same value is
#      a failure, not a match.
#
# Usage:
#   check-renewal-memo.sh <C> (--history=<anchor-history.jsonl> | --anchor-tx=<64hex>)
#                         [--memo-dir=<dir>]     default: <repo>/docs/tasks
#   <C> is the cycle INSCRIBED that day (N+1), the number in the memo's name.
#
# Exit codes:
#   0  COMPLETE
#   2  usage error
#   3  MISSING — the memo (or docs/tasks/ itself) does not exist
#   4  INCOMPLETE — the memo exists but fails one or more of 2-4 (each
#      failing item is listed on stderr)
#   5  the expected anchor tx id could not be resolved from --history=
#      (file unreadable, a malformed JSON line, no mainnet line for cycle C,
#      or more than one tx id)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
	echo "usage: check-renewal-memo.sh <cycle N+1> (--history=<anchor-history.jsonl> | --anchor-tx=<64hex>) [--memo-dir=<dir>]" >&2
	exit 2
}

CYCLE=""
HISTORY=""
ANCHOR_TX=""
MEMO_DIR="${REPO_ROOT}/docs/tasks"

for arg in "$@"; do
	case "$arg" in
	--history=*) HISTORY="${arg#*=}" ;;
	--anchor-tx=*) ANCHOR_TX="${arg#*=}" ;;
	--memo-dir=*) MEMO_DIR="${arg#*=}" ;;
	-h | --help) usage ;;
	-*)
		echo "check-renewal-memo: unknown option: ${arg}" >&2
		usage
		;;
	*)
		[ -z "$CYCLE" ] || usage
		CYCLE="$arg"
		;;
	esac
done

case "$CYCLE" in
'' | *[!0-9]* | 0*)
	echo "check-renewal-memo: <cycle> must be a positive integer (the cycle inscribed that day, N+1), got '${CYCLE}'" >&2
	usage
	;;
esac
if [ -n "$HISTORY" ] && [ -n "$ANCHOR_TX" ]; then
	echo "check-renewal-memo: pass --history= OR --anchor-tx=, not both" >&2
	usage
fi
if [ -z "$HISTORY" ] && [ -z "$ANCHOR_TX" ]; then
	echo "check-renewal-memo: the expected anchor tx id is required (--history= or --anchor-tx=) — without it any 64-hex string in the memo would pass" >&2
	usage
fi

# ---- expected anchor tx id ---------------------------------------------------
if [ -n "$HISTORY" ]; then
	if [ ! -r "$HISTORY" ]; then
		echo "check-renewal-memo: cannot read --history=${HISTORY}" >&2
		exit 5
	fi
	if ! command -v jq >/dev/null 2>&1; then
		echo "check-renewal-memo: jq is required for --history=" >&2
		exit 5
	fi
	# Fail closed on a malformed ledger: a line jq cannot parse is reported and
	# stops the check, rather than being skipped while earlier lines decide.
	if ! JQ_ERR="$(jq empty "$HISTORY" 2>&1)"; then # MUT:jsonparse
		echo "check-renewal-memo: ${HISTORY} is not valid JSON lines — ${JQ_ERR}" >&2
		exit 5
	fi
	# Mainnet lines only: a line without .network predates the field and is
	# mainnet (the published ledger has only ever carried mainnet anchors).
	if ! TX_IDS="$(jq -r --argjson c "$CYCLE" \
		'select(type == "object" and .cycle_number == $c and ((.network // "mainnet-a") == "mainnet-a")) | .tx_id // empty' \
		"$HISTORY" | sort -u)"; then
		echo "check-renewal-memo: could not read the cycle-${CYCLE} lines of ${HISTORY}" >&2
		exit 5
	fi
	TX_N="$(printf '%s' "$TX_IDS" | grep -c . || true)"
	if [ "$TX_N" -ne 1 ]; then
		echo "check-renewal-memo: ${HISTORY} has ${TX_N} distinct mainnet tx id(s) for cycle ${CYCLE}, expected exactly 1 — has unit 8.5 published today's anchor?" >&2
		exit 5
	fi
	ANCHOR_TX="$TX_IDS"
fi
case "$ANCHOR_TX" in
*[!0-9a-f]*)
	echo "check-renewal-memo: anchor tx id is not lowercase hex: '${ANCHOR_TX}'" >&2
	exit 2
	;;
esac
if [ "${#ANCHOR_TX}" -ne 64 ]; then
	echo "check-renewal-memo: anchor tx id must be 64 hex characters, got ${#ANCHOR_TX}" >&2
	exit 2
fi

# ---- 1. the memo exists --------------------------------------------------------
MEMO="${MEMO_DIR}/validator-renew-cycle-${CYCLE}.md"
if [ ! -d "$MEMO_DIR" ]; then
	echo "check-renewal-memo: MISSING — ${MEMO_DIR} does not exist (docs/tasks/ is git-ignored; the memo is written locally on the Mac that drove the day)" >&2
	echo "RESULT: MISSING (${MEMO})"
	exit 3
fi
if [ ! -f "$MEMO" ]; then # MUT:exists
	echo "check-renewal-memo: MISSING — ${MEMO} does not exist. Write it from the template in docs/CYCLE_GATE.md step 11." >&2
	echo "RESULT: MISSING (${MEMO})"
	exit 3
fi

PROBLEMS=0
problem() {
	PROBLEMS=$((PROBLEMS + 1))
	echo "check-renewal-memo: INCOMPLETE — $1" >&2
}

# section <heading-prefix> — the body of the first "## <prefix>…" section,
# up to the next "## " heading.
section() {
	awk -v want="## $1" 'index($0, want) == 1 { f = 1; next } /^## / { if (f) exit } f' "$MEMO"
}

# value_of <key> <section text> — the value of the first "- <key>: …" line.
value_of() {
	printf '%s\n' "$2" | awk -v k="- $1:" 'index($0, k) == 1 { v = substr($0, length(k) + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit }'
}

B58='1-9A-HJ-NP-Za-km-z'
# A P-Chain transaction id: CB58, base58 alphabet, 48-52 characters.
REG_TX_RE="(^|[^${B58}])[${B58}]{48,52}([^${B58}]|\$)"

# has_template_marker <value> — a "<…>" placeholder is still in the value.
has_template_marker() {
	printf '%s' "$1" | grep -qE '<[^<>]*>' # MUT:angle
}

# The step 11 template's own instruction wording (docs/CYCLE_GATE.md). A value
# containing any of these is the template with its brackets stripped, not an
# outcome. tests/renewal-memo extracts the template from CYCLE_GATE and
# proves both the verbatim and the stripped copy fail, so this list cannot
# drift from the doc silently.
TEMPLATE_PHRASES=(
	"AddValidator の P-Chain tx id"
	"self stake の実値"
	"unix (JST)"
	"step 7c の 64hex tx id"
	"完了判定 ①〜⑤ の各結果"
	"lock を実測した結果"
)
has_template_wording() {
	local p
	for p in "${TEMPLATE_PHRASES[@]}"; do
		case "$1" in
		*"$p"*) return 0 ;; # MUT:wording
		esac
	done
	return 1
}

# has_placeholder <value> — the value says that nothing was recorded.
# Japanese spellings as substrings (no ID can contain them); Latin spellings
# only as WHOLE WORDS, case-insensitively (LC_ALL=C so tr leaves the UTF-8
# bytes alone) — a CB58 or hex ID is one alphanumeric run, so "tbd" or
# "unknown" occurring inside an ID by chance never matches.
has_placeholder() {
	local lc
	case "$1" in
	- | 未 | *記録なし* | *未確認* | *未記入* | *不明*) return 0 ;; # MUT:placeholder
	esac
	lc="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
	printf '%s' "$lc" | grep -qE '(^|[^a-z0-9])(unknown|tbd|n/a)([^a-z0-9]|$)' # MUT:wholeword
}

# ---- 2. State is updated -----------------------------------------------------
STATE="$(section "State")"
if [ -z "$STATE" ]; then
	problem "no '## State' section"
	PHASE=""
else
	PHASE="$(printf '%s\n' "$STATE" | sed -n 's/^- Current phase:[[:space:]]*//p' | head -1)"
	if [ -z "$PHASE" ]; then
		problem "the State section has no 'Current phase:' line"
	elif ! printf '%s' "$PHASE" | grep -qE '^完了($|[ (]|（)'; then # MUT:state
		problem "State is stale: 'Current phase: ${PHASE}' — after the day it must read '完了 …'"
	elif printf '%s' "$PHASE" | grep -qiE '未完了|していない|ではない|incomplete|not (yet )?(complete|done)'; then # MUT:negation
		problem "State negates completion: 'Current phase: ${PHASE}'"
	elif has_template_marker "$PHASE"; then
		problem "'Current phase:' still holds a template placeholder: '${PHASE}'"
	fi
fi

# ---- 2b. retroactive marker ----------------------------------------------------
# A memo written AFTER the day, from records, may say a value was not recorded
# (記録なし, 未確認, …). It must say so about itself with this one exact line in
# its State section; anything else that starts "- Retroactive:" is reported,
# so a typo cannot pass for the marker.
RETRO_RE='^- Retroactive: yes \(事後作成 [0-9]{4}-[0-9]{2}-[0-9]{2}\)$'
RETRO=0
if printf '%s\n' "$STATE" | grep -qE "$RETRO_RE"; then # MUT:retro
	RETRO=1
elif printf '%s\n' "$STATE" | grep -q '^- Retroactive:'; then
	problem "malformed retroactive marker — the exact line is '- Retroactive: yes (事後作成 YYYY-MM-DD)'"
fi

# ---- 3. the outcome is recorded ------------------------------------------------
OUTCOME="$(section "結果")"
if [ -z "$OUTCOME" ]; then
	problem "no '## 結果' (outcome) section"
fi
for key in "registration tx" "self stake" "endTime" "anchor tx" "verification" "keys locked"; do
	v="$(value_of "$key" "$OUTCOME")"
	if [ -z "$v" ]; then # MUT:keys
		problem "outcome key '${key}:' is missing or empty"
	elif has_template_marker "$v"; then
		problem "outcome key '${key}:' still holds a template placeholder '<…>': '${v}'"
	elif has_template_wording "$v"; then
		problem "outcome key '${key}:' still holds the step 11 template's wording: '${v}'"
	elif [ "$RETRO" -ne 1 ] && has_placeholder "$v"; then
		problem "outcome key '${key}:' says nothing was recorded ('${v}') — allowed only in a memo marked '- Retroactive: yes (事後作成 YYYY-MM-DD)'"
	fi
done

# ---- 4. the IDs are real, retroactive or not -----------------------------------
REGV="$(value_of "registration tx" "$OUTCOME")"
if [ -n "$REGV" ] && ! printf '%s' "$REGV" | grep -qE "$REG_TX_RE"; then # MUT:regid
	problem "'registration tx:' carries no P-Chain tx id (CB58, 48-52 base58 characters): '${REGV}'"
fi
TXV="$(value_of "anchor tx" "$OUTCOME")"
if [ -n "$TXV" ]; then
	# Every 64-hex token in the value, case-folded; exactly one, and it is THE id.
	TX_TOKENS="$(printf '%s' "$TXV" | LC_ALL=C tr '[:upper:]' '[:lower:]' |
		grep -oE '(^|[^0-9a-f])[0-9a-f]{64}([^0-9a-f]|$)' | grep -oE '[0-9a-f]{64}' | sort -u || true)"
	if [ "$TX_TOKENS" != "$ANCHOR_TX" ]; then # MUT:tx
		problem "'anchor tx:' must carry exactly the cycle-${CYCLE} anchor tx id ${ANCHOR_TX} and no other 64-hex id (it reads '${TXV}')"
	fi
fi

if [ "$PROBLEMS" -gt 0 ]; then
	echo "RESULT: INCOMPLETE (${PROBLEMS} item(s); ${MEMO})"
	exit 4
fi
echo "RESULT: COMPLETE (cycle ${CYCLE}; anchor tx ${ANCHOR_TX}; ${MEMO})"
exit 0
