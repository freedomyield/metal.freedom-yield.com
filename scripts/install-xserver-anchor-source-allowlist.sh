#!/usr/bin/env bash
# install-xserver-anchor-source-allowlist.sh — REMOVE `anchor-source.json`
# from the Xserver-side receive-metal-push wrapper allowlist.
#
# RETIRED / FLIPPED 2026-08-06. This script originally (P2, Clean Fix Plan,
# 2026-07-01) EXTENDED the wrapper allowlist so push-to-web-host.sh could
# publish anchor-source.json over SSH. That premise died on 2026-07-07: the
# git-deploy migration made anchor-source.json committed-to-repo and
# distributed by the GitHub Actions deploy instead — push-to-web-host.sh's
# own sender allowlist has never carried `anchor-source.json` since (grep it:
# absent), and per docs/DEPLOY_OWNERSHIP_MATRIX.md this is now a permanent
# architectural decision, not a temporary gap. So the receive side accepting
# a filename the sender will never send again is pure drift — dead
# acceptance with no producer behind it, discovered 2026-08-06 alongside two
# related dead references (see docs/DEPLOY_OWNERSHIP_MATRIX.md's "no
# detached .sig exists" note).
#
# This script now does the OPPOSITE of its original behavior: it removes
# `anchor-source.json` from the wrapper's allowlist if an earlier run of the
# pre-2026-08-06 version of this script (or a manual edit) ever put it
# there. Idempotent either way — if the wrapper never had it, this is a
# no-op.
#
# Usage (operator, on Mac):
#   XSERVER_HOST=<ip>  bash scripts/install-xserver-anchor-source-allowlist.sh
#
# Test/local mode: SKIP_SSH=1 WRAPPER_FILE=<path> operates on a local file
# copy (no host contacted) — mirrors install-xserver-static-deploy-key.sh's
# SKIP_SSH convention.
#
# Safety:
#   - Backs up the wrapper before editing (receive-metal-push.bak-<timestamp>).
#   - Idempotent: absent -> "OK: ... not present" and exit 0, no changes.
#   - Narrow sed pattern targeting only the exact `anchor-source.json` case-
#     branch token (never touches `anchor-source.json.sig`, a distinct dead
#     reference tracked separately — see the DEPLOY_OWNERSHIP_MATRIX.md note).
#   - Does not touch anything else on Xserver, or other projects' vhosts.

set -euo pipefail

# ---- shared removal logic (kept in one place; both the SKIP_SSH=1 local
# path and the remote heredoc below apply this same transform to keep the
# two paths from drifting — see install_into()'s analogue in
# install-xserver-static-deploy-key.sh for the established pattern). ----
remove_from() {  # $1 = wrapper file path (local)
	local WRAPPER="$1"
	[ -f "$WRAPPER" ] || { echo "ERROR: wrapper not found: $WRAPPER" >&2; exit 4; }

	# The [|)] suffix requires "anchor-source.json" to be immediately
	# followed by a case-pattern delimiter, which a bare `.` (as in
	# anchor-source.json.sig — a separate, also-dead reference tracked in
	# docs/DEPLOY_OWNERSHIP_MATRIX.md, out of scope for this installer)
	# never satisfies. Confirmed by direct test: this check alone already
	# leaves an anchor-source.json.sig-only line untouched.
	if ! grep -qE 'anchor-source\.json[|)]' "$WRAPPER"; then
		echo "OK: allowlist does not contain anchor-source.json — nothing to remove"
		return 0
	fi

	local BAK
	BAK="${WRAPPER}.bak-$(date +%Y%m%d-%H%M%S)"
	cp -p "$WRAPPER" "$BAK"
	echo "--- backup: $BAK ---"

	# Reverses exactly what the pre-2026-08-06 version of this script
	# inserted (`s/validator\.json|/anchor-source.json|validator.json|/`),
	# plus a defensive end-of-list variant in case the token was ever placed
	# last in the case pattern instead of first.
	sed -i.tmp \
		-e 's/anchor-source\.json|//' \
		-e 's/|anchor-source\.json)/)/' \
		"$WRAPPER"
	rm -f "${WRAPPER}.tmp"

	if grep -qE 'anchor-source\.json[|)]' "$WRAPPER"; then
		echo "ERROR: anchor-source.json still present after removal attempt — manual review required." >&2
		echo "      Backup preserved at $BAK; wrapper left as edited (may be partially modified)." >&2
		exit 5
	fi

	echo "--- verify wrapper still syntactically valid bash ---"
	# Review round 1 (2026-08-06): this used to be `bash -n "$WRAPPER" &&
	# echo "syntax OK"` — a check whose FAILURE was never wired to anything.
	# bash -n's own nonzero exit was simply discarded (the `&&` only ever
	# gates the success-echo), so a syntactically broken wrapper still fell
	# through to "OK: ... still syntactically valid" and exit 0. Since this
	# wrapper is the web host's SSH forced command, shipping it broken
	# silently kills every subsequent validator-host push. Restore from the
	# backup and fail closed instead.
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
	echo "OK: anchor-source.json removed from allowlist; wrapper still syntactically valid"
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
echo "==> Using SSH key:  $XSERVER_KEY"
echo

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
# [|)] requires "anchor-source.json" to be immediately followed by a
# case-pattern delimiter; a bare "." (anchor-source.json.sig — a separate,
# also-dead reference out of scope for this installer) never satisfies
# that, so this check already leaves a .sig-only line untouched.
if ! grep -qE 'anchor-source\.json[|)]' "$WRAPPER"; then
	echo "OK: allowlist does not contain anchor-source.json — nothing to remove"
	exit 0
fi

echo "--- creating backup ---"
BAK="${WRAPPER}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$WRAPPER" "$BAK"
ls -la "$BAK"

echo
echo "--- removing anchor-source.json from allowlist ---"
sed -i.tmp \
	-e 's/anchor-source\.json|//' \
	-e 's/|anchor-source\.json)/)/' \
	"$WRAPPER"
rm -f "${WRAPPER}.tmp"

if grep -qE 'anchor-source\.json[|)]' "$WRAPPER"; then
	echo "ERROR: anchor-source.json still present after removal attempt — manual review required." >&2
	echo "      Backup preserved at $BAK; wrapper left as edited (may be partially modified)." >&2
	exit 5
fi

echo
echo "--- verify wrapper still syntactically valid bash ---"
# Review round 1 (2026-08-06): same gate fix as the local path above — a
# broken wrapper here IS the web host's SSH forced command, so restore
# from backup and fail closed rather than reporting false success.
if ! bash -n "$WRAPPER"; then
	echo "ERROR: wrapper is no longer syntactically valid bash after the edit — restoring from backup." >&2
	cp -p "$BAK" "$WRAPPER"
	echo "restored: $WRAPPER <- $BAK" >&2
	exit 6
fi
echo "syntax OK"

echo
echo "--- diff (unified) ---"
diff -u "$BAK" "$WRAPPER" || true

echo
echo "OK: anchor-source.json removed from allowlist; wrapper still syntactically valid"
echo "backup preserved: $BAK"
REMOTE_EOF

RC=$?
echo
if [ "$RC" -eq 0 ]; then
	echo "==> Xserver wrapper allowlist cleanup complete."
	echo "    anchor-source.json is served via git-deploy only; push-to-web-host.sh"
	echo "    will never send it. See docs/DEPLOY_OWNERSHIP_MATRIX.md."
else
	echo "==> Xserver wrapper update returned rc=$RC (see error above)."
	exit "$RC"
fi
