#!/usr/bin/env bash
# tests/cycle-gate/mock-postanchor.sh — stub for post-anchor-event.sh used by
# resume-after-cycle-start.sh tests (= POSTANCHOR env override target).
#
# Behavior controlled by env:
#   MOCK_POSTANCHOR_EXIT     desired exit code (default 0)
#   MOCK_POSTANCHOR_LOGFILE  if set, append "called with: $*" to this file
#                            (= lets the harness assert the script was invoked
#                            with the expected --event-type / --cycle-n args)
#
# Always emits a brief identification line on stderr.
set -u
echo "[mock-postanchor] called: $*" >&2
if [ -n "${MOCK_POSTANCHOR_LOGFILE:-}" ]; then
	printf 'called with: %s\n' "$*" >> "${MOCK_POSTANCHOR_LOGFILE}"
fi
exit "${MOCK_POSTANCHOR_EXIT:-0}"
