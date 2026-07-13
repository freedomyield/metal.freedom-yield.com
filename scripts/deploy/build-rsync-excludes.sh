#!/usr/bin/env bash
# build-rsync-excludes.sh <prefix>
# Emit rsync --exclude args (leading-anchored) for the dynamically-pushed
# feeds listed in deploy/feed-excludes.txt. Single source of truth so the
# validator-host and Xserver rsyncs cannot drift. Both live legs are
# public/-rooted (prefix "") as of the 2026-07-13 delivery-ownership
# inversion — the validator host no longer takes a whole-repo rsync at all
# (git delivers everything outside public/ instead; see
# scripts/advance-host-checkout.sh). <prefix> remains an argument for
# generality and is still exercised at "public/" by
# tests/deploy/test-rsync-delete-protection.sh for repo-root-shaped
# coverage of the emitter, not because any live leg uses that prefix.
set -euo pipefail
PREFIX="${1?usage: build-rsync-excludes.sh <prefix>}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIST="${FEED_EXCLUDES_FILE:-${REPO}/deploy/feed-excludes.txt}"
[ -r "${LIST}" ] || { echo "ERROR: feed list not readable: ${LIST}" >&2; exit 1; }
while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in ''|\#*) continue ;; esac
  printf -- '--exclude=/%s%s\n' "${PREFIX}" "${line}"
done < "${LIST}"
