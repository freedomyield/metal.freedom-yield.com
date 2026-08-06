#!/usr/bin/env bash
# scripts/lib/cron-filename-guard.sh — is_cron_executed_filename(), the
# single canonical definition of "would cron.d actually run a file with
# this name".
#
# CHAIN: none — this file defines a shell function only. It never invokes
#        a broadcast-capable command and offers no route to one.
#
# Why this exists (2026-08-06, H2 task, then H3 same day): is_cron_executed_
# filename() was introduced the same day inside
# scripts/install-cron-env-headers.sh (and duplicated into
# scripts/install-repoint-publish-crons.sh) — each with a comment claiming a
# tests/install-cron-env-headers/ + tests/install-repoint-publish-crons/
# "lock-step consistency check" kept the two copies in sync. That test never
# existed: each suite only ran its own self-contained mutation check against
# its own inline copy, so nothing would have caught the two drifting apart.
# The H2 brief asked the new remediation script this lib was extracted for
# NOT to duplicate that logic a third time. The H3 task then went further
# and closed the original duplication too: both install-cron-env-headers.sh
# and install-repoint-publish-crons.sh now source this file instead of
# defining the function inline. This is the ONLY definition in the repo —
# tests/cron-filename-guard/ asserts that repo-wide (grep for exactly one
# match, mutation-tested by adding a second definition to a scratch copy and
# confirming the check goes red).
#
# Per crontab(5) (Debian's cron), a /etc/cron.d/ entry is only read if its
# name consists solely of upper/lower case letters, digits, underscores,
# and hyphens — identical to run-parts(8)'s own filename rule for
# cron.daily/weekly/monthly. Anything outside that set (a dot, a tilde,
# ...) is a name cron silently ignores — most often a backup/rotation
# sidecar (*.bak-<ts>, *.disabled, *.orig, *.dpkg-old, *~). This is a
# positive allowlist check ("would cron run this"), not a denylist of known
# sidecar suffixes — a new sidecar convention needs no update here.
#
# Usage:
#   . "$(dirname "$0")/lib/cron-filename-guard.sh"
#   if is_cron_executed_filename "$basename"; then ...; fi
#
# Not meant to be executed directly (defines a function; has no side
# effects when sourced).

is_cron_executed_filename() {
	case "$1" in
		*[!A-Za-z0-9_-]*) return 1 ;;
		*) return 0 ;;
	esac
}
