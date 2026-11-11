#!/usr/bin/env bash
# test-check-duplicate-functions.sh — suite for scripts/check-duplicate-functions.sh
# (gate G2 of the 2026-11-10 simplify refactor): a function name defined in two or
# more scripts must be a thin wrapper around a library function, or a row in
# scripts/duplicate-functions.allow must say why the copy stays.
#
# Every case builds a throwaway git repo (mktemp -d, removed by trap), writes a few
# scripts, and runs G2 there. G2 must fail closed: a missing or malformed input is
# exit 2 and never prints `OK`; an allowlist row that matches nothing is OBSOLETE.
# Each wrapper condition has an "immediate outside" case: the other two conditions
# hold and only that one is missing.
#
# CHAIN: none — local temporary git repos only; no host, no network, no broadcast.
#
# Usage:
#   bash tests/check-duplicate-functions/test-check-duplicate-functions.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G2="${REPO_ROOT}/scripts/check-duplicate-functions.sh"
GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; WORK=""; }
trap cleanup EXIT

OUT=""
ERR=""
RC=0

# mkrepo: a new repository in $WORK/r with an allowlist that holds only a comment.
mkrepo() {
	cleanup
	WORK="$(mktemp -d -t g2-test.XXXXXX)" || exit 1
	mkdir -p "$WORK/r"
	cd "$WORK/r" || exit 1
	git init -q . >/dev/null 2>&1
	mkdir -p scripts/lib bin
	printf '# allowlist for the test repository\n' > scripts/duplicate-functions.allow
}
put() { mkdir -p "$(dirname "$1")"; printf '%b' "$2" > "$1"; } # put <path> <content with \n \t escapes>
allow() { local r; for r in "$@"; do printf '%b\n' "$r" >> scripts/duplicate-functions.allow; done; }
commit() { git add -- scripts bin >/dev/null 2>&1; git "${GITQ[@]}" commit -q --allow-empty -m change >/dev/null 2>&1; }

run_g2() { OUT="$(cd "$WORK/r" && bash "$G2" "$@" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"; }

has_line() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
last_line() { printf '%s\n' "$OUT" | tail -n 1; }

expect_ok() { # name [expected last line]
	if [ "$RC" -ne 0 ]; then bad "$1 (rc=$RC want=0 out=$(printf '%s' "$OUT" | tail -n 2 | tr '\n' '|'))"; return; fi
	if [ -n "${2:-}" ] && [ "$(last_line)" != "$2" ]; then bad "$1 (last line: $(last_line))"; return; fi
	ok "$1"
}
expect_fail() { # name expected-violation-line expected-FAIL-line  (rc 1; both lines present as whole lines)
	if [ "$RC" -ne 1 ]; then bad "$1 (rc=$RC want=1 out=$(printf '%s' "$OUT" | tail -n 3 | tr '\n' '|'))"; return; fi
	if ! has_line "$2"; then bad "$1 (missing line: $2)"; return; fi
	if ! has_line "$3"; then bad "$1 (missing line: $3)"; return; fi
	if printf '%s\n' "$OUT" | grep -q '^OK'; then bad "$1 (printed OK)"; return; fi
	ok "$1"
}
expect_refused() { # name : rc 2, no OK on stdout, one message line on stderr
	if [ "$RC" -ne 2 ]; then bad "$1 (rc=$RC want=2 out=$(printf '%s' "$OUT" | tail -n 2 | tr '\n' '|'))"; return; fi
	if printf '%s\n' "$OUT" | grep -q '^OK'; then bad "$1 (printed OK)"; return; fi
	case "$ERR" in "check-duplicate-functions: "*) ok "$1" ;; *) bad "$1 (stderr: $ERR)" ;; esac
}

if [ ! -f "$G2" ]; then
	echo "FATAL: gate not found at $G2" >&2
	# Red phase of TDD: the cases below fail because the script is missing.
fi

HDR='#!/usr/bin/env bash\n'
LIB_FETCH='_fy_fetch_retry_fetch() {\n\tcurl -s "$@"\n}\n'
LIB_OTHER='_fy_other_x() {\n\t:\n}\n'
GOODSRC='. "$ROOT/scripts/lib/fetch-retry.sh"\n'
GOODFN='fetch() { _fy_fetch_retry_fetch "$@"; }\n'

# wrapper_repo: two library files, and scripts/a.sh holding a wrapper `fetch` that meets all three conditions.
wrapper_repo() {
	mkrepo
	put scripts/lib/fetch-retry.sh "${HDR}${LIB_FETCH}"
	put scripts/lib/other.sh "${HDR}${LIB_OTHER}"
	put scripts/a.sh "${HDR}${GOODSRC}${GOODFN}"
}
# variant <name> <copy|wrapper> <content of scripts/b.sh>: b.sh also defines `fetch`; a.sh's one is a good wrapper.
variant() {
	wrapper_repo
	put scripts/b.sh "${HDR}$3"
	commit
	run_g2
	if [ "$2" = copy ]; then
		expect_fail "$1" "COPY fetch scripts/b.sh" "FAIL 1"
	else
		expect_ok "$1" "OK 1 names 0 rows"
	fi
}

# ---- arguments ----------------------------------------------------------------------------
mkrepo; commit
run_g2
expect_ok "args_none: runs, rc 0, nothing duplicated" "OK 0 names 0 rows"
run_g2 --help
expect_refused "args_one: any argument is refused (rc 2)"
run_g2 a b
expect_refused "args_two: two arguments are refused (rc 2)"

# ---- repository ---------------------------------------------------------------------------
mkrepo; commit
mkdir -p "$WORK/nr"
OUT="$(cd "$WORK/nr" && GIT_CEILING_DIRECTORIES="$WORK" bash "$G2" 2>"$WORK/err")"; RC=$?; ERR="$(cat "$WORK/err")"
expect_refused "repo_missing: not a git repository (rc 2)"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
commit
printf 'garbage' > .git/index
run_g2
expect_refused "git_fails: a broken index makes git ls-files fail (rc 2)"

# ---- allowlist: missing or unexpected ---------------------------------------------------
mkrepo; commit
rm -f scripts/duplicate-functions.allow
run_g2
expect_refused "allow_absent: no allowlist file (rc 2)"

mkrepo; commit
rm -f scripts/duplicate-functions.allow
ln -s /dev/null scripts/duplicate-functions.allow
run_g2
expect_refused "allow_not_regular: the allowlist is a symlink to /dev/null, not a regular file (rc 2)"

mkrepo; commit
chmod 000 scripts/duplicate-functions.allow
run_g2
expect_refused "allow_unreadable: allowlist not readable (rc 2)"

bad_row_case() { # name row
	mkrepo
	put scripts/a.sh "${HDR}foo() { :; }\n"
	put scripts/b.sh "${HDR}foo() { :; }\n"
	allow "foo\tscripts/a.sh\treason a" "foo\tscripts/b.sh\treason b" "$2"
	commit
	run_g2
	expect_refused "$1"
}
bad_row_case "allow_two_fields: a row with 2 fields (rc 2)" "foo\tscripts/c.sh"
bad_row_case "allow_four_fields: a row with 4 fields (rc 2)" "foo\tscripts/c.sh\treason\textra"
bad_row_case "allow_empty_reason: empty reason (rc 2)" "foo\tscripts/c.sh\t"
bad_row_case "allow_blank_reason: reason of spaces only (rc 2)" "foo\tscripts/c.sh\t   "
bad_row_case "allow_empty_name: empty name (rc 2)" "\tscripts/c.sh\treason"
bad_row_case "allow_empty_file: empty file (rc 2)" "foo\t\treason"
bad_row_case "allow_name_space: name with a space (rc 2)" "fo o\tscripts/c.sh\treason"
bad_row_case "allow_name_digit_first: name starting with a digit (rc 2)" "1foo\tscripts/c.sh\treason"
bad_row_case "allow_file_outside: file outside scripts/ and bin/ (rc 2)" "foo\tdocs/c.sh\treason"
bad_row_case "allow_file_tests_dir: file under tests/ (rc 2)" "foo\ttests/c.sh\treason"
bad_row_case "allow_file_scripts_no_slash: scripts without a slash (rc 2)" "foo\tscriptsx/c.sh\treason"
bad_row_case "allow_file_bin_no_slash: bin without a slash (rc 2)" "foo\tbinx/c.sh\treason"
bad_row_case "allow_duplicate_row: the same (name, file) twice (rc 2)" "foo\tscripts/a.sh\tagain"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
allow "" "   " "# a comment" "   # an indented comment" "foo\tscripts/a.sh\treason a" "" "foo\tscripts/b.sh\treason b"
commit
run_g2
expect_ok "allow_comments_blank: comment and blank lines are ignored (rc 0)" "OK 1 names 2 rows"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
printf 'foo\tscripts/a.sh\treason a\nfoo\tscripts/b.sh\treason b' > scripts/duplicate-functions.allow
commit
run_g2
expect_ok "allow_no_final_newline: the last row is read without a newline" "OK 1 names 2 rows"

# ---- scanned files ----------------------------------------------------------------------
mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
allow "foo\tscripts/a.sh\tr" "foo\tscripts/b.sh\tr"
commit
chmod 000 scripts/b.sh
run_g2
expect_refused "scan_unreadable: a tracked script that cannot be read (rc 2)"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
allow "foo\tscripts/a.sh\tr" "foo\tscripts/b.sh\tr"
commit
rm -f scripts/b.sh
run_g2
expect_refused "scan_deleted: a tracked script missing from the work tree (rc 2)"

mkrepo
put bin/tool "#!/usr/bin/env bash\nfoo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
chmod 000 bin/tool
run_g2
expect_refused "scan_bin_unreadable: a tracked bin/ file that cannot be read (rc 2)"

# ---- allowlist rows and the copies ------------------------------------------------------
mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
allow "foo\tscripts/a.sh\treason a" "foo\tscripts/b.sh\treason b"
commit
run_g2
expect_ok "two_copies_rows: two copies, both with rows (rc 0)" "OK 1 names 2 rows"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_fail "copy_no_row_a: two copies, no rows (COPY for a)" "COPY foo scripts/a.sh" "FAIL 2"
expect_fail "copy_no_row_b: two copies, no rows (COPY for b)" "COPY foo scripts/b.sh" "FAIL 2"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
allow "foo\tscripts/a.sh\treason a"
commit
run_g2
expect_fail "copy_one_row: a row for a only; b is COPY, a is not" "COPY foo scripts/b.sh" "FAIL 1"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\nbar() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
allow "bar\tscripts/a.sh\tother name" "foo\tscripts/a.sh\treason a"
commit
run_g2
expect_fail "copy_row_other_name: a row for the same file but another name does not excuse b" "COPY foo scripts/b.sh" "FAIL 2"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
put scripts/c.sh "${HDR}:\n"
allow "foo\tscripts/a.sh\treason a" "foo\tscripts/c.sh\twrong file"
commit
run_g2
expect_fail "copy_row_other_file: a row for the same name but another file does not excuse b" "COPY foo scripts/b.sh" "FAIL 2"
expect_fail "copy_row_other_file_obsolete: and that row is OBSOLETE" "OBSOLETE foo scripts/c.sh" "FAIL 2"

# ---- OBSOLETE ---------------------------------------------------------------------------
mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
put scripts/c.sh "${HDR}:\n"
allow "foo\tscripts/a.sh\treason a" "foo\tscripts/b.sh\treason b" "foo\tscripts/c.sh\tc has no foo"
commit
run_g2
expect_fail "obsolete_no_definition: the file has no such definition" "OBSOLETE foo scripts/c.sh" "FAIL 1"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
allow "foo\tscripts/a.sh\treason a" "foo\tscripts/b.sh\treason b" "foo\tscripts/gone.sh\tno such file"
commit
run_g2
expect_fail "obsolete_no_file: the file does not exist" "OBSOLETE foo scripts/gone.sh" "FAIL 1"

mkrepo
put scripts/a.sh "${HDR}foo() { :; }\n"
put scripts/b.sh "${HDR}bar() { :; }\n"
allow "foo\tscripts/a.sh\treason a"
commit
run_g2
expect_fail "obsolete_one_file: the name is now in one file only" "OBSOLETE foo scripts/a.sh" "FAIL 1"

mkrepo
put scripts/lib/fetch-retry.sh "${HDR}${LIB_FETCH}"
put scripts/a.sh "${HDR}${GOODSRC}${GOODFN}"
put scripts/b.sh "${HDR}fetch() { :; }\n"
allow "fetch\tscripts/a.sh\ta is a wrapper" "fetch\tscripts/b.sh\tb is a copy"
commit
run_g2
expect_fail "obsolete_wrapper: the definition there is a wrapper" "OBSOLETE fetch scripts/a.sh" "FAIL 1"

mkrepo
put scripts/a.sh "${HDR}# foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
allow "foo\tscripts/b.sh\tonly a comment elsewhere"
commit
run_g2
expect_fail "comment_not_definition: a commented-out definition is not a definition" "OBSOLETE foo scripts/b.sh" "FAIL 1"

# ---- definition forms ---------------------------------------------------------------------
mkrepo
put scripts/a.sh "${HDR}function foo {\n\t:\n}\nfunction baz() {\n\t:\n}\n\tqux ()\t{ :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\nbaz() { :; }\nqux() { :; }\n"
commit
run_g2
expect_fail "forms_function_brace: function NAME { is a definition" "COPY foo scripts/a.sh" "FAIL 6"
expect_fail "forms_function_parens: function NAME() { is a definition" "COPY baz scripts/a.sh" "FAIL 6"
expect_fail "forms_indented_space: indented NAME () is a definition" "COPY qux scripts/a.sh" "FAIL 6"

mkrepo
put scripts/a.sh "${HDR}cat <<'EOF'\nfoo() { :; }\nEOF\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_fail "heredoc_counts: a definition inside heredoc text counts for its file" "COPY foo scripts/a.sh" "FAIL 2"

mkrepo
put scripts/a.sh "${HDR}echo foo() { :; }\nx=\$(foo)\nfoo=1\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_ok "not_definitions: echo foo(), \$(foo) and foo=1 are not definitions" "OK 0 names 0 rows"

# ---- bin/ files and other files -----------------------------------------------------------
mkrepo
put bin/tool "#!/usr/bin/env bash\nfoo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_fail "bin_env_bash: a bin/ file with an env bash shebang is scanned" "COPY foo bin/tool" "FAIL 2"

mkrepo
put bin/tool "#!/bin/sh\nfoo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_fail "bin_sh: a bin/ file with a /bin/sh shebang is scanned" "COPY foo bin/tool" "FAIL 2"

mkrepo
put bin/tool "#!/bin/bash -eu\nfoo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_fail "bin_bash_args: /bin/bash with an argument is scanned" "COPY foo bin/tool" "FAIL 2"

mkrepo
put bin/tool "#!/usr/bin/env python3\nfoo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_ok "bin_python: a bin/ file with a python shebang is not scanned" "OK 0 names 0 rows"

mkrepo
put bin/tool "#!/bin/bashx\nfoo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_ok "bin_bashx: a shebang that only starts like /bin/bash is not scanned" "OK 0 names 0 rows"

mkrepo
put bin/tool "foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_ok "bin_no_shebang: a bin/ file without a shebang is not scanned" "OK 0 names 0 rows"

mkrepo
put scripts/x.py "foo() { :; }\n"
put scripts/b.sh "${HDR}foo() { :; }\n"
commit
run_g2
expect_ok "scripts_not_sh: a scripts/ file that is not *.sh is not scanned" "OK 0 names 0 rows"

# ---- wrapper: all three conditions hold ---------------------------------------------------
wrapper_repo
put scripts/b.sh "${HDR}${GOODSRC}${GOODFN}"
commit
run_g2
expect_ok "wrapper_ok: all three conditions (one-line form), no row needed" "OK 1 names 0 rows"

variant "wrapper_multiline_ok: multi-line form with a comment and a blank line in the body" wrapper \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() {\n\t# call the library\n\n\t_fy_fetch_retry_fetch "$@"\n}\n'
variant "wrapper_indented_ok: indented definition closed by an equally indented brace" wrapper \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nif true; then\n\tfetch() {\n\t\t_fy_fetch_retry_fetch "$@"\n\t}\nfi\n'
variant "wrapper_literal_line_start: the literal at the start and the end of a line" wrapper \
	'scripts/lib/fetch-retry.sh\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_literal_quoted: the literal between quotes" wrapper \
	'. "scripts/lib/fetch-retry.sh";\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'

# condition 1: the body is exactly one line
variant "wrapper_c1_two_lines: body of 2 lines (conditions 2 and 3 hold)" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() {\n\t_fy_fetch_retry_fetch "$@"\n\t_fy_fetch_retry_fetch "$@"\n}\n'
variant "wrapper_c1_no_closing: no closing brace at the definition indentation" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() {\n\t_fy_fetch_retry_fetch "$@"\n  }\n'
variant "wrapper_c1_subshell: a subshell body" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() ( _fy_fetch_retry_fetch "$@" )\n'
variant "wrapper_c1_comment_brace_body: a comment after the definition, then a 2-line body (valid bash)" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() # _fy_fetch_retry_fetch }\n{\n\t_fy_fetch_retry_fetch "$@"\n\t_fy_fetch_retry_fetch "$@"\n}\n'
variant "wrapper_c1_brace_next_line: the opening brace on the next line" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch()\n{\n\t_fy_fetch_retry_fetch "$@"\n}\n'
variant "wrapper_c1_empty_body: an empty body" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() { }\n'
variant "wrapper_c1_unclosed_one_line: a one-line form that does not close" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() { _fy_fetch_retry_fetch "$@";\n}\n'

# condition 2: the first word names a function defined in a library file
variant "wrapper_c2_command: the first word is a command (curl)" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() { curl -s "$@"; }\n'
mkrepo
put scripts/lib/fetch-retry.sh "${HDR}${LIB_FETCH}"
put scripts/a.sh "${HDR}${GOODSRC}${GOODFN}"
put scripts/c.sh "${HDR}helper() { :; }\n"
put scripts/b.sh "${HDR}${GOODSRC}fetch() { helper \"\$@\"; }\n"
commit
run_g2
expect_fail "wrapper_c2_local_function: the first word is a function defined outside any library" "COPY fetch scripts/b.sh" "FAIL 1"
variant "wrapper_c2_unknown: the first word is a name defined nowhere" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() { nothing_here "$@"; }\n'

# condition 3: the same file names the library file's path
variant "wrapper_c3_missing: no literal at all" copy \
	'fetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_c3_comment_only: the literal only on a comment line" copy \
	'# . scripts/lib/fetch-retry.sh\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_c3_indented_comment: the literal only on an indented comment line" copy \
	'\t# . scripts/lib/fetch-retry.sh\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_c3_other_library: the literal of a different library file" copy \
	'. "$ROOT/scripts/lib/other.sh"\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_c3_suffix: the literal followed by .bak" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh.bak"\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_c3_suffix_dash: the literal followed by a dash" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh-old"\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_c3_prefix: the literal preceded by a name character" copy \
	'. "$ROOT/my-scripts/lib/fetch-retry.sh"\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_c3_prefix_letter: the literal preceded by a letter" copy \
	'. "$ROOT/xscripts/lib/fetch-retry.sh"\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_c3_second_occurrence: a bad first occurrence and a good second one on one line" wrapper \
	'. x-scripts/lib/fetch-retry.sh.bak "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() { _fy_fetch_retry_fetch "$@"; }\n'
variant "wrapper_c3_other_library_wrong_callee: a function of other.sh with fetch-retry.sh's literal" copy \
	'. "$ROOT/scripts/lib/fetch-retry.sh"\nfetch() { _fy_other_x "$@"; }\n'

# ---- LIBDUP -------------------------------------------------------------------------------
wrapper_repo
put scripts/a.sh "${HDR}${GOODSRC}_fy_fetch_retry_fetch() { :; }\n"
allow "_fy_fetch_retry_fetch\tscripts/a.sh\ta row does not excuse this"
commit
run_g2
expect_fail "libdup_copy_with_row: a library name redefined outside lib, even with a row" "LIBDUP _fy_fetch_retry_fetch scripts/a.sh" "FAIL 1"

wrapper_repo
put scripts/a.sh "${HDR}. \"\$ROOT/scripts/lib/other.sh\"\n_fy_fetch_retry_fetch() { _fy_other_x \"\$@\"; }\n"
commit
run_g2
expect_fail "libdup_wrapper_form: a library name redefined as a wrapper is still LIBDUP" "LIBDUP _fy_fetch_retry_fetch scripts/a.sh" "FAIL 1"

wrapper_repo
put scripts/lib/second.sh "${HDR}${LIB_FETCH}"
commit
run_g2
expect_fail "libdup_two_lib_files_first: the same name in two library files (first)" "LIBDUP _fy_fetch_retry_fetch scripts/lib/fetch-retry.sh" "FAIL 2"
expect_fail "libdup_two_lib_files_second: the same name in two library files (second)" "LIBDUP _fy_fetch_retry_fetch scripts/lib/second.sh" "FAIL 2"

# ---- the real tree and the no-AI property -------------------------------------------------
OUT="$(cd "$REPO_ROOT" && bash "$G2" 2>/dev/null)"; RC=$?; ERR=""
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | tail -n 1 | grep -Eq '^OK [0-9]+ names [0-9]+ rows$'; then
	ok "real-tree: G2 on this repository exits 0 with an OK line"
else
	bad "real-tree: G2 on this repository (rc=$RC out=$(printf '%s' "$OUT" | tail -n 3 | tr '\n' '|'))"
fi

NOAI_BAD=""
for g in scripts/check-doc-moves.sh scripts/check-duplicate-functions.sh scripts/check-refactor-equivalence.sh; do
	if [ ! -f "$REPO_ROOT/$g" ]; then NOAI_BAD="${NOAI_BAD} ${g}(missing)"; continue; fi
	grep -niE 'anthropic|openai|claude|api_key' "$REPO_ROOT/$g" >/dev/null 2>&1
	case $? in 1) ;; *) NOAI_BAD="${NOAI_BAD} ${g}" ;; esac
done
if [ -z "$NOAI_BAD" ]; then ok "no-ai: none of the three gate scripts names an AI service or key"; else bad "no-ai:${NOAI_BAD}"; fi

cd "$REPO_ROOT" || exit 1
echo ""
echo "test-check-duplicate-functions.sh summary: PASS=${PASS}  FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
