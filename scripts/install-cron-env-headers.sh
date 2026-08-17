#!/usr/bin/env bash
# install-cron-env-headers.sh — add the missing SHELL=/bin/bash + PATH env
# headers (and, where required, FY_LIVE=1) to project cron files under
# /etc/cron.d/.
#
# Motivation: docs/CRON_CONVENTIONS.md (linter rule 5) requires every
# /etc/cron.d/metal-* file to set SHELL=/bin/bash and an explicit PATH at the
# top. The 2026-07-06 stocktake found 7 project cron files missing one or both
# headers — they run under cron's default /bin/sh + minimal PATH, which is
# exactly the class of latent breakage the convention exists to prevent.
#
# 2026-08-06: also closes the equivalent gap for FY_LIVE=1
# (check-cron-file.sh Rule 6). scripts/lib/side-effects.sh (the C3 rollout)
# gates the production side effects that route THROUGH it — a
# fyd_notify-wrapped ntfy push, a /var/lib/freedom-yield state write — behind
# FY_LIVE=1. It does not reach inside notify.sh or push-to-web-host.sh:
# neither carries a gate of its own. What covers that gap differs between the
# two — every call site of notify.sh in this repo goes through the fyd_notify
# wrapper, so the flag still bites there, while push-to-web-host.sh is
# invoked directly everywhere and Rule 6 requires the flag on its crons as
# allowlist POLICY rather than because the script reads it (the settled
# account is docs/CRON_CONVENTIONS.md's Rule 6 section). The
# scripts/install-*-cron.sh generators now write the flag into every NEW
# install, but a file installed before this landed has no way to pick it up
# except a full re-run of its (sometimes root-only, sometimes
# vps-bootstrap.sh-embedded) installer. This script is the existing,
# already-designed-for-exactly-this-job remediation path for an
# already-deployed file: point it at the live /etc/cron.d and it adds only
# the missing header(s), leaving the command body untouched. Selective, not
# blanket — it adds FY_LIVE=1 only to a file that actually references a
# side-effecting script (same detection as check-cron-file.sh Rule 6; the
# allowlist below MUST stay identical to that script's copy — see the
# cross-file consistency case in tests/check-cron-file/), so a genuinely
# read-only cron never grows an unused line.
#
# Behavior:
#   - Scope: files matching /etc/cron.d/metal-* OR /etc/cron.d/freedom-yield-*
#     ONLY (this project's two live cron.d prefixes; never touches other
#     projects' cron files). 2026-08-06 host audit (docs/audits/
#     constitution-2026-07-07-host-state-audit.md:35) found the live host
#     carries 15 project cron files, one of them freedom-yield-peer-geo — an
#     orphan with no repo installer of its own (scripts/peer-geo.py, cron-
#     invoked, calls push-to-web-host.sh). Scoping to metal-* only would
#     leave that cron permanently unreachable by this remediation path.
#   - Idempotent: files already carrying every required header are left
#     byte-identical.
#   - Skips (never reads-as-a-target-to-mutate) any matched path whose
#     basename is not a filename cron.d would actually execute. Per
#     crontab(5) (Debian's cron), a /etc/cron.d/ file is only picked up if
#     its name consists solely of upper/lower case letters, digits,
#     underscores, and hyphens — the same rule run-parts(8) enforces for
#     cron.daily/weekly/monthly. A name outside that set (any dot, tilde,
#     etc.) — most often a backup/rotation sidecar such as
#     *.bak-<UTC timestamp>, *.disabled, *.orig, *.dpkg-old, *~ — is
#     silently ignored by cron itself, so rewriting one here would corrupt a
#     point-in-time record without touching anything cron actually runs.
#     2026-08-06 production --dry-run found exactly this: two *.bak-<ts>
#     files under metal-* reported "would fix". Each skip is printed (never
#     silent) as "skipped (not a cron-executed filename): <name>" and
#     counted separately in the summary.
#   - Insertion point: after the leading comment block (matching the style of
#     the already-compliant files), before the first env/command line.
#   - Only the missing header(s) are added; an existing PATH= (or FY_LIVE=1)
#     is never edited.
#   - A file carrying a WRONG SHELL value (SHELL= present but not /bin/bash)
#     is left untouched and flagged with a warning: prepending SHELL=/bin/bash
#     above it would be defeated (cron honors the later assignment), and
#     silently rewriting an operator-authored value is not this installer's
#     call. Operator review required for such files.
#   - Every modified file is first copied to the backup dir.
#   - cron picks up /etc/cron.d mtime changes automatically; no reload needed.
#
# Usage (validator host, as root):
#   sudo bash scripts/install-cron-env-headers.sh            # apply
#   sudo bash scripts/install-cron-env-headers.sh --dry-run  # report only
#
# Env overrides (test-time):
#   FYD_CRON_DIR         cron dir to scan (default /etc/cron.d). When
#                        overridden, the root requirement is waived (test
#                        harness mode).
#   FYD_BACKUP_DIR       backup destination (default /var/backups/metal-cron-
#                        env-headers-<UTC timestamp>)
#   FYD_CRON_SCRIPTS_DIR scripts/ dir used to resolve a referenced *.sh
#                        basename for the FY_LIVE=1 side-effect check
#                        (default: this script's own directory). Test-only
#                        knob — see check-cron-file.sh, which shares the name.
#
# Exit codes:
#   0  success (including "nothing to do")
#   1  usage error
#   2  not root (and FYD_CRON_DIR not overridden)
#   3  a modified file failed post-edit verification (backup restored)

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		-h|--help) sed -n '2,36p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*) echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

CRON_DIR="${FYD_CRON_DIR:-/etc/cron.d}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups/metal-cron-env-headers-${STAMP}}"

if [ "$CRON_DIR" = "/etc/cron.d" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: must run as root to edit /etc/cron.d (usage: sudo bash $0)" >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/cron-filename-guard.sh
. "${SCRIPT_DIR}/lib/cron-filename-guard.sh"

SHELL_LINE='SHELL=/bin/bash'
PATH_LINE='PATH=/usr/local/bin:/usr/bin:/bin'
FY_LIVE_LINE='FY_LIVE=1'

# ---------------------------------------------------------------------------
# FY_LIVE=1 side-effect detection — MUST stay identical to check-cron-file.sh
# Rule 6's copy (allowlist + dynamic-resolve logic). Duplicated rather than
# shared via a sourced lib, same tradeoff scripts/lib/side-effects.sh itself
# accepts for FYD_PUSH_FILENAME_RE: a lock-step test (tests/check-cron-file/)
# greps both files and fails if the lists diverge, so drift is caught rather
# than prevented by construction.
# ---------------------------------------------------------------------------
KNOWN_SIDE_EFFECT_CRON_BASENAMES="notify.sh push-to-web-host.sh notify-anchor-transition.sh watch-anchor-events.sh check-anchor-publish-health.sh check-host-drift.sh advance-host-checkout.sh check-watch-validators.sh daily-status.sh check-anomalies.sh"

CRON_ENV_HEADERS_SCRIPTS_DIR="${FYD_CRON_SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"

basename_is_side_effecting() {
	local bn="$1"
	# shellcheck disable=SC2086  # intentional word-split of the space-separated list
	if printf '%s\n' $KNOWN_SIDE_EFFECT_CRON_BASENAMES | grep -qxF "$bn"; then
		return 0
	fi
	local candidate="${CRON_ENV_HEADERS_SCRIPTS_DIR}/${bn}"
	if [ -r "$candidate" ] && grep -qE 'side-effects\.sh' "$candidate" 2>/dev/null; then
		return 0
	fi
	return 1
}

# cron_file_needs_fy_live <path> — true (rc 0) iff the file references at
# least one side-effecting script (per basename_is_side_effecting) AND does
# not already carry a bare 'FY_LIVE=1' line. Scans command lines only
# (comments and existing env assignments excluded), matching
# check-cron-file.sh's CRON_LINES filter.
cron_file_needs_fy_live() {
	local f="$1"
	if grep -qE '^FY_LIVE=1$' "$f"; then
		return 1
	fi
	local bn
	while IFS= read -r bn; do
		[ -z "$bn" ] && continue
		if basename_is_side_effecting "$bn"; then
			return 0
		fi
	done < <(grep -vE '^[[:space:]]*(#|$)' "$f" | grep -vE '^[A-Z_]+=' \
		| grep -oE 'scripts/[A-Za-z0-9_.-]+\.sh' | sed -E 's#^scripts/##' | sort -u || true)
	return 1
}

# is_cron_executed_filename() — sourced above from
# scripts/lib/cron-filename-guard.sh, not redefined here. (2026-08-06, H3
# task: this used to be an inline copy with a comment claiming a
# tests/install-cron-env-headers/ + tests/install-repoint-publish-crons/
# "lock-step consistency check" kept it in sync with the sibling installer's
# copy — no such cross-file test ever existed; each suite only ran its own
# self-contained mutation check. The fix is structural, not another test to
# keep in sync by convention: there is now exactly one definition, in the
# shared lib, and tests/cron-filename-guard/ checks that — scoped to
# scripts/+.githooks/+bin/ across several definition syntax shapes, not a
# claim that the string never appears again anywhere in the repo. See that
# lib's own header comment for the exact scope.)

CHANGED=0
SKIPPED=0
WARNED=0
SKIPPED_NOT_CRON=0

# Two prefixes: metal-* (the common case) and freedom-yield-* (orphan crons
# with no repo installer, e.g. freedom-yield-peer-geo — see the Scope note
# above). Neither pattern matching anything is tolerated the same way a bare
# metal-* with no hits always has been: [ -f "$f" ] below skips the literal
# unexpanded glob string.
for f in "$CRON_DIR"/metal-* "$CRON_DIR"/freedom-yield-*; do
	[ -f "$f" ] || continue
	bn="$(basename "$f")"

	# Not a filename cron.d would ever execute (see is_cron_executed_filename
	# above) — most often a *.bak-<ts>/*.disabled/*.orig sidecar. Skip loudly,
	# never mutate: this is the one class of file where "fixing" it would
	# corrupt a point-in-time record rather than change anything cron runs.
	if ! is_cron_executed_filename "$bn"; then
		SKIPPED_NOT_CRON=$((SKIPPED_NOT_CRON + 1))
		echo "skipped (not a cron-executed filename): $bn"
		continue
	fi

	need_shell=1; need_path=1; need_fy_live=0
	grep -qE '^SHELL=/bin/bash\b' "$f" && need_shell=0
	grep -qE '^PATH=' "$f" && need_path=0
	if cron_file_needs_fy_live "$f"; then
		need_fy_live=1
	fi

	# Wrong-value SHELL (present but not /bin/bash): do NOT touch. Prepending
	# SHELL=/bin/bash would be defeated by the later assignment (cron honors
	# the last one), and rewriting an operator-authored value is an operator
	# decision, not this installer's.
	if [ "$need_shell" -eq 1 ] && grep -qE '^SHELL=' "$f"; then
		WARNED=$((WARNED + 1))
		echo "warn:    ${bn} carries $(grep -E '^SHELL=' "$f" | head -1) (not /bin/bash) — left untouched; operator review required (FY_LIVE check also skipped)"
		continue
	fi

	if [ "$need_shell" -eq 0 ] && [ "$need_path" -eq 0 ] && [ "$need_fy_live" -eq 0 ]; then
		SKIPPED=$((SKIPPED + 1))
		echo "ok:      ${bn} (all required headers present)"
		continue
	fi

	missing=""
	[ "$need_shell" -eq 1 ] && missing="SHELL"
	[ "$need_path"  -eq 1 ] && missing="${missing:+$missing+}PATH"
	[ "$need_fy_live" -eq 1 ] && missing="${missing:+$missing+}FY_LIVE"

	if [ "$DRY_RUN" -eq 1 ]; then
		echo "would fix: ${bn} (missing: $missing)"
		CHANGED=$((CHANGED + 1))
		continue
	fi

	mkdir -p "$BACKUP_DIR"
	cp -p "$f" "$BACKUP_DIR/${bn}"

	# Insert the missing header(s) after the leading comment/blank block —
	# the position the already-compliant project cron files use.
	tmp="$(mktemp)"
	awk -v add_shell="$need_shell" -v add_path="$need_path" -v add_fy_live="$need_fy_live" \
		-v shell_line="$SHELL_LINE" -v path_line="$PATH_LINE" -v fy_live_line="$FY_LIVE_LINE" '
		BEGIN { inserted = 0 }
		{
			if (!inserted && $0 !~ /^[[:space:]]*(#|$)/) {
				if (add_shell == 1) print shell_line
				if (add_path == 1) print path_line
				if (add_fy_live == 1) print fy_live_line
				inserted = 1
			}
			print
		}
		END {
			if (!inserted) {
				if (add_shell == 1) print shell_line
				if (add_path == 1) print path_line
				if (add_fy_live == 1) print fy_live_line
			}
		}
	' "$f" > "$tmp"

	# Preserve mode/ownership of the original (cron.d requires root:root 0644).
	chmod --reference="$f" "$tmp" 2>/dev/null || chmod 644 "$tmp"
	chown --reference="$f" "$tmp" 2>/dev/null || true
	mv "$tmp" "$f"

	# Post-edit verification (linter rule 5 equivalent, + FY_LIVE=1 when this
	# file needed it). Restore on failure.
	VERIFY_OK=1
	grep -qE '^SHELL=/bin/bash\b' "$f" || VERIFY_OK=0
	grep -qE '^PATH=' "$f" || VERIFY_OK=0
	if [ "$need_fy_live" -eq 1 ]; then
		grep -qE '^FY_LIVE=1$' "$f" || VERIFY_OK=0
	fi
	if [ "$VERIFY_OK" -eq 0 ]; then
		echo "ERROR: post-edit verification failed for $f — restoring backup" >&2
		cp -p "$BACKUP_DIR/${bn}" "$f"
		exit 3
	fi

	CHANGED=$((CHANGED + 1))
	echo "fixed:   ${bn} (added: $missing)"
done

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
	echo "DRY-RUN summary: would fix ${CHANGED}, already compliant ${SKIPPED}, needs operator review ${WARNED}, skipped (not cron-executed) ${SKIPPED_NOT_CRON}"
else
	echo "summary: fixed ${CHANGED}, already compliant ${SKIPPED}, needs operator review ${WARNED}, skipped (not cron-executed) ${SKIPPED_NOT_CRON}"
	[ "$CHANGED" -gt 0 ] && echo "backups: ${BACKUP_DIR}/"
fi
exit 0
