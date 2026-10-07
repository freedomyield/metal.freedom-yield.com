#!/usr/bin/env bash
# tests/deploy/test-validator-host-single-caddy.sh
#
# The validator host runs exactly ONE Caddy: the deploy-managed `site` stack
# (container caddy-static, custom image caddy-static:local with the rate_limit
# plugin). It must serve BOTH
#   - 127.0.0.1:8085 -> :80   (deploy health check; the behind-proxy site)
#   - 127.0.0.1:8443 -> :8443 (operator ops dashboard, SSH tunnel + BasicAuth)
# and NOTHING else on the host: no 80/443, nothing on 0.0.0.0.
#
# Why (2026-10-07): a second Caddy (stock image, 80/443 + 8443, created by hand
# from docker-compose.prod.yml in May) had kept the ops dashboard alive on a
# config it read before the Caddyfile started using rate_limit. The first
# reboot made it re-read the Caddyfile and it crash-looped. The ops vhost now
# rides on the deploy-managed custom-image Caddy via docker-compose.ops-tunnel.yml.
#
# Checks, over the REAL `docker compose config` of exactly the file set the
# deploy workflow uses (parsed out of deploy.yml, not restated here):
#   T1 deploy.yml's Caddy step uses base + behind-proxy + ops-tunnel
#   T2 merged ports are exactly {127.0.0.1:8085->80, 127.0.0.1:8443->8443}
#   T3 the real OPS_BASIC_AUTH_HASH from the env replaces the behind-proxy dummy
#   T4 without OPS_BASIC_AUTH_HASH the config refuses to render (fail closed)
#   T5 image/container stay caddy-static:local / caddy-static, project `site`
#   T6 scripts/vps-bootstrap.sh brings Caddy up with the same file set and its
#      server-status cron names the caddy-static container
#   T7 deploy.yml's Caddy step probes 127.0.0.1:8443 and fails on any code other
#      than 401 (an open or missing dashboard must stop the deploy)
#
# `docker compose config` only renders files; it touches no container. Runs in a
# throwaway copy so no .env in the checkout can leak in. Hash values are synthetic.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REPO/.github/workflows/deploy.yml"
BOOTSTRAP="$REPO/scripts/vps-bootstrap.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; FAILURES=()
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1 ($2)"); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected='$2' actual='$3'"; fi; }

finish() {
  echo
  echo "PASS=$PASS FAIL=$FAIL"
  if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
  exit 0
}

EXPECTED_FILES="docker-compose.yml docker-compose.behind-proxy.yml docker-compose.ops-tunnel.yml"

echo "T1: deploy.yml's Caddy step composes base + behind-proxy + ops-tunnel"
COMPOSE_LINE="$(grep -E '^[[:space:]]*COMPOSE="docker compose ' "$WORKFLOW" | head -1)"
DEPLOY_FILES="$(printf '%s\n' "$COMPOSE_LINE" | grep -oE -- '-f [^ "]+' | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "T1 deploy compose -f set" "$EXPECTED_FILES" "$DEPLOY_FILES"

echo "T7: deploy.yml's Caddy step requires HTTP 401 (no credentials) from 127.0.0.1:8443"
# Only the "Bring up / reload Caddy on VPS" step body, up to the next step.
CADDY_STEP="$(awk '
  /^[[:space:]]*- name: Bring up \/ reload Caddy on VPS[[:space:]]*$/ { on = 1; next }
  on && /^[[:space:]]*- name: / { exit }
  on { print }' "$WORKFLOW")"
if printf '%s\n' "$CADDY_STEP" | grep -Eq "^[[:space:]]*OPS_CODE=\\\$\\(curl [^#]*-w '%\\{http_code\\}' http://127\\.0\\.0\\.1:8443/"; then
  ok "T7a step probes http://127.0.0.1:8443/ for its HTTP code"
else
  bad "T7a step probes http://127.0.0.1:8443/ for its HTTP code" "OPS_CODE=\$(curl ... 8443/) not found"
fi
# The gate itself: a non-401 code must reach `exit 1` (mutation M3 deleted this).
GATE="$(printf '%s\n' "$CADDY_STEP" | awk '
  /^[[:space:]]*if \[ "\$OPS_CODE" != "401" \]; then[[:space:]]*$/ { on = 1; next }
  on && /^[[:space:]]*fi[[:space:]]*$/ { exit }
  on { print }')"
if printf '%s\n' "$GATE" | grep -q 'expected 401' && printf '%s\n' "$GATE" | grep -Eq '^[[:space:]]*exit 1[[:space:]]*$'; then
  ok "T7b any code other than 401 fails the step with the 'expected 401' message"
else
  bad "T7b any code other than 401 fails the step" "if [ \"\$OPS_CODE\" != \"401\" ] ... exit 1 block not found"
fi

echo "T6: vps-bootstrap uses the same file set and names caddy-static for server-status"
BOOT_LINE="$(grep -E '^[[:space:]]*docker compose (-f [^ ]+ )+up -d' "$BOOTSTRAP" | grep 'docker-compose.yml' | head -1)"
BOOT_FILES="$(printf '%s\n' "$BOOT_LINE" | grep -oE -- '-f [^ ]+' | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "T6a bootstrap Caddy compose -f set" "$EXPECTED_FILES" "$BOOT_FILES"
if grep -Eq '^CADDY_CONTAINER=caddy-static$' "$BOOTSTRAP"; then
  ok "T6b bootstrap server-status cron sets CADDY_CONTAINER=caddy-static"
else
  bad "T6b bootstrap server-status cron sets CADDY_CONTAINER=caddy-static" "line not found"
fi
if grep -Eq '^METALGO_CONTAINER=' "$BOOTSTRAP"; then
  ok "T6c bootstrap server-status cron sets METALGO_CONTAINER (server-status.sh requires it)"
else
  bad "T6c bootstrap server-status cron sets METALGO_CONTAINER" "line not found"
fi

if ! command -v jq >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1 \
   || ! docker compose version >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then bad "docker compose v2 + jq" "required in CI"; finish; fi
  echo "SKIP: T2-T5 need docker compose v2 + jq (static checks above still ran)"
  finish
fi

W="$TMP/repo"
mkdir -p "$W/caddy"
for f in $DEPLOY_FILES; do
  if [ -f "$REPO/$f" ]; then cp "$REPO/$f" "$W/"; else bad "compose file exists" "$f missing"; finish; fi
done
FARGS=()
for f in $DEPLOY_FILES; do FARGS+=(-f "$f"); done

render() {
  (cd "$W" && env -i PATH="$PATH" HOME="$HOME" ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} "$@" \
     docker compose "${FARGS[@]}" config --format json)
}

SYNTH_HASH='$2a$14$SyntheticTestHashOnlyForComposeRenderXXXXXXXXXXXXXX'
JSON="$(render OPS_BASIC_AUTH_HASH="$SYNTH_HASH")"; rc=$?
assert_eq "T2 config renders with OPS_BASIC_AUTH_HASH set" 0 "$rc"

echo "T2: published ports are loopback 8085 + 8443 only"
PORTS="$(printf '%s' "$JSON" | jq -r '.services.caddy.ports // [] | map("\(.host_ip // "ALL"):\(.published)->\(.target)/\(.protocol // "tcp")") | sort | join(",")')"
assert_eq "T2 exact port set" "127.0.0.1:8085->80/tcp,127.0.0.1:8443->8443/tcp" "$PORTS"

echo "T3: the real hash from the env reaches the container"
# `config` re-escapes every literal $ as $$ in its output; undo that to compare.
GOT_HASH="$(printf '%s' "$JSON" | jq -r '.services.caddy.environment.OPS_BASIC_AUTH_HASH // "" | gsub("\\$\\$"; "$")')"
assert_eq "T3 OPS_BASIC_AUTH_HASH is the env value, not the behind-proxy dummy" "$SYNTH_HASH" "$GOT_HASH"

echo "T4: no hash -> refuse to render"
render >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'OPS_BASIC_AUTH_HASH' "$TMP/err"; then
  ok "T4 missing OPS_BASIC_AUTH_HASH fails closed (rc=$rc)"
else
  bad "T4 missing OPS_BASIC_AUTH_HASH fails closed" "rc=$rc err=$(head -c 200 "$TMP/err")"
fi

echo "T5: still the one custom-image Caddy"
assert_eq "T5a project" "site" "$(printf '%s' "$JSON" | jq -r '.name')"
assert_eq "T5b container_name" "caddy-static" "$(printf '%s' "$JSON" | jq -r '.services.caddy.container_name')"
assert_eq "T5c image" "caddy-static:local" "$(printf '%s' "$JSON" | jq -r '.services.caddy.image')"
assert_eq "T5d only one service" "caddy" "$(printf '%s' "$JSON" | jq -r '.services | keys | join(",")')"

finish
