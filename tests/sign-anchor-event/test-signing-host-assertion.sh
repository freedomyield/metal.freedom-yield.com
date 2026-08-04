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

# --- isolate the --output default path (never touch the real /tmp default) ---
# Case 3 below is --dry-run, which DOES reach sign-anchor-event.sh's
# write_output_fragment step (cases 1/2 exit at the signing-host guard,
# before that step, so they cannot reach it regardless). Without this
# override, case 3 would write the real /tmp/fya-testnet-sign-output.json —
# a live operator artifact, not test scratch. See scripts/sign-anchor-event.sh
# FY_SIGN_OUTPUT_DIR usage note and tests/sign-anchor-event/test-sign-anchor-event.sh
# for the same fix applied there.
SIGN_OUTPUT_DIR="$(mktemp -d -t fya-signhost-output.XXXXXX)"
export FY_SIGN_OUTPUT_DIR="$SIGN_OUTPUT_DIR"

# Snapshot the real default path now (content hash, or ABSENT) so the
# invariant check near the end of this file can prove it went untouched.
if command -v sha256sum >/dev/null 2>&1; then
	real_default_hash() { [ -r "$1" ] && sha256sum "$1" | awk '{print $1}' || echo "ABSENT"; }
else
	real_default_hash() { [ -r "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "ABSENT"; }
fi
REAL_DEFAULT_TESTNET="/tmp/fya-testnet-sign-output.json"
REAL_DEFAULT_TESTNET_BEFORE="$(real_default_hash "$REAL_DEFAULT_TESTNET")"

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

cleanup() { rm -rf "$CFG" "$FARM" "$SIGN_OUTPUT_DIR"; }
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

# Case 3 is the only case above that reaches write_output_fragment (cases 1/2
# exit 7 at the guard, before that step) — confirm its output actually landed
# under FY_SIGN_OUTPUT_DIR, not the real /tmp default.
if [ -r "$SIGN_OUTPUT_DIR/fya-testnet-sign-output.json" ]; then
	pass "case 3 output landed under FY_SIGN_OUTPUT_DIR, not the real /tmp default"
else
	fail "case 3 output missing from FY_SIGN_OUTPUT_DIR — check the override actually applied"
fi

# Invariant: the real /tmp default path must be exactly as it was before this
# suite ran (untouched, or still absent), regardless of which case would
# otherwise reach it.
if [ "$REAL_DEFAULT_TESTNET_BEFORE" = "$(real_default_hash "$REAL_DEFAULT_TESTNET")" ]; then
	pass "real /tmp default path untouched by this entire suite"
else
	fail "real /tmp default path CHANGED by this suite (was: $REAL_DEFAULT_TESTNET_BEFORE)"
fi

echo
echo "----------------------------------------"
echo "test-signing-host-assertion.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
