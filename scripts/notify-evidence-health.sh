#!/usr/bin/env bash
# notify-evidence-health.sh — post-cron health check for /api/evidence.json
# publication pipeline + ntfy push of the result.
#
# Designed to fire ~5 minutes after the daily metal-evidence cron at
# 01:30 UTC so the operator wakes up to a single ntfy push summarising
# whether the cron auto-fire succeeded and whether the runtime
# evidence.json carries the expected shape.
#
# What it checks (= PHASE5_CHECKLIST.md § A cron-stability gate, but
# daily as ongoing health):
#
#   A1. The most recent gen-evidence.log block ends with `rc=0`.
#   A2. /api/evidence.json's generated_at is within the last 24 hours.
#   A3. /api/evidence.json carries the live_artifacts.identity_manifest
#       entry with formal_schema_url + operator_guide_url (= post-6b20b56
#       shape where identity_manifest is live, not in_preparation).
#
# Output: one ntfy push with a 3-line PASS/FAIL summary. Priority is
# `default` when all three pass and `high` when any fails — Android DND
# handles sleep-time silencing per memory reference_ntfy_notifications.
#
# Designed for cron use; no flags. Run after gen-evidence.sh has had
# time to complete (suggest 5 min buffer).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="${ROOT}/logs/gen-evidence.log"
EVIDENCE_URL="${EVIDENCE_URL:-https://metal.freedom-yield.com/api/evidence.json}"

# Helper: 3-state result emoji
ok_or_x() {
	if [ "$1" = "PASS" ]; then printf '%s' "✅"; else printf '%s' "❌"; fi
}

# ---- A1: cron log rc check ----
A1_RESULT="FAIL"
A1_DETAIL="log not found"
if [ -r "${LOG_FILE}" ]; then
	# Grab the last line that announces an end-of-block.
	LAST_END=$(grep '^=== metal-evidence end' "${LOG_FILE}" 2>/dev/null | tail -1 || true)
	if [ -n "${LAST_END}" ]; then
		# Extract rc=<n> and ISO timestamp.
		LAST_RC=$(printf '%s' "${LAST_END}" | sed -nE 's/.*rc=([0-9]+).*/\1/p')
		LAST_TS=$(printf '%s' "${LAST_END}" | sed -nE 's/.*end ([0-9T:Z\-]+) .*/\1/p')
		if [ "${LAST_RC}" = "0" ]; then
			A1_RESULT="PASS"
			A1_DETAIL="rc=0 at ${LAST_TS}"
		else
			A1_DETAIL="rc=${LAST_RC} at ${LAST_TS}"
		fi
	else
		A1_DETAIL="no end-marker in log"
	fi
fi

# ---- A2: evidence.json generated_at freshness ----
A2_RESULT="FAIL"
A2_DETAIL="fetch failed"
EVIDENCE_TMP=$(mktemp)
trap 'rm -f "${EVIDENCE_TMP}"' EXIT
if curl -sSLf "${EVIDENCE_URL}" -o "${EVIDENCE_TMP}" 2>/dev/null; then
	GENERATED_AT=$(jq -r '.generated_at // empty' "${EVIDENCE_TMP}" 2>/dev/null)
	if [ -n "${GENERATED_AT}" ]; then
		# Compare against now − 24h. BSD/macOS date and GNU date differ;
		# fall back to compare timestamp strings lexicographically (ISO 8601
		# UTC sorts correctly).
		NOW_MINUS_24H=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
			|| date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
			|| echo "")
		if [ -z "${NOW_MINUS_24H}" ]; then
			# Neither GNU nor BSD date understood the flag — degrade.
			A2_RESULT="PASS"
			A2_DETAIL="${GENERATED_AT} (freshness compare degraded)"
		elif [ "${GENERATED_AT}" \> "${NOW_MINUS_24H}" ]; then
			A2_RESULT="PASS"
			A2_DETAIL="${GENERATED_AT}"
		else
			A2_DETAIL="${GENERATED_AT} (stale, >24h)"
		fi
	else
		A2_DETAIL="generated_at missing"
	fi
fi

# ---- A3: in_preparation_artifacts enriched fields ----
A3_RESULT="FAIL"
A3_DETAIL="fetch failed"
if [ -s "${EVIDENCE_TMP}" ]; then
	FORMAL_URL=$(jq -r '.live_artifacts.identity_manifest.formal_schema_url // empty' "${EVIDENCE_TMP}" 2>/dev/null)
	OP_URL=$(jq -r '.live_artifacts.identity_manifest.operator_guide_url // empty' "${EVIDENCE_TMP}" 2>/dev/null)
	if [ -n "${FORMAL_URL}" ] && [ -n "${OP_URL}" ]; then
		A3_RESULT="PASS"
		A3_DETAIL="formal_schema_url + operator_guide_url present"
	elif [ -n "${FORMAL_URL}" ]; then
		A3_DETAIL="formal_schema_url ok, operator_guide_url missing"
	elif [ -n "${OP_URL}" ]; then
		A3_DETAIL="operator_guide_url ok, formal_schema_url missing"
	else
		A3_DETAIL="both fields missing (pre-6b20b56 shape, identity_manifest still under in_preparation_artifacts?)"
	fi
fi

# ---- Compose ntfy push ----
if [ "${A1_RESULT}" = "PASS" ] && [ "${A2_RESULT}" = "PASS" ] && [ "${A3_RESULT}" = "PASS" ]; then
	PRIO="default"
	TITLE="evidence health: 3/3 PASS"
else
	PRIO="high"
	TITLE="evidence health: FAIL — see body"
fi

MSG=$(cat <<EOF
$(ok_or_x "${A1_RESULT}") A1 cron rc:   ${A1_DETAIL}
$(ok_or_x "${A2_RESULT}") A2 fresh:     ${A2_DETAIL}
$(ok_or_x "${A3_RESULT}") A3 enriched:  ${A3_DETAIL}
EOF
)

bash "${ROOT}/scripts/notify.sh" "${PRIO}" "${TITLE}" "${MSG}"
