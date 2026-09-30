#!/usr/bin/env bash
# scripts/lib/anchor-history-read.sh — the ONE read path from an A-Chain
# history service to a normalized anchor transaction.
#
# CHAIN: none — READ ONLY. Every request here is a history/chain READ
#        (Hyperion /v2/history/get_actions, /v2/history/get_transaction,
#        /v1/history/get_transaction, /v1/chain/get_block,
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
# HTTP goes through `curl` on PATH (tests put a stub first on PATH).
# Bash 3.2 compatible.

AHR_MAX_TIME="${AHR_MAX_TIME:-15}"
AHR_HEX64='^[0-9a-f]{64}$'

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
