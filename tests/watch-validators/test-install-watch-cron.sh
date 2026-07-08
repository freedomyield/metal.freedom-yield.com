#!/usr/bin/env bash
# test-install-watch-cron.sh — suite for scripts/install-watch-cron.sh.
#
# CHAIN: none — writes only to a tempdir target via FYD_CRON_FILE; never
#        touches /etc/cron.d or any real cron.
#
# Usage:
#   bash tests/watch-validators/test-install-watch-cron.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-watch-cron.sh"

if [ ! -f "$INSTALLER" ]; then
	echo "FATAL: installer not found at $INSTALLER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

CHECKER="${REPO_ROOT}/scripts/check-cron-file.sh"

DIR=""
setup()    { DIR="$(mktemp -d -t watch-cron-test.XXXXXX)"; }
teardown() { rm -rf "$DIR"; DIR=""; }
run_installer() {
	FYD_CRON_FILE="$DIR/cron-file" FYD_BACKUP_DIR="$DIR/backups" FYD_REPO_DIR="$DIR/repo" \
		bash "$INSTALLER" "$@"
}
cron() { cat "$DIR/cron-file" 2>/dev/null; }

# ---- case 1: fresh install — JST-daytime schedule, no night ticks ------------------
setup
OUT="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "install: exit 0" \
	|| bad "install: exit 0 (actual=$RC, out: $OUT)"
cron | grep -qE '^0 0,4,8,12 \* \* \* deploy ' \
	&& ok "install: schedule is 0,4,8,12 UTC as deploy" \
	|| bad "install: schedule is 0,4,8,12 UTC as deploy (cron: $(cron))"
cron | grep -v '^#' | grep -q '\*/4' \
	&& bad "install: no */4 night-hitting schedule remains" \
	|| ok "install: no */4 night-hitting schedule remains"
cron | grep -q 'check-watch-validators.sh' \
	&& ok "install: invokes the checker" \
	|| bad "install: invokes the checker"
cron | grep -q '^NTFY_TOPIC_FILE=/etc/freedom-yield/ntfy-topic$' \
	&& ok "install: carries the NTFY_TOPIC_FILE env header" \
	|| bad "install: carries the NTFY_TOPIC_FILE env header"
# R3: log-redirect pattern (2026-07-08 rework of the /var/log/ redirect that
# would have failed check-cron-file.sh — same class as the 2026-06-19 incident).
cron | grep -qE '>>\s*/var/log/' \
	&& bad "install: no /var/log/ redirect remains" \
	|| ok "install: no /var/log/ redirect remains"
cron | grep -qF ">> ${DIR}/repo/logs/check-watch.log" \
	&& ok "install: redirects to project-local logs/check-watch.log" \
	|| bad "install: redirects to project-local logs/check-watch.log (cron: $(cron))"
cron | grep -qE '\{[^}]*&&[^{]*\}\s*>>' \
	&& ok "install: chain is brace-wrapped around the redirect" \
	|| bad "install: chain is brace-wrapped around the redirect (cron: $(cron))"
cron | grep -q 'rc=$?' \
	&& ok "install: captures rc=\$?" \
	|| bad "install: captures rc=\$? (cron: $(cron))"
cron | grep -qE 'echo[^|]*start' && cron | grep -qE 'echo[^|]*end' \
	&& ok "install: has start/end markers" \
	|| bad "install: has start/end markers (cron: $(cron))"
[ -f "$DIR/repo/logs/check-watch.log" ] \
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
teardown

# ---- case 2: idempotent — second run is a no-op, no backup created ------------------
setup
run_installer >/dev/null 2>&1
OUT="$(run_installer 2>&1)"
echo "$OUT" | grep -q 'already up to date' \
	&& ok "idempotent: second run reports no change" \
	|| bad "idempotent: second run reports no change (out: $OUT)"
ls "$DIR"/backups/cron-file.bak-* >/dev/null 2>&1 \
	&& bad "idempotent: no backup created" \
	|| ok "idempotent: no backup created"
teardown

# ---- case 3: differing existing file → backed up then replaced ----------------------
setup
printf 'SHELL=/bin/bash\n0 */4 * * * deploy old-command\n' > "$DIR/cron-file"
OUT="$(run_installer 2>&1)"
echo "$OUT" | grep -q 'backed up prior cron' \
	&& ok "replace: prior cron backed up" \
	|| bad "replace: prior cron backed up (out: $OUT)"
ls "$DIR"/backups/cron-file.bak-* >/dev/null 2>&1 \
	&& ok "replace: backup file exists (outside cron dir)" \
	|| bad "replace: backup file exists (outside cron dir)"
cron | grep -qE '^0 0,4,8,12 ' \
	&& ok "replace: new schedule installed" \
	|| bad "replace: new schedule installed"
teardown

# ---- case 4: --dry-run writes nothing --------------------------------------------------
setup
OUT="$(run_installer --dry-run 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'DRY-RUN' \
	&& ok "dry-run: exit 0 with preview" \
	|| bad "dry-run: exit 0 with preview (rc=$RC out: $OUT)"
[ -f "$DIR/cron-file" ] \
	&& bad "dry-run: nothing written" \
	|| ok "dry-run: nothing written"
[ -e "$DIR/repo" ] \
	&& bad "dry-run: no side-effect log dir created" \
	|| ok "dry-run: no side-effect log dir created"
teardown

# ---- case 5: unknown arg → usage error ---------------------------------------------------
setup
run_installer --bogus >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "unknown arg: exit 1" \
	|| bad "unknown arg: exit 1 (actual=$RC)"
teardown

# ---- case 6: check-cron-file.sh pre-flight gate blocks a bad candidate --------------------
setup
STUB="$DIR/always-fail-checker.sh"
printf '#!/usr/bin/env bash\necho "stub: forced failure"\nexit 1\n' > "$STUB"
chmod +x "$STUB"
OUT="$(FYD_CRON_FILE="$DIR/cron-file" FYD_BACKUP_DIR="$DIR/backups" FYD_REPO_DIR="$DIR/repo" \
	FYD_CRON_CHECKER="$STUB" bash "$INSTALLER" 2>&1)"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "lint gate: exit 3 when check-cron-file.sh fails" \
	|| bad "lint gate: exit 3 when check-cron-file.sh fails (actual=$RC, out: $OUT)"
[ -f "$DIR/cron-file" ] \
	&& bad "lint gate: nothing installed on lint failure" \
	|| ok "lint gate: nothing installed on lint failure"
teardown

# ---- summary ------------------------------------------------------------------------------
echo "test-install-watch-cron.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
