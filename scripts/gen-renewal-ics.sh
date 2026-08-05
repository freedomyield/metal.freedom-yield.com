#!/usr/bin/env bash
# gen-renewal-ics.sh — generate Validator renewal schedule as an iCalendar (.ics).
#
# Reads the current endTime from public/api/validator.json and projects renewal
# events for the current cycle + the next 2 estimated cycles (monthly cadence).
# Output: public/calendar/<token>.ics, where <token> is read from
# /etc/freedom-yield/calendar-token (a stable random hex string). The token
# acts as a hard-to-guess URL component — without it the file is undiscoverable.
#
# Per-cycle events (1):
#   - Renewal:  T-5min to T+60min (covers the rollover window)
# Plus one all-day banner for the current period.
#
# Cron (daily) regenerates so the file stays in sync with on-chain endTime.
# Idempotent: same endTime → same content. Atomic write via tempfile + mv.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# -------- cycle-gate (= cycle-affecting write 制御、 fail-closed) --------
# Skip .ics regeneration when the gate is deferred or missing. The renewal
# calendar embeds cycle endTime / reminder timestamps; rewriting during a
# transition window risks publishing stale cycle metadata to subscribers.
CYCLE_GATE_SCRIPT="${ROOT}/scripts/cycle-gate.sh"
if [ ! -x "${CYCLE_GATE_SCRIPT}" ]; then
	echo "[gen-renewal-ics] cycle-gate.sh missing or non-executable → skip (fail-closed)" >&2
	exit 0
fi
if ! "${CYCLE_GATE_SCRIPT}" --side-effect=cycle-artifact-write; then
	echo "[gen-renewal-ics] deferred by cycle-gate → skip .ics regeneration" >&2
	exit 0
fi

VALIDATOR_JSON="${VALIDATOR_JSON:-$ROOT/public/api/validator.json}"
OUT_DIR="${CALENDAR_OUT_DIR:-$ROOT/public/calendar}"
TOKEN_FILE="${CALENDAR_TOKEN_FILE:-/etc/freedom-yield/calendar-token}"
# cycle-history.jsonl's line count = number of CLOSED cycles (same
# CLOSED_COUNT idiom as scripts/gen-anchor-source.sh's FY_EXPECT_CYCLE
# guard). Used below to derive the real upcoming renewal number instead of
# hardcoding "Renewal #1" — see the "next renewal number" section.
CYCLE_HISTORY_JSONL="${CYCLE_HISTORY_JSONL:-$ROOT/public/api/cycle-history.jsonl}"
# Last-confirmed CLOSED_COUNT, persisted under the same gitignored/push-owned
# directory as the calendar output itself (public/calendar). Read on an
# absent/unreadable cycle-history.jsonl so this script never has to guess
# "0" out of thin air (see the "next renewal number" section below) —
# review round 1, item 2.
CLOSED_COUNT_CACHE_FILE="${CLOSED_COUNT_CACHE_FILE:-${CALENDAR_OUT_DIR:-$ROOT/public/calendar}/.last-closed-count}"
RENEWAL_DOC_URL="https://github.com/freedomyield/metal.freedom-yield.com/blob/main/docs/VALIDATOR_RENEWAL.md"

if [ ! -r "$TOKEN_FILE" ]; then
  echo "ERROR: calendar token file not readable: $TOKEN_FILE" >&2
  echo "       create with: openssl rand -hex 16 | sudo tee $TOKEN_FILE >/dev/null && sudo chmod 644 $TOKEN_FILE" >&2
  exit 1
fi
TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
[ -n "$TOKEN" ] || { echo "ERROR: token is empty" >&2; exit 1; }
# Token must be 16-64 hex chars (matches web host wrapper pattern)
[[ "$TOKEN" =~ ^[a-f0-9]{16,64}$ ]] || { echo "ERROR: token must be 16-64 hex chars" >&2; exit 1; }

mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/${TOKEN}.ics"
# Public schedule URL — same content, discoverable filename so the website
# can deep-link to "Add to Google Calendar" for general visitors. The token
# URL stays private for the operator's existing GCal subscription.
OUT_PUBLIC="$OUT_DIR/schedule.ics"

if [ ! -r "$VALIDATOR_JSON" ]; then
  echo "ERROR: validator.json not readable: $VALIDATOR_JSON" >&2
  exit 1
fi

END_RAW=$(jq -r '.endTime // empty' "$VALIDATOR_JSON")
START_RAW=$(jq -r '.startTime // empty' "$VALIDATOR_JSON")
NODE_ID=$(jq -r '.nodeId // "unknown"' "$VALIDATOR_JSON")
if [ -z "$END_RAW" ] || [ "$END_RAW" = "null" ]; then
  echo "ERROR: cannot read .endTime from $VALIDATOR_JSON" >&2
  exit 1
fi

# ---- portability shim: GNU date (validator host, Linux CI) vs BSD date
# (operator Mac, hermetic tests) — mirrors scripts/gen-anchor-source.sh's
# identical `date --version` capability probe (review round 1, item 1: this
# script previously called GNU `date -d` unconditionally with no fallback,
# so its own test suite could only SKIP, never actually assert, on a
# non-GNU-date host — an "empty PASS" that run-all-tests silently counted
# as green). epoch_to_fmt() replaces the three separate fmt_* helpers'
# direct `date -d "@$1"` calls; date_from_iso() backs to_epoch()'s rare
# non-numeric-input branch (validator.json always emits a numeric epoch in
# practice, so this path is defensive-only, but portable regardless).
if date --version >/dev/null 2>&1; then
  # GNU (Linux)
  epoch_to_fmt() { TZ="$2" date -d "@$1" +"$3"; }
  date_from_iso() { date -d "$1" +%s; }
else
  # BSD (macOS)
  epoch_to_fmt() { TZ="$2" date -r "$1" +"$3"; }
  date_from_iso() { date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s; }
fi

# validator.json stores times as Unix epoch numbers (per node-info.sh output).
# Tolerate ISO strings too in case the schema changes in the future.
to_epoch() {
  local v=$1
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
  else
    date_from_iso "$v"
  fi
}
END_EPOCH=$(to_epoch "$END_RAW")
START_EPOCH=$(to_epoch "${START_RAW:-$END_RAW}")
DTSTAMP=$(date -u +%Y%m%dT%H%M%SZ)

# ---- next renewal number (= CLOSED_COUNT + 1) --------------------------
# CLOSED_COUNT = number of already-closed cycles on cycle-history.jsonl
# (one line per closed cycle; cycle_status is always "closed" per
# public/api/cycle-history.schema.v1.json). Previously this script
# hardcoded "Renewal #1/#2/#3" unconditionally, so the public calendar kept
# announcing "Renewal #1 (初回)" long after the first renewal had actually
# happened (3 renewals recorded as of this fix).
#
# Review round 1, item 2: a naive "absent/unreadable -> CLOSED_COUNT=0" is
# the SAME silent-genesis failure shape this branch's M-2 sibling fix
# (scripts/gen-anchor-source.sh) closes for prev_anchor_root — an
# unreadable file is NOT evidence that zero cycles have closed, it is
# evidence that we could not check. cycle-history.jsonl lives under
# public/api/ (gitignored, push-owned — real in production, absent in a
# fresh worktree), so "absent" is a live possibility here, not a
# theoretical one. This is intentionally NOT made fail-closed: a cron
# chains .ics generation into a push step, and refusing to generate would
# break the subscriber calendar outright (reviewer-agreed trade-off) — so
# the three states below are handled fail-SAFE instead:
#
#   1. cycle-history.jsonl readable  -> CONFIRMED count (0 is a legitimate
#      confirmed value here: genuine pre-first-cycle bootstrap). Persisted
#      to CLOSED_COUNT_CACHE_FILE for case 2 below. Line count uses the
#      same blank-line-tolerant idiom as gen-anchor-source.sh's M-2 fix
#      (grep -vE blank -c), NOT `wc -l` — `wc -l` undercounts by one when
#      the file's last line lacks a trailing newline (a real, independent
#      bug from the M-2 pattern; review round 1, item 5). `|| true` is
#      required: under this script's own `pipefail`, `grep -c` legitimately
#      exits 1 when it matches zero lines (e.g. CLOSED_COUNT is genuinely
#      0), which would otherwise abort the whole script under `set -e`.
#   2. cycle-history.jsonl unreadable + a prior CONFIRMED count was cached
#      -> use the CACHED value (= "retain the previous value", not a fresh
#      confirmation) and warn loudly that this run could not confirm it.
#   3. cycle-history.jsonl unreadable + no cache exists at all (true
#      first-ever run before this script has ever seen a readable file) ->
#      CLOSED_COUNT=0, but flagged as UNCONFIRMED, not CONFIRMED.
#
# CLOSED_COUNT_SOURCE gates the "初回" (first-time) checklist text below:
# that text is shown ONLY on a CONFIRMED zero, never on a cached or
# unconfirmed fallback — even when the fallback also happens to be 0 — so
# an operational hiccup reading cycle-history.jsonl can never itself cause
# the public calendar to assert "this is confirmed to be the very first
# renewal" when that was never actually checked.
CLOSED_COUNT=0
CLOSED_COUNT_SOURCE="unconfirmed"
if [ -r "$CYCLE_HISTORY_JSONL" ]; then
  CLOSED_COUNT=$(grep -cvE '^[[:space:]]*$' "$CYCLE_HISTORY_JSONL" 2>/dev/null || true)
  [[ "$CLOSED_COUNT" =~ ^[0-9]+$ ]] || CLOSED_COUNT=0
  CLOSED_COUNT_SOURCE="confirmed"
  mkdir -p "$(dirname "$CLOSED_COUNT_CACHE_FILE")" 2>/dev/null || true
  printf '%s\n' "$CLOSED_COUNT" > "$CLOSED_COUNT_CACHE_FILE" 2>/dev/null || true
elif [ -r "$CLOSED_COUNT_CACHE_FILE" ]; then
  CACHED_CLOSED_COUNT="$(tr -d '[:space:]' < "$CLOSED_COUNT_CACHE_FILE" 2>/dev/null || true)"
  if [[ "$CACHED_CLOSED_COUNT" =~ ^[0-9]+$ ]]; then
    CLOSED_COUNT="$CACHED_CLOSED_COUNT"
    CLOSED_COUNT_SOURCE="cached"
    echo "WARN: [gen-renewal-ics] $CYCLE_HISTORY_JSONL unreadable — using last-confirmed CLOSED_COUNT=$CLOSED_COUNT cached at $CLOSED_COUNT_CACHE_FILE (NOT freshly confirmed this run). If cycle-history.jsonl should exist, investigate before trusting the renewal numbering below." >&2
  else
    echo "WARN: [gen-renewal-ics] $CYCLE_HISTORY_JSONL unreadable AND cache at $CLOSED_COUNT_CACHE_FILE is unusable — assuming pre-first-cycle bootstrap (CLOSED_COUNT=0, UNCONFIRMED). If a cycle has already closed, this renewal numbering is wrong; investigate immediately." >&2
  fi
else
  echo "WARN: [gen-renewal-ics] $CYCLE_HISTORY_JSONL unreadable and no cached count exists yet at $CLOSED_COUNT_CACHE_FILE — assuming pre-first-cycle bootstrap (CLOSED_COUNT=0, UNCONFIRMED). If a cycle has already closed, this renewal numbering is wrong; investigate immediately." >&2
fi
NEXT_RENEWAL_N=$((CLOSED_COUNT + 1))

# Helper: epoch -> "yyyymmddThhmmss" in JST (for DTSTART/DTEND with TZID)
fmt_jst() { epoch_to_fmt "$1" Asia/Tokyo "%Y%m%dT%H%M%S"; }

# Helper: epoch -> "yyyymmdd" (for VALUE=DATE all-day events)
fmt_date() { epoch_to_fmt "$1" Asia/Tokyo "%Y%m%d"; }

# Helper: epoch -> human "MM/DD HH:MM JST"
fmt_human() { epoch_to_fmt "$1" Asia/Tokyo '%m/%d %H:%M JST'; }

# Generate one cycle's renewal event. Args: cycle_end_epoch, cycle_number, label, extra_note
# Public calendar shows a single 🔁 marker per cycle at endTime ± 5 min.
# Operator-internal prep windows are no longer surfaced publicly because
# issuance mode varies per cycle (pre-expiry vs post-expiry depending on
# FREE-balance accounting); a fixed T-2 marker would misrepresent the
# schedule. Operator-side ntfy alerts (T-7/T-1/T-0/T-10min) carry the
# per-event urgency.
gen_cycle() {
  local cycle_end=$1
  local n=$2
  local label=$3
  local extra=$4

  local event_start=$((cycle_end - 300))
  local event_end=$((cycle_end + 3600))
  local cycle_end_h=$(fmt_human "$cycle_end")

  cat <<EOF
BEGIN:VEVENT
UID:metal-renewal-${n}-${TOKEN}@freedom-yield.com
DTSTAMP:${DTSTAMP}
DTSTART;TZID=Asia/Tokyo:$(fmt_jst $event_start)
DTEND;TZID=Asia/Tokyo:$(fmt_jst $event_end)
SUMMARY:🔁 Validator Renewal #${n}
DESCRIPTION:${label}\n旧期間 endTime: ${cycle_end_h}\n新サイクルへの rollover。Pending → Current 昇格を観察、サイト validator.json 更新と uptime カウンタリセットを確認。${extra}\n\nNodeID: ${NODE_ID}\nDoc: ${RENEWAL_DOC_URL}
LOCATION:metal.freedom-yield.com
BEGIN:VALARM
ACTION:DISPLAY
DESCRIPTION:Renewal #${n} 5 分前
TRIGGER:-PT5M
END:VALARM
END:VEVENT
EOF
}

TMP=$(mktemp "${OUT_DIR}/.${TOKEN}.ics.XXXXXX")
trap 'rm -f "$TMP"' EXIT

{
  # ICS bytes use CRLF in spec but Google Calendar accepts LF too. Keep LF for
  # simplicity; if a stricter consumer complains, post-process with sed.
  cat <<EOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Freedom Yield//Metal Validator Schedule//EN
METHOD:PUBLISH
X-WR-CALNAME:Metal Validator Renewal
X-WR-TIMEZONE:Asia/Tokyo
X-WR-CALDESC:Metal Blockchain validator (Freedom Yield) renewal schedule. Auto-generated daily from on-chain endTime.
BEGIN:VTIMEZONE
TZID:Asia/Tokyo
BEGIN:STANDARD
DTSTART:19700101T000000
TZOFFSETFROM:+0900
TZOFFSETTO:+0900
TZNAME:JST
END:STANDARD
END:VTIMEZONE
BEGIN:VEVENT
UID:metal-current-period-${TOKEN}@freedom-yield.com
DTSTAMP:${DTSTAMP}
DTSTART;VALUE=DATE:$(fmt_date $START_EPOCH)
DTEND;VALUE=DATE:$(fmt_date $((END_EPOCH + 86400)))
SUMMARY:📊 Validator 稼働期間 (current)
DESCRIPTION:現在のバリデート期間。startTime / endTime は P-Chain 上の値。\n\nNodeID: ${NODE_ID}\nendTime: $(fmt_human $END_EPOCH)\nDoc: ${RENEWAL_DOC_URL}
TRANSP:TRANSPARENT
END:VEVENT
EOF

  # Renewal N = current (ends at END_EPOCH). N is derived above from
  # CLOSED_COUNT, not hardcoded — otherwise the public calendar keeps
  # announcing "Renewal #1 (初回)" forever, regardless of how many
  # renewals have actually already happened. The initial-only checklist
  # copy is shown ONLY when CLOSED_COUNT is a CONFIRMED zero
  # ($CLOSED_COUNT_SOURCE = "confirmed", not "cached"/"unconfirmed") — a
  # cached or unconfirmed fallback must never assert "this is confirmed to
  # be the very first renewal" (review round 1, item 2).
  if [ "$CLOSED_COUNT_SOURCE" = "confirmed" ] && [ "$CLOSED_COUNT" -eq 0 ]; then
    N1_LABEL="次回 (Renewal #${NEXT_RENEWAL_N}, 初回)"
    N1_EXTRA="\\n初回 renewal: 入念に検証。NodeID typo / BLS PoP / startTime > 旧 endTime / stake 額 / reward addr をダブルチェック。"
  else
    N1_LABEL="次回 (Renewal #${NEXT_RENEWAL_N})"
    N1_EXTRA=""
  fi
  gen_cycle "$END_EPOCH" "$NEXT_RENEWAL_N" "$N1_LABEL" "$N1_EXTRA"

  # Renewal N+1 = estimated next (endTime + 30 days + 8 min startTime buffer)
  C2=$((END_EPOCH + 30 * 86400 + 480))
  N2=$((NEXT_RENEWAL_N + 1))
  gen_cycle "$C2" "$N2" "月次 (Renewal #${N2}, 推定)" "\\n月次サイクル本格運用。dates は #${NEXT_RENEWAL_N} 確定後に再計算されます。"

  # Renewal N+2 = estimated
  C3=$((C2 + 30 * 86400 + 480))
  N3=$((NEXT_RENEWAL_N + 2))
  gen_cycle "$C3" "$N3" "月次 (Renewal #${N3}, 推定)" "\\n月次サイクル推定 (前回 endTime + 30 日)。"

  echo "END:VCALENDAR"
} > "$TMP"

chmod 644 "$TMP"
# Write to both the token path and the public schedule path.
# Same content; the URLs differ only in discoverability — token stays out
# of search engines, public schedule is meant to be linked.
cp "$TMP" "$OUT_PUBLIC"
chmod 644 "$OUT_PUBLIC"
mv "$TMP" "$OUT_FILE"
trap - EXIT

# GNU/BSD stat portability (same try-GNU-then-BSD-fallback idiom as
# scripts/peer-validators.sh's SNAP_SIZE / scripts/broadcast-guard.sh's
# TOKEN_MTIME) — this is now reachable on macOS too since the date shim
# above no longer forces an early GNU-only failure.
OUT_FILE_SIZE=$(stat -c%s "$OUT_FILE" 2>/dev/null || stat -f%z "$OUT_FILE")
echo "Generated: $OUT_FILE ($OUT_FILE_SIZE bytes)"
echo "Generated: $OUT_PUBLIC (public mirror)"
echo "Operator URL: https://metal.freedom-yield.com/calendar/${TOKEN}.ics"
echo "Public URL:   https://metal.freedom-yield.com/calendar/schedule.ics"
