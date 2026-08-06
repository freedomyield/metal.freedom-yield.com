#!/usr/bin/env bash
# Regression test: .github/workflows/deploy.yml writes public/api/build.json
# before either rsync leg ships public/, so the deploy manifest that
# .gitignore and validate.yml have assumed exists since before this fix
# actually gets produced and delivered.
#
# CHAIN: none — pure static grep/awk of the workflow file, plus a hermetic
# execution of the step's own `run:` shell against synthetic
# GITHUB_SHA/GITHUB_REF_NAME/GITHUB_RUN_ID env vars (the same ones the
# Actions runtime provides for free — no network, no real deploy).
#
# Review round 1 (2026-08-06) finding: the first version of this test used
# `python3 -c 'import yaml; ...'` to pull the step's run: block out of the
# workflow, but PyYAML is not a dependency anything else in this repo
# declares or requires (grepped: this was the only `import yaml` in the
# whole tree) — a host with python3 but no PyYAML would hard-fail this
# suite (only python3/jq presence was skip-guarded) -- an interpreter-
# present-but-library-missing gap of the same shape this project has hit
# before across differing hosts. Rewritten to extract the run:
# block with awk instead, using the workflow's own fixed indentation
# (`- name:` at 6 spaces, `run: |` at 8, block content at 10 — the same
# convention every other step in this file already uses) — no YAML parser,
# no new dependency at all.
#
# Background (2026-08-06): .gitignore documented `public/api/build.json` as
# "CI/CD で deploy 時に生成、コミット不要" and validate.yml's committed-JSON
# check already excluded it from its `find public -name '*.json'` loop —
# both assumed a producer that never actually existed. The live URL 404'd
# permanently. This test pins: the "Write build.json" step exists, runs
# strictly before both "Rsync public/ to VPS" and "Rsync public/ to Xserver
# (public origin)" (the two legs that ship public/ off the runner), writes
# to exactly public/api/build.json, and its `run:` block, executed against
# synthetic Actions env vars, produces valid JSON carrying the fields an
# evaluator would actually want (commit_sha, deployed_at).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
WORKFLOW="${REPO}/.github/workflows/deploy.yml"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

[ -f "${WORKFLOW}" ] || { echo "FAIL: workflow not found at ${WORKFLOW}" >&2; exit 1; }

BUILD_LINE="$(grep -n -F -- '- name: Write build.json (deploy manifest)' "${WORKFLOW}" | head -1 | cut -d: -f1)"
VPS_RSYNC_LINE="$(grep -n -F -- '- name: Rsync public/ to VPS' "${WORKFLOW}" | head -1 | cut -d: -f1)"
XS_RSYNC_LINE="$(grep -n -F -- '- name: Rsync public/ to Xserver (public origin)' "${WORKFLOW}" | head -1 | cut -d: -f1)"

[ -n "${BUILD_LINE}" ] && ok "found step 'Write build.json (deploy manifest)' (line ${BUILD_LINE})" \
	|| no "step 'Write build.json (deploy manifest)' not found"
[ -n "${VPS_RSYNC_LINE}" ] && ok "found step 'Rsync public/ to VPS' (line ${VPS_RSYNC_LINE})" \
	|| no "step 'Rsync public/ to VPS' not found"
[ -n "${XS_RSYNC_LINE}" ] && ok "found step 'Rsync public/ to Xserver (public origin)' (line ${XS_RSYNC_LINE})" \
	|| no "step 'Rsync public/ to Xserver (public origin)' not found"

if [ -n "${BUILD_LINE}" ] && [ -n "${VPS_RSYNC_LINE}" ] && [ "${BUILD_LINE}" -lt "${VPS_RSYNC_LINE}" ]; then
	ok "build.json step precedes the validator-host rsync"
else
	no "build.json step does not precede the validator-host rsync (build=${BUILD_LINE:-?} vps=${VPS_RSYNC_LINE:-?})"
fi
if [ -n "${BUILD_LINE}" ] && [ -n "${XS_RSYNC_LINE}" ] && [ "${BUILD_LINE}" -lt "${XS_RSYNC_LINE}" ]; then
	ok "build.json step precedes the Xserver rsync"
else
	no "build.json step does not precede the Xserver rsync (build=${BUILD_LINE:-?} xs=${XS_RSYNC_LINE:-?})"
fi

grep -q '> public/api/build.json' "${WORKFLOW}" \
	&& ok "step writes to exactly public/api/build.json" \
	|| no "step does not write to public/api/build.json"

# ---- functional: extract the step's own run: block and execute it against
# synthetic Actions env vars (GITHUB_SHA / GITHUB_REF_NAME / GITHUB_RUN_ID
# are provided by the real Actions runtime for free; jq is preinstalled on
# ubuntu-latest, same tool this repo already depends on elsewhere). ----
if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP: jq unavailable — cannot execute the extracted run: block"
else
	WORK="$(mktemp -d)"
	trap 'rm -rf "${WORK}"' EXIT
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		awk '
			/^      - name: Write build\.json \(deploy manifest\)$/ { instep=1 }
			instep && /^        run: \|$/ { inrun=1; next }
			instep && inrun {
				if ($0 ~ /^          /) {
					print substr($0, 11)
				} else if ($0 !~ /^[[:space:]]*$/) {
					exit
				} else {
					print ""
				}
			}
		' "${WORKFLOW}"
	} > "${WORK}/step.sh"
	if [ ! -s "${WORK}/step.sh" ] || [ "$(wc -l < "${WORK}/step.sh" | tr -d ' ')" -le 2 ]; then
		no "could not extract the build.json step's run: block (awk found 0 content lines — indentation drifted from 6/8/10 spaces, or the step was renamed)"
	else
		mkdir -p "${WORK}/repo/public/api"
		OUT_JSON="${WORK}/repo/public/api/build.json"
		( cd "${WORK}/repo" && \
			GITHUB_SHA="0123456789abcdef0123456789abcdef01234567" \
			GITHUB_REF_NAME="main" \
			GITHUB_RUN_ID="987654321" \
			bash "${WORK}/step.sh" ) > "${WORK}/step.out" 2>&1
		RC=$?
		[ "${RC}" -eq 0 ] && ok "extracted run: block exits 0" || no "extracted run: block failed (rc=${RC}): $(cat "${WORK}/step.out")"
		if [ -f "${OUT_JSON}" ]; then
			jq empty "${OUT_JSON}" 2>/dev/null && ok "produced build.json is valid JSON" || no "produced build.json is NOT valid JSON"
			[ "$(jq -r '.commit_sha' "${OUT_JSON}")" = "0123456789abcdef0123456789abcdef01234567" ] \
				&& ok "commit_sha carries the full GITHUB_SHA" || no "commit_sha wrong: $(jq -r '.commit_sha' "${OUT_JSON}" 2>/dev/null)"
			[ "$(jq -r '.commit_short_sha' "${OUT_JSON}")" = "01234567" ] \
				&& ok "commit_short_sha is the 8-char prefix" || no "commit_short_sha wrong: $(jq -r '.commit_short_sha' "${OUT_JSON}" 2>/dev/null)"
			jq -r '.deployed_at' "${OUT_JSON}" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
				&& ok "deployed_at is ISO 8601 UTC" || no "deployed_at not ISO 8601 UTC: $(jq -r '.deployed_at' "${OUT_JSON}" 2>/dev/null)"
		else
			no "build.json was not written by the extracted step"
		fi
	fi
fi

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
