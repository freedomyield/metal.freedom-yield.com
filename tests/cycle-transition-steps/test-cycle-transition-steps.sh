#!/usr/bin/env bash
# tests/cycle-transition-steps/test-cycle-transition-steps.sh
#
# CI gate against runbook/reality drift: docs/cycle-transition-steps.json is
# a hand-maintained, machine-readable ground truth for the 13 execution
# units a cycle transition actually runs (see that file's own $comment for
# the 2026-08-06 background — steps 7.5 and 8.5 existed in the real
# pipeline but were never written into docs/CYCLE_GATE.md or
# docs/VALIDATOR_RENEWAL.md as their own line item, which is exactly the
# class of gap this test exists to catch going forward).
#
# What this suite checks, per step in the JSON:
#   1. the step's cycle_gate_pattern is a literal substring somewhere in
#      docs/CYCLE_GATE.md (the model α runbook)
#   2. the step's validator_renewal_pattern is a literal substring
#      somewhere in docs/VALIDATOR_RENEWAL.md (day-of list + emergency
#      fallback both live in this one file)
#   3. every script named in the step's "scripts" array exists under
#      scripts/ (catches a rename/removal the runbook text was never
#      updated for — a related but distinct drift class)
#
# This is intentionally NOT a semantic check of step ORDER or full command
# arguments (those are covered by exit-code-driven tests on the individual
# scripts, e.g. tests/gen-anchor-source/, tests/gen-anchor-receipt/). It
# only proves: "every execution unit this repo's maintainers believe is
# real has at least one literal mention in both operator-facing docs."
# Forgetting to add a new step to either doc — the actual 2026-08-06
# incident class — fails this test immediately; see the header of
# docs/cycle-transition-steps.json for the update contract (add a step
# here AND to both docs in the same commit).
#
# CHAIN: none — pure text/JSON inspection, no chain reads, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (read-only).
#
# Usage:
#   bash tests/cycle-transition-steps/test-cycle-transition-steps.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEPS_JSON="${REPO_ROOT}/docs/cycle-transition-steps.json"
CYCLE_GATE_DOC="${REPO_ROOT}/docs/CYCLE_GATE.md"
RENEWAL_DOC="${REPO_ROOT}/docs/VALIDATOR_RENEWAL.md"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

if ! command -v jq >/dev/null 2>&1; then
	echo "  FAIL: jq required for this suite" >&2
	echo "test-cycle-transition-steps.sh summary: PASS=0  FAIL=1"
	echo "RESULT: FAIL"
	exit 1
fi

# ---- 0. sanity: all three inputs must exist and the JSON must parse ----
for f in "$STEPS_JSON" "$CYCLE_GATE_DOC" "$RENEWAL_DOC"; do
	if [ ! -r "$f" ]; then
		bad "required input not readable: ${f#"${REPO_ROOT}"/}"
	fi
done
if [ "$FAIL" -gt 0 ]; then
	echo "test-cycle-transition-steps.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: FAIL"
	exit 1
fi

if ! jq empty "$STEPS_JSON" >/dev/null 2>&1; then
	bad "docs/cycle-transition-steps.json is not valid JSON"
	echo "test-cycle-transition-steps.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: FAIL"
	exit 1
fi
ok "docs/cycle-transition-steps.json parses as JSON"

STEP_COUNT="$(jq '.steps | length' "$STEPS_JSON")"
if [ "$STEP_COUNT" -ge 1 ] 2>/dev/null; then
	ok "docs/cycle-transition-steps.json declares ${STEP_COUNT} step(s)"
else
	bad "docs/cycle-transition-steps.json declares zero steps (or .steps missing)"
fi

# ---- 1. no duplicate step ids ----
DUP_IDS="$(jq -r '.steps[].id' "$STEPS_JSON" | sort | uniq -d)"
if [ -z "$DUP_IDS" ]; then
	ok "no duplicate step ids"
else
	bad "duplicate step id(s): $(echo "$DUP_IDS" | tr '\n' ' ')"
fi

# ---- 2. per-step: pattern present in each doc, referenced scripts exist ----
# Iterate as TSV (id \t cycle_gate_pattern \t validator_renewal_pattern) to
# avoid a subshell-per-jq-call for every field; NUL-safe enough for this
# repo's ASCII+CJK-but-no-embedded-tab step text.
while IFS=$'\t' read -r id cg_pattern vr_pattern; do
	[ -z "$id" ] && continue

	cg_count="$(grep -cF -- "$cg_pattern" "$CYCLE_GATE_DOC" 2>/dev/null || true)"
	[ -z "$cg_count" ] && cg_count=0
	if [ "$cg_count" -ge 1 ]; then
		ok "step ${id}: pattern present in docs/CYCLE_GATE.md"
	else
		bad "step ${id}: pattern MISSING from docs/CYCLE_GATE.md — expected substring: ${cg_pattern}"
	fi

	vr_count="$(grep -cF -- "$vr_pattern" "$RENEWAL_DOC" 2>/dev/null || true)"
	[ -z "$vr_count" ] && vr_count=0
	if [ "$vr_count" -ge 1 ]; then
		ok "step ${id}: pattern present in docs/VALIDATOR_RENEWAL.md"
	else
		bad "step ${id}: pattern MISSING from docs/VALIDATOR_RENEWAL.md — expected substring: ${vr_pattern}"
	fi
done < <(jq -r '.steps[] | [.id, .cycle_gate_pattern, .validator_renewal_pattern] | @tsv' "$STEPS_JSON")

# ---- 3. every referenced script actually exists under scripts/ ----
while IFS=$'\t' read -r id script; do
	[ -z "$id" ] && continue
	[ -z "$script" ] && continue
	if [ -f "${REPO_ROOT}/scripts/${script}" ]; then
		ok "step ${id}: referenced script exists (scripts/${script})"
	else
		bad "step ${id}: referenced script MISSING (scripts/${script})"
	fi
done < <(jq -r '.steps[] | .id as $id | .scripts[]? | [$id, .] | @tsv' "$STEPS_JSON")

echo "test-cycle-transition-steps.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
