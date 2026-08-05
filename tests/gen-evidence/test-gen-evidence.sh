#!/usr/bin/env bash
# tests/gen-evidence/test-gen-evidence.sh — regression for the MED-6 fix to
# scripts/gen-evidence.sh: anchor_receipt and anchor_history had been live
# since the cycle 2 -> 3 transition (2026-07-04) but the manifest still
# classified both under in_preparation_artifacts with a placeholder
# planned_url, misrepresenting the live/operational split to any automated
# due-diligence consumer of /api/evidence.json. The fix moves both entries
# into live_artifacts with a real url (not planned_url), and repoints
# anchor_receipt's schema_url/formal_schema_url at the v2 schema/example
# that the live file (scripts/gen-anchor-receipt.sh) actually validates
# against.
#
# This suite runs the REAL gen-evidence.sh end to end against a fixture
# REPO_BASE (validator.json + a cycle-gate.sh stub — the real
# scripts/cycle-gate.sh is not used, since it is a small independent
# contract this suite can stub directly: --side-effect=cycle-artifact-write
# is unconditionally green with no I/O — see scripts/cycle-gate.sh's own
# header) and then validates the output both structurally (jq assertions)
# and against the REAL, committed public/api/evidence.schema.v1.json — the
# "prove the generated output schema-PASSes" requirement for this fix.
#
# CHAIN: none. gen-evidence.sh performs no broadcast (local jq compose from
#        a local validator.json only — see the script header's own
#        feedback_polite_external_access / feedback_validator_operation_first
#        constraints). PRIME_DIRECTIVE: safe.
#
# Usage:
#   bash tests/gen-evidence/test-gen-evidence.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/gen-evidence.sh"
REAL_SCHEMA="${REPO_ROOT}/public/api/evidence.schema.v1.json"

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

skip_pass() {
	echo "SKIP: $1"
	echo
	echo "test-gen-evidence.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: PASS"
	exit 0
}

[ -f "$SCRIPT" ] || { echo "FATAL: script not found at $SCRIPT" >&2; exit 1; }
[ -r "$REAL_SCHEMA" ] || { echo "FATAL: schema not found at $REAL_SCHEMA" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || skip_pass "jq unavailable"

# Schema validator: prefer ajv (matches the mandatory-validation idiom used
# by gen-anchor-source.sh / gen-anchor-receipt.sh / append-anchor-history.sh
# for R13), fall back to python3+jsonschema, skip (report PASS) if neither
# is present rather than silently pretending schema conformance was checked.
validate_schema() {
	local schema="$1" data="$2"
	if command -v ajv >/dev/null 2>&1; then
		ajv --spec=draft2020 --strict=false validate -s "$schema" -d "$data"
		return $?
	fi
	if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
		python3 - "$schema" "$data" <<'PYEOF'
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1], encoding="utf-8"))
data = json.load(open(sys.argv[2], encoding="utf-8"))
jsonschema.validate(instance=data, schema=schema, format_checker=jsonschema.FormatChecker())
PYEOF
		return $?
	fi
	return 2
}
SCHEMA_VALIDATOR_AVAILABLE=1
if ! command -v ajv >/dev/null 2>&1 && \
   ! { command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; }; then
	SCHEMA_VALIDATOR_AVAILABLE=0
fi

WORK="$(mktemp -d -t fya-gen-evidence.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURE_REPO="$WORK/repo"
mkdir -p "$FIXTURE_REPO/scripts" "$FIXTURE_REPO/public/api"

# Minimal cycle-gate.sh stub: honors exactly the contract gen-evidence.sh
# relies on (--side-effect=cycle-artifact-write -> unconditionally green,
# per the real scripts/cycle-gate.sh header) without pulling in that
# script's other side-effect types / RPC / state-file logic, which this
# suite has no need to exercise.
cat > "$FIXTURE_REPO/scripts/cycle-gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "[stub cycle-gate] cycle-artifact-write -> green" >&2
exit 0
EOF
chmod +x "$FIXTURE_REPO/scripts/cycle-gate.sh"

# Fresh validator.json (observedAt = now) so VALIDATOR_STATUS resolves to
# "active" rather than "unknown" — not itself under test here, but keeps the
# fixture representative of the live shape.
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$FIXTURE_REPO/public/api/validator.json" <<EOF
{
  "nodeId": "NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v",
  "stake": {"self": 34600},
  "delegationFee": {"percent": 3},
  "bootstrap": {"pChain": true, "xChain": true, "cChain": true},
  "observedAt": "${NOW_ISO}"
}
EOF

OUT_JSON="$FIXTURE_REPO/public/api/evidence.json"
STDOUT_LOG="$WORK/stdout.log"
STDERR_LOG="$WORK/stderr.log"

REPO_BASE="$FIXTURE_REPO" bash "$SCRIPT" >"$STDOUT_LOG" 2>"$STDERR_LOG"
RC=$?

check_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label (expected='$expected' actual='$actual')"; fi
}

check_eq "script exits 0" "0" "$RC"

if [ "$RC" -ne 0 ] || [ ! -r "$OUT_JSON" ]; then
	fail "evidence.json not written; stderr: $(cat "$STDERR_LOG" 2>/dev/null | tr '\n' '|')"
else
	pass "evidence.json written"

	check_eq "MED-6: live_artifacts.anchor_receipt.url is the real runtime URL" \
		"https://metal.freedom-yield.com/api/anchor-receipt.json" \
		"$(jq -r '.live_artifacts.anchor_receipt.url // "MISSING"' "$OUT_JSON")"
	check_eq "MED-6: live_artifacts.anchor_receipt.formal_schema_url is v2 (matches gen-anchor-receipt.sh's actual SCHEMA_FILE)" \
		"https://metal.freedom-yield.com/api/anchor-receipt.schema.v2.json" \
		"$(jq -r '.live_artifacts.anchor_receipt.formal_schema_url // "MISSING"' "$OUT_JSON")"
	check_eq "MED-6: live_artifacts.anchor_history.url is the real runtime URL" \
		"https://metal.freedom-yield.com/api/anchor-history.jsonl" \
		"$(jq -r '.live_artifacts.anchor_history.url // "MISSING"' "$OUT_JSON")"
	check_eq "MED-6: live_artifacts.anchor_history.formal_schema_url is v2 (matches append-anchor-history.sh's actual SCHEMA_FILE)" \
		"https://metal.freedom-yield.com/api/anchor-history.schema.v2.json" \
		"$(jq -r '.live_artifacts.anchor_history.formal_schema_url // "MISSING"' "$OUT_JSON")"

	check_eq "MED-6: in_preparation_artifacts.anchor_receipt no longer present" \
		"null" "$(jq -r '.in_preparation_artifacts.anchor_receipt // "null"' "$OUT_JSON")"
	check_eq "MED-6: in_preparation_artifacts.anchor_history no longer present" \
		"null" "$(jq -r '.in_preparation_artifacts.anchor_history // "null"' "$OUT_JSON")"

	if jq -e 'any(paths; .[-1] == "planned_url")' "$OUT_JSON" >/dev/null 2>&1; then
		fail "MED-6: no planned_url key should remain anywhere in the manifest"
	else
		pass "MED-6: no planned_url key remains anywhere in the manifest"
	fi

	# ---- schema conformance: prove the generated output PASSes the REAL,
	# committed schema, not a fixture copy. ---------------------------------
	if [ "$SCHEMA_VALIDATOR_AVAILABLE" -eq 0 ]; then
		fail "no JSON-schema validator available (ajv absent; python3+jsonschema absent) — cannot prove schema conformance. Run scripts/setup-schema-validator.sh."
	else
		if validate_schema "$REAL_SCHEMA" "$OUT_JSON" >"$WORK/schema-validate.log" 2>&1; then
			pass "generated evidence.json validates against public/api/evidence.schema.v1.json"
		else
			fail "generated evidence.json FAILED schema validation: $(cat "$WORK/schema-validate.log" 2>/dev/null | tr '\n' '|')"
		fi
	fi
fi

echo
echo "----------------------------------------"
echo "test-gen-evidence.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
