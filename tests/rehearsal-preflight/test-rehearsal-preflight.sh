#!/usr/bin/env bash
# test-rehearsal-preflight.sh — suite for scripts/install-rehearsal-preflight.sh.
#
# CHAIN: none. Every case runs the pre-flight against a throwaway fixture
#        tree with a STUBBED `proton` (so the real project keystore is never
#        touched, locked or unlocked) and a STUBBED curl for the one chain
#        call. Every published-artifact URL is overridden to a LOCAL PATH, so
#        no case in this suite performs any network I/O at all.
#
# WHAT THIS SUITE IS FOR. A pre-flight that has never been observed to go red
# is a pre-flight nobody should trust: its whole value is the claim "if a
# precondition is broken, this refuses". So each check is BROKEN ON PURPOSE,
# one at a time, from an otherwise all-green fixture, and the suite asserts
# both the exit code and that the failure is attributed to the right check.
# The all-green baseline is asserted first, which is what makes each mutation
# attributable: without it, a red could come from the fixture rather than the
# mutation.
#
# Usage:
#   bash tests/rehearsal-preflight/test-rehearsal-preflight.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFLIGHT="${REPO_ROOT}/scripts/install-rehearsal-preflight.sh"
PUBKEY_HELPER="${REPO_ROOT}/scripts/lib/eosio-pubkey-raw-hex.js"
CANONICAL="${REPO_ROOT}/public/api/anchor-source.json"

for f in "$PREFLIGHT" "$PUBKEY_HELPER"; do
	[ -r "$f" ] || { echo "FATAL: expected file missing: $f" >&2; exit 1; }
done
for t in node jq git ssh-keygen; do
	command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t required for this suite" >&2; exit 1; }
done

# Absolute path to timeout(1), captured BEFORE any case rewrites PATH. One
# case deliberately runs the pre-flight on a PATH with no `timeout` on it; if
# the harness itself resolved `timeout` from that PATH, the case would die
# with 127 before the pre-flight ever ran and would prove nothing.
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"
[ -n "$TIMEOUT_BIN" ] || { echo "FATAL: timeout(1) required for this suite" >&2; exit 1; }

PASS=0
FAIL=0
pass() { printf 'PASS  %-72s%s\n' "$1" "${2:+ ($2)}"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %-72s%s\n' "$1" "${2:+ ($2)}" >&2; FAIL=$((FAIL + 1)); }

BASE="$(mktemp -d -t fya-preflight-suite.XXXXXX)"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Synthetic key material. Fabricated bytes only — this repo's sanitize policy
# forbids a real on-chain public key in a fixture, testnet included. The pair
# below is the SAME key in the two encodings the chain and the keystore use,
# which is exactly the cross-format comparison check 9 has to get right.
# ---------------------------------------------------------------------------
SYNTH_EOS="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("02"+"5c".repeat(32),"hex"), "EOS"));
' "$PUBKEY_HELPER")"
SYNTH_K1="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("02"+"5c".repeat(32),"hex"), "PUB_K1_"));
' "$PUBKEY_HELPER")"
OTHER_K1="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("03"+"a7".repeat(32),"hex"), "PUB_K1_"));
' "$PUBKEY_HELPER")"
if [ -z "$SYNTH_EOS" ] || [ -z "$SYNTH_K1" ] || [ -z "$OTHER_K1" ]; then
	echo "FATAL: could not build synthetic key fixtures" >&2
	exit 1
fi

# The cycle number is read LIVE from the canonical anchor-source, never
# hardcoded: that file advances at every transition, and a pinned number here
# would go stale for precisely the reason the pre-flight exists.
CYCLE="$(jq -r '.observations_branch.cycle_number_observed // empty' "$CANONICAL" 2>/dev/null)"
if ! printf '%s' "$CYCLE" | grep -qE '^[0-9]+$'; then
	echo "FATAL: canonical anchor-source has no cycle_number_observed" >&2
	exit 1
fi
CLOSED=$((CYCLE - 1))

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
STUB="${BASE}/bin"
mkdir -p "$STUB"

# proton stub. Modes are selected per-case via FYP_TEST_PROTON_MODE.
# `locked` returns 124 = what `timeout` returns when a locked keystore hangs
# on the passphrase prompt; `failed` returns a plain non-zero, the other
# observed locked-keystore shape.
cat > "${STUB}/proton" <<'PROTON_STUB'
#!/usr/bin/env bash
# Record the full argv of every invocation. The suite asserts on this log
# rather than on a grep of the script's text: a printed remedy line and an
# executed command look identical to grep, and only one of them is a
# keystore operation.
[ -n "${FYP_TEST_PROTON_LOG:-}" ] && printf '%s\n' "$*" >> "$FYP_TEST_PROTON_LOG"
MODE="${FYP_TEST_PROTON_MODE:-list}"
case "$1" in
	key:list)
		case "$MODE" in
			locked) exit 124 ;;
			failed) exit 3 ;;
			empty)  echo '[]' ; exit 0 ;;
			*)      cat "${FYP_TEST_PROTON_KEYS:-/dev/null}" ; exit 0 ;;
		esac ;;
	account)
		# The rehearsal's SECOND lock probe. A keystore can list keys and
		# still refuse a signing-adjacent read, which is the exact state the
		# pre-flight has to catch before the operator is called.
		case "$MODE" in
			acctfail) exit 1 ;;
			accthang) exit 124 ;;
			*)        echo '{"account_name":"stub"}' ; exit 0 ;;
		esac ;;
	*)  echo "stub proton: unexpected subcommand: $*" >&2 ; exit 90 ;;
esac
PROTON_STUB
chmod +x "${STUB}/proton"

# curl stub for the single chain call (get_account). Every published-artifact
# read is pointed at a local path instead, so this stub is the only network
# surface the pre-flight has and it is fully synthetic here.
cat > "${STUB}/curl-stub" <<'CURL_STUB'
#!/usr/bin/env bash
[ "${FYP_TEST_CURL_FAIL:-0}" = "1" ] && { echo "stub: simulated transport failure" >&2; exit 7; }
cat "${FYP_TEST_ACCOUNT_JSON:-/dev/null}"
CURL_STUB
chmod +x "${STUB}/curl-stub"

cat > "${STUB}/gtimeout" <<'GT_STUB'
#!/usr/bin/env bash
exec "$@"
GT_STUB
chmod +x "${STUB}/gtimeout"

# ---------------------------------------------------------------------------
# Fixture tree
# ---------------------------------------------------------------------------
# Fictional account names throughout (sanitize policy: never a real on-chain
# account name in a fixture, testnet included).
make_fixture() { # <dir>
	local d="$1" i
	mkdir -p "$d/ks-test" "$d/ks-main" "$d/rehearsal-config" "$d/mainnet-config"

	printf 'testactor11\n' > "$d/rehearsal-config/xpr-account"
	printf 'testsink111\n' > "$d/rehearsal-config/anchor-sink"
	printf 'proton-test\n' > "$d/rehearsal-config/xpr-chain"

	printf 'mainactor11\n' > "$d/mainnet-config/xpr-account"
	printf 'mainsink111\n' > "$d/mainnet-config/anchor-sink"
	printf '0.0001 XPR\n'  > "$d/mainnet-config/xpr-quantity"

	ssh-keygen -t ed25519 -N '' -C 'fyd-preflight-test-fixture' -f "$d/id_key" -q </dev/null
	chmod 600 "$d/id_key"

	# cycle-history: CLOSED contiguous rows, so fyc_closed_cycle_count agrees
	# with itself across all three idioms it cross-checks.
	: > "$d/cycle-history.jsonl"
	i=1
	while [ "$i" -le "$CLOSED" ]; do
		printf '{"cycle_n":%d,"start_iso":"2026-01-%02dT00:00:00Z","end_iso":"2026-02-%02dT00:00:00Z"}\n' \
			"$i" "$i" "$i" >> "$d/cycle-history.jsonl"
		i=$((i + 1))
	done

	# anchor-source: the canonical bytes verbatim, so check 6's committed-bytes
	# guard passes against this repo's own HEAD blob.
	cp "$CANONICAL" "$d/anchor-source.json"
	cp "$CANONICAL" "$d/published-anchor-source.json"

	# anchor-history: newest row = the cycle already inscribed = $CYCLE, which
	# makes the baseline a DRESS run.
	printf '{"cycle_number":%d,"event_type":"cyclestart"}\n' "$CYCLE" > "$d/anchor-history.jsonl"

	# validator.json: registered period ends far in the future.
	printf '{"endTime":%d,"startTime":%d}\n' 4102444800 4070908800 > "$d/validator.json"

	# get_account response carrying the synthetic anchor key.
	jq -nc --arg a testactor11 --arg k "$SYNTH_EOS" \
		'{account_name:$a,permissions:[{perm_name:"owner",required_auth:{keys:[]}},{perm_name:"anchor",required_auth:{keys:[{key:$k}]}}]}' \
		> "$d/account.json"

	# proton key:list output: the same key in the OTHER encoding, plus noise.
	printf '%s\n%s\n' "$OTHER_K1" "$SYNTH_K1" > "$d/keys.txt"
}

GOOD="${BASE}/good"
make_fixture "$GOOD"

# fresh <name> — a private copy of the good fixture, for one mutation.
fresh() {
	local d="${BASE}/case-$1"
	rm -rf "$d"
	cp -Rp "$GOOD" "$d"
	printf '%s' "$d"
}

# run_pf <fixture-dir> [extra args…] — run the pre-flight against a fixture.
# Env is set inline so each case is independent; PATH is prepended with the
# stub dir so the real proton binary is unreachable from every case.
run_pf() {
	local d="$1"
	shift
	local expect="${PF_EXPECT_CYCLE:-$CYCLE}"
	local src="${PF_SOURCE:-$d/anchor-source.json}"
	env PATH="${STUB}:${PATH}" \
		HOME="${PF_HOME:-$d/ks-test}" \
		FYP_KEYSTORE_TESTNET="${PF_KS_TEST:-$d/ks-test}" \
		FYP_KEYSTORE_MAINNET="${PF_KS_MAIN:-$d/ks-main}" \
		FYP_REHEARSAL_CFG="$d/rehearsal-config" \
		FYP_MAINNET_CFG="$d/mainnet-config" \
		FYP_IDENTITY_KEY="$d/id_key" \
		FYP_LEDGER_URL="${PF_LEDGER:-$d/cycle-history.jsonl}" \
		FYP_ANCHOR_SOURCE_URL="${PF_PUB_SRC:-$d/published-anchor-source.json}" \
		FYP_ANCHOR_HISTORY_URL="${PF_HISTORY:-$d/anchor-history.jsonl}" \
		FYP_VALIDATOR_URL="${PF_VALIDATOR:-$d/validator.json}" \
		FYP_CURL="${STUB}/curl-stub" \
		FYP_TEST_ACCOUNT_JSON="${PF_ACCOUNT:-$d/account.json}" \
		FYP_TEST_PROTON_KEYS="${PF_KEYS:-$d/keys.txt}" \
		FYP_TEST_PROTON_MODE="${PF_PROTON_MODE:-list}" \
		FYP_TEST_PROTON_LOG="${PF_PROTON_LOG:-}" \
		FYP_TEST_CURL_FAIL="${PF_CURL_FAIL:-0}" \
		"$TIMEOUT_BIN" 60 bash "$PREFLIGHT" --expect-cycle="$expect" --source="$src" "$@" </dev/null 2>&1
}

# expect_case <label> <fixture> <want-rc> <must-contain> [must-not-contain]
expect_case() {
	local label="$1" d="$2" want="$3" needle="$4" anti="${5:-}"
	local out rc
	out="$(run_pf "$d")"; rc=$?
	if [ "$rc" -ne "$want" ]; then
		bad "$label" "rc=$rc want=$want | $(printf '%s' "$out" | grep -E '^(  FAIL|VERDICT)' | tr '\n' ' ' | cut -c1-160)"
		return
	fi
	if ! printf '%s' "$out" | grep -qF "$needle"; then
		bad "$label" "rc ok but missing text: $needle"
		return
	fi
	if [ -n "$anti" ] && printf '%s' "$out" | grep -qF "$anti"; then
		bad "$label" "rc ok but found forbidden text: $anti"
		return
	fi
	pass "$label" "rc=$rc"
}

# ===========================================================================
# Part 1 — the all-green baseline (what makes every mutation attributable)
# ===========================================================================
BASE_OUT="$(run_pf "$GOOD")"; BASE_RC=$?
if [ "$BASE_RC" -eq 0 ] \
   && printf '%s' "$BASE_OUT" | grep -qF "VERDICT: PRE-FLIGHT GREEN" \
   && [ "$(printf '%s' "$BASE_OUT" | grep -c '^  PASS  \[')" -eq 9 ] \
   && ! printf '%s' "$BASE_OUT" | grep -q '^  FAIL  \['; then
	pass "baseline: all nine checks PASS on a good fixture" "rc=$BASE_RC"
else
	bad "baseline: all nine checks PASS on a good fixture" \
		"rc=$BASE_RC passes=$(printf '%s' "$BASE_OUT" | grep -c '^  PASS  \[') $(printf '%s' "$BASE_OUT" | grep '^  FAIL' | tr '\n' ' ')"
fi

if printf '%s' "$BASE_OUT" | grep -qF "classification: DRESS" \
   && printf '%s' "$BASE_OUT" | grep -qF "DRESS REHEARSAL — the resulting tx is NOT gate-1 evidence"; then
	pass "baseline: an already-inscribed cycle is classified DRESS, loudly"
else
	bad "baseline: an already-inscribed cycle is classified DRESS, loudly"
fi

# On a dress run the --status pointer must be a WARNING, not an instruction:
# measured 2026-08-17, --status with the sibling value answers COMPLETE about
# the PREVIOUS transition, which reads like confirmation of a pending one.
if printf '%s' "$BASE_OUT" | grep -qF "Do NOT reach for scripts/cycle-transition.sh --status" \
   && ! printf '%s' "$BASE_OUT" | grep -qF "Cross-check with: scripts/cycle-transition.sh"; then
	pass "baseline: a dress run warns about --status instead of recommending it"
else
	bad "baseline: a dress run warns about --status instead of recommending it"
fi

# The meaning switch must be flagged on every run, but WITHOUT a number: on a
# dress run "M-1" is last month's cycle wearing a "today" label, and that label
# is the entry point to a double-inscription (see the script header). The
# number itself belongs to check 8, after classification.
if printf '%s' "$BASE_OUT" | grep -qF "paired flag:" \
   && printf '%s' "$BASE_OUT" | grep -qF "is a DIFFERENT number" \
   && ! printf '%s' "$BASE_OUT" | grep -qF "sibling value:" \
   && ! printf '%s' "$BASE_OUT" | grep -qF "for the same day would be"; then
	pass "baseline: the meaning switch is flagged in the banner, without a number"
else
	bad "baseline: the meaning switch is flagged in the banner, without a number"
fi

# ===========================================================================
# Part 2 — usage
# ===========================================================================
U_OUT="$(env PATH="${STUB}:${PATH}" HOME="${GOOD}/ks-test" FYP_KEYSTORE_TESTNET="${GOOD}/ks-test" \
	bash "$PREFLIGHT" </dev/null 2>&1)"; U_RC=$?
if [ "$U_RC" -eq 1 ] && printf '%s' "$U_OUT" | grep -qF -- "--expect-cycle=<M> is required"; then
	pass "usage: no --expect-cycle -> exit 1"
else
	bad "usage: no --expect-cycle -> exit 1" "rc=$U_RC"
fi

# The accepted form is a POSITIVE integer with no leading zero: cycle
# numbering starts at 1, and "010" would be read as octal by $(( )) later.
for badval in not-a-number 0 007 -1 " "; do
	PF_EXPECT_CYCLE="$badval" ; export PF_EXPECT_CYCLE
	N_OUT="$(run_pf "$GOOD")"; N_RC=$?
	unset PF_EXPECT_CYCLE
	if [ "$N_RC" -eq 1 ] \
	   && { printf '%s' "$N_OUT" | grep -qF "must be a positive integer" \
	        || printf '%s' "$N_OUT" | grep -qF "is required"; }; then
		pass "usage: --expect-cycle='${badval}' -> exit 1"
	else
		bad "usage: --expect-cycle='${badval}' -> exit 1" "rc=$N_RC"
	fi
done

ES_OUT="$(run_pf "$GOOD" --source=)"; ES_RC=$?
if [ "$ES_RC" -eq 1 ] && printf '%s' "$ES_OUT" | grep -qF "given with an empty value"; then
	pass "usage: --source= with an empty value -> exit 1, not a silent default"
else
	bad "usage: --source= with an empty value -> exit 1, not a silent default" "rc=$ES_RC"
fi

B_OUT="$(run_pf "$GOOD" --bogus-flag-xyz)"; B_RC=$?
if [ "$B_RC" -eq 1 ] && printf '%s' "$B_OUT" | grep -qF "unknown arg"; then
	pass "usage: unknown flag -> exit 1"
else
	bad "usage: unknown flag -> exit 1" "rc=$B_RC"
fi

H_OUT="$(env PATH="${STUB}:${PATH}" HOME="${GOOD}/ks-test" bash "$PREFLIGHT" --help </dev/null 2>&1)"; H_RC=$?
if [ "$H_RC" -eq 0 ] \
   && printf '%s' "$H_OUT" | grep -qF "the cycle CLOSING today" \
   && printf '%s' "$H_OUT" | grep -qF "the cycle being" \
   && printf '%s' "$H_OUT" | grep -qF "IT INSTALLS NOTHING"; then
	pass "usage: --help documents both meanings and the no-op nature"
else
	bad "usage: --help documents both meanings and the no-op nature" "rc=$H_RC"
fi

# --help must print the header to its END, not to a hardcoded line number.
# The last paragraph of that header is the limits section, which is the part
# a truncation would silently drop and the part a reader least affords to lose.
# `sed -E 's/^# ?//'` here too, matching what the script now does. The old
# form used the GNU-only `\?`, which BSD sed leaves literal — and because BOTH
# sides used it, the substring pin below matched a still-prefixed line and the
# defect was structurally invisible. That is M1.
HDR_LAST="$(awk 'NR>1 { if ($0 ~ /^#/) last=$0; else if ($0 != "") exit } END{print last}' "$PREFLIGHT" | sed -E 's/^# ?//')"
if [ "$H_RC" -eq 0 ] && [ "$(printf '%s\n' "$H_OUT" | grep -c '^# ')" -eq 0 ]; then
	pass "usage: --help strips the comment markers (BSD sed safe)"
else
	bad "usage: --help strips the comment markers (BSD sed safe)" \
		"$(printf '%s\n' "$H_OUT" | grep -c '^# ') line(s) still start with '# '"
fi
if [ -n "$HDR_LAST" ] && printf '%s' "$H_OUT" | grep -qF "$HDR_LAST"; then
	pass "usage: --help prints the header through its final line" "last=[${HDR_LAST:0:40}…]"
else
	bad "usage: --help prints the header through its final line" "missing: [$HDR_LAST]"
fi

# ===========================================================================
# Part 3 — check 2 / the §3.5 keystore guard (mutations)
# ===========================================================================
D="$(fresh home-unset)"
UH_OUT="$(env -u HOME PATH="${STUB}:${PATH}" FYP_KEYSTORE_TESTNET="$D/ks-test" \
	bash "$PREFLIGHT" --expect-cycle="$CYCLE" </dev/null 2>&1)"; UH_RC=$?
if [ "$UH_RC" -eq 8 ] && printf '%s' "$UH_OUT" | grep -qF "§3.5"; then
	pass "check 2: unset HOME -> exit 8 (§3.5)"
else
	bad "check 2: unset HOME -> exit 8 (§3.5)" "rc=$UH_RC"
fi

D="$(fresh home-mainnet)"
PF_HOME="$D/ks-main"; export PF_HOME
M_OUT="$(run_pf "$D")"; M_RC=$?
unset PF_HOME
if [ "$M_RC" -eq 8 ] && printf '%s' "$M_OUT" | grep -qF "That is the MAINNET keystore"; then
	pass "check 2: HOME pointed at the MAINNET keystore -> exit 8, named as such"
else
	bad "check 2: HOME pointed at the MAINNET keystore -> exit 8, named as such" "rc=$M_RC"
fi

D="$(fresh keystores-same)"
PF_KS_MAIN="$D/ks-test"; export PF_KS_MAIN
S_OUT="$(run_pf "$D")"; S_RC=$?
unset PF_KS_MAIN
if [ "$S_RC" -eq 8 ] && printf '%s' "$S_OUT" | grep -qF "testnet-and-mainnet-keystores-are-the-same-dir"; then
	pass "check 2: one dir serving both networks -> exit 8"
else
	bad "check 2: one dir serving both networks -> exit 8" "rc=$S_RC"
fi

D="$(fresh keystore-missing)"
rm -rf "$D/ks-main"
expect_case "check 2: mainnet keystore dir absent -> exit 8" "$D" 8 "mainnet-keystore-dir-missing"

# ===========================================================================
# Part 4 — check 1 / prerequisite tools (mutation via a constructed PATH)
# ===========================================================================
# A constructed PATH is the only way to make a tool genuinely absent. It is
# built twice: once COMPLETE (which must reproduce the green baseline, proving
# the list is sufficient and therefore that the omission below is what caused
# the red), and once missing `timeout` while `gtimeout` is present — the state
# that reads like success and is not.
MINI="${BASE}/mini-bin"
mkdir -p "$MINI"
MINI_TOOLS="sh bash env sed grep egrep jq git node curl ssh-keygen ssh-add timeout date mktemp cat tr cut sort tail head awk cmp ls wc rm id dirname basename uname sha256sum shasum expr"
for t in $MINI_TOOLS; do
	p="$(command -v "$t" 2>/dev/null)" || continue
	[ -n "$p" ] && ln -sf "$p" "${MINI}/${t}" 2>/dev/null
done
ln -sf "${STUB}/proton"     "${MINI}/proton"
ln -sf "${STUB}/curl-stub"  "${MINI}/curl-stub"

run_pf_path() { # <fixture> <path>
	local d="$1" p="$2"
	env PATH="$p" HOME="$d/ks-test" \
		FYP_KEYSTORE_TESTNET="$d/ks-test" FYP_KEYSTORE_MAINNET="$d/ks-main" \
		FYP_REHEARSAL_CFG="$d/rehearsal-config" FYP_MAINNET_CFG="$d/mainnet-config" \
		FYP_IDENTITY_KEY="$d/id_key" \
		FYP_LEDGER_URL="$d/cycle-history.jsonl" \
		FYP_ANCHOR_SOURCE_URL="$d/published-anchor-source.json" \
		FYP_ANCHOR_HISTORY_URL="$d/anchor-history.jsonl" \
		FYP_VALIDATOR_URL="$d/validator.json" \
		FYP_CURL="${STUB}/curl-stub" \
		FYP_TEST_ACCOUNT_JSON="$d/account.json" FYP_TEST_PROTON_KEYS="$d/keys.txt" \
		"$TIMEOUT_BIN" 60 bash "$PREFLIGHT" --expect-cycle="$CYCLE" --source="$d/anchor-source.json" </dev/null 2>&1
}

D="$(fresh path-complete)"
PC_OUT="$(run_pf_path "$D" "$MINI")"; PC_RC=$?
if [ "$PC_RC" -eq 0 ] && printf '%s' "$PC_OUT" | grep -qF "VERDICT: PRE-FLIGHT GREEN"; then
	pass "check 1: the constructed PATH is complete (baseline reproduces green)"
else
	bad "check 1: the constructed PATH is complete (baseline reproduces green)" \
		"rc=$PC_RC — the omission case below would not be attributable | $(printf '%s' "$PC_OUT" | grep '^  FAIL' | tr '\n' ' ')"
fi

NO_TIMEOUT="${BASE}/no-timeout-bin"
mkdir -p "$NO_TIMEOUT"
for l in "$MINI"/*; do
	case "$(basename "$l")" in timeout) continue ;; esac
	ln -sf "$(readlink "$l" 2>/dev/null || printf '%s' "$l")" "${NO_TIMEOUT}/$(basename "$l")" 2>/dev/null
done
ln -sf "${STUB}/gtimeout" "${NO_TIMEOUT}/gtimeout"
D="$(fresh path-no-timeout)"
NT_OUT="$(run_pf_path "$D" "$NO_TIMEOUT")"; NT_RC=$?
if [ "$NT_RC" -eq 2 ] \
   && printf '%s' "$NT_OUT" | grep -qF "missing: timeout" \
   && printf '%s' "$NT_OUT" | grep -qF "gtimeout IS present but the bare name"; then
	pass "check 1: gtimeout present but bare 'timeout' absent -> exit 2, named"
else
	bad "check 1: gtimeout present but bare 'timeout' absent -> exit 2, named" "rc=$NT_RC"
fi

# ===========================================================================
# Part 5 — checks 3/4/5 (operator-local config and key mutations)
# ===========================================================================
D="$(fresh rh-missing-file)"; rm -f "$D/rehearsal-config/xpr-chain"
expect_case "check 3: rehearsal config missing a file -> exit 3" "$D" 3 "missing:xpr-chain"

D="$(fresh rh-wrong-chain)"; printf 'proton\n' > "$D/rehearsal-config/xpr-chain"
expect_case "check 3: rehearsal xpr-chain not proton-test -> exit 3" "$D" 3 "xpr-chain-is-not-proton-test"

D="$(fresh rh-self-sink)"; cp "$D/rehearsal-config/xpr-account" "$D/rehearsal-config/anchor-sink"
expect_case "check 3: sink equals actor (BLOCK-1) -> exit 3" "$D" 3 "sink-equals-account(BLOCK-1)"

D="$(fresh mn-missing-sink)"; rm -f "$D/mainnet-config/anchor-sink"
expect_case "check 4: mainnet config missing anchor-sink -> exit 3" "$D" 3 "missing:anchor-sink"

D="$(fresh mn-no-quantity)"; rm -f "$D/mainnet-config/xpr-quantity"
Q_OUT="$(run_pf "$D")"; Q_RC=$?
if [ "$Q_RC" -eq 0 ] && printf '%s' "$Q_OUT" | grep -qF "xpr-quantity absent"; then
	pass "check 4: absent xpr-quantity is reported but NOT a failure (it has a default)" "rc=$Q_RC"
else
	bad "check 4: absent xpr-quantity is reported but NOT a failure (it has a default)" "rc=$Q_RC"
fi

D="$(fresh id-mode)"; chmod 644 "$D/id_key"
expect_case "check 5: identity private key not mode 600 -> exit 3" "$D" 3 "private-key-mode-not-600"

D="$(fresh id-nopub)"; rm -f "$D/id_key.pub"
expect_case "check 5: identity public key absent -> exit 3" "$D" 3 "missing-public-key"

# ===========================================================================
# Part 6 — check 6 (anchor-source bytes)
# ===========================================================================
D="$(fresh src-uncommitted)"
jq '.computed_at = "1999-01-01T00:00:00Z"' "$D/anchor-source.json" > "$D/mutated.json"
PF_SOURCE="$D/mutated.json"; export PF_SOURCE
SU_OUT="$(run_pf "$D")"; SU_RC=$?
unset PF_SOURCE
if [ "$SU_RC" -eq 5 ] && printf '%s' "$SU_OUT" | grep -qF "NOT byte-identical to git show HEAD:"; then
	pass "check 6: --source differing from the committed blob -> exit 5" "rc=$SU_RC"
else
	bad "check 6: --source differing from the committed blob -> exit 5" "rc=$SU_RC"
fi

D="$(fresh pub-stale)"
jq '.dag_root_computed = "00000000000000000000000000000000000000000000000000000000deadbeef"' \
	"$D/published-anchor-source.json" > "$D/pub2.json" && mv "$D/pub2.json" "$D/published-anchor-source.json"
expect_case "check 6: published dag_root != committed -> exit 5" "$D" 5 "published dag_root_computed"

D="$(fresh pub-gone)"; rm -f "$D/published-anchor-source.json"
expect_case "check 6: published anchor-source unfetchable -> exit 9 (inconclusive)" "$D" 9 "could not fetch the published anchor-source"

# ===========================================================================
# Part 7 — check 7 (ledger vs anchor-source vs --expect-cycle)
# ===========================================================================
D="$(fresh ledger-behind)"
PF_EXPECT_CYCLE="$((CYCLE + 1))"; export PF_EXPECT_CYCLE
LB_OUT="$(run_pf "$D")"; LB_RC=$?
unset PF_EXPECT_CYCLE
if [ "$LB_RC" -eq 6 ] \
   && printf '%s' "$LB_OUT" | grep -qF "the number to inscribe is ${CYCLE}" \
   && printf '%s' "$LB_OUT" | grep -qF "runs AFTER the day's recompose+publish"; then
	pass "check 7: day-of number declared before phase 1 landed -> exit 6" "rc=$LB_RC"
else
	bad "check 7: day-of number declared before phase 1 landed -> exit 6" "rc=$LB_RC"
fi

# The ledger agrees with --expect-cycle but the anchor-source does not: this
# is the exact refusal run-testnet-rehearsal.sh makes at step 1/10, moved
# earlier.
D="$(fresh src-cycle-drift)"
jq --argjson c "$((CYCLE + 5))" '.observations_branch.cycle_number_observed = $c' \
	"$GOOD/anchor-source.json" > "$D/drift.json"
DR_OUT="$(env PATH="${STUB}:${PATH}" HOME="$D/ks-test" \
	FYP_KEYSTORE_TESTNET="$D/ks-test" FYP_KEYSTORE_MAINNET="$D/ks-main" \
	FYP_REHEARSAL_CFG="$D/rehearsal-config" FYP_MAINNET_CFG="$D/mainnet-config" \
	FYP_IDENTITY_KEY="$D/id_key" FYP_LEDGER_URL="$D/cycle-history.jsonl" \
	FYP_ANCHOR_SOURCE_URL="$D/drift.json" FYP_ANCHOR_HISTORY_URL="$D/anchor-history.jsonl" \
	FYP_VALIDATOR_URL="$D/validator.json" FYP_CURL="${STUB}/curl-stub" \
	FYP_TEST_ACCOUNT_JSON="$D/account.json" FYP_TEST_PROTON_KEYS="$D/keys.txt" \
	"$TIMEOUT_BIN" 60 bash "$PREFLIGHT" --expect-cycle="$CYCLE" --source="$D/drift.json" </dev/null 2>&1)"; DR_RC=$?
# The mutated source also stops matching HEAD, so check 6 fires first (exit
# 5) — the assertion is that the drift is REPORTED by check 7 in the same
# run, which is what "one run shows every problem" has to mean.
if [ "$DR_RC" -eq 5 ] && printf '%s' "$DR_OUT" | grep -qF "FAIL  [7]"; then
	pass "check 7: anchor-source cycle drift is reported alongside check 6" "rc=$DR_RC"
else
	bad "check 7: anchor-source cycle drift is reported alongside check 6" "rc=$DR_RC"
fi

D="$(fresh ledger-gone)"; rm -f "$D/cycle-history.jsonl"
expect_case "check 7: ledger unfetchable -> exit 9 (inconclusive)" "$D" 9 "could not fetch the published cycle-history ledger"

D="$(fresh ledger-gap)"
printf '{"cycle_n":%d,"start_iso":"2026-03-01T00:00:00Z","end_iso":"2026-03-02T00:00:00Z"}\n' "$((CYCLE + 9))" \
	>> "$D/cycle-history.jsonl"
expect_case "check 7: non-contiguous ledger -> refused, exit 6" "$D" 6 "cycle-context refused"

# ===========================================================================
# Part 8 — check 8 (already-inscribed anchor ledger)
# ===========================================================================
D="$(fresh dayof)"
printf '{"cycle_number":%d,"event_type":"cyclestart"}\n' "$((CYCLE - 1))" > "$D/anchor-history.jsonl"
DO_OUT="$(run_pf "$D")"; DO_RC=$?
if [ "$DO_RC" -eq 0 ] \
   && printf '%s' "$DO_OUT" | grep -qF "classification: DAY-OF" \
   && printf '%s' "$DO_OUT" | grep -qF "the resulting tx IS the mainnet gate-1 input"; then
	pass "check 8: nothing inscribed for this cycle yet -> DAY-OF" "rc=$DO_RC"
else
	bad "check 8: nothing inscribed for this cycle yet -> DAY-OF" "rc=$DO_RC"
fi
if printf '%s' "$DO_OUT" | grep -qF "Cross-check with: scripts/cycle-transition.sh --status --expect-cycle=$((CYCLE - 1))" \
   && ! printf '%s' "$DO_OUT" | grep -qF "Do NOT reach for scripts/cycle-transition.sh"; then
	pass "check 8: on a DAY-OF run --status IS recommended, with the -1 value"
else
	bad "check 8: on a DAY-OF run --status IS recommended, with the -1 value"
fi
# On DAY-OF the pairing IS M-1 and check 8 says so — the one branch on which
# that arithmetic is true.
if printf '%s' "$DO_OUT" | grep -qF "pairing: the cycle CLOSING today is $((CYCLE - 1))" \
   && ! printf '%s' "$DO_OUT" | grep -qF "NO cycle closes today"; then
	pass "check 8: DAY-OF states the pairing as the cycle closing today"
else
	bad "check 8: DAY-OF states the pairing as the cycle closing today"
fi

D="$(fresh hist-far-behind)"
printf '{"cycle_number":%d,"event_type":"cyclestart"}\n' "$((CYCLE - 3))" > "$D/anchor-history.jsonl"
expect_case "check 8: --expect-cycle neither inscribed nor next -> exit 6" "$D" 6 "is neither the last inscribed cycle"

# The narrow refusal: the registered period has ended and the anchor ledger
# has not advanced past it, so the declared number is the closing cycle's.
D="$(fresh period-ended)"
printf '{"endTime":%d,"startTime":%d}\n' 1000000000 900000000 > "$D/validator.json"
expect_case "check 8: period already ended + cycle already inscribed -> exit 6" "$D" 6 \
	"belongs to the cycle that just closed"

D="$(fresh hist-gone)"; rm -f "$D/anchor-history.jsonl"
expect_case "check 8: anchor-history unfetchable -> exit 9 (inconclusive)" "$D" 9 "could not fetch the published anchor-history"

D="$(fresh val-gone)"; rm -f "$D/validator.json"
expect_case "check 8: validator.json unfetchable -> exit 9 (inconclusive)" "$D" 9 "could not fetch the published validator.json"

# ===========================================================================
# Part 8b — C1 regression: the "9/4 morning" three-surface consistency proof
# ===========================================================================
# The state under test is the transition morning BEFORE the boundary:
# endTime is still hours away, cycle M's anchor is already on-chain, and the
# ledger has not moved. The pre-flight is GREEN/DRESS there — correctly. What
# was wrong was the number it printed alongside: the banner and check 7 both
# said the cycle-transition.sh value "for today" was M-1, and on 2026-09-04
# the cycle that closes is M, not M-1. Feeding M-1 into
# `cycle-transition.sh --print-only` is accepted (the ledger admits both
# readings), and gen-anchor-source.sh's ordering guard accepts it too because
# it compares against that same not-yet-advanced ledger — so the plan derives
# an already-inscribed memo prefix and nothing objects until after the
# irreversible broadcast.
#
# The assertion is therefore not "one line changed" but "all three surfaces
# that mention the paired value now say the same thing".
D="$(fresh dress-morning)"
MORNING_END="$(( $(date -u +%s) + 6 * 3600 ))"   # boundary later today
printf '{"endTime":%d,"startTime":%d}\n' "$MORNING_END" "$(( MORNING_END - 2592000 ))" > "$D/validator.json"
printf '{"cycle_number":%d,"event_type":"cyclestart"}\n' "$CYCLE" > "$D/anchor-history.jsonl"
MO_OUT="$(run_pf "$D")"; MO_RC=$?

if [ "$MO_RC" -eq 0 ] && printf '%s' "$MO_OUT" | grep -qF "classification: DRESS"; then
	pass "C1/9-4-morning: pre-boundary + already-inscribed -> GREEN, DRESS" "rc=$MO_RC"
else
	bad "C1/9-4-morning: pre-boundary + already-inscribed -> GREEN, DRESS" "rc=$MO_RC"
fi

# Surface 1 — banner: flags the meaning switch, commits to no number.
if printf '%s' "$MO_OUT" | grep -qF "paired flag:" \
   && ! printf '%s' "$MO_OUT" | grep -qF "sibling value:"; then
	pass "C1 surface 1 (banner): meaning switch flagged, no paired number asserted"
else
	bad "C1 surface 1 (banner): meaning switch flagged, no paired number asserted"
fi

# Surface 2 — check 8: says no cycle closes today, and names M for the day.
if printf '%s' "$MO_OUT" | grep -qF "pairing: NO cycle closes today" \
   && printf '%s' "$MO_OUT" | grep -qF "On the transition day it will be ${CYCLE}" \
   && printf '%s' "$MO_OUT" | grep -qF "this rehearsal flag will be $((CYCLE + 1))"; then
	pass "C1 surface 2 (check 8): N/A today; transition-day values named"
else
	bad "C1 surface 2 (check 8): N/A today; transition-day values named"
fi

# Surface 3 — verdict: re-run with M+1, and --status is M on the day.
if printf '%s' "$MO_OUT" | grep -qF -- "--expect-cycle=$((CYCLE + 1)). That second run is not optional." \
   && printf '%s' "$MO_OUT" | grep -qF "is ${CYCLE} then — the cycle that closes that day"; then
	pass "C1 surface 3 (verdict): day-of rehearsal M+1, day-of --status M"
else
	bad "C1 surface 3 (verdict): day-of rehearsal M+1, day-of --status M"
fi

# The consistency claim itself: on a DRESS run the number M-1 must not appear
# anywhere as a cycle-transition.sh value, on ANY surface. This is the check
# that would have caught the original defect on all three lines at once.
if ! printf '%s' "$MO_OUT" | grep -qE "cycle-transition\.sh[^\n]*--expect-cycle=$((CYCLE - 1))" \
   && ! printf '%s' "$MO_OUT" | grep -qE "would be $((CYCLE - 1))" \
   && ! printf '%s' "$MO_OUT" | grep -qF "CLOSING today) : $((CYCLE - 1))"; then
	pass "C1: on a DRESS run, $((CYCLE - 1)) is never presented as a cycle-transition.sh value"
else
	bad "C1: on a DRESS run, $((CYCLE - 1)) is never presented as a cycle-transition.sh value" \
		"$(printf '%s' "$MO_OUT" | grep -nE -- "--expect-cycle=$((CYCLE - 1))|would be $((CYCLE - 1))" | tr '\n' '|')"
fi

# ===========================================================================
# Part 8c — I1: provenance of every observation, and the NON-AUTHORITATIVE label
# ===========================================================================
# Every run in this suite is overridden, so every run must be labelled. The
# failure mode being closed is a green transcript that never names what it
# read, quoted to the operator as the live state.
if printf '%s' "$BASE_OUT" | grep -qF "observations read from:" \
   && printf '%s' "$BASE_OUT" | grep -qF "NON-AUTHORITATIVE RUN" \
   && printf '%s' "$BASE_OUT" | grep -qF "VERDICT: PRE-FLIGHT GREEN — but NON-AUTHORITATIVE." \
   && printf '%s' "$BASE_OUT" | grep -qF "NON-AUTHORITATIVE RUN — environment overrides in effect:"; then
	pass "I1: an overridden green is labelled NON-AUTHORITATIVE in banner, summary and verdict"
else
	bad "I1: an overridden green is labelled NON-AUTHORITATIVE in banner, summary and verdict"
fi

# Each of the five sources is named, with the fixture paths visible.
I1_NAMED=1
for s_label in "cycle-history  :" "anchor-source  :" "anchor-history :" "validator      :" "testnet chain  :"; do
	printf '%s' "$BASE_OUT" | grep -qF "$s_label" || I1_NAMED=0
done
if [ "$I1_NAMED" -eq 1 ] && [ "$(printf '%s' "$BASE_OUT" | grep -c 'LOCAL OVERRIDE')" -ge 4 ]; then
	pass "I1: all five observation sources are named, local ones marked LOCAL OVERRIDE"
else
	bad "I1: all five observation sources are named, local ones marked LOCAL OVERRIDE" \
		"named=$I1_NAMED overrides=$(printf '%s' "$BASE_OUT" | grep -c 'LOCAL OVERRIDE')"
fi

# The provenance label discriminates: an https source is marked `published`
# even while the rest are local. Hermetic — the stub transport is what fails,
# so no network call is made.
D="$(fresh provenance)"
PF_LEDGER="https://example.invalid/api/cycle-history.jsonl"; export PF_LEDGER
PF_CURL_FAIL=1; export PF_CURL_FAIL
PV_OUT="$(run_pf "$D")"; PV_RC=$?
unset PF_LEDGER PF_CURL_FAIL
if printf '%s' "$PV_OUT" | grep -qE 'cycle-history  : https://example\.invalid[^[]*\[published\]' \
   && printf '%s' "$PV_OUT" | grep -qE 'validator      : [^[]*\[LOCAL OVERRIDE\]'; then
	pass "I1: the provenance label discriminates published vs local per source" "rc=$PV_RC"
else
	bad "I1: the provenance label discriminates published vs local per source" "rc=$PV_RC"
fi

# ===========================================================================
# Part 8d — M4: the published anchor-history must be monotonic to be read
# ===========================================================================
D="$(fresh hist-nonmonotonic)"
{
	printf '{"cycle_number":%d,"event_type":"cyclestart"}\n' "$((CYCLE + 2))"
	printf '{"cycle_number":%d,"event_type":"cyclestart"}\n' "$CYCLE"
} > "$D/anchor-history.jsonl"
expect_case "check 8: non-monotonic anchor-history -> refused, exit 6" "$D" 6 "is not monotonic"

# ===========================================================================
# Part 9 — check 9 (the 2026-07-31 check itself)
# ===========================================================================
D="$(fresh key-absent)"; printf '%s\n' "$OTHER_K1" > "$D/keys.txt"
expect_case "check 9: keystore lists keys but not the chain's -> exit 4" "$D" 4 \
	"the CURRENT on-chain anchor key is NOT in the project testnet keystore"

D="$(fresh key-locked)"
PF_PROTON_MODE=locked; export PF_PROTON_MODE
KL_OUT="$(run_pf "$D")"; KL_RC=$?
unset PF_PROTON_MODE
if [ "$KL_RC" -eq 7 ] \
   && printf '%s' "$KL_OUT" | grep -qF "the testnet keystore is LOCKED" \
   && printf '%s' "$KL_OUT" | grep -qF "Do NOT follow the key-rotation runbook"; then
	pass "check 9: locked keystore -> exit 7, and NOT diagnosed as a missing key" "rc=$KL_RC"
else
	bad "check 9: locked keystore -> exit 7, and NOT diagnosed as a missing key" "rc=$KL_RC"
fi

D="$(fresh key-listnothing)"
PF_PROTON_MODE=empty; export PF_PROTON_MODE
KE_OUT="$(run_pf "$D")"; KE_RC=$?
unset PF_PROTON_MODE
if [ "$KE_RC" -eq 7 ] && printf '%s' "$KE_OUT" | grep -qF "INCONCLUSIVE, not proof the key is absent"; then
	pass "check 9: empty key listing -> exit 7 (inconclusive), never a false 'absent'" "rc=$KE_RC"
else
	bad "check 9: empty key listing -> exit 7 (inconclusive), never a false 'absent'" "rc=$KE_RC"
fi

D="$(fresh rpc-down)"
PF_CURL_FAIL=1; export PF_CURL_FAIL
RD_OUT="$(run_pf "$D")"; RD_RC=$?
unset PF_CURL_FAIL
if [ "$RD_RC" -eq 9 ] && printf '%s' "$RD_OUT" | grep -qF "testnet chain RPC unreachable"; then
	pass "check 9: chain RPC unreachable -> exit 9, never assumed fine" "rc=$RD_RC"
else
	bad "check 9: chain RPC unreachable -> exit 9, never assumed fine" "rc=$RD_RC"
fi

D="$(fresh no-anchor-perm)"
jq 'del(.permissions[] | select(.perm_name=="anchor"))' "$D/account.json" > "$D/acct2.json" && mv "$D/acct2.json" "$D/account.json"
expect_case "check 9: account carries no anchor permission -> exit 4" "$D" 4 "carries no 'anchor' permission"

D="$(fresh acct-malformed)"; printf '{"nope":true}\n' > "$D/account.json"
expect_case "check 9: malformed get_account response -> exit 9" "$D" 9 "malformed/unexpected"

# I2 — the rehearsal's SECOND lock probe. `key:list` succeeding does not
# establish that a signing-adjacent read works; the rehearsal exits 2 on this
# at its step 4/10, and before this case existed the pre-flight reported GREEN
# into that state.
D="$(fresh acct-probe-fails)"
PF_PROTON_MODE=acctfail; export PF_PROTON_MODE
AF_OUT="$(run_pf "$D")"; AF_RC=$?
unset PF_PROTON_MODE
if [ "$AF_RC" -eq 7 ] \
   && printf '%s' "$AF_OUT" | grep -qF "the anchor key IS present, but the signing-adjacent read" \
   && printf '%s' "$AF_OUT" | grep -qF "chain:set writes config"; then
	pass "check 9: key present but 'proton account' refuses -> exit 7, both causes named" "rc=$AF_RC"
else
	bad "check 9: key present but 'proton account' refuses -> exit 7, both causes named" "rc=$AF_RC"
fi

D="$(fresh acct-probe-hangs)"
PF_PROTON_MODE=accthang; export PF_PROTON_MODE
AH_OUT="$(run_pf "$D")"; AH_RC=$?
unset PF_PROTON_MODE
if [ "$AH_RC" -eq 7 ] && printf '%s' "$AH_OUT" | grep -qF "timed out"; then
	pass "check 9: 'proton account' hangs (rc 124) -> exit 7, named as a timeout" "rc=$AH_RC"
else
	bad "check 9: 'proton account' hangs (rc 124) -> exit 7, named as a timeout" "rc=$AH_RC"
fi

# M5 — keys[0] is a faithful mirror of the rehearsal, so a multi-key anchor
# permission makes BOTH partial. Say so rather than let a one-of-two match
# read as "the keystore can sign".
D="$(fresh multikey)"
jq --arg k "$OTHER_K1" '(.permissions[] | select(.perm_name=="anchor") | .required_auth.keys) += [{key:$k}]
   | (.permissions[] | select(.perm_name=="anchor") | .required_auth.threshold) = 2' \
	"$D/account.json" > "$D/acct2.json" && mv "$D/acct2.json" "$D/account.json"
MK_OUT="$(run_pf "$D")"; MK_RC=$?
if [ "$MK_RC" -eq 0 ] \
   && printf '%s' "$MK_OUT" | grep -qF "advisory: the anchor permission has 2 key(s), threshold 2" \
   && printf '%s' "$MK_OUT" | grep -qF "neither is a complete answer"; then
	pass "check 9: multi-key / threshold>1 anchor permission -> advisory, not a silent pass" "rc=$MK_RC"
else
	bad "check 9: multi-key / threshold>1 anchor permission -> advisory, not a silent pass" "rc=$MK_RC"
fi

# The cross-format match is the substance of check 9: the chain answers in
# one encoding and the keystore lists the other. Prove the PASS is real by
# showing it still matches when only the encoding differs (baseline already
# did) and does not when the bytes differ (key-absent above).
if printf '%s' "$BASE_OUT" | grep -qF "matches the current on-chain key"; then
	pass "check 9: EOS-format chain key matched against a PUB_K1_-format keystore entry"
else
	bad "check 9: EOS-format chain key matched against a PUB_K1_-format keystore entry"
fi

# ===========================================================================
# Part 10 — reporting discipline
# ===========================================================================
# Two independent breakages: every one must be listed, and the exit code must
# be the FIRST in listing order (check 3's 3, not check 9's 4).
D="$(fresh two-failures)"
rm -f "$D/mainnet-config/anchor-sink"
printf '%s\n' "$OTHER_K1" > "$D/keys.txt"
TF_OUT="$(run_pf "$D")"; TF_RC=$?
if [ "$TF_RC" -eq 3 ] \
   && printf '%s' "$TF_OUT" | grep -qF "FAIL  [4]" \
   && printf '%s' "$TF_OUT" | grep -qF "FAIL  [9]" \
   && printf '%s' "$TF_OUT" | grep -qF "first failure was [4]"; then
	pass "reporting: every failure is listed; exit code is the first in order" "rc=$TF_RC"
else
	bad "reporting: every failure is listed; exit code is the first in order" \
		"rc=$TF_RC $(printf '%s' "$TF_OUT" | grep '^  FAIL' | tr '\n' ' ')"
fi

# ===========================================================================
# Part 11 — read-only, and no broadcast pathway
# ===========================================================================
# The pre-flight must not modify the repository working tree or the fixture.
BEFORE_GIT="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort)"
D="$(fresh readonly-probe)"
BEFORE_TREE="$(cd "$D" && find . -type f -exec ls -ld {} \; 2>/dev/null | sort)"
run_pf "$D" >/dev/null 2>&1
AFTER_TREE="$(cd "$D" && find . -type f -exec ls -ld {} \; 2>/dev/null | sort)"
AFTER_GIT="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | sort)"
if [ "$BEFORE_TREE" = "$AFTER_TREE" ] && [ "$BEFORE_GIT" = "$AFTER_GIT" ]; then
	pass "read-only: neither the fixture tree nor the repo working tree changed"
else
	bad "read-only: neither the fixture tree nor the repo working tree changed"
fi

# Broadcast-shape scan. Patterns are assembled from fragments so this file's
# own text can never be mistaken for the thing it forbids, and so a repo-wide
# grep for a raw broadcast string does not hit this suite. They are
# INVOCATION-shaped on purpose: the pre-flight legitimately NAMES the
# rehearsal and the signer in its comments (citing the line numbers it
# mirrors), and a bare-filename scan would forbid documentation rather than
# execution.
P="proton"
SCAN_FAIL=0
SCAN_HITS=""
scan_forbidden() { # <file> — sets SCAN_FAIL/SCAN_HITS
	local f="$1" pat
	for pat in "${P} action" "${P} transaction" "cleos" "bin/safe-broad""cast" \
	           "bash .*run-testnet-rehearsal.sh" "bash .*sign-anchor-event.sh" \
	           "push_""transaction" "fyd-broadcast-token"; do
		if grep -qE -- "$pat" "$f"; then
			SCAN_FAIL=1
			SCAN_HITS="${SCAN_HITS} [${pat}]"
		fi
	done
}
scan_forbidden "$PREFLIGHT"
if [ "$SCAN_FAIL" -eq 0 ]; then
	pass "no broadcast pathway: the pre-flight contains no broadcast-capable invocation"
else
	bad "no broadcast pathway: the pre-flight contains no broadcast-capable invocation" "hits:${SCAN_HITS}"
fi

# Mutation evidence: the scan must be capable of firing, or its green above
# means nothing.
SCAN_FAIL=0; SCAN_HITS=""
PROBE="${BASE}/probe.sh"
printf '#!/usr/bin/env bash\n%s action foo\nbash scripts/run-testnet-rehearsal.sh\n' "$P" > "$PROBE"
scan_forbidden "$PROBE"
if [ "$SCAN_FAIL" -eq 1 ] && [ "$(printf '%s' "$SCAN_HITS" | grep -c '\[')" -ge 1 ]; then
	pass "no broadcast pathway: the scan fires on a synthetic violation"
else
	bad "no broadcast pathway: the scan fires on a synthetic violation"
fi

# Keystore safety, asserted BEHAVIOURALLY rather than by grep. The pre-flight
# prints `proton key:unlock` as the remedy for a locked keystore, so the text
# of the script legitimately contains a keystore-mutating command name; what
# must be true is that it never RUNS one. The stub records argv, so the log
# of a full green run is the evidence.
D="$(fresh proton-argv)"
PROTON_LOG="${BASE}/proton-argv.log"
: > "$PROTON_LOG"
PF_PROTON_LOG="$PROTON_LOG"; export PF_PROTON_LOG
run_pf "$D" >/dev/null 2>&1
unset PF_PROTON_LOG
ARGV_LINES="$(grep -c '' "$PROTON_LOG" 2>/dev/null || echo 0)"
# Exactly two, and both READS: the key listing, and the signing-adjacent probe
# carried over from the rehearsal's step 4/10. `chain:set` sits between them in
# the rehearsal and is deliberately NOT carried, because it writes proton-cli's
# config — a read-only pre-flight that mutates the tool it inspects is not
# read-only. That absence is asserted here, not merely described in a comment.
ARGV_OK=1
ARGV_SAW_LIST=0
ARGV_SAW_ACCOUNT=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	case "$line" in
		"key:list")   ARGV_SAW_LIST=1 ;;
		"account "*)  ARGV_SAW_ACCOUNT=1 ;;
		*)            ARGV_OK=0 ;;
	esac
done < "$PROTON_LOG"
if [ "$ARGV_LINES" -eq 2 ] && [ "$ARGV_OK" -eq 1 ] \
   && [ "$ARGV_SAW_LIST" -eq 1 ] && [ "$ARGV_SAW_ACCOUNT" -eq 1 ] \
   && ! grep -q 'chain:set' "$PROTON_LOG"; then
	pass "keystore safety: a whole run invokes proton exactly twice, both reads" "invocations=$ARGV_LINES"
else
	bad "keystore safety: a whole run invokes proton exactly twice, both reads" \
		"invocations=$ARGV_LINES argv=[$(tr '\n' ';' < "$PROTON_LOG")]"
fi

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-rehearsal-preflight.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
