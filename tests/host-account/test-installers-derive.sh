#!/usr/bin/env bash
# tests/host-account/test-installers-derive.sh — every script that takes the
# repo root from its own location and the cron account from the checkout's
# owner (scripts/lib/host-account.sh) is run here, one by one, from a copy of
# the tree, from another cwd, with no FYD_REPO_PATH / FYD_CRON_USER.
#
# CHAIN: none — writes only inside a tempdir; no host, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# What each script is held to:
#   path    the repo root it uses is the copy's root (so dropping or adding a
#           `/..` in its derivation changes the path in its output and fails)
#   user    the account it writes (cron user field, logrotate `create`, chown
#           argument, lint verdict) is the checkout's owner. A stub `stat`
#           reports a DIFFERENT owner for the scripts/ directory than for the
#           root, so reading the wrong directory is visible.
#   refuse  owner root / UNKNOWN / empty: exit 5 (65 for host-log-dir), and
#           nothing is written.
#
# Scripts that write under /etc/cron.d are run from a copy in which that path
# is rewritten into the tempdir, the same harness shape the other installer
# suites use; `id -u` reports 0, `chown` records its arguments, `install`
# drops the root-only flags.

set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

BASE="$(mktemp -d -t host-account-inst.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT
ACCT=fixacct

TREE="$BASE/tree"
mkdir -p "$TREE" "$BASE/etc/cron.d" "$BASE/stub"
cp -R "${REPO_ROOT}/scripts" "$TREE/scripts"
mkdir -p "$TREE/logs"
# the harness rewrite: /etc/cron.d/ -> tempdir, in the copies only
for f in "$TREE"/scripts/install-*.sh; do
	sed "s#/etc/cron\\.d/#${BASE}/etc/cron.d/#g" "$f" > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
done

# --- stubs ------------------------------------------------------------------
cat > "$BASE/stub/stat" <<'EOF'
#!/bin/sh
# last argument is the path. STUB_OWNER forces a value for every path; without
# it the scripts/ directory reports root and everything else the fixture
# account, so deriving from the wrong directory is visible.
for a; do p="$a"; done
if [ "${STUB_OWNER+set}" = set ]; then printf '%s\n' "$STUB_OWNER"; exit 0; fi
case "$p" in
	*/scripts) echo root ;;
	*) echo fixacct ;;
esac
EOF
cat > "$BASE/stub/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ] && [ $# -eq 1 ]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"
EOF
cat > "$BASE/stub/chown" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CHOWN_LOG"
EOF
cat > "$BASE/stub/install" <<'EOF'
#!/bin/sh
# drop the root-only flags and run the real install
args=""
while [ $# -gt 0 ]; do
	case "$1" in -o|-g) shift 2 ;; *) args="$args $1"; shift ;; esac
done
# shellcheck disable=SC2086
exec /usr/bin/install $args
EOF
chmod +x "$BASE/stub/"*

run() { # run <script> [args] -> rc ; output in $BASE/out ; chown log in $BASE/chown.log
	local s="$1"; shift
	: > "$BASE/chown.log"
	( cd / && env -u FYD_REPO_PATH -u FYD_REPO_DIR -u REPO -u REMOTE_PATH -u LOG_OWNER -u FYD_CRON_USER -u FYD_DEPLOY_USER \
		PATH="$BASE/stub:$PATH" CHOWN_LOG="$BASE/chown.log" "$@" bash "$TREE/scripts/$s" ${RUN_ARGS:-} ) > "$BASE/out" 2>&1
}
fresh() { rm -f "$BASE"/etc/cron.d/* "$BASE/lr.conf"; rm -rf "$BASE/bk"; }

check_cron() { # name script targetfile checked-script
	local name="$1" script="$2" target="$3" checked="$4"
	fresh
	run "$script" FYD_BACKUP_DIR="$BASE/bk" FYD_CRON_TARGET="$BASE/etc/cron.d/$target" FYD_CRON_FILE="$BASE/etc/cron.d/$target"; local rc=$?
	[ "$rc" -eq 0 ] && ok "$name: runs from the copy with no path/account env (rc=0)" || bad "$name: runs from the copy with no path/account env (rc=$rc: $(head -3 "$BASE/out" | tr '\n' ' '))"
	grep -qE "^[0-9*/,]+ [0-9*/,]+ \* \* [0-9*] ${ACCT} .*${TREE}/scripts/${checked}" "$BASE/etc/cron.d/$target" 2>/dev/null \
		&& ok "$name: cron line = copy's root + the checkout owner" \
		|| bad "$name: cron line = copy's root + the checkout owner"
	for o in root UNKNOWN ""; do
		fresh
		run "$script" STUB_OWNER="$o" FYD_BACKUP_DIR="$BASE/bk" FYD_CRON_TARGET="$BASE/etc/cron.d/$target" FYD_CRON_FILE="$BASE/etc/cron.d/$target"; rc=$?
		{ [ "$rc" -eq 5 ] && [ ! -e "$BASE/etc/cron.d/$target" ]; } \
			&& ok "$name: owner '${o:-empty}' -> exit 5, nothing written" \
			|| bad "$name: owner '${o:-empty}' -> exit 5, nothing written (rc=$rc)"
	done
}

# five installers with FYD_CRON_TARGET + FYD_REPO_PATH
check_cron host-advance   install-metal-host-advance-cron.sh   metal-host-advance   advance-host-checkout.sh
check_cron host-drift     install-metal-host-drift-cron.sh     metal-host-drift     check-host-drift.sh
check_cron identity-pins  install-metal-identity-pins-cron.sh  metal-identity-pins  check-identity-pins.sh
check_cron pulsevm-watch  install-metal-pulsevm-watch-cron.sh  metal-pulsevm-watch  check-pulsevm-upstream.sh
check_cron reward-tracker install-reward-tracker-cron.sh       metal-reward-tracker reward-tracker.sh

# publish-health (fixed target, root-only) ------------------------------------
fresh
run install-metal-anchor-publish-health-cron.sh; rc=$?
[ "$rc" -eq 0 ] && ok "publish-health: runs from the copy (rc=0)" || bad "publish-health: runs from the copy (rc=$rc: $(head -3 "$BASE/out" | tr '\n' ' '))"
grep -qE "^\*/15 \* \* \* \* ${ACCT} bash ${TREE}/scripts/check-anchor-publish-health.sh" "$BASE/etc/cron.d/metal-anchor-publish-health" 2>/dev/null \
	&& ok "publish-health: cron line = copy's root + the checkout owner" \
	|| bad "publish-health: cron line = copy's root + the checkout owner"
for o in root UNKNOWN ""; do
	fresh; run install-metal-anchor-publish-health-cron.sh STUB_OWNER="$o"; rc=$?
	{ [ "$rc" -eq 5 ] && [ ! -e "$BASE/etc/cron.d/metal-anchor-publish-health" ]; } \
		&& ok "publish-health: owner '${o:-empty}' -> exit 5, nothing written" \
		|| bad "publish-health: owner '${o:-empty}' -> exit 5, nothing written (rc=$rc)"
done

# watch-cron: the cron line and the chown argument ----------------------------
fresh
run install-watch-cron.sh; rc=$?
[ "$rc" -eq 0 ] && ok "watch: runs from the copy (rc=0)" || bad "watch: runs from the copy (rc=$rc: $(head -3 "$BASE/out" | tr '\n' ' '))"
grep -qE "^0 0,4,8,12 \* \* \* ${ACCT} \{ .*cd ${TREE} && bash scripts/check-watch-validators.sh" "$BASE/etc/cron.d/metal-watch-validators" 2>/dev/null \
	&& ok "watch: cron line = copy's root + the checkout owner" || bad "watch: cron line = copy's root + the checkout owner"
grep -qF "${ACCT}:${ACCT} ${TREE}/logs ${TREE}/logs/check-watch.log" "$BASE/chown.log" \
	&& ok "watch: chown is given the checkout owner and the copy's logs/" || bad "watch: chown is given the checkout owner and the copy's logs/ (log: $(cat "$BASE/chown.log"))"
for o in root UNKNOWN ""; do
	fresh; run install-watch-cron.sh STUB_OWNER="$o"; rc=$?
	{ [ "$rc" -eq 5 ] && [ ! -e "$BASE/etc/cron.d/metal-watch-validators" ]; } \
		&& ok "watch: owner '${o:-empty}' -> exit 5, nothing written" || bad "watch: owner '${o:-empty}' -> exit 5, nothing written (rc=$rc)"
done

# anchor-watch-alert-only ------------------------------------------------------
fresh
run install-anchor-watch-alert-only.sh; rc=$?
[ "$rc" -eq 0 ] && ok "anchor-watch: runs from the copy (rc=0)" || bad "anchor-watch: runs from the copy (rc=$rc: $(head -3 "$BASE/out" | tr '\n' ' '))"
grep -qE "^\*/5 \* \* \* \* ${ACCT} \{ .*cd ${TREE} && bash scripts/watch-anchor-events.sh" "$BASE/etc/cron.d/metal-anchor-watch" 2>/dev/null \
	&& ok "anchor-watch: cron line = copy's root + the checkout owner" || bad "anchor-watch: cron line = copy's root + the checkout owner"
grep -qF "${ACCT}:${ACCT} ${TREE}/logs ${TREE}/logs/anchor-watch.log" "$BASE/chown.log" \
	&& ok "anchor-watch: chown is given the checkout owner and the copy's logs/" || bad "anchor-watch: chown is given the checkout owner and the copy's logs/ (log: $(cat "$BASE/chown.log"))"
for o in root UNKNOWN ""; do
	fresh; run install-anchor-watch-alert-only.sh STUB_OWNER="$o"; rc=$?
	{ [ "$rc" -eq 5 ] && [ ! -e "$BASE/etc/cron.d/metal-anchor-watch" ]; } \
		&& ok "anchor-watch: owner '${o:-empty}' -> exit 5, nothing written" || bad "anchor-watch: owner '${o:-empty}' -> exit 5, nothing written (rc=$rc)"
done

# logrotate --------------------------------------------------------------------
mkdir -p "$BASE/logd"; touch "$BASE/logd/anomalies.log" "$BASE/logd/anomalies-web-diag.log" "$BASE/logd/anomalies-web-blips.log"
fresh
run install-anomalies-logrotate.sh FYD_LOGROTATE_TARGET="$BASE/lr.conf" FYD_LOG_DIR="$BASE/logd" FYD_BACKUP_DIR="$BASE/bk"; rc=$?
[ "$rc" -eq 0 ] && ok "logrotate: runs from the copy (rc=0)" || bad "logrotate: runs from the copy (rc=$rc: $(head -3 "$BASE/out" | tr '\n' ' '))"
grep -qE "^  create 644 ${ACCT} ${ACCT}$" "$BASE/lr.conf" 2>/dev/null \
	&& ok "logrotate: create line = the checkout owner" || bad "logrotate: create line = the checkout owner"
for o in root UNKNOWN ""; do
	fresh; run install-anomalies-logrotate.sh STUB_OWNER="$o" FYD_LOGROTATE_TARGET="$BASE/lr.conf" FYD_LOG_DIR="$BASE/logd" FYD_BACKUP_DIR="$BASE/bk"; rc=$?
	{ [ "$rc" -eq 5 ] && [ ! -e "$BASE/lr.conf" ]; } \
		&& ok "logrotate: owner '${o:-empty}' -> exit 5, nothing written" || bad "logrotate: owner '${o:-empty}' -> exit 5, nothing written (rc=$rc)"
done

# host-log-dir -----------------------------------------------------------------
run install-host-log-dir.sh; rc=$?
[ "$rc" -eq 0 ] && ok "host-log-dir: runs from the copy (rc=0)" || bad "host-log-dir: runs from the copy (rc=$rc: $(head -3 "$BASE/out" | tr '\n' ' '))"
grep -qF "${ACCT}:${ACCT} ${TREE}/logs" "$BASE/chown.log" \
	&& ok "host-log-dir: chown is given the checkout owner and the copy's logs/" || bad "host-log-dir: chown is given the checkout owner and the copy's logs/ (log: $(cat "$BASE/chown.log"))"
for o in root UNKNOWN ""; do
	run install-host-log-dir.sh STUB_OWNER="$o"; rc=$?
	{ [ "$rc" -eq 65 ] && [ ! -s "$BASE/chown.log" ]; } \
		&& ok "host-log-dir: owner '${o:-empty}' -> exit 65, no chown" || bad "host-log-dir: owner '${o:-empty}' -> exit 65, no chown (rc=$rc)"
done

# check-cron-file: the /var/log ownership verdict ------------------------------
EXIST="$(find /var/log -maxdepth 1 -type f 2>/dev/null | head -1)"
if [ -n "$EXIST" ]; then
	printf 'SHELL=/bin/bash\nPATH=/usr/local/bin:/usr/bin:/bin\n* * * * * %s echo hi >> %s 2>&1\n' "$ACCT" "$EXIST" > "$BASE/cron-in"
	( cd / && PATH="$BASE/stub:$PATH" bash "$TREE/scripts/check-cron-file.sh" "$BASE/cron-in" ) > "$BASE/out" 2>&1
	grep -qF "owned by the cron account" "$BASE/out" \
		&& ok "check-cron-file: an existing /var/log file owned by the checkout owner is verified" \
		|| bad "check-cron-file: an existing /var/log file owned by the checkout owner is verified"
	for o in root UNKNOWN ""; do
		( cd / && PATH="$BASE/stub:$PATH" STUB_OWNER="$o" bash "$TREE/scripts/check-cron-file.sh" "$BASE/cron-in" ) > "$BASE/out" 2>&1
		grep -qF "not verified writable by the cron account" "$BASE/out" \
			&& ok "check-cron-file: owner '${o:-empty}' verifies nothing (fail closed)" \
			|| bad "check-cron-file: owner '${o:-empty}' verifies nothing (fail closed)"
	done
else
	echo "SKIP  check-cron-file: no regular file under /var/log on this machine"
fi

echo "test-installers-derive.sh summary: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
