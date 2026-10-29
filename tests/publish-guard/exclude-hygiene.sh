#!/usr/bin/env bash
# exclude-hygiene.sh — snapshot / restore / self-heal for a repository's
# .git/info/exclude, plus the trap idiom that makes the restore survive an
# interrupt. SOURCED, never executed (the filename deliberately does not match
# the test-*.sh glob that tests/run-all-tests.sh discovers).
#
# WHY THIS IS A SEPARATE FILE. tests/publish-guard/test-publish-guard.sh has to
# add a line to info/exclude to prove that a gitignored file is skipped. That
# file lives in the repository's COMMON git dir, which EVERY WORKTREE of the
# repository shares, so a line left behind there does not merely dirty one
# checkout — it silently changes what git ignores for the main checkout and for
# every subagent worktree. That is the same class of state ("this file was
# never scanned") the guard under test exists to prevent.
#
# Keeping the logic here means the assertions in the suite exercise THE CODE
# THE SUITE ITSELF RUNS, rather than a re-implementation that could drift. The
# suite calls these functions for the real repository; a hermetic section of
# the same suite calls them against a throwaway repository and kills the
# process mid-mutation to prove the restore actually happens.
#
# API (all return 0):
#   xg_resolve <repo-dir>     -> sets XG_EXCL, creating its directory
#   xg_selfheal               -> strips any stranded guardtest-ignored- line
#   xg_snapshot               -> records XG_EXISTED / XG_BACKUP
#   xg_restore                -> restores byte-for-byte (or removes) + clears
#   xg_install_traps [fn]     -> EXIT + HUP/INT/TERM, handler TERMINATES
#
# XG_MARKER is the prefix that identifies a line this machinery owns.

XG_MARKER="guardtest-ignored-"
XG_EXCL=""
XG_EXISTED=0
XG_BACKUP=""

# XG_RUN_ID scopes every temp file this machinery creates to ONE run.
#
# WHY. $TMPDIR is shared by every process on the machine, so a bare
# "pubguard-exclude-backup.*" glob counts — and a bare `rm -f` on that glob
# DELETES — the live backups of any other run of this suite happening at the
# same time. This repository runs suites from several worktrees in parallel as
# a matter of course, and the effect was measured: F2-4 fails (another run's
# backup is already there, so "did the control strand one?" is answered by
# somebody else's file), and F2-1 can fail LEAKED (another run deleted THIS
# run's backup mid-sleep, so xg_restore had nothing to copy back). A run-scoped
# infix makes both questions ask only about files this run created.
#
# EXPORTED, and resolved with :- so a child that sources this file again — the
# F2 harness does exactly that — keeps the parent's id. That is required, not
# incidental: the harness is the process whose backup F2-4 must be able to see.
XG_RUN_ID="${XG_RUN_ID:-$$-$(date +%s)-${RANDOM:-0}}"
export XG_RUN_ID
XG_BACKUP_PREFIX="pubguard-exclude-backup-${XG_RUN_ID}"

# xg_resolve <repo-dir>
# `git rev-parse --git-path info/exclude` rather than a literal
# "<repo>/.git/info/exclude": inside a linked worktree "<repo>/.git" is a FILE
# (a gitdir pointer), not a directory, so the literal path fails with "Not a
# directory" — which made the assertion that uses it silently FAIL whenever the
# suite ran from a worktree. Ask git; it answers correctly for both shapes.
xg_resolve() {
	local repo="$1" rel
	rel="$(cd "$repo" && git rev-parse --git-path info/exclude 2>/dev/null)"
	case "$rel" in
		/*) XG_EXCL="$rel" ;;
		*)  XG_EXCL="$repo/$rel" ;;
	esac
	mkdir -p "$(dirname "$XG_EXCL")"
	return 0
}

# xg_selfheal
# Trap-independent, because a trap cannot cover every death: SIGKILL runs no
# handler at all. Strip any line a previous run stranded BEFORE snapshotting,
# so the worst case is one run's damage rather than an accumulating list nobody
# ever notices. Only rewrites the file when there is something to remove, so a
# healthy run does not touch it at all.
xg_selfheal() {
	local heal
	if [ -n "$XG_EXCL" ] && [ -f "$XG_EXCL" ] && grep -q "^${XG_MARKER}" "$XG_EXCL"; then
		heal="$(mktemp -t "pubguard-exclude-heal-${XG_RUN_ID}.XXXXXX")"
		grep -v "^${XG_MARKER}" "$XG_EXCL" > "$heal"
		cat "$heal" > "$XG_EXCL"
		rm -f "$heal"
	fi
	return 0
}

# xg_snapshot
# Records the exact pre-test state — content, or "did not exist" — so it can be
# put back byte for byte regardless of what was in it.
xg_snapshot() {
	XG_EXISTED=0
	XG_BACKUP=""
	if [ -n "$XG_EXCL" ] && [ -f "$XG_EXCL" ]; then
		XG_EXISTED=1
		XG_BACKUP="$(mktemp -t "${XG_BACKUP_PREFIX}.XXXXXX")"
		cp "$XG_EXCL" "$XG_BACKUP"
	fi
	return 0
}

# xg_restore
# Idempotent: safe to call from the straight-line path AND again from the EXIT
# trap. Always returns 0 — it runs as a trap handler, where a non-zero return
# would be a second failure on top of whatever is already unwinding.
xg_restore() {
	if [ -n "$XG_EXCL" ]; then
		if [ "$XG_EXISTED" -eq 1 ]; then
			if [ -n "$XG_BACKUP" ] && [ -f "$XG_BACKUP" ]; then
				cp "$XG_BACKUP" "$XG_EXCL"
			fi
		else
			rm -f "$XG_EXCL"
		fi
	fi
	if [ -n "$XG_BACKUP" ]; then rm -f "$XG_BACKUP"; fi
	XG_EXCL=""; XG_BACKUP=""; XG_EXISTED=0
	return 0
}

# xg_install_traps [cleanup-fn]
# The signal handlers TERMINATE. A handler registered for EXIT+HUP+INT+TERM
# together does not: bash runs it and then carries on from wherever the signal
# landed, so the process keeps running with its cleanup already done — the
# exact defect found in scripts/push-to-web-host.sh on 2026-08-06, where the
# next statement then fed ssh an already-deleted file. Exit codes are the
# conventional 128+signum.
xg_install_traps() {
	local fn="${1:-xg_restore}"
	trap "$fn" EXIT
	trap "$fn; exit 129" HUP
	trap "$fn; exit 130" INT
	trap "$fn; exit 143" TERM
	return 0
}
