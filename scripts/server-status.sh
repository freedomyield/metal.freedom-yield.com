#!/usr/bin/env bash
# Emit /srv/api/server-status.json with operator-only host metrics.
# Designed to be invoked from cron every minute.
# Output is served via the ops vhost (Caddy :8443) behind BasicAuth.
# Public access is blocked by the public vhost's deny rule.
set -euo pipefail

# Resolve repository root from script location if REPO_BASE is not set.
REPO_BASE="${REPO_BASE:-$(cd "$(dirname "$0")/.." && pwd)}"

OUT="${OUT:-${REPO_BASE:-/path/to/your/repo}/public/api/server-status.json}"
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

# Container statuses (docker)
METALGO_STATUS=$(docker inspect --format '{{.State.Status}}' metalgo-mainnet 2>/dev/null || echo "missing")
CADDY_STATUS=$(docker inspect --format '{{.State.Status}}' caddy-static 2>/dev/null || echo "missing")

# fail2ban currently banned (sshd jail)
# fail2ban-client typically requires root; deploy will get permission denied.
# Tolerate failure so set -e doesn't abort the whole script.
F2B_BANNED=$( (fail2ban-client status sshd 2>/dev/null || true) \
  | awk -F'\t' '/Currently banned/ {gsub(/^ */, "", $2); print $2}')
F2B_BANNED="${F2B_BANNED:-null}"

# === assemble JSON =====================================================
TMP=$(mktemp)
cat > "$TMP" <<EOF
{
	"observedAt": "$NOW",
	"host": {
		"load": { "1m": $LOAD1, "5m": $LOAD5, "15m": $LOAD15 },
		"cpu": { "usedPercent": $CPU_PCT },
		"memory": {
			"totalKB": $MEM_TOTAL_KB,
			"usedKB": $MEM_USED_KB,
			"usedPercent": $MEM_PCT
		},
		"disk": {
			"totalKB": $DISK_TOTAL_KB,
			"usedKB": $DISK_USED_KB,
			"usedPercent": $DISK_PCT
		},
		"uptimeSec": $UPTIME_SEC
	},
	"metalgo": {
		"containerStatus": "$METALGO_STATUS",
		"peerCount": $PEERS,
		"pChainHeight": $P_HEIGHT,
		"cChainHeight": $C_HEIGHT
	},
	"caddy": {
		"containerStatus": "$CADDY_STATUS"
	},
	"security": {
		"fail2banSshBanned": $F2B_BANNED
	}
}
EOF

# move atomically (cron-safe — readers never see a half-written file)
mv "$TMP" "$OUT"
chmod 644 "$OUT"
