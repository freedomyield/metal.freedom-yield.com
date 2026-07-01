#!/usr/bin/env bash
# test-broadcast-guard.sh — regression suite for scripts/broadcast-guard.sh
# (tier-1 PreToolUse hook enforcing docs/CONSTITUTION.md PRIME DIRECTIVE).
#
# CHAIN: none — this test does not broadcast; it drives the guard with
#        synthetic Claude Code PreToolUse hook JSON inputs and asserts
#        exit codes.
#
# Usage:
#   bash tests/broadcast-guard/test-broadcast-guard.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED (with per-case detail on stderr)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_ROOT}/scripts/broadcast-guard.sh"

if [ ! -x "$GUARD" ]; then
	echo "FATAL: guard not executable at $GUARD" >&2
	exit 1
fi

# Isolate the test from any real operator token so tests are deterministic.
TEST_TOKEN="$(mktemp -t fyd-guard-test.XXXXXX)"
export FYD_BROADCAST_TOKEN_FILE="$TEST_TOKEN"
# Point audit log at a scratch file so tests don't touch the real one.
TEST_AUDIT_LOG="$(mktemp -t fyd-guard-audit.XXXXXX)"
export FYD_BROADCAST_AUDIT_LOG="$TEST_AUDIT_LOG"

cleanup() { rm -f "$TEST_TOKEN" "$TEST_AUDIT_LOG"; }
trap cleanup EXIT

PASS=0
FAIL=0

run_case() {
	local name="$1"
	local expected_rc="$2"
	local input="$3"
	local rc
	echo "$input" | bash "$GUARD" >/dev/null 2>&1
	rc=$?
	if [ "$rc" -eq "$expected_rc" ]; then
		printf 'PASS  %-60s (rc=%d)\n' "$name" "$rc"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %-60s (rc=%d, expected %d)\n' "$name" "$rc" "$expected_rc" >&2
		FAIL=$((FAIL + 1))
	fi
}

# Ensure clean state: no token file present.
rm -f "$TEST_TOKEN"

# ---- allow cases (no broadcast shape) ----
run_case "allow: benign ls" 0 \
	'{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
run_case "allow: git status" 0 \
	'{"tool_name":"Bash","tool_input":{"command":"git status --short"}}'
run_case "allow: benign curl (no push_transaction/issueTx path)" 0 \
	'{"tool_name":"Bash","tool_input":{"command":"curl -sS https://example.com/api/version"}}'
run_case "allow: non-Bash tool (Read)" 0 \
	'{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
run_case "allow: non-Bash tool (Write)" 0 \
	'{"tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"y"}}'
run_case "allow: empty Bash command" 0 \
	'{"tool_name":"Bash","tool_input":{"command":""}}'
run_case "allow: word 'proton' in unrelated context (grep, echo)" 0 \
	'{"tool_name":"Bash","tool_input":{"command":"grep proton scripts/*.sh"}}'
run_case "allow: word 'cleos' in unrelated context (which)" 0 \
	'{"tool_name":"Bash","tool_input":{"command":"which cleos"}}'

# ---- block cases (broadcast shape, no token) ----
run_case "block: proton action" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"proton action eosio.token transfer arg"}}'
run_case "block: proton transaction" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"proton transaction {}"}}'
run_case "block: proton transaction:push" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"proton transaction:push arg"}}'
run_case "block: cleos push transaction" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"cleos push transaction tx.json"}}'
run_case "block: cleos push_transaction (underscore form)" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"cleos --url=http://x push_transaction tx.json"}}'
run_case "block: cleos push action" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"cleos push action eosio.token transfer arg"}}'
run_case "block: curl push_transaction endpoint" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"curl -sS -X POST http://api/v1/chain/push_transaction -d @tx.json"}}'
run_case "block: curl issueTx endpoint" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"curl -X POST http://node/ext/bc/P/issueTx -d @tx.json"}}'
run_case "block: curl eth_sendRawTransaction" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"curl http://node -d {\"method\":\"eth_sendRawTransaction\"}"}}'
run_case "block: curl /ext/bc/X issueTx" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"curl http://node/ext/bc/X/issueTx"}}'
run_case "block: curl /ext/bc/C issueTx" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"curl http://node/ext/bc/C/issueTx"}}'
run_case "block: wget push_transaction" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"wget --post-data=@tx.json http://api/v1/chain/push_transaction"}}'
run_case "block: metalgo IssueTx" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"metalgo IssueTx arg"}}'

# ---- token override: allow broadcast shape when fresh token present ----
touch "$TEST_TOKEN"
run_case "override: proton transaction:push WITH fresh token → allow" 0 \
	'{"tool_name":"Bash","tool_input":{"command":"proton transaction:push arg"}}'
run_case "override: curl issueTx WITH fresh token → allow" 0 \
	'{"tool_name":"Bash","tool_input":{"command":"curl http://node/ext/bc/P/issueTx"}}'

# Audit log side-effect: 2 successful override cases → 2 lines appended.
AUDIT_LINES="$(wc -l < "$TEST_AUDIT_LOG" | tr -d ' ')"
if [ "$AUDIT_LINES" -eq 2 ]; then
	printf 'PASS  %-60s (lines=%d)\n' "audit log: 2 lines appended on override" "$AUDIT_LINES"
	PASS=$((PASS + 1))
else
	printf 'FAIL  %-60s (lines=%d, expected 2)\n' "audit log: 2 lines appended on override" "$AUDIT_LINES" >&2
	FAIL=$((FAIL + 1))
fi

# ---- expired token: block even with token file present ----
# Backdate the token by 400 seconds (> 300 TTL).
# Portable touch -d / -t handling: use -t YYYYMMDDhhmm on both GNU + BSD.
if OLD_TS_UTC="$(date -u -d '@0' +%Y%m%d%H%M 2>/dev/null)"; then
	# GNU date
	OLD_TS="$(date -u -d '-400 seconds' +%Y%m%d%H%M)"
else
	# BSD date (macOS)
	OLD_TS="$(date -u -v-400S +%Y%m%d%H%M)"
fi
touch -t "$OLD_TS" "$TEST_TOKEN"
run_case "expired: proton transaction:push WITH stale token → block" 1 \
	'{"tool_name":"Bash","tool_input":{"command":"proton transaction:push arg"}}'

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-broadcast-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
