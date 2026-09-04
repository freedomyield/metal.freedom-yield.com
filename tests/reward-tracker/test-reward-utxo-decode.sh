#!/usr/bin/env bash
# tests/reward-tracker/test-reward-utxo-decode.sh — verifies
# scripts/lib/reward-utxo-decode.sh's decode_reward_utxo_nmetal() /
# sum_reward_utxos_metal() against hand-built UTXO byte fixtures.
#
# CHAIN: none — pure decoder test. Fixture bytes are built in-line by a
# python3 helper that mirrors metalgo's actual serialization order (see the
# lib's header for the byte-layout citation); no live or mocked RPC call is
# made anywhere in this file.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/scripts/lib/reward-utxo-decode.sh"

PASS=0
FAIL=0
FAILURES=()

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %-65s expected=%s actual=%s\n' "$label" "$expected" "$actual"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected=$expected, actual=$actual)")
		printf '  FAIL  %-65s expected=%s actual=%s\n' "$label" "$expected" "$actual"
	fi
}

assert_rc() {
	local label="$1" expected_rc="$2" actual_rc="$3"
	if [ "$expected_rc" = "$actual_rc" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  %-65s expected_rc=%s actual_rc=%s\n' "$label" "$expected_rc" "$actual_rc"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("$label (expected_rc=$expected_rc, actual_rc=$actual_rc)")
		printf '  FAIL  %-65s expected_rc=%s actual_rc=%s\n' "$label" "$expected_rc" "$actual_rc"
	fi
}

# build_utxo_hex <amt_nmetal> <type_id> — constructs a hex-encoded UTXO blob
# byte-for-byte in the same field order metalgo's codec would produce for a
# TransferOutput (or a caller-chosen type_id, to build the wrong-type
# fixture). TxID/AssetID/Addrs bytes are arbitrary fill (0x11/0x22/0x33) —
# decode_reward_utxo_nmetal never reads them.
build_utxo_hex() {
	local amt_nmetal="$1" type_id="${2:-7}"
	python3 - "$amt_nmetal" "$type_id" <<'PY'
import sys
amt = int(sys.argv[1])
type_id = int(sys.argv[2])
parts = [
    b'\x00\x00',                 # codec version
    bytes([0x11]) * 32,          # TxID
    (0).to_bytes(4, 'big'),      # OutputIndex
    bytes([0x22]) * 32,          # AssetID
    type_id.to_bytes(4, 'big'),  # Out type ID
    amt.to_bytes(8, 'big'),      # Amt
    (0).to_bytes(8, 'big'),      # Locktime
    (1).to_bytes(4, 'big'),      # Threshold
    (1).to_bytes(4, 'big'),      # len(Addrs)
    bytes([0x33]) * 20,          # Addrs[0]
]
print('0x' + b''.join(parts).hex())
PY
}

echo "=== decode_reward_utxo_nmetal() ==="

# shellcheck source=scripts/lib/reward-utxo-decode.sh
. "$LIB"

UTXO_5_METAL="$(build_utxo_hex 5000000000)"
UTXO_FRAC="$(build_utxo_hex 123456789)"
UTXO_ZERO="$(build_utxo_hex 0)"
UTXO_WRONG_TYPE="$(build_utxo_hex 5000000000 22)"   # 22 = stakeable.LockOut

assert_eq "5 METAL UTXO decodes to 5000000000 nMETAL" "5000000000" "$(decode_reward_utxo_nmetal "$UTXO_5_METAL")"
assert_eq "fractional UTXO decodes exactly" "123456789" "$(decode_reward_utxo_nmetal "$UTXO_FRAC")"
assert_eq "zero-amount UTXO decodes to 0" "0" "$(decode_reward_utxo_nmetal "$UTXO_ZERO")"
assert_eq "no 0x prefix also accepted" "5000000000" "$(decode_reward_utxo_nmetal "${UTXO_5_METAL#0x}")"

decode_reward_utxo_nmetal "$UTXO_WRONG_TYPE" >/dev/null 2>&1
assert_rc "wrong Out type ID (22, not 7) refused, not misparsed" "3" "$?"

decode_reward_utxo_nmetal "0x1234" >/dev/null 2>&1
assert_rc "too-short blob refused" "2" "$?"

decode_reward_utxo_nmetal "0xzz" >/dev/null 2>&1
assert_rc "non-hex input refused" "1" "$?"

echo ""
echo "=== sum_reward_utxos_metal() ==="

SUM_TWO="$(printf '%s\n%s\n' "$UTXO_5_METAL" "$UTXO_FRAC" | sum_reward_utxos_metal)"
assert_eq "5 METAL + 0.123456789 METAL = 5.123456789" "5.123456789" "$SUM_TWO"

SUM_EMPTY="$(printf '' | sum_reward_utxos_metal)"
assert_eq "no UTXOs -> 0.000000000 (a legitimate outcome, not an error)" "0.000000000" "$SUM_EMPTY"

# A partial-decode set (one good UTXO, one wrong-type UTXO) must still sum
# the decodable one rather than aborting to nothing — see the lib's
# fail-loud-but-partial rationale.
SUM_PARTIAL="$(printf '%s\n%s\n' "$UTXO_5_METAL" "$UTXO_WRONG_TYPE" | sum_reward_utxos_metal 2>/dev/null)"
assert_eq "one good + one refused UTXO -> sums the decodable one, not zero" "5.000000000" "$SUM_PARTIAL"

echo ""
echo "=== mutation kill check ==="
echo "(proves the type-ID guard is what rejects UTXO_WRONG_TYPE — not an"
echo " accident of the fixture — by removing the guard and observing a"
echo " MISPARSED, non-zero, WRONG amount come back instead of a refusal.)"

MUTANT="$(mktemp)"
trap 'rm -f "$MUTANT"' EXIT
# Neutralize the type-ID check: force it to always look like a match.
sed 's/if \[ "\$type_id" -ne 7 \]; then/if [ "0" -ne 7 ] \&\& false; then/' "$LIB" > "$MUTANT"
if ! diff -q "$LIB" "$MUTANT" >/dev/null 2>&1; then
	(
		# shellcheck disable=SC1090
		. "$MUTANT"
		MUTANT_OUT="$(decode_reward_utxo_nmetal "$UTXO_WRONG_TYPE" 2>/dev/null)"
		MUTANT_RC=$?
		echo "$MUTANT_RC $MUTANT_OUT"
	) > "${MUTANT}.result"
	read -r MUTANT_RC MUTANT_OUT < "${MUTANT}.result"
	rm -f "${MUTANT}.result"
	if [ "$MUTANT_RC" = "0" ]; then
		PASS=$((PASS + 1))
		printf '  PASS  mutant (type-ID guard disabled) MISPARSES the wrong-type UTXO (rc=0, amount=%s) instead of refusing — the guard is load-bearing\n' "$MUTANT_OUT"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("mutation kill check: mutant still refused (rc=$MUTANT_RC) — the sed patch did not actually disable the guard")
		printf '  FAIL  mutant unexpectedly still refused (rc=%s) — guard patch ineffective\n' "$MUTANT_RC"
	fi
else
	FAIL=$((FAIL + 1))
	FAILURES+=("mutation kill check: sed did not change the file — type-ID guard not found at expected shape")
	echo "  FAIL  mutant sed produced no diff — guard not matched, mutation not actually applied"
fi
rm -f "$MUTANT" "${MUTANT}.result"
trap - EXIT

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
