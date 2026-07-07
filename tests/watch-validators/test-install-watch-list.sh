#!/usr/bin/env bash
# test-install-watch-list.sh — suite for scripts/install-watch-list.sh.
#
# CHAIN: none — the installer runs against a tempdir via FYD_ETC_DIR
#        (root requirement waived in harness mode); /etc/freedom-yield is
#        never touched.
#
# Usage:
#   bash tests/watch-validators/test-install-watch-list.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-watch-list.sh"

if [ ! -f "$INSTALLER" ]; then
	echo "FATAL: installer not found at $INSTALLER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

N1="NodeID-aaaa1111"
N2="NodeID-bbbb2222"

DIR=""
setup() {
	DIR="$(mktemp -d -t watch-inst-test.XXXXXX)"
	printf '{"%s": {"active": true}, "%s": {"active": false}}' "$N1" "$N2" > "$DIR/state.json"
}
teardown() { rm -rf "$DIR"; DIR=""; }
run_installer() {
	FYD_ETC_DIR="$DIR/etc" FYD_STATE_FILE="$DIR/state.json" bash "$INSTALLER" "$@"
}
target() { cat "$DIR/etc/watch-list.json" 2>/dev/null; }

# ---- case 1: non-root + default etc dir → exit 2 ---------------------------------
if [ "$(id -u)" -ne 0 ]; then
	FYD_STATE_FILE=/nonexistent bash "$INSTALLER" --from-state >/dev/null 2>&1
	RC=$?
	[ "$RC" -eq 2 ] \
		&& ok "non-root + default etc dir: exit 2" \
		|| bad "non-root + default etc dir: exit 2 (actual=$RC)"
else
	echo "SKIP  non-root case (suite running as root)"
fi

# ---- case 2: --from-state recovers the state file's NodeIDs -----------------------
setup
OUT="$(run_installer --from-state 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "from-state: exit 0" \
	|| bad "from-state: exit 0 (actual=$RC)"
target | jq -e --arg a "$N1" --arg b "$N2" 'sort == ([$a, $b] | sort)' >/dev/null \
	&& ok "from-state: both NodeIDs recovered into the list" \
	|| bad "from-state: both NodeIDs recovered (target: $(target))"
echo "$OUT" | grep -q '2 NodeID(s), source: state' \
	&& ok "from-state: reports count + source" \
	|| bad "from-state: reports count + source (out: $OUT)"
teardown

# ---- case 3: --ids explicit list ----------------------------------------------------
setup
run_installer --ids="$N1, $N2" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "ids: exit 0 (whitespace tolerated)" \
	|| bad "ids: exit 0 (actual=$RC)"
target | jq -e 'length == 2' >/dev/null \
	&& ok "ids: 2 entries written" \
	|| bad "ids: 2 entries written (target: $(target))"
teardown

# ---- case 4: invalid NodeID → exit 4, nothing written ---------------------------------
setup
run_installer --ids="$N1,not-a-node-id" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 4 ] \
	&& ok "invalid id: exit 4" \
	|| bad "invalid id: exit 4 (actual=$RC)"
[ -f "$DIR/etc/watch-list.json" ] \
	&& bad "invalid id: nothing written" \
	|| ok "invalid id: nothing written"
teardown

# ---- case 5: idempotent + differing-content backup --------------------------------------
setup
run_installer --from-state >/dev/null 2>&1
SNAP="$(target)"
OUT2="$(run_installer --from-state 2>&1)"
echo "$OUT2" | grep -q 'already up to date' \
	&& ok "idempotent: second run reports up to date" \
	|| bad "idempotent: second run reports up to date (out: $OUT2)"
[ "$(target)" = "$SNAP" ] \
	&& ok "idempotent: content unchanged" \
	|| bad "idempotent: content unchanged"
run_installer --ids="$N1" >/dev/null 2>&1
BK="$(ls "$DIR/etc"/watch-list.json.bak-* 2>/dev/null | head -1)"
[ -n "$BK" ] && [ "$(cat "$BK")" = "$SNAP" ] \
	&& ok "backup: prior differing list preserved" \
	|| bad "backup: prior differing list preserved"
target | jq -e 'length == 1' >/dev/null \
	&& ok "backup: new list installed after backup" \
	|| bad "backup: new list installed after backup"
teardown

# ---- case 6: --dry-run writes nothing -----------------------------------------------------
setup
run_installer --from-state --dry-run >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "dry-run: exit 0" \
	|| bad "dry-run: exit 0 (actual=$RC)"
[ -f "$DIR/etc/watch-list.json" ] \
	&& bad "dry-run: nothing written" \
	|| ok "dry-run: nothing written"
teardown

# ---- case 7: --from-state with empty state → exit 3 ----------------------------------------
setup
echo '{}' > "$DIR/state.json"
run_installer --from-state >/dev/null 2>&1
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "empty state: exit 3" \
	|| bad "empty state: exit 3 (actual=$RC)"
teardown

# ---- case 8: no mode → exit 1 ---------------------------------------------------------------
setup
run_installer >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "no mode: exit 1" \
	|| bad "no mode: exit 1 (actual=$RC)"
teardown

# ---- case 9: generated list is consumable by the checker -------------------------------------
setup
run_installer --from-state >/dev/null 2>&1
STUB_LOG="$DIR/notify.log"
cat > "$DIR/notify-stub.sh" <<STUBEOF
#!/usr/bin/env bash
echo "\$@" >> "$STUB_LOG"
STUBEOF
chmod +x "$DIR/notify-stub.sh"
printf '[]' > "$DIR/explorer.json"
mkdir -p "$DIR/state-dir"
WATCH_LIST_FILE="$DIR/etc/watch-list.json" WATCH_STATE_DIR="$DIR/state-dir" \
	EXPLORER_API="file://$DIR/explorer.json" WATCH_NOTIFY="$DIR/notify-stub.sh" \
	EXPLORER_MIN_VALIDATORS=0 \
	bash "$REPO_ROOT/scripts/check-watch-validators.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "integration: checker consumes the installed list (exit 0)" \
	|| bad "integration: checker consumes the installed list (actual=$RC)"
jq -e 'keys | length == 2' "$DIR/state-dir/watch-prev-state.json" >/dev/null 2>&1 \
	&& ok "integration: checker baselined both watched IDs" \
	|| bad "integration: checker baselined both watched IDs"
teardown

# ---- summary -----------------------------------------------------------------------------------
echo "test-install-watch-list.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
