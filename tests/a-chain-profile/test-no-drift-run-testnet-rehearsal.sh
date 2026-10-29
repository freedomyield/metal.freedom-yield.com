#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-run-testnet-rehearsal.sh —
# scripts/run-testnet-rehearsal.sh carries NO chain literal of its own.
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Rewritten by Task 5 of the PulseVM migration-readiness plan (2026-09-30).
# Until then this suite pinned the rehearsal's hard-coded endpoints, proton-cli
# network name and explorer base to config/a-chain-profiles.json (xpr-testnet).
# The rehearsal now reads them through scripts/lib/a-chain-profile.sh, so this
# suite fails if a literal comes back into executable code or a value stops
# being read from the library. Runtime proof that the default profile yields
# the old values: tests/run-testnet-rehearsal/test-history-reachability-gate.sh
# (G2, G7).
# shellcheck disable=SC2016  # patterns below are literal regexes, not expansions
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"
F=scripts/run-testnet-rehearsal.sh
CODE="$(grep -vE '^[[:space:]]*#' "${ND_REPO_ROOT}/$F")"

leaks=""
while IFS= read -r v; do
	[ -n "$v" ] || continue
	printf '%s\n' "$CODE" | grep -qF -- "$v" && leaks="${leaks} ${v}"
done <<VALUES
$(jq -r '.profiles[] | (.chain_id // empty), .node_hosts[],
	(.history_bases[] | sub("^https://"; "") | sub("/.*$"; "")),
	((.explorer_base // empty) | sub("^https://"; "") | sub("/.*$"; ""))' "$ND_CFG" | sort -u)
VALUES
if [ -z "$leaks" ]; then nd_ok "TR1 no chain host / chain_id / explorer literal in code"; else nd_bad "TR1 no chain host / chain_id / explorer literal in code" "found:${leaks}"; fi

nd_code_has() { # <name> <ERE>
	if printf '%s\n' "$CODE" | grep -qE -- "$2"; then nd_ok "$1"; else nd_bad "$1" "no code line matches: $2"; fi
}
nd_code_has "TR2 sources the profile library"         '\. "\$\{REPO_ROOT\}/scripts/lib/a-chain-profile\.sh"'
nd_code_has "TR3 chain:set takes the profile network"  '^proton chain:set "\$PROTON_NET" >/dev/null'
nd_code_has "TR4 network name from the profile"        '^PROTON_NET="\$\(acp_proton_network testnet\)"'
nd_code_has "TR5 explorer from the profile"            '^TESTNET_EXPLORER="\$\(acp_explorer_base testnet\)"'
nd_code_has "TR6 chain RPC default from node_hosts"    '^TESTNET_CHAIN_RPC="\$\{XPR_TESTNET_CHAIN_RPC:-https://\$\{PROFILE_NODE_HOST\}\}"'
nd_code_has "TR7 history RPC default from history_bases" '^TESTNET_RPC="\$\{XPR_TESTNET_RPC:-\$\{PROFILE_HISTORY_BASE\}\}"'
nd_code_has "TR8 pre-broadcast reachability check on the same RPC as the receipt" \
	'--chain=testnet-a --rpc="\$TESTNET_RPC" --ledger=/dev/null --actor="\$XPR_ACCOUNT"'
if printf '%s\n' "$CODE" | grep -qE '^proton chain:set [a-z]'; then
	nd_bad "TR9 no literal chain:set network" "$(printf '%s\n' "$CODE" | grep -E '^proton chain:set [a-z]')"
else
	nd_ok "TR9 no literal chain:set network"
fi
nd_finish test-no-drift-run-testnet-rehearsal
