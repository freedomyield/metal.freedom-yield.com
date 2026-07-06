#!/usr/bin/env bash
# peer-validators.sh — snapshot the Metal Blockchain validator set into
# public/api/peers.json for operational tooling.
#
# Architecture: read local metalgo's P-Chain RPC (no external call), shape
# into a single JSON document with per-validator rows + network summary +
# operator clusters. The output is small (~250 validators × ~400 bytes =
# ~100 KB) and refreshed once a day — totally fine for a static-serve
# JSON consumed by a single human.
#
# Operator clustering: validators that share the same validation reward
# owner addresses are grouped — same person/entity running multiple
# nodes. The page surfaces these clusters so the operator can see the
# real concentration of stake by entity rather than by NodeID.
#
# This is purely an operational network state snapshot — no thesis
# confirmation signals or probability flags here.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/public/api/peers.json}"
RPC="${METALGO_API:-http://localhost:9650}"
OWN_NODE_ID="${OWN_NODE_ID:-$(jq -r '.nodeId // empty' "$ROOT/public/api/validator.json" 2>/dev/null || echo '')}"
EXPLORER_API="${EXPLORER_API:-https://explorer.metalblockchain.org/api/v1/validators}"

# Fetch full validator set from local metalgo. We never hit external RPC
# for this — only our own node, which is authoritative anyway.
RESP=$(curl -sS --max-time 15 -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{}}' \
  "${RPC}/ext/bc/P")

if ! echo "$RESP" | jq -e '.result.validators' > /dev/null 2>&1; then
  echo "ERROR: bad RPC response from ${RPC}/ext/bc/P" >&2
  echo "$RESP" | head -c 500 >&2
  exit 1
fi

# Fetch human-readable validator names from Metallicus' explorer API.
# This is the only place names are published — local metalgo RPC doesn't
# expose them. Cron runs once daily so the external hit is polite.
# Failure is non-fatal: if explorer is down we just ship empty names.
NAMES_TMP=$(mktemp)
if curl -sS --max-time 20 -H 'Accept: application/json' "$EXPLORER_API" \
   | jq -c 'if type == "array" then map({key:.nodeId, value: .name}) | from_entries else {} end' \
   > "$NAMES_TMP" 2>/dev/null; then
  NAMES_COUNT=$(jq 'to_entries | map(select(.value != null and .value != "")) | length' "$NAMES_TMP" 2>/dev/null || echo 0)
  echo "Fetched $NAMES_COUNT validator names from $EXPLORER_API"
else
  echo "WARN: explorer name fetch failed, proceeding with empty names" >&2
  echo '{}' > "$NAMES_TMP"
fi

NOW_SEC=$(date +%s)
GEN_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

TMP=$(mktemp)
trap 'rm -f "$TMP" "$NAMES_TMP"' EXIT

echo "$RESP" | jq \
  --arg now "$NOW_SEC" \
  --arg gen "$GEN_ISO" \
  --arg own "$OWN_NODE_ID" \
  --slurpfile names "$NAMES_TMP" \
'
  ($names[0] // {}) as $name_map |
  # nMETAL → METAL helper. P-Chain stake amounts are in nMETAL (10^9
  # base unit), keep tonumber to preserve precision for sums.
  def nano_to_metal: tonumber / 1e9;
  # Sort + join addresses to form a stable cluster key. Single key per
  # operator regardless of address order in the JSON.
  def addr_key: (sort | join(","));

  .result.validators as $raw |

  # Per-validator base rows.
  # Metalgo API specifics (verified against live response):
  #   .weight           → self-stake in nMETAL (string, "2000000000000")
  #   .delegatorWeight  → sum of delegations in nMETAL
  #   .delegatorCount   → count of delegations
  #   .delegationFee    → percent string ("3.0000" = 3 %)  NO /10000
  #   .uptime           → percent string ("99.9940")       NO *100
  #   .startTime/.endTime → unix seconds (string)
  # No .stakeAmount, no .delegators[] in this API version — we used those
  # in the first pass and it explains why every numeric came out zero.
  [$raw[]? | {
    node_id: .nodeID,
    name:                  (($name_map[.nodeID] // null) | if . == "" then null else . end),
    self_stake_metal:      ((.weight // "0") | nano_to_metal),
    delegators_count:      ((.delegatorCount // "0") | tonumber),
    total_delegated_metal: ((.delegatorWeight // "0") | nano_to_metal),
    delegation_fee_pct:    ((.delegationFee // "0") | tonumber),
    uptime_pct:            ((.uptime // "0") | tonumber),
    period_start_unix:     ((.startTime // "0") | tonumber),
    period_end_unix:       ((.endTime // "0") | tonumber),
    duration_days:         ((((.endTime // "0") | tonumber) - ((.startTime // "0") | tonumber)) / 86400 | floor),
    days_remaining:        ((((.endTime // "0") | tonumber) - ($now | tonumber)) / 86400 | floor),
    connected:             (.connected // null),
    reward_addresses:      ((.validationRewardOwner.addresses // [])),
    cluster_key:           ((.validationRewardOwner.addresses // []) | addr_key),
    is_self:               (.nodeID == $own)
  } | . + {
    # Capacity = total weight ceiling is 5× self-stake; usage % = received / cap
    capacity_used_pct: (
      if (.self_stake_metal // 0) > 0
      then (.total_delegated_metal / ((.self_stake_metal // 1) * 4) * 100 | . * 10 | round / 10)
      else 0
      end
    ),
    period_start_iso: (.period_start_unix | todate),
    period_end_iso:   (.period_end_unix | todate)
  }] as $vs |

  # Operator clusters — group by validationRewardOwner address set.
  # A cluster with 2+ NodeIDs strongly implies same operator.
  ($vs | group_by(.cluster_key)
    | map(select((.[0].cluster_key // "") != ""))
    | map({
        cluster_key:       (.[0].cluster_key),
        node_count:        length,
        node_ids:          ([.[] | .node_id]),
        total_self_metal:  ([.[] | .self_stake_metal] | add),
        total_recv_metal:  ([.[] | .total_delegated_metal] | add),
        addresses:        (.[0].reward_addresses)
      })
    | map(select(.node_count > 1))
    | sort_by(-.total_self_metal)
  ) as $clusters |

  # Summary
  (($vs | length)) as $count |
  (($vs | map(.self_stake_metal) | sort) | .[$count / 2 | floor]) as $median_stake |
  (($vs | map(.uptime_pct) | sort) | .[$count / 2 | floor])         as $median_uptime |
  (($vs | map(.delegation_fee_pct) | sort) | .[$count / 2 | floor]) as $median_fee |

  # Fee histogram in 1 % bins, 2…12+
  ($vs | group_by(.delegation_fee_pct | floor)
       | map({(.[0].delegation_fee_pct | floor | tostring): length})
       | add // {}) as $fee_hist |

  # Expiry buckets
  ($vs | map(.days_remaining)) as $days |
  (($days | map(select(. <= 7))   | length)) as $exp7 |
  (($days | map(select(. > 7 and . <= 14))   | length)) as $exp14 |
  (($days | map(select(. > 14 and . <= 30))  | length)) as $exp30 |
  (($days | map(select(. > 30 and . <= 90))  | length)) as $exp90 |
  (($days | map(select(. > 90))   | length)) as $exp90p |

  {
    generated_at: $gen,
    network: "mainnet",
    own_node_id: $own,
    summary: {
      active_count: $count,
      total_self_stake_metal:  (($vs | map(.self_stake_metal) | add) // 0),
      total_delegated_metal:   (($vs | map(.total_delegated_metal) | add) // 0),
      median_self_stake_metal: $median_stake,
      median_uptime_pct:       $median_uptime,
      median_fee_pct:          $median_fee,
      fee_histogram:           $fee_hist,
      expiry_buckets: {
        days_0_7:    $exp7,
        days_8_14:   $exp14,
        days_15_30:  $exp30,
        days_31_90:  $exp90,
        days_91_plus: $exp90p
      },
      operator_cluster_count: ($clusters | length)
    },
    operator_clusters: $clusters,
    validators: ($vs | sort_by(-(.self_stake_metal + .total_delegated_metal)))
  }
' > "$TMP"

mv "$TMP" "$OUT"

COUNT=$(jq '.summary.active_count' "$OUT")
CLUSTERS=$(jq '.summary.operator_cluster_count' "$OUT")
echo "wrote $OUT — ${COUNT} active validators, ${CLUSTERS} multi-node clusters"

# ─────────────────────── C+D: changes detector + Gini time-series ──
# Delegated to Python — bash subshells were silently swallowing errors.
STATE_DIR="${UPTIME_STATE_DIR:-/var/lib/freedom-yield}"
mkdir -p "$STATE_DIR"
PEERS_JSON="$OUT" \
NAMES_JSON="$NAMES_TMP" \
STATE_DIR="$STATE_DIR" \
OUT_CHANGES="${ROOT}/public/api/peers-changes.json" \
OUT_GINI="${ROOT}/public/api/peers-gini.json" \
OUT_GINI_HISTORY="${ROOT}/public/api/peers-gini-history.jsonl" \
GEN_ISO="$GEN_ISO" \
python3 "${ROOT}/scripts/peer-analytics.py"

# ─────────────────────── Phase β: daily full peers snapshot archive ──
# Gzip + stash a snapshot of peers.json into the master archive. One
# file per day (YYYY-MM-DD), idempotent on same-day reruns. Lets us
# answer "what was the validator set on date X?" months/years later
# without keeping 200 KB × 365 = 73 MB of uncompressed copies.
SNAPSHOT_DIR="${STATE_DIR}/peers-history"
mkdir -p "$SNAPSHOT_DIR"
TODAY=$(date -u +%Y-%m-%d)
SNAPSHOT="${SNAPSHOT_DIR}/peers-${TODAY}.json.gz"
gzip -c "$OUT" > "$SNAPSHOT"
SNAP_SIZE=$(stat -c%s "$SNAPSHOT" 2>/dev/null || stat -f%z "$SNAPSHOT")
echo "stashed daily snapshot: $SNAPSHOT (${SNAP_SIZE} bytes gzipped)"

# Update the index — a small JSON listing all known snapshot dates +
# their sizes. The catalog can fetch this to show a date picker.
SNAPSHOT_INDEX="${ROOT}/public/api/peers-history-index.json"
python3 -c "
import os, json, glob, datetime
files = sorted(glob.glob('${SNAPSHOT_DIR}/peers-*.json.gz'))
entries = []
for f in files:
    name = os.path.basename(f)
    date = name.replace('peers-', '').replace('.json.gz', '')
    entries.append({'date': date, 'size_bytes': os.path.getsize(f), 'filename': name})
print(json.dumps({'generated_at': '${GEN_ISO}', 'count': len(entries), 'entries': entries}, indent=2))
" > "$SNAPSHOT_INDEX"
echo "wrote $SNAPSHOT_INDEX ($(jq '.count' "$SNAPSHOT_INDEX") snapshots indexed)"

trap - EXIT
