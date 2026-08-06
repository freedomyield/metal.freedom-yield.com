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
#                      deletion stays a human decision.
#
#   env EXTRA_ORPHANS="/abs/path/a.sh:/abs/path/b.sh"
#                      extra orphan paths to retire alongside the above (with
#                      --purge-orphans). Lets a legacy script whose NAME is a
#                      now-forbidden literal be retired without writing that
#                      literal into this tracked file. Each is still refused if
#                      any cron references it, and moved (not deleted).
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

# check-cron-file.sh violation count for a file (0 if the linter is clean or
# emits no Result line). `|| true`: linter exits 1 on violations — must not
# abort us under set -e/pipefail.
#
# FYD_CRON_FY_LIVE_GRACE=1 (2026-08-06, check-cron-file.sh Rule 6): a rename
# from OLD_NAME to NEW_NAME can flip a cron's Rule-6 outcome purely because
# NEW_NAME (push-to-web-host.sh) is on Rule 6's side-effect allowlist while
# OLD_NAME (push-to-xserver.sh) never was — a file with zero FY_LIVE-related
# violations before the repoint would gain one after, purely from the name
# swap, on every currently-live cron that has not yet had FY_LIVE=1 added to
# its env header. §2's BEFORE_V vs AFTER_V comparison exists to protect
# against a rewrite that adds a NEW problem, not to enforce an unrelated,
# already-known migration-window gap — that is exactly the case this flag
# is for. Without it, this script would start silently refusing to repoint
# every affected live cron the day Rule 6 landed, undermining the one job
# it exists to do.
lint_violations() {
	FYD_CRON_FY_LIVE_GRACE=1 bash "$CHECKER" "$1" 2>/dev/null | sed -n 's/^Result: \([0-9]*\) violation.*/\1/p' || true
}

# ===== 0. preconditions =====================================================
NEW_PATH="${SCRIPTS_DIR}/${NEW_NAME}"
[ -f "$NEW_PATH" ] || { echo "ERROR: canonical script missing: $NEW_PATH" >&2
                        echo "       run sync-to-validator-host.sh from the Mac first." >&2; exit 1; }

# ===== 1. safety: every feed the CRONS ACTUALLY PUSH via OLD must be =========
#         accepted by NEW. A feed OLD's allowlist carries but no cron pushes
#         (and NEW rejects) is vestigial — reported, never blocking. This is
#         stricter where it matters (real cron usage) and looser where it does
#         not (dead allowlist entries, e.g. artifacts now git-deploy-owned).
OLD_PATH="${SCRIPTS_DIR}/${OLD_NAME}"
# feed tokens the live crons push through OLD (literal `OLD_NAME <name>.<ext>`)
cron_pushed_tokens() {
	# `|| true`: no match (grep rc=1) under pipefail must yield empty, not abort.
	grep -rhoE "${OLD_NAME}[[:space:]]+[a-z0-9][a-z0-9._-]*\.(json|jsonl|ics)" "${CRON_DIR}"/ 2>/dev/null \
		| awk '{print $NF}' | sort -u || true
}
# does any cron push a COMPUTED .ics through OLD (e.g. `OLD_NAME $(token).ics`)?
cron_pushes_dynamic_ics() {
	grep -rhE "${OLD_NAME}[[:space:]]+[^[:space:]]*\.ics" "${CRON_DIR}"/ 2>/dev/null \
		| grep -qvE "${OLD_NAME}[[:space:]]+[a-z0-9][a-z0-9._-]*\.ics([[:space:]]|$)"
}
if [ -f "$OLD_PATH" ]; then
	say "── repoint safety: feeds crons push via ${OLD_NAME} must be accepted by ${NEW_NAME} ──"
	NEW_HAS_ICS_GLOB=0; has_ics_glob "$NEW_PATH" && NEW_HAS_ICS_GLOB=1
	CRON_TOKENS="$(cron_pushed_tokens)"
	BLOCKING=""
	while IFS= read -r tok; do
		[ -z "$tok" ] && continue
		allowlist_tokens "$NEW_PATH" | grep -qxF "$tok" && continue
		case "$tok" in *.ics) [ "$NEW_HAS_ICS_GLOB" = 1 ] && continue ;; esac
		BLOCKING="${BLOCKING} ${tok}"
	done <<EOF
${CRON_TOKENS}
EOF
	if cron_pushes_dynamic_ics && [ "$NEW_HAS_ICS_GLOB" = 0 ]; then
		BLOCKING="${BLOCKING} (computed).ics"
	fi
	if [ -n "$BLOCKING" ]; then
		echo "ERROR: ${NEW_NAME} rejects feed(s) a live cron pushes via ${OLD_NAME}:${BLOCKING}" >&2
		echo "       Repointing would make these feeds silently rejected. Aborting." >&2
		exit 1
	fi
	# informational: OLD allowlist entries NEW rejects that no cron actually pushes
	VESTIGIAL=""
	while IFS= read -r tok; do
		[ -z "$tok" ] && continue
		allowlist_tokens "$NEW_PATH" | grep -qxF "$tok" && continue
		case "$tok" in *.ics) [ "$NEW_HAS_ICS_GLOB" = 1 ] && continue ;; esac
		printf '%s\n' "${CRON_TOKENS}" | grep -qxF "$tok" && continue
		VESTIGIAL="${VESTIGIAL} ${tok}"
	done < <(allowlist_tokens "$OLD_PATH")
	say "  ✓ every cron-pushed feed is accepted by ${NEW_NAME} (safe to repoint)"
	[ -n "$VESTIGIAL" ] && say "  note: ${OLD_NAME} also allowlists (vestigial — no cron pushes them, e.g. git-deploy-owned):${VESTIGIAL}"
else
	say "  note: ${OLD_NAME} already absent from ${SCRIPTS_DIR} — safety check skipped"
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
	# A name-swap must not INTRODUCE new linter violations, but pre-existing
	# ones in the ORIGINAL are out of scope for a repoint (they predate it and
	# no linter rule depends on the script filename). Refuse only if the rewrite
	# is strictly WORSE than the original; carry forward pre-existing issues.
	if [ -x "$CHECKER" ]; then
		BEFORE_V="$(lint_violations "$f")"; AFTER_V="$(lint_violations "$TMP")"
		if [ "${AFTER_V:-0}" -gt "${BEFORE_V:-0}" ]; then
			echo "  ✗ SKIP $(basename "$f"): rewrite would ADD linter violations (${BEFORE_V:-0}→${AFTER_V:-0})" >&2
			rm -f "$TMP"; continue
		fi
		[ "${AFTER_V:-0}" -gt 0 ] && say "  (note: $(basename "$f") carries ${AFTER_V} pre-existing linter issue(s), unchanged by repoint)"
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
# Operator-supplied extra orphan paths (colon- or space-separated), so a legacy
# script whose NAME is a now-forbidden literal can be retired WITHOUT embedding
# that literal in this tracked file. Each still passes the cron-reference guard
# below (refused if any cron references it) and is moved (not rm'd).
if [ -n "${EXTRA_ORPHANS:-}" ]; then
	IFS=': ' read -r -a _extra_orphans <<< "${EXTRA_ORPHANS}"
	ORPHANS+=("${_extra_orphans[@]}")
fi
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
