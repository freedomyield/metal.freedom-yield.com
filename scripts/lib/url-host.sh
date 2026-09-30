#!/usr/bin/env bash
# scripts/lib/url-host.sh — extract the HOST a client will actually connect to
# from an endpoint URL, for exact-match allowlist checks.
#
# CHAIN: none — defines shell functions only. Never invokes proton, curl or
#        any network client.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. It sits IN FRONT OF the broadcast
#        path: bin/safe-broadcast gate 3 uses it to check that the endpoint
#        proton-cli will push to is on the selected chain profile's
#        node_hosts allowlist (config/a-chain-profiles.json).
#
# WHY A LIBRARY
#   The reference implementation is fyp_host_of in
#   scripts/install-rehearsal-preflight.sh (check 10, the clone-network
#   defense), hardened over three review rounds (authority isolated BEFORE
#   userinfo is stripped; backslash is a WHATWG authority terminator; https
#   only; one trailing dot normalized). bin/safe-broadcast needs the SAME
#   answer for the same input, so the body below is a verbatim copy, and
#   tests/safe-broadcast/test-url-host-parity.sh runs both implementations
#   over the known-hostile corpus and fails on any difference. Read the
#   preflight's check-10 header for the reasoning behind every step; do not
#   "simplify" one copy without the other.
#
# INTERFACE
#   . "${REPO_ROOT}/scripts/lib/url-host.sh"
#   fyd_host_of <url>   prints the lower-cased host; prints NOTHING and
#                       returns 1 when the value is rejected outright
#                       (not https://, or '@' survives userinfo stripping).
#   Callers compare the output by EXACT string (acp_host_allowed), never by
#   suffix or substring.
#
# Bash 3.2 compatible.

fyd_host_of() {
	local raw="$1" v
	v="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
	case "$v" in
		https://*) v="${v#https://}" ;;
		*) printf ''; return 1 ;;
	esac
	v="${v%%[/?#\\]*}"
	v="${v##*@}"
	case "$v" in
		*@*) printf ''; return 1 ;;
	esac
	v="${v%%:*}"
	v="${v%.}"
	printf '%s' "$v"
}
