#!/usr/bin/env bash
# tests/incidents/test-schema.sh
#
# Validates public/api/incidents.schema.v1.json + public/api/incidents.example.json
# against a real JSON Schema validator (= jsonschema in a Python venv).
#
# Cases (positive + negative):
#   - committed example validates clean
#   - empty incidents array is valid
#   - all three event types (incident / scheduled_maintenance / drill)
#   - all three status values (open / under_remediation / resolved)
#   - potentiallyAffectedStart null + status undetermined → ACCEPTED
#   - potentiallyAffectedStart null + status not_applicable → ACCEPTED
#   - potentiallyAffectedStart ISO date + status known → ACCEPTED
#   - potentiallyAffectedStart "undetermined" string → REJECTED (= the
#     plain-string sentinel must NOT pass; use null + status enum instead)
#   - confirmedPauseWindowEnd null while ongoing → ACCEPTED
#   - resolutionDate null while open/under_remediation → ACCEPTED
#   - additive property (= unknown extra fields) → ACCEPTED (additive-only)
#   - severity outside enum → REJECTED
#   - type outside enum → REJECTED
#   - bad id pattern → REJECTED
#   - missing required field → REJECTED
#
# Setup: lazily creates /tmp/incidents-schema-venv with jsonschema if not
# present. No production state touched.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="$REPO/public/api/incidents.schema.v1.json"
EXAMPLE="$REPO/public/api/incidents.example.json"

VENV="${INCIDENTS_SCHEMA_VENV:-/tmp/incidents-schema-venv}"

# --- graceful dependency check -----------------------------------------------
# The test uses Python + the jsonschema module. We lazily create a venv on
# first run. Environments where python3-venv is missing (Debian slim / some
# CI images / operator hosts without dev packages) or where the venv cannot
# reach PyPI would fail here permanently, but the anchor / broadcast / gate
# pipelines this repo actually cares about are all covered by the other test
# suites — the incidents schema check is a nice-to-have data-hygiene guard,
# not something a missing dev tool should turn into a red run-all-tests.
# Skip cleanly (exit 0, print SKIP) when the dependency can't be provisioned.
skip_reason=""
if ! command -v python3 >/dev/null 2>&1; then
  skip_reason="python3 not on PATH"
elif [ ! -x "$VENV/bin/python3" ] && ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
  # No python3-venv module and no already-built venv — can't proceed.
  skip_reason="python3-venv module unavailable (install python3-venv or pip install jsonschema in $VENV manually)"
fi

if [ -n "$skip_reason" ]; then
  printf 'SKIP: tests/incidents/test-schema.sh — %s\n' "$skip_reason" >&2
  exit 0
fi

if [ ! -x "$VENV/bin/python3" ]; then
  echo "Creating venv at $VENV ..." >&2
  if ! python3 -m venv "$VENV" >&2; then
    printf 'SKIP: tests/incidents/test-schema.sh — venv creation failed at %s (missing python3-venv?)\n' "$VENV" >&2
    exit 0
  fi
  if ! "$VENV/bin/pip" install --quiet jsonschema >&2; then
    printf 'SKIP: tests/incidents/test-schema.sh — pip install jsonschema failed (offline?); rerun after installing manually into %s\n' "$VENV" >&2
    exit 0
  fi
fi

PY="$VENV/bin/python3"

# One final belt-and-suspenders check: the venv exists but the module might
# have been damaged (broken pip cache, disk fill, etc.). Skip gracefully
# rather than blaring FAIL from an environmental issue.
if ! "$PY" -c 'import jsonschema' >/dev/null 2>&1; then
  printf 'SKIP: tests/incidents/test-schema.sh — jsonschema module not importable in %s\n' "$VENV" >&2
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
FAILURES=()

# validate_input <name> <expected: pass|fail> <json-doc-text>
validate_input() {
  local name="$1" expected="$2"
  local doc="$3"
  local doc_file="$TMP/${name}.json"
  printf '%s' "$doc" > "$doc_file"
  if "$PY" -c "
import json, sys
import jsonschema
schema = json.load(open('$SCHEMA'))
doc = json.load(open('$doc_file'))
try:
    jsonschema.validate(instance=doc, schema=schema)
    print('VALID')
except jsonschema.ValidationError as e:
    print('INVALID:', e.message)
    sys.exit(1)
except Exception as e:
    print('ERROR:', type(e).__name__, str(e))
    sys.exit(2)
" >"$TMP/${name}.out" 2>&1; then
    actual="pass"
  else
    actual="fail"
  fi
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %-60s expected=%s actual=%s\n' "$name" "$expected" "$actual"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name expected=$expected actual=$actual: $(cat "$TMP/${name}.out")")
    printf '  FAIL  %-60s expected=%s actual=%s\n' "$name" "$expected" "$actual"
    printf '         output: %s\n' "$(cat "$TMP/${name}.out")"
  fi
}

# === Committed example must validate ====================================
echo "=== C7 committed schema + example ==="
if "$PY" -c "
import json, jsonschema
schema = json.load(open('$SCHEMA'))
example = json.load(open('$EXAMPLE'))
jsonschema.validate(instance=example, schema=schema)
print('OK')
" >"$TMP/example.out" 2>&1; then
  PASS=$((PASS + 1))
  printf '  PASS  committed example validates clean\n'
else
  FAIL=$((FAIL + 1))
  FAILURES+=("committed example FAILED validation: $(cat "$TMP/example.out")")
  printf '  FAIL  committed example: %s\n' "$(cat "$TMP/example.out")"
fi

# Verify schema itself loads + has required structure.
if "$PY" -c "
import json
s = json.load(open('$SCHEMA'))
assert s['\$id'] == 'https://metal.freedom-yield.com/api/incidents.schema.v1.json'
assert s['x-stability'] == 'additive-only-within-v1'
assert 'incidents' in s['properties']
assert 'incident' in s['\$defs']
print('OK')
" >"$TMP/struct.out" 2>&1; then
  PASS=$((PASS + 1))
  printf '  PASS  schema structural invariants ($id, stability, defs)\n'
else
  FAIL=$((FAIL + 1))
  FAILURES+=("schema structural: $(cat "$TMP/struct.out")")
  printf '  FAIL  schema structural: %s\n' "$(cat "$TMP/struct.out")"
fi

echo ""
echo "=== C7 positive cases ==="

# Empty incidents array.
validate_input "empty incidents array" pass '{
  "validatorSince": "2026-05-19",
  "incidents": []
}'

# Status: open
validate_input "status=open" pass '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-01",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Just detected",
    "severity": "Minor",
    "status": "open",
    "summary": "Newly detected, not yet under active remediation."
  }]
}'

# Status: resolved with full date set
validate_input "status=resolved with resolutionDate + postmortemUrl" pass '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-02",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "confirmedPauseWindowStart": "2026-06-24T01:00:00Z",
    "confirmedPauseWindowEnd": "2026-06-24T02:00:00Z",
    "potentiallyAffectedStart": "2026-06-24",
    "potentiallyAffectedStartStatus": "known",
    "resolutionDate": "2026-06-24",
    "title": "Resolved",
    "severity": "Major",
    "status": "resolved",
    "summary": "Fully resolved within 1h window.",
    "postmortemUrl": "https://example.com/postmortem.md"
  }]
}'

# Type: scheduled_maintenance
validate_input "type=scheduled_maintenance" pass '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-07-01-01",
    "type": "scheduled_maintenance",
    "detectionDate": "2026-07-01",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "not_applicable",
    "title": "Planned web migration",
    "severity": "Info",
    "status": "resolved",
    "summary": "Maintenance, announced ahead."
  }]
}'

# Type: drill
validate_input "type=drill" pass '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-08-01-01",
    "type": "drill",
    "detectionDate": "2026-08-01",
    "potentiallyAffectedStart": "2026-08-01",
    "potentiallyAffectedStartStatus": "known",
    "title": "DR drill tabletop",
    "severity": "Info",
    "status": "resolved",
    "summary": "Tabletop exercise."
  }]
}'

# Null fields where allowed.
validate_input "null confirmedPauseWindowEnd (= ongoing)" pass '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-25-01",
    "type": "incident",
    "detectionDate": "2026-06-25",
    "confirmedPauseWindowStart": "2026-06-25T01:00:00Z",
    "confirmedPauseWindowEnd": null,
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Still ongoing",
    "severity": "Major",
    "status": "under_remediation",
    "summary": "Pause window still open."
  }]
}'

# Additive property (= unknown field allowed).
validate_input "additive property (unknown extra field)" pass '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-25-02",
    "type": "incident",
    "detectionDate": "2026-06-25",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Additive",
    "severity": "Info",
    "status": "open",
    "summary": "Has extra field.",
    "futureField": "this is allowed under additive-only-within-v1"
  }]
}'

echo ""
echo "=== C7 negative cases ==="

# potentiallyAffectedStart="undetermined" string is REJECTED.
# (= must use null + potentiallyAffectedStartStatus="undetermined")
validate_input "REJECT: potentiallyAffectedStart=\"undetermined\" string" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-03",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "potentiallyAffectedStart": "undetermined",
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Bad sentinel",
    "severity": "Minor",
    "status": "open",
    "summary": "Should be rejected — plain string sentinel."
  }]
}'

# severity outside enum.
validate_input "REJECT: severity=Unknown" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-04",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Bad severity",
    "severity": "Unknown",
    "status": "open",
    "summary": "Should be rejected."
  }]
}'

# type outside enum.
validate_input "REJECT: type=postmortem" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-05",
    "type": "postmortem",
    "detectionDate": "2026-06-24",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Bad type",
    "severity": "Minor",
    "status": "open",
    "summary": "Should be rejected."
  }]
}'

# status outside enum.
validate_input "REJECT: status=acknowledged" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-06",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Bad status",
    "severity": "Minor",
    "status": "acknowledged",
    "summary": "Should be rejected."
  }]
}'

# bad id pattern.
validate_input "REJECT: id pattern wrong (no -NN suffix)" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Bad id",
    "severity": "Minor",
    "status": "open",
    "summary": "Should be rejected."
  }]
}'

# Missing required field (title).
validate_input "REJECT: missing required field (title)" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-07",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "severity": "Minor",
    "status": "open",
    "summary": "Missing title."
  }]
}'

# Missing required field (potentiallyAffectedStartStatus).
validate_input "REJECT: missing potentiallyAffectedStartStatus" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-08",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "potentiallyAffectedStart": null,
    "title": "No start-status",
    "severity": "Minor",
    "status": "open",
    "summary": "Missing the status disambiguator."
  }]
}'

# potentiallyAffectedStartStatus outside enum.
validate_input "REJECT: potentiallyAffectedStartStatus=ambiguous" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-09",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "ambiguous",
    "title": "Bad start-status",
    "severity": "Minor",
    "status": "open",
    "summary": "Should be rejected."
  }]
}'

# Bad date format.
validate_input "REJECT: detectionDate non-ISO" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-10",
    "type": "incident",
    "detectionDate": "24/06/2026",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Bad date",
    "severity": "Minor",
    "status": "open",
    "summary": "Should be rejected."
  }]
}'

# confirmedPauseWindowStart bad format (date without time).
validate_input "REJECT: confirmedPauseWindowStart is date-only" fail '{
  "validatorSince": "2026-05-19",
  "incidents": [{
    "id": "2026-06-24-11",
    "type": "incident",
    "detectionDate": "2026-06-24",
    "confirmedPauseWindowStart": "2026-06-24",
    "potentiallyAffectedStart": null,
    "potentiallyAffectedStartStatus": "undetermined",
    "title": "Bad pause-start",
    "severity": "Minor",
    "status": "open",
    "summary": "Should be rejected (expects date-time)."
  }]
}'

# Missing required top-level field (validatorSince).
validate_input "REJECT: missing top-level validatorSince" fail '{
  "incidents": []
}'

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
