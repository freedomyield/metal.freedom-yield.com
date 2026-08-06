#!/usr/bin/env bash
# tests/sync-to-validator-host/test-sync-to-validator-host.sh — functional
# suite for the send-time publish-guard layer in
# scripts/sync-to-validator-host.sh.
#
# CHAIN: none — no network. Two stubs are prepended onto PATH:
#   - `rsync`, which FORWARDS TO THE REAL rsync whenever the destination is
#     local and only records-and-succeeds when it is remote (`host:path`).
#     Forwarding matters: the pre-transfer scan asks the real rsync, with the
#     real exclude arguments, which files it would send. Stubbing rsync
#     outright would replace the very mechanism under test with a fake.
#   - `ssh`, for the post-transfer chown step.
# PRIME_DIRECTIVE: safe.
#
# What this pins (all measured 2026-08-06):
#   - this script rsyncs the WORKING TREE's scripts/ onto the production host,
#     so publish-guard's three git-facing layers never see any of it;
#   - a forbidden literal in any file rsync would send stops the transfer
#     entirely — nothing partial, and the remote is never contacted;
#   - the set of files scanned is exactly the set rsync would send, so a file
#     under an --exclude does not block the sync;
#   - the guard being unusable is a refusal, not a warning.
#
# Usage:  bash tests/sync-to-validator-host/test-sync-to-validator-host.sh
# Exit:   0 all pass / 1 any fail

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_SCRIPT="${REPO_ROOT}/scripts/sync-to-validator-host.sh"

if [ ! -f "$SRC_SCRIPT" ]; then
	echo "FATAL: script not found at $SRC_SCRIPT" >&2
	exit 1
fi

REAL_RSYNC="$(command -v rsync || true)"
if [ -z "$REAL_RSYNC" ]; then
	echo "FATAL: rsync not found on PATH; this suite drives the real rsync for enumeration" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# Forbidden payload assembled at runtime so this tracked file never contains a
# flaggable literal (same technique as tests/publish-guard/test-publish-guard.sh).
LEAK_IP="$(printf '%d.%d.%d.%d' 8 8 8 8)"

BASE=""; STUBDIR=""; INSTALL=""; KEY_FILE=""; RSYNC_LOG=""; SSH_LOG=""
setup() {
	BASE="$(mktemp -d -t sync-to-validator-host-test.XXXXXX)"
	STUBDIR="$BASE/bin"
	INSTALL="$BASE/install"
	KEY_FILE="$BASE/validator_key"
	RSYNC_LOG="$BASE/rsync-invocations.log"
	SSH_LOG="$BASE/ssh-invocations.log"

	mkdir -p "$STUBDIR" "$INSTALL/scripts/lib" "$INSTALL/scripts/operator-local"

	# An installed copy of the send path: the script, the scan library it
	# sources, and the guard that library invokes — all resolved relative to
	# the script's own directory at runtime.
	cp "$SRC_SCRIPT"                            "$INSTALL/scripts/sync-to-validator-host.sh"
	cp "$REPO_ROOT/scripts/lib/publish-scan.sh" "$INSTALL/scripts/lib/publish-scan.sh"
	cp "$REPO_ROOT/scripts/publish-guard.sh"    "$INSTALL/scripts/publish-guard.sh"
	chmod +x "$INSTALL/scripts/sync-to-validator-host.sh" "$INSTALL/scripts/publish-guard.sh"

	# Ordinary payload files that rsync would carry.
	printf '#!/bin/sh\necho ok\n'                     > "$INSTALL/scripts/harmless.sh"
	printf '# doc host 203.0.113.10 is RFC5737\n'     > "$INSTALL/scripts/doc-ip.sh"

	cat > "$STUBDIR/rsync" <<STUBEOF
#!/usr/bin/env bash
for a in "\$@"; do last="\$a"; done
case "\$last" in
	*:*)
		{ printf 'RSYNC_REMOTE:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "\$RSYNC_STUB_LOG"
		exit "\${RSYNC_STUB_EXIT:-0}"
		;;
esac
exec "$REAL_RSYNC" "\$@"
STUBEOF
	chmod +x "$STUBDIR/rsync"

	cat > "$STUBDIR/ssh" <<'STUBEOF'
#!/usr/bin/env bash
{ printf 'SSH:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$SSH_STUB_LOG"
exit 0
STUBEOF
	chmod +x "$STUBDIR/ssh"

	printf 'dummy-ed25519-key-material\n' > "$KEY_FILE"
}
teardown() { rm -rf "$BASE"; BASE=""; }

run_sync() {
	PATH="$STUBDIR:$PATH" \
	VALIDATOR_HOST="203.0.113.11" \
	VALIDATOR_HOST_KEY="$KEY_FILE" \
	VALIDATOR_HOST_USER="deploy" \
	REMOTE_PATH="/home/deploy/metal.freedom-yield.com/scripts/" \
	RSYNC_STUB_LOG="$RSYNC_LOG" \
	SSH_STUB_LOG="$SSH_LOG" \
	FYD_PUBLISH_DENYLIST=/dev/null \
		bash "$INSTALL/scripts/sync-to-validator-host.sh" "$@"
}

remote_rsync_ran() { grep -q 'RSYNC_REMOTE:' "$RSYNC_LOG" 2>/dev/null; }

# ---- case 1: clean tree -> transfers, and the excludes reach rsync ----------
setup
OUT="$(run_sync 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "clean tree: exit 0" \
	|| bad "clean tree: expected exit 0, got $RC (out: $OUT)"
remote_rsync_ran \
	&& ok "clean tree: the remote transfer ran" \
	|| bad "clean tree: the remote transfer never ran (log: $(cat "$RSYNC_LOG" 2>/dev/null))"
echo "$OUT" | grep -q 'publish-guard: [0-9]* file(s) scanned clean' \
	&& ok "clean tree: reports how many files were scanned" \
	|| bad "clean tree: no scan count reported (out: $OUT)"
grep -q '\[--exclude=operator-local/\]' "$RSYNC_LOG" \
	&& ok "clean tree: the shared exclude list reaches the real transfer" \
	|| bad "clean tree: exclude args missing from rsync argv (log: $(cat "$RSYNC_LOG" 2>/dev/null))"
teardown

# ---- case 2: a forbidden literal in a synced file -> nothing transfers ------
setup
printf '# host %s\n' "$LEAK_IP" > "$INSTALL/scripts/leaky.sh"
OUT="$(run_sync 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "leak: file carrying a public IP -> nonzero exit" \
	|| bad "leak: expected nonzero exit, got 0 (out: $OUT)"
remote_rsync_ran \
	&& bad "leak: the remote transfer ran — the bytes LEFT THE MACHINE" \
	|| ok "leak: the remote transfer never ran"
[ -s "$SSH_LOG" ] \
	&& bad "leak: the post-transfer ssh step ran" \
	|| ok "leak: the post-transfer ssh step never ran"
echo "$OUT" | grep -q 'NOTHING was synced' \
	&& ok "leak: error states that nothing was transferred" \
	|| bad "leak: error does not say nothing was synced (out: $OUT)"
echo "$OUT" | grep -q 'scripts/leaky.sh' \
	&& ok "leak: error names the offending file" \
	|| bad "leak: error does not name the offending file (out: $OUT)"
teardown

# ---- case 3: the scanned set is rsync's set, not "every file present" -------
# operator-local/ is excluded from the transfer, so a forbidden literal there
# must NOT block the sync — otherwise the scan would be enforcing a different
# rule from the one rsync applies, which is the drift this design avoids by
# asking rsync itself which files it would send.
setup
printf '# host %s\n' "$LEAK_IP" > "$INSTALL/scripts/operator-local/notes.sh"
OUT="$(run_sync 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "excluded: a leak under an --exclude does not block the sync" \
	|| bad "excluded: sync was blocked by a file rsync would never send, got $RC (out: $OUT)"
remote_rsync_ran \
	&& ok "excluded: the remote transfer still ran" \
	|| bad "excluded: the remote transfer did not run (out: $OUT)"
teardown

# ---- case 4: guard absent -> refuse before contacting anything -------------
setup
rm -f "$INSTALL/scripts/publish-guard.sh"
OUT="$(run_sync 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "fail-closed: guard missing -> nonzero exit" \
	|| bad "fail-closed: guard missing but exit was 0 (out: $OUT)"
remote_rsync_ran \
	&& bad "fail-closed: guard missing yet the remote transfer ran" \
	|| ok "fail-closed: guard missing -> the remote transfer never ran"
teardown

# ---- case 5: scan library absent -> refuse ---------------------------------
setup
rm -f "$INSTALL/scripts/lib/publish-scan.sh"
OUT="$(run_sync 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "fail-closed: scan library missing -> nonzero exit" \
	|| bad "fail-closed: scan library missing but exit was 0 (out: $OUT)"
remote_rsync_ran \
	&& bad "fail-closed: scan library missing yet the remote transfer ran" \
	|| ok "fail-closed: scan library missing -> the remote transfer never ran"
teardown

# ---- case 6: guard present but does not detect -> refuse -------------------
setup
printf '#!/bin/sh\nexit 0\n' > "$INSTALL/scripts/publish-guard.sh"
chmod +x "$INSTALL/scripts/publish-guard.sh"
OUT="$(run_sync 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "fail-closed: guard that always allows -> nonzero exit (self-test)" \
	|| bad "fail-closed: stub guard was trusted and the sync proceeded (out: $OUT)"
remote_rsync_ran \
	&& bad "fail-closed: stub guard was trusted and the remote transfer ran" \
	|| ok "fail-closed: stub guard -> the remote transfer never ran"
echo "$OUT" | grep -q 'self-test failed' \
	&& ok "fail-closed: error names the self-test as what refused" \
	|| bad "fail-closed: error does not name the self-test (out: $OUT)"
teardown

# ---- case 7: --dry-run is scanned too --------------------------------------
# A preview that skips the check would report "this would transfer fine" about
# a tree that will in fact be refused.
setup
printf '# host %s\n' "$LEAK_IP" > "$INSTALL/scripts/leaky.sh"
OUT="$(run_sync --dry-run 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "dry-run: a leaking tree is refused in dry-run too" \
	|| bad "dry-run: expected nonzero exit, got 0 (out: $OUT)"
teardown

# ---- summary ---------------------------------------------------------------
echo "test-sync-to-validator-host.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
