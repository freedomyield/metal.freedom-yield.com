#!/usr/bin/env bash
# tests/safe-broadcast/test-safe-broadcast-equivalence.sh — P1 pin: with the
# DEFAULT chain profiles (xpr-mainnet / xpr-testnet), bin/safe-broadcast must
# behave exactly as it did before it read config/a-chain-profiles.json.
#
# CHAIN: none. proton-cli and curl are stubs on PATH (sb-harness.sh); nothing
#        is signed or sent. The "push" scenarios reach the stub's canned
#        transaction:push answer, which is how the success path is observable.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# HOW THE GOLDEN FILE WAS MADE
#   fixtures/equivalence-golden.txt is the normalized record (exit code,
#   stdout, stderr, audit-log lines, and the ORDERED list of proton/curl
#   calls) of every scenario below, produced by running this suite with
#   --write-golden against the wrapper at base commit 8a79fd5 — the last
#   version with hard-coded chain constants, i.e. the code the 2026-10-07
#   transition was rehearsed on:
#       git show 8a79fd5:bin/safe-broadcast > <tree>/bin/safe-broadcast
#       SB_EQ_WRAPPER=<tree>/bin/safe-broadcast \
#         bash tests/safe-broadcast/test-safe-broadcast-equivalence.sh --write-golden
#   The current wrapper must reproduce it byte-for-byte. The call list makes
#   this stronger than an exit-code match: the same endpoints are asked the
#   same questions in the same order.
#
#   Every scenario runs with a VALID proton-cli.json fixture (compiled-in
#   networks, no `endpoints` override) — the state the operator's keystores
#   are in when scripts/install-rehearsal-preflight.sh check 10 is green — so
#   the new gate-3 host check passes and must not change any outcome.
#
#   Deliberately NOT here (they are intended, stricter changes, pinned in
#   test-safe-broadcast-profiles.sh): an FYD_*_CHAIN_ID override that
#   DIFFERS from the profile (old: gate 3 compared against the override;
#   now: refused before any gate), an XPR_TESTNET_RPC that is not one of the
#   profile's history bases (old: used unchecked; now: gate 1 refuses), and
#   any proton-cli.json that fails the new host check.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GOLDEN="$HERE/fixtures/equivalence-golden.txt"
WRITE=0
[ "${1:-}" = "--write-golden" ] && WRITE=1

# shellcheck source=tests/safe-broadcast/sb-harness.sh
. "$HERE/sb-harness.sh"
sbh_init
trap 'rm -rf "$SBH_T"' EXIT

W="${SB_EQ_WRAPPER:-$ROOT/bin/safe-broadcast}"
T="$SBH_T"
OUT="$T/actual.txt"
: > "$OUT"

MAIN_TOKEN='{"chain":"mainnet-a"}'
C3_SHA="$(jq -c . "$T/tx-c3.json" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}')"

# sc <name> <token-content|@stale|@none> <stdin> [VAR=v ...] -- <args...>
sc() {
	local name="$1" tok="$2" stdin="$3"
	shift 3
	sbh_reset
	case "$tok" in
		@none)  rm -f "$FYD_BROADCAST_TOKEN_FILE" ;;
		@stale) sbh_token ''
		        touch -t "$(date -u -v-400S +%Y%m%d%H%M 2>/dev/null || date -u -d '-400 seconds' +%Y%m%d%H%M)" "$FYD_BROADCAST_TOKEN_FILE" ;;
		*)      sbh_token "$tok" ;;
	esac
	sbh_run "$name" "$stdin" "$W" "$@"
	# The usage text IS the header comment, which this change extends (new
	# sections documenting the profile behaviour). Compare everything else
	# exactly: header lines are replaced by one marker line.
	local f
	for f in out err; do
		if grep -qxF -f "$HELP" "$T/$f"; then
			{ grep -vxF -f "$HELP" "$T/$f" | sed '/^$/d'; echo "[usage text printed]"; } > "$T/$f.f"
			mv "$T/$f.f" "$T/$f"
		fi
	done
	sbh_block "$name" >> "$OUT"
}
HELP="$T/help.txt"
bash "$W" --help > "$HELP" 2>/dev/null
sed -i.bak '/^$/d' "$HELP" && rm -f "$HELP.bak"
[ -s "$HELP" ] || { echo "FAIL could not capture --help of $W"; exit 1; }

M=(--chain=mainnet-a --non-interactive)

# ---- argument handling ----
sc "arg: no args"                ''  '' --
sc "arg: --tx missing"           ''  '' -- --chain=testnet-a
sc "arg: --chain missing"        ''  '' -- --tx="$T/tx-c3.json"
sc "arg: --chain invalid"        ''  '' -- --tx="$T/tx-c3.json" --chain=mainnet-c
sc "arg: --chain xpr-mainnet (not an accepted spelling)" '' '' -- --tx="$T/tx-c3.json" --chain=xpr-mainnet
sc "arg: tx unreadable"          ''  '' -- --tx=/nonexistent/path --chain=testnet-a
sc "arg: tx without actions"     ''  '' -- --tx="$T/tx-empty.json" --chain=testnet-a
sc "arg: unknown flag"           ''  '' -- --tx="$T/tx-c3.json" --chain=testnet-a --foo
sc "arg: --endpoint= refused"    ''  '' -- --tx="$T/tx-c3.json" --chain=testnet-a --endpoint=https://example.invalid
sc "arg: -u refused"             ''  '' -- -u

# ---- gate 2 ----
sc "gate 2: token missing"       @none  '' -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "gate 2: token stale (tight)" @stale '' -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "gate 2: token stale (300s)"  @stale '' -- --tx="$T/tx-c3.json" --chain=testnet-a

# ---- gate 1 ----
sc "gate 1: no testnet id"       "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}"
sc "gate 1: id not hex"          "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id=nothex
sc "gate 1: id 32 hex"           "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id=00112233445566778899aabbccddeeff
sc "gate 1: unresolvable"        "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_ZERO" --dry-run-log="$T/dry-c3.json"
sc "gate 1: cycle-2 vs cycle-4"  "$MAIN_TOKEN" '' -- --tx="$T/tx-c4.json" "${M[@]}" --testnet-tx-id="$SBH_CYCLE2" --dry-run-log="$T/dry-c4.json"
sc "gate 1: no extractable actions" "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_NOACT" --dry-run-log="$T/dry-c3.json"
sc "gate 1: non-object .data"    "$MAIN_TOKEN" '' -- --tx="$T/tx-hex.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-c3.json"
sc "gate 1: updateauth vs transfer evidence" "$MAIN_TOKEN" '' -- --tx="$T/tx-upd.json" "${M[@]}" --testnet-tx-id="$SBH_UPD_DIFF" --dry-run-log="$T/dry-c3.json"
sc "gate 1: XPR_TESTNET_RPC = the profile's history base" "$MAIN_TOKEN" '' XPR_TESTNET_RPC=https://test.proton.eosusa.io -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-c3.json"

# ---- gate 4 ----
sc "gate 4: no dry-run log"      "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16"
sc "gate 4: dry-run log empty"   "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/tx-nonexistent"
sc "gate 4: prefix mismatch"     "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-c4.json"
sc "gate 4: no prefix"           "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-noprefix.json"
sc "gate 4: wrong target chain"  "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-wrongchain.json"
sc "gate 4: not JSON (anchor)"   "$MAIN_TOKEN" '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-text.txt"

# ---- gate 2b ----
sc "gate 2b: mainnet, testnet-bound token" '{"chain":"testnet-a"}' '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-c3.json"
sc "gate 2b: mainnet, bare token"          ''                      '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-c3.json"
sc "gate 2b: mainnet, unrecognized chain"  '{"chain":"moon"}'      '' -- --tx="$T/tx-c3.json" "${M[@]}" --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-c3.json"
sc "gate 2b: testnet, tx_sha256 mismatch"  "{\"chain\":\"testnet-a\",\"tx_sha256\":\"$SBH_ZERO\"}" '' -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "gate 2b: testnet, proton-test alias token" '{"chain":"proton-test"}' '' -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive

# ---- gate 3 ----
sc "gate 3: testnet chain_id mismatch" '' '' STUB_CHAIN_ID=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "gate 3: mainnet answers testnet id" "$MAIN_TOKEN" '' STUB_CHAIN_ID="$SBH_XPR_TEST_CID" -- --tx="$T/tx-c4.json" "${M[@]}" --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
sc "gate 3: chain:set fails"     '' '' STUB_CHAINSET_RC=1 -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "gate 3: chain:info unparseable" '' '' 'STUB_CHAIN_INFO_RAW=Error: connect ECONNREFUSED' -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "gate 3: override EQUAL to the profile (testnet)" '' '' FYD_TESTNET_CHAIN_ID="$SBH_XPR_TEST_CID" -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "gate 3: override EQUAL to the profile (mainnet)" "$MAIN_TOKEN" '' FYD_MAINNET_CHAIN_ID="$SBH_XPR_MAIN_CID" -- --tx="$T/tx-c4.json" "${M[@]}" --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
sc "gate 3: empty override = unset" '' '' FYD_TESTNET_CHAIN_ID= -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive

# ---- confirmation prompt ----
sc "confirm: testnet, wrong phrase" '' 'yes' -- --tx="$T/tx-c3.json" --chain=testnet-a
sc "confirm: testnet, EOF"          '' ''    -- --tx="$T/tx-c3.json" --chain=testnet-a
sc "confirm: testnet, correct phrase → push" '' 'BROADCAST testnet-a
' -- --tx="$T/tx-c3.json" --chain=testnet-a
sc "confirm: mainnet, correct phrase → push" "$MAIN_TOKEN" 'BROADCAST mainnet-a
' -- --tx="$T/tx-c4.json" --chain=mainnet-a --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"

# ---- the push (processed profile: trace in the answer) ----
sc "push: testnet processed → tx_id"   '' '' -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "push: testnet proton-test alias"   '' '' -- --tx="$T/tx-c3.json" --chain=proton-test --non-interactive
sc "push: testnet chain+sha bound"     "{\"chain\":\"testnet-a\",\"tx_sha256\":\"$C3_SHA\"}" '' -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "push: mainnet cycle-4 all gates"   "$MAIN_TOKEN" '' -- --tx="$T/tx-c4.json" "${M[@]}" --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
sc "push: mainnet alias proton"        '{"chain":"proton"}' '' -- --tx="$T/tx-c4.json" --chain=proton --non-interactive --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
sc "push: mainnet updateauth + text dry-run" "$MAIN_TOKEN" '' -- --tx="$T/tx-upd.json" "${M[@]}" --testnet-tx-id="$SBH_UPD_SAME" --dry-run-log="$T/dry-text.txt"
sc "push: answer carries only id"      '' '' STUB_PUSH_MODE=idfield -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "push: answer carries only transaction_id" '' '' STUB_PUSH_MODE=idonly -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "push: chain rejects"               '' '' STUB_PUSH_MODE=fail -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "push: answer without any id"       '' '' STUB_PUSH_MODE=noid -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "push: mainnet chain rejects"       "$MAIN_TOKEN" '' STUB_PUSH_MODE=fail -- --tx="$T/tx-c4.json" "${M[@]}" --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"

if [ "$WRITE" = "1" ]; then
	mkdir -p "$(dirname "$GOLDEN")"
	cp "$OUT" "$GOLDEN"
	echo "wrote $GOLDEN ($(grep -c '^=== ' "$GOLDEN") scenarios) from $W"
	exit 0
fi

N="$(grep -c '^=== ' "$OUT")"
if [ ! -r "$GOLDEN" ]; then
	echo "FAIL golden file missing: $GOLDEN"
	exit 1
fi
if diff -u "$GOLDEN" "$OUT" > "$T/diff.txt"; then
	echo "PASS all $N default-profile scenarios reproduce the pre-profile wrapper byte-for-byte (rc, stdout, stderr, audit, call order)"
	echo "test-safe-broadcast-equivalence.sh: PASS=$N FAIL=0"
	exit 0
fi
echo "FAIL default-profile behaviour differs from the pre-profile wrapper:"
sed 's/^/  /' "$T/diff.txt" | head -80
echo "test-safe-broadcast-equivalence.sh: FAIL"
exit 1
