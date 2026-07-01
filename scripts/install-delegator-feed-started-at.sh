#!/usr/bin/env bash
# install-delegator-feed-started-at.sh — one-line installer for the
# delegator lifecycle observation window boundary config.
#
# Purpose: gen-anchor-source.sh reads /etc/freedom-yield/delegator-feed-started-at
# to populate observations_branch.delegator_lifecycle_observation_window_started_at.
# When absent, gen-anchor-source.sh emits a WARN and omits the field, which
# leaves evaluators with undefined observation-window semantics = partial-
# observation risk. This installer sets the boundary to the T-B2 commit
# activation time (2026-07-01T06:02:00Z per commit 9911171) so cycle 2's
# empty delegator_lifecycle_events array is honestly bounded.
#
# Usage (operator, once, on Hetzner):
#   sudo bash scripts/install-delegator-feed-started-at.sh
# Usage (with custom timestamp):
#   sudo FEED_STARTED_AT="2026-07-01T06:02:00Z" bash scripts/install-delegator-feed-started-at.sh
#
# Idempotent: safe to re-run; leaves existing content unchanged when timestamps match.

set -euo pipefail

FEED_STARTED_AT="${FEED_STARTED_AT:-2026-07-01T06:02:00Z}"
CFG_DIR="${FY_CONFIG_DIR:-/etc/freedom-yield}"
CFG_FILE="${CFG_DIR}/delegator-feed-started-at"

if ! printf '%s' "$FEED_STARTED_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
	echo "ERROR: FEED_STARTED_AT must be ISO 8601 UTC (YYYY-MM-DDTHH:MM:SSZ), got: '$FEED_STARTED_AT'" >&2
	exit 2
fi

if [ ! -d "$CFG_DIR" ]; then
	echo "creating $CFG_DIR"
	mkdir -p "$CFG_DIR"
	chmod 755 "$CFG_DIR"
fi

if [ -f "$CFG_FILE" ]; then
	EXISTING="$(head -1 "$CFG_FILE" | tr -d '[:space:]')"
	if [ "$EXISTING" = "$FEED_STARTED_AT" ]; then
		echo "OK: $CFG_FILE already set to $FEED_STARTED_AT (no change)"
		exit 0
	fi
	echo "WARN: $CFG_FILE currently contains '$EXISTING'; overwriting with '$FEED_STARTED_AT'"
fi

printf '%s\n' "$FEED_STARTED_AT" > "$CFG_FILE"
chmod 644 "$CFG_FILE"
echo "OK: wrote $CFG_FILE = $FEED_STARTED_AT"
echo
echo "Next: gen-anchor-source.sh will now include"
echo "  observations_branch.delegator_lifecycle_observation_window_started_at = \"$FEED_STARTED_AT\""
echo "in the generated anchor-source.json output."
