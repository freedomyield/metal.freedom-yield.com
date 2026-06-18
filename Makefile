# Metal Blockchain validator サイト + Tahoe testnet ノード管理
#
# 二つの compose を扱う:
#   - docker-compose.yml + override.yml      → サイト本体(Caddy)
#   - docker-compose.metalgo.yml              → Tahoe testnet ノード(独立)

.PHONY: help up down logs restart site-up site-down site-logs node-up node-down node-logs node-status node-shell smoke

help: ## このヘルプを表示
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

## --- サイト (Caddy) ---

site-up: ## サイトを起動 (localhost:${HTTP_PORT:-8080})
	docker compose up -d
	@echo "Site: http://localhost:$${HTTP_PORT:-8080}/"

site-down: ## サイトを停止
	docker compose down

site-logs: ## サイトのログ
	docker compose logs -f caddy

## --- Tahoe testnet ノード (metalgo) ---

node-up: ## Tahoe testnet ノードを起動 (~数十分で同期完了)
	docker compose -f docker-compose.metalgo.yml up -d
	@echo "metalgo API: http://localhost:9650"
	@echo "同期状況: make node-status"

node-down: ## Tahoe testnet ノードを停止 (data volume は残る)
	docker compose -f docker-compose.metalgo.yml down

node-down-clean: ## ノード停止 + chain data 削除 (再同期したい時)
	docker compose -f docker-compose.metalgo.yml down -v

node-logs: ## ノードのログ
	docker compose -f docker-compose.metalgo.yml logs -f metalgo

node-status: ## NodeID / bootstrap 状況を表示し、public/api/validator.json を更新
	bash scripts/node-info.sh

check-validator: ## 自分の NodeID が Tahoe validator set に入ったか確認(委任 tx 送信後に実行)
	bash scripts/check-validator.sh

node-shell: ## ノードコンテナにシェル接続(デバッグ用)
	docker compose -f docker-compose.metalgo.yml exec metalgo /bin/sh

## --- 両方 ---

up: site-up node-up ## サイトとノードを両方起動

down: site-down node-down ## サイトとノードを両方停止

logs: ## 両方のログを別タブで見るのを推奨。ここはサイトのみ
	@echo "サイト: make site-logs"
	@echo "ノード: make node-logs"
