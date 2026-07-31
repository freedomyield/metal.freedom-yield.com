#!/usr/bin/env bash
# preview-cycle-anchor-broadcast.sh — STAGE 1 of a mainnet A-chain anchor
# broadcast, for any cycle. (Renamed from preview-cycle3-anchor-broadcast.sh,
# which hardcoded cycle 3; this version derives the cycle number from
# --source instead of assuming one.)
#
# One-shot operator preview (no automated test by design — it broadcasts
# nothing and only displays the composed transaction shape for review).
#
# Refreshes anchor-source.json (v2 3-branch composition), generates the mainnet
# --dry-run-log (safe-broadcast gate-4 material), and DISPLAYS the exact
# transaction shape a subsequent sign-anchor-event.sh broadcast would inscribe.
#
# BROADCASTS NOTHING. Invokes no `proton transaction` / real safe-broadcast
# call. Touches no operator token. Only (re)writes the regenerable
# anchor-source.json + a temp dry-run-log — both idempotent. Run as the deploy
# user on the validator host.
#
# STAGE 2 (the actual broadcast) is a SEPARATE, operator-authorized step
# printed at the end of this script's output, and runs on the operator's
# Mac (sign-anchor-event.sh's real broadcast path requires the Mac-only
# signing host; see the signing-host assertion in sign-anchor-event.sh).
#
# Usage:
#   bash scripts/preview-cycle-anchor-broadcast.sh --testnet-tx-id=<64-hex> \
#       [--source=public/api/anchor-source.json]
#
# Args:
#   --testnet-tx-id=<64hex>  Required. The latest testnet rehearsal tx id for
#                            THIS cycle's exact memo shape (gate 1 material).
#                            No default: a stale tx id from a prior cycle
#                            would silently satisfy gate 1's Hyperion lookup
#                            without proving today's shape.
#   --source=<path>          Default: public/api/anchor-source.json (relative
#                            to $REPO). The cycle number displayed below is
#                            derived from this file's
#                            observations_branch.cycle_number_observed — this
#                            script makes no assumption about which cycle is
#                            current.
#
# Env overrides: REPO, DRYLOG (same meaning as before); TESTNET_TX_ID and
# SOURCE_PATH are equivalent to the two flags above (flags take precedence).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/require-keystore-home.sh
. "${SCRIPT_DIR}/lib/require-keystore-home.sh"

# ---- §3.5 keystore separation guard (fail-closed) ----
# Must precede this script's only proton invocation ([4/5] gate3 probe
# below, `proton chain:info`) — placed here, before anything else runs
# (including the anchor-source.json regeneration in [1/5]), so a misscoped
# HOME refuses before any side effect, not just before the proton call.
# Exit 8 = keystore guard failed (§3.5), by convention with bin/safe-broadcast
# and scripts/sign-anchor-event.sh, which share this same check.
require_project_keystore_home "$0" || exit 8

# ---- args ----
SOURCE_PATH="${SOURCE_PATH:-public/api/anchor-source.json}"
TESTNET_TX_ID="${TESTNET_TX_ID:-}"
for arg in "$@"; do
	case "$arg" in
		--source=*)        SOURCE_PATH="${arg#*=}" ;;
		--testnet-tx-id=*) TESTNET_TX_ID="${arg#*=}" ;;
		--help|-h)
			sed -n '1,/^set -euo pipefail$/p' "$0" >&2
			exit 0 ;;
		*) echo "ERROR: unknown arg '$arg'" >&2; exit 1 ;;
	esac
done

if [ -z "$TESTNET_TX_ID" ]; then
	echo "ERROR: --testnet-tx-id=<64-hex> is required (see --help)." >&2
	exit 1
fi

REPO="${REPO:-/home/deploy/metal.freedom-yield.com}"
DRYLOG="${DRYLOG:-/home/deploy/.fya-mainnet-dryrun.json}"
EXPECTED_CHAIN_ID="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
TESTNET_HIST="https://test.proton.eosusa.io/v1/history/get_transaction"

cd "$REPO"

echo "════════════════════════════════════════════════════════════════"
echo "  STAGE 1 — mainnet anchor PREVIEW  (NO broadcast)"
echo "════════════════════════════════════════════════════════════════"

echo
echo "── [1/5] gen-anchor-source.sh — compose anchor-source.json ──"
bash scripts/gen-anchor-source.sh
echo "  ✓ anchor-source.json composed"

echo
echo "── [2/5] composed values (the value that will actually be inscribed) ──"
SCHEMA_VER="$(jq -r '.schema_version' "$SOURCE_PATH")"
CYC="$(jq -r '.observations_branch.cycle_number_observed' "$SOURCE_PATH")"
PREFIX="fya${SCHEMA_VER}c${CYC}"
jq -r --arg prefix "$PREFIX" '
  "  dag_root_computed (memo \($prefix):…):  \(.dag_root_computed)",
  "  cycle_number_observed:  \(.observations_branch.cycle_number_observed)"
' "$SOURCE_PATH"
echo "  ✓ cycle number (derived from $SOURCE_PATH) = $CYC  (schema major = $SCHEMA_VER, memo prefix = $PREFIX)"

echo
echo "── [3/5] sign-anchor-event --chain=mainnet-a --dry-run  (NO broadcast, no token) ──"
bash scripts/sign-anchor-event.sh --chain=mainnet-a --anchor-source="$SOURCE_PATH" --dry-run > "$DRYLOG"
echo "  ✓ dry-run-log written: $DRYLOG ($(wc -c < "$DRYLOG") bytes)"
echo "  ── EXACT memos to be inscribed (expect 4: ${PREFIX}-{id,ob,ar} + ${PREFIX}) ──"
jq -r '.. | objects | select(has("memo")) | "    memo=\(.memo)"' "$DRYLOG" 2>/dev/null || cat "$DRYLOG"
MEMOS=$(jq -r '.. | objects | select(has("memo")) | .memo' "$DRYLOG" 2>/dev/null | grep -c '^fya' || true)
echo "  memo count (expect 4): ${MEMOS:-?}"
echo "  ── recipients / auth (expect: metalfreedom@anchor → fyhistory, 0.0001 XPR ×4) ──"
jq -r '.. | objects | select(has("memo")) |
  "    \(.authorization[0].actor // "?")@\(.authorization[0].permission // "?") → \(.data.to // .to // "?")  \(.data.quantity // .quantity // "?")"' \
  "$DRYLOG" 2>/dev/null | sort -u || true

echo
echo "── [4/5] read-only gate pre-checks (safe-broadcast enforces these for real) ──"
G1=$(curl -s --max-time 15 "$TESTNET_HIST" -d "{\"id\":\"$TESTNET_TX_ID\"}" 2>/dev/null | jq -r '.block_num // "MISS"' 2>/dev/null || echo ERR)
echo "  gate1 testnet-tx ${TESTNET_TX_ID:0:8}…  block_num: $G1  $([ "$G1" != MISS ] && [ "$G1" != ERR ] && echo '✓' || echo '(verify)')"
if command -v proton >/dev/null 2>&1; then
  CID=$(proton chain:info 2>/dev/null | jq -r '.chain_id // empty' 2>/dev/null || true)
  echo "  gate3 proton chain_id:  ${CID:-?}  $([ "${CID:-}" = "$EXPECTED_CHAIN_ID" ] && echo '✓ mainnet 384da888…' || echo '(verify at broadcast)')"
else
  echo "  gate3 proton: not on PATH in this shell (safe-broadcast checks chain_id at broadcast time)"
fi

echo
echo "── [5/5] STAGE 2 — broadcast command (review + authorize FIRST; do NOT auto-run here) ──"
# R16 (bin/safe-broadcast gate-2/2b): the operator token must be CHAIN- and
# CONTENT-bound JSON, not a bare `touch` — an unbound/legacy token is REFUSED
# unconditionally for mainnet (fail-closed). Bind it to the EXACT tx already
# composed and displayed above ($DRYLOG's .tx), so authorization cannot drift
# to a different shape between review and broadcast.
#
# This command runs on the OPERATOR'S MAC, not here: sign-anchor-event.sh's
# real (non-dry-run) broadcast path enforces a signing-host assertion
# (exit 7 anywhere but the Mac) because the anchor key never leaves the Mac.
# Copy the dry-run-log content across (or re-derive it there — the anchor
# source must already be committed/pushed/deployed by
# scripts/operator-local/commit-anchor-source.sh first, see docs/CYCLE_GATE.md).
if command -v sha256sum >/dev/null 2>&1; then
  sha256_pipe() { sha256sum | awk '{print $1}'; }
else
  sha256_pipe() { shasum -a 256 | awk '{print $1}'; }
fi
TOKEN_TX_SHA256="$(jq -c .tx "$DRYLOG" | sha256_pipe)"
echo "  token tx_sha256 (binds to THIS exact tx): $TOKEN_TX_SHA256"
cat <<CMD
    printf '{"chain":"mainnet-a","tx_sha256":"%s"}' "$TOKEN_TX_SHA256" > /tmp/fyd-broadcast-token
                                             # gate-2/2b (R16), valid 5 min (300s TTL) from now.
                                             # chain+tx-bound; a bare touch is REFUSED for mainnet.
                                             # Run the block below on the operator's MAC:
    HOME=~/.metal-fy-proton proton key:unlock
    FY_CONFIG_DIR=\$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \\
      bash scripts/sign-anchor-event.sh \\
        --chain=mainnet-a \\
        --anchor-source=$SOURCE_PATH \\
        --testnet-tx-id=$TESTNET_TX_ID \\
        --dry-run-log=$DRYLOG
    # safe-broadcast will show the tx and require typing verbatim:  BROADCAST mainnet-a
CMD

echo
echo "════ STAGE 1 complete. NOTHING was broadcast. Paste this whole output back. ════"
