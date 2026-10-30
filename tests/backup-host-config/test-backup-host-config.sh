#!/usr/bin/env bash
# tests/backup-host-config/test-backup-host-config.sh
#
# CHAIN: none — no host and no chain is contacted.
#
# scripts/operator-local/backup-host-config.sh — age-encrypted, passphrase-free
# off-host backup of the validator host's untracked config. Hermetic:
#   - ssh is a stub that serves a fixture tree through the real tar (the
#     read-only tar command) and real sha256 hashes (the read-only sha256sum
#     command), and refuses any other remote command;
#   - age is a stub that writes a spec-shaped age v1 header (ssh-ed25519
#     stanza, tag computed from the given public key) and a scrambled payload
#     of the exact age size, logs its argv and refuses passphrase/decrypt
#     modes. When the real `age` is installed, the `realage` case delegates to
#     it and decrypts the result with the throwaway private key;
#   - tar / cp / mv / shasum are argv-logging wrappers around the real ones.
# HOME and TMPDIR point into a watched directory that a background poller
# scans for plaintext while the script runs. All keys are throwaway keys
# generated here; no real key is read.
#
# Claims proven here, each with a mutant below that breaks it and must make
# its case fail (the "break-the-property" section at the bottom):
#   C1  no plaintext file is ever created                (poller + post-scan)
#   C2  no passphrase prompt, ever; stdin is never needed (stdin closed)
#   C3  age is run with -R <recipient> only (never passphrase mode)
#   C4  the recipient must be one ssh-ed25519 PUBLIC key: a private key or
#       another key type is refused before any ssh
#   C5  age header: wrong tag / more than one stanza -> verify fails
#   C6  size sanity: a truncated file -> verify fails
#   C7  names of the encrypted stream must equal the host listing
#   C8  manifest = host sha256 hashes + names only; contents are refused, and
#       its file set must equal the archive's
#   C9  verify failure -> exit 1, files renamed *.VERIFY-FAILED, no Dropbox copy
#   C10 Dropbox copy only after all checks, and only the two .age files
#   C13 the manifest is age-encrypted to the same recipient (mode 600); its
#       plaintext (hashes of maybe low-entropy files) is never left on disk,
#       on success or failure paths
#   C11 --dry-run never runs age and writes nothing
#   C12 VALIDATOR_HOST unset -> refuse before any ssh
#
# --restore-drill (real `age`, a throwaway unencrypted key; skipped without age):
#   D1  a correct backup + manifest -> exit 0, log "matched=7/7  OK"; the key
#       is derived from the recipient path, and no .pub is needed
#   D2  a changed byte in the encrypted backup -> exit 1, "FAIL decrypt"
#   D3  a changed manifest hash -> exit 1, the file NAME is shown, no hash is
#   D4  a manifest line dropped / one extra file in the tar / empty -> exit 1
#   D5  the scratch dir never survives: OK, FAIL and a TERM mid-run
#   D6  the scratch dir is mode 700 when age writes into it
#   D7  no host is touched; only the log file appears under HOME
#   D8  the identity path reaches age only (no other tool's argv)
#   D9  symlink / ".." / absolute members -> exit 1, "FAIL unsafe-member"
#   D10 no argument -> newest dated file; missing manifest/file -> exit 2, no log
#   D11 log line shape, mode 600, no absolute path, no hash
#
# BACKUP_SCRIPT_UNDER_TEST=<path>  run the cases against another script
# BACKUP_TEST_ONLY=<case>          run one case (used by the mutation loop)

# shellcheck disable=SC2015,SC2016,SC2329  # A&&ok||bad reporters; literal perl code; functions called indirectly
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REAL_SCRIPT="$REPO/scripts/operator-local/backup-host-config.sh"
SCRIPT="${BACKUP_SCRIPT_UNDER_TEST:-$REAL_SCRIPT}"
ONLY="${BACKUP_TEST_ONLY:-}"
TMP="$(mktemp -d)"
POLL_PID=""
cleanup() { [ -n "$POLL_PID" ] && kill "$POLL_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

skip_or_fail() {
	if [ -n "${CI:-}" ]; then echo "FAIL: $1 (CI must run this suite)"; exit 1; fi
	echo "SKIP: $1"; exit 0
}
for t in tar shasum perl ssh-keygen mkfifo; do
	command -v "$t" >/dev/null 2>&1 || skip_or_fail "$t not available"
done
REAL_AGE="$(command -v age 2>/dev/null || true)"

PASS=0; FAIL=0; FAILURES=()
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1 ($2)"); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected='$2' actual='$3'"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing '$2'" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "unexpected '$2'" ;; *) ok "$1" ;; esac; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

MARKER="PLAINTEXT-MARKER-c0nf1g"
DEPLOY="/srv/example-deploy"
EXPECTED_REMOTE="tar -C /etc -cf - freedom-yield -C ${DEPLOY} .env"
EXPECTED_HASH="cd /etc && find freedom-yield ! -type d -exec sha256sum {} + && cd ${DEPLOY} && sha256sum .env"

# --- throwaway keys -------------------------------------------------------------
KEYS="$TMP/keys"; mkdir -p "$KEYS"
ssh-keygen -q -t ed25519 -N '' -C test -f "$KEYS/id_ed25519" >/dev/null
ssh-keygen -q -t rsa -b 2048 -N '' -C test -f "$KEYS/id_rsa" >/dev/null
ssh-keygen -q -t ecdsa -N '' -C test -f "$KEYS/id_ecdsa" >/dev/null
cat "$KEYS/id_ed25519.pub" "$KEYS/id_ed25519.pub" >"$KEYS/two.pub"
printf 'ssh-ed25519 %s test\n' "$(awk '{print $2}' "$KEYS/id_rsa.pub")" >"$KEYS/relabelled-rsa.pub"
PUB="$KEYS/id_ed25519.pub"

# --- fixture host trees -----------------------------------------------------
mkfix() { # $1 root, $2 extra file name (optional)
	mkdir -p "$1/etc/freedom-yield" "$1/deploy"
	for f in web-host ntfy-topic calendar-token wallet-addresses.json watch-list.json validator-name; do
		printf '%s %s\n' "$MARKER" "$f" >"$1/etc/freedom-yield/$f"
	done
	printf 'OPS_BASIC_AUTH_HASH=%s\n' "$MARKER" >"$1/deploy/.env"
	[ -z "${2:-}" ] || printf '%s\n' "$MARKER" >"$1/etc/freedom-yield/$2"
}
mkfix "$TMP/host"
mkfix "$TMP/host-alt" "appeared-later"

# --- stubs / wrappers ---------------------------------------------------------
BIN="$TMP/bin"; LOGS="$TMP/logs"; mkdir -p "$BIN" "$LOGS"
CALLS="$LOGS/calls.log"   # one line per process: name<TAB>argv (ordered)
for c in tar cp mv shasum; do
	real="$(command -v "$c")"
	cat >"$BIN/$c" <<STUB
#!/usr/bin/env bash
printf '%s\t%s\n' "$c" "\$*" >>"\$STUB_CALLS"
exec "$real" "\$@"
STUB
	chmod +x "$BIN/$c"
done
REAL_TAR="$(command -v tar)"
REAL_SHASUM="$(command -v shasum)"
cat >"$BIN/ssh" <<STUB
#!/usr/bin/env bash
printf 'ssh\t%s\n' "\$*" >>"\$STUB_CALLS"
n=0; [ -s "\$STUB_SSH_COUNTER" ] && n=\$(cat "\$STUB_SSH_COUNTER"); n=\$((n + 1))
printf '%s' "\$n" >"\$STUB_SSH_COUNTER"
case " \$* " in *" -n "*) ;; *) cat >/dev/null ;; esac
last="\${!#}"
root="\$STUB_FIX"
case " \${STUB_SSH_ALT_CALLS:-} " in *" \$n "*) root="\$STUB_FIX_ALT" ;; esac
if [ "\$last" = "\$STUB_EXPECTED_HASH" ]; then
	out="\$(cd "\$root/etc" && find freedom-yield ! -type d -exec "$REAL_SHASUM" -a 256 {} + && cd "\$root/deploy" && "$REAL_SHASUM" -a 256 .env)"
	[ "\${STUB_HASH_DROP:-}" = 1 ] && out="\$(printf '%s\n' "\$out" | sed '\$d')"
	printf '%s\n' "\$out"
	[ "\${STUB_HASH_LEAK:-}" = 1 ] && printf 'OPS_BASIC_AUTH_HASH=%s\n' "\$STUB_MARKER"
	exit 0
fi
[ "\$last" = "\$STUB_EXPECTED_REMOTE" ] || { echo "stub ssh: unexpected remote command: \$last" >&2; exit 97; }
if [ "\$n" = "\${STUB_SSH_FAIL_CALL:-0}" ]; then
	"$REAL_TAR" -C "\$root/etc" -cf - freedom-yield | head -c 700; exit 255
fi
"$REAL_TAR" -C "\$root/etc" -cf - freedom-yield -C "\$root/deploy" .env
rc=\$?
# Hold the stream open until the poller has finished 3 more full passes, so a
# plaintext copy taken from this stream exists on disk while the poller looks,
# however fast the machine is (C1 must not depend on timing: on a fast Linux
# runner the mutant's copy lived shorter than one 10 ms poll). No passes in
# time -> recorded, and no_plaintext_anywhere fails loudly.
if [ -n "\${STUB_POLL_TICKS:-}" ]; then
	t0=\$(wc -c <"\$STUB_POLL_TICKS"); i=0
	while [ "\$(wc -c <"\$STUB_POLL_TICKS")" -lt \$((t0 + 3)) ]; do
		i=\$((i + 1)); [ \$i -gt 500 ] && { echo "ssh call \$n" >>"\$STUB_POLL_TIMEOUT"; break; }
		sleep 0.01
	done
fi
exit \$rc
STUB
chmod +x "$BIN/ssh"
# age stub: `-R <pubkey> -o <out>` only. Header per the age v1 spec, payload
# = 16-byte nonce + per-64KiB-chunk (scrambled bytes + 16-byte tag).
cat >"$BIN/age" <<STUB
#!/usr/bin/env bash
printf 'age\t%s\n' "\$*" >>"\$STUB_CALLS"
if [ "\${STUB_AGE_REAL:-}" = 1 ]; then exec "$REAL_AGE" "\$@"; fi
[ \$# = 4 ] && [ "\$1" = -R ] && [ "\$3" = -o ] || { echo "stub age: refusing argv: \$*" >&2; exit 97; }
exec perl -MMIME::Base64 -MDigest::SHA=sha256 -e '
	my (\$pub, \$out) = @ARGV;
	open(my \$p, "<", \$pub) or die; my \$l = <\$p>; my (undef, \$b64) = split /\s+/, \$l;
	my \$tag = encode_base64(substr(sha256(decode_base64(\$b64)), 0, 4), ""); \$tag =~ s/=+\$//;
	\$tag = "AAAAAA" if \$ENV{STUB_AGE_BADTAG};
	my \$r = "A" x 43;
	open(my \$o, ">:raw", \$out) or die;
	print \$o "age-encryption.org/v1\n-> ssh-ed25519 \$tag \$r\n\$r\n";
	print \$o "-> X25519 \$r\n\$r\n" if \$ENV{STUB_AGE_TWO};
	print \$o "--- \$r\n", "N" x 16;
	binmode STDIN; my (\$buf, \$any, \$short) = ("", 0, \$ENV{STUB_AGE_SHORT});
	while (1) { my \$k = read(STDIN, \$buf, 65536); last unless \$k; \$any = 1;
		(my \$x = \$buf) =~ tr/\x00-\xff/\x80-\xff\x00-\x7f/; print \$o \$x, "T" x 16; }
	print \$o "T" x 16 unless \$any;
	close \$o;
	truncate(\$out, (-s \$out) - 1) if \$short;
' "\$2" "\$4"
STUB
chmod +x "$BIN/age"

# --- runner -------------------------------------------------------------------
RC=0; OUT=""; ERR=""
reset_env() {
	rm -rf "${TMP:?}/home" "${LOGS:?}"/*; mkdir -p "$TMP/home/tmp" "$TMP/home/.ssh" "$TMP/home/Dropbox/metal-validator-backup"
	: >"$TMP/home/.ssh/id_test"; : >"$CALLS"; : >"$LOGS/poll-hits"
}
start_poller() {
	: >"$LOGS/poll-ticks"
	( while :; do grep -D skip -rlF "$MARKER" "$TMP/home" >>"$LOGS/poll-hits" 2>/dev/null; printf . >>"$LOGS/poll-ticks"; sleep 0.01; done ) &
	POLL_PID=$!
}
stop_poller() { kill "$POLL_PID" 2>/dev/null; wait "$POLL_PID" 2>/dev/null; POLL_PID=""; }
# run_case [args...] — stdin CLOSED: any read/prompt fails loudly.
run_case() {
	start_poller
	OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" TMPDIR="$TMP/home/tmp" \
		VALIDATOR_HOST="${T_HOST-validator.example.invalid}" VALIDATOR_SSH_KEY="$TMP/home/.ssh/id_test" DEPLOY_PATH="$DEPLOY" \
		BACKUP_RECIPIENT_PUBKEY="${T_PUB-$PUB}" \
		STUB_CALLS="$CALLS" STUB_SSH_COUNTER="$LOGS/ssh-count" STUB_EXPECTED_REMOTE="$EXPECTED_REMOTE" \
		STUB_EXPECTED_HASH="$EXPECTED_HASH" STUB_MARKER="$MARKER" \
		STUB_FIX="$TMP/host" STUB_FIX_ALT="$TMP/host-alt" STUB_SSH_ALT_CALLS="${T_ALT_CALLS:-}" \
		STUB_SSH_FAIL_CALL="${T_FAIL_CALL:-0}" STUB_HASH_DROP="${T_HASH_DROP:-}" STUB_HASH_LEAK="${T_HASH_LEAK:-}" \
		STUB_AGE_BADTAG="${T_AGE_BADTAG:-}" STUB_AGE_TWO="${T_AGE_TWO:-}" STUB_AGE_SHORT="${T_AGE_SHORT:-}" \
		STUB_AGE_REAL="${T_AGE_REAL:-}" STUB_POLL_TICKS="$LOGS/poll-ticks" STUB_POLL_TIMEOUT="$LOGS/poll-timeout" \
		bash "$SCRIPT" "$@" 2>"$LOGS/stderr" 0<&-)"
	RC=$?
	ERR="$(cat "$LOGS/stderr")"
	stop_poller
	rm -f "$LOGS/ssh-count"
}
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
out_files() { find "$TMP/home" -maxdepth 1 -name 'fy-host-config-backup-*' | sort; }
dropbox_files() { find "$TMP/home/Dropbox/metal-validator-backup" -type f | sort; }
calls_of() { grep -c "^$1	" "$CALLS" || true; }
no_plaintext_anywhere() { # $1 label
	assert_eq "$1: poller ran full passes while each stream was held open" "" "$(cat "$LOGS/poll-timeout" 2>/dev/null)"
	assert_eq "$1: poller saw no plaintext during the run" "" "$(sort -u "$LOGS/poll-hits")"
	assert_eq "$1: no plaintext left under HOME/TMPDIR" "" "$(grep -D skip -rlF "$MARKER" "$TMP/home" 2>/dev/null)"
}
no_prompt() { # $1 label
	assert_not_contains "$1: no passphrase prompt" "assphrase:" "$OUT$ERR"
	assert_not_contains "$1: never read the (closed) stdin" "Bad file descriptor" "$ERR"
}
TODAY="$(date -u +%Y%m%d)"
BK="$TMP/home/fy-host-config-backup-${TODAY}.tar.age"
MF="${BK}.manifest.age"
ENV_HASH="$(shasum -a 256 "$TMP/host/deploy/.env" | awk '{print $1}')"
# stub_decrypt <file> — inverse of the age stub (test-only format), prints
# the plaintext to stdout.
stub_decrypt() {
	perl -e 'open(my $h, "<:raw", $ARGV[0]) or exit 1; local $/; my $d = <$h>;
		$d =~ s/\A.*?\n--- [^\n]*\n//s or exit 1; $d = substr($d, 16);
		while (length $d > 16) { my $c = substr($d, 0, 65536 + 16, ""); $c = substr($c, 0, -16);
			$c =~ tr/\x80-\xff\x00-\x7f/\x00-\xff/; print $c }' "$1"
}
no_plain_manifest() { # $1 label — the .env hash must not be readable anywhere
	assert_eq "$1: no plaintext manifest left on disk" "" "$(grep -D skip -rlF "$ENV_HASH" "$TMP/home" 2>/dev/null)"
	assert_eq "$1: no *.manifest file left" "" "$(find "$TMP/home" -name '*.manifest' 2>/dev/null)"
}
# verify_fail_common <label> — the shape every verify failure must have (C9)
verify_fail_common() {
	assert_eq "$1: exit 1" "1" "$RC"
	[ -f "${BK}.VERIFY-FAILED" ] && ok "$1: file kept, flagged .VERIFY-FAILED" || bad "$1: file kept, flagged .VERIFY-FAILED" "$(out_files)"
	[ ! -e "$BK" ] && ok "$1: no unflagged .tar.age left" || bad "$1: no unflagged .tar.age left" "exists"
	[ ! -e "$MF" ] && ok "$1: no unflagged manifest left" || bad "$1: no unflagged manifest left" "exists"
	assert_eq "$1: nothing copied to Dropbox" "" "$(dropbox_files)"
	assert_contains "$1: loud message" "VERIFY FAILED" "$ERR"
	no_plaintext_anywhere "$1"
	no_plain_manifest "$1"
}

# --- cases ----------------------------------------------------------------------
if want happy; then
	echo "== happy path (C1 C2 C3 C8 C10) =="
	reset_env
	run_case
	assert_eq "happy: exit 0" "0" "$RC"
	[ -f "$BK" ] && ok "happy: backup file written" || bad "happy: backup file written" "missing $BK; $ERR"
	assert_eq "happy: backup mode 600" "600" "$(mode_of "$BK")"
	assert_eq "happy: manifest mode 600" "600" "$(mode_of "$MF")"
	DB="$TMP/home/Dropbox/metal-validator-backup/$(basename "$BK")"
	SHA="$(shasum -a 256 "$BK" 2>/dev/null | awk '{print $1}')"
	assert_eq "happy: Dropbox copy identical" "$SHA" "$(shasum -a 256 "$DB" 2>/dev/null | awk '{print $1}')"
	assert_eq "happy: Dropbox manifest identical" "$(shasum -a 256 "$MF" 2>/dev/null | awk '{print $1}')" \
		"$(shasum -a 256 "$DB.manifest.age" 2>/dev/null | awk '{print $1}')"
	assert_eq "happy: Dropbox gets only the two .age files" "$(basename "$BK") $(basename "$MF")" \
		"$(dropbox_files | xargs -n1 basename 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
	assert_eq "happy: manifest is an age v1 file" "age-encryption.org/v1" "$(head -1 "$MF" 2>/dev/null)"
	no_plain_manifest "happy"
	assert_contains "happy: sha256 printed" "sha256:   $SHA" "$OUT"
	no_plaintext_anywhere "happy"
	no_prompt "happy"
	assert_eq "happy: age argv is exactly -R <recipient> -o <partial> (backup, manifest)" \
		"-R $PUB -o ${BK}.partial|-R $PUB -o ${MF}.partial" "$(grep '^age	' "$CALLS" | cut -f2 | tr '\n' '|' | sed 's/|$//')"
	MPLAIN="$(stub_decrypt "$MF")"
	assert_eq "happy: every ssh call ran one of the two read-only commands" "" \
		"$(grep '^ssh' "$CALLS" | grep -vF -- "$EXPECTED_REMOTE" | grep -vF -- "$EXPECTED_HASH")"
	assert_eq "happy: manifest has 7 lines" "7" "$(grep -c . <<<"$MPLAIN")"
	assert_eq "happy: every manifest line is '<sha256>  <name>'" "" "$(grep -vE '^[0-9a-f]{64}  [^ ]+$' <<<"$MPLAIN")"
	assert_not_contains "happy: manifest carries no file contents" "$MARKER" "$MPLAIN"
	assert_eq "happy: manifest hash of .env is the real one" "$ENV_HASH  .env" "$(grep '  \.env$' <<<"$MPLAIN")"
	cp_line="$(grep -n '^cp	' "$CALLS" | head -1 | cut -d: -f1)"
	last_ssh="$(grep -n '^ssh	' "$CALLS" | tail -1 | cut -d: -f1)"
	[ -n "$cp_line" ] && [ -n "$last_ssh" ] && [ "$last_ssh" -lt "$cp_line" ] \
		&& ok "happy: Dropbox copy only after the manifest fetch" \
		|| bad "happy: Dropbox copy only after the manifest fetch" "ssh@${last_ssh:-none} cp@${cp_line:-none}"
	: >"$CALLS"
	run_case --restore-help
	assert_eq "restore-help: exit 0" "0" "$RC"
	assert_contains "restore-help: shows the age decrypt with the private key" "age -d -i $TMP/keys/id_ed25519 " "$OUT"
	assert_contains "restore-help: shows the manifest decrypt" ".tar.age.manifest.age" "$OUT"
	assert_eq "restore-help: contacts nothing" "0" "$(calls_of ssh)"
	assert_contains "restore-help: points at the drill" "--restore-drill" "$OUT"
fi

if want realage; then
	echo "== real age: the file decrypts with the throwaway private key =="
	if [ -z "$REAL_AGE" ]; then
		echo "  SKIP  realage (age not installed; the stub cases still run)"
	else
		reset_env
		T_AGE_REAL=1 run_case
		assert_eq "realage: exit 0" "0" "$RC"
		names="$("$REAL_AGE" -d -i "$KEYS/id_ed25519" "$BK" 2>/dev/null | tar -tf - | LC_ALL=C sort | tr '\n' ' ')"
		assert_contains "realage: decrypts and lists .env" ".env " "$names"
		assert_contains "realage: decrypts and lists the config entries" "freedom-yield/ntfy-topic " "$names"
		assert_eq "realage: manifest decrypts, .env hash is the real one" "$ENV_HASH  .env" \
			"$("$REAL_AGE" -d -i "$KEYS/id_ed25519" "$MF" 2>/dev/null | grep '  \.env$')"
		no_plain_manifest "realage"
		no_plaintext_anywhere "realage"
	fi
fi

if want recipient; then
	echo "== recipient validation (C4) =="
	for k in "private:$KEYS/id_ed25519" "rsa:$KEYS/id_rsa.pub" "ecdsa:$KEYS/id_ecdsa.pub" \
		"two-keys:$KEYS/two.pub" "relabelled-rsa:$KEYS/relabelled-rsa.pub" "missing:$KEYS/none.pub"; do
		label="${k%%:*}"; reset_env
		T_PUB="${k#*:}" run_case
		assert_eq "$label: exit 2" "2" "$RC"
		assert_eq "$label: ssh never ran" "0" "$(calls_of ssh)"
		assert_eq "$label: nothing written" "" "$(out_files)"
	done
fi

if want wrongtag; then
	echo "== age header addressed to someone else (C5 C9) =="
	reset_env
	T_AGE_BADTAG=1 run_case
	verify_fail_common "wrongtag"
	assert_contains "wrongtag: names the tag mismatch" "stanza tag" "$ERR"
fi

if want tworecip; then
	echo "== two recipient stanzas (C5) =="
	reset_env
	T_AGE_TWO=1 run_case
	verify_fail_common "tworecip"
fi

if want short; then
	echo "== truncated file (C6) =="
	reset_env
	T_AGE_SHORT=1 run_case
	verify_fail_common "short"
fi

if want namediff; then
	echo "== encrypted stream names differ from the host listing (C7) =="
	reset_env
	T_ALT_CALLS="2 3" run_case
	verify_fail_common "namediff"
	assert_contains "namediff: diff names the extra entry" "appeared-later" "$ERR"
fi

if want hashdrop; then
	echo "== manifest file set differs from the archive (C8) =="
	reset_env
	T_HASH_DROP=1 run_case
	verify_fail_common "hashdrop"
fi

if want hashleak; then
	echo "== host hash output carries content (C8) =="
	reset_env
	T_HASH_LEAK=1 run_case
	verify_fail_common "hashleak"
	assert_contains "hashleak: refused as not '<sha256>  <name>'" "line(s) that are not" "$ERR"
	assert_eq "hashleak: content never stored anywhere" "" "$(grep -D skip -rlF "$MARKER" "$TMP/home" 2>/dev/null)"
fi

if want streamfail; then
	echo "== host stream dies mid-way =="
	reset_env
	T_FAIL_CALL=2 run_case
	assert_eq "streamfail: exit 3" "3" "$RC"
	[ -f "${BK}.INCOMPLETE" ] && ok "streamfail: partial kept as .INCOMPLETE" || bad "streamfail: partial kept as .INCOMPLETE" "$(out_files)"
	assert_eq "streamfail: nothing copied to Dropbox" "" "$(dropbox_files)"
	no_plaintext_anywhere "streamfail"
	no_plain_manifest "streamfail"
fi

if want dryrun; then
	echo "== --dry-run (C11) =="
	reset_env
	run_case --dry-run
	assert_eq "dryrun: exit 0" "0" "$RC"
	no_prompt "dryrun"
	assert_eq "dryrun: age never ran" "0" "$(calls_of age)"
	assert_eq "dryrun: nothing written" "" "$(out_files)"
	assert_contains "dryrun: lists .env" ".env" "$OUT"
	assert_contains "dryrun: lists a config entry" "freedom-yield/watch-list.json" "$OUT"
	assert_not_contains "dryrun: prints names, never contents" "$MARKER" "$OUT$ERR"
fi

if want nohost; then
	echo "== VALIDATOR_HOST unset (C12) =="
	reset_env
	T_HOST="" run_case
	assert_eq "nohost: exit 2" "2" "$RC"
	assert_contains "nohost: names the variable" "VALIDATOR_HOST" "$ERR"
	assert_eq "nohost: ssh never ran" "0" "$(calls_of ssh)"
fi

# ===== --restore-drill (D1..D11) ===================================================
# Real `age` and a throwaway unencrypted ssh-ed25519 identity (no passphrase, so
# nothing is typed). The drill makes plaintext by design, so run_case (whose
# poller hunts plaintext under HOME) is NOT used: TMPDIR is outside HOME, and
# the checks are "nothing is left" instead.
DRILL_LOGFILE="$TMP/home/fy-restore-drill.log"
DS="$TMP/dscratch"; DTMP="$TMP/drilltmp"; DBIN="$TMP/dbin"; OUTSIDE="$TMP/outside"
DBK="$TMP/home/fy-host-config-backup-20260101.tar.age"
KEYPATH="$KEYS/id_ed25519"
mkdir -p "$DS" "$DTMP" "$DBIN" "$OUTSIDE"
# argv-logging wrappers for every tool the drill could hand the key to
for c in tar cp mv shasum cat grep perl head sed awk cut sort comm find tr wc rm chmod mkdir basename date mktemp stat ls; do
	real="$(command -v "$c" 2>/dev/null)" || continue
	cat >"$DBIN/$c" <<STUB
#!/usr/bin/env bash
printf '%s\t%s\n' "$c" "\$*" >>"\$STUB_CALLS"
exec "$real" "\$@"
STUB
	chmod +x "$DBIN/$c"
done
cp "$BIN/ssh" "$DBIN/ssh"
# age wrapper: logs argv, records the mode of the -o parent dir, can hold (TERM test)
cat >"$DBIN/age" <<STUB
#!/usr/bin/env bash
printf 'age\t%s\n' "\$*" >>"\$STUB_CALLS"
prev=""; o=""
for a in "\$@"; do [ "\$prev" = -o ] && o="\$a"; prev="\$a"; done
if [ -n "\$o" ]; then d="\$(dirname "\$o")"; { stat -c %a "\$d" 2>/dev/null || stat -f %Lp "\$d"; } >>"\$STUB_WORKMODE"; fi
if [ -n "\${STUB_AGE_HOLD:-}" ]; then : >"\$STUB_AGE_HOLD"; sleep 6; exit 1; fi
exec "$REAL_AGE" "\$@"
STUB
chmod +x "$DBIN/age"

build_denv() {
	DENV=(env -i PATH="$DBIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" TMPDIR="$DTMP"
		BACKUP_RECIPIENT_PUBKEY="${T_PUB-$PUB}"
		STUB_CALLS="$CALLS" STUB_SSH_COUNTER="$LOGS/ssh-count" STUB_EXPECTED_REMOTE=none STUB_EXPECTED_HASH=none
		STUB_WORKMODE="$LOGS/workmode" STUB_AGE_HOLD="${T_HOLD:-}")
	[ -z "${T_IDENT:-}" ] || DENV+=(BACKUP_IDENTITY="$T_IDENT")
}
drill_run() { # args to the script; stdin closed
	build_denv
	OUT="$("${DENV[@]}" bash "$SCRIPT" "$@" 2>"$LOGS/stderr" 0<&-)"
	RC=$?
	ERR="$(cat "$LOGS/stderr")"
}
drill_reset() { reset_env; rm -rf "$DTMP" "$OUTSIDE" "$DS"; mkdir -p "$DTMP" "$OUTSIDE" "$DS"; }
drill_left() { find "$DTMP" -mindepth 1 -maxdepth 1 -name 'fy-hcb-drill.*' | sort; }
last_log() { tail -1 "$DRILL_LOGFILE" 2>/dev/null; }
log_status() { last_log | sed -E 's/^.*matched=[0-9]+\/[0-9]+  //'; }
enc() { "$REAL_AGE" -R "$PUB" -o "$2" <"$1"; }
fx_manifest() { # $1 root of a fixture host tree, $2 out
	( cd "$1/etc" && find freedom-yield ! -type d -exec shasum -a 256 {} + && cd "$1/deploy" && shasum -a 256 .env ) | LC_ALL=C sort -k2 >"$2"
}
std_fixture() { # builds $DS/backup.tar and $DS/manifest.txt from the fixture host
	tar -C "$TMP/host/etc" -cf "$DS/backup.tar" freedom-yield -C "$TMP/host/deploy" .env
	fx_manifest "$TMP/host" "$DS/manifest.txt"
}
put_pair() { # $1 yyyymmdd — encrypts $DS/backup.tar and $DS/manifest.txt into HOME
	enc "$DS/backup.tar" "$TMP/home/fy-host-config-backup-$1.tar.age" \
		&& enc "$DS/manifest.txt" "$TMP/home/fy-host-config-backup-$1.tar.age.manifest.age"
}
drill_fail_common() { # <label> <reason>
	assert_eq "$1: exit 1" "1" "$RC"
	assert_eq "$1: log says FAIL $2" "FAIL $2" "$(log_status)"
	assert_eq "$1: no scratch dir left" "" "$(drill_left)"
}
DRILL_OK=1
if [ -z "$REAL_AGE" ]; then
	DRILL_OK=0
	if [ -n "${CI:-}" ]; then echo "FAIL: age not available (CI must run the drill cases)"; exit 1; fi
	echo "SKIP: restore-drill cases (age not installed)"
fi

if [ "$DRILL_OK" = 1 ] && want drillok; then
	echo "== restore drill: a correct backup (D1) =="
	drill_reset; std_fixture; put_pair 20260101
	drill_run --restore-drill "$DBK"
	assert_eq "drillok: exit 0" "0" "$RC"
	assert_eq "drillok: log is one line" "1" "$(grep -c . "$DRILL_LOGFILE" 2>/dev/null)"
	assert_contains "drillok: log says matched=7/7  OK" "matched=7/7  OK" "$(last_log)"
	assert_eq "drillok: age argv is exactly -d -i <identity> -o <work> <file> (manifest, backup)" \
		"-d -i $KEYPATH ${DBK}.manifest.age|-d -i $KEYPATH $DBK" \
		"$(grep '^age	' "$CALLS" | cut -f2 | sed 's/ -o [^ ]*//' | tr '\n' '|' | sed 's/|$//')"
	no_prompt "drillok"
	assert_eq "drillok: no scratch dir left" "" "$(drill_left)"
fi

if [ "$DRILL_OK" = 1 ] && want drillnopub; then
	echo "== restore drill: no .pub needed (D1) =="
	drill_reset; std_fixture; put_pair 20260101
	T_PUB="$TMP/missing.pub" T_IDENT="$KEYPATH" drill_run --restore-drill "$DBK"
	assert_eq "drillnopub: exit 0 without any .pub" "0" "$RC"
	assert_contains "drillnopub: log says OK" "matched=7/7  OK" "$(last_log)"
fi

if [ "$DRILL_OK" = 1 ] && want drilltamper; then
	echo "== restore drill: a changed byte in the backup (D2) =="
	drill_reset; std_fixture; put_pair 20260101
	perl -e 'open(my $h, "+<:raw", $ARGV[0]) or die; my $n = -s $ARGV[0]; seek($h, $n - 20, 0); read($h, my $b, 1);
		seek($h, $n - 20, 0); print $h chr(ord($b) ^ 0xff); close $h' "$DBK"
	drill_run --restore-drill "$DBK"
	drill_fail_common "drilltamper" "decrypt"
fi

if [ "$DRILL_OK" = 1 ] && want drillmanifest; then
	echo "== restore drill: manifest and tar disagree (D3 D4) =="
	BADH="0000000000000000000000000000000000000000000000000000000000000000"
	drill_reset; std_fixture
	REALH="$(grep '  freedom-yield/ntfy-topic$' "$DS/manifest.txt" | awk '{print $1}')"
	sed "s/^[0-9a-f]\{64\}  freedom-yield\/ntfy-topic\$/$BADH  freedom-yield\/ntfy-topic/" "$DS/manifest.txt" >"$DS/m2" && mv "$DS/m2" "$DS/manifest.txt"
	put_pair 20260101
	drill_run --restore-drill "$DBK"
	assert_eq "drillmanifest-hash: exit 1" "1" "$RC"
	assert_contains "drillmanifest-hash: the file name is shown" "freedom-yield/ntfy-topic" "$OUT$ERR"
	assert_not_contains "drillmanifest-hash: no manifest hash on screen" "$BADH" "$OUT$ERR"
	assert_not_contains "drillmanifest-hash: no real hash on screen" "$REALH" "$OUT$ERR"
	assert_eq "drillmanifest-hash: log says FAIL mismatch, 6 of 7" "matched=6/7  FAIL mismatch" "$(last_log | sed -E 's/^.*  matched=/matched=/')"
	assert_eq "drillmanifest-hash: no scratch dir left" "" "$(drill_left)"
	drill_reset; std_fixture
	grep -v 'watch-list.json' "$DS/manifest.txt" >"$DS/m2" && mv "$DS/m2" "$DS/manifest.txt"
	put_pair 20260101
	drill_run --restore-drill "$DBK"
	assert_eq "drillmanifest-drop: exit 1" "1" "$RC"
	assert_contains "drillmanifest-drop: the unlisted file is named" "freedom-yield/watch-list.json" "$OUT$ERR"
	cp -R "$TMP/host" "$DS/hostx"; printf 'x\n' >"$DS/hostx/etc/freedom-yield/extra-file"
	tar -C "$DS/hostx/etc" -cf "$DS/backup.tar" freedom-yield -C "$DS/hostx/deploy" .env
	fx_manifest "$TMP/host" "$DS/manifest.txt"
	put_pair 20260101
	drill_run --restore-drill "$DBK"
	assert_eq "drillmanifest-extra: exit 1" "1" "$RC"
	assert_contains "drillmanifest-extra: the extra file is named" "freedom-yield/extra-file" "$OUT$ERR"
	drill_reset; std_fixture
	tar -cf "$DS/backup.tar" -T /dev/null; : >"$DS/manifest.txt"
	put_pair 20260101
	drill_run --restore-drill "$DBK"
	assert_eq "drillmanifest-empty: exit 1" "1" "$RC"
	assert_eq "drillmanifest-empty: log says FAIL mismatch" "FAIL mismatch" "$(log_status)"
fi

if [ "$DRILL_OK" = 1 ] && want drillclean; then
	echo "== restore drill: the scratch dir never survives (D5) =="
	drill_reset; std_fixture; put_pair 20260101
	drill_run --restore-drill "$DBK"
	assert_eq "drillclean: OK run exit 0" "0" "$RC"
	assert_eq "drillclean: no fy-hcb-drill dir left after OK" "" "$(drill_left)"
	assert_eq "drillclean: the marker is nowhere after OK" "" "$(grep -D skip -rlF "$MARKER" "$DTMP" "$TMP/home" 2>/dev/null)"
	perl -e 'open(my $h, "+<:raw", $ARGV[0]) or die; my $n = -s $ARGV[0]; seek($h, $n - 20, 0); read($h, my $b, 1);
		seek($h, $n - 20, 0); print $h chr(ord($b) ^ 0xff); close $h' "$DBK"
	drill_run --restore-drill "$DBK"
	assert_eq "drillclean: FAIL run exit 1" "1" "$RC"
	assert_eq "drillclean: no fy-hcb-drill dir left after FAIL" "" "$(drill_left)"
	assert_eq "drillclean: the marker is nowhere after FAIL" "" "$(grep -D skip -rlF "$MARKER" "$DTMP" "$TMP/home" 2>/dev/null)"
	drill_reset; std_fixture; put_pair 20260101
	T_HOLD="$LOGS/age-started"; build_denv; unset T_HOLD
	"${DENV[@]}" bash "$SCRIPT" --restore-drill "$DBK" >"$LOGS/out" 2>"$LOGS/stderr" 0<&- &
	DPID=$!
	i=0; while [ ! -e "$LOGS/age-started" ] && [ "$i" -lt 60 ]; do sleep 2; i=$((i + 1)); done
	kill -TERM "$DPID" 2>/dev/null
	wait "$DPID"; RC=$?
	assert_eq "drillclean: TERM exit 143" "143" "$RC"
	assert_eq "drillclean: TERM leaves no fy-hcb-drill dir" "" "$(drill_left)"
	assert_eq "drillclean: TERM is logged as FAIL interrupted" "FAIL interrupted" "$(log_status)"
fi

if [ "$DRILL_OK" = 1 ] && want drillmode; then
	echo "== restore drill: scratch dir mode (D6) =="
	drill_reset; std_fixture; put_pair 20260101
	drill_run --restore-drill "$DBK"
	assert_eq "drillmode: exit 0" "0" "$RC"
	assert_eq "drillmode: age wrote into a mode 700 dir (manifest, backup)" "700 700" "$(tr '\n' ' ' <"$LOGS/workmode" | sed 's/ $//')"
fi

if [ "$DRILL_OK" = 1 ] && want drillhost; then
	echo "== restore drill: no host, no write outside the log (D7) =="
	drill_reset; std_fixture; put_pair 20260101
	find "$TMP/home" | LC_ALL=C sort >"$DS/before"
	drill_run --restore-drill "$DBK"
	find "$TMP/home" | LC_ALL=C sort >"$DS/after"
	assert_eq "drillhost: exit 0 with no VALIDATOR_* variables" "0" "$RC"
	assert_eq "drillhost: ssh never ran" "0" "$(calls_of ssh)"
	assert_eq "drillhost: only the log file appeared under HOME" "> $DRILL_LOGFILE" "$(diff "$DS/before" "$DS/after" | grep '^[<>]')"
fi

if [ "$DRILL_OK" = 1 ] && want drillkey; then
	echo "== restore drill: the identity path reaches age only (D8) =="
	drill_reset; std_fixture; put_pair 20260101
	drill_run --restore-drill "$DBK"
	assert_eq "drillkey: exit 0" "0" "$RC"
	assert_eq "drillkey: age was handed the identity twice" "2" "$(grep '^age	' "$CALLS" | grep -cF -- "-i $KEYPATH")"
	assert_eq "drillkey: no other tool's argv names the identity" "0" "$(grep -v '^age	' "$CALLS" | grep -cF -- "$KEYPATH")"
fi

if [ "$DRILL_OK" = 1 ] && want drillunsafe; then
	echo "== restore drill: unsafe archive members (D9) =="
	drill_reset; std_fixture; cp "$DS/manifest.txt" "$DS/good-manifest.txt"
	mkdir -p "$DS/sym"; printf 'a\n' >"$DS/sym/a.txt"; ln -s /etc/hostname "$DS/sym/lnk"
	tar -C "$DS/sym" -cf "$DS/backup.tar" a.txt lnk
	put_pair 20260101
	drill_run --restore-drill "$DBK"
	drill_fail_common "drillunsafe-symlink" "unsafe-member"
	drill_reset; std_fixture
	mkdir -p "$DS/dd/sub"; printf 'x\n' >"$DS/dd/evilfile"
	( cd "$DS/dd/sub" && tar -cPf "$DS/backup.tar" ../evilfile )
	put_pair 20260101
	drill_run --restore-drill "$DBK"
	drill_fail_common "drillunsafe-dotdot" "unsafe-member"
	drill_reset; std_fixture
	printf 'x\n' >"$OUTSIDE/abs.txt"
	tar -cPf "$DS/backup.tar" "$OUTSIDE/abs.txt"; rm -f "$OUTSIDE/abs.txt"
	put_pair 20260101
	drill_run --restore-drill "$DBK"
	drill_fail_common "drillunsafe-absolute" "unsafe-member"
	assert_eq "drillunsafe-absolute: nothing was created outside the scratch dir" "" "$(ls -A "$OUTSIDE")"
fi

if [ "$DRILL_OK" = 1 ] && want drillselect; then
	echo "== restore drill: which file (D10) =="
	drill_reset; std_fixture; put_pair 20260101
	perl -e 'open(my $h, "+<:raw", $ARGV[0]) or die; my $n = -s $ARGV[0]; seek($h, $n - 20, 0); read($h, my $b, 1);
		seek($h, $n - 20, 0); print $h chr(ord($b) ^ 0xff); close $h' "$DBK"
	put_pair 20260202
	cp "$TMP/home/fy-host-config-backup-20260202.tar.age" "$TMP/home/fy-host-config-backup-20260404.tar.age.VERIFY-FAILED"
	drill_run --restore-drill
	assert_eq "drillselect: no argument picks the newest (the older one is corrupt): exit 0" "0" "$RC"
	assert_contains "drillselect: the log names the newest" "fy-host-config-backup-20260202.tar.age  matched=7/7  OK" "$(last_log)"
	rm -f "$DRILL_LOGFILE"
	rm -f "${DBK}.manifest.age"; : >"$CALLS"
	drill_run --restore-drill "$DBK"
	assert_eq "drillselect: missing manifest: exit 2" "2" "$RC"
	assert_eq "drillselect: missing manifest: no log written" "" "$(ls "$DRILL_LOGFILE" 2>/dev/null)"
	assert_eq "drillselect: missing manifest: age never ran" "0" "$(calls_of age)"
	drill_run --restore-drill "$TMP/home/fy-host-config-backup-19990101.tar.age"
	assert_eq "drillselect: missing file: exit 2" "2" "$RC"
	assert_eq "drillselect: missing file: no log written" "" "$(ls "$DRILL_LOGFILE" 2>/dev/null)"
	drill_reset
	drill_run --restore-drill
	assert_eq "drillselect: nothing to drill: exit 2" "2" "$RC"
	drill_run --help
	assert_contains "drillselect: --help documents the drill" "--restore-drill" "$OUT"
	assert_contains "drillselect: --help reaches the exit codes" "99 refused" "$OUT"
fi

if [ "$DRILL_OK" = 1 ] && want drilllog; then
	echo "== restore drill: the log line (D11) =="
	drill_reset; std_fixture; put_pair 20260101
	drill_run --restore-drill "$DBK"
	perl -e 'open(my $h, "+<:raw", $ARGV[0]) or die; my $n = -s $ARGV[0]; seek($h, $n - 20, 0); read($h, my $b, 1);
		seek($h, $n - 20, 0); print $h chr(ord($b) ^ 0xff); close $h' "$DBK"
	drill_run --restore-drill "$DBK"
	assert_eq "drilllog: two runs, two lines" "2" "$(grep -c . "$DRILL_LOGFILE")"
	assert_eq "drilllog: every line has the documented shape" "0" \
		"$(grep -cvE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z  fy-host-config-backup-[0-9]{8}\.tar\.age  matched=[0-9]+/[0-9]+  (OK|FAIL( [a-z-]+)?)$' "$DRILL_LOGFILE")"
	assert_eq "drilllog: mode 600" "600" "$(mode_of "$DRILL_LOGFILE")"
	assert_eq "drilllog: no absolute path in the log" "0" "$(grep -c '/home\|/tmp\|/Users\|/var' "$DRILL_LOGFILE")"
	assert_eq "drilllog: no hash in the log" "0" "$(grep -cE '[0-9a-f]{64}' "$DRILL_LOGFILE")"
fi

# --- break-the-property ---------------------------------------------------------
# Each mutant breaks exactly one claim; re-running the named case against it
# MUST fail, for the claimed reason ($4 must be among the failures).
# Not mutated: --restore-help and --help (print text only; their assertions are the check).
if [ -z "$ONLY" ] && [ -z "${BACKUP_SCRIPT_UNDER_TEST:-}" ]; then
	echo "== break-the-property (each mutant must make its case fail) =="
	MUT="$TMP/mutants"; mkdir -p "$MUT"
	mutate() { # $1 name, $2 case, $3 perl substitution, $4 expected failing assertion
		local m="$MUT/$1.sh"
		perl -0pe "$3" "$REAL_SCRIPT" >"$m"
		if cmp -s "$m" "$REAL_SCRIPT"; then bad "mutant $1" "substitution did not apply"; return; fi
		if BACKUP_SCRIPT_UNDER_TEST="$m" BACKUP_TEST_ONLY="$2" bash "$0" >"$MUT/$1.out" 2>&1; then
			bad "mutant $1 is caught by case '$2'" "case still passed"
		elif grep -qF "FAIL  $4" "$MUT/$1.out"; then
			ok "mutant $1 is caught by '$4'"
		else
			bad "mutant $1 is caught by '$4'" "failed for another reason: $(grep -m1 'FAIL  ' "$MUT/$1.out")"
		fi
	}
	# C1: tee the plaintext stream to disk (and delete it afterwards).
	mutate plaintext-tee happy 's/host_run "\$REMOTE_CMD" \| tee "\$SIDE\/tee"/host_run "\$REMOTE_CMD" | tee "\$OUT_DIR\/stream.tar" | tee "\$SIDE\/tee"/; s/(mv "\$PARTIAL" "\$OUT"\n)/$1rm -f "\$OUT_DIR\/stream.tar"\n/' \
		'happy: poller saw no plaintext during the run'
	# C2: ask for a passphrase before encrypting.
	mutate prompts happy 's/(echo "\[2\] Streaming)/printf "Enter backup passphrase: " >&2; read -rs FYBK_PP || true\n$1/' \
		'happy: no passphrase prompt'
	# C3: age in passphrase mode.
	mutate age-passphrase-mode happy 's/age -R "\$RECIPIENT" -o "\$PARTIAL"/age -p -o "\$PARTIAL"/' \
		'happy: age argv is exactly -R <recipient> -o <partial> (backup, manifest)'
	# C4: accept whatever recipient file is given.
	mutate recipient-gate-off recipient 's/if ! RECIPIENT_TAG="\$\(recipient_tag "\$RECIPIENT"\)"; then/if ! RECIPIENT_TAG="\$(recipient_tag "\$RECIPIENT")" \&\& false; then/' \
		'private: ssh never ran'
	# C4: drop both key-type checks (label and wire-format body).
	mutate key-type-off recipient 's/\$type eq "ssh-ed25519" or do/1 or do/; s/length\(\$blob\) == 51 && /1 || /' \
		'rsa: exit 2'
	# C5: skip the tag comparison.
	mutate no-tag-check wrongtag 's/\(\$st\[0\]\[1\] \/\/ ""\) eq \$tag or do/1 or do/' \
		'wrongtag: exit 1'
	# C5: skip the stanza count.
	mutate no-stanza-count tworecip 's/\@st == 1 or do/1 or do/' \
		'tworecip: exit 1'
	# C6: skip the size check.
	mutate no-size-check short 's/\$size == \$want or do/1 or do/' \
		'short: exit 1'
	# C7: skip the name-set comparison.
	mutate no-name-compare namediff 's/if \[ "\$ACTUAL_SORTED" != "\$EXPECTED_SORTED" \]; then/if false; then/' \
		'namediff: exit 1'
	# C8: skip the manifest/archive file-set comparison.
	mutate no-manifest-set hashdrop 's/if \[ "\$HASH_FILES" != "\$ARCHIVE_FILES" \]; then/if false; then/' \
		'hashdrop: exit 1'
	# C8: skip the line-shape check (the set check behind it still refuses,
	# so the claim is the specific refusal).
	mutate no-line-shape hashleak 's/if \[ "\$BAD_LINES" != "0" \]; then/if false; then/' \
		"hashleak: refused as not '<sha256>  <name>'"
	# C9: ignore the verify verdict.
	mutate ignore-verify wrongtag 's/if \[ "\$VERIFY_OK" != "1" \]; then/if false; then/' \
		'wrongtag: file kept, flagged .VERIFY-FAILED'
	# C9: keep the failed file under its normal name.
	mutate unflagged-fail wrongtag 's/mv "\$OUT" "\$\{OUT\}\.VERIFY-FAILED"/:/' \
		'wrongtag: file kept, flagged .VERIFY-FAILED'
	# C10: copy to Dropbox before verifying.
	mutate dropbox-first wrongtag 's/(mv "\$PARTIAL" "\$OUT"\n)/$1cp "\$OUT" "\$DROPBOX_DIR\/"\n/' \
		'wrongtag: nothing copied to Dropbox'
	# C10: the plaintext manifest is copied to Dropbox as well.
	mutate dropbox-plain-manifest happy 's/^(rm -f "\$MANIFEST_PLAIN"\n)/cp "\$MANIFEST_PLAIN" "\$DROPBOX_DIR\/plain.manifest" || true\n$1/m' \
		'happy: Dropbox gets only the two .age files'
	# C13: manifest written with a loose mode.
	mutate manifest-loose-mode happy 's/^umask 077$/umask 022/m; s/\t\tchmod 600 "\$MANIFEST"\n//; s/\t: >"\$\{MANIFEST\}\.partial"\n\tchmod 600 "\$\{MANIFEST\}\.partial"\n//' \
		'happy: manifest mode 600'
	# C13: plaintext manifest written next to the backup instead of the run dir.
	mutate manifest-beside-backup happy 's/^MANIFEST_PLAIN="\$SIDE\/manifest"$/MANIFEST_PLAIN="\$OUT.plain"/m; s/^rm -f "\$MANIFEST_PLAIN"\n//m' \
		'happy: no plaintext manifest left on disk'
	# C13: neither the explicit removal nor the exit trap clears the run dir
	# (two mechanisms; either alone suffices on this path).
	mutate no-plain-cleanup wrongtag 's/^trap \x27rm -rf "\$SIDE"\x27 EXIT$/trap : EXIT/m; s/^rm -f "\$MANIFEST_PLAIN"\n//m' \
		'wrongtag: no plaintext manifest left on disk'
	# C13: manifest stored unencrypted under the .age name.
	mutate manifest-not-encrypted happy 's/if age -R "\$RECIPIENT" -o "\$\{MANIFEST\}\.partial" <"\$MANIFEST_PLAIN" \\\n[^\n]*; then/if cp "\$MANIFEST_PLAIN" "\${MANIFEST}.partial"; then/' \
		'happy: no plaintext manifest left on disk'
	# C11: dry-run falls through to the backup.
	mutate dryrun-encrypts dryrun 's/if \[ "\$MODE" = "dry-run" \]; then/if [ "\$MODE" = "never" ]; then/' \
		'dryrun: age never ran'
	# C12: no VALIDATOR_HOST guard.
	mutate no-host-guard nohost 's/\[ -n "\$VALIDATOR_HOST" \] \|\| die 2/true || die 2/' \
		'nohost: ssh never ran'
	# D1: the drill is gated on a recipient .pub too.
	mutate drill-needs-pub drillnopub 's/^(\tDRILL_IDENTITY=.*)$/$1\n\t[ -f "\$RECIPIENT" ] || die 2 "needs pub"/m' \
		'drillnopub: exit 0 without any .pub'
	# D2: a failed decryption of the backup is ignored.
	mutate decrypt-ignored drilltamper 's/-o "\$WORK\/backup\.tar" "\$DRILL_FILE" \|\| drill_fail decrypt "could not open the backup"/-o "\$WORK\/backup.tar" "\$DRILL_FILE" || true/' \
		'drilltamper: log says FAIL decrypt'
	# D3: whole lines (hashes) are printed instead of names.
	mutate shows-hashes drillmanifest 's/^\tstrip_hash\(\) \{.*$/\tstrip_hash() { cat; }/m' \
		'drillmanifest-hash: no manifest hash on screen'
	# D3/D4: the comparison verdict is ignored.
	mutate no-compare drillmanifest 's/if \[ -n "\$DIFF_NAMES" \] \|\| \[ "\$DRILL_TOTAL" -lt 1 \]; then/if false; then/' \
		'drillmanifest-hash: exit 1'
	# D4: an empty manifest counts as a match.
	mutate empty-ok drillmanifest 's/\|\| \[ "\$DRILL_TOTAL" -lt 1 \]/|| [ "\$DRILL_TOTAL" -lt 0 ]/' \
		'drillmanifest-empty: exit 1'
	# D5: the scratch dir is not removed.
	mutate no-cleanup drillclean 's/if \[ -n "\$WORK" \]; then rm -rf "\$WORK"; fi/:/' \
		'drillclean: no fy-hcb-drill dir left after OK'
	# D5: TERM does not run the exit trap.
	# (bash runs the EXIT trap on a fatal TERM too, so the claim this breaks is
	# the reason: without its own trap the run is logged "error", not "interrupted")
	mutate no-term-trap drillclean 's/^\ttrap \x27DRILL_REASON=interrupted; exit 143\x27 TERM\n//m' \
		'drillclean: TERM is logged as FAIL interrupted'
	# D5: no exit trap at all.
	mutate no-exit-trap drillclean 's/^\ttrap drill_exit EXIT\n//m' \
		'drillclean: TERM leaves no fy-hcb-drill dir'
	# D6: the scratch dir is left world-readable.
	mutate loose-workdir drillmode 's/chmod 700 "\$WORK"/chmod 755 "\$WORK"/' \
		'drillmode: age wrote into a mode 700 dir (manifest, backup)'
	# D7: the drill reaches for the host.
	mutate drill-ssh drillhost 's/^(\tmkdir "\$WORK\/x")$/$1\n\tssh -n nowhere true || true/m' \
		'drillhost: ssh never ran'
	# D7: the drill writes a stray file under HOME.
	mutate drill-stray drillhost 's/^(\tmkdir "\$WORK\/x")$/$1\n\t: >"\$HOME\/stray"/m' \
		'drillhost: only the log file appeared under HOME'
	# D8: the identity file is read by another tool.
	mutate key-read drillkey 's/^(\tmkdir "\$WORK\/x")$/$1\n\tshasum -a 256 "\$DRILL_IDENTITY" >\/dev\/null/m' \
		"drillkey: no other tool's argv names the identity"
	# D9: the member-type check is off.
	mutate no-type-check drillunsafe 's/grep -qE \x27\[\^-d\]\x27/grep -qE \x27^\\0\$\x27/' \
		'drillunsafe-symlink: log says FAIL unsafe-member'
	# D9: the name check is off.
	mutate no-name-check drillunsafe 's/grep -qE \x27\^\/\|\(\^\|\/\)\\\.\\\.\(\/\|\$\)\x27/grep -qE \x27^\\0\$\x27/' \
		'drillunsafe-dotdot: log says FAIL unsafe-member'
	# D10: the oldest file is picked.
	mutate pick-oldest drillselect 's/if \[ -f "\$f" \]; then DRILL_FILE="\$f"; fi/if [ -f "\$f" ] \&\& [ -z "\$DRILL_FILE" ]; then DRILL_FILE="\$f"; fi/' \
		'drillselect: no argument picks the newest (the older one is corrupt): exit 0'
	# D10: a missing manifest is not a precondition.
	mutate no-manifest-check drillselect 's/\t\[ -f "\$DRILL_MANIFEST" \] \|\| die 2 [^\n]*\n//' \
		'drillselect: missing manifest: exit 2'
	# D11: the log is world-readable.
	mutate loose-log drilllog 's/^umask 077$/umask 022/m; s/\t\tchmod 600 "\$DRILL_LOG"\n//' \
		'drilllog: mode 600'
	# D11: the log carries the full path.
	mutate log-abs-path drilllog 's/"\$\(basename "\$DRILL_FILE"\)" \\\n/"\$DRILL_FILE" \\\n/' \
		'drilllog: no absolute path in the log'
	# D11: the log line loses its shape.
	mutate log-shape drilllog 's/matched=%s\/%s  %s/matched=%s\/%s %s/' \
		'drilllog: every line has the documented shape'
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
