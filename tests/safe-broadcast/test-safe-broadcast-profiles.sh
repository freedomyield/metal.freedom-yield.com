#!/usr/bin/env bash
# tests/safe-broadcast/test-safe-broadcast-profiles.sh — the behaviour
# bin/safe-broadcast gained when it moved onto config/a-chain-profiles.json
# (2026-09-30, PulseVM migration readiness): the gate-3 push-endpoint host
# check, confirm-only FYD_*_CHAIN_ID overrides, profile selection, the
# XPR_TESTNET_RPC allowlist, Hyperion v2 evidence in gate 1, and the id-only
# push path (pre-broadcast history reachability, bounded post-push
# confirmation, exit 9 with the tx_id, never a re-push).
#
# CHAIN: none. proton-cli and curl are stubs (sb-harness.sh); nothing is
#        signed or sent. PulseVM scenarios run a COPY of the wrapper inside a
#        temp tree whose config/a-chain-profiles.json is a fixture with
#        made-up PulseVM values (the committed PulseVM profiles are null and
#        refuse, which is itself tested below against the real file).
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# The default-profile equivalence with the pre-profile wrapper is a separate
# suite: test-safe-broadcast-equivalence.sh.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=tests/safe-broadcast/sb-harness.sh
. "$HERE/sb-harness.sh"
sbh_init
trap 'rm -rf "$SBH_T"' EXIT
T="$SBH_T"
W="$ROOT/bin/safe-broadcast"
CFG="$(sbh_cfg_path)"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() {
	FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"
	sed 's/^/      err| /' "$T/err" | head -12
	sed 's/^/      call| /' "$SBH_CALLS" | head -12
}
# check <name> <rc> [err:<substr>] [noerr:<substr>] [out:<exact>] [call:<substr>]
#       [nocall:<substr>] [calls:<substr>=<n>] [audit:<substr>] [noaudit]
check() {
	local name="$1" want_rc="$2" a why=""
	shift 2
	[ "$SBH_RC" = "$want_rc" ] || why="rc=$SBH_RC want $want_rc"
	for a in "$@"; do
		[ -z "$why" ] || break
		case "$a" in
			err:*)    grep -qF -- "${a#err:}" "$T/err" || why="stderr lacks: ${a#err:}" ;;
			noerr:*)  grep -qF -- "${a#noerr:}" "$T/err" && why="stderr has: ${a#noerr:}" ;;
			out:*)    [ "$(cat "$T/out")" = "${a#out:}" ] || why="stdout is '$(cat "$T/out")' want '${a#out:}'" ;;
			call:*)   grep -qF -- "${a#call:}" "$SBH_CALLS" || why="no call: ${a#call:}" ;;
			nocall:*) grep -qF -- "${a#nocall:}" "$SBH_CALLS" && why="unexpected call: ${a#nocall:}" ;;
			calls:*)  local k="${a#calls:}" n
			          n="$(grep -cF -- "${k%=*}" "$SBH_CALLS")"
			          [ "$n" = "${k##*=}" ] || why="calls matching '${k%=*}' = $n, want ${k##*=}" ;;
			audit:*)  grep -qF -- "${a#audit:}" "$T/audit.log" || why="audit lacks: ${a#audit:}" ;;
			noaudit)  [ -s "$T/audit.log" ] && why="audit log written" ;;
		esac
	done
	if [ -z "$why" ]; then ok "$name"; else bad "$name" "$why"; fi
}
# cfg_set <jq-filter> — edit the (freshly reset) proton-cli.json fixture
cfg_set() { local t; t="$(mktemp)"; jq "$1" "$CFG" > "$t" && mv "$t" "$CFG"; }
ovr() { # <chain> <endpoint...> — add an `endpoints` override stanza
	local c="$1"; shift
	local arr; arr="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
	cfg_set ".endpoints = ((.endpoints // []) + [{\"chain\":\"$c\",\"endpoints\":$arr}])"
}

MT='{"chain":"mainnet-a"}'
TT='{"chain":"testnet-a"}'
MAIN_ARGS=(--tx="$T/tx-c4.json" --chain=mainnet-a --non-interactive --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json")
TEST_ARGS=(--tx="$T/tx-c3.json" --chain=testnet-a --non-interactive)

echo "── gate 3 host check (default xpr profiles) ──"
sbh_reset; sbh_token "$MT"; ovr proton https://xpr-clone.example.net
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H1 mainnet: endpoint:set override to a clone host → refuse before chain:info" 3 \
	"err:NOT on the xpr-mainnet node_hosts allowlist" "err:host:     xpr-clone.example.net" \
	"nocall:proton chain:info" "nocall:proton transaction:push" noaudit
sbh_reset; sbh_token "$MT"; ovr proton https://proton.eosusa.io https://rpc.api.mainnet.metalx.com/
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H2 mainnet: override naming only allowlisted hosts → passes, pushes" 0 "out:$SBH_TXID" "calls:proton transaction:push=1"
sbh_reset; sbh_token "$MT"; ovr proton https://proton.eosusa.io https://xpr-clone.example.net
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H3 mainnet: override with one good + one clone endpoint → refuse" 3 "err:xpr-clone.example.net" "nocall:proton transaction:push"
sbh_reset; sbh_token "$MT"; ovr proton-test https://xpr-clone.example.net
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H4 mainnet: an override for the OTHER network is not used → built-in list checked, passes" 0 "out:$SBH_TXID"
sbh_reset; sbh_token "$MT"; cfg_set '(.networks[] | select(.chain=="proton") | .endpoints) |= . + ["https://xpr-clone.example.net"]'
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H5 mainnet: no override, built-in copy carries an off-list host → refuse" 3 "err:built-in list for proton" "err:xpr-clone.example.net" "nocall:proton chain:info"
sbh_reset; sbh_token "$MT"; ovr proton http://proton.eosusa.io
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H6 mainnet: plain-http allowlisted host → refuse (https only)" 3 "err:not a plain https URL" "nocall:proton transaction:push"
AT='@'
sbh_reset; sbh_token "$MT"; ovr proton "https://xpr-clone.example.net/${AT}proton.eosusa.io"
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H7 mainnet: allowlisted host hidden in the path after '/@' → refuse (host = clone)" 3 "err:host:     xpr-clone.example.net"
sbh_reset; sbh_token "$MT"; ovr proton "https://xpr-clone.example.net\\${AT}proton.eosusa.io"
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H8 mainnet: backslash authority trick → refuse (host = clone)" 3 "err:host:     xpr-clone.example.net"
sbh_reset; sbh_token ''; ovr proton-test https://xpr-rpc-testnet.pulsevm.dev
sbh_run - '' "$W" -- "${TEST_ARGS[@]}"
check "H9 testnet: the 2026-08-21 same-chain_id demo host → refuse" 3 "err:NOT on the xpr-testnet node_hosts allowlist" "nocall:proton chain:info"
sbh_reset; sbh_token "$MT"; rm -f "$CFG"
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H10 proton-cli config missing → refuse (endpoint unobservable)" 3 "err:cannot read proton-cli's config" "nocall:proton chain:info"
sbh_reset; sbh_token "$MT"; printf 'not json' > "$CFG"
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H11 proton-cli config not JSON → refuse" 3 "err:not a parseable JSON object"
sbh_reset; sbh_token "$MT"; printf '[1,2]' > "$CFG"
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H12 proton-cli config a JSON array → refuse" 3 "err:not a parseable JSON object"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" STUB_CHAINSET_NOWRITE=1 -- "${MAIN_ARGS[@]}"
check "H13 currentChain not the network just selected → refuse" 3 "err:currentChain is 'proton-test'"
sbh_reset; sbh_token "$MT"; cfg_set 'del(.networks)'
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H14 no override and no built-in copy for the network → refuse" 3 "err:no endpoint for proton"
sbh_reset; sbh_token "$MT"; cfg_set '.endpoints = [{"chain":"proton","endpoints":["https://proton.eosusa.io\nhttps://xpr-clone.example.net"]}]'
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H15 endpoint value with an embedded newline → refuse (malformed)" 3 "err:malformed endpoint value"
sbh_reset; sbh_token "$MT"; cfg_set '.endpoints = [{"chain":"proton","endpoints":[42]}]'
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H16 non-string endpoint → refuse (malformed)" 3 "err:malformed endpoint value"
sbh_reset; sbh_token "$MT"; cfg_set '.endpoints = [{"chain":"proton","endpoints":"https://proton.eosusa.io"}]'
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H17 override endpoints not a list → refuse (malformed)" 3 "err:malformed endpoint value"
sbh_reset; sbh_token "$MT"; cfg_set '.endpoints = [{"chain":"proton","endpoints":[]}]'
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H18 override stanza with no endpoint → refuse" 3 "err:no endpoint for proton"
sbh_reset; sbh_token "$MT"; cfg_set '.networks = [{"chain":"proton","endpoints":["https://PROTON.EOSUSA.IO."]}]'
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
check "H19 case / trailing-dot variant of an allowlisted host → passes (same host)" 0 "out:$SBH_TXID"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" -- "${MAIN_ARGS[@]}"
if grep -q 'privateKeys' "$T/err"; then bad "H20 the config's privateKeys never reach any output" "found"; else ok "H20 the config's privateKeys never reach any output"; fi

echo "── FYD_*_CHAIN_ID: confirm-only ──"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" FYD_MAINNET_CHAIN_ID=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff -- "${MAIN_ARGS[@]}"
check "O1 mainnet override ≠ profile → refused before any gate (exit 4), nothing contacted" 4 \
	"err:a-chain-profile:" "err:refusing before any gate" "nocall:curl" "nocall:proton" noaudit
sbh_reset; sbh_token ''
sbh_run - '' "$W" FYD_TESTNET_CHAIN_ID=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff -- "${TEST_ARGS[@]}"
check "O2 testnet override ≠ profile → refused (exit 4), nothing contacted" 4 "err:a-chain-profile:" "nocall:proton"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" FYD_MAINNET_CHAIN_ID=384DA888112027F0321850A169F737C33E53B388AAD48B5ADACE4BAB97F437E0 -- "${MAIN_ARGS[@]}"
check "O3 upper-cased copy of the real id is still refused (exact match only)" 4 "err:a-chain-profile:"

echo "── profile selection ──"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet -- "${MAIN_ARGS[@]}"
check "S1 committed pulsevm-mainnet (chain_id null) → refused, nothing contacted" 4 "err:is null" "nocall:curl" "nocall:proton"
sbh_reset; sbh_token ''
sbh_run - '' "$W" FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet -- "${TEST_ARGS[@]}"
check "S2 committed pulsevm-testnet → refused" 4 "err:is null" "nocall:proton"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" FYD_A_CHAIN_PROFILE_MAINNET=no-such-profile -- "${MAIN_ARGS[@]}"
check "S3 unknown profile → refused" 4 "err:a-chain-profile:" "nocall:proton"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" FYD_A_CHAIN_PROFILE_MAINNET=xpr-testnet -- "${MAIN_ARGS[@]}"
check "S4 a TESTNET profile selected for mainnet → refused" 4 "err:a-chain-profile:" "nocall:proton"
sbh_reset; sbh_token "$MT"
sbh_run - 'BROADCAST mainnet-a
' "$W" FYD_A_CHAIN_PROFILE_MAINNET=xpr-mainnet -- --tx="$T/tx-c4.json" --chain=mainnet-a --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
check "S5 explicit selection is announced in the confirmation prompt" 0 "err:chain profile: xpr-mainnet (explicitly selected)" "out:$SBH_TXID"
sbh_reset; sbh_token "$MT"
sbh_run - 'BROADCAST mainnet-a
' "$W" -- --tx="$T/tx-c4.json" --chain=mainnet-a --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
check "S6 default selection prints no profile line (output unchanged)" 0 "noerr:chain profile:"

echo "── gate 1: XPR_TESTNET_RPC must be a profile history base ──"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" XPR_TESTNET_RPC=https://xpr-clone.example.net -- "${MAIN_ARGS[@]}"
check "R1 XPR_TESTNET_RPC off the profile → gate 1 refuses, no lookup made" 3 "err:is not one of the testnet profile (xpr-testnet) history bases" "nocall:curl" "nocall:proton"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" XPR_TESTNET_RPC=https://test.proton.eosusa.io/ -- "${MAIN_ARGS[@]}"
check "R2 trailing-slash variant is not an exact match → refuse" 3 "err:XPR_TESTNET_RPC="

echo "── gate 1: evidence shapes ──"
EV2="$(printf '9a9a0001%.0s' 1 2 3 4 5 6 7 8)"
EVB="$(printf '9a9a0002%.0s' 1 2 3 4 5 6 7 8)"
EVC="$(printf '9a9a0003%.0s' 1 2 3 4 5 6 7 8)"
EVD="$(printf '9a9a0004%.0s' 1 2 3 4 5 6 7 8)"
EVE="$(printf '9a9a0005%.0s' 1 2 3 4 5 6 7 8)"
act4='{"act":{"account":"eosio.token","name":"transfer","data":{"memo":"fya1c4-test"}}}'
act2='{"act":{"account":"eosio.token","name":"transfer","data":{"memo":"fya1c2-test"}}}'
printf '{"trx_id":"%s","executed":true,"actions":[%s]}\n' "$EV2" "$act4" > "$T/hist/v1/$EV2.json"
printf '{"trx_id":"%s","executed":true,"actions":[%s]}\n' "$SBH_ZERO" "$act4" > "$T/hist/v1/$EVB.json"
printf '{"id":"%s","trx_id":"%s","actions":[%s]}\n' "$EVC" "$SBH_ZERO" "$act4" > "$T/hist/v1/$EVC.json"
printf '{"trx_id":"%s","executed":false,"actions":[%s]}\n' "$EVD" "$act4" > "$T/hist/v1/$EVD.json"
printf '{"trx_id":"%s","executed":true,"actions":[%s]}\n' "$EVE" "$act2" > "$T/hist/v1/$EVE.json"
EVV2ONLY="$(printf '9a9a0006%.0s' 1 2 3 4 5 6 7 8)"
printf '{"trx_id":"%s","executed":true,"actions":[%s]}\n' "$EVV2ONLY" "$act4" > "$T/hist/v2/$EVV2ONLY.json"
g1() { # <name> <rc> <evidence-id> <checks...>
	local n="$1" r="$2" id="$3"; shift 3
	sbh_reset; sbh_token "$MT"
	sbh_run - '' "$W" -- --tx="$T/tx-c4.json" --chain=mainnet-a --non-interactive --testnet-tx-id="$id" --dry-run-log="$T/dry-c4.json"
	check "$n" "$r" "$@"
}
g1 "V1 Hyperion v2 shape (trx_id + actions[].act) accepted → passes" 0 "$EV2" "out:$SBH_TXID"
g1 "V2 v2 shape naming ANOTHER tx → refuse" 3 "$EVB" "err:could not resolve --testnet-tx-id"
g1 "V3 id matches but trx_id names another tx → refuse" 3 "$EVC" "err:could not resolve --testnet-tx-id"
g1 "V4 executed:false → refuse" 3 "$EVD" "err:could not resolve --testnet-tx-id"
g1 "V5 v2 shape with the wrong cycle memo prefix → refuse (same strictness)" 3 "$EVE" "err:memo-prefix set does not match"
g1 "V6 default profile never asks the v2 endpoint (v2-only evidence → refuse)" 3 "$EVV2ONLY" \
	"err:could not resolve --testnet-tx-id" "nocall:/v2/history" "calls:curl POST=1"

echo "── lib rc mapping ──"
mkdir -p "$T/oldjq"
REALJQ="$(command -v jq)"
cat > "$T/oldjq/jq" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then echo "jq-1.5-1-a5b5cbe"; exit 0; fi
exec "$REALJQ" "\$@"
STUB
chmod +x "$T/oldjq/jq"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$W" "PATH=$T/oldjq:$PATH" -- "${MAIN_ARGS[@]}"
check "M1 jq older than 1.6 (lib rc 6) → exit 2, nothing contacted" 2 "err:a-chain-profile" "nocall:proton" "nocall:curl"
BADTREE="$T/badtree"
printf '{"schema_version":1,"profiles":{}}\n' > "$T/bad-profiles.json"
sbh_tree "$BADTREE" "$W" "$T/bad-profiles.json"
sbh_reset; sbh_token "$MT"
sbh_run - '' "$BADTREE/bin/safe-broadcast" -- "${MAIN_ARGS[@]}"
check "M2 invalid profile file (lib rc 2) → exit 4, nothing contacted" 4 "err:a-chain-profile" "nocall:proton" "nocall:curl"

# ---------------------------------------------------------------------------
echo "── PulseVM (fixture profiles: id-only push, LIB = head) ──"
PVM_MAIN_CID="$(printf 'a1b2c3d4%.0s' 1 2 3 4 5 6 7 8)"
PVM_TEST_CID="$(printf 'd4c3b2a1%.0s' 1 2 3 4 5 6 7 8)"
jq --arg m "$PVM_MAIN_CID" --arg t "$PVM_TEST_CID" '
	.profiles["pulsevm-mainnet"] += {chain_id: $m, node_hosts: ["pvm-node.example.net"],
		history_bases: ["https://pvm-hist-a.example.net", "https://pvm-hist-b.example.net"],
		explorer_base: "https://pvm-explorer.example.net/tx", proton_network: "proton"}
	| .profiles["pulsevm-testnet"] += {chain_id: $t, node_hosts: ["pvm-test-node.example.net"],
		history_bases: ["https://pvm-test-hist.example.net"],
		explorer_base: "https://pvm-test-explorer.example.net/tx", proton_network: "proton-test"}' \
	"$ROOT/config/a-chain-profiles.json" > "$T/pvm-profiles.json"
PT="$T/pvmtree"
sbh_tree "$PT" "$W" "$T/pvm-profiles.json"
PW="$PT/bin/safe-broadcast"
PVM_EVID="$(printf '7e570001%.0s' 1 2 3 4 5 6 7 8)"
printf '{"trx_id":"%s","executed":true,"actions":[%s]}\n' "$PVM_EVID" "$act4" > "$T/hist/v2/$PVM_EVID.json"
PVM_ENV=(FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet
	STUB_PUSH_MODE=idonly "STUB_CHAIN_ID=$PVM_MAIN_CID" FYD_SB_CONFIRM_INTERVAL=0 FYD_SB_CONFIRM_ATTEMPTS=3)
PVM_ARGS=(--tx="$T/tx-c4.json" --chain=mainnet-a --non-interactive --testnet-tx-id="$PVM_EVID" --dry-run-log="$T/dry-c4.json")
confirmed_fixture() { # history answer for the broadcast tx: <executed> <act>
	printf '{"trx_id":"%s","executed":%s,"actions":[%s]}\n' "$SBH_TXID" "$1" "$2" > "$T/hist/v2/$SBH_TXID.json"
}
pvm_reset() { sbh_reset; rm -f "$T/hist/v2/$SBH_TXID.json"; sbh_token "$MT"; ovr proton https://pvm-node.example.net/rpc; }

pvm_reset; confirmed_fixture true "$act4"
sbh_run - '' "$PW" "${PVM_ENV[@]}" -- "${PVM_ARGS[@]}"
check "P1 id-only push + history confirms → exit 0, tx_id on stdout" 0 "out:$SBH_TXID" \
	"call:curl GET https://pvm-test-hist.example.net/v2/history/get_transaction?id=$PVM_EVID" \
	"call:curl GET https://pvm-hist-a.example.net/v2/health" "calls:proton transaction:push=1" \
	"audit:phase=confirm" "audit:confirmed=1"
if awk '/v2\/health/{h=NR} /transaction:push/{p=NR} END{exit !(h && p && h < p)}' "$SBH_CALLS"; then
	ok "P1b history reachability is probed BEFORE the push"; else bad "P1b history reachability is probed BEFORE the push" "order"; fi

pvm_reset
sbh_run - '' "$PW" "${PVM_ENV[@]}" -- "${PVM_ARGS[@]}"
check "P2 id-only push, never confirmed → exit 9, tx_id + MAY-have-broadcast on stderr, stdout empty" 9 \
	"out:" "err:tx_id: $SBH_TXID" "err:a broadcast MAY have happened — verify before retrying" \
	"calls:proton transaction:push=1" "audit:confirmed=0"
check "P2b bounded: 3 rounds × 2 bases × (v1 POST + v2 GET) = 12 lookups, no re-push" 9 \
	"calls:$SBH_TXID=12" "calls:proton transaction:push=1"

pvm_reset; confirmed_fixture true "$act4"; echo 5 > "$T/hist/delay/$SBH_TXID"
sbh_run - '' "$PW" "${PVM_ENV[@]}" -- "${PVM_ARGS[@]}"
check "P3 tx shows up in history on round 2 → confirmed, exit 0" 0 "out:$SBH_TXID" "audit:confirmed=1"

pvm_reset; confirmed_fixture false "$act4"
sbh_run - '' "$PW" "${PVM_ENV[@]}" -- "${PVM_ARGS[@]}"
check "P4 history says executed:false → exit 9 (not confirmed)" 9 "err:MAY have happened" "out:"

pvm_reset; confirmed_fixture true '{"act":{"account":"eosio","name":"updateauth","data":{}}}'
sbh_run - '' "$PW" "${PVM_ENV[@]}" -- "${PVM_ARGS[@]}"
check "P5 history names the tx but with a different action set → exit 9" 9 "err:is not the outgoing one" "out:"

pvm_reset; confirmed_fixture true "$act4"
sbh_run - '' "$PW" "${PVM_ENV[@]}" STUB_HEALTH_FAIL=1 -- "${PVM_ARGS[@]}"
check "P6 no history base reachable → refused BEFORE the broadcast (exit 4)" 4 \
	"err:refusing BEFORE the broadcast" "nocall:proton transaction:push" noaudit

pvm_reset; confirmed_fixture true "$act4"
sbh_run - '' "$PW" FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet STUB_PUSH_MODE=idonly "STUB_CHAIN_ID=$PVM_MAIN_CID" \
	-- --tx="$T/tx-c4.json" --chain=mainnet-a --non-interactive --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
check "P7 XPR testnet evidence for a PulseVM mainnet → gate 1 refuses (open operator decision)" 3 \
	"err:OPEN operator decision" "nocall:curl" "nocall:proton"

sbh_reset; sbh_token "$MT"; confirmed_fixture true "$act4"
sbh_run - '' "$PW" "${PVM_ENV[@]}" -- "${PVM_ARGS[@]}"
check "P8 PulseVM profile with proton-cli still on its built-in XPR hosts → gate 3 refuses" 3 \
	"err:NOT on the pulsevm-mainnet node_hosts allowlist" "nocall:proton transaction:push"

pvm_reset
sbh_run - '' "$PW" "${PVM_ENV[@]}" STUB_PUSH_MODE=fail -- "${PVM_ARGS[@]}"
check "P9 id-only push errors → exit 6 with the MAY-have-broadcast banner" 6 "err:a broadcast MAY have happened"

pvm_reset
sbh_run - '' "$PW" "${PVM_ENV[@]}" FYD_SB_CONFIRM_ATTEMPTS=999 -- "${PVM_ARGS[@]}"
check "P10 attempts out of range (999) → default 20 rounds (80 lookups), still bounded" 9 "calls:$SBH_TXID=80"
pvm_reset
sbh_run - '' "$PW" "${PVM_ENV[@]}" FYD_SB_CONFIRM_ATTEMPTS=abc -- "${PVM_ARGS[@]}"
check "P11 attempts non-numeric → default 20 rounds" 9 "calls:$SBH_TXID=80"
pvm_reset
sbh_run - '' "$PW" "${PVM_ENV[@]}" FYD_SB_CONFIRM_ATTEMPTS=0 -- "${PVM_ARGS[@]}"
check "P12 attempts 0 → default 20 rounds (never zero lookups)" 9 "calls:$SBH_TXID=80"

sbh_reset; rm -f "$T/hist/v2/$SBH_TXID.json"; sbh_token "$TT"; ovr proton-test https://pvm-test-node.example.net/rpc
confirmed_fixture true '{"act":{"account":"eosio.token","name":"transfer","data":{"memo":"fya1c3-test"}}}'
sbh_run - '' "$PW" FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet STUB_PUSH_MODE=idonly "STUB_CHAIN_ID=$PVM_TEST_CID" FYD_SB_CONFIRM_INTERVAL=0 -- "${TEST_ARGS[@]}"
check "P13 testnet role on an id-only profile is confirmed the same way" 0 "out:$SBH_TXID" \
	"call:curl GET https://pvm-test-hist.example.net/v2/health" "audit:confirmed=1"

pvm_reset; confirmed_fixture true "$act4"
sbh_run - 'BROADCAST mainnet-a
' "$PW" "${PVM_ENV[@]}" -- --tx="$T/tx-c4.json" --chain=mainnet-a --testnet-tx-id="$PVM_EVID" --dry-run-log="$T/dry-c4.json"
check "P14 the prompt names the PulseVM profile, chain_id and push shape" 0 \
	"err:chain profile: pulsevm-mainnet (explicitly selected), chain_id=$PVM_MAIN_CID, push_response=id-only"

echo "---"
echo "test-safe-broadcast-profiles.sh: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
