#!/usr/bin/env bash
# install-host-log-dir.sh — ensure the repo-local logs/ directory exists on the
# validator host with the ownership/permissions cron needs.
#
# Motivation: the project crons redirect their output with `>> .../logs/*.log`.
# If the logs/ directory is absent (e.g. right after a fresh clone or a
# `git reset --hard origin/main` on the host), the shell cannot open the
# redirect target and bash aborts BEFORE running the cron's actual script —
# a silent, whole-job failure. The repo now tracks logs/ via logs/.gitkeep so
# a checkout always restores the directory; this installer is the belt-and-
# suspenders companion that also fixes ownership (cron runs as `deploy`) in
# case the directory was recreated by a different user or with wrong perms.
#
# This is a one-shot / idempotent installer (safe to re-run, no unit test
# needed): re-running only re-asserts mkdir/chown/chmod and reports state.
#
# Usage (validator host, as root):
#   sudo bash scripts/install-host-log-dir.sh            # apply
#   sudo REMOTE_PATH=/home/deploy/metal.freedom-yield.com \
#       bash scripts/install-host-log-dir.sh             # explicit repo base
#
# Env:
#   REMOTE_PATH  — repo root on the validator host. Default: resolved from this
#                  script's own location ($(dirname)/..). The script REFUSES to
#                  run if the resolved path looks like a placeholder or a local
#                  Mac path, so it cannot be run against the developer machine
#                  by mistake (this installer only makes sense on the host).
#   LOG_OWNER    — owner:group applied to logs/ (default: deploy:deploy).
#
# Exit codes:
#   0  success
#  64  REPO_BASE looks like a placeholder or local Mac path (refused)
set -euo pipefail

# Resolve the repo root: explicit REMOTE_PATH wins, else from script location.
REPO_BASE="${REMOTE_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
LOG_OWNER="${LOG_OWNER:-deploy:deploy}"

# Refuse if REPO_BASE looks like a Mac local path or a placeholder. This
# installer is host-only: on the Mac the script-location fallback resolves to
# a /Users/... path, which is exactly what we must not operate on.
case "${REPO_BASE}" in
  /path/to/your/repo/*|"${HOME}"/*|/Users/*)
    echo "ERROR: REPO_BASE looks like a placeholder or local Mac path: ${REPO_BASE}" >&2
    echo "       This installer only runs on the validator host. Set REMOTE_PATH" >&2
    echo "       to the host repo root, e.g." >&2
    echo "       REMOTE_PATH=/home/deploy/metal.freedom-yield.com" >&2
    exit 64
    ;;
esac

LOG_DIR="${REPO_BASE}/logs"

mkdir -p "${LOG_DIR}"
chown "${LOG_OWNER}" "${LOG_DIR}"
chmod 755 "${LOG_DIR}"

echo "✓ logs directory ready: ${LOG_DIR}"
echo "  owner: $(ls -ld "${LOG_DIR}" | awk '{print $3":"$4}')  mode: $(ls -ld "${LOG_DIR}" | awk '{print $1}')"
