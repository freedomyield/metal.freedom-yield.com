#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-preview-cycle-anchor-broadcast.sh —
# scripts/preview-cycle-anchor-broadcast.sh's chain literals
# == config/a-chain-profiles.json.
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
# Not assigned to Tasks 3-5 of the PulseVM plan: this suite keeps the preview
# pinned until whichever change moves it onto the profile library.
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"
F=scripts/preview-cycle-anchor-broadcast.sh
nd_eq     "PV1 mainnet chain_id"       "$F" '^EXPECTED_CHAIN_ID="([0-9a-f]{64})".*' xpr-mainnet chain_id
nd_member "PV2 gate-1 testnet history" "$F" '^TESTNET_HIST="([^"]+)/v1/history/get_transaction".*' xpr-testnet history_bases
nd_finish test-no-drift-preview-cycle-anchor-broadcast
