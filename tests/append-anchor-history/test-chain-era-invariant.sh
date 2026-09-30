#!/usr/bin/env bash
# tests/append-anchor-history/test-chain-era-invariant.sh — invariant 5 keyed
# per chain_id, and v3 receipts/lines (PulseVM migration readiness, Task 4).
#
# The REAL scripts/append-anchor-history.sh runs in a temporary tree with a
# FIXTURE config/a-chain-profiles.json in which pulsevm-mainnet carries a
# synthetic chain_id, so a chain change ("new era") can be exercised without
# touching the committed profile file. Lines are validated with the REAL
# JSON-schema validator when one is present (else SKIP).
#
# CHAIN: none — pure file operations. R18 publication is disabled
#        (FYD_PUBLISH_ARCHIVES=0), so no push and no notification is attempted.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
# ok/bad/skip always return 0, so `cond && ok || bad` is a safe if/else here.
# shellcheck disable=SC2015
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { printf 'SKIP  %s\n' "$1"; }

WORK="$(mktemp -d -t era-invariant.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

LEG_M="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
LEG_T="71ee83bcf52142d61019d95f9cc5427ba6a0d7ff8accd9e2088ae2abeaf3d3dd"
PV_M="$(printf 'ab%.0s' $(seq 1 32))"
UNKNOWN="$(printf 'ee%.0s' $(seq 1 32))"
BID="$(printf 'b%.0s' $(seq 1 64))"

TREE="$WORK/tree"
mkdir -p "$TREE/scripts/lib" "$TREE/config" "$TREE/public/api"
cp "$REPO_ROOT/scripts/append-anchor-history.sh" "$TREE/scripts/"
cp "$REPO_ROOT/scripts/lib/side-effects.sh" "$REPO_ROOT/scripts/lib/a-chain-profile.sh" "$TREE/scripts/lib/"
cp "$REPO_ROOT"/public/api/anchor-history.schema.v2.json "$REPO_ROOT"/public/api/anchor-history.schema.v3.json "$TREE/public/api/"
jq --arg pv "$PV_M" '
	.profiles["pulsevm-mainnet"].chain_id = $pv
	| .profiles["pulsevm-mainnet"].history_bases = ["https://history.pulse.example"]' \
	"$REPO_ROOT/config/a-chain-profiles.json" > "$TREE/config/a-chain-profiles.json"
APPEND="$TREE/scripts/append-anchor-history.sh"
export FYD_PUBLISH_ARCHIVES=0

REAL_VALIDATOR=0
if command -v ajv >/dev/null 2>&1 || { command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; }; then
	REAL_VALIDATOR=1
else
	mkdir -p "$WORK/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/ajv"; chmod +x "$WORK/bin/ajv"
	export PATH="$WORK/bin:$PATH"
fi
validate_line() { # <schema> <json-line>
	printf '%s\n' "$2" > "$WORK/line.json"
	if command -v ajv >/dev/null 2>&1; then
		ajv --spec=draft2020 --strict=false validate -s "$1" -d "$WORK/line.json" >/dev/null 2>&1
	else
		python3 - "$1" "$WORK/line.json" <<'PY' >/dev/null 2>&1
import json, sys, jsonschema
jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])), format_checker=jsonschema.FormatChecker())
PY
	fi
}

# receipt <n> <block_num> <prev|null> [schema_version] [chain_id] [chain_profile] [block_id] [network]
receipt() {
	local tx; tx="$(printf "%064x" "$1")"
	jq --arg tx "$tx" --argjson bn "$2" --arg prev "$3" --argjson sv "${4:-2}" \
		--arg cid "${5:-}" --arg prof "${6:-}" --arg bid "${7:-}" --arg net "${8:-mainnet-a}" --argjson cn "$((10 + $1))" '
		.schema_version = $sv | .cycle_number = $cn | .memo_prefix = "fya1c\($cn)"
		| .anchor.tx_id = $tx | .anchor.block_num = $bn | .anchor.network = $net
		| .prev_anchor_tx_id = (if $prev == "null" then null else $prev end)
		| .anchor |= (. + (if $cid == "" then {} else {chain_id: $cid} end)
		                + (if $prof == "" then {} else {chain_profile: $prof} end)
		                + (if $bid == "" then {} else {block_id: $bid} end))' \
		"$REPO_ROOT/public/api/anchor-receipt.v2.example.json" > "$WORK/r$1.json"
	printf '%s' "$WORK/r$1.json"
}
txn() { printf "%064x" "$1"; }
append() { # <history> <receipt> [env...]
	local h="$1" r="$2"; shift 2
	env "$@" bash "$APPEND" --receipt="$r" --history="$h" --event-type=cyclestart >/dev/null 2>"$WORK/err"
}

# ---- E1 legacy ledger (no chain_id) + v2 receipt on the legacy chain ----------
H="$WORK/h1.jsonl"; rm -f "$H"
append "$H" "$(receipt 1 1000 null)"; RC1=$?
append "$H" "$(receipt 2 2000 "$(txn 1)" 2 "$LEG_M" xpr-mainnet "$BID")"; RC=$?
[ "$RC1" -eq 0 ] && [ "$RC" -eq 0 ] && ok "E1 pre-2026-09-30 line + receipt with the legacy chain_id: same era, appended" || bad "E1 rc=$RC1/$RC $(cat "$WORK/err")"
LAST="$(tail -n 1 "$H")"
[ "$(printf '%s' "$LAST" | jq -r '[.schema_version, .chain_id, .block_id, .chain_profile] | map(tostring) | join(" ")')" = "2 $LEG_M $BID xpr-mainnet" ] \
	&& ok "E1 v2 line mirrors chain_id/block_id/chain_profile" || bad "E1 line: $LAST"
[ "$(head -n 1 "$H" | jq -r 'has("chain_id")')" = "false" ] && ok "E1 a receipt without chain_id yields a line without one (never invented)" || bad "E1 invented chain_id"
if [ "$REAL_VALIDATOR" = 1 ]; then
	ALLV2=1
	while IFS= read -r l; do validate_line "$REPO_ROOT/public/api/anchor-history.schema.v2.json" "$l" || ALLV2=0; done < "$H"
	[ "$ALLV2" = 1 ] && ok "E1 every line of the ledger still validates against the committed v2 schema" || bad "E1 v2 validation failed"
else skip "E1 v2 validation (no validator)"; fi

# ---- E2 same chain, lower block_num -> 4 ----------------------------------------
cp "$H" "$WORK/h2.jsonl"
append "$WORK/h2.jsonl" "$(receipt 3 1500 "$(txn 2)" 2 "$LEG_M" xpr-mainnet "$BID")"; RC=$?
[ "$RC" -eq 4 ] && grep -q 'invariant 5' "$WORK/err" && ok "E2 same chain_id, block_num decreasing -> 4" || bad "E2 rc=$RC"
append "$WORK/h2.jsonl" "$(receipt 3 1500 "$(txn 2)")"; RC=$?
[ "$RC" -eq 4 ] && ok "E2b receipt without chain_id counts as the legacy chain -> still 4" || bad "E2b rc=$RC"

# ---- E3 unknown chain_id -> 4, also on genesis -----------------------------------
cp "$H" "$WORK/h3.jsonl"
append "$WORK/h3.jsonl" "$(receipt 3 10 "$(txn 2)" 3 "$UNKNOWN" pulsevm-mainnet "$BID")"; RC=$?
[ "$RC" -eq 4 ] && grep -q 'unknown' "$WORK/err" && ok "E3 unknown chain_id refused (profile not selected)" || bad "E3 rc=$RC"
rm -f "$WORK/h3g.jsonl"
append "$WORK/h3g.jsonl" "$(receipt 3 10 null 3 "$UNKNOWN" pulsevm-mainnet "$BID")"; RC=$?
[ "$RC" -eq 4 ] && [ ! -s "$WORK/h3g.jsonl" ] && ok "E3b unknown chain_id refused on a genesis append too" || bad "E3b rc=$RC"
append "$WORK/h3.jsonl" "$(receipt 3 10 "$(txn 2)" 3 "$PV_M" pulsevm-mainnet "$BID")"; RC=$?
[ "$RC" -eq 4 ] && ok "E3c the new chain's chain_id is refused while its profile is NOT selected" || bad "E3c rc=$RC"

# ---- E4 new era on the selected profile's chain_id, block_num restarts ----------
cp "$H" "$WORK/h4.jsonl"
append "$WORK/h4.jsonl" "$(receipt 3 10 "$(txn 2)" 3 "$PV_M" pulsevm-mainnet "$BID")" FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet; RC=$?
[ "$RC" -eq 0 ] && grep -q 'new era' "$WORK/err" && ok "E4 new era allowed for the selected profile's chain_id (block_num 10 < 2000)" || bad "E4 rc=$RC $(cat "$WORK/err")"
LAST="$(tail -n 1 "$WORK/h4.jsonl")"
[ "$(printf '%s' "$LAST" | jq -r '(.schema_version|tostring) + " " + .chain_id')" = "3 $PV_M" ] && ok "E4 v3 receipt -> v3 line" || bad "E4 line: $LAST"
if [ "$REAL_VALIDATOR" = 1 ]; then
	validate_line "$REPO_ROOT/public/api/anchor-history.schema.v3.json" "$LAST" && ok "E4 v3 line validates against v3" || bad "E4 v3 line invalid"
	OKV2=1; for n in 1 2; do validate_line "$REPO_ROOT/public/api/anchor-history.schema.v2.json" "$(sed -n "${n}p" "$WORK/h4.jsonl")" || OKV2=0; done
	[ "$OKV2" = 1 ] && ok "E4 the earlier v2 lines are untouched and still v2-valid" || bad "E4 earlier lines invalid"
	for k in chain_id block_id chain_profile; do
		validate_line "$REPO_ROOT/public/api/anchor-history.schema.v3.json" "$(printf '%s' "$LAST" | jq -c --arg k "$k" 'del(.[$k])')" \
			&& bad "E4 v3 schema must require $k" || ok "E4 v3 schema requires $k"
	done
else skip "E4 schema validation (no validator)"; fi
append "$WORK/h4.jsonl" "$(receipt 4 5 "$(txn 3)" 3 "$PV_M" pulsevm-mainnet "$BID")" FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet; RC=$?
[ "$RC" -eq 4 ] && ok "E4b within the new era block_num must not decrease (5 < 10) -> 4" || bad "E4b rc=$RC"
append "$WORK/h4.jsonl" "$(receipt 4 20 "$(txn 3)" 3 "$PV_M" pulsevm-mainnet "$BID")" FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet; RC=$?
[ "$RC" -eq 0 ] && ok "E4c within the new era block_num increasing -> appended" || bad "E4c rc=$RC"

# ---- E5 return to an earlier era -> 4 --------------------------------------------
append "$WORK/h4.jsonl" "$(receipt 5 99999 "$(txn 4)" 2 "$LEG_M" xpr-mainnet "$BID")" FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet; RC=$?
[ "$RC" -eq 4 ] && grep -q 'EARLIER era' "$WORK/err" && ok "E5 returning to the legacy chain after a cutover -> 4" || bad "E5 rc=$RC"

# ---- E6 v3 receipt missing block_id / schema_version 4 -> 2 ------------------------
append "$WORK/h4.jsonl" "$(receipt 5 30 "$(txn 4)" 3 "$PV_M" pulsevm-mainnet)" FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet; RC=$?
[ "$RC" -eq 2 ] && ok "E6 v3 receipt without block_id -> 2" || bad "E6 rc=$RC"
append "$WORK/h4.jsonl" "$(receipt 5 30 "$(txn 4)" 4 "$PV_M" pulsevm-mainnet "$BID")" FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet; RC=$?
[ "$RC" -eq 2 ] && ok "E6b schema_version 4 -> 2" || bad "E6b rc=$RC"

# ---- E7 malformed earlier line -> 4 (cannot establish chain_ids) -----------------
{ head -n 1 "$H"; echo '{not json'; tail -n 1 "$H"; } > "$WORK/h7.jsonl"
append "$WORK/h7.jsonl" "$(receipt 3 3000 "$(txn 2)")"; RC=$?
[ "$RC" -eq 4 ] && ok "E7 unparseable ledger line -> 4 (fail closed)" || bad "E7 rc=$RC"

# ---- E8 lines without chain_id map by NETWORK (testnet lines -> legacy testnet) ---
rm -f "$WORK/h8.jsonl"
append "$WORK/h8.jsonl" "$(receipt 1 1000 null 2 "" "" "" testnet-a)"; RC1=$?
append "$WORK/h8.jsonl" "$(receipt 2 500 "$(txn 1)" 2 "$LEG_T" xpr-testnet "$BID" testnet-a)"; RC=$?
[ "$RC1" -eq 0 ] && [ "$RC" -eq 4 ] && ok "E8 a testnet line without chain_id is on the legacy TESTNET chain (500 < 1000 -> 4)" || bad "E8 rc=$RC1/$RC"

# ---- E9 a v2 receipt can only record the legacy chain (v2 invariant text holds) ---
cp "$H" "$WORK/h9.jsonl"
append "$WORK/h9.jsonl" "$(receipt 3 10 "$(txn 2)" 2 "$PV_M" pulsevm-mainnet "$BID")" FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet; RC=$?
[ "$RC" -eq 2 ] && [ "$(wc -l < "$WORK/h9.jsonl" | tr -d ' ')" = "2" ] && ok "E9 v2 receipt on the new chain refused (2), ledger untouched" || bad "E9 rc=$RC"

echo "---"
echo "test-chain-era-invariant.sh summary: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"
exit 1
