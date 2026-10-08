#!/usr/bin/env bash
# tests/daily-status/test-uptime-expected.sh — the daily status push shows the
# status page's 予定 (expected) uptime and the difference next to the observed
# uptime, with the SAME definition as the page (案C, approved 2026-10-03/10-08).
#
# CHAIN: none. PRIME_DIRECTIVE: safe — node/python evaluation of committed
# files plus daily-status.sh in a throwaway sandbox whose curl is a stub; no
# network, no broadcast, no SSH, no real notification.
#
# One definition, two implementations, one fixture:
#   public/status/status-calc.js   (page, node)   ─┐
#   scripts/uptime-expected.py     (push, python) ─┴─ tests/fixtures/uptime-expected-vectors.json
#
# Pins:
#   U1  every page-side vector: status-calc.js uptimeView → expected.toFixed(2),
#       signed(diff), drop (actual < expected - LIMITS.uptimeSlackPts) == want
#   U2  every vector: uptime-expected.py --json == want, suffix == fixture
#       (normal / with known outage / 0.49 vs 0.51 threshold / unexpected drop /
#       clip+merge / clamp to end / missing or non-array known-outages → 未確認 /
#       no startTime → 未確認 / no observed uptime → no suffix)
#   U3  toFixed(2) and signed() rounding parity, including exact binary ties
#   U4  end to end: daily-status.sh's push ends with
#       "[Uptime] <actual>% (予定 X%・差 ±Y)"; missing / broken known-outages.json
#       and a missing helper → "(予定: 未確認)" and the push still goes out;
#       an unexpected drop adds the ⚠ line
#   U5  notify.sh without NOTIFY_UPTIME_SUFFIX keeps the bare footer (every
#       other push is unchanged)
#
# Mutation kill check (main run only): six mutants — helper ignores outages,
# helper slack 0.5→5, helper treats a missing file as "no outages", page
# overlapMs returns 0, daily-status stops exporting the suffix, helper uses
# Python's own rounding — must each turn the core checks red.
#
# Overrides (used by the mutation runs): UPTIME_CALC_JS, UPTIME_HELPER_PY,
# DAILY_STATUS_SH; UPTIME_TEST_CORE_ONLY=1 skips the mutation section.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="${REPO}/tests/daily-status/test-uptime-expected.sh"
FIXTURE="${REPO}/tests/fixtures/uptime-expected-vectors.json"
CALC="${UPTIME_CALC_JS:-${REPO}/public/status/status-calc.js}"
HELPER="${UPTIME_HELPER_PY:-${REPO}/scripts/uptime-expected.py}"
DAILY="${DAILY_STATUS_SH:-${REPO}/scripts/daily-status.sh}"

for tool in node python3 jq; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "FAIL: $tool not found (required)" >&2
		exit 1
	fi
done

PASS=0
FAIL=0
FAILURES=()
ok() {
	if [ "$1" = "1" ]; then PASS=$((PASS + 1)); printf '  PASS  %s\n' "$2"
	else FAIL=$((FAIL + 1)); FAILURES+=("$2"); printf '  FAIL  %s\n' "$2"; fi
}
count_lines() {
	# stdin "PASS …"/"FAIL …" lines → add to the counters
	local line
	while IFS= read -r line; do
		case "$line" in
			PASS*) ok 1 "${line#PASS }" ;;
			FAIL*) ok 0 "${line#FAIL }" ;;
			*) printf '  ....  %s\n' "$line" ;;
		esac
	done
}

TMP="$(mktemp -d -t fy-uptime-expected.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Each side writes one PASS/FAIL line per vector; the line count is checked
# too, so a side that crashes or silently evaluates nothing cannot pass.
N_ALL="$(jq '.vectors | length' "$FIXTURE")"
N_PAGE="$(jq '[.vectors[] | select(.page != false)] | length' "$FIXTURE")"
expect_lines() {
	# $1 label, $2 expected count, $3 results file
	local got
	got="$(grep -cE '^(PASS|FAIL) ' "$3")"
	ok "$([ "$got" = "$2" ] && echo 1 || echo 0)" "$1 evaluated every vector (${got}/$2)"
	count_lines < "$3"
}

cat > "${TMP}/u1.js" <<'JS'
"use strict";
const C = require(process.env.CALC);
const F = require(process.env.FIXTURE);
for (const v of F.vectors) {
	if (v.page === false) continue;
	const u = C.uptimeView(v.validator, Array.isArray(v.outages) ? v.outages : []);
	const got = {
		status: u.actual === null ? "no_actual" : (u.expected === null ? "unconfirmed" : "ok"),
		expected: null, diff: null, drop: false
	};
	if (got.status === "ok") {
		got.expected = u.expected.toFixed(2);
		got.diff = C.signed(u.diff);
		got.drop = u.actual < u.expected - C.LIMITS.uptimeSlackPts;
	}
	const same = ["status", "expected", "diff", "drop"].every((k) => got[k] === v.want[k]);
	console.log((same ? "PASS" : "FAIL") + " U1 page: " + v.name + (same ? "" : " got=" + JSON.stringify(got)));
}
JS
cat > "${TMP}/u2.py" <<'PY'
import json, os, subprocess, sys
fixture, helper, tmp = sys.argv[1:4]
F = json.load(open(fixture, encoding="utf-8"))
for i, v in enumerate(F["vectors"]):
    vp = os.path.join(tmp, "v%d.json" % i)
    op = os.path.join(tmp, "o%d.json" % i)
    json.dump(v["validator"], open(vp, "w"))
    if v["outages"] is None:
        if os.path.exists(op):
            os.remove(op)
    else:
        json.dump(v["outages"], open(op, "w"))
    r = subprocess.run(["python3", helper, "--json", vp, op], capture_output=True, text=True)
    try:
        got = json.loads(r.stdout)
    except ValueError:
        got = {"raw": r.stdout, "err": r.stderr[-200:]}
    same = all(got.get(k) == v["want"][k] for k in ("status", "expected", "diff", "drop"))
    print(("PASS" if same else "FAIL") + " U2 push json: " + v["name"] + ("" if same else " got=" + json.dumps(got, ensure_ascii=False)))
    r = subprocess.run(["python3", helper, vp, op], capture_output=True, text=True)
    same = r.returncode == 0 and r.stdout == v["suffix"]
    print(("PASS" if same else "FAIL") + " U2 push suffix: " + v["name"] + ("" if same else " got=" + repr(r.stdout)))
PY

echo "=== U1: page side (status-calc.js) equals the shared fixture ==="
FIXTURE="$FIXTURE" CALC="$CALC" node "${TMP}/u1.js" </dev/null > "${TMP}/u1.out" 2>&1
expect_lines "U1 page" "$N_PAGE" "${TMP}/u1.out"

echo ""
echo "=== U2: push side (uptime-expected.py) equals the same fixture ==="
python3 "${TMP}/u2.py" "$FIXTURE" "$HELPER" "$TMP" </dev/null > "${TMP}/u2.out" 2>&1
expect_lines "U2 push" "$((N_ALL * 2))" "${TMP}/u2.out"

echo ""
echo "=== U3: rounding parity (JS toFixed(2) / signed vs python) ==="
JS_FMT="$(FIXTURE="$FIXTURE" CALC="$CALC" node -e '
const C = require(process.env.CALC); const F = require(process.env.FIXTURE);
console.log(JSON.stringify({ toFixed2: F.format.toFixed2.map((x) => x.toFixed(2)), signed: F.format.signed.map(C.signed) }));' </dev/null)"
PY_FMT="$(python3 - "$FIXTURE" "$HELPER" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ue", sys.argv[2])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
F = json.load(open(sys.argv[1], encoding="utf-8"))["format"]
print(json.dumps({"toFixed2": [m.to_fixed2(x) for x in F["toFixed2"]], "signed": [m.signed(x) for x in F["signed"]]}, separators=(",", ":")))
PY
)"
ok "$([ -n "$JS_FMT" ] && [ "$JS_FMT" = "$PY_FMT" ] && echo 1 || echo 0)" "U3 toFixed(2)/signed identical on ties (js=${JS_FMT} py=${PY_FMT})"

echo ""
echo "=== U4: end to end through daily-status.sh ==="
S="${TMP}/sandbox"
mkdir -p "${S}/scripts/lib" "${S}/public/api"
cp -R "${REPO}/scripts/lib/." "${S}/scripts/lib/"
cp "${REPO}/scripts/notify.sh" "${S}/scripts/notify.sh"
cp "$DAILY" "${S}/scripts/daily-status.sh"
cp "$HELPER" "${S}/scripts/uptime-expected.py"
printf '#!/usr/bin/env bash\nexit 0\n' > "${S}/scripts/cycle-gate.sh"
chmod +x "${S}/scripts/cycle-gate.sh"
cat > "${S}/public/api/server-status.json" <<'JSON'
{ "metalgo": { "containerStatus": "running", "peerCount": 120 },
  "host": { "cpu": { "usedPercent": 15 }, "memory": { "usedPercent": 30 }, "disk": { "usedPercent": 40 } } }
JSON
printf 'sandbox-topic-not-a-real-topic\n' > "${S}/topic"

BIN="${TMP}/bin"
mkdir -p "$BIN"
LOG="${TMP}/ntfy-body.log"
cat > "${BIN}/curl" <<CURLEOF
#!/usr/bin/env bash
# ntfy stub: the URL arrives in a -K config on a pipe (notify.sh, 2026-09-29).
_a=(); _p=""
for _x in "\$@"; do
	if [ "\$_p" = -K ] || [ "\$_p" = --config ]; then _x="\$(sed -n 's/^url = "\(.*\)"\$/\1/p' "\$_x")"; fi
	_a+=("\$_x"); _p="\$_x"
done
DATA=""; URL=""; prev=""
for a in "\${_a[@]}"; do
	case "\$prev" in -d|--data) DATA="\$a" ;; esac
	case "\$a" in https://ntfy.sh/*) URL="\$a" ;; esac
	prev="\$a"
done
if [ -n "\$URL" ]; then printf '%s' "\$DATA" > "${LOG}"; echo "ntfy POST: 200"; exit 0; fi
exit 7
CURLEOF
chmod +x "${BIN}/curl"

OUTAGES='[ { "start": "2026-09-24T10:56:46Z", "end": "2026-09-28T14:51:16Z", "note": "x" } ]'
write_validator() {
	# $1 = network uptime (JSON value)
	cat > "${S}/public/api/validator.json" <<JSON
{ "nodeId": "NodeID-sandbox", "startTime": 1788498830, "endTime": 1791349999,
  "observedAt": "2026-10-03T11:40:00Z", "uptime": { "network": $1 },
  "stake": { "self": 12600, "totalReceived": 0 },
  "bootstrap": { "pChain": true, "xChain": true, "cChain": true } }
JSON
}
run_daily() {
	rm -f "$LOG"
	env PATH="${BIN}:${PATH}" FY_LIVE=1 NTFY_TOPIC_FILE="${S}/topic" METALGO_RPC="http://127.0.0.1:1" \
		FY_STATE_DIR="${TMP}/state" bash "${S}/scripts/daily-status.sh" evening </dev/null >/dev/null 2>&1
}
tail_is() {
	# push body must END with exactly $1 (the footer line(s))
	[ -f "$LOG" ] && python3 -c 'import sys; b=open(sys.argv[1],encoding="utf-8").read(); sys.exit(0 if b.endswith("\n\n"+sys.argv[2]) else 1)' "$LOG" "$1" && echo 1 || echo 0
}
mkdir -p "${TMP}/state"

write_validator '"85.7800"'
printf '%s\n' "$OUTAGES" > "${S}/public/api/known-outages.json"
run_daily
ok "$(tail_is '[Uptime] 85.7800% (予定 85.78%・差 +0.00)')" "U4 known outage: footer carries 予定 and 差 on the observed-uptime line"

write_validator '"80.0000"'
run_daily
ok "$(tail_is "[Uptime] 80.0000% (予定 85.78%・差 -5.78)
⚠ 想定外の低下 (予定より 0.5 pt 超低い)")" "U4 unexpected drop: ⚠ line follows the footer"

write_validator '"85.7800"'
rm -f "${S}/public/api/known-outages.json"
run_daily
ok "$(tail_is '[Uptime] 85.7800% (予定: 未確認)')" "U4 known-outages.json missing → 予定: 未確認, push still sent"

printf '[ { "start": ' > "${S}/public/api/known-outages.json"
run_daily
ok "$(tail_is '[Uptime] 85.7800% (予定: 未確認)')" "U4 known-outages.json unparseable → 予定: 未確認"

printf '%s\n' "$OUTAGES" > "${S}/public/api/known-outages.json"
mv "${S}/scripts/uptime-expected.py" "${S}/scripts/uptime-expected.py.off"
run_daily
ok "$(tail_is '[Uptime] 85.7800% (予定: 未確認)')" "U4 helper missing → 予定: 未確認, push still sent"
mv "${S}/scripts/uptime-expected.py.off" "${S}/scripts/uptime-expected.py"

echo ""
echo "=== U5: other pushes keep the bare footer ==="
rm -f "$LOG"
env -u NOTIFY_UPTIME_SUFFIX PATH="${BIN}:${PATH}" NTFY_TOPIC_FILE="${S}/topic" \
	bash "${S}/scripts/notify.sh" default "t" "body" </dev/null >/dev/null 2>&1
ok "$(tail_is '[Uptime] 85.7800%')" "U5 notify.sh without NOTIFY_UPTIME_SUFFIX: footer unchanged"

if [ "${UPTIME_TEST_CORE_ONLY:-0}" != "1" ]; then
	echo ""
	echo "=== mutation kill check: each claim above must fail when broken ==="
	M="${TMP}/mutants"
	mkdir -p "$M"
	# mutate <src> <dst> <old> <new> — refuses (FAIL) when <old> is not found,
	# so a reformat never leaves a mutant identical to the original.
	mutate() {
		python3 - "$@" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
if old not in t:
    sys.exit(1)
open(dst, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
	}
	kill_check() {
		# $1 label, $2.. env assignments for the core run
		local label="$1"; shift
		local out rc
		out="$(env "$@" UPTIME_TEST_CORE_ONLY=1 bash "$SELF" </dev/null 2>&1)"; rc=$?
		ok "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" "mutant killed: ${label} ($(printf '%s\n' "$out" | grep -c '  FAIL ') core FAILs)"
	}
	run_mutant() {
		# $1 label, $2 src, $3 dst, $4 old, $5 new, $6 env var to point at dst
		if mutate "$2" "$3" "$4" "$5"; then
			kill_check "$1" "$6=$3"
		else
			ok 0 "mutation target not found: $1"
		fi
	}
	run_mutant "helper ignores known outages" "${REPO}/scripts/uptime-expected.py" "${M}/m1.py" \
		'    if not (b > a) or not isinstance(outages, list):
        return 0' '    return 0' UPTIME_HELPER_PY
	run_mutant "helper slack 0.5 → 5" "${REPO}/scripts/uptime-expected.py" "${M}/m2.py" \
		'UPTIME_SLACK_PTS = 0.5' 'UPTIME_SLACK_PTS = 5' UPTIME_HELPER_PY
	run_mutant "helper treats missing known-outages as none" "${REPO}/scripts/uptime-expected.py" "${M}/m3.py" \
		'    if not isinstance(outages, list):
        return res' '    if not isinstance(outages, list):
        outages = []' UPTIME_HELPER_PY
	run_mutant "page overlapMs returns 0" "${REPO}/public/status/status-calc.js" "${M}/m4.js" \
		'if (!(b > a) || !Array.isArray(outages)) return 0;' 'return 0;' UPTIME_CALC_JS
	run_mutant "daily-status does not export the suffix" "${REPO}/scripts/daily-status.sh" "${M}/m5.sh" \
		'export NOTIFY_UPTIME_SUFFIX="$UPTIME_SUFFIX"' ':' DAILY_STATUS_SH
	run_mutant "helper rounds with Python's half-even" "${REPO}/scripts/uptime-expected.py" "${M}/m6.py" \
		'    return str(Decimal(x).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))' '    return "%.2f" % x' UPTIME_HELPER_PY
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
