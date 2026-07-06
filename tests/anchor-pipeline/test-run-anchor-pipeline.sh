#!/usr/bin/env bash
# test-run-anchor-pipeline.sh — e2e wiring suite for scripts/run-anchor-pipeline.sh
# (design-stocktake #7: the 2026-07-04 production troubles were all
# integration/wiring/ordering failures that per-script unit suites cannot see).
#
# CHAIN: none — the REAL orchestrator runs against STUB sub-scripts. No RPC,
#        no signer, no broadcast path is ever reachable: the four pipeline
#        steps are replaced by recording stubs inside an isolated tempdir
#        harness (the orchestrator derives REPO_ROOT from its own location,
#        so copying it into the harness redirects every sub-script call).
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
# build_harness: fresh tempdir with the REAL orchestrator + 4 recording stubs.
# Stubs append their name to calls/order.log and dump "$@" to calls/<name>.args.
# A stub fails (exit 1) iff the marker file fail-<name> exists in the harness
# root. The sign stub emits the JSON contract the orchestrator consumes.
HARNESS=""
build_harness() {
	HARNESS="$(mktemp -d -t anchor-pipe-e2e.XXXXXX)"
	mkdir -p "$HARNESS/scripts" "$HARNESS/public/api" "$HARNESS/calls"
	cp "$ORCH" "$HARNESS/scripts/run-anchor-pipeline.sh"

	local name
	for name in gen-anchor-source sign-anchor-event gen-anchor-receipt append-anchor-history; do
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
		echo 'exit 0' >> "$HARNESS/scripts/${name}.sh"
	done
}

destroy_harness() {
	[ -n "$HARNESS" ] && rm -rf "$HARNESS"
	HARNESS=""
}

order_log()  { cat "$HARNESS/calls/order.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
args_of()    { cat "$HARNESS/calls/$1.args" 2>/dev/null; }
was_called() { [ -f "$HARNESS/calls/$1.args" ]; }

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
[ "$(order_log)" = "gen-anchor-source sign-anchor-event gen-anchor-receipt append-anchor-history" ] \
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
[ "$(order_log)" = "gen-anchor-source" ] \
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
[ "$(order_log)" = "gen-anchor-source sign-anchor-event" ] \
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
[ "$(order_log)" = "gen-anchor-source sign-anchor-event gen-anchor-receipt" ] \
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

# ---- summary -----------------------------------------------------------------
echo "test-run-anchor-pipeline.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
