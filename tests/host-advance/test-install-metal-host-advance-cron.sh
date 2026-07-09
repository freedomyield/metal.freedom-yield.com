#!/usr/bin/env bash
# test-install-metal-host-advance-cron.sh — suite for
# scripts/install-metal-host-advance-cron.sh (Task 2 of the 2026-07-09
# host-checkout-auto-advance design: docs/superpowers/specs/
# 2026-07-09-host-checkout-auto-advance-design.md).
#
# CHAIN: none — the installer runs against a tempdir target via
#        FYD_CRON_TARGET (root requirement waived in harness mode);
#        /etc/cron.d is never touched, and no host is contacted.
#
# Usage:
#   bash tests/host-advance/test-install-metal-host-advance-cron.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-metal-host-advance-cron.sh"

if [ ! -f "$INSTALLER" ]; then
	echo "FATAL: installer not found at $INSTALLER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

DIR=""
setup()    { DIR="$(mktemp -d -t advance-cron-test.XXXXXX)"; }
teardown() { rm -rf "$DIR"; DIR=""; }
run_installer() {
	FYD_CRON_TARGET="$DIR/metal-host-advance" FYD_BACKUP_DIR="$DIR/backups" \
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
[ -f "$DIR/metal-host-advance" ] \
	&& ok "fresh install: target file created" \
	|| bad "fresh install: target file created"
grep -qE '^SHELL=/bin/bash$' "$DIR/metal-host-advance" && grep -qE '^PATH=' "$DIR/metal-host-advance" \
	&& ok "fresh install: SHELL/PATH headers present (rule 5)" \
	|| bad "fresh install: SHELL/PATH headers present"
grep -q "45 4 \* \* \* deploy bash ${REPO_ROOT}/scripts/advance-host-checkout.sh" "$DIR/metal-host-advance" \
	&& ok "fresh install: schedule line targets advance-host-checkout.sh via FYD_REPO_PATH" \
	|| bad "fresh install: schedule line targets advance-host-checkout.sh"
grep -q 'deploy bash' "$DIR/metal-host-advance" \
	&& ok "fresh install: runs as user deploy" \
	|| bad "fresh install: runs as user deploy"
grep -q 'logger -t host-advance' "$DIR/metal-host-advance" \
	&& ok "fresh install: logs via logger -t host-advance" \
	|| bad "fresh install: logs via logger -t host-advance"
# Ordering rationale: the 04:45 UTC advance run must precede the 05:15 UTC
# check-host-drift.sh tripwire (scripts/install-metal-host-drift-cron.sh) so
# a healthy self-heal clears drift before the backstop samples it.
grep -qE '(^|[^0-9])4[45] 4 ' "$DIR/metal-host-advance" \
	&& ok "fresh install: scheduled before the 05:15 drift tripwire" \
	|| bad "fresh install: scheduled before the 05:15 drift tripwire"
[ -d "$DIR/backups" ] \
	&& bad "fresh install: no backup dir for a fresh target" \
	|| ok "fresh install: no backup dir for a fresh target"
teardown

# ---- case 3: generated content passes the repo cron linter -----------------------
setup
run_installer >/dev/null 2>&1
if [ -x "$REPO_ROOT/scripts/check-cron-file.sh" ]; then
	bash "$REPO_ROOT/scripts/check-cron-file.sh" "$DIR/metal-host-advance" >/dev/null 2>&1
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
SNAP="$(cat "$DIR/metal-host-advance")"
OUT2="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "idempotent: exit 0" \
	|| bad "idempotent: exit 0 (actual=$RC)"
echo "$OUT2" | grep -q 'already up to date' \
	&& ok "idempotent: reports already up to date" \
	|| bad "idempotent: reports already up to date (out: $OUT2)"
[ "$(cat "$DIR/metal-host-advance")" = "$SNAP" ] \
	&& ok "idempotent: file byte-identical" \
	|| bad "idempotent: file byte-identical"
[ -d "$DIR/backups" ] \
	&& bad "idempotent: no backup on no-op run" \
	|| ok "idempotent: no backup on no-op run"
teardown

# ---- case 5: differing pre-existing target → backed up then replaced --------------
setup
mkdir -p "$(dirname "$DIR/metal-host-advance")"
echo "# stale prior content" > "$DIR/metal-host-advance"
OUT="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "overwrite: exit 0" \
	|| bad "overwrite: exit 0 (actual=$RC)"
BK_FILE="$(ls "$DIR/backups"/metal-host-advance.bak-* 2>/dev/null | head -1)"
[ -n "$BK_FILE" ] && [ "$(cat "$BK_FILE")" = "# stale prior content" ] \
	&& ok "overwrite: prior bytes preserved in backup" \
	|| bad "overwrite: prior bytes preserved in backup"
grep -qE '^SHELL=/bin/bash$' "$DIR/metal-host-advance" \
	&& ok "overwrite: new content installed" \
	|| bad "overwrite: new content installed"
teardown

# ---- case 6: missing advance-host-checkout.sh at FYD_REPO_PATH → exit 3 -----------
setup
EMPTY="$DIR/empty-repo"; mkdir -p "$EMPTY"
FYD_CRON_TARGET="$DIR/metal-host-advance" FYD_REPO_PATH="$EMPTY" bash "$INSTALLER" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "missing script: exit 3" \
	|| bad "missing script: exit 3 (actual=$RC)"
[ -f "$DIR/metal-host-advance" ] \
	&& bad "missing script: nothing installed" \
	|| ok "missing script: nothing installed"
teardown

# ---- summary -----------------------------------------------------------------------
echo "test-install-metal-host-advance-cron.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
