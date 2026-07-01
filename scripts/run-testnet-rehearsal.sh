#!/usr/bin/env bash
# run-testnet-rehearsal.sh — T-I-20260701 operator installer.
#
# CHAIN: testnet-a (proton-test). This script DOES broadcast a
#        4-action pack to XPR testnet after all pre-checks pass.
# PRIME_DIRECTIVE: TESTNET-FIRST — this script is the mandatory
#                  testnet-first execution per Constitution §3.4
#                  BEFORE any mainnet anchor broadcast. Its
#                  successful tx_id becomes the --testnet-tx-id
#                  input for the mainnet gate 1.
#
# Runs the full anchor pipeline against XPR testnet, using the
# operator-local rehearsal config (~/freedom-yield-rehearsal-config)
# with actor=frdomyieltst, sink=fyhistorytst, chain=proton-test.
#
# Prerequisites (checked by this script; failed check → exit >0):
#   - proton-cli installed on this host (Mac local, not Hetzner)
#   - Testnet keys present in proton keystore
#     (PUB_K1_8fLkde... / PUB_K1_6crXf5... / PUB_K1_6pYLPz...)
#   - Rehearsal config dir at ~/freedom-yield-rehearsal-config
#   - jq + curl + sha256sum/shasum in PATH
#
# Prerequisites the OPERATOR provides interactively:
#   - `proton key:unlock` — proton-cli keystore must be unlocked
#     BEFORE running this script. Non-interactive shells (this
#     script) cannot unlock; a locked keystore causes proton to
#     hang indefinitely (see reference_proton_cli_keystore_lock_quirk).
#   - Broadcast authorization: this script auto-creates the
#     /tmp/fyd-broadcast-token file (5-minute TTL) so bin/safe-broadcast
#     admits the invocation. Operator invokes the script → operator
#     token = correct authorization pathway.
#
# Usage:
#   bash scripts/run-testnet-rehearsal.sh
#
# What it does:
#   1. Verify testnet keys present in keystore
#   2. Verify unlock state (proton-cli account read must succeed
#      without hang; timeout applied)
#   3. Verify proton chain:set proton-test + chain:info respond
#   4. Compose 4-action tx JSON via sign-anchor-event.sh --dry-run,
#      save to a tmpfile
#   5. Save dry-run log for future mainnet gate 4 material
#   6. Create broadcast token (/tmp/fyd-broadcast-token, TTL 5 min)
#   7. Invoke bin/safe-broadcast --chain=testnet-a with the composed tx
#   8. Extract tx_id, fetch tx from testnet Hyperion, run the
#      gen-anchor-receipt 7-gate verify chain
#   9. Emit a "TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>" line
#      that operator copy-pastes back to the AI session

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REHEARSAL_CFG="${HOME}/freedom-yield-rehearsal-config"

# Source pick order (highest to lowest):
#   1. --source=<path> arg
#   2. ANCHOR_SOURCE_OVERRIDE env
#   3. public/api/anchor-source.substantive.json  ← real hashes (default)
#   4. public/api/anchor-source.example.json      ← placeholder fallback
# The substantive file exists once gen-anchor-source.sh has run (on Hetzner)
# or when it's been composed manually with real identity + artifact hashes.
# Rehearsing with the example file inscribes 0000... placeholders on-chain,
# which is what happened in the 2026-07-01 pre-substantive rehearsal.
ANCHOR_SOURCE_ARG=""
for arg in "$@"; do
	case "$arg" in
		--source=*) ANCHOR_SOURCE_ARG="${arg#--source=}" ;;
	esac
done
if [ -n "$ANCHOR_SOURCE_ARG" ]; then
	ANCHOR_SOURCE="$ANCHOR_SOURCE_ARG"
elif [ -n "${ANCHOR_SOURCE_OVERRIDE:-}" ]; then
	ANCHOR_SOURCE="$ANCHOR_SOURCE_OVERRIDE"
elif [ -r "${REPO_ROOT}/public/api/anchor-source.substantive.json" ]; then
	ANCHOR_SOURCE="${REPO_ROOT}/public/api/anchor-source.substantive.json"
else
	ANCHOR_SOURCE="${REPO_ROOT}/public/api/anchor-source.example.json"
fi

TESTNET_RPC="${XPR_TESTNET_RPC:-https://test.proton.eosusa.io}"
DRY_RUN_LOG="${HOME}/.fya-testnet-dryrun-log.json"
TOKEN_FILE="/tmp/fyd-broadcast-token"

step() { printf '\n=== step %s ===\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

# ---- step 1: verify testnet keys ----
step "1/9 verify testnet keys in proton keystore"
KEYS_JSON="$(proton key:list 2>/dev/null || echo '[]')"
for k in PUB_K1_8fLkdepi3VFcak1d1pdMfW6GPEy47SuM95KzJriw7ptYSauxHF \
          PUB_K1_6crXf5FfzwJRbHtX8MtP72Ye8HP6C9Ny7ef7YGNfFGzE7ahQGq \
          PUB_K1_6pYLPztQ6vKnivihTzDZ6PKE1TDKyAP42PmnDdLW1MVQbJW6qX; do
	if echo "$KEYS_JSON" | grep -q "$k"; then
		echo "  present: ${k:0:24}..."
	else
		fail "testnet public key missing from proton keystore: ${k:0:24}...  (regenerate + fund per docs/PHASE_ALPHA_TESTNET_DRY_RUN.md)"
	fi
done

# ---- step 2: verify rehearsal config ----
step "2/9 verify rehearsal config dir ${REHEARSAL_CFG}"
for f in xpr-account anchor-sink xpr-chain; do
	[ -r "${REHEARSAL_CFG}/${f}" ] || fail "config file missing: ${REHEARSAL_CFG}/${f}"
	echo "  ${f}: $(cat "${REHEARSAL_CFG}/${f}")"
done

# ---- step 3: keystore unlock check + chain preflight ----
step "3/9 keystore unlock + proton chain preflight"
proton chain:set proton-test >/dev/null 2>&1 || fail "proton chain:set proton-test failed"
# proton chain:info returns a pretty-printed JSON object (~22 lines).
# The prior `head -20` truncated the trailing `}` and produced a "Unfinished
# JSON term at EOF" parse error at step 3 during S9/S11 rehearsals. Capture
# the full output, chain_id-check via grep (cheap presence test) and pull
# head_block_num via jq on the full JSON.
CHAIN_INFO="$(proton chain:info 2>&1)"
if ! printf '%s' "$CHAIN_INFO" | grep -q chain_id; then
	fail "proton chain:info testnet returned unexpected output; check RPC connectivity"
fi
HEAD_BLOCK_NUM="$(printf '%s' "$CHAIN_INFO" | jq -r '.head_block_num // "unparsed"' 2>/dev/null || echo unparsed)"
echo "  chain:info OK — head_block_num=$HEAD_BLOCK_NUM"

# Unlock probe: try to read the same account we'll sign with.
# Fast timeout because a locked keystore hangs on any signing-adjacent op.
if ! timeout 5 proton account frdomyieltst >/dev/null 2>&1; then
	printf '  WARN: proton account frdomyieltst timed out; keystore may be locked.\n'
	printf '        Run in a separate terminal:  proton key:unlock\n'
	printf '        then re-run this script.\n' >&2
	exit 2
fi
echo "  keystore appears unlocked (frdomyieltst account read succeeded)"

# ---- source visibility (audit trail: which file's hashes go on-chain) ----
step "3.5/9 anchor-source file audit"
echo "  path:              $ANCHOR_SOURCE"
if [ ! -r "$ANCHOR_SOURCE" ]; then
	fail "anchor-source file not readable: $ANCHOR_SOURCE"
fi
SRC_BASENAME="$(basename "$ANCHOR_SOURCE")"
echo "  basename:          $SRC_BASENAME"
SRC_ID_HEX="$(jq -r '.identity_branch.operator_ed25519_pubkey_sha256_hex' "$ANCHOR_SOURCE")"
SRC_MFST="$(jq -r '.artifacts_branch.public_api_manifest_root' "$ANCHOR_SOURCE")"
SRC_DAG="$(jq -r '.dag_root_computed' "$ANCHOR_SOURCE")"
echo "  identity pubkey:   $SRC_ID_HEX"
echo "  manifest root:     $SRC_MFST"
echo "  dag_root_computed: $SRC_DAG"
if [ "$SRC_ID_HEX" = "0000000000000000000000000000000000000000000000000000000000000000" ] \
   || [ "$SRC_MFST" = "0000000000000000000000000000000000000000000000000000000000000000" ]; then
	printf '\n  WARNING: anchor-source has placeholder hashes (0000...).\n'
	printf '           This will inscribe placeholders on-chain.\n'
	printf '           If this is not intentional, re-run with --source=<real-source.json>.\n\n'
fi

# ---- step 4: compose 4-action tx via sign-anchor-event.sh --dry-run ----
step "4/9 compose 4-action testnet tx"
TX_FILE="$(mktemp -t fya-testnet-tx.XXXXXX)"
trap 'rm -f "$TX_FILE"' EXIT
FY_CONFIG_DIR="${REHEARSAL_CFG}" bash "${REPO_ROOT}/scripts/sign-anchor-event.sh" \
	--chain=testnet-a \
	--anchor-source="${ANCHOR_SOURCE}" \
	--dry-run > "$DRY_RUN_LOG" 2>&1 || fail "sign-anchor-event.sh --dry-run failed"
jq '.tx' "$DRY_RUN_LOG" > "$TX_FILE" || fail "failed to extract .tx from dry-run log"
echo "  composed 4-action tx to $TX_FILE"
echo "  memo_prefix: $(jq -r .memo_prefix "$DRY_RUN_LOG")"
echo "  actor@perm:  $(jq -r '"\(.authorization.actor)@\(.authorization.permission)"' "$DRY_RUN_LOG")"
echo "  sink:        $(jq -r .sink "$DRY_RUN_LOG")"
echo "  dry-run log saved: $DRY_RUN_LOG  (= future mainnet gate-4 material)"

# ---- step 5: create broadcast token ----
step "5/9 create broadcast token (5-min TTL)"
touch "$TOKEN_FILE" || fail "cannot create $TOKEN_FILE"
echo "  token created at $TOKEN_FILE"

# ---- step 6: invoke bin/safe-broadcast ----
step "6/9 invoke bin/safe-broadcast --chain=testnet-a --non-interactive"
# non-interactive tightens TTL to 60s but we just touched; safe.
BROADCAST_OUT="$(mktemp -t fya-testnet-bcast.XXXXXX)"
BROADCAST_ERR="$(mktemp -t fya-testnet-bcast-err.XXXXXX)"
trap 'rm -f "$TX_FILE" "$BROADCAST_OUT" "$BROADCAST_ERR"' EXIT

BROADCAST_RC=0
FY_CONFIG_DIR="${REHEARSAL_CFG}" bash "${REPO_ROOT}/bin/safe-broadcast" \
	--tx="$TX_FILE" \
	--chain=testnet-a \
	--non-interactive \
	> "$BROADCAST_OUT" 2> "$BROADCAST_ERR" || BROADCAST_RC=$?

if [ "$BROADCAST_RC" -ne 0 ]; then
	echo "safe-broadcast exit rc=$BROADCAST_RC" >&2
	echo "--- stderr (last 30 lines) ---" >&2
	tail -30 "$BROADCAST_ERR" >&2
	echo "--- stdout (last 10 lines) ---" >&2
	tail -10 "$BROADCAST_OUT" >&2
	fail "safe-broadcast failed"
fi

TX_ID="$(cat "$BROADCAST_OUT" | tr -d '[:space:]')"
if ! echo "$TX_ID" | grep -qE '^[a-f0-9]{64}$'; then
	fail "extracted tx_id malformed: '$TX_ID'"
fi
echo "  BROADCAST OK  tx_id=$TX_ID"

# ---- step 7: reconstruct sign-anchor-event JSON for gen-anchor-receipt input ----
step "7/9 assemble sign-anchor-event output shape for receipt input"
SIGN_JSON="$(mktemp -t fya-testnet-sign.XXXXXX)"
trap 'rm -f "$TX_FILE" "$BROADCAST_OUT" "$BROADCAST_ERR" "$SIGN_JSON"' EXIT
jq --arg tx_id "$TX_ID" '
	{
		tx_id: $tx_id,
		chain: "metal-a-chain",
		network: "testnet-a",
		method: "hc_single_4_action_pack",
		schema_version: .schema_version,
		cycle_number: .cycle_number,
		memo_prefix: .memo_prefix,
		actions: [
			{branch: "identity",         memo: .composed_memos.identity,         root_hex: (.composed_memos.identity | sub("^[^:]+:"; ""))},
			{branch: "observations",     memo: .composed_memos.observations,     root_hex: (.composed_memos.observations | sub("^[^:]+:"; ""))},
			{branch: "artifacts",        memo: .composed_memos.artifacts,        root_hex: (.composed_memos.artifacts | sub("^[^:]+:"; ""))},
			{branch: "dag_root_summary", memo: .composed_memos.dag_root_summary, root_hex: (.composed_memos.dag_root_summary | sub("^[^:]+:"; ""))}
		],
		authorization: .authorization,
		sink: .sink,
		quantity: .quantity
	}
' "$DRY_RUN_LOG" > "$SIGN_JSON"

# ---- step 8: gen-anchor-receipt 7-gate verify chain ----
step "8/9 gen-anchor-receipt 7-gate verify against $TESTNET_RPC"
RECEIPT_OUT="${HOME}/.fya-testnet-receipt.json"
bash "${REPO_ROOT}/scripts/gen-anchor-receipt.sh" \
	--input="$SIGN_JSON" \
	--anchor-source="$ANCHOR_SOURCE" \
	--out="$RECEIPT_OUT" \
	--rpc="$TESTNET_RPC" \
	--trigger=manual \
	--prev-anchor-tx-id=null \
	|| fail "gen-anchor-receipt.sh failed"
echo "  7-gate PASS, receipt saved: $RECEIPT_OUT"

# ---- step 9: emit sentinel line for AI copy-paste ----
step "9/9 rehearsal complete"
cat <<EOF

=========================================================
TESTNET REHEARSAL COMPLETE — copy the line below back to the AI session:

    TESTNET REHEARSAL COMPLETE testnet_tx_id=${TX_ID}

Details for the record:
  chain:               testnet-a (proton-test)
  actor:               $(jq -r .authorization.actor "$DRY_RUN_LOG")
  sink:                $(jq -r .sink "$DRY_RUN_LOG")
  memo prefix:         $(jq -r .memo_prefix "$DRY_RUN_LOG")
  anchor-source:       $ANCHOR_SOURCE
  4 memos inscribed:
    [1/id]  $(jq -r .composed_memos.identity        "$DRY_RUN_LOG")
    [2/ob]  $(jq -r .composed_memos.observations    "$DRY_RUN_LOG")
    [3/ar]  $(jq -r .composed_memos.artifacts       "$DRY_RUN_LOG")
    [4/dag] $(jq -r .composed_memos.dag_root_summary "$DRY_RUN_LOG")
  dry-run log:         $DRY_RUN_LOG
  receipt:             $RECEIPT_OUT
  explorer URL:        https://testnet.protonscan.io/transaction/${TX_ID}

Next: paste the sentinel line to the AI session. AI will use it as the
--testnet-tx-id argument for the 2026-07-04 mainnet gate 1 in
bin/safe-broadcast (and record it in memory as T-I evidence).
=========================================================
EOF
exit 0
