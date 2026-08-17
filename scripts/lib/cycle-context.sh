#!/usr/bin/env bash
# scripts/lib/cycle-context.sh — the single derivation of the cycle number,
# and the phase/script/exit-code translation table.
#
# CHAIN: none — this file defines shell functions only. It reads a JSONL
#        ledger from a local path and returns integers and text. It performs
#        no network I/O, no writes, and no side effects of any kind, and it
#        deliberately offers no route to a broadcast: the strings that name
#        broadcast tooling do not appear anywhere in this file, and
#        tests/cycle-context/ fails if one is added. Broadcast stays behind
#        bin/ and the Prime Directive's four gates (docs/CONSTITUTION.md).
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# The 2026-08-06 design analysis (docs/superpowers/specs/
# 2026-08-06-single-source-of-truth-design.md, component C2) recorded that
# "the same cycle number is N in one script and N+1 in another", and that
# "the same ordering violation is exit 7 in one script and exit 9 in
# another". Both are true, and both were measured again on 2026-08-14 while
# writing this file. See MEASURED FACTS below for what was actually found —
# it is worse than "N vs N+1": there are THREE different ways to count the
# same ledger. Two of them (gen-anchor-source.sh, gen-identity.sh) are
# machine-checked against the operator's declared FY_EXPECT_CYCLE; the third
# (gen-renewal-ics.sh) is checked against nothing and publishes its answer.
#
# On transition day the number derived here becomes the memo prefix of an
# append-only on-chain inscription. Getting it wrong is not recoverable.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE PROMISES, AND WHAT IT DOES NOT
# ---------------------------------------------------------------------------
# PROMISES:
#   * One derivation, reached through two functions whose names cannot be
#     confused for each other (fyc_closed_cycle_count vs
#     fyc_cycle_number_to_inscribe).
#   * On a well-formed ledger, that derivation returns the SAME number as
#     every existing LEDGER-BASED derivation in the repo. tests/cycle-context/
#     proves this by re-implementing each script's idiom verbatim and
#     comparing.
#     SCOPE, stated because the unqualified version of this sentence would be
#     false: there is a FOURTH derivation that does not read the ledger at
#     all. uptime-history.sh:263 computes CYCLE_N=$((PREV_CYCLE_N + 1)) from
#     its own state file, and nothing reconciles that number against the
#     published ledger. This library cannot equal it and does not try; the
#     two are kept in step only by the operator running the transition steps
#     in order. Reconciling them is a separate task.
#   * On a ledger where those idioms would DISAGREE, it refuses (rc
#     $FYC_DIVERGENT_RC) and names each idiom's answer, instead of silently
#     picking one. That disagreement is precisely the state in which one of
#     the deployed scripts is already wrong for the day.
#   * A translation table from (script, exit code) to meaning + recovery,
#     built from codes that were MEASURED in the scripts, not transcribed
#     from their header comments (the two disagree — see MEASURED FACTS).
#
# DOES NOT PROMISE:
#   * It does not claim the exit table is EXHAUSTIVE. Every script here runs
#     under `set -e`, so any external tool can leak its own exit code out of
#     an unguarded command substitution. One such leak is measured and IS in
#     the table (uptime-history 2); there is no way to enumerate the rest by
#     inspection, and this file does not pretend to have done so. The table
#     covers deliberate exits: `exit <literal>` outside comments, plus the
#     indirect propagations traced by hand and re-verified by the test.
#   * It does not fetch anything. Every existing deriver resolves the ledger
#     differently (see LEDGER RESOLUTION), and choosing one here would make
#     this file a second opinion rather than a single source. The CALLER
#     supplies the path and therefore owns the decision of whether those
#     bytes are the published ones.
#   * It changes no existing script. Nothing in the repo sources this file
#     yet. This phase's value is the proof that the replacement WOULD be
#     equivalent, not the replacement.
#
# ---------------------------------------------------------------------------
# MEASURED FACTS (2026-08-14, this worktree)
# ---------------------------------------------------------------------------
# Three idioms count the same ledger. They do NOT all feed the same consumer,
# and saying so would overstate the coupling:
#
#   gen-anchor-source.sh      `wc -l < <ledger>`                    -> CLOSED_COUNT
#                             compared against FY_EXPECT_CYCLE; +1 becomes the
#                             ON-CHAIN memo prefix.
#   operator-local/gen-identity.sh
#                             `jq -s 'map(.cycle_n) | max'`         -> LAST_CYCLE_N
#                             compared against FY_EXPECT_CYCLE.
#   gen-renewal-ics.sh        `grep -cvE '^[[:space:]]*$' <ledger>` -> CLOSED_COUNT
#                             NOT compared against anything: this script
#                             contains no FY_EXPECT_CYCLE at all (the string
#                             appears once, in a comment at :38). +1 becomes
#                             NEXT_RENEWAL_N, which is published in the .ics
#                             calendar subscribers read.
#
# So two scripts machine-check themselves against the operator's declared
# cycle and one does not; a wrong count in the third is published silently.
#
# They agree on a well-formed ledger and diverge otherwise:
#   * `wc -l` counts NEWLINES. A ledger whose last line has no trailing
#     newline makes it answer N-1 — and gen-anchor-source.sh is the script
#     whose answer becomes the on-chain memo prefix.
#     The inaccurate comment about this is gen-renewal-ics.sh:38, which says
#     its count uses "the same CLOSED_COUNT idiom as gen-anchor-source.sh's
#     FY_EXPECT_CYCLE guard" — that guard uses `wc -l`, and this script
#     deliberately does not. (gen-renewal-ics.sh:146-148, which cites
#     gen-anchor-source.sh's M-2 fix as the blank-tolerant precedent, is
#     ACCURATE: that fix at gen-anchor-source.sh:304 really does use
#     `grep -vE '^[[:space:]]*$'`. An earlier revision of this header blamed
#     the accurate comment and missed the inaccurate one.)
#   * The line-count idioms answer "how many records are on the ledger". The
#     jq idiom answers "what is the highest cycle number on it". Those are
#     the same number only while the ledger is contiguous from 1 with no
#     gaps and no duplicates. Neither script checks that; this file does
#     (see fyc_closed_cycle_count).
#
# The exit-code tables in the script headers do not match the code:
#   * append-anchor-history.sh carries TWO exit-code lists that disagree with
#     each other. The primary "Exit codes:" block at :24-37 stops at 7; a
#     second prose list at :106-109 additionally names 8 (side-effects
#     library missing), which is the code the script really emits at :118.
#     An operator who reads the block that looks canonical does not learn
#     that 8 exists. (An earlier revision of this header called exit 8
#     undocumented outright; that was wrong, and the test that pins each row
#     to the script's own documentation is what surfaced the second list.)
#   * uptime-history.sh's header documents 0, 1, 3. It also exits 2 (jq's
#     own code, leaked through `set -e` when validator.json is absent —
#     measured, not inferred) and can exit 64 (fyd_state_dir's usage rc,
#     propagated by `|| exit $?` at line 77). Both undocumented.
#   * sign-anchor-event.sh's header documents "6 receipt shape assembly
#     failed". No code path emits 6. Documented but unreachable, so it is
#     NOT in the table below — a recovery procedure for a state that cannot
#     occur is worse than no entry.
#   * preview-cycle-anchor-broadcast.sh's header lists no exit 7; a `grep`
#     for `exit 7` hits only a comment sentence. Not in the table.
#
# ---------------------------------------------------------------------------
# LEDGER RESOLUTION (the caller's decision, not this file's)
# ---------------------------------------------------------------------------
# gen-anchor-source.sh resolves the ledger as: public URL, then a repo-local
# mirror, then $CYCLE_HISTORY_JSONL, and treats "none of the three readable"
# as CLOSED_COUNT=0 (pre-genesis). gen-renewal-ics.sh reads the local path,
# and on failure falls back to a cached count, then to 0-unconfirmed.
#
# THIS FILE REPRODUCES NEITHER FALLBACK. An unreadable ledger returns
# $FYC_UNREADABLE_RC and prints nothing. Per the design doc §6 fail-closed
# rule (a) and (c): a file we could not read is not evidence that zero
# cycles have closed, and on transition day "0" would derive cycle 1 and
# re-inscribe a memo prefix used months ago. A genuinely readable, genuinely
# empty ledger IS a legitimate 0 and is accepted as such.
#
# THE LEDGER ARGUMENT IS MANDATORY. An earlier revision defaulted to this
# repo's public/api/cycle-history.jsonl when called with no argument, which
# contradicted the paragraph above: on a developer machine that path does not
# exist and the call refuses (looking correct), but on the validator host it
# DOES exist and is push-owned, so the same no-argument call would quietly
# answer from a local mirror while the caller believed it had chosen nothing.
# A default that is inert where it is tested and load-bearing where it runs is
# the worst shape available, so there is no default.
#
# ---------------------------------------------------------------------------
# CONTRACT
# ---------------------------------------------------------------------------
# Exit codes raised BY THIS LIBRARY (not by any script it describes):
#   64  $FYC_USAGE_RC       called wrong (bad arity, unknown argument).
#                           Same number and same meaning as
#                           scripts/lib/side-effects.sh's usage rc, on
#                           purpose: one spelling of "the caller made a
#                           mistake" across both libraries.
#   65  $FYC_UNREADABLE_RC  the ledger path is missing or unreadable.
#   66  $FYC_DIVERGENT_RC   the ledger is readable but the idioms disagree,
#                           or it cannot be parsed as JSONL at all.
#   67  $FYC_NO_ROW_RC      no translation-table row for the (script, code)
#                           asked about.
# 65, 66 and 67 sit outside every code any script in the table can emit, so
# for those three a caller can always tell "the library refused" from "the
# script it was asking about failed".
#
# 64 IS AMBIGUOUS FOR EXACTLY ONE SCRIPT, and pretending otherwise would be
# the kind of overclaim this file exists to avoid. uptime-history.sh can
# itself exit 64 (table row `1|2|uptime-history.sh|64`), because it
# propagates scripts/lib/side-effects.sh's usage rc verbatim — the same
# number this library uses, for the same underlying condition ("a caller
# passed something the library does not accept"). So a bare 64 observed
# while running uptime-history.sh does not distinguish "cycle-context
# refused my call" from "uptime-history's state-dir call was wrong"; both
# are usage errors originating in a scripts/lib/ library, which is why they
# share a number rather than despite it. Distinguish them by the stderr
# prefix, which is unambiguous: `cycle-context:` vs `side-effects:`.
#
# 65-67 are NOT part of the translation table and must never be translated
# as if they were a script's code.
#
# CALLERS WITHOUT `set -e` MUST CHECK THE RETURN CODE. A refusal prints its
# reason to stderr and NOTHING to stdout, so
# `N="$(fyc_closed_cycle_count "$f")"` leaves N EMPTY and execution
# continues. Either run under `set -e`, or check explicitly:
#     N="$(fyc_closed_cycle_count "$LEDGER")" || exit $?
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#   # shellcheck source=scripts/lib/cycle-context.sh
#   . "${REPO_ROOT}/scripts/lib/cycle-context.sh"
#
#   CLOSED="$(fyc_closed_cycle_count "$LEDGER")"        || exit $?   # N
#   INSCRIBE="$(fyc_cycle_number_to_inscribe "$LEDGER")" || exit $?  # N+1
#
#   fyc_exit_explain gen-anchor-source.sh 9
#   fyc_phase_of gen-anchor-source.sh
#
# See tests/cycle-context/test-cycle-context.sh for the executable statement
# of every rule above, including the mutation cases that prove the equality
# assertions are not tautologies.

FYC_CYCLE_CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FYC_REPO_ROOT="$(cd "${FYC_CYCLE_CONTEXT_LIB_DIR}/../.." && pwd)"

FYC_USAGE_RC=64
FYC_UNREADABLE_RC=65
FYC_DIVERGENT_RC=66
FYC_NO_ROW_RC=67

# There is deliberately NO default ledger path and no environment variable
# that supplies one — see "THE LEDGER ARGUMENT IS MANDATORY" above.

# ---------------------------------------------------------------------------
# Internal helpers (fyc__ prefix — not part of the contract)
# ---------------------------------------------------------------------------

fyc__usage() {
	echo "cycle-context: ERROR: $*" >&2
	return "$FYC_USAGE_RC"
}

# fyc__ledger_path <caller> <path> — validate arity and readability.
fyc__ledger_path() {
	local caller="$1"
	shift
	if [ "$#" -ne 1 ]; then
		fyc__usage "${caller}: exactly one argument required (ledger path), got $#. There is no default: naming the ledger is the caller's decision, and a default would answer from a local mirror on the validator host while looking inert here."
		return "$FYC_USAGE_RC"
	fi
	local path="$1"
	if [ -z "$path" ]; then
		fyc__usage "${caller}: ledger path must not be empty"
		return "$FYC_USAGE_RC"
	fi
	if [ -d "$path" ]; then
		fyc__usage "${caller}: ledger path is a directory: ${path}"
		return "$FYC_USAGE_RC"
	fi
	if [ ! -r "$path" ]; then
		echo "cycle-context: ERROR: cycle-history ledger not readable: ${path}" >&2
		echo "               Refusing to derive a cycle number. An unreadable ledger is NOT" >&2
		echo "               evidence that zero cycles have closed; deriving 1 from it would" >&2
		echo "               re-inscribe a memo prefix that is already on-chain." >&2
		return "$FYC_UNREADABLE_RC"
	fi
	printf '%s\n' "$path"
	return 0
}

# The three idioms, each a faithful re-statement of the one in the named
# script. tests/cycle-context/ greps those scripts for the exact source
# literal and fails if either side drifts, so these cannot quietly stop
# describing the scripts they claim to describe.

# gen-anchor-source.sh: `wc -l < "$CYCLE_HISTORY_JSONL" | tr -d ' '`
fyc__count_newlines() {
	wc -l < "$1" | tr -d ' '
}

# gen-renewal-ics.sh: `grep -cvE '^[[:space:]]*$' "$CYCLE_HISTORY_JSONL" 2>/dev/null || true`
# `|| true` is load-bearing: grep -c exits 1 when it counts zero, which
# aborts a `set -e` caller on a legitimately empty ledger.
fyc__count_nonblank() {
	local n
	n="$(grep -cvE '^[[:space:]]*$' "$1" 2>/dev/null || true)"
	n="$(printf '%s' "$n" | tr -d '[:space:]')"
	[ -n "$n" ] || n=0
	printf '%s\n' "$n"
}

# operator-local/gen-identity.sh: `jq -s 'map(.cycle_n) | max // empty'`
# Prints nothing when the ledger does not parse as JSONL, which the caller
# below turns into a refusal rather than a zero.
fyc__max_cycle_n() {
	jq -s 'map(.cycle_n) | max // empty' "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The derivation (exactly one place)
# ---------------------------------------------------------------------------

# fyc_closed_cycle_count <ledger>
#   Prints N — the number of cycles that have ALREADY CLOSED and are on the
#   published ledger. This is the number FY_EXPECT_CYCLE is compared against
#   in gen-anchor-source.sh and gen-identity.sh — NOT in gen-renewal-ics.sh,
#   which derives the same quantity and compares it against nothing (see
#   MEASURED FACTS). It is NOT the number that gets inscribed.
#
#   The answer is the non-blank record count (gen-renewal-ics.sh's idiom),
#   chosen because each line of cycle-history.jsonl IS one closed cycle and
#   because it is the only one of the three that survives a ledger written
#   without a trailing newline. The other two idioms are computed as well and
#   the call REFUSES ($FYC_DIVERGENT_RC) if any disagrees, so the choice is
#   never silently load-bearing: on every input where this function returns a
#   number, all three idioms returned that same number.
#
#   Checking max(cycle_n) == record count is also, for free, a contiguity
#   check: N distinct positive integers with maximum N are exactly {1..N}, so
#   a gap, a duplicate, or a row missing cycle_n all force a divergence
#   refusal rather than an off-by-one that looks plausible.
#
#   A readable, genuinely empty ledger is a legitimate 0 (pre-genesis) and
#   skips the max check, which has nothing to compare.
fyc_closed_cycle_count() {
	local path
	path="$(fyc__ledger_path fyc_closed_cycle_count "$@")" || return $?

	local by_nonblank by_newline by_max
	by_nonblank="$(fyc__count_nonblank "$path")"
	by_newline="$(fyc__count_newlines "$path")"

	if [ "$by_nonblank" -eq 0 ]; then
		# Pre-genesis. A file of only blank bytes still counts as 0 records,
		# but `wc -l` sees its newlines, so the two legitimately differ here
		# and comparing them would refuse a valid empty ledger.
		printf '0\n'
		return 0
	fi

	if [ "$by_newline" != "$by_nonblank" ]; then
		echo "cycle-context: ERROR: the two line-count idioms disagree on ${path}." >&2
		echo "               gen-anchor-source.sh's idiom (wc -l)              -> ${by_newline}" >&2
		echo "               gen-renewal-ics.sh's idiom (non-blank grep -c)    -> ${by_nonblank}" >&2
		echo "               A missing trailing newline or a blank line is the usual cause." >&2
		echo "               These two numbers reach DIFFERENT public artifacts, and the first" >&2
		echo "               one becomes the on-chain memo prefix. Fix the ledger's bytes" >&2
		echo "               before deriving anything from it." >&2
		return "$FYC_DIVERGENT_RC"
	fi

	by_max="$(fyc__max_cycle_n "$path")"
	by_max="$(printf '%s' "$by_max" | tr -d '[:space:]')"
	if [ -z "$by_max" ]; then
		echo "cycle-context: ERROR: could not read a maximum cycle_n from ${path}." >&2
		echo "               The ledger is non-empty (${by_nonblank} records) but does not parse" >&2
		echo "               as JSONL, or no record carries cycle_n. Refusing rather than" >&2
		echo "               trusting the line count alone." >&2
		return "$FYC_DIVERGENT_RC"
	fi
	if [ "$by_max" != "$by_nonblank" ]; then
		echo "cycle-context: ERROR: the record count and the highest cycle_n disagree on ${path}." >&2
		echo "               record count (gen-anchor-source / gen-renewal-ics) -> ${by_nonblank}" >&2
		echo "               max cycle_n  (gen-identity)                        -> ${by_max}" >&2
		echo "               The ledger is not contiguous 1..N: a gap, a duplicate cycle_n, or a" >&2
		echo "               record without cycle_n. Those two scripts would answer differently" >&2
		echo "               for the SAME FY_EXPECT_CYCLE. Repair the ledger before proceeding." >&2
		return "$FYC_DIVERGENT_RC"
	fi

	printf '%s\n' "$by_nonblank"
	return 0
}

# fyc_cycle_number_to_inscribe <ledger>
#   Prints N+1 — the number of the cycle that is ABOUT TO BE INSCRIBED, i.e.
#   the one that becomes the memo prefix and appears as
#   observations_branch.cycle_number_observed in anchor-source.json.
#
#   Deliberately NOT a flag on the function above. The two quantities differ
#   by one and are used within minutes of each other on transition day; a
#   boolean argument would let a wrong call site typecheck. The names have no
#   shared prefix beyond fyc_ and no shared word, so a mistaken call reads
#   wrong on the page.
fyc_cycle_number_to_inscribe() {
	local closed
	closed="$(fyc_closed_cycle_count "$@")" || return $?
	printf '%s\n' "$((closed + 1))"
	return 0
}

# ---------------------------------------------------------------------------
# Exit-code translation (translate, never renumber)
# ---------------------------------------------------------------------------
# Rows are `phase|step|script|code|meaning|recovery`.
#
#   phase   the design doc §5 phase (1-6), or `daily` for the two scripts
#           that touch cycle numbering from cron but are not transition
#           steps. Verified against docs/cycle-transition-steps.json by the
#           test, so a runbook change that moves a script cannot leave this
#           table describing the old order.
#   step    the id in docs/cycle-transition-steps.json, or `-`.
#   code    a code MEASURED as reachable in that script. Nothing here is
#           transcribed from a header comment; where the two disagree the
#           code wins and the disagreement is recorded in MEASURED FACTS.
#
# THE NUMBERS ARE NOT CHANGED, ONLY EXPLAINED. gen-anchor-source.sh's exit 9
# and gen-identity.sh's exit 7 are the same ordering violation, and this
# table says so in both rows while leaving both numbers exactly as the
# scripts emit them. Renumbering is forbidden: `retryable_notify_rc()`
# classifies notify.sh's 2/4/5 by value in three call sites, and the
# broadcast/publish guards' 0/2 are an external hook contract.
#
# No field may contain `|`. The test enforces that.
#
# The rows live in a FUNCTION rather than in a variable assigned from
# `$(cat <<'EOF' … EOF)`. That earlier form was a landmine: bash 3.2 (the
# macOS system bash this repo's tests run under) scans for the closing `)` of
# a command substitution while tracking quote state, and it counts the quote
# characters inside the heredoc body even though the heredoc is quoted and the
# body is literal. The prose here is English, so apostrophes ("the caller's",
# "jq's") are unavoidable; every added row flipped the parity, and the row
# that finally made it odd turned the whole library into a syntax error at
# source time. Measured 2026-08-14. A heredoc inside a function body is not
# inside a command substitution, so the miscount cannot happen.
fyc__table_rows() {
	cat <<'FYC_TABLE_EOF'
1|2|uptime-history.sh|0|Wrote the daily row, or it was already present. Also returned when the cycle gate deferred Job B, which is a NORMAL outcome and not proof that a cycle was closed.|Read stderr to tell the three apart. If this was the transition tick, confirm uptime-cycles.json gained exactly one closed-cycle record before moving to step 3.
1|2|uptime-history.sh|1|validator.json is readable but is missing nodeId, endTime or uptime.|Wait for the node-info tick (step 1) to rewrite validator.json, confirm the three fields are present, then re-run.
1|2|uptime-history.sh|2|UNDOCUMENTED in this script's header. jq's own exit code, leaked by set -e when an input file cannot be opened at all (validator.json absent, as opposed to present-but-incomplete which is exit 1). Measured 2026-08-14.|Check that VALIDATOR_JSON points at an existing file. This is a missing input, not bad data.
1|2|uptime-history.sh|3|scripts/lib/side-effects.sh is not readable (structural). The script refuses rather than keep a track record nothing can persist.|Confirm scripts/lib/ reached this machine intact; a partial sync of scripts/ is the usual cause. Re-sync, then re-run.
1|2|uptime-history.sh|64|UNDOCUMENTED in this script's header. side-effects.sh's usage rc, propagated verbatim by the state-dir resolution at line 77 (an unknown role argument).|A caller or a patch passed a role fyd_state_dir does not know. Fix the role name; do not add a fallback, which would resolve to the production state directory.
1|3|gen-cycle-history.sh|0|Wrote cycle-history.jsonl, OR the cycle gate deferred the run. Both are exit 0; 0 alone does not prove the ledger advanced.|Confirm the ledger actually gained the row: the record count must now equal the just-closed cycle number. Do not proceed to step 5 on the strength of exit 0 alone.
1|3|gen-cycle-history.sh|1|A required input is missing (uptime-cycles.json or incidents.json), or the output directory does not exist.|uptime-cycles.json is step 2's output, so this usually means step 2 was skipped or deferred by the gate. Re-run step 2 and confirm it wrote.
1|3|gen-cycle-history.sh|2|An input exists but is malformed: no .cycles array, or no .incidents array.|Repair the named input. Do not hand-edit cycle-history.jsonl to compensate; it is generated from these inputs and would be overwritten.
1|3|gen-cycle-history.sh|3|A generated line is not valid JSON.|Inspect the source record in uptime-cycles.json for an unescaped value; the generator copies fields through verbatim.
1|3|gen-cycle-history.sh|4|Incident attribution is not conserved: the per-cycle counts do not sum to the total.|An incident's detectionDate falls outside every cycle window. Check the first and last cycle boundaries against incidents.json before publishing.
3|5|gen-anchor-source.sh|0|Composed anchor-source.json, schema-validated it, and passed the obligation-verb check.|Proceed to step 6. Verify the printed cycle number is the one you intend to inscribe BEFORE committing.
3|5|gen-anchor-source.sh|2|Bad argument or usage error.|Fix the argument. Note this script has no exit 1; a usage error is 2 here and 1 in most siblings.
3|5|gen-anchor-source.sh|3|A required input file is missing (validator.json, identity.json, or another branch input).|Identify the named file. If it is identity.json, phase 2 has not landed yet; complete step 4 and its deploy before retrying.
3|5|gen-anchor-source.sh|4|The P-chain RPC call failed, or the NodeID is not present in the current validator set.|A NodeID absent from the current set usually means the transition is mid-flight. Re-check the node is registered for the new period, then re-run.
3|5|gen-anchor-source.sh|5|An obligation verb was detected in the output (verb-discipline violation).|The composed record makes a promise instead of an observation. Correct the offending input text; do not weaken the check.
3|5|gen-anchor-source.sh|6|Schema validation failed, or the schema file itself is unreadable.|Compare the output against public/api/anchor-source.schema.v1.json. Reached through the shared validator helper, not a literal exit.
3|5|gen-anchor-source.sh|7|Atomic write failed for the canonical output or for the per-anchor archive copy.|Check free space and directory permissions on public/api/ and public/api/archive/. NOTE the ordering guard here is 9, not 7 - do not read this as the ordering guard.
3|5|gen-anchor-source.sh|8|No JSON schema validator is available (neither ajv nor python3+jsonschema). Fail-closed rather than skip validation.|Provision a validator on this machine (scripts/setup-schema-validator.sh), then re-run.
3|5|gen-anchor-source.sh|9|ORDERING GUARD. The published cycle-history ledger has not advanced to the cycle the caller declared in FY_EXPECT_CYCLE, so composing now would derive the number of the cycle that is STILL OPEN and re-inscribe a memo prefix already on-chain.|Re-run phase 1: close the cycle (step 2), regenerate and publish the ledger (step 3), confirm the published bytes actually changed, then re-run this step. This is the same condition gen-identity.sh reports as exit 7; the number differs, the meaning does not.
3|5|gen-anchor-source.sh|10|anchor-history.jsonl is non-empty but prev_anchor_root and prev_anchor_tx could not both be read as 64-hex from its last non-blank line.|Do NOT let this fall back to genesis. Inspect the last line of anchor-history.jsonl: a trailing blank line or a renamed field is the known cause. Repair the ledger, then re-run.
3|5|gen-anchor-source.sh|11|scripts/lib/side-effects.sh is not readable (structural).|Confirm scripts/lib/ reached this machine intact, then re-run.
4|7a|run-testnet-rehearsal.sh|0|The rehearsal completed and printed the sentinel line carrying the testnet transaction id.|Copy the sentinel line verbatim. It is the gate-1 evidence for the mainnet step and is only valid for the SAME cycle number.
4|7a|run-testnet-rehearsal.sh|1|A pre-check refused: unreadable or fixture anchor-source without the opt-in flag, a cycle mismatch against --expect-cycle, a missing tool, an unreachable testnet RPC, or the on-chain anchor key not present locally.|Read the FAIL line; each names its own remedy. A cycle mismatch means the day-of recompose (step 5/6) has not happened yet - do the rehearsal AFTER it, never before.
4|7a|run-testnet-rehearsal.sh|2|The project testnet keystore is LOCKED. Detected by a probe that timed out or failed, not by an empty key listing.|Unlock the project testnet keystore in a separate terminal per docs/PHASE_ALPHA_TESTNET_DRY_RUN.md, then re-run. Do NOT follow the key-rotation runbook; the key is almost certainly present.
4|7a|run-testnet-rehearsal.sh|8|Keystore separation guard failed (Constitution 3.5): HOME does not resolve to the project testnet keystore.|Re-invoke with the project testnet keystore HOME prefix. Never satisfy this by pointing at the default shared keystore.
5|7b|preview-cycle-anchor-broadcast.sh|0|The preview completed. Nothing was broadcast.|Review the printed authorization, sink and memo prefix against what you intend, then proceed to step 7c.
5|7b|preview-cycle-anchor-broadcast.sh|1|Usage error, or the --source file is unreadable.|Fix the argument or the path.
5|7b|preview-cycle-anchor-broadcast.sh|3|The config directory is incomplete (the account or sink file is missing).|Restore the operator config directory on this machine. Do not invent values.
5|7b|preview-cycle-anchor-broadcast.sh|4|The mainnet dry-run log came out empty or unparseable.|Without a parseable log there is no gate-4 material. Re-run the preview; if it stays empty, stop and diagnose before any broadcast.
5|7b|preview-cycle-anchor-broadcast.sh|8|Keystore separation guard failed (Constitution 3.5).|Re-invoke with the project mainnet keystore HOME prefix.
5|7b|preview-cycle-anchor-broadcast.sh|9|Committed-bytes guard failed: --source does not match the committed anchor-source.|Preview the COMMITTED bytes, not a working-tree copy. If they should match, step 6 has not landed; complete it first.
5|7b|preview-cycle-anchor-broadcast.sh|10|Published-copy guard failed: the live public anchor-source.json does not match.|The deploy has not propagated. Wait for it and re-check the published bytes; do not proceed on the local copy.
5|7c|sign-anchor-event.sh|0|Success. The receipt fragment is on stdout.|Transfer the fragment to the host for step 8 (step 7.5). It is the only record of what was inscribed.
5|7c|sign-anchor-event.sh|1|Usage error.|Fix the argument.
5|7c|sign-anchor-event.sh|2|anchor-source.json is missing or invalid, its DAG root does not match, or cycle_number_observed is below 1.|Re-derive the anchor source (step 5) rather than editing it. A DAG mismatch means the file changed after it was composed.
5|7c|sign-anchor-event.sh|3|A config file is missing (the account or sink file).|Restore the operator config directory on this machine.
5|7c|sign-anchor-event.sh|4|The broadcast helper under bin/ is missing or not executable.|Restore it from the repo. Do not substitute a direct call; the helper is where the authorization gates live.
5|7c|sign-anchor-event.sh|5|The broadcast helper returned non-zero.|Read the helper's own output for the gate that refused. Do not retry blindly: a partially accepted transaction must be checked on-chain FIRST, because a second attempt could double-inscribe.
5|7c|sign-anchor-event.sh|7|The signing CLI is not on PATH. This is a PATH pre-flight, NOT an assertion about which machine you are on and NOT a keystore read: a Mac whose PATH lacks the CLI (a cron or other non-login shell) hits this too, and the message's "the operator's Mac" wording invites the wrong diagnosis.|First check PATH in THIS shell before concluding you are on the wrong machine; a non-login shell is the common cause. If you only need the composed transaction, --dry-run needs no signing key and never reaches this check. If you really are on the validator host, move the step, not the key.
5|7c|sign-anchor-event.sh|8|Keystore separation guard failed (Constitution 3.5): HOME resolves to the default shared keystore.|Re-invoke with the project mainnet keystore HOME prefix.
6|8|gen-anchor-receipt.sh|0|All seven verification gates passed and the receipt was written.|Proceed to the history append. The receipt is the input that append-anchor-history.sh validates against.
6|8|gen-anchor-receipt.sh|1|Usage or argument error.|Fix the argument.
6|8|gen-anchor-receipt.sh|2|The input could not be parsed.|Confirm the signing fragment transferred intact (step 7.5). A truncated transfer looks exactly like this.
6|8|gen-anchor-receipt.sh|3|The RPC is unreachable, or the transaction id was not found.|A transaction that was just broadcast may not have propagated yet. Re-check on the explorer before concluding it failed; do NOT re-broadcast.
6|8|gen-anchor-receipt.sh|4|One of the seven verify gates failed.|Read which gate. This compares what is on-chain against what was intended, so a failure here means the inscription and the record disagree. Stop and reconcile before appending anything.
6|8|gen-anchor-receipt.sh|5|Atomic write failed for the receipt or for the archive copy.|Check free space and permissions, then re-run. Verification is idempotent.
6|8|gen-anchor-receipt.sh|6|The receipt failed schema validation.|Compare against public/api/anchor-receipt.schema.v2.json. Reached through the shared validator helper, not a literal exit.
6|8|gen-anchor-receipt.sh|7|No JSON schema validator is available. Fail-closed rather than skip validation.|Provision a validator on this machine (scripts/setup-schema-validator.sh), then re-run.
6|8|append-anchor-history.sh|0|The line was appended.|Confirm the ledger grew by exactly one line, then publish it (step 8.5).
6|8|append-anchor-history.sh|1|Usage or argument error.|Fix the argument.
6|8|append-anchor-history.sh|2|The receipt file is unreadable or invalid.|Re-run step 8's receipt generation; do not hand-write a receipt.
6|8|append-anchor-history.sh|3|The receipt's verification_status is not live.|The receipt records that verification did not fully pass. Resolve that first; appending it would record an unverified anchor as verified.
6|8|append-anchor-history.sh|4|An append-only invariant was violated: a duplicate (cycle_number, event_type) pair, a duplicate key_seq, or a cycle_number lower than the last line's.|A duplicate pair usually means this append already succeeded. Check the last line of the ledger BEFORE retrying; the file is append-only and a second row cannot be removed cleanly.
6|8|append-anchor-history.sh|5|Atomic write failed.|Check free space and permissions, then re-run after confirming the last line.
6|8|append-anchor-history.sh|6|The newly composed line failed schema validation.|Compare against the anchor-history schema. Reached through the shared validator helper, not a literal exit.
6|8|append-anchor-history.sh|7|No JSON schema validator is available. Fail-closed rather than skip validation.|Provision a validator on this machine (scripts/setup-schema-validator.sh), then re-run.
6|8|append-anchor-history.sh|8|scripts/lib/side-effects.sh is not readable (structural). Named only in the SECOND exit list at :106-109; the primary Exit codes block at :24-37 stops at 7, so the list that looks canonical omits this code.|Confirm scripts/lib/ reached this machine intact, then re-run. If you were reading the primary exit-code block and could not find 8, that is the script's two lists disagreeing, not a code from somewhere else.
daily|-|check-identity-pins.sh|0|No NEW breakage. Pins match, or the only mismatches are baselined tracked pins or structural stream pins.|None.
daily|-|check-identity-pins.sh|2|Cannot run: jq missing, the identity manifest is unreadable or empty, the baseline or feed-excludes list is unreadable, the publication registry (deploy/publication.json, the kind-gate authority) is unreadable or unparseable or empty, a pin URL is malformed, or no sha256 tool. A blind checker must never be mistaken for a healthy one.|Restore the missing tool or file. In live mode this condition also alerts, deliberately.
daily|-|check-identity-pins.sh|3|NEW breakage on a tracked pin: the hash mismatches, or the pinned file is gone.|A commit changed a file the signed manifest pins. Either restore the bytes or re-sign the manifest; do not baseline it to make the alert stop.
daily|-|check-identity-pins.sh|4|Live mode only: a tracked pin's URL could not be fetched, so no comparison was possible. A fetched 200 that mismatches is still exit 3, never this.|Re-check once the URL is reachable. Do not read this as "the pin is fine".
daily|-|check-identity-pins.sh|5|scripts/lib/side-effects.sh is not readable (structural). Distinct from 3 and 2 on purpose - it is the state in which alerting itself is impossible.|Confirm scripts/lib/ reached this machine intact, then re-run.
daily|-|check-identity-pins.sh|6|NEW kind-gate break: a pin exists over a kind=stream publication that is not acknowledged in deploy/publication.json's known_kind_violations, or over a publication with no row in deploy/publication.json at all. Checked before exit 3/4, so a run with both a kind-gate break and a mismatch reports and alerts 6.|Acknowledge a still-open kind=stream case in deploy/publication.json's known_kind_violations, add a missing publications[] row, or re-issue the manifest (gen-identity.sh never pins kind=stream) so the pin is simply gone.
daily|-|gen-renewal-ics.sh|0|The calendar was regenerated, OR the cycle gate deferred the run. Both are exit 0.|Read stderr to tell them apart. This script has no header exit table; these two rows were measured from the code.
daily|-|gen-renewal-ics.sh|1|A required input is unreadable: the calendar token file, validator.json, or endTime within it.|Restore the named file. Note the renewal NUMBER can still be wrong without any non-zero exit - an unreadable ledger falls back to a cached or unconfirmed count and says so on stderr only.
FYC_TABLE_EOF
}

# fyc_exit_table
#   Prints the raw table. One row per line, `phase|step|script|code|meaning|recovery`.
fyc_exit_table() {
	if [ "$#" -ne 0 ]; then
		fyc__usage "fyc_exit_table: takes no arguments (got $#)"
		return "$FYC_USAGE_RC"
	fi
	fyc__table_rows
	return 0
}

# fyc__row <script> <code> — print the matching row, or return $FYC_NO_ROW_RC.
fyc__row() {
	local script="$1" code="$2" line f_script f_code
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		f_script="$(printf '%s' "$line" | cut -d'|' -f3)"
		f_code="$(printf '%s' "$line" | cut -d'|' -f4)"
		if [ "$f_script" = "$script" ] && [ "$f_code" = "$code" ]; then
			printf '%s\n' "$line"
			return 0
		fi
	done < <(fyc__table_rows)
	return "$FYC_NO_ROW_RC"
}

# fyc__field <script> <code> <field-index> <label>
fyc__field() {
	local script="$1" code="$2" idx="$3" label="$4" row
	if ! row="$(fyc__row "$script" "$code")"; then
		echo "cycle-context: ERROR: no ${label} on record for ${script} exit ${code}." >&2
		echo "               The table covers deliberate exits only and is not claimed to be" >&2
		echo "               exhaustive: any script here runs under set -e, so an external tool" >&2
		echo "               can leak its own code. Treat this as UNKNOWN and investigate the" >&2
		echo "               script's stderr directly - do not assume it is benign." >&2
		return "$FYC_NO_ROW_RC"
	fi
	printf '%s' "$row" | cut -d'|' -f"$idx"
	return 0
}

# fyc_exit_meaning <script> <code>
fyc_exit_meaning() {
	if [ "$#" -ne 2 ]; then
		fyc__usage "fyc_exit_meaning: usage: fyc_exit_meaning <script> <code>"
		return "$FYC_USAGE_RC"
	fi
	fyc__field "$1" "$2" 5 meaning
}

# fyc_exit_recovery <script> <code>
fyc_exit_recovery() {
	if [ "$#" -ne 2 ]; then
		fyc__usage "fyc_exit_recovery: usage: fyc_exit_recovery <script> <code>"
		return "$FYC_USAGE_RC"
	fi
	fyc__field "$1" "$2" 6 recovery
}

# fyc_phase_of <script>
#   Prints the design-doc phase the script belongs to (1-6, or `daily`).
fyc_phase_of() {
	if [ "$#" -ne 1 ]; then
		fyc__usage "fyc_phase_of: usage: fyc_phase_of <script>"
		return "$FYC_USAGE_RC"
	fi
	local script="$1" line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if [ "$(printf '%s' "$line" | cut -d'|' -f3)" = "$script" ]; then
			printf '%s' "$line" | cut -d'|' -f1
			return 0
		fi
	done < <(fyc__table_rows)
	echo "cycle-context: ERROR: ${script} is not in the translation table." >&2
	return "$FYC_NO_ROW_RC"
}

# fyc_scripts_in_table — distinct script names, in table order.
fyc_scripts_in_table() {
	if [ "$#" -ne 0 ]; then
		fyc__usage "fyc_scripts_in_table: takes no arguments (got $#)"
		return "$FYC_USAGE_RC"
	fi
	fyc__table_rows | cut -d'|' -f3 | awk '!seen[$0]++'
	return 0
}

# fyc_exit_explain <script> <code>
#   The operator-facing form: phase, step, meaning and recovery for one
#   observed exit code, on stdout.
fyc_exit_explain() {
	if [ "$#" -ne 2 ]; then
		fyc__usage "fyc_exit_explain: usage: fyc_exit_explain <script> <code>"
		return "$FYC_USAGE_RC"
	fi
	local script="$1" code="$2" row
	if ! row="$(fyc__row "$script" "$code")"; then
		echo "cycle-context: ERROR: no entry for ${script} exit ${code} - treat as UNKNOWN." >&2
		return "$FYC_NO_ROW_RC"
	fi
	printf 'phase:    %s\n' "$(printf '%s' "$row" | cut -d'|' -f1)"
	printf 'step:     %s\n' "$(printf '%s' "$row" | cut -d'|' -f2)"
	printf 'script:   %s\n' "$script"
	printf 'exit:     %s\n' "$code"
	printf 'meaning:  %s\n' "$(printf '%s' "$row" | cut -d'|' -f5)"
	printf 'recovery: %s\n' "$(printf '%s' "$row" | cut -d'|' -f6)"
	return 0
}
