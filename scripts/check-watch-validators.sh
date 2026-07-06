#!/usr/bin/env bash
# check-watch-validators.sh — monitor a private list of anonymous-but-
# interesting validators for state changes and fire an ntfy notification
# when something moves. Specifically:
#
#   1. A `name` field appears (operator has registered identity with
#      Metallicus / explorer) — likely institutional reveal
#   2. delegators count goes from 0 → >0 (someone delegated to them)
#   3. Validator disappears from the active set (period ended)
#   4. Validator returns to the active set after a previous departure
#      (operator made an explicit decision to re-engage — informative
#      signal worth surfacing at `high` priority since it indicates
#      active intent rather than a passive timeline like an expiry)
#
# Watch-list source (2026-07-06 revision): the list lives in a HOST-LOCAL
# private config, ${WATCH_LIST_FILE:-/etc/freedom-yield/watch-list.json}
# (a JSON array of NodeID strings, installed via
# scripts/install-watch-list.sh). It deliberately does NOT come from the
# public validator-directory.json anymore: naming third-party validators
# we monitor in a public feed was retired with the 2026-06 sanitize, and
# the earlier coupling silently disabled this monitor for 18 days when the
# public directory lost its `type: "watch"` entries. A missing or empty
# list is a graceful no-op (exit 0) so the cron stays green until the
# operator installs the list.
#
# Architecture mirrors the existing alert pipeline: fetch live state,
# compare against last-known state stored in /var/lib/freedom-yield/,
# send notify.sh on change.
#
# Cron: run every 4 hours (/etc/cron.d/metal-watch-validators). The watch
# list is small so external API impact is minimal — once per check we hit
# the explorer API.
#
# Manual run: bash scripts/check-watch-validators.sh [--dry-run]
#
# Env overrides (test-time + ops):
#   WATCH_LIST_FILE   private NodeID list (default /etc/freedom-yield/watch-list.json)
#   WATCH_STATE_DIR   state dir (default /var/lib/freedom-yield)
#   EXPLORER_API      explorer validators endpoint
#   WATCH_NOTIFY      notifier (default <repo>/scripts/notify.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH_LIST_FILE="${WATCH_LIST_FILE:-/etc/freedom-yield/watch-list.json}"
STATE_DIR="${WATCH_STATE_DIR:-/var/lib/freedom-yield}"
PREV_FILE="${STATE_DIR}/watch-prev-state.json"
EXPLORER_API="${EXPLORER_API:-https://explorer.metalblockchain.org/api/v1/validators}"
NOTIFY="${WATCH_NOTIFY:-${ROOT}/scripts/notify.sh}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# Pull the private list of NodeIDs to watch. Missing/empty/malformed list
# is a graceful no-op so the cron stays green pre-install.
if [ ! -r "$WATCH_LIST_FILE" ]; then
  echo "no watch list at $WATCH_LIST_FILE — nothing to do"
  exit 0
fi
WATCH_IDS=$(jq -r 'if type == "array" then .[] else empty end' "$WATCH_LIST_FILE" 2>/dev/null | grep '^NodeID-' || true)
if [ -z "$WATCH_IDS" ]; then
  echo "watch list is empty — nothing to do"
  exit 0
fi

mkdir -p "$STATE_DIR"

# Fetch current explorer snapshot once and cache for the loop.
EXP_RESP=$(curl -sS --max-time 20 -H 'Accept: application/json' "$EXPLORER_API" || echo '[]')

# Build current state: { NodeID → { name, delegators_count, active } } for the watched IDs.
CURRENT_JSON=$(echo "$EXP_RESP" | jq --arg ids "$WATCH_IDS" '
  ($ids | split("\n")) as $watch |
  (if type == "array" then . else [] end) as $vs |
  [
    $watch[] | select(length > 0) |
    . as $nid |
    ($vs | map(select(.nodeId == $nid)) | first) as $v |
    {
      key: $nid,
      value: (if $v == null then { active: false } else {
        active: true,
        name: ($v.name // null),
        delegators_count: (($v.delegators // []) | length)
      } end)
    }
  ] | from_entries
')

# Compare with previous state.
if [ -f "$PREV_FILE" ]; then
  PREV_JSON=$(cat "$PREV_FILE")
else
  PREV_JSON='{}'
fi

# For each watched NodeID, detect deltas worth notifying.
CHANGES=$(jq -n --argjson cur "$CURRENT_JSON" --argjson prev "$PREV_JSON" '
  ($cur | keys) as $ids |
  [
    $ids[] | . as $nid |
    {nid: $nid, cur: $cur[$nid], prev: ($prev[$nid] // null)}
    | . as $row
    | (
        if .prev == null then []   # first run — silent baseline
        else
          (
            (if (.cur.name // null) != (.prev.name // null) and (.cur.name // null) != null then
               [{nid: .nid, type: "name_appeared", value: .cur.name}]
             else [] end)
            +
            (if (.cur.delegators_count // 0) > 0 and (.prev.delegators_count // 0) == 0 then
               [{nid: .nid, type: "first_delegation", value: .cur.delegators_count}]
             else [] end)
            +
            (if (.cur.active // false) == false and (.prev.active // false) == true then
               [{nid: .nid, type: "departed", value: null}]
             else [] end)
            +
            (if (.cur.active // false) == true and (.prev.active // false) == false then
               [{nid: .nid, type: "rejoined", value: ((.cur.delegators_count // 0) | tostring)}]
             else [] end)
          )
        end
      )[]
  ]
')

NUM_CHANGES=$(echo "$CHANGES" | jq 'length')
if [ "$NUM_CHANGES" = "0" ]; then
  echo "no changes on $(echo "$WATCH_IDS" | wc -l | tr -d ' ') watched validators"
else
  echo "$NUM_CHANGES change(s) detected:"
  echo "$CHANGES" | jq -r '.[] | "  \(.type): \(.nid) → \(.value)"'
  if [ "$DRY" = "1" ]; then
    echo "(dry run, not notifying)"
  else
    echo "$CHANGES" | jq -r '.[] | "\(.type)|\(.nid)|\(.value)"' | while IFS='|' read -r kind nid val; do
      case "$kind" in
        name_appeared)
          bash "$NOTIFY" high "Watch validator named" "$nid → $val (was anonymous)" || true
          ;;
        first_delegation)
          bash "$NOTIFY" high "Watch validator receiving delegations" "$nid now has $val delegator(s) (was 0)" || true
          ;;
        departed)
          bash "$NOTIFY" default "Watch validator left active set" "$nid is no longer in the explorer" || true
          ;;
        rejoined)
          bash "$NOTIFY" high "Watch validator rejoined active set" "$nid is back in the explorer (delegators: $val)" || true
          ;;
      esac
    done
  fi
fi

# Persist current state for next run — but NOT in dry-run: overwriting the
# baseline without having notified would swallow the pending alerts (the next
# real run would see "no change"). Dry-run must be side-effect-free.
if [ "$DRY" = "0" ]; then
  echo "$CURRENT_JSON" > "$PREV_FILE"
fi
