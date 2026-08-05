#!/usr/bin/env bash
# install-xserver-subdir-allowlist.sh — teach the Xserver-side
# receive-metal-push forced-command wrapper the two allowlisted
# SUBDIRECTORY prefixes:
#
#   archive/anchor-source-<64 lowercase hex>.json
#   archive/anchor-receipt-<64 lowercase hex>.json
#   peers-history/peers-YYYY-MM-DD.json.gz
#
# CHAIN: none. PRIME_DIRECTIVE: safe (no broadcast-capable command).
#
# Motivation (2026-08-05 archive-publication audit):
#   anchor-history.jsonl publishes `archived_source_path` /
#   `archived_receipt_path` as `api/archive/anchor-source-<dag>.json` /
#   `api/archive/anchor-receipt-<tx>.json`, and peers-history-index.json's
#   entries are documented on the public data page as
#   `/api/peers-history/<filename>`. Every one of those URLs returned 404:
#   scripts/push-to-web-host.sh could only name FLAT files, and this
#   wrapper's own allowlist is likewise flat-filename-only. The sender side
#   is fixed in scripts/push-to-web-host.sh; this installer fixes the
#   receiver side. BOTH are required — either alone still yields a rejected
#   push.
#
# What it changes on the web host:
#   Inserts the repo-canonical block scripts/deploy/receive-subdir-allowlist.snippet.sh
#   at the top of /home/deploy/bin/receive-metal-push (immediately after the
#   shebang), with @@FY_SUBDIR_ROOT@@ substituted for the wrapper's real
#   public api/ directory. The block handles only the two prefixes above and
#   exits; every other command string falls through to the wrapper's
#   existing flat-filename allowlist, untouched.
#
# Safety:
#   - Idempotent: re-running when the FY-SUBDIR-ALLOWLIST-V1 marker is
#     already present prints "already installed" and exits 0.
#   - Backs the wrapper up (receive-metal-push.bak-<timestamp>) before any
#     write, and writes through the existing inode (`cat > "$WRAPPER"`) so
#     ownership/mode/authorized_keys forced-command path are preserved.
#   - Composes the new wrapper in a temp file and refuses to install it
#     unless `bash -n` accepts it AND the placeholder token is gone.
#   - Auto-detects the destination api/ directory from the wrapper itself
#     and REFUSES on ambiguity — pass FY_WEB_API_DIR=<dir> to be explicit.
#   - Touches nothing else on the host: no other wrapper, vhost, cron, or
#     project directory.
#
# Usage (operator, once, from the Mac):
#   XSERVER_HOST=<ip-or-host> bash scripts/install-xserver-subdir-allowlist.sh
#   XSERVER_HOST=<ip-or-host> FY_WEB_API_DIR=/path/to/public/api \
#     bash scripts/install-xserver-subdir-allowlist.sh
#
# Options:
#   --dry-run        Connect + inspect + print the exact diff, write nothing.
#   --print-remote   Print the remote script this installer would execute and
#                    exit. No SSH, no XSERVER_HOST needed — this is the mode
#                    the test suite uses to verify the remote half without
#                    touching a host.
#
# Env:
#   XSERVER_HOST     required (except with --print-remote)
#   XSERVER_USER     default: root
#   XSERVER_KEY      default: $HOME/.ssh/id_rsa
#   FY_WEB_API_DIR   destination api/ dir on the web host; skips auto-detect
#
# Exit codes:
#   0  installed, already installed, or dry-run/print completed
#   2  local precondition failed (snippet missing, key unreadable, bad arg)
#   3  SSH pre-check failed
#   4  wrapper not found on the web host
#   5  refused: composed wrapper failed `bash -n`, or the placeholder token
#      survived substitution
#   6  refused: destination api/ directory could not be determined
#      unambiguously (pass FY_WEB_API_DIR) or does not exist

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNIPPET_FILE="${SNIPPET_FILE:-${REPO_ROOT}/scripts/deploy/receive-subdir-allowlist.snippet.sh}"
MARKER="FY-SUBDIR-ALLOWLIST-V1"

DRY_RUN=0
PRINT_REMOTE=0
for arg in "$@"; do
	case "$arg" in
		--dry-run)      DRY_RUN=1 ;;
		--print-remote) PRINT_REMOTE=1 ;;
		-h|--help)      sed -n '2,80p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)              echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
	esac
done

# The remote half. Kept in one place so --print-remote shows byte-for-byte
# what a real run executes.
read -r -d '' REMOTE_SCRIPT <<'REMOTE_EOF' || true
set -euo pipefail

SNIPPET_B64="${1:?internal: snippet b64 arg missing}"
DRY_RUN="${2:-0}"
API_DIR_OVERRIDE="${3:-}"
MARKER="${4:?internal: marker arg missing}"

# FY_WRAPPER_PATH exists so the whole remote half can be exercised against a
# fixture wrapper in tests/install-xserver-subdir-allowlist/ without a host.
# It is never set on a real run: ssh does not forward the environment.
WRAPPER="${FY_WRAPPER_PATH:-/home/deploy/bin/receive-metal-push}"

if [ ! -f "$WRAPPER" ]; then
	echo "ERROR (4): wrapper not found: $WRAPPER" >&2
	exit 4
fi

echo "--- wrapper metadata ---"
ls -la "$WRAPPER"

echo
echo "--- idempotency check (marker: $MARKER) ---"
if grep -q "$MARKER" "$WRAPPER"; then
	echo "OK: subdirectory allowlist already installed — no changes needed"
	exit 0
fi

echo
echo "--- resolving destination api/ directory ---"
if [ -n "$API_DIR_OVERRIDE" ]; then
	API_DIR="$API_DIR_OVERRIDE"
	echo "using FY_WEB_API_DIR override: $API_DIR"
else
	CANDIDATES="$(grep -oE '/[A-Za-z0-9._/-]+/api' "$WRAPPER" | sort -u || true)"
	COUNT="$(printf '%s\n' "$CANDIDATES" | grep -c . || true)"
	if [ "$COUNT" -ne 1 ]; then
		echo "ERROR (6): could not determine the destination api/ directory unambiguously." >&2
		echo "           candidates found in $WRAPPER:" >&2
		printf '%s\n' "$CANDIDATES" | sed 's/^/             /' >&2
		echo "           re-run with FY_WEB_API_DIR=<dir> to be explicit." >&2
		exit 6
	fi
	API_DIR="$CANDIDATES"
	echo "auto-detected: $API_DIR"
fi

case "$API_DIR" in
	/*) ;;
	*)  echo "ERROR (6): api dir must be an absolute path: $API_DIR" >&2; exit 6 ;;
esac
if ! printf '%s' "$API_DIR" | grep -qE '^[A-Za-z0-9._/-]+$'; then
	echo "ERROR (6): api dir contains unexpected characters: $API_DIR" >&2
	exit 6
fi
if [ ! -d "$API_DIR" ]; then
	echo "ERROR (6): api dir does not exist on this host: $API_DIR" >&2
	exit 6
fi

echo
echo "--- materialising snippet ---"
TMP_RAW="$(mktemp)"
TMP_SNIP="$(mktemp)"
TMP_NEW="$(mktemp)"
trap 'rm -f "$TMP_RAW" "$TMP_SNIP" "$TMP_NEW"' EXIT
printf '%s' "$SNIPPET_B64" | base64 -d > "$TMP_RAW"
# Drop the snippet's standalone shebang — it is being embedded, not run —
# then substitute the destination root. Done with tail/sed-to-stdout rather
# than `sed -i`, whose in-place flag is spelled differently on BSD and GNU.
if head -n 1 "$TMP_RAW" | grep -q '^#!'; then
	tail -n +2 "$TMP_RAW" > "$TMP_SNIP"
else
	cat "$TMP_RAW" > "$TMP_SNIP"
fi
sed "s|@@FY_SUBDIR_ROOT@@|${API_DIR}|g" "$TMP_SNIP" > "$TMP_RAW"
cat "$TMP_RAW" > "$TMP_SNIP"
if grep -q '@@FY_SUBDIR_ROOT@@' "$TMP_SNIP"; then
	echo "ERROR (5): placeholder token survived substitution — refusing to install" >&2
	exit 5
fi
if ! grep -q "$MARKER" "$TMP_SNIP"; then
	echo "ERROR (5): snippet does not carry the $MARKER marker — refusing to install" >&2
	exit 5
fi
echo "snippet ready ($(wc -l < "$TMP_SNIP") lines), root=$API_DIR"

echo
echo "--- composing new wrapper ---"
if head -n 1 "$WRAPPER" | grep -q '^#!'; then
	head -n 1 "$WRAPPER"      > "$TMP_NEW"
	cat "$TMP_SNIP"          >> "$TMP_NEW"
	tail -n +2 "$WRAPPER"    >> "$TMP_NEW"
else
	cat "$TMP_SNIP"           > "$TMP_NEW"
	cat "$WRAPPER"           >> "$TMP_NEW"
fi

if ! bash -n "$TMP_NEW"; then
	echo "ERROR (5): composed wrapper failed syntax check — wrapper left untouched" >&2
	exit 5
fi
echo "composed wrapper passes bash -n"

echo
echo "--- diff (current -> proposed) ---"
diff -u "$WRAPPER" "$TMP_NEW" || true

if [ "$DRY_RUN" = "1" ]; then
	echo
	echo "DRY-RUN: wrapper NOT modified."
	exit 0
fi

echo
echo "--- backup ---"
BAK="${WRAPPER}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$WRAPPER" "$BAK"
ls -la "$BAK"

echo
echo "--- installing (in place, preserving inode/mode/owner) ---"
cat "$TMP_NEW" > "$WRAPPER"

echo
echo "--- verify ---"
bash -n "$WRAPPER" && echo "syntax OK"
grep -n "$MARKER" "$WRAPPER" | head -2
ls -la "$WRAPPER"

echo
echo "OK: subdirectory allowlist installed. Backup at $BAK"
REMOTE_EOF

if [ ! -r "$SNIPPET_FILE" ]; then
	echo "ERROR (2): snippet not readable: $SNIPPET_FILE" >&2
	exit 2
fi
if ! grep -q "$MARKER" "$SNIPPET_FILE"; then
	echo "ERROR (2): snippet at $SNIPPET_FILE does not carry the $MARKER marker" >&2
	exit 2
fi

if [ "$PRINT_REMOTE" -eq 1 ]; then
	printf '%s\n' "$REMOTE_SCRIPT"
	exit 0
fi

: "${XSERVER_HOST:?XSERVER_HOST env var required (Xserver IP or hostname)}"
XSERVER_USER="${XSERVER_USER:-root}"
XSERVER_KEY="${XSERVER_KEY:-$HOME/.ssh/id_rsa}"
FY_WEB_API_DIR="${FY_WEB_API_DIR:-}"

if [ ! -r "$XSERVER_KEY" ]; then
	echo "ERROR (2): SSH key not readable at $XSERVER_KEY (override with XSERVER_KEY=<path>)" >&2
	exit 2
fi

SNIPPET_B64="$(base64 < "$SNIPPET_FILE" | tr -d '\n')"

echo "==> Xserver target: ${XSERVER_USER}@${XSERVER_HOST}"
echo "==> Using SSH key:  $XSERVER_KEY"
echo "==> Snippet:        $SNIPPET_FILE"
[ "$DRY_RUN" -eq 1 ] && echo "==> Mode:           DRY-RUN (inspect + diff only)"
echo

# Pre-check the connection first so an auth failure cannot leave the
# wrapper half-touched.
if ! ssh -i "$XSERVER_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
	"${XSERVER_USER}@${XSERVER_HOST}" 'exit 0' 2>&1; then
	echo "ERROR (3): SSH pre-check failed — cannot reach ${XSERVER_USER}@${XSERVER_HOST}" >&2
	exit 3
fi
echo "==> SSH pre-check OK"
echo

set +e
printf '%s\n' "$REMOTE_SCRIPT" | ssh -i "$XSERVER_KEY" \
	-o BatchMode=yes -o ConnectTimeout=10 \
	"${XSERVER_USER}@${XSERVER_HOST}" \
	bash -s -- "$SNIPPET_B64" "$DRY_RUN" "$FY_WEB_API_DIR" "$MARKER"
RC=$?
set -e

echo
if [ "$RC" -eq 0 ]; then
	echo "==> Done."
	echo "    Next, from the validator host:"
	echo "      bash scripts/push-to-web-host.sh archive/anchor-receipt-<64hex>.json"
	echo "      bash scripts/push-to-web-host.sh peers-history/peers-YYYY-MM-DD.json.gz"
	echo "    then verify:"
	echo "      curl -sSI https://metal.freedom-yield.com/api/archive/anchor-receipt-<64hex>.json"
else
	echo "==> Remote step returned rc=$RC (see error above); wrapper left as-is unless the log says otherwise."
	exit "$RC"
fi
