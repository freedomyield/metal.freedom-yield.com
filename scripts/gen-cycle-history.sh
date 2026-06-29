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
#   - final_self_stake_metal     integer
#   - final_total_delegated_metal integer
#   - final_delegation_fee_pct   number
#   - avg_peer_count             number
#   - min_peer_count             integer
#   - incidents_in_cycle_count   integer
#   - incidents_in_cycle_ids     array of incident id strings
#   - explorer_url               string
#   - cycle_status               string  ("closed")
#   - notes                      string
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
              | select(.date >= $c.start_iso and .date < $c.end_iso) ]
            | length ),
        incidents_in_cycle_ids:
          [ $inc[0].incidents[]?
            | select(.date >= $c.start_iso and .date < $c.end_iso)
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

mv "${TMP}" "${OUT}"
trap - EXIT

echo "Wrote ${OUT} ($(wc -l < "${OUT}" | tr -d ' ') cycles)"
