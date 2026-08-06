#!/usr/bin/env bash
# scripts/operator-local/test-commit-anchor-source.sh
#
# Hermetic test suite for commit-anchor-source.sh. Builds a throwaway git
# repo in a tempdir, uses --input-file / FYD_ANCHOR_FETCH_STUB to feed
# fixture JSON instead of ever making a real SSH connection, and asserts
# on exit codes, commit presence/absence, and committed content.
#
# CHAIN: none — no real SSH, no real validator host, no broadcast-capable
#        commands invoked anywhere in this suite (PRIME DIRECTIVE: safe).
#
# The host-refusal guard (hostname / /etc/freedom-yield marker /
# 'deploy' user detection) is a byte-for-byte copy of gen-identity.sh's
# already-shipped guard and is NOT functionally exercised here — mirrors
# gen-identity.sh's own test-gen-identity.sh, which does not exercise its
# copy of the same guard either (there is no repo convention for safely
# faking hostname/marker-file/deploy-user detection in a test).
#
# Usage:
#   bash scripts/operator-local/test-commit-anchor-source.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

# Hermeticity: force a git commit identity for every git command this suite
# (and the committer script it drives) runs, regardless of the ambient
# environment. This matters because GIT_AUTHOR_NAME / GIT_COMMITTER_NAME
# environment variables — if merely *set*, even to an empty string — take
# precedence over ALL config sources (system, global, local repo config,
# and `-c user.name=...` on the command line alike). A CI runner with no
# global git identity and an empty GECOS name derives an empty name and
# `git commit` dies with "empty ident name ... not allowed"; per-command
# `-c user.name=` (see GITQ below) does NOT help in that case, because the
# empty env var already won. Exporting non-empty values here is the one
# thing that actually wins in every environment. Values are obviously fake
# test fixtures (.invalid is the RFC 2606 reserved-for-testing TLD) — never
# a real operator name/email.
export GIT_AUTHOR_NAME="FYD Hermetic Test Suite"
export GIT_AUTHOR_EMAIL="fyd-hermetic-test@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT_REAL="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMITTER="${SCRIPT_DIR}/commit-anchor-source.sh"
REAL_SCHEMA="${REPO_ROOT_REAL}/public/api/anchor-source.schema.v1.json"

if [ ! -f "$COMMITTER" ]; then
	echo "FATAL: committer not found at $COMMITTER" >&2
	exit 1
fi
if [ ! -r "$REAL_SCHEMA" ]; then
	echo "FATAL: real schema not found at $REAL_SCHEMA" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

BASE=""; REPO=""; GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)

# build_repo — fresh scratch git repo with a real (copied) schema file at
# public/api/anchor-source.schema.v1.json, one seed commit, no existing
# anchor-source.json (first commit in every case starts genesis-shaped
# from the repo's point of view; individual cases layer a prior anchor
# commit on top when they need an "existing repo copy" to diff against).
build_repo() {
	BASE="$(mktemp -d -t commit-anchor-source-test.XXXXXX)"
	REPO="$BASE/repo"
	mkdir -p "$REPO/public/api"
	cp "$REAL_SCHEMA" "$REPO/public/api/anchor-source.schema.v1.json"
	git -C "$REPO" "${GITQ[@]}" init -q -b main 2>/dev/null || { mkdir -p "$REPO"; git -C "$REPO" "${GITQ[@]}" init -q -b main; }
	git -C "$REPO" "${GITQ[@]}" add -A
	git -C "$REPO" "${GITQ[@]}" commit -qm seed
}
teardown() { rm -rf "$BASE"; BASE=""; }

run_committer() {
	REPO_ROOT="$REPO" bash "$COMMITTER" "$@"
}

# fixture <cycle> <prev_root> <prev_tx> <dag_root_char> -> writes a
# schema-valid anchor-source.json fixture to stdout. prev_root/prev_tx
# pass the literal string "null" for the genesis case; otherwise a 64-hex
# string is expected. dag_root_char is repeated 64x to make each fixture's
# dag_root trivially distinguishable in assertions.
fixture() {
	local cycle="$1" prev_root="$2" prev_tx="$3" dag_char="$4"
	local prev_root_jq prev_tx_jq
	if [ "$prev_root" = "null" ]; then prev_root_jq="null"; else prev_root_jq="\"$prev_root\""; fi
	if [ "$prev_tx" = "null" ]; then prev_tx_jq="null"; else prev_tx_jq="\"$prev_tx\""; fi
	jq -n \
		--argjson cycle "$cycle" \
		--argjson prev_root "$prev_root_jq" \
		--argjson prev_tx "$prev_tx_jq" \
		--arg dag "$(printf "${dag_char}%.0s" $(seq 1 64))" \
		'{
			"$schema": "https://metal.freedom-yield.com/api/anchor-source.schema.v1.json",
			schema_version: 1,
			computed_at: "2026-08-04T00:00:00Z",
			computed_by_script: "gen-anchor-source.sh v1.0",
			computed_from_git_commit: "0000000000000000000000000000000000000000",
			identity_branch: {
				operator_ed25519_pubkey_sha256_hex: ("0" * 64),
				operator_asserts_node_id: "NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v",
				prev_anchor_root: $prev_root,
				prev_anchor_tx: $prev_tx,
				key_seq: 1,
				identity_history_root: ("c" * 64)
			},
			observations_branch: {
				cycle_number_observed: $cycle,
				cycle_start_time_observed: "2026-08-04T00:00:00Z",
				cycle_end_time_observed: null,
				self_stake_observed_metal: 14060,
				self_stake_observed_nmetal: "14060000000000",
				fee_percent_observed_at_cycle_start: 3,
				delegator_lifecycle_events_in_cycle_observed: [],
				delegator_snapshot_at_cycle_end: []
			},
			artifacts_branch: {
				public_api_manifest_root: ("d" * 64),
				public_api_files_hashed: [{path: "validator.json", sha256: ("e" * 64)}],
				period_uptime_observed_pct: 99.9,
				period_incident_count_observed: 0
			},
			dag_root_computed: $dag
		}'
}

commit_count() { git -C "$REPO" log --oneline | wc -l | tr -d ' '; }

# ---- case 1: fresh repo, valid non-genesis fixture, matching --expect-cycle
#      -> commit succeeds, content matches, commit message carries cycle +
#      dag_root prefix, NOT pushed by default. ------------------------------
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
BEFORE_COUNT="$(commit_count)"
OUT="$(run_committer --expect-cycle=4 --input-file="$BASE/f-cycle4.json" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "fresh-commit: exit 0" \
	|| bad "fresh-commit: exit 0 (actual=$RC, out=$OUT)"
[ "$(commit_count)" -eq $((BEFORE_COUNT + 1)) ] \
	&& ok "fresh-commit: exactly one new commit" \
	|| bad "fresh-commit: exactly one new commit (before=$BEFORE_COUNT, after=$(commit_count))"
[ "$(git -C "$REPO" show HEAD:public/api/anchor-source.json | jq -c .)" = "$(jq -c . "$BASE/f-cycle4.json")" ] \
	&& ok "fresh-commit: committed content matches fetched fixture" \
	|| bad "fresh-commit: committed content matches fetched fixture"
git -C "$REPO" log -1 --format=%s | grep -qE 'cycle 4' \
	&& ok "fresh-commit: commit subject names cycle 4" \
	|| bad "fresh-commit: commit subject names cycle 4 (got: $(git -C "$REPO" log -1 --format=%s))"
git -C "$REPO" log -1 --format=%s | grep -qE 'ffffffff' \
	&& ok "fresh-commit: commit subject names dag_root prefix" \
	|| bad "fresh-commit: commit subject names dag_root prefix (got: $(git -C "$REPO" log -1 --format=%s))"
echo "$OUT" | grep -qi 'not pushed' \
	&& ok "fresh-commit: reports not-pushed by default" \
	|| bad "fresh-commit: reports not-pushed by default (out: $OUT)"
teardown

# ---- case 2: --expect-cycle mismatch -> exit 5, no commit created --------
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
BEFORE_COUNT="$(commit_count)"
run_committer --expect-cycle=5 --input-file="$BASE/f-cycle4.json" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 5 ] \
	&& ok "cycle-mismatch: exit 5" \
	|| bad "cycle-mismatch: exit 5 (actual=$RC)"
[ "$(commit_count)" -eq "$BEFORE_COUNT" ] \
	&& ok "cycle-mismatch: no commit created" \
	|| bad "cycle-mismatch: no commit created (before=$BEFORE_COUNT, after=$(commit_count))"
teardown

# ---- case 3: genesis fixture (null prev_root/prev_tx) WITHOUT
#      --allow-genesis -> exit 6, no commit. --------------------------------
build_repo
fixture 1 null null a > "$BASE/f-genesis.json"
BEFORE_COUNT="$(commit_count)"
run_committer --expect-cycle=1 --input-file="$BASE/f-genesis.json" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 6 ] \
	&& ok "genesis-guard: exit 6 without --allow-genesis" \
	|| bad "genesis-guard: exit 6 without --allow-genesis (actual=$RC)"
[ "$(commit_count)" -eq "$BEFORE_COUNT" ] \
	&& ok "genesis-guard: no commit created" \
	|| bad "genesis-guard: no commit created"
teardown

# ---- case 4: same genesis fixture WITH --allow-genesis -> exit 0, commit
#      created. -------------------------------------------------------------
build_repo
fixture 1 null null a > "$BASE/f-genesis.json"
BEFORE_COUNT="$(commit_count)"
run_committer --expect-cycle=1 --allow-genesis --input-file="$BASE/f-genesis.json" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "genesis-guard: exit 0 with --allow-genesis" \
	|| bad "genesis-guard: exit 0 with --allow-genesis (actual=$RC)"
[ "$(commit_count)" -eq $((BEFORE_COUNT + 1)) ] \
	&& ok "genesis-guard: commit created with --allow-genesis" \
	|| bad "genesis-guard: commit created with --allow-genesis"
teardown

# ---- case 5: malformed JSON -> exit 4, no commit --------------------------
build_repo
printf 'not json at all {' > "$BASE/bad.json"
BEFORE_COUNT="$(commit_count)"
run_committer --expect-cycle=1 --input-file="$BASE/bad.json" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 4 ] \
	&& ok "malformed-json: exit 4" \
	|| bad "malformed-json: exit 4 (actual=$RC)"
[ "$(commit_count)" -eq "$BEFORE_COUNT" ] \
	&& ok "malformed-json: no commit created" \
	|| bad "malformed-json: no commit created"
teardown

# ---- case 6: valid JSON but schema-invalid (missing required field)
#      -> exit 4, no commit. -------------------------------------------------
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f | jq 'del(.dag_root_computed)' > "$BASE/f-invalid.json"
BEFORE_COUNT="$(commit_count)"
run_committer --expect-cycle=4 --input-file="$BASE/f-invalid.json" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 4 ] \
	&& ok "schema-invalid: exit 4" \
	|| bad "schema-invalid: exit 4 (actual=$RC)"
[ "$(commit_count)" -eq "$BEFORE_COUNT" ] \
	&& ok "schema-invalid: no commit created" \
	|| bad "schema-invalid: no commit created"
teardown

# ---- case 7: missing --expect-cycle -> exit 2, no commit ------------------
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
BEFORE_COUNT="$(commit_count)"
run_committer --input-file="$BASE/f-cycle4.json" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "missing-expect-cycle: exit 2" \
	|| bad "missing-expect-cycle: exit 2 (actual=$RC)"
[ "$(commit_count)" -eq "$BEFORE_COUNT" ] \
	&& ok "missing-expect-cycle: no commit created" \
	|| bad "missing-expect-cycle: no commit created"
teardown

# ---- case 8: idempotent — fetched content already matches the current
#      repo copy exactly -> exit 0, "nothing to commit", no new commit. -----
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
run_committer --expect-cycle=4 --input-file="$BASE/f-cycle4.json" >/dev/null 2>&1
AFTER_FIRST_COUNT="$(commit_count)"
OUT="$(run_committer --expect-cycle=4 --input-file="$BASE/f-cycle4.json" 2>&1)"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "idempotent: exit 0 on re-run with identical content" \
	|| bad "idempotent: exit 0 on re-run with identical content (actual=$RC, out=$OUT)"
[ "$(commit_count)" -eq "$AFTER_FIRST_COUNT" ] \
	&& ok "idempotent: no new commit created" \
	|| bad "idempotent: no new commit created (before=$AFTER_FIRST_COUNT, after=$(commit_count))"
echo "$OUT" | grep -qi 'nothing to commit' \
	&& ok "idempotent: reports nothing to commit" \
	|| bad "idempotent: reports nothing to commit (out: $OUT)"
teardown

# ---- case 9: FYD_ANCHOR_FETCH_STUB path (no --input-file) — verifies the
#      SSH-fetch function is stubbable and that no real SSH connection is
#      attempted. --------------------------------------------------------
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
BEFORE_COUNT="$(commit_count)"
FYD_ANCHOR_FETCH_STUB="cat $BASE/f-cycle4.json" REPO_ROOT="$REPO" bash "$COMMITTER" --expect-cycle=4 >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "fetch-stub: exit 0 via FYD_ANCHOR_FETCH_STUB (no --input-file)" \
	|| bad "fetch-stub: exit 0 via FYD_ANCHOR_FETCH_STUB (actual=$RC)"
[ "$(commit_count)" -eq $((BEFORE_COUNT + 1)) ] \
	&& ok "fetch-stub: commit created" \
	|| bad "fetch-stub: commit created"
teardown

# ---- case 10: --push with no remote configured -> exit 8, but the commit
#      itself still landed (push failure does not roll back the commit). --
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
BEFORE_COUNT="$(commit_count)"
run_committer --expect-cycle=4 --input-file="$BASE/f-cycle4.json" --push >/dev/null 2>&1
RC=$?
[ "$RC" -eq 8 ] \
	&& ok "push-fails-no-remote: exit 8" \
	|| bad "push-fails-no-remote: exit 8 (actual=$RC)"
[ "$(commit_count)" -eq $((BEFORE_COUNT + 1)) ] \
	&& ok "push-fails-no-remote: commit still landed locally" \
	|| bad "push-fails-no-remote: commit still landed locally"
teardown

# ---- case 11: unknown flag -> exit 2, no commit ---------------------------
build_repo
BEFORE_COUNT="$(commit_count)"
run_committer --this-flag-does-not-exist >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "unknown-flag: exit 2" \
	|| bad "unknown-flag: exit 2 (actual=$RC)"
[ "$(commit_count)" -eq "$BEFORE_COUNT" ] \
	&& ok "unknown-flag: no commit created" \
	|| bad "unknown-flag: no commit created"
teardown

# ---- case 12: non-integer --expect-cycle -> exit 2 ------------------------
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
run_committer --expect-cycle=notanumber --input-file="$BASE/f-cycle4.json" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "non-integer-expect-cycle: exit 2" \
	|| bad "non-integer-expect-cycle: exit 2 (actual=$RC)"
teardown

# ---- case 13 (fix round 1, fold-in minor): --expect-cycle=0 -> exit 2 -----
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
run_committer --expect-cycle=0 --input-file="$BASE/f-cycle4.json" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "expect-cycle-zero: exit 2" \
	|| bad "expect-cycle-zero: exit 2 (actual=$RC)"
teardown

# ---- case 14 (fix round 1, fold-in minor): --expect-cycle=007 (leading
#      zero) -> exit 2 -------------------------------------------------------
build_repo
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
run_committer --expect-cycle=007 --input-file="$BASE/f-cycle4.json" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "expect-cycle-leading-zero: exit 2" \
	|| bad "expect-cycle-leading-zero: exit 2 (actual=$RC)"
teardown

# ---- case 15 (C2 fix): --push refused when the repo is NOT on main ------
#      Reproduces the reviewer-found bug: git push origin main pushes
#      whatever branch is checked out to origin's main ref, which would
#      otherwise silently push feature-branch content while still
#      reporting "OK: pushed". Must refuse BEFORE committing (so there is
#      no local-only commit left behind either) whenever --push is given
#      off main. -------------------------------------------------------------
build_repo
git -C "$REPO" "${GITQ[@]}" checkout -qb some-feature-branch
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
BEFORE_COUNT="$(commit_count)"
OUT="$(run_committer --expect-cycle=4 --input-file="$BASE/f-cycle4.json" --push 2>&1)"
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "push-refused-off-main: exit 2" \
	|| bad "push-refused-off-main: exit 2 (actual=$RC, out=$OUT)"
[ "$(commit_count)" -eq "$BEFORE_COUNT" ] \
	&& ok "push-refused-off-main: no commit created (not even local-only)" \
	|| bad "push-refused-off-main: no commit created (before=$BEFORE_COUNT, after=$(commit_count))"
echo "$OUT" | grep -qi 'pushed' \
	&& bad "push-refused-off-main: never claims anything was pushed (out: $OUT)" \
	|| ok "push-refused-off-main: never claims anything was pushed"
teardown

# ---- case 16 (I3 fix): refuses to commit when other files are already
#      staged besides anchor-source.json — otherwise `git commit` (no
#      pathspec) would sweep pre-staged unrelated changes into this
#      "single-purpose" commit. The unrelated staged file must remain
#      staged and untouched afterward (this script only ever refuses; it
#      never unstages anything on the operator's behalf). -----------------
build_repo
printf 'unrelated pre-staged content\n' > "$REPO/unrelated-file.txt"
git -C "$REPO" "${GITQ[@]}" add unrelated-file.txt
UNRELATED_CONTENT_BEFORE="$(git -C "$REPO" show :unrelated-file.txt)"
fixture 4 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" f > "$BASE/f-cycle4.json"
BEFORE_COUNT="$(commit_count)"
OUT="$(run_committer --expect-cycle=4 --input-file="$BASE/f-cycle4.json" 2>&1)"
RC=$?
[ "$RC" -eq 7 ] \
	&& ok "refuse-other-staged: exit 7" \
	|| bad "refuse-other-staged: exit 7 (actual=$RC, out=$OUT)"
[ "$(commit_count)" -eq "$BEFORE_COUNT" ] \
	&& ok "refuse-other-staged: no commit created" \
	|| bad "refuse-other-staged: no commit created"
# The script's own `git add` on anchor-source.json is expected to remain
# staged (that path is exactly what this script manages) — what must NOT
# happen is the unrelated file being touched, unstaged, or its content
# changed on the operator's behalf.
git -C "$REPO" diff --cached --name-only | grep -q -x 'unrelated-file.txt' \
	&& ok "refuse-other-staged: unrelated file still staged (script never unstages on operator's behalf)" \
	|| bad "refuse-other-staged: unrelated file still staged (staged now: $(git -C "$REPO" diff --cached --name-only))"
[ "$(git -C "$REPO" show :unrelated-file.txt)" = "$UNRELATED_CONTENT_BEFORE" ] \
	&& ok "refuse-other-staged: unrelated file's staged content unchanged" \
	|| bad "refuse-other-staged: unrelated file's staged content unchanged"
echo "$OUT" | grep -q 'unrelated-file.txt' \
	&& ok "refuse-other-staged: error names the unrelated staged file" \
	|| bad "refuse-other-staged: error names the unrelated staged file (out: $OUT)"
teardown

# ---- summary ---------------------------------------------------------------
echo "test-commit-anchor-source.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
