#!/usr/bin/env bash
# DR drill — end-to-end exercise of the disaster recovery path on the Mac:
#   1. Decrypt the encrypted staker key backup with the operator's passphrase
#   2. Verify SHA-256 of all three key files matches the recorded originals
#   3. Boot a local-network metalgo container with the restored keys
#   4. Confirm info.getNodeID returns the expected production NodeID
#   5. Clean up (stop container, remove temp files)
#
# NEVER connects to mainnet — uses --network-id=local. Safe to run while
# the production validator is up; impossible to create a double-validator.
#
# Run quarterly as risk-theater prevention: untested backups are not backups.
#
# Usage:  bash scripts/dr-drill.sh
# Env:    ENCRYPTED_BACKUP  (default: ~/staker-backup.tar.gz.enc)
#         EXPECTED_NODEID    (default: NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v)
#         METALGO_IMAGE      (default: metalblockchain/metalgo:latest)
set -euo pipefail

ENCRYPTED_BACKUP="${ENCRYPTED_BACKUP:-$HOME/staker-backup.tar.gz.enc}"
EXPECTED_NODEID="${EXPECTED_NODEID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
METALGO_IMAGE="${METALGO_IMAGE:-metalblockchain/metalgo:latest}"
CONTAINER_NAME="metal-dr-drill"
HTTP_PORT=19650
WORKDIR=$(mktemp -d)

# Expected SHA-256 of the original key files (recorded after deployment)
EXPECTED_SHA_CRT="8e32e649f2e3dbc4bad590e746d644a5eb7f717c2dc9a21230461d5dfa9cb67b"
EXPECTED_SHA_KEY="97f608f1b19a4c21b262e51811e5b7be493e0ecaf9bc2a1c4d47bc56f22cad4f"
EXPECTED_SHA_BLS="73e93c0fbb9df720cd852acbfd37d980df63ab37977b7990deb76817e54a813f"

cleanup() {
  echo
  echo "=== Cleanup ==="
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
  echo "  removed: $CONTAINER_NAME container"
  echo "  removed: $WORKDIR"
}
trap cleanup EXIT

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ PASS: $*"; }

echo "=============================================="
echo " DR drill — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="
echo

# ── Step 0: prerequisites ──────────────────────────────────────────────
echo "[0/5] Prerequisites"
[ -f "$ENCRYPTED_BACKUP" ] || fail "encrypted backup not found at $ENCRYPTED_BACKUP"
docker info >/dev/null 2>&1 || fail "docker not running"
docker image inspect "$METALGO_IMAGE" >/dev/null 2>&1 \
  || { echo "  pulling $METALGO_IMAGE..."; docker pull "$METALGO_IMAGE"; }
pass "encrypted backup, docker, metalgo image all present"

# ── Step 1: decrypt ────────────────────────────────────────────────────
echo
echo "[1/5] Decrypt encrypted backup"
read -rs -p "  Enter passphrase: " PP
echo
export PP_FOR_OPENSSL="$PP"
unset PP

if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
       -in "$ENCRYPTED_BACKUP" \
       -out "$WORKDIR/restored.tar.gz" \
       -pass env:PP_FOR_OPENSSL 2>/dev/null; then
  unset PP_FOR_OPENSSL
  fail "decryption failed (wrong passphrase or corrupt file)"
fi
unset PP_FOR_OPENSSL
pass "decryption succeeded"

# ── Step 2: extract + hash check ───────────────────────────────────────
echo
echo "[2/5] Verify SHA-256 of restored key files"
tar xzf "$WORKDIR/restored.tar.gz" -C "$WORKDIR"
STAKING="$WORKDIR/staker-backup/staking"
[ -d "$STAKING" ] || fail "expected directory $STAKING not in tarball"

ACT_CRT=$(shasum -a 256 "$STAKING/staker.crt" | awk '{print $1}')
ACT_KEY=$(shasum -a 256 "$STAKING/staker.key" | awk '{print $1}')
ACT_BLS=$(shasum -a 256 "$STAKING/signer.key" | awk '{print $1}')

[ "$ACT_CRT" = "$EXPECTED_SHA_CRT" ] || fail "staker.crt hash mismatch (got $ACT_CRT)"
[ "$ACT_KEY" = "$EXPECTED_SHA_KEY" ] || fail "staker.key hash mismatch (got $ACT_KEY)"
[ "$ACT_BLS" = "$EXPECTED_SHA_BLS" ] || fail "signer.key hash mismatch (got $ACT_BLS)"
pass "all 3 file hashes match recorded originals"

# ── Step 3: boot metalgo on local network ──────────────────────────────
echo
echo "[3/5] Boot metalgo on local network with restored keys"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run --rm -d \
  --name "$CONTAINER_NAME" \
  -v "$STAKING":/root/.metalgo/staking:ro \
  -p "127.0.0.1:${HTTP_PORT}:9650" \
  --entrypoint /metalgo/build/metalgo \
  "$METALGO_IMAGE" \
  --network-id=local \
  --http-host=0.0.0.0 \
  --http-port=9650 \
  --staking-port=9651 \
  --staking-tls-cert-file=/root/.metalgo/staking/staker.crt \
  --staking-tls-key-file=/root/.metalgo/staking/staker.key \
  --staking-signer-key-file=/root/.metalgo/staking/signer.key \
  --bootstrap-ips= \
  --bootstrap-ids= \
  >/dev/null
sleep 5
docker ps --filter "name=$CONTAINER_NAME" --format '  {{.Names}}  {{.Status}}'
pass "metalgo container running on local network"

# ── Step 4: NodeID verification ────────────────────────────────────────
echo
echo "[4/5] Query NodeID via info.getNodeID"
RESP=$(curl -sS -X POST -H 'content-type:application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
  "http://127.0.0.1:${HTTP_PORT}/ext/info")
ACT_NODEID=$(echo "$RESP" | jq -r '.result.nodeID // empty')

if [ -z "$ACT_NODEID" ]; then
  echo "  raw response: $RESP" >&2
  fail "no nodeID in response"
fi

echo "  expected: $EXPECTED_NODEID"
echo "  actual:   $ACT_NODEID"
[ "$ACT_NODEID" = "$EXPECTED_NODEID" ] || fail "NodeID mismatch — backup does not reproduce production identity"
pass "NodeID reproduced from backup"

# Also verify BLS PoP recovered correctly
ACT_BLS_PUB=$(echo "$RESP" | jq -r '.result.nodePOP.publicKey // empty')
echo "  BLS publicKey: ${ACT_BLS_PUB:0:24}...${ACT_BLS_PUB: -10}"
[ -n "$ACT_BLS_PUB" ] || fail "BLS publicKey not present in nodePOP"

echo
echo "[5/5] Drill complete"
echo "=============================================="
echo " ✓ DR drill PASSED"
echo " Encrypted backup at $ENCRYPTED_BACKUP"
echo " correctly reproduces $EXPECTED_NODEID."
echo " Schedule next drill ~3 months from now."
echo "=============================================="
