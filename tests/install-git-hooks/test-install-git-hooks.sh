#!/usr/bin/env bash
# test-install-git-hooks.sh — suite for scripts/install-git-hooks.sh.
#
# CHAIN: none — operates only on a throwaway tempdir git repo; never
#        touches this repo's own git config or the real .githooks/.
#
# Usage:
#   bash tests/install-git-hooks/test-install-git-hooks.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-git-hooks.sh"

if [ ! -f "$INSTALLER" ]; then
	echo "FATAL: installer not found at $INSTALLER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# ---- fixtures ----------------------------------------------------------------
WORK=""
setup() {
	WORK="$(mktemp -d -t install-git-hooks-test.XXXXXX)"
	(cd "$WORK" && git init -q)
	mkdir -p "$WORK/.githooks"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/.githooks/pre-commit"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/.githooks/pre-push"
	chmod +x "$WORK/.githooks/pre-commit" "$WORK/.githooks/pre-push"
}
teardown() {
	rm -rf "$WORK"
}

run_installer() { (cd "$WORK" && bash "$INSTALLER" "$@"); }
hookspath()     { (cd "$WORK" && git config --get core.hooksPath 2>/dev/null); }

# ---- case 1: --check before install must FAIL without mutating --------------
setup
OUT="$(run_installer --check 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "check before install: exit non-zero" \
	|| bad "check before install: exit non-zero (actual=$RC)"
[ -z "$(hookspath)" ] \
	&& ok "check before install: does not mutate core.hooksPath" \
	|| bad "check before install: does not mutate core.hooksPath (got: $(hookspath))"
teardown

# ---- case 2: default (install) mode sets core.hooksPath=.githooks -----------
setup
OUT="$(run_installer 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "install: exit 0" \
	|| bad "install: exit 0 (actual=$RC, out: $OUT)"
[ "$(hookspath)" = ".githooks" ] \
	&& ok "install: core.hooksPath = .githooks" \
	|| bad "install: core.hooksPath = .githooks (got: $(hookspath))"
teardown

# ---- case 3: idempotent — running twice is a clean no-op the second time ----
setup
run_installer >/dev/null 2>&1
run_installer >/dev/null 2>&1
RC2=$?
[ "$RC2" -eq 0 ] \
	&& ok "idempotent: second install run exit 0" \
	|| bad "idempotent: second install run exit 0 (actual=$RC2)"
[ "$(hookspath)" = ".githooks" ] \
	&& ok "idempotent: core.hooksPath still .githooks after second run" \
	|| bad "idempotent: core.hooksPath still .githooks after second run (got: $(hookspath))"
teardown

# ---- case 4: --check after install must PASS ---------------------------------
setup
run_installer >/dev/null 2>&1
OUT="$(run_installer --check 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "check after install: exit 0" \
	|| bad "check after install: exit 0 (actual=$RC, out: $OUT)"
teardown

# ---- case 5: missing .githooks/ dir must FAIL, not crash --------------------
setup
rm -rf "$WORK/.githooks"
OUT="$(run_installer 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "missing .githooks/: exit non-zero" \
	|| bad "missing .githooks/: exit non-zero (actual=$RC)"
[ -z "$(hookspath)" ] \
	&& ok "missing .githooks/: does not set core.hooksPath" \
	|| bad "missing .githooks/: does not set core.hooksPath (got: $(hookspath))"
teardown

# ---- case 6: outside a git repo must FAIL gracefully (no crash) -------------
NOGIT="$(mktemp -d -t install-git-hooks-nogit.XXXXXX)"
OUT="$(cd "$NOGIT" && bash "$INSTALLER" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "outside git repo: exit non-zero" \
	|| bad "outside git repo: exit non-zero (actual=$RC)"
rm -rf "$NOGIT"

# ---- summary ----------------------------------------------------------------------
echo "test-install-git-hooks.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
