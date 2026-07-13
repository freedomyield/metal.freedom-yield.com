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
# fyd_login_home
#   Prints the invoking user's LOGIN home directory, independent of the
#   current $HOME. Deliberately does NOT read $HOME (same reasoning as
#   require_project_keystore_home below: it must work correctly even when
#   $HOME has been rescoped to a project keystore dir).
#   Resolves `~<login-username>` via `id -un` + bash tilde expansion. If
#   `id -un` itself fails or prints nothing (rare; not observed on this
#   repo's supported macOS/Linux targets), the tilde expansion of a bare
#   `~` falls back to bash's OWN current $HOME value — it does NOT print
#   an empty string, despite earlier revisions of this comment claiming
#   otherwise. Practical effect on each consumer:
#     - require_project_keystore_home() below: on that rare failure,
#       login_home == the caller's own $HOME, so the equality check
#       trivially matches and the guard REFUSES — i.e. this function's
#       failure mode is over-blocking, not fail-open.
#     - Non-keystore-path consumers (e.g. run-testnet-rehearsal.sh's
#       `[ -n "$LOGIN_HOME" ] || LOGIN_HOME="$HOME"` fallback) keep an
#       explicit empty-string fallback defensively; it is unreachable
#       given the behavior above, but harmless to retain.
#
#   Two consumers:
#     1. require_project_keystore_home() below — to detect whether $HOME
#        still points at the login default (the thing being forbidden).
#     2. Scripts that ALSO have their own operator-local, non-keystore
#        paths (e.g. scripts/run-testnet-rehearsal.sh's rehearsal config
#        dir, dry-run log, receipt file) that must keep resolving to the
#        login home even when the script itself is correctly invoked with
#        HOME=<project keystore dir> per §3.5. Without this, a
#        keystore-scoped HOME would silently relocate those unrelated
#        paths into the keystore dir and break the script (§3.5 follow-up,
#        Task D).
fyd_login_home() {
	eval echo "~$(id -un)" 2>/dev/null
}

# require_project_keystore_home [<label-for-error-message>]
#   Returns 0 if $HOME is explicitly set AND is not the login default
#   home, OR if the login default home could not be determined
#   (inconclusive → does not block).
#   Returns 1 and prints a §3.5-citing error (with a corrected invocation
#   example) to stderr if $HOME is unset/empty, OR if $HOME resolves to
#   the login default home.
#
#   The unset/empty case matters on its own: node's `os.homedir()` (what
#   proton-cli uses under the hood) falls back to a passwd-database lookup
#   when $HOME is unset, which resolves to the SAME default keystore this
#   guard exists to forbid. Treating unset/empty HOME as "inconclusive,
#   let it through" would fail-open exactly the case §3.5 cares about most
#   — so it is refused explicitly, ahead of (and independent of) the
#   login-home comparison below.
require_project_keystore_home() {
	local caller="${1:-$0}"
	local login_home
	login_home="$(fyd_login_home || true)"
	if [ -z "${HOME:-}" ]; then
		echo "ERROR (keystore guard, Constitution §3.5): \$HOME must be explicitly set to a" >&2
		echo "                project keystore (it is currently unset or empty)." >&2
		echo "                §3.5 prohibits proton-cli against the default (shared)" >&2
		echo "                keystore for this project — fail-closed, no bypass flag." >&2
		echo "                Re-invoke ${caller} with an explicit project keystore prefix:" >&2
		echo "                  HOME=~/.metal-fy-proton      ${caller} ...   (mainnet)" >&2
		echo "                  HOME=~/.metal-fy-proton-test ${caller} ...   (testnet)" >&2
		return 1
	fi
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
