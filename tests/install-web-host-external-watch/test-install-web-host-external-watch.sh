#!/usr/bin/env bash
# tests/install-web-host-external-watch/test-install-web-host-external-watch.sh
#
# scripts/install-web-host-external-watch.sh — the Mac-run installer that puts
# the off-host watchdog on the (multi-tenant) web host.
#
# CHAIN: none — no network, no real SSH. Both remote halves run locally under
# SKIP_SSH=1 against a fake account home and a fake `crontab` on PATH; the
# real-mode argv/stdin discipline is checked with a recording `ssh` stub.
# The self-test runs the real scripts/external-watch.sh with curl / timeout /
# flock stubbed, WATCH_LIVE never set. Addresses are RFC5737; the topic is
# generated at run time. PRIME_DIRECTIVE: safe.
#
# What must never regress (each is shown to fail under a mutation, G9 —
# see the task report):
#   - co-tenant crontab lines outside the markers stay byte-identical
#   - a failed post-write verification restores the original crontab
#   - re-run is a no-op; a changed block is replaced, never duplicated
#   - --uninstall removes only the block
#   - the validator host value and the topic never reach stdout/stderr/argv
#   - modes: dirs 700, scripts 700, etc/* 600
#   - --dry-run writes nothing
#
# Usage: bash tests/install-web-host-external-watch/test-install-web-host-external-watch.sh
# Exit:  0 all PASS / 1 any FAIL
#
# shellcheck disable=SC2016,SC2034,SC2086
# SC2016/SC2034: assertions are single-quoted strings eval'd by check(), so
# variables expand at assertion time. SC2086: ${EXTRA_ENV} is word-split on
# purpose (it carries VAR=value pairs for env).

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${INSTALLER_UNDER_TEST:-$REPO/scripts/install-web-host-external-watch.sh}"
WATCH_SRC="$REPO/scripts/external-watch.sh"
NOTIFY_SRC="$REPO/scripts/notify.sh"

for t in jq base64 awk; do
	command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not available"; exit 0; }
done
if [ "$(id -u)" = 0 ]; then
	echo "SKIP: must not run as root (the installer refuses a root watch account)"; exit 0
fi

T="$(mktemp -d -t ew-installer-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1${3:+ — $3}"; fi; }

ME="$(id -un)"
VH="203.0.113.57"
TOPIC="faketopic-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
JQ_DIR="$(dirname "$(command -v jq)")"

meta() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# ---- stubs -------------------------------------------------------------------
CRONBIN="$T/cronbin"; STUB="$T/stub"; SSHBIN="$T/sshbin"
mkdir -p "$CRONBIN" "$STUB" "$SSHBIN"
cat > "$CRONBIN/crontab" <<'EOF'
#!/usr/bin/env bash
# Fake crontab: -u U -l | -u U -r | -u U <file>. FAKE_CRON_MANGLE_ONCE=1 makes
# the FIRST write alter a co-tenant line (a broken cron write), later writes
# (the restore) behave. FAKE_CRON_EDIT_ON_LIST=N: a co-tenant appends a line
# right after the Nth `-l`. FAKE_CRON_LIST_FAIL_FROM=N: the Nth and later `-l`
# fail. =append: the first write gains a stray line instead.
[ "$1" = -u ] || { echo "fake crontab: -u required" >&2; exit 64; }
u="$2"; shift 2
case "$1" in
	-l) echo l >> "$FAKE_CRON_WRITES.lists"; n="$(wc -l < "$FAKE_CRON_WRITES.lists" | tr -d ' ')"
	    if [ -n "${FAKE_CRON_LIST_FAIL_FROM:-}" ] && [ "$n" -ge "$FAKE_CRON_LIST_FAIL_FROM" ]; then
	        echo "crontab: cannot open spool (simulated)" >&2; exit 1
	    fi
	    if [ -e "$FAKE_CRON_STORE" ]; then cat "$FAKE_CRON_STORE"; else echo "no crontab for $u" >&2; rc=1; fi
	    # A co-tenant edits the crontab right after our Nth read.
	    [ "${FAKE_CRON_EDIT_ON_LIST:-0}" = "$n" ] && echo "# co-tenant edit $n" >> "$FAKE_CRON_STORE"
	    exit "${rc:-0}" ;;
	-r) rm -f "$FAKE_CRON_STORE" ;;
	*)  echo w >> "$FAKE_CRON_WRITES"
	    first=0; [ "$(wc -l < "$FAKE_CRON_WRITES" | tr -d ' ')" = 1 ] && first=1
	    if [ "${FAKE_CRON_MANGLE_ONCE:-0}" = 1 ] && [ "$first" = 1 ]; then
	        sed 's/cotenant-a/cotenant-X/' "$1" > "$FAKE_CRON_STORE"
	    elif [ "${FAKE_CRON_MANGLE_ONCE:-0}" = append ] && [ "$first" = 1 ]; then
	        { cat "$1"; echo "# stray line"; } > "$FAKE_CRON_STORE"
	    else
	        cat "$1" > "$FAKE_CRON_STORE"
	    fi ;;
esac
EOF
printf '#!/bin/sh\nprintf %%s %s\n' "'{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"validators\":[]}}'" > "$STUB/curl"
printf '#!/bin/sh\nexit 0\n' > "$STUB/timeout"
printf '#!/bin/sh\nexit 0\n' > "$STUB/flock"
cat > "$SSHBIN/ssh" <<'EOF'
#!/usr/bin/env bash
# Recording ssh stub: argv -> $SSH_LOG (one line per call), stdin -> numbered file.
printf '%s' "$*" | tr '\n' ' ' >> "$SSH_LOG"; printf '\n' >> "$SSH_LOG"
last="${!#}"
n="$(wc -l < "$SSH_LOG" | tr -d ' ')"
if [ "${STUB_SSH_FAIL:-0}" = 1 ]; then
	for a in "$@"; do case "$a" in *@*) echo "ssh: connect to host 198.51.100.7 port 22: Connection refused (${a})" >&2 ;; esac; done
	exit 255
fi
if [ "${STUB_SSH_NOISE:-0}" = 1 ]; then
	echo "Warning: Permanently added '198.51.100.7' (ED25519) to the list of known hosts." >&2
	echo "debug: opuser@203.0.113.57 root@198.51.100.23 via [2001:db8::7]" >&2
fi
case "$last" in
	'exit 0') exit 0 ;;
	'cat -- '*) printf '%s\n' "$STUB_TOPIC"; exit 0 ;;
	'test -s '*) exit 0 ;;
	*) cat > "$SSH_STDIN_DIR/$n"; exit 0 ;;
esac
EOF
chmod +x "$CRONBIN/crontab" "$STUB"/* "$SSHBIN/ssh"

# ---- fixture web host ----------------------------------------------------------
H=""; STORE=""; WRITES=""
fresh_fixture() {
	rm -rf "$T/fx"; mkdir -p "$T/fx/home/bin" "$T/fx/webroot/api"
	H="$T/fx/home"; STORE="$T/fx/crontab.store"; WRITES="$T/fx/crontab.writes"
	chmod 755 "$H"
	printf '#!/bin/bash\n# wrapper fixture\n__fy_root='"'"'%s'"'"'\n' "$T/fx/webroot/api" > "$H/bin/receive-metal-push"
	printf '{"observedAt":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$T/fx/webroot/api/validator.json"
	printf '%s\n' "$TOPIC" > "$T/fx/validator-topic"
	: > "$WRITES"; rm -f "$WRITES.lists"
}
cotenant_crontab() { # two co-tenant jobs, comments, blank lines, trailing spaces
	printf '# co-tenant project A\nMAILTO=""\n*/10 * * * * /srv/cotenant-a/run.sh  \n\n# co-tenant B\n0 3 * * * /srv/cotenant-b/nightly.sh >/dev/null 2>&1\n' > "$STORE"
}
BEGIN_MARK='# BEGIN metal-fy-external-watch'
END_MARK='# END metal-fy-external-watch'
# shellcheck disable=SC2016  # literal $HOME is the armed cron line
CRON_LINE='*/5 * * * * WATCH_LIVE=1 /bin/bash $HOME/metal-fy-watch/bin/external-watch.sh >>$HOME/metal-fy-watch/log/cron.err 2>&1'
outside() { awk -v b="$BEGIN_MARK" -v e="$END_MARK" 'i==0&&$0==b{i=1;next} i==1&&$0==e{i=0;next} i==0{print}' "$1"; }
nbegin() { grep -cxF "$BEGIN_MARK" "$1" 2>/dev/null || true; }

ALL_OUT="$T/all-output"; : > "$ALL_OUT"
OUT=""; RC=0
run() { # run the installer in SKIP_SSH mode
	OUT="$(env SKIP_SSH=1 SKIP_SSH_HOME="$H" \
		SKIP_SSH_SELFTEST_PATH="$STUB:/usr/bin:/bin:$JQ_DIR" \
		WATCH_ACCOUNT="$ME" VALIDATOR_HOST="$VH" VALIDATOR_TOPIC_FILE="$T/fx/validator-topic" \
		FAKE_CRON_STORE="$STORE" FAKE_CRON_WRITES="$WRITES" \
		PATH="$CRONBIN:$PATH" ${EXTRA_ENV:-} bash "$INSTALLER" "$@" 2>&1 </dev/null)"
	RC=$?
	printf '%s\n' "$OUT" >> "$ALL_OUT"
}
nwrites() { wc -l < "$WRITES" | tr -d ' '; }

# ==============================================================================
# static
# ==============================================================================
REMOTE="$T/remote.sh"
VALIDATOR_HOST="$VH" WEB_HOST=198.51.100.23 bash "$INSTALLER" --print-remote > "$REMOTE" 2>"$T/pr.err"
PR_RC=$?
check "--print-remote exits 0 with no host" '[ "$PR_RC" -eq 0 ] && [ -s "$REMOTE" ]'
check "--print-remote output passes bash -n" 'bash -n "$REMOTE"'
check "--print-remote embeds no host value" '! grep -qF "$VH" "$REMOTE" && ! grep -qF 198.51.100.23 "$REMOTE"'
check "remote carries the exact markers" 'grep -qxF "BEGIN_MARK='"'"'$BEGIN_MARK'"'"'" "$REMOTE" && grep -qxF "END_MARK='"'"'$END_MARK'"'"'" "$REMOTE"'
check "remote carries the exact cron line" 'grep -qxF "CRON_LINE='"'"'$CRON_LINE'"'"'" "$REMOTE"'
check "SSH_OPTS is hardened (LogLevel, IdentitiesOnly, no agent/forwarding)" \
	'grep -A1 "^SSH_OPTS=(" "$INSTALLER" | tr "\n" " " | grep -qE "BatchMode=yes.*LogLevel=ERROR.*IdentitiesOnly=yes.*ForwardAgent=no.*ClearAllForwardings=yes"'
check "installer never enables xtrace" '! grep -nE "^[^#]*(set -[a-wyz]*x|set -o xtrace|bash -x)" "$INSTALLER"'

# ==============================================================================
# fresh install onto a crontab with co-tenants
# ==============================================================================
fresh_fixture; cotenant_crontab; cp "$STORE" "$T/orig"
run
W="$H/metal-fy-watch"
check "fresh install exits 0" '[ "$RC" -eq 0 ]' "rc=$RC: $(printf '%s' "$OUT" | tail -5)"
check "crontab: exactly one block" '[ "$(nbegin "$STORE")" = 1 ]'
check "crontab: co-tenant lines byte-identical" 'outside "$STORE" | cmp -s - "$T/orig"'
check "crontab: block is exactly markers + line, at the end" \
	'tail -n 3 "$STORE" | cmp -s - <(printf "%s\n" "$BEGIN_MARK" "$CRON_LINE" "$END_MARK")'
check "crontab: backup taken before the write" 'cmp -s "$T/orig" "$(ls "$W"/backup/crontab.bak-* | head -1)"'
check "bin/external-watch.sh identical to repo" 'cmp -s "$WATCH_SRC" "$W/bin/external-watch.sh"'
check "bin/notify.sh identical to repo" 'cmp -s "$NOTIFY_SRC" "$W/bin/notify.sh"'
check "etc/ntfy-topic holds the streamed topic" 'cmp -s "$T/fx/validator-topic" "$W/etc/ntfy-topic"'
check "watch.env: VALIDATOR_HOST" 'grep -qxF "VALIDATOR_HOST=$VH" "$W/etc/watch.env"'
check "watch.env: VALIDATOR_JSON from __fy_root" 'grep -qxF "VALIDATOR_JSON=$T/fx/webroot/api/validator.json" "$W/etc/watch.env"'
check "watch.env: NTFY_TOPIC_FILE" 'grep -qxF "NTFY_TOPIC_FILE=$W/etc/ntfy-topic" "$W/etc/watch.env"'
MODES_OK=1
for d in "" /bin /etc /state /log /backup; do [ "$(meta "$W$d")" = 700 ] || MODES_OK=0; done
for f in bin/external-watch.sh bin/notify.sh; do [ "$(meta "$W/$f")" = 700 ] || MODES_OK=0; done
for f in etc/watch.env etc/ntfy-topic; do [ "$(meta "$W/$f")" = 600 ] || MODES_OK=0; done
check "modes: dirs 700, scripts 700, etc/* 600" '[ "$MODES_OK" = 1 ]'
check "self-test ran and its log line was printed" 'printf "%s" "$OUT" | grep -qE "log: .*fresh=PASS"'
check "self-test did not put any check into alerting (WATCH_LIVE unset)" \
	'[ ! -e "$W/state/state.json" ] || ! grep -q alerting "$W/state/state.json"'
check "output: topic confirmed without its value" 'printf "%s" "$OUT" | grep -q "topic: new — non-empty, mode 600"'

# ---- re-run is a no-op --------------------------------------------------------
cp "$STORE" "$T/after1"; W1="$(nwrites)"
run
check "re-run exits 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "re-run: already up to date" 'printf "%s" "$OUT" | grep -q "already up to date"'
check "re-run: crontab not rewritten" '[ "$(nwrites)" = "$W1" ] && cmp -s "$STORE" "$T/after1"'
check "re-run: files unchanged" 'printf "%s" "$OUT" | grep -q "bin/external-watch.sh: unchanged"'

# ---- changed block is replaced in place, not duplicated -------------------------
fresh_fixture
printf '# co-tenant before\n1 1 * * * /srv/cotenant-a/x\n%s\n*/9 * * * * old line\n%s\n# co-tenant after\n2 2 * * * /srv/cotenant-b/y\n' \
	"$BEGIN_MARK" "$END_MARK" > "$STORE"
cp "$STORE" "$T/orig"
run
check "changed block: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "changed block: still exactly one block" '[ "$(nbegin "$STORE")" = 1 ]'
check "changed block: old line gone, new line present" '! grep -qF "old line" "$STORE" && grep -qxF "$CRON_LINE" "$STORE"'
check "changed block: lines before/after identical and in place" \
	'outside "$STORE" | cmp -s - <(outside "$T/orig") && [ "$(sed -n 3p "$STORE")" = "$BEGIN_MARK" ] && [ "$(tail -n 1 "$STORE")" = "2 2 * * * /srv/cotenant-b/y" ]'

# ---- no trailing newline --------------------------------------------------------
fresh_fixture
printf '# co-tenant\n5 5 * * * /srv/cotenant-a/z' > "$STORE"
run
check "no trailing newline: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "no trailing newline: co-tenant bytes kept (only the missing newline added)" \
	'outside "$STORE" | cmp -s - <(printf "# co-tenant\n5 5 * * * /srv/cotenant-a/z\n")'

# ---- no crontab at all ----------------------------------------------------------
fresh_fixture
run
check "no crontab: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "no crontab: crontab is exactly the block" 'cmp -s "$STORE" <(printf "%s\n" "$BEGIN_MARK" "$CRON_LINE" "$END_MARK")'

# ---- verification failure restores ----------------------------------------------
fresh_fixture; cotenant_crontab; cp "$STORE" "$T/orig"
EXTRA_ENV="FAKE_CRON_MANGLE_ONCE=1" run
check "mangled write: exit 7" '[ "$RC" -eq 7 ]' "rc=$RC"
check "mangled write: original crontab restored byte-for-byte" 'cmp -s "$STORE" "$T/orig"'
check "mangled write: failure explained" 'printf "%s" "$OUT" | grep -q "lines outside the markers changed" && printf "%s" "$OUT" | grep -q "byte-identical to the backup"'

fresh_fixture
EXTRA_ENV="FAKE_CRON_MANGLE_ONCE=append" run
check "no crontab before + bad write: exit 7 and the crontab removed again" \
	'[ "$RC" -eq 7 ] && [ ! -e "$STORE" ]' "rc=$RC"

# ---- concurrent co-tenant edit (Fix round 1 #1) ----------------------------------
# -l order on a fresh install: 1 = snapshot (after the self-test), 2 = re-check
# right before the write, 3 = verification read.
fresh_fixture; cotenant_crontab
EXTRA_ENV="FAKE_CRON_EDIT_ON_LIST=1" run
check "co-tenant edit before our write: exit 9" '[ "$RC" -eq 9 ]' "rc=$RC"
check "co-tenant edit before our write: nothing written, their edit kept" \
	'[ "$(nwrites)" = 0 ] && grep -qxF "# co-tenant edit 1" "$STORE" && [ "$(nbegin "$STORE")" = 0 ]'
check "co-tenant edit before our write: operator told to re-run" 'printf "%s" "$OUT" | grep -q "Re-run the installer"'

fresh_fixture; cotenant_crontab
EXTRA_ENV="FAKE_CRON_MANGLE_ONCE=1 FAKE_CRON_EDIT_ON_LIST=3" run
check "co-tenant edit after a bad write: CRITICAL exit 10, no blind restore" \
	'[ "$RC" -eq 10 ] && [ "$(nwrites)" = 1 ] && grep -qxF "# co-tenant edit 3" "$STORE"' "rc=$RC"
check "co-tenant edit after a bad write: backup path given" 'printf "%s" "$OUT" | grep -q "Backup: ~$ME/metal-fy-watch/backup/crontab.bak-"'

# ---- crontab unreadable after our write (Fix round 1 #5) --------------------------
fresh_fixture; cotenant_crontab
EXTRA_ENV="FAKE_CRON_LIST_FAIL_FROM=3" run
check "crontab unreadable after write: CRITICAL exit 10 with backup path" \
	'[ "$RC" -eq 10 ] && printf "%s" "$OUT" | grep -q "CRITICAL (10).*re-read" && printf "%s" "$OUT" | grep -q "Backup: ~$ME/metal-fy-watch/backup/crontab.bak-"' "rc=$RC"
fresh_fixture; cotenant_crontab
EXTRA_ENV="FAKE_CRON_MANGLE_ONCE=1 FAKE_CRON_LIST_FAIL_FROM=4" run
check "crontab unreadable before restore: CRITICAL exit 10" '[ "$RC" -eq 10 ]' "rc=$RC"
fresh_fixture; cotenant_crontab
EXTRA_ENV="FAKE_CRON_MANGLE_ONCE=1 FAKE_CRON_LIST_FAIL_FROM=5" run
check "crontab unreadable after restore: CRITICAL exit 10" '[ "$RC" -eq 10 ]' "rc=$RC"

# ---- planted symlinks (Fix round 1 #4) -------------------------------------------
fresh_fixture; cotenant_crontab; mkdir -p "$T/fx/elsewhere"
ln -s "$T/fx/elsewhere" "$H/metal-fy-watch"
run
check "watch dir is a symlink: exit 5, nothing written through it" \
	'[ "$RC" -eq 5 ] && [ -z "$(ls -A "$T/fx/elsewhere")" ] && [ "$(nwrites)" = 0 ]' "rc=$RC"
fresh_fixture; mkdir -p "$T/fx/elsewhere" "$H/metal-fy-watch"
ln -s "$T/fx/elsewhere" "$H/metal-fy-watch/etc"
run
check "etc/ is a symlink: exit 5, topic not written through it" \
	'[ "$RC" -eq 5 ] && [ -z "$(ls -A "$T/fx/elsewhere")" ]' "rc=$RC"

# ---- malformed markers: nothing written -----------------------------------------
fresh_fixture
printf '%s\n%s\n1 1 * * * /srv/cotenant-a/x\n' "$BEGIN_MARK" "$BEGIN_MARK" > "$STORE"; cp "$STORE" "$T/orig"
run
check "two BEGIN markers: exit 9" '[ "$RC" -eq 9 ]' "rc=$RC"
check "two BEGIN markers: crontab untouched" '[ "$(nwrites)" = 0 ] && cmp -s "$STORE" "$T/orig"'

# ---- dry-run changes nothing ----------------------------------------------------
fresh_fixture; cotenant_crontab; cp "$STORE" "$T/orig"
run --dry-run
check "dry-run: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "dry-run: no metal-fy-watch dir created" '[ ! -e "$H/metal-fy-watch" ]'
check "dry-run: crontab untouched" '[ "$(nwrites)" = 0 ] && cmp -s "$STORE" "$T/orig"'
check "dry-run: shows the block lines only (no co-tenant context)" \
	'printf "%s" "$OUT" | grep -qF "+$CRON_LINE" && ! printf "%s" "$OUT" | grep -qF "cotenant-a"'

# ---- api dir detection ----------------------------------------------------------
fresh_fixture
printf "__fy_root='/srv/other/api'\n" >> "$H/bin/receive-metal-push"
run
check "two __fy_root dirs: exit 6, nothing written" '[ "$RC" -eq 6 ] && [ "$(nwrites)" = 0 ]' "rc=$RC"
mkdir -p "$T/fx/alt/api"
EXTRA_ENV="FY_WEB_API_DIR=$T/fx/alt/api" run
check "FY_WEB_API_DIR override wins" '[ "$RC" -eq 0 ] && grep -qxF "VALIDATOR_JSON=$T/fx/alt/api/validator.json" "$H/metal-fy-watch/etc/watch.env"' "rc=$RC"
fresh_fixture; rm "$H/bin/receive-metal-push"
run
check "no push wrapper and no override: exit 6" '[ "$RC" -eq 6 ]' "rc=$RC"

# ---- topic rejected -------------------------------------------------------------
fresh_fixture; cotenant_crontab; : > "$T/fx/validator-topic"
run
check "empty topic: exit 5" '[ "$RC" -eq 5 ]' "rc=$RC"
check "empty topic: no topic file, crontab untouched" '[ ! -e "$H/metal-fy-watch/etc/ntfy-topic" ] && [ "$(nwrites)" = 0 ]'

# ---- self-test failure blocks arming --------------------------------------------
fresh_fixture; cotenant_crontab; cp "$STORE" "$T/orig"
printf '#!/usr/bin/env bash\necho "[external-watch] config error: x" >&2\nexit 1\n' > "$T/bad-watch.sh"
EXTRA_ENV="SKIP_SSH_WATCH_SRC=$T/bad-watch.sh" run
check "self-test rc!=0: installer exits 8" '[ "$RC" -eq 8 ]' "rc=$RC"
check "self-test rc!=0: surfaced clearly" 'printf "%s" "$OUT" | grep -q "watch self-test failed: rc=1"'
check "self-test rc!=0: crontab not armed" '[ "$(nwrites)" = 0 ] && cmp -s "$STORE" "$T/orig"'
check "crontab is read only after the self-test (minimal race window)" '[ ! -e "$WRITES.lists" ]'

# ---- uninstall ------------------------------------------------------------------
fresh_fixture; cotenant_crontab; cp "$STORE" "$T/orig"
run
run --uninstall --dry-run
check "uninstall dry-run: nothing removed" '[ "$RC" -eq 0 ] && [ -d "$H/metal-fy-watch" ] && [ "$(nbegin "$STORE")" = 1 ]' "rc=$RC"
run --uninstall
check "uninstall: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "uninstall: crontab back to exactly the co-tenant lines" 'cmp -s "$STORE" "$T/orig"'
check "uninstall: metal-fy-watch removed" '[ ! -e "$H/metal-fy-watch" ]'
check "uninstall: crontab backup kept in the home (600)" \
	'b="$(ls "$H"/metal-fy-watch-crontab.bak-* 2>/dev/null | head -1)"; [ -n "$b" ] && [ "$(meta "$b")" = 600 ] && [ "$(nbegin "$b")" = 1 ]'
run --uninstall
check "uninstall again: no-op" '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "no metal-fy-external-watch block" && cmp -s "$STORE" "$T/orig"'

# ---- local preconditions --------------------------------------------------------
fresh_fixture
EXTRA_ENV="WATCH_ACCOUNT=Bad;name" run
check "malformed WATCH_ACCOUNT: exit 2" '[ "$RC" -eq 2 ]' "rc=$RC"
EXTRA_ENV="VALIDATOR_HOST=bad;host" run
check "malformed VALIDATOR_HOST: exit 2" '[ "$RC" -eq 2 ]' "rc=$RC"

# ---- the remote half itself never prints the host (the Mac-side mask is only
# a second layer, so it is bypassed here by running the printed remote raw) ----
fresh_fixture; cotenant_crontab
printf '%s\n' "$TOPIC" | FAKE_CRON_STORE="$STORE" FAKE_CRON_WRITES="$WRITES" PATH="$CRONBIN:$PATH" \
	bash "$REMOTE" topic 0 "$ME" "" "$H" "" > "$T/raw.out" 2>&1
{ printf '%s\n' "$VH"; base64 < "$WATCH_SRC" | tr -d '\n'; echo; base64 < "$NOTIFY_SRC" | tr -d '\n'; echo; } \
	| FAKE_CRON_STORE="$STORE" FAKE_CRON_WRITES="$WRITES" PATH="$CRONBIN:$PATH" \
	bash "$REMOTE" install 0 "$ME" "" "$H" "$STUB:/usr/bin:/bin:$JQ_DIR" >> "$T/raw.out" 2>&1
RAW_RC=$?
check "raw remote install: exit 0" '[ "$RAW_RC" -eq 0 ]' "rc=$RAW_RC"
check "raw remote output (unmasked) has no validator host and no topic" \
	'! grep -qF "$VH" "$T/raw.out" && ! grep -qF "$TOPIC" "$T/raw.out"'
check "raw remote output names no on-host absolute path" '! grep -qF "$T/fx" "$T/raw.out"'

# ==============================================================================
# real mode against a recording ssh stub: argv / stdin discipline
# ==============================================================================
printf 'dummy\n' > "$T/key"
SSH_LOG="$T/ssh.log"; SSH_STDIN_DIR="$T/sshin"; mkdir -p "$SSH_STDIN_DIR"
real() {
	: > "$SSH_LOG"; rm -f "$SSH_STDIN_DIR"/*
	OUT="$(env PATH="$SSHBIN:$PATH" SSH_LOG="$SSH_LOG" SSH_STDIN_DIR="$SSH_STDIN_DIR" STUB_TOPIC="$TOPIC" \
		WEB_HOST=198.51.100.23 WEB_HOST_KEY="$T/key" VALIDATOR_HOST="$VH" VALIDATOR_SSH_USER=opuser \
		VALIDATOR_SSH_KEY="$T/key" VALIDATOR_TOPIC_FILE=/fake/topic ${EXTRA_ENV:-} \
		bash "$INSTALLER" "$@" 2>&1 </dev/null)"
	RC=$?
	printf '%s\n' "$OUT" >> "$ALL_OUT"
}
real
check "real mode (stub ssh): exit 0" '[ "$RC" -eq 0 ]' "rc=$RC: $OUT"
check "real mode: topic never in any ssh argv" '! grep -qF "$TOPIC" "$SSH_LOG"'
check "real mode: validator host never in web-host argv" '! grep -F 198.51.100.23 "$SSH_LOG" | grep -qF "$VH"'
check "real mode: every ssh call is BatchMode with a key" '[ "$(grep -c . "$SSH_LOG")" -ge 4 ] && ! grep -v -- "-o BatchMode=yes" "$SSH_LOG" | grep -q . && ! grep -v -- "-i $T/key" "$SSH_LOG" | grep -q .'
check "real mode: topic travelled on the web host session stdin" 'grep -lxF "$TOPIC" "$SSH_STDIN_DIR"/* >/dev/null 2>&1'
check "real mode: validator host travelled on stdin, not argv" 'grep -lxF "$VH" "$SSH_STDIN_DIR"/* >/dev/null 2>&1'
check "real mode: every ssh call carries the hardening options" \
	'! grep -vE -- "-o LogLevel=ERROR.*-o IdentitiesOnly=yes -o ForwardAgent=no -o ClearAllForwardings=yes" "$SSH_LOG" | grep -q .'
EXTRA_ENV="STUB_SSH_NOISE=1" real
check "noisy ssh: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "noisy ssh: resolved IP, user@host and IPv6 never reach the output" \
	'! printf "%s" "$OUT" | grep -qE "198\.51\.100\.7|203\.0\.113\.57|198\.51\.100\.23|opuser|root@|2001:db8" && printf "%s" "$OUT" | grep -qF "<ssh user>@" && printf "%s" "$OUT" | grep -qF "[<ip>]"' "$OUT"
EXTRA_ENV="STUB_SSH_FAIL=1" real
check "real mode: pre-check failure exits 3" '[ "$RC" -eq 3 ]' "rc=$RC"
check "real mode: pre-check prints a generic error, never ssh's own text" \
	'printf "%s" "$OUT" | grep -qF "<web host> (ssh rc=255)" && ! printf "%s" "$OUT" | grep -qE "Connection refused|198\.51\.100\.(7|23)|opuser"'
EXTRA_ENV="WEB_HOST_KEY=" real
check "real mode: WEB_HOST_KEY required, no ssh attempted" '[ "$RC" -eq 2 ] && [ ! -s "$SSH_LOG" ]' "rc=$RC"
real --uninstall --dry-run
check "real mode: uninstall needs no validator ssh" '[ "$RC" -eq 0 ] && ! grep -q opuser@ "$SSH_LOG"' "rc=$RC"

# ==============================================================================
# secrets never printed, across every run above
# ==============================================================================
check "no run printed the validator host" '! grep -qF "$VH" "$ALL_OUT"'
check "no run printed the topic" '! grep -qF "$TOPIC" "$ALL_OUT"'
check "no run printed the web host or key path" '! grep -qF 198.51.100.23 "$ALL_OUT" && ! grep -qF "$T/key" "$ALL_OUT"'

echo
echo "test-install-web-host-external-watch.sh summary: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
