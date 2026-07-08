#!/usr/bin/env bash
# install-tier1-hook.sh — one-shot operator installer for the PreToolUse
# hooks that enforce docs/CONSTITUTION.md PRIME DIRECTIVE (broadcast-guard)
# and the host-identifier / operator-PII publish guard (publish-guard).
#
# CHAIN: none — this script does not broadcast; it installs the guards
#        that gate future broadcast-capable command shapes and future
#        publish-bound writes.
# PRIME_DIRECTIVE: TESTNET-FIRST — this is the tier-1 mechanical
#                  enforcement installer per
#                  memory/project_broadcast_enforcement_gate_plan.md
#
# Why this script exists:
#   The Claude Code auto-mode classifier treats .claude/settings.json
#   as a HARD-tier restricted path (self-modification of agent config)
#   and blocks AI writes to it, even under explicit user instruction.
#   By design, only the operator can install the hooks. This script
#   collapses that install to one operator command.
#
# Why MERGE, not clobber (regression fixed 2026-07-08):
#   .claude/settings.json is tracked in git and normally already carries
#   BOTH the broadcast-guard hook (Bash matcher) and the publish-guard
#   hook (Bash matcher + Write|Edit|MultiEdit matcher). Earlier versions
#   of this installer unconditionally overwrote the file with a
#   broadcast-guard-only template. A re-run on an already-correct
#   checkout (fresh clone / DR rebuild / reinstall) would silently
#   DELETE the publish-guard PII/host-identifier layer while the
#   installer's own self-check — which only asserted broadcast-guard —
#   still printed PASS. This version merges the required hook entries
#   into whatever settings.json already exists (additive, via jq) and
#   only falls back to writing the full template when no settings.json
#   is present yet. See tests/install-tier1-hook/ for the regression
#   test that diffs the installer's rendered hook set against the
#   tracked .claude/settings.json so this cannot silently reoccur.
#
# Usage (from repo root, in the operator's own terminal):
#   bash scripts/install-tier1-hook.sh
#
# Behavior:
#   1. Create .claude/ if missing.
#   2. If .claude/settings.json does not exist: write it from the
#      canonical template (both hooks).
#      If it already exists: MERGE the required PreToolUse hook entries
#      into it with jq (existing unrelated keys/matchers/hooks are left
#      untouched). If jq is unavailable, refuse to touch an existing
#      file unless it already has all the required entries (verified by
#      literal-string check) — never blind-clobber.
#   3. Verify: file exists, JSON parses, both guard scripts are
#      referenced by the correct matchers, both guards are executable,
#      broadcast-guard passes a smoke test.
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
BROADCAST_GUARD="scripts/broadcast-guard.sh"
PUBLISH_GUARD="scripts/publish-guard.sh"
BROADCAST_CMD='bash "$CLAUDE_PROJECT_DIR/scripts/broadcast-guard.sh"'
PUBLISH_CMD='bash "$CLAUDE_PROJECT_DIR/scripts/publish-guard.sh"'
WRITE_MATCHER='Write|Edit|MultiEdit'

echo "== tier-1 hook installer =="
echo "repo root: ${REPO_ROOT}"

# ---- guard prerequisites (both guards, not just broadcast-guard) ----
for guard in "${BROADCAST_GUARD}" "${PUBLISH_GUARD}"; do
	if [ ! -f "${guard}" ]; then
		echo "FAIL: ${guard} not found at repo root" >&2
		exit 1
	fi
	if [ ! -x "${guard}" ]; then
		echo "installer: making ${guard} executable"
		chmod +x "${guard}"
	fi
done

# ---- write/merge settings.json ----
mkdir -p "${SETTINGS_DIR}"

write_fresh_template() {
	# Heredoc terminator MUST be at column 1 with no trailing whitespace.
	cat > "${SETTINGS_FILE}" <<'SETTINGS_EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "_comment": "Repo-level Claude Code settings. Tier-1 mechanical enforcement of docs/CONSTITUTION.md PRIME DIRECTIVE (broadcast-guard) and the host-identifier publish guard (publish-guard: real host IP / operator handle / SSH key name) via PreToolUse hooks. See memory/project_broadcast_enforcement_gate_plan.md and docs/audits/constitution-2026-07-03T16-33-audit.md.",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/broadcast-guard.sh\""
          },
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/publish-guard.sh\""
          }
        ]
      },
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/publish-guard.sh\""
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
}

if [ ! -s "${SETTINGS_FILE}" ]; then
	echo "installer: ${SETTINGS_FILE} absent/empty — writing fresh template (both hooks)"
	write_fresh_template
elif command -v jq >/dev/null 2>&1; then
	echo "installer: ${SETTINGS_FILE} exists — merging required hook entries (additive)"
	MERGE_TMP="$(mktemp -t fyd-tier1-settings.XXXXXX)"
	if ! jq \
		--arg bcmd "${BROADCAST_CMD}" \
		--arg pcmd "${PUBLISH_CMD}" \
		--arg writeMatcher "${WRITE_MATCHER}" \
		--argjson bashHooks "$(jq -n --arg b "${BROADCAST_CMD}" --arg p "${PUBLISH_CMD}" \
			'[{"type":"command","command":$b},{"type":"command","command":$p}]')" \
		--argjson writeHooks "$(jq -n --arg p "${PUBLISH_CMD}" \
			'[{"type":"command","command":$p}]')" \
		'
		def ensure_matcher(m; want):
			(if any(.hooks.PreToolUse[]?; .matcher == m) then
				.hooks.PreToolUse |= map(
					if .matcher == m then
						.hooks = (((.hooks // []) + want) | unique_by(.command) | sort_by(.command))
					else . end)
			else
				.hooks.PreToolUse += [{"matcher": m, "hooks": want}]
			end);
		.hooks //= {} |
		.hooks.PreToolUse //= [] |
		ensure_matcher("Bash"; $bashHooks) |
		ensure_matcher($writeMatcher; $writeHooks)
		' "${SETTINGS_FILE}" > "${MERGE_TMP}" 2>/dev/null \
		&& jq empty "${MERGE_TMP}" 2>/dev/null
	then
		echo "FAIL: jq merge of ${SETTINGS_FILE} failed; refusing to write (existing file left untouched)" >&2
		rm -f "${MERGE_TMP}"
		exit 1
	fi
	mv "${MERGE_TMP}" "${SETTINGS_FILE}"
else
	# No jq: cannot safely parse+merge. Refusing to blind-overwrite an
	# existing file is the whole point of this fix — that is exactly how
	# the publish-guard layer was silently deleted before. Only proceed
	# as a no-op if every required entry is already present verbatim.
	if grep -qF "${BROADCAST_CMD}" "${SETTINGS_FILE}" \
		&& grep -qF "${PUBLISH_CMD}" "${SETTINGS_FILE}" \
		&& grep -qF "${WRITE_MATCHER}" "${SETTINGS_FILE}"; then
		echo "installer: jq not available, but ${SETTINGS_FILE} already contains both required hooks — leaving as-is"
	else
		echo "FAIL: jq not available and ${SETTINGS_FILE} exists without all required hook entries." >&2
		echo "      Refusing to overwrite an existing settings.json without jq to merge safely." >&2
		echo "      Install jq and re-run, or hand-edit ${SETTINGS_FILE} to match the template in this script." >&2
		exit 1
	fi
fi

# ---- verify 1: file exists + non-empty ----
if [ ! -s "${SETTINGS_FILE}" ]; then
	echo "FAIL: ${SETTINGS_FILE} missing or empty after write" >&2
	exit 1
fi
FILE_BYTES="$(wc -c < "${SETTINGS_FILE}" | tr -d ' ')"
echo "PASS 1/7: ${SETTINGS_FILE} exists (${FILE_BYTES} bytes)"

# ---- verify 2: JSON parses ----
if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP 2/7: jq not installed, cannot validate JSON syntax" >&2
elif ! jq empty "${SETTINGS_FILE}" 2>/dev/null; then
	echo "FAIL 2/7: ${SETTINGS_FILE} is not valid JSON" >&2
	exit 1
else
	echo "PASS 2/7: ${SETTINGS_FILE} is valid JSON"
fi

# ---- verify 3-5: both guards referenced by the correct matchers ----
# (extended 2026-07-08: previously only checked broadcast-guard.sh, so a
# clobbering re-run that deleted the publish-guard entries still printed
# PASS. See history note above.)
if command -v jq >/dev/null 2>&1; then
	BASH_CMDS="$(jq -r '.hooks.PreToolUse[]? | select(.matcher=="Bash") | .hooks[]?.command // empty' "${SETTINGS_FILE}")"
	WRITE_CMDS="$(jq -r --arg m "${WRITE_MATCHER}" '.hooks.PreToolUse[]? | select(.matcher==$m) | .hooks[]?.command // empty' "${SETTINGS_FILE}")"

	case "${BASH_CMDS}" in
		*broadcast-guard.sh*)
			echo "PASS 3/7: Bash-matcher hooks reference broadcast-guard.sh"
			;;
		*)
			echo "FAIL 3/7: Bash-matcher hooks do not reference broadcast-guard.sh" >&2
			exit 1
			;;
	esac

	case "${BASH_CMDS}" in
		*publish-guard.sh*)
			echo "PASS 4/7: Bash-matcher hooks reference publish-guard.sh"
			;;
		*)
			echo "FAIL 4/7: Bash-matcher hooks do not reference publish-guard.sh" >&2
			exit 1
			;;
	esac

	case "${WRITE_CMDS}" in
		*publish-guard.sh*)
			echo "PASS 5/7: ${WRITE_MATCHER} matcher hooks reference publish-guard.sh"
			;;
		*)
			echo "FAIL 5/7: ${WRITE_MATCHER} matcher hooks do not reference publish-guard.sh" >&2
			exit 1
			;;
	esac
else
	echo "SKIP 3/7: jq not installed, cannot introspect hook command"
	echo "SKIP 4/7: jq not installed, cannot introspect hook command"
	echo "SKIP 5/7: jq not installed, cannot introspect hook command"
fi

# ---- verify 6: both guard scripts are executable ----
if [ ! -x "${BROADCAST_GUARD}" ] || [ ! -x "${PUBLISH_GUARD}" ]; then
	echo "FAIL 6/7: one or both guard scripts are not executable (${BROADCAST_GUARD}, ${PUBLISH_GUARD})" >&2
	exit 1
fi
echo "PASS 6/7: ${BROADCAST_GUARD} and ${PUBLISH_GUARD} are executable"

# ---- verify 7: broadcast-guard smoke test (safe command allowed, broadcast blocked) ----
SMOKE_ALLOW_RC=99
if echo '{"tool_name":"Bash","tool_input":{"command":"ls -la /tmp"}}' | bash "${BROADCAST_GUARD}" >/dev/null 2>&1; then
	SMOKE_ALLOW_RC=0
else
	SMOKE_ALLOW_RC=$?
fi

SMOKE_BLOCK_RC=99
if echo '{"tool_name":"Bash","tool_input":{"command":"proton transaction:push arg"}}' | bash "${BROADCAST_GUARD}" >/dev/null 2>&1; then
	SMOKE_BLOCK_RC=0
else
	SMOKE_BLOCK_RC=$?
fi

if [ "${SMOKE_ALLOW_RC}" -eq 0 ] && [ "${SMOKE_BLOCK_RC}" -eq 2 ]; then
	echo "PASS 7/7: broadcast-guard smoke test (safe=allow, broadcast=block)"
else
	echo "FAIL 7/7: broadcast-guard smoke test unexpected rcs (safe=${SMOKE_ALLOW_RC} expected 0, broadcast=${SMOKE_BLOCK_RC} expected 2)" >&2
	exit 1
fi

echo
echo "=========================================="
echo "INSTALL COMPLETE — tier-1 PreToolUse hooks active (broadcast-guard + publish-guard)"
echo "=========================================="
echo
echo "Next: paste this single line back to the AI session:"
echo "    INSTALL COMPLETE ${SETTINGS_FILE} ${FILE_BYTES} bytes"
