#!/usr/bin/env bash
# check-compose-naming.sh — READ-ONLY check that this repo's metalgo compose
# resolves to the SAME names as the metalgo container already running on this
# host.
#
# CHAIN: none — no broadcast, no RPC.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (read-only docker queries only).
#
# WHY: the production validator host's metalgo predates this repo and runs
# under a different compose project / container / named volume than the
# repo's defaults. A `docker compose ... up` whose names do not match creates
# a NEW empty /data volume -> new staker keys -> a different NodeID. The fix is
# to set METALGO_COMPOSE_PROJECT / METALGO_CONTAINER_NAME in the host .env to the
# current names (docs/DISASTER_RECOVERY.md, warning on compose naming). This
# script proves the alignment BEFORE any compose up.
#
# What it compares (one MATCH/MISMATCH line each):
#   project    compose `name`                    vs  label com.docker.compose.project
#   container  services.metalgo.container_name   vs  container .Name
#   data       the /data mount: volume -> resolved volume name (volumes.<key>.name),
#              bind -> host path                  vs  the container's /data Mount
#                                                     (volume -> .Name, bind -> .Source)
#   isolation  COMPOSE_PROJECT_NAME must be UNSET (environment and ./.env). The host
#              .env is shared with the Caddy stack (docker-compose.yml, name: site);
#              COMPOSE_PROJECT_NAME beats `name:` in every compose file, so it would
#              rename the Caddy project and its volumes too. Use
#              METALGO_COMPOSE_PROJECT instead.
#
# The running container is found ONLY by label com.docker.compose.service=metalgo
# (all states, `docker ps -a`). 0 or 2+ such containers -> fail closed.
#
# It NEVER creates, starts, stops or removes anything: the only docker
# invocations are `docker compose ... config`, `docker ps` and `docker inspect`,
# enforced by an allowlist wrapper (dk) that refuses anything else.
#
# Run on the validator host, from anywhere (it cd's to the repo root so the
# host .env next to the compose files is picked up, as compose itself would):
#   bash scripts/check-compose-naming.sh
#
# Exit codes:
#   0  all four items MATCH
#   1  at least one MISMATCH
#   2  could not decide (docker/jq missing, compose config failed, 0 or 2+
#      metalgo containers, unparsable output) — fail closed, never a pass

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || { echo "UNDECIDED: cannot cd to repo root" >&2; exit 2; }

BASE_FILE="docker-compose.metalgo.yml"
PROD_FILE="docker-compose.metalgo.prod.yml"
SERVICE_LABEL="com.docker.compose.service=metalgo"

die() { echo "UNDECIDED: $*" >&2; echo "RESULT: UNDECIDED (fail closed; nothing was changed)"; exit 2; }

# Allowlist wrapper: the only docker calls this script may make.
dk() {
  case "${1:-}" in
    ps|inspect) docker "$@" ;;
    compose)
      # only `docker compose -f X -f Y config ...`
      local a seen_config=0
      for a in "$@"; do [ "$a" = "config" ] && seen_config=1; done
      [ "$seen_config" -eq 1 ] || { echo "REFUSED: docker compose without config" >&2; return 97; }
      for a in "$@"; do
        case "$a" in
          up|create|run|start|stop|restart|rm|down|kill|pause|unpause|pull|build|exec|cp|scale)
            echo "REFUSED: docker compose $a" >&2; return 97 ;;
        esac
      done
      docker "$@" ;;
    *) echo "REFUSED: docker ${1:-<none>}" >&2; return 97 ;;
  esac
}

command -v docker >/dev/null 2>&1 || die "docker not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
[ -f "$BASE_FILE" ] && [ -f "$PROD_FILE" ] || die "compose files not found in $REPO_ROOT"

# ---- 1. what the repo's compose resolves to (with the host .env) ----
cfg=$(dk compose -f "$BASE_FILE" -f "$PROD_FILE" config --format json) \
  || die "docker compose config failed (is the host .env complete?)"

want_project=$(printf '%s' "$cfg" | jq -er '.name // empty') || die "compose config has no project name"
want_container=$(printf '%s' "$cfg" | jq -er '.services.metalgo.container_name // empty') \
  || die "compose config has no services.metalgo.container_name"
want_data=""
mtype=$(printf '%s' "$cfg" | jq -er '[.services.metalgo.volumes[]? | select(.target == "/data")] | if length == 1 then .[0].type else error("n") end') \
  || die "compose config: expected exactly one /data mount for metalgo"
msrc=$(printf '%s' "$cfg" | jq -er '[.services.metalgo.volumes[]? | select(.target == "/data")][0].source') \
  || die "compose config: /data mount has no source"
case "$mtype" in
  volume)
    vname=$(printf '%s' "$cfg" | jq -er --arg k "$msrc" '.volumes[$k].name // empty') \
      || die "compose config: volume key '$msrc' has no resolved name"
    want_data="volume:$vname" ;;
  bind) want_data="bind:$msrc" ;;
  *) die "compose config: unsupported /data mount type '$mtype'" ;;
esac

# ---- 2. the metalgo container actually on this host ----
ids=$(dk ps -a --no-trunc -q --filter "label=$SERVICE_LABEL") || die "docker ps failed"
n=$(printf '%s\n' "$ids" | grep -c . || true)
if [ "$n" -ne 1 ]; then
  die "expected exactly 1 container with label $SERVICE_LABEL, found $n"
fi
id=$(printf '%s\n' "$ids" | grep . | head -n1)

info=$(dk inspect "$id") || die "docker inspect failed"
have_container=$(printf '%s' "$info" | jq -er '.[0].Name | ltrimstr("/")') || die "inspect: no Name"
have_project=$(printf '%s' "$info" | jq -er '.[0].Config.Labels["com.docker.compose.project"] // empty') \
  || die "inspect: container has no compose project label"
have_data=$(printf '%s' "$info" | jq -er '
  [.[0].Mounts[]? | select(.Destination == "/data")]
  | if length != 1 then error("n")
    elif .[0].Type == "volume" then "volume:" + .[0].Name
    elif .[0].Type == "bind" then "bind:" + .[0].Source
    else error("type") end') || die "inspect: expected exactly one volume/bind mount at /data"
have_state=$(printf '%s' "$info" | jq -r '.[0].State.Status // "unknown"')

# ---- 3. compare ----
fails=0
item() {
  if [ "$2" = "$3" ]; then
    printf 'MATCH     %-9s %s\n' "$1" "$2"
  else
    printf 'MISMATCH  %-9s compose=%s  running=%s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}
item project   "$want_project"   "$have_project"
item container "$want_container" "$have_container"
item data      "$want_data"      "$have_data"
cpn_src=""
[ -n "${COMPOSE_PROJECT_NAME:-}" ] && cpn_src="environment"
if [ -f .env ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?COMPOSE_PROJECT_NAME[[:space:]]*=' .env; then
  cpn_src="${cpn_src:+$cpn_src+}.env"
fi
if [ -z "$cpn_src" ]; then
  printf 'MATCH     %-9s %s\n' isolation "COMPOSE_PROJECT_NAME unset"
else
  printf 'MISMATCH  %-9s COMPOSE_PROJECT_NAME is set (%s): it also renames the Caddy stack; use METALGO_COMPOSE_PROJECT\n' isolation "$cpn_src"
  fails=$((fails + 1))
fi
echo "INFO      state     $have_state (informational; not part of the verdict)"

if [ "$fails" -eq 0 ]; then
  echo "RESULT: MATCH (compose resolves to the running metalgo's names; nothing was changed)"
  exit 0
fi
echo "RESULT: MISMATCH ($fails item(s)) — do NOT (re)create metalgo via compose on this host."
echo "        Set METALGO_COMPOSE_PROJECT / METALGO_CONTAINER_NAME in the host .env and re-run."
exit 1
