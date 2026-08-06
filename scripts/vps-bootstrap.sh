#!/usr/bin/env bash
# VPS bootstrap — provision a fresh Ubuntu 22.04 VPS to host the Metal
# Blockchain validator + Caddy + this site.
#
# Usage (on a brand-new validator host VPS, as root):
#   curl -fsSLO https://raw.githubusercontent.com/<owner>/metal.freedom-yield.com/main/scripts/vps-bootstrap.sh
#   bash vps-bootstrap.sh
#
# Idempotent: rerunning is safe. Does NOT touch staker keys — those
# are deployed separately from the encrypted backup (see docs/DISASTER_RECOVERY.md).
#
# Variables you may override before running:
#   DEPLOY_USER       (default: <deploy_user>) — non-root user that GitHub Actions SSHes in as
#   DEPLOY_DIR        (default: /home/$DEPLOY_USER/metal.freedom-yield.com)
#   GITHUB_DEPLOY_PUBKEY  — paste here to auto-register the GitHub Actions deploy key
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/$DEPLOY_USER/metal.freedom-yield.com}"
GITHUB_DEPLOY_PUBKEY="${GITHUB_DEPLOY_PUBKEY:-}"

log() { printf '\n=== %s ===\n' "$*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (sudo bash vps-bootstrap.sh)" >&2
    exit 1
  fi
}

step_packages() {
  log "Step 1/8: apt update + install required packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    docker.io \
    docker-compose-v2 \
    ufw \
    fail2ban \
    git \
    jq \
    curl \
    bc
  systemctl enable --now docker
  systemctl enable --now fail2ban
}

step_firewall() {
  log "Step 2/8: ufw firewall (deny incoming, allow 22/80/443/9651)"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 9651/tcp >/dev/null
  ufw --force enable >/dev/null
  ufw status verbose | grep -E '^(Status|22|80|443|9651)'
}

step_ssh_hardening() {
  log "Step 3/8: SSH hardening (PasswordAuthentication no, key-only)"
  cat > /etc/ssh/sshd_config.d/99-disable-password.conf <<'EOF'
# Disable password-based SSH (key-only) — defense in depth
# Managed by scripts/vps-bootstrap.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  sshd -t
  systemctl reload ssh
  sshd -T 2>/dev/null | grep -E '^(passwordauthentication|kbdinteractive|permitrootlogin)' | sort
}

step_deploy_user() {
  log "Step 4/8: deploy user + SSH access for GitHub Actions"
  if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$DEPLOY_USER"
    usermod -aG docker "$DEPLOY_USER"
  fi
  install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
  touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
  chmod 0600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh/authorized_keys"
  if [ -n "$GITHUB_DEPLOY_PUBKEY" ]; then
    if ! grep -qF "$GITHUB_DEPLOY_PUBKEY" "/home/$DEPLOY_USER/.ssh/authorized_keys"; then
      echo "$GITHUB_DEPLOY_PUBKEY" >> "/home/$DEPLOY_USER/.ssh/authorized_keys"
      echo "Registered GitHub Actions deploy pubkey"
    fi
  else
    echo "NOTE: GITHUB_DEPLOY_PUBKEY not set — paste GitHub Actions pubkey to"
    echo "      /home/$DEPLOY_USER/.ssh/authorized_keys manually."
  fi
}

step_repo() {
  log "Step 5/8: clone or pull the repository"
  if [ ! -d "$DEPLOY_DIR/.git" ]; then
    sudo -u "$DEPLOY_USER" git clone https://github.com/freedomyield/metal.freedom-yield.com.git "$DEPLOY_DIR"
  else
    sudo -u "$DEPLOY_USER" git -C "$DEPLOY_DIR" pull --ff-only
  fi
  ls -la "$DEPLOY_DIR" | head -10
}

step_server_status_cron() {
  log "Step 6c/8: install 1-minute server-status.json refresh cron (ops dashboard)"
  cat > /etc/cron.d/metal-server-status <<EOF
# Refresh ops dashboard data every 1 minute.
* * * * * $DEPLOY_USER bash $DEPLOY_DIR/scripts/server-status.sh >> /var/log/server-status.log 2>&1
EOF
  chmod 644 /etc/cron.d/metal-server-status
  touch /var/log/server-status.log
  chown "$DEPLOY_USER:$DEPLOY_USER" /var/log/server-status.log
  chmod 644 /var/log/server-status.log
  cat > /etc/logrotate.d/server-status <<EOF
/var/log/server-status.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
  create 644 $DEPLOY_USER $DEPLOY_USER
}
EOF
  # deploy user needs docker group for `docker inspect` calls in server-status.sh
  usermod -aG docker "$DEPLOY_USER" 2>/dev/null || true
  systemctl restart cron
}

step_node_info_cron() {
  log "Step 6a/8: install 5-minute validator.json refresh cron"
  # PWA countdown / explorer link / public stake values are read from
  # public/api/validator.json, which is refreshed by this cron from metalgo.
  cat > /etc/cron.d/metal-node-info <<EOF
# Refresh public/api/validator.json every 5 minutes.
*/5 * * * * $DEPLOY_USER cd $DEPLOY_DIR && bash scripts/node-info.sh >> /var/log/node-info.log 2>&1
EOF
  chmod 644 /etc/cron.d/metal-node-info
  touch /var/log/node-info.log
  chown "$DEPLOY_USER:$DEPLOY_USER" /var/log/node-info.log
  chmod 644 /var/log/node-info.log
  cat > /etc/logrotate.d/node-info <<EOF
/var/log/node-info.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
  create 644 $DEPLOY_USER $DEPLOY_USER
}
EOF
  systemctl restart cron
  ls -la /etc/cron.d/metal-node-info /etc/logrotate.d/node-info
}

step_daily_status_cron() {
  log "Step 6e/8: install daily status digest cron (09:00 JST = 00:00 UTC)"
  cat > /etc/cron.d/metal-daily-status <<EOF
# Daily status push at 09:00 JST (00:00 UTC). Default priority (quiet).
# Aligned with the operator's quiet-hours window (notify.sh suppresses
# non-urgent notifications 22:00–09:00 JST).
# FY_LIVE=1 required: scripts/lib/side-effects.sh (C3 rollout, 2026-08-06)
# gates every production side effect behind FY_LIVE=1; daily-status.sh
# sends a real ntfy push. See check-cron-file.sh Rule 6.
FY_LIVE=1
0 0 * * * $DEPLOY_USER bash $DEPLOY_DIR/scripts/daily-status.sh >> /var/log/daily-status.log 2>&1
EOF
  chmod 644 /etc/cron.d/metal-daily-status
  touch /var/log/daily-status.log
  chown "$DEPLOY_USER:$DEPLOY_USER" /var/log/daily-status.log
  chmod 644 /var/log/daily-status.log
  cat > /etc/logrotate.d/daily-status <<EOF
/var/log/daily-status.log {
  daily
  rotate 14
  missingok
  notifempty
  compress
  delaycompress
  create 0644 $DEPLOY_USER $DEPLOY_USER
}
EOF
  systemctl restart cron
}

step_anomaly_cron() {
  log "Step 6d/8: install 5-minute anomaly detector cron (ntfy.sh push)"
  mkdir -p /var/lib/freedom-yield
  chown "$DEPLOY_USER:$DEPLOY_USER" /var/lib/freedom-yield
  if [ ! -f /etc/freedom-yield/ntfy-topic ]; then
    mkdir -p /etc/freedom-yield
    openssl rand -hex 16 | (echo -n ""; cat) > /etc/freedom-yield/ntfy-topic
    chown root:"$DEPLOY_USER" /etc/freedom-yield/ntfy-topic
    chmod 640 /etc/freedom-yield/ntfy-topic
    echo "Generated new ntfy topic at /etc/freedom-yield/ntfy-topic — read it and subscribe in the ntfy Android app."
  fi
  cat > /etc/cron.d/metal-anomalies <<EOF
# FY_LIVE=1 required: scripts/lib/side-effects.sh (C3 rollout, 2026-08-06)
# gates every production side effect behind FY_LIVE=1; check-anomalies.sh
# sends real ntfy pushes and writes ANOMALY_STATE_DIR. See
# check-cron-file.sh Rule 6.
FY_LIVE=1
*/5 * * * * $DEPLOY_USER bash $DEPLOY_DIR/scripts/check-anomalies.sh >> /var/log/anomalies.log 2>&1
EOF
  chmod 644 /etc/cron.d/metal-anomalies
  touch /var/log/anomalies.log
  chown "$DEPLOY_USER:$DEPLOY_USER" /var/log/anomalies.log
  chmod 644 /var/log/anomalies.log
  cat > /etc/logrotate.d/anomalies <<EOF
/var/log/anomalies.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
  create 644 $DEPLOY_USER $DEPLOY_USER
}
EOF
  systemctl restart cron
}

step_period_check_cron() {
  log "Step 6b/8: install daily validator-period check cron"
  cp "$DEPLOY_DIR/scripts/check-validator-period.sh" /usr/local/bin/check-validator-period.sh 2>/dev/null \
    || cat > /usr/local/bin/check-validator-period.sh <<'CRON_SCRIPT'
#!/usr/bin/env bash
# Daily check of remaining validator period. Logs to /var/log/validator-period.log.
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
CRON_SCRIPT
  chmod +x /usr/local/bin/check-validator-period.sh
  ln -sf /usr/local/bin/check-validator-period.sh /etc/cron.daily/check-validator-period
  ls -la /etc/cron.daily/check-validator-period
}

step_metalgo() {
  log "Step 7/8: bring up metalgo (mainnet) — staker keys must be in place first"
  STAKING_DIR=/var/lib/docker/volumes/metalgo_data/_data/staking
  if [ ! -f "$STAKING_DIR/staker.crt" ]; then
    echo "WARNING: $STAKING_DIR/staker.crt not found."
    echo "         Restore from encrypted backup before continuing:"
    echo "           1. scp staker-backup.tar.gz.enc to this VPS"
    echo "           2. openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \\"
    echo "                -in staker-backup.tar.gz.enc -out /tmp/restore.tar.gz"
    echo "           3. mkdir -p $STAKING_DIR && tar xzf /tmp/restore.tar.gz -C /tmp"
    echo "           4. mv /tmp/staker-backup/staking/* $STAKING_DIR/"
    echo "           5. chmod 600 $STAKING_DIR/* && chown root:root $STAKING_DIR/*"
    echo "         Then re-run this script (Step 7 will then start metalgo)."
    return 0
  fi
  cd "$DEPLOY_DIR"
  docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml up -d
  sleep 10
  echo "NodeID check:"
  curl -sS -X POST -H 'content-type:application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
    http://localhost:9650/ext/info | jq -r '.result.nodeID // "not ready yet"'
}

step_caddy() {
  log "Step 8/8: bring up Caddy + site"
  cd "$DEPLOY_DIR"
  if [ ! -f .env ]; then
    echo "NOTE: .env not present. Create it with DOMAIN= and ACME_EMAIL= before starting Caddy."
    return 0
  fi
  docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
  sleep 5
  docker ps --filter name=caddy-static --format 'table {{.Names}}\t{{.Status}}'
}

main() {
  require_root
  step_packages
  step_firewall
  step_ssh_hardening
  step_deploy_user
  step_repo
  step_node_info_cron
  step_server_status_cron
  step_anomaly_cron
  step_daily_status_cron
  step_period_check_cron
  step_metalgo
  step_caddy
  log "DONE. Verify with:"
  echo "  - bash scripts/node-info.sh (expect NodeID-yyPvtQHTA4...)"
  echo "  - curl -I http://localhost (expect Caddy 200/302)"
  echo "  - tail /var/log/validator-period.log"
}

main "$@"
