#!/usr/bin/env bash
# tests/anomalies/test-caddy-advice-body.sh
#
# Pins the operator advice inside the "Caddy 停止" / "Caddy 復旧" pushes of
# scripts/check-anomalies.sh.
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction).
#
# WHY THIS EXISTS
#   check-anomalies.sh runs on the VALIDATOR host. Until 2026-10-07 the
#   "Caddy 停止" body said the public site was down and told the operator to
#   run `docker logs --tail 50 caddy-static` then a bare `docker compose up -d`.
#   The public site is served by the separate web host; on the validator host
#   Caddy only answers the deploy health check on 127.0.0.1:8085 (the operator
#   ops dashboard it used to serve on 127.0.0.1:8443 was abolished on
#   2026-10-07, so the advice must not send the operator looking for it).
#   A fixed container name can point at a retired container, and a bare
#   compose up runs whatever compose project sits in the current directory —
#   the same unsafe-advice class fixed for metalgo on 2026-10-02
#   (test-metalgo-advice-body.sh). The advice must list the caddy containers
#   first, act on the listed ID, restart the EXISTING container, and say what
#   is actually affected.
#
# METHOD
#   The body format literal is lifted out of the real script (same extractor
#   as test-metalgo-advice-body.sh) and rendered with printf. Every assertion
#   lives in check_script, which runs on the real script (must pass) and on
#   mutants that each break one property (must fail) — so each assertion is
#   shown to have teeth on every run.
#
# Usage: bash tests/anomalies/test-caddy-advice-body.sh   (exit 0 = all PASS)

set -u
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${SCRIPT_UNDER_TEST:-${REPO}/scripts/check-anomalies.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}" >&2; }

# render_body <script> <title>
render_body() {
	local script="$1" title="$2" fmt n
	fmt="$(awk -v t="\"${title}\"" '
		/^[[:space:]]*body=\$\(printf '\''/ { last = $0; next }
		index($0, "notify_or_keep") && index($0, t) { print last; exit }
	' "$script" | sed -e "s/^[[:space:]]*body=\$(printf '//" -e "s/' \".*\$//")"
	[ -n "$fmt" ] || return 1
	n="$(printf '%s' "$fmt" | grep -o '%s' | wc -l | tr -d ' ')"
	# shellcheck disable=SC2059,SC2046  # the format IS the thing under test
	printf "$fmt" $(seq "$n" | sed 's/.*/X/')
}

# check_script <script> — prints one line per failed property, nothing if all hold.
check_script() {
	local s="$1" body recov
	body="$(render_body "$s" "Caddy 停止")" || { echo "body not found"; return; }
	c_has()   { printf '%s' "$body" | grep -qF -- "$2" || echo "$1 (missing: $2)"; }
	c_lacks() { printf '%s' "$body" | grep -qF -- "$2" && echo "$1 (present: $2)"; }

	c_lacks "no fixed container name"           "caddy-static"
	c_has   "lists caddy containers with ID/Names/Status first" \
		'1) docker ps -a --filter name=caddy --format "{{.ID}} {{.Names}} {{.Status}}"'
	c_has   "logs by the listed ID"              "2) docker logs --tail 50 <1) の ID>"
	c_has   "restarts the EXISTING container"    "3) docker start <1) の ID>"
	c_has   "stops when the ID is ambiguous"     "どれか不明なら start せず止めて確認"
	c_has   "warns against bare compose up"      "docker compose up -d は実行しない"
	# The only line that may mention compose up is the warning itself.
	if printf '%s\n' "$body" | grep -E 'compose' | grep -E 'up[[:space:]]+-d' \
		| grep -vqF 'は実行しない'; then
		echo "no compose up -d instruction"
	fi
	c_has   "impact: deploy health check on 8085" \
		"影響: 次の deploy の health check (127.0.0.1:8085) が失敗する。公開サイトは別サーバで影響なし、validator 本体も無事"
	c_lacks "does not claim the public site is down" "公開サイト + ops dashboard ダウン"
	c_lacks "does not name the abolished dashboard" "運用ダッシュボード"
	c_lacks "does not name the abolished 8443"      "8443"
	c_has   "absent state explained"             "absent = 監視先の名前のコンテナが無い"

	recov="$(grep -F '"Caddy 復旧"' "$s")"
	printf '%s' "$recov" | grep -qF 'validator host の Caddy (deploy の health check 先) が再稼働' \
		|| echo "recovery names the validator-host Caddy"
	printf '%s' "$recov" | grep -qF 'サイト + ops' && echo "recovery does not claim the site"
	printf '%s' "$recov" | grep -qE '運用ダッシュボード|8443' && echo "recovery does not name the abolished dashboard"
}

# --- real script: every property holds ------------------------------------
real="$(check_script "$SCRIPT")"
if [ -z "$real" ]; then
	ok "check-anomalies: all Caddy advice properties hold"
else
	while IFS= read -r l; do bad "check-anomalies: $l"; done <<<"$real"
fi

# --- mutants: each must break at least the named property ------------------
# mutant <label> <expected-failure-substring> <sed-expr>
mutant() {
	local label="$1" want="$2" expr="$3" m="$WORK/m.sh" out
	sed -e "$expr" "$SCRIPT" >"$m"
	if cmp -s "$m" "$SCRIPT"; then bad "mutant '$label' did not change the script"; return; fi
	out="$(check_script "$m")"
	if printf '%s' "$out" | grep -qF -- "$want"; then
		ok "mutant '$label' caught ($want)"
	else
		bad "mutant '$label' NOT caught" "expected failure: $want; got: ${out:-<none>}"
	fi
}

mutant "fixed container name in logs"  "no fixed container name" \
	's/docker logs --tail 50 <1) の ID>/docker logs --tail 50 caddy-static/'
mutant "bare compose up as a step"     "no compose up -d instruction" \
	's/3) docker start <1) の ID>/3) docker compose up -d/'
mutant "list step dropped"             "lists caddy containers" \
	's/1) docker ps -a --filter name=caddy[^\\]*\\n//'
mutant "old public-site impact"        "impact: deploy health check" \
	's/影響: 次の deploy の health check[^'"'"']*/影響: 公開サイト + ops dashboard ダウン、validator 本体は無事/'
mutant "abolished-dashboard impact"    "does not name the abolished dashboard" \
	's/影響: 次の deploy の health check (127.0.0.1:8085) が失敗する。/影響: 次の deploy の health check (127.0.0.1:8085) が失敗し、運用ダッシュボード (SSH 経由の 8443) も見られない。/'
mutant "ambiguity guard dropped"       "stops when the ID is ambiguous" \
	's/ (どれか不明なら start せず止めて確認)//'
mutant "old recovery text"             "recovery names the validator-host Caddy" \
	's/validator host の Caddy (deploy の health check 先) が再稼働/サイト + ops dashboard が再稼働/'
mutant "abolished-dashboard recovery"  "recovery does not name the abolished dashboard" \
	's/validator host の Caddy (deploy の health check 先) が再稼働/validator host の Caddy (deploy の health check 先) が再稼働、運用ダッシュボード (8443) も復旧/'

printf '\n%d PASS, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
