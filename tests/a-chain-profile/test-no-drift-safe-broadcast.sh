#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-safe-broadcast.sh — bin/safe-broadcast's
# chain literals == config/a-chain-profiles.json (xpr-* profiles).
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
# Owner: Task 3 of the PulseVM migration-readiness plan rewrites/deletes this
# suite when bin/safe-broadcast reads the profile instead of literals.
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"
F=bin/safe-broadcast
nd_eq     "SB1 testnet chain_id default"  "$F" '.*FYD_TESTNET_CHAIN_ID:-([0-9a-f]{64})\}.*' xpr-testnet chain_id
nd_eq     "SB2 mainnet chain_id default"  "$F" '.*FYD_MAINNET_CHAIN_ID:-([0-9a-f]{64})\}.*' xpr-mainnet chain_id
nd_eq     "SB3 testnet proton network"    "$F" '.*PROTON_CHAIN="([a-z0-9-]+)"; IS_MAINNET=0.*' xpr-testnet proton_network
nd_eq     "SB4 mainnet proton network"    "$F" '.*PROTON_CHAIN="([a-z0-9-]+)"; +IS_MAINNET=1.*' xpr-mainnet proton_network
nd_member "SB5 gate-1 testnet history"    "$F" '^[[:space:]]*TESTNET_RPC="\$\{XPR_TESTNET_RPC:-([^}]+)\}".*' xpr-testnet history_bases
nd_finish test-no-drift-safe-broadcast
