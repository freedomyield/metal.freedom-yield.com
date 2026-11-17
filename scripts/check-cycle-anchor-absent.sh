#!/usr/bin/env bash
# check-cycle-anchor-absent.sh — read, from the history bases of the selected
# chain profile, whether a cycle's anchor (memo prefix fya<S>c<N>) is on chain
# for the signing account. A person reads its exit 0 before a re-authorized
# broadcast, so 0 is given only when a floor is seen and the prefix is absent.
#
# CHAIN: none — READ ONLY. It sends only history/chain READ requests, all
#        through scripts/lib/anchor-history-read.sh (it reads no response
#        itself). It never signs, never pushes, never runs the proton CLI;
#        tests/check-cycle-anchor-absent/ greps this file to keep it that way.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast).
#
# Usage:
#   check-cycle-anchor-absent.sh --chain=<mainnet-a|testnet-a|proton|proton-test|xpr-mainnet|xpr-testnet>
#       ( --memo-prefix=fya<S>c<N> | --anchor-source=<file> )     exactly one of the two
#       [--actor=<account>]    default: first line of $FY_CONFIG_DIR/xpr-account
#                              (FY_CONFIG_DIR default /etc/freedom-yield)
#       [--not-before=<E>]     E = YYYY-MM-DDTHH:MM:SS (the wrapper's expiration)
#       [-h|--help]
#   --anchor-source: the prefix is fya<schema_version>c<observations_branch.
#   cycle_number_observed> (as scripts/sign-anchor-event.sh builds it).
#   There is no other flag: no base override, no way to switch a guard off.
#
# Exit codes (stdout is one line for 0 and 10, empty otherwise; every reason
# goes to stderr as "[cycle-anchor-absent] ..."):
#   0   absent: in EVERY base a floor was seen and the prefix is not there
#       (with --not-before: E is also past the irreversible block in every base)
#         ABSENT prefix=<p> profile=<name> floor=<first base's floor> bases=<n>
#         [ not_before=<E> lib_time=<first base's LIB time>]
#   10  present: some base shows the prefix (found) or a later cycle of the
#       same schema (found_later)
#         PRESENT prefix=<p> verdict=<found|found_later> trx_id=<..> block_num=<..> timestamp=<..> base=<url>
#   4   --not-before: E is not yet past the irreversible block of some base
#   3   history unreadable or stale, no floor seen before the history ended, a
#       base serves another chain_id, or a LIB time cannot be read
#   2   profile unusable (no chain_id / history_bases) or a library unreadable
#   1   usage error
#
# Per base, in this order, the first decision ends that base (outcome name):
#   1. chain_id: a base that answers and differs from the profile's -> unreadable;
#      a base that does not answer (Hyperion-only) goes on, except with
#      --not-before (step 2 needs get_info) -> unreadable
#   2. only with --not-before: LIB time > E (strictly) goes on; LIB <= E -> wait
#      (history is not read); LIB time unreadable -> unreadable
#   3. index freshness (AHR_INDEX_MAX_LAG_BLOCKS) stale -> unreadable
#   4. ahr_find_cycle_anchor: found / found_later -> present; clear with a floor
#      -> absent; clear without a floor (history ran out) -> unreadable (J1 (a),
#      on every chain); unreadable or an unexpected shape -> unreadable
# All bases are combined: any present -> 10 (the first one in profile order);
# else any unreadable -> 3; else any wait -> 4; else all absent -> 0.
# One base's "absent" never decides alone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---- definitions (the only place these values are written) ------------------
CCAA_DEFAULT_CONFIG_DIR="/etc/freedom-yield"
CCAA_ACTOR_FILE_NAME="xpr-account"
CCAA_REQUIRED_TOOLS="jq curl"
CCAA_ACTOR_CHARS="abcdefghijklmnopqrstuvwxyz12345."
CCAA_ACTOR_MAX_LENGTH=12

CCAA_LOG_TAG="[cycle-anchor-absent]"
ccaa__log() { printf '%s %s\n' "$CCAA_LOG_TAG" "$*" >&2; }
ccaa__die() { local rc="$1"; shift; ccaa__log "$*"; exit "$rc"; }

# ---- input checks (digits and letters are listed, never ranged) --------------
ccaa__is_digits() { case "${1:-}" in ''|*[!0123456789]*) return 1 ;; esac; return 0; }

# ccaa__valid_prefix <p> — fya<digits>c<digits> and nothing else.
ccaa__valid_prefix() {
	local rest schema cycle
	case "${1:-}" in fya*c*) ;; *) return 1 ;; esac
	rest="${1#fya}"; schema="${rest%%c*}"; cycle="${rest#*c}"
	ccaa__is_digits "$schema" && ccaa__is_digits "$cycle"
}

ccaa__valid_actor() {
	local a="${1:-}"
	[ -n "$a" ] && [ "${#a}" -le "$CCAA_ACTOR_MAX_LENGTH" ] || return 1
	case "$a" in *[!"$CCAA_ACTOR_CHARS"]*) return 1 ;; esac
	return 0
}

# ccaa__read_anchor_source <file> — prints fya<schema>c<cycle>, or rc 1.
# The file must hold exactly one JSON value; both numbers are integers >= 1.
ccaa__read_anchor_source() {
	local prefix
	[ -f "${1:-}" ] && [ -r "$1" ] || return 1
	prefix="$(jq -r -s '
		if length == 1 and (.[0] | type) == "object"
		   and (.[0].schema_version | type) == "number"
		   and (.[0].schema_version | . == floor and . >= 1)
		   and (.[0].observations_branch | type) == "object"
		   and (.[0].observations_branch.cycle_number_observed | type) == "number"
		   and (.[0].observations_branch.cycle_number_observed | . == floor and . >= 1)
		then "fya\(.[0].schema_version)c\(.[0].observations_branch.cycle_number_observed)"
		else empty end' "$1" 2>/dev/null)" || return 1
	ccaa__valid_prefix "$prefix" || return 1
	printf '%s\n' "$prefix"
}

# ---- arguments ---------------------------------------------------------------
CHAIN=""
PREFIX=""
PREFIX_GIVEN=0
SOURCE_FILE=""
SOURCE_GIVEN=0
ACTOR=""
ACTOR_GIVEN=0
NOT_BEFORE=""
NOT_BEFORE_GIVEN=0

for arg in "$@"; do
	case "$arg" in
		--chain=*)         CHAIN="${arg#*=}" ;;
		--memo-prefix=*)   PREFIX="${arg#*=}"; PREFIX_GIVEN=1 ;;
		--anchor-source=*) SOURCE_FILE="${arg#*=}"; SOURCE_GIVEN=1 ;;
		--actor=*)         ACTOR="${arg#*=}"; ACTOR_GIVEN=1 ;;
		--not-before=*)    NOT_BEFORE="${arg#*=}"; NOT_BEFORE_GIVEN=1 ;;
		-h|--help)         sed -n '2,51p' "$0" | cut -c3-; exit 0 ;;
		*)                 ccaa__die 1 "unknown argument: $arg" ;;
	esac
done

[ -n "$CHAIN" ] || ccaa__die 1 "--chain=<mainnet-a|testnet-a|...> is required"
for tool in $CCAA_REQUIRED_TOOLS; do
	command -v "$tool" >/dev/null 2>&1 || ccaa__die 1 "required tool not on PATH: $tool"
done

if [ "$PREFIX_GIVEN" -eq 1 ] && [ "$SOURCE_GIVEN" -eq 1 ]; then
	ccaa__die 1 "give exactly one of --memo-prefix and --anchor-source, not both"
fi
if [ "$PREFIX_GIVEN" -eq 0 ] && [ "$SOURCE_GIVEN" -eq 0 ]; then
	ccaa__die 1 "give one of --memo-prefix=fya<S>c<N> and --anchor-source=<file>"
fi
if [ "$SOURCE_GIVEN" -eq 1 ]; then
	PREFIX="$(ccaa__read_anchor_source "$SOURCE_FILE")" \
		|| ccaa__die 1 "--anchor-source is not one JSON value with integer schema_version and observations_branch.cycle_number_observed (each >= 1): $SOURCE_FILE"
fi
ccaa__valid_prefix "$PREFIX" || ccaa__die 1 "the memo prefix must be fya<digits>c<digits>, got: $PREFIX"

if [ "$ACTOR_GIVEN" -eq 0 ]; then
	ACTOR_FILE="${FY_CONFIG_DIR:-$CCAA_DEFAULT_CONFIG_DIR}/$CCAA_ACTOR_FILE_NAME"
	[ -r "$ACTOR_FILE" ] || ccaa__die 1 "no --actor and the actor file is not readable: $ACTOR_FILE"
	ACTOR="$(head -n 1 "$ACTOR_FILE" | tr -d ' \t\r')"
fi
ccaa__valid_actor "$ACTOR" || ccaa__die 1 "the actor is not an account name (1-12 of ${CCAA_ACTOR_CHARS})"

# ---- libraries and profile ----------------------------------------------------
for lib in a-chain-profile.sh anchor-history-read.sh; do
	[ -r "${REPO_ROOT}/scripts/lib/${lib}" ] \
		|| ccaa__die 2 "required library not readable: scripts/lib/${lib}"
done
# shellcheck source=scripts/lib/a-chain-profile.sh
. "${REPO_ROOT}/scripts/lib/a-chain-profile.sh" || { ccaa__log "cannot load a-chain-profile.sh"; exit 2; }
# shellcheck source=scripts/lib/anchor-history-read.sh
. "${REPO_ROOT}/scripts/lib/anchor-history-read.sh" || { ccaa__log "cannot load anchor-history-read.sh"; exit 2; }

ROLE="$(acp_role_of_chain "$CHAIN" 2>/dev/null)" || ccaa__die 1 "unknown --chain: $CHAIN"
NOT_BEFORE_EPOCH=""
if [ "$NOT_BEFORE_GIVEN" -eq 1 ]; then
	NOT_BEFORE_EPOCH="$(ahr_utc_to_epoch "$NOT_BEFORE")" \
		|| ccaa__die 1 "--not-before is not a UTC time YYYY-MM-DDTHH:MM:SS: $NOT_BEFORE"
fi
PROFILE="$(acp_profile_name "$ROLE")" || ccaa__die 2 "no usable A-Chain profile for role $ROLE"
CHAIN_ID="$(acp_expected_chain_id "$ROLE")" || ccaa__die 2 "profile $PROFILE has no usable chain_id"
BASES="$(ahr_select_bases "$ROLE" "" 0)" || ccaa__die 2 "profile $PROFILE has no usable history_bases"
[ -n "$BASES" ] || ccaa__die 2 "profile $PROFILE has no usable history_bases"

# ---- one base ------------------------------------------------------------------
# ccaa__check_base <base> — sets, never prints:
#   CCAA_OUTCOME   present | unreadable | wait | absent
#   CCAA_FLOOR     (absent) the floor memo prefix
#   CCAA_LIB_TIME  (absent, with --not-before) the LIB time as served
#   CCAA_PRESENT_LINE  (present) the stdout line
CCAA_OUTCOME=""
CCAA_FLOOR=""
CCAA_LIB_TIME=""
CCAA_PRESENT_LINE=""

# ccaa__is_one_json_object <text> — rc 0 only when the WHOLE text is exactly one
# JSON value and that value is an object. Two values (in any order), trailing
# text, an empty answer or a non-object are all rc 1 (jq -e fails on a parse
# error too), so nothing that is not one library answer is ever read.
ccaa__is_one_json_object() {
	printf '%s' "${1:-}" | jq -s -e 'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1
}

# ccaa__lib_time <base> — sets CCAA_LIB_TIME and CCAA_LIB_EPOCH; rc 1 when unreadable.
CCAA_LIB_EPOCH=""
ccaa__lib_time() {
	local times
	times="$(ahr_chain_times "$1")" || return 1
	ccaa__is_one_json_object "$times" || return 1
	CCAA_LIB_TIME="$(printf '%s' "$times" | jq -r 'select(type == "object" and (.last_irreversible_block_time | type) == "string") | .last_irreversible_block_time')"
	[ -n "$CCAA_LIB_TIME" ] || return 1
	CCAA_LIB_EPOCH="$(ahr_utc_to_epoch "$CCAA_LIB_TIME")" || return 1
}

# ccaa__read_verdict <json> <base> — sets CCAA_OUTCOME (and its fields) from the
# one line ahr_find_cycle_anchor printed. Any shape it does not know is unreadable.
ccaa__read_verdict() {
	local kind verdict trx block ts
	local hex='[0123456789abcdef]'
	local tsch='[0123456789TZ:.-]'
	if ! ccaa__is_one_json_object "$1"; then
		ccaa__log "$2: the cycle-anchor reader did not answer exactly one JSON object"
		CCAA_OUTCOME=unreadable; return 0
	fi
	kind="$(printf '%s' "$1" | jq -r --arg hex "$hex" --arg tsch "$tsch" '
		select(type == "object")
		| if (.verdict == "found" or .verdict == "found_later")
		     and (.trx_id | type) == "string" and (.trx_id | test("\\A" + $hex + "{64}\\z"))
		     and (.block_num | type) == "number" and (.block_num == (.block_num | floor)) and .block_num >= 0
		     and (.timestamp | type) == "string" and (.timestamp | test("\\A" + $tsch + "+\\z"))
		  then ["present", .verdict, .trx_id, (.block_num | tostring), .timestamp] | join(" ")
		  elif .verdict == "clear" and (.floor | type) == "string"
		     and (.floor | test("\\Afya[0123456789]+c[0123456789]+\\z"))
		  then ["absent", .floor] | join(" ")
		  else empty end' 2>/dev/null)" || kind=""
	read -r kind verdict trx block ts <<EOF
$kind
EOF
	case "$kind" in
		present)
			CCAA_OUTCOME=present
			CCAA_PRESENT_LINE="PRESENT prefix=$PREFIX verdict=$verdict trx_id=$trx block_num=$block timestamp=$ts base=$2" ;;
		absent)
			CCAA_OUTCOME=absent
			CCAA_FLOOR="$verdict" ;;
		*)
			if printf '%s' "$1" | jq -e 'select(type == "object" and .verdict == "clear" and .floor == null)' >/dev/null 2>&1; then
				ccaa__log "$2: the history ended without showing a floor (the previous cycle's anchor): absence is not established"
			else
				ccaa__log "$2: the cycle-anchor reader answered in a shape this check does not accept"
			fi
			CCAA_OUTCOME=unreadable ;;
	esac
}

ccaa__check_base() {
	local base="$1" observed verdict
	CCAA_OUTCOME=""; CCAA_FLOOR=""; CCAA_LIB_TIME=""; CCAA_PRESENT_LINE=""
	if observed="$(ahr_observed_chain_id "$base")"; then
		if [ "$observed" != "$CHAIN_ID" ]; then
			ccaa__log "$base: serves another chain_id than profile $PROFILE"
			CCAA_OUTCOME=unreadable; return 0
		fi
	elif [ "$NOT_BEFORE_GIVEN" -eq 1 ]; then
		ccaa__log "$base: get_info is not served, so the irreversible block time cannot be read"
		CCAA_OUTCOME=unreadable; return 0
	fi
	if [ "$NOT_BEFORE_GIVEN" -eq 1 ]; then
		if ! ccaa__lib_time "$base"; then
			ccaa__log "$base: the irreversible block time cannot be read"
			CCAA_OUTCOME=unreadable; return 0
		fi
		if ! [ "$CCAA_LIB_EPOCH" -gt "$NOT_BEFORE_EPOCH" ]; then
			ccaa__log "$base: LIB time $CCAA_LIB_TIME is not past $NOT_BEFORE yet"
			CCAA_OUTCOME="wait"; return 0
		fi
	fi
	if ! ahr_index_fresh "$base" "$AHR_INDEX_MAX_LAG_BLOCKS"; then
		ccaa__log "$base: the history index is stale or its health cannot be read"
		CCAA_OUTCOME=unreadable; return 0
	fi
	if ! verdict="$(ahr_find_cycle_anchor "$base" "$ACTOR" "$PREFIX")"; then
		ccaa__log "$base: the history cannot be read"
		CCAA_OUTCOME=unreadable; return 0
	fi
	ccaa__read_verdict "$verdict" "$base"
}

# ---- combine -------------------------------------------------------------------
# ccaa__combine_outcomes <absent> <wait> <unreadable> — prints the exit code
# (present never gets here: it ends the run at once with 10).
ccaa__combine_outcomes() {
	if [ "$3" -gt 0 ]; then printf '3\n'
	elif [ "$2" -gt 0 ]; then printf '4\n'
	elif [ "$1" -gt 0 ]; then printf '0\n'
	else printf '2\n'; fi
}

N_BASES=0; N_ABSENT=0; N_WAIT=0; N_UNREADABLE=0
FIRST_FLOOR=""; FIRST_LIB_TIME=""
for base in $BASES; do
	N_BASES=$((N_BASES + 1))
	ccaa__check_base "$base"
	case "$CCAA_OUTCOME" in
		present)    printf '%s\n' "$CCAA_PRESENT_LINE"; exit 10 ;;
		unreadable) N_UNREADABLE=$((N_UNREADABLE + 1)) ;;
		wait)       N_WAIT=$((N_WAIT + 1)) ;;
		absent)     N_ABSENT=$((N_ABSENT + 1))
		            if [ "$N_ABSENT" -eq 1 ]; then FIRST_FLOOR="$CCAA_FLOOR"; FIRST_LIB_TIME="$CCAA_LIB_TIME"; fi ;;
		*)          N_UNREADABLE=$((N_UNREADABLE + 1)) ;;
	esac
done

RC="$(ccaa__combine_outcomes "$N_ABSENT" "$N_WAIT" "$N_UNREADABLE")"
if [ "$RC" -eq 0 ] && [ "$N_ABSENT" -ne "$N_BASES" ]; then RC=3; fi
case "$RC" in
	0)
		LINE="ABSENT prefix=$PREFIX profile=$PROFILE floor=$FIRST_FLOOR bases=$N_BASES"
		if [ "$NOT_BEFORE_GIVEN" -eq 1 ]; then LINE="$LINE not_before=$NOT_BEFORE lib_time=$FIRST_LIB_TIME"; fi
		printf '%s\n' "$LINE"
		exit 0 ;;
	4) ccaa__die 4 "$NOT_BEFORE is not yet past the irreversible block in every base: wait" ;;
	3) ccaa__die 3 "absence is not established (a base was unreadable, stale or showed no floor): do not treat this as absent" ;;
	*) ccaa__die 2 "no history base to ask" ;;
esac
