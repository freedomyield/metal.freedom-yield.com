#!/usr/bin/env bash
# tests/cycle-gate/mock-pusher.sh — stub for push-to-web-host.sh used by
# post-anchor-event.sh tests.
#
# Behavior controlled by env:
#   MOCK_PUSHER_EXIT      desired exit code (default 0)
#
# Always succeeds silently by default; tests can force failure to verify the
# push-failure exit path of post-anchor-event.sh.
set -u
echo "[mock-pusher] push of $* (no-op)" >&2
exit "${MOCK_PUSHER_EXIT:-0}"
