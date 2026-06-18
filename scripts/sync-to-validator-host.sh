#!/bin/bash
# Sync the validator-side scripts (scripts/*) from this repo working copy
# to the validator host validator host. Required after editing any script that
# runs on validator host (cron-invoked node-info.sh, peer-geo.py, push-to-web-host.sh,
# check-validator-*.sh, etc.) because the GitHub Actions deploy targets
# the web host web host, not validator host.
#
# Usage:
#   VALIDATOR_HOST=<ip>  ./scripts/sync-to-validator-host.sh             # default key
#   VALIDATOR_HOST=<ip>  VALIDATOR_HOST_KEY=~/.ssh/foo  ./scripts/sync-to-validator-host.sh
#   VALIDATOR_HOST=<ip>  ./scripts/sync-to-validator-host.sh --dry-run   # show what would transfer
#
# Env:
#   VALIDATOR_HOST  — IP / hostname of the validator host (REQUIRED; never
#                   hardcoded so the repo can stay public-safe)
#   VALIDATOR_HOST_KEY   — SSH private key (default: ~/.ssh/<your_validator_host_key>)
#   VALIDATOR_HOST_USER  — SSH user (default: root)
#   REMOTE_PATH   — target directory (default: ${REPO_BASE:-/path/to/your/repo}/scripts/)
#
# Behaviour:
#   - rsync only the scripts/ directory (not public/, not caddy/, not docker-compose/*).
#   - --inplace to preserve inode for any bind-mounted file (same rule as Caddyfile).
#   - --chmod=u=rwx,go=rx so the target files stay executable for `deploy` user.
#   - chown deploy:deploy on the remote after rsync so cron(running as deploy) can read them.
set -euo pipefail

# Resolve repository root from script location if REPO_BASE is not set.
REPO_BASE="${REPO_BASE:-$(cd "$(dirname "$0")/.." && pwd)}"

: "${VALIDATOR_HOST:?VALIDATOR_HOST env var is required (e.g. VALIDATOR_HOST=203.0.113.11 ./scripts/sync-to-validator-host.sh)}"
: "${VALIDATOR_HOST_KEY:=$HOME/.ssh/<your_validator_host_key>}"
: "${VALIDATOR_HOST_USER:=root}"
: "${REMOTE_PATH:=${REPO_BASE:-/path/to/your/repo}/scripts/}"

[ -f "$VALIDATOR_HOST_KEY" ] || { echo "ERROR: SSH key not found: $VALIDATOR_HOST_KEY" >&2; exit 1; }

# Resolve repo root so this script can be run from anywhere
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_PATH="${REPO_ROOT}/scripts/"

DRY_RUN=""
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then
  DRY_RUN="n"
fi

echo "Syncing ${LOCAL_PATH} -> ${VALIDATOR_HOST_USER}@${VALIDATOR_HOST}:${REMOTE_PATH}"
echo "Key: ${VALIDATOR_HOST_KEY}"
[ -n "$DRY_RUN" ] && echo "(dry-run, no changes will be made)"

rsync -rtvz${DRY_RUN} --inplace \
  --chmod=u=rwx,go=rx \
  -e "ssh -i ${VALIDATOR_HOST_KEY}" \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='operator-local/' \
  "${LOCAL_PATH}" \
  "${VALIDATOR_HOST_USER}@${VALIDATOR_HOST}:${REMOTE_PATH}"

if [ -z "$DRY_RUN" ]; then
  # cron runs as `deploy`, so files must be readable by deploy user
  ssh -i "${VALIDATOR_HOST_KEY}" "${VALIDATOR_HOST_USER}@${VALIDATOR_HOST}" \
    "chown -R deploy:deploy '${REMOTE_PATH}' && chmod 755 ${REMOTE_PATH}*.sh ${REMOTE_PATH}*.py 2>/dev/null || true"
  echo "✓ chown deploy:deploy applied"
fi
