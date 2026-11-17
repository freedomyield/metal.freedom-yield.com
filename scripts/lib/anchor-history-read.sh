#!/usr/bin/env bash
# scripts/lib/anchor-history-read.sh — the ONE read path from an A-Chain
# history service to a normalized anchor transaction.
#
# CHAIN: none — READ ONLY. Every request here is a history/chain READ
#        (Hyperion /v2/history/get_actions, /v2/history/get_transaction,
#        /v2/health, /v1/history/get_transaction, /v1/chain/get_block,
#        /v1/chain/get_info). There is no push/send path in this file and
#        tests/anchor-history-read/ greps it to keep it that way.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no broadcast).
#
# WHY A SHARED LIBRARY
#   scripts/gen-anchor-receipt.sh resolves the anchor tx AFTER the
#   irreversible broadcast. scripts/check-anchor-history-reachable.sh must
#   prove BEFORE signing that the same resolution will work (plan P3). If
#   the two carried their own copies of the request/normalization code, the
#   pre-broadcast check could pass on a path the receipt generator does not
#   take. Both source this file, so the check exercises the exact code the
#   receipt will run.
#
# REQUIRES scripts/lib/a-chain-profile.sh to be sourced first (history bases
# come from the selected chain profile, never from a literal).
#
# INTERFACE
#   ahr_select_bases <role> <rpc_override> <allow_unlisted 0|1>
#       One history base per line. With an empty override: the selected
#       profile's history_bases, in order. With an override: it must be one
#       of history_bases EXACTLY; otherwise it is refused, unless
#       allow_unlisted=1 AND role=testnet (rehearsal escape hatch, loud
#       WARN). allow_unlisted is refused for the mainnet role: a mainnet
#       receipt is only ever verified against a reviewed, committed history
#       base. rc: 0 ok, 1 refused override, 2 profile unavailable.
#   ahr_resolve_tx <base> <tx_id> <actor>
#       Prints the normalized tx JSON:
#         {id, block_num, block_time, block_id (64hex|null), via,
#          actions: [{act:{account,name,authorization,data:{memo}}}]}
#       Tries, in order, and stops at the first that yields >= 1 action:
#         1. Hyperion GET /v2/history/get_actions?account=<actor>&limit=50&sort=desc
#            (skipped when actor is empty) — the path gen-anchor-receipt.sh
#            has always preferred (account-scoped, reliably indexed)
#         2. Hyperion GET /v2/history/get_transaction?id=<tx>
#         3. EOSIO history plugin POST /v1/history/get_transaction — the
#            response carries `traces` (NOT `actions`; the pre-2026-09-30
#            fallback looked for `.actions` and could never match). Only
#            traces whose receipt.receiver == act.account are the executed
#            actions; the rest are require_recipient notifications.
#       rc: 0 resolved, 3 not resolvable at this base.
#   ahr_probe_actions <base> <actor>
#       Liveness probe of request 1 above with limit=1. Prints the newest
#       action normalized as {block_num, block_id|null} (or {} when the
#       account has no action yet). rc 0 iff the base answered a JSON object
#       with an `actions` array; 3 otherwise.
#   ahr_block_id <base> <block_num>
#       POST /v1/chain/get_block; prints the block id (64 hex) iff the
#       response's block_num equals the requested one. rc 0 / 1.
#   ahr_observed_chain_id <base>
#       POST /v1/chain/get_info; prints chain_id (64 hex) if the base serves
#       it. rc 0 / 1 (not served — a Hyperion-only base may not).
#
#   ahr_find_cycle_anchor <base> <actor> <prefix>
#       Scans <actor>'s eosio.token transfers newest first (pages of
#       AHR_SCAN_PAGE_LIMIT, at most AHR_SCAN_MAX_PAGES) and decides ONE anchor
#       prefix (fya<schema>c<cycle>). Only transfers FROM <actor> whose memo
#       starts with the anchor shape count; schema and cycle are compared as
#       numbers. Prints one JSON line
#         {verdict, trx_id, block_num, timestamp, scanned, floor}
#       verdict: found (same cycle) | found_later (same schema, higher cycle) |
#       clear (a lower cycle ended the scan: floor = that memo's fya<S>c<M>;
#       or the history ran out: floor = null). trx_id/block_num/timestamp are
#       the matched entry's for found*, else null. scanned = entries read,
#       repeats across pages not counted. rc 0 decided; rc 3 unreadable
#       (stdout empty): bad input, curl failure, an unreadable page or entry,
#       entries out of order, or the page budget used up without a decision.
#   ahr_index_fresh <base> <max_lag_blocks>
#       GET <base>/v2/health. rc 0 when every health entry is OK and the head
#       and last indexed block (both present, head > 0) are within max_lag of
#       each other; rc 3 when stale, missing or unreadable. No stdout.
#   ahr_chain_times <base>
#       POST <base>/v1/chain/get_info. Prints
#         {"head_block_time":"...","last_irreversible_block_time":"..."}
#       (strings exactly as served). rc 0; rc 3 when unreadable or either
#       time is missing or not an ISO UTC time.
#   ahr_utc_to_epoch <iso>
#       YYYY-MM-DDTHH:MM:SS[.f(1-6 digits)][Z] (UTC) -> epoch seconds (the
#       fraction is cut off, not rounded). rc 0 / 3 (any other form).
#   ahr_epoch_to_utc <seconds>
#       Epoch seconds (digits only, at most 12) -> YYYY-MM-DDTHH:MM:SS, no Z.
#       rc 0 / 3. Both time functions are the one time helper (jq, no date(1)):
#       the result does not depend on TZ or locale.
#
# HTTP goes through `curl` on PATH (tests put a stub first on PATH).
# Bash 3.2 compatible.

AHR_MAX_TIME="${AHR_MAX_TIME:-15}"
AHR_HEX64='^[0-9a-f]{64}$'

# Check-A constants. Plain assignments on purpose: the environment cannot move
# them (the caller passes AHR_INDEX_MAX_LAG_BLOCKS to ahr_index_fresh itself).
AHR_SCAN_PAGE_LIMIT=100
AHR_SCAN_MAX_PAGES=10
# shellcheck disable=SC2034  # not read in this file: the callers (T2, T4) pass it to ahr_index_fresh
AHR_INDEX_MAX_LAG_BLOCKS=30
AHR_TRANSFER_FILTER=eosio.token:transfer
# ISO UTC time as the history services print it. Digits are listed, never a
# range: a range can match full-width digits under a Japanese locale.
AHR__UTC_RE='\A[0123456789]{4}-[0123456789]{2}-[0123456789]{2}T[0123456789]{2}:[0123456789]{2}:[0123456789]{2}(\.[0123456789]{1,6})?Z?\z'

ahr__warn() { printf 'anchor-history-read: %s\n' "$*" >&2; }

ahr_select_bases() {
	local role="${1:-}" override="${2:-}" allow="${3:-0}" rc prof
	if [ -z "$override" ]; then
		acp_history_bases "$role" || return 2
		return 0
	fi
	if acp_history_base_allowed "$role" "$override"; then
		printf '%s\n' "$override"
		return 0
	else
		rc=$?
	fi
	# rc 1 = "not in the list"; anything else = the profile itself refused.
	[ "$rc" -eq 1 ] || return 2
	prof="$(acp_profile_name "$role" 2>/dev/null || echo '?')"
	if [ "$allow" = "1" ] && [ "$role" = "testnet" ]; then
		ahr__warn "WARNING: --rpc=${override} is NOT in the history_bases of profile ${prof}; accepted only because --allow-unlisted-rpc was given (testnet rehearsal escape hatch)"
		printf '%s\n' "$override"
		return 0
	fi
	if [ "$allow" = "1" ]; then
		ahr__warn "refused: --allow-unlisted-rpc is testnet-only; a ${role} history base must be one of profile ${prof}'s history_bases (config/a-chain-profiles.json)"
		return 1
	fi
	ahr__warn "refused: --rpc=${override} is not one of profile ${prof}'s history_bases: $(acp_history_bases "$role" 2>/dev/null | tr '\n' ' ')"
	return 1
}

# jq program shared by both Hyperion paths: select this tx's actions and
# normalize. block_id is kept only when every action agrees on one 64-hex id.
# shellcheck disable=SC2016  # jq program: $tx/$via/$hex are jq variables
AHR__JQ_HYPERION='
[.actions[]? | select(.trx_id == $tx)] as $a
| if ($a | length) == 0 then empty else
  { id: $tx,
    block_num: ($a | first | .block_num),
    block_time: ($a | first | .timestamp),
    block_id: ([$a[] | .block_id // empty] | unique
               | if length == 1 and (.[0] | type == "string") and (.[0] | test($hex))
                 then .[0] else null end),
    via: $via,
    actions: [$a[] | {act: {account: .act.account, name: .act.name,
                            authorization: .act.authorization,
                            data: {memo: .act.data.memo}}}] }
  end'

# shellcheck disable=SC2016  # jq program: $tx/$hex are jq variables
AHR__JQ_V1='
select(type == "object" and .id == $tx)
| [.traces[]? | select(.receipt.receiver == .act.account)] as $t
| if ($t | length) == 0 then empty else
  { id: $tx,
    block_num: .block_num,
    block_time: .block_time,
    block_id: ([$t[] | .producer_block_id // empty] | unique
               | if length == 1 and (.[0] | type == "string") and (.[0] | test($hex))
                 then .[0] else null end),
    via: "v1/history/get_transaction",
    actions: [$t[] | {act: {account: .act.account, name: .act.name,
                            authorization: .act.authorization,
                            data: {memo: .act.data.memo}}}] }
  end'

ahr__norm() {
	# ahr__norm <jq-program> <tx> <via> — stdin: response body
	local out
	out="$(jq -c --arg tx "$2" --arg via "$3" --arg hex "$AHR_HEX64" "$1" 2>/dev/null)" || return 1
	[ -n "$out" ] || return 1
	printf '%s\n' "$out" | head -n 1
}

ahr_resolve_tx() {
	local base="${1:-}" tx="${2:-}" actor="${3:-}" body out
	[ -n "$base" ] && [ -n "$tx" ] || return 3
	if [ -n "$actor" ]; then
		body="$(curl -sSf --max-time "$AHR_MAX_TIME" \
			"${base}/v2/history/get_actions?account=${actor}&limit=50&sort=desc" 2>/dev/null || true)"
		if out="$(printf '%s' "$body" | ahr__norm "$AHR__JQ_HYPERION" "$tx" "v2/history/get_actions")"; then
			printf '%s\n' "$out"; return 0
		fi
	fi
	body="$(curl -sSf --max-time "$AHR_MAX_TIME" \
		"${base}/v2/history/get_transaction?id=${tx}" 2>/dev/null || true)"
	if out="$(printf '%s' "$body" | ahr__norm "$AHR__JQ_HYPERION" "$tx" "v2/history/get_transaction")"; then
		printf '%s\n' "$out"; return 0
	fi
	body="$(curl -sSf --max-time "$AHR_MAX_TIME" \
		-X POST -H 'content-type:application/json' \
		-d "{\"id\":\"${tx}\"}" \
		"${base}/v1/history/get_transaction" 2>/dev/null || true)"
	if out="$(printf '%s' "$body" | ahr__norm "$AHR__JQ_V1" "$tx" "v1/history/get_transaction")"; then
		printf '%s\n' "$out"; return 0
	fi
	return 3
}

ahr_probe_actions() {
	local base="${1:-}" actor="${2:-}" body out
	[ -n "$base" ] && [ -n "$actor" ] || return 3
	body="$(curl -sSf --max-time "$AHR_MAX_TIME" \
		"${base}/v2/history/get_actions?account=${actor}&limit=1&sort=desc" 2>/dev/null || true)"
	out="$(printf '%s' "$body" | jq -c --arg hex "$AHR_HEX64" '
		select(type == "object" and (.actions | type == "array"))
		| (.actions[0] // null) as $x
		| if $x == null then {} else
		    {block_num: $x.block_num,
		     block_id: (if ($x.block_id | type == "string") and ($x.block_id | test($hex)) then $x.block_id else null end)}
		  end' 2>/dev/null | head -n 1)"
	[ -n "$out" ] || return 3
	printf '%s\n' "$out"
}

ahr_block_id() {
	local base="${1:-}" bn="${2:-}" body id
	case "$bn" in ''|*[!0-9]*) return 1 ;; esac
	body="$(curl -sSf --max-time "$AHR_MAX_TIME" \
		-X POST -H 'content-type:application/json' \
		-d "{\"block_num_or_id\":${bn}}" \
		"${base}/v1/chain/get_block" 2>/dev/null || true)"
	id="$(printf '%s' "$body" | jq -r --argjson bn "$bn" \
		'select(type == "object" and .block_num == $bn) | .id // empty' 2>/dev/null | head -n 1)"
	printf '%s' "$id" | grep -Eq "$AHR_HEX64" || return 1
	printf '%s\n' "$id"
}

ahr_observed_chain_id() {
	local base="${1:-}" body cid
	body="$(curl -sSf --max-time "$AHR_MAX_TIME" -X POST \
		"${base}/v1/chain/get_info" 2>/dev/null || true)"
	cid="$(printf '%s' "$body" | jq -r 'select(type == "object") | .chain_id // empty' 2>/dev/null | head -n 1)"
	printf '%s' "$cid" | grep -Eq "$AHR_HEX64" || return 1
	printf '%s\n' "$cid"
}

# ---- check A: has this actor already inscribed this cycle's anchor? ----------
# Input forms are decided with enumerated characters only (no a-z / 0-9 ranges,
# no \d, no [[:digit:]]): a range matches full-width characters under a
# Japanese UTF-8 locale on macOS bash 3.2, and jq's \d does too.

ahr__valid_base() { case "${1:-}" in https://?*) return 0 ;; esac; return 1; }

ahr__is_digits() { case "${1:-}" in ''|*[!0123456789]*) return 1 ;; esac; return 0; }

ahr__valid_actor() {
	local a="${1:-}"
	[ -n "$a" ] && [ "${#a}" -le 12 ] || return 1
	case "$a" in *[!abcdefghijklmnopqrstuvwxyz12345.]*) return 1 ;; esac
	return 0
}

# ahr__prefix_parts <prefix> — prints "<schema> <cycle>" for fya<digits>c<digits>.
ahr__prefix_parts() {
	local p="${1:-}" rest schema cycle
	case "$p" in fya*c*) ;; *) return 1 ;; esac
	rest="${p#fya}"; schema="${rest%%c*}"; cycle="${rest#*c}"
	ahr__is_digits "$schema" && ahr__is_digits "$cycle" || return 1
	printf '%s %s\n' "$schema" "$cycle"
}

# ahr__fetch <url> — GET; body on stdout, rc 3 on any curl failure.
ahr__fetch() { curl -sSf --max-time "$AHR_MAX_TIME" "$1" 2>/dev/null || return 3; }

# ahr__actions_url <base> <actor> <page k> — page 0 carries no skip.
ahr__actions_url() {
	local url="${1}/v2/history/get_actions?account=${2}&filter=${AHR_TRANSFER_FILTER}&sort=desc&limit=${AHR_SCAN_PAGE_LIMIT}"
	[ "$3" -ge 1 ] && url="${url}&skip=$(($3 * AHR_SCAN_PAGE_LIMIT))"
	printf '%s' "$url"
}

# jq program for ONE page of get_actions (history shape -> page state). Args:
# $actor, $s / $m (the prefix's schema and cycle digits), $seen (global_sequence
# numbers of earlier pages). Prints {ok:false}, or
# {ok, decided, raw, added, seen, result}. Nothing is skipped: an entry that
# cannot be read makes the whole page not ok. The scan stops at the first
# decision; entries older than it are not read.
# shellcheck disable=SC2016  # jq program: $actor/$s/$m/$seen are jq variables
AHR__JQ_SCAN_PAGE='
def dnorm: if test("\\A0+\\z") then "0" else sub("\\A0+"; "") end;
def dcmp($a; $b):
  ($a | dnorm) as $x | ($b | dnorm) as $y
  | if ($x | length) != ($y | length) then ($x | length) - ($y | length)
    elif $x < $y then -1 elif $x > $y then 1 else 0 end;
def entry_ok:
  type == "object" and (.act | type) == "object"
  and (.act.account | type) == "string" and (.act.name | type) == "string"
  and (.global_sequence | type) == "number"
  and (if .act.account == "eosio.token" and .act.name == "transfer"
       then (.act.data | type) == "object" and (.act.data.from | type) == "string"
            and (.act.data.memo | type) == "string"
       else true end);
def memo_head:
  [.act.data.memo | capture("\\Afya(?<s>[0123456789]+)c(?<m>[0123456789]+)(?:[^0123456789]|\\z)")] | first;
def found_ok:
  (.trx_id | type) == "string" and (.block_num | type) == "number" and (.timestamp | type) == "string";
def decide($actor; $s; $m):
  if .act.account == "eosio.token" and .act.name == "transfer" and .act.data.from == $actor
  then (memo_head) as $h
    | if $h == null or dcmp($h.s; $s) != 0 then null
      else dcmp($h.m; $m) as $c
        | if $c < 0 then {verdict: "clear", trx_id: null, block_num: null, timestamp: null,
                          floor: ("fya" + $h.s + "c" + $h.m)}
          else {verdict: (if $c == 0 then "found" else "found_later" end),
                trx_id: .trx_id, block_num: .block_num, timestamp: .timestamp, floor: null}
          end
      end
  else null end;
if type != "object" or (.actions | type) != "array" then {ok: false}
else .actions as $acts
  | reduce range(0; $acts | length) as $i
      ({ok: true, decided: false, prev: null, added: 0, seen: $seen, result: null};
       if .decided or (.ok | not) then .
       else $acts[$i] as $e
         | if ($e | entry_ok | not) then .ok = false
           elif .prev != null and $e.global_sequence >= .prev then .ok = false
           else .prev = $e.global_sequence
             | if any(.seen[]; . == $e.global_sequence) then .
               else .added += 1 | .seen += [$e.global_sequence]
                 | ($e | decide($actor; $s; $m)) as $r
                 | if $r == null then .
                   elif $r.verdict != "clear" and ($r | found_ok | not) then .ok = false
                   else .decided = true | .result = $r end
               end
           end
       end)
  | if .ok then {ok, decided, raw: ($acts | length), added, seen, result} else {ok: false} end
end'

# ahr__one_json_value — stdin: a response body. Prints it as one compact line
# only when the WHOLE body is exactly one JSON value; zero values, two or more,
# or anything after the value (a broken character included) is rc 3. Every
# check-A reader goes through this, so a second value or trailing text can
# never hide a match or change a verdict.
ahr__one_json_value() {
	local out
	out="$(jq -c -s 'if length == 1 then .[0] else empty end' 2>/dev/null)" || return 3
	[ -n "$out" ] || return 3
	printf '%s\n' "$out"
}

# ahr__scan_page <body> <actor> <schema> <cycle> <seen-json> — one state line.
ahr__scan_page() {
	local one out
	one="$(printf '%s' "$1" | ahr__one_json_value)" || return 3
	out="$(printf '%s' "$one" | jq -c --arg actor "$2" --arg s "$3" --arg m "$4" --argjson seen "$5" \
		"$AHR__JQ_SCAN_PAGE" 2>/dev/null)" || return 3
	[ -n "$out" ] || return 3
	printf '%s\n' "$out"
}

# ahr__emit_verdict <state-json> <scanned> — the decided page's verdict line.
ahr__emit_verdict() {
	printf '%s' "$1" | jq -c --argjson n "$2" \
		'.result | {verdict, trx_id, block_num, timestamp, scanned: $n, floor}'
}

# ahr__emit_exhausted <scanned> — the history ended with no floor and no match.
ahr__emit_exhausted() {
	jq -nc --argjson n "$1" \
		'{verdict: "clear", trx_id: null, block_num: null, timestamp: null, scanned: $n, floor: null}'
}

ahr_find_cycle_anchor() {
	local base="${1:-}" actor="${2:-}" prefix="${3:-}" parts schema cycle
	local k=0 body st ok decided raw added scanned=0 seen='[]'
	ahr__valid_base "$base" && ahr__valid_actor "$actor" || return 3
	parts="$(ahr__prefix_parts "$prefix")" || return 3
	schema="${parts% *}"; cycle="${parts#* }"
	while [ "$k" -lt "$AHR_SCAN_MAX_PAGES" ]; do
		body="$(ahr__fetch "$(ahr__actions_url "$base" "$actor" "$k")")" || return 3
		st="$(ahr__scan_page "$body" "$actor" "$schema" "$cycle" "$seen")" || return 3
		read -r ok decided raw added <<< "$(printf '%s' "$st" | jq -r '"\(.ok) \(.decided) \(.raw) \(.added)"')"
		[ "$ok" = true ] || return 3
		scanned=$((scanned + added))
		if [ "$decided" = true ]; then
			ahr__emit_verdict "$st" "$scanned" || return 3
			return 0
		fi
		if [ "$raw" -lt "$AHR_SCAN_PAGE_LIMIT" ]; then
			ahr__emit_exhausted "$scanned" || return 3
			return 0
		fi
		seen="$(printf '%s' "$st" | jq -c '.seen')"
		k=$((k + 1))
	done
	return 3
}

# shellcheck disable=SC2016  # jq program: $n is a jq variable
AHR__JQ_FRESH='
if type != "object" or (.health | type) != "array" or (.health | length) == 0 then false
else ([.health[] | .service_data? | objects | .head_block_num? | numbers] | max) as $h
   | ([.health[] | .service_data? | objects | .last_indexed_block? | numbers] | max) as $l
   | (.health | all(type == "object" and .status == "OK"))
     and $h != null and $l != null and $h > 0
     and ($h - $l) <= $n and ($l - $h) <= $n
end'

# ahr_index_fresh: max_lag may have leading zeros (read as decimal) and at most
# 9 digits; anything longer is refused rather than wrapped around.
ahr_index_fresh() {
	local base="${1:-}" lag="${2:-}" body one
	ahr__valid_base "$base" || return 3
	ahr__is_digits "$lag" && [ "${#lag}" -le 9 ] || return 3
	body="$(ahr__fetch "${base}/v2/health")" || return 3
	one="$(printf '%s' "$body" | ahr__one_json_value)" || return 3
	printf '%s' "$one" | jq -e --argjson n "$((10#$lag))" "$AHR__JQ_FRESH" >/dev/null 2>&1 || return 3
}

ahr_chain_times() {
	local base="${1:-}" body one out
	ahr__valid_base "$base" || return 3
	body="$(curl -sSf --max-time "$AHR_MAX_TIME" -X POST \
		"${base}/v1/chain/get_info" 2>/dev/null)" || return 3
	one="$(printf '%s' "$body" | ahr__one_json_value)" || return 3
	out="$(printf '%s' "$one" | jq -c --arg re "$AHR__UTC_RE" '
		select(type == "object"
		       and (.head_block_time | type) == "string" and (.head_block_time | test($re))
		       and (.last_irreversible_block_time | type) == "string"
		       and (.last_irreversible_block_time | test($re)))
		| {head_block_time, last_irreversible_block_time}' 2>/dev/null)"
	[ -n "$out" ] || return 3
	printf '%s\n' "$out"
}

# ahr_utc_to_epoch <iso>: the fraction and the Z are cut off, the rest goes
# through jq's fromdateiso8601 (timegm: TZ-independent). The result must print
# back as the same time, so an impossible date (Feb 30) is refused, not rolled.
ahr_utc_to_epoch() {
	local out
	out="$(jq -nr --arg s "${1:-}" --arg re "$AHR__UTC_RE" '
		$s | select(test($re))
		| sub("\\.[0123456789]+"; "") | sub("Z\\z"; "") | (. + "Z") as $t
		| ($t | fromdateiso8601) as $e
		| select(($e | todate) == $t) | $e' 2>/dev/null | head -n 1)"
	[ -n "$out" ] || return 3
	printf '%s\n' "$out"
}

ahr_epoch_to_utc() {
	local sec="${1:-}" out
	ahr__is_digits "$sec" && [ "${#sec}" -le 12 ] || return 3
	out="$(jq -nr --argjson e "$((10#$sec))" '$e | todate | sub("Z\\z"; "")' 2>/dev/null)" || return 3
	[ -n "$out" ] || return 3
	printf '%s\n' "$out"
}
