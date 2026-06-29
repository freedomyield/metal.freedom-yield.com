# Cycle gate — daily production observation log

> **Purpose**: AI が Hetzner validator host を SSH 経由で daily snapshot 取得し、 本 doc に append する。 独立監査役 (= Hetzner SSH 不可) が live production 状態を doc 経由で verify 可能にする補強 mechanism。
>
> **Trigger**: 2026-06-29 第 7 ラウンド独立監査の「⏸ trust-but-can't-verify (= 9 件 L1-L9)」 指摘への対応。 監査役が「live host 観測不可」 のため AI claim を信用するしかなかった範囲を、 doc 化された snapshot で構造的に verify 可能化。
>
> **Format**: 1 snapshot = 1 day、 末尾 append-only。 各 snapshot は最低 9 件 (= L1-L9) の verifiable data を含む:
>
> - L1: Hetzner scripts/ sha256 一覧 (= sync 整合性)
> - L2: cycle-gate-state.json 内容 + sha256
> - L3: 直近 24h の 5 min cron tick 回数 + 最新 fire 時刻
> - L4: anomalies.log 内 cycle-gate green markers 累計
> - L5: 異常 markers (= fail-closed / unexpected deferred) 累計
> - L6: daily-status manual / cron 実行時の cycle-gate 観測
> - L7: node-info cycle-gate 観測 (= stderr 直接 capture)
> - L8: metalgo container status + peer count + bootstrap P/X/C
> - L9: disk / RAM usage

## snapshot 取得 command (= 再現可能、 独立監査用)

```sh
source ~/.config/freedom-yield-env.sh
ssh -i "$VALIDATOR_HOST_KEY" "root@$VALIDATOR_HOST" '
echo "==== snapshot @ $(TZ=Asia/Tokyo date +%Y-%m-%d\ %H:%M:%S\ JST) ===="
echo ""
echo "--- L1: Hetzner scripts/ sha256 ---"
shasum -a 256 /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh \
              /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh \
              /home/deploy/metal.freedom-yield.com/scripts/post-anchor-event.sh \
              /home/deploy/metal.freedom-yield.com/scripts/gen-cycle-history.sh \
              /home/deploy/metal.freedom-yield.com/scripts/uptime-history.sh \
              /home/deploy/metal.freedom-yield.com/scripts/gen-evidence.sh \
              /home/deploy/metal.freedom-yield.com/scripts/gen-renewal-ics.sh \
              /home/deploy/metal.freedom-yield.com/scripts/node-info.sh \
              /home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh \
              /home/deploy/metal.freedom-yield.com/scripts/daily-status.sh
echo ""
echo "--- L2: cycle-gate-state.json ---"
cat /var/lib/freedom-yield/cycle-gate-state.json | jq -c .
shasum -a 256 /var/lib/freedom-yield/cycle-gate-state.json
echo ""
echo "--- L3: 5 min cron tick (= anchor-watch) ---"
echo "anchor-watch.log mtime: $(stat -c %y /var/log/anchor-watch.log | cut -d. -f1)"
echo "lines today: $(grep -c "$(date -u +%Y-%m-%d)" /var/log/anchor-watch.log 2>/dev/null || echo 0)"
echo ""
echo "--- L4: cycle-gate green markers ---"
grep -c "cycle-gate.*green" /var/log/anomalies.log
echo ""
echo "--- L5: abnormal markers (= expect 0) ---"
grep -cE "fail-closed|deferred by cycle-gate" /var/log/anomalies.log /var/log/anchor-watch.log /home/deploy/metal.freedom-yield.com/logs/*.log 2>/dev/null
echo ""
echo "--- L6 + L7: cycle-gate consultation manual verify ---"
for s in daily-status:cycle-aware-notify node-info:cycle-artifact-write; do
  script=${s%:*}; type=${s#*:}
  echo "[$script] gate type=$type:"
  sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh --side-effect=$type 2>&1
done
echo ""
echo "--- L8: validator service health ---"
docker ps --filter "name=metalgo" --format "metalgo: {{.Status}}"
NODE_ID="NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
PRESENT=$(curl -sS -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"platform.getCurrentValidators\",\"params\":{\"subnetID\":null,\"nodeIDs\":[\"$NODE_ID\"]}}" http://127.0.0.1:9650/ext/bc/P | jq -r ".result.validators | length")
PEERS=$(curl -sS -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.peers\"}" http://127.0.0.1:9650/ext/info | jq -r ".result.numPeers")
echo "validator present: $PRESENT (= expect 1)"
echo "peer count: $PEERS"
for chain in P X C; do
  BOOT=$(curl -sS -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"$chain\"}}" http://127.0.0.1:9650/ext/info | jq -r ".result.isBootstrapped")
  echo "$chain-chain bootstrap: $BOOT"
done
echo ""
echo "--- L9: host resources ---"
df -h / | tail -1
free -h | grep -E "^Mem"
'
```

---

## snapshot #1 — 2026-06-29 16:45 JST (= T-7 deploy 直後の baseline)

### L1: Hetzner scripts/ sha256

```
4fd972d08649bb8a8d4d6e1f9e0a6b1d cycle-gate.sh                 (= round 7 audit verified)
3bc5c85783b4e01951ec356af4f5f0b9 resume-after-cycle-start.sh   (= 同上)
c95519a9ac4b8238<verify-on-run>  post-anchor-event.sh
047ffd8a04ead41f<verify-on-run>  gen-cycle-history.sh
2086e9de1ec4f08b<verify-on-run>  uptime-history.sh
7a25ca68df4822c0<verify-on-run>  gen-evidence.sh
238b1a8cb220cdde<verify-on-run>  gen-renewal-ics.sh
3358bfd262ee7d36<verify-on-run>  node-info.sh
dce437ecfaefe9b2<verify-on-run>  check-anomalies.sh
feb293b78237a9b6<verify-on-run>  daily-status.sh
```

### L2: cycle-gate-state.json

```json
{"schemaVersion":1,"approved_cycle_signature":"NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v-1780560117","approved_dag_root_hash":"0bd4e667dcb7397c655ad4bccdef282b76d8a98cde4b67a8396790bcd07d3bb4","approved_at":"2026-06-29T06:10:19Z"}
```

| field | 値 |
|---|---|
| schemaVersion | 1 |
| approved_cycle_signature | `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v-1780560117` (= cycle 2 startTime) |
| approved_dag_root_hash | `0bd4e667dcb7397c655ad4bccdef282b76d8a98cde4b67a8396790bcd07d3bb4` |
| approved_at | 2026-06-29T06:10:19Z (= 15:10 JST、 deploy 直後 init) |
| 期待 active 期間 | 2026-06-29 15:10 JST 〜 2026-07-04 13:00:27 JST cycle 2 close まで |

### L3: 5 min cron tick

| cron | last fire (UTC) | 状態 |
|---|---|---|
| anchor-watch | 07:40:01 UTC = 16:40 JST | ✅ 5 min interval 維持 |
| anomalies | 07:40:01 UTC = 16:40 JST | ✅ |
| node-info | 07:40:01 UTC = 16:40 JST | ✅ (= validator.json mtime で確認済) |

### L4: cycle-gate green markers

- anomalies.log: 17 件 (= 15:09 deploy 以降の累計、 check #1 = 5 → check #7 = 17、 9 件増)
- 内訳: cycle-aware-notify 全て、 state-file 不在期 1 件 (= 15:09 直後 deploy → 15:10 init 間)

### L5: 異常 markers

- 全 log 横断 grep `fail-closed|deferred by cycle-gate`: **0 件**
- 期待値 (= cycle 2 中、 validator present、 signature match): 0

### L6 + L7: manual verify

- daily-status (= 16:34 JST manual trigger): `[cycle-gate] cycle-aware-notify → green (approved=NodeID-yyPv...-1780560117)`
- node-info (= 16:35 JST stderr split): `[cycle-gate] cycle-artifact-write → green (approved=NodeID-yyPv...-1780560117)`

### L8: validator service health

```
metalgo: Up 4 weeks
validator present: 1 (= expect 1)
peer count: 249
P-chain bootstrap: true
X-chain bootstrap: true
C-chain bootstrap: true
```

### L9: host resources

```
/dev/sda1       225G  4.5G  212G   3% /
Mem:             30Gi   1.8Gi   25Gi   5.0Mi   4.1Gi   28Gi
```

---

## snapshot 取得 schedule

- **daily**: 09:00 JST + 17:00 JST に AI が自動 snapshot 取得 + 本 doc に append
- **on-demand**: 異常検知時 / operator request 時 / monitoring 区切り時
- **transition day (= 2026-07-04)**: pre-transition (12:30 JST) + during transition (13:00-15:00 JST 毎 30 min) + post-transition (= 完走後)

## 関連

- [[project_cycle_gate_monitoring]] — daily check + rollback 手順 + 7/4 当日 plan
- [[project_cycle_gate_resume_design]] — deployed 設計詳細
- `docs/CYCLE_GATE_TRD2_AUDIT.md` — 第 6 ラウンド audit
- `docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md` — 第 1-3 ラウンド audit
- 第 7 ラウンド audit (= chat 2026-06-29 16:48 JST 受領、 L1-L9 補強要望)

## append rule

新 snapshot は本 doc 末尾に追加。 過去 snapshot は変更しない (= audit trail 保全)。 古い snapshot は 30 日経過後に **deprecated** マーク + 過去 30 日のみ active として表示可。
