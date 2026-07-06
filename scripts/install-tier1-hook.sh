#!/usr/bin/env bash
# install-tier1-hook.sh — one-shot operator installer for the tier-1
# PreToolUse hook that enforces docs/CONSTITUTION.md PRIME DIRECTIVE.
#
# CHAIN: none — this script does not broadcast; it installs the guard
#        that gates future broadcast-capable command shapes.
# PRIME_DIRECTIVE: TESTNET-FIRST — this is the tier-1 mechanical
#                  enforcement installer per
#                  memory/project_broadcast_enforcement_gate_plan.md
#
# Why this script exists:
#   The Claude Code auto-mode classifier treats .claude/settings.json
#   as a HARD-tier restricted path (self-modification of agent config)
#   and blocks AI writes to it, even under explicit user instruction.
#   By design, only the operator can install the hook. This script
#   collapses that install to one operator command.
#
# Usage (from repo root, in the operator's own terminal):
#   bash scripts/install-tier1-hook.sh
#
# Behavior:
#   1. Create .claude/ if missing.
#   2. Write .claude/settings.json with the PreToolUse hook config.
#   3. Verify: file exists, JSON parses, hook command references
#      scripts/broadcast-guard.sh, guard is executable, guard passes
#      a smoke test.
#   4. Print PASS / FAIL line so the operator can copy-paste the
#      result back to the AI session.
#
# Exit codes:
#   0  install + all verifications PASS
#   1  install or a verification step failed

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}" || { echo "FAIL: cannot cd to repo root ${REPO_ROOT}" >&2; exit 1; }

SETTINGS_DIR=".claude"
SETTINGS_FILE=".claude/settings.json"
GUARD_SCRIPT="scripts/broadcast-guard.sh"

echo "== tier-1 hook installer =="
echo "repo root: ${REPO_ROOT}"

# ---- guard prerequisite ----
if [ ! -f "${GUARD_SCRIPT}" ]; then
	echo "FAIL: ${GUARD_SCRIPT} not found at repo root" >&2
	exit 1
fi
if [ ! -x "${GUARD_SCRIPT}" ]; then
	echo "installer: making ${GUARD_SCRIPT} executable"
	chmod +x "${GUARD_SCRIPT}"
fi

# ---- write settings.json ----
mkdir -p "${SETTINGS_DIR}"

# Heredoc terminator MUST be at column 1 with no trailing whitespace.
cat > "${SETTINGS_FILE}" <<'SETTINGS_EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "_comment": "Repo-level Claude Code settings. Tier-1 mechanical enforcement of docs/CONSTITUTION.md PRIME DIRECTIVE via PreToolUse hook. See memory/project_broadcast_enforcement_gate_plan.md for tier design and rationale.",
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
SETTINGS_EOF

# ---- verify 1: file exists + non-empty ----
if [ ! -s "${SETTINGS_FILE}" ]; then
	echo "FAIL: ${SETTINGS_FILE} missing or empty after write" >&2
	exit 1
fi
FILE_BYTES="$(wc -c < "${SETTINGS_FILE}" | tr -d ' ')"
echo "PASS 1/5: ${SETTINGS_FILE} exists (${FILE_BYTES} bytes)"

# ---- verify 2: JSON parses ----
if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP 2/5: jq not installed, cannot validate JSON syntax" >&2
elif ! jq empty "${SETTINGS_FILE}" 2>/dev/null; then
	echo "FAIL 2/5: ${SETTINGS_FILE} is not valid JSON" >&2
	exit 1
else
	echo "PASS 2/5: ${SETTINGS_FILE} is valid JSON"
fi

# ---- verify 3: hook command references broadcast-guard.sh ----
if command -v jq >/dev/null 2>&1; then
	HOOK_CMD="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "${SETTINGS_FILE}")"
	case "${HOOK_CMD}" in
		*broadcast-guard.sh*)
			echo "PASS 3/5: hook command references broadcast-guard.sh"
			;;
		"")
			echo "FAIL 3/5: hook command is empty in ${SETTINGS_FILE}" >&2
			exit 1
			;;
		*)
			echo "FAIL 3/5: hook command does not reference broadcast-guard.sh (got: ${HOOK_CMD})" >&2
			exit 1
			;;
	esac
else
	echo "SKIP 3/5: jq not installed, cannot introspect hook command"
fi

# ---- verify 4: guard script is executable ----
if [ ! -x "${GUARD_SCRIPT}" ]; then
	echo "FAIL 4/5: ${GUARD_SCRIPT} is not executable" >&2
	exit 1
fi
echo "PASS 4/5: ${GUARD_SCRIPT} is executable"

# ---- verify 5: guard smoke test (safe command allowed, broadcast blocked) ----
SMOKE_ALLOW_RC=99
if echo '{"tool_name":"Bash","tool_input":{"command":"ls -la /tmp"}}' | bash "${GUARD_SCRIPT}" >/dev/null 2>&1; then
	SMOKE_ALLOW_RC=0
else
	SMOKE_ALLOW_RC=$?
fi

SMOKE_BLOCK_RC=99
if echo '{"tool_name":"Bash","tool_input":{"command":"proton transaction:push arg"}}' | bash "${GUARD_SCRIPT}" >/dev/null 2>&1; then
	SMOKE_BLOCK_RC=0
else
	SMOKE_BLOCK_RC=$?
fi

if [ "${SMOKE_ALLOW_RC}" -eq 0 ] && [ "${SMOKE_BLOCK_RC}" -eq 2 ]; then
	echo "PASS 5/5: guard smoke test (safe=allow, broadcast=block)"
else
	echo "FAIL 5/5: guard smoke test unexpected rcs (safe=${SMOKE_ALLOW_RC} expected 0, broadcast=${SMOKE_BLOCK_RC} expected 2)" >&2
	exit 1
fi

echo
echo "=========================================="
echo "INSTALL COMPLETE — tier-1 PreToolUse hook active"
echo "=========================================="
echo
echo "Next: paste this single line back to the AI session:"
echo "    INSTALL COMPLETE ${SETTINGS_FILE} ${FILE_BYTES} bytes"
