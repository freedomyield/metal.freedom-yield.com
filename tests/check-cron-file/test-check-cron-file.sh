#!/usr/bin/env bash
# test-check-cron-file.sh — suite for scripts/check-cron-file.sh, the
# /etc/cron.d/metal-* pre-flight linter. Previously had no dedicated unit
# test (only exercised indirectly via installer suites).
#
# Focus: Rule 1's 2026-07-08 rework (R3). The original Rule 1 failed EVERY
# `>> /var/log/...` redirect unconditionally — right for a brand-new entry
# (the 2026-06-19 metal-evidence failure mode) but a false positive for the
# handful of /var/log/ crons scripts/vps-bootstrap.sh pre-provisions itself
# (touch + chown deploy:deploy before the cron ever fires). Rule 1 now passes
# a /var/log/ target that is either verified deploy-owned on this machine, or
# whose basename is on the known-good allowlist.
#
# CHAIN: none — pure file linting, no cron/system state touched.
#
# Usage:
#   bash tests/check-cron-file/test-check-cron-file.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-cron-file.sh"

if [ ! -f "$CHECKER" ]; then
	echo "FATAL: checker not found at $CHECKER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

DIR=""
setup()    { DIR="$(mktemp -d -t check-cron-file-test.XXXXXX)"; }
teardown() { rm -rf "$DIR"; DIR=""; }

# ---- case 1: usage error — no arg -----------------------------------------------------
bash "$CHECKER" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "no arg: exit 2" \
	|| bad "no arg: exit 2 (actual=$RC)"

# ---- case 2: usage error — file not found ----------------------------------------------
bash "$CHECKER" /nonexistent/path/does-not-exist >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "missing file: exit 2" \
	|| bad "missing file: exit 2 (actual=$RC)"

# ---- case 3: fully-compliant file → 0 violations ----------------------------------------
setup
cat > "$DIR/good" <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 5 * * * deploy { echo "=== x start \$(date -u +\%FT\%TZ) ==="; cd /home/deploy/metal.freedom-yield.com && bash scripts/x.sh; rc=\$?; echo "=== x end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /home/deploy/metal.freedom-yield.com/logs/x.log 2>&1
EOF
bash "$CHECKER" "$DIR/good" >/tmp/good_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "compliant file: exit 0" \
	|| bad "compliant file: exit 0 (actual=$RC)"
grep -q 'Result: 0 violation' /tmp/good_out.txt \
	&& ok "compliant file: 0 violations reported" \
	|| bad "compliant file: 0 violations reported"
teardown

# ---- case 4 (Rule 1, R3): unallowlisted /var/log/ target → FAIL -------------------------
setup
cat > "$DIR/bad-varlog" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * deploy echo hi >> /var/log/some-brand-new-name.log 2>&1
EOF
bash "$CHECKER" "$DIR/bad-varlog" >/tmp/bad_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "unallowlisted /var/log/: exit 1" \
	|| bad "unallowlisted /var/log/: exit 1 (actual=$RC)"
grep -qF 'FAIL: uses >> /var/log/some-brand-new-name.log' /tmp/bad_out.txt \
	&& ok "unallowlisted /var/log/: Rule 1 fails with the target named" \
	|| bad "unallowlisted /var/log/: Rule 1 fails with the target named"
teardown

# ---- case 5 (Rule 1, R3): allowlisted basename, absent locally → PASS -------------------
setup
cat > "$DIR/allowlisted" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash scripts/node-info.sh >> /var/log/node-info.log 2>&1
EOF
bash "$CHECKER" "$DIR/allowlisted" >/tmp/allow_out.txt 2>&1
grep -qF 'allowlisted: /var/log/node-info.log' /tmp/allow_out.txt \
	&& ok "allowlisted /var/log/ basename: Rule 1 passes" \
	|| bad "allowlisted /var/log/ basename: Rule 1 passes (out: $(cat /tmp/allow_out.txt))"
teardown

# ---- case 6 (Rule 1, R3): project-local logs/ path is unaffected ------------------------
setup
cat > "$DIR/local" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/x.sh >> /home/deploy/metal.freedom-yield.com/logs/x.log 2>&1
EOF
bash "$CHECKER" "$DIR/local" >/tmp/local_out.txt 2>&1
grep -qF 'no /var/log/ redirect.' /tmp/local_out.txt \
	&& ok "project-local logs/: Rule 1 reports no /var/log/ redirect" \
	|| bad "project-local logs/: Rule 1 reports no /var/log/ redirect"
teardown

# ---- case 7 (Rule 1, R3): existing file on this machine, owned by invoking user ---------
# (not "deploy") under a fabricated /var/log-shaped target is impossible to
# construct without root, so this only exercises the negative path already
# covered by case 4. Documented here rather than faked to avoid a misleading
# green that doesn't actually exercise the deploy-ownership branch.

# ---- case 8: Rule 2 — un-braced chain with && and >> still fails ------------------------
setup
cat > "$DIR/no-brace" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 5 * * * deploy cd /home/deploy/metal.freedom-yield.com && bash scripts/x.sh >> /home/deploy/metal.freedom-yield.com/logs/x.log 2>&1
EOF
bash "$CHECKER" "$DIR/no-brace" >/tmp/nobrace_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 2 still enforced: un-braced chain fails" \
	|| bad "Rule 2 still enforced: un-braced chain fails (actual=$RC)"
teardown

# ---- case 8b (Rule 2, 2026-08-07 widening): un-braced chain piped to another
# command — `A && B 2>&1 | logger` — must fail too. Before the widening this
# was INVISIBLE to Rule 2 (it only inspected lines containing `>>`) and the
# real TOOLKIT.md peer-validators sample shipped in exactly this shape with
# 4 of 6 output streams silently dropped while the linter reported clean.
# scripts/foo.sh / bar.sh are placeholders that exist nowhere in this repo,
# so Rule 6 cannot resolve them (fail-open there by design) and this case
# isolates Rule 2.
setup
cat > "$DIR/pipe-no-brace-2cmd" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash scripts/foo.sh && bash scripts/bar.sh 2>&1 | logger -t tag
EOF
bash "$CHECKER" "$DIR/pipe-no-brace-2cmd" >/tmp/pipe2_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 2 widened: un-braced 2-command chain piped to logger fails" \
	|| bad "Rule 2 widened: un-braced 2-command chain piped to logger fails (actual=$RC, out: $(cat /tmp/pipe2_out.txt))"
grep -qF 'found a chain that redirects only the last command' /tmp/pipe2_out.txt \
	&& ok "Rule 2 widened: violation carries the Rule 2 message" \
	|| bad "Rule 2 widened: violation carries the Rule 2 message (out: $(cat /tmp/pipe2_out.txt))"
teardown

# ---- case 8c (Rule 2, widening): 3-command chain piped to logger — the
# EXACT shape that shipped in TOOLKIT.md's old peer-validators sample line
# (measured: 2 of 6 streams reached the tag, 4 were dropped) — must fail.
setup
cat > "$DIR/pipe-no-brace-3cmd" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 4 * * * deploy bash scripts/foo.sh && bash scripts/bar.sh && bash scripts/baz.sh 2>&1 | logger -t tag
EOF
bash "$CHECKER" "$DIR/pipe-no-brace-3cmd" >/tmp/pipe3_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 2 widened: un-braced 3-command chain piped to logger fails" \
	|| bad "Rule 2 widened: un-braced 3-command chain piped to logger fails (actual=$RC, out: $(cat /tmp/pipe3_out.txt))"
teardown

# ---- case 8d (Rule 2, widening): un-braced chain with a bare `>` (not `>>`)
# truncating redirect on the last command only — must fail. Previously Rule 2
# only looked for `>>`, so a single `>` chain-scoping bug was invisible too.
setup
cat > "$DIR/single-gt-no-brace" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 4 * * * deploy bash scripts/foo.sh && bash scripts/bar.sh > /tmp/x.log 2>&1
EOF
bash "$CHECKER" "$DIR/single-gt-no-brace" >/tmp/singlegt_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 2 widened: un-braced chain with a bare > redirect fails" \
	|| bad "Rule 2 widened: un-braced chain with a bare > redirect fails (actual=$RC, out: $(cat /tmp/singlegt_out.txt))"
teardown

# ---- case 8e (Rule 2, widening — no false positive): `{ A && B ; } 2>&1 | logger`
# is the CORRECT wrapped form of the pipe shape and must pass Rule 2.
setup
cat > "$DIR/braced-pipe" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy { bash scripts/foo.sh && bash scripts/bar.sh ; } 2>&1 | logger -t tag
EOF
bash "$CHECKER" "$DIR/braced-pipe" >/tmp/bracedpipe_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 2 widened: braced chain piped to logger passes (no false positive)" \
	|| bad "Rule 2 widened: braced chain piped to logger passes (actual=$RC, out: $(cat /tmp/bracedpipe_out.txt))"
teardown

# ---- case 8f (Rule 2, widening — no false positive): bash -c "A && B" 2>&1 | logger
# is the real production shape of freedom-yield-peer-geo (the one cron with
# no repo installer of its own). The && is inside bash -c's own quoted
# argument, not a top-level cron-line chain, so the outer pipe correctly
# scopes the whole bash -c invocation — must pass Rule 2.
setup
cat > "$DIR/bash-c-pipe" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 6 * * * deploy bash -c "cd /home/deploy/metal.freedom-yield.com && python3 scripts/foo.py && bash scripts/bar.sh" 2>&1 | logger -t peer-geo
EOF
bash "$CHECKER" "$DIR/bash-c-pipe" >/tmp/bashcpipe_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 2 widened: bash -c \"A && B\" 2>&1 | logger passes (no false positive)" \
	|| bad "Rule 2 widened: bash -c \"A && B\" 2>&1 | logger passes (actual=$RC, out: $(cat /tmp/bashcpipe_out.txt))"
teardown

# ---- case 8g (Rule 2, widening — no false positive): a single command
# piped to logger, no chain at all — must pass. This is the shape most
# read-only crons already use; the widening must not touch it.
setup
cat > "$DIR/single-cmd-pipe" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash scripts/foo.sh 2>&1 | logger -t tag
EOF
bash "$CHECKER" "$DIR/single-cmd-pipe" >/tmp/singlecmdpipe_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 2 widened: single command piped to logger passes (no chain, no false positive)" \
	|| bad "Rule 2 widened: single command piped to logger passes (actual=$RC, out: $(cat /tmp/singlecmdpipe_out.txt))"
teardown

# ---- case 8h (Rule 2, pass-message honesty): the compliant-file fixture
# from case 3 (a braced && chain with a >> redirect) must still report Rule 2
# as explicitly checked and passing — not the pre-2026-08-07 message that
# claimed to check a shape (pipes) it never inspected.
setup
cat > "$DIR/good-for-msg" <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 5 * * * deploy { echo "=== x start \$(date -u +\%FT\%TZ) ==="; cd /home/deploy/metal.freedom-yield.com && bash scripts/x.sh; rc=\$?; echo "=== x end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /home/deploy/metal.freedom-yield.com/logs/x.log 2>&1
EOF
bash "$CHECKER" "$DIR/good-for-msg" >/tmp/goodmsg_out.txt 2>&1
grep -qF 'every && chain with a redirect or pipe wraps it in { ... }' /tmp/goodmsg_out.txt \
	&& ok "Rule 2 pass message states what was actually checked (redirect AND pipe)" \
	|| bad "Rule 2 pass message states what was actually checked (out: $(cat /tmp/goodmsg_out.txt))"
teardown

# ---- case 8i (mutation control): prove the 2026-08-07 widening — not
# something else — is what makes cases 8b/8c/8d fail. old_rule2_flags_violation
# below is a self-contained, byte-for-byte reproduction of Rule 2's PRE-WIDEN
# trigger condition (a line needs BOTH a literal `&&` AND a literal `>>` to
# even be inspected — this is the exact code that shipped before this task).
# It must report "not flagged" for all three broken fixtures — i.e. reverting
# the widening really does make them slip through silently, which is the
# defect this task exists to close. This does not re-test the CURRENT
# checker (cases 8b/8c/8d already did, via the real scripts/check-cron-file.sh);
# it isolates that the widening specifically is the responsible change.
old_rule2_flags_violation() {
	local file="$1" cron_lines any
	cron_lines="$(grep -vE '^\s*(#|$)' "$file" | grep -vE '^[A-Z_]+=' || true)"
	any=0
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		if ! printf '%s' "$line" | grep -q '&&'; then continue; fi
		if ! printf '%s' "$line" | grep -q '>>'; then continue; fi
		if ! printf '%s' "$line" | grep -qE '\{[^}]*&&[^{]*\}\s*>>'; then
			any=1
		fi
	done <<< "$cron_lines"
	[ "$any" -eq 1 ]
}

setup
cat > "$DIR/mut-2cmd" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash scripts/foo.sh && bash scripts/bar.sh 2>&1 | logger -t tag
EOF
cat > "$DIR/mut-3cmd" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 4 * * * deploy bash scripts/foo.sh && bash scripts/bar.sh && bash scripts/baz.sh 2>&1 | logger -t tag
EOF
cat > "$DIR/mut-single-gt" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 4 * * * deploy bash scripts/foo.sh && bash scripts/bar.sh > /tmp/x.log 2>&1
EOF
old_rule2_flags_violation "$DIR/mut-2cmd" \
	&& bad "mutation control: pre-widen Rule 2 does NOT catch the 2-cmd pipe chain (it did — regression in the control itself)" \
	|| ok "mutation control: pre-widen Rule 2 silently passed the 2-cmd pipe chain (confirms the widening is what fixes it)"
old_rule2_flags_violation "$DIR/mut-3cmd" \
	&& bad "mutation control: pre-widen Rule 2 does NOT catch the 3-cmd pipe chain (it did — regression in the control itself)" \
	|| ok "mutation control: pre-widen Rule 2 silently passed the 3-cmd pipe chain (confirms the widening is what fixes it)"
old_rule2_flags_violation "$DIR/mut-single-gt" \
	&& bad "mutation control: pre-widen Rule 2 does NOT catch the bare > chain (it did — regression in the control itself)" \
	|| ok "mutation control: pre-widen Rule 2 silently passed the bare > chain (confirms the widening is what fixes it)"
teardown

# ---- case 8j/8k (Rule 2, F-1 fix, no false positive): a `${VAR}` or a
# literal `}` inside an unquoted argument, appearing AFTER a correctly
# wrapped chain's own closing brace, must not be mistaken for "the end of
# the wrapper". 2026-08-07 review found the first implementation of this
# widening sliced the line with `sed 's/^.*\}//'` (greedy — eats through to
# the LAST `}` in the line, not the chain's own), which lost the real
# `>>`/`|` into the discarded prefix and produced a false violation on a
# correctly-wrapped line. Both must PASS.
setup
cat > "$DIR/f1-logdir" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
LOGDIR=/home/deploy/metal.freedom-yield.com/logs
0 5 * * * deploy { cd /repo && bash a.sh ; } >> ${LOGDIR}/x.log 2>&1
EOF
bash "$CHECKER" "$DIR/f1-logdir" >/tmp/f1logdir_out.txt 2>&1
grep -A2 '^\[2\]' /tmp/f1logdir_out.txt | grep -qF '✓' \
	&& ok "Rule 2 F-1 fix: braced chain followed by \${VAR}/path passes (no false positive)" \
	|| bad "Rule 2 F-1 fix: braced chain followed by \${VAR}/path passes (out: $(cat /tmp/f1logdir_out.txt))"
teardown

setup
cat > "$DIR/f1-tagbrace" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy { cd /repo && bash a.sh ; } 2>&1 | logger -t tag-}x
EOF
bash "$CHECKER" "$DIR/f1-tagbrace" >/tmp/f1tagbrace_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 2 F-1 fix: braced chain followed by an unquoted trailing } passes (no false positive)" \
	|| bad "Rule 2 F-1 fix: braced chain followed by an unquoted trailing } passes (actual=$RC, out: $(cat /tmp/f1tagbrace_out.txt))"
teardown

# ---- case 8l (Rule 2, F-5 gap closed): a `;`-separated, self-contained,
# ALREADY-correctly-wrapped brace group earlier on the line must not make a
# SEPARATE, genuinely unwrapped chain later on the same line look safe. The
# single anchored-regex rewrite (F-1's fix) closed this as a side effect —
# proven directly against the real checker.
setup
cat > "$DIR/f5-disconnected" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 4 * * * deploy { echo a && echo b ; } ; cd /repo && bash x.sh 2>&1 | logger -t t
EOF
bash "$CHECKER" "$DIR/f5-disconnected" >/tmp/f5disc_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 2 F-5 gap closed: an unrelated wrapped group earlier on the line no longer masks a later unwrapped chain" \
	|| bad "Rule 2 F-5 gap closed: an unrelated wrapped group earlier on the line no longer masks a later unwrapped chain (actual=$RC, out: $(cat /tmp/f5disc_out.txt))"
teardown

# ---- case 8m (mutation control, F-1/F-5): byte-for-byte reproduction of the
# intermediate (widened-but-buggy) implementation this review round replaced
# — the match-then-greedy-slice version, NOT the pre-widening version
# case 8i already controls for. Proves the F-1 rewrite (single anchored
# regex, no slice) is specifically what fixes both defects: the control must
# OVER-flag f1-logdir/f1-tagbrace (false positive) and UNDER-flag
# f5-disconnected (false negative) — the exact opposite of what the real
# checker does above.
buggy_two_step_wrapped() {
	local file="$1" cron_lines line unquoted sink_probe after_brace after_brace_probe wrapped any_bad
	cron_lines="$(grep -vE '^\s*(#|$)' "$file" | grep -vE '^[A-Z_]+=' || true)"
	any_bad=0
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		unquoted="$(printf '%s' "$line" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")"
		if ! printf '%s' "$unquoted" | grep -q '&&'; then continue; fi
		sink_probe="$(printf '%s' "$unquoted" | sed -E 's/[0-9]*>&[0-9]+//g')"
		if ! printf '%s' "$sink_probe" | grep -qE '[>|]'; then continue; fi
		wrapped=0
		if printf '%s' "$unquoted" | grep -qE '\{[^}]*&&[^{]*\}'; then
			after_brace="$(printf '%s' "$unquoted" | sed -E 's/^.*\}//')"
			after_brace_probe="$(printf '%s' "$after_brace" | sed -E 's/[0-9]*>&[0-9]+//g')"
			if printf '%s' "$after_brace_probe" | grep -qE '[>|]'; then
				wrapped=1
			fi
		fi
		[ "$wrapped" -eq 0 ] && any_bad=1
	done <<< "$cron_lines"
	[ "$any_bad" -eq 1 ]
}

setup
cat > "$DIR/f1-logdir" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
LOGDIR=/home/deploy/metal.freedom-yield.com/logs
0 5 * * * deploy { cd /repo && bash a.sh ; } >> ${LOGDIR}/x.log 2>&1
EOF
cat > "$DIR/f1-tagbrace" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy { cd /repo && bash a.sh ; } 2>&1 | logger -t tag-}x
EOF
cat > "$DIR/f5-disconnected" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 4 * * * deploy { echo a && echo b ; } ; cd /repo && bash x.sh 2>&1 | logger -t t
EOF
buggy_two_step_wrapped "$DIR/f1-logdir" \
	&& ok "mutation control: match-then-slice implementation DID false-flag \${VAR} (confirms F-1 fix is what's responsible)" \
	|| bad "mutation control: match-then-slice implementation did NOT false-flag \${VAR} (control no longer reproduces F-1 — investigate)"
buggy_two_step_wrapped "$DIR/f1-tagbrace" \
	&& ok "mutation control: match-then-slice implementation DID false-flag the trailing } (confirms F-1 fix is what's responsible)" \
	|| bad "mutation control: match-then-slice implementation did NOT false-flag the trailing } (control no longer reproduces F-1 — investigate)"
buggy_two_step_wrapped "$DIR/f5-disconnected" \
	&& bad "mutation control: match-then-slice implementation caught the disconnected chain (control no longer reproduces F-5 — investigate)" \
	|| ok "mutation control: match-then-slice implementation silently missed the disconnected chain (confirms F-1 fix ALSO closes F-5)"
teardown

# ---- case 9 (Rule 6): allowlisted side-effecting script, no FY_LIVE=1 → FAIL ------------
setup
cat > "$DIR/side-effect-missing" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF
bash "$CHECKER" "$DIR/side-effect-missing" >/tmp/rule6_missing_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 6: side-effecting script without FY_LIVE=1 fails" \
	|| bad "Rule 6: side-effecting script without FY_LIVE=1 fails (actual=$RC)"
grep -qF 'check-host-drift.sh' /tmp/rule6_missing_out.txt \
	&& ok "Rule 6: violation names the side-effecting script" \
	|| bad "Rule 6: violation names the side-effecting script (out: $(cat /tmp/rule6_missing_out.txt))"
teardown

# ---- case 10 (Rule 6): allowlisted side-effecting script, WITH FY_LIVE=1 → PASS ---------
setup
cat > "$DIR/side-effect-present" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF
bash "$CHECKER" "$DIR/side-effect-present" >/tmp/rule6_present_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 6: side-effecting script WITH FY_LIVE=1 passes" \
	|| bad "Rule 6: side-effecting script WITH FY_LIVE=1 passes (actual=$RC, out: $(cat /tmp/rule6_present_out.txt))"
teardown

# ---- case 11 (Rule 6): real but non-side-effecting script, no FY_LIVE=1 → PASS ----------
# server-status.sh exists in this checkout's scripts/ dir, is not on the
# allowlist, and does not source side-effects.sh — the "read-only cron, out
# of scope" case. Otherwise fully rule 1-5 compliant so this case isolates
# Rule 6.
setup
cat > "$DIR/read-only" <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * deploy { echo "=== x start \$(date -u +\%FT\%TZ) ==="; cd /home/deploy/metal.freedom-yield.com && bash scripts/server-status.sh; rc=\$?; echo "=== x end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /home/deploy/metal.freedom-yield.com/logs/server-status.log 2>&1
EOF
bash "$CHECKER" "$DIR/read-only" >/tmp/rule6_readonly_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 6: non-side-effecting real script does not require FY_LIVE=1" \
	|| bad "Rule 6: non-side-effecting real script does not require FY_LIVE=1 (actual=$RC, out: $(cat /tmp/rule6_readonly_out.txt))"
teardown

# ---- case 12 (Rule 6): dynamic layer — a script sourcing side-effects.sh --------------
# but NOT on the static allowlist must still be caught, via FYD_CRON_SCRIPTS_DIR
# pointed at a synthetic scripts/ dir. Proves the "future-proof" detection path.
setup
mkdir -p "$DIR/fakescripts"
cat > "$DIR/fakescripts/migrated-example.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/lib/side-effects.sh"
fyd_notify default "example" "hi"
EOF
cat > "$DIR/dynamic-side-effect" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy bash scripts/migrated-example.sh 2>&1 | logger -t example
EOF
FYD_CRON_SCRIPTS_DIR="$DIR/fakescripts" bash "$CHECKER" "$DIR/dynamic-side-effect" >/tmp/rule6_dynamic_out.txt 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "Rule 6: dynamic detection catches a non-allowlisted lib-sourcing script" \
	|| bad "Rule 6: dynamic detection catches a non-allowlisted lib-sourcing script (actual=$RC, out: $(cat /tmp/rule6_dynamic_out.txt))"
teardown

# ---- case 13 (Rule 6): FYD_CRON_FY_LIVE_GRACE=1 downgrades to a warning ----------------
setup
cat > "$DIR/grace" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift
EOF
FYD_CRON_FY_LIVE_GRACE=1 bash "$CHECKER" "$DIR/grace" >/tmp/rule6_grace_out.txt 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "Rule 6: FYD_CRON_FY_LIVE_GRACE=1 downgrades the miss to non-fatal" \
	|| bad "Rule 6: FYD_CRON_FY_LIVE_GRACE=1 downgrades the miss to non-fatal (actual=$RC)"
grep -qF 'GRACE' /tmp/rule6_grace_out.txt \
	&& ok "Rule 6: grace path is visibly flagged, not silent" \
	|| bad "Rule 6: grace path is visibly flagged, not silent (out: $(cat /tmp/rule6_grace_out.txt))"
teardown

# ---- case 14: KNOWN_SIDE_EFFECT_CRON_BASENAMES stays in sync across both consumers -----
# check-cron-file.sh Rule 6 and install-cron-env-headers.sh duplicate this
# allowlist by design (see both files' comments) — this is the lock-step
# test that catches divergence, mirroring tests/side-effects/'s treatment of
# FYD_PUSH_FILENAME_RE.
ENV_HEADERS="${REPO_ROOT}/scripts/install-cron-env-headers.sh"
LIST_A="$(grep -m1 '^KNOWN_SIDE_EFFECT_CRON_BASENAMES=' "$CHECKER")"
LIST_B="$(grep -m1 '^KNOWN_SIDE_EFFECT_CRON_BASENAMES=' "$ENV_HEADERS")"
[ -n "$LIST_A" ] && [ "$LIST_A" = "$LIST_B" ] \
	&& ok "KNOWN_SIDE_EFFECT_CRON_BASENAMES identical in check-cron-file.sh and install-cron-env-headers.sh" \
	|| bad "KNOWN_SIDE_EFFECT_CRON_BASENAMES identical in check-cron-file.sh and install-cron-env-headers.sh (A: $LIST_A | B: $LIST_B)"

# ---- summary --------------------------------------------------------------------------
echo "test-check-cron-file.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
