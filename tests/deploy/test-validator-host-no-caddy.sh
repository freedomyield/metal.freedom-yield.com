#!/usr/bin/env bash
# tests/deploy/test-validator-host-no-caddy.sh
#
# Invariant: NO Caddy (and no other site container) runs on the validator host.
#
# Why (2026-10-07): after the operator ops dashboard was abolished, the
# validator host's caddy-static (project `site`, 127.0.0.1:8085) served
# nothing; its only client was deploy.yml's own health check. The public site
# is served by the web host (its own caddy-static behind its nginx). The
# operator decided to remove the validator-host Caddy, and Constitution v0.8 §5
# dropped "build / up / reload the site Caddy" from CI's sanctioned path onto
# the validator host. This suite pins that so the Caddy step, the bootstrap
# step or the cron env cannot quietly come back.
#
# Checks (each check function is also run against a mutant that reintroduces
# the removed shape, and must fail on it — teeth are shown on every run):
#   D  deploy.yml: no non-comment line runs docker / caddy / 8085 (the
#      validator-host leg and the Xserver leg alike — neither runs a container)
#   B  scripts/vps-bootstrap.sh: no step_caddy (sourced, not grepped), no
#      site-stack `docker compose -f docker-compose.yml … up`, no
#      CADDY_CONTAINER in the server-status cron; METALGO_CONTAINER stays
#   M  server-status.sh / check-anomalies.sh / daily-status.sh /
#      anomaly-state-init.sh: no caddy field, no CADDY_CONTAINER, no Caddy
#      stop/recovery alert, no caddy state seed (server-status.json schema is
#      observedAt / host / metalgo / security)
#   T4 the site Caddy definition (kept: it is the web host's shape) still has
#      no :8443 site / basic_auth / OPS_BASIC_AUTH_HASH, and the ops-tunnel
#      override stays deleted
#   T2/T3/T5 the site compose definition (docker-compose.yml +
#      docker-compose.behind-proxy.yml, the web host's shape: nginx ->
#      127.0.0.1:8085) renders with an empty env, loopback 8085 only, one
#      caddy-static service. `docker compose config` touches no container.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe.

set -uo pipefail
exec </dev/null

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

# report <label> <violations> — PASS when the check printed nothing.
report() {
  if [ -z "$2" ]; then ok "$1"
  else while IFS= read -r l; do bad "$1" "$l"; done <<<"$2"; fi
}
# expect_caught <label> <violations-from-mutant>
expect_caught() {
  if [ -n "$2" ]; then ok "mutant caught: $1"
  else bad "mutant NOT caught: $1" "check printed nothing"; fi
}

# --- D: deploy.yml ------------------------------------------------------------
check_deploy() {
  local f="$1" hits
  hits="$(grep -n -v -E '^[[:space:]]*#' "$f" | grep -i -E 'docker|caddy|8085' || true)"
  [ -z "$hits" ] || printf '%s\n' "$hits" | sed 's/^/runs a container on a deploy host: /'
}
echo "D: deploy.yml runs no Caddy / container on the validator host"
report "D deploy.yml has no docker / caddy / 8085 in code" "$(check_deploy "$WORKFLOW")"

# Mutant: the removed step, reinserted right before the Xserver leg.
awk '/^      - name: Set up Xserver deploy key/ {
  print "      - name: Bring up / reload Caddy on VPS"
  print "        run: |"
  print "          ssh \"$SSH_USER@$SSH_HOST\" \"cd $DEPLOY_PATH && docker compose -f docker-compose.yml -f docker-compose.behind-proxy.yml up -d --build\""
  print ""
} { print }' "$WORKFLOW" >"$TMP/deploy-mutant.yml"
expect_caught "Caddy step reinserted into deploy.yml" "$(check_deploy "$TMP/deploy-mutant.yml")"
awk '{ print } /^          rsync -rltvz --delete --inplace/ { print "          curl -fsS http://127.0.0.1:8085/health" }' "$WORKFLOW" >"$TMP/deploy-mutant2.yml"
if cmp -s "$TMP/deploy-mutant2.yml" "$WORKFLOW"; then bad "mutant 8085 probe changed deploy.yml" "sed matched nothing"
else expect_caught "8085 health probe reinserted" "$(check_deploy "$TMP/deploy-mutant2.yml")"; fi

# --- B: vps-bootstrap.sh -------------------------------------------------------
check_bootstrap() {
  local f="$1" code
  code="$(grep -v -E '^[[:space:]]*#' "$f")"
  if (VPS_BOOTSTRAP_SOURCED=1; . "$f" >/dev/null 2>&1; declare -F step_caddy >/dev/null); then
    echo "defines step_caddy"
  fi
  printf '%s\n' "$code" | grep -E '^[[:space:]]*step_caddy[[:space:]]*$' >/dev/null && echo "main() calls step_caddy"
  printf '%s\n' "$code" | grep -E 'docker compose .*-f docker-compose\.yml( |$)' >/dev/null && echo "brings up the site compose stack"
  printf '%s\n' "$code" | grep -E '^CADDY_CONTAINER=' >/dev/null && echo "server-status cron sets CADDY_CONTAINER"
  printf '%s\n' "$code" | grep -E '^METALGO_CONTAINER=' >/dev/null || echo "server-status cron lost METALGO_CONTAINER (server-status.sh requires it)"
  return 0
}
echo "B: vps-bootstrap provisions no Caddy"
report "B bootstrap has no Caddy step / site stack / CADDY_CONTAINER" "$(check_bootstrap "$BOOTSTRAP")"

awk '{ print } /^METALGO_CONTAINER=/ { print "CADDY_CONTAINER=caddy-static" }' "$BOOTSTRAP" >"$TMP/boot-m1.sh"
expect_caught "CADDY_CONTAINER back in the cron env" "$(check_bootstrap "$TMP/boot-m1.sh")"
awk '/^main\(\) \{/ {
  print "step_caddy() {"
  print "  docker compose -f docker-compose.yml -f docker-compose.behind-proxy.yml up -d --build"
  print "}"
  print ""
} { print } /^  step_metalgo$/ { print "  step_caddy" }' "$BOOTSTRAP" >"$TMP/boot-m2.sh"
M2="$(check_bootstrap "$TMP/boot-m2.sh")"
expect_caught "step_caddy defined + called" "$M2"
printf '%s\n' "$M2" | grep -qF "defines step_caddy" && ok "mutant caught via sourcing (defines step_caddy)" \
  || bad "sourced definition check has no teeth" "got: ${M2:-<none>}"
sed -e '/^METALGO_CONTAINER=/d' "$BOOTSTRAP" >"$TMP/boot-m3.sh"
expect_caught "METALGO_CONTAINER dropped along with CADDY_CONTAINER" "$(check_bootstrap "$TMP/boot-m3.sh")"

# --- M: monitoring no longer watches a validator-host Caddy ------------------
SS="$REPO/scripts/server-status.sh"
CA="$REPO/scripts/check-anomalies.sh"
DS="$REPO/scripts/daily-status.sh"
SI="$REPO/scripts/anomaly-state-init.sh"
code_of() { grep -v -E '^[[:space:]]*#' "$1"; }
# check_monitoring <server-status> <check-anomalies> <daily-status> <state-init>
check_monitoring() {
  code_of "$1" | grep -i -E 'caddy' >/dev/null && echo "server-status.sh still reads / requires / publishes caddy"
  code_of "$2" | grep -E '\.caddy|OBS_CADDY|Caddy 停止|Caddy 復旧' >/dev/null && echo "check-anomalies.sh still validates / alerts on caddy"
  code_of "$3" | grep -E '\.caddy|CADDY_S' >/dev/null && echo "daily-status.sh still reads caddy"
  code_of "$4" | grep -F '"caddy"' >/dev/null && echo "anomaly-state-init.sh still seeds caddy"
  [ -e "$REPO/scripts/lib/container-status.sh" ] && echo "caddy-only helper scripts/lib/container-status.sh is back"
  return 0
}
echo "M: monitoring has no validator-host Caddy"
report "M server-status / check-anomalies / daily-status / state-init ignore Caddy" \
  "$(check_monitoring "$SS" "$CA" "$DS" "$SI")"
awk '{ print } /^: "\$\{METALGO_CONTAINER:\?/ { print ": \"${CADDY_CONTAINER:?CADDY_CONTAINER is required}\"" }' "$SS" >"$TMP/ss-m.sh"
expect_caught "server-status requires CADDY_CONTAINER again" "$(check_monitoring "$TMP/ss-m.sh" "$CA" "$DS" "$SI")"
awk '{ print } /and \(\.metalgo\.peerCount\|type=="number"\)/ { print "      and (.caddy|type==\"object\")" }' "$CA" >"$TMP/ca-m.sh"
if cmp -s "$TMP/ca-m.sh" "$CA"; then bad "check-anomalies mutant changed the file" "awk matched nothing"
else expect_caught "check-anomalies K-1 requires .caddy again" "$(check_monitoring "$SS" "$TMP/ca-m.sh" "$DS" "$SI")"; fi
awk '{ print } /^METALGO_S=/ { print "CADDY_S=$(jq -r '"'"'.caddy.containerStatus'"'"' \"$STATUS_JSON\")" }' "$DS" >"$TMP/ds-m.sh"
expect_caught "daily-status reads .caddy again" "$(check_monitoring "$SS" "$CA" "$TMP/ds-m.sh" "$SI")"

# --- T4: the kept site definition stays dashboard-free --------------------------
echo "T4: no dashboard vhost, credential or port in the site Caddy definition"
CF_CODE="$(grep -v '^[[:space:]]*#' "$CADDYFILE")"
if printf '%s\n' "$CF_CODE" | grep -Eq '^[[:space:]]*[^[:space:]]*:8443[[:space:]]*\{'; then
  bad "T4a Caddyfile has no :8443 site" "$(printf '%s\n' "$CF_CODE" | grep -m1 ':8443')"
else
  ok "T4a Caddyfile has no :8443 site"
fi
BA_RE='^[[:space:]]*basic_auth[[:space:]]*\{|OPS_BASIC_AUTH_HASH'
if printf '%s\n' "$CF_CODE" | grep -Eq "$BA_RE"; then
  bad "T4b Caddyfile has no basic_auth / OPS_BASIC_AUTH_HASH" "$(printf '%s\n' "$CF_CODE" | grep -m1 -E "$BA_RE")"
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

SITE_FILES="docker-compose.yml docker-compose.behind-proxy.yml"
W="$TMP/repo"
mkdir -p "$W/caddy"
for f in $SITE_FILES; do
  if [ -f "$REPO/$f" ]; then cp "$REPO/$f" "$W/"; else bad "compose file exists" "$f missing"; finish; fi
done
FARGS=()
for f in $SITE_FILES; do FARGS+=(-f "$f"); done

render() {
  (cd "$W" && env -i PATH="$PATH" HOME="$HOME" ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} "$@" \
     docker compose "${FARGS[@]}" config --format json)
}

echo "T3: site definition renders with an empty environment (no credential required)"
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
