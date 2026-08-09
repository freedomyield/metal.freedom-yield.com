#!/usr/bin/env bash
# tests/anomalies/test-delegation-notify-body.sh
#
# Exact-string coverage for the two delegation-transition notification bodies
# produced by scripts/check-anomalies.sh.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction).
#
# WHY THIS EXISTS
#   Until 2026-08-06 the increase body rendered
#       受入額: <received> METAL
#       自己 stake: <self> METAL / 受入枠 <cap> METAL
#   The slash had a DIFFERENT quantity on each side — self stake over the
#   delegation ceiling — so it read as a ratio while being none, and the
#   number that actually belongs over that denominator (cumulative received)
#   was stranded on the previous line. The operator caught it in a live push.
#   The decrease body carried the same received figure with no ceiling
#   context at all.
#
#   On 2026-08-10 the operator reported the next layer of the same problem:
#   the push said "+1 件" and never said what that one delegation was WORTH.
#   The previous cumulative was already in the state file — written on every
#   successful notify, never read back — so the delta was recoverable and
#   simply was not being computed. The body now carries a 新規 / 離脱 line,
#   and the cumulative line was shortened to a bare ratio (label, unit and
#   normal-case head-room dropped) because a phone push is read in two
#   seconds. 満枠 keeps its 🔒 marker: "cannot receive more" is an operational
#   branch, not an arithmetic one.
#
#   Both failures were of MEANING, not of mechanism, so the assertions here
#   are on the exact bytes of the delivered body, not on "a notify happened".
#
# METHOD
#   The real script is driven end to end inside a sandbox repo: a curl stand-in
#   answers platform.getCurrentValidators with a canned delegator set, and
#   scripts/notify.sh is a recording shim, so what is asserted is the body the
#   operator would actually have received. The "live numbers" case below uses
#   the exact figures from the 2026-08-10 report (self 21640, 33179.7979 →
#   33768.7979, 8 delegators) so its expected body can be diffed against the
#   operator's own mock line for line.
#
# Usage:
#   bash tests/anomalies/test-delegation-notify-body.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED
#   0 with SKIP lines when the host has no GNU date (the script's own K-2
#     freshness gate needs `date -d`, so the run cannot reach the transition)

set -u

# tests/run-all-tests.sh drives its suite list through `while read … done <
# <(find …)`, i.e. on THIS script's stdin. Anything in here that reads stdin
# eats the rest of the run and the suite silently finishes early with a green
# "ALL PASS" on a truncated list — which is exactly what happened while these
# cases were being written (a `grep -qF "-589"` parsed the needle as an option,
# fell back to stdin, and swallowed 76 of the 88 suites). The `--` terminators
# in assert_has / assert_lacks are the real fix; this is the backstop so the
# next such slip costs one red assertion instead of the whole run.
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO}/scripts/check-anomalies.sh"

PASS=0
FAIL=0
SKIP=0
FAILURES=()
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILURES+=("$1${2:+ — $2}"); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}" >&2; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s%s\n' "$1" "${2:+ — $2}"; }

TMP="$(mktemp -d -t fy-deleg-body.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BIN="${TMP}/bin"
mkdir -p "$BIN"

# --- PATH stand-ins (test-local; nothing on this machine is modified) ------
# curl: answers the P-chain RPC with the canned validator set, fails anything
# else the way an unreachable host would (the web probe reads 000, and the
# baseline below already says web=warn so no transition and no 30s sleep).
RPC_JSON="${TMP}/rpc.json"
cat >"${BIN}/curl" <<CURLEOF
#!/usr/bin/env bash
for a in "\$@"; do
	case "\$a" in
		*/ext/bc/P) cat "${RPC_JSON}"; exit 0 ;;
	esac
done
exit 7
CURLEOF
chmod +x "${BIN}/curl"

# flock: util-linux is absent on macOS. Always reports "acquired"; it does NOT
# implement locking (contention semantics live in
# tests/anomalies/integration-linux.sh, which only runs where flock is real).
if ! command -v flock >/dev/null 2>&1; then
	printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN}/flock"
	chmod +x "${BIN}/flock"
fi

# date: the script's K-2 freshness gate needs GNU `date -d`. Point at the real
# gdate binary when the host date cannot do it; skip honestly when neither is
# available rather than faking a clock.
GNU_DATE=1
if ! date -u -d '@0' +%s >/dev/null 2>&1; then
	if command -v gdate >/dev/null 2>&1; then
		printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(command -v gdate)" >"${BIN}/date"
		chmod +x "${BIN}/date"
	else
		GNU_DATE=0
	fi
fi
export PATH="${BIN}:${PATH}"

# --- fixture values --------------------------------------------------------
SELF_STAKE=21640                      # METAL
TOTAL_NMETAL=11183797900000           # = 11183.7979 METAL
NODE_ID="NodeID-sandboxdelegationtest"
EXPECT_RECEIVED="11183.7979"
EXPECT_CAP="86560"                    # 21640 * 4
EXPECT_REMAIN="75376.2021"            # 86560 - 11183.7979 (daily-status.sh still shows it)
EXPECT_WEIGHT="32823.7979"            # 21640 + 11183.7979

# Baseline cumulative for the default cases: 589 METAL below the observed
# total, so the default delta is the operator's own 589 figure.
DEFAULT_BASELINE_TOTAL=10594797900000 # = 10594.7979 METAL

# write_rpc <delegator_count> <aggregate_weight_nmetal>
#   Only .delegatorCount and .delegatorWeight feed the notification body;
#   the per-delegator array exists so the lifecycle-event diff has something
#   to chew on (its output is asserted in other tests, not here).
write_rpc() {
	local count="$1" weight="$2" i list=""
	for ((i = 1; i <= count; i++)); do
		[ -n "$list" ] && list="${list},"
		list="${list}{\"txID\":\"tx-$(printf '%03d' "$i")\",\"weight\":\"1\",\"endTime\":\"4102444800\"}"
	done
	cat >"$RPC_JSON" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"validators":[{
  "nodeID":"${NODE_ID}",
  "endTime":"4102444800",
  "delegatorCount":"${count}",
  "delegatorWeight":"${weight}",
  "delegators":[${list}]
}]}}
JSON
}
write_rpc 3 "$TOTAL_NMETAL"

# BASELINE_TOTAL_NMETAL is consume-once: set it immediately before a
# build_sandbox call to state that case's baseline cumulative, and
# build_sandbox clears it again so the next case cannot silently inherit it.
BASELINE_TOTAL_NMETAL=""

# build_sandbox <name> <baseline delegator_count> [script-override]
#   Returns the sandbox path in $S and the recording log path in $LOG.
build_sandbox() {
	local name="$1" baseline_count="$2" script_src="${3:-$SCRIPT}"
	local baseline_total="${BASELINE_TOTAL_NMETAL:-$DEFAULT_BASELINE_TOTAL}"
	BASELINE_TOTAL_NMETAL=""
	S="${TMP}/${name}"
	LOG="${TMP}/${name}.notify.log"
	rm -rf "$S"; : >"$LOG"
	mkdir -p "${S}/scripts/lib" "${S}/public/api" "${S}/state/locks"
	cp "$script_src" "${S}/scripts/check-anomalies.sh"
	cp "${REPO}/scripts/lib/side-effects.sh" "${S}/scripts/lib/side-effects.sh"
	cat >"${S}/scripts/notify.sh" <<SHIM
#!/usr/bin/env bash
{ printf 'TITLE<<%s>>\n' "\$2"; printf 'BODY<<%s>>\n' "\$3"; } >>"${LOG}"
exit 0
SHIM
	chmod +x "${S}/scripts/notify.sh"

	cat >"${S}/public/api/validator.json" <<JSON
{ "nodeId": "${NODE_ID}", "uptime": { "network": "99.0000" }, "stake": { "self": ${SELF_STAKE} } }
JSON
	cat >"${S}/public/api/server-status.json" <<JSON
{
  "observedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "metalgo": { "containerStatus": "running", "peerCount": 120 },
  "caddy":   { "containerStatus": "running" },
  "host": {
    "cpu":    { "usedPercent": 15 },
    "memory": { "usedPercent": 30, "totalKB": 16000000, "usedKB":  4800000 },
    "disk":   { "usedPercent": 40, "totalKB": 500000000, "usedKB": 200000000 }
  }
}
JSON
	# web / api_freshness start at warn so neither transition fires (and the
	# 30-second web re-probe is skipped). delegator_snapshot is empty so the
	# lifecycle-event diff has a baseline to work from.
	cat >"${S}/state/anomaly-state.json" <<JSON
{
  "metalgo": "running", "caddy": "running", "disk": "ok", "memory": "ok",
  "peers": "ok", "web": "warn", "api_freshness": "warn",
  "validator_present": "yes", "last_known_end_time": null,
  "delegator_count": ${baseline_count}, "delegator_total_nmetal": ${baseline_total},
  "delegator_snapshot": [],
  "period_alert_sent": { "7": false, "1": false, "0": false, "10min": false }
}
JSON
}

run_sandbox() {
	env FY_LIVE=1 \
		ANOMALY_STATE_DIR="${S}/state" \
		NODE_ID="$NODE_ID" \
		METALGO_API="http://127.0.0.1:1" \
		WEB_URL="http://127.0.0.1:1" \
		FRESH_REPROBE_SLEEP=0 \
		bash "${S}/scripts/check-anomalies.sh" >/dev/null 2>&1
}

body_of() { sed -n 's/^BODY<<//p' "$LOG" | head -1; }
whole_of() { cat "$LOG"; }
# The bodies are multi-line, so the recorded BODY<<…>> spans to EOF.
actual_body() { sed -n '/^BODY<</,$p' "$LOG" | sed '1s/^BODY<<//' | sed '$s/>>$//'; }

# assert_body <case name> <expected body>
assert_body() {
	local name="$1" expected="$2" actual
	actual="$(actual_body)"
	if [ "$actual" = "$expected" ]; then
		ok "$name"
	else
		bad "$name" "expected [$expected] actual [$actual]"
	fi
}
# assert_has / assert_lacks <case name> <fixed needle>
# `--` is load-bearing: needles here legitimately start with '-' (a leaked
# negative amount is one of the things being ruled out), and without the
# terminator grep reads "-589" as its obsolete -NUM context option, then finds
# no file operand and silently searches STDIN instead — passing vacuously AND
# draining the outer runner's suite list. See the exec </dev/null note above.
assert_has() {
	grep -qF -- "$2" "$LOG" && ok "$1" || bad "$1" "missing [$2] in [$(tr '\n' '|' <"$LOG")]"
}
assert_lacks() {
	grep -qF -- "$2" "$LOG" && bad "$1" "found [$2] in [$(tr '\n' '|' <"$LOG")]" || ok "$1"
}
# Body-scoped variant. The titles legitimately carry 受入 / 離脱 wording that
# tracks the COUNT, so a whole-log grep cannot ask "is this word in the body".
assert_body_lacks() {
	local actual; actual="$(actual_body)"
	case "$actual" in
		*"$2"*) bad "$1" "found [$2] in body [$(printf '%s' "$actual" | tr '\n' '|')]" ;;
		*)      ok "$1" ;;
	esac
}

if [ "$GNU_DATE" -eq 0 ]; then
	skip "delegation notify body cases" "host date lacks -d and gdate is absent"
	echo
	echo "test-delegation-notify-body.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
	echo "RESULT: PASS"
	exit 0
fi

# ===========================================================================
echo "== increase branch (2 → 3 delegators) =="
build_sandbox inc 2
run_sandbox
INC_LOG="$(whole_of)"

grep -qF "TITLE<<Delegation +1 件受入 (合計 3 件)>>" "$LOG" \
	&& ok "increase: title unchanged" \
	|| bad "increase: title unchanged" "$(head -1 "$LOG")"

EXPECT_INC="$(printf '+1 件、合計 3 件\n新規 589\n%s / %s\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)' \
	"$EXPECT_RECEIVED" "$EXPECT_CAP" "$SELF_STAKE" "$EXPECT_WEIGHT")"
ACTUAL_INC="$(actual_body)"
if [ "$ACTUAL_INC" = "$EXPECT_INC" ]; then
	ok "increase: body is byte-exact"
else
	bad "increase: body is byte-exact" "expected [$EXPECT_INC] actual [$ACTUAL_INC]"
fi

printf '%s' "$INC_LOG" | grep -qF "${EXPECT_RECEIVED} / ${EXPECT_CAP}" \
	&& ok "increase: the slash has received over ceiling (same quantity family)" \
	|| bad "increase: the slash has received over ceiling"
printf '%s' "$INC_LOG" | grep -qF "自己 stake: ${SELF_STAKE} METAL / " \
	&& bad "increase: self stake is no longer paired across a slash" "old form is back" \
	|| ok "increase: self stake is no longer paired across a slash"
printf '%s' "$INC_LOG" | grep -qF "受入額:" \
	&& bad "increase: the stranded 受入額 line is gone" "still present" \
	|| ok "increase: the stranded 受入額 line is gone"
printf '%s' "$INC_LOG" | grep -qF "自己 stake: ${SELF_STAKE} METAL" \
	&& ok "increase: self stake survives as a standalone quantity" \
	|| bad "increase: self stake survives as a standalone quantity"
# The head-room is still correct arithmetic (daily-status.sh prints it); the
# push just no longer spends a line on a number the reader can subtract.
assert_lacks "increase: the head-room figure is absent from the push" "$EXPECT_REMAIN"

# ===========================================================================
echo
echo "== decrease branch (4 → 3 delegators) =="
BASELINE_TOTAL_NMETAL=11772797900000    # 11772.7979 → 589 METAL leaves
build_sandbox dec 4
run_sandbox
DEC_LOG="$(whole_of)"

grep -qF "TITLE<<Delegation -1 件離脱 (合計 3 件)>>" "$LOG" \
	&& ok "decrease: title unchanged" \
	|| bad "decrease: title unchanged" "$(head -1 "$LOG")"

EXPECT_DEC="$(printf -- '-1 件、合計 3 件\n離脱 589\n%s / %s\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)\n期間満了か途中解除、explorer で確認:\nhttps://explorer.metalblockchain.org/validators/%s' \
	"$EXPECT_RECEIVED" "$EXPECT_CAP" "$SELF_STAKE" "$EXPECT_WEIGHT" "$NODE_ID")"
ACTUAL_DEC="$(actual_body)"
if [ "$ACTUAL_DEC" = "$EXPECT_DEC" ]; then
	ok "decrease: body is byte-exact"
else
	bad "decrease: body is byte-exact" "expected [$EXPECT_DEC] actual [$ACTUAL_DEC]"
fi
printf '%s' "$DEC_LOG" | grep -qF "${EXPECT_RECEIVED} / ${EXPECT_CAP}" \
	&& ok "decrease: carries the same 受入 line as the increase branch" \
	|| bad "decrease: carries the same 受入 line as the increase branch"
printf '%s' "$DEC_LOG" | grep -qF "受入額:" \
	&& bad "decrease: the context-free 受入額 line is gone" "still present" \
	|| ok "decrease: the context-free 受入額 line is gone"
# Regression guard for the empty-body bug found 2026-08-06: the format string
# starts with '-', so without `printf --` bash reads it as an option, fails,
# and the push goes out as a bare title. Assert the body is non-empty at all,
# separately from the byte-exact case, because that is the property a future
# edit is most likely to break again.
[ -n "$ACTUAL_DEC" ] \
	&& ok "decrease: body is non-empty (leading-dash printf regression guard)" \
	|| bad "decrease: body is non-empty (leading-dash printf regression guard)" "empty body — is `printf --` still there?"

# ===========================================================================
echo
echo "== deliberate divergence from the canonical renderer (daily-status.sh) =="
# daily-status.sh owns the at-rest shape of this fact and keeps the full form
# including the head-room. The push shortens it (2026-08-10 operator mock).
# Assert BOTH literals so a future edit that "unifies" them trips here and has
# to re-read this comment first.
CANON='受入: ${RECEIVED_F} / ${CAP_METAL} METAL (残枠 ${REMAIN_METAL})'
grep -qF "$CANON" "${REPO}/scripts/daily-status.sh" \
	&& ok "daily-status.sh still renders the full 受入 shape with 残枠" \
	|| bad "daily-status.sh still renders the full 受入 shape with 残枠" "canon moved — re-derive the divergence note in check-anomalies.sh"
grep -qF 'DELEG_LINE="${OBS_DELEGATOR_TOTAL_METAL} / ${CAPACITY_METAL}"' "$SCRIPT" \
	&& ok "check-anomalies.sh renders the shortened push shape (bare ratio)" \
	|| bad "check-anomalies.sh renders the shortened push shape (bare ratio)"
grep -qF '(残枠 ${REMAIN_METAL})' "$SCRIPT" \
	&& bad "check-anomalies.sh no longer prints 残枠 in the push" "残枠 is back in the push body" \
	|| ok "check-anomalies.sh no longer prints 残枠 in the push"

# ===========================================================================
echo
echo "== over-cap / zero-stake degradation (no negative, no divide) =="
build_sandbox cap 2
# self stake below the received amount → head-room clamps to 0 → 満枠.
cat >"${S}/public/api/validator.json" <<JSON
{ "nodeId": "${NODE_ID}", "uptime": { "network": "99.0000" }, "stake": { "self": 1 } }
JSON
run_sandbox
CAP_LOG="$(whole_of)"
printf '%s' "$CAP_LOG" | grep -qF '🔒 満枠' \
	&& ok "over-cap: degrades to 満枠 instead of a negative head-room" \
	|| bad "over-cap: degrades to 満枠" "$(printf '%s' "$CAP_LOG" | sed -n '2p')"
printf '%s' "$CAP_LOG" | grep -qE '残枠 -' \
	&& bad "over-cap: never prints a negative 残枠" "negative rendered" \
	|| ok "over-cap: never prints a negative 残枠"

build_sandbox zero 2
cat >"${S}/public/api/validator.json" <<JSON
{ "nodeId": "${NODE_ID}", "uptime": { "network": "99.0000" }, "stake": { "self": 0 } }
JSON
run_sandbox
ZERO_LOG="$(whole_of)"
[ -n "$ZERO_LOG" ] \
	&& ok "zero self stake: still produces a notification (no arithmetic abort)" \
	|| bad "zero self stake: still produces a notification"
printf '%s' "$ZERO_LOG" | grep -qE 'nan|inf|Infinity|残枠 -' \
	&& bad "zero self stake: no nan/inf/negative in the body" "$(printf '%s' "$ZERO_LOG" | sed -n '2p')" \
	|| ok "zero self stake: no nan/inf/negative in the body"

# ===========================================================================
echo
echo "== mutation: restoring the old format must turn these assertions red =="
MUT="${TMP}/check-anomalies.mutated.sh"
sed \
	-e "s@^      body=\$(printf '+%s 件、合計 %s 件.*@      body=\$(printf '+%s 件、合計 %s 件\\\\n受入額: %s METAL\\\\n自己 stake: %s METAL / 受入枠 %s METAL\\\\n総 weight: %s METAL (self + delegators)' \"\$DIFF\" \"\$OBS_DELEGATOR_COUNT\" \"\$OBS_DELEGATOR_TOTAL_METAL\" \"\$SELF_STAKE\" \"\$CAPACITY_METAL\" \"\$TOTAL_WEIGHT_METAL\")@" \
	"$SCRIPT" >"$MUT"
if cmp -s "$MUT" "$SCRIPT"; then
	bad "mutation applied" "sed matched nothing — the mutation check would be a tautology"
else
	build_sandbox mut 2 "$MUT"
	run_sandbox
	MUT_LOG="$(whole_of)"
	printf '%s' "$MUT_LOG" | grep -qF "自己 stake: ${SELF_STAKE} METAL / 受入枠" \
		&& ok "mutation: the old cross-quantity slash reappears in the mutated build" \
		|| bad "mutation: the old cross-quantity slash reappears" "$(printf '%s' "$MUT_LOG" | tr '\n' '|' | head -c 300)"
	printf '%s' "$MUT_LOG" | grep -qF "新規 589" \
		&& bad "mutation: the 新規 line is absent from the old-format build" "still present" \
		|| ok "mutation: the 新規 line is absent from the old-format build"
fi

# Second mutation: drop the `--` terminator and the decrease body must go
# empty again, proving the regression guard above is not a tautology.
MUT2="${TMP}/check-anomalies.nodashdash.sh"
sed 's@body=\$(printf -- .-%s 件@body=$(printf '"'"'-%s 件@' "$SCRIPT" >"$MUT2"
if cmp -s "$MUT2" "$SCRIPT"; then
	bad "mutation applied: printf -- removed" "sed matched nothing"
else
	build_sandbox mut2 4 "$MUT2"
	run_sandbox
	MUT2_BODY="$(actual_body)"
	[ -z "$MUT2_BODY" ] \
		&& ok "mutation: removing printf -- empties the decrease body (guard is real)" \
		|| bad "mutation: removing printf -- empties the decrease body" "body was [$MUT2_BODY]"
fi

# ===========================================================================
# 2026-08-10: "how much moved this time"
# ===========================================================================
# From here the fixture switches to the operator's live shape: 8 delegators,
# self 21640 (→ ceiling 86560). Every case states its own baseline cumulative.
LIVE_RECEIVED_NMETAL=33768797900000     # 33768.7979 METAL
LIVE_RECEIVED="33768.7979"
LIVE_WEIGHT="55408.7979"                # 21640 + 33768.7979

echo
echo "== live numbers from the 2026-08-10 report (33179.7979 → 33768.7979) =="
write_rpc 8 "$LIVE_RECEIVED_NMETAL"
BASELINE_TOTAL_NMETAL=33179797900000
build_sandbox live 7
run_sandbox

assert_has "live: title unchanged" "TITLE<<Delegation +1 件受入 (合計 8 件)>>"
# This is the operator's mock, line for line.
EXPECT_LIVE="$(printf '+1 件、合計 8 件\n新規 589\n%s / %s\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)' \
	"$LIVE_RECEIVED" "$EXPECT_CAP" "$SELF_STAKE" "$LIVE_WEIGHT")"
assert_body "live: body matches the operator mock byte for byte" "$EXPECT_LIVE"
# Rounding rule 1: an exact-integer delta loses its %.4f tail.
assert_has   "live: integer delta drops trailing zeros (589, not 589.0000)" "新規 589"
assert_lacks "live: no 589.0000"                                            "589.0000"
# Requirement: the normal case must NOT carry the head-room.
assert_lacks "live: normal case omits 残枠"                                  "残枠"
assert_lacks "live: normal case omits the 満枠 marker"                       "満枠"
assert_lacks "live: the ratio line dropped its 受入 label"                   "受入:"

echo
echo "== the baseline advances: a second tick reports its own delta, not the sum =="
# The delta is only meaningful if the committed baseline moves with each
# delivered push. Same sandbox, second tick, log cleared in between.
if [ "$(jq -r '.delegator_total_nmetal' "${S}/state/anomaly-state.json")" = "$LIVE_RECEIVED_NMETAL" ]; then
	ok "tick 1 committed the new cumulative to state"
else
	bad "tick 1 committed the new cumulative to state" "state has $(jq -c '{delegator_count, delegator_total_nmetal}' "${S}/state/anomaly-state.json")"
fi
: >"$LOG"
write_rpc 9 34357797900000            # +589 again, on top of 33768.7979
run_sandbox
EXPECT_TICK2="$(printf '+1 件、合計 9 件\n新規 589\n34357.7979 / %s\n自己 stake: %s METAL\n総 weight: 55997.7979 METAL (self + delegators)' \
	"$EXPECT_CAP" "$SELF_STAKE")"
assert_body  "tick 2: 新規 is this tick's 589, not the 1178 since bootstrap" "$EXPECT_TICK2"
assert_lacks "tick 2: the delta did not accumulate" "新規 1178"

echo
echo "== 満枠: the ceiling reached (86560 / 86560) =="
write_rpc 8 86560000000000
BASELINE_TOTAL_NMETAL=85971000000000    # 85971 → +589
build_sandbox full 7
run_sandbox
EXPECT_FULL="$(printf '+1 件、合計 8 件\n新規 589\n%s / %s 🔒 満枠\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)' \
	"$EXPECT_CAP" "$EXPECT_CAP" "$SELF_STAKE" "108200")"
assert_body  "満枠: body is byte-exact (marker present, head-room still absent)" "$EXPECT_FULL"
assert_has   "満枠: the 🔒 marker is shown"       "86560 / 86560 🔒 満枠"
assert_lacks "満枠: still no 残枠"                "残枠"

# --- boundary 1: several delegations inside one tick -----------------------
echo
echo "== boundary 1: +2 件 in one tick — 新規 is the SUM, not one delegation =="
write_rpc 8 "$LIVE_RECEIVED_NMETAL"
BASELINE_TOTAL_NMETAL=32000000000000    # 32000 → +1768.7979 across TWO arrivals
build_sandbox multi 6
run_sandbox
assert_has "multi: title says +2 件" "TITLE<<Delegation +2 件受入 (合計 8 件)>>"
EXPECT_MULTI="$(printf '+2 件、合計 8 件\n新規 1768.7979\n%s / %s\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)' \
	"$LIVE_RECEIVED" "$EXPECT_CAP" "$SELF_STAKE" "$LIVE_WEIGHT")"
assert_body "multi: 新規 is the aggregate movement of the tick" "$EXPECT_MULTI"

# --- boundary 2: count and amount disagree ---------------------------------
echo
echo "== boundary 2a: count UP but amount DOWN (big one expired, small one arrived) =="
# DECISION (2026-08-10): the label follows the SIGN OF THE AMOUNT, not the
# direction of the count, so this renders 離脱 589 under a "+1 件" title. The
# alternative considered was suppressing the line entirely when the delta is
# ≤ 0; rejected because this is precisely the tick where the operator most
# needs the number, and hiding it recreates the reported defect. The brief
# forbids "新規 -589" — satisfied structurally: the magnitude is |v| by
# construction, so no minus sign can reach the body on any path.
write_rpc 8 "$LIVE_RECEIVED_NMETAL"
BASELINE_TOTAL_NMETAL=34357797900000    # 34357.7979 → net −589 despite +1 件
build_sandbox mixed 7
run_sandbox
EXPECT_MIXED="$(printf '+1 件、合計 8 件\n離脱 589\n%s / %s\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)' \
	"$LIVE_RECEIVED" "$EXPECT_CAP" "$SELF_STAKE" "$LIVE_WEIGHT")"
assert_body  "mixed: count up + amount down renders 離脱 with the net figure" "$EXPECT_MIXED"
assert_lacks      "mixed: never renders a signed 新規"        "新規 -"
assert_lacks      "mixed: no minus sign anywhere in the amount" "-589"
assert_body_lacks "mixed: does not claim 新規 on a net loss"    "新規"

echo
echo "== boundary 2b: count DOWN but amount UP (mirror case) =="
write_rpc 8 "$LIVE_RECEIVED_NMETAL"
BASELINE_TOTAL_NMETAL=33179797900000    # net +589 despite −1 件
build_sandbox mirror 9
run_sandbox
EXPECT_MIRROR="$(printf -- '-1 件、合計 8 件\n新規 589\n%s / %s\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)\n期間満了か途中解除、explorer で確認:\nhttps://explorer.metalblockchain.org/validators/%s' \
	"$LIVE_RECEIVED" "$EXPECT_CAP" "$SELF_STAKE" "$LIVE_WEIGHT" "$NODE_ID")"
assert_body  "mirror: count down + amount up renders 新規 on the decrease branch" "$EXPECT_MIRROR"
assert_body_lacks "mirror: does not claim 離脱 on a net gain" "離脱"
assert_lacks      "mirror: never renders a signed 離脱"       "離脱 -"

# --- boundary 3: no usable baseline ----------------------------------------
echo
echo "== boundary 3: bootstrap / unknown baseline =="
write_rpc 8 "$LIVE_RECEIVED_NMETAL"
BASELINE_TOTAL_NMETAL=null              # field present but never populated
build_sandbox nobase 7
run_sandbox
EXPECT_NOBASE="$(printf '+1 件、合計 8 件\n%s / %s\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)' \
	"$LIVE_RECEIVED" "$EXPECT_CAP" "$SELF_STAKE" "$LIVE_WEIGHT")"
assert_body  "nobase: null baseline drops the line entirely (no blank line, no fake delta)" "$EXPECT_NOBASE"
assert_lacks "nobase: does not present the cumulative as if it were new" "新規"
assert_lacks "nobase: and does not invent a departure"                   "離脱"

# A genuine first-ever delegation (baseline 0) is NOT the unknown case: the
# delta really does equal the cumulative, and both numbers are printed one
# above the other, so they agree instead of misleading.
write_rpc 8 "$LIVE_RECEIVED_NMETAL"
BASELINE_TOTAL_NMETAL=0
build_sandbox firstever 7
run_sandbox
EXPECT_FIRST="$(printf '+1 件、合計 8 件\n新規 %s\n%s / %s\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)' \
	"$LIVE_RECEIVED" "$LIVE_RECEIVED" "$EXPECT_CAP" "$SELF_STAKE" "$LIVE_WEIGHT")"
assert_body "firstever: a real 0 baseline reports the full amount as new" "$EXPECT_FIRST"

# The true bootstrap (delegator_count itself null) must stay silent — the
# paired transition seeds both fields without notifying.
write_rpc 8 "$LIVE_RECEIVED_NMETAL"
BASELINE_TOTAL_NMETAL=null
build_sandbox bootstrap null
run_sandbox
[ -z "$(whole_of)" ] \
	&& ok "bootstrap: null delegator_count still emits no notification at all" \
	|| bad "bootstrap: null delegator_count still emits no notification at all" "$(tr '\n' '|' <"$LOG")"

# --- boundary 4: rounding ---------------------------------------------------
echo
echo "== boundary 4: rounding follows the existing %.4f + strip-trailing-zeros rule =="
write_rpc 8 "$LIVE_RECEIVED_NMETAL"
BASELINE_TOTAL_NMETAL=33768000000000    # → +0.7979 exactly
build_sandbox frac 7
run_sandbox
EXPECT_FRAC="$(printf '+1 件、合計 8 件\n新規 0.7979\n%s / %s\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)' \
	"$LIVE_RECEIVED" "$EXPECT_CAP" "$SELF_STAKE" "$LIVE_WEIGHT")"
assert_body  "frac: sub-1 delta keeps 4 decimals and no padding" "$EXPECT_FRAC"
assert_lacks "frac: no 0.79790000"                               "0.79790000"

write_rpc 8 "$LIVE_RECEIVED_NMETAL"
BASELINE_TOTAL_NMETAL=33768797899999    # 1 nMETAL below → rounds to 0.0000
build_sandbox dust 7
run_sandbox
assert_body  "dust: a delta under the display precision drops the line" "$EXPECT_NOBASE"
assert_lacks "dust: never prints 新規 0"  "新規 0"
assert_lacks "dust: never prints 離脱 0"  "離脱 0"

# ===========================================================================
echo
echo "== mutations for the 2026-08-10 delta line =="

# M3: silence the delta line. The live case must lose 新規 589 while keeping
# everything else, proving the delta assertions are not passing by accident.
MUT3="${TMP}/check-anomalies.nodelta.sh"
sed 's@^        DELTA_BLOCK="${DELTA_DIR} ${DELTA_MAG}".*@        DELTA_BLOCK=""@' "$SCRIPT" >"$MUT3"
if cmp -s "$MUT3" "$SCRIPT"; then
	bad "mutation applied: delta line silenced" "sed matched nothing"
else
	write_rpc 8 "$LIVE_RECEIVED_NMETAL"
	BASELINE_TOTAL_NMETAL=33179797900000
	build_sandbox mut3 7 "$MUT3"
	run_sandbox
	assert_lacks "mutation: silencing DELTA_BLOCK removes 新規 589 (delta assertions are real)" "新規 589"
	assert_has   "mutation: the rest of the body survives the silencing"  "${LIVE_RECEIVED} / ${EXPECT_CAP}"
fi

# M4: put the head-room back. The live body must stop matching, proving the
# "no 残枠 in the push" requirement is actually enforced.
MUT4="${TMP}/check-anomalies.remain.sh"
sed 's@^      DELEG_LINE="${OBS_DELEGATOR_TOTAL_METAL} / ${CAPACITY_METAL}"$@      DELEG_LINE="${OBS_DELEGATOR_TOTAL_METAL} / ${CAPACITY_METAL} METAL (残枠 ${REMAIN_METAL})"@' "$SCRIPT" >"$MUT4"
if cmp -s "$MUT4" "$SCRIPT"; then
	bad "mutation applied: 残枠 restored" "sed matched nothing"
else
	write_rpc 8 "$LIVE_RECEIVED_NMETAL"
	BASELINE_TOTAL_NMETAL=33179797900000
	build_sandbox mut4 7 "$MUT4"
	run_sandbox
	assert_has "mutation: restoring the head-room makes 残枠 reappear" "残枠 52791.2021"
	[ "$(actual_body)" != "$EXPECT_LIVE" ] \
		&& ok "mutation: the operator-mock body no longer matches once 残枠 is back" \
		|| bad "mutation: the operator-mock body no longer matches once 残枠 is back" "still byte-equal"
fi

# M5: drop the absolute value. The count-up/amount-down case must then leak a
# minus sign, proving the |v| in the magnitude awk is load-bearing.
MUT5="${TMP}/check-anomalies.signed.sh"
sed 's@BEGIN{v=(a-b)/1e9; if(v<0)v=-v; printf@BEGIN{v=(a-b)/1e9; printf@' "$SCRIPT" >"$MUT5"
if cmp -s "$MUT5" "$SCRIPT"; then
	bad "mutation applied: abs removed" "sed matched nothing"
else
	write_rpc 8 "$LIVE_RECEIVED_NMETAL"
	BASELINE_TOTAL_NMETAL=34357797900000
	build_sandbox mut5 7 "$MUT5"
	run_sandbox
	assert_has "mutation: removing |v| leaks a negative amount (the abs is load-bearing)" "離脱 -589"
	# Same needle the "mixed" case rules out, asserted positively here. If the
	# grep helper ever loses its `--` again this flips red instead of every
	# leading-dash assertion in the file quietly passing on empty stdin.
	assert_has "mutation: the bare -589 needle really matches (grep -- guard is live)" "-589"
fi

echo
echo "test-delegation-notify-body.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
printf '\nFailures:\n'
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
echo "RESULT: FAIL"
exit 1
