#!/usr/bin/env bash
# scripts/cycle-transition.sh — the cycle-transition orchestrator, phase C2-2:
# the six-phase skeleton and the `--print-only` fallback.
#
# CHAIN: none — this script PRINTS text and exits. It runs no step, opens no
#        socket, writes no file, sends no notification and reaches no host.
#        It deliberately offers no route to a broadcast, and never will: the
#        strings that name broadcast tooling do not appear anywhere in this
#        file, and tests/orchestrator-guard/ fails if one is added.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (read-only; prints a plan).
#
# ---------------------------------------------------------------------------
# WHAT THIS IS, AND WHAT IT IS NOT (READ THIS BEFORE TRUSTING THE OUTPUT)
# ---------------------------------------------------------------------------
# This is phase 1 of component C2 in docs/superpowers/specs/
# 2026-08-06-single-source-of-truth-design.md. Its ONLY mode is
# `--print-only`, which prints the day-of plan. THERE IS NO EXECUTION PATH IN
# THIS FILE. Not a disabled one, not a flag-guarded one — none. Execution
# arrives in C2-3 together with the post-condition-driven resume.
#
# `--print-only` is the spec's stated fallback (§8): "orchestrator が当日
# 使えなくても、その出力をそのまま実行すれば現行手順と同一になる". So the
# output is designed to be pasted:
#
#   * EVERY line of the output is either a `#` comment or a command. The
#     whole output parses as a shell script (`bash -n`), which
#     tests/cycle-transition/ asserts on every run.
#   * EVERY command line carries a trailing `# host` or `# Mac` naming the
#     machine it must run on. There are exactly two machines and no third
#     spelling.
#   * Values are resolved at print time. The output contains no `$FOO` and no
#     `${BAR}`; the test asserts zero of them. The three places where a value
#     genuinely cannot exist yet are listed under "WHAT IS NOT RESOLVED".
#
# docs/CYCLE_GATE.md REMAINS THE CANON. This file does not replace it; it
# restates it in a machine-checkable shape. tests/cycle-transition/ fails if
# the two drift — see "THE DRIFT GATE" below.
#
# ---------------------------------------------------------------------------
# WHAT IS NOT RESOLVED, AND WHY (the honest list)
# ---------------------------------------------------------------------------
# Three values are not knowable when the plan is printed. None of them is
# papered over with a plausible-looking guess:
#
#   1. THE TESTNET REHEARSAL TX ID (units 7b, 7c). It is produced by unit 7a,
#      which is downstream of a human stop. Without `--testnet-tx-id=`, those
#      two command lines print COMMENTED OUT, with the reason inline — the
#      same idiom docs/CYCLE_GATE.md step 6 already uses for a block that
#      must not be pasted as-is. Supply `--testnet-tx-id=<64hex>` after 7a
#      and they print live and fully resolved.
#   2. THE PREVIOUS ANCHOR TX ID (unit 8). It is read from the LAST LINE of
#      the host's anchor-history.jsonl, and unit 8 runs on the host while
#      this plan may be printed on the Mac. It is therefore emitted as the
#      command substitution docs/CYCLE_GATE.md step 8 already prescribes,
#      which resolves on the host at paste time. Resolving it here from a
#      file that may not exist on this machine would be a fail-OPEN guess of
#      exactly the kind design doc §6 rule (a) forbids.
#   3. UNIT 4b IS AN EDIT, NOT A COMMAND. The C4 post-issuance cleanup edits
#      two registry files by hand. Its "commands" are the verification and
#      the commit that must carry those edits; the edits themselves are
#      printed as a checklist, quoting docs/CYCLE_GATE.md step 4b.
#
# ---------------------------------------------------------------------------
# THE FOUR STOPS, AND WHERE THEY REALLY SIT
# ---------------------------------------------------------------------------
# The spec §5 sketch draws each ⏸ stop BELOW its phase. Read literally that
# ordering is wrong for all four of them, and the disagreement is not
# cosmetic — it is the difference between a runnable plan and one that stalls:
#
#   stop 1  wallet AddValidator → unit 1 waits for the node-info tick to
#           REFLECT that entry. The wallet action must precede phase 1.
#           docs/CYCLE_GATE.md agrees: it is step 0, before step 1.
#   stop 2  identity-key passphrase → gen-identity.sh (unit 4) PROMPTS for
#           it. It cannot follow phase 2.
#   stop 3  testnet keystore unlock → the rehearsal (unit 7a) needs an
#           unlocked keystore to run at all.
#   stop 4  mainnet broadcast authorization → gate 2 of the PRIME DIRECTIVE
#           is a PRE-condition of unit 7c, not a review of it. (Its second
#           half — the explorer confirmation — genuinely is after; the stop
#           text says both.)
#
# Under the reading "each ⏸ is the entry gate of the phase it is drawn with",
# all four become correct simultaneously AND match docs/CYCLE_GATE.md's step
# order. That is the reading implemented here. This is a deliberate,
# documented resolution of a spec ambiguity, not a silent reordering.
#
# ---------------------------------------------------------------------------
# THE DRIFT GATE (spec §8: "phase list と doc の step list が乖離したら CI で
# fail")
# ---------------------------------------------------------------------------
# The unit table below is reconciled by tests/cycle-transition/ against BOTH:
#
#   * docs/cycle-transition-steps.json — the 13 machine-checked execution
#     units. Every one of its ids must appear here.
#   * docs/CYCLE_GATE.md — the canonical runbook. The set of step markers in
#     its "Operator runbook" section must equal this table's ids, plus step 0
#     (the operator's wallet action, which is stop 1 here and deliberately
#     not an execution unit — that file says so itself).
#
# The two sources do not agree with each other, and this table follows the
# CANON rather than the index: docs/CYCLE_GATE.md carries STEP 4b (the C4
# post-issuance cleanup, added 2026-08-14) and docs/cycle-transition-steps.json
# — last updated 2026-08-06 — does not. So this table holds 14 units: the 13
# indexed ones plus 4b. The test pins that difference to exactly {4b}, so
# neither "4b silently disappears" nor "some other step quietly joins the
# plan" can pass.
#
# A THIRD source is cross-checked for free: scripts/lib/cycle-context.sh's
# translation table carries a phase column per script. Every script named
# here that also appears there must agree on the phase, and the check is
# enforced at PRINT TIME (not only in the test), so a plan that contradicts
# the exit-code table refuses to print rather than misdirecting recovery.
#
# ---------------------------------------------------------------------------
# WHY THE KEYSTORE UNLOCK COMMANDS ARE NOT PRINTED
# ---------------------------------------------------------------------------
# Stops 3 and 4 need a keystore unlocked. The literal unlock command is NOT
# reproduced here, by design and by CI: tests/orchestrator-guard/ fails this
# file if it contains the name of the CLI, and memory/
# feedback_no_operator_paste_execution.md records that unlock/lock are the
# operator's own two manual actions, handed over in chat at that moment, not
# copy-pasted out of a script's stdout. The stop blocks name the keystore
# HOME and cite docs/CYCLE_GATE.md step 7 for the exact wording. This is a
# REAL gap in "paste the output and you have the current procedure" and it is
# listed as such in the closing summary the plan prints about itself.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   bash scripts/cycle-transition.sh --print-only --expect-cycle=<N> \
#        --ledger=<path> [--testnet-tx-id=<64hex>]
#
#   --expect-cycle=<N>       REQUIRED. The cycle that CLOSES today — exactly
#                            the value units 4 and 5 pass as FY_EXPECT_CYCLE.
#                            Why it is not derived: see THE OFF-BY-ONE below.
#   --ledger=<path>          REQUIRED. The published cycle-history.jsonl. Not
#                            the source of the cycle number — the CHECK on it.
#                            There is no default, for the reason stated at
#                            length in scripts/lib/cycle-context.sh ("THE
#                            LEDGER ARGUMENT IS MANDATORY").
#   --testnet-tx-id=<64hex>  Optional. See "WHAT IS NOT RESOLVED" above.
#
# ---------------------------------------------------------------------------
# THE OFF-BY-ONE, AND WHY --expect-cycle IS NOT DERIVED FROM THE LEDGER
# ---------------------------------------------------------------------------
# The ledger cannot answer "which cycle closes today" on its own, and a script
# that pretends otherwise is wrong for half the day.
#
# On transition day the ledger holds N-1 rows in the morning (cycle N is still
# open) and N rows once unit 3 has published. So fyc_closed_cycle_count returns
# N-1 before phase 1 and N after it. BOTH are correct readings of the ledger,
# and they differ by one. A plan printed at 09:00 and re-printed at 14:00 —
# which is the documented workflow, since --testnet-tx-id only exists after
# unit 7a — would silently disagree with itself about the memo prefix.
#
# There is no way to tell the two states apart from the ledger alone, so this
# script does not guess. The operator declares N, exactly as docs/CYCLE_GATE.md
# already makes them declare it in units 4 and 5, and the ledger is used to
# CHECK that declaration:
#
#   closed == N-1  ->  phase 1 has not run yet. Normal at the start of the day.
#   closed == N    ->  phase 1 has landed. Normal for a re-print.
#   anything else  ->  REFUSED (exit 68), naming both numbers.
#
# The refusal is the point. The cycle number becomes the memo prefix of an
# append-only on-chain inscription; a plausible-looking off-by-one there is not
# recoverable, and 2026-07-01 is what an unrecoverable anchor mistake costs.
#
# Required environment (refused if unset — see fyct__require_env):
#   VALIDATOR_HOST       the validator host. Never literal in this repo
#                        (memory/feedback_no_literal_host_identifier.md);
#                        same convention as scripts/sync-to-validator-host.sh.
#   VALIDATOR_HOST_KEY   the ssh key path for it. Required here rather than
#                        defaulted, because the repo-wide default is the
#                        literal placeholder `~/.ssh/<your_validator_host_key>`
#                        and `<`/`>` are redirection operators — printing it
#                        would emit a line that cannot be pasted (the exact
#                        trap docs/CYCLE_GATE.md step 6 warns about).
# Optional environment:
#   VALIDATOR_HOST_USER  defaults to root, as in the sibling scripts.
#   FY_CONFIG_DIR        defaults to $HOME/.fy-mainnet-broadcast/config,
#                        RESOLVED TO AN ABSOLUTE PATH at print time. That
#                        resolution is not cosmetic: it removes the zsh
#                        assignment-ordering pitfall documented at length in
#                        docs/CYCLE_GATE.md step 7c, because an absolute path
#                        cannot be re-pointed by a later HOME= prefix.
#
# Exit codes:
#   0   the plan was printed
#   64  usage error (unknown flag, missing argument, missing required env)
#   65  the ledger is unreadable        (propagated from cycle-context.sh)
#   66  the ledger is self-inconsistent (propagated from cycle-context.sh)
#   67  the phase cross-check against cycle-context.sh's table disagrees
#   68  the ledger disagrees with --expect-cycle (see THE OFF-BY-ONE)

# Self-locating, like scripts/lib/publish-scan.sh: the libraries are resolved
# from THIS file's own path, never from the caller's CWD. There is deliberately
# no repo-root variable — this script reads no repo file and executes no repo
# script, and a path root it does not need is a path root a later edit could
# quietly start executing from.
FYCT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/cycle-context.sh
. "${FYCT_SELF_DIR}/lib/cycle-context.sh"

# scripts/lib/side-effects.sh is sourced for exactly one thing: fyd_is_live,
# so that "what does live mean" is read from the one place that defines it
# rather than re-spelled here. NO fyd_* side-effect function is called
# anywhere in this file, because this phase performs no side effect to gate.
# When C2-3 adds execution, every side effect it performs goes through this
# library — that is the point of sourcing it now rather than later.
# shellcheck source=scripts/lib/side-effects.sh
. "${FYCT_SELF_DIR}/lib/side-effects.sh"

FYCT_USAGE_RC=64
FYCT_PHASE_MISMATCH_RC=67
FYCT_LEDGER_DISAGREES_RC=68

# ---------------------------------------------------------------------------
# The phase table
# ---------------------------------------------------------------------------
# Rows are `phase|label|stop_number|stop_text`. A stop_number of `-` means the
# phase has no human intervention on entry. Held in a function rather than a
# `$(cat <<EOF)` variable for the bash 3.2 reason documented in
# scripts/lib/cycle-context.sh's fyc__table_rows: on the macOS system bash,
# apostrophes inside a quoted heredoc that sits inside a command substitution
# flip the parser's quote parity and can turn the whole file into a syntax
# error. A heredoc inside a function body is not inside a command
# substitution, so it cannot happen. No field may contain `|`.
fyct__phase_rows() {
	cat <<'FYCT_PHASE_EOF'
1|記録 / record|1|OPERATOR, IN THE METAL WALLET WEB UI. Submit the new AddValidator (the stake amount is decided on the day, by the operator, and by nobody else), watch the tx reach Committed on the explorer, and confirm the new entry is visible in the current validator set. This is the one human-driven state change of the day and the precondition for unit 1 below, which waits for that entry to appear. Do NOT start phase 1 on the submit alone. Full field-by-field form: docs/VALIDATOR_RENEWAL.md Step 2.
2|identity|2|OPERATOR, AT A TTY. Unit 4 prompts for the operator identity key passphrase; it is held in Dashlane (see docs/OPERATOR_IDENTITY_SETUP.md). The prompt appears when gen-identity.sh runs, so the passphrase is a precondition of phase 2, not a review of it.
3|compose|-|-
4|rehearsal|3|OPERATOR, AT A TTY. Unlock the PROJECT TESTNET keystore (HOME=~/.metal-fy-proton-test) — the unlock command itself is handed over in chat, not printed here (see this script's header, "WHY THE KEYSTORE UNLOCK COMMANDS ARE NOT PRINTED"; exact wording in docs/CYCLE_GATE.md step 7a). Unit 7a cannot run against a locked keystore: it exits 2. This is also where testnet broadcast authorization is given.
5|刻印 / inscribe|4|OPERATOR, TWICE. (a) BEFORE unit 7c: unlock the SEPARATE MAINNET keystore (HOME=~/.metal-fy-proton) and give the PRIME DIRECTIVE gate-2 per-invocation authorization, naming chain, actor, permission, action, memo and quantity explicitly. Gate 2 is a precondition, not a review. (b) AFTER unit 7c: confirm the transaction on the explorer by eye, then re-lock the mainnet keystore — its prompt reads "Enter 32 character password (leave empty to create new)", and an empty Enter there creates a NEW password instead of locking with the existing one.
6|事後 / post|-|-
FYCT_PHASE_EOF
}

# ---------------------------------------------------------------------------
# The unit table
# ---------------------------------------------------------------------------
# Rows are `id|phase|machine|scripts|title`.
#
#   id       matches docs/cycle-transition-steps.json, plus 4b from
#            docs/CYCLE_GATE.md (see THE DRIFT GATE in the header).
#   machine  exactly `host` or `Mac`. There is no third value; the test
#            enforces the closed set, because "which machine" is the single
#            most consequential fact on each line and a typo'd third spelling
#            would read as a new machine rather than as a mistake.
#   scripts  space-separated, `-` when the unit runs no repo script. Used by
#            the test to cross-check the phase against
#            scripts/lib/cycle-context.sh's translation table.
#
# ORDER IS LOAD-BEARING and is docs/CYCLE_GATE.md's order verbatim.
fyct__unit_rows() {
	cat <<'FYCT_UNIT_EOF'
1|1|host|-|wait for the node-info tick to reflect the new AddValidator endTime
2|1|host|uptime-history.sh|close out the just-ended cycle's uptime record
3|1|host|gen-cycle-history.sh push-to-web-host.sh|append the cycle row to the ledger and publish it
4|2|Mac|operator-local/gen-identity.sh|regenerate the signed identity manifest for the new cycle
4b|2|Mac|-|C4 post-issuance cleanup, then commit + push + wait for deploy
5|3|host|gen-anchor-source.sh|compose the fresh 3-branch anchor-source DAG
6|3|Mac|operator-local/commit-anchor-source.sh|fetch + verify + commit the host-composed anchor-source, push, wait for deploy
7a|4|Mac|run-testnet-rehearsal.sh|testnet rehearsal of this cycle's exact memo shape (gate-1 material)
7b|5|Mac|preview-cycle-anchor-broadcast.sh|mainnet dry run from the committed bytes (gate-4 material)
7c|5|Mac|sign-anchor-event.sh|sign the 4-action anchor pack
7.5|5|Mac|-|transfer the signing fragment from the Mac to the host
8|6|host|gen-anchor-receipt.sh append-anchor-history.sh|7-gate verify the transaction, then append it to the anchor ledger
8.5|6|host|push-to-web-host.sh|publish the two canonical flat files
9|6|host|resume-after-cycle-start.sh|record the cycle-gate approval state
FYCT_UNIT_EOF
}

# fyct_unit_ids — the unit ids, in plan order. The single enumeration; the
# test and the printer both read it, so a row added to the table above cannot
# be printed without also being counted, or counted without being printed.
fyct_unit_ids() {
	fyct__unit_rows | cut -d'|' -f1
}

fyct__unit_field() {
	local id="$1" idx="$2" line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if [ "$(printf '%s' "$line" | cut -d'|' -f1)" = "$id" ]; then
			printf '%s' "$line" | cut -d"|" -f"$idx"
			return 0
		fi
	done < <(fyct__unit_rows)
	return 1
}

fyct_unit_phase()   { fyct__unit_field "$1" 2; }
fyct_unit_machine() { fyct__unit_field "$1" 3; }
fyct_unit_scripts() { fyct__unit_field "$1" 4; }
fyct_unit_title()   { fyct__unit_field "$1" 5; }

# ---------------------------------------------------------------------------
# Print-time consistency check against scripts/lib/cycle-context.sh
# ---------------------------------------------------------------------------
# Eight of the scripts named in the unit table also carry a phase in
# cycle-context.sh's exit-code translation table. If the two disagree, the
# recovery advice an operator would be given points at the wrong phase — so
# the plan refuses to print rather than printing a plan that contradicts the
# table used to interpret its failures. Scripts absent from that table are
# skipped silently: it covers exit codes, not steps, and never claimed to
# name every script in the pipeline.
fyct__check_phase_agreement() {
	local id phase scripts s ctx_phase bad=0
	while IFS= read -r id; do
		[ -n "$id" ] || continue
		phase="$(fyct_unit_phase "$id")"
		scripts="$(fyct_unit_scripts "$id")"
		[ "$scripts" = "-" ] && continue
		for s in $scripts; do
			# Only the basename is in the translation table.
			s="${s##*/}"
			if ctx_phase="$(fyc_phase_of "$s" 2>/dev/null)"; then
				if [ "$ctx_phase" != "$phase" ]; then
					echo "cycle-transition: ERROR: phase disagreement for ${s}: this plan says phase ${phase}, scripts/lib/cycle-context.sh says phase ${ctx_phase}." >&2
					bad=1
				fi
			fi
		done
	done < <(fyct_unit_ids)
	if [ "$bad" -ne 0 ]; then
		echo "cycle-transition:        Refusing to print. One of the two tables is wrong, and a plan whose" >&2
		echo "cycle-transition:        phases contradict the exit-code table would send recovery to the wrong phase." >&2
		return "$FYCT_PHASE_MISMATCH_RC"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Printing helpers
# ---------------------------------------------------------------------------

# c <text...> — one comment line.
fyct__c() { printf '# %s\n' "$*"; }
# blank comment line (keeps the whole output a valid shell script).
fyct__cb() { printf '#\n'; }
fyct__rule() { printf '# %s\n' "----------------------------------------------------------------------------"; }

# cmd <machine> <command-text>
#   One command line, with the machine as a trailing comment. Every command
#   the plan emits goes through here, so no line can reach the output without
#   naming its machine.
fyct__cmd() {
	local machine="$1"
	shift
	printf '%s  # %s\n' "$*" "$machine"
}

# cmd_pending <machine> <reason-tag> <command-text>
#   The same, COMMENTED OUT, for a command that cannot be resolved yet.
fyct__cmd_pending() {
	local machine="$1" tag="$2"
	shift 2
	printf '# [%s] %s  # %s\n' "$tag" "$*" "$machine"
}

# fyct__wrap <indent> <text> — wrap prose into comment lines at ~76 columns
# without needing `fold`/`fmt` (neither is guaranteed on both machines).
fyct__wrap() {
	local indent="$1" text="$2" line="" word
	for word in $text; do
		if [ -z "$line" ]; then
			line="$word"
		elif [ "${#line}" -ge 68 ]; then
			printf '# %s%s\n' "$indent" "$line"
			line="$word"
		else
			line="$line $word"
		fi
	done
	[ -n "$line" ] && printf '# %s%s\n' "$indent" "$line"
	return 0
}

fyct__require_env() {
	local missing=""
	[ -n "${VALIDATOR_HOST:-}" ] || missing="VALIDATOR_HOST"
	[ -n "${VALIDATOR_HOST_KEY:-}" ] || missing="${missing:+$missing }VALIDATOR_HOST_KEY"
	if [ -n "$missing" ]; then
		echo "cycle-transition: ERROR: required environment not set: ${missing}" >&2
		echo "                  --print-only exists to emit commands that can be PASTED, so it refuses" >&2
		echo "                  to print a plan containing a placeholder the shell would choke on." >&2
		echo "                  Export both, then re-run (same convention as scripts/sync-to-validator-host.sh):" >&2
		echo "                    export VALIDATOR_HOST=<validator host IP or hostname>" >&2
		echo "                    export VALIDATOR_HOST_KEY=~/.ssh/<your validator host key>" >&2
		return "$FYCT_USAGE_RC"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# The per-unit command blocks
# ---------------------------------------------------------------------------
# Every command below is docs/CYCLE_GATE.md's, with its placeholders
# substituted. Where this file states something the runbook does not, the
# difference is called out in an inline comment, because a silent divergence
# from the canon is exactly what the drift gate exists to prevent.
#
# Reads these globals, all resolved by main(): N, INSCRIBE, VH, VHK, VHU,
# CFG, TTX, TTX_KNOWN.
fyct__unit_commands() {
	local id="$1" m
	m="$(fyct_unit_machine "$id")"

	case "$id" in
	1)
		fyct__wrap "  " "Repeat until endTime is the NEW AddValidator entry's. The metal-node-info cron rewrites this file every 5 minutes, so a file whose mtime is under 5 minutes old is fresh."
		fyct__wrap "  " "Do NOT query the P-chain RPC directly to check this: scripts/broadcast-guard.sh refuses that command shape unconditionally, by shape alone, and reading this cron artifact is the sanctioned way to observe chain state (docs/CYCLE_GATE.md step 0)."
		fyct__cmd "$m" "jq -r '{endTime: .endTime, observedAt: .observedAt}' public/api/validator.json"
		;;
	2)
		fyct__wrap "  " "FY_LIVE=1 is REQUIRED and docs/CYCLE_GATE.md step 2 does not show it — that step carries no command block at all. Measured 2026-08-14: every write in uptime-history.sh goes through fyd_live_write / fyd_live_run (lines 91-107, 166, 257) and the file contains no ungated redirect write, so without the opt-in this step is a loud but complete no-op and the cycle never closes."
		fyct__cmd "$m" "FY_LIVE=1 bash scripts/uptime-history.sh"
		;;
	3)
		fyct__wrap "  " "The publish is neither optional nor automatic: units 4 and 5 read the PUBLISHED ledger, so skipping it makes gen-identity.sh exit 7 and gen-anchor-source.sh exit 9 against a stale count."
		fyct__cmd "$m" "bash scripts/gen-cycle-history.sh"
		fyct__cmd "$m" "bash scripts/push-to-web-host.sh cycle-history.jsonl"
		fyct__wrap "  " "Confirm the published copy grew by exactly one line and now holds ${N} records before continuing."
		fyct__cmd "$m" "curl -fsS 'https://metal.freedom-yield.com/api/cycle-history.jsonl' | grep -cve '^[[:space:]]*\$' || true"
		;;
	4)
		fyct__wrap "  " "FY_EXPECT_CYCLE is the CLOSED-cycle count (${N}), not the number being inscribed. It is mandatory at a transition: it hard-stops with exit 7 if unit 3's publish has not landed."
		fyct__wrap "  " "This is the command that prompts for the identity-key passphrase (stop 2)."
		fyct__cmd "$m" "FY_EXPECT_CYCLE=${N} OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity bash scripts/operator-local/gen-identity.sh"
		;;
	4b)
		fyct__wrap "  " "MANDATORY, and it must land in the SAME COMMIT as unit 4's identity.json or tests/publication-registry/ goes red on main. These are hand edits, not commands — quoted from docs/CYCLE_GATE.md step 4b, which is the canonical wording:"
		fyct__cb
		fyct__wrap "    " "(a) deploy/identity-pin-baseline.json — delete all three known_broken entries (evidence_json.sha256, validator_json.sha256, uptime_cycles_json.sha256) and the c4_status block with them."
		fyct__wrap "    " "(b) deploy/publication.json — set known_kind_violations.violations to {}, and clear pinned_by on api/evidence.json, api/validator.json, api/cycle-history.jsonl and api/uptime-cycles.json."
		fyct__wrap "    " "(c) deploy/publication.json — add pinned_by for api/incidents.schema.v1.json and for the api/archive/ directory row."
		fyct__cb
		fyct__wrap "  " "docs/CYCLE_GATE.md step 4b also records an open item that must be corrected BEFORE this step runs: the record_caveat on the api/archive/ row still says STRUCTURALLY immutable on the basis of a grep for a field name that is actually spelled computed_at. Read that step before editing."
		fyct__cmd "$m" "bash tests/publication-registry/test-publication-registry.sh"
		fyct__cmd "$m" "git add public/api/identity.json deploy/identity-pin-baseline.json deploy/publication.json"
		fyct__cmd "$m" "git commit -m 'chore(identity): cycle ${INSCRIBE} identity manifest + C4 post-issuance cleanup'"
		fyct__cmd "$m" "git push"
		fyct__cmd "$m" "gh run watch"
		;;
	5)
		fyct__wrap "  " "Expect exactly one 'side-effects: WARNING: state dir falls back to the production default' line. It is correct here — this script only READS the production streams. Do NOT point FY_STATE_DIR at a sandbox (it would compose the DAG from empty inputs) and do NOT add FY_LIVE=1 (it writes no production state)."
		fyct__wrap "  " "Its ordering guard is exit 9, not 7. Its exit 7 means an atomic write failed — a different condition."
		fyct__cmd "$m" "FY_EXPECT_CYCLE=${N} bash scripts/gen-anchor-source.sh"
		;;
	6)
		fyct__wrap "  " "Meaning switch from unit 5, deliberate: --expect-cycle here is the number being INSCRIBED (${INSCRIBE}), compared against the fetched file's observations_branch.cycle_number_observed. Passing ${N} exits 5."
		fyct__cmd "$m" "export VALIDATOR_HOST=${VH}"
		fyct__cmd "$m" "export VALIDATOR_HOST_KEY=${VHK}"
		fyct__cmd "$m" "bash scripts/operator-local/commit-anchor-source.sh --expect-cycle=${INSCRIBE}"
		fyct__wrap "  " "Push and deploy are separate and NOT optional: anchor-source.json publishes via git-deploy, and until it lands unit 9's Phase 1 never sees a fresh dag_root_computed and times out with exit 3."
		fyct__cmd "$m" "git push"
		fyct__cmd "$m" "gh run watch"
		;;
	7a)
		fyct__wrap "  " "Run this only AFTER unit 6 has landed. Against the real committed file the default source selection is correct, so no --source= and no fixture override is needed. Running it earlier against a hand-built fixture is what cost an extra reconciliation on 2026-08-04."
		fyct__cmd "$m" "HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=${INSCRIBE}"
		fyct__wrap "  " "Copy the closing 'TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>' line verbatim — it is the gate-1 input for units 7b and 7c, and it is valid only for cycle ${INSCRIBE}. Re-run this script with --testnet-tx-id=<that id> to print 7b and 7c fully resolved."
		fyct__wrap "  " "Then clear the rehearsal's leftover chain-bound token. It is bound to the testnet chain and cannot authorize the mainnet step, but leaving it makes /tmp harder to read before 7b/7c."
		fyct__cmd "$m" "rm -f /tmp/fyd-broadcast-token"
		;;
	7b)
		fyct__wrap "  " "From the ALREADY-COMMITTED bytes, with no recompose. It refuses with exit 9 if the source differs from git show HEAD:public/api/anchor-source.json, and with exit 10 if the live public copy does not yet serve those same bytes. It composes nothing and sends nothing."
		fyct__wrap "  " "Do not run it on the validator host: the keystore separation guard refuses a login-HOME invocation with exit 8, and a host-side recompose would produce a different dag_root_computed because the artifacts branch hashes feeds the 5-minute crons rewrite."
		fyct__wrap "  " "FY_CONFIG_DIR is printed as an absolute path on purpose: that sidesteps the zsh left-to-right assignment-ordering trap that silently relocates the config dir inside the keystore when it is written home-relative. Deliberate: no line of this plan contains a shell variable reference, so nothing in it can resolve differently in the shell that pastes it."
		if [ "$TTX_KNOWN" = "1" ]; then
			fyct__cmd "$m" "FY_CONFIG_DIR=${CFG} HOME=~/.metal-fy-proton bash scripts/preview-cycle-anchor-broadcast.sh --source=public/api/anchor-source.json --testnet-tx-id=${TTX}"
		else
			fyct__wrap "  " "NOT RESOLVED: the rehearsal tx id does not exist until unit 7a has run. The line below is COMMENTED OUT deliberately — substitute the real id, or re-run this script with --testnet-tx-id=<64hex>."
			fyct__cmd_pending "$m" "NEEDS 7a TX ID" "FY_CONFIG_DIR=${CFG} HOME=~/.metal-fy-proton bash scripts/preview-cycle-anchor-broadcast.sh --source=public/api/anchor-source.json --testnet-tx-id=<64hex from unit 7a>"
		fi
		;;
	7c)
		fyct__wrap "  " "Requires the stop-4(a) authorization above. Both gate args are mandatory; unit 7b prints this same command with them already filled in, and that printed form is the one to prefer on the day."
		fyct__wrap "  " "Its stdout is additionally saved to /tmp/fya-mainnet-sign-output.json, which is unit 7.5's input."
		if [ "$TTX_KNOWN" = "1" ]; then
			fyct__cmd "$m" "FY_CONFIG_DIR=${CFG} HOME=~/.metal-fy-proton bash scripts/sign-anchor-event.sh --chain=mainnet-a --anchor-source=public/api/anchor-source.json --testnet-tx-id=${TTX} --dry-run-log=/tmp/fya-mainnet-dryrun.json"
		else
			fyct__wrap "  " "NOT RESOLVED: same reason as unit 7b. Commented out deliberately."
			fyct__cmd_pending "$m" "NEEDS 7a TX ID" "FY_CONFIG_DIR=${CFG} HOME=~/.metal-fy-proton bash scripts/sign-anchor-event.sh --chain=mainnet-a --anchor-source=public/api/anchor-source.json --testnet-tx-id=<64hex from unit 7a> --dry-run-log=/tmp/fya-mainnet-dryrun.json"
		fi
		;;
	7.5)
		fyct__wrap "  " "Typed on the Mac, lands on the host. Unit 8 reads the destination path. The chmod is defensive: this connects as root while unit 8 runs as the deploy user, and a restrictive root umask would otherwise leave the file unreadable to it."
		fyct__cmd "$m" "scp -i ${VHK} /tmp/fya-mainnet-sign-output.json ${VHU}@${VH}:/home/deploy/.fya-sign-output.json"
		fyct__cmd "$m" "ssh -i ${VHK} ${VHU}@${VH} 'chmod 644 /home/deploy/.fya-sign-output.json'"
		;;
	8)
		fyct__wrap "  " "--prev-anchor-tx-id is NOT derived from anything else, and it is read on the host from the last line of the anchor ledger — so it is emitted as the command substitution docs/CYCLE_GATE.md step 8 prescribes, which resolves at paste time on the host. Omitting it, or passing a stale value, writes a wrong prev link into the receipt and then fails append invariant 6. Only genesis may be null."
		fyct__cmd "$m" "bash scripts/gen-anchor-receipt.sh --input=/home/deploy/.fya-sign-output.json --anchor-source=public/api/anchor-source.json --trigger=cyclestart --prev-anchor-tx-id=\"\$(tail -n 1 public/api/anchor-history.jsonl | jq -r '.tx_id')\""
		fyct__wrap "  " "FY_LIVE=1 is required on the append, but not for the reason it usually is: the append itself happens either way, deliberately, because a forgotten opt-in must never cost a line in an append-only ledger. What the opt-in gates is the automatic R18 archive push. gen-anchor-receipt.sh needs no opt-in at all."
		fyct__cmd "$m" "FY_LIVE=1 bash scripts/append-anchor-history.sh --receipt=public/api/anchor-receipt.json --event-type=cyclestart"
		;;
	8.5)
		fyct__wrap "  " "Two, not four. These are the canonical flat copies unit 8 just wrote locally. Skip this and the public feeds keep serving the PREVIOUS cycle even though the anchor already succeeded — unit 9 polls only anchor-source.json freshness, so it will NOT catch a missed push here. anchor-source.json is not in this list: it is git-deploy owned."
		fyct__cmd "$m" "bash scripts/push-to-web-host.sh anchor-receipt.json"
		fyct__cmd "$m" "bash scripts/push-to-web-host.sh anchor-history.jsonl"
		fyct__wrap "  " "The two R18 per-anchor archive copies are pushed automatically by unit 8's append. That push is best-effort: if stderr or an alert shows 'R18 publish FAILED' or 'R18 publish skipped', re-run the manual retry command it prints."
		;;
	9)
		fyct__wrap "  " "FY_LIVE=1 is required; without it the script refuses with exit 6 before Phase 1 and writes nothing. No broadcast and no explorer URL here — this only records cycle-gate approval state."
		fyct__cmd "$m" "FY_LIVE=1 bash scripts/resume-after-cycle-start.sh --apply"
		;;
	*)
		echo "cycle-transition: ERROR: no command block for unit '${id}' — the unit table and the command blocks have drifted." >&2
		return 1
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------
fyct_print_plan() {
	local id phase machine title last_phase="" prow plabel pstop ptext

	fyct__c "============================================================================"
	fyct__c "Metal Freedom Yield — cycle transition plan"
	fyct__c "PRINT ONLY. Nothing below has been executed, and this script has no code"
	fyct__c "path that could execute it."
	fyct__c "============================================================================"
	fyct__c "printed by     : scripts/cycle-transition.sh --print-only"
	fyct__c "printed at     : ${PRINTED_AT}"
	fyct__c "ledger read    : ${LEDGER}"
	fyct__c "cycle closing today (N)  : ${N}    (declared via --expect-cycle)"
	fyct__c "cycle to inscribe (N+1)  : ${INSCRIBE}"
	fyct__c "ledger cross-check       : ${PHASE1_STATE}"
	fyct__c "validator host : ${VH}"
	fyct__c "host ssh key   : ${VHK}"
	fyct__c "host ssh user  : ${VHU}"
	fyct__c "mainnet config : ${CFG}"
	if [ "$TTX_KNOWN" = "1" ]; then
		fyct__c "rehearsal tx   : ${TTX}"
	else
		fyct__c "rehearsal tx   : not supplied — units 7b and 7c print commented out"
	fi
	if fyd_is_live; then
		fyct__c "FY_LIVE here   : 1 — LIVE. Pasting these commands into THIS shell will"
		fyct__c "                 perform production side effects."
	else
		fyct__c "FY_LIVE here   : ${FY_LIVE:-<unset>} (not live). Note that several commands below set"
		fyct__c "                 FY_LIVE=1 themselves, as the canon requires."
	fi
	fyct__cb
	fyct__c "HOW TO READ THIS"
	fyct__wrap "  " "Every line is either a comment or a command. Each command ends with the machine it runs on: '# host' is the validator host, '# Mac' is the operator Mac. There is no third machine."
	fyct__wrap "  " "The four STOP blocks are human actions. This script performs none of them, and it holds no route to a broadcast — phases 4 and 5 print and stop, permanently, enforced by tests/orchestrator-guard/."
	fyct__wrap "  " "docs/CYCLE_GATE.md remains the canon. This plan restates it with values filled in; where the two differ, an inline comment says so."
	fyct__c "============================================================================"
	printf '\n'

	while IFS= read -r id; do
		[ -n "$id" ] || continue
		phase="$(fyct_unit_phase "$id")"
		machine="$(fyct_unit_machine "$id")"
		title="$(fyct_unit_title "$id")"

		if [ "$phase" != "$last_phase" ]; then
			prow="$(fyct__phase_rows | grep "^${phase}|")"
			plabel="$(printf '%s' "$prow" | cut -d'|' -f2)"
			pstop="$(printf '%s' "$prow" | cut -d'|' -f3)"
			ptext="$(printf '%s' "$prow" | cut -d'|' -f4)"

			if [ "$pstop" != "-" ]; then
				fyct__rule
				fyct__c "⏸ STOP ${pstop} — entry gate of phase ${phase}"
				fyct__wrap "  " "$ptext"
				fyct__rule
				printf '\n'
			fi

			fyct__c "=== PHASE ${phase} — ${plabel} ============================================"
			last_phase="$phase"
		fi

		fyct__cb
		fyct__c "[unit ${id}] ${machine} — ${title}"
		fyct__unit_commands "$id"
		printf '\n'
	done < <(fyct_unit_ids)

	# Closing self-assessment. Stated in the output itself, not only in a
	# report, because the person pasting this is the person who needs to know
	# where it stops being a faithful copy of the runbook.
	fyct__c "============================================================================"
	fyct__c "WHERE THIS PLAN IS NOT A COMPLETE SUBSTITUTE FOR docs/CYCLE_GATE.md"
	fyct__cb
	fyct__wrap "  " "1. The keystore unlock and re-lock commands for stops 3 and 4 are NOT printed. tests/orchestrator-guard/ fails this file if it names the signing CLI, and those two are the operator's own manual actions, handed over in chat. Get their exact wording from docs/CYCLE_GATE.md step 7."
	if [ "$TTX_KNOWN" != "1" ]; then
		fyct__wrap "  " "2. Units 7b and 7c are commented out because the rehearsal tx id does not exist yet. Re-run with --testnet-tx-id=<64hex> once unit 7a has printed its sentinel."
	else
		fyct__wrap "  " "2. Units 7b and 7c are resolved against the supplied rehearsal tx id. Verify it is THIS cycle's (cycle ${INSCRIBE}) — a stale id from an earlier rehearsal satisfies the shape check and fails gate 1."
	fi
	fyct__wrap "  " "3. Unit 8's --prev-anchor-tx-id resolves on the host at paste time, by design; it is not a value this plan could know."
	fyct__wrap "  " "4. Unit 4b is a set of hand edits. Only its verification and commit are commands."
	fyct__wrap "  " "5. This plan does not execute, verify, or resume. Post-condition-driven resume is C2-3."
	fyct__c "============================================================================"
	return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
fyct_main() {
	set -euo pipefail

	local mode="" ledger="" ttx="" expect=""
	local usage="usage: bash scripts/cycle-transition.sh --print-only --expect-cycle=<N> --ledger=<path> [--testnet-tx-id=<64hex>]"

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--print-only)
			mode="print-only"
			shift
			;;
		--expect-cycle=*)
			expect="${1#--expect-cycle=}"
			shift
			;;
		--ledger=*)
			ledger="${1#--ledger=}"
			shift
			;;
		--testnet-tx-id=*)
			ttx="${1#--testnet-tx-id=}"
			shift
			;;
		-h | --help)
			echo "$usage" >&2
			echo "       --print-only is the only mode; this phase has no execution path." >&2
			echo "       --expect-cycle is the cycle CLOSING today (the FY_EXPECT_CYCLE value)." >&2
			return 0
			;;
		*)
			echo "cycle-transition: ERROR: unknown argument: $1" >&2
			echo "                  ${usage}" >&2
			return "$FYCT_USAGE_RC"
			;;
		esac
	done

	if [ "$mode" != "print-only" ]; then
		echo "cycle-transition: ERROR: --print-only is required." >&2
		echo "                  It is the ONLY mode this script has. Execution is deliberately absent" >&2
		echo "                  in this phase (C2-2); it arrives in C2-3 with the resume logic." >&2
		return "$FYCT_USAGE_RC"
	fi
	if [ -z "$ledger" ]; then
		echo "cycle-transition: ERROR: --ledger=<path> is required." >&2
		echo "                  There is no default, deliberately: on the validator host a defaulted" >&2
		echo "                  path would silently answer from a local mirror while looking inert on" >&2
		echo "                  a developer machine (scripts/lib/cycle-context.sh, THE LEDGER ARGUMENT" >&2
		echo "                  IS MANDATORY)." >&2
		return "$FYCT_USAGE_RC"
	fi
	if [ -z "$expect" ]; then
		echo "cycle-transition: ERROR: --expect-cycle=<N> is required." >&2
		echo "                  N is the cycle that CLOSES today — the same number units 4 and 5 pass" >&2
		echo "                  as FY_EXPECT_CYCLE. It is NOT derived from the ledger: the ledger holds" >&2
		echo "                  N-1 rows before phase 1 and N rows after it, both are legitimate, and" >&2
		echo "                  guessing between them would move the on-chain memo prefix by one." >&2
		return "$FYCT_USAGE_RC"
	fi
	if ! printf '%s' "$expect" | grep -qE '^[1-9][0-9]*$'; then
		echo "cycle-transition: ERROR: --expect-cycle must be a positive integer (got '${expect}')." >&2
		return "$FYCT_USAGE_RC"
	fi
	if [ -n "$ttx" ] && ! printf '%s' "$ttx" | grep -qE '^[0-9a-fA-F]{64}$'; then
		echo "cycle-transition: ERROR: --testnet-tx-id must be 64 hex characters (got ${#ttx})." >&2
		return "$FYCT_USAGE_RC"
	fi

	fyct__require_env || return $?

	# Globals the command blocks read.
	LEDGER="$ledger"
	N="$expect"
	INSCRIBE="$((expect + 1))"

	# The ledger CHECKS the declaration; it does not supply it. See THE
	# OFF-BY-ONE in the header for why both accepted states exist.
	CLOSED="$(fyc_closed_cycle_count "$ledger")" || return $?
	if [ "$CLOSED" -eq "$((N - 1))" ]; then
		PHASE1_STATE="phase 1 has NOT run yet (ledger holds ${CLOSED} closed cycles; unit 3 will make it ${N})"
	elif [ "$CLOSED" -eq "$N" ]; then
		# Phase 1 has landed, so the library's own inscribe derivation is now
		# answerable and must agree with the declaration. Asserting it rather
		# than assuming it is the whole reason the ledger is read at all.
		local lib_inscribe
		lib_inscribe="$(fyc_cycle_number_to_inscribe "$ledger")" || return $?
		if [ "$lib_inscribe" != "$INSCRIBE" ]; then
			echo "cycle-transition: ERROR: internal disagreement — cycle-context derives ${lib_inscribe} to inscribe, this plan says ${INSCRIBE}." >&2
			return "$FYCT_LEDGER_DISAGREES_RC"
		fi
		PHASE1_STATE="phase 1 HAS landed (ledger holds ${CLOSED} closed cycles, agreeing with --expect-cycle)"
	else
		echo "cycle-transition: ERROR: the ledger disagrees with --expect-cycle=${N}." >&2
		echo "                  ledger closed-cycle count : ${CLOSED}" >&2
		echo "                  expected                  : $((N - 1)) (before phase 1) or ${N} (after unit 3)" >&2
		echo "                  Neither matches, so one of the two is wrong. Do NOT proceed: this number" >&2
		echo "                  becomes the memo prefix of an append-only on-chain inscription." >&2
		echo "                  Check that --ledger points at the PUBLISHED cycle-history.jsonl and that" >&2
		echo "                  --expect-cycle names the cycle closing today, not the one being inscribed." >&2
		return "$FYCT_LEDGER_DISAGREES_RC"
	fi

	VH="$VALIDATOR_HOST"
	VHK="$VALIDATOR_HOST_KEY"
	VHU="${VALIDATOR_HOST_USER:-root}"
	CFG="${FY_CONFIG_DIR:-${HOME}/.fy-mainnet-broadcast/config}"
	TTX="$ttx"
	TTX_KNOWN=0
	[ -n "$ttx" ] && TTX_KNOWN=1
	PRINTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	fyct__check_phase_agreement || return $?

	fyct_print_plan
	return 0
}

# Sourcing this file defines its functions and runs nothing, so the test suite
# can exercise the table and the printer directly (including by replacing
# fyct__unit_rows to prove the coverage assertions can actually fail).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	fyct_main "$@"
fi
