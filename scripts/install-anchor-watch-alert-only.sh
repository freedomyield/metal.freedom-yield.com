#!/usr/bin/env bash
# install-anchor-watch-alert-only.sh — re-enable the anchor-watch cron in
# DETECTION / ALERT-ONLY mode (option a). Run as root on the validator host.
#
# Points watch-anchor-events.sh's DRIVER at notify-anchor-transition.sh via the
# ANCHOR_DRIVER env, so a presence transition fires an ntfy push (run the MANUAL
# anchor from the Mac) instead of the stranded Hetzner auto-broadcast path.
# BROADCASTS NOTHING. Idempotent. Removes the .disabled-cycle-transition marker.
set -euo pipefail

REPO="${REPO:-/home/deploy/metal.freedom-yield.com}"
CRON=/etc/cron.d/metal-anchor-watch
DRIVER="${REPO}/scripts/notify-anchor-transition.sh"
NOTIFY="${REPO}/scripts/notify.sh"
TOPIC=/etc/freedom-yield/ntfy-topic

# --- prerequisites (fail closed if the alert-only driver is not deployed) ---
# sync-to-validator-host.sh does not preserve the +x bit, so ensure it here
# (watch-anchor-events.sh execs the driver directly and requires it executable).
[ -f "$DRIVER" ] || { echo "ERROR: notify driver missing: $DRIVER" >&2
                      echo "       run  sync-to-validator-host.sh  from the Mac first." >&2; exit 1; }
chmod +x "$DRIVER" "${REPO}/scripts/watch-anchor-events.sh"
[ -x "$DRIVER" ] || { echo "ERROR: could not make notify driver executable: $DRIVER" >&2; exit 1; }
[ -x "$NOTIFY" ] || { echo "ERROR: notify.sh missing/not executable: $NOTIFY" >&2; exit 1; }
if [ ! -r "$TOPIC" ] || [ ! -s "$TOPIC" ]; then
	echo "WARN: ntfy topic not configured at $TOPIC — alerts will no-op (non-fatal)." >&2
fi

# --- write the cron in alert-only mode ---
TMP="$(mktemp)"
cat > "$TMP" <<EOF
# Phase α anchor watcher — DETECTION / ALERT-ONLY mode (2026-07-04).
# Polls metalgo for our NodeID validator-presence flag every 5 min. On a
# transition (cyclestart / cycleend) it dispatches to notify-anchor-transition.sh,
# which fires an ntfy push telling the operator to run the MANUAL anchor from the
# Mac. BROADCASTS NOTHING from this host — metalfreedom@anchor key is Mac-only.
# State file: /var/lib/freedom-yield/anchor-watcher-state.json
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
ANCHOR_DRIVER=${DRIVER}
*/5 * * * * deploy cd ${REPO} && bash scripts/watch-anchor-events.sh >> /var/log/anchor-watch.log 2>&1
EOF
install -o root -g root -m 644 "$TMP" "$CRON"
rm -f "$TMP"
echo "✓ wrote $CRON (alert-only, ANCHOR_DRIVER=notify-anchor-transition.sh)"

# --- remove disabled marker(s) left by the transition ---
shopt -s nullglob
for f in "${CRON}".disabled-cycle-transition-*; do
	rm -f "$f"; echo "✓ removed disabled marker: $f"
done
shopt -u nullglob

echo
echo "── active cron (comments stripped) ──"
grep -vE '^[[:space:]]*#' "$CRON" | sed 's/^/  /'
echo
echo "Re-enabled in ALERT-ONLY mode. Next presence transition → ntfy push (no broadcast)."
echo "Anchors remain Mac-signed + manually broadcast."
