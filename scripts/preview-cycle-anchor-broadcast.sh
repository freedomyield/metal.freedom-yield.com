#!/usr/bin/env bash
# preview-cycle-anchor-broadcast.sh — STAGE 1 of a mainnet A-chain anchor
# broadcast, for any cycle. (Renamed from preview-cycle3-anchor-broadcast.sh,
# which hardcoded cycle 3; this version derives the cycle number from
# --source instead of assuming one.)
#
# One-shot operator preview (no automated test by design — it broadcasts
# nothing and only displays the composed transaction shape for review).
#
# COMPOSES NOTHING. It reads the anchor-source.json bytes that are ALREADY
# COMMITTED (verified against `git show HEAD:public/api/anchor-source.json`),
# generates the mainnet `--dry-run-log` (safe-broadcast gate-4 material) from
# exactly those bytes, and DISPLAYS the transaction shape a subsequent
# sign-anchor-event.sh broadcast would inscribe.
#
# WHY the no-recompose rule (2026-07-31 day-of walkthrough audit, C1/C2/C3):
# this script used to run `gen-anchor-source.sh` unconditionally before
# producing the dry-run log. `anchor-source.json`'s artifacts branch hashes
# live feeds (validator.json / evidence.json) that the 5-minute crons rewrite,
# so a recompose even MINUTES after the committed one yields a DIFFERENT
# `dag_root_computed`. The dry-run log (and therefore the tx that gets signed)
# would then diverge from the committed + published + deployed bytes that the
# receipt's `url` + `sha256` point at — silently. The whole point of step 6's
# commit/push/deploy is that the signed value equals the published value, so
# this script now REFUSES to work from anything but the committed bytes
# (override: --allow-uncommitted, for deliberate off-cycle experiments only).
#
# WHY the published-copy guard (2026-07-31 final walkthrough re-verification):
# the committed-bytes guard above ([1/5]) only proves --source matches LOCAL
# HEAD — it says nothing about whether that commit has actually been pushed
# and deployed. Running this script in the gap between "git commit" and
# "push finishes propagating" passed [1/5] while the public site still served
# the OLD anchor-source.json, so the receipt's url+sha256 would only be
# caught as wrong AFTER an irreversible broadcast (resume-after-cycle-start.sh
# exit 3, much too late). So immediately after [1/5] passes, this script ALSO
# fetches the live published copy (cache-busted — see below) and compares its
# dag_root_computed to --source; a mismatch or an unreachable site refuses
# (exit 10) rather than let the operator proceed on an unverified assumption.
# --skip-published-check bypasses this for deliberate offline/degraded use.
#
# BROADCASTS NOTHING. Invokes no `proton transaction` / real safe-broadcast
# call. Touches no operator token. Writes only a temp dry-run-log.
#
# WHERE IT RUNS: the operator's MAC, after step 6 of docs/CYCLE_GATE.md's
# runbook has committed + pushed the day's anchor-source.json. It is NOT run
# on the validator host: the §3.5 keystore guard below requires
# HOME=~/.metal-fy-proton, which a `sudo -u deploy …` host invocation cannot
# satisfy (it refuses with exit 8 against the deploy login home).
#
# STAGE 2 (the actual broadcast) is a SEPARATE, operator-authorized step
# printed at the end of this script's output, and also runs on the operator's
# Mac (sign-anchor-event.sh's real broadcast path requires the Mac-only
# signing host; see the signing-host assertion in sign-anchor-event.sh).
#
# Usage (on the operator's Mac, from the repo root):
#   FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
#     bash scripts/preview-cycle-anchor-broadcast.sh \
#       --source=public/api/anchor-source.json \
#       --testnet-tx-id=<64-hex>
#
# Args:
#   --testnet-tx-id=<64hex>  Required. The latest testnet rehearsal tx id for
#                            THIS cycle's exact memo shape (gate 1 material).
#                            No default: a stale tx id from a prior cycle
#                            would silently satisfy gate 1's Hyperion lookup
#                            without proving today's shape.
#   --source=<path>          Default: public/api/anchor-source.json (relative
#                            to $REPO). Used VERBATIM — never regenerated.
#                            The cycle number displayed below is derived from
#                            this file's
#                            observations_branch.cycle_number_observed — this
#                            script makes no assumption about which cycle is
#                            current.
#   --allow-uncommitted      Skip the committed-bytes guard ([1/5]). Only for
#                            deliberate off-cycle experiments; a real cycle
#                            broadcast must sign the committed bytes.
#   --skip-published-check   Skip the published-copy guard that runs right
#                            after [1/5] passes (fetches the LIVE public
#                            anchor-source.json and compares dag_root_computed
#                            against --source). Loud stderr warning when
#                            given. Only for deliberate offline/degraded use —
#                            a real cycle broadcast should verify the public
#                            site already serves the committed bytes.
#   --skip-compose           Accepted no-op, kept so the flag reads as an
#                            explicit statement of intent. This script never
#                            composes; there is nothing to skip.
#
# Env overrides: REPO (default: this script's own repo root), DRYLOG (default
# /tmp/fya-mainnet-dryrun.json), FY_CONFIG_DIR (default /etc/freedom-yield —
# on the Mac it MUST be set, see [3/5]); TESTNET_TX_ID and SOURCE_PATH are
# equivalent to the two flags above (flags take precedence). ANCHOR_SOURCE_URL
# (default https://metal.freedom-yield.com/api/anchor-source.json, same
# convention as scripts/check-anchor-publish-health.sh) is the published-copy
# guard's fetch target; FYD_CURL (default curl) lets tests stub that fetch —
# also the same convention as check-anchor-publish-health.sh.
#
# Exit codes:
#   0  preview complete (nothing broadcast)
#   1  usage error / unreadable --source
#   3  broadcast config dir incomplete (xpr-account / anchor-sink missing) —
#      same meaning as scripts/sign-anchor-event.sh's exit 3
#   4  the mainnet dry-run log came out empty / unparseable
#   8  keystore guard failed (§3.5)
#   9  committed-bytes guard failed — --source does not match
#      `git show HEAD:public/api/anchor-source.json`
#   10 published-copy guard failed — the live public anchor-source.json could
#      not be fetched/parsed (network unreachable / invalid JSON), or was
#      fetched fine but its dag_root_computed does not match --source (a
#      push/deploy has not finished propagating yet). --skip-published-check
#      bypasses this guard for offline/degraded use only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/require-keystore-home.sh
. "${SCRIPT_DIR}/lib/require-keystore-home.sh"

# ---- §3.5 keystore separation guard (fail-closed) ----
# Must precede this script's only proton invocation ([4/5] gate3 probe
# below, `proton chain:info`) — placed here, before anything else runs, so a
# misscoped HOME refuses before any side effect.
# Exit 8 = keystore guard failed (§3.5), by convention with bin/safe-broadcast
# and scripts/sign-anchor-event.sh, which share this same check.
require_project_keystore_home "$0" || exit 8

# ---- args ----
SOURCE_PATH="${SOURCE_PATH:-public/api/anchor-source.json}"
TESTNET_TX_ID="${TESTNET_TX_ID:-}"
ALLOW_UNCOMMITTED=0
SKIP_PUBLISHED_CHECK=0
for arg in "$@"; do
	case "$arg" in
		--source=*)        SOURCE_PATH="${arg#*=}" ;;
		--testnet-tx-id=*) TESTNET_TX_ID="${arg#*=}" ;;
		--allow-uncommitted) ALLOW_UNCOMMITTED=1 ;;
		--skip-published-check) SKIP_PUBLISHED_CHECK=1 ;;
		--skip-compose)    : ;;   # documented no-op: this script never composes
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

REPO="${REPO:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
DRYLOG="${DRYLOG:-/tmp/fya-mainnet-dryrun.json}"
EXPECTED_CHAIN_ID="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
TESTNET_HIST="https://test.proton.eosusa.io/v1/history/get_transaction"
# The single tracked path whose committed bytes are the signing contract.
CANONICAL_TRACKED_PATH="public/api/anchor-source.json"

if command -v sha256sum >/dev/null 2>&1; then
	sha256_pipe() { sha256sum | awk '{print $1}'; }
else
	sha256_pipe() { shasum -a 256 | awk '{print $1}'; }
fi

cd "$REPO"

echo "════════════════════════════════════════════════════════════════"
echo "  STAGE 1 — mainnet anchor PREVIEW  (NO broadcast, NO recompose)"
echo "════════════════════════════════════════════════════════════════"
echo "  repo:   $REPO"
echo "  source: $SOURCE_PATH  (used verbatim)"

echo
echo "── [1/5] committed-bytes guard — sign only what is already committed ──"
if [ ! -r "$SOURCE_PATH" ]; then
	echo "ERROR: --source not readable: $SOURCE_PATH (relative to $REPO)" >&2
	exit 1
fi
SRC_SHA256="$(sha256_pipe < "$SOURCE_PATH")"
echo "  source sha256:  $SRC_SHA256"

HEAD_TMP="$(mktemp -t fya-head-anchor-source.XXXXXX)"
trap 'rm -f "$HEAD_TMP"' EXIT
GUARD_STATUS=""
if ! command -v git >/dev/null 2>&1; then
	GUARD_STATUS="no-git-binary"
elif ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
	GUARD_STATUS="not-a-git-repo"
elif ! git -C "$REPO" show "HEAD:${CANONICAL_TRACKED_PATH}" > "$HEAD_TMP" 2>/dev/null; then
	GUARD_STATUS="no-head-blob"
elif cmp -s "$SOURCE_PATH" "$HEAD_TMP"; then
	GUARD_STATUS="match"
else
	GUARD_STATUS="mismatch"
fi

if [ "$GUARD_STATUS" = "match" ]; then
	echo "  ✓ byte-for-byte identical to git show HEAD:${CANONICAL_TRACKED_PATH}"
	echo "    (= the bytes step 6 committed locally. This does NOT yet prove push/deploy —"
	echo "    see the published-copy guard immediately below.)"
else
	echo "  ✗ committed-bytes guard did NOT pass: ${GUARD_STATUS}" >&2
	if [ "$GUARD_STATUS" = "mismatch" ]; then
		SRC_DAG="$(jq -r '.dag_root_computed // "?"' "$SOURCE_PATH" 2>/dev/null || echo '?')"
		HEAD_DAG="$(jq -r '.dag_root_computed // "?"' "$HEAD_TMP" 2>/dev/null || echo '?')"
		echo "      --source dag_root_computed: $SRC_DAG" >&2
		echo "      HEAD     dag_root_computed: $HEAD_DAG" >&2
		if [ "$SRC_DAG" != "$HEAD_DAG" ]; then
			echo "      The two DIFFER — signing this file would inscribe a value that the" >&2
			echo "      published anchor-source.json does not contain (silent receipt" >&2
			echo "      url/sha256 divergence). anchor-source.json's artifacts branch hashes" >&2
			echo "      live feeds that the 5-minute crons rewrite, so any recompose after" >&2
			echo "      the commit produces a different dag_root." >&2
		else
			echo "      dag_root matches but the BYTES differ (formatting/timestamp field)." >&2
			echo "      The receipt binds url+sha256 of the published bytes, so this still" >&2
			echo "      diverges from what the site serves." >&2
		fi
	fi
	echo "      Fix: commit + push + deploy the intended anchor-source.json first" >&2
	echo "      (scripts/operator-local/commit-anchor-source.sh --expect-cycle=<N+1>," >&2
	echo "      = step 6 of docs/CYCLE_GATE.md's runbook), then re-run this script." >&2
	if [ "$ALLOW_UNCOMMITTED" -eq 1 ]; then
		echo "      --allow-uncommitted given → continuing anyway. This preview is NOT" >&2
		echo "      valid material for a real cycle broadcast." >&2
	else
		echo "      (--allow-uncommitted overrides this guard for off-cycle experiments only.)" >&2
		exit 9
	fi
fi

# ---- published-copy guard (2026-07-31 walkthrough re-verification) ----
# Only meaningful once the block above proved --source == local HEAD; if that
# guard didn't pass we either already exited 9, or --allow-uncommitted was
# given (an explicitly off-cycle experiment where "does the live site serve
# this" isn't the question being asked). See the header's "WHY the
# published-copy guard" section for the full incident rationale.
if [ "$GUARD_STATUS" = "match" ]; then
	echo
	echo "── published-copy guard — the live site must already serve these committed bytes ──"
	if [ "$SKIP_PUBLISHED_CHECK" -eq 1 ]; then
		echo "  ⚠ --skip-published-check given — NOT verifying the live public copy." >&2
		echo "    Only safe for deliberate offline/degraded use; a real cycle broadcast" >&2
		echo "    should confirm the public site already serves these bytes." >&2
	else
		PUBLISHED_SOURCE_URL="${ANCHOR_SOURCE_URL:-https://metal.freedom-yield.com/api/anchor-source.json}"
		CURL_BIN="${FYD_CURL:-curl}"
		# Cache-bust: caddy/Caddyfile serves /api/*.json with
		# `Cache-Control: public, max-age=120, must-revalidate`, and the CF edge
		# in front of it now caches that response too (2026-07-17 edge-cache
		# fix), so a plain GET run right after push+deploy can still return an
		# edge-cached copy up to 2 minutes stale — exactly the silent
		# divergence this guard exists to catch. A unique query string is a
		# normal cache-key component, so it defeats the edge cache regardless
		# of either side's Cache-Control headers; the no-cache request headers
		# below are sent too, but as belt-and-suspenders only — a bare
		# `Cache-Control: no-cache` REQUEST header is not guaranteed to bypass
		# a shared/edge cache by itself.
		CACHE_BUST="$(date +%s)-$$-${RANDOM}"
		PUB_TMP="$(mktemp -t fya-published-anchor-source.XXXXXX)"
		trap 'rm -f "$HEAD_TMP" "$PUB_TMP"' EXIT
		PUB_HTTP="$("$CURL_BIN" -sS -o "$PUB_TMP" -w '%{http_code}' --max-time 15 \
			-H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
			"${PUBLISHED_SOURCE_URL}?cb=${CACHE_BUST}" 2>/dev/null || echo "000")"
		if [ "$PUB_HTTP" != "200" ]; then
			echo "  ✗ could not fetch published copy: ${PUBLISHED_SOURCE_URL} (HTTP=${PUB_HTTP})" >&2
			echo "      Network unreachable or endpoint down — refusing to guess whether the" >&2
			echo "      live site already serves the committed bytes." >&2
			echo "      Fix: check connectivity / site health and re-run, or pass" >&2
			echo "      --skip-published-check for deliberate offline/degraded use only." >&2
			exit 10
		fi
		if ! jq empty "$PUB_TMP" >/dev/null 2>&1; then
			echo "  ✗ published copy at ${PUBLISHED_SOURCE_URL} is not valid JSON" >&2
			echo "      Fix: investigate the public endpoint, then re-run." >&2
			exit 10
		fi
		PUB_DAG="$(jq -r '.dag_root_computed // empty' "$PUB_TMP" 2>/dev/null || true)"
		COMMITTED_DAG="$(jq -r '.dag_root_computed // empty' "$SOURCE_PATH" 2>/dev/null || true)"
		if [ -z "$PUB_DAG" ] || [ "$PUB_DAG" != "$COMMITTED_DAG" ]; then
			echo "  ✗ published copy does NOT match committed bytes (stale publish / propagation lag)" >&2
			echo "      committed  dag_root_computed: ${COMMITTED_DAG:-?}" >&2
			echo "      published  dag_root_computed: ${PUB_DAG:-?}" >&2
			echo "      Fix: push + deploy (docs/CYCLE_GATE.md step 6), wait for propagation" >&2
			echo "      (the /api/*.json edge cache is up to 120s), then re-run this script." >&2
			echo "      (--skip-published-check overrides this guard for offline/degraded use only.)" >&2
			exit 10
		fi
		echo "  ✓ published copy matches committed bytes — the receipt's url+sha256 will agree"
	fi
fi

echo
echo "── [2/5] values to be inscribed (read from the file above, not recomposed) ──"
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
# sign-anchor-event.sh reads xpr-account / anchor-sink / xpr-quantity from
# ${FY_CONFIG_DIR:-/etc/freedom-yield}. On the Mac that default does not
# exist, and without FY_CONFIG_DIR the child exits 3 — which, under the old
# `> "$DRYLOG"` redirect, left a 0-byte dry-run log that only failed much
# later at gate 4 (2026-07-31 audit, C1). Check up front instead.
CONFIG_DIR="${FY_CONFIG_DIR:-/etc/freedom-yield}"
echo "  config dir: $CONFIG_DIR"
MISSING_CFG=""
for f in xpr-account anchor-sink; do
	[ -r "${CONFIG_DIR}/${f}" ] || MISSING_CFG="${MISSING_CFG} ${f}"
done
if [ -n "$MISSING_CFG" ]; then
	echo "ERROR: broadcast config incomplete in ${CONFIG_DIR} — missing:${MISSING_CFG}" >&2
	echo "       Re-invoke with the mainnet config dir, e.g.:" >&2
	echo "         FY_CONFIG_DIR=\$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \\" >&2
	echo "           bash scripts/preview-cycle-anchor-broadcast.sh --source=${SOURCE_PATH} --testnet-tx-id=${TESTNET_TX_ID}" >&2
	echo "       (FY_CONFIG_DIR must come BEFORE HOME= on that line — see docs/CYCLE_GATE.md step 7.)" >&2
	exit 3
fi
bash scripts/sign-anchor-event.sh --chain=mainnet-a --anchor-source="$SOURCE_PATH" --dry-run > "$DRYLOG"
if [ ! -s "$DRYLOG" ] || ! jq -e '.tx' "$DRYLOG" >/dev/null 2>&1; then
	echo "ERROR: dry-run log is empty or has no .tx: $DRYLOG ($(wc -c < "$DRYLOG" | tr -d ' ') bytes)" >&2
	echo "       Refusing to hand an unusable file to safe-broadcast's gate 4." >&2
	exit 4
fi
echo "  ✓ dry-run-log written: $DRYLOG ($(wc -c < "$DRYLOG" | tr -d ' ') bytes)"
echo "  ── EXACT memos to be inscribed (expect 4: ${PREFIX}-{id,ob,ar} + ${PREFIX}) ──"
jq -r '.tx.actions[] | "    memo=\(.data.memo // "?")"' "$DRYLOG" 2>/dev/null || cat "$DRYLOG"
MEMOS=$(jq -r '.tx.actions[] | .data.memo // empty' "$DRYLOG" 2>/dev/null | grep -c '^fya' || true)
echo "  memo count (expect 4): ${MEMOS:-?}"
# Read authorization off the ACTION objects (`.tx.actions[]`), not off a
# recursive `select(has("memo"))` — `memo` lives inside `.data`, so the old
# recursive form only ever matched the data objects and printed "?@?" for
# actor@permission. Gate 2 requires the operator to NAME actor+permission, so
# this line has to show the real values.
echo "  ── recipients / auth (expect: metalfreedom@anchor → fyhistory, 0.0001 XPR ×4) ──"
jq -r '.tx.actions[] |
  "    \(.authorization[0].actor // "?")@\(.authorization[0].permission // "?") → \(.data.to // "?")  \(.data.quantity // "?")"' \
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
# Both blocks below run on the OPERATOR'S MAC — the same machine this script
# ran on: sign-anchor-event.sh's real (non-dry-run) broadcast path enforces a
# signing-host assertion (exit 7 anywhere but the Mac) because the anchor key
# never leaves the Mac. Since [1/5] proved $SOURCE_PATH equals the committed
# bytes, STAGE 2 signs exactly what this preview displayed.
TOKEN_TX_SHA256="$(jq -c .tx "$DRYLOG" | sha256_pipe)"
echo "  token tx_sha256 (binds to THIS exact tx): $TOKEN_TX_SHA256"
cat <<CMD
    printf '{"chain":"mainnet-a","tx_sha256":"%s"}' "$TOKEN_TX_SHA256" > /tmp/fyd-broadcast-token
                                             # gate-2/2b (R16), valid 5 min (300s TTL) from now.
                                             # chain+tx-bound; a bare touch is REFUSED for mainnet.
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
echo "════ STAGE 1 complete. NOTHING was broadcast, NOTHING was recomposed. ════"
