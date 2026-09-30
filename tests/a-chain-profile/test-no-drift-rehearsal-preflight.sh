#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-rehearsal-preflight.sh —
# scripts/install-rehearsal-preflight.sh's allowlists and endpoint defaults
# == config/a-chain-profiles.json.
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
# Owner: Task 5 of the PulseVM migration-readiness plan rewrites/deletes this
# suite when the pre-flight reads the profile instead of literals.
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"
F=scripts/install-rehearsal-preflight.sh
nd_set_eq "RP1 testnet host allowlist" "$F" '^TESTNET_HOST_ALLOWLIST="([^"]+)"$' xpr-testnet node_hosts
nd_set_eq "RP2 mainnet host allowlist" "$F" '^MAINNET_HOST_ALLOWLIST="([^"]+)"$' xpr-mainnet node_hosts
nd_member "RP3 testnet history RPC default" "$F" '^TESTNET_HYPERION_RPC="\$\{XPR_TESTNET_RPC:-([^}]+)\}".*' xpr-testnet history_bases
nd_member "RP4 testnet chain RPC default host" "$F" '^TESTNET_CHAIN_RPC="\$\{XPR_TESTNET_CHAIN_RPC:-https://([^}/]+)\}".*' xpr-testnet node_hosts
# shellcheck disable=SC2016  # regex, not an expansion
nd_eq     "RP5 rehearsal chain name" "$F" '.*\[ "\$RH_CHAIN" = "([a-z0-9-]+)" \].*' xpr-testnet proton_network
nd_finish test-no-drift-rehearsal-preflight
