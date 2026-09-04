#!/usr/bin/env bash
# tests/reward-tracker/test-reward-calculator.sh — verifies
# scripts/lib/reward-calculator.sh's estimate_reward() against a real Metal
# Wallet observation, plus edge cases and error handling.
#
# CHAIN: none — pure function test, no RPC, no node, no broadcast.
#
# THE FIXTURE (operator-supplied, 2026-09-04): a real Metal Wallet
# "Estimated Reward" for a 23,750 METAL stake over a 2,849,105-second
# (32d23h5m) staking period read ~201.07 METAL. estimate_reward() takes
# (stake_metal, duration_sec, current_supply_metal) — the wallet UI does not
# expose the current_supply_metal it used, so that third input is not
# independently known. What IS known is the formula itself (ported from
# metalgo's actual calculator.go — see reward-calculator.sh's header) and
# the other two inputs, which together make current_supply_metal the ONE
# remaining unknown in one equation. FIXTURE_SUPPLY_METAL below is that
# value, solved by binary search against the untouched production formula
# (not tuned against a broken one) until the output matched the observed
# 201.07 within float epsilon. This is inversion of a known formula against
# one real data point, not a fabricated number — see
# [[feedback_numeric_claim_capture_before_writing]] and
# [[feedback_no_fabricated_audit_data]]: the fixture supply is documented
# here as DERIVED, and the test's actual claim is narrower — that
# estimate_reward(23750, 2849105, FIXTURE_SUPPLY_METAL) lands within 1% of
# 201.07, which is the operator's own tolerance band, not a self-granted one.
#
# If a future correction changes any of the four Metal mainnet reward
# constants in reward-calculator.sh (min/max consumption rate, minting
# period, supply cap), FIXTURE_SUPPLY_METAL will need to be re-derived — it
# is only valid for the constants captured in this file's own header.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/scripts/lib/reward-calculator.sh"

PASS=0
FAIL=0
FAILURES=()

assert_within_pct() {
	local label="$1" expected="$2" actual="$3" tol_pct="$4"
	local ok
	ok=$(awk -v e="$expected" -v a="$actual" -v t="$tol_pct" \
		'BEGIN{d=a-e; if(d<0)d=-d; pct=(d/e)*100; print (pct<=t)?"1":"0", pct}')
	local flag pct
	flag="${ok%% *}"
	pct="${ok##* }"
	if [ "$flag" = "1" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %-60s expected≈%s actual=%s (%.4f%% off, tol %s%%)\n' "$label" "$expected" "$actual" "$pct" "$tol_pct"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected≈$expected actual=$actual, ${pct}% off > ${tol_pct}% tolerance)")
		printf '  FAIL  %-60s expected≈%s actual=%s (%.4f%% off, tol %s%%)\n' "$label" "$expected" "$actual" "$pct" "$tol_pct"
	fi
}

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %-60s expected=%s actual=%s\n' "$label" "$expected" "$actual"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected=$expected, actual=$actual)")
		printf '  FAIL  %-60s expected=%s actual=%s\n' "$label" "$expected" "$actual"
	fi
}

assert_rc() {
	local label="$1" expected_rc="$2" actual_rc="$3"
	if [ "$expected_rc" = "$actual_rc" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %-60s expected_rc=%s actual_rc=%s\n' "$label" "$expected_rc" "$actual_rc"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected_rc=$expected_rc, actual_rc=$actual_rc)")
		printf '  FAIL  %-60s expected_rc=%s actual_rc=%s\n' "$label" "$expected_rc" "$actual_rc"
	fi
}

echo "=== estimate_reward() — Metal Wallet fixture verification ==="

FIXTURE_STAKE_METAL="23750"
FIXTURE_DURATION_SEC="2849105"
FIXTURE_SUPPLY_METAL="347139159.417798947"
FIXTURE_TARGET_METAL="201.07"

ACTUAL="$(
	# shellcheck source=scripts/lib/reward-calculator.sh
	. "$LIB"
	estimate_reward "$FIXTURE_STAKE_METAL" "$FIXTURE_DURATION_SEC" "$FIXTURE_SUPPLY_METAL"
)"
assert_within_pct "23,750 METAL / 2,849,105s ≈ Metal Wallet's 201.07 METAL" "$FIXTURE_TARGET_METAL" "$ACTUAL" "1"

echo ""
echo "=== estimate_reward() — mechanical properties ==="

# Sourced directly into THIS shell (not a subshell) — assert_eq/assert_rc
# mutate PASS/FAIL/FAILURES, and a subshell's mutations do not propagate
# back to the parent, which would silently under-count every assertion
# below (caught once already while writing this test: the totals line
# read PASS=2 while 10 individual "PASS" lines had printed above it).
# shellcheck source=scripts/lib/reward-calculator.sh
. "$LIB"

Z="$(estimate_reward 0 "$FIXTURE_DURATION_SEC" "$FIXTURE_SUPPLY_METAL")"
assert_eq "stake=0 -> reward=0" "0.000000000" "$Z"

D0="$(estimate_reward "$FIXTURE_STAKE_METAL" 0 "$FIXTURE_SUPPLY_METAL")"
assert_eq "duration=0 -> reward=0" "0.000000000" "$D0"

A="$(estimate_reward 100 "$FIXTURE_DURATION_SEC" "$FIXTURE_SUPPLY_METAL")"
B="$(estimate_reward 200 "$FIXTURE_DURATION_SEC" "$FIXTURE_SUPPLY_METAL")"
DOUBLED="$(awk -v a="$A" 'BEGIN{printf "%.9f", a*2}')"
assert_eq "linear in stake: 2x stake -> 2x reward" "$DOUBLED" "$B"

RC_CURRENT_SUPPLY_METAL="$FIXTURE_SUPPLY_METAL"
ENV_FALLBACK="$(estimate_reward 100 "$FIXTURE_DURATION_SEC")"
assert_eq "RC_CURRENT_SUPPLY_METAL env fallback used when 3rd arg omitted" "$A" "$ENV_FALLBACK"
unset RC_CURRENT_SUPPLY_METAL

echo ""
echo "=== estimate_reward() — error handling ==="

estimate_reward 100 86400 >/dev/null 2>&1
assert_rc "no supply given, no env fallback -> usage error" "1" "$?"

estimate_reward 100 -1 347139159 >/dev/null 2>&1
assert_rc "negative duration -> rejected" "2" "$?"

estimate_reward 100 86400 0 >/dev/null 2>&1
assert_rc "zero current_supply -> rejected" "2" "$?"

estimate_reward 100 86400 666666666 >/dev/null 2>&1
assert_rc "current_supply == supply cap -> rejected (defensive, not in Go source)" "2" "$?"

echo ""
echo "=== estimate_reward() — mutation kill check ==="
echo "(proves the fixture assertion above actually exercises the formula:"
echo " a MUTANT copy with MIN/MAX consumption rate swapped must fail it.)"

MUTANT="$(mktemp)"
trap 'rm -f "$MUTANT"' EXIT
sed \
	-e 's/^RC_MIN_CONSUMPTION_RATE=100000$/RC_MIN_CONSUMPTION_RATE=120000/' \
	-e 's/^RC_MAX_CONSUMPTION_RATE=120000$/RC_MAX_CONSUMPTION_RATE=100000/' \
	"$LIB" > "$MUTANT"
if ! diff -q "$LIB" "$MUTANT" >/dev/null 2>&1; then
	MUTANT_ACTUAL="$(
		# shellcheck disable=SC1090  # dynamic mktemp path, by design
		. "$MUTANT"
		estimate_reward "$FIXTURE_STAKE_METAL" "$FIXTURE_DURATION_SEC" "$FIXTURE_SUPPLY_METAL"
	)"
	MUTANT_WITHIN="$(awk -v e="$FIXTURE_TARGET_METAL" -v a="$MUTANT_ACTUAL" \
		'BEGIN{d=a-e; if(d<0)d=-d; pct=(d/e)*100; print (pct<=1)?"1":"0"}')"
	if [ "$MUTANT_WITHIN" = "0" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  mutant (MIN/MAX consumption rate swapped) falls OUTSIDE 1%% tolerance (actual=%s) — the fixture check has teeth\n' "$MUTANT_ACTUAL"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("mutation kill check: mutant STILL passed the fixture tolerance (actual=$MUTANT_ACTUAL) — the fixture assertion is not sensitive to this constant")
		printf '  FAIL  mutant unexpectedly still within tolerance (actual=%s) — fixture check is not sensitive\n' "$MUTANT_ACTUAL"
	fi
else
	FAIL=$((FAIL + 1))
	FAILURES+=("mutation kill check: sed did not change the file — RC_MIN_CONSUMPTION_RATE/RC_MAX_CONSUMPTION_RATE literals not found at expected shape")
	echo "  FAIL  mutant sed produced no diff — constants not matched, mutation not actually applied"
fi
rm -f "$MUTANT"
trap - EXIT

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
