#!/usr/bin/env bash
# test-safe-broadcast.sh — regression suite for bin/safe-broadcast
# (tier-2 mechanical enforcement of PRIME DIRECTIVE).
#
# CHAIN: none — this test drives arg validation and gate refusal paths only.
#        It does NOT invoke any real proton broadcast. Cases that would
#        reach the `proton transaction:push` call are skipped without a
#        running proton-cli + configured keystore; those are covered by
#        the testnet full E2E rehearsal (T-I-20260701) instead.
#
# Usage:
#   bash tests/safe-broadcast/test-safe-broadcast.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/bin/safe-broadcast"

if [ ! -x "$WRAPPER" ]; then
	echo "FATAL: safe-broadcast not executable at $WRAPPER" >&2
	exit 1
fi

# ---- isolate token + audit log ----
TEST_TOKEN="$(mktemp -t safe-bcast-token.XXXXXX)"
TEST_AUDIT="$(mktemp -t safe-bcast-audit.XXXXXX)"
TEST_TX_VALID="$(mktemp -t safe-bcast-tx.XXXXXX)"
TEST_TX_EMPTY="$(mktemp -t safe-bcast-tx.XXXXXX)"
TEST_DRY_LOG="$(mktemp -t safe-bcast-dryrun.XXXXXX)"
# ---- gate 1 / gate 4 shape-binding hardening fixtures (2026-08) ----
TEST_TX_CYCLE4="$(mktemp -t safe-bcast-tx.XXXXXX)"
TEST_TX_UPDATEAUTH="$(mktemp -t safe-bcast-tx.XXXXXX)"
TEST_DRY_LOG_CYCLE4="$(mktemp -t safe-bcast-dryrun.XXXXXX)"
TEST_DRY_LOG_NONJSON="$(mktemp -t safe-bcast-dryrun.XXXXXX)"
export FYD_BROADCAST_TOKEN_FILE="$TEST_TOKEN"
export FYD_BROADCAST_AUDIT_LOG="$TEST_AUDIT"

# ---- hermetic proton stub ----
# The wrapper does `command -v proton || exit 4` (bin/safe-broadcast) as a
# pre-gate check, BEFORE any PRIME DIRECTIVE gate. On a host without the real
# proton CLI (e.g. the CI ubuntu runner) every gate-1/gate-2 scenario — which
# expects exit 3 — would instead exit 4 at that pre-gate check and never reach
# its intended gate. To make this suite hermetic (identical behaviour on macOS
# and Linux, with or without the real CLI installed) we put a stub `proton` on
# PATH for ALL scenarios. It only needs to (a) satisfy `command -v proton`, and
# (b) answer the gate-3 chain:info probe with a well-formed chain_id. No test
# case reaches the actual broadcast, so the stub never issues one — it does NOT
# weaken any assertion, it only removes the environment's real-proton dependency.
# The gate-3 scenario overrides FYD_TESTNET_CHAIN_ID to a bogus value, so the
# stub's (real, default) chain_id deliberately mismatches → exit 4, as intended.
STUB_DIR="$(mktemp -d -t safe-bcast-stub.XXXXXX)"
cat > "$STUB_DIR/proton" <<'STUB'
#!/usr/bin/env bash
# Test stub for proton-cli (see tests/safe-broadcast/test-safe-broadcast.sh).
case "$1" in
	chain:set)  exit 0 ;;
	chain:info) echo '{"chain_id":"71ee83bcf52142d61019d95f9cc5427ba6a0d7ff8accd9e2088ae2abeaf3d3dd","head_block_num":1}' ; exit 0 ;;
	*)          exit 0 ;;
esac
STUB
chmod +x "$STUB_DIR/proton"

# ---- hermetic curl stub (gate-1 resolution, mainnet path only) ----
# To exercise anything past gate 1 on the MAINNET path we must first satisfy
# gate 1 (--testnet-tx-id must resolve against the testnet Hyperion
# endpoint), which normally requires a real network call. This stub resolves
# ONLY a fixed set of sentinel ids (defined below, each carrying a canned
# testnet-evidence-tx body written to $FIXTURE_DIR) and returns "not found"
# for anything else — in particular the PRE-EXISTING all-zeros id used by the
# "testnet-tx-id shape-valid but unresolvable" case above stays unresolvable,
# unchanged. bin/safe-broadcast has exactly one curl call site (gate 1), so
# this is a safe, narrow, fully-offline stub.
#
# Each fixture body is v1 `/v1/history/get_transaction`-shaped
# (`.actions[].act.{account,name,data.memo}`), matching the shape
# bin/safe-broadcast's own gate-1 code (and scripts/gen-anchor-receipt.sh's
# v1 fallback) already assumes for this endpoint.
FIXTURE_DIR="$(mktemp -d -t safe-bcast-fixtures.XXXXXX)"

# R16_RESOLVABLE_TXID: single eosio.token::transfer, memo fya1c3-test —
# matches $TEST_TX_VALID exactly (cycle-3 shape). Used by the pre-existing
# R16 gate-2b test cases below, and by the new gate-4 non-JSON-log case.
R16_RESOLVABLE_TXID="1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
cat > "$FIXTURE_DIR/r16.json" <<JSON
{"id":"${R16_RESOLVABLE_TXID}","block_num":123456,"actions":[{"act":{"account":"eosio.token","name":"transfer","authorization":[{"actor":"metalfreedom","permission":"anchor"}],"data":{"memo":"fya1c3-test"}}}]}
JSON

# CYCLE2_EVIDENCE_TXID: single eosio.token::transfer, memo fya1c2-test — the
# WRONG cycle vs. the cycle-4 outgoing tx ($TEST_TX_CYCLE4, memo fya1c4-test)
# it gets paired against. Proves gate 1 (b) refuses cross-cycle evidence.
CYCLE2_EVIDENCE_TXID="$(printf 'aaaa2222%.0s' 1 2 3 4 5 6 7 8)"
cat > "$FIXTURE_DIR/cycle2.json" <<JSON
{"id":"${CYCLE2_EVIDENCE_TXID}","block_num":222222,"actions":[{"act":{"account":"eosio.token","name":"transfer","authorization":[{"actor":"metalfreedom","permission":"anchor"}],"data":{"memo":"fya1c2-test"}}}]}
JSON

# CYCLE4_EVIDENCE_TXID: single eosio.token::transfer, memo fya1c4-test —
# matches $TEST_TX_CYCLE4 exactly (same cycle). Proves gate 1 (b) passes
# same-prefix evidence.
CYCLE4_EVIDENCE_TXID="$(printf 'bbbb4444%.0s' 1 2 3 4 5 6 7 8)"
cat > "$FIXTURE_DIR/cycle4.json" <<JSON
{"id":"${CYCLE4_EVIDENCE_TXID}","block_num":444444,"actions":[{"act":{"account":"eosio.token","name":"transfer","authorization":[{"actor":"metalfreedom","permission":"anchor"}],"data":{"memo":"fya1c4-test"}}}]}
JSON

# UPDATEAUTH_SAME_TXID: single eosio::updateauth, no memo — matches
# $TEST_TX_UPDATEAUTH's action shape exactly (key-rotation carve-out: (a)
# action-set match applies, (b) memo-prefix match is exempt since neither
# side has an anchor-shaped memo).
UPDATEAUTH_SAME_TXID="$(printf 'cccc5555%.0s' 1 2 3 4 5 6 7 8)"
cat > "$FIXTURE_DIR/updateauth-same.json" <<JSON
{"id":"${UPDATEAUTH_SAME_TXID}","block_num":555555,"actions":[{"act":{"account":"eosio","name":"updateauth","authorization":[{"actor":"metalfreedom","permission":"active"}],"data":{}}}]}
JSON

# UPDATEAUTH_DIFF_TXID: single eosio.token::transfer (memo fya1c4-test) —
# a DIFFERENT action than $TEST_TX_UPDATEAUTH's eosio::updateauth. Proves
# gate 1 (a) still refuses even though neither memo-prefix set applies.
UPDATEAUTH_DIFF_TXID="$(printf 'dddd6666%.0s' 1 2 3 4 5 6 7 8)"
cat > "$FIXTURE_DIR/updateauth-diff.json" <<JSON
{"id":"${UPDATEAUTH_DIFF_TXID}","block_num":666666,"actions":[{"act":{"account":"eosio.token","name":"transfer","authorization":[{"actor":"metalfreedom","permission":"anchor"}],"data":{"memo":"fya1c4-test"}}}]}
JSON

cat > "$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
# Test stub for curl (see tests/safe-broadcast/test-safe-broadcast.sh).
BODY=""
prev=""
for a in "\$@"; do
	if [ "\$prev" = "-d" ]; then
		BODY="\$a"
	fi
	prev="\$a"
done
REQ_ID="\$(printf '%s' "\$BODY" | grep -oE '"id":"[a-f0-9]{64}"' | grep -oE '[a-f0-9]{64}')"
case "\$REQ_ID" in
	"${R16_RESOLVABLE_TXID}")     cat "${FIXTURE_DIR}/r16.json" ;;
	"${CYCLE2_EVIDENCE_TXID}")    cat "${FIXTURE_DIR}/cycle2.json" ;;
	"${CYCLE4_EVIDENCE_TXID}")    cat "${FIXTURE_DIR}/cycle4.json" ;;
	"${UPDATEAUTH_SAME_TXID}")    cat "${FIXTURE_DIR}/updateauth-same.json" ;;
	"${UPDATEAUTH_DIFF_TXID}")    cat "${FIXTURE_DIR}/updateauth-diff.json" ;;
	*)                            echo '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/curl"

export PATH="$STUB_DIR:$PATH"

# ---- §3.5 keystore separation guard: project-keystore HOME fixture ----
# bin/safe-broadcast now refuses (exit 8) if $HOME resolves to the login
# user's default home, before its first real proton invocation (gate 3).
# None of the scenarios below touch a real keystore (proton is stubbed
# above), so scoping HOME to a throwaway fixture dir for the WHOLE suite is
# exactly what a real operator invocation looks like (HOME=~/.metal-fy-proton*)
# and lets every pre-existing gate-3/gate-2b "reaches gate 3" scenario keep
# exercising gate 3 itself, rather than being intercepted by the new guard.
LOGIN_HOME="$(eval echo "~$(id -un)" 2>/dev/null || true)"
TEST_HOME="$(mktemp -d -t safe-bcast-home.XXXXXX)"
export HOME="$TEST_HOME"

cleanup() {
	rm -f "$TEST_TOKEN" "$TEST_AUDIT" "$TEST_TX_VALID" "$TEST_TX_EMPTY" "$TEST_DRY_LOG" \
		"$TEST_TX_CYCLE4" "$TEST_TX_UPDATEAUTH" "$TEST_DRY_LOG_CYCLE4" "$TEST_DRY_LOG_NONJSON"
	rm -rf "$STUB_DIR" "$TEST_HOME" "$FIXTURE_DIR"
}
trap cleanup EXIT

# Prepare test fixtures.
cat > "$TEST_TX_VALID" <<'JSON'
{
  "actions": [
    {
      "account": "eosio.token",
      "name": "transfer",
      "authorization": [{"actor": "metalfreedom", "permission": "anchor"}],
      "data": {"from": "metalfreedom", "to": "fyhistory", "quantity": "0.0001 XPR", "memo": "fya1c3-test"}
    }
  ]
}
JSON
echo '{}' > "$TEST_TX_EMPTY"

# ---- gate 1 / gate 4 shape-binding hardening fixtures (2026-08) ----
# TEST_DRY_LOG: generic mainnet dry-run log paired with $TEST_TX_VALID
# (cycle-3, memo fya1c3-test) across the pre-existing R16 gate-2b/gate-3
# scenarios below. Gate 4 now requires valid JSON + (for anchor-shaped
# outgoing tx) a matching memo_prefix — a bare non-JSON placeholder would
# now be refused at gate 4 before ever reaching those gates, so this must be
# a realistic `sign-anchor-event.sh --dry-run`-shaped JSON document, not
# plain text. Field names (memo_prefix, target_chain) match that script's
# actual --dry-run output (scripts/sign-anchor-event.sh:301, 298).
cat > "$TEST_DRY_LOG" <<'JSON'
{
  "dry_run": true,
  "target_chain": "mainnet-a",
  "memo_prefix": "fya1c3",
  "composed_memos": {"dag_root_summary": "fya1c3:deadbeef"}
}
JSON

# TEST_TX_CYCLE4: cycle-4 shaped mainnet outgoing tx (same structure as
# TEST_TX_VALID, different cycle prefix). Paired with CYCLE2_EVIDENCE_TXID
# (wrong cycle → gate 1 refuse) and CYCLE4_EVIDENCE_TXID (same cycle →
# gate 1 pass).
cat > "$TEST_TX_CYCLE4" <<'JSON'
{
  "actions": [
    {
      "account": "eosio.token",
      "name": "transfer",
      "authorization": [{"actor": "metalfreedom", "permission": "anchor"}],
      "data": {"from": "metalfreedom", "to": "fyhistory", "quantity": "0.0001 XPR", "memo": "fya1c4-test"}
    }
  ]
}
JSON

# TEST_DRY_LOG_CYCLE4: dry-run log matching TEST_TX_CYCLE4's prefix
# (fya1c4) and chain (mainnet-a) — used for the gate 1 + gate 4 combined
# happy-path case, and reused (deliberately mismatched against a cycle-3 tx)
# for the gate-4 memo-prefix-mismatch refusal case below.
cat > "$TEST_DRY_LOG_CYCLE4" <<'JSON'
{
  "dry_run": true,
  "target_chain": "mainnet-a",
  "memo_prefix": "fya1c4",
  "composed_memos": {"dag_root_summary": "fya1c4:deadbeef"}
}
JSON

# TEST_DRY_LOG_NONJSON: not valid JSON at all — for the gate 4 (a) check.
printf 'this is not json\n' > "$TEST_DRY_LOG_NONJSON"

# TEST_TX_UPDATEAUTH: key-rotation shaped outgoing tx — no memo at all, so
# neither gate 1 (b) nor gate 4 (b) (memo-prefix matching) apply; only
# gate 1 (a) (action-set match) and gate 4 (a)/(c) (JSON validity / chain)
# do. Mirrors the existing updateauth-based key-rotation rehearsal flow
# (memory: proton keystore rotation testnet-first) that this hardening must
# not break.
cat > "$TEST_TX_UPDATEAUTH" <<'JSON'
{
  "actions": [
    {
      "account": "eosio",
      "name": "updateauth",
      "authorization": [{"actor": "metalfreedom", "permission": "active"}],
      "data": {"account": "metalfreedom", "permission": "anchor", "parent": "active", "auth": {"threshold": 1, "keys": [], "accounts": [], "waits": []}}
    }
  ]
}
JSON

PASS=0
FAIL=0

run_case() {
	local name="$1"
	local expected_rc="$2"
	shift 2
	local args=("$@")
	local rc
	if [ "${#args[@]}" -eq 0 ]; then
		bash "$WRAPPER" </dev/null >/dev/null 2>&1
	else
		bash "$WRAPPER" "${args[@]}" </dev/null >/dev/null 2>&1
	fi
	rc=$?
	if [ "$rc" -eq "$expected_rc" ]; then
		printf 'PASS  %-70s (rc=%d)\n' "$name" "$rc"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %-70s (rc=%d, expected %d)\n' "$name" "$rc" "$expected_rc" >&2
		FAIL=$((FAIL + 1))
	fi
}

# ---- arg validation (exit 2) ----
run_case "arg: no args" 2
run_case "arg: --tx missing" 2 --chain=testnet-a
run_case "arg: --chain missing" 2 --tx="$TEST_TX_VALID"
run_case "arg: --chain invalid" 2 --tx="$TEST_TX_VALID" --chain=mainnet-c
run_case "arg: --tx file not readable" 2 --tx=/nonexistent/path --chain=testnet-a
run_case "arg: --tx missing .actions" 2 --tx="$TEST_TX_EMPTY" --chain=testnet-a
run_case "arg: unknown flag" 2 --tx="$TEST_TX_VALID" --chain=testnet-a --foo

# ---- gate 2 (token) failure paths (exit 3) ----
rm -f "$TEST_TOKEN"
run_case "gate 2: testnet, token missing" 3 --tx="$TEST_TX_VALID" --chain=testnet-a --non-interactive

# Expired token (400s old > 300s TTL and > 60s tight TTL).
touch "$TEST_TOKEN"
if OLD_TS_UTC="$(date -u -d '@0' +%Y%m%d%H%M 2>/dev/null)"; then
	OLD_TS="$(date -u -d '-400 seconds' +%Y%m%d%H%M)"
else
	OLD_TS="$(date -u -v-400S +%Y%m%d%H%M)"
fi
touch -t "$OLD_TS" "$TEST_TOKEN"
run_case "gate 2: testnet, token stale (400s > 60s tight TTL)" 3 --tx="$TEST_TX_VALID" --chain=testnet-a --non-interactive
run_case "gate 2: testnet, token stale (400s > 300s TTL)" 3 --tx="$TEST_TX_VALID" --chain=testnet-a

# ---- gate 1 + 4 (mainnet-only) failure paths (exit 3) ----
# Fresh token for these tests so gate 2 doesn't short-circuit them.
touch "$TEST_TOKEN"
run_case "gate 1: mainnet, no --testnet-tx-id" 3 --tx="$TEST_TX_VALID" --chain=mainnet-a --non-interactive
run_case "gate 1: mainnet, --testnet-tx-id malformed (not hex)" 3 --tx="$TEST_TX_VALID" --chain=mainnet-a --testnet-tx-id=nothex --non-interactive
run_case "gate 1: mainnet, --testnet-tx-id wrong length (32 hex)" 3 --tx="$TEST_TX_VALID" --chain=mainnet-a --testnet-tx-id=00112233445566778899aabbccddeeff --non-interactive

# Valid-shape testnet-tx-id but nonexistent on chain → resolve fails → exit 3.
# Note: this hits the network. If offline, curl will fail and the wrapper
# will still exit 3, so the test remains deterministic.
run_case "gate 1: mainnet, --testnet-tx-id shape-valid but unresolvable" 3 \
	--tx="$TEST_TX_VALID" \
	--chain=mainnet-a \
	--testnet-tx-id=0000000000000000000000000000000000000000000000000000000000000000 \
	--dry-run-log="$TEST_DRY_LOG" \
	--non-interactive

# ---- gate 1 / gate 4 shape binding (2026-08 hardening) ----
# Audit finding: gate 1 previously only checked the testnet evidence tx was
# 64-hex + resolvable — never that its shape (actions, memo prefix) matched
# the outgoing mainnet tx. A cycle-2 testnet tx (memo prefix fya1c2) could
# therefore authorize a cycle-4 mainnet anchor broadcast. Gate 4 only
# checked the --dry-run-log was non-empty — a log from an unrelated shape
# passed trivially. See the "Gate 1 / Gate 4 shape binding" section in
# bin/safe-broadcast's usage header for the full spec these cases verify.

# gate 1 (b): cycle-2 testnet evidence vs. a cycle-4 mainnet outgoing tx —
# same action shape (eosio.token::transfer) but the memo-prefix SET differs
# (fya1c2 vs fya1c4) → refuse. This is the exact 2026-07-04 cycle-3 incident
# shape (there: cycle-2 evidence authorizing a cycle-3 broadcast).
touch "$TEST_TOKEN"
run_case "gate 1: mainnet, cycle-2 testnet evidence vs cycle-4 outgoing tx → refuse (memo prefix mismatch)" 3 \
	--tx="$TEST_TX_CYCLE4" \
	--chain=mainnet-a \
	--testnet-tx-id="$CYCLE2_EVIDENCE_TXID" \
	--dry-run-log="$TEST_DRY_LOG_CYCLE4" \
	--non-interactive

# gate 1 (a)+(b) combined pass, THEN gate 4 (a)+(b) pass: cycle-4 testnet
# evidence vs. the matching cycle-4 outgoing tx (same action shape, same
# memo prefix) → gate 1 passes; dry-run log memo_prefix (fya1c4) and
# target_chain (mainnet-a) both match → gate 4 passes; a freshly
# chain-bound token → gate 2/2b pass; execution reaches gate 3, where the
# hermetic proton stub (always answers with the TESTNET chain_id)
# deterministically mismatches the MAINNET expected chain_id → exit 4. This
# is the only externally-observable way to prove gate 1 AND gate 4 both
# passed without a live proton/network broadcast (both gates refuse with
# the same exit code 3, so "reached a later, different exit code" is the
# only black-box signal available — same idiom as the pre-existing R16
# gate-2b "passes" case below).
printf '{"chain":"mainnet-a"}' > "$TEST_TOKEN"
run_case "gate 1+4: mainnet, matching cycle-4 evidence + matching dry-run-log → pass (reaches gate 3, exit 4)" 4 \
	--tx="$TEST_TX_CYCLE4" \
	--chain=mainnet-a \
	--testnet-tx-id="$CYCLE4_EVIDENCE_TXID" \
	--dry-run-log="$TEST_DRY_LOG_CYCLE4" \
	--non-interactive

# gate 1 (d) key-rotation carve-out, same action: an updateauth outgoing tx
# (no memo — not anchor-shaped) paired with updateauth testnet evidence of
# the IDENTICAL action shape → gate 1's memo-prefix sub-check (b) does not
# apply (neither side has an anchor-shaped memo); only (a) action-set match
# applies, and it passes. Gate 4's memo-prefix sub-check (b) is likewise
# skipped (outgoing tx isn't anchor-shaped); only (a) JSON-validity and (c)
# chain-match apply, and $TEST_DRY_LOG (mainnet-a) satisfies both. A fresh
# mainnet-bound token clears gate 2/2b, so execution reaches gate 3 →
# exit 4 (same stub-mismatch mechanism as above). This proves the existing
# updateauth-based key-rotation testnet-first flow is NOT broken by this
# hardening.
printf '{"chain":"mainnet-a"}' > "$TEST_TOKEN"
run_case "gate 1: mainnet, updateauth outgoing + same-action testnet evidence → pass (reaches gate 3, exit 4)" 4 \
	--tx="$TEST_TX_UPDATEAUTH" \
	--chain=mainnet-a \
	--testnet-tx-id="$UPDATEAUTH_SAME_TXID" \
	--dry-run-log="$TEST_DRY_LOG" \
	--non-interactive

# gate 1 (a): an updateauth outgoing tx paired with testnet evidence whose
# action is eosio.token::transfer (a DIFFERENT account+name) → refuse, even
# though neither side is anchor-shaped (the memo-prefix sub-check (b) does
# not even come into play — (a) alone already refuses).
touch "$TEST_TOKEN"
run_case "gate 1: mainnet, updateauth outgoing vs different-action testnet evidence → refuse (action set mismatch)" 3 \
	--tx="$TEST_TX_UPDATEAUTH" \
	--chain=mainnet-a \
	--testnet-tx-id="$UPDATEAUTH_DIFF_TXID" \
	--dry-run-log="$TEST_DRY_LOG" \
	--non-interactive

# gate 4 (b): cycle-3 outgoing tx (memo fya1c3-test) whose testnet evidence
# passes gate 1 cleanly (R16_RESOLVABLE_TXID, same cycle-3 shape), but the
# --dry-run-log records memo_prefix "fya1c4" (from $TEST_DRY_LOG_CYCLE4) —
# the WRONG cycle vs. the outgoing tx's actual fya1c3 prefix → gate 4
# refuses. Proves gate 4 checks the log's OWN recorded shape, not just
# gate 1's testnet evidence.
touch "$TEST_TOKEN"
run_case "gate 4: mainnet, dry-run log memo_prefix mismatch vs outgoing tx → refuse" 3 \
	--tx="$TEST_TX_VALID" \
	--chain=mainnet-a \
	--testnet-tx-id="$R16_RESOLVABLE_TXID" \
	--dry-run-log="$TEST_DRY_LOG_CYCLE4" \
	--non-interactive

# gate 4 (a): --dry-run-log exists and is non-empty but is NOT valid JSON →
# refuse, even though gate 1 (R16_RESOLVABLE_TXID vs cycle-3 outgoing tx)
# passes cleanly.
touch "$TEST_TOKEN"
run_case "gate 4: mainnet, dry-run log is not valid JSON → refuse" 3 \
	--tx="$TEST_TX_VALID" \
	--chain=mainnet-a \
	--testnet-tx-id="$R16_RESOLVABLE_TXID" \
	--dry-run-log="$TEST_DRY_LOG_NONJSON" \
	--non-interactive

# ---- keystore guard (§3.5): refuse when $HOME resolves to the login home ----
# The guard sits immediately before gate 3 (this wrapper's first real proton
# invocation). It fires only when $HOME resolves EXACTLY to the login
# user's default home (via `id -un` + `eval echo ~<user>` — independent of
# $HOME itself). We can only assert this deterministically when the test
# runner's login home is resolvable; if not, skip rather than fabricate a
# result.
#
# Reset the token to a bare/legacy (unbound, empty-content) state first: the
# gate 1/gate 4 shape-binding block above left it CONTENT-bound to
# "mainnet-a" (R16 gate 2b), which would otherwise make gate 2b itself
# refuse these testnet-chain cases (a mainnet-bound token cannot authorize
# testnet either, by design) before ever reaching the guard/gate 3 under
# test here. A bare legacy token keeps testnet's backward-compat accept path.
: > "$TEST_TOKEN"
touch "$TEST_TOKEN"
if [ -n "$LOGIN_HOME" ]; then
	export HOME="$LOGIN_HOME"
	run_case "keystore guard: HOME=login home → refuse (exit 8, before gate 3)" 8 \
		--tx="$TEST_TX_VALID" --chain=testnet-a --non-interactive
	export HOME="$TEST_HOME"
else
	printf 'SKIP  %-70s (login home not resolvable in this environment)\n' "keystore guard: HOME=login home → refuse"
fi

# ---- keystore guard (§3.5): pass through when $HOME is a project fixture ----
# HOME is already scoped to $TEST_HOME (a throwaway temp dir, standing in for
# a real ~/.metal-fy-proton-test) for the whole suite (see the export near
# the top of this file). This case shows that explicitly: the guard does
# NOT fire, and execution proceeds to gate 3, where the hermetic proton stub
# (testnet chain_id) matches the default expected testnet chain_id → the
# broadcast then reaches the interactive confirmation prompt, which aborts
# immediately on EOF stdin (run_case redirects `</dev/null`) → exit 5.
# This proves pass-through without needing a real proton/network broadcast.
touch "$TEST_TOKEN"
run_case "keystore guard: HOME=project fixture dir → passes (reaches gate 3+confirm, exit 5)" 5 \
	--tx="$TEST_TX_VALID" --chain=testnet-a

# ---- gate 3 (chain identity) failure path (exit 4) ----
# Force a chain_id mismatch by overriding the expected testnet chain_id to a
# value that cannot match the live chain. This exercises the identity check and
# refuses BEFORE any broadcast (exit 4, before the pre-broadcast audit log).
# Deterministic across environments: with proton present the real chain_id
# differs from this bogus expectation; without proton (or offline) the wrapper
# also exits 4 (proton-not-found / chain:set / parse failure all map to 4).
touch "$TEST_TOKEN"
export FYD_TESTNET_CHAIN_ID="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
run_case "gate 3: testnet, chain_id mismatch → refuse (exit 4)" 4 \
	--tx="$TEST_TX_VALID" --chain=testnet-a --non-interactive
unset FYD_TESTNET_CHAIN_ID

# ---- R16: gate 2b (operator token CONTENT binding) ----
# Freshness alone used to be sufficient (gate 2 above) — a token
# touched/bound for testnet could otherwise silently authorize an unrelated
# mainnet broadcast within the same TTL window. These cases exercise the
# chain-binding and tx-content-binding checks directly.
#
# The mainnet-path cases need gate 1 (--testnet-tx-id resolution) to PASS
# first, since gate 1 runs before gate 2/2b in the wrapper. R16_RESOLVABLE_TXID
# (set up alongside the hermetic curl stub near the top of this file) is a
# sentinel id our stub curl resolves deterministically offline, distinct
# from the pre-existing "unresolvable" all-zeros fixture above.
if command -v sha256sum >/dev/null 2>&1; then
	TEST_TX_VALID_SHA256="$(jq -c . "$TEST_TX_VALID" | sha256sum | awk '{print $1}')"
else
	TEST_TX_VALID_SHA256="$(jq -c . "$TEST_TX_VALID" | shasum -a 256 | awk '{print $1}')"
fi

# Mismatched chain binding: token bound to testnet-a, broadcast targets
# mainnet-a → refuse at gate 2b (exit 3), BEFORE gate 3 is ever reached.
# This is the exact scenario R16 exists to close: a testnet-bound token
# must not be able to authorize a mainnet broadcast.
printf '{"chain":"testnet-a"}' > "$TEST_TOKEN"
run_case "gate 2b: mainnet, token bound to testnet-a → refuse (exit 3)" 3 \
	--tx="$TEST_TX_VALID" \
	--chain=mainnet-a \
	--testnet-tx-id="$R16_RESOLVABLE_TXID" \
	--dry-run-log="$TEST_DRY_LOG" \
	--non-interactive

# Legacy/unbound token (bare touch — no JSON content): mainnet refuses
# unconditionally, fail-closed. (Testnet keeps accepting this for backward
# compatibility — already proven by the "gate 3: testnet, chain_id
# mismatch" case above, which uses a bare-touched token and still reaches
# gate 3, not gate 2.)
: > "$TEST_TOKEN"
touch "$TEST_TOKEN"
run_case "gate 2b: mainnet, legacy/unbound token → refuse (exit 3, fail-closed)" 3 \
	--tx="$TEST_TX_VALID" \
	--chain=mainnet-a \
	--testnet-tx-id="$R16_RESOLVABLE_TXID" \
	--dry-run-log="$TEST_DRY_LOG" \
	--non-interactive

# Correctly-bound token (chain=mainnet-a, matching --chain=mainnet-a): gate
# 2b passes and processing reaches gate 3, where the hermetic proton stub
# (which always answers with the TESTNET chain_id) deterministically
# mismatches the MAINNET expected chain_id → exit 4. This proves the token
# was accepted through gate 2b — a correctly-bound token still authorizes,
# as far as this hermetic suite can observe without a live proton/network
# (full success is covered by the testnet E2E rehearsal, T-I-20260701).
printf '{"chain":"mainnet-a"}' > "$TEST_TOKEN"
run_case "gate 2b: mainnet, token correctly bound to mainnet-a → passes (reaches gate 3, exit 4)" 4 \
	--tx="$TEST_TX_VALID" \
	--chain=mainnet-a \
	--testnet-tx-id="$R16_RESOLVABLE_TXID" \
	--dry-run-log="$TEST_DRY_LOG" \
	--non-interactive

# tx_sha256 binding (stronger, optional layer): chain matches but the bound
# tx_sha256 does not match the actual --tx content → refuse (exit 3).
printf '{"chain":"testnet-a","tx_sha256":"%s"}' "0000000000000000000000000000000000000000000000000000000000000000" > "$TEST_TOKEN"
run_case "gate 2b: testnet, tx_sha256 bound but mismatched → refuse (exit 3)" 3 \
	--tx="$TEST_TX_VALID" --chain=testnet-a --non-interactive

# tx_sha256 binding: chain AND tx_sha256 both match → gate 2b passes,
# reaches gate 3 (exit 4 via the same bogus FYD_TESTNET_CHAIN_ID override
# used in the "gate 3: testnet, chain_id mismatch" case above).
export FYD_TESTNET_CHAIN_ID="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
printf '{"chain":"testnet-a","tx_sha256":"%s"}' "$TEST_TX_VALID_SHA256" > "$TEST_TOKEN"
run_case "gate 2b: testnet, chain+tx_sha256 correctly bound → passes (reaches gate 3, exit 4)" 4 \
	--tx="$TEST_TX_VALID" --chain=testnet-a --non-interactive
unset FYD_TESTNET_CHAIN_ID

# ---- audit log: no line written on gate refusal (pre-log happens only after gates pass) ----
if [ ! -s "$TEST_AUDIT" ]; then
	printf 'PASS  %-70s (empty)\n' "audit log: no lines on gate refusal"
	PASS=$((PASS + 1))
else
	printf 'FAIL  %-70s (unexpected content: %d bytes)\n' "audit log: no lines on gate refusal" "$(wc -c < "$TEST_AUDIT")" >&2
	FAIL=$((FAIL + 1))
fi

# ---- audit log FALLBACK path (§3.5 follow-up): resolves against the LOGIN
# home, not a keystore-scoped $HOME ----
# bin/safe-broadcast computes AUDIT_LOG_FALLBACK via fyd_login_home()
# (scripts/lib/require-keystore-home.sh) rather than reading $HOME
# directly, so that a §3.5-compliant HOME=~/.metal-fy-proton[-test]
# invocation does not relocate the fallback audit log into the keystore
# dir and split it from the canonical ~/.fyd-broadcast-audit.log history.
# Reproduce the EXACT expression bin/safe-broadcast uses (see the
# AUDIT_LOG_FALLBACK assignment near its top) in a fresh subshell with
# HOME scoped to a throwaway keystore fixture dir — exactly how a real
# operator invocation sets it — and assert the result resolves under the
# real LOGIN home, not the fixture. This never invokes proton, writes no
# file, and does not touch the real login home directory; it only checks
# the computed PATH STRING.
if [ -n "$LOGIN_HOME" ]; then
	FALLBACK_PROBE="$(mktemp -t safe-bcast-fallback-probe.XXXXXX)"
	cat > "$FALLBACK_PROBE" <<PROBE
. "${REPO_ROOT}/scripts/lib/require-keystore-home.sh"
_login_home="\$(fyd_login_home || true)"
printf '%s' "\${_login_home:-/tmp}/.fyd-broadcast-audit.log"
PROBE
	RESOLVED_FALLBACK="$(HOME="$TEST_HOME" bash "$FALLBACK_PROBE")"
	rm -f "$FALLBACK_PROBE"
	EXPECTED_FALLBACK="${LOGIN_HOME}/.fyd-broadcast-audit.log"
	if [ "$RESOLVED_FALLBACK" = "$EXPECTED_FALLBACK" ]; then
		printf 'PASS  %-70s (%s)\n' "audit log fallback: HOME=keystore fixture → resolves under LOGIN home" "$RESOLVED_FALLBACK"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %-70s (got [%s], expected [%s])\n' "audit log fallback: HOME=keystore fixture → resolves under LOGIN home" "$RESOLVED_FALLBACK" "$EXPECTED_FALLBACK" >&2
		FAIL=$((FAIL + 1))
	fi
	case "$RESOLVED_FALLBACK" in
		"$TEST_HOME"/*)
			printf 'FAIL  %-70s (resolved under keystore fixture: %s)\n' "audit log fallback: does NOT relocate into the keystore dir" "$RESOLVED_FALLBACK" >&2
			FAIL=$((FAIL + 1))
			;;
		*)
			printf 'PASS  %-70s\n' "audit log fallback: does NOT relocate into the keystore dir"
			PASS=$((PASS + 1))
			;;
	esac
else
	printf 'SKIP  %-70s (login home not resolvable in this environment)\n' "audit log fallback: HOME=keystore fixture → resolves under LOGIN home"
	printf 'SKIP  %-70s (login home not resolvable in this environment)\n' "audit log fallback: does NOT relocate into the keystore dir"
fi

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-safe-broadcast.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
