#!/usr/bin/env bash
# check-duplicate-functions.sh — gate G2 of the 2026-11-10 simplify refactor.
# CHAIN: none — reads git and files only; touches no host, no network, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# A function name defined in two or more shell scripts is allowed only when every
# definition is a thin wrapper around a library function, or when a row in
# scripts/duplicate-functions.allow says why that copy stays. This keeps removed
# copies from coming back.
#
# Usage:
#   bash scripts/check-duplicate-functions.sh        (no arguments)
#
# Scans, in the repository of the current directory: every tracked *.sh under
# scripts/ and bin/, plus each tracked bin/ file whose first line is a shebang
# naming bash or sh (/bin/bash, /bin/sh, /usr/bin/env bash, /usr/bin/env sh).
# Files under scripts/lib/ are the library files.
#
# A definition is a non-comment line `NAME()` (optionally after `function`) or
# `function NAME {`. Heredoc text is not excluded.
#
# A definition is a wrapper only when ALL of these hold, otherwise it is a copy:
#   1. its body is exactly one line that is not blank or a comment (the one-line
#      form `NAME() { CMD; }` is one line; the multi-line form ends at the first
#      later line that is `}` alone at the definition's indentation; no such
#      line, a `(` subshell body, or `{` on the next line is not a wrapper);
#   2. that line's first word is a function defined in a library file;
#   3. the same file has, on a non-comment line, the literal
#      `scripts/lib/<that library file's basename>` with a character outside
#      [A-Za-z0-9._-] (or the line's start or end) on both sides.
#
# Output (stdout) and exit codes:
#   COPY <name> <file>      a copy of a duplicated name outside scripts/lib/ with no row
#   LIBDUP <name> <file>    a library name defined outside scripts/lib/ (wrapper or
#                           not; no row excuses it), or in two library files
#   OBSOLETE <name> <file>  a row that is not a non-wrapper definition of a duplicated name
#   exit 0  `OK <n> names <m> rows` (n = duplicated names, m = allowlist rows)
#   exit 1  the lines above (sorted), then `FAIL <k>`
#   exit 2  refused to judge: one line `check-duplicate-functions: <reason>` on
#           stderr and no `OK` — an argument, not a git repository, a git failure,
#           a missing/unreadable allowlist or scanned file, or a malformed row
#
# Fail closed: every unexpected state is exit 2 or exit 1, never a quiet pass.
#
# Allowlist: scripts/duplicate-functions.allow, TSV `name<TAB>file<TAB>reason`;
# `#` comment lines and blank lines are ignored.
#
# Where it connects: run by hand or by a runner; reads git and the work tree only.
# How to remove it: delete this file, the allowlist and tests/check-duplicate-functions/;
# nothing else refers to them.

set -euo pipefail
export LC_ALL=C

g2_die() { echo "check-duplicate-functions: $*" >&2; exit 2; }

[ "$#" -eq 0 ] || g2_die "no arguments are accepted (got: $1)"

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || g2_die "not inside a git repository"
cd "$TOP" || g2_die "cannot enter the repository root"

ALLOW="scripts/duplicate-functions.allow"
[ -f "$ALLOW" ] && [ -r "$ALLOW" ] || g2_die "allowlist missing or unreadable: $ALLOW"

TMP="$(mktemp -d)" || g2_die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

git ls-files -z -- scripts bin > "$TMP/tracked" 2>"$TMP/ls.err" || g2_die "git ls-files failed: $(head -n 1 "$TMP/ls.err")"

: > "$TMP/files"
while IFS= read -r -d '' f; do
	case "$f" in
		*$'\t'*|*$'\n'*) g2_die "path with a tab or newline is not supported: $f" ;;
	esac
	scan=0
	case "$f" in
		*.sh) scan=1 ;;
		bin/*)
			[ -f "$f" ] && [ -r "$f" ] || g2_die "cannot read tracked file: $f"
			first=""
			IFS= read -r first < "$f" || true
			if printf '%s\n' "$first" | grep -Eq '^#![[:space:]]*(/bin/bash|/bin/sh|/usr/bin/env[[:space:]]+(bash|sh))([[:space:]]|$)'; then scan=1; fi
			;;
	esac
	[ "$scan" -eq 1 ] || continue
	[ -f "$f" ] && [ -r "$f" ] || g2_die "cannot read tracked file: $f"
	printf '%s\n' "$f" >> "$TMP/files"
done < "$TMP/tracked"

read -r -d '' AWK_PROG <<'AWKEOF' || true
function fatal(msg) { print msg > "/dev/stderr"; exit 2 }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function is_blank_or_comment(s,   t) { t = s; sub(/^[ \t]+/, "", t); return (t == "" || substr(t, 1, 1) == "#") }
function basename(p,   k) { k = p; sub(/^.*\//, "", k); return k }
function first_word(s,   t) {
	t = s; sub(/^[ \t]+/, "", t)
	if (match(t, /^[^ \t;&|()<>]+/)) return substr(t, 1, RLENGTH)
	return ""
}
function addv(v) { if (!(v in vseen)) { vseen[v] = 1; vlist[++nv] = v } }

# has_literal: does file fi have `lit` on a non-comment line, bounded on both sides?
function has_literal(fi, lit,   i, s, p, pos, off, rest, before, after) {
	for (i = 1; i <= N[fi]; i++) {
		s = L[fi, i]
		if (is_blank_or_comment(s)) continue
		off = 0
		rest = s
		while ((p = index(rest, lit)) > 0) {
			pos = off + p
			before = (pos == 1) ? "" : substr(s, pos - 1, 1)
			after = substr(s, pos + length(lit), 1)
			if (!(before ~ /[A-Za-z0-9._-]/) && !(after ~ /[A-Za-z0-9._-]/)) return 1
			off = pos
			rest = substr(s, off + 1)
		}
	}
	return 0
}

# wrap_fw: condition 1. Returns the first word of the single body line, or "" when
# the definition has no one-line body of the allowed shapes.
function wrap_fw(fi, i, ind, rest,   a, j, cnt, fw, ln, body) {
	rest = trim(rest)
	if (substr(rest, 1, 1) != "{") return ""
	a = trim(substr(rest, 2))
	if (a == "" || substr(a, 1, 1) == "#") {
		cnt = 0; fw = ""
		for (j = i + 1; j <= N[fi]; j++) {
			ln = L[fi, j]; sub(/[ \t]+$/, "", ln)
			if (ln == (ind "}")) return (cnt == 1) ? fw : ""
			if (is_blank_or_comment(ln)) continue
			cnt++
			if (cnt == 1) fw = first_word(ln)
		}
		return ""
	}
	if (substr(a, length(a), 1) != "}") return ""
	body = trim(substr(a, 1, length(a) - 1))
	sub(/;[ \t]*$/, "", body)
	body = trim(body)
	if (body == "" || substr(body, 1, 1) == "#") return ""
	return first_word(body)
}

# is_wrapper: all three conditions for definition d.
function is_wrapper(d,   c1, c2, c3, fw, k) {
	fw = dfw[d]
	c1 = (fw != "")
	c2 = (fw != "" && (fw in libcount))
	c3 = 0
	if (c2) {
		for (k = 1; k <= libcount[fw]; k++)
			if (has_literal(dfi[d], "scripts/lib/" basename(libfile[fw, k]))) c3 = 1
	}
	return (c1 && c2 && c3)
}

# row_err: why a non-comment allowlist line is malformed, or "".
function row_err(line,   n) {
	n = split(line, ra, "\t")
	if (n != 3) return "needs exactly 3 tab-separated fields"
	if (trim(ra[1]) == "" || trim(ra[2]) == "" || trim(ra[3]) == "") return "has an empty field"
	if (ra[1] !~ /^[A-Za-z_][A-Za-z0-9_]*$/) return "name is not a function name"
	if (ra[2] !~ /^(scripts|bin)\//) return "file is not under scripts/ or bin/"
	if ((ra[1] SUBSEP ra[2]) in row) return "the same (name, file) twice"
	return ""
}

function main(   rc, line, fi, i, n, s, t, hasfn, nm, u, rest, ind, d, key, k, e, r, ok, c, j, v, lineno, nrows, nf, m) {
	nf = 0
	while ((rc = (getline line < LIST)) > 0) files[++nf] = line
	if (rc < 0) fatal("cannot read the file list")
	close(LIST)

	nd = 0
	for (fi = 1; fi <= nf; fi++) {
		islib[fi] = (substr(files[fi], 1, 12) == "scripts/lib/")
		n = 0
		while ((rc = (getline line < files[fi])) > 0) { n++; L[fi, n] = line }
		if (rc < 0) fatal("cannot read " files[fi])
		close(files[fi])
		N[fi] = n
		for (i = 1; i <= n; i++) {
			s = L[fi, i]
			if (is_blank_or_comment(s)) continue
			t = s; sub(/^[ \t]+/, "", t)
			hasfn = 0
			if (match(t, /^function[ \t]+/)) { t = substr(t, RLENGTH + 1); hasfn = 1 }
			if (!match(t, /^[A-Za-z_][A-Za-z0-9_]*/)) continue
			nm = substr(t, 1, RLENGTH)
			u = substr(t, RLENGTH + 1); sub(/^[ \t]*/, "", u)
			if (substr(u, 1, 2) == "()") rest = substr(u, 3)
			else if (hasfn && substr(u, 1, 1) == "{") rest = u
			else continue
			match(s, /^[ \t]*/); ind = substr(s, 1, RLENGTH)
			nd++
			dname[nd] = nm; dfile[nd] = files[fi]; dfi[nd] = fi
			dfw[nd] = wrap_fw(fi, i, ind, rest)
		}
	}

	# per name: in how many files, and in which library files
	for (d = 1; d <= nd; d++) {
		key = dname[d] SUBSEP dfile[d]
		if (key in seen) continue
		seen[key] = 1
		fcount[dname[d]]++
		if (islib[dfi[d]]) { libcount[dname[d]]++; libfile[dname[d], libcount[dname[d]]] = dfile[d] }
	}

	# the allowlist
	nrows = 0; lineno = 0
	while ((rc = (getline line < ALLOW)) > 0) {
		lineno++
		if (is_blank_or_comment(line)) continue
		e = row_err(line)
		if (e != "") fatal("allowlist line " lineno ": " e)
		row[ra[1] SUBSEP ra[2]] = 1
		rname[++nrows] = ra[1]; rfile[nrows] = ra[2]
	}
	if (rc < 0) fatal("cannot read the allowlist")
	close(ALLOW)

	nv = 0
	for (nm in libcount)
		if (libcount[nm] >= 2)
			for (k = 1; k <= libcount[nm]; k++) addv("LIBDUP " nm " " libfile[nm, k])
	for (d = 1; d <= nd; d++) {
		if (islib[dfi[d]]) continue
		nm = dname[d]
		if (nm in libcount) addv("LIBDUP " nm " " dfile[d])
		if (fcount[nm] >= 2 && !is_wrapper(d) && !((nm SUBSEP dfile[d]) in row)) addv("COPY " nm " " dfile[d])
	}
	for (r = 1; r <= nrows; r++) {
		ok = 0
		if (fcount[rname[r]] >= 2)
			for (d = 1; d <= nd; d++)
				if (dname[d] == rname[r] && dfile[d] == rfile[r] && !is_wrapper(d)) ok = 1
		if (!ok) addv("OBSOLETE " rname[r] " " rfile[r])
	}

	c = 0
	for (nm in fcount) if (fcount[nm] >= 2) c++

	for (i = 2; i <= nv; i++) {
		v = vlist[i]; j = i - 1
		while (j >= 1 && vlist[j] > v) { vlist[j + 1] = vlist[j]; j-- }
		vlist[j + 1] = v
	}
	if (nv > 0) {
		for (i = 1; i <= nv; i++) print vlist[i]
		print "FAIL " nv
		exit 1
	}
	print "OK " c " names " nrows " rows"
	exit 0
}
BEGIN { main() }
AWKEOF

rc=0
awk -v LIST="$TMP/files" -v ALLOW="$ALLOW" "$AWK_PROG" > "$TMP/out" 2> "$TMP/awk.err" < /dev/null || rc=$?
case "$rc" in
	0|1) cat "$TMP/out"; exit "$rc" ;;
	*) g2_die "$(head -n 1 "$TMP/awk.err")" ;;
esac
