#!/usr/bin/env bash
# tests/anomalies/test-web-incident.sh
#
# Public-site probe: path classification, persistence gate, diagnostics and
# the optional web_incident state field — spec
# docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# §5 cases 1-8 (case 9 lives in tests/install-anomalies-web-origin-env/).
#
# Strategy: runs the REAL scripts/check-anomalies.sh end to end, several
# times against one sandbox state file, the way cron does — the same shape
# as tests/anomalies/test-delegation-notify-body.sh. The properties under
# test span runs ("no push on run 1, one push on run 2, none on run 3"), so
# they can only be observed across real candidate-state commits; a
# sed-extracted block would have to re-implement the commit it is meant to
# test. The real K-3.5 schema check, notify_or_keep retry path and commit
# are exercised, not stubbed.
#
# PATH stand-ins (test-local; nothing on this machine is modified):
#   curl     /health: P_cf answers from a per-sandbox queue (one code per
#            call, the last one repeats); P_direct (recognised by --resolve)
#            answers a fixed code. /api/validator.json answers a fresh
#            observedAt. The P-chain RPC fails, so the validator/period
#            transitions are skipped (as in the delegation suite).
#   sleep    no-op, logged (the 30 s re-probe and notify's 5 s retry)
#   timeout  logged, then runs the rest of its argv
#   mtr      logged, prints one line
#   flock    no-op where util-linux is absent (macOS)
#   date     GNU date (gdate on macOS); the suite SKIPs when neither exists
# The sandbox's scripts/notify.sh records prio / title / body per call and
# exits with the code in notify.rc.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast, no
# network: every curl is the stub).

set -uo pipefail
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO}/scripts/check-anomalies.sh"

PASS=0
FAIL=0
FAILURES=()
assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$label"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected='$expected', actual='$actual')")
		printf '  FAIL  %s expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual"
	fi
}
assert_has() {   # <label> <fixed string> <text>
	if grep -qF -- "$2" <<<"$3"; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$1"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$1 (missing '$2')")
		printf '  FAIL  %s — missing [%s]\n' "$1" "$2"
	fi
}
assert_not_has() {   # <label> <fixed string> <text>  — I1: no origin-IP leak
	if grep -qF -- "$2" <<<"$3"; then
		FAIL=$((FAIL + 1))
		FAILURES+=("$1 (unexpectedly contains '$2')")
		printf '  FAIL  %s — unexpectedly contains [%s]\n' "$1" "$2"
	else
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$1"
	fi
}
assert_re() {    # <label> <ERE> <text>
	if grep -qE -- "$2" <<<"$3"; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$1"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$1 (no line matches /$2/)")
		printf '  FAIL  %s — no line matches /%s/\n' "$1" "$2"
	fi
}

TMP="$(mktemp -d -t fy-web-incident.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
BIN="${TMP}/bin"
mkdir -p "$BIN"

if date -u -d '@0' +%s >/dev/null 2>&1; then
	:
elif command -v gdate >/dev/null 2>&1; then
	printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(command -v gdate)" >"${BIN}/date"
else
	echo "SKIP: test-web-incident.sh requires GNU date (Linux 'date' or macOS 'gdate' via Homebrew coreutils)"
	exit 0
fi
if ! command -v flock >/dev/null 2>&1; then
	printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN}/flock"
fi
cat >"${BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$STUB_LOG"
exit 0
EOF
cat >"${BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >>"$STUB_LOG"
shift
exec "$@"
EOF
cat >"${BIN}/mtr" <<'EOF'
#!/usr/bin/env bash
printf 'mtr %s\n' "$*" >>"$STUB_LOG"
echo 'HOST: stub   Loss%   Snt   Last   Avg  Best  Wrst StDev'
EOF
cat >"${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
url=""; out=""; hdr=""; resolve=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) hdr="$2"; shift 2 ;;
		--resolve) resolve="$2"; shift 2 ;;
		-w | --max-time | -X | -H | --data) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
printf 'curl url=%s resolve=%s\n' "$url" "${resolve:-none}" >>"$STUB_LOG"
case "$url" in
	*/ext/bc/P) exit 7 ;;
	*/api/validator.json)
		printf '{"observedAt":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$out"
		printf '200'
		exit 0
		;;
	*/health)
		if [ -n "$resolve" ]; then
			code=$(cat "$DIRECT_CODE_FILE")
		else
			code=$(head -1 "$CF_QUEUE")
			if [ "$(wc -l <"$CF_QUEUE" | tr -d ' ')" -gt 1 ]; then
				tail -n +2 "$CF_QUEUE" >"${CF_QUEUE}.next" && mv "${CF_QUEUE}.next" "$CF_QUEUE"
			fi
			if [ -n "$hdr" ] && [ "$code" != "000" ]; then
				printf 'HTTP/2 %s\r\ncf-ray: 8c1f00dd1a2b3c4d-SIN\r\n\r\n' "$code" >"$hdr"
			fi
		fi
		if [ "$code" = "000" ]; then
			echo 'curl: (28) Operation timed out after 10001 milliseconds' >&2
			printf 'http_code=000 t_dns=0.004 t_connect=0.000 t_tls=0.000 t_ttfb=0.000 t_total=10.001 remote_ip='
			exit 28
		fi
		printf 'http_code=%s t_dns=0.004 t_connect=0.012 t_tls=0.030 t_ttfb=0.050 t_total=0.051 remote_ip=192.0.2.10' "$code"
		exit 0
		;;
esac
exit 7
EOF
chmod +x "${BIN}"/*

# new_sandbox <name> [web] — fresh repo copy + baseline state (web ok, no
# web_incident). Sets S and the per-sandbox stub control files.
new_sandbox() {
	S="${TMP}/$1"
	local web="${2:-ok}"
	rm -rf "$S"
	mkdir -p "${S}/scripts/lib" "${S}/public/api" "${S}/state/locks" "${S}/notify"
	cp "$SCRIPT" "${S}/scripts/check-anomalies.sh"
	cp -R "${REPO}/scripts/lib/." "${S}/scripts/lib/"
	cat >"${S}/scripts/notify.sh" <<'SHIM'
#!/usr/bin/env bash
n=$(( $(cat "${NOTIFY_DIR}/count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" >"${NOTIFY_DIR}/count"
printf '%s|%s|%s\n' "$n" "$1" "$2" >>"${NOTIFY_DIR}/index"
printf '%s' "$3" >"${NOTIFY_DIR}/body.${n}"
exit "$(cat "$NOTIFY_RC_FILE" 2>/dev/null || echo 0)"
SHIM
	chmod +x "${S}/scripts/notify.sh"
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
	printf '{ "nodeId": "NodeID-sandbox", "uptime": { "network": "99.0000" }, "stake": { "self": 12600 } }\n' \
		>"${S}/public/api/validator.json"
	cat >"${S}/state/anomaly-state.json" <<JSON
{
  "metalgo": "running", "caddy": "running", "disk": "ok", "memory": "ok",
  "peers": "ok", "web": "${web}", "api_freshness": "ok",
  "validator_present": "yes", "last_known_end_time": null,
  "delegator_count": null, "delegator_total_nmetal": null,
  "period_alert_sent": { "7": false, "1": false, "0": false, "10min": false }
}
JSON
	STATE="${S}/state/anomaly-state.json"
	STUB_LOG="${S}/stub.log"
	CF_QUEUE="${S}/cf.queue"
	DIRECT_CODE_FILE="${S}/direct.code"
	NOTIFY_RC_FILE="${S}/notify.rc"
	NOTIFY_DIR="${S}/notify"
	DIAG_LOG="${S}/state/anomalies-web-diag.log"
	BLIP_LOG="${S}/state/anomalies-web-blips.log"
	echo 200 >"$CF_QUEUE"
	echo 200 >"$DIRECT_CODE_FILE"
	echo 0 >"$NOTIFY_RC_FILE"
	: >"$STUB_LOG"
}

# run_check [VAR=value ...] — one cron tick. Later assignments override the
# defaults (env applies them left to right). Returns the script's rc.
run_check() {
	: >"$STUB_LOG"
	rm -f "${NOTIFY_DIR}/index" "${NOTIFY_DIR}/count" "${NOTIFY_DIR}"/body.*
	env PATH="${BIN}:${PATH}" FY_LIVE=1 NTFY_TAGS= \
		NOTIFY= FYD_NOTIFY= ANCHOR_NOTIFY= WATCH_NOTIFY= FY_STATE_DIR= \
		ANOMALY_STATE_DIR="${S}/state" METALGO_API="http://127.0.0.1:1" \
		WEB_URL="https://example.invalid" WEB_ORIGIN_IP="${WEB_ORIGIN_IP_VALUE:-192.0.2.10}" \
		WEB_DIAG_LOG= WEB_BLIP_LOG= FRESH_REPROBE_SLEEP=0 \
		STUB_LOG="$STUB_LOG" CF_QUEUE="$CF_QUEUE" DIRECT_CODE_FILE="$DIRECT_CODE_FILE" \
		NOTIFY_RC_FILE="$NOTIFY_RC_FILE" NOTIFY_DIR="$NOTIFY_DIR" \
		"$@" bash "${S}/scripts/check-anomalies.sh" >"${S}/run.out" 2>"${S}/run.err"
}

set_cf()        { printf '%s\n' "$@" >"$CF_QUEUE"; }
set_direct()    { echo "$1" >"$DIRECT_CODE_FILE"; }
set_notify_rc() { echo "$1" >"$NOTIFY_RC_FILE"; }
st()            { jq -c "$1" "$STATE"; }
backdate()      { jq ".web_incident.started_at -= $1" "$STATE" >"${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"; }
count_in()      { [ -f "$2" ] || { echo 0; return; }; grep -c -- "$1" "$2" || true; }
pushes()        { count_in '|' "${NOTIFY_DIR}/index"; }
push_prio()     { sed -n "${1}p" "${NOTIFY_DIR}/index" | cut -d'|' -f2; }
push_title()    { sed -n "${1}p" "${NOTIFY_DIR}/index" | cut -d'|' -f3-; }
push_body()     { cat "${NOTIFY_DIR}/body.${1}" 2>/dev/null; }
cf_probes()     { count_in 'url=https://example.invalid/health resolve=none' "$STUB_LOG"; }
direct_probes() { count_in 'resolve=example.invalid:443:192.0.2.10' "$STUB_LOG"; }
sleeps()        { count_in '^sleep ' "$STUB_LOG"; }
mtr_calls()     { count_in '^mtr ' "$STUB_LOG"; }
diag_blocks()   { count_in '^=== web-diag ' "$DIAG_LOG"; }
blip_lines()    { count_in 'duration_s=' "$BLIP_LOG"; }

OUTAGE_TITLE='公開サイトが応答しない (5 分以上継続)'
CF_TITLE='公開サイト: Cloudflare 経路で失敗継続 (origin は正常)'
RECOVERY_TITLE='公開サイト復旧'
# I1: the fixed WEB_ORIGIN_IP run_check() sets below — no push body, in any
# class (cf_path / origin_or_path / unknown / recovery), may ever contain it.
WEB_ORIGIN_IP_VALUE='192.0.2.10'

echo "=== healthy steady state: one request, nothing else ==="
new_sandbox steady
set_cf 200
run_check; rc=$?
assert_eq "steady: rc=0" 0 "$rc"
assert_eq "steady: exactly one P_cf request" 1 "$(cf_probes)"
assert_eq "steady: no P_direct" 0 "$(direct_probes)"
assert_eq "steady: no sleep" 0 "$(sleeps)"
assert_eq "steady: no mtr" 0 "$(mtr_calls)"
assert_eq "steady: no push" 0 "$(pushes)"
assert_eq "steady: web_incident absent" null "$(st '.web_incident')"
assert_eq "steady: no diagnostics file" no "$([ -e "$DIAG_LOG" ] && echo yes || echo no)"

echo "=== case 1: blip that recovers inside the 30 s re-probe ==="
new_sandbox c1
set_cf 000 200
run_check; rc=$?
assert_eq "c1: rc=0" 0 "$rc"
assert_eq "c1: re-probed (2 P_cf)" 2 "$(cf_probes)"
assert_eq "c1: re-probe slept WEB_REPROBE_SLEEP default 30" 1 "$(count_in '^sleep 30$' "$STUB_LOG")"
assert_eq "c1: no P_direct" 0 "$(direct_probes)"
assert_eq "c1: no push" 0 "$(pushes)"
assert_eq "c1: no incident" null "$(st '.web_incident')"
assert_eq "c1: .web stays ok" '"ok"' "$(st '.web')"
assert_eq "c1: no diagnostics block" 0 "$(diag_blocks)"

echo "=== case 2: fails the re-probe, recovers next run → no push, one blip line ==="
new_sandbox c2
set_cf 000 000; set_direct 200
run_check; rc=$?
assert_eq "c2 run1: rc=0" 0 "$rc"
assert_eq "c2 run1: no push" 0 "$(pushes)"
assert_eq "c2 run1: incident opened" '{"runs":1,"pushed":false,"last_class":"cf_path","classes":["cf_path"]}' \
	"$(st '.web_incident | {runs, pushed, last_class, classes}')"
assert_eq "c2 run1: started_at is an epoch" number "$(jq -r '.web_incident.started_at | type' "$STATE")"
assert_eq "c2 run1: one diagnostics block" 1 "$(diag_blocks)"
assert_re "c2 run1: diag header names the class" '^=== web-diag [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z class=cf_path ===$' "$(cat "$DIAG_LOG")"
set_cf 200
run_check; rc=$?
assert_eq "c2 run2: rc=0" 0 "$rc"
assert_eq "c2 run2: no push" 0 "$(pushes)"
assert_eq "c2 run2: incident cleared" null "$(st '.web_incident')"
assert_eq "c2 run2: .web ok" '"ok"' "$(st '.web')"
assert_eq "c2 run2: one blip line" 1 "$(blip_lines)"
assert_re "c2 run2: blip line shape, pushed=false" \
	'^[0-9T:-]+Z [0-9T:-]+Z duration_s=[0-9]+ classes=cf_path pushed=false$' "$(cat "$BLIP_LOG")"

echo "=== case 3: origin_or_path persists → one high push on run 2, none on run 3 ==="
new_sandbox c3
set_cf 000 000; set_direct 000
run_check
assert_eq "c3 run1: no push" 0 "$(pushes)"
set_cf 000
run_check; rc=$?
assert_eq "c3 run2: rc=0" 0 "$rc"
assert_eq "c3 run2: no re-probe while an incident is open (1 P_cf)" 1 "$(cf_probes)"
assert_eq "c3 run2: exactly one push" 1 "$(pushes)"
assert_eq "c3 run2: priority high" high "$(push_prio 1)"
assert_eq "c3 run2: outage title" "$OUTAGE_TITLE" "$(push_title 1)"
B="$(push_body 1)"
assert_has "c3 run2: body names the class" '分類: origin 停止 または シンガポール経路 (未判別)' "$B"
assert_has "c3 run2: body carries the duration" '継続: 約 ' "$B"
assert_has "c3 run2: body quotes the P_cf timing" 'Cloudflare 経由: http_code=000' "$B"
assert_has "c3 run2: body quotes the P_direct timing" 'origin 直接: http_code=000' "$B"
assert_has "c3 run2: body points at the diagnostics file" "診断: ${DIAG_LOG}" "$B"
assert_not_has "c3 run2 (I1): body carries no origin IP (origin_or_path)" "$WEB_ORIGIN_IP_VALUE" "$B"
assert_eq "c3 run2: .web=warn" '"warn"' "$(st '.web')"
assert_eq "c3 run2: pushed=true runs=2" '{"pushed":true,"runs":2}' "$(st '.web_incident | {pushed, runs}')"
run_check; rc=$?
assert_eq "c3 run3: rc=0" 0 "$rc"
assert_eq "c3 run3: no further push" 0 "$(pushes)"
assert_eq "c3 run3: runs=3" 3 "$(st '.web_incident.runs')"

echo "=== case 5: recovery after a push → default push with duration + classes ==="
backdate 570
set_cf 200
run_check; rc=$?
assert_eq "c5: rc=0" 0 "$rc"
assert_eq "c5: exactly one push" 1 "$(pushes)"
assert_eq "c5: priority default" default "$(push_prio 1)"
assert_eq "c5: recovery title" "$RECOVERY_TITLE" "$(push_title 1)"
B="$(push_body 1)"
assert_has "c5: body carries the duration as an observation bound" '継続: 約 10 分 (5 分刻みの観測)' "$B"
assert_has "c5: body carries the classes seen" '観測した分類: origin 停止 または シンガポール経路 (未判別)' "$B"
assert_not_has "c5 (I1): body carries no origin IP (recovery)" "$WEB_ORIGIN_IP_VALUE" "$B"
assert_eq "c5: .web back to ok" '"ok"' "$(st '.web')"
assert_eq "c5: incident cleared" null "$(st '.web_incident')"
assert_eq "c5: one blip line" 1 "$(blip_lines)"
assert_re "c5: blip line pushed=true" 'duration_s=(57[0-9]|58[0-9]|59[0-9]|600) classes=origin_or_path pushed=true$' "$(cat "$BLIP_LOG")"

echo "=== case 4: cf_path persists → default push with the Cloudflare title ==="
new_sandbox c4
set_cf 522 522; set_direct 200
run_check
set_cf 522
run_check; rc=$?
assert_eq "c4 run2: rc=0" 0 "$rc"
assert_eq "c4 run2: exactly one push" 1 "$(pushes)"
assert_eq "c4 run2: priority default" default "$(push_prio 1)"
assert_eq "c4 run2: Cloudflare title" "$CF_TITLE" "$(push_title 1)"
B="$(push_body 1)"
assert_has "c4 run2: body names the class" '分類: Cloudflare 経路 (origin は正常)' "$B"
assert_has "c4 run2: body carries the cf-ray colo" 'cf-ray colo: SIN' "$B"
assert_not_has "c4 run2 (I1): body carries no origin IP (cf_path)" "$WEB_ORIGIN_IP_VALUE" "$B"
assert_eq "c4 run2: .web=warn" '"warn"' "$(st '.web')"

echo "=== case 6: outage push fails → pushed stays false, next run pushes ==="
new_sandbox c6
set_cf 000 000; set_direct 000
run_check
set_cf 000; set_notify_rc 2
run_check; rc=$?
assert_eq "c6 run2: rc=6 (notify permanently failed)" 6 "$rc"
assert_eq "c6 run2: two attempts (rc 2 is retried once)" 2 "$(pushes)"
assert_eq "c6 run2: pushed stays false" false "$(st '.web_incident.pushed')"
assert_eq "c6 run2: .web stays ok" '"ok"' "$(st '.web')"
assert_eq "c6 run2: runs still advances (observation)" 2 "$(st '.web_incident.runs')"
set_notify_rc 0
run_check; rc=$?
assert_eq "c6 run3: rc=0" 0 "$rc"
assert_eq "c6 run3: the push goes out" 1 "$(pushes)"
assert_eq "c6 run3: outage title" "$OUTAGE_TITLE" "$(push_title 1)"
assert_eq "c6 run3: pushed=true" true "$(st '.web_incident.pushed')"
assert_eq "c6 run3: .web=warn" '"warn"' "$(st '.web')"

echo "=== case 6b (I2): recovery push fails → .web/web_incident held, next run recovers ==="
new_sandbox c6b
set_cf 000 000; set_direct 000
run_check
set_cf 000
run_check
assert_eq "c6b setup: outage push delivered, .web=warn" '"warn"' "$(st '.web')"
assert_eq "c6b setup: web_incident pushed=true" true "$(st '.web_incident.pushed')"
set_cf 200; set_notify_rc 2
run_check; rc=$?
assert_eq "c6b run3: rc=6 (recovery notify permanently failed)" 6 "$rc"
assert_eq "c6b run3: two attempts (rc 2 is retried once)" 2 "$(pushes)"
assert_eq "c6b run3: .web stays warn (K-3: no commit on a failed push)" '"warn"' "$(st '.web')"
assert_eq "c6b run3: web_incident is kept (not cleared)" no "$([ "$(st '.web_incident')" = null ] && echo yes || echo no)"
assert_eq "c6b run3: 0 blip lines (recovery not yet delivered)" 0 "$(blip_lines)"
set_notify_rc 0
run_check; rc=$?
assert_eq "c6b run4: rc=0" 0 "$rc"
assert_eq "c6b run4: exactly one recovery push" 1 "$(pushes)"
assert_eq "c6b run4: recovery title" "$RECOVERY_TITLE" "$(push_title 1)"
assert_eq "c6b run4: exactly one blip line" 1 "$(blip_lines)"
assert_eq "c6b run4: .web=ok" '"ok"' "$(st '.web')"
assert_eq "c6b run4: incident cleared" null "$(st '.web_incident')"

echo "=== case 7: WEB_ORIGIN_IP unset → P_direct skipped, class unknown, high push ==="
new_sandbox c7
set_cf 000 000
run_check WEB_ORIGIN_IP=
assert_eq "c7 run1: no P_direct request" 0 "$(count_in 'resolve=[^n]' "$STUB_LOG")"
assert_eq "c7 run1: no mtr (nothing to trace)" 0 "$(mtr_calls)"
assert_eq "c7 run1: class unknown" '"unknown"' "$(st '.web_incident.last_class')"
assert_has "c7 run1: diagnostics say P_direct was skipped" '[direct] skipped' "$(cat "$DIAG_LOG")"
set_cf 000
run_check WEB_ORIGIN_IP=; rc=$?
assert_eq "c7 run2: rc=0" 0 "$rc"
assert_eq "c7 run2: priority high" high "$(push_prio 1)"
assert_eq "c7 run2: outage title" "$OUTAGE_TITLE" "$(push_title 1)"
B="$(push_body 1)"
assert_has "c7 run2: body names the class" '分類: 判別不能 (origin 直接確認なし)' "$B"
assert_not_has "c7 run2 (I1): body carries no origin IP (unknown)" "$WEB_ORIGIN_IP_VALUE" "$B"

echo "=== case 7b: a malformed WEB_ORIGIN_IP is refused, not used ==="
new_sandbox c7b
set_cf 000 000
run_check WEB_ORIGIN_IP='192.0.2.10;x'
assert_eq "c7b: no P_direct request" 0 "$(count_in 'resolve=[^n]' "$STUB_LOG")"
assert_eq "c7b: class unknown" '"unknown"' "$(st '.web_incident.last_class')"
assert_has "c7b: refusal is logged" 'not a dotted-quad IPv4 address' "$(cat "${S}/run.err")"

echo "=== class change within one incident ==="
new_sandbox cx
set_cf 000 000; set_direct 200
run_check
set_cf 000; set_direct 000
run_check
assert_eq "cx run2: push by the LATEST class (high)" high "$(push_prio 1)"
assert_eq "cx run2: classes keep the history" '["cf_path","origin_or_path"]' "$(st '.web_incident.classes')"
assert_eq "cx run2: last_class is the latest" '"origin_or_path"' "$(st '.web_incident.last_class')"

echo "=== diagnostics block content ==="
new_sandbox diag
set_cf 522 000; set_direct 000
run_check
D="$(cat "$DIAG_LOG")"
assert_re "diag: P_cf #1 timing line" '^\[cf#1\] http_code=522 .* curl_rc=0$' "$D"
assert_re "diag: P_cf #1 headers kept (cf-ray)" '^  cf-ray: 8c1f00dd1a2b3c4d-SIN$' "$D"
assert_re "diag: P_cf #2 timing line" '^\[cf#2\] http_code=000 .* curl_rc=28$' "$D"
assert_re "diag: P_cf #2 curl error kept" '^  curl: \(28\) Operation timed out' "$D"
assert_re "diag: P_direct timing line" '^\[direct\] http_code=000 ' "$D"
assert_re "diag: mtr section" '^\[mtr\]$' "$D"
assert_eq "diag: mtr ran under timeout 25 with the spec's flags" 1 \
	"$(count_in '^timeout 25 mtr -r -n -c 5 -w 192.0.2.10$' "$STUB_LOG")"
assert_eq "diag: log written beside the sandbox state, not /var/log" yes \
	"$([ -s "${S}/state/anomalies-web-diag.log" ] && echo yes || echo no)"

echo "=== legacy state: .web=warn without web_incident ==="
new_sandbox legacy warn
set_cf 000
run_check; rc=$?
assert_eq "legacy fail: rc=0" 0 "$rc"
assert_eq "legacy fail: no re-probe" 1 "$(cf_probes)"
assert_eq "legacy fail: no second outage push" 0 "$(pushes)"
assert_eq "legacy fail: state not converted" null "$(st '.web_incident')"
set_cf 200
run_check
assert_eq "legacy recover: one push" 1 "$(pushes)"
assert_eq "legacy recover: recovery title" "$RECOVERY_TITLE" "$(push_title 1)"
assert_has "legacy recover: duration honestly unknown" '継続: 不明' "$(push_body 1)"
assert_eq "legacy recover: .web ok" '"ok"' "$(st '.web')"
assert_eq "legacy recover: no blip line (start unknown)" 0 "$(blip_lines)"

echo "=== case 8: K-3.5 schema — web_incident optional, validated when present ==="
new_sandbox s_absent
run_check; rc=$?
assert_eq "schema: absent web_incident passes (rc=0)" 0 "$rc"
new_sandbox s_null
jq '.web_incident = null' "$STATE" >"${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
run_check; rc=$?
assert_eq "schema: null web_incident passes (rc=0)" 0 "$rc"
for bad in \
	'{"started_at":"x","last_class":"cf_path","classes":["cf_path"],"runs":1,"pushed":false}' \
	'{"started_at":1,"last_class":"bogus","classes":["cf_path"],"runs":1,"pushed":false}' \
	'{"started_at":1,"last_class":"cf_path","classes":[1],"runs":1,"pushed":false}' \
	'{"started_at":1,"last_class":"cf_path","classes":["cf_path"],"runs":1,"pushed":"no"}' \
	'false'; do
	new_sandbox s_bad
	jq --argjson wi "$bad" '.web_incident = $wi' "$STATE" >"${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
	run_check; rc=$?
	assert_eq "schema: malformed web_incident $bad → exit 4" 4 "$rc"
	assert_eq "schema: …and is quarantined" 1 "$(find "${S}/state/quarantine" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
done

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
