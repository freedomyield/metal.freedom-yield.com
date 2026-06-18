#!/usr/bin/env bash
# notify.sh — push a single ntfy.sh notification.
# Reads the topic from $NTFY_TOPIC_FILE (default /etc/<your-namespace>/ntfy-topic).
# Topic is treated as a shared secret (anyone who knows it can publish/subscribe).
#
# Usage:
#   bash notify.sh <priority> <title> <message...>
#     priority = default | high | urgent  (ntfy.sh "Priority" header)
# Examples:
#   bash notify.sh high "Validator renewal" "7 days left to re-AddValidator"
#   bash notify.sh urgent "metalgo down" "container status: exited"
set -euo pipefail

TOPIC_FILE="${NTFY_TOPIC_FILE:-/etc/<your-namespace>/ntfy-topic}"
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

curl -sS -X POST "https://ntfy.sh/${TOPIC}" \
  -H "Title: ${TITLE}" \
  -H "Priority: ${PRIO}" \
  -H "Tags: ${TAGS}" \
  -d "$MSG" \
  -o /dev/null \
  -w "ntfy POST: %{http_code}\n"
