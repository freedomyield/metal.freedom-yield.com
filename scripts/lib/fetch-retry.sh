#!/usr/bin/env bash
# scripts/lib/fetch-retry.sh — the single fetch-with-retry loop shared by the
# monitors that poll a URL (anchor-publish-health, identity-pins, pulsevm-upstream).
#
# CHAIN: none — defines shell functions only. It runs whatever $CURL names;
#        the library itself opens no connection and holds no endpoint.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (read-only GET, no broadcast path).
#
# USAGE (after `source`):
#   fy_fetch_retry [--max-time=SECONDS] [--no-retry-4xx] -- URL OUTFILE
#     stdout : the FINAL attempt's HTTP status code ("000" on transport
#              failure), no trailing newline
#     OUTFILE: the FINAL attempt's body
#     return : 0 after a valid call, 64 on a usage error (a malformed
#              FYD_FETCH_ATTEMPTS / FYD_RETRY_SLEEP is a usage error)
#     env    : FYD_FETCH_ATTEMPTS (default 3; integer 1..10, no sign, no
#              leading 0), FYD_RETRY_SLEEP (default 3; integer 0..60, no sign,
#              no leading 0 except 0 itself), CURL (the caller's curl, required)
#   --max-time is required (the monitors differ: 15 vs 20 seconds, no recorded
#   reason, so it stays an argument). --no-retry-4xx stops at the first 4xx
#   (pulsevm-upstream: a 404 on a third party cannot succeed on retry).
#
# The curl call, the loop and the stop rules are the bytes of the three copies
# this replaces. Stops at the first 200; sleeps between attempts, never after
# the last. A malformed FYD_FETCH_ATTEMPTS / FYD_RETRY_SLEEP is rejected with 64
# before any curl call (the earlier "behaves as in those copies" rule is
# cancelled: design spec §17).
#
# Library rules (B-P7): never ends the caller's shell, no side effects when sourced.

_fy_fetch_retry_usage() {
	printf 'fy_fetch_retry: %s\n' "$1" >&2
	return 64
}

fy_fetch_retry() {
	local max_time="" no_retry_4xx=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--max-time=*) max_time="${1#--max-time=}" ;;
		--no-retry-4xx) no_retry_4xx=1 ;;
		--) shift; break ;;
		*) _fy_fetch_retry_usage "unknown option or missing --: $1"; return 64 ;;
		esac
		shift
	done
	case "$max_time" in
	"" | *[!0-9]*) _fy_fetch_retry_usage "--max-time=SECONDS (integer) is required"; return 64 ;;
	esac
	if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
		_fy_fetch_retry_usage "need exactly: -- URL OUTFILE"
		return 64
	fi
	local url="$1" outfile="$2"
	local attempts="${FYD_FETCH_ATTEMPTS:-3}"
	local sleep_s="${FYD_RETRY_SLEEP:-3}"
	case "$attempts" in
	[1-9] | 10) ;;
	*) _fy_fetch_retry_usage "FYD_FETCH_ATTEMPTS must be an integer 1..10"; return 64 ;;
	esac
	case "$sleep_s" in
	0 | [1-9] | [1-5][0-9] | 60) ;;
	*) _fy_fetch_retry_usage "FYD_RETRY_SLEEP must be an integer 0..60"; return 64 ;;
	esac
	local attempt=1 code
	while :; do
		code="$("$CURL" -sS -o "$outfile" -w "%{http_code}" --max-time "$max_time" "$url" 2>/dev/null || echo "000")"
		[ "$code" = "200" ] && break
		if [ "$no_retry_4xx" = "1" ]; then
			case "$code" in 4??) break ;; esac
		fi
		[ "$attempt" -ge "$attempts" ] && break
		sleep "$sleep_s"
		attempt=$((attempt + 1))
	done
	printf '%s' "$code"
	return 0
}
