# Deploy setup (VPS 契約後の初期化手順)

`.github/workflows/deploy.yml` を動かすために、VPS 側 + GitHub 側で必要な設定。
**VPS 契約 → このドキュメント通りに設定 → `DEPLOY_ENABLED=true` 設定 → 次回 push で初回 deploy 走行**、の流れ。

## 前提

- validator host (推奨 production-grade VPS Ubuntu 22.04) もしくは同等の VPS を 1 台
- ドメイン `metal.freedom-yield.com` の DNS A レコードを edge CDN で VPS public IP に向ける
- 22/TCP, 9651/TCP のみ inbound 許可(80/443 は開けない。公開サイトは web host。validator host には Caddy も web server も無い。80/443 の旧ルールと Caddy は 2026-10-07 に現行 host から削除済)

**配信トポロジ (2 ホスト)**: GitHub Actions は repo-tracked static (`public/`) を **2 つの target** に配信する — (1) validator host の checkout の `public/` (2026-10-07 に validator host の Caddy を撤去したので、ここを配信するものは無い。rsync は別の判断で外すまで残している)、(2) 公開 Xserver origin (edge CDN 背後)。この 2 つの配信経路は非対称: validator host は `$DEPLOY_PATH` に本リポの git checkout を持ち、`public/` 以外の git 管理ファイル(`docs/`, `scripts/`, `tests/`, `caddy/Caddyfile`, `docker-compose*.yml` 等)は deploy のたびに `scripts/advance-host-checkout.sh` の `git pull --ff-only` が届ける(§4 参照)。公開 Xserver は git checkout を一切持たず (deploy dir に本リポの git でないコピーは在るが、deploy が更新するのはその `public/` だけ。§9)、`rrsync -wo` で metal public dir に封じ込めた専用鍵(`scripts/install-xserver-static-deploy-key.sh` で設置)による `public/` のみの rsync が唯一の配信経路。動的 feed は validator host cron → 受信 wrapper 経由で Xserver に届く(deploy とは別経路)。両 `public/` rsync の除外集合は単一 SoT `deploy/feed-excludes.txt` から生成。詳細は [`docs/DEPLOY_OWNERSHIP_MATRIX.md`](DEPLOY_OWNERSHIP_MATRIX.md)。

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

### 9. web host の `caddy-static` に Caddyfile の変更を反映する

公開サイトは web host の host nginx → `127.0.0.1:8085` → container `caddy-static` が配信する。
CI の deploy が web host に対して行うのは `public/` の rsync だけで(鍵が配信 dir に封じ込められている。§7 の 8)、
**`caddy/Caddyfile` を変えても、それだけでは web host に届かない**。届ける経路はこの節の手順だけ。
web host の deploy dir には本リポの**git でないコピー** (`.git` なし。compose ファイル・`caddy/`・`docs/`・`.env` 等) が在り、
`caddy-static` はそのコピーの compose ファイルで起動され、そのコピーの `caddy/Caddyfile` を読む。deploy が更新するのは
その中の `public/` だけなので、**コピーの他のファイル (compose・Caddyfile) は deploy では更新されない**。

**統治**: web host は他プロジェクトと同居する multi-tenant host なので、Constitution §5 の
「本プロジェクトの path・unit・名前に限定する。host 全体に効く変更は禁止」が掛かる。§5 の
「変更ごとに chat で承認 → AI 実行 → AI 検証」(v0.7、Operating Model W7)は**文言上 validator host
だけ**が対象で、web host 上の手作業の変更を明示的に統治する条文は無い (Operating Model の責任表は
web host の deploy を CI だけに割り当てている)。そこでこの手順は、より厳しい側として **W7 と同じ形**で
運用する: 変更(下の `--check` の diff と sha256)を operator が chat で**その変更として**承認 →
AI が Mac から実行 → AI が期待値と照合。operator が自分で実行してもよい。この運用を条文にするか
(W7 の対象を web host に広げる等)は operator の判断事項で、この節は条文を変えていない。

**採らなかった案** (2026-10-08 検討):
CI に web host 用の限定コマンドを足す案は、Caddyfile を書き換えて reload できる鍵 (= docker を
動かせる鍵。共有 host では実質 root 相当) を CI の secret に置くことになり、漏れた時に他プロジェクト
まで届く。Operating Model W6 (「web host では container を起動しない」) の変更も要る。
running の Caddyfile と repo の差を常時見張る案は、web host で docker を読める権限を見張り側に
新たに与える必要がある。差の確認は下の `--check` で必要な時に行う。

#### 9.1 web host の事実 (VERIFIED 2026-10-08)

リポジトリからは確認できない次の 4 点を、2026-10-08 に下の読み取り専用コマンドで web host 上で確認した。
具体的な path は host の内部構造なので**リポジトリに書かない** (Constitution §4.2 C5)。実行時に環境変数で渡す。
web host の構成を変えたら (container の作り直し・deploy dir の移動等)、使う前に同じコマンドで確かめ直す。

| 事実 | 確認結果 (2026-10-08) | 渡し方 |
|---|---|---|
| `caddy-static` の compose project 名 | `site` (compose ファイルは `docker-compose.yml` + `docker-compose.behind-proxy.yml`) | `WEB_CADDY_PROJECT=site` |
| `/etc/caddy/Caddyfile` の bind 元 | read-only の bind。元は `<deploy dir>/caddy/Caddyfile` (通常ファイル、deploy アカウント所有 644、親は symlink でない dir)。host と container の sha256 は一致 | `WEB_CADDY_FILE=<deploy dir>/caddy/Caddyfile` |
| build context | `<deploy dir>` (本リポの git でないコピー。`caddy/Dockerfile` を含む)。image は `caddy-static:local` (caddy v2.11.4、`http.handlers.rate_limit` あり) | §9.4 でだけ使う |
| ssh で入る account | root (docker を使える) | `WEB_HOST_USER=root` (既定) |

その他の確認結果: port は `80/tcp` → `127.0.0.1:8085` だけ、`DOMAIN=:80`、`/srv` は `<deploy dir>/public` の read-only bind、
volume は `site_caddy_config` / `site_caddy_data`。`<deploy dir>` は validator host の deploy path と同じ配置。

**admin API の落とし穴 (IPv6)**: container 内の admin API は `127.0.0.1:2019` だけで listen している。busybox は
`localhost` を `::1` に解決するので、`http://localhost:2019/` は**拒否される** (2026-10-08 実測)。caddy の既定の
reload 先も `localhost:2019` なので、script は `caddy reload --address 127.0.0.1:2019` と明示する。手で叩く時も必ず
`127.0.0.1:2019` を使う。

確かめ直しに使う**読み取り専用**のコマンド (web host 上で実行。どれも状態を変えない):

```bash
# 1. compose project・作業 dir・compose ファイル・稼働状態
docker inspect --type container --format '{{json .Config.Labels}}' caddy-static
docker inspect --type container --format '{{.State.Running}} {{.Config.Image}} {{.Image}}' caddy-static
# 2. mount (Caddyfile の bind 元と種別)・port
docker inspect --type container --format '{{json .Mounts}}' caddy-static
docker inspect --type container --format '{{json .HostConfig.PortBindings}}' caddy-static
# 3. validate に渡す DOMAIN (他の env は表示しない)
docker inspect --type container --format '{{range .Config.Env}}{{println .}}{{end}}' caddy-static | grep '^DOMAIN='
# 4. 稼働中の image に rate_limit が入っているか / caddy の版
docker exec caddy-static caddy list-modules | grep -x http.handlers.rate_limit
docker exec caddy-static caddy version
# 5. reload に使う admin API が応答するか (GET のみ。localhost は ::1 になり拒否されるので 127.0.0.1)
docker exec caddy-static wget -q -O /dev/null http://127.0.0.1:2019/config/ && echo admin-api-ok
# 6. host の bind 元と container の見ている内容が同じか・symlink でないか (2 の Source を使う)
sha256sum <2 の Source>
docker exec caddy-static cat /etc/caddy/Caddyfile | sha256sum
stat -c '%F %i %U:%G %a' <2 の Source>
stat -c '%F' "$(dirname <2 の Source>)"
# 7. build context の有無 (1 の com.docker.compose.project.working_dir)
ls -la <working_dir> <working_dir>/caddy
docker image inspect --format '{{.Created}} {{json .RepoTags}}' <1 の .Image>
# 8. ssh の account
id
```

期待: 1 の `com.docker.compose.project` が `WEB_CADDY_PROJECT` に、2 の `/etc/caddy/Caddyfile` が
`"Type":"bind"` でその `Source` が `WEB_CADDY_FILE` になる。port は `80/tcp` → `127.0.0.1:8085` だけ。
4 で rate_limit が出なければ、稼働中の image は本リポの `caddy/Dockerfile` の物ではない (§9.4 が先)。
6 の 2 つの sha256 が違えば、bind が古い inode に留まっている (下の注意) — 解消は §9.4 と同じく
container の作り直しになるので、この手順の範囲外。

その後 `--check` (読み取りのみ) を 1 回通し、`guard: ok` と diff を確認してから初めて `--apply` に進む。

#### 9.2 手順

```bash
# 0. 手元 (Mac)。何にも接続しない。repo の Caddyfile の sha256 と次の手順を表示
bash scripts/web-host-caddy-apply.sh

# 1. 読み取りのみ: scope guard + 稼働中 → repo の diff (exit 0 = 一致 / 10 = 差あり)
WEB_HOST=<web host> WEB_HOST_KEY=<鍵> WEB_CADDY_PROJECT=site WEB_CADDY_FILE=<deploy dir>/caddy/Caddyfile \
  bash scripts/web-host-caddy-apply.sh --check

# 2. operator に diff と sha256 を示し、その変更として chat で承認を得る

# 3. 反映 (承認された sha256 を渡す。repo の Caddyfile が commit 済みで、sha256 が一致しないと拒否)
WEB_HOST=… WEB_HOST_KEY=… WEB_CADDY_PROJECT=… WEB_CADDY_FILE=… \
  bash scripts/web-host-caddy-apply.sh --apply --approved-sha256=<0 の sha256>

# 4. operator と同じ経路で確認 (edge CDN 経由)
curl -fsS https://metal.freedom-yield.com/health
curl -sSI https://metal.freedom-yield.com/ | grep -i '^content-security-policy'
```

`--apply` がすること (script 冒頭のコメントが正):

1. scope guard — container 名は `caddy-static` 固定 (入力で変えられない)。compose project・Caddyfile の
   bind 元・port (`127.0.0.1:8085` だけ)・host と container の内容一致・symlink でないこと、を全て満たさなければ
   何も変えずに exit 2。さらに**書き込む前に** 6 と同じ health を 1 回通す。通らなければ exit 2 (何も変えない)。
   元から健全でないサイトを「戻しに失敗した (exit 4)」と誤って報告しないため。health は `127.0.0.1:8085` に
   Host を付けずに当てるので、`DOMAIN` が `:80` 型であることが前提 (§9.1 で確認済み)
2. 稼働中の image で使い捨て container (`--rm --network none --read-only`) を起こし `caddy validate`。失敗なら exit 2 (何も変えない)
3. host の Caddyfile を `Caddyfile.bak-<UTC>` に控え (同じ dir)、控えの sha256 を記録する
4. host の Caddyfile を**その場で上書き**する。単一ファイルの bind mount は inode に固定されるので、
   rename (mv や多くのエディタの保存) で置き換えると container は古い内容を見続ける。上書き後、container 内から
   新しい内容が見えることを確かめる
5. container 内で `caddy reload --address 127.0.0.1:2019` (停止・再作成はしない。`localhost` は使わない: §9.1 の落とし穴)
6. `127.0.0.1:8085/health` が `ok`、`/` に CSP ヘッダ。4〜6 のどれかが失敗すれば 3 の控えに同じ方法で戻して
   reload し直し、exit 1。戻す前に控えの sha256 が 3 で記録した値と同じか確かめ、違えば戻さずに exit 4
7. 成功した時だけ、同じ dir の `Caddyfile.bak-<YYYYmmddTHHMMSSZ>` を新しい 5 個まで残し、古いものを消す
   (その名前の形の通常ファイルだけ。他の名前・symlink・他の dir には触れない。失敗時は証拠として消さない)

使う docker コマンドは `docker inspect … caddy-static` / `docker exec caddy-static {cat, caddy list-modules, caddy reload}` /
`docker run --rm --network none … caddy validate` だけ。docker compose・build・stop・rm・prune、nginx・systemd・cron・
パッケージ・firewall には触れない。

#### 9.3 戻す

- **自動**: `--apply` は失敗時に自動で戻す (exit 1 = 前の Caddyfile で動いている)
- **後から戻す**: `--apply` が表示した `BACKUP:` の名前を使う (戻す前の状態も新しい控えに残る)

  ```bash
  WEB_HOST=… WEB_HOST_KEY=… WEB_CADDY_PROJECT=… WEB_CADDY_FILE=… \
    bash scripts/web-host-caddy-apply.sh --rollback --backup=Caddyfile.bak-<YYYYmmddTHHMMSSZ>
  ```

- **exit 4 (自動の戻しが失敗)**: 緊急。web host で `docker logs --tail 50 caddy-static` を見て、
  `cat <控え> > <WEB_CADDY_FILE>` (その場で上書き。mv しない) → `docker exec caddy-static caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --address 127.0.0.1:2019`。
  それでも配信が戻らなければ [INCIDENT_RESPONSE.md §3.1](INCIDENT_RESPONSE.md) へ。いずれも operator に上げてから行う

#### 9.4 `caddy/Dockerfile` の変更 (image の再 build) — 自動化しない

image を作り直すには container の再作成 (短い停止) が要り、web host 上の build context と compose 定義 (§9.1: deploy dir の git でないコピー) に依存する。そのコピーの `caddy/Dockerfile` と compose ファイルも deploy では更新されないので、先に repo の版と揃える必要がある。
script はこれを扱わない。必要になったら、§9.1 の結果を元に「build → `caddy validate` (新 image で使い捨て container) →
本プロジェクトの compose project だけを指定した `up -d --no-deps --force-recreate` → health → 戻し (前の image ID を控えて
タグを戻す)」を具体的なコマンドと期待値つきで起こし、**その変更として**承認を得てから行う。

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `Permission denied (publickey)` | `authorized_keys` のパーミッション / `deploy` ユーザの home の所有権を確認 |
| `Advance host checkout to origin/main` ステップで deploy が失敗 | exit 1 なら host が origin より ahead(=host が commit を author した。人間が読んで手動 reconcile、force merge/reset 禁止)か、`public/` 以外に origin/main と食い違う未コミット変更がある(自己修復対象外)。exit 2 なら `$DEPLOY_PATH` がまだ git checkout でない(§4 を参照し `git clone` する)か `git fetch` 失敗(一時的、次回リトライ)。詳細は [`docs/HOST_CHECKOUT_AUTO_ADVANCE.md`](HOST_CHECKOUT_AUTO_ADVANCE.md) |
| rsync が遅い / 時間切れ | 2026-07-13 以降、この rsync は `public/` のみを転送する(小さい)。遅い場合は VPS 側ネットワーク/SSH を疑う — `node_modules/` 等リポジトリ全体の巨大ファイルはもう転送対象に含まれない |
| 公開 health check が失敗 | edge DNS の TTL 待ち / edge CDN の SSL モードを "Full (strict)" にする |

## 関連

- [.github/workflows/deploy.yml](../.github/workflows/deploy.yml) — 実際の workflow 定義
- [docker-compose.behind-proxy.yml](../docker-compose.behind-proxy.yml) — サイトの Caddy を host の nginx の背後 `127.0.0.1:8085` に置く override(`docker-compose.yml` と合わせて 2 本)。web host の `caddy-static` と同じ形。web host には本リポの git checkout は無く、deploy dir の git でないコピーのこの 2 本で `caddy-static` が起動されている。本リポの deploy はこれを起動せず、コピーの compose・Caddyfile も更新しない (更新は §9)。validator host の Caddy(以前はこの 2 本で deploy.yml が起動)は 2026-10-07 に operator の決定で撤去した(利用者が deploy の health check だけだった)。運用ダッシュボード(`127.0.0.1:8443`、SSH トンネル + BasicAuth、`docker-compose.ops-tunnel.yml` と host `.env` の `OPS_BASIC_AUTH_HASH`)は 2026-10-07 に operator の決定で廃止した(一度も使われず、operator 用 `/status/` ページと重複)。`docker-compose.prod.yml` は Caddy が直接 80/443 を bind する別トポロジ用の override で、どの host でも使っていない
- [docs/HOST_CHECKOUT_AUTO_ADVANCE.md](HOST_CHECKOUT_AUTO_ADVANCE.md) — validator host の git `HEAD` を `origin/main` に FF-only で追従させる self-heal の仕組み(git advance が担う「`public/` 以外の全ファイル配信」の実装)
- [docs/DEPLOY_OWNERSHIP_MATRIX.md](DEPLOY_OWNERSHIP_MATRIX.md) — git 配信 vs rsync 配信の単一ルールと、`public/api/` 個別ファイルの所有権表
- [docs/MAINNET_MIGRATION.md](MAINNET_MIGRATION.md) — Tahoe→mainnet 段階移行(本 deploy 設定もそこに連動)
- メモ `project_public_repo_plan.md` — public 化前提のため、deploy 関連でも IP / hostname を直書きしない方針
