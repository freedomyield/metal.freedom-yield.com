# Custom Caddy image with the rate-limit plugin baked in.
# Built once per deploy (deploy.yml passes --build); layers cached.
#
# Why a custom image:
#   The stock caddy:2-alpine doesn't ship the rate_limit directive.
#   We need per-IP request quotas for /peers/ (BasicAuth brute-force
#   defense) and per-API throttling (caching-bypass attack defense).
#
# Plugin: github.com/mholt/caddy-ratelimit — official Caddy module,
# in-memory by default (we don't need distributed; single Caddy
# instance behind nginx).

FROM caddy:2-builder-alpine AS builder
RUN xcaddy build \
	--with github.com/mholt/caddy-ratelimit

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
