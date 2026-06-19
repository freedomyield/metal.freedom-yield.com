# Deploy setup (VPS 契約後の初期化手順)

`.github/workflows/deploy.yml` を動かすために、VPS 側 + GitHub 側で必要な設定。
**VPS 契約 → このドキュメント通りに設定 → `DEPLOY_ENABLED=true` 設定 → 次回 push で初回 deploy 走行**、の流れ。

## 前提

- validator host (推奨 production-grade VPS Ubuntu 22.04) もしくは同等の VPS を 1 台
- ドメイン `metal.freedom-yield.com` の DNS A レコードを edge CDN で VPS public IP に向ける
- 80/443/TCP, 443/UDP(HTTP/3), 22/TCP, 9651/TCP が inbound 許可

## 手順

### 1. VPS 側: <deploy_user> の作成 + SSH 鍵設定

ローカル mac で deploy 用キーペアを生成(本リポではないどこかで実行):

```sh
ssh-keygen -t ed25519 -f ~/.ssh/<your_deploy_key> -C "github-actions deploy for metal.freedom-yield.com"
# 結果: ~/.ssh/<your_deploy_key>(秘密鍵) と ~/.ssh/<your_deploy_key>.pub(公開鍵)
```

VPS にログインして <deploy_user> を作成し、公開鍵を登録:

```sh
# VPS 上で root として(or sudo 経由で)
adduser --disabled-password --gecos '' <deploy_user>
mkdir -p <deploy_user_home>/.ssh && chmod 700 <deploy_user_home>/.ssh
# 上で生成した ~/.ssh/<your_deploy_key>.pub の内容を貼り付け
cat > <deploy_user_home>/.ssh/authorized_keys
# (内容を貼り付け、Ctrl-D で終了)
chmod 600 <deploy_user_home>/.ssh/authorized_keys
chown -R <deploy_user>:<deploy_user> <deploy_user_home>/.ssh

# <deploy_user> を docker group に追加(docker compose を sudo なしで実行できる)
usermod -aG docker <deploy_user>
```

### 2. VPS 側: ufw / firewall 設定

```sh
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
# validator を同居させる場合は次も(別ホストなら不要)
ufw allow 9651/tcp
ufw default deny incoming
ufw default allow outgoing
ufw enable
```

### 3. VPS 側: Docker と Compose v2 の確認

```sh
docker --version            # 20.10+
docker compose version      # v2.x
```

(古い場合は公式手順でアップデート: https://docs.docker.com/engine/install/ubuntu/)

### 4. VPS 側: deploy 先パスの準備

deploy userの home 配下に bare な directory を 1 つ作る。中身は GitHub Actions が rsync で配置:

```sh
# deploy userに切替
su - deploy
mkdir -p <deploy_path>
```

`.env` は **VPS 側でだけ手動作成**(deploy 対象外、`--exclude='.env'`):

```sh
cat > <deploy_path>/.env <<'EOF'
DOMAIN=metal.freedom-yield.com
ACME_EMAIL=info@metal.freedom-yield.com
EOF
chmod 600 <deploy_path>/.env
```

### 5. GitHub 側: Secrets 登録

`Settings → Secrets and variables → Actions → Secrets` で以下を登録:

| Name | 値 |
|---|---|
| `SSH_HOST` | VPS の IP (例: `5.223.xxx.xxx`) |
| `SSH_USER` | `deploy` |
| `SSH_KEY` | ローカルの `~/.ssh/<your_deploy_key>`(秘密鍵)の **全内容**(OpenSSH PEM 形式、BEGIN/END マーカーを含む全行) |
| `SSH_PORT` | (任意、22 以外を使うなら) |
| `DEPLOY_PATH` | `<deploy_path>` |

⚠️ `SSH_KEY` は改行を含むので、エディタからコピペするときに **CRLF が混入しないように**。Mac のターミナルで `pbcopy < ~/.ssh/<your_deploy_key>` 推奨。

### 6. GitHub 側: Variable で deploy を有効化

`Settings → Secrets and variables → Actions → Variables` で:

| Name | Value |
|---|---|
| `DEPLOY_ENABLED` | `true` |

これが `true` でない間、deploy ジョブは skip され CI は赤くならない。VPS 準備中の commit でも作業を止めずに済む。

### 7. 初回 deploy(手動実行)

GitHub の `Actions` タブ → `Deploy site to VPS` → `Run workflow` → main を選んで実行。

数十秒〜数分で:

1. checkout
2. cache-bust(main.js に SHA を付与)
3. SSH 接続
4. rsync で `public/`, `caddy/Caddyfile`, `docker-compose.yml`, `docker-compose.prod.yml` 等を VPS に配置
5. VPS 側で `docker compose up -d` → Caddy 起動 → Let's Encrypt 証明書取得 → `caddy reload`
6. ヘルスチェック

成功後、`https://metal.freedom-yield.com/` でサイトが見えるはず。

### 8. 以降の deploy

`main` ブランチに push するだけ。`README.md`, `CLAUDE.md`, `docs/**`, `.gitignore` への push では deploy は走らない(`paths-ignore` 設定)。

`workflow_dispatch` で随時手動実行も可。

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `Permission denied (publickey)` | `authorized_keys` のパーミッション / `deploy` ユーザの home の所有権を確認 |
| `Failed to obtain certificate` (Caddy) | DNS A レコードが VPS IP に向いていない / edge CDN の proxy ON で Let's Encrypt の HTTP-01 がブロックされている。**edge proxy は OFF か、DNS-01 challenge に切替** |
| `caddy reload` でエラー | VPS 側で `docker compose logs caddy` を見て Caddyfile syntax エラーを修正 |
| rsync が遅い / 時間切れ | `node_modules/` や巨大ファイルが exclude されているか確認、`--exclude` を追加 |
| 公開 health check が失敗 | edge DNS の TTL 待ち / edge CDN の SSL モードを "Full (strict)" にする |

## 関連

- [.github/workflows/deploy.yml](../.github/workflows/deploy.yml) — 実際の workflow 定義
- [docker-compose.prod.yml](../docker-compose.prod.yml) — VPS で起動する Caddy 設定
- [docs/MAINNET_MIGRATION.md](MAINNET_MIGRATION.md) — Tahoe→mainnet 段階移行(本 deploy 設定もそこに連動)
- メモ `project_public_repo_plan.md` — public 化前提のため、deploy 関連でも IP / hostname を直書きしない方針
