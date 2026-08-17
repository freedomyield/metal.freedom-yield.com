#!/usr/bin/env bash
# test-publication-registry.sh — hold deploy/publication.json to the files it
# claims to describe.
#
# CHAIN: none. PRIME_DIRECTIVE: safe — no broadcast, no push, no network, no
# SSH. Reads repo files and runs git plumbing (ls-files / check-ignore) on the
# working tree. Writes only into its own mktemp directory.
#
# ---------------------------------------------------------------------------
# WHAT THESE TESTS PROVE, AND WHAT THEY DO NOT
# ---------------------------------------------------------------------------
# They prove that the three hand-maintained derived regions can be reproduced
# byte-for-byte from the registry TODAY, and that the registry's declarations
# about git tracking, gitignore status and manifest pins match what git and
# public/api/identity.json actually say TODAY.
#
# They do NOT prove that anything at runtime reads the registry — nothing
# does yet (C1 Phase 0 deliberately changes no consumer). They do NOT prove
# that a published URL is reachable, that a pinned digest currently matches
# the live bytes (that is scripts/check-identity-pins.sh), or that the
# production cron files invoke what the registry says they invoke — the
# registry explicitly disclaims that surface and T12 checks the disclaimer is
# still there.
#
# T1  feed-excludes            renders byte-identically to deploy/feed-excludes.txt
# T2  gitignore-block          renders byte-identically to the .gitignore section
# T3  push-allowlist-case      renders byte-identically to the enforced case line
# T4  push-allowlist-doc       renders byte-identically --as-built
# T5  known_render_drift is real and expiring (canonical minus as-built is
#     exactly the declared missing rows; each is enforced but undocumented)
# T6  kind gate: no pin over a kind=stream path outside known_kind_violations
# T7  known_kind_violations has no obsolete entry
# T8  SoT closure: derived order lists and publications[] agree both ways
# T9  git-owned and push-owned sets are disjoint (protects the 149 tracked
#     public/ files the registry deliberately does not enumerate)
# T10 subdir basename patterns identical in registry / sender / receiver
# T11 registry validates against deploy/publication.schema.v1.json
# T12 the coverage disclaimer is present and structurally complete
# T13 declared git_tracked / gitignored match git
# T14 pinned_by is exactly the pin set in identity.json's artifact_manifest
# T15 mutation self-proof: break the registry three ways, each must go red
# T16 enumeration closure over the prefixes the registry CLAIMS
# T17 known_doc_drift is real and expiring
# T18 kind=record is earned by a digest key, never a date key; and
#     becomes_record_after only ever sits on a kind=stream row
# T19 forward regression: the suite behaves correctly against the post-C4
#     manifest shape (streams listed unpinned, a record pinned on a directory
#     row), including a mutation that reproduces the pre-fix T7 false pass
# T20 pin_policy wording (S3): the record-kind defining clause is copied,
#     not independently reworded, across deploy/publication.json,
#     public/api/identity.schema.v1.json and
#     scripts/operator-local/gen-identity.sh
# T21 all THREE copies of the registry-kind resolution rule agree — this
#     file's kind_of(), scripts/check-identity-pins.sh's registry_kind_of()
#     and scripts/operator-local/gen-identity.sh's registry_kind_of_path()
#     (the copy that composes the signed manifest) — with a mutation proof on
#     each side of the comparison
# T22 the two bash url→path copies are behaviourally identical (extracted and
#     executed), the jq SEMANTICS agree with them on every URL the signed
#     manifest carries (semantics only — the two jq copies' own texts are held
#     by T7/T14 and by k8U in tests/identity-pins/), and the recorded reason
#     for not unifying all four is itself expiring

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGISTRY="${REPO_ROOT}/deploy/publication.json"
SCHEMA="${REPO_ROOT}/deploy/publication.schema.v1.json"
RENDER="${REPO_ROOT}/scripts/deploy/render-publication.sh"
IDENTITY="${REPO_ROOT}/public/api/identity.json"
SENDER="${REPO_ROOT}/scripts/push-to-web-host.sh"
RECEIVER="${REPO_ROOT}/scripts/deploy/receive-subdir-allowlist.snippet.sh"
IDENTITY_SCHEMA="${REPO_ROOT}/public/api/identity.schema.v1.json"
GEN_IDENTITY="${REPO_ROOT}/scripts/operator-local/gen-identity.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
note() { printf '      %s\n' "$1"; }

TMPDIR_T="$(mktemp -d -t fyd-pubreg.XXXXXX)"
trap 'rm -rf "$TMPDIR_T"' EXIT

for f in "$REGISTRY" "$SCHEMA" "$RENDER" "$IDENTITY" "$SENDER" "$RECEIVER" "$IDENTITY_SCHEMA" "$GEN_IDENTITY"; do
	[ -r "$f" ] || { echo "FATAL: missing prerequisite: $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

# ---------------------------------------------------------------------------
# T1-T4 — byte equality of the four rendered regions
# ---------------------------------------------------------------------------
check_artifact() {
	local artifact="$1" label="$2"
	shift 2
	if bash "$RENDER" --check "$artifact" "$@" 2>"${TMPDIR_T}/${artifact}.err"; then
		pass "$label"
	else
		fail "$label"
		sed 's/^/      /' "${TMPDIR_T}/${artifact}.err" | head -40
	fi
}

check_artifact feed-excludes       "T1  deploy/feed-excludes.txt renders byte-identically from the registry"
check_artifact gitignore-block     "T2  .gitignore runtime-data section renders byte-identically"
check_artifact push-allowlist-case "T3  push-to-web-host.sh flat case line renders byte-identically"
check_artifact push-allowlist-doc  "T4  push-to-web-host.sh 'Allowed targets' table renders byte-identically (--as-built)" --as-built

# ---------------------------------------------------------------------------
# T5 — known_render_drift describes a real, still-present, expiring drift
# ---------------------------------------------------------------------------
t5() {
	local declared canonical as_built added n_declared
	declared="$(jq -r '.known_render_drift["push_allowlist_doc.missing_rows"].missing_rows[]? // empty' "$REGISTRY" | sort)"
	if [ -z "$declared" ]; then
		# No declared drift is a legitimate end state (Phase 1 fixes the file).
		# It is only correct if canonical and as-built are then identical.
		if diff -q <(bash "$RENDER" push-allowlist-doc) <(bash "$RENDER" push-allowlist-doc --as-built) >/dev/null; then
			pass "T5  known_render_drift is empty and canonical == as-built (drift resolved)"
		else
			fail "T5  canonical and as-built differ but known_render_drift declares nothing"
		fi
		return
	fi
	canonical="${TMPDIR_T}/doc-canonical"
	as_built="${TMPDIR_T}/doc-asbuilt"
	bash "$RENDER" push-allowlist-doc            > "$canonical"
	bash "$RENDER" push-allowlist-doc --as-built > "$as_built"
	# Nothing may be REMOVED by --as-built other than whole rows.
	if diff "$as_built" "$canonical" | grep -q '^< '; then
		fail "T5  as-built render has lines the canonical render lacks — that is not a missing-row drift"
		return
	fi

	# Attribute each ADDED LINE to a declared name by prefix, after stripping
	# the comment indent — NOT by slicing a fixed column. A push name longer
	# than the table's name field renders as two lines (the name, then an
	# arrow-only continuation), and a column-based match sees neither, i.e. it
	# reports "no drift" for exactly the shape most likely to have some. A
	# continuation is recognised by the character after the indent being a
	# space, which no real push name ever starts with.
	local indent added_lines line stripped matched name unmatched=0
	indent="$(jq -r '.derived.push_allowlist_doc.layout.indent' "$REGISTRY")"
	added_lines="$(diff "$as_built" "$canonical" | sed -n 's/^> //p')"
	added=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		stripped="${line#"$indent"}"
		[ "$stripped" = "$line" ] && continue
		case "$stripped" in ' '*|'') continue ;; esac
		matched=""
		while IFS= read -r name; do
			[ -n "$name" ] || continue
			case "$stripped" in "$name"*) matched="$name" ;; esac
		done <<< "$declared"
		if [ -z "$matched" ]; then
			fail "T5  added line attributable to no declared missing row: ${line}"
			unmatched=1
		else
			added="${added}${matched}"$'\n'
		fi
	done <<< "$added_lines"
	[ "$unmatched" -eq 0 ] || return
	added="$(printf '%s' "$added" | grep . | sort -u)"
	if [ "$added" != "$declared" ]; then
		fail "T5  canonical-minus-as-built is not exactly the declared missing_rows"
		note "declared: $(echo "$declared" | tr '\n' ' ')"
		note "actual:   $(echo "$added" | tr '\n' ' ')"
		return
	fi
	# Expiry conditions: each declared row must STILL be (a) absent from the
	# live header table and (b) present in the live enforced case line. Either
	# flipping makes the entry obsolete, and obsolete must be loud.
	local live_doc live_case obsolete=0
	live_doc="$(bash "$RENDER" --extract push-allowlist-doc)"
	live_case="$(bash "$RENDER" --extract push-allowlist-case)"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		# Row present == a line that is exactly indent+name followed by a
		# space or end-of-line. Literal comparison, not a regex: push names
		# contain '.', '<' and '>'.
		if printf '%s\n' "$live_doc" | awk -v ind="$indent" -v n="$name" '
			index($0, ind n) == 1 {
				r = substr($0, length(ind n) + 1)
				if (r == "" || substr(r, 1, 1) == " ") found = 1
			}
			END { exit found ? 0 : 1 }'; then
			fail "T5  OBSOLETE: '${name}' now HAS a row in the header table — drop it from known_render_drift"
			obsolete=1
		fi
		if ! printf '%s\n' "$live_case" | grep -Fq -- "${name}"; then
			fail "T5  OBSOLETE: '${name}' is no longer in the enforced case line — drop it from known_render_drift"
			obsolete=1
		fi
	done <<< "$declared"
	n_declared="$(printf '%s\n' "$declared" | grep -c . || true)"
	[ "$obsolete" -eq 0 ] && pass "T5  known_render_drift describes ${n_declared} real, still-present, still-enforced omission(s)"
}
t5

# ---------------------------------------------------------------------------
# Shared: pin table from identity.json, and kind lookup from the registry
# ---------------------------------------------------------------------------
# "<pin key>\t<public-relative path>" for every pin in the signed manifest.
# The path is derived from the manifest's own url / schema_url, not asserted
# by the registry, so this is a measurement and not a restatement.
#
# A PIN IS A PRESENT sha256, not a listed entry. Since the C4 kind discipline
# (2026-08-14) an entry whose publication kind is `stream` is listed with url +
# kind and NO sha256, so emitting a `.sha256` row for every entry would invent
# pins that do not exist. scripts/check-identity-pins.sh's own PINS
# enumeration (the `jq -r` that builds "<pin_id>\t<url>\t<sha256>" rows) has
# always gated on `(.value.sha256 // "") != ""` — cited by name rather than by
# line number, which was already off by ~170 lines when this was measured on
# 2026-08-17; this is the second implementation of
# the same enumeration and the two must not disagree. Measured consequence of
# the disagreement, before this fix: against a post-C4 manifest T7 reported
# "all 4 known_kind_violations entries still describe a real violation" while
# the manifest contained no stream pin at all — a false pass on the one check
# whose entire job is to expire the acknowledgement list.
identity_pins() {
	jq -r '
		.artifact_manifest | to_entries[] |
		( select(.value.sha256 != null)
		  | [ (.key + ".sha256"), (.value.url        | sub("^https?://[^/]+/"; "")) ] | @tsv ),
		( select(.value.schema_sha256 != null)
		  | [ (.key + ".schema_sha256"), (.value.schema_url | sub("^https?://[^/]+/"; "")) ] | @tsv )
	' "$IDENTITY"
}

# registry_row_for_path <public-relative path> -> the registry `path` that
# GOVERNS it, or empty.
#
# Exact row wins. Otherwise a directory row (path ending in "/") governs the
# member only when the member's basename matches that row's member_pattern —
# the same resolution scripts/operator-local/gen-identity.sh performs, and the
# reason a digest-named archive member may be treated as kind=record while
# api/archive/whatever.json may not. Without this, a pin on a directory member
# resolved to NO row: kind_of returned empty so T6 skipped it in silence, and
# T14 compared the member URL against a registry path that can only ever be the
# directory itself, so a record pin was impossible to declare at all.
registry_row_for_path() {
	jq -r --arg p "$1" '
		( [ .publications[] | select(.path == $p) | .path ] | first // "" ) as $exact
		| if $exact != "" then $exact
		  else
			( [ .publications[]
				| . as $row
				| select($row.path | endswith("/"))
				| select(($row.member_pattern // "") != "")
				| select($p | startswith($row.path))
				| ($row.path | length) as $plen
				| ($p[$plen:]) as $member
				| select($member | test($row.member_pattern))
				| $row.path
			  ] | first // "" )
		  end
	' "${2:-$REGISTRY}"
}

# kind_of resolves through the same governing row, so a pin on a directory
# member is classified by that directory's kind instead of vanishing.
kind_of() {
	local reg="${2:-$REGISTRY}" row
	row="$(registry_row_for_path "$1" "$reg")"
	[ -n "$row" ] || return 0
	jq -r --arg p "$row" '.publications[] | select(.path == $p) | .kind' "$reg"
}

# ---------------------------------------------------------------------------
# Shared (T21/T22): run a foreign script's function without editing that script
# ---------------------------------------------------------------------------
# extract_shell_fn <file> <fn name> — print the function's SOURCE verbatim,
# from its `name() {` line to the first line that is exactly `}`.
#
# Extraction BY NAME, rather than by a sentinel comment pair, is what makes it
# possible to hold scripts/operator-local/gen-identity.sh's copies of shared
# resolution logic to account from tests/ alone: the generator needs no marker
# comments added to it, so nothing outside this directory has to change for
# the third copy of a duplicated rule to become machine-checked. What this
# suite then executes is the generator's ACTUAL function — its jq program, its
# --arg wiring, its 2>/dev/null — not a re-transcription of it. A
# re-transcription would merely be one more untested copy of the thing under
# test, which is the defect being closed, not a check on it.
extract_shell_fn() {
	awk -v fn="$2" '
		$0 == fn "() {"     { inside = 1 }
		inside              { print }
		inside && $0 == "}" { exit }
	' "$1"
}

# assert_extracted_fn <file> <fn name> <label> — the extraction must be the
# function it claims to be, or this suite FAILS.
#
# An extraction that silently comes up empty (the function was renamed, or its
# closing brace moved) would otherwise turn every comparison built on it into
# a vacuous green: two resolvers that are never run agree about everything.
# That is the "空振り PASS" shape this whole task exists to remove, so a
# broken extraction is a failure here, never a skip.
assert_extracted_fn() {
	local f="$1" fn="$2" label="$3" bad_x=0
	if [ ! -s "$f" ]; then
		fail "${label} extraction of ${fn}() from the source script produced nothing — was it renamed or reshaped?"
		return 1
	fi
	head -1 "$f" | grep -qxF -- "${fn}() {" \
		|| { fail "${label} extraction of ${fn}() does not begin at its definition line"; bad_x=1; }
	tail -1 "$f" | grep -qxF -- '}' \
		|| { fail "${label} extraction of ${fn}() does not end at its closing brace"; bad_x=1; }
	[ "$bad_x" -eq 0 ]
}

# probe_paths — the public-relative paths every kind resolver in T21 is
# compared over: every exact publications[] row this registry declares, plus
# directory-member paths that DO and DO NOT match a directory row's
# member_pattern, plus a member of the one directory row that has NO
# member_pattern at all. The member paths are the point: an exact-match-only
# implementation, and the historical `select($p | startswith(.path))` bug,
# are both invisible against exact rows alone.
#
# The last one closes review finding M-1 (2026-08-17): `calendar/` is the
# only directory row in this registry without a member_pattern, so it is the
# only path that exercises each resolver's "member_pattern is empty -> this
# row governs nothing" guard. Measured on a clone, both ways: doctor
# gen-identity.sh's resolver to drop that guard and default the pattern to
# "." (so `calendar/renewal.ics` resolves to `stream` instead of no row) and
# WITHOUT this probe the suite is still 37 PASS / 0 FAIL, WITH it T21 names
# the path and fails. The n>=20 / n_record>=1 / n_norow>=1 strength check
# never reached the branch — the api/archive/ rows satisfy all three.
probe_paths() {
	jq -r '.publications[].path' "$REGISTRY"
	printf '%s\n' \
		"api/archive/anchor-source-0000000000000000000000000000000000000000000000000000000000000001.json" \
		"api/archive/anchor-source-2026-08-14.json" \
		"api/peers-history/peers-2026-08-14.json.gz" \
		"api/peers-history/not-a-date.json.gz" \
		"calendar/renewal.ics"
}

# ---------------------------------------------------------------------------
# T6 — kind gate: kind=stream must not be pinned, except in the baseline
# ---------------------------------------------------------------------------
t6() {
	local key path kind new=0
	while IFS=$'\t' read -r key path; do
		[ -n "$key" ] || continue
		kind="$(kind_of "$path")"
		[ "$kind" = "stream" ] || continue
		if [ "$(jq -r --arg k "$key" '.known_kind_violations.violations[$k] // empty' "$REGISTRY")" = "" ]; then
			fail "T6  NEW kind violation: pin '${key}' targets ${path} (kind=stream) and is not in known_kind_violations"
			new=1
		fi
	done <<< "$(identity_pins)"
	[ "$new" -eq 0 ] && pass "T6  no NEW kind=stream pin (all stream pins are declared in known_kind_violations)"
}
t6

# ---------------------------------------------------------------------------
# T7 — the baseline is an acknowledgement, not a mute: no obsolete entry
#
# scripts/check-identity-pins.sh's OBSOLETE-KIND-ACK block calls these "the
# same three conditions T7 uses, so the two can never disagree". Review
# finding M-5 (2026-08-17) measured one asymmetry in that claim and it is
# left in place deliberately: for an ack entry with NO `path` key at all,
# this test reads `.path` raw (jq -r yields the string "null", which never
# equals a real pinned path, so condition 2 fires and CI goes red), while the
# checker reads `.path // ""` and then guards on `[ -n "$ACK_PATH" ]`, so it
# skips condition 2 and moves on to condition 3.
#
# Not aligned, for two reasons. It is unreachable: deploy/publication.schema
# .v1.json makes `path` required under known_kind_violations.violations.*,
# and T11 fails if the real registry stops validating against that schema.
# And the direction of the difference is the safe one — T7 is the STRICTER
# of the two, on the side that fails CI inside the offending commit; making
# it match the checker would mean weakening a live assertion to match a guard
# that exists only for robustness. If `path` ever stops being required, this
# note is what says which of the two moves.
# ---------------------------------------------------------------------------
t7() {
	local key declared_path live_path kind obsolete=0 n
	while IFS= read -r key; do
		[ -n "$key" ] || continue
		declared_path="$(jq -r --arg k "$key" '.known_kind_violations.violations[$k].path' "$REGISTRY")"
		live_path="$(identity_pins | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')"
		if [ -z "$live_path" ]; then
			fail "T7  OBSOLETE baseline entry '${key}': that pin no longer exists in identity.json's artifact_manifest"
			obsolete=1
			continue
		fi
		if [ "$live_path" != "$declared_path" ]; then
			fail "T7  baseline entry '${key}' declares path ${declared_path} but the manifest pins ${live_path}"
			obsolete=1
			continue
		fi
		kind="$(kind_of "$declared_path")"
		if [ "$kind" != "stream" ]; then
			fail "T7  OBSOLETE baseline entry '${key}': ${declared_path} is kind=${kind}, no longer a violation"
			obsolete=1
		fi
	done <<< "$(jq -r '.known_kind_violations.violations | keys[]' "$REGISTRY")"
	n="$(jq -r '.known_kind_violations.violations | length' "$REGISTRY")"
	[ "$obsolete" -eq 0 ] && pass "T7  all ${n} known_kind_violations entries still describe a real violation"
}
t7

# ---------------------------------------------------------------------------
# T8 — SoT closure: the derived order lists and publications[] agree both ways
# ---------------------------------------------------------------------------
t8() {
	local a b bad=0
	cmp_sets() { # $1 label, $2 expected-from-publications, $3 actual-from-derived
		if [ "$2" = "$3" ]; then return 0; fi
		fail "T8  $1"
		note "only in publications[]: $(comm -23 <(printf '%s\n' "$2") <(printf '%s\n' "$3") | tr '\n' ' ')"
		note "only in derived order:  $(comm -13 <(printf '%s\n' "$2") <(printf '%s\n' "$3") | tr '\n' ' ')"
		bad=1
	}

	a="$(jq -r '.publications[] | select(.rsync_delete_exclude == true) | .path' "$REGISTRY" | sort)"
	b="$(jq -r '.derived.feed_excludes.order[].path' "$REGISTRY" | sort)"
	cmp_sets "rsync_delete_exclude==true does not match derived.feed_excludes.order" "$a" "$b"

	a="$(jq -r '.publications[] | select(.gitignored == true and (.publisher != "deploy-runner")) | .path' "$REGISTRY" | sort)"
	b="$(jq -r '.derived.gitignore_block.order[].path' "$REGISTRY" | sort)"
	cmp_sets "gitignored==true does not match derived.gitignore_block.order" "$a" "$b"

	a="$(jq -r '.publications[] | select(.publisher == "push") | select(.push_name != null) | .push_name' "$REGISTRY" | sort)"
	b="$(jq -r '.derived.push_allowlist_case.order[]' "$REGISTRY" | sort)"
	cmp_sets "publisher==push push_names do not match derived.push_allowlist_case.order" "$a" "$b"

	# Every name in the doc table must be either a push publication or a
	# push_allowlist_only member — no orphan documentation rows.
	a="$(jq -r '[ (.publications[] | select(.push_name != null) | .push_name),
	              (.push_allowlist_only[].push_name) ] | .[]' "$REGISTRY" | sort -u)"
	b="$(jq -r '.derived.push_allowlist_doc.flat_order[]' "$REGISTRY" | sort -u)"
	if [ -n "$(comm -13 <(printf '%s\n' "$a") <(printf '%s\n' "$b"))" ]; then
		fail "T8  derived.push_allowlist_doc.flat_order names something no entry describes"
		bad=1
	fi

	# Duplicate paths would let two rows disagree about the same file.
	if [ "$(jq -r '.publications[].path' "$REGISTRY" | sort | uniq -d | head -1)" != "" ]; then
		fail "T8  duplicate path in publications[]"
		bad=1
	fi

	[ "$bad" -eq 0 ] && pass "T8  derived order lists and publications[] agree in both directions"
}
t8

# ---------------------------------------------------------------------------
# T9 — git-owned and push-owned sets are disjoint.
# This is what makes the registry's decision NOT to enumerate the static site
# tree checkable rather than assumed: if any tracked file ever falls under a
# feed exclude or a push name, it has two owners and must be declared.
# ---------------------------------------------------------------------------
t9() {
	local excl_files excl_dirs push_names tracked rel base bad=0 n
	excl_files="$(jq -r '.derived.feed_excludes.order[].path | select(endswith("/") | not)' "$REGISTRY")"
	excl_dirs="$(jq -r '.derived.feed_excludes.order[].path | select(endswith("/"))' "$REGISTRY")"
	push_names="$(jq -r '.derived.push_allowlist_case.order[]' "$REGISTRY")"
	tracked="$(cd "$REPO_ROOT" && git ls-files public/)"
	n=0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		n=$((n + 1))
		rel="${f#public/}"
		base="$(basename "$rel")"
		if printf '%s\n' "$excl_files" | grep -Fxq -- "$rel"; then
			fail "T9  tracked file ${f} is also a feed exclude — two owners"
			bad=1
		fi
		while IFS= read -r d; do
			[ -n "$d" ] || continue
			case "$rel" in "$d"*) fail "T9  tracked file ${f} lives under push-owned directory ${d} — two owners"; bad=1 ;; esac
		done <<< "$excl_dirs"
		if printf '%s\n' "$push_names" | grep -Fxq -- "$base"; then
			case "$rel" in
				api/*) fail "T9  tracked file ${f} shares a basename with a push allowlist entry — two owners"; bad=1 ;;
			esac
		fi
	done <<< "$tracked"
	[ "$bad" -eq 0 ] && pass "T9  all ${n} tracked public/ files are disjoint from every push-owned path and name"
}
t9

# ---------------------------------------------------------------------------
# T10 — the two subdirectory basename patterns are one string in three places
# ---------------------------------------------------------------------------
t10() {
	# NOTE: read prefix and pattern on SEPARATE lines, not via @tsv. jq's @tsv
	# escapes backslashes, and these values are regexes full of them — an @tsv
	# round-trip silently turns `\.json` into `\\.json` and every comparison
	# below fails for a reason that has nothing to do with the files.
	local prefix pattern bad=0 n=0
	while IFS= read -r prefix && IFS= read -r pattern; do
		[ -n "$prefix" ] || continue
		n=$((n + 1))
		grep -Fq -- "$pattern" "$SENDER"   || { fail "T10 pattern for '${prefix}/' not found verbatim in scripts/push-to-web-host.sh"; bad=1; }
		grep -Fq -- "$pattern" "$RECEIVER" || { fail "T10 pattern for '${prefix}/' not found verbatim in receive-subdir-allowlist.snippet.sh"; bad=1; }
	done <<< "$(jq -r '.publications[] | select(.push_prefix != null) | .push_prefix, .member_pattern' "$REGISTRY")"
	[ "$n" -gt 0 ] || { fail "T10 registry declares no subdirectory member_pattern at all"; bad=1; }

	# Flat push names can carry a basename_pattern too (the token-named .ics).
	# Declaring one and never comparing it to the sender is a pattern that
	# looks enforced and is not.
	local pname m=0
	while IFS= read -r pname && IFS= read -r pattern; do
		[ -n "$pname" ] || continue
		m=$((m + 1))
		grep -Fq -- "$pattern" "$SENDER" || { fail "T10 basename_pattern for push name '${pname}' not found verbatim in scripts/push-to-web-host.sh"; bad=1; }
	done <<< "$(jq -r '.push_allowlist_only[]? | select(.basename_pattern != null) | .push_name, .basename_pattern' "$REGISTRY")"

	[ "$bad" -eq 0 ] && pass "T10 all ${n} subdirectory + ${m} flat basename patterns are byte-identical in the registry and the scripts that enforce them"
}
t10

# ---------------------------------------------------------------------------
# T11 — registry validates against its schema
# ---------------------------------------------------------------------------
t11() {
	local out
	if command -v ajv >/dev/null 2>&1; then
		if out="$(ajv validate -s "$SCHEMA" -d "$REGISTRY" 2>&1)"; then
			pass "T11 registry validates against deploy/publication.schema.v1.json (ajv)"
		else
			fail "T11 registry fails its schema (ajv)"; note "$out"
		fi
		return
	fi
	if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
		if out="$(python3 - "$SCHEMA" "$REGISTRY" <<'PY' 2>&1
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
data = json.load(open(sys.argv[2]))
jsonschema.validate(data, schema)
print("ok")
PY
		)"; then
			pass "T11 registry validates against deploy/publication.schema.v1.json (python3+jsonschema)"
		else
			fail "T11 registry fails its schema (python3+jsonschema)"; note "$(printf '%s' "$out" | head -20)"
		fi
		return
	fi
	# Never resolve "cannot verify" into "verified".
	fail "T11 no JSON-schema validator available (ajv absent, python3+jsonschema absent) — refusing to report the registry as valid"
}
t11

# ---------------------------------------------------------------------------
# T12 — the coverage disclaimer must stay complete.
# Deleting it would be the single most dangerous silent edit to this file
# (spec §9: a SoT that is believed to cover production but does not).
# ---------------------------------------------------------------------------
t12() {
	local n bad
	n="$(jq -r '.coverage.does_not_govern | length' "$REGISTRY")"
	bad="$(jq -r '[.coverage.does_not_govern[] | select((.surface | length) == 0 or (.measured | length) == 0 or (.why_excluded | length) == 0)] | length' "$REGISTRY")"
	if [ "$n" -ge 1 ] && [ "$bad" -eq 0 ]; then
		pass "T12 coverage.does_not_govern declares ${n} surface(s), each with surface/measured/why_excluded"
	else
		fail "T12 coverage.does_not_govern is empty or has an entry with a blank field (n=${n}, blank=${bad})"
	fi
	# Every push publication must state whether its cron is verifiable here.
	local missing
	missing="$(jq -r '[.publications[] | select(.publisher == "push" or .publisher == "push-subdir" or .publisher == "push-out-of-band") | select(.owner | has("cron_installer_in_repo") | not) | .path] | length' "$REGISTRY")"
	if [ "$missing" -eq 0 ]; then
		pass "T12 every push-owned publication states owner.cron_installer_in_repo"
	else
		fail "T12 ${missing} push-owned publication(s) omit owner.cron_installer_in_repo"
	fi
}
t12

# ---------------------------------------------------------------------------
# T13 — declared git state matches measured git state
# ---------------------------------------------------------------------------
t13() {
	local path gp declared measured bad=0 n=0
	while IFS=$'\t' read -r path declared; do
		[ -n "$path" ] || continue
		n=$((n + 1))
		gp="public/${path}"
		if (cd "$REPO_ROOT" && git check-ignore -q "$gp"); then measured=true; else measured=false; fi
		[ "$declared" = "$measured" ] || { fail "T13 ${path}: declares gitignored=${declared}, git says ${measured}"; bad=1; }
	done <<< "$(jq -r '.publications[] | select(has("gitignored")) | [.path, (.gitignored|tostring)] | @tsv' "$REGISTRY")"

	while IFS=$'\t' read -r path declared; do
		[ -n "$path" ] || continue
		gp="public/${path}"
		case "$path" in
			*/) if [ -n "$(cd "$REPO_ROOT" && git ls-files "$gp")" ]; then measured=true; else measured=false; fi ;;
			*)  if (cd "$REPO_ROOT" && git ls-files --error-unmatch "$gp" >/dev/null 2>&1); then measured=true; else measured=false; fi ;;
		esac
		[ "$declared" = "$measured" ] || { fail "T13 ${path}: declares git_tracked=${declared}, git says ${measured}"; bad=1; }
	done <<< "$(jq -r '.publications[] | select(has("git_tracked")) | [.path, (.git_tracked|tostring)] | @tsv' "$REGISTRY")"

	[ "$bad" -eq 0 ] && pass "T13 declared gitignored/git_tracked match git for every publication that states them (${n} gitignore claims)"
}
t13

# ---------------------------------------------------------------------------
# T14 — pinned_by is exactly the manifest's pin set, in both directions
# ---------------------------------------------------------------------------
t14() {
	local live declared bad=0 n key path row unresolved=0
	# The live side names the GOVERNING registry row, not the raw URL path: a
	# pin on a content-addressed member of api/archive/ is declared on the
	# api/archive/ row, because that directory row is the only place the
	# registry can carry a pinned_by for it. Comparing the member URL against
	# publications[].path directly made a record pin undeclarable — the two
	# sides could never agree, in either direction.
	live=""
	while IFS=$'\t' read -r key path; do
		[ -n "$key" ] || continue
		row="$(registry_row_for_path "$path")"
		if [ -z "$row" ]; then
			fail "T14 pin '${key}' targets ${path}, which no publications[] row governs (no exact row, no directory row whose member_pattern matches)"
			unresolved=1
			continue
		fi
		live="${live}api/identity.json#artifact_manifest.${key}	${row}"$'\n'
	done <<< "$(identity_pins)"
	live="$(printf '%s' "$live" | sort)"
	[ "$unresolved" -eq 0 ] || bad=1
	declared="$(jq -r '.publications[] | . as $p | .pinned_by[]? | [., $p.path] | @tsv' "$REGISTRY" | sort)"
	if [ "$live" != "$declared" ]; then
		fail "T14 pinned_by does not match identity.json's artifact_manifest"
		note "only in identity.json: $(comm -23 <(printf '%s\n' "$live") <(printf '%s\n' "$declared") | tr '\t' ' ' | tr '\n' '; ')"
		note "only in registry:      $(comm -13 <(printf '%s\n' "$live") <(printf '%s\n' "$declared") | tr '\t' ' ' | tr '\n' '; ')"
		bad=1
	fi
	n="$(printf '%s\n' "$live" | grep -c . || true)"
	[ "$bad" -eq 0 ] && pass "T14 all ${n} manifest pins are declared on exactly the publication the manifest's own url names"
}
t14

# ---------------------------------------------------------------------------
# T16 — enumeration closure over the prefixes the registry CLAIMS.
# T9 protects the files the registry deliberately does not list. This is the
# other direction, and the one that was missing: inside public/api/ and
# public/.well-known/ — the two prefixes coverage.does_not_govern implicitly
# claims ARE enumerated — every tracked file must have a row. Without this,
# adding a tracked artifact under either prefix left the suite green, which is
# the whole failure class this registry exists to end.
# ---------------------------------------------------------------------------
t16() {
	local declared tracked missing extra bad=0 n
	declared="$(jq -r '.publications[] | select(.git_tracked == true) | .path' "$REGISTRY" | sort)"
	tracked="$(cd "$REPO_ROOT" && git ls-files public/api/ public/.well-known/ | sed 's|^public/||' | sort)"
	missing="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$tracked"))"
	extra="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$tracked"))"
	if [ -n "$missing" ]; then
		fail "T16 tracked under a claimed prefix but absent from publications[]:"
		while IFS= read -r f; do [ -n "$f" ] && note "  public/${f}"; done <<< "$missing"
		bad=1
	fi
	if [ -n "$extra" ]; then
		fail "T16 declared git_tracked=true but git does not track it under a claimed prefix:"
		while IFS= read -r f; do [ -n "$f" ] && note "  public/${f}"; done <<< "$extra"
		bad=1
	fi
	n="$(printf '%s\n' "$tracked" | grep -c . || true)"
	[ "$bad" -eq 0 ] && pass "T16 public/api/ and public/.well-known/ are enumerated exhaustively (${n} tracked files, ${n} rows)"
}
t16

# ---------------------------------------------------------------------------
# T17 — known_doc_drift is real and expiring.
# Same contract as T5, applied to documentation the registry contradicts. The
# alternative — leaving the correction only in prose — goes silently false the
# day someone fixes the doc.
# ---------------------------------------------------------------------------
t17() {
	local key tf wrong path declared_producer registry_producer row bad=0 n=0
	while IFS= read -r key; do
		[ -n "$key" ] || continue
		tf="${REPO_ROOT}/$(jq -r --arg k "$key" '.known_doc_drift[$k].target_file' "$REGISTRY")"
		wrong="$(jq -r --arg k "$key" '.known_doc_drift[$k].wrong_text' "$REGISTRY")"
		if [ ! -r "$tf" ]; then
			fail "T17 [${key}] target_file not readable: ${tf}"
			bad=1
			continue
		fi
		while IFS= read -r path && IFS= read -r declared_producer; do
			[ -n "$path" ] || continue
			n=$((n + 1))
			# The doc row for this path must STILL contain the wrong text.
			row="$(grep -F "\`public/${path}\`" "$tf" | head -1)"
			if [ -z "$row" ]; then
				fail "T17 [${key}] OBSOLETE: no row for public/${path} in ${tf} any more — drop the entry"
				bad=1
				continue
			fi
			if ! printf '%s\n' "$row" | grep -Fq -- "$wrong"; then
				fail "T17 [${key}] OBSOLETE: the row for public/${path} no longer says ${wrong} — the doc was fixed, drop the entry"
				bad=1
				continue
			fi
			# And the registry must actually carry the corrected producer.
			registry_producer="$(jq -r --arg p "$path" '.publications[] | select(.path == $p) | .owner.producer' "$REGISTRY")"
			if [ "$registry_producer" != "$declared_producer" ]; then
				fail "T17 [${key}] ${path}: drift entry says the real producer is '${declared_producer}' but publications[] says '${registry_producer}'"
				bad=1
			fi
		done <<< "$(jq -r --arg k "$key" '.known_doc_drift[$k].entries[] | .path, .measured_producer' "$REGISTRY")"
	done <<< "$(jq -r '.known_doc_drift | keys[] | select(startswith("_") | not)' "$REGISTRY")"
	[ "$bad" -eq 0 ] && pass "T17 all ${n} known_doc_drift rows are still wrong in the doc and still corrected here"
}
t17

# ---------------------------------------------------------------------------
# T18 — kind=record must be earned by a digest key, never by a date key.
# This encodes the mistake found in review on 2026-08-07: api/peers-history/
# was classified record on the strength of "one file per day", but its
# producer rewrites the CURRENT day's member on every run
# (scripts/peer-validators.sh:254-256, :361), so the published URL for today
# resolves to different bytes several times a day. A date is a promise about
# naming; only a content-derived key is a promise about bytes. The second rule
# keeps the qualifier honest: becomes_record_after may only WIDEN what a
# knowing consumer may do, so it may never sit on an entry whose .kind already
# grants pin permission.
# ---------------------------------------------------------------------------
t18() {
	local path pattern kind bad=0 n=0
	while IFS= read -r path && IFS= read -r pattern; do
		[ -n "$path" ] || continue
		n=$((n + 1))
		case "$pattern" in
			*'[a-f0-9]{64}'*) ;;
			*)
				fail "T18 ${path} is kind=record but its member_pattern is not keyed by a 64-hex digest: ${pattern}"
				note "     a date or sequence key names a file; it does not promise its bytes. Use kind=stream + becomes_record_after."
				bad=1
				;;
		esac
	done <<< "$(jq -r '.publications[] | select(.kind == "record") | .path, (.member_pattern // "")' "$REGISTRY")"

	while IFS= read -r path; do
		[ -n "$path" ] || continue
		kind="$(kind_of "$path")"
		[ "$kind" = "stream" ] || { fail "T18 ${path} carries becomes_record_after but kind=${kind}; the qualifier may only widen, never restate"; bad=1; }
	done <<< "$(jq -r '.publications[] | select(has("becomes_record_after")) | .path' "$REGISTRY")"

	[ "$bad" -eq 0 ] && pass "T18 all ${n} kind=record entries are keyed by a content digest, and every becomes_record_after sits on a kind=stream entry"
}
t18

# ---------------------------------------------------------------------------
# T19 — forward regression: this suite must behave correctly against the
# manifest the 2026-09-04 issuance will produce, not only against the one
# committed today.
#
# Why this exists: T6/T7/T14 read the CURRENT signed identity.json, in which
# every entry still carries a sha256. That made two defects invisible.
#   (1) identity_pins() emitted a `.sha256` row per ENTRY rather than per
#       PRESENT DIGEST, so against a post-C4 manifest T7 found a "live" pin for
#       every acknowledged violation and passed while the manifest pinned no
#       stream at all — a false pass on the expiry check itself.
#   (2) T14 compared a pin's URL path against publications[].path by exact
#       equality, so a pin on a content-addressed member of api/archive/ could
#       not be declared by any row: the directory row is the only place a
#       pinned_by can live for it.
# Both would first have fired on transition day, inside the commit that lands
# the re-issued manifest, where publication.json edits alone could not clear
# them. The fixtures below are synthetic and hermetic; nothing here reads or
# writes a real artifact.
# ---------------------------------------------------------------------------
t19() {
	local fx_id="$TMPDIR_T/t19-identity.json"
	local reg_stale="$TMPDIR_T/t19-registry-stale.json"
	local reg_done="$TMPDIR_T/t19-registry-updated.json"
	local arc_hex="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	local zero="1111111111111111111111111111111111111111111111111111111111111111"
	local out bad=0

	# A manifest in the post-C4 shape: streams listed without sha256, static
	# and record entries pinned, plus the new incidents schema pin.
	jq --arg h "$arc_hex" --arg z "$zero" '
		["evidence_json","validator_json","cycle_history_jsonl","uptime_cycles_json"] as $streams
		| .artifact_manifest |= with_entries(
			. as $e
			| if ($streams | index($e.key))
			  then .value |= (del(.sha256) + {kind: "stream"})
			  else .value |= (. + {kind: "static"})
			  end)
		| .artifact_manifest.incidents_json += {
			schema_url: "https://metal.freedom-yield.com/api/incidents.schema.v1.json",
			schema_sha256: $z }
		| .artifact_manifest.anchor_source_archive_json = {
			url: ("https://metal.freedom-yield.com/api/archive/anchor-source-" + $h + ".json"),
			kind: "record",
			sha256: $z }
	' "$IDENTITY" > "$fx_id" || { fail "T19 could not build the post-C4 manifest fixture"; return; }

	# The "stale" registry is SYNTHESISED into the pre-C4 shape, never copied
	# from the live one. Copying it was the first version of this case and it
	# was wrong in a way that only bites later: on 2026-09-04, the moment the
	# operator performs the step-4b cleanup, the live registry stops being
	# stale, the fixture stops being a stale fixture, and the two assertions
	# below flip to red — inside the very commit that did the right thing.
	# Measured on a tree with step 4b applied: "T7 did NOT flag the 4 expired
	# violations" / "T14 did NOT flag the stale pinned_by set", PASS=23 FAIL=2.
	# That is the same transition-day dead end this case exists to prevent,
	# merely relocated into the test. Forcing both states here makes T19 give
	# the same verdict before and after the cleanup.
	jq '
		.known_kind_violations.violations = {
			"evidence_json.sha256":       { path: "api/evidence.json",       reason: "T19 fixture" },
			"validator_json.sha256":      { path: "api/validator.json",      reason: "T19 fixture" },
			"uptime_cycles_json.sha256":  { path: "api/uptime-cycles.json",  reason: "T19 fixture" },
			"cycle_history_jsonl.sha256": { path: "api/cycle-history.jsonl", reason: "T19 fixture" }
		}
		| .publications |= map(
			. as $row
			| if   $row.path == "api/evidence.json"       then .pinned_by = ["api/identity.json#artifact_manifest.evidence_json.sha256"]
			  elif $row.path == "api/validator.json"      then .pinned_by = ["api/identity.json#artifact_manifest.validator_json.sha256"]
			  elif $row.path == "api/uptime-cycles.json"  then .pinned_by = ["api/identity.json#artifact_manifest.uptime_cycles_json.sha256"]
			  elif $row.path == "api/cycle-history.jsonl" then .pinned_by = ["api/identity.json#artifact_manifest.cycle_history_jsonl.sha256"]
			  elif $row.path == "api/incidents.schema.v1.json" then .pinned_by = []
			  elif $row.path == "api/archive/"                 then .pinned_by = []
			  else . end)
	' "$REGISTRY" > "$reg_stale" || { fail "T19 could not synthesise the pre-C4 registry fixture"; return; }

	# The registry as the 2026-09-04 commit must leave it — derived from the
	# SYNTHETIC stale fixture, so this pair is a genuine before/after of the
	# step-4b edit rather than a comparison against whatever is on disk today.
	jq '
		.known_kind_violations.violations = {}
		| .publications |= map(
			. as $row
			| if (["api/evidence.json","api/validator.json","api/cycle-history.jsonl","api/uptime-cycles.json"] | index($row.path))
			then .pinned_by = []
			elif .path == "api/incidents.schema.v1.json"
			then .pinned_by = ["api/identity.json#artifact_manifest.incidents_json.schema_sha256"]
			elif .path == "api/archive/"
			then .pinned_by = ["api/identity.json#artifact_manifest.anchor_source_archive_json.sha256"]
			else . end)
	' "$reg_stale" > "$reg_done" || { fail "T19 could not build the updated-registry fixture"; return; }

	# The fixtures must actually contain what the case claims to exercise. A
	# renamed or deleted publication row would otherwise silently shrink the
	# test instead of failing it.
	# n_pins counts PINS the way identity_pins() does — a payload sha256 and a
	# schema_sha256 are each one pin — not entries.
	local n_pins n_unpinned n_rows
	n_pins="$(IDENTITY="$fx_id" identity_pins | grep -c .)"
	n_unpinned="$(jq -r '[.artifact_manifest[] | select(has("sha256") | not)] | length' "$fx_id")"
	[ "$n_pins" -eq 6 ] && [ "$n_unpinned" -eq 4 ] \
		|| { fail "T19 manifest fixture is not the shape this case tests (${n_pins} pins / ${n_unpinned} unpinned entries, want 6/4) — a leaf was added or removed upstream"; return; }
	n_rows="$(jq -r '[.publications[] | select(.path == "api/incidents.schema.v1.json" or .path == "api/archive/")] | length' "$reg_stale")"
	[ "$n_rows" -eq 2 ] \
		|| { fail "T19 registry fixture is missing api/incidents.schema.v1.json and/or api/archive/ (found ${n_rows} of 2) — the rows step 4b writes to no longer exist"; return; }

	# The stale fixture must be STALE no matter what the live registry says.
	# This is the assertion that would have caught the copy: on a tree where
	# step 4b has already been applied, `cp "$REGISTRY"` yields 0 violations
	# and 0 stream pins here, and the two comparisons below would then be
	# checking nothing while still reporting green.
	local n_viol n_streampins
	n_viol="$(jq -r '.known_kind_violations.violations | length' "$reg_stale")"
	n_streampins="$(jq -r '[ .publications[]
		| select([.pinned_by[]? | test("artifact_manifest\\.(evidence_json|validator_json|uptime_cycles_json|cycle_history_jsonl)\\.sha256$")] | any)
		] | length' "$reg_stale")"
	if [ "$n_viol" -eq 4 ] && [ "$n_streampins" -eq 4 ]; then
		pass "T19 the stale fixture is synthesised, not copied (4 violations + 4 stream pins, independent of the live registry)"
	else
		fail "T19 the stale fixture is not stale (${n_viol} violations / ${n_streampins} stream pins, want 4/4) — it is tracking the live registry instead of pinning the pre-C4 state"
		return
	fi

	# Run the real checks against the fixtures in a subshell so their pass/fail
	# counters and their globals cannot leak into this suite's own tally.
	run_against() { ( IDENTITY="$1"; REGISTRY="$2"; PASS=0; FAIL=0; t6; t7; t14 ) 2>&1; }

	# (1) post-C4 manifest + registry NOT yet updated: the suite must say so.
	out="$(run_against "$fx_id" "$reg_stale")"
	if printf '%s' "$out" | grep -q '^FAIL  T7 .*OBSOLETE baseline entry'; then
		pass "T19 post-C4 manifest + stale registry: T7 reports the expired kind violations (no false pass)"
	else
		fail "T19 post-C4 manifest + stale registry: T7 did NOT flag the 4 expired violations"
		note "$(printf '%s' "$out" | grep '^FAIL' | head -3 | tr '\n' '; ')"
		bad=1
	fi
	if printf '%s' "$out" | grep -q '^FAIL  T14'; then
		pass "T19 post-C4 manifest + stale registry: T14 reports the pinned_by drift"
	else
		fail "T19 post-C4 manifest + stale registry: T14 did NOT flag the stale pinned_by set"
		bad=1
	fi

	# (2) post-C4 manifest + the registry edit the report prescribes: GREEN.
	# This is the assertion that proves the target state is reachable, i.e.
	# that transition day is not a dead end.
	out="$(run_against "$fx_id" "$reg_done")"
	if printf '%s' "$out" | grep -q '^FAIL'; then
		fail "T19 post-C4 manifest + updated registry is NOT green — the 2026-09-04 target state is unreachable"
		printf '%s\n' "$out" | grep -E '^(FAIL|      )' | head -8 | sed 's/^/      /'
		bad=1
	else
		pass "T19 post-C4 manifest + updated registry: T6/T7/T14 all green (transition-day target state is reachable)"
	fi

	# (3) the record pin must resolve through the directory row, not by luck.
	local row
	row="$(registry_row_for_path "api/archive/anchor-source-${arc_hex}.json" "$reg_done")"
	[ "$row" = "api/archive/" ] \
		&& pass "T19 a content-addressed archive member resolves to the api/archive/ row" \
		|| { fail "T19 archive member resolved to '${row:-<none>}', not api/archive/"; bad=1; }
	row="$(registry_row_for_path "api/archive/not-a-digest.json" "$reg_done")"
	[ -z "$row" ] \
		&& pass "T19 a non-matching archive member resolves to NO row (member_pattern governs)" \
		|| { fail "T19 'api/archive/not-a-digest.json' wrongly resolved to '${row}'"; bad=1; }

	# (4) MUTATION: restore the old unconditional enumeration and require the
	# false pass to come back. Without this, (1) could be passing for an
	# unrelated reason.
	identity_pins_unconditional() {
		jq -r '
			.artifact_manifest | to_entries[] |
			( [ (.key + ".sha256"), (.value.url | sub("^https?://[^/]+/"; "")) ] | @tsv ),
			( select(.value.schema_sha256 != null)
			  | [ (.key + ".schema_sha256"), (.value.schema_url | sub("^https?://[^/]+/"; "")) ] | @tsv )
		' "$IDENTITY"
	}
	out="$( ( IDENTITY="$fx_id"; REGISTRY="$reg_stale"; PASS=0; FAIL=0
	          eval "$(declare -f identity_pins_unconditional | sed '1s/identity_pins_unconditional/identity_pins/')"
	          t7 ) 2>&1 )"
	if printf '%s' "$out" | grep -q '^PASS  T7'; then
		pass "T19 MUTATION: the pre-fix enumeration reproduces the T7 false pass (the fix is load-bearing)"
	else
		fail "T19 MUTATION: the pre-fix enumeration did not reproduce the false pass — (1) may be passing for another reason"
		bad=1
	fi

	[ "$bad" -eq 0 ] || true
}
t19

# ---------------------------------------------------------------------------
# T20 — pin_policy wording (S3): the `record` kind's defining clause must not
# drift into independently-reworded copies. The api/archive/ row's
# record_caveat originally asserted this obligation itself, naming
# docs/IDENTITY_VERIFICATION.md and identity.json's pin_policy as carrying
# "that same wording ... in step with this row" — an unchecked claim, which is
# why this test was written. That sentence has since been corrected twice
# against what T20 actually does: on 2026-08-17 for naming
# docs/IDENTITY_VERIFICATION.md (not checked here — see below), and again the
# same day for naming THIS ROW as the canonical source. It is not: the clause
# T20 compares against lives in .kind_definitions.record, the taxonomy
# authority at the top of the registry, and record_caveat is unchecked prose.
# Do not re-derive the phrase below from record_caveat.
#
# What IS checked here, and what is deliberately NOT:
#   - kind_definitions.record (this registry, the taxonomy authority), the
#     `kind` enum's description in public/api/identity.schema.v1.json, and
#     the --arg pin_policy_rule literal in
#     scripts/operator-local/gen-identity.sh must all contain the same
#     canonical sentence VERBATIM (a substring check, not whole-block
#     equality: the three documents are deliberately different lengths for
#     different audiences — a terse schema one-liner, a verbose registry
#     definition with its own correction history, and an operational rule
#     embedded in signed output — so forcing them byte-identical end to end
#     would make at least two of them unreadable).
#   - docs/IDENTITY_VERIFICATION.md is judged NOT a fit for this check: it is
#     operator-facing prose that explains the same facts in its own voice
#     (see its own sentence: "The rule is also restated in-band ... so the
#     manifest explains itself without reference to this document" — it
#     explicitly does not claim to restate pin_policy verbatim). Forcing
#     literal-text sync there would fight the document's own purpose. This
#     was a judgment call, not an oversight — recorded here so it is
#     reviewable rather than silent.
#   - gen-identity.sh's literal pin_policy_* strings vs
#     public/api/identity.example.json's pin_policy object ARE held to full
#     byte equality, but as a RUNTIME-BEHAVIOUR case (does the actual
#     generator output match the committed preview?) — see
#     tests/identity-kind-discipline/test-gen-identity-kind-discipline.sh
#     case 1, not here.
# ---------------------------------------------------------------------------
t20() {
	local phrase bad=0 field_value

	# Review finding (I-3, 2026-08-17): the original implementation grepped
	# the WHOLE FILE for each source, then named a SPECIFIC field in its PASS
	# message ("kind_definitions.record carries..."). A file-wide grep passes
	# even when the phrase is moved to an unrelated key elsewhere in the same
	# file — measured: relocating the clause from kind_definitions.record to
	# a decoy key (_scratch_note) left T20 green. Fixed to extract the exact
	# field's VALUE first (jq for the two JSON sources; the single physical
	# line the --arg is declared on for the bash source, so a comment or an
	# unrelated string elsewhere in gen-identity.sh cannot satisfy this
	# either) and grep only that.
	phrase="derived from a digest of the content it addresses, so whatever that digest covers cannot change without the name changing too"

	field_value="$(jq -r '.kind_definitions.record // ""' "$REGISTRY")"
	if printf '%s' "$field_value" | grep -qF -- "$phrase"; then
		pass "T20 deploy/publication.json's .kind_definitions.record field (not just the file) carries the canonical record clause"
	else
		fail "T20 deploy/publication.json's .kind_definitions.record field does NOT carry the canonical record clause verbatim — has it been reworded without propagating?"
		bad=1
	fi

	field_value="$(jq -r '.properties.artifact_manifest.additionalProperties.properties.kind.description // ""' "$IDENTITY_SCHEMA")"
	if printf '%s' "$field_value" | grep -qF -- "$phrase"; then
		pass "T20 public/api/identity.schema.v1.json's .kind.description field (not just the file) carries the canonical record clause"
	else
		fail "T20 public/api/identity.schema.v1.json's .kind.description field does NOT carry the canonical record clause verbatim — DRIFTED from deploy/publication.json"
		bad=1
	fi

	# gen-identity.sh is bash, not JSON, so there is no field to jq out —
	# but grepping the whole file has the same decoy risk (an unrelated
	# comment mentioning the same words would satisfy a whole-file grep).
	# Narrowed to the single physical line the --arg is declared on: this
	# script writes pin_policy_rule as one unbroken line (measured), so a
	# line-scoped grep is exactly field-scoped here.
	field_value="$(grep -F -- 'pin_policy_rule "' "$GEN_IDENTITY")"
	if [ -n "$field_value" ] && printf '%s' "$field_value" | grep -qF -- "$phrase"; then
		pass "T20 scripts/operator-local/gen-identity.sh's pin_policy_rule line (not just the file) carries the canonical record clause"
	else
		fail "T20 scripts/operator-local/gen-identity.sh's pin_policy_rule line does NOT carry the canonical record clause verbatim — DRIFTED from deploy/publication.json"
		bad=1
	fi

	[ "$bad" -eq 0 ] && pass "T20 the record-kind defining clause is present verbatim, in the specific field/line, in all 3 authoritative sources"
}
t20

# ---------------------------------------------------------------------------
# T21 — cross-implementation agreement (I-5, 2026-08-17; extended to the third
# copy the same day, N-3).
#
# THREE copies of the same "which registry row governs this path, and what is
# its kind" rule exist in this repository:
#
#   (a) this file's own registry_row_for_path() + kind_of() — bash driving two
#       separate jq calls (find the governing row, then read that row's kind)
#   (b) scripts/check-identity-pins.sh's registry_kind_of() — ONE jq program
#       doing both, run by the CI gate and by the daily cron
#   (c) scripts/operator-local/gen-identity.sh's registry_kind_of_path() — the
#       same single-program shape, run by the operator on the Mac. This is the
#       copy that COMPOSES the manifest: at the 2026-09-04 cycle transition it
#       is what decides which artifacts get a sha256 into SIGNED output.
#
# "正しい状態が1箇所に無い" is the defect this refactor programme exists to
# close, so a resolution rule living in three places is the pattern under
# repair, and (c) is the copy with the most authority of the three. Unifying
# them is not available: (a) is test-local bash, and (b) and (c) must each run
# standalone — on the validator host and on the operator's Mac respectively —
# with no shared library between them. What IS available is making the copies
# machine-checked equal rather than hand-checked equal, which is this case.
#
# Nothing verified any of it before this test existed, and (a) vs (b) had in
# fact diverged once already: a `select($p | startswith(.path))` bug in the
# checker's copy silently rebound `.` to a string and errored on every
# directory-row (kind=record) path, undetected until an unrelated case
# (tests/identity-pins/test-check-identity-pins.sh's k7R) tripped over it by
# accident. Until 2026-08-17 this case disclosed (c) as an uncovered gap; N-3
# closed it, because the copy that composes a signed manifest is the last one
# that should be running unchecked.
#
# Both foreign copies are EXTRACTED, never re-transcribed:
#   (b) the exact bytes between the two T21-SENTINEL comment lines inside
#       registry_kind_of(), run standalone via `jq -f`
#   (c) the exact source lines of registry_kind_of_path(), located BY FUNCTION
#       NAME and sourced into a subshell — so what runs here is the
#       generator's actual function, and nothing in scripts/ had to be edited
#       for it to be covered
#
# A re-transcription would be a fourth untested copy and would prove nothing.
# The two MUTATION blocks at the end rule out the remaining way this could be
# vacuous — extractor and extracted breaking the same way — by doctoring each
# SIDE of the comparison in turn and requiring the disagreement to surface.
# ---------------------------------------------------------------------------
t21() {
	local prog_file gen_src mut_file mut_src needle ndis
	local bad=0 n=0 n_record=0 n_norow=0 path own_kind checker_kind gen_kind

	# ---- copy (b): the checker's jq program, verbatim between the sentinels
	prog_file="${TMPDIR_T}/checker-registry-kind-of.jq"
	sed -n '/# T21-SENTINEL-BEGIN/,/# T21-SENTINEL-END/p' "${REPO_ROOT}/scripts/check-identity-pins.sh" > "$prog_file"
	if [ ! -s "$prog_file" ]; then
		fail "T21 could not extract registry_kind_of's jq program from scripts/check-identity-pins.sh — sentinel markers missing?"
		return
	fi

	# ---- copy (c): the generator's function, located by name
	gen_src="${TMPDIR_T}/gen-registry-kind-of-path.sh"
	extract_shell_fn "$GEN_IDENTITY" registry_kind_of_path > "$gen_src"
	assert_extracted_fn "$gen_src" registry_kind_of_path "T21" || return
	# The extraction must contain the parts that make it a registry resolver.
	# A function that was gutted upstream (or an awk range that grabbed some
	# other block that happens to end in a brace) would still satisfy the
	# shape check above while resolving nothing.
	for needle in 'publications[]' 'member_pattern' 'PUBLICATION_REGISTRY' '--arg p'; do
		grep -qF -- "$needle" "$gen_src" || {
			fail "T21 the extracted registry_kind_of_path() does not contain '${needle}' — the extraction is not the resolver it claims to be"
			return
		}
	done

	run_checker_kind_of() { jq -r --arg p "$1" -f "$prog_file" "$REGISTRY"; }
	# gen_kind_via <extracted-resolver-file> <path> — run the generator's own
	# function in a subshell, with the one variable it reads pointed at this
	# suite's registry.
	gen_kind_via() { ( PUBLICATION_REGISTRY="$REGISTRY"; . "$1"; registry_kind_of_path "$2" ); }

	compare_one() {
		n=$((n + 1))
		own_kind="$(kind_of "$1")"
		checker_kind="$(run_checker_kind_of "$1")"
		gen_kind="$(gen_kind_via "$gen_src" "$1")"
		if [ "$own_kind" != "$checker_kind" ]; then
			fail "T21 ${1}: this suite's kind_of()='${own_kind}' but scripts/check-identity-pins.sh's registry_kind_of()='${checker_kind}'"
			bad=1
		fi
		if [ "$own_kind" != "$gen_kind" ]; then
			fail "T21 ${1}: this suite's kind_of()='${own_kind}' but scripts/operator-local/gen-identity.sh's registry_kind_of_path()='${gen_kind}'"
			bad=1
		fi
		case "$own_kind" in
			record) n_record=$((n_record + 1)) ;;
			"")     n_norow=$((n_norow + 1)) ;;
		esac
	}

	while IFS= read -r path; do
		[ -n "$path" ] || continue
		compare_one "$path"
	done <<< "$(probe_paths)"

	# The comparison is only worth something if the probe set actually
	# exercises BOTH resolution branches. Measured, not assumed: an agreement
	# established over exact rows alone would hold for three implementations
	# that all get directory members wrong in the same way.
	if [ "$n" -lt 20 ] || [ "$n_record" -lt 1 ] || [ "$n_norow" -lt 1 ]; then
		fail "T21 the probe set is too weak to prove agreement (${n} paths; ${n_record} resolving to kind=record, ${n_norow} resolving to no row at all) — the directory-row branch must be exercised in both outcomes"
		bad=1
	fi

	if [ "$bad" -eq 0 ]; then
		pass "T21 all THREE registry-kind resolvers agree on all ${n} probe paths (${n_record} via a directory row, ${n_norow} governed by no row): this suite's kind_of(), scripts/check-identity-pins.sh's registry_kind_of() (jq extracted verbatim), scripts/operator-local/gen-identity.sh's registry_kind_of_path() (function extracted by name)"
	else
		note "T21 checked ${n} path(s); see FAIL lines above for the disagreements"
	fi

	# count_disagreements <resolver-file> [reference fn] — how many probe paths
	# the extracted resolver and the reference disagree about.
	count_disagreements() {
		local src="$1" ref="${2:-kind_of}" p d=0
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			[ "$("$ref" "$p")" = "$(gen_kind_via "$src" "$p")" ] || d=$((d + 1))
		done <<< "$(probe_paths)"
		printf '%s' "$d"
	}

	# ---- MUTATION 1 (foreign side): doctor the GENERATOR's resolver so it
	# ignores member_pattern, extract THAT, and require the comparison to
	# notice. Without it, the agreement above could be an artifact of the
	# extraction failing over to something that always matches.
	mut_file="${TMPDIR_T}/gen-identity-mutant.sh"
	mut_src="${TMPDIR_T}/gen-registry-kind-of-path-mutant.sh"
	sed '/test(.*member_pattern/d' "$GEN_IDENTITY" > "$mut_file"
	if cmp -s "$mut_file" "$GEN_IDENTITY"; then
		fail "T21 MUTATION 1 could not doctor gen-identity.sh (its member_pattern guard line was not found) — the mutation proof did not run"
		bad=1
	else
		extract_shell_fn "$mut_file" registry_kind_of_path > "$mut_src"
		if assert_extracted_fn "$mut_src" registry_kind_of_path "T21 MUTATION 1"; then
			ndis="$(count_disagreements "$mut_src")"
			if [ "$ndis" -ge 1 ]; then
				pass "T21 MUTATION 1: dropping the member_pattern guard from gen-identity.sh's resolver is detected (${ndis} disagreement(s)) — the third copy is really being executed here, not assumed"
			else
				fail "T21 MUTATION 1: a doctored gen-identity.sh resolver still agreed on every probe path — the cross-check of the third copy is not load-bearing"
				bad=1
			fi
		else
			bad=1
		fi
	fi

	# ---- MUTATION 2 (reference side): hold the REAL extracted resolver against
	# a deliberately weaker reference — exact-path matching only, the most
	# plausible way this suite's own kind_of() could regress — and require the
	# disagreement to surface. Mutation 1 alone cannot rule out a comparison
	# that is blind in this direction.
	kind_of_exact_only() {
		jq -r --arg p "$1" '[ .publications[] | select(.path == $p) | .kind ] | first // ""' "$REGISTRY"
	}
	ndis="$(count_disagreements "$gen_src" kind_of_exact_only)"
	if [ "$ndis" -ge 1 ]; then
		pass "T21 MUTATION 2: an exact-match-only reference disagrees with the real gen-identity.sh resolver on ${ndis} probe path(s) — a regression on the reference side of the comparison is detected too"
	else
		fail "T21 MUTATION 2: an exact-match-only reference agreed with gen-identity.sh's resolver everywhere — the probe set never exercises directory-row resolution"
		bad=1
	fi
}
t21

# ---------------------------------------------------------------------------
# T22 — url→path normalisation (M-3, 2026-08-17): the DECISION not to unify,
# made checkable instead of asserted.
#
# "Strip the scheme and host off a manifest URL to get a path relative to
# public/" is implemented FOUR times:
#
#   (1) scripts/check-identity-pins.sh    url_to_public_path()    bash
#   (2) scripts/operator-local/gen-identity.sh url_to_registry_path() bash
#   (3) this file's identity_pins()       jq  sub("^https?://[^/]+/"; "")
#   (4) tests/identity-pins/'s K8_KIND_OF_JQ  jq, the same sub()
#
# FOUR is measured, not asserted. Grepping tests/ and scripts/ for the literal
# jq expression sub("^https?://[^/]+/"; "") returns NINE lines (2026-08-17,
# after N-1). THREE of them are implementations (3) and (4) — (3) spells it
# twice, once per pin kind, and (4) once. The other six are not
# implementations: two lines of T19's mutation fixture below (a deliberate
# reproduction of the OLD implementation, not a copy of the current one),
# jq_spelling_retyped() below (this case's own re-transcription, disclosed
# under "What (b) does NOT check"), one line of prose in
# scripts/check-identity-pins.sh, and two lines inside this comment block —
# item (3) above and this sentence's own quotation of the pattern.
# tests/identity-pins/ carried a FIFTH implementation copy — its k8
# postcondition counter — until N-1 collapsed it into the shared
# K8_KIND_OF_JQ prelude named above; that copy was guarded by nothing and
# produced a 空振り PASS.
#
# The review that raised this left it as "duplication across a bash/jq
# boundary, covered by text matching, do not force a single implementation".
# That judgment is kept — (1) and (2) run inside two standalone scripts that
# share no library, and (3)/(4) run INSIDE jq programs, where calling out to a
# shell function is not available at all. Collapsing four into one would mean
# either shelling out from jq or reimplementing jq's regex in bash: strictly
# more machinery guarding a two-line string operation.
#
# What is NOT kept is leaving that judgment as prose. This case replaces the
# text matching with measurement:
#
#   a. (1) and (2) are extracted BY NAME and required to return the same
#      (exit status, stdout) pair for every probe URL — the equality the
#      comment in each script asserts about the other, now checked.
#   b. the jq SPELLING of the conversion is required to agree with (1) for
#      every URL the SIGNED manifest actually carries — the only input domain
#      where a disagreement could misclassify a real pin. READ THE LIMIT ON
#      THIS CAREFULLY: see "What (b) does NOT check" below.
#   c. the recorded REASON for keeping the jq form separate is that it
#      deliberately behaves differently OUTSIDE that domain. Measured
#      2026-08-17: for "ftp://h/api/x.json" the bash copies strip the host and
#      return "api/x.json" while the jq sub() leaves the string untouched, and
#      for an input with no path at all the bash copies REFUSE (exit 1, which
#      is what makes check-identity-pins.sh die on a malformed pin url) while
#      the jq sub() silently returns the input. If that divergence ever
#      disappears, the justification for four implementations has expired and
#      this case says so rather than staying quietly green.
#
# What (b) does NOT check (review finding I-1, 2026-08-17)
# -------------------------------------------------------
# (b) does NOT execute copy (3) or copy (4). The jq program it compares
# against is jq_spelling_retyped() below — the same expression TYPED OUT
# AGAIN here, not extracted from either. So (b) measures "the jq semantics
# and the bash semantics agree on the manifest's URLs"; it does NOT measure
# "identity_pins() and K8_KIND_OF_JQ still contain that expression".
#
# This is the very re-transcription T21 refuses a few hundred lines up ("A
# re-transcription would be a fourth untested copy and would prove nothing").
# It is left standing here, knowingly, because copies (3) and (4) are already
# carried behaviourally by other cases — measured 2026-08-17 by mutating each
# one and observing which suite went red:
#
#   mutate identity_pins()'s sub()  -> T22 stays 4/4 PASS; T7 (4 FAIL), T14
#                                      (9 FAIL), T19 and T15 go red
#   mutate K8_KIND_OF_JQ's sub()    -> this whole suite stays green; the k8U
#                                      unit cases and k8 in
#                                      tests/identity-pins/ go red (5 FAIL,
#                                      re-measured 2026-08-17 after N-1)
#
# So nothing is unguarded, but the guard is not here, and this case must not
# be read as providing it. Extracting (3) and (4) the way T21 extracts the
# two bash resolvers is entirely possible — identity_pins() is a shell
# function in this file and K8_KIND_OF_JQ is a plain variable assignment — and
# is DESCOPED, not blocked. It is the obvious next revision of this case.
#
# So the honest summary, which the assertions below enforce rather than
# claim: two of the four implementations are machine-checked identical to
# each other, the jq SEMANTICS are machine-checked compatible with them on
# the domain that matters (the two jq copies' own texts are held by T7/T14
# and k8U instead), and the reason they are not one implementation is itself
# an expiring declaration.
# ---------------------------------------------------------------------------
t22() {
	local a_src b_src mut_src bad=0 n=0 n_refuse=0 n_real=0 n_div=0 mdiff=0 u

	a_src="${TMPDIR_T}/checker-url-to-public-path.sh"
	b_src="${TMPDIR_T}/gen-url-to-registry-path.sh"
	extract_shell_fn "${REPO_ROOT}/scripts/check-identity-pins.sh" url_to_public_path   > "$a_src"
	extract_shell_fn "$GEN_IDENTITY"                               url_to_registry_path > "$b_src"
	assert_extracted_fn "$a_src" url_to_public_path   "T22" || return
	assert_extracted_fn "$b_src" url_to_registry_path "T22" || return

	# "<exit status>|<stdout>", so a REFUSAL and an empty result stay
	# distinguishable — the refusal is the load-bearing half here (it is what
	# makes check-identity-pins.sh die on a malformed pin url instead of
	# comparing against nothing).
	url_via() {
		local out rc
		out="$( . "$1"; "$2" "$3" )"; rc=$?
		printf '%s|%s' "$rc" "$out"
	}
	# NAMED for what it is: the jq expression RE-TYPED here, not extracted
	# from identity_pins() (copy 3) or K8_KIND_OF_JQ (copy 4). Comparing
	# against it measures jq-vs-bash SEMANTICS, never that those two copies
	# still spell it this way. See "What (b) does NOT check" in the header
	# before strengthening any claim built on this.
	jq_spelling_retyped() { jq -rn --arg u "$1" '$u | sub("^https?://[^/]+/"; "")'; }

	manifest_urls() { jq -r '.artifact_manifest[]? | (.url // empty), (.schema_url // empty)' "$IDENTITY"; }
	url_probes() {
		manifest_urls
		printf '%s\n' \
			"https://metal.freedom-yield.com/api/archive/anchor-source-0000000000000000000000000000000000000000000000000000000000000001.json" \
			"http://example.test/a/b/c.json" \
			"https://example.test/x" \
			"https://example.test//api/x.json" \
			"https://example.test/" \
			"https://example.test" \
			"ftp://example.test/api/x.json" \
			"not-a-url"
	}

	# ---- a. the two bash copies must be behaviourally identical
	while IFS= read -r u; do
		[ -n "$u" ] || continue
		n=$((n + 1))
		local ra rb
		ra="$(url_via "$a_src" url_to_public_path   "$u")"
		rb="$(url_via "$b_src" url_to_registry_path "$u")"
		case "$ra" in 1\|*) n_refuse=$((n_refuse + 1)) ;; esac
		if [ "$ra" != "$rb" ]; then
			fail "T22 '${u}': check-identity-pins.sh's url_to_public_path -> ${ra} but gen-identity.sh's url_to_registry_path -> ${rb} (rc|stdout)"
			bad=1
		fi
	done <<< "$(url_probes)"
	if [ "$n" -lt 8 ] || [ "$n_refuse" -lt 1 ]; then
		fail "T22 the probe set is too weak (${n} URLs, ${n_refuse} of them refused) — a comparison that never exercises the refusal path proves nothing about the half that matters"
		bad=1
	elif [ "$bad" -eq 0 ]; then
		pass "T22 the two BASH url→path copies agree on exit status AND stdout for all ${n} probe URLs (${n_refuse} of which they both refuse)"
	fi

	# ---- b. the jq SEMANTICS must agree on the domain that actually occurs.
	# Not a check on copies (3)/(4) themselves — see "What (b) does NOT
	# check" in the header. Those are carried by T7/T14 and by k8U in
	# tests/identity-pins/.
	while IFS= read -r u; do
		[ -n "$u" ] || continue
		n_real=$((n_real + 1))
		if [ "$(url_via "$a_src" url_to_public_path "$u")" != "0|$(jq_spelling_retyped "$u")" ]; then
			fail "T22 '${u}' is a URL the signed manifest carries, and the bash normalisation disagrees with the jq sub() semantics on it"
			bad=1
		fi
	done <<< "$(manifest_urls)"
	if [ "$n_real" -lt 1 ]; then
		fail "T22 the signed manifest carried no URL to compare — this half of the case did not run"
		bad=1
	else
		pass "T22 the jq sub() SEMANTICS agree with the bash form on all ${n_real} URL(s) the signed manifest carries (semantics only — this does not execute identity_pins() or K8_KIND_OF_JQ; T7/T14 and k8U hold those)"
	fi

	# ---- c. the reason for keeping them separate must still be true
	for u in "ftp://example.test/api/x.json" "https://example.test"; do
		[ "$(url_via "$a_src" url_to_public_path "$u")" != "0|$(jq_spelling_retyped "$u")" ] && n_div=$((n_div + 1))
	done
	if [ "$n_div" -eq 2 ]; then
		pass "T22 the recorded bash/jq divergence is still real (non-http(s) scheme, and a URL with no path) — the reason for not folding the jq copies in has not expired"
	else
		fail "T22 OBSOLETE justification: the bash and jq normalisations now agree even outside the manifest's URL domain (${n_div}/2 divergences left). The reason recorded above for keeping four implementations no longer holds — unify them, or rewrite the reason"
		bad=1
	fi

	# ---- MUTATION: doctor one copy, require the pair comparison to notice
	mut_src="${TMPDIR_T}/gen-url-to-registry-path-mutant.sh"
	awk 'index($0, "rest=\"${rest#") { next } { print }' "$b_src" > "$mut_src"
	if cmp -s "$mut_src" "$b_src"; then
		fail "T22 MUTATION could not doctor the extracted url_to_registry_path() — the mutation proof did not run"
		bad=1
	elif assert_extracted_fn "$mut_src" url_to_registry_path "T22 MUTATION"; then
		while IFS= read -r u; do
			[ -n "$u" ] || continue
			[ "$(url_via "$a_src" url_to_public_path "$u")" = "$(url_via "$mut_src" url_to_registry_path "$u")" ] \
				|| mdiff=$((mdiff + 1))
		done <<< "$(url_probes)"
		if [ "$mdiff" -ge 1 ]; then
			pass "T22 MUTATION: dropping the host-stripping step from gen-identity.sh's url_to_registry_path is detected on ${mdiff} probe URL(s) — both copies are really being executed here"
		else
			fail "T22 MUTATION: a doctored url_to_registry_path still matched on every probe URL — the pair comparison is not load-bearing"
			bad=1
		fi
	else
		bad=1
	fi
}
t22

# ---------------------------------------------------------------------------
# T15 — mutation self-proof.
# T1-T4 would still pass if the renderer ignored the registry and printed a
# baked-in copy. Break the registry three ways and require the corresponding
# check to go red. Runs against a COPY; the real registry is never written.
# ---------------------------------------------------------------------------
t15() {
	local mutant bad=0
	mutant="${TMPDIR_T}/mutant.json"

	run_mutation() { # $1 label, $2 jq program, $3 artifact, $4... extra render args
		local label="$1" prog="$2" artifact="$3"; shift 3
		jq "$prog" "$REGISTRY" > "$mutant" || { fail "T15 could not build mutant for: ${label}"; bad=1; return; }
		if FYD_PUBLICATION_FILE="$mutant" bash "$RENDER" --check "$artifact" "$@" >/dev/null 2>&1; then
			fail "T15 mutation '${label}' did NOT make ${artifact} red — the check is not reading the registry"
			bad=1
		fi
	}

	# 1. Drop one feed-exclude entry.
	run_mutation "drop api/peers-gini.json from feed_excludes.order" \
		'.derived.feed_excludes.order |= map(select(.path != "api/peers-gini.json"))' \
		feed-excludes

	# 2. Rename one push target.
	run_mutation "rename push_name evidence.json -> evidence2.json" \
		'(.publications[] | select(.path == "api/evidence.json") | .push_name) = "evidence2.json"
		 | (.derived.push_allowlist_case.order) |= map(if . == "evidence.json" then "evidence2.json" else . end)' \
		push-allowlist-case

	# 3. Alter a gitignore comment line by one character.
	run_mutation "change one .gitignore comment byte" \
		'(.derived.gitignore_block.order[] | select(.path == "api/uptime-cycles.json")) |= (. + {comment_before: ["# injected"]})' \
		gitignore-block

	# 4. The kind gate must be reading kinds, not a constant: flip a static
	#    pinned artifact to stream and require T6's logic to find a NEW
	#    violation.
	jq '(.publications[] | select(.path == "api/incidents.json") | .kind) = "stream"' "$REGISTRY" > "$mutant"
	local found=0 key path kind
	while IFS=$'\t' read -r key path; do
		[ -n "$key" ] || continue
		kind="$(kind_of "$path" "$mutant")"
		[ "$kind" = "stream" ] || continue
		[ "$(jq -r --arg k "$key" '.known_kind_violations.violations[$k] // empty' "$mutant")" = "" ] && found=1
	done <<< "$(identity_pins)"
	if [ "$found" -ne 1 ]; then
		fail "T15 flipping api/incidents.json to kind=stream did not surface as a NEW kind violation"
		bad=1
	fi

	[ "$bad" -eq 0 ] && pass "T15 mutation self-proof: 4 mutations, each turns its own check red"
}
t15

echo
echo "test-publication-registry.sh summary: PASS=${PASS}  FAIL=${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
