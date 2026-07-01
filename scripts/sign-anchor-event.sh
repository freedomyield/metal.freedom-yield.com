#!/usr/bin/env bash
# sign-anchor-event.sh — HC-single 4-action pack anchor broadcaster.
#
# CHAIN: default testnet-a (via --chain=testnet-a explicit). Mainnet is
#        opt-in only per docs/CONSTITUTION.md PRIME DIRECTIVE.
# PRIME_DIRECTIVE: TESTNET-FIRST — this script MUST NOT invoke proton
#                  directly. It composes the 4-action tx JSON from
#                  /api/anchor-source.json and delegates broadcast to
#                  bin/safe-broadcast (tier-2 wrapper).
#
# 2026-07-01 rewrite: single-action "fyid1:<hash>" memo scheme replaced
# with the 4-action pack scheme (memo prefix `fya<schema>c<cycle>-*`) per
# memory/project_merkle_dag_identity_anchor_design_20260701.md. The
# `fyid1v1c*` namespace is retired due to the mainnet accident tx
# 997881e844befaf9c159c741988fe99e8ca566a52e539639ab83517b1f36100a
# (memo `fyid1v1c2-test-single`) that permanently occupies it.
#
# Authority chain:
#   ed25519 operator identity key (Mac) → /api/identity.json
#     → anchor-source.json (dag_root_computed + 3 branch roots)
#       → metalfreedom@anchor (validator host, K1 via proton-cli)
#         → bin/safe-broadcast (tier-2 gate)
#           → proton transaction:push (4 eosio.token::transfer actions)
#             → on-chain: 4 rows with memos fya<S>c<N>-{id,ob,ar}:<hex>
#                         + fya<S>c<N>:<dag_root_hex>
#               → /api/anchor-receipt.json (produced by gen-anchor-receipt.sh)
#
# Constitution alignment:
#   - §2 #1 validator health: no blocking I/O against metalgo.
#   - §3.3 operational: anchor key never printed / logged / echoed;
#     proton-cli keystore holds the working copy (config §B4).
#   - §3.4 PRIME DIRECTIVE: broadcast goes through bin/safe-broadcast
#     which enforces all 4 gates. Direct `proton transaction:push`
#     invocation is banned; if attempted, tier-1 broadcast-guard.sh
#     blocks it and this script exits non-zero.
#   - §5: ships in scripts/ for validator-host execution; deployment
#     to the validator host is operator-approved.
#
# Exit codes:
#   0  success — JSON receipt fragment on stdout
#   1  usage error
#   2  anchor-source.json missing / invalid / dag_root mismatch
#   3  config file missing (xpr-account / anchor-sink)
#   4  bin/safe-broadcast missing or non-executable
#   5  broadcast failed (safe-broadcast propagated non-zero)
#   6  receipt shape assembly failed
#
# Usage:
#   sign-anchor-event.sh --chain=<testnet-a|mainnet-a>
#                        [--anchor-source=<path>]
#                        [--testnet-tx-id=<64hex>]
#                        [--dry-run-log=<file>]
#                        [--non-interactive]
#
# Required:
#   --chain=<testnet-a|mainnet-a>   Target chain, mandatory.
#
# Optional:
#   --anchor-source=<path>          Default: public/api/anchor-source.json
#   --testnet-tx-id=<64hex>         Passed through to safe-broadcast (mainnet only).
#   --dry-run-log=<file>            Passed through to safe-broadcast (mainnet only).
#   --non-interactive               Passed through to safe-broadcast.
#   --dry-run                       Compose + emit tx JSON to stdout only.
#                                   DOES NOT invoke safe-broadcast, so requires
#                                   no operator token. Use for schema tests and
#                                   for producing the --dry-run-log input to
#                                   mainnet safe-broadcast.
#
# Config files (validator-host convention, /etc/freedom-yield/):
#   xpr-account   XPR account name that holds the anchor permission.
#                 Mainnet: metalfreedom (or the mainnet operator account).
#                 Testnet: rehearsal test account (see PHASE_ALPHA_TESTNET_DRY_RUN.md).
#   anchor-sink   sink account for eosio.token::transfer (BLOCK-1: != xpr-account).
#   xpr-quantity  transfer quantity in EOSIO asset form (default "0.0001 XPR").
#
# JSON receipt fragment on stdout (consumed by gen-anchor-receipt.sh in T-D):
#   {
#     "tx_id": "<64-hex>",
#     "chain": "metal-a-chain",
#     "network": "testnet-a" | "mainnet-a",
#     "method": "hc_single_4_action_pack",
#     "schema_version": <int>,
#     "cycle_number": <int>,
#     "memo_prefix": "fya<S>c<N>",
#     "actions": [
#       {"branch": "identity",         "memo": "fya<S>c<N>-id:<hex>", "root_hex": "<hex>"},
#       {"branch": "observations",     "memo": "fya<S>c<N>-ob:<hex>", "root_hex": "<hex>"},
#       {"branch": "artifacts",        "memo": "fya<S>c<N>-ar:<hex>", "root_hex": "<hex>"},
#       {"branch": "dag_root_summary", "memo": "fya<S>c<N>:<hex>",    "root_hex": "<hex>"}
#     ],
#     "authorization": {"actor": "<xpr-account>", "permission": "anchor"},
#     "sink":     "<anchor-sink>",
#     "quantity": "<xpr-quantity>"
#   }

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAFE_BROADCAST="${REPO_ROOT}/bin/safe-broadcast"

# -------- arg parsing --------
CHAIN=""
ANCHOR_SOURCE="${REPO_ROOT}/public/api/anchor-source.json"
TESTNET_TX_ID=""
DRY_RUN_LOG=""
NON_INTERACTIVE=0
DRY_RUN=0

for arg in "$@"; do
	case "$arg" in
		--chain=*)           CHAIN="${arg#*=}" ;;
		--anchor-source=*)   ANCHOR_SOURCE="${arg#*=}" ;;
		--testnet-tx-id=*)   TESTNET_TX_ID="${arg#*=}" ;;
		--dry-run-log=*)     DRY_RUN_LOG="${arg#*=}" ;;
		--non-interactive)   NON_INTERACTIVE=1 ;;
		--dry-run)           DRY_RUN=1 ;;
		-h|--help)           sed -n '2,90p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)                   echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if [ -z "$CHAIN" ]; then
	echo "ERROR: --chain=<testnet-a|mainnet-a> required" >&2
	exit 1
fi
case "$CHAIN" in
	testnet-a|mainnet-a) ;;
	*) echo "ERROR: --chain must be testnet-a or mainnet-a, got: $CHAIN" >&2; exit 1 ;;
esac

# -------- prerequisites --------
if [ ! -r "$ANCHOR_SOURCE" ]; then
	echo "ERROR: anchor-source.json not readable: $ANCHOR_SOURCE" >&2
	exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "ERROR: jq required" >&2
	exit 2
fi
if ! command -v sha256sum >/dev/null 2>&1; then
	if command -v shasum >/dev/null 2>&1; then
		sha256_pipe() { shasum -a 256 | awk '{print $1}'; }
	else
		echo "ERROR: sha256sum or shasum required" >&2
		exit 2
	fi
else
	sha256_pipe() { sha256sum | awk '{print $1}'; }
fi
if [ ! -x "$SAFE_BROADCAST" ]; then
	echo "ERROR (4): bin/safe-broadcast missing or non-executable: $SAFE_BROADCAST" >&2
	exit 4
fi

# -------- read anchor-source.json --------
SCHEMA_VER="$(jq -r '.schema_version // 0' "$ANCHOR_SOURCE")"
if [ "$SCHEMA_VER" -ne 1 ]; then
	echo "ERROR (2): anchor-source.json schema_version must be 1, got: $SCHEMA_VER" >&2
	exit 2
fi

CYCLE_NUM="$(jq -r '.observations_branch.cycle_number_observed // 0' "$ANCHOR_SOURCE")"
if [ "$CYCLE_NUM" -lt 1 ]; then
	echo "ERROR (2): observations_branch.cycle_number_observed must be >= 1, got: $CYCLE_NUM" >&2
	exit 2
fi

DAG_ROOT="$(jq -r '.dag_root_computed // empty' "$ANCHOR_SOURCE")"
if ! echo "$DAG_ROOT" | grep -qE '^[0-9a-f]{64}$'; then
	echo "ERROR (2): dag_root_computed missing or malformed in anchor-source.json" >&2
	exit 2
fi

# Compute per-branch canonical hashes (RFC-8785-ish: jq -cS = compact + sorted keys).
IDENTITY_ROOT="$(jq -cS '.identity_branch' "$ANCHOR_SOURCE" | sha256_pipe)"
OBSERVATIONS_ROOT="$(jq -cS '.observations_branch' "$ANCHOR_SOURCE" | sha256_pipe)"
ARTIFACTS_ROOT="$(jq -cS '.artifacts_branch' "$ANCHOR_SOURCE" | sha256_pipe)"

# Verify dag_root_computed matches the recomputation (belt + suspenders).
COMPUTED_DAG="$(printf '%s%s%s' "$IDENTITY_ROOT" "$OBSERVATIONS_ROOT" "$ARTIFACTS_ROOT" | sha256_pipe)"
if [ "$COMPUTED_DAG" != "$DAG_ROOT" ]; then
	echo "ERROR (2): dag_root_computed mismatch — anchor-source.json is inconsistent" >&2
	echo "         recomputed: $COMPUTED_DAG" >&2
	echo "         file says:  $DAG_ROOT" >&2
	exit 2
fi

# -------- config --------
CONFIG_DIR="${FY_CONFIG_DIR:-/etc/freedom-yield}"

read_config_strict() {
	local key="$1"
	local path="${CONFIG_DIR}/${key}"
	if [ ! -r "$path" ]; then
		echo "ERROR (3): required config missing: $path" >&2
		exit 3
	fi
	tr -d '\r\n\t ' < "$path"
}

read_config_default() {
	local key="$1" default="$2"
	local path="${CONFIG_DIR}/${key}"
	if [ -r "$path" ]; then
		head -n 1 "$path" | sed -e 's/[[:space:]]*$//'
	else
		printf '%s' "$default"
	fi
}

XPR_ACCOUNT="$(read_config_strict xpr-account)"
if [ -z "$XPR_ACCOUNT" ]; then
	echo "ERROR (3): xpr-account is empty" >&2
	exit 3
fi
SINK="$(read_config_strict anchor-sink)"
if [ -z "$SINK" ]; then
	echo "ERROR (3): anchor-sink is empty" >&2
	exit 3
fi
if [ "$SINK" = "$XPR_ACCOUNT" ]; then
	echo "ERROR (3): sink must not equal xpr-account (BLOCK-1: eosio.token rejects self-transfer)" >&2
	exit 3
fi
QUANTITY="$(read_config_default xpr-quantity '0.0001 XPR')"

# -------- memo prefix --------
# Format: fya<schema>c<cycle>-<branch>:<hex>  or  fya<schema>c<cycle>:<hex>
# fya = "freedom yield anchor". Schema major and cycle are numeric.
# Pivoted from fyid1v1c<N> on 2026-07-01 to isolate from mainnet
# accident tx memo fyid1v1c2-test-single.
PREFIX="fya${SCHEMA_VER}c${CYCLE_NUM}"

MEMO_ID="${PREFIX}-id:${IDENTITY_ROOT}"
MEMO_OB="${PREFIX}-ob:${OBSERVATIONS_ROOT}"
MEMO_AR="${PREFIX}-ar:${ARTIFACTS_ROOT}"
MEMO_DG="${PREFIX}:${DAG_ROOT}"

# Sanity: each memo must fit under EOSIO 256-byte memo limit with margin.
for m in "$MEMO_ID" "$MEMO_OB" "$MEMO_AR" "$MEMO_DG"; do
	if [ "${#m}" -gt 200 ]; then
		echo "ERROR (2): memo too long (${#m} > 200): $m" >&2
		exit 2
	fi
done

# -------- compose 4-action tx JSON --------
TX_FILE="$(mktemp -t sign-anchor-tx.XXXXXX)"
trap 'rm -f "$TX_FILE"' EXIT

jq -n \
	--arg from "$XPR_ACCOUNT" \
	--arg to "$SINK" \
	--arg qty "$QUANTITY" \
	--arg memo_id "$MEMO_ID" \
	--arg memo_ob "$MEMO_OB" \
	--arg memo_ar "$MEMO_AR" \
	--arg memo_dg "$MEMO_DG" \
	'{
		actions: [
			{account: "eosio.token", name: "transfer",
			 authorization: [{actor: $from, permission: "anchor"}],
			 data: {from: $from, to: $to, quantity: $qty, memo: $memo_id}},
			{account: "eosio.token", name: "transfer",
			 authorization: [{actor: $from, permission: "anchor"}],
			 data: {from: $from, to: $to, quantity: $qty, memo: $memo_ob}},
			{account: "eosio.token", name: "transfer",
			 authorization: [{actor: $from, permission: "anchor"}],
			 data: {from: $from, to: $to, quantity: $qty, memo: $memo_ar}},
			{account: "eosio.token", name: "transfer",
			 authorization: [{actor: $from, permission: "anchor"}],
			 data: {from: $from, to: $to, quantity: $qty, memo: $memo_dg}}
		]
	}' > "$TX_FILE"

# -------- --dry-run: emit tx JSON + composed memos, do NOT broadcast --------
if [ "$DRY_RUN" = "1" ]; then
	jq -n \
		--arg chain "$CHAIN" \
		--argjson schema_version "$SCHEMA_VER" \
		--argjson cycle_number "$CYCLE_NUM" \
		--arg prefix "$PREFIX" \
		--arg id_root "$IDENTITY_ROOT" \
		--arg ob_root "$OBSERVATIONS_ROOT" \
		--arg ar_root "$ARTIFACTS_ROOT" \
		--arg dag_root "$DAG_ROOT" \
		--arg from "$XPR_ACCOUNT" \
		--arg to "$SINK" \
		--arg qty "$QUANTITY" \
		--slurpfile tx "$TX_FILE" \
		'{
			dry_run: true,
			target_chain: $chain,
			schema_version: $schema_version,
			cycle_number: $cycle_number,
			memo_prefix: $prefix,
			composed_memos: {
				identity:         "\($prefix)-id:\($id_root)",
				observations:     "\($prefix)-ob:\($ob_root)",
				artifacts:        "\($prefix)-ar:\($ar_root)",
				dag_root_summary: "\($prefix):\($dag_root)"
			},
			authorization: {actor: $from, permission: "anchor"},
			sink: $to,
			quantity: $qty,
			tx: $tx[0]
		}'
	exit 0
fi

# -------- delegate to bin/safe-broadcast --------
SAFE_ARGS=(--tx="$TX_FILE" --chain="$CHAIN")
[ -n "$TESTNET_TX_ID" ]    && SAFE_ARGS+=(--testnet-tx-id="$TESTNET_TX_ID")
[ -n "$DRY_RUN_LOG" ]      && SAFE_ARGS+=(--dry-run-log="$DRY_RUN_LOG")
[ "$NON_INTERACTIVE" = "1" ] && SAFE_ARGS+=(--non-interactive)

TX_ID=""
BROADCAST_RC=0
TX_ID="$(bash "$SAFE_BROADCAST" "${SAFE_ARGS[@]}")" || BROADCAST_RC=$?
if [ "$BROADCAST_RC" -ne 0 ] || ! echo "$TX_ID" | grep -qE '^[a-f0-9]{64}$'; then
	echo "ERROR (5): safe-broadcast failed (rc=$BROADCAST_RC, tx_id=${TX_ID:-empty})" >&2
	exit 5
fi

# -------- emit JSON receipt fragment on stdout --------
jq -n \
	--arg tx_id "$TX_ID" \
	--arg chain "$CHAIN" \
	--argjson schema_version "$SCHEMA_VER" \
	--argjson cycle_number "$CYCLE_NUM" \
	--arg prefix "$PREFIX" \
	--arg id_root "$IDENTITY_ROOT" \
	--arg ob_root "$OBSERVATIONS_ROOT" \
	--arg ar_root "$ARTIFACTS_ROOT" \
	--arg dag_root "$DAG_ROOT" \
	--arg from "$XPR_ACCOUNT" \
	--arg to "$SINK" \
	--arg qty "$QUANTITY" \
	'{
		tx_id: $tx_id,
		chain: "metal-a-chain",
		network: $chain,
		method: "hc_single_4_action_pack",
		schema_version: $schema_version,
		cycle_number: $cycle_number,
		memo_prefix: $prefix,
		actions: [
			{branch: "identity",         memo: "\($prefix)-id:\($id_root)",  root_hex: $id_root},
			{branch: "observations",     memo: "\($prefix)-ob:\($ob_root)",  root_hex: $ob_root},
			{branch: "artifacts",        memo: "\($prefix)-ar:\($ar_root)",  root_hex: $ar_root},
			{branch: "dag_root_summary", memo: "\($prefix):\($dag_root)",    root_hex: $dag_root}
		],
		authorization: {actor: $from, permission: "anchor"},
		sink: $to,
		quantity: $qty
	}'
