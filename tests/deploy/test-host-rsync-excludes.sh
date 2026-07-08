#!/usr/bin/env bash
# Regression test: the validator-host rsync block in
# .github/workflows/deploy.yml MUST exclude logs/, tests/, docs/, and
# TOOLKIT.md from --delete.
#
# logs/ holds host-runtime state — project-local cron exit-code logs
# (e.g. logs/gen-evidence.log) that scripts/notify-evidence-health.sh
# reads for its A1 check (see scripts/check-cron-file.sh:58 for the
# project-local-log-path convention). The repo only ships logs/.gitkeep,
# so if the validator-host rsync block ever drops its inline
# --exclude='logs/', a deploy's `--delete` silently wipes host cron
# logs and the evidence-health check flaps to "cron rc: log not found"
# on an otherwise-healthy system.
#
# tests/, docs/, and TOOLKIT.md are repo-internal dev/doc files the
# validator host does not use at runtime — the host receives them via
# its own git checkout instead. Before these were excluded, the deploy
# rsync would still ship them and --inplace-touch the host's git-tracked
# copies, which then showed up as local modifications and made the
# host's `git pull --ff-only` abort on the next push touching those
# paths — forcing a manual reconcile every time. (public/ cannot be
# excluded the same way — it is deploy-transformed and cache-busted —
# so pushes touching public/ still cause host drift; that part is
# inherent and out of scope for this test.)
#
# This test pins all four excludes in place so dropping any one of them
# fails the test.
#
# No network, no SSH, no real deploy — pure static grep of the workflow
# file, mirroring the style of the sibling tests in this directory.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
WORKFLOW="${REPO}/.github/workflows/deploy.yml"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

[ -f "${WORKFLOW}" ] || { echo "FAIL: workflow not found at ${WORKFLOW}" >&2; exit 1; }

# Isolate the validator-host rsync block: the step running
# "rsync -rltvz --delete --inplace" whose destination is the repo root
# (./ "$SSH_USER@$SSH_HOST:$DEPLOY_PATH/"). This is distinct from the
# Xserver block below it, whose source is ./public/ and therefore can
# never touch repo-root logs/, tests/, docs/, or TOOLKIT.md in the
# first place.
HOST_BLOCK="$(awk '/rsync -rltvz --delete --inplace/{flag=1} flag{print} flag && /\.\/ "\$SSH_USER@\$SSH_HOST:\$DEPLOY_PATH\/"/{exit}' "${WORKFLOW}")"

if [ -z "${HOST_BLOCK}" ]; then
  no "could not isolate the validator-host rsync block in ${WORKFLOW}"
else
  ok "isolated the validator-host rsync block"

  echo "${HOST_BLOCK}" | grep -Fqx -- "            --exclude='logs/' \\" \
    && ok "validator-host rsync excludes logs/ (inline, matches surrounding style)" \
    || no "validator-host rsync block is missing --exclude='logs/'"

  echo "${HOST_BLOCK}" | grep -Fqx -- "            --exclude='tests/' \\" \
    && ok "validator-host rsync excludes tests/ (inline, matches surrounding style)" \
    || no "validator-host rsync block is missing --exclude='tests/'"

  echo "${HOST_BLOCK}" | grep -Fqx -- "            --exclude='docs/' \\" \
    && ok "validator-host rsync excludes docs/ (inline, matches surrounding style)" \
    || no "validator-host rsync block is missing --exclude='docs/'"

  echo "${HOST_BLOCK}" | grep -Fqx -- "            --exclude='TOOLKIT.md' \\" \
    && ok "validator-host rsync excludes TOOLKIT.md (inline, matches surrounding style)" \
    || no "validator-host rsync block is missing --exclude='TOOLKIT.md'"

  # Guard against the fix drifting into the shared feed-excludes emitter
  # instead: these are repo-root excludes (like scripts/), not
  # public/-relative feeds, so they belong inline next to
  # --exclude='scripts/'.
  echo "${HOST_BLOCK}" | grep -Fqx -- "            --exclude='scripts/' \\" \
    && ok "new excludes sit alongside the scripts/ exclude (repo-root style)" \
    || no "expected sibling --exclude='scripts/' line not found for context"
fi

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
