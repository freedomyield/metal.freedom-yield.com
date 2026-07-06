#!/usr/bin/env bash
# install-repoint-publish-crons.sh — repoint the live publish crons from the
# retired push-to-xserver.sh to the canonical push-to-web-host.sh. Run as root
# on the validator host.
#
# WHY (design-stocktake #12 / project_host_cron_publish_naming_split memory):
#   The de-branding rename push-to-xserver.sh -> push-to-web-host.sh was made in
#   the repo only. The host's /etc/cron.d/metal-* files still invoke the OLD name
#   directly (7 crons: node-info, uptime-history, peer-validators, node-health,
#   renewal-ics, peer-geo, + an anchor-publish-health comment). The old script
#   survives on the host (rsync has no --delete) and has diverged from the
#   canonical one. Data is currently healthy (both allow the same feeds) but the
#   LIVE publish path points at a repo-untracked script, so repo edits never
#   reach production. This repoints the crons to the tracked script.
#
# BROADCASTS NOTHING. Idempotent (re-runs are no-ops once repointed).
#
# Usage:
#   sudo bash scripts/install-repoint-publish-crons.sh [--dry-run] [--purge-orphans]
#     --dry-run        show what would change, touch nothing
#     --purge-orphans  after repoint, MOVE the now-unreferenced orphan scripts
#                      (push-to-xserver.sh + its .bak-*) into a timestamped
#                      .retired-*/ dir. Never rm — reversible, and VPS file
#                      deletion stays a human decision. (A separate legacy
#                      provider-named sync orphan, if present on the host, is
#                      removed by the operator manually — not referenced here.)
#
# Env overrides (test-time):
#   CRON_DIR     dir holding the cron files      (default /etc/cron.d)
#   SCRIPTS_DIR  dir holding the publish scripts (default REPO/scripts)
#   REPO         repo root       (default /home/deploy/metal.freedom-yield.com)
set -euo pipefail

REPO="${REPO:-/home/deploy/metal.freedom-yield.com}"
SCRIPTS_DIR="${SCRIPTS_DIR:-${REPO}/scripts}"
CRON_DIR="${CRON_DIR:-/etc/cron.d}"
# Backups live OUTSIDE CRON_DIR: a *.bak file left in /etc/cron.d is clutter at
# best and a stray executable cron at worst, and would also pollute this script's
# own "is this still referenced?" grep on a re-run.
BACKUP_DIR="${BACKUP_DIR:-/var/backups/metal-cron}"
OLD_NAME="push-to-xserver.sh"
NEW_NAME="push-to-web-host.sh"

DRY_RUN=0
PURGE=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		--purge-orphans) PURGE=1 ;;
		-h|--help) sed -n '1,/^set -euo pipefail$/p' "$0" >&2; exit 0 ;;
		*) echo "ERROR: unknown arg '$arg'" >&2; exit 2 ;;
	esac
done

say() { printf '%s\n' "$*"; }
run_note() { [ "$DRY_RUN" = 1 ] && printf '(dry-run) '; }

# ---- extract the allowlisted filenames from a publish script's case block ----
# Pulls every <name>.{json,jsonl,ics} token that appears inside `case … esac`.
allowlist_tokens() {
	local script="$1"
	sed -n '/^case /,/^esac/p' "$script" 2>/dev/null \
		| grep -oE '[a-z0-9][a-z0-9._-]*\.(json|jsonl|ics)' | sort -u
}
# does the script's case block carry a `*.ics)` glob (= accepts any .ics)?
has_ics_glob() { sed -n '/^case /,/^esac/p' "$1" 2>/dev/null | grep -qE '\*\.ics\)'; }

# ===== 0. preconditions =====================================================
NEW_PATH="${SCRIPTS_DIR}/${NEW_NAME}"
[ -f "$NEW_PATH" ] || { echo "ERROR: canonical script missing: $NEW_PATH" >&2
                        echo "       run sync-to-validator-host.sh from the Mac first." >&2; exit 1; }

# ===== 1. safety: NEW must allow everything OLD allows (superset) ============
OLD_PATH="${SCRIPTS_DIR}/${OLD_NAME}"
if [ -f "$OLD_PATH" ]; then
	say "── allowlist superset check (${NEW_NAME} must ⊇ ${OLD_NAME}) ──"
	MISSING=""
	NEW_HAS_ICS_GLOB=0; has_ics_glob "$NEW_PATH" && NEW_HAS_ICS_GLOB=1
	while IFS= read -r tok; do
		[ -z "$tok" ] && continue
		if allowlist_tokens "$NEW_PATH" | grep -qxF "$tok"; then continue; fi
		# an .ics token is covered if NEW carries the *.ics) glob
		case "$tok" in *.ics) [ "$NEW_HAS_ICS_GLOB" = 1 ] && continue ;; esac
		MISSING="${MISSING} ${tok}"
	done < <(allowlist_tokens "$OLD_PATH")
	if [ -n "$MISSING" ]; then
		echo "ERROR: ${NEW_NAME} does NOT allow targets that ${OLD_NAME} accepts:${MISSING}" >&2
		echo "       Repointing would make these feeds silently rejected. Aborting." >&2
		exit 1
	fi
	say "  ✓ ${NEW_NAME} allows every target ${OLD_NAME} accepts (safe to repoint)"
else
	say "  note: ${OLD_NAME} already absent from ${SCRIPTS_DIR} — superset check skipped"
fi
say ""

# ===== 2. repoint every cron file that invokes the OLD script ================
say "── repoint cron files (${OLD_NAME} → ${NEW_NAME}) ──"
TS="$(date +%Y%m%d-%H%M%S)"
CHECKER="${SCRIPTS_DIR}/check-cron-file.sh"
REPOINTED=0
shopt -s nullglob
CRON_FILES=("${CRON_DIR}"/*)
shopt -u nullglob
for f in "${CRON_FILES[@]}"; do
	[ -f "$f" ] || continue
	# skip dotfiles + backup/disabled sidecars (cron.d ignores dotted names too,
	# but be explicit so a stray file is never rewritten as if it were a cron).
	case "$(basename "$f")" in .*|*.bak*|*.disabled*|*~) continue ;; esac
	grep -q "$OLD_NAME" "$f" || continue
	TMP="$(mktemp)"
	sed "s/${OLD_NAME}/${NEW_NAME}/g" "$f" > "$TMP"
	# validate the rewritten file before installing (refuse on lint failure)
	if [ -x "$CHECKER" ]; then
		if ! bash "$CHECKER" "$TMP" >/dev/null 2>&1; then
			echo "  ✗ SKIP $(basename "$f"): rewritten file fails check-cron-file.sh" >&2
			rm -f "$TMP"; continue
		fi
	fi
	if [ "$DRY_RUN" = 1 ]; then
		say "  $(run_note)would repoint: $(basename "$f")"
		rm -f "$TMP"
	else
		mkdir -p "${BACKUP_DIR}/${TS}"
		cp -p "$f" "${BACKUP_DIR}/${TS}/$(basename "$f")"
		# preserve mode of the original cron file
		install -m "$(stat -c '%a' "$f" 2>/dev/null || echo 644)" "$TMP" "$f"
		rm -f "$TMP"
		say "  ✓ repointed: $(basename "$f")  (backup: ${BACKUP_DIR}/${TS}/$(basename "$f"))"
	fi
	REPOINTED=$((REPOINTED + 1))
done
[ "$REPOINTED" = 0 ] && say "  (nothing to repoint — all crons already use ${NEW_NAME})"
say ""

# ===== 3. orphan report / optional purge ====================================
say "── orphan scripts (no longer referenced by any cron after repoint) ──"
shopt -s nullglob
ORPHANS=("${SCRIPTS_DIR}/${OLD_NAME}" "${SCRIPTS_DIR}/${OLD_NAME}".bak-*)
shopt -u nullglob
FOUND=0
RETIRE_DIR="${SCRIPTS_DIR}/.retired-${TS}"
for o in "${ORPHANS[@]}"; do
	[ -e "$o" ] || continue
	# refuse to touch anything still referenced by a live cron
	if grep -rqF "$(basename "$o")" "${CRON_DIR}"/ 2>/dev/null; then
		say "  ⚠ still referenced by a cron, NOT an orphan: $(basename "$o")"
		continue
	fi
	FOUND=$((FOUND + 1))
	if [ "$PURGE" = 1 ] && [ "$DRY_RUN" = 0 ]; then
		mkdir -p "$RETIRE_DIR"
		mv "$o" "$RETIRE_DIR/"
		say "  ✓ retired (moved): $(basename "$o") → .retired-${TS}/"
	else
		say "  • orphan: $(basename "$o")  ($([ "$DRY_RUN" = 1 ] && echo 'dry-run' || echo 'run with --purge-orphans to retire'))"
	fi
done
[ "$FOUND" = 0 ] && say "  (no orphans found)"
say ""

# ===== 4. summary ===========================================================
if [ "$DRY_RUN" = 1 ]; then
	say "DRY-RUN complete. Re-run without --dry-run to apply."
else
	say "Done. ${REPOINTED} cron file(s) now invoke ${NEW_NAME}."
	if [ "$REPOINTED" -gt 0 ]; then
		say "Rollback if needed: restore each cron file from ${BACKUP_DIR}/${TS}/ ."
		say "Verify feeds still publish, then re-run with --purge-orphans to retire the old script."
	fi
fi
