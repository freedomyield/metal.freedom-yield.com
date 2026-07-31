#!/usr/bin/env bash
# scripts/operator-local/commit-anchor-source.sh
#
# Transfer the validator host's checkout of public/api/anchor-source.json
# to Git (Mac-side commit) — the host→git transfer path plan A4 identified
# as missing. anchor-source.json is git-tracked and git-deploy served
# (docs/DEPLOY_OWNERSHIP_MATRIX.md, docs/ANCHOR_SOURCE.md), but the file is
# AUTHORED on the validator host by scripts/gen-anchor-source.sh. Before
# this script, nothing moved that host-composed content back to Git — the
# cycle 3 gap was a 3-day manual copy that produced a stale-published-
# anchor incident (project_incident_20260707_public_anchor_source_stale).
#
# MUST NOT BE RUN ON VALIDATOR HOST OR WEB HOST.
# This helper is for the operator's local Mac only (same guard idiom as
# gen-identity.sh). It never reads validator keys, staking keys, BLS keys,
# signer.key, or staker.key, and it never invokes any broadcast-capable
# command — it only fetches a JSON file over SSH, validates it, and runs
# `git commit` (and, only with --push, `git push origin main`).
#
# Sync exclusion:
#   scripts/sync-to-validator-host.sh excludes operator-local/ so this
#   file is never shipped to the validator host or web host.
#
# What this helper does:
#   1. Fetches the host checkout's current public/api/anchor-source.json
#      over SSH (fetch_remote_anchor_source; isolated in its own function
#      so tests can stub it — see FYD_ANCHOR_FETCH_STUB below. NO real SSH
#      connection is ever made by the test suite).
#   2. Validates: jq parse, schema validation against
#      public/api/anchor-source.schema.v1.json (same schema_validate_or_die
#      pattern as gen-anchor-source.sh / gen-anchor-receipt.sh /
#      append-anchor-history.sh — duplicated here rather than sourced, per
#      this repo's no-cross-script-sourcing convention; keep the four in
#      sync if you touch the logic), --expect-cycle=N match against
#      observations_branch.cycle_number_observed, and identity_branch.
#      prev_anchor_root / prev_anchor_tx non-null (unless --allow-genesis).
#   3. Shows a diff summary against the current repo copy.
#   4. Copies the fetched (now-validated) bytes into the repo path,
#      `git add`, and a single-purpose commit naming the cycle number and
#      the first 8 hex chars of dag_root_computed.
#   5. Does NOT push unless --push is given (then: git push origin main).
#
# What this helper does NOT do:
#   - It never broadcasts anything (no proton / cleos / RPC push_transaction
#     equivalent anywhere in this file).
#   - It never reads or copies validator/staking/BLS signing material.
#   - It never runs on the validator host or web host (guard below).
#
# Env:
#   VALIDATOR_HOST        IP / hostname of the validator host (required
#                          unless --input-file is given; same convention as
#                          scripts/sync-to-validator-host.sh — never
#                          hardcoded so the repo stays public-safe).
#   VALIDATOR_HOST_KEY    SSH private key (default:
#                          ~/.ssh/<your_validator_host_key> — a literal
#                          placeholder, matching sync-to-validator-host.sh;
#                          host IP / real key names are never literal in
#                          this repo).
#   VALIDATOR_HOST_USER   SSH user (default: root).
#   REMOTE_ANCHOR_SOURCE_PATH
#                          path to anchor-source.json on the validator host
#                          (default: /home/deploy/metal.freedom-yield.com/
#                          public/api/anchor-source.json).
#   REPO_ROOT              path to repo (default: two levels above this
#                          script).
#   FYD_ANCHOR_FETCH_STUB  TEST-ONLY. If set, this shell command is run
#                          instead of the real SSH fetch, its stdout
#                          redirected to the same destination the real
#                          fetch would write to. No real SSH connection is
#                          ever made when this is set — the entire test
#                          suite sets it, exactly per the PRIME DIRECTIVE's
#                          "no exploratory broadcast/network calls in
#                          tests" spirit applied to this script's one
#                          network dependency.
#
# Usage:
#   bash scripts/operator-local/commit-anchor-source.sh --expect-cycle=N \
#     [--allow-genesis] [--push] [--input-file=PATH]
#
# Flags:
#   --expect-cycle=N   required; must equal the fetched file's
#                      observations_branch.cycle_number_observed.
#   --allow-genesis    allow identity_branch.prev_anchor_root /
#                      prev_anchor_tx to be null (first anchor only;
#                      without this flag, null in either field is refused).
#   --push             after a successful commit, `git push origin main`.
#                      Default: commit only, operator pushes by hand.
#   --input-file=PATH  read from PATH instead of SSH-fetching the host
#                      (manual/offline use; also how tests exercise this
#                      script's validation logic without any fetch stub).
#   -h|--help
#
# Exit codes:
#   0  success (committed, and pushed if --push)
#   2  bad arg / usage error (missing --expect-cycle, unknown flag)
#   3  fetch failed (SSH or --input-file read)
#   4  jq parse failed, or schema validation failed (includes exit 8's
#      "no validator available" case — folded into 4 here since both mean
#      "did not validate")
#   5  --expect-cycle mismatch
#   6  genesis guard failed (prev_anchor_root/tx null without --allow-genesis)
#   7  git add / git commit failed
#   8  git push failed (only reachable with --push)
#   99 host-refusal guard triggered (production-looking host detected)
#
# See also: docs/ANCHOR_SOURCE.md, docs/DEPLOY_OWNERSHIP_MATRIX.md,
# scripts/gen-anchor-source.sh (the host-side producer this transfers),
# scripts/advance-host-checkout.sh (protects host-composed
# anchor-source.json dirt from being discarded while it waits for this
# script to run).

set -euo pipefail

# ---- 1. Refuse to run anywhere except the operator's local Mac. -------------
# Identical guard to scripts/operator-local/gen-identity.sh:56-78 — see
# that file for the rationale (hostname/marker/deploy-user detection,
# defense in depth).

HN="$(hostname -s 2>/dev/null || hostname)"
case "$HN" in
	*validator*|*web*|*-prod*|*deploy*)
		echo "REFUSE: commit-anchor-source.sh on production-looking host '$HN'." >&2
		echo "        This script must only run on the operator's local Mac." >&2
		exit 99
		;;
esac

if [[ -f /etc/freedom-yield/web-host || -f /etc/freedom-yield/validator-host ]]; then
	echo "REFUSE: detected /etc/freedom-yield/{web-host,validator-host} — server detected." >&2
	exit 99
fi
if [[ -d /home/deploy ]] && id deploy >/dev/null 2>&1; then
	echo "REFUSE: detected 'deploy' user — refusing to run on what looks like a server." >&2
	exit 99
fi

# ---- 2. Resolve inputs / arg parsing ----------------------------------------

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
ANCHOR_SOURCE_REL="public/api/anchor-source.json"
CANONICAL_PATH="${REPO_ROOT}/${ANCHOR_SOURCE_REL}"
SCHEMA_FILE="${REPO_ROOT}/public/api/anchor-source.schema.v1.json"

EXPECT_CYCLE=""
ALLOW_GENESIS=0
DO_PUSH=0
INPUT_FILE=""

for arg in "$@"; do
	case "$arg" in
		--expect-cycle=*) EXPECT_CYCLE="${arg#--expect-cycle=}" ;;
		--allow-genesis)  ALLOW_GENESIS=1 ;;
		--push)           DO_PUSH=1 ;;
		--input-file=*)   INPUT_FILE="${arg#--input-file=}" ;;
		-h|--help)
			sed -n '2,90p' "$0" | sed 's/^# \?//'
			exit 0
			;;
		*)
			echo "ERROR: unknown arg: $arg" >&2
			exit 2
			;;
	esac
done

if [ -z "$EXPECT_CYCLE" ]; then
	echo "ERROR: --expect-cycle=N is required (see --help)" >&2
	exit 2
fi
case "$EXPECT_CYCLE" in
	''|*[!0-9]*)
		echo "ERROR: --expect-cycle must be a positive integer, got: '$EXPECT_CYCLE'" >&2
		exit 2
		;;
esac

require_cmd() {
	for c in "$@"; do
		if ! command -v "$c" >/dev/null 2>&1; then
			echo "ERROR: required command not found: $c" >&2
			exit 2
		fi
	done
}
require_cmd jq git diff

[ -r "$SCHEMA_FILE" ] || { echo "ERROR: schema file not readable: $SCHEMA_FILE" >&2; exit 2; }

# ---- 3. Fetch (SSH, isolated for test stubbing) -----------------------------

# fetch_remote_anchor_source <dst-file> — writes the host checkout's
# current bytes of anchor-source.json to <dst-file>. Isolated in its own
# function, and gated on FYD_ANCHOR_FETCH_STUB, so the test suite never
# makes a real SSH connection: it always sets the stub, which replaces
# this entire function body with a harmless local command (e.g. `cat` on
# a fixture file).
fetch_remote_anchor_source() {
	local dst="$1"
	if [ -n "${FYD_ANCHOR_FETCH_STUB:-}" ]; then
		bash -c "$FYD_ANCHOR_FETCH_STUB" > "$dst"
		return $?
	fi
	: "${VALIDATOR_HOST:?VALIDATOR_HOST env var is required (e.g. VALIDATOR_HOST=203.0.113.11), same convention as scripts/sync-to-validator-host.sh}"
	: "${VALIDATOR_HOST_KEY:=$HOME/.ssh/<your_validator_host_key>}"
	: "${VALIDATOR_HOST_USER:=root}"
	: "${REMOTE_ANCHOR_SOURCE_PATH:=/home/deploy/metal.freedom-yield.com/public/api/anchor-source.json}"
	if [ ! -f "$VALIDATOR_HOST_KEY" ]; then
		echo "ERROR: SSH key not found: $VALIDATOR_HOST_KEY" >&2
		return 1
	fi
	ssh -i "$VALIDATOR_HOST_KEY" "${VALIDATOR_HOST_USER}@${VALIDATOR_HOST}" \
		"cat '${REMOTE_ANCHOR_SOURCE_PATH}'" > "$dst"
}

FETCHED_FILE="$(mktemp -t fyd-commit-anchor-source.XXXXXX)"
cleanup_fetched() { rm -f "$FETCHED_FILE"; }
trap cleanup_fetched EXIT

if [ -n "$INPUT_FILE" ]; then
	[ -r "$INPUT_FILE" ] || { echo "ERROR: --input-file not readable: $INPUT_FILE" >&2; exit 3; }
	cp "$INPUT_FILE" "$FETCHED_FILE"
else
	if ! fetch_remote_anchor_source "$FETCHED_FILE"; then
		echo "ERROR: failed to fetch anchor-source.json from the validator host" >&2
		exit 3
	fi
fi

if [ ! -s "$FETCHED_FILE" ]; then
	echo "ERROR: fetched anchor-source.json is empty" >&2
	exit 3
fi

# ---- 4. Validate: jq parse + schema + expect-cycle + genesis guard --------

if ! jq empty "$FETCHED_FILE" >/dev/null 2>&1; then
	echo "ERROR: fetched anchor-source.json is not valid JSON" >&2
	exit 4
fi

# schema_validate_or_die — same R13 pattern as gen-anchor-source.sh /
# gen-anchor-receipt.sh / append-anchor-history.sh (duplicated per this
# repo's no-cross-script-sourcing convention; keep the four in sync). Try
# ajv first, then python3+jsonschema, else fail closed rather than
# silently skip validation.
schema_validate_or_die() {
	local schema="$1" data_file="$2" label="$3" out
	if [ ! -r "$schema" ]; then
		echo "ERROR: schema file not readable: $schema (cannot validate $label)" >&2
		return 6
	fi
	if command -v ajv >/dev/null 2>&1; then
		if out="$(ajv --spec=draft2020 --strict=false validate -s "$schema" -d "$data_file" 2>&1)"; then
			echo "OK: $label schema-valid (ajv)" >&2
			return 0
		fi
		echo "ERROR: $label failed schema validation against $schema (ajv)" >&2
		printf '%s\n' "$out" >&2
		return 6
	fi
	if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
		if out="$(python3 - "$schema" "$data_file" <<'PYEOF' 2>&1
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1], encoding="utf-8"))
data = json.load(open(sys.argv[2], encoding="utf-8"))
jsonschema.validate(instance=data, schema=schema, format_checker=jsonschema.FormatChecker())
PYEOF
		)"; then
			echo "OK: $label schema-valid (python3+jsonschema)" >&2
			return 0
		fi
		echo "ERROR: $label failed schema validation against $schema (python3+jsonschema)" >&2
		printf '%s\n' "$out" >&2
		return 6
	fi
	echo "ERROR: no JSON schema validator available (ajv absent; python3+jsonschema absent) — refusing to skip validation for $label. Install ajv-cli (npm i -g ajv-cli ajv-formats) or 'pip3 install jsonschema' (see scripts/setup-schema-validator.sh)." >&2
	return 8
}

if ! schema_validate_or_die "$SCHEMA_FILE" "$FETCHED_FILE" "fetched anchor-source.json"; then
	echo "ERROR: fetched anchor-source.json failed schema validation — refusing to commit" >&2
	exit 4
fi

FETCHED_CYCLE="$(jq -r '.observations_branch.cycle_number_observed' "$FETCHED_FILE")"
if [ "$FETCHED_CYCLE" != "$EXPECT_CYCLE" ]; then
	echo "ERROR: --expect-cycle=${EXPECT_CYCLE} does not match fetched observations_branch.cycle_number_observed=${FETCHED_CYCLE}" >&2
	echo "       Refusing to commit a different cycle's anchor than the operator expected." >&2
	exit 5
fi

PREV_ROOT="$(jq -r '.identity_branch.prev_anchor_root' "$FETCHED_FILE")"
PREV_TX="$(jq -r '.identity_branch.prev_anchor_tx' "$FETCHED_FILE")"
if { [ "$PREV_ROOT" = "null" ] || [ "$PREV_TX" = "null" ]; } && [ "$ALLOW_GENESIS" -ne 1 ]; then
	echo "ERROR: identity_branch.prev_anchor_root and/or prev_anchor_tx is null (prev_anchor_root=${PREV_ROOT}, prev_anchor_tx=${PREV_TX})." >&2
	echo "       This is only expected for the very first (genesis) anchor. Pass --allow-genesis if this really is the genesis anchor; otherwise investigate why the hash chain looks broken." >&2
	exit 6
fi

DAG_ROOT="$(jq -r '.dag_root_computed' "$FETCHED_FILE")"
DAG_SHORT="${DAG_ROOT:0:8}"

echo "OK: validated anchor-source.json — cycle ${FETCHED_CYCLE}, dag_root ${DAG_SHORT}..." >&2

# ---- 5. Diff summary against current repo copy -----------------------------

echo "--- diff summary (repo copy -> fetched) ---" >&2
if [ -f "$CANONICAL_PATH" ]; then
	diff -u <(jq -S . "$CANONICAL_PATH") <(jq -S . "$FETCHED_FILE") >&2 || true
else
	echo "(no existing repo copy at $ANCHOR_SOURCE_REL — this would be the first commit)" >&2
fi
echo "--- end diff summary ---" >&2

# ---- 6. Copy into repo, git add, single-purpose commit ---------------------

mkdir -p "$(dirname "$CANONICAL_PATH")"
cp "$FETCHED_FILE" "$CANONICAL_PATH"

if ! git -C "$REPO_ROOT" add "$ANCHOR_SOURCE_REL"; then
	echo "ERROR: git add failed for $ANCHOR_SOURCE_REL" >&2
	exit 7
fi

if git -C "$REPO_ROOT" diff --cached --quiet -- "$ANCHOR_SOURCE_REL"; then
	echo "OK: nothing to commit — repo copy already matches the fetched, validated anchor-source.json (cycle ${FETCHED_CYCLE}, dag_root ${DAG_SHORT}...)" >&2
	exit 0
fi

COMMIT_MSG="anchor-source: transfer cycle ${FETCHED_CYCLE} anchor (dag_root ${DAG_SHORT})

Host-composed by gen-anchor-source.sh on the validator host; fetched,
validated (schema + expect-cycle + genesis guard), and committed via
commit-anchor-source.sh."

if ! git -C "$REPO_ROOT" commit -q -m "$COMMIT_MSG"; then
	echo "ERROR: git commit failed" >&2
	exit 7
fi

COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
echo "OK: committed ${COMMIT_SHA} — anchor-source: transfer cycle ${FETCHED_CYCLE} anchor (dag_root ${DAG_SHORT})" >&2

# ---- 7. Optional push -------------------------------------------------------

if [ "$DO_PUSH" -eq 1 ]; then
	if ! git -C "$REPO_ROOT" push origin main; then
		echo "ERROR: git push origin main failed (commit ${COMMIT_SHA} is local-only)" >&2
		exit 8
	fi
	echo "OK: pushed ${COMMIT_SHA} to origin main" >&2
else
	echo "NOTE: not pushed (pass --push to push origin main). Commit ${COMMIT_SHA} is local-only." >&2
fi

exit 0
