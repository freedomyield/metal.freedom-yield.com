#!/usr/bin/env bash
# test-install-tier1-hook.sh — regression suite for
# scripts/install-tier1-hook.sh.
#
# CHAIN: none — this test does not broadcast. It runs the installer
#        against an isolated scratch copy of the repo (never the real
#        .claude/settings.json of the repo this test lives in) and
#        asserts on the rendered JSON.
#
# WHY THIS SUITE EXISTS (2026-07-08):
#   The installer used to unconditionally clobber .claude/settings.json
#   with a template that installed ONLY the broadcast-guard PreToolUse
#   hook, while the tracked .claude/settings.json carries BOTH
#   broadcast-guard AND publish-guard (Bash matcher + Write|Edit|
#   MultiEdit matcher). Because settings.json is tracked in git, a
#   normal checkout already has both hooks — so a re-run of the old
#   installer (fresh clone / DR rebuild / reinstall) would silently
#   DELETE the publish-guard PII/host-identifier layer while the
#   installer's own self-check (which only asserted broadcast-guard)
#   still printed PASS. This suite pins:
#     1. a fresh install renders BOTH hooks;
#     2. re-running the installer against a settings.json that only has
#        the old broadcast-guard-only shape ADDS publish-guard rather
#        than requiring a human to notice a silent deletion;
#     3. re-running against an already-correct settings.json preserves
#        an unrelated hook entry that was merged in (additive, no
#        clobber);
#     4. the installer's rendered hook set, reduced to
#        (matcher -> sorted unique commands), is IDENTICAL to the
#        tracked repo .claude/settings.json's hook set — so any future
#        drift between the two fails this test instead of shipping
#        silently.
#
# Usage:  bash tests/install-tier1-hook/test-install-tier1-hook.sh
# Exit:   0 all pass / 1 any fail

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER_SRC="${REPO_ROOT}/scripts/install-tier1-hook.sh"
BROADCAST_GUARD_SRC="${REPO_ROOT}/scripts/broadcast-guard.sh"
PUBLISH_GUARD_SRC="${REPO_ROOT}/scripts/publish-guard.sh"
TRACKED_SETTINGS="${REPO_ROOT}/.claude/settings.json"

for f in "$INSTALLER_SRC" "$BROADCAST_GUARD_SRC" "$PUBLISH_GUARD_SRC" "$TRACKED_SETTINGS"; do
	if [ ! -f "$f" ]; then
		echo "FATAL: required fixture not found: $f" >&2
		exit 1
	fi
done

if ! command -v jq >/dev/null 2>&1; then
	echo "FATAL: jq required to run this suite (not present on PATH)" >&2
	exit 1
fi

PASS=0
FAIL=0

# Normalize a settings.json's PreToolUse hook set to
# [{matcher, commands: [sorted unique command strings]}, ...] sorted by
# matcher, so semantically-equivalent-but-differently-ordered JSON compares
# equal. This is the "hook set" the task package asks the regression test
# to diff against the tracked file.
normalize_hookset() {
	jq -S '
		[ (.hooks.PreToolUse // [])[]
		  | {matcher, commands: ([.hooks[]?.command] | sort | unique)}
		] | sort_by(.matcher)
	' "$1"
}

# Build a fresh isolated scratch "repo" (never the real repo this test
# lives in) with just enough shape for the installer to run standalone:
# scripts/install-tier1-hook.sh + its two guard prerequisites, resolved
# via the installer's own "$(dirname "$0")/.." logic.
new_scratch_repo() {
	local dir
	dir="$(mktemp -d -t fyd-tier1-installer-test.XXXXXX)"
	mkdir -p "${dir}/scripts" "${dir}/.claude"
	cp "$INSTALLER_SRC" "${dir}/scripts/install-tier1-hook.sh"
	cp "$BROADCAST_GUARD_SRC" "${dir}/scripts/broadcast-guard.sh"
	cp "$PUBLISH_GUARD_SRC" "${dir}/scripts/publish-guard.sh"
	chmod +x "${dir}/scripts/"*.sh
	printf '%s' "$dir"
}

run_installer() {
	# $1 = scratch repo dir
	(
		cd "$1" || exit 1
		# Isolate broadcast-guard's state from the real host (mirrors
		# tests/broadcast-guard/test-broadcast-guard.sh convention).
		export FYD_BROADCAST_TOKEN_FILE="$1/scratch-token"
		export FYD_BROADCAST_AUDIT_LOG="$1/scratch-audit.log"
		bash scripts/install-tier1-hook.sh
	)
}

check() {
	local name="$1" ok="$2"
	if [ "$ok" = "1" ]; then
		printf 'PASS  %s\n' "$name"
		PASS=$((PASS + 1))
	else
		printf 'FAIL  %s\n' "$name" >&2
		FAIL=$((FAIL + 1))
	fi
}

# ---- case 1: fresh install (no pre-existing settings.json) renders BOTH hooks ----
SCRATCH1="$(new_scratch_repo)"
rm -f "${SCRATCH1}/.claude/settings.json"
run_installer "$SCRATCH1" >"${SCRATCH1}/install.log" 2>&1
RC1=$?
if [ "$RC1" -eq 0 ] && jq empty "${SCRATCH1}/.claude/settings.json" 2>/dev/null; then
	BASH_CMDS="$(jq -r '.hooks.PreToolUse[]? | select(.matcher=="Bash") | .hooks[]?.command' "${SCRATCH1}/.claude/settings.json")"
	WRITE_CMDS="$(jq -r '.hooks.PreToolUse[]? | select(.matcher=="Write|Edit|MultiEdit") | .hooks[]?.command' "${SCRATCH1}/.claude/settings.json")"
	case "$BASH_CMDS" in *broadcast-guard.sh*) HAS_BC=1 ;; *) HAS_BC=0 ;; esac
	case "$BASH_CMDS" in *publish-guard.sh*) HAS_BP=1 ;; *) HAS_BP=0 ;; esac
	case "$WRITE_CMDS" in *publish-guard.sh*) HAS_WP=1 ;; *) HAS_WP=0 ;; esac
	if [ "$HAS_BC" = "1" ] && [ "$HAS_BP" = "1" ] && [ "$HAS_WP" = "1" ]; then
		check "fresh install: renders broadcast-guard + publish-guard (both matchers)" 1
	else
		check "fresh install: renders broadcast-guard + publish-guard (both matchers)" 0
		cat "${SCRATCH1}/install.log" >&2
	fi
else
	check "fresh install: installer exits 0 with valid JSON" 0
	cat "${SCRATCH1}/install.log" >&2
fi

# ---- case 2: re-run against the OLD broadcast-guard-only shape ADDS publish-guard ----
SCRATCH2="$(new_scratch_repo)"
cat > "${SCRATCH2}/.claude/settings.json" <<'OLD_EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/broadcast-guard.sh\""
          }
        ]
      }
    ]
  }
}
OLD_EOF
run_installer "$SCRATCH2" >"${SCRATCH2}/install.log" 2>&1
RC2=$?
if [ "$RC2" -eq 0 ]; then
	BASH_CMDS2="$(jq -r '.hooks.PreToolUse[]? | select(.matcher=="Bash") | .hooks[]?.command' "${SCRATCH2}/.claude/settings.json")"
	WRITE_CMDS2="$(jq -r '.hooks.PreToolUse[]? | select(.matcher=="Write|Edit|MultiEdit") | .hooks[]?.command' "${SCRATCH2}/.claude/settings.json")"
	case "$BASH_CMDS2" in *publish-guard.sh*) HAS_BP2=1 ;; *) HAS_BP2=0 ;; esac
	case "$WRITE_CMDS2" in *publish-guard.sh*) HAS_WP2=1 ;; *) HAS_WP2=0 ;; esac
	if [ "$HAS_BP2" = "1" ] && [ "$HAS_WP2" = "1" ]; then
		check "re-run against old broadcast-guard-only settings.json: publish-guard gets ADDED (regression fix)" 1
	else
		check "re-run against old broadcast-guard-only settings.json: publish-guard gets ADDED (regression fix)" 0
		cat "${SCRATCH2}/install.log" >&2
	fi
else
	check "re-run against old broadcast-guard-only settings.json: installer exits 0" 0
	cat "${SCRATCH2}/install.log" >&2
fi

# ---- case 3: re-run against an already-correct settings.json preserves an
#              UNRELATED pre-existing hook entry (merge is additive, not clobber) ----
SCRATCH3="$(new_scratch_repo)"
cp "$TRACKED_SETTINGS" "${SCRATCH3}/.claude/settings.json"
# Graft an unrelated matcher onto the already-correct file to prove the
# installer does not clobber anything it doesn't own.
jq '.hooks.PreToolUse += [{"matcher":"PostToolUse-canary","hooks":[{"type":"command","command":"echo canary-should-survive"}]}]' \
	"${SCRATCH3}/.claude/settings.json" > "${SCRATCH3}/.claude/settings.json.tmp" \
	&& mv "${SCRATCH3}/.claude/settings.json.tmp" "${SCRATCH3}/.claude/settings.json"
run_installer "$SCRATCH3" >"${SCRATCH3}/install.log" 2>&1
RC3=$?
if [ "$RC3" -eq 0 ]; then
	CANARY="$(jq -r '.hooks.PreToolUse[]? | select(.matcher=="PostToolUse-canary") | .hooks[0].command // empty' "${SCRATCH3}/.claude/settings.json")"
	if [ "$CANARY" = "echo canary-should-survive" ]; then
		check "re-run against already-correct settings.json: unrelated hook entry survives (no clobber)" 1
	else
		check "re-run against already-correct settings.json: unrelated hook entry survives (no clobber)" 0
		cat "${SCRATCH3}/install.log" >&2
	fi
else
	check "re-run against already-correct settings.json: installer exits 0" 0
	cat "${SCRATCH3}/install.log" >&2
fi

# ---- case 4: self-check now asserts publish-guard, and FAILS when it is
#              genuinely missing and cannot be safely merged (jq hidden) ----
SCRATCH4="$(new_scratch_repo)"
cat > "${SCRATCH4}/.claude/settings.json" <<'OLD_EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/broadcast-guard.sh\""
          }
        ]
      }
    ]
  }
}
OLD_EOF
# Hide jq from PATH so the installer takes the no-merge-possible branch.
NO_JQ_PATH="$(mktemp -d -t fyd-tier1-nojq-path.XXXXXX)"
for bin in bash sh cat chmod cp dirname echo grep mkdir mktemp mv printf rm sed tr wc; do
	real="$(command -v "$bin" 2>/dev/null || true)"
	[ -n "$real" ] && ln -sf "$real" "${NO_JQ_PATH}/${bin}"
done
(
	cd "$SCRATCH4" || exit 1
	export FYD_BROADCAST_TOKEN_FILE="$SCRATCH4/scratch-token"
	export FYD_BROADCAST_AUDIT_LOG="$SCRATCH4/scratch-audit.log"
	PATH="${NO_JQ_PATH}" bash scripts/install-tier1-hook.sh
) >"${SCRATCH4}/install.log" 2>&1
RC4=$?
STILL_MISSING_PUBLISH=0
if ! grep -qF 'publish-guard.sh' "${SCRATCH4}/.claude/settings.json"; then
	STILL_MISSING_PUBLISH=1
fi
if [ "$RC4" -ne 0 ] && grep -q 'Refusing to overwrite' "${SCRATCH4}/install.log" && [ "$STILL_MISSING_PUBLISH" = "1" ]; then
	check "no-jq + genuinely missing publish-guard: installer FAILS loudly instead of silently clobbering" 1
else
	check "no-jq + genuinely missing publish-guard: installer FAILS loudly instead of silently clobbering" 0
	cat "${SCRATCH4}/install.log" >&2
fi
rm -rf "$NO_JQ_PATH"

# ---- case 5 (the drift regression test): installer's rendered hook set on
#              a FRESH install is byte-for-byte identical, after
#              normalization, to the tracked repo .claude/settings.json.
#              Any future drift between the installer template and the
#              tracked file fails here. ----
SCRATCH5="$(new_scratch_repo)"
rm -f "${SCRATCH5}/.claude/settings.json"
run_installer "$SCRATCH5" >"${SCRATCH5}/install.log" 2>&1
RC5=$?
if [ "$RC5" -eq 0 ]; then
	RENDERED_NORM="$(normalize_hookset "${SCRATCH5}/.claude/settings.json")"
	TRACKED_NORM="$(normalize_hookset "$TRACKED_SETTINGS")"
	if [ "$RENDERED_NORM" = "$TRACKED_NORM" ]; then
		check "installer's rendered hook set matches tracked .claude/settings.json (no drift)" 1
	else
		check "installer's rendered hook set matches tracked .claude/settings.json (no drift)" 0
		echo "--- rendered ---" >&2
		echo "$RENDERED_NORM" >&2
		echo "--- tracked ---" >&2
		echo "$TRACKED_NORM" >&2
	fi
else
	check "installer's rendered hook set matches tracked .claude/settings.json (no drift)" 0
	cat "${SCRATCH5}/install.log" >&2
fi

rm -rf "$SCRATCH1" "$SCRATCH2" "$SCRATCH3" "$SCRATCH4" "$SCRATCH5"

echo
echo "test-install-tier1-hook.sh summary: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
