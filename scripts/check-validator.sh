#!/usr/bin/env bash
# 自分の NodeID が Tahoe testnet の validator set に入ったか確認する
# delegation/validation tx 送信後に `make check-validator` で呼ぶ想定
#
# 出力:
#   - Pending validators (start time 待ち)
#   - Current validators (active)
#   - 自分の NodeID にマッチする件数 / 詳細
set -euo pipefail

API="${METALGO_API:-http://localhost:9650}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR_JSON="${ROOT}/public/api/validator.json"

if [[ ! -f "${VALIDATOR_JSON}" ]]; then
	echo "ERROR: ${VALIDATOR_JSON} が無い。先に make node-status を実行してください"
	exit 1
fi

NODE_ID=$(jq -r '.nodeId // empty' "${VALIDATOR_JSON}")
if [[ -z "${NODE_ID}" ]]; then
	echo "ERROR: validator.json に nodeId が無い。metalgo の起動・同期を確認してください"
	exit 1
fi

echo "=== Tahoe validator set lookup ==="
echo "NodeID: ${NODE_ID}"
echo "API:    ${API}"
echo

rpc_p() {
	local method="$1"
	curl -sS -X POST \
		--max-time 10 \
		-H 'content-type:application/json' \
		--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":{\"subnetID\":\"11111111111111111111111111111111LpoYY\"}}" \
		"${API}/ext/bc/P"
}

format_validators() {
	local json="$1" label="$2"
	local matched
	matched=$(echo "${json}" | jq --arg id "${NODE_ID}" '.result.validators // [] | map(select(.nodeID == $id))')
	local count
	count=$(echo "${matched}" | jq 'length')

	echo "=== ${label}: ${count} 件マッチ ==="
	if [[ "${count}" -gt 0 ]]; then
		echo "${matched}" | jq -r '.[] | "  → start:  \(.startTime)\n  → end:    \(.endTime)\n  → weight: \(.weight) nMETAL\n  → uptime: \(.uptime // "n/a")"'
	fi
	echo
}

CURRENT=$(rpc_p platform.getCurrentValidators)
PENDING=$(rpc_p platform.getPendingValidators 2>/dev/null || echo '{"result":{"validators":[]}}')

format_validators "${CURRENT}" "Current validators (active)"
format_validators "${PENDING}" "Pending validators (start time 待ち)"

# サマリ
CURRENT_HIT=$(echo "${CURRENT}" | jq --arg id "${NODE_ID}" '.result.validators // [] | map(select(.nodeID == $id)) | length')
PENDING_HIT=$(echo "${PENDING}" | jq --arg id "${NODE_ID}" '.result.validators // [] | map(select(.nodeID == $id)) | length')

if [[ "${CURRENT_HIT}" -gt 0 ]]; then
	echo "✓ active な validator として登録されています"
elif [[ "${PENDING_HIT}" -gt 0 ]]; then
	echo "⏳ pending(start time 待ち)。指定した start time 到達後に再度実行してください"
else
	echo "ℹ delegation/validation tx は未送信、または confirm 待ち。数分待ってから再実行を推奨"
fi
