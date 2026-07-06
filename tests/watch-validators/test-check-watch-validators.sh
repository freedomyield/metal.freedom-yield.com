#!/usr/bin/env bash
# test-check-watch-validators.sh — suite for scripts/check-watch-validators.sh
# (salvaged to the repo + repointed to the private host-local watch list,
# 2026-07-06).
#
# CHAIN: none — the explorer API is a file:// stub, the notifier is a
#        recording stub, and all paths live in a tempdir harness. No real
#        RPC / explorer / ntfy is ever touched.
#
# Usage:
#   bash tests/watch-validators/test-check-watch-validators.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-watch-validators.sh"

if [ ! -f "$CHECKER" ]; then
	echo "FATAL: checker not found at $CHECKER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

NID="NodeID-testwatch1111111111111111111111111"

BASE=""; STUB_LOG=""
setup() {
	BASE="$(mktemp -d -t watch-test.XXXXXX)"
	STUB_LOG="$BASE/notify.log"
	mkdir -p "$BASE/state"
	cat > "$BASE/notify-stub.sh" <<STUBEOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$STUB_LOG"
STUBEOF
	chmod +x "$BASE/notify-stub.sh"
	printf '[\n  "%s"\n]\n' "$NID" > "$BASE/watch-list.json"
}
teardown() { rm -rf "$BASE"; BASE=""; }

# explorer_stub <json> — write the explorer response the checker will curl.
explorer_stub() { printf '%s' "$1" > "$BASE/explorer.json"; }

run_checker() {
	WATCH_LIST_FILE="$BASE/watch-list.json" \
	WATCH_STATE_DIR="$BASE/state" \
	EXPLORER_API="file://$BASE/explorer.json" \
	WATCH_NOTIFY="$BASE/notify-stub.sh" \
	bash "$CHECKER" "$@"
}
alerts() { cat "$STUB_LOG" 2>/dev/null; }
state()  { cat "$BASE/state/watch-prev-state.json" 2>/dev/null; }

# ---- case 1: list missing → graceful no-op, no state created --------------------
setup
rm "$BASE/watch-list.json"
OUT="$(run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "no list: exit 0" \
	|| bad "no list: exit 0 (actual=$RC)"
echo "$OUT" | grep -q 'no watch list' \
	&& ok "no list: graceful message" \
	|| bad "no list: graceful message (out: $OUT)"
[ -f "$BASE/state/watch-prev-state.json" ] \
	&& bad "no list: no state written" \
	|| ok "no list: no state written"
teardown

# ---- case 2: empty/malformed list → graceful no-op --------------------------------
setup
echo '{}' > "$BASE/watch-list.json"
OUT="$(run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'watch list is empty' \
	&& ok "malformed list: graceful empty handling (exit 0)" \
	|| bad "malformed list: graceful empty handling (rc=$RC out: $OUT)"
teardown

# ---- case 3: first run = silent baseline, state persisted -------------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
OUT="$(run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "baseline: exit 0" \
	|| bad "baseline: exit 0 (actual=$RC)"
[ -s "$STUB_LOG" ] \
	&& bad "baseline: silent (no notify)" \
	|| ok "baseline: silent (no notify)"
state | jq -e --arg n "$NID" '.[$n].active == true' >/dev/null \
	&& ok "baseline: state persisted with active=true" \
	|| bad "baseline: state persisted with active=true (state: $(state))"
teardown

# ---- case 4: name_appeared → high notify -------------------------------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[{\"nodeId\": \"$NID\", \"name\": \"Acme Validator\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
alerts | grep -q "^high|Watch validator named|$NID → Acme Validator" \
	&& ok "name_appeared: high notify with name" \
	|| bad "name_appeared: high notify with name (alerts: $(alerts))"
state | jq -e --arg n "$NID" '.[$n].name == "Acme Validator"' >/dev/null \
	&& ok "name_appeared: state carries the new name" \
	|| bad "name_appeared: state carries the new name"
teardown

# ---- case 5: first_delegation → high notify -----------------------------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": [{\"x\": 1}, {\"x\": 2}]}]"
run_checker >/dev/null 2>&1
alerts | grep -q "^high|Watch validator receiving delegations|$NID now has 2 delegator" \
	&& ok "first_delegation: high notify with count" \
	|| bad "first_delegation: high notify with count (alerts: $(alerts))"
teardown

# ---- case 6: departed → default notify -----------------------------------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[]"
run_checker >/dev/null 2>&1
alerts | grep -q "^default|Watch validator left active set|$NID" \
	&& ok "departed: default notify" \
	|| bad "departed: default notify (alerts: $(alerts))"
teardown

# ---- case 7: rejoined → high notify ----------------------------------------------------
setup
explorer_stub "[]"
printf '{"%s": {"active": false}}' "$NID" > "$BASE/state/watch-prev-state.json"
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": [{\"x\": 1}]}]"
run_checker >/dev/null 2>&1
alerts | grep -q "^high|Watch validator rejoined active set|$NID" \
	&& ok "rejoined: high notify" \
	|| bad "rejoined: high notify (alerts: $(alerts))"
teardown

# ---- case 8: --dry-run detects but does not notify --------------------------------------
setup
explorer_stub "[{\"nodeId\": \"$NID\", \"delegators\": []}]"
run_checker >/dev/null 2>&1
explorer_stub "[{\"nodeId\": \"$NID\", \"name\": \"Acme\", \"delegators\": []}]"
OUT="$(run_checker --dry-run 2>&1)"
echo "$OUT" | grep -q '1 change(s) detected' \
	&& ok "dry-run: change detected and reported" \
	|| bad "dry-run: change detected and reported (out: $OUT)"
[ -s "$STUB_LOG" ] \
	&& bad "dry-run: no notify fired" \
	|| ok "dry-run: no notify fired"
teardown

# ---- summary ------------------------------------------------------------------------------
echo "test-check-watch-validators.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
