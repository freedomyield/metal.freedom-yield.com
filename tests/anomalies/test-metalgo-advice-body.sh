#!/usr/bin/env bash
# tests/anomalies/test-metalgo-advice-body.sh
#
# Pins the operator advice inside the metalgo-related alert bodies of
# scripts/check-anomalies.sh (metalgo 停止 / ディスク 85% 超過 / ピア接続数低下).
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction).
#
# WHY THIS EXISTS
#   Until 2026-10-02 these bodies told the operator to run
#   `docker logs metalgo-mainnet`, `docker exec metalgo-mainnet …` and, on
#   metalgo-down, `docker compose -f docker-compose.metalgo.yml
#   -f docker-compose.metalgo.prod.yml up -d`. The current production host runs
#   metalgo under a pre-repo compose project / container name (warning at the
#   top of docs/DISASTER_RECOVERY.md), so the fixed name does not exist there,
#   and that compose up would create a NEW empty volume → new staker keys → a
#   node with a DIFFERENT NodeID. Operators act on these pushes under stress,
#   so the advice must find the container by compose label and must restart
#   the EXISTING container instead of composing a new one.
#
# METHOD
#   Each body is a single `body=$(printf '<fmt>' …)` line directly above the
#   notify_or_keep call carrying the alert title. The format literal is lifted
#   out of the real script and rendered with printf, so what is asserted is the
#   text the push would carry (minus the runtime numbers).
#
# Usage: bash tests/anomalies/test-metalgo-advice-body.sh   (exit 0 = all PASS)

set -u
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${SCRIPT_UNDER_TEST:-${REPO}/scripts/check-anomalies.sh}"
LABEL='label=com.docker.compose.service=metalgo'

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}" >&2; }

# render_body <title> — prints the rendered body for the alert with that title.
render_body() {
	local title="$1" fmt
	fmt="$(awk -v t="\"${title}\"" '
		/^[[:space:]]*body=\$\(printf '\''/ { last = $0; next }
		index($0, "notify_or_keep") && index($0, t) { print last; exit }
	' "$SCRIPT" | sed -e "s/^[[:space:]]*body=\$(printf '//" -e "s/' \".*\$//")"
	[ -n "$fmt" ] || return 1
	# One placeholder per %s slot: surplus args would make printf re-run the
	# whole format and render the body more than once.
	local n
	n="$(printf '%s' "$fmt" | grep -o '%s' | wc -l | tr -d ' ')"
	# shellcheck disable=SC2059,SC2046  # the format IS the thing under test
	printf "$fmt" $(seq "$n" | sed 's/.*/X/')
}

has()   { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || bad "$1" "missing: $3"; }
lacks() { printf '%s' "$2" | grep -qF -- "$3" && bad "$1" "present: $3" || ok "$1"; }

for title in "metalgo 停止" "ディスク 85% 超過" "ピア接続数低下"; do
	body="$(render_body "$title")" || { bad "$title: body found in script"; continue; }
	ok "$title: body found in script"
	lacks "$title: no fixed container name" "$body" "metalgo-mainnet"
	has   "$title: container found by compose label" "$body" "$LABEL"
done

down="$(render_body "metalgo 停止")"
if printf '%s\n' "$down" | grep -E 'compose' | grep -qE 'up[[:space:]]+-d'; then
	bad "metalgo 停止: no compose up -d step" "$(printf '%s\n' "$down" | grep -E 'compose.*up')"
else
	ok "metalgo 停止: no compose up -d step"
fi
lacks "metalgo 停止: no compose file advice" "$down" "docker-compose.metalgo"
has   "metalgo 停止: restarts the existing container" "$down" "docker start <2) の ID>"
has   "metalgo 停止: NodeID warning line" "$down" \
	"compose up は実行しない (別 NodeID になる。docs/DISASTER_RECOVERY.md 冒頭の警告)"
has   "metalgo 停止: impact line kept" "$down" "影響: validator が consensus から脱落しうる"

# Whole-script sweep: no advice anywhere in check-anomalies names the fixed container.
grep -qF 'metalgo-mainnet' "$SCRIPT" \
	&& bad "check-anomalies: no 'metalgo-mainnet' anywhere" "$(grep -nF 'metalgo-mainnet' "$SCRIPT" | head -3)" \
	|| ok "check-anomalies: no 'metalgo-mainnet' anywhere"

printf '\n%d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
