#!/usr/bin/env bash
# scripts/notify-relay-count.sh — count what notify-relay-put.sh logged (read only).
# CHAIN: none — reads the journal and the cron dir; writes nothing, sends nothing.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast-capable command).
#
# Usage: scripts/notify-relay-count.sh [--since <value passed to journalctl --since>]   (default: today)
# Output: a one-screen table: put 204, each fallback word (most first), other, total,
#         and the cron files that carry an FYD_NOTIFY env line.
# Exit: 0 ok / 1 journal or cron dir unreadable (one line) / 2 bad arguments.
#
# Where to connect: nothing; run it by hand on the host. How to remove: delete this file.
# Env overrides (test-time): FYD_JOURNALCTL (default journalctl), FYD_CRON_DIR (default /etc/cron.d).

set -euo pipefail

# --- definition table
COUNT_JOURNALCTL_DEFAULT='journalctl'
COUNT_CRON_DIR_DEFAULT='/etc/cron.d'
COUNT_LOG_TAG='notify-relay'
COUNT_SINCE_DEFAULT='today'
COUNT_SUCCESS_LINE='notify-relay: put 204'
COUNT_FALLBACK_PREFIX='notify-relay: fallback '
COUNT_FALLBACK_WORD_PATTERN='^[A-Za-z0-9_]+$'
COUNT_NOTIFY_ENV_NAME='FYD_NOTIFY'
COUNT_NAMES_LIST_MAX=20

COUNT_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=SCRIPTDIR/lib/cron-filename-guard.sh
. "${COUNT_SCRIPT_DIR}/lib/cron-filename-guard.sh"

count_fail() { echo "ERROR: $2" >&2; exit "$1"; }

# count_read_journal <since> — the journal message lines (no metadata), or exit 1.
count_read_journal() {
	local jc="${FYD_JOURNALCTL:-$COUNT_JOURNALCTL_DEFAULT}"
	"$jc" -t "$COUNT_LOG_TAG" --since "$1" -o cat -q --no-pager 2>/dev/null \
		|| count_fail 1 "journal unreadable (journalctl failed; try as a user allowed to read it)"
}

# count_cron_names <cron_dir> — names of cron-executed files with an FYD_NOTIFY env line, sorted.
count_cron_names() {
	local dir="$1" f bn
	[ -d "$dir" ] && [ -r "$dir" ] || count_fail 1 "cron dir unreadable"
	for f in "$dir"/*; do
		[ -f "$f" ] || continue
		bn="$(basename "$f")"
		is_cron_executed_filename "$bn" || continue
		if grep -qE "^[[:space:]]*${COUNT_NOTIFY_ENV_NAME}[[:space:]]*=" "$f" 2>/dev/null; then
			echo "$bn"
		else
			[ "$?" = 1 ] || count_fail 1 "cron file unreadable: ${bn}"
		fi
	done | LC_ALL=C sort
}

# count_tally <journal text> — lines "put <n>", "fb <word> <n>", "other <n>" on stdout.
count_tally() {
	printf '%s\n' "$1" | awk \
		-v ok="$COUNT_SUCCESS_LINE" -v pre="$COUNT_FALLBACK_PREFIX" -v pat="$COUNT_FALLBACK_WORD_PATTERN" '
		$0 == "" { next }
		$0 == ok { put++; next }
		index($0, pre) == 1 { w = substr($0, length(pre) + 1); if (w ~ pat) { fb[w]++; next } }
		{ other++ }
		END {
			print "put " (put + 0)
			for (w in fb) print "fb " w " " fb[w]
			print "other " (other + 0)
		}'
}

count_print() { # <since> <tally> <names>
	local since="$1" tally="$2" names="$3" total=0 n word cnt kind rest nnames
	echo "notify-relay の数（since ${since}）"
	while read -r kind rest; do
		case "$kind" in
			put) echo "put 204｜${rest}"; total=$((total + rest)) ;;
			other) n="$rest" ;;
		esac
	done <<< "$tally"
	while read -r kind word cnt; do
		[ "$kind" = fb ] || continue
		echo "fallback ${word}｜${cnt}"
		total=$((total + cnt))
	done < <(printf '%s\n' "$tally" | grep '^fb ' | LC_ALL=C sort -k3,3nr -k2,2)
	echo "その他｜${n:-0}"
	echo "合計｜$((total + ${n:-0}))"
	nnames=0
	[ -z "$names" ] || nnames="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
	echo "${COUNT_NOTIFY_ENV_NAME} を持つ cron｜${nnames} 本"
	if [ "$nnames" -gt 0 ] && [ "$nnames" -le "$COUNT_NAMES_LIST_MAX" ]; then printf '%s\n' "$names" | sed 's/^/  /'; fi
}

count_main() {
	local since="$COUNT_SINCE_DEFAULT" journal tally names
	while [ $# -gt 0 ]; do
		case "$1" in
			--since) [ $# -ge 2 ] || count_fail 2 "--since needs a value"; since="$2"; shift 2 ;;
			*) count_fail 2 "usage: notify-relay-count.sh [--since <value>]" ;;
		esac
	done
	journal="$(count_read_journal "$since")"
	names="$(count_cron_names "${FYD_CRON_DIR:-$COUNT_CRON_DIR_DEFAULT}")"
	tally="$(count_tally "$journal")"
	count_print "$since" "$tally" "$names"
}

count_main "$@"
