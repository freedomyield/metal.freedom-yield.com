#!/usr/bin/env bash
# test-install-repoint-publish-crons.sh
# Scenario tests for scripts/install-repoint-publish-crons.sh.
# Uses CRON_DIR / SCRIPTS_DIR / REPO env overrides against tmp fixtures.
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-repoint-publish-crons.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  ✗ %s\n' "$1"; }

WORK=""; SD=""; CD=""
cleanup(){ [ -n "${WORK}" ] && rm -rf "${WORK}"; }
trap cleanup EXIT

# make_fixture <old_extra_token>
# Builds a scripts dir (canonical + old publish scripts + checker stub) and a
# cron.d dir (one cron on the OLD name, one already on the NEW name). If
# <old_extra_token> is given, the OLD script additionally allows that token so
# the superset check can be exercised as failing.
make_fixture(){
	local old_extra="${1:-}"
	WORK="$(mktemp -d -t repoint.XXXXXX)"
	SD="${WORK}/scripts"; CD="${WORK}/cron.d"
	mkdir -p "${SD}" "${CD}"
	cat > "${SD}/push-to-web-host.sh" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  a.json|b.json|c.jsonl|schedule.ics) : ;;
  *.ics) : ;;
  *) exit 1 ;;
esac
EOS
	cat > "${SD}/push-to-xserver.sh" <<EOS
#!/usr/bin/env bash
case "\$1" in
  a.json|b.json|schedule.ics${old_extra:+|${old_extra}}) : ;;
  *) exit 1 ;;
esac
EOS
	chmod +x "${SD}/push-to-web-host.sh" "${SD}/push-to-xserver.sh"
	printf '#!/usr/bin/env bash\nexit 0\n' > "${SD}/check-cron-file.sh"
	chmod +x "${SD}/check-cron-file.sh"
	printf '%s\n' '*/5 * * * * deploy cd /x && bash scripts/node-info.sh && bash scripts/push-to-xserver.sh a.json' > "${CD}/metal-node-info"
	printf '%s\n' '0 4 * * * deploy cd /x && bash scripts/push-to-web-host.sh b.json' > "${CD}/metal-already-new"
	printf 'stale\n' > "${SD}/push-to-xserver.sh.bak-20260101-000000"
	printf '#!/usr/bin/env bash\n# retired sync\n' > "${SD}/sync-to-hetzner.sh"
	chmod +x "${SD}/sync-to-hetzner.sh"
}
run(){ REPO="${WORK}" SCRIPTS_DIR="${SD}" CRON_DIR="${CD}" BACKUP_DIR="${WORK}/backups" bash "${INSTALLER}" "$@" 2>&1; }

echo "================================================================"
echo "install-repoint-publish-crons.sh — scenario tests"
echo "================================================================"

# ---- T1: --dry-run touches nothing --------------------------------------
echo "[T1] --dry-run previews but modifies nothing"
make_fixture
OUT="$(run --dry-run)"; RC=$?
if [ "${RC}" = 0 ] && grep -q 'push-to-xserver.sh a.json' "${CD}/metal-node-info" \
   && echo "${OUT}" | grep -q 'would repoint'; then
	ok "T1 dry-run left cron on old name + previewed"
else no "T1 dry-run (rc=${RC})"; fi

# ---- T2: apply repoints the old-name cron, keeps a backup ----------------
echo "[T2] apply repoints old-name cron + writes backup"
make_fixture
run >/dev/null 2>&1; RC=$?
if [ "${RC}" = 0 ] \
   && grep -q 'push-to-web-host.sh a.json' "${CD}/metal-node-info" \
   && ! grep -q 'push-to-xserver.sh' "${CD}/metal-node-info" \
   && ls "${WORK}"/backups/*/metal-node-info >/dev/null 2>&1; then
	ok "T2 repointed old→new + backup present (outside cron dir)"
else no "T2 repoint (rc=${RC})"; fi

# ---- T3: cron already on the new name is left untouched (no backup) -------
echo "[T3] cron already on new name is untouched"
if grep -q 'push-to-web-host.sh b.json' "${CD}/metal-already-new" \
   && ! ls "${WORK}"/backups/*/metal-already-new >/dev/null 2>&1; then
	ok "T3 already-new cron untouched"
else no "T3 already-new cron"; fi

# ---- T4: idempotent — second apply repoints nothing ----------------------
echo "[T4] second apply is a no-op"
OUT="$(run)"; RC=$?
if [ "${RC}" = 0 ] && echo "${OUT}" | grep -q 'nothing to repoint'; then
	ok "T4 idempotent second run"
else no "T4 idempotent (rc=${RC})"; fi

# ---- T5: superset check PASSES when new ⊇ old ----------------------------
echo "[T5] superset check passes when new allows all old targets"
make_fixture
OUT="$(run --dry-run)"; RC=$?
if [ "${RC}" = 0 ] && echo "${OUT}" | grep -q 'allows every target'; then
	ok "T5 superset PASS"
else no "T5 superset PASS (rc=${RC})"; fi

# ---- T6: superset check ABORTS when old allows a target new does not -----
echo "[T6] superset check aborts when old allows a target new rejects"
make_fixture "z.json"
OUT="$(run)"; RC=$?
if [ "${RC}" != 0 ] && echo "${OUT}" | grep -q 'does NOT allow' \
   && grep -q 'push-to-xserver.sh a.json' "${CD}/metal-node-info"; then
	ok "T6 aborted + cron NOT repointed (z.json would be rejected)"
else no "T6 superset abort (rc=${RC})"; fi

# ---- T7: --purge-orphans moves orphans to a retired dir (no rm) -----------
echo "[T7] --purge-orphans retires orphan scripts by moving them"
make_fixture
run --purge-orphans >/dev/null 2>&1; RC=$?
RETIRED_DIR="$(ls -d "${SD}"/.retired-* 2>/dev/null | head -1)"
if [ "${RC}" = 0 ] && [ -n "${RETIRED_DIR}" ] \
   && [ ! -e "${SD}/push-to-xserver.sh" ] \
   && [ -e "${RETIRED_DIR}/push-to-xserver.sh" ] \
   && [ -e "${RETIRED_DIR}/sync-to-hetzner.sh" ]; then
	ok "T7 orphans moved to .retired (reversible, not deleted)"
else no "T7 purge-orphans (rc=${RC} retired=${RETIRED_DIR:-none})"; fi

# ---- T8: missing canonical script → fail-closed --------------------------
echo "[T8] missing push-to-web-host.sh → error exit 1"
make_fixture
rm -f "${SD}/push-to-web-host.sh"
run >/dev/null 2>&1; RC=$?
if [ "${RC}" = 1 ]; then ok "T8 fail-closed when canonical script absent"
else no "T8 missing-canonical (rc=${RC})"; fi

echo ""
echo "================================================================"
printf 'RESULTS: %s PASS / %s FAIL (total %s)\n' "${PASS}" "${FAIL}" "$((PASS+FAIL))"
if [ "${FAIL}" -gt 0 ]; then
	printf 'Failed:\n'; for l in "${FAILED[@]}"; do printf '  - %s\n' "$l"; done
	exit 1
fi
echo "================================================================"
exit 0
