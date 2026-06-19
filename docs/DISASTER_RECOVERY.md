# Disaster Recovery — VPS 完全死亡からの復旧手順

VPS が「明日突然消失」した時に、同じ NodeID を持つ validator を再稼働させるための手順書。**全工程の所要時間は 20 〜 30 分**(`scripts/vps-bootstrap.sh` + metalgo state sync 利用時)。

> 重要: NodeID は `staker.crt`/`staker.key` から決定論的に導出される(検証済、2026-05-19)。同じ鍵セットを別 VPS に展開すれば、まったく同じ NodeID で再稼働できる。**鍵さえ残っていれば validator アイデンティティは失われない**。

---

## 災害シナリオ

| 種別 | 影響範囲 | DR 適用 |
|---|---|---|
| A. VPS インスタンス完全消失 (validator host 側障害 / 削除事故) | サーバ全データ消失 | **全工程実施** |
| B. disk 破損のみ (再起動不能) | チェーンデータ消失、鍵は VPS にあれば残る | C へ降格(validator host で disk 再構築 → 鍵があれば工程 4 から) |
| C. metalgo データ破損 (DB corruption) | チェーンデータのみ | 工程 4(再 bootstrap)のみ |
| D. ネットワーク障害 (一時的) | 接続不能 | DR 不要、validator host status 待ち |

本書は **A シナリオ** を主軸に記述。B/C は工程の途中から適用可能。

---

## 前提: バックアップが揃っていること

### staker keys(NodeID 復活に必須)

- **保管場所**: Mac の `<your-staker-backup-dir>/staking/`
- **ファイル**:
  - `staker.crt` (X.509 cert, ~428 bytes) ← NodeID の源泉
  - `staker.key` (EC private key, ~241 bytes)
  - `signer.key` (BLS private key, 32 bytes)
- **検証**: 2026-05-19 にローカル metalgo(network=local)で `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v` 再現確認済
- **権限**: 600(owner only)

### Wallet keys(報酬受取に必須、validator 復活とは別レイヤ)

- Metal Wallet web wallet (24 語 mnemonic、紙バックアップ済)
- WebAuth wallet (紙バックアップ済)
- 詳細: operator-local notes 参照

### このリポジトリ(サイト + scripts + Caddyfile)

- GitHub(本リポ)に push 済
- `docker-compose.*.yml` / `caddy/Caddyfile` / `public/*` / `scripts/*` は全て git 上

### SSH key

- Mac の `~/.ssh/<your_validator_host_key>`(VPS root SSH 用) — VPS 新規作成時は VPS provider console から SSH key 投入で再使用可能

---

## ⚡ 短縮復旧手順 (推奨)

`scripts/vps-bootstrap.sh` を使う最短ルート (合計 20-30 分):

```sh
# 1. 新 VPS 起動(validator host Console、upgraded VPS Asian region、Ubuntu 22.04、SSH key 投入)
#    新 IP を取得

# 2. DNS 切替(edge CDN で A レコード更新、TTL 5 分)

# 3. VPS にログイン、bootstrap script 実行
ssh -i ~/.ssh/<your_validator_host_key> root@<新IP>
curl -fsSLO https://raw.githubusercontent.com/freedomyield/metal.freedom-yield.com/main/scripts/vps-bootstrap.sh
bash vps-bootstrap.sh
# → packages / ufw / SSH hardening / deploy user / repo clone / cron 全自動

# 4. staker keys を encrypted backup から復旧(Mac 側で)
scp -i ~/.ssh/<your_validator_host_key> ~/staker-backup.tar.gz.enc root@<新IP>:/tmp/

# 5. VPS 側で復号 + 配置
ssh -i ~/.ssh/<your_validator_host_key> root@<新IP>
STAKING=/var/lib/docker/volumes/metalgo_data/_data/staking
mkdir -p "$STAKING"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in /tmp/staker-backup.tar.gz.enc -out /tmp/restore.tar.gz
# (パスフレーズ入力)
tar xzf /tmp/restore.tar.gz -C /tmp
mv /tmp/staker-backup/staking/* "$STAKING/"
chmod 600 "$STAKING"/*
rm /tmp/restore.tar.gz
rm /tmp/staker-backup.tar.gz.enc
rm -rf /tmp/staker-backup

# 6. bootstrap script を再実行(Step 7 metalgo 起動が今度は走る)
bash <deploy_path>/scripts/vps-bootstrap.sh

# 7. .env 作成 → Caddy 起動
cd <deploy_path>
cat > .env <<EOF
DOMAIN=metal.freedom-yield.com
ACME_EMAIL=info@metal.freedom-yield.com
EOF
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# 8. GitHub repo Secret の SSH_HOST を新 IP に更新
#    → main に空 commit push で deploy 動作確認

# 9. NodeID 確認(同じになっているはず)
bash scripts/node-info.sh
# 期待: NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v
```

合計時間目安:
- Step 1-3: ~10 分(VPS 起動 + DNS + bootstrap script)
- Step 4-5: ~3 分(scp + 復号 + 配置)
- Step 6-7: ~5 分(metalgo state sync + Caddy)
- Step 8-9: ~2 分(Secret 更新 + 確認)

state sync が効くため metalgo は **数分** で current tip に到達 (full bootstrap の 60 分ではない)。

詳細手順や troubleshooting は以下の「全工程手動版」を参照。

---

## 全工程手動版 (A シナリオ: VPS 完全消失)

### Step 1: 新 VPS を起動 (5 〜 10 分)

1. VPS provider console → Project → 新規 Server
2. スペック: **production-grade VPS** (official-minimum-class or above)
   - 旧と同じか、上位互換
3. OS: **Ubuntu 22.04 LTS**(metalgo 動作確認済)
4. SSH key: 既存の `<your_validator_host_key>` public key を投入
5. Server 名: 任意 (運用の慣習に従う)
6. 起動完了 → 新 IP を VPS provider console から取得(operator-local notes へ)

### Step 2: DNS 切替 (5 分 + edge CDN TTL 待ち)

1. edge CDN → metal.freedom-yield.com → DNS
2. `A` レコードの IP を新 VPS の IP に変更
3. TTL は 5 分(短く設定済)
4. 伝播確認: `dig metal.freedom-yield.com +short` で新 IP が返るのを確認

### Step 3: VPS 初期セットアップ (15 分)

```sh
# Mac から
ssh -i ~/.ssh/<your_validator_host_key> root@<新IP>

# 以下、新 VPS の root として実行
apt update && apt upgrade -y
apt install -y docker.io docker-compose-v2 ufw fail2ban git jq curl

# firewall (旧と同じポリシー)
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 9651/tcp
ufw --force enable

# SSH ハードニング (パスワード認証無効化)
cat > /etc/ssh/sshd_config.d/99-disable-password.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sshd -t && systemctl reload ssh

# <deploy_user> (GitHub Actions 用)
useradd -m -s /bin/bash <deploy_user>
mkdir -p <deploy_user_home>/.ssh
# (GitHub Actions の公開鍵を <deploy_user_home>/.ssh/authorized_keys に投入)
# 公開鍵は GitHub repo Secrets の SSH_KEY に対応するペア
chown -R <deploy_user>:<deploy_user> <deploy_user_home>/.ssh
chmod 700 <deploy_user_home>/.ssh && chmod 600 <deploy_user_home>/.ssh/authorized_keys
```

### Step 4: 本リポを clone + staker keys を投入 (10 分)

```sh
# VPS 上で
cd /opt
git clone https://github.com/<owner>/metal.freedom-yield.com.git metal-validator
cd metal-validator

# Mac から staker keys を新 VPS へ転送(Mac で実行)
# ⚠️ 同 NodeID で 2 ノード mainnet 接続は厳禁。旧 VPS が死んでいることを確認してから投入
scp -i ~/.ssh/<your_validator_host_key> -r <your-staker-backup-dir>/staking/* root@<新IP>:/tmp/staking/

# VPS 上で、docker compose volume の場所に配置
# (docker-compose.metalgo.yml の volume mount 先に合わせる)
mkdir -p /var/lib/metalgo/staking
mv /tmp/staking/* /var/lib/metalgo/staking/
chown -R 1000:1000 /var/lib/metalgo  # metalgo container uid
chmod 600 /var/lib/metalgo/staking/*
```

### Step 5: .env 作成 + metalgo 起動 (60 分: bootstrap 込み)

```sh
cd /opt/metal-validator
cat > .env <<EOF
METALGO_NETWORK_ID=mainnet
# (旧 .env と同じ設定、リポ管理外)
EOF

# 起動
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml up -d

# NodeID 確認(復旧成否の決定点)
sleep 30
curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
  http://localhost:9650/ext/info | jq -r '.result.nodeID'
# 期待値: NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v

# bootstrap 進捗監視
watch -n 30 'curl -sS -X POST -H "content-type:application/json" \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"P\"}}" \
  http://localhost:9650/ext/info'
# P/X/C 全部 true になるまで待機(通常 30 〜 60 分、state sync で更に速い)
```

### Step 6: Caddy + サイト復活 (10 分)

```sh
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# Let's Encrypt 自動取得を待つ(初回 1 〜 2 分)
sleep 60
curl -sS https://metal.freedom-yield.com/ | head -1
# 期待値: HTTP/2 200 + HTML 返却
```

### Step 7: GitHub Actions deploy の宛先更新 (5 分)

GitHub repo → Settings → Secrets → `SSH_HOST` を **新 IP** に更新。  
他の secrets(`SSH_USER` / `SSH_KEY` / `DEPLOY_PATH`)は変更不要(キー継続使用)。

main ブランチに空コミット push してデプロイ動作を確認。

### Step 8: validator.json 自動更新の復活 (3 分)

```sh
# cron で scripts/node-info.sh が動いているか確認
crontab -l | grep node-info
# 旧と同じ schedule で再登録
(crontab -l 2>/dev/null; echo "*/5 * * * * cd /opt/metal-validator && ./scripts/node-info.sh > /tmp/node-info.log 2>&1") | crontab -

# 手動実行で出力確認
cd /opt/metal-validator && ./scripts/node-info.sh
cat public/api/validator.json | jq .nodeId
# 期待値: "NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
```

---

## 復旧完了の checklist

- [ ] 新 VPS で `info.getNodeID` が `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v` を返す
- [ ] P/X/C 全 chain で `isBootstrapped: true`
- [ ] `https://metal.freedom-yield.com/` が HTTPS で開く
- [ ] サイト上で `validator-data` の値が live で表示される
- [ ] explorer で uptime が再上昇開始(復旧時点で一時的に下がるが、継続稼働で回復)
- [ ] GitHub Actions の最新 deploy が success
- [ ] ufw / fail2ban / SSH パスワード認証無効化が new VPS にも適用済
- [ ] cron で `scripts/node-info.sh` が回っている

---

## バリデート期間中に復旧する場合の注意

- 復旧中の downtime は uptime 評価に影響(80% 下回ると報酬ゼロ)
- 16 日間 duration の場合: **連続 ~76 時間以上の downtime で 80% 割れ**(初日からゼロ前提の計算)
- 復旧が遅延しそうなら、期間終了を待って **新期間で再登録**(downtime 不問になる)も選択肢
  - ただし NodeID は同じまま、stake は P-Chain に解放後に再投入

---

## 鍵を全て失った最悪シナリオ(NodeID 復活不可)

`staker.crt` / `staker.key` が Mac + VPS 両方で失われた場合、**同 NodeID は二度と再現できない**。

その場合の対処:
1. 新 NodeID で新規 validator を立ち上げ
2. サイト・docs・GitHub Actions の NodeID を全て新値に更新
3. 委任者には公開アナウンスで NodeID 変更通知(現在 delegator ゼロのため影響なし)
4. 過去の uptime track record は失われる

→ **これを防ぐため、Mac の `<your-staker-backup-dir>/` は別マシン or USB へ暗号化 backup する**(TODO、未実施)

---

## 関連

- `docs/VALIDATOR_HOST_SETUP.md` — VPS 初期セットアップ詳細
- `docs/KEY_ROTATION.md` — 鍵を **意図的に** 変更する場合の手順(本 DR とは別物)
