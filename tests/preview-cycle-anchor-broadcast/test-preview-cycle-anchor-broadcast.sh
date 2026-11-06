#!/usr/bin/env bash
# test-preview-cycle-anchor-broadcast.sh — suite for the NEW published-copy
# guard added to scripts/preview-cycle-anchor-broadcast.sh (2026-07-31
# walkthrough re-verification, R1).
#
# CHAIN: none — no network. A recording curl stub (FYD_CURL) serves fixture
#        bodies + HTTP codes from tempfiles; no real HTTP, no broadcast, no
#        proton invocation is ever reached (see scope note below).
#
# Scope (why this suite stops where it stops): the script's own header has
# always documented itself as "no automated test by design" for the FULL
# STAGE-1 pipeline — reaching real completion (exit 0) requires a live
# FY_CONFIG_DIR (xpr-account / anchor-sink) and a real sign-anchor-event.sh
# --dry-run run, neither of which this fix touches. What this fix DID add is
# the published-copy guard that runs immediately after the pre-existing
# committed-bytes guard ([1/5]) passes — so this suite drives the real
# script (real $0, so the real §3.5 keystore-guard lib and the real
# committed-bytes guard both run unstubbed) against a throwaway git fixture
# repo (REPO=<fixture>, so [1/5] deterministically resolves to "match"), with
# ONLY the new guard's `curl` call stubbed (FYD_CURL). FY_CONFIG_DIR is
# pointed at a guaranteed-nonexistent path, so once the new guard passes (or
# is skipped) the script always proceeds to its PRE-EXISTING [3/5] config-dir
# check and exits 3 there — a known, unrelated, already-documented stopping
# point. Exit 3 in the "pass"/"skip" cases below therefore PROVES the new
# guard did not block (a guard failure would exit 10, not 3); it is not
# asserting the whole pipeline completed.
#
# Cases:
#   1. published copy matches --source (same dag_root_computed)      -> guard
#      passes (no exit 10), reaches [2/5], eventually exits 3 (config dir).
#      Also asserts the cache-buster query param is present and UNIQUE
#      across repeated invocations (the mechanism that defeats the /api/*.json
#      120s edge cache).
#   2. published copy differs (different dag_root_computed)          -> exit 10,
#      distinct from the pre-existing exit 9 (local-HEAD guard).
#   3. published copy unreachable (curl fails, HTTP=000)             -> exit 10,
#      fail-closed, no guessing.
#   4. published copy is not valid JSON                               -> exit 10.
#   5. --skip-published-check                                        -> loud
#      stderr warning, guard NOT evaluated (curl stub never called), still
#      reaches [2/5] / exits 3 same as case 1.
#   6. the pre-existing local-HEAD guard (exit 9) and its --allow-uncommitted
#      escape hatch are UNCHANGED by this fix (regression guard).
#
# Usage:
#   bash tests/preview-cycle-anchor-broadcast/test-preview-cycle-anchor-broadcast.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

# Hermeticity: force a resolvable git commit identity for every git command
# this suite runs, regardless of the ambient environment. GIT_AUTHOR_NAME /
# GIT_COMMITTER_NAME environment variables — if merely *set*, even to an
# empty string — take precedence over ALL config sources (system, global,
# local repo config, and the per-invocation `-c user.name=...` this suite
# already uses via GITQ alike). A CI runner with no global git identity and
# an empty GECOS name derives an empty name and `git commit` dies with
# "empty ident name ... not allowed"; GITQ's `-c user.name=` does NOT help
# in that case, because an explicitly-empty env var already won. Exporting
# non-empty values here is the one thing that actually wins in every
# environment (see scripts/operator-local/test-commit-anchor-source.sh for
# the case where this was first found to matter). Values are obviously fake
# test fixtures (.invalid is the RFC 2606 reserved-for-testing TLD) — never
# a real operator name/email.
export GIT_AUTHOR_NAME="FYD Hermetic Test Suite"
export GIT_AUTHOR_EMAIL="fyd-hermetic-test@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/preview-cycle-anchor-broadcast.sh"

if [ ! -f "$SCRIPT" ]; then
	echo "FATAL: script not found at $SCRIPT" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)
DUMMY_TX_ID="$(printf '%064d' 1)"
DAG_COMMITTED="c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee0"
DAG_OTHER="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

BASE=""; FIXTURE_REPO=""; TEST_HOME=""; NO_CFG_DIR=""
CURL_STUB=""; CURL_LOG=""
setup() {
	BASE="$(mktemp -d -t preview-cycle-anchor-broadcast-test.XXXXXX)"
	TEST_HOME="$BASE/fake-home"                # satisfies the §3.5 keystore guard
	mkdir -p "$TEST_HOME"
	NO_CFG_DIR="$BASE/no-such-fy-config-dir"    # guaranteed absent -> [3/5] exit 3
	FIXTURE_REPO="$BASE/fixture-repo"
	mkdir -p "$FIXTURE_REPO/public/api"
	printf '{"schema_version":1,"observations_branch":{"cycle_number_observed":4},"dag_root_computed":"%s"}\n' \
		"$DAG_COMMITTED" > "$FIXTURE_REPO/public/api/anchor-source.json"
	git -C "$FIXTURE_REPO" "${GITQ[@]}" init -q -b main
	git -C "$FIXTURE_REPO" "${GITQ[@]}" add -A
	git -C "$FIXTURE_REPO" "${GITQ[@]}" commit -qm seed

	CURL_STUB="$BASE/curl-stub.sh"
	CURL_LOG="$BASE/curl-urls.log"
	# Recording curl stub. Emulates:
	#   curl -sS -o <outfile> -w "%{http_code}" --max-time N \
	#     -H '...' -H '...' <url>?cb=<unique>
	# Controlled by env: PUB_FAIL=1 (simulate curl connection failure, no
	# output, exit 1 -> caller's `|| echo 000` fires), PUB_CODE (HTTP status
	# to report, default 200), PUB_BODY_FILE (fixture body to serve).
	cat > "$CURL_STUB" <<'STUBEOF'
#!/usr/bin/env bash
outfile=""
url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) outfile="$2"; shift 2 ;;
		-w|--max-time) shift 2 ;;
		-H) shift 2 ;;
		-sS|-s|-S) shift ;;
		http*) url="$1"; shift ;;
		*) shift ;;
	esac
done
printf '%s\n' "$url" >> "${CURL_URL_LOG:?}"
if [ "${PUB_FAIL:-0}" = "1" ]; then
	exit 1
fi
code="${PUB_CODE:-200}"
if [ -n "$outfile" ] && [ -n "${PUB_BODY_FILE:-}" ] && [ -f "${PUB_BODY_FILE}" ]; then
	cat "$PUB_BODY_FILE" > "$outfile"
fi
printf '%s' "$code"
STUBEOF
	chmod +x "$CURL_STUB"
}
teardown() { rm -rf "$BASE"; BASE=""; }

write_pub_source() {
	# write_pub_source <outfile> <dag_root_computed_hex>
	printf '{"schema_version":1,"dag_root_computed":"%s"}\n' "$2" > "$1"
}

# run_preview <extra-arg...> — invokes the REAL script by its real path (so
# $0-derived SCRIPT_DIR resolves the real scripts/lib/require-keystore-home.sh
# unstubbed), with REPO redirected to the throwaway fixture repo and
# FY_CONFIG_DIR redirected to a guaranteed-absent path.
run_preview() {
	CURL_URL_LOG="$CURL_LOG" \
	HOME="$TEST_HOME" \
	REPO="$FIXTURE_REPO" \
	FY_CONFIG_DIR="$NO_CFG_DIR" \
	ANCHOR_SOURCE_URL="https://example.test/api/anchor-source.json" \
	FYD_CURL="$CURL_STUB" \
	PUB_FAIL="${PUB_FAIL:-0}" PUB_CODE="${PUB_CODE:-200}" PUB_BODY_FILE="${PUB_BODY_FILE:-}" \
	DRYLOG="$BASE/dryrun.json" \
		bash "$SCRIPT" --source=public/api/anchor-source.json \
			--testnet-tx-id="$DUMMY_TX_ID" "$@"
}

# ---- case 1: published copy matches --source -> guard passes, reaches [2/5],
#      exits 3 at the pre-existing (unrelated) config-dir check -------------
setup
PUB_BODY_FILE="$BASE/pub-match.json"
write_pub_source "$PUB_BODY_FILE" "$DAG_COMMITTED"
OUT="$(PUB_CODE=200 PUB_BODY_FILE="$PUB_BODY_FILE" run_preview 2>&1)"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "match: guard passes, script proceeds to the pre-existing config-dir exit (3)" \
	|| bad "match: expected exit 3 (guard did not block), got $RC (out: $OUT)"
echo "$OUT" | grep -q 'published copy matches committed bytes' \
	&& ok "match: success line printed" \
	|| bad "match: success line missing (out: $OUT)"
echo "$OUT" | grep -q '\[2/5\]' \
	&& ok "match: script advanced past the new guard into [2/5]" \
	|| bad "match: [2/5] marker missing — guard may have blocked (out: $OUT)"
[ -s "$CURL_LOG" ] && grep -q '?cb=' "$CURL_LOG" \
	&& ok "match: fetch used a cache-busting query param" \
	|| bad "match: no ?cb= query param seen (log: $(cat "$CURL_LOG" 2>/dev/null))"
teardown

# ---- case 1b: cache-buster is unique across two separate invocations ------
setup
PUB_BODY_FILE="$BASE/pub-match.json"
write_pub_source "$PUB_BODY_FILE" "$DAG_COMMITTED"
PUB_CODE=200 PUB_BODY_FILE="$PUB_BODY_FILE" run_preview >/dev/null 2>&1
PUB_CODE=200 PUB_BODY_FILE="$PUB_BODY_FILE" run_preview >/dev/null 2>&1
CB1="$(sed -n '1p' "$CURL_LOG" | grep -oE 'cb=[^&[:space:]]+')"
CB2="$(sed -n '2p' "$CURL_LOG" | grep -oE 'cb=[^&[:space:]]+')"
[ -n "$CB1" ] && [ -n "$CB2" ] && [ "$CB1" != "$CB2" ] \
	&& ok "cache-buster: two invocations use two different cb= values ($CB1 vs $CB2)" \
	|| bad "cache-buster: expected distinct cb= values, got '$CB1' and '$CB2'"
teardown

# ---- case 2: published copy DIFFERS -> exit 10 (new code, distinct from 9) -
setup
PUB_BODY_FILE="$BASE/pub-stale.json"
write_pub_source "$PUB_BODY_FILE" "$DAG_OTHER"
OUT="$(PUB_CODE=200 PUB_BODY_FILE="$PUB_BODY_FILE" run_preview 2>&1)"
RC=$?
[ "$RC" -eq 10 ] \
	&& ok "differ: mismatch -> exit 10" \
	|| bad "differ: expected exit 10, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'does NOT match committed bytes' \
	&& ok "differ: message names the mismatch" \
	|| bad "differ: message missing (out: $OUT)"
echo "$OUT" | grep -q "$DAG_COMMITTED" && echo "$OUT" | grep -q "$DAG_OTHER" \
	&& ok "differ: message shows both dag_root_computed values" \
	|| bad "differ: expected both hashes in output (out: $OUT)"
teardown

# ---- case 3: published copy UNREACHABLE -> exit 10, fail-closed -----------
setup
OUT="$(PUB_FAIL=1 run_preview 2>&1)"
RC=$?
[ "$RC" -eq 10 ] \
	&& ok "unreachable: curl failure -> exit 10 (fail-closed)" \
	|| bad "unreachable: expected exit 10, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'could not fetch published copy' \
	&& ok "unreachable: message states fetch failure, no guessing" \
	|| bad "unreachable: message missing (out: $OUT)"
teardown

# ---- case 4: published copy is not valid JSON -> exit 10 ------------------
setup
PUB_BODY_FILE="$BASE/pub-garbage.txt"
printf 'not json at all' > "$PUB_BODY_FILE"
OUT="$(PUB_CODE=200 PUB_BODY_FILE="$PUB_BODY_FILE" run_preview 2>&1)"
RC=$?
[ "$RC" -eq 10 ] \
	&& ok "invalid-json: unparseable published body -> exit 10" \
	|| bad "invalid-json: expected exit 10, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'not valid JSON' \
	&& ok "invalid-json: message names the parse failure" \
	|| bad "invalid-json: message missing (out: $OUT)"
teardown

# ---- case 5: --skip-published-check -> warned pass, guard not evaluated ---
setup
OUT="$(run_preview --skip-published-check 2>&1)"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "skip: warned pass, still reaches the pre-existing config-dir exit (3)" \
	|| bad "skip: expected exit 3 (not blocked), got $RC (out: $OUT)"
echo "$OUT" | grep -q -- '--skip-published-check given' \
	&& ok "skip: loud warning printed" \
	|| bad "skip: warning missing (out: $OUT)"
[ ! -s "$CURL_LOG" ] \
	&& ok "skip: the published-copy curl fetch was never invoked" \
	|| bad "skip: expected no curl call, but log has: $(cat "$CURL_LOG" 2>/dev/null)"
teardown

# ---- case 6 (regression): pre-existing local-HEAD guard (exit 9) and its
#      --allow-uncommitted escape hatch are unchanged by this fix -----------
setup
# --source points at a file that differs from the fixture repo's committed
# HEAD copy -> the PRE-EXISTING committed-bytes guard ([1/5]) must still fail
# with exit 9, and the NEW published-copy guard must never even run (no
# curl call), since it only runs once [1/5] resolves to "match".
BAD_SRC="$BASE/uncommitted-source.json"
write_pub_source "$BAD_SRC" "$DAG_OTHER"
OUT="$(CURL_URL_LOG="$CURL_LOG" HOME="$TEST_HOME" REPO="$FIXTURE_REPO" \
	FY_CONFIG_DIR="$NO_CFG_DIR" FYD_CURL="$CURL_STUB" DRYLOG="$BASE/dryrun.json" \
	bash "$SCRIPT" --source="$BAD_SRC" --testnet-tx-id="$DUMMY_TX_ID" 2>&1)"
RC=$?
[ "$RC" -eq 9 ] \
	&& ok "regression: local-HEAD guard still exits 9 on mismatch (unchanged)" \
	|| bad "regression: expected exit 9, got $RC (out: $OUT)"
[ ! -s "$CURL_LOG" ] \
	&& ok "regression: published-copy guard never runs when [1/5] itself fails" \
	|| bad "regression: unexpected curl call when [1/5] should have blocked first"
# --allow-uncommitted still overrides [1/5] and continues (unchanged); the
# published-copy guard then runs (GUARD_STATUS=match is not required by this
# fix's design — see script comment — so we only assert [1/5]'s own behavior
# here, not exit code, since --allow-uncommitted intentionally proceeds past
# a config-dir failure the same as before this fix).
OUT2="$(CURL_URL_LOG="$CURL_LOG" HOME="$TEST_HOME" REPO="$FIXTURE_REPO" \
	FY_CONFIG_DIR="$NO_CFG_DIR" FYD_CURL="$CURL_STUB" DRYLOG="$BASE/dryrun.json" \
	bash "$SCRIPT" --source="$BAD_SRC" --testnet-tx-id="$DUMMY_TX_ID" --allow-uncommitted 2>&1)"
RC2=$?
echo "$OUT2" | grep -q -- '--allow-uncommitted given' \
	&& ok "regression: --allow-uncommitted escape hatch still works (unchanged)" \
	|| bad "regression: --allow-uncommitted behavior changed (out: $OUT2)"
[ "$RC2" -eq 3 ] \
	&& ok "regression: --allow-uncommitted proceeds past [1/5] to the pre-existing config-dir exit (3)" \
	|| bad "regression: expected exit 3 after --allow-uncommitted, got $RC2 (out: $OUT2)"
[ ! -s "$CURL_LOG" ] \
	&& ok "regression: published-copy guard also skipped on the --allow-uncommitted (mismatch) path — no curl call" \
	|| bad "regression: unexpected curl call on the --allow-uncommitted path"
teardown

# ---- gate 1 pre-check ([4/5]) must ask the SAME question bin/safe-broadcast's
#      gate 1 asks (2026-11-06: the preview sent no content-type, the live
#      history endpoint answered 400, and every preview showed MISS) ----------
# CHAIN: none — no network. A recording `curl` and `proton` stub sit first on
# PATH; the fixture repo carries a stub scripts/sign-anchor-event.sh so the
# script runs all the way through [4/5] and exits 0.
HIST_TX="$(printf '%064d' 7)"
G1_STUBDIR=""; G1_LOG=""; G1_TREE=""; G1_TREE_V2=""
g1_setup() {
	setup
	G1_STUBDIR="$BASE/stubbin"; G1_LOG="$BASE/hist-requests.log"; : > "$G1_LOG"
	mkdir -p "$G1_STUBDIR" "$BASE/cfg" "$FIXTURE_REPO/scripts"
	: > "$BASE/cfg/xpr-account"; : > "$BASE/cfg/anchor-sink"
	cat > "$FIXTURE_REPO/scripts/sign-anchor-event.sh" <<'SIGNEOF'
#!/usr/bin/env bash
printf '%s\n' '{"tx":{"actions":[{"authorization":[{"actor":"a","permission":"anchor"}],"data":{"memo":"fya1c4","to":"x","quantity":"0.0001 XPR"}}]}}'
SIGNEOF
	cat > "$G1_STUBDIR/proton" <<'PEOF'
#!/usr/bin/env bash
echo '{}'
PEOF
	# History endpoint emulation (the 2026-11-06 behaviour): a v1 POST without
	# `content-type:application/json` is a 400 (curl -f -> rc 22, no body;
	# without -f the error body is printed). V1_BODY / V2_BODY serve the answers.
	cat > "$G1_STUBDIR/curl" <<'CEOF'
#!/usr/bin/env bash
method=GET; ctype=0; url=""; fflag=0
while [ $# -gt 0 ]; do
	case "$1" in
		-X) method="$2"; shift 2 ;;
		-H) case "$(printf '%s' "$2" | tr 'A-Z' 'a-z' | tr -d ' ')" in content-type:application/json*) ctype=1 ;; esac; shift 2 ;;
		-d) method=POST; shift 2 ;;
		--max-time) shift 2 ;;
		-[a-zA-Z]*) case "$1" in *f*) fflag=1 ;; esac; shift ;;
		http*) url="$1"; shift ;;
		*) shift ;;
	esac
done
printf '%s ct=%s %s\n' "$method" "$ctype" "$url" >> "${HIST_LOG:?}"
case "$url" in
	*/v1/history/get_transaction)
		if [ "$method" != POST ] || [ "$ctype" != 1 ]; then
			[ "$fflag" = 1 ] && exit 22
			printf '%s' "{\"code\":400,\"message\":\"body must have required property 'id'\"}"; exit 0
		fi
		[ -n "${V1_BODY:-}" ] || exit 22
		printf '%s' "$V1_BODY" ;;
	*/v2/history/get_transaction\?id=*)
		[ -n "${V2_BODY:-}" ] || exit 22
		printf '%s' "$V2_BODY" ;;
	*) exit 22 ;;
esac
CEOF
	chmod +x "$G1_STUBDIR/curl" "$G1_STUBDIR/proton"
	# Throwaway copies of scripts/ + config/ so this suite can run a MUTANT of
	# the script and an id-only profile without touching the real tree.
	G1_TREE="$BASE/tree"; mkdir -p "$G1_TREE"
	cp -R "$REPO_ROOT/scripts" "$G1_TREE/scripts"; cp -R "$REPO_ROOT/config" "$G1_TREE/config"
	G1_TREE_V2="$BASE/tree-v2"; mkdir -p "$G1_TREE_V2"
	cp -R "$REPO_ROOT/scripts" "$G1_TREE_V2/scripts"; cp -R "$REPO_ROOT/config" "$G1_TREE_V2/config"
	jq '.profiles["xpr-mainnet"].push_response="id-only" | .profiles["xpr-testnet"].push_response="id-only"' \
		"$REPO_ROOT/config/a-chain-profiles.json" > "$G1_TREE_V2/config/a-chain-profiles.json"
}
# g1_run <script> [VAR=val ...] — runs [1/5]..[5/5] with the stubs.
g1_run() {
	local script="$1"; shift
	env PATH="$G1_STUBDIR:$PATH" HIST_LOG="$G1_LOG" CURL_URL_LOG="$CURL_LOG" \
		HOME="$TEST_HOME" REPO="$FIXTURE_REPO" FY_CONFIG_DIR="$BASE/cfg" \
		DRYLOG="$BASE/dryrun.json" FYD_CURL="$CURL_STUB" "$@" \
		bash "$script" --source=public/api/anchor-source.json \
			--testnet-tx-id="$HIST_TX" --skip-published-check 2>&1
}
g1_line() { printf '%s\n' "$1" | grep 'gate1 testnet-tx' | head -1; }
V1_OK="{\"id\":\"$HIST_TX\",\"block_num\":123,\"traces\":[]}"

# G1: the v1 POST carries content-type -> block_num shown, check mark
g1_setup
OUT="$(g1_run "$SCRIPT" V1_BODY="$V1_OK")"; RC=$?
LINE="$(g1_line "$OUT")"
[ "$RC" -eq 0 ] && ok "gate1: preview runs through [4/5] to exit 0" || bad "gate1: expected exit 0, got $RC (out: $OUT)"
case "$LINE" in *"block_num: 123"*"✓"*) ok "gate1: v1 POST with content-type resolves -> block_num + check" ;; *) bad "gate1: expected 'block_num: 123 ✓', got: $LINE" ;; esac
grep -q '^POST ct=1 .*/v1/history/get_transaction$' "$G1_LOG" \
	&& ok "gate1: request is a POST with content-type:application/json" \
	|| bad "gate1: no POST+content-type request seen (log: $(cat "$G1_LOG"))"
teardown

# G2 (mutant): drop the content-type header -> the stubbed endpoint answers 400
#      -> MISS. G1 above fails against this mutant.
g1_setup
sed -i.bak "s/-H 'content-type:application\/json'//" "$G1_TREE/scripts/preview-cycle-anchor-broadcast.sh"
if cmp -s "$G1_TREE/scripts/preview-cycle-anchor-broadcast.sh" "$REPO_ROOT/scripts/preview-cycle-anchor-broadcast.sh"; then
	bad "mutant(no content-type): the sed did not change the script (mutation not applied)"
else
	OUT="$(g1_run "$G1_TREE/scripts/preview-cycle-anchor-broadcast.sh" V1_BODY="$V1_OK")"
	LINE="$(g1_line "$OUT")"
	case "$LINE" in *"block_num: 123"*) bad "mutant(no content-type) NOT caught: still resolved ($LINE)" ;; *) ok "mutant(no content-type) caught: gate1 does not resolve ($LINE)" ;; esac
fi
teardown

# G3: v1 answers for a DIFFERENT tx id -> safe-broadcast's gate 1 would refuse,
#     so the preview must not show a check mark (never looser than the real gate).
g1_setup
OUT="$(g1_run "$SCRIPT" V1_BODY="{\"id\":\"$(printf '%064d' 9)\",\"block_num\":123}")"
LINE="$(g1_line "$OUT")"
case "$LINE" in *"✓"*|*"block_num: 123"*) bad "gate1: foreign tx id must not resolve, got: $LINE" ;; *) ok "gate1: answer naming another tx -> MISS, no check" ;; esac
teardown

# G4: v1 answers executed:false -> real gate refuses -> no check mark.
g1_setup
OUT="$(g1_run "$SCRIPT" V1_BODY="{\"id\":\"$HIST_TX\",\"block_num\":123,\"executed\":false}")"
LINE="$(g1_line "$OUT")"
case "$LINE" in *"✓"*) bad "gate1: executed:false must not show a check, got: $LINE" ;; *) ok "gate1: executed:false -> no check" ;; esac
teardown

# G5: processed profile (default): v1 fails + v2 would answer -> safe-broadcast
#     does NOT try v2 there, so the preview must not either.
g1_setup
OUT="$(g1_run "$SCRIPT" V2_BODY="{\"trx_id\":\"$HIST_TX\",\"block_num\":456}")"
LINE="$(g1_line "$OUT")"
case "$LINE" in *"✓"*) bad "gate1: processed profile must not fall back to v2, got: $LINE" ;; *) ok "gate1: processed profile -> v1 only, no check from v2" ;; esac
! grep -q '/v2/history/' "$G1_LOG" \
	&& ok "gate1: processed profile made no v2 request" \
	|| bad "gate1: unexpected v2 request on a processed profile"
teardown

# G6: id-only profile: v1 fails, v2 answers -> resolved via v2 (same as gate 1).
g1_setup
OUT="$(g1_run "$G1_TREE_V2/scripts/preview-cycle-anchor-broadcast.sh" V2_BODY="{\"trx_id\":\"$HIST_TX\",\"block_num\":456}")"
LINE="$(g1_line "$OUT")"
case "$LINE" in *"block_num: 456"*"✓"*) ok "gate1: id-only profile resolves through the v2 GET" ;; *) bad "gate1: id-only v2 fallback expected 'block_num: 456 ✓', got: $LINE (out: $OUT)" ;; esac
teardown

# G7 (mutant): remove the v2 attempt in the id-only run -> must stop resolving.
g1_setup
sed -i.bak 's/if \[ "\$try_v2" = "1" \]; then/if [ "$try_v2" = "never" ]; then/' "$G1_TREE_V2/scripts/preview-cycle-anchor-broadcast.sh"
if cmp -s "$G1_TREE_V2/scripts/preview-cycle-anchor-broadcast.sh" "$REPO_ROOT/scripts/preview-cycle-anchor-broadcast.sh"; then
	bad "mutant(no v2): mutation not applied"
else
	OUT="$(g1_run "$G1_TREE_V2/scripts/preview-cycle-anchor-broadcast.sh" V2_BODY="{\"trx_id\":\"$HIST_TX\",\"block_num\":456}")"
	LINE="$(g1_line "$OUT")"
	case "$LINE" in *"block_num: 456"*) bad "mutant(no v2) NOT caught: still resolved ($LINE)" ;; *) ok "mutant(no v2) caught: id-only run no longer resolves ($LINE)" ;; esac
fi
teardown

# G8: the lookup helpers in the preview are identical to bin/safe-broadcast's
#     (one question, two askers: compare the definitions mechanically).
extract_fn() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$1"; }
for FN in sb_history_names_tx sb_history_lookup; do
	A="$(extract_fn "$REPO_ROOT/bin/safe-broadcast" "$FN")"
	B="$(extract_fn "$SCRIPT" "$FN")"
	if [ -n "$A" ] && [ "$A" = "$B" ]; then ok "drift guard: $FN identical in preview and bin/safe-broadcast"
	else bad "drift guard: $FN missing or differs between preview and bin/safe-broadcast"; fi
done

# ---- summary ----------------------------------------------------------------
echo "test-preview-cycle-anchor-broadcast.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
