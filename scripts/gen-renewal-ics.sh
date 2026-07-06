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
OUT_DIR="$ROOT/public/calendar"
TOKEN_FILE="${CALENDAR_TOKEN_FILE:-/etc/freedom-yield/calendar-token}"
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

# validator.json stores times as Unix epoch numbers (per node-info.sh output).
# Tolerate ISO strings too in case the schema changes in the future.
to_epoch() {
  local v=$1
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
  else
    date -d "$v" +%s
  fi
}
END_EPOCH=$(to_epoch "$END_RAW")
START_EPOCH=$(to_epoch "${START_RAW:-$END_RAW}")
DTSTAMP=$(date -u +%Y%m%dT%H%M%SZ)

# Helper: epoch -> "yyyymmddThhmmss" in JST (for DTSTART/DTEND with TZID)
fmt_jst() { TZ=Asia/Tokyo date -d "@$1" +%Y%m%dT%H%M%S; }

# Helper: epoch -> "yyyymmdd" (for VALUE=DATE all-day events)
fmt_date() { TZ=Asia/Tokyo date -d "@$1" +%Y%m%d; }

# Helper: epoch -> human "MM/DD HH:MM JST"
fmt_human() { TZ=Asia/Tokyo date -d "@$1" '+%m/%d %H:%M JST'; }

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

  # Cycle 1 = current (ends at END_EPOCH)
  gen_cycle "$END_EPOCH" 1 "次回 (Renewal #1, 初回)" "\\n初回 renewal: 入念に検証。NodeID typo / BLS PoP / startTime > 旧 endTime / stake 額 / reward addr をダブルチェック。"

  # Cycle 2 = estimated next (endTime + 30 days + 8 min startTime buffer)
  C2=$((END_EPOCH + 30 * 86400 + 480))
  gen_cycle "$C2" 2 "月次 (Renewal #2, 推定)" "\\n月次サイクル本格運用。dates は #1 確定後に再計算されます。"

  # Cycle 3 = estimated
  C3=$((C2 + 30 * 86400 + 480))
  gen_cycle "$C3" 3 "月次 (Renewal #3, 推定)" "\\n月次サイクル推定 (前回 endTime + 30 日)。"

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

echo "Generated: $OUT_FILE ($(stat -c %s "$OUT_FILE") bytes)"
echo "Generated: $OUT_PUBLIC (public mirror)"
echo "Operator URL: https://metal.freedom-yield.com/calendar/${TOKEN}.ics"
echo "Public URL:   https://metal.freedom-yield.com/calendar/schedule.ics"
