# shellcheck shell=bash
# tests/lib/real-home-fence.sh — the ONE place a test runs a command with HOME
# set to the real login home (sourced, not executed).
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe. Nothing here reads a
# keystore, a config or a key; nothing touches the network.
#
# Why this exists (2026-11-27): a "HOME = login home is refused" case needs the
# real login home (fyd_login_home reads `id -un`, and the tests do not change
# that). When a mutant removed the guard, such a case went on and its script
# read the real keystore dirs' proton-cli.json with jq (2026-11-26). Inside the
# fence, a command that gets past its guard meets only temp dirs and traps:
#   (a) every path override the guarded scripts accept points into a temp dir
#       of this run (FENCE_OVERRIDE_* below);
#   (b) PATH starts with a trap dir: proton, jq, curl, wget, ssh, scp, openssl
#       and node there read nothing, write one line to the mark file and exit
#       FENCE_TRAP_EXIT;
#   (c) if any trap was called, the run's status is FENCE_TRAP_EXIT whatever
#       the command returned, so the case FAILS (no case expects 97).
#
# `HOME=<login home>` must appear in tests/ only inside this file:
# tests/operator-paths/test-operator-paths.sh P11 counts every other place.
#
# run_with_real_login_home <command> [args...]
#   Runs one external command (not a shell function) with HOME = the login
#   home, the overrides of (a) and the traps of (b). Output is the command's.
#   Exit: the command's status; FENCE_TRAP_EXIT if a trap was called;
#   FENCE_SETUP_EXIT if the fence could not be built (nothing was run).

FENCE_TRAP_EXIT=97
FENCE_SETUP_EXIT=96
FENCE_TRAP_MARK_NAME="fence-trap-called"
FENCE_TRAP_DIR_NAME="trap"
FENCE_TRAPPED_TOOLS="proton jq curl wget ssh scp openssl node"
FENCE_TEMP_TEMPLATE="real-home-fence.XXXXXX"

# fence_write_traps <trap dir> <mark file> — one trap per FENCE_TRAPPED_TOOLS name.
fence_write_traps() {
	local trap_dir="$1" mark_file="$2" tool
	mkdir -p "$trap_dir" || return 1
	for tool in $FENCE_TRAPPED_TOOLS; do
		{
			printf '#!/bin/sh\n'
			printf "printf '%%s\\\\n' '%s' >> '%s'\n" "$tool" "$mark_file"
			printf "echo 'FENCE: trap %s was called (not run)' >&2\n" "$tool"
			printf 'exit %s\n' "$FENCE_TRAP_EXIT"
		} > "${trap_dir}/${tool}" || return 1
		chmod +x "${trap_dir}/${tool}" || return 1
	done
}

# fence_traps_first <trap dir> — 0 iff every trapped name resolves to its trap.
fence_traps_first() {
	local trap_dir="$1" tool
	for tool in $FENCE_TRAPPED_TOOLS; do
		[ "$(PATH="${trap_dir}:${PATH}" command -v "$tool")" = "${trap_dir}/${tool}" ] || return 1
	done
}

run_with_real_login_home() {
	local login_home fence_root trap_dir mark_file rc
	login_home="$(eval echo "~$(id -un)" 2>/dev/null || true)"
	case "$login_home" in
		/*) ;;
		*) echo "FENCE: the login home cannot be resolved — nothing run" >&2; return "$FENCE_SETUP_EXIT" ;;
	esac
	fence_root="$(mktemp -d -t "$FENCE_TEMP_TEMPLATE")" || fence_root=""
	if [ -z "$fence_root" ] || [ ! -d "$fence_root" ]; then
		echo "FENCE: could not create the temp dir — nothing run" >&2
		return "$FENCE_SETUP_EXIT"
	fi
	trap_dir="${fence_root}/${FENCE_TRAP_DIR_NAME}"
	mark_file="${fence_root}/${FENCE_TRAP_MARK_NAME}"
	if ! fence_write_traps "$trap_dir" "$mark_file" || ! fence_traps_first "$trap_dir"; then
		echo "FENCE: the traps are not first on PATH — nothing run" >&2
		rm -rf -- "$fence_root"
		return "$FENCE_SETUP_EXIT"
	fi
	env HOME="$login_home" \
		PATH="${trap_dir}:${PATH}" \
		FYP_KEYSTORE_TESTNET="${fence_root}/ks-testnet" \
		FYP_KEYSTORE_MAINNET="${fence_root}/ks-mainnet" \
		FYP_PQ_KEY_DIR="${fence_root}/pq-key-dir" \
		FY_PQ_KEY_DIR="${fence_root}/pq-key-dir" \
		FYP_MAINNET_CFG="${fence_root}/mainnet-cfg" \
		FYP_REHEARSAL_CFG="${fence_root}/rehearsal-cfg" \
		FYP_IDENTITY_KEY="${fence_root}/identity-key" \
		FY_CONFIG_DIR="${fence_root}/fy-config" \
		FYD_RELAY_TOKEN_DIR="${fence_root}/relay" \
		FYD_BROADCAST_TOKEN_FILE="${fence_root}/absent-token" \
		FYD_BROADCAST_AUDIT_LOG="${fence_root}/audit.log" \
		XDG_CONFIG_HOME="${fence_root}/xdg-config" \
		ANCHOR_SOURCE_OVERRIDE="${fence_root}/absent/anchor-source.json" \
		"$@"
	rc=$?
	if [ -e "$mark_file" ]; then
		echo "FENCE: trap called ($(tr '\n' ' ' < "$mark_file")) — the command got past its guard" >&2
		rc="$FENCE_TRAP_EXIT"
	fi
	rm -rf -- "$fence_root"
	return "$rc"
}
