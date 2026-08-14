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

# SIGDFL — run the script under test with SIGINT/SIGQUIT at their DEFAULT
# dispositions.
#
# WHY. A shell without job control sets SIGINT and SIGQUIT to SIG_IGN in every
# ASYNCHRONOUS command it starts — i.e. in anything launched with `&` from a
# non-interactive script, which is how this repository runs suites in parallel.
# A signal ignored on entry cannot be trapped, so `trap … INT` inside the
# script under test never installs, and the SIGINT case below then measures the
# LAUNCHER's job-control context instead of the script's handler. Measured
# 2026-08-14: in the foreground the SIGINT case passes; the identical suite as
# a background job reports exit 0 and "the remote transfer ran anyway", while
# SIGTERM — not ignored this way — passes in both. That is a false red, and a
# false red that appears only under parallelism is how a real red stops being
# believed.
#
# perl restores the disposition and then execs, and exec preserves it. exec also
# keeps the PID, so $PPID inside the script — which is how signalling_guard
# addresses it — is unchanged.
SIGDFL_PERL="$(command -v perl 2>/dev/null || true)"
if [ -z "$SIGDFL_PERL" ]; then
	echo "FATAL: perl not found. It is required to give the script under test default signal dispositions (and publish-guard, which this suite exercises, needs it too)." >&2
	exit 1
fi
SIGDFL=( "$SIGDFL_PERL" -e '$SIG{INT}="DEFAULT"; $SIG{QUIT}="DEFAULT"; exec { $ARGV[0] } @ARGV or die "exec: $!"' -- )

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
	GUARD_HITS="$BASE/guard-hits" \
	FYD_PUBLISH_DENYLIST=/dev/null \
		"${SIGDFL[@]}" bash "$INSTALL/scripts/sync-to-validator-host.sh" "$@"
}

# signalling_guard <signal>
# Replaces the fixture's guard with a wrapper that delegates to the real one
# and then signals the SYNC SCRIPT once a real file has been scanned.
# publish-scan runs the guard as `( … exec bash guard --text )`, a subshell
# forked straight from the script — and the scan loop is `while … done < file`,
# a redirection rather than a pipeline, so it is not itself a subshell — hence
# the guard's $PPID is the script. Hit 1 is the self-test probe; hit 2 onward
# is a real file. This makes the signal land at a known instant instead of
# being raced in from outside.
signalling_guard() {
	local sig="$1"
	cp "$REPO_ROOT/scripts/publish-guard.sh" "$INSTALL/scripts/publish-guard.real.sh"
	cat > "$INSTALL/scripts/publish-guard.sh" <<GUARDEOF
#!/usr/bin/env bash
n=0
[ -f "\$GUARD_HITS" ] && n=\$(cat "\$GUARD_HITS")
n=\$((n + 1)); printf '%s' "\$n" > "\$GUARD_HITS"
rc=0
bash "${INSTALL}/scripts/publish-guard.real.sh" "\$@" || rc=\$?
[ "\$n" -ge 2 ] && kill -${sig} "\$PPID" 2>/dev/null
exit \$rc
GUARDEOF
	chmod +x "$INSTALL/scripts/publish-guard.sh"
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

# ---- case 8: a signal during the scan stops the transfer -------------------
# A handler that cleans up but does not exit lets bash carry on from wherever
# the signal landed. Measured on the first version of this feature: a SIGTERM
# was absorbed completely and the script went on to run the remote rsync AND
# the remote chown, exiting 0 — a cron timeout, `systemctl stop` or ^C could
# not stop a production transfer that was already under way.
setup
signalling_guard TERM
OUT="$(run_sync 2>&1)"
RC=$?
[ "$RC" -eq 143 ] \
	&& ok "signal: SIGTERM during the scan -> exit 143 (128+SIGTERM)" \
	|| bad "signal: expected exit 143, got $RC — the handler did not terminate the script (out: $OUT)"
remote_rsync_ran \
	&& bad "signal: the remote transfer ran after the script was signalled" \
	|| ok "signal: the remote transfer never ran after the signal"
[ -s "$SSH_LOG" ] \
	&& bad "signal: the remote chown ran after the script was signalled" \
	|| ok "signal: the remote chown never ran after the signal"
teardown

# ---- case 9: SIGINT / SIGHUP terminate too, with distinct codes ------------
for SIGNAME in INT HUP; do
	case "$SIGNAME" in INT) WANT=130 ;; HUP) WANT=129 ;; esac
	setup
	signalling_guard "$SIGNAME"
	OUT="$(run_sync 2>&1)"
	RC=$?
	[ "$RC" -eq "$WANT" ] \
		&& ok "signal: SIG${SIGNAME} during the scan -> exit ${WANT}" \
		|| bad "signal: SIG${SIGNAME} expected exit ${WANT}, got $RC (out: $OUT)"
	remote_rsync_ran \
		&& bad "signal: SIG${SIGNAME} — the remote transfer ran anyway" \
		|| ok "signal: SIG${SIGNAME} — the remote transfer never ran"
	teardown
done

# ---- summary ---------------------------------------------------------------
echo "test-sync-to-validator-host.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
