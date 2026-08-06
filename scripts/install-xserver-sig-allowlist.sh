#!/usr/bin/env bash
# install-xserver-sig-allowlist.sh — REMOVE `anchor-source.json.sig`,
# `anchor-receipt.json.sig`, and `identity.json.sig` from the Xserver-side
# receive-metal-push wrapper allowlist.
#
# RETIRED / FLIPPED 2026-08-06. This script originally extended the wrapper
# allowlist so push-to-web-host.sh could publish the three `.sig` files
# over SSH, "complementing" install-xserver-anchor-source-allowlist.sh
# (itself retired the same day — see that script's header). None of the
# three targets should ever be accepted on this receive path:
#   - `anchor-source.json.sig` and `anchor-receipt.json.sig` have no
#     producer anywhere in the repo — no script signs either file, and
#     none is planned. See docs/DEPLOY_OWNERSHIP_MATRIX.md's "no detached
#     .sig exists" note (added 2026-08-06) for the verification chain that
#     makes a separate signature over either file redundant.
#   - `identity.json.sig` is real and does exist, but it is git-deploy
#     owned (produced on the operator's Mac by
#     scripts/operator-local/gen-identity.sh, committed, distributed by
#     the GitHub Actions deploy) — push-to-web-host.sh's sender allowlist
#     has never carried it and never will, the same architectural pattern
#     as anchor-source.json.
#
# All three were therefore dead acceptance on the receive side: filenames
# the sender will never send, extending the wrapper's attack surface for
# zero functional benefit.
#
# This script now does the OPPOSITE of its original behavior: it removes
# all three tokens from the wrapper's allowlist if an earlier run of the
# pre-2026-08-06 version of this script ever put them there. Idempotent —
# any token already absent is simply skipped.
#
# Usage (operator, on Mac):
#   XSERVER_HOST=<ip>  bash scripts/install-xserver-sig-allowlist.sh
#
# Test/local mode: SKIP_SSH=1 WRAPPER_FILE=<path> operates on a local file
# copy (no host contacted) — mirrors install-xserver-static-deploy-key.sh's
# SKIP_SSH convention.

set -euo pipefail

TOKENS="anchor-source.json.sig anchor-receipt.json.sig identity.json.sig"

# ---- shared removal logic (kept in one place; both the SKIP_SSH=1 local
# path and the remote heredoc below apply this same transform). ----
remove_from() {  # $1 = wrapper file path (local)
	local WRAPPER="$1"
	[ -f "$WRAPPER" ] || { echo "ERROR: wrapper not found: $WRAPPER" >&2; exit 4; }

	local any_present=0
	for tok in $TOKENS; do
		local esc="${tok//./\\.}"
		if grep -qE "${esc}[|)]" "$WRAPPER"; then
			any_present=1
		fi
	done
	if [ "$any_present" -eq 0 ]; then
		echo "OK: allowlist contains none of: $TOKENS — nothing to remove"
		return 0
	fi

	local BAK
	BAK="${WRAPPER}.bak-$(date +%Y%m%d-%H%M%S)"
	cp -p "$WRAPPER" "$BAK"
	echo "--- backup: $BAK ---"

	# Removes each token independently (mid-list with trailing pipe, or
	# end-of-list preceding the close paren) — reverses exactly what the
	# pre-2026-08-06 version of this script inserted
	# (`s/validator\.json|/anchor-source.json.sig|anchor-receipt.json.sig|identity.json.sig|validator.json|/`)
	# without assuming the three tokens stayed contiguous.
	for tok in $TOKENS; do
		local esc="${tok//./\\.}"
		sed -i.tmp \
			-e "s/${esc}|//" \
			-e "s/|${esc})/)/" \
			"$WRAPPER"
		rm -f "${WRAPPER}.tmp"
	done

	for tok in $TOKENS; do
		local esc="${tok//./\\.}"
		if grep -qE "${esc}[|)]" "$WRAPPER"; then
			echo "ERROR: $tok still present after removal attempt — manual review required." >&2
			echo "      Backup preserved at $BAK; wrapper left as edited (may be partially modified)." >&2
			exit 5
		fi
	done

	echo "--- verify wrapper still syntactically valid bash ---"
	# Review round 1 (2026-08-06): a bare `bash -n "$WRAPPER" && echo
	# "syntax OK"` never gated anything — its failure was discarded, so a
	# broken wrapper still fell through to "OK: ... still syntactically
	# valid" and exit 0. This wrapper is the web host's SSH forced command;
	# shipping it broken silently kills every subsequent validator-host
	# push. Restore from the backup and fail closed instead.
	if ! bash -n "$WRAPPER"; then
		echo "ERROR: wrapper is no longer syntactically valid bash after the edit — restoring from backup." >&2
		cp -p "$BAK" "$WRAPPER"
		echo "restored: $WRAPPER <- $BAK" >&2
		exit 6
	fi
	echo "syntax OK"

	echo "--- diff (unified) ---"
	diff -u "$BAK" "$WRAPPER" || true

	echo
	echo "OK: .sig allowlist entries removed; wrapper still syntactically valid"
	echo "backup preserved: $BAK"
}

if [ "${SKIP_SSH:-0}" = "1" ]; then
	remove_from "${WRAPPER_FILE:?WRAPPER_FILE required in SKIP_SSH mode}"
	exit 0
fi

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

TOKENS="anchor-source.json.sig anchor-receipt.json.sig identity.json.sig"

any_present=0
for tok in $TOKENS; do
	esc="${tok//./\\.}"
	if grep -qE "${esc}[|)]" "$WRAPPER"; then
		any_present=1
	fi
done
if [ "$any_present" -eq 0 ]; then
	echo "OK: allowlist contains none of: $TOKENS — nothing to remove"
	exit 0
fi

echo "--- backup ---"
BAK="${WRAPPER}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$WRAPPER" "$BAK"
ls -la "$BAK"

echo
echo "--- removing .sig allowlist entries ---"
for tok in $TOKENS; do
	esc="${tok//./\\.}"
	sed -i.tmp \
		-e "s/${esc}|//" \
		-e "s/|${esc})/)/" \
		"$WRAPPER"
	rm -f "${WRAPPER}.tmp"
done

for tok in $TOKENS; do
	esc="${tok//./\\.}"
	if grep -qE "${esc}[|)]" "$WRAPPER"; then
		echo "ERROR: $tok still present after removal attempt — manual review required." >&2
		echo "      Backup preserved at $BAK; wrapper left as edited (may be partially modified)." >&2
		exit 5
	fi
done

echo
echo "--- verify + syntax ---"
# Review round 1 (2026-08-06): same gate fix as the local path above —
# restore from backup and fail closed instead of reporting false success.
if ! bash -n "$WRAPPER"; then
	echo "ERROR: wrapper is no longer syntactically valid bash after the edit — restoring from backup." >&2
	cp -p "$BAK" "$WRAPPER"
	echo "restored: $WRAPPER <- $BAK" >&2
	exit 6
fi
echo "syntax OK"

echo
echo "--- diff ---"
diff -u "$BAK" "$WRAPPER" || true

echo
echo "OK: .sig allowlist removal complete. Backup at $BAK."
REMOTE_EOF
