#!/usr/bin/env bash
# Unit test for scripts/deploy/build-rsync-excludes.sh
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
EMIT="${REPO}/scripts/deploy/build-rsync-excludes.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

# validator-host shape: prefix public/
OUT="$(bash "${EMIT}" "public/")"
echo "${OUT}" | grep -qx -- '--exclude=/public/api/validator.json' \
  && ok "public/ prefix anchors validator.json" || no "public/ validator.json"
# anchor-source.json is now git-tracked and published via git-deploy, so it must
# NOT be excluded (neither the feed nor the dead .sig reference).
echo "${OUT}" | grep -q -- '--exclude=/public/api/anchor-source.json' \
  && no "anchor-source.json must NOT be excluded (git-tracked)" \
  || ok "anchor-source.json (and .sig) not excluded — served via git-deploy"
# anchor-receipt.json remains a host-pushed feed and MUST stay excluded.
echo "${OUT}" | grep -qx -- '--exclude=/public/api/anchor-receipt.json' \
  && ok "public/ prefix anchors anchor-receipt.json" || no "public/ anchor-receipt.json"
echo "${OUT}" | grep -qx -- '--exclude=/public/calendar/' \
  && ok "public/ prefix anchors calendar/" || no "public/ calendar/"

# Xserver shape: empty prefix
OUT="$(bash "${EMIT}" "")"
echo "${OUT}" | grep -qx -- '--exclude=/api/validator.json' \
  && ok "empty prefix anchors api/validator.json" || no "empty api/validator.json"
echo "${OUT}" | grep -qx -- '--exclude=/calendar/' \
  && ok "empty prefix anchors calendar/" || no "empty calendar/"

# Count parity: both shapes emit the same number of lines
H="$(bash "${EMIT}" "public/" | wc -l | tr -d ' ')"
X="$(bash "${EMIT}" "" | wc -l | tr -d ' ')"
[ "${H}" = "${X}" ] && [ "${H}" = 19 ] \
  && ok "both shapes emit 19 excludes" || no "count parity (h=${H} x=${X})"

# Missing list file → non-zero exit
if FEED_EXCLUDES_FILE=/nonexistent bash "${EMIT}" "public/" >/dev/null 2>&1; then
  no "missing list should fail"
else ok "missing list fails closed"; fi

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
