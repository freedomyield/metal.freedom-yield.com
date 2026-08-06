#!/usr/bin/env bash
# gen-cycle-history.sh — emit /api/cycle-history.jsonl
#
# Purpose:
#   A cycle-by-cycle audit packet in JSONL form. One JSON object per line,
#   chronological, derived deterministically from the canonical inputs:
#
#     public/api/uptime-cycles.json   — closed-cycle uptime ledger
#     public/api/incidents.json       — operator-maintained incident log
#
#   The JSONL output joins those two so each closed cycle is paired with the
#   set of incidents that fell inside the cycle's window. Designed to be
#   read line-by-line by automated due-diligence tooling.
#
# Per-line schema (schema_version 1):
#   - schema_version             integer
#   - cycle_n                    integer
#   - node_id                    string  (NodeID-...)
#   - network                    string  (metal-mainnet)
#   - start_iso / end_iso        ISO 8601 UTC
#   - duration_days              integer
#   - final_uptime_pct           number
#   - days_recorded              integer
#   - final_self_stake_metal     number  (fractional METAL; NOT integer —
#                                 self-stake need not be a whole METAL)
#   - final_total_delegated_metal number  (fractional METAL; NOT integer —
#                                 delegated stake need not be a whole METAL)
#   - final_delegation_fee_pct   number
#   - avg_peer_count             number
#   - min_peer_count             integer
#   - incidents_in_cycle_count   integer
#   - incidents_in_cycle_ids     array of incident id strings
#   - explorer_url               string
#   - cycle_status               string  ("closed")
#   - notes                      string | null  (null = no free-text note for this cycle)
#
# Idempotent + deterministic — running it twice on the same inputs produces
# the same bytes. Atomic write via tmp + validation + mv.
#
# Invocation (validator host):
#   bash scripts/gen-cycle-history.sh
#
# Push to web host:
#   bash scripts/push-to-web-host.sh cycle-history.jsonl
#
# Exit codes:
#   0  wrote the file (or skipped by the cycle gate, which is a normal outcome)
#   1  required input missing / output dir missing
#   2  an input is present but malformed (no .cycles / no .incidents array)
#   3  a generated line is not valid JSON
#   4  incident attribution is not conserved — the per-cycle counts do not sum
#      to the number of incidents inside the overall covered window, so
#      incidents are being dropped or double-counted. Refuses to write.
#
# This script never reads validator keys, staking keys, or any signing
# material. It only joins two already-public JSON files.
set -euo pipefail

ROOT="${REPO_BASE:-$(cd "$(dirname "$0")/.." && pwd)}"

# -------- cycle-gate (= cycle-affecting write 制御、 fail-closed) --------
# Skip regeneration of cycle-history.jsonl when the gate is deferred or
# missing/broken. cycle-history.jsonl bytes flow into dag_root_hash via
# gen-identity.sh, so an unapproved rewrite during a transition window
# would risk SC inscription integrity.
CYCLE_GATE_SCRIPT="${ROOT}/scripts/cycle-gate.sh"
if [ ! -x "${CYCLE_GATE_SCRIPT}" ]; then
	echo "[gen-cycle-history] cycle-gate.sh missing or non-executable → skip (fail-closed)" >&2
	exit 0
fi
if ! "${CYCLE_GATE_SCRIPT}" --side-effect=cycle-artifact-write; then
	echo "[gen-cycle-history] deferred by cycle-gate → skip cycle-history.jsonl regeneration" >&2
	exit 0
fi

UPTIME="${UPTIME_CYCLES_JSON:-${ROOT}/public/api/uptime-cycles.json}"
INCIDENTS="${INCIDENTS_JSON:-${ROOT}/public/api/incidents.json}"
OUT="${OUT_JSONL:-${ROOT}/public/api/cycle-history.jsonl}"
NETWORK="${NETWORK:-metal-mainnet}"

for f in "${UPTIME}" "${INCIDENTS}"; do
  if [ ! -f "${f}" ]; then
    echo "ERROR: missing input ${f}" >&2
    exit 1
  fi
done

# Sanity-check input shape.
jq -e '.cycles | type == "array"' "${UPTIME}" >/dev/null \
  || { echo "ERROR: ${UPTIME} missing .cycles array" >&2; exit 2; }
jq -e '.incidents | type == "array"' "${INCIDENTS}" >/dev/null \
  || { echo "ERROR: ${INCIDENTS} missing .incidents array" >&2; exit 2; }

OUT_DIR="$(dirname "${OUT}")"
[ -d "${OUT_DIR}" ] || { echo "ERROR: ${OUT_DIR} missing" >&2; exit 1; }

TMP="${OUT_DIR}/.cycle-history.jsonl.tmp.$$"
trap 'rm -f "${TMP}"' EXIT

# One JSON object per line. Sorted by cycle_n so output is deterministic.
#
# Attribution convention: detectionDate is a DATE ("2026-06-24"), start_iso and
# end_iso are full timestamps ("2026-05-19T07:10:14Z"). Comparing them directly
# is a lexical comparison in which the shorter date string always sorts BEFORE
# the same-day timestamp, so an incident detected on a cycle's own start date
# failed `>= start_iso` and fell into the PREVIOUS cycle — and one detected on
# the very first cycle's start date (2026-05-19, the validator's first day)
# belonged to no cycle at all and vanished from the feed entirely. Both sides
# are therefore truncated to their date part: a boundary-date incident belongs
# to the cycle that STARTS that day. Windows stay contiguous and half-open, so
# every incident lands in exactly one cycle. The conservation check after
# generation enforces that property rather than trusting it.
#
# The incident date field is "detectionDate" — the name incidents.schema.v1.json
# declares, the example carries and the live feed uses. Until 2026-08-06 the two
# incident selectors below read ".date", which no incident object has ever had:
# jq yields null for a missing key, `null >= "2026-06-04"` is false for every
# entry, so incidents_in_cycle_count pinned to 0 and incidents_in_cycle_ids to []
# on every cycle regardless of what actually happened. Same writer/reader
# field-name class as the 2026-08-04 anchor-history near-miss, and just as
# silent: the output stayed well-formed and schema-valid, it merely understated
# the public record. Found by scripts/check-field-contracts.py.
jq -c \
  --slurpfile inc "${INCIDENTS}" \
  --arg network "${NETWORK}" \
  '
    .cycles
    | sort_by(.cycle_n)
    | .[]
    | . as $c
    | {
        schema_version: 1,
        cycle_n: $c.cycle_n,
        node_id: $c.node_id,
        network: $network,
        start_iso: $c.start_iso,
        end_iso: $c.end_iso,
        duration_days: $c.duration_days,
        final_uptime_pct: $c.final_uptime_pct,
        days_recorded: $c.days_recorded,
        final_self_stake_metal: $c.final_self_stake_metal,
        final_total_delegated_metal: $c.final_total_delegated_metal,
        final_delegation_fee_pct: $c.final_delegation_fee_pct,
        avg_peer_count: $c.avg_peer_count,
        min_peer_count: $c.min_peer_count,
        incidents_in_cycle_count:
          ( [ $inc[0].incidents[]?
              | select(.detectionDate >= $c.start_iso[0:10]
                       and .detectionDate < $c.end_iso[0:10]) ]
            | length ),
        incidents_in_cycle_ids:
          [ $inc[0].incidents[]?
            | select(.detectionDate >= $c.start_iso[0:10]
                     and .detectionDate < $c.end_iso[0:10])
            | .id ],
        explorer_url: $c.explorer_url,
        cycle_status: "closed",
        notes: $c.notes
      }
  ' "${UPTIME}" > "${TMP}"

# Validate every line is valid JSON (strict).
LINE_NO=0
while IFS= read -r line; do
  LINE_NO=$((LINE_NO + 1))
  printf '%s\n' "$line" | jq empty >/dev/null 2>&1 \
    || { echo "ERROR: invalid JSON at line ${LINE_NO} of ${TMP}" >&2; exit 3; }
done < "${TMP}"

# Conservation check: every incident inside the overall covered window must be
# attributed to exactly one cycle. The bug this file was fixed for produced a
# perfectly well-formed, schema-valid feed that simply counted zero incidents
# forever — line-level JSON validation could not see it, and neither could the
# schema. This can: if the per-cycle counts do not sum to the number of
# incidents in [first cycle start, last cycle end), something is being dropped
# or double-counted, and we fail instead of publishing a quietly wrong record.
if [ -s "${TMP}" ]; then
  SUM_ATTRIBUTED="$(jq -s 'map(.incidents_in_cycle_count) | add // 0' "${TMP}")"
  WINDOW_START="$(jq -rs '.[0].start_iso[0:10]' "${TMP}")"
  WINDOW_END="$(jq -rs '.[-1].end_iso[0:10]' "${TMP}")"
  EXPECTED_IN_WINDOW="$(jq --arg s "${WINDOW_START}" --arg e "${WINDOW_END}" \
    '[ .incidents[]? | select(.detectionDate >= $s and .detectionDate < $e) ] | length' \
    "${INCIDENTS}")"
  if [ "${SUM_ATTRIBUTED}" != "${EXPECTED_IN_WINDOW}" ]; then
    echo "ERROR: incident attribution is not conserved — per-cycle counts sum to ${SUM_ATTRIBUTED}, but ${EXPECTED_IN_WINDOW} incidents fall in [${WINDOW_START}, ${WINDOW_END}). Incidents are being dropped or double-counted; refusing to write ${OUT}." >&2
    exit 4
  fi
fi

mv "${TMP}" "${OUT}"
trap - EXIT

echo "Wrote ${OUT} ($(wc -l < "${OUT}" | tr -d ' ') cycles)"
