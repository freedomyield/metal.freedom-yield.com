#!/usr/bin/env bash
# tests/compose-naming/test-compose-config-naming.sh
#
# The REAL `docker compose config` over the repo's metalgo compose files:
#   - with no naming env, the names are unchanged from before 2026-10-03
#     (project metalgo-stack, container metalgo-<network>, volume
#     metalgo-stack_metalgo_data; base-only container metalgo-testnet)
#   - METALGO_COMPOSE_PROJECT / METALGO_CONTAINER_NAME (in the environment, or in a
#     .env beside the compose files as on the host) change the project,
#     the container AND the /data named volume together
#   - check-compose-naming.sh parses real compose output: with docker ps /
#     inspect stubbed to a synthetic container, aligned env -> MATCH, default
#     env -> MISMATCH on all three items, COMPOSE_PROJECT_NAME -> isolation MISMATCH
#   - docker-compose.metalgo.adopt.yml: with METALGO_DATA_VOLUME the /data volume
#     renders `external: true` under exactly that name (project/container
#     untouched); without it the override refuses to render (fail closed); the
#     verifier picks the override up from the env / .env and reports adopt MATCH
#   - drift items over real compose output: the default mainnet command / 16g /
#     8 CPUs / unless-stopped compare equal to a container carrying the same
#     values (the production shape), and METAL_MEM_LIMIT changes are caught
#   - why COMPOSE_PROJECT_NAME is not the knob: the host .env is shared with
#     the Caddy stack, and COMPOSE_PROJECT_NAME renames that stack too, while
#     METALGO_COMPOSE_PROJECT leaves it alone.
#
# `docker compose config` only renders files — it never contacts containers or
# volumes. It runs in a throwaway copy so a host .env in the checkout cannot
# leak in. All names are synthetic (t-*).
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

skip_or_fail() {
  if [ -n "${CI:-}" ]; then echo "FAIL: $1 (CI must run this suite)"; exit 1; fi
  echo "SKIP: $1"; exit 0
}
command -v jq >/dev/null 2>&1 || skip_or_fail "jq not available"
command -v docker >/dev/null 2>&1 || skip_or_fail "docker not available"
docker compose version >/dev/null 2>&1 || skip_or_fail "docker compose v2 not available"
REAL_DOCKER="$(command -v docker)"

PASS=0; FAIL=0; FAILURES=()
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1 ($2)"); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected='$2' actual='$3'"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing '$2' in '$3'" ;; esac; }

W="$TMP/repo"
mkdir -p "$W/scripts" "$TMP/bin"
cp "$REPO/docker-compose.metalgo.yml" "$REPO/docker-compose.metalgo.prod.yml" "$REPO/docker-compose.metalgo.adopt.yml" "$W/"
cp "$REPO/scripts/check-compose-naming.sh" "$W/scripts/"

# names <extra env...> -> "project|container|volume|mount-source" (prod overlay)
names() {
  (cd "$W" && env -i PATH="$PATH" HOME="$HOME" ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} \
     METAL_NETWORK=mainnet METAL_PUBLIC_IP=192.0.2.1 "$@" \
     docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml config --format json) \
  | jq -r '[.name, .services.metalgo.container_name, (.volumes.metalgo_data.name // "-"),
            ([.services.metalgo.volumes[] | select(.target == "/data")][0].source)] | join("|")'
}

echo "T1: defaults unchanged"
assert_eq "T1 mainnet defaults" "metalgo-stack|metalgo-mainnet|metalgo-stack_metalgo_data|metalgo_data" "$(names)"
assert_eq "T1 tahoe container follows METAL_NETWORK" "metalgo-stack|metalgo-tahoe|metalgo-stack_metalgo_data|metalgo_data" "$(names METAL_NETWORK=tahoe)"
base=$(cd "$W" && env -i PATH="$PATH" HOME="$HOME" docker compose -f docker-compose.metalgo.yml config --format json \
       | jq -r '[.name, .services.metalgo.container_name, .volumes.metalgo_data.name] | join("|")')
assert_eq "T1 base-only (local dev) unchanged" "metalgo-stack|metalgo-testnet|metalgo-stack_metalgo_data" "$base"

echo "T2: environment overrides move project, container and volume together"
assert_eq "T2 both overridden" "t-proj|t-ctr|t-proj_metalgo_data|metalgo_data" \
  "$(names METALGO_COMPOSE_PROJECT=t-proj METALGO_CONTAINER_NAME=t-ctr)"
assert_eq "T2 project only -> container keeps default" "t-proj|metalgo-mainnet|t-proj_metalgo_data|metalgo_data" \
  "$(names METALGO_COMPOSE_PROJECT=t-proj)"
assert_eq "T2 container only -> project/volume keep default" "metalgo-stack|t-ctr|metalgo-stack_metalgo_data|metalgo_data" \
  "$(names METALGO_CONTAINER_NAME=t-ctr)"
assert_eq "T2 empty values fall back to defaults" "metalgo-stack|metalgo-mainnet|metalgo-stack_metalgo_data|metalgo_data" \
  "$(names METALGO_CONTAINER_NAME= METALGO_COMPOSE_PROJECT=)"

echo "T3: a .env beside the compose files (the host layout) is honoured"
printf 'METALGO_COMPOSE_PROJECT=t-envproj\nMETALGO_CONTAINER_NAME=t-envctr\n' >"$W/.env"
assert_eq "T3 .env overrides" "t-envproj|t-envctr|t-envproj_metalgo_data|metalgo_data" "$(names)"
rm -f "$W/.env"

echo "T4: METALGO_DATA_PATH still switches /data to a bind mount"
assert_eq "T4 bind source" "/srv/t-data" "$(names METALGO_DATA_PATH=/srv/t-data | cut -d'|' -f4)"

echo "T5: verifier against real compose output (ps/inspect stubbed)"
cat >"$TMP/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/log"
case "\$1" in
  compose) exec "$REAL_DOCKER" "\$@" ;;
  ps) echo cid-1 ;;
  inspect) cat "$TMP/insp.json" ;;
  volume) [ "\$2" = inspect ] && echo '[{}]' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/docker"
jq -n '[{Name:"/t-ctr", State:{Status:"running"},
         Config:{Image:"metalblockchain/metalgo:latest",
                 Cmd:["/metalgo/build/metalgo","--network-id=mainnet","--public-ip=192.0.2.1","--http-host=0.0.0.0",
                      "--http-port=9650","--staking-port=9651","--log-level=info","--data-dir=/data"],
                 Labels:{"com.docker.compose.project":"t-proj","com.docker.compose.service":"metalgo"}},
         HostConfig:{Memory:17179869184, NanoCpus:8000000000, RestartPolicy:{Name:"unless-stopped"}},
         Mounts:[{Type:"volume",Name:"t-proj_metalgo_data",Destination:"/data"}]}]' >"$TMP/insp.json"
vrun() {
  : >"$TMP/log"
  env -i PATH="$TMP/bin:$PATH" HOME="$HOME" ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} \
    METAL_NETWORK=mainnet METAL_PUBLIC_IP=192.0.2.1 "$@" bash "$W/scripts/check-compose-naming.sh" 2>&1
}
out=$(vrun METALGO_COMPOSE_PROJECT=t-proj METALGO_CONTAINER_NAME=t-ctr); rc=$?
assert_eq "T5a aligned env -> exit 0" 0 "$rc"
assert_contains "T5a data MATCH on the resolved volume" "MATCH     data      volume:t-proj_metalgo_data" "$out"
out=$(vrun); rc=$?
assert_eq "T5b default env -> exit 1" 1 "$rc"
assert_eq "T5b three MISMATCH lines" 3 "$(printf '%s\n' "$out" | grep -c '^MISMATCH ')"
out=$(vrun METALGO_COMPOSE_PROJECT=t-proj METALGO_CONTAINER_NAME=t-ctr COMPOSE_PROJECT_NAME=t-proj); rc=$?
assert_eq "T5c COMPOSE_PROJECT_NAME set -> exit 1 even though names align" 1 "$rc"
assert_contains "T5c isolation MISMATCH" "MISMATCH  isolation" "$out"
assert_eq "T5a nine MATCH lines (naming + drift on real compose output)" 9 "$(vrun METALGO_COMPOSE_PROJECT=t-proj METALGO_CONTAINER_NAME=t-ctr | grep -c '^MATCH ')"
out=$(vrun METALGO_COMPOSE_PROJECT=t-proj METALGO_CONTAINER_NAME=t-ctr METAL_MEM_LIMIT=8g); rc=$?
assert_eq "T5d METAL_MEM_LIMIT=8g vs a 16g container -> exit 1" 1 "$rc"
assert_contains "T5d memory MISMATCH in bytes" "MISMATCH  memory    compose=8589934592  running=17179869184" "$out"
out=$(vrun METALGO_COMPOSE_PROJECT=t-proj METALGO_CONTAINER_NAME=t-ctr METAL_PUBLIC_IP=192.0.2.2); rc=$?
assert_eq "T5e a different METAL_PUBLIC_IP -> exit 1 (command drift)" 1 "$rc"
assert_contains "T5e command MISMATCH" "MISMATCH  command" "$out"
bad_calls=$(grep -vE '^(compose .* config( |$)|ps |inspect |volume inspect )' "$TMP/log" || true)
assert_eq "T5 docker saw only config/ps/inspect/volume inspect" "" "$bad_calls"

echo "T7: the adopt override over the real compose files"
adopt() {
  (cd "$W" && env -i PATH="$PATH" HOME="$HOME" ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} \
     METAL_NETWORK=mainnet METAL_PUBLIC_IP=192.0.2.1 "$@" \
     docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml -f docker-compose.metalgo.adopt.yml config --format json)
}
assert_eq "T7a external volume under exactly METALGO_DATA_VOLUME; project/container untouched" \
  "t-proj|t-ctr|t-old_data|true|metalgo_data" \
  "$(adopt METALGO_COMPOSE_PROJECT=t-proj METALGO_CONTAINER_NAME=t-ctr METALGO_DATA_VOLUME=t-old_data \
     | jq -r '[.name, .services.metalgo.container_name, .volumes.metalgo_data.name, .volumes.metalgo_data.external,
               ([.services.metalgo.volumes[] | select(.target == "/data")][0].source)] | join("|")')"
adopt >/dev/null 2>"$TMP/adopt.err"; rc=$?
assert_eq "T7b override without METALGO_DATA_VOLUME refuses to render" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "T7b error names the variable" "METALGO_DATA_VOLUME" "$(cat "$TMP/adopt.err")"
jq '.[0].Mounts[0].Name = "t-old_data"' "$TMP/insp.json" >"$TMP/insp2.json" && mv "$TMP/insp2.json" "$TMP/insp.json"
out=$(vrun METALGO_COMPOSE_PROJECT=t-proj METALGO_CONTAINER_NAME=t-ctr METALGO_DATA_VOLUME=t-old_data); rc=$?
assert_eq "T7c verifier with METALGO_DATA_VOLUME (real compose) -> exit 0" 0 "$rc"
assert_contains "T7c adopt MATCH" "MATCH     adopt     external volume t-old_data" "$out"
assert_contains "T7c data MATCH on the adopted name" "MATCH     data      volume:t-old_data" "$out"
printf 'METALGO_COMPOSE_PROJECT=t-proj\nMETALGO_CONTAINER_NAME=t-ctr\nMETALGO_DATA_VOLUME=t-old_data\n' >"$W/.env"
out=$(vrun); rc=$?
assert_eq "T7d same via the host-style .env -> exit 0" 0 "$rc"
assert_contains "T7d adopt MATCH via .env" "MATCH     adopt" "$out"
rm -f "$W/.env"

echo "T6: the Caddy stack (same host .env) is untouched by the metalgo knobs"
cp "$REPO/docker-compose.yml" "$REPO/docker-compose.prod.yml" "$W/"
site() {
  (cd "$W" && env -i PATH="$PATH" HOME="$HOME" ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} \
     DOMAIN=example.com ACME_EMAIL=ops@example.com OPS_BASIC_AUTH_HASH=x "$@" \
     docker compose -f docker-compose.yml -f docker-compose.prod.yml config --format json) \
  | jq -r '[.name, .volumes.caddy_data.name] | join("|")'
}
site_default=$(site)
assert_eq "T6a METALGO_* leave the site project/volume alone" "$site_default" \
  "$(site METALGO_COMPOSE_PROJECT=t-proj METALGO_CONTAINER_NAME=t-ctr)"
assert_eq "T6b (rationale) COMPOSE_PROJECT_NAME would rename the site stack" "t-proj|t-proj_caddy_data" \
  "$(site COMPOSE_PROJECT_NAME=t-proj)"

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
