#!/usr/bin/env bash
# install-notify-relay.sh — host installer (P3) for the notify relay put.
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe. No network, no broadcast, no AI call.
#
# One mode per call:
#   --install-secrets    read the token (line 1) and the URL (line 2) from stdin;
#                        write <relay dir>/token and <relay dir>/url (600, dir 700)
#   --uninstall-secrets  remove token and url (and the dir when empty)
#   --enable-cron        add one FYD_NOTIFY=<repo>/scripts/notify-relay-put.sh line to
#                        each eligible cron file, just before its first command line
#   --disable-cron       remove only that line (every other byte is kept)
#   --dry-run            with any mode: report only, write nothing
#
# Where to connect: the FYD_NOTIFY line in a cron file's env (design doc 10).
# How to remove: --disable-cron, then --uninstall-secrets.
#
# Env overrides (test-time): FYD_CRON_DIR (cron dir; default /etc/cron.d),
# FYD_BACKUP_DIR (copies of changed cron files), NTFY_TOPIC_FILE (moves the
# relay dir). The root requirement is waived only when the matching variable
# is set and not empty.
#
# Exit codes: 0 ok / 1 usage / 2 not root / 3 post-edit check failed (restored) /
#             4 token or URL malformed (nothing written)

set -euo pipefail

# --- definition table
RELAY_CRON_DIR_DEFAULT='/etc/cron.d'
RELAY_CRON_FILE_GLOBS='metal-* freedom-yield-*'
RELAY_CRON_DELEGATE_VARS='FYD_NOTIFY ANCHOR_NOTIFY WATCH_NOTIFY NOTIFY'
RELAY_BACKUP_DIR_PREFIX='/var/backups/metal-notify-relay-'
RELAY_CRON_USER='root'
RELAY_NOTIFY_ENV_NAME='FYD_NOTIFY'
RELAY_PUT_SCRIPT_REL='scripts/notify-relay-put.sh'
RELAY_OWN_TOPIC_ENV_NAME='NTFY_TOPIC_FILE'
RELAY_DIR_MODE='700'
RELAY_FILE_MODE='600'
RELAY_CRON_FILE_MODE='644'

RELAY_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
RELAY_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=SCRIPTDIR/lib/cron-filename-guard.sh
. "${RELAY_SCRIPT_DIR}/lib/cron-filename-guard.sh"
# shellcheck source=SCRIPTDIR/lib/notify-text.sh
. "${RELAY_SCRIPT_DIR}/lib/notify-text.sh"

RELAY_DRY_RUN=0
RELAY_MODE=''
RELAY_MODE_COUNT=0
RELAY_CRON_DIR=''
RELAY_BACKUP_DIR=''
RELAY_LINE="${RELAY_NOTIFY_ENV_NAME}=${RELAY_REPO_ROOT}/${RELAY_PUT_SCRIPT_REL}"
RELAY_LINE_PATTERN="^${RELAY_NOTIFY_ENV_NAME}=.*/${RELAY_PUT_SCRIPT_REL//./\\.}\$"
RELAY_COUNT_CHANGED=0
RELAY_COUNT_OK=0
RELAY_COUNT_EXCLUDED=0
RELAY_COUNT_SKIPPED=0
RELAY_TMP_PATH=''
RELAY_TOKEN_VALUE=''
RELAY_URL_VALUE=''

relay_install_usage() { sed -n '2,20p' "$0" | sed 's/^# \?//'; }
relay_install_fail() { echo "ERROR: $2" >&2; exit "$1"; }
relay_install_cleanup() { if [ -n "$RELAY_TMP_PATH" ]; then rm -f "${RELAY_TMP_PATH:?}"; fi; }
trap relay_install_cleanup EXIT

relay_install_set_mode() {
	RELAY_MODE="$1"
	RELAY_MODE_COUNT=$((RELAY_MODE_COUNT + 1))
}

relay_install_parse_args() {
	local arg
	for arg in "$@"; do
		case "$arg" in
			--dry-run) RELAY_DRY_RUN=1 ;;
			--install-secrets|--uninstall-secrets|--enable-cron|--disable-cron)
				relay_install_set_mode "${arg#--}" ;;
			-h|--help) relay_install_usage; exit 0 ;;
			*) relay_install_fail 1 "unknown arg: $arg" ;;
		esac
	done
	[ "$RELAY_MODE_COUNT" -eq 1 ] || relay_install_fail 1 "give exactly one mode (see --help)"
}

# relay_install_require_root_unless_set <value> <label> — empty value means the real default path.
relay_install_require_root_unless_set() {
	if [ -z "$1" ] && [ "$(id -u)" -ne 0 ]; then
		relay_install_fail 2 "must run as root to touch $2 (usage: sudo bash $0)"
	fi
}

# relay_install_mode_of <path> — octal permission bits (GNU stat first, then BSD).
relay_install_mode_of() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# ---------------------------------------------------------------- secrets

# relay_install_read_stdin — sets RELAY_TOKEN_VALUE and RELAY_URL_VALUE or exits 4 (nothing written).
relay_install_read_stdin() {
	local extra=''
	IFS= read -r RELAY_TOKEN_VALUE || true
	IFS= read -r RELAY_URL_VALUE || true
	if IFS= read -r extra; then
		relay_install_fail 4 "stdin has more than 2 lines"
	fi
	[ -z "$extra" ] || relay_install_fail 4 "stdin has more than 2 lines"
	fyd_relay_token_is_valid "$RELAY_TOKEN_VALUE" || relay_install_fail 4 "line 1 is not a valid token"
	fyd_relay_url_is_valid "$RELAY_URL_VALUE" || relay_install_fail 4 "line 2 is not a valid URL"
}

# relay_install_place_secret <dir> <name> <value> — umask 077 temp file, then mv into place.
relay_install_place_secret() {
	local dir="$1" name="$2" value="$3"
	RELAY_TMP_PATH="$(umask 077; mktemp "${dir}/.install.XXXXXX")"
	printf '%s\n' "$value" > "$RELAY_TMP_PATH"
	chmod "$RELAY_FILE_MODE" "$RELAY_TMP_PATH"
	mv "$RELAY_TMP_PATH" "${dir}/${name}"
	RELAY_TMP_PATH=''
	echo "installed: ${name} ($(relay_install_mode_of "${dir}/${name}"))"
}

relay_install_run_install_secrets() {
	local dir
	relay_install_require_root_unless_set "${NTFY_TOPIC_FILE:-}" "the secret directory"
	relay_install_read_stdin
	dir="$(fyd_relay_dir)"
	if [ "$RELAY_DRY_RUN" -eq 1 ]; then
		echo "would install: ${RELAY_TOKEN_FILE_NAME} (${RELAY_FILE_MODE})"
		echo "would install: ${RELAY_URL_FILE_NAME} (${RELAY_FILE_MODE})"
		return 0
	fi
	(umask 077; mkdir -p "$dir")
	chmod "$RELAY_DIR_MODE" "$dir"
	relay_install_place_secret "$dir" "$RELAY_TOKEN_FILE_NAME" "$RELAY_TOKEN_VALUE"
	relay_install_place_secret "$dir" "$RELAY_URL_FILE_NAME" "$RELAY_URL_VALUE"
}

relay_install_remove_secret() {
	local dir="$1" name="$2"
	if [ ! -e "${dir}/${name}" ]; then echo "absent: ${name}"; return 0; fi
	if [ "$RELAY_DRY_RUN" -eq 1 ]; then echo "would remove: ${name}"; return 0; fi
	rm -f "${dir:?}/${name:?}"
	echo "removed: ${name}"
}

relay_install_run_uninstall_secrets() {
	local dir
	relay_install_require_root_unless_set "${NTFY_TOPIC_FILE:-}" "the secret directory"
	dir="$(fyd_relay_dir)"
	relay_install_remove_secret "$dir" "$RELAY_TOKEN_FILE_NAME"
	relay_install_remove_secret "$dir" "$RELAY_URL_FILE_NAME"
	if [ ! -d "$dir" ]; then echo "absent: directory"; return 0; fi
	if [ "$RELAY_DRY_RUN" -eq 1 ]; then echo "would remove: directory (if empty)"; return 0; fi
	if rmdir "$dir" 2>/dev/null; then echo "removed: directory"; else echo "kept: directory (not empty)"; fi
}

# ------------------------------------------------------------------- cron

# relay_install_command_lines <file> — "<lineno> <user>" for each command line.
relay_install_command_lines() {
	awk '
		/^[[:space:]]*(#|$)/ { next }
		/^[A-Z_]+=/ { next }
		{ u = ($1 ~ /^@/) ? $2 : $6; print NR, u }
	' "$1"
}

relay_install_has_env_line() { grep -qE "^$2=" "$1"; }

relay_install_has_delegate_env() {
	local var
	for var in $RELAY_CRON_DELEGATE_VARS; do
		if relay_install_has_env_line "$1" "$var"; then return 0; fi
	done
	return 1
}

relay_install_has_non_root_user() {
	local user
	while read -r _ user; do
		[ "$user" = "$RELAY_CRON_USER" ] || return 0
	done < <(relay_install_command_lines "$1")
	return 1
}

# relay_install_exclusion_reason <file> — prints a reason word, or nothing when eligible.
relay_install_exclusion_reason() {
	local f="$1"
	if relay_install_has_delegate_env "$f"; then echo other_delegate; return 0; fi
	if relay_install_has_env_line "$f" "$RELAY_OWN_TOPIC_ENV_NAME"; then echo own_topic_file; return 0; fi
	if [ -z "$(relay_install_command_lines "$f")" ]; then echo no_commands; return 0; fi
	if relay_install_has_non_root_user "$f"; then echo non_root_user; return 0; fi
}

relay_install_backup_file() {
	mkdir -p "$RELAY_BACKUP_DIR"
	cp -p "$1" "${RELAY_BACKUP_DIR}/$(basename "$1")"
}

# relay_install_replace_file <file> <new content path> — keep the mode (644 where it cannot be copied).
relay_install_replace_file() {
	chmod --reference="$1" "$2" 2>/dev/null || chmod "$RELAY_CRON_FILE_MODE" "$2"
	chown --reference="$1" "$2" 2>/dev/null || true
	mv "$2" "$1"
}

# relay_install_restore_and_fail <file> — put the saved copy back, exit 3.
relay_install_restore_and_fail() {
	cp -p "${RELAY_BACKUP_DIR}/$(basename "$1")" "$1"
	relay_install_fail 3 "post-edit check failed for $(basename "$1") — restored"
}

relay_install_add_line() {
	local f="$1" first_cmd
	first_cmd="$(relay_install_command_lines "$f" | head -n 1 | cut -d' ' -f1)"
	relay_install_backup_file "$f"
	RELAY_TMP_PATH="$(mktemp)"
	{
		head -n "$((first_cmd - 1))" "$f"
		printf '%s\n' "$RELAY_LINE"
		tail -n "+${first_cmd}" "$f"
	} > "$RELAY_TMP_PATH"
	relay_install_replace_file "$f" "$RELAY_TMP_PATH"
	RELAY_TMP_PATH=''
	[ "$(grep -cxF "$RELAY_LINE" "$f")" -eq 1 ] || relay_install_restore_and_fail "$f"
}

relay_install_enable_one() {
	local f="$1" bn reason
	bn="$(basename "$f")"
	if grep -qxF "$RELAY_LINE" "$f"; then
		RELAY_COUNT_OK=$((RELAY_COUNT_OK + 1)); echo "ok:      ${bn}"; return 0
	fi
	reason="$(relay_install_exclusion_reason "$f")"
	if [ -n "$reason" ]; then
		RELAY_COUNT_EXCLUDED=$((RELAY_COUNT_EXCLUDED + 1)); echo "excluded: ${bn} (${reason})"; return 0
	fi
	RELAY_COUNT_CHANGED=$((RELAY_COUNT_CHANGED + 1))
	if [ "$RELAY_DRY_RUN" -eq 1 ]; then echo "would add: ${bn}"; return 0; fi
	relay_install_add_line "$f"
	echo "added:   ${bn}"
}

# relay_install_strip_line <file> <out> — copy without the relay line; every other byte kept.
relay_install_strip_line() {
	local line has_newline
	while :; do
		if IFS= read -r line; then has_newline=1; else [ -n "$line" ] || break; has_newline=0; fi
		if ! printf '%s\n' "$line" | grep -qE "$RELAY_LINE_PATTERN"; then
			if [ "$has_newline" -eq 1 ]; then printf '%s\n' "$line"; else printf '%s' "$line"; fi
		fi
	done < "$1" > "$2"
}

relay_install_disable_one() {
	local f="$1" bn
	bn="$(basename "$f")"
	if ! grep -qE "$RELAY_LINE_PATTERN" "$f"; then
		RELAY_COUNT_OK=$((RELAY_COUNT_OK + 1)); echo "ok:      ${bn} (no relay line)"; return 0
	fi
	RELAY_COUNT_CHANGED=$((RELAY_COUNT_CHANGED + 1))
	if [ "$RELAY_DRY_RUN" -eq 1 ]; then echo "would remove: ${bn}"; return 0; fi
	relay_install_backup_file "$f"
	RELAY_TMP_PATH="$(mktemp)"
	relay_install_strip_line "$f" "$RELAY_TMP_PATH"
	relay_install_replace_file "$f" "$RELAY_TMP_PATH"
	RELAY_TMP_PATH=''
	if grep -qE "$RELAY_LINE_PATTERN" "$f"; then
		relay_install_restore_and_fail "$f"
	fi
	echo "removed: ${bn}"
}

relay_install_print_summary() {
	local label prefix='summary:'
	if [ "$1" = "enable" ]; then label='added'; else label='removed'; fi
	if [ "$RELAY_DRY_RUN" -eq 1 ]; then prefix='DRY-RUN summary:'; label="would be ${label}"; fi
	echo "${prefix} ${label} ${RELAY_COUNT_CHANGED}, ok ${RELAY_COUNT_OK}, excluded ${RELAY_COUNT_EXCLUDED}, skipped (not cron-executed) ${RELAY_COUNT_SKIPPED}"
	if [ "$RELAY_DRY_RUN" -eq 0 ] && [ "$RELAY_COUNT_CHANGED" -gt 0 ]; then echo "backups: ${RELAY_BACKUP_DIR}/"; fi
}

relay_install_run_cron() {
	local action="$1" glob f bn
	for glob in $RELAY_CRON_FILE_GLOBS; do
		for f in "$RELAY_CRON_DIR"/$glob; do
			[ -f "$f" ] || continue
			bn="$(basename "$f")"
			if ! is_cron_executed_filename "$bn"; then
				RELAY_COUNT_SKIPPED=$((RELAY_COUNT_SKIPPED + 1))
				echo "skipped (not a cron-executed filename): ${bn}"
				continue
			fi
			"relay_install_${action}_one" "$f"
		done
	done
	echo ""
	relay_install_print_summary "$action"
}

relay_install_prepare_cron() {
	local stamp
	if [ -n "${FYD_CRON_DIR:-}" ]; then RELAY_CRON_DIR="$FYD_CRON_DIR"; else RELAY_CRON_DIR="$RELAY_CRON_DIR_DEFAULT"; fi
	relay_install_require_root_unless_set "${FYD_CRON_DIR:-}" "$RELAY_CRON_DIR_DEFAULT"
	stamp="$(date -u +%Y%m%d-%H%M%S)"
	if [ -n "${FYD_BACKUP_DIR:-}" ]; then RELAY_BACKUP_DIR="$FYD_BACKUP_DIR"; else RELAY_BACKUP_DIR="${RELAY_BACKUP_DIR_PREFIX}${stamp}"; fi
}

relay_install_main() {
	relay_install_parse_args "$@"
	case "$RELAY_MODE" in
		install-secrets) relay_install_run_install_secrets ;;
		uninstall-secrets) relay_install_run_uninstall_secrets ;;
		enable-cron) relay_install_prepare_cron; relay_install_run_cron enable ;;
		disable-cron) relay_install_prepare_cron; relay_install_run_cron disable ;;
	esac
}

relay_install_main "$@"
