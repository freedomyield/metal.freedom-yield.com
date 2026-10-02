#!/usr/bin/env bash
# check-anchor-history-reachable.sh — prove, BEFORE an anchor is signed, that
# the receipt step that runs AFTER the irreversible broadcast will be able to
# resolve the transaction and name its chain.
#
# CHAIN: none — READ ONLY. It sends only history/chain READ requests
#        (Hyperion get_actions / get_transaction, /v1/history/get_transaction,
#        /v1/chain/get_block, /v1/chain/get_info) through
#        scripts/lib/anchor-history-read.sh. It never signs, never pushes,
#        never runs proton-cli; tests/anchor-history-read/ greps this file and
#        the library to keep it that way.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast). Its job is to make the
#        broadcast path fail closed EARLIER (plan P3): a history outage or a
#        chain profile that cannot name its chain stops the run before
#        signing, instead of after it.
#
# WHAT IT CHECKS (for the selected chain profile of --chain's role)
#   a. the profile can supply everything scripts/gen-anchor-receipt.sh will
#      need: chain_id (reconciled with FYD_<ROLE>_CHAIN_ID), history_bases
#      (or an allowed --rpc), explorer_base (unless --explorer-base), and the
#      receipt schema choice (v2 only on the role's default profile)
#   b. per history base, in the receipt generator's order: if the base serves
#      /v1/chain/get_info, its chain_id must equal the profile's (a mismatch
#      is exit 4 — an allowlisted base serving another chain); a base that
#      does not serve get_info (Hyperion-only) is reported, not failed
#   c. RESOLUTION, with the receipt generator's own code (ahr_resolve_tx):
#        known-tx mode (preferred): a past anchor on THIS chain — the newest
#          ledger line whose chain_id AND chain_profile are the selected
#          profile's (lines without them count as the legacy xpr-* profile of
#          their network) or --known-tx — must resolve with >= 1 action,
#          block_num and block_time, and (v3) a block_id
#        liveness mode (no such anchor yet, e.g. the first anchor on a new
#          chain, or testnet): Hyperion get_actions for the signing account
#          must answer; for v3 the newest action (if any) must carry a
#          block_id or the base must serve get_block for it
#      The FIRST base (profile order) that resolves decides, exactly as in the
#      receipt generator; the check passes only if that base is fully OK.
#
# Usage:
#   check-anchor-history-reachable.sh --chain=<mainnet-a|testnet-a|proton|proton-test|xpr-mainnet|xpr-testnet>
#       [--rpc=<history base>] [--allow-unlisted-rpc]   (as gen-anchor-receipt.sh)
#       [--receipt-schema=<v2|v3>]                      (as gen-anchor-receipt.sh)
#       [--explorer-base=<url>]                         (as gen-anchor-receipt.sh)
#       [--actor=<account>]    default: first line of $FY_CONFIG_DIR/xpr-account
#                              (FY_CONFIG_DIR default /etc/freedom-yield) — the
#                              same file sign-anchor-event.sh reads
#       [--ledger=<path>]      default: $FYD_HISTORY_FILE, else
#                              public/api/anchor-history.jsonl
#       [--known-tx=<64hex|none>]  none = force liveness mode
#
# Exit codes:
#   0  reachable — the receipt step will be able to run (stdout: one
#      "REACHABLE ..." line)
#   1  usage / arg error (bad flag, --rpc refused, no actor for liveness mode,
#      unreadable ledger)
#   2  the chain profile cannot supply what the receipt needs (e.g. a
#      pulsevm-* profile with chain_id / history_bases / explorer_base not yet
#      published, or FYD_<ROLE>_CHAIN_ID disagreeing with it)
#   3  not reachable: no history base resolved, or the deciding base cannot
#      supply a field the receipt requires
#   4  an allowlisted history base reports a different chain_id

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CHAIN=""
RPC_OVERRIDE=""
ALLOW_UNLISTED_RPC=0
RECEIPT_SCHEMA=""
EXPLORER_OVERRIDE=""
ACTOR=""
LEDGER="${FYD_HISTORY_FILE:-${REPO_ROOT}/public/api/anchor-history.jsonl}"
KNOWN_TX=""

for arg in "$@"; do
	case "$arg" in
		--chain=*)              CHAIN="${arg#*=}" ;;
		--rpc=*)                RPC_OVERRIDE="${arg#*=}" ;;
		--allow-unlisted-rpc)   ALLOW_UNLISTED_RPC=1 ;;
		--receipt-schema=*)     RECEIPT_SCHEMA="${arg#*=}" ;;
		--explorer-base=*)      EXPLORER_OVERRIDE="${arg#*=}" ;;
		--actor=*)              ACTOR="${arg#*=}" ;;
		--ledger=*)             LEDGER="${arg#*=}" ;;
		--known-tx=*)           KNOWN_TX="${arg#*=}" ;;
		-h|--help)              sed -n '2,64p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)                      echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

LOG() { printf '[history-reachable] %s\n' "$*" >&2; }

[ -n "$CHAIN" ] || { echo "ERROR: --chain=<mainnet-a|testnet-a|...> required" >&2; exit 1; }
case "$KNOWN_TX" in
	""|none) ;;
	*) printf '%s' "$KNOWN_TX" | grep -Eq '^[a-f0-9]{64}$' \
		|| { echo "ERROR: --known-tx must be 64 lowercase hex or 'none', got: $KNOWN_TX" >&2; exit 1; } ;;
esac
if [ -n "$ACTOR" ] && ! printf '%s' "$ACTOR" | grep -Eq '^[a-z1-5.]{1,12}$'; then
	echo "ERROR: --actor is not an account name: $ACTOR" >&2
	exit 1
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
	echo "ERROR: jq + curl required" >&2
	exit 1
fi

for lib in a-chain-profile.sh anchor-history-read.sh; do
	[ -r "${REPO_ROOT}/scripts/lib/${lib}" ] \
		|| { echo "ERROR (2): required library not readable: scripts/lib/${lib}" >&2; exit 2; }
done
# shellcheck source=scripts/lib/a-chain-profile.sh
. "${REPO_ROOT}/scripts/lib/a-chain-profile.sh" || { echo "ERROR (2): cannot load a-chain-profile.sh" >&2; exit 2; }
# shellcheck source=scripts/lib/anchor-history-read.sh
. "${REPO_ROOT}/scripts/lib/anchor-history-read.sh"

# ---- a. the profile can supply what the receipt needs ---------------------
ROLE="$(acp_role_of_chain "$CHAIN")" || { echo "ERROR: unknown --chain: $CHAIN" >&2; exit 1; }
PROFILE="$(acp_profile_name "$ROLE")" \
	|| { echo "ERROR (2): no usable A-Chain profile for role $ROLE" >&2; exit 2; }
CHAIN_ID="$(acp_expected_chain_id "$ROLE")" \
	|| { echo "ERROR (2): profile $PROFILE has no usable chain_id — the receipt could not name its chain; do NOT sign" >&2; exit 2; }
if [ "$ROLE" = "mainnet" ]; then DEFAULT_PROFILE="$ACP_DEFAULT_MAINNET"; else DEFAULT_PROFILE="$ACP_DEFAULT_TESTNET"; fi
case "$RECEIPT_SCHEMA" in
	"") if [ "$PROFILE" = "$DEFAULT_PROFILE" ]; then RECEIPT_SCHEMA=v2; else RECEIPT_SCHEMA=v3; fi ;;
	v2) [ "$PROFILE" = "$DEFAULT_PROFILE" ] \
		|| { echo "ERROR: --receipt-schema=v2 is refused for non-default profile $PROFILE (the receipt step would refuse it too)" >&2; exit 1; } ;;
	v3) ;;
	*) echo "ERROR: --receipt-schema must be v2 or v3, got: $RECEIPT_SCHEMA" >&2; exit 1 ;;
esac
if [ -z "$EXPLORER_OVERRIDE" ]; then
	acp_explorer_base "$ROLE" >/dev/null \
		|| { echo "ERROR (2): profile $PROFILE has no explorer_base (the receipt step would refuse); pass --explorer-base to both steps" >&2; exit 2; }
fi
if BASES="$(ahr_select_bases "$ROLE" "$RPC_OVERRIDE" "$ALLOW_UNLISTED_RPC")"; then :; else
	rc=$?
	if [ "$rc" -eq 1 ]; then exit 1; fi
	echo "ERROR (2): profile $PROFILE has no history_bases" >&2
	exit 2
fi
LOG "profile=$PROFILE role=$ROLE chain_id=$CHAIN_ID receipt_schema=$RECEIPT_SCHEMA bases=$(printf '%s' "$BASES" | tr '\n' ' ')"

# ---- which past anchor proves resolution on THIS chain? -------------------
KNOWN_ACTOR=""
if [ "$KNOWN_TX" = "none" ]; then
	KNOWN_TX=""
	LOG "WARNING: --known-tx=none — liveness mode forced by the operator"
elif [ -z "$KNOWN_TX" ] && [ -s "$LEDGER" ]; then
	LEG_M="$(FYD_A_CHAIN_PROFILE_MAINNET="$ACP_DEFAULT_MAINNET" acp_chain_id mainnet)" || exit 2
	LEG_T="$(FYD_A_CHAIN_PROFILE_TESTNET="$ACP_DEFAULT_TESTNET" acp_chain_id testnet)" || exit 2
	if ! PICK="$(jq -rs --arg cid "$CHAIN_ID" --arg prof "$PROFILE" \
			--arg lm "$LEG_M" --arg lt "$LEG_T" \
			--arg dm "$ACP_DEFAULT_MAINNET" --arg dt "$ACP_DEFAULT_TESTNET" '
			map(. as $l
				| (($l.network == "testnet-a") or ($l.network == "xpr-testnet")) as $t
				| select(($l.chain_id // (if $t then $lt else $lm end)) == $cid
					and ($l.chain_profile // (if $t then $dt else $dm end)) == $prof
					and ($l.tx_id | type == "string")))
			| last // empty | "\(.tx_id) \(.signing_actor // "")"' "$LEDGER" 2>/dev/null)"; then
		echo "ERROR: cannot parse the anchor ledger $LEDGER" >&2
		exit 1
	fi
	if [ -n "$PICK" ]; then
		KNOWN_TX="${PICK%% *}"
		KNOWN_ACTOR="${PICK#* }"
	fi
fi
if [ -z "$ACTOR" ]; then
	CFG_ACTOR_FILE="${FY_CONFIG_DIR:-/etc/freedom-yield}/xpr-account"
	if [ -r "$CFG_ACTOR_FILE" ]; then
		ACTOR="$(head -n 1 "$CFG_ACTOR_FILE" | tr -d '[:space:]')"
		printf '%s' "$ACTOR" | grep -Eq '^[a-z1-5.]{1,12}$' || ACTOR=""
	fi
fi
[ -n "$KNOWN_ACTOR" ] || KNOWN_ACTOR="$ACTOR"
if [ -n "$KNOWN_TX" ]; then
	MODE="known-tx"
	LOG "mode=known-tx tx=$KNOWN_TX (a past anchor on this chain)"
else
	MODE="liveness"
	[ -n "$ACTOR" ] || { echo "ERROR: no past anchor on chain $CHAIN_ID in $LEDGER and no --actor (nor readable \$FY_CONFIG_DIR/xpr-account): nothing to probe with" >&2; exit 1; }
	LOG "mode=liveness actor=$ACTOR (no past anchor on this chain/profile in the ledger)"
fi

# ---- b + c. per base, in the receipt generator's order ---------------------
need_block_id() { [ "$RECEIPT_SCHEMA" = "v3" ]; }

for base in $BASES; do
	if OBS="$(ahr_observed_chain_id "$base")"; then
		if [ "$OBS" != "$CHAIN_ID" ]; then
			echo "ERROR (4): $base reports chain_id $OBS, profile $PROFILE says $CHAIN_ID — do NOT sign" >&2
			exit 4
		fi
		LOG "$base: get_info chain_id matches"
	else
		LOG "$base: get_info not served (Hyperion-only base) — chain binding rests on the profile allowlist"
	fi

	if [ "$MODE" = "known-tx" ]; then
		if ! TXJ="$(ahr_resolve_tx "$base" "$KNOWN_TX" "$KNOWN_ACTOR")"; then
			LOG "$base: known tx NOT resolvable — trying next base"
			continue
		fi
		BN="$(printf '%s' "$TXJ" | jq -r '.block_num // empty')"
		BT="$(printf '%s' "$TXJ" | jq -r '.block_time // empty')"
		BID="$(printf '%s' "$TXJ" | jq -r '.block_id // empty')"
		if [ -z "$BN" ] || [ -z "$BT" ]; then
			echo "ERROR (3): $base resolved the known tx but without block_num/block_time — the receipt's gate 7 would fail" >&2
			exit 3
		fi
		[ -n "$BID" ] || BID="$(ahr_block_id "$base" "$BN" || true)"
	else
		if ! PROBE="$(ahr_probe_actions "$base" "$ACTOR")"; then
			LOG "$base: get_actions liveness probe failed — trying next base"
			continue
		fi
		BN="$(printf '%s' "$PROBE" | jq -r '.block_num // empty')"
		BID="$(printf '%s' "$PROBE" | jq -r '.block_id // empty')"
		if [ -n "$BN" ] && [ -z "$BID" ]; then
			BID="$(ahr_block_id "$base" "$BN" || true)"
		fi
		if [ -z "$BN" ]; then
			LOG "$base: account $ACTOR has no action yet — block_id service not provable here"
			BID="unprovable"
		fi
	fi

	if [ -z "$BID" ]; then
		if need_block_id; then
			echo "ERROR (3): $base serves no block_id (history nor get_block) — a v3 receipt would fail after the broadcast; do NOT sign" >&2
			exit 3
		fi
		LOG "WARNING: $base serves no block_id — the v2 receipt will omit it"
	fi
	echo "REACHABLE profile=$PROFILE chain_id=$CHAIN_ID base=$base mode=$MODE receipt_schema=$RECEIPT_SCHEMA"
	exit 0
done

echo "ERROR (3): no history base of profile $PROFILE passed ($MODE mode): $(printf '%s' "$BASES" | tr '\n' ' ')— the receipt step would fail after the broadcast; do NOT sign" >&2
exit 3
