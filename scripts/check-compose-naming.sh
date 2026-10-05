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
#   adopt      when METALGO_DATA_VOLUME is set (environment or ./.env), the
#              compose file list includes docker-compose.metalgo.adopt.yml and the
#              /data volume must resolve `external: true` to that name and exist
#              (`docker volume inspect`). An external volume is outside compose's
#              management: no "Recreate (data will be lost)?" prompt on a
#              config-hash mismatch, never deleted by `down -v` (rehearsed
#              2026-10-05). Unset -> an INFO line only (a fresh host's volume is
#              created by this compose and needs no adoption).
#   drift      the running container vs what `up` would create from the same files:
#              image (.Config.Image), command (.Config.Cmd, exact array), memory
#              (.HostConfig.Memory bytes), nanocpus (.HostConfig.NanoCpus),
#              restart (.HostConfig.RestartPolicy.Name). The /data mount name is
#              the `data` item above. Any difference is a MISMATCH: recreating
#              would silently change what the validator runs with (e.g. a .env
#              whose METAL_PUBLIC_IP / METAL_NETWORK / METAL_MEM_LIMIT does not
#              reproduce today's container).
#
# The running container is found ONLY by label com.docker.compose.service=metalgo
# (all states, `docker ps -a`). 0 or 2+ such containers -> fail closed.
#
# It NEVER creates, starts, stops or removes anything: the only docker
# invocations are `docker compose ... config`, `docker ps`, `docker inspect` and
# `docker volume inspect`, enforced by an allowlist wrapper (dk) that refuses
# anything else.
#
# Run on the validator host, from anywhere (it cd's to the repo root so the
# host .env next to the compose files is picked up, as compose itself would):
#   bash scripts/check-compose-naming.sh
#
# The day-of recreate on a host that adopts its existing /data volume is then
# (first a dry run, then for real; stdin from /dev/null, NEVER -y / --yes):
#   docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml \
#     -f docker-compose.metalgo.adopt.yml --dry-run up -d metalgo </dev/null
#   docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml \
#     -f docker-compose.metalgo.adopt.yml up -d metalgo </dev/null
# The script prints the exact command for this host on its `INFO files` line.
#
# Exit codes:
#   0  every item MATCH
#   1  at least one MISMATCH
#   2  could not decide (docker/jq missing, compose config failed, 0 or 2+
#      metalgo containers, unparsable output) — fail closed, never a pass

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || { echo "UNDECIDED: cannot cd to repo root" >&2; exit 2; }

BASE_FILE="docker-compose.metalgo.yml"
PROD_FILE="docker-compose.metalgo.prod.yml"
ADOPT_FILE="docker-compose.metalgo.adopt.yml"
SERVICE_LABEL="com.docker.compose.service=metalgo"

die() { echo "UNDECIDED: $*" >&2; echo "RESULT: UNDECIDED (fail closed; nothing was changed)"; exit 2; }

# Allowlist wrapper: the only docker calls this script may make.
dk() {
  case "${1:-}" in
    ps|inspect) docker "$@" ;;
    volume)
      [ "${2:-}" = inspect ] || { echo "REFUSED: docker volume ${2:-<none>}" >&2; return 97; }
      docker "$@" ;;
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

# ---- 0. which compose files (the same rule as scripts/vps-bootstrap.sh) ----
# METALGO_DATA_VOLUME set (non-empty, in the environment or ./.env) -> this host
# adopts an existing /data volume -> the adopt override joins the -f list.
adopt_src=""
[ -n "${METALGO_DATA_VOLUME:-}" ] && adopt_src="environment"
if [ -f .env ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?METALGO_DATA_VOLUME[[:space:]]*=[[:space:]]*[^[:space:]#]' .env; then
  adopt_src="${adopt_src:+$adopt_src+}.env"
fi
files=(-f "$BASE_FILE" -f "$PROD_FILE")
if [ -n "$adopt_src" ]; then
  [ -f "$ADOPT_FILE" ] || die "METALGO_DATA_VOLUME is set ($adopt_src) but $ADOPT_FILE is missing"
  files+=(-f "$ADOPT_FILE")
fi

# ---- 1. what the repo's compose resolves to (with the host .env) ----
cfg=$(dk compose "${files[@]}" config --format json) \
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

# drift: what `up` would create vs the running container (normalised so that
# "unset" compares equal on both sides: no limit = 0, no restart policy = "no")
want_image=$(printf '%s' "$cfg" | jq -r '.services.metalgo.image // "<unset>"')
want_cmd=$(printf '%s' "$cfg" | jq -c '.services.metalgo.command // null')
want_mem=$(printf '%s' "$cfg" | jq -r '(.services.metalgo.mem_limit // 0) | tonumber') \
  || die "compose config: mem_limit is not a number"
want_cpu=$(printf '%s' "$cfg" | jq -r '(.services.metalgo.cpus // 0) | tonumber * 1000000000 | round') \
  || die "compose config: cpus is not a number"
want_restart=$(printf '%s' "$cfg" | jq -r '(.services.metalgo.restart // "") | if . == "" then "no" else . end')
have_image=$(printf '%s' "$info" | jq -r '.[0].Config.Image // "<unset>"')
have_cmd=$(printf '%s' "$info" | jq -c '.[0].Config.Cmd // null')
have_mem=$(printf '%s' "$info" | jq -r '.[0].HostConfig.Memory // 0') || die "inspect: unreadable HostConfig.Memory"
have_cpu=$(printf '%s' "$info" | jq -r '.[0].HostConfig.NanoCpus // 0') || die "inspect: unreadable HostConfig.NanoCpus"
have_restart=$(printf '%s' "$info" | jq -r '(.[0].HostConfig.RestartPolicy.Name // "") | if . == "" then "no" else . end')

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

# adopt
if [ -n "$adopt_src" ]; then
  ext=$(printf '%s' "$cfg" | jq -r --arg k "$msrc" '.volumes[$k].external // false')
  if [ "$mtype" != volume ]; then
    printf 'MISMATCH  %-9s METALGO_DATA_VOLUME is set but /data resolves to a bind mount (METALGO_DATA_PATH?): the adopted volume would not be used\n' adopt
    fails=$((fails + 1))
  elif [ "$ext" != true ]; then
    printf 'MISMATCH  %-9s METALGO_DATA_VOLUME is set (%s) but /data volume %s does not resolve external: true (%s)\n' adopt "$adopt_src" "$vname" "$ADOPT_FILE"
    fails=$((fails + 1))
  elif ! dk volume inspect "$vname" >/dev/null 2>&1; then
    printf 'MISMATCH  %-9s external volume %s does not exist on this host (an up would fail: external volume not found)\n' adopt "$vname"
    fails=$((fails + 1))
  else
    printf 'MATCH     %-9s %s\n' adopt "external volume $vname via $ADOPT_FILE (compose will not create, recreate or delete it)"
  fi
else
  printf 'INFO      %-9s %s\n' adopt "off (METALGO_DATA_VOLUME unset): /data is a compose-managed volume. On a host whose volume predates this repo, set METALGO_DATA_VOLUME (docs/DISASTER_RECOVERY.md)"
fi

# drift
item image    "$want_image"   "$have_image"
item command  "$want_cmd"     "$have_cmd"
item memory   "$want_mem"     "$have_mem"
item nanocpus "$want_cpu"     "$have_cpu"
item restart  "$want_restart" "$have_restart"

echo "INFO      state     $have_state (informational; not part of the verdict)"
echo "INFO      files     docker compose ${files[*]} --dry-run up -d metalgo </dev/null   (then the same without --dry-run; never -y)"

if [ "$fails" -eq 0 ]; then
  echo "RESULT: MATCH (compose resolves to the running metalgo's names and settings; nothing was changed)"
  exit 0
fi
echo "RESULT: MISMATCH ($fails item(s)) — do NOT (re)create metalgo via compose on this host."
echo "        Fix the host .env (METALGO_COMPOSE_PROJECT / METALGO_CONTAINER_NAME / METALGO_DATA_VOLUME,"
echo "        and METAL_* so the command / limits reproduce the running container) and re-run."
exit 1
