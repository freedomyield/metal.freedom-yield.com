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

# build_utxo_hex <amt_nmetal> [type_id] [output_index] — constructs a
# hex-encoded UTXO blob byte-for-byte in the same field order metalgo's
# codec would produce for a TransferOutput (or a caller-chosen type_id, to
# build the wrong-type fixture). TxID/AssetID/Addrs bytes are arbitrary fill
# (0x11/0x22/0x33) — the decoder never reads them. output_index (default 0)
# is the UTXOID.OutputIndex field the 2026-09-07 self/fee split reads.
build_utxo_hex() {
	local amt_nmetal="$1" type_id="${2:-7}" out_idx="${3:-0}"
	python3 - "$amt_nmetal" "$type_id" "$out_idx" <<'PY'
import sys
amt = int(sys.argv[1])
type_id = int(sys.argv[2])
out_idx = int(sys.argv[3])
parts = [
    b'\x00\x00',                    # codec version
    bytes([0x11]) * 32,             # TxID
    out_idx.to_bytes(4, 'big'),     # OutputIndex
    bytes([0x22]) * 32,             # AssetID
    type_id.to_bytes(4, 'big'),     # Out type ID
    amt.to_bytes(8, 'big'),         # Amt
    (0).to_bytes(8, 'big'),         # Locktime
    (1).to_bytes(4, 'big'),         # Threshold
    (1).to_bytes(4, 'big'),         # len(Addrs)
    bytes([0x33]) * 20,             # Addrs[0]
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
echo "=== decode_reward_utxo_output_index() ==="

UTXO_IDX2="$(build_utxo_hex 5000000000 7 2)"
UTXO_IDX3="$(build_utxo_hex 1000000000 7 3)"
UTXO_IDX_MAX="$(build_utxo_hex 1 7 4294967295)"
assert_eq "OutputIndex 2 decodes to 2" "2" "$(decode_reward_utxo_output_index "$UTXO_IDX2")"
assert_eq "OutputIndex 3 decodes to 3" "3" "$(decode_reward_utxo_output_index "$UTXO_IDX3")"
assert_eq "OutputIndex uint32 max decodes exactly" "4294967295" "$(decode_reward_utxo_output_index "$UTXO_IDX_MAX")"
assert_eq "OutputIndex: no 0x prefix also accepted" "2" "$(decode_reward_utxo_output_index "${UTXO_IDX2#0x}")"
decode_reward_utxo_output_index "0x1234" >/dev/null 2>&1
assert_rc "OutputIndex: too-short blob refused" "2" "$?"
decode_reward_utxo_output_index "$UTXO_WRONG_TYPE" >/dev/null 2>&1
assert_rc "OutputIndex: wrong Out type ID refused (same guard as the amount decoder)" "3" "$?"

echo ""
echo "=== split_reward_utxos_metal() — self / fee by relative OutputIndex ==="
# Shapes traced from metalgo's rewardValidatorTx() (see the lib header):
#   commit: self at index K (== PotentialReward), fee at K+1 iff accrued > 0
#   abort:  fee ONLY, at index K (no self output)
# Output: "<total> <self> <fee> <known> <basis>"; self/fee are "-" when known=0.
SELF_K2="$(build_utxo_hex 50500000000 7 2)"    # 50.5 METAL @ index 2
FEE_K3="$(build_utxo_hex 12250000000 7 3)"     # 12.25 METAL @ index 3
FEE_K5="$(build_utxo_hex 12250000000 7 5)"     # 12.25 METAL @ index 5 (gap)
EXTRA_K4="$(build_utxo_hex 1000000000 7 4)"    # a third output — unknown shape

assert_eq "0 UTXOs -> 0 total, self 0, fee 0, known" \
	"0.000000000 0.000000000 0.000000000 1 zero-outputs" "$(printf '' | split_reward_utxos_metal)"

assert_eq "2 UTXOs, consecutive: lower index = self, higher = fee, known" \
	"62.750000000 50.500000000 12.250000000 1 utxo-order" "$(printf '%s\n%s\n' "$SELF_K2" "$FEE_K3" | split_reward_utxos_metal)"
assert_eq "2 UTXOs given in reverse order still split by index, not by input order" \
	"62.750000000 50.500000000 12.250000000 1 utxo-order" "$(printf '%s\n%s\n' "$FEE_K3" "$SELF_K2" | split_reward_utxos_metal)"
assert_eq "2 UTXOs, consecutive, lower amount == potentialReward hint: known" \
	"62.750000000 50.500000000 12.250000000 1 utxo-order+potential-reward" "$(printf '%s\n%s\n' "$SELF_K2" "$FEE_K3" | split_reward_utxos_metal 50500000000)"
assert_eq "2 UTXOs, consecutive, lower amount != potentialReward hint: total kept, split refused" \
	"62.750000000 - - 0 refused:hint-contradicted" "$(printf '%s\n%s\n' "$SELF_K2" "$FEE_K3" | split_reward_utxos_metal 999)"
assert_eq "2 UTXOs, NON-consecutive indices (2,5): total kept, split refused" \
	"62.750000000 - - 0 refused:nonadjacent" "$(printf '%s\n%s\n' "$SELF_K2" "$FEE_K5" | split_reward_utxos_metal)"
assert_eq "2 UTXOs, SAME index: total kept, split refused" \
	"101.000000000 - - 0 refused:nonadjacent" "$(printf '%s\n%s\n' "$SELF_K2" "$SELF_K2" | split_reward_utxos_metal)"
assert_eq "3 UTXOs: total kept, split refused" \
	"63.750000000 - - 0 refused:too-many" "$(printf '%s\n%s\n%s\n' "$SELF_K2" "$FEE_K3" "$EXTRA_K4" | split_reward_utxos_metal)"

assert_eq "1 UTXO, no potentialReward hint: total kept, split refused (commit-self vs abort-fee is undecidable)" \
	"50.500000000 - - 0 refused:single-no-hint" "$(printf '%s\n' "$SELF_K2" | split_reward_utxos_metal)"
assert_eq "1 UTXO == potentialReward hint: self = all, fee 0, known (commit path)" \
	"50.500000000 50.500000000 0.000000000 1 potential-reward-match" "$(printf '%s\n' "$SELF_K2" | split_reward_utxos_metal 50500000000)"
assert_eq "1 UTXO != potentialReward hint: self 0, fee = all, known (abort path pays the delegatee cut only)" \
	"12.250000000 0.000000000 12.250000000 1 potential-reward-mismatch" "$(printf '%s\n' "$FEE_K3" | split_reward_utxos_metal 50500000000)"
assert_eq "1 UTXO, non-numeric hint is treated as absent (split refused, not crashed)" \
	"50.500000000 - - 0 refused:single-no-hint" "$(printf '%s\n' "$SELF_K2" | split_reward_utxos_metal abc 2>/dev/null)"

# A refused UTXO poisons the split (never guess around a blob we could not
# read) but the total still carries the decodable part, matching
# sum_reward_utxos_metal's fail-loud-but-partial contract.
assert_eq "one good + one refused UTXO: partial total, split refused" \
	"50.500000000 - - 0 refused:undecodable" "$(printf '%s\n%s\n' "$SELF_K2" "$UTXO_WRONG_TYPE" | split_reward_utxos_metal 2>/dev/null)"

# m-2: a single output LARGER than the hint is just as much "not the self
# reward" as a smaller one — the comparison is equality, not ordering.
BIG_K2="$(build_utxo_hex 70000000000 7 2)"        # 70 METAL > hint 50.5
assert_eq "1 UTXO > potentialReward hint: self 0, fee = all (equality, not >=)" \
	"70.000000000 0.000000000 70.000000000 1 potential-reward-mismatch" "$(printf '%s\n' "$BIG_K2" | split_reward_utxos_metal 50500000000)"

echo ""
echo "=== split_reward_utxos_metal --assert-no-delegators ==="
# Under the operator's "no delegation existed" assertion, the cited source
# leaves ONE self output (commit) or ZERO outputs (abort) — anything else
# proves the assertion false and is refused outright.
assert_eq "flag, 1 UTXO, no hint: self = all, basis operator-asserted-no-delegators" \
	"50.500000000 50.500000000 0.000000000 1 operator-asserted-no-delegators" "$(printf '%s\n' "$SELF_K2" | split_reward_utxos_metal --assert-no-delegators)"
assert_eq "flag, 0 UTXOs: zero-outputs, known" \
	"0.000000000 0.000000000 0.000000000 1 zero-outputs" "$(printf '' | split_reward_utxos_metal --assert-no-delegators)"
assert_eq "flag, 2 UTXOs: assertion contradicted, refused (total kept)" \
	"62.750000000 - - 0 refused:no-delegators-contradicted" "$(printf '%s\n%s\n' "$SELF_K2" "$FEE_K3" | split_reward_utxos_metal --assert-no-delegators 2>/dev/null)"
assert_eq "flag, 3 UTXOs: assertion contradicted, refused" \
	"63.750000000 - - 0 refused:no-delegators-contradicted" "$(printf '%s\n%s\n%s\n' "$SELF_K2" "$FEE_K3" "$EXTRA_K4" | split_reward_utxos_metal --assert-no-delegators 2>/dev/null)"
assert_eq "flag + matching hint: chain evidence wins the basis (potential-reward-match)" \
	"50.500000000 50.500000000 0.000000000 1 potential-reward-match" "$(printf '%s\n' "$SELF_K2" | split_reward_utxos_metal 50500000000 --assert-no-delegators)"
assert_eq "flag + contradicting hint: refused (operator testimony vs chain evidence)" \
	"12.250000000 - - 0 refused:hint-contradicted" "$(printf '%s\n' "$FEE_K3" | split_reward_utxos_metal 50500000000 --assert-no-delegators 2>/dev/null)"
assert_eq "flag given before the hint is parsed the same way" \
	"50.500000000 50.500000000 0.000000000 1 potential-reward-match" "$(printf '%s\n' "$SELF_K2" | split_reward_utxos_metal --assert-no-delegators 50500000000)"

echo ""
echo "=== mutation kill check (split): the consecutive-index guard has teeth ==="
SPLIT_MUTANT="$(mktemp)"
sed 's/\[ "$((hi_idx - lo_idx))" -ne 1 \]/[ "0" -ne 0 ]/' "$LIB" > "$SPLIT_MUTANT"
if ! diff -q "$LIB" "$SPLIT_MUTANT" >/dev/null 2>&1; then
	SPLIT_MUTANT_OUT="$(
		# shellcheck disable=SC1090
		. "$SPLIT_MUTANT"
		printf '%s\n%s\n' "$SELF_K2" "$FEE_K5" | split_reward_utxos_metal
	)"
	if [ "$SPLIT_MUTANT_OUT" = "62.750000000 50.500000000 12.250000000 1 utxo-order" ]; then
		PASS=$((PASS + 1))
		echo "  PASS  mutant (consecutive-index guard disabled) SPLITS the (2,5) gap pair as if adjacent — the guard is load-bearing"
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("split mutation kill: mutant still refused the gap pair (out=$SPLIT_MUTANT_OUT)")
		echo "  FAIL  split mutant unexpectedly still refused: $SPLIT_MUTANT_OUT"
	fi
else
	FAIL=$((FAIL + 1))
	FAILURES+=("split mutation kill: sed did not change the file — guard not found at expected shape")
	echo "  FAIL  split mutant sed produced no diff — guard not matched"
fi
rm -f "$SPLIT_MUTANT"

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
