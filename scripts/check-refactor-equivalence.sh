#!/usr/bin/env bash
# check-refactor-equivalence.sh — gate G3 of the 2026-11-10 simplify refactor.
# CHAIN: none — local temporary directories and git worktrees only.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (nothing here can reach a chain).
#
# Proves that a refactor changed nothing observable: the same script (or the same
# test suite) is run at a base commit and at HEAD, and the results are compared.
#
# Usage:
#   bash scripts/check-refactor-equivalence.sh --base=<commit> --cases=<tsv>
#   bash scripts/check-refactor-equivalence.sh --base=<commit> --suite=<dir>
#   optional: --timeout=<seconds>  limit of each single run, digits 1..3600, default 900
#   optional, suite mode only: --markers=colon  also read `ok:` / `PASS:` (pass) and
#             `FAIL:` (fail) case lines; every suite file must have one at base
#
# Cases mode: each row of the TSV runs one script at both sides with the same
# fixture, and compares rc, stdout, stderr and the listed output files byte for byte.
# Suite mode: every executable test-*.sh directly in <dir> is run at both sides and
# only the exit code and the multiset of (status, case name) pairs are compared.
# A case line is: optional whitespace, a marker, whitespace, the name (trailing blanks
# trimmed). Markers: PASS and ✓ (pass), FAIL and ✗ (fail); with --markers=colon also
# exactly ok: or PASS: (pass) and FAIL: (fail), case-sensitive, then at least one blank.
# The base run must be green (rc 0 and no fail case line); a red base is exit 2,
# because red at both sides with the same fail cases would otherwise compare equal.
#
# Cases file: tab-separated, 6 or 7 columns, `#` lines and blank lines ignored,
# `-` means empty:
#   1 script           repo-relative path, tracked at both sides
#   2 args             space-separated words; the token {FIXTURE} becomes the fixture copy
#   3 env              space-separated KEY=VALUE; reserved keys are refused (exit 2):
#                      PATH HOME TMPDIR FY_LIVE ENV IFS CDPATH GLOBIGNORE SHELLOPTS PS4 and
#                      every key starting with BASH LD_ DYLD_ GIT_ PYTHON PERL5 G3_
#   4 fixture dir      repo-relative, taken from HEAD (same bytes for both sides)
#   5 output files     comma-separated, relative to the fixture copy
#   6 validator        ajv-stub | python | none | -
#   7 normalize        optional, comma-separated JSON keys whose string value is masked
# In args and env values any of  ' " \ $ ` ; | & < > ( )  is refused.
#
# Output (stdout): `DIFF <id> <what>` per difference, `SUITE <file> base_rc=<n>
# head_rc=<n> cases=<n>/<n>` info lines in suite mode, then `OK <n> equal` or `FAIL <k>`.
#
# Exit codes:
#   0  equal; last line `OK <n> equal`
#   1  different; DIFF lines, then `FAIL <k>`
#   2  could not run (no OK is printed): one line `check-refactor-equivalence: <reason>`
#      on stderr. Missing or bad input, git failure, malformed row, a stub that does
#      not shadow proton/ssh, zero cases, a validator that cannot be set up, a suite
#      whose base run is red (`<id>: base is red (rc=<n>, fail cases=<k>): ...`), a run
#      that exceeded --timeout (`<id>: timeout after <n>s at base|head`; the run's
#      process group gets TERM, then KILL 5 s later if anything is left), --markers
#      that is not `colon`, given twice or with --cases, or --markers=colon on a suite
#      file with no colon-form case line at base.
#
# Fail closed: every unexpected state is exit 2 or exit 1, never a quiet pass.
# Both sides run in a `git worktree add --detach` under one mktemp directory; a trap
# on EXIT, INT and TERM removes the worktree and the directory on every exit.
# Each run starts with HUP INT QUIT PIPE ALRM TERM USR1 USR2 at their default action,
# whatever G3's caller ignored, as the leader of its own process group (perl setpgrp);
# one watchdog per run, by recorded PID, stops that group on expiry, and the trap stops
# the recorded group and watchdog too. Nothing is ever signalled by name.
# curl, ssh, scp, proton and cleos are stubs: no network, no host, no broadcast.

set -Eeuo pipefail
export LC_ALL=C

g3_die() { echo "check-refactor-equivalence: $*" >&2; exit 2; }

trap 'g3_die "unexpected failure (line $LINENO)"' ERR

G3_TOP=""
G3_T=""
G3_CHILD=""
G3_WD=""
G3_CLEANED=0

g3_cleanup() {
	local rc="$1"
	trap - ERR
	[ "$G3_CLEANED" -eq 0 ] || return 0
	G3_CLEANED=1
	if [ -n "$G3_WD" ]; then
		kill -KILL "$G3_WD" 2>/dev/null || true
		wait "$G3_WD" 2>/dev/null || true
		G3_WD=""
	fi
	if [ -n "$G3_CHILD" ]; then
		kill -KILL -- "-$G3_CHILD" 2>/dev/null || true
		kill -KILL "$G3_CHILD" 2>/dev/null || true
		wait "$G3_CHILD" 2>/dev/null || true
		G3_CHILD=""
	fi
	if [ -n "$G3_T" ] && [ -d "$G3_T" ]; then
		if [ -d "$G3_T/tree" ] && [ -n "$G3_TOP" ]; then
			git -C "$G3_TOP" worktree remove --force "$G3_T/tree" >/dev/null 2>&1 || true
		fi
		chmod -R u+rwX "$G3_T" >/dev/null 2>&1 || true
		rm -rf "$G3_T"
		[ -z "$G3_TOP" ] || git -C "$G3_TOP" worktree prune >/dev/null 2>&1 || true
	fi
	return 0
}
trap 'g3_cleanup $?' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# ---- arguments ---------------------------------------------------------------------------
G3_BASE=""
G3_CASES=""
G3_SUITE=""
have_base=0
have_cases=0
have_suite=0
G3_TIMEOUT=900
have_timeout=0
G3_MARKERS=""
have_markers=0
for arg in "$@"; do
	case "$arg" in
		--base=*)
			[ "$have_base" -eq 0 ] || g3_die "--base given twice"
			have_base=1
			G3_BASE="${arg#--base=}"
			;;
		--cases=*)
			[ "$have_cases" -eq 0 ] || g3_die "--cases given twice"
			have_cases=1
			G3_CASES="${arg#--cases=}"
			;;
		--suite=*)
			[ "$have_suite" -eq 0 ] || g3_die "--suite given twice"
			have_suite=1
			G3_SUITE="${arg#--suite=}"
			;;
		--timeout=*)
			[ "$have_timeout" -eq 0 ] || g3_die "--timeout given twice"
			have_timeout=1
			G3_TIMEOUT="${arg#--timeout=}"
			case "$G3_TIMEOUT" in ''|*[!0-9]*) g3_die "--timeout must be digits only, 1..3600: $G3_TIMEOUT" ;; esac
			[ "${#G3_TIMEOUT}" -le 4 ] || g3_die "--timeout out of range 1..3600: $G3_TIMEOUT"
			G3_TIMEOUT=$((10#$G3_TIMEOUT))
			[ "$G3_TIMEOUT" -ge 1 ] && [ "$G3_TIMEOUT" -le 3600 ] || g3_die "--timeout out of range 1..3600: $G3_TIMEOUT"
			;;
		--markers=*)
			[ "$have_markers" -eq 0 ] || g3_die "--markers given twice"
			have_markers=1
			G3_MARKERS="${arg#--markers=}"
			[ "$G3_MARKERS" = "colon" ] || g3_die "unknown marker set: '$G3_MARKERS' (known: colon)"
			;;
		*) g3_die "unknown argument: $arg (usage: --base=<commit> (--cases=<tsv> | --suite=<dir> [--markers=colon]) [--timeout=<seconds>])" ;;
	esac
done
[ "$have_base" -eq 1 ] && [ -n "$G3_BASE" ] || g3_die "--base=<commit> is required"
case "$G3_BASE" in -*) g3_die "base must not start with a dash: $G3_BASE" ;; esac
if [ "$have_cases" -eq 1 ] && [ "$have_suite" -eq 1 ]; then g3_die "--cases and --suite cannot be combined"; fi
if [ "$have_cases" -eq 0 ] && [ "$have_suite" -eq 0 ]; then g3_die "one of --cases=<tsv> or --suite=<dir> is required"; fi
if [ "$have_cases" -eq 1 ] && [ -z "$G3_CASES" ]; then g3_die "--cases is empty"; fi
if [ "$have_suite" -eq 1 ] && [ -z "$G3_SUITE" ]; then g3_die "--suite is empty"; fi
if [ "$have_markers" -eq 1 ] && [ "$have_cases" -eq 1 ]; then g3_die "--markers cannot be combined with --cases"; fi

G3_PWD="$PWD"
if [ "$have_cases" -eq 1 ]; then
	case "$G3_CASES" in /*) ;; *) G3_CASES="$G3_PWD/$G3_CASES" ;; esac
	[ -f "$G3_CASES" ] && [ -r "$G3_CASES" ] || g3_die "cases file missing or unreadable: $G3_CASES"
fi

G3_TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || g3_die "not inside a git repository"
cd "$G3_TOP" || g3_die "cannot enter the repository root"
G3_BASEC="$(git rev-parse --verify --quiet "${G3_BASE}^{commit}" 2>/dev/null)" || g3_die "base is not a commit: $G3_BASE"
G3_HEADC="$(git rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null)" || g3_die "HEAD is not a commit"
G3_ORIG_PATH="$PATH"
G3_PERL="$(command -v perl 2>/dev/null)" || g3_die "perl is required"
case "$G3_PERL" in /*) ;; *) g3_die "perl is not an executable on PATH: $G3_PERL" ;; esac

# Start of a run (§16.4-1): set HUP INT QUIT PIPE ALRM TERM USR1 USR2 to their default
# action (a signal ignored by G3's caller would otherwise stay ignored in the run), become
# the leader of a new process group, leave a marker, then exec.
G3_PG_START='$SIG{$_} = "DEFAULT" for qw(HUP INT QUIT PIPE ALRM TERM USR1 USR2); my $ok = shift; setpgrp(0, 0) or exit 125; open(my $h, ">", $ok) or exit 125; close($h); exec { $ARGV[0] } @ARGV; unlink($ok); exit 126;'
# Watchdog of a run: after the limit, mark, TERM the group, KILL it 5 s later if anything is left.
G3_WATCHDOG='my ($pg, $n, $mark) = @ARGV; sleep($n); if (open(my $h, ">", $mark)) { close($h); } kill("TERM", -$pg); for (1 .. 50) { select(undef, undef, undef, 0.1); exit(3) unless kill(0, -$pg); } kill("KILL", -$pg); exit(3);'

# ---- validators of a path / name ---------------------------------------------------------
# A repo-relative path: plain characters, no leading slash or dash, no `..` segment.
g3_check_relpath() { # what value
	local what="$1" v="$2"
	[ -n "$v" ] || g3_die "$what is empty"
	case "$v" in
		/*|-*) g3_die "$what must be repo-relative: $v" ;;
		*..*) case "/$v/" in */../*) g3_die "$what must not contain '..': $v" ;; esac ;;
	esac
	if LC_ALL=C grep -q '[^A-Za-z0-9._/@+-]' <<< "$v"; then
		g3_die "$what has a character outside A-Za-z0-9._/@+-: $v"
	fi
}

# Split a comma-separated list into the array G3_LIST; an empty item is refused.
g3_split_commas() { # what value
	case "$2" in ,*|*,|*,,*) g3_die "$1: empty item in list: $2" ;; esac
	G3_LIST=()
	local IFS=,
	read -r -a G3_LIST <<< "$2"
}

g3_check_no_forbidden() { # what value
	case "$2" in
		*"'"*|*'"'*|*'\'*|*'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*)
			g3_die "$1 contains a forbidden character (one of ' \" \\ \$ \` ; | & < > ( )): $2" ;;
	esac
}

# ---- one temp directory, then the trap owns it -------------------------------------------
G3_T="$(mktemp -d "${TMPDIR:-/tmp}/g3-equiv.XXXXXX")" || g3_die "mktemp failed"
G3_T="$(cd "$G3_T" && pwd -P)" || g3_die "cannot resolve the temp directory"
mkdir -p "$G3_T/stubs" "$G3_T/res" || g3_die "cannot create work directories"
: > "$G3_T/report"
G3_DIFFS=0
G3_UNITS=0

g3_report() { printf '%s\n' "$*" >> "$G3_T/report"; }
g3_diff() { # id what
	g3_report "DIFF $1 $2"
	G3_DIFFS=$((G3_DIFFS + 1))
}

# ---- stubs -------------------------------------------------------------------------------
G3_STUB_CMDS="curl ssh scp proton cleos"
g3_make_stubs() {
	local tpl c body
	tpl='#!/bin/sh
{ printf "%s" "@CMD@"; for a in "$@"; do printf " %s" "$a"; done; printf "\n"; } >> "@T@/calls.log"
if [ -f "@T@/fx/stubs/@CMD@" ] && [ -x "@T@/fx/stubs/@CMD@" ]; then exec "@T@/fx/stubs/@CMD@" "$@"; fi
echo "g3-stub: @CMD@ not provided by the case" >&2
exit 1'
	for c in $G3_STUB_CMDS; do
		body="${tpl//@CMD@/$c}"
		body="${body//@T@/$G3_T}"
		printf '%s\n' "$body" > "$G3_T/stubs/$c"
		chmod 755 "$G3_T/stubs/$c"
	done
}
g3_make_stubs

# ---- farm: one symlink per executable name on the original PATH (first wins) -------------
g3_build_farm() { # name excluded-name-regex
	local farm="$G3_T/farm-$1"
	[ -d "$farm" ] && return 0
	mkdir "$farm"
	perl -e '
		my ($farm, $excl, $path) = @ARGV;
		my $re = qr/$excl/;
		my %seen;
		for my $d (split /:/, $path) {
			next unless length $d && $d =~ m{^/};
			opendir(my $dh, $d) or next;
			for my $n (sort readdir $dh) {
				next if $n eq "." || $n eq ".." || $seen{$n};
				my $p = "$d/$n";
				next unless -f $p && -x $p;
				$seen{$n} = 1;
				next if $n =~ $re;
				symlink($p, "$farm/$n") or die "symlink $n: $!\n";
			}
			closedir($dh);
		}
	' "$farm" "$2" "$G3_ORIG_PATH"
}

# ---- one run of one script at one side ---------------------------------------------------
# Globals read: G3_R_COMMIT G3_R_SCRIPT G3_R_FIXDIR G3_R_VALIDATOR G3_R_CWD (fx|tree)
#               G3_R_ID G3_R_SIDE (base|head; for the timeout message)
#               G3_R_ARGS (array) G3_R_ENV (array) G3_R_OUTFILES (array)
# Writes into $1: rc, stdout, stderr, files/<path>
g3_run() { # outdir
	local out="$1" t="$G3_T" runpath c expected got wdrc
	mkdir -p "$out/files"
	rm -rf "$t/tree" "$t/fx" "$t/home" "$t/tmp" "$t/calls.log" "$t/stubs/ajv" "$t/pg-started" "$t/timed-out"
	git worktree add --detach --quiet "$t/tree" "$G3_R_COMMIT" >/dev/null 2>&1 || g3_die "git worktree add failed for $G3_R_COMMIT"
	mkdir -p "$t/fx" "$t/home" "$t/tmp"
	: > "$t/calls.log"
	if [ -n "$G3_R_FIXDIR" ]; then
		git archive "$G3_HEADC:$G3_R_FIXDIR" 2>/dev/null | tar -x -C "$t/fx" || g3_die "cannot extract fixture $G3_R_FIXDIR from HEAD"
	fi

	case "$G3_R_VALIDATOR" in
		"")
			runpath="$t/stubs:$G3_ORIG_PATH" ;;
		ajv-stub)
			g3_build_farm noajv '^(ajv)$'
			git show "$G3_HEADC:tests/fixtures/ajv-stub/ajv" > "$t/stubs/ajv" 2>/dev/null || g3_die "tests/fixtures/ajv-stub/ajv is not in HEAD"
			chmod 755 "$t/stubs/ajv"
			runpath="$t/stubs:$t/farm-noajv" ;;
		python)
			g3_build_farm noajv '^(ajv)$'
			[ -x "$t/farm-noajv/python3" ] || g3_die "validator python: no python3 on PATH"
			"$t/farm-noajv/python3" -c 'import jsonschema' >/dev/null 2>&1 || g3_die "validator python: python3 cannot import jsonschema here"
			runpath="$t/stubs:$t/farm-noajv" ;;
		none)
			g3_build_farm nopy '^(ajv|python|python3|python3\..*)$'
			runpath="$t/stubs:$t/farm-nopy" ;;
		*) g3_die "internal: validator $G3_R_VALIDATOR" ;;
	esac

	# The stubs must shadow the real tools under exactly this environment.
	expected=""
	for c in $G3_STUB_CMDS; do expected="${expected}${t}/stubs/${c}"$'\n'; done
	got="$(cd "$t/fx" && env -u BASH_ENV -u ENV -u FY_LIVE -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u CDPATH -u GLOBIGNORE -u PS4 "HOME=$t/home" "TMPDIR=$t/tmp" "PATH=$runpath" \
		"$BASH" -c 'for c in curl ssh scp proton cleos; do command -v "$c" || echo "MISSING:$c"; done' </dev/null 2>/dev/null)" || g3_die "stub check could not run"
	got="${got}"$'\n'
	[ "$got" = "$expected" ] || g3_die "stubs do not shadow curl/ssh/scp/proton/cleos in the run environment"

	local cwd="$t/fx"
	[ "$G3_R_CWD" = "tree" ] && cwd="$t/tree"
	local rc=0
	(
		cd "$cwd" && exec env -u BASH_ENV -u ENV -u FY_LIVE -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u CDPATH -u GLOBIGNORE -u PS4 "HOME=$t/home" "TMPDIR=$t/tmp" "PATH=$runpath" \
			${G3_R_ENV[@]+"${G3_R_ENV[@]}"} "$G3_PERL" -e "$G3_PG_START" "$t/pg-started" "$BASH" "$t/tree/$G3_R_SCRIPT" ${G3_R_ARGS[@]+"${G3_R_ARGS[@]}"}
	) </dev/null >"$out/stdout" 2>"$out/stderr" &
	G3_CHILD=$!
	"$G3_PERL" -e "$G3_WATCHDOG" "$G3_CHILD" "$G3_TIMEOUT" "$t/timed-out" </dev/null >/dev/null 2>&1 &
	G3_WD=$!
	wait "$G3_CHILD" || rc=$?
	if [ -e "$t/timed-out" ]; then
		# expired: let the watchdog finish (TERM, then KILL 5 s later if anything is left)
		wait "$G3_WD" 2>/dev/null || true
		G3_WD=""; G3_CHILD=""
		g3_die "$G3_R_ID: timeout after ${G3_TIMEOUT}s at $G3_R_SIDE"
	fi
	wdrc=0
	kill -KILL "$G3_WD" 2>/dev/null || true
	wait "$G3_WD" 2>/dev/null || wdrc=$?
	G3_WD=""
	# a watchdog that ended on its own has fired, even if its marker could not be written
	[ "$wdrc" -eq 137 ] || g3_die "$G3_R_ID: timeout after ${G3_TIMEOUT}s at $G3_R_SIDE"
	G3_CHILD=""
	[ -e "$t/pg-started" ] || g3_die "$G3_R_ID: the run did not start in its own process group at $G3_R_SIDE (rc=$rc)"
	printf '%s\n' "$rc" > "$out/rc"

	local f
	for f in ${G3_R_OUTFILES[@]+"${G3_R_OUTFILES[@]}"}; do
		if [ -L "$t/fx/$f" ] || { [ -e "$t/fx/$f" ] && [ ! -f "$t/fx/$f" ]; }; then
			g3_die "output file is not a regular file: $f"
		fi
		if [ -f "$t/fx/$f" ]; then
			mkdir -p "$out/files/$(dirname "$f")"
			cp "$t/fx/$f" "$out/files/$f"
		fi
	done

	git -C "$G3_TOP" worktree remove --force "$t/tree" >/dev/null 2>&1 || true
	rm -rf "$t/tree"
	git -C "$G3_TOP" worktree prune >/dev/null 2>&1 || true
}

# Mask the string value of each named key, in place.
g3_normalize() { # file keys-comma-separated
	local f="$1" k prog=""
	[ -f "$f" ] || return 0
	g3_split_commas "normalize keys" "$2"
	for k in "${G3_LIST[@]}"; do
		prog="${prog}s/\"${k}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"${k}\":\"<NORMALIZED>\"/g;"
	done
	perl -0777 -i -pe "$prog" "$f"
}

# ---- cases mode --------------------------------------------------------------------------
ROW_LINE=(); ROW_SCRIPT=(); ROW_ARGS=(); ROW_ENV=(); ROW_FIX=(); ROW_OUT=(); ROW_VAL=(); ROW_NORM=()

g3_load_cases() {
	local lineno=0 line tabs rest f i
	local -a cols
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		case "$line" in ''|'#'*) continue ;; esac
		case "$line" in *$'\r'*) g3_die "line $lineno: carriage return in row" ;; esac
		tabs="${line//[^$'\t']/}"
		case "${#tabs}" in
			5|6) ;;
			*) g3_die "line $lineno: expected 6 or 7 tab-separated columns, found $((${#tabs} + 1))" ;;
		esac
		cols=()
		rest="$line"
		i=0
		while [ "$i" -le "${#tabs}" ]; do
			case "$rest" in
				*$'\t'*) f="${rest%%$'\t'*}"; rest="${rest#*$'\t'}" ;;
				*) f="$rest"; rest="" ;;
			esac
			[ -n "$f" ] || g3_die "line $lineno: column $((i + 1)) is empty (use - for empty)"
			cols[$i]="$f"
			i=$((i + 1))
		done
		ROW_LINE[${#ROW_LINE[@]}]="$lineno"
		ROW_SCRIPT[${#ROW_SCRIPT[@]}]="${cols[0]}"
		ROW_ARGS[${#ROW_ARGS[@]}]="${cols[1]}"
		ROW_ENV[${#ROW_ENV[@]}]="${cols[2]}"
		ROW_FIX[${#ROW_FIX[@]}]="${cols[3]}"
		ROW_OUT[${#ROW_OUT[@]}]="${cols[4]}"
		ROW_VAL[${#ROW_VAL[@]}]="${cols[5]}"
		ROW_NORM[${#ROW_NORM[@]}]="${cols[6]:--}"
	done < "$G3_CASES"
	[ "${#ROW_LINE[@]}" -gt 0 ] || g3_die "no case rows in $G3_CASES"
}

g3_blob_at() { # commit path -> 0 if a tracked file
	[ "$(git cat-file -t "$1:$2" 2>/dev/null)" = "blob" ]
}

g3_validate_rows() {
	local n="${#ROW_LINE[@]}" i l w k v
	for ((i = 0; i < n; i++)); do
		l="line ${ROW_LINE[$i]}"
		g3_check_relpath "$l: script" "${ROW_SCRIPT[$i]}"
		g3_blob_at "$G3_BASEC" "${ROW_SCRIPT[$i]}" || g3_die "$l: script is not tracked at base: ${ROW_SCRIPT[$i]}"
		g3_blob_at "$G3_HEADC" "${ROW_SCRIPT[$i]}" || g3_die "$l: script is not tracked at HEAD: ${ROW_SCRIPT[$i]}"
		if [ "${ROW_ARGS[$i]}" != "-" ]; then g3_check_no_forbidden "$l: args" "${ROW_ARGS[$i]}"; fi
		if [ "${ROW_ENV[$i]}" != "-" ]; then
			set -f
			for w in ${ROW_ENV[$i]}; do
				case "$w" in *=*) ;; *) g3_die "$l: env word without '=': $w" ;; esac
				k="${w%%=*}"; v="${w#*=}"
				LC_ALL=C grep -Eq '^[A-Z_][A-Z0-9_]*$' <<< "$k" || g3_die "$l: bad env key: $k"
				# §15.5: keys that could run something other than the script, change which
				# program answers, swap the validator's module or point git elsewhere
				case "$k" in
					PATH|HOME|TMPDIR|FY_LIVE|ENV|IFS|CDPATH|GLOBIGNORE|SHELLOPTS|PS4) g3_die "$l: env key $k is reserved" ;;
					BASH*|LD_*|DYLD_*|GIT_*|PYTHON*|PERL5*|G3_*) g3_die "$l: env key $k is reserved" ;;
				esac
				g3_check_no_forbidden "$l: env value" "$v"
			done
			set +f
		fi
		if [ "${ROW_FIX[$i]}" != "-" ]; then
			g3_check_relpath "$l: fixture dir" "${ROW_FIX[$i]}"
			[ "$(git cat-file -t "$G3_HEADC:${ROW_FIX[$i]}" 2>/dev/null)" = "tree" ] || g3_die "$l: fixture dir is not in HEAD: ${ROW_FIX[$i]}"
		fi
		if [ "${ROW_OUT[$i]}" != "-" ]; then
			g3_split_commas "$l: output files" "${ROW_OUT[$i]}"
			for w in "${G3_LIST[@]}"; do g3_check_relpath "$l: output file" "$w"; done
		fi
		case "${ROW_VAL[$i]}" in
			ajv-stub|python|none|-) ;;
			*) g3_die "$l: unknown validator: ${ROW_VAL[$i]}" ;;
		esac
		if [ "${ROW_NORM[$i]}" != "-" ]; then
			g3_split_commas "$l: normalize keys" "${ROW_NORM[$i]}"
			for w in "${G3_LIST[@]}"; do
				LC_ALL=C grep -Eq '^[A-Za-z0-9_]+$' <<< "$w" || g3_die "$l: bad normalize key: $w"
			done
		fi
	done
}

g3_split_row() { # index -> G3_R_* for one side (commit set by the caller)
	local i="$1" w fx="$G3_T/fx"
	G3_R_SCRIPT="${ROW_SCRIPT[$i]}"
	G3_R_FIXDIR=""; [ "${ROW_FIX[$i]}" = "-" ] || G3_R_FIXDIR="${ROW_FIX[$i]}"
	G3_R_VALIDATOR=""; [ "${ROW_VAL[$i]}" = "-" ] || G3_R_VALIDATOR="${ROW_VAL[$i]}"
	G3_R_CWD="fx"
	G3_R_ARGS=(); G3_R_ENV=(); G3_R_OUTFILES=()
	set -f
	if [ "${ROW_ARGS[$i]}" != "-" ]; then
		for w in ${ROW_ARGS[$i]}; do G3_R_ARGS[${#G3_R_ARGS[@]}]="${w//\{FIXTURE\}/$fx}"; done
	fi
	if [ "${ROW_ENV[$i]}" != "-" ]; then
		for w in ${ROW_ENV[$i]}; do G3_R_ENV[${#G3_R_ENV[@]}]="${w//\{FIXTURE\}/$fx}"; done
	fi
	set +f
	if [ "${ROW_OUT[$i]}" != "-" ]; then
		g3_split_commas "output files" "${ROW_OUT[$i]}"
		G3_R_OUTFILES=("${G3_LIST[@]}")
	fi
}

g3_compare_file() { # id what base-file head-file
	if cmp -s "$3" "$4"; then return 0; fi
	g3_diff "$1" "$2"
}

g3_cases_mode() {
	g3_load_cases
	g3_validate_rows
	local n="${#ROW_LINE[@]}" i id f before
	local -a outs
	local B="$G3_T/res/base" H="$G3_T/res/head"
	for ((i = 0; i < n; i++)); do
		id="L${ROW_LINE[$i]}"
		before=$G3_DIFFS
		rm -rf "$B" "$H"
		g3_split_row "$i"
		G3_R_ID="$id"
		G3_R_COMMIT="$G3_BASEC"; G3_R_SIDE=base; g3_run "$B"
		G3_R_COMMIT="$G3_HEADC"; G3_R_SIDE=head; g3_run "$H"

		if [ "${ROW_NORM[$i]}" != "-" ]; then
			g3_normalize "$B/stdout" "${ROW_NORM[$i]}"; g3_normalize "$H/stdout" "${ROW_NORM[$i]}"
			g3_normalize "$B/stderr" "${ROW_NORM[$i]}"; g3_normalize "$H/stderr" "${ROW_NORM[$i]}"
		fi
		g3_compare_file "$id" rc "$B/rc" "$H/rc"
		g3_compare_file "$id" stdout "$B/stdout" "$H/stdout"
		g3_compare_file "$id" stderr "$B/stderr" "$H/stderr"
		outs=()
		if [ "${ROW_OUT[$i]}" != "-" ]; then
			g3_split_commas "output files" "${ROW_OUT[$i]}"
			outs=("${G3_LIST[@]}")
		fi
		for f in ${outs[@]+"${outs[@]}"}; do
			if [ ! -f "$B/files/$f" ] && [ ! -f "$H/files/$f" ]; then
				g3_die "line ${ROW_LINE[$i]}: output file absent on both sides: $f"
			elif [ ! -f "$B/files/$f" ] || [ ! -f "$H/files/$f" ]; then
				g3_diff "$id" "file-presence:$f"
			else
				if [ "${ROW_NORM[$i]}" != "-" ]; then
					g3_normalize "$B/files/$f" "${ROW_NORM[$i]}"; g3_normalize "$H/files/$f" "${ROW_NORM[$i]}"
				fi
				g3_compare_file "$id" "file:$f" "$B/files/$f" "$H/files/$f"
			fi
		done
		[ "$G3_DIFFS" -ne "$before" ] || G3_UNITS=$((G3_UNITS + 1))
	done
}

# ---- suite mode --------------------------------------------------------------------------
g3_list_suites() { # commit dir -> sorted file names (basename) of executable test-*.sh
	local entry meta path mode name
	git ls-tree -z "$1" "$2/" 2>/dev/null | {
		while IFS= read -r -d '' entry; do
			meta="${entry%%$'\t'*}"; path="${entry#*$'\t'}"
			mode="${meta%% *}"
			name="${path##*/}"
			[ "${path%/*}" = "$2" ] || continue
			case "$name" in test-*.sh) ;; *) continue ;; esac
			[ "$mode" = "100755" ] || continue
			case "$meta" in *" blob "*) ;; *) continue ;; esac
			if LC_ALL=C grep -q '[^A-Za-z0-9._+-]' <<< "$name"; then
				echo "check-refactor-equivalence: unsupported suite file name: $name" >&2
				exit 3
			fi
			printf '%s\n' "$name"
		done
	} | LC_ALL=C sort
}

g3_extract_cases() { # stdout-file stderr-file colon-count-file -> "status<TAB>name" lines on stdout
	local re='^[[:space:]]*(PASS|FAIL|✓|✗)[[:space:]]+(.+)$' line st name
	local rec='^[[:space:]]*(ok:|PASS:|FAIL:)[[:space:]]+(.+)$' ncolon=0
	while IFS= read -r line || [ -n "$line" ]; do
		if [[ $line =~ $re ]]; then
			:
		elif [ "$G3_MARKERS" = "colon" ] && [[ $line =~ $rec ]]; then
			:
		else
			continue
		fi
		st="${BASH_REMATCH[1]}"
		name="${BASH_REMATCH[2]}"
		name="${name%"${name##*[![:space:]]}"}"
		[ -n "$name" ] || continue
		case "$st" in
			PASS|✓) st=pass ;;
			FAIL|✗) st=fail ;;
			ok:|PASS:) st=pass; ncolon=$((ncolon + 1)) ;;
			FAIL:) st=fail; ncolon=$((ncolon + 1)) ;;
			*) st=fail ;;
		esac
		printf '%s\t%s\n' "$st" "$name"
	done < <(cat "$1" "$2")
	printf '%s\n' "$ncolon" > "$3"
}

g3_suite_mode() {
	local dir="$G3_SUITE" bl hl f st nm
	dir="${dir%/}"
	g3_check_relpath "suite dir" "$dir"
	bl="$G3_T/suites-base"; hl="$G3_T/suites-head"
	g3_list_suites "$G3_BASEC" "$dir" > "$bl" || g3_die "cannot list suites at base"
	g3_list_suites "$G3_HEADC" "$dir" > "$hl" || g3_die "cannot list suites at HEAD"
	[ -s "$bl" ] || g3_die "no executable test-*.sh in $dir at base"
	[ -s "$hl" ] || g3_die "no executable test-*.sh in $dir at HEAD"

	local B="$G3_T/res/base" H="$G3_T/res/head" id before bc hc brc hrc bf
	G3_R_ARGS=(); G3_R_ENV=(); G3_R_OUTFILES=(); G3_R_FIXDIR=""; G3_R_VALIDATOR=""; G3_R_CWD="tree"
	# files at one side only
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		id="$dir/$f"
		if ! grep -qxF -- "$f" "$hl"; then g3_diff "$id" "only-at-base"; fi
	done < "$bl"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		id="$dir/$f"
		if ! grep -qxF -- "$f" "$bl"; then g3_diff "$id" "only-at-head"; fi
	done < "$hl"
	# files at both sides
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		grep -qxF -- "$f" "$hl" || continue
		id="$dir/$f"
		before=$G3_DIFFS
		rm -rf "$B" "$H"
		G3_R_SCRIPT="$id"
		G3_R_ID="$id"
		G3_R_COMMIT="$G3_BASEC"; G3_R_SIDE=base; g3_run "$B"
		g3_extract_cases "$B/stdout" "$B/stderr" "$B/ncolon" | LC_ALL=C sort > "$B/cases"
		# §15.2 kind M: --markers=colon must be needed by every suite file it is used on
		if [ "$G3_MARKERS" = "colon" ] && [ "$(cat "$B/ncolon")" = "0" ]; then
			g3_die "$id: --markers=colon but no colon-form case line at base"
		fi
		# §15.3: a red base proves nothing (red at both sides would compare equal).
		brc="$(cat "$B/rc")"
		bf="$(grep -c '^fail'$'\t' "$B/cases" || true)"
		if [ "$brc" != "0" ] || [ "$bf" != "0" ]; then
			g3_die "$id: base is red (rc=$brc, fail cases=$bf): cannot prove equivalence"
		fi
		G3_R_COMMIT="$G3_HEADC"; G3_R_SIDE=head; g3_run "$H"
		g3_extract_cases "$H/stdout" "$H/stderr" "$H/ncolon" | LC_ALL=C sort > "$H/cases"
		bc="$(wc -l < "$B/cases" | tr -d ' ')"; hc="$(wc -l < "$H/cases" | tr -d ' ')"
		[ "$bc" -gt 0 ] || g3_die "$id: no case lines at base (cannot compare)"
		[ "$hc" -gt 0 ] || g3_die "$id: no case lines at HEAD (cannot compare)"
		brc="$(cat "$B/rc")"; hrc="$(cat "$H/rc")"
		g3_report "SUITE $id base_rc=$brc head_rc=$hrc cases=$bc/$hc"
		[ "$brc" = "$hrc" ] || g3_diff "$id" rc
		if ! cmp -s "$B/cases" "$H/cases"; then
			while IFS=$'\t' read -r st nm; do g3_diff "$id" "case-only-at-base $st:$nm"; done < <(LC_ALL=C comm -23 "$B/cases" "$H/cases")
			while IFS=$'\t' read -r st nm; do g3_diff "$id" "case-only-at-head $st:$nm"; done < <(LC_ALL=C comm -13 "$B/cases" "$H/cases")
		fi
		[ "$G3_DIFFS" -ne "$before" ] || G3_UNITS=$((G3_UNITS + 1))
	done < "$bl"
}

# ---- main --------------------------------------------------------------------------------
if [ "$have_cases" -eq 1 ]; then
	g3_cases_mode
else
	g3_suite_mode
fi

cat "$G3_T/report"
if [ "$G3_DIFFS" -gt 0 ]; then
	echo "FAIL $G3_DIFFS"
	exit 1
fi
echo "OK $G3_UNITS equal"
exit 0
