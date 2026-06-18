# Tahoe → Mainnet 移行手順

Tahoe testnet で運用パイプラインを検証してから、Metal Blockchain mainnet validator として本番化するための差分一覧と手順。

## 大前提

- **testnet key と mainnet key は完全分離**(同じ key を使い回さない、ファイル名・volume も別)
- 本番開始は **2,000 METAL を確保し、 [docs/KEY_ROTATION.md](KEY_ROTATION.md) のセキュリティ要件を満たしてから**
- VPS (production-grade、Metallicus が公開する minimum recommendation を満たす) でホストし、port 9651 を public IP に開ける

## Tahoe vs Mainnet 差分一覧

| 項目 | Tahoe(testnet、現在) | Mainnet(本番、移行先) |
|---|---|---|
| metalgo 起動 flag | `--network-id=tahoe` | フラグなし(mainnet がデフォルト) |
| 最小 validator stake | 1 METAL(無料、faucet) | **2,000 METAL** (at protocol minimum) |
| 最小委任額 | n/a | 25 METAL |
| 最小 validation 期間 | 2 週間 | 2 週間 |
| 最大 validation 期間 | 1 年 | 1 年 |
| delegation fee 下限(プロトコル強制) | 2% | 2% |
| delegation fee 本リポ方針 | n/a | operator-chosen, above 2% protocol floor |
| Slashing | なし(報酬ゼロのみ) | なし(同上) |
| Explorer | https://tahoe.metalscan.io/ | https://explorer.metalblockchain.org/ |
| C-Chain RPC | https://tahoe.metalblockchain.org/ext/bc/C/rpc | https://api.metalblockchain.org/ext/bc/C/rpc |
| C-Chain ID | 381932 | (公式 docs で確認、メインネット ID) |
| Faucet | https://faucet.metalblockchain.org/ | なし(取引所購入 or OTC) |
| ホスト | ローカル PC(127.0.0.1 bind) | **production-grade VPS、port 9651 を public IP に bind** |
| Storage | named volume(state ~数 GB) | 500GB〜1TB NVMe(state は伸びる、定期 pruning) |
| staking key | testnet 専用、捨てて OK | **長期保存、暗号化 backup、漏洩時の経済損失あり** |

## 移行手順(順序付き)

### 段階 1: Tahoe での検証完了確認

mainnet に移る前に、Tahoe で以下を**全て**検証済にする:

- [ ] `make node-up` で metalgo 起動、`make node-status` で NodeID 取得成功
- [ ] faucet → Tahoe wallet → 自分の NodeID への delegation tx 成功
- [ ] `info.getCurrentValidators` で自分の NodeID が validator set に含まれる
- [ ] `info.uptime` API の形状理解(公開 IP でない環境では 0 評価が想定通り)
- [ ] `make node-down` → `make node-up` で staking key/state 永続化を確認
- [ ] [docs/KEY_ROTATION.md](KEY_ROTATION.md) の backup 手順を実機で 1 回練習

### 段階 2: 資金・サーバ準備

- [ ] **2,000 METAL** 以上を取引所 or OTC で確保(buffer 込みで 2,500 以上推奨)
- [ ] VPS アカウント作成 → production-grade VPS 起動
- [ ] OS Ubuntu 22.04 LTS、追加 NVMe volume 500GB-1TB
- [ ] ufw 設定: inbound は **9651/TCP** と **22/TCP(SSH 鍵限定)** のみ
- [ ] Docker + Docker Compose v2 をインストール
- [ ] 本リポを clone、`git config core.hooksPath .githooks`

### 段階 3: mainnet 用 docker-compose.prod.yml 作成

ローカルの `docker-compose.metalgo.yml` をベースに、以下を変更した `docker-compose.prod.yml` を新規作成:

```yaml
# docker-compose.prod.yml (mainnet 用、VPS で実行)
services:
  metalgo:
    image: metalblockchain/metalgo:<version-pinned>  # latest ではなく tag 固定
    container_name: metalgo-mainnet
    command:
      - /metalgo/build/metalgo
      # --network-id=tahoe を削除(mainnet がデフォルト)
      - --http-host=127.0.0.1   # public RPC は出さない、別途 reverse proxy 経由
      - --http-port=9650
      - --staking-port=9651
      - --public-ip=<VPS public IP>   # 必須、ピアから到達可能にする
      - --log-level=info
      - --data-dir=/data
    ports:
      - "127.0.0.1:9650:9650"   # API は localhost のみ
      - "9651:9651"             # P2P を public に公開(public IP からアクセス可能に)
    # ... 残りは既存と同じ(read_only / cap_drop ALL / no-new-privileges)
    mem_limit: 16g     # mainnet では公式最小に従う
    cpus: 8.0
```

**起動**:
```sh
docker compose -f docker-compose.prod.yml up -d
```

### 段階 4: staking key の新規生成 + 安全な保存

mainnet 用に**全く新しい** staking key を生成する(testnet key は流用厳禁)。

1. compose 初回起動時、metalgo が `/data/staking/staker.crt`、`staker.key`、`signer.key` を自動生成
2. **生成直後**に backup を取り、暗号化保管: [docs/KEY_ROTATION.md](KEY_ROTATION.md) の backup 手順参照
3. NodeID を取得: `bash scripts/node-info.sh` (mainnet 用に METALGO_API を調整可)
4. mainnet 用 NodeID をメモ。これが**本番の信用情報の核**になる

### 段階 5: mainnet validator として P-Chain に登録

1. Metal Wallet (mainnet モード) で 2,000 METAL 以上を保管しているアドレスから:
2. **Add Validator** tx を送信:
   - NodeID: 段階 4 で取得したもの
   - stake: 2,000 METAL 以上
   - start time: 数分後(同期完了確認後)
   - end time: 1 年後推奨(更新を計画的に)
   - delegation fee: operator-chosen, above 2% protocol floor
3. `info.getPendingValidators` で自分の NodeID が pending に入ったか確認
4. start time 到達後、`info.getCurrentValidators` で active に移行を確認

### 段階 6: サイトを mainnet モードに切り替え

サイト側のテキストと API を mainnet 用に書き換える:

- [ ] `public/index.html` / `public/ja/index.html`: "Phase 0" → "Phase 1 — live on mainnet"
- [ ] `public/index.html` / `public/ja/index.html`: hero-eyebrow を "Tahoe testnet preparation" → "Validator live"
- [ ] `scripts/node-info.sh`: `mode` を `"mainnet"` に固定 or 自動判別
- [ ] `public/api/validator.json` の `explorer` を `https://explorer.metalblockchain.org/` に
- [ ] `caddy/Caddyfile` CSP の `connect-src` に mainnet explorer/RPC URL を追加(必要なら)
- [ ] `public/robots.txt`: 14 日連続 uptime 達成後、`Disallow: /` を削除(検索エンジン indexing 有効化)
- [ ] サイト deploy: `docker-compose.prod.yml` の Caddy を VPS で起動、edge DNS A レコード `metal.freedom-yield.com` → VPS IP

### 段階 7: 監視・通知

- [ ] `info.uptime` を定期取得(cron / systemd timer)
- [ ] uptime < 80% でアラート(Telegram / Discord / email)
- [ ] disk usage > 80% でアラート
- [ ] metalgo container down でアラート
- [ ] 詳細は `docs/INCIDENT_RESPONSE.md`(将来作成)

### 段階 8: 14 日連続 uptime 達成後

- [ ] robots.txt の `Disallow: /` を削除
- [ ] Google Search Console / Bing Webmaster に登録
- [ ] サイトに「14 日連続 uptime 達成」を公開
- [ ] delegation を本格的に受け付け開始

## サイト側で testnet 表示を残すか

選択肢:

- (a) **完全に mainnet モードに切替**(推奨): testnet 情報は GitHub の commit history に残す
- (b) **testnet/mainnet 両方を表示**: ヘッダで切替、開発透明性を強調
- (c) **testnet を `/tahoe/` に退避**: メインは mainnet、技術的興味のあるユーザに見せる

最初は (a) で十分。後で必要なら (c) に移行。

## やってはいけないこと

- testnet 用 staking key を mainnet で**絶対に使い回さない**(逆も同様)
- `staker.key` / `signer.key` を平文で backup する(必ず暗号化)
- delegation fee を後から下げる(委任者の信頼を損なう、最初から低めに設定)
- start time 直後に検証完了せず、active 入りで「未同期 validator」になる(他 validator から低評価)
- mainnet 切替と同時にサイトの URL 構造を変える(検索ランキングへの影響を分離)

## 関連

- [docs/KEY_ROTATION.md](KEY_ROTATION.md) — key 管理 / backup / 漏洩対応
- [README.md](../README.md) — リポ全体の構成
