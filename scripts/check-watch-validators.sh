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
#
# NOTIFICATION DESIGN (2026-07-07 rework, after the 01:00 JST incident):
# everything this monitor observes is slow-moving market intelligence about
# THIRD-PARTY validators — never an operational emergency for our node. So:
#
#   - All changes found in one run are batched into a SINGLE notification
#     ("Watch validators: N change(s)"), never one push per validator.
#   - Priority is `low` (name_appeared / first_delegation — the signals the
#     watch exists for) or `min` (departed / rejoined — passive period
#     timelines). Both are silent on Android: readable in the morning,
#     never a night-time ring. `high`/`default` are reserved for our own
#     validator's health alerts, per the no-false-urgency policy.
#
# EXPLORER SANITY GATE: absence from the explorer response is only trusted
# as a real departure when the response itself is credible — an HTTP/curl
# failure, a non-array body, or a suspiciously small validator set
# (< EXPLORER_MIN_VALIDATORS, default 50 — the live Metal validator set
# numbers in the low hundreds, so a sub-50 response is an API fault, not a
# real mass departure) skips the run without touching state or notifying.
# Without this gate a
# single explorer outage fabricates a mass "departed" for every watched
# NodeID and then re-fires them all as "rejoined" when the API recovers.
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
# DELIVERY-CONFIRMED STATE ADVANCE (R5, 2026-07-08): the baseline snapshot
# (PREV_FILE) is only overwritten when there were zero changes (pure
# observation) OR the batched notify was CONFIRMED delivered (strict mode +
# one in-run retry, mirroring check-anomalies.sh's notify_or_keep()). If
# notify cannot confirm delivery, the baseline is left at its prior value so
# the same delta is recomputed and re-notified on the next run instead of a
# transient ntfy outage silently and permanently dropping the change.
#
# Cron: JST-daytime only — 0 0,4,8,12 * * * UTC = 09/13/17/21 JST
# (/etc/cron.d/metal-watch-validators, installed by
# scripts/install-watch-cron.sh). The old 0 */4 schedule landed two of six
# daily runs at 01:00/05:00 JST; intelligence this slow never justifies a
# night-time delivery. The watch list is small so external API impact is
# minimal — once per check we hit the explorer API.
#
# Manual run: bash scripts/check-watch-validators.sh [--dry-run]
#
# Env overrides (test-time + ops):
#   WATCH_LIST_FILE   private NodeID list (default /etc/freedom-yield/watch-list.json)
#   WATCH_STATE_DIR   state dir (default /var/lib/freedom-yield)
#   EXPLORER_API      explorer validators endpoint
#   EXPLORER_MIN_VALIDATORS  sanity floor for the response size (default 50)
#   WATCH_NOTIFY      notifier (default <repo>/scripts/notify.sh)
#   NOTIFY_RETRY_SLEEP  seconds before the single in-run notify retry (default 5; tests override to 0)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH_LIST_FILE="${WATCH_LIST_FILE:-/etc/freedom-yield/watch-list.json}"
STATE_DIR="${WATCH_STATE_DIR:-/var/lib/freedom-yield}"
PREV_FILE="${STATE_DIR}/watch-prev-state.json"
EXPLORER_API="${EXPLORER_API:-https://explorer.metalblockchain.org/api/v1/validators}"
EXPLORER_MIN="${EXPLORER_MIN_VALIDATORS:-50}"
NOTIFY="${WATCH_NOTIFY:-${ROOT}/scripts/notify.sh}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# --- delivery-confirmed notify (same pattern as check-anomalies.sh's
# notify_or_keep(): strict mode + one in-run retry on the retryable classes,
# state only advances on confirmed delivery). See R5 / MONITORING_NOTIFY_CALLERS.md.
attempt_notify() {
  local prio="$1" title="$2" body="$3"
  if [ ! -x "$NOTIFY" ]; then
    echo "check-watch-validators: notify script missing or not executable: $NOTIFY" >&2
    return 100
  fi
  NOTIFY_STRICT_EXIT=1 bash "$NOTIFY" "$prio" "$title" "$body" >/dev/null 2>&1
  return $?
}
retryable_notify_rc() {
  case "$1" in
    2|4|5) return 0 ;;   # transport / 429 / 5xx
    *)     return 1 ;;
  esac
}
notify_or_keep() {
  local prio="$1" title="$2" body="$3" rc
  attempt_notify "$prio" "$title" "$body"; rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if retryable_notify_rc "$rc"; then
    sleep "${NOTIFY_RETRY_SLEEP:-5}"
    attempt_notify "$prio" "$title" "$body"; rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
  fi
  echo "check-watch-validators: notify permanent fail (rc=$rc, prio=$prio, title=\"$title\")" >&2
  return "$rc"
}

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
# Sanity gate (see header): only a credible response may drive state deltas.
# Anything else skips the run — exit 0 keeps the cron green, the log line
# carries the reason, and the untouched baseline means a recovered API
# resumes exactly where it left off (no fabricated departed/rejoined pairs).
if ! EXP_RESP=$(curl -sS --max-time 20 -H 'Accept: application/json' "$EXPLORER_API"); then
  echo "explorer fetch failed — skipping run (state untouched)"
  exit 0
fi
EXP_TYPE=$(printf '%s' "$EXP_RESP" | jq -r 'type' 2>/dev/null || echo invalid)
if [ "$EXP_TYPE" != "array" ]; then
  echo "explorer response is not an array (type=$EXP_TYPE) — skipping run (state untouched)"
  exit 0
fi
EXP_LEN=$(printf '%s' "$EXP_RESP" | jq 'length')
if [ "$EXP_LEN" -lt "$EXPLORER_MIN" ]; then
  echo "explorer returned only $EXP_LEN validators (< floor $EXPLORER_MIN) — treating as API fault, skipping run (state untouched)"
  exit 0
fi

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
            (if (.cur.delegators_count // 0) > 0 and (.prev.delegators_count // 0) == 0
                and (.prev.active // false) == true then
               # only within a continuous presence — a rejoin already reports
               # its delegator count in the rejoined line
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
NOTIFY_CONFIRMED=1
if [ "$NUM_CHANGES" = "0" ]; then
  echo "no changes on $(echo "$WATCH_IDS" | wc -l | tr -d ' ') watched validators"
else
  echo "$NUM_CHANGES change(s) detected:"
  echo "$CHANGES" | jq -r '.[] | "  \(.type): \(.nid) → \(.value)"'
  if [ "$DRY" = "1" ]; then
    echo "(dry run, not notifying)"
  else
    # One batched notification per run (see header). Priority = max class
    # present: low if any name/delegation signal, min for pure timeline moves.
    SUMMARY=$(echo "$CHANGES" | jq -r '.[] |
      if .type == "name_appeared" then "named: \(.nid) → \(.value)"
      elif .type == "first_delegation" then "first delegation: \(.nid) (\(.value) delegator(s))"
      elif .type == "departed" then "left active set: \(.nid)"
      else "rejoined active set: \(.nid) (delegators: \(.value))"
      end')
    BATCH_PRIO=$(echo "$CHANGES" | jq -r 'map(.type) |
      if any(. == "name_appeared" or . == "first_delegation") then "low" else "min" end')
    if notify_or_keep "$BATCH_PRIO" "Watch validators: ${NUM_CHANGES} change(s)" "$SUMMARY"; then
      NOTIFY_CONFIRMED=1
    else
      NOTIFY_CONFIRMED=0
      echo "notify not confirmed — baseline state NOT advanced so these ${NUM_CHANGES} change(s) are re-detected and re-notified next run" >&2
    fi
  fi
fi

# Persist current state for next run — but NOT in dry-run, and NOT when this
# was a real run with change(s) to notify whose delivery could not be
# confirmed (NOTIFY_CONFIRMED=0). Either would overwrite the baseline without
# having notified and silently swallow the pending alert(s) — the next run
# would see "no change" instead of retrying. A run with zero changes always
# persists (pure observation, nothing to confirm).
if [ "$DRY" = "0" ] && [ "$NOTIFY_CONFIRMED" = "1" ]; then
  echo "$CURRENT_JSON" > "$PREV_FILE"
fi
