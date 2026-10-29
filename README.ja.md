# metal.freedom-yield.com

**Freedom Yield** の Metal Blockchain (Layer-0 by Metallicus, Avalanche fork) validator の公開サイトと運用スクリプト。

🇬🇧 English: [README.md](README.md)

## このリポジトリの中身

- **公開ウェブサイト** (`public/`) — landing / validator status / delegate 案内 / incident 履歴 / open data カタログ。EN は `/`、JA は `/ja/`。ローカルでは Caddy で配信、本番は GitHub Actions で web host へ deploy。
- **運用スクリプト群** (`scripts/`) — `node-info.sh` / `peer-validators.sh` / `notify.sh` / `dr-drill.sh` 等。validator host 上で動き、公開 JSON エンドポイント生成、anomaly alert、DR ドリル等を担う。他 Metal validator が再利用できるものについては [TOOLKIT.md](TOOLKIT.md) 参照。
- **Runbook** (`docs/`) — incident response、key rotation、disaster recovery、validator host setup、mainnet 移行、validator renewal、security layers。
- **Manifest format guide** (`docs/`) — [`EVIDENCE_MANIFEST.md`](docs/EVIDENCE_MANIFEST.md)(live)、[`CYCLE_HISTORY.md`](docs/CYCLE_HISTORY.md)、[`IDENTITY_VERIFICATION.md`](docs/IDENTITY_VERIFICATION.md)、[`TRANSPARENT_VALIDATOR_PLEDGE.md`](docs/TRANSPARENT_VALIDATOR_PLEDGE.md)。`/api/` 配下の公開 JSON / JSONL surface のスキーマ、生成パイプライン、消費方法を記述。
- **ローカル Tahoe testnet metalgo ノード** (`docker-compose.metalgo.yml`) — 本番 METAL を使わずに pipeline を検証するため。

本番 validator (`metalgo` が専用 VPS で動作、port 9651 公開) はこのリポジトリとは別の懸念事項です。このリポジトリは validator を**説明と documentation のみ**します。

リポジトリ内のすべての作業は最上位文書 [`docs/CONSTITUTION.md`](docs/CONSTITUTION.md) と [`docs/OPERATING_MODEL.md`](docs/OPERATING_MODEL.md) のワークフローに従います。

## クイックスタート

### 前提

- Docker Desktop (または Compose v2 が動く任意の Docker engine)
- macOS / Linux (Windows は未検証)
- Apple Silicon Mac: そのまま動く (metalgo image に arm64 build あり)

### 初期セットアップ

```sh
# Secret-scanning pre-commit hook を有効化 (local git config、push されない)
git config core.hooksPath .githooks

# Optional: gitleaks を入れて pre-commit を強化
brew install gitleaks   # macOS

# Local env (HTTP_PORT の衝突回避用)
cp .env.example .env
```

### サイト起動 (Caddy)

```sh
make site-up        # Caddy を起動 → http://localhost:8080 (or HTTP_PORT)
make site-logs      # ログ追従
make site-down      # 停止
```

### Tahoe testnet ノード起動 (metalgo)

```sh
make node-up        # image を pull して起動、bootstrap に ~30s-2min
make node-status    # NodeID + bootstrap を取得、public/api/validator.json を更新
make node-logs      # metalgo ログ追従
make node-down      # 停止 (data volume は維持)
```

`make up` / `make down` で両方を同時に起動 / 停止。

## ファイル構成

```
.
├── TOOLKIT.md                   # scripts/ のカタログ
├── CLAUDE.md                    # AI セッション用プロジェクト文脈
├── caddy/Caddyfile              # security headers, CSP (default-src 'none' base)
├── docker-compose.yml           # site (Caddy), project: site
├── docker-compose.override.yml  # local dev port mapping
├── docker-compose.metalgo.yml   # Tahoe testnet ノード, project: metalgo-stack
├── public/                      # 静的サイト (EN + JA mirror)
│   ├── index.html / ja/
│   ├── data/                    # 全 JSON/JSONL feed のドキュメント
│   ├── styles.css
│   ├── 404.html / ja/404.html
│   ├── robots.txt
│   └── api/
│       ├── validator.example.json     # schema 例 (commit する)
│       └── validator.json             # gitignore、node-info.sh で生成
├── scripts/                     # 詳細は TOOLKIT.md
├── docs/                        # 運用 runbook
├── .githooks/pre-commit         # gitleaks + fallback grep
└── Makefile
```

## セキュリティ姿勢

- **Pre-commit hook** (`.githooks/pre-commit`) で PEM 秘密鍵 / AWS・GitHub token / `.env` / `.pem` / `.p12` / `staker.key` 等をコミット前にブロック
- **CSP**: `default-src 'none'` ベース、必要な resource type のみ allowlist
- **ローカル dev bind**: metalgo の port は `127.0.0.1` のみに bind — LAN から隔離。本番 VPS は別 compose で public bind
- **コンテナ**: `read_only` root FS、`cap_drop: [ALL]`、`no-new-privileges`
- **Secret**: staking key は Docker named volume の中だけに置き、host filesystem に出さない。`.gitignore` で PEM/p12/`staker.*`/`signer.*`/`.env` を包括
- **Key rotation**: [docs/KEY_ROTATION.md](docs/KEY_ROTATION.md) を参照

## 他の Metal validator 向け

Metal Blockchain validator を運用中 / 検討中の方は、[TOOLKIT.md](TOOLKIT.md) でこのリポジトリのどの script が任意の Metal validator で再利用可能か、どれが私たちの構成前提かを区別しています。短く言うと、`scripts/` の大半は chain-level の汎用操作 (validator state、peer-set snapshot、uptime 履歴、anomaly detection、ntfy push、DR drill、renewal calendar) です。push / sync / bootstrap script は operator 固有の reference material です。

サイト公開カタログ <https://metal.freedom-yield.com/data/> で、サイトが公開する全 JSON / JSONL feed をドキュメント化しています。

## プロジェクトステータス

**Mainnet active** — 2026-05-19 から。本番 NodeID: `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v`。

現在の運用は月次 cycle 再登録 + 小さな delegation fee。Live status と過去 cycle 履歴は <https://metal.freedom-yield.com/> および `/api/uptime-cycles.json` で公開しています。

## 連絡先

info@metal.freedom-yield.com
