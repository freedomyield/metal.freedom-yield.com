#!/usr/bin/env bash
# scripts/cycle-transition.sh — the cycle-transition orchestrator, phases C2-2
# and C2-3: the six-phase skeleton, the `--print-only` fallback, and the
# post-condition `--status` reading.
#
# CHAIN: none — this script PRINTS text and exits. It runs no transition step,
#        writes no production file, sends no notification, opens no shell on
#        another machine, and holds no route to a broadcast.
#        Stated precisely, because the loose version is false: the
#        broadcast-tool names DO occur here as SUBSTRINGS — the keystore paths
#        the plan prints contain one inside a hyphenated directory name. What
#        tests/orchestrator-guard/ forbids, and what is absent, is any
#        occurrence its word-boundary scan accepts: the tool named as a
#        command rather than buried in an identifier. That test fails if one
#        is added.
#        The two modes differ in what they READ, and the difference is stated
#        rather than averaged: `--print-only` opens no socket and reads
#        nothing but the ledger path it was handed. `--status` reads — an
#        HTTP GET of the published feeds (or a local directory of
#        already-fetched bytes), `git show` of one committed blob, and local
#        files named on the command line — into a private scratch directory
#        it removes on exit. Neither mode ssh's, pushes, notifies, or writes
#        anywhere else.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (read-only; prints a plan or a
#                  reading).
#
# ---------------------------------------------------------------------------
# WHAT THIS IS, AND WHAT IT IS NOT (READ THIS BEFORE TRUSTING THE OUTPUT)
# ---------------------------------------------------------------------------
# This is component C2 in docs/superpowers/specs/
# 2026-08-06-single-source-of-truth-design.md. It has exactly two modes:
#
#   --print-only  prints the day-of plan (C2-2).
#   --status      re-measures each phase's POST-CONDITION and reports where
#                 the day actually stopped (C2-3).
#
# THERE IS NO EXECUTION PATH IN THIS FILE. Not a disabled one, not a
# flag-guarded one — none. `--status` decides where the day stopped; it does
# not restart it, and nothing here invokes a transition step. Adding execution
# is a later task and a separate decision, not a consequence of this one.
#
# `--print-only` is the spec's stated fallback (§8): "orchestrator が当日
# 使えなくても、その出力をそのまま実行すれば現行手順と同一になる". So the
# output is designed to be pasted:
#
#   * EVERY line of the output is either a `#` comment or a command. The
#     whole output parses as a shell script (`bash -n`), which
#     tests/cycle-transition/ asserts on every run.
#   * THE WHOLE PLAN IS TYPED ON THE MAC. Every command line carries a
#     trailing `# host` or `# Mac` naming where it EXECUTES, and a `# host`
#     line already carries the `ssh` + `sudo -u deploy` that gets it there and
#     runs it as the right user (plus a `cd <repo>` on the units that need a
#     working directory; the ones invoked by absolute path do not use one).
#     Naming the machine without handing over the route was a C2-2 review
#     finding: `# host` alone is a label, not a procedure, and running these
#     as root instead of deploy reproduces the ownership accident unit 7.5's
#     chmod exists to prevent. There are exactly two machines and no third
#     spelling.
#   * Values are resolved at print time. The output contains no unescaped
#     `$FOO` / `${BAR}`. Exactly two escaped `$` sequences are emitted, both
#     on unit 8's line: `\$(tail …)` and `\$PREV_TX`. They are escaped so the
#     DEPLOY SHELL ON THE HOST evaluates them rather than this machine; the
#     test pins the escaped-variable allowlist to exactly `PREV_TX`. What
#     genuinely cannot be resolved is listed under "WHAT IS NOT RESOLVED".
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
#   bash scripts/cycle-transition.sh --status --expect-cycle=<N> \
#        [--public-base=<url|dir>] [--anchor-source-local=<path>] \
#        [--tx-json=<path>] [--gate-state=<path>]
#
# The two modes take deliberately different inputs and neither accepts the
# other's. `--print-only` is handed a ledger path because it prints a plan and
# must not go looking for one; `--status` is NOT, because the published bytes
# ARE its observation and reading a local mirror instead would answer the
# wrong question. Passing --ledger to --status (or --testnet-tx-id) is refused
# rather than ignored.
#
#   --expect-cycle=<N>       REQUIRED. The cycle that CLOSES today — exactly
#                            the value units 4 and 5 pass as FY_EXPECT_CYCLE.
#                            Why it is not derived: see THE OFF-BY-ONE below.
#   --ledger=<path>          REQUIRED. The PUBLISHED cycle-history.jsonl. Not
#                            the source of the cycle number — the CHECK on it.
#                            There is no default, for the reason stated at
#                            length in scripts/lib/cycle-context.sh ("THE
#                            LEDGER ARGUMENT IS MANDATORY"). It is not in this
#                            repo (the public feeds are gitignored), so fetch
#                            the published copy first:
#                              curl -fsS https://metal.freedom-yield.com/api/cycle-history.jsonl \
#                                -o /tmp/cycle-history.jsonl
#                            Fetching the PUBLISHED bytes is the point: units
#                            4 and 5 guard against that same copy, so a local
#                            mirror could agree with the plan while the guards
#                            still refuse.
#   --testnet-tx-id=<64hex>  Optional, --print-only only. See "WHAT IS NOT
#                            RESOLVED" above.
#
#   --public-base=<url|dir>  --status only. Where the PUBLISHED artifacts are
#                            read from. Defaults to the live site. A value
#                            that is not http(s) is treated as a local
#                            DIRECTORY laid out like the site (api/…), so
#                            already-fetched bytes can be re-read offline.
#   --anchor-source-local=<path>
#                            --status only. The local copy phase 3's published
#                            bytes are compared against. Defaults to the
#                            committed blob (git show HEAD:…).
#   --tx-json=<path>         --status only. A chain response for this cycle's
#                            mainnet transaction, already captured. Without
#                            it phase 5 reads UNKNOWN — never COMPLETE.
#   --gate-state=<path>      --status only. The cycle-gate state file.
#                            Defaults to the FY_STATE_DIR resolution, which
#                            only exists on the validator host.
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
# WHAT THIS CLOSES, AND WHAT IT DOES NOT. Stating only the first half would be
# the overclaim this repo keeps paying for.
#
# CLOSED: the plan cannot disagree with ITSELF. A morning print and an
# afternoon re-print of the same declared N produce the same N and N+1, so the
# memo prefix does not move under the operator while the day proceeds. The
# test asserts exactly that.
#
# NOT CLOSED BY THIS GUARD: whether the DECLARATION is right. The guard
# narrows the input to two accepted values, it does not verify them.
# `--expect-cycle=3` against a 3-row ledger is accepted here, reports "phase 1
# HAS landed", and derives 4 to inscribe — and because gen-identity.sh and
# gen-anchor-source.sh compare against that same not-yet-advanced ledger, both
# of them pass too. The first thing that objects is append-anchor-history.sh's
# invariant 4, which runs AFTER the irreversible broadcast.
#
# CLOSED BY --status, NOT BY --print-only. The second, independent observation
# that separates the two states is implemented in --status (see THE SECOND
# OBSERVATION further down), where it refuses with exit 71. It is deliberately
# NOT wired into --print-only: that mode is the day's retreat path and must
# keep working with nothing but a ledger file, offline, with no network and no
# second feed to fetch. So the honest statement of today's coverage is: run
# --status before trusting an --expect-cycle you typed. --print-only on its
# own still cannot tell you whether the number is right.
#
# Required environment FOR --print-only ONLY (refused if unset — see
# fyct__require_env). `--status` returns before that check and requires
# NEITHER variable: it reaches no host, so host coordinates would be an input
# it has no use for, and demanding them would imply an ssh route that does not
# exist. Measured: a --status run with both unset succeeds.
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
#   VALIDATOR_HOST_USER  defaults to root, as in the sibling scripts. This is
#                        the SSH login only — every host unit then drops to
#                        `sudo -u deploy`, because the pipeline's files are
#                        deploy-owned and running them as root is what unit
#                        7.5's defensive chmod exists to recover from.
#   FY_REMOTE_REPO       the repo path on the validator host. Defaults to
#                        /home/deploy/metal.freedom-yield.com, the path
#                        docs/CYCLE_GATE.md and docs/VALIDATOR_RENEWAL.md
#                        both use verbatim.
#   FY_CONFIG_DIR        defaults to $HOME/.fy-mainnet-broadcast/config,
#                        RESOLVED TO AN ABSOLUTE PATH at print time. That
#                        resolution is not cosmetic: it removes the zsh
#                        assignment-ordering pitfall documented at length in
#                        docs/CYCLE_GATE.md step 7c, because an absolute path
#                        cannot be re-pointed by a later HOME= prefix.
#
# Exit codes:
#   0   --print-only: the plan was printed.
#       --status:     every post-condition was measured and all are COMPLETE.
#   64  usage error (unknown flag, missing argument, missing required env,
#       a flag belonging to the other mode)
#   65  the ledger is unreadable        (propagated from cycle-context.sh)
#   66  the ledger is self-inconsistent (propagated from cycle-context.sh)
#   67  the phase cross-check against cycle-context.sh's table disagrees
#   68  the ledger disagrees with --expect-cycle (see THE OFF-BY-ONE)
#   69  --status only: measured, and at least one phase is NOT done. This is
#       the ordinary mid-transition answer, not an error.
#   70  --status only: at least one post-condition could NOT be observed. The
#       report names each one. UNKNOWN is never resolved to COMPLETE.
#   71  --status only: --expect-cycle reads as "phase 1 HAS landed" and the
#       second observation contradicts that, or could not be made at all.

# Self-locating, like scripts/lib/publish-scan.sh: the libraries are resolved
# from THIS file's own path, never from the caller's CWD. There is deliberately
# no repo-root variable, and this script executes no repo script. The one repo
# artifact it reads is a COMMITTED blob, and even that is reached by handing
# this directory to `git -C` rather than by computing a root: git resolves its
# own toplevel, so no path root exists here that a later edit could quietly
# start executing from.
FYCT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/cycle-context.sh
. "${FYCT_SELF_DIR}/lib/cycle-context.sh"

# scripts/lib/side-effects.sh is sourced for exactly two READ-ONLY things:
# fyd_is_live (so "what does live mean" is read from the one place that
# defines it) and fyd_state_dir (so --status looks for the cycle-gate state
# where the writers put it, rather than re-spelling the path). NO
# side-effect-PERFORMING fyd_* function — fyd_live_write, fyd_live_run,
# fyd_notify, fyd_push — is called anywhere in this file, because neither mode
# performs a side effect to gate. Should a later phase ever add one, this is
# already the library it must go through.
# shellcheck source=scripts/lib/side-effects.sh
. "${FYCT_SELF_DIR}/lib/side-effects.sh"

FYCT_USAGE_RC=64
FYCT_PHASE_MISMATCH_RC=67
FYCT_LEDGER_DISAGREES_RC=68
FYCT_STATUS_INCOMPLETE_RC=69
FYCT_STATUS_UNKNOWN_RC=70
FYCT_STATUS_UNCONFIRMED_RC=71

# The published site. Only --status reads it, and only over GET.
FYCT_PUBLIC_BASE_DEFAULT="https://metal.freedom-yield.com"

# Thresholds for THE SECOND OBSERVATION (see the header). Both are derived
# from measured values, not chosen for roundness:
#   * a validation period is ~31 days (live pair 2026-08-17: startTime
#     1785820477, endTime 1788498020 = 30.99 days), and a transition happens
#     within hours of endTime, so nothing legitimate sits 7 days from the end
#     while claiming the period already closed;
#   * the ledger's end_iso for a closed cycle and the chain's startTime for
#     the next one were 14 minutes apart in the live data (2026-08-04
#     T05:00:25Z vs 2026-08-04T05:14:37Z), so 6 hours is ~25x the observed
#     skew and still four orders of magnitude below a whole cycle.
FYCT_STATUS_PERIOD_MARGIN_S=604800
FYCT_STATUS_BOUNDARY_TOL_S=21600

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
5|刻印 / inscribe|4|OPERATOR, TWICE — AND (a) IS NOT DUE YET AT THIS LINE. (a) Between unit 7b and unit 7c, NOT before 7b: unlock the SEPARATE MAINNET keystore (HOME=~/.metal-fy-proton) and give the PRIME DIRECTIVE gate-2 per-invocation authorization, naming chain, actor, permission, action, memo and quantity explicitly. Gate 2 is a precondition of 7c, not a review of it — but 7b is a dry run that needs the mainnet keystore HOME only for the separation guard, never an UNLOCKED one, so unlocking here would leave the keystore open one unit longer than necessary. Unit 7b prints the exact unlock line and token ritual itself when it finishes, which is the moment to do this. (b) AFTER unit 7c: confirm the transaction on the explorer by eye, then re-lock the mainnet keystore — its prompt reads "Enter 32 character password (leave empty to create new)", and an empty Enter there creates a NEW password instead of locking with the existing one.
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

# fyct__host_cd <remote-shell-command>
#   A `# host` unit that needs a working directory: ssh in, drop to the deploy
#   user, cd to the repo, run. This is docs/VALIDATOR_RENEWAL.md's day-of form
#   verbatim (its ①②③ / ⑧ / ⑧.5 blocks), not an invention here.
#
#   QUOTING, because it is three shells deep and easy to get wrong:
#     - the outer '...' is consumed by the LOCAL shell, so everything inside
#       reaches ssh untouched;
#     - the "..." inside is expanded by the REMOTE LOGIN shell (root);
#     - `bash -c` then runs the result as the deploy user.
#   So a `$` that must survive to the deploy shell has to reach the remote
#   login shell as `\$`. Only unit 8 needs that, and it is the reason the
#   escaped-variable allowlist in tests/cycle-transition/ is non-empty.
fyct__host_cd() {
	fyct__cmd host "ssh -i ${VHK} ${VHU}@${VH} 'sudo -u deploy bash -c \"cd ${REMOTE_REPO} && $1\"'"
}

# fyct__host_env <env-assignments> <script-relative-path> [args...]
#   A `# host` unit that needs no working directory: the `sudo -u deploy env
#   … bash <absolute script path>` form docs/CYCLE_GATE.md's emergency
#   fallback and docs/VALIDATOR_RENEWAL.md ⑤/⑨ both use.
fyct__host_env() {
	local envs="$1"
	shift
	fyct__cmd host "ssh -i ${VHK} ${VHU}@${VH} 'sudo -u deploy env ${envs} bash ${REMOTE_REPO}/$*'"
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
		fyct__wrap "  " "Forces a fresh node-info tick and then reads it back, rather than waiting on the 5-minute cron. Repeat until endTime is the NEW AddValidator entry's."
		fyct__wrap "  " "Do NOT query the P-chain RPC directly to check this: scripts/broadcast-guard.sh refuses that command shape unconditionally, by shape alone, and reading this cron artifact is the sanctioned way to observe chain state (docs/CYCLE_GATE.md step 0)."
		fyct__host_cd "bash scripts/node-info.sh && jq -r .endTime,.observedAt public/api/validator.json"
		;;
	2)
		fyct__wrap "  " "FY_LIVE=1 is REQUIRED, and docs/CYCLE_GATE.md step 2 does not show it — that step carries no command block at all. Measured 2026-08-14: uptime-history.sh routes every persistent write through fyd_live_write / fyd_live_run (91, 92, 106, 107, 108, 166), and its only two raw redirects go to mktemp paths (253 to the temp from 234, 283 to the temp from 280) whose install mv is itself gated (257, 284). So without the opt-in nothing lands anywhere and the cycle simply never closes."
		fyct__host_env "FY_LIVE=1" "scripts/uptime-history.sh"
		;;
	3)
		fyct__wrap "  " "The publish is neither optional nor automatic: units 4 and 5 read the PUBLISHED ledger, so skipping it makes gen-identity.sh exit 7 and gen-anchor-source.sh exit 9 against a stale count."
		fyct__host_cd "bash scripts/gen-cycle-history.sh && bash scripts/push-to-web-host.sh cycle-history.jsonl"
		fyct__wrap "  " "Then confirm the PUBLISHED copy grew by exactly one line and now holds ${N} records. Deliberately checked from the Mac, not the host: units 4 and 5 guard against what the site actually serves, so the host's own copy is not the thing that matters here."
		fyct__cmd Mac "curl -fsS 'https://metal.freedom-yield.com/api/cycle-history.jsonl' | grep -cve '^[[:space:]]*\$' || true"
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
		fyct__wrap "  " "public/api/identity.json.sig IS IN THIS LIST AND MUST STAY. gen-identity.sh writes the manifest and its detached signature as a pair (its atomic-publish block moves both), and the real cycle-4 transition commit 90bcdd9 carried exactly those two files. Staging the manifest without the signature publishes a NEW manifest under the PREVIOUS cycle's signature: the public ssh-keygen -Y verify then fails, and unit 9's Phase 1 identity signature check fails with it."
		fyct__cmd "$m" "git add public/api/identity.json public/api/identity.json.sig deploy/identity-pin-baseline.json deploy/publication.json"
		fyct__cmd "$m" "git commit -m 'chore(identity): cycle ${INSCRIBE} identity manifest + C4 post-issuance cleanup'"
		fyct__cmd "$m" "git push"
		fyct__cmd "$m" "gh run watch"
		;;
	5)
		fyct__wrap "  " "Expect exactly one 'side-effects: WARNING: state dir falls back to the production default' line. It is correct here — this script only READS the production streams. Do NOT point FY_STATE_DIR at a sandbox (it would compose the DAG from empty inputs) and do NOT add FY_LIVE=1 (it writes no production state)."
		fyct__wrap "  " "Its ordering guard is exit 9, not 7. Its exit 7 means an atomic write failed — a different condition."
		fyct__host_env "FY_EXPECT_CYCLE=${N}" "scripts/gen-anchor-source.sh"
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
		fyct__wrap "  " "FY_CONFIG_DIR is printed as an absolute path on purpose: that sidesteps the zsh left-to-right assignment-ordering trap that silently relocates the config dir inside the keystore when it is written home-relative."
		fyct__wrap "  " "This unit needs the mainnet keystore HOME (the separation guard refuses otherwise with exit 8) but NOT an unlocked keystore, no signing key, and no authorization — it is a dry run that touches no operator token. It also prints the stop-4(a) unlock line, the token ritual and the unit 7c command with both gate args filled in, so prefer ITS output over the line printed below."
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
		fyct__wrap "  " "--prev-anchor-tx-id is NOT derived from anything else. It is read on the HOST from the last line of the anchor ledger, into PREV_TX, chained with && so a failed read stops the receipt instead of writing an empty prev link. That is why this one line carries an escaped \$ — it must survive to the deploy shell. Passing a stale value (or none) writes a wrong prev link and then fails append invariant 6. Only genesis may be null."
		fyct__wrap "  " "FY_LIVE=1 on the append is required, but not for the reason it usually is: the append itself happens either way, deliberately, because a forgotten opt-in must never cost a line in an append-only ledger. What the opt-in gates is the automatic R18 archive push. gen-anchor-receipt.sh needs no opt-in at all."
		fyct__host_cd "PREV_TX=\\\$(tail -n 1 public/api/anchor-history.jsonl | jq -r .tx_id) && bash scripts/gen-anchor-receipt.sh --input=/home/deploy/.fya-sign-output.json --anchor-source=public/api/anchor-source.json --trigger=cyclestart --prev-anchor-tx-id=\\\$PREV_TX && FY_LIVE=1 bash scripts/append-anchor-history.sh --receipt=public/api/anchor-receipt.json --event-type=cyclestart"
		;;
	8.5)
		fyct__wrap "  " "Two, not four. These are the canonical flat copies unit 8 just wrote on the host. Skip this and the public feeds keep serving the PREVIOUS cycle even though the anchor already succeeded — unit 9 polls only anchor-source.json freshness, so it will NOT catch a missed push here. anchor-source.json is not in this list: it is git-deploy owned."
		fyct__host_cd "bash scripts/push-to-web-host.sh anchor-receipt.json && bash scripts/push-to-web-host.sh anchor-history.jsonl"
		fyct__wrap "  " "The two R18 per-anchor archive copies are pushed automatically by unit 8's append. That push is best-effort: if stderr or an alert shows 'R18 publish FAILED' or 'R18 publish skipped', re-run the manual retry command it prints."
		;;
	9)
		fyct__wrap "  " "FY_LIVE=1 is required; without it the script refuses with exit 6 before Phase 1 and writes nothing. No broadcast and no explorer URL here — this only records cycle-gate approval state."
		fyct__host_env "FY_LIVE=1" "scripts/resume-after-cycle-start.sh --apply"
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
	fyct__c "DO NOT PASTE THIS OUTPUT INTO A COMMIT, A PR, AN ISSUE, A CHAT LOG OR"
	fyct__c "A PUBLISHED REPORT. It carries the resolved validator host and ssh key"
	fyct__c "path, which are never literal in this repository on purpose."
	fyct__c "============================================================================"
	fyct__c "printed by     : scripts/cycle-transition.sh --print-only"
	fyct__c "printed at     : ${PRINTED_AT}"
	fyct__c "ledger read    : ${LEDGER}"
	fyct__c "cycle closing today (N)  : ${N}    (declared via --expect-cycle)"
	fyct__c "cycle to inscribe (N+1)  : ${INSCRIBE}"
	fyct__c "ledger cross-check       : ${PHASE1_STATE}"
	fyct__c "validator host : ${VH}"
	fyct__c "host ssh key   : ${VHK}"
	fyct__c "host ssh user  : ${VHU} (login only — every host unit drops to sudo -u deploy)"
	fyct__c "host repo path : ${REMOTE_REPO}"
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
	fyct__wrap "  " "TYPE EVERYTHING ON THE MAC. Each command ends with the machine it EXECUTES on: '# Mac' runs locally; '# host' already carries the ssh and the sudo -u deploy that take it to the validator host and run it as the deploy user (with a cd into the repo where the unit needs one). There is no third machine, and you should not need a second terminal on the host."
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
	fyct__wrap "  " "1. The keystore unlock and re-lock commands for stops 3 and 4 are NOT printed here. tests/orchestrator-guard/ fails this file if it names the signing CLI, and those are the operator's own manual actions, handed over in chat. Measured relief: the phase scripts print them themselves — unit 7b prints the MAINNET unlock line plus the token ritual, and unit 7a prints the TESTNET unlock line whenever it detects a locked keystore. So the only step of the day with no printed source anywhere is the FINAL RE-LOCK after unit 7c, which is also the one where an empty Enter silently sets a new password. Get its wording from docs/CYCLE_GATE.md step 7c."
	if [ "$TTX_KNOWN" != "1" ]; then
		fyct__wrap "  " "2. Units 7b and 7c are commented out because the rehearsal tx id does not exist yet. Re-run with --testnet-tx-id=<64hex> once unit 7a has printed its sentinel."
	else
		fyct__wrap "  " "2. Units 7b and 7c are resolved against the supplied rehearsal tx id. Verify it is THIS cycle's (cycle ${INSCRIBE}) — a stale id from an earlier rehearsal satisfies the shape check and fails gate 1."
	fi
	fyct__wrap "  " "3. Unit 8's PREV_TX resolves on the host at paste time, by design; it is not a value this plan could know. It is the one escaped variable in the output."
	fyct__wrap "  " "4. Unit 4b is a set of hand edits. Only its verification and commit are commands."
	fyct__wrap "  " "5. The '~' in the keystore and identity-key paths is USER-RELATIVE, not resolved here. It expands to the home directory of whoever pastes it, which is correct on the operator's Mac and wrong anywhere else. Everything else on those lines is fully resolved."
	fyct__wrap "  " "6. The host repo path (${REMOTE_REPO}) and the deploy user are assumed, not probed. If the host layout ever changes, these lines are wrong in a way this plan cannot detect."
	fyct__wrap "  " "7. This plan does not execute or verify anything — it is a plan. To find out how far the day actually got, run the SAME script with --status --expect-cycle=${N}: it re-measures each phase's post-condition against the published artifacts instead of trusting a record. It is read-only too, and it is the check this plan cannot make on the number you typed above."
	fyct__c "============================================================================"
	return 0
}

# ---------------------------------------------------------------------------
# --status — "the record is not the evidence" (C2-3)
# ---------------------------------------------------------------------------
# docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md §5 says
# resume must not believe the state file: it re-measures each phase's
# POST-CONDITION. This mode implements that reading and nothing else.
#
# The five post-conditions are the spec's table, with two substitutions this
# machine forces. Both are stated here rather than smuggled in:
#
#   spec row                     -> implemented as
#   ---------------------------------------------------------------------
#   1  ledger gained exactly one    fyc_closed_cycle_count(PUBLISHED) == N.
#      row, max cycle_n == N        That function already refuses unless the
#                                   record count AND max(cycle_n) agree, so
#                                   "one more row" and "max == N" are the
#                                   same assertion once it returns.
#
#   2  identity generated_at        after the END of cycle N as the PUBLISHED
#      after the cycle start,       LEDGER records it — NOT after the current
#      and deploy succeeded         on-chain startTime. Measured 2026-08-17:
#                                   the live manifest carries generated_at
#                                   2026-08-06 while the period started
#                                   2026-08-04, because it was re-signed
#                                   mid-cycle. "After startTime" is therefore
#                                   satisfied by a manifest from the WRONG
#                                   cycle and would report phase 2 done before
#                                   it ran. The two instants are 14 minutes
#                                   apart in real data, so nothing is lost.
#                                   "deploy success" is not a separate probe:
#                                   these ARE the published bytes, so a fresh
#                                   generated_at at that URL IS the deploy
#                                   having landed. What is NOT checked is the
#                                   ed25519 signature itself — only that the
#                                   .sig published alongside it (see below).
#
#   3  published anchor-source      published sha256 == the COMMITTED bytes
#      sha256 == host copy          (git show HEAD:public/api/anchor-source
#                                   .json), or --anchor-source-local=<path>.
#                                   NOT the host's live file: --status must
#                                   not ssh, and unit 7b's own note records
#                                   that a host-side recompose yields a
#                                   DIFFERENT dag_root_computed because the
#                                   5-minute crons rewrite the feeds the
#                                   artifacts branch hashes — so comparing
#                                   against a live host copy would go red on a
#                                   correct transition. The committed bytes
#                                   are what unit 6 verified the host copy
#                                   into, and are the same comparison
#                                   preview-cycle-anchor-broadcast.sh makes
#                                   (its exit 9 / exit 10 pair).
#                                   Byte equality ALONE is not enough and is
#                                   not used alone: published and committed
#                                   agree all month, so the cycle number in
#                                   the published copy must ALSO have advanced
#                                   to N+1. Without that, phase 3 would read
#                                   COMPLETE before the day started.
#
#   5  mainnet tx resolves          the captured chain response passed as
#      on-chain, memo prefix        --tx-json=<path> must resolve exactly four
#      matches                      DISTINCT memos, all carrying fya<S>c<N+1>
#                                   — S read from the PUBLISHED anchor-source,
#                                   N+1 from --expect-cycle, neither taken
#                                   from the response itself. Four DISTINCT
#                                   memos rather than four entries, for the
#                                   measured reason recorded at FYCT_TXQ_MEMOS
#                                   below. This mode does
#                                   NOT fetch it: the mainnet history endpoint
#                                   cannot be named in this file at all
#                                   (tests/orchestrator-guard/ fails on a
#                                   substring of its hostname), and a second,
#                                   unreviewed chain client is worse than
#                                   re-reading the response the receipt step
#                                   already knows how to obtain. What this
#                                   therefore does NOT prove is provenance:
#                                   it verifies the response, not that it came
#                                   from mainnet a moment ago.
#
#   6  cycle-gate-state signature   approved_cycle_signature must equal
#      matches the current cycle    <nodeId>-<startTime> from the PUBLISHED
#                                   validator.json — the exact string
#                                   cycle-gate.sh recomputes from the chain.
#                                   The file lives in FY_STATE_DIR on the
#                                   validator host, so off that host this
#                                   reads UNKNOWN, never COMPLETE.
#
# PHASE 4 HAS NO POST-CONDITION AND NONE IS INVENTED HERE. The spec's table
# has no row for it, and the rehearsal's only product is a transaction id on
# stdout that nothing publishes. It prints as NO-POST-CONDITION and is
# excluded from the arithmetic. Manufacturing one would be the fabrication
# this repo's audit rules forbid.
#
# UNKNOWN IS NEVER COMPLETE. Any observation that cannot be made is reported
# as UNKNOWN and raises the exit code (design doc §6 fail-closed rule (b)).
#
# ---------------------------------------------------------------------------
# THE SECOND OBSERVATION (what closes the --expect-cycle hole)
# ---------------------------------------------------------------------------
# THE OFF-BY-ONE above records that the ledger narrows --expect-cycle to two
# values without verifying either, and that the dangerous shape is a
# declaration the ledger reads as "phase 1 HAS landed" when it has not.
#
# --status adds the independent observation that separates them, taken from
# public/api/validator.json — the feed step 0 already reads. Measured
# 2026-08-17 against the live site: startTime=1785820477, endTime=1788498020,
# i.e. the CURRENT on-chain period, opening 2026-08-04 and closing 2026-09-04
# 14:00 JST. Two consequences, and BOTH are checked whenever the ledger reads
# as "phase 1 HAS landed":
#
#   (i)  The current period must not be about to end. Cycle N cannot have
#        closed while the chain still says its period runs for another week.
#        Catches the declaration made on transition morning, BEFORE the wallet
#        action.
#   (ii) The just-closed cycle must end where the current period began: the
#        ledger row for cycle N must carry end_iso within
#        FYCT_STATUS_BOUNDARY_TOL_S of validator.json's startTime.
#        Catches the SAME declaration made after the wallet action but before
#        unit 3 — where (i) passes, because the new period is a month long,
#        while the ledger's last row is still a month old.
#
# Failing either is exit 71. So is being unable to make the observation at
# all: a declaration that could not be confirmed has not been confirmed.
#
# WHAT IS STILL NOT CLOSED, stated because the half-statement is the overclaim
# this repo keeps paying for. The OTHER branch — closed == N-1, "phase 1 has
# not run" — has no second observation and cannot have one: before the wallet
# action, "cycle N closes today" and "cycle N closed a month ago and N+1
# closes today" produce identical public state. What that branch cannot do is
# derive an already-inscribed number by accident.
#
# AN EARLIER REVISION OF THIS PARAGRAPH ALSO CLAIMED that branch "reports every
# phase as not yet done, which is the safe direction". THAT WAS FALSE, and it
# was measured false by review: on transition morning, before the node-info
# tick, phase 6 returned COMPLETE. The claim is removed rather than softened,
# and the hole it papered over is closed below.
#
# ---------------------------------------------------------------------------
# STALE-PASS: WHICH POST-CONDITIONS A PREVIOUS CYCLE CAN SATISFY
# ---------------------------------------------------------------------------
# The rule that decides it, applied to all five rather than to the one that was
# caught:
#
#   A post-condition can be satisfied by last month's state exactly when it
#   does NOT embed the identity of the cycle being transitioned.
#
#   phase 1  embeds N        (the record count must BE N)               safe
#   phase 2  embeds cycle N's end boundary from the published ledger    safe
#   phase 3  embeds N+1      (cycle_number_observed)                    safe
#   phase 5  embeds N+1      (the memo prefix fya<S>c<N+1>)             safe
#   phase 6  embeds NO cycle number. Its post-condition is "the         STALE-
#            gate-state signature equals the CURRENT on-chain period",  ABLE
#            and that is a time-varying quantity which lags: before the
#            node-info tick reflects the new AddValidator, the previous
#            cycle's approved signature still equals the still-current
#            period. spec §5's row is faithful; the staleness is in the
#            quantity, not in the implementation of it.
#
# So phase 6, and only phase 6, is gated: when phase 1 is not COMPLETE it
# reports UNKNOWN, never COMPLETE. That gate is exactly sufficient rather than
# merely conservative — unit 3 (which makes phase 1 COMPLETE) is downstream of
# unit 1 (the tick), so phase 1 COMPLETE implies startTime has already
# advanced, which is precisely the condition under which the previous cycle's
# signature can no longer match.
#
# The other four are NOT gated on phase 1, deliberately. Each embeds a cycle
# number that only today's work can produce, so gating them would hide a real
# observation (e.g. an anchor-source already composed for N+1 while the ledger
# publish failed) behind an UNKNOWN. Masking a genuine signal is not the same
# kind of safety as refusing a stale one.

# The two jq programs phase 5 runs over --tx-json. They are constants rather
# than inline strings because the shape they have to survive was MEASURED, not
# assumed, and the measurement is worth keeping next to them.
#
# Measured 2026-08-17 against the real cycle-4 anchor transaction:
#   * the v1 history response carries NO top-level `.actions` at all. It
#     carries `.traces`, and for the 4-action pack there are TWELVE of them —
#     three per action, because a token transfer notifies both parties in
#     addition to executing. `.trx.trx.actions` was present but empty. An
#     earlier revision of this code counted `.actions[]` and would have
#     reported UNKNOWN/INCOMPLETE on a perfectly good transaction.
#   * the Hyperion v2 response (the path gen-anchor-receipt.sh prefers) is
#     account-scoped and returns entries for many transactions, each carrying
#     its own `.trx_id`.
# So: take memos from `.actions` OR `.traces`, keep only the entries belonging
# to this transaction, and UNIQUE them. The pack is four DISTINCT memos; the
# repetition is an artefact of how the chain reports notifications, and
# counting raw entries would make the answer depend on which endpoint the
# response came from.
#
# THE PREFIX IS MATCHED WITH ITS SEPARATOR, not by bare startswith. `fya1c4`
# is a prefix of `fya1c41`, so a bare startswith would accept cycle 41's memos
# as cycle 4's the first time a two-digit cycle collides with a one-digit one.
# The pack's four memos are `<p>-id:` `<p>-ob:` `<p>-ar:` `<p>:`
# (gen-anchor-receipt.sh composes exactly these), so requiring the separator
# makes the match exact, and requiring all four KINDS makes it the same set
# assertion gen-anchor-receipt.sh's gate 5 makes — without needing the roots,
# which this reading has no independent source for.
FYCT_TXQ_ID='if ((.id? // "") | tostring) != "" then .id else ([(.actions // []), (.traces // [])] | add | map(.trx_id // empty) | first // "") end'
FYCT_TXQ_MEMOS='[(.actions // []), (.traces // [])] | add | map(select((.trx_id // $t) == $t)) | map(.act.data.memo // empty) | unique'
FYCT_TXQ_KINDS='map(if startswith($p + "-id:") then "id" elif startswith($p + "-ob:") then "ob" elif startswith($p + "-ar:") then "ar" elif startswith($p + ":") then "root" else empty end) | unique'

fyct__have() { command -v "$1" >/dev/null 2>&1; }

# fyct__sha256 <file> — hex digest on stdout, or non-zero if no tool exists.
# Same two-tool dance as gen-anchor-receipt.sh; fail-closed if neither is
# present, never a silent "assume equal".
fyct__sha256() {
	if fyct__have sha256sum; then
		sha256sum < "$1" | awk '{print $1}'
	elif fyct__have shasum; then
		shasum -a 256 < "$1" | awk '{print $1}'
	else
		return 1
	fi
}

# ISO-8601 -> epoch. The `-u` on the BSD branch is load-bearing, not
# decoration: BSD strptime treats the trailing "Z" as a literal, so without it
# the wall-clock numbers are read in $TZ and the answer is off by the local
# offset (9h under Asia/Tokyo). Verbatim from gen-renewal-ics.sh, which
# documents the reviewer-measured 9-hour disagreement.
fyct__date_from_iso() {
	if date --version >/dev/null 2>&1; then
		date -d "$1" +%s 2>/dev/null
	else
		date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
	fi
}

# Accepts either an epoch integer (validator.json's form) or an ISO string
# (cycle-history.jsonl's form).
fyct__to_epoch() {
	case "$1" in
	'' | *[!0-9]*) fyct__date_from_iso "$1" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

# fyct__status_read <relative-path> <dest>
#   Reads one published artifact. An http(s) base is a plain GET; anything
#   else is a local directory of already-fetched bytes. Returns non-zero and
#   leaves NO file behind when the artifact cannot be read — a partial or
#   absent read must never reach a comparison looking like data.
#
#   A ZERO-BYTE artifact is treated as unreadable, which is deliberately
#   STRICTER than scripts/lib/cycle-context.sh, where a readable but
#   genuinely empty ledger is a legitimate pre-genesis 0. The two are asking
#   different questions: cycle-context is handed a path by a caller who chose
#   it, while this reads a URL that a broken publish also answers with zero
#   bytes. Genesis is long past, so on this path "empty" is overwhelmingly
#   "the publish failed", and the answer it produces is UNKNOWN — never
#   COMPLETE. Measured 2026-08-17: an empty published ledger yields
#   "PHASE 1 record UNKNOWN" and exit 70, not a claim about the day.
fyct__status_read() {
	local rel="$1" dest="$2" base="${FYCT_PUBLIC_BASE%/}"
	rm -f "$dest"
	case "$FYCT_PUBLIC_BASE" in
	http://* | https://*)
		fyct__have curl || return 1
		# Retried, not single-shot. This repo has already paid for the
		# single-shot version once: the 2026-07-17 api_freshness false alarm
		# was a transient fetch on a contended host, and the permanent fix was
		# to retry (memory/project_fix_20260717_cf_cache_and_freshness_retry).
		# A transient miss here would read as UNKNOWN rather than as a wrong
		# verdict, so this is noise reduction on transition day, not a
		# correctness fix — and the retries cannot mask a real outage, since
		# exhausting them still returns non-zero.
		local try=1
		while [ "$try" -le 3 ]; do
			if curl -fsS --max-time 20 "${base}/${rel}" -o "$dest" 2>/dev/null; then
				break
			fi
			rm -f "$dest"
			if [ "$try" -eq 3 ]; then
				return 1
			fi
			sleep 2
			try=$((try + 1))
		done
		;;
	*)
		[ -r "${base}/${rel}" ] || return 1
		if ! cat "${base}/${rel}" > "$dest" 2>/dev/null; then
			rm -f "$dest"
			return 1
		fi
		;;
	esac
	if [ ! -s "$dest" ]; then
		rm -f "$dest"
		return 1
	fi
	return 0
}

# The one directory --status writes to, and the only thing it ever removes.
# Held at file scope rather than in a `local` so the EXIT trap can still see
# it after the function that created it has returned — a trap that references
# an out-of-scope local fails under `set -u` and leaves the directory behind,
# which is the opposite of what it is for.
FYCT_STATUS_SCRATCH=""
fyct__status_cleanup() {
	if [ -n "${FYCT_STATUS_SCRATCH:-}" ] && [ -d "${FYCT_STATUS_SCRATCH}" ]; then
		rm -rf "${FYCT_STATUS_SCRATCH}"
	fi
	return 0
}

# Like fyct__wrap, without the leading `# `: the status report is a report,
# not a script to paste. Nothing in --status output is meant to be executed.
fyct__status_wrap() {
	local indent="$1" text="$2" line="" word
	for word in $text; do
		if [ -z "$line" ]; then
			line="$word"
		elif [ "${#line}" -ge 62 ]; then
			printf '%s%s\n' "$indent" "$line"
			line="$word"
		else
			line="$line $word"
		fi
	done
	if [ -n "$line" ]; then
		printf '%s%s\n' "$indent" "$line"
	fi
	return 0
}

# fyct__status_verdict <phase> <label> <verdict> <detail>
fyct__status_verdict() {
	printf 'PHASE %-3s %-11s %-18s %s\n' "$1" "$2" "$3" "$4"
	return 0
}

# fyct__status_evidence <text> — an indented supporting line under a verdict.
fyct__status_evidence() { fyct__status_wrap "             " "$*"; }

# fyct__status_units <phase> — the unit ids that make up one phase, for the
# recovery hint. Read from the SAME table --print-only prints, so a phase can
# never be advised to re-run a step the plan does not contain.
fyct__status_units() {
	local want="$1" id out=""
	while IFS= read -r id; do
		[ -n "$id" ] || continue
		if [ "$(fyct_unit_phase "$id")" = "$want" ]; then
			out="${out:+$out }${id}"
		fi
	done < <(fyct_unit_ids)
	printf '%s' "$out"
}

# fyct__status_next <phase> <verdict> <how-to-observe>
#   The next-step line for one phase. INCOMPLETE gets the unit list; UNKNOWN
#   gets the observation it is missing and NO unit list; COMPLETE gets
#   nothing. See the call site for why the distinction is not cosmetic.
fyct__status_next() {
	local phase="$1" verdict="$2" howto="$3"
	case "$verdict" in
	INCOMPLETE)
		printf 'to advance phase %-8s: units %s\n' "$phase" "$(fyct__status_units "$phase")"
		;;
	UNKNOWN)
		printf 'to OBSERVE phase %-8s: not measured — %s\n' "$phase" "$howto"
		;;
	esac
	return 0
}

# fyct__status_crosscheck <validator-json> <ledger> <have-validator>
#   THE SECOND OBSERVATION. Called only when the ledger reads as "phase 1 HAS
#   landed". Returns 0 when that reading is confirmed, $FYCT_STATUS_UNCONFIRMED_RC
#   otherwise — including when it cannot be checked.
fyct__status_crosscheck() {
	local valid_f="$1" ledger_f="$2" have_valid="$3"
	local now end_time start_time row_end row_end_e delta

	if [ "$have_valid" -ne 1 ]; then
		echo "cycle-transition: ERROR: --expect-cycle=${N} reads as \"phase 1 HAS landed\", and that" >&2
		echo "                  reading could not be confirmed: api/validator.json was not readable" >&2
		echo "                  from ${FYCT_PUBLIC_BASE}." >&2
		echo "                  An unconfirmed declaration is not a confirmed one. This number becomes" >&2
		echo "                  the memo prefix of an append-only on-chain inscription." >&2
		return "$FYCT_STATUS_UNCONFIRMED_RC"
	fi

	now="$(date -u +%s)"
	end_time="$(jq -r '.endTime // empty' "$valid_f" 2>/dev/null || true)"
	start_time="$(jq -r '.startTime // empty' "$valid_f" 2>/dev/null || true)"
	end_time="$(fyct__to_epoch "$end_time" || true)"
	start_time="$(fyct__to_epoch "$start_time" || true)"

	if [ -z "$end_time" ] || [ -z "$start_time" ]; then
		echo "cycle-transition: ERROR: --expect-cycle=${N} reads as \"phase 1 HAS landed\", and that" >&2
		echo "                  reading could not be confirmed: api/validator.json carries no readable" >&2
		echo "                  startTime/endTime pair, so the current on-chain period is unknown." >&2
		return "$FYCT_STATUS_UNCONFIRMED_RC"
	fi

	# (i) the current period must not be about to end.
	if [ "$end_time" -le "$((now + FYCT_STATUS_PERIOD_MARGIN_S))" ]; then
		echo "cycle-transition: ERROR: --expect-cycle=${N} is contradicted by the chain." >&2
		echo "                  The published ledger holds ${N} closed cycles, which with --expect-cycle=${N}" >&2
		echo "                  reads as \"cycle ${N} has closed and unit 3 published its row\"." >&2
		echo "                  But api/validator.json says the CURRENT on-chain period ends at ${end_time}" >&2
		echo "                  (now ${now}) — within $((FYCT_STATUS_PERIOD_MARGIN_S / 86400)) days, so it has NOT rolled over yet." >&2
		echo "                  A cycle closes at that rollover. Nothing closed today, and those ${N} rows" >&2
		echo "                  are the previous transitions', not this one's." >&2
		echo "                  --expect-cycle names the cycle CLOSING TODAY, which is the one still OPEN:" >&2
		echo "                  $((N + 1)). Re-run with --expect-cycle=$((N + 1))." >&2
		echo "                  Left uncorrected, this declaration derives $((N + 1)) as the number to INSCRIBE —" >&2
		echo "                  one short of the cycle today's transition opens, and append-only." >&2
		return "$FYCT_STATUS_UNCONFIRMED_RC"
	fi

	# (ii) the just-closed cycle must end where the current period began.
	row_end="$(jq -r -s --argjson n "$N" 'map(select(.cycle_n == $n)) | .[0].end_iso // empty' "$ledger_f" 2>/dev/null || true)"
	if [ -z "$row_end" ]; then
		echo "cycle-transition: ERROR: --expect-cycle=${N} reads as \"phase 1 HAS landed\", and that" >&2
		echo "                  reading could not be confirmed: the published ledger has no end_iso on" >&2
		echo "                  its row for cycle ${N}, so the cycle boundary cannot be compared against" >&2
		echo "                  the current on-chain period." >&2
		return "$FYCT_STATUS_UNCONFIRMED_RC"
	fi
	row_end_e="$(fyct__to_epoch "$row_end" || true)"
	if [ -z "$row_end_e" ]; then
		echo "cycle-transition: ERROR: --expect-cycle=${N}: the ledger's end_iso for cycle ${N} (${row_end})" >&2
		echo "                  could not be parsed as a timestamp, so the boundary check is unavailable." >&2
		return "$FYCT_STATUS_UNCONFIRMED_RC"
	fi
	delta="$((row_end_e - start_time))"
	if [ "$delta" -lt 0 ]; then
		delta="$((0 - delta))"
	fi
	if [ "$delta" -gt "$FYCT_STATUS_BOUNDARY_TOL_S" ]; then
		echo "cycle-transition: ERROR: --expect-cycle=${N} is contradicted by the cycle boundary." >&2
		echo "                  The ledger's row for cycle ${N} ends at ${row_end} (epoch ${row_end_e}), but the" >&2
		echo "                  CURRENT on-chain period began at ${start_time} — $((delta / 3600)) hours apart." >&2
		echo "                  Cycle ${N} ends exactly where cycle $((N + 1)) begins, so if cycle ${N} really had just" >&2
		echo "                  closed those two instants would coincide. They describe different cycles." >&2
		echo "                  This is the shape of a declaration made after the new AddValidator was" >&2
		echo "                  reflected but before unit 3 published the ledger row. Check which cycle" >&2
		echo "                  closes today before proceeding." >&2
		return "$FYCT_STATUS_UNCONFIRMED_RC"
	fi

	printf 'second observation       : CONFIRMED — current on-chain period runs to %s, and cycle %s ends at its start (%s s apart)\n' \
		"$end_time" "$N" "$delta"
	return 0
}

# ---------------------------------------------------------------------------
# fyct_status_report — the whole reading. Reads globals set by main: N,
# INSCRIBE, PRINTED_AT, FYCT_PUBLIC_BASE, FYCT_ANCHOR_LOCAL, FYCT_TX_JSON,
# FYCT_GATE_STATE.
# ---------------------------------------------------------------------------
fyct_status_report() {
	local scratch ledger_f ident_f sig_f anchor_f valid_f head_f local_src
	local have_ledger=0 have_ident=0 have_sig=0 have_anchor=0 have_valid=0
	local closed="" ledger_rc=0
	local v1="" v2="" v3="" v5="" v6=""
	local d1="" d2="" d3="" d5="" d6=""
	local n_unknown=0 n_incomplete=0 rc=0

	if ! fyct__have jq; then
		echo "cycle-transition: ERROR: --status requires jq to read the published feeds." >&2
		echo "                  Refusing rather than reporting phases it could not measure." >&2
		return "$FYCT_STATUS_UNKNOWN_RC"
	fi

	# The ONLY directory this mode writes to, and it does not outlive the run.
	FYCT_STATUS_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/fyct-status.XXXXXX")"
	scratch="$FYCT_STATUS_SCRATCH"
	trap fyct__status_cleanup EXIT

	ledger_f="${scratch}/cycle-history.jsonl"
	ident_f="${scratch}/identity.json"
	sig_f="${scratch}/identity.json.sig"
	anchor_f="${scratch}/anchor-source.json"
	valid_f="${scratch}/validator.json"
	head_f="${scratch}/anchor-source.committed.json"

	fyct__status_read api/cycle-history.jsonl "$ledger_f" && have_ledger=1
	fyct__status_read api/identity.json "$ident_f" && have_ident=1
	fyct__status_read api/identity.json.sig "$sig_f" && have_sig=1
	fyct__status_read api/anchor-source.json "$anchor_f" && have_anchor=1
	fyct__status_read api/validator.json "$valid_f" && have_valid=1

	printf '============================================================================\n'
	printf 'Metal Freedom Yield — cycle transition STATUS\n'
	printf 'READ ONLY. This is a reading of what the published artifacts and the local\n'
	printf 'inputs actually say. It runs no step, and this file holds no code path that\n'
	printf 'could. It re-measures post-conditions; it does not trust a state file.\n'
	printf '============================================================================\n'
	printf 'read at                  : %s\n' "$PRINTED_AT"
	printf 'published source         : %s\n' "$FYCT_PUBLIC_BASE"
	printf 'cycle closing today (N)  : %s    (declared via --expect-cycle)\n' "$N"
	printf 'cycle to inscribe (N+1)  : %s\n' "$INSCRIBE"

	# ---- phase 1 -----------------------------------------------------------
	if [ "$have_ledger" -ne 1 ]; then
		v1=UNKNOWN
		d1="the published cycle-history could not be read"
	else
		closed="$(fyc_closed_cycle_count "$ledger_f")" || ledger_rc=$?
		if [ "$ledger_rc" -ne 0 ]; then
			echo "cycle-transition: ERROR: the PUBLISHED cycle-history could not be interpreted." >&2
			echo "                  cycle-context.sh refused with rc ${ledger_rc}; its reason is above." >&2
			return "$ledger_rc"
		fi
		if [ "$closed" -eq "$N" ]; then
			v1=COMPLETE
			d1="published ledger holds ${closed} closed cycles, max cycle_n = ${closed}"
		elif [ "$closed" -eq "$((N - 1))" ]; then
			v1=INCOMPLETE
			d1="published ledger still holds ${closed} closed cycles; cycle ${N} is not on it"
		else
			echo "cycle-transition: ERROR: the published ledger disagrees with --expect-cycle=${N}." >&2
			echo "                  published closed-cycle count : ${closed}" >&2
			echo "                  expected                     : $((N - 1)) (before phase 1) or ${N} (after unit 3)" >&2
			echo "                  Neither matches, so one of the two is wrong. Do NOT proceed." >&2
			return "$FYCT_LEDGER_DISAGREES_RC"
		fi
	fi

	# ---- the second observation, before any verdict is printed -------------
	if [ "$v1" = "COMPLETE" ]; then
		fyct__status_crosscheck "$valid_f" "$ledger_f" "$have_valid" || return $?
	else
		printf 'second observation       : not applicable (the ledger does not claim phase 1 landed)\n'
	fi
	printf '============================================================================\n'

	# ---- phase 2 -----------------------------------------------------------
	local gen_at="" gen_e="" bound="" bound_e=""
	if [ "$v1" != "COMPLETE" ]; then
		v2=UNKNOWN
		d2="phase 1 has not landed, so the cycle boundary to compare against is not published"
	elif [ "$have_ident" -ne 1 ]; then
		v2=UNKNOWN
		d2="the published identity manifest could not be read"
	else
		gen_at="$(jq -r '.generated_at // empty' "$ident_f" 2>/dev/null || true)"
		bound="$(jq -r -s --argjson n "$N" 'map(select(.cycle_n == $n)) | .[0].end_iso // empty' "$ledger_f" 2>/dev/null || true)"
		gen_e="$(fyct__to_epoch "$gen_at" || true)"
		bound_e="$(fyct__to_epoch "$bound" || true)"
		if [ -z "$gen_e" ] || [ -z "$bound_e" ]; then
			v2=UNKNOWN
			d2="generated_at (${gen_at:-<absent>}) or the cycle ${N} boundary (${bound:-<absent>}) is unreadable"
		elif [ "$gen_e" -le "$bound_e" ]; then
			v2=INCOMPLETE
			d2="published generated_at ${gen_at} is not after cycle ${N}'s end ${bound}"
		elif [ "$have_sig" -ne 1 ]; then
			v2=INCOMPLETE
			d2="the manifest is fresh but api/identity.json.sig did not publish with it"
		else
			v2=COMPLETE
			d2="published generated_at ${gen_at} is after cycle ${N}'s end ${bound}, and the .sig published with it"
		fi
	fi

	# ---- phase 3 -----------------------------------------------------------
	local pub_sha="" loc_sha="" cyc_obs=""
	local_src=""
	if [ "$have_anchor" -ne 1 ]; then
		v3=UNKNOWN
		d3="the published anchor-source could not be read"
	else
		cyc_obs="$(jq -r '.observations_branch.cycle_number_observed // empty' "$anchor_f" 2>/dev/null || true)"
		if [ -n "$FYCT_ANCHOR_LOCAL" ]; then
			local_src="$FYCT_ANCHOR_LOCAL"
			if [ -r "$FYCT_ANCHOR_LOCAL" ]; then
				cat "$FYCT_ANCHOR_LOCAL" > "$head_f" 2>/dev/null || rm -f "$head_f"
			fi
		else
			local_src="git show HEAD:public/api/anchor-source.json"
			git -C "$FYCT_SELF_DIR" show HEAD:public/api/anchor-source.json > "$head_f" 2>/dev/null || rm -f "$head_f"
		fi
		if [ ! -s "$head_f" ]; then
			v3=UNKNOWN
			d3="no local copy to compare against (${local_src})"
		else
			pub_sha="$(fyct__sha256 "$anchor_f" || true)"
			loc_sha="$(fyct__sha256 "$head_f" || true)"
			if [ -z "$pub_sha" ] || [ -z "$loc_sha" ]; then
				v3=UNKNOWN
				d3="no sha256 tool on this machine (sha256sum / shasum), so byte equality cannot be decided"
			elif [ -z "$cyc_obs" ]; then
				# UNKNOWN, not INCOMPLETE: an absent field is a failure to
				# observe, and this file's rule is that those never resolve to
				# a verdict about the work. (INCOMPLETE would also be safe,
				# but it asserts "the compose has not happened", which a
				# missing field does not establish.)
				v3=UNKNOWN
				d3="the published anchor-source carries no observations_branch.cycle_number_observed, so which cycle it describes cannot be read"
			elif [ "$cyc_obs" != "$INSCRIBE" ]; then
				v3=INCOMPLETE
				d3="the published anchor-source still describes cycle ${cyc_obs}, not ${INSCRIBE}"
			elif [ "$pub_sha" != "$loc_sha" ]; then
				v3=INCOMPLETE
				d3="published sha256 ${pub_sha} != local ${loc_sha}"
			else
				v3=COMPLETE
				d3="published bytes equal the local copy (sha256 ${pub_sha}) and describe cycle ${INSCRIBE}"
			fi
		fi
	fi

	# ---- phase 5 -----------------------------------------------------------
	local schema_ver="" prefix="" tx_id="" act_n="" match_n=""
	if [ -z "$FYCT_TX_JSON" ]; then
		v5=UNKNOWN
		d5="no captured chain response supplied (--tx-json=<path>)"
	elif [ ! -r "$FYCT_TX_JSON" ] || ! jq empty "$FYCT_TX_JSON" >/dev/null 2>&1; then
		v5=UNKNOWN
		d5="--tx-json=${FYCT_TX_JSON} is unreadable or is not JSON"
	elif [ "$have_anchor" -ne 1 ]; then
		v5=UNKNOWN
		d5="the published anchor-source is unreadable, so the expected memo prefix cannot be derived"
	else
		schema_ver="$(jq -r '.schema_version // empty' "$anchor_f" 2>/dev/null || true)"
		if [ -z "$schema_ver" ]; then
			v5=UNKNOWN
			d5="the published anchor-source carries no schema_version, so the memo prefix cannot be derived"
		else
			prefix="fya${schema_ver}c${INSCRIBE}"
			tx_id="$(jq -r "$FYCT_TXQ_ID" "$FYCT_TX_JSON" 2>/dev/null || true)"
			act_n="$(jq -r --arg t "$tx_id" "${FYCT_TXQ_MEMOS} | length" "$FYCT_TX_JSON" 2>/dev/null || true)"
			match_n="$(jq -r --arg t "$tx_id" --arg p "$prefix" "${FYCT_TXQ_MEMOS} | ${FYCT_TXQ_KINDS} | length" "$FYCT_TX_JSON" 2>/dev/null || true)"
			[ -n "$act_n" ] || act_n=0
			[ -n "$match_n" ] || match_n=0
			if [ -z "$tx_id" ] || [ "$act_n" -eq 0 ]; then
				v5=INCOMPLETE
				d5="the response carries no memo for any transaction, so nothing is inscribed yet"
			elif [ "$act_n" -eq 4 ] && [ "$match_n" -eq 4 ]; then
				v5=COMPLETE
				d5="tx ${tx_id} resolves 4 distinct memos, one per branch, all under prefix ${prefix}"
			else
				v5=INCOMPLETE
				d5="tx ${tx_id} resolves ${act_n} distinct memo(s), ${match_n} of the 4 branch memos under prefix ${prefix}"
			fi
		fi
	fi

	# ---- phase 6 -----------------------------------------------------------
	local gate_sig="" gate_dag="" gate_schema="" want_sig="" node_id="" start_t=""
	if [ "$v1" != "COMPLETE" ]; then
		# STALE-PASS GATE. See the header section of that name: phase 6 is the
		# one post-condition that carries no cycle number, so before the
		# node-info tick the PREVIOUS cycle's approved signature still equals
		# the still-current period and this would answer COMPLETE on a day
		# where nothing has happened yet. Measured by review on a
		# transition-morning fixture. Same shape as phase 2's gate above.
		v6=UNKNOWN
		d6="phase 1 has not landed, so a signature matching the current period would be last cycle's, not this one's"
	elif [ ! -r "$FYCT_GATE_STATE" ]; then
		v6=UNKNOWN
		d6="no cycle-gate state at ${FYCT_GATE_STATE} (it lives on the validator host)"
	elif ! jq empty "$FYCT_GATE_STATE" >/dev/null 2>&1; then
		v6=UNKNOWN
		d6="${FYCT_GATE_STATE} is not valid JSON — cycle-gate.sh itself fails closed on this"
	elif [ "$have_valid" -ne 1 ]; then
		v6=UNKNOWN
		d6="the published validator.json is unreadable, so the current cycle signature cannot be derived"
	else
		gate_schema="$(jq -r '.schemaVersion // empty' "$FYCT_GATE_STATE" 2>/dev/null || true)"
		gate_sig="$(jq -r '.approved_cycle_signature // empty' "$FYCT_GATE_STATE" 2>/dev/null || true)"
		gate_dag="$(jq -r '.approved_dag_root_hash // empty' "$FYCT_GATE_STATE" 2>/dev/null || true)"
		node_id="$(jq -r '.nodeId // empty' "$valid_f" 2>/dev/null || true)"
		start_t="$(jq -r '.startTime // empty' "$valid_f" 2>/dev/null || true)"
		if [ "$gate_schema" != "1" ]; then
			v6=UNKNOWN
			d6="state file schemaVersion is '${gate_schema:-<absent>}', not 1 — cycle-gate.sh treats this as fail-closed, and so does this reading"
		elif [ -z "$node_id" ] || [ -z "$start_t" ]; then
			v6=UNKNOWN
			d6="validator.json carries no nodeId/startTime pair, so the expected signature cannot be composed"
		else
			want_sig="${node_id}-${start_t}"
			if [ "$gate_sig" = "$want_sig" ]; then
				v6=COMPLETE
				d6="approved_cycle_signature matches the current on-chain period"
			else
				v6=INCOMPLETE
				d6="approved_cycle_signature is '${gate_sig:-<absent>}', the current cycle is '${want_sig}'"
			fi
		fi
	fi

	# ---- report ------------------------------------------------------------
	fyct__status_verdict 1 "record" "$v1" "$d1"
	fyct__status_verdict 2 "identity" "$v2" "$d2"
	fyct__status_verdict 3 "compose" "$v3" "$d3"
	fyct__status_verdict 4 "rehearsal" "NO-POST-CONDITION" "the design doc states none; none is invented here"
	fyct__status_evidence "The spec's post-condition table has no row for phase 4. Unit 7a's only product is a testnet transaction id on stdout, which nothing publishes, so there is no artifact to re-measure. Confirm the rehearsal by its own sentinel line, not from here."
	fyct__status_verdict 5 "inscribe" "$v5" "$d5"
	fyct__status_verdict 6 "post" "$v6" "$d6"

	# The supplementary observation phase 6 does NOT gate on. Reported because
	# a disagreement here is worth seeing, and separated because the design
	# doc's post-condition names the signature and nothing else — widening a
	# stated post-condition on my own initiative is the kind of quiet drift
	# this file's tables exist to prevent.
	if [ -n "$gate_dag" ] && [ "$have_anchor" -eq 1 ]; then
		local pub_dag
		pub_dag="$(jq -r '.dag_root_computed // empty' "$anchor_f" 2>/dev/null || true)"
		if [ -n "$pub_dag" ]; then
			if [ "$pub_dag" = "$gate_dag" ]; then
				fyct__status_evidence "supplementary (not part of the phase 6 verdict): approved_dag_root_hash equals the published dag_root_computed."
			else
				fyct__status_evidence "supplementary (not part of the phase 6 verdict): approved_dag_root_hash ${gate_dag} differs from the published dag_root_computed ${pub_dag}."
			fi
		fi
	fi

	printf '============================================================================\n'
	printf 'WHERE THIS READING IS NOT A COMPLETE ACCOUNT OF THE DAY\n'
	fyct__status_wrap "  " "FIVE OF THE FOURTEEN EXECUTION UNITS ARE COVERED BY NO POST-CONDITION. The list below is the result of asking, for EVERY unit in the plan, \"if this were skipped, would all five still read COMPLETE?\" — not of noticing one. An earlier revision listed only 8.5, and review found a second (4b); the sweep that produced this list found three more."
	fyct__status_wrap "  " "1. UNIT 7a (phase 4) has no post-condition at all. The rehearsal's only product is a transaction id on stdout, which nothing publishes."
	fyct__status_wrap "  " "2. UNIT 7b (the mainnet dry run) is observed by nothing. Its --dry-run-log is an OPTIONAL argument to unit 7c, so skipping it does not even make 7c fail — it removes the gate-4 evidence silently."
	fyct__status_wrap "  " "3. UNITS 7.5, 8 AND 8.5 are observed by nothing. Phase 6's post-condition is the gate-state signature written by unit 9, and unit 9 reads only the chain, the published anchor-source and the identity manifest — never the receipt or the anchor ledger. So a day where the signing fragment was never transferred, no receipt was verified, no history row was appended and nothing was published still reads COMPLETE here, with the public anchor-receipt.json and anchor-history.jsonl left serving the PREVIOUS cycle."
	fyct__status_wrap "  " "4. UNIT 4b's REGISTRY EDITS are observed by nothing. Phase 2 reads generated_at and the presence of the .sig; identity.json carries no cycle number and no registry state. 4b's commit is needed to publish the manifest at all, so a wholly skipped 4b does show up — but doing the commit WITHOUT the deploy/identity-pin-baseline.json and deploy/publication.json edits leaves every post-condition here green while tests/publication-registry/ goes red on main."
	fyct__status_wrap "  " "5. Phase 2 confirms that identity.json.sig published alongside the manifest. It does NOT verify the signature. Unit 9's Phase 1 is what performs the cryptographic check."
	fyct__status_wrap "  " "6. Phase 3 compares the published bytes against the copy committed IN THE REPOSITORY THIS COMMAND IS RUNNING FROM — this machine's HEAD, not the host's and not the host's live file. Running it on a machine whose HEAD lags the one that committed unit 6 reports INCOMPLETE for a phase that is done. See this script's header for why comparing against a live host copy would be worse."
	fyct__status_wrap "  " "7. Phase 5 verifies the response it was handed, not its provenance. Capture it at the moment you run this; a response from another machine or another hour is not distinguishable here."
	fyct__status_wrap "  " "8. Only the phase-1-HAS-landed reading of --expect-cycle has a second observation. The other reading has none and structurally cannot: before the wallet action the two candidate declarations produce identical public state."
	printf '============================================================================\n'

	local p
	for p in "$v1" "$v2" "$v3" "$v5" "$v6"; do
		case "$p" in
		UNKNOWN) n_unknown=$((n_unknown + 1)) ;;
		INCOMPLETE) n_incomplete=$((n_incomplete + 1)) ;;
		esac
	done

	# ---- what to do next ---------------------------------------------------
	# A UNIT LIST IS ONLY PRINTED FOR INCOMPLETE, NEVER FOR UNKNOWN. An earlier
	# revision printed it for both, and the default live invocation (no
	# --tx-json) therefore answered "PHASE 5 UNKNOWN" and, three lines later,
	# "to advance phase 5: units 7b 7c 7.5" — telling the operator to re-run
	# the day's one irreversible signing unit on the strength of an
	# observation that was never made. "I did not look" and "it is not done"
	# must not produce the same instruction. For UNKNOWN the only honest next
	# step is to obtain the observation, so that is what is printed.
	fyct__status_next 1 "$v1" "the published cycle-history must be readable from --public-base"
	fyct__status_next 2 "$v2" "phase 1 must land first, and the published identity manifest and its .sig must be readable"
	fyct__status_next 3 "$v3" "the published anchor-source and a local copy to compare it with must both be readable"
	fyct__status_next 5 "$v5" "capture this cycle's mainnet transaction with a read-only history query and pass it as --tx-json=<path>"
	fyct__status_next 6 "$v6" "BOTH are required: phase 1 landed, and the cycle-gate state readable (run this ON THE VALIDATOR HOST where it lives, or pass --gate-state=<path>). The verdict line above says which one is missing"

	# Ordering guard on phase 3's advice. Unit 5 RE-COMPOSES anchor-source on
	# the host, and a recompose changes dag_root_computed (this script's
	# header says why). Run after the inscription and the pre-image that was
	# signed stops being the one the site serves. So the advice is only safe
	# while the inscription demonstrably has NOT happened, i.e. v5 INCOMPLETE.
	# UNKNOWN counts as unsafe, not as permission.
	if [ "$v3" = "INCOMPLETE" ] && [ "$v5" != "INCOMPLETE" ]; then
		fyct__status_wrap "             " "STOP before unit 5: phase 5 reads ${v5}. Unit 5 recomposes anchor-source and a recompose changes dag_root_computed, so running it once the cycle is inscribed replaces the pre-image that was signed. Establish that phase 5 has NOT happened before re-running unit 5; unit 6 alone (re-fetch, verify, commit) is the safe half."
	fi

	fyct__status_wrap "" "The resolved command for every unit above is printed by --print-only. docs/CYCLE_GATE.md remains the canon; this reading restates where it stopped."

	if [ "$n_unknown" -gt 0 ]; then
		rc="$FYCT_STATUS_UNKNOWN_RC"
		printf 'RESULT                   : %s post-condition(s) NOT OBSERVED, %s incomplete (exit %s)\n' \
			"$n_unknown" "$n_incomplete" "$rc"
		fyct__status_wrap "" "An observation that could not be made is reported as UNKNOWN and never resolved to COMPLETE. Supply the missing input, or re-run where the artifact lives, before concluding anything about those phases."
	elif [ "$n_incomplete" -gt 0 ]; then
		rc="$FYCT_STATUS_INCOMPLETE_RC"
		printf 'RESULT                   : %s phase(s) not yet complete (exit %s)\n' "$n_incomplete" "$rc"
	else
		rc=0
		printf 'RESULT                   : all five post-conditions measured and COMPLETE (exit 0)\n'
	fi
	printf '============================================================================\n'

	fyct__status_cleanup
	return "$rc"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
fyct_main() {
	set -euo pipefail

	local mode="" ledger="" ttx="" expect=""
	local pubbase="" anchor_local="" tx_json="" gate_state=""
	local usage="usage: bash scripts/cycle-transition.sh {--print-only --ledger=<path> | --status} --expect-cycle=<N>"

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--print-only)
			mode="${mode:+${mode}+}print-only"
			shift
			;;
		--status)
			mode="${mode:+${mode}+}status"
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
		--public-base=*)
			pubbase="${1#--public-base=}"
			shift
			;;
		--anchor-source-local=*)
			anchor_local="${1#--anchor-source-local=}"
			shift
			;;
		--tx-json=*)
			tx_json="${1#--tx-json=}"
			shift
			;;
		--gate-state=*)
			gate_state="${1#--gate-state=}"
			shift
			;;
		-h | --help)
			echo "$usage" >&2
			echo "       --print-only prints the day-of plan. --status re-measures each phase's" >&2
			echo "       post-condition and reports where the day stopped. Neither executes a step;" >&2
			echo "       there is no execution path in this file." >&2
			echo "       --expect-cycle is the cycle CLOSING today (the FY_EXPECT_CYCLE value)." >&2
			echo "       --status also takes --public-base=, --anchor-source-local=, --tx-json=," >&2
			echo "       --gate-state=; see this script's USAGE header." >&2
			return 0
			;;
		*)
			echo "cycle-transition: ERROR: unknown argument: $1" >&2
			echo "                  ${usage}" >&2
			return "$FYCT_USAGE_RC"
			;;
		esac
	done

	if [ "$mode" = "" ]; then
		echo "cycle-transition: ERROR: one of --print-only or --status is required." >&2
		echo "                  There is no default mode, deliberately: a script whose no-argument" >&2
		echo "                  behaviour has to be guessed is a script that will one day be run by" >&2
		echo "                  accident on transition day." >&2
		return "$FYCT_USAGE_RC"
	fi
	if [ "$mode" != "print-only" ] && [ "$mode" != "status" ]; then
		echo "cycle-transition: ERROR: --print-only and --status are separate readings; pass one." >&2
		echo "                  They take different inputs and answer different questions, and a" >&2
		echo "                  combined invocation would have to guess which one you meant." >&2
		return "$FYCT_USAGE_RC"
	fi

	# Cross-mode arguments are REFUSED, not ignored. Silently accepting a flag
	# that does nothing is how an operator ends up believing an observation was
	# made that never was.
	if [ "$mode" = "status" ]; then
		if [ -n "$ledger" ]; then
			echo "cycle-transition: ERROR: --ledger is not accepted with --status." >&2
			echo "                  --status reads the PUBLISHED ledger from --public-base, because the" >&2
			echo "                  published bytes ARE the post-condition. Reading a local mirror instead" >&2
			echo "                  would answer a different question and could report a phase complete" >&2
			echo "                  that the site does not serve." >&2
			return "$FYCT_USAGE_RC"
		fi
		if [ -n "$ttx" ]; then
			echo "cycle-transition: ERROR: --testnet-tx-id is not accepted with --status." >&2
			echo "                  It resolves two printed command lines in --print-only. Phase 4 has no" >&2
			echo "                  post-condition to measure, so --status has nothing to do with it." >&2
			return "$FYCT_USAGE_RC"
		fi
	else
		local stray=""
		[ -z "$pubbase" ] || stray="--public-base"
		[ -z "$anchor_local" ] || stray="${stray:+$stray }--anchor-source-local"
		[ -z "$tx_json" ] || stray="${stray:+$stray }--tx-json"
		[ -z "$gate_state" ] || stray="${stray:+$stray }--gate-state"
		if [ -n "$stray" ]; then
			echo "cycle-transition: ERROR: ${stray} belong(s) to --status, not --print-only." >&2
			echo "                  --print-only prints a plan from the ledger it was handed; it observes" >&2
			echo "                  nothing and must keep working offline." >&2
			return "$FYCT_USAGE_RC"
		fi
	fi

	if [ "$mode" = "print-only" ] && [ -z "$ledger" ]; then
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

	# Globals both modes read.
	N="$expect"
	INSCRIBE="$((expect + 1))"
	PRINTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if [ "$mode" = "status" ]; then
		FYCT_PUBLIC_BASE="${pubbase:-$FYCT_PUBLIC_BASE_DEFAULT}"
		FYCT_ANCHOR_LOCAL="$anchor_local"
		FYCT_TX_JSON="$tx_json"
		if [ -n "$gate_state" ]; then
			FYCT_GATE_STATE="$gate_state"
		else
			# Resolved through the library that owns the path, so --status
			# looks where the writers write. fyd_state_dir is a resolution,
			# not a side effect; it announces the production default on
			# stderr when FY_LIVE is unset, which is exactly the warning an
			# operator wants to see before reading that file.
			local state_dir
			state_dir="$(fyd_state_dir cycle)" || return $?
			FYCT_GATE_STATE="${state_dir}/cycle-gate-state.json"
		fi
		fyct__check_phase_agreement || return $?
		fyct_status_report
		return $?
	fi

	fyct__require_env || return $?

	# Globals the command blocks read.
	LEDGER="$ledger"

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
	REMOTE_REPO="${FY_REMOTE_REPO:-/home/deploy/metal.freedom-yield.com}"
	TTX="$ttx"
	TTX_KNOWN=0
	[ -n "$ttx" ] && TTX_KNOWN=1

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
