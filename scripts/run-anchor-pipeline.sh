#!/usr/bin/env bash
# run-anchor-pipeline.sh — v2 anchor orchestrator.
#
# CHAIN: default testnet-a (--chain=testnet-a explicit). Mainnet is
#        opt-in only per docs/CONSTITUTION.md PRIME DIRECTIVE.
# PRIME_DIRECTIVE: TESTNET-FIRST — this script broadcasts via
#                  bin/safe-broadcast which enforces all 4 gates.
#
# Runs a fail-closed freshness preflight, then the four-step anchor
# pipeline sequentially:
#   0. scripts/check-scripts-freshness.sh → fail-closed HEAD==origin/main gate
#   1. scripts/gen-anchor-source.sh   → refresh anchor-source.json
#   2. scripts/sign-anchor-event.sh   → compose + broadcast 4-action pack
#   3. scripts/gen-anchor-receipt.sh  → fetch tx + 7-PASS verify + write receipt
#   4. scripts/append-anchor-history.sh → append line to history jsonl
#
# AFTER the pipeline — publication (deliberately NOT done here): the
# artifacts this run produced reach their public URLs from the validator
# host via
#   bash scripts/push-to-web-host.sh anchor-receipt.json
#   bash scripts/push-to-web-host.sh anchor-history.jsonl
#   bash scripts/push-to-web-host.sh archive/anchor-source-<dag_root>.json
#   bash scripts/push-to-web-host.sh archive/anchor-receipt-<tx_id>.json
# (`anchor-source.json` itself is git-deploy owned — commit it, do not push
# it; see docs/DEPLOY_OWNERSHIP_MATRIX.md.) The last two are the R18
# per-anchor archives that anchor-history.jsonl's archived_source_path /
# archived_receipt_path advertise; the subdirectory push shapes were added
# 2026-08-05 and require the matching web-host wrapper allowlist
# (scripts/install-xserver-subdir-allowlist.sh). Pushing stays outside this
# script on purpose: this is a broadcast path, and an outbound SSH failure
# must never be able to fail a run whose on-chain anchor already succeeded.
#
# Freshness preflight (Task 4, 2026-07-09 host-checkout-auto-advance design):
# a checkout that is behind origin/main can carry an already-fixed bug or a
# stale anchor-source value forward into a live broadcast, so this pipeline
# refuses to run anchor generation/sign/broadcast against anything but a
# checkout that is exactly even with origin/main.
# scripts/check-scripts-freshness.sh exit codes: 0=fresh, 1=stale,
# 3=fetch-failed — both 1 and 3 fail-closed here: an undetermined freshness
# (fetch failed) is treated the same as a known-stale one, because on a
# broadcast-critical path "we couldn't tell" must never be read as "go
# ahead". Emergency-only escape hatch: FYD_ALLOW_STALE_PIPELINE=1 skips the
# gate and fires a loud `alert high` so the bypass is never silent; default
# is enforce (gate ON).
#
# Fails fast on any step; emits step-by-step progress on stderr.
# On success, prints the tx_id on stdout.
#
# 2026-07-01 introduction: replaces the fyid1:<hash> single-action
# orchestration that lived in post-anchor-event.sh. That legacy script
# was retired and deleted in the v2 migration (2026-07-06); all anchor
# broadcasts go through this pipeline.
#
# Exit codes:
#   0    all four steps PASS, tx_id on stdout
#   1    usage / arg error
#   2    freshness preflight failed (stale or undetermined checkout) —
#        run advance-host-checkout.sh, or FYD_ALLOW_STALE_PIPELINE=1 to
#        bypass (emergency only; always alerts)
#   10+  step-N failed, script exit = 10 + step number (11..14)
#
# Usage:
#   run-anchor-pipeline.sh --chain=<testnet-a|mainnet-a>
#                          [--trigger=<cyclestart|cycleend|idrotate|heartbeat|manual>]
#                          [--testnet-tx-id=<64hex>]
#                          [--dry-run-log=<file>]
#                          [--prev-anchor-tx-id=<64hex|null>]
#                          [--event-type=<cyclestart|cycleend|idrotate|heartbeat>]
#                          [--key-seq=<int>]
#                          [--non-interactive]
#                          [--skip-source-refresh]
#
# Env overrides:
#   FYD_ALLOW_STALE_PIPELINE=1  bypass the freshness gate (emergency only;
#                               fires alert high on every use — see above)
#   FYD_NOTIFY                  notifier script used for the bypass alert
#                               (default: <repo>/scripts/notify.sh)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CHAIN=""
TRIGGER="manual"
TESTNET_TX_ID=""
DRY_RUN_LOG=""
PREV_ANCHOR_TX_ID="null"
EVENT_TYPE=""
KEY_SEQ=""
NON_INTERACTIVE=""
SKIP_SOURCE_REFRESH=0

for arg in "$@"; do
	case "$arg" in
		--chain=*)                CHAIN="${arg#*=}" ;;
		--trigger=*)              TRIGGER="${arg#*=}" ;;
		--testnet-tx-id=*)        TESTNET_TX_ID="${arg#*=}" ;;
		--dry-run-log=*)          DRY_RUN_LOG="${arg#*=}" ;;
		--prev-anchor-tx-id=*)    PREV_ANCHOR_TX_ID="${arg#*=}" ;;
		--event-type=*)           EVENT_TYPE="${arg#*=}" ;;
		--key-seq=*)              KEY_SEQ="${arg#*=}" ;;
		--non-interactive)        NON_INTERACTIVE="--non-interactive" ;;
		--skip-source-refresh)    SKIP_SOURCE_REFRESH=1 ;;
		-h|--help)                sed -n '2,61p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)                        echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if [ -z "$CHAIN" ]; then
	echo "ERROR: --chain=<testnet-a|mainnet-a> required" >&2
	exit 1
fi

ANCHOR_SOURCE="${REPO_ROOT}/public/api/anchor-source.json"
LOG() { printf '[run-anchor-pipeline] %s\n' "$*" >&2; }

NOTIFY="${FYD_NOTIFY:-${REPO_ROOT}/scripts/notify.sh}"
alert() {
	# alert <priority> <title> <message> — mirrors advance-host-checkout.sh's
	# alert() pattern: best-effort notify, never fatal if the notifier itself
	# is missing/broken (that must not block the LOG line already emitted).
	if [ -x "$NOTIFY" ] || [ -f "$NOTIFY" ]; then
		bash "$NOTIFY" "$1" "$2" "$3" || LOG "WARN: notify failed (alert was: $2 — $3)"
	else
		LOG "WARN: notifier not found at $NOTIFY (alert was: $2 — $3)"
	fi
}

# -------- preflight: fail-closed freshness gate (Task 4) --------
# Broadcast-critical: refuse to run anchor generation/sign/broadcast against
# a checkout that is behind origin/main, or whose freshness could not even
# be determined. See header comment for the full rationale. Default is
# enforce; FYD_ALLOW_STALE_PIPELINE=1 is the sole, explicitly-audited
# escape hatch and it always alerts loudly when used so a bypass can never
# pass unnoticed.
if [ "${FYD_ALLOW_STALE_PIPELINE:-0}" = "1" ]; then
	LOG "WARNING: FYD_ALLOW_STALE_PIPELINE=1 — freshness gate BYPASSED for this run"
	alert high "run-anchor-pipeline: freshness gate BYPASSED" "FYD_ALLOW_STALE_PIPELINE=1 skipped the fail-closed freshness preflight for this anchor pipeline invocation (chain=${CHAIN}, trigger=${TRIGGER}). Emergency override only — confirm the checkout is actually safe."
elif ! bash "${REPO_ROOT}/scripts/check-scripts-freshness.sh" >&2; then
	LOG "ERROR (2): refusing to run anchor pipeline on a stale/undetermined checkout — run advance-host-checkout.sh"
	exit 2
else
	LOG "preflight OK: checkout is fresh (HEAD == origin/main)"
fi

# -------- step 1: refresh anchor-source.json --------
if [ "$SKIP_SOURCE_REFRESH" = "1" ]; then
	LOG "step 1/4 SKIP: --skip-source-refresh in effect; using existing $ANCHOR_SOURCE"
	if [ ! -r "$ANCHOR_SOURCE" ]; then
		LOG "ERROR (11): anchor-source.json not readable at $ANCHOR_SOURCE (cannot skip refresh)"
		exit 11
	fi
else
	LOG "step 1/4: refreshing anchor-source.json via gen-anchor-source.sh"
	if ! bash "${REPO_ROOT}/scripts/gen-anchor-source.sh"; then
		LOG "ERROR (11): gen-anchor-source.sh failed"
		exit 11
	fi
fi

# -------- step 2: sign + broadcast 4-action pack --------
LOG "step 2/4: sign + broadcast via sign-anchor-event.sh"
SIGN_ARGS=(--chain="$CHAIN" --anchor-source="$ANCHOR_SOURCE")
[ -n "$TESTNET_TX_ID" ]      && SIGN_ARGS+=(--testnet-tx-id="$TESTNET_TX_ID")
[ -n "$DRY_RUN_LOG" ]        && SIGN_ARGS+=(--dry-run-log="$DRY_RUN_LOG")
[ -n "$NON_INTERACTIVE" ]    && SIGN_ARGS+=("$NON_INTERACTIVE")

SIGN_OUT="$(mktemp -t run-anchor-sign.XXXXXX)"
trap 'rm -f "$SIGN_OUT"' EXIT

if ! bash "${REPO_ROOT}/scripts/sign-anchor-event.sh" "${SIGN_ARGS[@]}" > "$SIGN_OUT"; then
	LOG "ERROR (12): sign-anchor-event.sh failed"
	cat "$SIGN_OUT" >&2
	exit 12
fi

TX_ID="$(jq -r '.tx_id' "$SIGN_OUT")"
LOG "step 2/4 OK: tx_id=$TX_ID"

# -------- step 3: fetch + 7-PASS verify + write receipt --------
LOG "step 3/4: gen-anchor-receipt.sh (7-PASS verify + write receipt)"
RECEIPT_ARGS=(
	--input="$SIGN_OUT"
	--anchor-source="$ANCHOR_SOURCE"
	--trigger="$TRIGGER"
	--prev-anchor-tx-id="$PREV_ANCHOR_TX_ID"
)
if ! bash "${REPO_ROOT}/scripts/gen-anchor-receipt.sh" "${RECEIPT_ARGS[@]}" >&2; then
	LOG "ERROR (13): gen-anchor-receipt.sh failed"
	exit 13
fi

RECEIPT="${REPO_ROOT}/public/api/anchor-receipt.json"

# -------- step 4: append to history --------
LOG "step 4/4: append-anchor-history.sh"
APPEND_ARGS=(--receipt="$RECEIPT")
[ -n "$EVENT_TYPE" ] && APPEND_ARGS+=(--event-type="$EVENT_TYPE")
[ -n "$KEY_SEQ" ]    && APPEND_ARGS+=(--key-seq="$KEY_SEQ")

if ! bash "${REPO_ROOT}/scripts/append-anchor-history.sh" "${APPEND_ARGS[@]}" >&2; then
	LOG "ERROR (14): append-anchor-history.sh failed"
	exit 14
fi

LOG "PIPELINE COMPLETE: tx_id=$TX_ID, receipt=$RECEIPT"
echo "$TX_ID"
