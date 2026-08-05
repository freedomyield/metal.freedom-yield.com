#!/usr/bin/env bash
# tests/install-xserver-subdir-allowlist/test-install-xserver-subdir-allowlist.sh
#
# Functional suite for the RECEIVER half of the subdirectory publication
# path:
#   scripts/deploy/receive-subdir-allowlist.snippet.sh   (the block that runs
#                                                        on the web host)
#   scripts/install-xserver-subdir-allowlist.sh          (the installer that
#                                                        embeds it)
#
# CHAIN: none — no network, no SSH. The snippet is driven directly with
# FY_SUBDIR_ROOT pointed at a temp directory, and the installer is only
# exercised in modes that never open a socket (--print-remote, local
# precondition failures) plus a recording `ssh` stub on PATH for the
# connection-failure path. PRIME_DIRECTIVE: safe.
#
# Why this suite exists: anchor-history.jsonl advertises
# `api/archive/anchor-source-<dag>.json` / `api/archive/anchor-receipt-<tx>.json`
# and peers-history-index.json's entries resolve to `/api/peers-history/<name>`.
# All of them 404'd. The sender allowlist alone cannot fix that — the web
# host's forced-command wrapper enforces its own allowlist and had no
# subdirectory concept. This suite covers that receiver-side block and the
# sender→receiver contract between them.
#
# Usage: bash tests/install-xserver-subdir-allowlist/test-install-xserver-subdir-allowlist.sh
# Exit:  0 all PASS / 1 any FAIL

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SNIPPET="${REPO_ROOT}/scripts/deploy/receive-subdir-allowlist.snippet.sh"
INSTALLER="${REPO_ROOT}/scripts/install-xserver-subdir-allowlist.sh"
PUSHER="${REPO_ROOT}/scripts/push-to-web-host.sh"

for f in "$SNIPPET" "$INSTALLER" "$PUSHER"; do
	[ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

DAG_HEX="$(printf 'a%.0s' $(seq 1 64))"
TX_HEX="$(printf 'b%.0s' $(seq 1 64))"

BASE=""; ROOT=""
setup()    { BASE="$(mktemp -d -t subdir-allowlist-test.XXXXXX)"; ROOT="$BASE/webroot/api"; mkdir -p "$ROOT"; }
teardown() { rm -rf "$BASE"; BASE=""; }

# recv <command-string> <payload-file> -> writes rc to $RC, output to $OUT
recv() {
	OUT="$(FY_SUBDIR_ROOT="$ROOT" SSH_ORIGINAL_COMMAND="$1" bash "$SNIPPET" < "$2" 2>&1)"
	RC=$?
}

no_temp_left() { ! find "$ROOT" -name '.push.*' -print -quit 2>/dev/null | grep -q .; }

# isolate_bin <extra-tool>...
# Build a PATH directory holding only the tools the receive block needs,
# deliberately WITHOUT jq and python3 unless one is named explicitly, so the
# "no JSON validator on this host" branch is exercised for real rather than
# asserted about. Resolved from well-known bin directories rather than
# `command -v`, which can return a shell alias name instead of a path.
isolate_bin() {
	local tool d
	mkdir -p "$BASE/isobin"
	for tool in mkdir mktemp cat grep rm mv chmod gzip "$@"; do
		for d in /bin /usr/bin /usr/local/bin /opt/homebrew/bin; do
			if [ -x "$d/$tool" ]; then ln -sf "$d/$tool" "$BASE/isobin/$tool"; break; fi
		done
	done
	printf '%s' "$BASE/isobin"
}

# recv_isolated <bindir> <command-string> <payload-file>
recv_isolated() {
	OUT="$(env -i PATH="$1" FY_SUBDIR_ROOT="$ROOT" SSH_ORIGINAL_COMMAND="$2" \
		/bin/bash "$SNIPPET" < "$3" 2>&1)"
	RC=$?
}

landed_count() { find "$BASE/webroot" -type f 2>/dev/null | wc -l | tr -d ' '; }
orphan_count() { find "$BASE/webroot" -name '.push.*' 2>/dev/null | wc -l | tr -d ' '; }

# ==============================================================================
# Receiver: accepted shapes
# ==============================================================================

# ---- case 1: archive/anchor-source-<64hex>.json accepted --------------------
setup
printf '{"archived":"source"}\n' > "$BASE/src.json"
recv "archive/anchor-source-${DAG_HEX}.json" "$BASE/src.json"
[ "$RC" -eq 0 ] \
	&& ok "receiver: anchor-source archive accepted (exit 0)" \
	|| bad "receiver: expected exit 0, got $RC (out: $OUT)"
DEST="$ROOT/archive/anchor-source-${DAG_HEX}.json"
[ -f "$DEST" ] \
	&& ok "receiver: file landed at api/archive/<basename> (subdir auto-created)" \
	|| bad "receiver: destination file not created at $DEST"
cmp -s "$BASE/src.json" "$DEST" \
	&& ok "receiver: delivered bytes are identical to the pushed payload" \
	|| bad "receiver: delivered bytes differ from the payload"
MODE="$(ls -l "$DEST" | cut -c1-10)"
[ "$MODE" = "-rw-r--r--" ] \
	&& ok "receiver: delivered file is world-readable 644 (servable by the web server)" \
	|| bad "receiver: unexpected mode $MODE on the delivered file"
no_temp_left \
	&& ok "receiver: no .push.* temp file left behind after a successful write" \
	|| bad "receiver: temp file left behind"
teardown

# ---- case 2: archive/anchor-receipt-<64hex>.json accepted ------------------
setup
printf '{"archived":"receipt"}\n' > "$BASE/rcpt.json"
recv "archive/anchor-receipt-${TX_HEX}.json" "$BASE/rcpt.json"
[ "$RC" -eq 0 ] && [ -f "$ROOT/archive/anchor-receipt-${TX_HEX}.json" ] \
	&& ok "receiver: anchor-receipt archive accepted and delivered" \
	|| bad "receiver: receipt archive not delivered (rc=$RC, out: $OUT)"
teardown

# ---- case 3: peers-history/peers-YYYY-MM-DD.json.gz accepted ---------------
setup
printf '{"peers":[]}\n' | gzip -c > "$BASE/snap.gz"
recv "peers-history/peers-2026-08-05.json.gz" "$BASE/snap.gz"
[ "$RC" -eq 0 ] && [ -f "$ROOT/peers-history/peers-2026-08-05.json.gz" ] \
	&& ok "receiver: daily peers snapshot accepted and delivered" \
	|| bad "receiver: snapshot not delivered (rc=$RC, out: $OUT)"
teardown

# ==============================================================================
# Receiver: rejected shapes (nothing may land, nothing may leak)
# ==============================================================================

# ---- case 4: path traversal -----------------------------------------------
setup
printf 'x\n' > "$BASE/p"
recv "archive/../../etc/passwd" "$BASE/p"
[ "$RC" -eq 2 ] \
	&& ok "receiver: traversal rejected with exit 2" \
	|| bad "receiver: traversal expected exit 2, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'REJECT: path traversal' \
	&& ok "receiver: traversal rejection names the reason" \
	|| bad "receiver: traversal message missing (out: $OUT)"
[ -z "$(find "$BASE/webroot" -type f 2>/dev/null)" ] \
	&& ok "receiver: traversal wrote nothing anywhere under the web root" \
	|| bad "receiver: traversal produced a file"
teardown

# ---- case 5: nested path under an allowed prefix ---------------------------
setup
printf 'x\n' > "$BASE/p"
recv "archive/sub/anchor-receipt-${TX_HEX}.json" "$BASE/p"
[ "$RC" -eq 2 ] \
	&& ok "receiver: nested path rejected with exit 2 (one level only)" \
	|| bad "receiver: nested path expected exit 2, got $RC (out: $OUT)"
teardown

# ---- case 6: malformed basenames ------------------------------------------
setup
printf 'x\n' > "$BASE/p"
recv "archive/anchor-receipt-notahash.json" "$BASE/p"
[ "$RC" -eq 2 ] \
	&& ok "receiver: non-hex archive basename rejected with exit 2" \
	|| bad "receiver: non-hex basename expected exit 2, got $RC (out: $OUT)"
recv "archive/secrets.json" "$BASE/p"
[ "$RC" -eq 2 ] \
	&& ok "receiver: arbitrary name under archive/ rejected with exit 2" \
	|| bad "receiver: arbitrary archive name expected exit 2, got $RC (out: $OUT)"
recv "peers-history/peers-2026-8-5.json.gz" "$BASE/p"
[ "$RC" -eq 2 ] \
	&& ok "receiver: non-ISO snapshot date rejected with exit 2" \
	|| bad "receiver: bad snapshot date expected exit 2, got $RC (out: $OUT)"
UPPER_HEX="$(printf 'A%.0s' $(seq 1 64))"
recv "archive/anchor-source-${UPPER_HEX}.json" "$BASE/p"
[ "$RC" -eq 2 ] \
	&& ok "receiver: uppercase hex rejected with exit 2 (lowercase-only convention)" \
	|| bad "receiver: uppercase hex expected exit 2, got $RC (out: $OUT)"
[ -z "$(find "$BASE/webroot" -type f 2>/dev/null)" ] \
	&& ok "receiver: no rejected shape produced a file" \
	|| bad "receiver: a rejected shape produced a file"
teardown

# ---- case 7: non-matching command falls through untouched ------------------
# The block must not change the wrapper's existing flat-filename behaviour:
# for anything outside the two prefixes it neither writes nor claims success.
setup
printf '{"ok":true}\n' > "$BASE/p"
recv "validator.json" "$BASE/p"
echo "$OUT" | grep -q 'OK: received' \
	&& bad "fall-through: block claimed to handle a flat filename" \
	|| ok "fall-through: flat filename not claimed by the subdirectory block"
[ -z "$(find "$BASE/webroot" -type f 2>/dev/null)" ] \
	&& ok "fall-through: flat filename wrote nothing (wrapper's own allowlist handles it)" \
	|| bad "fall-through: flat filename produced a file"
teardown

# ---- case 8: destination root missing / placeholder unsubstituted ----------
setup
printf '{"ok":true}\n' > "$BASE/p"
OUT="$(FY_SUBDIR_ROOT="$BASE/does-not-exist" SSH_ORIGINAL_COMMAND="archive/anchor-source-${DAG_HEX}.json" \
	bash "$SNIPPET" < "$BASE/p" 2>&1)"
RC=$?
[ "$RC" -eq 4 ] \
	&& ok "receiver: missing destination root refuses with exit 4" \
	|| bad "receiver: missing root expected exit 4, got $RC (out: $OUT)"
# With FY_SUBDIR_ROOT unset the literal @@FY_SUBDIR_ROOT@@ placeholder is
# used, which is not a directory — i.e. a wrapper installed without
# substitution fails closed instead of writing somewhere unexpected.
OUT="$(SSH_ORIGINAL_COMMAND="archive/anchor-source-${DAG_HEX}.json" \
	bash "$SNIPPET" < "$BASE/p" 2>&1)"
RC=$?
[ "$RC" -eq 4 ] \
	&& ok "receiver: unsubstituted @@FY_SUBDIR_ROOT@@ fails closed with exit 4" \
	|| bad "receiver: unsubstituted placeholder expected exit 4, got $RC (out: $OUT)"
teardown

# ---- case 9: content type must match the declared name --------------------
setup
printf 'not json at all\n' > "$BASE/bad.json"
recv "archive/anchor-source-${DAG_HEX}.json" "$BASE/bad.json"
if command -v jq >/dev/null 2>&1; then
	[ "$RC" -eq 6 ] \
		&& ok "receiver: invalid JSON archive payload rejected with exit 6" \
		|| bad "receiver: invalid JSON expected exit 6, got $RC (out: $OUT)"
	[ ! -f "$ROOT/archive/anchor-source-${DAG_HEX}.json" ] \
		&& ok "receiver: invalid JSON did not land on the public path" \
		|| bad "receiver: invalid JSON landed on the public path"
	no_temp_left \
		&& ok "receiver: no temp file left behind after a content rejection" \
		|| bad "receiver: temp file left behind after content rejection"
else
	ok "receiver: JSON content check skipped (jq absent on this machine)"
fi
printf 'plain bytes, not gzip\n' > "$BASE/bad.gz"
recv "peers-history/peers-2026-08-05.json.gz" "$BASE/bad.gz"
[ "$RC" -eq 6 ] \
	&& ok "receiver: non-gzip snapshot payload rejected with exit 6" \
	|| bad "receiver: non-gzip expected exit 6, got $RC (out: $OUT)"
: > "$BASE/empty"
recv "archive/anchor-receipt-${TX_HEX}.json" "$BASE/empty"
[ "$RC" -eq 6 ] \
	&& ok "receiver: empty payload rejected with exit 6 (truncated push)" \
	|| bad "receiver: empty payload expected exit 6, got $RC (out: $OUT)"
teardown

# ==============================================================================
# End-to-end: sender → (stub ssh transport) → receiver → public tree
# ==============================================================================

# ---- case 10: the exact pipeline command lands the archive publicly --------
# The ssh stub stands in only for the transport: it feeds the pushed bytes
# and the pushed command string into the real receiver block, exactly as
# sshd's forced command would. This is the step that was missing entirely —
# after gen-anchor-receipt.sh writes public/api/archive/anchor-receipt-<tx>.json,
# this command is what makes the URL anchor-history.jsonl advertises resolve.
setup
FIXTURE_REPO="$BASE/repo"
STUBDIR="$BASE/bin"
mkdir -p "$FIXTURE_REPO/public/api/archive" "$STUBDIR"
printf '{"schema_version":2,"anchor":{"tx_id":"%s"}}\n' "$TX_HEX" \
	> "$FIXTURE_REPO/public/api/archive/anchor-receipt-${TX_HEX}.json"
printf 'dummy-key\n' > "$BASE/key"

cat > "$STUBDIR/ssh" <<'STUBEOF'
#!/usr/bin/env bash
# Transport stub: last arg is the remote command string, stdin is the file.
cmd="${!#}"
FY_SUBDIR_ROOT="$FY_STUB_ROOT" SSH_ORIGINAL_COMMAND="$cmd" bash "$FY_STUB_SNIPPET"
STUBEOF
chmod +x "$STUBDIR/ssh"

OUT="$(PATH="$STUBDIR:$PATH" \
	REPO_BASE="$FIXTURE_REPO" \
	WEB_PUSH_KEY="$BASE/key" \
	WEB_HOST="deploy@203.0.113.11" \
	WEB_HOST_FILE="$BASE/no-such-file" \
	FY_STUB_ROOT="$ROOT" \
	FY_STUB_SNIPPET="$SNIPPET" \
	bash "$PUSHER" "archive/anchor-receipt-${TX_HEX}.json" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "end-to-end: push-to-web-host.sh archive/<receipt> exits 0" \
	|| bad "end-to-end: expected exit 0, got $RC (out: $OUT)"
DEST="$ROOT/archive/anchor-receipt-${TX_HEX}.json"
[ -f "$DEST" ] \
	&& ok "end-to-end: receipt archive landed at api/archive/ on the web root" \
	|| bad "end-to-end: receipt archive did not land at $DEST (out: $OUT)"
cmp -s "$FIXTURE_REPO/public/api/archive/anchor-receipt-${TX_HEX}.json" "$DEST" \
	&& ok "end-to-end: published bytes are identical to the archived pre-image" \
	|| bad "end-to-end: published bytes differ from the archive copy"

# Same transport, a name the sender rejects: nothing may reach the web root.
OUT="$(PATH="$STUBDIR:$PATH" \
	REPO_BASE="$FIXTURE_REPO" \
	WEB_PUSH_KEY="$BASE/key" \
	WEB_HOST="deploy@203.0.113.11" \
	WEB_HOST_FILE="$BASE/no-such-file" \
	FY_STUB_ROOT="$ROOT" \
	FY_STUB_SNIPPET="$SNIPPET" \
	bash "$PUSHER" "archive/../../etc/passwd" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "end-to-end: traversal rejected by the sender before transport" \
	|| bad "end-to-end: traversal was not rejected"
teardown

# ==============================================================================
# Sender/receiver lock-step + installer guards
# ==============================================================================

# ---- case 11: both halves enforce the same patterns -----------------------
setup
for pat in 'anchor-(source|receipt)-[a-f0-9]{64}' 'peers-[0-9]{4}-[0-9]{2}-[0-9]{2}'; do
	if grep -qF "$pat" "$SNIPPET" && grep -qF "$pat" "$PUSHER"; then
		ok "lock-step: sender and receiver both carry pattern ${pat}"
	else
		bad "lock-step: pattern ${pat} missing from sender or receiver"
	fi
done
grep -q 'install-xserver-subdir-allowlist.sh' "$PUSHER" \
	&& ok "lock-step: push-to-web-host.sh header points at the receiver installer" \
	|| bad "lock-step: push-to-web-host.sh does not mention the receiver installer"
grep -q 'api/archive/' "${REPO_ROOT}/deploy/feed-excludes.txt" \
	&& grep -q 'api/peers-history/' "${REPO_ROOT}/deploy/feed-excludes.txt" \
	&& ok "lock-step: both subdirectories are excluded from the deploy --delete" \
	|| bad "lock-step: deploy/feed-excludes.txt is missing a subdirectory entry"
teardown

# ---- case 12: installer --print-remote is syntactically valid -------------
setup
REMOTE="$BASE/remote.sh"
bash "$INSTALLER" --print-remote > "$REMOTE" 2>"$BASE/err"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "installer: --print-remote exits 0 without touching a host" \
	|| bad "installer: --print-remote exited $RC (err: $(cat "$BASE/err"))"
bash -n "$REMOTE" \
	&& ok "installer: the remote half passes bash -n" \
	|| bad "installer: the remote half fails bash -n"
grep -q 'receive-metal-push' "$REMOTE" \
	&& ok "installer: remote half targets the receive-metal-push wrapper" \
	|| bad "installer: remote half does not name the wrapper"
grep -q 'bak-' "$REMOTE" \
	&& ok "installer: remote half backs the wrapper up before writing" \
	|| bad "installer: remote half has no backup step"
grep -qF '"$CHECKER" -n "$TMP_NEW"' "$REMOTE" \
	&& ok "installer: remote half refuses to install a wrapper failing its shebang's syntax check" \
	|| bad "installer: remote half does not syntax-check the composed wrapper"
grep -qF 'neither jq nor python3' "$REMOTE" \
	&& ok "installer: remote half warns when the host has no JSON validator" \
	|| bad "installer: remote half does not surface a missing JSON validator"
grep -q '@@FY_SUBDIR_ROOT@@' "$REMOTE" \
	&& ok "installer: remote half substitutes (and re-checks) the root placeholder" \
	|| bad "installer: remote half never handles the root placeholder"
teardown

# ---- case 13: installer local preconditions fail closed -------------------
setup
STUBDIR="$BASE/bin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/ssh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'SSH_CALLED\n' >> "$SSH_STUB_LOG"
exit "${STUB_EXIT:-0}"
STUBEOF
chmod +x "$STUBDIR/ssh"
SSH_LOG="$BASE/ssh.log"

OUT="$(SNIPPET_FILE=/nonexistent bash "$INSTALLER" --print-remote 2>&1)"
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "installer: missing snippet file -> exit 2" \
	|| bad "installer: missing snippet expected exit 2, got $RC (out: $OUT)"

OUT="$(bash "$INSTALLER" --bogus-flag 2>&1)"
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "installer: unknown argument -> exit 2" \
	|| bad "installer: unknown arg expected exit 2, got $RC (out: $OUT)"

OUT="$(PATH="$STUBDIR:$PATH" SSH_STUB_LOG="$SSH_LOG" XSERVER_HOST="" \
	bash "$INSTALLER" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "installer: empty XSERVER_HOST -> nonzero exit" \
	|| bad "installer: empty XSERVER_HOST unexpectedly succeeded"
[ ! -s "$SSH_LOG" ] \
	&& ok "installer: no ssh attempted without a target host" \
	|| bad "installer: ssh was invoked despite no target host"

# Unreadable SSH key is a local precondition and must not reach the network.
: > "$SSH_LOG"
OUT="$(PATH="$STUBDIR:$PATH" SSH_STUB_LOG="$SSH_LOG" \
	XSERVER_HOST="203.0.113.11" XSERVER_KEY="$BASE/no-such-key" \
	bash "$INSTALLER" 2>&1)"
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "installer: unreadable SSH key -> exit 2" \
	|| bad "installer: unreadable key expected exit 2, got $RC (out: $OUT)"
[ ! -s "$SSH_LOG" ] \
	&& ok "installer: no ssh attempted when the key is unreadable" \
	|| bad "installer: ssh was invoked despite an unreadable key"

# SSH pre-check failure must stop before the remote edit is attempted.
: > "$SSH_LOG"
printf 'dummy-key\n' > "$BASE/key"
OUT="$(PATH="$STUBDIR:$PATH" SSH_STUB_LOG="$SSH_LOG" STUB_EXIT=1 \
	XSERVER_HOST="203.0.113.11" XSERVER_KEY="$BASE/key" \
	bash "$INSTALLER" 2>&1)"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "installer: SSH pre-check failure -> exit 3" \
	|| bad "installer: SSH pre-check failure expected exit 3, got $RC (out: $OUT)"
[ "$(grep -c SSH_CALLED "$SSH_LOG")" = "1" ] \
	&& ok "installer: only the pre-check ran; the remote edit was never attempted" \
	|| bad "installer: expected exactly 1 ssh invocation, got $(grep -c SSH_CALLED "$SSH_LOG")"
teardown

# ==============================================================================
# Installer, remote half, driven against a FIXTURE wrapper
#
# The remote half honours FY_WRAPPER_PATH so the real edit logic — detect the
# api dir, back up, insert the snippet, syntax-check, verify — runs here
# end-to-end without a host. What is proven: after the edit the wrapper both
# handles the two new subdirectory prefixes AND still behaves exactly as
# before for its own flat filenames.
# ==============================================================================

make_fixture_wrapper() {
	# $1 = path to write, $2 = api dir it serves
	cat > "$1" <<FIXEOF
#!/usr/bin/env bash
set -euo pipefail
API_DIR="$2"
f="\${SSH_ORIGINAL_COMMAND:-}"
case "\$f" in
	validator.json|evidence.json)
		cat > "\$API_DIR/\$f"
		echo "OK: flat \$f"
		;;
	*)
		echo "rejected: \$f" >&2
		exit 1
		;;
esac
FIXEOF
	chmod +x "$1"
}

run_remote() {
	# $1 = wrapper path, $2 = dry-run flag, $3 = api dir override.
	# The wrapper path is the remote script's 5th POSITIONAL argument (never
	# an environment variable) — see case 24.
	bash "$BASE/remote.sh" "$B64" "$2" "$3" "FY-SUBDIR-ALLOWLIST-V1" "$1"
}

# ---- case 14: install into a fixture wrapper, then exercise it -------------
setup
B64="$(base64 < "$SNIPPET" | tr -d '\n')"
bash "$INSTALLER" --print-remote > "$BASE/remote.sh"
WRAP="$BASE/receive-metal-push"
make_fixture_wrapper "$WRAP" "$ROOT"

OUT="$(run_remote "$WRAP" 0 "" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "install: remote half installs into a fixture wrapper (exit 0)" \
	|| bad "install: expected exit 0, got $RC (out: $OUT)"
echo "$OUT" | grep -q "auto-detected: $ROOT" \
	&& ok "install: destination api dir auto-detected from the wrapper itself" \
	|| bad "install: api dir not auto-detected (out: $OUT)"
grep -q 'FY-SUBDIR-ALLOWLIST-V1' "$WRAP" \
	&& ok "install: marker present in the patched wrapper" \
	|| bad "install: marker absent from the patched wrapper"
grep -q '@@FY_SUBDIR_ROOT@@' "$WRAP" \
	&& bad "install: placeholder survived into the patched wrapper" \
	|| ok "install: placeholder substituted in the patched wrapper"
bash -n "$WRAP" \
	&& ok "install: patched wrapper passes bash -n" \
	|| bad "install: patched wrapper fails bash -n"
[ "$(find "$BASE" -maxdepth 1 -name 'receive-metal-push.bak-*' | wc -l | tr -d ' ')" = "1" ] \
	&& ok "install: exactly one backup of the wrapper was taken" \
	|| bad "install: expected exactly one backup file"

# the patched wrapper now handles a subdirectory push …
printf '{"archived":"receipt"}\n' > "$BASE/payload.json"
OUT="$(SSH_ORIGINAL_COMMAND="archive/anchor-receipt-${TX_HEX}.json" bash "$WRAP" < "$BASE/payload.json" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && [ -f "$ROOT/archive/anchor-receipt-${TX_HEX}.json" ] \
	&& ok "install: patched wrapper delivers archive/<receipt> to api/archive/" \
	|| bad "install: patched wrapper did not deliver the archive (rc=$RC, out: $OUT)"

# … and still behaves exactly as before for its own flat filenames.
printf '{"flat":true}\n' > "$BASE/flat.json"
OUT="$(SSH_ORIGINAL_COMMAND="validator.json" bash "$WRAP" < "$BASE/flat.json" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && [ -f "$ROOT/validator.json" ] \
	&& ok "install: pre-existing flat-filename behaviour is preserved" \
	|| bad "install: flat filename broke after the edit (rc=$RC, out: $OUT)"
OUT="$(SSH_ORIGINAL_COMMAND="secrets.env" bash "$WRAP" < "$BASE/flat.json" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "install: wrapper still rejects filenames on neither allowlist" \
	|| bad "install: wrapper accepted a non-allowlisted filename after the edit"

# idempotency: a second install is a no-op and takes no second backup.
OUT="$(run_remote "$WRAP" 0 "" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "install: re-running is idempotent (exit 0)" \
	|| bad "install: re-run expected exit 0, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'already installed' \
	&& ok "install: re-run reports 'already installed'" \
	|| bad "install: re-run did not report idempotency (out: $OUT)"
[ "$(find "$BASE" -maxdepth 1 -name 'receive-metal-push.bak-*' | wc -l | tr -d ' ')" = "1" ] \
	&& ok "install: re-run took no second backup" \
	|| bad "install: re-run created an extra backup"
[ "$(grep -c 'FY-SUBDIR-ALLOWLIST-V1' "$WRAP")" -le 4 ] \
	&& ok "install: the block was not inserted twice" \
	|| bad "install: the block appears to have been inserted twice"
teardown

# ---- case 15: dry-run writes nothing --------------------------------------
setup
B64="$(base64 < "$SNIPPET" | tr -d '\n')"
bash "$INSTALLER" --print-remote > "$BASE/remote.sh"
WRAP="$BASE/receive-metal-push"
make_fixture_wrapper "$WRAP" "$ROOT"
BEFORE="$(cksum < "$WRAP")"
OUT="$(run_remote "$WRAP" 1 "" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "dry-run: exits 0" \
	|| bad "dry-run: expected exit 0, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'DRY-RUN: wrapper NOT modified' \
	&& ok "dry-run: says explicitly that nothing was written" \
	|| bad "dry-run: missing the not-modified notice (out: $OUT)"
[ "$(cksum < "$WRAP")" = "$BEFORE" ] \
	&& ok "dry-run: wrapper is byte-identical afterwards" \
	|| bad "dry-run: wrapper was modified"
[ -z "$(find "$BASE" -maxdepth 1 -name 'receive-metal-push.bak-*')" ] \
	&& ok "dry-run: no backup file created" \
	|| bad "dry-run: a backup was created in dry-run mode"
echo "$OUT" | grep -q '^+.*FY-SUBDIR-ALLOWLIST-V1' \
	&& ok "dry-run: prints the diff the operator would be applying" \
	|| bad "dry-run: diff of the proposed change not shown (out: $OUT)"
teardown

# ---- case 16: ambiguous / absent api dir fails closed ---------------------
setup
B64="$(base64 < "$SNIPPET" | tr -d '\n')"
bash "$INSTALLER" --print-remote > "$BASE/remote.sh"
WRAP="$BASE/receive-metal-push"
mkdir -p "$BASE/other/api"
make_fixture_wrapper "$WRAP" "$ROOT"
# A genuinely ambiguous wrapper: two conflicting API_DIR *assignments*. A path
# mentioned only in a comment is not ambiguity — the resolver reads
# assignments, so prose about other directories must not stop an install.
printf 'API_DIR="%s"\n' "$BASE/other/api" >> "$WRAP"
OUT="$(run_remote "$WRAP" 0 "" 2>&1)"
RC=$?
[ "$RC" -eq 6 ] \
	&& ok "ambiguity: two conflicting API_DIR assignments -> exit 6, wrapper untouched" \
	|| bad "ambiguity: expected exit 6, got $RC (out: $OUT)"
grep -q 'FY-SUBDIR-ALLOWLIST-V1' "$WRAP" \
	&& bad "ambiguity: wrapper was modified despite the refusal" \
	|| ok "ambiguity: wrapper left unmodified"
# …and the operator's explicit override resolves it.
OUT="$(run_remote "$WRAP" 0 "$ROOT" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "ambiguity: FY_WEB_API_DIR override resolves it (exit 0)" \
	|| bad "ambiguity: override expected exit 0, got $RC (out: $OUT)"
teardown

setup
B64="$(base64 < "$SNIPPET" | tr -d '\n')"
bash "$INSTALLER" --print-remote > "$BASE/remote.sh"
OUT="$(run_remote "$BASE/no-such-wrapper" 0 "" 2>&1)"
RC=$?
[ "$RC" -eq 4 ] \
	&& ok "missing wrapper: remote half exits 4" \
	|| bad "missing wrapper: expected exit 4, got $RC (out: $OUT)"
OUT="$(run_remote "$BASE/receive-metal-push" 0 "$BASE/no-such-api-dir" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "missing api dir: remote half refuses (nonzero exit)" \
	|| bad "missing api dir: unexpectedly succeeded"
teardown

# ==============================================================================
# Regression: the two fail-opens found in review (2026-08-05), reproduced
# exactly as reported and re-run against the fixed block.
# ==============================================================================

# ---- case 17: JSON validation is unconditional (jq-absent fail-open) -------
# Reported: the JSON check ran only `if command -v jq`, so on a host without
# jq the content `THIS IS NOT JSON AT ALL {{{` landed on the public archive
# URL with rc=0 under a perfectly valid anchor filename — while the .gz
# branch was fail-closed. Asymmetric, and the archive side is the one an
# evaluator is told to verify against an on-chain memo.
setup
BIN="$(isolate_bin)"          # neither jq nor python3 on PATH
printf 'THIS IS NOT JSON AT ALL {{{\n' > "$BASE/evil"
printf '{"ok":true}\n'                 > "$BASE/good"
recv_isolated "$BIN" "archive/anchor-source-${DAG_HEX}.json" "$BASE/evil"
[ "$RC" -eq 6 ] \
	&& ok "no-validator: invalid JSON refused with exit 6 (was: accepted, rc=0)" \
	|| bad "no-validator: expected exit 6, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'no JSON validator on this host' \
	&& ok "no-validator: refusal names the missing tooling and the remedy" \
	|| bad "no-validator: message does not explain the refusal (out: $OUT)"
[ "$(landed_count)" = "0" ] \
	&& ok "no-validator: nothing landed on the public path" \
	|| bad "no-validator: a file landed on the public path"
# A VALID payload must be refused too: the point is that this host cannot
# verify content at all, so publishing anything unverified is the failure.
recv_isolated "$BIN" "archive/anchor-source-${DAG_HEX}.json" "$BASE/good"
[ "$RC" -eq 6 ] \
	&& ok "no-validator: even valid JSON refused (cannot verify != trust)" \
	|| bad "no-validator: valid payload expected exit 6, got $RC (out: $OUT)"
[ "$(orphan_count)" = "0" ] \
	&& ok "no-validator: no temp file left behind" \
	|| bad "no-validator: temp file left behind"
# peers-history stays fail-closed on the same host (gzip -t is always there).
printf 'plain bytes\n' > "$BASE/notgz"
recv_isolated "$BIN" "peers-history/peers-2026-08-05.json.gz" "$BASE/notgz"
[ "$RC" -eq 6 ] \
	&& ok "no-validator: .gz branch still fail-closed on the same host" \
	|| bad "no-validator: .gz branch expected exit 6, got $RC (out: $OUT)"
teardown

# ---- case 18: python3 fallback validator ----------------------------------
setup
BIN="$(isolate_bin python3)"   # jq absent, python3 present
printf 'THIS IS NOT JSON AT ALL {{{\n' > "$BASE/evil"
printf '{"ok":true}\n'                 > "$BASE/good"
if [ -x "$BIN/python3" ]; then
	recv_isolated "$BIN" "archive/anchor-source-${DAG_HEX}.json" "$BASE/evil"
	[ "$RC" -eq 6 ] \
		&& ok "python3-fallback: invalid JSON rejected without jq" \
		|| bad "python3-fallback: expected exit 6, got $RC (out: $OUT)"
	recv_isolated "$BIN" "archive/anchor-source-${DAG_HEX}.json" "$BASE/good"
	[ "$RC" -eq 0 ] && [ -f "$ROOT/archive/anchor-source-${DAG_HEX}.json" ] \
		&& ok "python3-fallback: valid JSON accepted without jq" \
		|| bad "python3-fallback: valid payload expected exit 0, got $RC (out: $OUT)"
else
	ok "python3-fallback: skipped (no python3 in the standard bin dirs)"
fi
teardown

# ---- case 19: newline in basename (line-oriented grep fail-open) ----------
# Reported: `printf '%s' "$base" | grep -Eq '^…$'` is line-oriented, so
# "archive/<valid>.json\nEVIL-SUFFIX" satisfied the pattern on its first
# line and was written under a filename containing a newline — while the
# sender rejects that same shape, breaking the "both sides enforce the same
# allowlist independently" property this design depends on.
setup
printf '{"ok":true}\n' > "$BASE/good"
NL_NAME="$(printf 'archive/anchor-source-%s.json\nEVIL-SUFFIX' "$DAG_HEX")"
recv "$NL_NAME" "$BASE/good"
[ "$RC" -eq 2 ] \
	&& ok "newline-basename: rejected with exit 2 (was: accepted, rc=0)" \
	|| bad "newline-basename: expected exit 2, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'illegal character in basename' \
	&& ok "newline-basename: rejection names the character-class rule" \
	|| bad "newline-basename: unexpected message (out: $OUT)"
[ "$(landed_count)" = "0" ] \
	&& ok "newline-basename: no file created under any name" \
	|| bad "newline-basename: a file was created ($(find "$BASE/webroot" -type f | cat -v))"
# The sender rejects the identical shape — the two halves now agree.
OUT="$(REPO_BASE="$BASE" WEB_PUSH_KEY="$BASE/good" WEB_HOST="deploy@203.0.113.11" \
	WEB_HOST_FILE="$BASE/none" bash "$PUSHER" "$NL_NAME" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] \
	&& ok "newline-basename: sender rejects the same shape (parity restored)" \
	|| bad "newline-basename: sender accepted it"
teardown

# ---- case 20: other control characters and metacharacters -----------------
setup
printf '{"ok":true}\n' > "$BASE/good"
for evil in \
	"archive/anchor-source-${DAG_HEX}.json ; id" \
	"$(printf 'archive/anchor-source-%s.json\tTAB' "$DAG_HEX")" \
	"archive/anchor-source-${DAG_HEX}.json\$(id)" \
	"archive/.hidden-${DAG_HEX}.json"
do
	recv "$evil" "$BASE/good"
	[ "$RC" -eq 2 ] || bad "charset: expected exit 2 for a metacharacter basename, got $RC"
done
[ "$(landed_count)" = "0" ] \
	&& ok "charset: whitespace / tab / \$( ) / dotfile basenames all rejected, nothing landed" \
	|| bad "charset: a metacharacter basename produced a file"
teardown

# ---- case 21: interrupted transfer leaves no orphan in the public dir -----
# The temp file has to live inside the public directory for the rename to be
# atomic, so a transfer cut off mid-push must not leave .push.XXXXXX behind
# where the web server would serve it.
setup
FIFO="$BASE/fifo"
mkfifo "$FIFO"
( printf 'partial-payload-'; sleep 5 ) > "$FIFO" &
WPID=$!
FY_SUBDIR_ROOT="$ROOT" SSH_ORIGINAL_COMMAND="archive/anchor-source-${DAG_HEX}.json" \
	bash "$SNIPPET" < "$FIFO" >/dev/null 2>&1 &
SPID=$!
SEEN=0
for _ in $(seq 1 60); do
	if [ "$(orphan_count)" != "0" ]; then SEEN=1; break; fi
	sleep 0.1
done
[ "$SEEN" = "1" ] \
	&& ok "interrupt: temp file observed in the public dir mid-transfer" \
	|| bad "interrupt: never observed the in-flight temp file (test setup issue)"
kill -TERM "$SPID" 2>/dev/null
kill "$WPID" 2>/dev/null
wait "$SPID" 2>/dev/null
wait "$WPID" 2>/dev/null
[ "$(orphan_count)" = "0" ] \
	&& ok "interrupt: no .push.* orphan left in the public dir" \
	|| bad "interrupt: orphan temp survived ($(find "$BASE/webroot" -name '.push.*'))"
[ ! -f "$ROOT/archive/anchor-source-${DAG_HEX}.json" ] \
	&& ok "interrupt: the truncated payload never landed under the real name" \
	|| bad "interrupt: a truncated payload landed"
teardown

# ---- case 22: an INSTALLED wrapper ignores FY_SUBDIR_ROOT -----------------
# The destination must not be steerable by the environment: this code runs
# under an authorized_keys forced command.
setup
B64="$(base64 < "$SNIPPET" | tr -d '\n')"
bash "$INSTALLER" --print-remote > "$BASE/remote.sh"
WRAP="$BASE/receive-metal-push"
make_fixture_wrapper "$WRAP" "$ROOT"
run_remote "$WRAP" 0 "" >/dev/null 2>&1
mkdir -p "$BASE/attacker"
printf '{"ok":true}\n' > "$BASE/good"
OUT="$(FY_SUBDIR_ROOT="$BASE/attacker" SSH_ORIGINAL_COMMAND="archive/anchor-receipt-${TX_HEX}.json" \
	bash "$WRAP" < "$BASE/good" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "env-pinning: installed wrapper still accepts the push" \
	|| bad "env-pinning: push failed (rc=$RC, out: $OUT)"
[ -f "$ROOT/archive/anchor-receipt-${TX_HEX}.json" ] \
	&& ok "env-pinning: bytes landed in the installed destination" \
	|| bad "env-pinning: bytes did not land in the installed destination"
[ -z "$(find "$BASE/attacker" -type f)" ] \
	&& ok "env-pinning: FY_SUBDIR_ROOT could not redirect the write" \
	|| bad "env-pinning: FY_SUBDIR_ROOT redirected the write to an attacker path"
grep -q "__fy_installed='yes'" "$WRAP" \
	&& ok "env-pinning: installed block is marked installed" \
	|| bad "env-pinning: installed marker not substituted"
teardown

# ---- case 23: installer honours a #!/bin/sh wrapper ----------------------
setup
B64="$(base64 < "$SNIPPET" | tr -d '\n')"
bash "$INSTALLER" --print-remote > "$BASE/remote.sh"
WRAP="$BASE/receive-metal-push"
make_fixture_wrapper "$WRAP" "$ROOT"
# Re-point the shebang at /bin/sh, as a POSIX wrapper would have it.
{ printf '#!/bin/sh\n'; tail -n +2 "$WRAP"; } > "$WRAP.sh" && mv "$WRAP.sh" "$WRAP"
chmod +x "$WRAP"
OUT="$(run_remote "$WRAP" 0 "" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "sh-wrapper: installs into a #!/bin/sh wrapper" \
	|| bad "sh-wrapper: expected exit 0, got $RC (out: $OUT)"
echo "$OUT" | grep -q 'passes sh -n' \
	&& ok "sh-wrapper: syntax-checked with sh -n, not bash -n" \
	|| bad "sh-wrapper: did not use the shebang's interpreter (out: $OUT)"
printf '{"ok":true}\n' > "$BASE/good"
OUT="$(SSH_ORIGINAL_COMMAND="archive/anchor-receipt-${TX_HEX}.json" sh "$WRAP" < "$BASE/good" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] && [ -f "$ROOT/archive/anchor-receipt-${TX_HEX}.json" ] \
	&& ok "sh-wrapper: the patched wrapper runs correctly under sh" \
	|| bad "sh-wrapper: patched wrapper failed under sh (rc=$RC, out: $OUT)"
teardown

# ---- case 24: the wrapper path is positional, not environment-driven -----
setup
B64="$(base64 < "$SNIPPET" | tr -d '\n')"
bash "$INSTALLER" --print-remote > "$BASE/remote.sh"
WRAP="$BASE/receive-metal-push"
make_fixture_wrapper "$WRAP" "$ROOT"
# Env var set, positional override empty: must fall back to the pinned
# production path (absent here) rather than edit the fixture.
OUT="$(FY_WRAPPER_PATH="$WRAP" bash "$BASE/remote.sh" "$B64" 0 "" "FY-SUBDIR-ALLOWLIST-V1" "" 2>&1)"
RC=$?
[ "$RC" -eq 4 ] \
	&& ok "wrapper-pinning: FY_WRAPPER_PATH in the environment is ignored" \
	|| bad "wrapper-pinning: environment steered the target (rc=$RC, out: $OUT)"
grep -q 'FY-SUBDIR-ALLOWLIST-V1' "$WRAP" \
	&& bad "wrapper-pinning: the fixture wrapper was edited via the environment" \
	|| ok "wrapper-pinning: the fixture wrapper was left untouched"
teardown

# ---- summary ---------------------------------------------------------------
echo "test-install-xserver-subdir-allowlist.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
