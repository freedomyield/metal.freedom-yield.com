#!/usr/bin/env bash
# tests/safe-broadcast/test-safe-broadcast-outcome.sh — the double-inscription
# guard of bin/safe-broadcast (design 2026-10-16, sections 3-5 and 11; operator
# decisions J1 (a) and J2): check A (is this cycle's anchor already on chain),
# the attempt journal (an earlier attempt may still land), the expiration
# header, and the classification of what the push printed.
#
# CHAIN: none. proton-cli and curl are stubs on PATH (sb-harness.sh); the T1
#        history library is the harness STUB (sbh_ahr_stub_lib), so nothing is
#        signed, sent or read from a network. Every case runs the wrapper of a
#        throwaway tree. PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Case names start with their property id (A1, A2, A3, J1, A7, A8, SH, LD, B1,
# B3-B9, JR, C2, MV): the lane report maps each mutation to the cases it turns
# red. OC_ONLY=<ERE of ids> runs only those groups (used for mutation runs).
#
# Sample names are made up (actor fxanchor, sink fxsink, other account
# fxstranger); the older harness fixtures keep their own names and are used as
# they are. The history base URLs are read from the profile file, never typed.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=tests/safe-broadcast/sb-harness.sh
. "$HERE/sb-harness.sh"
# shellcheck source=tests/lib/assert.sh
. "$ROOT/tests/lib/assert.sh"
sbh_init
trap 'rm -rf "$SBH_T"' EXIT
T="$SBH_T"
# The exit-7 / unreadable-log cases name a RELATIVE fallback audit path that
# must resolve inside this throwaway dir (see the equivalence suite).
cd "$T" || exit 1
CFG="$(sbh_cfg_path)"
PROFILES="$ROOT/config/a-chain-profiles.json"
TREE="$T/tree"
sbh_tree "$TREE" "$ROOT/bin/safe-broadcast"
W="$TREE/bin/safe-broadcast"

ok()  { t_pass "$1"; }
bad() {
	t_fail "$1"; printf '      %s\n' "$2"
	sed 's/^/      err| /' "$T/err" | head -14
	sed 's/^/      call| /' "$SBH_CALLS" | head -14
}
# sel <id> — run this group? (OC_ONLY empty = everything)
sel() { [ -z "${OC_ONLY:-}" ] || printf '%s' "$1" | grep -Eq "^(${OC_ONLY})\$"; }

# check <name> <rc> [err:<s>] [noerr:<s>] [out:<exact>] [call:<s>] [nocall:<s>]
#       [calls:<s>=<n>] [audit:<s>] [noaudit] [alines:<n>] [noproton]
check() {
	local name="$1" want_rc="$2" a why="" k n
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
			calls:*)  k="${a#calls:}"
			          n="$(grep -cF -- "${k%=*}" "$SBH_CALLS")"
			          [ "$n" = "${k##*=}" ] || why="calls matching '${k%=*}' = $n, want ${k##*=}" ;;
			audit:*)  grep -qF -- "${a#audit:}" "$T/audit.log" || why="audit lacks: ${a#audit:}" ;;
			noaudit)  [ -s "$T/audit.log" ] && why="audit log written" ;;
			alines:*) n="$(grep -c '' "$T/audit.log")"
			          [ "$n" = "${a#alines:}" ] || why="audit has $n line(s), want ${a#alines:}" ;;
			noproton) grep -q '^proton ' "$SBH_CALLS" && why="proton-cli stub was invoked: $(grep '^proton ' "$SBH_CALLS" | head -1)" ;;
		esac
	done
	if [ -z "$why" ]; then ok "$name"; else bad "$name" "$why"; fi
}

# ---- fixtures and helpers -----------------------------------------------------
MT='{"chain":"mainnet-a"}'
TT='{"chain":"testnet-a"}'
TARGS=(--tx="$T/tx-c3.json" --chain=testnet-a --non-interactive)
MARGS=(--tx="$T/tx-c4.json" --chain=mainnet-a --non-interactive --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json")
ACTOR="$(jq -r '.actions[0].authorization[0].actor' "$T/tx-c3.json")"
BASE_TEST="$(jq -r '.profiles["xpr-testnet"].history_bases[0]' "$PROFILES")"
BASE_MAIN="$(jq -r '.profiles["xpr-mainnet"].history_bases[0]' "$PROFILES")"
C3_SHA="$(jq -c . "$T/tx-c3.json" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}')"
JSHA="$(printf 'abcd0001%.0s' 1 2 3 4 5 6 7 8)"
FXTX="$(printf 'fe120000%.0s' 1 2 3 4 5 6 7 8)"
HEAD1="2030-06-15T12:00:00.250"
HEAD2="2030-06-15T12:30:30.900"
EXP2="2030-06-15T12:40:30"
act3='{"act":{"account":"eosio.token","name":"transfer","data":{"memo":"fya1c3-test"}}}'

# tz <offset-seconds> / tn <offset-seconds>: now+offset as YYYY-MM-DDTHH:MM:SSZ / without the Z
tz() { jq -nr --argjson o "$1" '(now | floor) + $o | todate'; }
tn() { jq -nr --argjson o "$1" '(now | floor) + $o | todate | rtrimstr("Z")'; }

FOUND="{\"verdict\":\"found\",\"trx_id\":\"$FXTX\",\"block_num\":123456,\"timestamp\":\"2026-11-01T00:00:00.000\",\"scanned\":3,\"floor\":\"fya1c1\"}"
FOUND_LATER="{\"verdict\":\"found_later\",\"trx_id\":\"$FXTX\",\"block_num\":123457,\"timestamp\":\"2026-11-02T00:00:00.000\",\"scanned\":1,\"floor\":null}"
CLEAR_NOFLOOR='{"verdict":"clear","trx_id":null,"block_num":null,"timestamp":null,"scanned":9,"floor":null}'
CLEAR_FLOOR='{"verdict":"clear","trx_id":null,"block_num":null,"timestamp":null,"scanned":4,"floor":"fya1c1"}'

# ahr_set <file> <content> [<rc>] — drive the library stub
ahr_set() { printf '%s' "$2" > "$SBH_AHR_DIR/$1.out"; [ -z "${3:-}" ] || printf '%s' "$3" > "$SBH_AHR_DIR/$1.rc"; }
ahr_rc()  { printf '%s' "$2" > "$SBH_AHR_DIR/$1.rc"; }
# begin <token> — fresh state for the next scenario
begin() { sbh_reset; sbh_token "$1"; }
# go [VAR=v ...] -- args  /  goi <stdin> [VAR=v ...] -- args
go()  { sbh_run - '' "$W" "$@"; }
goi() { local in="$1"; shift; sbh_run - "$in" "$W" "$@"; }
# the journal: pre / post lines in the wrapper's own format (TAB separated)
jpre() { # <ts> <chain> <memo_prefix> <expiration>
	printf '%s\tinvoker=u\twrapper=safe-broadcast\tphase=pre\tchain=%s\ttx_sha256=%s\ttestnet_txid=none\tmemo_prefix=%s\texpiration=%s\tprofile=xpr-testnet\n' \
		"$1" "$2" "$JSHA" "$3" "$4" >> "$T/audit.log"
}
jpre_legacy() { # <ts> <chain>  — a pre line written before memo_prefix existed
	printf '%s\tinvoker=u\twrapper=safe-broadcast\tphase=pre\tchain=%s\ttx_sha256=%s\ttestnet_txid=none\n' "$1" "$2" "$JSHA" >> "$T/audit.log"
}
jpost() { # <ts> <chain> <rc> [<outcome>]
	printf '%s\tinvoker=u\twrapper=safe-broadcast\tphase=post\tchain=%s\ttx_sha256=%s\trc=%s\ttx_id=none%s\n' \
		"$1" "$2" "$JSHA" "$3" "${4:+	outcome=$4}" >> "$T/audit.log"
}
mk() { jq "$2" "$T/tx-c3.json" > "$T/$1"; }   # <file> <jq filter> — a variant of the testnet anchor tx

# ===========================================================================
if sel A1; then
echo "── A1 check A: the prefix is already on chain ──"
begin "$TT"; ahr_set find "$FOUND" 0
go -- "${TARGS[@]}"
check "A1-testnet-found-non-interactive → 11, nothing sent, no pre line" 11 \
	"err:fya1c3" "err:$FXTX" "err:123456" "err:2026-11-01T00:00:00.000" "err:nothing was signed" \
	"calls:ahr_find_cycle_anchor=1" "call:ahr_find_cycle_anchor $BASE_TEST $ACTOR fya1c3" \
	"nocall:proton transaction:push" noaudit
begin "$MT"; ahr_set find "$FOUND" 0
go -- "${MARGS[@]}"
check "A1-mainnet-found-non-interactive → 11, nothing sent, no pre line" 11 \
	"err:fya1c4" "err:$FXTX" "call:ahr_find_cycle_anchor $BASE_MAIN $ACTOR fya1c4" \
	"nocall:proton transaction:push" noaudit
begin "$TT"; ahr_set find "$FOUND" 0
goi '' -- --tx="$T/tx-c3.json" --chain=testnet-a
check "A1-testnet-found-interactive → 11 BEFORE the confirmation screen" 11 \
	"noerr:BROADCAST CONFIRMATION" "err:$FXTX" "nocall:proton transaction:push" noaudit
begin "$TT"; ahr_set find "$FOUND_LATER" 0
go -- "${TARGS[@]}"
check "A1-found_later → 11 (a later cycle is on chain)" 11 "err:$FXTX" "err:123457" "nocall:proton transaction:push" noaudit
fi

if sel A2; then
echo "── A2 check A again right before the push ──"
begin "$TT"; ahr_set find.1 "$CLEAR_FLOOR" 0; ahr_set find.2 "$FOUND" 0
go -- "${TARGS[@]}"
check "A2-history flips to found after the prompt → 11, no push, no pre line" 11 \
	"calls:ahr_find_cycle_anchor=2" "nocall:proton transaction:push" noaudit "err:$FXTX"
fi

if sel A3; then
echo "── A3 history unreadable → 12 ──"
a3() { # <name> <err> [setup-command...] — one testnet run, expect 12 and nothing sent
	local n="$1" e="$2"
	shift 2
	begin "$TT"; "$@"
	go -- "${TARGS[@]}"
	check "$n" 12 "err:$e" "err:nothing was sent" "nocall:proton transaction:push" noaudit
}
a3 "A3-find rc 3 (stdout empty) → 12" "$BASE_TEST" ahr_rc find 3
a3 "A3-index not fresh (fresh rc 3) → 12, find is never called" "stale" ahr_rc fresh 3
check "A3-index not fresh: ahr_find_cycle_anchor is not called" 12 "calls:ahr_find_cycle_anchor=0" "calls:ahr_index_fresh=1"
a3 "A3-answer is not JSON → 12" "not a usable answer" ahr_set find 'not json' 0
a3 "A3-answer is a JSON array → 12" "not a usable answer" ahr_set find '[1,2]' 0
a3 "A3-answer: unknown verdict → 12" "not a usable answer" ahr_set find '{"verdict":"maybe","trx_id":null,"block_num":null,"timestamp":null,"scanned":1,"floor":"fya1c1"}' 0
a3 "A3-answer: no verdict key → 12" "not a usable answer" ahr_set find '{"trx_id":null,"block_num":null,"timestamp":null,"scanned":1,"floor":"fya1c1"}' 0
a3 "A3-answer: found with trx_id null → 12" "not a usable answer" \
	ahr_set find '{"verdict":"found","trx_id":null,"block_num":12,"timestamp":"2026-11-01T00:00:00.000","scanned":1,"floor":"fya1c1"}' 0
a3 "A3-answer: found with block_num a string → 12" "not a usable answer" \
	ahr_set find "{\"verdict\":\"found\",\"trx_id\":\"$FXTX\",\"block_num\":\"12\",\"timestamp\":\"2026-11-01T00:00:00.000\",\"scanned\":1,\"floor\":\"fya1c1\"}" 0
a3 "A3-answer: floor is a number → 12" "not a usable answer" \
	ahr_set find '{"verdict":"clear","trx_id":null,"block_num":null,"timestamp":null,"scanned":1,"floor":7}' 0
a3 "A3-answer: two lines → 12" "not a usable answer" ahr_set find "$CLEAR_FLOOR
$CLEAR_FLOOR" 0
# an answer holding more than one JSON value is not "one object of the agreed shape"
FLAGARGS=("${TARGS[@]}" --allow-existing-cycle-anchor)
begin "$TT"; ahr_set find "$CLEAR_FLOOR $FOUND_LATER" 0
go -- "${FLAGARGS[@]}"
check "A3-answer holds two JSON values (clear+floor then found_later) → 12, no push" 12 \
	"err:not a usable answer" "err:nothing was sent" "nocall:proton transaction:push" noaudit
begin "$TT"; ahr_set find "$FOUND_LATER $CLEAR_FLOOR" 0
go -- "${FLAGARGS[@]}"
check "A3-answer holds two JSON values (found_later then clear+floor) → 12, no push" 12 \
	"err:not a usable answer" "err:nothing was sent" "nocall:proton transaction:push" noaudit
begin "$MT"; ahr_set find "$CLEAR_FLOOR $FOUND_LATER" 0
go -- "${MARGS[@]}"
check "A3-answer holds two JSON values, mainnet (no flag) → 12, no push" 12 \
	"err:not a usable answer" "nocall:proton transaction:push" noaudit
begin "$TT"; ahr_set find "$CLEAR_FLOOR trailing" 0
go -- "${FLAGARGS[@]}"
check "A3-answer is one object followed by trailing text → 12, no push" 12 \
	"err:not a usable answer" "nocall:proton transaction:push" noaudit
# a profile with no history base at all
jq '.profiles["xpr-testnet"].history_bases = []' "$PROFILES" > "$T/nobase.json"
sbh_tree "$T/nobasetree" "$ROOT/bin/safe-broadcast" "$T/nobase.json"
begin "$TT"
sbh_run - '' "$T/nobasetree/bin/safe-broadcast" -- "${TARGS[@]}"
check "A3-profile without a history base → 12 (nothing to read)" 12 "err:history" "calls:ahr_=0" "nocall:proton transaction:push" noaudit
# two bases: a second, made-up base is added to the testnet profile
jq '.profiles["xpr-testnet"].history_bases += ["https://fx-hist-b.example.net"]' "$PROFILES" > "$T/twobase.json"
sbh_tree "$T/twobasetree" "$ROOT/bin/safe-broadcast" "$T/twobase.json"
TW="$T/twobasetree/bin/safe-broadcast"
begin "$TT"; ahr_rc find.1 3; ahr_set find.2 "$CLEAR_FLOOR" 0
sbh_run - '' "$TW" -- "${TARGS[@]}"
check "A3-two bases: first unreadable, second clear with a floor → proceeds, pushes" 0 \
	"call:ahr_find_cycle_anchor https://fx-hist-b.example.net $ACTOR fya1c3" "calls:proton transaction:push=1"
begin "$TT"; ahr_set find.1 "$CLEAR_FLOOR" 0; ahr_set find.2 "$FOUND" 0
sbh_run - '' "$TW" -- "${TARGS[@]}"
check "A3-two bases: first clear with a floor, second found → 11 (the blocking answer wins)" 11 \
	"calls:ahr_find_cycle_anchor=2" "nocall:proton transaction:push" noaudit
fi

if sel J1; then
echo "── J1 clear without a floor (decision J1 (a)) ──"
begin "$MT"; ahr_set find "$CLEAR_NOFLOOR" 0
go -- "${MARGS[@]}"
check "J1-mainnet: exhausted scan without a floor → 12, nothing sent" 12 "err:floor" "nocall:proton transaction:push" noaudit
begin "$TT"; ahr_set find "$CLEAR_NOFLOOR" 0
go -- "${TARGS[@]}"
check "J1-testnet without the flag: no floor → 12" 12 "err:floor" "nocall:proton transaction:push" noaudit
begin "$TT"; ahr_set find "$CLEAR_NOFLOOR" 0
go -- "${TARGS[@]}" --allow-existing-cycle-anchor
check "J1-testnet with the flag: no floor → WARNING, pushes" 0 \
	"err:WARNING (check A)" "err:no floor" "calls:proton transaction:push=1" "out:$SBH_TXID"
fi

if sel A7; then
echo "── A7 the updateauth shape never reaches check A or the journal ──"
begin "$TT"; jpre_legacy "$(tz -100)" testnet-a
go -- --tx="$T/tx-upd.json" --chain=testnet-a --non-interactive
check "A7-testnet updateauth: no ahr_ call, a stopping journal line is not consulted, pushes" 0 \
	"calls:ahr_=0" "calls:proton transaction:push=1" "audit:memo_prefix=none"
begin "$MT"; jpre_legacy "$(tz -100)" mainnet-a
go -- --tx="$T/tx-upd.json" --chain=mainnet-a --non-interactive --testnet-tx-id="$SBH_UPD_SAME" --dry-run-log="$T/dry-text.txt"
check "A7-mainnet updateauth: no ahr_ call, a stopping journal line is not consulted, pushes" 0 \
	"calls:ahr_=0" "calls:proton transaction:push=1" "audit:memo_prefix=none"
begin "$TT"; ahr_set find "$FOUND" 0
go -- "${TARGS[@]}"
check "A7-control: the SAME setup with an anchor shape does call ahr_ (so 0 above means something)" 11 "calls:ahr_find_cycle_anchor=1"
fi

if sel A8; then
echo "── A8 --allow-existing-cycle-anchor ──"
begin "$MT"
go -- "${MARGS[@]}" --allow-existing-cycle-anchor
check "A8-mainnet + flag → 2, nothing called" 2 "err:testnet-only" "calls:ahr_=0" noproton "calls:curl=0" noaudit
begin "$MT"
go -- --tx="$T/tx-c4.json" --chain=proton --non-interactive --allow-existing-cycle-anchor
check "A8-mainnet alias (proton) + flag → 2, nothing called" 2 "err:testnet-only" "calls:ahr_=0" noproton noaudit
begin "$TT"
go -- "${TARGS[@]}" --allow-existing-cycle-anchor=x
check "A8-flag with a value (--allow-existing-cycle-anchor=x) is an unknown argument → 2" 2 "err:unknown arg" noproton noaudit
begin "$TT"; ahr_set find "$FOUND" 0
go -- "${TARGS[@]}" --allow-existing-cycle-anchor
check "A8-testnet found + flag → WARNING with the trx_id, pushes" 0 \
	"err:WARNING (check A)" "err:$FXTX" "calls:proton transaction:push=1"
begin "$TT"; ahr_set find "$FOUND_LATER" 0
go -- "${TARGS[@]}" --allow-existing-cycle-anchor
check "A8-testnet found_later + flag → still 11" 11 "nocall:proton transaction:push" noaudit
begin "$TT"; ahr_rc find 3
go -- "${TARGS[@]}" --allow-existing-cycle-anchor
check "A8-testnet unreadable + flag → still 12" 12 "nocall:proton transaction:push" noaudit
begin "$TT"
go -- --tx="$T/tx-upd.json" --chain=testnet-a --non-interactive --allow-existing-cycle-anchor
check "A8-flag on a shape that is not an anchor → 2, nothing called" 2 "err:anchor-shaped tx only" "calls:ahr_=0" noproton noaudit
fi

if sel SH; then
echo "── SH shape judgment → 2, nothing called ──"
sh_case() { # <name> <tx-file> <err-substring> [args...]
	local n="$1" f="$2" e="$3"
	begin "$TT"
	go -- --tx="$T/$f" --chain=testnet-a --non-interactive
	check "$n" 2 "err:$e" "calls:ahr_=0" noproton "calls:curl=0" noaudit
}
for k in expiration ref_block_num ref_block_prefix max_net_usage_words max_cpu_usage_ms delay_sec context_free_actions transaction_extensions; do
	mk "tx-hdr-$k.json" ". + {\"$k\": 1}"
	sh_case "SH-top-level key $k → 2" "tx-hdr-$k.json" "$k: a transaction header field"
done
mk tx-hdr-fxunknown.json '. + {"fxunknown": 1}'
sh_case "SH-top-level key fxunknown (not in any list) → 2" tx-hdr-fxunknown.json "fxunknown"
sh_case "SH-testnet: .data is not an object → 2" tx-hex.json "not an object"
mk tx-two-prefix.json '.actions += [(.actions[0] | .data.memo = "fya1c9-x")]'
sh_case "SH-two memo prefixes → 2" tx-two-prefix.json "more than one memo prefix"
mk tx-mixed-actor.json '.actions += [(.actions[0] | .authorization[0].actor = "fxstranger" | .data.from = "fxstranger")]'
sh_case "SH-two different authorization actors → 2" tx-mixed-actor.json "ONE and the same actor"
mk tx-from-other.json '.actions[0].data.from = "fxstranger"'
sh_case "SH-data.from differs from the authorization actor → 2" tx-from-other.json "data.from must be"
mk tx-no-auth.json '.actions[0].authorization = []'
sh_case "SH-authorization is empty → 2" tx-no-auth.json "non-empty authorization"
# the tx file is exactly ONE JSON object (jq -e looks at the last value only)
cat "$T/tx-c3.json" "$T/tx-c3.json" > "$T/tx-two-objects.json"
sh_case "SH-tx file holds two JSON objects → 2" tx-two-objects.json "not exactly one JSON object"
{ cat "$T/tx-c3.json"; printf ' trailing text\n'; } > "$T/tx-trailing.json"
sh_case "SH-tx file is one object followed by trailing text → 2" tx-trailing.json "tx file"
fi

if sel LD; then
echo "── LD the library load is checked first ──"
ld_case() { # <name> <tree> — the tree's lib was damaged by the caller
	begin "$TT"
	sbh_run - '' "$2/bin/safe-broadcast" -- "${TARGS[@]}"
	check "$1" 4 "err:anchor-history-read" noproton "calls:curl=0" "calls:ahr_=0" noaudit
}
sbh_tree "$T/ld1" "$ROOT/bin/safe-broadcast"; rm -f "$T/ld1/scripts/lib/anchor-history-read.sh"
ld_case "LD-no library file → 4" "$T/ld1"
sbh_tree "$T/ld2" "$ROOT/bin/safe-broadcast"; printf 'return 1\n' > "$T/ld2/scripts/lib/anchor-history-read.sh"
ld_case "LD-the library fails to load → 4" "$T/ld2"
for fn in ahr_find_cycle_anchor ahr_index_fresh ahr_utc_to_epoch ahr_epoch_to_utc; do
	sbh_tree "$T/ld-$fn" "$ROOT/bin/safe-broadcast"
	sed "s/^${fn}() {/${fn}_gone() {/" "$T/ld-$fn/scripts/lib/anchor-history-read.sh" > "$T/ld-$fn.lib" && mv "$T/ld-$fn.lib" "$T/ld-$fn/scripts/lib/anchor-history-read.sh"
	ld_case "LD-function $fn is missing → 4" "$T/ld-$fn"
done
for v in '' 'x' '3x' '３０'; do
	sbh_tree "$T/ld-lag" "$ROOT/bin/safe-broadcast"
	sed "s/^AHR_INDEX_MAX_LAG_BLOCKS=.*/AHR_INDEX_MAX_LAG_BLOCKS=$v/" "$T/ld-lag/scripts/lib/anchor-history-read.sh" > "$T/ld-lag.lib" && mv "$T/ld-lag.lib" "$T/ld-lag/scripts/lib/anchor-history-read.sh"
	ld_case "LD-AHR_INDEX_MAX_LAG_BLOCKS='$v' is not digits → 4" "$T/ld-lag"
done
sbh_tree "$T/ld-unset" "$ROOT/bin/safe-broadcast"
sed '/^AHR_INDEX_MAX_LAG_BLOCKS=/d' "$T/ld-unset/scripts/lib/anchor-history-read.sh" > "$T/ld-unset.lib" && mv "$T/ld-unset.lib" "$T/ld-unset/scripts/lib/anchor-history-read.sh"
ld_case "LD-AHR_INDEX_MAX_LAG_BLOCKS is not defined → 4" "$T/ld-unset"
begin "$MT"
sbh_run - '' "$T/ld1/bin/safe-broadcast" -- "${MARGS[@]}"
check "LD-mainnet run with no library file → 4 as well (the load is for every run)" 4 "calls:curl=0" noproton
fi

if sel B1; then
echo "── B1 the expiration header ──"
BEFORE="$(jq -c . "$T/tx-c3.json" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; })"
begin "{\"chain\":\"testnet-a\",\"tx_sha256\":\"$C3_SHA\"}"
go "STUB_HEAD_TIME=$HEAD1" "STUB_HEAD_TIME_2=$HEAD2" -- "${TARGS[@]}"
check "B1-token bound to tx_sha256 still passes; stderr and the pre line carry the same E" 0 \
	"out:$SBH_TXID" "err:expiration=$EXP2" "audit:expiration=$EXP2" "calls:proton chain:info=2"
WANT="$(jq -c --arg e "$EXP2" '. + {expiration: $e}' "$T/tx-c3.json")"
GOT="$(cat "$T/push-arg.json" 2>/dev/null || true)"
t_assert_eq "B1-the pushed JSON is the tx plus expiration = SECOND head + 600 s, no Z" "$WANT" "$GOT"
AFTER="$(jq -c . "$T/tx-c3.json" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; })"
t_assert_eq "B1-the tx file itself is unchanged" "$BEFORE" "$AFTER"
begin "$MT"
go "STUB_HEAD_TIME=$HEAD1" "STUB_HEAD_TIME_2=$HEAD2" -- "${MARGS[@]}"
GOT="$(jq -r .expiration "$T/push-arg.json" 2>/dev/null || true)"
t_assert_eq "B1-mainnet: the same expiration" "$EXP2" "$GOT"
fi

if sel B3; then
echo "── B3 classification of what the push printed ──"
b3() { # <name> <mode> <rc> <outcome> [checks...]
	local n="$1" m="$2" r="$3" o="$4"
	shift 4
	begin "$TT"
	go "STUB_PUSH_MODE=$m" "STUB_HEAD_TIME=$HEAD1" "STUB_HEAD_TIME_2=$HEAD2" -- "${TARGS[@]}"
	check "$n" "$r" "audit:outcome=$o" "err:expiration=$EXP2" "calls:proton transaction:push=1" "$@"
}
# the banner of an UNKNOWN outcome names E, the prefix and the earliest retry
UNK=("err:BROADCAST OUTCOME UNKNOWN" "err:$EXP2" "err:fya1c3" "err:earliest possible retry" "out:")
b3 "B3-reject_assert → 6 rejected" reject_assert 6 rejected "out:" "err:nothing will land"
b3 "B3-reject_assert_ansi (colour codes + Hint line) → 6 rejected" reject_assert_ansi 6 rejected "out:"
b3 "B3-reject_net → 6 rejected, NET exhausted" reject_net 6 rejected "err:NET exhausted" "out:"
b3 "B3-dup (duplicate transaction) → 10" dup 10 unknown "${UNK[@]}"
b3 "B3-dup_assert (an allowed text AND duplicate) → 10: duplicate is looked at before the allowlist" dup_assert 10 unknown "${UNK[@]}"
b3 "B3-dump_then_assert → 10" dump_then_assert 10 unknown "${UNK[@]}"
b3 "B3-assert_with_signal (one allowed line that names an RPC failure) → 10" assert_with_signal 10 unknown "${UNK[@]}"
b3 "B3-abort → 10" abort 10 unknown "${UNK[@]}"
b3 "B3-garbage (deadline exceeded) → 10" garbage 10 unknown "${UNK[@]}"
b3 "B3-crash (rc 1, assertion text on stderr) → 10" crash 10 unknown "${UNK[@]}"
b3 "B3-noid ({}) → 10" noid 10 unknown "${UNK[@]}"
b3 "B3-processed_soft (status soft_fail) → 10" processed_soft 10 unknown "${UNK[@]}"
b3 "B3-processed → 0 submitted" processed 0 submitted "out:$SBH_TXID"
fi

if sel B4; then
echo "── B4 id-only profile (PulseVM fixture) ──"
PVM_TEST_CID="$(printf 'd4c3b2a1%.0s' 1 2 3 4 5 6 7 8)"
jq --arg t "$PVM_TEST_CID" '
	.profiles["pulsevm-testnet"] += {chain_id: $t, node_hosts: ["pvm-test-node.example.net"],
		history_bases: ["https://pvm-test-hist.example.net"],
		explorer_base: "https://pvm-test-explorer.example.net/tx", proton_network: "proton-test"}' \
	"$PROFILES" > "$T/pvm-profiles.json"
sbh_tree "$T/pvmtree" "$ROOT/bin/safe-broadcast" "$T/pvm-profiles.json"
PW="$T/pvmtree/bin/safe-broadcast"
cfg_set() { local t; t="$(mktemp)"; jq "$1" "$CFG" > "$t" && mv "$t" "$CFG"; }
pvm_begin() { begin "$TT"; rm -f "$T/hist/v2/$SBH_TXID.json"; cfg_set '.endpoints = [{"chain":"proton-test","endpoints":["https://pvm-test-node.example.net/rpc"]}]'; }
pvm_hist() { printf '{"trx_id":"%s","executed":true,"actions":[%s]}\n' "$SBH_TXID" "$act3" > "$T/hist/v2/$SBH_TXID.json"; }
PVM_ENV=(FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet "STUB_CHAIN_ID=$PVM_TEST_CID" FYD_SB_CONFIRM_INTERVAL=0 FYD_SB_CONFIRM_ATTEMPTS=1 "STUB_HEAD_TIME=$HEAD1" "STUB_HEAD_TIME_2=$HEAD2")
pvm_run() { sbh_run - '' "$PW" "${PVM_ENV[@]}" "$@" -- "${TARGS[@]}"; }
pvm_begin; pvm_run STUB_PUSH_MODE=reject_assert
check "B4-no tx_id + an allowed assertion text → 10 (not 6: no allowlist on id-only)" 10 \
	"err:BROADCAST OUTCOME UNKNOWN" "err:$EXP2" "audit:outcome=unknown" "calls:proton transaction:push=1" "nocall:get_transaction"
pvm_begin; pvm_run STUB_PUSH_MODE=noid
check "B4-answer without any id → 10" 10 "err:BROADCAST OUTCOME UNKNOWN" "audit:outcome=unknown"
pvm_begin; pvm_run STUB_PUSH_MODE=crash
check "B4-push crash → 10 (it was 6 before the guard)" 10 "err:BROADCAST OUTCOME UNKNOWN" "audit:outcome=unknown"
pvm_begin; pvm_run STUB_PUSH_MODE=idonly
check "B4-tx_id but history never confirms → 9 (unchanged)" 9 "err:is NOT confirmed" "audit:confirmed=0" "err:expiration=$EXP2"
pvm_begin; pvm_hist; pvm_run STUB_PUSH_MODE=idonly
check "B4-tx_id confirmed in history → 0" 0 "out:$SBH_TXID" "audit:confirmed=1" "audit:outcome=submitted"
pvm_begin; pvm_hist; pvm_run STUB_PUSH_MODE=idonly_with_dump
check "B4-tx_id but the output carries an RPC dump → 10, no confirmation lookup" 10 \
	"err:BROADCAST OUTCOME UNKNOWN" "nocall:get_transaction" "audit:outcome=unknown"
fi

if sel B5; then
echo "── B5 the attempt journal ──"
B5TS="$(tz -60)"; B5E="$(tn 300)"   # computed once: pre and post must carry the SAME time
b5() { # <name> <want-rc> <post-rc|-> <outcome|-> [checks...] — a same-prefix pre line, E after LIB, optionally its post line
	local n="$1" r="$2" prc="$3" o="$4"
	shift 4
	begin "$TT"; jpre "$B5TS" testnet-a fya1c3 "$B5E"
	if [ "$prc" != "-" ]; then
		if [ "$o" = "-" ]; then jpost "$B5TS" testnet-a "$prc"; else jpost "$B5TS" testnet-a "$prc" "$o"; fi
	fi
	go -- "${TARGS[@]}"
	check "$n" "$r" "$@"
}
b5 "B5-a same-prefix pre line with no post line, E after LIB → 13, no push, nothing appended" 13 - - \
	"err:fya1c3" "err:$B5E" "err:LIB" "nocall:proton transaction:push" "alines:1"
b5 "B5-outcome=submitted, E after LIB → 13" 13 0 submitted "nocall:proton transaction:push" "alines:2"
b5 "B5-outcome=unknown, E after LIB → 13" 13 10 unknown "nocall:proton transaction:push" "alines:2"
b5 "B5-an old post line with no outcome= (rc only) does not release the line → 13" 13 1 - "nocall:proton transaction:push"
b5 "B5-outcome=rejected → the line is ignored, pushes" 0 6 rejected "calls:proton transaction:push=1"
b5 "B5-outcome=refused-gate3-recheck → ignored, pushes" 0 refused-gate3-recheck refused-gate3-recheck "calls:proton transaction:push=1"
# the boundary E = LIB: the stub's LIB is the pre line's expiration, to the second
begin "$TT"; jpre "$B5TS" testnet-a fya1c3 "$B5E"
go "STUB_LIB_TIME=$B5E.000" -- "${TARGS[@]}"
check "B5-E equal to LIB → 13 (equal blocks too), no push" 13 "err:fya1c3" "nocall:proton transaction:push" "alines:1"
begin "$TT"; jpre "$B5TS" testnet-a fya1c3 "$B5E"
go "STUB_LIB_TIME=$(tn 301).000" -- "${TARGS[@]}"
check "B5-E before LIB → the line is ignored, pushes" 0 "calls:proton transaction:push=1"
fi

if sel B6; then
echo "── B6 the journal compares against LIB, not head ──"
begin "$TT"; jpre "2030-01-01T00:00:00Z" testnet-a fya1c3 "2030-01-01T00:05:00"
go "STUB_LIB_TIME=2030-01-01T00:00:00.000" "STUB_HEAD_TIME=2030-01-01T00:10:00.500" -- "${TARGS[@]}"
check "B6-head after E, E after LIB → 13" 13 "nocall:proton transaction:push" "alines:1"
fi

if sel B7; then
echo "── B7 after E is irreversibly past, check A decides ──"
begin "$TT"; jpre "$(tz -900)" testnet-a fya1c3 "$(tn -400)"
go -- "${TARGS[@]}"
check "B7-E before LIB, check A clear → pushes" 0 "calls:proton transaction:push=1" "calls:ahr_find_cycle_anchor=2"
begin "$TT"; jpre "$(tz -900)" testnet-a fya1c3 "$(tn -400)"; ahr_set find "$FOUND" 0
go -- "${TARGS[@]}"
check "B7-E before LIB, check A found → 11" 11 "nocall:proton transaction:push" "err:$FXTX" "alines:1"
fi

if sel B8; then
echo "── B8 pre lines from before memo_prefix existed ──"
begin "$TT"; jpre_legacy "$(tz -100)" testnet-a
go -- "${TARGS[@]}"
check "B8-legacy pre line, TS + 3600 s after LIB → 13" 13 "nocall:proton transaction:push" "alines:1"
begin "$TT"; jpre_legacy "$(tz -4000)" testnet-a
go -- "${TARGS[@]}"
check "B8-legacy pre line, TS + 3600 s before LIB → pushes" 0 "calls:proton transaction:push=1"
begin "$TT"; jpre "$(tz -100)" testnet-a fya1c3 none
go -- "${TARGS[@]}"
check "B8-expiration=none on a same-prefix line is bounded by TS + 3600 s → 13" 13 "nocall:proton transaction:push"
fi

if sel B9; then
echo "── B9 chain times missing or unreadable ──"
begin "$TT"
go STUB_OMIT_LIB=1 -- "${TARGS[@]}"
check "B9-anchor shape: LIB missing (first answer) → 13, nothing sent" 13 "err:last_irreversible_block_time" "nocall:proton transaction:push" noaudit
begin "$TT"
go STUB_OMIT_LIB_2=1 -- "${TARGS[@]}"
check "B9-anchor shape: LIB missing from the SECOND answer only → 13" 13 "nocall:proton transaction:push" noaudit
begin "$TT"
go STUB_LIB_TIME=yesterday -- "${TARGS[@]}"
check "B9-anchor shape: LIB is not a time → 13" 13 "nocall:proton transaction:push" noaudit
begin "$TT"
go "STUB_CHAIN_INFO_RAW={\"chain_id\":\"$SBH_XPR_TEST_CID\",\"head_block_num\":1,\"head_block_time\":\"$HEAD1\",\"last_irreversible_block_time\":12345}" -- "${TARGS[@]}"
check "B9-anchor shape: LIB is a number → 13" 13 "nocall:proton transaction:push" noaudit
begin "$TT"
go STUB_OMIT_LIB=1 -- --tx="$T/tx-upd.json" --chain=testnet-a --non-interactive
check "B9-not an anchor shape: LIB missing → 4" 4 "nocall:proton transaction:push" noaudit
begin "$TT"
go STUB_OMIT_HEAD_TIME_2=1 -- "${TARGS[@]}"
check "B9-anchor shape: head time missing from the second answer → 4" 4 "nocall:proton transaction:push" noaudit
begin "$TT"
go STUB_HEAD_TIME_2=noon -- "${TARGS[@]}"
check "B9-anchor shape: head time is not a time → 4" 4 "nocall:proton transaction:push" noaudit
fi

if sel JR; then
echo "── JR journal edges ──"
begin "$TT"; jpre "$(tz -60)" testnet-a fya1c9 "$(tn 300)"
go -- "${TARGS[@]}"
check "JR-another prefix → ignored, pushes" 0 "calls:proton transaction:push=1"
begin "$TT"; jpre "$(tz -60)" mainnet-a fya1c3 "$(tn 300)"
go -- "${TARGS[@]}"
check "JR-another role (a mainnet line on a testnet run) → ignored, pushes" 0 "calls:proton transaction:push=1"
begin "$TT"; jpre "$(tz -60)" testnet-a none "$(tn 300)"
go -- "${TARGS[@]}"
check "JR-memo_prefix=none (a non-anchor attempt) → ignored, pushes" 0 "calls:proton transaction:push=1"
begin "$TT"; jpre "$(tz -60)" testnet-a fya1c3 "$(tn 300)"; sed -i.bak 's/wrapper=safe-broadcast/wrapper=other-tool/' "$T/audit.log" && rm -f "$T/audit.log.bak"
go -- "${TARGS[@]}"
check "JR-a line of another wrapper → ignored, pushes" 0 "calls:proton transaction:push=1"
begin "$TT"; jpre "not-a-time" testnet-a fya1c3 "$(tn 300)"
go -- "${TARGS[@]}"
check "JR-pre line with an unreadable TS → 13" 13 "nocall:proton transaction:push" "alines:1"
begin "$TT"; jpre "$(tz -60)" moon fya1c3 "$(tn 300)"
go -- "${TARGS[@]}"
check "JR-pre line with an unknown chain value → 13" 13 "nocall:proton transaction:push" "alines:1"
begin "$TT"; jpre "$(tz -60)" "" fya1c3 "$(tn 300)"
go -- "${TARGS[@]}"
check "JR-pre line with an empty chain value → 13" 13 "nocall:proton transaction:push" "alines:1"
begin "$TT"; jpre "$(tz -60)" testnet-a fya1c3 "soon"
go -- "${TARGS[@]}"
check "JR-pre line with an unreadable expiration → 13" 13 "nocall:proton transaction:push" "alines:1"
begin "$TT"; chmod 200 "$T/audit.log"
go -- "${TARGS[@]}"
check "JR-the audit log cannot be read → 13, nothing sent" 13 "err:audit log" "nocall:proton transaction:push"
chmod 600 "$T/audit.log"
# lib_equals_head: PulseVM-like profile compares against HEAD; the xpr profile against LIB
jq '.profiles["xpr-testnet"].lib_equals_head = true | .profiles["xpr-mainnet"].lib_equals_head = true' "$PROFILES" > "$T/libhead.json"
sbh_tree "$T/libheadtree" "$ROOT/bin/safe-broadcast" "$T/libhead.json"
begin "$TT"; jpre "$(tz -60)" testnet-a fya1c3 "$(tn -100)"
sbh_run - '' "$T/libheadtree/bin/safe-broadcast" -- "${TARGS[@]}"
check "JR-lib_equals_head profile: E is before HEAD (LIB = head) → pushes" 0 "calls:proton transaction:push=1"
begin "$TT"; jpre "$(tz -60)" testnet-a fya1c3 "$(tn -100)"
go -- "${TARGS[@]}"
check "JR-control: the same line on the default profile (E after LIB) → 13" 13 "nocall:proton transaction:push"
fi

if sel C2; then
echo "── C2 the second chain:info is checked again ──"
begin "$TT"
go "STUB_CHAIN_ID_2=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" -- "${TARGS[@]}"
check "C2-chain_id differs on the second chain:info → 4, nothing sent, no pre line" 4 \
	"err:after the prompt" "calls:proton chain:info=2" "nocall:proton transaction:push" noaudit
# a chain:info answer holding two JSON values (jq -r prints one line per value)
CI_OK="$(jq -nc --arg c "$SBH_XPR_TEST_CID" --arg h "$(tn 0).500" --arg l "$(tn -170).000" '{chain_id: $c, head_block_num: 1, head_block_time: $h, last_irreversible_block_time: $l}')"
CI_OTHER='{"head_block_num":2}'
CI_WRONG='{"chain_id":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}'
begin "$TT"
go "STUB_CHAIN_INFO_RAW=$CI_OK $CI_OTHER" -- "${TARGS[@]}"
check "C3-first chain:info holds two JSON objects (right chain_id first) → 4, no push" 4 \
	"err:could not parse chain_id" "nocall:proton transaction:push" noaudit
begin "$TT"
go "STUB_CHAIN_INFO_RAW=$CI_OTHER $CI_OK" -- "${TARGS[@]}"
check "C3-first chain:info holds two JSON objects (no chain_id first, right one second) → 4, no push" 4 \
	"err:could not parse chain_id" "nocall:proton transaction:push" noaudit
begin "$TT"
go "STUB_CHAIN_INFO_RAW=$CI_WRONG $CI_OK" -- "${TARGS[@]}"
check "C3-first chain:info holds two JSON objects (wrong chain_id first) → 4, no push" 4 \
	"nocall:proton transaction:push" noaudit
begin "$TT"
go "STUB_CHAIN_INFO_RAW_2=$CI_OK $CI_OTHER" -- "${TARGS[@]}"
check "C2-second chain:info holds two JSON objects (right chain_id in the first) → 4, no push, no pre line" 4 \
	"err:after the prompt" "calls:proton chain:info=2" "nocall:proton transaction:push" noaudit
# the other files read from outside: the dry-run log and the operator token
printf '{"x":1}\n{"dry_run":true,"target_chain":"mainnet-a","memo_prefix":"fya1c4"}\n' > "$T/dry-two.json"
begin "$MT"; ahr_set find "$CLEAR_FLOOR" 0
go -- "${MARGS[@]/--dry-run-log=*/--dry-run-log=$T/dry-two.json}"
check "C2-dry-run log holds two JSON objects → 3 (gate 4), no push" 3 \
	"err:gate 4" "nocall:proton transaction:push" noaudit
begin '{"chain":"mainnet-a"} {"x":1}'; ahr_set find "$CLEAR_FLOOR" 0
go -- "${MARGS[@]}"
check "C2-operator token holds two JSON objects → not chain-bound → mainnet refused 3" 3 \
	"err:gate 2" "nocall:proton transaction:push" noaudit
fi

if sel MV; then
echo "── MV the scenarios that left the equivalence golden ──"
mv_ok() { # <name> <outcome-or-"-"> [checks...] — rc 0, one push
	local n="$1" o="$2"
	shift 2
	check "$n" 0 "out:$SBH_TXID" "calls:proton transaction:push=1" "audit:memo_prefix=" "audit:expiration=" "audit:profile=" "audit:outcome=submitted" "$@"
}
begin ''; goi 'yes' -- --tx="$T/tx-c3.json" --chain=testnet-a
check "MV-confirm: testnet, wrong phrase → 5" 5 "err:ABORTED" "nocall:proton transaction:push" noaudit
begin ''; goi '' -- --tx="$T/tx-c3.json" --chain=testnet-a
check "MV-confirm: testnet, EOF → 5" 5 "err:ABORTED" "nocall:proton transaction:push" noaudit
begin ''; goi 'BROADCAST testnet-a
' -- --tx="$T/tx-c3.json" --chain=testnet-a
mv_ok "MV-confirm: testnet, correct phrase → push" -
begin "$MT"; goi 'BROADCAST mainnet-a
' -- --tx="$T/tx-c4.json" --chain=mainnet-a --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
mv_ok "MV-confirm: mainnet, correct phrase → push" -
begin "$MT"; go XPR_TESTNET_RPC="$BASE_TEST" -- --tx="$T/tx-c3.json" --chain=mainnet-a --non-interactive --testnet-tx-id="$SBH_R16" --dry-run-log="$T/dry-c3.json"
mv_ok "MV-gate 1: XPR_TESTNET_RPC = the profile's history base → push" - "call:curl POST $BASE_TEST/v1/history/get_transaction"
begin '{"chain":"proton-test"}'; go -- "${TARGS[@]}"
mv_ok "MV-gate 2b: testnet, proton-test alias token → push" -
begin ''; go FYD_TESTNET_CHAIN_ID="$SBH_XPR_TEST_CID" -- "${TARGS[@]}"
mv_ok "MV-gate 3: override EQUAL to the profile (testnet) → push" -
begin "$MT"; go FYD_MAINNET_CHAIN_ID="$SBH_XPR_MAIN_CID" -- "${MARGS[@]}"
mv_ok "MV-gate 3: override EQUAL to the profile (mainnet) → push" -
begin ''; go FYD_TESTNET_CHAIN_ID= -- "${TARGS[@]}"
mv_ok "MV-gate 3: empty override = unset → push" -
begin ''; go -- "${TARGS[@]}"
mv_ok "MV-push: testnet processed → tx_id" -
begin ''; go -- --tx="$T/tx-c3.json" --chain=proton-test --non-interactive
mv_ok "MV-push: testnet proton-test alias" -
begin "{\"chain\":\"testnet-a\",\"tx_sha256\":\"$C3_SHA\"}"; go -- "${TARGS[@]}"
mv_ok "MV-push: testnet chain+sha bound" -
begin "$MT"; go -- "${MARGS[@]}"
mv_ok "MV-push: mainnet cycle-4 all gates" -
begin '{"chain":"proton"}'; go -- --tx="$T/tx-c4.json" --chain=proton --non-interactive --testnet-tx-id="$SBH_CYCLE4" --dry-run-log="$T/dry-c4.json"
mv_ok "MV-push: mainnet alias proton" -
begin "$MT"; go -- --tx="$T/tx-upd.json" --chain=mainnet-a --non-interactive --testnet-tx-id="$SBH_UPD_SAME" --dry-run-log="$T/dry-text.txt"
check "MV-push: mainnet updateauth + text dry-run (not an anchor shape: no check A, memo_prefix=none)" 0 \
	"out:$SBH_TXID" "calls:proton transaction:push=1" "calls:ahr_=0" "audit:memo_prefix=none" "audit:expiration=" "audit:outcome=submitted"
begin ''; go STUB_PUSH_MODE=idfield -- "${TARGS[@]}"
mv_ok "MV-push: answer carries only id (processed profile: no receipt status = submitted)" -
begin ''; go STUB_PUSH_MODE=idonly -- "${TARGS[@]}"
mv_ok "MV-push: answer carries only transaction_id (same)" -
begin ''; go STUB_PUSH_MODE=crash -- "${TARGS[@]}"
check "MV-push: chain rejects (crash, rc 1) → 10" 10 "err:BROADCAST OUTCOME UNKNOWN" "audit:outcome=unknown" "calls:proton transaction:push=1" "out:"
begin ''; go STUB_PUSH_MODE=noid -- "${TARGS[@]}"
check "MV-push: answer without any id → 10" 10 "err:BROADCAST OUTCOME UNKNOWN" "audit:outcome=unknown" "out:"
begin "$MT"; go STUB_PUSH_MODE=crash -- "${MARGS[@]}"
check "MV-push: mainnet chain rejects (crash) → 10" 10 "err:BROADCAST OUTCOME UNKNOWN" "audit:outcome=unknown" "calls:proton transaction:push=1" "out:"
begin ''; go "PATH=$SBH_PATH_NOUSER" "FYD_BROADCAST_AUDIT_LOG=$T" -- "${TARGS[@]}"
check "MV-audit: log write fails, anchor shape → 13 (the journal cannot be read), nothing sent" 13 \
	"nocall:proton transaction:push" "err:audit log"
begin ''; go "PATH=$SBH_PATH_NOUSER" "FYD_BROADCAST_AUDIT_LOG=$T" -- --tx="$T/tx-upd.json" --chain=testnet-a --non-interactive
check "MV-audit: log write fails, updateauth shape → 7 (kept), nothing sent" 7 "err:audit log write failed" "nocall:proton transaction:push"
fi

echo "---"
t_summary safe-broadcast-outcome
