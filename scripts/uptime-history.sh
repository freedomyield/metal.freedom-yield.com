#!/usr/bin/env bash
# uptime-history.sh — long-horizon uptime track record builder.
#
# Maintains three artefacts:
#
#   1. /var/lib/freedom-yield/uptime-history.jsonl
#      Master append-only daily ledger. ONE FILE for the entire lifetime
#      of the validator. Loss = unrecoverable history. Backed up to Mac
#      + Dropbox per [[reference_backup_locations]] discipline.
#
#   2. /var/lib/freedom-yield/current-cycle-state.json
#      In-flight cycle metadata. Used to detect cycle boundary by
#      comparing validator.json's period_end_unix against last seen.
#
#   3a. public/api/uptime-recent.json
#       Last 90 days of daily entries (for chart / fine-grained view).
#       Regenerated from JSONL on every run.
#
#   3b. public/api/uptime-cycles.json
#       All cycles ever, summarised at cycle close. Append-only growth.
#       Each row includes period_id + explorer URL for audit.
#
# Auditability principles:
#   - Every row references on-chain period_id (start/end unix from P-Chain)
#   - explorer_url on cycle rows points to the validator page on the
#     official explorer so a 3rd party can verify our claims against chain
#   - JSONL master is immutable append-only — we never edit past rows
#   - Idempotent: rerunning the script same day does not duplicate entries
#
# Invocation:
#   Daily cron at ~03:30 UTC (after node-info.sh has refreshed JSON),
#   plus on demand for manual catch-up after outages.
#
# Env:
#   UPTIME_STATE_DIR  state dir (default /var/lib/freedom-yield). Resolved by
#                     scripts/lib/side-effects.sh (fyd_state_dir uptime),
#                     which also honours the canonical FY_STATE_DIR at higher
#                     precedence. The legacy spelling is unchanged — the live
#                     host cron env header still sets it.
#   FY_LIVE=1         REQUIRED before ANY of the four artefacts above is
#                     written: the append-only master ledger, the cycle
#                     state, the cycle summary file and the public preview.
#                     Anything else is a loud dry no-op printing one
#                     "DRY: would …" line per suppressed write
#                     (scripts/lib/side-effects.sh, C3 rollout 2026-08-06).
#                     The cron env header carries it; tests deliberately do
#                     not.
#
#                     The cycle-gate consultation is NOT a side effect and is
#                     NOT gated: a dry run still asks the gate and still
#                     honours a deferral, so the gate's verdict is identical
#                     in both modes.
#
#                     Every read is written to tolerate an artefact that the
#                     bootstrap would have created but FY_LIVE suppressed, so
#                     a dry run reports what it WOULD write instead of dying
#                     on a file it was not allowed to create.
#
# Exit codes:
#   0 — wrote new daily entry (or already present)
#   1 — fatal error (missing JSON, bad data)
#   3 — scripts/lib/side-effects.sh missing (structural — refuse rather than
#       silently keep a track record that nothing can persist)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FYD_LIB="${ROOT}/scripts/lib/side-effects.sh"
if [ ! -r "$FYD_LIB" ]; then
  echo "uptime-history: FATAL: side-effects library not readable at $FYD_LIB" >&2
  exit 3
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

VALIDATOR_JSON="${VALIDATOR_JSON:-$ROOT/public/api/validator.json}"
STATUS_JSON="${STATUS_JSON:-$ROOT/public/api/server-status.json}"
STATE_DIR="$(fyd_state_dir uptime)" || exit $?
HIST_JSONL="${STATE_DIR}/uptime-history.jsonl"
CYCLE_STATE="${STATE_DIR}/current-cycle-state.json"
# Optional operator-maintained notes file. Schema:
#   { "1": "Cycle 1: ...", "2": "...", ... }   (key = cycle_n as string)
# Each closing cycle picks up its note (if any) from this file. Notes
# missing for a cycle are recorded as null, which the journal page
# renders as "(No notes recorded)".
CYCLE_NOTES_JSON="${CYCLE_NOTES_JSON:-${STATE_DIR}/cycle-notes.json}"
OUT_RECENT="${ROOT}/public/api/uptime-recent.json"
OUT_CYCLES="${ROOT}/public/api/uptime-cycles.json"
EXPLORER_BASE="${EXPLORER_BASE:-https://explorer.metalblockchain.org/validators}"
RECENT_DAYS="${RECENT_DAYS:-90}"

fyd_live_run "create the uptime state dir ${STATE_DIR}" mkdir -p "$STATE_DIR"
fyd_live_run "create the public api dir $(dirname "$OUT_RECENT")" mkdir -p "$(dirname "$OUT_RECENT")"

# read_or <path> <fallback> — print the file's bytes, or <fallback> when the
# file does not exist. Every read below goes through this so that a dry run
# (whose bootstrap writes were suppressed a few lines down) still sees the
# same VALUES a live run would have bootstrapped, and therefore takes the
# same branches. Without it a dry run would die on the first `jq FILE` of a
# file FY_LIVE had just stopped it from creating — a gate that changes the
# control flow is not a gate, it is a second implementation.
read_or() {
  if [ -f "$1" ]; then cat "$1"; else printf '%s' "$2"; fi
}

# Bootstrap empty files so jq operations have something to read.
[ -f "$HIST_JSONL" ] || fyd_live_write "an empty uptime master ledger" "$HIST_JSONL" </dev/null
[ -f "$OUT_CYCLES" ] || printf '%s\n' '{"cycles":[]}' | fyd_live_write "an empty cycle summary file" "$OUT_CYCLES"
[ -f "$CYCLE_STATE" ] || printf '%s\n' '{}' | fyd_live_write "an empty cycle state" "$CYCLE_STATE"

# Read current on-chain state.
NODE_ID=$(jq -r '.nodeId // empty' "$VALIDATOR_JSON")
START_UNIX=$(jq -r '.startTime // empty' "$VALIDATOR_JSON")
END_UNIX=$(jq -r '.endTime // empty' "$VALIDATOR_JSON")
UPTIME=$(jq -r '.uptime.network // .uptime // empty' "$VALIDATOR_JSON")
OBSERVED_AT=$(jq -r '.observedAt // empty' "$VALIDATOR_JSON")

# Phase γ #1: track stake / fee / delegation alongside uptime so each
# daily row carries the full economic context of that day. These end up
# in the long-term JSONL master and bubble through to cycle-close rows.
SELF_STAKE=$(jq -r '.stake.self // 0' "$VALIDATOR_JSON")
TOTAL_DELEGATED=$(jq -r '.stake.totalReceived // 0' "$VALIDATOR_JSON")
FEE_PCT=$(jq -r '.delegationFee.percent // null' "$VALIDATOR_JSON")
NETWORK_VALIDATORS=$(jq -r '.networkSize.totalValidators // null' "$VALIDATOR_JSON")

if [ -z "$NODE_ID" ] || [ -z "$END_UNIX" ] || [ -z "$UPTIME" ]; then
  echo "ERROR: validator.json missing required fields (nodeId/endTime/uptime)" >&2
  exit 1
fi

# Optional metrics from server-status.json (skipped if file absent).
PEER_COUNT=0
P_BOOT=null; X_BOOT=null; C_BOOT=null
if [ -f "$STATUS_JSON" ]; then
  PEER_COUNT=$(jq -r '.metalgo.peerCount // 0' "$STATUS_JSON")
fi
P_BOOT=$(jq -r '.bootstrap.pChain // null' "$VALIDATOR_JSON")
X_BOOT=$(jq -r '.bootstrap.xChain // null' "$VALIDATOR_JSON")
C_BOOT=$(jq -r '.bootstrap.cChain // null' "$VALIDATOR_JSON")

TODAY=$(date -u +%Y-%m-%d)

# === Append today's daily entry (idempotent by date+period combo) ====
# A new line is added only if there is not already a row for today within
# the current period. If the period rolled over today (rare), we accept
# two rows on the same date — one for the old period (its closing snap)
# and one for the new (its opening snap).
EXISTING=$(read_or "$HIST_JSONL" '' \
  | grep -c "^{\"date\":\"${TODAY}\",.*\"period_end_unix\":${END_UNIX}" 2>/dev/null || true)
if [ "$EXISTING" = "0" ]; then
  ENTRY=$(jq -n -c \
    --arg date "$TODAY" \
    --arg obs "$OBSERVED_AT" \
    --arg nid "$NODE_ID" \
    --argjson ps "$START_UNIX" \
    --argjson pe "$END_UNIX" \
    --argjson up "$UPTIME" \
    --argjson pc "$PEER_COUNT" \
    --argjson pb "$P_BOOT" \
    --argjson xb "$X_BOOT" \
    --argjson cb "$C_BOOT" \
    --argjson ss "$SELF_STAKE" \
    --argjson td "$TOTAL_DELEGATED" \
    --argjson fp "$FEE_PCT" \
    --argjson nv "$NETWORK_VALIDATORS" \
    '{date:$date, observed_at:$obs, node_id:$nid, period_start_unix:$ps, period_end_unix:$pe, uptime_pct:$up, peer_count:$pc, bootstrap:{p:$pb,x:$xb,c:$cb}, self_stake_metal:$ss, total_delegated_metal:$td, delegation_fee_pct:$fp, network_total_validators:$nv}')
  printf '%s\n' "$ENTRY" | fyd_live_write --append "today's uptime master entry" "$HIST_JSONL"
  if fyd_is_live; then
    echo "Appended daily entry for $TODAY (period $START_UNIX → $END_UNIX, uptime ${UPTIME}%, self ${SELF_STAKE} METAL, delegated ${TOTAL_DELEGATED}, fee ${FEE_PCT}%)"
  fi
else
  echo "Daily entry for $TODAY already present, skipping append"
fi

# === Cycle boundary detection =======================================
# Compare validator.json's period_end_unix with last seen in cycle state.
# If different, the previous cycle has ended — close it out + append cycle
# summary to uptime-cycles.json.

# -------- cycle-gate (= partial gate, Job B only, fail-closed) --------
# Job A (= daily snapshot append to uptime-history.jsonl) above is NOT gated.
# Job B (= cycle boundary append to uptime-cycles.json) below IS gated.
# uptime-cycles.json bytes flow into cycle-history.jsonl → dag_root_hash;
# an unapproved cycle boundary append during a transition window would risk
# SC inscription integrity. Skip Job B but keep Job A's daily snapshot.
CYCLE_GATE_SCRIPT="${ROOT}/scripts/cycle-gate.sh"
if [ ! -x "${CYCLE_GATE_SCRIPT}" ]; then
	echo "[uptime-history] cycle-gate.sh missing or non-executable → skip Job B (fail-closed)" >&2
	exit 0
fi
if ! "${CYCLE_GATE_SCRIPT}" --side-effect=cycle-artifact-write; then
	echo "[uptime-history] deferred by cycle-gate → skip Job B (cycle boundary detection)" >&2
	exit 0
fi

LAST_END=$(read_or "$CYCLE_STATE" '{}' | jq -r '.period_end_unix // empty')

if [ -z "$LAST_END" ]; then
  # First run ever — initialise state with current cycle.
  CYCLE_N=1
  echo "Bootstrap: initialising cycle state at cycle #${CYCLE_N}"
elif [ "$LAST_END" != "$END_UNIX" ]; then
  # Cycle changed — wrap up the old one.
  PREV_START=$(read_or "$CYCLE_STATE" '{}' | jq -r '.period_start_unix // empty')
  PREV_END="$LAST_END"
  PREV_CYCLE_N=$(read_or "$CYCLE_STATE" '{}' | jq -r '.cycle_n // 0')

  # Collect closing snapshot of the previous cycle from the JSONL.
  # Pull final fee / stake / delegation values + avg peer count over the
  # cycle, so each closed-cycle row stands as a self-contained track-record entry.
  FINAL_UP=$(jq -s --argjson pe "$PREV_END" '[.[] | select(.period_end_unix == $pe)] | last | .uptime_pct // null' < <(read_or "$HIST_JSONL" '' | jq -c . 2>/dev/null))
  DAYS_REC=$(jq -s --argjson pe "$PREV_END" '[.[] | select(.period_end_unix == $pe)] | length' < <(read_or "$HIST_JSONL" '' | jq -c . 2>/dev/null))
  FINAL_SELF_STAKE=$(jq -s --argjson pe "$PREV_END" '[.[] | select(.period_end_unix == $pe)] | last | .self_stake_metal // null' < <(read_or "$HIST_JSONL" '' | jq -c . 2>/dev/null))
  FINAL_TOTAL_DELEGATED=$(jq -s --argjson pe "$PREV_END" '[.[] | select(.period_end_unix == $pe)] | last | .total_delegated_metal // null' < <(read_or "$HIST_JSONL" '' | jq -c . 2>/dev/null))
  FINAL_FEE_PCT=$(jq -s --argjson pe "$PREV_END" '[.[] | select(.period_end_unix == $pe)] | last | .delegation_fee_pct // null' < <(read_or "$HIST_JSONL" '' | jq -c . 2>/dev/null))
  AVG_PEER_COUNT=$(jq -s --argjson pe "$PREV_END" '
    [.[] | select(.period_end_unix == $pe) | .peer_count // 0] as $pcs
    | if ($pcs | length) > 0 then (($pcs | add) / ($pcs | length) | . * 10 | round / 10) else null end
  ' < <(read_or "$HIST_JSONL" '' | jq -c . 2>/dev/null))
  MIN_PEER_COUNT=$(jq -s --argjson pe "$PREV_END" '[.[] | select(.period_end_unix == $pe) | .peer_count // 0] | min // null' < <(read_or "$HIST_JSONL" '' | jq -c . 2>/dev/null))
  DURATION_DAYS=$(( (PREV_END - PREV_START) / 86400 ))
  START_ISO=$(date -u -d "@$PREV_START" +%Y-%m-%dT%H:%M:%SZ)
  END_ISO=$(date -u -d "@$PREV_END" +%Y-%m-%dT%H:%M:%SZ)

  # Idempotency: do not append if this cycle is already in the file.
  ALREADY=$(read_or "$OUT_CYCLES" '{"cycles":[]}' \
    | jq --arg pe "$PREV_END" '[.cycles[] | select(.end_unix == ($pe|tonumber))] | length')
  if [ "$ALREADY" = "0" ]; then
    # Pick up an operator note for this cycle, if present. Notes file is
    # optional; missing file or missing key both result in JSON null.
    NOTE_JSON="null"
    if [ -f "$CYCLE_NOTES_JSON" ]; then
      NOTE_JSON=$(jq -c --arg k "$PREV_CYCLE_N" '.[$k] // null' "$CYCLE_NOTES_JSON" 2>/dev/null || echo "null")
    fi
    TMP=$(mktemp)
    read_or "$OUT_CYCLES" '{"cycles":[]}' \
    | jq --argjson cn "$PREV_CYCLE_N" \
       --arg nid "$NODE_ID" \
       --arg si "$START_ISO" \
       --arg ei "$END_ISO" \
       --argjson sx "$PREV_START" \
       --argjson ex "$PREV_END" \
       --argjson du "$DURATION_DAYS" \
       --argjson up "$FINAL_UP" \
       --argjson dr "$DAYS_REC" \
       --argjson fss "$FINAL_SELF_STAKE" \
       --argjson ftd "$FINAL_TOTAL_DELEGATED" \
       --argjson ffp "$FINAL_FEE_PCT" \
       --argjson apc "$AVG_PEER_COUNT" \
       --argjson mpc "$MIN_PEER_COUNT" \
       --arg ex_url "${EXPLORER_BASE}/${NODE_ID}" \
       --argjson note "$NOTE_JSON" \
       '.cycles += [{cycle_n:$cn, node_id:$nid, start_iso:$si, end_iso:$ei, start_unix:$sx, end_unix:$ex, duration_days:$du, final_uptime_pct:$up, days_recorded:$dr, final_self_stake_metal:$fss, final_total_delegated_metal:$ftd, final_delegation_fee_pct:$ffp, avg_peer_count:$apc, min_peer_count:$mpc, explorer_url:$ex_url, notes:$note}]' \
       > "$TMP"
    # Atomicity preserved: the content is built in a temp file and only the
    # final rename is gated, exactly as scripts/lib/side-effects.sh's
    # fyd_live_write docstring prescribes for state that must survive a crash.
    fyd_live_run "append the closed cycle summary to ${OUT_CYCLES}" mv "$TMP" "$OUT_CYCLES"
    rm -f "$TMP"
    if fyd_is_live; then
      echo "Closed cycle #${PREV_CYCLE_N}: ${START_ISO} → ${END_ISO}, ${DAYS_REC} days, final uptime ${FINAL_UP}%, self ${FINAL_SELF_STAKE} METAL, delegated ${FINAL_TOTAL_DELEGATED}, fee ${FINAL_FEE_PCT}%, avg peers ${AVG_PEER_COUNT}, notes=$([ "$NOTE_JSON" = "null" ] && echo none || echo present)"
    fi
  fi
  CYCLE_N=$((PREV_CYCLE_N + 1))
else
  CYCLE_N=$(read_or "$CYCLE_STATE" '{}' | jq -r '.cycle_n // 1')
fi

# Persist current cycle state.
jq -n -c \
  --argjson cn "$CYCLE_N" \
  --arg nid "$NODE_ID" \
  --argjson ps "$START_UNIX" \
  --argjson pe "$END_UNIX" \
  '{cycle_n:$cn, node_id:$nid, period_start_unix:$ps, period_end_unix:$pe, updated_at:(now|todateiso8601)}' \
  | fyd_live_write "the current cycle state" "$CYCLE_STATE"

# === Regenerate uptime-recent.json (last N days) ====================
# Pull the trailing RECENT_DAYS rows from the JSONL. This file is what
# the web chart consumes; small and cheap to regenerate every run.
RECENT_TMP=$(mktemp)
read_or "$HIST_JSONL" '' | tail -n "$RECENT_DAYS" \
  | jq -s --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson days "$RECENT_DAYS" \
      '{generated_at:$gen, window_days:$days, entries:.}' > "$RECENT_TMP"
fyd_live_run "install the refreshed public uptime preview ${OUT_RECENT}" mv "$RECENT_TMP" "$OUT_RECENT"
rm -f "$RECENT_TMP"

if fyd_is_live; then
  echo "Wrote $OUT_RECENT ($(wc -l < "$HIST_JSONL") total master entries)"
  echo "Wrote $OUT_CYCLES ($(jq '.cycles | length' "$OUT_CYCLES") cycles)"
fi
