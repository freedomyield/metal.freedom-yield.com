#!/usr/bin/env bash
# test-check-host-drift.sh — suite for scripts/check-host-drift.sh.
#
# CHAIN: none — builds throwaway local git repo pairs (origin + clone) in a
#        tempdir; no network, no real ntfy (notifier is a recording stub).
#
# Usage:
#   bash tests/host-drift/test-check-host-drift.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

# Hermeticity: force a resolvable git commit identity for every git command
# this suite runs, regardless of the ambient environment. GIT_AUTHOR_NAME /
# GIT_COMMITTER_NAME environment variables — if merely *set*, even to an
# empty string — take precedence over ALL config sources (system, global,
# local repo config, and the per-invocation `-c user.name=...` this suite
# already uses via GITQ alike). A CI runner with no global git identity and
# an empty GECOS name derives an empty name and `git commit` dies with
# "empty ident name ... not allowed"; GITQ's `-c user.name=` does NOT help
# in that case, because an explicitly-empty env var already won. Exporting
# non-empty values here is the one thing that actually wins in every
# environment (see scripts/operator-local/test-commit-anchor-source.sh for
# the case where this was first found to matter). Values are obviously fake
# test fixtures (.invalid is the RFC 2606 reserved-for-testing TLD) — never
# a real operator name/email.
export GIT_AUTHOR_NAME="FYD Hermetic Test Suite"
export GIT_AUTHOR_EMAIL="fyd-hermetic-test@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-host-drift.sh"

if [ ! -f "$CHECKER" ]; then
	echo "FATAL: checker not found at $CHECKER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# ---- harness -----------------------------------------------------------------
# build_pair: bare origin with one commit (scripts/ + public/ content) + clone.
BASE=""; ORIGIN=""; CLONE=""; STUB=""; STUB_LOG=""
GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)
build_pair() {
	BASE="$(mktemp -d -t host-drift-test.XXXXXX)"
	ORIGIN="$BASE/origin.git"
	CLONE="$BASE/clone"
	STUB="$BASE/notify-stub.sh"
	STUB_LOG="$BASE/notify.log"

	local seed="$BASE/seed"
	mkdir -p "$seed/scripts" "$seed/public" "$seed/docs"
	echo 'echo hello' > "$seed/scripts/a.sh"
	echo '<html>' > "$seed/public/index.html"
	echo '# doc' > "$seed/docs/README.md"
	git -C "$seed" "${GITQ[@]}" init -q -b main
	git -C "$seed" "${GITQ[@]}" add -A
	git -C "$seed" "${GITQ[@]}" commit -qm seed

	git clone -q --bare "$seed" "$ORIGIN"
	git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
	git -C "$CLONE" "${GITQ[@]}" remote set-url origin "$ORIGIN"

	cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$STUB_LOG"
STUBEOF
	chmod +x "$STUB"
}
teardown() { rm -rf "$BASE"; BASE=""; }

# FY_LIVE=1 is what makes the recording stub actually get called: since the
# C3 inversion (scripts/lib/side-effects.sh, 2026-08-06) every side effect is
# opt-in, so a run without it is a loud dry no-op and no alert is delivered to
# assert on. That default-dry behaviour has its own coverage in
# tests/side-effects-callers/test-monitoring-side-effects.sh; here we opt in
# because these cases are about WHAT is alerted, not WHETHER.
run_checker() {
	FY_LIVE=1 FYD_REPO_DIR="$CLONE" FYD_NOTIFY="$STUB" bash "$CHECKER" "$@"
}
alerts() { cat "$STUB_LOG" 2>/dev/null; }

# ---- case 1: in sync → exit 0, no alert ---------------------------------------
build_pair
OUT="$(run_checker 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "in-sync: exit 0" \
	|| bad "in-sync: exit 0 (actual=$RC)"
echo "$OUT" | grep -q 'in sync: ahead=0 behind=0 code-drift=0' \
	&& ok "in-sync: healthy log line" \
	|| bad "in-sync: healthy log line (out: $OUT)"
[ -s "$STUB_LOG" ] \
	&& bad "in-sync: no alert fired" \
	|| ok "in-sync: no alert fired"
teardown

# ---- case 2: local ahead commit → exit 1 + high alert --------------------------
build_pair
echo 'echo edited-on-host' > "$CLONE/scripts/a.sh"
git -C "$CLONE" "${GITQ[@]}" commit -qam host-local-edit
run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "ahead: exit 1" \
	|| bad "ahead: exit 1 (actual=$RC)"
alerts | grep -q '^high|host-drift: checkout diverging|.*ahead=1' \
	&& ok "ahead: high alert with ahead=1" \
	|| bad "ahead: high alert with ahead=1 (alerts: $(alerts))"
alerts | grep -q 'advance-host-checkout.sh' \
	&& ok "ahead: alert points first remedy at auto-advance backstop" \
	|| bad "ahead: alert points first remedy at auto-advance backstop (alerts: $(alerts))"
teardown

# ---- case 3: uncommitted code-zone drift → exit 1, file named in alert ---------
build_pair
echo 'echo hand-edited' >> "$CLONE/scripts/a.sh"
run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "code-drift: exit 1" \
	|| bad "code-drift: exit 1 (actual=$RC)"
alerts | grep -q 'code-drift=1' \
	&& ok "code-drift: alert carries code-drift=1" \
	|| bad "code-drift: alert carries code-drift=1 (alerts: $(alerts))"
alerts | grep -q 'scripts/a.sh' \
	&& ok "code-drift: drifted file named in alert" \
	|| bad "code-drift: drifted file named in alert"
teardown

# ---- case 4: public/-only drift → exit 0 (structural, excluded by design) ------
build_pair
echo '<html>?v=stamped' > "$CLONE/public/index.html"
run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "public-only drift: exit 0 (excluded zone)" \
	|| bad "public-only drift: exit 0 (actual=$RC)"
[ -s "$STUB_LOG" ] \
	&& bad "public-only drift: no alert" \
	|| ok "public-only drift: no alert"
teardown

# ---- case 5: behind within threshold → exit 0; beyond threshold → exit 1 -------
build_pair
# add 2 commits to origin only (via a scratch clone)
SCRATCH="$BASE/scratch"
git clone -q "$ORIGIN" "$SCRATCH" 2>/dev/null
for i in 1 2; do
	echo "change $i" >> "$SCRATCH/docs/README.md"
	git -C "$SCRATCH" "${GITQ[@]}" commit -qam "origin-change-$i"
done
git -C "$SCRATCH" push -q origin main
run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "behind=2 (max 10): exit 0, informational" \
	|| bad "behind=2 (max 10): exit 0 (actual=$RC)"
FYD_BEHIND_MAX=1 run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "behind=2 (max 1): exit 1" \
	|| bad "behind=2 (max 1): exit 1 (actual=$RC)"
alerts | grep -q 'behind=2(>1)' \
	&& ok "behind: alert names the threshold breach" \
	|| bad "behind: alert names the threshold breach (alerts: $(alerts))"
teardown

# ---- case 6: fetch failure → exit 2 + default-priority alert --------------------
build_pair
rm -rf "$ORIGIN"
run_checker >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "fetch-fail: exit 2" \
	|| bad "fetch-fail: exit 2 (actual=$RC)"
alerts | grep -q '^default|host-drift: fetch failed' \
	&& ok "fetch-fail: default-priority alert" \
	|| bad "fetch-fail: default-priority alert (alerts: $(alerts))"
teardown

# ---- case 7: not a git dir → exit 2, no crash ------------------------------------
build_pair
NOTDIR="$BASE/plain"; mkdir -p "$NOTDIR"
FY_LIVE=1 FYD_REPO_DIR="$NOTDIR" FYD_NOTIFY="$STUB" bash "$CHECKER" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "non-git dir: exit 2" \
	|| bad "non-git dir: exit 2 (actual=$RC)"
teardown

# ---- case 8: checker is read-only (never mutates the clone) ----------------------
build_pair
echo 'echo hand-edited' >> "$CLONE/scripts/a.sh"
SNAP="$(cat "$CLONE/scripts/a.sh")"
HEAD_BEFORE="$(git -C "$CLONE" rev-parse HEAD)"
run_checker >/dev/null 2>&1
[ "$(cat "$CLONE/scripts/a.sh")" = "$SNAP" ] && [ "$(git -C "$CLONE" rev-parse HEAD)" = "$HEAD_BEFORE" ] \
	&& ok "read-only: working tree and HEAD untouched" \
	|| bad "read-only: working tree and HEAD untouched"
teardown

# ---- summary ----------------------------------------------------------------------
echo "test-check-host-drift.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
