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
# Optional: signal the script that invoked us. Both halves of `cat … | ssh …`
# are children of the push script's shell, so $PPID is that shell. Lets a case
# deliver a signal at a known instant instead of racing one in.
if [ -n "${SSH_STUB_SIGNAL:-}" ]; then kill -"$SSH_STUB_SIGNAL" "$PPID" 2>/dev/null; fi
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
run_push() { run_push_ex "$SCRIPT" "" "$@"; }

# run_push_ex <script> <extra-PATH-prefix> <filename...>
# Same as run_push but lets a case drive a COPY of the script from a fixture
# install tree (so the guard next to it can be broken without touching the
# repo) and/or shadow a dependency on PATH.
#
# FYD_PUBLISH_DENYLIST=/dev/null keeps the send-time content scan hermetic:
# publish-guard reads an optional .publish-denylist from its repo root, which
# on an operator machine is a real, gitignored file. Without this the suite's
# result would depend on that machine-local file's contents. The content
# assertions below all use pattern layers (public IP), not the denylist.
run_push_ex() {
	local script="$1" extra_path="$2"
	shift 2
	PATH="${extra_path:+${extra_path}:}$STUBDIR:$PATH" \
	REPO_BASE="$FIXTURE_REPO" \
	WEB_PUSH_KEY="$KEY_FILE" \
	WEB_HOST="${WEB_HOST-deploy@203.0.113.11}" \
	WEB_HOST_FILE="${WEB_HOST_FILE:-$NO_HOST_FILE}" \
	PEERS_HISTORY_DIR="${PEERS_HISTORY_DIR:-$PEERS_STATE_DIR}" \
	SSH_STUB_LOG="$SSH_LOG" \
	SSH_STUB_SIGNAL="${SSH_STUB_SIGNAL:-}" \
	GUARD_HITS="$BASE/guard-hits" \
	STUB_EXIT="${STUB_EXIT:-0}" \
	FYD_PUBLISH_DENYLIST=/dev/null \
		bash "$script" "$@"
}

# install_fixture <dir> -> echoes the path of the push script inside it.
# An INSTALLED copy of the whole send path: the script, the scan library it
# sources, and the guard that library invokes. All three are resolved relative
# to the script's own directory at runtime, so a case can delete or replace any
# one of them and observe what the send path does — without mutating the repo.
install_fixture() {
	mkdir -p "$1/scripts/lib"
	cp "$REPO_ROOT/scripts/push-to-web-host.sh" "$1/scripts/push-to-web-host.sh"
	cp "$REPO_ROOT/scripts/lib/publish-scan.sh" "$1/scripts/lib/publish-scan.sh"
	cp "$REPO_ROOT/scripts/publish-guard.sh"    "$1/scripts/publish-guard.sh"
	chmod +x "$1/scripts/push-to-web-host.sh" "$1/scripts/publish-guard.sh"
	printf '%s' "$1/scripts/push-to-web-host.sh"
}

# signalling_guard <install-dir> <signal>
# Replaces a fixture's guard with a wrapper that delegates to the real one and
# then signals the PUSH SCRIPT the moment the OUTBOUND CONTENT scan has
# returned. publish-scan runs the guard as `( … exec bash guard --text )`, a
# subshell forked straight from the script, so the guard's $PPID is that
# script. This pins the signal to the exact instant between "content approved"
# and "content handed to ssh" — the window where a handler that returns instead
# of exiting lets the next statement run against an already-cleaned snapshot.
# Hit 1 is the self-test probe; hit 2 onward is real outbound content.
signalling_guard() {
	local dir="$1" sig="$2"
	cp "$REPO_ROOT/scripts/publish-guard.sh" "$dir/scripts/publish-guard.real.sh"
	cat > "$dir/scripts/publish-guard.sh" <<GUARDEOF
#!/usr/bin/env bash
n=0
[ -f "\$GUARD_HITS" ] && n=\$(cat "\$GUARD_HITS")
n=\$((n + 1)); printf '%s' "\$n" > "\$GUARD_HITS"
rc=0
bash "${dir}/scripts/publish-guard.real.sh" "\$@" || rc=\$?
[ "\$n" -ge 2 ] && kill -${sig} "\$PPID" 2>/dev/null
exit \$rc
GUARDEOF
	chmod +x "$dir/scripts/publish-guard.sh"
}

ssh_was_invoked() { [ -s "$SSH_LOG" ]; }
ssh_invocations() { grep -c '^ARGV:' "$SSH_LOG" 2>/dev/null || echo 0; }

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

# ==============================================================================
# Send-time content scan (2026-08-06). The allowlist above decides whether a
# NAME may be published; nothing decided whether the CONTENT may be. This path
# never invokes git and all of its targets are gitignored, so publish-guard's
# three git-facing layers (PreToolUse hook / pre-commit / pre-push) could not
# see any of it — measured 2026-08-06, coverage was zero.
#
# The forbidden payload is ASSEMBLED AT RUNTIME so this tracked file never
# contains a flaggable literal (same technique as
# tests/publish-guard/test-publish-guard.sh, and the reason that file explains
# it: writing one here trips the layer-1 hook on this very file).
# ==============================================================================
LEAK_IP="$(printf '%d.%d.%d.%d' 8 8 8 8)"
LEAK_JSON="$(printf '{"generatedAt":"x","host":"%s"}\n' "$LEAK_IP")"

# ---- case 23: forbidden content -> refused BEFORE ssh -----------------------
setup
printf '%s' "$LEAK_JSON" > "$FIXTURE_REPO/public/api/validator.json"
OUT="$(run_push validator.json 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "content-guard: feed carrying a public IP -> nonzero exit" \
	|| bad "content-guard: expected nonzero exit, got 0 (out: $OUT)"
ssh_was_invoked \
	&& bad "content-guard: ssh stub was invoked — the bytes LEFT THE MACHINE" \
	|| ok "content-guard: ssh stub was never invoked (blocked before send)"
echo "$OUT" | grep -q 'PUBLISH_GUARD_BLOCK' \
	&& ok "content-guard: the guard's own block report is surfaced" \
	|| bad "content-guard: no PUBLISH_GUARD_BLOCK in output (out: $OUT)"
echo "$OUT" | grep -q 'NOT pushed' \
	&& ok "content-guard: error states the push did not happen" \
	|| bad "content-guard: error does not say the push was refused (out: $OUT)"
teardown

# ---- case 24: the SAME file without the payload still pushes ----------------
# Paired control for case 23. Without it, case 23 would also "pass" if the
# scan rejected every feed unconditionally.
setup
printf '{"generatedAt":"x","host":"203.0.113.10"}\n' > "$FIXTURE_REPO/public/api/validator.json"
OUT="$(run_push validator.json 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "content-guard: same feed with a doc-range IP -> exit 0 (no regression)" \
	|| bad "content-guard: clean feed was refused, got $RC (out: $OUT)"
ssh_was_invoked \
	&& ok "content-guard: clean feed reached the ssh stub" \
	|| bad "content-guard: clean feed never reached ssh"
teardown

# ---- case 25: forbidden content INSIDE a gzip payload -> refused ------------
# The compressed bytes do not contain the literal (deflate re-codes it), so
# only decompressing before scanning can see it. The assertion below proves
# the compressed form really is opaque, so this case cannot pass by accident.
setup
printf '%s' "$LEAK_JSON" | gzip -c > "$PEERS_STATE_DIR/peers-2026-08-05.json.gz"
LC_ALL=C grep -qF "$LEAK_IP" "$PEERS_STATE_DIR/peers-2026-08-05.json.gz" \
	&& bad "gzip-guard: premise broken — the literal survives compression verbatim" \
	|| ok "gzip-guard: the literal is NOT present in the compressed bytes"
OUT="$(run_push peers-history/peers-2026-08-05.json.gz 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "gzip-guard: snapshot whose DECOMPRESSED content leaks -> nonzero exit" \
	|| bad "gzip-guard: expected nonzero exit, got 0 (out: $OUT)"
ssh_was_invoked \
	&& bad "gzip-guard: ssh stub was invoked for a leaking snapshot" \
	|| ok "gzip-guard: ssh stub was never invoked"
echo "$OUT" | grep -q 'DECOMPRESSED' \
	&& ok "gzip-guard: error identifies the decompressed content as the source" \
	|| bad "gzip-guard: error does not mention the decompressed content (out: $OUT)"
teardown

# ---- case 26: fail-closed when the guard is ABSENT from the install tree ----
setup
FIX="$BASE/install-noguard"
FIX_SCRIPT="$(install_fixture "$FIX")"
rm -f "$FIX/scripts/publish-guard.sh"
OUT="$(run_push_ex "$FIX_SCRIPT" "" validator.json 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "fail-closed: guard missing -> nonzero exit" \
	|| bad "fail-closed: guard missing but exit was 0 (out: $OUT)"
ssh_was_invoked \
	&& bad "fail-closed: guard missing yet ssh was invoked" \
	|| ok "fail-closed: guard missing -> ssh stub was never invoked"
teardown

# ---- case 27: fail-closed when the scan LIBRARY is absent -------------------
setup
FIX="$BASE/install-nolib"
FIX_SCRIPT="$(install_fixture "$FIX")"
rm -f "$FIX/scripts/lib/publish-scan.sh"
OUT="$(run_push_ex "$FIX_SCRIPT" "" validator.json 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "fail-closed: scan library missing -> nonzero exit" \
	|| bad "fail-closed: scan library missing but exit was 0 (out: $OUT)"
ssh_was_invoked \
	&& bad "fail-closed: scan library missing yet ssh was invoked" \
	|| ok "fail-closed: scan library missing -> ssh stub was never invoked"
teardown

# ---- case 28: fail-closed when the guard is PRESENT but does not detect -----
# The realistic accident, not an attacker: scripts/ is rsynced to production,
# so a truncated copy is a live possibility, and a guard that exits 0 without
# scanning is byte-for-byte indistinguishable from a clean verdict. This is the
# assertion the self-test exists for — it is the only one that fails if the
# self-test is removed and the exit code alone is trusted.
setup
FIX="$BASE/install-stubguard"
FIX_SCRIPT="$(install_fixture "$FIX")"
printf '#!/bin/sh\nexit 0\n' > "$FIX/scripts/publish-guard.sh"
chmod +x "$FIX/scripts/publish-guard.sh"
OUT="$(run_push_ex "$FIX_SCRIPT" "" validator.json 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "fail-closed: guard that always allows -> nonzero exit (self-test)" \
	|| bad "fail-closed: stub guard was trusted and the push proceeded (out: $OUT)"
ssh_was_invoked \
	&& bad "fail-closed: stub guard was trusted and ssh was invoked" \
	|| ok "fail-closed: stub guard -> ssh stub was never invoked"
echo "$OUT" | grep -q 'self-test failed' \
	&& ok "fail-closed: error names the self-test as what refused" \
	|| bad "fail-closed: error does not name the self-test (out: $OUT)"
teardown

# ---- case 29: fail-closed when the guard's OWN dependency is broken ---------
# perl is shadowed on PATH for the duration of this one invocation (no system
# perl is touched). publish-guard then cannot complete its scan and fails
# closed itself; this asserts the send path honours that instead of shipping.
setup
FAKEBIN="$BASE/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/perl"
chmod +x "$FAKEBIN/perl"
OUT="$(run_push_ex "$SCRIPT" "$FAKEBIN" validator.json 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "fail-closed: broken perl -> nonzero exit" \
	|| bad "fail-closed: broken perl but the push proceeded (out: $OUT)"
ssh_was_invoked \
	&& bad "fail-closed: broken perl yet ssh was invoked" \
	|| ok "fail-closed: broken perl -> ssh stub was never invoked"
teardown

# ---- case 30: an INTACT install fixture still pushes ------------------------
# Control for cases 26-28: proves those three fail because of what they broke,
# not because driving the script from a fixture directory breaks it.
setup
FIX="$BASE/install-intact"
FIX_SCRIPT="$(install_fixture "$FIX")"
OUT="$(run_push_ex "$FIX_SCRIPT" "" validator.json 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "fail-closed control: intact install fixture -> exit 0" \
	|| bad "fail-closed control: intact fixture was refused, got $RC (out: $OUT)"
ssh_was_invoked \
	&& ok "fail-closed control: intact fixture reached the ssh stub" \
	|| bad "fail-closed control: intact fixture never reached ssh"
teardown

# ---- case 31: scanned bytes and sent bytes are THE SAME bytes ---------------
# The scan reads a snapshot and ssh is fed that same snapshot, so a producer
# rewriting the source between the two reads cannot slip past. Asserted through
# the byte count the stub records.
setup
printf '{"ok":true,"padding":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' > "$FIXTURE_REPO/public/api/validator.json"
EXPECT_BYTES=$(wc -c < "$FIXTURE_REPO/public/api/validator.json" | tr -d ' ')
OUT="$(run_push validator.json 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "snapshot: scanned-then-sent push -> exit 0" \
	|| bad "snapshot: expected exit 0, got $RC (out: $OUT)"
grep -q "STDIN_BYTES: ${EXPECT_BYTES}" "$SSH_LOG" \
	&& ok "snapshot: ssh received exactly the scanned byte count ($EXPECT_BYTES)" \
	|| bad "snapshot: byte mismatch (expected $EXPECT_BYTES, log: $(cat "$SSH_LOG" 2>/dev/null))"
teardown

# ==============================================================================
# Signal handling. A handler that CLEANS UP BUT DOES NOT EXIT is worse than no
# handler: bash runs it and then carries on from wherever the signal landed.
# Both failure modes below were reproduced on the first version of this feature
# (30 SIGTERM trials, no artificial delay): 12 of them started ssh with an
# EMPTY stdin — a zero-byte body published under a real feed name — and the
# rest ignored the signal and finished all three attempts, 19 s past the
# SIGTERM. Neither is a leak (the handler deletes the snapshot, it never
# substitutes content), but a cron timeout / `systemctl stop` / ^C must be able
# to stop a publish, and an empty feed must never be published.
#
# The signal is delivered from inside the fixtures at a known instant rather
# than raced in from outside, so these cases are deterministic.
# ==============================================================================

# ---- case 32: SIGTERM between "content approved" and "content sent" --------
setup
FIX="$BASE/install-signal-scan"
FIX_SCRIPT="$(install_fixture "$FIX")"
signalling_guard "$FIX" TERM
OUT="$(run_push_ex "$FIX_SCRIPT" "" validator.json 2>&1)"
RC=$?
[ "$RC" -eq 143 ] \
	&& ok "signal: SIGTERM after the scan -> exit 143 (128+SIGTERM)" \
	|| bad "signal: expected exit 143, got $RC — the handler did not terminate the script (out: $OUT)"
ssh_was_invoked \
	&& bad "signal: ssh ran after the script was signalled" \
	|| ok "signal: ssh never ran after the script was signalled"
grep -q 'STDIN_BYTES: 0' "$SSH_LOG" 2>/dev/null \
	&& bad "signal: a ZERO-BYTE payload reached ssh under a real feed name" \
	|| ok "signal: no zero-byte payload reached ssh"
teardown

# ---- case 33: SIGTERM while ssh is running -> no further attempts ----------
setup
SSH_STUB_SIGNAL=TERM
STUB_EXIT=1
OUT="$(run_push validator.json 2>&1)"
RC=$?
unset SSH_STUB_SIGNAL STUB_EXIT
[ "$RC" -eq 143 ] \
	&& ok "signal: SIGTERM during a push -> exit 143, retries abandoned" \
	|| bad "signal: expected exit 143, got $RC — the retry loop absorbed the signal (out: $OUT)"
[ "$(ssh_invocations)" -eq 1 ] \
	&& ok "signal: exactly one ssh attempt was made after the signal" \
	|| bad "signal: $(ssh_invocations) ssh attempts — the loop kept going past the signal"
teardown

# ---- case 34: SIGINT and SIGHUP terminate too -------------------------------
# Same handler shape, distinct exit codes, so a caller can tell what killed it.
for SIGNAME in INT HUP; do
	case "$SIGNAME" in INT) WANT=130 ;; HUP) WANT=129 ;; esac
	setup
	FIX="$BASE/install-signal-$SIGNAME"
	FIX_SCRIPT="$(install_fixture "$FIX")"
	signalling_guard "$FIX" "$SIGNAME"
	OUT="$(run_push_ex "$FIX_SCRIPT" "" validator.json 2>&1)"
	RC=$?
	[ "$RC" -eq "$WANT" ] \
		&& ok "signal: SIG${SIGNAME} after the scan -> exit ${WANT}" \
		|| bad "signal: SIG${SIGNAME} expected exit ${WANT}, got $RC (out: $OUT)"
	ssh_was_invoked \
		&& bad "signal: SIG${SIGNAME} — ssh ran after the script was signalled" \
		|| ok "signal: SIG${SIGNAME} — ssh never ran"
	teardown
done

# ---- summary -----------------------------------------------------------------
echo "test-push-to-web-host.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
