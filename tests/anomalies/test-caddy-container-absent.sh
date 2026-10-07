#!/usr/bin/env bash
# tests/anomalies/test-caddy-container-absent.sh
#
# Pins scripts/lib/container-status.sh (fy_container_status) and its use by
# scripts/server-status.sh for the Caddy container.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe. `docker` is a stub on
# PATH; no real docker, network or chain call is made.
#
# WHY THIS EXISTS
#   CADDY_CONTAINER (host cron env) names the ops-dashboard Caddy, and which
#   container serves the dashboard can change. When the named container was
#   removed, `docker inspect` failed, server-status.sh exited 5 and the whole
#   status feed (metalgo included) went stale without saying why. A missing
#   container must be published as "absent" — a non-running state that
#   check-anomalies.sh alerts on — while a docker failure must still abort.
#
# Each property is also checked against a mutant implementation that breaks it
# (must fail), so the assertions are shown to have teeth on every run.
#
# Usage: bash tests/anomalies/test-caddy-container-absent.sh   (exit 0 = all PASS)

set -u
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${LIB_UNDER_TEST:-${REPO}/scripts/lib/container-status.sh}"
SS="${REPO}/scripts/server-status.sh"
CA="${REPO}/scripts/check-anomalies.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}" >&2; }

# --- docker stub ---------------------------------------------------------
# FAKE_DOCKER_STATE: "<name>=<status>" lines for existing containers.
# FAKE_DOCKER_DOWN=1: every docker call fails (daemon unreachable).
# FAKE_INSPECT_BROKEN=1: inspect fails even for existing containers.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
[ "${FAKE_DOCKER_DOWN:-0}" = 1 ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1" in
  inspect)
    name="${!#}"
    [ "${FAKE_INSPECT_BROKEN:-0}" = 1 ] && { echo "boom" >&2; exit 1; }
    st=$(printf '%s\n' "${FAKE_DOCKER_STATE:-}" | awk -F= -v n="$name" '$1==n {print $2; exit}')
    if [ -n "$st" ]; then printf '%s\n' "$st"; exit 0; fi
    printf '\n'; echo "Error: No such object: $name" >&2; exit 1 ;;
  ps)
    printf '%s\n' "${FAKE_DOCKER_STATE:-}" | awk -F= 'NF {print $1}'; exit 0 ;;
  *) echo "stub: unexpected docker $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$WORK/bin/docker"

# run_status <lib> <name> [VAR=val …] → prints "rc=<rc> out=<out>"
run_status() {
	local lib="$1" name="$2"; shift 2
	env PATH="$WORK/bin:$PATH" "$@" bash -c '. "$1"; out=$(fy_container_status "$2"); rc=$?; printf "rc=%s out=%s" "$rc" "$out"' _ "$lib" "$name"
}

ST=$'web-dash-a=running\nold-caddy=exited\ncaddy=running'

# check_lib <lib> — one line per broken property.
check_lib() {
	local l="$1" r
	r="$(run_status "$l" web-dash-a FAKE_DOCKER_STATE="$ST")"
	[ "$r" = "rc=0 out=running" ] || echo "running container → running (got: $r)"
	r="$(run_status "$l" old-caddy FAKE_DOCKER_STATE="$ST")"
	[ "$r" = "rc=0 out=exited" ] || echo "exited container → exited (got: $r)"
	r="$(run_status "$l" retired-caddy FAKE_DOCKER_STATE="$ST")"
	[ "$r" = "rc=0 out=absent" ] || echo "removed container → absent (got: $r)"
	# exact match: 'cadd' is a prefix of an existing name but is not a container
	r="$(run_status "$l" cadd FAKE_DOCKER_STATE="$ST")"
	[ "$r" = "rc=0 out=absent" ] || echo "name match is exact, not prefix (got: $r)"
	r="$(run_status "$l" web-dash-a FAKE_DOCKER_STATE="$ST" FAKE_DOCKER_DOWN=1)"
	[ "$r" = "rc=1 out=" ] || echo "docker down → rc 1, never absent (got: $r)"
	r="$(run_status "$l" web-dash-a FAKE_DOCKER_STATE="$ST" FAKE_INSPECT_BROKEN=1)"
	[ "$r" = "rc=1 out=" ] || echo "existing but uninspectable → rc 1 (got: $r)"
	r="$(run_status "$l" "" FAKE_DOCKER_STATE="$ST")"
	[ "$r" = "rc=1 out=" ] || echo "empty name → rc 1 (got: $r)"
}

real="$(check_lib "$LIB")"
if [ -z "$real" ]; then ok "fy_container_status: all properties hold"
else while IFS= read -r l; do bad "fy_container_status: $l"; done <<<"$real"; fi

# mutant <label> <expected-failure-substring> <sed-expr>
mutant() {
	local label="$1" want="$2" expr="$3" m="$WORK/lib-mutant.sh" out
	sed -e "$expr" "$LIB" >"$m"
	if cmp -s "$m" "$LIB"; then bad "mutant '$label' did not change the lib"; return; fi
	out="$(check_lib "$m")"
	if printf '%s' "$out" | grep -qF -- "$want"; then ok "mutant '$label' caught ($want)"
	else bad "mutant '$label' NOT caught" "expected: $want; got: ${out:-<none>}"; fi
}
mutant "docker failure reported as absent"  "docker down → rc 1" \
	"s/names=\$(docker ps -a --format '{{.Names}}' 2>\/dev\/null) || return 1/names=\$(docker ps -a --format '{{.Names}}' 2>\/dev\/null) || { printf absent; return 0; }/"
mutant "substring instead of exact match"   "name match is exact" \
	's/grep -qxF -- "$name"/grep -qF -- "$name"/'
mutant "absent mapped to exited"            "removed container → absent" \
	"s/printf 'absent'/printf 'exited'/"
mutant "uninspectable called absent"        "existing but uninspectable" \
	's/    return 1   # exists but inspect failed.*/    :/'

# --- wiring: server-status.sh uses the helper for Caddy ---------------------
check_wiring() {
	local s="$1"
	grep -qE '^\. .*/lib/container-status\.sh"' "$s" || echo "sources lib/container-status.sh"
	grep -qE 'CADDY_STATUS=\$\(fy_container_status "\$CADDY_CONTAINER"\)' "$s" \
		|| echo "Caddy status comes from fy_container_status"
	grep -qE 'CADDY_STATUS=\$\(inspect_status' "$s" && echo "Caddy no longer uses bare inspect_status"
}
w="$(check_wiring "$SS")"
if [ -z "$w" ]; then ok "server-status.sh: Caddy uses fy_container_status"
else while IFS= read -r l; do bad "server-status.sh: $l"; done <<<"$w"; fi
sed -e 's/CADDY_STATUS=$(fy_container_status "$CADDY_CONTAINER")/CADDY_STATUS=$(inspect_status "$CADDY_CONTAINER")/' "$SS" >"$WORK/ss-mutant.sh"
if cmp -s "$WORK/ss-mutant.sh" "$SS"; then bad "wiring mutant did not change server-status.sh"
elif [ -n "$(check_wiring "$WORK/ss-mutant.sh")" ]; then ok "wiring mutant (back to inspect_status) caught"
else bad "wiring mutant (back to inspect_status) NOT caught"; fi

# --- downstream: "absent" is non-running, so check-anomalies alerts on it ----
# The Caddy transition fires on any value other than "running"; pin that it is
# not narrowed to a list of docker states that would skip "absent".
grep -qF 'if [ "$OBS_CADDY" != "running" ] && [ "$ORIG_CADDY" = "running" ]; then' "$CA" \
	&& ok "check-anomalies: Caddy alert fires on any non-running state (absent included)" \
	|| bad "check-anomalies: Caddy alert condition changed — re-check that absent still alerts"

printf '\n%d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
