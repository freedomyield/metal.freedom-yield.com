#!/usr/bin/env bash
# Anomaly detector — runs every 5 min via cron.
# Compares current state vs a state file to dedup notifications (so we don't spam
# the same alert minute after minute).
#
# Detection rules:
#   - metalgo container not "running"
#   - caddy   container not "running"
#   - disk usedPercent > 85
#   - memory usedPercent > 95
#   - peer count < 10
#   - validator entry missing from getCurrentValidators (= dropped from consensus)
#   - period remaining: T-7 day / T-1 day / T-0 day / T-10min before endTime
#     (date-matched JST for the day-based three; second-precision for T-10min)
#   - public web URL (web host, behind edge CDN) returns non-200 — 1 回目で fail したら
#     30 秒後に即再確認、2 回連続で fail なら alert(transient blip は ~50 秒で
#     黙ってミュート、本物の障害は ~50 秒で検知)
#   - public /api/validator.json observedAt > 15 min stale (= push pipeline stuck)
#
# State file: /var/lib/<your-namespace>/anomaly-state.json
#   {
#     "metalgo": "running",   ← last seen status
#     "caddy":   "running",
#     "disk":    "ok",        ← "ok" or "warn"
#     "memory":  "ok",
#     "peers":   "ok",
#     "web":     "ok",        ← web host(web 配信) の公開到達性
#     "api_freshness": "ok",  ← validator.json の observedAt 鮮度
#     "validator_present": "yes",
#     "period_alert_sent": { "7": false, "1": false, "0": false, "10min": false }
#   }
#
# Alert cadence (JST date-matched, one-shot per cycle):
#   - T-7 day  default  : 1 週間前 heads-up
#   - T-1 day  default  : 前日 reminder
#   - T-0 day  default  : 当日 reminder (action 時刻は別途)
#   - T-10min  urgent   : 旧 stake 解放まで残り 10 分
# Rationale: in post-expiry issuance mode (current cycle) the only moment the
# operator can act is at or after endTime when the old stake unlocks. Firing
# "urgent" alerts T-2 days out is false urgency.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY="${NOTIFY:-$ROOT/scripts/notify.sh}"
: "${ANOMALY_STATE_DIR:?ANOMALY_STATE_DIR is required}"
STATE_DIR="$ANOMALY_STATE_DIR"
STATE_FILE=$STATE_DIR/anomaly-state.json
STATUS_JSON="$ROOT/public/api/server-status.json"
VALIDATOR_JSON="$ROOT/public/api/validator.json"
NODE_ID="${NODE_ID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
METALGO_API="${METALGO_API:-http://localhost:9650}"

# === 4B.5.1: K-1 + K-2 gate thresholds (env overridable) ===================
MAX_AGE_SEC="${MAX_AGE_SEC:-600}"
FUTURE_SKEW_MAX_SEC="${FUTURE_SKEW_MAX_SEC:-60}"

# === 4B.5.1 K-1: input syntax + schema gate ================================
# Exit code:
#   2  STATUS_JSON missing / unreadable / invalid JSON / required fields missing / wrong type
# Side effects: stderr only; no state mutation; no notify call.
validate_status_json() {
  if [ ! -f "$STATUS_JSON" ]; then
    echo "[K-1] STATUS_JSON missing: $STATUS_JSON" >&2; return 2
  fi
  if [ ! -r "$STATUS_JSON" ]; then
    echo "[K-1] STATUS_JSON unreadable: $STATUS_JSON" >&2; return 2
  fi
  if ! jq empty "$STATUS_JSON" >/dev/null 2>&1; then
    echo "[K-1] STATUS_JSON not valid JSON" >&2; return 2
  fi
  if ! jq -e '
      (.observedAt|type=="string") and ((.observedAt|length)>0)
      and (.metalgo|type=="object")
      and (.metalgo.containerStatus|type=="string") and ((.metalgo.containerStatus|length)>0)
      and (.metalgo.peerCount|type=="number")
      and (.caddy|type=="object")
      and (.caddy.containerStatus|type=="string") and ((.caddy.containerStatus|length)>0)
      and (.host.cpu.usedPercent|type=="number")
      and (.host.memory.usedPercent|type=="number")
      and (.host.disk.usedPercent|type=="number")
    ' "$STATUS_JSON" >/dev/null 2>&1; then
    echo "[K-1] STATUS_JSON missing required fields or wrong types" >&2; return 2
  fi
  return 0
}

# === 4B.5.1 K-2: freshness gate ============================================
# Spec (boundary):
#   - age = now_utc - observedAt_utc  (positive when input is in the past)
#   - accept iff:  -FUTURE_SKEW_MAX_SEC <= age <= MAX_AGE_SEC
#       i.e. age=MAX_AGE_SEC is ACCEPT, age=MAX_AGE_SEC+1 is REJECT
#            future_skew=FUTURE_SKEW_MAX_SEC is ACCEPT, +1 is REJECT
#   - parse failure → exit 2 (= input invalid)
#   - stale (age > MAX_AGE_SEC) or future skew (> FUTURE_SKEW_MAX_SEC) → exit 3
# Side effects: stderr only (logs computed age); no state mutation; no notify call.
validate_freshness() {
  local obs obs_epoch now age
  obs=$(jq -r '.observedAt' "$STATUS_JSON" 2>/dev/null)
  obs_epoch=$(date -u -d "$obs" +%s 2>/dev/null)
  if [ -z "$obs_epoch" ] || ! [[ "$obs_epoch" =~ ^[0-9]+$ ]]; then
    echo "[K-2] observedAt parse failed: '$obs'" >&2
    return 2
  fi
  now=$(date -u +%s)
  age=$(( now - obs_epoch ))
  echo "[K-2] age=${age}s (now=${now} obs_epoch=${obs_epoch} max=${MAX_AGE_SEC} skew_max=${FUTURE_SKEW_MAX_SEC})" >&2
  if [ "$age" -lt 0 ]; then
    local skew=$(( -age ))
    if [ "$skew" -gt "$FUTURE_SKEW_MAX_SEC" ]; then
      echo "[K-2] observedAt in future by ${skew}s > ${FUTURE_SKEW_MAX_SEC}s" >&2
      return 3
    fi
  elif [ "$age" -gt "$MAX_AGE_SEC" ]; then
    echo "[K-2] observedAt stale: age=${age}s > ${MAX_AGE_SEC}s" >&2
    return 3
  fi
  return 0
}

validate_status_json; K1RC=$?
if [ "$K1RC" -ne 0 ]; then exit "$K1RC"; fi
validate_freshness; K2RC=$?
if [ "$K2RC" -ne 0 ]; then exit "$K2RC"; fi

# === 4B.5.2 K-4: non-blocking flock + contention counter ===================
# Purpose: at most one check-anomalies.sh runs concurrently. A previous run
# still in flight (= e.g. slow curl waiting for metalgo) makes the next 5-min
# cron tick skip cleanly rather than pile up on the lock or trigger duplicate
# notifications. See docs/MONITORING_OPS.md §4 for design rationale.
#
# Exit codes:
#   0  lock acquired and (eventually) normal completion, OR contention skip
#   5  structural error: lock dir missing or lock file cannot be opened
#
# Side effects:
#   - Lock file is created on first open (= no operator pre-step needed
#     beyond the one-time lock-dir creation).
#   - Lock file is NEVER deleted by this script. flock holds the fd, not the
#     file entry. State init/reset MUST also leave the lock file in place.
#   - Contention counter is bumped on skip via a separately-locked write to
#     a counter file. Counter bump failure does NOT abort the main pipeline
#     (= observability is best-effort).
LOCK_FILE="${ANOMALY_LOCK_FILE:-/var/lib/freedom-yield/locks/check-anomalies.lock}"
LOCK_DIR="$(dirname "$LOCK_FILE")"
CONTENTION_COUNTER="${ANOMALY_CONTENTION_COUNTER:-/var/lib/freedom-yield/anomaly-contention-counter}"

bump_contention_counter() {
  # Best-effort: failure to bump must NOT abort the cron's main job.
  local counter_lock="${CONTENTION_COUNTER}.lock"
  (
    if ! exec 8>"$counter_lock"; then
      echo "[K-4-COUNTER] cannot open counter lock $counter_lock; skipping bump" >&2
      exit 0
    fi
    if ! flock -w 2 8; then
      echo "[K-4-COUNTER] could not acquire counter lock within 2s; skipping bump" >&2
      exit 0
    fi
    local cur=0
    if [ -f "$CONTENTION_COUNTER" ]; then
      cur=$(cat "$CONTENTION_COUNTER" 2>/dev/null || echo 0)
      [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
    fi
    local next=$(( cur + 1 ))
    # Atomic write of the counter value.
    local tmp
    tmp=$(mktemp -p "$(dirname "$CONTENTION_COUNTER")" .counter.XXXXXX 2>/dev/null) || {
      echo "[K-4-COUNTER] mktemp failed for counter dir; skipping bump" >&2
      exit 0
    }
    printf '%s\n' "$next" > "$tmp"
    mv "$tmp" "$CONTENTION_COUNTER" 2>/dev/null \
      || { rm -f "$tmp"; echo "[K-4-COUNTER] rename to $CONTENTION_COUNTER failed; skipping bump" >&2; exit 0; }
  ) || true
}

if [ ! -d "$LOCK_DIR" ]; then
  echo "[K-4] lock dir missing: $LOCK_DIR (run anomaly-state-init.sh on a fresh host); exit 5" >&2
  exit 5
fi
if ! exec 9>"$LOCK_FILE"; then
  echo "[K-4] cannot open lock file: $LOCK_FILE; exit 5" >&2
  exit 5
fi
if ! flock -n 9; then
  echo "[K-4-SKIP] previous run still holds lock ($LOCK_FILE); incrementing contention counter; exit 0" >&2
  bump_contention_counter
  exit 0
fi
echo "[K-4] lock acquired" >&2

# === 4B.5.2 K-3.5: state-file presence + schema validation + SHA-256 dedup ===
# See docs/MONITORING_OPS.md §5 for design rationale.
#
# Sub-cases and exit codes:
#   - state dir missing                         -> exit 5 (structural)
#   - state file missing, no missing-marker     -> create marker + best-effort notify + exit 7
#   - state file missing, marker present        -> stderr log only + exit 7
#   - state file invalid, new SHA-256           -> quarantine + best-effort notify + exit 4
#   - state file invalid, recurring SHA-256     -> stderr log only + exit 4
#
# Bootstrap is NOT auto-performed here. The operator runs
# scripts/anomaly-state-init.sh manually (= explicit, audited, single source
# of truth for baseline state). The cron's job is detection, not provisioning.
QUAR_DIR="${STATE_DIR}/quarantine"
MISSING_MARKER="${STATE_DIR}/.missing-notified.marker"

if [ ! -d "$STATE_DIR" ]; then
  echo "[K-3.5] state dir missing: $STATE_DIR (run anomaly-state-init.sh); exit 5" >&2
  exit 5
fi

if [ ! -f "$STATE_FILE" ]; then
  if [ -f "$MISSING_MARKER" ]; then
    echo "[K-3.5] state file still missing: $STATE_FILE (marker present, no new notify); exit 7" >&2
    exit 7
  fi
  # First detection — best-effort notify + create marker. Marker creation
  # and exit code do NOT depend on notify success.
  if [ -x "$NOTIFY" ]; then
    bash "$NOTIFY" high "anomaly state file missing" \
      "$(printf 'state file が存在しません: %s\n対処: scripts/anomaly-state-init.sh --confirm --baseline-status=running を実行\n再消失時に再通知できるよう missing marker を %s に作成\n本 tick は K-3 transition 処理を行わず exit 7' \
         "$STATE_FILE" "$MISSING_MARKER")" \
      >/dev/null 2>&1 || true
  fi
  # Marker is durable record; notify result is independent.
  : > "$MISSING_MARKER" 2>/dev/null || true
  echo "[K-3.5] state file missing: $STATE_FILE (marker created at $MISSING_MARKER); exit 7" >&2
  exit 7
fi

# State file exists — validate. Compute SHA-256 first so a corruption that
# is structurally JSON but schema-noncompliant gets the same dedup treatment
# as a corruption that is not parseable.
quarantine_corrupt_state() {
  local reason="$1"
  local full_sha sha8 quar_target ts
  full_sha=$(sha256sum "$STATE_FILE" 2>/dev/null | awk '{print $1}')
  if [ -z "$full_sha" ] || [ ${#full_sha} -ne 64 ]; then
    echo "[K-3.5] sha256sum failed for $STATE_FILE; exit 4" >&2
    exit 4
  fi
  sha8="${full_sha:0:8}"
  quar_target="${QUAR_DIR}/${full_sha}"

  if [ -d "$quar_target" ]; then
    # Recurrence (= identical bytes already quarantined). No new artefact, no
    # new notify. Stderr only.
    echo "[K-3.5] state corruption recurrence (reason=${reason}, sha8=${sha8}, full=${full_sha:0:16}...); no new quarantine, no new notify; original preserved; exit 4" >&2
    exit 4
  fi

  # New corruption hash — create quarantine atomically (= mktemp dir, fill,
  # then rename to deterministic target).
  mkdir -p "$QUAR_DIR" 2>/dev/null || {
    echo "[K-3.5] cannot create quarantine dir $QUAR_DIR; exit 4" >&2
    exit 4
  }
  local stage
  stage=$(mktemp -d -p "$QUAR_DIR" .stage.XXXXXX 2>/dev/null) || {
    echo "[K-3.5] mktemp -d failed in $QUAR_DIR; exit 4" >&2
    exit 4
  }
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cp -p "$STATE_FILE" "${stage}/state.json" 2>/dev/null || true
  {
    echo "reason=${reason}"
    echo "first_seen_at_utc=${ts}"
    echo "state_file_path=${STATE_FILE}"
    echo "state_file_sha256=${full_sha}"
    echo "state_file_sha8=${sha8}"
    echo ""
    echo "--- first 400 bytes of corrupt state ---"
    head -c 400 "$STATE_FILE" 2>/dev/null
    echo ""
    echo ""
    echo "--- jq parse/schema attempt ---"
    jq -e . "$STATE_FILE" 2>&1 || true
  } > "${stage}/diag.txt"
  printf '%s\n' "$ts" > "${stage}/first-seen-at.txt"

  if ! mv "$stage" "$quar_target" 2>/dev/null; then
    rm -rf "$stage" 2>/dev/null || true
    echo "[K-3.5] rename of staged quarantine to ${quar_target} failed; exit 4" >&2
    exit 4
  fi

  # Best-effort notify. Result does NOT change exit code or the on-disk
  # preservation: the durable record is the quarantine dir.
  if [ -x "$NOTIFY" ]; then
    bash "$NOTIFY" high "anomaly state corrupted (new hash)" \
      "$(printf 'state file が schema 不適合 (reason=%s, sha8=%s)\n元 file は変更せず保持\n診断 dir: %s\n対処: 診断確認後、 scripts/anomaly-state-init.sh --confirm --baseline-status=<value> [--clear-quarantine] で再初期化\n本 tick は K-3 transition 処理を行わず exit 4' \
         "$reason" "$sha8" "$quar_target")" \
      >/dev/null 2>&1 || true
  fi
  echo "[K-3.5] new corruption (reason=${reason}, sha8=${sha8}) quarantined at ${quar_target}; original preserved; exit 4" >&2
  exit 4
}

# JSON parse check.
if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  quarantine_corrupt_state "json-parse-fail"
fi

# Schema check: all required top-level fields with expected types.
if ! jq -e '
    (.metalgo|type=="string") and
    (.caddy|type=="string") and
    (.disk|type=="string") and
    (.memory|type=="string") and
    (.peers|type=="string") and
    (.web|type=="string") and
    (.api_freshness|type=="string") and
    (.validator_present|type=="string") and
    (has("last_known_end_time")) and
    (has("delegator_count")) and
    (has("delegator_total_nmetal")) and
    (.period_alert_sent|type=="object") and
    (.period_alert_sent|has("7")) and
    (.period_alert_sent|has("1")) and
    (.period_alert_sent|has("0")) and
    (.period_alert_sent|has("10min"))
  ' "$STATE_FILE" >/dev/null 2>&1; then
  quarantine_corrupt_state "schema-mismatch"
fi
# K-3.5 PASS — state is parseable and schema-conformant.

# === 4B.5.2 K-3: candidate-state commit + retry classification =============
# Conceptual layers (kept distinct in code as well as in mind):
#   ORIGINAL_STATE      = byte-identical snapshot of $STATE_FILE at run start
#   CURRENT_OBSERVATION = derived from STATUS_JSON + RPC + web probe + clock
#   CANDIDATE_STATE     = working state; starts == ORIGINAL_STATE, only
#                         advances on notify success or pure observation
# Final commit: at most ONE atomic rename to $STATE_FILE per run.
# When canonical(CANDIDATE) == canonical(ORIGINAL) the rename is skipped
# entirely (mtime preserved). See docs/MONITORING_OPS.md §6.

# --- GLOBAL_RC priority helper -------------------------------------------
# Explicit priority hierarchy; avoids implicit numerical-max coupling so
# new codes added later can override the priority without surprises.
GLOBAL_RC=0
rc_priority_set() {
  local new="$1"
  case "$new" in
    8) GLOBAL_RC=8 ;;
    7) [ "$GLOBAL_RC" -lt 7 ] && GLOBAL_RC=7 ;;
    6) [ "$GLOBAL_RC" -lt 6 ] && GLOBAL_RC=6 ;;
    5) [ "$GLOBAL_RC" -lt 5 ] && GLOBAL_RC=5 ;;
    4) [ "$GLOBAL_RC" -lt 4 ] && GLOBAL_RC=4 ;;
    3) [ "$GLOBAL_RC" -lt 3 ] && GLOBAL_RC=3 ;;
    2) [ "$GLOBAL_RC" -lt 2 ] && GLOBAL_RC=2 ;;
    0) : ;;
    *) [ "$GLOBAL_RC" -lt "$new" ] && GLOBAL_RC="$new" ;;
  esac
}

# --- ORIGINAL_STATE + CANDIDATE_STATE materialisation --------------------
ORIGINAL_STATE=$(mktemp -p "$STATE_DIR" .original.XXXXXX) || {
  echo "[K-3] mktemp ORIGINAL_STATE failed in $STATE_DIR" >&2
  exit 8
}
CANDIDATE_STATE=$(mktemp -p "$STATE_DIR" .candidate.XXXXXX) || {
  rm -f "$ORIGINAL_STATE"
  echo "[K-3] mktemp CANDIDATE_STATE failed in $STATE_DIR" >&2
  exit 8
}
cleanup_k3() {
  rm -f "$ORIGINAL_STATE" "$CANDIDATE_STATE" "${CANDIDATE_STATE}.swp" 2>/dev/null || true
}
trap cleanup_k3 EXIT
if ! cp "$STATE_FILE" "$ORIGINAL_STATE"; then
  echo "[K-3] cp STATE_FILE -> ORIGINAL_STATE failed" >&2
  exit 8
fi
if ! cp "$ORIGINAL_STATE" "$CANDIDATE_STATE"; then
  echo "[K-3] cp ORIGINAL_STATE -> CANDIDATE_STATE failed" >&2
  exit 8
fi

# --- field accessors ------------------------------------------------------
# orig_get reads from the immutable snapshot; transitions always compare
# observations against ORIGINAL_STATE, never against CANDIDATE_STATE (= a
# notify-failed field stays at the original value, and the next decision
# in this run still treats it as "original").
orig_get() { jq -r "$1" "$ORIGINAL_STATE" 2>/dev/null; }

# candidate_set writes the candidate via mktemp-sibling + atomic rename.
# Failure here is treated as a state-write error (= rc 8) but does NOT
# abort the run; the cron continues to attempt subsequent transitions, and
# the final commit will fail or skip cleanly.
candidate_set() {
  local path="$1" val="$2"
  local tmp="${CANDIDATE_STATE}.swp"
  if ! jq "$path = $val" "$CANDIDATE_STATE" > "$tmp" 2>/dev/null; then
    echo "[K-3] candidate_set jq edit failed: path=$path" >&2
    rm -f "$tmp"
    rc_priority_set 8
    return 1
  fi
  if ! mv "$tmp" "$CANDIDATE_STATE" 2>/dev/null; then
    echo "[K-3] candidate_set rename failed: swp -> candidate" >&2
    rm -f "$tmp"
    rc_priority_set 8
    return 1
  fi
  return 0
}

# --- notify retry classification (= consumes C3b NOTIFY_STRICT_EXIT=1) ---
# Per docs/MONITORING_NOTIFY_CALLERS.md §4 (S1) and operator decision:
#   in-run retry: rc 2 (transport), rc 4 (HTTP 429), rc 5 (HTTP 5xx)
#   no retry:     rc 1 (topic missing/empty), rc 3 (HTTP 4xx non-429),
#                 rc 100 (NOTIFY script missing/non-executable)
attempt_notify() {
  local prio="$1" title="$2" body="$3"
  if [ ! -x "$NOTIFY" ]; then
    echo "[K-3] notify script missing or not executable: $NOTIFY" >&2
    return 100
  fi
  NOTIFY_STRICT_EXIT=1 bash "$NOTIFY" "$prio" "$title" "$body" >/dev/null 2>&1
  return $?
}

retryable_notify_rc() {
  case "$1" in
    2|4|5) return 0 ;;
    *) return 1 ;;
  esac
}

# notify_or_keep <prio> <title> <body>
#   returns 0  → caller MAY candidate_set the field
#   returns !0 → caller MUST NOT mutate candidate (= ORIGINAL_STATE value
#                stays, next cron run re-detects and re-attempts).
# At most 2 attempts per call (= 1 initial + 1 in-run retry). No fixed
# upper bound on lifetime duplicates across runs. Delivery is at-least-once:
# duplicates are possible (= ambiguous transport success, state-commit
# failure after notify success), and not suppressed by this pipeline.
notify_or_keep() {
  local prio="$1" title="$2" body="$3" rc
  attempt_notify "$prio" "$title" "$body"; rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if retryable_notify_rc "$rc"; then
    sleep 5
    attempt_notify "$prio" "$title" "$body"; rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
  fi
  echo "[K-3] notify permanent fail (rc=$rc, prio=$prio, title=\"$title\")" >&2
  rc_priority_set 6
  return "$rc"
}

# === CURRENT_OBSERVATION extraction =====================================
OBS_METALGO=$(jq -r '.metalgo.containerStatus // "unknown"' "$STATUS_JSON")
OBS_CADDY=$(jq -r '.caddy.containerStatus // "unknown"' "$STATUS_JSON")
OBS_DISK_PCT=$(jq -r '.host.disk.usedPercent // 0' "$STATUS_JSON")
OBS_DISK_TOTAL_KB=$(jq -r '.host.disk.totalKB // 0' "$STATUS_JSON")
OBS_DISK_USED_KB=$(jq -r '.host.disk.usedKB // 0' "$STATUS_JSON")
OBS_MEM_PCT=$(jq -r '.host.memory.usedPercent // 0' "$STATUS_JSON")
OBS_MEM_TOTAL_KB=$(jq -r '.host.memory.totalKB // 0' "$STATUS_JSON")
OBS_MEM_USED_KB=$(jq -r '.host.memory.usedKB // 0' "$STATUS_JSON")
OBS_PEERS=$(jq -r '.metalgo.peerCount // 0' "$STATUS_JSON")

kb_to_gb() { awk -v k="$1" 'BEGIN{printf "%.1f", k/1024/1024}'; }
kb_to_mb() { awk -v k="$1" 'BEGIN{printf "%.0f", k/1024}'; }

# === transition: metalgo (notify-gated) =================================
ORIG_METALGO=$(orig_get '.metalgo')
if [ "$OBS_METALGO" != "running" ] && [ "$ORIG_METALGO" = "running" ]; then
  body=$(printf 'コンテナ状態: %s\n対処:\n1) ssh -i ~/.ssh/<your_validator_host_key> root@VPS\n2) docker logs --tail 50 metalgo-mainnet\n3) docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml up -d\n影響: validator が consensus から脱落しうる、uptime 評価値が低下' "$OBS_METALGO")
  notify_or_keep urgent "metalgo 停止" "$body" && candidate_set '.metalgo' "\"$OBS_METALGO\""
elif [ "$OBS_METALGO" = "running" ] && [ "$ORIG_METALGO" != "running" ]; then
  notify_or_keep default "metalgo 復旧" "コンテナが running に戻りました" \
    && candidate_set '.metalgo' "\"$OBS_METALGO\""
fi

# === transition: caddy (notify-gated) ===================================
ORIG_CADDY=$(orig_get '.caddy')
if [ "$OBS_CADDY" != "running" ] && [ "$ORIG_CADDY" = "running" ]; then
  body=$(printf 'コンテナ状態: %s\n対処:\n1) docker logs --tail 50 caddy-static\n2) docker compose up -d\n影響: 公開サイト + ops dashboard ダウン、validator 本体は無事' "$OBS_CADDY")
  notify_or_keep high "Caddy 停止" "$body" && candidate_set '.caddy' "\"$OBS_CADDY\""
elif [ "$OBS_CADDY" = "running" ] && [ "$ORIG_CADDY" != "running" ]; then
  notify_or_keep default "Caddy 復旧" "サイト + ops dashboard が再稼働" \
    && candidate_set '.caddy' "\"$OBS_CADDY\""
fi

# === transition: disk (hysteresis: warn>85, ok<=80) =====================
DISK_INT=$(printf '%.0f' "$OBS_DISK_PCT" 2>/dev/null || echo 0)
ORIG_DISK=$(orig_get '.disk')
if [ "$DISK_INT" -gt 85 ] && [ "$ORIG_DISK" = "ok" ]; then
  DISK_TOTAL_GB=$(kb_to_gb "$OBS_DISK_TOTAL_KB")
  DISK_FREE_GB=$(kb_to_gb $(( OBS_DISK_TOTAL_KB - OBS_DISK_USED_KB )))
  body=$(printf '使用率: %s%% (空き %s GB / 全 %s GB)\n対処:\n1) docker exec metalgo-mainnet du -sh /data\n2) journalctl --vacuum-time=7d\n3) docker system prune\n影響: metalgo データ増加で chain 動作不能リスク' "$OBS_DISK_PCT" "$DISK_FREE_GB" "$DISK_TOTAL_GB")
  notify_or_keep high "ディスク 85% 超過" "$body" && candidate_set '.disk' '"warn"'
elif [ "$DISK_INT" -le 80 ] && [ "$ORIG_DISK" = "warn" ]; then
  notify_or_keep default "ディスク正常化" "ルート使用率 ${OBS_DISK_PCT}%" \
    && candidate_set '.disk' '"ok"'
fi

# === transition: memory (hysteresis: warn>95, ok<=90) ===================
MEM_INT=$(printf '%.0f' "$OBS_MEM_PCT" 2>/dev/null || echo 0)
ORIG_MEM=$(orig_get '.memory')
if [ "$MEM_INT" -gt 95 ] && [ "$ORIG_MEM" = "ok" ]; then
  MEM_TOTAL_MB=$(kb_to_mb "$OBS_MEM_TOTAL_KB")
  MEM_FREE_MB=$(kb_to_mb $(( OBS_MEM_TOTAL_KB - OBS_MEM_USED_KB )))
  body=$(printf '使用率: %s%% (空き %s MB / 全 %s MB)\n対処:\n1) docker stats --no-stream\n2) 必要なら metalgo 再起動\n影響: OOM killer 発動でプロセス強制終了リスク' "$OBS_MEM_PCT" "$MEM_FREE_MB" "$MEM_TOTAL_MB")
  notify_or_keep high "メモリ 95% 超過" "$body" && candidate_set '.memory' '"warn"'
elif [ "$MEM_INT" -le 90 ] && [ "$ORIG_MEM" = "warn" ]; then
  notify_or_keep default "メモリ正常化" "メモリ使用率 ${OBS_MEM_PCT}%" \
    && candidate_set '.memory' '"ok"'
fi

# === transition: peers (hysteresis: warn<10, ok>=50) ====================
ORIG_PEERS=$(orig_get '.peers')
if [ "${OBS_PEERS:-0}" -lt 10 ] && [ "$ORIG_PEERS" = "ok" ]; then
  body=$(printf '%s 接続(通常 100+)\n対処:\n1) ufw status で 9651/TCP open 確認\n2) docker logs --tail 50 metalgo-mainnet\n3) validator host ネットワーク疎通確認\n影響: validator が consensus 投票できない、uptime 評価値低下' "$OBS_PEERS")
  notify_or_keep high "ピア接続数低下" "$body" && candidate_set '.peers' '"warn"'
elif [ "${OBS_PEERS:-0}" -ge 50 ] && [ "$ORIG_PEERS" = "warn" ]; then
  notify_or_keep default "ピア接続数復旧" "${OBS_PEERS} 接続" \
    && candidate_set '.peers' '"ok"'
fi

# === observation: web URL availability (with blip-mitigation re-check) ==
# Re-probe only when prior state was ok; if already warn, skip the 30s
# sleep because the outage is already confirmed. Re-probe is part of the
# OBSERVATION phase, not the transition decision.
WEB_URL="${WEB_URL:-https://metal.freedom-yield.com}"
web_probe() {
  local s
  s=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "${WEB_URL}/health" 2>/dev/null)
  echo "${s:-000}"
}
OBS_WEB_STATUS=$(web_probe)
ORIG_WEB=$(orig_get '.web'); [ "$ORIG_WEB" = "null" ] && ORIG_WEB="ok"
if [ "$OBS_WEB_STATUS" != "200" ] && [ "$ORIG_WEB" = "ok" ]; then
  sleep 30
  OBS_WEB_STATUS=$(web_probe)
fi

# === transition: web (notify-gated) =====================================
if [ "$OBS_WEB_STATUS" != "200" ] && [ "$ORIG_WEB" = "ok" ]; then
  body=$(printf 'GET %s/health -> HTTP %s (期待: 200)\n30 秒後の再確認でも失敗 = transient blip ではない\n対処:\n1) web host に SSH してログ確認\n2) docker ps | grep caddy-static\n3) systemctl status nginx\n4) tail /var/log/nginx/error.log\n5) edge provider status page 確認(edge provider outageの可能性)\n影響: 閲覧者がサイトに到達不能、validator は無事' "$WEB_URL" "$OBS_WEB_STATUS")
  notify_or_keep high "公開サイトが応答しない" "$body" && candidate_set '.web' '"warn"'
elif [ "$OBS_WEB_STATUS" = "200" ] && [ "$ORIG_WEB" = "warn" ]; then
  notify_or_keep default "公開サイト復旧" "GET ${WEB_URL}/health -> 200 OK" \
    && candidate_set '.web' '"ok"'
fi

# === transition: api_freshness (= push pipeline health, web-gated) ======
ORIG_FRESH=$(orig_get '.api_freshness'); [ "$ORIG_FRESH" = "null" ] && ORIG_FRESH="ok"
if [ "$OBS_WEB_STATUS" = "200" ]; then
  PUBLIC_OBS=$(curl -sS --max-time 10 "${WEB_URL}/api/validator.json" 2>/dev/null \
    | jq -r '.observedAt // empty' 2>/dev/null)
  if [ -n "$PUBLIC_OBS" ]; then
    PUBLIC_OBS_EPOCH=$(date -d "$PUBLIC_OBS" +%s 2>/dev/null || echo 0)
    if [ "$PUBLIC_OBS_EPOCH" -gt 0 ]; then
      AGE_MIN=$(( ($(date +%s) - PUBLIC_OBS_EPOCH) / 60 ))
      if [ "$AGE_MIN" -gt 15 ] && [ "$ORIG_FRESH" = "ok" ]; then
        body=$(printf '公開 validator.json の observedAt が %s 分前\n(%s)\n通常は 5 分以内に更新される\n対処:\n1) /var/log/node-info.log を確認(直近の cron 実行履歴)\n2) <deploy_user> で手動 push を試す:\n   sudo -u <deploy_user> bash scripts/push-to-web-host.sh validator.json\n3) web host の <deploy_user_home>/.ssh/authorized_keys / receive-metal-push 確認\n影響: 閲覧者が古い stake / uptime / 残期間を見続ける(validator 本体は無事)' "$AGE_MIN" "$PUBLIC_OBS")
        notify_or_keep high "API freshness 異常 (push 経路停止?)" "$body" \
          && candidate_set '.api_freshness' '"warn"'
      elif [ "$AGE_MIN" -le 10 ] && [ "$ORIG_FRESH" = "warn" ]; then
        notify_or_keep default "API freshness 回復" "validator.json は ${AGE_MIN} 分前に更新済" \
          && candidate_set '.api_freshness' '"ok"'
      fi
    fi
  fi
fi

# === RPC: getCurrentValidators with RPC-failure guard ===================
# Pre-K-3 the script used // 0 // "0" defaults that silently fabricated an
# "all delegators left + endTime gone" observation when the RPC failed —
# a false-positive source. Under K-3 we explicitly detect RPC failure and
# skip the validator/delegator/period transitions for the run, leaving
# those candidate fields at their ORIGINAL_STATE values.
VALIDATOR_RESP=$(curl -sS -X POST -H 'content-type:application/json' --max-time 5 \
  --data '{"jsonrpc":"2.0","id":1,"method":"platform.getCurrentValidators","params":{}}' \
  "${METALGO_API}/ext/bc/P" 2>/dev/null)

RPC_VALID=1
if [ -z "$VALIDATOR_RESP" ] \
   || ! echo "$VALIDATOR_RESP" | jq -e '.result.validators' >/dev/null 2>&1; then
  RPC_VALID=0
  echo "[K-3] metalgo getCurrentValidators empty/unparseable; skipping validator/delegator/period transitions (= candidate fields unchanged)" >&2
fi

if [ "$RPC_VALID" = "1" ]; then
  OBS_VALIDATOR_END=$(echo "$VALIDATOR_RESP" \
    | jq -r --arg id "$NODE_ID" '.result.validators[]? | select(.nodeID == $id) | .endTime // empty' \
    | head -1)
  OBS_DELEGATOR_COUNT=$(echo "$VALIDATOR_RESP" \
    | jq -r --arg id "$NODE_ID" '.result.validators[]? | select(.nodeID == $id) | .delegatorCount // "0"' \
    | head -1)
  OBS_DELEGATOR_TOTAL_NMETAL=$(echo "$VALIDATOR_RESP" \
    | jq -r --arg id "$NODE_ID" '.result.validators[]? | select(.nodeID == $id) | .delegatorWeight // "0"' \
    | head -1)
  OBS_DELEGATOR_COUNT="${OBS_DELEGATOR_COUNT:-0}"
  OBS_DELEGATOR_TOTAL_NMETAL="${OBS_DELEGATOR_TOTAL_NMETAL:-0}"
  OBS_DELEGATOR_TOTAL_METAL=$(awk -v n="$OBS_DELEGATOR_TOTAL_NMETAL" 'BEGIN{printf "%.4f", n/1e9}' | sed -E 's/\.?0+$//')

  # === transition: delegator_count + delegator_total_nmetal (paired) ===
  # Two fields advance atomically (= either both move to OBS or both stay
  # at ORIGINAL). First-observation case (ORIG == null) is a bootstrap
  # observation — no notify, candidate gets OBS for both fields.
  ORIG_DC=$(orig_get '.delegator_count')
  if [ "$ORIG_DC" = "null" ]; then
    candidate_set '.delegator_count' "$OBS_DELEGATOR_COUNT"
    candidate_set '.delegator_total_nmetal' "$OBS_DELEGATOR_TOTAL_NMETAL"
  elif [ "$ORIG_DC" != "$OBS_DELEGATOR_COUNT" ]; then
    SELF_STAKE=$(jq -r '.stake.self // 0' "$VALIDATOR_JSON" 2>/dev/null)
    CAPACITY_METAL=$(awk -v s="$SELF_STAKE" 'BEGIN{printf "%.0f", s*4}')
    TOTAL_WEIGHT_METAL=$(awk -v s="$SELF_STAKE" -v d="$OBS_DELEGATOR_TOTAL_METAL" 'BEGIN{printf "%.4f", s+d}' | sed -E 's/\.?0+$//')
    if [ "$OBS_DELEGATOR_COUNT" -gt "${ORIG_DC:-0}" ]; then
      DIFF=$((OBS_DELEGATOR_COUNT - ORIG_DC))
      body=$(printf '+%s 件、合計 %s 件\n受入額: %s METAL\n自己 stake: %s METAL / 受入枠 %s METAL\n総 weight: %s METAL (self + delegators)' "$DIFF" "$OBS_DELEGATOR_COUNT" "$OBS_DELEGATOR_TOTAL_METAL" "$SELF_STAKE" "$CAPACITY_METAL" "$TOTAL_WEIGHT_METAL")
      if notify_or_keep high "新規 delegation 受入" "$body"; then
        candidate_set '.delegator_count' "$OBS_DELEGATOR_COUNT"
        candidate_set '.delegator_total_nmetal' "$OBS_DELEGATOR_TOTAL_NMETAL"
      fi
    else
      DIFF=$((ORIG_DC - OBS_DELEGATOR_COUNT))
      body=$(printf '-%s 件、合計 %s 件\n受入額: %s METAL\n総 weight: %s METAL (self + delegators)\n期間満了か途中解除、explorer で確認:\nhttps://explorer.metalblockchain.org/validators/%s' "$DIFF" "$OBS_DELEGATOR_COUNT" "$OBS_DELEGATOR_TOTAL_METAL" "$TOTAL_WEIGHT_METAL" "$NODE_ID")
      if notify_or_keep default "Delegation 終了" "$body"; then
        candidate_set '.delegator_count' "$OBS_DELEGATOR_COUNT"
        candidate_set '.delegator_total_nmetal' "$OBS_DELEGATOR_TOTAL_NMETAL"
      fi
    fi
  fi
  # else: ORIG_DC == OBS, no transition, candidate unchanged (= original).

  # === transition: validator_present + tracking last_known_end_time ===
  ORIG_VAL=$(orig_get '.validator_present')
  ORIG_LAST_END=$(orig_get '.last_known_end_time')
  if [ -z "$OBS_VALIDATOR_END" ] || [ "$OBS_VALIDATOR_END" = "null" ]; then
    if [ "$ORIG_VAL" = "yes" ]; then
      NOW=$(date +%s)
      EXPECTED_DROP="no"
      if [ -n "$ORIG_LAST_END" ] && [ "$ORIG_LAST_END" != "null" ] \
         && [ "$NOW" -ge "$((ORIG_LAST_END - 60))" ]; then
        EXPECTED_DROP="yes"
      fi
      if [ "$EXPECTED_DROP" = "yes" ]; then
        END_HUMAN=$(TZ=Asia/Tokyo date -d "@$ORIG_LAST_END" '+%m/%d %H:%M JST')
        body=$(printf 'NodeID: %s\n旧 endTime (%s) を予定通り通過、validator entry が current から外れました。\n再 AddValidator tx 発行までの一時的 gap です(月次サイクルの想定挙動)。\nDR drill は不要。renewal 進行中なら継続してください。' "$NODE_ID" "$END_HUMAN")
        notify_or_keep default "期間終了を確認" "$body" \
          && candidate_set '.validator_present' '"no"'
      else
        body=$(printf 'NodeID: %s\nplatform.getCurrentValidators から消失\n※ 期間切れではない時点での消失 = 不時の事象\n原因の可能性:\n1) ネットワーク到達不能 → ufw + validator host 確認\n2) staker key 破損 → DR drill 実施\n影響: 全 stake が P-Chain に解放、報酬累積停止' "$NODE_ID")
        notify_or_keep urgent "Validator が予期せず脱落" "$body" \
          && candidate_set '.validator_present' '"no"'
      fi
    fi
  else
    if [ "$ORIG_VAL" = "no" ]; then
      notify_or_keep default "Validator 再登録確認" "$NODE_ID が current validators に存在" \
        && candidate_set '.validator_present' '"yes"'
    fi
    # Pure tracking — updated unconditionally when validator is present.
    # No notify gate; the field is an observation, not a transition.
    candidate_set '.last_known_end_time' "$OBS_VALIDATOR_END"

    # === period deadline thresholds ====================================
    NOW=$(date +%s)
    SECONDS_LEFT=$(( OBS_VALIDATOR_END - NOW ))
    DAYS_LEFT=$(( SECONDS_LEFT / 86400 ))

    # Period boundary observation: reset per-period flags as a unit when a
    # new period has started. No notify (= internal state advancement based
    # on the observed period). When DAYS_LEFT <= 14, flags are left to
    # advance via individual T-N transitions.
    if [ "$DAYS_LEFT" -gt 14 ]; then
      candidate_set '.period_alert_sent' '{"7":false,"1":false,"0":false,"10min":false}'
    fi

    END_DATETIME_JP=$(TZ=Asia/Tokyo date -d "@$OBS_VALIDATOR_END" '+%m/%d %H:%M JST')
    END_TIME_JP=$(TZ=Asia/Tokyo date -d "@$OBS_VALIDATOR_END" '+%H:%M JST')
    END_DATE_JST=$(TZ=Asia/Tokyo date -d "@$OBS_VALIDATOR_END" '+%Y-%m-%d')
    DAY_BEFORE_JST=$(TZ=Asia/Tokyo date -d "@$((OBS_VALIDATOR_END - 86400))" '+%Y-%m-%d')
    WEEK_BEFORE_JST=$(TZ=Asia/Tokyo date -d "@$((OBS_VALIDATOR_END - 7*86400))" '+%Y-%m-%d')
    T_MINUS_10_JP=$(TZ=Asia/Tokyo date -d "@$((OBS_VALIDATOR_END - 600))" '+%H:%M JST')
    TODAY_JST=$(TZ=Asia/Tokyo date '+%Y-%m-%d')

    # T-7 day
    T7_SENT=$(orig_get '.period_alert_sent["7"]')
    if [ "$TODAY_JST" = "$WEEK_BEFORE_JST" ] && [ "$T7_SENT" != "true" ]; then
      body=$(printf '終了予定: %s\n来週の同時刻が期限。今週中に次回 duration(default = 月次 ~30 日)と stake 額を確定。\n参照: docs/VALIDATOR_RENEWAL.md\n影響: なし、heads-up のみ' "$END_DATETIME_JP")
      notify_or_keep default "期間終了 1 週間前" "$body" \
        && candidate_set '.period_alert_sent["7"]' 'true'
    fi
    # T-1 day
    T1_SENT=$(orig_get '.period_alert_sent["1"]')
    if [ "$TODAY_JST" = "$DAY_BEFORE_JST" ] && [ "$T1_SENT" != "true" ]; then
      body=$(printf '終了予定: 明日 %s\n明日の %s 直後に旧 stake が P-Chain FREE に解放 → AddValidator tx を発行。\n本日中の準備:\n- Metal Wallet web で Wallet 2 ロード確認\n- BLS PoP / NodeID を docs/VALIDATOR_RENEWAL.md と照合\n- stake 額・duration 確定' "$END_DATETIME_JP" "$END_TIME_JP")
      notify_or_keep default "期間終了 前日" "$body" \
        && candidate_set '.period_alert_sent["1"]' 'true'
    fi
    # T-0 day
    T0_SENT=$(orig_get '.period_alert_sent["0"]')
    if [ "$TODAY_JST" = "$END_DATE_JST" ] && [ "$DAYS_LEFT" -ge 0 ] && [ "$T0_SENT" != "true" ]; then
      body=$(printf '終了予定: 本日 %s\n%s 直後に旧 stake 解放 → AddValidator tx を発行。\n10 分前(%s 頃)に urgent 通知を再送します。\n本日中の準備:\n- Metal Wallet web を開いて Wallet 2 ロード\n- docs/VALIDATOR_RENEWAL.md Step 2 の値をコピー可能な状態に' "$END_DATETIME_JP" "$END_TIME_JP" "$T_MINUS_10_JP")
      notify_or_keep default "本日 期間終了予定" "$body" \
        && candidate_set '.period_alert_sent["0"]' 'true'
    fi
    # T-10min
    T10MIN_SENT=$(orig_get '.period_alert_sent["10min"]')
    if [ "$SECONDS_LEFT" -le 600 ] && [ "$SECONDS_LEFT" -gt -1800 ] && [ "$T10MIN_SENT" != "true" ]; then
      MIN_LEFT=$(( SECONDS_LEFT / 60 ))
      [ "$MIN_LEFT" -lt 0 ] && MIN_LEFT=0
      body=$(printf '旧 endTime: %s(残 約 %d 分)\nMetal Wallet web を開いて Wallet 2 ロード:\n1) Available (P) が新 stake 額に届いていることを目視\n2) Start Time = 発行時 epoch + 600\n3) End Time = Start Time + 2,592,000(30 日)\n4) Stake 額 / Fee 3.0%% を再確認\n5) tx broadcast → explorer で Committed 確認\n参照: docs/VALIDATOR_RENEWAL.md Step 2' "$END_DATETIME_JP" "$MIN_LEFT")
      notify_or_keep urgent "旧 stake 解放まで 10 分" "$body" \
        && candidate_set '.period_alert_sent["10min"]' 'true'
    fi
  fi
fi

# === final atomic commit (= ≤ 1 per run, skipped when no change) ========
# Canonical (= sorted-keys) JSON compare. Equal → no on-disk write, no
# mtime change. Different → mktemp + sync + atomic rename + sync dir.
# Best-effort durable (= POSIX rename is atomic for concurrent readers;
# durability across crashes depends on kernel/fs and is not advertised).
ORIG_CANON=$(jq -S . "$ORIGINAL_STATE")
CAND_CANON=$(jq -S . "$CANDIDATE_STATE")
if [ "$ORIG_CANON" = "$CAND_CANON" ]; then
  echo "[K-3] candidate == original (canonical); no commit, mtime preserved" >&2
else
  COMMIT_TMP=$(mktemp -p "$STATE_DIR" .state.commit.XXXXXX 2>/dev/null) || {
    rc_priority_set 8
    echo "[K-3] mktemp for commit failed in $STATE_DIR; original preserved" >&2
    exit "$GLOBAL_RC"
  }
  if ! cp "$CANDIDATE_STATE" "$COMMIT_TMP"; then
    rm -f "$COMMIT_TMP"
    rc_priority_set 8
    echo "[K-3] cp candidate -> commit tmp failed; original preserved" >&2
    exit "$GLOBAL_RC"
  fi
  sync "$COMMIT_TMP" 2>/dev/null || true
  if ! mv "$COMMIT_TMP" "$STATE_FILE"; then
    rm -f "$COMMIT_TMP"
    rc_priority_set 8
    echo "[K-3] atomic rename failed; original preserved" >&2
    exit "$GLOBAL_RC"
  fi
  chmod 0644 "$STATE_FILE" 2>/dev/null || true
  sync "$STATE_DIR" 2>/dev/null || true
  echo "[K-3] committed candidate to $STATE_FILE" >&2
fi

exit "$GLOBAL_RC"
