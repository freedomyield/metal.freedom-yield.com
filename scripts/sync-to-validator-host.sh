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
#   REMOTE_PATH   — target directory on the validator host
#                   (default: /home/deploy/metal.freedom-yield.com/scripts/)
#                   The script refuses to run if REMOTE_PATH looks like a
#                   local Mac path or a placeholder; see the guard below.
#
# Behaviour:
#   - rsync only the scripts/ directory (not public/, not caddy/, not docker-compose/*).
#   - --inplace to preserve inode for any bind-mounted file (same rule as Caddyfile).
#   - --chmod=u=rwx,go=rx so the target files stay executable for `deploy` user.
#   - chown deploy:deploy on the remote after rsync so cron(running as deploy) can read them.
#   - every file rsync would transfer is scanned by scripts/publish-guard.sh
#     first, and nothing is transferred if any of them fails. This ships the
#     WORKING TREE, not a commit, so the guard's three git-facing layers never
#     see it; the machine it lands on is the one that generates the public
#     feed and runs these scripts from cron.
set -euo pipefail

# Resolve repository root from script location if REPO_BASE is not set.
REPO_BASE="${REPO_BASE:-$(cd "$(dirname "$0")/.." && pwd)}"

: "${VALIDATOR_HOST:?VALIDATOR_HOST env var is required (e.g. VALIDATOR_HOST=203.0.113.11 ./scripts/sync-to-validator-host.sh)}"
: "${VALIDATOR_HOST_KEY:=$HOME/.ssh/<your_validator_host_key>}"
: "${VALIDATOR_HOST_USER:=root}"
: "${REMOTE_PATH:=/home/deploy/metal.freedom-yield.com/scripts/}"

# Refuse if REMOTE_PATH looks like a Mac local path or a placeholder.
# This guards against the previous default chain that resolved REMOTE_PATH
# to "${REPO_BASE}/scripts/" — REPO_BASE always auto-resolves to the local
# repo root, so the old default tried to mkdir Mac paths on the remote.
case "${REMOTE_PATH}" in
  /path/to/your/repo/*|"${HOME}"/*|/Users/*)
    echo "ERROR: REMOTE_PATH looks like a placeholder or local Mac path: ${REMOTE_PATH}" >&2
    echo "       Expected a path on the validator host, e.g." >&2
    echo "       /home/deploy/metal.freedom-yield.com/scripts/" >&2
    exit 64
    ;;
esac

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

# Exclusions are declared ONCE and expanded into rsync arguments below. The
# pre-transfer scan reuses these very arguments, so the set of files scanned
# and the set of files transferred cannot drift apart — the scan does not
# reimplement rsync's pattern matching, it asks rsync.
SYNC_EXCLUDES=( '__pycache__/' '*.pyc' 'operator-local/' )
RSYNC_EXCLUDE_ARGS=()
for _ex in "${SYNC_EXCLUDES[@]}"; do
  RSYNC_EXCLUDE_ARGS+=( "--exclude=${_ex}" )
done
unset _ex

# ---- pre-transfer content scan (publish-guard, send-time layer) ----------
PUBLISH_SCAN_LIB="$(cd "$(dirname "$0")" && pwd)/lib/publish-scan.sh"
if [ ! -r "$PUBLISH_SCAN_LIB" ]; then
  echo "ERROR: publish-scan library not found at $PUBLISH_SCAN_LIB" >&2
  echo "       Refusing to sync: outbound content cannot be checked." >&2
  exit 1
fi
# shellcheck source=lib/publish-scan.sh
. "$PUBLISH_SCAN_LIB"
fyd_publish_scan_selftest || {
  echo "ERROR: refusing to sync — publish-guard could not be trusted (see above)." >&2
  exit 1
}

# Ask rsync itself which files it would send, with the same exclusions, by
# dry-running against an empty local directory. No network, no remote, and no
# second copy of the pattern rules to keep in step.
SCAN_LIST="$(mktemp -t fyd-sync-scanlist.XXXXXX)"
SCAN_EMPTY="$(mktemp -d -t fyd-sync-empty.XXXXXX)"
cleanup_scan() { rm -f "$SCAN_LIST"; rmdir "$SCAN_EMPTY" 2>/dev/null || true; return 0; }
# A signal handler MUST terminate the script — see the long note on the same
# construct in push-to-web-host.sh. One handler registered for EXIT+HUP+INT+TERM
# means bash runs it and then CARRIES ON: measured here, a SIGTERM was absorbed
# entirely and the script went on to run the remote rsync AND the remote chown,
# exiting 0. A cron timeout, `systemctl stop` or ^C could not stop a production
# transfer that was already under way.
trap cleanup_scan EXIT
trap 'cleanup_scan; exit 129' HUP
trap 'cleanup_scan; exit 130' INT
trap 'cleanup_scan; exit 143' TERM

rsync -rn --out-format='%n' "${RSYNC_EXCLUDE_ARGS[@]}" \
  "${LOCAL_PATH}" "${SCAN_EMPTY}/" > "$SCAN_LIST"

SCAN_COUNT=0
SCAN_BAD=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  f="${LOCAL_PATH}${rel}"
  [ -f "$f" ] || continue          # directories are listed too; skip them
  SCAN_COUNT=$((SCAN_COUNT + 1))
  if ! fyd_publish_scan_file "$f" "scripts/${rel}"; then
    SCAN_BAD=$((SCAN_BAD + 1))
  fi
done < "$SCAN_LIST"

if [ "$SCAN_BAD" -gt 0 ]; then
  echo "ERROR: ${SCAN_BAD} of ${SCAN_COUNT} file(s) failed publish-guard. NOTHING was synced." >&2
  exit 1
fi
echo "✓ publish-guard: ${SCAN_COUNT} file(s) scanned clean"

rsync -rtvz${DRY_RUN} --inplace \
  --chmod=u=rwx,go=rx \
  -e "ssh -i ${VALIDATOR_HOST_KEY}" \
  "${RSYNC_EXCLUDE_ARGS[@]}" \
  "${LOCAL_PATH}" \
  "${VALIDATOR_HOST_USER}@${VALIDATOR_HOST}:${REMOTE_PATH}"

if [ -z "$DRY_RUN" ]; then
  # cron runs as `deploy`, so files must be readable by deploy user
  ssh -i "${VALIDATOR_HOST_KEY}" "${VALIDATOR_HOST_USER}@${VALIDATOR_HOST}" \
    "chown -R deploy:deploy '${REMOTE_PATH}' && chmod 755 ${REMOTE_PATH}*.sh ${REMOTE_PATH}*.py 2>/dev/null || true"
  echo "✓ chown deploy:deploy applied"
fi
