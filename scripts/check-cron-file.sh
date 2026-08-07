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

# ---- Rule 2: a chain's redirect/pipe must cover the WHOLE chain -----------
# A pipeline binds TIGHTER than && (or ;), so in
#     A && B 2>&1 | logger
# the pipe applies ONLY to B — A's stdout/stderr go to cron's own handling
# (typically MAILTO, usually unset on this host, so just dropped). The exact
# same problem exists for a redirect:
#     A && B >> log 2>&1
# only redirects B. Both are fixed the same way: wrap the whole chain in
# `{ ... ; }` and put the redirect/pipe AFTER the closing brace, or run the
# chain as a single `bash -c "A && B" 2>&1 | logger` invocation (the chain is
# then opaque to cron; the outer redirect/pipe scopes that one bash -c
# process, which is what we want — this is the real production shape used by
# the freedom-yield-peer-geo cron).
#
# 2026-08-07 widening. Originally this rule only inspected lines containing
# `>>` — a line whose only sink was a pipe (`2>&1 | logger`) was invisible to
# it, and it PASSED with an explicit "✓ all chains wrap their redirect in
# { ... }" even though it never looked at that line. This is exactly how a
# real cron sample (TOOLKIT.md's old `peer-validators` line) shipped with 4
# of 6 output streams silently dropped while the linter said it was fine. Now
# checked, for any line with a top-level `&&`:
#   - `>>` (append redirect) — as before.
#   - a bare `>` that is not part of an `N>&M` fd-duplication like `2>&1`
#     (so `A && B > /tmp/x 2>&1` is now caught; `2>&1` alone is not a false
#     trigger — it never writes to a file or a process by itself).
#   - `|` (pipe to another command, e.g. `logger`).
#
# Quoting. "Top-level" means outside any '...' or "...". The check strips
# quoted substrings first — a plain textual strip, NOT a shell parse — so
# `bash -c "A && B" 2>&1 | logger` reads as a single command with no
# top-level chain: the && is opaque inside bash -c's own argument, and the
# outer pipe scopes that one process, which is correct. The SAME stripped
# text is used to look for the `{ ... }` wrapper, so a brace pair that only
# exists INSIDE a quoted argument can't be mistaken for a real wrapper
# around a chain that is actually unbraced.
#
# Known gaps (deliberate — see task-h4-report.md for the full reasoning):
#   - `;` and `||` chains are not inspected, only `&&`. No production cron
#     line in this repo joins top-level commands with `;` or `||`; widening
#     to them risks false positives from a literal `;` inside an unquoted
#     argument without a real shell parse, which this linter deliberately
#     does not attempt (see the 2026-08-06 publish-guard "tried to understand
#     shell" over-reach precedent this task exists to avoid repeating). This
#     is also why a MULTI-STATEMENT line — an independently `;`-separated
#     chain BEFORE or AFTER a correctly-wrapped `{ ... && ... ; } | sink`
#     group on the same line — is not detected even though the unwrapped
#     part has the exact same problem: the wrapped group's own match is
#     enough to mark the WHOLE line safe. No production cron line in this
#     repo puts more than one top-level statement on a line, so this has
#     never fired in practice; documented here rather than silently relied
#     on (2026-08-07 review F-5 — verified the shape both before and after
#     that review's F-1 fix).
#   - The quote-strip is a plain textual `"[^"]*"` / `'[^']*'` removal, not a
#     shell tokenizer: it does not understand backslash-escaped quotes
#     (`\"` inside a double-quoted string). Spot-checked 2026-08-07 with
#     three shapes containing `\"` (a safe one, and two genuinely-broken
#     unwrapped-chain ones) — all three came out correct, because an EVEN
#     number of literal `"` characters still pairs up left-to-right into
#     something that resolves the same top-level `&&`/sink either way. This
#     is not a proof for every possible escaped-quote shape, only the ones
#     tested; unlike a truly ambiguous case, an ODD/unbalanced literal quote
#     count reliably leaves a stray `&&` or brace unmatched, which can only
#     ever produce an EXTRA violation (fail closed), never a missed one —
#     the same posture Rule 1 and Rule 6 already take toward input they
#     cannot fully resolve.
echo "[2] A chain's redirect/pipe must cover the WHOLE chain, not just its last command"
ANY_CHAIN_NO_BRACES=0
while IFS= read -r line; do
  [ -z "$line" ] && continue

  # Strip quoted substrings so a && / > / | found INSIDE a quoted argument
  # (e.g. bash -c "A && B") is not mistaken for a top-level chain or sink.
  UNQUOTED="$(printf '%s' "$line" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")"

  # No top-level && => no chain, nothing here for this rule to check.
  if ! printf '%s' "$UNQUOTED" | grep -q '&&'; then continue; fi

  # Strip fd-duplication tokens (2>&1, >&2, ...) GLOBALLY over the whole
  # line before any further matching — not just from a slice taken after
  # some separately-computed "end of brace" boundary. 2026-08-07 review
  # (F-1): an earlier version sliced the line with `sed 's/^.*\}//'` to get
  # "everything after the brace", but that `.*` is greedy and eats through
  # to the LAST `}` in the line, not the chain's own closing brace — a
  # trailing `${VAR}` (`{ A && B ; } >> ${LOGDIR}/x.log 2>&1`) or a `}`
  # inside an unquoted argument (`{ A && B ; } 2>&1 | logger -t tag-}x`)
  # both swallowed the real `>>`/`|` into the discarded prefix and produced
  # a false violation on a correctly-wrapped line. Stripping fd-dup globally
  # first, then testing the WHOLE probe with ONE anchored regex below (the
  # same shape Rule 2 always used for `>>` alone) avoids ever slicing the
  # string at all — the regex engine itself finds the correct closing brace,
  # because `[^{]*` cannot cross a real `{` and a candidate `}` that isn't
  # immediately followed by a sink simply fails to complete the match, which
  # correctly rules out an unrelated LATER `}` on the same line (proved by
  # case 8j/8k's two F-1 fixtures below).
  PROBE="$(printf '%s' "$UNQUOTED" | sed -E 's/[0-9]*>&[0-9]+//g')"

  # Does the chain have a scope-sensitive sink at all?
  if ! printf '%s' "$PROBE" | grep -qE '[>|]'; then continue; fi

  # A chain with a sink is safe ONLY if a `{ ... }` wrapper covers the whole
  # chain and the sink sits right after ITS OWN closing brace — one anchored
  # match, not a match-then-slice.
  WRAPPED=0
  if printf '%s' "$PROBE" | grep -qE '\{[^}]*&&[^{]*\}[[:space:]]*[>|]'; then
    WRAPPED=1
  fi

  if [ "$WRAPPED" -eq 0 ]; then
    # NOTE: keep the literal substring "found a chain that redirects only
    # the last command" at the front of this message — it is asserted
    # verbatim by tests/cron-generators-lint/test-cron-generators-lint.sh
    # (outside this task's file set), which predates the 2026-08-07 pipe
    # widening below and still expects it.
    fail "found a chain that redirects only the last command (a trailing | pipe has the exact same problem):"
    printf "         %s\n" "$line"
    note "Wrap the chain in { ... ; } with the redirect/pipe AFTER the closing"
    note "brace, or invoke it as bash -c \"...\" 2>&1 | ..., so every"
    note "command's output reaches the log."
    ANY_CHAIN_NO_BRACES=1
  fi
done <<< "$CRON_LINES"
[ $ANY_CHAIN_NO_BRACES -eq 0 ] && pass "every && chain with a redirect or pipe wraps it in { ... } (or is a single bash -c \"...\" invocation)."
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
# Known gap (not closed by either layer): a script that reaches
# notify.sh/push-to-web-host.sh only INDIRECTLY — via an env-injected
# driver rather than a literal scripts/<name>.sh token in the cron command
# — is invisible to both the allowlist match (the driver's basename never
# appears in CRON_LINES) and the dynamic resolve (same reason). Example:
# install-anchor-watch-alert-only.sh's cron line invokes
# watch-anchor-events.sh directly (allowlisted, so still caught here), but
# ANCHOR_DRIVER=notify-anchor-transition.sh is set via env, not spelled out
# on the command line — if watch-anchor-events.sh's OWN allowlist entry
# were ever removed, its indirect notify call would stop being detected.
# Rule 6 is therefore a floor, not a proof of completeness; a script whose
# ONLY side-effecting caller is reached by env-injected indirection needs
# its own allowlist entry, not just its driver's.
#
# Exact-match caveat: FY_LIVE=1 must appear as a bare `^FY_LIVE=1$` line —
# no surrounding whitespace, no quoting, no inline comment. A hand-edited
# file that wrote `FY_LIVE = 1` or `FY_LIVE=1  # note` will be reported as
# MISSING even though cron would likely still export a truthy-looking
# value. This mirrors fyd_is_live()'s own deliberate strictness
# (scripts/lib/side-effects.sh: "no trimming, no truthiness, no case
# folding") — the two must agree on what counts as live, or a file could
# lint clean while the library it's gating still treats it as dry.
#
# Migration-window grace: check-cron-file.sh is invoked ONLY as a pre-flight
# gate inside scripts/install-*-cron.sh (this candidate content, not yet
# written anywhere), by install-repoint-publish-crons.sh's own before/after
# lint_violations() comparison (wrapped in FYD_CRON_FY_LIVE_GRACE=1 there —
# repointing a script name is not the tool that should be blocked by an
# unrelated FY_LIVE gap), and by its own test suite — nothing else in this
# repo runs it against an already-deployed /etc/cron.d file automatically.
# A host file installed before this rule existed will not trip any OTHER
# gate until (a) a human pulls it down and lints it by hand (an audit), or
# (b) its owning installer is re-run. FYD_CRON_FY_LIVE_GRACE=1 exists for
# case (a) only — to audit a not-yet-reinstalled host file during the
# 2026-08 migration window without the audit itself reporting a false new
# violation. It must never be set by an installer's own pre-flight call.
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
