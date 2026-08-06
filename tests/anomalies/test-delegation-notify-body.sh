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
#   context at all. Both now render the same 受入 line that
#   scripts/daily-status.sh has always rendered.
#
#   The failure was one of MEANING, not of mechanism, so the assertions here
#   are on the exact bytes of the delivered body, not on "a notify happened".
#
# METHOD
#   The real script is driven end to end inside a sandbox repo: a curl stand-in
#   answers platform.getCurrentValidators with a canned delegator set, and
#   scripts/notify.sh is a recording shim, so what is asserted is the body the
#   operator would actually have received. The fixture numbers are the ones
#   from the 2026-08-06 live push (self 21640, received 11183.7979, 3
#   delegators) so the expected strings can be read against that push directly.
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

# --- fixture values, taken from the 2026-08-06 live push -------------------
SELF_STAKE=21640                      # METAL
TOTAL_NMETAL=11183797900000           # = 11183.7979 METAL
NODE_ID="NodeID-sandboxdelegationtest"
EXPECT_RECEIVED="11183.7979"
EXPECT_CAP="86560"                    # 21640 * 4
EXPECT_REMAIN="75376.2021"            # 86560 - 11183.7979
EXPECT_WEIGHT="32823.7979"            # 21640 + 11183.7979

cat >"$RPC_JSON" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"validators":[{
  "nodeID":"${NODE_ID}",
  "endTime":"4102444800",
  "delegatorCount":"3",
  "delegatorWeight":"${TOTAL_NMETAL}",
  "delegators":[
    {"txID":"tx-aaa","weight":"3727932633333","endTime":"4102444800"},
    {"txID":"tx-bbb","weight":"3727932633333","endTime":"4102444800"},
    {"txID":"tx-ccc","weight":"3727932633334","endTime":"4102444800"}
  ]
}]}}
JSON

# build_sandbox <name> <baseline delegator_count> [script-override]
#   Returns the sandbox path in $S and the recording log path in $LOG.
build_sandbox() {
	local name="$1" baseline_count="$2" script_src="${3:-$SCRIPT}"
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
  "delegator_count": ${baseline_count}, "delegator_total_nmetal": 1,
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

EXPECT_INC="$(printf '+1 件、合計 3 件\n受入: %s / %s METAL (残枠 %s)\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)' \
	"$EXPECT_RECEIVED" "$EXPECT_CAP" "$EXPECT_REMAIN" "$SELF_STAKE" "$EXPECT_WEIGHT")"
ACTUAL_INC="$(sed -n '/^BODY<</,$p' "$LOG" | sed '1s/^BODY<<//' | sed '$s/>>$//')"
if [ "$ACTUAL_INC" = "$EXPECT_INC" ]; then
	ok "increase: body is byte-exact"
else
	bad "increase: body is byte-exact" "expected [$EXPECT_INC] actual [$ACTUAL_INC]"
fi

printf '%s' "$INC_LOG" | grep -qF "受入: ${EXPECT_RECEIVED} / ${EXPECT_CAP} METAL" \
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

# ===========================================================================
echo
echo "== decrease branch (4 → 3 delegators) =="
build_sandbox dec 4
run_sandbox
DEC_LOG="$(whole_of)"

grep -qF "TITLE<<Delegation -1 件離脱 (合計 3 件)>>" "$LOG" \
	&& ok "decrease: title unchanged" \
	|| bad "decrease: title unchanged" "$(head -1 "$LOG")"

EXPECT_DEC="$(printf -- '-1 件、合計 3 件\n受入: %s / %s METAL (残枠 %s)\n自己 stake: %s METAL\n総 weight: %s METAL (self + delegators)\n期間満了か途中解除、explorer で確認:\nhttps://explorer.metalblockchain.org/validators/%s' \
	"$EXPECT_RECEIVED" "$EXPECT_CAP" "$EXPECT_REMAIN" "$SELF_STAKE" "$EXPECT_WEIGHT" "$NODE_ID")"
ACTUAL_DEC="$(sed -n '/^BODY<</,$p' "$LOG" | sed '1s/^BODY<<//' | sed '$s/>>$//')"
if [ "$ACTUAL_DEC" = "$EXPECT_DEC" ]; then
	ok "decrease: body is byte-exact"
else
	bad "decrease: body is byte-exact" "expected [$EXPECT_DEC] actual [$ACTUAL_DEC]"
fi
printf '%s' "$DEC_LOG" | grep -qF "受入: ${EXPECT_RECEIVED} / ${EXPECT_CAP} METAL" \
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
echo "== format parity with the canonical renderer (daily-status.sh) =="
# daily-status.sh owns the canonical shape of this fact. Assert the literal
# both files must share, so a change to one without the other is caught.
CANON='受入: ${RECEIVED_F} / ${CAP_METAL} METAL (残枠 ${REMAIN_METAL})'
grep -qF "$CANON" "${REPO}/scripts/daily-status.sh" \
	&& ok "daily-status.sh still renders the canonical 受入 shape" \
	|| bad "daily-status.sh still renders the canonical 受入 shape" "canon moved — re-derive check-anomalies.sh from it"
grep -qF '受入: ${OBS_DELEGATOR_TOTAL_METAL} / ${CAPACITY_METAL} METAL (残枠 ${REMAIN_METAL})' "$SCRIPT" \
	&& ok "check-anomalies.sh renders the same shape" \
	|| bad "check-anomalies.sh renders the same shape"

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
	printf '%s' "$MUT_LOG" | grep -qF "受入: ${EXPECT_RECEIVED} / ${EXPECT_CAP} METAL" \
		&& bad "mutation: the corrected 受入 line is absent from the mutated build" "still present" \
		|| ok "mutation: the corrected 受入 line is absent from the mutated build"
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
	MUT2_BODY="$(sed -n '/^BODY<</,$p' "$LOG" | sed '1s/^BODY<<//' | sed '$s/>>$//')"
	[ -z "$MUT2_BODY" ] \
		&& ok "mutation: removing printf -- empties the decrease body (guard is real)" \
		|| bad "mutation: removing printf -- empties the decrease body" "body was [$MUT2_BODY]"
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
