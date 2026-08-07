#!/usr/bin/env bash
# render-publication.sh — render (or extract) the files derived from
# deploy/publication.json.
#
# CHAIN: none. PRIME_DIRECTIVE: safe — reads local files, writes only stdout.
# No network, no SSH, no broadcast, no push, no write to any tracked file.
#
# ---------------------------------------------------------------------------
# WHAT THIS DOES AND DOES NOT DO (read before trusting it)
# ---------------------------------------------------------------------------
# It prints to stdout. It never edits a file. As of C1 Phase 0 nothing in the
# deploy path or the push path consumes its output: deploy/feed-excludes.txt,
# .gitignore and scripts/push-to-web-host.sh are still hand-maintained and are
# still what actually runs. The only thing this script buys today is that
# tests/publication-registry/ can prove those three regions are reproducible
# from deploy/publication.json, and go red when they stop being.
#
# So: a hand edit to one of the target files that is not mirrored in the
# registry is DETECTED, not PREVENTED. Turning the consumers around to read
# the registry is C1 Phase 1.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   render-publication.sh <artifact> [--as-built]
#   render-publication.sh --extract <artifact>
#   render-publication.sh --check <artifact> [--as-built]
#
#   <artifact> ∈ feed-excludes | gitignore-block | push-allowlist-doc
#                | push-allowlist-case
#
#   (default)    render the artifact from the registry, canonically.
#   --as-built   render it the way the target file is CURRENTLY written, by
#                applying deploy/publication.json's known_render_drift. Only
#                push-allowlist-doc currently has drift; for every other
#                artifact --as-built is identical to the canonical render.
#                This flag exists so the drift is a declared, expiring fact
#                instead of a silently-tolerated difference.
#   --extract    print the region as it exists in the target file right now.
#   --check      diff the render against the extract; exit 0 on byte equality,
#                1 otherwise (the diff goes to stderr).
#
# Environment:
#   FYD_PUBLICATION_FILE   registry path (default: deploy/publication.json).
#                          Exists so tests can point it at a mutated copy.
#   FYD_REPO_ROOT          repo root for resolving target_file (default: the
#                          repo this script lives in).
#
# Requires jq. There is no fallback: rendering a byte-exact artifact from a
# partial JSON reader is worse than refusing, because the failure would look
# like a legitimate mismatch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${FYD_REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
REGISTRY="${FYD_PUBLICATION_FILE:-${REPO_ROOT}/deploy/publication.json}"

die() { echo "ERROR: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required by $(basename "$0") and is not on PATH."
[ -r "$REGISTRY" ] || die "registry not readable: $REGISTRY"
jq -e . "$REGISTRY" >/dev/null 2>&1 || die "registry is not valid JSON: $REGISTRY"

MODE="render"
AS_BUILT=0
ARTIFACT=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--extract)   MODE="extract" ;;
		--check)     MODE="check" ;;
		--as-built)  AS_BUILT=1 ;;
		-h|--help)   sed -n '2,50p' "$0" | sed 's/^# \?//'; exit 0 ;;
		-*)          die "unknown option: $1" ;;
		*)
			[ -z "$ARTIFACT" ] || die "more than one artifact given: $ARTIFACT and $1"
			ARTIFACT="$1"
			;;
	esac
	shift
done
[ -n "$ARTIFACT" ] || die "usage: $(basename "$0") <feed-excludes|gitignore-block|push-allowlist-doc|push-allowlist-case> [--as-built] [--extract|--check]"

rq() { jq -r "$1" "$REGISTRY"; }

target_file_for() {
	case "$1" in
		feed-excludes)       rq '.derived.feed_excludes.target_file' ;;
		gitignore-block)     rq '.derived.gitignore_block.target_file' ;;
		push-allowlist-doc)  rq '.derived.push_allowlist_doc.target_file' ;;
		push-allowlist-case) rq '.derived.push_allowlist_case.target_file' ;;
		*) die "unknown artifact: $1" ;;
	esac
}

# ---- rendering ------------------------------------------------------------

render_feed_excludes() {
	rq '.derived.feed_excludes.header[]'
	rq '.derived.feed_excludes.order[] | (.comment_before // [] | .[]), .path'
}

render_gitignore_block() {
	local prefix
	prefix="$(rq '.derived.gitignore_block.path_prefix')"
	rq '.derived.gitignore_block.section_header'
	jq -r --arg p "$prefix" '.derived.gitignore_block.order[]
		| (.comment_before // [] | .[]), ($p + .path)' "$REGISTRY"
	rq '.derived.gitignore_block.trailer.lines[]'
}

# One documentation-table row. Two shapes, decided by whether the name fits
# the name column: names that fit take the arrow on the same line, names that
# overflow put the arrow on a continuation line aligned to the same column.
# The names are ASCII, so printf's byte-width padding is character padding
# here; the arrow itself is emitted verbatim and never padded.
doc_row() {
	local name="$1" target="$2" check="${3:-}"
	local indent name_w target_w arrow
	indent="$DOC_INDENT"; name_w="$DOC_NAME_W"; target_w="$DOC_TARGET_W"; arrow="$DOC_ARROW"
	if [ "${#name}" -le "$name_w" ]; then
		if [ -n "$check" ]; then
			printf '%s%-*s%s%-*s(%s)\n' "$indent" "$name_w" "$name" "$arrow" "$target_w" "$target" "$check"
		else
			printf '%s%-*s%s%s\n' "$indent" "$name_w" "$name" "$arrow" "$target"
		fi
	else
		printf '%s%s\n' "$indent" "$name"
		# Continuation aligned to the arrow column: '#' + (indent-1 + name_w) spaces.
		printf '#%*s%s%s\n' "$(( ${#indent} - 1 + name_w ))" "" "$arrow" "$target"
	fi
}

# push_name -> "target<TAB>check", taken from publications[] first and then
# from push_allowlist_only[]. A name present in neither is fatal: it means the
# doc/case order references something the registry does not describe.
push_name_lookup() {
	jq -r '
		[ (.publications[]? | select(.push_name != null)
		    | {name: .push_name, target: .push_target, check: .push_content_check}),
		  (.push_allowlist_only[]?
		    | {name: .push_name, target: .push_target, check: .push_content_check}) ]
		| .[] | [.name, (.target // ""), (.check // "")] | @tsv
	' "$REGISTRY"
}

render_push_allowlist_doc() {
	DOC_INDENT="$(rq '.derived.push_allowlist_doc.layout.indent')"
	DOC_NAME_W="$(rq '.derived.push_allowlist_doc.layout.name_field_width')"
	DOC_TARGET_W="$(rq '.derived.push_allowlist_doc.layout.target_field_width')"
	DOC_ARROW="$(rq '.derived.push_allowlist_doc.layout.arrow')"

	local lookup omit=""
	lookup="$(push_name_lookup)"
	if [ "$AS_BUILT" -eq 1 ]; then
		omit="$(jq -r '.known_render_drift["push_allowlist_doc.missing_rows"].missing_rows[]? // empty' "$REGISTRY")"
	fi

	rq '.derived.push_allowlist_doc.region_start'

	local name target check row skip
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		skip=0
		if [ -n "$omit" ]; then
			while IFS= read -r o; do
				[ "$o" = "$name" ] && skip=1
			done <<< "$omit"
		fi
		[ "$skip" -eq 1 ] && continue
		row="$(printf '%s\n' "$lookup" | awk -F'\t' -v n="$name" '$1 == n { print; exit }')"
		[ -n "$row" ] || die "push name '$name' appears in derived.push_allowlist_doc.flat_order but is described by no publications[] or push_allowlist_only[] entry."
		target="$(printf '%s' "$row" | cut -f2)"
		check="$(printf '%s' "$row" | cut -f3)"
		doc_row "$name" "$target" "$check"
	done <<< "$(rq '.derived.push_allowlist_doc.flat_order[]')"

	rq '.derived.push_allowlist_doc.subdir_header[]'

	local sname starget
	while IFS=$'\t' read -r sname starget; do
		[ -n "$sname" ] || continue
		doc_row "$sname" "$starget" ""
	done <<< "$(jq -r '.derived.push_allowlist_doc.subdir_rows[] | [.name, .target] | @tsv' "$REGISTRY")"
}

render_push_allowlist_case() {
	local indent joined
	indent="$(rq '.derived.push_allowlist_case.indent')"
	joined="$(jq -r '.derived.push_allowlist_case.order | join("|")' "$REGISTRY")"
	printf '%s%s)\n' "$indent" "$joined"
}

render() {
	case "$1" in
		feed-excludes)       render_feed_excludes ;;
		gitignore-block)     render_gitignore_block ;;
		push-allowlist-doc)  render_push_allowlist_doc ;;
		push-allowlist-case) render_push_allowlist_case ;;
		*) die "unknown artifact: $1" ;;
	esac
}

# ---- extraction -----------------------------------------------------------
# Every extractor is anchored on literal text, never on a line number: a line
# number in a test is a second copy of the truth and drifts the first time
# someone adds a comment.

strip_trailing() {
	# Drop trailing lines matching $1 (an awk regex), keeping everything else.
	awk -v pat="$1" '{ buf[NR] = $0 } END {
		last = NR
		while (last > 0 && buf[last] ~ pat) last--
		for (i = 1; i <= last; i++) print buf[i]
	}'
}

extract() {
	local tf
	tf="${REPO_ROOT}/$(target_file_for "$1")"
	[ -r "$tf" ] || die "target file not readable: $tf"
	case "$1" in
		feed-excludes)
			cat "$tf"
			;;
		gitignore-block)
			local hdr
			hdr="$(rq '.derived.gitignore_block.section_header')"
			awk -v hdr="$hdr" '
				$0 == hdr { inblk = 1; print; next }
				inblk && /^# ---- / { exit }
				inblk { print }
			' "$tf" | strip_trailing '^[[:space:]]*$'
			;;
		push-allowlist-doc)
			local start endbefore
			start="$(rq '.derived.push_allowlist_doc.region_start')"
			endbefore="$(rq '.derived.push_allowlist_doc.region_end_before')"
			awk -v s="$start" -v e="$endbefore" '
				$0 == s { inblk = 1; print; next }
				inblk && $0 == e { exit }
				inblk { print }
			' "$tf" | strip_trailing '^#$|^[[:space:]]*$'
			;;
		push-allowlist-case)
			# The enforced flat allowlist: the one line that both starts with
			# the first name in the declared order and ends with ')'.
			local first
			first="$(rq '.derived.push_allowlist_case.order[0]')"
			awk -v f="$first" '
				{ t = $0; sub(/^[[:space:]]+/, "", t) }
				index(t, f "|") == 1 && t ~ /\)$/ { print; found = 1; exit }
				END { if (!found) exit 3 }
			' "$tf" || die "could not locate the flat allowlist case line in $tf"
			;;
		*) die "unknown artifact: $1" ;;
	esac
}

# ---- dispatch -------------------------------------------------------------

case "$MODE" in
	render)  render "$ARTIFACT" ;;
	extract) extract "$ARTIFACT" ;;
	check)
		tmp_r="$(mktemp -t fyd-render.XXXXXX)"
		tmp_e="$(mktemp -t fyd-extract.XXXXXX)"
		trap 'rm -f "$tmp_r" "$tmp_e"' EXIT
		render "$ARTIFACT"  > "$tmp_r"
		extract "$ARTIFACT" > "$tmp_e"
		if cmp -s "$tmp_r" "$tmp_e"; then
			exit 0
		fi
		{
			echo "MISMATCH: $ARTIFACT (as-built=$AS_BUILT)"
			echo "--- rendered from $REGISTRY"
			echo "+++ extracted from ${REPO_ROOT}/$(target_file_for "$ARTIFACT")"
			diff -u "$tmp_r" "$tmp_e" || true
		} >&2
		exit 1
		;;
esac
