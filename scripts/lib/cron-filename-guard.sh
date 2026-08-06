#!/usr/bin/env bash
# scripts/lib/cron-filename-guard.sh — is_cron_executed_filename(), the
# single canonical definition of "would cron.d actually run a file with
# this name".
#
# CHAIN: none — this file defines a shell function only. It never invokes
#        a broadcast-capable command and offers no route to one.
#
# Why this exists (2026-08-06, H2 task): is_cron_executed_filename() was
# introduced the same day inside scripts/install-cron-env-headers.sh (and
# duplicated into scripts/install-repoint-publish-crons.sh, kept in
# lock-step by convention rather than by a shared source). The H2 brief
# explicitly asked the new remediation script this lib was extracted for
# NOT to duplicate that logic a third time — so this file is the reusable
# copy: source it and call the function, instead of pasting the case
# pattern again. The two pre-existing inline copies in
# install-cron-env-headers.sh and install-repoint-publish-crons.sh are left
# as-is (out of this task's scope to touch already-shipped, already-tested
# installers); a future cleanup could point them at this lib too.
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
