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

# ---- case 9 (Rule 6): allowlisted side-effecting script, no FY_LIVE=1 → FAIL ------------
setup
cat > "$DIR/side-effect-missing" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF
bash "$CHECKER" "$DIR/side-effect-missing" >/tmp/rule6_missing_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 6: side-effecting script without FY_LIVE=1 fails" \
	|| bad "Rule 6: side-effecting script without FY_LIVE=1 fails (actual=$RC)"
grep -qF 'check-host-drift.sh' /tmp/rule6_missing_out.txt \
	&& ok "Rule 6: violation names the side-effecting script" \
	|| bad "Rule 6: violation names the side-effecting script (out: $(cat /tmp/rule6_missing_out.txt))"
teardown

# ---- case 10 (Rule 6): allowlisted side-effecting script, WITH FY_LIVE=1 → PASS ---------
setup
cat > "$DIR/side-effect-present" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF
bash "$CHECKER" "$DIR/side-effect-present" >/tmp/rule6_present_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 6: side-effecting script WITH FY_LIVE=1 passes" \
	|| bad "Rule 6: side-effecting script WITH FY_LIVE=1 passes (actual=$RC, out: $(cat /tmp/rule6_present_out.txt))"
teardown

# ---- case 11 (Rule 6): real but non-side-effecting script, no FY_LIVE=1 → PASS ----------
# server-status.sh exists in this checkout's scripts/ dir, is not on the
# allowlist, and does not source side-effects.sh — the "read-only cron, out
# of scope" case. Otherwise fully rule 1-5 compliant so this case isolates
# Rule 6.
setup
cat > "$DIR/read-only" <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * deploy { echo "=== x start \$(date -u +\%FT\%TZ) ==="; cd /home/deploy/metal.freedom-yield.com && bash scripts/server-status.sh; rc=\$?; echo "=== x end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /home/deploy/metal.freedom-yield.com/logs/server-status.log 2>&1
EOF
bash "$CHECKER" "$DIR/read-only" >/tmp/rule6_readonly_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 6: non-side-effecting real script does not require FY_LIVE=1" \
	|| bad "Rule 6: non-side-effecting real script does not require FY_LIVE=1 (actual=$RC, out: $(cat /tmp/rule6_readonly_out.txt))"
teardown

# ---- case 12 (Rule 6): dynamic layer — a script sourcing side-effects.sh --------------
# but NOT on the static allowlist must still be caught, via FYD_CRON_SCRIPTS_DIR
# pointed at a synthetic scripts/ dir. Proves the "future-proof" detection path.
setup
mkdir -p "$DIR/fakescripts"
cat > "$DIR/fakescripts/migrated-example.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/lib/side-effects.sh"
fyd_notify default "example" "hi"
EOF
cat > "$DIR/dynamic-side-effect" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash scripts/migrated-example.sh 2>&1 | logger -t example
EOF
FYD_CRON_SCRIPTS_DIR="$DIR/fakescripts" bash "$CHECKER" "$DIR/dynamic-side-effect" >/tmp/rule6_dynamic_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 6: dynamic detection catches a non-allowlisted lib-sourcing script" \
	|| bad "Rule 6: dynamic detection catches a non-allowlisted lib-sourcing script (actual=$RC, out: $(cat /tmp/rule6_dynamic_out.txt))"
teardown

# ---- case 13 (Rule 6): FYD_CRON_FY_LIVE_GRACE=1 downgrades to a warning ----------------
setup
cat > "$DIR/grace" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF
FYD_CRON_FY_LIVE_GRACE=1 bash "$CHECKER" "$DIR/grace" >/tmp/rule6_grace_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 6: FYD_CRON_FY_LIVE_GRACE=1 downgrades the miss to non-fatal" \
	|| bad "Rule 6: FYD_CRON_FY_LIVE_GRACE=1 downgrades the miss to non-fatal (actual=$RC)"
grep -qF 'GRACE' /tmp/rule6_grace_out.txt \
	&& ok "Rule 6: grace path is visibly flagged, not silent" \
	|| bad "Rule 6: grace path is visibly flagged, not silent (out: $(cat /tmp/rule6_grace_out.txt))"
teardown

# ---- case 14: KNOWN_SIDE_EFFECT_CRON_BASENAMES stays in sync across both consumers -----
# check-cron-file.sh Rule 6 and install-cron-env-headers.sh duplicate this
# allowlist by design (see both files' comments) — this is the lock-step
# test that catches divergence, mirroring tests/side-effects/'s treatment of
# FYD_PUSH_FILENAME_RE.
ENV_HEADERS="${REPO_ROOT}/scripts/install-cron-env-headers.sh"
LIST_A="$(grep -m1 '^KNOWN_SIDE_EFFECT_CRON_BASENAMES=' "$CHECKER")"
LIST_B="$(grep -m1 '^KNOWN_SIDE_EFFECT_CRON_BASENAMES=' "$ENV_HEADERS")"
[ -n "$LIST_A" ] && [ "$LIST_A" = "$LIST_B" ] \
	&& ok "KNOWN_SIDE_EFFECT_CRON_BASENAMES identical in check-cron-file.sh and install-cron-env-headers.sh" \
	|| bad "KNOWN_SIDE_EFFECT_CRON_BASENAMES identical in check-cron-file.sh and install-cron-env-headers.sh (A: $LIST_A | B: $LIST_B)"

# ---- summary --------------------------------------------------------------------------
echo "test-check-cron-file.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
