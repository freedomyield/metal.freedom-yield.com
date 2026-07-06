#!/usr/bin/env bash
# install-cron-env-headers.sh — add the missing SHELL=/bin/bash + PATH env
# headers to project cron files under /etc/cron.d/.
#
# Motivation: docs/CRON_CONVENTIONS.md (linter rule 5) requires every
# /etc/cron.d/metal-* file to set SHELL=/bin/bash and an explicit PATH at the
# top. The 2026-07-06 stocktake found 7 project cron files missing one or both
# headers — they run under cron's default /bin/sh + minimal PATH, which is
# exactly the class of latent breakage the convention exists to prevent.
#
# Behavior:
#   - Scope: files matching /etc/cron.d/metal-* ONLY (project-scoped prefix;
#     never touches other projects' cron files).
#   - Idempotent: files already carrying both headers are left byte-identical.
#   - Insertion point: after the leading comment block (matching the style of
#     the already-compliant files), before the first env/command line.
#   - Only the missing header(s) are added; an existing PATH= is never edited.
#   - Every modified file is first copied to the backup dir.
#   - cron picks up /etc/cron.d mtime changes automatically; no reload needed.
#
# Usage (validator host, as root):
#   sudo bash scripts/install-cron-env-headers.sh            # apply
#   sudo bash scripts/install-cron-env-headers.sh --dry-run  # report only
#
# Env overrides (test-time):
#   FYD_CRON_DIR     cron dir to scan (default /etc/cron.d). When overridden,
#                    the root requirement is waived (test harness mode).
#   FYD_BACKUP_DIR   backup destination (default /var/backups/metal-cron-env-
#                    headers-<UTC timestamp>)
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

SHELL_LINE='SHELL=/bin/bash'
PATH_LINE='PATH=/usr/local/bin:/usr/bin:/bin'

CHANGED=0
SKIPPED=0

for f in "$CRON_DIR"/metal-*; do
	[ -f "$f" ] || continue
	need_shell=1; need_path=1
	grep -qE '^SHELL=/bin/bash\b' "$f" && need_shell=0
	grep -qE '^PATH=' "$f" && need_path=0

	if [ "$need_shell" -eq 0 ] && [ "$need_path" -eq 0 ]; then
		SKIPPED=$((SKIPPED + 1))
		echo "ok:      $(basename "$f") (both headers present)"
		continue
	fi

	missing=""
	[ "$need_shell" -eq 1 ] && missing="SHELL"
	[ "$need_path"  -eq 1 ] && missing="${missing:+$missing+}PATH"

	if [ "$DRY_RUN" -eq 1 ]; then
		echo "would fix: $(basename "$f") (missing: $missing)"
		CHANGED=$((CHANGED + 1))
		continue
	fi

	mkdir -p "$BACKUP_DIR"
	cp -p "$f" "$BACKUP_DIR/$(basename "$f")"

	# Insert the missing header(s) after the leading comment/blank block —
	# the position the already-compliant project cron files use.
	tmp="$(mktemp)"
	awk -v add_shell="$need_shell" -v add_path="$need_path" \
		-v shell_line="$SHELL_LINE" -v path_line="$PATH_LINE" '
		BEGIN { inserted = 0 }
		{
			if (!inserted && $0 !~ /^[[:space:]]*(#|$)/) {
				if (add_shell == 1) print shell_line
				if (add_path == 1) print path_line
				inserted = 1
			}
			print
		}
		END {
			if (!inserted) {
				if (add_shell == 1) print shell_line
				if (add_path == 1) print path_line
			}
		}
	' "$f" > "$tmp"

	# Preserve mode/ownership of the original (cron.d requires root:root 0644).
	chmod --reference="$f" "$tmp" 2>/dev/null || chmod 644 "$tmp"
	chown --reference="$f" "$tmp" 2>/dev/null || true
	mv "$tmp" "$f"

	# Post-edit verification (linter rule 5 equivalent). Restore on failure.
	if ! grep -qE '^SHELL=/bin/bash\b' "$f" || ! grep -qE '^PATH=' "$f"; then
		echo "ERROR: post-edit verification failed for $f — restoring backup" >&2
		cp -p "$BACKUP_DIR/$(basename "$f")" "$f"
		exit 3
	fi

	CHANGED=$((CHANGED + 1))
	echo "fixed:   $(basename "$f") (added: $missing)"
done

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
	echo "DRY-RUN summary: would fix ${CHANGED}, already compliant ${SKIPPED}"
else
	echo "summary: fixed ${CHANGED}, already compliant ${SKIPPED}"
	[ "$CHANGED" -gt 0 ] && echo "backups: ${BACKUP_DIR}/"
fi
exit 0
