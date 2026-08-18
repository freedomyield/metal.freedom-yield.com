# Incident Response Runbook

障害発生時に何を確認・誰に連絡・どう復旧するかをまとめた運用ハンドブック。

## 1. 重要度分類 (SEV)

| SEV | 状態 | 例 | 一次対応 SLA |
|---|---|---|---|
| **SEV-1 Critical** | 重大障害・公的説明必須 | staking key 漏洩疑い、mainnet active 中の連続 24h+ ダウン、delegator 資金影響 | **15 分以内** |
| **SEV-2 High** | サービス機能停止 | サイト完全 down、metalgo 4h+ 連続ダウン、`info.uptime` 急落 (80% 割れ) | **30 分以内** |
| **SEV-3 Medium** | 部分的・性能劣化 | TLS 期限警告、サイト遅延、deploy 失敗連続、Volume IOPS 警告 | **2 時間以内** |
| **SEV-4 Low** | 軽微 | 1 ページ表示崩れ、ログ警告、軽微な誤字 | **次の営業日** |

判断に迷ったら一段階高めに分類(後で下げるのは容易、上げるのは遅れる)。

## 2. 検出ソース

| ソース | 監視対象 | 通知方法 |
|---|---|---|
| GitHub Actions deploy workflow | デプロイ成功率 | 失敗 → email |
| Uptime check workflow | サイト HTTP 200 + TLS 期限 | ワークフロー失敗 → email |
| edge CDN dashboard | DNS / WAF / 帯域 | 設定で email アラート |
| VPS provider console | 課金・traffic 超過・サーバ状態 | 設定で email アラート |
| `metalgo health` API | P/X/C-Chain bootstrap 状態 | 自前 cron で監視 |
| `info.uptime` API | 自分の validator のネットワーク評価値 | 自前 cron で 80% 割れ警告 |
| メール受信 | `info@metal.freedom-yield.com` 宛 | email forwarding service 経由 |

## 3. 障害種別ごとの対応

### 3.1 サイトダウン (HTTP 非 200 / TLS エラー)

**症状**: 外部からアクセス不可、Uptime check が連続 fail。

**調査手順**:

```bash
# 1. 外部から確認
curl -sI https://metal.freedom-yield.com/ | head -3

# 2. DNS 解決
dig +short metal.freedom-yield.com A

# 3. edge CDN 経由 vs origin direct (origin IP は秘匿、内部メモから参照)

# 4. web host に SSH
# ssh <deploy_user>@<web host from internal notes>

# 5. Caddy コンテナ状態
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs caddy --tail 30

# 6. ディスク容量
df -h /

# 7. ufw / Cloud Firewall ルールが壊れていないか
sudo ufw status verbose
```

**対応分岐**:

- Caddy crashed → `docker compose -f docker-compose.yml -f docker-compose.prod.yml restart caddy`
- Caddyfile syntax error → 直近の編集をロールバック → `caddy reload --config /etc/caddy/Caddyfile`
- ディスクフル → `docker system prune -a` / `journalctl --vacuum-size=100M`
- VPS 自体停止 → VPS provider console から再起動 → 5 分待って再確認
- DNS 消失 → edge CDN dashboardで A レコード復元
- TLS 期限切れ → Caddy 再起動で Let's Encrypt 自動更新を再走らせる。それでも駄目なら ACME challenge 経路 (HTTP-01 が edge proxy でブロックされていないか) を確認

### 3.2 metalgo container down / unhealthy

**症状**: `docker compose ps` で metalgo が unhealthy / restarting / exited、または `info.getNodeID` API が応答なし。

**調査手順**:

```bash
# 1. コンテナ状態
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml ps

# 2. 最近のログ(エラー原因の特定)
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml logs metalgo --tail 100

# 3. リソース使用率(OOM か CPU 詰まりか)
docker stats --no-stream
free -h
df -h /  # data volume の空き

# 4. データボリュームの状態
docker volume ls

# 5. API 直接呼び出し
curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
  http://localhost:9650/ext/info
```

**対応分岐**:

- OOM kill → mem_limit を上げる、または VPS plan を上位に
- ディスクフル → C-Chain pruning を実行 (`pruning-enabled=true` config)、または Volume 拡張
- corrupted state → 最終手段: data volume を破棄し再 bootstrap(数時間〜)。**mainnet では staking key を別途救出してから**
- network connectivity 喪失 → ufw / provider firewall で 9651 が通っているか確認
- image bug → image tag を 1 つ前の安定版に pin して再起動

### 3.3 Validator uptime 低下 (`info.uptime` < 80%)

**症状**: 自分の `info.uptime` ネットワーク評価値が 80% を割っている。継続すると報酬ゼロ。

**注意**: METAL は **スラッシングなし**。経済損失は「報酬機会の喪失」のみ。元本(stake)は守られる。

**調査手順**:

```bash
# 1. ピア接続数
curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"info.peers"}' \
  http://localhost:9650/ext/info | jq '.result.numPeers'

# 2. 自分の uptime(ネットワーク評価)
curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"info.uptime"}' \
  http://localhost:9650/ext/info

# 3. health check 全体
curl -sS http://localhost:9650/ext/health
```

**対応分岐**:

- numPeers が極端に少ない → public IP / port 9651 が他 validator から到達できていない。provider firewall / ufw / `--public-ip` フラグの 3 つを確認
- 直近 OOM や crash 履歴あり → リソース増強 + image 更新
- 時刻 drift → `timedatectl` で NTP 同期状態確認、`systemctl restart systemd-timesyncd`
- 長期 (数時間〜) 復旧しない → SEV-1 にエスカレーション。サイト `/incidents/` で開示

### 3.4 Staking key 漏洩疑い (SEV-1)

**症状**: `staker.key` / `signer.key` が外部に出た可能性(USB 紛失、誤コミット、bind mount 経路の権限事故、第三者のサーバ侵入、etc.)。

**即座の対応**:

```bash
# 1. metalgo を停止(攻撃者が validator を勝手に動かすのを止める)
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml down

# 2. host の他の侵入痕跡を確認
last -n 50
sudo journalctl --since "24 hours ago" | grep -iE 'sshd|sudo'
sudo find / -newer /etc/passwd -not -path '/proc/*' -not -path '/sys/*' 2>/dev/null | head -20
```

**判断 (active stake があるか)**:

- active stake あり → endTime まで攻撃者が一時的に validator を動かせる(報酬を盗まれるが、元本は守られる)。endTime 待ち + 新 NodeID の準備
- pending only → 即時 cancel は不可だが、stake が active 入りする前に新 NodeID で stake し直す手段を検討
- 詳細は [KEY_ROTATION.md の "漏洩疑い時の緊急対応"](KEY_ROTATION.md#漏洩疑い時の緊急対応) 参照

**情報開示**: サイト `/incidents/` に経緯を SEV-1 として公開(信用情報サイトの責務)。後述の post-mortem テンプレで。

### 3.5 Long downtime (provider outage / 自然災害 / etc.)

**症状**: VPS が 1 時間以上応答なし、provider status page で region 障害発表など。

**対応**:

1. provider status page を確認
2. SEV-2(復旧見込みあり) or SEV-1(復旧不能 / 数時間以上)に分類
3. SEV-1 の場合: 別 region に VPS を立てて metalgo を新規 NodeID で立ち上げる選択肢。ただし新 NodeID = 新 stake になるので**短期判断は慎重に**。**通常は復旧を待つ**(METAL は slashing なし、報酬機会ロスのみ)
4. サイト側は別 host に rsync して継続(/incidents/ 開示も)

### 3.6 Bootstrap fail / 再同期が必要

**症状**: 起動後何時間経っても bootstrap が完了しない、または `accepted state summary "Skipped"` 等のログが繰り返し出る。

**対応**:

```bash
# 1. ログ詳細
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml logs metalgo --tail 200 | grep -E "WARN|ERROR|bootstrap"

# 2. データボリュームを破棄して再 bootstrap (mainnet では staking key を救出してから!)
# staking key を tar で別場所に backup
docker run --rm -v metalgo_data:/data -v "$PWD/backup":/backup alpine \
  tar czf /backup/staking-rescue-$(date +%Y%m%d).tar.gz -C /data staking

# 3. data volume だけリセット(staking 以外)、staking dir は新 volume に戻す
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml down -v
docker volume create metalgo_data
docker run --rm -v metalgo_data:/data -v "$PWD/backup":/backup alpine \
  tar xzf /backup/staking-rescue-*.tar.gz -C /data

# 4. 再起動
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml up -d
```

⚠️ staking dir(`staker.crt` / `staker.key` / `signer.key`)を救出せずに volume を消すと **NodeID が変わる**。**mainnet では絶対に注意**。詳細は [KEY_ROTATION.md](KEY_ROTATION.md)。

## 4. エスカレーション

- **SEV-1**: 即時、Discord / Twitter で簡潔に開示「現在 SEV-1 障害対応中、詳細は後ほど」
- **SEV-2**: 30 分以内に類似の開示
- **SEV-3**: 復旧後 24 時間以内に開示
- **SEV-4**: post-mortem は任意

開示先:

- サイト `/incidents/` ページ(全 SEV)
- X / Twitter (SEV-1, SEV-2)
- Discord(招集後、または delegator コミュニティ)

## 5. Post-mortem テンプレート

復旧後 1 週間以内に `public/incidents/<YYYY-MM-DD>-<slug>.html` として publish。

```markdown
# Incident: <短いタイトル>

- **Date**: YYYY-MM-DD HH:MM JST 発生 / HH:MM 復旧
- **SEV**: SEV-X
- **Duration**: X 時間 Y 分
- **Impact**: (delegator への影響、報酬影響額、サイトダウン分など定量化)

## Timeline

- HH:MM 検出 (検出ソース: ...)
- HH:MM 一次対応開始
- HH:MM 原因特定
- HH:MM 復旧措置適用
- HH:MM 復旧確認

## Root cause

(技術的な原因。「なぜそうなったか」を 5 Why で深掘り)

## What went well

- ...

## What went poorly

- ...

## Action items

| # | アクション | 期限 |
|---|---|---|
| 1 | (再発防止策) | YYYY-MM-DD |
| 2 | (検出改善) | YYYY-MM-DD |

## Lessons learned

(同様のインシデントを次回どう避けるか、運用知見として)
```

## 6. 未公開の開示 entry の staging (`docs/pending-disclosures/`)

開示すると決まったが**公開のタイミングが先の日付に固定されている** entry は、
`docs/pending-disclosures/<incident-id>.json` に git-tracked で置く。

なぜこのディレクトリが要るか: 開示は通常「決めた日にそのまま
`public/api/incidents.json` へ append する」(2026-06-24-01 / 2026-08-06-01 は
どちらもそうした) が、cycle 転換に紐づく開示だけは
[`CYCLE_GATE.md`](CYCLE_GATE.md) の step 2.5 で **step 3 より前**という順序制約
を負う。当日まで本文が repo の外 (session の scratch) にあると、当日それを
探すところから始まる = 事故の元。

ルール:

- ファイルの中身は **`incidents[]` にそのまま入る entry オブジェクト 1 個**。
  ラッパーもメタデータも付けない。公開される bytes と同一にしておき、当日は
  挿入するだけにする (step 2.5 手順 1 の `jq --slurpfile`)。
- ファイル名は `<incident-id>.json`。id は `public/api/incidents.json` の
  `id` と同じ `YYYY-MM-DD-NN` 形式。
- `docs/**` は [`deploy.yml`](../.github/workflows/deploy.yml) の `paths-ignore`
  に入っているので、**ここに置いても公開面は動かない**し、署名済み manifest の
  pin も破らない。公開は step 2.5 で `public/api/incidents.json` に入った時に
  初めて起きる。
- 公開したら **step 4b の commit でこのファイルを削除する**。本文が 2 箇所に
  あると必ず片方が古くなる。
- `tests/incidents/test-schema.sh` がこのディレクトリを毎回検査する:
  各ファイルは schema の incident 定義に適合しなければならず、ファイル名と
  `id` は一致していなければならず、**その id が既に `incidents.json` に
  publish されていたら FAIL** (= 削除忘れの検出)。ディレクトリが空なら
  検査は 0 件で通る = 平常時は何も要求しない。

## 7. 関連

- [docs/KEY_ROTATION.md](KEY_ROTATION.md) — staking key 取扱・漏洩対応
- [docs/DEPLOY_SETUP.md](DEPLOY_SETUP.md) — VPS 設定・GH Actions 接続
- [SECURITY.md](../SECURITY.md) — 外部からの脆弱性報告窓口
