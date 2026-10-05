#!/usr/bin/env bash
# tests/backup-host-config/test-backup-host-config.sh
#
# CHAIN: none — no host and no chain is contacted.
#
# scripts/operator-local/backup-host-config.sh — encrypted off-host backup of
# the validator host's untracked config. Hermetic: ssh is a stub that serves a
# fixture tree through the real tar; openssl / tar / cp / mv / shasum are
# argv-logging wrappers around the real binaries (so the encryption is real
# and independently decryptable). HOME and TMPDIR point into a watched
# directory that a background poller scans for plaintext while the script
# runs.
#
# Claims proven here, each with a mutant below that breaks it and must make
# its case fail (the "break-the-property" section at the bottom):
#   C1 no plaintext file is ever created            (poller + post-scan)
#   C2 the passphrase is never on any process argv  (argv logs)
#   C3 a mismatched confirmation refuses, writes nothing, never streams
#   C4 verify failure -> non-zero, file kept but renamed *.VERIFY-FAILED
#   C5 Dropbox copy happens only after a passing verify
#   C6 --dry-run never prompts and never encrypts
#   C7 VALIDATOR_HOST unset -> refuse before any ssh
#   C8 ssh never reads the script's stdin (-n), so the prompts get the input
#   C9 a name-set difference between the host listing and the archive fails verify
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
for t in openssl tar shasum; do
	command -v "$t" >/dev/null 2>&1 || skip_or_fail "$t not available"
done

PASS=0; FAIL=0; FAILURES=()
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1 ($2)"); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected='$2' actual='$3'"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing '$2'" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "unexpected '$2'" ;; *) ok "$1" ;; esac; }

MARKER="PLAINTEXT-MARKER-c0nf1g"
PP="Pp-SECRET-7f3a-x9"
DEPLOY="/srv/example-deploy"
EXPECTED_REMOTE="tar -C /etc -cf - freedom-yield -C ${DEPLOY} .env"

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
for c in openssl tar cp mv shasum; do
	real="$(command -v "$c")"
	cat >"$BIN/$c" <<STUB
#!/usr/bin/env bash
printf '%s\t%s\n' "$c" "\$*" >>"\$STUB_CALLS"
if [ "$c" = openssl ]; then
	case " \$* " in
		*" -d "*) [ "\${STUB_OPENSSL_DECRYPT_FAIL:-}" = 1 ] && exit 1 ;;
		*) [ -n "\${STUB_OPENSSL_SLEEP:-}" ] && sleep "\$STUB_OPENSSL_SLEEP" ;;
	esac
fi
exec "$real" "\$@"
STUB
	chmod +x "$BIN/$c"
done
REAL_TAR="$(command -v tar)"
cat >"$BIN/ssh" <<STUB
#!/usr/bin/env bash
printf 'ssh\t%s\n' "\$*" >>"\$STUB_CALLS"
n=0; [ -s "\$STUB_SSH_COUNTER" ] && n=\$(cat "\$STUB_SSH_COUNTER"); n=\$((n + 1))
printf '%s' "\$n" >"\$STUB_SSH_COUNTER"
# real ssh reads stdin unless -n: mimic that so a missing -n swallows input.
case " \$* " in *" -n "*) ;; *) cat >/dev/null ;; esac
last="\${!#}"
[ "\$last" = "\$STUB_EXPECTED_REMOTE" ] || { echo "stub ssh: unexpected remote command: \$last" >&2; exit 97; }
root="\$STUB_FIX"; [ "\$n" = "\${STUB_SSH_ALT_CALL:-0}" ] && root="\$STUB_FIX_ALT"
if [ "\$n" = "\${STUB_SSH_FAIL_CALL:-0}" ]; then
	"$REAL_TAR" -C "\$root/etc" -cf - freedom-yield | head -c 700; exit 255
fi
"$REAL_TAR" -C "\$root/etc" -cf - freedom-yield -C "\$root/deploy" .env
STUB
chmod +x "$BIN/ssh"

# --- runner -------------------------------------------------------------------
# run_case <stdin> [args...]  (env overrides via the caller's `VAR=x run_case`)
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
run_case() {
	local input="$1"; shift
	start_poller
	OUT="$(printf '%b' "$input" | env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" TMPDIR="$TMP/home/tmp" \
		VALIDATOR_HOST="${T_HOST-validator.example.invalid}" VALIDATOR_SSH_KEY="$TMP/home/.ssh/id_test" DEPLOY_PATH="$DEPLOY" \
		FYBK_TEST_ALLOW_NON_TTY="${T_ALLOW_NON_TTY-1}" \
		STUB_CALLS="$CALLS" STUB_SSH_COUNTER="$LOGS/ssh-count" STUB_EXPECTED_REMOTE="$EXPECTED_REMOTE" \
		STUB_FIX="$TMP/host" STUB_FIX_ALT="$TMP/host-alt" STUB_SSH_ALT_CALL="${T_ALT_CALL:-0}" \
		STUB_SSH_FAIL_CALL="${T_FAIL_CALL:-0}" STUB_OPENSSL_DECRYPT_FAIL="${T_DEC_FAIL:-}" STUB_OPENSSL_SLEEP=0.4 \
		bash "$SCRIPT" "$@" 2>"$LOGS/stderr")"
	RC=$?
	ERR="$(cat "$LOGS/stderr")"
	stop_poller
	rm -f "$LOGS/ssh-count"
}
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
enc_files() { find "$TMP/home" -maxdepth 1 -name 'fy-host-config-backup-*' | sort; }
dropbox_files() { find "$TMP/home/Dropbox/metal-validator-backup" -type f | sort; }
calls_of() { grep -c "^$1	" "$CALLS" || true; }
no_plaintext_anywhere() { # $1 label
	assert_eq "$1: poller saw no plaintext during the run" "" "$(sort -u "$LOGS/poll-hits")"
	assert_eq "$1: no plaintext left under HOME/TMPDIR" "" "$(grep -rlF "$MARKER" "$TMP/home" 2>/dev/null)"
}
pp_never_exposed() { # $1 label
	assert_not_contains "$1: passphrase absent from every process argv" "$PP" "$(cat "$CALLS")"
	assert_not_contains "$1: passphrase absent from stdout/stderr" "$PP" "$OUT$ERR"
}
TODAY="$(date -u +%Y%m%d)"
BK="$TMP/home/fy-host-config-backup-${TODAY}.tar.enc"

# --- cases ----------------------------------------------------------------------
if want happy; then
	echo "== happy path (C1 C2 C5 C8) =="
	reset_env
	run_case "$PP\n$PP\n"
	assert_eq "happy: exit 0" "0" "$RC"
	[ -f "$BK" ] && ok "happy: backup file written" || bad "happy: backup file written" "missing $BK"
	assert_eq "happy: backup mode 600" "600" "$(stat -f %Lp "$BK" 2>/dev/null || stat -c %a "$BK" 2>/dev/null)"
	DB="$TMP/home/Dropbox/metal-validator-backup/$(basename "$BK")"
	[ -f "$DB" ] && ok "happy: Dropbox copy written" || bad "happy: Dropbox copy written" "missing"
	SHA="$(shasum -a 256 "$BK" 2>/dev/null | awk '{print $1}')"
	assert_eq "happy: Dropbox copy identical" "$SHA" "$(shasum -a 256 "$DB" 2>/dev/null | awk '{print $1}')"
	assert_contains "happy: sha256 printed" "sha256:  $SHA" "$OUT"
	no_plaintext_anywhere "happy"
	pp_never_exposed "happy"
	assert_contains "happy: ssh uses -n" " -n " " $(grep '^ssh' "$CALLS" | head -1 | cut -f2) "
	assert_eq "happy: every ssh call ran exactly the read-only tar" "" \
		"$(grep '^ssh' "$CALLS" | grep -vF -- "$EXPECTED_REMOTE")"
	dec_line="$(grep -n '^openssl	enc -d' "$CALLS" | head -1 | cut -d: -f1)"
	cp_line="$(grep -n '^cp	' "$CALLS" | head -1 | cut -d: -f1)"
	[ -n "$dec_line" ] && [ -n "$cp_line" ] && [ "$dec_line" -lt "$cp_line" ] \
		&& ok "happy: Dropbox copy only after the verify decrypt" \
		|| bad "happy: Dropbox copy only after the verify decrypt" "decrypt@${dec_line:-none} cp@${cp_line:-none}"
	# Independent decrypt with the real openssl and the staker-backup parameters.
	names="$(X="$PP" openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:X -in "$BK" 2>/dev/null | tar -tf - | LC_ALL=C sort | tr '\n' ' ')"
	assert_contains "happy: independent decrypt (AES-256-CBC, PBKDF2 600k) lists .env" ".env " "$names"
	assert_contains "happy: independent decrypt lists the config dir entries" "freedom-yield/ntfy-topic " "$names"
	wrong="$(X="$PP" openssl enc -d -aes-256-cbc -pbkdf2 -iter 1000 -pass env:X -in "$BK" 2>/dev/null | tar -tf - 2>/dev/null)"
	assert_eq "happy: 1000 iterations does NOT decrypt (600k is really used)" "" "$wrong"

	echo "== --verify drill on that file =="
	cp "$BK" "$TMP/keep.enc"
	run_case "$PP\n" --verify "$TMP/keep.enc"
	assert_eq "verify-mode: right passphrase -> 0" "0" "$RC"
	assert_contains "verify-mode: PASS line" "VERIFY PASS" "$OUT"
	pp_never_exposed "verify-mode"
	run_case "not-the-passphrase\n" --verify "$TMP/keep.enc"
	assert_eq "verify-mode: wrong passphrase -> 1" "1" "$RC"
fi

if want mismatch; then
	echo "== mismatched confirmation (C3) =="
	reset_env
	run_case "$PP\n${PP}-typo\n"
	assert_eq "mismatch: exit 2" "2" "$RC"
	assert_contains "mismatch: says so" "do not match" "$ERR"
	assert_eq "mismatch: no backup files" "" "$(enc_files)"
	assert_eq "mismatch: openssl never ran" "0" "$(calls_of openssl)"
	assert_eq "mismatch: host contacted only for the listing" "1" "$(calls_of ssh)"
	reset_env
	run_case "\n\n"
	assert_eq "empty passphrase: exit 2" "2" "$RC"
	assert_eq "empty passphrase: no backup files" "" "$(enc_files)"
fi

if want verifyfail; then
	echo "== verify failure: decrypt fails (C4 C5) =="
	reset_env
	T_DEC_FAIL=1 run_case "$PP\n$PP\n"
	assert_eq "verifyfail: exit 1" "1" "$RC"
	[ -f "${BK}.VERIFY-FAILED" ] && ok "verifyfail: file kept, flagged .VERIFY-FAILED" || bad "verifyfail: file kept, flagged .VERIFY-FAILED" "$(enc_files)"
	[ ! -e "$BK" ] && ok "verifyfail: no unflagged .tar.enc left" || bad "verifyfail: no unflagged .tar.enc left" "exists"
	assert_eq "verifyfail: nothing copied to Dropbox" "" "$(dropbox_files)"
	assert_contains "verifyfail: loud message" "VERIFY FAILED" "$ERR"
	no_plaintext_anywhere "verifyfail"
fi

if want namediff; then
	echo "== verify failure: archive names differ from the host listing (C9 C4) =="
	reset_env
	T_ALT_CALL=2 run_case "$PP\n$PP\n"
	assert_eq "namediff: exit 1" "1" "$RC"
	[ -f "${BK}.VERIFY-FAILED" ] && ok "namediff: file kept, flagged" || bad "namediff: file kept, flagged" "$(enc_files)"
	assert_contains "namediff: diff names the extra entry" "appeared-later" "$ERR"
	assert_eq "namediff: nothing copied to Dropbox" "" "$(dropbox_files)"
fi

if want streamfail; then
	echo "== host stream dies mid-way =="
	reset_env
	T_FAIL_CALL=2 run_case "$PP\n$PP\n"
	assert_eq "streamfail: exit 3" "3" "$RC"
	[ -f "${BK}.INCOMPLETE" ] && ok "streamfail: partial kept as .INCOMPLETE" || bad "streamfail: partial kept as .INCOMPLETE" "$(enc_files)"
	assert_eq "streamfail: nothing copied to Dropbox" "" "$(dropbox_files)"
	no_plaintext_anywhere "streamfail"
fi

if want dryrun; then
	echo "== --dry-run (C6) =="
	reset_env
	run_case "$PP\n$PP\n" --dry-run
	assert_eq "dryrun: exit 0" "0" "$RC"
	assert_not_contains "dryrun: no passphrase prompt" "passphrase:" "$ERR"
	assert_eq "dryrun: openssl never ran" "0" "$(calls_of openssl)"
	assert_eq "dryrun: no backup files" "" "$(enc_files)"
	assert_contains "dryrun: lists .env" ".env" "$OUT"
	assert_contains "dryrun: lists a config entry" "freedom-yield/watch-list.json" "$OUT"
	assert_not_contains "dryrun: prints names, never contents" "$MARKER" "$OUT$ERR"
	no_plaintext_anywhere "dryrun"
fi

if want nohost; then
	echo "== VALIDATOR_HOST unset (C7) / non-tty refusal =="
	reset_env
	T_HOST="" run_case "$PP\n$PP\n"
	assert_eq "nohost: exit 2" "2" "$RC"
	assert_contains "nohost: names the variable" "VALIDATOR_HOST" "$ERR"
	assert_eq "nohost: ssh never ran" "0" "$(calls_of ssh)"
	reset_env
	T_ALLOW_NON_TTY=0 run_case "$PP\n$PP\n"
	assert_eq "non-tty: exit 2 (passphrase only from a terminal)" "2" "$RC"
	assert_eq "non-tty: no backup files" "" "$(enc_files)"
fi

# --- break-the-property ---------------------------------------------------------
# Each mutant breaks exactly one claim; re-running the named case against it
# MUST fail. A mutant that still passes means that case protects nothing.
if [ -z "$ONLY" ] && [ -z "${BACKUP_SCRIPT_UNDER_TEST:-}" ]; then
	echo "== break-the-property (each mutant must make its case fail) =="
	MUT="$TMP/mutants"; mkdir -p "$MUT"
	# $4 is the assertion that must be among the failures, so a mutant is
	# only counted as caught when it fails for the claimed reason.
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
	mutate plaintext-tee happy 's/if ! host_stream \| FYBK/if ! host_stream | tee "\$OUT_DIR\/stream.tar" | FYBK/; s/(mv "\$PARTIAL" "\$OUT"\n)/$1rm -f "\$OUT_DIR\/stream.tar"\n/' \
		'happy: poller saw no plaintext during the run'
	# C2: hand the passphrase to openssl on argv.
	mutate pass-on-argv happy 's/-pass env:FYBK_OPENSSL_PASS -out/-pass "pass:\$FYBK_PP" -out/' \
		'happy: passphrase absent from every process argv'
	# C3: skip the confirmation comparison.
	mutate no-confirm-check mismatch 's/if \[ "\$p1" != "\$p2" \]; then/if false; then/' \
		'mismatch: exit 2'
	# C4: ignore the verify verdict.
	mutate ignore-verify verifyfail 's/if \[ "\$VERIFY_OK" != "1" \]; then/if false; then/' \
		'verifyfail: exit 1'
	# C4: keep the failed file under its normal name.
	mutate unflagged-fail verifyfail 's/mv "\$OUT" "\$\{OUT\}\.VERIFY-FAILED"/:/' \
		'verifyfail: file kept, flagged .VERIFY-FAILED'
	# C5: copy to Dropbox before verifying.
	mutate dropbox-first verifyfail 's/(mv "\$PARTIAL" "\$OUT"\n)/$1cp "\$OUT" "\$DROPBOX_DIR\/"\n/' \
		'verifyfail: nothing copied to Dropbox'
	# C6: prompt during dry-run.
	mutate dryrun-prompts dryrun 's/(if \[ "\$MODE" = "dry-run" \]; then\n)/$1\tread_passphrase 1\n/' \
		'dryrun: no passphrase prompt'
	# C7: no VALIDATOR_HOST guard.
	mutate no-host-guard nohost 's/\[ -n "\$VALIDATOR_HOST" \] \|\| die 2/true || die 2/' \
		'nohost: ssh never ran'
	# C8: ssh without -n swallows the prompts' input.
	mutate ssh-reads-stdin happy 's/ssh -n -o/ssh -o/' \
		'happy: exit 0'
	# C9: skip the name-set comparison.
	mutate no-name-compare namediff 's/if \[ "\$ACTUAL_SORTED" != "\$EXPECTED_SORTED" \]; then/if false; then/' \
		'namediff: exit 1'
	# non-tty: accept piped input without the test override.
	mutate tty-check-off nohost 's/if \[ ! -t 0 \] && /if false \&\& /' \
		'non-tty: exit 2 (passphrase only from a terminal)'
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
