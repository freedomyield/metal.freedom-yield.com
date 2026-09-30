#!/usr/bin/env bash
# tests/a-chain-profile/docker-jq-matrix.sh — the jq-version matrix for
# scripts/lib/a-chain-profile.sh, run in throw-away containers:
#   ubuntu:18.04 (jq 1.5)  -> jq-too-old-check.sh: every getter refuses, rc 6
#   ubuntu:20.04 (jq 1.6)  -> the full contract + no-drift suites pass
# jq 1.6 is the oldest jq the library accepts and the oldest on any host
# that runs it, so the 1.6 leg is what proves the code stays within it.
#
# NOT part of tests/run-all-tests.sh (no test-*.sh name): it needs docker and
# network access for image pulls and apt, which neither CI (validate.yml) nor
# every operator machine has. Run it by hand when the library or its jq
# usage changes:
#   bash tests/a-chain-profile/docker-jq-matrix.sh
# CHAIN: none — containers get a read-only copy of the repo; no proton, no
# chain endpoint is contacted (only the distro package mirror for jq).
# Exit: 0 both legs as expected, 1 a leg failed, 2 docker unavailable.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
	echo "docker-jq-matrix: docker unavailable"
	exit 2
fi
PREP='apt-get update -qq >/dev/null && apt-get install -y -qq jq >/dev/null && cp -r /src /w && cd /w && jq --version'
rc=0
echo "== ubuntu:18.04 (jq 1.5): the version gate must refuse =="
docker run --rm -v "${REPO_ROOT}:/src:ro" ubuntu:18.04 bash -c \
	"${PREP} && bash tests/a-chain-profile/jq-too-old-check.sh" || rc=1
echo "== ubuntu:20.04 (jq 1.6): every suite must pass =="
docker run --rm -v "${REPO_ROOT}:/src:ro" ubuntu:20.04 bash -c \
	"set -o pipefail; ${PREP} && for t in tests/a-chain-profile/test-*.sh; do bash \"\$t\" | tail -1 || exit 1; done" || rc=1
echo "docker-jq-matrix: $([ "$rc" = 0 ] && echo ALL AS EXPECTED || echo FAILED)"
exit "$rc"
