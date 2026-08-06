#!/usr/bin/env bash
# test-install-cron-audit-markers.sh — suite for
# scripts/install-cron-audit-markers.sh (H2 task, 2026-08-06).
#
# CHAIN: none — the installer runs against a tempdir via FYD_CRON_DIR (root
#        requirement waived in harness mode); /etc/cron.d is never touched.
#
# Usage:
#   bash tests/install-cron-audit-markers/test-install-cron-audit-markers.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-cron-audit-markers.sh"
CHECKER="${REPO_ROOT}/scripts/check-cron-file.sh"

if [ ! -f "$INSTALLER" ]; then
	echo "FATAL: installer not found at $INSTALLER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# ---- fixtures ---------------------------------------------------------------
DIR=""
BK=""
setup() {
	DIR="$(mktemp -d -t cron-markers-test.XXXXXX)"
	BK="$(mktemp -d -t cron-markers-bk.XXXXXX)"

	# real production defect shape, quoted verbatim in the H2 brief: a
	# 3-command && chain whose >> redirect only ever covered the last
	# command (node-info.sh's own stdout/stderr never reached the log).
	cat > "$DIR/metal-node-info" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
*/5 * * * * deploy cd /home/deploy/metal.freedom-yield.com && bash scripts/node-info.sh && bash scripts/push-to-web-host.sh validator.json >> /var/log/node-info.log 2>&1
EOF

	# single command, no && chain, but still no markers (Rule 3 still
	# requires them for any line with >>) — the metal-server-status shape.
	cat > "$DIR/metal-server-status" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/server-status.sh >> /var/log/server-status.log 2>&1
EOF

	# fully compliant already — must remain byte-identical.
	cat > "$DIR/metal-compliant" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 5 * * * deploy { echo "=== metal-compliant start $(date -u +\%FT\%TZ) ==="; bash scripts/x.sh; rc=$?; echo "=== metal-compliant end $(date -u +\%FT\%TZ) rc=$rc ==="; } >> /home/deploy/metal.freedom-yield.com/logs/x.log 2>&1
EOF

	# no >> at all (logger pipe) — Rules 2/3 do not apply; must stay
	# untouched (this script's job is >> lines only).
	cat > "$DIR/metal-host-drift" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF

	# ambiguous partial marker attempt (has "echo" but no brace group /
	# rc capture) — must be left untouched, whole file flagged for
	# operator review, never guessed at.
	cat > "$DIR/metal-partial" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 3 * * * deploy echo "start"; bash scripts/y.sh >> /var/log/y.log 2>&1
EOF

	# freedom-yield-* orphan (no repo installer) — must be in scope.
	cat > "$DIR/freedom-yield-peer-geo" <<'EOF'
0 6 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/peer-geo.py >> /home/deploy/metal.freedom-yield.com/logs/peer-geo.log 2>&1
EOF

	# other project's file — out of scope, must never be touched.
	cat > "$DIR/otherproj-job" <<'EOF'
15 3 * * * someone bash /other/project.sh >> /var/log/other.log 2>&1
EOF

	# sidecar filenames (real 2026-08-06 defect classes seen with the
	# sibling install-cron-env-headers.sh) — cron.d never executes these;
	# "fixing" one would corrupt a point-in-time record.
	cp "$DIR/metal-node-info" "$DIR/metal-node-info.bak-20260101-000000"
	cp "$DIR/metal-node-info" "$DIR/metal-node-info.disabled"
	cp "$DIR/metal-node-info" "$DIR/metal-node-info.orig"
}
teardown() { rm -rf "$DIR" "$BK"; DIR=""; BK=""; }

run_installer() {
	FYD_CRON_DIR="$DIR" FYD_BACKUP_DIR="$BK" bash "$INSTALLER" "$@"
}

# ---- case 1: dry-run reports but modifies nothing ---------------------------
setup
BEFORE_NI="$(cat "$DIR/metal-node-info")"
BEFORE_SS="$(cat "$DIR/metal-server-status")"
OUT="$(run_installer --dry-run 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "dry-run: exit 0" \
	|| bad "dry-run: exit 0 (actual=$RC)"
[ "$(cat "$DIR/metal-node-info")" = "$BEFORE_NI" ] \
	&& ok "dry-run: chain file unmodified" \
	|| bad "dry-run: chain file unmodified"
[ "$(cat "$DIR/metal-server-status")" = "$BEFORE_SS" ] \
	&& ok "dry-run: single-command file unmodified" \
	|| bad "dry-run: single-command file unmodified"
echo "$OUT" | grep -q 'would fix: metal-node-info' \
	&& ok "dry-run: reports would-fix for chain file" \
	|| bad "dry-run: reports would-fix for chain file (out: $OUT)"
echo "$OUT" | grep -q 'would fix: metal-server-status' \
	&& ok "dry-run: reports would-fix for single-command file" \
	|| bad "dry-run: reports would-fix for single-command file"
[ -e "$BK/metal-node-info" ] \
	&& bad "dry-run: no backup written" \
	|| ok "dry-run: no backup written"
teardown

# ---- case 2: apply fixes the chain (real production defect shape) -----------
setup
run_installer >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "apply: exit 0" \
	|| bad "apply: exit 0 (actual=$RC)"
grep -qE 'echo "=== metal-node-info start' "$DIR/metal-node-info" \
	&& ok "apply: start marker added to chain file" \
	|| bad "apply: start marker added to chain file"
grep -qE 'echo "=== metal-node-info end' "$DIR/metal-node-info" \
	&& ok "apply: end marker added to chain file" \
	|| bad "apply: end marker added to chain file"
grep -qE 'rc=\$\?' "$DIR/metal-node-info" \
	&& ok "apply: rc=\$? capture added to chain file" \
	|| bad "apply: rc=\$? capture added to chain file"
grep -qE '\{[^}]*&&[^{]*\}[[:space:]]*>>' "$DIR/metal-node-info" \
	&& ok "apply: chain now brace-wrapped covering the whole && chain" \
	|| bad "apply: chain now brace-wrapped covering the whole && chain"
teardown

# ---- case 3: apply fixes the single-command (no &&) shape too ---------------
setup
run_installer >/dev/null 2>&1
grep -qE 'echo "=== metal-server-status start' "$DIR/metal-server-status" \
	&& grep -qE 'echo "=== metal-server-status end' "$DIR/metal-server-status" \
	&& grep -qE 'rc=\$\?' "$DIR/metal-server-status" \
	&& ok "apply: single-command file gets markers + rc capture too" \
	|| bad "apply: single-command file gets markers + rc capture too (content: $(cat "$DIR/metal-server-status"))"
teardown

# ---- case 4: command body / schedule / user / log target are unchanged ------
setup
run_installer >/dev/null 2>&1
FIXED="$(cat "$DIR/metal-node-info" | grep '\*/5')"
echo "$FIXED" | grep -qF '*/5 * * * * deploy' \
	&& ok "invariance: schedule + user unchanged" \
	|| bad "invariance: schedule + user unchanged (line: $FIXED)"
echo "$FIXED" | grep -qF 'cd /home/deploy/metal.freedom-yield.com && bash scripts/node-info.sh && bash scripts/push-to-web-host.sh validator.json' \
	&& ok "invariance: full && command chain preserved verbatim" \
	|| bad "invariance: full && command chain preserved verbatim (line: $FIXED)"
echo "$FIXED" | grep -qF '>> /var/log/node-info.log 2>&1' \
	&& ok "invariance: redirect target + fd redirection unchanged" \
	|| bad "invariance: redirect target + fd redirection unchanged (line: $FIXED)"
teardown

# ---- case 5: fixed file passes check-cron-file.sh in full ------------------
setup
run_installer >/dev/null 2>&1
if [ -x "$CHECKER" ]; then
	bash "$CHECKER" "$DIR/metal-node-info" >/tmp/audit-markers-lint-ni.txt 2>&1
	RC=$?
	[ "$RC" -eq 0 ] \
		&& ok "lint: fixed chain file passes check-cron-file.sh in full" \
		|| bad "lint: fixed chain file passes check-cron-file.sh in full (rc=$RC, out: $(cat /tmp/audit-markers-lint-ni.txt))"
	bash "$CHECKER" "$DIR/metal-server-status" >/tmp/audit-markers-lint-ss.txt 2>&1
	RC=$?
	[ "$RC" -eq 0 ] \
		&& ok "lint: fixed single-command file passes check-cron-file.sh in full" \
		|| bad "lint: fixed single-command file passes check-cron-file.sh in full (rc=$RC, out: $(cat /tmp/audit-markers-lint-ss.txt))"
else
	echo "SKIP  lint cases (check-cron-file.sh not executable)"
fi
teardown

# ---- case 6: already-compliant file stays byte-identical; no backup --------
setup
CBEFORE="$(cat "$DIR/metal-compliant")"
run_installer >/dev/null 2>&1
[ "$(cat "$DIR/metal-compliant")" = "$CBEFORE" ] \
	&& ok "compliant file: byte-identical after apply" \
	|| bad "compliant file: byte-identical after apply"
[ -e "$BK/metal-compliant" ] \
	&& bad "compliant file: no backup entry" \
	|| ok "compliant file: no backup entry"
teardown

# ---- case 7: no->> (logger) file is out of Rule 2/3's scope, untouched -----
setup
HBEFORE="$(cat "$DIR/metal-host-drift")"
run_installer >/dev/null 2>&1
[ "$(cat "$DIR/metal-host-drift")" = "$HBEFORE" ] \
	&& ok "logger-pipe file: byte-identical (no >> to fix)" \
	|| bad "logger-pipe file: byte-identical (no >> to fix)"
[ -e "$BK/metal-host-drift" ] \
	&& bad "logger-pipe file: no backup entry" \
	|| ok "logger-pipe file: no backup entry"
teardown

# ---- case 8: ambiguous partial-marker line -> whole file untouched, warned -
setup
PBEFORE="$(cat "$DIR/metal-partial")"
OUT="$(run_installer 2>&1)"
[ "$(cat "$DIR/metal-partial")" = "$PBEFORE" ] \
	&& ok "ambiguous line: file left byte-identical" \
	|| bad "ambiguous line: file left byte-identical"
echo "$OUT" | grep -q 'warn:.*metal-partial.*operator review required' \
	&& ok "ambiguous line: warn names the file + reason" \
	|| bad "ambiguous line: warn names the file + reason (out: $OUT)"
echo "$OUT" | grep -qF 'echo "start"; bash scripts/y.sh >> /var/log/y.log 2>&1' \
	&& ok "ambiguous line: the offending line itself is echoed for review" \
	|| bad "ambiguous line: the offending line itself is echoed for review"
echo "$OUT" | grep -q 'needs operator review 1' \
	&& ok "ambiguous line: summary counts 1 for operator review" \
	|| bad "ambiguous line: summary counts 1 for operator review (out: $OUT)"
[ -e "$BK/metal-partial" ] \
	&& bad "ambiguous line: no backup entry (file untouched)" \
	|| ok "ambiguous line: no backup entry (file untouched)"
teardown

# ---- case 9: freedom-yield-* prefix is in scope ------------------------------
setup
run_installer >/dev/null 2>&1
grep -qE 'echo "=== freedom-yield-peer-geo start' "$DIR/freedom-yield-peer-geo" \
	&& ok "freedom-yield-*: orphan cron gets fixed too" \
	|| bad "freedom-yield-*: orphan cron gets fixed too (content: $(cat "$DIR/freedom-yield-peer-geo"))"
teardown

# ---- case 10: other-project file stays out of scope, untouched -------------
setup
OBEFORE="$(cat "$DIR/otherproj-job")"
run_installer >/dev/null 2>&1
[ "$(cat "$DIR/otherproj-job")" = "$OBEFORE" ] \
	&& ok "non-metal/freedom-yield file out of scope, untouched" \
	|| bad "non-metal/freedom-yield file out of scope, untouched"
teardown

# ---- case 11: sidecar filenames are skipped loudly, never mutated ----------
setup
B1="$(cat "$DIR/metal-node-info.bak-20260101-000000")"
B2="$(cat "$DIR/metal-node-info.disabled")"
B3="$(cat "$DIR/metal-node-info.orig")"
OUT="$(run_installer 2>&1)"
[ "$(cat "$DIR/metal-node-info.bak-20260101-000000")" = "$B1" ] \
	&& ok "sidecar: .bak-<ts> file unmodified" \
	|| bad "sidecar: .bak-<ts> file unmodified"
[ "$(cat "$DIR/metal-node-info.disabled")" = "$B2" ] \
	&& ok "sidecar: .disabled file unmodified" \
	|| bad "sidecar: .disabled file unmodified"
[ "$(cat "$DIR/metal-node-info.orig")" = "$B3" ] \
	&& ok "sidecar: .orig file unmodified" \
	|| bad "sidecar: .orig file unmodified"
echo "$OUT" | grep -q 'skipped (not a cron-executed filename): metal-node-info.bak-20260101-000000' \
	&& ok "sidecar: skip reported for .bak-<ts>" \
	|| bad "sidecar: skip reported for .bak-<ts> (out: $OUT)"
echo "$OUT" | grep -q 'skipped (not a cron-executed filename): metal-node-info.disabled' \
	&& ok "sidecar: skip reported for .disabled" \
	|| bad "sidecar: skip reported for .disabled"
echo "$OUT" | grep -q 'skipped (not a cron-executed filename): metal-node-info.orig' \
	&& ok "sidecar: skip reported for .orig" \
	|| bad "sidecar: skip reported for .orig"
echo "$OUT" | grep -q 'skipped (not cron-executed) 3' \
	&& ok "sidecar: summary counts 3 skipped" \
	|| bad "sidecar: summary counts 3 skipped (out: $OUT)"
[ -e "$BK/metal-node-info.bak-20260101-000000" ] \
	&& bad "sidecar: no backup written for a skipped file" \
	|| ok "sidecar: no backup written for a skipped file"
teardown

# ---- case 12: backup preserves the pre-edit byte content --------------------
setup
ORIG="$(cat "$DIR/metal-node-info")"
run_installer >/dev/null 2>&1
[ -f "$BK/metal-node-info" ] && [ "$(cat "$BK/metal-node-info")" = "$ORIG" ] \
	&& ok "backup: pre-edit copy preserved for the fixed file" \
	|| bad "backup: pre-edit copy preserved for the fixed file"
teardown

# ---- case 13: idempotent — second run is a byte-identical no-op ------------
setup
run_installer >/dev/null 2>&1
SNAP_NI="$(cat "$DIR/metal-node-info")"
SNAP_SS="$(cat "$DIR/metal-server-status")"
OUT2="$(run_installer 2>&1)"
[ "$(cat "$DIR/metal-node-info")" = "$SNAP_NI" ] \
	&& ok "idempotent: chain file identical after second run" \
	|| bad "idempotent: chain file identical after second run"
[ "$(cat "$DIR/metal-server-status")" = "$SNAP_SS" ] \
	&& ok "idempotent: single-command file identical after second run" \
	|| bad "idempotent: single-command file identical after second run"
echo "$OUT2" | grep -q 'summary: fixed 0, already compliant 5, needs operator review 1, skipped (not cron-executed) 3' \
	&& ok "idempotent: second run reports fixed 0 / compliant 5 / review 1 / skipped 3" \
	|| bad "idempotent: second run reports fixed 0 / compliant 5 / review 1 / skipped 3 (out: $OUT2)"
teardown

# ---- case 14: unknown arg -> exit 1 ------------------------------------------
setup
run_installer --bogus >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "arg: unknown flag -> exit 1" \
	|| bad "arg: unknown flag -> exit 1 (actual=$RC)"
teardown

# ---- case 15: is_cron_executed_filename is REUSED (sourced), not duplicated -
# The H2 brief explicitly required reusing the existing guard rather than
# re-implementing it. Prove the installer actually sources
# scripts/lib/cron-filename-guard.sh (no inline `case "$1" in *[!A-Za-z...`
# pattern of its own) and that the shared lib's function is what gates the
# scope loop.
LIB="${REPO_ROOT}/scripts/lib/cron-filename-guard.sh"
[ -f "$LIB" ] \
	&& ok "reuse: shared lib scripts/lib/cron-filename-guard.sh exists" \
	|| bad "reuse: shared lib scripts/lib/cron-filename-guard.sh exists"
grep -qF 'is_cron_executed_filename() {' "$LIB" \
	&& ok "reuse: lib defines is_cron_executed_filename()" \
	|| bad "reuse: lib defines is_cron_executed_filename()"
grep -qE '^\s*\.\s+"\$\{SCRIPT_DIR\}/lib/cron-filename-guard\.sh"' "$INSTALLER" \
	&& ok "reuse: installer sources the shared lib" \
	|| bad "reuse: installer sources the shared lib"
grep -qE '^is_cron_executed_filename\(\)' "$INSTALLER" \
	&& bad "reuse: installer does NOT re-define is_cron_executed_filename() itself" \
	|| ok "reuse: installer does NOT re-define is_cron_executed_filename() itself"

# ---- case 16 (mutation check): the sourced guard, exercised directly -------
if bash -c "
	. '$LIB'
	is_cron_executed_filename 'metal-node-info.bak-20260101-000000' && exit 1
	is_cron_executed_filename 'metal-node-info.disabled' && exit 1
	is_cron_executed_filename 'metal-node-info.orig' && exit 1
	is_cron_executed_filename 'metal-node-info' || exit 1
	exit 0
"; then
	ok "mutation: sourced is_cron_executed_filename rejects sidecar names, accepts a normal one"
else
	bad "mutation: sourced is_cron_executed_filename rejects sidecar names, accepts a normal one"
fi

# ---- summary ------------------------------------------------------------------
echo "test-install-cron-audit-markers.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
