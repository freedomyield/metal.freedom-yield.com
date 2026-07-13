#!/usr/bin/env bash
# Regression test for the rsync --delete exclusion contract that
# protects validator-host-pushed runtime artifacts during GitHub
# Actions deploys (= audit-C/F-E1 follow-up).
#
# The test builds a local-to-local fixture pair:
#   src/   plays the role of the GitHub Actions checkout (= Git tree)
#   dst/   plays the role of the web-host deploy target
#
# We then run rsync with the shared feed-exclusion set (produced by
# scripts/deploy/build-rsync-excludes.sh — the single source of truth
# deploy.yml also consumes) for BOTH the repo-root-rooted (prefix
# "public/", no live rsync leg uses this shape since the 2026-07-13
# delivery-ownership inversion — kept for emitter coverage) and Xserver
# (public/-rooted, prefix "" — the shape BOTH live legs now use) shapes,
# and assert these invariants:
#
#   1. Files the validator host writes (= rsync excludes) survive the
#      deploy: rsync does NOT delete them from dst even when src has no
#      copy at all.
#   2. Files the Git tree owns get copied from src to dst, overwriting
#      stale dst content.
#   3. Files not in either category are subject to normal --delete
#      semantics (= deleted from dst when absent from src). This catches
#      regressions where someone over-applies exclusions.
#
# No network, no SSH, no real deploy.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMITTER="${REPO_ROOT}/scripts/deploy/build-rsync-excludes.sh"
[ -x "${EMITTER}" ] || { echo "FAIL: emitter not found/executable at ${EMITTER}" >&2; exit 1; }

# The feed exclusion set is produced by the shared emitter (single source
# of truth: deploy/feed-excludes.txt) — the same one deploy.yml consumes
# for BOTH rsync targets (both public/-rooted, prefix "", since the
# 2026-07-13 delivery-ownership inversion). We exercise both emitter
# prefix shapes below for coverage:
#   - repo-root-rooted shape (no live leg uses this): prefix "public/"
#   - validator-host + Xserver (both public/-rooted) shape: prefix ""
# The emitter already prints ready-to-use `--exclude=/...` args, so we
# collect them verbatim. (Portable to bash 3.2 / macOS — no mapfile;
# process substitution only.)
# Capture once, then read via here-strings. Piping the emitter into
# `grep -q` under `set -o pipefail` would let grep close the pipe early,
# kill the emitter with SIGPIPE, and poison the pipeline status — a false
# negative. A captured variable avoids the pipe entirely.
EMITTED_PUBLIC="$(bash "${EMITTER}" "public/")"
EXCLUDE_ARGS=()
while IFS= read -r ex; do
	[ -n "${ex}" ] || continue
	EXCLUDE_ARGS+=("${ex}")
done <<< "${EMITTED_PUBLIC}"

# Sanity: anchor-receipt.json MUST be excluded (= the audit fix this
# test was written to defend).
if ! grep -qx -- '--exclude=/public/api/anchor-receipt.json' <<< "${EMITTED_PUBLIC}"; then
	echo "FAIL  precondition: emitter does not exclude public/api/anchor-receipt.json" >&2
	exit 1
fi
echo "OK    precondition: emitter excludes 'public/api/anchor-receipt.json'"

TMP="$(mktemp -d -t rsync-protect.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

SRC="${TMP}/src"
DST="${TMP}/dst"
mkdir -p "${SRC}/public/api" "${SRC}/public/.well-known"
mkdir -p "${DST}/public/api" "${DST}/public/.well-known"

# --- src: Git-owned content ---
echo '{"git_owned": true}' > "${SRC}/public/api/identity.json"
echo 'signature-bytes'      > "${SRC}/public/api/identity.json.sig"
echo '{"$schema": "x"}'      > "${SRC}/public/api/identity.schema.v1.json"
echo '{"key_seq": 1}'       > "${SRC}/public/api/identity-history.jsonl"
echo 'ssh-ed25519 AAAA...'  > "${SRC}/public/.well-known/operator-identity.pub"

# --- dst: simulated state BEFORE the deploy ---
# (a) Validator-pushed runtime files exist on dst with content the deploy
#     MUST NOT remove. These have NO counterpart in src.
mkdir -p "${DST}/public/api"
echo '{"runtime": "anchor-receipt"}' > "${DST}/public/api/anchor-receipt.json"
echo '{"runtime": "validator"}'      > "${DST}/public/api/validator.json"
echo '{"runtime": "evidence"}'       > "${DST}/public/api/evidence.json"
echo '{"line": 1}'                   > "${DST}/public/api/cycle-history.jsonl"
echo '{"line": 1}'                   > "${DST}/public/api/peers-gini-history.jsonl"
# (b) Stale Git-owned content that should be OVERWRITTEN by the deploy.
echo '{"git_owned": false, "stale": true}' > "${DST}/public/api/identity.json"
# (c) Junk file not in src and not in exclude list — should be DELETED.
echo 'should be deleted' > "${DST}/public/api/junk.json"

# --- Run rsync --delete with the workflow's exclude list ---
rsync -rltv --delete \
	"${EXCLUDE_ARGS[@]}" \
	"${SRC}/" "${DST}/" >/dev/null

PASS=0; FAIL=0

check_exists() {
	local path="$1" label="$2"
	if [ -e "${path}" ]; then
		echo "  PASS ${label} preserved at ${path}"
		PASS=$((PASS+1))
	else
		echo "  FAIL ${label} unexpectedly deleted at ${path}"
		FAIL=$((FAIL+1))
	fi
}

check_absent() {
	local path="$1" label="$2"
	if [ ! -e "${path}" ]; then
		echo "  PASS ${label} correctly deleted (junk drop)"
		PASS=$((PASS+1))
	else
		echo "  FAIL ${label} survived deletion at ${path}"
		FAIL=$((FAIL+1))
	fi
}

check_content() {
	local path="$1" expect="$2" label="$3"
	if [ "$(cat "${path}" 2>/dev/null)" = "${expect}" ]; then
		echo "  PASS ${label} content matches expected '${expect}'"
		PASS=$((PASS+1))
	else
		echo "  FAIL ${label} content mismatch; got '$(cat "${path}" 2>/dev/null)' expected '${expect}'"
		FAIL=$((FAIL+1))
	fi
}

echo ""
echo "=== Invariant 1: validator-pushed files survive --delete ==="
check_exists  "${DST}/public/api/anchor-receipt.json"      "anchor-receipt.json"
check_exists  "${DST}/public/api/validator.json"            "validator.json"
check_exists  "${DST}/public/api/evidence.json"             "evidence.json"
check_exists  "${DST}/public/api/cycle-history.jsonl"       "cycle-history.jsonl"
check_exists  "${DST}/public/api/peers-gini-history.jsonl"  "peers-gini-history.jsonl"
# And their content was NOT overwritten (= src has no copy of these).
check_content "${DST}/public/api/anchor-receipt.json" '{"runtime": "anchor-receipt"}' \
	"anchor-receipt.json content"

echo ""
echo "=== Invariant 2: Git-owned files copied + stale dst overwritten ==="
check_exists  "${DST}/public/api/identity.json"            "identity.json"
check_exists  "${DST}/public/api/identity.json.sig"        "identity.json.sig"
check_exists  "${DST}/public/api/identity.schema.v1.json"  "identity.schema.v1.json"
check_exists  "${DST}/public/api/identity-history.jsonl"   "identity-history.jsonl"
check_exists  "${DST}/public/.well-known/operator-identity.pub" "operator-identity.pub"
# And the stale identity.json was overwritten.
check_content "${DST}/public/api/identity.json" '{"git_owned": true}' \
	"identity.json content (overwritten from src)"

echo ""
echo "=== Invariant 3: junk file outside exclude list is deleted ==="
check_absent "${DST}/public/api/junk.json" "junk.json"

echo ""
echo "=== Xserver shape: public/-rooted rsync preserves feeds, updates git-owned static ==="
# The Xserver web root is public/ directly, so rsync's source is ./public/
# and the feed excludes are anchored WITHOUT the public/ prefix. Same feeds,
# same single source of truth, different anchor.
#
# anchor-source.json is NOT a protected feed anymore: as of the git-deploy
# ownership change (anchor-source.json de-excluded from deploy/feed-excludes.txt
# and now shipped from the Git tree) it obeys invariant 2 — src MUST overwrite
# stale dst, exactly like identity.schema.v1.json below. The protected-feed
# coverage (invariant 1) is carried here by validator.json and
# anchor-receipt.json, both still validator-host-pushed and rsync-excluded, so
# their fresh dst content survives even though src has no copy.
XS="$(mktemp -d -t rsync-xserver.XXXXXX)"
mkdir -p "${XS}/src/public/api" "${XS}/src/public/calendar" "${XS}/dst/api"
printf 'SRC-static\n'      > "${XS}/src/public/api/identity.schema.v1.json"
printf 'SRC-home\n'        > "${XS}/src/public/index.html"
printf 'SRC-anchor\n'      > "${XS}/src/public/api/anchor-source.json"
printf 'src-should-skip\n' > "${XS}/src/public/api/validator.json"
printf 'FRESH-feed\n'      > "${XS}/dst/api/validator.json"
printf 'FRESH-receipt\n'   > "${XS}/dst/api/anchor-receipt.json"
printf 'STALE-anchor\n'    > "${XS}/dst/api/anchor-source.json"
printf 'STALE-static\n'    > "${XS}/dst/api/identity.schema.v1.json"
printf 'ORPHAN\n'          > "${XS}/dst/api/old-removed.json"
XEXC=()
while IFS= read -r ex; do
	[ -n "${ex}" ] || continue
	XEXC+=("${ex}")
done < <(bash "${EMITTER}" "")
rsync -rlt --delete "${XEXC[@]}" "${XS}/src/public/" "${XS}/dst/" >/dev/null
# Invariant 1 — protected feeds survive --delete (src carries no copy):
check_content "${XS}/dst/api/validator.json"          'FRESH-feed'    "Xserver validator.json feed"
check_content "${XS}/dst/api/anchor-receipt.json"     'FRESH-receipt' "Xserver anchor-receipt.json feed"
# Invariant 2 — git-owned files overwrite stale dst:
check_content "${XS}/dst/api/anchor-source.json"      'SRC-anchor'    "Xserver anchor-source.json (git-deploy owned, overwritten from src)"
check_content "${XS}/dst/api/identity.schema.v1.json" 'SRC-static'    "Xserver static schema (updated from src)"
check_exists  "${XS}/dst/index.html"                  "Xserver index.html"
check_absent  "${XS}/dst/api/old-removed.json"        "Xserver non-feed orphan"
rm -rf "${XS}"

echo ""
echo "Result: ${PASS} pass, ${FAIL} fail"
[ "${FAIL}" -eq 0 ]
