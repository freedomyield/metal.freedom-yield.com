#!/usr/bin/env bash
# install-git-hooks.sh — idempotently wire this clone's git hooks to
# .githooks/ (core.hooksPath=.githooks).
#
# Why this exists:
#   .githooks/pre-commit (gitleaks + fallback secret grep) and
#   .githooks/pre-push (host-identifier publish-guard scan) only run when
#   `core.hooksPath` is set in THIS clone's local git config. That config
#   is per-clone, not committed, and is silently lost on a fresh clone,
#   a repo re-create, or a new worktree — exactly the kind of "config step
#   nobody remembers to do" that let a secret slip through once already
#   (see docs/CONSTITUTION.md PRIME DIRECTIVE history, 2026-07-03 credential
#   exposure incident). This script collapses that config step to one
#   command, and gives CI/operators a --check mode to verify it's live
#   without depending on memory.
#
# CHAIN: none — mutates only this clone's local (non-shared, non-committed)
#        git config; never touches remote state, broadcast state, or any
#        file tracked in the repository.
# PRIME_DIRECTIVE: TESTNET-FIRST — not applicable; no broadcast surface.
#
# Usage (from repo root, or any subdirectory of the working tree):
#   bash scripts/install-git-hooks.sh          # install (idempotent) + verify
#   bash scripts/install-git-hooks.sh --check  # verify only, no mutation
#
# Exit codes:
#   0  core.hooksPath is (now) correctly wired to .githooks
#   1  prerequisite missing, or (in --check mode) not yet wired

set -u

MODE="install"
for arg in "$@"; do
	case "$arg" in
		--check)   MODE="check" ;;
		-h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)         echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "${REPO_ROOT}" ]; then
	echo "FAIL: not inside a git working tree" >&2
	exit 1
fi
cd "${REPO_ROOT}" || { echo "FAIL: cannot cd to repo root ${REPO_ROOT}" >&2; exit 1; }

HOOKS_DIR=".githooks"
WANT="${HOOKS_DIR}"

echo "== git hooks installer =="
echo "repo root: ${REPO_ROOT}"
echo "mode: ${MODE}"

# ---- prerequisite: .githooks/ exists with the expected hooks, executable ----
if [ ! -d "${HOOKS_DIR}" ]; then
	echo "FAIL: ${HOOKS_DIR}/ not found at repo root" >&2
	exit 1
fi
MISSING=0
for h in pre-commit pre-push; do
	if [ ! -f "${HOOKS_DIR}/${h}" ]; then
		echo "FAIL: ${HOOKS_DIR}/${h} not found" >&2
		MISSING=1
	elif [ ! -x "${HOOKS_DIR}/${h}" ]; then
		echo "FAIL: ${HOOKS_DIR}/${h} exists but is not executable" >&2
		MISSING=1
	fi
done
[ "${MISSING}" -eq 0 ] || exit 1
echo "PASS: ${HOOKS_DIR}/{pre-commit,pre-push} present and executable"

# ---- install: set core.hooksPath (idempotent no-op if already correct) -----
if [ "${MODE}" = "install" ]; then
	CURRENT="$(git config --get core.hooksPath 2>/dev/null || true)"
	if [ "${CURRENT}" = "${WANT}" ]; then
		echo "INFO: core.hooksPath already = ${WANT} (no change)"
	else
		git config core.hooksPath "${WANT}"
		echo "installer: set core.hooksPath = ${WANT}"
	fi
fi

# ---- verify (both modes) -----------------------------------------------------
ACTUAL="$(git config --get core.hooksPath 2>/dev/null || true)"
if [ "${ACTUAL}" = "${WANT}" ]; then
	echo "PASS: core.hooksPath = ${ACTUAL}"
else
	if [ "${MODE}" = "check" ]; then
		echo "FAIL: core.hooksPath = '${ACTUAL:-<unset>}' (expected ${WANT}); run without --check to install" >&2
	else
		echo "FAIL: core.hooksPath = '${ACTUAL:-<unset>}' (expected ${WANT}) after install attempt" >&2
	fi
	exit 1
fi

echo
echo "=========================================="
echo "OK — local hooks wired to ${HOOKS_DIR} (pre-commit secret-scan + pre-push publish-guard active)"
echo "=========================================="
