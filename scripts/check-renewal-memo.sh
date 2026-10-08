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
#   2. its "## State" section has a "Current phase:" line whose value starts
#      with 完了 — a memo still reading "Current phase: 1" is STALE, which is
#      exactly the cycle-6 state of 2026-10-07
#   3. its "## 結果" (outcome) section carries every one of these keys as a
#      "- <key>: <value>" line with a real value (not empty, not a
#      <placeholder>):
#        registration tx / self stake / endTime / anchor tx / verification /
#        keys locked
#   4. the "anchor tx:" value contains THE cycle-<C> anchor tx id — taken from
#      --anchor-tx=, or resolved from --history= (the mainnet line whose
#      cycle_number is C). Any 64-hex string is not enough: a memo copied
#      from the previous cycle would carry one.
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
#      (file unreadable, no mainnet line for cycle C, or more than one tx id)

set -u

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
	# Mainnet lines only: a line without .network predates the field and is
	# mainnet (the published ledger has only ever carried mainnet anchors).
	TX_IDS="$(jq -r --argjson c "$CYCLE" \
		'select(.cycle_number == $c and ((.network // "mainnet-a") == "mainnet-a")) | .tx_id // empty' \
		"$HISTORY" 2>/dev/null | sort -u)" || TX_IDS=""
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

is_real_value() {
	case "$1" in
	'' | '<'*'>' | TBD | tbd | 未 | 未記入 | - ) return 1 ;;
	esac
	return 0
}

# ---- 2. State is updated -----------------------------------------------------
STATE="$(section "State")"
if [ -z "$STATE" ]; then
	problem "no '## State' section"
else
	PHASE="$(printf '%s\n' "$STATE" | sed -n 's/^- Current phase:[[:space:]]*//p' | head -1)"
	case "$PHASE" in
	完了*) : ;; # MUT:state
	'') problem "the State section has no 'Current phase:' line" ;;
	*) problem "State is stale: 'Current phase: ${PHASE}' — after the day it must read '完了 …'" ;;
	esac
fi

# ---- 3. the outcome is recorded ------------------------------------------------
OUTCOME="$(section "結果")"
if [ -z "$OUTCOME" ]; then
	problem "no '## 結果' (outcome) section"
fi
for key in "registration tx" "self stake" "endTime" "anchor tx" "verification" "keys locked"; do
	v="$(value_of "$key" "$OUTCOME")"
	if ! is_real_value "$v"; then # MUT:keys
		problem "outcome key '${key}:' is missing or has no real value"
	fi
done

# ---- 4. the anchor tx is THIS cycle's ------------------------------------------
TXV="$(value_of "anchor tx" "$OUTCOME")"
case "$TXV" in
*"$ANCHOR_TX"*) : ;; # MUT:tx
*)
	if is_real_value "$TXV"; then
		problem "'anchor tx:' does not contain the cycle-${CYCLE} anchor tx id ${ANCHOR_TX} (it reads '${TXV}')"
	fi
	;;
esac

if [ "$PROBLEMS" -gt 0 ]; then
	echo "RESULT: INCOMPLETE (${PROBLEMS} item(s); ${MEMO})"
	exit 4
fi
echo "RESULT: COMPLETE (cycle ${CYCLE}; anchor tx ${ANCHOR_TX}; ${MEMO})"
exit 0
