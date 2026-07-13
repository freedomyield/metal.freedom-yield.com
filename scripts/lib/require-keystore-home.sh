#!/usr/bin/env bash
# scripts/lib/require-keystore-home.sh — §3.5 keystore separation guard.
#
# CHAIN: none — this file defines a shell function only; it never invokes
#        proton or any broadcast-capable command itself.
#
# Constitution §3.5 (docs/CONSTITUTION.md) prohibits using the default
# (shared) proton-cli keystore for this project under any circumstance,
# and requires every proton-cli invocation to carry an explicit
# project-scoped keystore prefix (HOME=~/.metal-fy-proton for mainnet,
# HOME=~/.metal-fy-proton-test for testnet). This library centralizes the
# mechanical fail-closed check so every executable script that invokes
# proton-cli enforces it identically, ahead of that script's first proton
# invocation.
#
# The check: refuse if the effective $HOME resolves to the login user's
# default home — i.e. the caller did not scope HOME to a dedicated project
# keystore. Login-home resolution uses `id -un` + `eval echo ~<user>`
# (portable across macOS/Linux) and deliberately does NOT read $HOME to
# determine the login home, so the check cannot be short-circuited by the
# very env var it is validating.
#
# There is no bypass flag. Fail-closed is the point.
#
# Usage (source once near the top of a script, before any `proton …` call):
#   REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"     # or equivalent
#   # shellcheck source=scripts/lib/require-keystore-home.sh
#   . "${REPO_ROOT}/scripts/lib/require-keystore-home.sh"
#   require_project_keystore_home "$0" || exit 8
#
# Exit-code convention across callers: 8 = keystore guard failed (§3.5).
# Each calling script's own header documents this alongside its other
# exit codes.
#
# require_project_keystore_home [<label-for-error-message>]
#   Returns 0 if $HOME is not the login default home, OR if the login
#   default home could not be determined (inconclusive → does not block).
#   Returns 1 and prints a §3.5-citing error (with a corrected invocation
#   example) to stderr if $HOME resolves to the login default home.
require_project_keystore_home() {
	local caller="${1:-$0}"
	local login_home
	login_home="$(eval echo "~$(id -un)" 2>/dev/null || true)"
	if [ -n "$login_home" ] && [ "${HOME:-}" = "$login_home" ]; then
		echo "ERROR (keystore guard, Constitution §3.5): \$HOME resolves to the login" >&2
		echo "                default home (${HOME:-unset})." >&2
		echo "                §3.5 prohibits proton-cli against the default (shared)" >&2
		echo "                keystore for this project — fail-closed, no bypass flag." >&2
		echo "                Re-invoke ${caller} with an explicit project keystore prefix:" >&2
		echo "                  HOME=~/.metal-fy-proton      ${caller} ...   (mainnet)" >&2
		echo "                  HOME=~/.metal-fy-proton-test ${caller} ...   (testnet)" >&2
		return 1
	fi
	return 0
}
