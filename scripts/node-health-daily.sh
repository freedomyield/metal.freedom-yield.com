#!/usr/bin/env bash
# node-health-daily.sh — once-a-day snapshot of host + metalgo health,
# kept FOREVER. Phase γ #3.
#
# The minute-level server-status.json (server-status.sh) is realtime,
# overwritten, ops-only. This script samples once a day and append-only
# persists the operationally interesting subset:
#   - host: load, cpu, ram, disk, host_uptime
#   - metalgo: container status, peer count, P/C chain heights, bootstrap
#
# Two output files:
#   /var/lib/freedom-yield/node-health-history.jsonl
#     validator host master. Append-only. KEEP FOREVER. Full schema.
#     ~250 bytes/day → 90 KB/year → 1 MB / 11 years. Trivial.
#
#   public/api/node-health-recent.json
#     Public preview, last 90 days. Sanitized subset (peer count, chain
#     heights, bootstrap, container status). Host CPU/RAM/disk are
#     NOT exposed publicly — they stay in the validator host master only,
#     since detailed host metrics are operationally sensitive
#     (upgrade timing signals, capacity headroom etc.).
#
# This script does NOT push anything itself; cron handles push.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS_JSON="${STATUS_JSON:-$ROOT/public/api/server-status.json}"
STATE_DIR="${UPTIME_STATE_DIR:-/var/lib/freedom-yield}"
HIST_JSONL="${STATE_DIR}/node-health-history.jsonl"
OUT_PUBLIC="${ROOT}/public/api/node-health-recent.json"
RECENT_DAYS="${RECENT_DAYS:-90}"
API="${METALGO_API:-http://localhost:9650}"

mkdir -p "$STATE_DIR"
[ -f "$HIST_JSONL" ] || : > "$HIST_JSONL"

# probe_bootstrapped <chain> — read-only query of metalgo's own
# info.isBootstrapped RPC (no broadcast). Prints "true" / "false" / "null".
# "null" means unprobeable (RPC unreachable, malformed response, or a
# field of unexpected type) — it is never coerced to a fabricated true/false.
# `|| true` on each capture keeps a transient metalgo/RPC hiccup from
# aborting the whole daily snapshot under `set -e`.
probe_bootstrapped() {
  local chain="$1" resp val
  resp=$(curl -sS -X POST --max-time 5 \
    -H 'content-type:application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"${chain}\"}}" \
    "${API}/ext/info" 2>/dev/null || true)
  # NOTE: deliberately NOT `.result.isBootstrapped // empty` — jq's `//`
  # treats a `false` result as falsy too, so that filter would silently
  # turn a real "not bootstrapped" into "unknown". Test for boolean type
  # explicitly instead.
  val=$(printf '%s' "${resp}" | jq -r '
      if (.result.isBootstrapped | type) == "boolean"
      then (.result.isBootstrapped | tostring)
      else "null"
      end
    ' 2>/dev/null || true)
  case "$val" in
    true|false) printf '%s' "$val" ;;
    *)          printf 'null' ;;
  esac
}

if [ ! -f "$STATUS_JSON" ]; then
  echo "ERROR: $STATUS_JSON not found (is server-status.sh running?)" >&2
  exit 1
fi

TODAY=$(date -u +%Y-%m-%d)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Idempotency: never append twice for the same UTC date.
if grep -q "^{\"date\":\"${TODAY}\"" "$HIST_JSONL" 2>/dev/null; then
  echo "node-health: entry for $TODAY already present, skipping"
  exit 0
fi

# Actual probed bootstrap status (never a fabricated constant — see
# probe_bootstrapped above). Probed here, after the idempotency check, so a
# no-op run doesn't spend an RPC round-trip it won't use.
BOOT_P=$(probe_bootstrapped P)
BOOT_X=$(probe_bootstrapped X)
BOOT_C=$(probe_bootstrapped C)

# Read the realtime snapshot. server-status.sh writes atomically so the
# file is always parseable.
ENTRY=$(jq -c \
  --arg date "$TODAY" \
  --arg now "$NOW_ISO" \
  --argjson bootP "$BOOT_P" \
  --argjson bootX "$BOOT_X" \
  --argjson bootC "$BOOT_C" \
  '{
    date: $date,
    observed_at: $now,
    host: {
      load_1m:        .host.load["1m"],
      load_5m:        .host.load["5m"],
      load_15m:       .host.load["15m"],
      cpu_pct:        .host.cpu.usedPercent,
      mem_used_kb:    .host.memory.usedKB,
      mem_total_kb:   .host.memory.totalKB,
      mem_pct:        .host.memory.usedPercent,
      disk_used_kb:   .host.disk.usedKB,
      disk_total_kb:  .host.disk.totalKB,
      disk_pct:       .host.disk.usedPercent,
      host_uptime_sec: .host.uptimeSec
    },
    metalgo: {
      container_status: .metalgo.containerStatus,
      peer_count:       .metalgo.peerCount,
      p_chain_height:   .metalgo.pChainHeight,
      c_chain_height:   .metalgo.cChainHeight
    },
    bootstrap: {
      p: $bootP, x: $bootX, c: $bootC
    }
  }' "$STATUS_JSON")

echo "$ENTRY" >> "$HIST_JSONL"
echo "node-health: appended $TODAY"

# === regenerate public preview (sanitized subset, last RECENT_DAYS) ====
# Public-safe fields only: nothing that would reveal host capacity or
# upgrade timing. Peer count + chain heights + bootstrap are sufficient
# to demonstrate "validator is fully sync'd and well-connected".
tail -n "$RECENT_DAYS" "$HIST_JSONL" \
  | jq -s --arg gen "$NOW_ISO" --argjson days "$RECENT_DAYS" '
      {
        generated_at: $gen,
        window_days:  $days,
        entries: [.[] | {
          date: .date,
          observed_at: .observed_at,
          peer_count:     .metalgo.peer_count,
          p_chain_height: .metalgo.p_chain_height,
          c_chain_height: .metalgo.c_chain_height,
          container_status: .metalgo.container_status,
          bootstrap: .bootstrap
        }]
      }' > "${OUT_PUBLIC}.tmp"
mv "${OUT_PUBLIC}.tmp" "$OUT_PUBLIC"
echo "wrote $OUT_PUBLIC ($(jq '.entries | length' "$OUT_PUBLIC") entries)"
