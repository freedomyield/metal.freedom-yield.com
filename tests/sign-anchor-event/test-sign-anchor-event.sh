#!/usr/bin/env bash
# test-sign-anchor-event.sh — regression suite for scripts/sign-anchor-event.sh
# (HC-single 4-action pack composer, delegates broadcast to bin/safe-broadcast).
#
# CHAIN: none — most cases exercise --dry-run only, which composes the tx
#        JSON without invoking bin/safe-broadcast. The keystore-guard cases
#        near the end DO reach past the --dry-run-only path, but only as far
#        as bin/safe-broadcast's own gate 2 (a stub `proton` on PATH + an
#        isolated, guaranteed-missing operator token file make that a
#        deterministic local failure) — no broadcast occurs anywhere below.
#
# Usage:
#   bash tests/sign-anchor-event/test-sign-anchor-event.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/sign-anchor-event.sh"

if [ ! -x "$SCRIPT" ]; then
	echo "FATAL: sign-anchor-event.sh not executable at $SCRIPT" >&2
	exit 1
fi

# Isolate config to a temp dir so we don't touch /etc/freedom-yield.
TMP_CFG="$(mktemp -d -t fya-sign-cfg.XXXXXX)"
TMP_ANCHOR_BAD_DAG="$(mktemp -t fya-sign-anchor.XXXXXX).json"
TMP_ANCHOR_MISSING_CYCLE="$(mktemp -t fya-sign-anchor.XXXXXX).json"
export FY_CONFIG_DIR="$TMP_CFG"

echo "metalfreedom" > "$TMP_CFG/xpr-account"
echo "fyhistory"    > "$TMP_CFG/anchor-sink"
echo "0.0001 XPR"   > "$TMP_CFG/xpr-quantity"

# Bad-dag anchor-source: valid shape but dag_root_computed does not match
# the recomputation. Should be caught by belt+suspenders verify.
cp "${REPO_ROOT}/public/api/anchor-source.example.json" "$TMP_ANCHOR_BAD_DAG"
# Overwrite dag_root_computed with a plausible but wrong 64-hex.
jq '.dag_root_computed = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"' \
	"$TMP_ANCHOR_BAD_DAG" > "$TMP_ANCHOR_BAD_DAG.tmp" && mv "$TMP_ANCHOR_BAD_DAG.tmp" "$TMP_ANCHOR_BAD_DAG"

# Missing-cycle anchor-source: cycle_number_observed <= 0.
cp "${REPO_ROOT}/public/api/anchor-source.example.json" "$TMP_ANCHOR_MISSING_CYCLE"
jq '.observations_branch.cycle_number_observed = 0' \
	"$TMP_ANCHOR_MISSING_CYCLE" > "$TMP_ANCHOR_MISSING_CYCLE.tmp" && mv "$TMP_ANCHOR_MISSING_CYCLE.tmp" "$TMP_ANCHOR_MISSING_CYCLE"

# ---- §3.5 keystore separation guard fixtures ----
# A hermetic `proton` stub (just enough to satisfy `command -v proton`; it
# is never actually asked to sign or broadcast anything) plus a project
# keystore HOME fixture, mirroring tests/safe-broadcast/test-safe-broadcast.sh.
LOGIN_HOME="$(eval echo "~$(id -un)" 2>/dev/null || true)"
TEST_HOME="$(mktemp -d -t fya-sign-home.XXXXXX)"
STUB_DIR="$(mktemp -d -t fya-sign-stub.XXXXXX)"
cat > "$STUB_DIR/proton" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_DIR/proton"
export PATH="$STUB_DIR:$PATH"
export HOME="$TEST_HOME"
# Guaranteed-missing token path so a guard pass-through deterministically
# fails at bin/safe-broadcast's gate 2 (token missing) rather than picking
# up a stray real /tmp/fyd-broadcast-token from this machine.
NO_TOKEN_FILE="$(mktemp -u -t fya-sign-notoken.XXXXXX)"
export FYD_BROADCAST_TOKEN_FILE="$NO_TOKEN_FILE"

cleanup() {
	rm -rf "$TMP_CFG" "$TEST_HOME" "$STUB_DIR"
	rm -f "$TMP_ANCHOR_BAD_DAG" "$TMP_ANCHOR_MISSING_CYCLE"
}
trap cleanup EXIT

PASS=0
FAIL=0

run_case() {
	local name="$1"
	local expected_rc="$2"
	shift 2
	local rc
	bash "$SCRIPT" "$@" >/dev/null 2>&1
	rc=$?
	if [ "$rc" -eq "$expected_rc" ]; then
		printf 'PASS  %-70s (rc=%d)\n' "$name" "$rc"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %-70s (rc=%d, expected %d)\n' "$name" "$rc" "$expected_rc" >&2
		FAIL=$((FAIL + 1))
	fi
}

# ---- arg validation (exit 1) ----
run_case "arg: no args" 1
run_case "arg: --chain missing" 1 --anchor-source="${REPO_ROOT}/public/api/anchor-source.example.json" --dry-run
run_case "arg: --chain invalid" 1 --chain=mainnet-c --dry-run
run_case "arg: unknown flag" 1 --chain=testnet-a --foo

# ---- anchor-source validation (exit 2) ----
run_case "anchor-source: file missing" 2 --chain=testnet-a --anchor-source=/nonexistent --dry-run
run_case "anchor-source: dag_root mismatch" 2 --chain=testnet-a --anchor-source="$TMP_ANCHOR_BAD_DAG" --dry-run
run_case "anchor-source: cycle_number 0" 2 --chain=testnet-a --anchor-source="$TMP_ANCHOR_MISSING_CYCLE" --dry-run

# ---- happy path: --dry-run with example.json ----
run_case "dry-run: testnet-a, example.json" 0 \
	--chain=testnet-a --anchor-source="${REPO_ROOT}/public/api/anchor-source.example.json" --dry-run
run_case "dry-run: mainnet-a, example.json (no gate check in dry-run)" 0 \
	--chain=mainnet-a --anchor-source="${REPO_ROOT}/public/api/anchor-source.example.json" --dry-run

# ---- structure verification of dry-run output ----
DRY_OUT="$(bash "$SCRIPT" --chain=testnet-a \
	--anchor-source="${REPO_ROOT}/public/api/anchor-source.example.json" --dry-run 2>/dev/null)"

check_structure() {
	local name="$1" expected="$2" actual="$3"
	if [ "$actual" = "$expected" ]; then
		printf 'PASS  %-70s (value=%s)\n' "$name" "$actual"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %-70s (actual=%s, expected=%s)\n' "$name" "$actual" "$expected" >&2
		FAIL=$((FAIL + 1))
	fi
}

check_structure "structure: dry_run == true"      "true"    "$(echo "$DRY_OUT" | jq -r .dry_run)"
check_structure "structure: target_chain"         "testnet-a" "$(echo "$DRY_OUT" | jq -r .target_chain)"
check_structure "structure: schema_version"       "1"       "$(echo "$DRY_OUT" | jq -r .schema_version)"
check_structure "structure: memo_prefix pivot"    "fya1c2"  "$(echo "$DRY_OUT" | jq -r .memo_prefix)"
check_structure "structure: 4 actions in tx"      "4"       "$(echo "$DRY_OUT" | jq '.tx.actions | length')"
check_structure "structure: 4 composed_memos keys" "4"      "$(echo "$DRY_OUT" | jq '.composed_memos | keys | length')"
check_structure "structure: identity memo begins fya1c2-id:" "true" \
	"$(echo "$DRY_OUT" | jq -r '.composed_memos.identity | startswith("fya1c2-id:")')"
check_structure "structure: dag_root_summary memo has no branch suffix" "true" \
	"$(echo "$DRY_OUT" | jq -r '.composed_memos.dag_root_summary | test("^fya1c2:[0-9a-f]{64}$")')"
check_structure "structure: all 4 actions target eosio.token::transfer" "true" \
	"$(echo "$DRY_OUT" | jq -r '[.tx.actions[] | (.account == "eosio.token" and .name == "transfer")] | all')"
check_structure "structure: all 4 actions authorized by metalfreedom@anchor" "true" \
	"$(echo "$DRY_OUT" | jq -r '[.tx.actions[] | (.authorization[0].actor == "metalfreedom" and .authorization[0].permission == "anchor")] | all')"

# ---- keystore guard (§3.5): refuse when $HOME resolves to the login home ----
# Non-dry-run path: the stub `proton` on PATH satisfies the signing-host
# assertion (command -v proton), so execution reaches the guard just after
# it. Only assertable when the test runner's login home is resolvable.
if [ -n "$LOGIN_HOME" ]; then
	export HOME="$LOGIN_HOME"
	run_case "keystore guard: HOME=login home → refuse (exit 8)" 8 \
		--chain=testnet-a --anchor-source="${REPO_ROOT}/public/api/anchor-source.example.json"
	export HOME="$TEST_HOME"
else
	printf 'SKIP  %-70s (login home not resolvable in this environment)\n' "keystore guard: HOME=login home → refuse"
fi

# ---- keystore guard (§3.5): pass through when $HOME is a project fixture ----
# HOME=$TEST_HOME (not the login home) → the guard does not fire, execution
# proceeds to delegate to bin/safe-broadcast, which (with the same stub
# proton + an isolated, guaranteed-missing $FYD_BROADCAST_TOKEN_FILE) fails
# deterministically at ITS OWN gate 2 (token missing, rc=3) — sign-anchor-event.sh
# maps any non-zero safe-broadcast rc to its own exit 5. This proves
# pass-through (a real keystore guard failure would be exit 8, not 5) without
# any real proton signing or network broadcast.
run_case "keystore guard: HOME=project fixture dir → passes (delegates, exit 5)" 5 \
	--chain=testnet-a --anchor-source="${REPO_ROOT}/public/api/anchor-source.example.json"

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-sign-anchor-event.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
