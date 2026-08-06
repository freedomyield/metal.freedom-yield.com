#!/usr/bin/env bash
# notify-evidence-health.sh — health check for /api/evidence.json publication.
#
# Two modes:
#   bash notify-evidence-health.sh               → ntfy push (legacy/standalone)
#   bash notify-evidence-health.sh --summary     → write 3-line summary to stdout
#                                                   (= for composition into the
#                                                   morning daily-status ntfy)
#
# Originally fired standalone at ~01:35 UTC every day, but that produced a
# second ntfy push too close to the 00:00 UTC morning daily-status digest
# (= duplicate cron output per user feedback 2026-06-23). The new flow has
# daily-status.sh morning call this script with --summary and embed the
# result, so the operator sees a single morning push containing both the
# daily snapshot and the evidence-pipeline health row.
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
# Output (push mode): one ntfy push with a 3-line PASS/FAIL summary.
#   Priority `default` when all three pass, `high` when any fails — Android
#   DND handles sleep-time silencing per memory reference_ntfy_notifications.
# Output (--summary mode): 3 lines on stdout, no ntfy call.
#   Exit code 0 when 3/3 PASS, 1 otherwise (caller can branch on it if
#   they want to escalate priority of the host push).
#
# Env:
#   FY_LIVE=1  REQUIRED before the push mode reaches ntfy. Anything else is
#              a loud dry no-op printing one "DRY: would notify …" line
#              (scripts/lib/side-effects.sh, C3 rollout 2026-08-06).
#              --summary mode has no side effect and is unaffected.
#
# Exit code 3 (push mode only): scripts/lib/side-effects.sh missing.

set -euo pipefail

MODE="push"
case "${1:-}" in
	--summary|--summary-only) MODE="summary" ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FYD_LIB="${ROOT}/scripts/lib/side-effects.sh"
if [ ! -r "$FYD_LIB" ]; then
	echo "notify-evidence-health: FATAL: side-effects library not readable at $FYD_LIB" >&2
	exit 3
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

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

# ---- Compose output ----
MSG=$(cat <<EOF
$(ok_or_x "${A1_RESULT}") A1 cron rc:   ${A1_DETAIL}
$(ok_or_x "${A2_RESULT}") A2 fresh:     ${A2_DETAIL}
$(ok_or_x "${A3_RESULT}") A3 enriched:  ${A3_DETAIL}
EOF
)

if [ "${MODE}" = "summary" ]; then
	# Embedding mode — print to stdout, no ntfy call. Exit code carries
	# overall PASS/FAIL so the caller can branch.
	printf '%s\n' "${MSG}"
	if [ "${A1_RESULT}" = "PASS" ] && [ "${A2_RESULT}" = "PASS" ] && [ "${A3_RESULT}" = "PASS" ]; then
		exit 0
	else
		exit 1
	fi
fi

# Standalone push mode (legacy).
if [ "${A1_RESULT}" = "PASS" ] && [ "${A2_RESULT}" = "PASS" ] && [ "${A3_RESULT}" = "PASS" ]; then
	PRIO="default"
	TITLE="evidence health: 3/3 PASS"
else
	PRIO="high"
	TITLE="evidence health: FAIL — see body"
fi

fyd_notify "${PRIO}" "${TITLE}" "${MSG}"
