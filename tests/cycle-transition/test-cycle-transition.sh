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
# The scripts are read through the orchestrator's OWN accessor, not by column
# number. An earlier revision cut field 4 literally; when the actor column was
# inserted, the field moved and this loop silently checked nothing — exactly
# the vacuous pass the CHECKED floor below exists to catch, and it did catch
# it. Going through fyct_unit_scripts means the next column change cannot
# reproduce that. Only the id is read positionally, and it is field 1.
while IFS= read -r id; do
	[ -n "$id" ] || continue
	scripts_field="$(bash -c '. "$1"; fyct_unit_scripts "$2"' _ "$ORCH" "$id" 2>/dev/null)"
	[ -n "$scripts_field" ] || continue
	[ "$scripts_field" = "-" ] && continue
	for s in $scripts_field; do
		s="${s##*/}"
		if bash -c '. "$1"; fyc_phase_of "$2"' _ "${REPO_ROOT}/scripts/lib/cycle-context.sh" "$s" >/dev/null 2>&1; then
			CHECKED=$((CHECKED + 1))
		fi
	done
done < <(cut -d'|' -f1 "$ROWS")
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
# J. The orchestrator has no execution path — in either mode
# ===========================================================================
# Every external command the plan describes must reach the output as TEXT.
# If any of them were invoked, section E's tattle log would be non-empty --
# it is checked there, and section M repeats the measurement for --status.
# Here we pin the complementary structural fact: no shell is ever spawned, so
# no repo script can be run from this file.
# J1. The statement-position scan. Its CLAIM IS SCOPED TO ITS ANCHOR, because
# an earlier revision claimed "never spawns a shell" from this grep alone and
# review disproved it: inserting `FYCT_SPAWN="$(bash -c 'printf ok')"` into
# fyct_status_report left the suite at PASS=110 FAIL=0. The regex is unchanged
# — it is the sentence that was wrong. J2/J3/J4 below are what actually close
# the hole; this one now says only what it tests.
EXEC_HIT="$(grep -nE '^[[:space:]]*(bash|sh|eval)[[:space:]]' "$ORCH" || true)"
if [ -z "$EXEC_HIT" ]; then
	ok "no statement-position bash/sh/eval in the orchestrator (this scan sees line starts only — J2-J4 cover the rest)"
else
	bad "the orchestrator spawns a shell at statement position: $(printf '%s' "$EXEC_HIT" | head -1)"
fi
EXEC_PROBE="${TMP}/exec-probe.sh"
cp "$ORCH" "$EXEC_PROBE"
printf '\tbash "${FYCT_SELF_DIR}/uptime-history.sh"\n' >> "$EXEC_PROBE"
if grep -qE '^[[:space:]]*(bash|sh|eval)[[:space:]]' "$EXEC_PROBE"; then
	ok "mutation: the statement-position scan fires on an added statement-position call"
else
	bad "MUTATION NOT CAUGHT: the statement-position scan missed an added call"
fi

# J2. The form the statement-position scan misses: a shell started inside a
# command substitution or backticks. This is the exact probe review used.
SUBSHELL_RE='\$\([[:space:]]*(bash|sh|zsh|eval|source)[[:space:]]|`[[:space:]]*(bash|sh|zsh)[[:space:]]'
SUB_HIT="$(grep -nE "$SUBSHELL_RE" "$ORCH" | grep -vE '^[0-9]+:#' || true)"
if [ -z "$SUB_HIT" ]; then
	ok "no shell started inside a command substitution or backticks either"
else
	bad "the orchestrator starts a shell inside a substitution: $(printf '%s' "$SUB_HIT" | head -1)"
fi
SUB_PROBE="${TMP}/subshell-probe.sh"
cp "$ORCH" "$SUB_PROBE"
printf '\tFYCT_SPAWN="$(bash -c %sprintf ok%s)"\n' "'" "'" >> "$SUB_PROBE"
if grep -qE "$SUBSHELL_RE" "$SUB_PROBE"; then
	ok "mutation: the substitution scan fires on review's own FYCT_SPAWN probe"
else
	bad "MUTATION NOT CAUGHT: the substitution scan missed the FYCT_SPAWN probe"
fi

# J3. THE ONE THAT ACTUALLY FORECLOSES DIRECT-PATH EXECUTION. PATH stubs and
# the greps above can all be walked around by running a repo script by its
# absolute path. The orchestrator has exactly ONE path root it could build
# such a path from — FYCT_SELF_DIR — so pinning every non-comment use of it to
# an exact allowlist is what makes "no transition step can be run from here" a
# statement about the file rather than about one syntax.
SELFDIR_USES="$(grep -nE 'FYCT_SELF_DIR' "$ORCH" | grep -vE '^[0-9]+:#' | sed 's/^[0-9]*://' | sed 's/^[[:space:]]*//' | sort)"
SELFDIR_EXPECTED="$(printf '%s\n' \
	'. "${FYCT_SELF_DIR}/lib/cycle-context.sh"' \
	'. "${FYCT_SELF_DIR}/lib/side-effects.sh"' \
	'FYCT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
	'git -C "$FYCT_SELF_DIR" show HEAD:public/api/anchor-source.json > "$head_f" 2>/dev/null || rm -f "$head_f"' \
	| sort)"
if [ "$SELFDIR_USES" = "$SELFDIR_EXPECTED" ]; then
	ok "the orchestrator's only path root is used in exactly 4 sanctioned ways (2 library sources, its own definition, one read-only git show)"
else
	bad "FYCT_SELF_DIR is used in a way this suite has not sanctioned:"
	comm -13 <(printf '%s\n' "$SELFDIR_EXPECTED") <(printf '%s\n' "$SELFDIR_USES") | head -3 | sed 's/^/        /'
fi
SELF_PROBE="${TMP}/selfdir-probe.sh"
cp "$ORCH" "$SELF_PROBE"
printf '\tFYCT_OUT="$("${FYCT_SELF_DIR}/uptime-history.sh")"\n' >> "$SELF_PROBE"
SELF_PROBE_USES="$(grep -nE 'FYCT_SELF_DIR' "$SELF_PROBE" | grep -vE '^[0-9]+:#' | sed 's/^[0-9]*://' | sed 's/^[[:space:]]*//' | sort)"
if [ "$SELF_PROBE_USES" != "$SELFDIR_EXPECTED" ]; then
	ok "mutation: the path-root allowlist fires on a direct-path execution of a repo script"
else
	bad "MUTATION NOT CAUGHT: a direct-path execution of a repo script passed the path-root allowlist"
fi

# J4. `eval` / `source` / `.` are shell BUILTINS, so no PATH stub can see them.
# Pin them to the two library sources and nothing else.
BUILTIN_USES="$(grep -nE '^[[:space:]]*(eval|source|\.)[[:space:]]' "$ORCH" | sed 's/^[0-9]*://' | sed 's/^[[:space:]]*//' | sort)"
BUILTIN_EXPECTED="$(printf '%s\n' \
	'. "${FYCT_SELF_DIR}/lib/cycle-context.sh"' \
	'. "${FYCT_SELF_DIR}/lib/side-effects.sh"' | sort)"
if [ "$BUILTIN_USES" = "$BUILTIN_EXPECTED" ]; then
	ok "eval / source / . appear only as the two sanctioned library sources"
else
	bad "an unsanctioned eval/source/. statement is present: $(printf '%s' "$BUILTIN_USES" | head -1)"
fi

# ===========================================================================
# K. --status: the post-conditions are MEASURED, and every one is mutated
# ===========================================================================
# docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md §5 lists
# five post-conditions and none for phase 4. This section builds a fixture in
# which all five hold, proves --status says so, then breaks each one
# INDIVIDUALLY and proves the verdict stops saying COMPLETE. Without the
# mutations the first case would pass just as happily against a --status that
# printed COMPLETE unconditionally.
#
# Everything here is hermetic: --public-base points at a local directory, so
# no request leaves this machine and no live feed can turn the suite red.

if date --version >/dev/null 2>&1; then
	epoch_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
else
	epoch_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
fi

# Never a real node id (memory/feedback_no_literal_host_identifier.md and the
# public-repo sanitize rule): the string only has to round-trip through the
# signature composition.
STATUS_NODE="NodeID-fixtureonlyNOTaRealNodeIdentifier"
STATUS_DAG="$(printf 'd%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 \
	17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 \
	33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 \
	49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64)"
STATUS_TX="$(printf 'b%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 \
	17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 \
	33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 \
	49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64)"

# make_status_pub <dir> <rows> <last_end_epoch> <start_epoch> <end_epoch> \
#                 <generated_at_epoch> <cycle_number_observed>
# Lays out a directory the same way the site does, so --public-base can read
# it with no network.
make_status_pub() {
	local d="$1" rows="$2" last_end="$3" st="$4" en="$5" gen="$6" cyc="$7" i=1
	mkdir -p "${d}/api"
	: > "${d}/api/cycle-history.jsonl"
	while [ "$i" -le "$rows" ]; do
		if [ "$i" -eq "$rows" ]; then
			printf '{"cycle_n":%d,"cycle_status":"closed","end_iso":"%s"}\n' \
				"$i" "$(epoch_iso "$last_end")" >> "${d}/api/cycle-history.jsonl"
		else
			printf '{"cycle_n":%d,"cycle_status":"closed","end_iso":"1970-01-01T00:00:00Z"}\n' \
				"$i" >> "${d}/api/cycle-history.jsonl"
		fi
		i=$((i + 1))
	done
	printf '{"schema_version":1,"nodeId":"%s","startTime":%s,"endTime":%s}\n' \
		"$STATUS_NODE" "$st" "$en" > "${d}/api/validator.json"
	printf '{"schema_version":1,"generated_at":"%s"}\n' "$(epoch_iso "$gen")" \
		> "${d}/api/identity.json"
	printf 'SSHSIG-fixture-not-a-real-signature\n' > "${d}/api/identity.json.sig"
	printf '{"schema_version":1,"dag_root_computed":"%s","observations_branch":{"cycle_number_observed":%s}}\n' \
		"$STATUS_DAG" "$cyc" > "${d}/api/anchor-source.json"
}

# make_status_tx <file> <memo-prefix>
# The `traces` shape, with three entries per action. That is not an invention:
# measured 2026-08-17 against the real cycle-4 anchor transaction, the v1
# history response carried NO top-level `.actions` and TWELVE `.traces` — a
# token transfer notifies both parties on top of executing. A fixture using
# the shape the code WISHED for would have proved nothing about the shape the
# chain actually returns.
make_status_tx() {
	local f="$1" p="$2" first=1 suffix i
	{
		printf '{"id":"%s","traces":[' "$STATUS_TX"
		for suffix in "-id:aa" "-ob:bb" "-ar:cc" ":dd"; do
			for i in 1 2 3; do
				[ "$first" -eq 1 ] || printf ','
				first=0
				printf '{"trx_id":"%s","act":{"data":{"memo":"%s%s"}}}' \
					"$STATUS_TX" "$p" "$suffix"
			done
		done
		printf ']}\n'
	} > "$f"
}

# make_status_gate <file> <signature>
make_status_gate() {
	printf '{"schemaVersion":1,"approved_cycle_signature":"%s","approved_dag_root_hash":"%s","approved_at":"1970-01-01T00:00:00Z"}\n' \
		"$2" "$STATUS_DAG" > "$1"
}

STATUS_RC=0
# run_status <outfile> <expect-cycle> [args...]
run_status() {
	local out="$1" ec="$2"
	shift 2
	env HOME="$SANDBOX_HOME" FY_STATE_DIR="${TMP}/no-state-dir" \
		bash "$ORCH" --status --expect-cycle="$ec" "$@" > "$out" 2>"${out}.err"
	STATUS_RC=$?
}

# verdict_of <plan> <phase> — the verdict word on that phase's line.
verdict_of() {
	awk -v p="PHASE $2 " 'index($0, p) == 1 { print $4 }' "$1"
}

ST_NOW="$(date -u +%s)"
ST_START=$((ST_NOW - 86400))          # the new period opened yesterday
ST_END=$((ST_NOW + 31 * 86400))       # and runs another month
ST_GEN=$((ST_START + 3600))           # the manifest was re-signed after it
ST_N=4
ST_INSCRIBE=5

STATUS_OK="${TMP}/status-ok"
mkdir -p "$STATUS_OK"
make_status_pub "${STATUS_OK}/pub" "$ST_N" "$ST_START" "$ST_START" "$ST_END" "$ST_GEN" "$ST_INSCRIBE"
cp "${STATUS_OK}/pub/api/anchor-source.json" "${STATUS_OK}/anchor-local.json"
make_status_tx "${STATUS_OK}/tx.json" "fya1c${ST_INSCRIBE}"
make_status_gate "${STATUS_OK}/gate.json" "${STATUS_NODE}-${ST_START}"

# ok_args — the full set of inputs under which all five post-conditions hold.
ok_args() {
	printf '%s\n' \
		"--public-base=${STATUS_OK}/pub" \
		"--anchor-source-local=${STATUS_OK}/anchor-local.json" \
		"--tx-json=${STATUS_OK}/tx.json" \
		"--gate-state=${STATUS_OK}/gate.json"
}
# shellcheck disable=SC2207
OK_ARGS=($(ok_args))

ST_ALL="${TMP}/status-all.txt"
run_status "$ST_ALL" "$ST_N" "${OK_ARGS[@]}"
if [ "$STATUS_RC" -eq 0 ]; then
	ok "--status exits 0 when all five post-conditions hold"
else
	bad "--status returned ${STATUS_RC} on an all-complete fixture: $(head -3 "${ST_ALL}.err")"
fi
ALL_COMPLETE=1
for ph in 1 2 3 5 6; do
	v="$(verdict_of "$ST_ALL" "$ph")"
	if [ "$v" != "COMPLETE" ]; then
		bad "phase ${ph} read '${v}' on the all-complete fixture, expected COMPLETE"
		ALL_COMPLETE=0
	fi
done
if [ "$ALL_COMPLETE" -eq 1 ]; then
	ok "all five measurable post-conditions read COMPLETE on the all-complete fixture"
fi

# Phase 4 is SKIPPED as having no post-condition — not invented, not silently
# folded into the arithmetic.
if [ "$(verdict_of "$ST_ALL" 4)" = "NO-POST-CONDITION" ]; then
	ok "phase 4 is reported as NO-POST-CONDITION (the design doc states none)"
else
	bad "phase 4 read '$(verdict_of "$ST_ALL" 4)', expected NO-POST-CONDITION"
fi
if grep -q 'no row for phase 4' "$ST_ALL"; then
	ok "the report says WHY phase 4 has no post-condition, rather than just omitting it"
else
	bad "phase 4 is skipped without stating why"
fi
if grep -q 'all five post-conditions measured and COMPLETE' "$ST_ALL"; then
	ok "the summary counts five post-conditions, so phase 4 is excluded from the arithmetic"
else
	bad "the all-complete summary does not count exactly five post-conditions"
fi

# An all-COMPLETE reading must not read as "the day is finished": the design
# doc's five post-conditions do not cover unit 8.5, and the report has to say
# so ON THE ALL-GREEN PATH, which is the only path where it matters.
if grep -q 'WHERE THIS READING IS NOT A COMPLETE ACCOUNT OF THE DAY' "$ST_ALL"; then
	ok "the report states its own limits, including on the all-complete path"
else
	bad "the report omits its limits block"
fi
# The uncovered-unit list is the result of sweeping ALL 14 units, so the test
# pins every unit the sweep found rather than the one that was noticed first.
# An earlier revision disclosed only 8.5; review found 4b; the sweep then found
# 7b, 7.5 and 8. A regression that quietly drops any of them is the same
# failure as never having listed it.
UNCOVERED_MISSING=""
for u in '7a' '7b' '7.5, 8 AND 8.5' '4b'; do
	grep -qF "$u" "$ST_ALL" || UNCOVERED_MISSING="${UNCOVERED_MISSING:+$UNCOVERED_MISSING }${u}"
done
if [ -z "$UNCOVERED_MISSING" ]; then
	ok "the limits block names every unit the coverage sweep found uncovered (7a, 7b, 7.5/8/8.5, 4b)"
else
	bad "the limits block no longer discloses: ${UNCOVERED_MISSING}"
fi
if grep -q 'FIVE OF THE FOURTEEN EXECUTION UNITS ARE COVERED BY NO POST-CONDITION' "$ST_ALL"; then
	ok "the limits block states the coverage arithmetic (5 of 14 units), not just examples"
else
	bad "the limits block does not state how many units are uncovered"
fi

# ---- MUTATION: break each post-condition on its own -----------------------
# mutate_case <name> <phase> <expected-verdict> <prep-fn>
# Each prep function receives a fresh copy of the passing fixture and breaks
# exactly one thing.
MUT_DIR_N=0
mutate_case() {
	local name="$1" phase="$2" want="$3" prep="$4" got
	MUT_DIR_N=$((MUT_DIR_N + 1))
	local d="${TMP}/status-mut-${MUT_DIR_N}"
	rm -rf "$d"
	cp -R "$STATUS_OK" "$d"
	"$prep" "$d"
	local out="${TMP}/status-mut-${MUT_DIR_N}.txt"
	# shellcheck disable=SC2207
	local args=($(printf '%s\n' \
		"--public-base=${d}/pub" \
		"--anchor-source-local=${d}/anchor-local.json" \
		"--tx-json=${d}/tx.json" \
		"--gate-state=${d}/gate.json"))
	if [ "$name" = "no --tx-json supplied" ]; then
		args=("--public-base=${d}/pub" "--anchor-source-local=${d}/anchor-local.json" "--gate-state=${d}/gate.json")
	fi
	if [ "$name" = "no cycle-gate state file" ]; then
		args=("--public-base=${d}/pub" "--anchor-source-local=${d}/anchor-local.json" "--tx-json=${d}/tx.json" "--gate-state=${d}/absent.json")
	fi
	run_status "$out" "$ST_N" "${args[@]}"
	got="$(verdict_of "$out" "$phase")"
	if [ "$got" = "$want" ]; then
		ok "mutation: ${name} -> phase ${phase} reads ${got}"
	else
		bad "MUTATION NOT CAUGHT: ${name} -> phase ${phase} read '${got}', expected ${want}"
	fi
}

mut_drop_row() { head -n $((ST_N - 1)) "${1}/pub/api/cycle-history.jsonl" > "${1}/tmp.jsonl"; mv "${1}/tmp.jsonl" "${1}/pub/api/cycle-history.jsonl"; }
mut_stale_identity() { printf '{"schema_version":1,"generated_at":"%s"}\n' "$(epoch_iso $((ST_START - 3600)))" > "${1}/pub/api/identity.json"; }
mut_drop_sig() { rm -f "${1}/pub/api/identity.json.sig"; }
mut_local_bytes() { printf '\n' >> "${1}/anchor-local.json"; }
mut_old_cycle() { printf '{"schema_version":1,"dag_root_computed":"%s","observations_branch":{"cycle_number_observed":%s}}\n' "$STATUS_DAG" "$ST_N" > "${1}/pub/api/anchor-source.json"; cp "${1}/pub/api/anchor-source.json" "${1}/anchor-local.json"; }
mut_wrong_memo() { make_status_tx "${1}/tx.json" "fya1c${ST_N}"; }
mut_noop() { :; }
mut_wrong_sig() { make_status_gate "${1}/gate.json" "${STATUS_NODE}-1"; }

mutate_case "the published ledger is one row short"        1 INCOMPLETE mut_drop_row
mutate_case "identity generated_at predates the cycle end" 2 INCOMPLETE mut_stale_identity
mutate_case "identity.json.sig did not publish"            2 INCOMPLETE mut_drop_sig
mutate_case "the local anchor-source copy differs by one byte" 3 INCOMPLETE mut_local_bytes
mutate_case "the published anchor-source still names the old cycle" 3 INCOMPLETE mut_old_cycle
mutate_case "the transaction's memos carry the previous cycle's prefix" 5 INCOMPLETE mut_wrong_memo
mutate_case "no --tx-json supplied"                        5 UNKNOWN    mut_noop
mutate_case "the cycle-gate signature names another cycle" 6 INCOMPLETE mut_wrong_sig
mutate_case "no cycle-gate state file"                     6 UNKNOWN    mut_noop

# ---- exit-code arithmetic -------------------------------------------------
# 69 (something incomplete) and 70 (something unobservable) must be
# distinguishable, and UNKNOWN must dominate: "could not look" is never
# allowed to read as "looked and it was fine".
ST_69="${TMP}/status-69"
rm -rf "$ST_69"
cp -R "$STATUS_OK" "$ST_69"
make_status_gate "${ST_69}/gate.json" "${STATUS_NODE}-1"
run_status "${TMP}/status-69.txt" "$ST_N" \
	"--public-base=${ST_69}/pub" "--anchor-source-local=${ST_69}/anchor-local.json" \
	"--tx-json=${ST_69}/tx.json" "--gate-state=${ST_69}/gate.json"
if [ "$STATUS_RC" -eq 69 ]; then
	ok "one incomplete phase and nothing unobservable exits 69"
else
	bad "expected exit 69 for an incomplete-only reading, got ${STATUS_RC}"
fi
run_status "${TMP}/status-70.txt" "$ST_N" \
	"--public-base=${STATUS_OK}/pub" "--anchor-source-local=${STATUS_OK}/anchor-local.json" \
	"--gate-state=${STATUS_OK}/gate.json"
if [ "$STATUS_RC" -eq 70 ]; then
	ok "an unobservable post-condition exits 70, never 0"
else
	bad "expected exit 70 when a post-condition could not be observed, got ${STATUS_RC}"
fi

# ---- next-step lines: UNKNOWN must never read as "re-run these units" -----
# The exact defect review measured on a live default invocation: phase 5 read
# UNKNOWN (no --tx-json) and the report still said "to advance phase 5: units
# 7b 7c 7.5" — 7c being the day's one irreversible signing unit. "I did not
# look" must not produce the same instruction as "it is not done".
if grep -qE '^to OBSERVE phase 5 ' "${TMP}/status-70.txt"; then
	ok "an UNKNOWN phase gets an OBSERVE line naming the input it is missing"
else
	bad "an UNKNOWN phase did not get an OBSERVE line"
fi
if grep -qE '^to advance phase 5 ' "${TMP}/status-70.txt"; then
	bad "REGRESSION: an UNKNOWN phase 5 was told to re-run units 7b/7c/7.5 — 7c is irreversible"
else
	ok "an UNKNOWN phase is never given a unit list to re-run (7c is irreversible)"
fi
# ...and the unit list still appears, from the unit table, when the phase is
# genuinely INCOMPLETE. Without this the fix above could be "print nothing".
if grep -qE '^to advance phase 6 +: units 8 8\.5 9$' "${TMP}/status-69.txt"; then
	ok "an INCOMPLETE phase still gets its unit list, taken from the table --print-only prints"
else
	bad "an INCOMPLETE phase lost its unit list: $(grep -E '^to advance' "${TMP}/status-69.txt" | head -1)"
fi

# The status output must be as free of broadcast-tool literals as the plan.
BC_ST="$(grep -inE '(^|[^A-Za-z0-9_.-])(proton|cleos|safe-broadcast)([^A-Za-z0-9_.-]|$)' "$ST_ALL" || true)"
if [ -z "$BC_ST" ]; then
	ok "the --status report contains no broadcast-tool literal either"
else
	bad "the --status report contains a broadcast-tool literal: $(printf '%s' "$BC_ST" | head -1)"
fi

# ===========================================================================
# L. --status: the second observation closes the --expect-cycle hole
# ===========================================================================
# The C2-2 header records the shape it could not catch: a declaration the
# ledger reads as "phase 1 HAS landed" when it has not. There are two moments
# on transition day where that is possible, and they need DIFFERENT
# observations, so both are exercised.

# L1 — declared on transition morning, before the wallet action. The ledger
# holds N-1 rows and --expect-cycle=N-1, so closed == declared; the chain says
# the current period is about to end.
ST_PRE="${TMP}/status-danger-pre"
mkdir -p "$ST_PRE"
make_status_pub "${ST_PRE}/pub" $((ST_N - 1)) $((ST_NOW - 31 * 86400)) $((ST_NOW - 31 * 86400)) $((ST_NOW + 3600)) "$ST_GEN" "$ST_N"
run_status "${TMP}/status-danger-pre.txt" $((ST_N - 1)) "--public-base=${ST_PRE}/pub" "--gate-state=${TMP}/absent.json"
if [ "$STATUS_RC" -eq 71 ]; then
	ok "the dangerous declaration (ledger = N-1 rows, --expect-cycle = N-1) is refused with exit 71 before the wallet action"
else
	bad "the pre-wallet dangerous declaration returned ${STATUS_RC}, expected 71"
fi
if grep -q 'contradicted by the chain' "${TMP}/status-danger-pre.txt.err"; then
	ok "the refusal names the chain observation that contradicts it"
else
	bad "the pre-wallet refusal does not say what contradicted the declaration"
fi
if grep -q -- "--expect-cycle=${ST_N}" "${TMP}/status-danger-pre.txt.err"; then
	ok "the refusal names the number that should have been declared"
else
	bad "the refusal does not name the corrected --expect-cycle"
fi

# L2 — the SAME declaration made after the wallet action but before unit 3.
# The period is now a month long, so L1's observation passes; what still
# disagrees is where the ledger's last cycle ended.
ST_MID="${TMP}/status-danger-mid"
mkdir -p "$ST_MID"
make_status_pub "${ST_MID}/pub" $((ST_N - 1)) $((ST_NOW - 31 * 86400)) $((ST_NOW - 3600)) "$ST_END" "$ST_GEN" "$ST_N"
run_status "${TMP}/status-danger-mid.txt" $((ST_N - 1)) "--public-base=${ST_MID}/pub" "--gate-state=${TMP}/absent.json"
if [ "$STATUS_RC" -eq 71 ]; then
	ok "the same declaration is still refused after the wallet action, by the cycle-boundary observation"
else
	bad "the post-wallet dangerous declaration returned ${STATUS_RC}, expected 71"
fi
if grep -q 'contradicted by the cycle boundary' "${TMP}/status-danger-mid.txt.err"; then
	ok "the second refusal names the boundary observation, not the period one"
else
	bad "the post-wallet refusal cites the wrong observation"
fi

# L3 — MUTATION IN THE OTHER DIRECTION. A guard that refuses everything would
# pass L1 and L2 while being useless. The CORRECT declaration against the same
# two fixtures must not be refused.
run_status "${TMP}/status-pre-ok.txt" "$ST_N" "--public-base=${ST_PRE}/pub" "--gate-state=${TMP}/absent.json"
PRE_OK_RC="$STATUS_RC"
run_status "${TMP}/status-mid-ok.txt" "$ST_N" "--public-base=${ST_MID}/pub" "--gate-state=${TMP}/absent.json"
MID_OK_RC="$STATUS_RC"
if [ "$PRE_OK_RC" -ne 71 ] && [ "$MID_OK_RC" -ne 71 ]; then
	ok "the CORRECT declaration against the same two fixtures is not refused (rc ${PRE_OK_RC} / ${MID_OK_RC}) — the guard discriminates"
else
	bad "the guard refused a correct declaration (rc ${PRE_OK_RC} / ${MID_OK_RC}) — it is refusing by reflex, not by observation"
fi
if grep -q 'PHASE 1   record      INCOMPLETE' "${TMP}/status-pre-ok.txt"; then
	ok "under the correct declaration the pre-wallet fixture reads phase 1 as INCOMPLETE"
else
	bad "the pre-wallet fixture did not read phase 1 as INCOMPLETE under the correct declaration"
fi

# L4 — the observation itself missing must refuse too. "Could not confirm" is
# not "confirmed" (design doc §6 fail-closed).
ST_NOVAL="${TMP}/status-noval"
rm -rf "$ST_NOVAL"
cp -R "$STATUS_OK" "$ST_NOVAL"
rm -f "${ST_NOVAL}/pub/api/validator.json"
run_status "${TMP}/status-noval.txt" "$ST_N" "--public-base=${ST_NOVAL}/pub" "--gate-state=${TMP}/absent.json"
if [ "$STATUS_RC" -eq 71 ]; then
	ok "an unavailable second observation is refused with exit 71, not accepted"
else
	bad "a missing validator.json returned ${STATUS_RC}, expected 71"
fi

# ---- STALE-PASS: a previous cycle's state must not satisfy a post-condition -
# Review measured this against the implementation: on transition morning,
# before the node-info tick, phase 6 returned COMPLETE. Its post-condition is
# the only one of the five that embeds NO cycle number — "the signature equals
# the CURRENT period" is satisfied by last cycle's state until the period
# rolls over — so the day's most consequential reading answered "the anchor is
# recorded" on a day where nothing had started.
#
# The fixture is that morning exactly: ledger at N-1 rows, the current on-chain
# period a month old and about to end, and a gate state whose signature
# legitimately matches it.
ST_STALE="${TMP}/status-stale6"
mkdir -p "$ST_STALE"
STALE_START=$((ST_NOW - 31 * 86400))
make_status_pub "${ST_STALE}/pub" $((ST_N - 1)) "$STALE_START" "$STALE_START" $((ST_NOW + 3600)) "$ST_GEN" "$ST_N"
make_status_gate "${ST_STALE}/gate.json" "${STATUS_NODE}-${STALE_START}"
run_status "${TMP}/status-stale6.txt" "$ST_N" \
	"--public-base=${ST_STALE}/pub" "--gate-state=${ST_STALE}/gate.json"
STALE_V6="$(verdict_of "${TMP}/status-stale6.txt" 6)"
if [ "$STALE_V6" = "UNKNOWN" ]; then
	ok "stale-pass: on transition morning phase 6 reads UNKNOWN, not COMPLETE, even though the gate signature matches the current period"
else
	bad "STALE PASS: phase 6 read '${STALE_V6}' before the transition began — last cycle's state satisfied a post-condition"
fi
# The gate must be a gate, not a blanket UNKNOWN: with phase 1 landed, the
# same comparison still has to be able to say COMPLETE.
if [ "$(verdict_of "$ST_ALL" 6)" = "COMPLETE" ]; then
	ok "the phase 6 gate still permits COMPLETE once phase 1 has landed (it gates, it does not disable)"
else
	bad "the phase 6 gate suppressed a legitimate COMPLETE"
fi
# The other four embed a cycle number, so the same morning must NOT push them
# to UNKNOWN — masking a real observation is a different failure, not safety.
if [ "$(verdict_of "${TMP}/status-stale6.txt" 1)" = "INCOMPLETE" ]; then
	ok "the same fixture still reports phase 1 INCOMPLETE (the gate did not blanket the report)"
else
	bad "phase 1 lost its verdict on the stale-pass fixture"
fi

# ---- ordering guard on phase 3's advice (unit 5 recomposes) ---------------
# Phase 3 INCOMPLETE while the cycle is already inscribed must not read as
# "re-run unit 5": a recompose changes dag_root_computed and would replace the
# pre-image that was signed.
ST_ORDER="${TMP}/status-order"
rm -rf "$ST_ORDER"
cp -R "$STATUS_OK" "$ST_ORDER"
printf '\n' >> "${ST_ORDER}/anchor-local.json"
run_status "${TMP}/status-order.txt" "$ST_N" \
	"--public-base=${ST_ORDER}/pub" "--anchor-source-local=${ST_ORDER}/anchor-local.json" \
	"--tx-json=${ST_ORDER}/tx.json" "--gate-state=${ST_ORDER}/gate.json"
if [ "$(verdict_of "${TMP}/status-order.txt" 3)" = "INCOMPLETE" ] &&
	[ "$(verdict_of "${TMP}/status-order.txt" 5)" = "COMPLETE" ]; then
	if grep -q 'STOP before unit 5' "${TMP}/status-order.txt"; then
		ok "phase 3's unit list carries a stop-order warning when the cycle is already inscribed"
	else
		bad "phase 3 advised re-running unit 5 after inscription with no warning — a recompose would replace the signed pre-image"
	fi
else
	bad "the ordering fixture did not produce phase 3 INCOMPLETE + phase 5 COMPLETE"
fi
# ...and the warning must not fire when re-composing is genuinely safe.
ST_ORDER2="${TMP}/status-order2"
rm -rf "$ST_ORDER2"
cp -R "$STATUS_OK" "$ST_ORDER2"
printf '\n' >> "${ST_ORDER2}/anchor-local.json"
make_status_tx "${ST_ORDER2}/tx.json" "fya1c${ST_N}"
run_status "${TMP}/status-order2.txt" "$ST_N" \
	"--public-base=${ST_ORDER2}/pub" "--anchor-source-local=${ST_ORDER2}/anchor-local.json" \
	"--tx-json=${ST_ORDER2}/tx.json" "--gate-state=${ST_ORDER2}/gate.json"
if ! grep -q 'STOP before unit 5' "${TMP}/status-order2.txt"; then
	ok "the stop-order warning stays silent while phase 5 is demonstrably not done (it is a guard, not a banner)"
else
	bad "the stop-order warning fires even when re-composing is safe"
fi

# ---- memo prefix must be matched with its separator ----------------------
# `fya1c4` is a prefix of `fya1c41`, so a bare startswith would let cycle 41's
# memos satisfy a cycle-4 reading the first time those cycles exist.
ST_COLLIDE="${TMP}/status-collide"
rm -rf "$ST_COLLIDE"
cp -R "$STATUS_OK" "$ST_COLLIDE"
make_status_tx "${ST_COLLIDE}/tx.json" "fya1c${ST_INSCRIBE}1"
run_status "${TMP}/status-collide.txt" "$ST_N" \
	"--public-base=${ST_COLLIDE}/pub" "--anchor-source-local=${ST_COLLIDE}/anchor-local.json" \
	"--tx-json=${ST_COLLIDE}/tx.json" "--gate-state=${ST_COLLIDE}/gate.json"
if [ "$(verdict_of "${TMP}/status-collide.txt" 5)" = "INCOMPLETE" ]; then
	ok "a memo prefix that merely EXTENDS the expected one (fya1c${ST_INSCRIBE}1 vs fya1c${ST_INSCRIBE}) does not satisfy phase 5"
else
	bad "PREFIX COLLISION: cycle ${ST_INSCRIBE}1's memos satisfied a cycle-${ST_INSCRIBE} reading"
fi

# ---- an absent field is UNKNOWN, not a verdict about the work ------------
ST_NOCYC="${TMP}/status-nocyc"
rm -rf "$ST_NOCYC"
cp -R "$STATUS_OK" "$ST_NOCYC"
printf '{"schema_version":1,"dag_root_computed":"%s","observations_branch":{}}\n' "$STATUS_DAG" \
	> "${ST_NOCYC}/pub/api/anchor-source.json"
cp "${ST_NOCYC}/pub/api/anchor-source.json" "${ST_NOCYC}/anchor-local.json"
run_status "${TMP}/status-nocyc.txt" "$ST_N" \
	"--public-base=${ST_NOCYC}/pub" "--anchor-source-local=${ST_NOCYC}/anchor-local.json" \
	"--tx-json=${ST_NOCYC}/tx.json" "--gate-state=${ST_NOCYC}/gate.json"
if [ "$(verdict_of "${TMP}/status-nocyc.txt" 3)" = "UNKNOWN" ]; then
	ok "a missing cycle_number_observed reads UNKNOWN (it is a failure to observe, not evidence the compose did not run)"
else
	bad "a missing cycle_number_observed read '$(verdict_of "${TMP}/status-nocyc.txt" 3)', expected UNKNOWN"
fi

# A ledger matching neither accepted state is still exit 68 in this mode.
ST_BAD="${TMP}/status-badledger"
mkdir -p "$ST_BAD"
make_status_pub "${ST_BAD}/pub" 9 "$ST_START" "$ST_START" "$ST_END" "$ST_GEN" "$ST_INSCRIBE"
run_status "${TMP}/status-badledger.txt" "$ST_N" "--public-base=${ST_BAD}/pub" "--gate-state=${TMP}/absent.json"
if [ "$STATUS_RC" -eq 68 ]; then
	ok "--status refuses a ledger that agrees with neither N-1 nor N with exit 68"
else
	bad "--status returned ${STATUS_RC} for a disagreeing ledger, expected 68"
fi

# ===========================================================================
# M. --status has no side effects either — measured, not asserted
# ===========================================================================
# Same tattling-stub method as section E. The claim being tested is narrower
# and stated as such: in local-directory mode --status needs NO outbound
# command at all, and in neither mode does it write, ssh, push or notify.
ST_TATTLE="${TMP}/tattle-status.log"
: > "$ST_TATTLE"
STUBDIR2="${TMP}/stubs-status"
mkdir -p "$STUBDIR2"
for c in ssh scp curl wget rsync git ntfy mail sendmail; do
	printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$c" "$ST_TATTLE" > "${STUBDIR2}/${c}"
	chmod +x "${STUBDIR2}/${c}"
done

CANARY2="${TMP}/canary-status"
mkdir -p "$CANARY2/sub"
printf 'original\n' > "$CANARY2/file-a"
printf 'original\n' > "$CANARY2/sub/file-b"
CANARY2_BEFORE="$(snapshot "$CANARY2")"
REPO_BEFORE2="$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | sort)"
FIXTURE_BEFORE="$(snapshot "$STATUS_OK")"

# A FRESH, NEVER-USED HOME. The shared SANDBOX_HOME has already had ~25
# --status runs against it by this point in the suite, so a snapshot taken
# here would be taken AFTER any leak and could only detect writes whose
# CONTENT changes run to run. Review measured exactly that hole: a mutation
# writing a fixed-content $HOME/.fyct-leak passed at PASS=110, while one
# writing changing content was caught. An unused directory removes the
# ordering dependence entirely — anything at all in it afterwards is a leak.
SANDBOX_HOME2="${TMP}/home-untouched"
mkdir -p "$SANDBOX_HOME2"
HOME_BEFORE2="$(snapshot "$SANDBOX_HOME2")"

ST_SIDEFX="${TMP}/status-sidefx.txt"
env PATH="${STUBDIR2}:${PATH}" \
	HOME="$SANDBOX_HOME2" \
	FY_STATE_DIR="${CANARY2}/state" \
	bash "$ORCH" --status --expect-cycle="$ST_N" "${OK_ARGS[@]}" > "$ST_SIDEFX" 2>/dev/null
ST_SIDEFX_RC=$?

if [ "$ST_SIDEFX_RC" -eq 0 ]; then
	ok "--status still reads all five post-conditions with every outbound command stubbed"
else
	bad "--status returned ${ST_SIDEFX_RC} under a stubbed PATH — it depends on an outbound command it should not"
fi
if [ ! -s "$ST_TATTLE" ]; then
	ok "--status against a local --public-base invoked no ssh / scp / curl / wget / rsync / git / notify at all"
else
	bad "--status invoked an outbound command: $(head -3 "$ST_TATTLE" | tr '\n' ';')"
fi
if [ "$(snapshot "$CANARY2")" = "$CANARY2_BEFORE" ]; then
	ok "--status left the canary tree byte-identical"
else
	bad "--status modified the canary tree"
fi
if [ "$(snapshot "$SANDBOX_HOME2")" = "$HOME_BEFORE2" ] && [ -z "$(find "$SANDBOX_HOME2" -mindepth 1 2>/dev/null)" ]; then
	ok "--status wrote nothing into a HOME it had never been pointed at (order-independent, so fixed-content writes are caught too)"
else
	bad "--status wrote into HOME: $(find "$SANDBOX_HOME2" -mindepth 1 2>/dev/null | head -3 | tr '\n' ' ')"
fi
if [ "$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | sort)" = "$REPO_BEFORE2" ]; then
	ok "--status changed nothing in the repository working tree"
else
	bad "--status changed the repository working tree"
fi
if [ "$(snapshot "$STATUS_OK")" = "$FIXTURE_BEFORE" ]; then
	ok "--status left every artifact it READ byte-identical (it is a reader, not a repairer)"
else
	bad "--status modified one of the artifacts it read"
fi
# The private scratch directory is the one thing it writes, and it must not
# outlive the run. Measured in a TMPDIR THIS CHECK OWNS, so the answer depends
# on nothing but the one invocation: an earlier revision scanned the shared
# TMPDIR and went red when six unrelated --status runs executed in parallel
# (review measured that), and before that it went red on a directory a
# mutation run had abandoned. A private TMPDIR removes both, and makes the
# assertion exact rather than probabilistic — anything in it afterwards came
# from this run.
SCRATCH_TMPDIR="${TMP}/scratch-probe"
mkdir -p "$SCRATCH_TMPDIR"
env HOME="$SANDBOX_HOME2" FY_STATE_DIR="${TMP}/no-state-dir" TMPDIR="$SCRATCH_TMPDIR" \
	bash "$ORCH" --status --expect-cycle="$ST_N" "${OK_ARGS[@]}" >/dev/null 2>&1
NEW_SCRATCH="$(find "$SCRATCH_TMPDIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -3 || true)"
if [ -z "$NEW_SCRATCH" ]; then
	ok "--status left its private TMPDIR completely empty (scratch removed, nothing else written)"
else
	bad "--status left a scratch directory behind: $(printf '%s' "$NEW_SCRATCH" | tr '\n' ' ')"
fi

# In URL mode the ONLY outbound command may be a GET. Pointed at a stub, the
# fetches come back empty and every phase falls to UNKNOWN — fail-closed —
# while the tattle log proves nothing but curl was reached for.
: > "$ST_TATTLE"
env PATH="${STUBDIR2}:${PATH}" HOME="$SANDBOX_HOME" FY_STATE_DIR="${CANARY2}/state" \
	bash "$ORCH" --status --expect-cycle="$ST_N" \
	--public-base="https://example.invalid" --gate-state="${TMP}/absent.json" \
	> "${TMP}/status-url.txt" 2>/dev/null
ST_URL_RC=$?
NON_CURL="$(grep -v '^curl ' "$ST_TATTLE" || true)"
if [ -s "$ST_TATTLE" ] && [ -z "$NON_CURL" ]; then
	ok "in URL mode the only outbound command reached for is curl — never ssh, scp, rsync, git or a notifier"
else
	bad "URL mode reached for something other than curl: $(printf '%s' "$NON_CURL" | head -2 | tr '\n' ';')"
fi
if [ "$ST_URL_RC" -eq 70 ]; then
	ok "unreachable feeds make every post-condition UNKNOWN (exit 70), never COMPLETE"
else
	bad "unreachable feeds returned ${ST_URL_RC}, expected 70"
fi

# ===========================================================================
# N. --status usage: the modes do not blur into each other
# ===========================================================================
expect_rc 64 "--status without --expect-cycle is refused with exit 64" -- \
	--status
expect_rc 64 "--ledger is refused with --status (it reads the PUBLISHED ledger)" -- \
	--status --expect-cycle=4 --ledger="$LEDGER_POST"
expect_rc 64 "--testnet-tx-id is refused with --status" -- \
	--status --expect-cycle=4 --testnet-tx-id="$TX64"
expect_rc 64 "--public-base is refused with --print-only" -- \
	--print-only --expect-cycle=4 --ledger="$LEDGER_POST" --public-base=/tmp
expect_rc 64 "--tx-json is refused with --print-only" -- \
	--print-only --expect-cycle=4 --ledger="$LEDGER_POST" --tx-json=/tmp/x.json
expect_rc 64 "asking for both modes at once is refused with exit 64" -- \
	--print-only --status --expect-cycle=4 --ledger="$LEDGER_POST"
expect_rc 64 "no mode at all is refused with exit 64" -- \
	--expect-cycle=4

# ===========================================================================
# O. Actor, and the canon-only checkpoint (the 2026-08-18 three-way audit)
# ===========================================================================
# The audit compared the printed plan, docs/CYCLE_GATE.md and the
# implementations against each other and found the plan silent on things the
# canon requires. Each case below pins one of those, so the plan cannot go
# quiet on it again. `$PLAN` is the un-resolved print; `$PLAN_TX` is the same
# plan with the rehearsal tx supplied, used where the assertion is about a
# command line that only exists resolved.

# flatten — undo the ~68-column comment wrapping, so a phrase can be matched
# whether or not the printer split it across two lines. Every assertion on
# PROSE below goes through this; forgetting it is why three earlier drafts of
# this section reported red against correct output.
flatten() { sed 's/^#[[:space:]]*//' | tr '\n' ' ' | tr -s ' '; }
num_word() {
	case "$1" in
	1) printf 'one' ;; 2) printf 'two' ;; 3) printf 'three' ;;
	4) printf 'four' ;; 5) printf 'five' ;; 6) printf 'six' ;;
	*) printf '%s' "$1" ;;
	esac
}
# The closing self-assessment, isolated once for the several cases that read it.
CLOSING="$(awk '/^# WHERE THIS PLAN IS NOT A COMPLETE SUBSTITUTE/{f=1} f' "$PLAN")"
CLOSING_FLAT="$(printf '%s\n' "$CLOSING" | flatten)"
if [ -n "$CLOSING" ]; then
	ok "the closing self-assessment block was isolated for inspection"
else
	bad "could not isolate the closing self-assessment — the cases reading it would be vacuous"
fi

# --- Actor is printed, closed, and consistent with the machine -------------
# The finding: the plan labelled machines only, so unit 7a — where the
# operator personally starting the script IS the testnet broadcast
# authorization — read exactly like the six other `Mac` lines the AI runs.
ACTORS="$(grep -oE '^# \[unit [^]]+\] (host|Mac) — [^ ]+' "$PLAN" | awk '{print $NF}')"
ACTOR_N="$(printf '%s\n' "$ACTORS" | grep -c . || true)"
if [ "$ACTOR_N" -eq 14 ]; then
	ok "all 14 unit headers name an actor as well as a machine"
else
	bad "expected 14 unit headers carrying an actor, found ${ACTOR_N}"
fi
BAD_ACTOR="$(printf '%s\n' "$ACTORS" | grep -vxE 'AI@host|AI@Mac|operator@TTY' || true)"
if [ -z "$BAD_ACTOR" ]; then
	ok "every actor is one of the canon's three values (AI@host / AI@Mac / operator@TTY)"
else
	bad "unrecognized actor value(s): $(printf '%s' "$BAD_ACTOR" | tr '\n' ' ')"
fi

# The actor's machine suffix must agree with the machine column. Without
# this the two labels could drift apart and each would look self-consistent.
ACTOR_MISMATCH=""
while IFS= read -r hdr; do
	[ -n "$hdr" ] || continue
	h_machine="$(printf '%s' "$hdr" | awk '{print $4}')"
	h_actor="$(printf '%s' "$hdr" | awk '{print $NF}')"
	case "$h_actor" in
	AI@*)
		[ "${h_actor#AI@}" = "$h_machine" ] || ACTOR_MISMATCH="${ACTOR_MISMATCH} ${hdr}"
		;;
	operator@TTY)
		# The operator sits at the Mac; there is no operator@TTY on the host.
		[ "$h_machine" = "Mac" ] || ACTOR_MISMATCH="${ACTOR_MISMATCH} ${hdr}"
		;;
	esac
done < <(grep -oE '^# \[unit [^]]+\] (host|Mac) — [^ ]+' "$PLAN")
if [ -z "$ACTOR_MISMATCH" ]; then
	ok "every actor's machine agrees with the unit's machine column"
else
	bad "actor / machine disagreement:${ACTOR_MISMATCH}"
fi

# Exactly one unit is the operator's, and it is 7a. Both halves matter: "at
# least one" would pass if every unit were mislabelled operator@TTY, and
# "7a is operator@TTY" would pass if 7b had quietly become one too.
OP_UNITS="$(grep -oE '^# \[unit [^]]+\] (host|Mac) — operator@TTY' "$PLAN" | sed 's/^# \[unit //; s/\].*$//')"
if [ "$OP_UNITS" = "7a" ]; then
	ok "exactly one execution unit is operator@TTY, and it is unit 7a"
else
	bad "expected exactly unit 7a to be operator@TTY, got '$(printf '%s' "$OP_UNITS" | tr '\n' ' ')'"
fi
if unit_block "$PLAN" 7a >/dev/null && \
	awk -v want="# [unit 7a] " 'index($0,want)==1{f=1;next} index($0,"# [unit ")==1{f=0} f' "$PLAN" \
	| grep -qi 'THE OPERATOR HAVING STARTED IT IS THE PER-INVOCATION AUTHORIZATION'; then
	ok "unit 7a states that the operator having started it IS the authorization"
else
	bad "unit 7a does not say why it must be the operator who starts it"
fi

# ---- MUTATION: the actor scan must be able to fail ------------------------
ACTOR_MUT="${TMP}/plan-actor-mut.txt"
sed 's/^# \[unit 7a\] Mac — operator@TTY/# [unit 7a] Mac — AI@Mac/' "$PLAN" > "$ACTOR_MUT"
MUT_OP="$(grep -oE '^# \[unit [^]]+\] (host|Mac) — operator@TTY' "$ACTOR_MUT" | sed 's/^# \[unit //; s/\].*$//')"
if [ "$MUT_OP" != "7a" ]; then
	ok "mutation: relabelling unit 7a as AI@Mac is detected by the operator@TTY check"
else
	bad "MUTATION NOT CAUGHT: unit 7a still read as operator@TTY after being relabelled"
fi

# --- CHECKPOINT 2.5: printed, and still not a unit -------------------------
# The finding: docs/CYCLE_GATE.md step 2.5 (publish the disclosure incident)
# appeared nowhere in the plan — not as a step, and not in the plan's own
# list of what it omits. It is the one step of the day that cannot be
# corrected afterwards, because unit 3 writes the incident count into an
# append-only ledger.
if grep -q '^# ⛔ CHECKPOINT 2\.5 ' "$PLAN"; then
	ok "CHECKPOINT 2.5 is printed in the plan"
else
	bad "CHECKPOINT 2.5 is MISSING from the plan — a day driven from this printout would skip it"
fi
# It must reach the operator WITHOUT joining the unit table: the drift gate
# above demands set equality with the canon's top-level markers, and 2.5 is
# deliberately a sub-block there. A `# [unit 2.5]` header would turn section
# B red on every cycle. This is the constraint that dictated the comment form.
if ! plan_unit_ids "$PLAN" | grep -qxF '2.5'; then
	ok "CHECKPOINT 2.5 is not a unit id, so the drift gate's set equality is untouched"
else
	bad "CHECKPOINT 2.5 became a unit id — the drift gate will now fail against the canon"
fi
# Printed where it is due: after unit 2, before unit 3. Ordering is the whole
# point — read after unit 3 it is already too late to act on.
CP_LINE="$(grep -n '^# ⛔ CHECKPOINT 2\.5 ' "$PLAN" | head -1 | cut -d: -f1)"
U2_LINE="$(grep -n '^# \[unit 2\] ' "$PLAN" | head -1 | cut -d: -f1)"
U3_LINE="$(grep -n '^# \[unit 3\] ' "$PLAN" | head -1 | cut -d: -f1)"
if [ -n "$CP_LINE" ] && [ -n "$U2_LINE" ] && [ -n "$U3_LINE" ] &&
	[ "$CP_LINE" -gt "$U2_LINE" ] && [ "$CP_LINE" -lt "$U3_LINE" ]; then
	ok "CHECKPOINT 2.5 is printed between unit 2 and unit 3, where it is actionable"
else
	bad "CHECKPOINT 2.5 is not positioned between unit 2 and unit 3 (cp=${CP_LINE} u2=${U2_LINE} u3=${U3_LINE})"
fi
# It must be decidable from the printout, not from memory: the tracked
# payload directory is the go/no-go, and the canon is named for the rest.
if grep -q 'docs/pending-disclosures' "$PLAN" && grep -q 'docs/CYCLE_GATE.md step 2.5' "$PLAN"; then
	ok "CHECKPOINT 2.5 names both its go/no-go input and the canonical procedure"
else
	bad "CHECKPOINT 2.5 omits the pending-disclosures input or the canon pointer"
fi

# --- K-2: the plan must not contradict the canon about step 2 --------------
# The plan's own header promises "where the two differ, an inline comment
# says so". That comment said docs/CYCLE_GATE.md step 2 "carries no command
# block at all", which was false — it carries the FY_LIVE=1 line verbatim.
if ! grep -qF 'that step carries no command block at all' "$PLAN"; then
	ok "the plan no longer claims docs/CYCLE_GATE.md step 2 has no command block"
else
	bad "the plan still claims canon step 2 carries no command block — it does (the FY_LIVE=1 line)"
fi
# ...and the claim is checked against the canon rather than merely deleted.
RUNBOOK_STEP2="$(awk '/^2\. \*\*host — .uptime-history/{f=1;next} /^3\. \*\*/{f=0} f' "$RUNBOOK")"
if printf '%s' "$RUNBOOK_STEP2" | grep -qF 'bash scripts/uptime-history.sh'; then
	ok "measured: docs/CYCLE_GATE.md step 2 really does carry a uptime-history.sh command block"
else
	bad "docs/CYCLE_GATE.md step 2 has no uptime-history.sh command block — re-check the plan's note"
fi
# The transition-day false alarm the plan used to drop with it. Matched on a
# short fragment on purpose: the plan wraps prose at ~68 columns, so any
# phrase long enough to be distinctive is also long enough to be split across
# two comment lines and never matched.
U2_BLOCK="$(awk -v want="# [unit 2] " 'index($0,want)==1{f=1;next} index($0,"# [unit ")==1{f=0} f' "$PLAN")"
if printf '%s' "$U2_BLOCK" | grep -qF "Appended daily entry"; then
	ok "unit 2 warns that a second 'Appended daily entry' is the expected boundary signal"
else
	bad "unit 2 omits the same-date duplicate-append note (a transition-day false alarm)"
fi
if printf '%s' "$U2_BLOCK" | grep -qF 'Closed cycle #'; then
	ok "unit 2 names the positive success signal rather than the absence of 'DRY:'"
else
	bad "unit 2 does not name the 'Closed cycle #<N>' success signal"
fi

# --- K-3: ssh-add is printed, at stop 2, as the operator's own action ------
# The finding: the plan described stop 2 as "unit 4 will prompt you", the
# opposite of the canon, where the key is loaded into the agent BEFORE unit 4
# precisely so the AI's non-interactive run of gen-identity.sh does not stop
# at a prompt.
if grep -qE '^ssh-add .*  # Mac$' "$PLAN"; then
	ok "the plan prints the ssh-add line as a command"
else
	bad "the plan does not print ssh-add — the AI's unit 4 would stop at a passphrase prompt"
fi
SSHADD_LINE="$(grep -n '^ssh-add ' "$PLAN" | head -1 | cut -d: -f1)"
U4_LINE="$(grep -n '^# \[unit 4\] ' "$PLAN" | head -1 | cut -d: -f1)"
if [ -n "$SSHADD_LINE" ] && [ -n "$U4_LINE" ] && [ "$SSHADD_LINE" -lt "$U4_LINE" ]; then
	ok "ssh-add is printed BEFORE unit 4, which is the whole point of it"
else
	bad "ssh-add is not printed before unit 4 (ssh-add=${SSHADD_LINE} unit4=${U4_LINE})"
fi
if grep -q 'freedom-yield-operator-identity' "$PLAN"; then
	ok "the ssh-add line names the operator identity key"
else
	bad "the ssh-add line does not name the operator identity key"
fi
# The canon is the source of that path; a drifting copy here would be worse
# than none, so the two are compared rather than trusted.
if grep -qF 'ssh-add ~/.ssh/freedom-yield-operator-identity' "$CYCLE_GATE_DOC"; then
	ok "measured: the ssh-add line matches docs/CYCLE_GATE.md's step 4 前操作 block"
else
	bad "docs/CYCLE_GATE.md no longer carries this ssh-add line — the plan's copy may have drifted"
fi
# The old, inverted model must be gone, not merely supplemented.
if ! grep -qF 'Unit 4 prompts for the operator identity key passphrase' "$PLAN"; then
	ok "the superseded \"unit 4 will prompt you\" model is no longer printed"
else
	bad "stop 2 still describes unit 4 as prompting, which inverts the canon's model"
fi

# --- K-6: step 3 is verifiable, because a baseline is taken ----------------
# "grew by exactly one line" is a claim about a difference; the plan printed
# only the after-reading, so nothing in it could support the claim.
LEDGER_READS="$(grep -c "^curl -fsS 'https://metal.freedom-yield.com/api/cycle-history.jsonl'" "$PLAN" || true)"
if [ "$LEDGER_READS" -eq 2 ]; then
	ok "unit 3 prints two published-ledger readings (a baseline and an after)"
else
	bad "expected 2 published-ledger readings in unit 3, found ${LEDGER_READS}"
fi
# The baseline is worthless unless it is taken BEFORE the publish. Anchored
# to the COMMAND line, not to any mention of the script: CHECKPOINT 2.5 also
# names gen-cycle-history.sh in prose (explaining why it must run first), and
# matching that instead put the "publish" earlier than the baseline.
GEN_HIST_LINE="$(grep -n '^ssh .*gen-cycle-history\.sh' "$PLAN" | head -1 | cut -d: -f1)"
FIRST_READ="$(grep -n "^curl -fsS 'https://metal.freedom-yield.com/api/cycle-history.jsonl'" "$PLAN" | head -1 | cut -d: -f1)"
LAST_READ="$(grep -n "^curl -fsS 'https://metal.freedom-yield.com/api/cycle-history.jsonl'" "$PLAN" | tail -1 | cut -d: -f1)"
if [ -n "$GEN_HIST_LINE" ] && [ "$FIRST_READ" -lt "$GEN_HIST_LINE" ] && [ "$LAST_READ" -gt "$GEN_HIST_LINE" ]; then
	ok "one ledger reading is taken before the publish and one after it"
else
	bad "the ledger readings do not straddle the publish (first=${FIRST_READ} publish=${GEN_HIST_LINE} last=${LAST_READ})"
fi
# Both readings must COUNT THE SAME WAY, or the difference is meaningless.
UNIQ_READS="$(grep "^curl -fsS 'https://metal.freedom-yield.com/api/cycle-history.jsonl'" "$PLAN" | sort -u | grep -c . || true)"
if [ "$UNIQ_READS" -eq 1 ]; then
	ok "the two ledger readings are the identical command, so their difference is meaningful"
else
	bad "the two ledger readings use ${UNIQ_READS} different commands — the difference would not be comparable"
fi
# The expected before/after pair is stated, not left to the reader.
if grep -qF "Expect $((EXPECT_CYCLE - 1)) here and ${EXPECT_CYCLE} afterwards" "$PLAN"; then
	ok "unit 3 states the expected before/after counts ($((EXPECT_CYCLE - 1)) -> ${EXPECT_CYCLE})"
else
	bad "unit 3 does not state the expected before/after ledger counts"
fi
# The `|| true` trap is disclosed rather than silently carried.
if grep -q 'A READING OF 0 MEANS THE FETCH FAILED' "$PLAN"; then
	ok "unit 3 discloses that a failed fetch also prints 0"
else
	bad "unit 3 does not warn that a failed fetch prints 0 rather than erroring"
fi

# --- K-8: the signing fragment path is pinned, not defaulted ---------------
# sign-anchor-event.sh composes its default output path under
# FY_SIGN_OUTPUT_DIR. With the default in force and that variable exported,
# 7c writes elsewhere while 7.5 scp's the literal /tmp path — shipping the
# previous cycle's fragment, caught only by unit 8, after the broadcast.
SIGN_LINE="$(grep -E '^FY_CONFIG_DIR=.*sign-anchor-event\.sh' "$PLAN_TX" || true)"
if printf '%s' "$SIGN_LINE" | grep -qF -- '--output=/tmp/fya-mainnet-sign-output.json'; then
	ok "unit 7c pins its output path with an explicit --output="
else
	bad "unit 7c does not pin --output= — FY_SIGN_OUTPUT_DIR could relocate the fragment"
fi
# --output= must be a real flag, not a plausible one this plan invented.
if grep -qE '^[[:space:]]*--output=\*\)' "${REPO_ROOT}/scripts/sign-anchor-event.sh"; then
	ok "measured: sign-anchor-event.sh really parses --output="
else
	bad "sign-anchor-event.sh does not parse --output= — the pinned flag would be ignored"
fi
# The pinned path and 7.5's scp source are coupled by string equality alone.
SCP_SRC="$(grep -E '^scp -i .* /tmp/fya-mainnet-sign-output\.json ' "$PLAN_TX" || true)"
if [ -n "$SCP_SRC" ]; then
	ok "unit 7.5 scp's exactly the path unit 7c was pinned to"
else
	bad "unit 7.5's scp source does not match unit 7c's --output= path"
fi
if grep -q 'MUST BE THE SAME STRING AS UNIT 7c' "$PLAN"; then
	ok "unit 7.5 states that its literal source path is coupled to 7c's --output="
else
	bad "unit 7.5 does not disclose the coupling to 7c's output path"
fi

# --- The 7c hardening must not be cancelled by "prefer 7b's line" ----------
# preview-cycle-anchor-broadcast.sh prints its own rendering of the 7c
# command, and that rendering has neither --output= nor an absolute
# FY_CONFIG_DIR — it is the home-relative form the canon warns about at
# length. Telling the operator to prefer it undoes both fixes on this line,
# so the plan has to send them for the VALUES and keep them on the printed
# command. Measured against the real script, not assumed.
PREVIEW_SH="${REPO_ROOT}/scripts/preview-cycle-anchor-broadcast.sh"
PREVIEW_7C="$(sed -n '/^ *bash scripts\/sign-anchor-event.sh/,/dry-run-log/p' "$PREVIEW_SH")"
if [ -n "$PREVIEW_7C" ] && ! printf '%s' "$PREVIEW_7C" | grep -qF -- '--output='; then
	ok "measured: unit 7b's printed 7c command really does omit --output="
else
	bad "unit 7b's printed 7c command now carries --output= — the plan's warning may be stale"
fi
if grep -qF 'FY_CONFIG_DIR=\$HOME/.fy-mainnet-broadcast/config' "$PREVIEW_SH"; then
	ok "measured: unit 7b's printed 7c command really does write FY_CONFIG_DIR home-relative"
else
	bad "unit 7b's printed 7c command no longer writes FY_CONFIG_DIR home-relative — re-check the plan's warning"
fi
# Neither unit may tell the reader to prefer that rendering wholesale.
U7B_FLAT="$(awk -v want="# [unit 7b] " 'index($0,want)==1{f=1;next} index($0,"# [unit ")==1{f=0} f' "$PLAN" | flatten)"
U7C_FLAT="$(awk -v want="# [unit 7c] " 'index($0,want)==1{f=1;next} index($0,"# [unit ")==1{f=0} f' "$PLAN" | flatten)"
STALE=""
printf '%s' "$U7B_FLAT" | grep -qiF 'prefer ITS output over the line printed below' && STALE="${STALE} 7b"
printf '%s' "$U7C_FLAT" | grep -qiF 'that printed form is the one to prefer' && STALE="${STALE} 7c"
if [ -z "$STALE" ]; then
	ok "no unit tells the operator to prefer unit 7b's rendering of the 7c command"
else
	bad "unit(s)${STALE} still recommend pasting 7b's 7c line, which drops --output= and the absolute FY_CONFIG_DIR"
fi
# ...and both must say what to take from 7b instead: the values.
if printf '%s' "$U7B_FLAT" | grep -qiF 'TAKE THE VALUES FROM IT, NOT THE LINE'; then
	ok "unit 7b directs the reader to take the values from its output, not the command line"
else
	bad "unit 7b does not distinguish taking 7b's VALUES from pasting 7b's command"
fi
if printf '%s' "$U7C_FLAT" | grep -qiF 'copy them from there INTO THE LINE BELOW'; then
	ok "unit 7c says to copy the gate args into the printed line rather than replace it"
else
	bad "unit 7c does not say to copy 7b's gate args into this line"
fi
if printf '%s' "$U7C_FLAT" | grep -qiF 'home-relative'; then
	ok "unit 7c names the home-relative FY_CONFIG_DIR trap it closes"
else
	bad "unit 7c does not name the trap that makes its line differ from 7b's"
fi

# --- F4: the day's pauses are counted, and the checkpoint is one of them ---
# "The four STOP blocks are human actions" read as "there are four places the
# day pauses", which silently excludes CHECKPOINT 2.5 — the one pause that is
# irreversible if missed.
HEADER_FLAT="$(sed -n '/^# HOW TO READ THIS/,/^# ======/p' "$PLAN" | flatten)"
if printf '%s' "$HEADER_FLAT" | grep -qiF 'FIVE PLACES'; then
	ok "the header counts five pauses, not four, and names the checkpoint as the fifth"
else
	bad "the header still counts only the four STOP blocks as the day's pauses"
fi

# --- K-5: unit 4b quotes the canon's whole list ----------------------------
# The plan called its 4b checklist a verbatim quote while carrying three of
# the canon's bullets. The two that were missing are the CHECKPOINT 2.5
# follow-ups, and one of them is the only item on the list no exit code
# covers.
CANON_4B="$(awk '/^4b\. \*\*Mac —/{f=1;next} /^5\. \*\*/{f=0} f' "$RUNBOOK")"
CANON_4B_BULLETS="$(printf '%s\n' "$CANON_4B" | grep -cE '^   - ' || true)"
B4_BLOCK="$(awk -v want="# [unit 4b] " 'index($0,want)==1{f=1;next} index($0,"# [unit ")==1{f=0} f' "$PLAN")"
PLAN_4B_BULLETS="$(printf '%s\n' "$B4_BLOCK" | grep -cE '^#     \([a-e]\) ' || true)"
if [ "$CANON_4B_BULLETS" -ge 4 ]; then
	ok "measured: docs/CYCLE_GATE.md step 4b carries ${CANON_4B_BULLETS} bullets"
else
	bad "docs/CYCLE_GATE.md step 4b's bullet list read as only ${CANON_4B_BULLETS} bullets — the comparison below would be vacuous"
fi
# NOT equality, and the asymmetry is deliberate rather than a loosened test.
# The failure this guards against is the plan carrying FEWER items than the
# canon: that is how a mandatory edit gets dropped on the day. The plan
# carrying more is not the same kind of defect — an extra caution in a
# printout costs a few seconds of reading, and forbidding it would make this
# suite go red for exactly as long as it takes a canon edit and a plan edit
# to reach main, i.e. it would manufacture the "known red we ignore" state
# this repo has already paid for once.
if [ "$PLAN_4B_BULLETS" -ge "$CANON_4B_BULLETS" ]; then
	ok "unit 4b prints ${PLAN_4B_BULLETS} bullets, covering the canon's ${CANON_4B_BULLETS}"
else
	bad "unit 4b prints only ${PLAN_4B_BULLETS} bullets but docs/CYCLE_GATE.md step 4b carries ${CANON_4B_BULLETS} — a mandatory edit would be dropped"
fi
# Counting alone would pass on three right bullets and two invented ones, so
# the two that were actually missing are named.
if printf '%s' "$B4_BLOCK" | grep -qF 'incidents_json.sha256' &&
	printf '%s' "$B4_BLOCK" | grep -qF 'OBSOLETE-BASELINE'; then
	ok "unit 4b carries the temporary-baseline bullet and names the report-only signal for it"
else
	bad "unit 4b omits the temporary incidents_json.sha256 baseline bullet"
fi
# The published payload IS deleted — but in checkpoint 2.5's own commit, not
# in 4b's. Deferring it to 4b was measured to leave ci-main.yml red for the
# hours between the 2.5 push and unit 4, so the deletion travels with the
# publish. The plan has to place it where the canon does, or the operator
# stages it in the wrong commit.
if printf '%s' "$B4_BLOCK" | grep -qF 'docs/pending-disclosures'; then
	bad "unit 4b claims the pending payload is deleted here — the canon deletes it in checkpoint 2.5's own commit"
else
	ok "unit 4b does not claim the pending-payload deletion (it belongs to checkpoint 2.5's commit)"
fi
# Range-extracted from its header to the rule that closes it. Matched on
# single words, because the plan re-wraps prose at ~68 columns and any phrase
# worth asserting on is long enough to be split across two comment lines.
CP_BLOCK="$(sed -n '/^# ⛔ CHECKPOINT 2\.5 /,/^# ----------/p' "$PLAN")"
if [ -z "$CP_BLOCK" ]; then
	bad "could not isolate the CHECKPOINT 2.5 block — the assertions below would be vacuous"
elif printf '%s\n' "$CP_BLOCK" | grep -qF 'DELETION' &&
	printf '%s\n' "$CP_BLOCK" | grep -qF 'pending payload'; then
	ok "CHECKPOINT 2.5 states that its own commit carries the pending-payload deletion"
else
	bad "CHECKPOINT 2.5 does not say the pending payload is deleted in its commit"
fi
# 4b's staged set must therefore stay at the four always-staged files.
if printf '%s\n' "$B4_BLOCK" | grep -qF 'FOUR entries'; then
	ok "unit 4b states that its staged set is four files, on a 2.5 cycle as well"
else
	bad "unit 4b does not state the expected staged set"
fi
# And the bullet that no exit code covers must be flagged as such.
if printf '%s' "$B4_BLOCK" | grep -qF 'DOES NOT CHANGE THE EXIT CODE'; then
	ok "unit 4b flags the one bullet CI cannot fail on"
else
	bad "unit 4b does not distinguish the bullet CI cannot fail on from the ones it can"
fi

# --- Every count the plan states about 4b must match the bullets it printed --
# The plan said "two of its five bullets" in the closing summary while unit 4b
# itself said four, and the truth was four with ONE conditional. Prose counts
# in this repo have been wrong repeatedly ("4 lines" for 11, "5 places" for
# 6), so they are derived here and compared rather than read.
B4_COND="$(printf '%s\n' "$B4_BLOCK" | grep -cF 'ONLY IF CHECKPOINT 2.5' || true)"
if [ "$B4_COND" -ge 1 ]; then
	ok "measured: ${B4_COND} of unit 4b's ${PLAN_4B_BULLETS} bullets are marked CHECKPOINT-2.5-conditional"
else
	bad "no unit 4b bullet is marked CHECKPOINT-2.5-conditional — the counts below would be vacuous"
fi
B4_FLAT="$(printf '%s\n' "$B4_BLOCK" | flatten)"
# Unit 4b's own header count.
if printf '%s' "$B4_FLAT" | grep -qiF "carries $(num_word "$PLAN_4B_BULLETS") bullets"; then
	ok "unit 4b's header states the number of bullets it actually prints ($(num_word "$PLAN_4B_BULLETS"))"
else
	bad "unit 4b's header does not say 'carries $(num_word "$PLAN_4B_BULLETS") bullets' — it printed ${PLAN_4B_BULLETS}"
fi
# The closing summary's count of the same list, which is where they diverged.
if printf '%s' "$CLOSING_FLAT" | grep -qiF "$(num_word "$B4_COND") of its $(num_word "$PLAN_4B_BULLETS") bullets"; then
	ok "the closing summary agrees: $(num_word "$B4_COND") of $(num_word "$PLAN_4B_BULLETS") bullets is conditional"
else
	bad "the closing summary's 4b count disagrees with the plan: it printed ${PLAN_4B_BULLETS} bullets, ${B4_COND} of them conditional"
fi
# Cheap, and it is the exact wrong number that shipped.
if printf '%s' "$CLOSING_FLAT" | grep -qiF 'five bullets'; then
	bad "the closing summary still says 'five bullets' — unit 4b prints ${PLAN_4B_BULLETS}"
else
	ok "the closing summary no longer claims five 4b bullets"
fi

# --- K-7: both keystores are re-locked, and the plan says so ---------------
# The canon requires two re-locks and its own completion checklist calls
# closing only one "the likeliest omission of the day". The plan's stop 4
# mentioned only the mainnet keystore.
STOP4="$(awk '/^# ⏸ STOP 4 /{f=1;next} /^# === PHASE/{f=0} f' "$PLAN")"
if printf '%s' "$STOP4" | grep -qi 'TESTNET keystore' &&
	printf '%s' "$STOP4" | grep -qi 're-lock BOTH keystores'; then
	ok "stop 4 requires re-locking BOTH keystores, not only the mainnet one"
else
	bad "stop 4 does not require re-locking the testnet keystore as well"
fi
# The plan's own count of the operator's keystrokes must match the canon's.
if grep -qF 'Counting the operator' "$PLAN" && grep -qF 'the whole day: SIX' "$PLAN"; then
	ok "the plan counts six operator@TTY actions, matching the canon"
else
	bad "the plan does not count the operator's six manual actions"
fi
# Checked against what the canon REQUIRES, not against its prose count. The
# count sentence has itself been wrong (it said five while three other
# passages demanded six), so pinning the plan to that sentence would pin it to
# whichever of the two the canon happens to be asserting today. The
# requirement is stable and is what the operator is actually measured against:
# the completion checklist demands both keystores locked.
if grep -qF 'keystore が 2 つとも locked' "$CYCLE_GATE_DOC"; then
	ok "measured: docs/CYCLE_GATE.md's completion checklist requires BOTH keystores locked"
else
	bad "docs/CYCLE_GATE.md no longer requires both keystores locked — re-check stop 4"
fi

# --- The plan still discloses what it omits --------------------------------
# The closing summary is the reader's map of where the printout stops being a
# faithful copy. It has to mention the checkpoint it summarises rather than
# reproduces, or the omission is undisclosed all over again.
if printf '%s' "$CLOSING" | grep -qF 'CHECKPOINT 2.5'; then
	ok "the closing summary discloses that CHECKPOINT 2.5 is summarised, not reproduced"
else
	bad "the closing summary does not mention CHECKPOINT 2.5"
fi
if printf '%s' "$CLOSING" | grep -qF 'TWO RE-LOCKS'; then
	ok "the closing summary names both unprinted re-locks, not one"
else
	bad "the closing summary still describes a single unprinted re-lock"
fi

finish
