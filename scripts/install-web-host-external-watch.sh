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
#     etc/watch.env  etc/ntfy-topic           600  (ntfy-topic: the watch's OWN topic)
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
# The validator host is NEVER contacted by this installer (no ssh, no key,
# no command). VALIDATOR_HOST is only written into watch.env for the watch's
# own TCP reachability probe.
#
# Secrets handling:
#   - The watch has its OWN ntfy topic, never the validator host's: a
#     compromise of the shared web host can then read or forge only the
#     watch's channel, and it can be rotated on its own. On the first install
#     it is generated ON THE WEB HOST, as the account, from /dev/urandom
#     (fy-metal-<32 hex>; the prefix keeps publish-guard rule A5 effective),
#     written umask 077 / mode 600. An existing valid topic is kept (never
#     rotated silently); an existing file of any other shape is refused.
#   - Hand-over to the operator never displays it: --copy-topic (run
#     automatically after a first install) streams it from the web host over
#     ssh stdout straight into the Mac clipboard (pbcopy). It never lands on
#     the Mac's disk, never appears in any argv, and is never printed. Without
#     pbcopy the installer refuses (it never falls back to printing).
#   - The validator host address is delivered on the remote session's stdin,
#     not in argv, and is never printed: output shows `<validator host>`.
#     Web host address and key path are masked the same way.
#   - Every file under metal-fy-watch/ is written AS the site account (the
#     root session only reads account data through that account), so a
#     planted symlink there can never make root write elsewhere.
#
# Steps (install):
#   1. ssh pre-check of the web host (BatchMode; no password prompts).
#   2. topic: keep the existing dedicated topic, or generate one on the web
#      host (--dry-run only reports which).
#   3. detect VALIDATOR_JSON from the push wrapper's `__fy_root='<dir>'`
#      line (~WATCH_ACCOUNT/bin/receive-metal-push), or FY_WEB_API_DIR.
#   4. install bin/ + etc/watch.env (existing files backed up to backup/).
#   5. self-test: run the watch once WITHOUT WATCH_LIVE as the account and
#      print its log line. A non-zero exit stops here, BEFORE the crontab is
#      armed, so a watch that cannot even read its config never goes to cron.
#   6. crontab block (backup to backup/crontab.bak-<ts>, write, verify,
#      restore on failure). The armed line is:
#      */5 * * * * WATCH_LIVE=1 /bin/bash $HOME/metal-fy-watch/bin/external-watch.sh >>$HOME/metal-fy-watch/log/cron.err 2>&1
#   7. only if step 2 generated a new topic: --copy-topic (see above), then
#      the operator saves it in the password manager and subscribes to it in
#      the ntfy app.
#
# --uninstall: remove the crontab block (same verification, crontab backed up
# to ~WATCH_ACCOUNT/metal-fy-watch-crontab.bak-<ts> first; only the newest 3
# files of exactly that name are kept, nothing else is touched), then remove
# ~WATCH_ACCOUNT/metal-fy-watch/ (including the watch's topic: a later
# install generates a new one, to be saved and subscribed to again).
# Needs only the WEB_HOST_* variables.
#
# Usage (operator, from the Mac):
#   WEB_HOST=<addr> WEB_HOST_KEY=<key> VALIDATOR_HOST=<addr> \
#     bash scripts/install-web-host-external-watch.sh [--dry-run]
#   WEB_HOST=<addr> WEB_HOST_KEY=<key> \
#     bash scripts/install-web-host-external-watch.sh --copy-topic
#   WEB_HOST=<addr> WEB_HOST_KEY=<key> \
#     bash scripts/install-web-host-external-watch.sh --uninstall [--dry-run]
#
# Options:
#   --dry-run        Connect + inspect + print what would change. Writes
#                    nothing; no topic is generated, read or copied.
#   --print-remote   Print the remote script and exit. No SSH, no env needed,
#                    no host values embedded (they travel on stdin at run time).
#   --copy-topic     Copy the watch's installed topic into the Mac clipboard
#                    (pbcopy) without displaying it. Needs only WEB_HOST_*.
#   --uninstall      Remove the crontab block and ~WATCH_ACCOUNT/metal-fy-watch.
#
# Env (none is ever echoed):
#   WEB_HOST             required
#   WEB_HOST_USER        default root (crontab -u needs it)
#   WEB_HOST_KEY         required, no default
#   WATCH_ACCOUNT        default deploy
#   VALIDATOR_HOST       required for install (written to watch.env only;
#                        never contacted)
#   FY_WEB_API_DIR       web host api/ dir holding validator.json; skips
#                        auto-detection from the push wrapper
#   WATCH_PUBLIC_STATUS  public status file for the phone status page
#                        (/api/watch-status.json, docs/MONITORING_OPS.md §14.7):
#                          auto  = watch-status.json in the same api/ dir as
#                                  validator.json (the site's served api/)
#                          off   = disable (removes the key)
#                          /abs/path.json = explicit target
#                          unset = keep what the installed watch.env has
#                                  (disabled on a first install)
#
# Test mode: SKIP_SSH=1 runs both remote halves locally with `bash -c` (no
# host contacted). Only then are these honoured: SKIP_SSH_HOME (fake account
# home), SKIP_SSH_SELFTEST_PATH (PATH for the self-test, e.g. with stubs),
# SKIP_SSH_WATCH_SRC (substitute watch script). Tests put a fake `crontab`,
# `pbcopy` and `pbpaste` on PATH.
#
# Exit codes:
#   0  installed / already up to date / uninstalled / dry-run / print done
#   2  local precondition failed (env, key unreadable, bad arg, bad source,
#      pbcopy/pbpaste missing)
#   3  ssh pre-check failed
#   4  account, its home, or runuser not usable on the web host
#   5  topic: generation failed, an existing topic file is not a dedicated
#      watch topic (refused, left as is), or none installed (--copy-topic)
#   6  VALIDATOR_JSON dir undeterminable (pass FY_WEB_API_DIR) or invalid
#   7  crontab verification failed — original crontab RESTORED
#   8  watch self-test failed (crontab not armed)
#   9  crontab unreadable or its markers malformed — nothing written
#   10 CRITICAL: crontab restore could not be verified (backup path printed)
#   11 installed layout failed mode/owner verification
#   12 topic hand-over to the clipboard failed (nothing printed; re-run
#      --copy-topic)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODE=install
DRY_RUN=0
PRINT_REMOTE=0
COPY_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--dry-run)      DRY_RUN=1 ;;
		--print-remote) PRINT_REMOTE=1 ;;
		--uninstall)    MODE=uninstall ;;
		--copy-topic)   COPY_ONLY=1 ;;
		-h|--help)      sed -n '2,130p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)              echo "ERROR (2): unknown arg: $arg" >&2; exit 2 ;;
	esac
done
if [ "$COPY_ONLY" = 1 ]; then
	if [ "$MODE" != install ] || [ "$DRY_RUN" = 1 ]; then
		echo "ERROR (2): --copy-topic cannot be combined with --uninstall or --dry-run" >&2; exit 2
	fi
	MODE=copy-topic
fi

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
# $7: WATCH_PUBLIC_STATUS request ("" keep | auto | off | /abs/path.json).
PUBSTAT_REQ="${7:-}"
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

# A symlink at the watch dir or etc/ could steer the topic (or any file) to a
# place of the account's choosing — refuse instead of following it.
refuse_symlinks() {
	local rel
	for rel in "" /etc /bin; do
		if as_account test -L "$W$rel"; then
			echo "ERROR (5): $SHOW$rel is a symlink — refusing, nothing written" >&2; exit 5
		fi
	done
}
ensure_layout() {
	refuse_symlinks
	as_account mkdir -p "$W/bin" "$W/etc" "$W/state" "$W/log" "$W/backup"
	as_account chmod 700 "$W" "$W/bin" "$W/etc" "$W/state" "$W/log" "$W/backup"
}

# ---- mode: topic (keep the existing dedicated topic, or generate one) -------
# The value never leaves the web host here: it is generated file-to-file
# (od | tr into the file; printf is a builtin, so it is in no argv) and only
# ever checked by shape. It is never echoed.
TF="$W/etc/ntfy-topic"
TOPIC_RE='^fy-metal-[0-9a-f]{32}$'
topic_shape_ok() { # file -> 0 if it holds exactly one dedicated watch topic
	as_account bash -c 'v="$(tr -d "[:space:]" < "$1")"; [[ "$v" =~ $2 ]]' _ "$1" "$TOPIC_RE"
}
if [ "$MODE" = topic ]; then
	if [ "$DRY_RUN" = 1 ]; then
		if as_account test -L "$W" || as_account test -L "$W/etc" || as_account test -L "$TF"; then
			echo "ERROR (5): a symlink under $SHOW — refusing" >&2; exit 5
		fi
		if ! as_account test -e "$TF"; then
			echo "topic: none yet — would generate a new dedicated watch topic on the web host (DRY-RUN: nothing generated)"
		elif as_account test -f "$TF" && topic_shape_ok "$TF"; then
			echo "topic: existing dedicated watch topic — would keep it (value not shown)"
		else
			echo "ERROR (5): existing etc/ntfy-topic is not a dedicated watch topic (fy-metal-<32 hex>) — the installer would refuse" >&2; exit 5
		fi
		exit 0
	fi
	ensure_layout
	if as_account test -L "$TF"; then
		echo "ERROR (5): $SHOW/etc/ntfy-topic is a symlink — refusing, nothing written" >&2; exit 5
	fi
	if as_account test -e "$TF"; then
		# Never rotate silently, and never adopt a topic of another shape (for
		# example the validator host's): the operator decides by hand.
		if ! as_account test -f "$TF" || ! topic_shape_ok "$TF"; then
			echo "ERROR (5): existing etc/ntfy-topic is not a dedicated watch topic (fy-metal-<32 hex>) — refusing to use or replace it." >&2
			echo "           Inspect $SHOW/etc/ntfy-topic by hand (or --uninstall), then re-run." >&2
			exit 5
		fi
		as_account chmod 600 "$TF"
		STATE=kept
	else
		T="$(as_account mktemp "$W/etc/.ntfy-topic.XXXXXX")"
		as_account bash -c 'umask 077; { printf "fy-metal-"; od -An -N16 -tx1 /dev/urandom | tr -d " \n"; printf "\n"; } > "$1"' _ "$T"
		if ! topic_shape_ok "$T"; then
			as_account rm -f "$T"
			echo "ERROR (5): topic generation failed — nothing written" >&2; exit 5
		fi
		as_account chmod 600 "$T"
		# -n: a topic that appeared meanwhile is never overwritten.
		as_account mv -n "$T" "$TF"
		if as_account test -e "$T"; then
			as_account rm -f "$T"
			echo "ERROR (5): a topic file appeared while generating — left as is; re-run" >&2; exit 5
		fi
		STATE=generated
	fi
	if ! as_account test -s "$TF" || [ "$(file_meta "$TF")" != "600 $ACCT_UID" ]; then
		echo "ERROR (5): topic file verification failed (non-empty / 600 / owner)" >&2; exit 5
	fi
	echo "topic: $STATE — dedicated watch topic, mode 600, owner $ACCT (value not shown)"
	exit 0
fi

# ---- mode: copy-topic (stdout = the topic, and nothing else) ----------------
# The Mac side pipes this session's stdout straight into pbcopy.
if [ "$MODE" = copy-topic ]; then
	if as_account test -L "$W" || as_account test -L "$W/etc" || as_account test -L "$TF" \
		|| ! as_account test -f "$TF"; then
		echo "ERROR (5): no watch topic installed under $SHOW/etc" >&2; exit 5
	fi
	if ! as_account bash -c 'v="$(tr -d "[:space:]" < "$1")"; [[ "$v" =~ $2 ]] || exit 1; printf "%s" "$v"' _ "$TF" "$TOPIC_RE"; then
		echo "ERROR (5): installed etc/ntfy-topic is not a dedicated watch topic — not copied" >&2; exit 5
	fi
	exit 0
fi

# ---- crontab helpers -------------------------------------------------------
HAD_CRONTAB=0
ORIG_HAD_CRONTAB=0  # captured right after reading "before"; read_crontab overwrites HAD_CRONTAB
# read_crontab <out file> [critical]; sets HAD_CRONTAB. Without "critical" a
# read failure happens before any write (exit 9, nothing written); with it,
# the crontab has already been written and its state is unknown (exit 10).
read_crontab() {
	if crontab -u "$ACCT" -l > "$1" 2> "$TMP/cl.err"; then
		HAD_CRONTAB=1
	elif grep -qi 'no crontab' "$TMP/cl.err"; then
		: > "$1"; HAD_CRONTAB=0
	elif [ "${2:-}" = critical ]; then
		echo "CRITICAL (10): cannot re-read the crontab of $ACCT after writing it — state unknown." >&2
		echo "              Check it by hand. Backup: $CRONTAB_BAK_SHOW" >&2
		exit 10
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
	# Someone else may have edited the crontab since our verification read;
	# restoring now would silently discard their change.
	read_crontab "$TMP/prerestore" critical
	if ! cmp -s "$TMP/after" "$TMP/prerestore"; then
		echo "CRITICAL (10): the crontab changed again after our write — NOT restoring over it." >&2
		echo "              Check it by hand. Backup: $CRONTAB_BAK_SHOW" >&2
		exit 10
	fi
	if [ "$ORIG_HAD_CRONTAB" = 1 ]; then
		crontab -u "$ACCT" "$TMP/before" || true
	else
		crontab -u "$ACCT" -r 2>/dev/null || true
	fi
	read_crontab "$TMP/restored" critical
	if cmp -s "$TMP/before" "$TMP/restored"; then
		echo "restored: crontab of $ACCT is byte-identical to the backup ($CRONTAB_BAK_SHOW)" >&2
	else
		echo "CRITICAL (10): restore could not be verified. Backup: $CRONTAB_BAK_SHOW" >&2
		exit 10
	fi
}

# write_and_verify <new file> <expect: present|absent>
write_and_verify() {
	# Co-tenants share this crontab: if it changed since the "before" snapshot
	# the new file was built from, writing would discard their edit.
	read_crontab "$TMP/recheck"
	if ! cmp -s "$TMP/before" "$TMP/recheck"; then
		echo "ERROR (9): the crontab of $ACCT changed while this installer ran — nothing written." >&2
		echo "           Re-run the installer." >&2
		exit 9
	fi
	crontab -u "$ACCT" "$1" || true
	read_crontab "$TMP/after" critical
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
		echo "           (a co-tenant edit made in the same instant would be rolled back too —" >&2
		echo "            compare the crontab with the backup below after the restore)" >&2
		restore_crontab
		exit 7
	fi
	echo "verified: lines outside the markers identical before/after"
}

# ---- mode: uninstall -------------------------------------------------------
# Uninstall crontab backups live in the account home (the watch dir is being
# removed), one per uninstall. Keep the newest 3 regular files of exactly the
# name shape written above (the timestamps sort as names, LC_ALL=C); never a
# symlink, never any other name. Runs as the account, from inside the home
# verified above, removing "./<name>". A failure is reported, never fatal.
prune_uninstall_backups() {
	as_account env LC_ALL=C bash -c '
		cd -P -- "$1" || exit 1
		k=()
		for b in metal-fy-watch-crontab.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]; do
			if [ -f "$b" ] && [ ! -L "$b" ]; then k+=("$b"); fi
		done
		n=$(( ${#k[@]} - 3 )); i=0; r=0
		while [ "$i" -lt "$n" ]; do rm -f -- "./${k[$i]}" || r=1; i=$((i + 1)); done
		exit "$r"' _ "$ACCT_HOME" \
		|| echo "WARNING: could not prune old ~$ACCT/metal-fy-watch-crontab.bak-* (left as is)" >&2
}

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
		prune_uninstall_backups
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

echo "--- public status file (WATCH_PUBLIC_STATUS) ---"
PUBSTAT_RE='^/[A-Za-z0-9._/-]+[.]json$'
pubstat_ok() { printf '%s' "$1" | grep -qE "$PUBSTAT_RE" && ! printf '%s' "$1" | grep -qE '(^|/)[.][.]?(/|$)|//'; }
PUBSTAT=""
case "$PUBSTAT_REQ" in
	off)  echo "public status: disabled (WATCH_PUBLIC_STATUS=off)" ;;
	auto) PUBSTAT="$API_DIR/watch-status.json"
	      echo "public status: enabled — watch-status.json in the api dir of validator.json (auto)" ;;
	"")
		OLD="$(as_account sed -n 's/^WATCH_PUBLIC_STATUS=//p' "$W/etc/watch.env" 2>/dev/null | tail -n 1 || true)"
		if [ -n "$OLD" ] && pubstat_ok "$OLD"; then
			PUBSTAT="$OLD"; echo "public status: enabled — kept from the installed watch.env"
		else
			echo "public status: disabled (not configured; WATCH_PUBLIC_STATUS=auto enables it)"
		fi ;;
	*)    PUBSTAT="$PUBSTAT_REQ"; echo "public status: enabled — explicit path" ;;
esac
if [ -n "$PUBSTAT" ]; then
	if ! pubstat_ok "$PUBSTAT"; then
		echo "ERROR (6): WATCH_PUBLIC_STATUS must be an absolute *.json path of [A-Za-z0-9._/-] without . or .. segments" >&2; exit 6
	fi
	if ! as_account test -d "${PUBSTAT%/*}" || ! as_account test -w "${PUBSTAT%/*}"; then
		echo "ERROR (6): the public status file's directory does not exist or is not writable by $ACCT" >&2; exit 6
	fi
fi

{
	echo "# metal-fy-watch config — written by scripts/install-web-host-external-watch.sh"
	echo "# Strict KEY=VALUE, never sourced. Host-specific: never commit. Mode 600."
	echo "VALIDATOR_HOST=$VHOST"
	echo "VALIDATOR_JSON=$VJSON"
	echo "NTFY_TOPIC_FILE=$W/etc/ntfy-topic"
	[ -z "$PUBSTAT" ] || echo "WATCH_PUBLIC_STATUS=$PUBSTAT"
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

# plan_crontab: snapshot the crontab ("before") and build the new one. Called
# as late as possible (after the self-test) so the window in which a co-tenant
# edit could race us is minimal; write_and_verify re-checks it anyway.
plan_crontab() {
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
}

if [ "$DRY_RUN" = 1 ]; then
	echo
	echo "--- crontab of $ACCT ---"
	plan_crontab
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
# Account-controlled bytes: control characters (terminal escapes) are
# dropped before they reach the operator's terminal; UTF-8 text is kept.
no_ctrl() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }
sed 's/^/  watch: /' "$TMP/st.err" | no_ctrl
if [ "$ST_RC" -ne 0 ]; then
	echo "watch self-test failed: rc=$ST_RC (crontab not armed)" >&2
	exit 8
fi
ST_LOG="$(as_account tail -n 1 "$W/log/watch.log" 2>/dev/null | no_ctrl || true)"
echo "  log: ${ST_LOG:-(no log line)}"
case "$ST_LOG" in
	*=FAIL*) echo "WARNING: a check FAILed in the self-test — the first live run (within 5 min) may push an alert" >&2 ;;
esac

echo
echo "--- crontab of $ACCT ---"
plan_crontab
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
FY_WEB_API_DIR="${FY_WEB_API_DIR:-}"
WATCH_PUBLIC_STATUS="${WATCH_PUBLIC_STATUS:-}"
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
case "$WATCH_PUBLIC_STATUS" in
	""|auto|off) ;;
	*) if ! printf '%s' "$WATCH_PUBLIC_STATUS" | grep -qE '^/[A-Za-z0-9._/-]+[.]json$' \
		|| printf '%s' "$WATCH_PUBLIC_STATUS" | grep -qE '(^|/)[.][.]?(/|$)|//'; then
		die2 "WATCH_PUBLIC_STATUS must be auto, off, or an absolute *.json path of [A-Za-z0-9._/-]"
	fi ;;
esac
if [ "$SKIP_SSH" != 1 ]; then
	[ -n "$WEB_HOST" ] || die2 "WEB_HOST required"
	[ -n "$WEB_HOST_KEY" ] || die2 "WEB_HOST_KEY required (no default)"
	[ -r "$WEB_HOST_KEY" ] || die2 "WEB_HOST_KEY not readable"
	printf '%s' "$WEB_HOST_USER" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' || die2 "WEB_HOST_USER malformed"
fi
if [ -n "${VALIDATOR_SSH_USER:-}${VALIDATOR_SSH_KEY:-}${VALIDATOR_TOPIC_FILE:-}" ]; then
	echo "note: VALIDATOR_SSH_USER / VALIDATOR_SSH_KEY / VALIDATOR_TOPIC_FILE are no longer used (the validator host is never contacted) — ignored" >&2
fi
# The topic is handed over only through the Mac clipboard; there is no
# printing fallback, so refuse before touching any host.
if [ "$MODE" = copy-topic ] || { [ "$MODE" = install ] && [ "$DRY_RUN" != 1 ]; }; then
	if ! command -v pbcopy >/dev/null 2>&1 || ! command -v pbpaste >/dev/null 2>&1; then
		die2 "pbcopy/pbpaste not found — the watch topic is handed over only through the Mac clipboard and is never printed; run this on the Mac"
	fi
fi
if [ "$MODE" = install ]; then
	printf '%s' "$VALIDATOR_HOST" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
		|| die2 "VALIDATOR_HOST missing or malformed"
	for f in "$WATCH_SRC" "$NOTIFY_SRC"; do
		if [ ! -s "$f" ] || ! bash -n "$f" 2>/dev/null; then
			die2 "source script missing or fails bash -n: $(basename "$f")"
		fi
	done
fi

# mask: replace every host-specific value with a placeholder. Literals (key
# path first, since it may contain a user name, then hosts, then the ssh user)
# reach awk through ENVIRON, not argv. Then any IPv4 dotted quad and anything
# shaped like an IPv6 address is masked generically, so a name ssh resolved
# to an address we never saw is still hidden. Applied to every byte coming
# back from a host.
mask() {
	M1="$WEB_HOST_KEY" M3="$WEB_HOST" M4="$VALIDATOR_HOST" M5="$WEB_HOST_USER" \
	LC_ALL=C awk 'BEGIN {
		n = split("M1 M3 M4 M5", k, " ")
		split("<ssh key>|<web host>|<validator host>|<ssh user>", r, "|")
	}
	{
		for (i = 1; i <= n; i++) {
			v = ENVIRON[k[i]]; if (v == "") continue
			out = ""; s = $0
			while ((p = index(s, v)) > 0) { out = out substr(s, 1, p - 1) r[i]; s = substr(s, p + length(v)) }
			$0 = out s
		}
		gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "<ip>")
		# IPv6: a hex/colon run with >=2 colons that has "::", a hex letter,
		# or >=5 colons. Plain times like 04:53:35 are left alone.
		out = ""; s = $0
		while (match(s, /[0-9A-Fa-f:]+/)) {
			tok = substr(s, RSTART, RLENGTH); t = tok; c = gsub(/:/, ":", t)
			if (c >= 2 && (index(tok, "::") || tok ~ /[A-Fa-f]/ || c >= 5)) tok = "<ip>"
			out = out substr(s, 1, RSTART - 1) tok; s = substr(s, RSTART + RLENGTH)
		}
		print out s
	}'
}

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR
	-o IdentitiesOnly=yes -o ForwardAgent=no -o ClearAllForwardings=yes)

# web_run <mode>: run the remote half on the web host; stdin is passed through.
web_run() {
	local args
	args="$(shq "$1") $(shq "$DRY_RUN") $(shq "$WATCH_ACCOUNT") $(shq "$FY_WEB_API_DIR") $(shq "$T_HOME") $(shq "$T_PATH") $(shq "$WATCH_PUBLIC_STATUS")"
	if [ "$SKIP_SSH" = 1 ]; then
		eval "set -- $args"
		bash -c "$REMOTE_SCRIPT" _ "$@"
	else
		ssh -i "$WEB_HOST_KEY" "${SSH_OPTS[@]}" "${WEB_HOST_USER}@${WEB_HOST}" \
			"bash -c $(shq "$REMOTE_SCRIPT") _ ${args}"
	fi
}

# copy_topic: web host stdout -> pbcopy, never displayed, never on disk. The
# clipboard is then checked by shape only (pbpaste | grep -q), not shown.
copy_topic() {
	local rcs
	set +e
	web_run copy-topic < /dev/null 2> >(mask >&2) | pbcopy
	rcs=("${PIPESTATUS[@]}")
	set -e
	if [ "${rcs[0]}" -ne 0 ] || [ "${rcs[1]}" -ne 0 ]; then
		echo "ERROR (12): topic not copied (web host rc=${rcs[0]}, pbcopy rc=${rcs[1]}) — nothing printed; fix and re-run --copy-topic" >&2
		exit 12
	fi
	if ! pbpaste | LC_ALL=C grep -Eqx 'fy-metal-[0-9a-f]{32}'; then
		echo "ERROR (12): the clipboard does not hold a watch topic after copying — re-run --copy-topic" >&2
		exit 12
	fi
	echo "topic copied to clipboard (not shown)"
	echo "次の手順 (topic は画面にもファイルにも出していません):"
	echo "  1. password manager に「新しい項目」として貼り付けて保存する (validator host の topic とは別の項目)"
	echo "  2. スマートフォンの ntfy アプリで、この topic を購読する (Subscribe to topic に貼り付け)"
	echo "  3. 保存と購読が済んだら、クリップボードを別の文字列で上書きする"
}

echo "==> web host:       <web host> (account $WATCH_ACCOUNT)"
[ "$MODE" = install ] && echo "==> validator host: <validator host> (written to watch.env only; never contacted)"
echo "==> mode:           $MODE$([ "$DRY_RUN" = 1 ] && echo ' (DRY-RUN)')"
echo

if [ "$SKIP_SSH" != 1 ]; then
	set +e
	# Pre-check stderr is discarded, not masked: ssh may print resolved
	# addresses or user names no literal mask knows about.
	ssh -i "$WEB_HOST_KEY" "${SSH_OPTS[@]}" "${WEB_HOST_USER}@${WEB_HOST}" 'exit 0' > /dev/null 2>&1 < /dev/null
	rc=$?
	set -e
	if [ "$rc" -ne 0 ]; then echo "ERROR (3): ssh pre-check failed: <web host> (ssh rc=$rc)" >&2; exit 3; fi
	echo "==> ssh pre-check OK"
fi

if [ "$MODE" = copy-topic ]; then
	copy_topic
	exit 0
fi

TOPIC_STATE=""
if [ "$MODE" = install ]; then
	echo "==> watch topic (dedicated to the watch; never the validator host's)"
	set +e
	TOPIC_OUT="$(web_run topic < /dev/null 2>&1 | mask)"
	rcs=("${PIPESTATUS[@]}")
	set -e
	printf '%s\n' "$TOPIC_OUT"
	if [ "${rcs[0]}" -ne 0 ]; then echo "ERROR (5): watch topic step failed (rc=${rcs[0]}) — nothing else written" >&2; exit "${rcs[0]}"; fi
	case "$TOPIC_OUT" in *"topic: generated "*) TOPIC_STATE=generated ;; *"topic: kept "*) TOPIC_STATE=kept ;; esac
	echo
	WATCH_B64="$(base64 < "$WATCH_SRC" | tr -d '\n')"
	NOTIFY_B64="$(base64 < "$NOTIFY_SRC" | tr -d '\n')"
	set +e
	printf '%s\n%s\n%s\n' "$VALIDATOR_HOST" "$WATCH_B64" "$NOTIFY_B64" | web_run install 2>&1 | mask
	RC="${PIPESTATUS[1]}"
	set -e
	# A topic generated in this run must reach the operator even if a later
	# step failed: the next run keeps it and would not copy it again.
	if [ "$TOPIC_STATE" = generated ]; then
		echo
		echo "==> new watch topic: copying it to the clipboard"
		copy_topic
	elif [ "$TOPIC_STATE" = kept ]; then
		echo "==> existing watch topic kept (run --copy-topic to hand it over again)"
	fi
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
