#!/usr/bin/env bash
# tests/a-chain-profile/test-gate1-drift.sh — the COMMITTED
# config/a-chain-profiles.json must keep every pulsevm-* profile's
# gate1_evidence_profile at null.
# CHAIN: none (reads one JSON file). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Why: setting pulsevm-mainnet.gate1_evidence_profile is the one edit that
# opens PRIME DIRECTIVE gate 1 for PulseVM, i.e. it decides what "the
# corresponding testnet" means. That is an interpretation of the Constitution,
# not a config tweak, and must not ride in on a one-field commit.
#
# GATE1_DRIFT_CFG overrides the file (used only to mutate a temp copy).
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CFG="${GATE1_DRIFT_CFG:-${REPO_ROOT}/config/a-chain-profiles.json}"
FAIL=0
n=0
while IFS=$'\t' read -r name val; do
	n=$((n + 1))
	if [ "$val" = "null" ]; then
		printf 'PASS %s gate1_evidence_profile is null\n' "$name"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL %s gate1_evidence_profile is %s, expected null\n' "$name" "$val"
		printf '     This value may only change together with an operator decision recorded as a\n'
		printf '     Constitution §9 clarification (like the v0.5 §5 precedent), cited in the\n'
		printf '     profile commit; update this test in the same commit. See\n'
		printf '     docs/A_CHAIN_PULSEVM_CUTOVER.md §3(a).\n'
	fi
done < <(jq -r '.profiles | to_entries[] | select(.key | startswith("pulsevm-")) | [.key, (.value.gate1_evidence_profile | tojson)] | @tsv' "$CFG")
if [ "$n" -lt 2 ]; then
	FAIL=$((FAIL + 1)); printf 'FAIL expected at least 2 pulsevm-* profiles, found %s\n' "$n"
fi
echo "---"; echo "gate1-drift: profiles=${n} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
