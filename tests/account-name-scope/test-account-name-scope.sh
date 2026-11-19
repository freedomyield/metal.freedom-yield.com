#!/usr/bin/env bash
# test-account-name-scope.sh — suite for scripts/check-account-name-scope.sh
# (the gate that keeps the four on-chain account names out of the public tree,
# 2026-11-19 anchor-name-out design, section 7).
#
# Every case builds a throwaway git repo (mktemp -d, removed by trap) with FAKE names
# (the two variables below) and a scope definition made from their sha256, and runs the
# gate there. Each case checks the exit code and the shape of the output lines; every
# case also checks that no fake name (any letter case) appears on stdout or stderr.
# The gate must fail closed: anything it could not look at is exit 2 and never `OK`.
# The last stage runs the gate on THIS repository with the real definition: `OK` passes,
# `DISABLED` is shown as "switched off" and passes, anything else fails (spec 9.8).
#
# CHAIN: none — local temporary git repos only; no host, no network, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Usage:
#   bash tests/account-name-scope/test-account-name-scope.sh
# Test-only knob: FYD_NAME_SCOPE_GATE replaces the gate under test (used to run the
# suite against deliberately broken copies of the gate).

set -u
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="${FYD_NAME_SCOPE_GATE:-${REPO_ROOT}/scripts/check-account-name-scope.sh}"
BASH_BIN="$(command -v bash)"
GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)

# The fake names (one variable each). Never real values.
FAKE_ACCOUNT="fakeanchor12"
FAKE_SINK="fakesink1"
# A fifth fake name used by the longest-match cases only: it contains FAKE_SINK whole.
FAKE_REH_SINK="fakesink1tst"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; WORK=""; }
trap cleanup EXIT

sha_of() { perl -MDigest::SHA=sha256_hex -e 'print sha256_hex(lc $ARGV[0])' "$1"; }
H_ACC="$(sha_of "$FAKE_ACCOUNT")"
H_SINK="$(sha_of "$FAKE_SINK")"
H_REH_SINK="$(sha_of "$FAKE_REH_SINK")"
TAB=$'\t'

OUT=""; ERR=""; RC=0
R=""; CFG=""; T_TODAY="2026-11-19"; RUN_DIR=""; PATH_OVERRIDE=""; PERL5LIB_OVERRIDE=""

# row <hash> <role> <glob> <until> <reason> -> one definition line
row() { printf '%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5"; }
ACC_ROW_VERIFY="$(row "$H_ACC" anchor-account public/verify/index.html - 'verify page')"
ACC_ROW_FROZEN="$(row "$H_ACC" anchor-account 'docs/frozen/*.sh' 2026-12-08 'frozen script')"
SINK_ROW_LEGACY="$(row "$H_SINK" anchor-sink 'public/api/legacy/*.json' - 'legacy responses')"

# write_cfg <line>...  (first line is written as given: the caller supplies `enabled`)
write_cfg() { : > "$CFG"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$CFG"; done; }
default_cfg() { write_cfg '# test scope definition' "enabled${TAB}1" "$ACC_ROW_VERIFY" "$ACC_ROW_FROZEN" "$SINK_ROW_LEGACY"; }

put() { mkdir -p "$(dirname "$R/$1")"; printf '%b' "$2" > "$R/$1"; } # put <path> <content with \n escapes>
commit() { ( cd "$R" && git add -- ':/' >/dev/null 2>&1 && git "${GITQ[@]}" commit -q --allow-empty -m "${1:-change}" >/dev/null 2>&1 ); }

# mkrepo: a repository whose tree is entirely in scope; default definition and today.
mkrepo() {
	cleanup
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/ans-test.XXXXXX")" || exit 1
	R="$WORK/r"; mkdir -p "$R"
	( cd "$R" && git init -q . >/dev/null 2>&1 )
	CFG="$WORK/scope.tsv"; T_TODAY="2026-11-19"; RUN_DIR=""; PATH_OVERRIDE=""; PERL5LIB_OVERRIDE=""
	default_cfg
}
seed_ok() { # 4 files, all inside their allowed places; the gate must say `OK 4 files`
	put public/verify/index.html "<p>${FAKE_ACCOUNT}</p>\n"
	put docs/frozen/a.sh "# ${FAKE_ACCOUNT}\n"
	put public/api/legacy/x.json "{\"to\":\"${FAKE_SINK}\"}\n"
	put README.md "hello\n"
	commit seed
}

run_gate() {
	local dir="${RUN_DIR:-$R}"
	OUT="$(
		cd "$dir" || exit 99
		export FYD_NAME_SCOPE_CONFIG="$CFG"
		if [ -n "${T_TODAY+x}" ] && [ "$T_TODAY" != "__unset__" ]; then export FYD_NAME_SCOPE_TODAY="$T_TODAY"; else unset FYD_NAME_SCOPE_TODAY; fi
		[ -n "$PERL5LIB_OVERRIDE" ] && export PERL5LIB="$PERL5LIB_OVERRIDE"
		[ -n "$PATH_OVERRIDE" ] && export PATH="$PATH_OVERRIDE"
		"$BASH_BIN" "$GATE" "$@" 2>"$WORK/err"
	)"; RC=$?
	ERR="$(cat "$WORK/err")"
}

has_line() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
no_leak() { ! printf '%s\n%s\n' "$OUT" "$ERR" | grep -qiF -e "$FAKE_ACCOUNT" -e "$FAKE_SINK" -e "$FAKE_REH_SINK"; }

# expect <name> <rc> [exact stdout line]...
expect() {
	local name="$1" want="$2" l; shift 2
	if [ "$RC" -ne "$want" ]; then bad "$name (rc=$RC want=$want out=$(printf '%s' "$OUT" | head -n 3 | tr '\n' '|') err=$(printf '%s' "$ERR" | head -n 1))"; return; fi
	for l in "$@"; do has_line "$l" || { bad "$name (missing line: $l | got: $(printf '%s' "$OUT" | head -n 4 | tr '\n' '|'))"; return; }; done
	if [ "$want" -ne 0 ] && printf '%s\n' "$OUT" | grep -qE '^(OK|DISABLED)'; then bad "$name (printed OK/DISABLED)"; return; fi
	if [ "$want" -eq 2 ]; then
		[ -n "$ERR" ] || { bad "$name (rc 2 without a reason on stderr)"; return; }
		printf '%s\n' "$OUT" | grep -qE '^(VIOLATION|EXPIRED|OBSOLETE)' && { bad "$name (printed a verdict with rc 2)"; return; }
	fi
	no_leak || { bad "$name (a fake name leaked into the output)"; return; }
	ok "$name"
}
# expect_only <name> <rc> <line>...: like expect, and stdout has exactly these lines
expect_only() {
	local name="$1" want="$2"; shift 2
	local exp; exp="$(printf '%s\n' "$@")"
	if [ "$OUT" != "$exp" ]; then bad "$name (stdout differs: got=$(printf '%s' "$OUT" | head -n 6 | tr '\n' '|'))"; return; fi
	expect "$name" "$want" "$@"
}

if [ ! -f "$GATE" ]; then
	echo "FATAL: gate not found at $GATE" >&2
	# Red phase of TDD: the cases below fail because the script is missing.
fi

# ---- arguments ------------------------------------------------------------------------
mkrepo; seed_ok
run_gate; expect_only "all-good: OK with the number of scanned files" 0 "OK 4 files"
run_gate --bogus; expect "args: unknown argument is 2" 2
run_gate --messages=; expect "args: --messages= (empty) is 2" 2
run_gate --index --messages=HEAD; expect "args: --index with --messages is 2" 2
run_gate --messages=HEAD --index; expect "args: --messages with --index is 2 (other order)" 2
run_gate extra; expect "args: a stray positional argument is 2" 2
run_gate -h; expect "args: -h prints usage, exit 0" 0
printf '%s\n' "$OUT" | grep -qi 'usage' && ok "args: -h output has a Usage line" || bad "args: -h output has a Usage line"

# ---- the definition file --------------------------------------------------------------
mkrepo; seed_ok
CFG="$WORK/nonexistent.tsv"; run_gate; expect "config: missing file is 2" 2
CFG=""; run_gate; expect "config: FYD_NAME_SCOPE_CONFIG set but empty is 2" 2
CFG="$WORK/scope.tsv"; default_cfg; chmod 000 "$CFG"
if [ "$(id -u)" -eq 0 ]; then ok "config: unreadable file is 2 (skipped as root)"; else run_gate; expect "config: unreadable file is 2" 2; fi
chmod 644 "$CFG"
: > "$CFG"; run_gate; expect "config: empty file (no enabled row) is 2" 2
write_cfg '# only comments' ''; run_gate; expect "config: comments only is 2" 2
write_cfg "$ACC_ROW_VERIFY" "$SINK_ROW_LEGACY"; run_gate; expect "config: enabled row missing (a name row comes first) is 2" 2
for v in 2 yes ''; do
	write_cfg "enabled${TAB}${v}" "$ACC_ROW_VERIFY"; run_gate; expect "config: enabled value '${v}' is 2" 2
done
write_cfg "enabled${TAB}1"; run_gate; expect "config: zero name rows is 2" 2
write_cfg "enabled${TAB}1" '# a comment but no rows' ''; run_gate; expect "config: zero name rows (comments between) is 2" 2
write_cfg "enabled${TAB}1" "$SINK_ROW_LEGACY" "${ACC_ROW_VERIFY}${TAB}extra"; run_gate; expect "config: six columns is 2" 2
write_cfg "enabled${TAB}1" "$SINK_ROW_LEGACY" "$(printf '%s\t%s\t%s\t%s' "$H_ACC" anchor-account public/verify/index.html -)"; run_gate; expect "config: four columns is 2" 2
write_cfg "enabled${TAB}1" "$SINK_ROW_LEGACY" "$(row "${H_ACC%?}" anchor-account public/verify/index.html - r)"; run_gate; expect "config: 63-character hash is 2" 2
write_cfg "enabled${TAB}1" "$SINK_ROW_LEGACY" "$(row "$(printf '%s' "$H_ACC" | tr 'a-f' 'A-F')" anchor-account public/verify/index.html - r)"; run_gate; expect "config: uppercase hash is 2" 2
write_cfg "enabled${TAB}1" "$SINK_ROW_LEGACY" "$(row "g${H_ACC#?}" anchor-account public/verify/index.html - r)"; run_gate; expect "config: non-hex hash is 2" 2
write_cfg "enabled${TAB}1" "$SINK_ROW_LEGACY" "$(row "$H_ACC" some-other-role public/verify/index.html - r)"; run_gate; expect "config: role outside the four is 2" 2
for g in '' 'docs/**/a.sh' 'docs/?.sh' 'docs/[ab].sh' 'docs/{a,b}.sh' '/docs/a.sh' 'docs/../a.sh' '..'; do
	write_cfg "enabled${TAB}1" "$SINK_ROW_LEGACY" "$(row "$H_ACC" anchor-account "$g" - r)"; run_gate; expect "config: glob '${g}' is 2" 2
done
for u in 2026-02-30 2026-1-1 tomorrow '' 2026-13-01 2026-00-10 2026-11-31 2027-02-29; do
	write_cfg "enabled${TAB}1" "$SINK_ROW_LEGACY" "$(row "$H_ACC" anchor-account public/verify/index.html "$u" r)"; run_gate; expect "config: until '${u}' is 2" 2
done
write_cfg "enabled${TAB}1" "$(row "$H_ACC" anchor-account public/verify/index.html 2028-02-29 r)" "$SINK_ROW_LEGACY"; run_gate
expect "config: a real leap day is a valid until (rc 1 from the unlisted frozen file, not 2)" 1
write_cfg "enabled${TAB}1" "$SINK_ROW_LEGACY" "$(row "$H_ACC" anchor-account public/verify/index.html - '')"; run_gate; expect "config: empty reason is 2" 2
write_cfg "enabled${TAB}1" "$ACC_ROW_VERIFY" "$ACC_ROW_VERIFY"; run_gate; expect "config: the same row twice is 2" 2
write_cfg "enabled${TAB}1" "$ACC_ROW_VERIFY" "$(row "$H_ACC" anchor-sink public/verify/index.html - 'same hash, another role')"; run_gate; expect "config: one hash under two roles is 2" 2
default_cfg

# ---- FYD_NAME_SCOPE_TODAY -------------------------------------------------------------
for d in 20261119 2026-13-01 'today' ''; do
	T_TODAY="$d"; run_gate; expect "today: '${d}' is not a date, 2" 2
done
T_TODAY="__unset__"; run_gate
case "$RC:$(printf '%s' "$OUT" | head -n 1)" in
	0:OK*) ok "today: unset falls back to the UTC date (no row expires before the year 2100)" ;;
	1:*) # the default rows expire 2026-12-08: after that date the unset case is EXPIRED, which is right
		if [ "$(date -u +%Y-%m-%d)" \> "2026-12-08" ]; then ok "today: unset falls back to the UTC date (rows have expired, so 1)"; else bad "today: unset (rc=$RC out=$(printf '%s' "$OUT" | head -n 2 | tr '\n' '|'))"; fi ;;
	*) bad "today: unset (rc=$RC err=$ERR)" ;;
esac
T_TODAY="2026-11-19"

# ---- git ------------------------------------------------------------------------------
mkrepo; seed_ok
mkdir -p "$WORK/notrepo"; RUN_DIR="$WORK/notrepo"; run_gate; expect "git: outside a repository is 2" 2; RUN_DIR=""
mkdir -p "$WORK/emptyrepo"; ( cd "$WORK/emptyrepo" && git init -q . >/dev/null 2>&1 ); RUN_DIR="$WORK/emptyrepo"; run_gate; expect "git: no HEAD (no commit) is 2" 2; RUN_DIR=""
run_gate --messages=no-such-base; expect "git: --messages base that does not exist is 2" 2
mkrepo; seed_ok
blob="$(cd "$R" && git rev-parse HEAD:README.md)"; rm -f "$R/.git/objects/${blob%"${blob#??}"}/${blob#??}"
run_gate; expect "scan-died: a tracked blob that cannot be read (cat-file fails, no completion mark) is 2" 2
mkrepo; seed_ok
tree="$(cd "$R" && git rev-parse 'HEAD^{tree}')"; rm -f "$R/.git/objects/${tree%"${tree#??}"}/${tree#??}"
run_gate; expect "git: ls-tree fails on HEAD (tree object gone) is 2, not an empty OK" 2
mkrepo; seed_ok
printf 'bad\n' > "$R/tab$TAB.txt" 2>/dev/null && { commit tabname; run_gate; expect "git: a tracked path with a tab is 2" 2; }

# ---- perl and Digest::SHA --------------------------------------------------------------
mkrepo; seed_ok
mkdir -p "$WORK/nopath"
for t in git mktemp rm date sort cat head tail tr uniq wc sed awk grep mkdir cut dirname basename comm env printf test; do
	p="$(command -v "$t" 2>/dev/null)" || continue
	case "$p" in /*) printf '#!/bin/sh\nexec %s "$@"\n' "$p" > "$WORK/nopath/$t"; chmod +x "$WORK/nopath/$t" ;; esac
done
PATH_OVERRIDE="$WORK/nopath"; run_gate; expect "perl: not on PATH is 2" 2
PATH_OVERRIDE=""
mkdir -p "$WORK/badperl/Digest"; printf 'die "Digest::SHA unavailable (test)\\n";\n1;\n' > "$WORK/badperl/Digest/SHA.pm"
PERL5LIB_OVERRIDE="$WORK/badperl"; run_gate; expect "perl: Digest::SHA cannot be loaded is 2" 2
PERL5LIB_OVERRIDE=""

# ---- name in content -------------------------------------------------------------------
mkrepo; seed_ok
put src/leak.txt "line one\nline two\nsee ${FAKE_ACCOUNT} here\n"; commit leak
run_gate; expect "content: name outside every allowed glob is 1, VIOLATION with path:line" 1 "VIOLATION src/leak.txt:3 anchor-account"
printf '%s\n' "$OUT" | grep -q '^OK' && bad "content: no OK is printed with a violation" || ok "content: no OK is printed with a violation"
mkrepo; seed_ok
put src/leak.txt "x ${FAKE_SINK}\n"; commit leak
run_gate; expect "content: the sink name is judged by its own role and glob" 1 "VIOLATION src/leak.txt:1 anchor-sink"
mkrepo; seed_ok
put docs/frozen/b.sh "# ${FAKE_SINK}\n"; commit sinkinfrozen
run_gate; expect "content: a name is allowed only by ITS OWN rows (the account's glob does not allow the sink)" 1 "VIOLATION docs/frozen/b.sh:1 anchor-sink"
mkrepo; seed_ok
put src/Upper.txt "NOTE: $(printf "%s" "$FAKE_ACCOUNT" | tr a-z A-Z)\n"; commit upper
run_gate; expect "case: an upper-case name in content is found (lower-cased before hashing)" 1 "VIOLATION src/Upper.txt:1 anchor-account"
mkrepo; seed_ok
put src/near.txt "x${FAKE_ACCOUNT} ${FAKE_ACCOUNT}_suffix ${FAKE_ACCOUNT}9 prefix_${FAKE_ACCOUNT}\n"; commit near
run_gate; expect_only "substring rule: the name glued to word characters is still a hit (no word boundary is looked at)" 1 "VIOLATION src/near.txt:1 anchor-account"
mkrepo; seed_ok
put src/glued1.txt "a ${FAKE_SINK}stub b\n"; commit glued1
run_gate; expect_only "substring rule: content - the name followed by letters is a VIOLATION" 1 "VIOLATION src/glued1.txt:1 anchor-sink"
mkrepo; seed_ok
put src/glued2.txt "a x${FAKE_ACCOUNT} b\n"; commit glued2
run_gate; expect_only "substring rule: content - the name preceded by a letter is a VIOLATION" 1 "VIOLATION src/glued2.txt:1 anchor-account"
mkrepo; seed_ok
put "src/${FAKE_SINK}stub.txt" "clean\n"; commit gluedpath
run_gate; expect_only "substring rule: path - the name followed by letters is a VIOLATION (redacted, no name left)" 1 "VIOLATION src/<anchor-sink>stub.txt:path anchor-sink"
mkrepo; seed_ok
base="$(cd "$R" && git rev-parse HEAD)"; put src/ok.txt "fine\n"; commit "note x${FAKE_ACCOUNT}stub"
head12="$(cd "$R" && git rev-parse HEAD | cut -c1-12)"
run_gate --messages="$base"; expect_only "substring rule: commit message - the name inside a longer word is a VIOLATION" 1 "VIOLATION commit:${head12} anchor-account"
mkrepo; seed_ok
put src/mixed.txt "Mixed $(printf '%s' "$FAKE_SINK" | sed 's/^f/F/; s/s/S/') here\n"; commit mixed
run_gate; expect_only "substring rule: a mixed-case name (FakeSink1 form) is a VIOLATION" 1 "VIOLATION src/mixed.txt:1 anchor-sink"
mkrepo; seed_ok
put src/mixed2.txt "GLUED_$(printf '%s' "$FAKE_ACCOUNT" | tr a-z A-Z)STUB\n"; commit mixed2
run_gate; expect_only "substring rule: upper-case name inside a longer upper-case word is a VIOLATION" 1 "VIOLATION src/mixed2.txt:1 anchor-account"
mkrepo; seed_ok
put docs/frozen/glued.sh "# ${FAKE_ACCOUNT}stub and x${FAKE_ACCOUNT}\n"; commit gluedallowed
run_gate; expect_only "substring rule: a glued name inside an allowed glob is OK (allowed place stays allowed)" 0 "OK 5 files"
mkrepo; seed_ok
put "docs/frozen/${FAKE_ACCOUNT}stub.sh" "clean\n"; commit gluedfrozenpath
run_gate; expect_only "substring rule: redaction leaves no name in the output when the name sits in a glued path word" 1 "VIOLATION docs/frozen/<anchor-account>stub.sh:path anchor-account"
mkrepo; seed_ok
put src/punct.txt "a.${FAKE_ACCOUNT}.b (${FAKE_SINK}) \"${FAKE_ACCOUNT}\"\n"; commit punct
run_gate; expect "word rule: the name between punctuation is a hit (two names, one line each role)" 1 "VIOLATION src/punct.txt:1 anchor-account" "VIOLATION src/punct.txt:1 anchor-sink"
mkrepo; seed_ok
printf 'AB\000\000%s\000\377\376tail\n' "$FAKE_ACCOUNT" > "$R/src.bin"; commit binary
run_gate; expect "binary: a name inside binary content is found" 1 "VIOLATION src.bin:1 anchor-account"
mkrepo; seed_ok
put src/a.txt "${FAKE_ACCOUNT}\n"; put src/b.txt "x\n${FAKE_SINK}\n"; commit two
run_gate; expect "output: all violations are printed (sorted) before exit 1" 1 "VIOLATION src/a.txt:1 anchor-account" "VIOLATION src/b.txt:2 anchor-sink"
[ "$(printf '%s\n' "$OUT" | grep -c '^VIOLATION')" -eq 2 ] && ok "output: exactly the two violations are listed" || bad "output: exactly the two violations are listed"
mkrepo; seed_ok
put docs/frozen/z.sh "a\n${FAKE_ACCOUNT}\n${FAKE_ACCOUNT}\n"; commit x; put README.md "uncommitted ${FAKE_ACCOUNT}\n"
run_gate; expect_only "default: reads HEAD, not the work tree (an uncommitted edit changes nothing)" 0 "OK 5 files"

# ---- name in the path ------------------------------------------------------------------
mkrepo; seed_ok
put "public/api/legacy/${FAKE_SINK}.json" "{\"to\":\"${FAKE_SINK}\"}\n"; commit pathname
run_gate; expect_only "path: a name in the path is a violation even where the glob allows the content (path shown redacted)" 1 "VIOLATION public/api/legacy/<anchor-sink>.json:path anchor-sink"
mkrepo; seed_ok
put "docs/$(printf "%s" "$FAKE_ACCOUNT" | tr a-z A-Z)-notes.md" "clean\n"; commit upperpath
run_gate; expect "path: an upper-case name in the path is found" 1 "VIOLATION docs/<anchor-account>-notes.md:path anchor-account"
mkrepo; seed_ok
( cd "$R" && git update-index --add --cacheinfo "160000,$(printf 'a%.0s' $(seq 1 40)),sub/${FAKE_SINK}" && git "${GITQ[@]}" commit -q -m gitlink >/dev/null 2>&1 )
run_gate; expect "submodule: the path of a gitlink is checked, its content is not read (rc 1, not 2)" 1 "VIOLATION sub/<anchor-sink>:path anchor-sink"
mkrepo; seed_ok
( cd "$R" && git update-index --add --cacheinfo "160000,$(printf 'a%.0s' $(seq 1 40)),sub/clean" && git "${GITQ[@]}" commit -q -m gitlink >/dev/null 2>&1 )
run_gate; expect_only "submodule: a clean gitlink is counted and never read (OK, not 2)" 0 "OK 5 files"

# ---- commit messages -------------------------------------------------------------------
mkrepo; seed_ok
base="$(cd "$R" && git rev-parse HEAD)"
put src/ok.txt "fine\n"; commit "a note that mentions $(printf "%s" "$FAKE_ACCOUNT" | tr a-z A-Z)"
head12="$(cd "$R" && git rev-parse HEAD | cut -c1-12)"
run_gate --messages="$base"; expect "messages: a name in a commit message of base..HEAD is 1 (commit:<12 hex>)" 1 "VIOLATION commit:${head12} anchor-account"
run_gate; expect_only "messages: without --messages the commit text is not looked at" 0 "OK 5 files"
base2="$(cd "$R" && git rev-parse HEAD)"; put src/more.txt "fine\n"; commit "clean message"
run_gate --messages="$base2"; expect_only "messages: a name in a commit at or before the base is not looked at" 0 "OK 6 files"
put src/leak2.txt "${FAKE_SINK}\n"; commit "clean again"
run_gate --messages="$base2"; expect "messages: the tree is still checked in --messages mode" 1 "VIOLATION src/leak2.txt:1 anchor-sink"
# the scan of the commit messages dies after it started: a perl shim that exits 0 and prints
# nothing only for the commit-message program (found by a string only that program holds; the tree scan and the judge run on the real perl)
mkrepo; seed_ok
base3="$(cd "$R" && git rev-parse HEAD)"; put src/more.txt "fine\n"; commit "clean message"
mkdir -p "$WORK/shim"; REAL_PERL="$(command -v perl)"
printf '#!/bin/sh\ncase "$2" in *"a commit record could not be read"*) exit 0 ;; esac\nexec %s "$@"\n' "$REAL_PERL" > "$WORK/shim/perl"; chmod +x "$WORK/shim/perl"
PATH_OVERRIDE="$WORK/shim:$PATH"; run_gate --messages="$base3"
expect "scan-died: the commit-message scan prints no completion mark (exit 0, no output) is 2, no verdict" 2
PATH_OVERRIDE=""; run_gate --messages="$base3"; expect_only "scan-died: the same repository with the real perl is OK (the shim was the only cause)" 0 "OK 5 files"

# ---- --index ---------------------------------------------------------------------------
mkrepo; seed_ok
put src/staged.txt "${FAKE_ACCOUNT}\n"; ( cd "$R" && git add -- src/staged.txt >/dev/null 2>&1 )
run_gate; expect_only "index: a staged-only name is invisible to the default (HEAD) mode" 0 "OK 4 files"
run_gate --index; expect "index: --index finds the staged name" 1 "VIOLATION src/staged.txt:1 anchor-account"
put src/staged.txt "clean in the work tree\n"
run_gate --index; expect "index: --index reads the staged blob, not the work tree" 1 "VIOLATION src/staged.txt:1 anchor-account"
mkrepo; seed_ok
put "src/${FAKE_SINK}.txt" "clean\n"; ( cd "$R" && git add -- ':/' >/dev/null 2>&1 )
run_gate --index; expect "index: --index finds a staged path with a name" 1 "VIOLATION src/<anchor-sink>.txt:path anchor-sink"
mkrepo; seed_ok
run_gate --index; expect_only "index: a clean index is OK with the same file count" 0 "OK 4 files"

# ---- EXPIRED and OBSOLETE ---------------------------------------------------------------
mkrepo; seed_ok
T_TODAY="2026-12-08"; run_gate; expect_only "expired: until = today is still valid" 0 "OK 4 files"
T_TODAY="2026-12-09"; run_gate
expect "expired: until < today is EXPIRED, and the place it allowed is a VIOLATION again" 1 "EXPIRED anchor-account docs/frozen/*.sh 2026-12-08" "VIOLATION docs/frozen/a.sh:1 anchor-account"
if [ "$RC" -eq 1 ] && ! printf '%s\n' "$OUT" | grep -q '^OBSOLETE'; then ok "expired: an expired row is not also reported OBSOLETE"; else bad "expired: an expired row is not also reported OBSOLETE"; fi
T_TODAY="2026-11-19"
mkrepo; seed_ok
write_cfg "enabled${TAB}1" "$ACC_ROW_VERIFY" "$ACC_ROW_FROZEN" "$SINK_ROW_LEGACY" "$(row "$H_SINK" anchor-sink 'docs/nothing/*.md' - 'unused')"
run_gate; expect "obsolete: a row whose glob matches nothing is OBSOLETE (rc 1)" 1 "OBSOLETE anchor-sink docs/nothing/*.md"
mkrepo; seed_ok
put docs/frozen/b.sh "no name here\n"; git -C "$R" rm -q -f docs/frozen/a.sh; commit swap
run_gate; expect "obsolete: a glob that matches files but none with the name inside is OBSOLETE" 1 "OBSOLETE anchor-account docs/frozen/*.sh"
mkrepo; seed_ok
( cd "$R" && git rm -q -f public/api/legacy/x.json >/dev/null 2>&1 ); commit nolegacy
run_gate; expect "obsolete: the same on the sink row after its file is removed" 1 "OBSOLETE anchor-sink public/api/legacy/*.json"
mkrepo; seed_ok
SINK_ROW_VERIFY="$(row "$H_SINK" anchor-sink public/verify/index.html - 'same glob as the account row')"
write_cfg "enabled${TAB}1" "$ACC_ROW_VERIFY" "$SINK_ROW_VERIFY" "$ACC_ROW_FROZEN" "$SINK_ROW_LEGACY"
run_gate; expect_only "obsolete: judged per name (two rows with one glob, only the account name is in the file: the sink row is OBSOLETE)" 1 "OBSOLETE anchor-sink public/verify/index.html"
mkrepo; seed_ok
put public/api/legacy/deep/y.json "${FAKE_SINK}\n"; ( cd "$R" && git rm -q -f public/api/legacy/x.json >/dev/null 2>&1 ); commit deepunder
run_gate; expect "glob: * does not cross a slash (a name one directory deeper is a VIOLATION)" 1 "VIOLATION public/api/legacy/deep/y.json:1 anchor-sink"

# ---- longest match: a short name inside a longer name counts for the longer one only ----
REH_ROW="$(row "$H_REH_SINK" rehearsal-anchor-sink 'docs/rehearsal/*.sh' - 'rehearsal script')"
longest_cfg() { write_cfg "enabled${TAB}1" "$ACC_ROW_VERIFY" "$ACC_ROW_FROZEN" "$SINK_ROW_LEGACY" "$REH_ROW"; }
mkrepo; seed_ok; longest_cfg
put src/alone.txt "to ${FAKE_SINK}\n"; commit alone
run_gate; expect_only "longest: (a) the production sink name alone is anchor-sink" 1 "VIOLATION src/alone.txt:1 anchor-sink" "OBSOLETE rehearsal-anchor-sink docs/rehearsal/*.sh"
mkrepo; seed_ok; longest_cfg
put src/glued.txt "a ${FAKE_SINK}stub b x${FAKE_SINK}\n"; commit glued
run_gate; expect_only "longest: (b) the production sink name with letters glued on or before is anchor-sink" 1 "VIOLATION src/glued.txt:1 anchor-sink" "OBSOLETE rehearsal-anchor-sink docs/rehearsal/*.sh"
mkrepo; seed_ok; longest_cfg
put docs/rehearsal/r.sh "# ${FAKE_REH_SINK}\n"; commit reh
run_gate; expect_only "longest: (c) the rehearsal sink name in its own glob is OK, no anchor-sink hit" 0 "OK 5 files"
mkrepo; seed_ok; longest_cfg
put docs/rehearsal/r.sh "# ${FAKE_REH_SINK}\n# ${FAKE_SINK}\n"; commit reh2
run_gate; expect_only "longest: (c) a bare production sink name in the same file is still an anchor-sink VIOLATION" 1 "VIOLATION docs/rehearsal/r.sh:2 anchor-sink"
mkrepo; seed_ok; longest_cfg
put src/leak2.txt "${FAKE_REH_SINK}\n"; commit reh3
run_gate; expect_only "longest: the rehearsal sink name outside its glob is rehearsal-anchor-sink only" 1 "VIOLATION src/leak2.txt:1 rehearsal-anchor-sink" "OBSOLETE rehearsal-anchor-sink docs/rehearsal/*.sh"
mkrepo; seed_ok; longest_cfg
put "docs/rehearsal/${FAKE_REH_SINK}.sh" "clean\n"; commit rehpath
run_gate; expect_only "longest: a path holding the rehearsal name is redacted by the longer role, no name left" 1 "VIOLATION docs/rehearsal/<rehearsal-anchor-sink>.sh:path rehearsal-anchor-sink" "OBSOLETE rehearsal-anchor-sink docs/rehearsal/*.sh"
mkrepo; seed_ok; longest_cfg
base="$(cd "$R" && git rev-parse HEAD)"; put src/ok.txt "fine\n"; commit "note ${FAKE_REH_SINK}"
head12="$(cd "$R" && git rev-parse HEAD | cut -c1-12)"
run_gate --messages="$base"; expect_only "longest: a commit message holding the rehearsal name is the rehearsal role only" 1 "VIOLATION commit:${head12} rehearsal-anchor-sink" "OBSOLETE rehearsal-anchor-sink docs/rehearsal/*.sh"

# ---- enabled 0 ---------------------------------------------------------------------------
mkrepo; seed_ok
put src/leak.txt "${FAKE_ACCOUNT}\n"; commit leak
write_cfg "enabled${TAB}0" "this line is not even a row"
run_gate; expect_only "disabled: enabled 0 is DISABLED, exit 0, the other lines are not read" 0 "DISABLED"
run_gate --index; expect_only "disabled: also with --index" 0 "DISABLED"

# ---- the real tree -------------------------------------------------------------------------
REAL_OUT="$( cd "$REPO_ROOT" && env -u FYD_NAME_SCOPE_CONFIG -u FYD_NAME_SCOPE_TODAY "$BASH_BIN" "$GATE" 2>&1 )"; REAL_RC=$?
if [ "$REAL_RC" -eq 0 ] && printf '%s\n' "$REAL_OUT" | grep -qE '^OK [0-9]+ files$'; then
	ok "real-tree: the gate on this repository with the real definition says OK"
elif [ "$REAL_RC" -eq 0 ] && [ "$REAL_OUT" = "DISABLED" ]; then
	ok "real-tree: the gate is switched off (enabled 0 in config/account-name-scope.tsv) - shown, not failed"
else
	bad "real-tree: the gate on this repository (rc=$REAL_RC, $(printf '%s\n' "$REAL_OUT" | grep -c '^VIOLATION') violations, $(printf '%s\n' "$REAL_OUT" | grep -c '^EXPIRED') expired, $(printf '%s\n' "$REAL_OUT" | grep -c '^OBSOLETE') obsolete; last line: $(printf '%s\n' "$REAL_OUT" | tail -n 1 | cut -c1-120))"
fi

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
