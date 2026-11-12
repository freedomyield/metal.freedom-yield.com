#!/usr/bin/env bash
# test-fetch-retry.sh — suite for scripts/lib/fetch-retry.sh (fy_fetch_retry).
#
# CHAIN: none — curl is always a stub; nothing leaves the machine.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction).
#
# LIB=<path> runs the suite against another copy (used by the mutation runs).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LIB="${LIB:-$REPO_ROOT/scripts/lib/fetch-retry.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAILN=0; SKIPN=0

ok()   { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAILN=$((FAILN + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }
eq()   { # name got want
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "got [$2] want [$3]"; fi
}

# stub curl: line N of $T/script is "CODE[ BODY]" or "FAIL"; past the end repeats the last;
# past call 12 it always answers 200 (see the cap line below).
cat > "$T/curl-stub" <<'STUB'
#!/usr/bin/env bash
T="$(dirname "$0")"
n=$(( $(cat "$T/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$T/count"
printf '%s\n' "$*" >> "$T/args"
line="$(sed -n "${n}p" "$T/script")"
[ -z "$line" ] && line="$(tail -n 1 "$T/script")"
code="${line%% *}"; body=""
case "$line" in *" "*) body="${line#* }" ;; esac
[ "$n" -gt 12 ] && code=200   # safety cap: a loop that would not stop ends here, so a broken lib fails by assertion, not by timeout
out=""
while [ "$#" -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
[ "$code" = "FAIL" ] && exit 7
printf '%s' "$body" > "$out"
printf '%s' "$code"
STUB
chmod +x "$T/curl-stub"

# run <script-lines> <args...> : sets OUT RC ERR CALLS BODY
run() {
	printf '%s\n' "$1" > "$T/script"; shift
	rm -f "$T/count" "$T/args" "$T/body" "$T/sleeps"
	# sleep is replaced inside the subshell: it records its argument and never really sleeps
	# RUN_LC (optional) names the locale the subshell runs in; the lib is loaded under it
	OUT="$( ( [ -n "${RUN_LC:-}" ] && export LC_ALL="$RUN_LC"; . "$LIB"; sleep() { printf '%s\n' "$1" >> "$T/sleeps"; }; CURL="$T/curl-stub" fy_fetch_retry "$@" ) 2>"$T/err"; echo "rc=$?" )"
	RC="${OUT##*rc=}"; OUT="${OUT%rc=*}"
	ERR="$(cat "$T/err")"
	SLEEPN="$(wc -l < "$T/sleeps" 2>/dev/null | tr -d ' ')"; SLEEPN="${SLEEPN:-0}"
	SLEEPV="$(sort -u "$T/sleeps" 2>/dev/null | tr '\n' ' ')"
	CALLS="$(cat "$T/count" 2>/dev/null || echo 0)"
	BODY="$(cat "$T/body" 2>/dev/null)"
}
export FYD_RETRY_SLEEP=0
U=http://example.invalid/x
unset FYD_FETCH_ATTEMPTS

run "200 ok" --max-time=15 -- "$U" "$T/body"
eq "200-at-once code" "$OUT" "200"; eq "200-at-once calls" "$CALLS" "1"; eq "200-at-once rc" "$RC" "0"
eq "outfile-holds-body" "$BODY" "ok"

run "$(printf '500 a\n500 b\n200 c')" --max-time=15 -- "$U" "$T/body"
eq "500-500-200 code" "$OUT" "200"; eq "500-500-200 calls" "$CALLS" "3"; eq "outfile-last-body" "$BODY" "c"

run "500 z" --max-time=15 -- "$U" "$T/body"
eq "500x3 code" "$OUT" "500"; eq "500x3 calls" "$CALLS" "3"

run "FAIL" --max-time=15 -- "$U" "$T/body"
eq "transport-failure code" "$OUT" "000"; eq "transport-failure calls" "$CALLS" "3"

run "$(printf '404 n\n200 y')" --max-time=15 --no-retry-4xx -- "$U" "$T/body"
eq "no-retry-4xx code" "$OUT" "404"; eq "no-retry-4xx calls" "$CALLS" "1"
run "$(printf '404 n\n200 y')" --max-time=15 -- "$U" "$T/body"
eq "retry-4xx-default code" "$OUT" "200"; eq "retry-4xx-default calls" "$CALLS" "2"
# just outside the 4xx exception: 5xx and 3xx still retry under --no-retry-4xx
run "$(printf '503 n\n200 y')" --max-time=15 --no-retry-4xx -- "$U" "$T/body"
eq "5xx-retries-with-flag calls" "$CALLS" "2"
run "$(printf '302 n\n200 y')" --max-time=15 --no-retry-4xx -- "$U" "$T/body"
eq "3xx-retries-with-flag calls" "$CALLS" "2"
run "$(printf '399 n\n200 y')" --max-time=15 --no-retry-4xx -- "$U" "$T/body"
eq "399-retries-with-flag calls" "$CALLS" "2"
run "$(printf '500 n\n200 y')" --max-time=15 --no-retry-4xx -- "$U" "$T/body"
eq "500-retries-with-flag calls" "$CALLS" "2"

FYD_FETCH_ATTEMPTS=1 run "500 z" --max-time=15 -- "$U" "$T/body"
eq "attempts=1 calls" "$CALLS" "1"; eq "attempts=1 code" "$OUT" "500"
FYD_FETCH_ATTEMPTS=5 run "500 z" --max-time=15 -- "$U" "$T/body"
eq "attempts=5 calls" "$CALLS" "5"

# FYD_FETCH_ATTEMPTS: unset / empty -> default 3; a well-formed 1..10 -> that many calls (500 stub)
run "500 z" --max-time=15 -- "$U" "$T/body"
eq "attempts=unset calls" "$CALLS" "3"; eq "attempts=unset rc" "$RC" "0"
FYD_FETCH_ATTEMPTS="" run "500 z" --max-time=15 -- "$U" "$T/body"
eq "attempts=empty calls" "$CALLS" "3"; eq "attempts=empty rc" "$RC" "0"
FYD_FETCH_ATTEMPTS=3 run "500 z" --max-time=15 -- "$U" "$T/body"
eq "attempts=3 calls" "$CALLS" "3"
FYD_FETCH_ATTEMPTS=10 run "500 z" --max-time=15 -- "$U" "$T/body"
eq "attempts=10 calls" "$CALLS" "10"; eq "attempts=10 code" "$OUT" "500"
# FYD_RETRY_SLEEP: unset / empty -> default 3; a well-formed 0..60 is handed to sleep as is
unset FYD_RETRY_SLEEP
run "500 z" --max-time=15 -- "$U" "$T/body"
eq "sleep=unset passed" "$SLEEPV" "3 "; eq "sleep=unset times" "$SLEEPN" "2"
export FYD_RETRY_SLEEP=0
FYD_RETRY_SLEEP="" run "500 z" --max-time=15 -- "$U" "$T/body"
eq "sleep=empty passed" "$SLEEPV" "3 "; eq "sleep=empty times" "$SLEEPN" "2"
for v in 0 3 60; do
	FYD_RETRY_SLEEP="$v" run "500 z" --max-time=15 -- "$U" "$T/body"
	eq "sleep=$v passed" "$SLEEPV" "$v "; eq "sleep=$v times" "$SLEEPN" "2"; eq "sleep=$v rc" "$RC" "0"
done

# a malformed value is a usage error: 64, no curl, nothing on stdout, no OUTFILE, no sleep,
# exactly one stderr line naming the key (never the value)
MSG_A="fy_fetch_retry: FYD_FETCH_ATTEMPTS must be an integer 1..10"
MSG_S="fy_fetch_retry: FYD_RETRY_SLEEP must be an integer 0..60"
badval() { # name key value expected-message
	local n="$1" k="$2" v="$3" want="$4"
	if [ "$k" = FYD_FETCH_ATTEMPTS ]; then
		FYD_FETCH_ATTEMPTS="$v" run "500 z" --max-time=15 -- "$U" "$T/body"
	else
		FYD_RETRY_SLEEP="$v" run "500 z" --max-time=15 -- "$U" "$T/body"
	fi
	eq "$n rc" "$RC" "64"; eq "$n no-curl" "$CALLS" "0"; eq "$n stdout-empty" "$OUT" ""
	if [ -e "$T/body" ]; then fail "$n no-outfile" "OUTFILE was created"; else ok "$n no-outfile"; fi
	eq "$n no-sleep" "$SLEEPN" "0"
	eq "$n stderr" "$ERR" "$want"; eq "$n stderr-lines" "$(wc -l < "$T/err" | tr -d ' ')" "1"
}
badval "attempts=0" FYD_FETCH_ATTEMPTS 0 "$MSG_A"
badval "attempts=11" FYD_FETCH_ATTEMPTS 11 "$MSG_A"
badval "attempts=neg" FYD_FETCH_ATTEMPTS -1 "$MSG_A"
badval "attempts=frac" FYD_FETCH_ATTEMPTS 1.5 "$MSG_A"
badval "attempts=alpha" FYD_FETCH_ATTEMPTS abc "$MSG_A"
badval "attempts=lead-zero" FYD_FETCH_ATTEMPTS 03 "$MSG_A"
badval "attempts=plus" FYD_FETCH_ATTEMPTS +3 "$MSG_A"
badval "attempts=lead-space" FYD_FETCH_ATTEMPTS " 3" "$MSG_A"
badval "attempts=trail-space" FYD_FETCH_ATTEMPTS "3 " "$MSG_A"
badval "attempts=newline" FYD_FETCH_ATTEMPTS $'3\n' "$MSG_A"
badval "attempts=hex" FYD_FETCH_ATTEMPTS 0x3 "$MSG_A"
badval "attempts=exp" FYD_FETCH_ATTEMPTS 1e1 "$MSG_A"
badval "attempts=huge" FYD_FETCH_ATTEMPTS 99999999999999999999 "$MSG_A"
badval "sleep=61" FYD_RETRY_SLEEP 61 "$MSG_S"
badval "sleep=neg" FYD_RETRY_SLEEP -1 "$MSG_S"
badval "sleep=frac" FYD_RETRY_SLEEP 0.5 "$MSG_S"
badval "sleep=alpha" FYD_RETRY_SLEEP abc "$MSG_S"
badval "sleep=lead-zero" FYD_RETRY_SLEEP 03 "$MSG_S"
badval "sleep=double-zero" FYD_RETRY_SLEEP 00 "$MSG_S"
badval "sleep=plus" FYD_RETRY_SLEEP +1 "$MSG_S"
badval "sleep=lead-space" FYD_RETRY_SLEEP " 0" "$MSG_S"
badval "sleep=trail-space" FYD_RETRY_SLEEP "0 " "$MSG_S"
badval "sleep=newline" FYD_RETRY_SLEEP $'0\n' "$MSG_S"
badval "sleep=huge" FYD_RETRY_SLEEP 99999999999999999999 "$MSG_S"
# both malformed: the FYD_FETCH_ATTEMPTS line only
FYD_FETCH_ATTEMPTS=abc FYD_RETRY_SLEEP=abc run "500 z" --max-time=15 -- "$U" "$T/body"
eq "both-bad rc" "$RC" "64"; eq "both-bad stderr" "$ERR" "$MSG_A"; eq "both-bad no-curl" "$CALLS" "0"
# an OUTFILE that already exists is left exactly as it was (content and mtime)
printf 'keep' > "$T/pre"; touch -t 200001010000 "$T/pre"; touch -t 200101010000 "$T/ref"
FYD_FETCH_ATTEMPTS=abc run "200 new" --max-time=15 -- "$U" "$T/pre"
eq "attempts=alpha outfile-content" "$(cat "$T/pre")" "keep"
if [ "$T/pre" -ot "$T/ref" ]; then ok "attempts=alpha outfile-mtime"; else fail "attempts=alpha outfile-mtime" "mtime changed"; fi

# --- shape checks are ASCII-only whatever the caller's locale (audit B1) ---
# Under ja_JP.UTF-8 on this Mac's bash 3.2 a range such as [0-9] also matches the full-width digits
# U+FF10..FF19, so a range-based check lets FYD_FETCH_ATTEMPTS=<full-width 1> through and the loop
# never stops. The cases below run the lib under that locale with full-width values.
JA_LC="ja_JP.UTF-8"
FW0=$'\xef\xbc\x90'; FW1=$'\xef\xbc\x91'; FW3=$'\xef\xbc\x93'; FW5=$'\xef\xbc\x95'; FW6=$'\xef\xbc\x96'
skip() { SKIPN=$((SKIPN + 1)); printf 'SKIP %s — %s\n' "$1" "$2"; }
# probe: does the range [0-9] match a full-width digit in this bash under that locale?
# hit = the locale is in force and the old range-based check would have let the value through
JA_PROBE="$(LC_ALL="$JA_LC" "$BASH" -c 'case "$1" in [0-9]) printf hit ;; *) printf miss ;; esac' _ "$FW1" 2>/dev/null)"
JA_OK=0
if [ "$JA_PROBE" = "hit" ]; then
	JA_OK=1
elif [ "$(uname -s)" = "Darwin" ]; then
	fail "ja-locale-probe" "probe=[$JA_PROBE] locale=$JA_LC bash=$BASH_VERSION: on Darwin the full-width cases must run, so this is a failure, not a skip"
else
	JA_WHY="probe=[$JA_PROBE] locale=$JA_LC bash=$BASH_VERSION uname=$(uname -s)"
fi
[ "$JA_OK" = 1 ] && ok "ja-locale-probe"

# jabad <name> <attempts> <sleep> <max-time value> <expected stderr>: one shape rejected under the ja locale
jabad() {
	local n="$1" a="$2" s="$3" m="$4" want="$5"
	if [ "$JA_OK" != 1 ]; then skip "$n" "$JA_WHY"; return 0; fi
	RUN_LC="$JA_LC" FYD_FETCH_ATTEMPTS="$a" FYD_RETRY_SLEEP="$s" run "500 z" --max-time="$m" -- "$U" "$T/body"
	eq "$n rc" "$RC" "64"; eq "$n no-curl" "$CALLS" "0"; eq "$n stdout-empty" "$OUT" ""
	if [ -e "$T/body" ]; then fail "$n no-outfile" "OUTFILE was created"; else ok "$n no-outfile"; fi
	eq "$n stderr" "$ERR" "$want"; eq "$n stderr-lines" "$(wc -l < "$T/err" | tr -d ' ')" "1"
}
MSG_M="fy_fetch_retry: --max-time=SECONDS (integer) is required"
jabad "ja attempts=fw1" "$FW1" 2 15 "$MSG_A"
jabad "ja attempts=fw10" "$FW1$FW0" 2 15 "$MSG_A"
jabad "ja attempts=fw5" "$FW5" 2 15 "$MSG_A"
jabad "ja sleep=fw6" 2 "$FW6" 15 "$MSG_S"
jabad "ja sleep=fw60" 2 "$FW6$FW0" 15 "$MSG_S"
jabad "ja sleep=fw30" 2 "$FW3$FW0" 15 "$MSG_S"
jabad "ja sleep=fw0" 2 "$FW0" 15 "$MSG_S"
jabad "ja max-time=fw15" 2 0 "$FW1$FW5" "$MSG_M"
jabad "ja max-time=fw1" 2 0 "$FW1" "$MSG_M"
# the ASCII values that must keep working under the same locale (run on every host)
jaok() { # name attempts sleep max-time want-calls want-sleep
	RUN_LC="$JA_LC" FYD_FETCH_ATTEMPTS="$2" FYD_RETRY_SLEEP="$3" run "500 z" --max-time="$4" -- "$U" "$T/body"
	eq "$1 rc" "$RC" "0"; eq "$1 calls" "$CALLS" "$5"; eq "$1 code" "$OUT" "500"
	eq "$1 sleep" "$SLEEPV" "$6"
}
jaok "ja ascii attempts=1" 1 0 15 1 ""
jaok "ja ascii attempts=10" 10 0 15 10 "0 "
jaok "ja ascii sleep=0" 2 0 15 2 "0 "
jaok "ja ascii sleep=60" 2 60 15 2 "60 "
RUN_LC="$JA_LC" run "200 ok" --max-time=15 -- "$U" "$T/body"
eq "ja ascii max-time=15 rc" "$RC" "0"; eq "ja ascii max-time=15 calls" "$CALLS" "1"
eq "ja ascii max-time=15 args" "$(cat "$T/args")" "-sS -o $T/body -w %{http_code} --max-time 15 $U"

# the curl line
run "200 ok" --max-time=15 -- "$U" "$T/body"
eq "curl args 15" "$(cat "$T/args")" "-sS -o $T/body -w %{http_code} --max-time 15 $U"
run "200 ok" --max-time=20 -- "$U" "$T/body"
eq "curl args 20" "$(cat "$T/args")" "-sS -o $T/body -w %{http_code} --max-time 20 $U"

# no trailing newline
run "200 ok" --max-time=15 -- "$U" "$T/body"
eq "stdout-no-newline" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" "3"

# usage errors: 64, no curl call
usage() { # name args...
	local n="$1"; shift
	run "200 ok" "$@"
	eq "$n rc" "$RC" "64"; eq "$n no-curl" "$CALLS" "0"
}
usage "missing-max-time" -- "$U" "$T/body"
usage "non-integer-max-time" --max-time=abc -- "$U" "$T/body"
usage "empty-max-time" --max-time= -- "$U" "$T/body"
usage "unknown-option" --max-time=15 --bogus -- "$U" "$T/body"
usage "missing-dashdash" --max-time=15 "$U" "$T/body"
usage "missing-url-outfile" --max-time=15 --
usage "missing-outfile" --max-time=15 -- "$U"
usage "extra-arg" --max-time=15 -- "$U" "$T/body" extra
usage "empty-url" --max-time=15 -- "" "$T/body"

# sourcing prints nothing, defines only fy_fetch_retry and _fy_fetch_retry_*
SRC_OUT="$(bash -c ". '$LIB'" 2>&1)"; eq "source-silent" "$SRC_OUT" ""
FUNCS="$(bash -c ". '$LIB'; declare -F | sed 's/^declare -f //' | sort | tr '\n' ' '")"
BAD=""; for f in $FUNCS; do case "$f" in fy_fetch_retry|_fy_fetch_retry_*) ;; *) BAD="$BAD $f" ;; esac; done
eq "defines-only-own-functions" "$BAD" ""
case " $FUNCS " in *" fy_fetch_retry "*) ok "defines-fy_fetch_retry" ;; *) fail "defines-fy_fetch_retry" "funcs: $FUNCS" ;; esac

# header + B-P7
head -10 "$LIB" | grep -q '^# CHAIN: none' && ok "header-chain" || fail "header-chain" "no CHAIN in first 10 lines"
head -10 "$LIB" | grep -q '^# PRIME_DIRECTIVE: TESTNET-FIRST' && ok "header-prime" || fail "header-prime" "no PRIME_DIRECTIVE in first 10 lines"
HITS="$(grep -nE '\bexit\b|fyd_notify|fyd_push|FY_LIVE' "$LIB" | wc -l | tr -d ' ')"
eq "B-P7 no exit/notify/push/FY_LIVE" "$HITS" "0"

printf 'test-fetch-retry summary: %s passed, %s failed, %s skipped\n' "$PASS" "$FAILN" "$SKIPN"
[ "$FAILN" -eq 0 ]
