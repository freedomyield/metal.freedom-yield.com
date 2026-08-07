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

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGISTRY="${REPO_ROOT}/deploy/publication.json"
SCHEMA="${REPO_ROOT}/deploy/publication.schema.v1.json"
RENDER="${REPO_ROOT}/scripts/deploy/render-publication.sh"
IDENTITY="${REPO_ROOT}/public/api/identity.json"
SENDER="${REPO_ROOT}/scripts/push-to-web-host.sh"
RECEIVER="${REPO_ROOT}/scripts/deploy/receive-subdir-allowlist.snippet.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
note() { printf '      %s\n' "$1"; }

TMPDIR_T="$(mktemp -d -t fyd-pubreg.XXXXXX)"
trap 'rm -rf "$TMPDIR_T"' EXIT

for f in "$REGISTRY" "$SCHEMA" "$RENDER" "$IDENTITY" "$SENDER" "$RECEIVER"; do
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
	# Lines present canonically but not as built, reduced to the push name.
	added="$(diff "$as_built" "$canonical" | sed -n 's/^> #   \([^ ]*\) .*/\1/p' | sort)"
	if [ "$added" != "$declared" ]; then
		fail "T5  canonical-minus-as-built is not exactly the declared missing_rows"
		note "declared: $(echo "$declared" | tr '\n' ' ')"
		note "actual:   $(echo "$added" | tr '\n' ' ')"
		return
	fi
	# Expiry conditions: each declared row must STILL be (a) absent from the
	# live header table and (b) present in the live enforced case line. Either
	# flipping makes the entry obsolete, and obsolete must be loud.
	local live_doc live_case name obsolete=0
	live_doc="$(bash "$RENDER" --extract push-allowlist-doc)"
	live_case="$(bash "$RENDER" --extract push-allowlist-case)"
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		if printf '%s\n' "$live_doc" | grep -Fq -- "#   ${name} "; then
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
identity_pins() {
	jq -r '
		.artifact_manifest | to_entries[] |
		( [ (.key + ".sha256"), (.value.url        | sub("^https?://[^/]+/"; "")) ] | @tsv ),
		( select(.value.schema_sha256 != null)
		  | [ (.key + ".schema_sha256"), (.value.schema_url | sub("^https?://[^/]+/"; "")) ] | @tsv )
	' "$IDENTITY"
}

kind_of() { jq -r --arg p "$1" '.publications[] | select(.path == $p) | .kind' "$REGISTRY"; }

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
	[ "$bad" -eq 0 ] && pass "T10 all ${n} subdirectory basename patterns are byte-identical in registry, sender and receiver"
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
	local live declared bad=0 n
	live="$(identity_pins | awk -F'\t' '{ printf "api/identity.json#artifact_manifest.%s\t%s\n", $1, $2 }' | sort)"
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
		kind="$(jq -r --arg p "$path" '.publications[] | select(.path == $p) | .kind' "$mutant")"
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
