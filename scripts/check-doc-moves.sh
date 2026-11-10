#!/usr/bin/env bash
# check-doc-moves.sh — gate G1 of the 2026-11-10 simplify refactor.
#
# After documents are moved (git mv) or scripts are deleted, no live file may
# still name the old path, and a move under docs/ or scripts/ must be
# byte-identical (rename similarity 100).
#
# Usage:
#   bash scripts/check-doc-moves.sh --base=<commit>
#
# Reads `git diff --name-status -M <base> HEAD` of the repository in the current
# directory, and searches the tracked files outside a fixed exempt set.
#
# Exit codes:
#   0  no violation; last line `OK <n> moves` (n = number of renames)
#   1  one `VIOLATION <file>:<line> <old> -> <new>` line per violation, then `FAIL <k>`
#   2  refused to judge (no OK is printed): missing/empty --base, unknown argument,
#      git error (bad base, not a repository), unreadable file, or a diff status
#      letter other than A, M, D, R
#
# Fail closed: every unexpected state is exit 2 or exit 1, never a quiet pass.
# A line that names the old basename is clean only when EVERY occurrence of it is
# part of the full new path (a relative link, an old path, or a mixed line is a
# violation).
#
# Exempt set (fixed here, not a parameter): docs/audits/**, docs/archive/**,
# docs/CYCLE_GATE_DAILY_OBSERVATION.md, and files directly under
# docs/superpowers/specs/ or docs/superpowers/plans/ whose name contains
# `simplify-refactor`.
#
# CHAIN: none — reads git only; touches no host, no network, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.

set -euo pipefail
export LC_ALL=C

die() { echo "check-doc-moves: $*" >&2; exit 2; }

BASE=""
BASE_SET=0
for arg in "$@"; do
	case "$arg" in
		--base=*)
			[ "$BASE_SET" -eq 0 ] || die "--base given twice"
			BASE_SET=1
			BASE="${arg#--base=}"
			;;
		*) die "unknown argument: $arg (usage: --base=<commit>)" ;;
	esac
done
[ "$BASE_SET" -eq 1 ] && [ -n "$BASE" ] || die "--base=<commit> is required"

TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$TOP" || die "cannot enter the repository root"
git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1 || die "base is not a commit: $BASE"

TMP="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

git diff --name-status -M -z "$BASE" HEAD > "$TMP/diff" 2>"$TMP/diff.err" || die "git diff failed: $(head -n 1 "$TMP/diff.err")"

is_exempt() {
	case "$1" in
		docs/audits/*|docs/archive/*|docs/CYCLE_GATE_DAILY_OBSERVATION.md) return 0 ;;
		docs/superpowers/specs/*simplify-refactor*|docs/superpowers/plans/*simplify-refactor*)
			local rest="${1#docs/superpowers/*/}"
			case "$rest" in */*) return 1 ;; *) return 0 ;; esac
			;;
	esac
	return 1
}

plain_name() { # tab and newline would break the rules file: refuse rather than guess
	case "$1" in
		*$'\t'*|*$'\n'*) die "path with a tab or newline is not supported: $1" ;;
	esac
}

VIOL="$TMP/violations"
RULES="$TMP/rules"
: > "$VIOL"
: > "$RULES"
MOVES=0

TOKENS=()
while IFS= read -r -d '' tok; do TOKENS+=("$tok"); done < "$TMP/diff"

i=0
n=${#TOKENS[@]}
while [ "$i" -lt "$n" ]; do
	status="${TOKENS[$i]}"
	letter="${status:0:1}"
	case "$letter" in
		R)
			[ $((i + 2)) -lt "$n" ] || die "truncated rename record in git diff output"
			old="${TOKENS[$((i + 1))]}"
			new="${TOKENS[$((i + 2))]}"
			i=$((i + 3))
			plain_name "$old"; plain_name "$new"
			sim="${status:1}"
			case "$sim" in ''|*[!0-9]*) die "bad similarity in status: $status" ;; esac
			MOVES=$((MOVES + 1))
			case "$old" in docs/*|scripts/*) under=1 ;; *) case "$new" in docs/*|scripts/*) under=1 ;; *) under=0 ;; esac ;; esac
			if [ "$under" -eq 1 ] && [ "$((10#$sim))" -lt 100 ]; then
				echo "VIOLATION ${new}:0 ${old} -> ${new} similarity $((10#$sim))" >> "$VIOL"
			fi
			printf 'M\t%s\t%s\t%s\n' "${old##*/}" "$new" "$old" >> "$RULES"
			;;
		D)
			[ $((i + 1)) -lt "$n" ] || die "truncated delete record in git diff output"
			old="${TOKENS[$((i + 1))]}"
			i=$((i + 2))
			plain_name "$old"
			case "$old" in
				docs/*) echo "VIOLATION ${old}:0 ${old} -> (deleted)" >> "$VIOL" ;;
			esac
			case "$old" in
				scripts/*) printf 'D\t%s\t\t%s\n' "$old" "$old" >> "$RULES" ;;
			esac
			;;
		A|M)
			[ $((i + 1)) -lt "$n" ] || die "truncated record in git diff output"
			i=$((i + 2))
			;;
		*) die "unexpected diff status letter: $status" ;;
	esac
done

if [ -s "$RULES" ]; then
	git ls-files -z > "$TMP/tracked" 2>"$TMP/ls.err" || die "git ls-files failed: $(head -n 1 "$TMP/ls.err")"
	: > "$TMP/scan"
	while IFS= read -r -d '' f; do
		is_exempt "$f" && continue
		plain_name "$f"
		[ -f "$f" ] && [ -r "$f" ] || die "cannot read tracked file: $f"
		printf './%s\0' "$f" >> "$TMP/scan"
	done < "$TMP/tracked"

	if [ -s "$TMP/scan" ]; then
		AWK_PROG='
BEGIN {
	n = 0
	while ((getline line < rules) > 0) {
		split(line, a, "\t")
		kind[n] = a[1]; needle[n] = a[2]; newp[n] = a[3]; oldp[n] = a[4]; n++
	}
	close(rules)
}
{
	for (r = 0; r < n; r++) {
		if (index($0, needle[r]) == 0) continue
		if (kind[r] == "D") { hit = 1 }
		else {
			# positions of the full new path on this line
			np = 0; s = $0; off = 0
			while ((k = index(s, newp[r])) > 0) { ns[np] = off + k; ne[np] = off + k + length(newp[r]) - 1; np++; off += k; s = substr(s, k + 1) }
			hit = 0; s = $0; off = 0
			while ((k = index(s, needle[r])) > 0) {
				st = off + k; en = st + length(needle[r]) - 1
				cov = 0
				for (q = 0; q < np; q++) if (ns[q] <= st && ne[q] >= en) cov = 1
				if (!cov) hit = 1
				off += k; s = substr(s, k + 1)
			}
		}
		if (hit) {
			f = FILENAME; sub(/^\.\//, "", f)
			printf "VIOLATION %s:%d %s -> %s\n", f, FNR, oldp[r], (kind[r] == "D" ? "(deleted)" : newp[r])
		}
		hit = 0
	}
}'
		xargs -0 -n 200 awk -v rules="$RULES" "$AWK_PROG" < "$TMP/scan" >> "$VIOL" 2>"$TMP/awk.err" || die "search failed: $(head -n 1 "$TMP/awk.err")"
	fi
fi

if [ -s "$VIOL" ]; then
	sort -u "$VIOL" > "$TMP/violations.sorted"
	cat "$TMP/violations.sorted"
	echo "FAIL $(wc -l < "$TMP/violations.sorted" | tr -d ' ')"
	exit 1
fi
echo "OK ${MOVES} moves"
