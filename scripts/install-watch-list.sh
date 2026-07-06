#!/usr/bin/env bash
# install-watch-list.sh — compose the private validator watch list consumed
# by scripts/check-watch-validators.sh.
#
# Writes ${FYD_ETC_DIR:-/etc/freedom-yield}/watch-list.json — a JSON array of
# NodeID strings. The list is HOST-LOCAL and PRIVATE by design: naming
# third-party validators we monitor in a public feed was retired with the
# 2026-06 sanitize (the old public-directory coupling also silently disabled
# the monitor for 18 days when the directory lost its watch tags).
#
# ID sources (exactly one):
#   --from-state          recover the NodeIDs from the monitor's own last
#                         known state, /var/lib/freedom-yield/
#                         watch-prev-state.json (its object keys). This is
#                         the restore path after the 2026-06-18 list loss.
#   --ids=<a,b,c>         explicit comma-separated NodeID list.
#
# Every ID must match ^NodeID-[A-Za-z0-9]+$; anything else aborts before
# writing. Idempotent: identical content → no change. A differing existing
# list is backed up beside the target as watch-list.json.bak-<UTC ts>.
# File mode 0640 root:deploy (the cron runs as deploy and only needs read).
#
# Usage (validator host, as root):
#   sudo bash scripts/install-watch-list.sh --from-state [--dry-run]
#   sudo bash scripts/install-watch-list.sh --ids=NodeID-abc,NodeID-def
#
# Env overrides (test-time):
#   FYD_ETC_DIR       target dir (default /etc/freedom-yield). When
#                     overridden, the root requirement and root:deploy
#                     ownership are waived (test harness mode).
#   FYD_STATE_FILE    state file for --from-state
#                     (default /var/lib/freedom-yield/watch-prev-state.json)
#
# Exit codes:
#   0  installed / already up to date / dry-run
#   1  usage error
#   2  not root (and FYD_ETC_DIR not overridden)
#   3  --from-state: state file missing or holds no NodeIDs
#   4  an ID failed validation (nothing written)

set -euo pipefail

ETC_DIR="${FYD_ETC_DIR:-/etc/freedom-yield}"
STATE_FILE="${FYD_STATE_FILE:-/var/lib/freedom-yield/watch-prev-state.json}"
TARGET="${ETC_DIR}/watch-list.json"

MODE=""
IDS_CSV=""
DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--from-state) MODE="state" ;;
		--ids=*)      MODE="ids"; IDS_CSV="${arg#*=}" ;;
		--dry-run)    DRY_RUN=1 ;;
		-h|--help)    sed -n '2,40p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)            echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if [ -z "$MODE" ]; then
	echo "ERROR: one of --from-state or --ids=<a,b,c> is required" >&2
	exit 1
fi

if [ "$ETC_DIR" = "/etc/freedom-yield" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: must run as root to write ${ETC_DIR} (usage: sudo bash $0 ...)" >&2
	exit 2
fi

# ---- collect IDs --------------------------------------------------------------
IDS=""
if [ "$MODE" = "state" ]; then
	if [ ! -r "$STATE_FILE" ]; then
		echo "ERROR: state file not readable: $STATE_FILE" >&2
		exit 3
	fi
	IDS="$(jq -r 'if type == "object" then keys[] else empty end' "$STATE_FILE" 2>/dev/null | grep '^NodeID-' || true)"
	if [ -z "$IDS" ]; then
		echo "ERROR: no NodeIDs recoverable from $STATE_FILE" >&2
		exit 3
	fi
else
	IDS="$(printf '%s' "$IDS_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)"
fi

# ---- validate ------------------------------------------------------------------
while IFS= read -r id; do
	if ! printf '%s' "$id" | grep -qE '^NodeID-[A-Za-z0-9]+$'; then
		echo "ERROR: invalid NodeID: '$id' — nothing written" >&2
		exit 4
	fi
done <<< "$IDS"

CONTENT="$(printf '%s\n' "$IDS" | jq -R . | jq -sS .)"
COUNT="$(printf '%s\n' "$IDS" | wc -l | tr -d ' ')"

if [ "$DRY_RUN" -eq 1 ]; then
	echo "DRY-RUN: would write ${TARGET} with ${COUNT} NodeID(s) (source: ${MODE})"
	exit 0
fi

if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$CONTENT" ]; then
	echo "ok: ${TARGET} already up to date (${COUNT} NodeID(s), no change)"
	exit 0
fi

mkdir -p "$ETC_DIR"
if [ -f "$TARGET" ]; then
	STAMP="$(date -u +%Y%m%d-%H%M%S)"
	cp -p "$TARGET" "${TARGET}.bak-${STAMP}"
	echo "backed up prior list to ${TARGET}.bak-${STAMP}"
fi

TMP="$(mktemp)"
printf '%s\n' "$CONTENT" > "$TMP"
chmod 640 "$TMP"
if [ "$ETC_DIR" = "/etc/freedom-yield" ]; then
	chown root:deploy "$TMP"
fi
mv "$TMP" "$TARGET"
echo "installed: ${TARGET} (${COUNT} NodeID(s), source: ${MODE})"
