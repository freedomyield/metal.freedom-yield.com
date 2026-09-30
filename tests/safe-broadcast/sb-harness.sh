#!/usr/bin/env bash
# tests/safe-broadcast/sb-harness.sh — shared hermetic harness for the
# bin/safe-broadcast profile suites (sourced; NOT a suite itself — its name
# does not match the runner's test-*.sh glob).
#
# CHAIN: none. Every network-facing binary the wrapper calls is a stub on
#        PATH: `proton` (chain:set / chain:info / transaction:push) and `curl`
#        (history lookups, health probe). The stubs only print canned JSON and
#        append one line per call to a call log. sbh_init refuses to continue
#        unless `command -v proton` and `command -v curl` resolve to the stubs,
#        and HOME is a throwaway fixture directory holding no key, so even a
#        mis-resolved real proton-cli would have nothing to sign with.
#
# What it provides
#   sbh_init                  build $SBH_T (fixtures, stubs, HOME, config)
#   sbh_tree <dir> <wrapper> [<profiles.json>]
#                             lay out a minimal repo tree (bin/, scripts/lib/,
#                             config/) so a wrapper copy resolves the library
#                             and a FIXTURE profile file relative to itself
#                             (the library has no env var for its file path)
#   sbh_token <json|''>       fresh operator token with that content
#   sbh_reset                 clean state for the next scenario: pristine
#                             proton-cli.json, empty audit/call logs, no
#                             history delays (set token/delays AFTER this)
#   sbh_run <name> <stdin> <wrapper> [VAR=value ...] -- <args ...>
#                             run one scenario; leaves SBH_RC and the files
#                             $SBH_T/out, err, audit.log, calls.log behind
#   sbh_block <name>          the normalized, comparable record of the last
#                             run (rc, stdout, stderr, audit log, call log)
#
# Stub controls (environment of one sbh_run)
#   STUB_CHAIN_ID=<hex>       chain:info answers this chain_id (default: the
#                             real id of the chain the fixture config's
#                             currentChain names — proton / proton-test)
#   STUB_CHAIN_INFO_RAW=<s>   chain:info prints <s> verbatim
#   STUB_CHAINSET_RC=<n>      chain:set exits <n>
#   STUB_CHAINSET_NOWRITE=1   chain:set does not update currentChain
#   STUB_PUSH_MODE=processed|idfield|idonly|fail|noid
#   STUB_HEALTH_FAIL=1        <base>/v2/health fails
#   History fixtures: $SBH_T/hist/v1/<txid>.json (POST /v1/history/
#   get_transaction), $SBH_T/hist/v2/<txid>.json (GET /v2/history/
#   get_transaction?id=), $SBH_T/hist/delay/<txid> = number of lookups that
#   answer "not found" first.

# shellcheck disable=SC2034  # these constants are used by the suites that source this file
SBH_TXID="f00d0000f00d0000f00d0000f00d0000f00d0000f00d0000f00d0000f00d0000"
SBH_XPR_MAIN_CID="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
SBH_XPR_TEST_CID="71ee83bcf52142d61019d95f9cc5427ba6a0d7ff8accd9e2088ae2abeaf3d3dd"
SBH_R16="1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
SBH_CYCLE2="$(printf 'aaaa2222%.0s' 1 2 3 4 5 6 7 8)"
SBH_CYCLE4="$(printf 'bbbb4444%.0s' 1 2 3 4 5 6 7 8)"
SBH_UPD_SAME="$(printf 'cccc5555%.0s' 1 2 3 4 5 6 7 8)"
SBH_UPD_DIFF="$(printf 'dddd6666%.0s' 1 2 3 4 5 6 7 8)"
SBH_NOACT="$(printf 'eeee7777%.0s' 1 2 3 4 5 6 7 8)"
SBH_ZERO="0000000000000000000000000000000000000000000000000000000000000000"

# The proton-cli config path, exactly as conf/env-paths derive it (the same
# rule bin/safe-broadcast uses).
sbh_cfg_path() {
	case "$(uname -s)" in
		Darwin) printf '%s' "$HOME/Library/Preferences/@proton/cli-nodejs/proton-cli.json" ;;
		*)      printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/@proton/cli-nodejs/proton-cli.json" ;;
	esac
}

sbh_init() {
	SBH_T="$(mktemp -d -t sbh.XXXXXX)"
	SBH_T="$(cd "$SBH_T" && pwd -P)"
	mkdir -p "$SBH_T/stub" "$SBH_T/home" "$SBH_T/hist/v1" "$SBH_T/hist/v2" "$SBH_T/hist/delay"
	export SBH_T
	export SBH_CALLS="$SBH_T/calls.log"
	export FYD_BROADCAST_TOKEN_FILE="$SBH_T/token"
	export FYD_BROADCAST_AUDIT_LOG="$SBH_T/audit.log"
	export HOME="$SBH_T/home"
	unset XDG_CONFIG_HOME FYD_A_CHAIN_PROFILE_MAINNET FYD_A_CHAIN_PROFILE_TESTNET \
		FYD_MAINNET_CHAIN_ID FYD_TESTNET_CHAIN_ID XPR_TESTNET_RPC FYD_SAFE_BROADCAST \
		FYD_SB_CONFIRM_ATTEMPTS FYD_SB_CONFIRM_INTERVAL

	# Pristine proton-cli.json: what `conf` persists on first run — the
	# compiled-in networks copied under `networks`, no `endpoints` override,
	# an EMPTY privateKeys list (there is no key anywhere in this harness).
	cat > "$SBH_T/proton-cli.pristine.json" <<'JSON'
{"privateKeys":[],"tryKeychain":false,"isLocked":false,
 "networks":[
  {"chain":"proton","endpoints":["https://rpc.api.mainnet.metalx.com","https://proton.cryptolions.io","https://proton.eosusa.io"]},
  {"chain":"proton-test","endpoints":["https://rpc.api.testnet.metalx.com","https://proton-testnet.eoscafeblock.com","https://test.proton.eosusa.io"]}],
 "currentChain":"proton-test"}
JSON

	# ---- stub: proton ----
	cat > "$SBH_T/stub/proton" <<'STUB'
#!/usr/bin/env bash
# Test stub for proton-cli (tests/safe-broadcast/sb-harness.sh). Never signs.
cfg() {
	case "$(uname -s)" in
		Darwin) printf '%s' "$HOME/Library/Preferences/@proton/cli-nodejs/proton-cli.json" ;;
		*)      printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/@proton/cli-nodejs/proton-cli.json" ;;
	esac
}
case "$1" in
	chain:set)
		echo "proton chain:set $2" >> "$SBH_CALLS"
		[ "${STUB_CHAINSET_RC:-0}" = "0" ] || exit "$STUB_CHAINSET_RC"
		c="$(cfg)"
		if [ "${STUB_CHAINSET_NOWRITE:-0}" != "1" ] && [ -f "$c" ]; then
			t="$(mktemp)"; jq --arg c "$2" '.currentChain = $c' "$c" > "$t" && mv "$t" "$c"
		fi
		exit 0 ;;
	chain:info)
		echo "proton chain:info" >> "$SBH_CALLS"
		if [ -n "${STUB_CHAIN_INFO_RAW:-}" ]; then printf '%s\n' "$STUB_CHAIN_INFO_RAW"; exit 0; fi
		cid="${STUB_CHAIN_ID:-}"
		if [ -z "$cid" ]; then
			cc="$(jq -r '.currentChain // empty' "$(cfg)" 2>/dev/null)"
			case "$cc" in
				proton) cid="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0" ;;
				*)      cid="71ee83bcf52142d61019d95f9cc5427ba6a0d7ff8accd9e2088ae2abeaf3d3dd" ;;
			esac
		fi
		printf '{"chain_id":"%s","head_block_num":1}\n' "$cid"
		exit 0 ;;
	transaction:push)
		echo "proton transaction:push" >> "$SBH_CALLS"
		tx="f00d0000f00d0000f00d0000f00d0000f00d0000f00d0000f00d0000f00d0000"
		case "${STUB_PUSH_MODE:-processed}" in
			processed) printf '{"transaction_id":"%s","processed":{"id":"%s","block_num":42,"receipt":{"status":"executed"}}}\n' "$tx" "$tx" ;;
			idfield)   printf '{"id":"%s"}\n' "$tx" ;;
			idonly)    printf '{"transaction_id":"%s"}\n' "$tx" ;;
			noid)      printf '{}\n' ;;
			fail)      echo "Error: assertion failure with message: stub" >&2; exit 1 ;;
		esac
		exit 0 ;;
	*)
		echo "proton $*" >> "$SBH_CALLS"
		exit 0 ;;
esac
STUB

	# ---- stub: curl ----
	cat > "$SBH_T/stub/curl" <<'STUB'
#!/usr/bin/env bash
# Test stub for curl (tests/safe-broadcast/sb-harness.sh). Offline.
method=GET; body=""; url=""; prev=""
for a in "$@"; do
	case "$prev" in
		-X) method="$a" ;;
		-d) body="$a"; [ "$method" = "GET" ] && method=POST ;;
	esac
	case "$a" in https://*|http://*) url="$a" ;; esac
	prev="$a"
done
# full argv too: headers / flags are part of the request being pinned
echo "curl $method $url $body | argv: $*" >> "$SBH_CALLS"
serve() { # <id> <dir>
	local id="$1" d="$2" n
	if [ -f "$SBH_T/hist/delay/$id" ]; then
		n="$(cat "$SBH_T/hist/delay/$id")"
		if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$SBH_T/hist/delay/$id"; return 1; fi
	fi
	[ -f "$SBH_T/hist/$d/$id.json" ] || return 1
	cat "$SBH_T/hist/$d/$id.json"
}
case "$url" in
	*/v1/history/get_transaction)
		id="$(printf '%s' "$body" | grep -oE '"id":"[a-f0-9]{64}"' | grep -oE '[a-f0-9]{64}')"
		serve "$id" v1 || echo '{}'
		exit 0 ;;
	*/v2/history/get_transaction\?id=*)
		id="${url##*id=}"
		serve "$id" v2 || exit 22
		exit 0 ;;
	*/v2/health)
		[ "${STUB_HEALTH_FAIL:-0}" = "1" ] && exit 7
		echo '{"health":[{"service":"Elasticsearch","status":"OK"}]}'
		exit 0 ;;
esac
echo '{}'
exit 0
STUB
	chmod +x "$SBH_T/stub/proton" "$SBH_T/stub/curl"
	export PATH="$SBH_T/stub:$PATH"
	if [ "$(command -v proton)" != "$SBH_T/stub/proton" ] || [ "$(command -v curl)" != "$SBH_T/stub/curl" ]; then
		echo "FATAL: proton/curl stubs are not first on PATH — refusing to run anything" >&2
		exit 1
	fi

	# ---- tx fixtures ----
	sbh_tx() { # <file> <account> <name> <data-json>
		printf '{"actions":[{"account":"%s","name":"%s","authorization":[{"actor":"metalfreedom","permission":"anchor"}],"data":%s}]}\n' \
			"$2" "$3" "$4" > "$SBH_T/$1"
	}
	sbh_tx tx-c3.json  eosio.token transfer '{"from":"metalfreedom","to":"fyhistory","quantity":"0.0001 XPR","memo":"fya1c3-test"}'
	sbh_tx tx-c4.json  eosio.token transfer '{"from":"metalfreedom","to":"fyhistory","quantity":"0.0001 XPR","memo":"fya1c4-test"}'
	sbh_tx tx-upd.json eosio       updateauth '{"account":"metalfreedom","permission":"anchor","parent":"active"}'
	sbh_tx tx-hex.json eosio.token transfer '"0011deadbeef"'
	echo '{}' > "$SBH_T/tx-empty.json"
	printf '{"dry_run":true,"target_chain":"mainnet-a","memo_prefix":"fya1c3"}\n' > "$SBH_T/dry-c3.json"
	printf '{"dry_run":true,"target_chain":"mainnet-a","memo_prefix":"fya1c4"}\n' > "$SBH_T/dry-c4.json"
	printf '{"dry_run":true,"target_chain":"testnet-a","memo_prefix":"fya1c3"}\n' > "$SBH_T/dry-wrongchain.json"
	printf '{"dry_run":true,"target_chain":"mainnet-a"}\n' > "$SBH_T/dry-noprefix.json"
	printf 'this is not json\n' > "$SBH_T/dry-text.txt"

	# ---- v1 (history plugin shape) evidence fixtures ----
	sbh_v1() { # <id> <traces-json-array> [extra-top-level-json-fields]
		printf '{"id":"%s","block_num":100,"traces":%s%s}\n' "$1" "$2" "${3:-}" > "$SBH_T/hist/v1/$1.json"
	}
	local tr_c3='{"act":{"account":"eosio.token","name":"transfer","data":{"memo":"fya1c3-test"}}}'
	local tr_c2='{"act":{"account":"eosio.token","name":"transfer","data":{"memo":"fya1c2-test"}}}'
	local tr_c4='{"act":{"account":"eosio.token","name":"transfer","data":{"memo":"fya1c4-test"}}}'
	sbh_v1 "$SBH_R16"    "[$tr_c3,$tr_c3]"
	sbh_v1 "$SBH_CYCLE2" "[$tr_c2,$tr_c2]"
	sbh_v1 "$SBH_CYCLE4" "[$tr_c4,$tr_c4,$tr_c4]"
	printf '{"id":"%s","block_num":5,"actions":[{"act":{"account":"eosio","name":"updateauth","data":{}}}]}\n' "$SBH_UPD_SAME" > "$SBH_T/hist/v1/$SBH_UPD_SAME.json"
	printf '{"id":"%s","block_num":6,"trx":{"trx":{"actions":[{"account":"eosio.token","name":"transfer","data":{"memo":"fya1c4-test"}}]}}}\n' "$SBH_UPD_DIFF" > "$SBH_T/hist/v1/$SBH_UPD_DIFF.json"
	printf '{"id":"%s","block_num":7,"traces":[],"trx":{"trx":{"actions":[]}}}\n' "$SBH_NOACT" > "$SBH_T/hist/v1/$SBH_NOACT.json"
}

# sbh_tree <dir> <wrapper-source> [<profiles.json>] — minimal repo tree.
sbh_tree() {
	local d="$1" w="$2" cfg="${3:-}" root
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
	mkdir -p "$d/bin" "$d/scripts/lib" "$d/config"
	cp "$w" "$d/bin/safe-broadcast"
	chmod +x "$d/bin/safe-broadcast"
	cp "$root/scripts/lib/require-keystore-home.sh" "$d/scripts/lib/"
	[ -f "$root/scripts/lib/a-chain-profile.sh" ] && cp "$root/scripts/lib/a-chain-profile.sh" "$d/scripts/lib/"
	[ -f "$root/scripts/lib/url-host.sh" ] && cp "$root/scripts/lib/url-host.sh" "$d/scripts/lib/"
	cp "${cfg:-$root/config/a-chain-profiles.json}" "$d/config/a-chain-profiles.json"
}

sbh_token() { printf '%s' "$1" > "$FYD_BROADCAST_TOKEN_FILE"; }

sbh_reset() {
	local c
	c="$(sbh_cfg_path)"
	mkdir -p "$(dirname "$c")"
	cp "$SBH_T/proton-cli.pristine.json" "$c"
	: > "$SBH_T/audit.log"
	: > "$SBH_CALLS"
	rm -f "$SBH_T/hist/delay/"*
}

# sbh_run <name> <stdin> <wrapper> [VAR=value ...] -- <args ...>
# The token is NOT reset here (callers set it with sbh_token right before).
sbh_run() {
	local stdin="$2" wrapper="$3"
	shift 3
	local envs=()
	while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
	[ "${1:-}" = "--" ] && shift
	(
		for e in ${envs[@]+"${envs[@]}"}; do export "${e?}"; done
		printf '%s' "$stdin" | bash "$wrapper" "$@"
	) > "$SBH_T/out" 2> "$SBH_T/err"
	SBH_RC=$?
}

# Normalize a file for comparison: temp root, timestamps, token age, invoker.
sbh_norm() {
	sed -e "s#${SBH_T}#<T>#g" \
	    -e 's#[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z#<TS>#g' \
	    -e 's#token expired ([0-9]*s#token expired (<N>s#g' \
	    -e "s#invoker=[^	]*#invoker=<U>#g" "$1"
}

sbh_block() {
	printf '=== %s\nrc=%s\n--- stdout\n' "$1" "$SBH_RC"
	sbh_norm "$SBH_T/out"
	printf -- '--- stderr\n'
	sbh_norm "$SBH_T/err"
	printf -- '--- audit\n'
	sbh_norm "$SBH_T/audit.log"
	printf -- '--- calls\n'
	sbh_norm "$SBH_CALLS"
}
