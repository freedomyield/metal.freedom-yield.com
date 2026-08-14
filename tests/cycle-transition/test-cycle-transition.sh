#!/usr/bin/env bash
# tests/cycle-transition/test-cycle-transition.sh
#
# The executable statement of what scripts/cycle-transition.sh --print-only
# promises. Every assertion that could be a tautology is paired with a
# mutation that proves it can fail (design doc §7: "新規の不変条件はすべて
# mutation で実証する").
#
# Covered:
#   A. the plan prints all 13 execution units from
#      docs/cycle-transition-steps.json, plus step 4b from docs/CYCLE_GATE.md
#      — MUTATED per unit: dropping any one row turns the check red
#   B. the drift gate (spec §8): docs/CYCLE_GATE.md's runbook step markers and
#      the orchestrator's unit table must describe the same set — MUTATED
#   C. the output is fully env-resolved: zero `$FOO` / `${BAR}`
#   D. the output is paste-safe: it parses as a shell script, and every
#      command line names the machine it runs on
#   E. --print-only has no side effects — MEASURED with tattling PATH stubs
#      and before/after snapshots, not asserted from reading the source
#   F. the cycle number cannot drift by one across a re-print
#   G. the orchestrator holds no broadcast-tool string (checked here too, not
#      delegated to tests/orchestrator-guard/, per the task's requirement to
#      verify it independently)
#   H. the phase table agrees with scripts/lib/cycle-context.sh — MUTATED
#
# CHAIN: none — runs the orchestrator in --print-only, which prints and exits.
#        No chain read, no broadcast, no network, no production path.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (read-only).
#
# Usage:
#   bash tests/cycle-transition/test-cycle-transition.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ORCH="${REPO_ROOT}/scripts/cycle-transition.sh"
STEPS_JSON="${REPO_ROOT}/docs/cycle-transition-steps.json"
CYCLE_GATE_DOC="${REPO_ROOT}/docs/CYCLE_GATE.md"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

finish() {
	echo "test-cycle-transition.sh summary: PASS=$PASS  FAIL=$FAIL"
	if [ "$FAIL" -eq 0 ]; then
		echo "RESULT: PASS"
		exit 0
	fi
	echo "RESULT: FAIL"
	exit 1
}

for f in "$ORCH" "$STEPS_JSON" "$CYCLE_GATE_DOC"; do
	[ -r "$f" ] || bad "required input not readable: ${f#"${REPO_ROOT}"/}"
done
command -v jq >/dev/null 2>&1 || bad "jq is required for this suite"
[ "$FAIL" -eq 0 ] || finish

TMP="$(mktemp -d -t cycle-transition-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures. The sandbox HOME keeps the resolved FY_CONFIG_DIR deterministic
# and off the real one. The host coordinates are RFC 5737 documentation
# values, never a real host (memory/feedback_no_literal_host_identifier.md).
# ---------------------------------------------------------------------------
SANDBOX_HOME="${TMP}/home"
mkdir -p "$SANDBOX_HOME"
FAKE_HOST="203.0.113.11"
FAKE_KEY="${SANDBOX_HOME}/.ssh/fixture-key"
TX64="$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 \
	17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 \
	33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 \
	49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64)"

# A ledger with M contiguous closed cycles.
make_ledger() {
	local n="$1" out="$2" i=1
	: > "$out"
	while [ "$i" -le "$n" ]; do
		printf '{"cycle_n":%d,"uptime":"99.98"}\n' "$i" >> "$out"
		i=$((i + 1))
	done
}
LEDGER_PRE="${TMP}/ledger-pre.jsonl"   # 3 closed: phase 1 not yet run
LEDGER_POST="${TMP}/ledger-post.jsonl" # 4 closed: phase 1 landed
make_ledger 3 "$LEDGER_PRE"
make_ledger 4 "$LEDGER_POST"
EXPECT_CYCLE=4
EXPECT_INSCRIBE=5

# run_plan <ledger> <outfile> [extra args...] -> rc
run_plan() {
	local ledger="$1" out="$2"
	shift 2
	env HOME="$SANDBOX_HOME" \
		VALIDATOR_HOST="$FAKE_HOST" \
		VALIDATOR_HOST_KEY="$FAKE_KEY" \
		bash "$ORCH" --print-only --expect-cycle="$EXPECT_CYCLE" \
		--ledger="$ledger" "$@" > "$out" 2>"${out}.err"
}

PLAN="${TMP}/plan.txt"
if run_plan "$LEDGER_POST" "$PLAN"; then
	ok "--print-only exits 0 on a well-formed ledger"
else
	bad "--print-only failed (rc=$?): $(head -3 "${PLAN}.err")"
	finish
fi

# plan_unit_ids <plan> — the unit ids the plan actually printed.
plan_unit_ids() {
	grep -oE '^# \[unit [^]]+\]' "$1" | sed 's/^# \[unit //; s/\]$//'
}

# ===========================================================================
# A. Unit coverage against docs/cycle-transition-steps.json (+ step 4b)
# ===========================================================================
JSON_IDS="$(jq -r '.steps[].id' "$STEPS_JSON" | sort)"
JSON_COUNT="$(printf '%s\n' "$JSON_IDS" | grep -c .)"
if [ "$JSON_COUNT" -eq 13 ]; then
	ok "docs/cycle-transition-steps.json still declares 13 execution units"
else
	bad "docs/cycle-transition-steps.json declares ${JSON_COUNT} units, expected 13 — the plan's baseline moved"
fi

PLAN_IDS="$(plan_unit_ids "$PLAN" | sort)"
MISSING=""
while IFS= read -r id; do
	[ -n "$id" ] || continue
	printf '%s\n' "$PLAN_IDS" | grep -qxF "$id" || MISSING="${MISSING:+$MISSING }$id"
done <<EOF
$JSON_IDS
EOF
if [ -z "$MISSING" ]; then
	ok "every one of the 13 indexed execution units appears in --print-only output"
else
	bad "units missing from the plan: ${MISSING}"
fi

# The plan carries exactly one unit the index does not: step 4b. Pinning the
# difference (rather than allowing "a superset") is what stops an unrelated
# step from quietly joining the plan.
EXTRA="$(comm -13 <(printf '%s\n' "$JSON_IDS") <(printf '%s\n' "$PLAN_IDS"))"
if [ "$EXTRA" = "4b" ]; then
	ok "the plan carries exactly one non-indexed unit, and it is step 4b"
else
	bad "plan-vs-index difference is '$(echo "$EXTRA" | tr '\n' ' ')', expected exactly '4b'"
fi

# Step 4b again, by name and explicitly: the task requires it not be dropped.
if plan_unit_ids "$PLAN" | grep -qxF '4b'; then
	ok "step 4b (C4 post-issuance cleanup) is present in the plan"
else
	bad "step 4b is MISSING from the plan"
fi
if grep -q 'identity-pin-baseline.json' "$PLAN" && grep -q 'known_kind_violations' "$PLAN"; then
	ok "step 4b carries its actual cleanup checklist, not just a heading"
else
	bad "step 4b heading present but its cleanup checklist is missing"
fi

# A unit heading is not a step. Every script docs/cycle-transition-steps.json
# declares must actually be INVOKED on a command line IN ITS OWN UNIT —
# otherwise a unit keeps its id and its prose while quietly running nothing.
#
# Scoping to the unit is load-bearing, not pedantry: an earlier revision of
# this case searched the whole plan, and deleting unit 3's
# push-to-web-host.sh call left it GREEN because unit 8.5 calls the same
# script. That is precisely the vacuous pass this suite exists to rule out.
#
# Checked against the tx-resolved plan so units 7b/7c are live commands rather
# than the deliberately commented-out pending form.
PLAN_COV="${TMP}/plan-coverage.txt"
run_plan "$LEDGER_POST" "$PLAN_COV" --testnet-tx-id="$TX64" || true

# unit_block <plan> <unit-id> — the command lines belonging to one unit.
# Literal index() matching, not regex: unit ids 7.5 and 8.5 contain a dot.
unit_block() {
	awk -v want="# [unit $2] " '
		index($0, want) == 1 { f = 1; next }
		index($0, "# [unit ") == 1 { f = 0 }
		index($0, "# === PHASE") == 1 { f = 0 }
		f { print }
	' "$1" | grep -vE '^#'
}
COV_MISSING=""
COV_N=0
while IFS=$'\t' read -r step_id script; do
	[ -n "$step_id" ] || continue
	[ -n "$script" ] || continue
	COV_N=$((COV_N + 1))
	if ! unit_block "$PLAN_COV" "$step_id" | grep -qF "$script"; then
		COV_MISSING="${COV_MISSING:+$COV_MISSING }${step_id}:${script}"
	fi
done < <(jq -r '.steps[] | .id as $i | .scripts[]? | [$i, .] | @tsv' "$STEPS_JSON")
if [ "$COV_N" -lt 12 ]; then
	bad "only ${COV_N} (step, script) pair(s) checked — expected at least 12, the check may be vacuous"
elif [ -z "$COV_MISSING" ]; then
	ok "all ${COV_N} (step, script) pairs from cycle-transition-steps.json are invoked inside their own unit"
else
	bad "declared script(s) not invoked by their own unit: ${COV_MISSING}"
fi

# ---- MUTATION: dropping any single unit row must break coverage -----------
# The rows are captured once, then a subshell re-defines fyct__unit_rows to
# serve them minus one id. This exercises the REAL printer over mutated data;
# it does not re-implement it.
ROWS="${TMP}/rows.txt"
bash -c '. "$1"; fyct__unit_rows' _ "$ORCH" > "$ROWS" 2>/dev/null
if [ ! -s "$ROWS" ]; then
	bad "could not capture the unit table for mutation"
	finish
fi

MUT_DRIVER="${TMP}/mutate.sh"
cat > "$MUT_DRIVER" <<'MUTEOF'
# args: <orchestrator> <rows-file> <id-to-drop>
. "$1"
FYCT_ROWS_FILE="$2"
FYCT_DROP="$3"
fyct__unit_rows() { grep -v "^${FYCT_DROP}|" "$FYCT_ROWS_FILE"; }
LEDGER="/fixture/ledger.jsonl"
N=4
INSCRIBE=5
PHASE1_STATE="fixture"
VH="203.0.113.11"
VHK="/fixture/key"
VHU="root"
CFG="/fixture/config"
TTX=""
TTX_KNOWN=0
PRINTED_AT="1970-01-01T00:00:00Z"
fyct_print_plan
MUTEOF

ROW_COUNT="$(grep -c . "$ROWS")"
MUT_OK=1
MUT_TESTED=0
while IFS= read -r drop_id; do
	[ -n "$drop_id" ] || continue
	MUT_PLAN="${TMP}/plan-drop-${MUT_TESTED}.txt"
	bash "$MUT_DRIVER" "$ORCH" "$ROWS" "$drop_id" > "$MUT_PLAN" 2>/dev/null
	MUT_IDS="$(plan_unit_ids "$MUT_PLAN")"
	MUT_N="$(printf '%s\n' "$MUT_IDS" | grep -c . || true)"
	# The mutant must still be a REAL plan missing exactly one unit. Without
	# this, a mutation driver that silently died would produce an empty file,
	# "the dropped unit is absent" would hold trivially, and the whole loop
	# would report green while proving nothing.
	if [ "$MUT_N" -ne "$((ROW_COUNT - 1))" ]; then
		bad "mutation for ${drop_id} produced ${MUT_N} units, expected $((ROW_COUNT - 1)) — the mutant is not a valid plan, so this case proves nothing"
		MUT_OK=0
	elif printf '%s\n' "$MUT_IDS" | grep -qxF "$drop_id"; then
		bad "MUTATION NOT CAUGHT: unit ${drop_id} still printed after its row was removed"
		MUT_OK=0
	fi
	MUT_TESTED=$((MUT_TESTED + 1))
done < <(cut -d'|' -f1 "$ROWS")

if [ "$MUT_TESTED" -lt 14 ]; then
	bad "mutation loop only exercised ${MUT_TESTED} units, expected 14"
elif [ "$MUT_OK" -eq 1 ]; then
	ok "mutation: dropping any one of the ${MUT_TESTED} unit rows removes it from the output (coverage check is not a tautology)"
fi

# ===========================================================================
# B. Drift gate — docs/CYCLE_GATE.md's runbook vs the orchestrator's units
# ===========================================================================
# Top-level markers in the "Operator runbook" section only (the emergency
# fallback section further down has its own numbered list and is not the
# runbook).
RUNBOOK="${TMP}/runbook.txt"
awk '/^## Operator runbook/{f=1;next} /^## /{f=0} f' "$CYCLE_GATE_DOC" > "$RUNBOOK"
if [ ! -s "$RUNBOOK" ]; then
	bad "could not isolate the Operator runbook section of docs/CYCLE_GATE.md"
	finish
fi

DOC_TOP="$(grep -oE '^([0-9]+(\.[0-9]+)?[a-z]?)\. \*\*' "$RUNBOOK" | sed 's/\. \*\*$//')"
DOC_SUB="$(grep -oE '^[[:space:]]*\*\*7[abc] — ' "$RUNBOOK" | grep -oE '7[abc]')"
# Step 7 is a container for 7a/7b/7c; step 0 is the operator's wallet action,
# which docs/CYCLE_GATE.md itself says is "no script, no gate" — it is stop 1
# in the plan, deliberately not an execution unit.
DOC_UNITS="$(printf '%s\n%s\n' "$DOC_TOP" "$DOC_SUB" | grep -vxE '0|7' | sort -u)"
PLAN_SORTED="$(printf '%s\n' "$PLAN_IDS" | sort -u)"

if [ "$DOC_UNITS" = "$PLAN_SORTED" ]; then
	ok "drift gate: docs/CYCLE_GATE.md's runbook steps and the plan's units are the same set"
else
	bad "drift gate: runbook steps and plan units differ"
	echo "        only in doc : $(comm -23 <(printf '%s\n' "$DOC_UNITS") <(printf '%s\n' "$PLAN_SORTED") | tr '\n' ' ')"
	echo "        only in plan: $(comm -13 <(printf '%s\n' "$DOC_UNITS") <(printf '%s\n' "$PLAN_SORTED") | tr '\n' ' ')"
fi

# Step 0 must remain a documented step that the plan represents as stop 1.
if printf '%s\n' "$DOC_TOP" | grep -qxF '0'; then
	ok "docs/CYCLE_GATE.md still carries step 0 (the wallet action)"
else
	bad "docs/CYCLE_GATE.md step 0 disappeared — stop 1 in the plan would no longer have a canon"
fi
if printf '%s\n' "$DOC_TOP" | grep -qxF '4b'; then
	ok "docs/CYCLE_GATE.md still carries step 4b"
else
	bad "docs/CYCLE_GATE.md step 4b disappeared — the plan would be asserting a step the canon dropped"
fi

# ---- MUTATION: the drift gate must fail when the two sets differ ----------
DOC_UNITS_MUT="$(printf '%s\n' "$DOC_UNITS" | grep -vxF '8.5')"
if [ "$DOC_UNITS_MUT" != "$PLAN_SORTED" ]; then
	ok "mutation: removing one step from the doc-side set makes the drift gate disagree"
else
	bad "MUTATION NOT CAUGHT: drift gate still agreed after a step was removed from the doc set"
fi

# ===========================================================================
# C. Full env resolution
# ===========================================================================
# Unescaped variable references must be zero: those resolve in whatever shell
# pastes the plan, which is exactly what "env fully resolved" forbids.
UNRESOLVED="$(grep -nE '(^|[^\\])\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' "$PLAN" || true)"
if [ -z "$UNRESOLVED" ]; then
	ok "the plan contains zero UNESCAPED shell variables (no \$FOO, no \${BAR}) anywhere"
else
	bad "the plan contains unescaped shell variables:"
	printf '%s\n' "$UNRESOLVED" | head -5 | sed 's/^/        /'
fi

# Escaped ones are legitimate but must be an exact, named allowlist: they
# survive to the DEPLOY shell on the host on purpose. Pinning the set is what
# keeps "one deliberate exception" from drifting into "we stopped resolving".
ESCAPED_NAMES="$(grep -oE '\\\$\{?[A-Za-z_][A-Za-z0-9_]*' "$PLAN" | sed 's/[^A-Za-z0-9_]//g' | sort -u || true)"
if [ "$ESCAPED_NAMES" = "PREV_TX" ]; then
	ok "the only host-evaluated (escaped) variable is PREV_TX, as the header declares"
else
	bad "escaped-variable allowlist drift: got '$(printf '%s' "$ESCAPED_NAMES" | tr '\n' ' ')', expected exactly 'PREV_TX'"
fi
if [ -z "$(grep -F 'PREV_TX' "$PLAN" | grep -vE '^ssh |^#' || true)" ]; then
	ok "PREV_TX appears only inside an ssh remote command, never on a locally-run line"
else
	bad "PREV_TX appears on a line that is not an ssh remote command"
fi

# The resolved values really are substituted, not merely absent.
for needle in "$FAKE_HOST" "$FAKE_KEY" "FY_EXPECT_CYCLE=${EXPECT_CYCLE}" "--expect-cycle=${EXPECT_INSCRIBE}"; do
	if grep -qF -- "$needle" "$PLAN"; then
		ok "resolved value present in the plan: ${needle}"
	else
		bad "resolved value MISSING from the plan: ${needle}"
	fi
done

# ===========================================================================
# D. Paste safety
# ===========================================================================
if bash -n "$PLAN" 2>/dev/null; then
	ok "the whole --print-only output parses as a shell script (bash -n)"
else
	bad "the --print-only output does not parse as a shell script"
fi

UNTAGGED="$(grep -vE '^[[:space:]]*#' "$PLAN" | grep -vE '^[[:space:]]*$' | grep -vE '  # (host|Mac)$' || true)"
if [ -z "$UNTAGGED" ]; then
	ok "every command line names its machine with a trailing '# host' or '# Mac'"
else
	bad "command line(s) with no machine tag:"
	printf '%s\n' "$UNTAGGED" | head -5 | sed 's/^/        /'
fi

# --- Host routing. `# host` is a label; the line must also GET there. -------
# Regression guard for the C2-2 review finding: a bare `bash scripts/foo.sh`
# tagged `# host` silently runs on the Mac (wrong machine, wrong repo) or, if
# the operator ssh's in by hand, as ROOT — which is the ownership accident
# unit 7.5's chmod exists to recover from.
HOST_CMDS="$(grep -E '  # host$' "$PLAN" || true)"
HOST_N="$(printf '%s\n' "$HOST_CMDS" | grep -c . || true)"
if [ "$HOST_N" -ge 7 ]; then
	ok "the plan emits ${HOST_N} host command lines"
else
	bad "expected at least 7 host command lines, found ${HOST_N}"
fi
BAD_HOST="$(printf '%s\n' "$HOST_CMDS" | grep -vE "^ssh -i ${FAKE_KEY} root@${FAKE_HOST} " || true)"
if [ -z "$BAD_HOST" ]; then
	ok "every host command line is a resolved ssh invocation to the validator host"
else
	bad "host command line(s) missing the ssh route:"
	printf '%s\n' "$BAD_HOST" | head -3 | sed 's/^/        /'
fi
BAD_SUDO="$(printf '%s\n' "$HOST_CMDS" | grep -vF "sudo -u deploy" || true)"
if [ -z "$BAD_SUDO" ]; then
	ok "every host command line drops to the deploy user (never runs as root)"
else
	bad "host command line(s) that would run as root:"
	printf '%s\n' "$BAD_SUDO" | head -3 | sed 's/^/        /'
fi
BAD_REPO="$(printf '%s\n' "$HOST_CMDS" | grep -vF "/home/deploy/metal.freedom-yield.com" || true)"
if [ -z "$BAD_REPO" ]; then
	ok "every host command line names the repo path on the host"
else
	bad "host command line(s) with no host repo path"
fi
# Mac lines may legitimately contact the host — unit 7.5 IS the Mac->host
# transfer (scp + a defensive chmod). What they must never do is run a
# pipeline script on the host, which is the thing that has to go through
# sudo -u deploy.
MAC_CMDS="$(grep -E '  # Mac$' "$PLAN" || true)"
if [ -z "$(printf '%s\n' "$MAC_CMDS" | grep -F 'sudo -u deploy' || true)" ]; then
	ok "no Mac-tagged line carries sudo -u deploy (host execution is not smuggled onto a Mac line)"
else
	bad "a Mac-tagged line carries sudo -u deploy"
fi
if [ -z "$(printf '%s\n' "$MAC_CMDS" | grep -E 'bash /home/deploy/' || true)" ]; then
	ok "no Mac-tagged line runs a script from the host repo path"
else
	bad "a Mac-tagged line runs a script out of the host repo path"
fi

# --- The three-shell quoting actually survives ------------------------------
# Each ssh line crosses three shells (local -> remote root -> deploy bash -c).
# This evaluates the printed line locally with `ssh` stubbed, proving it yields
# exactly ONE remote-command argument, then evaluates that argument with `sudo`
# stubbed, proving `bash -c` receives the intended script. Nothing real runs:
# the local layer is single-quoted and the escaped `$` does not substitute.
QPROBE="${TMP}/quote-probe.sh"
cat > "$QPROBE" <<'QEOF'
ssh() {
	local last=""
	for a in "$@"; do last="$a"; done
	printf 'ARGC=%s\n' "$#"
	printf '%s' "$last" > "$QP_REMOTE_OUT"
}
sudo() {
	# The whole argument vector, not just the last: the two sanctioned forms
	# end differently (`bash -c <script>` vs `env … bash <path> --apply`).
	printf '%s' "$*" > "$QP_SCRIPT_OUT"
}
eval "$(cat "$QP_LINE")"
eval "$(cat "$QP_REMOTE_OUT")"
QEOF
Q_OK=1
Q_N=0
while IFS= read -r hline; do
	[ -n "$hline" ] || continue
	Q_N=$((Q_N + 1))
	printf '%s\n' "$hline" > "${TMP}/qline.txt"
	QOUT="$(QP_LINE="${TMP}/qline.txt" QP_REMOTE_OUT="${TMP}/qremote.txt" \
		QP_SCRIPT_OUT="${TMP}/qscript.txt" bash "$QPROBE" 2>/dev/null)"
	# ssh must receive exactly: -i <key> <user@host> <one remote command>
	if ! printf '%s' "$QOUT" | grep -qx 'ARGC=4'; then
		bad "host line ${Q_N}: ssh did not receive exactly 4 arguments ($(printf '%s' "$QOUT" | head -1)) — the remote command is being split"
		Q_OK=0
	fi
	# ...and sudo must be handed a command rooted at the host repo path.
	if ! grep -qF '/home/deploy/metal.freedom-yield.com' "${TMP}/qscript.txt" 2>/dev/null; then
		bad "host line ${Q_N}: sudo would not receive a command rooted at the host repo path"
		Q_OK=0
	fi
	if ! grep -qF -- '-u deploy' "${TMP}/qscript.txt" 2>/dev/null; then
		bad "host line ${Q_N}: sudo would not run as the deploy user"
		Q_OK=0
	fi
done <<EOF
$HOST_CMDS
EOF
if [ "$Q_OK" -eq 1 ] && [ "$Q_N" -ge 7 ]; then
	ok "all ${Q_N} host lines survive local -> root -> deploy quoting with one intact remote command"
fi
# The PREV_TX line specifically must reach the deploy shell UNESCAPED, so the
# deploy shell (not the root shell) is the one that reads the ledger.
printf '%s\n' "$HOST_CMDS" | grep -F 'PREV_TX' > "${TMP}/qline.txt" 2>/dev/null || true
if [ -s "${TMP}/qline.txt" ]; then
	QP_LINE="${TMP}/qline.txt" QP_REMOTE_OUT="${TMP}/qremote.txt" \
		QP_SCRIPT_OUT="${TMP}/qscript.txt" bash "$QPROBE" >/dev/null 2>&1
	if grep -q 'PREV_TX=\$(tail' "${TMP}/qscript.txt" 2>/dev/null &&
		grep -q -- '--prev-anchor-tx-id=\$PREV_TX' "${TMP}/qscript.txt" 2>/dev/null; then
		ok "unit 8 reaches the deploy shell with PREV_TX still unevaluated (the host reads its own ledger)"
	else
		bad "unit 8's PREV_TX did not survive to the deploy shell as an unevaluated substitution"
	fi
else
	bad "could not locate the PREV_TX host line"
fi

# --- C1 regression: the identity signature must be staged with the manifest --
SIG_LINE="$(grep -E '^git add ' "$PLAN" || true)"
if printf '%s' "$SIG_LINE" | grep -qF 'public/api/identity.json.sig'; then
	ok "unit 4b stages public/api/identity.json.sig alongside the manifest"
else
	bad "unit 4b's git add omits public/api/identity.json.sig — a new manifest would be published under the previous cycle's signature"
fi
if printf '%s' "$SIG_LINE" | grep -qF 'public/api/identity.json '; then
	ok "unit 4b stages public/api/identity.json"
else
	bad "unit 4b's git add omits public/api/identity.json"
fi

# --- M3: the output warns against republishing itself -----------------------
if grep -q 'DO NOT PASTE THIS OUTPUT INTO A COMMIT' "$PLAN"; then
	ok "the plan carries the do-not-republish banner (it contains host + key paths)"
else
	bad "the plan is missing the do-not-republish banner"
fi

# The machine set is closed: a third spelling would read as a new machine.
BAD_MACHINE="$(grep -oE '^# \[unit [^]]+\] [^ ]+' "$PLAN" | awk '{print $NF}' | grep -vxE 'host|Mac' || true)"
if [ -z "$BAD_MACHINE" ]; then
	ok "every unit header declares host or Mac and nothing else"
else
	bad "unrecognized machine name(s): $(printf '%s' "$BAD_MACHINE" | tr '\n' ' ')"
fi

# All four stop blocks are present and each names the operator.
STOPS="$(grep -c '^# ⏸ STOP ' "$PLAN" || true)"
if [ "$STOPS" -eq 4 ]; then
	ok "all four operator stop blocks are printed"
else
	bad "expected 4 stop blocks, found ${STOPS}"
fi

# ===========================================================================
# E. No side effects — measured, not asserted
# ===========================================================================
# Tattling stubs for every command that could reach outside this process.
STUBDIR="${TMP}/stubs"
TATTLE="${TMP}/tattle.log"
mkdir -p "$STUBDIR"
: > "$TATTLE"
for c in ssh scp curl wget rsync git ntfy mail sendmail; do
	printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$c" "$TATTLE" > "${STUBDIR}/${c}"
	chmod +x "${STUBDIR}/${c}"
done

CANARY="${TMP}/canary"
mkdir -p "$CANARY/sub"
printf 'original\n' > "$CANARY/file-a"
printf 'original\n' > "$CANARY/sub/file-b"
snapshot() { find "$1" -type f -exec shasum {} \; 2>/dev/null | sort; }
CANARY_BEFORE="$(snapshot "$CANARY")"
REPO_BEFORE="$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | sort)"
HOME_BEFORE="$(snapshot "$SANDBOX_HOME")"

SIDE_PLAN="${TMP}/plan-sidefx.txt"
env PATH="${STUBDIR}:${PATH}" \
	HOME="$SANDBOX_HOME" \
	FY_STATE_DIR="${CANARY}/state" \
	VALIDATOR_HOST="$FAKE_HOST" \
	VALIDATOR_HOST_KEY="$FAKE_KEY" \
	bash "$ORCH" --print-only --expect-cycle="$EXPECT_CYCLE" \
	--ledger="$LEDGER_POST" > "$SIDE_PLAN" 2>/dev/null
SIDE_RC=$?

if [ "$SIDE_RC" -eq 0 ]; then
	ok "--print-only still succeeds with outbound commands stubbed (it never needed them)"
else
	bad "--print-only failed (rc=${SIDE_RC}) under stubbed PATH"
fi
if [ ! -s "$TATTLE" ]; then
	ok "no ssh / scp / curl / wget / rsync / git / notify invocation occurred during --print-only"
else
	bad "--print-only invoked an outbound command: $(head -3 "$TATTLE" | tr '\n' ';')"
fi
if [ "$(snapshot "$CANARY")" = "$CANARY_BEFORE" ]; then
	ok "--print-only left the canary tree byte-identical (no writes, no new files)"
else
	bad "--print-only modified the canary tree"
fi
if [ "$(snapshot "$SANDBOX_HOME")" = "$HOME_BEFORE" ]; then
	ok "--print-only wrote nothing into HOME"
else
	bad "--print-only wrote into HOME"
fi
if [ "$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | sort)" = "$REPO_BEFORE" ]; then
	ok "--print-only changed nothing in the repository working tree"
else
	bad "--print-only changed the repository working tree"
fi
# A dry-mode side effect would announce itself; there must be nothing to announce.
if ! grep -q '^DRY: ' "${PLAN}.err" 2>/dev/null; then
	ok "--print-only emitted no 'DRY:' line — it suppressed nothing because it attempts nothing"
else
	bad "--print-only emitted a 'DRY:' line, so it attempted a side effect"
fi

# ===========================================================================
# F. The cycle number cannot drift by one across a re-print
# ===========================================================================
PLAN_PRE="${TMP}/plan-pre.txt"
if run_plan "$LEDGER_PRE" "$PLAN_PRE"; then
	ok "--print-only accepts a ledger from BEFORE phase 1 (closed = N-1)"
else
	bad "--print-only rejected a legitimate pre-phase-1 ledger"
fi
num_lines() { grep -E "^# cycle (closing today|to inscribe)" "$1"; }
if [ "$(num_lines "$PLAN_PRE")" = "$(num_lines "$PLAN")" ]; then
	ok "a plan printed before phase 1 and one printed after it agree on N and N+1"
else
	bad "the cycle numbers moved between a pre-phase-1 and a post-phase-1 print"
	num_lines "$PLAN_PRE" | sed 's/^/        pre:  /'
	num_lines "$PLAN" | sed 's/^/        post: /'
fi
if grep -q "FY_EXPECT_CYCLE=${EXPECT_CYCLE} " "$PLAN_PRE" && grep -q -- "--expect-cycle=${EXPECT_INSCRIBE}" "$PLAN_PRE"; then
	ok "the pre-phase-1 plan still emits FY_EXPECT_CYCLE=${EXPECT_CYCLE} and --expect-cycle=${EXPECT_INSCRIBE}"
else
	bad "the pre-phase-1 plan emitted the wrong cycle numbers"
fi

# A ledger that matches neither accepted state must be refused, not guessed.
LEDGER_BAD="${TMP}/ledger-bad.jsonl"
make_ledger 9 "$LEDGER_BAD"
run_plan "$LEDGER_BAD" "${TMP}/plan-bad.txt"
BAD_RC=$?
if [ "$BAD_RC" -eq 68 ]; then
	ok "a ledger that agrees with neither N-1 nor N is refused with exit 68"
else
	bad "expected exit 68 for a disagreeing ledger, got ${BAD_RC}"
fi

# ===========================================================================
# G. No broadcast-tool string in the orchestrator (checked here too)
# ===========================================================================
BC_HIT="$(grep -inE '(^|[^A-Za-z0-9_.-])(proton|cleos|safe-broadcast)([^A-Za-z0-9_.-]|$)' "$ORCH" || true)"
if [ -z "$BC_HIT" ]; then
	ok "scripts/cycle-transition.sh contains no broadcast-tool literal (verified independently)"
else
	bad "scripts/cycle-transition.sh contains a broadcast-tool literal: $(printf '%s' "$BC_HIT" | head -1)"
fi
# ...and the same must hold for what it PRINTS, which is what an operator pastes.
BC_OUT="$(grep -inE '(^|[^A-Za-z0-9_.-])(proton|cleos|safe-broadcast)([^A-Za-z0-9_.-]|$)' "$PLAN" || true)"
if [ -z "$BC_OUT" ]; then
	ok "the printed plan contains no broadcast-tool literal either"
else
	bad "the printed plan contains a broadcast-tool literal: $(printf '%s' "$BC_OUT" | head -1)"
fi
# The scanner above must be capable of firing (it is the same expression the
# CI guard uses; proving it here keeps this suite's green independent).
if printf 'bash bin/safe-broadcast --chain=x\n' | grep -qiE '(^|[^A-Za-z0-9_.-])(proton|cleos|safe-broadcast)([^A-Za-z0-9_.-]|$)'; then
	ok "mutation: the broadcast scanner fires on a known-bad line"
else
	bad "MUTATION NOT CAUGHT: the broadcast scanner did not fire on a known-bad line"
fi

# ===========================================================================
# H. Phase agreement with scripts/lib/cycle-context.sh
# ===========================================================================
if bash -c '. "$1"; fyct__check_phase_agreement' _ "$ORCH" >/dev/null 2>&1; then
	ok "every unit's phase agrees with scripts/lib/cycle-context.sh's translation table"
else
	bad "phase disagreement between the unit table and cycle-context.sh"
fi

# The check covers a non-empty set of scripts — otherwise it would pass
# vacuously if the table stopped naming any of them.
CHECKED=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	scripts_field="$(printf '%s' "$line" | cut -d'|' -f4)"
	[ "$scripts_field" = "-" ] && continue
	for s in $scripts_field; do
		s="${s##*/}"
		if bash -c '. "$1"; fyc_phase_of "$2"' _ "${REPO_ROOT}/scripts/lib/cycle-context.sh" "$s" >/dev/null 2>&1; then
			CHECKED=$((CHECKED + 1))
		fi
	done
done < "$ROWS"
if [ "$CHECKED" -ge 8 ]; then
	ok "the phase cross-check covers ${CHECKED} script(s) present in cycle-context.sh's table"
else
	bad "the phase cross-check covers only ${CHECKED} script(s) — expected at least 8, so it may be passing vacuously"
fi

# ---- MUTATION: a wrong phase must be refused, with exit 67 ----------------
PHASE_MUT="${TMP}/phase-mutate.sh"
cat > "$PHASE_MUT" <<'PMEOF'
. "$1"
FYCT_ROWS_FILE="$2"
# Move gen-anchor-source.sh (cycle-context says phase 3) into phase 6.
fyct__unit_rows() { sed 's/^5|3|/5|6|/' "$FYCT_ROWS_FILE"; }
fyct__check_phase_agreement
PMEOF
bash "$PHASE_MUT" "$ORCH" "$ROWS" >/dev/null 2>&1
PM_RC=$?
if [ "$PM_RC" -eq 67 ]; then
	ok "mutation: moving a script to the wrong phase is refused with exit 67"
else
	bad "MUTATION NOT CAUGHT: a wrong phase returned ${PM_RC}, expected 67"
fi

# ===========================================================================
# I. Resolved-rehearsal mode and usage refusals
# ===========================================================================
PLAN_TX="${TMP}/plan-tx.txt"
if run_plan "$LEDGER_POST" "$PLAN_TX" --testnet-tx-id="$TX64"; then
	ok "--testnet-tx-id is accepted"
else
	bad "--testnet-tx-id was rejected: $(head -2 "${PLAN_TX}.err")"
fi
if ! grep -q 'NEEDS 7a TX ID' "$PLAN_TX"; then
	ok "with a rehearsal tx id supplied, units 7b and 7c print live (no pending marker)"
else
	bad "units 7b/7c stayed commented out even though a rehearsal tx id was supplied"
fi
if [ "$(grep -c -- "--testnet-tx-id=${TX64}" "$PLAN_TX")" -eq 2 ]; then
	ok "the rehearsal tx id is substituted into both unit 7b and unit 7c"
else
	bad "expected the rehearsal tx id in exactly 2 command lines"
fi
if bash -n "$PLAN_TX" 2>/dev/null; then
	ok "the tx-resolved plan also parses as a shell script"
else
	bad "the tx-resolved plan does not parse as a shell script"
fi
# Without it, the two lines must be commented out — never emitted live with a
# placeholder that would run against a bogus id.
if [ "$(grep -c '^# \[NEEDS 7a TX ID\]' "$PLAN")" -eq 2 ]; then
	ok "without a rehearsal tx id, units 7b and 7c are emitted commented out"
else
	bad "expected exactly 2 commented-out pending command lines without a tx id"
fi

# Usage refusals, each fail-closed.
try_rc() {
	env HOME="$SANDBOX_HOME" VALIDATOR_HOST="$FAKE_HOST" VALIDATOR_HOST_KEY="$FAKE_KEY" \
		bash "$ORCH" "$@" >/dev/null 2>&1
	printf '%s' $?
}
# expect_rc <expected> <description> -- <args...>
expect_rc() {
	local want="$1" desc="$2" got
	shift 3 # drop expected, description, and the literal --
	got="$(try_rc "$@")"
	if [ "$got" = "$want" ]; then
		ok "$desc"
	else
		bad "${desc} (got exit ${got}, expected ${want})"
	fi
}
expect_rc 64 "missing --expect-cycle is refused with exit 64" -- \
	--print-only --ledger="$LEDGER_POST"
expect_rc 64 "missing --ledger is refused with exit 64" -- \
	--print-only --expect-cycle=4
expect_rc 64 "omitting --print-only is refused with exit 64 (there is no default mode)" -- \
	--expect-cycle=4 --ledger="$LEDGER_POST"
expect_rc 64 "an unknown flag such as --apply is refused with exit 64" -- \
	--print-only --expect-cycle=4 --ledger="$LEDGER_POST" --apply
expect_rc 64 "--expect-cycle=0 is refused with exit 64" -- \
	--print-only --expect-cycle=0 --ledger="$LEDGER_POST"
expect_rc 64 "a short --testnet-tx-id is refused with exit 64" -- \
	--print-only --expect-cycle=4 --ledger="$LEDGER_POST" --testnet-tx-id=deadbeef

# An unreadable ledger must refuse (65), never be read as "zero cycles closed".
MISSING_RC="$(env HOME="$SANDBOX_HOME" VALIDATOR_HOST="$FAKE_HOST" VALIDATOR_HOST_KEY="$FAKE_KEY" \
	bash "$ORCH" --print-only --expect-cycle=4 --ledger="${TMP}/nope.jsonl" >/dev/null 2>&1; printf '%s' $?)"
if [ "$MISSING_RC" = "65" ]; then
	ok "an unreadable ledger is refused with exit 65 (never treated as zero closed cycles)"
else
	bad "an unreadable ledger returned ${MISSING_RC}, expected 65"
fi

# Required env: without it the plan would print a placeholder that cannot be
# pasted, so it must refuse rather than emit one.
NOENV_RC="$(env -u VALIDATOR_HOST -u VALIDATOR_HOST_KEY HOME="$SANDBOX_HOME" \
	bash "$ORCH" --print-only --expect-cycle=4 --ledger="$LEDGER_POST" >/dev/null 2>&1; printf '%s' $?)"
if [ "$NOENV_RC" = "64" ]; then
	ok "missing VALIDATOR_HOST / VALIDATOR_HOST_KEY is refused with exit 64"
else
	bad "missing host env returned ${NOENV_RC}, expected 64"
fi

# ===========================================================================
# J. The orchestrator has no execution path at all in this phase
# ===========================================================================
# Every external command the plan describes must reach the output as TEXT.
# If any of them were invoked, section E's tattle log would be non-empty --
# it is checked there. Here we pin the complementary structural fact: the
# script never executes a repo script.
EXEC_HIT="$(grep -nE '^[[:space:]]*(bash|sh|eval)[[:space:]]' "$ORCH" || true)"
if [ -z "$EXEC_HIT" ]; then
	ok "the orchestrator contains no statement that executes another program"
else
	bad "the orchestrator executes something — this phase must not: $(printf '%s' "$EXEC_HIT" | head -1)"
fi
# ...and that scan must be capable of firing.
EXEC_PROBE="${TMP}/exec-probe.sh"
cp "$ORCH" "$EXEC_PROBE"
printf '\tbash "${FYCT_SELF_DIR}/uptime-history.sh"\n' >> "$EXEC_PROBE"
if grep -qE '^[[:space:]]*(bash|sh|eval)[[:space:]]' "$EXEC_PROBE"; then
	ok "mutation: the execution scan fires when a call to another script is added"
else
	bad "MUTATION NOT CAUGHT: the execution scan missed an added call to another script"
fi

finish
