#!/usr/bin/env bash
# test-watch-anchor-events.sh — suite for scripts/watch-anchor-events.sh,
# focused on R5 (2026-07-08): a validator-presence transition must NOT
# advance the watcher's state file (anchor-watcher-state.json) unless the
# dispatch driver CONFIRMS delivery (exit 0, or exit 2 = nothing-to-do).
#
# Without this gate, a transient ntfy failure at a cycle boundary silently
# and PERMANENTLY drops the once-per-cycle "run the manual anchor" signal:
# the old code wrote is_present unconditionally, so a failed dispatch this
# tick made the next tick's prior-state == this tick's real state, and the
# transition could never be re-detected.
#
# CHAIN: none — curl is a PATH-stubbed script that answers from a local
# control file (never touches a real metalgo RPC), and the dispatch driver
# is a controllable stub (never notify-anchor-transition.sh / notify.sh /
# real ntfy). All state lives under a per-test tempdir via FY_STATE_DIR.
#
# Usage:
#   bash tests/watch-anchor-events/test-watch-anchor-events.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WATCHER="${REPO}/scripts/watch-anchor-events.sh"

if [ ! -x "$WATCHER" ]; then
	echo "FATAL: watcher not found or not executable at $WATCHER" >&2
	exit 1
fi

PASS=0
FAIL=0
FAILURES=()
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); echo "FAIL  $1"; }

NODE_ID="NodeID-testwatchanchor1111111111111111111"

TMP="$(mktemp -d -t watch-anchor-events.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/state"
STATE_DIR="$TMP/state"
STATE_FILE="$STATE_DIR/anchor-watcher-state.json"

# --- stub curl: answers the getCurrentValidators POST from a control file,
# ignoring the actual request body/URL (the watcher only cares about the
# response shape). Present iff $RPC_PRESENT_FILE contains "1".
cat > "$TMP/bin/curl" <<'CURLEOF'
#!/usr/bin/env bash
present="0"
[ -f "$RPC_PRESENT_FILE" ] && present="$(cat "$RPC_PRESENT_FILE")"
if [ "$present" = "1" ]; then
	printf '{"jsonrpc":"2.0","id":1,"result":{"validators":[{"nodeID":"%s"}]}}' "$RPC_NODE_ID"
else
	printf '{"jsonrpc":"2.0","id":1,"result":{"validators":[]}}'
fi
CURLEOF
chmod +x "$TMP/bin/curl"

set_present() { echo "$1" > "$TMP/rpc-present"; }

# --- stub driver: exit code controlled by $DRIVER_EXIT_FILE (default 0);
# every invocation appends one line to $DRIVER_LOG.
cat > "$TMP/bin/driver.sh" <<'DRIVEREOF'
#!/usr/bin/env bash
echo "$*" >> "$DRIVER_LOG"
code=0
[ -f "$DRIVER_EXIT_FILE" ] && code="$(cat "$DRIVER_EXIT_FILE")"
exit "$code"
DRIVEREOF
chmod +x "$TMP/bin/driver.sh"

DRIVER_LOG="$TMP/driver-calls.log"
DRIVER_EXIT_FILE="$TMP/driver-exit-code"
: > "$DRIVER_LOG"

set_driver_exit() { echo "$1" > "$DRIVER_EXIT_FILE"; }
driver_calls() { wc -l < "$DRIVER_LOG" | tr -d ' '; }

# FY_LIVE=1 on every case, including the --dry-run one. Since the C3 rollout
# (2026-08-06) a dry FY_LIVE suppresses the state write by itself, so the R5
# assertions below ("state NOT advanced", "state advances once confirmed")
# would stop measuring the driver-confirmation logic they exist to protect and
# start measuring the library's gate. The dry side is covered separately by
# tests/side-effects-callers/test-anchor-cycle-side-effects.sh.
run_watcher() {
	PATH="$TMP/bin:$PATH" \
	FY_LIVE=1 \
	NODE_ID="$NODE_ID" \
	METALGO_RPC="http://stub-metalgo" \
	FY_STATE_DIR="$STATE_DIR" \
	ANCHOR_DRIVER="$TMP/bin/driver.sh" \
	RPC_PRESENT_FILE="$TMP/rpc-present" \
	RPC_NODE_ID="$NODE_ID" \
	DRIVER_LOG="$DRIVER_LOG" \
	DRIVER_EXIT_FILE="$DRIVER_EXIT_FILE" \
	bash "$WATCHER" "$@"
}

state_is_present() { jq -r '.is_present' "$STATE_FILE" 2>/dev/null; }
state_last_event()  { jq -r '.last_event'  "$STATE_FILE" 2>/dev/null; }

# ---- case 1: first run — no prior state, no transition inferred, driver not invoked ----
set_present 0
RC=0; run_watcher >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && ok "first run: exit 0" || bad "first run: exit 0 (actual=$RC)"
[ "$(driver_calls)" -eq 0 ] && ok "first run: driver not invoked (no transition possible)" \
	|| bad "first run: driver not invoked (calls=$(driver_calls))"
[ "$(state_is_present)" = "0" ] && ok "first run: state records is_present=0" \
	|| bad "first run: state records is_present=0 (actual=$(state_is_present))"

# ---- case 2 (R5 core): transition + driver cannot confirm delivery → state NOT advanced ----
set_present 1
set_driver_exit 5   # simulate notify-anchor-transition.sh's "failed to confirm delivery"
RC=0; run_watcher >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] && ok "R5: unconfirmed dispatch → watcher exit 4" \
	|| bad "R5: unconfirmed dispatch → watcher exit 4 (actual=$RC)"
[ "$(driver_calls)" -eq 1 ] && ok "R5: driver invoked once on the transition" \
	|| bad "R5: driver invoked once on the transition (calls=$(driver_calls))"
[ "$(state_is_present)" = "0" ] && ok "R5: state NOT advanced (is_present stays 0)" \
	|| bad "R5: state NOT advanced (is_present stays 0) (actual=$(state_is_present))"

# ---- case 3 (R5 core): real state unchanged, driver still failing → SAME transition retried ----
# (present is still 1; state still says 0 from case 2, so this is a fresh
# poll re-detecting the identical cyclestart transition.)
RC=0; run_watcher >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] && ok "R5 retry: still unconfirmed → watcher exit 4 again" \
	|| bad "R5 retry: still unconfirmed → watcher exit 4 again (actual=$RC)"
[ "$(driver_calls)" -eq 2 ] && ok "R5 retry: driver invoked AGAIN next poll (was NOT permanently dropped)" \
	|| bad "R5 retry: driver invoked AGAIN next poll (calls=$(driver_calls))"
[ "$(state_is_present)" = "0" ] && ok "R5 retry: state still NOT advanced" \
	|| bad "R5 retry: state still NOT advanced (actual=$(state_is_present))"

# ---- case 4 (R5 core): driver now confirms delivery → state advances, signal delivered ----
set_driver_exit 0
RC=0; run_watcher >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && ok "R5 recovery: confirmed dispatch → watcher exit 0" \
	|| bad "R5 recovery: confirmed dispatch → watcher exit 0 (actual=$RC)"
[ "$(driver_calls)" -eq 3 ] && ok "R5 recovery: driver invoked a 3rd time (this poll)" \
	|| bad "R5 recovery: driver invoked a 3rd time (calls=$(driver_calls))"
[ "$(state_is_present)" = "1" ] && ok "R5 recovery: state advances to is_present=1 once confirmed" \
	|| bad "R5 recovery: state advances to is_present=1 once confirmed (actual=$(state_is_present))"
[ "$(state_last_event)" = "cyclestart" ] && ok "R5 recovery: last_event recorded as cyclestart" \
	|| bad "R5 recovery: last_event recorded as cyclestart (actual=$(state_last_event))"

# ---- case 5: no further transition → driver not re-invoked, state stays settled ----
RC=0; run_watcher >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && ok "settled: exit 0" || bad "settled: exit 0 (actual=$RC)"
[ "$(driver_calls)" -eq 3 ] && ok "settled: driver not re-invoked absent a new transition" \
	|| bad "settled: driver not re-invoked absent a new transition (calls=$(driver_calls))"
[ "$(state_is_present)" = "1" ] && ok "settled: is_present stays 1" \
	|| bad "settled: is_present stays 1 (actual=$(state_is_present))"

# ---- case 6: transition + driver exit 2 ("nothing to do") is CONFIRMED, state advances ----
# Mirrors notify-anchor-transition.sh's own exit 2 (unrecognized/missing
# --event-type never happens from this caller, but the watcher's contract
# treats 2 as an OK/no-op outcome, not a failed dispatch).
set_present 0
set_driver_exit 2
RC=0; run_watcher >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && ok "driver exit 2: treated as confirmed → watcher exit 0" \
	|| bad "driver exit 2: treated as confirmed → watcher exit 0 (actual=$RC)"
[ "$(state_is_present)" = "0" ] && ok "driver exit 2: state advances (cycleend recorded)" \
	|| bad "driver exit 2: state advances (cycleend recorded) (actual=$(state_is_present))"

# ---- case 7: --dry-run never invokes the driver and never writes state ----
CALLS_BEFORE="$(driver_calls)"
set_present 1
OUT="$(run_watcher --dry-run 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && ok "dry-run: exit 0" || bad "dry-run: exit 0 (actual=$RC)"
echo "$OUT" | grep -qi 'DRY-RUN' && ok "dry-run: prints intent" \
	|| bad "dry-run: prints intent (out: $OUT)"
[ "$(driver_calls)" -eq "$CALLS_BEFORE" ] && ok "dry-run: driver not invoked" \
	|| bad "dry-run: driver not invoked (calls before=$CALLS_BEFORE after=$(driver_calls))"
[ "$(state_is_present)" = "0" ] && ok "dry-run: state file untouched" \
	|| bad "dry-run: state file untouched (actual=$(state_is_present))"

# ---- summary ------------------------------------------------------------
echo "test-watch-anchor-events.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
for f in "${FAILURES[@]}"; do echo "  - $f"; done
exit 1
