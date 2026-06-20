#!/usr/bin/env bash
# Emit /srv/api/server-status.json with operator-only host metrics.
# Designed to be invoked from cron every minute.
# Output is served via the ops vhost (Caddy :8443) behind BasicAuth.
# Public access is blocked by the public vhost's deny rule.
set -euo pipefail

# Resolve repository root from script location if REPO_BASE is not set.
REPO_BASE="${REPO_BASE:-$(cd "$(dirname "$0")/.." && pwd)}"

# OUT override is honoured so fixture tests can target /tmp without touching prod.
OUT="${OUT:-${REPO_BASE}/public/api/server-status.json}"
API="${METALGO_API:-http://localhost:9650}"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# === host metrics =====================================================
LOAD1=$(awk '{print $1}' /proc/loadavg)
LOAD5=$(awk '{print $2}' /proc/loadavg)
LOAD15=$(awk '{print $3}' /proc/loadavg)

# CPU usage percent (rough, from /proc/stat over a short sample)
read -r _ user1 nice1 sys1 idle1 _ < /proc/stat
sleep 1
read -r _ user2 nice2 sys2 idle2 _ < /proc/stat
busy=$(( (user2-user1) + (nice2-nice1) + (sys2-sys1) ))
total=$(( busy + (idle2-idle1) ))
if [ "$total" -gt 0 ]; then
  CPU_PCT=$(awk -v b="$busy" -v t="$total" 'BEGIN{printf "%.1f", b/t*100}')
else
  CPU_PCT=0
fi

# RAM
MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
MEM_USED_KB=$(( MEM_TOTAL_KB - MEM_AVAIL_KB ))
MEM_PCT=$(awk -v u="$MEM_USED_KB" -v t="$MEM_TOTAL_KB" 'BEGIN{printf "%.1f", u/t*100}')

# Disk (root filesystem)
DISK_LINE=$(df -kP / | awk 'NR==2')
DISK_USED_KB=$(echo "$DISK_LINE" | awk '{print $3}')
DISK_TOTAL_KB=$(echo "$DISK_LINE" | awk '{print $2}')
DISK_PCT=$(echo "$DISK_LINE" | awk '{gsub("%","",$5); print $5}')

# Uptime (host)
UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)

# === metalgo peer count + chain heights ===============================
PEERS=$(curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"info.peers"}' \
  --max-time 3 \
  "$API/ext/info" 2>/dev/null | jq -r '.result.numPeers // "null"')

P_HEIGHT=$(curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"platform.getHeight"}' \
  --max-time 3 \
  "$API/ext/bc/P" 2>/dev/null | jq -r '.result.height // "null"')

C_HEIGHT_HEX=$(curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  --max-time 3 \
  "$API/ext/bc/C/rpc" 2>/dev/null | jq -r '.result // "0x0"')
C_HEIGHT=$((C_HEIGHT_HEX))

# Container statuses (docker).
# Container names are runtime configuration (compose project prefix differs by
# host); inject via env so script and host-specific values stay decoupled.
: "${METALGO_CONTAINER:?METALGO_CONTAINER is required}"
: "${CADDY_CONTAINER:?CADDY_CONTAINER is required}"

# docker inspect emits a stray '\n' on stdout when the object is missing, which
# survives inside $(... || echo "missing") and produces invalid JSON downstream.
# inspect_status returns non-zero on failure so the caller can abort before publish.
inspect_status() {
  local out
  if out=$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null); then
    out=$(printf '%s' "$out" | tr -d '\r\n\t')
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  return 1
}

# Capture explicitly via if-conditional so non-zero from inspect_status is preserved.
if ! METALGO_STATUS=$(inspect_status "$METALGO_CONTAINER"); then
  echo "ERROR: docker inspect failed for METALGO_CONTAINER=$METALGO_CONTAINER; keeping last-known-good $OUT" >&2
  exit 5
fi
if ! CADDY_STATUS=$(inspect_status "$CADDY_CONTAINER"); then
  echo "ERROR: docker inspect failed for CADDY_CONTAINER=$CADDY_CONTAINER; keeping last-known-good $OUT" >&2
  exit 5
fi

# fail2ban currently banned (sshd jail)
# fail2ban-client typically requires root; deploy will get permission denied.
# Tolerate failure so set -e doesn't abort the whole script.
F2B_BANNED=$( (fail2ban-client status sshd 2>/dev/null || true) \
  | awk -F'\t' '/Currently banned/ {gsub(/^ */, "", $2); print $2}')
F2B_BANNED="${F2B_BANNED:-null}"

# === assemble JSON =====================================================
TMP=$(mktemp)
ERR=$(mktemp)
if ! jq -n \
    --arg     observedAt  "$NOW" \
    --argjson load1       "$LOAD1" \
    --argjson load5       "$LOAD5" \
    --argjson load15      "$LOAD15" \
    --argjson cpu         "$CPU_PCT" \
    --argjson memTotalKB  "$MEM_TOTAL_KB" \
    --argjson memUsedKB   "$MEM_USED_KB" \
    --argjson memPct      "$MEM_PCT" \
    --argjson diskTotalKB "$DISK_TOTAL_KB" \
    --argjson diskUsedKB  "$DISK_USED_KB" \
    --argjson diskPct     "$DISK_PCT" \
    --argjson uptime      "$UPTIME_SEC" \
    --arg     metalgoStat "$METALGO_STATUS" \
    --argjson peerCount   "$PEERS" \
    --argjson pHeight     "$P_HEIGHT" \
    --argjson cHeight     "$C_HEIGHT" \
    --arg     caddyStat   "$CADDY_STATUS" \
    --argjson f2bBanned   "$F2B_BANNED" \
    '{
      observedAt: $observedAt,
      host: {
        load:   { "1m": $load1, "5m": $load5, "15m": $load15 },
        cpu:    { usedPercent: $cpu },
        memory: { totalKB: $memTotalKB, usedKB: $memUsedKB, usedPercent: $memPct },
        disk:   { totalKB: $diskTotalKB, usedKB: $diskUsedKB, usedPercent: $diskPct },
        uptimeSec: $uptime
      },
      metalgo: {
        containerStatus: $metalgoStat,
        peerCount:       $peerCount,
        pChainHeight:    $pHeight,
        cChainHeight:    $cHeight
      },
      caddy:    { containerStatus: $caddyStat },
      security: { fail2banSshBanned: $f2bBanned }
    }' > "$TMP" 2> "$ERR"; then
  echo "ERROR: jq generation failed: $(cat "$ERR")" >&2
  rm -f "$TMP" "$ERR"
  exit 2
fi
rm -f "$ERR"

# Syntactic gate.
if ! jq empty "$TMP" >/dev/null 2>&1; then
  echo "ERROR: generated JSON failed jq empty; keeping last-known-good $OUT" >&2
  rm -f "$TMP"
  exit 3
fi

# Semantic gate. Refuse to publish syntactically valid but semantically broken JSON.
sem_fail=0
sem_check() {
  jq -e "$1" "$TMP" >/dev/null 2>&1 || {
    echo "ERROR: semantic check failed: $2" >&2
    sem_fail=$((sem_fail + 1))
  }
}
sem_check '.observedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' 'observedAt is UTC ISO-8601'
sem_check '.metalgo.containerStatus | type == "string" and length > 0' 'metalgo.containerStatus non-empty'
sem_check '.caddy.containerStatus   | type == "string" and length > 0' 'caddy.containerStatus non-empty'
sem_check '.metalgo.peerCount       | type == "number" and . >= 0 and (. | floor == .)' 'peerCount integer >= 0'
sem_check '.host.cpu.usedPercent    | type == "number" and . >= 0 and . <= 100' 'cpu usedPercent in 0..100'
sem_check '.host.memory.usedPercent | type == "number" and . >= 0 and . <= 100' 'memory usedPercent in 0..100'
sem_check '.host.disk.usedPercent   | type == "number" and . >= 0 and . <= 100' 'disk usedPercent in 0..100'
sem_check '.host.uptimeSec          | type == "number" and . >= 0' 'uptimeSec >= 0'
sem_check 'has("observedAt") and has("host") and has("metalgo") and has("caddy") and has("security")' 'required top-level keys present'
if [ "$sem_fail" -ne 0 ]; then
  echo "ERROR: $sem_fail semantic failure(s); keeping last-known-good $OUT" >&2
  rm -f "$TMP"
  exit 4
fi

# move atomically (cron-safe — readers never see a half-written file)
mv "$TMP" "$OUT"
chmod 644 "$OUT"
