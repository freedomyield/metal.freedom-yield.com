#!/usr/bin/env bash
# tests/gen-anchor-receipt/test-chain-aware-receipt.sh — the receipt names its
# chain (PulseVM migration readiness, Task 4, 2026-09-30).
#
# Full happy-path runs of scripts/gen-anchor-receipt.sh against a stub
# history service, in a temporary tree with a FIXTURE chain-profile file, so
# the default XPR path and a non-default (pulsevm-*) path can both be run.
# Receipts are validated with the REAL JSON-schema validator (python3
# jsonschema or ajv) against the committed v2/v3 schemas; without one those
# assertions are reported as SKIP and the rest still run.
#
# CHAIN: none. `curl` is a stub first on PATH; nothing leaves this machine.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (the generator only reads).
# ok/bad/skip always return 0, so `cond && ok || bad` is a safe if/else here.
# shellcheck disable=SC2015
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { printf 'SKIP  %s\n' "$1"; }

WORK="$(mktemp -d -t receipt-chain.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

LEG_M="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
LEG_T="71ee83bcf52142d61019d95f9cc5427ba6a0d7ff8accd9e2088ae2abeaf3d3dd"
PV_T="$(printf 'cd%.0s' $(seq 1 32))"
BID="$(printf 'b%.0s' $(seq 1 64))"
# Self-consistent 4-action pack (dag = sha256(id||ob||ar)), same values as
# tests/gen-anchor-receipt/test-r13-r18-schema-archive.sh.
ID_ROOT="b4d5a3eb0b3ec2706bcc2685320ca970c07dabb9412befa8465793666a928df8"
OB_ROOT="c2f5fb3e78a0527aa993a1beaa601a1acf4bc74c80a1f08a22aee47e44306c49"
AR_ROOT="8ad3a424779b937615987a7ea7a384b32cda6dfbe778f220c8da7ce6a9b4b84f"
DAG_ROOT="168a3abd5f657b639dd095b228cc5fc62e5a3c7c1fa3559c20669048d2a54511"
TX_ID="d1f94312e950b813f4f52476027340e442665a92cc4a80971086feb5c8768fc9"
ACTOR="alicewallet"
MP="fya1c9"

TREE="$WORK/tree"
mkdir -p "$TREE/scripts/lib" "$TREE/config" "$TREE/public/api" "$WORK/bin" "$WORK/resp" "$WORK/out"
cp "$REPO_ROOT/scripts/gen-anchor-receipt.sh" "$TREE/scripts/"
cp "$REPO_ROOT/scripts/lib/a-chain-profile.sh" "$REPO_ROOT/scripts/lib/anchor-history-read.sh" "$TREE/scripts/lib/"
cp "$REPO_ROOT"/public/api/anchor-receipt.schema.v2.json "$REPO_ROOT"/public/api/anchor-receipt.schema.v3.json "$TREE/public/api/"
jq --arg pv "$PV_T" '
	.profiles["pulsevm-testnet"].chain_id = $pv
	| .profiles["pulsevm-testnet"].history_bases = ["https://history-test.pulse.example", "https://history-test2.pulse.example"]
	| .profiles["pulsevm-testnet"].explorer_base = "https://explorer-test.pulse.example/transaction"
	| .profiles["spare-testnet"] = (.profiles["pulsevm-testnet"] | .chain_id = null
		| .history_bases = ["https://history-spare.example"] | .explorer_base = "https://explorer-spare.example/transaction")' \
	"$REPO_ROOT/config/a-chain-profiles.json" > "$TREE/config/a-chain-profiles.json"
GEN="$TREE/scripts/gen-anchor-receipt.sh"

cat > "$WORK/bin/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/calls.log"
url=""
for a in "\$@"; do case "\$a" in https://*) url="\$a" ;; esac; done
host="\${url#https://}"; host="\${host%%/*}"
[ -e "$WORK/down-\$host" ] && exit 7
case "\$url" in
	*/v2/history/get_actions*)     f=get_actions ;;
	*/v2/history/get_transaction*) f=get_transaction_v2 ;;
	*/v1/history/get_transaction)  f=get_transaction_v1 ;;
	*/v1/chain/get_block)          f=get_block ;;
	*) exit 22 ;;
esac
[ -r "$WORK/resp/\$f.json" ] || exit 22
cat "$WORK/resp/\$f.json"
STUB
chmod +x "$WORK/bin/curl"

# Real validator, or a pass-through stub (then schema assertions are SKIPped).
REAL_VALIDATOR=0
if command -v ajv >/dev/null 2>&1 || { command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; }; then
	REAL_VALIDATOR=1
else
	printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/ajv"; chmod +x "$WORK/bin/ajv"
fi
export PATH="$WORK/bin:$PATH"

validate() { # <schema-file> <doc> -> rc 0 valid
	if command -v ajv >/dev/null 2>&1 && [ "$REAL_VALIDATOR" = 1 ]; then
		ajv --spec=draft2020 --strict=false validate -s "$1" -d "$2" >/dev/null 2>&1
	else
		python3 - "$1" "$2" <<'PY' >/dev/null 2>&1
import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])), format_checker=jsonschema.FormatChecker())
PY
	fi
}

input_json() { # <network>
	jq -n --arg net "$1" --arg tx "$TX_ID" --arg mp "$MP" --arg a "$ACTOR" \
		--arg i "$ID_ROOT" --arg o "$OB_ROOT" --arg r "$AR_ROOT" --arg d "$DAG_ROOT" '
	{tx_id: $tx, chain: "metal-a-chain", network: $net, method: "hc_single_4_action_pack",
	 schema_version: 1, cycle_number: 9, memo_prefix: $mp,
	 actions: [{branch: "identity", memo: "\($mp)-id:\($i)", root_hex: $i},
	           {branch: "observations", memo: "\($mp)-ob:\($o)", root_hex: $o},
	           {branch: "artifacts", memo: "\($mp)-ar:\($r)", root_hex: $r},
	           {branch: "dag_root_summary", memo: "\($mp):\($d)", root_hex: $d}],
	 authorization: {actor: $a, permission: "anchor"}, sink: "examplesink", quantity: "0.0001 XPR"}'
}
# hyperion <with-block-id 0|1> — the 4 actions as Hyperion serves them
hyperion() {
	jq -n --arg tx "$TX_ID" --arg mp "$MP" --arg a "$ACTOR" --arg bid "$BID" --argjson wb "$1" \
		--arg i "$ID_ROOT" --arg o "$OB_ROOT" --arg r "$AR_ROOT" --arg d "$DAG_ROOT" '
	{actions: [("\($mp)-id:\($i)", "\($mp)-ob:\($o)", "\($mp)-ar:\($r)", "\($mp):\($d)")
	  | {trx_id: $tx, block_num: 12345678, timestamp: "2026-10-07T04:00:30.000",
	     act: {account: "eosio.token", name: "transfer", authorization: [{actor: $a, permission: "anchor"}], data: {memo: .}}}
	  + (if $wb == 1 then {block_id: $bid} else {} end)]}'
}
input_json testnet-a > "$WORK/in-testnet.json"
input_json mainnet-a > "$WORK/in-mainnet.json"
printf '{"fixture":"anchor-source"}\n' > "$WORK/source.json"
reset() { rm -f "$WORK/resp/"*.json "$WORK/out/"*.json; : > "$WORK/calls.log"; }
gen() { # <input> <out> [args...] ; env via caller
	local in="$1" out="$2"; shift 2
	bash "$GEN" --input="$in" --anchor-source="$WORK/source.json" --out="$out" --trigger=cyclestart "$@" >/dev/null 2>"$WORK/err"
}

# ---- C1 default testnet (xpr-testnet): v2 + additive chain fields -------------
reset; hyperion 1 > "$WORK/resp/get_actions.json"
gen "$WORK/in-testnet.json" "$WORK/out/c1.json"; RC=$?
[ "$RC" -eq 0 ] && ok "C1 default testnet receipt written" || bad "C1 rc=$RC $(cat "$WORK/err")"
C1_GOT="$(jq -r '[.schema_version, ."$schema", .anchor.chain_id, .anchor.chain_profile, .anchor.history_base, .anchor.block_id] | map(tostring) | join(" ")' "$WORK/out/c1.json" 2>/dev/null)"
[ "$C1_GOT" = "2 https://metal.freedom-yield.com/api/anchor-receipt.schema.v2.json $LEG_T xpr-testnet https://test.proton.eosusa.io $BID" ] \
	&& ok "C1 v2 receipt carries chain_id/chain_profile/history_base/block_id" || bad "C1 fields: $(jq -c '.anchor | {chain_id, chain_profile, history_base, block_id}' "$WORK/out/c1.json" 2>/dev/null)"
[ "$(jq -r .anchor.explorer_url "$WORK/out/c1.json" 2>/dev/null)" = "https://testnet.protonscan.io/transaction/$TX_ID" ] \
	&& ok "C1 testnet receipt links the TESTNET explorer (profile value)" || bad "C1 explorer_url: $(jq -r .anchor.explorer_url "$WORK/out/c1.json" 2>/dev/null)"
if [ "$REAL_VALIDATOR" = 1 ]; then
	validate "$REPO_ROOT/public/api/anchor-receipt.schema.v2.json" "$WORK/out/c1.json" && ok "C1 validates against the committed v2 schema (real validator)" || bad "C1 not v2-valid"
else skip "C1 v2 schema validation (no validator)"; fi

# ---- C2 default mainnet: legacy mainnet chain_id --------------------------------
reset; hyperion 1 > "$WORK/resp/get_actions.json"
gen "$WORK/in-mainnet.json" "$WORK/out/c2.json"; RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r '.anchor.chain_id + " " + .anchor.chain_profile + " " + .anchor.history_base' "$WORK/out/c2.json")" = "$LEG_M xpr-mainnet https://proton.eosusa.io" ] \
	&& ok "C2 default mainnet: legacy chain_id, xpr-mainnet, profile history base" || bad "C2 rc=$RC"
[ "$(jq -r .anchor.explorer_url "$WORK/out/c2.json")" = "https://explorer.xprnetwork.org/transaction/$TX_ID" ] \
	&& ok "C2 mainnet explorer unchanged" || bad "C2 explorer"

# ---- C3 --receipt-schema=v3 on the legacy chain ---------------------------------
reset; hyperion 1 > "$WORK/resp/get_actions.json"
gen "$WORK/in-mainnet.json" "$WORK/out/c3.json" --receipt-schema=v3; RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r '(.schema_version|tostring) + " " + ."$schema"' "$WORK/out/c3.json")" = "3 https://metal.freedom-yield.com/api/anchor-receipt.schema.v3.json" ] \
	&& ok "C3 legacy-chain v3 receipt (schema_version 3, v3 \$schema)" || bad "C3 rc=$RC $(cat "$WORK/err")"
if [ "$REAL_VALIDATOR" = 1 ]; then
	validate "$REPO_ROOT/public/api/anchor-receipt.schema.v3.json" "$WORK/out/c3.json" && ok "C3 validates against v3" || bad "C3 not v3-valid"
	validate "$REPO_ROOT/public/api/anchor-receipt.schema.v2.json" "$WORK/out/c3.json" && bad "C3 a v3 receipt must NOT pass as v2" || ok "C3 a v3 receipt does not pass as v2 (major bump is visible)"
	jq 'del(.anchor.block_id)' "$WORK/out/c3.json" > "$WORK/out/c3-nobid.json"
	validate "$REPO_ROOT/public/api/anchor-receipt.schema.v3.json" "$WORK/out/c3-nobid.json" && bad "C3 v3 schema must require block_id" || ok "C3 v3 schema requires block_id"
else skip "C3 schema validation (no validator)"; fi

# ---- C4/C5 block_id not served: v3 fails (3, nothing written), v2 omits ---------
reset; hyperion 0 > "$WORK/resp/get_actions.json"
gen "$WORK/in-mainnet.json" "$WORK/out/c4.json" --receipt-schema=v3; RC=$?
[ "$RC" -eq 3 ] && [ ! -e "$WORK/out/c4.json" ] && ok "C4 v3 without block_id -> rc 3, nothing written" || bad "C4 rc=$RC"
gen "$WORK/in-mainnet.json" "$WORK/out/c5.json"; RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r '.anchor | has("block_id")' "$WORK/out/c5.json")" = "false" ] && grep -q 'WARN: block_id' "$WORK/err" \
	&& ok "C5 v2 without block_id -> written, field omitted, WARN" || bad "C5 rc=$RC"

# ---- C6 block_id from get_block fallback ------------------------------------------
jq -n --arg id "$BID" '{block_num: 12345678, id: $id}' > "$WORK/resp/get_block.json"
gen "$WORK/in-mainnet.json" "$WORK/out/c6.json" --receipt-schema=v3; RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .anchor.block_id "$WORK/out/c6.json")" = "$BID" ] && ok "C6 block_id via /v1/chain/get_block" || bad "C6 rc=$RC"

# ---- C7 v1 fallback (traces) — the formerly dead path ---------------------------
reset
hyperion 1 | jq --arg tx "$TX_ID" '{id: $tx, block_num: 12345678, block_time: "2026-10-07T04:00:30.000",
	traces: ([.actions[] | {receipt: {receiver: "eosio.token"}, act: .act, producer_block_id: .block_id}]
	       + [.actions[] | {receipt: {receiver: "examplesink"}, act: .act}])}' > "$WORK/resp/get_transaction_v1.json"
gen "$WORK/in-mainnet.json" "$WORK/out/c7.json"; RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .anchor.block_id "$WORK/out/c7.json")" = "$BID" ] \
	&& ok "C7 v1 get_transaction (traces, notifications filtered) resolves the receipt" || bad "C7 rc=$RC $(cat "$WORK/err")"

# ---- C8 Hyperion get_transaction when get_actions does not list the tx ----------
reset; hyperion 1 > "$WORK/resp/get_transaction_v2.json"; jq -n '{actions: []}' > "$WORK/resp/get_actions.json"
gen "$WORK/in-mainnet.json" "$WORK/out/c8.json"; RC=$?
[ "$RC" -eq 0 ] && grep -q "get_transaction?id=$TX_ID" "$WORK/calls.log" && ok "C8 falls back to /v2/history/get_transaction" || bad "C8 rc=$RC"

# ---- C9 FYD_TESTNET_CHAIN_ID disagreeing with the profile -> 1, no request -------
reset; hyperion 1 > "$WORK/resp/get_actions.json"
FYD_TESTNET_CHAIN_ID="$LEG_M" gen "$WORK/in-testnet.json" "$WORK/out/c9.json"; RC=$?
[ "$RC" -eq 1 ] && [ ! -s "$WORK/calls.log" ] && ok "C9 chain_id override mismatch refused before any request" || bad "C9 rc=$RC"

# ---- C10 non-default profile: v3 by default, v2 refused ---------------------------
reset; hyperion 1 > "$WORK/resp/get_actions.json"
FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet gen "$WORK/in-testnet.json" "$WORK/out/c10.json"; RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r '(.schema_version|tostring) + " " + .anchor.chain_id + " " + .anchor.chain_profile + " " + .anchor.history_base' "$WORK/out/c10.json")" = "3 $PV_T pulsevm-testnet https://history-test.pulse.example" ] \
	&& ok "C10a pulsevm-testnet: v3 receipt on its own chain_id and history base" || bad "C10a rc=$RC $(cat "$WORK/err")"
[ "$(jq -r .anchor.explorer_url "$WORK/out/c10.json")" = "https://explorer-test.pulse.example/transaction/$TX_ID" ] \
	&& ok "C10a explorer from the selected profile" || bad "C10a explorer"
FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet gen "$WORK/in-testnet.json" "$WORK/out/c10b.json" --receipt-schema=v2; RC=$?
[ "$RC" -eq 1 ] && ok "C10b --receipt-schema=v2 refused for pulsevm-testnet" || bad "C10b rc=$RC"
FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet gen "$WORK/in-testnet.json" "$WORK/out/c10c.json" --rpc=https://test.proton.eosusa.io; RC=$?
[ "$RC" -eq 1 ] && ok "C10c the legacy base is not a history base of the new profile" || bad "C10c rc=$RC"

# ---- C12 a profile that has everything BUT a chain_id refuses, before any request
reset; hyperion 1 > "$WORK/resp/get_actions.json"
FYD_A_CHAIN_PROFILE_TESTNET=spare-testnet gen "$WORK/in-testnet.json" "$WORK/out/c12.json"; RC=$?
[ "$RC" -eq 1 ] && [ ! -s "$WORK/calls.log" ] && [ ! -e "$WORK/out/c12.json" ] \
	&& ok "C12 chain_id null (bases + explorer present) -> rc 1, no request, nothing written" || bad "C12 rc=$RC"

# ---- C13 history bases tried in profile order (same rule as the pre-broadcast check)
reset; hyperion 1 > "$WORK/resp/get_actions.json"; touch "$WORK/down-history-test.pulse.example"
FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet gen "$WORK/in-testnet.json" "$WORK/out/c13.json"; RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .anchor.history_base "$WORK/out/c13.json")" = "https://history-test2.pulse.example" ] \
	&& ok "C13 first base down -> resolved at the second, recorded as history_base" || bad "C13 rc=$RC $(cat "$WORK/err")"
rm -f "$WORK"/down-*

# ---- C11 the published v3 examples validate against the published v3 schemas ---
API="$REPO_ROOT/public/api"
if [ "$REAL_VALIDATOR" = 1 ]; then
	validate "$API/anchor-receipt.schema.v3.json" "$API/anchor-receipt.v3.example.json" \
		&& ok "C11 anchor-receipt.v3.example.json is v3-valid" || bad "C11 receipt v3 example invalid"
	n=0; allok=1
	while IFS= read -r line; do
		n=$((n + 1)); printf '%s\n' "$line" > "$WORK/exline.json"
		sv="$(jq -r .schema_version "$WORK/exline.json")"
		validate "$API/anchor-history.schema.v${sv}.json" "$WORK/exline.json" || { allok=0; bad "C11 history v3 example line $n invalid against v$sv"; }
	done < "$API/anchor-history.v3.example.jsonl"
	[ "$allok" = 1 ] && [ "$n" -ge 3 ] && ok "C11 every anchor-history.v3.example.jsonl line validates against its own schema_version ($n lines)"
else skip "C11 example validation (no validator)"; fi

echo "---"
echo "test-chain-aware-receipt.sh summary: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"
exit 1
