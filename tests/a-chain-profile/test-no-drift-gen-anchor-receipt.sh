#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-gen-anchor-receipt.sh —
# scripts/gen-anchor-receipt.sh's chain literals == config/a-chain-profiles.json.
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
# Owner: Task 4 of the PulseVM migration-readiness plan rewrites/deletes this
# suite when the receipt generator reads the profile instead of literals.
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"
F=scripts/gen-anchor-receipt.sh
nd_member "GR1 mainnet history RPC" "$F" '.*mainnet-a\|xpr-mainnet\|proton\) RPC="([^"]+)".*' xpr-mainnet history_bases
nd_member "GR2 testnet history RPC" "$F" '.*testnet-a\|xpr-testnet\|proton-test\) RPC="([^"]+)".*' xpr-testnet history_bases
# The script uses ONE explorer default for both networks; it equals the
# mainnet profile. (Testnet receipts therefore link the mainnet explorer
# today — recorded in the Task 2 report for Task 4 to decide.)
nd_eq     "GR3 explorer base default" "$F" '^EXPLORER_BASE="\$\{EXPLORER_BASE:-([^}]+)\}".*' xpr-mainnet explorer_base
nd_finish test-no-drift-gen-anchor-receipt
