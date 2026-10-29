#!/usr/bin/env bash
# test-pipeline-not-fy-live-gated.sh — regression suite for the 2026-08-14
# "make the 9/4 rehearsal executable" task.
#
# WHAT THIS PINS: the anchor/rehearsal broadcast pipeline —
#   scripts/run-testnet-rehearsal.sh, scripts/sign-anchor-event.sh,
#   bin/safe-broadcast, scripts/gen-anchor-receipt.sh, scripts/gen-anchor-source.sh
# — stays INDEPENDENT of three things that landed between the 2026-08-04
# cycle-4 transition and this task, all elsewhere in the repo:
#
#   1. C3 (2026-08-06, `scripts/lib/side-effects.sh` + 21-script opt-in
#      rollout): production side effects across notify/monitoring/cron
#      scripts now require FY_LIVE=1. The pipeline scripts above were
#      DELIBERATELY excluded from that rollout (see
#      scripts/gen-anchor-source.sh's own header: "this script's own
#      output ... is not gated either: it is a deterministic generator an
#      operator runs by hand at a cycle transition ... gating it would turn
#      a forgotten export into a silently missing anchor source on the one
#      day of the cycle that it matters" — the same reasoning applies to
#      the rest of this pipeline, which already carries its OWN, STRICTER
#      gate: the operator-token + 4 PRIME DIRECTIVE gates in
#      bin/safe-broadcast). A future FY_LIVE sweep that widens scope to
#      include these files would silently require an extra env var on
#      cycle-transition day, in front of a time-boxed broadcast window —
#      exactly the class of self-inflicted delay the 2026-07-31 day-of
#      walkthrough audit (I3) already measured once for a different cause.
#   2. F8 (2026-08-10, `scripts/lib/publish-scan.sh`): outbound-byte
#      scanning ahead of scripts/push-to-web-host.sh and
#      scripts/sync-to-validator-host.sh. The rehearsal pipeline composes
#      and (operator-authorized) broadcasts a transaction; it never pushes
#      bytes to the web/validator host, so it has no publish-scan call site
#      to gain.
#   3. C1 (2026-08-07, deploy/publication.json): a declared-inventory
#      registry with zero runtime consumers as of this task (see the
#      file's own "_comment" and "coverage" fields) — nothing in this
#      pipeline reads it.
#
# HOW: cheap, deterministic `grep -c` counts against the tracked source of
# each pipeline script — no execution, no proton, no network, no keystore.
# Each negative assertion (below) is paired with a POSITIVE control proving
# the search pattern itself is live (i.e. the library it looks for actually
# exists and is actually referenced somewhere real) — a typo'd filename
# would otherwise make every negative assertion vacuously, silently PASS.
#
# CHAIN: none. Pure static grep over tracked files.
#
# Usage:
#   bash tests/run-testnet-rehearsal/test-pipeline-not-fy-live-gated.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0
FAIL=0
pass() { printf 'PASS  %-78s%s\n' "$1" "${2:+ ($2)}"; PASS=$((PASS + 1)); }
fail_case() { printf 'FAIL  %-78s%s\n' "$1" "${2:+ ($2)}" >&2; FAIL=$((FAIL + 1)); }

# Files held to the STRICT bar: zero reference to FY_LIVE, side-effects.sh,
# publish-scan, or publication.json at all. These are the actual broadcast
# pipeline (compose -> gate -> push to chain -> verify).
STRICT_PIPELINE_FILES=(
	"scripts/run-testnet-rehearsal.sh"
	"scripts/sign-anchor-event.sh"
	"bin/safe-broadcast"
	"scripts/gen-anchor-receipt.sh"
)

# scripts/gen-anchor-source.sh is a DELIBERATE partial exception: it sources
# scripts/lib/side-effects.sh and mentions "FY_LIVE" in its own header
# comment (see file header above) — but ONLY to call the non-gated
# fyd_state_dir() helper for a read-only input path. It must never call any
# of the actual GATING functions (fyd_is_live / fyd_live_run /
# fyd_live_write / fyd_notify / fyd_push) — those are what would condition
# its own anchor-source.json write on FY_LIVE, which its header comment
# explicitly disclaims. Checked separately below, by function name rather
# than by "no FY_LIVE substring at all" (which would also flag the
# explanatory comment itself).
GEN_ANCHOR_SOURCE="scripts/gen-anchor-source.sh"

for f in "${STRICT_PIPELINE_FILES[@]}" "$GEN_ANCHOR_SOURCE"; do
	if [ ! -r "${REPO_ROOT}/${f}" ]; then
		fail_case "pipeline file exists and is readable: ${f}" "missing"
	fi
done

# ============================================================
# Positive controls: prove the patterns below are live, not typo'd.
# ============================================================

if [ -r "${REPO_ROOT}/scripts/lib/side-effects.sh" ] \
   && grep -q 'FY_LIVE' "${REPO_ROOT}/scripts/lib/side-effects.sh"; then
	pass "positive control: scripts/lib/side-effects.sh exists and defines FY_LIVE gating"
else
	fail_case "positive control: scripts/lib/side-effects.sh exists and defines FY_LIVE gating" "grep found nothing — the FY_LIVE search below would be vacuous"
fi

if [ -r "${REPO_ROOT}/scripts/lib/publish-scan.sh" ] \
   && grep -ql 'publish-scan' "${REPO_ROOT}/scripts/push-to-web-host.sh" 2>/dev/null; then
	pass "positive control: scripts/lib/publish-scan.sh exists and IS wired into push-to-web-host.sh"
else
	fail_case "positive control: scripts/lib/publish-scan.sh exists and IS wired into push-to-web-host.sh" "grep found nothing — the publish-scan search below would be vacuous"
fi

if [ -r "${REPO_ROOT}/deploy/publication.json" ]; then
	pass "positive control: deploy/publication.json (C1) exists"
else
	fail_case "positive control: deploy/publication.json (C1) exists" "missing"
fi

# ============================================================
# Negative assertions: the pipeline files must not reference any of the
# three landed-elsewhere mechanisms above.
# ============================================================

for f in "${STRICT_PIPELINE_FILES[@]}"; do
	path="${REPO_ROOT}/${f}"
	[ -r "$path" ] || continue

	if grep -q 'FY_LIVE' "$path"; then
		fail_case "${f}: no FY_LIVE reference (C3 opt-in must not gate this pipeline)" "grep matched"
	else
		pass "${f}: no FY_LIVE reference (C3 opt-in must not gate this pipeline)"
	fi

	if grep -q 'side-effects\.sh' "$path"; then
		fail_case "${f}: does not source scripts/lib/side-effects.sh" "grep matched"
	else
		pass "${f}: does not source scripts/lib/side-effects.sh"
	fi

	if grep -qi 'publish-scan' "$path"; then
		fail_case "${f}: no publish-scan reference (F8 is scoped to push/sync, not compose/broadcast)" "grep matched"
	else
		pass "${f}: no publish-scan reference (F8 is scoped to push/sync, not compose/broadcast)"
	fi

	if grep -q 'publication\.json' "$path"; then
		fail_case "${f}: no deploy/publication.json reference (C1 has no runtime consumers yet)" "grep matched"
	else
		pass "${f}: no deploy/publication.json reference (C1 has no runtime consumers yet)"
	fi
done

# ============================================================
# scripts/gen-anchor-source.sh: the deliberate partial exception (see
# GEN_ANCHOR_SOURCE comment above). Checked by GATING FUNCTION NAME, not by
# bare "FY_LIVE" substring absence (which would also flag its own, wanted,
# explanatory comment) — and its FY_LIVE-independence claim must still be
# spelled out in the source, not just true by grep-absence, since a silent,
# undocumented exemption is one accidental edit away from being "forgotten"
# and swept into a future FY_LIVE rollout.
# ============================================================

GEN_SRC="${REPO_ROOT}/${GEN_ANCHOR_SOURCE}"
if [ -r "$GEN_SRC" ]; then
	if grep -qE 'fyd_is_live|fyd_live_run|fyd_live_write|fyd_notify|fyd_push' "$GEN_SRC"; then
		fail_case "${GEN_ANCHOR_SOURCE}: calls no FY_LIVE-gating function (only the non-gated fyd_state_dir helper)" "grep matched a gating function"
	else
		pass "${GEN_ANCHOR_SOURCE}: calls no FY_LIVE-gating function (only the non-gated fyd_state_dir helper)"
	fi

	if grep -q 'fyd_state_dir' "$GEN_SRC"; then
		pass "${GEN_ANCHOR_SOURCE}: does source side-effects.sh, but only for the non-gated fyd_state_dir helper"
	else
		fail_case "${GEN_ANCHOR_SOURCE}: does source side-effects.sh, but only for the non-gated fyd_state_dir helper" "fyd_state_dir call not found — the exception's own justification no longer holds"
	fi

	if grep -qi 'publish-scan' "$GEN_SRC"; then
		fail_case "${GEN_ANCHOR_SOURCE}: no publish-scan reference (F8 is scoped to push/sync, not generation)" "grep matched"
	else
		pass "${GEN_ANCHOR_SOURCE}: no publish-scan reference (F8 is scoped to push/sync, not generation)"
	fi

	if grep -q 'publication\.json' "$GEN_SRC"; then
		fail_case "${GEN_ANCHOR_SOURCE}: no deploy/publication.json reference (C1 has no runtime consumers yet)" "grep matched"
	else
		pass "${GEN_ANCHOR_SOURCE}: no deploy/publication.json reference (C1 has no runtime consumers yet)"
	fi

	if grep -qi 'NOT gated on FY_LIVE' "$GEN_SRC"; then
		pass "${GEN_ANCHOR_SOURCE}: FY_LIVE exemption is explicitly documented in-file"
	else
		fail_case "${GEN_ANCHOR_SOURCE}: FY_LIVE exemption is explicitly documented in-file" "explanatory comment not found — exemption may have gone undocumented"
	fi
else
	fail_case "${GEN_ANCHOR_SOURCE}: readable" "missing"
fi

echo
echo "----------------------------------------"
echo "test-pipeline-not-fy-live-gated.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
