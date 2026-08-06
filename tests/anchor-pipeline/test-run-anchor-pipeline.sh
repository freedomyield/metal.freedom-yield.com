#!/usr/bin/env bash
# test-run-anchor-pipeline.sh — e2e wiring suite for scripts/run-anchor-pipeline.sh
# (design-stocktake #7: the 2026-07-04 production troubles were all
# integration/wiring/ordering failures that per-script unit suites cannot see).
#
# CHAIN: none — the REAL orchestrator runs against STUB sub-scripts. No RPC,
#        no signer, no broadcast path is ever reachable: the five pipeline
#        steps (Task 4 adds the freshness-gate preflight to the original
#        four) are replaced by recording stubs inside an isolated tempdir
#        harness (the orchestrator derives REPO_ROOT from its own location,
#        so copying it into the harness redirects every sub-script call).
#        The bypass alert is likewise a recording stub (FYD_NOTIFY) — no
#        real notifier is ever invoked.
#
# Shape: 13 scenario blocks (case 1..13) carrying runtime assertions — the
# summary line's PASS count tallies assertions, not scenarios.
#
# What this covers that the unit suites do not:
#   - argument forwarding across step boundaries (--chain/--testnet-tx-id/
#     --non-interactive → sign; --trigger/--prev-anchor-tx-id → receipt;
#     --event-type/--key-seq → append)
#   - fail-fast ordering (a failing step stops the pipeline; later steps
#     must NOT be invoked)
#   - exit-code mapping (step N failure → exit 10+N)
#   - tx_id propagation (sign stdout JSON → pipeline stdout)
#   - --skip-source-refresh contract (skips step 1 iff anchor-source exists)
#   - freshness gate (Task 4): stale (exit 1) and fetch-failed (exit 3) both
#     fail-closed and abort before any anchor generation; fresh (exit 0)
#     proceeds; FYD_ALLOW_STALE_PIPELINE=1 bypasses the gate and fires an
#     alert high
#
# Usage:
#   bash tests/anchor-pipeline/test-run-anchor-pipeline.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ORCH="${REPO_ROOT}/scripts/run-anchor-pipeline.sh"

if [ ! -f "$ORCH" ]; then
	echo "FATAL: orchestrator not found at $ORCH" >&2
	exit 1
fi

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# ---- harness ---------------------------------------------------------------
# build_harness: fresh tempdir with the REAL orchestrator + 5 recording stubs
# (Task 4 adds check-scripts-freshness to the original 4 pipeline steps, as
# the fail-closed preflight gate). Stubs append their name to calls/order.log
# and dump "$@" to calls/<name>.args. A stub fails (exit 1) iff the marker
# file fail-<name> exists in the harness root. The sign stub emits the JSON
# contract the orchestrator consumes; the freshness stub additionally honors
# a fetchfail-check-scripts-freshness marker (exit 3), mirroring
# check-scripts-freshness.sh's real exit-code contract (0=fresh/1=stale/
# 3=fetch-failed).
HARNESS=""
NOTIFY_STUB=""
NOTIFY_LOG=""
build_harness() {
	HARNESS="$(mktemp -d -t anchor-pipe-e2e.XXXXXX)"
	mkdir -p "$HARNESS/scripts/lib" "$HARNESS/public/api" "$HARNESS/calls"
	cp "$ORCH" "$HARNESS/scripts/run-anchor-pipeline.sh"
	# The orchestrator sources the side-effects library relative to its own
	# location, so the harness needs the REAL one (not a stub — the point of
	# an isolated harness is that the code under test is unmodified).
	cp "${REPO_ROOT}/scripts/lib/side-effects.sh" "$HARNESS/scripts/lib/side-effects.sh"

	local name
	for name in check-scripts-freshness gen-anchor-source sign-anchor-event gen-anchor-receipt append-anchor-history; do
		cat > "$HARNESS/scripts/${name}.sh" <<STUB
#!/usr/bin/env bash
ROOT="\$(cd "\$(dirname "\$0")/.." && pwd)"
echo "${name}" >> "\$ROOT/calls/order.log"
printf '%s\n' "\$@" > "\$ROOT/calls/${name}.args"
[ -e "\$ROOT/fail-${name}" ] && exit 1
STUB
		# The sign stub must emit the tx_id JSON contract on stdout, and the
		# gen stub must materialize anchor-source.json like the real step 1.
		if [ "$name" = "sign-anchor-event" ]; then
			echo 'printf "{\"tx_id\": \"feedc0de%s\"}\n" "77"' >> "$HARNESS/scripts/${name}.sh"
		fi
		if [ "$name" = "gen-anchor-source" ]; then
			echo 'echo "{}" > "$ROOT/public/api/anchor-source.json"' >> "$HARNESS/scripts/${name}.sh"
		fi
		if [ "$name" = "check-scripts-freshness" ]; then
			echo '[ -e "$ROOT/fetchfail-check-scripts-freshness" ] && exit 3' >> "$HARNESS/scripts/${name}.sh"
			# Mimics the REAL check-scripts-freshness.sh's success-path stdout
			# ("fresh: HEAD == origin/main" on stdout, exit 0) so the harness
			# can catch a regression where the orchestrator forgets to keep
			# that message off its own stdout (which must carry ONLY the
			# tx_id — see case 1/12's exact-match OUT assertions below).
			echo 'echo "fresh: HEAD == origin/main"' >> "$HARNESS/scripts/${name}.sh"
		fi
		echo 'exit 0' >> "$HARNESS/scripts/${name}.sh"
	done

	# notify stub for the Task 4 freshness-gate bypass alert — records
	# priority|title|message lines, mirroring tests/host-advance's pattern.
	NOTIFY_STUB="$HARNESS/notify-stub.sh"
	NOTIFY_LOG="$HARNESS/notify.log"
	cat > "$NOTIFY_STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$(dirname "$0")/notify.log"
STUBEOF
	chmod +x "$NOTIFY_STUB"
}

destroy_harness() {
	[ -n "$HARNESS" ] && rm -rf "$HARNESS"
	HARNESS=""
	NOTIFY_STUB=""
	NOTIFY_LOG=""
}

order_log()  { cat "$HARNESS/calls/order.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
args_of()    { cat "$HARNESS/calls/$1.args" 2>/dev/null; }
was_called() { [ -f "$HARNESS/calls/$1.args" ]; }
notify_log() { cat "$NOTIFY_LOG" 2>/dev/null; }

# ---- case 1: happy path — 4 steps in order, exit 0, tx_id on stdout --------
build_harness
OUT="$(bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a 2>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "happy path: exit 0" \
	|| bad "happy path: exit 0 (actual=$RC)"
[ "$OUT" = "feedc0de77" ] \
	&& ok "happy path: tx_id propagated to stdout" \
	|| bad "happy path: tx_id propagated to stdout (actual='$OUT')"
[ "$(order_log)" = "check-scripts-freshness gen-anchor-source sign-anchor-event gen-anchor-receipt append-anchor-history" ] \
	&& ok "happy path: 4 steps invoked in pipeline order" \
	|| bad "happy path: 4 steps invoked in pipeline order (actual='$(order_log)')"
destroy_harness

# ---- case 2: arg forwarding to each step ------------------------------------
build_harness
bash "$HARNESS/scripts/run-anchor-pipeline.sh" \
	--chain=testnet-a \
	--testnet-tx-id=abc123 \
	--non-interactive \
	--trigger=cyclestart \
	--prev-anchor-tx-id=deadbeef \
	--event-type=cyclestart \
	--key-seq=3 \
	>/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "forwarding run: exit 0" \
	|| bad "forwarding run: exit 0 (actual=$RC)"
SIGN_ARGS="$(args_of sign-anchor-event)"
echo "$SIGN_ARGS" | grep -q -- '--chain=testnet-a' \
	&& ok "forwarding: --chain reaches sign step" \
	|| bad "forwarding: --chain reaches sign step (args: $SIGN_ARGS)"
echo "$SIGN_ARGS" | grep -q -- '--testnet-tx-id=abc123' \
	&& ok "forwarding: --testnet-tx-id reaches sign step" \
	|| bad "forwarding: --testnet-tx-id reaches sign step"
echo "$SIGN_ARGS" | grep -q -- '--non-interactive' \
	&& ok "forwarding: --non-interactive reaches sign step" \
	|| bad "forwarding: --non-interactive reaches sign step"
RECEIPT_ARGS="$(args_of gen-anchor-receipt)"
echo "$RECEIPT_ARGS" | grep -q -- '--trigger=cyclestart' \
	&& ok "forwarding: --trigger reaches receipt step" \
	|| bad "forwarding: --trigger reaches receipt step (args: $RECEIPT_ARGS)"
echo "$RECEIPT_ARGS" | grep -q -- '--prev-anchor-tx-id=deadbeef' \
	&& ok "forwarding: --prev-anchor-tx-id reaches receipt step" \
	|| bad "forwarding: --prev-anchor-tx-id reaches receipt step"
APPEND_ARGS="$(args_of append-anchor-history)"
echo "$APPEND_ARGS" | grep -q -- '--event-type=cyclestart' \
	&& ok "forwarding: --event-type reaches append step" \
	|| bad "forwarding: --event-type reaches append step (args: $APPEND_ARGS)"
echo "$APPEND_ARGS" | grep -q -- '--key-seq=3' \
	&& ok "forwarding: --key-seq reaches append step" \
	|| bad "forwarding: --key-seq reaches append step"
destroy_harness

# ---- case 3: --skip-source-refresh with anchor-source present --------------
build_harness
echo '{}' > "$HARNESS/public/api/anchor-source.json"
bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a --skip-source-refresh >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "skip-refresh(present): exit 0" \
	|| bad "skip-refresh(present): exit 0 (actual=$RC)"
was_called gen-anchor-source \
	&& bad "skip-refresh(present): gen-anchor-source must NOT be invoked" \
	|| ok "skip-refresh(present): gen-anchor-source not invoked"
was_called sign-anchor-event \
	&& ok "skip-refresh(present): sign step still runs" \
	|| bad "skip-refresh(present): sign step still runs"
destroy_harness

# ---- case 4: --skip-source-refresh with anchor-source MISSING → exit 11 ----
build_harness
bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a --skip-source-refresh >/dev/null 2>&1
RC=$?
[ "$RC" -eq 11 ] \
	&& ok "skip-refresh(missing): exit 11" \
	|| bad "skip-refresh(missing): exit 11 (actual=$RC)"
was_called sign-anchor-event \
	&& bad "skip-refresh(missing): sign must NOT be invoked" \
	|| ok "skip-refresh(missing): sign not invoked"
destroy_harness

# ---- case 5: step-1 failure → exit 11, steps 2-4 not invoked ----------------
build_harness
touch "$HARNESS/fail-gen-anchor-source"
bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a >/dev/null 2>&1
RC=$?
[ "$RC" -eq 11 ] \
	&& ok "step-1 fail: exit 11" \
	|| bad "step-1 fail: exit 11 (actual=$RC)"
[ "$(order_log)" = "check-scripts-freshness gen-anchor-source" ] \
	&& ok "step-1 fail: later steps not invoked" \
	|| bad "step-1 fail: later steps not invoked (order='$(order_log)')"
destroy_harness

# ---- case 6: step-2 failure → exit 12, steps 3-4 not invoked ----------------
build_harness
touch "$HARNESS/fail-sign-anchor-event"
bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a >/dev/null 2>&1
RC=$?
[ "$RC" -eq 12 ] \
	&& ok "step-2 fail: exit 12" \
	|| bad "step-2 fail: exit 12 (actual=$RC)"
[ "$(order_log)" = "check-scripts-freshness gen-anchor-source sign-anchor-event" ] \
	&& ok "step-2 fail: receipt/append not invoked" \
	|| bad "step-2 fail: receipt/append not invoked (order='$(order_log)')"
destroy_harness

# ---- case 7: step-3 failure → exit 13, step 4 not invoked -------------------
build_harness
touch "$HARNESS/fail-gen-anchor-receipt"
bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a >/dev/null 2>&1
RC=$?
[ "$RC" -eq 13 ] \
	&& ok "step-3 fail: exit 13" \
	|| bad "step-3 fail: exit 13 (actual=$RC)"
[ "$(order_log)" = "check-scripts-freshness gen-anchor-source sign-anchor-event gen-anchor-receipt" ] \
	&& ok "step-3 fail: append not invoked" \
	|| bad "step-3 fail: append not invoked (order='$(order_log)')"
destroy_harness

# ---- case 8: step-4 failure → exit 14 ---------------------------------------
build_harness
touch "$HARNESS/fail-append-anchor-history"
bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a >/dev/null 2>&1
RC=$?
[ "$RC" -eq 14 ] \
	&& ok "step-4 fail: exit 14" \
	|| bad "step-4 fail: exit 14 (actual=$RC)"
destroy_harness

# ---- case 9: arg validation --------------------------------------------------
build_harness
bash "$HARNESS/scripts/run-anchor-pipeline.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "arg: missing --chain → exit 1" \
	|| bad "arg: missing --chain → exit 1 (actual=$RC)"
[ -f "$HARNESS/calls/order.log" ] \
	&& bad "arg: missing --chain must invoke no step" \
	|| ok "arg: missing --chain invokes no step"
bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a --bogus-flag >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "arg: unknown flag → exit 1" \
	|| bad "arg: unknown flag → exit 1 (actual=$RC)"
destroy_harness

# ---- case 10: freshness gate STALE (checker exit 1) → abort, nothing generated ---
# Task 4: check-scripts-freshness.sh reporting stale must fail-closed the
# pipeline before any anchor generation/sign/broadcast step runs.
build_harness
touch "$HARNESS/fail-check-scripts-freshness"
bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a >/dev/null 2>&1
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "freshness stale: non-zero exit" \
	|| bad "freshness stale: non-zero exit (actual=$RC)"
[ "$(order_log)" = "check-scripts-freshness" ] \
	&& ok "freshness stale: only the freshness checker was invoked" \
	|| bad "freshness stale: only the freshness checker was invoked (order='$(order_log)')"
was_called gen-anchor-source \
	&& bad "freshness stale: gen-anchor-source must NOT be invoked (no anchor generated)" \
	|| ok "freshness stale: gen-anchor-source not invoked (no anchor generated)"
[ -f "$HARNESS/public/api/anchor-source.json" ] \
	&& bad "freshness stale: anchor-source.json must not be materialized" \
	|| ok "freshness stale: anchor-source.json not materialized"
destroy_harness

# ---- case 11: freshness gate FETCH-FAILED (checker exit 3) → fail-closed too -----
# Fetch-failure means "freshness undetermined" — on a broadcast-adjacent path
# that must be treated the same as known-stale, never as "proceed".
build_harness
touch "$HARNESS/fetchfail-check-scripts-freshness"
bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a >/dev/null 2>&1
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "freshness fetch-fail: non-zero exit" \
	|| bad "freshness fetch-fail: non-zero exit (actual=$RC)"
was_called gen-anchor-source \
	&& bad "freshness fetch-fail: gen-anchor-source must NOT be invoked" \
	|| ok "freshness fetch-fail: gen-anchor-source not invoked"
destroy_harness

# ---- case 12: freshness gate FRESH (default stub exit 0) → gate passes ----------
build_harness
OUT="$(bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a 2>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "freshness fresh: exit 0" \
	|| bad "freshness fresh: exit 0 (actual=$RC)"
was_called check-scripts-freshness \
	&& ok "freshness fresh: checker was invoked" \
	|| bad "freshness fresh: checker was invoked"
was_called gen-anchor-source \
	&& ok "freshness fresh: pipeline proceeds past the gate" \
	|| bad "freshness fresh: pipeline proceeds past the gate"
[ "$OUT" = "feedc0de77" ] \
	&& ok "freshness fresh: tx_id still propagated to stdout" \
	|| bad "freshness fresh: tx_id still propagated to stdout (actual='$OUT')"
destroy_harness

# ---- case 13: FYD_ALLOW_STALE_PIPELINE=1 bypasses the gate + fires alert high ---
# Emergency-only override: even with a stale marker set, the pipeline must
# proceed AND the bypass must be loudly alerted (never a silent skip).
# FY_LIVE=1 because the assertion under test is "the alert is actually sent";
# since the C3 rollout (2026-08-06) a dry FY_LIVE would suppress it, and the
# case would then be measuring the library's gate instead of the bypass path.
# The suppressed direction is covered by
# tests/side-effects-callers/test-anchor-cycle-side-effects.sh.
build_harness
touch "$HARNESS/fail-check-scripts-freshness"
OUT="$(FY_LIVE=1 FYD_ALLOW_STALE_PIPELINE=1 FYD_NOTIFY="$NOTIFY_STUB" bash "$HARNESS/scripts/run-anchor-pipeline.sh" --chain=testnet-a 2>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "bypass: exit 0 despite stale marker" \
	|| bad "bypass: exit 0 despite stale marker (actual=$RC)"
[ "$OUT" = "feedc0de77" ] \
	&& ok "bypass: pipeline completes (tx_id on stdout)" \
	|| bad "bypass: pipeline completes (tx_id on stdout) (actual='$OUT')"
was_called check-scripts-freshness \
	&& bad "bypass: freshness checker must NOT be invoked when bypassed" \
	|| ok "bypass: freshness checker not invoked when bypassed"
ALERTS="$(notify_log)"
echo "$ALERTS" | grep -q '^high|' \
	&& ok "bypass: alert fired at priority=high" \
	|| bad "bypass: alert fired at priority=high (log: $ALERTS)"
echo "$ALERTS" | grep -qi 'bypass' \
	&& ok "bypass: alert message mentions the bypass" \
	|| bad "bypass: alert message mentions the bypass (log: $ALERTS)"
destroy_harness

# ---- summary -----------------------------------------------------------------
echo "test-run-anchor-pipeline.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
