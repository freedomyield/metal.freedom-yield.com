#!/usr/bin/env bash
# test-install-metal-host-drift-cron.sh — suite for
# scripts/install-metal-host-drift-cron.sh (PR #4 review 🟡 3: the installer
# previously had no unit test).
#
# CHAIN: none — the installer runs against a tempdir target via
#        FYD_CRON_TARGET (root requirement waived in harness mode);
#        /etc/cron.d is never touched.
#
# Usage:
#   bash tests/host-drift/test-install-metal-host-drift-cron.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-metal-host-drift-cron.sh"

if [ ! -f "$INSTALLER" ]; then
	echo "FATAL: installer not found at $INSTALLER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

DIR=""
setup()    { DIR="$(mktemp -d -t drift-cron-test.XXXXXX)"; }
teardown() { rm -rf "$DIR"; DIR=""; }
run_installer() {
	FYD_CRON_TARGET="$DIR/metal-host-drift" FYD_BACKUP_DIR="$DIR/backups" \
		FYD_REPO_PATH="$REPO_ROOT" bash "$INSTALLER" "$@"
}

# ---- case 1: default target as non-root → exit 2, nothing written --------------
if [ "$(id -u)" -ne 0 ]; then
	FYD_REPO_PATH="$REPO_ROOT" bash "$INSTALLER" >/dev/null 2>&1
	RC=$?
	[ "$RC" -eq 2 ] \
		&& ok "non-root + default target: exit 2" \
		|| bad "non-root + default target: exit 2 (actual=$RC)"
else
	echo "SKIP  non-root case (suite running as root)"
fi

# ---- case 2: fresh install into harness target ----------------------------------
setup
OUT="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "fresh install: exit 0" \
	|| bad "fresh install: exit 0 (actual=$RC)"
[ -f "$DIR/metal-host-drift" ] \
	&& ok "fresh install: target file created" \
	|| bad "fresh install: target file created"
grep -qE '^SHELL=/bin/bash$' "$DIR/metal-host-drift" && grep -qE '^PATH=' "$DIR/metal-host-drift" \
	&& ok "fresh install: SHELL/PATH headers present (rule 5)" \
	|| bad "fresh install: SHELL/PATH headers present"
grep -q "15 5 \* \* \* deploy bash ${REPO_ROOT}/scripts/check-host-drift.sh" "$DIR/metal-host-drift" \
	&& ok "fresh install: schedule line targets check-host-drift.sh via FYD_REPO_PATH" \
	|| bad "fresh install: schedule line targets check-host-drift.sh"
grep -q 'logger -t host-drift' "$DIR/metal-host-drift" \
	&& ok "fresh install: logs via logger (no /var/log redirect)" \
	|| bad "fresh install: logs via logger"
[ -d "$DIR/backups" ] \
	&& bad "fresh install: no backup dir for a fresh target" \
	|| ok "fresh install: no backup dir for a fresh target"
teardown

# ---- case 3: generated content passes the repo cron linter -----------------------
setup
run_installer >/dev/null 2>&1
if [ -x "$REPO_ROOT/scripts/check-cron-file.sh" ]; then
	bash "$REPO_ROOT/scripts/check-cron-file.sh" "$DIR/metal-host-drift" >/dev/null 2>&1
	RC=$?
	[ "$RC" -eq 0 ] \
		&& ok "lint: generated file passes check-cron-file.sh" \
		|| bad "lint: generated file passes check-cron-file.sh (rc=$RC)"
else
	echo "SKIP  lint case (check-cron-file.sh not executable)"
fi
teardown

# ---- case 4: idempotent — second run no change, no backup -------------------------
setup
run_installer >/dev/null 2>&1
SNAP="$(cat "$DIR/metal-host-drift")"
OUT2="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "idempotent: exit 0" \
	|| bad "idempotent: exit 0 (actual=$RC)"
echo "$OUT2" | grep -q 'already up to date' \
	&& ok "idempotent: reports already up to date" \
	|| bad "idempotent: reports already up to date (out: $OUT2)"
[ "$(cat "$DIR/metal-host-drift")" = "$SNAP" ] \
	&& ok "idempotent: file byte-identical" \
	|| bad "idempotent: file byte-identical"
[ -d "$DIR/backups" ] \
	&& bad "idempotent: no backup on no-op run" \
	|| ok "idempotent: no backup on no-op run"
teardown

# ---- case 5: differing pre-existing target → backed up then replaced --------------
setup
mkdir -p "$(dirname "$DIR/metal-host-drift")"
echo "# stale prior content" > "$DIR/metal-host-drift"
OUT="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "overwrite: exit 0" \
	|| bad "overwrite: exit 0 (actual=$RC)"
BK_FILE="$(ls "$DIR/backups"/metal-host-drift.bak-* 2>/dev/null | head -1)"
[ -n "$BK_FILE" ] && [ "$(cat "$BK_FILE")" = "# stale prior content" ] \
	&& ok "overwrite: prior bytes preserved in backup" \
	|| bad "overwrite: prior bytes preserved in backup"
grep -qE '^SHELL=/bin/bash$' "$DIR/metal-host-drift" \
	&& ok "overwrite: new content installed" \
	|| bad "overwrite: new content installed"
teardown

# ---- case 6: missing check-host-drift.sh at FYD_REPO_PATH → exit 3 ----------------
setup
EMPTY="$DIR/empty-repo"; mkdir -p "$EMPTY"
FYD_CRON_TARGET="$DIR/metal-host-drift" FYD_REPO_PATH="$EMPTY" bash "$INSTALLER" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "missing checker: exit 3" \
	|| bad "missing checker: exit 3 (actual=$RC)"
[ -f "$DIR/metal-host-drift" ] \
	&& bad "missing checker: nothing installed" \
	|| ok "missing checker: nothing installed"
teardown

# ---- summary -----------------------------------------------------------------------
echo "test-install-metal-host-drift-cron.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
