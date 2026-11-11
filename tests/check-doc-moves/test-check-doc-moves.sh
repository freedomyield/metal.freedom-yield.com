#!/usr/bin/env bash
# test-check-doc-moves.sh — suite for scripts/check-doc-moves.sh (gate G1 of the
# 2026-11-10 simplify refactor): after documents are moved or scripts deleted, no
# live file may still name the old path, and a `docs/` move must be byte-identical.
#
# Every case builds a throwaway git repo (mktemp -d, removed by trap), commits a
# base, changes the tree, commits again and runs G1 there. G1 must fail closed:
# a git error, a missing argument or an unreadable file is exit 2, never `OK`.
#
# CHAIN: none — local temporary git repos only; no host, no network, no broadcast.
#
# Usage:
#   bash tests/check-doc-moves/test-check-doc-moves.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G1="${REPO_ROOT}/scripts/check-doc-moves.sh"
GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; WORK=""; }
trap cleanup EXIT

OUT=""
RC=0

# fresh_repo: new repo in $WORK/r with a base commit (docs/A.md, docs/B.md, scripts/old.sh, README.md, TOOLKIT.md).
fresh_repo() {
	cleanup
	WORK="$(mktemp -d -t check-doc-moves-test.XXXXXX)" || exit 1
	mkdir -p "$WORK/r"
	cd "$WORK/r" || exit 1
	git init -q . >/dev/null 2>&1
	mkdir -p docs scripts
	printf 'alpha\nbeta\ngamma\n' > docs/A.md
	printf 'bravo\n' > docs/B.md
	printf '#!/usr/bin/env bash\necho old\n' > scripts/old.sh
	printf '# readme\nplain line\nno refs here\n' > README.md
	printf '# toolkit\nnothing\n' > TOOLKIT.md
	git add docs scripts README.md TOOLKIT.md
	git "${GITQ[@]}" commit -q -m base
	BASE="$(git rev-parse HEAD)"
}

commit_all() { git add -A >/dev/null 2>&1; git "${GITQ[@]}" commit -q -m change; }

run_g1() { OUT="$(bash "$G1" "$@" 2>"$WORK/stderr")"; RC=$?; }

expect() { # name want_rc [grep -F pattern in stdout]
	local name="$1" want="$2" pat="${3:-}"
	if [ "$RC" -ne "$want" ]; then bad "$name (rc=$RC want=$want out=$(printf '%s' "$OUT" | tail -n 2 | tr '\n' '|'))"; return; fi
	if [ -n "$pat" ] && ! printf '%s\n' "$OUT" | grep -qF -- "$pat"; then bad "$name (missing output: $pat)"; return; fi
	ok "$name"
}
no_ok() { # name : stdout must not contain a line starting with OK
	if printf '%s\n' "$OUT" | grep -q '^OK'; then bad "$1 (printed OK)"; else ok "$1"; fi
}

if [ ! -f "$G1" ]; then
	echo "FATAL: gate not found at $G1" >&2
	# Red phase of TDD: the cases below fail because the script is missing.
fi

# ---- clean_move -------------------------------------------------------------------------
fresh_repo
mkdir -p docs/audits && git mv docs/A.md docs/audits/A.md && commit_all
run_g1 --base="$BASE"
expect "clean_move: rc 0, OK 1 moves" 0 "OK 1 moves"

# ---- no_moves ---------------------------------------------------------------------------
fresh_repo
printf 'more\n' >> README.md && commit_all
run_g1 --base="$BASE"
expect "no_moves: rc 0, OK 0 moves" 0 "OK 0 moves"

# ---- partial_similarity -----------------------------------------------------------------
fresh_repo
mkdir -p docs/audits && git mv docs/A.md docs/audits/A.md
printf 'alpha\nbeta\nCHANGED\n' > docs/audits/A.md && commit_all
run_g1 --base="$BASE"
expect "partial_similarity: rc 1, similarity VIOLATION" 1 "similarity"

# ---- docs_deleted -----------------------------------------------------------------------
fresh_repo
git rm -q docs/B.md && commit_all
run_g1 --base="$BASE"
expect "docs_deleted: rc 1, deleted VIOLATION" 1 "VIOLATION docs/B.md:0 docs/B.md -> (deleted)"

# ---- stale_basename ---------------------------------------------------------------------
fresh_repo
printf '# readme\nplain line\nsee docs/A.md here\n' > README.md
git add README.md && git "${GITQ[@]}" commit -q -m refs && BASE="$(git rev-parse HEAD)"
mkdir -p docs/audits && git mv docs/A.md docs/audits/A.md && commit_all
run_g1 --base="$BASE"
expect "stale_basename: rc 1, exact line" 1 "VIOLATION README.md:3 docs/A.md -> docs/audits/A.md"

# ---- relative_link (Review Focus 1) -----------------------------------------------------
fresh_repo
printf 'see [a](audits/A.md)\n' > docs/X.md && git add docs/X.md && git "${GITQ[@]}" commit -q -m x && BASE="$(git rev-parse HEAD)"
mkdir -p docs/audits && git mv docs/A.md docs/audits/A.md && commit_all
run_g1 --base="$BASE"
expect "relative_link: rc 1" 1 "VIOLATION docs/X.md:1"

# ---- mixed_line (Review Focus 2) --------------------------------------------------------
fresh_repo
mkdir -p docs/audits && git mv docs/A.md docs/audits/A.md
printf 'new docs/audits/A.md and old A.md on one line\n' > docs/X.md && commit_all
run_g1 --base="$BASE"
expect "mixed_line: rc 1" 1 "VIOLATION docs/X.md:1"

# ---- new_path_ok ------------------------------------------------------------------------
fresh_repo
mkdir -p docs/audits && git mv docs/A.md docs/audits/A.md
printf 'see docs/audits/A.md\nand docs/audits/A.md again, docs/audits/A.md\n' > docs/X.md && commit_all
run_g1 --base="$BASE"
expect "new_path_ok: rc 0" 0 "OK 1 moves"

# ---- exempt_refs ------------------------------------------------------------------------
fresh_repo
mkdir -p docs/audits docs/archive docs/superpowers/plans
printf 'mentions docs/A.md\n' > docs/audits/old.md
printf 'mentions docs/A.md\n' > docs/archive/x.md
printf 'mentions docs/A.md\n' > docs/CYCLE_GATE_DAILY_OBSERVATION.md
printf 'mentions docs/A.md\n' > docs/superpowers/plans/2099-simplify-refactor-x.md
git add docs && git "${GITQ[@]}" commit -q -m exempt && BASE="$(git rev-parse HEAD)"
git mv docs/A.md docs/audits/A.md && commit_all
run_g1 --base="$BASE"
expect "exempt_refs: rc 0 (exempt set only)" 0 "OK 1 moves"

# ---- exempt_narrow ----------------------------------------------------------------------
fresh_repo
mkdir -p docs/superpowers/plans docs/superpowers/specs/sub
printf 'mentions docs/A.md\n' > docs/superpowers/plans/2099-other.md
printf 'mentions docs/A.md\n' > docs/superpowers/specs/sub/simplify-refactor.md
git add docs && git "${GITQ[@]}" commit -q -m narrow && BASE="$(git rev-parse HEAD)"
mkdir -p docs/audits && git mv docs/A.md docs/audits/A.md && commit_all
run_g1 --base="$BASE"
expect "exempt_narrow: rc 1" 1 "FAIL 2"

# ---- deleted_script_ref -----------------------------------------------------------------
fresh_repo
printf '# toolkit\nuse scripts/old.sh now\n' > TOOLKIT.md
git add TOOLKIT.md && git "${GITQ[@]}" commit -q -m ref && BASE="$(git rev-parse HEAD)"
git rm -q scripts/old.sh && commit_all
run_g1 --base="$BASE"
expect "deleted_script_ref: rc 1" 1 "VIOLATION TOOLKIT.md:2 scripts/old.sh -> (deleted)"

fresh_repo
mkdir -p docs/audits
printf 'use scripts/old.sh\n' > docs/audits/note.md
git add docs && git "${GITQ[@]}" commit -q -m ref && BASE="$(git rev-parse HEAD)"
git rm -q scripts/old.sh && commit_all
run_g1 --base="$BASE"
expect "deleted_script_ref_exempt: rc 0" 0 "OK 0 moves"

# ---- fail closed: arguments and git errors ----------------------------------------------
fresh_repo
run_g1
expect "missing_base: rc 2" 2
no_ok "missing_base: no OK"
run_g1 --base=
expect "empty_base: rc 2" 2
run_g1 --bogus
expect "unknown_arg: rc 2" 2
run_g1 --base="$BASE" --bogus
expect "unknown_arg_after_base: rc 2" 2
run_g1 --base=deadbeef
expect "bad_base: rc 2" 2
no_ok "bad_base: no OK"
(
	NOREPO="$(mktemp -d -t check-doc-moves-norepo.XXXXXX)" || exit 1
	cd "$NOREPO" || exit 1
	OUT="$(GIT_CEILING_DIRECTORIES="$(dirname "$NOREPO")" bash "$G1" --base=HEAD 2>/dev/null)"; RC=$?
	rm -rf "$NOREPO"
	if [ "$RC" -eq 2 ] && ! printf '%s\n' "$OUT" | grep -q '^OK'; then echo "PASS  not_a_repo: rc 2, no OK"; else echo "FAIL  not_a_repo (rc=$RC)"; fi
) > "$WORK/notarepo.out" 2>&1
cat "$WORK/notarepo.out"
grep -q '^PASS' "$WORK/notarepo.out" && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# ---- unknown status letter (type change) -------------------------------------------------
fresh_repo
rm README.md && ln -s docs/A.md README.md && commit_all
run_g1 --base="$BASE"
expect "unknown_status_letter: rc 2" 2
no_ok "unknown_status_letter: no OK"

# ---- unreadable file ---------------------------------------------------------------------
fresh_repo
printf 'secret\n' > docs/Z.md && git add docs/Z.md && git "${GITQ[@]}" commit -q -m z && BASE="$(git rev-parse HEAD)"
mkdir -p docs/audits && git mv docs/A.md docs/audits/A.md && commit_all
chmod 000 docs/Z.md
run_g1 --base="$BASE"
chmod 644 docs/Z.md
expect "unreadable_file: rc 2" 2
no_ok "unreadable_file: no OK"

# ---- space_in_name (Review Focus 5) -----------------------------------------------------
fresh_repo
printf 'spaced\n' > "docs/a b.md" && git add "docs/a b.md" && git "${GITQ[@]}" commit -q -m sp && BASE="$(git rev-parse HEAD)"
mkdir -p docs/audits && git mv "docs/a b.md" "docs/audits/a b.md" && commit_all
run_g1 --base="$BASE"
expect "space_in_name: rc 0, OK 1 moves" 0 "OK 1 moves"

# ---- non-docs rename: similarity unchecked, basename refs still checked (Review Focus 4) --
fresh_repo
printf 'one\ntwo\nthree\nfour\n' > notes.txt
printf 'see notes.txt\n' > docs/ref.md
git add notes.txt docs/ref.md && git "${GITQ[@]}" commit -q -m n && BASE="$(git rev-parse HEAD)"
mkdir -p misc && git mv notes.txt misc/notes.txt
printf 'one\ntwo\nthree\nfour\nfive\n' > misc/notes.txt && commit_all
run_g1 --base="$BASE"
expect "nondocs_rename: similarity not checked, basename ref still caught" 1 "VIOLATION docs/ref.md:1 notes.txt -> misc/notes.txt"
if printf '%s\n' "$OUT" | grep -q 'similarity'; then bad "nondocs_rename: similarity must not be flagged"; else ok "nondocs_rename: no similarity line"; fi

# ---- scripts/ rename: similarity below 100 is a violation (spec: "under docs/ or scripts/") -
# old and new both under scripts/ (docs/ not involved): a changed body must be flagged.
fresh_repo
printf '#!/usr/bin/env bash\necho one\necho two\necho three\necho four\n' > scripts/move.sh
git add scripts/move.sh && git "${GITQ[@]}" commit -q -m mv && BASE="$(git rev-parse HEAD)"
mkdir -p scripts/sub && git mv scripts/move.sh scripts/sub/move.sh
printf '#!/usr/bin/env bash\necho one\necho two\necho three\necho CHANGED\n' > scripts/sub/move.sh && commit_all
run_g1 --base="$BASE"
expect "scripts_rename_similarity: scripts/ -> scripts/, rc 1, similarity VIOLATION" 1 "VIOLATION scripts/sub/move.sh:0 scripts/move.sh -> scripts/sub/move.sh similarity"

# old under scripts/, new outside both docs/ and scripts/: the old side alone must count.
fresh_repo
printf '#!/usr/bin/env bash\necho one\necho two\necho three\necho four\n' > scripts/move.sh
git add scripts/move.sh && git "${GITQ[@]}" commit -q -m mv && BASE="$(git rev-parse HEAD)"
mkdir -p tools && git mv scripts/move.sh tools/move.sh
printf '#!/usr/bin/env bash\necho one\necho two\necho three\necho CHANGED\n' > tools/move.sh && commit_all
run_g1 --base="$BASE"
expect "scripts_rename_similarity_old_side: scripts/ -> tools/, rc 1, similarity VIOLATION" 1 "VIOLATION tools/move.sh:0 scripts/move.sh -> tools/move.sh similarity"

# old outside, new under scripts/: the new side alone must count.
fresh_repo
printf '#!/usr/bin/env bash\necho one\necho two\necho three\necho four\n' > tools_move.sh
git add tools_move.sh && git "${GITQ[@]}" commit -q -m mv && BASE="$(git rev-parse HEAD)"
git mv tools_move.sh scripts/move.sh
printf '#!/usr/bin/env bash\necho one\necho two\necho three\necho CHANGED\n' > scripts/move.sh && commit_all
run_g1 --base="$BASE"
expect "scripts_rename_similarity_new_side: other -> scripts/, rc 1, similarity VIOLATION" 1 "VIOLATION scripts/move.sh:0 tools_move.sh -> scripts/move.sh similarity"

# ---- exempt set is narrow: the file just outside each exempt element still counts -----------
# Each case moves docs/A.md and puts one file naming the old path just outside one element
# of the exempt set. G1 must report exactly that file (rc 1, one VIOLATION, FAIL 1).
outside_case() { # name relative-path-of-referencing-file
	local name="$1" ref="$2"
	fresh_repo
	mkdir -p "$(dirname "$ref")"
	printf 'mentions docs/A.md\n' > "$ref"
	git add "$ref" && git "${GITQ[@]}" commit -q -m outside && BASE="$(git rev-parse HEAD)"
	mkdir -p docs/audits && git mv docs/A.md docs/audits/A.md && commit_all
	run_g1 --base="$BASE"
	expect "${name}: rc 1, VIOLATION ${ref}:1" 1 "VIOLATION ${ref}:1 docs/A.md -> docs/audits/A.md"
	if [ "$RC" -eq 1 ] && ! printf '%s\n' "$OUT" | grep -qxF "FAIL 1"; then bad "${name}: count must be exactly FAIL 1"; fi
}
outside_case "exempt_outside_audits_prefix" "docs/auditsX.md"
outside_case "exempt_outside_audits_dash_dir" "docs/audits-old/note.md"
outside_case "exempt_outside_archive_prefix" "docs/archiveX.md"
outside_case "exempt_outside_docs_a_prefix" "docs/ahead.md"
outside_case "exempt_outside_cycle_gate_other" "docs/CYCLE_GATE_OTHER.md"
outside_case "exempt_outside_superpowers_other_dir" "docs/superpowers/notes/2099-simplify-refactor-x.md"
outside_case "exempt_outside_repo_root_simplify_refactor" "2099-simplify-refactor-x.md"

cd "$REPO_ROOT" || exit 1
echo ""
echo "test-check-doc-moves.sh summary: PASS=${PASS}  FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
