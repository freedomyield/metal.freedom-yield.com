#!/usr/bin/env bash
# advance-host-checkout.sh — self-healing FF-only advance of the validator-host
# git checkout to origin/main.
#
# Motivation: on 2026-07-09 the validator host was found 21 commits behind
# origin/main (the `host-drift: checkout diverging` tripwire). Investigation
# found nothing in any deploy leg ever advanced host HEAD — deploy.yml back
# then rsynced files but excluded .git/, check-host-drift.sh is read-only by
# design, and sync-to-validator-host.sh only rsyncs scripts/ (that last part
# is still true today — it is a separate operator-run tool, unrelated to
# deploy.yml). Compounding it, deploy stamps cache-bust markers (?v=<sha>)
# into public/*.html on the host, dirtying the tree so a naive
# `git pull --ff-only` aborts. This script closes that loop: it is the
# primary self-heal (see
# docs/superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md
# §2①, addendum); check-host-drift.sh remains as the read-only backstop
# that detects if this script ever stops running. As of the 2026-07-13
# delivery-ownership inversion, deploy.yml itself pipes and invokes this
# script directly at every deploy (its "Advance host checkout to
# origin/main" step) — it is no longer cron-only, and deploy.yml's own
# rsync now ships only public/.
#
# Algorithm (spec §2① — followed exactly):
#   1. fetch origin main
#   2. ahead  = rev-list --count origin/main..HEAD
#   3. behind = rev-list --count HEAD..origin/main
#   4. ahead>0   -> refuse: make NO changes, alert high, exit 1
#                   (a host must NEVER author commits — see CLAUDE.md /
#                   Constitution infra-separation rules)
#   5. behind==0 -> log in-sync, exit 0
#   6. else: discard ONLY public/ (deploy cache-bust dirt), then
#      6.5. self_heal_lossless_dirt: absorb any remaining worktree dirt
#           that is byte-identical (content AND mode) to origin/main —
#           the rsync-clobber signature of a deploy leg writing tracked
#           bytes onto the host outside git. Reverting/removing such dirt
#           loses zero information (the pull that follows immediately
#           re-creates the identical bytes) and is alerted as
#           informational, not high, since nothing was lost. Anything not
#           byte-identical is left untouched.
#      `git pull --ff-only origin main`.
#        - success -> log behind N -> 0 (old..new), exit 0
#        - failure -> alert high, exit 1
#
# NEVER: `git reset --hard`, `git merge`, discarding anything outside
# public/ unless byte-identical to origin/main (see self_heal_lossless_dirt
# — step 6.5), discarding content that differs from origin/main, silently
# discarding host-authored public/api/anchor-source.json dirt that differs
# from HEAD (see "anchor-source.json protection" below — step 6.7), or
# invoking any broadcast-capable command (proton / cleos /
# bin/safe-broadcast / any RPC push_transaction equivalent) — this script
# does not touch broadcast machinery at all.
#
# anchor-source.json protection (added 2026-08, plan A4): step 6 above
# (`git checkout -- public/`) is otherwise unconditional, but
# public/api/anchor-source.json is special-cased before it runs. That file
# is git-tracked yet AUTHORED on this very host by gen-anchor-source.sh —
# the operator's Mac transfers it to Git via
# scripts/operator-local/commit-anchor-source.sh, a step that can lag the
# host composing it (see docs/ANCHOR_SOURCE.md). Without protection, a
# deploy or the daily cron landing in that gap would silently discard the
# freshly-composed, not-yet-committed anchor content along with the
# routine cache-bust dirt step 6 exists for. So: if this file's worktree
# content is byte-identical to HEAD, nothing changes (ordinary step-6
# discard, zero information lost). If it differs, the bytes are preserved
# BEFORE step 6 runs (protect_anchor_source_pre_discard, alert high) and,
# once the FF pull (step 7) either lands or fails, resolved
# (resolve_anchor_source_post_pull): if the pull never touched the path,
# the preserved dirt is restored on top, still pending its own commit; if
# the pull DID touch it (the Mac-side commit arrived via origin) and the
# incoming bytes match the preserved dirt, it self-heals (default alert,
# nothing lost); if they differ, origin wins on the canonical path but the
# preserved dirt is stashed to a `.host-<UTC timestamp>` sibling (alert
# high) rather than discarded. A single EXIT trap
# (restore_anchor_dirt_on_exit) is the safety net for every OTHER exit
# path between capture and resolution (discard failure, self-heal
# failure, FF-pull failure) — it restores the preserved bytes onto the
# real path so no exit route can silently lose them.
#
# Usage:
#   bash scripts/advance-host-checkout.sh
#
# Env overrides (test-time + ops):
#   FYD_REPO_DIR       repo checkout to advance (default: this script's repo)
#   FYD_NOTIFY         notifier to invoke (default: <script dir>/notify.sh)
#   FYD_LOCK_TIMEOUT   seconds to wait for the concurrency lock (default:
#                      120; test-time only — production callers keep the
#                      default)
#
# Exit codes:
#   0  already in sync, or successfully advanced to origin/main
#   1  refused (host ahead of origin) OR public/ discard failed OR
#      ff-only pull failed (e.g. a non-public tracked file has uncommitted
#      edits that the incoming diff would clobber — git refuses the merge
#      rather than lose data, and so do we) OR anchor-source.json dirt
#      could not be preserved / stashed (mktemp or cp/mv failure — treated
#      as loudly as any other data-loss risk in this script)
#   2  fetch failed, or REPO_DIR is not a git checkout (both transient /
#      environmental; next tick retries)
#
# Cron: scripts/install-metal-host-advance-cron.sh, scheduled to run BEFORE
# the check-host-drift.sh daily tripwire so a healthy self-heal clears drift
# before the backstop samples it.
#
# Concurrency: two callers run this script against the SAME checkout — the
# deploy-time invocation (deploy.yml's "Advance host checkout" step) and
# the daily cron. If they overlap, the git-lock loser would fail its pull
# and fire a spurious high-priority alert for what is really just benign
# contention. A per-checkout flock on <git-dir>/fyd-advance.lock (resolved
# via `rev-parse --absolute-git-dir` — worktrees have a .git FILE, and the
# non-absolute form can return a cwd-relative path) serializes them: the
# second run waits up to FYD_LOCK_TIMEOUT (120s) for the first to finish,
# then — both runs being idempotent — typically lands on "already in
# sync". A timeout is NOT benign contention (an advance wedged >120s) and
# fails loudly. On systems without flock (macOS, where the dev test suite
# runs — the repo already treats flock as Linux-only, see
# tests/anomalies/integration-linux.sh) the guard is skipped entirely and
# the script behaves exactly as before the guard existed.

# No `-e`... actually not needed here: unlike check-host-drift.sh's
# `[ cond ] && VAR=` drift-accumulation idiom, every operation in this
# script that can legitimately fail in normal operation — the fetch, the
# public/ discard, each self_heal_lossless_dirt mutating op (`git checkout
# --`, `rm`, added 2026-07-13), and the ff-only pull — is guarded by an
# explicit `if ! ...; then` / `if VAR=$(...); then` test, which is exempt
# from `set -e` by POSIX semantics, so their failure is handled
# deliberately rather than tripping the trap. Everything else (rev-list
# --count, git status --porcelain) is expected to succeed once fetch has
# already succeeded against real refs; if one of those somehow still
# fails, aborting immediately via `set -e` is the safer default for
# host-mutating automation than silently continuing on an unknown repo
# state.
set -euo pipefail

# Stdin hardening: deploy pipes this script over SSH via `bash -s`, so the
# script's stdin IS the script text itself. A bare `exec </dev/null` here
# would therefore make bash read "the rest of the script" from /dev/null
# and silently stop with exit 0 (measured, 2026-07-13). Instead the whole
# body is one brace group with stdin redirected at the group's close:
# bash must parse to the closing `}` before executing anything, so no
# stdin-reading command can ever swallow script text mid-run, and every
# command inside sees /dev/null on stdin. `exit` inside a brace group
# (not a subshell) still exits the script with its code as before.
{

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${FYD_REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
NOTIFY="${FYD_NOTIFY:-${SCRIPT_DIR}/notify.sh}"

# anchor-source.json protection state (see header comment). Declared here,
# ahead of `set -u`-sensitive use, so the EXIT trap below is well-defined
# from the moment it is registered regardless of which exit path fires.
ANCHOR_SOURCE_REL="public/api/anchor-source.json"
ANCHOR_SOURCE_ABS="${REPO_DIR}/${ANCHOR_SOURCE_REL}"
ANCHOR_DIRT_CAPTURED=0
ANCHOR_DIRT_FILE=""
ANCHOR_DIRT_RESOLVED=0

log() { printf '[advance-host-checkout] %s\n' "$*"; }

alert() {
	# alert <priority> <title> <message>
	if [ -x "$NOTIFY" ] || [ -f "$NOTIFY" ]; then
		bash "$NOTIFY" "$1" "$2" "$3" || log "WARN: notify failed (alert was: $2 — $3)"
	else
		log "WARN: notifier not found at $NOTIFY (alert was: $2 — $3)"
	fi
}

# restore_anchor_dirt_on_exit — EXIT-trap safety net for anchor-source.json
# protection (see header comment / plan A4). If protect_anchor_source_pre_
# discard captured host dirt but the script exits before
# resolve_anchor_source_post_pull runs to completion — public/ discard
# failure, a self_heal_lossless_dirt failure, or an FF-pull failure are all
# exactly this shape, since none of them reach the pull-succeeded branch
# that calls resolve_anchor_source_post_pull — this restores the preserved
# bytes onto the real path so no such exit route can silently lose them.
# A no-op once ANCHOR_DIRT_RESOLVED=1 (resolve_anchor_source_post_pull sets
# this as its first act, before it decides the dirt's fate itself) or if no
# dirt was ever captured (ANCHOR_DIRT_CAPTURED stays 0 whenever the
# worktree copy was already byte-identical to HEAD, or the path never had
# any dirt to protect in the first place).
restore_anchor_dirt_on_exit() {
	[ "$ANCHOR_DIRT_CAPTURED" -eq 1 ] || return 0
	[ "$ANCHOR_DIRT_RESOLVED" -eq 1 ] && return 0
	if [ -f "$ANCHOR_DIRT_FILE" ]; then
		if cp -p "$ANCHOR_DIRT_FILE" "$ANCHOR_SOURCE_ABS" 2>/dev/null; then
			log "anchor-source.json: restored preserved host dirt on early exit (safety net)"
		else
			log "ERROR: anchor-source.json safety-net restore failed; preserved bytes remain at ${ANCHOR_DIRT_FILE}"
		fi
		rm -f "$ANCHOR_DIRT_FILE"
	fi
}
trap restore_anchor_dirt_on_exit EXIT

# protect_anchor_source_pre_discard — special-case public/api/anchor-source.json
# ahead of the unconditional `git checkout -- public/` a few lines below.
# That file is git-tracked but AUTHORED on this host by gen-anchor-source.sh
# (see docs/ANCHOR_SOURCE.md); the operator's Mac transfers it to Git via
# scripts/operator-local/commit-anchor-source.sh, a step that can lag the
# host composing it. Without this, the blanket public/ discard would
# silently throw away freshly-composed, not-yet-committed anchor content
# along with the routine cache-bust dirt it exists to clear.
#
# If the worktree copy is already byte-identical to HEAD, this is a no-op
# (ANCHOR_DIRT_CAPTURED stays 0) — the ordinary discard a few lines down
# loses zero information either way. Only a REAL difference from HEAD is
# captured: snapshotted to a tmp file (so it survives the discard that is
# about to run) and alerted at high priority. resolve_anchor_source_post_pull
# below decides its final fate once the FF pull's effect on this exact path
# is known.
protect_anchor_source_pre_discard() {
	[ -f "$ANCHOR_SOURCE_ABS" ] || return 0
	if git -C "$REPO_DIR" diff --quiet HEAD -- ":(literal)${ANCHOR_SOURCE_REL}" 2>/dev/null; then
		return 0
	fi
	local dirt_file
	if ! dirt_file="$(mktemp -t fyd-anchor-source-dirt.XXXXXX)"; then
		log "ERROR: mktemp failed while preserving anchor-source.json dirt"
		alert high "host-advance: anchor-source.json preserve failed" "mktemp failed while trying to preserve host-authored public/api/anchor-source.json dirt ahead of the public/ discard (behind=${BEHIND}); refusing to risk silent loss — investigate manually."
		exit 1
	fi
	if ! cp -p "$ANCHOR_SOURCE_ABS" "$dirt_file"; then
		log "ERROR: failed to snapshot anchor-source.json dirt to ${dirt_file}"
		alert high "host-advance: anchor-source.json preserve failed" "cp failed while trying to preserve host-authored public/api/anchor-source.json dirt ahead of the public/ discard (behind=${BEHIND}); refusing to risk silent loss — investigate manually."
		rm -f "$dirt_file"
		exit 1
	fi
	ANCHOR_DIRT_FILE="$dirt_file"
	ANCHOR_DIRT_CAPTURED=1
	log "anchor-source.json: host-authored dirt differs from HEAD — preserved ahead of public/ discard"
	alert high "host-authored anchor-source.json pending commit — preserved" "public/api/anchor-source.json has host-composed content that differs from the committed HEAD and has not yet been transferred by commit-anchor-source.sh. Preserved (not discarded) ahead of the public/ working-tree reset (behind=${BEHIND})."
}

# resolve_anchor_source_post_pull <old_blob_hash> <new_blob_hash> — called
# only after a successful FF pull, only when protect_anchor_source_pre_
# discard actually captured dirt above. Decides the preserved dirt's final
# fate now that the pull's effect on this exact path is known:
#   - old == new (pull never touched this path): the preserved dirt is
#     restored on top of the (unchanged) pulled content — still pending
#     its own commit-anchor-source.sh run, nothing lost.
#   - old != new (the Mac-side commit-anchor-source.sh commit arrived via
#     origin) and the incoming bytes match the preserved dirt exactly:
#     self-heal — the preserved copy is now redundant, discarded, alerted
#     at default priority (informational, nothing lost).
#   - old != new and the incoming bytes DIFFER from the preserved dirt:
#     origin wins on the canonical path (already what the pull just wrote
#     there) but the preserved dirt is stashed to a `.host-<UTC
#     timestamp>` sibling rather than discarded, alerted at high priority
#     with the stash path.
resolve_anchor_source_post_pull() {
	[ "$ANCHOR_DIRT_CAPTURED" -eq 1 ] || return 0
	ANCHOR_DIRT_RESOLVED=1
	local old_hash="$1" new_hash="$2"

	if [ "$old_hash" = "$new_hash" ]; then
		cp -p "$ANCHOR_DIRT_FILE" "$ANCHOR_SOURCE_ABS"
		rm -f "$ANCHOR_DIRT_FILE"
		log "anchor-source.json: pull left this path untouched — restored preserved host dirt"
		return 0
	fi

	if cmp -s "$ANCHOR_DIRT_FILE" "$ANCHOR_SOURCE_ABS"; then
		rm -f "$ANCHOR_DIRT_FILE"
		log "anchor-source.json: self-heal — incoming pull content matches preserved host dirt"
		alert default "host-advance: self-healed anchor-source.json" "public/api/anchor-source.json: the preserved host-authored dirt was byte-identical to the incoming pull (the pending commit-anchor-source.sh commit arrived via origin) — self-healed, nothing lost."
		return 0
	fi

	local ts stash_path
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	stash_path="${ANCHOR_SOURCE_ABS}.host-${ts}"
	if mv "$ANCHOR_DIRT_FILE" "$stash_path"; then
		log "anchor-source.json: incoming pull diverged from preserved host dirt — stashed host dirt to ${stash_path}"
		alert high "host-advance: anchor-source.json host dirt stashed" "public/api/anchor-source.json: the incoming pull (a commit-anchor-source.sh commit that arrived via origin) diverged from the preserved host-authored content. Origin content was kept on the canonical path; the diverged host dirt was stashed to ${stash_path} for manual review — nothing was discarded."
		return 0
	fi

	# Stash relocation itself failed (rare — mktemp's dir and REPO_DIR can be
	# different filesystems). Mirrors self_heal_lossless_dirt's own
	# mutating-op-failure severity: fail loudly rather than let a run that
	# hit this edge case report a plain, undifferentiated success. The
	# canonical path is already correct (origin content, written by the
	# pull itself) and the preserved dirt is deliberately left in place at
	# ANCHOR_DIRT_FILE (not deleted) so the alert's named path is where an
	# operator actually finds it.
	log "ERROR: failed to stash divergent anchor-source.json host dirt to ${stash_path}"
	alert high "host-advance: anchor-source.json stash failed" "failed to move preserved host dirt to ${stash_path} after the incoming pull diverged from it; the host dirt remains readable at ${ANCHOR_DIRT_FILE} — investigate and relocate manually. The canonical path already holds the correct origin content."
	return 1
}

# self_heal_lossless_dirt — absorb working-tree dirt that is byte-identical
# (content AND mode) to what the incoming FF pull would write anyway.
# This is the rsync-clobber signature: a deploy leg (or manual rsync) wrote
# origin/main's bytes onto the host outside git, so git sees "local
# changes" and refuses the pull even though nothing would be lost.
# Reverting such a file to HEAD (or deleting such an untracked file) loses
# zero information — the pull that follows immediately re-creates the
# identical bytes. Anything NOT byte-identical (real local work, staged
# edits, deletions, mode drift) is deliberately left alone so git's own
# refusal keeps protecting it, exactly as before.
self_heal_lossless_dirt() {
	local healed=0 healed_list="" entry path
	while IFS= read -r -d '' entry; do
		[ "${#entry}" -ge 4 ] || continue
		path="${entry:3}"
		case "$path" in public/*) continue ;; esac
		case "$entry" in
		" M "*)
			# tracked, modified in the worktree only (index clean).
			# :(literal) pathspec magic: $path must match exactly one
			# file, never expand as a glob (a path containing * or ?
			# would otherwise be a pathspec pattern). The cat-file /
			# show calls below use rev:path syntax, which is not a
			# pathspec and needs no such guard.
			if git -C "$REPO_DIR" diff --quiet origin/main -- ":(literal)$path"; then
				if ! git -C "$REPO_DIR" checkout -- ":(literal)$path"; then
					log "ERROR: self-heal failed to revert ${path}"
					alert high "host-advance: self-heal revert failed" "git checkout -- ${path} failed during lossless self-heal (behind=${BEHIND}); host state left as-is — investigate manually."
					exit 1
				fi
				log "self-heal: reverted lossless dirt (worktree == origin/main): ${path}"
				healed=$((healed + 1)); healed_list="${healed_list}${path} "
			fi
			;;
		"?? "*)
			# untracked file colliding with an incoming tracked path
			if git -C "$REPO_DIR" cat-file -e "origin/main:${path}" 2>/dev/null \
				&& git -C "$REPO_DIR" show "origin/main:${path}" | cmp -s - "${REPO_DIR}/${path}"; then
				if ! rm -- "${REPO_DIR}/${path}"; then
					log "ERROR: self-heal failed to remove untracked ${path}"
					alert high "host-advance: self-heal removal failed" "rm ${path} failed during lossless self-heal (untracked file identical to origin/main, behind=${BEHIND}); host state left as-is — investigate manually."
					exit 1
				fi
				log "self-heal: removed untracked file identical to origin/main: ${path}"
				healed=$((healed + 1)); healed_list="${healed_list}${path} "
			fi
			;;
		esac
	done < <(git -C "$REPO_DIR" status --porcelain -z --untracked-files=all)
	if [ "$healed" -gt 0 ]; then
		alert default "host-advance: self-healed ${healed} file(s)" "Absorbed lossless working-tree dirt identical to origin/main before FF pull: ${healed_list}— something wrote git-tracked content outside git (rsync leg?); the pull proceeds, but the writer should be identified."
	fi
}

if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	log "ERROR: not a git checkout: $REPO_DIR"
	exit 2
fi

# Mutual exclusion between the deploy-time invocation and the daily cron
# (see the header's Concurrency paragraph). Lockfile lives inside the
# checkout's own git dir: per-checkout by construction and never tracked.
# --absolute-git-dir, not --git-dir: a worktree's .git is a FILE (so
# "$REPO_DIR/.git/" would be wrong), and the non-absolute form can return
# a path relative to the repo dir, which would resolve against our cwd.
# No flock (macOS dev/test) -> skip; behavior is unchanged from before.
if command -v flock >/dev/null 2>&1; then
	LOCKFILE="$(git -C "$REPO_DIR" rev-parse --absolute-git-dir)/fyd-advance.lock"
	exec 9>"$LOCKFILE"
	if ! flock -w "${FYD_LOCK_TIMEOUT:-120}" 9; then
		log "ERROR: lock timeout — another advance has held ${LOCKFILE} for >${FYD_LOCK_TIMEOUT:-120}s"
		alert high "host-advance: lock timeout" "another advance has held the lock >${FYD_LOCK_TIMEOUT:-120}s (${LOCKFILE}); investigate — an advance run (deploy-time or cron) appears wedged."
		exit 1
	fi
fi

if ! git -C "$REPO_DIR" fetch --quiet origin main 2>/dev/null; then
	log "ERROR: git fetch origin main failed"
	alert default "host-advance: fetch failed" "git fetch origin main failed on the validator host; next tick retries."
	exit 2
fi

AHEAD="$(git -C "$REPO_DIR" rev-list --count origin/main..HEAD)"
BEHIND="$(git -C "$REPO_DIR" rev-list --count HEAD..origin/main)"

# Host must NEVER author — refuse and make no changes whatsoever.
if [ "$AHEAD" != "0" ]; then
	log "REFUSED: host is ${AHEAD} commit(s) ahead of origin/main; making no changes"
	alert high "host-advance: refused (host has local commits)" "host HEAD is ahead=${AHEAD} commit(s) of origin/main — a host must never author commits. No changes were made; investigate and reconcile manually."
	exit 1
fi

if [ "$BEHIND" = "0" ]; then
	log "already in sync: ahead=0 behind=0"
	exit 0
fi

OLD_HEAD="$(git -C "$REPO_DIR" rev-parse --short HEAD)"

# Preserve any host-authored anchor-source.json dirt BEFORE the blanket
# public/ discard below can silently take it (see header comment /
# protect_anchor_source_pre_discard). No-op if the file is clean or
# byte-identical to HEAD.
protect_anchor_source_pre_discard

# Discard ONLY public/ working-tree dirt, never anything else. This is safe
# specifically because this host is internal, not the public origin: Caddy
# here binds 127.0.0.1:${BEHIND_PROXY_PORT:-8085} only (plain HTTP, loopback)
# per docker-compose.behind-proxy.yml:20 — real traffic is served from
# Xserver, so nothing user-facing ever reads this host's public/ working
# tree. Deploy legs stamp cache-bust markers (?v=<sha>) into public/*.html
# here, which is exactly the dirt that blocks a clean FF pull; the next
# deploy re-stamps it regardless of what we discard now. (Any real
# anchor-source.json dirt was already pulled out of this path's way by
# protect_anchor_source_pre_discard above, so this unconditional discard
# cannot lose it — the EXIT trap restores it if the script stops here.)
if ! git -C "$REPO_DIR" checkout -- public/ 2>/dev/null; then
	log "ERROR: failed to discard public/ working-tree dirt"
	alert high "host-advance: public/ discard failed" "git checkout -- public/ failed while preparing an FF-only pull (behind=${BEHIND}); host state left as-is beyond that attempt — investigate manually."
	exit 1
fi

self_heal_lossless_dirt

# Snapshot this path's blob at (pre-pull) HEAD so resolve_anchor_source_
# post_pull can tell, after a successful pull, whether the incoming commits
# touched it at all. Empty string if the path did not exist at HEAD (should
# not happen in production — anchor-source.json is a required, already-
# committed artifact — but rev-parse fails safe rather than aborting under
# `set -e` if it ever did).
OLD_ANCHOR_HASH="$(git -C "$REPO_DIR" rev-parse "HEAD:${ANCHOR_SOURCE_REL}" 2>/dev/null || echo '')"

# FF-only, never reset/merge. If a tracked file OUTSIDE public/ has
# uncommitted edits that the incoming diff would overwrite, git itself
# refuses the merge rather than lose data — we surface that as a loud
# alert instead of forcing it through.
if PULL_OUT="$(git -C "$REPO_DIR" pull --ff-only origin main 2>&1)"; then
	NEW_HEAD="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
	NEW_ANCHOR_HASH="$(git -C "$REPO_DIR" rev-parse "HEAD:${ANCHOR_SOURCE_REL}" 2>/dev/null || echo '')"
	if ! resolve_anchor_source_post_pull "$OLD_ANCHOR_HASH" "$NEW_ANCHOR_HASH"; then
		# Advance itself succeeded (HEAD is current); only the anchor-
		# source.json stash step failed. Still a loud, non-zero exit — see
		# resolve_anchor_source_post_pull's own comment for why the
		# canonical path is nonetheless already correct.
		exit 1
	fi
	log "advanced: behind ${BEHIND} → 0 (${OLD_HEAD}..${NEW_HEAD})"
	exit 0
else
	log "ERROR: ff-only pull failed: ${PULL_OUT}"
	alert high "host-advance: ff-only pull failed" "git pull --ff-only origin main failed (behind=${BEHIND}): ${PULL_OUT}"
	exit 1
fi

# Close of the stdin-hardening brace group opened right after `set -euo
# pipefail` — see the comment there.
} </dev/null
