#!/usr/bin/env bash
# tests/anomalies/test-web-probe-lib.sh
#
# Unit tests for scripts/lib/web-probe.sh — the measurement, classification
# and text-rendering helpers behind check-anomalies.sh's public-site probe
# (docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# §3.1, §3.2, §3.5). The library is sourced directly; curl / mtr / timeout
# are PATH stubs that record their argv, so nothing leaves the machine.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast, no network).

set -uo pipefail
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO}/scripts/lib/web-probe.sh"

TMP="$(mktemp -d -t fy-web-probe-lib.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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
assert_rc() {    # <label> <expected rc> <cmd...>
	local label="$1" expected="$2" rc
	shift 2
	"$@" >/dev/null 2>&1
	rc=$?
	assert_eq "$label" "$expected" "$rc"
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

if [ "$(uname)" = "Linux" ]; then
	DATE_REAL="$(command -v date)"
elif command -v gdate >/dev/null 2>&1; then
	DATE_REAL="$(command -v gdate)"
else
	echo "SKIP: test-web-probe-lib.sh requires GNU date (Linux 'date' or macOS 'gdate' via Homebrew coreutils)"
	exit 0
fi

BIN="${TMP}/bin"
mkdir -p "$BIN" "${TMP}/empty"
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$DATE_REAL" >"${BIN}/date"
cat >"${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$STUB_ARGV_LOG"
hdr=""; prev=""
for a in "$@"; do
	[ "$prev" = "-D" ] && hdr="$a"
	prev="$a"
done
case "$STUB_MODE" in
	ok)
		[ -n "$hdr" ] && printf 'HTTP/2 200\r\ncf-ray: 8c1f00dd1a2b3c4d-SIN\r\n\r\n' >"$hdr"
		printf 'http_code=200 t_dns=0.001 t_connect=0.010 t_tls=0.020 t_ttfb=0.030 t_total=0.031 remote_ip=192.0.2.10'
		exit 0
		;;
	timeout)
		echo 'curl: (28) Operation timed out after 10001 milliseconds' >&2
		printf 'http_code=000 t_dns=0.001 t_connect=0.000 t_tls=0.000 t_ttfb=0.000 t_total=10.001 remote_ip='
		exit 28
		;;
	silent)
		exit 7
		;;
esac
EOF
cat >"${BIN}/mtr" <<'EOF'
#!/usr/bin/env bash
printf 'mtr %s\n' "$*" >>"$STUB_ARGV_LOG"
echo 'HOST: stub   Loss%   Snt   Last   Avg  Best  Wrst StDev'
EOF
cat >"${BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >>"$STUB_ARGV_LOG"
shift
exec "$@"
EOF
chmod +x "${BIN}"/*
export PATH="${BIN}:${PATH}"
export STUB_ARGV_LOG="${TMP}/argv.log"
export STUB_MODE=ok
: >"$STUB_ARGV_LOG"

# shellcheck source=scripts/lib/web-probe.sh
. "$LIB"

echo "=== web_is_ipv4 ==="
for ip in 192.0.2.10 198.51.100.255 203.0.113.0 127.0.0.1 0.0.0.0; do
	assert_rc "accepts [$ip]" 0 web_is_ipv4 "$ip"
done
for ip in "" 256.1.1.1 1.2.3 1.2.3.4. .1.2.3.4 1..2.3 a.b.c.d 1.2.3.4.5 \
	2001:db8::1 "192.0.2.10 " "192.0.2.10;x" 1234.1.1.1 010.0.0.1; do
	assert_rc "rejects [$ip]" 1 web_is_ipv4 "$ip"
done

echo "=== web_resolve_spec ==="
assert_eq "https → port 443" "example.invalid:443:192.0.2.10" "$(web_resolve_spec https://example.invalid 192.0.2.10)"
assert_eq "http → port 80" "example.invalid:80:192.0.2.10" "$(web_resolve_spec http://example.invalid/x 192.0.2.10)"
assert_eq "explicit port kept" "127.0.0.1:19123:127.0.0.1" "$(web_resolve_spec http://127.0.0.1:19123 127.0.0.1)"
assert_rc "non-IPv4 origin refused" 1 web_resolve_spec https://example.invalid not-an-ip

echo "=== web_classify (spec §3.2) ==="
assert_eq "P_cf 200 → no class" "" "$(web_classify 200 skipped)"
assert_eq "P_cf fail + P_direct 200 → cf_path" cf_path "$(web_classify 000 200)"
assert_eq "P_cf 522 + P_direct 200 → cf_path" cf_path "$(web_classify 522 200)"
assert_eq "P_cf fail + P_direct fail → origin_or_path" origin_or_path "$(web_classify 000 000)"
assert_eq "P_cf fail + P_direct 503 → origin_or_path" origin_or_path "$(web_classify 000 503)"
assert_eq "P_cf fail + P_direct skipped → unknown" unknown "$(web_classify 000 skipped)"

echo "=== labels ==="
assert_eq "cf_path label" 'Cloudflare 経路 (origin は正常)' "$(web_class_label cf_path)"
assert_eq "origin_or_path label" 'origin 停止 または シンガポール経路 (未判別)' "$(web_class_label origin_or_path)"
assert_eq "unknown label" '判別不能 (origin 直接確認なし)' "$(web_class_label unknown)"
assert_eq "labels for a class history" \
	'Cloudflare 経路 (origin は正常) → origin 停止 または シンガポール経路 (未判別)' \
	"$(web_class_labels_csv cf_path,origin_or_path)"
assert_eq "labels for an empty history" '-' "$(web_class_labels_csv '')"

echo "=== web_duration_min (rounded up, at least 1) ==="
for pair in 0:1 1:1 60:1 61:2 570:10 600:10 601:11 -5:1 abc:1; do
	assert_eq "duration ${pair%%:*}s → ${pair#*:} min" "${pair#*:}" "$(web_duration_min "${pair%%:*}")"
done

echo "=== web_cf_colo ==="
printf 'HTTP/2 522\r\nCF-RAY: 8c1f00dd1a2b3c4d-NRT\r\n' >"${TMP}/h1"
printf 'HTTP/2 200\r\ncf-ray: 8c1f00dd1a2b3c4d-SIN\r\n' >"${TMP}/h2"
printf 'HTTP/1.1 200 OK\r\nserver: nginx\r\n' >"${TMP}/h3"
assert_eq "colo from CF-RAY (any case)" NRT "$(web_cf_colo "${TMP}/h1")"
assert_eq "colo from cf-ray" SIN "$(web_cf_colo "${TMP}/h2")"
assert_eq "no cf-ray → -" - "$(web_cf_colo "${TMP}/h3")"
assert_eq "missing file → -" - "$(web_cf_colo "${TMP}/nope")"

echo "=== web_probe ==="
: >"$STUB_ARGV_LOG"
STUB_MODE=ok
assert_eq "200 → prints 200" 200 "$(web_probe "${TMP}/p1" https://example.invalid/health)"
assert_re "200 → timing line kept with curl rc" '^http_code=200 t_dns=.* remote_ip=192\.0\.2\.10 curl_rc=0$' "$(cat "${TMP}/p1.w")"
assert_re "200 → headers kept" '^cf-ray: 8c1f00dd1a2b3c4d-SIN' "$(tr -d '\r' <"${TMP}/p1.h")"
ARGV="$(tail -1 "$STUB_ARGV_LOG")"
assert_re "argv: 10 s cap" '--max-time 10 ' "$ARGV"
assert_re "argv: headers dumped to the scratch file" "-D ${TMP}/p1\.h " "$ARGV"
assert_eq "argv: no --resolve for P_cf" 0 "$(grep -c -- '--resolve' <<<"$ARGV")"
STUB_MODE=timeout
assert_eq "timeout → 000" 000 "$(web_probe "${TMP}/p2" https://example.invalid/health)"
assert_re "timeout → curl rc 28 recorded" 'curl_rc=28$' "$(cat "${TMP}/p2.w")"
assert_re "timeout → curl error kept" '\(28\)' "$(cat "${TMP}/p2.err")"
STUB_MODE=silent
assert_eq "no output at all → 000" 000 "$(web_probe "${TMP}/p3" https://example.invalid/health)"
assert_eq "no output → minimal timing line" 'http_code=000 curl_rc=7' "$(cat "${TMP}/p3.w")"
STUB_MODE=ok
web_probe "${TMP}/p4" https://example.invalid/health example.invalid:443:192.0.2.10 >/dev/null
assert_re "P_direct passes --resolve" '--resolve example\.invalid:443:192\.0\.2\.10 ' "$(tail -1 "$STUB_ARGV_LOG")"
assert_eq "unwritable scratch never degrades the verdict" 200 "$(web_probe /dev/null/nope https://example.invalid/health)"

echo "=== web_mtr_capture ==="
: >"$STUB_ARGV_LOG"
web_mtr_capture 192.0.2.10 "${TMP}/mtr1"
assert_eq "mtr under timeout 25 with the spec's flags" 'timeout 25 mtr -r -n -c 5 -w 192.0.2.10' "$(head -1 "$STUB_ARGV_LOG")"
assert_re "mtr report captured" '^HOST: stub' "$(cat "${TMP}/mtr1")"
: >"$STUB_ARGV_LOG"
web_mtr_capture "" "${TMP}/mtr2"
assert_eq "no IP → skipped" 'skipped (no valid WEB_ORIGIN_IP)' "$(cat "${TMP}/mtr2")"
assert_eq "no IP → mtr not invoked" 0 "$(grep -c . "$STUB_ARGV_LOG")"
(PATH="${TMP}/empty"; web_mtr_capture 192.0.2.10 "${TMP}/mtr3")
assert_eq "mtr absent → skipped, not an error" 'skipped (mtr not installed)' "$(cat "${TMP}/mtr3")"

echo "=== web_render_diag ==="
D="${TMP}/diag"
mkdir -p "$D"
printf 'http_code=000 t_dns=0.001 t_connect=0.000 t_tls=0.000 t_ttfb=0.000 t_total=10.001 remote_ip= curl_rc=28\n' >"${D}/cf1.w"
: >"${D}/cf1.h"
echo 'curl: (28) Operation timed out' >"${D}/cf1.err"
printf 'http_code=522 t_dns=0.001 t_connect=0.010 t_tls=0.020 t_ttfb=5.000 t_total=5.001 remote_ip=192.0.2.10 curl_rc=0\n' >"${D}/cf2.w"
printf 'HTTP/2 522\r\ncf-ray: 8c1f00dd1a2b3c4d-SIN\r\n\r\n' >"${D}/cf2.h"
: >"${D}/cf2.err"
echo 'HOST: stub' >"${D}/mtr"
OUT="$(web_render_diag "$D" unknown 2026-09-21T09:00:00Z skipped)"
assert_eq "header line" '=== web-diag 2026-09-21T09:00:00Z class=unknown ===' "$(head -1 <<<"$OUT")"
assert_re "cf#1 timing" '^\[cf#1\] http_code=000 .*curl_rc=28$' "$OUT"
assert_re "cf#1 stderr" '^\[cf#1 stderr\]$' "$OUT"
assert_re "cf#2 headers, CR stripped, indented" '^  cf-ray: 8c1f00dd1a2b3c4d-SIN$' "$OUT"
assert_re "direct skipped" '^\[direct\] skipped' "$OUT"
assert_re "mtr section" '^  HOST: stub$' "$OUT"
OUT2="$(web_render_diag "$D" cf_path 2026-09-21T09:00:00Z 200)"
assert_re "direct expected but absent → not run" '^\[direct\] not run$' "$OUT2"

echo "=== web_render_blip_line ==="
assert_eq "blip line" \
	'2026-09-21T09:00:00Z 2026-09-21T09:10:00Z duration_s=600 classes=cf_path,origin_or_path pushed=true' \
	"$(web_render_blip_line 1789981200 1789981800 cf_path,origin_or_path true)"
assert_eq "blip line, no classes" \
	'2026-09-21T09:00:00Z 2026-09-21T09:10:00Z duration_s=600 classes=- pushed=false' \
	"$(web_render_blip_line 1789981200 1789981800 '' false)"

echo "=== purity: the library performs no side effect of its own ==="
CODE_ONLY="$(grep -vE '^[[:space:]]*#' "$LIB")"
for pat in fyd_ notify candidate_set STATE_FILE /var/log /var/lib; do
	assert_eq "no '${pat}' in library code" 0 "$(grep -cF -- "$pat" <<<"$CODE_ONLY")"
done

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
