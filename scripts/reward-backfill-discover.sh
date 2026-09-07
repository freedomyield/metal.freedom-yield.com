#!/usr/bin/env bash
# reward-backfill-discover.sh — ONE-SHOT, READ-ONLY discovery of this
# validator's historical AddValidatorTx txIDs, for feeding
# `reward-tracker.sh --backfill <txID> <cycle_n>`. Cycles that matured
# before reward-tracker.sh existed were never tracked live and their
# AddValidatorTx IDs were recorded nowhere — this script recovers them
# from the P-Chain itself, without writing anything anywhere.
#
# CHAIN: none — READ-ONLY BY CONSTRUCTION. The only two RPC methods this
#        script can form are platform.getCurrentValidators and
#        platform.getTx (both pure reads). Each request body is composed
#        inside its own dedicated function with the method name as a
#        string literal, so no code path exists that could compose any
#        other method. No broadcast-capable call exists in this file.
# PRIME_DIRECTIVE: TESTNET-FIRST — not applicable (no broadcast pathway).
#
# HOW IT WORKS
#   1. platform.getCurrentValidators (own NodeID) -> the CURRENT staking
#      txID (the in-flight cycle's AddValidatorTx — the newest link).
#   2. Each cycle's AddValidatorTx spends UTXOs returned by the previous
#      cycle's tx when it matured, so walking INPUT txID references
#      backwards (BFS with a visited set, depth-capped at MAX_DEPTH)
#      reaches every historical staking tx. Non-staking intermediates
#      (BaseTx / ImportTx shapes) are walked straight through.
#   3. A walked tx is a "staking tx candidate" iff its unsigned body
#      carries a validator object naming OUR NodeID. Field names are
#      probed flexibly (jq recursion over the unsigned body, accepting
#      start/startTime and end/endTime spellings) rather than hard-coded
#      to one metalgo JSON marshalling version.
#   4. Candidates are matched EXACTLY (start_unix AND end_unix both
#      equal) against uptime-cycles.json's closed-cycle rows.
#
# OUTPUT (stdout, tab-separated; nothing else ever goes to stdout)
#   <cycle_n> <txID> <start_unix> <end_unix> matched   resolved closed cycle
#   UNMATCHED <txID> <start> <end> unmatched           staking candidate with
#                                                      no closed-cycle row
#                                                      (e.g. the in-flight
#                                                      cycle's own tx)
#   <cycle_n> NOT-FOUND                                closed cycle whose
#                                                      staking tx was not
#                                                      discovered
#
# OUTPUT HYGIENE (constitution §4 — the raw platform.getTx JSON contains
# the operator's reward-owner wallet addresses): raw RPC responses are
# held in shell variables / a private temp dir only, and ONLY txIDs, unix
# times, cycle numbers, counts and type words are ever printed to
# stdout/stderr. Never the raw tx JSON, never an address, never an
# amount. tests/reward-backfill-discover/ enforces this with a
# leak-canary grep, and proves the grep has teeth with a mutation-kill
# run (a mutant that echoes the raw response must fail it).
#
# Usage:
#   bash scripts/reward-backfill-discover.sh
#
# Env:
#   METALGO_RPC          metalgo RPC base URL       (default http://127.0.0.1:9650)
#   FY_RPC_TIMEOUT        curl --max-time seconds    (default 6)
#   VALIDATOR_JSON        path to validator.json     (default public/api/validator.json)
#   UPTIME_CYCLES_JSON    path to uptime-cycles.json (default public/api/uptime-cycles.json)
#   MAX_DEPTH             BFS depth cap              (default 8)
#
# Exit codes:
#   0  every closed cycle in uptime-cycles.json was discovered and matched
#   1  usage error
#   2  RPC unreachable / response unparseable / own NodeID absent from the
#      current validator set / current staking tx unreadable (fail-closed)
#   3  validator.json or uptime-cycles.json missing, unreadable, or
#      missing the required fields (structural input problem)
#   4  at least one closed cycle could not be discovered — NOT-FOUND rows
#      were printed; the matched rows that WERE printed are still valid

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

METALGO_RPC="${METALGO_RPC:-http://127.0.0.1:9650}"
RPC_TIMEOUT="${FY_RPC_TIMEOUT:-6}"
VALIDATOR_JSON="${VALIDATOR_JSON:-$ROOT/public/api/validator.json}"
UPTIME_CYCLES_JSON="${UPTIME_CYCLES_JSON:-$ROOT/public/api/uptime-cycles.json}"
MAX_DEPTH="${MAX_DEPTH:-8}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	sed -n '2,76p' "$0" | sed 's/^# \?//'
	exit 0
elif [ $# -gt 0 ]; then
	echo "reward-backfill-discover: unknown argument: $1 (this script takes no arguments — see --help)" >&2
	exit 1
fi

# ---- read-only RPC composers ---------------------------------------------
# Exactly TWO functions may build a request body, each with its method name
# as a literal. There is deliberately NO generic "call any method" helper —
# that absence is what makes this script read-only by construction (and is
# what the companion test's method-allowlist grep pins down).

# rpc_get_current_validators — prints the raw response body (empty on
# transport failure). Callers must never print it. Takes NO argument:
# $NODE_ID is consumed HERE via jq's own --arg (never interpolated raw
# into a string, and never passed through a call-site assignment), so
# tests/field-contracts' transitive-binding pass does not misattribute
# the RPC response to validator.json's vocabulary — the exact shape and
# rationale of scripts/reward-tracker.sh's CV_REQ_BODY construction
# (commit 60b4e7f); see that file's comment block for the full story.
rpc_get_current_validators() {
	local body
	body=$(jq -nc --arg id "$NODE_ID" \
		'{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{"nodeIDs":[$id]}}')
	curl -sS --max-time "$RPC_TIMEOUT" -X POST -H "Content-Type: application/json" \
		--data "$body" "${METALGO_RPC}/ext/bc/P" 2>/dev/null || true
}

# rpc_get_tx <txID> — prints the raw response body (empty on transport
# failure). The response contains reward-owner ADDRESSES: callers must
# never print it (see OUTPUT HYGIENE in the header).
rpc_get_tx() {
	local body
	body=$(jq -nc --arg tx "$1" \
		'{"jsonrpc":"2.0","id":1,"method":"platform.getTx","params":{"txID":$tx,"encoding":"json"}}')
	curl -sS --max-time "$RPC_TIMEOUT" -X POST -H "Content-Type: application/json" \
		--data "$body" "${METALGO_RPC}/ext/bc/P" 2>/dev/null || true
}

# ---- structural inputs ----------------------------------------------------
if [ ! -r "$VALIDATOR_JSON" ]; then
	echo "reward-backfill-discover: ERROR: validator.json not readable at ${VALIDATOR_JSON}" >&2
	exit 3
fi
NODE_ID=$(jq -r '.nodeId // empty' "$VALIDATOR_JSON" 2>/dev/null)
if [ -z "$NODE_ID" ]; then
	echo "reward-backfill-discover: ERROR: validator.json carries no .nodeId" >&2
	exit 3
fi
if [ ! -r "$UPTIME_CYCLES_JSON" ]; then
	echo "reward-backfill-discover: ERROR: uptime-cycles.json not readable at ${UPTIME_CYCLES_JSON}" >&2
	exit 3
fi
if ! jq -e '.cycles | type == "array"' "$UPTIME_CYCLES_JSON" >/dev/null 2>&1; then
	echo "reward-backfill-discover: ERROR: uptime-cycles.json has no .cycles array" >&2
	exit 3
fi

WORK=$(mktemp -d) || exit 3
trap 'rm -rf "$WORK"' EXIT
VISITED_FILE="$WORK/visited.txt"     # one txID per line, ever enqueued+fetched
CAND_FILE="$WORK/candidates.tsv"     # txID <TAB> start_unix <TAB> end_unix
MATCHED_TX_FILE="$WORK/matched.txt"  # txIDs consumed by a closed-cycle match
: > "$VISITED_FILE"
: > "$CAND_FILE"
: > "$MATCHED_TX_FILE"

# ---- step 1: current staking tx (the BFS root) ---------------------------
CV_RESP=$(rpc_get_current_validators)
if [ -z "$CV_RESP" ] || ! printf '%s' "$CV_RESP" | jq -e '.result.validators' >/dev/null 2>&1; then
	echo "reward-backfill-discover: ERROR: platform.getCurrentValidators unreachable or unparseable — fail-closed" >&2
	exit 2
fi
ROOT_TX=$(printf '%s' "$CV_RESP" | jq -r --arg id "$NODE_ID" \
	'[.result.validators[]? | select(.nodeID == $id)] | first | .txID // empty' 2>/dev/null)
if [ -z "$ROOT_TX" ]; then
	echo "reward-backfill-discover: ERROR: own NodeID absent from the current validator set — no BFS root, fail-closed" >&2
	exit 2
fi

# ---- steps 2+3: BFS backwards over input txID references -----------------
# Queue entries are "txID<space>depth". Plain indexed array + head pointer
# (no bash-4 associative arrays — the validator host has bash 4 but this
# repo's tests also run on a stock macOS bash 3.2).
QUEUE=("$ROOT_TX 0")
QHEAD=0
while [ "$QHEAD" -lt "${#QUEUE[@]}" ]; do
	ENTRY="${QUEUE[$QHEAD]}"
	QHEAD=$((QHEAD + 1))
	TX="${ENTRY% *}"
	DEPTH="${ENTRY##* }"

	grep -qxF "$TX" "$VISITED_FILE" && continue
	printf '%s\n' "$TX" >> "$VISITED_FILE"

	RESP=$(rpc_get_tx "$TX")
	if [ -z "$RESP" ]; then
		echo "reward-backfill-discover: ERROR: platform.getTx transport failure at ${TX} — fail-closed" >&2
		exit 2
	fi
	if ! printf '%s' "$RESP" | jq -e . >/dev/null 2>&1; then
		echo "reward-backfill-discover: ERROR: platform.getTx response unparseable at ${TX} — fail-closed" >&2
		exit 2
	fi
	# (tx JSON handled in-memory only; never echoed — see OUTPUT HYGIENE)
	if ! printf '%s' "$RESP" | jq -e '.result.tx.unsignedTx' >/dev/null 2>&1; then
		if [ "$TX" = "$ROOT_TX" ]; then
			echo "reward-backfill-discover: ERROR: current staking tx ${TX} not readable as a P-Chain tx — fail-closed" >&2
			exit 2
		fi
		echo "reward-backfill-discover: dead-end at ${TX} (no readable unsigned tx body; its ancestors are skipped)" >&2
		continue
	fi

	# Staking classification: a validator object naming OUR NodeID anywhere
	# in the unsigned body (AddValidatorTx / AddPermissionlessValidatorTx
	# shapes both carry {nodeID, start|startTime, end|endTime}).
	VAL_OBJ=$(printf '%s' "$RESP" | jq -c '
		[.result.tx.unsignedTx | .. | objects
		 | select(has("nodeID") and (has("start") or has("startTime")) and (has("end") or has("endTime")))]
		| first // empty' 2>/dev/null)
	if [ -n "$VAL_OBJ" ]; then
		V_NODE=$(printf '%s' "$VAL_OBJ" | jq -r '.nodeID // empty')
		if [ "$V_NODE" = "$NODE_ID" ]; then
			V_START=$(printf '%s' "$VAL_OBJ" | jq -r '(.start // .startTime) | tonumber' 2>/dev/null)
			V_END=$(printf '%s' "$VAL_OBJ" | jq -r '(.end // .endTime) | tonumber' 2>/dev/null)
			if [ -z "$V_START" ] || [ -z "$V_END" ]; then
				echo "reward-backfill-discover: ERROR: staking tx ${TX} has unreadable start/end times — fail-closed" >&2
				exit 2
			fi
			printf '%s\t%s\t%s\n' "$TX" "$V_START" "$V_END" >> "$CAND_FILE"
		fi
	fi

	# Enqueue every input txID reference (jq recursion — robust across
	# metalgo JSON shapes; only .result.tx.unsignedTx is walked, so the
	# tx's own .result.tx.id is never re-enqueued as its own parent).
	if [ "$DEPTH" -lt "$MAX_DEPTH" ]; then
		while IFS= read -r PARENT; do
			[ -n "$PARENT" ] || continue
			grep -qxF "$PARENT" "$VISITED_FILE" && continue
			QUEUE+=("$PARENT $((DEPTH + 1))")
		done < <(printf '%s' "$RESP" | jq -r \
			'[.result.tx.unsignedTx | .. | .txID? | select(type == "string")] | unique | .[]' 2>/dev/null)
	fi
done

# ---- step 4: exact start/end match against closed cycles -----------------
MISSING=0
while IFS=$'\t' read -r CN CS CE; do
	[ -n "$CN" ] || continue
	M_TX=$(awk -F'\t' -v s="$CS" -v e="$CE" '$2 == s && $3 == e { print $1; exit }' "$CAND_FILE")
	if [ -n "$M_TX" ]; then
		printf '%s\t%s\t%s\t%s\tmatched\n' "$CN" "$M_TX" "$CS" "$CE"
		printf '%s\n' "$M_TX" >> "$MATCHED_TX_FILE"
	else
		printf '%s\tNOT-FOUND\n' "$CN"
		MISSING=1
	fi
done < <(jq -r '.cycles[]? | [.cycle_n, .start_unix, .end_unix] | @tsv' "$UPTIME_CYCLES_JSON" 2>/dev/null)

# Candidates no closed cycle claimed (typically the in-flight cycle's own
# tx, whose row uptime-cycles.json does not carry yet) — listed, never
# silently dropped, so the operator can see everything the walk found.
while IFS=$'\t' read -r C_TX C_S C_E; do
	[ -n "$C_TX" ] || continue
	grep -qxF "$C_TX" "$MATCHED_TX_FILE" && continue
	printf 'UNMATCHED\t%s\t%s\t%s\tunmatched\n' "$C_TX" "$C_S" "$C_E"
done < "$CAND_FILE"

N_VISITED=$(wc -l < "$VISITED_FILE" | tr -d '[:space:]')
N_CAND=$(wc -l < "$CAND_FILE" | tr -d '[:space:]')
N_MATCHED=$(wc -l < "$MATCHED_TX_FILE" | tr -d '[:space:]')
echo "reward-backfill-discover: walked ${N_VISITED} tx, found ${N_CAND} staking candidate(s), matched ${N_MATCHED} closed cycle(s)" >&2

if [ "$MISSING" -eq 1 ]; then
	echo "reward-backfill-discover: at least one closed cycle was NOT discovered (see NOT-FOUND rows) — exit 4" >&2
	exit 4
fi
exit 0
