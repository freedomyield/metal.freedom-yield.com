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

DIR=""
setup()    { DIR="$(mktemp -d -t watch-cron-test.XXXXXX)"; }
teardown() { rm -rf "$DIR"; DIR=""; }
run_installer() { FYD_CRON_FILE="$DIR/cron-file" FYD_BACKUP_DIR="$DIR/backups" bash "$INSTALLER" "$@"; }
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
teardown

# ---- case 5: unknown arg → usage error ---------------------------------------------------
setup
run_installer --bogus >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "unknown arg: exit 1" \
	|| bad "unknown arg: exit 1 (actual=$RC)"
teardown

# ---- summary ------------------------------------------------------------------------------
echo "test-install-watch-cron.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
