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

echo
echo "----------------------------------------"
echo "RESULTS: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"
exit 1
