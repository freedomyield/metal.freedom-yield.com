#!/usr/bin/env bash
# tests/a-chain-profile/no-drift-lib.sh — shared helpers for the
# test-no-drift-*.sh suites (sourced, not a suite itself: it does not match
# the runner's test-*.sh glob).
#
# CHAIN: none. Reads repo files and config/a-chain-profiles.json only.
#
# The no-drift suites pin every chain-specific literal that still lives
# OUTSIDE config/a-chain-profiles.json to the committed profile value, so the
# two copies cannot silently diverge while Tasks 3-5 of the PulseVM
# migration-readiness plan move each script onto scripts/lib/a-chain-profile.sh.
# One suite per source file, so the task that removes a script's literals
# deletes or rewrites only its own suite. A literal that disappears (pattern
# no longer found exactly once) FAILS rather than passes: removing a
# duplicate must be accompanied by updating the suite that pinned it.

ND_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ND_CFG="${ND_REPO_ROOT}/config/a-chain-profiles.json"
ND_PASS=0
ND_FAIL=0

nd_ok()  { ND_PASS=$((ND_PASS + 1)); printf 'PASS %s\n' "$1"; }
nd_bad() { ND_FAIL=$((ND_FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# nd_extract <repo-relative-file> <sed -E regex with ONE capture group>
# Prints the capture; returns 1 unless exactly one line matches.
nd_extract() {
	local file="${ND_REPO_ROOT}/$1" re="$2" out n
	[ -r "$file" ] || { printf 'unreadable: %s\n' "$1" >&2; return 1; }
	out="$(sed -nE "s#${re}#\\1#p" "$file")"
	n="$(printf '%s' "$out" | grep -c '')"
	[ "$n" = "1" ] || { printf 'pattern matched %s lines (want 1) in %s: %s\n' "$n" "$1" "$re" >&2; return 1; }
	printf '%s\n' "$out"
}

# nd_prof <profile> <field> — the committed value (arrays: one per line).
nd_prof() {
	jq -r --arg p "$1" --arg f "$2" \
		'.profiles[$p][$f] | if type == "array" then .[] else tostring end' "$ND_CFG"
}

# nd_eq <name> <repo-file> <regex> <profile> <field> — literal == profile value
nd_eq() {
	local v want
	if ! v="$(nd_extract "$2" "$3" 2>&1)"; then nd_bad "$1" "$v"; return; fi
	want="$(nd_prof "$4" "$5")"
	if [ -n "$v" ] && [ "$v" = "$want" ]; then nd_ok "$1"; else nd_bad "$1" "$2 has '$v', profile $4.$5 is '$want'"; fi
}

# nd_member <name> <repo-file> <regex> <profile> <field> — literal is one of
# the profile list entries
nd_member() {
	local v
	if ! v="$(nd_extract "$2" "$3" 2>&1)"; then nd_bad "$1" "$v"; return; fi
	if [ -n "$v" ] && nd_prof "$4" "$5" | grep -qxF -- "$v"; then nd_ok "$1"
	else nd_bad "$1" "$2 has '$v', not in profile $4.$5: $(nd_prof "$4" "$5" | tr '\n' ' ')"; fi
}

# nd_set_eq <name> <repo-file> <regex> <profile> <field> — a space-separated
# literal list equals the profile list as a SET (order-insensitive)
nd_set_eq() {
	local v a b
	if ! v="$(nd_extract "$2" "$3" 2>&1)"; then nd_bad "$1" "$v"; return; fi
	a="$(printf '%s\n' "$v" | tr ' ' '\n' | sed '/^$/d' | sort)"
	b="$(nd_prof "$4" "$5" | sort)"
	if [ -n "$a" ] && [ "$a" = "$b" ]; then nd_ok "$1"
	else nd_bad "$1" "$2 has {$(printf '%s' "$a" | tr '\n' ' ')}, profile $4.$5 is {$(printf '%s' "$b" | tr '\n' ' ')}"; fi
}

nd_finish() {
	echo "---"
	echo "$1: PASS=${ND_PASS} FAIL=${ND_FAIL}"
	[ "$ND_FAIL" -eq 0 ] && [ "$ND_PASS" -gt 0 ]
}
