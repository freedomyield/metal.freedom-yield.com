#!/usr/bin/env bash
# tests/install-xserver-sig-allowlist/test-install-xserver-sig-allowlist.sh
# Scenario tests for scripts/install-xserver-sig-allowlist.sh (local
# SKIP_SSH mode) — no real host is ever contacted.
#
# CHAIN: none — pure local file editing via SKIP_SSH=1 WRAPPER_FILE=<path>,
# the same convention tests/install-xserver-static-deploy-key already
# exercises for that script. PRIME_DIRECTIVE: safe (no SSH, no broadcast).
#
# Background (2026-08-06): this script used to ADD `anchor-source.json.sig`,
# `anchor-receipt.json.sig`, and `identity.json.sig` to the Xserver
# receive-wrapper allowlist. None of the three has ever had a legitimate
# reason to be pushed over that path: the first two have no producer
# anywhere in the repo (no script ever signs either file), and the third
# (identity.json.sig) genuinely exists but is git-deploy owned — the same
# architectural pattern as anchor-source.json — so push-to-web-host.sh's
# sender allowlist has never carried it either. The script was flipped to
# do the OPPOSITE: remove all three tokens if a prior run ever added them,
# independently (not assuming they stayed contiguous), idempotently.
#
# Usage:
#   bash tests/install-xserver-sig-allowlist/test-install-xserver-sig-allowlist.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
INSTALLER="${REPO}/scripts/install-xserver-sig-allowlist.sh"

[ -f "$INSTALLER" ] || { echo "FATAL: installer not found at $INSTALLER" >&2; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

WORK=""; cleanup(){ [ -n "${WORK}" ] && rm -rf "${WORK}"; }; trap cleanup EXIT
WORK="$(mktemp -d)"

run(){ SKIP_SSH=1 WRAPPER_FILE="$1" bash "$INSTALLER"; }
any_sig_token_present(){ grep -qE '(anchor-source\.json\.sig|anchor-receipt\.json\.sig|identity\.json\.sig)[|)]' "$1"; }

echo "================================================================"
echo "install-xserver-sig-allowlist.sh — scenario tests"
echo "================================================================"

echo "[T1] all three tokens, contiguous mid-list (matches the pre-2026-08-06 add-installer's exact insert shape), all removed"
W="${WORK}/t1.sh"
cat > "$W" <<'EOF'
case "$1" in
  anchor-source.json.sig|anchor-receipt.json.sig|identity.json.sig|validator.json|peer-geo.json)
    exit 0
    ;;
esac
EOF
OUT="$(run "$W")"; RC=$?
if [ "$RC" = 0 ] && ! any_sig_token_present "$W" && grep -q 'validator.json|peer-geo.json' "$W"; then
	ok "T1 all three tokens removed, siblings intact"
else
	no "T1 (rc=$RC); wrapper now: $(cat "$W" 2>/dev/null)"
fi
echo "$OUT" | grep -q 'OK: .sig allowlist entries removed' && ok "T1 success message printed" || no "T1 success message missing"

echo "[T2] three tokens scattered (not contiguous), one at end-of-list -- each removed independently"
W="${WORK}/t2.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|anchor-source.json.sig|peer-geo.json|identity.json.sig|anchor-receipt.json.sig)
    exit 0
    ;;
esac
EOF
run "$W" >/dev/null; RC=$?
if [ "$RC" = 0 ] && ! any_sig_token_present "$W" && grep -qE '^\s*validator\.json\|peer-geo\.json\)' "$W"; then
	ok "T2 scattered tokens all removed, siblings intact"
else
	no "T2 (rc=$RC); wrapper now: $(cat "$W" 2>/dev/null)"
fi

echo "[T3] only ONE of the three tokens present -- removed without disturbing siblings"
W="${WORK}/t3.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|identity.json.sig|peer-geo.json)
    exit 0
    ;;
esac
EOF
run "$W" >/dev/null; RC=$?
if [ "$RC" = 0 ] && ! grep -qE 'identity\.json\.sig[|)]' "$W" && grep -q 'validator.json|peer-geo.json' "$W"; then
	ok "T3 single present token removed cleanly"
else
	no "T3 (rc=$RC); wrapper now: $(cat "$W" 2>/dev/null)"
fi

echo "[T4] idempotent: none present -> no-op, exit 0, file byte-identical"
W="${WORK}/t4.sh"
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
[ "$RC" = 0 ] && ok "T4 exit 0 when absent" || no "T4 exit code (rc=$RC)"
[ "$BEFORE" = "$AFTER" ] && ok "T4 file unchanged when tokens absent" || no "T4 file was modified despite absence"
echo "$OUT" | grep -q 'nothing to remove' && ok "T4 no-op message printed" || no "T4 no-op message missing"

echo "[T5] the flat anchor-source.json token (distinct, handled by the OTHER installer) is left untouched"
W="${WORK}/t5.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|anchor-source.json)
    exit 0
    ;;
esac
EOF
BEFORE="$(cat "$W")"
run "$W" >/dev/null; RC=$?
AFTER="$(cat "$W")"
[ "$RC" = 0 ] && [ "$BEFORE" = "$AFTER" ] \
	&& ok "T5 flat anchor-source.json left untouched (out of this installer's scope)" \
	|| no "T5 (rc=$RC) — flat token was disturbed or exit nonzero: $AFTER"

echo "[T6] a backup is written whenever a change is made, none when it's a no-op"
W="${WORK}/t6.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json|identity.json.sig)
    exit 0
    ;;
esac
EOF
run "$W" >/dev/null
ls "${WORK}"/t6.sh.bak-* >/dev/null 2>&1 && ok "T6 backup written on change" || no "T6 no backup found after change"

W="${WORK}/t6b.sh"
cat > "$W" <<'EOF'
case "$1" in
  validator.json)
    exit 0
    ;;
esac
EOF
run "$W" >/dev/null
if ls "${WORK}"/t6b.sh.bak-* >/dev/null 2>&1; then no "T6b unexpected backup on no-op"; else ok "T6b no backup on no-op"; fi

echo "[T7] unrelated entries elsewhere in the wrapper survive verbatim"
W="${WORK}/t7.sh"
cat > "$W" <<'EOF'
#!/bin/bash
# co-tenant note: do not touch peer-geo.json handling below
case "$1" in
  anchor-source.json.sig|anchor-receipt.json.sig|identity.json.sig|validator.json|peer-geo.json|node-health-recent.json)
    dest="/home/deploy/metal/api/$1"
    ;;
  *)
    echo "rejected" >&2
    exit 1
    ;;
esac
EOF
run "$W" >/dev/null
grep -q 'validator.json|peer-geo.json|node-health-recent.json' "$W" \
	&& grep -q 'co-tenant note: do not touch peer-geo.json handling below' "$W" \
	&& grep -q 'echo "rejected" >&2' "$W" \
	&& ok "T7 unrelated lines/entries survive verbatim" \
	|| no "T7 unrelated content was disturbed: $(cat "$W")"

echo "[T8] resulting wrapper is still syntactically valid bash"
W="${WORK}/t8.sh"
cat > "$W" <<'EOF'
#!/bin/bash
case "$1" in
  anchor-source.json.sig|anchor-receipt.json.sig|identity.json.sig|validator.json)
    exit 0
    ;;
esac
EOF
run "$W" >/dev/null
bash -n "$W" && ok "T8 wrapper still parses as valid bash" || no "T8 wrapper is now invalid bash"

echo "[T9] missing wrapper file fails closed (exit 4), no crash"
if run "${WORK}/does-not-exist.sh" >/dev/null 2>&1; then
	no "T9 missing wrapper should fail, not succeed"
else
	RC=$?
	[ "$RC" = 4 ] && ok "T9 missing wrapper fails closed with exit 4" || no "T9 wrong exit code (rc=$RC, want 4)"
fi

echo "[T10] SKIP_SSH=1 without WRAPPER_FILE fails closed (parameter-expansion guard)"
if SKIP_SSH=1 bash "$INSTALLER" >/dev/null 2>&1; then
	no "T10 should fail without WRAPPER_FILE"
else
	ok "T10 fails closed without WRAPPER_FILE"
fi

echo
echo "----------------------------------------"
echo "RESULTS: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"
exit 1
