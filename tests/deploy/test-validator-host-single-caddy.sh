#!/usr/bin/env bash
# tests/deploy/test-validator-host-single-caddy.sh
#
# The validator host runs exactly ONE Caddy: the deploy-managed `site` stack
# (container caddy-static, custom image caddy-static:local with the rate_limit
# plugin), bound to loopback only:
#   - 127.0.0.1:8085 -> :80   (deploy health check; the behind-proxy site)
# and NOTHING else on the host: no 8443, no 80/443, nothing on 0.0.0.0.
#
# Why (2026-10-07): earlier that day a second, hand-made Caddy (80/443 + 8443)
# crash-looped after a reboot and the operator ops dashboard (127.0.0.1:8443,
# SSH tunnel + BasicAuth) was briefly re-homed onto caddy-static through
# docker-compose.ops-tunnel.yml. The operator then abolished the dashboard
# (never used; it duplicated the operator /status/ page on the web host). This
# suite pins the result so neither the dashboard port nor its credential
# requirement can quietly come back.
#
# Checks, over the REAL `docker compose config` of exactly the file set the
# deploy workflow uses (parsed out of deploy.yml, not restated here):
#   T1 deploy.yml's Caddy step uses base + behind-proxy only (2 files)
#   T2 merged ports are exactly {127.0.0.1:8085->80}
#   T3 the config renders with an EMPTY environment (no OPS_BASIC_AUTH_HASH or
#      any other credential is required) and passes no OPS_BASIC_AUTH_HASH
#   T4 the Caddyfile has no :8443 site and no basic_auth; no compose file
#      in the repo publishes 8443; docker-compose.ops-tunnel.yml is gone
#   T5 image/container stay caddy-static:local / caddy-static, project `site`
#   T6 scripts/vps-bootstrap.sh brings Caddy up with the same file set and its
#      server-status cron names the caddy-static container
#   T7 deploy.yml's Caddy step does not probe 8443 any more
#
# `docker compose config` only renders files; it touches no container. Runs in a
# throwaway copy so no .env in the checkout can leak in.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REPO/.github/workflows/deploy.yml"
BOOTSTRAP="$REPO/scripts/vps-bootstrap.sh"
CADDYFILE="$REPO/caddy/Caddyfile"
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

EXPECTED_FILES="docker-compose.yml docker-compose.behind-proxy.yml"

echo "T1: deploy.yml's Caddy step composes base + behind-proxy only"
COMPOSE_LINE="$(grep -E '^[[:space:]]*COMPOSE="docker compose ' "$WORKFLOW" | head -1)"
DEPLOY_FILES="$(printf '%s\n' "$COMPOSE_LINE" | grep -oE -- '-f [^ "]+' | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "T1 deploy compose -f set" "$EXPECTED_FILES" "$DEPLOY_FILES"

echo "T7: deploy.yml's Caddy step no longer probes 8443"
# Only the "Bring up / reload Caddy on VPS" step body, up to the next step.
CADDY_STEP="$(awk '
  /^[[:space:]]*- name: Bring up \/ reload Caddy on VPS[[:space:]]*$/ { on = 1; next }
  on && /^[[:space:]]*- name: / { exit }
  on { print }' "$WORKFLOW")"
if [ -z "$CADDY_STEP" ]; then
  bad "T7 Caddy step found in deploy.yml" "step body empty"
elif printf '%s\n' "$CADDY_STEP" | grep -v '^[[:space:]]*#' | grep -q '8443'; then
  bad "T7 Caddy step does not touch 8443" "$(printf '%s\n' "$CADDY_STEP" | grep -v '^[[:space:]]*#' | grep -m1 '8443')"
else
  ok "T7 Caddy step does not touch 8443"
fi
if printf '%s\n' "$CADDY_STEP" | grep -Eq '^[[:space:]]*curl -fsS -o /dev/null http://127\.0\.0\.1:8085/health[[:space:]]*$'; then
  ok "T7b Caddy step still health-checks 127.0.0.1:8085"
else
  bad "T7b Caddy step still health-checks 127.0.0.1:8085" "curl ... 8085/health not found"
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

echo "T4: no dashboard vhost, credential or port anywhere in the Caddy config"
# Non-comment lines only: the decision record in comments may name the old port.
CF_CODE="$(grep -v '^[[:space:]]*#' "$CADDYFILE")"
if printf '%s\n' "$CF_CODE" | grep -Eq '^[[:space:]]*[^[:space:]]*:8443[[:space:]]*\{'; then
  bad "T4a Caddyfile has no :8443 site" "$(printf '%s\n' "$CF_CODE" | grep -m1 ':8443')"
else
  ok "T4a Caddyfile has no :8443 site"
fi
if printf '%s\n' "$CF_CODE" | grep -Eq '^[[:space:]]*basic_auth[[:space:]]*\{|OPS_BASIC_AUTH_HASH'; then
  bad "T4b Caddyfile has no basic_auth / OPS_BASIC_AUTH_HASH" "$(printf '%s\n' "$CF_CODE" | grep -m1 -E 'basic_auth|OPS_BASIC_AUTH_HASH')"
else
  ok "T4b Caddyfile has no basic_auth / OPS_BASIC_AUTH_HASH"
fi
LEAK=""
for f in "$REPO"/docker-compose*.yml; do
  if grep -v '^[[:space:]]*#' "$f" | grep -Eq '8443|OPS_BASIC_AUTH_HASH'; then LEAK="$LEAK $(basename "$f")"; fi
done
assert_eq "T4c no compose file publishes 8443 or passes OPS_BASIC_AUTH_HASH" "" "$LEAK"
if [ -e "$REPO/docker-compose.ops-tunnel.yml" ]; then
  bad "T4d docker-compose.ops-tunnel.yml is gone" "file exists"
else
  ok "T4d docker-compose.ops-tunnel.yml is gone"
fi

if ! command -v jq >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1 \
   || ! docker compose version >/dev/null 2>&1; then
  if [ -n "${CI:-}" ]; then bad "docker compose v2 + jq" "required in CI"; finish; fi
  echo "SKIP: T2/T3/T5 need docker compose v2 + jq (static checks above still ran)"
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

echo "T3: renders with an empty environment (no credential required)"
JSON="$(render 2>"$TMP/err")"; rc=$?
assert_eq "T3a config renders with no env at all" 0 "$rc"
[ "$rc" -eq 0 ] || { bad "T3a stderr" "$(head -c 200 "$TMP/err")"; finish; }
assert_eq "T3b no OPS_BASIC_AUTH_HASH reaches the container" "absent" \
  "$(printf '%s' "$JSON" | jq -r 'if (.services.caddy.environment // {} | has("OPS_BASIC_AUTH_HASH")) then "present" else "absent" end')"

echo "T2: published ports are loopback 8085 only"
PORTS="$(printf '%s' "$JSON" | jq -r '.services.caddy.ports // [] | map("\(.host_ip // "ALL"):\(.published)->\(.target)/\(.protocol // "tcp")") | sort | join(",")')"
assert_eq "T2 exact port set" "127.0.0.1:8085->80/tcp" "$PORTS"

echo "T5: still the one custom-image Caddy"
assert_eq "T5a project" "site" "$(printf '%s' "$JSON" | jq -r '.name')"
assert_eq "T5b container_name" "caddy-static" "$(printf '%s' "$JSON" | jq -r '.services.caddy.container_name')"
assert_eq "T5c image" "caddy-static:local" "$(printf '%s' "$JSON" | jq -r '.services.caddy.image')"
assert_eq "T5d only one service" "caddy" "$(printf '%s' "$JSON" | jq -r '.services | keys | join(",")')"

finish
