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
#   WATCH_STATE_DIR   state dir (default /var/lib/freedom-yield). Resolved by
#                     scripts/lib/side-effects.sh (fyd_state_dir watch), which
#                     also honours the canonical FY_STATE_DIR at higher
#                     precedence. The legacy spelling is unchanged.
#   EXPLORER_API      explorer validators endpoint
#   EXPLORER_MIN_VALIDATORS  sanity floor for the response size (default 50)
#   WATCH_NOTIFY      notifier (default <repo>/scripts/notify.sh). Resolved by
#                     scripts/lib/side-effects.sh, not here.
#   NOTIFY_RETRY_SLEEP  seconds before the single in-run notify retry (default 5; tests override to 0)
#   FY_LIVE=1         REQUIRED before any notify or baseline write actually
#                     happens. Anything else is a loud dry no-op printing one
#                     "DRY: would …" line per suppressed effect
#                     (scripts/lib/side-effects.sh, C3 rollout 2026-08-06).
#                     The cron env header carries it; tests deliberately do
#                     not. NOTE this is a test/prod boundary and is NOT the
#                     same knob as --dry-run, which is an operator-facing
#                     "detect and report, don't notify, don't advance the
#                     baseline" flag and stays exactly as it was.
#
# Exit code 3: scripts/lib/side-effects.sh missing (structural).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FYD_LIB="${ROOT}/scripts/lib/side-effects.sh"
if [ ! -r "$FYD_LIB" ]; then
  echo "check-watch-validators: FATAL: side-effects library not readable at $FYD_LIB" >&2
  exit 3
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

WATCH_LIST_FILE="${WATCH_LIST_FILE:-/etc/freedom-yield/watch-list.json}"
STATE_DIR="$(fyd_state_dir watch)" || exit $?
PREV_FILE="${STATE_DIR}/watch-prev-state.json"
EXPLORER_API="${EXPLORER_API:-https://explorer.metalblockchain.org/api/v1/validators}"
EXPLORER_MIN="${EXPLORER_MIN_VALIDATORS:-50}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# --- delivery-confirmed notify (same pattern as check-anomalies.sh's
# notify_or_keep(): strict mode + one in-run retry on the retryable classes,
# state only advances on confirmed delivery). See R5 / MONITORING_NOTIFY_CALLERS.md.
#
# stdout is still discarded; stderr is NOT (it used to be). A suppressed dry
# send announces itself on stderr, and swallowing that would recreate exactly
# the silent-no-op failure the C3 rollout exists to prevent.
#
# The old "notifier missing or not executable → rc 100" branch is gone: the
# library validates the delegate itself and returns 64. Both codes are
# non-retryable under retryable_notify_rc(), so the control flow is unchanged.
attempt_notify() {
  local prio="$1" title="$2" body="$3" rc=0
  fyd_notify --strict "$prio" "$title" "$body" >/dev/null || rc=$?
  return "$rc"
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

fyd_live_run "create the watch state dir ${STATE_DIR}" mkdir -p "$STATE_DIR"

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
#
# The write itself is gated on FY_LIVE by fyd_live_write, in lock step with
# the notify above: under a dry run the send is suppressed AND the baseline
# stays put, so the two can never disagree (scripts/lib/side-effects.sh
# CONTRACT — "a caller that turns rc 0 into a state transition must gate that
# state write with the same FY_LIVE").
if [ "$DRY" = "0" ] && [ "$NOTIFY_CONFIRMED" = "1" ]; then
  printf '%s\n' "$CURRENT_JSON" | fyd_live_write "the watch baseline snapshot" "$PREV_FILE"
fi
