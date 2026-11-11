#!/usr/bin/env bash
# test-check-refactor-equivalence.sh — suite for scripts/check-refactor-equivalence.sh
# (gate G3 of the 2026-11-10 simplify refactor): the same script, or the same test
# suite, run at a base commit and at HEAD must give the same result.
#
# Every case builds a throwaway git repo (mktemp -d, removed by trap) with a toy
# script at two commits and runs G3 there with TMPDIR pointing at an empty directory.
# After EVERY run (exit 0, 1 or 2) the toy repo's `git worktree list` must be back to
# one entry and that TMPDIR must be empty. G3 must fail closed: a missing input, a
# stub that does not shadow proton/ssh, or a suite without case lines is exit 2.
#
# CHAIN: none — local temporary git repos and stub commands only; no host, no network,
# no broadcast. The stubs for curl/ssh/proton are the gate's own.
#
# Usage:
#   bash tests/check-refactor-equivalence/test-check-refactor-equivalence.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G3="${REPO_ROOT}/scripts/check-refactor-equivalence.sh"
AJV_FIXTURE="${REPO_ROOT}/tests/fixtures/ajv-stub/ajv"
GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)
TAB=$'\t'

PASS=0
FAIL=0
t_ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
t_bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

WORK=""
BGPID=""
t_cleanup() {
	[ -z "$BGPID" ] || kill -KILL "$BGPID" 2>/dev/null
	[ -z "$WORK" ] || rm -rf "$WORK"
	WORK=""
}
trap t_cleanup EXIT

if [ ! -f "$G3" ]; then
	echo "FATAL: gate not found at $G3" >&2
	# Red phase of TDD: the cases below fail because the script is missing.
fi

OUT=""
ERRTXT=""
RC=0
BASE=""
T_PRE=""     # shell text evaluated inside the G3 run's subshell (exports for the run)
R=""         # the toy repo
CASES=""

# t_init: new toy repo $WORK/r (no commit yet), empty $WORK/tmp
t_init() {
	t_cleanup
	WORK="$(mktemp -d -t g3-suite.XXXXXX)" || exit 1
	R="$WORK/r"
	CASES="$WORK/cases.tsv"
	mkdir -p "$R" "$WORK/tmp"
	git -C "$R" init -q . >/dev/null 2>&1
	T_PRE=""
}

# t_put <relpath> [mode]: file content from stdin
t_put() {
	mkdir -p "$(dirname "$R/$1")"
	cat > "$R/$1"
	chmod "${2:-644}" "$R/$1"
}
# t_script <relpath> <body>: an executable bash script
t_script() { printf '#!/usr/bin/env bash\n%s\n' "$2" | t_put "$1" 755; }
t_commit() { git -C "$R" add -A >/dev/null 2>&1; git -C "$R" "${GITQ[@]}" commit -q -m "${1:-c}" --allow-empty; }
t_mark_base() { BASE="$(git -C "$R" rev-parse HEAD)"; }
# t_pair <base body> <head body>: scripts/toy.sh at two commits (BASE = the first)
t_pair() {
	t_init
	t_script scripts/toy.sh "$1"; t_commit base; t_mark_base
	t_script scripts/toy.sh "$2"; t_commit head
}
# t_row script args env fix out val [norm]
t_row() {
	if [ "$#" -ge 7 ]; then printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$@"; else printf '%s\t%s\t%s\t%s\t%s\t%s' "$@"; fi
}
t_cases() { : > "$CASES"; local r; for r in "$@"; do printf '%s\n' "$r" >> "$CASES"; done; }
t_cases_one() { t_cases "$(t_row scripts/toy.sh "$@")"; } # args env fix out val [norm]

# t_run <g3 args...>: runs G3 inside the toy repo; sets OUT, ERRTXT, RC
t_run() {
	OUT="$(cd "${T_RUNDIR:-$R}" && eval "$T_PRE" && TMPDIR="$WORK/tmp" bash "$G3" "$@" 2>"$WORK/stderr" </dev/null)"
	RC=$?
	ERRTXT="$(cat "$WORK/stderr")"
}
t_run_cases() { t_run --base="$BASE" --cases="$CASES"; }

# t_expect <name> <want rc> [fixed string that must be a stdout line] ...
# Always also checks: (rc 2) stderr starts with the tool's name and stdout has no OK/FAIL;
# (every rc) the toy repo's worktree list has one entry and TMPDIR is empty.
t_expect() {
	local name="$1" want="$2" pat why="" n
	shift 2
	[ "$RC" -eq "$want" ] || why="rc=$RC want=$want out=$(printf '%s' "$OUT" | tail -n 2 | tr '\n' '|') err=$(printf '%s' "$ERRTXT" | head -n 1)"
	if [ -z "$why" ]; then
		for pat in "$@"; do
			printf '%s\n' "$OUT" | grep -qxF -- "$pat" || { why="missing stdout line: $pat (got: $(printf '%s' "$OUT" | tr '\n' '|'))"; break; }
		done
	fi
	if [ -z "$why" ] && [ "$want" -eq 2 ]; then
		printf '%s\n' "$ERRTXT" | head -n 1 | grep -q '^check-refactor-equivalence: ' || why="rc 2 without the reason line on stderr: $(printf '%s' "$ERRTXT" | head -n 1)"
		if [ -z "$why" ] && printf '%s\n' "$OUT" | grep -Eq '^(OK|FAIL) '; then why="rc 2 but stdout has OK/FAIL"; fi
	fi
	if [ -z "$why" ] && [ -d "$R/.git" ]; then
		n="$(git -C "$R" worktree list | wc -l | tr -d ' ')"
		[ "$n" = "1" ] || why="leftover worktree: git worktree list has $n entries"
	fi
	if [ -z "$why" ] && [ -n "$(ls -A "$WORK/tmp" 2>/dev/null)" ]; then why="TMPDIR not empty after the run: $(ls -A "$WORK/tmp" | head -n 3 | tr '\n' ' ')"; fi
	if [ -n "$why" ]; then t_bad "$name ($why)"; else t_ok "$name"; fi
}
# t_expect_diffs <name> <want diff lines...>: rc 1, exactly these DIFF lines, FAIL <count>
t_expect_diffs() {
	local name="$1" got want n why=""
	shift
	got="$(printf '%s\n' "$OUT" | grep '^DIFF ' | LC_ALL=C sort)"
	want="$(printf '%s\n' "$@" | LC_ALL=C sort)"
	n="$#"
	if [ "$got" != "$want" ]; then
		t_run_note="$name"
		RC=99
		OUT="$(printf 'DIFF set differs; want: %s | got: %s' "$(printf '%s' "$want" | tr '\n' '|')" "$(printf '%s' "$got" | tr '\n' '|')")"
		why="$OUT"
		t_bad "$name ($why)"
		return
	fi
	t_expect "$name" 1 "FAIL $n"
}

# ======================================================================================
# CASES MODE
# ======================================================================================

# ---- equal -----------------------------------------------------------------------------
t_pair 'echo "out:$1"; echo err >&2' 'echo "out:$1"; echo err >&2 # comment only'
t_cases_one x - - - -
t_run_cases
t_expect "equal: rc 0, OK 1 equal" 0 "OK 1 equal"
if printf '%s\n' "$OUT" | grep -q '^DIFF '; then t_bad "equal: no DIFF line"; else t_ok "equal: no DIFF line"; fi

# ---- one difference at a time ----------------------------------------------------------
t_pair 'echo a; exit 0' 'echo a; exit 3'
t_cases_one x - - - -; t_run_cases
t_expect_diffs "rc differs: DIFF L1 rc only" "DIFF L1 rc"

t_pair 'echo a' 'echo b'
t_cases_one x - - - -; t_run_cases
t_expect_diffs "stdout differs: DIFF L1 stdout only" "DIFF L1 stdout"

t_pair 'echo a >&2' 'echo b >&2'
t_cases_one x - - - -; t_run_cases
t_expect_diffs "stderr differs: DIFF L1 stderr only" "DIFF L1 stderr"

t_pair 'echo one > out.txt' 'echo two > out.txt'
t_cases_one x - - out.txt -; t_run_cases
t_expect_diffs "output file differs: DIFF L1 file:out.txt only" "DIFF L1 file:out.txt"

t_pair 'echo hi' 'echo hi; echo new > out.txt'
t_cases_one x - - out.txt -; t_run_cases
t_expect_diffs "output file at head only: file-presence" "DIFF L1 file-presence:out.txt"

t_pair 'echo hi; echo old > out.txt' 'echo hi'
t_cases_one x - - out.txt -; t_run_cases
t_expect_diffs "output file at base only: file-presence" "DIFF L1 file-presence:out.txt"

t_pair 'echo hi' 'echo hi'
t_cases_one x - - out.txt -; t_run_cases
t_expect "output file absent on both sides: exit 2" 2

t_pair 'echo hi; echo same > sub.txt' 'echo hi; echo same > sub.txt'
t_cases_one x - - sub.txt,missing.txt -; t_run_cases
t_expect "second listed output file absent on both sides: exit 2" 2

# ---- several rows: every row is judged, line numbers are file line numbers --------------
t_pair 'echo "$1"' 'if [ "$1" = bad ]; then echo changed; else echo "$1"; fi'
t_cases '# comment' "$(t_row scripts/toy.sh good - - - -)" '' "$(t_row scripts/toy.sh bad - - - -)" "$(t_row scripts/toy.sh good2 - - - -)"
t_run_cases
t_expect_diffs "rows: only the differing row (file line 4) is reported" "DIFF L4 stdout"
if printf '%s\n' "$OUT" | grep -qx 'FAIL 1'; then t_ok "rows: FAIL counts DIFF lines"; else t_bad "rows: FAIL counts DIFF lines ($OUT)"; fi

t_pair 'echo "$1"' 'echo "$1"'
t_cases "$(t_row scripts/toy.sh a - - - -)" "$(t_row scripts/toy.sh b - - - -)"
t_run_cases
t_expect "rows: two equal rows give OK 2 equal" 0 "OK 2 equal"

# ---- normalize: only the named key, only its string value ------------------------------
t_pair 'echo "{\"ts\":\"A\",\"n\":1}"; echo "{\"ts\":\"A\"}" >&2; echo "{\"ts\" :  \"A\"}" > out.txt' \
       'echo "{\"ts\":\"B\",\"n\":1}"; echo "{\"ts\":\"B\"}" >&2; echo "{\"ts\" :  \"B\"}" > out.txt'
t_cases_one x - - out.txt - ts; t_run_cases
t_expect "normalize: named key differing only in its value is equal (stdout, stderr, file)" 0 "OK 1 equal"

t_cases_one x - - out.txt - id; t_run_cases
t_expect_diffs "normalize: a key that is not named still differs everywhere" "DIFF L1 stdout" "DIFF L1 stderr" "DIFF L1 file:out.txt"

t_pair 'echo "{\"ts\":\"A\",\"id\":\"x1\"}"' 'echo "{\"ts\":\"B\",\"id\":\"x2\"}"'
t_cases_one x - - - - ts; t_run_cases
t_expect_diffs "normalize: ts named, id differs too -> stdout differs" "DIFF L1 stdout"

t_pair 'echo "{\"ts\":\"A\",\"n\":1}"' 'echo "{\"ts\":\"B\",\"n\":2}"'
t_cases_one x - - - - ts; t_run_cases
t_expect_diffs "normalize: named key masked but another byte differs -> stdout differs" "DIFF L1 stdout"

t_pair 'echo "{\"ts\":5}"' 'echo "{\"ts\":6}"'
t_cases_one x - - - - ts; t_run_cases
t_expect_diffs "normalize: a non-string value of the named key is not masked" "DIFF L1 stdout"

t_pair 'echo "{\"xts\":\"A\"}"' 'echo "{\"xts\":\"B\"}"'
t_cases_one x - - - - ts; t_run_cases
t_expect_diffs "normalize: a key that only ends with the named key is not masked" "DIFF L1 stdout"

t_pair 'echo "{\"ts\":\"A\",\"id\":\"x1\"}"' 'echo "{\"ts\":\"B\",\"id\":\"x2\"}"'
t_cases_one x - - - - ts,id; t_run_cases
t_expect "normalize: two named keys" 0 "OK 1 equal"

t_pair 'echo hi' 'echo hi'
t_cases_one x - - - - 'ts,'; t_run_cases
t_expect "normalize: trailing comma in the list: exit 2" 2
t_cases_one x - - - - 'ts-x'; t_run_cases
t_expect "normalize: key with a dash: exit 2" 2

# ---- env column ------------------------------------------------------------------------
t_pair 'echo hi' 'echo hi'
for k in PATH HOME TMPDIR FY_LIVE; do
	t_cases_one x "${k}=1" - - -; t_run_cases
	t_expect "env: reserved key $k: exit 2" 2
	if [ "$RC" -eq 2 ] && ! printf '%s' "$ERRTXT" | grep -q 'reserved'; then t_bad "env: reserved key $k: reason must say reserved ($ERRTXT)"; fi
done
# the neighbours of the reserved keys are ordinary keys
t_pair 'echo "${PATHX-n}${MYPATH-n}${HOMEX-n}${TMPDIR_X-n}${FY_LIVE2-n}"' 'echo "11111"'
t_cases_one x 'PATHX=1 MYPATH=1 HOMEX=1 TMPDIR_X=1 FY_LIVE2=1' - - -; t_run_cases
t_expect "env: PATHX MYPATH HOMEX TMPDIR_X FY_LIVE2 are not reserved" 0 "OK 1 equal"
t_pair 'echo hi' 'echo hi'
t_cases_one x 'lower=1' - - -; t_run_cases
t_expect "env: lowercase key: exit 2" 2
t_cases_one x 'NOEQUALS' - - -; t_run_cases
t_expect "env: word without =: exit 2" 2
t_cases_one x 'A=1 B=has"quote' - - -; t_run_cases
t_expect "env: forbidden character in a value: exit 2" 2
t_pair 'echo "${EMPTYV-unset}|${WITHEQ-unset}"' 'echo "|a=b"'
t_cases_one x 'EMPTYV= WITHEQ=a=b' - - -; t_run_cases
t_expect "env: empty value and a value containing =" 0 "OK 1 equal"

# ---- args column -----------------------------------------------------------------------
t_pair 'echo hi' 'echo hi'
for ch in "'" '"' '\' '$' '`' ';' '|' '&' '<' '>' '(' ')'; do
	t_cases_one "a${ch}b" - - - -; t_run_cases
	t_expect "args: forbidden character $ch: exit 2" 2
done
t_init
t_script scripts/toy.sh 'echo "$#:$1:${2##*/}:$3"'; t_commit base; t_mark_base
printf 'x\n' | t_put 'fxd/a=b,c:d%e1f'
printf 'x\n' | t_put 'fxd/a=b,c:d%e2f'
t_script scripts/toy.sh 'echo "3:a=b,c:d%e*f:fx:scripts/toy.s*"'
t_commit head
t_cases_one 'a=b,c:d%e*f {FIXTURE} scripts/toy.s*' - fxd - -; t_run_cases
t_expect "args: = , : % * { } are allowed, * is not expanded (fixture and repo root hold matching files), {FIXTURE} -> fx" 0 "OK 1 equal"

# ---- column count and shape ------------------------------------------------------------
t_pair 'echo hi' 'echo hi'
t_cases "scripts/toy.sh${TAB}x${TAB}-${TAB}-${TAB}-"; t_run_cases
t_expect "columns: 5 columns: exit 2" 2
t_cases "scripts/toy.sh${TAB}x${TAB}-${TAB}-${TAB}-${TAB}-${TAB}-${TAB}-"; t_run_cases
t_expect "columns: 8 columns: exit 2" 2
t_cases "scripts/toy.sh${TAB}x${TAB}-${TAB}-${TAB}-${TAB}-"; t_run_cases
t_expect "columns: 6 columns: ok" 0 "OK 1 equal"
t_cases "scripts/toy.sh${TAB}x${TAB}-${TAB}-${TAB}-${TAB}-${TAB}-"; t_run_cases
t_expect "columns: 7 columns with - : ok" 0 "OK 1 equal"
t_cases "scripts/toy.sh${TAB}${TAB}-${TAB}-${TAB}-${TAB}-"; t_run_cases
t_expect "columns: an empty column: exit 2" 2
t_cases "scripts/toy.sh${TAB}x"$'\r'"${TAB}-${TAB}-${TAB}-${TAB}-"; t_run_cases
t_expect "columns: carriage return inside a row: exit 2" 2
t_cases "scripts/toy.sh${TAB}x${TAB}-${TAB}-${TAB}-${TAB}-${TAB}"; t_run_cases
t_expect "columns: 7th column present but empty: exit 2" 2
t_cases_one x - - - ajv; t_run_cases
t_expect "validator: unknown value ajv: exit 2" 2
if [ "$RC" -eq 2 ] && ! printf '%s' "$ERRTXT" | grep -q 'unknown validator'; then t_bad "validator: reason must say unknown validator ($ERRTXT)"; fi
t_cases_one x - - - AJV-STUB; t_run_cases
t_expect "validator: unknown value AJV-STUB: exit 2" 2
t_cases "# only a comment" ""; t_run_cases
t_expect "rows: only comments and blank lines: exit 2" 2
: > "$CASES"; t_run_cases
t_expect "rows: empty file: exit 2" 2

# ---- paths -----------------------------------------------------------------------------
t_pair 'echo hi' 'echo hi'
t_cases "$(t_row ../toy.sh x - - - -)"; t_run_cases
t_expect "paths: script with '..': exit 2" 2
t_cases "$(t_row /bin/echo x - - - -)"; t_run_cases
t_expect "paths: absolute script: exit 2" 2
t_cases_one x - - ../out.txt - ; t_run_cases
t_expect "paths: output file with '..': exit 2" 2
t_cases_one x - - /tmp/out.txt - ; t_run_cases
t_expect "paths: absolute output file: exit 2" 2
t_cases "$(t_row 'scripts/to y.sh' x - - - -)"; t_run_cases
t_expect "paths: script with a space: exit 2" 2

# ---- script tracking -------------------------------------------------------------------
t_init
t_script scripts/other.sh 'echo o'; t_commit base; t_mark_base
t_script scripts/toy.sh 'echo hi'; t_commit head
t_cases_one x - - - -; t_run_cases
t_expect "script missing at base: exit 2" 2

t_init
t_script scripts/toy.sh 'echo hi'; t_commit base; t_mark_base
git -C "$R" rm -q scripts/toy.sh; t_script scripts/other.sh 'echo o'; t_commit head
t_cases_one x - - - -; t_run_cases
t_expect "script missing at head: exit 2" 2

t_pair 'echo hi' 'echo hi'
t_script scripts/untracked.sh 'echo u'
t_cases "$(t_row scripts/untracked.sh x - - - -)"; t_run_cases
t_expect "script never committed: exit 2" 2

# ---- fixture, {FIXTURE}, environment of the run ----------------------------------------
t_init
t_script scripts/toy.sh 'r=ok
[ -f "$1/marker" ] || r=nomarker-arg
[ -f "$ENVV" ] || r=noenv
[ -f ./marker ] || r=nocwd
case "$HOME" in */g3-equiv.*/home) ;; *) r=badhome ;; esac
case "$TMPDIR" in */g3-equiv.*/tmp) ;; *) r=badtmp ;; esac
[ "${FY_LIVE-unset}" = unset ] || r=live
[ -z "${BASH_ENV-}" ] || r=bashenv
echo "$r"'
t_commit base; t_mark_base
printf 'm\n' | t_put fxd/marker
t_script scripts/toy.sh 'echo ok # head'
t_commit head
t_cases_one '{FIXTURE}' 'ENVV={FIXTURE}/marker' fxd - -
T_PRE='export FY_LIVE=1; printf "proton() { :; }\n" > "$WORK/benv"; export BASH_ENV="$WORK/benv"'
t_run_cases
t_expect "run env: {FIXTURE} in args and env, cwd = fixture, HOME/TMPDIR in the temp dir, FY_LIVE and BASH_ENV removed; fixture read from HEAD for both sides" 0 "OK 1 equal"
T_PRE=""

t_pair 'echo hi' 'echo hi'
t_cases_one x - nodir - -; t_run_cases
t_expect "fixture dir not in HEAD: exit 2" 2
mkdir -p "$R/untrackeddir"; echo x > "$R/untrackeddir/f"
t_cases_one x - untrackeddir - -; t_run_cases
t_expect "fixture dir only untracked in the working tree: exit 2 (HEAD is what counts)" 2

# ---- stubs -----------------------------------------------------------------------------
for c in curl ssh scp proton cleos; do
	t_pair 'out="$($1 a b 2>&1)"; rc=$?; echo "rc=$rc out=$out"' 'echo "rc=1 out=g3-stub: '"$c"' not provided by the case"'
	t_cases_one "$c" - - - -; t_run_cases
	t_expect "stub $c: without a fixture stub it fails with the g3-stub message" 0 "OK 1 equal"
done
for c in curl proton ssh; do
	t_init
	t_script scripts/toy.sh 'out="$($1 a b)"; echo "[$out]"; out="$($1 c)"; echo "[$out]"'; t_commit base; t_mark_base
	printf '#!/bin/sh\ncat "$(dirname "$0")/../../calls.log"\n' | t_put "fxd/stubs/$c" 755
	t_script scripts/toy.sh "echo \"[${c} a b]\"; echo \"[${c} a b\"; echo \"${c} c]\""
	t_commit head
	t_cases_one "$c" - fxd - -; t_run_cases
	t_expect "stub $c: every call is recorded (cmd + args, appended) and the fixture stub is used" 0 "OK 1 equal"
done
t_init
t_script scripts/toy.sh 'out="$(curl a b)"; echo "$?:$out"'; t_commit base; t_mark_base
printf '#!/bin/sh\necho "FIXTURE-CURL $*"\nexit 7\n' | t_put fxd/stubs/curl 755
t_script scripts/toy.sh 'echo "7:FIXTURE-CURL a b"'; t_commit head
t_cases_one x - fxd - -; t_run_cases
t_expect "stub: a fixture stub's rc and output pass through" 0 "OK 1 equal"
t_init
t_script scripts/toy.sh 'out="$(curl a b 2>&1)"; echo "$?:$out"'; t_commit base; t_mark_base
printf '#!/bin/sh\necho "FIXTURE-CURL $*"\nexit 7\n' | t_put fxd/stubs/curl 644
t_script scripts/toy.sh 'echo "1:g3-stub: curl not provided by the case"'; t_commit head
t_cases_one x - fxd - -; t_run_cases
t_expect "stub: a fixture stub that is not executable is treated as absent" 0 "OK 1 equal"

# ---- the stubs must shadow proton and ssh ----------------------------------------------
t_pair 'echo hi' 'echo hi'
t_cases_one x - - - -
T_PRE='proton() { echo REAL; }; export -f proton'
t_run_cases
t_expect "stub check: an exported function proton shadows the stub: exit 2" 2
if [ "$RC" -eq 2 ] && ! printf '%s' "$ERRTXT" | grep -q 'shadow'; then t_bad "stub check: reason must say shadow ($ERRTXT)"; fi
T_PRE='ssh() { echo REAL; }; export -f ssh'
t_run_cases
t_expect "stub check: an exported function ssh shadows the stub: exit 2" 2
T_PRE='curl() { echo REAL; }; export -f curl'
t_run_cases
t_expect "stub check: an exported function curl shadows the stub: exit 2" 2
T_PRE=""
t_run_cases
t_expect "stub check: the same case without the function is fine" 0 "OK 1 equal"

# ---- validators ------------------------------------------------------------------------
HAVE_JS=0
python3 -c 'import jsonschema' >/dev/null 2>&1 && HAVE_JS=1
VSH='case "$1" in
which) a="$(command -v ajv 2>/dev/null)"; case "$a" in */stubs/ajv) echo ajv=stub ;; "") echo ajv=none ;; *) echo ajv=real ;; esac ;;
py) if python3 -c "import jsonschema" 2>/dev/null; then echo py=yes; else echo py=no; fi ;;
nopy) for c in python3 python python3.99; do if command -v "$c" >/dev/null 2>&1; then echo "has-$c"; fi; done; echo end ;;
run) ajv -d "$2/data.json" -s "$2/schema.json"; echo "rc=$?" ;;
esac'
t_validator_repo() { # head body ; real ajv on PATH, the ajv stub fixture in HEAD
	t_init
	t_script scripts/toy.sh "$VSH"; t_commit base; t_mark_base
	mkdir -p "$WORK/realbin"; printf '#!/bin/sh\necho REAL-AJV\n' > "$WORK/realbin/ajv"
	printf '#!/bin/sh\necho FAKE\n' > "$WORK/realbin/python"; printf '#!/bin/sh\necho FAKE\n' > "$WORK/realbin/python3.99"
	chmod 755 "$WORK/realbin/ajv" "$WORK/realbin/python" "$WORK/realbin/python3.99"
	cp "$AJV_FIXTURE" "$R/tests-ajv.tmp"; mkdir -p "$R/tests/fixtures/ajv-stub"; mv "$R/tests-ajv.tmp" "$R/tests/fixtures/ajv-stub/ajv"; chmod 755 "$R/tests/fixtures/ajv-stub/ajv"
	printf '{"required":["a"]}\n' | t_put fxd/ok/schema.json; printf '{"a":1}\n' | t_put fxd/ok/data.json
	printf '{"required":["a"]}\n' | t_put fxd/bad/schema.json; printf '{"b":1}\n' | t_put fxd/bad/data.json
	t_script scripts/toy.sh "$1"; t_commit head
	T_PRE='export PATH="$WORK/realbin:$PATH"'
}
t_validator_repo 'echo ajv=real'
t_cases_one which - - - -; t_run_cases
t_expect "validator -: PATH unchanged after the stubs (a real ajv on PATH is visible)" 0 "OK 1 equal"

t_validator_repo 'echo ajv=stub'
t_cases_one which - - - ajv-stub; t_run_cases
t_expect "validator ajv-stub: the stub ajv shadows a real ajv" 0 "OK 1 equal"

t_validator_repo 'echo valid; echo "rc=0"'
t_cases_one 'run {FIXTURE}/ok' - fxd - ajv-stub; t_run_cases
t_expect "validator ajv-stub: conforming data -> valid, rc 0" 0 "OK 1 equal"

t_validator_repo "echo \"rc=1\"; echo \"invalid: missing ['a']\" >&2"
t_cases_one 'run {FIXTURE}/bad' - fxd - ajv-stub; t_run_cases
t_expect "validator ajv-stub: data missing a required key -> rc 1 and the stub's message" 0 "OK 1 equal"

t_validator_repo 'echo ajv=none'
t_cases_one which - - - none; t_run_cases
t_expect "validator none: a real ajv on PATH is not visible" 0 "OK 1 equal"

t_validator_repo 'echo end'
t_cases_one nopy - - - none; t_run_cases
t_expect "validator none: none of python3, python, python3.99 on PATH" 0 "OK 1 equal"

t_validator_repo 'echo end'
t_cases_one nopy - - - -; t_run_cases
if command -v python3 >/dev/null 2>&1; then
	t_expect_diffs "validator -: python3 stays visible (nopy differs from none)" "DIFF L1 stdout"
else
	t_expect "validator -: python3 stays visible (skipped: none here)" 0 "OK 1 equal"
fi

t_validator_repo 'echo ajv=none'
t_cases_one which - - - python; t_run_cases
if [ "$HAVE_JS" -eq 1 ]; then
	t_expect "validator python: ajv not visible, python3 with jsonschema is" 0 "OK 1 equal"
else
	t_expect "validator python: no jsonschema here -> could not set up: exit 2" 2
fi
t_validator_repo 'echo py=yes'
t_cases_one py - - - python; t_run_cases
if [ "$HAVE_JS" -eq 1 ]; then
	t_expect "validator python: python3 imports jsonschema" 0 "OK 1 equal"
else
	t_expect "validator python: no jsonschema here -> exit 2, never equal" 2
fi
# python3 that cannot import jsonschema (a blocking module first on PYTHONPATH) -> could not set up
t_validator_repo 'echo py=yes'
mkdir -p "$WORK/pyblock"; printf 'raise ImportError("blocked by the suite")\n' > "$WORK/pyblock/jsonschema.py"
T_PRE='export PYTHONPATH="$WORK/pyblock"'
t_cases_one py - - - python; t_run_cases
t_expect "validator python: python3 cannot import jsonschema -> exit 2" 2
if [ "$RC" -eq 2 ] && ! printf '%s' "$ERRTXT" | grep -q 'jsonschema'; then t_bad "validator python: reason must name jsonschema ($ERRTXT)"; fi
T_PRE=""

t_init
t_script scripts/toy.sh 'echo hi'; t_commit base; t_mark_base
t_script scripts/toy.sh 'echo hi # head'; t_commit head
t_cases_one x - - - ajv-stub; t_run_cases
t_expect "validator ajv-stub without tests/fixtures/ajv-stub/ajv in HEAD: exit 2" 2

# ---- arguments -------------------------------------------------------------------------
t_pair 'echo hi' 'echo hi'
t_cases_one x - - - -
t_run --cases="$CASES";                         t_expect "args: --base missing: exit 2" 2
t_run --base= --cases="$CASES";                 t_expect "args: --base empty: exit 2" 2
t_run --base=nosuchref --cases="$CASES";        t_expect "args: --base unresolvable: exit 2" 2
t_run --base="$BASE" ;                          t_expect "args: neither --cases nor --suite: exit 2" 2
t_run --base="$BASE" --cases="$CASES" --suite=tests/s; t_expect "args: both --cases and --suite: exit 2" 2
t_run --base="$BASE" --cases="$CASES" --bogus; t_expect "args: unknown argument: exit 2" 2
t_run --base="$BASE" --base="$BASE" --cases="$CASES"; t_expect "args: --base twice: exit 2" 2
t_run --base="$BASE" --cases="$WORK/nosuchfile.tsv"; t_expect "args: cases file missing: exit 2" 2
t_run --base="$BASE" --cases=; t_expect "args: --cases empty: exit 2" 2
t_run --base="$BASE" --suite=; t_expect "args: --suite empty: exit 2" 2
t_run --base=-x --cases="$CASES"; t_expect "args: --base starting with a dash: exit 2" 2
mkdir -p "$WORK/norepo"
T_RUNDIR="$WORK/norepo" t_run --base="$BASE" --cases="$CASES"
t_expect "args: not inside a git repository: exit 2" 2
T_RUNDIR=""

# ---- head is the commit, not the working tree ------------------------------------------
t_pair 'echo a' 'echo a'
printf '#!/usr/bin/env bash\necho dirty\n' > "$R/scripts/toy.sh"
t_cases_one x - - - -; t_run_cases
t_expect "head = the HEAD commit: an uncommitted edit of the script is ignored" 0 "OK 1 equal"
git -C "$R" checkout -q -- scripts/toy.sh

# ======================================================================================
# SUITE MODE
# ======================================================================================
t_suite_pair() { # base-suite-body head-suite-body : tests/s/test-a.sh at two commits
	t_init
	t_script tests/s/test-a.sh "$1"; t_commit base; t_mark_base
	t_script tests/s/test-a.sh "$2"; t_commit head
}
t_run_suite() { t_run --base="$BASE" --suite=tests/s; }

t_suite_pair 'echo "  ✓ alpha"; echo "  ✓ beta"; echo "  ✗ gamma"; echo "RESULTS: 2 passed, 1 failed"; exit 1' \
             'echo "PASS  alpha"; echo "PASS  beta"; echo "FAIL  gamma"; echo "test-a summary: PASS=2 FAIL=1"; exit 1'
t_run_suite
t_expect "suite: '  ✓ X' before and 'PASS  X' after (and ✗ -> FAIL): equal" 0 "SUITE tests/s/test-a.sh base_rc=1 head_rc=1 cases=3/3" "OK 1 equal"

t_suite_pair 'printf "PASS  %s\n" alpha; exit 0' 'printf "PASS  %-70s\n" alpha; exit 0'
t_run_suite
t_expect "suite: a name padded with %-70s equals the unpadded name" 0 "OK 1 equal"

t_suite_pair 'printf "PASS  alpha  \t\n"; exit 0' 'echo "  PASS alpha"; exit 0'
t_run_suite
t_expect "suite: leading whitespace, one space, and trailing blanks do not matter" 0 "OK 1 equal"

t_suite_pair 'echo "PASS  alpha"; echo "PASS  beta"; exit 0' 'echo "PASS  alpha"; exit 0'
t_run_suite
t_expect_diffs "suite: a lost case" "DIFF tests/s/test-a.sh case-only-at-base pass:beta"

t_suite_pair 'echo "PASS  alpha"; exit 0' 'echo "PASS  alpha2"; exit 0'
t_run_suite
t_expect_diffs "suite: a renamed case" "DIFF tests/s/test-a.sh case-only-at-base pass:alpha" "DIFF tests/s/test-a.sh case-only-at-head pass:alpha2"

t_suite_pair 'echo "PASS  alpha"; exit 0' 'echo "FAIL  alpha"; exit 0'
t_run_suite
t_expect_diffs "suite: a flipped status (same exit code)" "DIFF tests/s/test-a.sh case-only-at-base pass:alpha" "DIFF tests/s/test-a.sh case-only-at-head fail:alpha"

t_suite_pair 'echo "PASS  alpha"; exit 0' 'echo "PASS  alpha"; exit 1'
t_run_suite
t_expect_diffs "suite: the exit code differs (same cases)" "DIFF tests/s/test-a.sh rc"

t_suite_pair 'echo "PASS  alpha"; echo "PASS  alpha"; exit 0' 'echo "PASS  alpha"; exit 0'
t_run_suite
t_expect_diffs "suite: a case printed twice is a multiset entry" "DIFF tests/s/test-a.sh case-only-at-base pass:alpha"

t_suite_pair 'echo "PASS  alpha" >&2; exit 0' 'echo "PASS  alpha"; exit 0'
t_run_suite
t_expect "suite: case lines on stderr count (stdout and stderr are both parsed)" 0 "OK 1 equal"

t_suite_pair 'echo "PASSED alpha"; echo "PASS:alpha"; echo "FAILED beta"; echo "PASS"; echo "summary"; exit 0' 'echo nothing; exit 0'
t_run_suite
t_expect "suite: no case lines at either side: exit 2, never equal" 2

t_suite_pair 'echo "PASS  alpha"; exit 0' 'echo "all good"; exit 0'
t_run_suite
t_expect "suite: no case lines at HEAD only: exit 2" 2

t_suite_pair 'echo "all good"; exit 0' 'echo "PASS  alpha"; exit 0'
t_run_suite
t_expect "suite: no case lines at base only: exit 2" 2

t_suite_pair 'echo "PASS   "; exit 0' 'echo "PASS   "; exit 0'
t_run_suite
t_expect "suite: a marker followed only by blanks is not a case line: exit 2" 2

# several files, one differs; non-executable, non-test and nested files are not suites
t_init
t_script tests/s/test-a.sh 'echo "PASS  a"'; t_script tests/s/test-b.sh 'echo "PASS  b"'
printf 'echo "PASS  n"\n' | t_put tests/s/test-n.sh 644
t_script tests/s/helper.sh 'echo "PASS  h"'
t_script tests/s/sub/test-x.sh 'echo "PASS  x"'
t_commit base; t_mark_base
t_script tests/s/test-b.sh 'echo "PASS  b2"'
printf 'echo "FAIL  n"\n' | t_put tests/s/test-n.sh 644
t_script tests/s/helper.sh 'echo "FAIL  h"'
t_script tests/s/sub/test-x.sh 'echo "FAIL  x"'
t_commit head
t_run_suite
t_expect_diffs "suite: only test-b differs; test-n.sh (644), helper.sh and sub/test-x.sh are ignored" "DIFF tests/s/test-b.sh case-only-at-base pass:b" "DIFF tests/s/test-b.sh case-only-at-head pass:b2"
if printf '%s\n' "$OUT" | grep -q '^SUITE tests/s/test-a.sh '; then t_ok "suite: test-a still reported as compared"; else t_bad "suite: test-a still reported as compared"; fi

t_init
t_script tests/s/test-a.sh 'echo "PASS  a"'; t_commit base; t_mark_base
t_script tests/s/test-new.sh 'echo "PASS  new"'; t_commit head
t_run_suite
t_expect_diffs "suite: a suite file at head only" "DIFF tests/s/test-new.sh only-at-head"

t_init
t_script tests/s/test-a.sh 'echo "PASS  a"'; t_script tests/s/test-old.sh 'echo "PASS  old"'; t_commit base; t_mark_base
git -C "$R" rm -q tests/s/test-old.sh; t_commit head
t_run_suite
t_expect_diffs "suite: a suite file at base only" "DIFF tests/s/test-old.sh only-at-base"

t_init
printf 'echo "PASS  a"\n' | t_put tests/s/test-a.sh 644; t_commit base; t_mark_base
printf 'echo "PASS  a"\n' | t_put tests/s/test-a.sh 644; echo '# x' >> "$R/tests/s/test-a.sh"; t_commit head
t_run_suite
t_expect "suite: no executable test-*.sh at either side: exit 2" 2

t_init
t_script tests/s/test-a.sh 'echo "PASS  a"'; t_commit base; t_mark_base
git -C "$R" rm -q tests/s/test-a.sh; t_script tests/s/helper.sh 'echo h'; t_commit head
t_run_suite
t_expect "suite: no executable test-*.sh at head: exit 2" 2

t_suite_pair 'echo "PASS  a"' 'echo "PASS  a"'
t_run --base="$BASE" --suite=tests/nosuchdir
t_expect "suite: directory absent at both sides: exit 2" 2
t_run --base="$BASE" --suite=../s
t_expect "suite: directory with '..': exit 2" 2
t_run --base="$BASE" --suite=tests/s/
t_expect "suite: trailing slash on the directory is fine" 0 "OK 1 equal"

# ======================================================================================
# CLEANUP ON A SIGNAL
# ======================================================================================
t_init
t_script scripts/toy.sh 'echo $$ > "$FIFO"; exec sleep 20'; t_commit base; t_mark_base
t_script scripts/toy.sh 'echo $$ > "$FIFO"; exec sleep 20 # head'; t_commit head
mkfifo "$WORK/fifo"
t_cases_one x "FIFO=$WORK/fifo" - - -
exec 3<>"$WORK/fifo"
( cd "$R" && TMPDIR="$WORK/tmp" exec bash "$G3" --base="$BASE" --cases="$CASES" ) >"$WORK/sig.out" 2>"$WORK/sig.err" </dev/null &
BGPID=$!
CPID=""
if read -t 30 -u 3 CPID; then
	kill -TERM "$BGPID" 2>/dev/null
	wait "$BGPID" 2>/dev/null
	RC=$?
else
	kill -KILL "$BGPID" 2>/dev/null; wait "$BGPID" 2>/dev/null; RC=99
fi
BGPID=""
exec 3<&-
OUT="$(cat "$WORK/sig.out")"; ERRTXT="$(cat "$WORK/sig.err")"
t_expect "SIGTERM during a run: exit 143, worktree and temp dir removed" 143
if [ -n "$CPID" ] && ps -p "$CPID" >/dev/null 2>&1; then
	kill -KILL "$CPID" 2>/dev/null
	t_bad "SIGTERM during a run: the script that was running is still alive"
else
	t_ok "SIGTERM during a run: the script that was running is gone"
fi

cd "$REPO_ROOT" || exit 1
echo ""
echo "test-check-refactor-equivalence.sh summary: PASS=${PASS}  FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
