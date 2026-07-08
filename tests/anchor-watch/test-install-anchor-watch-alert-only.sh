#!/usr/bin/env bash
# test-install-anchor-watch-alert-only.sh — suite for
# scripts/install-anchor-watch-alert-only.sh (2026-07-08 R3: the installer
# had no unit test at all — its unconditional `install -o root -g root`
# meant it could never even run outside a real root/host context).
#
# CHAIN: none — writes only to a tempdir target via FYD_ANCHOR_WATCH_CRON,
#        against a fake REPO tempdir; never touches /etc/cron.d or any real
#        cron, and never invokes watch-anchor-events.sh or the driver
#        (stubs only — the suite never polls metalgo).
#
# Usage:
#   bash tests/anchor-watch/test-install-anchor-watch-alert-only.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-anchor-watch-alert-only.sh"
CHECKER="${REPO_ROOT}/scripts/check-cron-file.sh"

if [ ! -f "$INSTALLER" ]; then
	echo "FATAL: installer not found at $INSTALLER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

DIR=""
setup() {
	DIR="$(mktemp -d -t anchor-watch-cron-test.XXXXXX)"
	# Stub prerequisites the installer checks for: DRIVER, NOTIFY, and the
	# watcher script itself. Content is irrelevant — the installer only
	# checks existence / makes them executable, never runs them.
	mkdir -p "$DIR/repo/scripts"
	printf '#!/usr/bin/env bash\ntrue\n' > "$DIR/repo/scripts/notify-anchor-transition.sh"
	printf '#!/usr/bin/env bash\ntrue\n' > "$DIR/repo/scripts/notify.sh"
	printf '#!/usr/bin/env bash\ntrue\n' > "$DIR/repo/scripts/watch-anchor-events.sh"
	chmod +x "$DIR/repo/scripts/notify.sh"
}
teardown() { rm -rf "$DIR"; DIR=""; }
run_installer() {
	REPO="$DIR/repo" FYD_ANCHOR_WATCH_CRON="$DIR/cron-file" bash "$INSTALLER" "$@"
}
cron() { cat "$DIR/cron-file" 2>/dev/null; }

# ---- case 1: fresh install — alert-only content + project-local logging ------------
setup
OUT="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "install: exit 0" \
	|| bad "install: exit 0 (actual=$RC, out: $OUT)"
[ -f "$DIR/cron-file" ] \
	&& ok "install: cron file written" \
	|| bad "install: cron file written"
cron | grep -qE '^\*/5 \* \* \* \* deploy ' \
	&& ok "install: schedule is */5 as deploy" \
	|| bad "install: schedule is */5 as deploy (cron: $(cron))"
cron | grep -q "ANCHOR_DRIVER=${DIR}/repo/scripts/notify-anchor-transition.sh" \
	&& ok "install: ANCHOR_DRIVER points at notify-anchor-transition.sh" \
	|| bad "install: ANCHOR_DRIVER points at notify-anchor-transition.sh (cron: $(cron))"
cron | grep -q 'watch-anchor-events.sh' \
	&& ok "install: invokes watch-anchor-events.sh" \
	|| bad "install: invokes watch-anchor-events.sh"
# R3: log-redirect pattern (2026-07-08 rework of the /var/log/ redirect that
# would have failed check-cron-file.sh — same class as the 2026-06-19 incident).
cron | grep -qE '>>\s*/var/log/' \
	&& bad "install: no /var/log/ redirect remains" \
	|| ok "install: no /var/log/ redirect remains"
cron | grep -qF ">> ${DIR}/repo/logs/anchor-watch.log" \
	&& ok "install: redirects to project-local logs/anchor-watch.log" \
	|| bad "install: redirects to project-local logs/anchor-watch.log (cron: $(cron))"
cron | grep -qE '\{[^}]*&&[^{]*\}\s*>>' \
	&& ok "install: chain is brace-wrapped around the redirect" \
	|| bad "install: chain is brace-wrapped around the redirect (cron: $(cron))"
cron | grep -q 'rc=$?' \
	&& ok "install: captures rc=\$?" \
	|| bad "install: captures rc=\$? (cron: $(cron))"
cron | grep -qE 'echo[^|]*start' && cron | grep -qE 'echo[^|]*end' \
	&& ok "install: has start/end markers" \
	|| bad "install: has start/end markers (cron: $(cron))"
[ -f "$DIR/repo/logs/anchor-watch.log" ] \
	&& ok "install: creates the project-local log file" \
	|| bad "install: creates the project-local log file"
if [ -x "$CHECKER" ]; then
	bash "$CHECKER" "$DIR/cron-file" >/dev/null 2>&1
	RC=$?
	[ "$RC" -eq 0 ] \
		&& ok "install: generated cron passes check-cron-file.sh" \
		|| bad "install: generated cron passes check-cron-file.sh (rc=$RC)"
else
	echo "SKIP  lint case (check-cron-file.sh not executable)"
fi
[ -x "$DIR/repo/scripts/notify-anchor-transition.sh" ] \
	&& ok "install: driver made executable" \
	|| bad "install: driver made executable"
teardown

# ---- case 2: missing driver → exit 1, nothing written -------------------------------
setup
rm -f "$DIR/repo/scripts/notify-anchor-transition.sh"
OUT="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "missing driver: exit 1" \
	|| bad "missing driver: exit 1 (actual=$RC)"
[ -f "$DIR/cron-file" ] \
	&& bad "missing driver: nothing installed" \
	|| ok "missing driver: nothing installed"
teardown

# ---- case 3: non-root against the real default target → exit 2 ---------------------
if [ "$(id -u)" -ne 0 ]; then
	OUT="$(REPO="$REPO_ROOT" bash "$INSTALLER" 2>&1)"
	RC=$?
	[ "$RC" -eq 2 ] \
		&& ok "non-root + default target: exit 2" \
		|| bad "non-root + default target: exit 2 (actual=$RC)"
else
	echo "SKIP  non-root case (suite running as root)"
fi

# ---- case 4: check-cron-file.sh pre-flight gate blocks a bad candidate --------------
setup
STUB="$DIR/always-fail-checker.sh"
printf '#!/usr/bin/env bash\necho "stub: forced failure"\nexit 1\n' > "$STUB"
chmod +x "$STUB"
OUT="$(REPO="$DIR/repo" FYD_ANCHOR_WATCH_CRON="$DIR/cron-file" FYD_CRON_CHECKER="$STUB" \
	bash "$INSTALLER" 2>&1)"
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "lint gate: exit 1 when check-cron-file.sh fails" \
	|| bad "lint gate: exit 1 when check-cron-file.sh fails (actual=$RC, out: $OUT)"
[ -f "$DIR/cron-file" ] \
	&& bad "lint gate: nothing installed on lint failure" \
	|| ok "lint gate: nothing installed on lint failure"
teardown

# ---- case 5: disabled-cycle-transition markers are removed --------------------------
setup
touch "${DIR}/cron-file.disabled-cycle-transition-20260704T000000Z"
OUT="$(run_installer 2>&1)"
echo "$OUT" | grep -q 'removed disabled marker' \
	&& ok "disabled marker: removed on install" \
	|| bad "disabled marker: removed on install (out: $OUT)"
[ -f "${DIR}/cron-file.disabled-cycle-transition-20260704T000000Z" ] \
	&& bad "disabled marker: file actually gone" \
	|| ok "disabled marker: file actually gone"
teardown

# ---- summary --------------------------------------------------------------------------
echo "test-install-anchor-watch-alert-only.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
