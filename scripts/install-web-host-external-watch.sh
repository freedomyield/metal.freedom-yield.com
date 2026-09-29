#!/usr/bin/env bash
# install-web-host-external-watch.sh — place the off-host validator watchdog
# ("外部見張り", scripts/external-watch.sh) on the web host and arm it in the
# site account's crontab.
#
# CHAIN: none. PRIME_DIRECTIVE: safe (no broadcast-capable command).
# BROADCASTS NOTHING.
#
# Motivation (2026-09-24 incident): every monitor living on the validator
# host is blind to that host losing connectivity — a ~100 h outage delivered
# no alert. The watchdog therefore runs on a different machine, the web host,
# as the site account, every 5 minutes. This installer is the only supported
# way to put it there.
#
# What it changes on the web host (and nothing else):
#   ~WATCH_ACCOUNT/metal-fy-watch/            dir 700, owner WATCH_ACCOUNT
#     bin/external-watch.sh  bin/notify.sh    700
#     etc/watch.env  etc/ntfy-topic           600
#     state/ log/ backup/                     700
#   WATCH_ACCOUNT's crontab, strictly between the lines
#     # BEGIN metal-fy-external-watch
#     # END metal-fy-external-watch
#   Every crontab line outside those markers is verified identical before
#   and after the write (co-tenant projects share this crontab); on any
#   mismatch the backed-up crontab is restored and the installer fails.
#   Does not touch other projects, /etc, system cron, users, services,
#   firewall or web server configuration. No sudo, no useradd.
#
# Secrets handling:
#   - The ntfy topic is streamed validator host -> web host over two ssh
#     connections joined by a pipe. It never lands on the Mac's disk, never
#     appears in any argv, and is never printed. The web host side verifies
#     it is non-empty and well-formed and writes it mode 600.
#   - The validator host address is delivered on the remote session's stdin,
#     not in argv, and is never printed: output shows `<validator host>`.
#     Web host address and key paths are masked the same way.
#   - Every file under metal-fy-watch/ is written AS the site account (the
#     root session only reads account data through that account), so a
#     planted symlink there can never make root write elsewhere.
#
# Steps (install):
#   1. ssh pre-check of both hosts (BatchMode; no password prompts).
#   2. topic: validator host `cat` | web host receiver  (skipped by --dry-run)
#   3. detect VALIDATOR_JSON from the push wrapper's `__fy_root='<dir>'`
#      line (~WATCH_ACCOUNT/bin/receive-metal-push), or FY_WEB_API_DIR.
#   4. install bin/ + etc/watch.env (existing files backed up to backup/).
#   5. self-test: run the watch once WITHOUT WATCH_LIVE as the account and
#      print its log line. A non-zero exit stops here, BEFORE the crontab is
#      armed, so a watch that cannot even read its config never goes to cron.
#   6. crontab block (backup to backup/crontab.bak-<ts>, write, verify,
#      restore on failure). The armed line is:
#      */5 * * * * WATCH_LIVE=1 /bin/bash $HOME/metal-fy-watch/bin/external-watch.sh >>$HOME/metal-fy-watch/log/cron.err 2>&1
#
# --uninstall: remove the crontab block (same verification, crontab backed up
# to ~WATCH_ACCOUNT/metal-fy-watch-crontab.bak-<ts> first), then remove
# ~WATCH_ACCOUNT/metal-fy-watch/. Needs only the WEB_HOST_* variables.
#
# Usage (operator, from the Mac):
#   WEB_HOST=<addr> WEB_HOST_KEY=<key> VALIDATOR_HOST=<addr> \
#   VALIDATOR_SSH_USER=<user> VALIDATOR_SSH_KEY=<key> \
#   VALIDATOR_TOPIC_FILE=<abs path on the validator host> \
#     bash scripts/install-web-host-external-watch.sh [--dry-run]
#   WEB_HOST=<addr> WEB_HOST_KEY=<key> \
#     bash scripts/install-web-host-external-watch.sh --uninstall [--dry-run]
#
# Options:
#   --dry-run        Connect + inspect + print what would change. Writes
#                    nothing on either host; the topic is not read.
#   --print-remote   Print the remote script and exit. No SSH, no env needed,
#                    no host values embedded (they travel on stdin at run time).
#   --uninstall      Remove the crontab block and ~WATCH_ACCOUNT/metal-fy-watch.
#
# Env (none is ever echoed):
#   WEB_HOST             required
#   WEB_HOST_USER        default root (crontab -u needs it)
#   WEB_HOST_KEY         required, no default
#   WATCH_ACCOUNT        default deploy
#   VALIDATOR_HOST       required for install (written to watch.env only)
#   VALIDATOR_SSH_USER   required for install
#   VALIDATOR_SSH_KEY    required for install
#   VALIDATOR_TOPIC_FILE required for install; no default (absolute path)
#   FY_WEB_API_DIR       web host api/ dir holding validator.json; skips
#                        auto-detection from the push wrapper
#
# Test mode: SKIP_SSH=1 runs both remote halves locally with `bash -c` (no
# host contacted). Only then are these honoured: SKIP_SSH_HOME (fake account
# home), SKIP_SSH_SELFTEST_PATH (PATH for the self-test, e.g. with stubs),
# SKIP_SSH_WATCH_SRC (substitute watch script). VALIDATOR_TOPIC_FILE is read
# as a local file. Tests put a fake `crontab` on PATH.
#
# Exit codes:
#   0  installed / already up to date / uninstalled / dry-run / print done
#   2  local precondition failed (env, key unreadable, bad arg, bad source)
#   3  ssh pre-check failed (either host)
#   4  account, its home, or runuser not usable on the web host
#   5  topic transfer failed, or topic empty/malformed (nothing written)
#   6  VALIDATOR_JSON dir undeterminable (pass FY_WEB_API_DIR) or invalid
#   7  crontab verification failed — original crontab RESTORED
#   8  watch self-test failed (crontab not armed)
#   9  crontab unreadable or its markers malformed — nothing written
#   10 CRITICAL: crontab restore could not be verified (backup path printed)
#   11 installed layout failed mode/owner verification

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODE=install
DRY_RUN=0
PRINT_REMOTE=0
for arg in "$@"; do
	case "$arg" in
		--dry-run)      DRY_RUN=1 ;;
		--print-remote) PRINT_REMOTE=1 ;;
		--uninstall)    MODE=uninstall ;;
		-h|--help)      sed -n '2,105p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)              echo "ERROR (2): unknown arg: $arg" >&2; exit 2 ;;
	esac
done

# The remote half. Runs as WEB_HOST_USER (root) on the web host via
# `bash -c <script> _ <args>`; data (validator host, file contents, or the
# topic) arrives on stdin, never in argv. Kept in one place so --print-remote
# shows exactly what runs.
read -r -d '' REMOTE_SCRIPT <<'REMOTE_EOF' || true
# shellcheck disable=SC2016  # child-bash "$1".. and the cron line's literal $HOME are intended
set -euo pipefail
cd /

MODE="${1:?internal: mode arg missing}"
DRY_RUN="${2:-0}"
ACCT="${3:?internal: account arg missing}"
API_DIR_OVERRIDE="${4:-}"
# $5/$6 exist only for the SKIP_SSH=1 test mode (fake home, stubbed PATH for
# the self-test). POSITIONAL rather than environment, so nothing in the remote
# environment can redirect them; a real run always passes them empty.
HOME_OVERRIDE="${5:-}"
SELFTEST_PATH="${6:-}"
[ -n "$SELFTEST_PATH" ] || SELFTEST_PATH=/usr/bin:/bin

BEGIN_MARK='# BEGIN metal-fy-external-watch'
END_MARK='# END metal-fy-external-watch'
CRON_LINE='*/5 * * * * WATCH_LIVE=1 /bin/bash $HOME/metal-fy-watch/bin/external-watch.sh >>$HOME/metal-fy-watch/log/cron.err 2>&1'
TS="$(date +%Y%m%d-%H%M%S)"
SAFE_PATH_RE='^/[A-Za-z0-9._/-]+$'

# ---- account + home -------------------------------------------------------
if ! printf '%s' "$ACCT" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'; then
	echo "ERROR (4): account name malformed" >&2; exit 4
fi
ACCT_UID="$(id -u "$ACCT" 2>/dev/null || true)"
if [ -z "$ACCT_UID" ]; then echo "ERROR (4): account $ACCT not found" >&2; exit 4; fi
if [ "$ACCT_UID" = 0 ]; then echo "ERROR (4): refusing to run the watch as root" >&2; exit 4; fi
if [ -n "$HOME_OVERRIDE" ]; then
	ACCT_HOME="$HOME_OVERRIDE"
else
	command -v getent >/dev/null 2>&1 || { echo "ERROR (4): getent missing" >&2; exit 4; }
	ACCT_HOME="$(getent passwd "$ACCT" | cut -d: -f6)"
fi
ACCT_HOME="${ACCT_HOME%/}"
if ! printf '%s' "$ACCT_HOME" | grep -qE "$SAFE_PATH_RE" || [ ! -d "$ACCT_HOME" ]; then
	echo "ERROR (4): home of $ACCT not found or unusable" >&2; exit 4
fi
W="$ACCT_HOME/metal-fy-watch"
SHOW="~$ACCT/metal-fy-watch"

if [ "$(id -u)" != "$ACCT_UID" ] && ! command -v runuser >/dev/null 2>&1; then
	echo "ERROR (4): runuser missing — cannot act as $ACCT" >&2; exit 4
fi
# Everything under the account's home is touched AS the account, so a symlink
# planted there can never turn a root write into a write elsewhere.
as_account() {
	if [ "$(id -u)" = "$ACCT_UID" ]; then "$@"; else runuser -u "$ACCT" -- "$@"; fi
}
file_meta() { # path -> "<octal mode> <owner uid>" (GNU stat, BSD fallback)
	stat -c '%a %u' "$1" 2>/dev/null || stat -f '%Lp %u' "$1" 2>/dev/null
}
home_owner="$(file_meta "$ACCT_HOME" | cut -d' ' -f2)"
if [ "$home_owner" != "$ACCT_UID" ]; then
	echo "ERROR (4): home of $ACCT is not owned by $ACCT — refusing" >&2; exit 4
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ensure_layout() {
	as_account mkdir -p "$W/bin" "$W/etc" "$W/state" "$W/log" "$W/backup"
	as_account chmod 700 "$W" "$W/bin" "$W/etc" "$W/state" "$W/log" "$W/backup"
}

# ---- mode: topic (stdin = the topic; never echoed) ------------------------
if [ "$MODE" = topic ]; then
	ensure_layout
	T="$(as_account mktemp "$W/etc/.ntfy-topic.XXXXXX")"
	as_account bash -c 'umask 077; head -c 4096 > "$1"' _ "$T"
	if ! as_account bash -c 'v="$(tr -d "[:space:]" < "$1")"; [[ "$v" =~ ^[A-Za-z0-9_-]{1,64}$ ]]' _ "$T"; then
		as_account rm -f "$T"
		echo "ERROR (5): streamed topic is empty or malformed — nothing written" >&2
		exit 5
	fi
	STATE=new
	if as_account test -e "$W/etc/ntfy-topic"; then
		if as_account cmp -s "$T" "$W/etc/ntfy-topic"; then STATE=unchanged; else STATE=updated; fi
	fi
	as_account chmod 600 "$T"
	as_account mv -f "$T" "$W/etc/ntfy-topic"
	if ! as_account test -s "$W/etc/ntfy-topic" || [ "$(file_meta "$W/etc/ntfy-topic")" != "600 $ACCT_UID" ]; then
		echo "ERROR (5): topic file verification failed (non-empty / 600 / owner)" >&2; exit 5
	fi
	echo "topic: $STATE — non-empty, mode 600, owner $ACCT (value not shown)"
	exit 0
fi

# ---- crontab helpers -------------------------------------------------------
HAD_CRONTAB=0
ORIG_HAD_CRONTAB=0  # captured right after reading "before"; read_crontab overwrites HAD_CRONTAB
read_crontab() { # $1 = out file; sets HAD_CRONTAB
	if crontab -u "$ACCT" -l > "$1" 2> "$TMP/cl.err"; then
		HAD_CRONTAB=1
	elif grep -qi 'no crontab' "$TMP/cl.err"; then
		: > "$1"; HAD_CRONTAB=0
	else
		echo "ERROR (9): cannot read the crontab of $ACCT — nothing written" >&2; exit 9
	fi
}
outside_block() { LC_ALL=C awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
	'inb==0 && $0==b {inb=1; next} inb==1 && $0==e {inb=0; next} inb==0 {print}' "$1"; }
the_block() { LC_ALL=C awk -v b="$BEGIN_MARK" -v e="$END_MARK" \
	'inb==0 && $0==b {inb=1} inb==1 {print} inb==1 && $0==e {inb=0}' "$1"; }
count_line() { LC_ALL=C awk -v m="$2" '$0==m {n++} END {print n+0}' "$1"; }
line_no() { LC_ALL=C awk -v m="$2" '$0==m {print NR; exit}' "$1"; }
check_markers() { # $1 file -> sets NB; exits 9 on malformed
	NB="$(count_line "$1" "$BEGIN_MARK")"
	local ne; ne="$(count_line "$1" "$END_MARK")"
	if [ "$NB" -gt 1 ] || [ "$ne" -gt 1 ] || [ "$NB" != "$ne" ]; then
		echo "ERROR (9): crontab markers malformed (BEGIN=$NB END=$ne) — nothing written" >&2; exit 9
	fi
	if [ "$NB" = 1 ] && [ "$(line_no "$1" "$BEGIN_MARK")" -gt "$(line_no "$1" "$END_MARK")" ]; then
		echo "ERROR (9): crontab END marker precedes BEGIN — nothing written" >&2; exit 9
	fi
}
printf '%s\n' "$BEGIN_MARK" "$CRON_LINE" "$END_MARK" > "$TMP/block"

# Only changed lines, never co-tenant context lines.
show_crontab_diff() { diff -U0 "$1" "$2" | grep -vE '^(---|\+\+\+) ' || true; }

restore_crontab() {
	echo "--- restoring the original crontab ---" >&2
	if [ "$ORIG_HAD_CRONTAB" = 1 ]; then
		crontab -u "$ACCT" "$TMP/before" || true
	else
		crontab -u "$ACCT" -r 2>/dev/null || true
	fi
	read_crontab "$TMP/restored"
	if cmp -s "$TMP/before" "$TMP/restored"; then
		echo "restored: crontab of $ACCT is byte-identical to the backup" >&2
	else
		echo "CRITICAL (10): restore could not be verified. Backup: $CRONTAB_BAK_SHOW" >&2
		exit 10
	fi
}

# write_and_verify <new file> <expect: present|absent>
write_and_verify() {
	crontab -u "$ACCT" "$1" || true
	read_crontab "$TMP/after"
	local why=""
	outside_block "$TMP/before" > "$TMP/out.before"
	outside_block "$TMP/after" > "$TMP/out.after" || true
	if ! cmp -s "$TMP/out.before" "$TMP/out.after"; then
		why="lines outside the markers changed"
	elif [ "$2" = present ]; then
		the_block "$TMP/after" > "$TMP/block.after"
		if [ "$(count_line "$TMP/after" "$BEGIN_MARK")" != 1 ] || ! cmp -s "$TMP/block" "$TMP/block.after"; then
			why="block not present exactly once as intended"
		fi
	elif [ "$(count_line "$TMP/after" "$BEGIN_MARK")" != 0 ] || [ "$(count_line "$TMP/after" "$END_MARK")" != 0 ]; then
		why="block still present"
	fi
	if [ -n "$why" ]; then
		echo "ERROR (7): crontab verification failed: $why" >&2
		restore_crontab
		exit 7
	fi
	echo "verified: lines outside the markers identical before/after"
}

# ---- mode: uninstall -------------------------------------------------------
if [ "$MODE" = uninstall ]; then
	echo "--- crontab of $ACCT ---"
	read_crontab "$TMP/before"; ORIG_HAD_CRONTAB="$HAD_CRONTAB"
	check_markers "$TMP/before"
	CRONTAB_BAK="$ACCT_HOME/metal-fy-watch-crontab.bak-$TS"
	CRONTAB_BAK_SHOW="~$ACCT/metal-fy-watch-crontab.bak-$TS"
	if [ "$NB" = 0 ]; then
		echo "no metal-fy-external-watch block — crontab left untouched"
	else
		outside_block "$TMP/before" > "$TMP/new"
		show_crontab_diff "$TMP/before" "$TMP/new"
	fi
	if as_account test -e "$W"; then echo "would remove: $SHOW/"; else echo "$SHOW/ not present"; fi
	if [ "$DRY_RUN" = 1 ]; then echo; echo "DRY-RUN: nothing written."; exit 0; fi
	if [ "$NB" = 1 ]; then
		as_account bash -c 'umask 077; cat > "$1"' _ "$CRONTAB_BAK" < "$TMP/before"
		echo "backup: $CRONTAB_BAK_SHOW"
		write_and_verify "$TMP/new" absent
	fi
	if as_account test -e "$W"; then as_account rm -rf -- "$W"; echo "removed: $SHOW/"; fi
	echo "OK: external watch uninstalled"
	exit 0
fi

[ "$MODE" = install ] || { echo "ERROR: unknown mode" >&2; exit 2; }

# ---- mode: install (stdin: validator host, watch b64, notify b64) ----------
IFS= read -r VHOST || true
IFS= read -r WATCH_B64 || true
IFS= read -r NOTIFY_B64 || true
if ! printf '%s' "$VHOST" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; then
	echo "ERROR (2): validator host value missing or malformed" >&2; exit 2
fi
printf '%s' "$WATCH_B64" | base64 -d > "$TMP/external-watch.sh" 2>/dev/null || true
printf '%s' "$NOTIFY_B64" | base64 -d > "$TMP/notify.sh" 2>/dev/null || true
for f in external-watch.sh notify.sh; do
	if [ ! -s "$TMP/$f" ] || ! bash -n "$TMP/$f" 2>/dev/null; then
		echo "ERROR (2): received $f is empty or fails bash -n" >&2; exit 2
	fi
done

echo "--- validator.json location ---"
if [ -n "$API_DIR_OVERRIDE" ]; then
	API_DIR="${API_DIR_OVERRIDE%/}"
	echo "using FY_WEB_API_DIR override"
else
	WRAPPER="$ACCT_HOME/bin/receive-metal-push"
	if ! as_account test -f "$WRAPPER"; then
		echo "ERROR (6): push wrapper not found under ~$ACCT/bin — pass FY_WEB_API_DIR" >&2; exit 6
	fi
	CANDS="$(as_account sed -nE "s/^[[:space:]]*__fy_root='([^']+)'[[:space:]]*\$/\\1/p" "$WRAPPER" \
		| sed 's|/*$||' | sort -u || true)"
	N="$(printf '%s\n' "$CANDS" | grep -c . || true)"
	if [ "$N" -ne 1 ]; then
		echo "ERROR (6): push wrapper names $N distinct __fy_root dirs — pass FY_WEB_API_DIR" >&2; exit 6
	fi
	API_DIR="$CANDS"
	echo "detected from the push wrapper (__fy_root)"
fi
if ! printf '%s' "$API_DIR" | grep -qE "$SAFE_PATH_RE"; then
	echo "ERROR (6): api dir must be an absolute path of [A-Za-z0-9._/-]" >&2; exit 6
fi
if ! as_account test -d "$API_DIR"; then
	echo "ERROR (6): api dir does not exist or is not reachable by $ACCT" >&2; exit 6
fi
VJSON="$API_DIR/validator.json"
if as_account test -r "$VJSON"; then
	echo "validator.json: readable by $ACCT"
else
	echo "WARNING: validator.json not readable by $ACCT yet — the fresh check will FAIL until it is" >&2
fi

{
	echo "# metal-fy-watch config — written by scripts/install-web-host-external-watch.sh"
	echo "# Strict KEY=VALUE, never sourced. Host-specific: never commit. Mode 600."
	echo "VALIDATOR_HOST=$VHOST"
	echo "VALIDATOR_JSON=$VJSON"
	echo "NTFY_TOPIC_FILE=$W/etc/ntfy-topic"
} > "$TMP/watch.env"

echo
echo "--- files under $SHOW/ ---"
CHANGED=""
plan_file() { # rel src
	local rel="$1" src="$2"
	if ! as_account test -e "$W/$rel"; then
		echo "$rel: new"; CHANGED="$CHANGED $rel"
	elif as_account cmp -s - "$W/$rel" < "$src"; then
		echo "$rel: unchanged"
	else
		CHANGED="$CHANGED $rel"
		if [ "$rel" = etc/watch.env ]; then
			# Names of changed keys only: values are host-specific.
			echo "$rel: update (changed keys: $(as_account cat "$W/$rel" | diff - "$src" \
				| sed -nE 's/^[<>] ([A-Z_][A-Z0-9_]*)=.*/\1/p' | sort -u | tr '\n' ' '))"
		else
			echo "$rel: update"
			as_account diff -u --label "$rel (installed)" --label "$rel (repo)" "$W/$rel" - < "$src" || true
		fi
	fi
}
plan_file bin/external-watch.sh "$TMP/external-watch.sh"
plan_file bin/notify.sh "$TMP/notify.sh"
plan_file etc/watch.env "$TMP/watch.env"

echo
echo "--- crontab of $ACCT ---"
read_crontab "$TMP/before"; ORIG_HAD_CRONTAB="$HAD_CRONTAB"
check_markers "$TMP/before"
CRON_UP_TO_DATE=0
if [ "$NB" = 1 ]; then
	the_block "$TMP/before" > "$TMP/block.before"
	if cmp -s "$TMP/block" "$TMP/block.before"; then CRON_UP_TO_DATE=1; fi
	LC_ALL=C awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v blk="$TMP/block" '
		inb==0 && $0==b { while ((getline l < blk) > 0) print l; inb=1; next }
		inb==1 { if ($0==e) inb=0; next }
		{ print }' "$TMP/before" > "$TMP/new"
else
	cat "$TMP/before" > "$TMP/new"
	if [ -s "$TMP/new" ] && [ "$(tail -c 1 "$TMP/new" | od -An -c | tr -d ' ')" != '\n' ]; then
		printf '\n' >> "$TMP/new"
	fi
	cat "$TMP/block" >> "$TMP/new"
fi
if [ "$CRON_UP_TO_DATE" = 1 ]; then
	echo "crontab block: already up to date"
else
	show_crontab_diff "$TMP/before" "$TMP/new"
fi

if [ "$DRY_RUN" = 1 ]; then
	echo
	echo "DRY-RUN: nothing written."
	exit 0
fi

echo
echo "--- installing ---"
ensure_layout
for rel in $CHANGED; do
	case "$rel" in
		bin/*) mode=700; src="$TMP/${rel#bin/}" ;;
		*)     mode=600; src="$TMP/watch.env" ;;
	esac
	if as_account test -e "$W/$rel"; then
		as_account bash -c 'umask 077; cat "$1" > "$2"' _ "$W/$rel" "$W/backup/$(basename "$rel").bak-$TS"
	fi
	as_account bash -c 'umask 077; t="$(mktemp "$1/.inst.XXXXXX")" && cat > "$t" && chmod "$2" "$t" && mv -f "$t" "$3"' \
		_ "$(dirname "$W/$rel")" "$mode" "$W/$rel" < "$src"
	echo "wrote $rel ($mode)"
done
if ! as_account test -s "$W/etc/ntfy-topic"; then
	echo "ERROR (5): etc/ntfy-topic missing — the topic step must run first" >&2; exit 5
fi

echo
echo "--- layout verification ---"
BAD=0
for spec in ".:700" "bin:700" "etc:700" "state:700" "log:700" "backup:700" \
	"bin/external-watch.sh:700" "bin/notify.sh:700" "etc/watch.env:600" "etc/ntfy-topic:600"; do
	rel="${spec%%:*}"; want="${spec##*:}"
	[ "$rel" = . ] && p="$W" || p="$W/$rel"
	got="$(file_meta "$p" || true)"
	if [ -L "$p" ] || [ "$got" != "$want $ACCT_UID" ]; then
		echo "  BAD $rel (want $want owner $ACCT)" >&2; BAD=1
	fi
done
if [ "$BAD" = 1 ]; then echo "ERROR (11): layout verification failed" >&2; exit 11; fi
echo "modes/owner OK (dirs 700, scripts 700, etc/* 600, owner $ACCT)"

echo
echo "--- self-test (one run, WATCH_LIVE unset: nothing is sent) ---"
set +e
as_account env -i HOME="$ACCT_HOME" PATH="$SELFTEST_PATH" LANG=C.UTF-8 \
	/bin/bash "$W/bin/external-watch.sh" > "$TMP/st.out" 2> "$TMP/st.err"
ST_RC=$?
set -e
sed 's/^/  watch: /' "$TMP/st.err"
if [ "$ST_RC" -ne 0 ]; then
	echo "watch self-test failed: rc=$ST_RC (crontab not armed)" >&2
	exit 8
fi
echo "  log: $(as_account tail -n 1 "$W/log/watch.log" 2>/dev/null || echo '(no log line)')"

echo
echo "--- crontab ---"
if [ "$CRON_UP_TO_DATE" = 1 ]; then
	echo "already up to date — crontab not rewritten"
else
	CRONTAB_BAK="$W/backup/crontab.bak-$TS"
	CRONTAB_BAK_SHOW="$SHOW/backup/crontab.bak-$TS"
	as_account bash -c 'umask 077; cat > "$1"' _ "$CRONTAB_BAK" < "$TMP/before"
	echo "backup: $CRONTAB_BAK_SHOW"
	write_and_verify "$TMP/new" present
	echo "armed: */5 as $ACCT"
fi

echo
echo "OK: external watch installed under $SHOW/"
REMOTE_EOF

if [ "$PRINT_REMOTE" -eq 1 ]; then
	printf '%s\n' "$REMOTE_SCRIPT"
	exit 0
fi

SKIP_SSH="${SKIP_SSH:-0}"
WEB_HOST="${WEB_HOST:-}"
WEB_HOST_USER="${WEB_HOST_USER:-root}"
WEB_HOST_KEY="${WEB_HOST_KEY:-}"
WATCH_ACCOUNT="${WATCH_ACCOUNT:-deploy}"
VALIDATOR_HOST="${VALIDATOR_HOST:-}"
VALIDATOR_SSH_USER="${VALIDATOR_SSH_USER:-}"
VALIDATOR_SSH_KEY="${VALIDATOR_SSH_KEY:-}"
VALIDATOR_TOPIC_FILE="${VALIDATOR_TOPIC_FILE:-}"
FY_WEB_API_DIR="${FY_WEB_API_DIR:-}"
WATCH_SRC="${REPO_ROOT}/scripts/external-watch.sh"
NOTIFY_SRC="${REPO_ROOT}/scripts/notify.sh"
T_HOME="" T_PATH=""
if [ "$SKIP_SSH" = 1 ]; then
	T_HOME="${SKIP_SSH_HOME:-}"
	T_PATH="${SKIP_SSH_SELFTEST_PATH:-}"
	WATCH_SRC="${SKIP_SSH_WATCH_SRC:-$WATCH_SRC}"
fi

die2() { echo "ERROR (2): $*" >&2; exit 2; }

# ---- local preconditions (values checked, never printed) -------------------
if ! printf '%s' "$WATCH_ACCOUNT" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'; then
	die2 "WATCH_ACCOUNT malformed"
fi
if [ -n "$FY_WEB_API_DIR" ] && ! printf '%s' "$FY_WEB_API_DIR" | grep -qE '^/[A-Za-z0-9._/-]+$'; then
	die2 "FY_WEB_API_DIR must be an absolute path of [A-Za-z0-9._/-]"
fi
if [ "$SKIP_SSH" != 1 ]; then
	[ -n "$WEB_HOST" ] || die2 "WEB_HOST required"
	[ -n "$WEB_HOST_KEY" ] || die2 "WEB_HOST_KEY required (no default)"
	[ -r "$WEB_HOST_KEY" ] || die2 "WEB_HOST_KEY not readable"
	printf '%s' "$WEB_HOST_USER" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' || die2 "WEB_HOST_USER malformed"
fi
if [ "$MODE" = install ]; then
	printf '%s' "$VALIDATOR_HOST" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
		|| die2 "VALIDATOR_HOST missing or malformed"
	printf '%s' "$VALIDATOR_TOPIC_FILE" | grep -qE '^/[A-Za-z0-9._/-]+$' \
		|| die2 "VALIDATOR_TOPIC_FILE missing or not an absolute path of [A-Za-z0-9._/-]"
	if [ "$SKIP_SSH" != 1 ]; then
		printf '%s' "$VALIDATOR_SSH_USER" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' \
			|| die2 "VALIDATOR_SSH_USER missing or malformed"
		if [ -z "$VALIDATOR_SSH_KEY" ] || [ ! -r "$VALIDATOR_SSH_KEY" ]; then
			die2 "VALIDATOR_SSH_KEY missing or unreadable"
		fi
	fi
	for f in "$WATCH_SRC" "$NOTIFY_SRC"; do
		if [ ! -s "$f" ] || ! bash -n "$f" 2>/dev/null; then
			die2 "source script missing or fails bash -n: $(basename "$f")"
		fi
	done
fi

# mask: replace every host-specific value with a placeholder. Values reach
# awk through ENVIRON, not argv. Applied to every byte coming back from a host.
mask() {
	M1="$WEB_HOST" M2="$VALIDATOR_HOST" M3="$WEB_HOST_KEY" M4="$VALIDATOR_SSH_KEY" \
	LC_ALL=C awk 'BEGIN {
		n = split("M1 M2 M3 M4", k, " ")
		split("<web host>|<validator host>|<ssh key>|<ssh key>", r, "|")
	}
	{
		for (i = 1; i <= n; i++) {
			v = ENVIRON[k[i]]; if (v == "") continue
			out = ""; s = $0
			while ((p = index(s, v)) > 0) { out = out substr(s, 1, p - 1) r[i]; s = substr(s, p + length(v)) }
			$0 = out s
		}
		print
	}'
}

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

# web_run <mode>: run the remote half on the web host; stdin is passed through.
web_run() {
	local args
	args="$(shq "$1") $(shq "$DRY_RUN") $(shq "$WATCH_ACCOUNT") $(shq "$FY_WEB_API_DIR") $(shq "$T_HOME") $(shq "$T_PATH")"
	if [ "$SKIP_SSH" = 1 ]; then
		eval "set -- $args"
		bash -c "$REMOTE_SCRIPT" _ "$@"
	else
		ssh -i "$WEB_HOST_KEY" "${SSH_OPTS[@]}" "${WEB_HOST_USER}@${WEB_HOST}" \
			"bash -c $(shq "$REMOTE_SCRIPT") _ ${args}"
	fi
}
# validator_run <command>: a fixed read-only command on the validator host.
validator_run() {
	if [ "$SKIP_SSH" = 1 ]; then
		bash -c "$1"
	else
		ssh -i "$VALIDATOR_SSH_KEY" "${SSH_OPTS[@]}" "${VALIDATOR_SSH_USER}@${VALIDATOR_HOST}" "$1"
	fi
}

echo "==> web host:       <web host> (account $WATCH_ACCOUNT)"
[ "$MODE" = install ] && echo "==> validator host: <validator host>"
echo "==> mode:           $MODE$([ "$DRY_RUN" = 1 ] && echo ' (DRY-RUN)')"
echo

if [ "$SKIP_SSH" != 1 ]; then
	set +e
	ssh -i "$WEB_HOST_KEY" "${SSH_OPTS[@]}" "${WEB_HOST_USER}@${WEB_HOST}" 'exit 0' 2>&1 < /dev/null | mask
	rc="${PIPESTATUS[0]}"
	set -e
	if [ "$rc" -ne 0 ]; then echo "ERROR (3): ssh pre-check failed: <web host>" >&2; exit 3; fi
	if [ "$MODE" = install ]; then
		set +e
		ssh -i "$VALIDATOR_SSH_KEY" "${SSH_OPTS[@]}" "${VALIDATOR_SSH_USER}@${VALIDATOR_HOST}" 'exit 0' 2>&1 < /dev/null | mask
		rc="${PIPESTATUS[0]}"
		set -e
		if [ "$rc" -ne 0 ]; then echo "ERROR (3): ssh pre-check failed: <validator host>" >&2; exit 3; fi
	fi
	echo "==> ssh pre-check OK"
fi

TOPIC_READ="cat -- $(shq "$VALIDATOR_TOPIC_FILE")"
if [ "$MODE" = install ]; then
	if [ "$DRY_RUN" = 1 ]; then
		set +e
		validator_run "test -s $(shq "$VALIDATOR_TOPIC_FILE")" < /dev/null 2>&1 | mask
		rc="${PIPESTATUS[0]}"
		set -e
		if [ "$rc" -ne 0 ]; then echo "ERROR (5): topic file on the validator host missing or empty" >&2; exit 5; fi
		echo "==> topic: present on the validator host (DRY-RUN: not read, not transferred)"
	else
		echo "==> streaming the ntfy topic validator host -> web host (never on this Mac's disk)"
		set +e
		validator_run "$TOPIC_READ" < /dev/null 2> >(mask >&2) | web_run topic 2>&1 | mask
		rcs=("${PIPESTATUS[@]}")
		set -e
		if [ "${rcs[0]}" -ne 0 ]; then echo "ERROR (5): could not read the topic on the validator host (rc=${rcs[0]})" >&2; exit 5; fi
		if [ "${rcs[1]}" -ne 0 ]; then echo "ERROR (5): web host rejected the topic (rc=${rcs[1]})" >&2; exit "${rcs[1]}"; fi
	fi
	echo
	WATCH_B64="$(base64 < "$WATCH_SRC" | tr -d '\n')"
	NOTIFY_B64="$(base64 < "$NOTIFY_SRC" | tr -d '\n')"
	set +e
	printf '%s\n%s\n%s\n' "$VALIDATOR_HOST" "$WATCH_B64" "$NOTIFY_B64" | web_run install 2>&1 | mask
	RC="${PIPESTATUS[1]}"
	set -e
else
	set +e
	web_run uninstall < /dev/null 2>&1 | mask
	RC="${PIPESTATUS[0]}"
	set -e
fi

echo
if [ "$RC" -eq 0 ]; then
	echo "==> Done."
else
	echo "==> web host step returned rc=$RC (see above)." >&2
	exit "$RC"
fi
