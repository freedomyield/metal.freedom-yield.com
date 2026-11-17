#!/usr/bin/env bash
# tests/check-cycle-anchor-absent/test-check-cycle-anchor-absent.sh — contract
# suite for scripts/check-cycle-anchor-absent.sh (double-inscription guard,
# lane T4; spec §6 "New script", §7 K1, §9 T4, §11.10 J1 (a)).
#
# CHAIN: none. `curl` is a stub first on PATH that answers from per-host
#        fixture files and logs every call; nothing leaves this machine.
#        Account names, hosts and chain ids below are made-up fixtures.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (the code under test only reads).
# Case names start with their property id (K1-0, K1-10, K1-J1, K1-3, K1-4,
# K1-NUM, K1-2, K1-1, K1-SRC, K1-ACT, K1-RO) so a mutation report maps to cases.
# ok/bad always return 0, so `cond && ok || bad` is a safe if/else here.
# SC2030/SC2031: the locale cases set LC_ALL inside a subshell on purpose.
# shellcheck disable=SC2015,SC2030,SC2031
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh"

WORK="$(mktemp -d -t ccaa.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CCAA_T_WORK="$WORK"
mkdir -p "$WORK/bin" "$WORK/resp" "$WORK/cfg"
: > "$WORK/calls.log"

CID_M="$(printf 'aa%.0s' $(seq 1 32))"
CID_T="$(printf 'bb%.0s' $(seq 1 32))"
CID_S="$(printf 'ee%.0s' $(seq 1 32))"
H1="history.example"
H2="history2.example"
HT="history-test.example"
ACTOR="fxanchor"
E="2026-11-17T06:00:00"
LIB_OLD="2026-11-17T05:59:59"
LIB_NEW="2026-11-17T06:00:01"
HEAD_LATE="2026-11-17T06:30:00"
SCR="check-cycle-anchor-absent.sh"
TAG="[cycle-anchor-absent]"
printf '%s\n' "$ACTOR" > "$WORK/cfg/xpr-account"

# ---- trees: the script and the two libraries next to a FIXTURE config ---------
mk_tree() { # <dir> — script + libs + fixture config/a-chain-profiles.json
	mkdir -p "$1/scripts/lib" "$1/config"
	cp "$REPO_ROOT/scripts/$SCR" "$1/scripts/" 2>/dev/null || :
	cp "$REPO_ROOT/scripts/lib/a-chain-profile.sh" "$REPO_ROOT/scripts/lib/anchor-history-read.sh" "$1/scripts/lib/"
	jq --arg cm "$CID_M" --arg ct "$CID_T" --arg cs "$CID_S" --arg h1 "https://$H1" --arg h2 "https://$H2" --arg ht "https://$HT" '
		.profiles["xpr-mainnet"].chain_id = $cm
		| .profiles["xpr-mainnet"].history_bases = [$h1]
		| .profiles["xpr-testnet"].chain_id = $ct
		| .profiles["xpr-testnet"].history_bases = [$ht]
		| .profiles["pulsevm-mainnet"].chain_id = $cm
		| .profiles["pulsevm-mainnet"].history_bases = [$h1, $h2]
		| .profiles["pulsevm-mainnet"].explorer_base = "https://explorer.example/transaction"
		| .profiles["spare-testnet"] = (.profiles["pulsevm-testnet"] | .chain_id = $cs | .history_bases = []
			| .explorer_base = "https://explorer-spare.example/transaction")' \
		"$REPO_ROOT/config/a-chain-profiles.json" > "$1/config/a-chain-profiles.json"
}
TREE="$WORK/tree"
mk_tree "$TREE"
CHECK="$TREE/scripts/$SCR"

# ---- curl stub ---------------------------------------------------------------
# Answers from resp/<host>/<name>.json: get_actions pages = actions-<skip>,
# /v2/health = health, get_info = get_info. A missing file is an HTTP failure
# (exit 22). Every call's arguments are logged.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CCAA_T_WORK/calls.log"
url=""
for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
host="${url#https://}"; host="${host%%/*}"
case "$url" in
	*/v2/history/get_actions*)
		skip=0
		case "$url" in *"&skip="*) skip="${url##*&skip=}" ;; esac
		f="actions-$skip" ;;
	*/v2/health) f=health ;;
	*/v1/chain/get_info) f=get_info ;;
	*) exit 22 ;;
esac
[ -r "$CCAA_T_WORK/resp/$host/$f.json" ] || exit 22
cat "$CCAA_T_WORK/resp/$host/$f.json"
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

# ---- helpers -----------------------------------------------------------------
reset() { rm -rf "$WORK/resp"; mkdir -p "$WORK/resp/$H1" "$WORK/resp/$H2" "$WORK/resp/$HT"; : > "$WORK/calls.log"; }
calls() { wc -l < "$WORK/calls.log" | tr -d ' '; }
calls_matching() { grep -c "$1" "$WORK/calls.log" || :; }
info() { # <host> <chain_id> [lib_time] [head_time] — get_info body
	jq -nc --arg c "$2" --arg l "${3:-$LIB_OLD}" --arg h "${4:-$HEAD_LATE}" \
		'{chain_id: $c, head_block_time: $h, last_irreversible_block_time: $l}' > "$WORK/resp/$1/get_info.json"
}
fresh() { # <host> [head] [indexed] — /v2/health body
	jq -nc --argjson h "${2:-1000}" --argjson l "${3:-1000}" '{health: [
		{service: "NodeosRPC", status: "OK", service_data: {head_block_num: $h}},
		{service: "Elasticsearch", status: "OK", service_data: {last_indexed_block: $l}}]}' > "$WORK/resp/$1/health.json"
}
page() { # <host> <memo>... — one history page (page 0): <actor>'s transfers, newest first
	local host="$1"; shift
	printf '%s\n' "$@" | jq -R . | jq -sc --arg a "$ACTOR" '{actions: (to_entries | map(
		(9000 - .key) as $gs
		| {global_sequence: $gs, block_num: ($gs + 1000), timestamp: "2026-11-01T00:00:00.000",
		   trx_id: (("0" * (64 - ($gs | tostring | length))) + ($gs | tostring)),
		   act: {account: "eosio.token", name: "transfer",
		         data: {from: $a, to: "fxsink", quantity: "0.0001 XPR", memo: .value}}}))}' > "$WORK/resp/$host/actions-0.json"
}
# live <host> <chain_id> <memo>... — a base that is fresh, on the right chain and holds one page
live() { local host="$1" cid="$2"; shift 2; info "$host" "$cid"; fresh "$host"; page "$host" "$@"; }
want_trx() { printf '%064d' "$1"; } # global_sequence 9000 - index -> trx_id

run_chk() { OUT="$(env "FY_CONFIG_DIR=$WORK/cfg" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }
chk() { run_chk bash "$CHECK" "$@"; }
chk_env() { local e="$1"; shift; run_chk "$e" bash "$CHECK" "$@"; }
chk_ja() { OUT="$( export LC_ALL=ja_JP.UTF-8; FY_CONFIG_DIR="$WORK/cfg" bash "$CHECK" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }

# expect <case> <rc> <stdout> — stdout "" = empty (and the script's own stderr tag must be there,
# so a missing script or a crash before any code cannot pass); anything else = exact line.
expect() {
	local c="$1" rc="$2" out="$3"
	if [ "$RC" -ne "$rc" ]; then t_fail "$c" "rc=$RC want=$rc out=[$OUT] err=[$ERR]"; return 0; fi
	if [ -z "$out" ]; then
		if [ -n "$OUT" ]; then t_fail "$c" "stdout not empty: [$OUT]"; return 0; fi
		case "$ERR" in *"$TAG"*) t_pass "$c" ;; *) t_fail "$c" "no $TAG line on stderr: [$ERR]" ;; esac
	else
		[ "$OUT" = "$out" ] && t_pass "$c" || t_fail "$c" "out=[$OUT] want=[$out]"
	fi
}
usage_case() { # <case> — rc 1, empty stdout, own stderr tag, zero requests
	expect "$1" 1 ""
	[ "$(calls)" = 0 ] && t_pass "$1 (no request)" || t_fail "$1 (no request)" "calls=$(calls)"
}

ABS_M="ABSENT prefix=fya1c9 profile=xpr-mainnet floor=fya1c8 bases=1"

# ---- K1-0 absent -> 0 -----------------------------------------------------------
reset; live "$H1" "$CID_M" "plain" "fya1c8-id:x"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-0 one base, floor seen, prefix absent -> 0 and the ABSENT line" 0 "$ABS_M"

reset; live "$H1" "$CID_M" "plain" "fya1c8-id:x"; live "$H2" "$CID_M" "fya1c7-id:y"
chk_env FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-0 two bases, both clear -> 0, floor of the FIRST base, bases=2" 0 "ABSENT prefix=fya1c9 profile=pulsevm-mainnet floor=fya1c8 bases=2"
[ "$(calls_matching "$H2/v2/history/get_actions")" -ge 1 ] && t_pass "K1-0 the second base is read too (no early 0)" || t_fail "K1-0 the second base is read too" "calls=$(cat "$WORK/calls.log")"

reset; live "$H1" "$CID_M" "fya1c8-id:x"; live "$H2" "$CID_M" "fya1c9-id:y"
chk_env FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-0 the first base clear but the second holds the prefix -> 10, not 0" 10 \
	"PRESENT prefix=fya1c9 verdict=found trx_id=$(want_trx 9000) block_num=10000 timestamp=2026-11-01T00:00:00.000 base=https://$H2"

reset; live "$H1" "$CID_M" "fya1c8-id:x"; info "$H2" "$CID_M"; fresh "$H2"
chk_env FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-0 the first base clear, the second unreadable -> 3 (one clear base does not decide)" 3 ""

reset; live "$H1" "$CID_M" "fya1c8-id:x"; rm -f "$WORK/resp/$H1/get_info.json"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-0 a Hyperion-only base (get_info not served), no --not-before -> still 0" 0 "$ABS_M"

reset; live "$HT" "$CID_T" "fya1c8-id:x"
chk --chain=testnet-a --memo-prefix=fya1c9
expect "K1-0 testnet role, floor seen -> 0 (no flag, same rule)" 0 "ABSENT prefix=fya1c9 profile=xpr-testnet floor=fya1c8 bases=1"

# ---- K1-10 present -> 10 ----------------------------------------------------------
reset; live "$H1" "$CID_M" "plain" "fya1c9-id:x" "fya1c8-id:z"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-10 found -> 10 and the PRESENT line (trx_id, block_num, timestamp, base)" 10 \
	"PRESENT prefix=fya1c9 verdict=found trx_id=$(want_trx 8999) block_num=9999 timestamp=2026-11-01T00:00:00.000 base=https://$H1"

reset; live "$H1" "$CID_M" "fya1c10-id:x" "fya1c9-id:z"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-10 found_later (a later cycle already inscribed) -> 10 with verdict=found_later" 10 \
	"PRESENT prefix=fya1c9 verdict=found_later trx_id=$(want_trx 9000) block_num=10000 timestamp=2026-11-01T00:00:00.000 base=https://$H1"

reset; live "$H1" "$CID_M" "fya1c9-id:a"; live "$H2" "$CID_M" "fya1c9-id:b" "plain"
chk_env FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-10 both bases hold it -> the first base in profile order is printed" 10 \
	"PRESENT prefix=fya1c9 verdict=found trx_id=$(want_trx 9000) block_num=10000 timestamp=2026-11-01T00:00:00.000 base=https://$H1"

reset; live "$H1" "$CID_M" "plain"; live "$H2" "$CID_M" "fya1c9-id:b"
chk_env FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-10 an unreadable-floor first base (no floor) does not hide the second base's find -> 10" 10 \
	"PRESENT prefix=fya1c9 verdict=found trx_id=$(want_trx 9000) block_num=10000 timestamp=2026-11-01T00:00:00.000 base=https://$H2"

# ---- K1-J1 an exhausted scan without a floor is never 0 ------------------------------
reset; live "$H1" "$CID_M" "plain" "plain"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-J1 mainnet role: history ran out with no floor -> 3" 3 ""
reset; live "$HT" "$CID_T" "plain"
chk --chain=testnet-a --memo-prefix=fya1c9
expect "K1-J1 testnet role: history ran out with no floor -> 3 (J1 (a): no chain is special)" 3 ""
reset; live "$H1" "$CID_M" "fya2c3-id:x"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-J1 only another schema's memos (no same-schema floor) -> 3" 3 ""

# ---- K1-3 unreadable -> 3 -------------------------------------------------------------
reset; info "$H1" "$CID_M"; fresh "$H1"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 the history request fails -> 3, stdout empty" 3 ""
reset; live "$H1" "$CID_M" "fya1c8-id:x"; fresh "$H1" 1000 900
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 the index is stale (health lag 100 > 30) although the page shows a floor -> 3" 3 ""
reset; live "$H1" "$CID_M" "fya1c8-id:x"; rm -f "$WORK/resp/$H1/health.json"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 health cannot be read -> 3" 3 ""
reset; live "$H1" "$CID_M" "fya1c8-id:x"; info "$H1" "$CID_T"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 get_info names another chain_id although the page shows a floor -> 3" 3 ""
reset; live "$H1" "$CID_M" "fya1c8-id:x"; live "$H2" "$CID_T" "fya1c8-id:x"
chk_env FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 the first base is clear, the second serves another chain -> 3" 3 ""
reset; live "$H1" "$CID_M" "fya1c8-id:x"; printf '%s' '{"actions":[]}xyz' > "$WORK/resp/$H1/actions-0.json"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 the page is one value followed by garbage -> 3" 3 ""
reset; live "$H1" "$CID_M" "fya1c8-id:x"
jq -nc --arg l "$LIB_NEW" --arg h "$HEAD_LATE" '{head_block_time: $h, last_irreversible_block_time: $l}' > "$WORK/resp/$H1/get_info.json"
chk --chain=mainnet-a --memo-prefix=fya1c9 "--not-before=$E"
expect "K1-3 --not-before: get_info gives both times (LIB past E) but no chain_id, a floor is shown -> 3" 3 ""

# ---- K1-3 (answer shape) the reader's answer must be exactly ONE JSON object --------------
# A copy of the tree whose lib copy answers from files (no curl at all): the answer of
# ahr_find_cycle_anchor and of ahr_chain_times is whatever the case writes into mock/.
# Only the copy is changed; the real library file is untouched.
MTREE="$WORK/tree-mock"
mk_tree "$MTREE"
MCHECK="$MTREE/scripts/$SCR"
mkdir -p "$WORK/mock"
cat >> "$MTREE/scripts/lib/anchor-history-read.sh" <<'MOCK'
# ---- answer mock (suite only): every answer comes from a file ----
ahr_observed_chain_id() { cat "$CCAA_T_WORK/mock/cid"; }
ahr_index_fresh() { return 0; }
ahr_find_cycle_anchor() { cat "$CCAA_T_WORK/mock/find"; }
ahr_chain_times() { cat "$CCAA_T_WORK/mock/times"; }
MOCK
mock() { # <chain_id> <find answer> [<chain-times answer>] — the exact bytes the mocked library answers
	printf '%s' "$1" > "$WORK/mock/cid"; printf '%s' "$2" > "$WORK/mock/find"; printf '%s' "${3:-}" > "$WORK/mock/times"
	: > "$WORK/calls.log"
}
mchk() { run_chk bash "$MCHECK" "$@"; }
MCLEAR='{"verdict":"clear","trx_id":null,"block_num":null,"timestamp":null,"scanned":4,"floor":"fya1c8"}'
MFOUNDL='{"verdict":"found_later","trx_id":"'"$(printf 'c%.0s' $(seq 1 64))"'","block_num":7,"timestamp":"2026-11-01T00:00:00.000","scanned":1,"floor":null}'
MTIMES='{"head_block_time":"'"$HEAD_LATE"'","last_irreversible_block_time":"'"$LIB_NEW"'"}'

mock "$CID_M" "$MCLEAR"
mchk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 the mocked reader answers one clear+floor object -> 0 and the ABSENT line (control: the mock passes a good answer)" 0 "$ABS_M"
[ "$(calls)" = 0 ] && t_pass "K1-3 the mocked tree sends no request" || t_fail "K1-3 the mocked tree sends no request" "calls=$(cat "$WORK/calls.log")"

mock "$CID_M" "$MCLEAR $MFOUNDL"
mchk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 the reader answers two JSON values on one line (clear+floor then found_later) -> 3, not 0" 3 ""
mock "$CID_M" "$MFOUNDL $MCLEAR"
mchk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 the reader answers two JSON values on one line (found_later then clear+floor) -> 3" 3 ""
mock "$CID_T" "$MCLEAR $MCLEAR"
mchk --chain=testnet-a --memo-prefix=fya1c9
expect "K1-3 the reader answers two clear+floor values on one line (testnet role) -> 3" 3 ""
mock "$CID_M" "$MCLEAR x"
mchk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-3 the reader answers one object followed by trailing text -> 3" 3 ""
mock "$CID_M" "$MCLEAR" "$MTIMES"
mchk --chain=mainnet-a --memo-prefix=fya1c9 "--not-before=$E"
expect "K1-3 --not-before control: one chain-times object past E -> 0 with not_before and lib_time" 0 "$ABS_M not_before=$E lib_time=$LIB_NEW"
mock "$CID_M" "$MCLEAR" "$MTIMES {\"x\":1}"
mchk --chain=mainnet-a --memo-prefix=fya1c9 "--not-before=$E"
expect "K1-3 --not-before: the chain-times answer holds two JSON values (the second without a time) -> 3" 3 ""

# ---- K1-4 --not-before ----------------------------------------------------------------
NB="--not-before=$E"
reset; live "$H1" "$CID_M" "fya1c8-id:x"; info "$H1" "$CID_M" "$LIB_OLD" "$HEAD_LATE"
chk --chain=mainnet-a --memo-prefix=fya1c9 "$NB"
expect "K1-4 LIB before E (head after E) -> 4, stdout empty" 4 ""
[ "$(calls_matching "get_actions")" = 0 ] && [ "$(calls_matching "/v2/health")" = 0 ] && t_pass "K1-4 rc 4 reads no history and no health" || t_fail "K1-4 rc 4 reads no history" "calls=$(cat "$WORK/calls.log")"

reset; live "$H1" "$CID_M" "fya1c8-id:x"; info "$H1" "$CID_M" "$E" "$HEAD_LATE"
chk --chain=mainnet-a --memo-prefix=fya1c9 "$NB"
expect "K1-4 LIB equal to E -> 4 (not past)" 4 ""

reset; live "$H1" "$CID_M" "fya1c8-id:x"; info "$H1" "$CID_M" "$LIB_NEW" "$HEAD_LATE"
chk --chain=mainnet-a --memo-prefix=fya1c9 "$NB"
expect "K1-4 LIB one second after E, prefix absent -> 0 with not_before and lib_time" 0 \
	"$ABS_M not_before=$E lib_time=$LIB_NEW"

reset; live "$H1" "$CID_M" "fya1c9-id:x"; info "$H1" "$CID_M" "$LIB_NEW" "$HEAD_LATE"
chk --chain=mainnet-a --memo-prefix=fya1c9 "$NB"
expect "K1-4 LIB past E and the prefix is there -> 10" 10 \
	"PRESENT prefix=fya1c9 verdict=found trx_id=$(want_trx 9000) block_num=10000 timestamp=2026-11-01T00:00:00.000 base=https://$H1"

reset; live "$H1" "$CID_M" "fya1c8-id:x"; printf '%s' '{"chain_id":"'"$CID_M"'","head_block_time":"'"$HEAD_LATE"'"}' > "$WORK/resp/$H1/get_info.json"
chk --chain=mainnet-a --memo-prefix=fya1c9 "$NB"
expect "K1-4 the LIB time is missing from get_info -> 3" 3 ""

reset; live "$H1" "$CID_M" "fya1c8-id:x"; rm -f "$WORK/resp/$H1/get_info.json"
chk --chain=mainnet-a --memo-prefix=fya1c9 "$NB"
expect "K1-4 get_info not served and --not-before given -> 3" 3 ""

reset; live "$H1" "$CID_M" "fya1c8-id:x" ; live "$H2" "$CID_M" "fya1c8-id:x"; info "$H1" "$CID_M" "$LIB_NEW"; info "$H2" "$CID_M" "$LIB_OLD"
chk_env FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet --chain=mainnet-a --memo-prefix=fya1c9 "$NB"
expect "K1-4 one base past E, the other not -> 4 (all bases must be past)" 4 ""

reset; live "$H1" "$CID_M" "fya1c8-id:x" ; live "$H2" "$CID_M" "fya1c8-id:x"; info "$H1" "$CID_M" "$LIB_OLD"; rm -f "$WORK/resp/$H2/get_info.json"
chk_env FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet --chain=mainnet-a --memo-prefix=fya1c9 "$NB"
expect "K1-4 one base waits, the other cannot say its LIB -> 3 (unreadable outranks wait)" 3 ""

reset; live "$H1" "$CID_M" "fya1c8-id:x" ; live "$H2" "$CID_M" "fya1c9-id:y"; info "$H1" "$CID_M" "$LIB_OLD"; info "$H2" "$CID_M" "$LIB_NEW"
chk_env FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet --chain=mainnet-a --memo-prefix=fya1c9 "$NB"
expect "K1-4 one base waits, the other already shows the prefix -> 10 (present outranks wait)" 10 \
	"PRESENT prefix=fya1c9 verdict=found trx_id=$(want_trx 9000) block_num=10000 timestamp=2026-11-01T00:00:00.000 base=https://$H2"

# ---- K1-NUM the cycle is a number ------------------------------------------------------
reset; live "$H1" "$CID_M" "fya1c10-id:x" "fya1c8-id:y"
chk --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-NUM checking c9 while c10 is on chain -> 10 found_later (9 < 10 as numbers)" 10 \
	"PRESENT prefix=fya1c9 verdict=found_later trx_id=$(want_trx 9000) block_num=10000 timestamp=2026-11-01T00:00:00.000 base=https://$H1"
reset; live "$H1" "$CID_M" "fya1c9-id:x"
chk --chain=mainnet-a --memo-prefix=fya1c10
expect "K1-NUM checking c10 while the newest is c9 -> 0 (floor c9; 10 > 9 as numbers)" 0 \
	"ABSENT prefix=fya1c10 profile=xpr-mainnet floor=fya1c9 bases=1"

# ---- K1-2 profile unusable / library unreadable -> 2 -------------------------------------
reset
chk_env FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet --chain=testnet-a --memo-prefix=fya1c9
expect "K1-2 profile without a chain_id -> 2" 2 ""
chk_env FYD_A_CHAIN_PROFILE_TESTNET=spare-testnet --chain=testnet-a --memo-prefix=fya1c9
expect "K1-2 profile with a chain_id but no history_bases -> 2" 2 ""
[ "$(calls)" = 0 ] && t_pass "K1-2 no request for an unusable profile" || t_fail "K1-2 no request" "calls=$(calls)"

T_L1="$WORK/tree-no-profile-lib"; mk_tree "$T_L1"; rm -f "$T_L1/scripts/lib/a-chain-profile.sh"
run_chk bash "$T_L1/scripts/$SCR" --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-2 a-chain-profile.sh is not readable -> 2" 2 ""
T_L2="$WORK/tree-no-history-lib"; mk_tree "$T_L2"; rm -f "$T_L2/scripts/lib/anchor-history-read.sh"
run_chk bash "$T_L2/scripts/$SCR" --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-2 anchor-history-read.sh is not readable -> 2" 2 ""
T_L3="$WORK/tree-bad-profile-lib"; mk_tree "$T_L3"; printf 'return 1\n' > "$T_L3/scripts/lib/a-chain-profile.sh"
run_chk bash "$T_L3/scripts/$SCR" --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-2 a-chain-profile.sh is readable but fails to load -> 2" 2 ""
T_L4="$WORK/tree-bad-history-lib"; mk_tree "$T_L4"; printf 'return 1\n' > "$T_L4/scripts/lib/anchor-history-read.sh"
run_chk bash "$T_L4/scripts/$SCR" --chain=mainnet-a --memo-prefix=fya1c9
expect "K1-2 anchor-history-read.sh is readable but fails to load -> 2" 2 ""

# ---- K1-1 usage errors -> 1, no request ---------------------------------------------------
reset
chk --chain=mainnet-a --memo-prefix=fya1c9 --bogus;            usage_case "K1-1 an unknown argument"
chk --memo-prefix=fya1c9;                                      usage_case "K1-1 --chain is missing"
chk --chain=bogus-chain --memo-prefix=fya1c9;                  usage_case "K1-1 --chain names no role"
SRC_OK="$WORK/src-ok.json"
printf '%s' '{"schema_version":1,"observations_branch":{"cycle_number_observed":7}}' > "$SRC_OK"
chk --chain=mainnet-a --memo-prefix=fya1c9 --anchor-source="$SRC_OK"; usage_case "K1-1 --memo-prefix and --anchor-source together"
chk --chain=mainnet-a;                                         usage_case "K1-1 neither --memo-prefix nor --anchor-source"
for p in fya1c fyac1 fya1c1x FYA1C1 fya1c1c2 fya1c9-id:x ""; do
	chk --chain=mainnet-a "--memo-prefix=$p"; usage_case "K1-1 bad --memo-prefix [$p]"
done

# probe: does a range expression match a full-width digit under this bash + locale?
# shellcheck disable=SC2194  # the word is a constant on purpose: it is a full-width digit probe
ja_range_probe() { export LC_ALL=ja_JP.UTF-8; case "１" in *[!0-9]*) echo no ;; *) echo yes ;; esac; }
JA_RANGE="$(ja_range_probe)"
if [ "$JA_RANGE" = yes ]; then
	chk_ja --chain=mainnet-a "--memo-prefix=fya１c1"; usage_case "K1-1 full-width digit in --memo-prefix (ja_JP.UTF-8)"
	chk_ja --chain=mainnet-a --memo-prefix=fya1c9 "--actor=ｆxanchor"; usage_case "K1-1 full-width letter in --actor (ja_JP.UTF-8)"
elif [ "$(uname)" = Darwin ]; then
	t_fail "K1-1 probe: a [0-9] range no longer matches a full-width digit on this Darwin bash, the full-width cases are blind"
else
	printf 'SKIP  K1-1 full-width cases (a range does not match full-width digits here)\n'
fi

src() { printf '%s' "$2" > "$WORK/src-$1.json"; }
src two '{"schema_version":1,"observations_branch":{"cycle_number_observed":7}}{"schema_version":1,"observations_branch":{"cycle_number_observed":8}}'
src trail '{"schema_version":1,"observations_branch":{"cycle_number_observed":7}} x'
src sstr '{"schema_version":"1","observations_branch":{"cycle_number_observed":7}}'
src cfrac '{"schema_version":1,"observations_branch":{"cycle_number_observed":7.5}}'
src cnull '{"schema_version":1,"observations_branch":{"cycle_number_observed":null}}'
src cmiss '{"schema_version":1,"observations_branch":{}}'
src smiss '{"observations_branch":{"cycle_number_observed":7}}'
src czero '{"schema_version":1,"observations_branch":{"cycle_number_observed":0}}'
src szero '{"schema_version":0,"observations_branch":{"cycle_number_observed":7}}'
src empty ''
for s in two trail sstr cfrac cnull cmiss smiss czero szero empty; do
	chk --chain=mainnet-a "--anchor-source=$WORK/src-$s.json"; usage_case "K1-1 bad --anchor-source [$s]"
done
chk --chain=mainnet-a "--anchor-source=$WORK/src-does-not-exist.json"; usage_case "K1-1 --anchor-source is unreadable"

chk --chain=mainnet-a --memo-prefix=fya1c9 --actor=;                  usage_case "K1-1 empty --actor"
chk --chain=mainnet-a --memo-prefix=fya1c9 --actor=abcdefghijklm;     usage_case "K1-1 13-character --actor"
chk --chain=mainnet-a --memo-prefix=fya1c9 --actor=FXANCHOR;          usage_case "K1-1 upper-case --actor"
chk --chain=mainnet-a --memo-prefix=fya1c9 --actor=fx_anchor;         usage_case "K1-1 --actor with an underscore"
chk --chain=mainnet-a --memo-prefix=fya1c9 --actor=fxanchor6;         usage_case "K1-1 --actor with the digit 6"
mkdir -p "$WORK/cfg-none" "$WORK/cfg-empty"; : > "$WORK/cfg-empty/xpr-account"
run_chk FY_CONFIG_DIR="$WORK/cfg-none" bash "$CHECK" --chain=mainnet-a --memo-prefix=fya1c9; usage_case "K1-1 no --actor and no actor file"
run_chk FY_CONFIG_DIR="$WORK/cfg-empty" bash "$CHECK" --chain=mainnet-a --memo-prefix=fya1c9; usage_case "K1-1 no --actor and an empty actor file"
chk --chain=mainnet-a --memo-prefix=fya1c9 --not-before=2026-13-45T00:00:00; usage_case "K1-1 --not-before is not a time (month 13)"
chk --chain=mainnet-a --memo-prefix=fya1c9 --not-before=yesterday;            usage_case "K1-1 --not-before is not a time (word)"

# jq / curl missing from PATH -> 1 (a PATH that holds only the tools the script needs before that check)
BASH_BIN="$(command -v bash)"
mkdir -p "$WORK/bin-nojq" "$WORK/bin-nocurl"
for t in dirname head tr cat sed; do ln -sf "$(command -v "$t")" "$WORK/bin-nojq/$t"; ln -sf "$(command -v "$t")" "$WORK/bin-nocurl/$t"; done
ln -sf "$(command -v jq)" "$WORK/bin-nocurl/jq"
OUT="$( FY_CONFIG_DIR="$WORK/cfg" PATH="$WORK/bin-nojq" "$BASH_BIN" "$CHECK" --chain=mainnet-a --memo-prefix=fya1c9 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
usage_case "K1-1 jq is not on PATH"
OUT="$( FY_CONFIG_DIR="$WORK/cfg" PATH="$WORK/bin-nocurl" "$BASH_BIN" "$CHECK" --chain=mainnet-a --memo-prefix=fya1c9 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
usage_case "K1-1 the HTTP tool is not on PATH"

chk -h; case "$OUT" in *"--not-before"*"Exit codes"*) [ "$RC" -eq 0 ] && [ "$(calls)" = 0 ] && t_pass "K1-1 -h prints the usage and exit codes, rc 0, no request" || t_fail "K1-1 -h" "rc=$RC calls=$(calls)";; *) t_fail "K1-1 -h prints the usage" "rc=$RC out=[$OUT]";; esac

# ---- K1-SRC prefix from --anchor-source ----------------------------------------------------
reset; live "$H1" "$CID_M" "fya1c6-id:x"
chk --chain=mainnet-a "--anchor-source=$SRC_OK"
expect "K1-SRC schema 1 cycle 7 -> prefix fya1c7 (floor fya1c6)" 0 "ABSENT prefix=fya1c7 profile=xpr-mainnet floor=fya1c6 bases=1"
reset; live "$H1" "$CID_M" "fya2c6-id:x" "fya1c9-id:y"
src s2 '{"schema_version":2,"observations_branch":{"cycle_number_observed":7}}'
chk --chain=mainnet-a "--anchor-source=$WORK/src-s2.json"
expect "K1-SRC schema 2 cycle 7 -> prefix fya2c7 (the schema is read, not fixed)" 0 "ABSENT prefix=fya2c7 profile=xpr-mainnet floor=fya2c6 bases=1"

# ---- K1-ACT the actor ----------------------------------------------------------------------
reset; live "$H1" "$CID_M" "fya1c8-id:x"
chk --chain=mainnet-a --memo-prefix=fya1c9 --actor=fxother
[ "$(calls_matching "account=fxother&")" -ge 1 ] && [ "$(calls_matching "account=$ACTOR&")" = 0 ] && t_pass "K1-ACT --actor wins over the actor file" || t_fail "K1-ACT --actor wins" "calls=$(cat "$WORK/calls.log")"
reset; live "$H1" "$CID_M" "fya1c8-id:x"
chk --chain=mainnet-a --memo-prefix=fya1c9
[ "$(calls_matching "account=$ACTOR&")" -ge 1 ] && t_pass "K1-ACT the default actor is line 1 of FY_CONFIG_DIR/xpr-account" || t_fail "K1-ACT default actor" "calls=$(cat "$WORK/calls.log")"
reset; live "$H1" "$CID_M" "fya1c8-id:x"
mkdir -p "$WORK/cfg-two"; printf '%s\n%s\n' "$ACTOR" "fxother" > "$WORK/cfg-two/xpr-account"
run_chk FY_CONFIG_DIR="$WORK/cfg-two" bash "$CHECK" --chain=mainnet-a --memo-prefix=fya1c9
[ "$RC" -eq 0 ] && [ "$(calls_matching "account=$ACTOR&")" -ge 1 ] && [ "$(calls_matching "account=fxother&")" = 0 ] && t_pass "K1-ACT a two-line actor file: only line 1 is used" || t_fail "K1-ACT two-line actor file" "rc=$RC calls=$(cat "$WORK/calls.log")"

# ---- K1-RO read only, two libraries, no hidden range / default forms -----------------------
BODY="$WORK/body.txt"
grep -vE '^[[:space:]]*#' "$REPO_ROOT/scripts/$SCR" > "$BODY" 2>/dev/null || : > "$BODY"
[ -s "$BODY" ] && t_pass "K1-RO the script exists and has code lines" || t_fail "K1-RO the script exists and has code lines"
# The one tool-presence line names the HTTP tool; it is exempt as an exact line, nothing else is.
if grep -vxF 'CCAA_REQUIRED_TOOLS="jq curl"' "$BODY" | grep -Eiq 'curl|proton|safe-broadcast|push_transaction|transaction:push|cleos'; then
	t_fail "K1-RO a forbidden word in a code line" "$(grep -vxF 'CCAA_REQUIRED_TOOLS="jq curl"' "$BODY" | grep -Ein 'curl|proton|safe-broadcast|push_transaction|transaction:push|cleos' | head -3)"
else
	[ -s "$BODY" ] && t_pass "K1-RO no curl/proton/safe-broadcast/push_transaction/transaction:push/cleos in a code line (one exact tool-presence line exempt)" || t_fail "K1-RO forbidden words (empty body)"
fi
SRCLINES="$(grep -Ec '^[[:space:]]*(\.|source)[[:space:]]' "$BODY" || :)"
LIBLINES="$(grep -E '^[[:space:]]*(\.|source)[[:space:]]' "$BODY" | grep -Ec 'scripts/lib/(a-chain-profile|anchor-history-read)\.sh"' || :)"
[ "$SRCLINES" = 2 ] && [ "$LIBLINES" = 2 ] && t_pass "K1-RO it sources exactly the two libraries" || t_fail "K1-RO it sources exactly the two libraries" "source lines=$SRCLINES lib lines=$LIBLINES"
if grep -Eq 'ahr__' "$BODY"; then t_fail "K1-RO calls an internal ahr__ function"; else [ -s "$BODY" ] && t_pass "K1-RO no call to an internal ahr__ function" || t_fail "K1-RO ahr__ (empty body)"; fi
ALNUM="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
RANGE_RE="\\[!?[$ALNUM]-[$ALNUM]\\]|\\\\d|\\[\\[:|//"
if grep -Eq "$RANGE_RE" "$BODY"; then
	t_fail "K1-RO a range expression, \\d, [[: or a // in a code line" "$(grep -En "$RANGE_RE" "$BODY" | head -3)"
else
	[ -s "$BODY" ] && t_pass "K1-RO no letter/digit range, no \\d, no [[:, no jq // in a code line" || t_fail "K1-RO ranges (empty body)"
fi
[ -x "$REPO_ROOT/scripts/$SCR" ] && t_pass "K1-RO the script is executable" || t_fail "K1-RO the script is executable"

t_summary check-cycle-anchor-absent || :
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
