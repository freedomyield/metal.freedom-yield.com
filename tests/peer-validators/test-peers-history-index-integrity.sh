#!/usr/bin/env bash
# tests/peer-validators/test-peers-history-index-integrity.sh — regression
# coverage for scripts/peer-validators.sh's daily peers-history publish +
# index (2026-08-06 fix).
#
# CHAIN: none — RPC and the Metallicus explorer are both served via curl's
# file:// scheme from local fixture files (same technique already used by
# tests/watch-validators/test-check-watch-validators.sh for EXPLORER_API —
# curl reads the file directly and ignores -X POST/--data for that scheme),
# and the outbound web-host push is a recording stub swapped in via
# FYD_PUSH_TO_WEB_HOST (same override convention as append-anchor-
# history.sh's R18 publish). No real RPC, explorer, or SSH is ever
# touched. PRIME_DIRECTIVE: safe.
#
# Background: ecd348c (2026-08-05) made peer-validators.sh publish each
# day's gzipped validator-set snapshot right after stashing it locally, but
# a push failure was only a WARN — and public/api/peers-history-index.json
# was built by globbing every *.json.gz found in the LOCAL archive
# (STATE_DIR/peers-history), which always succeeds (no network involved).
# One failed push therefore left the index citing that date forever: the
# local file exists so the glob picks it up, but the file never reached the
# web host, so the URL the index advertises 404s permanently.
#
# The fix makes a persisted ledger (STATE_DIR/peers-history/.published) the
# ONLY source the index is built from — a date lands there iff
# push-to-web-host.sh actually exited 0 for it — and retries any local
# snapshot missing from the ledger at the top of every run, so a transient
# outage self-heals on the next scheduled run.
#
# This suite asserts the invariant that regressed: every entry in
# peers-history-index.json corresponds to a snapshot that was actually
# published, never merely stashed locally.
#
# Usage:
#   bash tests/peer-validators/test-peers-history-index-integrity.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/peer-validators.sh"
ANALYTICS="${REPO_ROOT}/scripts/peer-analytics.py"

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label (expected='$expected' actual='$actual')"; fi
}

skip_pass() {
	echo "SKIP: $1"
	echo
	echo "test-peers-history-index-integrity.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: PASS"
	exit 0
}

[ -f "$SCRIPT" ]    || { echo "FATAL: script not found at $SCRIPT" >&2; exit 1; }
[ -f "$ANALYTICS" ] || { echo "FATAL: peer-analytics.py not found at $ANALYTICS" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || skip_pass "jq unavailable"
command -v python3 >/dev/null 2>&1 || skip_pass "python3 unavailable"
command -v gzip    >/dev/null 2>&1 || skip_pass "gzip unavailable"

WORK="$(mktemp -d -t peer-validators-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

TODAY="$(date -u +%Y-%m-%d)"

# ---- shared RPC + explorer fixtures --------------------------------------
# file:// — curl reads these directly and ignores -X POST/--data for that
# scheme, so no separate curl stub binary is needed.
mkdir -p "$WORK/rpc-fixture/ext/bc"
cat > "$WORK/rpc-fixture/ext/bc/P" <<'EOF'
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "validators": [
      {
        "nodeID": "NodeID-testAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "weight": "2000000000000",
        "delegatorWeight": "500000000000",
        "delegatorCount": "3",
        "delegationFee": "3.0000",
        "uptime": "99.9900",
        "startTime": "1700000000",
        "endTime": "9999999999",
        "connected": true,
        "validationRewardOwner": {"addresses": ["P-testaddr1"]}
      },
      {
        "nodeID": "NodeID-testBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "weight": "1000000000000",
        "delegatorWeight": "0",
        "delegatorCount": "0",
        "delegationFee": "5.0000",
        "uptime": "98.5000",
        "startTime": "1700000000",
        "endTime": "9999999999",
        "connected": true,
        "validationRewardOwner": {"addresses": ["P-testaddr2"]}
      }
    ]
  }
}
EOF
echo '[]' > "$WORK/explorer.json"
RPC_URL="file://$WORK/rpc-fixture"
EXPLORER_URL="file://$WORK/explorer.json"

# push stub factory — logs its sole arg, one line per call; exits $rc.
make_push_stub() {
	local path="$1" log="$2" rc="$3"
	cat > "$path" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$log"
STUBEOF
	if [ "$rc" -ne 0 ]; then
		echo 'echo "stub: forced push failure" >&2' >> "$path"
	fi
	echo "exit $rc" >> "$path"
	chmod +x "$path"
}

# fresh_fixture <name> — fresh fixture repo + state dir; sets globals
# FIXTURE_REPO / STATE_DIR / PUSH_LOG / PUSH_STUB.
fresh_fixture() {
	local name="$1"
	FIXTURE_REPO="$WORK/repo-$name"
	STATE_DIR="$WORK/state-$name"
	mkdir -p "$FIXTURE_REPO/scripts" "$FIXTURE_REPO/public/api" "$STATE_DIR"
	cp -p "$ANALYTICS" "$FIXTURE_REPO/scripts/peer-analytics.py"
	PUSH_LOG="$WORK/push-$name.log"
	PUSH_STUB="$WORK/push-stub-$name.sh"
}

# FY_LIVE=1 is what makes the snapshot, the push and the ledger actually
# happen: since the C3 inversion (scripts/lib/side-effects.sh, 2026-08-06)
# every production side effect is opt-in, so a run without it is a loud dry
# no-op and there would be no ledger or index to assert on. That default-dry
# behaviour has its own coverage in
# tests/side-effects-callers/test-feed-side-effects.sh; here we opt in
# because these cases are about WHAT lands in the ledger and the index, not
# WHETHER anything lands at all.
run_peer_validators() {
	FY_LIVE=1 \
	REPO_BASE="$FIXTURE_REPO" \
	METALGO_API="$RPC_URL" \
	EXPLORER_API="$EXPLORER_URL" \
	UPTIME_STATE_DIR="$STATE_DIR" \
	FYD_PUSH_TO_WEB_HOST="$PUSH_STUB" \
	bash "$SCRIPT"
}

INDEX()  { cat "$FIXTURE_REPO/public/api/peers-history-index.json" 2>/dev/null; }
LEDGER() { cat "$STATE_DIR/peers-history/.published" 2>/dev/null; }

# =============================================================================
# (a) happy path — push succeeds, today's date lands in the ledger + index
# =============================================================================
fresh_fixture "a"
make_push_stub "$PUSH_STUB" "$PUSH_LOG" 0

STDERR_A="$WORK/run-a.stderr"
run_peer_validators >"$WORK/run-a.stdout" 2>"$STDERR_A"
RC_A=$?
check_eq "(a) script exits 0" "0" "$RC_A"
check_eq "(a) local snapshot stashed for today" "1" \
	"$([ -f "$STATE_DIR/peers-history/peers-${TODAY}.json.gz" ] && echo 1 || echo 0)"
check_eq "(a) ledger records today" "$TODAY" "$(LEDGER)"
check_eq "(a) index count=1" "1" "$(INDEX | jq -r '.count')"
check_eq "(a) index entry date=today" "$TODAY" "$(INDEX | jq -r '.entries[0].date')"
check_eq "(a) index entry filename correct" "peers-${TODAY}.json.gz" "$(INDEX | jq -r '.entries[0].filename')"
check_eq "(a) push called exactly once" "1" "$(wc -l < "$PUSH_LOG" 2>/dev/null | tr -d ' ')"
check_eq "(a) push called with correct arg" "peers-history/peers-${TODAY}.json.gz" "$(sed -n '1p' "$PUSH_LOG" 2>/dev/null)"

# =============================================================================
# (b) THE regression this fix closes: push fails -> local snapshot exists,
# but the index must NOT advertise it (old behavior: it would, forever,
# because the index globbed the local archive directly).
# =============================================================================
fresh_fixture "b"
make_push_stub "$PUSH_STUB" "$PUSH_LOG" 1

STDERR_B="$WORK/run-b.stderr"
run_peer_validators >/dev/null 2>"$STDERR_B"
RC_B=$?
check_eq "(b) push failure does not abort the script (fail-safe)" "0" "$RC_B"
check_eq "(b) local snapshot still stashed despite push failure" "1" \
	"$([ -f "$STATE_DIR/peers-history/peers-${TODAY}.json.gz" ] && echo 1 || echo 0)"
check_eq "(b) ledger does NOT record today (push never succeeded)" "" "$(LEDGER)"
check_eq "(b) INVARIANT: index does not advertise the unpublished date (count=0)" "0" "$(INDEX | jq -r '.count')"
check_eq "(b) INVARIANT: index entries array is empty" "0" "$(INDEX | jq -r '.entries | length')"
grep -q "WARN: snapshot published locally but push failed" "$STDERR_B" \
	&& pass "(b) stderr WARNs about the push failure" \
	|| fail "(b) stderr missing push-failure WARN"
grep -q "published snapshot: peers-history/peers-${TODAY}.json.gz" "$STDERR_B" \
	&& fail "(b) stderr wrongly claims the snapshot was published" \
	|| pass "(b) stderr correctly does not claim publish success"

# a SECOND run the same day, still failing, must not accidentally add the
# entry either -- guards against any "publish attempted once => ledger
# forever" mistake that isn't strictly gated on the push's exit code.
run_peer_validators >/dev/null 2>"$WORK/run-b2.stderr"
RC_B2=$?
check_eq "(b2) second failing run also exits 0" "0" "$RC_B2"
check_eq "(b2) INVARIANT still holds after a second failed run (count=0)" "0" "$(INDEX | jq -r '.count')"
check_eq "(b2) push retried on the second run too (2 attempts total)" "2" "$(wc -l < "$PUSH_LOG" 2>/dev/null | tr -d ' ')"

# self-heal: connectivity issue resolves -> next run succeeds -> ledger +
# index catch up without any manual backfill.
make_push_stub "$PUSH_STUB" "$PUSH_LOG" 0
run_peer_validators >/dev/null 2>"$WORK/run-b3.stderr"
RC_B3=$?
check_eq "(b3) self-heal run exits 0" "0" "$RC_B3"
check_eq "(b3) self-heal: ledger now records today" "$TODAY" "$(LEDGER)"
check_eq "(b3) self-heal: index now advertises today (count=1)" "1" "$(INDEX | jq -r '.count')"

# =============================================================================
# (c) backlog retry: a stray PAST-dated local snapshot that a prior (failed)
# run stashed but never got into the ledger must be picked up and published
# automatically -- without needing to be "today".
# =============================================================================
fresh_fixture "c"
mkdir -p "$STATE_DIR/peers-history"
# Simulate a prior day's run: the gzip landed locally but that day's push
# failed, so no ledger entry exists for it. Content doesn't matter -- the
# index only stats file size, it never decompresses.
echo 'stub gzip payload' > "$STATE_DIR/peers-history/peers-2025-01-01.json.gz"
make_push_stub "$PUSH_STUB" "$PUSH_LOG" 0

STDOUT_C="$WORK/run-c.stdout"
STDERR_C="$WORK/run-c.stderr"
run_peer_validators >"$STDOUT_C" 2>"$STDERR_C"
RC_C=$?
check_eq "(c) exits 0" "0" "$RC_C"
check_eq "(c) ledger contains both today and the backlog date" "2025-01-01,${TODAY}," "$(LEDGER | sort | tr '\n' ',')"
check_eq "(c) index count=2" "2" "$(INDEX | jq -r '.count')"
check_eq "(c) index includes the backlog date" "2025-01-01" \
	"$(INDEX | jq -r '.entries[] | select(.date=="2025-01-01") | .date')"
check_eq "(c) push attempted for both today and the backlog date (2 calls)" "2" "$(wc -l < "$PUSH_LOG" 2>/dev/null | tr -d ' ')"
grep -q "peers-history/peers-2025-01-01.json.gz" "$PUSH_LOG" \
	&& pass "(c) push was called with the backlog date's arg" \
	|| fail "(c) push was never called for the backlog date"
grep -q "retrying backlog snapshot: peers-2025-01-01.json.gz" "$STDOUT_C" \
	&& pass "(c) stdout reports the backlog retry" \
	|| fail "(c) stdout missing backlog-retry report"

# =============================================================================
# (d) backlog date whose push keeps failing must stay excluded from the
# index across repeated runs -- the exact shape of the historical bug: a
# local file that persists across runs while genuinely unpublished.
# =============================================================================
fresh_fixture "d"
mkdir -p "$STATE_DIR/peers-history"
echo 'stub gzip payload' > "$STATE_DIR/peers-history/peers-2025-02-02.json.gz"
make_push_stub "$PUSH_STUB" "$PUSH_LOG" 1

run_peer_validators >/dev/null 2>"$WORK/run-d1.stderr"
run_peer_validators >/dev/null 2>"$WORK/run-d2.stderr"
RC_D2=$?
check_eq "(d) exits 0 even after 2 failing runs" "0" "$RC_D2"
check_eq "(d) INVARIANT: backlog date never enters the ledger while failing" "" "$(LEDGER)"
check_eq "(d) INVARIANT: index count stays 0 across repeated failed runs" "0" "$(INDEX | jq -r '.count')"
check_eq "(d) local backlog file still present (fail-safe -- nothing deletes it)" "1" \
	"$([ -f "$STATE_DIR/peers-history/peers-2025-02-02.json.gz" ] && echo 1 || echo 0)"

# =============================================================================
# (e) REGRESSION GUARD (review round 1, 2026-08-06) — a read-only ledger
# file must NOT abort the script. Before this fix, `grep -qxF ... ||
# echo "$date" >> "$PUBLISHED_LEDGER"` had the ledger append as the FINAL
# command of an `||` list — under `set -euo pipefail`, bash does NOT
# exempt the final command of an && / || list from errexit (only the
# earlier, non-final commands are exempt), so a failed append aborted the
# whole script right there. The retry loop and the index write below it
# never ran at all, contradicting the function's own documented contract
# ("Every exit path here is a WARN, never a hard failure"). Realistic
# triggers: ENOSPC-triggered remount, a DR restore that left root-owned
# perms, any read-only filesystem window. This is push-succeeds-but-
# ledger-write-fails specifically (the touch guard for a wholly missing
# ledger is covered by manual repro in the report -- constructing a
# filesystem where touch itself fails but the snapshot gzip write
# (moments earlier, same directory) still succeeds isn't reproducible
# through simple chmod on this filesystem, since touch's utime() succeeds
# for the file's own owner even at mode 444; an actual write via `>>`
# does not have that exemption, which is exactly what this case drives).
# =============================================================================
echo "checking (e): read-only ledger must not abort the script"
fresh_fixture "e"
mkdir -p "$STATE_DIR/peers-history"
: > "$STATE_DIR/peers-history/.published"
chmod 444 "$STATE_DIR/peers-history/.published"
make_push_stub "$PUSH_STUB" "$PUSH_LOG" 0

STDERR_E="$WORK/run-e.stderr"
run_peer_validators >/dev/null 2>"$STDERR_E"
RC_E=$?
check_eq "(e) read-only ledger: script still exits 0 (fail-safe contract honored)" "0" "$RC_E"
check_eq "(e) read-only ledger: local snapshot still stashed" "1" \
	"$([ -f "$STATE_DIR/peers-history/peers-${TODAY}.json.gz" ] && echo 1 || echo 0)"
check_eq "(e) read-only ledger: push was still attempted and succeeded (1 call)" "1" "$(wc -l < "$PUSH_LOG" 2>/dev/null | tr -d ' ')"
grep -q "could not record .* in the ledger" "$STDERR_E" \
	&& pass "(e) stderr WARNs about the ledger write failure" \
	|| fail "(e) stderr missing ledger-write-failure WARN"
check_eq "(e) INVARIANT: index file is still written (not aborted before reaching it)" "0" \
	"$([ -f "$FIXTURE_REPO/public/api/peers-history-index.json" ] && echo 0 || echo 1)"
check_eq "(e) index is still valid JSON despite the ledger failure" "0" "$(INDEX | jq -r '.count')"

# (e2) self-heal: permissions fixed -> next run records the ledger entry
# and the index catches up, without needing today's already-stashed
# snapshot to be regenerated.
chmod 644 "$STATE_DIR/peers-history/.published"
run_peer_validators >/dev/null 2>"$WORK/run-e2.stderr"
RC_E2=$?
check_eq "(e2) self-heal run exits 0" "0" "$RC_E2"
check_eq "(e2) self-heal: ledger now records today" "$TODAY" "$(LEDGER)"
check_eq "(e2) self-heal: index now advertises today (count=1)" "1" "$(INDEX | jq -r '.count')"

# ---- summary ---------------------------------------------------------------
echo
echo "----------------------------------------"
echo "test-peers-history-index-integrity.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
