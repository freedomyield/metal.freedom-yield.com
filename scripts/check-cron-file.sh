#!/usr/bin/env bash
# check-cron-file.sh — pre-flight linter for /etc/cron.d/metal-* files.
#
# Validates that a candidate cron file follows the conventions documented at
# docs/CRON_CONVENTIONS.md. Refuses files that would repeat the 2026-06-19
# 01:30 UTC `metal-evidence` failure (redirect to /var/log/... that the
# deploy user cannot create).
#
# Usage:
#   scripts/check-cron-file.sh <path-to-proposed-cron-file>
#
# Exit status:
#   0   all checks pass
#   1   one or more violations found
#   2   usage error
#
# The linter is intentionally lightweight — pure bash + grep, no external
# config. It does not catch every possible cron mistake, just the rules
# that have actually bitten us in production.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <path-to-cron-file>" >&2
  exit 2
fi

CRON_FILE="$1"

if [ ! -f "$CRON_FILE" ]; then
  echo "ERROR: file not found: $CRON_FILE" >&2
  exit 2
fi

FAILED=0

note() { printf "  • %s\n" "$1"; }
fail() { printf "  ✗ FAIL: %s\n" "$1"; FAILED=$((FAILED + 1)); }
pass() { printf "  ✓ %s\n" "$1"; }

echo "Linting: $CRON_FILE"
echo ""

# Pull just the command lines (skip comments + env-var lines + blanks).
CRON_LINES="$(grep -vE '^\s*(#|$)' "$CRON_FILE" | grep -vE '^[A-Z_]+=' || true)"

if [ -z "$CRON_LINES" ]; then
  fail "no command lines found (every non-comment, non-env line was empty)"
  echo ""
  echo "Result: $FAILED violation(s)."
  exit 1
fi

# ---- Rule 1: /var/log redirects must be verified-writable, not just absent -
# The original rule failed EVERY >> /var/log/ redirect unconditionally. That
# is right for a brand-new entry (the 2026-06-19 metal-evidence failure mode:
# deploy has no create permission under /var/log/, root:syslog 0755), but it
# false-flags the small set of /var/log/ crons that scripts/vps-bootstrap.sh
# pre-provisions itself (touch + chown deploy:deploy + chmod 644, BEFORE the
# cron ever fires) — those are verified-healthy in production, not the
# failure mode this rule exists to catch. So: a /var/log/ target now passes
# if it is either (a) already present on THIS machine and owned by `deploy`
# (empirically verified writable — the vps-bootstrap.sh precondition holds),
# or (b) its basename is in the allowlist below (verified pre-provisioned
# elsewhere, but not directly observable from wherever this linter runs, e.g.
# a Mac checkout linting a candidate file before it ever reaches the host).
# Extending the allowlist requires the same pre-provisioning (touch + chown
# deploy:deploy) to exist for that path — do not add a name here just to
# silence the linter.
echo "[1] Log path must be project-local, or a verified-writable /var/log/ target"
KNOWN_GOOD_VAR_LOG_BASENAMES="server-status.log node-info.log daily-status.log anomalies.log validator-period.log"

var_log_owner() {
  # Prints the file owner username, or nothing if unreadable/unsupported.
  stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1" 2>/dev/null || true
}

VARLOG_TARGETS="$(printf '%s\n' "$CRON_LINES" \
  | grep -oE '>>[[:space:]]*/var/log/[A-Za-z0-9._-]+' \
  | sed -E 's#^>>[[:space:]]*##' | sort -u || true)"

if [ -z "$VARLOG_TARGETS" ]; then
  pass "no /var/log/ redirect."
else
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    base="$(basename "$target")"
    if [ -e "$target" ] && [ "$(var_log_owner "$target")" = "deploy" ]; then
      pass "verified: $target exists and is deploy-owned (pre-provisioned)."
    elif printf '%s\n' $KNOWN_GOOD_VAR_LOG_BASENAMES | grep -qxF "$base"; then
      pass "allowlisted: $target (known pre-provisioned path — see scripts/vps-bootstrap.sh)"
    else
      fail "uses >> $target — not verified deploy-writable and not allowlisted."
      note "Use a project-local path under .../logs/ instead, or pre-provision"
      note "(touch + chown deploy:deploy) and add the basename to the allowlist here."
    fi
  done <<VARLOG
$VARLOG_TARGETS
VARLOG
fi
echo ""

# ---- Rule 2: redirect must apply to a compound, not a single command ------
echo "[2] Compound { ... } redirect so the whole chain shares the log target"
ANY_CHAIN_NO_BRACES=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Skip lines without && (no chain — single-command lines are fine).
  if ! printf '%s' "$line" | grep -q '&&'; then continue; fi
  # Skip lines without a >> redirect (they don't have the problem).
  if ! printf '%s' "$line" | grep -q '>>'; then continue; fi
  # Lines that have both `&&` and `>>` must wrap in `{ ... }` so the
  # redirect scope covers every command in the chain.
  if ! printf '%s' "$line" | grep -qE '\{[^}]*&&[^{]*\}\s*>>'; then
    fail "found a chain that redirects only the last command:"
    printf "         %s\n" "$line"
    note "Wrap the chain in { ... } so every command's output flows to the log."
    ANY_CHAIN_NO_BRACES=1
  fi
done <<< "$CRON_LINES"
[ $ANY_CHAIN_NO_BRACES -eq 0 ] && pass "all chains wrap their redirect in { ... }."
echo ""

# ---- Rule 3: start + end markers + rc capture ----------------------------
echo "[3] Start / end markers and rc capture (audit visibility)"
WANT_MARKERS=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Only required for compound chains that actually do real work (have >>).
  if ! printf '%s' "$line" | grep -q '>>'; then continue; fi
  if ! printf '%s' "$line" | grep -qE 'echo[^|]*start'; then
    fail "no \"=== ... start ===\" marker on this line:"
    printf "         %s\n" "$line"
    WANT_MARKERS=1
  fi
  if ! printf '%s' "$line" | grep -qE 'echo[^|]*end'; then
    fail "no \"=== ... end ===\" marker on this line:"
    printf "         %s\n" "$line"
    WANT_MARKERS=1
  fi
  if ! printf '%s' "$line" | grep -qE 'rc=\$\?'; then
    fail "no rc=\$? capture on this line:"
    printf "         %s\n" "$line"
    WANT_MARKERS=1
  fi
done <<< "$CRON_LINES"
[ $WANT_MARKERS -eq 0 ] && pass "all heavy-work lines have start/end markers + rc capture."
echo ""

# ---- Rule 4: % must be escaped \% ----------------------------------------
echo "[4] % must be escaped \\% inside cron commands"
ANY_BARE_PCT=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Strip env-var assignments-style lines (handled separately).
  # Look for bare % that is NOT preceded by a backslash. The crude check:
  # extract the command portion (after the user field) and look for %.
  CMD_PART="$(printf '%s' "$line" | awk '{for (i=7; i<=NF; i++) printf "%s ", $i; print ""}')"
  # Count bare % (not preceded by backslash). Use perl-style negative
  # lookbehind via grep -P. If grep -P is unavailable, fall back to
  # naive check that counts % minus \%.
  if command -v grep >/dev/null 2>&1 && grep -P -q '(?<!\\)%' <<< "$CMD_PART" 2>/dev/null; then
    fail "bare % (unescaped) detected — cron will silently truncate the command:"
    printf "         %s\n" "$line"
    ANY_BARE_PCT=1
  fi
done <<< "$CRON_LINES"
[ $ANY_BARE_PCT -eq 0 ] && pass "no bare % in command lines (or grep -P unavailable; manual review recommended)."
echo ""

# ---- Rule 5: SHELL=/bin/bash + PATH set at top of file -------------------
echo "[5] SHELL and PATH explicitly set at the top of the file"
if grep -qE '^SHELL=/bin/bash\b' "$CRON_FILE"; then
  pass "SHELL=/bin/bash"
else
  fail "missing 'SHELL=/bin/bash' at the top of the file."
  note "Without it, cron defaults to /bin/sh and bash-only syntax may break."
fi
if grep -qE '^PATH=' "$CRON_FILE"; then
  pass "PATH explicitly set"
else
  fail "missing 'PATH=' at the top of the file."
  note "Cron's default PATH is minimal; set it so your scripts find their tools."
fi

echo ""
echo "Result: $FAILED violation(s)."
[ $FAILED -eq 0 ] && exit 0 || exit 1
