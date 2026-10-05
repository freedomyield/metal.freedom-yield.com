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
#   C10 Dropbox copy only after all checks; manifest is mode 600
#   C11 --dry-run never runs age and writes nothing
#   C12 VALIDATOR_HOST unset -> refuse before any ssh
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
	( while :; do grep -rlF "$MARKER" "$TMP/home" >>"$LOGS/poll-hits" 2>/dev/null; sleep 0.01; done ) &
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
		STUB_AGE_REAL="${T_AGE_REAL:-}" \
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
	assert_eq "$1: poller saw no plaintext during the run" "" "$(sort -u "$LOGS/poll-hits")"
	assert_eq "$1: no plaintext left under HOME/TMPDIR" "" "$(grep -rlF "$MARKER" "$TMP/home" 2>/dev/null)"
}
no_prompt() { # $1 label
	assert_not_contains "$1: no passphrase prompt" "assphrase:" "$OUT$ERR"
	assert_not_contains "$1: never read the (closed) stdin" "Bad file descriptor" "$ERR"
}
TODAY="$(date -u +%Y%m%d)"
BK="$TMP/home/fy-host-config-backup-${TODAY}.tar.age"
MF="${BK}.manifest"
# verify_fail_common <label> — the shape every verify failure must have (C9)
verify_fail_common() {
	assert_eq "$1: exit 1" "1" "$RC"
	[ -f "${BK}.VERIFY-FAILED" ] && ok "$1: file kept, flagged .VERIFY-FAILED" || bad "$1: file kept, flagged .VERIFY-FAILED" "$(out_files)"
	[ ! -e "$BK" ] && ok "$1: no unflagged .tar.age left" || bad "$1: no unflagged .tar.age left" "exists"
	[ ! -e "$MF" ] && ok "$1: no unflagged manifest left" || bad "$1: no unflagged manifest left" "exists"
	assert_eq "$1: nothing copied to Dropbox" "" "$(dropbox_files)"
	assert_contains "$1: loud message" "VERIFY FAILED" "$ERR"
	no_plaintext_anywhere "$1"
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
		"$(shasum -a 256 "$DB.manifest" 2>/dev/null | awk '{print $1}')"
	assert_contains "happy: sha256 printed" "sha256:   $SHA" "$OUT"
	no_plaintext_anywhere "happy"
	no_prompt "happy"
	assert_eq "happy: age argv is exactly -R <recipient> -o <partial>" "-R $PUB -o ${BK}.partial" \
		"$(grep '^age	' "$CALLS" | cut -f2)"
	assert_eq "happy: every ssh call ran one of the two read-only commands" "" \
		"$(grep '^ssh' "$CALLS" | grep -vF -- "$EXPECTED_REMOTE" | grep -vF -- "$EXPECTED_HASH")"
	assert_eq "happy: manifest has 7 lines" "7" "$(grep -c . "$MF" 2>/dev/null)"
	assert_eq "happy: every manifest line is '<sha256>  <name>'" "" "$(grep -vE '^[0-9a-f]{64}  [^ ]+$' "$MF" 2>/dev/null)"
	assert_not_contains "happy: manifest carries no file contents" "$MARKER" "$(cat "$MF" 2>/dev/null)"
	assert_eq "happy: manifest hash of .env is the real one" \
		"$(cd "$TMP/host/deploy" && shasum -a 256 .env)" "$(grep '  \.env$' "$MF" 2>/dev/null)"
	cp_line="$(grep -n '^cp	' "$CALLS" | head -1 | cut -d: -f1)"
	last_ssh="$(grep -n '^ssh	' "$CALLS" | tail -1 | cut -d: -f1)"
	[ -n "$cp_line" ] && [ -n "$last_ssh" ] && [ "$last_ssh" -lt "$cp_line" ] \
		&& ok "happy: Dropbox copy only after the manifest fetch" \
		|| bad "happy: Dropbox copy only after the manifest fetch" "ssh@${last_ssh:-none} cp@${cp_line:-none}"
	: >"$CALLS"
	run_case --restore-help
	assert_eq "restore-help: exit 0" "0" "$RC"
	assert_contains "restore-help: shows the age decrypt with the private key" "age -d -i $TMP/keys/id_ed25519 " "$OUT"
	assert_eq "restore-help: contacts nothing" "0" "$(calls_of ssh)"
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
	assert_eq "hashleak: content never stored anywhere" "" "$(grep -rlF "$MARKER" "$TMP/home" 2>/dev/null)"
fi

if want streamfail; then
	echo "== host stream dies mid-way =="
	reset_env
	T_FAIL_CALL=2 run_case
	assert_eq "streamfail: exit 3" "3" "$RC"
	[ -f "${BK}.INCOMPLETE" ] && ok "streamfail: partial kept as .INCOMPLETE" || bad "streamfail: partial kept as .INCOMPLETE" "$(out_files)"
	assert_eq "streamfail: nothing copied to Dropbox" "" "$(dropbox_files)"
	no_plaintext_anywhere "streamfail"
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

# --- break-the-property ---------------------------------------------------------
# Each mutant breaks exactly one claim; re-running the named case against it
# MUST fail, for the claimed reason ($4 must be among the failures).
# Not mutated: --restore-help (prints text only; its assertion is the check).
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
	mutate age-passphrase-mode happy 's/age -R "\$RECIPIENT" -o/age -p -o/' \
		'happy: age argv is exactly -R <recipient> -o <partial>'
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
		'wrongtag: exit 1'
	# C9: keep the failed file under its normal name.
	mutate unflagged-fail wrongtag 's/mv "\$OUT" "\$\{OUT\}\.VERIFY-FAILED"/:/' \
		'wrongtag: file kept, flagged .VERIFY-FAILED'
	# C10: copy to Dropbox before verifying.
	mutate dropbox-first wrongtag 's/(mv "\$PARTIAL" "\$OUT"\n)/$1cp "\$OUT" "\$DROPBOX_DIR\/"\n/' \
		'wrongtag: nothing copied to Dropbox'
	# C10: manifest written with a loose mode.
	mutate manifest-loose-mode happy 's/^umask 077$/umask 022/m; s/\tchmod 600 "\$MANIFEST"\n//' \
		'happy: manifest mode 600'
	# C11: dry-run falls through to the backup.
	mutate dryrun-encrypts dryrun 's/if \[ "\$MODE" = "dry-run" \]; then/if [ "\$MODE" = "never" ]; then/' \
		'dryrun: age never ran'
	# C12: no VALIDATOR_HOST guard.
	mutate no-host-guard nohost 's/\[ -n "\$VALIDATOR_HOST" \] \|\| die 2/true || die 2/' \
		'nohost: ssh never ran'
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
