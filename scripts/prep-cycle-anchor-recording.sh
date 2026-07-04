#!/usr/bin/env bash
# prep-cycle-anchor-recording.sh — record the just-closed cycle into the
# audit DAG so the next anchor can be broadcast with a fresh dag_root_hash.
#
# ⚠️ DEPRECATED (2026-07-04, commit 42797ae). The "proper fix" this script's own
#    footer calls for is now implemented: cycle-gate.sh ungates cycle-artifact-write
#    (the closed-cycle write proceeds while only broadcast stays gated), so the
#    transition deadlock this script hole-punched no longer exists. Retained only
#    until cycle-4 (~2026-08-04) validates the gate fix in production; delete after.
#    Do NOT reach for this on the next transition — the record crons now just work.
#
# RUNS ON: the validator host, as root. Broadcasts NOTHING.
#
# WHY THIS EXISTS (cycle-gate ordering gap, surfaced on the first real
# cycle 2 -> 3 transition):
#   The moment a cycle closes, metalgo already reports the *next* cycle, so
#   cycle-gate.sh flips to "deferred" (chain signature != approved). That
#   deferral correctly blocks the anchor-watch cron from broadcasting a stale
#   dag_root_hash — but it ALSO blocks uptime-history.sh's Job B (the append
#   of the just-closed cycle to uptime-cycles.json). Result: the closed cycle
#   is never recorded, cycle-history.jsonl never grows, and the DAG root never
#   advances — so resume-after-cycle-start.sh polls forever for a "fresh"
#   dag_root_hash that nothing produced.
#
#   There is no window where "the closed cycle is closed" AND "the gate is
#   green" overlap, so recording must happen with the gate temporarily green.
#   This script opens that window SAFELY:
#     1. disable the anchor-watch cron   (so a green gate cannot let the cron
#                                          broadcast a stale dag mid-window)
#     2. back up + remove cycle-gate-state.json (gate returns green =
#                                          backward-compat, per CYCLE_GATE.md
#                                          rollback lever 1)
#     3. run node-info.sh -> refresh validator.json to the CURRENT on-chain
#                            cycle. node-info.sh is itself gate-deferred, so
#                            during a transition validator.json is left stale
#                            at the just-closed cycle. uptime-history's Job B
#                            detects a boundary by comparing validator.json's
#                            period_end_unix to current-cycle-state.json's; if
#                            validator.json is stale the two match and NO
#                            boundary is seen. Refreshing it first is what makes
#                            the closed-cycle append fire.
#     4. run uptime-history.sh -> record the closed cycle
#     5. run gen-cycle-history.sh -> rebuild cycle-history.jsonl
#     6. publish validator.json + cycle-history.jsonl + the uptime ledgers
#
#   The gate is NOT re-created here; resume-after-cycle-start.sh --apply
#   re-creates it (approved = the new cycle) at broadcast time. The cron is
#   NOT re-enabled here; that is a deliberate post-broadcast operator step
#   (printed at the end) so no stale broadcast can slip through the window.
#
# IDEMPOTENT: if the just-closed cycle is already in cycle-history.jsonl the
#   script reports "already recorded" and makes no changes.
#
# NOT a substitute for a permanent fix. The proper fix is to let the
#   closed-cycle write proceed while only the broadcast stays gated. Tracked
#   separately; this unblocks the cycle 3 anchor today.

set -euo pipefail

REPO=/home/deploy/metal.freedom-yield.com
STATE_DIR="${UPTIME_STATE_DIR:-/var/lib/freedom-yield}"
GATE_STATE="${STATE_DIR}/cycle-gate-state.json"
CRON=/etc/cron.d/metal-anchor-watch
STAMP="$(date +%Y%m%d-%H%M%S)"
GATE_BAK="${GATE_STATE}.bak-prep-${STAMP}"
CRON_DISABLED="${CRON}.disabled-cycle-transition-${STAMP}"

# ---- guards ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root on the validator host." >&2; exit 1; }
[ -d "$REPO" ] || { echo "ERROR: ${REPO} not found — this is not the validator host." >&2; exit 1; }
cd "$REPO"
command -v jq >/dev/null || { echo "ERROR: jq required." >&2; exit 1; }

UPTIME_JSON="public/api/uptime-cycles.json"
CYCLE_JSONL="public/api/cycle-history.jsonl"
RECEIPT="public/api/anchor-receipt.json"

# Rollback guidance if anything fails after we start mutating.
CRON_MOVED=0
rollback_hint() {
	local rc=$?
	[ "$rc" -eq 0 ] && return 0
	echo "" >&2
	echo "!! FAILED (rc=${rc}). Partial state — roll back manually:" >&2
	[ "$CRON_MOVED" -eq 1 ] && echo "   re-enable cron:  mv ${CRON_DISABLED} ${CRON}" >&2
	[ -f "$GATE_BAK" ] && echo "   restore gate:    sudo -u deploy cp -a ${GATE_BAK} ${GATE_STATE}" >&2
	echo "   (do NOT run resume/broadcast until the state is understood)" >&2
}
trap rollback_hint EXIT

# ---- safety gate: no broadcast may have occurred for the in-progress cycle -
if [ -f "$RECEIPT" ]; then
	echo "ERROR: ${RECEIPT} exists — an anchor broadcast may already have run." >&2
	echo "       Inspect it before proceeding; this script refuses to touch a" >&2
	echo "       host that has already broadcast for the current cycle." >&2
	exit 1
fi

# ---- idempotency: is the closed cycle already recorded? -------------------
# On-chain the validator is in cycle N (in-progress). The just-closed cycle is
# N-1. cycle-history.jsonl should end at N-1 once recorded.
BEFORE_CYCLES="$(jq '.cycles | length' "$UPTIME_JSON")"
BEFORE_LINES=0; [ -f "$CYCLE_JSONL" ] && BEFORE_LINES="$(grep -c . "$CYCLE_JSONL" || true)"
echo "== state before =="
echo "   uptime-cycles.json closed cycles : ${BEFORE_CYCLES}"
echo "   cycle-history.jsonl lines        : ${BEFORE_LINES}"
echo "   highest recorded cycle_n         : $(jq -s 'max_by(.cycle_n).cycle_n // 0' "$CYCLE_JSONL" 2>/dev/null || echo 0)"

# ---- 1/5 disable the anchor-watch cron ------------------------------------
echo "== 1/5 disable anchor-watch cron (reversible) =="
if [ -f "$CRON" ]; then
	mv "$CRON" "$CRON_DISABLED"
	CRON_MOVED=1
	echo "   moved ${CRON} -> ${CRON_DISABLED}  (cron.d ignores dotted names)"
else
	echo "   ${CRON} already absent — skipping"
fi

# ---- 2/5 back up + remove the cycle-gate state (gate -> green) -------------
echo "== 2/5 back up + remove cycle-gate-state.json (gate -> green) =="
if [ -f "$GATE_STATE" ]; then
	sudo -u deploy cp -a "$GATE_STATE" "$GATE_BAK"
	sudo -u deploy rm -f "$GATE_STATE"
	echo "   backup: ${GATE_BAK}"
	echo "   removed live state — cycle-gate.sh now returns green (backward compat)"
else
	echo "   ${GATE_STATE} already absent — gate already green"
fi
sudo -u deploy bash scripts/cycle-gate.sh --side-effect=cycle-artifact-write \
	&& echo "   confirmed: cycle-artifact-write is GREEN" \
	|| { echo "ERROR: gate still not green after removing state file." >&2; exit 1; }

# ---- 3/6 refresh validator.json to the current on-chain cycle -------------
# node-info.sh is itself gate-deferred, so during a transition validator.json
# is left stale at the just-closed cycle. uptime-history's Job B detects a
# boundary by comparing validator.json.period_end_unix to
# current-cycle-state.json.period_end_unix; if both are stale they match and no
# boundary fires. Refresh validator.json (gate is green now) so the two differ.
echo "== 3/6 node-info.sh — refresh validator.json to the current cycle =="
VALIDATOR_JSON="public/api/validator.json"
CYCLE_STATE="${STATE_DIR}/current-cycle-state.json"
STATE_END="$(jq -r '.period_end_unix // empty' "$CYCLE_STATE" 2>/dev/null || true)"
V_END_BEFORE="$(jq -r '.endTime // empty' "$VALIDATOR_JSON" 2>/dev/null || true)"
echo "   before: validator.json period_end=${V_END_BEFORE:-?}  current-cycle-state period_end=${STATE_END:-?}"
sudo -u deploy bash scripts/node-info.sh 2>&1 | sed 's/^/   /'
V_END_AFTER="$(jq -r '.endTime // empty' "$VALIDATOR_JSON" 2>/dev/null || true)"
echo "   after:  validator.json period_end=${V_END_AFTER:-?}"
if [ -z "$V_END_AFTER" ]; then
	echo "ERROR: validator.json has no period_end_unix after node-info.sh." >&2
	exit 1
fi
if [ -n "$STATE_END" ] && [ "$V_END_AFTER" = "$STATE_END" ]; then
	# validator.json's cycle window == current-cycle-state's. Two cases:
	#  (a) first run, node-info failed to advance -> genuine error, abort.
	#  (b) idempotent re-run: a prior run already recorded the closed cycle AND
	#      advanced current-cycle-state to match validator.json -> fine, continue.
	if [ "$(jq '.cycles | length' "$UPTIME_JSON")" -ge 2 ]; then
		echo "   validator.json == current-cycle-state, but the closed cycle is already"
		echo "   recorded (idempotent re-run) — continuing."
	else
		echo "ERROR: validator.json period_end still equals current-cycle-state (${V_END_AFTER});" >&2
		echo "       node-info.sh did not advance to a new cycle, so uptime-history would" >&2
		echo "       still see no boundary. Inspect metalgo RPC before continuing." >&2
		exit 1
	fi
fi

# ---- 4/6 record the just-closed cycle -------------------------------------
echo "== 4/6 uptime-history.sh — record the closed cycle =="
sudo -u deploy env UPTIME_STATE_DIR="$STATE_DIR" bash scripts/uptime-history.sh 2>&1 | sed 's/^/   /'
AFTER_CYCLES="$(jq '.cycles | length' "$UPTIME_JSON")"
echo "   closed cycles: ${BEFORE_CYCLES} -> ${AFTER_CYCLES}"
# Idempotent success test: the just-closed cycle must be recorded. As of the
# cycle 3 start there are two closed cycles (1 + 2). On a re-run uptime-history
# appends nothing (already present) but the count is still >= 2, which passes;
# the original bug (cycle 2 never recorded) leaves it at 1, which fails.
if [ "$AFTER_CYCLES" -lt 2 ]; then
	echo "ERROR: uptime-cycles.json has < 2 closed cycles — cycle 2 was not recorded." >&2
	echo "       (metalgo may not yet report the prior cycle as closed, or the" >&2
	echo "        boundary was not detected). Inspect before continuing." >&2
	exit 1
fi

# ---- 5/6 rebuild cycle-history.jsonl --------------------------------------
echo "== 5/6 gen-cycle-history.sh — rebuild cycle-history.jsonl =="
sudo -u deploy bash scripts/gen-cycle-history.sh 2>&1 | sed 's/^/   /'
AFTER_LINES="$(grep -c . "$CYCLE_JSONL" || true)"
echo "   cycle-history.jsonl lines: ${BEFORE_LINES} -> ${AFTER_LINES}"
# cycle-history.jsonl is derived from uptime-cycles.json, so it must agree with
# the closed-cycle count (idempotent: both are 2 on first run and on re-run).
if [ "$AFTER_LINES" -ne "$AFTER_CYCLES" ] || [ "$AFTER_LINES" -lt 2 ]; then
	echo "ERROR: cycle-history.jsonl (${AFTER_LINES}) disagrees with uptime-cycles" >&2
	echo "       (${AFTER_CYCLES}) or is < 2 lines. Inspect before continuing." >&2
	exit 1
fi

# ---- 6/6 publish to the web host ------------------------------------------
echo "== 6/6 publish validator.json + cycle-history.jsonl + uptime ledgers =="
sudo -u deploy bash scripts/push-to-web-host.sh validator.json        2>&1 | sed 's/^/   validator:     /'
sudo -u deploy env WEB_HOST_FILE=/etc/freedom-yield/xserver-host \
	bash scripts/push-to-web-host.sh cycle-history.jsonl 2>&1 | sed 's/^/   cycle-history: /'
sudo -u deploy bash scripts/push-to-web-host.sh uptime-cycles.json    2>&1 | sed 's/^/   uptime-cycles: /'
sudo -u deploy bash scripts/push-to-web-host.sh uptime-recent.json    2>&1 | sed 's/^/   uptime-recent: /'

trap - EXIT
echo ""
echo "================= DONE (no broadcast performed) ================="
echo "Closed cycle recorded. cycle-history.jsonl now has ${AFTER_LINES} line(s)."
echo ""
echo "NEXT STEPS (in order):"
echo "  1. Mac:  OPERATOR_IDENTITY_KEY=~/.ssh/<identity-key> \\"
echo "             bash scripts/operator-local/gen-identity.sh"
echo "           -> dag_root_hash MUST now differ from 0bd4e667… (it now"
echo "              includes the just-closed cycle). If it is unchanged, STOP."
echo "  2. Mac:  git add public/api/identity.json public/api/identity.json.sig \\"
echo "             public/api/cycles-history.json && git commit && git push"
echo "  3. Wait for the GitHub Actions Deploy workflow to finish."
echo "  4. Validator host: run the gated broadcast —"
echo "       sudo -u deploy env PUBLIC_BASE=http://127.0.0.1:8085 \\"
echo "         bash ${REPO}/scripts/resume-after-cycle-start.sh --apply"
echo "     (PUBLIC_BASE points at the local Caddy because identity.json is not"
echo "      propagated to the public Xserver origin; the fresh dag is served"
echo "      locally after deploy. The broadcast still goes through"
echo "      bin/safe-broadcast's four PRIME DIRECTIVE gates.)"
echo "  5. AFTER a successful broadcast, re-enable the anchor cron:"
echo "       mv ${CRON_DISABLED} ${CRON}"
echo "================================================================"
