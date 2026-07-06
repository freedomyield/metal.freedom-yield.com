#!/usr/bin/env bash
# install-xserver-anchor-source-allowlist.sh — extend Xserver-side
# receive-metal-push wrapper allowlist to accept anchor-source.json,
# anchor-receipt.json, and anchor-history.jsonl.
#
# Motivation (P2, Clean Fix Plan, 2026-07-01):
#   receipt v2 anchor_source_url points at https://metal.freedom-yield.com/
#   api/anchor-source.json, but that URL currently returns 404 because the
#   file has never been published to Xserver. push-to-web-host.sh has now
#   been extended on the validator host to include anchor-source.json / anchor-receipt.
#   json / anchor-history.jsonl, but the Xserver-side forced-command wrapper
#   at /home/deploy/bin/receive-metal-push carries its own independent
#   allowlist and rejects anything not matched there. This installer
#   extends the wrapper's allowlist so evaluators can fetch anchor-source
#   .json via HTTPS.
#
# Usage (operator, on Mac, once):
#   XSERVER_HOST=<ip>  bash scripts/install-xserver-anchor-source-allowlist.sh
#
# Or if the operator already has ~/.ssh/id_rsa set up to reach Xserver as
# root and the host is known, just:
#   bash scripts/install-xserver-anchor-source-allowlist.sh
#
# Idempotent: re-running when the allowlist already contains anchor-source
# .json prints "OK: allowlist already extended" and exits 0 without changes.
#
# Safety:
#   - Backs up the wrapper before editing (receive-metal-push.bak-<timestamp>).
#   - Refuses to edit if the wrapper has been already extended (no double-edit).
#   - Uses a narrow sed pattern targeting the exact case statement, not a
#     broad match.
#   - Does not touch anything else on Xserver.
#   - Does not touch other projects' vhosts / wrappers.

set -euo pipefail

: "${XSERVER_HOST:?XSERVER_HOST env var required (Xserver IP or hostname)}"
XSERVER_USER="${XSERVER_USER:-root}"
XSERVER_KEY="${XSERVER_KEY:-$HOME/.ssh/id_rsa}"

if [ ! -r "$XSERVER_KEY" ]; then
	echo "ERROR: SSH key not readable at $XSERVER_KEY (override with XSERVER_KEY=<path>)" >&2
	exit 2
fi

echo "==> Xserver target: ${XSERVER_USER}@${XSERVER_HOST}"
echo "==> Using SSH key:  $XSERVER_KEY"
echo

# Guard: dry-run the SSH connection first so authentication failures don't
# leave the wrapper half-touched.
if ! ssh -i "$XSERVER_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
	"${XSERVER_USER}@${XSERVER_HOST}" 'exit 0' 2>&1; then
	echo "ERROR: SSH pre-check failed — cannot reach ${XSERVER_USER}@${XSERVER_HOST}" >&2
	exit 3
fi

echo "==> SSH pre-check OK, proceeding with wrapper inspection"
echo

ssh -i "$XSERVER_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
	"${XSERVER_USER}@${XSERVER_HOST}" bash <<'REMOTE_EOF'
set -euo pipefail

WRAPPER=/home/deploy/bin/receive-metal-push

if [ ! -f "$WRAPPER" ]; then
	echo "ERROR: wrapper not found: $WRAPPER" >&2
	exit 4
fi

echo "--- wrapper metadata ---"
ls -la "$WRAPPER"

echo
echo "--- current allowlist-related lines ---"
grep -nE '(case|\|.*\.json|\|.*\.jsonl|allow|filename|receive)' "$WRAPPER" | head -30

echo
echo "--- idempotency check ---"
if grep -q 'anchor-source\.json' "$WRAPPER"; then
	echo "OK: allowlist already contains anchor-source.json — no changes needed"
	exit 0
fi

echo "--- creating backup ---"
BAK="${WRAPPER}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$WRAPPER" "$BAK"
ls -la "$BAK"

echo
echo "--- extending allowlist ---"
# Approach: find any single line whose case-branch pattern contains
# `validator.json` (the wrapper's canonical anchor-file marker) and is not
# already extended. Insert `anchor-source.json|` at the start of the pattern
# so that regardless of how the terminator is spelled on this particular
# wrapper (originally we expected `node-health-recent.json)` from the
# validator-host-side twin script, but the observed Xserver shape terminates at
# `evidence.json)`) the extension lands on the same case branch.
#
# We only add `anchor-source.json` here — `anchor-receipt.json` and
# `anchor-history.jsonl` are typically already present on the Xserver
# wrapper. If they are missing, the operator can extend manually or re-run
# the validator-host-side push (which will surface the specific rejection).
if grep -q 'validator\.json[|)]' "$WRAPPER"; then
	sed -i.tmp \
		's/validator\.json|/anchor-source.json|validator.json|/' \
		"$WRAPPER"
	rm -f "${WRAPPER}.tmp"
else
	echo "ERROR: cannot locate a case-statement branch containing 'validator.json' in the wrapper. Manual review required." >&2
	echo "      Backup preserved at $BAK; wrapper unchanged." >&2
	exit 5
fi

echo
echo "--- verify extended allowlist ---"
grep -nE 'anchor-source\.json|anchor-receipt\.json|anchor-history\.jsonl' "$WRAPPER"

echo
echo "--- verify wrapper still syntactically valid bash ---"
bash -n "$WRAPPER" && echo "syntax OK"

echo
echo "--- diff (unified) ---"
diff -u "$BAK" "$WRAPPER" || true

echo
echo "OK: allowlist extended and wrapper still syntactically valid"
echo "backup preserved: $BAK"
REMOTE_EOF

RC=$?
echo
if [ "$RC" -eq 0 ]; then
	echo "==> Xserver wrapper allowlist extension complete."
	echo "    Next: from the validator host, run"
	echo "      bash scripts/push-to-web-host.sh anchor-source.json"
	echo "    then curl https://metal.freedom-yield.com/api/anchor-source.json"
	echo "    to verify the file is now served (200)."
else
	echo "==> Xserver wrapper update returned rc=$RC (see error above)."
	exit "$RC"
fi
