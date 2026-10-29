#!/usr/bin/env bash
# tests/compose-naming/test-check-compose-naming.sh
#
# scripts/check-compose-naming.sh — the read-only verifier that the repo's
# metalgo compose resolves to the names of the metalgo container already on
# the host. docker is fully stubbed: `compose ... config` prints a fixture,
# `ps` prints fixture ids, `inspect` prints a fixture. Every docker invocation
# is logged, so the suite can prove the verifier never asks docker to create,
# start, stop or remove anything.
#
# Also covers the adopt check (METALGO_DATA_VOLUME -> docker-compose.metalgo.adopt.yml
# in the -f list, /data volume external and present) and the drift items
# (image / command / memory / nanocpus / restart vs the running container).
# Section M re-runs key cases against mutants of the verifier (adopt file left
# out of the -f list, external not required, command not compared, memory not
# compared) and asserts each mutant gives the wrong verdict — i.e. the fixtures
# can tell a correct verifier from a broken one.
#
# All names are synthetic (t-*) — never the production names.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe (no real docker).

# shellcheck disable=SC2015  # A&&ok||bad reporters
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${COMPOSE_NAMING_SCRIPT_UNDER_TEST:-$REPO/scripts/check-compose-naming.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null 2>&1 || {
  if [ -n "${CI:-}" ]; then echo "FAIL: jq not available (CI must run this suite)"; exit 1; fi
  echo "SKIP: jq not available"; exit 0; }

PASS=0; FAIL=0; FAILURES=()
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1 ($2)"); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected='$2' actual='$3'"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing '$2' in '$3'" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "unexpected '$2' in '$3'" ;; *) ok "$1" ;; esac; }

# The verifier cd's to <its dir>/.. and requires the compose files there, so
# it runs from a throwaway repo layout (this is also how a mutant is tested).
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/scripts" "$TMP/bin" "$TMP/fx"
cp "$SCRIPT" "$FAKE_REPO/scripts/check-compose-naming.sh"
cp "$REPO/docker-compose.metalgo.yml" "$REPO/docker-compose.metalgo.prod.yml" "$REPO/docker-compose.metalgo.adopt.yml" "$FAKE_REPO/"

# ---- docker stub ----
cat >"$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1" in
  compose)
    for a in "$@"; do [ "$a" = config ] && { cat "$STUB_CFG"; exit "${STUB_CFG_RC:-0}"; }; done
    exit 0 ;;
  ps) [ -s "$STUB_IDS" ] && cat "$STUB_IDS"; exit 0 ;;
  inspect) cat "$STUB_INSPECT"; exit 0 ;;
  volume) [ "$2" = inspect ] && { echo '[{}]'; exit "${STUB_VOL_RC:-0}"; }; exit 0 ;;
  *) exit 0 ;;  # a mutating call "succeeds" silently — only the log catches it
esac
STUB
chmod +x "$TMP/bin/docker"

# Runtime settings shared by cfg and insp (compose renders mem_limit as a
# byte string and cpus as a number; docker inspect has bytes / nano-CPUs).
T_IMAGE="t-registry/metalgo:t-tag"
T_CMD='["/metalgo/build/metalgo","--network-id=t-net","--public-ip=192.0.2.1","--data-dir=/data"]'
# cfg <project> <container> <mount-type> <source> [volume-name]  (EXT=true -> external volume)
cfg() {
  local base='{image:$img, command:($cmd|fromjson), mem_limit:"17179869184", cpus:8, restart:"unless-stopped"}'
  if [ "$3" = volume ]; then
    jq -n --arg p "$1" --arg c "$2" --arg s "$4" --arg v "$5" --arg img "$T_IMAGE" --arg cmd "$T_CMD" --arg ext "${EXT:-}" \
      "{name:\$p, services:{metalgo:($base + {container_name:\$c, volumes:[{type:\"volume\",source:\$s,target:\"/data\"}]})},
        volumes:{(\$s):({name:\$v} + (if \$ext == \"true\" then {external:true} else {} end))}}"
  else
    jq -n --arg p "$1" --arg c "$2" --arg s "$4" --arg img "$T_IMAGE" --arg cmd "$T_CMD" \
      "{name:\$p, services:{metalgo:($base + {container_name:\$c, volumes:[{type:\"bind\",source:\$s,target:\"/data\"}]})}}"
  fi
}
# insp <name> <project> <mount-type> <name-or-source>
insp() {
  jq -n --arg n "/$1" --arg p "$2" --arg t "$3" --arg x "$4" --arg img "$T_IMAGE" --arg cmd "$T_CMD" \
    '[{Name:$n, State:{Status:"running"},
       Config:{Image:$img, Cmd:($cmd|fromjson), Labels:{"com.docker.compose.project":$p,"com.docker.compose.service":"metalgo"}},
       HostConfig:{Memory:17179869184, NanoCpus:8000000000, RestartPolicy:{Name:"unless-stopped",MaximumRetryCount:0}},
       Mounts:[{Type:"bind",Source:"/etc/unrelated",Destination:"/etc/x"},
               (if $t == "volume" then {Type:"volume",Name:$x,Source:"/var/lib/docker/volumes/\($x)/_data",Destination:"/data"}
                else {Type:"bind",Source:$x,Destination:"/data"} end)]}]'
}

OUT=""; RC=0
run() {
  : >"$TMP/log"
  OUT=$(env -u COMPOSE_PROJECT_NAME -u METALGO_DATA_VOLUME PATH="$TMP/bin:$PATH" ${CPN:+COMPOSE_PROJECT_NAME="$CPN"} \
        ${MDV:+METALGO_DATA_VOLUME="$MDV"} STUB_LOG="$TMP/log" STUB_CFG="$TMP/fx/cfg" STUB_IDS="$TMP/fx/ids" \
        STUB_INSPECT="$TMP/fx/insp" STUB_CFG_RC="${CFG_RC:-0}" STUB_VOL_RC="${VOL_RC:-0}" \
        bash "$FAKE_REPO/scripts/check-compose-naming.sh" 2>&1)
  RC=$?
}
# After every run: only `compose ... config`, `ps`, `inspect` reached docker.
assert_read_only() {
  local line bad_lines=""
  while IFS= read -r line; do
    case "$line" in
      "compose "*" config"*|"ps "*|"inspect "*|"volume inspect "*) : ;;
      *) bad_lines="${bad_lines}[$line]" ;;
    esac
    for w in $line; do
      case "$w" in up|create|run|start|stop|restart|rm|down|kill|pull|exec) bad_lines="${bad_lines}[$w in: $line]" ;; esac
    done
  done <"$TMP/log"
  assert_eq "$1: docker saw only config/ps/inspect/volume inspect" "" "$bad_lines"
}

echo "T1: all three match (named volume)"
cfg t-proj t-ctr volume metalgo_data t-proj_metalgo_data >"$TMP/fx/cfg"
echo cid-1 >"$TMP/fx/ids"; insp t-ctr t-proj volume t-proj_metalgo_data >"$TMP/fx/insp"
run
assert_eq "T1 exit 0" 0 "$RC"
assert_eq "T1 nine MATCH lines (4 naming + 5 drift)" 9 "$(printf '%s\n' "$OUT" | grep -c '^MATCH ')"
assert_contains "T1 adopt off is INFO only" "INFO      adopt     off (METALGO_DATA_VOLUME unset)" "$OUT"
assert_not_contains "T1 no adopt file without METALGO_DATA_VOLUME" "adopt.yml" "$(cat "$TMP/log")"
assert_not_contains "T1 volume inspect not needed" "volume inspect" "$(cat "$TMP/log")"
assert_contains "T1 day-of command (2 files, dry-run, stdin null)" \
  "INFO      files     docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml --dry-run up -d metalgo </dev/null" "$OUT"
assert_contains "T1 RESULT MATCH" "RESULT: MATCH" "$OUT"
assert_not_contains "T1 no MISMATCH" "MISMATCH" "$OUT"
assert_contains "T1 ps by service label, all states" "ps -a --no-trunc -q --filter label=com.docker.compose.service=metalgo" "$(cat "$TMP/log")"
assert_contains "T1 compose uses both files" "compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml config --format json" "$(cat "$TMP/log")"
assert_read_only T1

echo "T2: project differs"
cfg t-new t-ctr volume metalgo_data t-proj_metalgo_data >"$TMP/fx/cfg"
run
assert_eq "T2 exit 1" 1 "$RC"
assert_contains "T2 MISMATCH project" "MISMATCH  project" "$OUT"
assert_contains "T2 container still MATCH" "MATCH     container" "$OUT"
assert_read_only T2

echo "T3: container name differs"
cfg t-proj t-other volume metalgo_data t-proj_metalgo_data >"$TMP/fx/cfg"
run
assert_eq "T3 exit 1" 1 "$RC"
assert_contains "T3 MISMATCH container" "MISMATCH  container" "$OUT"
assert_read_only T3

echo "T4: /data volume differs (the NodeID-changing case)"
cfg t-proj t-ctr volume metalgo_data t-new_metalgo_data >"$TMP/fx/cfg"
run
assert_eq "T4 exit 1" 1 "$RC"
assert_contains "T4 MISMATCH data" "MISMATCH  data" "$OUT"
assert_contains "T4 RESULT MISMATCH" "RESULT: MISMATCH (1 item(s))" "$OUT"

echo "T5: bind mounts"
cfg t-proj t-ctr bind /srv/t-data >"$TMP/fx/cfg"; insp t-ctr t-proj bind /srv/t-data >"$TMP/fx/insp"
run
assert_eq "T5a same bind path -> exit 0" 0 "$RC"
insp t-ctr t-proj volume t-proj_metalgo_data >"$TMP/fx/insp"
run
assert_eq "T5b compose bind vs running volume -> exit 1" 1 "$RC"
assert_contains "T5b MISMATCH data" "MISMATCH  data" "$OUT"
cfg t-proj t-ctr volume metalgo_data t-proj_metalgo_data >"$TMP/fx/cfg"
insp t-ctr t-proj bind /var/lib/docker/volumes/t-proj_metalgo_data/_data >"$TMP/fx/insp"
run
assert_eq "T5c compose volume vs running bind of same path -> exit 1" 1 "$RC"

echo "T6: no metalgo container -> fail closed"
cfg t-proj t-ctr volume metalgo_data t-proj_metalgo_data >"$TMP/fx/cfg"
insp t-ctr t-proj volume t-proj_metalgo_data >"$TMP/fx/insp"
: >"$TMP/fx/ids"
run
assert_eq "T6 exit 2" 2 "$RC"
assert_contains "T6 says found 0" "found 0" "$OUT"
assert_not_contains "T6 no MATCH verdict" "RESULT: MATCH" "$OUT"
assert_not_contains "T6 inspect never reached" "inspect" "$(cat "$TMP/log")"
assert_read_only T6

echo "T7: two metalgo containers -> fail closed"
printf 'cid-1\ncid-2\n' >"$TMP/fx/ids"
run
assert_eq "T7 exit 2" 2 "$RC"
assert_contains "T7 says found 2" "found 2" "$OUT"
assert_not_contains "T7 no MATCH verdict" "RESULT: MATCH" "$OUT"
assert_read_only T7

echo "T8: compose config exits non-zero (e.g. incomplete .env) -> fail closed"
# The stub still prints a valid, all-matching config on stdout: the exit code
# alone must decide, so a verifier that ignored it would reach MATCH here.
echo cid-1 >"$TMP/fx/ids"
CFG_RC=1 run
assert_eq "T8 exit 2" 2 "$RC"
assert_not_contains "T8 ps never reached" "ps " "$(cat "$TMP/log")"

echo "T9: running container has no /data mount -> fail closed"
jq '.[0].Mounts |= map(select(.Destination != "/data"))' "$TMP/fx/insp" >"$TMP/fx/insp2" && mv "$TMP/fx/insp2" "$TMP/fx/insp"
run
assert_eq "T9 exit 2" 2 "$RC"

echo "T10: container without compose project label -> fail closed"
insp t-ctr t-proj volume t-proj_metalgo_data | jq '.[0].Config.Labels |= del(.["com.docker.compose.project"])' >"$TMP/fx/insp"
run
assert_eq "T10 exit 2" 2 "$RC"

echo "T12: COMPOSE_PROJECT_NAME set -> isolation MISMATCH even when names align"
cfg t-proj t-ctr volume metalgo_data t-proj_metalgo_data >"$TMP/fx/cfg"
echo cid-1 >"$TMP/fx/ids"; insp t-ctr t-proj volume t-proj_metalgo_data >"$TMP/fx/insp"
CPN=t-proj run
assert_eq "T12a in environment -> exit 1" 1 "$RC"
assert_contains "T12a isolation MISMATCH names the source" "MISMATCH  isolation COMPOSE_PROJECT_NAME is set (environment)" "$OUT"
printf 'METAL_NETWORK=mainnet\nCOMPOSE_PROJECT_NAME=t-proj\n' >"$FAKE_REPO/.env"
run
assert_eq "T12b in ./.env -> exit 1" 1 "$RC"
assert_contains "T12b isolation MISMATCH (.env)" "COMPOSE_PROJECT_NAME is set (.env)" "$OUT"
printf 'export COMPOSE_PROJECT_NAME = t-proj\n' >"$FAKE_REPO/.env"
run
assert_eq "T12c 'export X = y' form in ./.env -> exit 1" 1 "$RC"
printf '# COMPOSE_PROJECT_NAME=t-proj\nMETALGO_COMPOSE_PROJECT=t-proj\n' >"$FAKE_REPO/.env"
run
assert_eq "T12d commented-out line is not a hit -> exit 0" 0 "$RC"
rm -f "$FAKE_REPO/.env"


echo "T13: adopt (METALGO_DATA_VOLUME) — the override joins the -f list and must resolve external"
cfg t-proj t-ctr volume metalgo_data t-old_data >"$TMP/fx/cfg.ext0"
EXT=true cfg t-proj t-ctr volume metalgo_data t-old_data >"$TMP/fx/cfg"
echo cid-1 >"$TMP/fx/ids"; insp t-ctr t-proj volume t-old_data >"$TMP/fx/insp"
MDV=t-old_data run
assert_eq "T13a env: exit 0" 0 "$RC"
assert_contains "T13a adopt MATCH" "MATCH     adopt     external volume t-old_data" "$OUT"
assert_contains "T13a compose got the adopt override" \
  "compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml -f docker-compose.metalgo.adopt.yml config --format json" "$(cat "$TMP/log")"
assert_contains "T13a volume existence checked read-only" "volume inspect t-old_data" "$(cat "$TMP/log")"
assert_contains "T13a day-of command has the 3 files" \
  "docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml -f docker-compose.metalgo.adopt.yml --dry-run up -d metalgo </dev/null" "$OUT"
assert_read_only T13a
printf 'METAL_NETWORK=t-net\nMETALGO_DATA_VOLUME=t-old_data\n' >"$FAKE_REPO/.env"
run
assert_eq "T13b ./.env form: exit 0" 0 "$RC"
assert_contains "T13b compose got the adopt override" "-f docker-compose.metalgo.adopt.yml config" "$(cat "$TMP/log")"
printf 'export METALGO_DATA_VOLUME = t-old_data\n' >"$FAKE_REPO/.env"
run
assert_contains "T13c 'export X = y' form also adopts" "-f docker-compose.metalgo.adopt.yml config" "$(cat "$TMP/log")"
printf '# METALGO_DATA_VOLUME=t-old_data\nMETALGO_DATA_VOLUME=\n' >"$FAKE_REPO/.env"
run
assert_not_contains "T13d commented-out / empty value does not adopt" "adopt.yml" "$(cat "$TMP/log")"
rm -f "$FAKE_REPO/.env"
cp "$TMP/fx/cfg.ext0" "$TMP/fx/cfg"
MDV=t-old_data run
assert_eq "T13e set but /data not external -> exit 1" 1 "$RC"
assert_contains "T13e adopt MISMATCH (not external)" "does not resolve external: true" "$OUT"
EXT=true cfg t-proj t-ctr volume metalgo_data t-old_data >"$TMP/fx/cfg"
MDV=t-old_data VOL_RC=1 run
assert_eq "T13f external volume missing -> exit 1" 1 "$RC"
assert_contains "T13f adopt MISMATCH (missing)" "does not exist on this host" "$OUT"
cfg t-proj t-ctr bind /srv/t-data >"$TMP/fx/cfg"; insp t-ctr t-proj bind /srv/t-data >"$TMP/fx/insp"
MDV=t-old_data run
assert_eq "T13g adopt + bind /data -> exit 1" 1 "$RC"
assert_contains "T13g adopt MISMATCH (bind)" "resolves to a bind mount" "$OUT"
mv "$FAKE_REPO/docker-compose.metalgo.adopt.yml" "$TMP/adopt.bak"
MDV=t-old_data run
assert_eq "T13h adopt requested but override file missing -> exit 2" 2 "$RC"
mv "$TMP/adopt.bak" "$FAKE_REPO/docker-compose.metalgo.adopt.yml"

echo "T14: drift — each runtime setting differing from compose is a MISMATCH"
cfg t-proj t-ctr volume metalgo_data t-proj_metalgo_data >"$TMP/fx/cfg"
insp t-ctr t-proj volume t-proj_metalgo_data >"$TMP/fx/insp.good"
drift() {  # drift <label> <item> <jq filter applied to the inspect fixture>
  jq "$3" "$TMP/fx/insp.good" >"$TMP/fx/insp"
  run
  assert_eq "T14 $1 -> exit 1" 1 "$RC"
  assert_contains "T14 $1 -> MISMATCH $2" "MISMATCH  $2" "$OUT"
  assert_eq "T14 $1 -> exactly one MISMATCH" 1 "$(printf '%s\n' "$OUT" | grep -c '^MISMATCH ')"
}
drift "image tag"              image    '.[0].Config.Image = "t-registry/metalgo:other"'
drift "public ip"              command  '.[0].Config.Cmd[2] = "--public-ip=192.0.2.2"'
drift "extra flag"             command  '.[0].Config.Cmd += ["--t-extra"]'
drift "flag order"             command  '.[0].Config.Cmd |= [.[0], .[2], .[1], .[3]]'
drift "missing flag"           command  '.[0].Config.Cmd |= .[0:3]'
drift "memory"                 memory   '.[0].HostConfig.Memory = 8589934592'
drift "no memory limit"        memory   '.[0].HostConfig.Memory = 0'
drift "cpus"                   nanocpus '.[0].HostConfig.NanoCpus = 4000000000'
drift "restart policy"         restart  '.[0].HostConfig.RestartPolicy.Name = "always"'
drift "no restart policy"      restart  '.[0].HostConfig.RestartPolicy.Name = ""'
cp "$TMP/fx/insp.good" "$TMP/fx/insp"
run
assert_eq "T14 back to the good fixture -> exit 0" 0 "$RC"
jq '.services.metalgo |= del(.mem_limit, .cpus, .restart)' "$TMP/fx/cfg" >"$TMP/fx/cfg.unset"
jq '.[0].HostConfig = {Memory:0, NanoCpus:0, RestartPolicy:{Name:""}}' "$TMP/fx/insp.good" >"$TMP/fx/insp"
cp "$TMP/fx/cfg" "$TMP/fx/cfg.good"; cp "$TMP/fx/cfg.unset" "$TMP/fx/cfg"
run
assert_eq "T14 unset on both sides (no limit, no restart) -> exit 0" 0 "$RC"
cp "$TMP/fx/cfg.good" "$TMP/fx/cfg"; cp "$TMP/fx/insp.good" "$TMP/fx/insp"

echo "T11: static — the script text names no mutating docker subcommand outside its refusal list"
body=$(grep -v '^\s*#' "$SCRIPT" | grep -v 'REFUSED\|up|create|run|start')
for w in "compose up" "compose create" "compose run" "compose start" "compose stop" "compose rm" "compose down" \
         "docker start" "docker stop" "docker rm" "docker run" "docker create" "dk start" "dk stop" "dk rm" "dk run" "dk create" \
         "volume rm" "volume create" "volume prune" "dk volume rm"; do
  case "$body" in *"$w"*) bad "T11 no '$w'" "found in script body" ;; *) ok "T11 no '$w'" ;; esac
done

echo "M: break-the-property — mutants of the verifier must give the wrong verdict here"
GOOD_SCRIPT="$FAKE_REPO/scripts/check-compose-naming.sh"
cp "$GOOD_SCRIPT" "$TMP/good.sh"
mutant() {  # mutant <label> <sed expr>  -> installs the mutant, fails loudly if sed did not apply
  sed "$2" "$TMP/good.sh" >"$GOOD_SCRIPT"
  if cmp -s "$TMP/good.sh" "$GOOD_SCRIPT"; then bad "M $1: mutation applied" "sed matched nothing"; return 1; fi
}
EXT=true cfg t-proj t-ctr volume metalgo_data t-old_data >"$TMP/fx/cfg"
insp t-ctr t-proj volume t-old_data >"$TMP/fx/insp"
# M1: the adopt override is never added to the -f list -> the 2-file list must be seen
if mutant "adopt file dropped from -f" 's|  files+=(-f "\$ADOPT_FILE")|  :|'; then
  MDV=t-old_data run
  assert_not_contains "M1 mutant (adopt dropped) is caught: no 3-file compose call" \
    "-f docker-compose.metalgo.adopt.yml config" "$(cat "$TMP/log")"
fi
# M2: external not required -> T13e's fixture must then (wrongly) pass
cp "$TMP/fx/cfg.ext0" "$TMP/fx/cfg"
if mutant "external not required" 's|elif \[ "\$ext" != true \]; then|elif false; then|'; then
  MDV=t-old_data run
  assert_eq "M2 mutant (external unchecked) flips T13e to exit 0 (so T13e has teeth)" 0 "$RC"
fi
# M3/M4: command / memory not compared -> T14's fixtures must then (wrongly) pass
cfg t-proj t-ctr volume metalgo_data t-proj_metalgo_data >"$TMP/fx/cfg"
jq '.[0].Config.Cmd[2] = "--public-ip=192.0.2.2"' "$TMP/fx/insp.good" >"$TMP/fx/insp"
if mutant "command not compared" 's|^item command  "\$want_cmd"     "\$have_cmd"|item command  x x|'; then
  run
  assert_eq "M3 mutant (command unchecked) flips the public-ip drift to exit 0" 0 "$RC"
fi
jq '.[0].HostConfig.Memory = 8589934592' "$TMP/fx/insp.good" >"$TMP/fx/insp"
if mutant "memory not compared" 's|^item memory   "\$want_mem"     "\$have_mem"|item memory x x|'; then
  run
  assert_eq "M4 mutant (memory unchecked) flips the memory drift to exit 0" 0 "$RC"
fi
cp "$TMP/good.sh" "$GOOD_SCRIPT"

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
