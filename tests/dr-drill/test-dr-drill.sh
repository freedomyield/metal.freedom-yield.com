#!/usr/bin/env bash
# tests/dr-drill/test-dr-drill.sh
#
# CHAIN: none — docker and curl are stubs; no container is started, no
# network is touched.
#
# scripts/dr-drill.sh — readiness of the quarterly DR drill. A synthetic
# staker backup (fake key files, real tar + real openssl with the drill's
# cipher/iterations) is decrypted end to end; docker and the info API are
# stubbed. EXPECTED_SHA_* / EXPECTED_NODEID are pointed at the synthetic set,
# so no real key material or real backup is ever read.
#
# Claims, each with a mutant at the bottom that must fail its assertion:
#   D1 the default backup is the NEWEST ~/staker-backup-*.tar.gz.enc
#   D2 every metalgo container gets --network-id=local (never mainnet)
#   D3 the staking dir is found under the dated top directory of the tarball
#   D4 the default image is the production pin, not :latest
#   D5 wrong passphrase / NodeID mismatch / no backup -> non-zero
#
# DRILL_SCRIPT_UNDER_TEST=<path> / DRILL_TEST_ONLY=<case> as in the other suites.

# shellcheck disable=SC2015,SC2016,SC2329  # A&&ok||bad reporters; literal perl code; functions called indirectly
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REAL_SCRIPT="$REPO/scripts/dr-drill.sh"
SCRIPT="${DRILL_SCRIPT_UNDER_TEST:-$REAL_SCRIPT}"
ONLY="${DRILL_TEST_ONLY:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

skip_or_fail() {
	if [ -n "${CI:-}" ]; then echo "FAIL: $1 (CI must run this suite)"; exit 1; fi
	echo "SKIP: $1"; exit 0
}
for t in openssl tar shasum jq; do
	command -v "$t" >/dev/null 2>&1 || skip_or_fail "$t not available"
done

PASS=0; FAIL=0; FAILURES=()
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1 ($2)"); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected='$2' actual='$3'"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "missing '$2'" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "unexpected '$2'" ;; *) ok "$1" ;; esac; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

PP="drill-test-passphrase"
NODEID="NodeID-TestTestTestTestTestTestTestTest"
HOME_T="$TMP/home"; mkdir -p "$HOME_T"

# --- synthetic staker backup (dated top dir, as the real one is) ------------
SRC="$TMP/src/staker-backup-20260518/staking"; mkdir -p "$SRC"
printf 'fake-crt\n' >"$SRC/staker.crt"; printf 'fake-key\n' >"$SRC/staker.key"; printf 'fake-bls\n' >"$SRC/signer.key"
tar czf "$TMP/src/b.tar.gz" -C "$TMP/src" staker-backup-20260518
X="$PP" openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:X -in "$TMP/src/b.tar.gz" -out "$HOME_T/staker-backup-20260518.tar.gz.enc"
printf 'older-garbage' >"$HOME_T/staker-backup-20250101.tar.gz.enc"
SHA_CRT="$(shasum -a 256 "$SRC/staker.crt" | awk '{print $1}')"
SHA_KEY="$(shasum -a 256 "$SRC/staker.key" | awk '{print $1}')"
SHA_BLS="$(shasum -a 256 "$SRC/signer.key" | awk '{print $1}')"

# --- stubs --------------------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"; CALLS="$TMP/calls.log"
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker\t%s\n' "$*" >>"$STUB_CALLS"
exit 0
STUB
cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"jsonrpc":"2.0","id":1,"result":{"nodeID":"%s","nodePOP":{"publicKey":"0xabcdefabcdefabcdefabcdefabcdefabcdef0123456789","proofOfPossession":"0x00"}}}' "$STUB_NODEID"
STUB
cat >"$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN"/*

RC=0; OUT=""
run_drill() { # $1 stdin, rest = args; T_* env for overrides
	local input="$1"; shift
	: >"$CALLS"
	OUT="$(printf '%s\n' "$input" | env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)"):$(dirname "$(command -v openssl)")" \
		HOME="$HOME_T" STUB_CALLS="$CALLS" STUB_NODEID="${T_NODEID:-$NODEID}" \
		EXPECTED_NODEID="$NODEID" EXPECTED_SHA_CRT="$SHA_CRT" EXPECTED_SHA_KEY="$SHA_KEY" EXPECTED_SHA_BLS="$SHA_BLS" \
		DR_DRILL_BOOT_TIMEOUT=2 \
		bash "$SCRIPT" "$@" 2>&1)"
	RC=$?
}
docker_runs() { grep '^docker	run ' "$CALLS" || true; }

if want newest; then
	echo "== D1 newest backup is the default =="
	run_drill "" --dry-run
	assert_eq "newest: dry-run exit 0" "0" "$RC"
	assert_contains "newest: picks staker-backup-20260518" "backup: $HOME_T/staker-backup-20260518.tar.gz.enc" "$OUT"
	assert_not_contains "newest: does not decrypt in dry-run" "Decrypt encrypted backup" "$OUT"
	assert_contains "dry-run: boots with ephemeral keys" "--staking-ephemeral-cert-enabled=true" "$(docker_runs)"
	assert_contains "dry-run: local network" "--network-id=local" "$(docker_runs)"
fi

if want drill; then
	echo "== D2-D4 full drill against the synthetic backup =="
	run_drill "$PP"
	assert_eq "drill: exit 0" "0" "$RC"
	assert_contains "drill: PASSED" "DR drill PASSED" "$OUT"
	R="$(docker_runs)"
	assert_eq "drill: exactly one container started" "1" "$(grep -c . <<<"$R")"
	assert_contains "drill: --network-id=local" "--network-id=local" "$R"
	assert_not_contains "drill: never mainnet" "mainnet" "$R"
	assert_contains "drill: staking dir found under the dated top dir" "staker-backup-20260518/staking:/root/.metalgo/staking:ro" "$R"
	assert_contains "drill: default image is the production pin" "metalblockchain/metalgo:v1.13.5" "$R"
	assert_not_contains "drill: not :latest" "metalgo:latest" "$R"
fi

if want failures; then
	echo "== D5 failure paths =="
	run_drill "wrong-passphrase"
	assert_eq "wrong passphrase: exit 1" "1" "$RC"
	assert_eq "wrong passphrase: no container started" "" "$(docker_runs)"
	T_NODEID="NodeID-SomeoneElse" run_drill "$PP"
	assert_eq "nodeid mismatch: exit 1" "1" "$RC"
	assert_contains "nodeid mismatch: says so" "NodeID mismatch" "$OUT"
	mv "$HOME_T/staker-backup-20260518.tar.gz.enc" "$TMP/aside1"; mv "$HOME_T/staker-backup-20250101.tar.gz.enc" "$TMP/aside2"
	run_drill "" --dry-run
	assert_eq "no backup: exit 1" "1" "$RC"
	assert_contains "no backup: says so" "no ~/staker-backup-*.tar.gz.enc found" "$OUT"
	mv "$TMP/aside1" "$HOME_T/staker-backup-20260518.tar.gz.enc"; mv "$TMP/aside2" "$HOME_T/staker-backup-20250101.tar.gz.enc"
fi

if [ -z "$ONLY" ] && [ -z "${DRILL_SCRIPT_UNDER_TEST:-}" ]; then
	echo "== break-the-property =="
	MUT="$TMP/mutants"; mkdir -p "$MUT"
	mutate() { # $1 name, $2 case, $3 perl substitution, $4 assertion that must fail
		local m="$MUT/$1.sh"
		perl -0pe "$3" "$REAL_SCRIPT" >"$m"
		if cmp -s "$m" "$REAL_SCRIPT"; then bad "mutant $1" "substitution did not apply"; return; fi
		if DRILL_SCRIPT_UNDER_TEST="$m" DRILL_TEST_ONLY="$2" bash "$0" >"$MUT/$1.out" 2>&1; then
			bad "mutant $1 is caught by case '$2'" "case still passed"
		elif grep -qF "FAIL  $4" "$MUT/$1.out"; then
			ok "mutant $1 is caught by '$4'"
		else
			bad "mutant $1 is caught by '$4'" "failed for another reason: $(grep -m1 'FAIL  ' "$MUT/$1.out")"
		fi
	}
	mutate oldest-first newest 's/\[\[ "\$f" > "\$newest" \]\]/[[ "\$f" < "\$newest" ]]/' \
		'newest: picks staker-backup-20260518'
	mutate mainnet-args drill 's/  --network-id=local\n/  --network-id=mainnet\n/; s/\[ "\$has_local" = 1 \] \|\| fail/true || fail/; s/--network-id=\*\) fail/--network-id=NEVER) fail/' \
		'drill: --network-id=local'
	mutate guard-only drill 's/  --network-id=local\n/  --network-id=mainnet\n/' \
		'drill: exit 0'
	mutate stale-staking-path drill 's/STAKING=\$\(find [^\n]*\n/STAKING="\$WORKDIR\/staker-backup\/staking"\n/' \
		'drill: exit 0'
	mutate image-latest drill 's/metalgo:v1\.13\.5\}/metalgo:latest}/' \
		'drill: default image is the production pin'
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
