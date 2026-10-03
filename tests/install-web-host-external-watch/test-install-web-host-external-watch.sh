#!/usr/bin/env bash
# tests/install-web-host-external-watch/test-install-web-host-external-watch.sh
#
# scripts/install-web-host-external-watch.sh — the Mac-run installer that puts
# the off-host watchdog on the (multi-tenant) web host.
#
# CHAIN: none — no network, no real SSH. Both remote halves run locally under
# SKIP_SSH=1 against a fake account home and a fake `crontab` on PATH; the
# real-mode argv/stdin discipline is checked with a recording `ssh` stub.
# pbcopy/pbpaste are ALWAYS stubbed (a file under $T), so the real Mac
# clipboard is never touched. The self-test runs the real
# scripts/external-watch.sh with curl / timeout / flock stubbed, WATCH_LIVE
# never set. Addresses are RFC5737; every topic is generated at run time.
# PRIME_DIRECTIVE: safe.
#
# What must never regress (each is shown to fail under a mutation, G9 —
# see the task report):
#   - co-tenant crontab lines outside the markers stay byte-identical
#   - a failed post-write verification restores the original crontab
#   - re-run is a no-op; a changed block is replaced, never duplicated
#   - --uninstall removes only the block
#   - the validator host value and the topic never reach stdout/stderr/argv
#   - the validator host is never contacted (no ssh to it at all)
#   - the watch gets its own topic, generated on the web host, kept on
#     re-run, never adopted from another shape; handed over only via pbcopy
#   - modes: dirs 700, scripts 700, etc/* 600
#   - --dry-run writes nothing
#   - the self-test never runs LIVE
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

# A SKIP must never read as green in CI (GitHub sets CI=true).
skip_or_fail() {
	if [ -n "${CI:-}" ]; then echo "FAIL: $1 (CI must run this suite)"; exit 1; fi
	echo "SKIP: $1"; exit 0
}
for t in jq base64 awk od; do
	command -v "$t" >/dev/null 2>&1 || skip_or_fail "$t not available"
done
if [ "$(id -u)" = 0 ]; then
	skip_or_fail "must not run as root (the installer refuses a root watch account)"
fi

T="$(mktemp -d -t ew-installer-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1${3:+ — $3}"; fi; }

ME="$(id -un)"
VH="203.0.113.57"
# Dedicated-shape fake topic for the ssh stub, assembled at run time.
STUB_TOPIC="$(printf 'fy-metal-%s' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')")"
TOPIC_RE='^fy-metal-[0-9a-f]{32}$'
JQ_DIR="$(dirname "$(command -v jq)")"
CLIP="$T/clipboard"

meta() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# ---- stubs -------------------------------------------------------------------
CRONBIN="$T/cronbin"; STUB="$T/stub"; SSHBIN="$T/sshbin"; CLIPBIN="$T/clipbin"
mkdir -p "$CRONBIN" "$STUB" "$SSHBIN" "$CLIPBIN"
# Clipboard stubs: the real pbcopy is never reached (CLIPBIN is first on PATH).
# FAKE_PBCOPY_BROKEN=1: pbcopy "succeeds" but stores nothing.
printf '#!/bin/sh\nif [ "${FAKE_PBCOPY_BROKEN:-0}" = 1 ]; then cat >/dev/null; : > "$FAKE_CLIPBOARD"; else cat > "$FAKE_CLIPBOARD"; fi\n' > "$CLIPBIN/pbcopy"
printf '#!/bin/sh\ncat "$FAKE_CLIPBOARD" 2>/dev/null\n' > "$CLIPBIN/pbpaste"
chmod +x "$CLIPBIN"/*
cat > "$CRONBIN/crontab" <<'EOF'
#!/usr/bin/env bash
# Fake crontab: -u U -l | -u U -r | -u U <file>. FAKE_CRON_MANGLE_ONCE=1 makes
# the FIRST write alter a co-tenant line (a broken cron write), later writes
# (the restore) behave. FAKE_CRON_EDIT_ON_LIST=N: a co-tenant appends a line
# right after the Nth `-l`. FAKE_CRON_LIST_FAIL_FROM=N: the Nth and later `-l`
# fail. =append: the first write gains a stray line instead. =dropblock: the
# first write silently loses our block. =dupblock: it lands twice.
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
	    elif [ "${FAKE_CRON_MANGLE_ONCE:-0}" = dropblock ] && [ "$first" = 1 ]; then
	        awk '/^# BEGIN metal-fy-external-watch$/{i=1;next} i&&/^# END metal-fy-external-watch$/{i=0;next} !i' "$1" > "$FAKE_CRON_STORE"
	    elif [ "${FAKE_CRON_MANGLE_ONCE:-0}" = dupblock ] && [ "$first" = 1 ]; then
	        { cat "$1"; awk '/^# BEGIN metal-fy-external-watch$/{i=1} i{print} /^# END metal-fy-external-watch$/{i=0}' "$1"; } > "$FAKE_CRON_STORE"
	    else
	        cat "$1" > "$FAKE_CRON_STORE"
	    fi ;;
esac
EOF
# Self-test curl: logs its argv (a notify attempt carries "Title:") and
# answers like the RPC.
cat > "$STUB/curl" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$T/selftest-curl.log"
printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"validators":[]}}'
EOF
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
	# Literal host names / key path as ssh might echo them (not IP-shaped, so
	# only the literal masks can hide them).
	prev=""; for a in "$@"; do
		[ "$prev" = -i ] && echo "debug: identity file $a" >&2
		[[ "$a" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] && echo "debug: connecting to ${a#*@} as ${a%@*}" >&2
		prev="$a"
	done
fi
case "$last" in
	'exit 0') exit 0 ;;
	*"_ 'copy-topic' "*) printf '%s' "$STUB_TOPIC"; exit 0 ;;
	*"_ 'topic' "*) echo "topic: generated — dedicated watch topic, mode 600, owner x (value not shown)"; exit 0 ;;
	*) cat > "$SSH_STDIN_DIR/$n"
	   # A remote that (wrongly) echoed the validator host from its stdin.
	   [ "${STUB_SSH_NOISE:-0}" = 1 ] && echo "debug: remote read $(head -n 1 "$SSH_STDIN_DIR/$n")" >&2
	   exit 0 ;;
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
	: > "$WRITES"; rm -f "$WRITES.lists" "$CLIP" "$T/selftest-curl.log"
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
SEEN="$T/topics.seen"; : > "$SEEN"   # every topic that ever existed (never printed)
OUT=""; RC=0
remember_topic() { # $1 file: add its value to $SEEN (for the never-printed check)
	[ -f "$1" ] && tr -d '[:space:]' < "$1" >> "$SEEN" && printf '\n' >> "$SEEN"; return 0
}
run() { # run the installer in SKIP_SSH mode
	OUT="$(env SKIP_SSH=1 SKIP_SSH_HOME="$H" \
		SKIP_SSH_SELFTEST_PATH="$STUB:/usr/bin:/bin:$JQ_DIR" \
		WATCH_ACCOUNT="$ME" VALIDATOR_HOST="$VH" \
		FAKE_CRON_STORE="$STORE" FAKE_CRON_WRITES="$WRITES" FAKE_CLIPBOARD="$CLIP" \
		PATH="$CLIPBIN:$CRONBIN:$PATH" ${EXTRA_ENV:-} bash "$INSTALLER" "$@" 2>&1 </dev/null)"
	RC=$?
	printf '%s\n' "$OUT" >> "$ALL_OUT"
	remember_topic "$H/metal-fy-watch/etc/ntfy-topic"; remember_topic "$CLIP"
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
check "topic generated on the web host, dedicated shape fy-metal-<32 hex>" \
	'[[ "$(tr -d "[:space:]" < "$W/etc/ntfy-topic")" =~ $TOPIC_RE ]]'
check "output: topic generated, value not shown" 'printf "%s" "$OUT" | grep -q "topic: generated — dedicated watch topic, mode 600"'
check "first install: topic handed to the clipboard, exactly the installed value" \
	'[ "$(cat "$CLIP")" = "$(tr -d "[:space:]" < "$W/etc/ntfy-topic")" ]'
check "first install: says copied (not shown)" 'printf "%s" "$OUT" | grep -qx "topic copied to clipboard (not shown)"'
check "first install: tells the operator to save it and subscribe" \
	'printf "%s" "$OUT" | grep -q "password manager" && printf "%s" "$OUT" | grep -q "ntfy アプリ"'
check "no validator topic path or validator ssh involved" '! printf "%s" "$OUT" | grep -qiE "validator host -> web host|streaming"'
cp "$W/etc/ntfy-topic" "$T/topic.first"
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


# ---- re-run is a no-op --------------------------------------------------------
cp "$STORE" "$T/after1"; W1="$(nwrites)"; rm -f "$CLIP"
run
check "re-run exits 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "re-run: existing topic kept byte-for-byte (never rotated)" 'cmp -s "$T/topic.first" "$W/etc/ntfy-topic"'
check "re-run: kept topic is not copied again" '[ ! -e "$CLIP" ] && printf "%s" "$OUT" | grep -q "existing watch topic kept"'

check "re-run: already up to date" 'printf "%s" "$OUT" | grep -q "already up to date"'
check "re-run: crontab not rewritten" '[ "$(nwrites)" = "$W1" ] && cmp -s "$STORE" "$T/after1"'
check "re-run: files unchanged" 'printf "%s" "$OUT" | grep -q "bin/external-watch.sh: unchanged"'
# ---- --copy-topic -------------------------------------------------------------
rm -f "$CLIP"
run --copy-topic
check "--copy-topic: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "--copy-topic: clipboard = installed topic" '[ "$(cat "$CLIP")" = "$(tr -d "[:space:]" < "$W/etc/ntfy-topic")" ]'
check "--copy-topic: only the not-shown line, no value" 'printf "%s" "$OUT" | grep -qx "topic copied to clipboard (not shown)"'
check "--copy-topic: crontab untouched" '[ "$(nwrites)" = "$W1" ]'
run --copy-topic --dry-run
check "--copy-topic --dry-run refused: exit 2" '[ "$RC" -eq 2 ]' "rc=$RC"
EXTRA_ENV="FAKE_PBCOPY_BROKEN=1" run --copy-topic
check "--copy-topic with a clipboard that stayed empty: exit 12, no false success" \
	'[ "$RC" -eq 12 ] && ! printf "%s" "$OUT" | grep -q "topic copied to clipboard"' "rc=$RC"

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
check "dry-run: no metal-fy-watch dir created (no topic generated)" '[ ! -e "$H/metal-fy-watch" ]'
check "dry-run: says a topic would be generated, nothing copied" 'printf "%s" "$OUT" | grep -q "would generate a new dedicated watch topic" && [ ! -e "$CLIP" ]'
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

# ---- an existing topic of another shape is refused, never adopted/replaced ---
for bad_topic in "" "faketopic-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" \
	"$(printf 'fy-metal-%s' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')")"; do
	fresh_fixture; cotenant_crontab; cp "$STORE" "$T/orig"
	mkdir -p "$H/metal-fy-watch/etc"; printf '%s\n' "$bad_topic" > "$H/metal-fy-watch/etc/ntfy-topic"
	chmod 600 "$H/metal-fy-watch/etc/ntfy-topic"; cp "$H/metal-fy-watch/etc/ntfy-topic" "$T/badtopic"
	run
	check "foreign-shaped existing topic (${#bad_topic} chars): exit 5" '[ "$RC" -eq 5 ]' "rc=$RC"
	check "  file left byte-identical, crontab untouched, nothing copied" \
		'cmp -s "$T/badtopic" "$H/metal-fy-watch/etc/ntfy-topic" && [ "$(nwrites)" = 0 ] && [ ! -e "$CLIP" ] && [ ! -e "$H/metal-fy-watch/bin/external-watch.sh" ]'
done
fresh_fixture; mkdir -p "$H/metal-fy-watch/etc" "$T/fx/elsewhere"
printf '%s\n' "$STUB_TOPIC" > "$T/fx/elsewhere/t"; ln -s "$T/fx/elsewhere/t" "$H/metal-fy-watch/etc/ntfy-topic"
run
check "topic file is a symlink: exit 5, not followed" '[ "$RC" -eq 5 ] && [ "$(cat "$T/fx/elsewhere/t")" = "$STUB_TOPIC" ] && [ ! -e "$CLIP" ]' "rc=$RC"
fresh_fixture
run --copy-topic
check "--copy-topic with no topic installed: exit 12, nothing in the clipboard" '[ "$RC" -eq 12 ] && [ ! -s "$CLIP" ]' "rc=$RC"

# ---- pbcopy missing: refuse before touching any host, never print --------------
fresh_fixture; cotenant_crontab
NOPB="$T/nopb"; rm -rf "$NOPB"; mkdir -p "$NOPB"
for t in bash env dirname grep sed cat tr awk od base64 mktemp rm head; do
	src="$(command -v "$t")" && ln -s "$src" "$NOPB/$t"
done
for args in "" "--copy-topic"; do
	OUT="$(env -i HOME="$HOME" PATH="$NOPB" SKIP_SSH=1 SKIP_SSH_HOME="$H" WATCH_ACCOUNT="$ME" VALIDATOR_HOST="$VH" \
		"$(command -v bash)" "$INSTALLER" $args 2>&1 </dev/null)"; RC=$?
	printf '%s\n' "$OUT" >> "$ALL_OUT"
	check "no pbcopy (${args:-install}): exit 2, refused with a reason" '[ "$RC" -eq 2 ] && printf "%s" "$OUT" | grep -q "pbcopy/pbpaste not found"' "rc=$RC"
	check "  nothing created on the (fake) web host" '[ ! -e "$H/metal-fy-watch" ]'
done

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

# ---- uninstall keeps only the newest 3 of its own crontab backups (F6) ----------
fresh_fixture; cotenant_crontab
for ts in 20250101-000001 20250101-000002 20250101-000003 20250101-000004; do printf 'old\n' > "$H/metal-fy-watch-crontab.bak-$ts"; done
printf 'keep\n' > "$H/metal-fy-watch-crontab.bak-0notes"; printf 'keep\n' > "$H/other.bak-20200101-000000"
printf 'precious\n' > "$T/outside-f6"; ln -s "$T/outside-f6" "$H/metal-fy-watch-crontab.bak-20000101-000000"
run; run --uninstall
check "uninstall prune: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "uninstall prune: the 2 oldest of 5 own backups removed" \
	'[ ! -e "$H/metal-fy-watch-crontab.bak-20250101-000001" ] && [ ! -e "$H/metal-fy-watch-crontab.bak-20250101-000002" ]'
check "uninstall prune: newest 3 kept (2 old + this uninstall's)" \
	'[ -f "$H/metal-fy-watch-crontab.bak-20250101-000003" ] && [ -f "$H/metal-fy-watch-crontab.bak-20250101-000004" ] && new_bak="$(ls "$H" | grep -E "^metal-fy-watch-crontab\.bak-[0-9]{8}-[0-9]{6}\$" | grep -vE "^metal-fy-watch-crontab\.bak-(20250101-00000[1-4]|20000101-000000)\$")" && [ "$(nbegin "$H/$new_bak")" = 1 ]'
check "uninstall prune: other names in the home untouched" \
	'[ "$(cat "$H/metal-fy-watch-crontab.bak-0notes")" = keep ] && [ "$(cat "$H/other.bak-20200101-000000")" = keep ]'
check "uninstall prune: a symlink of that name (oldest) is neither removed nor followed" \
	'[ -L "$H/metal-fy-watch-crontab.bak-20000101-000000" ] && [ "$(cat "$T/outside-f6")" = precious ]'

# ---- local preconditions --------------------------------------------------------
fresh_fixture
EXTRA_ENV="WATCH_ACCOUNT=Bad;name" run
check "malformed WATCH_ACCOUNT: exit 2" '[ "$RC" -eq 2 ]' "rc=$RC"
EXTRA_ENV="VALIDATOR_HOST=bad;host" run
check "malformed VALIDATOR_HOST: exit 2" '[ "$RC" -eq 2 ]' "rc=$RC"

# ---- the self-test never runs LIVE (B3 / I8) -----------------------------------
# A check that is one failure away from alerting: stale validator.json and a
# seeded fresh fails=1. A LIVE self-test would push; a DRY one only says so.
fresh_fixture; cotenant_crontab
printf '{"observedAt":"2020-01-01T00:00:00Z"}\n' > "$T/fx/webroot/api/validator.json"
mkdir -p "$H/metal-fy-watch/state"
echo '{"fresh":{"status":"ok","fails":1,"first_fail_at":1},"p2p":{"status":"ok","fails":0,"first_fail_at":null},"chain":{"status":"ok","fails":0,"first_fail_at":null}}' \
	> "$H/metal-fy-watch/state/state.json"
run
check "stale feed + fails=1: install still exits 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "  self-test reached the alert path in DRY form" 'printf "%s" "$OUT" | grep -q "watch: DRY: would notify high"'
check "  no notify attempt was made (no curl call with a Title header)" \
	'[ -s "$T/selftest-curl.log" ] && ! grep -q "Title:" "$T/selftest-curl.log"'
check "  status not moved to alerting" '! grep -q alerting "$H/metal-fy-watch/state/state.json"'
check "  a FAILing self-test check is flagged to the operator" 'printf "%s" "$OUT" | grep -q "WARNING: a check FAILed in the self-test"'

# ---- self-test output: control characters never reach the terminal ----------
fresh_fixture
printf '#!/usr/bin/env bash\nprintf "evil \\033]0;x\\007 \\033[2J end\\n" >&2\nexit 0\n' > "$T/esc-watch.sh"
EXTRA_ENV="SKIP_SSH_WATCH_SRC=$T/esc-watch.sh" run
check "escape sequences from the account are stripped" \
	'[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "watch: evil" && ! printf "%s" "$OUT" | LC_ALL=C grep -q "$(printf "\033")"' "rc=$RC"

# ---- post-write verification: block must be present exactly once (I26) ------
for mode in dropblock dupblock; do
	fresh_fixture; cotenant_crontab; cp "$STORE" "$T/orig"
	EXTRA_ENV="FAKE_CRON_MANGLE_ONCE=$mode" run
	check "write that ${mode%block}s the block: exit 7" '[ "$RC" -eq 7 ]' "rc=$RC"
	check "  original crontab restored byte-for-byte" 'cmp -s "$STORE" "$T/orig"'
	check "  reason given" 'printf "%s" "$OUT" | grep -q "block not present exactly once as intended"'
done

# ---- bin/ symlink refused (I13) ------------------------------------------------
fresh_fixture; mkdir -p "$T/fx/elsewhere" "$H/metal-fy-watch"
ln -s "$T/fx/elsewhere" "$H/metal-fy-watch/bin"
run
check "bin/ is a symlink: exit 5, nothing written through it" \
	'[ "$RC" -eq 5 ] && [ -z "$(ls -A "$T/fx/elsewhere")" ] && [ "$(nwrites)" = 0 ]' "rc=$RC"

# ---- malformed markers (I15) ---------------------------------------------------
for layout in begin-only end-only end-first; do
	fresh_fixture
	case "$layout" in
		begin-only) printf '1 1 * * * /srv/cotenant-a/x\n%s\n' "$BEGIN_MARK" > "$STORE" ;;
		end-only)   printf '1 1 * * * /srv/cotenant-a/x\n%s\n' "$END_MARK" > "$STORE" ;;
		end-first)  printf '%s\n1 1 * * * /srv/cotenant-a/x\n%s\n' "$END_MARK" "$BEGIN_MARK" > "$STORE" ;;
	esac
	cp "$STORE" "$T/orig"
	run
	check "markers $layout: exit 9, crontab untouched" '[ "$RC" -eq 9 ] && [ "$(nwrites)" = 0 ] && cmp -s "$STORE" "$T/orig"' "rc=$RC"
done

# ---- overwritten files are backed up first (I17) --------------------------------
fresh_fixture; cotenant_crontab
run
cp "$H/metal-fy-watch/bin/external-watch.sh" "$T/watch.old"
{ cat "$WATCH_SRC"; echo "# changed for the backup test"; } > "$T/watch.new"
EXTRA_ENV="SKIP_SSH_WATCH_SRC=$T/watch.new" run
BAK="$(find "$H/metal-fy-watch/backup" -name "external-watch.sh.bak-*" 2>/dev/null | head -1)"
check "changed bin file: re-install exits 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "  old bytes backed up, mode 600" '[ -n "$BAK" ] && cmp -s "$BAK" "$T/watch.old" && [ "$(meta "$BAK")" = 600 ]'
check "  new bytes installed" 'cmp -s "$T/watch.new" "$H/metal-fy-watch/bin/external-watch.sh"'

# ---- changed watch.env: key names only, never values (I31) ----------------------
fresh_fixture; cotenant_crontab
HN_OLD="val-old-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n').example.test"
HN_NEW="val-new-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n').example.test"
EXTRA_ENV="VALIDATOR_HOST=$HN_OLD" run
EXTRA_ENV="VALIDATOR_HOST=$HN_NEW" run
check "changed VALIDATOR_HOST: exit 0, only the key name shown" \
	'[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "etc/watch.env: update (changed keys: VALIDATOR_HOST )"' "rc=$RC"
check "  neither the old nor the new value printed" '! printf "%s" "$OUT" | grep -qF "$HN_OLD" && ! printf "%s" "$OUT" | grep -qF "$HN_NEW"'
check "  new value written" 'grep -qxF "VALIDATOR_HOST=$HN_NEW" "$H/metal-fy-watch/etc/watch.env"'

# ---- WATCH_PUBLIC_STATUS: public status file for the phone page ------------------
fresh_fixture; cotenant_crontab
PUB="$T/fx/webroot/api/watch-status.json"
WENV="$H/metal-fy-watch/etc/watch.env"
run
check "status: first install without the env: key absent (disabled), says so" \
	'[ "$RC" -eq 0 ] && ! grep -q "^WATCH_PUBLIC_STATUS=" "$WENV" && printf "%s" "$OUT" | grep -q "public status: disabled"' "rc=$RC"
check "  and the self-test published nothing" '[ ! -e "$PUB" ]'
EXTRA_ENV="WATCH_PUBLIC_STATUS=auto" run --dry-run
check "status: auto --dry-run shows enabled + the changed key name, writes nothing" \
	'[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "public status: enabled — watch-status.json in the api dir of validator.json (auto)" && printf "%s" "$OUT" | grep -q "etc/watch.env: update (changed keys: WATCH_PUBLIC_STATUS )" && ! grep -q "^WATCH_PUBLIC_STATUS=" "$WENV" && [ ! -e "$PUB" ]' "rc=$RC"
EXTRA_ENV="WATCH_PUBLIC_STATUS=auto" run
check "status: auto writes the api dir of validator.json" '[ "$RC" -eq 0 ] && grep -qxF "WATCH_PUBLIC_STATUS=$PUB" "$WENV"' "rc=$RC"
check "  the self-test run published it (schema 2, mode 644)" '[ "$(jq -r .schema "$PUB" 2>/dev/null)" = 2 ] && [ "$(meta "$PUB")" = 644 ]'
check "  the path is not printed" '! printf "%s" "$OUT" | grep -qF "$PUB"'
run
check "status: re-install without the env keeps it" '[ "$RC" -eq 0 ] && grep -qxF "WATCH_PUBLIC_STATUS=$PUB" "$WENV" && printf "%s" "$OUT" | grep -q "kept from the installed watch.env"' "rc=$RC"
mkdir -p "$T/fx/other"
EXTRA_ENV="WATCH_PUBLIC_STATUS=$T/fx/other/s.json" run
check "status: explicit absolute path is written" '[ "$RC" -eq 0 ] && grep -qxF "WATCH_PUBLIC_STATUS=$T/fx/other/s.json" "$WENV"' "rc=$RC"
EXTRA_ENV="WATCH_PUBLIC_STATUS=off" run
check "status: off removes the key" '[ "$RC" -eq 0 ] && ! grep -q "^WATCH_PUBLIC_STATUS=" "$WENV"' "rc=$RC"
cp "$WENV" "$T/wenv.before"
for badv in relative.json /x/../y.json /x/y.txt '/x/a;b.json'; do
	EXTRA_ENV="WATCH_PUBLIC_STATUS=$badv" run
	check "status: malformed value '$badv' refused locally (exit 2), watch.env untouched" '[ "$RC" -eq 2 ] && cmp -s "$WENV" "$T/wenv.before"' "rc=$RC"
done
EXTRA_ENV="WATCH_PUBLIC_STATUS=$T/fx/nodir/watch-status.json" run
check "status: directory missing on the host: exit 6, watch.env untouched" '[ "$RC" -eq 6 ] && cmp -s "$WENV" "$T/wenv.before"' "rc=$RC"

# ---- layout verification fails loudly (I27) -------------------------------------
# chmod leaves installed files world-readable (644) as a broken filesystem
# might; the verifier must refuse with exit 11 before arming the crontab.
fresh_fixture; cotenant_crontab; cp "$STORE" "$T/orig"
BADCHMOD="$T/badchmod"; mkdir -p "$BADCHMOD"
REAL_CHMOD="$(command -v chmod)"
cat > "$BADCHMOD/chmod" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in */.inst.*) exec "$REAL_CHMOD" 644 "\$a" ;; esac; done
exec "$REAL_CHMOD" "\$@"
EOF
chmod +x "$BADCHMOD/chmod"
OUT="$(env SKIP_SSH=1 SKIP_SSH_HOME="$H" SKIP_SSH_SELFTEST_PATH="$STUB:/usr/bin:/bin:$JQ_DIR" \
	WATCH_ACCOUNT="$ME" VALIDATOR_HOST="$VH" FAKE_CRON_STORE="$STORE" FAKE_CRON_WRITES="$WRITES" FAKE_CLIPBOARD="$CLIP" \
	PATH="$BADCHMOD:$CLIPBIN:$CRONBIN:$PATH" bash "$INSTALLER" 2>&1 </dev/null)"; RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"; remember_topic "$H/metal-fy-watch/etc/ntfy-topic"
check "files left 644: exit 11" '[ "$RC" -eq 11 ]' "rc=$RC"
check "  names the bad entries, crontab not armed" 'printf "%s" "$OUT" | grep -q "BAD etc/watch.env" && [ "$(nwrites)" = 0 ] && cmp -s "$STORE" "$T/orig"'
check "  the topic generated before the failure was still handed over" '[ -s "$CLIP" ]'

# ---- the remote half itself never prints the host (the Mac-side mask is only
# a second layer, so it is bypassed here by running the printed remote raw) ----
fresh_fixture; cotenant_crontab
FAKE_CRON_STORE="$STORE" FAKE_CRON_WRITES="$WRITES" PATH="$CRONBIN:$PATH" \
	bash "$REMOTE" topic 0 "$ME" "" "$H" "" > "$T/raw.out" 2>&1 </dev/null
remember_topic "$H/metal-fy-watch/etc/ntfy-topic"
{ printf '%s\n' "$VH"; base64 < "$WATCH_SRC" | tr -d '\n'; echo; base64 < "$NOTIFY_SRC" | tr -d '\n'; echo; } \
	| FAKE_CRON_STORE="$STORE" FAKE_CRON_WRITES="$WRITES" PATH="$CRONBIN:$PATH" \
	bash "$REMOTE" install 0 "$ME" "" "$H" "$STUB:/usr/bin:/bin:$JQ_DIR" >> "$T/raw.out" 2>&1
RAW_RC=$?
check "raw remote install: exit 0" '[ "$RAW_RC" -eq 0 ]' "rc=$RAW_RC"
check "raw remote output (unmasked) has no validator host and no topic" \
	'! grep -qF "$VH" "$T/raw.out" && ! grep -qF "$(tr -d "[:space:]" < "$H/metal-fy-watch/etc/ntfy-topic")" "$T/raw.out"'
check "raw remote output names no on-host absolute path" '! grep -qF "$T/fx" "$T/raw.out"'

# ==============================================================================
# real mode against a recording ssh stub: argv / stdin discipline
# ==============================================================================
printf 'dummy\n' > "$T/key"
SSH_LOG="$T/ssh.log"; SSH_STDIN_DIR="$T/sshin"; mkdir -p "$SSH_STDIN_DIR"
WH=198.51.100.23
real() {
	: > "$SSH_LOG"; rm -f "$SSH_STDIN_DIR"/* "$CLIP"
	OUT="$(env PATH="$CLIPBIN:$SSHBIN:$PATH" SSH_LOG="$SSH_LOG" SSH_STDIN_DIR="$SSH_STDIN_DIR" STUB_TOPIC="$STUB_TOPIC" \
		FAKE_CLIPBOARD="$CLIP" WEB_HOST="$WH" WEB_HOST_KEY="$T/key" VALIDATOR_HOST="$VH" ${EXTRA_ENV:-} \
		bash "$INSTALLER" "$@" 2>&1 </dev/null)"
	RC=$?
	printf '%s\n' "$OUT" >> "$ALL_OUT"
}
real
check "real mode (stub ssh): exit 0" '[ "$RC" -eq 0 ]' "rc=$RC: $OUT"
check "real mode: every ssh call goes to the web host, none to the validator host" \
	'[ "$(grep -c . "$SSH_LOG")" -ge 3 ] && [ "$(grep -c -- "root@$WH " "$SSH_LOG")" = "$(grep -c . "$SSH_LOG")" ] && ! grep -qF -- "@$VH" "$SSH_LOG"'
check "real mode: topic never in any ssh argv" '! grep -qF "$STUB_TOPIC" "$SSH_LOG"'
check "real mode: validator host never in any ssh argv" '! grep -qF "$VH" "$SSH_LOG"'
check "real mode: every ssh call is BatchMode with the web host key" '! grep -v -- "-o BatchMode=yes" "$SSH_LOG" | grep -q . && ! grep -v -- "-i $T/key" "$SSH_LOG" | grep -q .'
check "real mode: new topic went from the copy-topic session stdout into the clipboard" '[ "$(cat "$CLIP")" = "$STUB_TOPIC" ]'
check "real mode: validator host travelled on stdin, not argv" 'grep -lxF "$VH" "$SSH_STDIN_DIR"/* >/dev/null 2>&1'
EXTRA_ENV="VALIDATOR_SSH_USER=opuser VALIDATOR_SSH_KEY=$T/key VALIDATOR_TOPIC_FILE=/fake/topic" real
check "old validator ssh variables: ignored with a note, still no validator ssh" \
	'[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "no longer used" && ! grep -qE -- "opuser@|@$VH" "$SSH_LOG"' "rc=$RC"
real --copy-topic
check "real --copy-topic: one ssh session to the web host, clipboard filled" \
	'[ "$RC" -eq 0 ] && [ "$(grep -c "copy-topic" "$SSH_LOG")" = 1 ] && [ "$(cat "$CLIP")" = "$STUB_TOPIC" ]' "rc=$RC"
check "real mode: every ssh call carries the hardening options" \
	'! grep -vE -- "-o LogLevel=ERROR.*-o IdentitiesOnly=yes -o ForwardAgent=no -o ClearAllForwardings=yes" "$SSH_LOG" | grep -q .'
EXTRA_ENV="STUB_SSH_NOISE=1" real
check "noisy ssh: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "noisy ssh: resolved IP, user@host and IPv6 never reach the output" \
	'! printf "%s" "$OUT" | grep -qE "198\.51\.100\.7|203\.0\.113\.57|198\.51\.100\.23|root@|2001:db8" && printf "%s" "$OUT" | grep -qF "[<ip>]"' "$OUT"
# Name-style hosts and the key path: only the literal masks can hide them.
HN_WEB="web-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n').example.test"
HN_VAL="val-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n').example.test"
: > "$SSH_LOG"; rm -f "$SSH_STDIN_DIR"/* "$CLIP"
OUT="$(env PATH="$CLIPBIN:$SSHBIN:$PATH" SSH_LOG="$SSH_LOG" SSH_STDIN_DIR="$SSH_STDIN_DIR" STUB_TOPIC="$STUB_TOPIC" \
	FAKE_CLIPBOARD="$CLIP" STUB_SSH_NOISE=1 WEB_HOST="$HN_WEB" WEB_HOST_KEY="$T/key" VALIDATOR_HOST="$HN_VAL" \
	bash "$INSTALLER" 2>&1 </dev/null)"; RC=$?
printf '%s\n' "$OUT" >> "$ALL_OUT"
check "noisy ssh, name-style hosts: exit 0" '[ "$RC" -eq 0 ]' "rc=$RC"
check "  web host name masked" '! printf "%s" "$OUT" | grep -qF "$HN_WEB" && printf "%s" "$OUT" | grep -qF "connecting to <web host>"'
check "  validator host name masked" '! printf "%s" "$OUT" | grep -qF "$HN_VAL" && printf "%s" "$OUT" | grep -qF "remote read <validator host>"'
check "  key path masked" '! printf "%s" "$OUT" | grep -qF "$T/key" && printf "%s" "$OUT" | grep -qF "identity file <ssh key>"' "leak=$(printf "%s" "$OUT" | grep -cF "$T/key") ids=$(printf "%s" "$OUT" | grep -c "identity file")"
EXTRA_ENV="STUB_SSH_FAIL=1" real
check "real mode: pre-check failure exits 3" '[ "$RC" -eq 3 ]' "rc=$RC"
check "real mode: pre-check prints a generic error, never ssh's own text" \
	'printf "%s" "$OUT" | grep -qF "<web host> (ssh rc=255)" && ! printf "%s" "$OUT" | grep -qE "Connection refused|198\.51\.100\.(7|23)|opuser"'
EXTRA_ENV="WEB_HOST_KEY=" real
check "real mode: WEB_HOST_KEY required, no ssh attempted" '[ "$RC" -eq 2 ] && [ ! -s "$SSH_LOG" ]' "rc=$RC"
real --uninstall --dry-run
check "real mode: uninstall needs no validator ssh" '[ "$RC" -eq 0 ] && ! grep -qF -- "@$VH" "$SSH_LOG"' "rc=$RC"
check "static: the installer has no validator-side ssh at all" \
	'! grep -nE "VALIDATOR_SSH_KEY\"|VALIDATOR_SSH_USER\}@|validator_run|@\\$\\{?VALIDATOR_HOST" "$INSTALLER"'

# ==============================================================================
# secrets never printed, across every run above
# ==============================================================================
check "no run printed the validator host" '! grep -qF "$VH" "$ALL_OUT"'
check "at least one generated topic was tracked" '[ "$(grep -c . "$SEEN")" -ge 3 ]'
check "no run printed any topic (stub or generated)" '! grep -qF "$STUB_TOPIC" "$ALL_OUT" && ! grep -qF -f <(grep . "$SEEN") "$ALL_OUT"'
check "no run printed the web host or key path" '! grep -qF 198.51.100.23 "$ALL_OUT" && ! grep -qF "$T/key" "$ALL_OUT"'

echo
echo "test-install-web-host-external-watch.sh summary: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
