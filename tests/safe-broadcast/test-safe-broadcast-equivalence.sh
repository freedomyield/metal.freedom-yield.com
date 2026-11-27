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
#   transition was rehearsed on (full-tree command below).
#   The current wrapper must reproduce it byte-for-byte. The call list makes
#   this stronger than an exit-code match: the same endpoints are asked the
#   same questions in the same order.
#
#   Every scenario runs with a VALID proton-cli.json fixture (compiled-in
#   networks, no `endpoints` override) — the state the operator's keystores
#   are in when scripts/install-rehearsal-preflight.sh check 10 is green — so
#   the new gate-3 host check passes and must not change any outcome.
#
#   Exit 7 (audit-log write failure) is reproduced without touching any real
#   file: an `id` stub names a nonexistent user, so the fallback log path is
#   a nonexistent relative directory, and the primary is pointed at a
#   directory.
#
#   REGENERATING THE GOLDEN needs the FULL base tree, not just the wrapper
#   file (it sources scripts/lib/require-keystore-home.sh, whose base copy
#   must be used too):
#       git archive 8a79fd5 | tar -x -C <tree>
#       SB_EQ_WRAPPER=<tree>/bin/safe-broadcast \
#         bash tests/safe-broadcast/test-safe-broadcast-equivalence.sh --write-golden
#   Never regenerate it from the current code — that would pin nothing.
#
#   Deliberately NOT here (they are intended, stricter changes, pinned in
#   test-safe-broadcast-profiles.sh): an FYD_*_CHAIN_ID override that
#   DIFFERS from the profile (old: gate 3 compared against the override;
#   now: refused before any gate), an XPR_TESTNET_RPC that is not one of the
#   profile's history bases (old: used unchecked; now: gate 1 refuses), and
#   any proton-cli.json that fails the new host check.
#   Also NOT here (2026-11-17, the double-inscription guard): the 21 scenarios
#   that reach the confirmation screen or the push. Each now passes through the
#   history library, check A, the attempt journal, the second chain:info, the
#   expiration header and the outcome classification, so its record changed on
#   purpose; they are pinned in test-safe-broadcast-outcome.sh (group MV), and
#   their blocks were DELETED from the golden file (nothing was regenerated):
#     gate 1: XPR_TESTNET_RPC = the profile's history base
#     gate 2b: testnet, proton-test alias token
#     gate 3: override EQUAL to the profile (testnet) / (mainnet) / empty override = unset
#     confirm: testnet wrong phrase / EOF / correct phrase; mainnet correct phrase
#     push: testnet processed, proton-test alias, chain+sha bound; mainnet cycle-4,
#           alias proton, updateauth + text dry-run; answer with only id / only
#           transaction_id; chain rejects (now 10); answer without any id (now 10);
#           mainnet chain rejects (now 10)
#     audit: log write fails (now 13: the journal cannot be read)
#   The block "keystore guard: HOME = login home → exit 8" stays in the golden
#   file unchanged, but since 2026-11-27 (L7c) the wrapper is no longer run
#   with HOME = the login home: the wrapper uses jq before its guard, so such a
#   run cannot go through tests/lib/real-home-fence.sh. Instead the guard
#   library itself is called inside the fence with the wrapper's path as the
#   caller, and its refusal text must equal that block's "ERROR (keystore
#   guard" lines byte-for-byte; the block is left out of the whole-file
#   compare. That the wrapper calls the guard before its first proton / $HOME
#   use is pinned in test-safe-broadcast.sh (source order). --write-golden
#   does not write that block: carry it over by hand.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GOLDEN="$HERE/fixtures/equivalence-golden.txt"
WRITE=0
[ "${1:-}" = "--write-golden" ] && WRITE=1

# shellcheck source=tests/safe-broadcast/sb-harness.sh
. "$HERE/sb-harness.sh"
# shellcheck source=tests/lib/assert.sh
. "$ROOT/tests/lib/assert.sh"
# shellcheck source=tests/lib/real-home-fence.sh
. "$ROOT/tests/lib/real-home-fence.sh"
sbh_init
trap 'rm -rf "$SBH_T"' EXIT

# Default: a TREE around the repo wrapper whose copy of scripts/lib/anchor-history-read.sh
# is the harness stub (the wrapper loads that library for every run, and none of the
# scenarios below reads history). SB_EQ_WRAPPER (a full base tree) still wins.
if [ -z "${SB_EQ_WRAPPER:-}" ]; then
	sbh_tree "$SBH_T/tree" "$ROOT/bin/safe-broadcast"
	SB_EQ_WRAPPER="$SBH_T/tree/bin/safe-broadcast"
fi
W="$SB_EQ_WRAPPER"
case "$W" in /*) ;; *) W="$PWD/$W" ;; esac
T="$SBH_T"
# Run from the temp root: the exit-7 scenario's fallback audit path is the
# RELATIVE "~zzsbnouser9/…", which must resolve inside this throwaway dir.
cd "$T" || exit 1
OUT="$T/actual.txt"
: > "$OUT"

MAIN_TOKEN='{"chain":"mainnet-a"}'

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
		# the wrapper's own path ($0) appears in some messages
		# (and bash's own "<script>: line N:" diagnostics — N moves with any edit)
		sed -e "s#${W}#<WRAPPER>#g" -e 's#^<WRAPPER>: line [0-9]*:#<WRAPPER>: line <N>:#' "$T/$f" > "$T/$f.w" && mv "$T/$f.w" "$T/$f"
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

# ---- pre-gate environment checks ----
sc "env: proton CLI missing"     '' '' "PATH=$SBH_PATH_NOPROTON" -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
# (the keystore-guard scenario with HOME = the login home: see the header and
#  the fenced library call just before the whole-file compare below)

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
sc "gate 1: v2-shaped answer (trx_id, no id) on the v1 endpoint → refuse" "$MAIN_TOKEN" '' -- --tx="$T/tx-c4.json" "${M[@]}" --testnet-tx-id="$SBH_V2SHAPE" --dry-run-log="$T/dry-c4.json"
sc "gate 1: curl missing"        "$MAIN_TOKEN" '' "PATH=$SBH_PATH_NOCURL" -- --tx="$T/tx-c4.json" "${M[@]}" --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"

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

# ---- gate 3 ----
sc "gate 3: testnet chain_id mismatch" '' '' STUB_CHAIN_ID=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "gate 3: mainnet answers testnet id" "$MAIN_TOKEN" '' STUB_CHAIN_ID="$SBH_XPR_TEST_CID" -- --tx="$T/tx-c4.json" "${M[@]}" --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
sc "gate 3: chain:set fails"     '' '' STUB_CHAINSET_RC=1 -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive
sc "gate 3: chain:info unparseable" '' '' 'STUB_CHAIN_INFO_RAW=Error: connect ECONNREFUSED' -- --tx="$T/tx-c3.json" --chain=testnet-a --non-interactive

# ---- confirmation prompt and the push ----
# (no scenario here: every one of them now passes through check A, the attempt
#  journal, the expiration header and the outcome classification — they are
#  pinned in test-safe-broadcast-outcome.sh, group MV)

if [ "$WRITE" = "1" ]; then
	mkdir -p "$(dirname "$GOLDEN")"
	cp "$OUT" "$GOLDEN"
	echo "wrote $GOLDEN ($(grep -c '^=== ' "$GOLDEN") scenarios) from $W"
	exit 0
fi

N="$(grep -c '^=== ' "$OUT")"
if [ ! -r "$GOLDEN" ]; then
	t_fail "golden file missing: $GOLDEN"
	t_summary safe-broadcast-equivalence || true
	exit 1
fi
# ---- keystore guard: HOME = login home (the library, inside the fence) ----
GUARD_BLOCK_NAME="keystore guard: HOME = login home → exit 8"
# golden_block_stderr_from <name> <first line prefix> — the golden block's
# stderr lines from the first one that starts with the prefix.
golden_block_stderr_from() {
	awk -v name="=== $1" -v pre="$2" '
		$0 == name { inb = 1; next }
		inb && /^=== / { exit }
		inb && $0 == "--- stderr" { ine = 1; next }
		inb && ine && /^--- / { exit }
		inb && ine && (on || index($0, pre) == 1) { on = 1; print }' "$GOLDEN"
}
GUARD_WANT="$T/guard-want.txt"
golden_block_stderr_from "$GUARD_BLOCK_NAME" "ERROR (keystore guard" > "$GUARD_WANT"
GUARD_LIB="$(dirname "$W")/../scripts/lib/require-keystore-home.sh"
# shellcheck disable=SC2016  # $1 / $2 are the inner shell's arguments
run_with_real_login_home bash -c '. "$1"; require_project_keystore_home "$2"' _ "$GUARD_LIB" "$W" \
	</dev/null >/dev/null 2>"$T/guard.err"; GUARD_RC=$?
sed -e "s#${W}#<WRAPPER>#g" "$T/guard.err" > "$T/guard.err.w"
sbh_norm "$T/guard.err.w" > "$T/guard-got.txt"
if [ ! -s "$GUARD_WANT" ]; then
	t_fail "keystore guard: the golden block '$GUARD_BLOCK_NAME' has no ERROR (keystore guard lines"
elif [ "$GUARD_RC" -eq 1 ] && cmp -s "$GUARD_WANT" "$T/guard-got.txt"; then
	t_pass "keystore guard: HOME = login home → the library (in the fence) refuses with the golden block's text, byte-for-byte"
else
	t_fail "keystore guard: HOME = login home → the library (in the fence) rc=$GUARD_RC (want 1) or its text differs from the golden block"
	diff -u "$GUARD_WANT" "$T/guard-got.txt" | sed 's/^/  /' | head -20
fi

# The whole-file compare leaves the block above out of the golden file.
GOLDEN_CMP="$T/golden-cmp.txt"
awk -v name="=== $GUARD_BLOCK_NAME" '$0 == name { skip = 1; next } /^=== / { skip = 0 } !skip' "$GOLDEN" > "$GOLDEN_CMP"
if diff -u "$GOLDEN_CMP" "$OUT" > "$T/diff.txt"; then
	t_pass "all $N default-profile scenarios reproduce the pre-profile wrapper byte-for-byte (rc, stdout, stderr, audit, call order)"
	t_summary safe-broadcast-equivalence || exit 1
	exit 0
fi
t_fail "default-profile behaviour differs from the pre-profile wrapper:"
sed 's/^/  /' "$T/diff.txt" | head -80
t_summary safe-broadcast-equivalence || true
exit 1
