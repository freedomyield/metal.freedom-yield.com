#!/usr/bin/env bash
# anomaly-state-init.sh — operator-driven baseline state initialiser for the
# anomaly notification pipeline. See docs/MONITORING_OPS.md §7 for the design.
#
# This script MUST NOT be invoked by cron. It is the single explicit path for:
#   - bootstrapping the state file on a fresh host
#   - resetting the state file after a corruption was triaged
#   - clearing the missing-marker so future re-disappearance re-notifies
#   - (optional) wiping prior quarantine dirs
#   - (optional) resetting the contention counter
#
# Concurrency: this script acquires the SAME ANOMALY_LOCK_FILE that
# check-anomalies.sh uses, non-blocking. If the cron is mid-run, init refuses
# to proceed and exits non-zero without touching state. The lock file itself
# is NEVER deleted — flock holds the fd, not the file entry.
#
# Usage:
#   bash anomaly-state-init.sh --confirm --baseline-status=running
#   bash anomaly-state-init.sh --confirm --baseline-status=running \
#       [--clear-quarantine] [--clear-counter]
#
# Exit codes:
#   0  success
#   1  missing required flag or invalid argument
#   2  lock dir missing (= operator hasn't run host setup; see runbook)
#   3  lock held by another process (= cron is in mid-run, retry shortly)
#   4  state write failed
#   5  state dir missing and could not be created
#
# Constraints:
#   - No external API calls.
#   - No changes to lock file itself (= leaves it intact).
#   - --confirm is required; without it, the script prints the plan and exits 1.

set -uo pipefail

STATE_DIR_DEFAULT="/var/lib/freedom-yield"
LOCK_FILE_DEFAULT="/var/lib/freedom-yield/locks/check-anomalies.lock"
COUNTER_DEFAULT="/var/lib/freedom-yield/anomaly-contention-counter"

STATE_DIR="${ANOMALY_STATE_DIR:-$STATE_DIR_DEFAULT}"
LOCK_FILE="${ANOMALY_LOCK_FILE:-$LOCK_FILE_DEFAULT}"
COUNTER_FILE="${ANOMALY_CONTENTION_COUNTER:-$COUNTER_DEFAULT}"

CONFIRM=0
BASELINE_STATUS=""
CLEAR_QUARANTINE=0
CLEAR_COUNTER=0

usage() {
  cat >&2 <<EOF
Usage: $0 --confirm --baseline-status=running|stopped [--clear-quarantine] [--clear-counter]

Required:
  --confirm                          Operator confirmation (refuse to proceed without it)
  --baseline-status=running|stopped  Initial metalgo + caddy state for the new baseline

Optional:
  --clear-quarantine                 Remove existing \${STATE_DIR}/quarantine/* dirs
  --clear-counter                    Reset contention counter to 0

Env overrides (for fixture / test only):
  ANOMALY_STATE_DIR                  default: $STATE_DIR_DEFAULT
  ANOMALY_LOCK_FILE                  default: $LOCK_FILE_DEFAULT
  ANOMALY_CONTENTION_COUNTER         default: $COUNTER_DEFAULT

See docs/MONITORING_OPS.md §7 for design and §10 for the host setup runbook.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --confirm) CONFIRM=1 ;;
    --baseline-status=running) BASELINE_STATUS="running" ;;
    --baseline-status=stopped) BASELINE_STATUS="stopped" ;;
    --baseline-status=*) echo "ERROR: invalid --baseline-status value (must be 'running' or 'stopped')" >&2; usage; exit 1 ;;
    --clear-quarantine) CLEAR_QUARANTINE=1 ;;
    --clear-counter) CLEAR_COUNTER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $arg" >&2; usage; exit 1 ;;
  esac
done

if [ "$CONFIRM" -ne 1 ]; then
  echo "Plan (no changes will be made without --confirm):" >&2
  echo "  state dir       : $STATE_DIR" >&2
  echo "  state file      : $STATE_DIR/anomaly-state.json" >&2
  echo "  missing marker  : $STATE_DIR/.missing-notified.marker (will be removed if present)" >&2
  echo "  lock file       : $LOCK_FILE (will be acquired but NOT deleted)" >&2
  echo "  baseline status : ${BASELINE_STATUS:-<not specified>}" >&2
  echo "  clear quarantine: $([ "$CLEAR_QUARANTINE" -eq 1 ] && echo yes || echo no)" >&2
  echo "  clear counter   : $([ "$CLEAR_COUNTER" -eq 1 ] && echo yes || echo no)" >&2
  echo "" >&2
  echo "Refusing to proceed without --confirm. Re-run with --confirm to apply." >&2
  exit 1
fi

if [ -z "$BASELINE_STATUS" ]; then
  echo "ERROR: --baseline-status is required (running or stopped)" >&2
  usage
  exit 1
fi

LOCK_DIR="$(dirname "$LOCK_FILE")"
if [ ! -d "$LOCK_DIR" ]; then
  echo "ERROR: lock dir missing: $LOCK_DIR" >&2
  echo "Run host setup first (= docs/MONITORING_OPS.md §10):" >&2
  echo "  sudo mkdir -p $LOCK_DIR && sudo chown deploy:deploy $LOCK_DIR && sudo chmod 0700 $LOCK_DIR" >&2
  exit 2
fi

if ! exec 9>"$LOCK_FILE"; then
  echo "ERROR: cannot open lock file: $LOCK_FILE" >&2
  exit 2
fi
if ! flock -n 9; then
  echo "ERROR: lock held by another process ($LOCK_FILE) — cron may be mid-run; retry shortly" >&2
  exit 3
fi
echo "[init] lock acquired ($LOCK_FILE)" >&2

# Ensure state dir exists with correct ownership (= caller is the deploy user
# in production; we do not chown here because the script may be invoked by
# the deploy user directly, in which case mkdir naturally owns).
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  echo "ERROR: cannot create state dir: $STATE_DIR" >&2
  exit 5
fi
chmod 0750 "$STATE_DIR" 2>/dev/null || true

STATE_FILE="$STATE_DIR/anomaly-state.json"
MISSING_MARKER="$STATE_DIR/.missing-notified.marker"
QUAR_DIR="$STATE_DIR/quarantine"

# Build the baseline JSON. metalgo/caddy take the operator-declared value;
# all other gate fields default to "ok" / "yes" / null + alert flags false.
TMP=$(mktemp -p "$STATE_DIR" .state.init.XXXXXX 2>/dev/null) || {
  echo "ERROR: mktemp failed in $STATE_DIR" >&2
  exit 4
}
cat > "$TMP" <<EOF
{
  "metalgo": "$BASELINE_STATUS",
  "caddy": "$BASELINE_STATUS",
  "disk": "ok",
  "memory": "ok",
  "peers": "ok",
  "web": "ok",
  "api_freshness": "ok",
  "validator_present": "yes",
  "last_known_end_time": null,
  "delegator_count": null,
  "delegator_total_nmetal": null,
  "period_alert_sent": { "7": false, "1": false, "0": false, "10min": false }
}
EOF

if ! jq -e . "$TMP" >/dev/null 2>&1; then
  rm -f "$TMP"
  echo "ERROR: generated baseline JSON is invalid (bug in init script)" >&2
  exit 4
fi

# Best-effort durability.
sync "$TMP" 2>/dev/null || true
if ! mv "$TMP" "$STATE_FILE"; then
  rm -f "$TMP"
  echo "ERROR: rename of $TMP -> $STATE_FILE failed" >&2
  exit 4
fi
chmod 0640 "$STATE_FILE" 2>/dev/null || true
sync "$STATE_DIR" 2>/dev/null || true
echo "[init] baseline state written: $STATE_FILE" >&2

# Missing-marker removal MUST follow successful state write. If we cleared
# the marker before writing the baseline, a crash mid-way would leave the
# host in a "state file missing + marker absent" condition, triggering a
# duplicate notify on the next cron tick.
MARKER_REMOVED=no
if [ -f "$MISSING_MARKER" ]; then
  if rm -f "$MISSING_MARKER"; then
    MARKER_REMOVED=yes
    echo "[init] missing marker removed ($MISSING_MARKER)" >&2
  else
    echo "WARN: failed to remove missing marker $MISSING_MARKER (state was written; manual cleanup needed)" >&2
  fi
fi

# Optional clears.
QUAR_CLEARED=no
if [ "$CLEAR_QUARANTINE" -eq 1 ] && [ -d "$QUAR_DIR" ]; then
  if find "$QUAR_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
    QUAR_CLEARED=yes
    echo "[init] quarantine dirs cleared ($QUAR_DIR)" >&2
  else
    echo "WARN: failed to clear quarantine dirs at $QUAR_DIR (state was written)" >&2
  fi
fi

COUNTER_RESET=no
if [ "$CLEAR_COUNTER" -eq 1 ]; then
  if printf '0\n' > "$COUNTER_FILE" 2>/dev/null; then
    COUNTER_RESET=yes
    echo "[init] contention counter reset to 0 ($COUNTER_FILE)" >&2
  else
    echo "WARN: failed to reset counter $COUNTER_FILE (state was written)" >&2
  fi
fi

cat >&2 <<EOF

=== init complete ===
  state file       : $STATE_FILE
  baseline status  : $BASELINE_STATUS
  lock file (kept) : $LOCK_FILE
  missing marker   : $([ "$MARKER_REMOVED" = "yes" ] && echo "removed" || echo "not present (no action)")
  quarantine clear : $QUAR_CLEARED
  counter reset    : $COUNTER_RESET

Next: verify with
  jq . $STATE_FILE
  bash scripts/check-anomalies.sh; echo rc=\$?

Lock is released automatically on script exit.
EOF

# fd 9 closes on exit → flock releases.
exit 0
