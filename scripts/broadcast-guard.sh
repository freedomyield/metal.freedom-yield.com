#!/usr/bin/env bash
# broadcast-guard.sh — PreToolUse hook enforcing Constitution v0.3 PRIME DIRECTIVE.
#
# CHAIN: none — this script does not broadcast; it intercepts and gates
#        broadcast-capable command shapes before Bash execution.
# PRIME_DIRECTIVE: TESTNET-FIRST — this script is the tier-1 mechanical
#                  enforcement of docs/CONSTITUTION.md PRIME DIRECTIVE.
#
# Contract (Claude Code PreToolUse hook):
#   - stdin: JSON with .tool_name and .tool_input
#   - exit 0: allow the tool call
#   - exit 1: block the tool call; stderr becomes the visible error
#
# Behavior:
#   1. Read JSON from stdin.
#   2. If tool_name != "Bash", allow (exit 0).
#   3. Extract .tool_input.command.
#   4. Scan for broadcast-capable command shapes (proton action /
#      transaction / transaction:push, cleos push_transaction, curl/wget
#      hitting push_transaction / issueTx / eth_sendRawTransaction /
#      /ext/bc/[XPC]/, metalgo IssueTx).
#   5. If none match, allow.
#   6. If a match is found, it is a RAW direct broadcast (see the block
#      comment below) and is refused UNCONDITIONALLY — an operator token
#      does NOT override it. The only exception is the sanctioned wrapper
#      bin/safe-broadcast, which sets FYD_SAFE_BROADCAST=1; that path still
#      requires a fresh operator token.
#   7. On the sanctioned-path allow, append (timestamp, invoker, tool_name,
#      command) to the audit log for tier-4 cross-check.
#
# Environment overrides:
#   FYD_BROADCAST_TOKEN_FILE  — default /tmp/fyd-broadcast-token
#   FYD_BROADCAST_TOKEN_TTL   — default 300 (seconds)
#   FYD_BROADCAST_AUDIT_LOG   — default /var/log/fyd-broadcast-audit.log;
#                               if not writable, falls back to
#                               $HOME/.fyd-broadcast-audit.log
#   FYD_SAFE_BROADCAST        — set to "1" by bin/safe-broadcast to mark the
#                               sanctioned broadcast pathway. Never set this
#                               by hand to bypass the guard.
#
# See:
#   docs/CONSTITUTION.md PRIME DIRECTIVE
#   memory/project_broadcast_enforcement_gate_plan.md (tier design)
#   memory/feedback_no_unauthorized_broadcast.md (trigger event)

set -u

TOKEN_FILE="${FYD_BROADCAST_TOKEN_FILE:-/tmp/fyd-broadcast-token}"
TOKEN_TTL="${FYD_BROADCAST_TOKEN_TTL:-300}"
AUDIT_LOG_PRIMARY="${FYD_BROADCAST_AUDIT_LOG:-/var/log/fyd-broadcast-audit.log}"
AUDIT_LOG_FALLBACK="${HOME:-/tmp}/.fyd-broadcast-audit.log"

INPUT="$(cat)"

# jq is required for reliable JSON parsing. If jq is unavailable, we fail
# closed (= block) because a guard that cannot parse is a broken guard,
# and a broken guard MUST NOT default to allow.
if ! command -v jq >/dev/null 2>&1; then
	printf '=== PRIME_DIRECTIVE_VIOLATION ===\nbroadcast-guard: jq not found; guard cannot parse tool input; failing closed.\n' >&2
	exit 1
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
if [ "$TOOL_NAME" != "Bash" ]; then
	# Not a shell command; nothing to guard.
	exit 0
fi

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
if [ -z "$CMD" ]; then
	# Empty command; nothing to guard.
	exit 0
fi

# Broadcast-shape detection. Patterns are ERE; each must match a plausible
# invocation form of the corresponding tool. Kept intentionally broad —
# false positives are recoverable (operator uses bin/safe-broadcast),
# false negatives are the exact class of failure that motivated this
# script's existence.
BROADCAST_PATTERNS=(
	'proton[[:space:]]+action[[:space:]]'
	'proton[[:space:]]+transaction([[:space:]]|:push)'
	# cleos push action / push transaction / push_transaction / push_transactions
	# ERE `[[:space:]_]` catches both space and underscore joiners.
	'cleos[[:space:]]+.*push[[:space:]_]+(action|transaction)'
	'(curl|wget)[[:space:]]+.*push_transaction'
	'(curl|wget)[[:space:]]+.*issueTx'
	'(curl|wget)[[:space:]]+.*eth_sendRawTransaction'
	'(curl|wget)[[:space:]]+.*/ext/bc/[XPC]'
	'metalgo[[:space:]]+.*IssueTx'
)

MATCHED_PATTERN=""
for pat in "${BROADCAST_PATTERNS[@]}"; do
	if printf '%s' "$CMD" | grep -qE "$pat"; then
		MATCHED_PATTERN="$pat"
		break
	fi
done

if [ -z "$MATCHED_PATTERN" ]; then
	# No broadcast shape detected; allow.
	exit 0
fi

# A broadcast-capable shape was detected.
#
# Reaching this point ALWAYS means a raw, direct broadcast invocation. The
# sanctioned wrapper bin/safe-broadcast is invoked as `bin/safe-broadcast ...`
# (which matches none of the BROADCAST_PATTERNS above) and its internal
# `proton transaction:push` call is a subprocess that the PreToolUse hook
# never sees. So a match here is a command about to broadcast WITHOUT the
# tier-2 four-gate check — the exact accident class this guard exists to stop
# (see memory/feedback_no_unauthorized_broadcast.md).
#
# Therefore a raw call is refused UNCONDITIONALLY. An operator token does NOT
# override it: the token proves authorization intent, not that gate 1
# (testnet-first), gate 3 (chain match), and gate 4 (dry-run) were satisfied —
# only bin/safe-broadcast verifies those. The sole exception is the sanctioned
# wrapper itself, which exports FYD_SAFE_BROADCAST=1 before it calls proton;
# on that path the four gates already ran, and we still require a fresh
# operator token below as defense in depth.

if [ "${FYD_SAFE_BROADCAST:-}" != "1" ]; then
	cat >&2 <<EOF
=== PRIME_DIRECTIVE_VIOLATION ===
Raw broadcast-capable command detected — blocked unconditionally.

Detected shape: $MATCHED_PATTERN

All broadcasts MUST go through bin/safe-broadcast, which enforces the four
PRIME DIRECTIVE gates (testnet-first / per-invocation authorization /
pre-flight chain match / dry-run). A raw broadcast (e.g. \`proton
transaction:push\`) bypasses gates 1, 3, and 4 and is refused here even if a
fresh operator token exists — the token alone does not prove the gates ran.

To broadcast, invoke the sanctioned wrapper:
  bin/safe-broadcast --tx=<file> --chain=<testnet-a|mainnet-a> ...

This block is enforced by scripts/broadcast-guard.sh, the tier-1 mechanical
implementation of docs/CONSTITUTION.md PRIME DIRECTIVE. Do not disable the
guard or rewrite the call to evade it; use bin/safe-broadcast.
EOF
	exit 1
fi

# --- sanctioned wrapper context (FYD_SAFE_BROADCAST=1) ---
# The four gates already ran inside bin/safe-broadcast. Re-verify a fresh
# operator token (tier-2 gate 2) as defense in depth before allowing.

if [ ! -f "$TOKEN_FILE" ]; then
	printf '=== PRIME_DIRECTIVE_VIOLATION ===\nbroadcast-guard: safe-broadcast context but operator token missing (%s); failing closed.\n' "$TOKEN_FILE" >&2
	exit 1
fi

# Portable mtime read: try GNU stat, then BSD stat.
TOKEN_MTIME=""
if TOKEN_MTIME="$(stat -c %Y "$TOKEN_FILE" 2>/dev/null)"; then
	:
elif TOKEN_MTIME="$(stat -f %m "$TOKEN_FILE" 2>/dev/null)"; then
	:
else
	printf '=== PRIME_DIRECTIVE_VIOLATION ===\nbroadcast-guard: cannot stat token file %s; failing closed.\n' "$TOKEN_FILE" >&2
	exit 1
fi

NOW="$(date +%s)"
AGE="$((NOW - TOKEN_MTIME))"

if [ "$AGE" -ge "$TOKEN_TTL" ]; then
	printf '=== PRIME_DIRECTIVE_VIOLATION ===\nbroadcast-guard: safe-broadcast context but operator token expired (%ss >= %ss max); failing closed.\n' "$AGE" "$TOKEN_TTL" >&2
	exit 1
fi

# Sanctioned path with a fresh token. Log the authorized broadcast for
# tier-4 cross-check.
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
INVOKER="${USER:-unknown}"
# Truncate command to 800 chars to keep log lines bounded; secrets in
# broadcast commands would be a separate violation caught elsewhere.
CMD_SNIP="$(printf '%s' "$CMD" | tr '\n\t' '  ' | cut -c1-800)"
LOG_LINE="$(printf '%s\tinvoker=%s\ttool=%s\tpattern=%s\tcmd=%s' \
	"$TS" "$INVOKER" "$TOOL_NAME" "$MATCHED_PATTERN" "$CMD_SNIP")"

AUDIT_TARGET="$AUDIT_LOG_PRIMARY"
# If primary is not writable (typical on Mac where /var/log needs sudo),
# fall back to $HOME/.fyd-broadcast-audit.log. Never suppress.
if ! ( : >> "$AUDIT_TARGET" ) 2>/dev/null; then
	AUDIT_TARGET="$AUDIT_LOG_FALLBACK"
fi

if ! printf '%s\n' "$LOG_LINE" >> "$AUDIT_TARGET" 2>/dev/null; then
	# Log write failure is itself a red flag. Warn but do not block —
	# operator has already authorized; blocking at this point would be
	# a new class of surprise. Emit to stderr so it surfaces.
	printf 'broadcast-guard: WARNING failed to write audit log to %s\n' "$AUDIT_TARGET" >&2
fi

exit 0
