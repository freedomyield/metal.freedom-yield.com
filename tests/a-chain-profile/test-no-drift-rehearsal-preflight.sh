#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-rehearsal-preflight.sh —
# scripts/install-rehearsal-preflight.sh carries NO chain literal of its own.
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Rewritten by Task 5 of the PulseVM migration-readiness plan (2026-09-30).
# Until then this suite pinned the pre-flight's hard-coded host allowlists,
# RPC defaults and rehearsal chain name to config/a-chain-profiles.json. The
# pre-flight now reads all of them through scripts/lib/a-chain-profile.sh, so
# the drift risk is the opposite one: a literal creeping BACK into executable
# code and silently shadowing the profile. This suite fails on that, and on
# any value no longer being read from the library. (Comment lines may name
# hosts — they document measurements; only code can shadow the profile.)
# shellcheck disable=SC2016  # patterns below are literal regexes, not expansions
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"
F=scripts/install-rehearsal-preflight.sh
CODE="$(grep -vE '^[[:space:]]*#' "${ND_REPO_ROOT}/$F")"

# RP1: no profile value of ANY profile in executable lines (chain_id, node
# host, history base host, explorer host).
leaks=""
while IFS= read -r v; do
	[ -n "$v" ] || continue
	printf '%s\n' "$CODE" | grep -qF -- "$v" && leaks="${leaks} ${v}"
done <<VALUES
$(jq -r '.profiles[] | (.chain_id // empty), .node_hosts[],
	(.history_bases[] | sub("^https://"; "") | sub("/.*$"; "")),
	((.explorer_base // empty) | sub("^https://"; "") | sub("/.*$"; ""))' "$ND_CFG" | sort -u)
VALUES
if [ -z "$leaks" ]; then nd_ok "RP1 no chain host / chain_id literal in code"; else nd_bad "RP1 no chain host / chain_id literal in code" "found:${leaks}"; fi

# RP2: no proton-cli network name is used as a comparison operand or as the
# chain argument of an allowlist scan (prose in remedy messages is fine).
nets=""
while IFS= read -r n; do
	[ -n "$n" ] || continue
	if printf '%s\n' "$CODE" | grep -qE -- "(=|!=) \"${n}\" \]|fyp_scan_chain_key \"\\\$out\" [a-z]+ ${n} "; then
		nets="${nets} ${n}"
	fi
done <<NETS
$(jq -r '.profiles[] | .proton_network // empty' "$ND_CFG" | sort -u)
NETS
if [ -z "$nets" ]; then nd_ok "RP2 no proton-cli network name compared as a literal"; else nd_bad "RP2 no proton-cli network name compared as a literal" "found:${nets}"; fi

nd_code_has() { # <name> <ERE>
	if printf '%s\n' "$CODE" | grep -qE -- "$2"; then nd_ok "$1"; else nd_bad "$1" "no code line matches: $2"; fi
}
nd_code_has "RP3 sources the profile library"          '\. "\$\{REPO_ROOT\}/scripts/lib/a-chain-profile\.sh"'
nd_code_has "RP4 testnet allowlist from node_hosts"    'fyp_acp_set TESTNET_HOST_ALLOWLIST acp_node_hosts +testnet'
nd_code_has "RP5 mainnet allowlist from node_hosts"    'fyp_acp_set MAINNET_HOST_ALLOWLIST acp_node_hosts +mainnet'
nd_code_has "RP6 network names from proton_network"    'fyp_acp_set TESTNET_NET +acp_proton_network testnet'
nd_code_has "RP7 history bases from the profile"       'fyp_acp_set TESTNET_HISTORY_BASES +acp_history_bases +testnet'
nd_code_has "RP8 XPR_TESTNET_RPC judged as an exact history base" 'acp_history_base_allowed testnet "\$TESTNET_HYPERION_RPC"'
nd_code_has "RP9 chain RPC default = first profile node host" '^TESTNET_CHAIN_RPC="\$\{XPR_TESTNET_CHAIN_RPC:-https://\$\{TESTNET_HOST_ALLOWLIST%% \*\}\}"'
nd_code_has "RP10 receipt RPC default = first profile history base" '^TESTNET_HYPERION_RPC="\$\{XPR_TESTNET_RPC:-\$\{TESTNET_HISTORY_BASES%% \*\}\}"'
# RP11: no allowlist is assigned a literal list any more.
if printf '%s\n' "$CODE" | grep -qE '^(TESTNET|MAINNET)_HOST_ALLOWLIST="[a-z]'; then
	nd_bad "RP11 no literal allowlist assignment" "$(printf '%s\n' "$CODE" | grep -E '^(TESTNET|MAINNET)_HOST_ALLOWLIST="[a-z]')"
else
	nd_ok "RP11 no literal allowlist assignment"
fi
# RP12: the FIRST listed values are the defaults, i.e. the old literals —
# pinned so a profile reorder is a visible, reviewed change of the default
# transport rather than an accident.
nd_first() { nd_prof "$1" "$2" | head -n 1; }
if [ "$(nd_first xpr-testnet node_hosts)" = "rpc.api.testnet.metalx.com" ] \
	&& [ "$(nd_first xpr-testnet history_bases)" = "https://test.proton.eosusa.io" ]; then
	nd_ok "RP12 default transports unchanged (first node host / first history base of xpr-testnet)"
else
	nd_bad "RP12 default transports unchanged (first node host / first history base of xpr-testnet)" \
		"xpr-testnet order changed: $(nd_first xpr-testnet node_hosts) / $(nd_first xpr-testnet history_bases)"
fi
nd_finish test-no-drift-rehearsal-preflight
