#!/usr/bin/env bash
# test-side-effects.sh — regression suite for scripts/lib/side-effects.sh,
# the single opt-in gate for production side effects (C3-1).
#
# CHAIN: none — no case in this suite reaches a broadcast-capable command.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction at all).
#
# Hermeticity, three layers deep (this suite exists BECAUSE the old
# opt-out design let tests reach production):
#   1. Every case points FYD_NOTIFY / FYD_PUSH_TO_WEB_HOST at recording
#      stubs in a mktemp dir, so even a live-mode case cannot reach
#      ntfy.sh or the web host.
#   2. `curl` and `ssh` stubs are prepended to $PATH for the whole suite.
#      If a resolution bug ever routed a call to the REAL notify.sh /
#      push-to-web-host.sh, those two would be the first external binaries
#      touched. Part 8 asserts the tripwire file they write to stayed
#      empty — i.e. proves no case made a network call, rather than
#      assuming it.
#   3. No case writes anywhere but $TMP (no repo file, no /var/lib, no
#      /tmp/fya-* — a 2026-08 accident had a test rm a production file
#      under /tmp).
#
# Mutation coverage (Part 9) — per the C3 design doc's test strategy
# ("新規の不変条件はすべて mutation で実証する"): Parts 2/5 would be
# tautologies if the dry path were never actually exercised. Part 9
# re-runs the same two assertions against a MUTATED library — one where
# fyd_is_live always says "live", one where fyd_dry_note prints nothing —
# and requires them to go red. Because both mutants are applied by
# redefining the single decision function AFTER sourcing, a green Part 9
# also proves the structural invariant that every side effect routes
# through fyd_is_live / fyd_dry_note rather than an inlined copy of the
# check (requirement: the FY_LIVE judgment lives in exactly one place).
#
# Usage:
#   bash tests/side-effects/test-side-effects.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

# SC2016: every `bash -c '… "$LIB" …'` snippet MUST keep $LIB unexpanded so
#         the CHILD shell resolves it from the exported environment; that is
#         the point of the pattern, not an oversight.
# SC2329: cleanup() is invoked indirectly, by the EXIT trap.
# shellcheck disable=SC2016,SC2329

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/side-effects.sh"
PUSH_SCRIPT="${REPO_ROOT}/scripts/push-to-web-host.sh"

if [ ! -r "$LIB" ]; then
	echo "FATAL: expected file missing: $LIB" >&2
	exit 1
fi
if [ ! -r "$PUSH_SCRIPT" ]; then
	echo "FATAL: expected file missing: $PUSH_SCRIPT" >&2
	exit 1
fi

TMP="$(mktemp -d -t side-effects-tests.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

STUB_LOG="${TMP}/stub.log"
TRIPWIRE="${TMP}/tripwire.log"
OUT_FILE="${TMP}/stdout"
ERR_FILE="${TMP}/stderr"
NOTIFY_STUB="${TMP}/notify-stub.sh"
PUSH_STUB="${TMP}/push-stub.sh"
BIN_DIR="${TMP}/bin"
mkdir -p "$BIN_DIR"
: >"$STUB_LOG"
: >"$TRIPWIRE"

# --- recording stubs: log argv + the two env vars the lib must forward ---
# The env vars use ${VAR-…}, NOT ${VAR:-…}: "set to the empty string" and
# "not set at all" are DIFFERENT outcomes here (`--tags=` must be able to
# clear an exported ambient value), and the colon form collapses them.
write_stub() {
	cat >"$1" <<STUB
#!/usr/bin/env bash
{
	printf 'CALL=%s\n' "$2"
	printf 'ARGC=%s\n' "\$#"
	for a in "\$@"; do printf 'ARG=%s\n' "\$a"; done
	printf 'ENV_NTFY_TAGS=%s\n' "\${NTFY_TAGS-<unset>}"
	printf 'ENV_NOTIFY_STRICT_EXIT=%s\n' "\${NOTIFY_STRICT_EXIT-<unset>}"
} >>"\${STUB_LOG:?}"
exit "\${STUB_RC:-0}"
STUB
	chmod +x "$1"
}
write_stub "$NOTIFY_STUB" notify
write_stub "$PUSH_STUB" push

# --- network tripwire (see header, layer 2) ---
for b in curl ssh; do
	cat >"${BIN_DIR}/${b}" <<TRIP
#!/usr/bin/env bash
printf '%s %s\n' "${b}" "\$*" >>"${TRIPWIRE}"
exit 7
TRIP
	chmod +x "${BIN_DIR}/${b}"
done

export PATH="${BIN_DIR}:${PATH}"
export LIB STUB_LOG
export FYD_NOTIFY="$NOTIFY_STUB"
export FYD_PUSH_TO_WEB_HOST="$PUSH_STUB"

PASS=0
FAIL=0

pass() { printf 'PASS  %-72s%s\n' "$1" "${2:+ ($2)}"; PASS=$((PASS + 1)); }
fail_case() { printf 'FAIL  %-72s%s\n' "$1" "${2:+ ($2)}" >&2; FAIL=$((FAIL + 1)); }

# run_case <snippet-run-with-lib-sourced>
#   Caller sets per-case env with an `env VAR=...` prefix. Resets the stub
#   log first so stub-invocation assertions are per-case. Sets RC / OUT / ERR.
run_case() {
	: >"$STUB_LOG"
	RC=0
	bash -c ". \"\$LIB\"; $1" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
	OUT="$(cat "$OUT_FILE")"
	ERR="$(cat "$ERR_FILE")"
}

# stub_calls — how many times a delegate stub was invoked since the last
# reset. grep -c prints 0 AND exits 1 when there is no match, so the count
# is taken from stdout and the exit status is only a fallback (a naive
# `grep -c … || echo 0` prints "0\n0" and breaks every integer comparison).
stub_calls() {
	local n
	n="$(grep -c '^CALL=' "$STUB_LOG" 2>/dev/null | tr -d '[:space:]')" || true
	[ -n "$n" ] || n=0
	printf '%s\n' "$n"
}

# ============================================================
# Part 1: the FY_LIVE judgment (strict literal "1", one place)
# ============================================================

run_case 'for f in fyd_is_live fyd_dry_note fyd_live_run fyd_live_write fyd_notify fyd_push fyd_state_dir; do declare -f "$f" >/dev/null 2>&1 || { echo "missing: $f"; exit 1; }; done'
if [ "$RC" -eq 0 ]; then
	pass "lib: sourcing defines the seven public functions"
else
	fail_case "lib: sourcing defines the seven public functions" "rc=$RC out=[$OUT]"
fi

# 1b-1g. Everything that is not the literal "1" must be dry.
for v in '' '0' 'yes' 'true' 'TRUE' 'on' '11' ' 1' '1 '; do
	: >"$STUB_LOG"
	RC=0
	FY_LIVE="$v" bash -c '. "$LIB"; if fyd_is_live; then echo LIVE; else echo DRY; fi' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
	OUT="$(cat "$OUT_FILE")"
	if [ "$OUT" = "DRY" ]; then
		pass "fyd_is_live: FY_LIVE=[$v] → dry"
	else
		fail_case "fyd_is_live: FY_LIVE=[$v] → dry" "got [$OUT]"
	fi
done

# unset
RC=0
OUT="$(env -u FY_LIVE bash -c '. "$LIB"; if fyd_is_live; then echo LIVE; else echo DRY; fi' 2>/dev/null)" || RC=$?
if [ "$OUT" = "DRY" ]; then
	pass "fyd_is_live: FY_LIVE unset → dry"
else
	fail_case "fyd_is_live: FY_LIVE unset → dry" "got [$OUT]"
fi

# the one live value
RC=0
OUT="$(FY_LIVE=1 bash -c '. "$LIB"; if fyd_is_live; then echo LIVE; else echo DRY; fi' 2>/dev/null)" || RC=$?
if [ "$OUT" = "LIVE" ]; then
	pass "fyd_is_live: FY_LIVE=1 → live"
else
	fail_case "fyd_is_live: FY_LIVE=1 → live" "got [$OUT]"
fi

# ============================================================
# Part 2: fyd_notify — dry is the default, and it is LOUD
# ============================================================

for v in UNSET '' '0' 'yes' 'true'; do
	: >"$STUB_LOG"
	RC=0
	if [ "$v" = UNSET ]; then
		env -u FY_LIVE bash -c '. "$LIB"; fyd_notify high "T" "body words"' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
	else
		FY_LIVE="$v" bash -c '. "$LIB"; fyd_notify high "T" "body words"' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
	fi
	ERR="$(cat "$ERR_FILE")"
	CALLS="$(stub_calls)"
	if [ "$RC" -eq 0 ] && [ "$CALLS" -eq 0 ] && printf '%s' "$ERR" | grep -q '^DRY: would notify '; then
		pass "fyd_notify: FY_LIVE=[$v] → no delegate call, rc 0, stderr 'DRY: would notify'"
	else
		fail_case "fyd_notify: FY_LIVE=[$v] → no delegate call, rc 0, stderr 'DRY: would notify'" "rc=$RC calls=$CALLS err=[$ERR]"
	fi
done

# The DRY line must carry enough to debug a cron that went quiet.
: >"$STUB_LOG"
env -u FY_LIVE bash -c '. "$LIB"; fyd_notify --strict --tags=tada urgent "Title here" "body"' >"$OUT_FILE" 2>"$ERR_FILE"
ERR="$(cat "$ERR_FILE")"
if printf '%s' "$ERR" | grep -q 'prio=urgent' \
	&& printf '%s' "$ERR" | grep -q 'tags=tada' \
	&& printf '%s' "$ERR" | grep -q 'strict=1' \
	&& printf '%s' "$ERR" | grep -q 'Title here' \
	&& printf '%s' "$ERR" | grep -q 'FY_LIVE='; then
	pass "fyd_notify: DRY line names prio/tags/strict/title and the FY_LIVE value"
else
	fail_case "fyd_notify: DRY line names prio/tags/strict/title and the FY_LIVE value" "err=[$ERR]"
fi

# ============================================================
# Part 3: fyd_notify — live delegation (argv + env, verbatim rc)
# ============================================================

: >"$STUB_LOG"
RC=0
FY_LIVE=1 bash -c '. "$LIB"; fyd_notify high "Renewal" "7 days left"' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
if [ "$RC" -eq 0 ] \
	&& [ "$(stub_calls)" -eq 1 ] \
	&& grep -q '^CALL=notify$' "$STUB_LOG" \
	&& grep -q '^ARGC=3$' "$STUB_LOG" \
	&& grep -q '^ARG=high$' "$STUB_LOG" \
	&& grep -q '^ARG=Renewal$' "$STUB_LOG" \
	&& grep -q '^ARG=7 days left$' "$STUB_LOG"; then
	pass "fyd_notify: FY_LIVE=1 → delegate called once with (prio, title, message) verbatim"
else
	fail_case "fyd_notify: FY_LIVE=1 → delegate called once with (prio, title, message) verbatim" "rc=$RC log=[$(cat "$STUB_LOG")]"
fi

# Multi-word message: notify.sh joins "$@" itself, so each word must arrive
# as its own argv element (this is the shape existing callers use).
: >"$STUB_LOG"
FY_LIVE=1 bash -c '. "$LIB"; fyd_notify default "T" one two three' >"$OUT_FILE" 2>"$ERR_FILE"
if grep -q '^ARGC=5$' "$STUB_LOG" && grep -q '^ARG=three$' "$STUB_LOG"; then
	pass "fyd_notify: variadic message words pass through as separate argv elements"
else
	fail_case "fyd_notify: variadic message words pass through as separate argv elements" "log=[$(cat "$STUB_LOG")]"
fi

# --tags / --strict → env forwarded to the delegate.
: >"$STUB_LOG"
FY_LIVE=1 bash -c '. "$LIB"; fyd_notify --tags=tada --strict high "T" "b"' >"$OUT_FILE" 2>"$ERR_FILE"
if grep -q '^ENV_NTFY_TAGS=tada$' "$STUB_LOG" && grep -q '^ENV_NOTIFY_STRICT_EXIT=1$' "$STUB_LOG" \
	&& ! grep -q '^ARG=--tags=tada$' "$STUB_LOG" && ! grep -q '^ARG=--strict$' "$STUB_LOG"; then
	pass "fyd_notify: --tags/--strict become NTFY_TAGS/NOTIFY_STRICT_EXIT, not argv"
else
	fail_case "fyd_notify: --tags/--strict become NTFY_TAGS/NOTIFY_STRICT_EXIT, not argv" "log=[$(cat "$STUB_LOG")]"
fi

# Ambient (non-exported) NTFY_TAGS / NOTIFY_STRICT_EXIT must still reach the
# delegate — that is how existing callers set them, and back-compat is the
# whole point. Set them INSIDE the shell (not exported) so only the lib's
# explicit forwarding can make them visible to the child.
: >"$STUB_LOG"
FY_LIVE=1 bash -c '. "$LIB"; NTFY_TAGS=ambient; NOTIFY_STRICT_EXIT=1; fyd_notify high "T" "b"' >"$OUT_FILE" 2>"$ERR_FILE"
if grep -q '^ENV_NTFY_TAGS=ambient$' "$STUB_LOG" && grep -q '^ENV_NOTIFY_STRICT_EXIT=1$' "$STUB_LOG"; then
	pass "fyd_notify: ambient (non-exported) NTFY_TAGS/NOTIFY_STRICT_EXIT are forwarded"
else
	fail_case "fyd_notify: ambient (non-exported) NTFY_TAGS/NOTIFY_STRICT_EXIT are forwarded" "log=[$(cat "$STUB_LOG")]"
fi

# Explicit flag beats ambient.
: >"$STUB_LOG"
FY_LIVE=1 bash -c '. "$LIB"; NTFY_TAGS=ambient; fyd_notify --tags=flagwins high "T" "b"' >"$OUT_FILE" 2>"$ERR_FILE"
if grep -q '^ENV_NTFY_TAGS=flagwins$' "$STUB_LOG"; then
	pass "fyd_notify: --tags beats an ambient NTFY_TAGS"
else
	fail_case "fyd_notify: --tags beats an ambient NTFY_TAGS" "log=[$(cat "$STUB_LOG")]"
fi

# "explicit wins" has to include an explicit EMPTY value, and the ambient
# variable here is EXPORTED — so the child would inherit it on its own
# unless the lib passes the empty value down deliberately. Without that,
# `--tags=` silently keeps the old tag.
: >"$STUB_LOG"
FY_LIVE=1 NTFY_TAGS=exported bash -c '. "$LIB"; fyd_notify --tags= high "T" "b"' >"$OUT_FILE" 2>"$ERR_FILE"
if grep -q '^ENV_NTFY_TAGS=$' "$STUB_LOG"; then
	pass "fyd_notify: --tags= (explicitly empty) clears an EXPORTED ambient NTFY_TAGS"
else
	fail_case "fyd_notify: --tags= (explicitly empty) clears an EXPORTED ambient NTFY_TAGS" "log=[$(cat "$STUB_LOG")]"
fi

# Exit codes are NOT translated: notify.sh's 2/3/4/5 classification is
# consumed by retryable_notify_rc() in three callers. Renumbering would
# silently turn a retryable 429 into a permanent failure.
for rc_want in 1 2 3 4 5; do
	: >"$STUB_LOG"
	RC=0
	FY_LIVE=1 STUB_RC="$rc_want" bash -c '. "$LIB"; fyd_notify high "T" "b"' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
	if [ "$RC" -eq "$rc_want" ]; then
		pass "fyd_notify: delegate exit $rc_want returned verbatim (no translation)"
	else
		fail_case "fyd_notify: delegate exit $rc_want returned verbatim (no translation)" "got rc=$RC"
	fi
done

# ============================================================
# Part 4: fyd_notify — argument validation runs in BOTH modes
# ============================================================
# "dry で通ったものが live で落ちる" must be impossible, so validation is
# not behind the FY_LIVE branch. Each case is asserted twice.

check_both_modes() {
	# check_both_modes <label> <snippet> <expected-rc>
	local label="$1" snippet="$2" want="$3" rc_dry=0 rc_live=0 calls_dry calls_live
	: >"$STUB_LOG"
	env -u FY_LIVE bash -c ". \"\$LIB\"; $snippet" >"$OUT_FILE" 2>"$ERR_FILE" || rc_dry=$?
	calls_dry="$(stub_calls)"
	: >"$STUB_LOG"
	FY_LIVE=1 bash -c ". \"\$LIB\"; $snippet" >"$OUT_FILE" 2>"$ERR_FILE" || rc_live=$?
	calls_live="$(stub_calls)"
	if [ "$rc_dry" -eq "$want" ] && [ "$rc_live" -eq "$want" ] \
		&& [ "$calls_dry" -eq 0 ] && [ "$calls_live" -eq 0 ]; then
		pass "$label" "rc=$want in both modes, 0 delegate calls"
	else
		fail_case "$label" "dry rc=$rc_dry calls=$calls_dry / live rc=$rc_live calls=$calls_live (want $want)"
	fi
}

check_both_modes "fyd_notify: unknown option (--tag= typo) rejected" 'fyd_notify --tag=tada high "T" "b"' 64
check_both_modes "fyd_notify: no arguments rejected" 'fyd_notify' 64
check_both_modes "fyd_notify: priority without title rejected" 'fyd_notify high' 64
check_both_modes "fyd_notify: unreadable delegate rejected" 'FYD_NOTIFY=/nonexistent/notify.sh fyd_notify high "T" "b"' 64

# An unknown priority is WARNED about but passed through: notify.sh coerces
# it to "default" and still delivers. Refusing here would lose an alert,
# which is worse than delivering it at the wrong priority.
: >"$STUB_LOG"
RC=0
FY_LIVE=1 bash -c '. "$LIB"; fyd_notify screaming "T" "b"' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
ERR="$(cat "$ERR_FILE")"
if [ "$RC" -eq 0 ] && [ "$(stub_calls)" -eq 1 ] && printf '%s' "$ERR" | grep -qi 'WARNING'; then
	pass "fyd_notify: unknown priority warns but still delivers (alert loss > wrong priority)"
else
	fail_case "fyd_notify: unknown priority warns but still delivers" "rc=$RC calls=$(stub_calls) err=[$ERR]"
fi

# An option written AFTER the priority becomes message text — the
# notification goes out titled "--strict". Same reasoning as above: not
# refused (that would drop an alert), but never silent.
: >"$STUB_LOG"
RC=0
FY_LIVE=1 bash -c '. "$LIB"; fyd_notify high --strict "Title" "body"' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
ERR="$(cat "$ERR_FILE")"
if [ "$RC" -eq 0 ] && [ "$(stub_calls)" -eq 1 ] \
	&& grep -q '^ARG=--strict$' "$STUB_LOG" \
	&& grep -q '^ENV_NOTIFY_STRICT_EXIT=<unset>$' "$STUB_LOG" \
	&& printf '%s' "$ERR" | grep -q "WARNING.*'--strict' came AFTER"; then
	pass "fyd_notify: misplaced --strict is warned about (it became text, not an option)"
else
	fail_case "fyd_notify: misplaced --strict is warned about" "rc=$RC err=[$ERR] log=[$(cat "$STUB_LOG")]"
fi

: >"$STUB_LOG"
FY_LIVE=1 bash -c '. "$LIB"; fyd_notify high "T" --tags=tada "body"' >"$OUT_FILE" 2>"$ERR_FILE"
ERR="$(cat "$ERR_FILE")"
if printf '%s' "$ERR" | grep -q "WARNING.*'--tags=tada' came AFTER" && grep -q '^ENV_NTFY_TAGS=<unset>$' "$STUB_LOG"; then
	pass "fyd_notify: misplaced --tags= in the message is warned about too"
else
	fail_case "fyd_notify: misplaced --tags= in the message is warned about too" "err=[$ERR] log=[$(cat "$STUB_LOG")]"
fi

# ============================================================
# Part 5: fyd_push
# ============================================================

: >"$STUB_LOG"
RC=0
env -u FY_LIVE bash -c '. "$LIB"; fyd_push validator.json' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
ERR="$(cat "$ERR_FILE")"
if [ "$RC" -eq 0 ] && [ "$(stub_calls)" -eq 0 ] && printf '%s' "$ERR" | grep -q '^DRY: would push validator.json'; then
	pass "fyd_push: dry → no delegate call, rc 0, stderr 'DRY: would push validator.json'"
else
	fail_case "fyd_push: dry → no delegate call, rc 0, stderr 'DRY: would push'" "rc=$RC calls=$(stub_calls) err=[$ERR]"
fi

: >"$STUB_LOG"
RC=0
FY_LIVE=1 bash -c '. "$LIB"; fyd_push archive/anchor-source-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.json' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
if [ "$RC" -eq 0 ] && [ "$(stub_calls)" -eq 1 ] && grep -q '^ARGC=1$' "$STUB_LOG" \
	&& grep -q '^ARG=archive/anchor-source-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.json$' "$STUB_LOG"; then
	pass "fyd_push: live → delegate called once with the filename verbatim (subdir shape)"
else
	fail_case "fyd_push: live → delegate called once with the filename verbatim" "rc=$RC log=[$(cat "$STUB_LOG")]"
fi

: >"$STUB_LOG"
RC=0
FY_LIVE=1 STUB_RC=1 bash -c '. "$LIB"; fyd_push validator.json' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
if [ "$RC" -eq 1 ]; then
	pass "fyd_push: delegate exit 1 returned verbatim"
else
	fail_case "fyd_push: delegate exit 1 returned verbatim" "got rc=$RC"
fi

check_both_modes "fyd_push: path traversal rejected" 'fyd_push ../../etc/passwd' 64
check_both_modes "fyd_push: absolute path rejected" 'fyd_push /etc/passwd' 64
check_both_modes "fyd_push: empty filename rejected" 'fyd_push ""' 64
check_both_modes "fyd_push: no argument rejected" 'fyd_push' 64
check_both_modes "fyd_push: two arguments rejected" 'fyd_push a.json b.json' 64
check_both_modes "fyd_push: shell metacharacters rejected" 'fyd_push "a.json; rm -rf /"' 64
check_both_modes "fyd_push: nested subdirectory rejected" 'fyd_push a/b/c.json' 64
check_both_modes "fyd_push: unreadable delegate rejected" 'FYD_PUSH_TO_WEB_HOST=/nonexistent/push.sh fyd_push validator.json' 64

# Lock-step: the lib's dry-mode shape check must be the SAME expression
# push-to-web-host.sh enforces, or a dry run could accept what live rejects.
SHAPE_RE_LITERAL='^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$'
if grep -qF "$SHAPE_RE_LITERAL" "$PUSH_SCRIPT" && grep -qF "$SHAPE_RE_LITERAL" "$LIB"; then
	pass "fyd_push: filename shape expression is byte-identical to push-to-web-host.sh's"
else
	fail_case "fyd_push: filename shape expression is byte-identical to push-to-web-host.sh's" "drifted — update both"
fi

# ============================================================
# Part 6: fyd_state_dir — four legacy names collapse into one
# ============================================================

state_case() {
	# state_case <label> <role> <expected-stdout> [VAR=VALUE ...]
	local label="$1" role="$2" want="$3" rc=0 got
	shift 3
	got="$(env -u FY_STATE_DIR -u ANOMALY_STATE_DIR -u WATCH_STATE_DIR -u UPTIME_STATE_DIR -u FY_LIVE \
		"$@" bash -c ". \"\$LIB\"; fyd_state_dir ${role}" 2>/dev/null)" || rc=$?
	if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
		pass "$label" "$got"
	else
		fail_case "$label" "rc=$rc got=[$got] want=[$want]"
	fi
}

state_case "fyd_state_dir: nothing set → production default" "" "/var/lib/freedom-yield"
state_case "fyd_state_dir: FY_STATE_DIR wins (canonical)" "" "/sandbox/fy" FY_STATE_DIR=/sandbox/fy
state_case "fyd_state_dir: role anomaly honours legacy ANOMALY_STATE_DIR" "anomaly" "/legacy/anomaly" ANOMALY_STATE_DIR=/legacy/anomaly
state_case "fyd_state_dir: role watch honours legacy WATCH_STATE_DIR" "watch" "/legacy/watch" WATCH_STATE_DIR=/legacy/watch
state_case "fyd_state_dir: role uptime honours legacy UPTIME_STATE_DIR" "uptime" "/legacy/uptime" UPTIME_STATE_DIR=/legacy/uptime
state_case "fyd_state_dir: role cycle resolves via FY_STATE_DIR" "cycle" "/sandbox/cycle" FY_STATE_DIR=/sandbox/cycle
state_case "fyd_state_dir: role anomaly falls back to default when unset" "anomaly" "/var/lib/freedom-yield"
state_case "fyd_state_dir: legacy name is ignored without its role (role required)" "" "/var/lib/freedom-yield" ANOMALY_STATE_DIR=/legacy/anomaly

# Precedence when both are set: the canonical name wins, because
# FY_STATE_DIR is the lever a test uses to sandbox EVERYTHING at once — an
# ambient legacy name must not be able to drag a sandboxed run back onto a
# production path. The conflict is announced, not swallowed.
: >"$STUB_LOG"
RC=0
OUT="$(env -u WATCH_STATE_DIR FY_STATE_DIR=/sandbox/fy ANOMALY_STATE_DIR=/var/lib/freedom-yield \
	bash -c '. "$LIB"; fyd_state_dir anomaly' 2>"$ERR_FILE")" || RC=$?
ERR="$(cat "$ERR_FILE")"
if [ "$RC" -eq 0 ] && [ "$OUT" = "/sandbox/fy" ] && printf '%s' "$ERR" | grep -q 'ANOMALY_STATE_DIR'; then
	pass "fyd_state_dir: FY_STATE_DIR beats a conflicting legacy name, and says so on stderr"
else
	fail_case "fyd_state_dir: FY_STATE_DIR beats a conflicting legacy name, and says so" "rc=$RC out=[$OUT] err=[$ERR]"
fi

# Unknown role must fail closed: a typo'd role that silently fell through
# to the default would write to production, which is the exact bug class
# this library exists to remove.
RC=0
OUT="$(env -u FY_STATE_DIR bash -c '. "$LIB"; fyd_state_dir anomalies' 2>"$ERR_FILE")" || RC=$?
if [ "$RC" -eq 64 ] && [ -z "$OUT" ]; then
	pass "fyd_state_dir: unknown role → rc 64, nothing on stdout (fail-closed)"
else
	fail_case "fyd_state_dir: unknown role → rc 64, nothing on stdout" "rc=$RC out=[$OUT]"
fi

RC=0
OUT="$(env -u FY_STATE_DIR bash -c '. "$LIB"; fyd_state_dir anomaly extra' 2>/dev/null)" || RC=$?
if [ "$RC" -eq 64 ]; then
	pass "fyd_state_dir: extra argument → rc 64"
else
	fail_case "fyd_state_dir: extra argument → rc 64" "rc=$RC out=[$OUT]"
fi

# Falling back to the production default while not live is legal (read-only
# use, operator debugging) but must be visible.
RC=0
OUT="$(env -u FY_STATE_DIR -u FY_LIVE bash -c '. "$LIB"; fyd_state_dir' 2>"$ERR_FILE")" || RC=$?
ERR="$(cat "$ERR_FILE")"
if [ "$OUT" = "/var/lib/freedom-yield" ] && printf '%s' "$ERR" | grep -q 'WARNING'; then
	pass "fyd_state_dir: production default under dry → warns on stderr"
else
	fail_case "fyd_state_dir: production default under dry → warns on stderr" "out=[$OUT] err=[$ERR]"
fi

RC=0
ERR_ONLY="$(env -u FY_STATE_DIR FY_LIVE=1 bash -c '. "$LIB"; fyd_state_dir' 2>&1 1>/dev/null)" || RC=$?
if [ -z "$ERR_ONLY" ]; then
	pass "fyd_state_dir: production default under live → silent (no cron log noise)"
else
	fail_case "fyd_state_dir: production default under live → silent" "err=[$ERR_ONLY]"
fi

# ============================================================
# Part 7: fyd_live_run — the generic gate for ad-hoc side effects
# ============================================================
# Everything that is neither notify nor push (file writes, rm, ssh,
# systemctl) goes through this, so those callers do not each invent a
# seventh way to spell "don't do it for real".

SENTINEL="${TMP}/sentinel"
rm -f "$SENTINEL"
RC=0
env -u FY_LIVE bash -c ". \"\$LIB\"; fyd_live_run \"create the sentinel\" touch \"$SENTINEL\"" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
ERR="$(cat "$ERR_FILE")"
if [ "$RC" -eq 0 ] && [ ! -e "$SENTINEL" ] && printf '%s' "$ERR" | grep -q '^DRY: would create the sentinel'; then
	pass "fyd_live_run: dry → command not executed, rc 0, 'DRY: would <description>'"
else
	fail_case "fyd_live_run: dry → command not executed, rc 0" "rc=$RC exists=$([ -e "$SENTINEL" ] && echo yes || echo no) err=[$ERR]"
fi

rm -f "$SENTINEL"
RC=0
FY_LIVE=1 bash -c ". \"\$LIB\"; fyd_live_run \"create the sentinel\" touch \"$SENTINEL\"" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
if [ "$RC" -eq 0 ] && [ -e "$SENTINEL" ]; then
	pass "fyd_live_run: live → command executed"
else
	fail_case "fyd_live_run: live → command executed" "rc=$RC exists=$([ -e "$SENTINEL" ] && echo yes || echo no)"
fi
rm -f "$SENTINEL"

RC=0
FY_LIVE=1 bash -c '. "$LIB"; fyd_live_run "fail on purpose" bash -c "exit 7"' >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
if [ "$RC" -eq 7 ]; then
	pass "fyd_live_run: live → command exit code returned verbatim"
else
	fail_case "fyd_live_run: live → command exit code returned verbatim" "got rc=$RC"
fi

check_both_modes "fyd_live_run: description without command rejected" 'fyd_live_run "just a description"' 64
check_both_modes "fyd_live_run: empty description rejected" 'fyd_live_run "" true' 64

# A caller-side redirection is applied by the caller's shell BEFORE the
# function runs, so fyd_live_run cannot gate it. This case pins that
# limitation as known-and-documented rather than leaving it to be
# rediscovered as an incident: it is the reason fyd_live_write exists, and
# if a future change ever DOES gate redirections, this case failing is the
# signal to delete it and the header warning together.
REDIR_FILE="${TMP}/redirect-not-gated"
printf 'PRE-EXISTING\n' >"$REDIR_FILE"
env -u FY_LIVE bash -c ". \"\$LIB\"; fyd_live_run \"write via redirect\" echo hi > \"$REDIR_FILE\"" 2>/dev/null
if [ ! -s "$REDIR_FILE" ]; then
	pass "fyd_live_run: caller-side '>' is NOT gated (documented limitation → use fyd_live_write)"
else
	fail_case "fyd_live_run: caller-side '>' is NOT gated (documented limitation)" "file kept content — behaviour changed, update the header"
fi
rm -f "$REDIR_FILE"

# ============================================================
# Part 7b: fyd_live_write — the gate a redirection cannot bypass
# ============================================================
# This is the direct counter-measure to the accident class "a test wrote to
# / truncated / deleted a production file". The path is an argument and the
# content arrives on stdin, so the open() happens INSIDE the gate.

WFILE="${TMP}/state.json"

# Dry must not create the file at all.
rm -f "$WFILE"
RC=0
printf 'new content\n' | env -u FY_LIVE bash -c ". \"\$LIB\"; fyd_live_write \"the cycle state\" \"$WFILE\"" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
ERR="$(cat "$ERR_FILE")"
if [ "$RC" -eq 0 ] && [ ! -e "$WFILE" ] && printf '%s' "$ERR" | grep -q '^DRY: would write the cycle state'; then
	pass "fyd_live_write: dry → file is not even created, rc 0, 'DRY: would write …'"
else
	fail_case "fyd_live_write: dry → file is not even created, rc 0" "rc=$RC exists=$([ -e "$WFILE" ] && echo yes || echo no) err=[$ERR]"
fi

# Dry must not TRUNCATE an existing production file — the exact shape of the
# 2026-08 accident.
printf 'PRODUCTION DATA\n' >"$WFILE"
BEFORE="$(cat "$WFILE")"
RC=0
printf 'clobber\n' | env -u FY_LIVE bash -c ". \"\$LIB\"; fyd_live_write \"the cycle state\" \"$WFILE\"" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$WFILE")" = "$BEFORE" ]; then
	pass "fyd_live_write: dry → existing production file NOT truncated (byte-identical)"
else
	fail_case "fyd_live_write: dry → existing production file NOT truncated" "rc=$RC now=[$(cat "$WFILE")]"
fi

# Same for the append form.
RC=0
printf 'extra\n' | env -u FY_LIVE bash -c ". \"\$LIB\"; fyd_live_write --append \"the ledger\" \"$WFILE\"" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
ERR="$(cat "$ERR_FILE")"
if [ "$RC" -eq 0 ] && [ "$(cat "$WFILE")" = "$BEFORE" ] && printf '%s' "$ERR" | grep -q '^DRY: would append to'; then
	pass "fyd_live_write: dry --append → nothing appended, DRY line says 'append to'"
else
	fail_case "fyd_live_write: dry --append → nothing appended" "rc=$RC now=[$(cat "$WFILE")] err=[$ERR]"
fi

# The DRY line reports how much content was suppressed, which also proves
# stdin was drained (a producer on the left of the pipe must not take
# SIGPIPE and fail a `set -o pipefail` caller).
RC=0
OUT_ERR="$(printf '123456789\n' | env -u FY_LIVE bash -c ". \"\$LIB\"; set -o pipefail; fyd_live_write \"x\" \"$WFILE\"" 2>&1 1>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT_ERR" | grep -q '10 bytes on stdin'; then
	pass "fyd_live_write: dry drains stdin and reports the byte count (no SIGPIPE for the producer)"
else
	fail_case "fyd_live_write: dry drains stdin and reports the byte count" "rc=$RC err=[$OUT_ERR]"
fi

# Live actually writes.
rm -f "$WFILE"
RC=0
printf 'live content\n' | FY_LIVE=1 bash -c ". \"\$LIB\"; fyd_live_write \"the cycle state\" \"$WFILE\"" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$WFILE" 2>/dev/null)" = "live content" ]; then
	pass "fyd_live_write: live → stdin written to the path"
else
	fail_case "fyd_live_write: live → stdin written to the path" "rc=$RC content=[$(cat "$WFILE" 2>/dev/null)]"
fi

RC=0
printf 'appended\n' | FY_LIVE=1 bash -c ". \"\$LIB\"; fyd_live_write --append \"the ledger\" \"$WFILE\"" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$WFILE" 2>/dev/null)" = "live content
appended" ]; then
	pass "fyd_live_write: live --append → content appended, existing content kept"
else
	fail_case "fyd_live_write: live --append → content appended" "rc=$RC content=[$(cat "$WFILE" 2>/dev/null)]"
fi

# Truncate-to-empty (the `: > "$f"` shape) works through the gate.
RC=0
FY_LIVE=1 bash -c ". \"\$LIB\"; fyd_live_write \"the empty ledger\" \"$WFILE\" </dev/null" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
if [ "$RC" -eq 0 ] && [ -f "$WFILE" ] && [ ! -s "$WFILE" ]; then
	pass "fyd_live_write: live with </dev/null → truncated to empty (the ': > \$f' shape)"
else
	fail_case "fyd_live_write: live with </dev/null → truncated to empty" "rc=$RC size=$(wc -c <"$WFILE" 2>/dev/null)"
fi

# A failing write reports non-zero (parent directory missing — the
# live-only parity gap documented in the lib header).
RC=0
printf 'x\n' | FY_LIVE=1 bash -c ". \"\$LIB\"; fyd_live_write \"nowhere\" \"${TMP}/no-such-dir/f\"" >"$OUT_FILE" 2>/dev/null || RC=$?
if [ "$RC" -ne 0 ] && [ "$RC" -ne 64 ]; then
	pass "fyd_live_write: live → a failing write returns non-zero (not a usage error)" "rc=$RC"
else
	fail_case "fyd_live_write: live → a failing write returns non-zero" "rc=$RC"
fi

check_both_modes "fyd_live_write: path without description rejected" 'fyd_live_write "only-one-arg" </dev/null' 64
check_both_modes "fyd_live_write: empty description rejected" 'fyd_live_write "" /tmp/x </dev/null' 64
check_both_modes "fyd_live_write: empty path rejected" 'fyd_live_write "d" "" </dev/null' 64
check_both_modes "fyd_live_write: extra argument rejected" 'fyd_live_write "d" /tmp/x /tmp/y </dev/null' 64
check_both_modes "fyd_live_write: unknown option rejected" 'fyd_live_write --appnd "d" /tmp/x </dev/null' 64
check_both_modes "fyd_live_write: directory as path rejected" "fyd_live_write \"d\" \"$TMP\" </dev/null" 64

# ============================================================
# Part 8: hermeticity tripwire
# ============================================================

if [ ! -s "$TRIPWIRE" ]; then
	pass "hermeticity: no case invoked curl or ssh (real ntfy / web host never reached)"
else
	fail_case "hermeticity: no case invoked curl or ssh" "tripwire=[$(cat "$TRIPWIRE")]"
fi

# ============================================================
# Part 9: mutation — prove Parts 2/5 can actually go red
# ============================================================
# Both mutants are applied by redefining a single function AFTER sourcing
# the real library. That only works if every side effect consults that one
# function, so a green result here doubles as proof of the "one decision
# site" invariant.

# M1: fyd_is_live always says live → the dry cases must leak a delegate call.
: >"$STUB_LOG"
env -u FY_LIVE bash -c '. "$LIB"; fyd_is_live() { return 0; }; fyd_notify high "T" "b"' >/dev/null 2>&1
M1_NOTIFY="$(stub_calls)"
: >"$STUB_LOG"
env -u FY_LIVE bash -c '. "$LIB"; fyd_is_live() { return 0; }; fyd_push validator.json' >/dev/null 2>&1
M1_PUSH="$(stub_calls)"
rm -f "$SENTINEL"
env -u FY_LIVE bash -c ". \"\$LIB\"; fyd_is_live() { return 0; }; fyd_live_run d touch \"$SENTINEL\"" >/dev/null 2>&1
M1_RUN=0
[ -e "$SENTINEL" ] && M1_RUN=1
rm -f "$SENTINEL"
printf 'leaked\n' | env -u FY_LIVE bash -c ". \"\$LIB\"; fyd_is_live() { return 0; }; fyd_live_write d \"$SENTINEL\"" >/dev/null 2>&1
M1_WRITE=0
[ -s "$SENTINEL" ] && M1_WRITE=1
rm -f "$SENTINEL"
if [ "$M1_NOTIFY" -eq 1 ] && [ "$M1_PUSH" -eq 1 ] && [ "$M1_RUN" -eq 1 ] && [ "$M1_WRITE" -eq 1 ]; then
	pass "mutation M1: always-live mutant leaks all four side effects (dry assertions are real)"
else
	fail_case "mutation M1: always-live mutant leaks all four side effects" "notify=$M1_NOTIFY push=$M1_PUSH run=$M1_RUN write=$M1_WRITE — a side effect bypasses fyd_is_live"
fi

# M2: fyd_dry_note prints nothing → the 'DRY:' assertions must lose their
# evidence. If any DRY: line survives, some path prints it inline instead
# of going through the single helper.
M2_ERR="$(env -u FY_LIVE bash -c ". \"\$LIB\"; fyd_dry_note() { return 0; }; fyd_notify high \"T\" \"b\"; fyd_push validator.json; fyd_live_run d true; fyd_live_write d \"${TMP}/m2\" </dev/null" 2>&1 1>/dev/null)"
if ! printf '%s' "$M2_ERR" | grep -q 'DRY:'; then
	pass "mutation M2: silencing fyd_dry_note removes every DRY: line (loud-dry assertions are real)"
else
	fail_case "mutation M2: silencing fyd_dry_note removes every DRY: line" "surviving=[$M2_ERR]"
fi

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-side-effects.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
