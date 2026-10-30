#!/usr/bin/env bash
# tests/staker-backup-encrypt/test-staker-backup-encrypt.sh
#
# CHAIN: none. Fake key files only; real tar + real openssl.
#
# scripts/operator-local/staker-backup-encrypt.sh -- makes the encrypted staker
# backup and proves in the same run that it opens to the same three files.
#
# Claims, each with a mutant at the bottom that must fail its assertion:
#   E1 the result opens with the drill's exact cipher/iterations and the given
#      passphrase, under the dated top dir dr-drill.sh expects, same 3 hashes
#   E2 a confirm that differs -> non-zero, nothing written
#   E3 an existing output is never overwritten (refused, file unchanged)
#   E4 a passphrase shorter than 16 -> non-zero, nothing written
#   E5 the .sha256 next to it matches the file; the file is mode 600
#
# SCRIPT_UNDER_TEST=<path> to run against a mutant.

# shellcheck disable=SC2015,SC2016  # A&&ok||bad reporters; literal perl code
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REAL="$REPO/scripts/operator-local/staker-backup-encrypt.sh"
SCRIPT="${SCRIPT_UNDER_TEST:-$REAL}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for t in openssl tar shasum; do
	command -v "$t" >/dev/null 2>&1 || { [ -n "${CI:-}" ] && { echo "FAIL: $t missing"; exit 1; }; echo "SKIP: $t"; exit 0; }
done

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }

PP="encrypt-test-passphrase-0123"
setup() {
	H="$TMP/$1"; mkdir -p "$H/staker-backup-20260518/staking"
	printf 'fake-crt-%s\n' "$1" >"$H/staker-backup-20260518/staking/staker.crt"
	printf 'fake-key-%s\n' "$1" >"$H/staker-backup-20260518/staking/staker.key"
	printf 'fake-bls-%s\n' "$1" >"$H/staker-backup-20260518/staking/signer.key"
}
run() { # run <home> <stdin text>
	printf '%s' "$2" | HOME="$1" STAKER_BACKUP_DATE=20261030 bash "$SCRIPT" >"$1.out" 2>&1
}
OUTNAME="staker-backup-20261030.tar.gz.enc"

# E1 + E5
setup e1
run "$TMP/e1" "$PP"$'\n'"$PP"$'\n'; rc=$?
[ "$rc" = 0 ] && ok "E1 exit 0" || bad "E1 exit 0" "rc=$rc $(tail -2 "$TMP/e1.out")"
mkdir -p "$TMP/e1x"
if X="$PP" openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:X \
	-in "$TMP/e1/$OUTNAME" -out "$TMP/e1x/r.tar.gz" 2>/dev/null \
	&& tar xzf "$TMP/e1x/r.tar.gz" -C "$TMP/e1x"; then
	same=1
	for f in staker.crt staker.key signer.key; do
		cmp -s "$TMP/e1/staker-backup-20260518/staking/$f" "$TMP/e1x/staker-backup-20261030/staking/$f" || same=0
	done
	[ "$same" = 1 ] && ok "E1 opens with the drill cipher; dated top dir; same 3 files" \
		|| bad "E1 same 3 files under staker-backup-20261030/staking" "differ or missing"
else
	bad "E1 opens with the drill cipher" "decrypt or extract failed"
fi
( cd "$TMP/e1" && shasum -a 256 -c "$OUTNAME.sha256" >/dev/null 2>&1 ) \
	&& ok "E5 .sha256 matches" || bad "E5 .sha256 matches" "missing or wrong"
[ "$(stat -f '%Lp' "$TMP/e1/$OUTNAME" 2>/dev/null || stat -c '%a' "$TMP/e1/$OUTNAME")" = 600 ] \
	&& ok "E5 mode 600" || bad "E5 mode 600" "other mode"

# E2
setup e2
run "$TMP/e2" "$PP"$'\n'"${PP}x"$'\n'; rc=$?
[ "$rc" != 0 ] && [ ! -e "$TMP/e2/$OUTNAME" ] && [ ! -e "$TMP/e2/$OUTNAME.partial" ] \
	&& ok "E2 confirm mismatch -> refused, nothing written" || bad "E2 confirm mismatch" "rc=$rc"

# E3
setup e3
printf 'existing' >"$TMP/e3/$OUTNAME"
run "$TMP/e3" "$PP"$'\n'"$PP"$'\n'; rc=$?
[ "$rc" != 0 ] && [ "$(cat "$TMP/e3/$OUTNAME")" = existing ] \
	&& ok "E3 existing output not overwritten" || bad "E3 existing output not overwritten" "rc=$rc"

# E4
setup e4
run "$TMP/e4" "short"$'\n'"short"$'\n'; rc=$?
[ "$rc" != 0 ] && [ ! -e "$TMP/e4/$OUTNAME" ] && [ ! -e "$TMP/e4/$OUTNAME.partial" ] \
	&& ok "E4 short passphrase -> refused, nothing written" || bad "E4 short passphrase" "rc=$rc"

echo
echo "RESULT: $PASS passed, $FAIL failed"

# --- mutants: each breaks one claim; the suite must fail on it ---------------
if [ -z "${SCRIPT_UNDER_TEST:-}" ]; then
	M="$TMP/mut"; mkdir -p "$M"
	mutant() { # mutant <name> <perl substitution>
		perl -0pe "$2" "$REAL" >"$M/$1.sh"
		if cmp -s "$REAL" "$M/$1.sh"; then bad "mutant $1 applies" "substitution matched nothing"; return; fi
		if SCRIPT_UNDER_TEST="$M/$1.sh" bash "$0" >"$M/$1.out" 2>&1; then
			bad "mutant $1 is caught" "suite passed on the mutant"
		else
			ok "mutant $1 is caught"
		fi
	}
	mutant iter    's/-iter 600000 -salt/-iter 1000 -salt/'
	mutant toplvl  's/-C "\$WORKDIR\/src" "\$TOP"/-C "\$WORKDIR\/src\/\$TOP" staking/'
	mutant confirm 's/\[ "\$P1" = "\$P2" \] \|\|/true ||/'
	mutant overwrite 's/\[ ! -e "\$OUT" \] && //'
	mutant minlen  's/MIN_LEN=16/MIN_LEN=1/'
	mutant shafile 's/shasum -a 256 "\$\(basename "\$OUT"\)" >/echo x >/'
	echo "RESULT (with mutants): $PASS passed, $FAIL failed"
fi
[ "$FAIL" = 0 ]
