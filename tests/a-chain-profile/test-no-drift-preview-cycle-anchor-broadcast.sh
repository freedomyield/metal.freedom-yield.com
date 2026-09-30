#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-preview-cycle-anchor-broadcast.sh —
# scripts/preview-cycle-anchor-broadcast.sh (the advisory STAGE-1 preview of
# gates 1 and 3) reads its chain values from the SAME profile library as
# bin/safe-broadcast, so it cannot drift from the real gates.
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
# Rewritten by Task 3 of the PulseVM migration-readiness plan (2026-09-30):
# it used to pin the preview's own chain_id / history literals to the
# profile; those literals are gone.
# shellcheck disable=SC2016  # nd_code_has patterns are literal regexes, not expansions
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"
F=scripts/preview-cycle-anchor-broadcast.sh
CODE="$(grep -vE '^[[:space:]]*#' "${ND_REPO_ROOT}/$F")"

leaks=""
while IFS= read -r v; do
	[ -n "$v" ] || continue
	printf '%s\n' "$CODE" | grep -qF -- "$v" && leaks="${leaks} ${v}"
done <<VALUES
$(jq -r '.profiles[] | (.chain_id // empty), .node_hosts[], .history_bases[]' "$ND_CFG" | sort -u)
VALUES
if [ -z "$leaks" ]; then nd_ok "PV1 no chain literal in code"; else nd_bad "PV1 no chain literal in code" "found:${leaks}"; fi

nd_code_has() { # <name> <ERE>
	if printf '%s\n' "$CODE" | grep -qE -- "$2"; then nd_ok "$1"; else nd_bad "$1" "no code line matches: $2"; fi
}
nd_code_has "PV2 sources the profile library"       '\. "\$\{SCRIPT_DIR\}/lib/a-chain-profile\.sh"'
nd_code_has "PV3 gate-3 chain_id = safe-broadcast's" 'EXPECTED_CHAIN_ID="\$\(acp_expected_chain_id mainnet\)"'
nd_code_has "PV4 gate-1 base from testnet profile"   'TESTNET_HIST_BASE="\$\(acp_history_bases testnet \| head -1\)"'
nd_code_has "PV5 gate-1 URL built from that base"    '^TESTNET_HIST="\$\{TESTNET_HIST_BASE\}/v1/history/get_transaction"'
nd_finish test-no-drift-preview-cycle-anchor-broadcast
