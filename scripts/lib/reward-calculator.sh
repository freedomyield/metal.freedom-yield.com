#!/usr/bin/env bash
# scripts/lib/reward-calculator.sh — estimate_reward(), a pure, unit-testable
# port of the Metal mainnet staking reward formula.
#
# CHAIN: none — this file defines shell functions only, does no I/O (no
#        curl, no file read/write), and never invokes a broadcast-capable
#        command. It is pure arithmetic: given a stake amount, a duration
#        and a current supply, it returns the reward that formula predicts.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS / WHY IT IS PORTED FROM metalgo, NOT THE WHITEPAPER
# ---------------------------------------------------------------------------
# 2026-09-04, operator correction to the reward-tracker.sh brief: the
# original brief's "見込み" (projection) math used a historical
# effective-daily-rate (reward / self_stake / duration_days of the last
# closed cycle). The operator rejected that in favor of reproducing the
# ACTUAL on-chain formula, because (a) it lets the projection work even
# before any cycle has closed, and (b) the whitepaper's §4.4.1 formula and
# the shipped Go implementation are not guaranteed to match token-for-token
# — the operator's instruction is explicit that metalgo's implementation is
# authoritative, not the paper.
#
# The formula below is a line-for-line arithmetic port of
# vms/platformvm/reward/calculator.go's Calculate() method, fetched from
# https://github.com/MetalBlockchain/metalgo (branch: master) on
# 2026-09-04. Reproduced here (comments trimmed) for cross-reference:
#
#   func (c *calculator) Calculate(stakedDuration time.Duration, stakedAmount, currentSupply uint64) uint64 {
#     bigStakedDuration := new(big.Int).SetUint64(uint64(stakedDuration))
#     bigStakedAmount := new(big.Int).SetUint64(stakedAmount)
#     bigCurrentSupply := new(big.Int).SetUint64(currentSupply)
#
#     adjustedConsumptionRateNumerator := new(big.Int).Mul(c.maxSubMinConsumptionRate, bigStakedDuration)
#     adjustedMinConsumptionRateNumerator := new(big.Int).Mul(c.minConsumptionRate, c.mintingPeriod)
#     adjustedConsumptionRateNumerator.Add(adjustedConsumptionRateNumerator, adjustedMinConsumptionRateNumerator)
#     adjustedConsumptionRateDenominator := new(big.Int).Mul(c.mintingPeriod, consumptionRateDenominator)
#
#     remainingSupply := c.supplyCap - currentSupply
#     reward := new(big.Int).SetUint64(remainingSupply)
#     reward.Mul(reward, adjustedConsumptionRateNumerator)
#     reward.Mul(reward, bigStakedAmount)
#     reward.Mul(reward, bigStakedDuration)
#     reward.Div(reward, adjustedConsumptionRateDenominator)
#     reward.Div(reward, bigCurrentSupply)
#     reward.Div(reward, c.mintingPeriod)
#
#     if !reward.IsUint64() {
#       return remainingSupply
#     }
#     return min(remainingSupply, reward.Uint64())
#   }
#
# stakedDuration and mintingPeriod are both Go time.Duration values (a
# nanosecond count) in the original, but the ratio between them is what the
# formula actually consumes — expressing BOTH consistently in seconds (as
# this port does) is arithmetically identical. Every division below is
# INTEGER floor division, applied in the SAME ORDER as the Go source (each
# .Div() call truncates before the next multiply/divide), because Go's
# big.Int arithmetic here is unsigned floor division and reordering the
# divisions would change the rounding, not just the precision. This port
# therefore does all arithmetic in nMETAL (1 METAL = 1e9 nMETAL, matching
# the chain's native fixed-point unit) using python3's arbitrary-precision
# ints — never awk/bc floating point, which cannot hold the ~1e35+
# intermediate products this formula produces without losing precision.
#
# ---------------------------------------------------------------------------
# CONSTANTS — Metal mainnet reward.Config, MainnetParams.StakingConfig
# ---------------------------------------------------------------------------
# Source: https://github.com/MetalBlockchain/metalgo
#         genesis/genesis_mainnet.go (MainnetParams), fetched 2026-09-04:
#
#   RewardConfig: reward.Config{
#     MaxConsumptionRate: .12 * reward.PercentDenominator,   // 120000
#     MinConsumptionRate: .10 * reward.PercentDenominator,   // 100000
#     MintingPeriod:      365 * 24 * time.Hour,              // 1 year
#     SupplyCap:          666666666 * units.Avax,            // 666,666,666 METAL
#   }
#   MinValidatorStake: 2 * units.KiloAvax                    // 2,000 METAL
#
# reward.PercentDenominator (vms/platformvm/reward/config.go) = 1_000_000.
#
# RC_MIN_VALIDATOR_STAKE_METAL is NOT used by estimate_reward() itself — it
# is exposed here because it is the same on-chain constant that the
# reward-tracker.sh digest/notify body cites as the self-stake starting
# point ("self-stake 2,000 → <current>"). Keeping it in this file means
# there is exactly one place that constant is sourced from, not a second
# hand-typed "2000" in reward-tracker.sh.
RC_MIN_CONSUMPTION_RATE=100000
RC_MAX_CONSUMPTION_RATE=120000
RC_MINTING_PERIOD_SEC=31536000     # 365 * 24 * 3600
RC_SUPPLY_CAP_METAL=666666666
RC_PERCENT_DENOMINATOR=1000000
# shellcheck disable=SC2034  # consumed by reward-tracker.sh, not this file
RC_MIN_VALIDATOR_STAKE_METAL=2000

# estimate_reward <stake_metal> <duration_sec> [current_supply_metal]
#   Prints the predicted total reward, in METAL, for staking <stake_metal>
#   METAL for <duration_sec> seconds, at the given (or ambient) current
#   circulating supply. 9 decimal places (exact — nMETAL has no smaller
#   unit), no thousands separator, no trailing text. Never touches stdin.
#
#   current_supply_metal resolution order:
#     1. the 3rd positional argument, if given (tests use this — see
#        tests/reward-tracker/test-reward-calculator.sh);
#     2. $RC_CURRENT_SUPPLY_METAL, if the caller has set it (production:
#        reward-tracker.sh sets this ONCE per run from a live
#        platform.getCurrentSupply call, then calls estimate_reward for
#        self + every delegator without re-fetching).
#   Neither present → usage error (rc 1). This function NEVER fetches
#   anything itself (no RPC, no state file) — that is deliberate: a pure
#   function is what makes it unit-testable against a frozen fixture
#   without a live or mocked P-Chain node.
#
#   Exit codes:
#     0  printed a reward (>= 0 METAL)
#     1  usage error (missing args, or no current_supply_metal resolvable)
#     2  invalid numeric input (negative duration, non-positive supply, or
#        current_supply_metal >= RC_SUPPLY_CAP_METAL — the last one is a
#        defensive guard the Go source does not need, because Go's
#        remainingSupply := supplyCap - currentSupply is UNSIGNED and the
#        caller there is trusted never to pass a supply at/above the cap;
#        this port has no such caller-side guarantee, so it refuses rather
#        than let a negative "remaining supply" produce a nonsense reward)
#     3  python3 not on PATH (this port's arithmetic engine)
estimate_reward() {
	if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
		echo "estimate_reward: usage: estimate_reward <stake_metal> <duration_sec> [current_supply_metal]" >&2
		return 1
	fi
	local stake_metal="$1" duration_sec="$2"
	local supply_metal="${3:-${RC_CURRENT_SUPPLY_METAL:-}}"
	if [ -z "$supply_metal" ]; then
		echo "estimate_reward: current_supply_metal not given and RC_CURRENT_SUPPLY_METAL is unset" >&2
		return 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		echo "estimate_reward: python3 required (arbitrary-precision integer arithmetic)" >&2
		return 3
	fi

	RC_MIN_CONSUMPTION_RATE="$RC_MIN_CONSUMPTION_RATE" \
	RC_MAX_CONSUMPTION_RATE="$RC_MAX_CONSUMPTION_RATE" \
	RC_MINTING_PERIOD_SEC="$RC_MINTING_PERIOD_SEC" \
	RC_SUPPLY_CAP_METAL="$RC_SUPPLY_CAP_METAL" \
	RC_PERCENT_DENOMINATOR="$RC_PERCENT_DENOMINATOR" \
	python3 - "$stake_metal" "$duration_sec" "$supply_metal" <<'PY'
import os
import sys
from decimal import Decimal, ROUND_HALF_UP

NANO = 10**9
MIN_CR = int(os.environ["RC_MIN_CONSUMPTION_RATE"])
MAX_CR = int(os.environ["RC_MAX_CONSUMPTION_RATE"])
MAX_SUB_MIN_CR = MAX_CR - MIN_CR
MINTING_PERIOD_SEC = int(os.environ["RC_MINTING_PERIOD_SEC"])
SUPPLY_CAP_METAL = int(os.environ["RC_SUPPLY_CAP_METAL"])
DENOM = int(os.environ["RC_PERCENT_DENOMINATOR"])
SUPPLY_CAP_N = SUPPLY_CAP_METAL * NANO

stake_metal_arg, duration_arg, supply_metal_arg = sys.argv[1:4]

try:
	duration_sec = int(duration_arg)
except ValueError:
	print("estimate_reward: duration_sec must be an integer number of seconds", file=sys.stderr)
	sys.exit(2)
if duration_sec < 0:
	print("estimate_reward: duration_sec must be >= 0", file=sys.stderr)
	sys.exit(2)

def to_nmetal(label, x):
	try:
		d = Decimal(x)
	except Exception:
		print(f"estimate_reward: {label} is not a valid number: {x!r}", file=sys.stderr)
		sys.exit(2)
	return int((d * NANO).to_integral_value(rounding=ROUND_HALF_UP))

stake_n = to_nmetal("stake_metal", stake_metal_arg)
supply_n = to_nmetal("current_supply_metal", supply_metal_arg)

if stake_n < 0:
	print("estimate_reward: stake_metal must be >= 0", file=sys.stderr)
	sys.exit(2)
if supply_n <= 0:
	print("estimate_reward: current_supply_metal must be > 0", file=sys.stderr)
	sys.exit(2)
if supply_n >= SUPPLY_CAP_N:
	# Defensive guard not present in the Go source — see the function's own
	# header comment (exit code 2) for why this port adds it.
	print("estimate_reward: current_supply_metal must be below the supply cap "
	      f"({SUPPLY_CAP_METAL} METAL)", file=sys.stderr)
	sys.exit(2)

remaining_n = SUPPLY_CAP_N - supply_n
adjusted_num = MAX_SUB_MIN_CR * duration_sec + MIN_CR * MINTING_PERIOD_SEC
adjusted_denom = MINTING_PERIOD_SEC * DENOM

reward_n = remaining_n
reward_n *= adjusted_num
reward_n *= stake_n
reward_n *= duration_sec
reward_n //= adjusted_denom
reward_n //= supply_n
reward_n //= MINTING_PERIOD_SEC
reward_n = min(remaining_n, reward_n)

whole, frac = divmod(reward_n, NANO)
print(f"{whole}.{frac:09d}")
PY
}
