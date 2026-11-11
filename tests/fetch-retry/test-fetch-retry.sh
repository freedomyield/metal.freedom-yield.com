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
PASS=0; FAILN=0

ok()   { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAILN=$((FAILN + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }
eq()   { # name got want
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "got [$2] want [$3]"; fi
}

# stub curl: line N of $T/script is "CODE[ BODY]" or "FAIL"; past the end repeats the last.
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
	rm -f "$T/count" "$T/args" "$T/body"
	OUT="$( ( . "$LIB"; CURL="$T/curl-stub" fy_fetch_retry "$@" ) 2>"$T/err"; echo "rc=$?" )"
	RC="${OUT##*rc=}"; OUT="${OUT%rc=*}"
	ERR="$(cat "$T/err")"
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

# unusual FYD_FETCH_ATTEMPTS: same as the copies (0 -> one call; non-numeric -> never stops on its own, test bounded by a 200)
FYD_FETCH_ATTEMPTS=0 run "500 z" --max-time=15 -- "$U" "$T/body"
eq "attempts=0 calls" "$CALLS" "1"; eq "attempts=0 code" "$OUT" "500"
FYD_FETCH_ATTEMPTS=abc run "$(printf '500 a\n500 b\n200 c')" --max-time=15 -- "$U" "$T/body"
eq "attempts=abc keeps retrying until 200" "$OUT" "200"; eq "attempts=abc calls" "$CALLS" "3"
case "$ERR" in *"integer"*) ok "attempts=abc stderr noise like the copies" ;; *) fail "attempts=abc stderr noise like the copies" "stderr: $ERR" ;; esac
FYD_RETRY_SLEEP=abc run "$(printf '500 a\n200 c')" --max-time=15 -- "$U" "$T/body"
eq "sleep=abc still returns" "$OUT" "200"; eq "sleep=abc calls" "$CALLS" "2"
FYD_RETRY_SLEEP=0 run "200 ok" --max-time=15 -- "$U" "$T/body"

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

printf 'test-fetch-retry summary: %s passed, %s failed\n' "$PASS" "$FAILN"
[ "$FAILN" -eq 0 ]
