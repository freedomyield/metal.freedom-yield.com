#!/usr/bin/env bash
# publish-scan.sh — run scripts/publish-guard.sh over the bytes that are ABOUT
# TO LEAVE THIS MACHINE, and refuse the transfer unless they are proven clean.
#
# WHY THIS EXISTS (measured 2026-08-06). publish-guard was wired at three
# points — the Claude PreToolUse hook, git pre-commit, git pre-push — and all
# three watch the same thing: content on its way INTO GIT. The live public feed
# never goes near git, so none of the three ever saw it:
#
#   * scripts/push-to-web-host.sh reads a file out of the working tree and
#     streams it straight to the public web host over ssh. It never invokes
#     git, and every one of its targets (public/api/*.json, archive/,
#     peers-history/, public/calendar/) is gitignored — so layer 1 skips them
#     BY DESIGN and layers 2/3 cannot see them at all.
#   * scripts/sync-to-validator-host.sh rsyncs the working tree's scripts/ onto
#     the production host, where cron then runs them.
#
# Both are cron-driven and neither was covered. This module is the missing
# send-time layer. It scans THE OUTBOUND BYTES THEMSELVES — not a path
# allowlist, not the committed version of the file, not "the file that path
# pointed at a moment ago".
#
# PUBLIC API. Both return 0 only on a positively-proven-clean result; ANY
# non-zero return means DO NOT SEND. There is deliberately no "warn and
# continue" path: a leak cannot be un-published.
#
#   fyd_publish_scan_selftest
#       Prove the guard on THIS machine still detects, by feeding it a
#       known-bad probe and requiring it to block. Call once per process,
#       before the first send.
#   fyd_publish_scan_file <path> [label]
#       Scan one file's exact bytes. <label> is only used in messages.
#
# WHY A SELF-TEST AND NOT JUST THE EXIT CODE. In --text mode a clean result is
# "exit 0, no output", which is byte-for-byte what a guard that never ran also
# produces — a truncated copy (this repo rsyncs scripts/ to production, so a
# short write is a real accident, not a hypothetical), a stray `exit 0` at the
# top, a shell that cannot parse the file. publish-guard.sh itself refuses to
# trust its own helpers' exit codes for exactly this reason and demands a
# positive marker from perl and a parse probe from jq; this is the same
# contract one level up. The probe costs one extra guard run per process
# (~20 ms — see the timings in the task report).
#
# Refs: docs/CONSTITUTION.md §4.1 S8, memory/feedback_no_literal_host_identifier.md.

# ---- installation-relative resolution (no env override, deliberately) -------
# The guard is located from THIS FILE's own path, never from REPO_BASE or the
# caller's CWD. REPO_BASE is a DATA root — callers and tests repoint it at a
# fixture tree — so resolving the guard through it would let a caller choose
# which guard (or no guard) enforces its own send. There is no environment
# variable that can substitute a different guard either: the whole point of
# this layer is that the send path cannot opt out of it.
_fyd_ps_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FYD_PUBLISH_SCAN_GUARD="${_fyd_ps_dir}/../publish-guard.sh"
# The guard resolves its optional .publish-denylist relative to `git rev-parse
# --show-toplevel` of its CWD. Cron gives it an arbitrary CWD, which silently
# decided whether that layer applied at all; pin it to the install root so the
# answer is the same on every invocation.
FYD_PUBLISH_SCAN_CWD="$(cd "${_fyd_ps_dir}/../.." && pwd 2>/dev/null || printf '/')"
unset _fyd_ps_dir

# _fyd_ps_run_guard <file> -> the guard's own exit code (0 clean / 1 block).
# stdout is discarded; the guard writes its block report to stderr and that is
# left alone so the operator sees which rule fired.
_fyd_ps_run_guard() {
	local rc=0
	( cd "$FYD_PUBLISH_SCAN_CWD" 2>/dev/null || cd / || exit 127
	  exec bash "$FYD_PUBLISH_SCAN_GUARD" --text ) < "$1" >/dev/null || rc=$?
	return "$rc"
}

# _fyd_ps_normalise <src> <dst> -> 0 on success
# Translates NUL bytes to newlines. The guard reads stdin through a command
# substitution, which drops NULs; doing the translation here means the byte
# stream the guard scans is one we chose rather than one we hoped about.
# Translation can only ever SPLIT a token, never join two, so it cannot hide a
# forbidden literal — it can only ever produce a false positive, never a false
# negative.
_fyd_ps_normalise() {
	LC_ALL=C tr '\0' '\n' < "$1" > "$2"
}

# fyd_publish_scan_selftest
fyd_publish_scan_selftest() {
	local tmp rc=0
	if [ ! -r "$FYD_PUBLISH_SCAN_GUARD" ]; then
		printf 'ERROR: publish-guard not found or unreadable at %s\n' "$FYD_PUBLISH_SCAN_GUARD" >&2
		printf '       Refusing to send: outbound content cannot be checked.\n' >&2
		return 1
	fi
	tmp="$(mktemp -t fyd-pubscan-probe.XXXXXX)" || {
		printf 'ERROR: cannot create a temporary file for the publish-guard self-test.\n' >&2
		printf '       Refusing to send: outbound content cannot be checked.\n' >&2
		return 1
	}
	# Probe payload assembled from parts so no address-shaped literal ever
	# appears in this tracked file (the guard's own test suite uses the same
	# technique, and this file was blocked by the layer-1 hook while being
	# written until it did). The octets below are the RFC2544 benchmarking
	# range: the guard does not exclude it, so a WORKING guard must block it —
	# and it is not, and can never be, a real host of ours.
	printf 'publish-scan self-test probe %d.%d.%d.%d\n' 198 18 0 1 > "$tmp"
	_fyd_ps_run_guard "$tmp" >/dev/null 2>&1 || rc=$?
	rm -f "$tmp"
	# Exactly 1: that is publish-guard's --text block code. 0 means the scanner
	# did not detect a payload it is required to detect (truncated, stubbed,
	# never ran); anything else means it could not run at all.
	if [ "$rc" -ne 1 ]; then
		printf 'ERROR: publish-guard self-test failed (expected block rc=1, got rc=%d).\n' "$rc" >&2
		printf '       The guard did not detect a payload it is required to detect, so a\n' >&2
		printf '       clean result from it would prove nothing. Refusing to send.\n' >&2
		printf '       Check: bash %s --text  (needs a working perl with Digest::SHA)\n' "$FYD_PUBLISH_SCAN_GUARD" >&2
		return 1
	fi
	return 0
}

# fyd_publish_scan_file <path> [label]
fyd_publish_scan_file() {
	local path="$1" label="${2:-$1}" tmp raw rc=0 magic
	if [ ! -r "$path" ]; then
		printf 'ERROR: cannot read outbound content for %s (path: %s)\n' "$label" "$path" >&2
		printf '       Refusing to send: unscanned content is never sent.\n' >&2
		return 1
	fi

	tmp="$(mktemp -t fyd-pubscan.XXXXXX)" || {
		printf 'ERROR: cannot create a temporary file to scan %s.\n' "$label" >&2
		printf '       Refusing to send: outbound content cannot be checked.\n' >&2
		return 1
	}
	if ! _fyd_ps_normalise "$path" "$tmp"; then
		rm -f "$tmp"
		printf 'ERROR: could not read the outbound bytes of %s for scanning.\n' "$label" >&2
		printf '       Refusing to send: outbound content cannot be checked.\n' >&2
		return 1
	fi
	_fyd_ps_run_guard "$tmp" || rc=$?
	rm -f "$tmp"
	if [ "$rc" -ne 0 ]; then
		printf 'ERROR: publish-guard refused the outbound content of %s (rc=%d).\n' "$label" "$rc" >&2
		printf '       NOT SENT. See the PUBLISH_GUARD_BLOCK report above for the rule that fired.\n' >&2
		return 1
	fi

	# gzip payloads: the compressed bytes are what travels, but the DECOMPRESSED
	# bytes are what the public actually reads, and a forbidden literal in there
	# is invisible in the compressed form. Detected by magic number rather than
	# by filename so the check does not depend on a naming convention. (The
	# compressed form is scanned above regardless — it is not pure entropy:
	# `gzip -c foo.json > bar.gz` stores the ORIGINAL BASENAME in the FNAME
	# header field, measured 2026-08-06.)
	magic="$(LC_ALL=C head -c 2 "$path" 2>/dev/null | LC_ALL=C od -An -tx1 2>/dev/null | tr -d ' \n')"
	if [ -s "$path" ] && [ -z "$magic" ]; then
		printf 'ERROR: could not read the leading bytes of %s to classify it.\n' "$label" >&2
		printf '       Refusing to send: a container we cannot identify cannot be scanned.\n' >&2
		return 1
	fi
	if [ "$magic" = "1f8b" ]; then
		raw="$(mktemp -t fyd-pubscan-gz.XXXXXX)" || {
			printf 'ERROR: cannot create a temporary file to decompress %s.\n' "$label" >&2
			printf '       Refusing to send: outbound content cannot be checked.\n' >&2
			return 1
		}
		if ! gzip -cd < "$path" > "$raw" 2>/dev/null; then
			rm -f "$raw"
			printf 'ERROR: %s looks gzipped but could not be decompressed for scanning.\n' "$label" >&2
			printf '       Refusing to send: what the public would read is unknown to us.\n' >&2
			return 1
		fi
		tmp="$(mktemp -t fyd-pubscan.XXXXXX)" || {
			rm -f "$raw"
			printf 'ERROR: cannot create a temporary file to scan %s.\n' "$label" >&2
			printf '       Refusing to send: outbound content cannot be checked.\n' >&2
			return 1
		}
		if ! _fyd_ps_normalise "$raw" "$tmp"; then
			rm -f "$raw" "$tmp"
			printf 'ERROR: could not read the decompressed bytes of %s for scanning.\n' "$label" >&2
			printf '       Refusing to send: outbound content cannot be checked.\n' >&2
			return 1
		fi
		rm -f "$raw"
		rc=0
		_fyd_ps_run_guard "$tmp" || rc=$?
		rm -f "$tmp"
		if [ "$rc" -ne 0 ]; then
			printf 'ERROR: publish-guard refused the DECOMPRESSED content of %s (rc=%d).\n' "$label" "$rc" >&2
			printf '       NOT SENT. See the PUBLISH_GUARD_BLOCK report above for the rule that fired.\n' >&2
			return 1
		fi
	fi

	return 0
}
