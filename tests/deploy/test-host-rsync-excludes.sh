#!/usr/bin/env bash
# Regression test: the validator-host leg of .github/workflows/deploy.yml
# delivers every tracked file via git, not rsync.
#
# CHAIN: none — pure static grep of the workflow file. No network, no SSH,
# no real deploy.
#
# Ownership inversion (2026-07-13): before this, the validator-host leg
# rsynced the whole repo (minus a growing --exclude blacklist) onto the
# host, and that rsync repeatedly leaked git-tracked files past the
# blacklist and --inplace-touched the host's git-tracked copies, which then
# showed up as local modifications and made the host's `git pull --ff-only`
# abort on the next push touching those paths (tests/, docs/, TOOLKIT.md on
# 2026-07-06; CLAUDE.md + bin/ on 2026-07-13 — two recurrences of the same
# structural class of bug).
#
# The fix inverts ownership instead of growing the blacklist again: git is
# now the ONLY delivery path for tracked files. A new step, "Advance host
# checkout to origin/main", pipes the runner's own checked-out copy of
# scripts/advance-host-checkout.sh to the host (so the host always executes
# the version this exact push shipped, never a stale on-host copy) BEFORE
# any rsync runs. Only after that does "Rsync public/ to VPS" ship the one
# artifact git cannot deliver: the deploy-transformed, cache-busted public/
# tree (cache-busting stamps ?v=<sha> into the runner's copy, deliberately
# diverging it from the committed files). With nothing outside public/
# shipped by rsync at all, the old four inline excludes (scripts/, logs/,
# tests/, docs/, TOOLKIT.md) have no remaining purpose and are gone; the
# feed excludes (shared SoT: deploy/feed-excludes.txt via the emitter,
# empty prefix — same anchor as the Xserver leg below it) still protect
# host-generated feed files under public/ from --delete, exactly as before.
#
# This test pins: the advance step exists and pipes the script correctly
# with both env overrides set, the public/ rsync step exists with the exact
# public/-only source/dest and its --delete/--inplace/feed-exclude
# machinery intact, the advance step runs strictly before the rsync step,
# and the old whole-repo rsync shape is gone entirely.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
WORKFLOW="${REPO}/.github/workflows/deploy.yml"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

[ -f "${WORKFLOW}" ] || { echo "FAIL: workflow not found at ${WORKFLOW}" >&2; exit 1; }

ADV_LINE="$(grep -n -F -- '- name: Advance host checkout to origin/main' "${WORKFLOW}" | head -1 | cut -d: -f1)"
RSYNC_LINE="$(grep -n -F -- '- name: Rsync public/ to VPS' "${WORKFLOW}" | head -1 | cut -d: -f1)"

if [ -n "${ADV_LINE}" ]; then
  ok "found step 'Advance host checkout to origin/main' (line ${ADV_LINE})"
else
  no "workflow is missing a step named 'Advance host checkout to origin/main'"
fi

if [ -n "${RSYNC_LINE}" ]; then
  ok "found step 'Rsync public/ to VPS' (line ${RSYNC_LINE})"
else
  no "workflow is missing a step named 'Rsync public/ to VPS'"
fi

if [ -n "${ADV_LINE}" ] && [ -n "${RSYNC_LINE}" ]; then
  if [ "${ADV_LINE}" -lt "${RSYNC_LINE}" ]; then
    ok "advance step (line ${ADV_LINE}) precedes the public/ rsync step (line ${RSYNC_LINE})"
  else
    no "advance step must precede the public/ rsync step (advance=${ADV_LINE}, rsync=${RSYNC_LINE})"
  fi

  # Isolate each step's own block: from its "- name:" line up to (not
  # including) the next top-level step's "- name:" line.
  ADV_NEXT="$(awk -v start="${ADV_LINE}" 'NR>start && /^      - name:/{print NR; exit}' "${WORKFLOW}")"
  [ -n "${ADV_NEXT}" ] || ADV_NEXT=$((ADV_LINE + 1000))
  ADV_BLOCK="$(sed -n "${ADV_LINE},$((ADV_NEXT - 1))p" "${WORKFLOW}")"

  echo "${ADV_BLOCK}" | grep -Eq -- '<[[:space:]]*scripts/advance-host-checkout\.sh' \
    && ok "advance step pipes the runner's scripts/advance-host-checkout.sh via bash -s" \
    || no "advance step does not pipe scripts/advance-host-checkout.sh (regex '<[[:space:]]*scripts/advance-host-checkout\\.sh')"

  echo "${ADV_BLOCK}" | grep -Fq -- 'FYD_REPO_DIR=' \
    && ok "advance step sets FYD_REPO_DIR=" \
    || no "advance step is missing FYD_REPO_DIR="

  echo "${ADV_BLOCK}" | grep -Fq -- 'FYD_NOTIFY=' \
    && ok "advance step sets FYD_NOTIFY=" \
    || no "advance step is missing FYD_NOTIFY="

  # FY_LIVE=1 (2026-08-06, C3 rollout): scripts/lib/side-effects.sh makes
  # alert DELIVERY opt-in. This ssh command is the ONLY caller of
  # advance-host-checkout.sh that gets no cron env header — the cron file is
  # covered by check-cron-file.sh Rule 6, this line by nothing until now.
  # Drop it and every gate in the repo still passes; the only symptom is that
  # the "host is ahead" / "cannot FF" high alerts this step's own comment
  # promises go silently undelivered.
  #
  # Asserted against the step's COMMAND lines, not the whole block: the block
  # also contains a prose comment mentioning FY_LIVE=1, so a naive substring
  # match would stay green after the flag was deleted from the ssh invocation.
  # Requiring it on the same line as `bash -s` pins the invocation itself.
  ADV_CMD="$(printf '%s\n' "${ADV_BLOCK}" | grep -v '^[[:space:]]*#')"
  printf '%s\n' "${ADV_CMD}" | grep -Eq -- 'FY_LIVE=1[[:space:]].*bash -s' \
    && ok "advance step's ssh invocation carries FY_LIVE=1 (alerts are actually delivered)" \
    || no "advance step's ssh invocation is missing FY_LIVE=1 — its high alerts would be suppressed (scripts/lib/side-effects.sh)"

  RSYNC_NEXT="$(awk -v start="${RSYNC_LINE}" 'NR>start && /^      - name:/{print NR; exit}' "${WORKFLOW}")"
  [ -n "${RSYNC_NEXT}" ] || RSYNC_NEXT=$((RSYNC_LINE + 1000))
  RSYNC_BLOCK="$(sed -n "${RSYNC_LINE},$((RSYNC_NEXT - 1))p" "${WORKFLOW}")"

  echo "${RSYNC_BLOCK}" | grep -Fqx -- '            public/ "$SSH_USER@$SSH_HOST:$DEPLOY_PATH/public/"' \
    && ok "public/ rsync source/dest line is exactly public/ ... \$DEPLOY_PATH/public/" \
    || no "public/ rsync step is missing the exact public/-only source/dest line"

  echo "${RSYNC_BLOCK}" | grep -Fq -- '--delete' \
    && ok "public/ rsync step still carries --delete" \
    || no "public/ rsync step is missing --delete"

  echo "${RSYNC_BLOCK}" | grep -Fq -- '--inplace' \
    && ok "public/ rsync step still carries --inplace" \
    || no "public/ rsync step is missing --inplace"

  echo "${RSYNC_BLOCK}" | grep -Fq -- '"${FEED_EXCLUDES[@]}"' \
    && ok "public/ rsync step still applies the FEED_EXCLUDES feed-exclusion set" \
    || no "public/ rsync step is missing \${FEED_EXCLUDES[@]}"

  echo "${RSYNC_BLOCK}" | grep -Fq -- 'build-rsync-excludes.sh ""' \
    && ok "public/ rsync step builds FEED_EXCLUDES with the empty prefix (transfer root is public/, same anchor as the Xserver leg)" \
    || no "public/ rsync step does not build FEED_EXCLUDES with the empty prefix"
fi

grep -Fq -- './ "$SSH_USER@$SSH_HOST:$DEPLOY_PATH/"' "${WORKFLOW}" \
  && no "workflow still contains the old whole-repo rsync shape (./ ... \$DEPLOY_PATH/)" \
  || ok "old whole-repo rsync shape (./ ... \$DEPLOY_PATH/) is gone"

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
