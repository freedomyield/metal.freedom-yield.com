#!/usr/bin/env bash
# tests/install-xserver-anchor-source-allowlist/test-install-xserver-anchor-source-allowlist.sh
# Scenario tests for scripts/install-xserver-anchor-source-allowlist.sh
# (local SKIP_SSH mode) — no real host is ever contacted.
#
# CHAIN: none — pure local file editing via SKIP_SSH=1 WRAPPER_FILE=<path>,
# the same convention tests/install-xserver-static-deploy-key already
# exercises for that script. PRIME_DIRECTIVE: safe (no SSH, no broadcast).
#
# Background (2026-08-06): this script used to ADD `anchor-source.json` to
# the Xserver receive-wrapper allowlist under an assumption (2026-07-01)
# that push-to-web-host.sh would publish it — an assumption the
# 2026-07-07 git-deploy migration made permanently false (that sender's
# allowlist has never carried `anchor-source.json`). The script was
# flipped to do the OPPOSITE: remove the token if a prior run (or manual
# edit) ever added it, idempotently, without disturbing the
# `anchor-source.json.sig` token (a separate, also-dead reference tracked
# by tests/install-xserver-sig-allowlist instead) or any other entry.
#
# Review round 1 (2026-08-06) finding: the local SKIP_SSH path
# (remove_from()) and the remote SSH heredoc used a DIFFERENT
# post-removal verification regex (local: `anchor-source\.json[|)]`;
# remote: `[^.]anchor-source\.json[|)]`), so the two paths could disagree
# on the identical wrapper content. T10-T13 below drive the REAL remote
# heredoc body (extracted verbatim from the shipped script via awk, with
# only its one hardcoded `WRAPPER=/home/deploy/...` line swapped for an
# env-supplied path — same "extract, don't reimplement" principle as
# tests/node-health/test-bootstrap-probe.sh) so this suite can no longer
# silently drift from what actually runs on the Xserver host, and T14 is
# the exact reproduction that caught the bug: a wrapper with
# `anchor-source.json` duplicated on one line, exploiting sed's missing
# `g` flag so removal leaves one residual sitting at column 0 of the
# line (nothing precedes it) — a position `[^.]anchor-source\.json[|)]`
# can never match (no character exists before column 0 for `[^.]` to
# consume), which is exactly how the remote path used to report false
# success while a real token still lingered.
#
# Usage:
#   bash tests/install-xserver-anchor-source-allowlist/test-install-xserver-anchor-source-allowlist.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
INSTALLER="${REPO}/scripts/install-xserver-anchor-source-allowlist.sh"

[ -f "$INSTALLER" ] || { echo "FATAL: installer not found at $INSTALLER" >&2; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

WORK=""; cleanup(){ [ -n "${WORK}" ] && rm -rf "${WORK}"; }; trap cleanup EXIT
WORK="$(mktemp -d)"

run(){ SKIP_SSH=1 WRAPPER_FILE="$1" bash "$INSTALLER"; }

# ---- extract the REAL remote heredoc body (verbatim, not reimplemented) ----
# The heredoc is delimited by `<<'REMOTE_EOF'` ... a flush-left `REMOTE_EOF`.
# Its one hardcoded `WRAPPER=/home/deploy/bin/receive-metal-push` line is
# swapped for a guard that requires the test to supply WRAPPER via env —
# every other byte of logic (the idempotency check, the sed removal, the
# post-removal verification, the syntax check) is exactly what the
# installer ships to the Xserver host.
REMOTE_SCRIPT="${WORK}/remote-heredoc-body.sh"
awk '/<<.REMOTE_EOF./{flag=1;next} /^REMOTE_EOF$/{flag=0} flag' "$INSTALLER" \
	| sed 's#^WRAPPER=/home/deploy/bin/receive-metal-push$#: "${WRAPPER:?WRAPPER must be set by the test harness}"#' \
	> "$REMOTE_SCRIPT"
if [ ! -s "$REMOTE_SCRIPT" ]; then
	echo "FATAL: could not extract the remote heredoc body from $INSTALLER (delimiter renamed/moved?)" >&2
	exit 1
fi
if grep -qF 'WRAPPER=/home/deploy/bin/receive-metal-push' "$REMOTE_SCRIPT"; then
	echo "FATAL: hardcoded WRAPPER= line survived extraction — env override would be silently ignored" >&2
	exit 1
fi
run_remote(){ WRAPPER="$1" bash "$REMOTE_SCRIPT"; }

echo "================================================================"
echo "install-xserver-anchor-source-allowlist.sh — scenario tests"
echo "================================================================"

echo "[T1] mid-list token (matches the pre-2026-08-06 add-installer's exact insert shape) is removed"
W="${WORK}/t1.sh"
cat > "$W" <<'EOF'
case "$1" in
  anchor-source.json|validator.json|peer-geo.json|evidence.json)
    exit 0
    ;;
esac
EOF
OUT="$(run "$W")"; RC=$?
if [ "$RC" = 0 ] && ! grep -qE 'anchor-source\.json[|)]' "$W" && grep -q 'validator.json|peer-geo.json|evidence.json' "$W"; then
	ok "T1 token removed, siblings intact"
else
	no "T1 (rc=$RC); wrapper now: $(cat "$W" 2>/dev/null)"
fi
echo "$OUT" | grep -q 'OK: anchor-source.json removed' && ok "T1 success message printed" || no "T1 success message missing"

echo "[T2] end-of-list token (defensive shape) is removed"
W="${WORK}/t2.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|peer-geo.json|anchor-source.json)
    exit 0
    ;;
esac
EOF
run "$W" >/dev/null; RC=$?
if [ "$RC" = 0 ] && ! grep -qE 'anchor-source\.json[|)]' "$W" && grep -qE '^\s*validator\.json\|peer-geo\.json\)' "$W"; then
	ok "T2 end-of-list token removed cleanly"
else
	no "T2 (rc=$RC); wrapper now: $(cat "$W" 2>/dev/null)"
fi

echo "[T3] idempotent: token absent -> no-op, exit 0, file byte-identical"
W="${WORK}/t3.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|peer-geo.json)
    exit 0
    ;;
esac
EOF
BEFORE="$(cat "$W")"
OUT="$(run "$W")"; RC=$?
AFTER="$(cat "$W")"
[ "$RC" = 0 ] && ok "T3 exit 0 when absent" || no "T3 exit code (rc=$RC)"
[ "$BEFORE" = "$AFTER" ] && ok "T3 file unchanged when token absent" || no "T3 file was modified despite absence"
echo "$OUT" | grep -q 'nothing to remove' && ok "T3 no-op message printed" || no "T3 no-op message missing"

echo "[T4] anchor-source.json.sig (distinct token) is left untouched"
W="${WORK}/t4.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|anchor-source.json.sig)
    exit 0
    ;;
esac
EOF
BEFORE="$(cat "$W")"
run "$W" >/dev/null; RC=$?
AFTER="$(cat "$W")"
[ "$RC" = 0 ] && [ "$BEFORE" = "$AFTER" ] \
	&& ok "T4 anchor-source.json.sig left untouched (out of this installer's scope)" \
	|| no "T4 (rc=$RC) — .sig token was disturbed or exit nonzero: $AFTER"

echo "[T5] a backup is written whenever a change is made, none when it's a no-op"
W="${WORK}/t5.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|anchor-source.json)
    exit 0
    ;;
esac
EOF
run "$W" >/dev/null
ls "${WORK}"/t5.sh.bak-* >/dev/null 2>&1 && ok "T5 backup written on change" || no "T5 no backup found after change"

W="${WORK}/t5b.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json)
    exit 0
    ;;
esac
EOF
run "$W" >/dev/null
if ls "${WORK}"/t5b.sh.bak-* >/dev/null 2>&1; then no "T5b unexpected backup on no-op"; else ok "T5b no backup on no-op"; fi

echo "[T6] unrelated entries elsewhere in the wrapper survive verbatim"
W="${WORK}/t6.sh"
cat > "$W" <<'EOF'
#!/bin/bash
# co-tenant note: do not touch peer-geo.json handling below
case "$1" in
  anchor-source.json|validator.json|peer-geo.json|node-health-recent.json|cycle-history.jsonl)
    dest="/home/deploy/metal/api/$1"
    ;;
  *)
    echo "rejected" >&2
    exit 1
    ;;
esac
EOF
run "$W" >/dev/null
grep -q 'node-health-recent.json|cycle-history.jsonl' "$W" \
	&& grep -q 'co-tenant note: do not touch peer-geo.json handling below' "$W" \
	&& grep -q 'echo "rejected" >&2' "$W" \
	&& ok "T6 unrelated lines/entries survive verbatim" \
	|| no "T6 unrelated content was disturbed: $(cat "$W")"

echo "[T7] resulting wrapper is still syntactically valid bash"
W="${WORK}/t7.sh"
cat > "$W" <<'EOF'
#!/bin/bash
case "$1" in
  anchor-source.json|validator.json)
    exit 0
    ;;
esac
EOF
run "$W" >/dev/null
bash -n "$W" && ok "T7 wrapper still parses as valid bash" || no "T7 wrapper is now invalid bash"

echo "[T8] missing wrapper file fails closed (exit 4), no crash"
if run "${WORK}/does-not-exist.sh" >/dev/null 2>&1; then
	no "T8 missing wrapper should fail, not succeed"
else
	RC=$?
	[ "$RC" = 4 ] && ok "T8 missing wrapper fails closed with exit 4" || no "T8 wrong exit code (rc=$RC, want 4)"
fi

echo "[T9] SKIP_SSH=1 without WRAPPER_FILE fails closed (parameter-expansion guard)"
if SKIP_SSH=1 bash "$INSTALLER" >/dev/null 2>&1; then
	no "T9 should fail without WRAPPER_FILE"
else
	ok "T9 fails closed without WRAPPER_FILE"
fi

# =============================================================================
# T10-T13: the REMOTE heredoc path (run_remote), parity checks against the
# same fixtures T1-T4 already proved for the local path. Before review
# round 1 these never ran at all -- the local and remote verification
# regexes had silently drifted (see file header).
# =============================================================================

echo "[T10] remote path: mid-list token removed"
W="${WORK}/t10.sh"
cat > "$W" <<'EOF'
case "$1" in
  anchor-source.json|validator.json|peer-geo.json|evidence.json)
    exit 0
    ;;
esac
EOF
OUT="$(run_remote "$W")"; RC=$?
if [ "$RC" = 0 ] && ! grep -qE 'anchor-source\.json[|)]' "$W" && grep -q 'validator.json|peer-geo.json|evidence.json' "$W"; then
	ok "T10 remote: token removed, siblings intact"
else
	no "T10 remote (rc=$RC); wrapper now: $(cat "$W" 2>/dev/null)"
fi
echo "$OUT" | grep -q 'OK: anchor-source.json removed' && ok "T10 remote: success message printed" || no "T10 remote: success message missing"

echo "[T11] remote path: end-of-list token removed"
W="${WORK}/t11.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|peer-geo.json|anchor-source.json)
    exit 0
    ;;
esac
EOF
run_remote "$W" >/dev/null; RC=$?
if [ "$RC" = 0 ] && ! grep -qE 'anchor-source\.json[|)]' "$W" && grep -qE '^\s*validator\.json\|peer-geo\.json\)' "$W"; then
	ok "T11 remote: end-of-list token removed cleanly"
else
	no "T11 remote (rc=$RC); wrapper now: $(cat "$W" 2>/dev/null)"
fi

echo "[T12] remote path: idempotent when token absent"
W="${WORK}/t12.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|peer-geo.json)
    exit 0
    ;;
esac
EOF
BEFORE="$(cat "$W")"
OUT="$(run_remote "$W")"; RC=$?
AFTER="$(cat "$W")"
[ "$RC" = 0 ] && ok "T12 remote: exit 0 when absent" || no "T12 remote: exit code (rc=$RC)"
[ "$BEFORE" = "$AFTER" ] && ok "T12 remote: file unchanged when token absent" || no "T12 remote: file was modified despite absence"
echo "$OUT" | grep -q 'nothing to remove' && ok "T12 remote: no-op message printed" || no "T12 remote: no-op message missing"

echo "[T13] remote path: anchor-source.json.sig (distinct token) left untouched"
W="${WORK}/t13.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|anchor-source.json.sig)
    exit 0
    ;;
esac
EOF
BEFORE="$(cat "$W")"
run_remote "$W" >/dev/null; RC=$?
AFTER="$(cat "$W")"
[ "$RC" = 0 ] && [ "$BEFORE" = "$AFTER" ] \
	&& ok "T13 remote: anchor-source.json.sig left untouched" \
	|| no "T13 remote (rc=$RC) — .sig token disturbed or exit nonzero: $AFTER"

# =============================================================================
# T14: REGRESSION GUARD — the exact case that caught the review-round-1 bug.
# sed lacks a `g` flag by design (fail-closed on a malformed/duplicated
# wrapper rather than silently rewriting it -- see the fix commit), so a
# wrapper with `anchor-source.json` appearing TWICE on one line, with NO
# leading whitespace, leaves one residual sitting at column 0 after the
# first occurrence is stripped. `[^.]anchor-source\.json[|)]` (the old
# remote-only check) requires a character to exist BEFORE the match, which
# column 0 never has, so it silently reported success while a real token
# still lingered. `anchor-source\.json[|)]` (used by both paths now) has
# no such blind spot. Both paths MUST now agree: exit 5, wrapper left with
# the literal token still present (not a false "removed").
# =============================================================================
echo "[T14] regression: duplicate token at column 0 -- local and remote MUST agree"
DUP_CONTENT='case "$1" in
anchor-source.json|anchor-source.json|validator.json)
exit 0
;;
esac'

W_LOCAL="${WORK}/t14-local.sh"
printf '%s\n' "$DUP_CONTENT" > "$W_LOCAL"
LOCAL_OUT="$(run "$W_LOCAL" 2>&1)"; LOCAL_RC=$?

W_REMOTE="${WORK}/t14-remote.sh"
printf '%s\n' "$DUP_CONTENT" > "$W_REMOTE"
REMOTE_OUT="$(run_remote "$W_REMOTE" 2>&1)"; REMOTE_RC=$?

[ "$LOCAL_RC" = 5 ] && ok "T14 local: fails closed (exit 5) on the duplicate-token wrapper" \
	|| no "T14 local: expected exit 5, got $LOCAL_RC"
[ "$REMOTE_RC" = 5 ] && ok "T14 remote: fails closed (exit 5) on the duplicate-token wrapper" \
	|| no "T14 remote: expected exit 5, got $REMOTE_RC (THIS is the review-round-1 bug if it's 0)"
[ "$LOCAL_RC" = "$REMOTE_RC" ] && ok "T14 local and remote AGREE on the outcome" \
	|| no "T14 local/remote DISAGREE: local=$LOCAL_RC remote=$REMOTE_RC — the exact drift this round fixes"
echo "$LOCAL_OUT" | grep -q 'still present after removal attempt' \
	&& ok "T14 local: reports the residual instead of false success" || no "T14 local: did not report the residual"
echo "$REMOTE_OUT" | grep -q 'still present after removal attempt' \
	&& ok "T14 remote: reports the residual instead of false success" || no "T14 remote: did not report the residual (would have said 'OK: removed' pre-fix)"
grep -qE 'anchor-source\.json[|)]' "$W_LOCAL" \
	&& ok "T14 local: the literal token is still verifiably present in the file" \
	|| no "T14 local: token unexpectedly gone — test fixture invalid"
grep -qE 'anchor-source\.json[|)]' "$W_REMOTE" \
	&& ok "T14 remote: the literal token is still verifiably present in the file" \
	|| no "T14 remote: token unexpectedly gone — test fixture invalid"

# =============================================================================
# T15: REGRESSION GUARD — review round 1's third finding. The old
# `bash -n "$WRAPPER" && echo "syntax OK"` never gated anything: bash -n's
# failure was simply discarded, so a wrapper left syntactically broken by
# the edit still printed "OK: ... still syntactically valid" and exited 0
# -- while it is the web host's SSH forced command, so shipping it broken
# silently kills every subsequent validator-host push. The fixture here is
# already missing its closing `esac` before the installer ever touches it
# (bash -n on it fails independently of this installer's edit -- this is
# deliberate: it isolates "does the gate fire and recover" from "can this
# specific sed transform ever itself produce a syntax error", which is not
# reproducible through this installer's narrow, single-token substitution).
# Both paths MUST: exit 6, and restore the wrapper to its pre-edit backup
# byte-for-byte (not just report an error and leave a mangled file).
# =============================================================================
echo "[T15] regression: syntax-gate actually gates (restore + exit 6), both paths"
BROKEN_CONTENT='case "$1" in
  anchor-source.json|validator.json)
    exit 0
    ;;'

W_LOCAL="${WORK}/t15-local.sh"
printf '%s\n' "$BROKEN_CONTENT" > "$W_LOCAL"
LOCAL_ORIG="$(cat "$W_LOCAL")"
LOCAL_OUT="$(run "$W_LOCAL" 2>&1)"; LOCAL_RC=$?
LOCAL_AFTER="$(cat "$W_LOCAL")"

W_REMOTE="${WORK}/t15-remote.sh"
printf '%s\n' "$BROKEN_CONTENT" > "$W_REMOTE"
REMOTE_ORIG="$(cat "$W_REMOTE")"
REMOTE_OUT="$(run_remote "$W_REMOTE" 2>&1)"; REMOTE_RC=$?
REMOTE_AFTER="$(cat "$W_REMOTE")"

[ "$LOCAL_RC" = 6 ] && ok "T15 local: exits 6 on a broken wrapper" || no "T15 local: expected exit 6, got $LOCAL_RC"
[ "$REMOTE_RC" = 6 ] && ok "T15 remote: exits 6 on a broken wrapper" || no "T15 remote: expected exit 6, got $REMOTE_RC"
echo "$LOCAL_OUT" | grep -q 'restoring from backup' && ok "T15 local: reports the restore" || no "T15 local: missing restore report"
echo "$REMOTE_OUT" | grep -q 'restoring from backup' && ok "T15 remote: reports the restore" || no "T15 remote: missing restore report"
[ "$LOCAL_AFTER" = "$LOCAL_ORIG" ] && ok "T15 local: wrapper byte-identical to pre-edit content (genuinely restored)" \
	|| no "T15 local: wrapper NOT restored — left mangled after a failed gate"
[ "$REMOTE_AFTER" = "$REMOTE_ORIG" ] && ok "T15 remote: wrapper byte-identical to pre-edit content (genuinely restored)" \
	|| no "T15 remote: wrapper NOT restored — left mangled after a failed gate"
echo "$LOCAL_OUT" | grep -q 'OK: anchor-source.json removed' \
	&& no "T15 local: falsely reported success despite the syntax failure" \
	|| ok "T15 local: does not report false success"
echo "$REMOTE_OUT" | grep -q 'OK: anchor-source.json removed' \
	&& no "T15 remote: falsely reported success despite the syntax failure" \
	|| ok "T15 remote: does not report false success"

echo
echo "----------------------------------------"
echo "RESULTS: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"
exit 1
