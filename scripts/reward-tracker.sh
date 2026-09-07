#!/usr/bin/env bash
# reward-tracker.sh — detects a matured validator cycle's confirmed reward,
# records it append-only (split into self-stake reward / delegation-fee
# income where the chain's own output order makes that certain), pushes a
# one-time "🎉 cycle reward" notification, and maintains the four-line
# morning-digest block: cumulative reward, the IN-PROGRESS cycle's expected
# reward at maturity, elapsed days, and the self-stake milestone.
#
# CHAIN: none — every RPC call is a read-only POST against the LOCAL metalgo
#        node (platform.getCurrentValidators / getRewardUTXOs /
#        getCurrentSupply). No broadcast-capable method is ever called; this
#        file has no route to bin/safe-broadcast or the Prime Directive's
#        four gates.
# PRIME_DIRECTIVE: TESTNET-FIRST — not applicable (no broadcast pathway).
#
# ---------------------------------------------------------------------------
# WHAT THIS TRACKS AND WHY (validator reward = self-stake reward + a cut of
# every delegator's reward — 2026-09-04 operator correction to the original
# design, which only modeled the self-stake half)
# ---------------------------------------------------------------------------
# Every AddValidatorTx metalgo processes gets a `potentialReward` computed
# ONCE at registration time (vms/platformvm/reward/calculator.go) and paid
# out when the tx matures — PROVIDED the uptime requirement was met. When
# this validator's own AddValidatorTx matures, metalgo ALSO pays out, in the
# SAME reward event, the accrued "delegatee reward" — the operator's cut
# (this validator's delegationFee%, currently 3%) of every delegator's own
# reward over that cycle (vms/platformvm/txs/executor/
# proposal_tx_executor.go, rewardValidatorTx()). Both amounts are recorded
# via AddRewardUTXO(txID, …) under the SAME txID — this validator's own
# AddValidatorTx ID — which is exactly the txID this script tracks and later
# calls platform.getRewardUTXOs against. So reward_metal recorded below
# ALREADY combines self-stake reward + delegation-fee income; the ledger's
# self_reward_metal / fee_income_metal (schema v2, below) only LABEL the two
# halves of that same total.
#
# WHY reward_metal WAS ONE FIELD (2026-09-04), AND HOW IT IS SPLIT NOW
# (2026-09-07, relative-order method):
# The 2026-09-04 design recorded one combined reward_metal: both reward
# outputs share the same TxID and differ only by OutputIndex, and the
# ABSOLUTE OutputIndex depends on the ORIGINAL AddValidatorTx's own
# output/stake count (`len(outputs)+len(stake)`), which this script cannot
# know without fetching and decoding that tx. That reasoning still holds
# for absolute indices. What it missed is that the split needs only the
# RELATIVE order, which rewardValidatorTx() fixes: self output at K, fee
# output at K+1 (commit path). On 2026-09-07 the operator asked for the
# breakdown, and scripts/lib/reward-utxo-decode.sh's
# split_reward_utxos_metal now derives it from OutputIndex order — READ
# THAT FILE'S "SELF / FEE SPLIT" HEADER before touching this: it cites the
# metalgo source line by line, including the one shape the naive rule gets
# wrong (a single output on the ABORT path is the delegatee cut, not the
# self reward, at the SAME index). A single output is therefore split only
# against the validator's PotentialReward, which platform.getCurrentValidators
# exposes as `potentialReward` while the tx is current; this script stores
# it in reward-tracker-state.json (tracked_potential_reward_nmetal) on
# every run so it is on hand when the tx matures. Every shape the source
# does not produce is recorded with split_known:false — total kept,
# breakdown null — never guessed.
#
# LEDGER SCHEMA v2 (2026-09-07). Rows keep every v1 field unchanged
# (reward_metal is still the combined total) and add self_reward_metal /
# fee_income_metal / split_known / schema_version:2. The file stays
# APPEND-ONLY: a v1 row is never rewritten. Readers apply the same rule
# uptime-cycles.json uses — the LAST row for a given cycle_n is the
# effective one (`[...] | last`) — so --backfill can supersede a v1 row by
# appending a v2 row for the same cycle, and every cumulative figure is
# computed over effective rows only. A v1 row that is still effective (or a
# v2 row with split_known:false) contributes to the cumulative TOTAL and is
# surfaced as "内訳不明 +N" in the breakdown, never silently folded into
# either half.
#
# ---------------------------------------------------------------------------
# PROJECTION (the morning digest's "見込み") — reward.Calculator ported
# ---------------------------------------------------------------------------
# scripts/lib/reward-calculator.sh's estimate_reward() is a pure port of
# metalgo's actual reward formula (not the whitepaper — see that file's
# header for why, and its own fixture test for a real Metal Wallet
# cross-check). The digest's projection is the reward expected AT MATURITY
# for the whole in-progress cycle (2026-09-07 operator change — previously
# it was scaled by the elapsed fraction to show "reward-so-far"; the
# operator wants the full-cycle figure, which is what estimate_reward()
# predicts and what the chain will actually pay, and the elapsed days are
# shown on their own line instead):
#
#   self_estimate = estimate_reward(self_stake_metal, cycle_duration_sec)
#   fee_estimate  = Σ_delegators estimate_reward(delegator_stake_metal * fee_fraction,
#                                                delegator_duration_sec)
#   digest_estimate = self_estimate + fee_estimate
#
# The `delegator_stake_metal * fee_fraction` term (not
# `estimate_reward(delegator_stake) * fee_fraction`) is deliberate and
# mathematically equivalent: estimate_reward's formula is exactly LINEAR in
# its stake argument (every other term is independent of stake), so scaling
# the stake INPUT by the fee fraction before the call produces the identical
# result, integer-truncation noise aside, as scaling the OUTPUT — and it is
# the shape that mirrors reward.Split()'s actual on-chain semantics (the
# validator's delegatee cut is fee% of the delegator's *reward*, i.e. the
# fee is applied inside the linear scaling, not outside it — see
# proposal_tx_executor.go's `reward.Split(delegator.PotentialReward,
# vdrTx.Shares())`, where the first return value — shares% of the total —
# is the delegatee's cut).
#
# current_supply_metal for these calls is fetched ONCE per run via
# platform.getCurrentSupply and cached in $RC_CURRENT_SUPPLY_METAL (see
# reward-calculator.sh's env-fallback resolution order) — never guessed,
# never hardcoded. If that RPC fails, the digest's projection segment is
# omitted (never fabricated) — see compute_and_write_digest().
#
# ---------------------------------------------------------------------------
# STATE (all under fyd_state_dir; production default /var/lib/freedom-yield)
# ---------------------------------------------------------------------------
#   rewards-history.jsonl     Append-only. One line per matured, confirmed
#                             cycle (schema v2, 2026-09-07):
#                               {"cycle_n":N,"reward_metal":X,
#                                "self_stake_metal":S,"start_unix":..,
#                                "end_unix":..,"add_validator_tx":"..",
#                                "observed_at":"..",
#                                "schema_version":2,
#                                "self_reward_metal":a|null,
#                                "fee_income_metal":b|null,
#                                "split_known":true|false}
#                             v1 rows (no schema_version) lack the last
#                             four keys. Existing lines are NEVER rewritten
#                             — only appended to, and only under FY_LIVE=1.
#                             Readers take the LAST row per cycle_n as the
#                             effective one (see "LEDGER SCHEMA v2" above).
#   reward-tracker-state.json In-flight tracking: which AddValidatorTx this
#                             script is currently waiting to mature (txID,
#                             its startTime/endTime/weight/potentialReward
#                             as observed on the latest run). Advances only
#                             after a maturity is either recorded or
#                             confirmed to need no recording.
#   reward-digest-line.txt    Up to FOUR lines, REGENERATED every run (not
#                             append-only): the morning digest block
#                             daily-status.sh splices into its morning push
#                             under [Reward]. Shape (2026-09-07):
#                               累積 N METAL (自己 a / 手数料 b)
#                               Cycle 5 見込み +M METAL (自己 +a / 手数料 +b)
#                               　10/7 満期・経過 3/33 日
#                               25,000 まで残り R
#                             Lines 2–3 are omitted (never fabricated) when
#                             the projection cannot be computed this run.
#
# ---------------------------------------------------------------------------
# NUMERIC NON-LEAK (constitution: no METAL amount on this script's own
# stdout/stderr — see scripts/daily-status.sh:66's identical discipline)
# ---------------------------------------------------------------------------
# Every log line in this script is number-free by construction: confirmation
# messages name what happened ("appended cycle N", "digest block updated")
# never how much. The only two places a METAL amount is ever formed into
# text are (a) the ntfy notification body, passed straight to fyd_notify
# (whose OWN dry-mode note prints a byte COUNT, never the message — see
# scripts/lib/side-effects.sh), and (b) the digest block content, piped
# straight into fyd_live_write (same dry-mode byte-count-only guarantee).
# Neither path ever touches this script's own echo/printf to stdout/stderr.
# tests/reward-tracker/test-reward-tracker.sh enforces this with a grep over
# captured stdout+stderr, and separately proves the check has teeth by
# re-running against a MUTANT copy with one diagnostic echo of reward_metal
# added, confirming that mutant is what makes the grep fail.
#
# ---------------------------------------------------------------------------
# Usage:
#   reward-tracker.sh                        normal daily run
#   reward-tracker.sh --backfill <txID> <cycle_n>
#                                             manually record ONE already-
#                                             matured historical cycle whose
#                                             AddValidatorTx this script
#                                             never tracked live (e.g. first
#                                             deploy of this script, or a
#                                             gap). Looks up cycle_n's
#                                             start_unix/end_unix/
#                                             final_self_stake_metal from
#                                             public/api/uptime-cycles.json
#                                             (no live "tracked weight" is
#                                             available for a backfilled tx).
#                                             Sends NO notification (backfill
#                                             is a manual, historical
#                                             operation — a "🎉 matured"
#                                             push about the past would be
#                                             noise) and does not touch the
#                                             digest file or the live
#                                             tracking state. Idempotency
#                                             (2026-09-07): if the effective
#                                             row for this txID is already a
#                                             v2 row, no-op; if only a v1 row
#                                             exists, ONE v2 row is appended
#                                             (the v1 row is left in place —
#                                             append-only). No potentialReward
#                                             hint is available for a
#                                             historical tx, so a single-
#                                             output backfill records
#                                             split_known:false.
#
# Env:
#   METALGO_RPC          metalgo RPC base URL        (default http://127.0.0.1:9650)
#   FY_RPC_TIMEOUT        curl --max-time seconds     (default 6)
#   VALIDATOR_JSON        path to validator.json      (default public/api/validator.json)
#   UPTIME_CYCLES_JSON    path to uptime-cycles.json  (default public/api/uptime-cycles.json)
#   FY_REWARD_MILESTONE   self-stake milestone, METAL (default 25000)
#   FY_LIVE=1              REQUIRED before the rewards-history append, the
#                          state write, the digest-file write, or the ntfy
#                          push happen for real (scripts/lib/side-effects.sh).
#                          Anything else is a loud dry no-op — see that
#                          library's header. Values are NEVER printed even
#                          in dry mode (see NUMERIC NON-LEAK above).
#
# Exit codes:
#   0  ran to completion (including "nothing matured, nothing to do")
#   1  usage error
#   3  scripts/lib/side-effects.sh missing (structural)
#   4  scripts/lib/reward-calculator.sh or reward-utxo-decode.sh missing (structural)
#   5  --backfill: cycle_n not found in uptime-cycles.json
#   6  --backfill: cycle_n's effective ledger row belongs to a DIFFERENT
#      txID (refused — the append-only ledger cannot have two txIDs claim
#      one cycle; resolve by hand before retrying)
#   (--backfill against an already-recorded v2 txID is exit 0, an idempotent no-op — not a distinct exit code, since it is not an error)
#   7  cannot open the flock lock file (structural — locks/ directory unwritable)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FYD_LIB="${ROOT}/scripts/lib/side-effects.sh"
if [ ! -r "$FYD_LIB" ]; then
	echo "reward-tracker: FATAL: side-effects library not readable at $FYD_LIB" >&2
	exit 3
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

RC_LIB="${ROOT}/scripts/lib/reward-calculator.sh"
UTXO_LIB="${ROOT}/scripts/lib/reward-utxo-decode.sh"
if [ ! -r "$RC_LIB" ] || [ ! -r "$UTXO_LIB" ]; then
	echo "reward-tracker: FATAL: reward-calculator.sh or reward-utxo-decode.sh not readable under ${ROOT}/scripts/lib" >&2
	exit 4
fi
# shellcheck source=scripts/lib/reward-calculator.sh
. "$RC_LIB"
# shellcheck source=scripts/lib/reward-utxo-decode.sh
. "$UTXO_LIB"

METALGO_RPC="${METALGO_RPC:-http://127.0.0.1:9650}"
RPC_TIMEOUT="${FY_RPC_TIMEOUT:-6}"
VALIDATOR_JSON="${VALIDATOR_JSON:-$ROOT/public/api/validator.json}"
UPTIME_CYCLES_JSON="${UPTIME_CYCLES_JSON:-$ROOT/public/api/uptime-cycles.json}"
FY_REWARD_MILESTONE="${FY_REWARD_MILESTONE:-25000}"

STATE_DIR="$(fyd_state_dir)" || exit $?
REWARDS_HISTORY="${STATE_DIR}/rewards-history.jsonl"
TRACKER_STATE="${STATE_DIR}/reward-tracker-state.json"
DIGEST_FILE="${STATE_DIR}/reward-digest-line.txt"
# Owned by uptime-history.sh, which resolves it via fyd_state_dir's "uptime"
# role — read it the same way so a test that only overrides
# UPTIME_STATE_DIR (not FY_STATE_DIR) still finds the same file this script
# reads. See scripts/lib/side-effects.sh's fyd_state_dir header re: roles.
UPTIME_STATE_DIR="$(fyd_state_dir uptime)" || exit $?
CURRENT_CYCLE_STATE="${UPTIME_STATE_DIR}/current-cycle-state.json"

fyd_live_run "create the state dir ${STATE_DIR}" mkdir -p "$STATE_DIR"

# ---- arg parsing -------------------------------------------------------
BACKFILL=0
BACKFILL_TX=""
BACKFILL_CYCLE_N=""
if [ "${1:-}" = "--backfill" ]; then
	BACKFILL=1
	BACKFILL_TX="${2:-}"
	BACKFILL_CYCLE_N="${3:-}"
	if [ -z "$BACKFILL_TX" ] || [ -z "$BACKFILL_CYCLE_N" ]; then
		echo "reward-tracker: usage: reward-tracker.sh --backfill <txID> <cycle_n>" >&2
		exit 1
	fi
elif [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	sed -n '2,60p' "$0" | sed 's/^# \?//'
	exit 0
elif [ $# -gt 0 ]; then
	echo "reward-tracker: unknown argument: $1" >&2
	exit 1
fi

# ---- small helpers (no METAL numbers ever passed to these for echo) -----

# rpc_post <endpoint_suffix> <json_body> — POST to $METALGO_RPC<suffix>.
# Prints the raw response body (empty on any failure). Never echoes numbers;
# the caller decides what, if anything, to log.
rpc_post() {
	local suffix="$1" body="$2"
	curl -sS --max-time "$RPC_TIMEOUT" -X POST -H "Content-Type: application/json" \
		--data "$body" "${METALGO_RPC}${suffix}" 2>/dev/null || true
}

# fmt_metal <value> <decimals> — comma-grouped fixed-decimal string.
# python3 (already a hard dependency via reward-calculator.sh) rather than
# awk: awk's doubles cannot be trusted at these magnitudes across the whole
# script, and re-deriving a matching precision policy in awk for every call
# site is more surface area than one shared formatter. Decimal +
# ROUND_HALF_UP (the same rounding reward-calculator.sh uses for nMETAL),
# not float formatting: a float f-string rounds half-to-even on the binary
# value, so 12.25 at one decimal prints "12.2" — a human reading the digest
# expects "12.3". Non-numeric input formats as 0.
fmt_metal() {
	python3 -c "
import sys
from decimal import Decimal, ROUND_HALF_UP, InvalidOperation
v = sys.argv[1]
d = int(sys.argv[2])
try:
    x = Decimal(v)
except InvalidOperation:
    x = Decimal(0)
q = Decimal(1).scaleb(-d)
print(f'{x.quantize(q, rounding=ROUND_HALF_UP):,.{d}f}')
" "$1" "$2"
}

# jst_md_of_epoch <epoch> — "M/D" in JST, no leading zeros (the digest's
# maturity date). GNU `date -d @` vs BSD `date -r` shim, same shape as
# scripts/gen-renewal-ics.sh's epoch_to_fmt; `%-m` is GNU-only so the
# zero-strip is done with sed instead.
if date --version >/dev/null 2>&1; then
	jst_md_of_epoch() { TZ=Asia/Tokyo date -d "@$1" +%m/%d | sed 's#^0##; s#/0#/#'; }
else
	jst_md_of_epoch() { TZ=Asia/Tokyo date -r "$1" +%m/%d | sed 's#^0##; s#/0#/#'; }
fi

# ---- rewards-history.jsonl helpers --------------------------------------
# All readers below go through history_effective_rows: the LAST row per
# cycle_n is the effective one (append-only supersession — see the header's
# "LEDGER SCHEMA v2"). None of them ever echo an amount to this script's
# own stdout/stderr; their output is consumed only by ntfy/digest builders.

# history_has_tx <txID> — true (rc 0) iff ANY line with this
# add_validator_tx exists (v1 or v2). Guards the LIVE path against a
# double-append if the state advance is interrupted between the append and
# the state write. --backfill uses history_effective_line_for_tx instead,
# because it must distinguish "recorded as v1 only" from "recorded as v2".
history_has_tx() {
	local tx="$1"
	[ -f "$REWARDS_HISTORY" ] || return 1
	grep -qF "\"add_validator_tx\":\"${tx}\"" "$REWARDS_HISTORY"
}

# history_effective_rows — prints a JSON array of the effective rows (last
# line per cycle_n, file order decides "last"). [] if the file is absent
# or empty.
history_effective_rows() {
	if [ ! -f "$REWARDS_HISTORY" ] || [ ! -s "$REWARDS_HISTORY" ]; then
		echo "[]"
		return 0
	fi
	jq -sc 'reduce .[] as $r ({}; .[($r.cycle_n | tostring)] = $r) | [.[]]' "$REWARDS_HISTORY"
}

# history_effective_line_for_cycle <cycle_n> — the effective row for that
# cycle_n as one compact JSON object, or empty output if none.
history_effective_line_for_cycle() {
	history_effective_rows | jq -c --argjson cn "$1" '[.[] | select(.cycle_n == $cn)] | last // empty'
}

# history_cumulative_metal — sum of reward_metal over effective rows.
history_cumulative_metal() {
	history_effective_rows | jq '[.[].reward_metal] | add // 0'
}

# history_cumulative_breakdown — prints "<self> <fee> <unknown>" over the
# effective rows: self/fee sum only rows whose split_known is true;
# unknown sums reward_metal of every other effective row (v1 rows, and v2
# rows recorded with split_known:false). self + fee + unknown == the
# cumulative total by construction.
history_cumulative_breakdown() {
	history_effective_rows | jq -r '
		([.[] | select(.split_known == true) | .self_reward_metal] | add // 0) as $s
		| ([.[] | select(.split_known == true) | .fee_income_metal] | add // 0) as $f
		| ([.[] | select(.split_known != true) | .reward_metal] | add // 0) as $u
		| "\($s) \($f) \($u)"'
}

# history_count — number of effective rows (= distinct cycles recorded).
history_count() {
	history_effective_rows | jq 'length'
}

# ---- append one matured-cycle line (shared by live tracking + --backfill)
# append_reward_line <cycle_n> <reward_metal> <self_stake_metal> \
#                     <start_unix> <end_unix> <add_validator_tx> \
#                     <self_reward_metal|-> <fee_income_metal|-> <split_known 0|1>
# The last three come straight from split_reward_utxos_metal's output
# line ("-" = refused → recorded as JSON null with split_known:false).
# Returns 0 iff the line was (or, in dry mode, would be) appended.
append_reward_line() {
	local cn="$1" reward="$2" self_stake="$3" su="$4" eu="$5" tx="$6"
	local self_r="$7" fee_r="$8" known="$9"
	local self_json="null" fee_json="null" known_json="false"
	if [ "$known" = "1" ]; then
		self_json="$self_r"
		fee_json="$fee_r"
		known_json="true"
	fi
	# jq 1.8's decNumber backend renders an exact-zero decimal like
	# "0.000000000" back out as "0E-9" — valid JSON, numerically identical,
	# but inconsistent with every non-zero row's plain decimal form.
	# `if . == 0 then 0 else .` normalizes only the exact-zero case (a real
	# 0-reward cycle — see the header note on why that is a legitimate,
	# non-racy outcome, not a "not yet paid" race) to a plain 0. The same
	# normalization is applied to the v2 halves (null passes through).
	local line
	line=$(jq -nc \
		--argjson cn "$cn" \
		--argjson reward "$reward" \
		--argjson self "$self_stake" \
		--argjson su "$su" \
		--argjson eu "$eu" \
		--arg tx "$tx" \
		--arg obs "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson self_r "$self_json" \
		--argjson fee_r "$fee_json" \
		--argjson known "$known_json" \
		'def z: if . == 0 then 0 else . end;
		 {cycle_n:$cn, reward_metal:($reward|z), self_stake_metal:($self|z), start_unix:$su, end_unix:$eu, add_validator_tx:$tx, observed_at:$obs,
		  schema_version:2, self_reward_metal:($self_r|z), fee_income_metal:($fee_r|z), split_known:$known}')
	printf '%s\n' "$line" | fyd_live_write --append "the matured-cycle reward record" "$REWARDS_HISTORY"
}

# ============================================================================
# non-blocking flock (mirrors check-anomalies.sh's K-4 pattern)
# ============================================================================
# At most one reward-tracker.sh runs concurrently — a slow RPC call (or a
# manual re-run overlapping a cron tick) must not let a second invocation
# interleave reads/writes of reward-tracker-state.json / rewards-
# history.jsonl / reward-digest-line.txt with it. Held for the WHOLE run
# (both --backfill and the normal daily run touch state), released only on
# process exit — same shape as check-anomalies.sh's K-4 lock, minus that
# script's separate operator-run init-script requirement: this subsystem
# has no equivalent to anomaly-state-init.sh, so the lock directory is
# created here rather than assumed pre-provisioned. The lock file itself
# carries no content and is never deleted (flock holds the fd, not the
# directory entry) — same FYD-GATE(exempt) categorization check-
# anomalies.sh uses for its own lock backing file: infrastructure, not
# state, so this mkdir/open is intentionally NOT behind fyd_live_run.
LOCK_DIR="${STATE_DIR}/locks"
# FYD-GATE(exempt): lock-dir infra, no content — see the paragraph above.
mkdir -p "$LOCK_DIR" 2>/dev/null || true
LOCK_FILE="${REWARD_TRACKER_LOCK_FILE:-${LOCK_DIR}/reward-tracker.lock}"
if ! exec 9>"$LOCK_FILE"; then
	echo "reward-tracker: FATAL: cannot open lock file: $LOCK_FILE" >&2
	exit 7
fi
if ! flock -n 9; then
	echo "reward-tracker: previous run still holds the lock ($LOCK_FILE) — skipping this run (exit 0, not an error)" >&2
	exit 0
fi

# ============================================================================
# --backfill mode
# ============================================================================
if [ "$BACKFILL" -eq 1 ]; then
	# Idempotency on the EFFECTIVE row for this cycle_n (see header):
	#   effective row is v2 and carries this txID  -> no-op
	#   effective row is v1 and carries this txID  -> append one v2 row
	#   effective row carries a DIFFERENT txID     -> refuse (exit 6)
	#   no row                                     -> append
	EFFECTIVE_ROW=$(history_effective_line_for_cycle "$BACKFILL_CYCLE_N")
	if [ -n "$EFFECTIVE_ROW" ]; then
		EFFECTIVE_TX=$(echo "$EFFECTIVE_ROW" | jq -r '.add_validator_tx // empty')
		EFFECTIVE_SCHEMA=$(echo "$EFFECTIVE_ROW" | jq -r '.schema_version // 1')
		if [ "$EFFECTIVE_TX" != "$BACKFILL_TX" ]; then
			echo "reward-tracker: ERROR: cycle_n=${BACKFILL_CYCLE_N} is already recorded under a different txID — refusing to append a conflicting row" >&2
			exit 6
		fi
		if [ "$EFFECTIVE_SCHEMA" -ge 2 ] 2>/dev/null; then
			echo "reward-tracker: --backfill txID already recorded as a v2 row, nothing to do (idempotent)" >&2
			exit 0
		fi
		echo "reward-tracker: --backfill effective row is v1 — appending a v2 row with the self/fee split (v1 row left in place)" >&2
	fi
	if [ ! -r "$UPTIME_CYCLES_JSON" ]; then
		echo "reward-tracker: ERROR: uptime-cycles.json not readable at ${UPTIME_CYCLES_JSON}" >&2
		exit 5
	fi
	CYCLE_ROW=$(jq -c --argjson cn "$BACKFILL_CYCLE_N" \
		'[.cycles[]? | select(.cycle_n == $cn)] | last // empty' "$UPTIME_CYCLES_JSON")
	if [ -z "$CYCLE_ROW" ]; then
		echo "reward-tracker: ERROR: cycle_n=${BACKFILL_CYCLE_N} not found in ${UPTIME_CYCLES_JSON}" >&2
		exit 5
	fi
	B_START=$(echo "$CYCLE_ROW" | jq -r '.start_unix')
	B_END=$(echo "$CYCLE_ROW" | jq -r '.end_unix')
	B_SELF_STAKE=$(echo "$CYCLE_ROW" | jq -r '.final_self_stake_metal')

	UTXO_RESP=$(rpc_post "/ext/bc/P" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"platform.getRewardUTXOs\",\"params\":{\"txID\":\"${BACKFILL_TX}\",\"encoding\":\"hex\"}}")
	if [ -z "$UTXO_RESP" ] || ! echo "$UTXO_RESP" | jq -e '.result.utxos' >/dev/null 2>&1; then
		echo "reward-tracker: ERROR: getRewardUTXOs unreachable or unparseable for backfill txID" >&2
		exit 1
	fi
	# No potentialReward hint exists for a historical tx (it is only
	# exposed while the tx is current), so a single-output cycle is
	# recorded with split_known:false here — see reward-utxo-decode.sh.
	read -r B_REWARD B_SELF_R B_FEE_R B_KNOWN <<< "$(echo "$UTXO_RESP" | jq -r '.result.utxos[]?' | split_reward_utxos_metal)"

	if append_reward_line "$BACKFILL_CYCLE_N" "$B_REWARD" "$B_SELF_STAKE" "$B_START" "$B_END" "$BACKFILL_TX" "$B_SELF_R" "$B_FEE_R" "$B_KNOWN"; then
		if fyd_is_live; then
			echo "reward-tracker: backfilled cycle ${BACKFILL_CYCLE_N} (no notification sent — see header)"
		else
			echo "reward-tracker: DRY — would backfill cycle ${BACKFILL_CYCLE_N}"
		fi
		exit 0
	fi
	echo "reward-tracker: ERROR: backfill append failed" >&2
	exit 1
fi

# ============================================================================
# Normal daily run
# ============================================================================

if [ ! -r "$VALIDATOR_JSON" ]; then
	echo "reward-tracker: validator.json not readable, skip this run" >&2
	exit 0
fi
NODE_ID=$(jq -r '.nodeId // empty' "$VALIDATOR_JSON")
if [ -z "$NODE_ID" ]; then
	echo "reward-tracker: validator.json missing nodeId, skip this run" >&2
	exit 0
fi

# Request body built via jq -n --arg (NOT raw string interpolation of
# $NODE_ID into the JSON literal) for two independent reasons: (1) proper
# JSON string escaping — a raw ${NODE_ID} substitution would corrupt the
# request if a node ID ever contained a quote or backslash; (2) it keeps
# tests/field-contracts/test-field-contracts.sh's writer/reader binder from
# tracing $NODE_ID (itself correctly bound to validator.json, since it was
# read from .nodeId two lines above) transitively into $CV_RESP and
# everything derived from it ($SELF_ENTRY, $CURRENT_TX, the delegator
# fields, …) — those are a P-Chain RPC response, not validator.json, and
# mistaking one for the other was reported CRITICAL/HIGH by
# tests/field-contracts/test-field-contracts.sh (coordinator review,
# 2026-09-04). cycle-gate.sh's own getCurrentValidators call avoids this
# because it filters client-side (`jq --arg id "$NODE_ID" 'select(...)'`
# against an UNFILTERED fetch) rather than filtering server-side — this
# script must filter server-side (params.nodeIDs) because that is the only
# way metalgo populates .delegators[] on the response (see this file's own
# header). The checker already exempts jq's OWN --arg option values
# (strip_jq_option_values in check-field-contracts.py, added for
# check-validator.sh's `jq --arg id "$NODE_ID"` pattern); building the curl
# body through the same idiom applies that existing, deliberate exemption
# instead of inventing a new one.
CV_REQ_BODY=$(jq -nc --arg id "$NODE_ID" \
	'{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{"nodeIDs":[$id]}}')
CV_RESP=$(rpc_post "/ext/bc/P" "$CV_REQ_BODY")
if [ -z "$CV_RESP" ] || ! echo "$CV_RESP" | jq -e '.result.validators' >/dev/null 2>&1; then
	echo "reward-tracker: getCurrentValidators unreachable or unparseable, skip this run" >&2
	exit 0
fi
SELF_ENTRY=$(echo "$CV_RESP" | jq -c --arg id "$NODE_ID" '.result.validators[]? | select(.nodeID == $id)')
if [ -z "$SELF_ENTRY" ]; then
	echo "reward-tracker: own nodeID absent from current validators this run, skip (transient gap or between cycles)" >&2
	exit 0
fi

CURRENT_TX=$(echo "$SELF_ENTRY" | jq -r '.txID')
CURRENT_START=$(echo "$SELF_ENTRY" | jq -r '.startTime')
CURRENT_END=$(echo "$SELF_ENTRY" | jq -r '.endTime')
CURRENT_WEIGHT_N=$(echo "$SELF_ENTRY" | jq -r '.weight')
# potentialReward = the exact self reward the commit path will pay (see the
# header's split rationale). Captured on EVERY run (write_state below runs
# on the no-change branch too), so a state file written before this field
# existed self-heals on the next daily tick, well before the tx matures.
CURRENT_POTENTIAL_N=$(echo "$SELF_ENTRY" | jq -r '.potentialReward // empty')

[ -f "$TRACKER_STATE" ] || printf '%s\n' '{}' | fyd_live_write "an empty reward-tracker state" "$TRACKER_STATE"
STATE_JSON=$(cat "$TRACKER_STATE" 2>/dev/null || echo '{}')
TRACKED_TX=$(echo "$STATE_JSON" | jq -r '.tracked_tx // empty')

write_state() {
	jq -nc \
		--arg tx "$CURRENT_TX" \
		--arg nid "$NODE_ID" \
		--argjson su "$CURRENT_START" \
		--argjson eu "$CURRENT_END" \
		--arg w "$CURRENT_WEIGHT_N" \
		--arg pr "$CURRENT_POTENTIAL_N" \
		--arg obs "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{tracked_tx:$tx, tracked_node_id:$nid, tracked_start_unix:$su, tracked_end_unix:$eu, tracked_weight_nmetal:$w, tracked_potential_reward_nmetal:$pr, updated_at:$obs}' \
		| fyd_live_write "the reward-tracker in-flight state" "$TRACKER_STATE"
}

if [ -z "$TRACKED_TX" ] || [ "$TRACKED_TX" = "$CURRENT_TX" ]; then
	# Bootstrap, or same cycle still in flight — nothing matured.
	write_state
	if [ -z "$TRACKED_TX" ]; then
		echo "reward-tracker: bootstrap — now tracking current cycle"
	else
		echo "reward-tracker: no change — current cycle still in flight"
	fi
else
	# tracked_tx != CURRENT_TX: the AddValidatorTx this script was tracking
	# is gone from the current set, replaced by CURRENT_TX. The tracked
	# cycle matured (or was retired). Resolve which cycle_n it was via
	# uptime-cycles.json's most recently CLOSED row, cross-checked by
	# end_unix against what we captured when we started tracking it — see
	# the header's "resolve cycle_n" note. A mismatch means uptime-
	# history.sh has not yet written that cycle's close row (its own daily
	# cron may simply not have run yet today) — defer, do NOT advance state,
	# so this branch retries on the next run instead of losing the event.
	TRACKED_START=$(echo "$STATE_JSON" | jq -r '.tracked_start_unix // empty')
	TRACKED_END=$(echo "$STATE_JSON" | jq -r '.tracked_end_unix // empty')
	TRACKED_WEIGHT_N=$(echo "$STATE_JSON" | jq -r '.tracked_weight_nmetal // empty')
	TRACKED_POTENTIAL_N=$(echo "$STATE_JSON" | jq -r '.tracked_potential_reward_nmetal // empty')

	if [ ! -r "$UPTIME_CYCLES_JSON" ]; then
		echo "reward-tracker: uptime-cycles.json not readable, deferring maturity detection to next run" >&2
	else
		LAST_CLOSED=$(jq -c '.cycles[-1]? // empty' "$UPTIME_CYCLES_JSON")
		LAST_CLOSED_END=$(echo "$LAST_CLOSED" | jq -r '.end_unix // empty' 2>/dev/null)
		if [ -z "$LAST_CLOSED" ] || [ "$LAST_CLOSED_END" != "$TRACKED_END" ]; then
			echo "reward-tracker: uptime-cycles.json last-closed row does not yet match the tracked cycle's end_unix, deferring to next run" >&2
		elif history_has_tx "$TRACKED_TX"; then
			# Already recorded (e.g. a previous run appended but died before
			# advancing state). Advance state now and move on.
			echo "reward-tracker: matured cycle already recorded, advancing tracked state"
			write_state
		else
			CYCLE_N=$(echo "$LAST_CLOSED" | jq -r '.cycle_n')
			SELF_STAKE_METAL=$(awk -v n="$TRACKED_WEIGHT_N" 'BEGIN{printf "%.9f", n/1000000000}')

			UTXO_RESP=$(rpc_post "/ext/bc/P" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"platform.getRewardUTXOs\",\"params\":{\"txID\":\"${TRACKED_TX}\",\"encoding\":\"hex\"}}")
			if [ -z "$UTXO_RESP" ] || ! echo "$UTXO_RESP" | jq -e '.result.utxos' >/dev/null 2>&1; then
				echo "reward-tracker: getRewardUTXOs unreachable or unparseable, deferring to next run" >&2
			else
				# split_reward_utxos_metal prints "<total> <self> <fee> <known>";
				# self/fee are "-" when the split was refused (known=0). The
				# potentialReward hint is what makes a single output decidable —
				# empty (pre-v2 state file) simply means "refuse", never guess.
				read -r REWARD_METAL SELF_REWARD_METAL FEE_INCOME_METAL SPLIT_KNOWN \
					<<< "$(echo "$UTXO_RESP" | jq -r '.result.utxos[]?' | split_reward_utxos_metal "$TRACKED_POTENTIAL_N")"

				if ! append_reward_line "$CYCLE_N" "$REWARD_METAL" "$SELF_STAKE_METAL" "$TRACKED_START" "$TRACKED_END" "$TRACKED_TX" "$SELF_REWARD_METAL" "$FEE_INCOME_METAL" "$SPLIT_KNOWN"; then
					echo "reward-tracker: ERROR: append_reward_line failed, NOT advancing tracked state (will retry next run)" >&2
					exit 1
				fi

				echo "reward-tracker: appended matured cycle record"
				write_state

				# ---- 🎉 / ⚠ notification ------------------------------------
				# Called unconditionally (live or dry): fyd_notify's own
				# FY_LIVE gate decides whether this actually reaches ntfy or
				# prints a "DRY: would notify …" byte-count-only note (see
				# scripts/lib/side-effects.sh) — matching every other
				# side-effecting call in this script, and the "FY_LIVE=1 …
				# dry では DRY: 行" contract from the task brief. Gating this
				# a second time on fyd_is_live here would be redundant (and
				# would suppress the dry note the brief explicitly wants).
				CUM_METAL=$(history_cumulative_metal)
				COUNT=$(history_count)
				NOW_SELF_STAKE=$(jq -r '.stake.self // 0' "$VALIDATOR_JSON")
				MILESTONE_QTY=$(awk -v s="$NOW_SELF_STAKE" -v x="$REWARD_METAL" 'BEGIN{printf "%.9f", s+x}')
				REACHED=$(awk -v q="$MILESTONE_QTY" -v m="$FY_REWARD_MILESTONE" 'BEGIN{print (q>=m)?"1":"0"}')
				REMAIN=$(awk -v q="$MILESTONE_QTY" -v m="$FY_REWARD_MILESTONE" 'BEGIN{v=m-q; if(v<0)v=0; printf "%.2f", v}')

				LINE2_TAIL=""
				if [ "$REACHED" = "1" ]; then
					LINE2_TAIL="$(fmt_metal "$FY_REWARD_MILESTONE" 0) 到達 🎉"
				else
					LINE2_TAIL="$(fmt_metal "$FY_REWARD_MILESTONE" 0) まで残り $(fmt_metal "$REMAIN" 2)"
				fi
				LINE2="${COUNT} cycles · self-stake $(fmt_metal "$RC_MIN_VALIDATOR_STAKE_METAL" 0) → $(fmt_metal "$NOW_SELF_STAKE" 0) · ${LINE2_TAIL}"

				# REWARD_METAL == 0 is NOT a "not yet paid" race: metalgo's
				# rewardValidatorTx() writes the reward UTXOs (zero of them, if
				# the 80% uptime requirement was missed) IN THE SAME onCommitState
				# transition that removes the staker from getCurrentValidators —
				# there is no block where the entry is gone but the reward is
				# still pending, so a same-run getRewardUTXOs read right after
				# detecting the disappearance can never observe a stale zero.
				REWARD_IS_ZERO=$(awk -v r="$REWARD_METAL" 'BEGIN{print (r+0==0)?"1":"0"}')
				# This-cycle breakdown tail (2026-09-07): "自己 +a / 手数料 +b"
				# when the split is known, "内訳不明" when it was refused —
				# the push never shows a guessed half.
				if [ "$SPLIT_KNOWN" = "1" ]; then
					SPLIT_TAIL="自己 +$(fmt_metal "$SELF_REWARD_METAL" 2) / 手数料 +$(fmt_metal "$FEE_INCOME_METAL" 2)"
				else
					SPLIT_TAIL="内訳不明"
				fi
				if [ "$REWARD_IS_ZERO" = "1" ]; then
					# No reward this cycle almost always means the 80% uptime
					# threshold was missed (see StakingConfig.UptimeRequirement in
					# reward-calculator.sh's header citation) — a degraded outcome,
					# not a celebration. Coordinator-decided (2026-09-04 review):
					# no 🎉, no tada tag — omitting --tags lets fyd_notify fall back
					# to the priority-derived default (high → "warning"), matching
					# check-anomalies.sh's own "drop the override, let the default
					# stand" pattern for a non-celebratory high-priority push.
					# Same 累積-first ordering as the >0 branch below (the
					# operator's requirement is cumulative first, regardless
					# of this cycle's outcome — CUM_METAL is computed above,
					# before this fork, from the history that now includes
					# this 0 line). The uptime warning moves into the delta
					# tail so the ordering stays identical across branches.
					# Zero total: 0 outputs is always a KNOWN split (0/0), so the
					# breakdown is spelled with the same bare "+0" the delta
					# uses, not "+0.00" — one visual convention per branch.
					LINE1="Cycle ${CYCLE_N} reward: 累積 $(fmt_metal "$CUM_METAL" 2) METAL (+0 this cycle: 自己 +0 / 手数料 +0 — check uptime)"
					BODY="${LINE1}
${LINE2}"
					fyd_notify high "⚠ Cycle ${CYCLE_N} reward: 0 METAL" "$BODY" >/dev/null
				else
					LINE1="Cycle ${CYCLE_N} reward: 累積 $(fmt_metal "$CUM_METAL" 2) METAL (+$(fmt_metal "$REWARD_METAL" 2) this cycle: ${SPLIT_TAIL})"
					BODY="${LINE1}
${LINE2}"
					# tada tag: unlike check-anomalies.sh's delegation push (which
					# withdraws the celebration when count and amount move opposite
					# ways), a NON-ZERO matured reward has no "net negative" case —
					# reward_metal is always >= 0, and this branch is only reached
					# when it is strictly > 0.
					fyd_notify --tags=tada high "🎉 Cycle ${CYCLE_N} reward matured" "$BODY" >/dev/null
				fi
			fi
		fi
	fi
fi

# ============================================================================
# Morning digest block (regenerated every run, independent of maturity above)
# ============================================================================
# Four lines (2026-09-07 operator format — see the header's STATE section):
#   1  累積 N METAL (自己 a / 手数料 b[ / 内訳不明 c])
#   2  Cycle N 見込み +M METAL (自己 +a / 手数料 +b)
#   3  　M/D 満期・経過 d/D 日            (full-width-space indent)
#   4  25,000 まで残り R  |  25,000 到達 🎉
# Every amount is fmt_metal'd to ONE decimal (the milestone constant itself
# stays a bare integer). Lines 2–3 exist only when the projection could be
# computed this run (cycle_n known, getCurrentSupply answered, calculator
# ran); otherwise the block is lines 1 + 4 with line 4 measured against the
# current self-stake alone — never a fabricated projection.
#
# Day arithmetic: D (cycle length) is ROUNDED to the nearest day —
# int(x + 0.5) — because a 32.97-day cycle is "33 days" to a human (the
# 2026-09-04 int() truncation printed 32); d (elapsed) stays floor'd and
# clamped to [0, D]. The maturity date is end_unix rendered in JST as M/D
# with no leading zeros (jst_md_of_epoch).
compute_and_write_digest() {
	local now_self_stake now_start now_end supply_resp supply_n supply_metal
	local line1 line2="" line3="" line4=""
	local proj_total=""

	now_self_stake=$(jq -r '.stake.self // empty' "$VALIDATOR_JSON")
	now_start="$CURRENT_START"
	now_end="$CURRENT_END"

	if [ -n "$now_self_stake" ] && [ -n "$now_start" ] && [ -n "$now_end" ] \
		&& [ -f "$CURRENT_CYCLE_STATE" ]; then
		local cycle_n_now
		cycle_n_now=$(jq -r '.cycle_n // empty' "$CURRENT_CYCLE_STATE" 2>/dev/null)

		supply_resp=$(rpc_post "/ext/bc/P" '{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentSupply","params":{}}')
		supply_n=$(echo "$supply_resp" | jq -r '.result.supply // empty' 2>/dev/null)

		if [ -n "$cycle_n_now" ] && [ -n "$supply_n" ]; then
			supply_metal=$(awk -v n="$supply_n" 'BEGIN{printf "%.9f", n/1000000000}')
			RC_CURRENT_SUPPLY_METAL="$supply_metal"

			local dur_sec=$((now_end - now_start))
			local self_full
			self_full=$(estimate_reward "$now_self_stake" "$dur_sec" 2>/dev/null) || self_full=""
			if [ -n "$self_full" ]; then
				# ---- fee projection: full-period estimate per delegator ----
				local fee_pct fee_frac fee_full="0"
				fee_pct=$(echo "$SELF_ENTRY" | jq -r '.delegationFee // 0')
				fee_frac=$(awk -v f="$fee_pct" 'BEGIN{printf "%.9f", f/100}')
				local n_del i
				n_del=$(echo "$SELF_ENTRY" | jq -r '.delegators // [] | length')
				i=0
				while [ "$i" -lt "$n_del" ]; do
					local del_w del_su del_eu del_stake del_dur del_full
					del_w=$(echo "$SELF_ENTRY" | jq -r ".delegators[$i].weight")
					del_su=$(echo "$SELF_ENTRY" | jq -r ".delegators[$i].startTime")
					del_eu=$(echo "$SELF_ENTRY" | jq -r ".delegators[$i].endTime")
					del_stake=$(awk -v w="$del_w" -v f="$fee_frac" 'BEGIN{printf "%.9f", (w/1000000000)*f}')
					del_dur=$((del_eu - del_su))
					del_full=$(estimate_reward "$del_stake" "$del_dur" 2>/dev/null) || del_full=""
					if [ -n "$del_full" ]; then
						fee_full=$(awk -v t="$fee_full" -v x="$del_full" 'BEGIN{printf "%.9f", t+x}')
					fi
					i=$((i + 1))
				done
				proj_total=$(awk -v s="$self_full" -v f="$fee_full" 'BEGIN{printf "%.9f", s+f}')

				# ---- days + maturity date ----
				local big_now d_days big_d md
				big_now=$(date -u +%s)
				big_d=$(awk -v s="$now_start" -v e="$now_end" 'BEGIN{v=int((e-s)/86400 + 0.5); if(v<1)v=1; print v}')
				d_days=$(awk -v now="$big_now" -v s="$now_start" -v dd="$big_d" 'BEGIN{v=int((now-s)/86400); if(v<0)v=0; if(v>dd)v=dd; print v}')
				md=$(jst_md_of_epoch "$now_end")

				line2="Cycle ${cycle_n_now} 見込み +$(fmt_metal "$proj_total" 1) METAL (自己 +$(fmt_metal "$self_full" 1) / 手数料 +$(fmt_metal "$fee_full" 1))"
				line3="　${md} 満期・経過 ${d_days}/${big_d} 日"
			fi
		fi
	fi

	# ---- line 1: cumulative with breakdown (effective ledger rows) ----
	local cum cum_self cum_fee cum_unknown unknown_tail=""
	cum=$(history_cumulative_metal)
	read -r cum_self cum_fee cum_unknown <<< "$(history_cumulative_breakdown)"
	if [ "$(awk -v u="$cum_unknown" 'BEGIN{print (u+0>0)?"1":"0"}')" = "1" ]; then
		unknown_tail=" / 内訳不明 $(fmt_metal "$cum_unknown" 1)"
	fi
	line1="累積 $(fmt_metal "$cum" 1) METAL (自己 $(fmt_metal "$cum_self" 1) / 手数料 $(fmt_metal "$cum_fee" 1)${unknown_tail})"

	# ---- line 4: milestone. Against self-stake + full-cycle projection when
	# one exists, against self-stake alone otherwise (fallback, never
	# fabricated). ----
	local base_self milestone_qty reached remain
	base_self=$(jq -r '.stake.self // 0' "$VALIDATOR_JSON")
	milestone_qty=$(awk -v s="$base_self" -v x="${proj_total:-0}" 'BEGIN{printf "%.9f", s+x}')
	reached=$(awk -v q="$milestone_qty" -v m="$FY_REWARD_MILESTONE" 'BEGIN{print (q>=m)?"1":"0"}')
	remain=$(awk -v q="$milestone_qty" -v m="$FY_REWARD_MILESTONE" 'BEGIN{v=m-q; if(v<0)v=0; printf "%.9f", v}')
	if [ "$reached" = "1" ]; then
		line4="$(fmt_metal "$FY_REWARD_MILESTONE" 0) 到達 🎉"
	else
		line4="$(fmt_metal "$FY_REWARD_MILESTONE" 0) まで残り $(fmt_metal "$remain" 1)"
	fi

	# Exactly one trailing newline, no blank lines: the consumer
	# (daily-status.sh) splices every non-empty line as-is.
	if [ -n "$line2" ]; then
		printf '%s\n%s\n%s\n%s\n' "$line1" "$line2" "$line3" "$line4"
	else
		printf '%s\n%s\n' "$line1" "$line4"
	fi | fyd_live_write "the reward digest block" "$DIGEST_FILE"
}

compute_and_write_digest
echo "reward-tracker: digest block updated"
