# Custom Caddy image with the rate-limit plugin baked in.
# Built wherever the site container runs from this repo (local dev:
# `make site-up`). This repo's deploy builds it nowhere: the web host has no
# git checkout of this repo (its deploy dir holds a non-git copy that deploy
# refreshes only under public/, so this file there is NOT updated by deploy),
# and the validator host runs no Caddy since 2026-10-07. A change here reaches the web host's `caddy-static` only by a
# separately approved rebuild (docs/DEPLOY_SETUP.md §9.4); a Caddyfile-only
# change goes through scripts/web-host-caddy-apply.sh (§9.2).
#
# Why a custom image:
#   The stock caddy:2-alpine doesn't ship the rate_limit directive.
#   We need per-IP request quotas for the whole site and per-API
#   throttling for /api/* (caching-bypass / scraping defense). There is no
#   BasicAuth-protected path any more (the /peers BasicAuth page is gone and
#   the ops dashboard was abolished on 2026-10-07).
#
# Plugin: github.com/mholt/caddy-ratelimit — official Caddy module,
# in-memory by default (we don't need distributed; single Caddy
# instance behind nginx).

FROM caddy:2-builder-alpine AS builder
RUN xcaddy build \
	--with github.com/mholt/caddy-ratelimit

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
