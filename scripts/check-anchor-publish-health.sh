#!/usr/bin/env bash
# check-anchor-publish-health.sh — verify the PUBLIC /api/anchor-source.json is
# both SERVED (HTTP 200) and CONTENT-CORRECT: its dag_root_computed must equal
# the DAG root actually anchored on-chain, as recorded in the public
# anchor-receipt.json. Alert-only — this monitor performs no recovery.
#
# CHAIN: none — read-only HTTP GETs of two public URLs. No broadcast, no push.
# PRIME_DIRECTIVE: TESTNET-FIRST — this script has no broadcast pathway.
#
# Why content-verify and not just liveness:
#   anchor-source.json is published via git-deploy. A served file can return
#   200 while carrying a STALE dag_root_computed that no longer reproduces the
#   value anchored on-chain — precisely the failure that went unnoticed for
#   three days. A liveness (200-only) check cannot detect it. This monitor
#   fetches the served file and asserts its combined DAG root reproduces the
#   on-chain anchored root recorded in the receipt.
#
# What it compares:
#   served anchor-source.json   .dag_root_computed                 (hex64)
#       ==
#   served anchor-receipt.json  anchored combined DAG root:
#         primary : hex of the dag_root_summary action memo `fya<S>c<N>:<hex>`
#         fallback: that action's .root_hex, then top-level .dag_root_hash
#   The receipt is the project's durable record of the value broadcast to Metal
#   A-chain, so equality proves the public source reproduces on-chain state.
#
# Recovery: NONE — deliberately. The previous auto-recover invoked
#   push-to-web-host.sh with "anchor-source.json", a filename that script's
#   allowlist rejects (it only accepts anchor-receipt.json, not
#   anchor-source.json) — the call could never succeed. Under git-deploy the
#   publish path is GitHub Actions, not a host-side push, so a host recover is
#   structurally impossible anyway. This monitor is alert-only: it logs,
#   fires a high-priority notify.sh push (see Alerting below), and exits
#   non-zero so the operator acts.
#
# Exit codes:
#   0  served AND dag_root_computed matches the anchored root (verbose: heartbeat)
#   2  anchor-source.json not served (HTTP != 200) — alert, no recover
#   3  served but dag_root_computed MISMATCHES the anchored root (stale publish)
#   4  served but the receipt could not be fetched/parsed (cannot content-verify)
#   5  served but anchor-source.json is unparseable / missing dag_root_computed
#      (or jq is unavailable)
#
# Logging:
#   Every non-OK event is written to stderr (for cron mail) and, when the path
#   is writable, appended to $ANCHOR_PUBLISH_HEALTH_LOG
#   (default /var/log/anchor-publish-health.log) for later audit.
#
# Alerting:
#   Every failure exit (2/3/4/5) additionally fires one high-priority ntfy
#   push via notify.sh — added 2026-07-08 after this checker sat RED for days
#   post-incident with zero phone signal (no notify call existed, and the
#   installed cron had no output redirect for cron mail to fall back on).
#   The alert title always names the exit code so the operator can triage
#   from the push notification alone, mirroring the alert() pattern in
#   scripts/check-host-drift.sh. Best-effort: a notify.sh failure is logged
#   (WARN) but never escalates the exit code or blocks the check.
#
# Usage:
#   bash scripts/check-anchor-publish-health.sh [--verbose]
#
# Env overrides (test-time + ops):
#   FYD_NOTIFY   notifier to invoke (default: <script dir>/notify.sh)
#
# Cron target (/etc/cron.d/metal-anchor-publish-health), every 15 minutes:
#   */15 * * * * deploy bash /home/.../scripts/check-anchor-publish-health.sh

set -uo pipefail

VERBOSE=0
for arg in "$@"; do
	case "$arg" in
		--verbose|-v) VERBOSE=1 ;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_URL="${ANCHOR_SOURCE_URL:-https://metal.freedom-yield.com/api/anchor-source.json}"
RECEIPT_URL="${ANCHOR_RECEIPT_URL:-https://metal.freedom-yield.com/api/anchor-receipt.json}"
LOG="${ANCHOR_PUBLISH_HEALTH_LOG:-/var/log/anchor-publish-health.log}"
CURL="${FYD_CURL:-curl}"
NOTIFY="${FYD_NOTIFY:-${SCRIPT_DIR}/notify.sh}"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

log() {
	# stderr for cron, appended to the log file when the path is writable.
	printf '%s %s\n' "$NOW_ISO" "$*" >&2
	if [ -w "$(dirname "$LOG")" ] 2>/dev/null || [ -w "$LOG" ] 2>/dev/null; then
		printf '%s %s\n' "$NOW_ISO" "$*" >> "$LOG" 2>/dev/null || true
	fi
}

alert() {
	# alert <priority> <title> <message> — best-effort; a notify.sh failure
	# is logged but never changes the caller's exit code.
	if [ -x "$NOTIFY" ] || [ -f "$NOTIFY" ]; then
		bash "$NOTIFY" "$1" "$2" "$3" || log "WARN: notify failed (alert was: $2 — $3)"
	else
		log "WARN: notifier not found at $NOTIFY (alert was: $2 — $3)"
	fi
}

is_hex64() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# fetch <url> <body_outfile> -> prints the HTTP status code (000 on failure).
fetch() {
	"$CURL" -sS -o "$2" -w "%{http_code}" --max-time 15 "$1" 2>/dev/null || echo "000"
}

if ! command -v jq >/dev/null 2>&1; then
	log "ERROR jq not found — cannot content-verify anchor-source.json"
	alert high "anchor-publish-health: jq missing (exit 5)" "jq not found on this host — cannot content-verify anchor-source.json."
	exit 5
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/anchor-publish-health.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SRC_BODY="$TMP/source.json"
RCPT_BODY="$TMP/receipt.json"

# ---- 1. liveness of the served anchor-source.json ---------------------------
SRC_HTTP="$(fetch "$SOURCE_URL" "$SRC_BODY")"
if [ "$SRC_HTTP" != "200" ]; then
	log "ERROR not served: $SOURCE_URL HTTP=$SRC_HTTP — alert-only, no host recover under git-deploy"
	alert high "anchor-publish-health: not served (exit 2)" "$SOURCE_URL returned HTTP=$SRC_HTTP — not served. Alert-only, no host recover under git-deploy."
	exit 2
fi

# ---- 2. parse dag_root_computed from the served source ----------------------
DAG_SRC="$(jq -er '.dag_root_computed // empty' "$SRC_BODY" 2>/dev/null || true)"
if ! is_hex64 "$DAG_SRC"; then
	log "ERROR served $SOURCE_URL (200) but .dag_root_computed missing/invalid — publish corrupt"
	alert high "anchor-publish-health: publish corrupt (exit 5)" "served $SOURCE_URL (200) but .dag_root_computed missing/invalid — publish corrupt."
	exit 5
fi

# ---- 3. fetch the receipt = record of the on-chain anchored root ------------
RCPT_HTTP="$(fetch "$RECEIPT_URL" "$RCPT_BODY")"
if [ "$RCPT_HTTP" != "200" ]; then
	log "WARN served $SOURCE_URL (200) but receipt $RECEIPT_URL HTTP=$RCPT_HTTP — cannot content-verify"
	alert high "anchor-publish-health: cannot content-verify (exit 4)" "served $SOURCE_URL (200) but receipt $RECEIPT_URL HTTP=$RCPT_HTTP — cannot content-verify."
	exit 4
fi

# Anchored combined DAG root: prefer the dag_root_summary action's combined memo
# `fya<S>c<N>:<hex>`, then that action's root_hex, then top-level dag_root_hash.
extract_anchored_root() {
	local f="$1" v
	v="$(jq -er 'first(.anchor.actions[]? | select(.branch=="dag_root_summary") | .memo) // empty' "$f" 2>/dev/null || true)"
	v="${v##*:}"
	if is_hex64 "$v"; then printf '%s' "$v"; return 0; fi
	v="$(jq -er 'first(.anchor.actions[]? | select(.branch=="dag_root_summary") | .root_hex) // empty' "$f" 2>/dev/null || true)"
	if is_hex64 "$v"; then printf '%s' "$v"; return 0; fi
	v="$(jq -er '.dag_root_hash // empty' "$f" 2>/dev/null || true)"
	if is_hex64 "$v"; then printf '%s' "$v"; return 0; fi
	return 1
}

DAG_ANCHORED="$(extract_anchored_root "$RCPT_BODY" || true)"
if ! is_hex64 "$DAG_ANCHORED"; then
	log "WARN served $SOURCE_URL (200) but receipt has no parseable anchored root — cannot content-verify"
	alert high "anchor-publish-health: cannot content-verify (exit 4)" "served $SOURCE_URL (200) but receipt has no parseable anchored root — cannot content-verify."
	exit 4
fi

# ---- 4. content-verify: served source must reproduce the on-chain root ------
if [ "$DAG_SRC" != "$DAG_ANCHORED" ]; then
	log "ERROR content mismatch: served anchor-source dag_root_computed=${DAG_SRC:0:12}… != on-chain anchored root=${DAG_ANCHORED:0:12}… (stale/incorrect publish)"
	alert high "anchor-publish-health: content mismatch (exit 3)" "served anchor-source dag_root_computed=${DAG_SRC:0:12}… != on-chain anchored root=${DAG_ANCHORED:0:12}… (stale/incorrect publish)."
	exit 3
fi

[ "$VERBOSE" -eq 1 ] && log "OK served + content-verified: $SOURCE_URL dag_root_computed=${DAG_SRC:0:12}… matches on-chain anchored root"
exit 0
