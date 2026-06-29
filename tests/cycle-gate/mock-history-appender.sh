#!/usr/bin/env bash
# tests/cycle-gate/mock-history-appender.sh — stub for append-anchor-history.sh.
# post-anchor-event.sh invokes "${SCRIPT_DIR}/append-anchor-history.sh" by hard
# path. Tests intercept this by installing this script in a fake SCRIPT_DIR.
set -u
echo "[mock-history-appender] would append history line for $*" >&2
exit "${MOCK_HISTORY_APPENDER_EXIT:-0}"
