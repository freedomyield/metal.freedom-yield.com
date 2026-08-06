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
# Fetch retries (D1): fetch() retries each GET up to FYD_FETCH_ATTEMPTS times
#   (default 3), breaking as soon as an attempt returns HTTP 200, with a
#   FYD_RETRY_SLEEP-second pause (default 3) between attempts — see Env
#   overrides below. Added 2026-07-16 after a single cross-region connection
#   blip between the validator host and the public Xserver/CF origin
#   (HTTP=000) rang the operator's phone at 16:00 UTC on 2026-07-15 even
#   though the 15:45 and 16:15 ticks either side were both fine — a
#   retry-less single curl cannot tell a transient network hiccup from a real
#   outage. The retry lives inside fetch() so it covers BOTH GETs (source:
#   exit-2 path; receipt: exit-4 path). It does NOT soften exit 3 (content
#   mismatch): that comparison only runs after a 200 has already been
#   obtained, so a stale publish is never masked by the retry loop.
#
# Log path (D2): the default $ANCHOR_PUBLISH_HEALTH_LOG target is repo-local
#   (${SCRIPT_DIR}/../logs/anchor-publish-health.log), not /var/log. On the
#   validator host /var/log is NOT writable by the `deploy` user this cron
#   runs as, so a /var/log default silently no-ops the file log forever (the
#   `[ -w ]` guard in log() below always fails) while still looking
#   configured. The repo-local logs/ dir is provisioned deploy:deploy by
#   scripts/install-host-log-dir.sh, matching every other project cron.
#
# Exit-3 alert dedup (D3): a content mismatch (exit 3) is a NORMAL,
#   guaranteed transient state during a cycle transition — the new
#   anchor-source.json publishes before the matching receipt does, so every
#   15-minute tick in that window mismatches until the receipt catches up.
#   Alerting `high` on every one of those ticks is alert fatigue (a real
#   anomaly gets lost in a run of expected pages). So: the mismatch's
#   SIGNATURE (served dag_root_computed + on-chain anchored root, the exact
#   pair compared above) is persisted to $ANCHOR_PUBLISH_HEALTH_MISMATCH_STATE
#   on the FIRST alert for that signature; repeat mismatches with the SAME
#   signature within $ANCHOR_PUBLISH_HEALTH_MISMATCH_SUPPRESS_SEC (default
#   21600s = 6h) are logged but do NOT re-fire notify.sh. A signature change
#   (the mismatch resolved to a DIFFERENT stale/incorrect pair) or the window
#   elapsing re-arms immediate alerting. On recovery (exit 0) the state is
#   cleared, so the next mismatch — even an identical signature recurring
#   later — alerts immediately again. The exit code (3) and the log line are
#   UNCHANGED on every tick; only the notify.sh call is gated. State-write
#   failures are logged (WARN) but never escalate the exit code (matches the
#   existing alert()/notify.sh best-effort contract below). Every input that
#   feeds the dedup decision fails OPEN (toward alerting), never silently
#   toward suppression: an unreadable/unparseable state file, a corrupted
#   window_started_epoch (non-numeric OR in the future — the latter would
#   otherwise make the elapsed-window arithmetic negative and suppress
#   forever), and a non-numeric $ANCHOR_PUBLISH_HEALTH_MISMATCH_SUPPRESS_SEC
#   all bypass suppression and alert immediately instead.
#
# Exit codes:
#   0  served AND dag_root_computed matches the anchored root (verbose: heartbeat)
#   2  anchor-source.json not served (HTTP != 200 on every retry attempt) —
#      alert, no recover
#   3  served but dag_root_computed MISMATCHES the anchored root (stale publish)
#   4  served but the receipt could not be fetched/parsed after retrying
#      (cannot content-verify)
#   5  served but anchor-source.json is unparseable / missing dag_root_computed
#      (or jq is unavailable)
#
# Logging:
#   Every non-OK event is written to stderr (for cron mail) and, when the path
#   is writable, appended to $ANCHOR_PUBLISH_HEALTH_LOG (default: repo-local
#   ${SCRIPT_DIR}/../logs/anchor-publish-health.log — see "Log path (D2)"
#   above) for later audit.
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
#   FY_LIVE=1           REQUIRED before an alert reaches ntfy AND before the
#                       exit-3 dedup state is written or cleared. Anything else
#                       is a loud dry no-op printing one "DRY: would …" line
#                       per suppressed effect (scripts/lib/side-effects.sh, C3
#                       rollout 2026-08-06). The metal-anchor-publish-health
#                       cron env header carries it; tests deliberately do not.
#
#                       The alert and the dedup state are gated TOGETHER on
#                       purpose. mismatch_state_write() records "the operator
#                       has been told about this signature"; if it ran while
#                       the send was suppressed, the mismatch would go
#                       unreported for the whole 6h window AFTER the cron got
#                       its FY_LIVE back. That is the exact hazard the
#                       CONTRACT section of scripts/lib/side-effects.sh names.
#
#                       NOT gated: the verdict, the exit code, and the file
#                       log. This checker's job is to detect, and a dry tick
#                       must still detect, still exit 2/3/4/5, and still leave
#                       an audit line behind.
#   FYD_NOTIFY          notifier to invoke (default: <script dir>/notify.sh).
#                       Resolved by scripts/lib/side-effects.sh, not here.
#   FYD_FETCH_ATTEMPTS  max attempts per fetch() call before giving up
#                       (default 3)
#   FYD_RETRY_SLEEP     seconds to pause between fetch() retry attempts
#                       (default 3; tests set 0 so the suite never sleeps)
#   ANCHOR_PUBLISH_HEALTH_LOG  file-log target (default: repo-local
#                       ${SCRIPT_DIR}/../logs/anchor-publish-health.log)
#   ANCHOR_PUBLISH_HEALTH_MISMATCH_STATE  exit-3 dedup state file (default:
#                       repo-local ${SCRIPT_DIR}/../logs/anchor-publish-health-mismatch-state.json;
#                       see "Exit-3 alert dedup (D3)" above)
#   ANCHOR_PUBLISH_HEALTH_MISMATCH_SUPPRESS_SEC  dedup window in seconds
#                       (default 21600 = 6h)
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
FYD_LIB="${SCRIPT_DIR}/lib/side-effects.sh"
if [ ! -r "$FYD_LIB" ]; then
	printf 'check-anchor-publish-health: FATAL: side-effects library not readable at %s\n' "$FYD_LIB" >&2
	exit 6
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

SOURCE_URL="${ANCHOR_SOURCE_URL:-https://metal.freedom-yield.com/api/anchor-source.json}"
RECEIPT_URL="${ANCHOR_RECEIPT_URL:-https://metal.freedom-yield.com/api/anchor-receipt.json}"
LOG="${ANCHOR_PUBLISH_HEALTH_LOG:-${SCRIPT_DIR}/../logs/anchor-publish-health.log}"
MISMATCH_STATE="${ANCHOR_PUBLISH_HEALTH_MISMATCH_STATE:-${SCRIPT_DIR}/../logs/anchor-publish-health-mismatch-state.json}"
MISMATCH_SUPPRESS_SEC="${ANCHOR_PUBLISH_HEALTH_MISMATCH_SUPPRESS_SEC:-21600}"
CURL="${FYD_CURL:-curl}"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Portable epoch -> ISO 8601 UTC (GNU `date -d @epoch` vs BSD `date -r epoch`;
# same shim shape as scripts/gen-anchor-source.sh's iso_utc_of_epoch). Only
# used for the mismatch-dedup state file's human-readable timestamp field —
# never for the dedup DECISION itself, which compares raw epoch integers.
if date --version >/dev/null 2>&1; then
	iso_utc_of_epoch() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }
else
	iso_utc_of_epoch() { date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ"; }
fi

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
	#
	# Delivery is gated on FY_LIVE by fyd_notify; the delegate is resolved
	# from FYD_NOTIFY exactly as before. A failure (including "delegate not
	# readable", which used to be this function's own branch) is logged and
	# swallowed — a checker must never die because its alert channel is down.
	fyd_notify "$1" "$2" "$3" || log "WARN: notify failed (alert was: $2 — $3)"
}

is_hex64() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# ---- exit-3 alert dedup (D3) -------------------------------------------
# See "Exit-3 alert dedup (D3)" in the header comment for full rationale.
# State shape ($MISMATCH_STATE, JSON):
#   { "signature": "<dag_src>:<dag_anchored>",
#     "window_started_epoch": <int>, "window_started_at": "<ISO8601>",
#     "suppress_window_sec": <int> }

# mismatch_should_alert <signature> -> prints "1" (alert now) or "0"
# (suppress). Alerts whenever there is no prior state, the prior state is
# unreadable/unparseable (fail-open toward alerting — a dedup bug must never
# silence a real content-mismatch page), the signature differs from the
# stored one, the stored window has elapsed, OR either input feeding the
# window-elapsed arithmetic is untrustworthy:
#   - $MISMATCH_SUPPRESS_SEC (env-configured) is non-numeric — an invalid
#     config must not become an accidental "never re-alert" mode.
#   - the persisted window_started_epoch is not a plain non-negative
#     integer, OR is in the FUTURE relative to now (a corrupted/tampered
#     state file) — without this clamp, a future epoch makes
#     `now_epoch - prev_epoch` negative, which can never reach the
#     (positive) suppress threshold, so the mismatch would be suppressed
#     forever (fail toward silence — exactly what this guard must not do).
mismatch_should_alert() {
	local sig="$1" now_epoch prev_sig prev_epoch
	now_epoch="$(date -u +%s)"
	if [ ! -r "$MISMATCH_STATE" ]; then
		printf '1'
		return 0
	fi
	if ! [[ "$MISMATCH_SUPPRESS_SEC" =~ ^[0-9]+$ ]]; then
		printf '1'
		return 0
	fi
	prev_sig="$(jq -r '.signature // empty' "$MISMATCH_STATE" 2>/dev/null || true)"
	prev_epoch="$(jq -r '.window_started_epoch // 0' "$MISMATCH_STATE" 2>/dev/null || echo 0)"
	[[ "$prev_epoch" =~ ^[0-9]+$ ]] || prev_epoch=0
	[ "$prev_epoch" -le "$now_epoch" ] || prev_epoch=0
	if [ -z "$prev_sig" ] || [ "$prev_sig" != "$sig" ]; then
		printf '1'
		return 0
	fi
	if [ $((now_epoch - prev_epoch)) -ge "$MISMATCH_SUPPRESS_SEC" ]; then
		printf '1'
		return 0
	fi
	printf '0'
}

# mismatch_state_write <signature> — persists the signature + a fresh window
# start (= "now"). Called only when an alert actually fires (new signature OR
# window elapsed), so the suppress window always measures from the most
# recent alert, not the first-ever one. Best-effort: failure is logged (WARN)
# but never changes the caller's exit code (matches alert()'s contract).
#
# Gated on FY_LIVE in lock step with the alert it records. The WHOLE body is
# gated (not just the final rename) because the body also mkdir's and mktemp's
# in the log directory, and a dry tick must leave no stray
# .anchor-publish-health-mismatch.XXXXXX behind. See the FY_LIVE block in the
# header for why writing this record while the send is suppressed is worse
# than doing nothing.
mismatch_state_write() {
	fyd_live_run "record the exit-3 mismatch dedup window in ${MISMATCH_STATE}" \
		mismatch_state_write_live "$1"
}
mismatch_state_write_live() {
	# FYD-GATE(branch): reached only through the fyd_live_run above.
	local sig="$1" now_epoch now_iso dir tmp
	now_epoch="$(date -u +%s)"
	now_iso="$(iso_utc_of_epoch "$now_epoch" 2>/dev/null || printf '%s' "$NOW_ISO")"
	dir="$(dirname "$MISMATCH_STATE")"
	mkdir -p "$dir" 2>/dev/null || true
	if [ ! -w "$dir" ] 2>/dev/null; then
		log "WARN: mismatch-dedup state dir not writable: $dir (state not persisted; next tick will re-alert)"
		return 1
	fi
	tmp="$(mktemp -p "$dir" .anchor-publish-health-mismatch.XXXXXX 2>/dev/null)" || {
		log "WARN: mktemp failed for mismatch-dedup state in $dir (state not persisted; next tick will re-alert)"
		return 1
	}
	if ! jq -n --arg sig "$sig" --argjson epoch "$now_epoch" --arg iso "$now_iso" \
		--argjson win "$MISMATCH_SUPPRESS_SEC" \
		'{signature: $sig, window_started_epoch: $epoch, window_started_at: $iso, suppress_window_sec: $win}' \
		> "$tmp" 2>/dev/null; then
		rm -f "$tmp"
		log "WARN: jq compose failed for mismatch-dedup state (state not persisted; next tick will re-alert)"
		return 1
	fi
	# FYD-GATE(branch): body of mismatch_state_write_live — see the wrapper.
	if ! mv "$tmp" "$MISMATCH_STATE" 2>/dev/null; then
		rm -f "$tmp"
		log "WARN: rename failed writing mismatch-dedup state to $MISMATCH_STATE (state not persisted; next tick will re-alert)"
		return 1
	fi
	return 0
}

# mismatch_state_clear — called on recovery (exit 0) so a later mismatch,
# even one that reproduces the exact same signature, alerts immediately
# rather than being suppressed by a stale window from before the recovery.
#
# Gated for symmetry with mismatch_state_write: a dry tick must not mutate the
# dedup ledger in EITHER direction. (Clearing is the safe direction — it can
# only cause an extra alert, never a missed one — but a dry run that silently
# rearms production state is still a dry run with a side effect.)
# The `2>/dev/null` the old body carried is gone on purpose: attached to
# fyd_live_run it would have swallowed the "DRY: would …" line this rollout
# exists to make visible. `rm -f` is already silent for a missing file, so the
# only output it can now produce is a real permission problem worth seeing,
# and `|| true` keeps that non-fatal exactly as before.
mismatch_state_clear() {
	fyd_live_run "clear the exit-3 mismatch dedup state ${MISMATCH_STATE}" rm -f "$MISMATCH_STATE" || true
}

# fetch <url> <body_outfile> -> prints the HTTP status code (000 on failure).
# Retries up to FYD_FETCH_ATTEMPTS times (default 3), stopping as soon as an
# attempt returns 200 (one success == healthy, no alarm for a transient
# blip). Sleeps FYD_RETRY_SLEEP seconds (default 3; tests use 0) between
# attempts, never after the last one. Contract unchanged for callers: prints
# exactly the FINAL attempt's HTTP status code, and the outfile holds the
# FINAL attempt's body.
fetch() {
	local url="$1" outfile="$2"
	local attempts="${FYD_FETCH_ATTEMPTS:-3}"
	local sleep_s="${FYD_RETRY_SLEEP:-3}"
	local attempt=1 code
	while :; do
		code="$("$CURL" -sS -o "$outfile" -w "%{http_code}" --max-time 15 "$url" 2>/dev/null || echo "000")"
		[ "$code" = "200" ] && break
		[ "$attempt" -ge "$attempts" ] && break
		sleep "$sleep_s"
		attempt=$((attempt + 1))
	done
	printf '%s' "$code"
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
	# D3 dedup: the exit code and the log line above are unconditional on
	# every tick — only the notify.sh call is gated on signature+window.
	MISMATCH_SIG="${DAG_SRC}:${DAG_ANCHORED}"
	if [ "$(mismatch_should_alert "$MISMATCH_SIG")" = "1" ]; then
		alert high "anchor-publish-health: content mismatch (exit 3)" "served anchor-source dag_root_computed=${DAG_SRC:0:12}… != on-chain anchored root=${DAG_ANCHORED:0:12}… (stale/incorrect publish)."
		mismatch_state_write "$MISMATCH_SIG"
	else
		log "INFO alert suppressed (exit 3 dedup): same mismatch signature already alerted within the last ${MISMATCH_SUPPRESS_SEC}s — set ANCHOR_PUBLISH_HEALTH_MISMATCH_SUPPRESS_SEC to override"
	fi
	exit 3
fi

# Recovery: clear any dedup state so a LATER mismatch — even one that
# reproduces the exact same signature — alerts immediately rather than
# being suppressed by a stale pre-recovery window.
mismatch_state_clear
[ "$VERBOSE" -eq 1 ] && log "OK served + content-verified: $SOURCE_URL dag_root_computed=${DAG_SRC:0:12}… matches on-chain anchored root"
exit 0
