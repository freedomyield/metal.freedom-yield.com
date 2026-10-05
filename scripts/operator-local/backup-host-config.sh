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
# Runs on the operator's Mac, NON-INTERACTIVELY: the AI runs it routinely.
# It never asks for a passphrase and never reads stdin. Never on a server.
#
# Encryption: `age` to the operator identity SSH PUBLIC key (ssh-ed25519).
# Encrypting needs only the public key, so nobody types anything. Decrypting
# needs the matching PRIVATE key (and its passphrase) — disaster only; see
# --restore-help. This script never reads, asks for or accepts a private key.
#
# How the plaintext is kept off disk:
#   ssh <host> 'tar -C /etc -cf - freedom-yield -C <DEPLOY_PATH> .env'
#     | tee <fifo> | age -R <pubkey> -o <file>.partial
#   The fifo feeds an in-memory `tar -t` (names only) and a byte counter, so
#   the exact stream that was encrypted is listed without being stored. No
#   plaintext tar file exists at any point, on the host or on the Mac.
#   umask 077; every file written is mode 600.
#
# Steps of a backup run:
#   0. validate the recipient public key (refuse a private key, any key type
#      other than ssh-ed25519, or more than one key) and compute its age tag
#   1. list what the host would send (names only, via `tar -t` of the stream)
#   2. stream + encrypt to ~/fy-host-config-backup-<UTC yyyymmdd>.tar.age.partial,
#      rename to .tar.age on success (on failure: *.INCOMPLETE, exit 3)
#   3. VERIFY without decrypting (the AI cannot decrypt, by design):
#      a. the names listed in flight from the encrypted stream == step 1's list,
#         and the required names are present
#      b. the age header is v1 with exactly ONE recipient stanza, of type
#         ssh-ed25519, whose tag equals the tag computed from the public key
#      c. the file size equals header + the age payload size for the counted
#         plaintext bytes (16-byte nonce + 16-byte tag per 64 KiB chunk)
#      d. re-fetch the host's per-file sha256 (read-only `sha256sum` over ssh),
#         check every line is `<64 hex>  <name>` (hashes and names only, never
#         contents) and that its file set equals the archive's file set
#      e. encrypt that manifest to the same recipient as <file>.manifest.age
#         (mode 600; header + size checked as in b/c). The plaintext manifest
#         exists only in the run's mktemp dir (mode 600), removed on every
#         exit path: hashes of low-entropy files are guessable.
#      On failure: backup and manifest renamed *.VERIFY-FAILED, exit 1.
#   4. only after a passing verify: copy the two .age files (backup + manifest)
#      to the Dropbox backup directory, check both copies' sha256.
#
# Usage (AI, routine — no operator input):
#   VALIDATOR_HOST=<host> VALIDATOR_SSH_KEY=~/.ssh/<key> \
#     bash scripts/operator-local/backup-host-config.sh            # backup
#   VALIDATOR_HOST=<host> VALIDATOR_SSH_KEY=~/.ssh/<key> \
#     bash scripts/operator-local/backup-host-config.sh --dry-run  # names only
#   bash scripts/operator-local/backup-host-config.sh --restore-help
#                       # prints how the OPERATOR decrypts in a disaster
#
# Env:
#   VALIDATOR_HOST          validator host (REQUIRED for backup / --dry-run)
#   VALIDATOR_SSH_KEY       ssh private key path for the host login
#                           (REQUIRED for backup / --dry-run; used only by ssh)
#   VALIDATOR_SSH_USER      ssh user (default: root — /etc/freedom-yield is root's)
#   DEPLOY_PATH             deploy checkout on the host
#                           (default: /home/deploy/metal.freedom-yield.com)
#   BACKUP_RECIPIENT_PUBKEY age recipient: an ssh-ed25519 PUBLIC key file
#                           (default: ~/.ssh/freedom-yield-operator-identity.pub)
#   BACKUP_OUT_DIR          where the .tar.age is written (default: $HOME)
#   BACKUP_DROPBOX_DIR      off-site copy dir (default: $HOME/Dropbox/metal-validator-backup)
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

CONFIG_PARENT="/etc"
CONFIG_NAME="freedom-yield"
# Names that MUST be in every archive (tar -t form). The rest of the expected
# set is whatever the host listed in step 1.
REQUIRED_NAMES=("${CONFIG_NAME}/" ".env")
# Known config entries: a missing one is reported as a WARN, not a refusal.
KNOWN_NAMES=(web-host ntfy-topic calendar-token wallet-addresses.json watch-list.json)

usage() { sed -n '2,78p' "$0" | sed 's/^# \{0,1\}//'; }
die() { local rc="$1"; shift; echo "ERROR: $*" >&2; exit "$rc"; }

MODE="backup"
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) MODE="dry-run" ;;
		--restore-help) MODE="restore-help" ;;
		-h|--help) usage; exit 0 ;;
		*) die 2 "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

RECIPIENT="${BACKUP_RECIPIENT_PUBKEY:-$HOME/.ssh/freedom-yield-operator-identity.pub}"

# ---- --restore-help: disaster-only instructions for the operator -----------
if [ "$MODE" = "restore-help" ]; then
	PRIV="${RECIPIENT%.pub}"
	cat <<EOF
Restore of a host-config backup — DISASTER ONLY, done by the OPERATOR.

The backup is encrypted with age to the operator identity public key
  $RECIPIENT
Only the matching PRIVATE key decrypts it:
  $PRIV
age prompts for that key's passphrase on the terminal. Nothing in the
routine backup / drill flow ever needs it.

1. Pick the file (no decryption needed to check it):
     ls -l ~/fy-host-config-backup-<yyyymmdd>.tar.age ~/fy-host-config-backup-<yyyymmdd>.tar.age.manifest.age
     (same files in ~/Dropbox/metal-validator-backup/)

2. Decrypt to a pipe straight into the NEW host (no plaintext on the Mac's disk):
     age -d -i $PRIV ~/fy-host-config-backup-<yyyymmdd>.tar.age \\
       | ssh -i ~/.ssh/<your_validator_host_key> root@<new host> \\
           'umask 077 && mkdir /root/fy-config-restore && tar -C /root/fy-config-restore -xpf -'

3. Check against the manifest (also age-encrypted; decrypt it to a pipe too):
     age -d -i $PRIV ~/fy-host-config-backup-<yyyymmdd>.tar.age.manifest.age \\
       | ssh -i ~/.ssh/<your_validator_host_key> root@<new host> \\
           'cd /root/fy-config-restore && sha256sum -c -'
   then put the files in place:
     # new host (root):
     #   cp -a /root/fy-config-restore/freedom-yield /etc/
     #   install -m 600 /root/fy-config-restore/.env <deploy_path>/.env
     #   rewrite METAL_PUBLIC_IP in .env to the new IP
     #   rm -rf /root/fy-config-restore

Full procedure: docs/DISASTER_RECOVERY.md (前提 section).
EOF
	exit 0
fi

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
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# recipient_tag <pubkey file> — validates an OpenSSH ssh-ed25519 PUBLIC key
# file and prints its age stanza tag: base64 (no padding) of the first 4 bytes
# of SHA-256 over the SSH wire-format key (age spec, ssh-ed25519 recipient).
# Refuses (rc 1, reason on stderr) on a private key, another key type, more
# than one key, or a malformed blob.
recipient_tag() {
	perl -MMIME::Base64 -MDigest::SHA=sha256 -e '
		my $f = shift; open(my $h, "<", $f) or do { print STDERR "  cannot read the key file\n"; exit 1 };
		local $/; my $all = <$h>; close $h;
		if ($all =~ /PRIVATE KEY|-{5}BEGIN /) { print STDERR "  this is a PRIVATE key, not a public key\n"; exit 1 }
		my @l = grep { /\S/ } split /\n/, $all;
		@l == 1 or do { print STDERR "  expected exactly one public key line, found ".scalar(@l)."\n"; exit 1 };
		my ($type, $b64) = split /\s+/, $l[0];
		$type eq "ssh-ed25519" or do { print STDERR "  key type is \"$type\"; only ssh-ed25519 is accepted\n"; exit 1 };
		($b64 // "") =~ m{^[A-Za-z0-9+/]+=*$} or do { print STDERR "  malformed key body\n"; exit 1 };
		my $blob = decode_base64($b64);
		length($blob) == 51 && substr($blob, 0, 15) eq "\x00\x00\x00\x0bssh-ed25519" && substr($blob, 15, 4) eq "\x00\x00\x00\x20"
			or do { print STDERR "  key body is not an ssh-ed25519 public key\n"; exit 1 };
		my $t = encode_base64(substr(sha256($blob), 0, 4), ""); $t =~ s/=+$//; print $t;
	' "$1"
}

# check_age_file <file> <expected tag> <plaintext bytes> — verifies the age v1
# header (exactly one stanza, ssh-ed25519, our tag) and the exact file size.
check_age_file() {
	perl -e '
		my ($f, $tag, $n) = @ARGV; open(my $h, "<:raw", $f) or do { print STDERR "  cannot read $f\n"; exit 1 };
		my $size = -s $f; my $hlen = 0; my @st; my $mac = 0;
		my $first = <$h>; defined $first or do { print STDERR "  empty file\n"; exit 1 };
		$hlen += length $first;
		$first eq "age-encryption.org/v1\n" or do { print STDERR "  not an age v1 header\n"; exit 1 };
		while (my $l = <$h>) {
			$hlen += length $l;
			if ($l =~ /^-> (.*)\n\z/) { push @st, [split / /, $1]; next }
			if ($l =~ m{^--- [A-Za-z0-9+/]{43}\n\z}) { $mac = 1; last }
			last if $hlen > 4096;   # stanza body lines are skipped; header is bounded
		}
		$mac or do { print STDERR "  no header MAC line\n"; exit 1 };
		@st == 1 or do { print STDERR "  expected exactly 1 recipient stanza, found ".scalar(@st)."\n"; exit 1 };
		$st[0][0] eq "ssh-ed25519" or do { print STDERR "  stanza type is $st[0][0], expected ssh-ed25519\n"; exit 1 };
		($st[0][1] // "") eq $tag or do { print STDERR "  stanza tag ".($st[0][1] // "")." != recipient tag $tag\n"; exit 1 };
		my $chunks = $n == 0 ? 1 : int(($n + 65535) / 65536);
		my $want = $hlen + 16 + $n + 16 * $chunks;
		$size == $want or do { print STDERR "  size $size != expected $want (header $hlen + payload for $n plaintext bytes)\n"; exit 1 };
	' "$1" "$2" "$3"
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

# ---- recipient (checked before anything touches the host) ------------------
[ -f "$RECIPIENT" ] || die 2 "recipient public key not found: $RECIPIENT (set BACKUP_RECIPIENT_PUBKEY)"
if ! RECIPIENT_TAG="$(recipient_tag "$RECIPIENT")"; then
	die 2 "refusing recipient $RECIPIENT (must be exactly one ssh-ed25519 PUBLIC key)"
fi

# ---- backup / dry-run preconditions ----------------------------------------
: "${VALIDATOR_HOST:=}"
[ -n "$VALIDATOR_HOST" ] || die 2 "VALIDATOR_HOST is not set (never hardcoded; the repo is public)"
: "${VALIDATOR_SSH_KEY:=}"
[ -n "$VALIDATOR_SSH_KEY" ] || die 2 "VALIDATOR_SSH_KEY is not set (ssh -i is mandatory)"
[ -f "$VALIDATOR_SSH_KEY" ] || die 2 "VALIDATOR_SSH_KEY not found: $VALIDATOR_SSH_KEY"
VALIDATOR_SSH_USER="${VALIDATOR_SSH_USER:-root}"
DEPLOY_PATH="${DEPLOY_PATH:-/home/deploy/metal.freedom-yield.com}"
# DEPLOY_PATH is interpolated into the remote commands: allow only plain paths.
[[ "$DEPLOY_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || die 2 "DEPLOY_PATH must be an absolute plain path: $DEPLOY_PATH"
[[ "$VALIDATOR_SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die 2 "VALIDATOR_SSH_USER looks invalid"

# The ONLY two commands run on the host, both read-only: a tar to stdout, and
# sha256sum over the same files (hashes + names, no contents).
REMOTE_CMD="tar -C ${CONFIG_PARENT} -cf - ${CONFIG_NAME} -C ${DEPLOY_PATH} .env"
REMOTE_HASH_CMD="cd ${CONFIG_PARENT} && find ${CONFIG_NAME} ! -type d -exec sha256sum {} + && cd ${DEPLOY_PATH} && sha256sum .env"

# host_run <cmd> — `-n`: ssh never reads this script's stdin.
host_run() {
	ssh -n -o BatchMode=yes -o IdentitiesOnly=yes -i "$VALIDATOR_SSH_KEY" \
		"${VALIDATOR_SSH_USER}@${VALIDATOR_HOST}" "$1"
}

echo "Recipient: $RECIPIENT (ssh-ed25519, age tag $RECIPIENT_TAG)" >&2
echo "Host commands (read-only): $REMOTE_CMD" >&2
echo "                           $REMOTE_HASH_CMD" >&2
echo "[1] Listing what the host would send (names only)…" >&2
if ! EXPECTED_NAMES="$(host_run "$REMOTE_CMD" | tar -tf -)"; then
	die 3 "could not list the host's config stream (ssh or tar failed)"
fi
[ -n "$EXPECTED_NAMES" ] || die 3 "host stream listed no entries"
EXPECTED_SORTED="$(LC_ALL=C sort <<<"$EXPECTED_NAMES")"
sed 's/^/  /' <<<"$EXPECTED_SORTED"
check_required "$EXPECTED_SORTED" || die 3 "host stream is missing required entries"

if [ "$MODE" = "dry-run" ]; then
	echo "(dry-run: $(grep -c . <<<"$EXPECTED_SORTED") entries would be encrypted; nothing written)"
	exit 0
fi

# ---- backup ----------------------------------------------------------------
command -v age >/dev/null 2>&1 || die 2 "age not found (brew install age)"
OUT_DIR="${BACKUP_OUT_DIR:-$HOME}"
DROPBOX_DIR="${BACKUP_DROPBOX_DIR:-$HOME/Dropbox/metal-validator-backup}"
STAMP="$(date -u +%Y%m%d)"
OUT="${OUT_DIR}/fy-host-config-backup-${STAMP}.tar.age"
MANIFEST="${OUT}.manifest.age"
PARTIAL="${OUT}.partial"
[ -d "$OUT_DIR" ] || die 2 "BACKUP_OUT_DIR not found: $OUT_DIR"
for f in "$OUT" "$PARTIAL" "$MANIFEST"; do
	[ ! -e "$f" ] || die 2 "already exists, refusing to overwrite: $f (move it aside first)"
done

# Side channel of the stream: fifos (no data at rest), the name list and the
# byte count. Never any file content.
SIDE="$(mktemp -d "${TMPDIR:-/tmp}/fy-hcb-run.XXXXXX")"
trap 'rm -rf "$SIDE"' EXIT
mkfifo "$SIDE/tee" "$SIDE/list"
# The plaintext manifest (hashes of possibly low-entropy files) lives ONLY
# here, mode 600, and is removed with SIDE on every exit path.
MANIFEST_PLAIN="$SIDE/manifest"

echo "[2] Streaming host config straight into age → $OUT" >&2
: >"$PARTIAL"
chmod 600 "$PARTIAL"
# count every byte, and list the names (then drain the padding, so tee never
# sees EPIPE).
tee "$SIDE/list" <"$SIDE/tee" | wc -c >"$SIDE/bytes" &
COUNT_PID=$!
{ tar -tf - ; cat >/dev/null; } <"$SIDE/list" >"$SIDE/names" &
LIST_PID=$!
STREAM_OK=1
host_run "$REMOTE_CMD" | tee "$SIDE/tee" | age -R "$RECIPIENT" -o "$PARTIAL" || STREAM_OK=0
wait "$COUNT_PID" || STREAM_OK=0
wait "$LIST_PID" || STREAM_OK=0
if [ "$STREAM_OK" != "1" ]; then
	mv -f "$PARTIAL" "${OUT}.INCOMPLETE"
	die 3 "stream or encryption failed; partial kept as ${OUT}.INCOMPLETE (not a valid backup)"
fi
mv "$PARTIAL" "$OUT"
chmod 600 "$OUT"
PLAIN_BYTES="$(tr -d ' ' <"$SIDE/bytes")"

echo "[3] Verifying without decrypting: names in flight, age header, size, host sha256 manifest" >&2
VERIFY_OK=1
ACTUAL_SORTED="$(LC_ALL=C sort <"$SIDE/names")"
# a. names of the stream that was actually encrypted
if [ "$ACTUAL_SORTED" != "$EXPECTED_SORTED" ]; then
	echo "  name set of the encrypted stream differs from the host listing:" >&2
	diff <(echo "$EXPECTED_SORTED") <(echo "$ACTUAL_SORTED") | sed 's/^/    /' >&2 || true
	VERIFY_OK=0
fi
check_required "$ACTUAL_SORTED" || VERIFY_OK=0
# b + c. age header addressed to exactly our recipient; exact size
check_age_file "$OUT" "$RECIPIENT_TAG" "$PLAIN_BYTES" || VERIFY_OK=0
# d. host sha256 manifest: hashes and names only
if HASHES="$(host_run "$REMOTE_HASH_CMD")"; then
	BAD_LINES="$(grep -vcE '^[0-9a-f]{64}  [^[:cntrl:]]+$' <<<"$HASHES" || true)"
	if [ "$BAD_LINES" != "0" ]; then
		echo "  host hash output has $BAD_LINES line(s) that are not '<sha256>  <name>' — not stored" >&2
		VERIFY_OK=0
	else
		HASH_FILES="$(sed 's/^[0-9a-f]*  //' <<<"$HASHES" | LC_ALL=C sort)"
		ARCHIVE_FILES="$(grep -v '/$' <<<"$ACTUAL_SORTED" || true)"
		if [ "$HASH_FILES" != "$ARCHIVE_FILES" ]; then
			echo "  host sha256 file set differs from the archive's files:" >&2
			diff <(echo "$ARCHIVE_FILES") <(echo "$HASH_FILES") | sed 's/^/    /' >&2 || true
			VERIFY_OK=0
		else
			LC_ALL=C sort -k2 <<<"$HASHES" >"$MANIFEST_PLAIN"
			chmod 600 "$MANIFEST_PLAIN"
		fi
	fi
else
	echo "  could not fetch the host sha256 list" >&2
	VERIFY_OK=0
fi

# e. only after every check above: encrypt the manifest to the same
#    recipient and check its header + size the same way.
if [ "$VERIFY_OK" = "1" ]; then
	: >"${MANIFEST}.partial"
	chmod 600 "${MANIFEST}.partial"
	if age -R "$RECIPIENT" -o "${MANIFEST}.partial" <"$MANIFEST_PLAIN" \
		&& check_age_file "${MANIFEST}.partial" "$RECIPIENT_TAG" "$(wc -c <"$MANIFEST_PLAIN" | tr -d ' ')"; then
		mv "${MANIFEST}.partial" "$MANIFEST"
		chmod 600 "$MANIFEST"
	else
		echo "  encrypting the manifest failed" >&2
		rm -f "${MANIFEST}.partial"
		VERIFY_OK=0
	fi
fi
rm -f "$MANIFEST_PLAIN"

if [ "$VERIFY_OK" != "1" ]; then
	mv "$OUT" "${OUT}.VERIFY-FAILED"
	[ ! -e "$MANIFEST" ] || mv "$MANIFEST" "${MANIFEST}.VERIFY-FAILED"
	echo "✗ VERIFY FAILED — kept as ${OUT}.VERIFY-FAILED, NOT copied to Dropbox. Do not trust it." >&2
	exit 1
fi
SHA="$(sha256_of "$OUT")"
MSHA="$(sha256_of "$MANIFEST")"
echo "✓ verify PASS ($(grep -c . <<<"$ACTUAL_SORTED") entries, $PLAIN_BYTES plaintext bytes, 1 recipient)"

echo "[4] Off-site copy → $DROPBOX_DIR" >&2
[ -d "$DROPBOX_DIR" ] || die 4 "Dropbox dir not found: $DROPBOX_DIR — local backup is verified at $OUT, copy it manually"
DEST="${DROPBOX_DIR}/$(basename "$OUT")"
MDEST="${DROPBOX_DIR}/$(basename "$MANIFEST")"
for f in "$DEST" "$MDEST"; do
	[ ! -e "$f" ] || die 4 "already exists in Dropbox, not overwritten: $f"
done
cp "$OUT" "$DEST"
chmod 600 "$DEST"
cp "$MANIFEST" "$MDEST"
chmod 600 "$MDEST"
[ "$(sha256_of "$DEST")" = "$SHA" ] || die 4 "Dropbox copy sha256 mismatch: $DEST"
[ "$(sha256_of "$MDEST")" = "$MSHA" ] || die 4 "Dropbox manifest copy sha256 mismatch: $MDEST"

echo
echo "✓ BACKUP DONE"
echo "  file:     $OUT"
echo "  manifest: $MANIFEST"
echo "  copy:     $DEST"
echo "  sha256:   $SHA"
echo "  restore (operator, disaster only): bash scripts/operator-local/backup-host-config.sh --restore-help"
