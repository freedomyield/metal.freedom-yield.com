#!/usr/bin/env bash
# test-check-scripts-freshness.sh — suite for scripts/check-scripts-freshness.sh.
#
# CHAIN: none — builds throwaway local git repo pairs (bare origin + clone)
#        in a tempdir; no network, no real host checkout is touched.
#
# Usage:
#   bash tests/scripts-freshness/test-check-scripts-freshness.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-scripts-freshness.sh"

if [ ! -f "$CHECKER" ]; then
	echo "FATAL: checker not found at $CHECKER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# ---- harness -----------------------------------------------------------------
# build_pair: bare origin with one commit (scripts/ content) + clone.
BASE=""; ORIGIN=""; CLONE=""
GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)
build_pair() {
	BASE="$(mktemp -d -t scripts-freshness-test.XXXXXX)"
	ORIGIN="$BASE/origin.git"
	CLONE="$BASE/clone"

	local seed="$BASE/seed"
	mkdir -p "$seed/scripts"
	echo 'echo hello' > "$seed/scripts/a.sh"
	git -C "$seed" "${GITQ[@]}" init -q -b main
	git -C "$seed" "${GITQ[@]}" add -A
	git -C "$seed" "${GITQ[@]}" commit -qm seed

	git clone -q --bare "$seed" "$ORIGIN"
	git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
	git -C "$CLONE" "${GITQ[@]}" remote set-url origin "$ORIGIN"
}
teardown() { rm -rf "$BASE"; BASE=""; }

run_checker() {
	FYD_REPO_DIR="$CLONE" bash "$CHECKER" "$@"
}

# ---- case 1: fresh (HEAD == origin/main) → exit 0, stdout message -------------
build_pair
OUT="$(run_checker 2>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "fresh: exit 0" \
	|| bad "fresh: exit 0 (actual=$RC)"
echo "$OUT" | grep -q '^fresh: HEAD == origin/main$' \
	&& ok "fresh: stdout message" \
	|| bad "fresh: stdout message (out: $OUT)"
teardown

# ---- case 2: behind → exit 1, STALE message on stderr -------------------------
build_pair
SCRATCH="$BASE/scratch"
git clone -q "$ORIGIN" "$SCRATCH" 2>/dev/null
for i in 1 2 3; do
	echo "change $i" >> "$SCRATCH/scripts/a.sh"
	git -C "$SCRATCH" "${GITQ[@]}" commit -qam "origin-change-$i"
done
git -C "$SCRATCH" push -q origin main
ERR="$(run_checker 2>&1 1>/dev/null)"
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "behind: exit 1" \
	|| bad "behind: exit 1 (actual=$RC)"
echo "$ERR" | grep -q '^STALE: local HEAD is 3 commit(s) behind origin/main; run advance-host-checkout.sh before proceeding$' \
	&& ok "behind: STALE message with count" \
	|| bad "behind: STALE message with count (err: $ERR)"
teardown

# ---- case 3: fetch failure (origin gone) → exit 3, error on stderr ------------
build_pair
rm -rf "$ORIGIN"
ERR="$(run_checker 2>&1 1>/dev/null)"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "fetch-fail: exit 3" \
	|| bad "fetch-fail: exit 3 (actual=$RC)"
echo "$ERR" | grep -qi 'fetch' \
	&& ok "fetch-fail: stderr mentions fetch" \
	|| bad "fetch-fail: stderr mentions fetch (err: $ERR)"
teardown

# ---- case 4: read-only (never mutates the clone) -------------------------------
build_pair
SNAP="$(cat "$CLONE/scripts/a.sh")"
HEAD_BEFORE="$(git -C "$CLONE" rev-parse HEAD)"
run_checker >/dev/null 2>&1
[ "$(cat "$CLONE/scripts/a.sh")" = "$SNAP" ] && [ "$(git -C "$CLONE" rev-parse HEAD)" = "$HEAD_BEFORE" ] \
	&& ok "read-only: working tree and HEAD untouched" \
	|| bad "read-only: working tree and HEAD untouched"
teardown

# ---- summary ----------------------------------------------------------------------
echo "test-check-scripts-freshness.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
