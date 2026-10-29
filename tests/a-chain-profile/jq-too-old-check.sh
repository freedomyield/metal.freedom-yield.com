#!/usr/bin/env bash
# tests/a-chain-profile/jq-too-old-check.sh — run UNDER A REAL jq < 1.6 (the
# docker matrix runs it on ubuntu:18.04, jq 1.5). Asserts that every getter
# of scripts/lib/a-chain-profile.sh refuses with rc 6 and an empty stdout,
# i.e. that the version gate — not luck — keeps the library off a jq it was
# not written for. Not a test-*.sh suite: on a host with jq >= 1.6 it has
# nothing to prove and says so (exit 2).
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/a-chain-profile.sh"
ver="$(jq --version 2>/dev/null)"
case "$ver" in
	jq-1.[0-5]|jq-1.[0-5][!0-9]*) ;;
	*) echo "jq-too-old-check: needs jq < 1.6, found '${ver}'"; exit 2 ;;
esac
PASS=0; FAIL=0
for call in "acp_validate" "acp_profile_name mainnet" "acp_chain_id mainnet" "acp_chain_id testnet" \
	"acp_expected_chain_id mainnet" "acp_node_hosts mainnet" "acp_history_bases testnet" \
	"acp_explorer_base mainnet" "acp_proton_network mainnet" "acp_push_response mainnet" \
	"acp_lib_equals_head mainnet" "acp_host_allowed mainnet proton.eosusa.io" \
	"acp_history_base_allowed testnet https://test.proton.eosusa.io"; do
	out="$(bash -c ". '$LIB'; $call" 2>/tmp/jq-too-old.err)"; rc=$?
	if [ "$rc" = 6 ] && [ -z "$out" ] && grep -q 'older than 1.6' /tmp/jq-too-old.err; then
		PASS=$((PASS + 1)); echo "PASS $call (rc 6, stdout empty)"
	else
		FAIL=$((FAIL + 1)); echo "FAIL $call rc=$rc stdout='$out' stderr=$(head -1 /tmp/jq-too-old.err)"
	fi
done
echo "jq-too-old-check (${ver}): PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
