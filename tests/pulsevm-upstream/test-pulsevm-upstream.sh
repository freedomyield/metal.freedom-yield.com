#!/usr/bin/env bash
# test-pulsevm-upstream.sh — suite for scripts/check-pulsevm-upstream.sh.
#
# CHAIN: none — a recording curl stub (FYD_CURL) serves fixture bodies and
#        HTTP codes from tempfiles. No real HTTP, no broadcast, no push, and
#        no ntfy: FYD_NOTIFY points at a recording stub throughout.
#
# What it proves:
#   T1-T4  each trigger fires on the condition it claims, and does NOT fire
#          on the near-miss version of that condition (a suite that only ever
#          asserts "it fired" cannot tell a working detector from `exit 3`)
#   fail-open  a missing OR unparseable state file fires BASELINE rather than
#          resolving to silence, and says T3/T4 were DEFERRED rather than
#          claiming they fired
#   quiet  a second identical run is exit 0 with no alert, and a release-tag
#          change alone is logged but never pushed
#   exit 4 a source that will not return 200, with the retry budget spent on
#          5xx/000 and NOT spent on a 4xx, alerting once at the third
#          consecutive failure and not before
#   exit 5 a 200 whose body cannot be parsed
#   DRY    without FY_LIVE=1 the repo's logs/ directory is left byte-identical
#          — no log file, no state file, no stray temp file — while the
#          verdict, the exit code and the stderr trace are unchanged
#   shape  the checker never names an /ext/bc/ URL (scripts/broadcast-guard.sh
#          blocks that shape unconditionally, read-only queries included, so
#          the checker is built to have no reason to go near it)
#
# Usage:
#   bash tests/pulsevm-upstream/test-pulsevm-upstream.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-pulsevm-upstream.sh"

if [ ! -f "$CHECKER" ]; then
	echo "FATAL: checker not found at $CHECKER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# The chain id A-Chain Alpine actually served on 2026-08-17, and a second one
# standing in for "the next reset, or mainnet".
CHAIN_A="193526980f523c07a567dda80f5f543e2356518ce1475cf3e03d98ca740b3f67"
CHAIN_B="aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111ff"

BASE=""; STUB=""; LOG=""; STATE=""; NOTIFY_STUB=""; NOTIFY_LOG=""
S1=""; S2=""; S3=""; S4=""; NPM_TS=""; NPM_TSC=""; NPM_SEARCH=""
SEED_NPM_WATCH=""; SEED_NPM_FOUND=""

# Fixture identities are FICTIONAL on purpose. The real `pulse-ts` maintainer
# is a private individual whose npm username and personal e-mail address have
# no business being committed to a public repository; what these cases need is
# the SHAPE of a publisher record and whether it matches the affiliation
# pattern, which a made-up identity carries just as well. The one real name
# kept is @metalblockchain/pulsevm-js — a company's published package, already
# named in the checker's header as the measurement that motivated S5.
STRANGER_USER="strangerdev"
STRANGER_MAIL="strangerdev@example.test"
OFFICIAL_USER="metalpayops"
OFFICIAL_MAIL="npmops@metalpay.example"
OFFICIAL_PKG="@metalblockchain/pulsevm-js"

setup() {
	BASE="$(mktemp -d -t pulsevm-upstream-test.XXXXXX)"
	STUB="$BASE/curl-stub.sh"
	LOG="$BASE/pulsevm-upstream.log"
	STATE="$BASE/pulsevm-upstream-state.json"
	NOTIFY_STUB="$BASE/notify-stub.sh"
	NOTIFY_LOG="$BASE/notify.log"
	S1="$BASE/s1.json"; S2="$BASE/s2.md"; S3="$BASE/s3.json"; S4="$BASE/s4.txt"
	NPM_TS="$BASE/npm-pulse-ts.json"
	NPM_TSC="$BASE/npm-pulse-tsc.json"
	NPM_SEARCH="$BASE/npm-search.json"
	SEED_NPM_WATCH=""
	SEED_NPM_FOUND=""

	cat > "$NOTIFY_STUB" <<NOTIFYEOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$NOTIFY_LOG"
NOTIFYEOF
	chmod +x "$NOTIFY_STUB"

	# Recording curl stub. Emulates
	#   curl -sS -o <outfile> -w "%{http_code}" --max-time N <url>
	# and dispatches on a distinctive substring of each source's URL. Per-URL
	# attempt counts land in $STUB_STATE_DIR/<key>.count so a case can assert
	# exactly how many requests fetch()'s retry loop made — which is the only
	# way to prove the "a 4xx is not retried" rule.
	cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
outfile=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) outfile="$2"; shift 2 ;;
		-w|--max-time) shift 2 ;;
		-sS|-s|-S) shift ;;
		http*|file*) url="$1"; shift ;;
		*) shift ;;
	esac
done
statedir="${STUB_STATE_DIR:-.}"
printf '%s\n' "$url" >> "$statedir/urls.log"
case "$url" in
	*releases*)   key=s1; body="${S1_BODY:-/dev/null}"; code="${S1_CODE:-200}"; seq="${S1_CODE_SEQ:-}" ;;
	*endpoints*)  key=s2; body="${S2_BODY:-/dev/null}"; code="${S2_CODE:-200}"; seq="${S2_CODE_SEQ:-}" ;;
	*health*)     key=s3; body="${S3_BODY:-/dev/null}"; code="${S3_CODE:-200}"; seq="${S3_CODE_SEQ:-}" ;;
	*llms*)       key=s4; body="${S4_BODY:-/dev/null}"; code="${S4_CODE:-200}"; seq="${S4_CODE_SEQ:-}" ;;
	*npm-search*) key=npmsearch; body="${NPMSEARCH_BODY:-/dev/null}"; code="${NPMSEARCH_CODE:-200}"; seq="${NPMSEARCH_CODE_SEQ:-}" ;;
	# S5a. The package name is recovered from the URL and turned into a
	# variable-name slug, so a case can serve any name without the stub
	# needing to know it in advance. The default code is 404 — an unfixtured
	# name is simply not published, which is the state most of them are in.
	*/npm/*)
		pkg="${url##*/npm/}"; pkg="${pkg%/latest}"
		# %2F back to / before slugging, so a scoped name's fixture variable
		# is named after the PACKAGE and not after its URL encoding.
		pkg="${pkg//%2F//}"; pkg="${pkg//%2f//}"
		slug="$(printf '%s' "$pkg" | tr -c 'A-Za-z0-9' '_' | tr 'a-z' 'A-Z')"
		key="npm_${slug}"
		eval "body=\"\${NPM_${slug}_BODY:-/dev/null}\""
		eval "code=\"\${NPM_${slug}_CODE:-404}\""
		eval "seq=\"\${NPM_${slug}_CODE_SEQ:-}\""
		;;
	*)            key=unknown; body=/dev/null; code=404; seq="" ;;
esac
countfile="$statedir/${key}.count"
n=0
[ -f "$countfile" ] && n="$(cat "$countfile")"
n=$((n + 1))
printf '%s' "$n" > "$countfile"
if [ -n "$seq" ]; then
	picked="$(printf '%s\n' $seq | sed -n "${n}p")"
	[ -n "$picked" ] && code="$picked" || code="$(printf '%s\n' $seq | tail -n1)"
fi
if [ -n "$outfile" ] && [ -f "$body" ]; then cat "$body" > "$outfile"; fi
printf '%s' "$code"
STUBEOF
	chmod +x "$STUB"

	# Default fixtures = the upstream as measured on 2026-08-17 (S1-S4) and
	# 2026-08-19 (S5): `pulse-ts` taken by an unaffiliated third party,
	# `pulse-tsc` not on npm at all, and exactly one package mentioning
	# PulseVM in the registry search.
	write_s1 "$S1" "v0.6.2"
	write_s2 "$S2" notice "$CHAIN_A" no-mainnet
	write_s3 "$S3" 3406
	write_s4 "$S4"
	write_npm "$NPM_TS" "pulse-ts" "2.1.1" "$STRANGER_USER" "$STRANGER_MAIL"
	write_npm_search "$NPM_SEARCH" "${OFFICIAL_PKG}|${OFFICIAL_USER}|${OFFICIAL_MAIL}"
}
teardown() { rm -rf "$BASE"; BASE=""; }

# write_npm <file> <name> <version> <maintainer> <email> [repository-url]
# The shape registry.npmjs.org serves at /<name>/latest, trimmed to the fields
# the checker's fingerprint reads.
write_npm() {
	local f="$1" name="$2" ver="$3" who="$4" mail="$5" repo="${6:-}"
	jq -n --arg n "$name" --arg v "$ver" --arg w "$who" --arg m "$mail" --arg r "$repo" \
		'{name: $n, version: $v,
		  description: "fixture manifest",
		  maintainers: [{name: $w, email: $m}],
		  _npmUser: {name: $w, email: $m},
		  repository: (if $r == "" then null else {type: "git", url: $r} end),
		  homepage: null,
		  dist: {tarball: "https://example.test/t.tgz"}}' > "$f"
}

# write_npm_search <file> [<name>|<publisher>|<email>]...
# The shape registry.npmjs.org/-/v1/search serves.
write_npm_search() {
	local f="$1" spec name who mail objs='[]'
	shift
	for spec in "$@"; do
		name="${spec%%|*}"; spec="${spec#*|}"
		who="${spec%%|*}"; mail="${spec#*|}"
		objs="$(printf '%s' "$objs" | jq -c --arg n "$name" --arg w "$who" --arg m "$mail" \
			'. + [{package: {name: $n, description: ("SDK for PulseVM — " + $n),
			                 publisher: {username: $w, email: $m},
			                 maintainers: [{username: $w, email: $m}],
			                 links: {npm: ("https://example.test/" + $n)}}}]')"
	done
	printf '%s' "$objs" | jq '{total: length, objects: .}' > "$f"
}

# write_s1 <file> <tag>
write_s1() {
	cat > "$1" <<JSON
{ "tag_name": "$2", "name": "PulseVM $2", "published_at": "2026-08-12T00:00:00Z" }
JSON
}

# write_s2 <file> <notice|no-notice> <chain-id-hex> <mainnet|no-mainnet>
#
# Mirrors the real https://pulsevm.dev/network/endpoints.md structure. The RPC
# row of the real page carries an AvalancheGo /ext/bc/<id>/rpc URL; it is
# deliberately NOT reproduced here. The checker never parses or requests that
# row, and scripts/broadcast-guard.sh matches that URL shape in any command
# line, so keeping it out of the fixture keeps the whole test tree free of a
# string that would trip an unrelated guard.
write_s2() {
	local f="$1" notice="$2" chain="$3" mainnet="$4"
	{
		printf '# Network Endpoints\n\n'
		printf '## A-Chain Alpine (testnet)\n\n'
		printf '::: warning Testnet resets frequently during hardening\n'
		printf 'Each reset changes the blockchain ID and chain ID, and state does not carry over.\n'
		printf ':::\n\n'
		printf '| | |\n|---|---|\n'
		printf '| History (Hyperion v2) | `https://a-chain-alpine-hyperion.example.test` |\n'
		printf '| Blockchain ID | `C6tuBzT2M3TZHyWc5Ro6L3cJyoxRAPy9avJeNh3FPzkBswXgX` |\n'
		printf '| Chain ID | `%s` |\n' "$chain"
		if [ "$notice" = "notice" ]; then
			printf '| Node version | PulseVM `v0.6.x`-series (third-party node sync is not yet supported on this reset — use the public RPC above) |\n'
		else
			printf '| Node version | PulseVM `v0.7.x`-series (run your own node: see the validator guide) |\n'
		fi
		printf '\n::: tip Testnet\nAlpine is the public test network for A-Chain.\n:::\n'
		if [ "$mainnet" = "mainnet" ]; then
			printf '\n## A-Chain Mainnet\n\nProduction endpoints are live.\n'
		fi
	} > "$f"
}

# write_s3 <file> <head_block_num>
write_s3() {
	cat > "$1" <<JSON
{ "chain": "pulse",
  "health": [
    { "service": "Elasticsearch", "service_data": { "version": "8.17.4" }, "status": "OK" },
    { "service": "PulseVM-RPC", "service_data": { "head_block_num": $2, "last_irreversible_block": $2 }, "status": "OK" },
    { "service": "Indexer", "service_data": { "head_block_num": $2, "last_indexed_block": $2 }, "status": "OK" }
  ],
  "version": "0.1.0" }
JSON
}

# write_s4 <file> [extra-page-path]
write_s4() {
	local f="$1" extra="${2:-}"
	{
		printf '# PulseVM\n\n## Pages\n\n'
		printf -- '- [For AI Agents & Bots](https://pulsevm.example.test/agents.md)\n'
		printf -- '- [RPC & REST API](https://pulsevm.example.test/build/api.md)\n'
		printf -- '- [Network Endpoints](https://pulsevm.example.test/network/endpoints.md)\n'
		printf -- '- [Antelope Compatibility](https://pulsevm.example.test/compare/antelope.md)\n'
		[ -n "$extra" ] && printf -- '- [New Page](https://pulsevm.example.test/%s)\n' "$extra"
	} > "$f"
}

# seed_state <sync_present true|false> <mainnet true|false> <chain-id> <head> <tag> [extra-page-path] [consecutive_failures]
#
# The S5 half is seeded from $SEED_NPM_WATCH / $SEED_NPM_FOUND rather than
# from positional arguments, so that every pre-existing call site keeps its
# meaning and only the cases that care about npm have to say anything. The
# defaults are the 2026-08-19 measurement, i.e. the state in which T5 is
# silent.
seed_state() {
	local sync="$1" mainnet="$2" chain="$3" head="$4" tag="$5" extra="${6:-}" consec="${7:-0}"
	local pages='["https://pulsevm.example.test/agents.md","https://pulsevm.example.test/build/api.md","https://pulsevm.example.test/compare/antelope.md","https://pulsevm.example.test/network/endpoints.md"]'
	if [ -n "$extra" ]; then
		pages="$(printf '%s' "$pages" | jq -c --arg p "https://pulsevm.example.test/${extra}" '. + [$p] | sort')"
	fi
	local npm_watch="${SEED_NPM_WATCH:-}" npm_found="${SEED_NPM_FOUND:-}"
	[ -n "$npm_watch" ] || npm_watch='[{"name":"pulse-ts","present":true,"version":"2.1.1","official":false},
	                                   {"name":"pulse-tsc","present":false,"version":"","official":false}]'
	[ -n "$npm_found" ] || npm_found="$(jq -nc --arg p "$OFFICIAL_PKG" '[$p]')"
	jq -n --arg tag "$tag" --argjson sync "$sync" --argjson mainnet "$mainnet" \
		--arg chain "$chain" --argjson head "$head" --argjson pages "$pages" --argjson consec "$consec" \
		--argjson npm_watch "$npm_watch" --argjson npm_found "$npm_found" \
		'{schema_version: 2, checked_at: "2026-08-16T02:00:00Z", consecutive_failures: $consec,
		  observations: {release_tag: $tag, sync_notice_present: $sync, mainnet_section_present: $mainnet,
		                 head_block: $head, chain_ids: [$chain], pages: $pages,
		                 npm_watch: $npm_watch, npm_discovered: $npm_found}}' > "$STATE"
}

run_checker() {
	FY_LIVE="${FY_LIVE_OVERRIDE-1}" \
	FYD_CURL="$STUB" \
	FYD_NOTIFY="$NOTIFY_STUB" \
	PULSEVM_UPSTREAM_LOG="$LOG" \
	PULSEVM_UPSTREAM_STATE="$STATE" \
	PULSEVM_RELEASES_URL="https://example.test/repos/pulsevm/releases/latest" \
	PULSEVM_ENDPOINTS_URL="https://example.test/network/endpoints.md" \
	PULSEVM_HEALTH_URL="https://example.test/v2/health" \
	PULSEVM_LLMS_URL="https://example.test/llms.txt" \
	PULSEVM_NPM_REGISTRY="https://example.test/npm" \
	PULSEVM_NPM_SEARCH_URL="https://example.test/npm-search?text=pulsevm&size=50" \
	PULSEVM_NPM_PACKAGES="${PULSEVM_NPM_PACKAGES-pulse-ts pulse-tsc}" \
	S1_BODY="$S1" S2_BODY="$S2" S3_BODY="$S3" S4_BODY="$S4" \
	S1_CODE="${S1_CODE:-200}" S2_CODE="${S2_CODE:-200}" S3_CODE="${S3_CODE:-200}" S4_CODE="${S4_CODE:-200}" \
	S1_CODE_SEQ="${S1_CODE_SEQ:-}" S2_CODE_SEQ="${S2_CODE_SEQ:-}" S3_CODE_SEQ="${S3_CODE_SEQ:-}" S4_CODE_SEQ="${S4_CODE_SEQ:-}" \
	NPM_PULSE_TS_BODY="$NPM_TS"   NPM_PULSE_TS_CODE="${NPM_TS_CODE:-200}"   NPM_PULSE_TS_CODE_SEQ="${NPM_TS_CODE_SEQ:-}" \
	NPM_PULSE_TSC_BODY="$NPM_TSC" NPM_PULSE_TSC_CODE="${NPM_TSC_CODE:-404}" NPM_PULSE_TSC_CODE_SEQ="${NPM_TSC_CODE_SEQ:-}" \
	NPMSEARCH_BODY="$NPM_SEARCH"  NPMSEARCH_CODE="${NPMSEARCH_CODE:-200}"   NPMSEARCH_CODE_SEQ="${NPMSEARCH_CODE_SEQ:-}" \
	STUB_STATE_DIR="$BASE" \
	FYD_RETRY_SLEEP=0 \
	FYD_FETCH_ATTEMPTS="${FYD_FETCH_ATTEMPTS:-3}" \
	PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA="${PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA:-1000}" \
	PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER="${PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER:-3}" \
		bash "$CHECKER" "$@"
}
alerts()   { cat "$NOTIFY_LOG" 2>/dev/null; }
# `grep -c .` already prints 0 for an empty log; it just exits 1 while doing
# so. `|| true` swallows that exit WITHOUT printing a second 0 — an earlier
# `|| echo 0` produced "0\n0" and made every "expected 0 alerts" case blow up
# on `[: integer expression expected` rather than pass.
n_alerts() { alerts | grep -c . || true; }
calls()    { cat "$BASE/$1.count" 2>/dev/null || echo 0; }
urls()     { cat "$BASE/urls.log" 2>/dev/null; }

# ---- the over-claim denylist -------------------------------------------------
# An alert body may not claim more than the run measured. This is not a style
# rule: T1's first shipped body ended "running our own node may now be
# possible", and when it fired for real against the live page on 2026-08-19 the
# page did not say that. It had stopped saying node sync was UNSUPPORTED while
# still telling readers to connect via the public RPC — the checker had
# measured the absence of a prohibition and reported it as a capability.
#
# The notification is the most-read surface this repo has (nobody diffs a
# header comment at 11:00 JST), so this asserts on the alert bodies rather than
# on the source. Every case that produces an alert runs it.
OVERCLAIM_RE='we can now|is now supported|are now supported|now be possible|now possible|migration landed|it is official|officially published|proves that|confirms that|means we can'
assert_no_overclaim() {
	local label="$1" hit
	hit="$(alerts | grep -inE "$OVERCLAIM_RE" | head -1)"
	if [ -n "$hit" ]; then
		bad "${label}: alert body claims more than the run measured -> ${hit}"
	else
		ok "${label}: alert body claims no capability the run did not measure"
	fi
}

# assert_alert_shape <label> — OBSERVED / OBLIGATION are mandatory in every
# body; NOT ESTABLISHED is asserted separately by the cases where a reader has
# an obvious wrong conclusion available to jump to.
assert_alert_shape() {
	local label="$1"
	alerts | grep -q 'OBSERVED:' \
		&& ok "${label}: alert states what was OBSERVED" \
		|| bad "${label}: alert does not separate the observation ($(alerts))"
	alerts | grep -q 'OBLIGATION:' \
		&& ok "${label}: alert names the OBLIGATION" \
		|| bad "${label}: alert does not name what to go and do ($(alerts))"
}

# ---- case 1: no prior state -> BASELINE fires, T3/T4 declared DEFERRED -------
setup
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "baseline: no state -> exit 3 (fail open toward alerting)" \
	|| bad "baseline: expected exit 3, got $RC"
echo "$OUT" | grep -q 'TRIGGER BASELINE' \
	&& ok "baseline: verdict names BASELINE" \
	|| bad "baseline: verdict missing BASELINE (out: $OUT)"
echo "$OUT" | grep -q 'T3/T4 DEFERRED' \
	&& ok "baseline: says T3/T4 were DEFERRED rather than claiming they fired" \
	|| bad "baseline: missing the DEFERRED disclaimer (out: $OUT)"
echo "$OUT" | grep -qE 'TRIGGER BASELINE \(priority=' \
	&& ok "baseline: does NOT claim T1/T2 on an unchanged upstream" \
	|| bad "baseline: unexpected extra trigger in the fired set (out: $OUT)"
alerts | grep -q '^high|' \
	&& ok "baseline: dispatched at HIGH — until this run the monitor was not watching anything" \
	|| bad "baseline: expected high priority ($(alerts))"
[ "$(n_alerts)" -eq 1 ] \
	&& ok "baseline: exactly one alert" \
	|| bad "baseline: expected 1 alert, got $(n_alerts) ($(alerts))"
alerts | grep -q '^high|' \
	&& ok "baseline: alert is high priority" \
	|| bad "baseline: alert not high priority ($(alerts))"
assert_no_overclaim "baseline"
[ -r "$STATE" ] && [ "$(jq -r '.observations.head_block' "$STATE")" = "3406" ] \
	&& ok "baseline: state recorded with the observed head block" \
	|| bad "baseline: state file missing or wrong ($(cat "$STATE" 2>/dev/null))"
[ "$(jq -r '.observations.npm_watch | length' "$STATE")" -eq 2 ] \
	&& ok "baseline: both watched npm names are recorded so the next run has a diff base" \
	|| bad "baseline: npm_watch not recorded ($(jq -c '.observations.npm_watch' "$STATE" 2>/dev/null))"
[ "$(jq -r '.consecutive_failures' "$STATE")" = "0" ] \
	&& ok "baseline: consecutive_failures reset to 0 on a successful run" \
	|| bad "baseline: expected consecutive_failures=0"
teardown

# ---- case 2: second identical run -> silent exit 0 ---------------------------
setup
run_checker >/dev/null 2>&1
rm -f "$NOTIFY_LOG"
OUT="$(run_checker --verbose 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "steady: an unchanged upstream -> exit 0" \
	|| bad "steady: expected exit 0, got $RC (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "steady: no alert on an unchanged upstream" \
	|| bad "steady: expected 0 alerts, got $(n_alerts) ($(alerts))"
echo "$OUT" | grep -q 'OK no upstream change' \
	&& ok "steady: --verbose emits the heartbeat line" \
	|| bad "steady: --verbose heartbeat missing (out: $OUT)"
teardown

# ---- case 3 (T1): the sync notice disappears --------------------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_s2 "$S2" no-notice "$CHAIN_A" no-mainnet
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T1: notice gone -> exit 3" \
	|| bad "T1: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'TRIGGER T1' \
	&& ok "T1: verdict names T1" \
	|| bad "T1: verdict missing T1 (out: $OUT)"
assert_alert_shape "T1"
# The scar. When this trigger fired for real the page had merely stopped
# saying node sync was unsupported; it went on routing readers to the public
# RPC. The body must report the absence it measured, deny the capability it
# did NOT measure, and send the reader to the page.
alerts | grep -q 'NOT ESTABLISHED: that third-party node sync is supported' \
	&& ok "T1: alert explicitly denies the conclusion it did not measure" \
	|| bad "T1: alert does not disclaim the capability ($(alerts))"
alerts | grep -q "read the page's node/version row" \
	&& ok "T1: alert sends the reader to the row that would actually answer it" \
	|| bad "T1: alert body missing the action ($(alerts))"
assert_no_overclaim "T1"
alerts | grep -q '^high|' \
	&& ok "T1: dispatched at HIGH — this is the trigger that converts watch into act" \
	|| bad "T1: expected high priority ($(alerts))"
teardown

# ---- case 3b (T1 near-miss): notice still present -> no fire ----------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T1 near-miss: notice still present -> exit 0" \
	|| bad "T1 near-miss: expected exit 0, got $RC (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "T1 near-miss: no alert" \
	|| bad "T1 near-miss: expected 0 alerts, got $(n_alerts) ($(alerts))"
teardown

# ---- case 3c (T1 hysteresis): already-absent notice does not re-page daily ---
setup
seed_state false false "$CHAIN_A" 3406 "v0.6.2"
write_s2 "$S2" no-notice "$CHAIN_A" no-mainnet
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T1 hysteresis: a notice absent in BOTH runs pages only on the transition" \
	|| bad "T1 hysteresis: expected exit 0 on the second absent run, got $RC (out: $OUT)"
teardown

# ---- case 4 (T2a): a mainnet section appears --------------------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_s2 "$S2" notice "$CHAIN_A" mainnet
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T2a: mainnet section -> exit 3" \
	|| bad "T2a: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'TRIGGER T2' \
	&& ok "T2a: verdict names T2" \
	|| bad "T2a: verdict missing T2 (out: $OUT)"
alerts | grep -q 'mainnet section appeared' \
	&& ok "T2a: alert names the mainnet-section sub-condition" \
	|| bad "T2a: alert body wrong ($(alerts))"
alerts | grep -q 'gate 1' \
	&& ok "T2a: alert names the OBLIGATION (re-check the safe-broadcast gates), not just the observation" \
	|| bad "T2a: alert body does not name what to go and do ($(alerts))"
# The same class of over-claim T1 shipped: what the checker matched is a
# markdown heading, and "A-Chain Mainnet (not yet live)" matches identically.
alerts | grep -q 'NOT ESTABLISHED: that a mainnet is live' \
	&& ok "T2a: alert reports the heading it matched, not a live mainnet" \
	|| bad "T2a: alert asserts more than a heading match ($(alerts))"
assert_alert_shape "T2a"
assert_no_overclaim "T2a"
alerts | grep -q '^high|' \
	&& ok "T2a: the mainnet-section sub-condition is HIGH" \
	|| bad "T2a: expected high priority ($(alerts))"
teardown

# ---- case 4b (T2b): a new chain id appears ----------------------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_s2 "$S2" notice "$CHAIN_B" no-mainnet
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T2b: unseen chain id -> exit 3" \
	|| bad "T2b: expected exit 3, got $RC (out: $OUT)"
alerts | grep -q "$CHAIN_B" \
	&& ok "T2b: alert names the new chain id" \
	|| bad "T2b: alert does not name the new chain id ($(alerts))"
alerts | grep -q 'Alpine reset changes the chain id too' \
	&& ok "T2b: alert distinguishes a reset from a migration instead of asserting one" \
	|| bad "T2b: alert missing the reset caveat ($(alerts))"
# The priority split's whole reason for existing. The endpoints page warns
# resets are frequent during hardening and that each one changes the chain id,
# so this path is the likeliest to be routine. If it arrived at `high` next to
# T1, the high channel would be trained into background noise within a few
# resets — which is the harm, not the noise itself.
alerts | grep -q '^default|' \
	&& ok "T2b: a chain-id-only change is DEFAULT — a routine Alpine reset must not share T1's channel" \
	|| bad "T2b: expected default priority, got ($(alerts))"
assert_alert_shape "T2b"
assert_no_overclaim "T2b"
teardown

# ---- case 4c (T2 near-miss): the word 'mainnet' in prose is not a section ----
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_s2 "$S2" notice "$CHAIN_A" no-mainnet
printf '\nThere is no mainnet deployment of PulseVM yet.\n' >> "$S2"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T2 near-miss: 'mainnet' in a sentence is not a mainnet SECTION -> exit 0" \
	|| bad "T2 near-miss: expected exit 0, got $RC (out: $OUT)"
teardown

# ---- case 5 (T3): a new documentation page ----------------------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_s4 "$S4" "network/validator.md"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T3: new page -> exit 3" \
	|| bad "T3: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'TRIGGER T3' \
	&& ok "T3: verdict names T3" \
	|| bad "T3: verdict missing T3 (out: $OUT)"
alerts | grep -q 'network/validator.md' \
	&& ok "T3: alert names the new page" \
	|| bad "T3: alert does not name the new page ($(alerts))"
alerts | grep -q '^default|' \
	&& ok "T3: a new docs page is DEFAULT" \
	|| bad "T3: expected default priority ($(alerts))"
alerts | grep -q 'this run did not read the pages themselves' \
	&& ok "T3: alert admits it read the page LIST, not the pages" \
	|| bad "T3: alert implies it read the new pages ($(alerts))"
assert_alert_shape "T3"
assert_no_overclaim "T3"
teardown

# ---- case 5b (T3 near-miss): a page REMOVED upstream is not a new page ------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2" "network/validator.md"
write_s4 "$S4"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T3 near-miss: a page disappearing is not a new page -> exit 0" \
	|| bad "T3 near-miss: expected exit 0, got $RC (out: $OUT)"
teardown

# ---- case 6 (T4): the head block advances past the threshold ----------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_s3 "$S3" 9406
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T4: head block +6000 -> exit 3" \
	|| bad "T4: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'TRIGGER T4' \
	&& ok "T4: verdict names T4" \
	|| bad "T4: verdict missing T4 (out: $OUT)"
alerts | grep -q '3406 -> 9406' \
	&& ok "T4: alert names both head blocks" \
	|| bad "T4: alert missing the block pair ($(alerts))"
alerts | grep -q '^default|' \
	&& ok "T4: a head-block advance is DEFAULT" \
	|| bad "T4: expected default priority ($(alerts))"
alerts | grep -q 'reset and replayed' \
	&& ok "T4: alert offers the other reading (a reset and replay looks identical from a head block)" \
	|| bad "T4: alert asserts real use without the alternative ($(alerts))"
assert_alert_shape "T4"
assert_no_overclaim "T4"
teardown

# ---- case 6d: a run firing BOTH kinds escalates to high ---------------------
# T1 (high) and T4 (default) together must not be dispatched at default — the
# act-now trigger is still in there and still needs acting on. Guards the
# obvious wrong implementation, where the LAST trigger to fire wins.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_s2 "$S2" no-notice "$CHAIN_A" no-mainnet
write_s3 "$S3" 9406
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "priority-mix: T1 + T4 together -> exit 3" \
	|| bad "priority-mix: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'TRIGGER T1,T4' \
	&& ok "priority-mix: both triggers are reported" \
	|| bad "priority-mix: expected both T1 and T4 in the verdict (out: $OUT)"
alerts | grep -q '^high|' \
	&& ok "priority-mix: a mixed run escalates to HIGH (the act-now trigger wins, not the last one evaluated)" \
	|| bad "priority-mix: expected high priority ($(alerts))"
teardown

# ---- case 6b (T4 near-miss): a sub-threshold advance is not a live chain ----
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_s3 "$S3" 3506
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T4 near-miss: +100 (< 1000) -> exit 0" \
	|| bad "T4 near-miss: expected exit 0, got $RC (out: $OUT)"
teardown

# ---- case 6c (T4 near-miss): a reset moves the head block BACKWARDS ---------
setup
seed_state true false "$CHAIN_A" 99999 "v0.6.2"
write_s3 "$S3" 12
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T4 near-miss: a backwards head block (genesis reset) does not fire T4 -> exit 0" \
	|| bad "T4 near-miss: expected exit 0, got $RC (out: $OUT)"
teardown

# ---- case 7: a release-tag change is recorded, never pushed -----------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_s1 "$S1" "v0.7.0"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "release: a new tag alone -> exit 0" \
	|| bad "release: expected exit 0, got $RC (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "release: a new tag never pushes" \
	|| bad "release: expected 0 alerts, got $(n_alerts) ($(alerts))"
echo "$OUT" | grep -q 'release tag v0.6.2 -> v0.7.0 (recorded, not a trigger)' \
	&& ok "release: the move is logged with both tags" \
	|| bad "release: log line missing (out: $OUT)"
[ "$(jq -r '.observations.release_tag' "$STATE")" = "v0.7.0" ] \
	&& ok "release: the new tag is persisted for the next run" \
	|| bad "release: state still holds the old tag"
teardown

# ---- case 8: unparseable prior state fails OPEN ------------------------------
setup
printf 'not json at all' > "$STATE"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "corrupt-state: an unparseable state file fails OPEN (exit 3), never toward silence" \
	|| bad "corrupt-state: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'BASELINE' \
	&& ok "corrupt-state: reported as BASELINE, not as a fabricated T1-T4" \
	|| bad "corrupt-state: verdict missing BASELINE (out: $OUT)"
jq -e '.schema_version == 2' "$STATE" >/dev/null 2>&1 \
	&& ok "corrupt-state: the corrupt file is replaced with a valid baseline" \
	|| bad "corrupt-state: state still corrupt ($(cat "$STATE" 2>/dev/null))"
teardown

# ---- case 8b: a state file with the wrong schema_version also re-baselines ---
# THE VERDICT IS ASSERTED, NOT JUST THE EXIT CODE. See case 8c's comment for
# the mutant that made this necessary — it applies identically here.
#
# The fixture is a FULLY WELL-FORMED observations record whose only defect is
# the schema_version. That is deliberate: with a malformed record the
# field-type gate would reject it anyway, so removing the schema check alone
# would change nothing and the case could not detect it. Because every field
# here is valid and every value differs from what the fixtures serve, a
# checker that accepted schema 99 would diff against it and report T2,T3 —
# so the BASELINE assertion below is load-bearing rather than decorative.
setup
jq -n '{schema_version: 99, checked_at: "2026-08-16T02:00:00Z", consecutive_failures: 0,
        observations: {release_tag: "v0.0.1", sync_notice_present: true, mainnet_section_present: false,
                       head_block: 1, chain_ids: ["0000000000000000000000000000000000000000000000000000000000000000"],
                       pages: ["https://pulsevm.example.test/gone.md"],
                       npm_watch: [{name: "pulse-ts", present: false, version: "", official: false}],
                       npm_discovered: ["@example/gone"]}}' > "$STATE"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && echo "$OUT" | grep -q 'TRIGGER BASELINE' \
	&& ok "schema-guard: an unknown schema_version re-baselines and SAYS BASELINE, rather than mis-reading fields into a fabricated verdict" \
	|| bad "schema-guard: expected exit 3 with a BASELINE verdict, got $RC (out: $OUT)"
teardown

# ---- case 8c: observations present but a trigger field missing -> fail open --
# The first draft read the two booleans with `// empty`, which in jq collapses
# a legitimate `false` into "missing" — T1/T2 could then never observe their
# "was it true yesterday" transition. The type gate at the top of the checker
# is what makes a malformed record re-baseline instead of being read with
# silent fallbacks.
#
# THE VERDICT ASSERTION IS THE POINT OF THIS CASE, not the exit code. An
# earlier version checked only `RC -eq 3` and a reviewer's mutation walked
# straight through it: weakening the gate to a bare `type == "object"` left
# the suite 80/80 green, because the mutant still exits 3 — but for the
# opposite reason. With the empty chain_ids/pages of a malformed record it
# reports `TRIGGER T2,T3`, i.e. it FABRICATES "a new chain id and four new
# pages appeared" out of a comparison it never made. In the same mutant
# PREV_SYNC_NOTICE becomes the string "null", so the `= "true"` transition can
# never hold and T1 — the trigger the header calls the single most important
# signal — is silently disarmed forever. An exit code cannot tell those two
# worlds apart; the verdict string can.
setup
jq -n '{schema_version: 2, checked_at: "2026-08-16T02:00:00Z", consecutive_failures: 0,
        observations: {release_tag: "v0.6.2", head_block: 3406, chain_ids: [], pages: [],
                       npm_watch: [], npm_discovered: []}}' > "$STATE"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "field-guard: observations missing a boolean trigger field re-baselines (fail open)" \
	|| bad "field-guard: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'TRIGGER BASELINE' \
	&& ok "field-guard: the verdict is BASELINE — a malformed record must not be diffed into a fabricated T2/T3" \
	|| bad "field-guard: expected a BASELINE verdict, got (out: $OUT)"
echo "$OUT" | grep -qE 'TRIGGER [^:]*T[234]' \
	&& bad "field-guard: fabricated a T2/T3/T4 from a record that was never comparable (out: $OUT)" \
	|| ok "field-guard: no T2/T3/T4 claimed from an uncomparable record"
teardown

# ---- case 8d: a false boolean must survive the round trip -------------------
# Guards the `// empty` bug directly: seed mainnet_section_present=false, serve
# a page WITH a mainnet section, and require T2 to fire. If false were read as
# missing, PREV_MAINNET would not equal "false" and this would silently pass
# as exit 0.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
[ "$(jq -r '.observations.mainnet_section_present' "$STATE")" = "false" ] \
	&& ok "field-guard: the seeded state really does carry false (not null)" \
	|| bad "field-guard: seed_state did not write a false boolean"
write_s2 "$S2" notice "$CHAIN_A" mainnet
RC=0; run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 3 ] \
	&& ok "field-guard: false -> true on a boolean is detected as a transition" \
	|| bad "field-guard: expected exit 3 on a false->true transition, got $RC"
teardown

# ---- case 9: a source that never returns 200 -> exit 4, silent the first time
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
OUT="$(S2_CODE_SEQ="500 500 500" run_checker 2>&1)"; RC=$?
[ "$RC" -eq 4 ] \
	&& ok "exit4: a source stuck at 500 -> exit 4" \
	|| bad "exit4: expected exit 4, got $RC (out: $OUT)"
[ "$(calls s2)" -eq 3 ] \
	&& ok "exit4: a 5xx spends the full retry budget (3 attempts)" \
	|| bad "exit4: expected 3 attempts on 5xx, got $(calls s2)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "exit4: the FIRST failed run does not page (a third party having a bad morning is not an alert)" \
	|| bad "exit4: expected 0 alerts on failure #1, got $(n_alerts) ($(alerts))"
[ "$(jq -r '.consecutive_failures' "$STATE")" = "1" ] \
	&& ok "exit4: the failure counter incremented" \
	|| bad "exit4: expected consecutive_failures=1, got $(jq -r '.consecutive_failures' "$STATE" 2>/dev/null)"
[ "$(jq -r '.observations.head_block' "$STATE")" = "3406" ] \
	&& ok "exit4: the previous observations survive the failure (no forced re-baseline next run)" \
	|| bad "exit4: observations lost on failure ($(cat "$STATE" 2>/dev/null))"
teardown

# ---- case 9b: a 4xx is a verdict, not a blip — no retry ---------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
RC=0; S1_CODE=403 run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] \
	&& ok "exit4-4xx: GitHub's 403 rate-limit answer -> exit 4" \
	|| bad "exit4-4xx: expected exit 4, got $RC"
[ "$(calls s1)" -eq 1 ] \
	&& ok "exit4-4xx: a 4xx is NOT retried (1 request, not 3) — retrying an exhausted rate limit is impolite and cannot succeed" \
	|| bad "exit4-4xx: expected exactly 1 attempt on 4xx, got $(calls s1)"
teardown

# ---- case 9c: the third consecutive failure pages exactly once --------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2" "" 2
RC=0; S2_CODE=500 run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] \
	&& ok "outage-page: still exit 4 on failure #3" \
	|| bad "outage-page: expected exit 4, got $RC"
[ "$(n_alerts)" -eq 1 ] \
	&& ok "outage-page: failure #3 pages exactly once" \
	|| bad "outage-page: expected 1 alert on failure #3, got $(n_alerts) ($(alerts))"
alerts | grep -q '^default|' \
	&& ok "outage-page: the outage page is 'default' priority, not 'high'" \
	|| bad "outage-page: wrong priority ($(alerts))"
teardown

# ---- case 9d: a FOURTH consecutive failure stays quiet ----------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2" "" 3
RC=0; S2_CODE=500 run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] \
	&& ok "outage-quiet: still exit 4 on failure #4" \
	|| bad "outage-quiet: expected exit 4, got $RC"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "outage-quiet: one page per outage, not one per day (failure #4 is silent)" \
	|| bad "outage-quiet: expected 0 alerts on failure #4, got $(n_alerts) ($(alerts))"
teardown

# ---- case 9e: a successful run re-arms the outage page ---------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2" "" 7
run_checker >/dev/null 2>&1
[ "$(jq -r '.consecutive_failures' "$STATE")" = "0" ] \
	&& ok "outage-rearm: recovery resets the counter so the next outage can page again" \
	|| bad "outage-rearm: expected consecutive_failures=0 after a good run"
teardown

# ---- case 10: 200 with an unparseable body -> exit 5 ------------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
printf '{"chain":"pulse","health":[]}' > "$S3"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 5 ] \
	&& ok "exit5: health payload without head_block_num -> exit 5" \
	|| bad "exit5: expected exit 5, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'no numeric head_block_num' \
	&& ok "exit5: the log names which source failed to parse" \
	|| bad "exit5: log does not name the source (out: $OUT)"
teardown

# ---- case 10b: 200 without a release tag -> exit 5 --------------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
printf '{"message":"Not Found"}' > "$S1"
RC=0; run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 5 ] \
	&& ok "exit5: releases payload without .tag_name -> exit 5" \
	|| bad "exit5: expected exit 5, got $RC"
teardown

# ---- case 10c: 200 with an empty endpoints body -> exit 5 ------------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
: > "$S2"
RC=0; run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 5 ] \
	&& ok "exit5: an empty 200 body (a docs shell instead of the document) -> exit 5" \
	|| bad "exit5: expected exit 5, got $RC"
teardown

# ---- case 10d: S4 200 with no parseable page links -> exit 5 ----------------
# The consequence if this guard were ever removed is specific and bad: an
# llms.txt format change (or a 200 error page) would record `pages: []`, and
# the NEXT healthy run would diff against that empty set and fire T3 naming
# all ~46 pages as new. Refusing to record an unparseable page list is what
# stops one upstream hiccup from manufacturing a trigger a day later.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
printf '<html><body>Service Temporarily Unavailable</body></html>\n' > "$S4"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 5 ] \
	&& ok "exit5: an llms.txt with no parseable page links -> exit 5 (never records an empty page set)" \
	|| bad "exit5: expected exit 5, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'no page links could be parsed' \
	&& ok "exit5: the log names S4 as the source that failed to parse" \
	|| bad "exit5: log does not name S4 (out: $OUT)"
[ "$(jq -r '.observations.pages | length' "$STATE")" -eq 4 ] \
	&& ok "exit5: the previous page set survives — the next run cannot fire a fabricated T3 against an empty baseline" \
	|| bad "exit5: page set was overwritten ($(jq -c '.observations.pages' "$STATE" 2>/dev/null))"
teardown

# ---- case 10e: S4 200 with a completely empty body -> exit 5 ----------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
: > "$S4"
RC=0; run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 5 ] \
	&& ok "exit5: an empty llms.txt body -> exit 5" \
	|| bad "exit5: expected exit 5, got $RC"
teardown

# ---- case 10f: the side-effects library is unreadable -> exit 6 -------------
# Exercised on a COPY of the checker placed in a directory with no lib/
# sibling, so the real scripts/lib/side-effects.sh is never touched or moved.
setup
COPY_DIR="$BASE/nolib"
mkdir -p "$COPY_DIR"
cp "$CHECKER" "$COPY_DIR/check-pulsevm-upstream.sh"
OUT="$(bash "$COPY_DIR/check-pulsevm-upstream.sh" 2>&1)"; RC=$?
[ "$RC" -eq 6 ] \
	&& ok "exit6: an unreadable side-effects library refuses to run (exit 6) rather than silently un-gating" \
	|| bad "exit6: expected exit 6, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'side-effects library not readable' \
	&& ok "exit6: the refusal names the missing library" \
	|| bad "exit6: refusal message missing (out: $OUT)"
teardown

# ---- case 11a (DRY): the repo's REAL logs/ is untouched ----------------------
# Deliberately runs against the checker's OWN default LOG and STATE paths — no
# override — so the containment claim is measured where it matters, and
# compares a listing plus per-file checksums of logs/ before and after.
# Nothing is created and nothing is deleted: if a developer (or an earlier
# suite) has real files sitting there, the comparison still holds.
#
# --verbose on purpose. The two DRY notes asserted here are the ones this run
# emits UNCONDITIONALLY: state_write() is reached on every successful path,
# and --verbose guarantees at least one log() call whatever the verdict. The
# notify note is NOT asserted here, because whether a trigger fires depends on
# whatever state file happens to already exist — case 11b covers that on a
# path we control. An earlier draft asserted exit 3 here and passed only
# because logs/ happened to be empty; it went red the moment a previous run
# left a state file behind, which is precisely the ambient coupling a
# containment test must not have.
setup
LOGS_DIR="${REPO_ROOT}/logs"
BEFORE="$(ls -A "$LOGS_DIR" 2>/dev/null | sort)"
BEFORE_SUM="$(cd "$LOGS_DIR" 2>/dev/null && find . -type f -exec shasum {} + 2>/dev/null | sort)"
OUT="$(FY_LIVE='' FYD_CURL="$STUB" FYD_NOTIFY="$NOTIFY_STUB" \
	PULSEVM_RELEASES_URL="https://example.test/repos/pulsevm/releases/latest" \
	PULSEVM_ENDPOINTS_URL="https://example.test/network/endpoints.md" \
	PULSEVM_HEALTH_URL="https://example.test/v2/health" \
	PULSEVM_LLMS_URL="https://example.test/llms.txt" \
	PULSEVM_NPM_REGISTRY="https://example.test/npm" \
	PULSEVM_NPM_SEARCH_URL="https://example.test/npm-search?text=pulsevm&size=50" \
	S1_BODY="$S1" S2_BODY="$S2" S3_BODY="$S3" S4_BODY="$S4" \
	NPM_PULSE_TS_BODY="$NPM_TS" NPM_PULSE_TS_CODE=200 \
	NPMSEARCH_BODY="$NPM_SEARCH" \
	STUB_STATE_DIR="$BASE" FYD_RETRY_SLEEP=0 \
	bash "$CHECKER" --verbose 2>&1)"
AFTER="$(ls -A "$LOGS_DIR" 2>/dev/null | sort)"
AFTER_SUM="$(cd "$LOGS_DIR" 2>/dev/null && find . -type f -exec shasum {} + 2>/dev/null | sort)"
[ "$BEFORE" = "$AFTER" ] \
	&& ok "dry: logs/ gained no file (no log, no state, no stray temp) without FY_LIVE=1" \
	|| bad "dry: logs/ changed — before=[$BEFORE] after=[$AFTER]"
[ "$BEFORE_SUM" = "$AFTER_SUM" ] \
	&& ok "dry: every existing file under logs/ is byte-identical afterwards" \
	|| bad "dry: an existing logs/ file was modified"
echo "$OUT" | grep -q 'DRY: would record the pulsevm upstream state' \
	&& ok "dry: the suppressed state write announces itself" \
	|| bad "dry: missing the state-write DRY line (out: $OUT)"
echo "$OUT" | grep -q 'DRY: would append this run.s lines to' \
	&& ok "dry: the suppressed file log announces itself" \
	|| bad "dry: missing the log DRY line (out: $OUT)"
[ "$(echo "$OUT" | grep -c 'DRY: would append this run')" -eq 1 ] \
	&& ok "dry: the log DRY note is latched (one line per run, not one per log line)" \
	|| bad "dry: expected exactly 1 log DRY note, got $(echo "$OUT" | grep -c 'DRY: would append this run')"
teardown

# ---- case 11b (DRY): the verdict survives dry mode; nothing is written ------
# Same dry run, but on sandbox paths this suite owns and knows are absent, so
# the trigger — and therefore the exit code and the suppressed notification —
# are deterministic.
setup
OUT="$(FY_LIVE_OVERRIDE='' run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "dry: the verdict and exit code are unchanged by dry mode (still exit 3)" \
	|| bad "dry: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'TRIGGER BASELINE' \
	&& ok "dry: detection still happens — a dry tick is not a blind tick" \
	|| bad "dry: no verdict emitted (out: $OUT)"
echo "$OUT" | grep -q 'DRY: would notify' \
	&& ok "dry: the suppressed ntfy push announces itself" \
	|| bad "dry: missing the notify DRY line (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "dry: no notification actually reached the delegate" \
	|| bad "dry: the notify stub was invoked ($(alerts))"
[ ! -e "$STATE" ] \
	&& ok "dry: the state file was not created" \
	|| bad "dry: a state file was written in dry mode ($(cat "$STATE" 2>/dev/null))"
[ ! -e "$LOG" ] \
	&& ok "dry: the log file was not created" \
	|| bad "dry: a log file was written in dry mode"
[ -z "$(find "$(dirname "$STATE")" -name '.pulsevm-upstream.*' 2>/dev/null)" ] \
	&& ok "dry: no stray mktemp artifact left behind (the whole write body is gated, not just the rename)" \
	|| bad "dry: a temp file survived the dry run"
teardown

# =============================================================================
# T5 — the npm surface
# =============================================================================
# The condition that motivated S5: pulsevm.dev tells a newcomer that step one
# is `pulse-ts create-key`, and on npm that name belongs to an unrelated
# third-party package. So the documented first command installs a stranger's
# code, and the moment that stops being true is worth knowing about.

# ---- case 14 (T5): a watched name goes from unpublished to published --------
# Published by someone with no organisation token, which is the DEFAULT
# channel: the name being taken is worth reading about, not worth paging over.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm "$NPM_TSC" "pulse-tsc" "0.1.0" "$STRANGER_USER" "$STRANGER_MAIL"
OUT="$(NPM_TSC_CODE=200 run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T5: an unpublished watched name appearing on npm -> exit 3" \
	|| bad "T5: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'TRIGGER T5' \
	&& ok "T5: verdict names T5" \
	|| bad "T5: verdict missing T5 (out: $OUT)"
alerts | grep -q 'pulse-tsc' \
	&& ok "T5: alert names the package" \
	|| bad "T5: alert does not name the package ($(alerts))"
alerts | grep -q '^default|' \
	&& ok "T5: a publish under an unaffiliated identity is DEFAULT" \
	|| bad "T5: expected default priority ($(alerts))"
assert_alert_shape "T5"
assert_no_overclaim "T5"
[ "$(jq -r '.observations.npm_watch[] | select(.name == "pulse-tsc") | .version' "$STATE")" = "0.1.0" ] \
	&& ok "T5: the new version is persisted for the next run" \
	|| bad "T5: state did not record the published version ($(jq -c '.observations.npm_watch' "$STATE" 2>/dev/null))"
teardown

# ---- case 14b (T5 near-miss): an absent name stays absent -------------------
# Also the politeness assertion. A 404 is a VERDICT, so fetch()'s no-retry rule
# means an unpublished name costs exactly one request per daily run — not
# three. And it must not be mistaken for an outage: exit 0, not exit 4.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T5 near-miss: a name that is 404 in BOTH runs -> exit 0 (a 404 is data, not an outage)" \
	|| bad "T5 near-miss: expected exit 0, got $RC (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "T5 near-miss: no alert" \
	|| bad "T5 near-miss: expected 0 alerts, got $(n_alerts) ($(alerts))"
[ "$(calls npm_PULSE_TSC)" -eq 1 ] \
	&& ok "T5 near-miss: an unpublished name costs exactly 1 request (a 4xx is not retried)" \
	|| bad "T5 near-miss: expected 1 request for the 404 name, got $(calls npm_PULSE_TSC)"
[ "$(jq -r '.observations.npm_watch[] | select(.name == "pulse-tsc") | .present' "$STATE")" = "false" ] \
	&& ok "T5 near-miss: absence is RECORDED as a fact, so the next run can diff against it" \
	|| bad "T5 near-miss: absence was not recorded ($(jq -c '.observations.npm_watch' "$STATE" 2>/dev/null))"
teardown

# ---- case 14c (T5): an already-published name changes hands -----------------
# The shape a takeover of `pulse-ts` would have, and the only T5 path that can
# reach `high` without a new package appearing.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm "$NPM_TS" "pulse-ts" "3.0.0" "$OFFICIAL_USER" "$OFFICIAL_MAIL" "https://github.com/MetalBlockchain/pulse-ts"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T5 handover: an owner newly matching the affiliation pattern -> exit 3" \
	|| bad "T5 handover: expected exit 3, got $RC (out: $OUT)"
alerts | grep -q 'changing hands' \
	&& ok "T5 handover: the alert distinguishes a takeover from a fresh publish" \
	|| bad "T5 handover: alert does not name the sub-condition ($(alerts))"
alerts | grep -q '^high|' \
	&& ok "T5 handover: an affiliated identity on a documented name is HIGH" \
	|| bad "T5 handover: expected high priority ($(alerts))"
alerts | grep -q 'NOT ESTABLISHED: who actually holds it now' \
	&& ok "T5 handover: a pattern match is reported as evidence, never as proof of provenance" \
	|| bad "T5 handover: alert asserts officialness ($(alerts))"
assert_no_overclaim "T5 handover"
teardown

# ---- case 14d (T5 hysteresis): an already-affiliated name does not re-page ---
setup
SEED_NPM_WATCH='[{"name":"pulse-ts","present":true,"version":"3.0.0","official":true},
                 {"name":"pulse-tsc","present":false,"version":"","official":false}]'
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm "$NPM_TS" "pulse-ts" "3.0.0" "$OFFICIAL_USER" "$OFFICIAL_MAIL"
RC=0; run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T5 hysteresis: an owner affiliated in BOTH runs pages only on the transition" \
	|| bad "T5 hysteresis: expected exit 0 on the second affiliated run, got $RC"
teardown

# ---- case 14e (T5): a version bump alone is recorded, never pushed ----------
# Same rule as the release tag, and it has teeth here: `pulse-ts` shipped
# twelve versions inside one afternoon. A version counter is not a change of
# surface.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm "$NPM_TS" "pulse-ts" "2.2.0" "$STRANGER_USER" "$STRANGER_MAIL"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T5 version: a new npm version alone -> exit 0" \
	|| bad "T5 version: expected exit 0, got $RC (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "T5 version: a new npm version never pushes" \
	|| bad "T5 version: expected 0 alerts, got $(n_alerts) ($(alerts))"
echo "$OUT" | grep -q 'npm package pulse-ts 2.1.1 -> 2.2.0 (recorded, not a trigger)' \
	&& ok "T5 version: the move is logged with both versions" \
	|| bad "T5 version: log line missing (out: $OUT)"
teardown

# ---- case 14f (T5): an unpublish is recorded, never pushed ------------------
# A hazard going DOWN, not an obligation appearing: the documented command
# starts failing loudly instead of installing someone else's code.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
OUT="$(NPM_TS_CODE=404 run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T5 unpublish: a watched package disappearing -> exit 0" \
	|| bad "T5 unpublish: expected exit 0, got $RC (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "T5 unpublish: a disappearance never pushes" \
	|| bad "T5 unpublish: expected 0 alerts, got $(n_alerts) ($(alerts))"
echo "$OUT" | grep -q 'no longer published' \
	&& ok "T5 unpublish: the disappearance is logged with the version it had" \
	|| bad "T5 unpublish: log line missing (out: $OUT)"
teardown

# ---- case 14f2 (T5): losing an affiliation match is recorded, never pushed --
# The inverse of case 14c. It returns the name to exactly the state this whole
# watch was built around — a documented name in unaffiliated hands — so it is
# history worth having, not an obligation. A run that ALSO bumps the version
# must log both, which is why the recorded-only movements sit outside the
# trigger chain.
setup
SEED_NPM_WATCH='[{"name":"pulse-ts","present":true,"version":"3.0.0","official":true},
                 {"name":"pulse-tsc","present":false,"version":"","official":false}]'
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm "$NPM_TS" "pulse-ts" "3.1.0" "$STRANGER_USER" "$STRANGER_MAIL"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T5 de-affiliation: a name losing its affiliation match -> exit 0" \
	|| bad "T5 de-affiliation: expected exit 0, got $RC (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "T5 de-affiliation: never pushes" \
	|| bad "T5 de-affiliation: expected 0 alerts, got $(n_alerts) ($(alerts))"
echo "$OUT" | grep -q 'no longer matches' \
	&& ok "T5 de-affiliation: the loss is logged" \
	|| bad "T5 de-affiliation: no log line (out: $OUT)"
echo "$OUT" | grep -q 'npm package pulse-ts 3.0.0 -> 3.1.0' \
	&& ok "T5 de-affiliation: a simultaneous version move is logged TOO, not shadowed by it" \
	|| bad "T5 de-affiliation: the version move was swallowed (out: $OUT)"
teardown

# ---- case 14g (T5 discovery): THE reason "pulsevm" is not in the pattern ----
# A stranger publishing `pulsevm-tools` matches the SEARCH (that is the whole
# point of searching for the subject) but must NOT match the AFFILIATION
# pattern — otherwise any admirer's package walks onto the `high` channel and
# trains it into noise, which is the harm the PRIORITY SPLIT exists to stop.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm_search "$NPM_SEARCH" \
	"${OFFICIAL_PKG}|${OFFICIAL_USER}|${OFFICIAL_MAIL}" \
	"pulsevm-tools|${STRANGER_USER}|${STRANGER_MAIL}"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T5 discovery: a package new to the search set -> exit 3" \
	|| bad "T5 discovery: expected exit 3, got $RC (out: $OUT)"
alerts | grep -q 'pulsevm-tools' \
	&& ok "T5 discovery: alert names the new package" \
	|| bad "T5 discovery: alert does not name it ($(alerts))"
alerts | grep -q '^default|' \
	&& ok "T5 discovery: a package merely NAMED after PulseVM is DEFAULT — the subject word is not an affiliation" \
	|| bad "T5 discovery: expected default priority — 'pulsevm' in a name must not read as official ($(alerts))"
assert_alert_shape "T5 discovery"
assert_no_overclaim "T5 discovery"
teardown

# ---- case 14h (T5 discovery): an affiliated scope escalates -----------------
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm_search "$NPM_SEARCH" \
	"${OFFICIAL_PKG}|${OFFICIAL_USER}|${OFFICIAL_MAIL}" \
	"@metalblockchain/pulse-cli|${OFFICIAL_USER}|${OFFICIAL_MAIL}"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T5 discovery: an affiliated new package -> exit 3" \
	|| bad "T5 discovery: expected exit 3, got $RC (out: $OUT)"
alerts | grep -q '^high|' \
	&& ok "T5 discovery: an organisation-scoped new package is HIGH" \
	|| bad "T5 discovery: expected high priority ($(alerts))"
assert_no_overclaim "T5 discovery affiliated"
teardown

# ---- case 14h2 (T5 discovery): a legacy uppercase name is not dropped -------
# npm has refused uppercase in NEW package names since 2017, but names created
# before that keep it. The client-side safety filter must not silently discard
# one — that would be a hole in the watch dressed up as input validation.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm_search "$NPM_SEARCH" \
	"${OFFICIAL_PKG}|${OFFICIAL_USER}|${OFFICIAL_MAIL}" \
	"PulseVM-Legacy|${STRANGER_USER}|${STRANGER_MAIL}"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && alerts | grep -q 'PulseVM-Legacy' \
	&& ok "T5 discovery: a pre-2017-style uppercase package name still reaches the diff" \
	|| bad "T5 discovery: an uppercase name was filtered out of the discovery set (rc=$RC, $(alerts))"
alerts | grep -q '^default|' \
	&& ok "T5 discovery: an uppercase name is still judged on affiliation, not on shape" \
	|| bad "T5 discovery: expected default priority ($(alerts))"
teardown

# ---- case 14i (T5 discovery near-miss): a package leaving is not a new one ---
setup
SEED_NPM_FOUND="$(jq -nc --arg p "$OFFICIAL_PKG" '[$p, "pulsevm-gone"]')"
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T5 discovery near-miss: a package dropping out of the search set is not a new package -> exit 0" \
	|| bad "T5 discovery near-miss: expected exit 0, got $RC (out: $OUT)"
teardown

# ---- case 14j: the search endpoint gets NO 404 exemption --------------------
# A 404 on a package means "not published". A 404 on the search API means the
# API moved, and reading nothing must never look like reading zero packages.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
RC=0; NPMSEARCH_CODE=404 run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 4 ] \
	&& ok "T5: a 404 from the SEARCH endpoint is an outage (exit 4), not an empty registry" \
	|| bad "T5: expected exit 4 from a 404 search, got $RC"
teardown

# ---- case 14k: a search 200 with zero results never records an empty set ----
# Identical reasoning to case 10d: recording an empty set would make the NEXT
# healthy run fire T5 and name every package as new.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
printf '{"total":0,"objects":[]}' > "$NPM_SEARCH"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 5 ] \
	&& ok "T5: a search 200 with no parseable package names -> exit 5" \
	|| bad "T5: expected exit 5, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'no package names could be parsed' \
	&& ok "T5: the log names S5b as the source that failed to parse" \
	|| bad "T5: log does not name S5b (out: $OUT)"
[ "$(jq -r '.observations.npm_discovered | length' "$STATE")" -eq 1 ] \
	&& ok "T5: the previous discovery set survives — the next run cannot fire a fabricated T5" \
	|| bad "T5: discovery set was overwritten ($(jq -c '.observations.npm_discovered' "$STATE" 2>/dev/null))"
teardown

# ---- case 14l: a name ADDED to the watch list is not an instant trigger -----
# The state file is perfectly usable and exactly one name is uncomparable. That
# is not a baseline, and firing on it would page the operator about an edit
# they just made and are currently looking at.
setup
SEED_NPM_WATCH='[{"name":"pulse-ts","present":true,"version":"2.1.1","official":false}]'
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm "$NPM_TSC" "pulse-tsc" "0.1.0" "$STRANGER_USER" "$STRANGER_MAIL"
OUT="$(NPM_TSC_CODE=200 run_checker 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "T5 new-name: a watch-list addition with no history does not fire" \
	|| bad "T5 new-name: expected exit 0, got $RC (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "T5 new-name: no alert for a name the operator just added" \
	|| bad "T5 new-name: expected 0 alerts, got $(n_alerts) ($(alerts))"
echo "$OUT" | grep -q 'first observation of watched npm package pulse-tsc' \
	&& ok "T5 new-name: the missing history is SAID OUT LOUD rather than silently treated as absent" \
	|| bad "T5 new-name: no first-observation log line (out: $OUT)"
teardown

# ---- case 14m (baseline): the current-only fact is evaluated, diffs are not --
setup
write_npm "$NPM_TS" "pulse-ts" "3.0.0" "$OFFICIAL_USER" "$OFFICIAL_MAIL"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T5 baseline: a first run against an already-affiliated name -> exit 3" \
	|| bad "T5 baseline: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'TRIGGER BASELINE,T5' \
	&& ok "T5 baseline: 'it is affiliated RIGHT NOW' needs no history, so it is reported alongside BASELINE" \
	|| bad "T5 baseline: expected BASELINE,T5 in the verdict (out: $OUT)"
echo "$OUT" | grep -q "and so are T5's transitions" \
	&& ok "T5 baseline: the transitions are declared DEFERRED, not claimed as fired" \
	|| bad "T5 baseline: missing the T5 deferral disclaimer (out: $OUT)"
alerts | grep -q '^high|' \
	&& ok "T5 baseline: escalates to high" \
	|| bad "T5 baseline: expected high priority ($(alerts))"
assert_no_overclaim "T5 baseline"
teardown

# ---- case 14n: an unusable watch list falls back LOUDLY, never per entry ----
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
OUT="$(PULSEVM_NPM_PACKAGES='pulse-ts Not-A-Valid*Name' run_checker 2>&1)"; RC=$?
echo "$OUT" | grep -q 'using the default list' \
	&& ok "config: a watch list containing an invalid npm name falls back to the default, loudly" \
	|| bad "config: no warning for an invalid watch list (out: $OUT)"
[ "$RC" -eq 0 ] \
	&& ok "config: the fallback list still produces a normal verdict" \
	|| bad "config: expected exit 0 after the fallback, got $RC (out: $OUT)"
urls | grep -q 'Not-A-Valid' \
	&& bad "config: the rejected name was still requested" \
	|| ok "config: the rejected name was never put into a URL"
teardown

# ---- case 14o: a scoped name is one path segment, so the slash is encoded ----
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
OUT="$(PULSEVM_NPM_PACKAGES='@pulsevm/pulse-ts' run_checker 2>&1)"; RC=$?
urls | grep -q 'npm/@pulsevm%2Fpulse-ts/latest' \
	&& ok "url: a scoped package name is percent-encoded (the registry takes it as ONE path segment)" \
	|| bad "url: scoped name not encoded ($(urls | grep npm/ | head -3))"
[ "$RC" -eq 0 ] \
	&& ok "url: an unfixtured scoped name reads as unpublished, with no history, so nothing fires" \
	|| bad "url: expected exit 0, got $RC (out: $OUT)"
teardown

# ---- case 14p: the SCOPE alone is enough to read as affiliated --------------
# The header claims an @metalblockchain scope is itself the strongest signal
# available, so the fingerprint has to include the package NAME and not just
# its maintainers. This fixture is deliberately published by the stranger
# identity: if .name were dropped from the fingerprint, nothing else here
# would match and the case would go quiet. (Stub fixture variables are named
# after the decoded package name — @metalblockchain/pulsevm-js slugs to
# _METALBLOCKCHAIN_PULSEVM_JS.)
setup
SEED_NPM_WATCH="$(jq -nc --arg p "$OFFICIAL_PKG" '[{name: $p, present: false, version: "", official: false}]')"
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm "$BASE/npm-official.json" "$OFFICIAL_PKG" "0.0.53" "$STRANGER_USER" "$STRANGER_MAIL"
OUT="$(PULSEVM_NPM_PACKAGES="$OFFICIAL_PKG" \
	NPM__METALBLOCKCHAIN_PULSEVM_JS_BODY="$BASE/npm-official.json" \
	NPM__METALBLOCKCHAIN_PULSEVM_JS_CODE=200 \
	run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
	&& ok "T5 scope: an organisation-scoped name appearing -> exit 3" \
	|| bad "T5 scope: expected exit 3, got $RC (out: $OUT)"
alerts | grep -q '^high|' \
	&& ok "T5 scope: the SCOPE alone reads as affiliated — the fingerprint includes the package name, not only its maintainers" \
	|| bad "T5 scope: expected high priority from the scope alone ($(alerts))"
teardown

# ---- case 14q (config): the SHIPPED default pattern, not a test override ----
# The affiliation pattern is never overridden anywhere in this suite, so every
# T5 case above exercises the real default. This asserts the one property that
# default has to have and that a priority assertion alone cannot pin down:
# the subject word must not be in it. Adding "pulsevm" here would route any
# admirer's `pulsevm-*` package onto the high channel.
DEFAULT_RE_LINE="$(grep -n "^NPM_OFFICIAL_RE_DEFAULT=" "$CHECKER" | head -1)"
[ -n "$DEFAULT_RE_LINE" ] \
	&& ok "config: the checker ships a default affiliation pattern" \
	|| bad "config: no NPM_OFFICIAL_RE_DEFAULT in the checker"
printf '%s' "$DEFAULT_RE_LINE" | grep -qi 'pulsevm' \
	&& bad "config: the default affiliation pattern contains the SUBJECT word 'pulsevm' — a stranger's pulsevm-* package would page high (${DEFAULT_RE_LINE})" \
	|| ok "config: the default affiliation pattern is organisation tokens only"
# The needle is assembled at runtime so this assertion cannot match itself.
# The gap it closes is real and was found by mutation: while run_checker set
# the pattern explicitly, adding the subject word to the checker's default
# left the whole suite green, because no case ever reached that default.
#
# Scoped to run_checker's own environment list, which is what every T5 case
# goes through. One case (14s) DOES pass a pattern, on purpose, to exercise the
# uncompilable-ERE fallback; that is a case opting in, not the harness opting
# every case out, and the difference is exactly what this assertion protects.
OVERRIDE_NEEDLE="PULSEVM_NPM""_OFFICIAL_RE="
awk '/^run_checker\(\) \{/,/^\}/' "$0" | grep -q "$OVERRIDE_NEEDLE" \
	&& bad "config: run_checker sets the affiliation pattern for every case, so none of the T5 cases test the shipped default" \
	|| ok "config: run_checker never sets the affiliation pattern — the T5 cases exercise the shipped default"

# ---- case 14s (config): an uncompilable affiliation pattern is not silent ---
# grep exits 2 on a pattern it cannot compile, which reads as "no match"
# everywhere — that would classify every package as unaffiliated and silently
# disarm the only T5 sub-condition that reaches `high`. The fallback has to be
# loud, and the high path has to still work after it.
setup
seed_state true false "$CHAIN_A" 3406 "v0.6.2"
write_npm "$NPM_TS" "pulse-ts" "3.0.0" "$OFFICIAL_USER" "$OFFICIAL_MAIL"
OUT="$(PULSEVM_NPM_OFFICIAL_RE='metal[block' run_checker 2>&1)"; RC=$?
echo "$OUT" | grep -q 'is not a usable ERE' \
	&& ok "config: an uncompilable affiliation pattern is reported, not swallowed" \
	|| bad "config: no warning for an uncompilable pattern (out: $OUT)"
[ "$RC" -eq 3 ] && alerts | grep -q '^high|' \
	&& ok "config: after the fallback the affiliation check still works (a bad pattern does not disarm the high path)" \
	|| bad "config: expected exit 3 at high priority after the ERE fallback, got $RC ($(alerts))"
teardown

# ---- case 14t: a schema-version-1 state file re-baselines -------------------
# The concrete deploy consequence of adding S5: every host that already has a
# state file written by the S1-S4 checker gets exactly one BASELINE page and
# then goes quiet. Asserted here rather than left as a header claim, because a
# version-1 record is well-formed for everything EXCEPT the two npm fields and
# would otherwise be the tempting thing to read field-by-field.
setup
jq -n --arg c "$CHAIN_A" '{schema_version: 1, checked_at: "2026-08-16T02:00:00Z", consecutive_failures: 0,
        observations: {release_tag: "v0.6.2", sync_notice_present: true, mainnet_section_present: false,
                       head_block: 3406, chain_ids: [$c],
                       pages: ["https://pulsevm.example.test/agents.md","https://pulsevm.example.test/build/api.md","https://pulsevm.example.test/compare/antelope.md","https://pulsevm.example.test/network/endpoints.md"]}}' > "$STATE"
OUT="$(run_checker 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && echo "$OUT" | grep -q 'TRIGGER BASELINE' \
	&& ok "schema-2: a state file from the S1-S4 era re-baselines and SAYS BASELINE — it cannot answer T5's 'was this name published yesterday'" \
	|| bad "schema-2: expected exit 3 with a BASELINE verdict, got $RC (out: $OUT)"
echo "$OUT" | grep -qE 'TRIGGER [^:]*T[2345]' \
	&& bad "schema-2: fabricated a trigger from a record that predates the fields it needs (out: $OUT)" \
	|| ok "schema-2: no trigger claimed from a record that predates S5"
[ "$(jq -r '.schema_version' "$STATE")" = "2" ] \
	&& ok "schema-2: the old file is replaced with a version-2 baseline" \
	|| bad "schema-2: state was not rewritten ($(jq -c . "$STATE" 2>/dev/null))"
teardown

# ---- case 14r (hermeticity): no request ever leaves for a real host ---------
# The suite serves every source from a stub; this proves it, rather than
# assuming it. npm's registry is a public good and a test suite has no business
# polling it.
setup
run_checker >/dev/null 2>&1
[ -z "$(urls | grep -v 'example\.test' || true)" ] \
	&& ok "hermetic: every request went to example.test — the suite never touches a real registry or docs site" \
	|| bad "hermetic: a request escaped to a real host ($(urls | grep -v 'example\.test' | head -3))"
[ "$(urls | grep -c 'example.test')" -eq 7 ] \
	&& ok "hermetic: a default run makes exactly 7 requests (S1-S4, two watched names, one search)" \
	|| bad "hermetic: expected 7 requests on a clean run, got $(urls | grep -c 'example.test')"
teardown

# ---- case 12 (shape): the checker never names an /ext/bc/ URL ---------------
# scripts/broadcast-guard.sh blocks that URL shape in any command line,
# read-only queries included. The checker is designed to have no reason to go
# near it; this asserts the design, not just the current text.
if grep -n '/ext/bc/' "$CHECKER" >/dev/null 2>&1; then
	bad "shape: checker names an /ext/bc/ URL — it must take every value from GitHub, the docs site, and Hyperion /v2 instead"
else
	ok "shape: checker names no /ext/bc/ URL (structurally cannot collide with broadcast-guard)"
fi
if grep -nE '/ext/(P|X)([^A-Za-z0-9]|$)' "$CHECKER" >/dev/null 2>&1; then
	bad "shape: checker names a bare /ext/P or /ext/X alias path"
else
	ok "shape: checker names no bare /ext/P or /ext/X alias path"
fi

# ---- case 13 (shape): side effects go through the library, not around it ----
grep -q 'lib/side-effects.sh' "$CHECKER" \
	&& ok "wiring: checker sources scripts/lib/side-effects.sh" \
	|| bad "wiring: checker does not source the side-effects library"
grep -q 'fyd_notify' "$CHECKER" \
	&& ok "wiring: notifications go through fyd_notify" \
	|| bad "wiring: no fyd_notify call"
grep -q 'fyd_live_run' "$CHECKER" \
	&& ok "wiring: the state write goes through fyd_live_run" \
	|| bad "wiring: no fyd_live_run call"
if grep -vE '^\s*#' "$CHECKER" | grep -qE '(^|[^a-z_])bash[[:space:]]+.*notify\.sh'; then
	bad "wiring: checker calls notify.sh directly, bypassing the FY_LIVE gate"
else
	ok "wiring: no direct notify.sh invocation (the gate cannot be bypassed)"
fi
if grep -vE '^\s*#' "$CHECKER" | grep -q 'push-to-web-host'; then
	bad "wiring: checker invokes push-to-web-host.sh — this monitor publishes nothing"
else
	ok "wiring: no push-to-web-host.sh call (this monitor publishes nothing)"
fi

# ---- summary ---------------------------------------------------------------
echo "test-pulsevm-upstream.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
