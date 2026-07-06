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
echo "$OUT2" | grep -q 'summary: fixed 0, already compliant 4' \
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
	grep -qE '^SHELL=/bin/bash\b' "$f" && grep -qE '^PATH=' "$f" || ALL_OK=0
done
[ "$ALL_OK" = "1" ] \
	&& ok "post-edit: every metal-* file carries both headers (rule 5)" \
	|| bad "post-edit: every metal-* file carries both headers (rule 5)"
teardown

# ---- case 9: unknown arg → exit 1 -------------------------------------------------
setup
run_installer --bogus >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "arg: unknown flag → exit 1" \
	|| bad "arg: unknown flag → exit 1 (actual=$RC)"
teardown

# ---- summary ----------------------------------------------------------------------
echo "test-install-cron-env-headers.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
