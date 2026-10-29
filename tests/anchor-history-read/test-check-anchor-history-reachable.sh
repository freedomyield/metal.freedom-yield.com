#!/usr/bin/env bash
# tests/anchor-history-read/test-check-anchor-history-reachable.sh — contract
# suite for scripts/check-anchor-history-reachable.sh and the shared reader
# scripts/lib/anchor-history-read.sh (PulseVM migration readiness, Task 4).
#
# CHAIN: none. `curl` is a stub first on PATH that answers from per-case
#        response files and logs every call; nothing leaves this machine.
#        The scripts under test are copied into a temporary tree together
#        with a FIXTURE config/a-chain-profiles.json (the profile library
#        resolves config/ relative to itself), so non-default profiles can
#        carry values without touching the committed file.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (the code under test only reads).
# ok/bad/skip always return 0, so `cond && ok || bad` is a safe if/else here.
# shellcheck disable=SC2015
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

WORK="$(mktemp -d -t ahr-reach.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

LEG_M="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
PV_M="$(printf 'ab%.0s' $(seq 1 32))"
TX_OLD="$(printf '7%.0s' $(seq 1 64))"
TX_NEW="$(printf '8%.0s' $(seq 1 64))"
BID="$(printf 'b%.0s' $(seq 1 64))"
ACTOR="alicewallet"

# ---- tree + fixture config ---------------------------------------------------
TREE="$WORK/tree"
mkdir -p "$TREE/scripts/lib" "$TREE/config" "$TREE/public/api" "$WORK/bin" "$WORK/resp" "$WORK/cfg"
cp "$REPO_ROOT/scripts/check-anchor-history-reachable.sh" "$TREE/scripts/"
cp "$REPO_ROOT/scripts/lib/a-chain-profile.sh" "$REPO_ROOT/scripts/lib/anchor-history-read.sh" "$TREE/scripts/lib/"
jq --arg pv "$PV_M" '
	.profiles["pulsevm-mainnet"].chain_id = $pv
	| .profiles["pulsevm-mainnet"].explorer_base = "https://explorer.pulse.example/transaction"
	| .profiles["spare-testnet"] = (.profiles["pulsevm-testnet"]
		| .history_bases = ["https://history-spare.example"] | .explorer_base = "https://explorer-spare.example/transaction")
	| .profiles["pulsevm-mainnet"].history_bases = ["https://history.pulse.example", "https://history2.pulse.example"]
	| .profiles["pulsevm-testnet"].chain_id = ("cd" * 32)
	| .profiles["pulsevm-testnet"].history_bases = ["https://history-test.pulse.example"]' \
	"$REPO_ROOT/config/a-chain-profiles.json" > "$TREE/config/a-chain-profiles.json"
CHECK="$TREE/scripts/check-anchor-history-reachable.sh"

# ---- curl stub ---------------------------------------------------------------
# Answers from $WORK/resp/<name>.json keyed by the endpoint; a missing file is
# an HTTP failure (exit 22). Every call's arguments are appended to calls.log.
cat > "$WORK/bin/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/calls.log"
url=""
for a in "\$@"; do case "\$a" in https://*) url="\$a" ;; esac; done
host="\${url#https://}"; host="\${host%%/*}"
[ -e "$WORK/down-\$host" ] && exit 7
case "\$url" in
	*/v2/history/get_actions*limit=1\&*) f=probe ;;
	*/v2/history/get_actions*)          f=get_actions ;;
	*/v2/history/get_transaction*)      f=get_transaction_v2 ;;
	*/v1/history/get_transaction)       f=get_transaction_v1 ;;
	*/v1/chain/get_block)               f=get_block ;;
	*/v1/chain/get_info)                f=get_info ;;
	*) exit 22 ;;
esac
[ -r "$WORK/resp/\$f.json" ] || exit 22
cat "$WORK/resp/\$f.json"
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

hyperion_tx() { # <tx> <block_num> [block_id]
	local tx="$1" bn="$2" bid="${3:-}"
	jq -n --arg tx "$tx" --argjson bn "$bn" '{actions: [range(4) | {trx_id: $tx, block_num: $bn, timestamp: "2026-09-04T06:16:21.000", act: {account: "eosio.token", name: "transfer", authorization: [{actor: "alicewallet", permission: "anchor"}], data: {memo: "m\(.)"}}}]}' \
		| if [ -n "$bid" ]; then jq --arg b "$bid" '.actions[] += {block_id: $b}'; else cat; fi
}
reset_resp() { rm -f "$WORK/resp/"*.json "$WORK/calls.log"; : > "$WORK/calls.log"; }
ledger_line() { # <tx> <block_num> [chain_id] [chain_profile] [network]
	jq -nc --arg tx "$1" --argjson bn "$2" --arg cid "${3:-}" --arg prof "${4:-}" --arg net "${5:-mainnet-a}" \
		'{schema_version: 2, tx_id: $tx, block_num: $bn, network: $net, signing_actor: "alicewallet"}
		 + (if $cid == "" then {} else {chain_id: $cid} end)
		 + (if $prof == "" then {} else {chain_profile: $prof} end)'
}
run() { # env... -- args ; sets RC, OUT, ERR
	OUT="$(env "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
}
LEDGER="$WORK/ledger.jsonl"
ledger_line "$TX_OLD" 100 > "$LEDGER"

# ---- R1 default mainnet, known tx from ledger -------------------------------
reset_resp
hyperion_tx "$TX_OLD" 100 "$BID" > "$WORK/resp/get_actions.json"
printf '{"chain_id":"%s"}' "$LEG_M" > "$WORK/resp/get_info.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER"
[ "$RC" -eq 0 ] && ok "R1 default mainnet reachable (rc 0)" || bad "R1 rc=$RC err=$ERR"
case "$OUT" in *"REACHABLE profile=xpr-mainnet chain_id=$LEG_M base=https://proton.eosusa.io mode=known-tx receipt_schema=v2"*) ok "R1 REACHABLE line names profile/chain/base/mode";; *) bad "R1 stdout: $OUT";; esac
grep -q "get_actions?account=alicewallet" "$WORK/calls.log" && ok "R1 resolves the ledger's tx with the ledger's signing actor" || bad "R1 calls: $(cat "$WORK/calls.log")"

# ---- R2 history down -> 3 ----------------------------------------------------
reset_resp
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER"
[ "$RC" -eq 3 ] && ok "R2 history unreachable -> rc 3 (do not sign)" || bad "R2 rc=$RC"

# ---- R3 allowlisted base reports another chain_id -> 4 ------------------------
reset_resp
hyperion_tx "$TX_OLD" 100 "$BID" > "$WORK/resp/get_actions.json"
printf '{"chain_id":"%s"}' "$PV_M" > "$WORK/resp/get_info.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER"
[ "$RC" -eq 4 ] && ok "R3 base serving another chain_id -> rc 4" || bad "R3 rc=$RC"

# ---- R4 get_info not served (Hyperion-only base) is not a failure ------------
reset_resp
hyperion_tx "$TX_OLD" 100 "$BID" > "$WORK/resp/get_actions.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER"
[ "$RC" -eq 0 ] && ok "R4 get_info absent -> still reachable" || bad "R4 rc=$RC"

# ---- R5 selected profile without chain_id -> 2, no request -------------------
reset_resp
run FYD_A_CHAIN_PROFILE_TESTNET=spare-testnet FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=testnet-a --actor="$ACTOR"
[ "$RC" -eq 2 ] && ok "R5 profile with chain_id null -> rc 2" || bad "R5 rc=$RC"
[ -s "$WORK/calls.log" ] && bad "R5 made requests: $(cat "$WORK/calls.log")" || ok "R5 refused before any request"

# ---- R6 FYD_MAINNET_CHAIN_ID disagrees with the profile -> 2 -----------------
reset_resp
run FYD_MAINNET_CHAIN_ID="$PV_M" FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER"
[ "$RC" -eq 2 ] && ok "R6 chain_id override mismatch -> rc 2" || bad "R6 rc=$RC"

# ---- R7 --rpc allowlist ------------------------------------------------------
reset_resp
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER" --rpc=https://clone.example.org
[ "$RC" -eq 1 ] && ok "R7a unlisted --rpc refused (rc 1)" || bad "R7a rc=$RC"
[ -s "$WORK/calls.log" ] && bad "R7a made requests" || ok "R7a refused before any request"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER" --rpc=https://clone.example.org --allow-unlisted-rpc
[ "$RC" -eq 1 ] && ok "R7b --allow-unlisted-rpc refused for mainnet" || bad "R7b rc=$RC"
reset_resp
jq -n '{actions: []}' > "$WORK/resp/probe.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=testnet-a --actor="$ACTOR" --ledger="$WORK/none" --rpc=https://rehearsal.example.org --allow-unlisted-rpc
[ "$RC" -eq 0 ] && grep -q 'rehearsal.example.org' "$WORK/calls.log" && ok "R7c --allow-unlisted-rpc accepted for testnet (WARN)" || bad "R7c rc=$RC err=$ERR"
case "$ERR" in *WARNING*allow-unlisted-rpc*) ok "R7c escape hatch is loud";; *) bad "R7c no WARNING: $ERR";; esac

# ---- R8 block_id: v3 requires it, v2 only warns ------------------------------
reset_resp
hyperion_tx "$TX_OLD" 100 > "$WORK/resp/get_actions.json"     # no block_id, no get_block
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER" --receipt-schema=v3
[ "$RC" -eq 3 ] && ok "R8a v3 with no block_id service -> rc 3" || bad "R8a rc=$RC"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER"
[ "$RC" -eq 0 ] && case "$ERR" in *"serves no block_id"*) true;; *) false;; esac \
	&& ok "R8b v2 with no block_id -> rc 0 + WARNING" || bad "R8b rc=$RC err=$ERR"

# ---- R9 v3 with block_id from get_block fallback -----------------------------
jq -n --arg id "$BID" '{block_num: 100, id: $id}' > "$WORK/resp/get_block.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER" --receipt-schema=v3
[ "$RC" -eq 0 ] && ok "R9 v3 block_id via get_block -> rc 0" || bad "R9 rc=$RC err=$ERR"
jq -n --arg id "$BID" '{block_num: 101, id: $id}' > "$WORK/resp/get_block.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER" --receipt-schema=v3
[ "$RC" -eq 3 ] && ok "R9b get_block for ANOTHER block_num is not accepted" || bad "R9b rc=$RC"

# ---- R10 liveness mode ---------------------------------------------------------
reset_resp
jq -n --arg id "$BID" '{actions: [{block_num: 5, block_id: $id}]}' > "$WORK/resp/probe.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$WORK/none" --actor="$ACTOR"
case "$RC:$OUT" in 0:*mode=liveness*) ok "R10a no ledger -> liveness mode with --actor";; *) bad "R10a rc=$RC out=$OUT";; esac
printf '%s\n' "$ACTOR" > "$WORK/cfg/xpr-account"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$WORK/none"
[ "$RC" -eq 0 ] && grep -q "account=$ACTOR&limit=1" "$WORK/calls.log" && ok "R10b actor read from \$FY_CONFIG_DIR/xpr-account" || bad "R10b rc=$RC"
rm -f "$WORK/cfg/xpr-account"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$WORK/none"
[ "$RC" -eq 1 ] && ok "R10c nothing to probe with (no ledger tx, no actor) -> rc 1" || bad "R10c rc=$RC"
rm -f "$WORK/resp/probe.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$WORK/none" --actor="$ACTOR"
[ "$RC" -eq 3 ] && ok "R10d liveness probe failing -> rc 3" || bad "R10d rc=$RC"

# ---- R11 known tx is taken from THIS chain + profile only ---------------------
reset_resp
{ ledger_line "$TX_OLD" 100; ledger_line "$TX_NEW" 50 "$PV_M" pulsevm-mainnet; } > "$WORK/ledger2.jsonl"
hyperion_tx "$TX_OLD" 100 "$BID" > "$WORK/resp/get_transaction_v2.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$WORK/ledger2.jsonl"
[ "$RC" -eq 0 ] && grep -q "id=$TX_OLD" "$WORK/calls.log" && ! grep -q "$TX_NEW" "$WORK/calls.log" \
	&& ok "R11a xpr-mainnet selected: probes the legacy tx, not the other era's" || bad "R11a rc=$RC calls=$(cat "$WORK/calls.log")"
reset_resp
hyperion_tx "$TX_NEW" 50 "$BID" > "$WORK/resp/get_transaction_v2.json"
run FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$WORK/ledger2.jsonl"
case "$RC:$OUT" in 0:*"profile=pulsevm-mainnet"*"base=https://history.pulse.example mode=known-tx receipt_schema=v3"*) ok "R11b pulsevm-mainnet selected: its own base, its own era's tx, v3";; *) bad "R11b rc=$RC out=$OUT err=$ERR";; esac
grep -q "$TX_OLD" "$WORK/calls.log" && bad "R11b probed the pre-cut tx" || ok "R11b never probes the pre-cut tx on the new chain"

# ---- R12 known tx without block_num -> 3 ----------------------------------------
reset_resp
hyperion_tx "$TX_OLD" 100 "$BID" | jq '.actions[] |= del(.block_num)' > "$WORK/resp/get_actions.json"
run FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER"
[ "$RC" -eq 3 ] && ok "R12 resolved tx without block_num -> rc 3" || bad "R12 rc=$RC"

# ---- R13 v2 refused for a non-default profile -----------------------------------
run FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$LEDGER" --receipt-schema=v2
[ "$RC" -eq 1 ] && ok "R13 --receipt-schema=v2 refused for pulsevm-mainnet" || bad "R13 rc=$RC"

# ---- R14 v1 fallback parses traces, not actions (the formerly dead fallback) ----
reset_resp
jq -n --arg tx "$TX_OLD" '{id: $tx, block_num: 100, block_time: "2026-09-04T06:16:21.000",
	traces: ([range(4) | {receipt: {receiver: "eosio.token"}, act: {account: "eosio.token", name: "transfer", authorization: [{actor: "alicewallet", permission: "anchor"}], data: {memo: "m\(.)"}}}]
	 + [range(4) | {receipt: {receiver: "alicewallet"}, act: {account: "eosio.token", name: "transfer", authorization: [{actor: "alicewallet", permission: "anchor"}], data: {memo: "m\(.)"}}}])}' \
	> "$WORK/resp/get_transaction_v1.json"
(
	. "$TREE/scripts/lib/a-chain-profile.sh"; . "$TREE/scripts/lib/anchor-history-read.sh"
	ahr_resolve_tx https://proton.eosusa.io "$TX_OLD" alicewallet
) > "$WORK/v1.json" 2>/dev/null
[ "$(jq -r '.via + ":" + (.actions | length | tostring)' "$WORK/v1.json" 2>/dev/null)" = "v1/history/get_transaction:4" ] \
	&& ok "R14 v1 fallback resolves via traces and drops the 4 notifications" || bad "R14 got: $(cat "$WORK/v1.json")"

# ---- R16 explorer_base missing: the receipt would refuse, so the check does ----
reset_resp
jq -n '{actions: []}' > "$WORK/resp/probe.json"
run FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=testnet-a --actor="$ACTOR" --ledger="$WORK/none"
[ "$RC" -eq 2 ] && ok "R16 profile without explorer_base -> rc 2" || bad "R16 rc=$RC err=$ERR"
run FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=testnet-a --actor="$ACTOR" --ledger="$WORK/none" --explorer-base=https://explorer.example.org/tx
case "$RC:$OUT" in 0:*"base=https://history-test.pulse.example"*) ok "R16b --explorer-base supplies it (mirrors the receipt flag)";; *) bad "R16b rc=$RC out=$OUT err=$ERR";; esac

# ---- R17 bases are tried in profile order; the first that resolves decides ------
reset_resp
hyperion_tx "$TX_NEW" 50 "$BID" > "$WORK/resp/get_transaction_v2.json"
touch "$WORK/down-history.pulse.example"
run FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$WORK/ledger2.jsonl"
case "$RC:$OUT" in 0:*"base=https://history2.pulse.example"*) ok "R17 first base down -> the second base decides (as in the receipt)";; *) bad "R17 rc=$RC out=$OUT";; esac
touch "$WORK/down-history2.pulse.example"
run FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" --chain=mainnet-a --ledger="$WORK/ledger2.jsonl"
[ "$RC" -eq 3 ] && ok "R17b every base down -> rc 3" || bad "R17b rc=$RC"
rm -f "$WORK"/down-*

# ---- R15 static: no write path in the check or the reader ------------------------
for f in "$REPO_ROOT/scripts/check-anchor-history-reachable.sh" "$REPO_ROOT/scripts/lib/anchor-history-read.sh"; do
	if grep -vE '^[[:space:]]*#' "$f" | grep -Eiq 'push_transaction|send_transaction|transaction:push|issueTx|eth_sendRaw|cleos|(^|[^-a-z])proton[[:space:]]+(action|transaction)|safe-broadcast'; then
		bad "R15 $(basename "$f") contains a write/broadcast path"
	else
		ok "R15 $(basename "$f") has no write/broadcast path"
	fi
done
grep -vE '^[[:space:]]*#' "$REPO_ROOT/scripts/lib/anchor-history-read.sh" | grep -oE '/v[12]/[a-z_]+/[a-z_]+' | sort -u > "$WORK/endpoints"
if [ "$(tr '\n' ' ' < "$WORK/endpoints")" = "/v1/chain/get_block /v1/chain/get_info /v1/history/get_transaction /v2/history/get_actions /v2/history/get_transaction " ]; then
	ok "R15 the reader's endpoint set is exactly the five read endpoints"
else
	bad "R15 endpoint set changed: $(tr '\n' ' ' < "$WORK/endpoints")"
fi

echo "---"
echo "test-check-anchor-history-reachable.sh summary: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"
exit 1
