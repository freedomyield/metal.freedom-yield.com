#!/usr/bin/env bash
# receive-subdir-allowlist.snippet.sh — web-host-side receive block for the
# two allowlisted SUBDIRECTORY prefixes.
#
# CHAIN: none. PRIME_DIRECTIVE: safe (no broadcast-capable command).
#
# WHAT THIS IS
#   The web host authenticates the validator host with a dedicated key whose
#   authorized_keys entry pins a forced command (the operator-local wrapper
#   /home/deploy/bin/receive-metal-push). That wrapper carries its own
#   independent allowlist of FLAT filenames and writes each one into the
#   public api/ directory. It has no notion of subdirectories, so
#   `api/archive/…` (R18 per-anchor archives) and `api/peers-history/…`
#   (daily validator-set snapshots) could never be delivered — both are
#   published as URLs by anchor-history.jsonl and peers-history-index.json
#   respectively, and both returned 404.
#
#   This file is the CANONICAL text of the block that teaches that wrapper
#   the two subdirectory prefixes. scripts/install-xserver-subdir-allowlist.sh
#   inserts it verbatim at the top of the wrapper (shebang line stripped,
#   @@FY_SUBDIR_ROOT@@ substituted with the wrapper's real public api/
#   directory). Keeping it in the repo — instead of inside the installer's
#   heredoc — is what makes the accept/reject behaviour directly testable
#   (tests/install-xserver-subdir-allowlist/) without touching a real host.
#
# ACCEPTED (everything else falls through to the wrapper's own allowlist):
#   archive/anchor-source-<64 lowercase hex>.json
#   archive/anchor-receipt-<64 lowercase hex>.json
#   peers-history/peers-YYYY-MM-DD.json.gz
#
# These patterns MUST stay in lock-step with the `archive/*` and
# `peers-history/*` branches of scripts/push-to-web-host.sh — the sender and
# the receiver enforce the same allowlist independently, on purpose.
#
# CONTRACT WHEN EMBEDDED
#   - Runs before the wrapper's own `set -euo pipefail`, so every command is
#     checked explicitly and nothing relies on shell error flags.
#   - POSIX shell only (the wrapper may be #!/bin/sh), no functions, all
#     variables __fy_-prefixed so they cannot collide with the wrapper's.
#   - Handles a matching push completely and `exit`s. A non-matching command
#     string falls through untouched — the wrapper's existing flat-filename
#     behaviour is not modified in any way.
#
# EXIT CODES (subdirectory pushes only)
#   0  accepted, written atomically into <root>/<prefix>/<basename>
#   2  rejected: prefix matched but basename/shape is not on the allowlist
#   4  refused: destination root missing (also the fail-closed outcome when
#      @@FY_SUBDIR_ROOT@@ was never substituted)
#   5  I/O failure (mkdir / mktemp / write / rename)
#   6  rejected: content did not match the declared type (invalid JSON, or
#      not a valid gzip stream), or the payload was empty
#
# Standalone invocation (how the tests drive it):
#   FY_SUBDIR_ROOT=<dir> SSH_ORIGINAL_COMMAND=<name> \
#     bash receive-subdir-allowlist.snippet.sh < payload

# ---- BEGIN FY-SUBDIR-ALLOWLIST-V1 ----
# (installed by scripts/install-xserver-subdir-allowlist.sh; the marker on
# this line is what makes the installer idempotent — do not rename it
# without bumping the version in the installer too.)
__fy_arg="${SSH_ORIGINAL_COMMAND:-${1:-}}"
__fy_root="${FY_SUBDIR_ROOT:-@@FY_SUBDIR_ROOT@@}"

case "$__fy_arg" in
	archive/*|peers-history/*)
		__fy_sub="${__fy_arg%%/*}"
		__fy_base="${__fy_arg#*/}"

		# Traversal / nesting guards first. The sender rejects these too;
		# this side must never depend on that, because the authorized_keys
		# forced command is reachable by anyone holding the push key.
		case "$__fy_arg" in
			*..*)
				echo "REJECT: path traversal in '$__fy_arg'" >&2
				exit 2
				;;
		esac
		case "$__fy_base" in
			''|*/*)
				echo "REJECT: '$__fy_arg' must be exactly <prefix>/<basename>" >&2
				exit 2
				;;
		esac

		__fy_kind=""
		case "$__fy_sub" in
			archive)
				if printf '%s' "$__fy_base" | grep -Eq '^anchor-(source|receipt)-[a-f0-9]{64}\.json$'; then
					__fy_kind="json"
				fi
				;;
			peers-history)
				if printf '%s' "$__fy_base" | grep -Eq '^peers-[0-9]{4}-[0-9]{2}-[0-9]{2}\.json\.gz$'; then
					__fy_kind="gz"
				fi
				;;
		esac
		if [ -z "$__fy_kind" ]; then
			echo "REJECT: basename '$__fy_base' is not allowlisted under '$__fy_sub/'" >&2
			exit 2
		fi

		if [ ! -d "$__fy_root" ]; then
			echo "REFUSE: destination root not a directory: $__fy_root" >&2
			exit 4
		fi
		if ! mkdir -p "$__fy_root/$__fy_sub"; then
			echo "ERROR: cannot create $__fy_root/$__fy_sub" >&2
			exit 5
		fi

		__fy_tmp="$(mktemp "$__fy_root/$__fy_sub/.push.XXXXXX")" || {
			echo "ERROR: mktemp failed in $__fy_root/$__fy_sub" >&2
			exit 5
		}
		if ! cat > "$__fy_tmp"; then
			rm -f "$__fy_tmp"
			echo "ERROR: write failed for $__fy_sub/$__fy_base" >&2
			exit 5
		fi
		if [ ! -s "$__fy_tmp" ]; then
			rm -f "$__fy_tmp"
			echo "REJECT: empty payload for $__fy_sub/$__fy_base" >&2
			exit 6
		fi

		# Content type must match what the name declares. A truncated push
		# that still produced bytes is the realistic failure here, and it
		# must not land on a public URL an evaluator is told to verify.
		if [ "$__fy_kind" = "json" ]; then
			if command -v jq >/dev/null 2>&1; then
				if ! jq -e . "$__fy_tmp" >/dev/null 2>&1; then
					rm -f "$__fy_tmp"
					echo "REJECT: $__fy_sub/$__fy_base is not valid JSON" >&2
					exit 6
				fi
			fi
		else
			if ! gzip -t "$__fy_tmp" 2>/dev/null; then
				rm -f "$__fy_tmp"
				echo "REJECT: $__fy_sub/$__fy_base is not a valid gzip stream" >&2
				exit 6
			fi
		fi

		chmod 644 "$__fy_tmp" 2>/dev/null || true
		if ! mv -f "$__fy_tmp" "$__fy_root/$__fy_sub/$__fy_base"; then
			rm -f "$__fy_tmp"
			echo "ERROR: atomic rename failed for $__fy_sub/$__fy_base" >&2
			exit 5
		fi
		echo "OK: received $__fy_sub/$__fy_base"
		exit 0
		;;
esac
# Not a subdirectory push — fall through to the wrapper's existing
# flat-filename allowlist unchanged.
# ---- END FY-SUBDIR-ALLOWLIST-V1 ----
