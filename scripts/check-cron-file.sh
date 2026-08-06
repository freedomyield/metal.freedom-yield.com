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
# Env overrides:
#   FYD_CRON_SCRIPTS_DIR  scripts/ dir used to resolve a referenced *.sh
#                         basename for Rule 6 (default: this script's own
#                         directory). Test/audit-only knob.
#   FYD_CRON_FY_LIVE_GRACE=1  downgrades a Rule 6 miss to a warning. See
#                         Rule 6's own comment for the migration-window
#                         rationale — never set this from an installer.
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

# ---- Rule 6: side-effecting cron entries must carry FY_LIVE=1 -------------
# scripts/lib/side-effects.sh (2026-08-06) makes every production side
# effect (ntfy notify, web-host push, /var/lib/freedom-yield state writes)
# opt-in behind FY_LIVE=1 — anything else is a loud dry no-op. Migrating
# each side-effecting script's calls onto the lib is a separate task;
# landing this rule together with the FY_LIVE=1 line scripts/install-*-cron.sh
# (and vps-bootstrap.sh) now write closes the dangerous ordering where a
# migrated script fires under an un-flagged cron and goes silently dry —
# "the cron went quiet and nobody noticed" is the one failure mode this
# rollout is most afraid of.
#
# Detection is two-layered, the same shape as Rule 1's precedent above:
#   (a) dynamic  — a referenced scripts/<name>.sh that resolves inside the
#       scripts dir being checked (default: this script's own directory;
#       override with FYD_CRON_SCRIPTS_DIR for tests / audits from a
#       different checkout) and whose content sources
#       scripts/lib/side-effects.sh. Needs no maintenance: a script is
#       picked up automatically the day it migrates onto the lib.
#   (b) allowlist — scripts already known (2026-08-06 audit) to call
#       notify.sh / push-to-web-host.sh / a /var/lib/freedom-yield state
#       dir directly, BEFORE their migration onto the lib lands. Extend
#       this list only when a script GAINS a production side effect, never
#       to silence this rule. KEPT IN SYNC with the identical list in
#       install-cron-env-headers.sh — see that script's own comment and the
#       cross-file consistency case in tests/check-cron-file/.
#
# A reference that matches NEITHER layer is not flagged (fail-open on this
# one rule) — an unresolvable name (a synthetic test fixture's placeholder
# script, or a real script this checkout doesn't happen to carry) must not
# force every unrelated cron file to also carry FY_LIVE=1. The two layers
# above are what keep a REAL side-effecting script from silently escaping
# the rule as new callers appear.
#
# Migration-window grace: check-cron-file.sh is invoked ONLY as a pre-flight
# gate inside scripts/install-*-cron.sh (this candidate content, not yet
# written anywhere) and by its own test suite — nothing in this repo runs it
# against an already-deployed /etc/cron.d/metal-* file automatically. A host
# file installed before this rule existed will not trip any gate until (a) a
# human pulls it down and lints it by hand (an audit), or (b) its owning
# installer is re-run. FYD_CRON_FY_LIVE_GRACE=1 exists for case (a) only —
# to audit a not-yet-reinstalled host file during the 2026-08 migration
# window without the audit itself reporting a false new violation. It must
# never be set by an installer's own pre-flight call.
echo "[6] Side-effecting cron entries must carry FY_LIVE=1"

# See install-cron-env-headers.sh — this list MUST stay identical there.
KNOWN_SIDE_EFFECT_CRON_BASENAMES="notify.sh push-to-web-host.sh notify-anchor-transition.sh watch-anchor-events.sh check-anchor-publish-health.sh check-host-drift.sh advance-host-checkout.sh check-watch-validators.sh daily-status.sh check-anomalies.sh"

CRON_FILE_SCRIPTS_DIR="${FYD_CRON_SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"

cron_basename_is_side_effecting() {
  local bn="$1"
  # shellcheck disable=SC2086  # intentional word-split of the space-separated list
  if printf '%s\n' $KNOWN_SIDE_EFFECT_CRON_BASENAMES | grep -qxF "$bn"; then
    return 0
  fi
  local candidate="${CRON_FILE_SCRIPTS_DIR}/${bn}"
  if [ -r "$candidate" ] && grep -qE 'side-effects\.sh' "$candidate" 2>/dev/null; then
    return 0
  fi
  return 1
}

SH_BASENAMES="$(printf '%s\n' "$CRON_LINES" \
  | grep -oE 'scripts/[A-Za-z0-9_.-]+\.sh' \
  | sed -E 's#^scripts/##' | sort -u || true)"

SIDE_EFFECT_HITS=""
while IFS= read -r bn; do
  [ -z "$bn" ] && continue
  if cron_basename_is_side_effecting "$bn"; then
    SIDE_EFFECT_HITS="${SIDE_EFFECT_HITS} ${bn}"
  fi
done <<< "$SH_BASENAMES"

if [ -z "$SIDE_EFFECT_HITS" ]; then
  pass "no side-effecting script referenced (or none resolvable) — FY_LIVE not required."
elif grep -qE '^FY_LIVE=1$' "$CRON_FILE"; then
  pass "FY_LIVE=1 present (required by:${SIDE_EFFECT_HITS})"
elif [ "${FYD_CRON_FY_LIVE_GRACE:-0}" = "1" ]; then
  note "MISSING FY_LIVE=1 (required by:${SIDE_EFFECT_HITS}) — downgraded to a warning because FYD_CRON_FY_LIVE_GRACE=1 is set."
  note "Migration-window audit exception only. Never set this inside an installer's own pre-flight call — re-run the owning installer to close the gap for real."
else
  fail "references side-effecting script(s) (${SIDE_EFFECT_HITS# }) but the file has no 'FY_LIVE=1' line."
  note "See scripts/lib/side-effects.sh. Add 'FY_LIVE=1' to the env header, or (migration-window audits only) set FYD_CRON_FY_LIVE_GRACE=1."
fi

echo ""
echo "Result: $FAILED violation(s)."
[ $FAILED -eq 0 ] && exit 0 || exit 1
