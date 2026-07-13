#!/usr/bin/env bash
# Regression test: the "Bring up / reload Caddy on VPS" step in
# .github/workflows/deploy.yml detects and heals a stale Caddyfile bind
# mount instead of silently reloading through it.
#
# CHAIN: none — pure static grep of the workflow file. No network, no SSH,
# no docker, no real deploy.
#
# Why this exists (2026-07-13 delivery-ownership inversion, Task 3):
# caddy/Caddyfile is a single-file bind mount (docker-compose.yml:25,
# ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro), pinned to the host inode
# present at container creation. Before the inversion, the whole-repo rsync
# used --inplace specifically to write into that same inode, so a plain
# `caddy reload` always picked up the new content. After the inversion, the
# "Advance host checkout to origin/main" step updates caddy/Caddyfile via a
# git pull, which replaces the file with a NEW inode — the running
# container's bind mount still points at the ORPHANED old inode, so
# `caddy reload` alone would reload stale config forever. The fix is
# state-based: compare what the container actually sees
# (`docker compose exec -T caddy cat /etc/caddy/Caddyfile`) against the host
# file (`caddy/Caddyfile`); if they differ, the mount is stale and only a
# scoped `--force-recreate caddy` (not reload, which reads through the same
# stale mount) can pick up the new config. This also self-heals any
# pre-existing stale mount from an earlier deploy and is a no-op when
# nothing changed.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
WORKFLOW="${REPO}/.github/workflows/deploy.yml"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

[ -f "${WORKFLOW}" ] || { echo "FAIL: workflow not found at ${WORKFLOW}" >&2; exit 1; }

STEP_LINE="$(grep -n -F -- '- name: Bring up / reload Caddy on VPS' "${WORKFLOW}" | head -1 | cut -d: -f1)"

if [ -n "${STEP_LINE}" ]; then
  ok "found step 'Bring up / reload Caddy on VPS' (line ${STEP_LINE})"
else
  no "workflow is missing a step named 'Bring up / reload Caddy on VPS'"
fi

if [ -n "${STEP_LINE}" ]; then
  # Isolate the step's own block: from its "- name:" line up to (not
  # including) the next top-level step's "- name:" line.
  STEP_NEXT="$(awk -v start="${STEP_LINE}" 'NR>start && /^      - name:/{print NR; exit}' "${WORKFLOW}")"
  [ -n "${STEP_NEXT}" ] || STEP_NEXT=$((STEP_LINE + 1000))
  STEP_BLOCK="$(sed -n "${STEP_LINE},$((STEP_NEXT - 1))p" "${WORKFLOW}")"

  echo "${STEP_BLOCK}" | grep -Fq -- 'exec -T caddy cat /etc/caddy/Caddyfile' \
    && ok "step reads the container's view of the Caddyfile via docker compose exec -T caddy cat" \
    || no "step is missing the container-view read (exec -T caddy cat /etc/caddy/Caddyfile)"

  echo "${STEP_BLOCK}" | grep -Fq -- 'cmp -s' \
    && ok "step uses cmp -s to compare container view vs host file" \
    || no "step is missing a cmp -s comparison"

  echo "${STEP_BLOCK}" | grep -Eq -- 'cmp -s - caddy/Caddyfile' \
    && ok "cmp -s compares the container view against the host's caddy/Caddyfile" \
    || no "cmp -s does not compare against caddy/Caddyfile"

  echo "${STEP_BLOCK}" | grep -Fq -- '--force-recreate caddy' \
    && ok "stale-mount branch force-recreates the scoped caddy service only" \
    || no "step is missing a --force-recreate caddy branch for the stale-mount case"

  echo "${STEP_BLOCK}" | grep -Fq -- 'caddy reload' \
    && ok "no-change branch still reloads Caddy in place" \
    || no "step is missing the caddy reload path for the unchanged-Caddyfile case"

  echo "${STEP_BLOCK}" | grep -Fq -- 'curl -fsS' \
    && ok "step still runs the trailing curl health check" \
    || no "step is missing the trailing curl -fsS health check"

  echo "${STEP_BLOCK}" | grep -Fq -- '127.0.0.1:8085/health' \
    && ok "health check still targets 127.0.0.1:8085/health (port unchanged)" \
    || no "health check no longer targets 127.0.0.1:8085/health"

  echo "${STEP_BLOCK}" | grep -Fq -- 'up -d' \
    && ok "step still brings the stack up with up -d before the stale-mount check" \
    || no "step is missing the initial docker compose up -d"
fi

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
