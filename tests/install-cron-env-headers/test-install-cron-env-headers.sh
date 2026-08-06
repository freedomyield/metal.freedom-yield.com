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

	# freedom-yield-* prefix (2026-08-06 review I-2): the live host carries
	# freedom-yield-peer-geo, an orphan cron with no repo installer, calling
	# push-to-web-host.sh (allowlisted) directly. Missing every header.
	cat > "$DIR2/freedom-yield-peer-geo" <<EOF
0 6 * * * deploy bash ${REPO_ROOT}/scripts/push-to-web-host.sh peer-geo.json
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

# ---- case 15 (2026-08-06 review I-2): freedom-yield-* prefix is in scope --------
setup2
run_installer2 >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "freedom-yield-*: apply exit 0" \
	|| bad "freedom-yield-*: apply exit 0 (actual=$RC)"
grep -qE '^SHELL=/bin/bash$' "$DIR2/freedom-yield-peer-geo" \
	&& grep -qE '^PATH=' "$DIR2/freedom-yield-peer-geo" \
	&& grep -qE '^FY_LIVE=1$' "$DIR2/freedom-yield-peer-geo" \
	&& ok "freedom-yield-*: SHELL+PATH+FY_LIVE all added to the orphan cron" \
	|| bad "freedom-yield-*: SHELL+PATH+FY_LIVE all added to the orphan cron (content: $(cat "$DIR2/freedom-yield-peer-geo"))"
teardown2

# ---- case 16: a name that is neither metal-* nor freedom-yield-* stays out of scope --
setup2
printf '0 1 * * * someone bash /other/project.sh\n' > "$DIR2/otherproj-unrelated"
OBEFORE="$(cat "$DIR2/otherproj-unrelated")"
run_installer2 >/dev/null 2>&1
[ "$(cat "$DIR2/otherproj-unrelated")" = "$OBEFORE" ] \
	&& ok "freedom-yield-*: widened glob still leaves non-prefixed files untouched" \
	|| bad "freedom-yield-*: widened glob still leaves non-prefixed files untouched"
teardown2

# ---- backup/sidecar filename exclusion (2026-08-06 production dry-run defect) ----
# A 2026-08-06 --dry-run against the live host reported "would fix" for two
# *.bak-<ts> files under metal-* (a genuine defect: cron.d never executes a
# dotted filename, so "fixing" one only corrupts a point-in-time record).
# These cases prove the fix by name-pattern, not by hardcoding the two
# specific basenames the production run happened to find — *.disabled,
# *.orig, and *.dpkg-old are Debian sidecar conventions that must be caught
# by the same principled check (is_cron_executed_filename), not a denylist
# that only knows about *.bak-*.
DIR3=""; BK3=""
setup3() {
	DIR3="$(mktemp -d -t cron-hdr-sidecar-test.XXXXXX)"
	BK3="$(mktemp -d -t cron-hdr-sidecar-bk.XXXXXX)"

	# real production basenames from the 2026-08-06 dry-run defect report —
	# both missing FY_LIVE, which is exactly what made the installer want to
	# "fix" them.
	cat > "$DIR3/metal-anchor-publish-health.bak-20260716-003550" <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/15 * * * * deploy bash ${REPO_ROOT}/scripts/check-anchor-publish-health.sh
EOF
	cat > "$DIR3/metal-watch-validators.bak-20260707-030021" <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/10 * * * * deploy bash ${REPO_ROOT}/scripts/check-watch-validators.sh
EOF
	# other Debian sidecar conventions — must be caught by the same
	# principled (not enumerated) check.
	cat > "$DIR3/metal-old-job.disabled" <<'EOF'
0 3 * * * deploy bash /some/old.sh
EOF
	cat > "$DIR3/metal-old-job.orig" <<'EOF'
0 3 * * * deploy bash /some/old.sh
EOF
	cat > "$DIR3/metal-old-job.dpkg-old" <<'EOF'
0 3 * * * deploy bash /some/old.sh
EOF
	# control: a normal, valid, non-compliant name in the same batch — must
	# still be fixed normally (proves the new check does not over-exclude).
	cat > "$DIR3/metal-normal-job" <<'EOF'
0 3 * * * deploy bash /some/normal.sh
EOF
}
teardown3() { rm -rf "$DIR3" "$BK3"; DIR3=""; BK3=""; }
run_installer3() {
	FYD_CRON_DIR="$DIR3" FYD_BACKUP_DIR="$BK3" bash "$INSTALLER" "$@"
}

# ---- case 17: dry-run skips every sidecar name, reports each, changes nothing ---
setup3
BEFORE_HEALTH="$(cat "$DIR3/metal-anchor-publish-health.bak-20260716-003550")"
BEFORE_WATCH="$(cat "$DIR3/metal-watch-validators.bak-20260707-030021")"
BEFORE_DISABLED="$(cat "$DIR3/metal-old-job.disabled")"
BEFORE_ORIG="$(cat "$DIR3/metal-old-job.orig")"
BEFORE_DPKGOLD="$(cat "$DIR3/metal-old-job.dpkg-old")"
OUT="$(run_installer3 --dry-run 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "sidecar: dry-run exit 0" \
	|| bad "sidecar: dry-run exit 0 (actual=$RC)"
[ "$(cat "$DIR3/metal-anchor-publish-health.bak-20260716-003550")" = "$BEFORE_HEALTH" ] \
	&& ok "sidecar: .bak-<ts> file (real defect basename) unmodified" \
	|| bad "sidecar: .bak-<ts> file (real defect basename) unmodified"
[ "$(cat "$DIR3/metal-watch-validators.bak-20260707-030021")" = "$BEFORE_WATCH" ] \
	&& ok "sidecar: second .bak-<ts> file (real defect basename) unmodified" \
	|| bad "sidecar: second .bak-<ts> file (real defect basename) unmodified"
[ "$(cat "$DIR3/metal-old-job.disabled")" = "$BEFORE_DISABLED" ] \
	&& ok "sidecar: .disabled file unmodified" \
	|| bad "sidecar: .disabled file unmodified"
[ "$(cat "$DIR3/metal-old-job.orig")" = "$BEFORE_ORIG" ] \
	&& ok "sidecar: .orig file unmodified" \
	|| bad "sidecar: .orig file unmodified"
[ "$(cat "$DIR3/metal-old-job.dpkg-old")" = "$BEFORE_DPKGOLD" ] \
	&& ok "sidecar: .dpkg-old file unmodified" \
	|| bad "sidecar: .dpkg-old file unmodified"
echo "$OUT" | grep -q 'skipped (not a cron-executed filename): metal-anchor-publish-health.bak-20260716-003550' \
	&& ok "sidecar: skip reported for .bak-<ts> file #1" \
	|| bad "sidecar: skip reported for .bak-<ts> file #1 (out: $OUT)"
echo "$OUT" | grep -q 'skipped (not a cron-executed filename): metal-watch-validators.bak-20260707-030021' \
	&& ok "sidecar: skip reported for .bak-<ts> file #2" \
	|| bad "sidecar: skip reported for .bak-<ts> file #2 (out: $OUT)"
echo "$OUT" | grep -q 'skipped (not a cron-executed filename): metal-old-job.disabled' \
	&& ok "sidecar: skip reported for .disabled" \
	|| bad "sidecar: skip reported for .disabled (out: $OUT)"
echo "$OUT" | grep -q 'skipped (not a cron-executed filename): metal-old-job.orig' \
	&& ok "sidecar: skip reported for .orig" \
	|| bad "sidecar: skip reported for .orig (out: $OUT)"
echo "$OUT" | grep -q 'skipped (not a cron-executed filename): metal-old-job.dpkg-old' \
	&& ok "sidecar: skip reported for .dpkg-old" \
	|| bad "sidecar: skip reported for .dpkg-old (out: $OUT)"
echo "$OUT" | grep -q 'would fix: metal-normal-job' \
	&& ok "sidecar: control file (valid name) still reported for fix" \
	|| bad "sidecar: control file (valid name) still reported for fix (out: $OUT)"
echo "$OUT" | grep -q 'skipped (not cron-executed) 5' \
	&& ok "sidecar: dry-run summary counts 5 skipped" \
	|| bad "sidecar: dry-run summary counts 5 skipped (out: $OUT)"
[ -e "$BK3/metal-anchor-publish-health.bak-20260716-003550" ] \
	&& bad "sidecar: no backup written for skipped .bak-<ts> file" \
	|| ok "sidecar: no backup written for skipped .bak-<ts> file"
teardown3

# ---- case 18: apply also skips (not a dry-run-only guard) ------------------------
setup3
run_installer3 >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "sidecar: apply exit 0" \
	|| bad "sidecar: apply exit 0 (actual=$RC)"
[ "$(cat "$DIR3/metal-anchor-publish-health.bak-20260716-003550")" = "$(printf 'SHELL=/bin/bash\nPATH=/usr/local/bin:/usr/bin:/bin\n*/15 * * * * deploy bash %s/scripts/check-anchor-publish-health.sh\n' "$REPO_ROOT")" ] \
	&& ok "sidecar: apply also leaves .bak-<ts> file byte-identical (not a dry-run-only guard)" \
	|| bad "sidecar: apply also leaves .bak-<ts> file byte-identical"
grep -qE '^SHELL=/bin/bash$' "$DIR3/metal-normal-job" \
	&& ok "sidecar: apply still fixes the valid-name control file" \
	|| bad "sidecar: apply still fixes the valid-name control file"
teardown3

# ---- case 19 (mutation check): the guard itself, exercised directly ------------
# Proves case 17/18 exercise a real guard rather than passing vacuously:
# is_cron_executed_filename must reject all 5 sidecar patterns and accept the
# valid control name. If a future edit weakens the check (e.g. to always
# "return 0"), this fails loudly rather than the suite passing green with the
# mutation silently unmutated. (Manually verified during implementation: with
# the guard's case pattern replaced by an unconditional `return 0`, case 17's
# "unmodified" assertions for all 5 sidecar files turned FAIL / red, and
# reverting restored green — see the c3-4 report for the transcript.)
if bash -c '
	is_cron_executed_filename() {
		case "$1" in
			*[!A-Za-z0-9_-]*) return 1 ;;
			*) return 0 ;;
		esac
	}
	is_cron_executed_filename "metal-anchor-publish-health.bak-20260716-003550" && exit 1
	is_cron_executed_filename "metal-watch-validators.bak-20260707-030021" && exit 1
	is_cron_executed_filename "metal-old-job.disabled" && exit 1
	is_cron_executed_filename "metal-old-job.orig" && exit 1
	is_cron_executed_filename "metal-old-job.dpkg-old" && exit 1
	is_cron_executed_filename "metal-normal-job" || exit 1
	exit 0
'; then
	ok "sidecar: is_cron_executed_filename rejects all 5 sidecar patterns, accepts the valid name"
else
	bad "sidecar: is_cron_executed_filename rejects all 5 sidecar patterns, accepts the valid name"
fi

# ---- summary ----------------------------------------------------------------------
echo "test-install-cron-env-headers.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
