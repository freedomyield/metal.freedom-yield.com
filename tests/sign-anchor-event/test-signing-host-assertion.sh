#!/usr/bin/env bash
# test-signing-host-assertion.sh — regression for the signing-host preflight
# (exit 7) added to scripts/sign-anchor-event.sh in commit 5e73afe
# (design-stocktake #6).
#
# The guard: in broadcast mode (NOT --dry-run), sign-anchor-event.sh refuses to
# reach bin/safe-broadcast on a host that lacks the `proton` CLI, because the
# <xpr-account>@anchor signing key lives only in the operator's Mac keystore.
# `command -v proton` failing is the trip wire → exit 7, BEFORE any broadcast
# delegation.
#
# CHAIN: none. The guard fires strictly before bin/safe-broadcast is invoked, so
#        no transaction can be composed-and-pushed. We further guarantee safety
#        by running with a scrubbed PATH that provides every tool the script
#        needs up to the guard but deliberately NO `proton` — so even on the
#        operator Mac (where proton IS installed) this test exercises the guard,
#        never a live broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. exit-code assertions only.
#
# Usage:
#   bash tests/sign-anchor-event/test-signing-host-assertion.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/sign-anchor-event.sh"
ANCHOR_SRC="${REPO_ROOT}/public/api/anchor-source.example.json"

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

[ -x "$SCRIPT" ]     || { echo "FATAL: sign-anchor-event.sh not executable at $SCRIPT" >&2; exit 1; }
[ -r "$ANCHOR_SRC" ] || { echo "FATAL: anchor-source example missing at $ANCHOR_SRC" >&2; exit 1; }

# --- isolated config dir (never touch /etc/freedom-yield) ---
CFG="$(mktemp -d -t fya-signhost-cfg.XXXXXX)"
echo "metalfreedom" > "$CFG/xpr-account"
echo "fyhistory"    > "$CFG/anchor-sink"
echo "0.0001 XPR"   > "$CFG/xpr-quantity"

# --- PATH farm WITHOUT proton -------------------------------------------------
# Symlink exactly the tools sign-anchor-event.sh uses up to the guard, but never
# proton. Running with PATH=$FARM makes `command -v proton` fail deterministically
# regardless of whether proton is installed on this host.
FARM="$(mktemp -d -t fya-signhost-bin.XXXXXX)"
for t in bash jq awk grep sed tr head cat mktemp rm dirname basename \
         sha256sum shasum printf date env cut sort wc; do
	p="$(command -v "$t" 2>/dev/null || true)"
	[ -n "$p" ] && ln -sf "$p" "$FARM/$t"
done

cleanup() { rm -rf "$CFG" "$FARM"; }
trap cleanup EXIT

# Harness sanity: proton MUST be unreachable via the scrubbed PATH, otherwise the
# broadcast-mode cases would risk reaching bin/safe-broadcast. Refuse to proceed.
if PATH="$FARM" command -v proton >/dev/null 2>&1; then
	fail "harness leaked proton into scrubbed PATH — refusing to run broadcast-mode cases"
	echo
	echo "test-signing-host-assertion.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: FAIL"
	exit 1
fi

# ---- Case 1: testnet-a broadcast mode, no proton -> exit 7 ----
out="$(PATH="$FARM" FY_CONFIG_DIR="$CFG" \
	bash "$SCRIPT" --chain=testnet-a --anchor-source="$ANCHOR_SRC" --non-interactive 2>&1)"
rc=$?
if [ "$rc" -eq 7 ]; then pass "testnet-a broadcast + no proton -> exit 7"; else fail "testnet-a: expected exit 7, got $rc"; fi
if echo "$out" | grep -q "proton CLI not found"; then
	pass "guard emits 'proton CLI not found' message"
else
	fail "guard message missing; got: $(echo "$out" | tr '\n' '|')"
fi

# ---- Case 2: mainnet-a broadcast mode, no proton -> exit 7 (guard is chain-agnostic, still no broadcast) ----
rc=0
PATH="$FARM" FY_CONFIG_DIR="$CFG" \
	bash "$SCRIPT" --chain=mainnet-a --anchor-source="$ANCHOR_SRC" --non-interactive >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 7 ]; then pass "mainnet-a broadcast + no proton -> exit 7 (no broadcast reached)"; else fail "mainnet-a: expected exit 7, got $rc"; fi

# ---- Case 3 (control): --dry-run never reaches the guard even without proton -> exit 0 ----
rc=0
PATH="$FARM" FY_CONFIG_DIR="$CFG" \
	bash "$SCRIPT" --chain=testnet-a --anchor-source="$ANCHOR_SRC" --dry-run >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass "control: --dry-run exits 0 before the guard (no proton needed)"; else fail "control: --dry-run expected exit 0, got $rc"; fi

echo
echo "----------------------------------------"
echo "test-signing-host-assertion.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
