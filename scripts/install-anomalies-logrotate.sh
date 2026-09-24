#!/usr/bin/env bash
# install-anomalies-logrotate.sh — install /etc/logrotate.d/anomalies: 90-day
# retention for the anomaly detector's cron log and the public-site probe's
# diagnostics + blip logs, and provision those two logs deploy-writable.
#
# CHAIN: none — writes one logrotate config and touches log files.
# PRIME_DIRECTIVE: TESTNET-FIRST — no broadcast pathway here or downstream.
#
# Why (docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# §3.5, goal G5): the 2026-09-21/23 public-site alerts could not be explained
# after the fact, partly because /var/log/anomalies.log kept only 7 days. The
# new diagnostics log (anomalies-web-diag.log) and incident log
# (anomalies-web-blips.log) are what a later digest or a hosting-provider
# support inquiry reads, so all three are kept 90 days.
#
# Single source: scripts/vps-bootstrap.sh calls this installer instead of
# carrying its own heredoc, so a fresh host and a remediated host cannot
# drift apart.
#
# Why this installer also provisions the two new logs: check-anomalies.sh runs
# as `deploy` and /var/log is root-owned, so `deploy` cannot create a file
# there (the 2026-06-19 metal-evidence failure, docs/CRON_CONVENTIONS.md
# Rule 1). They are created once here as root, owned by the deploy user,
# 0644 — the same pre-provisioning vps-bootstrap.sh does for anomalies.log.
# An existing log is never truncated.
#
# Backups of a differing prior config go to FYD_BACKUP_DIR, never next to the
# target: logrotate reads every file in /etc/logrotate.d, and a
# "*.bak-<stamp>" sidecar is not on its taboo-extension list, so it would be
# loaded as a second config for the same logs.
#
# Validation context (2026-09-24 fix, round 1): `logrotate -d` on the
# candidate standalone is the WRONG check. On the validator host /var/log is
# `root:syslog 0775` (group-writable), which logrotate treats as insecure
# UNLESS a `su` directive is in effect — and the host's `su root adm` lives
# in the global section of /etc/logrotate.conf, not in this snippet. A
# standalone check never sees that global `su`, so it fails with "parent
# directory has insecure permissions" even though the real daily run (which
# always goes through logrotate.conf's `include /etc/logrotate.d`) rotates
# fine.
#
# "Every global directive in the main config" is ALSO the wrong join,
# because logrotate applies directives top-to-bottom and only in lexical
# scope: a directive placed AFTER `include /etc/logrotate.d` does not apply
# to files pulled in by that include (verified empirically — `su` placed
# after the include still leaves those files "insecure"; a stanza placed
# after the include, e.g. some hosts' trailing `/var/log/wtmp {...}`, is
# also never in scope for our snippet). So the candidate is validated
# joined only to the main config's lines that appear BEFORE the include
# line that pulls in the candidate's own directory (`dirname` of TARGET —
# `/etc/logrotate.d` in production); any OTHER `include` line before that
# point is also dropped, since it would only pull in unrelated snippets we
# have no reason to validate against. Everything from the matching include
# line onward is never part of the join. If no include of the target's
# directory is found in the main config at all, this falls back to
# treating every non-include line as in scope (better than skipping
# validation outright over an atypically-structured main config). Either
# way this all happens in a throwaway temp file, against a throwaway state
# file — the installed snippet content itself is unaffected; only how it is
# checked changes. If the main config is missing entirely, validation falls
# back further, to the candidate alone (the pre-2026-09-24 behavior).
#
# Usage (validator host, as root):
#   sudo bash scripts/install-anomalies-logrotate.sh
#
# Env overrides (test harness):
#   FYD_LOGROTATE_TARGET  config file to write (default /etc/logrotate.d/anomalies).
#                         When overridden, the root requirement is waived and
#                         no ownership is enforced.
#   FYD_LOG_DIR           directory holding the three logs (default /var/log)
#   FYD_DEPLOY_USER       owner of the logs and of logrotate's `create`
#                         (default deploy)
#   FYD_BACKUP_DIR        backup destination (default /var/backups)
#   FYD_LOGROTATE_MAIN_CONF  main logrotate config to validate the candidate
#                         against (default /etc/logrotate.conf). For the
#                         real target, validation always runs against it (or
#                         falls back to standalone if it's missing). For a
#                         non-default (test-harness) target, validation only
#                         runs when this is explicitly set — a plain
#                         sandboxed run has neither a real main config nor
#                         real `create` users, so it keeps skipping
#                         validation entirely, as before.
#
# Exit codes:
#   0  installed or already up to date
#   2  not root (and FYD_LOGROTATE_TARGET not overridden)
#   3  log directory missing
#   4  generated config failed `logrotate -d` (nothing changed)
#
# Operator-gated: committed so the host action is one command; running it on
# the host follows operator approval (Constitution §5 / Operating Model W7).

set -euo pipefail

PROD_TARGET="/etc/logrotate.d/anomalies"
TARGET="${FYD_LOGROTATE_TARGET:-$PROD_TARGET}"
LOG_DIR="${FYD_LOG_DIR:-/var/log}"
DEPLOY_USER="${FYD_DEPLOY_USER:-deploy}"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups}"

if [ "$TARGET" = "$PROD_TARGET" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (writes /etc/logrotate.d/ and provisions /var/log files)" >&2
	echo "       usage: sudo bash scripts/install-anomalies-logrotate.sh" >&2
	exit 2
fi
if [ ! -d "$LOG_DIR" ]; then
	echo "ERROR: log directory missing: ${LOG_DIR}" >&2
	exit 3
fi

read -r -d '' EXPECTED <<CONF || true
# Managed by scripts/install-anomalies-logrotate.sh — edit the installer, not this file.
# 90-day retention: web-probe design spec 2026-09-24 §3.5 (G5).
${LOG_DIR}/anomalies.log ${LOG_DIR}/anomalies-web-diag.log ${LOG_DIR}/anomalies-web-blips.log {
  daily
  rotate 90
  compress
  missingok
  notifempty
  create 644 ${DEPLOY_USER} ${DEPLOY_USER}
}
CONF

MAIN_CONF="${FYD_LOGROTATE_MAIN_CONF:-/etc/logrotate.conf}"
TARGET_DIR="$(dirname "$TARGET")"

TMP="$(mktemp)"
VALIDATE_TMP="$(mktemp)"
trap 'rm -f "$TMP" "$VALIDATE_TMP" "${VALIDATE_TMP}.state"' EXIT
printf '%s\n' "$EXPECTED" >"$TMP"

# Parse check with logrotate itself (debug mode changes nothing; a scratch
# state file keeps /var/lib/logrotate/status untouched) — but not the
# candidate alone, and not the whole main config either. It is validated in
# the same context the daily run gives it: joined only to the main config's
# lines that precede its `include` of the candidate's own directory (see
# the "Validation context" header comment above for why position matters).
# Runs for the real target always; for a test-harness target only when
# FYD_LOGROTATE_MAIN_CONF was explicitly set, so the default sandboxed run
# (fake `create` owner, no real main config) keeps skipping validation
# exactly as before.
if command -v logrotate >/dev/null 2>&1 \
	&& { [ "$TARGET" = "$PROD_TARGET" ] || [ -n "${FYD_LOGROTATE_MAIN_CONF:-}" ]; }; then
	if [ -f "$MAIN_CONF" ]; then
		# Line number of the `include <TARGET_DIR>` directive, if any —
		# exact string match on the include's argument (after trimming
		# surrounding whitespace), not a path-prefix or glob match.
		TARGET_INCLUDE_LINE="$(awk -v d="$TARGET_DIR" '
			{
				line = $0
				sub(/^[ \t]+/, "", line)
				sub(/[ \t]+$/, "", line)
				if (line ~ /^include[ \t]+/) {
					arg = line
					sub(/^include[ \t]+/, "", arg)
					if (arg == d) { print NR; exit }
				}
			}
		' "$MAIN_CONF")"
		if [ -n "$TARGET_INCLUDE_LINE" ]; then
			# Only what precedes that include is in scope for our snippet —
			# logrotate reads top-to-bottom, so anything after (including
			# the include line itself, and any trailing host-specific
			# stanza some main configs put after their
			# `include /etc/logrotate.d`) never applies to files it pulls
			# in. Any OTHER include line before that point is still
			# dropped: it would only pull in unrelated snippets.
			head -n "$((TARGET_INCLUDE_LINE - 1))" "$MAIN_CONF" \
				| grep -Ev '^[[:space:]]*include([[:space:]]|$)' >"$VALIDATE_TMP" || true
		else
			# No include of our directory found at all — fall back to
			# treating every non-include line as in scope.
			grep -Ev '^[[:space:]]*include([[:space:]]|$)' "$MAIN_CONF" >"$VALIDATE_TMP" || true
		fi
		printf '%s\n' "$EXPECTED" >>"$VALIDATE_TMP"
	else
		cp "$TMP" "$VALIDATE_TMP"
	fi
	if ! logrotate -d -s "${VALIDATE_TMP}.state" "$VALIDATE_TMP" >/dev/null 2>&1; then
		echo "ERROR: generated config failed 'logrotate -d' (validated against ${MAIN_CONF}'s directives preceding its include of ${TARGET_DIR}) — nothing changed" >&2
		logrotate -d -s "${VALIDATE_TMP}.state" "$VALIDATE_TMP" 2>&1 | tail -5 >&2 || true
		exit 4
	fi
fi

for name in anomalies.log anomalies-web-diag.log anomalies-web-blips.log; do
	f="${LOG_DIR}/${name}"
	if [ ! -e "$f" ]; then
		: >"$f"
		echo "provisioned: ${f}"
	fi
	if [ "$TARGET" = "$PROD_TARGET" ]; then
		chown "${DEPLOY_USER}:${DEPLOY_USER}" "$f"
	fi
	chmod 0644 "$f"
done

if [ -f "$TARGET" ] && [ "$(cat "$TARGET")" = "$EXPECTED" ]; then
	echo "ok: ${TARGET} already up to date (no change)"
	exit 0
fi

if [ -f "$TARGET" ]; then
	STAMP="$(date -u +%Y%m%d-%H%M%S)"
	mkdir -p "$BACKUP_DIR"
	cp -p "$TARGET" "${BACKUP_DIR}/logrotate-$(basename "$TARGET").bak-${STAMP}"
	echo "backed up prior target to ${BACKUP_DIR}/logrotate-$(basename "$TARGET").bak-${STAMP}"
fi

if [ "$TARGET" = "$PROD_TARGET" ]; then
	install -m 0644 -o root -g root "$TMP" "$TARGET"
else
	install -m 0644 "$TMP" "$TARGET"
fi
echo "installed: ${TARGET} (daily, rotate 90, compress; create 644 ${DEPLOY_USER} ${DEPLOY_USER})"
echo "logs:      ${LOG_DIR}/anomalies.log ${LOG_DIR}/anomalies-web-diag.log ${LOG_DIR}/anomalies-web-blips.log"
