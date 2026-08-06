#!/usr/bin/env bash
# test-install-cron-env-headers.sh — suite for scripts/install-cron-env-headers.sh.
#
# CHAIN: none — the installer runs against a tempdir via FYD_CRON_DIR
#        (root requirement waived in harness mode); /etc/cron.d is never
#        touched.
#
# Usage:
#   bash tests/install-cron-env-headers/test-install-cron-env-headers.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-cron-env-headers.sh"

if [ ! -f "$INSTALLER" ]; then
	echo "FATAL: installer not found at $INSTALLER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# ---- fixtures ----------------------------------------------------------------
DIR=""
BK=""
setup() {
	DIR="$(mktemp -d -t cron-hdr-test.XXXXXX)"
	BK="$(mktemp -d -t cron-hdr-bk.XXXXXX)"

	# missing both, with leading comment block
	cat > "$DIR/metal-missing-both" <<'EOF'
# Daily job description
# spanning two comment lines.
0 4 * * * deploy bash /some/script.sh >> /dev/null 2>&1
EOF

	# missing SHELL only (has PATH)
	cat > "$DIR/metal-missing-shell" <<'EOF'
# watcher
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash /some/watch.sh
EOF

	# fully compliant — must remain byte-identical
	cat > "$DIR/metal-compliant" <<'EOF'
# compliant file
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 7 * * * deploy bash /some/daily.sh
EOF

	# no leading comments at all
	cat > "$DIR/metal-no-comments" <<'EOF'
30 2 * * * deploy bash /some/other.sh
EOF

	# other project's file — out of scope, must never be touched
	cat > "$DIR/otherproj-job" <<'EOF'
15 3 * * * someone bash /other/project.sh
EOF

	# WRONG-value SHELL (present but not /bin/bash) — must be left untouched
	cat > "$DIR/metal-wrong-shell" <<'EOF'
# wrong shell value
SHELL=/bin/sh
45 6 * * * deploy bash /some/wrong.sh
EOF
}
teardown() { rm -rf "$DIR" "$BK"; DIR=""; BK=""; }

run_installer() {
	FYD_CRON_DIR="$DIR" FYD_BACKUP_DIR="$BK" bash "$INSTALLER" "$@"
}

# ---- case 1: dry-run reports but modifies nothing ------------------------------
setup
BEFORE="$(cat "$DIR/metal-missing-both")"
OUT="$(run_installer --dry-run 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "dry-run: exit 0" \
	|| bad "dry-run: exit 0 (actual=$RC)"
[ "$(cat "$DIR/metal-missing-both")" = "$BEFORE" ] \
	&& ok "dry-run: file unmodified" \
	|| bad "dry-run: file unmodified"
echo "$OUT" | grep -q 'would fix: metal-missing-both (missing: SHELL+PATH)' \
	&& ok "dry-run: reports missing SHELL+PATH" \
	|| bad "dry-run: reports missing SHELL+PATH (out: $OUT)"
echo "$OUT" | grep -q 'would fix: metal-missing-shell (missing: SHELL)' \
	&& ok "dry-run: reports missing SHELL only" \
	|| bad "dry-run: reports missing SHELL only"
[ -e "$BK/metal-missing-both" ] \
	&& bad "dry-run: no backup written" \
	|| ok "dry-run: no backup written"
teardown

# ---- case 2: apply — headers inserted after leading comments -------------------
setup
run_installer >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "apply: exit 0" \
	|| bad "apply: exit 0 (actual=$RC)"
grep -qE '^SHELL=/bin/bash$' "$DIR/metal-missing-both" \
	&& ok "apply: SHELL added to missing-both" \
	|| bad "apply: SHELL added to missing-both"
grep -qE '^PATH=' "$DIR/metal-missing-both" \
	&& ok "apply: PATH added to missing-both" \
	|| bad "apply: PATH added to missing-both"
# insertion position: after the comment block, before the job line
POS="$(grep -n '' "$DIR/metal-missing-both" | sed -n 's/^\([0-9]*\):SHELL=\/bin\/bash$/\1/p')"
[ "$POS" = "3" ] \
	&& ok "apply: SHELL inserted after leading comment block (line 3)" \
	|| bad "apply: SHELL inserted after leading comment block (line=$POS)"
teardown

# ---- case 3: only the missing header is added ----------------------------------
setup
run_installer >/dev/null 2>&1
SHELL_N="$(grep -cE '^SHELL=' "$DIR/metal-missing-shell")"
PATH_N="$(grep -cE '^PATH=' "$DIR/metal-missing-shell")"
[ "$SHELL_N" = "1" ] && [ "$PATH_N" = "1" ] \
	&& ok "partial: SHELL added once, existing PATH untouched (1/1)" \
	|| bad "partial: SHELL added once, existing PATH untouched (SHELL=$SHELL_N PATH=$PATH_N)"
teardown

# ---- case 4: compliant file stays byte-identical; scope respected --------------
setup
CBEFORE="$(cat "$DIR/metal-compliant")"
OBEFORE="$(cat "$DIR/otherproj-job")"
run_installer >/dev/null 2>&1
[ "$(cat "$DIR/metal-compliant")" = "$CBEFORE" ] \
	&& ok "compliant file untouched" \
	|| bad "compliant file untouched"
[ "$(cat "$DIR/otherproj-job")" = "$OBEFORE" ] \
	&& ok "non-metal file out of scope" \
	|| bad "non-metal file out of scope"
[ -e "$BK/metal-compliant" ] \
	&& bad "compliant file: no backup entry" \
	|| ok "compliant file: no backup entry"
teardown

# ---- case 5: idempotent — second run changes nothing ----------------------------
setup
run_installer >/dev/null 2>&1
SNAP1="$(cat "$DIR/metal-missing-both")"
OUT2="$(run_installer 2>&1)"
[ "$(cat "$DIR/metal-missing-both")" = "$SNAP1" ] \
	&& ok "idempotent: second run leaves file identical" \
	|| bad "idempotent: second run leaves file identical"
echo "$OUT2" | grep -q 'summary: fixed 0, already compliant 4, needs operator review 1' \
	&& ok "idempotent: second run reports fixed 0 / compliant 4" \
	|| bad "idempotent: second run reports fixed 0 / compliant 4 (out: $OUT2)"
teardown

# ---- case 6: backup of every modified file --------------------------------------
setup
ORIG_BOTH="$(cat "$DIR/metal-missing-both")"
run_installer >/dev/null 2>&1
[ -f "$BK/metal-missing-both" ] && [ "$(cat "$BK/metal-missing-both")" = "$ORIG_BOTH" ] \
	&& ok "backup: pre-edit copy preserved" \
	|| bad "backup: pre-edit copy preserved"
teardown

# ---- case 7: no-comment file gets headers at top ---------------------------------
setup
run_installer >/dev/null 2>&1
FIRST="$(head -1 "$DIR/metal-no-comments")"
[ "$FIRST" = "SHELL=/bin/bash" ] \
	&& ok "no-comment file: SHELL is line 1" \
	|| bad "no-comment file: SHELL is line 1 (actual='$FIRST')"
teardown

# ---- case 8: post-edit files satisfy linter rule 5 -------------------------------
setup
run_installer >/dev/null 2>&1
ALL_OK=1
for f in "$DIR"/metal-*; do
	# metal-wrong-shell is deliberately left for operator review (warn path)
	[ "$(basename "$f")" = "metal-wrong-shell" ] && continue
	grep -qE '^SHELL=/bin/bash\b' "$f" && grep -qE '^PATH=' "$f" || ALL_OK=0
done
[ "$ALL_OK" = "1" ] \
	&& ok "post-edit: every fixable metal-* file carries both headers (rule 5)" \
	|| bad "post-edit: every fixable metal-* file carries both headers (rule 5)"
teardown

# ---- case 9: unknown arg → exit 1 -------------------------------------------------
setup
run_installer --bogus >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "arg: unknown flag → exit 1" \
	|| bad "arg: unknown flag → exit 1 (actual=$RC)"
teardown

# ---- case 10: WRONG-value SHELL → untouched, warned, operator review ------------
setup
WBEFORE="$(cat "$DIR/metal-wrong-shell")"
OUT="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "wrong-shell: exit 0 (advisory, not fatal)" \
	|| bad "wrong-shell: exit 0 (actual=$RC)"
[ "$(cat "$DIR/metal-wrong-shell")" = "$WBEFORE" ] \
	&& ok "wrong-shell: file left byte-identical" \
	|| bad "wrong-shell: file left byte-identical"
echo "$OUT" | grep -q 'warn:.*metal-wrong-shell.*SHELL=/bin/sh.*operator review required' \
	&& ok "wrong-shell: warn line names file + wrong value" \
	|| bad "wrong-shell: warn line names file + wrong value (out: $OUT)"
echo "$OUT" | grep -q 'needs operator review 1' \
	&& ok "wrong-shell: summary counts 1 for operator review" \
	|| bad "wrong-shell: summary counts 1 for operator review"
[ -e "$BK/metal-wrong-shell" ] \
	&& bad "wrong-shell: no backup entry (file untouched)" \
	|| ok "wrong-shell: no backup entry (file untouched)"
grep -cE '^SHELL=' "$DIR/metal-wrong-shell" | grep -q '^1$' \
	&& ok "wrong-shell: no duplicate SHELL line introduced" \
	|| bad "wrong-shell: no duplicate SHELL line introduced"
teardown

# ---- FY_LIVE=1 cases (2026-08-06, check-cron-file.sh Rule 6 parity) --------------
# Own fixture set / own dir: the 6 fixtures above deliberately reference
# placeholder script paths (/some/*.sh) so none of them trip FY_LIVE
# detection — cases 1-10 above are unaffected by this addition (verified: no
# existing assertion changed). These cases reference REAL basenames in this
# checkout's scripts/ dir to exercise the new behavior in isolation.
DIR2=""; BK2=""
setup2() {
	DIR2="$(mktemp -d -t cron-hdr-fy-live-test.XXXXXX)"
	BK2="$(mktemp -d -t cron-hdr-fy-live-bk.XXXXXX)"

	# side-effecting script (check-host-drift.sh, on the allowlist), SHELL/PATH
	# present, FY_LIVE missing.
	cat > "$DIR2/metal-needs-fy-live" <<EOF
# host drift tripwire
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
15 5 * * * deploy bash ${REPO_ROOT}/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF

	# same side-effecting script, already fully compliant — must stay
	# byte-identical.
	cat > "$DIR2/metal-side-effect-compliant" <<EOF
# host drift tripwire
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
15 5 * * * deploy bash ${REPO_ROOT}/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF

	# real, non-side-effecting script (server-status.sh) — FY_LIVE must NOT
	# be added.
	cat > "$DIR2/metal-read-only" <<EOF
# ops dashboard refresh
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * deploy bash ${REPO_ROOT}/scripts/server-status.sh >> /var/log/server-status.log 2>&1
EOF
}
teardown2() { rm -rf "$DIR2" "$BK2"; DIR2=""; BK2=""; }
run_installer2() {
	FYD_CRON_DIR="$DIR2" FYD_BACKUP_DIR="$BK2" bash "$INSTALLER" "$@"
}

# ---- case 11: dry-run reports the FY_LIVE gap for the side-effecting file -------
setup2
OUT="$(run_installer2 --dry-run 2>&1)"
echo "$OUT" | grep -q 'would fix: metal-needs-fy-live (missing: FY_LIVE)' \
	&& ok "FY_LIVE: dry-run reports the gap for a side-effecting cron" \
	|| bad "FY_LIVE: dry-run reports the gap for a side-effecting cron (out: $OUT)"
echo "$OUT" | grep -q 'would fix: metal-read-only' \
	&& bad "FY_LIVE: dry-run does not flag the read-only cron for a fix" \
	|| ok "FY_LIVE: dry-run does not flag the read-only cron for a fix"
echo "$OUT" | grep -q 'ok:.*metal-read-only' \
	&& ok "FY_LIVE: dry-run reports the read-only cron already compliant" \
	|| bad "FY_LIVE: dry-run reports the read-only cron already compliant (out: $OUT)"
teardown2

# ---- case 12: apply adds FY_LIVE=1 to the side-effecting file only --------------
setup2
RBEFORE="$(cat "$DIR2/metal-read-only")"
run_installer2 >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "FY_LIVE: apply exit 0" \
	|| bad "FY_LIVE: apply exit 0 (actual=$RC)"
grep -qE '^FY_LIVE=1$' "$DIR2/metal-needs-fy-live" \
	&& ok "FY_LIVE: added to the side-effecting cron" \
	|| bad "FY_LIVE: added to the side-effecting cron"
[ "$(cat "$DIR2/metal-read-only")" = "$RBEFORE" ] \
	&& ok "FY_LIVE: read-only cron left byte-identical (not added)" \
	|| bad "FY_LIVE: read-only cron left byte-identical (not added)"
teardown2

# ---- case 13: already-compliant side-effecting file stays byte-identical -------
setup2
CBEFORE="$(cat "$DIR2/metal-side-effect-compliant")"
run_installer2 >/dev/null 2>&1
[ "$(cat "$DIR2/metal-side-effect-compliant")" = "$CBEFORE" ] \
	&& ok "FY_LIVE: already-compliant side-effecting cron stays byte-identical" \
	|| bad "FY_LIVE: already-compliant side-effecting cron stays byte-identical"
[ -e "$BK2/metal-side-effect-compliant" ] \
	&& bad "FY_LIVE: no backup entry for the already-compliant file" \
	|| ok "FY_LIVE: no backup entry for the already-compliant file"
teardown2

# ---- case 14: post-apply, the fixed file passes check-cron-file.sh Rule 6 ------
setup2
run_installer2 >/dev/null 2>&1
if [ -x "${REPO_ROOT}/scripts/check-cron-file.sh" ]; then
	bash "${REPO_ROOT}/scripts/check-cron-file.sh" "$DIR2/metal-needs-fy-live" >/dev/null 2>&1
	RC=$?
	[ "$RC" -eq 0 ] \
		&& ok "FY_LIVE: patched file now passes check-cron-file.sh" \
		|| bad "FY_LIVE: patched file now passes check-cron-file.sh (rc=$RC)"
else
	echo "SKIP  lint case (check-cron-file.sh not executable)"
fi
teardown2

# ---- summary ----------------------------------------------------------------------
echo "test-install-cron-env-headers.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
