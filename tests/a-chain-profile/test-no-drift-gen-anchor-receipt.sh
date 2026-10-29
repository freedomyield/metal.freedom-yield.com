#!/usr/bin/env bash
# tests/a-chain-profile/test-no-drift-gen-anchor-receipt.sh — the receipt
# path carries NO chain literal of its own.
# CHAIN: none (reads files only). PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Until Task 4 (2026-09-30) scripts/gen-anchor-receipt.sh hardcoded the
# history hosts and the explorer base, and this suite pinned those literals
# to config/a-chain-profiles.json. Task 4 moved the receipt path onto
# scripts/lib/a-chain-profile.sh, so drift is now prevented by construction;
# this suite pins THAT: no profile value (chain_id, node host, history host,
# explorer host) may reappear as a literal in the receipt generator, the
# shared history reader or the pre-broadcast reachability check, and each of
# them must still read the profile through the library.
set -u
# shellcheck source=tests/a-chain-profile/no-drift-lib.sh
. "$(dirname "$0")/no-drift-lib.sh"

FILES="scripts/gen-anchor-receipt.sh scripts/lib/anchor-history-read.sh scripts/check-anchor-history-reachable.sh"

# Every chain-specific value in the committed profile file, as plain strings:
# chain_ids, node hosts, and the HOST part of history/explorer bases.
VALUES="$(jq -r '.profiles[] |
	(.chain_id // empty),
	(.node_hosts[]),
	(.history_bases[] | sub("^https://"; "") | sub("/.*$"; "")),
	((.explorer_base // empty) | sub("^https://"; "") | sub("/.*$"; ""))' "$ND_CFG" | sort -u)"
if [ -z "$VALUES" ]; then
	nd_bad "ND0 profile values readable" "no values extracted from $ND_CFG"
	nd_finish test-no-drift-gen-anchor-receipt
	exit
fi

for f in $FILES; do
	path="${ND_REPO_ROOT}/$f"
	if [ ! -r "$path" ]; then nd_bad "ND1 $f readable" "missing"; continue; fi
	hits=""
	while IFS= read -r v; do
		[ -n "$v" ] || continue
		if grep -qF -- "$v" "$path"; then hits="${hits}${v} "; fi
	done <<EOF
$VALUES
EOF
	if [ -z "$hits" ]; then nd_ok "ND1 $f carries no chain literal"
	else nd_bad "ND1 $f carries no chain literal" "found: $hits"; fi
done

# ...and each reads the profile through the library.
R="${ND_REPO_ROOT}/scripts/gen-anchor-receipt.sh"
H="${ND_REPO_ROOT}/scripts/lib/anchor-history-read.sh"
C="${ND_REPO_ROOT}/scripts/check-anchor-history-reachable.sh"
if grep -q 'scripts/lib/a-chain-profile.sh' "$R" && grep -q 'acp_expected_chain_id' "$R" && grep -q 'acp_explorer_base' "$R"; then
	nd_ok "ND2 gen-anchor-receipt.sh reads chain_id and explorer from the profile"
else
	nd_bad "ND2 gen-anchor-receipt.sh reads chain_id and explorer from the profile" "library source / getter missing"
fi
if grep -q 'acp_history_bases' "$H" && grep -q 'acp_history_base_allowed' "$H"; then
	nd_ok "ND3 history bases come from the profile (list + exact allowlist)"
else
	nd_bad "ND3 history bases come from the profile (list + exact allowlist)" "getter missing in anchor-history-read.sh"
fi
if grep -q 'scripts/lib/anchor-history-read.sh' "$R" && grep -q 'scripts/lib/anchor-history-read.sh' "$C"; then
	nd_ok "ND4 receipt and pre-broadcast check share one history reader"
else
	nd_bad "ND4 receipt and pre-broadcast check share one history reader" "one of them does not source anchor-history-read.sh"
fi

nd_finish test-no-drift-gen-anchor-receipt
