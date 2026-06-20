#!/usr/bin/env bash
# sign-anchor-event.sh — Phase α A-chain anchor signer (C2→C3 T-8).
#
# Called by scripts/post-anchor-event.sh (= C1 T-11) when a validator
# transition is detected (cycle start / cycle end / identity rotation).
# Builds, signs, and broadcasts the Metal A-chain (= XPRNetwork)
# inscription that anchors the current dag_root_hash; emits a minimal
# JSON receipt fragment that the caller consumes to assemble the public
# /api/anchor-receipt.json.
#
# Phase α uses the cheapest form: eosio.token::transfer signed by
# freedomyield@anchor, with the memo "fyid1:<dag_root_hash>". Phase β
# replaces this with a freedomyield::inscribe smart-contract action
# (see scripts/operator-local/contract/freedomyield-anchor.spec.md).
# This script handles Phase α only; the Phase β path is left as a
# documented hook below and is owned by Phase β implementation work.
#
# Authority chain:
#   ed25519 operator identity key (Mac) → signed /api/identity.json
#     → carries dag_root_hash
#       → freedomyield@anchor (validator host, K1 via proton-cli)
#         → eosio.token::transfer memo = fyid1:<dag_root_hash>
#           → on-chain receipt = /api/anchor-receipt.json
#
# Constitution alignment:
#   - §2 #1 validator health is unaffected: this script runs in a
#     subshell on the validator host but performs no blocking I/O
#     against metalgo, does not write to metalgo's data dir, and
#     fails closed (= no inscription is silently skipped without an
#     stderr line that the cron wrapper will surface).
#   - §3.3 operational: anchor private key path /etc/freedom-yield/
#     anchor.k1.key requires mode 0600 owned deploy:deploy (= per
#     docs/OPERATOR_IDENTITY_SETUP.md §B1).
#   - §4.1 secrets: the anchor private key value is never printed,
#     never logged, never echoed. The script reads it via proton-cli
#     keystore (= pre-imported in §B4), not by re-reading the file.
#   - §5: this script ships in scripts/ for validator-host execution;
#     deployment to the validator host is operator-approved.
#
# Exit codes:
#   0  success — JSON receipt fragment on stdout
#   1  usage error (bad args)
#   2  config missing (sink / network / key not configured)
#   3  proton-cli not installed or wrong version
#   4  broadcast failure (network / chain rejected the action)
#   5  receipt parse failure (proton-cli output shape unexpected)
#
# Usage:
#   sign-anchor-event.sh <event_type> <dag_root_hash> [--dry-run]
#     event_type     = cyclestart | cycleend | idrotate
#     dag_root_hash  = 64 lowercase hex chars
#     --dry-run      = compose and validate the action but do not broadcast.
#                      Useful for the §B5 self-test and for the C2→C3 T-9
#                      testnet rehearsal.
#
# Environment / config files (validator-host conventions, /etc/freedom-yield/):
#   anchor.k1.key      private key for ${XPR_ACCOUNT}@anchor, mode 0600
#                      deploy:deploy (= T-7 §B3 deploy artifact). Not re-read
#                      here; proton-cli keystore (§B4) holds the working copy.
#   xpr-account        single-line file containing the operator-controlled XPR
#                      account name that holds the anchor permission AND
#                      sources the eosio.token::transfer broadcast. NO default
#                      — the script fails closed if the file is missing, empty,
#                      multi-line, has invalid characters, or is longer than
#                      12 chars (per audit-C/F-E2). The literal "freedomyield"
#                      fallback was removed because the same script runs the
#                      testnet rehearsal with a throwaway test account.
#                      Mainnet: contains 'freedomyield'.
#                      Testnet: contains the rehearsal test account name
#                      (see docs/PHASE_ALPHA_TESTNET_DRY_RUN.md).
#   anchor-sink        single-line file containing the sink account name (= the
#                      receiver of the eosio.token::transfer; required because
#                      eosio.token rejects self-transfer per BLOCK-1). Operator-
#                      chosen account name, matches XPR pattern ^[a-z1-5.]{1,12}$.
#                      MUST NOT equal the value of xpr-account.
#   xpr-chain          single-line file containing "proton" (mainnet) or
#                      "proton-test" (testnet). Default: "proton". Selecting
#                      proton-test routes broadcasts to the testnet RPC, used by
#                      the T-9 dry-run rehearsal.
#   xpr-quantity       single-line file containing the transfer quantity in
#                      EOSIO asset form, e.g. "0.0001 XPR". Default:
#                      "0.0001 XPR".
#
# JSON receipt fragment on stdout (caller embeds into anchor-receipt.json):
#   {
#     "tx_id": "<64-hex>",
#     "block_num": <int>,
#     "block_time": "<RFC3339 UTC>",
#     "chain": "metal-a-chain",
#     "network": "xpr-mainnet" | "xpr-testnet",
#     "method": "phase_alpha_token_transfer",
#     "memo": "fyid1:<dag_root_hash>",
#     "inscribe_action": {
#       "account": "eosio.token",
#       "name": "transfer",
#       "from": "freedomyield",
#       "to": "<sink>",
#       "quantity": "<quantity>",
#       "memo": "fyid1:<dag_root_hash>",
#       "permission": {"actor": "freedomyield", "permission": "anchor"}
#     }
#   }

set -euo pipefail

# -------- arg parsing --------
DRY_RUN=0
EVENT_TYPE=""
DAG_ROOT=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1; shift ;;
		--help|-h)
			sed -n '1,/^set -euo pipefail$/p' "$0" >&2
			exit 0
			;;
		-*) echo "ERROR: unknown flag $1" >&2; exit 1 ;;
		*)
			if [ -z "${EVENT_TYPE}" ]; then EVENT_TYPE="$1"
			elif [ -z "${DAG_ROOT}" ];     then DAG_ROOT="$1"
			else echo "ERROR: extra positional arg $1" >&2; exit 1; fi
			shift
			;;
	esac
done

if [ -z "${EVENT_TYPE}" ] || [ -z "${DAG_ROOT}" ]; then
	echo "ERROR: usage: $0 <event_type> <dag_root_hash> [--dry-run]" >&2
	exit 1
fi

case "${EVENT_TYPE}" in
	cyclestart|cycleend|idrotate) ;;
	*)
		echo "ERROR: event_type must be cyclestart|cycleend|idrotate, got '${EVENT_TYPE}'" >&2
		exit 1
		;;
esac

case "${DAG_ROOT}" in
	*[!a-f0-9]*|"")
		echo "ERROR: dag_root_hash must be 64 lowercase hex chars, got '${DAG_ROOT}'" >&2
		exit 1
		;;
esac
if [ "${#DAG_ROOT}" -ne 64 ]; then
	echo "ERROR: dag_root_hash must be exactly 64 chars (got ${#DAG_ROOT})" >&2
	exit 1
fi

# -------- config --------
CONFIG_DIR="${FY_CONFIG_DIR:-/etc/freedom-yield}"

read_config() {
	local key="$1" default="${2:-}"
	local path="${CONFIG_DIR}/${key}"
	if [ -r "${path}" ]; then
		# tr -d to strip trailing newlines / whitespace
		tr -d '\n\r\t ' < "${path}"
	elif [ -n "${default}" ]; then
		printf '%s' "${default}"
	else
		echo "ERROR: required config ${path} missing or unreadable" >&2
		exit 2
	fi
}

# XPR_ACCOUNT — operator-controlled account name. Strict, no default.
# Per audit-C/F-E2 the literal 'freedomyield' fallback was removed so that
# the same script runs both mainnet and testnet rehearsal without the
# rehearsal accidentally broadcasting from the production account.
XPR_ACCOUNT_FILE="${CONFIG_DIR}/xpr-account"
if [ ! -r "${XPR_ACCOUNT_FILE}" ]; then
	echo "ERROR: required config ${XPR_ACCOUNT_FILE} missing or unreadable" >&2
	exit 2
fi
XPR_ACCOUNT_LINES="$(wc -l < "${XPR_ACCOUNT_FILE}" | tr -d ' ')"
# Allow exactly 0 newlines (= single-line file ending without LF) OR
# exactly 1 newline (= single line with trailing LF). Reject ≥2 newlines.
case "${XPR_ACCOUNT_LINES}" in
	0|1) ;;
	*)
		echo "ERROR: ${XPR_ACCOUNT_FILE} must contain exactly one line (got ${XPR_ACCOUNT_LINES} newlines)" >&2; exit 2 ;;
esac
XPR_ACCOUNT="$(head -n 1 "${XPR_ACCOUNT_FILE}" | tr -d '\r\n\t ')"
if [ -z "${XPR_ACCOUNT}" ]; then
	echo "ERROR: ${XPR_ACCOUNT_FILE} is empty (or whitespace only)" >&2; exit 2
fi
# Validate the XPR account name char-set with an LC_ALL=C-safe tr-based
# check. The shell case-statement pattern `*[!a-z1-5.]*` is locale-
# dependent: under en_US.UTF-8 / ja_JP.UTF-8 it collation-matches
# uppercase letters via a-z, silently letting 'FreeDomYield' through.
# Using `LC_ALL=C tr -d` guarantees ASCII-only character class semantics.
XPR_ACCOUNT_ILLEGAL="$(printf '%s' "${XPR_ACCOUNT}" | LC_ALL=C tr -d 'a-z1-5.')"
if [ -n "${XPR_ACCOUNT_ILLEGAL}" ]; then
	echo "ERROR: xpr-account '${XPR_ACCOUNT}' contains characters outside [a-z1-5.] (XPR account pattern); illegal chars: '${XPR_ACCOUNT_ILLEGAL}'" >&2; exit 2
fi
if [ "${#XPR_ACCOUNT}" -lt 1 ] || [ "${#XPR_ACCOUNT}" -gt 12 ]; then
	echo "ERROR: xpr-account length must be 1..12 chars (got ${#XPR_ACCOUNT})" >&2; exit 2
fi

SINK="$(read_config anchor-sink)"
CHAIN="$(read_config xpr-chain proton)"
# xpr-quantity: optional config file in CONFIG_DIR. Default "0.0001 XPR".
# Read the raw first line, preserving the internal space in the EOSIO asset
# form (e.g. "0.0001 XPR"); strip trailing whitespace only. read_config is
# not used here because it would strip the internal space.
if [ -r "${CONFIG_DIR}/xpr-quantity" ]; then
	QUANTITY="$(head -n 1 "${CONFIG_DIR}/xpr-quantity" | sed -e 's/[[:space:]]*$//')"
else
	QUANTITY="0.0001 XPR"
fi

if [ -z "${SINK}" ]; then
	echo "ERROR: sink is empty" >&2; exit 2
fi
# Locale-safe ASCII char-class validation (see XPR_ACCOUNT for rationale).
SINK_ILLEGAL="$(printf '%s' "${SINK}" | LC_ALL=C tr -d 'a-z1-5.')"
if [ -n "${SINK_ILLEGAL}" ]; then
	echo "ERROR: sink '${SINK}' does not match XPR account pattern ^[a-z1-5.]{1,12}$; illegal chars: '${SINK_ILLEGAL}'" >&2; exit 2
fi
if [ "${#SINK}" -lt 1 ] || [ "${#SINK}" -gt 12 ]; then
	echo "ERROR: sink length must be 1..12 chars (got ${#SINK})" >&2; exit 2
fi
if [ "${SINK}" = "${XPR_ACCOUNT}" ]; then
	echo "ERROR: sink MUST NOT equal xpr-account ('${XPR_ACCOUNT}') — eosio.token::transfer rejects self-transfer at contract level (BLOCK-1, eosio.token.cpp L99 'cannot transfer to self')" >&2; exit 2
fi

case "${CHAIN}" in
	proton)      NETWORK_TAG="xpr-mainnet" ;;
	proton-test) NETWORK_TAG="xpr-testnet" ;;
	*) echo "ERROR: xpr-chain must be 'proton' or 'proton-test', got '${CHAIN}'" >&2; exit 2 ;;
esac

# -------- proton-cli --------
if ! command -v proton >/dev/null 2>&1; then
	echo "ERROR: proton-cli not installed (PATH=${PATH})" >&2
	exit 3
fi

# -------- build action --------
MEMO="fyid1:${DAG_ROOT}"
ACTION_DATA_JSON="$(jq -nc \
	--arg from "${XPR_ACCOUNT}" \
	--arg to   "${SINK}" \
	--arg qty  "${QUANTITY}" \
	--arg memo "${MEMO}" \
	'{from: $from, to: $to, quantity: $qty, memo: $memo}')"

# Switch chain context. Idempotent.
proton chain:set "${CHAIN}" >/dev/null 2>&1 || true

# -------- broadcast --------
BROADCAST_OUT="$(mktemp -t signanchor.XXXXXX)"
BROADCAST_ERR="$(mktemp -t signanchor.XXXXXX)"
trap 'rm -f "${BROADCAST_OUT}" "${BROADCAST_ERR}"' EXIT

PROTON_ARGS=(action eosio.token transfer "${ACTION_DATA_JSON}" "${XPR_ACCOUNT}@anchor")
if [ "${DRY_RUN}" -eq 1 ]; then
	PROTON_ARGS+=(--dry-run)
fi

if ! proton "${PROTON_ARGS[@]}" > "${BROADCAST_OUT}" 2> "${BROADCAST_ERR}"; then
	echo "ERROR: proton broadcast failed (exit non-zero)" >&2
	echo "ERROR stderr (truncated to 20 lines):" >&2
	tail -n 20 "${BROADCAST_ERR}" >&2
	exit 4
fi

# -------- extract tx_id --------
# proton-cli prints a line containing the transaction id; the format varies
# slightly across versions. Try several patterns. If --dry-run we expect no
# tx_id (the action is not broadcast) and emit a sentinel.
if [ "${DRY_RUN}" -eq 1 ]; then
	TX_ID="dry-run-no-broadcast"
	BLOCK_NUM=0
	BLOCK_TIME="1970-01-01T00:00:00Z"
else
	# Try patterns in order:
	#  - "transaction_id: <64-hex>"
	#  - "transaction id: <64-hex>"
	#  - JSON output: '"transaction_id":"<64-hex>"'
	#  - Bare 64-hex on a line by itself (last-resort)
	TX_ID="$(
		grep -oE 'transaction[_ ]id["[:space:]:]+[a-f0-9]{64}' "${BROADCAST_OUT}" \
			| head -n 1 \
			| grep -oE '[a-f0-9]{64}' \
			| head -n 1
	)"
	if [ -z "${TX_ID}" ]; then
		TX_ID="$(grep -oE '^[a-f0-9]{64}$' "${BROADCAST_OUT}" | head -n 1 || true)"
	fi
	if [ -z "${TX_ID}" ]; then
		echo "ERROR: could not extract tx_id from proton-cli output" >&2
		echo "ERROR stdout (truncated to 20 lines):" >&2
		tail -n 20 "${BROADCAST_OUT}" >&2
		exit 5
	fi

	# Follow up: query the chain for block_num + block_time. If proton-cli
	# does not have a stable get_transaction subcommand we fall back to the
	# RPC endpoint via curl. Both paths are documented; the operator picks
	# whichever works for their proton-cli version.
	if proton --help 2>&1 | grep -q 'get_transaction\|get:transaction'; then
		BLOCK_NUM="$(proton get_transaction "${TX_ID}" 2>/dev/null \
			| grep -oE '"block_num":[[:space:]]*[0-9]+' \
			| head -n 1 \
			| grep -oE '[0-9]+' || true)"
		BLOCK_TIME="$(proton get_transaction "${TX_ID}" 2>/dev/null \
			| grep -oE '"block_time":[[:space:]]*"[^"]*"' \
			| head -n 1 \
			| sed -E 's/.*"([^"]*)"/\1/' || true)"
	fi
	# Fallback: query a public XPR mainnet RPC. (Endpoint pinning is operator
	# preference; we use the documented one from docs/OPERATOR_IDENTITY_SETUP.md A8.)
	if [ -z "${BLOCK_NUM:-}" ] || [ -z "${BLOCK_TIME:-}" ]; then
		RPC_BASE="${XPR_RPC_BASE:-https://api-xprnetwork-main.saltant.io}"
		[ "${CHAIN}" = "proton-test" ] && RPC_BASE="${XPR_RPC_BASE:-https://api-xprnetwork-test.saltant.io}"
		RPC_OUT="$(curl -sSf -X POST -H 'Content-Type: application/json' \
			--data "$(jq -nc --arg id "${TX_ID}" '{id: $id}')" \
			"${RPC_BASE}/v1/history/get_transaction" 2>/dev/null || echo '{}')"
		BLOCK_NUM="${BLOCK_NUM:-$(printf '%s' "${RPC_OUT}" | jq -r '.block_num // empty')}"
		BLOCK_TIME="${BLOCK_TIME:-$(printf '%s' "${RPC_OUT}" | jq -r '.block_time // empty')}"
	fi
	# Fail-closed per audit-C/F-E4: if EITHER block_num OR block_time
	# is unobtainable from on-chain sources after BOTH proton-cli
	# get_transaction AND the RPC fallback have been tried, we MUST
	# NOT fabricate the value from the local clock — doing so would
	# publish a receipt whose block_time is operator-derived rather
	# than chain-derived, falsely implying on-chain confirmation. The
	# audit requires that the receipt be withheld and the state file
	# NOT updated; the caller (= scripts/post-anchor-event.sh) will
	# inherit the non-zero exit and retry on the next cron tick.
	#
	# (If the operator separately needs to record the operator clock
	# at observation time, that goes in a distinct `observed_at` field
	# — never inside block_time. The schema would need an additive
	# extension for that; not done here.)
	if [ -z "${BLOCK_NUM:-}" ]; then
		echo "ERROR: block_num could not be derived from proton-cli get_transaction or RPC fallback for tx_id=${TX_ID}." >&2
		echo "ERROR: receipt withheld (= no partial publish, no state update). Retry next tick." >&2
		exit 4
	fi
	case "${BLOCK_NUM}" in
		*[!0-9]*) echo "ERROR: derived block_num is non-numeric: ${BLOCK_NUM}" >&2; exit 4 ;;
	esac

	if [ -z "${BLOCK_TIME:-}" ]; then
		echo "ERROR: block_time could not be derived from proton-cli get_transaction or RPC fallback for tx_id=${TX_ID}." >&2
		echo "ERROR: receipt withheld (= no local-clock fabrication, no partial publish, no state update). Retry next tick." >&2
		exit 4
	fi
	# Normalize block_time to RFC3339 UTC with a 'Z' suffix when the chain
	# returned a non-Z-terminated form. The value MUST have originated
	# from the chain (= the only way we got past the empty-check above).
	case "${BLOCK_TIME}" in
		*Z) ;;
		*)  BLOCK_TIME="${BLOCK_TIME}Z" ;;
	esac
fi

# -------- emit receipt fragment --------
jq -n \
	--arg tx_id        "${TX_ID}" \
	--argjson block_num "${BLOCK_NUM}" \
	--arg block_time   "${BLOCK_TIME}" \
	--arg network_tag  "${NETWORK_TAG}" \
	--arg memo         "${MEMO}" \
	--arg sink         "${SINK}" \
	--arg quantity     "${QUANTITY}" \
	--arg xpr_account  "${XPR_ACCOUNT}" \
	'{
		tx_id: $tx_id,
		block_num: $block_num,
		block_time: $block_time,
		chain: "metal-a-chain",
		network: $network_tag,
		method: "phase_alpha_token_transfer",
		memo: $memo,
		inscribe_action: {
			account: "eosio.token",
			name: "transfer",
			from: $xpr_account,
			to: $sink,
			quantity: $quantity,
			memo: $memo,
			permission: {actor: $xpr_account, permission: "anchor"}
		}
	}'
