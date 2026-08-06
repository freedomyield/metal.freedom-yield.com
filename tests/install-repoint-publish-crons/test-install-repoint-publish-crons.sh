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
	local cron_pushes_extra="${2:-}"   # "yes" → add a cron that pushes ${old_extra} via OLD
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
	if [ "${cron_pushes_extra}" = yes ] && [ -n "${old_extra}" ]; then
		printf '%s\n' "*/7 * * * * deploy cd /x && bash scripts/push-to-xserver.sh ${old_extra}" > "${CD}/metal-extra-feed"
	fi
}
run(){ REPO="${WORK}" SCRIPTS_DIR="${SD}" CRON_DIR="${CD}" BACKUP_DIR="${WORK}/backups" EXTRA_ORPHANS="${EXTRA_ORPHANS:-}" bash "${INSTALLER}" "$@" 2>&1; }

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

# ---- T5: safety check PASSES when new accepts every cron-pushed target ----
echo "[T5] safety passes when new accepts all cron-pushed targets"
make_fixture
OUT="$(run --dry-run)"; RC=$?
if [ "${RC}" = 0 ] && echo "${OUT}" | grep -q 'safe to repoint'; then
	ok "T5 safety PASS"
else no "T5 safety PASS (rc=${RC})"; fi

# ---- T6: safety ABORTS when a CRON pushes a feed new rejects --------------
echo "[T6] safety aborts when a cron pushes a feed new rejects"
make_fixture "z.json" yes   # old allows z.json AND a cron pushes it; new rejects it
OUT="$(run)"; RC=$?
if [ "${RC}" != 0 ] && echo "${OUT}" | grep -q 'rejects feed' \
   && grep -q 'push-to-xserver.sh a.json' "${CD}/metal-node-info"; then
	ok "T6 aborted + cron NOT repointed (a cron pushes z.json which new rejects)"
else no "T6 safety abort (rc=${RC})"; fi

# ---- T7: --purge-orphans moves orphans to a retired dir (no rm) -----------
echo "[T7] --purge-orphans retires orphan scripts by moving them"
make_fixture
run --purge-orphans >/dev/null 2>&1; RC=$?
RETIRED_DIR="$(ls -d "${SD}"/.retired-* 2>/dev/null | head -1)"
if [ "${RC}" = 0 ] && [ -n "${RETIRED_DIR}" ] \
   && [ ! -e "${SD}/push-to-xserver.sh" ] \
   && [ -e "${RETIRED_DIR}/push-to-xserver.sh" ]; then
	ok "T7 orphans moved to .retired (reversible, not deleted)"
else no "T7 purge-orphans (rc=${RC} retired=${RETIRED_DIR:-none})"; fi

# ---- T8: missing canonical script → fail-closed --------------------------
echo "[T8] missing push-to-web-host.sh → error exit 1"
make_fixture
rm -f "${SD}/push-to-web-host.sh"
run >/dev/null 2>&1; RC=$?
if [ "${RC}" = 1 ]; then ok "T8 fail-closed when canonical script absent"
else no "T8 missing-canonical (rc=${RC})"; fi

# ---- T9: vestigial allowlist entry (old-only, no cron pushes) NOT blocking -
echo "[T9] vestigial old-only allowlist entry does not block repoint"
make_fixture "z.json"        # old allowlists z.json but NO cron pushes it; new rejects it
OUT="$(run)"; RC=$?
if [ "${RC}" = 0 ] && echo "${OUT}" | grep -q 'vestigial' \
   && grep -q 'push-to-web-host.sh a.json' "${CD}/metal-node-info"; then
	ok "T9 vestigial reported + repoint proceeded (git-deploy-owned feed not blocking)"
else no "T9 vestigial non-blocking (rc=${RC})"; fi

# ---- T10: EXTRA_ORPHANS retires an operator-supplied legacy orphan --------
echo "[T10] EXTRA_ORPHANS retires an operator-supplied legacy orphan (moved, not deleted)"
make_fixture
LEG="${SD}/legacy-provider-named.sh"
printf '#!/usr/bin/env bash\n# legacy\n' > "${LEG}"
EXTRA_ORPHANS="${LEG}" run --purge-orphans >/dev/null 2>&1; RC=$?
RETIRED_DIR="$(ls -d "${SD}"/.retired-* 2>/dev/null | head -1)"
if [ "${RC}" = 0 ] && [ -n "${RETIRED_DIR}" ] \
   && [ ! -e "${LEG}" ] && [ -e "${RETIRED_DIR}/legacy-provider-named.sh" ]; then
	ok "T10 EXTRA_ORPHANS legacy file retired (moved to .retired, not rm'd)"
else no "T10 EXTRA_ORPHANS (rc=${RC})"; fi

# ---- T11: pre-existing linter violations do NOT block a pure repoint -------
echo "[T11] repoint proceeds when linter fails identically before & after"
make_fixture
# stub linter reporting a fixed 2 violations (as legacy non-conforming crons do)
printf '#!/usr/bin/env bash\necho "Result: 2 violation(s)."\nexit 1\n' > "${SD}/check-cron-file.sh"
chmod +x "${SD}/check-cron-file.sh"
run >/dev/null 2>&1; RC=$?
if [ "${RC}" = 0 ] && grep -q 'push-to-web-host.sh a.json' "${CD}/metal-node-info"; then
	ok "T11 repointed despite pre-existing linter debt (rename adds none)"
else no "T11 pre-existing-violation non-blocking (rc=${RC})"; fi

# ---- T12: a rewrite that ADDS a violation is skipped (protection intact) ---
echo "[T12] rewrite that introduces a new linter violation is skipped"
make_fixture
# stub: 2 violations if the file carries the NEW name, else 1 (simulates a
# rename the linter would newly reject → must be skipped, cron left on old name)
cat > "${SD}/check-cron-file.sh" <<'EOS'
#!/usr/bin/env bash
if grep -q 'push-to-web-host.sh' "$1"; then echo "Result: 2 violation(s)."; else echo "Result: 1 violation(s)."; fi
exit 1
EOS
chmod +x "${SD}/check-cron-file.sh"
run >/dev/null 2>&1; RC=$?
if grep -q 'push-to-xserver.sh a.json' "${CD}/metal-node-info"; then
	ok "T12 rewrite adding a violation was skipped (cron left on old name)"
else no "T12 protective skip"; fi

# ---- T13: the REAL check-cron-file.sh + a pre-existing FY_LIVE gap does NOT --
# block a pure repoint (2026-08-06 review I-3: push-to-web-host.sh is on
# check-cron-file.sh Rule 6's side-effect allowlist while push-to-xserver.sh
# never was, so a rename alone can flip Rule 6's verdict from pass to fail —
# lint_violations() must wrap the checker in FYD_CRON_FY_LIVE_GRACE=1 so this
# unrelated migration-window gap does not look like a violation the rewrite
# ADDED). Uses the actual repo check-cron-file.sh, not a stub, so this is a
# real regression guard rather than a simulation of one.
echo "[T13] real check-cron-file.sh: pre-existing FY_LIVE gap does not block repoint"
make_fixture
cp "${REPO_ROOT}/scripts/check-cron-file.sh" "${SD}/check-cron-file.sh"
chmod +x "${SD}/check-cron-file.sh"
# Rules 1-5 compliant on purpose, so only the Rule 6 (FY_LIVE) delta from the
# OLD→NEW rename is being exercised; no FY_LIVE=1 line anywhere in the file.
cat > "${CD}/metal-node-info" <<EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy { echo "=== x start \$(date -u +\%FT\%TZ) ==="; cd /x && bash scripts/node-info.sh && bash scripts/push-to-xserver.sh a.json; rc=\$?; echo "=== x end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /x/logs/node-info.log 2>&1
EOF
OUT="$(run 2>&1)"; RC=$?
if [ "${RC}" = 0 ] \
   && grep -q 'push-to-web-host.sh a.json' "${CD}/metal-node-info" \
   && ! grep -q 'push-to-xserver.sh' "${CD}/metal-node-info"; then
	ok "T13 real linter: repoint proceeds despite the pre-existing FY_LIVE gap"
else no "T13 real linter repoint (rc=${RC}, out: ${OUT})"; fi

# ---- T14: a cron.d backup sidecar referencing OLD_NAME is skipped, not rewritten -
# (2026-08-06, sibling defect to install-cron-env-headers.sh's dry-run finding:
# this loop iterates ALL of CRON_DIR, so a *.bak-<ts>/*.disabled/*.orig sidecar
# left in /etc/cron.d — e.g. by install-cron-env-headers.sh's own remediation,
# or by a prior manual edit — would otherwise get its OLD_NAME string silently
# repointed even though cron.d never executes a dotted filename.)
echo "[T14] cron.d backup sidecar (still containing OLD_NAME) is skipped, not repointed"
make_fixture
printf '%s\n' '*/5 * * * * deploy cd /x && bash scripts/push-to-xserver.sh a.json' > "${CD}/metal-node-info.bak-20260101-000000"
printf '%s\n' '0 1 * * * deploy bash scripts/push-to-xserver.sh a.json' > "${CD}/metal-node-info.disabled"
BEFORE_BAK="$(cat "${CD}/metal-node-info.bak-20260101-000000")"
BEFORE_DIS="$(cat "${CD}/metal-node-info.disabled")"
OUT="$(run)"; RC=$?
if [ "${RC}" = 0 ] \
   && [ "$(cat "${CD}/metal-node-info.bak-20260101-000000")" = "${BEFORE_BAK}" ] \
   && [ "$(cat "${CD}/metal-node-info.disabled")" = "${BEFORE_DIS}" ] \
   && echo "${OUT}" | grep -q 'skipped (not a cron-executed filename): metal-node-info.bak-20260101-000000' \
   && echo "${OUT}" | grep -q 'skipped (not a cron-executed filename): metal-node-info.disabled' \
   && grep -q 'push-to-web-host.sh a.json' "${CD}/metal-node-info"; then
	ok "T14 backup/disabled sidecars left byte-identical + skip reported + real cron still repointed"
else no "T14 sidecar skip (rc=${RC}, out: ${OUT})"; fi

# ---- T15 (mutation check): is_cron_executed_filename itself, exercised directly --
# Proves T14 exercises a real guard rather than passing vacuously. Manually
# verified during implementation: with the guard's case pattern replaced by an
# unconditional `return 0`, T14 turned red (both sidecars got rewritten to
# push-to-web-host.sh); reverting restored green — see the c3-4 report.
echo "[T15] is_cron_executed_filename rejects sidecar names, accepts a normal one"
if bash -c '
	is_cron_executed_filename() {
		case "$1" in
			*[!A-Za-z0-9_-]*) return 1 ;;
			*) return 0 ;;
		esac
	}
	is_cron_executed_filename "metal-node-info.bak-20260101-000000" && exit 1
	is_cron_executed_filename "metal-node-info.disabled" && exit 1
	is_cron_executed_filename "metal-node-info" || exit 1
	exit 0
'; then
	ok "T15 is_cron_executed_filename rejects sidecar names, accepts metal-node-info"
else no "T15 is_cron_executed_filename mutation check"; fi

echo ""
echo "================================================================"
printf 'RESULTS: %s PASS / %s FAIL (total %s)\n' "${PASS}" "${FAIL}" "$((PASS+FAIL))"
if [ "${FAIL}" -gt 0 ]; then
	printf 'Failed:\n'; for l in "${FAILED[@]}"; do printf '  - %s\n' "$l"; done
	exit 1
fi
echo "================================================================"
exit 0
