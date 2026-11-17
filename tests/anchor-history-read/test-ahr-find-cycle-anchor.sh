#!/usr/bin/env bash
# tests/anchor-history-read/test-ahr-find-cycle-anchor.sh — contract suite for
# the check-A readers of scripts/lib/anchor-history-read.sh: ahr_find_cycle_anchor,
# ahr_index_fresh, ahr_chain_times, ahr_utc_to_epoch, ahr_epoch_to_utc
# (double-inscription guard, lane T1; spec §9 / §11.6).
#
# CHAIN: none. `curl` is a stub first on PATH that answers from per-case
#        fixture files and logs every call; nothing leaves this machine.
#        Account names and the base below are made-up fixtures.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (the code under test only reads).
# Case names start with their property id (A3, A3h, A4, A5, A6, FOUND, IN,
# ENT, ORD, END, T, REQ, R1) so a mutation report maps to cases.
# ok/bad always return 0, so `cond && ok || bad` is a safe if/else here.
# SC2030/SC2031: the locale and TZ cases set LC_ALL / TZ inside a subshell on purpose.
# shellcheck disable=SC2015,SC2030,SC2031
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$REPO_ROOT/tests/lib/assert.sh"

WORK="$(mktemp -d -t ahr-find.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export AHR_T_WORK="$WORK"
mkdir -p "$WORK/bin" "$WORK/resp"
: > "$WORK/calls.log"

BASE="https://history.example"
ACTOR="fxanchor"
STRANGER="fxstranger"
SINK="fxsink"
TS="2026-11-01T00:00:00.000"

# ---- curl stub ---------------------------------------------------------------
# get_actions answers from resp/actions-<skip>.json (skip=0 when absent from the
# URL); /v2/health from resp/health.json; get_info from resp/get_info.json. A
# missing file is an HTTP failure (exit 22). Every call's arguments are logged.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AHR_T_WORK/calls.log"
url=""
for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
case "$url" in
	*/v2/history/get_actions*)
		skip=0
		case "$url" in *"&skip="*) skip="${url##*&skip=}" ;; esac
		f="actions-$skip" ;;
	*/v2/health) f=health ;;
	*/v1/chain/get_info) f=get_info ;;
	*) exit 22 ;;
esac
[ -r "$AHR_T_WORK/resp/$f.json" ] || exit 22
cat "$AHR_T_WORK/resp/$f.json"
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

AHR_MAX_TIME=15
export AHR_MAX_TIME
# shellcheck source=../../scripts/lib/anchor-history-read.sh
. "$REPO_ROOT/scripts/lib/anchor-history-read.sh"

# ---- helpers -----------------------------------------------------------------
reset() { rm -f "$WORK"/resp/*.json; : > "$WORK/calls.log"; }
calls() { wc -l < "$WORK/calls.log" | tr -d ' '; }
defined() { [ "$(type -t "$1")" = function ]; }
run_find() { OUT="$(ahr_find_cycle_anchor "$@" 2>"$WORK/err")"; RC=$?; }
run_find_ja() { OUT="$( export LC_ALL=ja_JP.UTF-8; ahr_find_cycle_anchor "$@" 2>"$WORK/err")"; RC=$?; }
run_fresh() { OUT="$(ahr_index_fresh "$@" 2>"$WORK/err")"; RC=$?; }
run_times() { OUT="$(ahr_chain_times "$@" 2>"$WORK/err")"; RC=$?; }

# expect_rc3 <case> <function> <want-calls>: unreadable = rc 3, empty stdout,
# exactly <want-calls> requests. The function must exist (a stub lib that
# defines nothing would otherwise make every "no request" case pass).
expect_rc3() {
	if defined "$2" && [ "$RC" -eq 3 ] && [ -z "$OUT" ] && [ "$(calls)" = "$3" ]; then
		t_pass "$1"
	else
		t_fail "$1" "defined=$(type -t "$2") rc=$RC out=[$OUT] calls=$(calls) want-calls=$3"
	fi
}
# expect_verdict <case> <want-calls> <want-json-string>: rc 0 and stdout equal
# to the expected one-line JSON (byte for byte, so key order is pinned too).
expect_verdict() {
	if defined ahr_find_cycle_anchor && [ "$RC" -eq 0 ] && [ "$OUT" = "$3" ] && [ "$(calls)" = "$2" ]; then
		t_pass "$1"
	else
		t_fail "$1" "rc=$RC out=[$OUT] want=[$3] calls=$(calls) want-calls=$2"
	fi
}
want() { # <verdict> <trx_id json> <block_num json> <timestamp json> <scanned> <floor json>
	jq -nc --arg v "$1" --argjson t "$2" --argjson b "$3" --argjson ts "$4" --argjson s "$5" --argjson f "$6" \
		'{verdict: $v, trx_id: $t, block_num: $b, timestamp: $ts, scanned: $s, floor: $f}'
}
want_at() { # <verdict> <page> <index> <scanned> <floor json> — entry values of that position
	local gs=$((10000 - $2 * 100 - $3))
	want "$1" "\"t$gs\"" "$((gs + 1000))" "\"$TS\"" "$4" "$5"
}

# filler <top_gs> <count>: strictly descending plain transfers from a stranger.
filler() {
	jq -nc --argjson top "$1" --argjson n "$2" --arg ts "$TS" '{actions: [range(0; $n) | {global_sequence: ($top - .), trx_id: "tf\($top - .)", block_num: 5000, timestamp: $ts, act: {account: "eosio.token", name: "transfer", data: {from: "fxstranger", to: "fxanchor", quantity: "0.0001 XPR", memo: "plain"}}}]}'
}
fpage() { filler "$((10000 - $1 * 100))" "$2" > "$WORK/resp/actions-$(($1 * 100)).json"; } # <page k> <count>
edit() { # <page k> <jq filter>
	local f="$WORK/resp/actions-$(($1 * 100)).json"
	jq -c "$2" "$f" > "$f.n" && mv "$f.n" "$f"
}
put() { # <page k> <index> <from> <to> <memo> — an anchor-shaped entry (trx t<gs>, block gs+1000)
	local f="$WORK/resp/actions-$(($1 * 100)).json"
	jq -c --argjson i "$2" --arg f "$3" --arg t "$4" --arg m "$5" \
		'.actions[$i] |= (.act.data.from = $f | .act.data.to = $t | .act.data.memo = $m | .trx_id = "t\(.global_sequence)" | .block_num = (.global_sequence + 1000))' \
		"$f" > "$f.n" && mv "$f.n" "$f"
}
health() { # <head_block_num|null> <last_indexed_block|null> [status] — one health body
	jq -nc --argjson h "$1" --argjson l "$2" --arg st "${3:-OK}" '{health: [
		{service: "NodeosRPC", status: $st, service_data: ({} + (if $h == null then {} else {head_block_num: $h} end))},
		{service: "Elasticsearch", status: "OK", service_data: ({} + (if $l == null then {} else {last_indexed_block: $l} end))}]}' > "$WORK/resp/health.json"
}

# ---- R1 the four constants are plain assignments the environment cannot move --
vals="$( AHR_SCAN_PAGE_LIMIT=5 AHR_SCAN_MAX_PAGES=3 AHR_INDEX_MAX_LAG_BLOCKS=1 AHR_TRANSFER_FILTER=x
	export AHR_SCAN_PAGE_LIMIT AHR_SCAN_MAX_PAGES AHR_INDEX_MAX_LAG_BLOCKS AHR_TRANSFER_FILTER
	. "$REPO_ROOT/scripts/lib/anchor-history-read.sh"
	printf '%s %s %s %s' "${AHR_SCAN_PAGE_LIMIT-}" "${AHR_SCAN_MAX_PAGES-}" "${AHR_INDEX_MAX_LAG_BLOCKS-}" "${AHR_TRANSFER_FILTER-}" )"
t_assert_eq "R1 the scan constants ignore the environment (100 10 30 eosio.token:transfer)" "100 10 30 eosio.token:transfer" "$vals"

# ---- REQ request form ---------------------------------------------------------
reset; fpage 0 100; fpage 1 3
run_find "$BASE" "$ACTOR" fya1c1
t_assert_eq "REQ page 0 has no skip, page 1 has skip=100, both the library's curl form" \
	"-sSf --max-time 15 $BASE/v2/history/get_actions?account=fxanchor&filter=eosio.token:transfer&sort=desc&limit=100|-sSf --max-time 15 $BASE/v2/history/get_actions?account=fxanchor&filter=eosio.token:transfer&sort=desc&limit=100&skip=100" \
	"$(paste -s -d '|' "$WORK/calls.log")"

# ---- A3 unreadable history: rc 3, empty stdout, nothing more requested --------
reset
run_find "$BASE" "$ACTOR" fya1c1
expect_rc3 "A3 curl failure on page 1" ahr_find_cycle_anchor 1

reset; fpage 0 100
run_find "$BASE" "$ACTOR" fya1c1
expect_rc3 "A3 curl failure on page 2 (page 1 full, no decision)" ahr_find_cycle_anchor 2

reset; printf '%s' '<html>502</html>' > "$WORK/resp/actions-0.json"
run_find "$BASE" "$ACTOR" fya1c1
expect_rc3 "A3 body is not JSON" ahr_find_cycle_anchor 1

reset; printf '%s' '[]' > "$WORK/resp/actions-0.json"
run_find "$BASE" "$ACTOR" fya1c1
expect_rc3 "A3 body is an array, not an object" ahr_find_cycle_anchor 1

reset; printf '%s' '"ok"' > "$WORK/resp/actions-0.json"
run_find "$BASE" "$ACTOR" fya1c1
expect_rc3 "A3 body is a string, not an object" ahr_find_cycle_anchor 1

reset; printf '%s' '{"total":1}' > "$WORK/resp/actions-0.json"
run_find "$BASE" "$ACTOR" fya1c1
expect_rc3 "A3 object without an actions array" ahr_find_cycle_anchor 1

reset; printf '%s' '{"actions":{"a":1}}' > "$WORK/resp/actions-0.json"
run_find "$BASE" "$ACTOR" fya1c1
expect_rc3 "A3 actions is an object, not an array" ahr_find_cycle_anchor 1

reset; for k in 0 1 2 3 4 5 6 7 8 9; do fpage "$k" 100; done
run_find "$BASE" "$ACTOR" fya1c1
expect_rc3 "A3 ten full pages with no decision (page budget, no 11th request)" ahr_find_cycle_anchor 10

# ---- A3h freshness -----------------------------------------------------------
reset; health 1000 1000
run_fresh "$BASE" 30
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(calls)" = 1 ] && t_pass "A3h head == indexed -> 0, silent, one request" || t_fail "A3h head == indexed" "rc=$RC out=[$OUT] calls=$(calls)"
t_assert_eq "A3h the request is a plain GET of /v2/health" "-sSf --max-time 15 $BASE/v2/health" "$(cat "$WORK/calls.log")"
reset; health 1000 970
run_fresh "$BASE" 30
[ "$RC" -eq 0 ] && t_pass "A3h lag exactly 30 -> 0" || t_fail "A3h lag exactly 30" "rc=$RC"
reset; health 1000 969
run_fresh "$BASE" 30
expect_rc3 "A3h lag 31 -> 3" ahr_index_fresh 1
reset; health 1000 1031
run_fresh "$BASE" 30
expect_rc3 "A3h indexed ahead of head by 31 -> 3" ahr_index_fresh 1
reset; health 1000 990
run_fresh "$BASE" 05
[ "$RC" -eq 3 ] && t_pass "A3h max_lag 05 (leading zero is decimal 5), lag 10 -> 3" || t_fail "A3h max_lag 05" "rc=$RC"
reset; health 10 null
run_fresh "$BASE" 30
expect_rc3 "A3h last_indexed_block missing (a 0 fill would pass) -> 3" ahr_index_fresh 1
reset; health null 10
run_fresh "$BASE" 30
expect_rc3 "A3h head_block_num missing -> 3" ahr_index_fresh 1
reset; health 0 0
run_fresh "$BASE" 30
expect_rc3 "A3h head 0 -> 3" ahr_index_fresh 1
reset; health 1000 1000 Error
run_fresh "$BASE" 30
expect_rc3 "A3h an entry whose status is not OK -> 3" ahr_index_fresh 1
reset; printf '%s' '{"health":["OK"]}' > "$WORK/resp/health.json"
run_fresh "$BASE" 30
expect_rc3 "A3h a health entry that is not an object -> 3" ahr_index_fresh 1
reset; printf '%s' '{"health":[]}' > "$WORK/resp/health.json"
run_fresh "$BASE" 30
expect_rc3 "A3h empty health array -> 3" ahr_index_fresh 1
reset; printf '%s' '{"health":"OK"}' > "$WORK/resp/health.json"
run_fresh "$BASE" 30
expect_rc3 "A3h health is not an array -> 3" ahr_index_fresh 1
reset; printf '%s' 'not json' > "$WORK/resp/health.json"
run_fresh "$BASE" 30
expect_rc3 "A3h body is not JSON -> 3" ahr_index_fresh 1
reset
run_fresh "$BASE" 30
expect_rc3 "A3h curl failure -> 3" ahr_index_fresh 1
for ml in "" x -1 1.5 "１0"; do
	reset; health 1000 1000
	run_fresh "$BASE" "$ml"
	expect_rc3 "A3h max_lag [$ml] is not digits -> 3, no request" ahr_index_fresh 0
done
reset; health 1000 1000
run_fresh "http://history.example" 30
expect_rc3 "A3h base not https -> 3, no request" ahr_index_fresh 0

# ---- A4 prefix boundary and the cycle order -----------------------------------
reset; fpage 0 6; put 0 5 "$ACTOR" "$SINK" "fya1c10:abcd"
run_find "$BASE" "$ACTOR" fya1c1
expect_verdict "A4 send fya1c1, only fya1c10 on chain -> found_later" 1 "$(want_at found_later 0 5 6 null)"

reset; fpage 0 8; put 0 3 "$ACTOR" "$SINK" "fya1c1:abcd"
run_find "$BASE" "$ACTOR" fya1c10
expect_verdict "A4 send fya1c10, fya1c1 is the floor -> clear, floor fya1c1" 1 "$(want clear null null null 4 '"fya1c1"')"

reset; fpage 0 8; put 0 3 "$ACTOR" "$SINK" "fya2c9:abcd"
run_find "$BASE" "$ACTOR" fya1c3
expect_verdict "A4 a different schema is neither found nor floor (read to the end)" 1 "$(want clear null null null 8 null)"

reset; fpage 0 8; put 0 3 "$ACTOR" "$SINK" "fya1c01"
run_find "$BASE" "$ACTOR" fya1c1
expect_verdict "A4 cycle compared as a number: fya1c01 is cycle 1" 1 "$(want_at found 0 3 4 null)"

for m in "fya1c1" "fya1c1:7f3a" "fya1c1 note" "fya1c1_x"; do
	reset; fpage 0 8; put 0 3 "$ACTOR" "$SINK" "$m"
	run_find "$BASE" "$ACTOR" fya1c1
	expect_verdict "A4 memo [$m] ends at a non-digit boundary -> found" 1 "$(want_at found 0 3 4 null)"
done
reset; fpage 0 8; put 0 3 "$ACTOR" "$SINK" "xfya1c1"
run_find "$BASE" "$ACTOR" fya1c1
expect_verdict "A4 memo [xfya1c1] does not start with the anchor shape -> not an anchor" 1 "$(want clear null null null 8 null)"

# ---- A5 only the actor's own outgoing transfers count -------------------------
reset; fpage 0 4; put 0 0 "$STRANGER" "$ACTOR" "fya1c1"; put 0 1 "$STRANGER" "$ACTOR" "fya1c0"; put 0 2 "$STRANGER" "$ACTOR" "fya1c1:x"
run_find "$BASE" "$ACTOR" fya1c1
expect_verdict "A5 anchor-shaped memos sent TO the actor by a stranger -> clear, no floor" 1 "$(want clear null null null 4 null)"

reset; fpage 0 4; put 0 0 "$STRANGER" "fxother" "fya1c1"; put 0 1 "$STRANGER" "fxother" "fya1c0"
run_find "$BASE" "$ACTOR" fya1c1
expect_verdict "A5 transfers between two other accounts -> clear, no floor" 1 "$(want clear null null null 4 null)"

reset; fpage 0 4; put 0 0 "$ACTOR" "$SINK" "fya1c1"; edit 0 '.actions[0].act.account = "other.token"'
run_find "$BASE" "$ACTOR" fya1c1
expect_verdict "A5 the actor's fya1c1 on another token contract -> clear" 1 "$(want clear null null null 4 null)"

# ---- A6 the floor ends the scan ----------------------------------------------
reset; fpage 0 100; put 0 40 "$ACTOR" "$SINK" "fya1c8"
run_find "$BASE" "$ACTOR" fya1c9
expect_verdict "A6 floor on page 1 -> exactly one request" 1 "$(want clear null null null 41 '"fya1c8"')"

reset; fpage 0 100; fpage 1 100; fpage 2 100; put 2 5 "$ACTOR" "$SINK" "fya1c8"
run_find "$BASE" "$ACTOR" fya1c9
expect_verdict "A6 floor on page 3 -> exactly three requests" 3 "$(want clear null null null 206 '"fya1c8"')"

reset; fpage 0 6; put 0 2 "$ACTOR" "$SINK" "fya1c8"; edit 0 '.actions[3] = "garbage"'
run_find "$BASE" "$ACTOR" fya1c9
expect_verdict "A6 entries older than the decision are not read" 1 "$(want clear null null null 3 '"fya1c8"')"

# ---- FOUND the verdict carries the matched entry's own values ------------------
reset; fpage 0 100; put 0 7 "$ACTOR" "$SINK" "fya1c4:abc"
run_find "$BASE" "$ACTOR" fya1c4
expect_verdict "FOUND page 1, 8th entry: its trx_id/block_num/timestamp, scanned 8" 1 "$(want_at found 0 7 8 null)"

reset; fpage 0 100; fpage 1 100; fpage 2 100; put 2 3 "$ACTOR" "$SINK" "fya1c4"
run_find "$BASE" "$ACTOR" fya1c4
expect_verdict "FOUND page 3, 4th entry: scanned counts the two full pages" 3 "$(want_at found 2 3 204 null)"

# ---- IN input forms: rc 3 and no request ---------------------------------------
reset; run_find "" "$ACTOR" fya1c1
expect_rc3 "IN base empty" ahr_find_cycle_anchor 0
reset; run_find "http://history.example" "$ACTOR" fya1c1
expect_rc3 "IN base not https" ahr_find_cycle_anchor 0
reset; run_find "$BASE" "" fya1c1
expect_rc3 "IN actor empty" ahr_find_cycle_anchor 0
reset; run_find "$BASE" "abcdefghijklm" fya1c1
expect_rc3 "IN actor 13 characters" ahr_find_cycle_anchor 0
reset; run_find "$BASE" "FXANCHOR" fya1c1
expect_rc3 "IN actor upper case" ahr_find_cycle_anchor 0
reset; run_find "$BASE" "fxanchor6" fya1c1
expect_rc3 "IN actor with the digit 6" ahr_find_cycle_anchor 0
reset; run_find "$BASE" "fx anchor" fya1c1
expect_rc3 "IN actor with a space" ahr_find_cycle_anchor 0
reset; fpage 0 2
run_find "$BASE" "abcdefghijkl" fya1c1
expect_verdict "IN actor of 12 characters is accepted" 1 "$(want clear null null null 2 null)"
reset; fpage 0 2
run_find "$BASE" "a.b.c.1.2.3" fya1c1
expect_verdict "IN actor with dots and digits 1-5 is accepted" 1 "$(want clear null null null 2 null)"
for p in "" fya1c fyac1 fya1c1x fya1c1: "FYA1C1" "fya1c1c1" "fya c1" "fya1c1 "; do
	reset; run_find "$BASE" "$ACTOR" "$p"
	expect_rc3 "IN prefix [$p] is not fya<digits>c<digits>" ahr_find_cycle_anchor 0
done
# Full-width forms: the Mac's bash 3.2 lets [0-9] and [a-z] match them under a
# Japanese UTF-8 locale. Probe it in the same kind of subshell the cases use.
ja_probe() { ( LC_ALL=ja_JP.UTF-8; export LC_ALL; fw="１"; case "$fw" in [0-9]) exit 0 ;; esac; exit 1 ); }
if ja_probe; then
	reset; run_find_ja "$BASE" "$ACTOR" "fya１c1"
	expect_rc3 "IN prefix with a full-width digit (ja_JP.UTF-8)" ahr_find_cycle_anchor 0
	reset; run_find_ja "$BASE" "$ACTOR" "fya1c１"
	expect_rc3 "IN prefix with a full-width cycle digit (ja_JP.UTF-8)" ahr_find_cycle_anchor 0
	reset; run_find_ja "$BASE" "fxanchor１" fya1c1
	expect_rc3 "IN actor with a full-width digit (ja_JP.UTF-8)" ahr_find_cycle_anchor 0
	reset; run_find_ja "$BASE" "ｆｘａｎｃｈｏｒ" fya1c1
	expect_rc3 "IN actor in full-width letters (ja_JP.UTF-8)" ahr_find_cycle_anchor 0
	reset; health 1000 1000
	OUT="$( export LC_ALL=ja_JP.UTF-8; ahr_index_fresh "$BASE" "１" 2>"$WORK/err")"; RC=$?
	expect_rc3 "IN max_lag full-width digit (ja_JP.UTF-8)" ahr_index_fresh 0
elif [ "$(uname -s)" = Darwin ]; then
	t_fail "IN full-width cases" "ja_JP.UTF-8 probe did not match on Darwin (the cases must run here)"
else
	echo "SKIP  IN full-width cases — ja_JP.UTF-8 range probe did not match on $(uname -s)"
fi

# ---- ENT entries that cannot be read: rc 3, never skipped -----------------------
# Page = [odd entry, the actor's floor fya1c8]. Skipping the odd entry would
# read on to the floor and answer clear.
ent() { # <case> <jq filter on page 0>
	reset; fpage 0 3; put 0 1 "$ACTOR" "$SINK" "fya1c8"; edit 0 "$2"
	run_find "$BASE" "$ACTOR" fya1c9
	expect_rc3 "ENT $1" ahr_find_cycle_anchor 1
}
ent "entry is a string, not an object" '.actions[0] = "x"'
ent "act.account is a number" '.actions[0].act.account = 5'
ent "act.name is missing" 'del(.actions[0].act.name)'
ent "act is a string" '.actions[0].act = "x"'
ent "global_sequence is a string" '.actions[0].global_sequence = "x"'
ent "transfer whose act.data is a string" '.actions[0].act.data = "x"'
ent "transfer whose data.from is a number" '.actions[0].act.data.from = 5'
ent "transfer whose data.memo is null" '.actions[0].act.data.memo = null'
reset; fpage 0 3; put 0 1 "$ACTOR" "$SINK" "fya1c8"; edit 0 '.actions[0].act.name = "open" | .actions[0].act.data = "x"'
run_find "$BASE" "$ACTOR" fya1c9
expect_verdict "ENT a non-transfer entry is read and ignored, not refused" 1 "$(want clear null null null 2 '"fya1c8"')"
reset; fpage 0 3; put 0 1 "$ACTOR" "$SINK" "fya1c9"; edit 0 'del(.actions[1].trx_id)'
run_find "$BASE" "$ACTOR" fya1c9
expect_rc3 "ENT a match without trx_id" ahr_find_cycle_anchor 1
reset; fpage 0 3; put 0 1 "$ACTOR" "$SINK" "fya1c9"; edit 0 '.actions[1].block_num = "x"'
run_find "$BASE" "$ACTOR" fya1c9
expect_rc3 "ENT a match whose block_num is not a number" ahr_find_cycle_anchor 1
reset; fpage 0 3; put 0 1 "$ACTOR" "$SINK" "fya1c9"; edit 0 'del(.actions[1].timestamp)'
run_find "$BASE" "$ACTOR" fya1c9
expect_rc3 "ENT a match without timestamp" ahr_find_cycle_anchor 1

# ---- ORD order and overlap -----------------------------------------------------
reset; fpage 0 3; put 0 2 "$ACTOR" "$SINK" "fya1c8"; edit 0 '.actions[0].global_sequence = 50 | .actions[1].global_sequence = 60'
run_find "$BASE" "$ACTOR" fya1c9
expect_rc3 "ORD global_sequence ascending inside a page" ahr_find_cycle_anchor 1
reset; fpage 0 3; put 0 2 "$ACTOR" "$SINK" "fya1c8"; edit 0 '.actions[1].global_sequence = .actions[0].global_sequence'
run_find "$BASE" "$ACTOR" fya1c9
expect_rc3 "ORD global_sequence equal inside a page (strictly descending)" ahr_find_cycle_anchor 1
reset; fpage 0 100; filler 9903 100 > "$WORK/resp/actions-100.json"; put 1 10 "$ACTOR" "$SINK" "fya1c8"
run_find "$BASE" "$ACTOR" fya1c9
expect_verdict "ORD page 2 repeats 3 entries of page 1: scanned 108, not 111" 2 "$(want clear null null null 108 '"fya1c8"')"

# ---- END short page = history exhausted ---------------------------------------
reset; printf '%s' '{"actions":[]}' > "$WORK/resp/actions-0.json"
run_find "$BASE" "$ACTOR" fya1c1
expect_verdict "END page 1 has 0 entries -> clear, floor null, one request" 1 "$(want clear null null null 0 null)"
reset; fpage 0 100; fpage 1 100; fpage 2 37
run_find "$BASE" "$ACTOR" fya1c1
expect_verdict "END page 3 has 37 entries -> clear, floor null, three requests, scanned 237" 3 "$(want clear null null null 237 null)"

# ---- T time parts --------------------------------------------------------------
INFO_OK='{"head_block_time":"2026-11-17T04:45:12.500","last_irreversible_block_time":"2026-11-17T04:45:12.000","head_block_num":5}'
reset; printf '%s' "$INFO_OK" > "$WORK/resp/get_info.json"
run_times "$BASE"
t_assert_eq "T chain_times prints both times as served" '{"head_block_time":"2026-11-17T04:45:12.500","last_irreversible_block_time":"2026-11-17T04:45:12.000"}' "$OUT"
[ "$RC" -eq 0 ] && [ "$(calls)" = 1 ] && t_pass "T chain_times rc 0, one POST request" || t_fail "T chain_times rc/calls" "rc=$RC calls=$(calls)"
case "$(cat "$WORK/calls.log")" in *"-X POST"*"$BASE/v1/chain/get_info") t_pass "T chain_times uses POST get_info";; *) t_fail "T chain_times request" "$(cat "$WORK/calls.log")";; esac
reset; printf '%s' '{"head_block_time":"2026-11-17T04:45:12.500Z","last_irreversible_block_time":"2026-11-17T04:45:12Z"}' > "$WORK/resp/get_info.json"
run_times "$BASE"
t_assert_eq "T chain_times keeps a served Z and a served fraction untouched" '{"head_block_time":"2026-11-17T04:45:12.500Z","last_irreversible_block_time":"2026-11-17T04:45:12Z"}' "$OUT"
reset; printf '%s' '{"head_block_time":"2026-11-17T04:45:12.500"}' > "$WORK/resp/get_info.json"
run_times "$BASE"
expect_rc3 "T chain_times LIB missing (not filled from head)" ahr_chain_times 1
reset; printf '%s' '{"last_irreversible_block_time":"2026-11-17T04:45:12.000"}' > "$WORK/resp/get_info.json"
run_times "$BASE"
expect_rc3 "T chain_times head missing" ahr_chain_times 1
reset; printf '%s' '{"head_block_time":"2026-11-17T04:45:12.500","last_irreversible_block_time":null}' > "$WORK/resp/get_info.json"
run_times "$BASE"
expect_rc3 "T chain_times LIB null" ahr_chain_times 1
reset; printf '%s' '{"head_block_time":"2026-11-17 04:45:12","last_irreversible_block_time":"2026-11-17T04:45:12.000"}' > "$WORK/resp/get_info.json"
run_times "$BASE"
expect_rc3 "T chain_times head with a space instead of T" ahr_chain_times 1
reset; printf '%s' '{"head_block_time":"2026-11-17T04:45:12.500","last_irreversible_block_time":1794890712}' > "$WORK/resp/get_info.json"
run_times "$BASE"
expect_rc3 "T chain_times LIB is a number" ahr_chain_times 1
reset
run_times "$BASE"
expect_rc3 "T chain_times curl failure" ahr_chain_times 1
reset; printf '%s' "$INFO_OK" > "$WORK/resp/get_info.json"
run_times "http://history.example"
expect_rc3 "T chain_times base not https, no request" ahr_chain_times 0

utc2epoch() { OUT="$(ahr_utc_to_epoch "$1" 2>/dev/null)"; RC=$?; }
epoch2utc() { OUT="$(ahr_epoch_to_utc "$1" 2>/dev/null)"; RC=$?; }
for tz in Asia/Tokyo America/New_York; do
	OUT="$( export TZ="$tz"; ahr_utc_to_epoch 2026-11-17T04:45:12 2>/dev/null )"
	t_assert_eq "T utc_to_epoch ignores TZ ($tz)" 1794890712 "$OUT"
	OUT="$( export TZ="$tz"; ahr_epoch_to_utc 1794890712 2>/dev/null )"
	t_assert_eq "T epoch_to_utc ignores TZ ($tz)" 2026-11-17T04:45:12 "$OUT"
done
utc2epoch 2000-01-01T00:00:00Z
t_assert_eq "T utc_to_epoch accepts a trailing Z" 946684800 "$OUT"
utc2epoch 2026-11-17T04:45:12.999999Z
t_assert_eq "T utc_to_epoch truncates the fraction (does not round)" 1794890712 "$OUT"
utc2epoch 2026-11-17T04:45:12.5
t_assert_eq "T utc_to_epoch fraction without Z" 1794890712 "$OUT"
epoch2utc 0
t_assert_eq "T epoch_to_utc 0 has no trailing Z" 1970-01-01T00:00:00 "$OUT"
epoch2utc 946684800
t_assert_eq "T epoch_to_utc 946684800" 2000-01-01T00:00:00 "$OUT"
epoch2utc 0099
t_assert_eq "T epoch_to_utc 0099 is decimal 99" 1970-01-01T00:01:39 "$OUT"
utc2epoch 2026-12-07T04:00:21
epoch2utc "$OUT"
t_assert_eq "T round trip utc -> epoch -> utc" 2026-12-07T04:00:21 "$OUT"
for bad in "" 2026-11-17 "2026-11-17 04:45:12" 2026-11-17T04:45:12+09:00 2026-11-17T04:45:12.1234567 2026-11-17T04:45:12.Z \
	2026-02-30T00:00:00 2026-13-01T00:00:00 "２026-11-17T04:45:12" "2026-11-17T04:45:12
" 2026-11-17T04:45:12ZZ x; do
	utc2epoch "$bad"; label="$(printf '%s' "$bad" | tr '\n' '~')"
	{ defined ahr_utc_to_epoch && [ "$RC" -eq 3 ] && [ -z "$OUT" ]; } && t_pass "T utc_to_epoch refuses [$label]" || t_fail "T utc_to_epoch refuses [$label]" "rc=$RC out=[$OUT]"
done
for bad in "" -1 1.5 abc "１２" 1e3 9999999999999; do
	epoch2utc "$bad"
	{ defined ahr_epoch_to_utc && [ "$RC" -eq 3 ] && [ -z "$OUT" ]; } && t_pass "T epoch_to_utc refuses [$bad]" || t_fail "T epoch_to_utc refuses [$bad]" "rc=$RC out=[$OUT]"
done

echo "---"
t_summary ahr-find-cycle-anchor || :
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"
exit 1
