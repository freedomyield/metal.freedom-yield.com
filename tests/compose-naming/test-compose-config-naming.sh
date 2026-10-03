#!/usr/bin/env bash
# tests/compose-naming/test-compose-config-naming.sh
#
# The REAL `docker compose config` over the repo's metalgo compose files:
#   - with no naming env, the names are unchanged from before 2026-10-03
#     (project metalgo-stack, container metalgo-<network>, volume
#     metalgo-stack_metalgo_data; base-only container metalgo-testnet)
#   - COMPOSE_PROJECT_NAME / METALGO_CONTAINER_NAME (in the environment, or in a
#     .env beside the compose files as on the host) change the project,
#     the container AND the /data named volume together
#   - check-compose-naming.sh parses real compose output: with docker ps /
#     inspect stubbed to a synthetic container, aligned env -> MATCH, default
#     env -> MISMATCH on all three items.
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
cp "$REPO/docker-compose.metalgo.yml" "$REPO/docker-compose.metalgo.prod.yml" "$W/"
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
  "$(names COMPOSE_PROJECT_NAME=t-proj METALGO_CONTAINER_NAME=t-ctr)"
assert_eq "T2 project only -> container keeps default" "t-proj|metalgo-mainnet|t-proj_metalgo_data|metalgo_data" \
  "$(names COMPOSE_PROJECT_NAME=t-proj)"
assert_eq "T2 container only -> project/volume keep default" "metalgo-stack|t-ctr|metalgo-stack_metalgo_data|metalgo_data" \
  "$(names METALGO_CONTAINER_NAME=t-ctr)"
assert_eq "T2 empty values fall back to defaults" "metalgo-stack|metalgo-mainnet|metalgo-stack_metalgo_data|metalgo_data" \
  "$(names METALGO_CONTAINER_NAME= COMPOSE_PROJECT_NAME=)"

echo "T3: a .env beside the compose files (the host layout) is honoured"
printf 'COMPOSE_PROJECT_NAME=t-envproj\nMETALGO_CONTAINER_NAME=t-envctr\n' >"$W/.env"
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
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/docker"
jq -n '[{Name:"/t-ctr", State:{Status:"running"},
         Config:{Labels:{"com.docker.compose.project":"t-proj","com.docker.compose.service":"metalgo"}},
         Mounts:[{Type:"volume",Name:"t-proj_metalgo_data",Destination:"/data"}]}]' >"$TMP/insp.json"
vrun() {
  : >"$TMP/log"
  env -i PATH="$TMP/bin:$PATH" HOME="$HOME" ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} \
    METAL_NETWORK=mainnet METAL_PUBLIC_IP=192.0.2.1 "$@" bash "$W/scripts/check-compose-naming.sh" 2>&1
}
out=$(vrun COMPOSE_PROJECT_NAME=t-proj METALGO_CONTAINER_NAME=t-ctr); rc=$?
assert_eq "T5a aligned env -> exit 0" 0 "$rc"
assert_contains "T5a data MATCH on the resolved volume" "MATCH     data      volume:t-proj_metalgo_data" "$out"
out=$(vrun); rc=$?
assert_eq "T5b default env -> exit 1" 1 "$rc"
assert_eq "T5b three MISMATCH lines" 3 "$(printf '%s\n' "$out" | grep -c '^MISMATCH ')"
bad_calls=$(grep -vE '^(compose .* config( |$)|ps |inspect )' "$TMP/log" || true)
assert_eq "T5 docker saw only config/ps/inspect" "" "$bad_calls"

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
