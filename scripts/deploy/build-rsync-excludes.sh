#!/usr/bin/env bash
# build-rsync-excludes.sh <prefix>
# Emit rsync --exclude args (leading-anchored) for the dynamically-pushed
# feeds listed in deploy/feed-excludes.txt. Single source of truth so the
# validator-host (whole-repo, prefix "public/") and Xserver (public/-rooted,
# prefix "") rsyncs cannot drift.
set -euo pipefail
PREFIX="${1?usage: build-rsync-excludes.sh <prefix>}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIST="${FEED_EXCLUDES_FILE:-${REPO}/deploy/feed-excludes.txt}"
[ -r "${LIST}" ] || { echo "ERROR: feed list not readable: ${LIST}" >&2; exit 1; }
while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in ''|\#*) continue ;; esac
  printf -- '--exclude=/%s%s\n' "${PREFIX}" "${line}"
done < "${LIST}"
