#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-run-testnet-rehearsal.sh —
# scripts/run-testnet-rehearsal.sh's endpoints / chain name / explorer
# == config/a-chain-profiles.json (xpr-testnet).
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
# Owner: Task 5 of the PulseVM migration-readiness plan rewrites/deletes this
# suite when the rehearsal reads the profile instead of literals.
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"
F=scripts/run-testnet-rehearsal.sh
nd_member "TR1 history RPC default"     "$F" '^TESTNET_RPC="\$\{XPR_TESTNET_RPC:-([^}]+)\}".*' xpr-testnet history_bases
nd_member "TR2 chain RPC default host"  "$F" '^TESTNET_CHAIN_RPC="\$\{XPR_TESTNET_CHAIN_RPC:-https://([^}/]+)\}".*' xpr-testnet node_hosts
nd_eq     "TR3 proton chain name"       "$F" '^proton chain:set ([a-z0-9-]+) >/dev/null.*' xpr-testnet proton_network
nd_eq     "TR4 explorer base"           "$F" '^[[:space:]]*explorer URL:[[:space:]]+(https://[^$]+)/\$\{TX_ID\}.*' xpr-testnet explorer_base
nd_finish test-no-drift-run-testnet-rehearsal
