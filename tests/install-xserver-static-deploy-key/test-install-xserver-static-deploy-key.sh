#!/usr/bin/env bash
# Scenario tests for scripts/install-xserver-static-deploy-key.sh (local mode).
# Exercises the SKIP_SSH=1 local-file path so no real host is contacted.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
INSTALLER="${REPO}/scripts/install-xserver-static-deploy-key.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

WORK=""; cleanup(){ [ -n "${WORK}" ] && rm -rf "${WORK}"; }; trap cleanup EXIT

setup(){
  WORK="$(mktemp -d)"
  AK="${WORK}/authorized_keys"
  # a pre-existing UNRELATED entry (co-tenant project) that must survive
  printf 'command="rrsync -ro /home/other/project",no-pty ssh-ed25519 AAAAOTHER other@x\n' > "${AK}"
  PUB="${WORK}/ci.pub"
  printf 'ssh-ed25519 AAAACIKEYDATA freedom-yield-static-deploy\n' > "${PUB}"
}
run(){ SKIP_SSH=1 AUTHORIZED_KEYS_FILE="${AK}" CI_PUBKEY="${PUB}" \
       WEB_ROOT="/home/acct/metal.freedom-yield.com/public" \
       XSERVER_HOST="unused-in-local" bash "${INSTALLER}" "$@" 2>&1; }

echo "================================================================"
echo "install-xserver-static-deploy-key.sh — scenario tests"
echo "================================================================"

echo "[T1] installs a restricted line for the CI key"
setup; OUT="$(run)"; RC=$?
if [ "${RC}" = 0 ] \
   && grep -q 'command="rrsync -wo /home/acct/metal.freedom-yield.com/public"' "${AK}" \
   && grep -q 'freedom-yield-static-deploy' "${AK}" \
   && grep -q 'no-pty' "${AK}"; then ok "T1 restricted line installed"; else no "T1 (rc=${RC})"; fi

echo "[T2] the unrelated co-tenant entry is untouched"
grep -q 'AAAAOTHER other@x' "${AK}" && ok "T2 other entry preserved" || no "T2 other entry lost"

echo "[T3] a backup was written"
ls "${AK}".bak-* >/dev/null 2>&1 && ok "T3 backup present" || no "T3 no backup"

echo "[T4] idempotent — second run makes no change and exits 0"
cp "${AK}" "${WORK}/ak.before"; OUT="$(run)"; RC=$?
if [ "${RC}" = 0 ] && cmp -s "${AK}" "${WORK}/ak.before"; then ok "T4 idempotent"; else no "T4 (rc=${RC})"; fi

echo "[T5] fails closed when CI_PUBKEY missing"
setup; if CI_PUBKEY="${WORK}/nope.pub" SKIP_SSH=1 AUTHORIZED_KEYS_FILE="${AK}" \
        WEB_ROOT="/home/acct/x/public" XSERVER_HOST=u bash "${INSTALLER}" >/dev/null 2>&1; then
  no "T5 should fail"; else ok "T5 fails closed on missing pubkey"; fi

echo ""
printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
