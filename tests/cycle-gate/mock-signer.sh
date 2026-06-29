#!/usr/bin/env bash
# tests/cycle-gate/mock-signer.sh — stub for sign-anchor-event.sh used by
# post-anchor-event.sh tests (= ANCHOR_SIGNER env override target).
#
# Emits a synthetic signer fragment JSON whose shape passes the AJV validation
# in post-anchor-event.sh (= anchor-receipt.schema.v1.json). Used to test
# post-anchor-event.sh's signer-orchestration path without invoking real
# proton-cli broadcast.
#
# Args (passed by post-anchor-event.sh):
#   $1  event_type (= cyclestart | cycleend | idrotate)
#   $2  dag_root_hash (= 64-hex)
#   [$3 --dry-run]
#
# Behavior controlled by env:
#   MOCK_SIGNER_EXIT      desired exit code (default 0)
#   MOCK_SIGNER_TX_ID     synthetic tx_id (= MUST be 64-hex per schema;
#                         default derived from event + dag prefix)
#   MOCK_SIGNER_ACTOR     signing_actor (default "metalfreedom")
#   MOCK_SIGNER_PERM      signing_permission (default "anchor")
#   MOCK_SIGNER_NETWORK   network tag (default "xpr-mainnet")
set -u

EVENT="${1:-unknown}"
DAG="${2:-0000000000000000000000000000000000000000000000000000000000000000}"

RC="${MOCK_SIGNER_EXIT:-0}"
# Default tx_id: 64-hex synthesized from event + dag prefix.
DEFAULT_TX="$(printf 'aabbccddeeff%s' "${DAG:0:52}")"
TX_ID="${MOCK_SIGNER_TX_ID:-${DEFAULT_TX}}"
ACTOR="${MOCK_SIGNER_ACTOR:-metalfreedom}"
PERM="${MOCK_SIGNER_PERM:-anchor}"
NETWORK="${MOCK_SIGNER_NETWORK:-xpr-mainnet}"

if [ "${RC}" -ne 0 ]; then
	echo "[mock-signer] simulated failure rc=${RC}" >&2
	exit "${RC}"
fi

# Emit JSON fragment matching the expected sign-anchor-event.sh output shape.
# Fields are aligned with the anchor schema's required list so AJV validation
# in post-anchor-event.sh passes.
cat <<EOF
{
  "chain": "metal-a-chain",
  "chain_backend": "pulsevm",
  "network": "${NETWORK}",
  "method": "phase_alpha_token_transfer",
  "tx_id": "${TX_ID}",
  "block_num": 12345678,
  "block_time": "2026-06-29T13:00:00.500Z",
  "memo": "fyid1:${DAG}",
  "inscribe_action": {
    "account": "eosio.token",
    "name": "transfer",
    "from": "${ACTOR}",
    "to": "fyhistory",
    "quantity": "0.0001 XPR",
    "memo": "fyid1:${DAG}",
    "permission": {
      "actor": "${ACTOR}",
      "permission": "${PERM}"
    }
  }
}
EOF
