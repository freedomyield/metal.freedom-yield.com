#!/usr/bin/env bash
# test-check-cron-file.sh — suite for scripts/check-cron-file.sh, the
# /etc/cron.d/metal-* pre-flight linter. Previously had no dedicated unit
# test (only exercised indirectly via installer suites).
#
# Focus: Rule 1's 2026-07-08 rework (R3). The original Rule 1 failed EVERY
# `>> /var/log/...` redirect unconditionally — right for a brand-new entry
# (the 2026-06-19 metal-evidence failure mode) but a false positive for the
# handful of /var/log/ crons scripts/vps-bootstrap.sh pre-provisions itself
# (touch + chown deploy:deploy before the cron ever fires). Rule 1 now passes
# a /var/log/ target that is either verified deploy-owned on this machine, or
# whose basename is on the known-good allowlist.
#
# CHAIN: none — pure file linting, no cron/system state touched.
#
# Usage:
#   bash tests/check-cron-file/test-check-cron-file.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-cron-file.sh"

if [ ! -f "$CHECKER" ]; then
	echo "FATAL: checker not found at $CHECKER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

DIR=""
setup()    { DIR="$(mktemp -d -t check-cron-file-test.XXXXXX)"; }
teardown() { rm -rf "$DIR"; DIR=""; }

# ---- case 1: usage error — no arg -----------------------------------------------------
bash "$CHECKER" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "no arg: exit 2" \
	|| bad "no arg: exit 2 (actual=$RC)"

# ---- case 2: usage error — file not found ----------------------------------------------
bash "$CHECKER" /nonexistent/path/does-not-exist >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "missing file: exit 2" \
	|| bad "missing file: exit 2 (actual=$RC)"

# ---- case 3: fully-compliant file → 0 violations ----------------------------------------
setup
cat > "$DIR/good" <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 5 * * * deploy { echo "=== x start \$(date -u +\%FT\%TZ) ==="; cd /home/deploy/metal.freedom-yield.com && bash scripts/x.sh; rc=\$?; echo "=== x end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /home/deploy/metal.freedom-yield.com/logs/x.log 2>&1
EOF
bash "$CHECKER" "$DIR/good" >/tmp/good_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "compliant file: exit 0" \
	|| bad "compliant file: exit 0 (actual=$RC)"
grep -q 'Result: 0 violation' /tmp/good_out.txt \
	&& ok "compliant file: 0 violations reported" \
	|| bad "compliant file: 0 violations reported"
teardown

# ---- case 4 (Rule 1, R3): unallowlisted /var/log/ target → FAIL -------------------------
setup
cat > "$DIR/bad-varlog" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * deploy echo hi >> /var/log/some-brand-new-name.log 2>&1
EOF
bash "$CHECKER" "$DIR/bad-varlog" >/tmp/bad_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "unallowlisted /var/log/: exit 1" \
	|| bad "unallowlisted /var/log/: exit 1 (actual=$RC)"
grep -qF 'FAIL: uses >> /var/log/some-brand-new-name.log' /tmp/bad_out.txt \
	&& ok "unallowlisted /var/log/: Rule 1 fails with the target named" \
	|| bad "unallowlisted /var/log/: Rule 1 fails with the target named"
teardown

# ---- case 5 (Rule 1, R3): allowlisted basename, absent locally → PASS -------------------
setup
cat > "$DIR/allowlisted" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash scripts/node-info.sh >> /var/log/node-info.log 2>&1
EOF
bash "$CHECKER" "$DIR/allowlisted" >/tmp/allow_out.txt 2>&1
grep -qF 'allowlisted: /var/log/node-info.log' /tmp/allow_out.txt \
	&& ok "allowlisted /var/log/ basename: Rule 1 passes" \
	|| bad "allowlisted /var/log/ basename: Rule 1 passes (out: $(cat /tmp/allow_out.txt))"
teardown

# ---- case 6 (Rule 1, R3): project-local logs/ path is unaffected ------------------------
setup
cat > "$DIR/local" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/x.sh >> /home/deploy/metal.freedom-yield.com/logs/x.log 2>&1
EOF
bash "$CHECKER" "$DIR/local" >/tmp/local_out.txt 2>&1
grep -qF 'no /var/log/ redirect.' /tmp/local_out.txt \
	&& ok "project-local logs/: Rule 1 reports no /var/log/ redirect" \
	|| bad "project-local logs/: Rule 1 reports no /var/log/ redirect"
teardown

# ---- case 7 (Rule 1, R3): existing file on this machine, owned by invoking user ---------
# (not "deploy") under a fabricated /var/log-shaped target is impossible to
# construct without root, so this only exercises the negative path already
# covered by case 4. Documented here rather than faked to avoid a misleading
# green that doesn't actually exercise the deploy-ownership branch.

# ---- case 8: Rule 2 — un-braced chain with && and >> still fails ------------------------
setup
cat > "$DIR/no-brace" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 5 * * * deploy cd /home/deploy/metal.freedom-yield.com && bash scripts/x.sh >> /home/deploy/metal.freedom-yield.com/logs/x.log 2>&1
EOF
bash "$CHECKER" "$DIR/no-brace" >/tmp/nobrace_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 2 still enforced: un-braced chain fails" \
	|| bad "Rule 2 still enforced: un-braced chain fails (actual=$RC)"
teardown

# ---- summary --------------------------------------------------------------------------
echo "test-check-cron-file.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
