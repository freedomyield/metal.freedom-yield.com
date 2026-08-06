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
#   FY_LIVE=1 bash anomaly-state-init.sh --confirm --baseline-status=running
#   FY_LIVE=1 bash anomaly-state-init.sh --confirm --baseline-status=running \
#       [--clear-quarantine] [--clear-counter]
#
# Exit codes:
#   0  success
#   1  missing required flag or invalid argument
#   2  lock dir missing (= operator hasn't run host setup; see runbook)
#   3  lock held by another process (= cron is in mid-run, retry shortly)
#   4  state write failed
#   5  state dir missing and could not be created
#   6  FY_LIVE=1 absent (see below)
#   7  scripts/lib/side-effects.sh missing (structural)
#
# WHY THIS SCRIPT REFUSES INSTEAD OF RUNNING DRY (C3 rollout, 2026-08-06)
#   Every other migrated caller treats "FY_LIVE is not 1" as a loud no-op
#   that still exits 0, because those are cron ticks and a suppressed tick is
#   a success. This script is the opposite shape: mutating state is its ENTIRE
#   purpose, it is invoked by hand, and it prints "init complete" at the end.
#   A dry run that returned 0 would tell the operator the baseline had been
#   reset when nothing had happened — and the monitor would then sit silent
#   exactly the way it did for days after 2026-06-24
#   (docs/postmortems/2026-06-anomaly-monitoring-resume.md). So a missing
#   FY_LIVE is refused loudly with exit 6 and a copy-pastable corrected
#   command, never absorbed.
#
# Constraints:
#   - No external API calls.
#   - No changes to lock file itself (= leaves it intact).
#   - --confirm is required; without it, the script prints the plan and exits 1.
#   - FY_LIVE=1 is required; without it, nothing is touched and it exits 6.

set -uo pipefail

FYD_LIB="$(cd "$(dirname "$0")" && pwd)/lib/side-effects.sh"
if [ ! -r "$FYD_LIB" ]; then
  echo "anomaly-state-init: FATAL: side-effects library not readable at $FYD_LIB" >&2
  exit 7
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

# The state dir is resolved by the library (FY_STATE_DIR, then the legacy
# ANOMALY_STATE_DIR this script's callers and runbook already use); its
# fallback is the same production default this script always had. LOCK_FILE
# and COUNTER_FILE derive from the resolved dir rather than repeating the
# literal — identical in production, sandbox-following everywhere else.
STATE_DIR="$(fyd_state_dir anomaly)" || exit $?
STATE_DIR_DEFAULT="$FYD_STATE_DIR_DEFAULT"
LOCK_FILE="${ANOMALY_LOCK_FILE:-${STATE_DIR}/locks/check-anomalies.lock}"
COUNTER_FILE="${ANOMALY_CONTENTION_COUNTER:-${STATE_DIR}/anomaly-contention-counter}"

CONFIRM=0
BASELINE_STATUS=""
CLEAR_QUARANTINE=0
CLEAR_COUNTER=0

usage() {
  cat >&2 <<EOF
Usage: FY_LIVE=1 $0 --confirm --baseline-status=running|stopped [--clear-quarantine] [--clear-counter]

Required:
  FY_LIVE=1                          Opt in to real side effects. Without it this
                                     script refuses (exit 6) rather than pretending
                                     to succeed — see scripts/lib/side-effects.sh.
  --confirm                          Operator confirmation (refuse to proceed without it)
  --baseline-status=running|stopped  Initial metalgo + caddy state for the new baseline

Optional:
  --clear-quarantine                 Remove existing \${STATE_DIR}/quarantine/* dirs
  --clear-counter                    Reset contention counter to 0

Env overrides (for fixture / test only):
  FY_STATE_DIR                       canonical state dir (highest precedence)
  ANOMALY_STATE_DIR                  legacy state dir  (default: $STATE_DIR_DEFAULT)
  ANOMALY_LOCK_FILE                  default: \${STATE_DIR}/locks/check-anomalies.lock
                                     (resolved now: $LOCK_FILE)
  ANOMALY_CONTENTION_COUNTER         default: \${STATE_DIR}/anomaly-contention-counter
                                     (resolved now: $COUNTER_FILE)

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

# FYD-GATE(refusal) — every write below this line is covered by the hard gate
# that follows, which is why this file carries no per-write fyd_live_*
# wrappers. Asserted by tests/side-effects-callers/test-monitoring-side-effects.sh,
# which requires that no write precedes this marker.
# --- FY_LIVE gate: refuse, do not run dry (see the header for why) ---------
# Placed AFTER argument validation so a typo still reports itself as a typo
# (exit 1), and BEFORE the first write of any kind — lock file included — so
# a refused run leaves the host byte-identical.
if ! fyd_is_live; then
  echo "ERROR: FY_LIVE=1 is required (currently: FY_LIVE=${FY_LIVE:-<unset>})." >&2
  echo "  This script exists only to mutate state. A dry run would print" >&2
  echo "  'init complete' while changing nothing, and the anomaly monitor" >&2
  echo "  would stay silently dead. Refusing instead." >&2
  echo "  Re-run as:" >&2
  echo "    FY_LIVE=1 ANOMALY_STATE_DIR=${STATE_DIR} bash $0 $*" >&2
  exit 6
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
  FY_LIVE=1 ANOMALY_STATE_DIR=$STATE_DIR bash scripts/check-anomalies.sh; echo rc=\$?
  (drop FY_LIVE=1 for a read-only dry pass — it prints "DRY: would …" for
   every side effect it would have performed and touches nothing)

Lock is released automatically on script exit.
EOF

# fd 9 closes on exit → flock releases.
exit 0
