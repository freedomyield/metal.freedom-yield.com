#!/usr/bin/env bash
# test-audit-cron-dir.sh — suite for scripts/audit-cron-dir.sh (H2 task,
# 2026-08-06): the "assert lint exit 0 across every project cron file in a
# directory" primitive.
#
# CHAIN: none — pure read-only file linting against a synthetic tempdir;
#        /etc/cron.d is never touched.
#
# Usage:
#   bash tests/audit-cron-dir/test-audit-cron-dir.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUDIT="${REPO_ROOT}/scripts/audit-cron-dir.sh"

if [ ! -f "$AUDIT" ]; then
	echo "FATAL: $AUDIT not found" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

DIR=""
setup()    { DIR="$(mktemp -d -t audit-cron-dir-test.XXXXXX)"; }
teardown() { rm -rf "$DIR"; DIR=""; }

# ---- case 1: all-clean directory -> exit 0, correct counts -----------------
setup
cat > "$DIR/metal-clean-a" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF
cat > "$DIR/freedom-yield-clean-b" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 5 * * * deploy { echo "=== x start $(date -u +\%FT\%TZ) ==="; bash scripts/x.sh; rc=$?; echo "=== x end $(date -u +\%FT\%TZ) rc=$rc ==="; } >> /home/deploy/metal.freedom-yield.com/logs/x.log 2>&1
EOF
OUT="$(bash "$AUDIT" "$DIR" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "all-clean: exit 0" \
	|| bad "all-clean: exit 0 (actual=$RC, out: $OUT)"
echo "$OUT" | grep -q 'summary: 2 scanned, 2 clean, 0 with violations' \
	&& ok "all-clean: summary counts 2/2/0" \
	|| bad "all-clean: summary counts 2/2/0 (out: $OUT)"
teardown

# ---- case 2: one violating file -> exit 1, named in output -----------------
setup
cat > "$DIR/metal-clean" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF
cat > "$DIR/metal-dirty" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/node-info.sh >> /var/log/node-info.log 2>&1
EOF
OUT="$(bash "$AUDIT" "$DIR" 2>&1)"
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "one-dirty: exit 1" \
	|| bad "one-dirty: exit 1 (actual=$RC)"
echo "$OUT" | grep -q 'VIOLATIONS: metal-dirty' \
	&& ok "one-dirty: violating file named" \
	|| bad "one-dirty: violating file named (out: $OUT)"
echo "$OUT" | grep -q 'clean: metal-clean' \
	&& ok "one-dirty: clean file still reported clean" \
	|| bad "one-dirty: clean file still reported clean (out: $OUT)"
echo "$OUT" | grep -q 'summary: 2 scanned, 1 clean, 1 with violations' \
	&& ok "one-dirty: summary counts 2/1/1" \
	|| bad "one-dirty: summary counts 2/1/1 (out: $OUT)"
echo "$OUT" | grep -q 'still violating: metal-dirty' \
	&& ok "one-dirty: still-violating list names the file" \
	|| bad "one-dirty: still-violating list names the file (out: $OUT)"
teardown

# ---- case 3: sidecar filenames are skipped, not scanned/scored -------------
setup
cat > "$DIR/metal-dirty.bak-20260101-000000" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/node-info.sh >> /var/log/node-info.log 2>&1
EOF
OUT="$(bash "$AUDIT" "$DIR" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "sidecar-only: exit 0 (sidecar excluded from scoring)" \
	|| bad "sidecar-only: exit 0 (actual=$RC, out: $OUT)"
echo "$OUT" | grep -q 'skipped (not a cron-executed filename): metal-dirty.bak-20260101-000000' \
	&& ok "sidecar-only: skip reported" \
	|| bad "sidecar-only: skip reported (out: $OUT)"
echo "$OUT" | grep -q 'summary: 0 scanned, 0 clean, 0 with violations, 1 skipped' \
	&& ok "sidecar-only: summary counts 0/0/0, 1 skipped" \
	|| bad "sidecar-only: summary counts 0/0/0, 1 skipped (out: $OUT)"
teardown

# ---- case 4: empty directory -> exit 0, zero counts -------------------------
setup
OUT="$(bash "$AUDIT" "$DIR" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "empty dir: exit 0" \
	|| bad "empty dir: exit 0 (actual=$RC)"
echo "$OUT" | grep -q 'summary: 0 scanned, 0 clean, 0 with violations' \
	&& ok "empty dir: summary counts all zero" \
	|| bad "empty dir: summary counts all zero (out: $OUT)"
teardown

# ---- case 5: default dir arg (no arg) does not error on missing checker path
[ -x "${REPO_ROOT}/scripts/check-cron-file.sh" ] \
	&& ok "checker: check-cron-file.sh present alongside audit-cron-dir.sh" \
	|| bad "checker: check-cron-file.sh present alongside audit-cron-dir.sh"

# ---- summary ------------------------------------------------------------------
echo "test-audit-cron-dir.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
