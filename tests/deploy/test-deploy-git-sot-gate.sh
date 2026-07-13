#!/usr/bin/env bash
# Regression gate: the 2026-07-13 delivery-ownership inversion (git is the
# ONLY delivery path for tracked files; rsync ships public/ only) must never
# silently regress back to a whole-repo rsync, and its self-heal machinery
# must stay wired exactly once.
#
# CHAIN: none — pure static grep of the workflow file + the advance script.
# No network, no SSH, no docker, no real deploy.
#
# This is the ARCHITECTURE-level tripwire, one layer above the per-block
# pins already carried by:
#   - tests/deploy/test-host-rsync-excludes.sh    (advance step shape, the
#     public/ rsync step's exact source/dest + flags, step order)
#   - tests/deploy/test-caddyfile-stale-mount-heal.sh (Caddy step's
#     cmp/reload/force-recreate/health-check content)
# Those two pin what each block currently looks like. This suite instead
# pins invariants that must hold regardless of how those blocks are worded —
# so a future edit that satisfies the letter of the per-block tests but
# reintroduces the old architecture (e.g. a second, differently-named
# whole-repo rsync step; a duplicated self-heal call; a health check that
# only guards one branch of the reload/force-recreate conditional) still
# gets caught here.
#
# Env overrides (test-time only):
#   FYD_WORKFLOW_FILE   path to the workflow file to check (default: this
#                       repo's .github/workflows/deploy.yml). Lets this gate
#                       itself be exercised against a deliberately broken
#                       copy — see the "prove it fails" runs in this task's
#                       report.
#
# scripts/advance-host-checkout.sh and
# scripts/install-metal-host-advance-cron.sh are always checked against
# their real repo paths (not override-able) — see the task report for why.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
WORKFLOW="${FYD_WORKFLOW_FILE:-${REPO}/.github/workflows/deploy.yml}"
ADVANCE_SCRIPT="${REPO}/scripts/advance-host-checkout.sh"
CRON_INSTALLER="${REPO}/scripts/install-metal-host-advance-cron.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

[ -f "${WORKFLOW}" ] || { echo "FAIL: workflow not found at ${WORKFLOW}" >&2; exit 1; }
[ -f "${ADVANCE_SCRIPT}" ] || { echo "FAIL: advance script not found at ${ADVANCE_SCRIPT}" >&2; exit 1; }

# --- 1. self_heal_lossless_dirt is defined exactly once and called exactly
#        once outside its own definition. Two of it (or zero calls) is
#        exactly the kind of drift a future refactor could introduce
#        silently — e.g. an accidental double-call that heals twice, or a
#        definition left orphaned after a call site is moved/deleted.
#        Both counts accept leading indentation, and the definition count
#        covers BOTH bash definition styles (`name() {` and
#        `function name {` / `function name() {`) so an indented or
#        function-keyword shadow duplicate cannot slip past the gate. ---
DEF_COUNT="$(grep -c -E '^[[:space:]]*(self_heal_lossless_dirt\(\)|function[[:space:]]+self_heal_lossless_dirt([[:space:]]*\(\))?)[[:space:]]*\{' "${ADVANCE_SCRIPT}")"
if [ "${DEF_COUNT}" -eq 1 ]; then
  ok "scripts/advance-host-checkout.sh defines self_heal_lossless_dirt() exactly once"
else
  no "scripts/advance-host-checkout.sh defines self_heal_lossless_dirt() ${DEF_COUNT} time(s) (expected exactly 1)"
fi

# Call = a line that is nothing but the bare function name, at ANY
# indentation — a second call nested inside an if/loop body must count
# too, not just column-0 calls. The definition line never matches: it
# continues with `() {`.
CALL_COUNT="$(grep -c -E '^[[:space:]]*self_heal_lossless_dirt[[:space:]]*$' "${ADVANCE_SCRIPT}")"
if [ "${CALL_COUNT}" -eq 1 ]; then
  ok "scripts/advance-host-checkout.sh calls self_heal_lossless_dirt exactly once outside its definition"
else
  no "scripts/advance-host-checkout.sh calls self_heal_lossless_dirt ${CALL_COUNT} time(s) outside its definition (expected exactly 1)"
fi

# --- 2. the whole-repo rsync shape must never come back, anywhere in the
#        file — not just in the block the per-block test already isolates.
#        Regex per task-4 brief: a transfer source of literal repo root
#        "./" piped straight into "$SSH_USER@$SSH_HOST:". ---
if grep -Eq -- '\./ "\$SSH_USER@\$SSH_HOST:' "${WORKFLOW}"; then
  no "workflow contains a whole-repo-root rsync transfer source (matches '\\./ \"\$SSH_USER@\$SSH_HOST:') — the whole-repo shape must never come back"
else
  ok "no whole-repo-root rsync transfer source anywhere in the workflow (regex '\\./ \"\$SSH_USER@\$SSH_HOST:' not found)"
fi

# --- 3. every rsync/ssh destination in the validator-host leg (between the
#        "Advance host checkout" step and the "Set up Xserver deploy key"
#        step, i.e. everything that runs against the validator host, not
#        the separate Xserver public-origin leg below it) must land under
#        $DEPLOY_PATH/public/ — never the bare $DEPLOY_PATH root. ---
ADV_LINE="$(grep -n -F -- '- name: Advance host checkout to origin/main' "${WORKFLOW}" | head -1 | cut -d: -f1)"
RSYNC_LINE="$(grep -n -F -- '- name: Rsync public/ to VPS' "${WORKFLOW}" | head -1 | cut -d: -f1)"
CADDY_LINE="$(grep -n -F -- '- name: Bring up / reload Caddy on VPS' "${WORKFLOW}" | head -1 | cut -d: -f1)"
XS_LINE="$(grep -n -F -- '- name: Set up Xserver deploy key' "${WORKFLOW}" | head -1 | cut -d: -f1)"

if [ -n "${ADV_LINE}" ] && [ -n "${XS_LINE}" ] && [ "${ADV_LINE}" -lt "${XS_LINE}" ]; then
  LEG_BLOCK="$(sed -n "${ADV_LINE},$((XS_LINE - 1))p" "${WORKFLOW}")"
  DEST_LINES="$(printf '%s\n' "${LEG_BLOCK}" | grep -F -- '"$SSH_USER@$SSH_HOST:' || true)"
  if [ -z "${DEST_LINES}" ]; then
    no "validator-host leg (Advance host checkout .. Set up Xserver deploy key) has no rsync/ssh destination lines to check — expected at least the public/ rsync destination"
  else
    # Suffix-anchored, not substring containment: the destination must END
    # with :$DEPLOY_PATH/public/" — a traversal shape like
    # :$DEPLOY_PATH/public/../secrets/ must not pass as "contains /public/".
    BAD_DEST="$(printf '%s\n' "${DEST_LINES}" | grep -v -E -- ':\$DEPLOY_PATH/public/"[[:space:]]*$' || true)"
    if [ -z "${BAD_DEST}" ]; then
      DEST_COUNT="$(printf '%s\n' "${DEST_LINES}" | grep -c .)"
      ok "every destination in the validator-host leg (${DEST_COUNT} found) targets \$DEPLOY_PATH/public/"
    else
      no "validator-host leg has a destination NOT targeting \$DEPLOY_PATH/public/ (bare \$DEPLOY_PATH root would leak the repo layout onto the VPS)"
    fi
  fi
else
  no "could not locate 'Advance host checkout to origin/main' before 'Set up Xserver deploy key' in the workflow — cannot bound the validator-host leg"
fi

# --- 4. step order: Advance < Rsync public/ < Bring up/reload Caddy. The
#        advance step must run first (git delivers everything else before
#        Caddy is (re)started against it); the public/ rsync must land
#        before Caddy comes up so the served tree is never stale. ---
if [ -n "${ADV_LINE}" ] && [ -n "${RSYNC_LINE}" ] && [ -n "${CADDY_LINE}" ]; then
  if [ "${ADV_LINE}" -lt "${RSYNC_LINE}" ] && [ "${RSYNC_LINE}" -lt "${CADDY_LINE}" ]; then
    ok "step order holds: Advance host checkout (${ADV_LINE}) < Rsync public/ to VPS (${RSYNC_LINE}) < Bring up / reload Caddy on VPS (${CADDY_LINE})"
  else
    no "step order violated: advance=${ADV_LINE} rsync=${RSYNC_LINE} caddy=${CADDY_LINE} (required: advance < rsync < caddy)"
  fi
else
  no "could not locate all three of 'Advance host checkout to origin/main', 'Rsync public/ to VPS', 'Bring up / reload Caddy on VPS' to check ordering"
fi

# --- 5. the daily self-heal cron backstop stays wired to this exact script.
#        If a future refactor renames/moves advance-host-checkout.sh without
#        updating the installer, the daily cron silently stops finding it. ---
if [ -f "${CRON_INSTALLER}" ] && grep -q 'advance-host-checkout.sh' "${CRON_INSTALLER}"; then
  ok "scripts/install-metal-host-advance-cron.sh exists and still references advance-host-checkout.sh"
else
  no "scripts/install-metal-host-advance-cron.sh is missing, or no longer references advance-host-checkout.sh"
fi

# --- 6. (Task 3 review addition) within the "Bring up / reload Caddy on
#        VPS" step, the trailing curl -fsS .../health check must appear
#        AFTER the `fi` that closes the reload/force-recreate conditional —
#        i.e. it must run regardless of which branch (in-place reload vs.
#        force-recreate) executed, not just guard one of them. Compares
#        line positions within the step's own extracted block only. ---
if [ -n "${CADDY_LINE}" ]; then
  CADDY_NEXT="$(awk -v start="${CADDY_LINE}" 'NR>start && /^      - name:/{print NR; exit}' "${WORKFLOW}")"
  [ -n "${CADDY_NEXT}" ] || CADDY_NEXT=$((CADDY_LINE + 1000))
  CADDY_BLOCK="$(sed -n "${CADDY_LINE},$((CADDY_NEXT - 1))p" "${WORKFLOW}")"

  FORCE_RECREATE_LINE="$(printf '%s\n' "${CADDY_BLOCK}" | grep -n -F -- '--force-recreate caddy' | head -1 | cut -d: -f1)"
  FI_LINE=""
  if [ -n "${FORCE_RECREATE_LINE}" ]; then
    FI_LINE="$(printf '%s\n' "${CADDY_BLOCK}" | awk -v start="${FORCE_RECREATE_LINE}" 'NR>start && /^[[:space:]]*fi[[:space:]]*$/{print NR; exit}')"
  fi
  HEALTH_LINE="$(printf '%s\n' "${CADDY_BLOCK}" | grep -n -E -- 'curl -fsS.*/health' | head -1 | cut -d: -f1)"

  if [ -n "${FI_LINE}" ] && [ -n "${HEALTH_LINE}" ]; then
    if [ "${FI_LINE}" -lt "${HEALTH_LINE}" ]; then
      ok "curl -fsS .../health (step-block line ${HEALTH_LINE}) runs AFTER the fi closing the reload/force-recreate conditional (step-block line ${FI_LINE}) — guards both branches"
    else
      no "curl -fsS .../health (step-block line ${HEALTH_LINE}) does NOT run after the closing fi (step-block line ${FI_LINE}) — health check would no longer guard both the reload and force-recreate branches"
    fi
  else
    no "could not locate both the fi closing the reload/force-recreate conditional and the curl -fsS .../health line within the Caddy step block (fi_line='${FI_LINE}' health_line='${HEALTH_LINE}')"
  fi
else
  no "cannot check health-check-after-fi ordering: 'Bring up / reload Caddy on VPS' step not found"
fi

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
