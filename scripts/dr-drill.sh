#!/usr/bin/env bash
# DR drill — end-to-end exercise of the disaster recovery path on the Mac:
#   1. Decrypt the encrypted staker key backup with the operator's passphrase
#   2. Verify SHA-256 of all three key files matches the recorded originals
#   3. Boot a local-network metalgo container with the restored keys
#   4. Confirm info.getNodeID returns the expected production NodeID
#   5. Clean up (stop container, remove temp files)
#
# CHAIN: none — no transaction is built or sent.
# NEVER connects to mainnet — every metalgo this script starts gets
# --network-id=local with empty bootstrap lists, and the script refuses to
# start a container whose args lack that flag (metalgo's own default is
# mainnet). Safe to run while the production validator is up; impossible to
# create a double-validator.
#
# Run quarterly as risk-theater prevention: untested backups are not backups.
#
# Usage:  bash scripts/dr-drill.sh              # full drill (asks the passphrase)
#         bash scripts/dr-drill.sh --dry-run    # readiness only: resolves the
#             backup file, checks docker + image, boots metalgo on the local
#             network with THROWAWAY ephemeral keys and checks info.getNodeID
#             answers. No passphrase, no decryption, no key material touched.
# Env:    ENCRYPTED_BACKUP  (default: newest ~/staker-backup-*.tar.gz.enc)
#         EXPECTED_NODEID   (default: NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v)
#         METALGO_IMAGE     (default: metalblockchain/metalgo:v1.13.5 — the
#                            production version; bump together with production)
#         EXPECTED_SHA_CRT / EXPECTED_SHA_KEY / EXPECTED_SHA_BLS
#                           (default: the recorded originals below)
#         DR_DRILL_BOOT_TIMEOUT  seconds to wait for the info API (default: 60)
set -euo pipefail

MODE="drill"
case "${1:-}" in
  "") ;;
  --dry-run) MODE="dry-run" ;;
  -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "ERROR: unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac

# newest_staker_backup — newest ~/staker-backup-*.tar.gz.enc by name (the
# names carry yyyymmdd, so lexical order is date order). Empty if none.
newest_staker_backup() {
  local f newest=""
  for f in "$HOME"/staker-backup-*.tar.gz.enc; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    if [ -z "$newest" ] || [[ "$f" > "$newest" ]]; then newest="$f"; fi
  done
  printf '%s' "$newest"
}

ENCRYPTED_BACKUP="${ENCRYPTED_BACKUP:-$(newest_staker_backup)}"
EXPECTED_NODEID="${EXPECTED_NODEID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
METALGO_IMAGE="${METALGO_IMAGE:-metalblockchain/metalgo:v1.13.5}"
BOOT_TIMEOUT="${DR_DRILL_BOOT_TIMEOUT:-60}"
CONTAINER_NAME="metal-dr-drill"
HTTP_PORT=19650
WORKDIR=$(mktemp -d)

# Expected SHA-256 of the original key files (recorded after deployment)
EXPECTED_SHA_CRT="${EXPECTED_SHA_CRT:-8e32e649f2e3dbc4bad590e746d644a5eb7f717c2dc9a21230461d5dfa9cb67b}"
EXPECTED_SHA_KEY="${EXPECTED_SHA_KEY:-97f608f1b19a4c21b262e51811e5b7be493e0ecaf9bc2a1c4d47bc56f22cad4f}"
EXPECTED_SHA_BLS="${EXPECTED_SHA_BLS:-73e93c0fbb9df720cd852acbfd37d980df63ab37977b7990deb76817e54a813f}"

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

LOCAL_NET_ARGS=(
  --network-id=local
  --http-host=0.0.0.0
  --http-port=9650
  --staking-port=9651
  --bootstrap-ips=
  --bootstrap-ids=
)

# start_local_metalgo <volume-dir or ""> <metalgo args...> — the only path
# that starts metalgo. Refuses unless the args pin the local network:
# metalgo defaults to mainnet.
start_local_metalgo() {
  local vol="$1" a has_local=0
  shift
  for a in "$@"; do
    case "$a" in
      --network-id=local) has_local=1 ;;
      --network-id=*) fail "refusing to start metalgo with $a (local only)" ;;
    esac
  done
  [ "$has_local" = 1 ] || fail "refusing to start metalgo without --network-id=local"
  local vol_args=()
  [ -z "$vol" ] || vol_args=(-v "$vol":/root/.metalgo/staking:ro)
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run --rm -d \
    --name "$CONTAINER_NAME" \
    ${vol_args[@]+"${vol_args[@]}"} \
    -p "127.0.0.1:${HTTP_PORT}:9650" \
    --entrypoint /metalgo/build/metalgo \
    "$METALGO_IMAGE" \
    "$@" \
    >/dev/null
}

# query_nodeid — polls info.getNodeID until it answers or BOOT_TIMEOUT passes;
# prints the last raw JSON response (empty on no answer).
query_nodeid() {
  local resp="" i=0
  while [ "$i" -lt "$BOOT_TIMEOUT" ]; do
    resp=$(curl -sS -m 3 -X POST -H 'content-type:application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
      "http://127.0.0.1:${HTTP_PORT}/ext/info" 2>/dev/null || true)
    if [ -n "$(echo "$resp" | jq -r '.result.nodeID // empty' 2>/dev/null)" ]; then
      printf '%s' "$resp"; return 0
    fi
    sleep 1; i=$((i + 1))
  done
  printf '%s' "$resp"
}

echo "=============================================="
echo " DR drill ($MODE) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="
echo

# ── Step 0: prerequisites ──────────────────────────────────────────────
echo "[0/5] Prerequisites"
for t in docker openssl tar shasum jq curl; do
  command -v "$t" >/dev/null 2>&1 || fail "$t not found"
done
[ -n "$ENCRYPTED_BACKUP" ] || fail "no ~/staker-backup-*.tar.gz.enc found (set ENCRYPTED_BACKUP)"
[ -f "$ENCRYPTED_BACKUP" ] || fail "encrypted backup not found at $ENCRYPTED_BACKUP"
echo "  backup: $ENCRYPTED_BACKUP ($(wc -c <"$ENCRYPTED_BACKUP" | tr -d ' ') bytes)"
echo "  image:  $METALGO_IMAGE"
docker info >/dev/null 2>&1 || fail "docker not running"
docker image inspect "$METALGO_IMAGE" >/dev/null 2>&1 \
  || { echo "  pulling $METALGO_IMAGE..."; docker pull "$METALGO_IMAGE"; }
pass "encrypted backup, docker, metalgo image all present"

if [ "$MODE" = "dry-run" ]; then
  echo
  echo "[dry-run] Boot metalgo on the local network with THROWAWAY ephemeral keys"
  start_local_metalgo "" "${LOCAL_NET_ARGS[@]}" \
    --staking-ephemeral-cert-enabled=true \
    --staking-ephemeral-signer-enabled=true
  RESP=$(query_nodeid)
  ACT_NODEID=$(echo "$RESP" | jq -r '.result.nodeID // empty' 2>/dev/null || true)
  [ -n "$ACT_NODEID" ] || { echo "  raw response: $RESP" >&2; fail "info.getNodeID did not answer within ${BOOT_TIMEOUT}s"; }
  pass "metalgo boots on the local network and answers info.getNodeID (throwaway ID, not compared)"
  echo
  echo "=============================================="
  echo " ✓ DR drill READY (dry-run). Nothing was decrypted."
  echo " Full drill: bash scripts/dr-drill.sh"
  echo "=============================================="
  exit 0
fi

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
# The tarball's top directory carries the backup date
# (staker-backup-<yyyymmdd>/staking), so locate the single staking/ dir.
STAKING=$(find "$WORKDIR" -mindepth 1 -maxdepth 2 -type d -name staking)
[ -n "$STAKING" ] && [ "$(grep -c . <<<"$STAKING")" = 1 ] \
  || fail "expected exactly one staking/ directory in the tarball, found: ${STAKING:-none}"

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
start_local_metalgo "$STAKING" "${LOCAL_NET_ARGS[@]}" \
  --staking-tls-cert-file=/root/.metalgo/staking/staker.crt \
  --staking-tls-key-file=/root/.metalgo/staking/staker.key \
  --staking-signer-key-file=/root/.metalgo/staking/signer.key
docker ps --filter "name=$CONTAINER_NAME" --format '  {{.Names}}  {{.Status}}'
pass "metalgo container running on local network"

# ── Step 4: NodeID verification ────────────────────────────────────────
echo
echo "[4/5] Query NodeID via info.getNodeID"
RESP=$(query_nodeid)
ACT_NODEID=$(echo "$RESP" | jq -r '.result.nodeID // empty' 2>/dev/null || true)

if [ -z "$ACT_NODEID" ]; then
  echo "  raw response: $RESP" >&2
  fail "no nodeID in response within ${BOOT_TIMEOUT}s"
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
