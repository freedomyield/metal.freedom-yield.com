#!/usr/bin/env bash
# Unit test for scripts/deploy/build-rsync-excludes.sh
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
EMIT="${REPO}/scripts/deploy/build-rsync-excludes.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

# repo-root-rooted shape: prefix public/ (no live rsync leg uses this
# prefix anymore — both the validator-host and Xserver legs are
# public/-rooted with empty prefix as of the 2026-07-13 delivery-ownership
# inversion; retained here for emitter prefix-handling coverage)
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

# validator-host + Xserver shape: empty prefix (both live legs, since the
# 2026-07-13 inversion)
OUT="$(bash "${EMIT}" "")"
echo "${OUT}" | grep -qx -- '--exclude=/api/validator.json' \
  && ok "empty prefix anchors api/validator.json" || no "empty api/validator.json"
echo "${OUT}" | grep -qx -- '--exclude=/calendar/' \
  && ok "empty prefix anchors calendar/" || no "empty calendar/"

# Subdirectory feeds (2026-08-05): api/archive/ holds the R18 per-anchor
# archives, api/peers-history/ the daily snapshots. Both are push-owned and
# never git-tracked, so a deploy --delete that failed to exclude them would
# erase every archived pre-image an evaluator is pointed at.
echo "${OUT}" | grep -qx -- '--exclude=/api/archive/' \
  && ok "empty prefix anchors api/archive/ (R18 archives)" || no "empty api/archive/"
echo "${OUT}" | grep -qx -- '--exclude=/api/peers-history/' \
  && ok "empty prefix anchors api/peers-history/" || no "empty api/peers-history/"

# Count parity: both shapes emit the same number of lines
# (20, not 21: api/anchor-receipt.json.sig was removed 2026-08-06 — it had
# no producer anywhere in the repo, a dead exclude for a file that is never
# written, so nothing protected it from being cleaned up by --delete.)
H="$(bash "${EMIT}" "public/" | wc -l | tr -d ' ')"
X="$(bash "${EMIT}" "" | wc -l | tr -d ' ')"
[ "${H}" = "${X}" ] && [ "${H}" = 20 ] \
  && ok "both shapes emit 20 excludes" || no "count parity (h=${H} x=${X})"

# Regression guard: the dead anchor-receipt.json.sig exclude must not
# reappear without a producer to justify it.
echo "$(bash "${EMIT}" "")" | grep -qx -- '--exclude=/api/anchor-receipt.json.sig' \
  && no "anchor-receipt.json.sig must NOT be excluded (no producer exists)" \
  || ok "anchor-receipt.json.sig not excluded — dead reference removed"

# Missing list file → non-zero exit
if FEED_EXCLUDES_FILE=/nonexistent bash "${EMIT}" "public/" >/dev/null 2>&1; then
  no "missing list should fail"
else ok "missing list fails closed"; fi

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
