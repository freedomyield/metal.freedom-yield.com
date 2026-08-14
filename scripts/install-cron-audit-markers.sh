#!/usr/bin/env bash
# install-cron-audit-markers.sh — add the missing brace-wrap + start/end
# markers + rc=$? capture (scripts/check-cron-file.sh Rules 2/3) to
# existing project cron files under /etc/cron.d/.
#
# Motivation (2026-08-06, H2 task): design spec docs/superpowers/specs/
# 2026-08-06-single-source-of-truth-design.md §8 places C3's "defense layer
# 1" on check-cron-file.sh being a binary, always-green gate. A same-day
# production audit found the opposite: Rule 6 (FY_LIVE) was 16/16 green,
# but 11 of 16 files violated Rule 3 (audit-visibility markers), several of
# them also Rule 2 (a chain redirecting only its last command — silently
# dropping the earlier commands' stdout/stderr, e.g. the live
# metal-node-info entry). The lint's exit code was non-zero from the start,
# so "lint is green" could never be used as a merge/deploy/reconciler
# signal. This script is the remediation path for a file ALREADY deployed;
# scripts/vps-bootstrap.sh (the generator for 4 of these) was fixed
# separately so a FRESH install no longer regresses.
#
# Design mirrors scripts/install-cron-env-headers.sh (the sibling
# remediation script for Rules 5/6, run against production the same day) —
# same flags, same idempotency contract, same summary shape, same
# is_cron_executed_filename() sidecar guard (reused from
# scripts/lib/cron-filename-guard.sh, not re-implemented here).
#
# Behavior:
#   - Scope: /etc/cron.d/metal-* and /etc/cron.d/freedom-yield-* only —
#     this project's two live cron.d prefixes (mirrors
#     install-cron-env-headers.sh's scope note: freedom-yield-peer-geo is a
#     repo-installer-less orphan that must still be reachable here).
#   - Idempotent: a file whose every >>-redirecting command line already
#     carries start/end markers + rc=$? capture (and, if it chains with
#     &&, is already brace-wrapped per Rule 2) is left byte-identical.
#   - Per-file granularity, like install-cron-env-headers.sh: each matched
#     file gets exactly one verdict (fixed / already compliant / needs
#     operator review / skipped-not-cron-executed).
#   - Skips (never reads-as-a-target-to-mutate) any matched path whose
#     basename is not a filename cron.d would actually execute — see
#     scripts/lib/cron-filename-guard.sh. Each skip is printed and counted.
#   - CONSERVATIVE by design: only rewrites a command line when its shape
#     is unambiguous — exactly one `>>` redirect, and NEITHER a `{ }` brace
#     group NOR an `echo` NOR an `rc=` assignment already present anywhere
#     on the line. Every violating line the 2026-08-06 production audit
#     actually found (and the metal-node-info example the H2 brief quotes)
#     is this shape: a bare command (chain) piped straight into `>>`, no
#     partial marker attempt. A line that does NOT match this shape (a
#     partial/custom marker attempt, multiple `>>` targets, etc.) is left
#     UNTOUCHED and the whole file is flagged "needs operator review" —
#     this script never guesses at how to merge into an already-nonstandard
#     line. This mirrors install-cron-env-headers.sh's WRONG-value-SHELL
#     fallback (leave it, warn, let a human decide).
#   - Rewrite preserves the schedule fields, the user field, the full
#     original command (including any internal `&&` chain, verbatim), and
#     the redirect target + any trailing fd redirection (e.g. `2>&1`)
#     UNCHANGED — only wraps the command in `{ ... }` and inserts the two
#     echo markers + `rc=$?` inside it. It never touches header lines
#     (SHELL=, PATH=, FY_LIVE=, or any other `^[A-Z_]+=` line) — that is
#     install-cron-env-headers.sh's job, not this script's.
#   - Every modified file is first copied to the backup dir.
#   - Post-edit self-verification re-checks only the lines this script
#     itself touched (not a full check-cron-file.sh run, which would also
#     report Rules 5/6 gaps this script never claims to close) — restores
#     the backup and aborts on any mismatch.
#   - cron picks up /etc/cron.d mtime changes automatically; no reload
#     needed.
#
# Usage (validator host, as root):
#   sudo bash scripts/install-cron-audit-markers.sh            # apply
#   sudo bash scripts/install-cron-audit-markers.sh --dry-run  # report only
#
# Env overrides (test-time):
#   FYD_CRON_DIR     cron dir to scan (default /etc/cron.d). When
#                    overridden, the root requirement is waived (test
#                    harness mode).
#   FYD_BACKUP_DIR   backup destination (default /var/backups/metal-cron-
#                    audit-markers-<UTC timestamp>)
#
# Exit codes:
#   0  success (including "nothing to do")
#   1  usage error
#   2  not root (and FYD_CRON_DIR not overridden)
#   3  a modified file failed post-edit self-verification (backup restored)

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		-h|--help) sed -n '2,60p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*) echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

CRON_DIR="${FYD_CRON_DIR:-/etc/cron.d}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups/metal-cron-audit-markers-${STAMP}}"

if [ "$CRON_DIR" = "/etc/cron.d" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: must run as root to edit /etc/cron.d (usage: sudo bash $0)" >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/cron-filename-guard.sh
. "${SCRIPT_DIR}/lib/cron-filename-guard.sh"

# ---------------------------------------------------------------------------
# Line classification — must stay behaviorally consistent with
# check-cron-file.sh Rules 2/3 (same repo, same regex shapes). Kept as a
# pre-check here (decides fixability), never the final arbiter: tests run
# check-cron-file.sh itself against this script's output.
# ---------------------------------------------------------------------------

is_comment_or_blank() { [[ "$1" =~ ^[[:space:]]*(#|$) ]]; }
is_env_assignment()   { [[ "$1" =~ ^[A-Z_]+= ]]; }

# line_is_compliant <line> — true (rc 0) iff this line needs no fix: either
# it has no `>>` at all (Rule 3's marker requirement does not apply), or it
# already carries start/end markers + rc=$? capture; AND, independently, if
# it carries a top-level && chain with a scope-sensitive sink (>> OR a |
# pipe), that chain is already brace-wrapped. The two checks are independent
# because Rule 3 (markers) only ever applies to a `>>` line, while Rule 2
# (brace-wrap) applies to a `&&` chain regardless of which sink it uses —
# same split as check-cron-file.sh's own Rule 2/Rule 3 comments.
#
# 2026-08-14 fix: this used to gate the ENTIRE function on `case "$line" in
# *'>>'*)`, so a line with no `>>` at all returned "compliant" immediately —
# including an unwrapped && chain piped straight to `logger` (no >> in
# sight), which is exactly the shape check-cron-file.sh Rule 2 was widened
# 2026-08-07 to catch. That silently reported a genuine violation as
# "already compliant" instead of the "needs operator review" this installer
# gives every other shape it cannot safely auto-fix (fix_line() only knows
# how to rewrite the >> form). The check below runs BEFORE the `>>` gate and
# does its own quote-stripping first (mirroring check-cron-file.sh's UNQUOTED
# construction) so that a `bash -c "A && B" | logger` wrapper — whose && is
# opaque inside a quoted argument, not a real top-level chain — is not
# misclassified as a violation.
line_is_compliant() {
	local line="$1" unquoted probe
	unquoted="$(printf '%s' "$line" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")"
	probe="$(printf '%s' "$unquoted" | sed -E 's/[0-9]*>&[0-9]+//g')"
	if printf '%s' "$probe" | grep -q '&&' && printf '%s' "$probe" | grep -qE '[>|]'; then
		printf '%s' "$probe" | grep -qE '\{[^}]*&&[^{]*\}[[:space:]]*[>|]' || return 1
	fi

	case "$line" in
		*'>>'*) : ;;
		*) return 0 ;;
	esac
	printf '%s' "$line" | grep -qE 'echo[^|]*start' || return 1
	printf '%s' "$line" | grep -qE 'echo[^|]*end' || return 1
	printf '%s' "$line" | grep -qE 'rc=\$\?' || return 1
	return 0
}

# line_is_simple_fixable <line> — true (rc 0) iff the line is the plain,
# unambiguous shape this script knows how to rewrite safely: exactly one
# `>>`, and no pre-existing `{`, `}`, `echo`, or `rc=` anywhere on the line
# (i.e. no partial/custom marker attempt to merge with or clobber).
line_is_simple_fixable() {
	local line="$1" count
	count="$(printf '%s' "$line" | grep -o '>>' | wc -l | tr -d '[:space:]')"
	[ "$count" -eq 1 ] || return 1
	case "$line" in
		*'{'*|*'}'*) return 1 ;;
		*'echo'*) return 1 ;;
		*'rc='*) return 1 ;;
	esac
	return 0
}

# fix_line <line> <label> — rewrites a simple-fixable line: brace-wraps the
# original command (chain) verbatim, prefixes it with a start marker,
# suffixes it with rc=$? capture + an end marker, and re-attaches the
# original redirect target + trailing fd redirection unchanged. Schedule
# fields and user field (the first 6 whitespace-separated tokens) pass
# through unchanged.
fix_line() {
	local line="$1" label="$2"
	local prefix rest chain redirect
	prefix="$(awk '{printf "%s %s %s %s %s %s", $1,$2,$3,$4,$5,$6}' <<<"$line")"
	rest="$(awk '{for(i=7;i<=NF;i++){printf "%s%s", (i>7?" ":""), $i}}' <<<"$line")"
	chain="$(sed -E 's/^(.*)>>.*$/\1/' <<<"$rest" | sed -E 's/[[:space:]]+$//')"
	redirect="$(sed -E 's/^.*>>(.*)$/\1/' <<<"$rest" | sed -E 's/^[[:space:]]+//')"
	# The single-quoted $(...)/$?/$rc below are deliberate literal output
	# (this cron line's markers are meant to run at cron-firing time, not
	# now) — not a missed-expansion bug.
	# shellcheck disable=SC2016
	printf '%s { echo "=== %s start $(date -u +\%%FT\%%TZ) ==="; %s; rc=$?; echo "=== %s end $(date -u +\%%FT\%%TZ) rc=$rc ==="; } >> %s' \
		"$prefix" "$label" "$chain" "$label" "$redirect"
}

CHANGED=0
SKIPPED=0
WARNED=0
SKIPPED_NOT_CRON=0

process_file() {
	local f="$1" bn
	bn="$(basename "$f")"

	if ! is_cron_executed_filename "$bn"; then
		SKIPPED_NOT_CRON=$((SKIPPED_NOT_CRON + 1))
		echo "skipped (not a cron-executed filename): $bn"
		return
	fi

	local any_review=0 any_fix=0
	local -a OUT_LINES=()
	local -a REVIEW_LINES=()

	while IFS= read -r line || [ -n "$line" ]; do
		if is_comment_or_blank "$line" || is_env_assignment "$line"; then
			OUT_LINES+=("$line")
			continue
		fi
		if line_is_compliant "$line"; then
			OUT_LINES+=("$line")
			continue
		fi
		if line_is_simple_fixable "$line"; then
			OUT_LINES+=("$(fix_line "$line" "$bn")")
			any_fix=1
			continue
		fi
		OUT_LINES+=("$line")
		any_review=1
		REVIEW_LINES+=("$line")
	done < "$f"

	if [ "$any_review" -eq 1 ]; then
		WARNED=$((WARNED + 1))
		echo "warn:    ${bn} has a command line this installer cannot safely auto-fix (partial/custom marker shape) — left untouched; operator review required"
		local rl
		for rl in "${REVIEW_LINES[@]}"; do
			echo "         ${rl}"
		done
		return
	fi

	if [ "$any_fix" -eq 0 ]; then
		SKIPPED=$((SKIPPED + 1))
		echo "ok:      ${bn} (no fix needed)"
		return
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		echo "would fix: ${bn}"
		CHANGED=$((CHANGED + 1))
		return
	fi

	mkdir -p "$BACKUP_DIR"
	cp -p "$f" "$BACKUP_DIR/${bn}"

	local tmp
	tmp="$(mktemp)"
	printf '%s\n' "${OUT_LINES[@]}" > "$tmp"

	# Post-edit self-verification: every non-header line must now be
	# compliant per this script's own check (deliberately NOT a full
	# check-cron-file.sh run — this script never claims to close Rules
	# 5/6, so a file still missing SHELL=/FY_LIVE= at this point must not
	# be reported as a failure here).
	local verify_ok=1 vline
	while IFS= read -r vline || [ -n "$vline" ]; do
		if is_comment_or_blank "$vline" || is_env_assignment "$vline"; then
			continue
		fi
		line_is_compliant "$vline" || verify_ok=0
	done < "$tmp"

	if [ "$verify_ok" -ne 1 ]; then
		echo "ERROR: post-edit self-verification failed for $f — restoring backup" >&2
		rm -f "$tmp"
		cp -p "$BACKUP_DIR/${bn}" "$f"
		exit 3
	fi

	chmod --reference="$f" "$tmp" 2>/dev/null || chmod 644 "$tmp"
	chown --reference="$f" "$tmp" 2>/dev/null || true
	mv "$tmp" "$f"

	CHANGED=$((CHANGED + 1))
	echo "fixed:   ${bn}"
}

for f in "$CRON_DIR"/metal-* "$CRON_DIR"/freedom-yield-*; do
	[ -f "$f" ] || continue
	process_file "$f"
done

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
	echo "DRY-RUN summary: would fix ${CHANGED}, already compliant ${SKIPPED}, needs operator review ${WARNED}, skipped (not cron-executed) ${SKIPPED_NOT_CRON}"
else
	echo "summary: fixed ${CHANGED}, already compliant ${SKIPPED}, needs operator review ${WARNED}, skipped (not cron-executed) ${SKIPPED_NOT_CRON}"
	[ "$CHANGED" -gt 0 ] && echo "backups: ${BACKUP_DIR}/"
fi
exit 0
