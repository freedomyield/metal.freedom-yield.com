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
| D. ネットワーク障害 (一時的、数十秒〜数分) | 接続不能 | DR 不要、validator host status 待ち |
| E. 経路断 (host は生存・外から不達が続く) | VM と metalgo は稼働、外部から到達不能 | **「経路断シナリオ」節** (fencing が先、移設は operator 判断) |

本書は **A シナリオ** を主軸に記述。B/C は工程の途中から適用可能。

### ⚠️ 警告: 現行本番 host の metalgo は、repo の compose とは別の名前で動いている

2026-10-02 に本番 host を read-only で実測した結果、現行本番 host (repo の初回 commit より前に作成) の metalgo は、**repo より前からある別の compose project 名・コンテナ名・named volume 名**で動いている。repo の compose ファイルからは別の名前になる (project = `docker-compose.metalgo.yml:17` の `name: metalgo-stack`、コンテナ = `docker-compose.metalgo.prod.yml` の `container_name: metalgo-${METAL_NETWORK:-mainnet}` → mainnet では `metalgo-mainnet`、volume = `metalgo-stack_metalgo_data`)。本番側の実名は本書に書かない (Constitution §4.1 S9 / §4.2 C5。operator-local notes 参照)。

- **現行本番 host で、今の repo のファイルのまま metalgo の `docker compose ... up -d` を実行してはいけない。** compose は別 project として **新しい空の volume** を作り、その metalgo は staker keys を見つけられず **新しい鍵を生成 = 別の NodeID** で起動しようとする。旧コンテナの横に 2 つ目の stack ができる (旧コンテナが動いていれば port 衝突で起動に失敗するが、volume とコンテナは残る。旧コンテナが止まっている時なら別 NodeID のまま起動する)。
- 同じ形のコマンドを案内している箇所がある: `docs/INCIDENT_RESPONSE.md`、`docs/VALIDATOR_HOST_SETUP.md` (どちらも該当箇所に 1 行の警告あり)。現行本番 host ではこれらの metalgo 用 compose コマンドも同じ扱い。`scripts/check-anomalies.sh` の通知の対処欄は label で特定し、既存コンテナを `docker start` する形に改めた (2026-10-02、`tests/anomalies/test-metalgo-advice-body.sh` で固定)。
- `scripts/vps-bootstrap.sh` の step_metalgo は、別 project の metalgo コンテナを見つけると何も作らず止まる (fail closed)。
- 名前を固定で仮定しない。本書の手順は metalgo コンテナを compose label `com.docker.compose.service=metalgo` で特定する。
- この label 特定は compose の service 名が `metalgo` であることを前提にしている。現行本番 host でも、この label が付いた metalgo コンテナがちょうど 1 つであることを 2026-10-02 に read-only で実測した (operator 承認)。将来この label が違っていれば、label による特定と `scripts/vps-bootstrap.sh` の他 project 検出 (`resolve_metalgo_data_dir`、`:327`) はそのコンテナを見落とす。
- **本番 host の命名を repo に揃えるか (またはその逆か) は未決の operator 判断。** 本書では揃えない。新 host への移設は repo の命名で新規に作るので、この問題は旧 host 側にだけ残る。

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
- **TODO(未確認)**: validator host 上の git 管理外設定 `/etc/freedom-yield/`(`web-host` / `ntfy-topic` / `calendar-token` / `wallet-addresses.json` / `watch-list.json` 等)と `.env` の `OPS_BASIC_AUTH_HASH` が host 外にバックアップされているかは未確認

### SSH key

- Mac の `~/.ssh/<your_validator_host_key>`(VPS root SSH 用) — VPS 新規作成時は VPS provider console から SSH key 投入で再使用可能

---

## ⚡ 短縮復旧手順 (推奨)

`scripts/vps-bootstrap.sh` を使う最短ルート (合計 20-30 分):

> **⛔ 関門 (鍵を置く前に必ず):** 旧 VM がまだ生きている可能性があるなら (経路断シナリオ、または A か E か判別できない時)、**ここで止まる**。「経路断シナリオ」節の 4. Fencing を完了し、provider の control plane (Console / API) で旧 server が **Off** (または削除済み) と表示されるまで、Step 4 以降 (鍵の転送・配置・metalgo 起動) に進まない。同じ NodeID の 2 ノードが mainnet に出るのを防ぐため。

```sh
# 1. 新 VPS 起動(validator host Console、upgraded VPS Asian region、Ubuntu 22.04、SSH key 投入)
#    新 IP を取得

# 2. DNS 切替(edge CDN で A レコード更新、TTL 5 分)

# 3. VPS にログイン、bootstrap script 実行
ssh -i ~/.ssh/<your_validator_host_key> root@<新IP>
curl -fsSLO https://raw.githubusercontent.com/freedomyield/metal.freedom-yield.com/main/scripts/vps-bootstrap.sh
bash vps-bootstrap.sh
# → packages / ufw / SSH hardening / deploy user / repo clone / cron 全自動
#   この時点では .env が無いので step_metalgo は
#   「NOTE: <deploy_path>/.env not present — metalgo not started and its data dir not resolved.」
#   を出して metalgo を起動しない(想定どおり。scripts/vps-bootstrap.sh:372)。鍵は Step 6 の手順で置く

# 4. staker keys を encrypted backup から復旧(Mac 側で。冒頭の関門を通過していること)
scp -i ~/.ssh/<your_validator_host_key> ~/staker-backup.tar.gz.enc root@<新IP>:/tmp/

# 5. VPS 側で .env 作成(metalgo 起動より前。metalgo と Caddy は同じ <deploy_path>/.env を読む)
#    METAL_NETWORK / METAL_PUBLIC_IP は docker-compose.metalgo.prod.yml の command で
#    「:?」必須 → 無いと metalgo は起動しない。METAL_STAKING_BIND は
#    docker-compose.metalgo.yml の ports で既定 127.0.0.1(= ピア不達、uptime ゼロ)。
#    ACME_EMAIL / OPS_BASIC_AUTH_HASH は docker-compose.prod.yml で「:?」必須(Caddy)。
#    METALGO_DATA_PATH は旧 .env で使っていた場合のみ同じ値を入れる(Step 6 は実際の
#    mount 先を compose から引くので、どちらでも動く)。METAL_IMAGE_TAG / METAL_MEM_LIMIT /
#    METAL_CPUS は任意(旧 .env に値があれば揃える)。
ssh -i ~/.ssh/<your_validator_host_key> root@<新IP>
# 平文の鍵が /tmp に残らないよう、この session の終了時 (途中の失敗・切断を含む) に必ず消す
trap 'rm -rf /tmp/restore.tar.gz /tmp/staker-backup' EXIT
# 途中で失敗して手で中断する時も、session を離れる前に同じ rm -rf を実行する
# (session が切れて trap が走ったか不明なら、再ログインして同じ rm -rf を実行する)
cd <deploy_path>
umask 077
cat > .env <<EOF
METAL_NETWORK=mainnet
METAL_PUBLIC_IP=<新IP>
METAL_STAKING_BIND=0.0.0.0
DOMAIN=metal.freedom-yield.com
ACME_EMAIL=info@metal.freedom-yield.com
OPS_BASIC_AUTH_HASH='<bcrypt hash、operator-local 保管>'
EOF

# 6. 鍵の置き場を確定 → 復号 + 配置 → 公開前の NodeID 確認
# 鍵の置き場 = metalgo コンテナの /data の mount 元。compose 自身から引く(起動はしない)
#   compose の project 名は docker-compose.metalgo.yml:17 の `name: metalgo-stack` なので、
#   /data の named volume(docker-compose.metalgo.prod.yml:49)の実体は
#   metalgo-stack_metalgo_data(metalgo_data ではない)。METALGO_DATA_PATH を使う場合はその path
#   (コンテナ名は固定で仮定しない。compose label で特定する。冒頭の警告参照)
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml create metalgo
docker ps -a --filter label=com.docker.compose.service=metalgo \
  --format '{{.ID}} {{.Names}} {{.Label "com.docker.compose.project"}}'
# 期待: 1 行だけ(新 host なので)。2 行以上なら止まる
CID=$(docker ps -a -q --filter label=com.docker.compose.service=metalgo)
DATA=$(docker inspect "$CID" \
  --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')
echo "$DATA"
# 期待(named volume の場合): /var/lib/docker/volumes/metalgo-stack_metalgo_data/_data
# (scripts/vps-bootstrap.sh の step_metalgo も同じ方法で置き場を引く)
STAKING="$DATA/staking"
mkdir -p "$STAKING"
chmod 700 "$STAKING"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in /tmp/staker-backup.tar.gz.enc -out /tmp/restore.tar.gz
# (パスフレーズ入力)
tar xzf /tmp/restore.tar.gz -C /tmp
mv /tmp/staker-backup/staking/* "$STAKING/"
# コンテナは root で動く(image に USER 指定なし)→ root 所有・600
chown root:root "$STAKING"/*
chmod 600 "$STAKING"/*
rm /tmp/restore.tar.gz
rm /tmp/staker-backup.tar.gz.enc
rm -rf /tmp/staker-backup
# 公開前の NodeID 確認: ネットワーク無し・staking 読み取り専用で metalgo を一時起動し、
# 起動ログの nodeID を読む(mainnet にも他ノードにも一切つながらない)
# image tag は .env で METAL_IMAGE_TAG を pin しているならその tag
docker run -d --name nodeid-check --network none -v "$STAKING:/data/staking:ro" \
  metalblockchain/metalgo:latest /metalgo/build/metalgo --network-id=local --data-dir=/data
sleep 15
docker logs nodeid-check 2>&1 | grep -o '"nodeID": *"[^"]*"' | sort -u
docker rm -f nodeid-check
# 期待: "nodeID": "NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
# 違う値・空なら起動に進まない(鍵の置き場か中身が違う。鍵が無いと metalgo は新しい鍵を作る)

# 7. metalgo と Caddy を起動
#    vps-bootstrap.sh の再実行でも起動はできる (step_metalgo は resolve_metalgo_data_dir
#    (scripts/vps-bootstrap.sh:325) で Step 6 と同じ /data の mount 元を引き、鍵があれば
#    :394 の metalgo_compose up -d で起動する)。本書では手順を目で追えるよう直接起動する
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml up -d
# 起動直後の NodeID 確認 (Step 6 の確認後に鍵が変わっていないことの再確認)
sleep 30
curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
  http://localhost:9650/ext/info | jq -r '.result.nodeID'
# 期待: NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v
# 違う値なら即座に止めて片付ける (別 NodeID のまま mainnet に居続けさせない):
#   docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml stop metalgo
#   docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml down
# "not ready" / 空なら 30 秒待って再確認。NodeID が一致するまで Caddy に進まない
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
docker ps --filter label=com.docker.compose.service=metalgo --format '{{.Names}} {{.Status}}'
docker ps --filter name=caddy-static --format '{{.Names}} {{.Status}}'
# 期待: どちらも 1 行で Up

# 8. GitHub repo Secret の SSH_HOST を新 IP に更新
#    → main に空 commit push で deploy 動作確認

# 9. NodeID 確認(同じになっているはず)
bash scripts/node-info.sh
# 期待: NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v
```

合計時間目安:
- Step 1-3: ~10 分(VPS 起動 + DNS + bootstrap script)
- Step 4-5: ~3 分(scp + .env)
- Step 6-7: ~5 分(鍵配置 + 公開前 NodeID 確認 + metalgo state sync + Caddy)
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

### Step 4: 本リポを clone + .env 作成 (10 分)

```sh
# VPS 上で(root)。置き場は vps-bootstrap.sh の DEPLOY_DIR 既定(scripts/vps-bootstrap.sh:19)
#   = /home/<deploy_user>/metal.freedom-yield.com(以下 <deploy_path>)。clone は deploy user で
sudo -u <deploy_user> git clone https://github.com/<owner>/metal.freedom-yield.com.git <deploy_path>
cd <deploy_path>

# .env(変数名と必須/任意の根拠は短縮復旧手順 Step 5 と同じ)
# (compose が読むのは METAL_NETWORK。METALGO_NETWORK_ID はどこからも読まれない)
umask 077
cat > .env <<EOF
METAL_NETWORK=mainnet
METAL_PUBLIC_IP=<新IP>
METAL_STAKING_BIND=0.0.0.0
DOMAIN=metal.freedom-yield.com
ACME_EMAIL=info@metal.freedom-yield.com
OPS_BASIC_AUTH_HASH='<bcrypt hash、operator-local 保管>'
EOF
```

### Step 5: staker keys 投入 + 公開前 NodeID 確認 + metalgo 起動 (60 分: bootstrap 込み)

```sh
# Mac から staker keys を新 VPS へ転送(Mac で実行)
# ⚠️ 同 NodeID で 2 ノード mainnet 接続は厳禁。旧 VPS が死んでいることを確認してから投入
#    (旧 VPS が生きている可能性があるなら「経路断シナリオ」節の fencing を先に完了させる)
ssh -i ~/.ssh/<your_validator_host_key> root@<新IP> 'install -d -m 700 /tmp/staking'
scp -i ~/.ssh/<your_validator_host_key> <your-staker-backup-dir>/staking/* root@<新IP>:/tmp/staking/

# VPS 上で(root、<deploy_path> で)
# 平文の鍵が /tmp に残らないよう、この session の終了時 (途中の失敗・切断を含む) に必ず消す
trap 'rm -rf /tmp/staking' EXIT
# 途中で失敗して手で中断する時も、session を離れる前に rm -rf /tmp/staking を実行する
# (Mac 側の scp が途中で失敗した時も、VPS にログインして同じく消す)
# 鍵の置き場 = metalgo コンテナの /data の mount 元。compose 自身から引く(起動はしない)
#   compose の project 名は docker-compose.metalgo.yml:17 の `name: metalgo-stack` なので、
#   /data の named volume(docker-compose.metalgo.prod.yml:49)の実体は
#   metalgo-stack_metalgo_data(metalgo_data ではない)。METALGO_DATA_PATH を使う場合はその path
#   (コンテナ名は固定で仮定しない。compose label で特定する。冒頭の警告参照)
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml create metalgo
docker ps -a --filter label=com.docker.compose.service=metalgo \
  --format '{{.ID}} {{.Names}} {{.Label "com.docker.compose.project"}}'
# 期待: 1 行だけ(新 host なので)。2 行以上なら止まる
CID=$(docker ps -a -q --filter label=com.docker.compose.service=metalgo)
DATA=$(docker inspect "$CID" \
  --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')
echo "$DATA"
# 期待(named volume の場合): /var/lib/docker/volumes/metalgo-stack_metalgo_data/_data
# (scripts/vps-bootstrap.sh の step_metalgo も同じ方法で置き場を引く)
STAKING="$DATA/staking"
mkdir -p "$STAKING"
chmod 700 "$STAKING"
mv /tmp/staking/* "$STAKING/"
rmdir /tmp/staking
# コンテナは root で動く(image に USER 指定なし)→ root 所有・600
chown root:root "$STAKING"/*
chmod 600 "$STAKING"/*

# 公開前の NodeID 確認: ネットワーク無し・staking 読み取り専用で metalgo を一時起動し、
# 起動ログの nodeID を読む(mainnet にも他ノードにも一切つながらない)
# image tag は .env で METAL_IMAGE_TAG を pin しているならその tag
docker run -d --name nodeid-check --network none -v "$STAKING:/data/staking:ro" \
  metalblockchain/metalgo:latest /metalgo/build/metalgo --network-id=local --data-dir=/data
sleep 15
docker logs nodeid-check 2>&1 | grep -o '"nodeID": *"[^"]*"' | sort -u
docker rm -f nodeid-check
# 期待: "nodeID": "NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
# 違う値・空なら起動に進まない(鍵の置き場か中身が違う。鍵が無いと metalgo は新しい鍵を作る)

# 起動
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml up -d

# NodeID 確認(復旧成否の決定点)
sleep 30
curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
  http://localhost:9650/ext/info | jq -r '.result.nodeID'
# 期待値: NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v
# 違う値なら即座に stop metalgo → down (短縮復旧手順 Step 7 と同じ)。一致するまで先に進まない

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
# node-info の cron は vps-bootstrap.sh の step_node_info_cron が /etc/cron.d/metal-node-info に
# 置く(deploy user で 5 分毎、scripts/vps-bootstrap.sh:137-156)。bootstrap を使わずに
# 組んだ場合は bootstrap を実行するか、同じ内容で置く。root の crontab には入れない
cat /etc/cron.d/metal-node-info

# 手動実行で出力確認(cron と同じ deploy user で)
cd <deploy_path> && sudo -u <deploy_user> bash scripts/node-info.sh
jq .nodeId public/api/validator.json
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

## 経路断シナリオ（host は生存・外から不達）

2026-09-24〜28 に実際に起きた形 (約 100 時間)。VM も metalgo コンテナも動き続けていたが、provider の外側 (上流 transit) で経路が切れ、外からは一切届かなかった。provider サポートも原因を説明できなかった。

**実行者**: 旧 VM の Power off・server の削除・rescue system での変更・provider へのチケット起票は **operator が実行する**。AI はコマンドと下書きの準備、事後の検証だけを行う (Constitution §5、`docs/OPERATING_MODEL.md` W7)。

A シナリオとの決定的な違い: **旧 VM は生きている**。ここで同じ staker keys を新 VM に展開すると、経路が戻った瞬間に **同 NodeID の 2 ノードが同時に mainnet に出る**。だから本節は「移設手順」ではなく **fencing (旧 VM を確実に止める) が本体**。

### 1. 見分け方

次の 3 つが揃えば経路断。どれか 1 つでも欠けたら A〜D のどれかとして扱う。ただし web host で mtr が使えず分類が `unknown (mtr unavailable)` の時は、1 つ目を「`p2p` が FAIL で alert」だけで満たすとみなし、残り 2 つで判断する。

- 外部見張り (`docs/MONITORING_OPS.md` §14、web host 上で 5 分毎) の `p2p` が FAIL で alert し (経路分類は `p2p` の alert にだけ付く)、経路分類が `provider-edge` (外部の観測点から見て、途中の hop までは応答し、そこから先が無応答) を示す。分類は web host からの 1 観測であって、どこで切れたかの証明ではない
- provider Console で対象 server の status が **Running**
- provider Console の VNC / console から OS にログインでき、`docker ps --filter label=com.docker.compose.service=metalgo` で metalgo が Up (コンテナ名は固定で仮定しない。冒頭の警告参照)

### 2. 最初にやること: provider へエスカレーション

- **検知したら即チケットを起票する**。移設判断を待たない。
- 添付は外部見張りの mtr。見張りは web host の watch ディレクトリ (`~<watch account>/metal-fy-watch/` 配下) にチケット下書きファイルを書き出すので、それをそのまま使う。
- 経路が戻るかどうかは provider 次第で、こちらからは早められない。以降の判断はチケットと並行で進める。

### 3. 移設するかの判断 (operator 判断)

- **既定の閾値: 外から連続 1 時間不達で移設に着手する**。最終決定は operator。
- 1 時間でよい理由: 2026-09-21〜23 の経路断は 30〜50 秒で戻っており、短い揺れはそもそも alert にならない (見張りは約 10 分で alert)。1 時間続いた時点でチケットは起票済みで、待つ以外の手が無い状態。下の予算に対しても 1 時間は小さい。
- 閾値を調整したい時の uptime 予算計算:

```text
D  = cycle の長さ (例: 約 33 日 = 約 792 時間)
許容 downtime  = D × (1 - 0.80)                  … 約 33 日なら約 158 時間 (約 6.6 日)
E  = cycle 開始からの経過時間
u  = 現 cycle の uptime (%)
     平常時: public/api/validator.json の uptime.network
     経路断中: validator.json は更新が止まる (validator host が書いている) ので、
              断の直前の値を使うか、外部見張り chain check と同じ公開 RPC 照会で読む
消費済み downtime ≈ E × (1 - u/100)
残り予算        ≈ 許容 downtime - 消費済み downtime
```

- 残り予算から「移設に要する時間 (短縮手順で 20〜30 分 + fencing + DNS TTL)」と「移設後にまた落ちる余裕」を引いた残りが、待てる上限。予算が薄い cycle 終盤ほど早く動く。

### 4. Fencing — 他所で起動する前に必ず完了させる

**旧 IP に届かないことは、旧 VM が止まっている証拠にならない。** 今回まさに、届かないまま VM は動いていた。止まったことは provider の control plane (Console / API。壊れたデータ経路とは別系統) でだけ確認する。

1. **provider Console または API で旧 VM を Power off** する (OS 内の shutdown を待たず、control plane からの電源断でよい)。
2. **status が Off になったことを Console / API で確認**する。Off を確認するまで新 VM で metalgo を起動しない (短縮手順 Step 4 の鍵投入より前に済ませる)。
3. **旧 VM を次に電源投入する前に、metalgo の自動起動を潰す。** 放置すると電源投入だけで同 NodeID の metalgo が勝手に戻る。根拠:
   - `scripts/vps-bootstrap.sh:44` が `systemctl enable --now docker` で docker を boot 時起動にしている
   - `docker-compose.metalgo.prod.yml:54` (base は `docker-compose.metalgo.yml:23`) が metalgo に `restart: unless-stopped` を付けている。電源断は「stop」扱いにならないので、docker 起動と同時に metalgo も戻る
   - 起動は `scripts/vps-bootstrap.sh:394` の `metalgo_compose up -d` (中身は `:303` の `docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml`)

   潰し方は次のどちらか:

   - **(推奨) バックアップ確認後に旧 server を削除する。** staker keys の暗号化バックアップ (本書「前提」節) と `/etc/freedom-yield/` の内容が手元にあることを確認してから。二度と戻らないので最も確実。
   - 調査のため残したい場合は、**provider の rescue system で起動**する (rescue は導入済み OS を起動しないので metalgo は上がらない)。root fs を mount し、(a) docker の boot 時起動を外す (`etc/systemd/system/multi-user.target.wants/docker.service` と `sockets.target.wants/docker.socket` の symlink を削除)、(b) metalgo の `/data` volume 内の `staking/` を volume の外へ退避する。rescue では docker が動いていないので label では引けない。mount した root fs の `var/lib/docker/volumes/` を `ls` して `*_metalgo_data` を確かめる (現行本番は repo と違う project 名。冒頭の警告参照)。両方やってから通常起動する。この方法では **平文の staker keys が旧 disk 上に残る** (退避しただけで消えていない)。調査が終わったら server を削除するか、退避した `staking/` を消す。鍵を残さない点でも削除 (推奨案) を選ぶ。

### 5. 移設手順

本書「⚡ 短縮復旧手順」の Step 1〜9 をそのまま使う。差分だけ書く:

- **Step 1**: 旧 VM と **別 region、できれば別 provider** を選ぶ。同 region だと同じ上流 transit を共有していて、同じ断に巻き込まれうる。
- **Step 4 の前に**: 上の fencing 1〜2 が完了していること。
- **validator host 側の operator-local 設定を戻す**: `/etc/freedom-yield/` (`web-host`、`ntfy-topic`、`calendar-token`、`wallet-addresses.json`、`watch-list.json` 等。git 管理外) と anchor 署名鍵 (`docs/OPERATOR_IDENTITY_SETUP.md` の転送手順)。

validator host の IP / ホスト名を持っている場所 (全部更新する。値はどこにも commit しない):

| 場所 | 参照元 | 更新方法 |
|---|---|---|
| GitHub repo Secret `SSH_HOST` (必要なら `SSH_PORT` / `SSH_USER` / `DEPLOY_PATH`) | `.github/workflows/deploy.yml` (Verify required secrets) | repo Settings → Secrets。`SSH_KEY` の公開鍵ペアが新 host の deploy user に入っていること |
| サイトドメインの DNS A / AAAA レコード (validator host を指している場合のみ。公開 origin は別 host の配信経路もある: `docs/DEPLOY_SETUP.md` 冒頭の配信トポロジ) | `docs/DEPLOY_SETUP.md` (edge CDN)、外形監視 `.github/workflows/uptime.yml` の `SITE_URL` | edge CDN で現在の向き先を確認し、validator host なら新 IP へ (短縮手順 Step 2) |
| 新 host の `.env` の `METAL_PUBLIC_IP` | `docker-compose.metalgo.prod.yml` | 上記 |
| 外部見張りの `watch.env` の `VALIDATOR_HOST` (web host 上) | `scripts/install-web-host-external-watch.sh`、`docs/MONITORING_OPS.md` §14 | 新しい `VALIDATOR_HOST` で installer を再実行 (topic は保持される) |
| operator Mac の `VALIDATOR_HOST` (環境変数・private note) | `scripts/sync-to-validator-host.sh`、`scripts/cycle-transition.sh`、`scripts/operator-local/commit-anchor-source.sh`、`scripts/resume-after-cycle-start.sh` | private note の値を差し替え |
| operator Mac の `~/.ssh/config` の host alias と `~/.ssh/known_hosts` | `docs/OPERATOR_IDENTITY_SETUP.md` (`VALIDATOR_SSH_HOST`) | alias の宛先を変更、旧 host key 行を削除 |

### 6. 戻り道・復旧後の確認

- [ ] 新 host で `bash scripts/node-info.sh` の NodeID が `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v` (変わっていない)
- [ ] 外部見張りが新 host に対して `p2p` / `chain` PASS、recovery push が届く
- [ ] 公開 RPC の `connected=true`、uptime が以後回復方向
- [ ] **同 NodeID のノードが 1 台だけ**: 旧 VM が Console / API で Off または削除済み、rescue で残したなら docker 無効化と `staking/` 退避が済んでいる
- [ ] 本書「復旧完了の checklist」も全項目
- [ ] provider チケットを「移設済み、旧 server は停止 / 削除」で閉じる。経路が戻っても **旧 VM へ戻さない** (戻すなら新 VM を同じ fencing 手順で止めてから、逆向きに本節をやり直す)

### 7. 未実施事項

- **実際の移設訓練 (新 VM を作って fencing → 移設 → 片付けまで通す) はまだやっていない。** operator が日程を決めて行う別タスク。本節の手順は訓練で検証されるまで未検証扱い。

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
