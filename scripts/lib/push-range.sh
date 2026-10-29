#!/usr/bin/env bash
# push-range.sh — the ONE place that decides which commits a `git push` sends.
#
# Sourced (not executed). Used by scripts/pre-push-scan.sh. Any other gate
# that needs "the commits being pushed" must call this function rather than
# re-deriving the range (two derivations drift apart — the lesson of P3).
#
#   fyd_push_range_commits <remote-shas file> <local-sha> <remote-sha>
#
#     <remote-shas file>: one sha per line — every commit the remote itself
#     advertised (`git ls-remote`, asked by the hook) that exists locally.
#     Local refs/remotes/* are NOT used: they are only this machine's memory.
#
#     stdout: the commits being sent, one full sha per line, parents before
#             children (`--topo-order --reverse`).
#     return: 0  range computed (stdout lists >= 1 commit; it is empty only
#                when local == remote, i.e. a no-op)
#             10 nothing to scan: the push deletes the remote ref
#             1  refuse: the range cannot be computed, or the ref would move
#                with zero new commits. A one-line reason is on stderr.
#
#   Rules (design: exception-gate-design.md §5):
#     local sha all-zero            -> deletion, return 10
#     remote sha all-zero (new ref) -> rev-list <local> --not <remote-shas>
#                                      (empty file = every ancestor)
#     otherwise                     -> rev-list <remote>..<local>
#     remote sha not a local commit -> refuse
#     rev-list fails                -> refuse
#     zero commits but local != remote -> refuse, unless the local object is
#                                      an annotated tag (its body is the new
#                                      content; the caller scans it)

fyd_push_range_commits() {
	local shas="$1" lsha="$2" rsha="$3" list

	if [[ "$lsha" =~ ^0+$ ]]; then
		return 10
	fi
	if ! git cat-file -e "${lsha}^{commit}" 2>/dev/null; then
		echo "push-range: local object ${lsha:0:12} is not a commit" >&2
		return 1
	fi

	if [[ "$rsha" =~ ^0+$ ]]; then
		if [[ ! -f "$shas" ]]; then
			echo "push-range: no remote-shas file from the hook" >&2
			return 1
		fi
		if ! list="$( { echo "$lsha"; sed 's/^/^/' "$shas"; } | git rev-list --topo-order --reverse --stdin 2>/dev/null)"; then
			echo "push-range: rev-list failed for new ref at ${lsha:0:12}" >&2
			return 1
		fi
	else
		if ! git cat-file -e "${rsha}^{commit}" 2>/dev/null; then
			echo "push-range: remote commit ${rsha:0:12} not found locally (fetch first)" >&2
			return 1
		fi
		if ! list="$(git rev-list --topo-order --reverse "${rsha}..${lsha}" 2>/dev/null)"; then
			echo "push-range: rev-list failed for ${rsha:0:12}..${lsha:0:12}" >&2
			return 1
		fi
	fi

	if [[ -z "$list" ]]; then
		if [[ "$lsha" != "$rsha" ]] && [[ "$(git cat-file -t "$lsha" 2>/dev/null)" != tag ]]; then
			echo "push-range: zero commits to scan but the ref moves to ${lsha:0:12}" >&2
			return 1
		fi
		return 0
	fi
	printf '%s\n' "$list"
	return 0
}
