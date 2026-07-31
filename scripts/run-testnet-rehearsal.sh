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
# with actor read from that config's xpr-account file (rehearsal
# convention: frdomyieltst), sink=fyhistorytst, chain=proton-test.
#
# Prerequisites (checked by this script; failed check → exit >0):
#   - proton-cli installed on this host (Mac local, not the validator host)
#   - node (Node.js) on PATH — used for public-key format verification
#     (scripts/lib/eosio-pubkey-raw-hex.js). Already a transitive
#     prerequisite of proton-cli itself (an npm package), so this adds no
#     new install step in practice.
#   - The CURRENT on-chain <account>@anchor public key present in the
#     proton keystore. This is verified dynamically against the live
#     testnet chain (step 3 below) — NOT against a hardcoded pin, so it
#     stays correct across future key rotations without a script edit.
#   - Rehearsal config dir at ~/freedom-yield-rehearsal-config
#   - jq + curl + sha256sum/shasum in PATH
#
# Prerequisites the OPERATOR provides interactively:
#   - `HOME=~/.metal-fy-proton-test proton key:unlock` — proton-cli keystore
#     must be unlocked BEFORE running this script (and this script itself
#     must be invoked with the same HOME=~/.metal-fy-proton-test prefix, per
#     Constitution §3.5). Non-interactive shells (this script) cannot
#     unlock; a locked keystore causes proton to hang indefinitely (see
#     reference_proton_cli_keystore_lock_quirk).
#   - Broadcast authorization: this script auto-creates the
#     /tmp/fyd-broadcast-token file (5-minute TTL), bound to chain=testnet-a
#     and the exact composed tx (tx_sha256) per R16, so bin/safe-broadcast
#     admits the invocation. Operator invokes the script → operator
#     token = correct authorization pathway.
#
# Usage:
#   HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh \
#       [--source=<path>] [--allow-fixture] [--expect-cycle=<N>]
#
# Options:
#   --source=<path>     Anchor-source JSON to inscribe. Default: the
#                       canonical public/api/anchor-source.json (current
#                       cycle's real hashes). Also settable via the
#                       ANCHOR_SOURCE_OVERRIDE env var (same precedence,
#                       --source= wins if both given).
#   --allow-fixture     Required, IN ADDITION to a --source=/
#                       ANCHOR_SOURCE_OVERRIDE pointing at
#                       anchor-source.substantive.json or
#                       anchor-source.example.json. These fixtures hold
#                       stale/placeholder data (never updated after their
#                       original cycle) and are refused otherwise — see
#                       step 1/10 below. Schema-shape testing ONLY; never
#                       valid PRIME DIRECTIVE gate-1 evidence. A warning
#                       (not fatal) is printed if this flag is given but
#                       the selected source is not actually a fixture.
#   --expect-cycle=<N>  MANDATORY for a real (day-of) rehearsal per
#                       docs/PHASE_ALPHA_TESTNET_DRY_RUN.md: fails closed
#                       (step 1/10) if the selected anchor-source's
#                       cycle_number_observed != N. A testnet rehearsal is
#                       only valid gate-1 evidence for a mainnet broadcast
#                       targeting the SAME cycle — the hardened mainnet
#                       gate 1 refuses cross-cycle evidence (e.g. a
#                       fya1c3 rehearsal cannot authorize a fya1c4
#                       broadcast). Omitting this flag does not block the
#                       run (useful for exploratory/schema-shape runs) but
#                       prints a non-fatal reminder, since an unverified
#                       cycle number is not real gate-1 evidence either.
#
# What it does:
#   1.  Resolve + print the anchor-source file that will be inscribed
#       (path, cycle_number_observed, computed_at, derived memo prefix);
#       refuse a fixture file unless --allow-fixture was given; refuse
#       (fail-closed) if --expect-cycle=<N> was given and does not match.
#   2.  Verify rehearsal config dir + read the actor account name.
#   3.  Fetch the CURRENT on-chain <account>@anchor public key via
#       read-only testnet RPC get_account, and verify it is present in
#       the local proton keystore (format-normalized comparison — see
#       scripts/lib/eosio-pubkey-raw-hex.js). Fail-closed if the RPC is
#       unreachable or the response is malformed.
#   4.  Verify unlock state (proton-cli account read must succeed
#       without hang; timeout applied) + proton chain:set proton-test
#       + chain:info respond.
#   5.  Compose 4-action tx JSON via sign-anchor-event.sh --dry-run,
#       save to a tmpfile.
#   6.  Create broadcast token (/tmp/fyd-broadcast-token, TTL 5 min,
#       chain+tx-bound per R16).
#   7.  Invoke bin/safe-broadcast --chain=testnet-a with the composed tx.
#   8.  Reassemble the sign-anchor-event JSON shape for receipt input.
#   9.  Extract tx_id, fetch tx from testnet Hyperion, run the
#       gen-anchor-receipt 7-gate verify chain.
#   10. Emit a "TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>" line
#       that operator copy-pastes back to the AI session.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/require-keystore-home.sh
. "${REPO_ROOT}/scripts/lib/require-keystore-home.sh"

# §3.5 follow-up (Task D): this script's rehearsal config dir, dry-run log,
# and receipt file are operator-local paths that have nothing to do with
# the proton-cli keystore. They must keep resolving under the login home
# even when this script is (correctly, per §3.5) invoked with
# HOME=~/.metal-fy-proton-test — otherwise they'd silently relocate into
# the keystore dir and break (e.g. step 2's config-file check). Resolve
# them from LOGIN_HOME (via the shared fyd_login_home helper), not $HOME.
LOGIN_HOME="$(fyd_login_home)"
# Defensive fallback only: per fyd_login_home()'s header comment
# (scripts/lib/require-keystore-home.sh), a failed `id -un` resolves to
# bash's own tilde-expansion of the current $HOME rather than an empty
# string, so this line is not reachable in practice. Kept in case that
# resolution behavior ever changes.
[ -n "$LOGIN_HOME" ] || LOGIN_HOME="$HOME"
REHEARSAL_CFG="${LOGIN_HOME}/freedom-yield-rehearsal-config"

# ---- anchor-source selection (arg parse only here; validated + printed in
# step 1/10 below, which is where the fixture gate lives) ----
# Pick order (highest to lowest):
#   1. --source=<path> arg
#   2. ANCHOR_SOURCE_OVERRIDE env
#   3. public/api/anchor-source.json  ← canonical, default (current cycle)
# anchor-source.substantive.json and anchor-source.example.json are NEVER
# auto-selected (they were, until 2026-07-31 — the substantive file is a
# cycle-2 fixture frozen since 2026-07-01 and was silently inscribing stale
# data whenever the canonical file happened to be absent). Either fixture
# may still be chosen explicitly via --source=/ANCHOR_SOURCE_OVERRIDE, but
# ONLY together with --allow-fixture (step 1/10 refuses otherwise).
ANCHOR_SOURCE_ARG=""
ALLOW_FIXTURE=0
EXPECT_CYCLE=""
for arg in "$@"; do
	case "$arg" in
		--source=*)         ANCHOR_SOURCE_ARG="${arg#--source=}" ;;
		--allow-fixture)    ALLOW_FIXTURE=1 ;;
		--expect-cycle=*)   EXPECT_CYCLE="${arg#--expect-cycle=}" ;;
		-h|--help)          sed -n '2,99p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)                  echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done
if [ -n "$EXPECT_CYCLE" ] && ! printf '%s' "$EXPECT_CYCLE" | grep -qE '^[0-9]+$'; then
	echo "ERROR: --expect-cycle must be a non-negative integer, got: $EXPECT_CYCLE" >&2
	exit 1
fi
if [ -n "$ANCHOR_SOURCE_ARG" ]; then
	ANCHOR_SOURCE="$ANCHOR_SOURCE_ARG"
	ANCHOR_SOURCE_ORIGIN="--source="
elif [ -n "${ANCHOR_SOURCE_OVERRIDE:-}" ]; then
	ANCHOR_SOURCE="$ANCHOR_SOURCE_OVERRIDE"
	ANCHOR_SOURCE_ORIGIN="ANCHOR_SOURCE_OVERRIDE env"
else
	ANCHOR_SOURCE="${REPO_ROOT}/public/api/anchor-source.json"
	ANCHOR_SOURCE_ORIGIN="default (canonical)"
fi

# get_account (chain API — permission/key lookup). Distinct provider/base
# from TESTNET_RPC below (Hyperion/history API) — see
# docs/ANCHOR_ACCOUNT_KEY_ROTATION.md, which already established this
# endpoint for the same get_account use case during the 2026-07-10 key
# rotation.
TESTNET_CHAIN_RPC="${XPR_TESTNET_CHAIN_RPC:-https://rpc.api.testnet.metalx.com}"
TESTNET_RPC="${XPR_TESTNET_RPC:-https://test.proton.eosusa.io}"
DRY_RUN_LOG="${LOGIN_HOME}/.fya-testnet-dryrun-log.json"
TOKEN_FILE="/tmp/fyd-broadcast-token"

step() { printf '\n=== step %s ===\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

# ---- §3.5 keystore separation guard (fail-closed) ----
# Must precede this script's FIRST proton invocation (step 3 below), and
# stays positioned immediately after the (proton-free, side-effect-free)
# variable setup above — i.e. before ANY step that could fail for reasons
# unrelated to keystore scoping (e.g. step 2's config-dir check).
# Exit 8 = keystore guard failed (§3.5), by convention with bin/safe-broadcast
# and scripts/sign-anchor-event.sh, which share this same check.
require_project_keystore_home "$0" || exit 8

# ---- step 1: anchor-source selection audit ----
step "1/10 anchor-source selection"
echo "  path:      $ANCHOR_SOURCE"
echo "  origin:    $ANCHOR_SOURCE_ORIGIN"
if [ ! -r "$ANCHOR_SOURCE" ]; then
	fail "anchor-source file not readable: $ANCHOR_SOURCE"
fi
SRC_BASENAME="$(basename "$ANCHOR_SOURCE")"
IS_FIXTURE=0
case "$SRC_BASENAME" in
	anchor-source.substantive.json|anchor-source.example.json)
		IS_FIXTURE=1
		if [ "$ALLOW_FIXTURE" -ne 1 ]; then
			fail "refusing fixture anchor-source '${SRC_BASENAME}' (origin: ${ANCHOR_SOURCE_ORIGIN}) without --allow-fixture. Fixtures hold stale/placeholder hashes frozen at their original cycle and are never valid PRIME DIRECTIVE gate-1 evidence. Pass --allow-fixture to explicitly opt in for schema-shape testing only."
		fi
		printf '  WARNING: using FIXTURE anchor-source (--allow-fixture given) — NOT valid gate-1 evidence.\n' >&2
		;;
esac
if [ "$ALLOW_FIXTURE" -eq 1 ] && [ "$IS_FIXTURE" -ne 1 ]; then
	printf '  WARNING: --allow-fixture was given but the selected anchor-source ("%s") is not a recognized fixture — the flag had no effect.\n' "$SRC_BASENAME" >&2
fi
echo "  basename:  $SRC_BASENAME"
SRC_SCHEMA_VER="$(jq -r '.schema_version // empty' "$ANCHOR_SOURCE")"
SRC_CYCLE_NUM="$(jq -r '.observations_branch.cycle_number_observed // empty' "$ANCHOR_SOURCE")"
SRC_COMPUTED_AT="$(jq -r '.computed_at // empty' "$ANCHOR_SOURCE")"
SRC_ID_HEX="$(jq -r '.identity_branch.operator_ed25519_pubkey_sha256_hex // empty' "$ANCHOR_SOURCE")"
SRC_MFST="$(jq -r '.artifacts_branch.public_api_manifest_root // empty' "$ANCHOR_SOURCE")"
SRC_DAG="$(jq -r '.dag_root_computed // empty' "$ANCHOR_SOURCE")"
echo "  schema_version:         $SRC_SCHEMA_VER"
echo "  cycle_number_observed:  $SRC_CYCLE_NUM"
echo "  computed_at:            $SRC_COMPUTED_AT"
if [ -n "$SRC_SCHEMA_VER" ] && [ -n "$SRC_CYCLE_NUM" ]; then
	echo "  derived memo_prefix:    fya${SRC_SCHEMA_VER}c${SRC_CYCLE_NUM}"
fi
# ---- --expect-cycle=<N> enforcement (mandatory for a real day-of
# rehearsal; see docs/PHASE_ALPHA_TESTNET_DRY_RUN.md) ----
# A testnet rehearsal is only valid PRIME DIRECTIVE gate-1 evidence for a
# mainnet broadcast targeting the SAME cycle. The hardened mainnet gate 1
# refuses cross-cycle evidence (e.g. fya1c3 evidence cannot authorize a
# fya1c4 broadcast) — so a rehearsal run against the wrong cycle's
# anchor-source would produce a tx_id that mainnet then refuses anyway,
# but only AFTER the testnet broadcast already happened. Catch the
# mismatch here instead, before anything is composed or broadcast.
if [ -n "$EXPECT_CYCLE" ]; then
	if [ "$SRC_CYCLE_NUM" != "$EXPECT_CYCLE" ]; then
		fail "anchor-source cycle_number_observed (${SRC_CYCLE_NUM:-<missing>}) does not match --expect-cycle=${EXPECT_CYCLE}. A testnet rehearsal's evidence is only valid for a mainnet broadcast targeting the SAME cycle (the hardened mainnet gate 1 refuses cross-cycle evidence). Recompose/regenerate the canonical anchor-source for cycle ${EXPECT_CYCLE} first (the rehearsal must run AFTER the day-of recompose), or pass --source=<a file whose cycle_number_observed is ${EXPECT_CYCLE}>."
	fi
	echo "  expect-cycle:           ${EXPECT_CYCLE}  (matches — OK)"
else
	printf '  NOTE: --expect-cycle=<N> not given — this run is NOT verified against any target mainnet cycle.\n' >&2
	printf '        --expect-cycle=<N> is MANDATORY for the day-of mainnet-gating rehearsal per docs/PHASE_ALPHA_TESTNET_DRY_RUN.md.\n' >&2
fi
echo "  identity pubkey:        $SRC_ID_HEX"
echo "  manifest root:          $SRC_MFST"
echo "  dag_root_computed:      $SRC_DAG"
if [ "$SRC_ID_HEX" = "0000000000000000000000000000000000000000000000000000000000000000" ] \
   || [ "$SRC_MFST" = "0000000000000000000000000000000000000000000000000000000000000000" ]; then
	printf '\n  WARNING: anchor-source has placeholder hashes (0000...).\n'
	printf '           This will inscribe placeholders on-chain.\n'
	printf '           If this is not intentional, re-run with --source=<real-source.json>.\n\n'
fi

# ---- step 2: verify rehearsal config ----
step "2/10 verify rehearsal config dir ${REHEARSAL_CFG}"
for f in xpr-account anchor-sink xpr-chain; do
	[ -r "${REHEARSAL_CFG}/${f}" ] || fail "config file missing: ${REHEARSAL_CFG}/${f}"
done
XPR_ACCOUNT="$(tr -d '\r\n\t ' < "${REHEARSAL_CFG}/xpr-account")"
[ -n "$XPR_ACCOUNT" ] || fail "config file empty: ${REHEARSAL_CFG}/xpr-account"
echo "  xpr-account: $XPR_ACCOUNT"
echo "  anchor-sink: $(cat "${REHEARSAL_CFG}/anchor-sink")"
echo "  xpr-chain:   $(cat "${REHEARSAL_CFG}/xpr-chain")"

# ---- step 3: verify the CURRENT on-chain anchor key is in the local
# keystore (chain-derived — no hardcoded pin, so this stays correct across
# future key rotations without editing this script) ----
step "3/10 verify ${XPR_ACCOUNT}@anchor key present in proton keystore (chain-derived)"
if ! command -v node >/dev/null 2>&1; then
	fail "node (Node.js) required for public-key format verification (scripts/lib/eosio-pubkey-raw-hex.js). node is already a transitive prerequisite of proton-cli itself."
fi
PUBKEY_HELPER="${REPO_ROOT}/scripts/lib/eosio-pubkey-raw-hex.js"
[ -r "$PUBKEY_HELPER" ] || fail "missing helper: $PUBKEY_HELPER"

CHAIN_RC=0
CHAIN_CURL_ERR="$(mktemp -t fya-testnet-curl-err.XXXXXX)"
CHAIN_ACCOUNT_JSON="$(curl -sS --max-time 15 -X POST -H 'content-type: application/json' \
	-d "$(jq -nc --arg a "$XPR_ACCOUNT" '{account_name:$a}')" \
	"${TESTNET_CHAIN_RPC}/v1/chain/get_account" 2>"$CHAIN_CURL_ERR")" || CHAIN_RC=$?
# Capture curl's own stderr (not discarded) so a fail-closed refusal here
# triages DNS/TLS/timeout distinctly instead of a bare "unreachable" —
# e.g. "Could not resolve host" vs "SSL certificate problem" vs "Operation
# timed out" are different operator actions.
CHAIN_CURL_ERR_TEXT="$(tr '\n' ' ' < "$CHAIN_CURL_ERR" 2>/dev/null)"
rm -f "$CHAIN_CURL_ERR"
if [ "$CHAIN_RC" -ne 0 ] || [ -z "$CHAIN_ACCOUNT_JSON" ]; then
	fail "testnet chain RPC unreachable: POST ${TESTNET_CHAIN_RPC}/v1/chain/get_account (account_name=${XPR_ACCOUNT}, curl rc=${CHAIN_RC}). curl stderr: ${CHAIN_CURL_ERR_TEXT:-<empty>}. Fail-closed per PRIME DIRECTIVE gate 1 — refusing to proceed without a verified current pubkey rather than guessing."
fi
if ! printf '%s' "$CHAIN_ACCOUNT_JSON" | jq -e --arg a "$XPR_ACCOUNT" \
	'.account_name == $a and (.permissions | type == "array")' >/dev/null 2>&1; then
	fail "testnet chain RPC get_account response malformed/unexpected for ${XPR_ACCOUNT}. Response (truncated): $(printf '%s' "$CHAIN_ACCOUNT_JSON" | head -c 300)"
fi
CHAIN_ANCHOR_PUBKEY="$(printf '%s' "$CHAIN_ACCOUNT_JSON" | jq -r '[.permissions[] | select(.perm_name=="anchor")][0].required_auth.keys[0].key // empty')"
if [ -z "$CHAIN_ANCHOR_PUBKEY" ]; then
	fail "testnet chain has no 'anchor' permission (with a key) on account ${XPR_ACCOUNT}; expected owner→active→anchor structure per docs/ANCHOR_ACCOUNT_KEY_ROTATION.md"
fi
echo "  chain-current ${XPR_ACCOUNT}@anchor pubkey (via ${TESTNET_CHAIN_RPC}): ${CHAIN_ANCHOR_PUBKEY:0:16}..."

CHAIN_ANCHOR_RAW=""
if ! CHAIN_ANCHOR_RAW="$(node "$PUBKEY_HELPER" "$CHAIN_ANCHOR_PUBKEY" 2>&1)"; then
	fail "could not decode chain-returned anchor pubkey '$CHAIN_ANCHOR_PUBKEY': $CHAIN_ANCHOR_RAW"
fi

# timeout matches the unlock probe below (step 4) — a locked keystore
# must not hang this step either.
KEYS_JSON="$(timeout 5 proton key:list 2>/dev/null || echo '[]')"
CANDIDATES="$(printf '%s' "$KEYS_JSON" | grep -oE '(PUB_K1_|EOS)[1-9A-HJ-NP-Za-km-z]+' | sort -u || true)"
if [ -z "$CANDIDATES" ]; then
	fail "no public keys found via 'proton key:list' in the local testnet keystore. The ${XPR_ACCOUNT}@anchor key must be imported before rehearsal — see docs/PHASE_ALPHA_TESTNET_DRY_RUN.md."
fi

MATCH_FOUND=0
while IFS= read -r cand; do
	[ -n "$cand" ] || continue
	CAND_RAW="$(node "$PUBKEY_HELPER" "$cand" 2>/dev/null)" || continue
	if [ "$CAND_RAW" = "$CHAIN_ANCHOR_RAW" ]; then
		MATCH_FOUND=1
		echo "  present: ${cand:0:24}...  (matches current on-chain key)"
		break
	fi
done <<-CANDLIST
$CANDIDATES
CANDLIST

if [ "$MATCH_FOUND" -ne 1 ]; then
	fail "the CURRENT on-chain ${XPR_ACCOUNT}@anchor public key (${CHAIN_ANCHOR_PUBKEY}) was not found in the local proton-cli testnet keystore. Either it was never imported, or it was rotated on-chain since the keystore was last updated. Import the matching private key (see docs/ANCHOR_ACCOUNT_KEY_ROTATION.md) and re-run. This check reads the pubkey from the chain itself (no hardcoded pin), so it stays correct across future rotations."
fi

# ---- step 4: keystore unlock check + chain preflight ----
step "4/10 keystore unlock + proton chain preflight"
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
if ! timeout 5 proton account "$XPR_ACCOUNT" >/dev/null 2>&1; then
	printf '  WARN: proton account %s timed out; keystore may be locked.\n' "$XPR_ACCOUNT"
	printf '        Run in a separate terminal:  HOME=~/.metal-fy-proton-test proton key:unlock\n'
	printf '        then re-run this script.\n' >&2
	exit 2
fi
echo "  keystore appears unlocked (${XPR_ACCOUNT} account read succeeded)"

# ---- step 5: compose 4-action tx via sign-anchor-event.sh --dry-run ----
step "5/10 compose 4-action testnet tx"
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

# ---- step 6: create broadcast token ----
# R16: the token is chain- AND content-bound (not a bare `touch`), so it
# cannot be reused, within its TTL, to authorize a differently-shaped or
# differently-targeted (e.g. mainnet) broadcast. Bind it to the exact tx
# composed in step 5, using the same canonicalization bin/safe-broadcast
# uses for its own tx_sha256 (jq -c . | sha256).
step "6/10 create broadcast token (5-min TTL, chain+tx-bound per R16)"
if command -v sha256sum >/dev/null 2>&1; then
	TOKEN_TX_SHA256="$(jq -c . "$TX_FILE" | sha256sum | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
	TOKEN_TX_SHA256="$(jq -c . "$TX_FILE" | shasum -a 256 | awk '{print $1}')"
else
	fail "sha256sum or shasum required to bind the broadcast token (R16)"
fi
[ -n "$TOKEN_TX_SHA256" ] || fail "failed to compute tx_sha256 for token binding"
printf '{"chain":"testnet-a","tx_sha256":"%s"}' "$TOKEN_TX_SHA256" > "$TOKEN_FILE" || fail "cannot create $TOKEN_FILE"
echo "  token created at $TOKEN_FILE (chain=testnet-a, tx_sha256=${TOKEN_TX_SHA256})"

# ---- step 7: invoke bin/safe-broadcast ----
step "7/10 invoke bin/safe-broadcast --chain=testnet-a --non-interactive"
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

# ---- step 8: reconstruct sign-anchor-event JSON for gen-anchor-receipt input ----
step "8/10 assemble sign-anchor-event output shape for receipt input"
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

# ---- step 9: gen-anchor-receipt 7-gate verify chain ----
step "9/10 gen-anchor-receipt 7-gate verify against $TESTNET_RPC"
RECEIPT_OUT="${LOGIN_HOME}/.fya-testnet-receipt.json"
bash "${REPO_ROOT}/scripts/gen-anchor-receipt.sh" \
	--input="$SIGN_JSON" \
	--anchor-source="$ANCHOR_SOURCE" \
	--out="$RECEIPT_OUT" \
	--rpc="$TESTNET_RPC" \
	--trigger=manual \
	--prev-anchor-tx-id=null \
	|| fail "gen-anchor-receipt.sh failed"
echo "  7-gate PASS, receipt saved: $RECEIPT_OUT"

# ---- step 10: emit sentinel line for AI copy-paste ----
step "10/10 rehearsal complete"
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
--testnet-tx-id argument for the next mainnet cycle-transition anchor
broadcast in bin/safe-broadcast (and record it in memory as PRIME
DIRECTIVE gate-1 evidence).
=========================================================
EOF
exit 0
