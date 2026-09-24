#!/usr/bin/env bash
# tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh
# — suite for scripts/install-anomalies-web-origin-env.sh (web-probe design
# spec 2026-09-24 §3.6 / §5 case 9: the WEB_ORIGIN_IP env line, supplied at
# install time and never committed).
#
# The fixture is the metal-anomalies file scripts/vps-bootstrap.sh generates
# (its heredoc rendered with the bootstrap's own variables), i.e. the shape
# the live host carries. Addresses are RFC 5737 documentation addresses.
#
# CHAIN: none — test-harness mode only (FYD_CRON_TARGET / FYD_BACKUP_DIR point
#        into a tempdir); /etc/cron.d is never touched.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Usage:
#   bash tests/install-anomalies-web-origin-env/test-install-anomalies-web-origin-env.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-anomalies-web-origin-env.sh"
CHECKER="${REPO_ROOT}/scripts/check-cron-file.sh"
BOOTSTRAP="${REPO_ROOT}/scripts/vps-bootstrap.sh"

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP  $1${2:+ — $2}"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

WORK="$(mktemp -d -t web-origin-env-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
CRON_DIR="$WORK/cron.d"
F="$CRON_DIR/metal-anomalies"
mkdir -p "$CRON_DIR"

render_fixture() {   # <out> — vps-bootstrap.sh's metal-anomalies heredoc, rendered
	local body
	body="$(awk -v pat='cat > /etc/cron.d/metal-anomalies <<EOF' \
		'index($0, pat){flag=1; next} flag && /^EOF$/{exit} flag{print}' "$BOOTSTRAP")"
	printf 'DEPLOY_USER="deploy"\nDEPLOY_DIR="/home/deploy/metal.freedom-yield.com"\ncat <<EOF\n%s\nEOF\n' "$body" \
		| bash >"$1"
}
run_inst() {   # [args...] — against $F
	FYD_CRON_TARGET="$F" FYD_BACKUP_DIR="$WORK/backups" bash "$INSTALLER" "$@"
}
backups() { ls "$WORK/backups" 2>/dev/null | grep -c '^metal-anomalies\.bak-' || true; }
first_cmd_line() { grep -nvE '^[[:space:]]*(#|$)|^[A-Z_]+=' "$1" | head -1 | cut -d: -f1; }

render_fixture "$F"
[ -s "$F" ] && grep -q 'check-anomalies.sh' "$F" \
	&& ok "fixture: rendered vps-bootstrap.sh's metal-anomalies" \
	|| { bad "fixture: rendered vps-bootstrap.sh's metal-anomalies"; exit 1; }
cp "$F" "$WORK/orig"

# --- T1 insert --------------------------------------------------------------------
OUT="$(run_inst --origin-ip=192.0.2.10 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "T1 insert exits 0" || bad "T1 insert exits 0" "rc=$RC $OUT"
[ "$(grep -c '^WEB_ORIGIN_IP=' "$F")" = "1" ] && grep -qxF 'WEB_ORIGIN_IP=192.0.2.10' "$F" \
	&& ok "T1 exactly one WEB_ORIGIN_IP line with the given value" \
	|| bad "T1 exactly one WEB_ORIGIN_IP line with the given value" "$(grep -n WEB_ORIGIN_IP "$F")"
WO_LINE="$(grep -n '^WEB_ORIGIN_IP=' "$F" | cut -d: -f1)"
[ "$WO_LINE" = "$(( $(first_cmd_line "$F") - 1 ))" ] \
	&& ok "T1 placed directly above the first command line (end of the env header block)" \
	|| bad "T1 placed directly above the first command line" "line=$WO_LINE first_cmd=$(first_cmd_line "$F")"
diff <(grep -v '^WEB_ORIGIN_IP=' "$F") "$WORK/orig" >/dev/null \
	&& ok "T1 every other line preserved" || bad "T1 every other line preserved"
bash "$CHECKER" "$F" >/dev/null 2>&1 \
	&& ok "T1 result passes check-cron-file.sh" || bad "T1 result passes check-cron-file.sh"
grep -qF '192.0.2.10' <<<"$OUT" \
	&& bad "T1 the value is never echoed" "$OUT" || ok "T1 the value is never echoed"
[ "$(mode_of "$F")" = "644" ] && ok "T1 mode 0644" || bad "T1 mode 0644" "$(mode_of "$F")"
[ "$(backups)" = "1" ] && ok "T1 prior file backed up once" || bad "T1 prior file backed up once" "$(backups)"

# --- T2 idempotent ------------------------------------------------------------------
cp "$F" "$WORK/after-t1"
OUT="$(run_inst --origin-ip=192.0.2.10 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'no change' <<<"$OUT" && cmp -s "$F" "$WORK/after-t1" \
	&& ok "T2 same value again is a byte-for-byte no-op" || bad "T2 same value again is a no-op" "rc=$RC $OUT"
[ "$(backups)" = "1" ] && ok "T2 no extra backup on a no-op" || bad "T2 no extra backup on a no-op" "$(backups)"

# --- T3 change value --------------------------------------------------------------------
run_inst --origin-ip=198.51.100.7 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(grep -c '^WEB_ORIGIN_IP=' "$F")" = "1" ] && grep -qxF 'WEB_ORIGIN_IP=198.51.100.7' "$F" \
	&& ok "T3 a new value replaces the old one (still one line)" \
	|| bad "T3 a new value replaces the old one" "$(grep -n WEB_ORIGIN_IP "$F")"
grep -qF '192.0.2.10' "$F" && bad "T3 old value gone" || ok "T3 old value gone"
[ "$(ls "$CRON_DIR")" = "metal-anomalies" ] \
	&& ok "T3 no sidecar left in the cron dir" || bad "T3 no sidecar left in the cron dir" "$(ls "$CRON_DIR")"

# --- T4 value from the environment ------------------------------------------------------
render_fixture "$F"
WEB_ORIGIN_IP=192.0.2.10 FYD_CRON_TARGET="$F" FYD_BACKUP_DIR="$WORK/backups" bash "$INSTALLER" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -qxF 'WEB_ORIGIN_IP=192.0.2.10' "$F" \
	&& ok "T4 WEB_ORIGIN_IP from the environment is accepted" || bad "T4 WEB_ORIGIN_IP from the environment" "rc=$RC"

# --- T5 duplicates collapse to one ----------------------------------------------------------
render_fixture "$F"
awk 'NR==1{print "WEB_ORIGIN_IP=203.0.113.9"} {print} END{print "WEB_ORIGIN_IP=203.0.113.10"}' "$F" >"$WORK/dup" && cp "$WORK/dup" "$F"
run_inst --origin-ip=192.0.2.10 >/dev/null 2>&1
[ "$(grep -c '^WEB_ORIGIN_IP=' "$F")" = "1" ] && grep -qxF 'WEB_ORIGIN_IP=192.0.2.10' "$F" \
	&& ok "T5 stray WEB_ORIGIN_IP lines are removed, one remains" \
	|| bad "T5 stray WEB_ORIGIN_IP lines are removed" "$(grep -n WEB_ORIGIN_IP "$F")"

# --- T6 invalid addresses are refused and change nothing ------------------------------------
render_fixture "$F"; cp "$F" "$WORK/pre-t6"
for badip in "" 256.1.1.1 1.2.3 010.0.0.1 2001:db8::1 '192.0.2.10;touch /tmp/x' '192.0.2.10 '; do
	WEB_ORIGIN_IP= FYD_CRON_TARGET="$F" FYD_BACKUP_DIR="$WORK/backups" bash "$INSTALLER" "--origin-ip=${badip}" >/dev/null 2>&1; RC=$?
	[ "$RC" -eq 1 ] && cmp -s "$F" "$WORK/pre-t6" \
		&& ok "T6 [${badip}] refused (exit 1), file untouched" \
		|| bad "T6 [${badip}] refused (exit 1), file untouched" "rc=$RC"
done

# --- T7 missing target ----------------------------------------------------------------------
FYD_CRON_TARGET="$CRON_DIR/nope" bash "$INSTALLER" --origin-ip=192.0.2.10 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && [ ! -e "$CRON_DIR/nope" ] \
	&& ok "T7 missing target → exit 3, nothing created" || bad "T7 missing target → exit 3" "rc=$RC"

# --- T8 lint failure changes nothing ----------------------------------------------------------
render_fixture "$F"
grep -v '^SHELL=' "$F" >"$WORK/noshell" && cp "$WORK/noshell" "$F"
cp "$F" "$WORK/pre-t8"
run_inst --origin-ip=192.0.2.10 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 4 ] && cmp -s "$F" "$WORK/pre-t8" \
	&& ok "T8 a candidate that fails check-cron-file.sh → exit 4, file untouched" \
	|| bad "T8 lint failure → exit 4, file untouched" "rc=$RC"

# --- T9 root gate ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	env -u FYD_CRON_TARGET bash "$INSTALLER" --origin-ip=192.0.2.10 >/dev/null 2>&1; RC=$?
	[ "$RC" -eq 2 ] && ok "T9 production target without root → exit 2" || bad "T9 production target without root → exit 2" "rc=$RC"
else
	skip "T9 root gate" "running as root"
fi

echo "test-install-anomalies-web-origin-env.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
