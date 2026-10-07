# Deploy setup (VPS 契約後の初期化手順)

`.github/workflows/deploy.yml` を動かすために、VPS 側 + GitHub 側で必要な設定。
**VPS 契約 → このドキュメント通りに設定 → `DEPLOY_ENABLED=true` 設定 → 次回 push で初回 deploy 走行**、の流れ。

## 前提

- validator host (推奨 production-grade VPS Ubuntu 22.04) もしくは同等の VPS を 1 台
- ドメイン `metal.freedom-yield.com` の DNS A レコードを edge CDN で VPS public IP に向ける
- 22/TCP, 9651/TCP のみ inbound 許可(80/443 は開けない。公開サイトは web host。validator host には Caddy も web server も無い。80/443 の旧ルールと Caddy は 2026-10-07 に現行 host から削除済)

**配信トポロジ (2 ホスト)**: GitHub Actions は repo-tracked static (`public/`) を **2 つの target** に配信する — (1) validator host の checkout の `public/` (2026-10-07 に validator host の Caddy を撤去したので、ここを配信するものは無い。rsync は別の判断で外すまで残している)、(2) 公開 Xserver origin (edge CDN 背後)。この 2 つの配信経路は非対称: validator host は `$DEPLOY_PATH` に本リポの git checkout を持ち、`public/` 以外の git 管理ファイル(`docs/`, `scripts/`, `tests/`, `caddy/Caddyfile`, `docker-compose*.yml` 等)は deploy のたびに `scripts/advance-host-checkout.sh` の `git pull --ff-only` が届ける(§4 参照)。公開 Xserver は git checkout を一切持たず、`rrsync -wo` で metal public dir に封じ込めた専用鍵(`scripts/install-xserver-static-deploy-key.sh` で設置)による `public/` のみの rsync が唯一の配信経路。動的 feed は validator host cron → 受信 wrapper 経由で Xserver に届く(deploy とは別経路)。両 `public/` rsync の除外集合は単一 SoT `deploy/feed-excludes.txt` から生成。詳細は [`docs/DEPLOY_OWNERSHIP_MATRIX.md`](DEPLOY_OWNERSHIP_MATRIX.md)。

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
# validator host: 22/tcp + 9651/tcp のみ。80/443 は開けない(何も listen しない。
# 公開サイトは web host。2026-10-07 に現行 host から削除済)
ufw allow 22/tcp
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

deploy user の home 配下に **git clone** で `<deploy_path>` を作る。2026-07-13
の delivery-ownership inversion 以降、`public/` 以外の git 管理ファイル
(`docs/`, `scripts/`, `tests/`, `caddy/Caddyfile`, `docker-compose*.yml`
等)は deploy のたびに `scripts/advance-host-checkout.sh` の
`git pull --ff-only` が届ける。このステップが動くには **`<deploy_path>` が
最初から git checkout であること** が前提 — `mkdir -p` だけの空ディレクトリの
ままだと、その advance ステップが `not a git checkout` で exit 2 して失敗し、
deploy job もそこで止まる。これは意図した fail-closed 挙動(git 管理外の空
ディレクトリへ誤って FF pull を強行しないためのガード)であり、bug ではない
— 詳細は [`docs/HOST_CHECKOUT_AUTO_ADVANCE.md`](HOST_CHECKOUT_AUTO_ADVANCE.md)。

```sh
# deploy userに切替
su - deploy
git clone https://github.com/<owner>/metal.freedom-yield.com.git <deploy_path>
```

`.env` は **VPS 側でだけ手動作成**(`.gitignore` 対象かつ `public/` 外なので、
git advance にも `public/` の rsync にも一切乗らない):

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
| `SSH_HOST` | VPS の IP (例: `203.0.113.x`) |
| `SSH_USER` | `deploy` |
| `SSH_KEY` | ローカルの `~/.ssh/<your_deploy_key>`(秘密鍵)の **全内容**(OpenSSH PEM 形式、BEGIN/END マーカーを含む全行) |
| `SSH_PORT` | (任意、22 以外を使うなら) |
| `DEPLOY_PATH` | `<deploy_path>` |
| `XSERVER_SSH_KEY` | 公開 Xserver 配信用の専用秘密鍵の**全内容**（`rrsync -wo` 制限の deploy 鍵。root 鍵は使わない） |
| `XSERVER_SSH_HOST` | 公開 Xserver origin の IP |
| `XSERVER_SSH_USER` | Xserver の配信アカウント名 |
| `XSERVER_SSH_PORT` | Xserver の SSH port |

⚠️ `SSH_KEY` は改行を含むので、エディタからコピペするときに **CRLF が混入しないように**。Mac のターミナルで `pbcopy < ~/.ssh/<your_deploy_key>` 推奨。

### 6. GitHub 側: Variable で deploy を有効化

`Settings → Secrets and variables → Actions → Variables` で:

| Name | Value |
|---|---|
| `DEPLOY_ENABLED` | `true` |

これが `true` でない間、deploy ジョブは skip され CI は赤くならない。VPS 準備中の commit でも作業を止めずに済む。

### 7. 初回 deploy(手動実行)

GitHub の `Actions` タブ → `Deploy site to VPS` → `Run workflow` → main を選んで実行。

数十秒〜数分で(`.github/workflows/deploy.yml` の実ステップ順):

1. Secrets 検証(`SSH_HOST`/`SSH_USER`/`SSH_KEY`/`DEPLOY_PATH` の未設定を検出)
2. checkout
3. cache-bust(main.js 等に SHA を付与。runner 側の `public/` コピーだけを書き換える)
4. SSH 鍵設定
5. `mkdir -p '$DEPLOY_PATH'`(**Ensure deploy path exists** — ディレクトリの
   存在保証のみ。git checkout を作るわけではないので、§4 の `git clone` を
   飛ばしていた場合はこのステップは通っても次のステップで止まる)
6. **Advance host checkout to origin/main** — runner のコピーの
   `scripts/advance-host-checkout.sh` を SSH 経由で VPS に流し込んで実行。
   `public/` 以外の git 管理ファイル(`scripts/`, `docker-compose*.yml`,
   `docs/`, `tests/` 等)は全てこの `git pull --ff-only` が届ける。
   fail-closed: host が origin へ FF できなければ(host が ahead / 未 git
   checkout / 実際の差分衝突)ここで deploy が失敗し、以降のステップは走らない。
7. rsync で cache-bust 済みの `public/` **のみ** を VPS に配置(それ以外の
   ファイルはこの rsync に含まれない)
8. (Xserver secrets 設定済みなら)Xserver deploy 鍵設定 → 公開 Xserver へも
   `public/` のみ rsync
9. 公開ヘルスチェック

validator host では container を build / 起動 / reload しない(Caddy step は
2026-10-07 に削除。Constitution v0.8 §5)。

成功後、`https://metal.freedom-yield.com/` でサイトが見えるはず。

### 8. 以降の deploy

`main` ブランチに push するだけ。`README.md`, `README.ja.md`, `CLAUDE.md`,
`docs/**`, `.gitignore` への push では deploy job 自体が走らない
(`.github/workflows/deploy.yml` の `on.push.paths-ignore` キー参照)。

ただし validator host の git checkout がそれで止まるわけではない —
こうした push も `origin/main` には乗るので、次に deploy を起動する push
(他のファイルを含む push、または `workflow_dispatch`)の advance ステップ
か、日次 04:45 UTC の `metal-host-advance` cron のどちらかが FF pull で拾う。
paths-ignore push の直後だけ host `HEAD` が origin より数コミット遅れて
見えるのは想定内であり drift ではない — 詳細は
[`docs/HOST_CHECKOUT_AUTO_ADVANCE.md`](HOST_CHECKOUT_AUTO_ADVANCE.md) の
cron backstop の節を参照。

`workflow_dispatch` で随時手動実行も可。

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `Permission denied (publickey)` | `authorized_keys` のパーミッション / `deploy` ユーザの home の所有権を確認 |
| `Advance host checkout to origin/main` ステップで deploy が失敗 | exit 1 なら host が origin より ahead(=host が commit を author した。人間が読んで手動 reconcile、force merge/reset 禁止)か、`public/` 以外に origin/main と食い違う未コミット変更がある(自己修復対象外)。exit 2 なら `$DEPLOY_PATH` がまだ git checkout でない(§4 を参照し `git clone` する)か `git fetch` 失敗(一時的、次回リトライ)。詳細は [`docs/HOST_CHECKOUT_AUTO_ADVANCE.md`](HOST_CHECKOUT_AUTO_ADVANCE.md) |
| rsync が遅い / 時間切れ | 2026-07-13 以降、この rsync は `public/` のみを転送する(小さい)。遅い場合は VPS 側ネットワーク/SSH を疑う — `node_modules/` 等リポジトリ全体の巨大ファイルはもう転送対象に含まれない |
| 公開 health check が失敗 | edge DNS の TTL 待ち / edge CDN の SSL モードを "Full (strict)" にする |

## 関連

- [.github/workflows/deploy.yml](../.github/workflows/deploy.yml) — 実際の workflow 定義
- [docker-compose.behind-proxy.yml](../docker-compose.behind-proxy.yml) — サイトの Caddy を host の nginx の背後 `127.0.0.1:8085` に置く override(`docker-compose.yml` と合わせて 2 本)。web host の `caddy-static` と同じ形。web host に本リポの checkout は無く、本リポの deploy はこれを起動しない。validator host の Caddy(以前はこの 2 本で deploy.yml が起動)は 2026-10-07 に operator の決定で撤去した(利用者が deploy の health check だけだった)。運用ダッシュボード(`127.0.0.1:8443`、SSH トンネル + BasicAuth、`docker-compose.ops-tunnel.yml` と host `.env` の `OPS_BASIC_AUTH_HASH`)は 2026-10-07 に operator の決定で廃止した(一度も使われず、operator 用 `/status/` ページと重複)。`docker-compose.prod.yml` は Caddy が直接 80/443 を bind する別トポロジ用の override で、どの host でも使っていない
- [docs/HOST_CHECKOUT_AUTO_ADVANCE.md](HOST_CHECKOUT_AUTO_ADVANCE.md) — validator host の git `HEAD` を `origin/main` に FF-only で追従させる self-heal の仕組み(git advance が担う「`public/` 以外の全ファイル配信」の実装)
- [docs/DEPLOY_OWNERSHIP_MATRIX.md](DEPLOY_OWNERSHIP_MATRIX.md) — git 配信 vs rsync 配信の単一ルールと、`public/api/` 個別ファイルの所有権表
- [docs/MAINNET_MIGRATION.md](MAINNET_MIGRATION.md) — Tahoe→mainnet 段階移行(本 deploy 設定もそこに連動)
- メモ `project_public_repo_plan.md` — public 化前提のため、deploy 関連でも IP / hostname を直書きしない方針
