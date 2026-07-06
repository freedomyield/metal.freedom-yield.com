#!/usr/bin/env bash
# Daily status digest — push a one-shot snapshot of validator + host state.
# Runs three times per day (09:00 + 18:00 + 22:00 JST), keyed by an optional slot arg:
#   daily-status.sh morning   → 🌅 朝の運用状態
#   daily-status.sh evening   → 🌆 夕方の運用状態
#   daily-status.sh night     → 🌙 夜の運用状態
#   daily-status.sh (no arg)  → falls back to neutral title
# Sends a single ntfy notification at "default" priority — quiet ping, full
# context in the body so the operator can skip opening the ops dashboard.
set -uo pipefail

SLOT="${1:-}"
case "$SLOT" in
  morning) TITLE_PREFIX="🌅 朝の運用状態" ;;
  evening) TITLE_PREFIX="🌆 夕方の運用状態" ;;
  night)   TITLE_PREFIX="🌙 夜の運用状態" ;;
  *)       TITLE_PREFIX="📋 運用状態" ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# -------- cycle-gate (= digest skip 制御、 fail-closed) --------
# Skip the entire digest push when the gate is deferred or missing.
# The digest body includes cycle-related fields (= validator stake, period,
# uptime); during a transition window the cycle data is in flux and a
# digest would either confuse the operator or require complex conditional
# rendering. Cleaner to skip the push entirely. Operator's transition-time
# awareness comes from the explicit resume-after-cycle-start.sh flow, not
# from periodic digest.
CYCLE_GATE_SCRIPT="${ROOT}/scripts/cycle-gate.sh"
if [ ! -x "${CYCLE_GATE_SCRIPT}" ]; then
	echo "[daily-status] cycle-gate.sh missing or non-executable → skip digest push (fail-closed)" >&2
	exit 0
fi
if ! "${CYCLE_GATE_SCRIPT}" --side-effect=cycle-aware-notify; then
	echo "[daily-status] deferred by cycle-gate → skip digest push for this slot" >&2
	exit 0
fi

NOTIFY="$ROOT/scripts/notify.sh"
STATUS_JSON="$ROOT/public/api/server-status.json"
VALIDATOR_JSON="$ROOT/public/api/validator.json"
WALLET_CONFIG="/etc/freedom-yield/wallet-addresses.json"
METALGO_RPC="${METALGO_RPC:-http://127.0.0.1:9650}"

if [ ! -f "$STATUS_JSON" ] || [ ! -f "$VALIDATOR_JSON" ]; then
  echo "missing JSON, skip" >&2
  exit 0
fi

# Balance fetch — talks ONLY to local metalgo RPC (no external API).
# Values appear only in the ntfy push body; never echo'd to stdout / log
# (operator's personal asset numbers must not be persisted per project policy).
fetch_balance() {
  local addrs_json="$1"
  local stake_amount="${2:-0}"
  if [ ! -r "$addrs_json" ]; then
    echo "—"
    return
  fi
  local c_addr p_addr x_addr
  c_addr=$(jq -r '.validator.cChain' "$addrs_json")
  p_addr=$(jq -r '.validator.pChain' "$addrs_json")
  x_addr=$(jq -r '.validator.xChain' "$addrs_json")

  # P-chain unlocked balance (nAVAX, 1 METAL = 1e9)
  local p_resp p_unlocked p_locked_stakeable p_locked_not
  p_resp=$(curl -s --max-time 6 -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"platform.getBalance\",\"params\":{\"addresses\":[\"$p_addr\"]}}" \
    "$METALGO_RPC/ext/bc/P" 2>/dev/null)
  p_unlocked=$(echo "$p_resp" | jq -r '.result.unlocked // "0"' 2>/dev/null)
  p_locked_stakeable=$(echo "$p_resp" | jq -r '.result.lockedStakeable // "0"' 2>/dev/null)
  p_locked_not=$(echo "$p_resp" | jq -r '.result.lockedNotStakeable // "0"' 2>/dev/null)

  # X-chain balance (nAVAX)
  local x_resp x_bal
  x_resp=$(curl -s --max-time 6 -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"avm.getBalance\",\"params\":{\"address\":\"$x_addr\",\"assetID\":\"METAL\"}}" \
    "$METALGO_RPC/ext/bc/X" 2>/dev/null)
  x_bal=$(echo "$x_resp" | jq -r '.result.balance // "0"' 2>/dev/null)

  # C-chain balance (wei hex, 1 METAL = 1e18)
  local c_resp c_hex
  c_resp=$(curl -s --max-time 6 -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[\"$c_addr\",\"latest\"]}" \
    "$METALGO_RPC/ext/bc/C/rpc" 2>/dev/null)
  c_hex=$(echo "$c_resp" | jq -r '.result // "0x0"' 2>/dev/null)

  # Convert wei/nAVAX → METAL (P/X: 1e9, C: 1e18). 3 decimals.
  python3 - "$p_unlocked" "$p_locked_stakeable" "$p_locked_not" "$x_bal" "$c_hex" "$stake_amount" <<'PY' 2>/dev/null
import sys
p_u, p_ls, p_ln, x, c_hex, stake = sys.argv[1:7]
def to_metal_nano(v):
    try: return int(v) / 1_000_000_000
    except: return 0
def to_metal_wei(h):
    try: return int(h, 16) / 1_000_000_000_000_000_000
    except: return 0
def to_float(v):
    try: return float(v)
    except: return 0
pu = to_metal_nano(p_u)
pls = to_metal_nano(p_ls)
pln = to_metal_nano(p_ln)
xv = to_metal_nano(x)
cv = to_metal_wei(c_hex)
sv = to_float(stake)
p_total = pu + pls + pln
total = p_total + xv + cv + sv
print(f"P-chain: {p_total:,.3f}")
if pls > 0 or pln > 0:
    print(f"  (内訳 unlocked {pu:,.3f} / locked {pls+pln:,.3f})")
print(f"X-chain: {xv:,.3f}")
print(f"C-chain: {cv:,.3f}")
print(f"Staked:  {sv:,.3f} (P-chain ロック)")
print(f"合計:    {total:,.3f} METAL")
PY
}

# Validator
NODE_ID=$(jq -r '.nodeId // "—"' "$VALIDATOR_JSON")
NODE_SHORT="${NODE_ID:0:24}…"
P_BOOT=$(jq -r '.bootstrap.pChain' "$VALIDATOR_JSON")
X_BOOT=$(jq -r '.bootstrap.xChain' "$VALIDATOR_JSON")
C_BOOT=$(jq -r '.bootstrap.cChain' "$VALIDATOR_JSON")
UPTIME=$(jq -r '.uptime.network // 0' "$VALIDATOR_JSON")
SELF_STAKE=$(jq -r '.stake.self // 0' "$VALIDATOR_JSON")
TOTAL_RECEIVED=$(jq -r '.stake.totalReceived // 0' "$VALIDATOR_JSON")
TOTAL_WEIGHT_METAL=$(awk -v s="$SELF_STAKE" -v d="$TOTAL_RECEIVED" 'BEGIN{printf "%.4f", s+d}' | sed -E 's/\.?0+$//')
END_TIME=$(jq -r '.endTime // 0' "$VALIDATOR_JSON")
NOW=$(date +%s)
DAYS_LEFT=$(( (END_TIME - NOW) / 86400 ))

BALANCE_BODY="$(fetch_balance "$WALLET_CONFIG" "$SELF_STAKE")"
if [ -z "$BALANCE_BODY" ]; then
  BALANCE_BODY="(残高取得失敗 — RPC エラー)"
fi

# Server
CPU=$(jq -r '.host.cpu.usedPercent' "$STATUS_JSON")
MEM=$(jq -r '.host.memory.usedPercent' "$STATUS_JSON")
DISK=$(jq -r '.host.disk.usedPercent' "$STATUS_JSON")
PEERS=$(jq -r '.metalgo.peerCount // 0' "$STATUS_JSON")
METALGO_S=$(jq -r '.metalgo.containerStatus' "$STATUS_JSON")
CADDY_S=$(jq -r '.caddy.containerStatus' "$STATUS_JSON")

# Overall verdict
if [ "$P_BOOT" = "true" ] && [ "$X_BOOT" = "true" ] && [ "$C_BOOT" = "true" ] \
   && [ "$METALGO_S" = "running" ] && [ "$CADDY_S" = "running" ]; then
  OVERALL="✓ 正常稼働中"
else
  OVERALL="⚠ 要確認"
fi

# Period status icon — informational, no false urgency.
# Action moment in post-expiry issuance mode is at endTime itself (旧 stake 解放);
# the standalone ntfy T-10min alert carries the actual urgency. The digest icon
# stays calm so the 3×/day push doesn't read as "panic" before there's anything
# the operator can do.
if [ "$DAYS_LEFT" -lt 0 ]; then PERIOD_STATE="⏰ 期間切れ"
elif [ "$DAYS_LEFT" -eq 0 ]; then PERIOD_STATE="⏰ 本日終了予定"
elif [ "$DAYS_LEFT" -eq 1 ]; then PERIOD_STATE="⚠ 明日終了"
elif [ "$DAYS_LEFT" -le 7 ]; then PERIOD_STATE="ℹ 残 1 週間以内"
elif [ "$DAYS_LEFT" -le 14 ]; then PERIOD_STATE="ℹ 残 2 週間以内"
else PERIOD_STATE="✓ 余裕"
fi

DATE_JP=$(TZ=Asia/Tokyo date '+%m/%d (%a)')
NOW_JST=$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M JST')
END_DATE_JST=$(TZ=Asia/Tokyo date -d "@$END_TIME" '+%m/%d %H:%M JST')

# Morning slot also carries the evidence-pipeline health row (= what
# notify-evidence-health.sh used to push standalone at ~01:35 UTC).
# Consolidating into the morning daily-status avoids the duplicate ntfy
# observed 2026-06-23. Evening / night slots stay slim.
#
# Exit code of `--summary` carries pass/fail so we can escalate the morning
# push to priority=high on any A1/A2/A3 FAIL (= the legacy standalone push
# did this; without escalation a degraded evidence pipeline would only
# surface as a body emoji, defeating Android DND bypass on `urgent`/`high`).
# Empty stdout means the script itself errored out (jq missing, network
# down, etc.) — show that explicitly so the operator never silently loses
# the row.
EVIDENCE_BLOCK=""
EVIDENCE_RC=0
if [ "$SLOT" = "morning" ]; then
  EVIDENCE_SCRIPT="$(dirname "$0")/notify-evidence-health.sh"
  if [ -x "$EVIDENCE_SCRIPT" ]; then
    set +e
    EVIDENCE_SUMMARY=$(bash "$EVIDENCE_SCRIPT" --summary 2>/dev/null)
    EVIDENCE_RC=$?
    set -e
    if [ -z "$EVIDENCE_SUMMARY" ]; then
      EVIDENCE_SUMMARY="⚠ evidence health script error (rc=${EVIDENCE_RC})"
      EVIDENCE_RC=2
    fi
    EVIDENCE_BLOCK="

[Evidence health]
${EVIDENCE_SUMMARY}"
  fi
fi

# Priority escalation: high when validator state is degraded (= OVERALL is
# ⚠ 要確認 or worse) or when the morning evidence-pipeline check returned
# non-zero. Otherwise default. urgent is reserved for separate alerters
# (anomalies / metalgo down / validator drop) per
# reference_ntfy_notifications.
PRIO="default"
case "$OVERALL" in
  *⚠*|*❌*) PRIO="high" ;;
esac
if [ "${EVIDENCE_RC:-0}" -ne 0 ]; then
  PRIO="high"
fi

# Multi-line body — ntfy Android renders \n as line break.
# Note: notify.sh auto-appends a single "[Uptime] XX.XXXX%" footer line to
# every ntfy body. Do NOT duplicate Uptime here; the auto-appended footer
# is the single source of truth for the headline number across all pushes.
BODY=$(cat <<EOF
${OVERALL}
取得時刻: ${NOW_JST}

[Validator]
Bootstrap: ${P_BOOT:0:1}/${X_BOOT:0:1}/${C_BOOT:0:1}
Stake: ${SELF_STAKE} METAL
受入合計: ${TOTAL_RECEIVED} METAL
総 weight: ${TOTAL_WEIGHT_METAL} METAL (self + delegators)
期限: ${PERIOD_STATE} 残 ${DAYS_LEFT} 日 (${END_DATE_JST})
通知: 1 週間前 / 前日 / 当日 / 10 分前 (urgent)

[Wallet 残高]
${BALANCE_BODY}

[Server]
CPU ${CPU}% / RAM ${MEM}% / Disk ${DISK}%
Peers: ${PEERS}
metalgo: ${METALGO_S}
caddy: ${CADDY_S}

[NodeID]
${NODE_SHORT}${EVIDENCE_BLOCK}
EOF
)

bash "$NOTIFY" "$PRIO" "${TITLE_PREFIX} ${DATE_JP}" "$BODY"
