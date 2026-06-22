#!/usr/bin/env bash
# Stub signer for tests/post-anchor-event/. Emits a synthetic receipt
# fragment matching the shape of sign-anchor-event.sh's stdout without
# touching proton-cli, the network, or any key material. The stub
# IGNORES --dry-run because in test context the entire signer is a stub
# anyway.
#
# Invoked as: stub-signer.sh <event_type> <dag_root_hash> [--dry-run]
set -euo pipefail

EVENT_TYPE="${1:-cyclestart}"
DAG_ROOT="${2:-0000000000000000000000000000000000000000000000000000000000000000}"

jq -n --arg dag "${DAG_ROOT}" '{
	tx_id: "abc1230000000000000000000000000000000000000000000000000000000000",
	block_num: 1,
	block_time: "1970-01-01T00:00:00Z",
	chain: "metal-a-chain",
	network: "xpr-testnet",
	method: "phase_alpha_token_transfer",
	memo: ("fyid1:" + $dag),
	inscribe_action: {
		account: "eosio.token",
		name: "transfer",
		from: "metalfreedom",
		to: "fyhistory",
		quantity: "0.0001 XPR",
		memo: ("fyid1:" + $dag),
		permission: {actor: "metalfreedom", permission: "anchor"}
	}
}'
