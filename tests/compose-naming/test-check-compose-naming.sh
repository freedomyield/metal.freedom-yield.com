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
cp "$REPO/docker-compose.metalgo.yml" "$REPO/docker-compose.metalgo.prod.yml" "$FAKE_REPO/"

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
  *) exit 0 ;;  # a mutating call "succeeds" silently — only the log catches it
esac
STUB
chmod +x "$TMP/bin/docker"

# cfg <project> <container> <mount-type> <source> [volume-name]
cfg() {
  if [ "$3" = volume ]; then
    jq -n --arg p "$1" --arg c "$2" --arg s "$4" --arg v "$5" \
      '{name:$p, services:{metalgo:{container_name:$c, volumes:[{type:"volume",source:$s,target:"/data"}]}}, volumes:{($s):{name:$v}}}'
  else
    jq -n --arg p "$1" --arg c "$2" --arg s "$4" \
      '{name:$p, services:{metalgo:{container_name:$c, volumes:[{type:"bind",source:$s,target:"/data"}]}}}'
  fi
}
# insp <name> <project> <mount-type> <name-or-source>
insp() {
  jq -n --arg n "/$1" --arg p "$2" --arg t "$3" --arg x "$4" \
    '[{Name:$n, State:{Status:"running"}, Config:{Labels:{"com.docker.compose.project":$p,"com.docker.compose.service":"metalgo"}},
       Mounts:[{Type:"bind",Source:"/etc/unrelated",Destination:"/etc/x"},
               (if $t == "volume" then {Type:"volume",Name:$x,Source:"/var/lib/docker/volumes/\($x)/_data",Destination:"/data"}
                else {Type:"bind",Source:$x,Destination:"/data"} end)]}]'
}

OUT=""; RC=0
run() {
  : >"$TMP/log"
  OUT=$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" STUB_CFG="$TMP/fx/cfg" STUB_IDS="$TMP/fx/ids" \
        STUB_INSPECT="$TMP/fx/insp" STUB_CFG_RC="${CFG_RC:-0}" \
        bash "$FAKE_REPO/scripts/check-compose-naming.sh" 2>&1)
  RC=$?
}
# After every run: only `compose ... config`, `ps`, `inspect` reached docker.
assert_read_only() {
  local line bad_lines=""
  while IFS= read -r line; do
    case "$line" in
      "compose "*" config"*|"ps "*|"inspect "*) : ;;
      *) bad_lines="${bad_lines}[$line]" ;;
    esac
    for w in $line; do
      case "$w" in up|create|run|start|stop|restart|rm|down|kill|pull|exec) bad_lines="${bad_lines}[$w in: $line]" ;; esac
    done
  done <"$TMP/log"
  assert_eq "$1: docker saw only config/ps/inspect" "" "$bad_lines"
}

echo "T1: all three match (named volume)"
cfg t-proj t-ctr volume metalgo_data t-proj_metalgo_data >"$TMP/fx/cfg"
echo cid-1 >"$TMP/fx/ids"; insp t-ctr t-proj volume t-proj_metalgo_data >"$TMP/fx/insp"
run
assert_eq "T1 exit 0" 0 "$RC"
assert_eq "T1 three MATCH lines" 3 "$(printf '%s\n' "$OUT" | grep -c '^MATCH ')"
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

echo "T11: static — the script text names no mutating docker subcommand outside its refusal list"
body=$(grep -v '^\s*#' "$SCRIPT" | grep -v 'REFUSED\|up|create|run|start')
for w in "compose up" "compose create" "compose run" "compose start" "compose stop" "compose rm" "compose down" \
         "docker start" "docker stop" "docker rm" "docker run" "docker create" "dk start" "dk stop" "dk rm" "dk run" "dk create"; do
  case "$body" in *"$w"*) bad "T11 no '$w'" "found in script body" ;; *) ok "T11 no '$w'" ;; esac
done

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
