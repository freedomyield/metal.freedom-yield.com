#!/usr/bin/env bash
# test-install-metal-anchor-publish-health-cron.sh — regression test for the
# unquoted-heredoc backtick command-substitution bug in
# scripts/install-metal-anchor-publish-health-cron.sh.
#
# CHAIN: none — extracts and renders the installer's `read -r -d '' EXPECTED
# <<CRON` heredoc in an isolated bash subshell. Never runs the installer
# itself (which requires root and writes to /etc/cron.d), never touches the
# network or any real cron.
#
# Why this exists: the heredoc must stay UNQUOTED (`<<CRON`, not `<<'CRON'`)
# so ${REPO_PATH} interpolates into the installed cron line. But in an
# unquoted heredoc, bare backticks anywhere — including inside a comment —
# are command substitution. A header comment once named `2>&1 | logger`
# literally: building EXPECTED executed "2>&1 | logger" as a side effect
# (piping a shell error into logger) AND corrupted the installed cron file's
# comment (the backtick span replaced by that command's output). Fixed by
# backslash-escaping the backticks (\` — literal in an unquoted heredoc,
# does not disturb ${REPO_PATH} interpolation).
#
# Usage:
#   bash tests/anchor-publish-health/test-install-metal-anchor-publish-health-cron.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-metal-anchor-publish-health-cron.sh"

if [ ! -f "$INSTALLER" ]; then
	echo "FATAL: installer not found at $INSTALLER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

BASE="$(mktemp -d -t install-anchor-publish-health-cron-test.XXXXXX)"
teardown() { rm -rf "$BASE"; }
trap teardown EXIT

# Extract the `read -r -d '' EXPECTED <<CRON ... CRON` heredoc verbatim —
# line-number independent (matches the opening `<<CRON` line through the
# closing bare `CRON` delimiter line) — so this test tracks the installer's
# actual source instead of a copy-pasted duplicate that could drift.
HEREDOC_BLOCK="$BASE/heredoc-block.sh"
awk '/<<CRON/{flag=1} flag{print} /^CRON$/{if (flag && NR>1) exit}' "$INSTALLER" > "$HEREDOC_BLOCK"

[ -s "$HEREDOC_BLOCK" ] \
	&& ok "extract: found the EXPECTED heredoc in the installer" \
	|| bad "extract: found the EXPECTED heredoc in the installer"

# Render it in an isolated subshell with a fake REPO_PATH — exactly what the
# installer does internally, minus the root check and the /etc/cron.d write.
RENDER="$BASE/render.sh"
{
	printf '#!/usr/bin/env bash\nset -euo pipefail\n'
	printf 'REPO_PATH="/home/deploy/metal.freedom-yield.com"\n'
	cat "$HEREDOC_BLOCK"
	printf 'printf "%%s\\n" "$EXPECTED"\n'
} > "$RENDER"

STDOUT="$BASE/stdout.txt"
STDERR="$BASE/stderr.txt"
bash "$RENDER" > "$STDOUT" 2> "$STDERR"
RC=$?

[ "$RC" -eq 0 ] \
	&& ok "render: heredoc renders without error" \
	|| bad "render: heredoc renders without error (rc=$RC, stderr: $(cat "$STDERR"))"

[ ! -s "$STDERR" ] \
	&& ok "render: no stderr side effect (no injected command output/errors)" \
	|| bad "render: no stderr side effect (stderr: $(cat "$STDERR"))"

grep -qF '/home/deploy/metal.freedom-yield.com/scripts/check-anchor-publish-health.sh' "$STDOUT" \
	&& ok 'render: ${REPO_PATH} still interpolates into the cron line' \
	|| bad 'render: ${REPO_PATH} still interpolates into the cron line'

grep -qF '`2>&1 | logger`' "$STDOUT" \
	&& ok "render: literal backtick comment text survives verbatim" \
	|| bad "render: literal backtick comment text survives verbatim (out: $(cat "$STDOUT"))"

grep -qi 'not found\|no such file\|command not found' "$STDOUT" \
	&& bad "render: no stray command-substitution artifact in the rendered text" \
	|| ok "render: no stray command-substitution artifact in the rendered text"

# Regression guard: every backtick left in the heredoc source must be
# backslash-escaped (a bare, unescaped backtick in an unquoted heredoc is
# command substitution regardless of which comment it lands in).
TOTAL_BACKTICKS="$(grep -o '`' "$HEREDOC_BLOCK" | wc -l | tr -d ' ')"
ESCAPED_BACKTICKS="$(grep -o '\\`' "$HEREDOC_BLOCK" | wc -l | tr -d ' ')"
[ "$TOTAL_BACKTICKS" -gt 0 ] && [ "$TOTAL_BACKTICKS" -eq "$ESCAPED_BACKTICKS" ] \
	&& ok "source: every backtick in the heredoc is backslash-escaped ($TOTAL_BACKTICKS/$TOTAL_BACKTICKS)" \
	|| bad "source: every backtick in the heredoc is backslash-escaped (total=$TOTAL_BACKTICKS escaped=$ESCAPED_BACKTICKS)"

# No unintended $(...) command substitution anywhere in the heredoc either.
grep -qE '\$\([^)]*\)' "$HEREDOC_BLOCK" \
	&& bad "source: no unintended \$(...) command substitution in the heredoc" \
	|| ok "source: no unintended \$(...) command substitution in the heredoc"

echo "test-install-metal-anchor-publish-health-cron.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
