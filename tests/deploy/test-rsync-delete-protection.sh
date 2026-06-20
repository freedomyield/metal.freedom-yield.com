#!/usr/bin/env bash
# Regression test for the rsync --delete exclusion contract that
# protects validator-host-pushed runtime artifacts during GitHub
# Actions deploys (= audit-C/F-E1 follow-up).
#
# The test builds a local-to-local fixture pair:
#   src/   plays the role of the GitHub Actions checkout (= Git tree)
#   dst/   plays the role of the web-host deploy target
#
# We then run rsync with the exclusion list extracted from the deploy
# workflow and assert three invariants:
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
DEPLOY_YML="${REPO_ROOT}/.github/workflows/deploy.yml"
[ -f "${DEPLOY_YML}" ] || { echo "FAIL: deploy.yml not found at ${DEPLOY_YML}" >&2; exit 1; }

# Extract --exclude='...' arguments from deploy.yml so the test stays in
# lock-step with the actual workflow. The grep matches the quoted form
# the workflow uses; non-matching lines are ignored. We then convert each
# match into an `--exclude=<value>` arg suitable to pass to rsync.
# (Portable to bash 3.2 / macOS — no mapfile. The grep `--` argument-
# end marker is required because `--exclude=...` otherwise looks like a
# grep flag.)
EXCLUDES_FILE="$(mktemp)"
grep -oE -- "--exclude='[^']*'" "${DEPLOY_YML}" \
	| sed -E "s/--exclude='([^']*)'/\1/" > "${EXCLUDES_FILE}"

EXCLUDE_ARGS=()
EXCLUDES_LIST=""
while IFS= read -r ex; do
	[ -n "${ex}" ] || continue
	EXCLUDE_ARGS+=("--exclude=${ex}")
	EXCLUDES_LIST="${EXCLUDES_LIST}|${ex}"
done < "${EXCLUDES_FILE}"
rm -f "${EXCLUDES_FILE}"

# Sanity: anchor-receipt.json MUST be in the exclude list (= the audit
# fix this test was written to defend).
case "${EXCLUDES_LIST}" in
	*"|public/api/anchor-receipt.json"*) ;;
	*)
		echo "FAIL  precondition: deploy.yml does not exclude public/api/anchor-receipt.json" >&2
		exit 1
		;;
esac
echo "OK    precondition: deploy.yml --exclude list contains 'public/api/anchor-receipt.json'"

TMP="$(mktemp -d -t rsync-protect.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

SRC="${TMP}/src"
DST="${TMP}/dst"
mkdir -p "${SRC}/public/api" "${SRC}/public/.well-known"
mkdir -p "${DST}/public/api" "${DST}/public/.well-known"

# --- src: Git-owned content ---
echo '{"git_owned": true}' > "${SRC}/public/api/identity.json"
echo 'signature-bytes'      > "${SRC}/public/api/identity.json.sig"
echo '{"git_owned": true}' > "${SRC}/public/api/cycles-history.json"
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
check_exists  "${DST}/public/api/cycles-history.json"      "cycles-history.json"
check_exists  "${DST}/public/api/identity-history.jsonl"   "identity-history.jsonl"
check_exists  "${DST}/public/.well-known/operator-identity.pub" "operator-identity.pub"
# And the stale identity.json was overwritten.
check_content "${DST}/public/api/identity.json" '{"git_owned": true}' \
	"identity.json content (overwritten from src)"

echo ""
echo "=== Invariant 3: junk file outside exclude list is deleted ==="
check_absent "${DST}/public/api/junk.json" "junk.json"

echo ""
echo "Result: ${PASS} pass, ${FAIL} fail"
[ "${FAIL}" -eq 0 ]
