#!/usr/bin/env bash
# check-pulsevm-upstream.sh — watch the PulseVM upstream for the handful of
# changes that would actually oblige this project to act, and stay silent
# otherwise.
#
# CHAIN: none — four read-only HTTP GETs against public third-party URLs. No
#        broadcast, no push, no signing, no chain RPC of any kind.
# PRIME_DIRECTIVE: TESTNET-FIRST — this script has no broadcast pathway.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# PulseVM is a metalgo VM plugin that runs the Antelope execution model on
# Avalanche Snowman as a Metal subnet. Its documentation site states that
# A-Chain — the chain this project anchors its cycle receipts to — is to be
# rebuilt on it. If that happens, two things in this repo break at once:
#
#   * bin/safe-broadcast's gate 1 takes its testnet evidence from
#     /v1/history/get_transaction (:266) and gate 3 reads `proton chain:info`
#     (:549). The rebooted A-Chain Alpine testnet offers neither route: its
#     own endpoints page states the Antelope-style /v1/chain REST "is not
#     currently exposed" and directs history reads to the Hyperion /v2 API
#     instead. A permanently-failing gate 1 is a permanent `exit 3`, which
#     under the Prime Directive means mainnet anchoring stops being possible
#     at all.
#   * the public verification story survives, because
#     scripts/gen-anchor-receipt.sh already prefers Hyperion /v2 (:160) and
#     the chain_id is already externalised into FYD_*_CHAIN_ID (:147-150).
#
# The migration has no published date. As surveyed on 2026-08-17, Metallicus's
# own properties (metallicus.com, metalblockchain.org,
# docs.metalblockchain.org, xprnetwork.org) do not mention PulseVM at all, and
# the only place the A-Chain claim is written down is the community-run
# pulsevm.dev docs site — see docs/STRATEGIC_TARGET_ALIGNMENT.md "What PulseVM
# changed" for that survey and which parts of it were re-measured directly.
# So there is nothing to build against yet — only something to WATCH. This
# script is that watch, and its entire design goal is to be silent until one
# of four specific things becomes true.
#
# ---------------------------------------------------------------------------
# WHAT IT READS (four sources — none of them a chain RPC; see below)
# ---------------------------------------------------------------------------
#   S1  api.github.com/repos/MetalBlockchain/pulsevm/releases/latest
#         -> .tag_name                       (recorded; never notifies — see below)
#   S2  pulsevm.dev/network/endpoints.md
#         -> the "third-party node sync is not yet supported" sentence,
#            any 64-hex chain id, and whether a mainnet section exists
#   S3  a-chain-alpine-hyperion.metalblockchain.org/v2/health
#         -> head_block_num
#   S4  pulsevm.dev/llms.txt
#         -> the site's own page list
#
# NOT READ, DELIBERATELY: the Alpine RPC endpoint. It is an AvalancheGo
# per-blockchain alias URL, and scripts/broadcast-guard.sh blocks that path
# shape unconditionally — read-only queries included — because a guard that
# tries to tell a read from a write on that path is a guard with a hole in it.
# This checker therefore takes every value it needs from GitHub, the docs
# site, and Hyperion /v2, none of which carry that shape.
#
# The absence is load-bearing, not incidental, and it extends to this comment:
# THIS FILE MUST NOT CONTAIN THE LITERAL PATH PREFIX AT ALL, not even in
# prose, because the invariant is asserted by a plain grep for it in
# tests/pulsevm-upstream/test-pulsevm-upstream.sh (case 12) — a header that
# explains the rule by quoting it would fail the rule. Do not "just add a
# liveness ping", and do not paste the endpoint here as documentation.
#
# (S2's page BODY does carry that shape, in a table row this script never
# parses. Reading a document that mentions a URL is not requesting it.)
#
# ---------------------------------------------------------------------------
# WHAT IT NOTIFIES ABOUT (and what it deliberately does not)
# ---------------------------------------------------------------------------
#   T1  the "third-party node sync is not yet supported" sentence is GONE
#         from S2 -> we can stand up our own node. The single most important
#         signal here, because it converts "watch" into "act".
#   T2  S2 grew a mainnet section, or shows a chain id we have not seen
#         before -> either the migration landed, or Alpine reset again (the
#         page says resets change the chain id, and warns to expect more).
#         The alert names which of the two sub-conditions fired.
#   T3  S4's page list grew -> the site publishes migration/validator pages
#         before anything else changes, so a new page is the earliest warning
#         available.
#   T4  S3's head block advanced by at least $PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA
#         since the last run -> Alpine started producing blocks for real.
#
#   BASELINE  no usable prior state -> fires once, says exactly that, and
#         records a baseline. See "fail open" below.
#
# NOT notified: a new release tag. Releases land roughly weekly and mean
# nothing on their own; the tag is written to the log and to the state file
# so it is there when a real trigger needs context. (This is the plan's
# explicit call, and it is what keeps a daily cron at zero pages in steady
# state — see the operator's standing "no false urgency" rule.)
#
# NOT notified either: a single failed fetch. See "Fetch failures" below.
#
# ---------------------------------------------------------------------------
# FAIL OPEN, TOWARD ALERTING
# ---------------------------------------------------------------------------
# Detection is a diff against $PULSEVM_UPSTREAM_STATE. A missing, unreadable,
# or unparseable state file therefore leaves the diff undefined — and an
# undefined diff must never resolve to silence, because "the state file got
# corrupted six months ago" and "nothing has changed" would then look
# identical from the outside. So:
#
#   * no usable prior state  -> the run FIRES (exit 3) with reason BASELINE.
#   * T1 and T2 are additionally evaluated from the CURRENT observation alone
#     whenever they can be (the sync notice being absent right now, or a
#     mainnet section existing right now, are facts that need no history), so
#     a first run against an already-changed upstream reports the real
#     condition rather than only "baseline recorded".
#   * T3 and T4 are pure diffs and cannot be evaluated without history. They
#     are reported as DEFERRED in the message rather than claimed as fired —
#     firing is the safe direction, but SAYING something fired when nothing
#     was compared is a fabricated claim, and this repo does not make those.
#
# The first run of a fresh install is therefore expected to page once and
# then go quiet. That is the intended behaviour, not a defect.
#
# ---------------------------------------------------------------------------
# FETCH FAILURES (exit 4 / 5) — one page per outage, not one per day
# ---------------------------------------------------------------------------
# Two of the four sources are someone else's property: a community developer's
# Vercel deployment and GitHub's unauthenticated API (60 requests/hour per IP,
# which answers 403 — not 429 — when exhausted). Paging the operator every
# time a third party has a bad morning is precisely the false urgency that
# makes a real alert invisible. Going permanently quiet because a URL moved is
# worse.
#
# So a failed run increments `consecutive_failures` in the state file and
# alerts ONCE, at `default` priority, on the exact run where the counter
# REACHES $PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER (default 3 = three days on the
# daily cron). Equality, not `-ge`: a week-long outage pages on day three and
# then stops. Any successful run resets the counter to 0, which re-arms that
# single page for the next distinct outage.
#
# In dry mode (no FY_LIVE=1) the counter is not persisted, so this escalation
# is a live-cron behaviour only — consistent with every other side effect
# here, and stated so the reader does not expect a test to observe it without
# setting FY_LIVE=1 and a sandbox state path.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  all four sources read, nothing fired (verbose: one heartbeat line)
#   3  at least one trigger fired (T1 / T2 / T3 / T4 / BASELINE) — alerts
#   4  a source did not return HTTP 200 after retrying
#   5  a source returned 200 but its body could not be parsed (or jq is absent)
#   6  scripts/lib/side-effects.sh is missing/unreadable
#
# There is deliberately no 64 here. scripts/lib/side-effects.sh returns 64 for
# "you called me wrong", but every call site in this file either swallows it
# (alert(), by contract — a watch must not die because its alert channel is
# down) or ignores it (state_write, whose failure is a logged WARN and never
# an exit code, matching check-anchor-publish-health.sh's best-effort state
# contract). So 64 cannot reach the caller, and listing it would describe a
# path that does not exist.
#
# ---------------------------------------------------------------------------
# ENV OVERRIDES
# ---------------------------------------------------------------------------
#   FY_LIVE=1   REQUIRED for the ntfy push, for the state write, AND for the
#               file log. The cron env header carries it; tests deliberately
#               do not.
#
#               The file log is gated here, which differs from
#               scripts/check-anchor-publish-health.sh (where the log is
#               deliberately NOT gated). The reason for the difference: that
#               checker's log is an audit trail of OUR published state, so a
#               dry tick still owes the record. This one's log is a diary of a
#               third party's website, the state file it would sit beside in
#               logs/ is gated anyway, and the requirement for this task is
#               that a dry run leave logs/ byte-identical. Visibility is not
#               lost: every line still goes to stderr, the installed cron
#               pipes stderr to `logger`, and the first suppressed write emits
#               one "DRY: would ..." line naming the log path.
#
#   FYD_NOTIFY            notifier delegate (resolved by side-effects.sh)
#   FYD_CURL              curl binary (tests point this at a stub)
#   FYD_FETCH_ATTEMPTS    max attempts per fetch (default 3)
#   FYD_RETRY_SLEEP       seconds between attempts (default 3; tests set 0)
#
#   PULSEVM_UPSTREAM_LOG        file log (default: repo-local
#                               ${SCRIPT_DIR}/../logs/pulsevm-upstream.log —
#                               /var/log is not deploy-writable on the host)
#   PULSEVM_UPSTREAM_STATE      state file (default: repo-local
#                               ${SCRIPT_DIR}/../logs/pulsevm-upstream-state.json)
#   PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA   T4 threshold (default 1000). A chain
#                               producing even one block a minute advances
#                               1440 in a day; a stalled one advances 0
#                               (Alpine's head block was 3406 across repeated
#                               samples on 2026-08-17). 1000 sits below the
#                               one-per-minute floor and far above the handful
#                               of blocks a manual poke produces.
#   PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER  consecutive failures before the one
#                               outage page (default 3)
#   PULSEVM_UPSTREAM_SYNC_NOTICE_RE  ERE for the T1 sentence (default
#                               'third-party node sync is not yet supported',
#                               matched case-insensitively). Any rewording
#                               upstream makes this stop matching and T1 fire
#                               — a false page in the SAFE direction. Adjust
#                               the override rather than widening the default
#                               to something that would also match a reworded
#                               "now supported".
#   PULSEVM_RELEASES_URL / PULSEVM_ENDPOINTS_URL / PULSEVM_HEALTH_URL /
#   PULSEVM_LLMS_URL      source URLs (tests point these at a stub)
#
# Usage:
#   bash scripts/check-pulsevm-upstream.sh [--verbose]
#
# Cron target (/etc/cron.d/metal-pulsevm-watch), daily — see
# scripts/install-metal-pulsevm-watch-cron.sh.

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
	printf 'check-pulsevm-upstream: FATAL: side-effects library not readable at %s\n' "$FYD_LIB" >&2
	exit 6
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

RELEASES_URL="${PULSEVM_RELEASES_URL:-https://api.github.com/repos/MetalBlockchain/pulsevm/releases/latest}"
ENDPOINTS_URL="${PULSEVM_ENDPOINTS_URL:-https://pulsevm.dev/network/endpoints.md}"
HEALTH_URL="${PULSEVM_HEALTH_URL:-https://a-chain-alpine-hyperion.metalblockchain.org/v2/health}"
LLMS_URL="${PULSEVM_LLMS_URL:-https://pulsevm.dev/llms.txt}"

LOG="${PULSEVM_UPSTREAM_LOG:-${SCRIPT_DIR}/../logs/pulsevm-upstream.log}"
STATE="${PULSEVM_UPSTREAM_STATE:-${SCRIPT_DIR}/../logs/pulsevm-upstream-state.json}"
HEAD_BLOCK_DELTA="${PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA:-1000}"
FAILURE_ALERT_AFTER="${PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER:-3}"
SYNC_NOTICE_RE="${PULSEVM_UPSTREAM_SYNC_NOTICE_RE:-third-party node sync is not yet supported}"

CURL="${FYD_CURL:-curl}"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# A non-numeric threshold must not become an accidental "never fire" (T4) or
# "never page" (outage escalation). Both fall back to their documented
# defaults, loudly, rather than being carried into arithmetic that would
# error and be read as false.
if ! [[ "$HEAD_BLOCK_DELTA" =~ ^[0-9]+$ ]]; then
	printf '%s WARN PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA=%s is not a non-negative integer — using 1000\n' "$NOW_ISO" "$HEAD_BLOCK_DELTA" >&2
	HEAD_BLOCK_DELTA=1000
fi
if ! [[ "$FAILURE_ALERT_AFTER" =~ ^[0-9]+$ ]]; then
	printf '%s WARN PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER=%s is not a non-negative integer — using 3\n' "$NOW_ISO" "$FAILURE_ALERT_AFTER" >&2
	FAILURE_ALERT_AFTER=3
fi

# ---- logging -------------------------------------------------------------
# stderr always (cron pipes it to logger); the file log only when live. The
# latch makes the suppression visible exactly once per run instead of once
# per line.
LOG_DRY_NOTED=0
log() {
	printf '%s %s\n' "$NOW_ISO" "$*" >&2
	if ! fyd_is_live; then
		if [ "$LOG_DRY_NOTED" -eq 0 ]; then
			LOG_DRY_NOTED=1
			fyd_dry_note "append this run's lines to ${LOG} (stderr above carries them regardless)"
		fi
		return 0
	fi
	if [ -w "$(dirname "$LOG")" ] 2>/dev/null || [ -w "$LOG" ] 2>/dev/null; then
		printf '%s %s\n' "$NOW_ISO" "$*" >> "$LOG" 2>/dev/null || true
	fi
}

alert() {
	# alert <priority> <title> <message> — best-effort; a notify failure is
	# logged and never changes the caller's exit code. A watch that dies
	# because its alert channel is down has stopped watching.
	fyd_notify "$1" "$2" "$3" || log "WARN: notify failed (alert was: $2 — $3)"
}

if ! command -v jq >/dev/null 2>&1; then
	log "ERROR jq not found — cannot parse any upstream source"
	exit 5
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pulsevm-upstream.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---- prior state (read BEFORE fetching, so a failure path can carry the
# previous observations forward instead of erasing the baseline) -----------
PREV_OK=0
PREV_CONSEC=0
PREV_OBS='null'
PREV_TAG=""
PREV_SYNC_NOTICE=""
PREV_MAINNET=""
PREV_HEAD=""
if [ -r "$STATE" ] && jq -e '.schema_version == 1' "$STATE" >/dev/null 2>&1; then
	PREV_CONSEC="$(jq -r '.consecutive_failures // 0' "$STATE" 2>/dev/null || echo 0)"
	[[ "$PREV_CONSEC" =~ ^[0-9]+$ ]] || PREV_CONSEC=0
	# The whole observations object must be USABLE, not merely present: every
	# field a trigger reads is type-checked here, so a truncated or
	# hand-edited record re-baselines (fail open) instead of being read
	# field-by-field with silent fallbacks. A `// empty` fallback would be
	# actively wrong for the two booleans — in jq, `false // empty` yields
	# EMPTY, so a legitimately-false flag would be indistinguishable from a
	# missing one and T1/T2 would never see their "was it true yesterday"
	# transition. That bug shipped in the first draft of this file and was
	# caught by the T2a case; hence `tostring` below, and this gate.
	if jq -e '.observations | type == "object"
	          and (.sync_notice_present | type) == "boolean"
	          and (.mainnet_section_present | type) == "boolean"
	          and (.head_block | type) == "number"' "$STATE" >/dev/null 2>&1; then
		PREV_OK=1
		PREV_OBS="$(jq -c '.observations' "$STATE" 2>/dev/null || echo 'null')"
		PREV_TAG="$(jq -r '.observations.release_tag // empty' "$STATE" 2>/dev/null || true)"
		PREV_SYNC_NOTICE="$(jq -r '.observations.sync_notice_present | tostring' "$STATE" 2>/dev/null || true)"
		PREV_MAINNET="$(jq -r '.observations.mainnet_section_present | tostring' "$STATE" 2>/dev/null || true)"
		PREV_HEAD="$(jq -r '.observations.head_block | tostring' "$STATE" 2>/dev/null || true)"
		jq -r '.observations.chain_ids[]? // empty' "$STATE" 2>/dev/null | sort -u > "$TMP/prev_chain_ids" || true
		jq -r '.observations.pages[]? // empty'     "$STATE" 2>/dev/null | sort -u > "$TMP/prev_pages"     || true
	fi
fi
[ -f "$TMP/prev_chain_ids" ] || : > "$TMP/prev_chain_ids"
[ -f "$TMP/prev_pages" ]     || : > "$TMP/prev_pages"

# ---- state writes (whole body gated: a dry run leaves no temp file either) -
state_write() {
	# state_write <observations-json-or-null> <consecutive_failures>
	fyd_live_run "record the pulsevm upstream state in ${STATE}" state_write_live "$1" "$2"
}
state_write_live() {
	# FYD-GATE(branch): reached only through the fyd_live_run above.
	local obs="$1" consec="$2" dir tmp
	dir="$(dirname "$STATE")"
	mkdir -p "$dir" 2>/dev/null || true
	if [ ! -w "$dir" ] 2>/dev/null; then
		log "WARN: state dir not writable: $dir (state not persisted; the next run will re-baseline)"
		return 1
	fi
	tmp="$(mktemp "${dir}/.pulsevm-upstream.XXXXXX" 2>/dev/null)" || {
		log "WARN: mktemp failed for the state file in $dir (state not persisted; the next run will re-baseline)"
		return 1
	}
	if ! jq -n --arg iso "$NOW_ISO" --argjson consec "$consec" --argjson obs "$obs" \
		'{schema_version: 1, checked_at: $iso, consecutive_failures: $consec, observations: $obs}' \
		> "$tmp" 2>/dev/null; then
		rm -f "$tmp"
		log "WARN: jq compose failed for the state file (state not persisted; the next run will re-baseline)"
		return 1
	fi
	if ! mv "$tmp" "$STATE" 2>/dev/null; then
		rm -f "$tmp"
		log "WARN: rename failed writing the state file to $STATE (state not persisted; the next run will re-baseline)"
		return 1
	fi
	return 0
}

# fail_and_exit <rc> <summary> — the single exit path for 4 and 5. Increments
# the consecutive-failure counter, pages exactly once when it REACHES the
# threshold, keeps the previous observations so the next successful run still
# has a baseline to diff against.
fail_and_exit() {
	local rc="$1" summary="$2" consec
	log "ERROR $summary"
	consec=$((PREV_CONSEC + 1))
	if [ "$consec" -eq "$FAILURE_ALERT_AFTER" ]; then
		alert default "pulsevm-upstream: source unreachable (exit ${rc})" \
			"${consec} consecutive failed runs — ${summary}. Alerting once per outage; a successful run re-arms it."
	else
		log "INFO consecutive_failures=${consec} (page fires only on the run that reaches ${FAILURE_ALERT_AFTER})"
	fi
	state_write "$PREV_OBS" "$consec"
	exit "$rc"
}

# ---- fetch ---------------------------------------------------------------
# Same shape as scripts/check-anchor-publish-health.sh's fetch(): prints the
# FINAL attempt's HTTP status, leaves the FINAL attempt's body in <outfile>,
# retries up to FYD_FETCH_ATTEMPTS and stops the moment a 200 arrives.
#
# One deliberate difference: a 4xx also stops the loop. A 4xx is a verdict,
# not a blip — a moved page will 404 three times in a row, and GitHub answers
# an exhausted unauthenticated rate limit with 403, so retrying it spends two
# more requests against a budget already known to be empty. Retrying a 4xx
# cannot succeed and is impolite to a third party; 5xx and connection failures
# (000) still get the full retry budget, which is where transient blips
# actually live.
fetch() {
	local url="$1" outfile="$2"
	local attempts="${FYD_FETCH_ATTEMPTS:-3}"
	local sleep_s="${FYD_RETRY_SLEEP:-3}"
	local attempt=1 code
	while :; do
		code="$("$CURL" -sS -o "$outfile" -w "%{http_code}" --max-time 20 "$url" 2>/dev/null || echo "000")"
		[ "$code" = "200" ] && break
		case "$code" in 4??) break ;; esac
		[ "$attempt" -ge "$attempts" ] && break
		sleep "$sleep_s"
		attempt=$((attempt + 1))
	done
	printf '%s' "$code"
}

fetch_or_fail() {
	# fetch_or_fail <label> <url> <outfile>
	local label="$1" url="$2" outfile="$3" code
	code="$(fetch "$url" "$outfile")"
	[ "$code" = "200" ] || fail_and_exit 4 "${label} not readable: ${url} HTTP=${code} after retrying"
}

fetch_or_fail "S1 releases"  "$RELEASES_URL"  "$TMP/s1.json"
fetch_or_fail "S2 endpoints" "$ENDPOINTS_URL" "$TMP/s2.md"
fetch_or_fail "S3 health"    "$HEALTH_URL"    "$TMP/s3.json"
fetch_or_fail "S4 llms"      "$LLMS_URL"      "$TMP/s4.txt"

# ---- parse ---------------------------------------------------------------
# S1: the release tag. Recorded only; never a trigger.
CUR_TAG="$(jq -er '.tag_name // empty' "$TMP/s1.json" 2>/dev/null || true)"
[ -n "$CUR_TAG" ] || fail_and_exit 5 "S1 returned 200 but has no .tag_name (${RELEASES_URL})"

# S3: head block. Taken by recursive descent rather than a fixed path — the
# value appears under more than one service entry in Hyperion's health
# payload (PulseVM-RPC and Indexer both carry it) and the service order is
# not contractual. First match wins; they agree in practice, and disagreeing
# by a block or two cannot cross the T4 threshold.
CUR_HEAD="$(jq -r 'first(.. | objects | .head_block_num? | numbers) // empty' "$TMP/s3.json" 2>/dev/null || true)"
[[ "$CUR_HEAD" =~ ^[0-9]+$ ]] || fail_and_exit 5 "S3 returned 200 but has no numeric head_block_num (${HEALTH_URL})"

# S2: the endpoints page. A 200 that is empty means the docs site served us a
# shell instead of the document.
[ -s "$TMP/s2.md" ] || fail_and_exit 5 "S2 returned 200 with an empty body (${ENDPOINTS_URL})"
if grep -qiE "$SYNC_NOTICE_RE" "$TMP/s2.md"; then CUR_SYNC_NOTICE=true; else CUR_SYNC_NOTICE=false; fi
# A mainnet SECTION, i.e. a markdown heading — not the bare word anywhere on
# the page, which would fire on a sentence like "mainnet is not live yet".
if grep -qiE '^#{1,6}[[:space:]].*mainnet' "$TMP/s2.md"; then CUR_MAINNET=true; else CUR_MAINNET=false; fi
# Antelope chain ids are 32-byte hex. The page's other identifier (the
# Avalanche blockchain ID) is base58 and cannot collide with this shape.
grep -oiE '\b[0-9a-f]{64}\b' "$TMP/s2.md" | tr 'A-F' 'a-f' | sort -u > "$TMP/cur_chain_ids" || true

# S4: the page list, taken from the link targets rather than the titles (a
# title can be reworded without the page changing).
[ -s "$TMP/s4.txt" ] || fail_and_exit 5 "S4 returned 200 with an empty body (${LLMS_URL})"
grep -oE 'https://[A-Za-z0-9._-]+/[A-Za-z0-9._/-]*\.md\b' "$TMP/s4.txt" | sort -u > "$TMP/cur_pages" || true
[ -s "$TMP/cur_pages" ] || fail_and_exit 5 "S4 returned 200 but no page links could be parsed (${LLMS_URL})"

# ---- evaluate triggers ---------------------------------------------------
FIRED=""
DETAIL=""
add_fire() { FIRED="${FIRED}${FIRED:+,}$1"; DETAIL="${DETAIL}${DETAIL:+ — }$2"; }

if [ "$PREV_OK" -eq 0 ]; then
	add_fire "BASELINE" "no usable prior state at ${STATE}; a baseline has been recorded (release=${CUR_TAG}, head_block=${CUR_HEAD}, chain_ids=$(wc -l < "$TMP/cur_chain_ids" | tr -d ' '), pages=$(wc -l < "$TMP/cur_pages" | tr -d ' ')). T3/T4 DEFERRED: nothing to diff against yet"
fi

# T1 — the sentence is gone. Evaluable from the current page alone, so it is
# also checked on a baseline run.
if [ "$CUR_SYNC_NOTICE" = "false" ] && { [ "$PREV_OK" -eq 0 ] || [ "$PREV_SYNC_NOTICE" = "true" ]; }; then
	add_fire "T1" "the 'third-party node sync is not yet supported' notice is GONE from ${ENDPOINTS_URL} — running our own node may now be possible"
fi

# T2 — mainnet section, or a chain id we have not recorded before.
if [ "$CUR_MAINNET" = "true" ] && { [ "$PREV_OK" -eq 0 ] || [ "$PREV_MAINNET" = "false" ]; }; then
	add_fire "T2" "a mainnet section appeared in ${ENDPOINTS_URL}"
fi
if [ "$PREV_OK" -eq 1 ]; then
	NEW_CHAIN_IDS="$(comm -13 "$TMP/prev_chain_ids" "$TMP/cur_chain_ids" | head -3 | tr '\n' ' ')"
	if [ -n "${NEW_CHAIN_IDS// /}" ]; then
		add_fire "T2" "new chain id(s) on ${ENDPOINTS_URL}: ${NEW_CHAIN_IDS%% } (an Alpine reset changes the chain id too — check which)"
	fi
fi

# T3 — new pages.
if [ "$PREV_OK" -eq 1 ]; then
	NEW_PAGES="$(comm -13 "$TMP/prev_pages" "$TMP/cur_pages" | head -5 | tr '\n' ' ')"
	if [ -n "${NEW_PAGES// /}" ]; then
		add_fire "T3" "new page(s) in ${LLMS_URL}: ${NEW_PAGES%% }"
	fi
fi

# T4 — the head block moved for real.
if [ "$PREV_OK" -eq 1 ] && [[ "$PREV_HEAD" =~ ^[0-9]+$ ]]; then
	if [ "$CUR_HEAD" -gt "$PREV_HEAD" ] && [ $((CUR_HEAD - PREV_HEAD)) -ge "$HEAD_BLOCK_DELTA" ]; then
		add_fire "T4" "A-Chain Alpine head block advanced ${PREV_HEAD} -> ${CUR_HEAD} (>= ${HEAD_BLOCK_DELTA}) — the testnet may be in real use"
	fi
fi

# Release tag movement is recorded, never paged.
if [ "$PREV_OK" -eq 1 ] && [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$CUR_TAG" ]; then
	log "INFO release tag ${PREV_TAG} -> ${CUR_TAG} (recorded, not a trigger)"
fi

# ---- record + verdict ----------------------------------------------------
# `jq -R -s` rather than `--rawfile`: --rawfile needs jq 1.6, and nothing
# else in this repo has taken that dependency yet. -R -s has worked since
# jq 1.4, so the checker runs on whatever the validator host happens to have.
CHAIN_IDS_JSON="$(jq -R -s 'split("\n") | map(select(length > 0))' < "$TMP/cur_chain_ids" 2>/dev/null || true)"
PAGES_JSON="$(jq -R -s 'split("\n") | map(select(length > 0))' < "$TMP/cur_pages" 2>/dev/null || true)"
CUR_OBS=""
if [ -n "$CHAIN_IDS_JSON" ] && [ -n "$PAGES_JSON" ]; then
	CUR_OBS="$(jq -n \
		--arg tag "$CUR_TAG" \
		--argjson sync "$CUR_SYNC_NOTICE" \
		--argjson mainnet "$CUR_MAINNET" \
		--argjson head "$CUR_HEAD" \
		--argjson chain_ids "$CHAIN_IDS_JSON" \
		--argjson pages "$PAGES_JSON" \
		'{release_tag: $tag, sync_notice_present: $sync, mainnet_section_present: $mainnet,
		  head_block: $head, chain_ids: $chain_ids, pages: $pages}' 2>/dev/null || true)"
fi
if [ -z "$CUR_OBS" ]; then
	# Composing our OWN record failed — that is a local defect, not an
	# upstream one, but it is still "this run produced no usable state".
	fail_and_exit 5 "could not compose the observation record from the fetched bodies"
fi

state_write "$CUR_OBS" 0

if [ -n "$FIRED" ]; then
	log "TRIGGER ${FIRED}: ${DETAIL}"
	alert high "pulsevm-upstream: ${FIRED} (exit 3)" "${DETAIL}"
	exit 3
fi

[ "$VERBOSE" -eq 1 ] && log "OK no upstream change: release=${CUR_TAG} head_block=${CUR_HEAD} sync_notice_present=${CUR_SYNC_NOTICE} mainnet_section=${CUR_MAINNET} pages=$(wc -l < "$TMP/cur_pages" | tr -d ' ')"
exit 0
