#!/usr/bin/env bash
# Daily check of remaining validator period. Logs to /var/log/validator-period.log.
# Installed by scripts/vps-bootstrap.sh under /etc/cron.daily/check-validator-period.
set -euo pipefail
LOG=/var/log/validator-period.log
API=http://localhost:9650

NODE_ID=$(curl -sS -X POST -H content-type:application/json \
  --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
  "${API}/ext/info" | jq -r .result.nodeID)

if [ -z "${NODE_ID:-}" ] || [ "$NODE_ID" = "null" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR cannot read NodeID" | tee -a "$LOG"
  exit 1
fi

END_TIME=$(curl -sS -X POST -H content-type:application/json \
  --data '{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{}}' \
  "${API}/ext/bc/P" \
  | jq -r --arg id "$NODE_ID" '.result.validators[]? | select(.nodeID == $id) | .endTime // empty' | head -1)

if [ -z "$END_TIME" ] || [ "$END_TIME" = "null" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WARN validator entry NOT FOUND for $NODE_ID (period may have ended)" | tee -a "$LOG"
  exit 0
fi

NOW=$(date +%s)
DAYS_LEFT=$(( (END_TIME - NOW) / 86400 ))
END_HUMAN=$(date -d "@$END_TIME" -u +%Y-%m-%dT%H:%M:%SZ)

LEVEL=INFO
if [ "$DAYS_LEFT" -le 3 ]; then LEVEL=CRITICAL
elif [ "$DAYS_LEFT" -le 7 ]; then LEVEL=WARN
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $LEVEL endTime=$END_HUMAN days_left=$DAYS_LEFT NodeID=$NODE_ID" | tee -a "$LOG"
