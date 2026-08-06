#!/usr/bin/env bash
# test-incident-attribution.sh — suite for gen-cycle-history.sh's incident join.
#
# CHAIN: none — builds synthetic uptime-cycles.json / incidents.json in a
#        tempdir and runs the generator against them. No network, no host.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Covers the two properties the 2026-08-06 audit had to establish by hand:
#
#   1. FIELD NAME — incidents are selected on `detectionDate`. Reading a
#      non-existent `.date` made jq return null, `null >= "..."` false for
#      every entry, and every cycle report 0 incidents while staying
#      schema-valid. Nothing in the pipeline noticed for as long as it ran.
#
#   2. BOUNDARY ATTRIBUTION — `detectionDate` is a date ("2026-06-24") and
#      start_iso/end_iso are timestamps ("2026-05-19T07:10:14Z"). Compared
#      directly, the shorter date string sorts BEFORE the same-day timestamp,
#      so an incident on a cycle's own start date fell into the previous
#      cycle — and one on the FIRST cycle's start date belonged to no cycle at
#      all and disappeared from the feed. Both sides are now truncated to their
#      date part, and the generator's conservation check enforces that every
#      incident in the covered window lands in exactly one cycle.
#
# Usage:
#   bash tests/gen-cycle-history/test-incident-attribution.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="${REPO_ROOT}/scripts/gen-cycle-history.sh"

if [ ! -f "$GEN" ]; then
	echo "FATAL: generator not found at $GEN" >&2
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "FATAL: jq required" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

BASE="$(mktemp -d -t gen-cycle-history-test.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT

# build <name> <cycles-json> <incidents-json> -> sets T
build() {
	T="$BASE/$1"
	rm -rf "$T"
	mkdir -p "$T/public/api" "$T/scripts"
	cp "$GEN" "$T/scripts/"
	# The real cycle-gate is a fail-closed guard around cycle-affecting writes;
	# stub it open so these cases exercise the join, not the gate.
	printf '#!/usr/bin/env bash\nexit 0\n' > "$T/scripts/cycle-gate.sh"
	chmod +x "$T/scripts/cycle-gate.sh"
	printf '%s\n' "$2" > "$T/public/api/uptime-cycles.json"
	printf '%s\n' "$3" > "$T/public/api/incidents.json"
}

run_gen() { OUT="$(REPO_BASE="$T" bash "$T/scripts/gen-cycle-history.sh" 2>&1)"; RC=$?; }

# Two contiguous cycles: cycle 1 starts on the validator's first day.
CYCLES_CONTIGUOUS='{"cycles":[
 {"cycle_n":1,"node_id":"NodeID-test","start_iso":"2026-05-19T07:10:14Z","end_iso":"2026-06-04T07:17:46Z","duration_days":16,"final_uptime_pct":99.9,"days_recorded":16,"final_self_stake_metal":2000,"final_total_delegated_metal":0,"final_delegation_fee_pct":3,"avg_peer_count":10,"min_peer_count":8,"explorer_url":"https://example.invalid/1","notes":null},
 {"cycle_n":2,"node_id":"NodeID-test","start_iso":"2026-06-04T07:17:46Z","end_iso":"2026-07-04T07:00:00Z","duration_days":30,"final_uptime_pct":99.8,"days_recorded":30,"final_self_stake_metal":5900,"final_total_delegated_metal":0,"final_delegation_fee_pct":3,"avg_peer_count":11,"min_peer_count":9,"explorer_url":"https://example.invalid/2","notes":null}
]}'

# One incident on the first cycle's start date, one exactly on the shared
# cycle boundary, one mid-cycle.
INCIDENTS_3='{"validatorSince":"2026-05-19","incidents":[
 {"id":"A-first-day","detectionDate":"2026-05-19","title":"t","severity":"Minor","status":"resolved","summary":"s"},
 {"id":"B-boundary","detectionDate":"2026-06-04","title":"t","severity":"Minor","status":"resolved","summary":"s"},
 {"id":"C-mid","detectionDate":"2026-06-24","title":"t","severity":"Critical","status":"resolved","summary":"s"}
]}'

# ---- 1: incidents are actually found (the field-name regression) -----------
build fieldname "$CYCLES_CONTIGUOUS" "$INCIDENTS_3"
run_gen
TOTAL="$(jq -s 'map(.incidents_in_cycle_count) | add' "$T/public/api/cycle-history.jsonl" 2>/dev/null)"
[ "$RC" -eq 0 ] && [ "$TOTAL" = "3" ] \
	&& ok "1 all 3 incidents are attributed (detectionDate is read, not .date)" \
	|| bad "1 incident count (rc=$RC total=$TOTAL): $OUT"

# ---- 2: an incident on the FIRST cycle's start date is not lost ------------
IDS1="$(jq -r 'select(.cycle_n==1) | .incidents_in_cycle_ids | join(",")' \
	"$T/public/api/cycle-history.jsonl" 2>/dev/null)"
[ "$IDS1" = "A-first-day" ] \
	&& ok "2 incident on the first cycle's start date lands in cycle 1" \
	|| bad "2 first-day attribution (got '$IDS1', want 'A-first-day')"

# ---- 3: a boundary-date incident belongs to the cycle that STARTS that day -
IDS2="$(jq -r 'select(.cycle_n==2) | .incidents_in_cycle_ids | join(",")' \
	"$T/public/api/cycle-history.jsonl" 2>/dev/null)"
[ "$IDS2" = "B-boundary,C-mid" ] \
	&& ok "3 boundary-date incident lands in the cycle starting that day (once)" \
	|| bad "3 boundary attribution (got '$IDS2', want 'B-boundary,C-mid')"

# ---- 4: no incident is counted twice ---------------------------------------
DUPES="$(jq -s '[.[].incidents_in_cycle_ids[]] | group_by(.) | map(select(length > 1)) | length' \
	"$T/public/api/cycle-history.jsonl" 2>/dev/null)"
[ "$DUPES" = "0" ] \
	&& ok "4 no incident is attributed to more than one cycle" \
	|| bad "4 duplicate attribution (groups with >1: $DUPES)"

# ---- 5: conservation check fires when an incident falls in no cycle --------
# Non-contiguous cycles leave a gap; the incident inside it is attributable to
# nothing, which is exactly the silent-undercount shape the check exists for.
CYCLES_GAP='{"cycles":[
 {"cycle_n":1,"node_id":"NodeID-test","start_iso":"2026-05-19T07:10:14Z","end_iso":"2026-06-04T07:17:46Z","duration_days":16,"final_uptime_pct":99.9,"days_recorded":16,"final_self_stake_metal":2000,"final_total_delegated_metal":0,"final_delegation_fee_pct":3,"avg_peer_count":10,"min_peer_count":8,"explorer_url":"https://example.invalid/1","notes":null},
 {"cycle_n":2,"node_id":"NodeID-test","start_iso":"2026-06-20T00:00:00Z","end_iso":"2026-07-04T07:00:00Z","duration_days":14,"final_uptime_pct":99.8,"days_recorded":14,"final_self_stake_metal":5900,"final_total_delegated_metal":0,"final_delegation_fee_pct":3,"avg_peer_count":11,"min_peer_count":9,"explorer_url":"https://example.invalid/2","notes":null}
]}'
INCIDENT_IN_GAP='{"validatorSince":"2026-05-19","incidents":[
 {"id":"D-in-gap","detectionDate":"2026-06-10","title":"t","severity":"Major","status":"resolved","summary":"s"}
]}'
build gap "$CYCLES_GAP" "$INCIDENT_IN_GAP"
run_gen
[ "$RC" -eq 4 ] && echo "$OUT" | grep -q "not conserved" \
	&& ok "5 conservation check fails closed (exit 4) on a dropped incident" \
	|| bad "5 conservation check (rc=$RC): $OUT"

# ---- 6: and it refuses to write the wrong file -----------------------------
[ ! -f "$T/public/api/cycle-history.jsonl" ] \
	&& ok "6 no output written when attribution is not conserved" \
	|| bad "6 wrote cycle-history.jsonl despite a failed conservation check"

# ---- 7: zero incidents is a legitimate result, not a failure ---------------
build none "$CYCLES_CONTIGUOUS" '{"validatorSince":"2026-05-19","incidents":[]}'
run_gen
TOTAL0="$(jq -s 'map(.incidents_in_cycle_count) | add' "$T/public/api/cycle-history.jsonl" 2>/dev/null)"
[ "$RC" -eq 0 ] && [ "$TOTAL0" = "0" ] \
	&& ok "7 an empty incident log produces zeros, not an error" \
	|| bad "7 empty incident log (rc=$RC total=$TOTAL0): $OUT"

echo
echo "test-incident-attribution.sh summary: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
