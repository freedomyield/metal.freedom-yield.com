#!/usr/bin/env bash
# notify.sh — push a single ntfy.sh notification.
# Reads the topic from $NTFY_TOPIC_FILE (default /etc/freedom-yield/ntfy-topic).
# Topic is treated as a shared secret (anyone who knows it can publish/subscribe).
#
# Usage:
#   bash notify.sh <priority> <title> <message...>
#     priority = default | high | urgent  (ntfy.sh "Priority" header)
#   Env: NTFY_TAGS=<tag> — non-empty value overrides the priority-derived
#     Tags header (= leading emoji) for this one notification, e.g.
#     NTFY_TAGS=tada. Unset/empty keeps the priority-derived default.
# Examples:
#   bash notify.sh high "Validator renewal" "7 days left to re-AddValidator"
#   bash notify.sh urgent "metalgo down" "container status: exited"
#
# Exit codes:
#
#   Default mode (NOTIFY_STRICT_EXIT unset or != "1"):
#     0  success path, including non-2xx HTTP responses
#        (= byte-identical to historical behaviour; existing callers
#         observe no change)
#     1  topic file missing/empty, OR curl-level fatal failure
#        propagated by set -euo pipefail
#
#   Strict mode (NOTIFY_STRICT_EXIT=1):
#     0  HTTP 2xx
#     1  topic file missing/empty (= fatal, no retry)
#     2  curl transport failure (= timeout, DNS, connection refused, ...)
#     3  HTTP 4xx (excluding 429)
#     4  HTTP 429 (= rate-limited; retryable)
#     5  HTTP 5xx (= server error; retryable)
#
# Strict mode is opt-in. Existing callers (= check-anomalies.sh notify()
# wrapper, daily-status.sh, notify-evidence-health.sh, the K-3.5
# best-effort paths) do NOT set NOTIFY_STRICT_EXIT. The K-3 transition
# processing in check-anomalies.sh (= commit C4) sets NOTIFY_STRICT_EXIT=1
# to drive retry classification.
#
# See docs/MONITORING_NOTIFY_CALLERS.md (= C3a inventory) and
# docs/MONITORING_OPS.md §6 for the surrounding K-3 design.
set -euo pipefail

TOPIC_FILE="${NTFY_TOPIC_FILE:-/etc/freedom-yield/ntfy-topic}"
STRICT="${NOTIFY_STRICT_EXIT:-0}"
PRIO="${1:-default}"
TITLE="${2:-Freedom Yield ops}"
shift 2 || true
MSG="${*:-(no message)}"

if [ ! -r "$TOPIC_FILE" ]; then
  echo "notify.sh: cannot read topic from $TOPIC_FILE" >&2
  exit 1
fi
TOPIC=$(tr -d '[:space:]' < "$TOPIC_FILE")
if [ -z "$TOPIC" ]; then
  echo "notify.sh: topic is empty" >&2
  exit 1
fi

# Priority mapping
case "$PRIO" in
  urgent|high|default|low|min) ;;
  *) PRIO="default" ;;
esac

# No server-side quiet hours suppression — Android's built-in "Do Not
# Disturb" (おやすみ設定) handles sleep-time silencing at the device, so
# notifications still arrive into the ntfy history but don't ring/vibrate.
# This avoids losing alerts: if a T-7 heads-up fired at 02:00 JST the
# operator can still see it when DND lifts. Per-priority bypass (e.g. urgent)
# is configured app-side on Android, not here.

# Tags render as the leading emoji in the ntfy client.
# One tag = one emoji = clean, readable notification.
case "$PRIO" in
  urgent) TAGS="rotating_light" ;;
  high)   TAGS="warning" ;;
  *)      TAGS="information_source" ;;
esac
# Per-notification override: a non-empty NTFY_TAGS replaces the
# priority-derived default (e.g. a high-priority good-news notification
# can carry "tada" instead of "warning"). Unset or empty NTFY_TAGS falls
# back to the mapping above — existing callers observe no change.
if [ -n "${NTFY_TAGS:-}" ]; then
  TAGS="$NTFY_TAGS"
fi

# Append current uptime to every notification body so the operator
# always sees the validator's headline number in their pocket — no
# need to open the dashboard for a quick health glance. Reads from
# the same validator.json the public site serves; falls back to
# silence if the file is missing or unparseable.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR_JSON="$ROOT/public/api/validator.json"
if [ -r "$VALIDATOR_JSON" ]; then
  UPTIME=$(jq -r '.uptime.network // empty' "$VALIDATOR_JSON" 2>/dev/null)
  if [ -n "$UPTIME" ] && [ "$UPTIME" != "null" ]; then
    MSG="${MSG}

[Uptime] ${UPTIME}%"
  fi
fi

if [ "$STRICT" = "1" ]; then
  # Strict mode: capture both curl exit code and HTTP status. Bound the
  # request with --max-time so a hung ntfy.sh server doesn't stall the
  # cron tick (= the K-3 retry classifier treats curl failures as
  # retryable transport errors).
  #
  # `set +e` around the capture so the non-zero curl exit doesn't trip
  # the script-wide `set -e`. We classify the failure explicitly below.
  set +e
  HTTP_CODE=$(curl -sS -X POST "https://ntfy.sh/${TOPIC}" \
    -H "Title: ${TITLE}" \
    -H "Priority: ${PRIO}" \
    -H "Tags: ${TAGS}" \
    -d "$MSG" \
    -o /dev/null \
    --max-time 10 \
    -w "%{http_code}" 2>/dev/null)
  CURL_RC=$?
  set -e

  # Curl-level failure (= no HTTP exchange completed). Includes timeout,
  # DNS, connection refused, TLS handshake fail.
  if [ "$CURL_RC" -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
    echo "notify.sh: transport failure (curl_rc=${CURL_RC}, http_code=${HTTP_CODE:-empty})" >&2
    exit 2
  fi

  case "$HTTP_CODE" in
    2*) echo "notify.sh: ntfy OK ${HTTP_CODE}" >&2; exit 0 ;;
    429) echo "notify.sh: ntfy rate-limited ${HTTP_CODE}" >&2; exit 4 ;;
    4*) echo "notify.sh: ntfy 4xx ${HTTP_CODE}" >&2; exit 3 ;;
    5*) echo "notify.sh: ntfy 5xx ${HTTP_CODE}" >&2; exit 5 ;;
    *)
      # Any other status (= 1xx, 3xx, unknown) is treated as transport
      # ambiguous and retryable.
      echo "notify.sh: ntfy unexpected ${HTTP_CODE}" >&2
      exit 2
      ;;
  esac
fi

# Default mode (= byte-identical to historical behaviour). curl's own exit
# code propagates via set -euo pipefail; HTTP status is printed via -w but
# does NOT affect the script exit. Existing callers (daily-status,
# notify-evidence-health, K-3.5 best-effort paths) observe no change.
curl -sS -X POST "https://ntfy.sh/${TOPIC}" \
  -H "Title: ${TITLE}" \
  -H "Priority: ${PRIO}" \
  -H "Tags: ${TAGS}" \
  -d "$MSG" \
  -o /dev/null \
  -w "ntfy POST: %{http_code}\n"
