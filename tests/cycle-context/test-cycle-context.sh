#!/usr/bin/env bash
# tests/cycle-context/test-cycle-context.sh — executable statement of
# scripts/lib/cycle-context.sh's contract.
#
# CHAIN: none. The library under test performs no chain access. Section T11
#        does INVOKE five scripts that can broadcast on other code paths;
#        see "SAFETY OF THE T11 PROBES" below for exactly why none of those
#        paths is reachable here and how this suite stays red if that
#        changes.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No broadcast pathway is exercised;
#        no network I/O (the one script that fetches is given a curl stub).
#
# WHAT THIS SUITE HAS TO PROVE, AND WHY EACH PART IS NOT A TAUTOLOGY
# ------------------------------------------------------------------
# The library claims two things that a reader cannot check by reading it:
#
#   (a) "on a well-formed ledger my answer equals every existing derivation
#        in the repo"
#   (b) "my exit table lists codes that the scripts actually emit"
#
# A test that asked the library for both answers would prove nothing. So:
#
#   * For (a), this suite RE-IMPLEMENTS each script's counting idiom from
#     the script's own source line (T2), and separately RUNS the real
#     gen-anchor-source.sh and reads the number IT derived (T3). T1 pins the
#     re-implementations to the scripts with a literal grep, so an idiom
#     that changes in a script and not here turns the suite red instead of
#     letting the copy quietly stop describing the original — the same
#     lock-step technique scripts/lib/side-effects.sh uses for
#     FYD_PUSH_FILENAME_RE.
#   * For (b), this suite EXTRACTS the `exit <literal>` codes from each
#     script's non-comment lines (T10) and, where a code is reachable only
#     indirectly, verifies the propagation mechanism itself rather than
#     accepting a claim about it. T11 then observes real exit codes by
#     running the scripts.
#
# Comment lines are excluded from the extraction deliberately:
# preview-cycle-anchor-broadcast.sh contains the sentence "exit 7 anywhere
# but the Mac" in prose, and a naive grep reads that as a reachable code.
# That false positive was measured on 2026-08-14 while writing this suite.
#
# SAFETY OF THE T11 PROBES
# ------------------------
# T11 runs each script once with an unrecognized argument. The probes exit
# during argument handling. Three belts, stated as measured rather than as
# assumed:
#
#   1. LOAD-BEARING. Each probe asserts the script's own argument-error text
#      on stderr, so a future edit that moves argument parsing later turns
#      this suite red instead of letting a probe run further than intended.
#   2. HOME is redirected to an empty temporary directory, so no project
#      keystore is reachable: the project keystores live under the LOGIN
#      home, and a fresh temp dir contains neither of them.
#      THIS DOES NOT TRIGGER THE CONSTITUTION 3.5 GUARD, and an earlier
#      revision of this comment claimed it did. Measured 2026-08-14:
#      require_project_keystore_home refuses only when HOME is unset/empty
#      or EQUAL TO the login home; an arbitrary temp dir passes it. A probe
#      with HOME=<temp> reaches argument parsing and exits 1, not 8. T11b
#      below asserts both halves of that behaviour rather than asserting
#      this paragraph.
#   3. FY_LIVE is unset, so scripts/lib/side-effects.sh suppresses every
#      notify, push and state write reachable from these scripts.
#
# Usage:
#   bash tests/cycle-context/test-cycle-context.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/cycle-context.sh"
SCRIPTS_DIR="${REPO_ROOT}/scripts"
STEPS_JSON="${REPO_ROOT}/docs/cycle-transition-steps.json"

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

finish() {
	echo
	echo "test-cycle-context.sh summary: PASS=$PASS  FAIL=$FAIL"
	if [ "$FAIL" -gt 0 ]; then
		echo "RESULT: FAIL"
		exit 1
	fi
	echo "RESULT: PASS"
	exit 0
}

[ -r "$LIB" ] || { echo "FATAL: library not readable at $LIB" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }

# shellcheck source=scripts/lib/cycle-context.sh
. "$LIB"

WORK="$(mktemp -d -t fyc-cycle-context.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Ledger fixture builders
# ---------------------------------------------------------------------------

# make_ledger <path> <n>  — a well-formed ledger of n closed cycles, 1..n,
# each line newline-terminated. This is the shape the real generator
# produces (gen-cycle-history.sh writes `jq -c` output, one object per line).
make_ledger() {
	local path="$1" n="$2" i=1
	: > "$path"
	while [ "$i" -le "$n" ]; do
		printf '{"schema_version":1,"cycle_n":%s,"cycle_status":"closed"}\n' "$i" >> "$path"
		i=$((i + 1))
	done
}

# ---------------------------------------------------------------------------
# The three idioms, re-implemented here from the scripts' own source lines.
# T1 below pins each of these to the literal it was copied from.
# ---------------------------------------------------------------------------
IDIOM_LITERAL_ANCHOR_SOURCE='CLOSED_COUNT="$(wc -l < "$CYCLE_HISTORY_JSONL" | tr -d '"'"' '"'"')"'
IDIOM_LITERAL_RENEWAL_ICS="CLOSED_COUNT=\$(grep -cvE '^[[:space:]]*\$' \"\$CYCLE_HISTORY_JSONL\" 2>/dev/null || true)"
IDIOM_LITERAL_GEN_IDENTITY="LAST_CYCLE_N=\"\$(jq -s 'map(.cycle_n) | max // empty' \"\${CY_BODY_TMP}\" 2>/dev/null || true)\""

idiom_anchor_source() { wc -l < "$1" | tr -d ' '; }
idiom_renewal_ics()   { local n; n="$(grep -cvE '^[[:space:]]*$' "$1" 2>/dev/null || true)"; printf '%s' "$n" | tr -d '[:space:]'; }
idiom_gen_identity()  { jq -s 'map(.cycle_n) | max // empty' "$1" 2>/dev/null || true; }

echo "=== T1: idiom lock-step — each re-implementation is pinned to its script ==="

check_literal() {
	local label="$1" file="$2" literal="$3"
	if grep -qF -- "$literal" "$file"; then
		pass "T1 ${label}: source literal still present in ${file#"${REPO_ROOT}"/}"
	else
		fail "T1 ${label}: literal NOT found in ${file#"${REPO_ROOT}"/} — the copy in this suite has stopped describing the script it claims to describe. Re-read the script and update BOTH."
	fi
}
check_literal "gen-anchor-source (wc -l)"        "${SCRIPTS_DIR}/gen-anchor-source.sh"            "$IDIOM_LITERAL_ANCHOR_SOURCE"
check_literal "gen-renewal-ics (non-blank grep)" "${SCRIPTS_DIR}/gen-renewal-ics.sh"              "$IDIOM_LITERAL_RENEWAL_ICS"
check_literal "gen-identity (max cycle_n)"       "${SCRIPTS_DIR}/operator-local/gen-identity.sh"  "$IDIOM_LITERAL_GEN_IDENTITY"

echo
echo "=== T2: on a well-formed ledger the library equals ALL existing idioms ==="

for n in 0 1 2 3 4 12 57; do
	L="$WORK/ok-$n.jsonl"
	make_ledger "$L" "$n"

	a="$(idiom_anchor_source "$L")"
	r="$(idiom_renewal_ics "$L")"
	g="$(idiom_gen_identity "$L")"
	[ -n "$g" ] || g=0   # empty ledger: max over nothing

	lib_closed="$(fyc_closed_cycle_count "$L")"; rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "T2 n=$n: library refused a well-formed ledger (rc=$rc)"
		continue
	fi
	lib_inscribe="$(fyc_cycle_number_to_inscribe "$L")"

	if [ "$a" = "$n" ] && [ "$r" = "$n" ] && [ "$g" = "$n" ]; then
		pass "T2 n=$n: all three script idioms independently answer $n"
	else
		fail "T2 n=$n: idioms disagree on a well-formed ledger (wc-l=$a nonblank=$r max-cycle_n=$g)"
	fi
	if [ "$lib_closed" = "$n" ]; then
		pass "T2 n=$n: fyc_closed_cycle_count == every idiom's answer ($n)"
	else
		fail "T2 n=$n: fyc_closed_cycle_count=$lib_closed but the idioms say $n"
	fi
	if [ "$lib_inscribe" = "$((n + 1))" ]; then
		pass "T2 n=$n: fyc_cycle_number_to_inscribe == $((n + 1))"
	else
		fail "T2 n=$n: fyc_cycle_number_to_inscribe=$lib_inscribe, expected $((n + 1))"
	fi
done

echo
echo "=== T3: the REAL gen-anchor-source.sh derives the same number ==="
# This is the strongest available proof: the script whose CLOSED_COUNT
# becomes the on-chain memo prefix is executed, its guard is fed the
# library's answer, and the guard's own verdict is read back. If the library
# were off by one, the "fresh" case below would exit 9.
#
# Technique (curl stub + fixture docroot) is the one in
# tests/test-gen-anchor-source-ordering-guard.sh. Every repo-default input
# path is pinned at a nonexistent path under $WORK, so the run cannot read
# or write real repo state; the P-chain POST is answered by the stub.

GAS="${SCRIPTS_DIR}/gen-anchor-source.sh"
FIX="$WORK/fixtures"
mkdir -p "$FIX" "$WORK/bin"

cat > "$FIX/operator-identity.pub" <<'PUBEOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHbSbydeQ7/AxLU4BUaqA6rXTMb5y6wcTW2+nRtV/gnj fixture-test-key
PUBEOF
printf '{"seq":1,"note":"fixture-identity-history"}\n' > "$FIX/identity-history.jsonl"

cat > "$WORK/bin/curl" <<STUBEOF
#!/usr/bin/env bash
FIX="$FIX"
URL=""; OUTFILE=""; IS_POST=0; prev=""
for a in "\$@"; do
	case "\$a" in http*) URL="\$a" ;; esac
	[ "\$prev" = "-o" ] && OUTFILE="\$a"
	[ "\$a" = "POST" ] && IS_POST=1
	prev="\$a"
done
if [ "\$IS_POST" -eq 1 ]; then
	echo '{"jsonrpc":"2.0","id":1,"result":{"validators":[]}}'
	exit 0
fi
case "\$URL" in
	*/operator-identity.pub)  cp "\$FIX/operator-identity.pub" "\$OUTFILE"; exit 0 ;;
	*/identity-history.jsonl) cp "\$FIX/identity-history.jsonl" "\$OUTFILE"; exit 0 ;;
	*) exit 22 ;;
esac
STUBEOF
chmod +x "$WORK/bin/curl"

# run_gas <ledger-path> <FY_EXPECT_CYCLE> — the public fetch always fails
# (the stub has no cycle-history route), so the script falls back to
# $CYCLE_HISTORY_JSONL, which is the fixture we control.
run_gas() {
	local ledger="$1" expect="$2"
	env \
		"PATH=${WORK}/bin:${PATH}" \
		"HOME=${WORK}/home" \
		"FY_LIVE=" \
		"NODE_ID=NodeID-fixture-not-a-real-node" \
		"API_BASE_URL=https://fixture.invalid/api" \
		"PUBKEY_URL=https://fixture.invalid/.well-known/operator-identity.pub" \
		"METALGO_API=http://127.0.0.1:9650" \
		"IDENTITY_JSON=${WORK}/nonexistent-identity.json" \
		"IDENTITY_HISTORY_JSONL=${WORK}/nonexistent-identity-history.jsonl" \
		"ANCHOR_HISTORY_JSONL=${WORK}/nonexistent-anchor-history.jsonl" \
		"CYCLE_HISTORY_JSONL=${ledger}" \
		"FY_STATE_DIR=${WORK}/state" \
		"UPTIME_HISTORY_JSONL=${WORK}/state/nonexistent-uptime.jsonl" \
		"DELEGATOR_EVENTS_JSONL=${WORK}/state/nonexistent-delegator.jsonl" \
		"ANOMALIES_LOG=${WORK}/state/nonexistent-anomalies.log" \
		"FY_CONFIG_DIR=${WORK}/cfg" \
		"FY_EXPECT_CYCLE=${expect}" \
		bash "$GAS" --dry-run 2>&1
}

mkdir -p "$WORK/home" "$WORK/state"

for n in 1 4 12; do
	L="$WORK/ok-$n.jsonl"
	lib_closed="$(fyc_closed_cycle_count "$L")"
	lib_inscribe="$(fyc_cycle_number_to_inscribe "$L")"

	out="$(run_gas "$L" "$lib_closed")"; rc=$?
	if [ "$rc" -eq 9 ]; then
		fail "T3 n=$n: real gen-anchor-source rejected the library's closed count ($lib_closed) as stale"
	else
		pass "T3 n=$n: real gen-anchor-source accepts FY_EXPECT_CYCLE=$lib_closed (no exit 9)"
	fi
	if printf '%s' "$out" | grep -qF "CLOSED_COUNT=${lib_closed} "; then
		pass "T3 n=$n: real gen-anchor-source printed CLOSED_COUNT=$lib_closed"
	else
		fail "T3 n=$n: expected 'CLOSED_COUNT=${lib_closed} ' in output; got: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-300)"
	fi
	if printf '%s' "$out" | grep -qF "CYCLE_NUMBER=${lib_inscribe}"; then
		pass "T3 n=$n: real gen-anchor-source derived CYCLE_NUMBER=$lib_inscribe (== fyc_cycle_number_to_inscribe)"
	else
		fail "T3 n=$n: expected 'CYCLE_NUMBER=${lib_inscribe}' in output; got: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-300)"
	fi

	# Feeding it the number to INSCRIBE instead of the number CLOSED is the
	# exact confusion this library exists to make impossible. The real script
	# must reject it.
	out="$(run_gas "$L" "$lib_inscribe")"; rc=$?
	if [ "$rc" -eq 9 ]; then
		pass "T3 n=$n: real gen-anchor-source rejects the inscribe number ($lib_inscribe) as FY_EXPECT_CYCLE — exit 9"
	else
		fail "T3 n=$n: passing the inscribe number as FY_EXPECT_CYCLE should exit 9, got rc=$rc"
	fi
done

echo
echo "=== T4: closed count vs number-to-inscribe cannot be swapped ==="
# Each assertion below is anchored to the LEDGER's own contents, not to the
# other function's answer, so swapping the two implementations cannot make
# both sides move together and stay green.
L="$WORK/ok-4.jsonl"
closed="$(fyc_closed_cycle_count "$L")"
inscribe="$(fyc_cycle_number_to_inscribe "$L")"
max_on_ledger="$(idiom_gen_identity "$L")"

if [ "$closed" = "$max_on_ledger" ]; then
	pass "T4: fyc_closed_cycle_count ($closed) == highest cycle_n ON the ledger ($max_on_ledger)"
else
	fail "T4: fyc_closed_cycle_count ($closed) != highest cycle_n on the ledger ($max_on_ledger)"
fi
if [ "$inscribe" = "$((max_on_ledger + 1))" ]; then
	pass "T4: fyc_cycle_number_to_inscribe ($inscribe) == highest cycle_n + 1"
else
	fail "T4: fyc_cycle_number_to_inscribe ($inscribe) != highest cycle_n + 1 ($((max_on_ledger + 1)))"
fi
if [ "$closed" != "$inscribe" ]; then
	pass "T4: the two functions never return the same number"
else
	fail "T4: the two functions returned the SAME number ($closed) — the distinction has collapsed"
fi
# The re-inscription accident, stated directly: the number about to be
# inscribed must not already be on the ledger, and the closed count must be.
n_hits_inscribe="$(grep -c "\"cycle_n\":${inscribe}[,}]" "$L" || true)"
n_hits_closed="$(grep -c "\"cycle_n\":${closed}[,}]" "$L" || true)"
if [ "$n_hits_inscribe" = "0" ]; then
	pass "T4: the number to inscribe ($inscribe) does NOT already appear on the ledger"
else
	fail "T4: the number to inscribe ($inscribe) is already a closed cycle — inscribing it would re-use a memo prefix"
fi
if [ "$n_hits_closed" = "1" ]; then
	pass "T4: the closed count ($closed) DOES appear on the ledger exactly once"
else
	fail "T4: the closed count ($closed) appears $n_hits_closed times on the ledger, expected 1"
fi

echo
echo "=== T5: the library refuses where the existing idioms would disagree ==="

expect_refusal() {
	local label="$1" path="$2" want_rc="$3" needle="$4" out rc
	out="$(fyc_closed_cycle_count "$path" 2>&1)"; rc=$?
	if [ "$rc" -eq "$want_rc" ]; then
		pass "T5 ${label}: refused with rc=$want_rc"
	else
		fail "T5 ${label}: expected rc=$want_rc, got rc=$rc (output: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-200))"
	fi
	if printf '%s' "$out" | grep -qF -- "$needle"; then
		pass "T5 ${label}: refusal names the cause"
	else
		fail "T5 ${label}: refusal message missing '${needle}'; got: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-200)"
	fi
}

# (1) No trailing newline. wc -l undercounts; the non-blank count does not.
NONL="$WORK/no-trailing-newline.jsonl"
printf '{"cycle_n":1}\n{"cycle_n":2}\n{"cycle_n":3}' > "$NONL"
a="$(idiom_anchor_source "$NONL")"; r="$(idiom_renewal_ics "$NONL")"
if [ "$a" = "2" ] && [ "$r" = "3" ]; then
	pass "T5 no-trailing-newline: the divergence is REAL in the scripts (wc-l=2, non-blank=3)"
else
	fail "T5 no-trailing-newline: expected wc-l=2 / non-blank=3, got wc-l=$a / non-blank=$r"
fi
expect_refusal "no-trailing-newline" "$NONL" 66 "the two line-count idioms disagree"
# ...and the real gen-anchor-source.sh really does answer the low number here,
# which is what makes the refusal the right behaviour rather than pedantry.
out="$(run_gas "$NONL" 3)"; rc=$?
if [ "$rc" -eq 9 ] && printf '%s' "$out" | grep -qF "CLOSED_COUNT=2 "; then
	pass "T5 no-trailing-newline: real gen-anchor-source derives 2 from a 3-record ledger (exit 9 against FY_EXPECT_CYCLE=3)"
else
	fail "T5 no-trailing-newline: expected real script to derive CLOSED_COUNT=2 and exit 9; rc=$rc out=$(printf '%s' "$out" | tr '\n' '|' | cut -c1-300)"
fi

# (2) A blank line in the middle. wc -l overcounts.
BLANK="$WORK/blank-line.jsonl"
printf '{"cycle_n":1}\n\n{"cycle_n":2}\n' > "$BLANK"
expect_refusal "interior-blank-line" "$BLANK" 66 "the two line-count idioms disagree"

# (3) A gap in the numbering. Both line counts agree; the max does not.
GAP="$WORK/gap.jsonl"
printf '{"cycle_n":1}\n{"cycle_n":2}\n{"cycle_n":4}\n' > "$GAP"
expect_refusal "gap-in-cycle_n" "$GAP" 66 "record count and the highest cycle_n disagree"

# (4) A duplicate cycle_n.
DUP="$WORK/dup.jsonl"
printf '{"cycle_n":1}\n{"cycle_n":2}\n{"cycle_n":2}\n' > "$DUP"
expect_refusal "duplicate-cycle_n" "$DUP" 66 "record count and the highest cycle_n disagree"

# (5) A record with no cycle_n at all — the 2026-08-04 field-name class.
NOFIELD="$WORK/no-field.jsonl"
printf '{"cycle_n":1}\n{"cycleN":2}\n' > "$NOFIELD"
expect_refusal "record-missing-cycle_n" "$NOFIELD" 66 "record count and the highest cycle_n disagree"

# (6) Not JSONL at all.
NOTJSON="$WORK/not-json.jsonl"
printf 'this is not json\n' > "$NOTJSON"
expect_refusal "unparseable-ledger" "$NOTJSON" 66 "could not read a maximum cycle_n"

# (7) Unreadable ledger — must NOT resolve to genesis.
expect_refusal "absent-ledger" "$WORK/does-not-exist.jsonl" 65 "not readable"
stdout_only="$(fyc_closed_cycle_count "$WORK/does-not-exist.jsonl" 2>/dev/null || true)"
if [ -z "$stdout_only" ]; then
	pass "T5 absent-ledger: nothing on stdout, so a caller without set -e gets an empty value, never a silent 0"
else
	fail "T5 absent-ledger: printed '$stdout_only' on stdout — a caller could mistake it for an answer"
fi

# (8) A readable but genuinely empty ledger IS a legitimate 0.
EMPTY="$WORK/empty.jsonl"
: > "$EMPTY"
if [ "$(fyc_closed_cycle_count "$EMPTY")" = "0" ] && [ "$(fyc_cycle_number_to_inscribe "$EMPTY")" = "1" ]; then
	pass "T5 empty-ledger: a readable empty ledger is pre-genesis (closed=0, inscribe=1)"
else
	fail "T5 empty-ledger: expected closed=0 / inscribe=1"
fi

echo
echo "=== T6: usage errors ==="
# The zero-argument cases matter more than they look: the ledger argument is
# mandatory precisely because a default would be inert on a developer machine
# (no public/api/cycle-history.jsonl) and load-bearing on the validator host
# (where that file exists and is push-owned). A no-arg call must refuse on
# BOTH machines, so it must refuse on arity, never on readability.
for call in "fyc_closed_cycle_count" "fyc_cycle_number_to_inscribe" "fyc_closed_cycle_count a b" "fyc_cycle_number_to_inscribe a b" "fyc_exit_meaning only-one" "fyc_phase_of" "fyc_exit_table extra"; do
	# shellcheck disable=SC2086
	$call >/dev/null 2>&1; rc=$?
	if [ "$rc" -eq 64 ]; then
		pass "T6 '$call' -> rc 64"
	else
		fail "T6 '$call' -> rc $rc, expected 64"
	fi
done
fyc_exit_meaning gen-anchor-source.sh 99 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 67 ]; then pass "T6 unknown (script,code) -> rc 67"; else fail "T6 unknown (script,code) -> rc $rc, expected 67"; fi

echo
echo "=== T7: table shape integrity ==="
# The library must PARSE, checked separately from sourcing it. The rows carry
# English prose, so apostrophes are unavoidable, and an earlier revision held
# them in `VAR=$(cat <<'EOF' … EOF)`: bash 3.2 counts quote characters inside
# a quoted heredoc body while scanning for the closing `)` of the command
# substitution, so one added row flipped the parity and the whole library
# became a syntax error. `bash -n` catches that class immediately, whereas a
# sourced-but-broken library shows up further down as a confusing cascade of
# "command not found".
if bash -n "$LIB" 2>/dev/null; then
	pass "T7: the library parses (bash -n)"
else
	fail "T7: the library does NOT parse: $(bash -n "$LIB" 2>&1 | head -2 | tr '\n' ' ')"
fi

ROWS="$(fyc_exit_table)"
row_count="$(printf '%s\n' "$ROWS" | grep -c . || true)"
if [ "$row_count" -gt 0 ]; then
	pass "T7: table is non-empty ($row_count rows)"
else
	fail "T7: table is empty"
fi
shape_bad=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	nf="$(printf '%s' "$line" | awk -F'|' '{print NF}')"
	[ "$nf" -eq 6 ] || { fail "T7: row has $nf fields, expected 6: $(printf '%s' "$line" | cut -c1-90)"; shape_bad=1; continue; }
	ph="$(printf '%s' "$line" | cut -d'|' -f1)"
	code="$(printf '%s' "$line" | cut -d'|' -f4)"
	mean="$(printf '%s' "$line" | cut -d'|' -f5)"
	recov="$(printf '%s' "$line" | cut -d'|' -f6)"
	case "$ph" in 1|2|3|4|5|6|daily) ;; *) fail "T7: unknown phase '$ph'"; shape_bad=1 ;; esac
	case "$code" in ''|*[!0-9]*) fail "T7: non-numeric code '$code'"; shape_bad=1 ;; esac
	[ -n "$mean" ]  || { fail "T7: empty meaning in row: $(printf '%s' "$line" | cut -c1-60)"; shape_bad=1; }
	[ -n "$recov" ] || { fail "T7: empty recovery in row: $(printf '%s' "$line" | cut -c1-60)"; shape_bad=1; }
done <<TABLE_EOF
$ROWS
TABLE_EOF
[ "$shape_bad" -eq 0 ] && pass "T7: every row has 6 non-empty fields, a known phase and a numeric code"

dupes="$(printf '%s\n' "$ROWS" | awk -F'|' 'NF{print $3"|"$4}' | sort | uniq -d)"
if [ -z "$dupes" ]; then
	pass "T7: no duplicate (script, code) rows"
else
	fail "T7: duplicate (script, code) rows: $(printf '%s' "$dupes" | tr '\n' ' ')"
fi

# Every row of one script must carry the SAME (phase, step). Without this,
# only the first row of each script is constrained: T9/T9b read one row per
# script and fyc_phase_of returns the first match, so changing the phase on
# (say) the exit-9 row alone went undetected. Measured 2026-08-14.
#
# The invariant is real, not a convenience: a script runs at one point in the
# transition, so every exit code it can return belongs to that same phase.
mixed="$(printf '%s\n' "$ROWS" | awk -F'|' 'NF{print $3"\t"$1"|"$2}' | sort -u | awk -F'\t' '{n[$1]++} END{for (s in n) if (n[s] > 1) print s}')"
if [ -z "$mixed" ]; then
	pass "T7: every script's rows all carry the same (phase, step)"
else
	fail "T7: script(s) with rows claiming more than one (phase, step): $(printf '%s' "$mixed" | tr '\n' ' ')"
fi

echo
echo "=== T8: the ten scripts the brief names are all in the table ==="
BRIEF_SCRIPTS="append-anchor-history.sh check-identity-pins.sh gen-cycle-history.sh gen-anchor-receipt.sh gen-anchor-source.sh gen-renewal-ics.sh preview-cycle-anchor-broadcast.sh run-testnet-rehearsal.sh uptime-history.sh sign-anchor-event.sh"
for s in $BRIEF_SCRIPTS; do
	if printf '%s\n' "$ROWS" | awk -F'|' -v s="$s" '$3==s{f=1} END{exit !f}'; then
		pass "T8: $s has table rows"
	else
		fail "T8: $s has NO table rows"
	fi
done

echo
echo "=== T9: phase/step assignment agrees with docs/cycle-transition-steps.json ==="
if [ ! -r "$STEPS_JSON" ]; then
	fail "T9: ${STEPS_JSON#"${REPO_ROOT}"/} not readable"
else
	# Every script named in the runbook ground truth that is also in the
	# table must carry that runbook's step id. A runbook reordering that
	# leaves this table describing the old order goes red here.
	while IFS='|' read -r step_id script_name; do
		[ -n "$script_name" ] || continue
		base="$(basename "$script_name")"
		tbl_step="$(printf '%s\n' "$ROWS" | awk -F'|' -v s="$base" '$3==s{print $2; exit}')"
		[ -n "$tbl_step" ] || continue   # not one of the ten; nothing to check
		if [ "$tbl_step" = "$step_id" ]; then
			pass "T9: $base is step $step_id in both the table and the runbook JSON"
		else
			fail "T9: $base is step '$tbl_step' in the table but step '$step_id' in the runbook JSON"
		fi
	done <<STEPS_EOF
$(jq -r '.steps[] | .id as $i | .scripts[]? | "\($i)|\(.)"' "$STEPS_JSON")
STEPS_EOF

	# And the reverse direction for the ten: a script in the table that the
	# runbook also knows must not be marked `daily`.
	for s in $BRIEF_SCRIPTS; do
		in_runbook="$(jq -r --arg s "$s" '[.steps[].scripts[]? | select((split("/")|last) == $s)] | length' "$STEPS_JSON")"
		tbl_phase="$(fyc_phase_of "$s")"
		if [ "$in_runbook" -gt 0 ] && [ "$tbl_phase" = "daily" ]; then
			fail "T9: $s is a runbook transition step but the table calls it 'daily'"
		elif [ "$in_runbook" -eq 0 ] && [ "$tbl_phase" != "daily" ]; then
			fail "T9: $s is not a runbook transition step but the table assigns phase '$tbl_phase'"
		else
			pass "T9: $s phase classification ('$tbl_phase') matches its runbook presence"
		fi
	done
fi

echo
echo "=== T9b: the phase number itself is checked, not just the step id ==="
# T9 above compares step ids, which the runbook JSON carries. It does NOT
# constrain the phase, because the runbook JSON has no phase field — so a
# row could claim phase 1 for step 5 and stay green. (Measured: mutation M6
# on 2026-08-14 passed T9 untouched.) The phase grouping's authority is
# design doc section 5, whose flow block is the ONLY place it is written
# down, so this section reads that block directly.
SPEC_DOC="${REPO_ROOT}/docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md"

# The phase -> step grouping transcribed from that block. Step 7.5 (the
# Mac->host transfer of the signing fragment) carries no script and is not
# named in the block at all; it is placed in phase 6 because phase 6 is what
# consumes it. Every other pair is a direct reading.
PHASE_STEP_PAIRS="1|1 1|2 1|3 2|4 3|5 3|6 4|7a 5|7b 5|7c 6|7.5 6|8 6|8.5 6|9"

if [ ! -r "$SPEC_DOC" ]; then
	fail "T9b: design doc not readable at ${SPEC_DOC#"${REPO_ROOT}"/} — the phase grouping has no authority to check against"
else
	# Anchor the transcription to the document for every script the block
	# names literally. The block writes bare stems, so match on those.
	check_spec_phase() {
		local stem="$1" want_phase="$2" line
		line="$(grep -E "^phase ${want_phase} " "$SPEC_DOC" || true)"
		if [ -z "$line" ]; then
			fail "T9b: design doc has no 'phase ${want_phase}' line — the flow block changed shape"
		elif printf '%s' "$line" | grep -qF -- "$stem"; then
			pass "T9b: design doc puts '${stem}' in phase ${want_phase}"
		else
			fail "T9b: design doc's phase ${want_phase} line does not mention '${stem}': $line"
		fi
	}
	check_spec_phase "uptime-history"    1
	check_spec_phase "gen-cycle-history" 1
	check_spec_phase "gen-anchor-source" 3
	check_spec_phase "preview"           5
	check_spec_phase "receipt"           6
	check_spec_phase "history append"    6

	# Every table row's (phase, step) must be one of the transcribed pairs.
	bad_pairs=0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		ph="$(printf '%s' "$line" | cut -d'|' -f1)"
		st="$(printf '%s' "$line" | cut -d'|' -f2)"
		[ "$ph" = "daily" ] && continue
		found=0
		for p in $PHASE_STEP_PAIRS; do
			[ "$p" = "${ph}|${st}" ] && { found=1; break; }
		done
		if [ "$found" -eq 0 ]; then
			fail "T9b: row claims phase ${ph} for step ${st}, which is not a pair the design doc's flow block allows"
			bad_pairs=1
		fi
	done <<PAIR_EOF
$ROWS
PAIR_EOF
	[ "$bad_pairs" -eq 0 ] && pass "T9b: every (phase, step) pair in the table is one the design doc allows"

	# The pair list must cover the runbook exactly, so a new runbook step
	# cannot slip in without a deliberate decision about its phase.
	runbook_steps="$(jq -r '.steps[].id' "$STEPS_JSON" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ *$//')"
	pair_steps="$(printf '%s' "$PHASE_STEP_PAIRS" | tr ' ' '\n' | cut -d'|' -f2 | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ *$//')"
	if [ "$runbook_steps" = "$pair_steps" ]; then
		pass "T9b: the phase grouping covers exactly the runbook's 13 steps"
	else
		fail "T9b: phase grouping covers steps [$pair_steps] but the runbook has [$runbook_steps] — assign the new step a phase deliberately"
	fi
fi

echo
echo "=== T10: every table code is a code the script can actually emit ==="
# Direction A: every deliberate `exit <literal>` in the script has a row.
# Direction B: every row's code is either such a literal or an indirect
#              propagation whose MECHANISM is verified below.
#
# INDIRECT_<script> lists codes reachable without a matching literal.
# Nothing here is taken on trust: each entry has its own mechanism check.
INDIRECT_append_anchor_history="6 7"
INDIRECT_gen_anchor_receipt="6 7"
INDIRECT_gen_anchor_source="6 8"
INDIRECT_uptime_history="2 64"

indirect_for() {
	case "$1" in
		append-anchor-history.sh) printf '%s' "$INDIRECT_append_anchor_history" ;;
		gen-anchor-receipt.sh)    printf '%s' "$INDIRECT_gen_anchor_receipt" ;;
		gen-anchor-source.sh)     printf '%s' "$INDIRECT_gen_anchor_source" ;;
		uptime-history.sh)        printf '%s' "$INDIRECT_uptime_history" ;;
		*)                        printf '' ;;
	esac
}

# literal_exits <script-path> — deliberate exits, comment lines excluded.
# Sorted LEXICALLY, not numerically: these lists are fed to comm(1), which
# assumes its inputs are in the collation order it compares with. A numeric
# sort puts "9" before "10" while comm's own comparison puts it after, and
# the resulting mis-alignment reports codes as both missing AND invented.
# Measured on 2026-08-14 during the mutation round.
literal_exits() {
	grep -vE '^[[:space:]]*#' "$1" \
		| grep -oE '(^|[;&|[:space:]])exit[[:space:]]+[0-9]+' \
		| grep -oE '[0-9]+$' \
		| LC_ALL=C sort -u
}

for s in $BRIEF_SCRIPTS; do
	path="${SCRIPTS_DIR}/${s}"
	tbl_codes="$(printf '%s\n' "$ROWS" | awk -F'|' -v s="$s" '$3==s{print $4}' | LC_ALL=C sort -u)"
	lit_codes="$(literal_exits "$path")"
	ind_codes="$(indirect_for "$s" | tr ' ' '\n' | grep -E '^[0-9]+$' | LC_ALL=C sort -u || true)"
	allowed="$(printf '%s\n%s\n' "$lit_codes" "$ind_codes" | grep -E '^[0-9]+$' | LC_ALL=C sort -u)"

	missing="$(comm -23 <(printf '%s\n' "$lit_codes") <(printf '%s\n' "$tbl_codes") | tr '\n' ' ' | sed 's/ *$//')"
	if [ -z "$missing" ]; then
		pass "T10 $s: every measured literal exit has a table row"
	else
		fail "T10 $s: literal exit code(s) with NO table row: $missing"
	fi

	invented="$(comm -23 <(printf '%s\n' "$tbl_codes") <(printf '%s\n' "$allowed") | tr '\n' ' ' | sed 's/ *$//')"
	if [ -z "$invented" ]; then
		pass "T10 $s: no table row invents a code the script cannot emit"
	else
		fail "T10 $s: table row(s) for unreachable code(s): $invented"
	fi
done

# Mechanism check for the schema-validator propagation: the script must
# actually contain the propagation, and its local validator helper must
# return exactly the codes declared indirect.
for s in append-anchor-history.sh gen-anchor-receipt.sh gen-anchor-source.sh; do
	path="${SCRIPTS_DIR}/${s}"
	if grep -qF 'exit "$schema_rc"' "$path"; then
		pass "T10 $s: the indirect propagation 'exit \"\$schema_rc\"' is present"
	else
		fail "T10 $s: declared an indirect exit via \$schema_rc, but the propagation is not in the script"
	fi
	helper_codes="$(sed -n '/schema_validate_or_die()/,/^}/p' "$path" | grep -oE 'return [0-9]+' | grep -oE '[0-9]+$' | grep -v '^0$' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ *$//')"
	declared="$(indirect_for "$s" | tr ' ' '\n' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ *$//')"
	if [ "$helper_codes" = "$declared" ]; then
		pass "T10 $s: schema helper returns exactly the declared indirect codes ($declared)"
	else
		fail "T10 $s: schema helper returns '$helper_codes' but the table declares '$declared'"
	fi
done

# Mechanism check for uptime-history's rc 64: the state-dir call must
# propagate side-effects.sh's usage rc verbatim.
if grep -qF 'fyd_state_dir uptime)" || exit $?' "${SCRIPTS_DIR}/uptime-history.sh"; then
	pass "T10 uptime-history.sh: the state-dir call propagates side-effects' rc verbatim (rc 64 reachable)"
else
	fail "T10 uptime-history.sh: table declares rc 64 via fyd_state_dir, but that propagation is not in the script"
fi

echo
echo "=== T10b: each row's PROSE is anchored to its own exit site ==="
# T10 above only constrains the SET of codes. Both text columns were entirely
# unchecked: swapping the meaning AND recovery of gen-anchor-source's exit 7
# and exit 9 left the suite green (measured 2026-08-14). That is the worst
# available failure, because exit 9 is the guard that prevents re-inscribing a
# memo prefix and the swapped text would tell the operator "atomic write
# failed — check free space" at the moment before an irreversible inscription.
#
# Method: for each (script, code), collect the EVIDENCE the script itself
# associates with that code — its header exit-table entry plus the lines
# leading up to each literal `exit <code>`. Then require that the row's prose
# matches ITS OWN evidence at least as well as any SIBLING code's evidence in
# the same script.
#
# The test is comparative, not a fixed threshold. An absolute "must share N
# words with its own evidence" was tried first and rejected: recovery text is
# prescriptive ("Fix the argument.") and legitimately does not echo the
# script's wording, so the threshold flagged 58 rows that were perfectly
# correct. It measured writing style, not correctness. What actually matters
# is the reviewer's failure mode — a row explaining the WRONG code — and that
# is exactly what "no sibling explains this prose better" detects: exit 9's
# text scores ~10 against exit 9's evidence and ~0 against exit 7's, so the
# swap inverts the comparison whatever the absolute numbers are.
#
# Rows whose prose shares no vocabulary with ANY sibling's evidence are
# SKIPPED with a named reason and counted, because there is genuinely nothing
# to discriminate with — coverage is printed rather than implied.

# evidence_for <script-path> <code> — the script's OWN header exit-table
# entry for that code (plus its indented continuation lines), lowercased.
# Empty when the script's header says nothing about the code.
#
# Only the header entry is used, and that narrowing was arrived at by
# measurement, not taste. Two alternatives were tried and discarded:
#
#   * "the eight lines before each literal `exit <code>`" — polluted: codes
#     with several exit sites accumulate unrelated neighbouring code, and
#     sign-anchor-event's exit 4 came out better explained by exit 2.
#   * the same, plus following single-line `fail()`-style helpers to their
#     call sites — fixed that case but introduced a SIZE bias: a code whose
#     helper has thirty call sites has thirty times the vocabulary of a code
#     guarded by one line, so raw overlap favours it regardless of meaning.
#     run-testnet-rehearsal's exit 8 then lost to its own exit 1.
#
# The header entry is the script's authoritative one-line statement of what
# the code means, it is one comparable size per code, and it is written
# independently of this table — so agreeing with it is evidence, not
# tautology. Where a script documents nothing (gen-renewal-ics.sh and
# run-testnet-rehearsal.sh have no exit table at all; append-anchor-history's
# stops before 8), there is no claim to compare against and the row is
# reported as UNPINNED rather than scored against a proxy.
evidence_for() {
	local path="$1" code="$2"
	awk -v c="$code" '
		/^#/ {
			if ($0 ~ ("^#[ \t]+" c "[ \t]")) { g = 1; print; next }
			if (g) {
				if ($0 ~ /^#[ \t]+[0-9]+[ \t]/) { g = 0; next }
				if ($0 ~ /^#[ \t][ \t][ \t]/)   { print; next }
				g = 0
			}
			next
		}
		{ g = 0 }
	' "$path" | tr '[:upper:]' '[:lower:]'
}

# words <<<text — content words, length >= 4, sorted unique.
words() {
	tr -c '[:alnum:]_' '\n' | tr '[:upper:]' '[:lower:]' \
		| grep -E '^[a-z_][a-z0-9_]{3,}$' | LC_ALL=C sort -u
}

T10B_SKIPPED=0
T10B_CHECKED=0
for s in $BRIEF_SCRIPTS; do
	path="${SCRIPTS_DIR}/${s}"
	codes="$(printf '%s\n' "$ROWS" | awk -F'|' -v s="$s" '$3==s{print $4}' | LC_ALL=C sort -u)"

	# Materialise each code's evidence vocabulary once.
	for c in $codes; do
		evidence_for "$path" "$c" | words > "$WORK/ev-${s}-${c}.txt"
	done

	for c in $codes; do
		# A code with no evidence of its own cannot be discriminated. These
		# are exactly the indirect-propagation codes whose header is silent
		# (uptime-history 2 and 64) — the finding this task reported. Naming
		# them here keeps the gap visible instead of scoring them at random
		# against siblings.
		if [ ! -s "$WORK/ev-${s}-${c}.txt" ]; then
			echo "SKIP  T10b $s exit $c: UNPINNED — the script's header documents nothing for this code, so there is no independent claim to compare the row against"
			T10B_SKIPPED=$((T10B_SKIPPED + 1))
			continue
		fi

		# MEANING only. The same rule was tried on `recovery` and rejected:
		# recovery is prescriptive and deliberately cross-references other
		# steps ("the ordering guard here is 9, not 7"), so its vocabulary
		# tracks the remedy rather than the condition and the comparison
		# flags correct rows. Recovery is covered structurally below, and the
		# library's header says plainly that its wording is not machine-
		# verified — which is the honest position, not a silent gap.
		text="$(printf '%s\n' "$ROWS" | awk -F'|' -v s="$s" -v c="$c" '$3==s && $4==c{print $5}')"
		printf '%s' "$text" | words > "$WORK/row-words.txt"

		own="$(comm -12 "$WORK/row-words.txt" "$WORK/ev-${s}-${c}.txt" | grep -c . || true)"
		best_other=0
		best_code=""
		for d in $codes; do
			[ "$d" = "$c" ] && continue
			[ -s "$WORK/ev-${s}-${d}.txt" ] || continue
			n="$(comm -12 "$WORK/row-words.txt" "$WORK/ev-${s}-${d}.txt" | grep -c . || true)"
			if [ "$n" -gt "$best_other" ]; then
				best_other="$n"
				best_code="$d"
			fi
		done

		if [ "$own" -eq 0 ] && [ "$best_other" -eq 0 ]; then
			echo "SKIP  T10b $s exit $c meaning: shares no vocabulary with any sibling's evidence — nothing to discriminate"
			T10B_SKIPPED=$((T10B_SKIPPED + 1))
			continue
		fi
		T10B_CHECKED=$((T10B_CHECKED + 1))
		if [ "$own" -ge "$best_other" ]; then
			pass "T10b $s exit $c meaning: best match is its own exit code (own=$own, next best exit ${best_code:-none}=$best_other)"
		else
			fail "T10b $s exit $c meaning: this prose matches exit ${best_code}'s evidence BETTER than exit ${c}'s (own=$own, exit ${best_code}=$best_other). The row explains the wrong code — check it has not been swapped."
		fi
	done
done
echo "T10b coverage: $T10B_CHECKED meaning(s) compared against their own exit code, $T10B_SKIPPED skipped (see SKIP lines)."

# Recovery is not content-verified (see above). What IS enforced: it must be
# present, must not merely restate the meaning, and must not be shared with
# another code of the same script — a recovery that is identical for two
# different failures is either wrong for one of them or too vague to act on.
dup_recov="$(printf '%s\n' "$ROWS" | awk -F'|' 'NF{print $3"\t"$6}' | LC_ALL=C sort | uniq -d | cut -f1 | LC_ALL=C sort -u)"
if [ -z "$dup_recov" ]; then
	pass "T10b: no two codes of the same script share a recovery procedure"
else
	fail "T10b: script(s) with two codes sharing one recovery procedure: $(printf '%s' "$dup_recov" | tr '\n' ' ')"
fi

# A row must not simply repeat itself across its two columns, which would
# satisfy the check above twice while telling the operator nothing to do.
same_cols="$(printf '%s\n' "$ROWS" | awk -F'|' 'NF && $5==$6 {print $3" exit "$4}')"
if [ -z "$same_cols" ]; then
	pass "T10b: no row has an identical meaning and recovery"
else
	fail "T10b: row(s) whose recovery merely repeats the meaning: $(printf '%s' "$same_cols" | tr '\n' ';')"
fi

echo
echo "=== T11: observed exit codes, measured by running the scripts ==="
# Each probe uses an unrecognized argument; see SAFETY OF THE T11 PROBES.
# The assertion is that the code the script REALLY returns is one the table
# explains — not that it equals a number written here, which would only
# restate the table.
mkdir -p "$WORK/probe-home"
probe() {
	local s="$1" needle="$2" out rc
	out="$(cd "$WORK" && env \
		"HOME=${WORK}/probe-home" \
		"FY_LIVE=" \
		"FY_CONFIG_DIR=${WORK}/nonexistent-cfg" \
		"VALIDATOR_JSON=${WORK}/nonexistent-validator.json" \
		"CYCLE_HISTORY_JSONL=${WORK}/nonexistent-cycle-history.jsonl" \
		timeout 30 bash "${SCRIPTS_DIR}/${s}" --fyc-unrecognized-argument-probe </dev/null 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "T11 $s: probe exited 0 — an unrecognized argument must not look like success"
		return
	fi
	if fyc_exit_meaning "$s" "$rc" >/dev/null 2>&1; then
		pass "T11 $s: observed rc=$rc is explained by the table"
	else
		fail "T11 $s: observed rc=$rc has NO table row"
	fi
	if [ -n "$needle" ]; then
		if printf '%s' "$out" | grep -qiF -- "$needle"; then
			pass "T11 $s: probe stopped at argument handling (stderr names it)"
		else
			fail "T11 $s: probe did NOT stop at argument handling — expected '$needle' in output. Re-read the script before trusting this suite's safety argument. Got: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-200)"
		fi
	fi
}

probe append-anchor-history.sh          "unknown arg"
probe check-identity-pins.sh            "unknown arg"
probe gen-anchor-receipt.sh             "unknown arg"
probe gen-anchor-source.sh              "unknown arg"
probe preview-cycle-anchor-broadcast.sh "unknown arg"
probe run-testnet-rehearsal.sh          "unknown arg"
probe sign-anchor-event.sh              "unknown arg"
# These three do not validate arguments at all — they fail on a missing
# input instead. That is itself worth recording: the probe still measures a
# real exit code, but there is no argument-error text to assert.
probe gen-cycle-history.sh              ""
probe gen-renewal-ics.sh                ""
probe uptime-history.sh                 ""

echo
echo "=== T11b: what the probe HOME actually does (belt 2, measured) ==="
# The three probed scripts that carry the Constitution 3.5 keystore guard.
# Asserting the guard's real behaviour here means the safety argument in this
# file's header is checked by the suite instead of merely asserted in prose —
# which is the failure this whole task is about.
GUARD_PROVEN=0
LOGIN_HOME_FOR_TEST="$(eval echo ~"$(id -un)" 2>/dev/null || printf '')"
for s in preview-cycle-anchor-broadcast.sh run-testnet-rehearsal.sh sign-anchor-event.sh; do
	# A temp HOME PASSES the guard — so belt 2 is "no keystore exists there",
	# not "the guard refuses".
	rc=0
	env "HOME=${WORK}/probe-home" "FY_LIVE=" timeout 30 bash "${SCRIPTS_DIR}/${s}" \
		--fyc-unrecognized-argument-probe </dev/null >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 8 ]; then
		pass "T11b $s: a temp HOME does NOT trip the 3.5 guard (rc=$rc) — belt 2 is the absence of a keystore, not a refusal"
	else
		fail "T11b $s: expected a temp HOME to pass the 3.5 guard, got rc 8. The header's belt-2 description is now wrong in the other direction — re-measure and rewrite it."
	fi

	# Under the login home the run must stop at one of the two gates — the
	# 3.5 guard (8) or argument handling (1) — and never past them.
	#
	# WHICH gate fires differs per script, measured 2026-08-14: only
	# preview-cycle-anchor-broadcast.sh places the guard ahead of argument
	# parsing, so it answers 8; run-testnet-rehearsal.sh and
	# sign-anchor-event.sh parse arguments first and answer 1. That is not a
	# defect — each guard only has to precede its own script's first keystore
	# use — but an earlier revision of this suite asserted 8 for all three
	# and was simply wrong about the ordering.
	if [ -n "$LOGIN_HOME_FOR_TEST" ]; then
		rc=0
		env "HOME=${LOGIN_HOME_FOR_TEST}" "FY_LIVE=" timeout 30 bash "${SCRIPTS_DIR}/${s}" \
			--fyc-unrecognized-argument-probe </dev/null >/dev/null 2>&1 || rc=$?
		case "$rc" in
			8) pass "T11b $s: login home stopped at the 3.5 guard (rc=8; this script guards before parsing)"
			   GUARD_PROVEN=1 ;;
			1) pass "T11b $s: login home stopped at argument handling (rc=1; this script parses before guarding)" ;;
			*) fail "T11b $s: login home run stopped at NEITHER gate (rc=$rc) — it got further than this suite's safety argument allows" ;;
		esac
	fi
done
if [ "${GUARD_PROVEN:-0}" -eq 1 ]; then
	pass "T11b: at least one probed script demonstrated the 3.5 guard actually refusing (rc=8), so the guard is live and not merely assumed"
else
	fail "T11b: no probed script demonstrated the 3.5 guard refusing — the guard may have stopped working, and this suite would not otherwise notice"
fi
# And the probe HOME really is empty of keystores.
if [ -z "$(ls -A "${WORK}/probe-home" 2>/dev/null || true)" ]; then
	pass "T11b: the probe HOME is empty — no project keystore is reachable from it"
else
	fail "T11b: the probe HOME is not empty: $(ls -A "${WORK}/probe-home" | tr '\n' ' ')"
fi

echo
echo "=== T12: no broadcast-capable string reaches the library ==="
# The design doc requires the C2 orchestrator to be provably free of these,
# enforced by grep. The library is the first piece of it.
FORBIDDEN_A="pro""ton"
FORBIDDEN_B="cle""os"
FORBIDDEN_C="safe-""broadcast"
FORBIDDEN_D="push_""transaction"
FORBIDDEN_E="issue""Tx"
FORBIDDEN_F="eth_""sendRawTransaction"
for needle in "$FORBIDDEN_A" "$FORBIDDEN_B" "$FORBIDDEN_C" "$FORBIDDEN_D" "$FORBIDDEN_E" "$FORBIDDEN_F"; do
	if grep -qF -- "$needle" "$LIB"; then
		fail "T12: forbidden string '$needle' is present in ${LIB#"${REPO_ROOT}"/}"
	else
		pass "T12: '$needle' absent from the library"
	fi
done

echo
echo "=== T13: the library changes no existing script ==="
# The whole value of this phase is that nothing was replaced yet. If a
# consumer appears, this assertion is the place to update deliberately.
consumers="$(grep -rlF 'lib/cycle-context.sh' "${SCRIPTS_DIR}" 2>/dev/null | grep -vF 'lib/cycle-context.sh' || true)"
if [ -z "$consumers" ]; then
	pass "T13: no script under scripts/ sources the library yet (this phase adds a library, not a replacement)"
else
	fail "T13: script(s) now source the library, so the 'no behaviour change' claim no longer holds: $(printf '%s' "$consumers" | tr '\n' ' ')"
fi

finish
