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
#   6. If a match is found, require an operator-authored token file
#      whose mtime is within TOKEN_TTL_SECONDS (default 300s). Missing
#      or expired token = block with PRIME_DIRECTIVE_VIOLATION message.
#   7. On allow, append (timestamp, invoker, tool_name, command) to the
#      audit log for tier-4 cross-check.
#
# Environment overrides:
#   FYD_BROADCAST_TOKEN_FILE  — default /tmp/fyd-broadcast-token
#   FYD_BROADCAST_TOKEN_TTL   — default 300 (seconds)
#   FYD_BROADCAST_AUDIT_LOG   — default /var/log/fyd-broadcast-audit.log;
#                               if not writable, falls back to
#                               $HOME/.fyd-broadcast-audit.log
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
# false positives are recoverable (operator authorizes with a token),
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

# From here down, a broadcast-capable shape was detected. Enforce token.

if [ ! -f "$TOKEN_FILE" ]; then
	cat >&2 <<EOF
=== PRIME_DIRECTIVE_VIOLATION ===
Broadcast-capable command detected without an authorization token.

Detected shape: $MATCHED_PATTERN
Token file:     $TOKEN_FILE  (missing)

This block is enforced by scripts/broadcast-guard.sh, the tier-1
mechanical implementation of docs/CONSTITUTION.md PRIME DIRECTIVE
(TESTNET-FIRST FOR ALL BROADCASTS).

To authorize this specific broadcast, the operator must:
  1. Confirm all four PRIME DIRECTIVE gates in docs/CONSTITUTION.md
     are simultaneously satisfied for this exact broadcast.
  2. Create the token file with any non-empty content, e.g.:
        touch $TOKEN_FILE
     (Token TTL is $TOKEN_TTL seconds from mtime.)
  3. Re-invoke the tool within the TTL window.

Do not bypass this guard. Do not rewrite the token invocation into
the same tool call. If the guard is blocking correctly-authorized
work, revise the plan; do not disable the guard.
EOF
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
	cat >&2 <<EOF
=== PRIME_DIRECTIVE_VIOLATION ===
Authorization token expired.

Token file: $TOKEN_FILE
Age:        ${AGE}s (max ${TOKEN_TTL}s)
Detected shape: $MATCHED_PATTERN

Operator must re-authorize by touching the token file within the TTL
window, then re-invoke the tool. Do not extend TTL; the short window
is the enforcement.
EOF
	exit 1
fi

# Token valid. Log the authorized broadcast attempt for tier-4 cross-check.
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
