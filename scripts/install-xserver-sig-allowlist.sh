#!/usr/bin/env bash
# install-xserver-sig-allowlist.sh — extend the Xserver receive-metal-push
# wrapper allowlist to accept .sig files for signed anchor artifacts.
#
# Complements install-xserver-anchor-source-allowlist.sh which added
# anchor-source.json. This installer adds:
#   anchor-source.json.sig
#   anchor-receipt.json.sig
#   identity.json.sig (defensive: already served but not currently uploaded
#                      via push-to-web-host.sh — extension future-proofs
#                      operator-triggered signature refreshes)
#
# The wrapper's existing signature branch (if any) is not disturbed. This
# installer only extends the .json branch to admit .json.sig items via the
# same case pattern.
#
# NOTE: this installer only makes .sig files accepted by the wrapper. The
# actual signing pipeline (operator private key on Mac → ssh-keygen -Y sign
# → push .sig) is separate and is not implemented today.
#
# Usage (operator, on Mac, once):
#   XSERVER_HOST=<ip>  bash scripts/install-xserver-sig-allowlist.sh
#
# Idempotent: re-running when the allowlist already contains
# anchor-source.json.sig prints "already extended" and exits 0.

set -euo pipefail

: "${XSERVER_HOST:?XSERVER_HOST env var required (Xserver IP or hostname)}"
XSERVER_USER="${XSERVER_USER:-root}"
XSERVER_KEY="${XSERVER_KEY:-$HOME/.ssh/id_rsa}"

if [ ! -r "$XSERVER_KEY" ]; then
	echo "ERROR: SSH key not readable at $XSERVER_KEY (override with XSERVER_KEY=<path>)" >&2
	exit 2
fi

echo "==> Xserver target: ${XSERVER_USER}@${XSERVER_HOST}"
if ! ssh -i "$XSERVER_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
	"${XSERVER_USER}@${XSERVER_HOST}" 'exit 0' 2>&1; then
	echo "ERROR: SSH pre-check failed" >&2
	exit 3
fi

ssh -i "$XSERVER_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
	"${XSERVER_USER}@${XSERVER_HOST}" bash <<'REMOTE_EOF'
set -euo pipefail
WRAPPER=/home/deploy/bin/receive-metal-push
[ -f "$WRAPPER" ] || { echo "ERROR: wrapper not found: $WRAPPER" >&2; exit 4; }

echo "--- wrapper metadata ---"
ls -la "$WRAPPER"

if grep -q 'anchor-source\.json\.sig' "$WRAPPER"; then
	echo "OK: allowlist already contains anchor-source.json.sig — no changes"
	exit 0
fi

echo "--- backup ---"
BAK="${WRAPPER}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$WRAPPER" "$BAK"
ls -la "$BAK"

echo
echo "--- extending allowlist to add .sig items ---"
# Add three .sig items right before validator.json| (same anchor as the
# prior installer used for shape independence).
if grep -q 'validator\.json[|)]' "$WRAPPER"; then
	sed -i.tmp \
		's/validator\.json|/anchor-source.json.sig|anchor-receipt.json.sig|identity.json.sig|validator.json|/' \
		"$WRAPPER"
	rm -f "${WRAPPER}.tmp"
else
	echo "ERROR: cannot locate 'validator.json' case-branch anchor. Manual review required." >&2
	echo "      Backup at $BAK; wrapper unchanged." >&2
	exit 5
fi

echo
echo "--- verify + syntax ---"
grep -nE 'anchor-source\.json\.sig|anchor-receipt\.json\.sig|identity\.json\.sig' "$WRAPPER"
bash -n "$WRAPPER" && echo "syntax OK"

echo
echo "--- diff ---"
diff -u "$BAK" "$WRAPPER" || true

echo
echo "OK: .sig allowlist extension complete. Backup at $BAK."
REMOTE_EOF
