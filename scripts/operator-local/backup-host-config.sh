#!/usr/bin/env bash
# scripts/operator-local/backup-host-config.sh
#
# CHAIN: none — no blockchain is contacted; nothing is broadcast.
#
# Off-host encrypted backup of the validator host's untracked configuration:
#   - the host config directory  /etc/freedom-yield/   (whole directory)
#   - the deploy checkout's      <DEPLOY_PATH>/.env
# Neither is in git, and before this script neither had a copy anywhere but
# the validator host itself (docs/DISASTER_RECOVERY.md, 前提 section).
#
# Runs on the operator's Mac, interactively. Never on a server.
#
# How the plaintext is kept off disk:
#   ssh <host> 'tar -C /etc -cf - freedom-yield -C <DEPLOY_PATH> .env'
#     | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt   (-> .tar.enc)
#   The tar stream goes straight from the ssh pipe into openssl; no plaintext
#   tar file exists at any point, on the host or on the Mac. The only command
#   run on the host is that read-only `tar -cf -`.
#   The cipher, KDF and iteration count are the same as the staker key backup
#   (AES-256-CBC + PBKDF2, 600k iterations), so the same manual command
#   decrypts both.
#
# Passphrase: prompted twice with `read -s` on the terminal. It is never
# taken from argv, an environment variable or a file, and it is never placed
# on the argv of any process: openssl reads it with `-pass env:` from a
# variable set only in openssl's own environment (same convention as the
# staker backup scripts).
#
# Steps of a backup run:
#   1. list what the host would send (names only, via `tar -t` of the stream)
#   2. prompt for the passphrase twice; refuse on mismatch or empty
#   3. stream + encrypt to ~/fy-host-config-backup-<UTC yyyymmdd>.tar.enc.partial
#      (mode 600), rename to .tar.enc on success
#   4. VERIFY: decrypt to a pipe, `tar -t`, compare names with step 1's list
#      and the required set. On failure the file is kept but renamed to
#      *.tar.enc.VERIFY-FAILED and the script exits non-zero.
#   5. only after a passing verify: copy to the Dropbox backup directory,
#      check the copy's sha256 matches, print sha256 of the encrypted file.
#
# Usage:
#   VALIDATOR_HOST=<host> VALIDATOR_SSH_KEY=~/.ssh/<key> \
#     bash scripts/operator-local/backup-host-config.sh            # backup
#   VALIDATOR_HOST=<host> VALIDATOR_SSH_KEY=~/.ssh/<key> \
#     bash scripts/operator-local/backup-host-config.sh --dry-run  # names only
#   bash scripts/operator-local/backup-host-config.sh --verify <file.tar.enc>
#                                     # restore drill: decrypt to a pipe + list
#
# Env:
#   VALIDATOR_HOST       validator host (REQUIRED for backup / --dry-run)
#   VALIDATOR_SSH_KEY    ssh private key path (REQUIRED for backup / --dry-run)
#   VALIDATOR_SSH_USER   ssh user (default: root — /etc/freedom-yield is root's)
#   DEPLOY_PATH          deploy checkout on the host
#                        (default: /home/deploy/metal.freedom-yield.com)
#   BACKUP_OUT_DIR       where the .tar.enc is written (default: $HOME)
#   BACKUP_DROPBOX_DIR   off-site copy dir (default: $HOME/Dropbox/metal-validator-backup)
#
# Exit codes:
#   0  success
#   1  verification failed (backup kept as *.VERIFY-FAILED, not copied)
#   2  usage / precondition refused (nothing written)
#   3  host stream or encryption failed (partial kept as *.INCOMPLETE)
#   4  backup verified locally, but the Dropbox copy could not be made/checked
#   99 refused: this looks like a server, not the operator's Mac
# shellcheck disable=SC2001  # sed indents multi-line name lists
set -euo pipefail
umask 077

CIPHER_ARGS=(-aes-256-cbc -pbkdf2 -iter 600000)
CONFIG_PARENT="/etc"
CONFIG_NAME="freedom-yield"
# Names that MUST be in every archive (tar -t form). The rest of the expected
# set is whatever the host listed in step 1.
REQUIRED_NAMES=("${CONFIG_NAME}/" ".env")
# Known config entries: a missing one is reported as a WARN, not a refusal.
KNOWN_NAMES=(web-host ntfy-topic calendar-token wallet-addresses.json watch-list.json)

usage() { sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; }
die() { local rc="$1"; shift; echo "ERROR: $*" >&2; exit "$rc"; }

MODE="backup"
VERIFY_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) MODE="dry-run" ;;
		--verify)
			MODE="verify"
			[ $# -ge 2 ] || die 2 "--verify needs a file argument"
			VERIFY_FILE="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die 2 "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

# ---- refuse on servers (same guard shape as gen-identity.sh) --------------
if [ -f "${CONFIG_PARENT}/${CONFIG_NAME}/web-host" ] || [ -f "${CONFIG_PARENT}/${CONFIG_NAME}/validator-host" ]; then
	echo "REFUSE: ${CONFIG_PARENT}/${CONFIG_NAME}/ exists here — this is a server. Run on the operator's Mac." >&2
	exit 99
fi
if [ -d /home/deploy ] && id deploy >/dev/null 2>&1; then
	echo "REFUSE: a 'deploy' user exists here — this looks like a server. Run on the operator's Mac." >&2
	exit 99
fi

# ---- helpers ---------------------------------------------------------------
# Interactive only: the passphrase must come from a person at a terminal.
# FYBK_TEST_ALLOW_NON_TTY=1 exists for the hermetic test suite only (it feeds
# the prompts through a pipe); it carries no passphrase itself.
require_tty() {
	if [ ! -t 0 ] && [ "${FYBK_TEST_ALLOW_NON_TTY:-}" != "1" ]; then
		die 2 "stdin is not a terminal — the passphrase is only accepted interactively"
	fi
}

# read_passphrase <confirm:0|1> — sets global FYBK_PP. Never echoes it.
read_passphrase() {
	local confirm="$1" p1="" p2=""
	# Prompt printed explicitly (bash's read -p stays silent off a terminal).
	printf 'Enter backup passphrase: ' >&2
	read -rs p1 || true
	echo >&2
	if [ "$confirm" = "1" ]; then
		printf 'Repeat backup passphrase: ' >&2
		read -rs p2 || true
		echo >&2
		if [ "$p1" != "$p2" ]; then
			p1=""; p2=""
			die 2 "passphrases do not match — nothing fetched, nothing written"
		fi
	fi
	p2=""
	[ -n "$p1" ] || die 2 "empty passphrase rejected"
	FYBK_PP="$p1"
	p1=""
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# decrypt_list <file> — decrypts to a pipe and prints the tar member names.
# The passphrase reaches openssl through its own environment only.
decrypt_list() {
	FYBK_OPENSSL_PASS="$FYBK_PP" openssl enc -d "${CIPHER_ARGS[@]}" \
		-pass env:FYBK_OPENSSL_PASS -in "$1" 2>/dev/null | tar -tf -
}

# check_required <newline-separated names> — prints what is missing; rc 1 if
# a REQUIRED name is absent (a missing KNOWN name is only a WARN).
check_required() {
	local names="$1" rc=0 n k
	for n in "${REQUIRED_NAMES[@]}"; do
		grep -qxF -- "$n" <<<"$names" || { echo "  MISSING (required): $n" >&2; rc=1; }
	done
	for k in "${KNOWN_NAMES[@]}"; do
		grep -qxF -- "${CONFIG_NAME}/$k" <<<"$names" || echo "  WARN: known entry not present: ${CONFIG_NAME}/$k" >&2
	done
	return "$rc"
}

# ---- --verify: restore drill on an existing file ---------------------------
if [ "$MODE" = "verify" ]; then
	[ -f "$VERIFY_FILE" ] || die 2 "file not found: $VERIFY_FILE"
	require_tty
	echo "Verify: $VERIFY_FILE ($(wc -c <"$VERIFY_FILE" | tr -d ' ') bytes)" >&2
	echo "Decrypts to a pipe and lists names only; nothing is extracted." >&2
	read_passphrase 0
	if ! NAMES="$(decrypt_list "$VERIFY_FILE")"; then
		FYBK_PP=""
		die 1 "decryption or listing failed (wrong passphrase or corrupt file): $VERIFY_FILE"
	fi
	FYBK_PP=""
	echo "Contents (names only):"
	sed 's/^/  /' <<<"$NAMES"
	check_required "$NAMES" || die 1 "archive is missing required entries: $VERIFY_FILE"
	echo "sha256: $(sha256_of "$VERIFY_FILE")  $VERIFY_FILE"
	echo "✓ VERIFY PASS: decrypts and contains $(grep -c . <<<"$NAMES") entries"
	exit 0
fi

# ---- backup / dry-run preconditions ----------------------------------------
: "${VALIDATOR_HOST:=}"
[ -n "$VALIDATOR_HOST" ] || die 2 "VALIDATOR_HOST is not set (never hardcoded; the repo is public)"
: "${VALIDATOR_SSH_KEY:=}"
[ -n "$VALIDATOR_SSH_KEY" ] || die 2 "VALIDATOR_SSH_KEY is not set (ssh -i is mandatory)"
[ -f "$VALIDATOR_SSH_KEY" ] || die 2 "VALIDATOR_SSH_KEY not found: $VALIDATOR_SSH_KEY"
VALIDATOR_SSH_USER="${VALIDATOR_SSH_USER:-root}"
DEPLOY_PATH="${DEPLOY_PATH:-/home/deploy/metal.freedom-yield.com}"
# DEPLOY_PATH is interpolated into the remote command: allow only plain paths.
[[ "$DEPLOY_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || die 2 "DEPLOY_PATH must be an absolute plain path: $DEPLOY_PATH"
[[ "$VALIDATOR_SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die 2 "VALIDATOR_SSH_USER looks invalid"

# The ONLY command run on the host: a read-only tar to stdout.
REMOTE_CMD="tar -C ${CONFIG_PARENT} -cf - ${CONFIG_NAME} -C ${DEPLOY_PATH} .env"

# host_stream — writes the host's tar stream to stdout. `-n`: ssh never reads
# this script's stdin (the passphrase prompt lives there).
host_stream() {
	ssh -n -o BatchMode=yes -o IdentitiesOnly=yes -i "$VALIDATOR_SSH_KEY" \
		"${VALIDATOR_SSH_USER}@${VALIDATOR_HOST}" "$REMOTE_CMD"
}

echo "Host command (read-only): $REMOTE_CMD" >&2
echo "[1] Listing what the host would send (names only)…" >&2
if ! EXPECTED_NAMES="$(host_stream | tar -tf -)"; then
	die 3 "could not list the host's config stream (ssh or tar failed)"
fi
[ -n "$EXPECTED_NAMES" ] || die 3 "host stream listed no entries"
EXPECTED_SORTED="$(LC_ALL=C sort <<<"$EXPECTED_NAMES")"
sed 's/^/  /' <<<"$EXPECTED_SORTED"
check_required "$EXPECTED_SORTED" || die 3 "host stream is missing required entries"

if [ "$MODE" = "dry-run" ]; then
	echo "(dry-run: $(grep -c . <<<"$EXPECTED_SORTED") entries would be encrypted; no passphrase asked, nothing written)"
	exit 0
fi

# ---- backup ----------------------------------------------------------------
OUT_DIR="${BACKUP_OUT_DIR:-$HOME}"
DROPBOX_DIR="${BACKUP_DROPBOX_DIR:-$HOME/Dropbox/metal-validator-backup}"
STAMP="$(date -u +%Y%m%d)"
OUT="${OUT_DIR}/fy-host-config-backup-${STAMP}.tar.enc"
PARTIAL="${OUT}.partial"
[ -d "$OUT_DIR" ] || die 2 "BACKUP_OUT_DIR not found: $OUT_DIR"
for f in "$OUT" "$PARTIAL"; do
	[ ! -e "$f" ] || die 2 "already exists, refusing to overwrite: $f (move it aside first)"
done

require_tty
echo "[2] Passphrase (AES-256-CBC + PBKDF2 600k, same as the staker backup)" >&2
read_passphrase 1

echo "[3] Streaming host config straight into openssl → $OUT" >&2
: >"$PARTIAL"
chmod 600 "$PARTIAL"
if ! host_stream | FYBK_OPENSSL_PASS="$FYBK_PP" openssl enc -e "${CIPHER_ARGS[@]}" -salt \
	-pass env:FYBK_OPENSSL_PASS -out "$PARTIAL"; then
	FYBK_PP=""
	mv -f "$PARTIAL" "${OUT}.INCOMPLETE"
	die 3 "stream or encryption failed; partial kept as ${OUT}.INCOMPLETE (not a valid backup)"
fi
mv "$PARTIAL" "$OUT"
chmod 600 "$OUT"

echo "[4] Verifying: decrypt to a pipe, list, compare with step 1" >&2
VERIFY_OK=1
if ACTUAL_NAMES="$(decrypt_list "$OUT")"; then
	ACTUAL_SORTED="$(LC_ALL=C sort <<<"$ACTUAL_NAMES")"
	if [ "$ACTUAL_SORTED" != "$EXPECTED_SORTED" ]; then
		echo "  name set differs from the host listing:" >&2
		diff <(echo "$EXPECTED_SORTED") <(echo "$ACTUAL_SORTED") | sed 's/^/    /' >&2 || true
		VERIFY_OK=0
	fi
	check_required "$ACTUAL_SORTED" || VERIFY_OK=0
else
	echo "  decryption/listing of the written file failed" >&2
	VERIFY_OK=0
fi
FYBK_PP=""

if [ "$VERIFY_OK" != "1" ]; then
	mv "$OUT" "${OUT}.VERIFY-FAILED"
	echo "✗ VERIFY FAILED — kept as ${OUT}.VERIFY-FAILED, NOT copied to Dropbox. Do not trust it." >&2
	exit 1
fi
SHA="$(sha256_of "$OUT")"
echo "✓ verify PASS ($(grep -c . <<<"$ACTUAL_SORTED") entries)"

echo "[5] Off-site copy → $DROPBOX_DIR" >&2
[ -d "$DROPBOX_DIR" ] || die 4 "Dropbox dir not found: $DROPBOX_DIR — local backup is verified at $OUT, copy it manually"
DEST="${DROPBOX_DIR}/$(basename "$OUT")"
[ ! -e "$DEST" ] || die 4 "already exists in Dropbox, not overwritten: $DEST"
cp "$OUT" "$DEST"
chmod 600 "$DEST"
[ "$(sha256_of "$DEST")" = "$SHA" ] || die 4 "Dropbox copy sha256 mismatch: $DEST"

echo
echo "✓ BACKUP DONE"
echo "  file:    $OUT"
echo "  copy:    $DEST"
echo "  sha256:  $SHA"
echo "  restore drill: bash scripts/operator-local/backup-host-config.sh --verify $OUT"
