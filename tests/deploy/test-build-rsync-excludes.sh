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
echo "${OUT}" | grep -qx -- '--exclude=/public/api/anchor-source.json.sig' \
  && ok "public/ prefix anchors anchor-source.json.sig" || no "public/ .sig"
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
[ "${H}" = "${X}" ] && [ "${H}" = 21 ] \
  && ok "both shapes emit 21 excludes" || no "count parity (h=${H} x=${X})"

# Missing list file → non-zero exit
if FEED_EXCLUDES_FILE=/nonexistent bash "${EMIT}" "public/" >/dev/null 2>&1; then
  no "missing list should fail"
else ok "missing list fails closed"; fi

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
