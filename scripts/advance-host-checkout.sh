#!/usr/bin/env bash
# advance-host-checkout.sh — self-healing FF-only advance of the validator-host
# git checkout to origin/main.
#
# Motivation: on 2026-07-09 the validator host was found 21 commits behind
# origin/main (the `host-drift: checkout diverging` tripwire). Investigation
# found nothing in any deploy leg ever advances host HEAD — deploy.yml rsyncs
# files but excludes .git/, check-host-drift.sh is read-only by design, and
# sync-to-validator-host.sh only rsyncs scripts/. Compounding it, deploy
# stamps cache-bust markers (?v=<sha>) into public/*.html on the host,
# dirtying the tree so a naive `git pull --ff-only` aborts. This script closes
# that loop: it is the primary self-heal (see
# docs/superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md §2①);
# check-host-drift.sh remains as the read-only backstop that detects if this
# script ever stops running.
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
#      `git pull --ff-only origin main`.
#        - success -> log behind N -> 0 (old..new), exit 0
#        - failure -> alert high, exit 1
#
# NEVER: `git reset --hard`, `git merge`, discarding anything outside
# public/, or invoking any broadcast-capable command (proton / cleos /
# bin/safe-broadcast / any RPC push_transaction equivalent) — this script
# does not touch broadcast machinery at all.
#
# Usage:
#   bash scripts/advance-host-checkout.sh
#
# Env overrides (test-time + ops):
#   FYD_REPO_DIR   repo checkout to advance (default: this script's repo)
#   FYD_NOTIFY     notifier to invoke (default: <script dir>/notify.sh)
#
# Exit codes:
#   0  already in sync, or successfully advanced to origin/main
#   1  refused (host ahead of origin) OR public/ discard failed OR
#      ff-only pull failed (e.g. a non-public tracked file has uncommitted
#      edits that the incoming diff would clobber — git refuses the merge
#      rather than lose data, and so do we)
#   2  fetch failed, or REPO_DIR is not a git checkout (both transient /
#      environmental; next tick retries)
#
# Cron: scripts/install-metal-host-advance-cron.sh, scheduled to run BEFORE
# the check-host-drift.sh daily tripwire so a healthy self-heal clears drift
# before the backstop samples it.

# No `-e`... actually not needed here: unlike check-host-drift.sh's
# `[ cond ] && VAR=` drift-accumulation idiom, this script has exactly two
# operations that can legitimately fail in normal operation (the fetch and
# the ff-only pull), and both are guarded by an explicit `if ! ...; then` /
# `if VAR=$(...); then` test — which is exempt from `set -e` by POSIX
# semantics, so their failure is handled deliberately rather than tripping
# the trap. Everything else (rev-list --count, checkout -- public/) is
# expected to succeed once fetch has already succeeded against real refs;
# if one of those somehow still fails, aborting immediately via `set -e`
# is the safer default for host-mutating automation than silently
# continuing on an unknown repo state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${FYD_REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
NOTIFY="${FYD_NOTIFY:-${SCRIPT_DIR}/notify.sh}"

log() { printf '[advance-host-checkout] %s\n' "$*"; }

alert() {
	# alert <priority> <title> <message>
	if [ -x "$NOTIFY" ] || [ -f "$NOTIFY" ]; then
		bash "$NOTIFY" "$1" "$2" "$3" || log "WARN: notify failed (alert was: $2 — $3)"
	else
		log "WARN: notifier not found at $NOTIFY (alert was: $2 — $3)"
	fi
}

if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	log "ERROR: not a git checkout: $REPO_DIR"
	exit 2
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

# Discard ONLY public/ working-tree dirt, never anything else. This is safe
# specifically because this host is internal, not the public origin: Caddy
# here binds 127.0.0.1:${BEHIND_PROXY_PORT:-8085} only (plain HTTP, loopback)
# per docker-compose.behind-proxy.yml:20 — real traffic is served from
# Xserver, so nothing user-facing ever reads this host's public/ working
# tree. Deploy legs stamp cache-bust markers (?v=<sha>) into public/*.html
# here, which is exactly the dirt that blocks a clean FF pull; the next
# deploy re-stamps it regardless of what we discard now.
if ! git -C "$REPO_DIR" checkout -- public/ 2>/dev/null; then
	log "ERROR: failed to discard public/ working-tree dirt"
	alert high "host-advance: public/ discard failed" "git checkout -- public/ failed while preparing an FF-only pull (behind=${BEHIND}); host state left as-is beyond that attempt — investigate manually."
	exit 1
fi

# FF-only, never reset/merge. If a tracked file OUTSIDE public/ has
# uncommitted edits that the incoming diff would overwrite, git itself
# refuses the merge rather than lose data — we surface that as a loud
# alert instead of forcing it through.
if PULL_OUT="$(git -C "$REPO_DIR" pull --ff-only origin main 2>&1)"; then
	NEW_HEAD="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
	log "advanced: behind ${BEHIND} → 0 (${OLD_HEAD}..${NEW_HEAD})"
	exit 0
else
	log "ERROR: ff-only pull failed: ${PULL_OUT}"
	alert high "host-advance: ff-only pull failed" "git pull --ff-only origin main failed (behind=${BEHIND}): ${PULL_OUT}"
	exit 1
fi
