#!/usr/bin/env bash
# tests/push-to-web-host/test-push-to-web-host.sh — functional suite for
# scripts/push-to-web-host.sh.
#
# CHAIN: none — no network. A recording `ssh` stub is prepended onto PATH so
# the script's real `cat "$SOURCE" | ssh ... "$TARGET" "$FILENAME"` line
# never opens a socket; the stub just logs its argv + stdin byte count and
# exits with a caller-controlled code. PRIME_DIRECTIVE: safe.
#
# Context: scripts/push-to-web-host.sh:53-120 is the feed-publish path that
# had a real prod regression (commit f0b535d — a de-brand pass rewrote a
# functional default to a placeholder). Until now it was only guarded by a
# narrow static string-grep (tests/config-paths/test-no-placeholder-paths.sh)
# that checks the source text but never exercises the script's actual
# runtime behaviour. This suite drives the script end-to-end against a
# fixture REPO_BASE and asserts:
#   - allowlist enforcement: an allowlisted filename is pushed, a filename
#     NOT on the allowlist is rejected before ssh is ever invoked
#   - the <16-64hex>.ics token pattern is enforced (valid accepted, invalid
#     rejected) independent of the static allowlist branch
#   - argument handling: missing filename arg fails closed
#   - preflight checks: missing source file / missing ssh key fail closed,
#     each without invoking ssh
#   - WEB_HOST resolution from WEB_HOST_FILE when WEB_HOST is unset, with
#     whitespace trimmed
#   - subdirectory allowlist (added 2026-08-05): the two accepted prefixes
#     (archive/, peers-history/) push with the subdirectory-qualified name
#     intact as the remote command string, while path traversal, absolute
#     paths, shell metacharacters, unknown prefixes, nested paths, and
#     malformed basenames are all rejected before ssh is ever invoked
#
# Usage:
#   bash tests/push-to-web-host/test-push-to-web-host.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/push-to-web-host.sh"

if [ ! -f "$SCRIPT" ]; then
	echo "FATAL: script not found at $SCRIPT" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

BASE=""; STUBDIR=""; FIXTURE_REPO=""; KEY_FILE=""; SSH_LOG=""; NO_HOST_FILE=""
PEERS_STATE_DIR=""
# Content-addressed archive names are 64 lowercase hex. Two distinct values
# so a test can prove the basename is carried through verbatim.
DAG_HEX="$(printf 'a%.0s' $(seq 1 64))"
TX_HEX="$(printf 'b%.0s' $(seq 1 64))"
setup() {
	BASE="$(mktemp -d -t push-to-web-host-test.XXXXXX)"
	STUBDIR="$BASE/bin"
	FIXTURE_REPO="$BASE/repo"
	KEY_FILE="$BASE/web_push_key"
	SSH_LOG="$BASE/ssh-invocations.log"
	NO_HOST_FILE="$BASE/no-such-web-host-file"   # deliberately absent

	PEERS_STATE_DIR="$BASE/state/peers-history"

	mkdir -p "$STUBDIR" "$FIXTURE_REPO/public/api" "$FIXTURE_REPO/public/calendar" \
		"$FIXTURE_REPO/public/api/archive" "$PEERS_STATE_DIR"

	# Recording ssh stub. Emulates the remote forced-command wrapper enough
	# to let the script believe the push succeeded/failed, and records what
	# it was invoked with (argv + stdin byte count) so tests can assert on
	# allowlist/arg behaviour without ever opening a socket.
	cat > "$STUBDIR/ssh" <<'STUBEOF'
#!/usr/bin/env bash
{
	printf 'ARGV:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
	printf 'STDIN_BYTES: %s\n' "$(wc -c | tr -d ' ')"
} >> "$SSH_STUB_LOG"
exit "${STUB_EXIT:-0}"
STUBEOF
	chmod +x "$STUBDIR/ssh"

	# Real content for every allowlisted JSON/JSONL feed name we exercise.
	printf '{"ok":true}\n' > "$FIXTURE_REPO/public/api/validator.json"
	printf '{"ok":true}\n' > "$FIXTURE_REPO/public/calendar/deadbeefdeadbeefdeadbeefdeadbeef.ics"

	# Subdirectory fixtures: R18 archives live in the repo's public/api/archive/,
	# daily peer snapshots live in the host state dir (NOT the repo).
	printf '{"archived":"source"}\n'  > "$FIXTURE_REPO/public/api/archive/anchor-source-${DAG_HEX}.json"
	printf '{"archived":"receipt"}\n' > "$FIXTURE_REPO/public/api/archive/anchor-receipt-${TX_HEX}.json"
	printf '{"peers":[]}\n' | gzip -c > "$PEERS_STATE_DIR/peers-2026-08-05.json.gz"

	printf 'dummy-ed25519-key-material\n' > "$KEY_FILE"
}
teardown() { rm -rf "$BASE"; BASE=""; }

# run_push <filename>
# Always pins REPO_BASE / WEB_PUSH_KEY / PATH / SSH stub log, and defaults
# WEB_HOST_FILE to a path that does not exist so the operator's real
# /etc/freedom-yield/web-host default is never consulted from this suite.
#
# WEB_HOST default uses `-` (not `:-`) so a caller who explicitly sets
# WEB_HOST="" (case 8, to exercise the WEB_HOST_FILE fallback) is honoured —
# only a genuinely UNSET WEB_HOST picks up the fixture default.
run_push() {
	PATH="$STUBDIR:$PATH" \
	REPO_BASE="$FIXTURE_REPO" \
	WEB_PUSH_KEY="$KEY_FILE" \
	WEB_HOST="${WEB_HOST-deploy@203.0.113.11}" \
	WEB_HOST_FILE="${WEB_HOST_FILE:-$NO_HOST_FILE}" \
	PEERS_HISTORY_DIR="${PEERS_HISTORY_DIR:-$PEERS_STATE_DIR}" \
	SSH_STUB_LOG="$SSH_LOG" \
	STUB_EXIT="${STUB_EXIT:-0}" \
		bash "$SCRIPT" "$@"
}

ssh_was_invoked() { [ -s "$SSH_LOG" ]; }

# ---- case 1: allowlisted JSON feed -> pushed, ssh invoked correctly -----------
setup
OUT="$(run_push validator.json 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "allowlisted: validator.json -> exit 0" \
	|| bad "allowlisted: expected exit 0, got $RC (out: $OUT)"
ssh_was_invoked \
	&& ok "allowlisted: ssh stub was invoked" \
	|| bad "allowlisted: ssh stub was NOT invoked"
grep -q '\[deploy@203.0.113.11\] \[validator.json\]' "$SSH_LOG" \
	&& ok "allowlisted: ssh invoked with correct target + filename as final args" \
	|| bad "allowlisted: ssh argv missing expected target/filename (log: $(cat "$SSH_LOG" 2>/dev/null))"
EXPECT_BYTES=$(wc -c < "$FIXTURE_REPO/public/api/validator.json" | tr -d ' ')
grep -q "STDIN_BYTES: ${EXPECT_BYTES}" "$SSH_LOG" \
	&& ok "allowlisted: full source content piped to ssh stdin ($EXPECT_BYTES bytes)" \
	|| bad "allowlisted: stdin byte count mismatch (expected $EXPECT_BYTES, log: $(cat "$SSH_LOG" 2>/dev/null))"
teardown

# ---- case 2: filename NOT on the allowlist -> rejected, ssh never invoked ----
setup
OUT="$(run_push secrets.env 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "not-allowlisted: secrets.env -> nonzero exit" \
	|| bad "not-allowlisted: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'unrecognized filename' \
	&& ok "not-allowlisted: error names the filename as unrecognized" \
	|| bad "not-allowlisted: missing 'unrecognized filename' (out: $OUT)"
ssh_was_invoked \
	&& bad "not-allowlisted: ssh stub was invoked (must fail BEFORE any push attempt)" \
	|| ok "not-allowlisted: ssh stub was never invoked"
teardown

# ---- case 3: valid <16-64hex>.ics token -> accepted, pushed -------------------
setup
TOKEN="deadbeefdeadbeefdeadbeefdeadbeef.ics"
OUT="$(run_push "$TOKEN" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "ics-token: valid hex token -> exit 0" \
	|| bad "ics-token: expected exit 0, got $RC (out: $OUT)"
grep -q "\\[${TOKEN}\\]" "$SSH_LOG" \
	&& ok "ics-token: ssh invoked with the token filename" \
	|| bad "ics-token: ssh argv missing token filename (log: $(cat "$SSH_LOG" 2>/dev/null))"
teardown

# ---- case 4: invalid ics token (too short / non-hex) -> rejected, no push ----
setup
OUT="$(run_push "not-a-valid-token.ics" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "ics-token: malformed token -> nonzero exit" \
	|| bad "ics-token: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'must be 16-64 hex chars' \
	&& ok "ics-token: error explains the hex-length rule" \
	|| bad "ics-token: missing hex-length error (out: $OUT)"
ssh_was_invoked \
	&& bad "ics-token: ssh stub was invoked for a malformed token" \
	|| ok "ics-token: ssh stub was never invoked for a malformed token"
teardown

# ---- case 5: missing filename argument -> fails closed, no push --------------
setup
OUT="$(run_push 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "missing-arg: no filename -> nonzero exit" \
	|| bad "missing-arg: expected nonzero exit, got 0"
echo "$OUT" | grep -qi 'usage' \
	&& ok "missing-arg: error includes usage text" \
	|| bad "missing-arg: missing usage text (out: $OUT)"
ssh_was_invoked \
	&& bad "missing-arg: ssh stub was invoked with no filename supplied" \
	|| ok "missing-arg: ssh stub was never invoked"
teardown

# ---- case 6: allowlisted filename but source file absent -> fails closed -----
setup
rm -f "$FIXTURE_REPO/public/api/validator.json"
OUT="$(run_push validator.json 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "missing-source: absent source file -> nonzero exit" \
	|| bad "missing-source: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'source not found' \
	&& ok "missing-source: error names the missing source" \
	|| bad "missing-source: missing 'source not found' (out: $OUT)"
ssh_was_invoked \
	&& bad "missing-source: ssh stub was invoked despite no source file" \
	|| ok "missing-source: ssh stub was never invoked"
teardown

# ---- case 7: source present but ssh key file absent -> fails closed ----------
setup
rm -f "$KEY_FILE"
OUT="$(run_push validator.json 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "missing-key: absent ssh key -> nonzero exit" \
	|| bad "missing-key: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'ssh key not found' \
	&& ok "missing-key: error names the missing key" \
	|| bad "missing-key: missing 'ssh key not found' (out: $OUT)"
ssh_was_invoked \
	&& bad "missing-key: ssh stub was invoked despite no key file" \
	|| ok "missing-key: ssh stub was never invoked"
teardown

# ---- case 8: WEB_HOST resolved from WEB_HOST_FILE (whitespace trimmed) -------
setup
HOST_FILE="$BASE/web-host-file"
printf ' deploy@203.0.113.42 \n' > "$HOST_FILE"
WEB_HOST=""              # explicitly empty: script must fall back to the file
WEB_HOST_FILE="$HOST_FILE"
OUT="$(run_push validator.json 2>&1)"
RC=$?
unset WEB_HOST WEB_HOST_FILE
[ "$RC" -eq 0 ] \
	&& ok "host-file: WEB_HOST_FILE fallback -> exit 0" \
	|| bad "host-file: expected exit 0, got $RC (out: $OUT)"
grep -q '\[deploy@203.0.113.42\]' "$SSH_LOG" \
	&& ok "host-file: target resolved from WEB_HOST_FILE with whitespace trimmed" \
	|| bad "host-file: target not resolved correctly (log: $(cat "$SSH_LOG" 2>/dev/null))"
teardown

# ==============================================================================
# Subdirectory allowlist (2026-08-05). Two prefixes only — archive/ and
# peers-history/ — each with a strict basename pattern. These URLs are
# already advertised by anchor-history.jsonl (archived_source_path /
# archived_receipt_path) and peers-history-index.json, and every one of them
# returned 404 because this script could not name a file inside a
# subdirectory at all.
# ==============================================================================

# ---- case 9: archive/anchor-source-<64hex>.json -> pushed --------------------
setup
NAME="archive/anchor-source-${DAG_HEX}.json"
OUT="$(run_push "$NAME" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "subdir archive: anchor-source archive -> exit 0" \
	|| bad "subdir archive: expected exit 0, got $RC (out: $OUT)"
grep -q "\\[${NAME}\\]" "$SSH_LOG" \
	&& ok "subdir archive: subdirectory-qualified name is the remote command string" \
	|| bad "subdir archive: ssh argv missing '$NAME' (log: $(cat "$SSH_LOG" 2>/dev/null))"
EXPECT_BYTES=$(wc -c < "$FIXTURE_REPO/public/api/archive/anchor-source-${DAG_HEX}.json" | tr -d ' ')
grep -q "STDIN_BYTES: ${EXPECT_BYTES}" "$SSH_LOG" \
	&& ok "subdir archive: content read from public/api/archive/ ($EXPECT_BYTES bytes)" \
	|| bad "subdir archive: stdin byte mismatch (expected $EXPECT_BYTES, log: $(cat "$SSH_LOG" 2>/dev/null))"
teardown

# ---- case 10: archive/anchor-receipt-<64hex>.json -> pushed ------------------
setup
NAME="archive/anchor-receipt-${TX_HEX}.json"
OUT="$(run_push "$NAME" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "subdir archive: anchor-receipt archive -> exit 0" \
	|| bad "subdir archive: expected exit 0, got $RC (out: $OUT)"
grep -q "\\[${NAME}\\]" "$SSH_LOG" \
	&& ok "subdir archive: receipt basename carried through verbatim (tx_id-keyed)" \
	|| bad "subdir archive: ssh argv missing '$NAME' (log: $(cat "$SSH_LOG" 2>/dev/null))"
teardown

# ---- case 11: peers-history/<snapshot> resolved from the host state dir ------
setup
NAME="peers-history/peers-2026-08-05.json.gz"
OUT="$(run_push "$NAME" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "subdir peers-history: snapshot -> exit 0" \
	|| bad "subdir peers-history: expected exit 0, got $RC (out: $OUT)"
grep -q "\\[${NAME}\\]" "$SSH_LOG" \
	&& ok "subdir peers-history: subdirectory-qualified name is the remote command string" \
	|| bad "subdir peers-history: ssh argv missing '$NAME' (log: $(cat "$SSH_LOG" 2>/dev/null))"
EXPECT_BYTES=$(wc -c < "$PEERS_STATE_DIR/peers-2026-08-05.json.gz" | tr -d ' ')
grep -q "STDIN_BYTES: ${EXPECT_BYTES}" "$SSH_LOG" \
	&& ok "subdir peers-history: content read from the host state dir, not the repo" \
	|| bad "subdir peers-history: stdin byte mismatch (expected $EXPECT_BYTES, log: $(cat "$SSH_LOG" 2>/dev/null))"
teardown

# ---- case 12: peers-history falls back to a repo-local staging copy ----------
setup
rm -f "$PEERS_STATE_DIR/peers-2026-08-05.json.gz"
mkdir -p "$FIXTURE_REPO/public/api/peers-history"
printf '{"staged":true}\n' | gzip -c > "$FIXTURE_REPO/public/api/peers-history/peers-2026-08-05.json.gz"
OUT="$(run_push peers-history/peers-2026-08-05.json.gz 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "subdir peers-history: repo-local staging fallback -> exit 0" \
	|| bad "subdir peers-history: fallback expected exit 0, got $RC (out: $OUT)"
EXPECT_BYTES=$(wc -c < "$FIXTURE_REPO/public/api/peers-history/peers-2026-08-05.json.gz" | tr -d ' ')
grep -q "STDIN_BYTES: ${EXPECT_BYTES}" "$SSH_LOG" \
	&& ok "subdir peers-history: fallback read the repo-local copy" \
	|| bad "subdir peers-history: fallback byte mismatch (expected $EXPECT_BYTES, log: $(cat "$SSH_LOG" 2>/dev/null))"
teardown

# ---- case 13: path traversal -> rejected before ssh --------------------------
setup
OUT="$(run_push "archive/../../etc/passwd" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "traversal: archive/../../etc/passwd -> nonzero exit" \
	|| bad "traversal: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'path traversal rejected' \
	&& ok "traversal: error names the traversal explicitly" \
	|| bad "traversal: missing 'path traversal rejected' (out: $OUT)"
ssh_was_invoked \
	&& bad "traversal: ssh stub was invoked (must fail BEFORE any push attempt)" \
	|| ok "traversal: ssh stub was never invoked"
teardown

# ---- case 14: absolute path -> rejected before ssh --------------------------
setup
OUT="$(run_push "/etc/passwd" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "absolute: /etc/passwd -> nonzero exit" \
	|| bad "absolute: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'absolute path rejected' \
	&& ok "absolute: error names the absolute path rule" \
	|| bad "absolute: missing 'absolute path rejected' (out: $OUT)"
ssh_was_invoked \
	&& bad "absolute: ssh stub was invoked" \
	|| ok "absolute: ssh stub was never invoked"
teardown

# ---- case 15: shell metacharacters -> rejected before ssh -------------------
# $FILENAME becomes the remote command string, so metacharacter rejection is
# a remote-command-injection guard, not just a local path guard.
setup
OUT="$(run_push 'archive/x;whoami' 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "metachar: 'archive/x;whoami' -> nonzero exit" \
	|| bad "metachar: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'illegal characters' \
	&& ok "metachar: error names the illegal-character rule" \
	|| bad "metachar: missing 'illegal characters' (out: $OUT)"
ssh_was_invoked \
	&& bad "metachar: ssh stub was invoked" \
	|| ok "metachar: ssh stub was never invoked"
teardown

# ---- case 16: nested path under an allowed prefix -> rejected ---------------
setup
OUT="$(run_push "archive/sub/anchor-receipt-${TX_HEX}.json" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "nested: archive/sub/<name> -> nonzero exit (one level only)" \
	|| bad "nested: expected nonzero exit, got 0"
ssh_was_invoked \
	&& bad "nested: ssh stub was invoked" \
	|| ok "nested: ssh stub was never invoked"
teardown

# ---- case 17: unknown subdirectory prefix -> rejected ----------------------
setup
OUT="$(run_push "secrets/creds.json" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "unknown-prefix: secrets/creds.json -> nonzero exit" \
	|| bad "unknown-prefix: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'unrecognized filename' \
	&& ok "unknown-prefix: falls through to the unrecognized-filename rejection" \
	|| bad "unknown-prefix: missing 'unrecognized filename' (out: $OUT)"
ssh_was_invoked \
	&& bad "unknown-prefix: ssh stub was invoked" \
	|| ok "unknown-prefix: ssh stub was never invoked"
teardown

# ---- case 18: malformed archive basename -> rejected -----------------------
setup
OUT="$(run_push "archive/anchor-receipt-notahash.json" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "bad-basename: non-hex archive basename -> nonzero exit" \
	|| bad "bad-basename: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'archive/ basename must be' \
	&& ok "bad-basename: error states the two accepted archive patterns" \
	|| bad "bad-basename: missing pattern error (out: $OUT)"
ssh_was_invoked \
	&& bad "bad-basename: ssh stub was invoked" \
	|| ok "bad-basename: ssh stub was never invoked"
teardown

# ---- case 19: uppercase hex archive basename -> rejected -------------------
# The repo-wide convention is lowercase [a-f0-9]{64} (schemas, tx_id checks,
# dag roots). Admitting uppercase here would create a second URL for the same
# anchor, only one of which the history file points at.
setup
UPPER_HEX="$(printf 'A%.0s' $(seq 1 64))"
OUT="$(run_push "archive/anchor-source-${UPPER_HEX}.json" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "case-sensitivity: uppercase hex archive basename -> nonzero exit" \
	|| bad "case-sensitivity: expected nonzero exit, got 0"
ssh_was_invoked \
	&& bad "case-sensitivity: ssh stub was invoked" \
	|| ok "case-sensitivity: ssh stub was never invoked"
teardown

# ---- case 20: malformed peers-history basename -> rejected -----------------
setup
OUT="$(run_push "peers-history/peers-2026-8-5.json.gz" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "bad-basename: non-ISO snapshot date -> nonzero exit" \
	|| bad "bad-basename: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'peers-history/ basename must be' \
	&& ok "bad-basename: error states the peers-YYYY-MM-DD.json.gz pattern" \
	|| bad "bad-basename: missing pattern error (out: $OUT)"
ssh_was_invoked \
	&& bad "bad-basename: ssh stub was invoked" \
	|| ok "bad-basename: ssh stub was never invoked"
teardown

# ---- case 21: well-formed archive name but source absent -> fails closed ----
setup
MISSING_HEX="$(printf 'c%.0s' $(seq 1 64))"
OUT="$(run_push "archive/anchor-receipt-${MISSING_HEX}.json" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "missing-source: absent archive file -> nonzero exit" \
	|| bad "missing-source: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'source not found' \
	&& ok "missing-source: error names the missing archive source" \
	|| bad "missing-source: missing 'source not found' (out: $OUT)"
ssh_was_invoked \
	&& bad "missing-source: ssh stub was invoked for an absent archive file" \
	|| ok "missing-source: ssh stub was never invoked"
teardown

# ---- case 22: snapshot absent in BOTH locations -> fails closed ------------
setup
rm -f "$PEERS_STATE_DIR/peers-2026-08-05.json.gz"
OUT="$(run_push "peers-history/peers-2026-08-05.json.gz" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "missing-source: snapshot absent in state dir and repo -> nonzero exit" \
	|| bad "missing-source: expected nonzero exit, got 0"
echo "$OUT" | grep -q 'nor repo fallback' \
	&& ok "missing-source: error names both locations it looked in" \
	|| bad "missing-source: error does not name both locations (out: $OUT)"
ssh_was_invoked \
	&& bad "missing-source: ssh stub was invoked" \
	|| ok "missing-source: ssh stub was never invoked"
teardown

# ---- summary -----------------------------------------------------------------
echo "test-push-to-web-host.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
