#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-safe-broadcast.sh — bin/safe-broadcast
# holds NO chain-specific literal any more: every chain value reaches its
# gates through scripts/lib/a-chain-profile.sh (config/a-chain-profiles.json).
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Rewritten by Task 3 of the PulseVM migration-readiness plan (2026-09-30):
# until then this suite pinned the wrapper's hard-coded chain_ids / network
# names / gate-1 history host to the profile. Those literals are gone, so the
# drift risk is now the opposite one — a literal creeping BACK into code and
# silently shadowing the profile. This suite fails on that, and on any
# chain value no longer being read from the library.
# shellcheck disable=SC2016  # nd_code_has patterns are literal regexes, not expansions
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"
F=bin/safe-broadcast
CODE="$(grep -vE '^[[:space:]]*#' "${ND_REPO_ROOT}/$F")"

# SB1: no profile value (chain_id, node host, history base, explorer base) of
# ANY profile appears in executable (non-comment) lines.
leaks=""
while IFS= read -r v; do
	[ -n "$v" ] || continue
	printf '%s\n' "$CODE" | grep -qF -- "$v" && leaks="${leaks} ${v}"
done <<VALUES
$(jq -r '.profiles[] | (.chain_id // empty), .node_hosts[], .history_bases[], (.explorer_base // empty)' "$ND_CFG" | sort -u)
VALUES
if [ -z "$leaks" ]; then nd_ok "SB1 no chain literal in code"; else nd_bad "SB1 no chain literal in code" "found:${leaks}"; fi

# SB2..SB8: each chain value is read through its getter.
nd_code_has() { # <name> <ERE>
	if printf '%s\n' "$CODE" | grep -qE -- "$2"; then nd_ok "$1"; else nd_bad "$1" "no code line matches: $2"; fi
}
nd_code_has "SB2 sources the profile library"      '\. "\$\{REPO_ROOT\}/scripts/lib/a-chain-profile\.sh"'
nd_code_has "SB3 expected chain_id from profile"   '^EXPECTED_CHAIN_ID="\$\(acp_expected_chain_id "\$ROLE"\)"'
nd_code_has "SB4 proton network from profile"      '^PROTON_CHAIN="\$\(acp_proton_network "\$ROLE"\)"'
nd_code_has "SB5 push shape from profile"          '^PUSH_RESPONSE="\$\(acp_push_response "\$ROLE"\)"'
nd_code_has "SB6 gate-1 bases from testnet profile" 'TESTNET_HISTORY_BASES="\$\(acp_history_bases testnet\)"'
nd_code_has "SB7 gate-3 host check uses node_hosts" 'acp_host_allowed "\$ROLE" "\$host"'
nd_code_has "SB8 id-only history from profile"     'HISTORY_BASES="\$\(acp_history_bases "\$ROLE"\)"'
# SB9: no proton-cli network name is assigned as a literal.
if printf '%s\n' "$CODE" | grep -qE 'PROTON_CHAIN="[a-z]'; then
	nd_bad "SB9 no literal PROTON_CHAIN assignment" "$(printf '%s\n' "$CODE" | grep -E 'PROTON_CHAIN="[a-z]')"
else
	nd_ok "SB9 no literal PROTON_CHAIN assignment"
fi
nd_finish test-no-drift-safe-broadcast
