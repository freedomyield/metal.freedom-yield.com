#!/usr/bin/env bash
# check-anchor-publish-health.sh — verify /api/anchor-source.json is served,
# with an auto-recover push if it silently vanishes.
#
# Motivation:
#   The public URL is the receipt v2 evaluator's step 2. If it 404s, the
#   verification chain breaks even though the tx is fine on-chain. GitHub
#   Actions rsync used to delete the runtime file (fixed in deploy.yml
#   commit b428f19 by adding an exclude), but a monitor gives us a safety
#   net for any future publish-path regressions and produces a durable log
#   the operator can consult if evaluators report broken links.
#
# Behavior:
#   1. curl the public URL. On 200, exit 0 quietly (or with a heartbeat
#      when --verbose is set).
#   2. On non-200, compare with the Hetzner-local file:
#      - if the local file exists and is non-empty, invoke push-to-web-host.sh
#        (retry-with-backoff already built in) and re-check.
#      - if the local file is missing, log an ERROR and exit 2 — this
#        requires a fresh gen-anchor-source.sh run and is not something
#        this monitor should perform (the timing must be operator-authorized).
#   3. Log every non-200 event to /var/log/anchor-publish-health.log for
#      later audit even when auto-recover succeeds.
#
# Usage:
#   bash scripts/check-anchor-publish-health.sh [--verbose]
#
# Cron target (added by /etc/cron.d/metal-anchor-publish-health):
#   */15 * * * * deploy bash /home/.../scripts/check-anchor-publish-health.sh

set -uo pipefail

VERBOSE=0
for arg in "$@"; do
	case "$arg" in
		--verbose|-v) VERBOSE=1 ;;
	esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="${ANCHOR_SOURCE_URL:-https://metal.freedom-yield.com/api/anchor-source.json}"
LOCAL_FILE="${ROOT}/public/api/anchor-source.json"
LOG="${ANCHOR_PUBLISH_HEALTH_LOG:-/var/log/anchor-publish-health.log}"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

log() {
	# stderr for cron, appended to log file if writable
	printf '%s %s\n' "$NOW_ISO" "$*" >&2
	if [ -w "$(dirname "$LOG")" ] || [ -w "$LOG" ] 2>/dev/null; then
		printf '%s %s\n' "$NOW_ISO" "$*" >> "$LOG" 2>/dev/null || true
	fi
}

HTTP="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "$URL" 2>/dev/null || echo "000")"

if [ "$HTTP" = "200" ]; then
	[ "$VERBOSE" -eq 1 ] && log "OK $URL $HTTP"
	exit 0
fi

log "WARN non-200 $URL $HTTP"

if [ ! -s "$LOCAL_FILE" ]; then
	log "ERROR local file missing or empty: $LOCAL_FILE — cannot auto-recover; run gen-anchor-source.sh manually with operator authorization"
	exit 2
fi

# Auto-recover: push from Hetzner local. Do NOT regenerate — the operator
# is the source of truth for when anchor-source.json changes.
log "INFO auto-recover: pushing $LOCAL_FILE via push-to-web-host.sh"
if bash "${ROOT}/scripts/push-to-web-host.sh" anchor-source.json 2>&1 | sed "s/^/    push: /" >&2; then
	# re-check
	sleep 3
	HTTP2="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "$URL" 2>/dev/null || echo "000")"
	if [ "$HTTP2" = "200" ]; then
		log "OK auto-recover succeeded: $URL now $HTTP2"
		exit 0
	fi
	log "ERROR auto-recover completed push but URL still $HTTP2"
	exit 3
fi

log "ERROR push-to-web-host.sh failed"
exit 4
