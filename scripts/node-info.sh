#!/usr/bin/env bash
# Metal Blockchain validator node のステータスを取得し、サイトの api/validator.json を更新する
# 前提: docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml up -d で metalgo が起動中
# network (mainnet / tahoe) は metalgo の info.getNetworkName から自動判定する
#
# 出力:
#   - 標準出力に NodeID / bootstrap 状況 / uptime
#   - public/api/validator.json を現在の network に応じた値で上書き(human readable)
set -euo pipefail

API="${METALGO_API:-http://localhost:9650}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/public/api/validator.json"

rpc() {
	local endpoint="$1" method="$2"
	curl -sS -X POST \
		--max-time 5 \
		-H 'content-type:application/json' \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\"}" \
		"${API}/ext/${endpoint}"
}

rpc_with_params() {
	local endpoint="$1" method="$2" params="$3"
	curl -sS -X POST \
		--max-time 5 \
		-H 'content-type:application/json' \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
		"${API}/ext/${endpoint}"
}

# Public RPC endpoints sampled for an independent observation of our NodeID's
# uptime. A node's subjective view of itself is by protocol design always
# ~100%, so the truthful value is what *other* nodes report — we collect their
# evaluations and take the median.
external_rpcs_for_network() {
	case "$1" in
		mainnet)
			echo "https://api.metalblockchain.org/ext/bc/P"
			;;
		tahoe)
			:
			;;
	esac
}

# Query one external RPC for our NodeID's uptime evaluation.
# Outputs "<endpoint>\t<value>" on success, nothing on failure.
external_uptime_one() {
	local url="$1" id="$2"
	local resp val
	resp=$(curl -sS -X POST --max-time 5 \
		-H 'content-type:application/json' \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"platform.getCurrentValidators\",\"params\":{\"nodeIDs\":[\"${id}\"]}}" \
		"${url}" 2>/dev/null || echo '{}')
	val=$(echo "${resp}" | jq -r --arg id "${id}" \
		'.result.validators[]? | select(.nodeID == $id) | .uptime // empty' 2>/dev/null | head -1)
	if [[ -n "${val}" && "${val}" != "null" ]]; then
		printf '%s\t%s\n' "${url}" "${val}"
	fi
}

# TTL cache for external uptime samples. The cron runs every 5 min for local
# data freshness, but external RPCs are someone else's infrastructure and
# being polled 12×/hour is rude. Re-sample at most once per TTL window
# (default 30 min → 2 hits/hour to each external endpoint).
EXT_CACHE_FILE="${EXTERNAL_UPTIME_CACHE:-/tmp/uptime-cache.json}"
EXT_CACHE_TTL_SEC="${EXTERNAL_UPTIME_TTL_SEC:-1800}"

read_external_uptime_cache() {
	[[ -r "${EXT_CACHE_FILE}" ]] || return 1
	local content fetched now age
	content=$(cat "${EXT_CACHE_FILE}" 2>/dev/null || true)
	fetched=$(echo "${content}" | jq -r '.fetchedAt // empty' 2>/dev/null || true)
	[[ -z "${fetched}" || "${fetched}" == "null" ]] && return 1
	now=$(date +%s)
	age=$((now - fetched))
	(( age < EXT_CACHE_TTL_SEC )) || return 1
	echo "${content}"
}

write_external_uptime_cache() {
	local samples_json="$1"
	local now
	now=$(date +%s)
	jq -n --argjson samples "${samples_json}" --argjson now "${now}" \
		'{fetchedAt: $now, samples: $samples}' > "${EXT_CACHE_FILE}" 2>/dev/null || true
}

echo "=== Metal validator node status ==="
echo "API: ${API}"
echo

NODE_ID_RAW=$(rpc info info.getNodeID || true)
if [[ -z "${NODE_ID_RAW}" ]]; then
	echo "ERROR: metalgo API に到達できません。docker compose -f docker-compose.metalgo.yml up -d で起動済みか確認"
	exit 1
fi

NODE_ID=$(echo "${NODE_ID_RAW}" | jq -r '.result.nodeID // empty')
NETWORK_NAME_RAW=$(rpc info info.getNetworkName || echo '{}')
NETWORK_NAME=$(echo "${NETWORK_NAME_RAW}" | jq -r '.result.networkName // "unknown"')

P_BOOT_RAW=$(rpc_with_params info info.isBootstrapped '{"chain":"P"}' || echo '{}')
X_BOOT_RAW=$(rpc_with_params info info.isBootstrapped '{"chain":"X"}' || echo '{}')
C_BOOT_RAW=$(rpc_with_params info info.isBootstrapped '{"chain":"C"}' || echo '{}')

P_BOOT=$(echo "${P_BOOT_RAW}" | jq -r '.result.isBootstrapped // false')
X_BOOT=$(echo "${X_BOOT_RAW}" | jq -r '.result.isBootstrapped // false')
C_BOOT=$(echo "${C_BOOT_RAW}" | jq -r '.result.isBootstrapped // false')

echo "Network: ${NETWORK_NAME}"
echo "NodeID:  ${NODE_ID:-<not ready>}"
echo "Bootstrap status:"
echo "  P-Chain: ${P_BOOT}"
echo "  X-Chain: ${X_BOOT}"
echo "  C-Chain: ${C_BOOT}"
echo

# P-Chain から自分の NodeID にマッチする現在の validator を取得。
# 現 metalgo API: .weight = 自己 stake (delegators は含まれない)、.delegatorWeight = 委任受入合計、
# .delegatorCount = 委任件数。.stakeAmount は旧 API 名残で実機では返らないが保険として読む。
# nodeIDs フィルタなしの呼出しでは .delegators[] 配列は省略され summary 値のみ返る。
CURRENT_RAW=$(curl -sS -X POST \
	--max-time 10 \
	-H 'content-type:application/json' \
	--data '{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{}}' \
	"${API}/ext/bc/P" 2>/dev/null || echo '{}')

# 自分の NodeID にマッチする entry を抽出
SELF_STAKE_NMETAL=$(echo "${CURRENT_RAW}" | jq -r --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id) | .stakeAmount // empty' | head -1)
WEIGHT_NMETAL=$(echo "${CURRENT_RAW}" | jq -r --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id) | .weight // empty' | head -1)
# delegators の合計 weight。metalgo は nodeIDs フィルタなしの呼出しでは
# .delegators[] 配列を省略する(bandwidth 最適化)。summary フィールドの
# .delegatorWeight が常に正しいので、こちらを使う(0 = 委任なし)。
DELEGATORS_SUM_NMETAL=$(echo "${CURRENT_RAW}" | jq -r --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id) | .delegatorWeight // "0"' | head -1)
DELEGATORS_SUM_NMETAL="${DELEGATORS_SUM_NMETAL:-0}"
DELEGATOR_COUNT=$(echo "${CURRENT_RAW}" | jq -r --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id) | .delegatorCount // "0"' | head -1)
DELEGATOR_COUNT="${DELEGATOR_COUNT:-0}"
UPTIME_RAW=$(echo "${CURRENT_RAW}" | jq -r --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id) | .uptime // empty' | head -1)
DELEGATION_FEE=$(echo "${CURRENT_RAW}" | jq -r --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id) | .delegationFee // empty' | head -1)
START_TIME=$(echo "${CURRENT_RAW}" | jq -r --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id) | .startTime // empty' | head -1)
END_TIME=$(echo "${CURRENT_RAW}" | jq -r --arg id "${NODE_ID}" \
	'.result.validators[]? | select(.nodeID == $id) | .endTime // empty' | head -1)

# Total validator count: CURRENT_RAW already contains every active validator
# (no nodeIDs filter), so we get the network size for free from the same
# localhost call. This replaces a previous per-page-load browser fetch to
# api.metalblockchain.org/ext/P — see [[feedback_polite_external_access]].
TOTAL_VALIDATORS=$(echo "${CURRENT_RAW}" | jq -r '(.result.validators // []) | length')

# 現 metalgo API では .weight = validator 自身の self-stake (delegators は含まない)、
# .delegatorWeight = 委任受入合計、と分離されている。total weight (= consensus 上の
# 影響度) は self + delegators。旧 .stakeAmount フィールドは存在しても自己 stake
# の意味で、weight と同義(なければ weight をそのまま使う)。
if [[ -z "${SELF_STAKE_NMETAL}" || "${SELF_STAKE_NMETAL}" == "null" ]]; then
	SELF_STAKE_NMETAL="${WEIGHT_NMETAL:-0}"
fi
# total weight = self-stake + delegators (consensus 上の総合 weight)
if [[ -n "${WEIGHT_NMETAL}" && "${WEIGHT_NMETAL}" != "null" ]]; then
	TOTAL_WEIGHT_NMETAL=$(echo "${SELF_STAKE_NMETAL:-0} + ${DELEGATORS_SUM_NMETAL:-0}" | bc)
else
	TOTAL_WEIGHT_NMETAL=""
fi

# nMETAL (10^9 単位) → METAL に変換、未登録なら null
nano_to_metal() {
	local v="$1"
	if [[ -n "${v}" && "${v}" != "null" ]]; then
		# 0 は sed の trailing-zero 削除で空文字列になるので特別扱い
		if [[ "${v}" == "0" ]]; then
			echo "0"
		else
			echo "scale=4; ${v} / 1000000000" | bc | sed -E 's/\.?0+$//'
		fi
	else
		echo "null"
	fi
}

SELF_STAKE=$(nano_to_metal "${SELF_STAKE_NMETAL}")
WEIGHT=$(nano_to_metal "${TOTAL_WEIGHT_NMETAL:-${WEIGHT_NMETAL}}")
TOTAL_RECEIVED=$(nano_to_metal "${DELEGATORS_SUM_NMETAL}")

# JSON フィールドのクォート判定(null は素のまま、値ありは数値 or 文字列)
json_num_or_null() {
	if [[ "$1" == "null" ]]; then echo "null"; else echo "$1"; fi
}

echo "Validator entry on P-Chain:"
echo "  Self-stake:       ${SELF_STAKE} METAL"
echo "  Total weight:     ${WEIGHT} METAL"
echo "  Total received:   ${TOTAL_RECEIVED} METAL"
echo "  Uptime (self):    ${UPTIME_RAW:-null}"
echo "  Delegation fee:   ${DELEGATION_FEE:-null}"

# Independent observation: poll external public RPCs for what *peers* think
# our uptime is. Self-reported value is always ~100% by protocol design
# (a node's subjective view of itself), so we treat the external median as
# the truthful number and keep self as a transparency field.
SELF_UPTIME="${UPTIME_RAW:-null}"
EXT_SAMPLES_JSON='[]'
EXT_CACHE_AGE_SEC=0
UPTIME_CACHE_HIT="false"

if [[ -n "${NODE_ID}" ]]; then
	if CACHED=$(read_external_uptime_cache); then
		EXT_SAMPLES_JSON=$(echo "${CACHED}" | jq '.samples')
		FETCHED=$(echo "${CACHED}" | jq '.fetchedAt')
		EXT_CACHE_AGE_SEC=$(( $(date +%s) - FETCHED ))
		UPTIME_CACHE_HIT="true"
	else
		EXT_SAMPLES_TSV=$(
			while IFS= read -r url; do
				[[ -z "${url}" ]] && continue
				# Defense in depth: never sample our own API.
				[[ "${url}" == "${API}"* ]] && continue
				external_uptime_one "${url}" "${NODE_ID}"
			done < <(external_rpcs_for_network "${NETWORK_NAME}")
		)
		if [[ -n "${EXT_SAMPLES_TSV}" ]]; then
			EXT_SAMPLES_JSON=$(echo "${EXT_SAMPLES_TSV}" \
				| jq -R 'split("\t") | {endpoint: .[0], value: (.[1] | tonumber)}' \
				| jq -s '.')
			write_external_uptime_cache "${EXT_SAMPLES_JSON}"
		fi
	fi
fi

EXT_SAMPLE_COUNT=$(echo "${EXT_SAMPLES_JSON}" | jq 'length')
EXT_UPTIME_MEDIAN="null"
UPTIME_SOURCE="self-reported"

if (( EXT_SAMPLE_COUNT > 0 )); then
	EXT_UPTIME_MEDIAN=$(echo "${EXT_SAMPLES_JSON}" | jq '
		[.[].value] | sort
		| (length / 2 | floor) as $m
		| if length % 2 == 1 then .[$m] else (.[$m] + .[$m-1]) / 2 end
	')
	UPTIME_SOURCE="external-median"
fi

# Primary value shown on the site: external median if any peer responded,
# otherwise the self value (with the source field flagging it).
PRIMARY_UPTIME="${EXT_UPTIME_MEDIAN}"
if [[ "${PRIMARY_UPTIME}" == "null" ]]; then
	PRIMARY_UPTIME="${SELF_UPTIME}"
fi

echo "  Uptime (peer median, n=${EXT_SAMPLE_COUNT}, cache_hit=${UPTIME_CACHE_HIT}, age=${EXT_CACHE_AGE_SEC}s): ${EXT_UPTIME_MEDIAN}"
echo "  Uptime (site primary, source=${UPTIME_SOURCE}): ${PRIMARY_UPTIME}"
echo

OBSERVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# NodeID が空でも JSON が壊れないように null を埋める
if [[ -n "${NODE_ID}" ]]; then
	NODE_ID_JSON="\"${NODE_ID}\""
else
	NODE_ID_JSON="null"
fi

UPTIME_JSON=$(json_num_or_null "${PRIMARY_UPTIME}")
SELF_UPTIME_JSON=$(json_num_or_null "${SELF_UPTIME}")
DELEGATION_FEE_JSON=$(json_num_or_null "${DELEGATION_FEE:-null}")
SELF_STAKE_JSON=$(json_num_or_null "${SELF_STAKE}")
TOTAL_RECEIVED_JSON=$(json_num_or_null "${TOTAL_RECEIVED}")
START_TIME_JSON=$(json_num_or_null "${START_TIME:-null}")
END_TIME_JSON=$(json_num_or_null "${END_TIME:-null}")

# network 名から phase / mode / explorer URL を決める
case "${NETWORK_NAME}" in
	mainnet)
		PHASE=1
		MODE="mainnet"
		EXPLORER="https://explorer.metalblockchain.org/"
		COMMENT_PREFIX="Phase 1 — mainnet operation. NodeID is the live validator identity"
		STAKE_NOTE="self = 自己 stake、totalReceived = 委任受入合計、max_weight = 5 × self。mainnet 最小 2,000 METAL"
		UPTIME_NOTE="network = 外部 RPC からの uptime 評価値の中央値(ピア観測の真値)。self = 自ノード自身に問い合わせた値(プロトコル仕様で常に ~100% を返すため参考のみ)。報酬閾値は 80%。"
		;;
	tahoe)
		PHASE=0
		MODE="tahoe-testnet"
		EXPLORER="https://tahoe.metalscan.io/"
		COMMENT_PREFIX="Phase 0 — Tahoe testnet pipeline check"
		STAKE_NOTE="self = 自己 stake、totalReceived = 委任受入合計、max_weight = 5 × self。Tahoe testnet 最小 1 METAL"
		UPTIME_NOTE="testnet は外部観測 RPC を未設定。network = self(自ノード値、プロトコル仕様で ~100% 固定)。本番 mainnet では外部 RPC から中央値を取得する"
		;;
	*)
		PHASE=0
		MODE="unknown"
		EXPLORER="https://explorer.metalblockchain.org/"
		COMMENT_PREFIX="Unknown network ${NETWORK_NAME}"
		STAKE_NOTE="self = 自己 stake、totalReceived = 委任受入合計、max_weight = 5 × self"
		UPTIME_NOTE="network = 外部 RPC 中央値(取得できれば)、self = 自ノード値(常に ~100%)"
		;;
esac

cat > "${OUT}" <<EOF
{
	"_comment": "${COMMENT_PREFIX}. NodeID etc. are live from local metalgo. stake は P-Chain platform.getCurrentValidators から、登録後にのみ値が入る。Updated by scripts/node-info.sh.",
	"phase": ${PHASE},
	"mode": "${MODE}",
	"network": "${NETWORK_NAME}",
	"nodeId": ${NODE_ID_JSON},
	"bootstrap": {
		"pChain": ${P_BOOT},
		"xChain": ${X_BOOT},
		"cChain": ${C_BOOT}
	},
	"stake": {
		"self": ${SELF_STAKE_JSON},
		"totalReceived": ${TOTAL_RECEIVED_JSON},
		"delegatorCount": ${DELEGATOR_COUNT},
		"unit": "METAL",
		"_note": "${STAKE_NOTE}"
	},
	"uptime": {
		"network": ${UPTIME_JSON},
		"self": ${SELF_UPTIME_JSON},
		"source": "${UPTIME_SOURCE}",
		"sampleSize": ${EXT_SAMPLE_COUNT},
		"samples": ${EXT_SAMPLES_JSON},
		"cacheAgeSec": ${EXT_CACHE_AGE_SEC},
		"cacheTtlSec": ${EXT_CACHE_TTL_SEC},
		"_note": "${UPTIME_NOTE}"
	},
	"delegationFee": {
		"percent": ${DELEGATION_FEE_JSON},
		"_note": "プロトコル下限 2%、超過分は operator-chosen"
	},
	"networkSize": {
		"totalValidators": ${TOTAL_VALIDATORS},
		"_note": "ローカル metalgo の platform.getCurrentValidators から取得した primary network validator 数。閲覧者ブラウザから外部 RPC を叩かない代替"
	},
	"startTime": ${START_TIME_JSON},
	"endTime": ${END_TIME_JSON},
	"explorer": "${EXPLORER}",
	"observedAt": "${OBSERVED_AT}"
}
EOF

echo "Wrote ${OUT}"
