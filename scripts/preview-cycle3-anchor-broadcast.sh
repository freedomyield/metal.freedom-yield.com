#!/usr/bin/env bash
# preview-cycle3-anchor-broadcast.sh — STAGE 1 of the cycle-3 mainnet A-chain anchor.
#
# One-shot operator preview (no automated test by design — it broadcasts
# nothing and only displays the composed transaction shape for review).
#
# Refreshes anchor-source.json (v2 3-branch composition), generates the mainnet
# --dry-run-log (safe-broadcast gate-4 material), and DISPLAYS the exact
# transaction shape a subsequent run-anchor-pipeline.sh broadcast would inscribe.
#
# BROADCASTS NOTHING. Invokes no `proton transaction`/`safe-broadcast`. Touches no
# operator token. Only (re)writes the regenerable anchor-source.json + a temp
# dry-run-log — both idempotent. Run as the deploy user on the validator host.
#
# STAGE 2 (the actual broadcast) is a SEPARATE, operator-authorized step printed
# at the end of this script's output.
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

REPO="${REPO:-/home/deploy/metal.freedom-yield.com}"
DRYLOG="${DRYLOG:-/home/deploy/.fya-mainnet-dryrun-cycle3.json}"
TESTNET_TX_ID="070a845f81a5a8aed017aaf9233ebf8a9ebe9830460ea0ef42f0d6bfc5be1f43"
EXPECTED_CHAIN_ID="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
TESTNET_HIST="https://test.proton.eosusa.io/v1/history/get_transaction"

cd "$REPO"

echo "════════════════════════════════════════════════════════════════"
echo "  STAGE 1 — cycle-3 mainnet anchor PREVIEW  (NO broadcast)"
echo "════════════════════════════════════════════════════════════════"

echo
echo "── [1/5] gen-anchor-source.sh — compose anchor-source.json ──"
bash scripts/gen-anchor-source.sh
echo "  ✓ anchor-source.json composed"

echo
echo "── [2/5] composed values (the value that will actually be inscribed) ──"
jq -r '
  "  dag_root_computed (memo fya1c3:…):  \(.dag_root_computed)",
  "  cycle_number_observed (must be 3):  \(.observations_branch.cycle_number_observed)"
' public/api/anchor-source.json
CYC=$(jq -r '.observations_branch.cycle_number_observed' public/api/anchor-source.json)
if [ "$CYC" != "3" ]; then
  echo "  ✗ ABORT: cycle_number_observed=$CYC (expected 3). Do NOT broadcast." >&2
  exit 1
fi
echo "  ✓ cycle number = 3"

echo
echo "── [3/5] sign-anchor-event --chain=mainnet-a --dry-run  (NO broadcast, no token) ──"
bash scripts/sign-anchor-event.sh --chain=mainnet-a --dry-run > "$DRYLOG"
echo "  ✓ dry-run-log written: $DRYLOG ($(wc -c < "$DRYLOG") bytes)"
echo "  ── EXACT memos to be inscribed (expect 4: fya1c3-{id,ob,ar} + fya1c3) ──"
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
echo "  gate1 testnet-tx 070a845f…  block_num: $G1  $([ "$G1" != MISS ] && [ "$G1" != ERR ] && echo '✓' || echo '(verify)')"
if command -v proton >/dev/null 2>&1; then
  CID=$(proton chain:info 2>/dev/null | jq -r '.chain_id // empty' 2>/dev/null || true)
  echo "  gate3 proton chain_id:  ${CID:-?}  $([ "${CID:-}" = "$EXPECTED_CHAIN_ID" ] && echo '✓ mainnet 384da888…' || echo '(verify at broadcast)')"
else
  echo "  gate3 proton: not on PATH in this shell (safe-broadcast checks chain_id at broadcast time)"
fi

echo
echo "── [5/5] STAGE 2 — broadcast command (review + authorize FIRST; do NOT auto-run) ──"
# R16 (bin/safe-broadcast gate-2/2b): the operator token must be CHAIN- and
# CONTENT-bound JSON, not a bare `touch` — an unbound/legacy token is REFUSED
# unconditionally for mainnet (fail-closed). Bind it to the EXACT tx already
# composed and displayed above ($DRYLOG's .tx), so authorization cannot drift
# to a different shape between review and broadcast.
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
    cd $REPO
    bash scripts/run-anchor-pipeline.sh \\
      --chain=mainnet-a \\
      --trigger=cyclestart --event-type=cyclestart \\
      --testnet-tx-id=$TESTNET_TX_ID \\
      --dry-run-log=$DRYLOG \\
      --prev-anchor-tx-id=null \\
      --key-seq=1
    # safe-broadcast will show the tx and require typing verbatim:  BROADCAST mainnet-a
CMD

echo
echo "════ STAGE 1 complete. NOTHING was broadcast. Paste this whole output back. ════"
