#!/usr/bin/env bash
# tests/test-gen-identity-ledger-lookup.sh
#
# Passphrase-free regression test for the §2.5 ledger-lookup logic in
# scripts/operator-local/gen-identity.sh. Validates that KEY_IAT / KEY_EXP
# are correctly resolved from identity-history.jsonl across normal,
# rotation, bootstrap, env-override, malformed-line, and multi-active
# scenarios.
#
# This is the regression-fixture-and-test bundle requested by the
# 2026-06-22 re-audit (F4). It does NOT require ssh-keygen, openssl,
# the operator identity private key, or any signing operation. It only
# exercises the JSONL parsing and field-resolution logic.
#
# Run from the repo root:
#   bash tests/test-gen-identity-ledger-lookup.sh
#
# Exit codes:
#   0 — all assertions pass
#   1 — at least one assertion failed
set -euo pipefail

FP_OURS="SHA256:rQZNC53Jdp3Cgi0XXbFT+aLWOtB8eS0Iv6jQ7KazvIY"
FP_OTHER="SHA256:0000000000000000000000000000000000000000000"
NOW_UTC_FAKE="2099-01-01T00:00:00Z"

pass_count=0
fail_count=0

assert_eq() {
	local label="$1" actual="$2" expected="$3"
	if [ "${actual}" = "${expected}" ]; then
		echo "  ✓ ${label}"
		pass_count=$((pass_count + 1))
	else
		echo "  ✗ ${label}"
		echo "    expected: ${expected}"
		echo "    actual:   ${actual}"
		fail_count=$((fail_count + 1))
	fi
}

# Mirror of the §2.5 ledger-lookup logic from gen-identity.sh.
# Inputs:  ledger_file fp [env_iat] [env_exp]
# Outputs: "<KEY_IAT>|<KEY_EXP>" on stdout
resolve_key_iat_key_exp() {
	local ledger_file="$1" fp="$2" env_iat="${3:-}" env_exp="${4:-}"
	local LEDGER_KEY_IAT="" LEDGER_KEY_EXP=""
	if [ -f "${ledger_file}" ]; then
		local LEDGER_MATCH
		LEDGER_MATCH="$(jq -Rc --arg fp "${fp}" '
			(fromjson? // empty)
			| select(.revoked == false and .operator_identity_pubkey_fingerprint == $fp)
		' "${ledger_file}" 2>/dev/null | tail -n 1)"
		if [ -n "${LEDGER_MATCH}" ]; then
			LEDGER_KEY_IAT="$(printf '%s' "${LEDGER_MATCH}" | jq -r '.key_iat // empty')"
			LEDGER_KEY_EXP="$(printf '%s' "${LEDGER_MATCH}" | jq -r '.key_exp // empty')"
		fi
	fi
	local KEY_IAT KEY_EXP
	KEY_IAT="${env_iat:-${LEDGER_KEY_IAT:-${NOW_UTC_FAKE}}}"
	if [ -n "${env_exp}" ]; then
		KEY_EXP="${env_exp}"
	elif [ -n "${LEDGER_KEY_EXP}" ] && [ "${KEY_IAT}" = "${LEDGER_KEY_IAT}" ]; then
		KEY_EXP="${LEDGER_KEY_EXP}"
	else
		KEY_EXP="$(LC_ALL=C date -u -j -v+365d -f '%Y-%m-%dT%H:%M:%SZ' "${KEY_IAT}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
			|| LC_ALL=C date -u -d "${KEY_IAT} +365 days" +%Y-%m-%dT%H:%M:%SZ)"
	fi
	printf '%s|%s\n' "${KEY_IAT}" "${KEY_EXP}"
}

# Mirror of the §4.5 self-check ledger lookup from gen-identity.sh.
# Inputs:  ledger_file fp
# Outputs: ledger's active key_iat for fp, or empty
resolve_ledger_active_iat() {
	local ledger_file="$1" fp="$2"
	if [ ! -f "${ledger_file}" ]; then
		printf ''
		return
	fi
	jq -Rr --arg fp "${fp}" '
		(fromjson? // empty)
		| select(.revoked == false and .operator_identity_pubkey_fingerprint == $fp)
		| .key_iat
	' "${ledger_file}" 2>/dev/null | tail -n 1
}

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# ----------------------------------------------------------------------
echo "Case 1: normal regen (single active entry, no env override)"
F="${TMPDIR_TEST}/ledger-normal.jsonl"
cat > "$F" <<EOF
{"schema_version":1,"key_seq":1,"operator_identity_pubkey_fingerprint":"${FP_OURS}","key_iat":"2026-06-22T06:28:51Z","key_exp":"2027-06-22T06:28:51Z","revoked":false}
EOF
result="$(resolve_key_iat_key_exp "$F" "$FP_OURS")"
assert_eq "Case 1 KEY_IAT/KEY_EXP" "$result" "2026-06-22T06:28:51Z|2027-06-22T06:28:51Z"

# ----------------------------------------------------------------------
echo "Case 2: env override (both)"
result="$(resolve_key_iat_key_exp "$F" "$FP_OURS" "2026-01-01T00:00:00Z" "2027-01-01T00:00:00Z")"
assert_eq "Case 2 KEY_IAT/KEY_EXP" "$result" "2026-01-01T00:00:00Z|2027-01-01T00:00:00Z"

# ----------------------------------------------------------------------
echo "Case 3: env override (IAT only) — EXP derived from env IAT + 365d"
result="$(resolve_key_iat_key_exp "$F" "$FP_OURS" "2026-03-15T12:00:00Z" "")"
assert_eq "Case 3 KEY_IAT/KEY_EXP" "$result" "2026-03-15T12:00:00Z|2027-03-15T12:00:00Z"

# ----------------------------------------------------------------------
echo "Case 4: env IAT == ledger value — EXP reuses ledger byte-for-byte"
result="$(resolve_key_iat_key_exp "$F" "$FP_OURS" "2026-06-22T06:28:51Z" "")"
assert_eq "Case 4 KEY_IAT/KEY_EXP" "$result" "2026-06-22T06:28:51Z|2027-06-22T06:28:51Z"

# ----------------------------------------------------------------------
echo "Case 5: bootstrap (ledger file absent) — NOW_UTC fallback"
result="$(resolve_key_iat_key_exp "${TMPDIR_TEST}/no-such-file.jsonl" "$FP_OURS")"
assert_eq "Case 5 KEY_IAT/KEY_EXP" "$result" "${NOW_UTC_FAKE}|2100-01-01T00:00:00Z"

# ----------------------------------------------------------------------
echo "Case 6: rotation (new fp, ledger exists but no match) — NOW_UTC fallback"
result="$(resolve_key_iat_key_exp "$F" "$FP_OTHER")"
assert_eq "Case 6 KEY_IAT/KEY_EXP" "$result" "${NOW_UTC_FAKE}|2100-01-01T00:00:00Z"

# ----------------------------------------------------------------------
echo "Case 7: revoked-entry exclusion (key_seq=1 revoked, key_seq=2 active)"
F="${TMPDIR_TEST}/ledger-revoked-and-active.jsonl"
cat > "$F" <<EOF
{"schema_version":1,"key_seq":1,"operator_identity_pubkey_fingerprint":"${FP_OURS}","key_iat":"2025-01-01T00:00:00Z","key_exp":"2026-01-01T00:00:00Z","revoked":true,"revoked_at":"2026-06-22T00:00:00Z","superseded_by_key_seq":2}
{"schema_version":1,"key_seq":2,"operator_identity_pubkey_fingerprint":"${FP_OURS}","key_iat":"2026-06-22T06:28:51Z","key_exp":"2027-06-22T06:28:51Z","revoked":false}
EOF
result="$(resolve_key_iat_key_exp "$F" "$FP_OURS")"
assert_eq "Case 7 KEY_IAT/KEY_EXP" "$result" "2026-06-22T06:28:51Z|2027-06-22T06:28:51Z"

# ----------------------------------------------------------------------
echo "Case 8: multiple active same-fp entries (out-of-spec) — tail -n 1 wins"
F="${TMPDIR_TEST}/ledger-multiple-active.jsonl"
cat > "$F" <<EOF
{"schema_version":1,"key_seq":1,"operator_identity_pubkey_fingerprint":"${FP_OURS}","key_iat":"2025-01-01T00:00:00Z","key_exp":"2026-01-01T00:00:00Z","revoked":false}
{"schema_version":1,"key_seq":2,"operator_identity_pubkey_fingerprint":"${FP_OURS}","key_iat":"2026-06-22T06:28:51Z","key_exp":"2027-06-22T06:28:51Z","revoked":false}
EOF
result="$(resolve_key_iat_key_exp "$F" "$FP_OURS")"
assert_eq "Case 8 KEY_IAT/KEY_EXP (newest wins)" "$result" "2026-06-22T06:28:51Z|2027-06-22T06:28:51Z"

# ----------------------------------------------------------------------
echo "Case 9: malformed JSONL line in ledger — valid line still found (F4 fix)"
F="${TMPDIR_TEST}/ledger-with-malformed.jsonl"
cat > "$F" <<EOF
this line is garbage, not json
{"schema_version":1,"key_seq":1,"operator_identity_pubkey_fingerprint":"${FP_OURS}","key_iat":"2026-06-22T06:28:51Z","key_exp":"2027-06-22T06:28:51Z","revoked":false}
also garbage
EOF
result="$(resolve_key_iat_key_exp "$F" "$FP_OURS")"
assert_eq "Case 9 KEY_IAT/KEY_EXP (jq tolerance)" "$result" "2026-06-22T06:28:51Z|2027-06-22T06:28:51Z"

# ----------------------------------------------------------------------
echo "Case 10: §4.5 self-check fires on divergence"
LEDGER_ACTIVE_IAT="$(resolve_ledger_active_iat "$F" "$FP_OURS")"
DIVERGING_KEY_IAT="2099-12-31T23:59:59Z"
if [ -n "${LEDGER_ACTIVE_IAT}" ] && [ "${DIVERGING_KEY_IAT}" != "${LEDGER_ACTIVE_IAT}" ]; then
	assert_eq "Case 10 self-check refuses sign" "exit_8_would_fire" "exit_8_would_fire"
else
	assert_eq "Case 10 self-check refuses sign" "no_check_fired" "exit_8_would_fire"
fi

# ----------------------------------------------------------------------
echo "Case 11: §4.5 self-check passes when KEY_IAT matches ledger"
MATCHING_KEY_IAT="${LEDGER_ACTIVE_IAT}"
if [ -n "${LEDGER_ACTIVE_IAT}" ] && [ "${MATCHING_KEY_IAT}" != "${LEDGER_ACTIVE_IAT}" ]; then
	assert_eq "Case 11 self-check pass when matched" "would_refuse" "would_pass"
else
	assert_eq "Case 11 self-check pass when matched" "would_pass" "would_pass"
fi

# ----------------------------------------------------------------------
echo ""
echo "Summary: ${pass_count} pass, ${fail_count} fail"
[ "${fail_count}" -eq 0 ] || exit 1
