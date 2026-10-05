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
  # 2026-08-06 (H2): SHELL/PATH headers (Rule 5) and the brace-wrapped
  # start/end markers + rc=$? capture (Rules 2/3) were missing here — the
  # linter (scripts/check-cron-file.sh) was never green against this
  # template's own output. Schedule/user/command body/log target below are
  # UNCHANGED; only the audit-visibility wrapper was added. See
  # docs/CRON_CONVENTIONS.md rules 2/3/5.
  cat > /etc/cron.d/metal-server-status <<EOF
# Refresh ops dashboard data every 1 minute.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * $DEPLOY_USER { echo "=== metal-server-status start \$(date -u +\%FT\%TZ) ==="; bash $DEPLOY_DIR/scripts/server-status.sh; rc=\$?; echo "=== metal-server-status end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /var/log/server-status.log 2>&1
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
  # 2026-08-06 (H2): SHELL/PATH headers (Rule 5) and the brace-wrapped
  # start/end markers + rc=$? capture (Rules 2/3) were missing — this was
  # the un-braced `&&` chain the H2 audit cited by name (only the last
  # command's redirect actually applied; node-info.sh's own stdout/stderr
  # never reached the log). Schedule/user/command body/log target below are
  # UNCHANGED; only the audit-visibility wrapper was added.
  cat > /etc/cron.d/metal-node-info <<EOF
# Refresh public/api/validator.json every 5 minutes.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * $DEPLOY_USER { echo "=== metal-node-info start \$(date -u +\%FT\%TZ) ==="; cd $DEPLOY_DIR && bash scripts/node-info.sh; rc=\$?; echo "=== metal-node-info end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /var/log/node-info.log 2>&1
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
  # 2026-08-06 (H2): SHELL/PATH headers (Rule 5) and the brace-wrapped
  # start/end markers + rc=$? capture (Rules 2/3) were missing here.
  # Schedule/user/command body/log target below are UNCHANGED; only the
  # audit-visibility wrapper was added.
  cat > /etc/cron.d/metal-daily-status <<EOF
# Daily status push at 09:00 JST (00:00 UTC). Default priority (quiet).
# Aligned with the operator's quiet-hours window (notify.sh suppresses
# non-urgent notifications 22:00–09:00 JST).
# FY_LIVE=1 required: scripts/lib/side-effects.sh (C3 rollout, 2026-08-06)
# gates the side effects routed through it behind FY_LIVE=1; daily-status.sh
# sends a real ntfy push. See check-cron-file.sh Rule 6.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
0 0 * * * $DEPLOY_USER { echo "=== metal-daily-status start \$(date -u +\%FT\%TZ) ==="; bash $DEPLOY_DIR/scripts/daily-status.sh; rc=\$?; echo "=== metal-daily-status end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /var/log/daily-status.log 2>&1
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
  # 2026-08-06 (H2): SHELL/PATH headers (Rule 5) and the brace-wrapped
  # start/end markers + rc=$? capture (Rules 2/3) were missing here.
  # Schedule/user/command body/log target below are UNCHANGED; only the
  # audit-visibility wrapper was added.
  cat > /etc/cron.d/metal-anomalies <<EOF
# ANOMALY_STATE_DIR=/var/lib/freedom-yield required: commit 57378ec
# (2026-06-20) added the \${ANOMALY_STATE_DIR:?required} guard to
# check-anomalies.sh but this template was never updated to match, which
# caused the 2026-06-24 resume incident (docs/postmortems/
# 2026-06-anomaly-monitoring-resume.md) — the first natural tick after
# uncommenting failed with "ANOMALY_STATE_DIR is required". The live host
# cron carries the line today (added out-of-band during that incident's
# recovery); this template did not, until now. mkdir -p above already
# provisions the directory.
#
# FY_LIVE=1 required: scripts/lib/side-effects.sh (C3 rollout, 2026-08-06)
# gates the side effects routed through it behind FY_LIVE=1; check-anomalies.sh
# sends real ntfy pushes and writes into ANOMALY_STATE_DIR. See
# check-cron-file.sh Rule 6.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
ANOMALY_STATE_DIR=/var/lib/freedom-yield
*/5 * * * * $DEPLOY_USER { echo "=== metal-anomalies start \$(date -u +\%FT\%TZ) ==="; bash $DEPLOY_DIR/scripts/check-anomalies.sh; rc=\$?; echo "=== metal-anomalies end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /var/log/anomalies.log 2>&1
EOF
  chmod 644 /etc/cron.d/metal-anomalies
  touch /var/log/anomalies.log
  chown "$DEPLOY_USER:$DEPLOY_USER" /var/log/anomalies.log
  chmod 644 /var/log/anomalies.log
  # 90-day retention for anomalies.log plus the public-site probe's
  # diagnostics / blip logs (web-probe design spec 2026-09-24 §3.5). Single
  # source: the installer also provisions the two web-probe logs
  # deploy-writable, as the touch/chown above does for anomalies.log.
  FYD_DEPLOY_USER="$DEPLOY_USER" bash "$DEPLOY_DIR/scripts/install-anomalies-logrotate.sh"
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

# The metalgo compose stack, exactly as step_metalgo starts it. Run from
# $DEPLOY_DIR so compose reads $DEPLOY_DIR/.env and derives the same project.
#
# stdin is ALWAYS /dev/null. When the existing /data volume carries a
# com.docker.compose.config-hash label that differs from what this compose file
# resolves to, `create` / `up` ask "Volume ... exists but doesn't match
# configuration in compose file. Recreate (data will be lost)?". Answering y
# deletes the volume = the staker keys = the NodeID. With no terminal on stdin
# compose takes the default (No) and keeps the volume (rehearsed 2026-10-05,
# docker compose v5.5.1), so a keystroke can never destroy the keys here.
# Never add -y / --yes to these calls.
#
# Adopt: when METALGO_DATA_VOLUME is set (environment or .env) this host keeps a
# /data volume that predates this repo, and docker-compose.metalgo.adopt.yml joins
# the -f list. It declares that volume `external: true`, so compose never creates,
# recreates (no "Recreate (data will be lost)?" at all) or deletes it, `down -v`
# included; if the volume is absent, create / up fail instead of starting on an
# empty one (rehearsed 2026-10-05). The rule is the same as in
# scripts/check-compose-naming.sh, which reports the file list it used.
metalgo_adopt_requested() {
  [ -n "${METALGO_DATA_VOLUME:-}" ] && return 0
  [ -f .env ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?METALGO_DATA_VOLUME[[:space:]]*=[[:space:]]*[^[:space:]#]' .env
}
metalgo_compose() {
  local files=(-f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml)
  if metalgo_adopt_requested; then
    files+=(-f docker-compose.metalgo.adopt.yml)
  fi
  docker compose "${files[@]}" "$@" </dev/null
}

# Print the host path that compose mounts at the metalgo container's /data —
# the directory that must hold staking/staker.{crt,key} and signer.key.
#
# Why not a fixed path: the volume name is <compose project>_metalgo_data, and
# the project comes from `name:` in docker-compose.metalgo.yml, an operator
# override (COMPOSE_PROJECT_NAME / -p), or METALGO_DATA_PATH replaces the
# volume with a bind mount. A hardcoded volume path (formerly
# /var/lib/docker/volumes/metalgo_data/_data, which compose never used) makes
# keys look missing, or lets them be placed where metalgo never reads them —
# metalgo then generates NEW keys and comes up with a different NodeID.
#
# Resolution: ask compose for its own metalgo container (creating it, never
# starting it, if absent) and read that container's /data mount source.
# Fails closed (non-zero, nothing created) when:
#   - a metalgo container from ANOTHER compose project exists on this host
#     (e.g. a stack created under an older project name): `up -d` from this
#     repo would start a second metalgo beside it on a fresh, empty volume;
#   - compose reports more than one metalgo container for this project;
#   - the /data mount source cannot be read.
resolve_metalgo_data_dir() {
  local all own own_short id foreign="" n src
  all=$(docker ps -a --no-trunc -q --filter label=com.docker.compose.service=metalgo) || {
    echo "ERROR: docker ps failed; cannot resolve the metalgo data dir" >&2; return 1; }
  own=$(metalgo_compose ps -a -q metalgo) || {
    echo "ERROR: docker compose ps failed (is .env complete?); cannot resolve the metalgo data dir" >&2; return 1; }
  own_short=$(printf '%s\n' "$own" | cut -c1-12)
  for id in $all; do
    printf '%s\n' "$own_short" | grep -qxF "$(printf '%s' "$id" | cut -c1-12)" || foreign="$foreign $id"
  done
  if [ -n "$foreign" ]; then
    echo "ERROR: a metalgo container from another compose project exists on this host:" >&2
    for id in $foreign; do
      docker inspect --format '         {{.Name}} project={{index .Config.Labels "com.docker.compose.project"}}' "$id" >&2 || true
    done
    echo "       Starting metalgo from this repo would create a second stack on a new, empty" >&2
    echo "       /data (new staker keys, different NodeID). Refusing. Reconcile by hand first" >&2
    echo "       (docs/DISASTER_RECOVERY.md, warning on compose project naming)." >&2
    echo "       If that container is this validator's current metalgo, set" >&2
    echo "       METALGO_COMPOSE_PROJECT / METALGO_CONTAINER_NAME / METALGO_DATA_VOLUME in .env to its names and" >&2
    echo "       confirm with scripts/check-compose-naming.sh (RESULT: MATCH) first." >&2
    return 1
  fi
  if [ -z "$own" ]; then
    metalgo_compose create metalgo >&2 || {
      echo "ERROR: docker compose create metalgo failed; cannot resolve the metalgo data dir" >&2; return 1; }
    own=$(metalgo_compose ps -a -q metalgo) || {
      echo "ERROR: docker compose ps failed after create" >&2; return 1; }
  fi
  n=$(printf '%s\n' "$own" | grep -c . || true)
  if [ "$n" -ne 1 ]; then
    echo "ERROR: expected exactly 1 metalgo container for this compose project, found $n. Refusing." >&2
    return 1
  fi
  src=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$own") || {
    echo "ERROR: docker inspect failed for the metalgo container" >&2; return 1; }
  if [ -z "$src" ]; then
    echo "ERROR: the metalgo container has no /data mount; cannot resolve the staking dir. Refusing." >&2
    return 1
  fi
  printf '%s\n' "$src"
}

step_metalgo() {
  log "Step 7/8: bring up metalgo (mainnet) — staker keys must be in place first"
  cd "$DEPLOY_DIR"
  if [ ! -f .env ]; then
    # Compose cannot even be evaluated without .env (METAL_NETWORK /
    # METAL_PUBLIC_IP are required), so no data dir can be resolved yet.
    # This is the expected state on the first run of a fresh host.
    echo "NOTE: $DEPLOY_DIR/.env not present — metalgo not started and its data dir not resolved."
    echo "      Create .env (docs/DISASTER_RECOVERY.md), restore the staker keys, then re-run."
    return 0
  fi
  local data_dir
  if ! data_dir=$(resolve_metalgo_data_dir); then
    echo "FATAL: could not resolve where compose mounts metalgo's /data; metalgo NOT started." >&2
    return 1
  fi
  STAKING_DIR="$data_dir/staking"
  if [ ! -f "$STAKING_DIR/staker.crt" ]; then
    echo "WARNING: $STAKING_DIR/staker.crt not found (resolved from the compose /data mount)."
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
  # On a host that already has a metalgo container (e.g. the current production
  # host, whose names predate this repo), compose must resolve to exactly that
  # project, container and /data volume, or `up` recreates metalgo on an empty
  # volume -> new staker keys -> a different NodeID. Refuse unless the
  # read-only verifier says MATCH (docs/DISASTER_RECOVERY.md, top warning).
  if [ -n "$(docker ps -aq --filter label=com.docker.compose.service=metalgo)" ]; then
    if ! bash "${COMPOSE_NAMING_CHECK:-scripts/check-compose-naming.sh}"; then
      echo "ERROR: compose names do not match the existing metalgo container;" >&2
      echo "       refusing to run compose up (set METALGO_COMPOSE_PROJECT /" >&2
      echo "       METALGO_CONTAINER_NAME / METALGO_DATA_VOLUME and METAL_* in .env and re-run" >&2
      echo "       scripts/check-compose-naming.sh)." >&2
      return 1
    fi
  fi
  metalgo_compose up -d
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

# VPS_BOOTSTRAP_SOURCED=1 lets tests source the step functions without
# provisioning anything. Not a BASH_SOURCE check: `curl ... | bash` must still run.
if [ "${VPS_BOOTSTRAP_SOURCED:-0}" != 1 ]; then
  main "$@"
fi
