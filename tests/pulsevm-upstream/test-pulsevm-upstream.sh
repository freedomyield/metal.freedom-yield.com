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
S1=""; S2=""; S3=""; S4=""

setup() {
	BASE="$(mktemp -d -t pulsevm-upstream-test.XXXXXX)"
	STUB="$BASE/curl-stub.sh"
	LOG="$BASE/pulsevm-upstream.log"
	STATE="$BASE/pulsevm-upstream-state.json"
	NOTIFY_STUB="$BASE/notify-stub.sh"
	NOTIFY_LOG="$BASE/notify.log"
	S1="$BASE/s1.json"; S2="$BASE/s2.md"; S3="$BASE/s3.json"; S4="$BASE/s4.txt"

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
case "$url" in
	*releases*)  key=s1; body="${S1_BODY:-/dev/null}"; code="${S1_CODE:-200}"; seq="${S1_CODE_SEQ:-}" ;;
	*endpoints*) key=s2; body="${S2_BODY:-/dev/null}"; code="${S2_CODE:-200}"; seq="${S2_CODE_SEQ:-}" ;;
	*health*)    key=s3; body="${S3_BODY:-/dev/null}"; code="${S3_CODE:-200}"; seq="${S3_CODE_SEQ:-}" ;;
	*llms*)      key=s4; body="${S4_BODY:-/dev/null}"; code="${S4_CODE:-200}"; seq="${S4_CODE_SEQ:-}" ;;
	*)           key=unknown; body=/dev/null; code=404; seq="" ;;
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

	# Default fixtures = the upstream as measured on 2026-08-17.
	write_s1 "$S1" "v0.6.2"
	write_s2 "$S2" notice "$CHAIN_A" no-mainnet
	write_s3 "$S3" 3406
	write_s4 "$S4"
}
teardown() { rm -rf "$BASE"; BASE=""; }

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
seed_state() {
	local sync="$1" mainnet="$2" chain="$3" head="$4" tag="$5" extra="${6:-}" consec="${7:-0}"
	local pages='["https://pulsevm.example.test/agents.md","https://pulsevm.example.test/build/api.md","https://pulsevm.example.test/compare/antelope.md","https://pulsevm.example.test/network/endpoints.md"]'
	if [ -n "$extra" ]; then
		pages="$(printf '%s' "$pages" | jq -c --arg p "https://pulsevm.example.test/${extra}" '. + [$p] | sort')"
	fi
	jq -n --arg tag "$tag" --argjson sync "$sync" --argjson mainnet "$mainnet" \
		--arg chain "$chain" --argjson head "$head" --argjson pages "$pages" --argjson consec "$consec" \
		'{schema_version: 1, checked_at: "2026-08-16T02:00:00Z", consecutive_failures: $consec,
		  observations: {release_tag: $tag, sync_notice_present: $sync, mainnet_section_present: $mainnet,
		                 head_block: $head, chain_ids: [$chain], pages: $pages}}' > "$STATE"
}

run_checker() {
	FY_LIVE="${FY_LIVE_OVERRIDE:-1}" \
	FYD_CURL="$STUB" \
	FYD_NOTIFY="$NOTIFY_STUB" \
	PULSEVM_UPSTREAM_LOG="$LOG" \
	PULSEVM_UPSTREAM_STATE="$STATE" \
	PULSEVM_RELEASES_URL="https://example.test/repos/pulsevm/releases/latest" \
	PULSEVM_ENDPOINTS_URL="https://example.test/network/endpoints.md" \
	PULSEVM_HEALTH_URL="https://example.test/v2/health" \
	PULSEVM_LLMS_URL="https://example.test/llms.txt" \
	S1_BODY="$S1" S2_BODY="$S2" S3_BODY="$S3" S4_BODY="$S4" \
	S1_CODE="${S1_CODE:-200}" S2_CODE="${S2_CODE:-200}" S3_CODE="${S3_CODE:-200}" S4_CODE="${S4_CODE:-200}" \
	S1_CODE_SEQ="${S1_CODE_SEQ:-}" S2_CODE_SEQ="${S2_CODE_SEQ:-}" S3_CODE_SEQ="${S3_CODE_SEQ:-}" S4_CODE_SEQ="${S4_CODE_SEQ:-}" \
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
echo "$OUT" | grep -qE 'TRIGGER BASELINE[,:]' \
	&& ok "baseline: does NOT claim T1/T2 on an unchanged upstream" \
	|| bad "baseline: unexpected extra trigger in the fired set (out: $OUT)"
[ "$(n_alerts)" -eq 1 ] \
	&& ok "baseline: exactly one alert" \
	|| bad "baseline: expected 1 alert, got $(n_alerts) ($(alerts))"
alerts | grep -q '^high|' \
	&& ok "baseline: alert is high priority" \
	|| bad "baseline: alert not high priority ($(alerts))"
[ -r "$STATE" ] && [ "$(jq -r '.observations.head_block' "$STATE")" = "3406" ] \
	&& ok "baseline: state recorded with the observed head block" \
	|| bad "baseline: state file missing or wrong ($(cat "$STATE" 2>/dev/null))"
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
alerts | grep -q 'running our own node may now be possible' \
	&& ok "T1: alert says what the operator can now do" \
	|| bad "T1: alert body missing the action ($(alerts))"
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
jq -e '.schema_version == 1' "$STATE" >/dev/null 2>&1 \
	&& ok "corrupt-state: the corrupt file is replaced with a valid baseline" \
	|| bad "corrupt-state: state still corrupt ($(cat "$STATE" 2>/dev/null))"
teardown

# ---- case 8b: a state file with the wrong schema_version also re-baselines ---
setup
printf '{"schema_version":99,"observations":{"head_block":1}}' > "$STATE"
RC=0; run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 3 ] \
	&& ok "schema-guard: an unknown schema_version re-baselines instead of mis-reading fields" \
	|| bad "schema-guard: expected exit 3, got $RC"
teardown

# ---- case 8c: observations present but a trigger field missing -> fail open --
# The first draft read the two booleans with `// empty`, which in jq collapses
# a legitimate `false` into "missing" — T1/T2 could then never observe their
# "was it true yesterday" transition. The type gate below is what makes a
# malformed record re-baseline instead of being read with silent fallbacks.
setup
jq -n '{schema_version: 1, checked_at: "2026-08-16T02:00:00Z", consecutive_failures: 0,
        observations: {release_tag: "v0.6.2", head_block: 3406, chain_ids: [], pages: []}}' > "$STATE"
RC=0; run_checker >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 3 ] \
	&& ok "field-guard: observations missing a boolean trigger field re-baselines (fail open)" \
	|| bad "field-guard: expected exit 3, got $RC"
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

# ---- case 11 (DRY): without FY_LIVE=1 the repo's logs/ is untouched ---------
# Run against the checker's OWN defaults (no LOG/STATE override) so this
# measures the real production paths, and assert the directory listing is
# byte-identical before and after. Nothing is deleted — if a developer has a
# real log sitting there, the comparison still holds.
setup
LOGS_DIR="${REPO_ROOT}/logs"
BEFORE="$(ls -A "$LOGS_DIR" 2>/dev/null | sort)"
BEFORE_SUM="$(cd "$LOGS_DIR" 2>/dev/null && find . -type f -exec shasum {} + 2>/dev/null | sort)"
OUT="$(FY_LIVE= FYD_CURL="$STUB" FYD_NOTIFY="$NOTIFY_STUB" \
	PULSEVM_RELEASES_URL="https://example.test/repos/pulsevm/releases/latest" \
	PULSEVM_ENDPOINTS_URL="https://example.test/network/endpoints.md" \
	PULSEVM_HEALTH_URL="https://example.test/v2/health" \
	PULSEVM_LLMS_URL="https://example.test/llms.txt" \
	S1_BODY="$S1" S2_BODY="$S2" S3_BODY="$S3" S4_BODY="$S4" \
	STUB_STATE_DIR="$BASE" FYD_RETRY_SLEEP=0 \
	bash "$CHECKER" 2>&1)"
RC=$?
AFTER="$(ls -A "$LOGS_DIR" 2>/dev/null | sort)"
AFTER_SUM="$(cd "$LOGS_DIR" 2>/dev/null && find . -type f -exec shasum {} + 2>/dev/null | sort)"
[ "$BEFORE" = "$AFTER" ] \
	&& ok "dry: logs/ gained no file (no log, no state, no stray temp) without FY_LIVE=1" \
	|| bad "dry: logs/ changed — before=[$BEFORE] after=[$AFTER]"
[ "$BEFORE_SUM" = "$AFTER_SUM" ] \
	&& ok "dry: every existing file under logs/ is byte-identical afterwards" \
	|| bad "dry: an existing logs/ file was modified"
[ "$RC" -eq 3 ] \
	&& ok "dry: the verdict and exit code are unchanged by dry mode (still exit 3)" \
	|| bad "dry: expected exit 3, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'DRY: would record the pulsevm upstream state' \
	&& ok "dry: the suppressed state write announces itself" \
	|| bad "dry: missing the state-write DRY line (out: $OUT)"
echo "$OUT" | grep -q 'DRY: would append this run.s lines to' \
	&& ok "dry: the suppressed file log announces itself exactly once" \
	|| bad "dry: missing the log DRY line (out: $OUT)"
[ "$(echo "$OUT" | grep -c 'DRY: would append this run')" -eq 1 ] \
	&& ok "dry: the log DRY note is latched (one line per run, not one per log line)" \
	|| bad "dry: expected exactly 1 log DRY note, got $(echo "$OUT" | grep -c 'DRY: would append this run')"
echo "$OUT" | grep -q 'DRY: would notify' \
	&& ok "dry: the suppressed ntfy push announces itself" \
	|| bad "dry: missing the notify DRY line (out: $OUT)"
[ "$(n_alerts)" -eq 0 ] \
	&& ok "dry: no notification actually reached the delegate" \
	|| bad "dry: the notify stub was invoked ($(alerts))"
echo "$OUT" | grep -q 'TRIGGER BASELINE' \
	&& ok "dry: detection still happens — a dry tick is not a blind tick" \
	|| bad "dry: no verdict emitted (out: $OUT)"
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
