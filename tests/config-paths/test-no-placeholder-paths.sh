#!/usr/bin/env bash
# tests/config-paths/test-no-placeholder-paths.sh
#
# Guard against the sanitize failure mode where a de-brand pass rewrites a
# functional config/state path default to the placeholder "<your-namespace>".
# When such a default reaches production it is not merely cosmetic:
#
#   * /var/lib/<your-namespace> — `mkdir -p` fails because the deploy user
#     cannot create a directory under /var/lib, and `set -euo pipefail`
#     aborts the whole script.
#   * /etc/<your-namespace>/... — config lookups resolve to a nonexistent
#     path, so the script errors out demanding an env var that no cron sets.
#
# This exact bug froze the peer-analytics feeds for 18 days: peer-validators.sh
# aborted at its STATE_DIR mkdir, so fee-market.json / peers-gini.json stopped
# regenerating (last sample 2026-06-18) and the downstream push never ran.
#
# The real namespace is the public brand "freedom-yield" (/var/lib/freedom-yield,
# /etc/freedom-yield) — safe to hard-code, and already the default in
# push-to-web-host.sh. Scripts must default to it, never to a placeholder.
#
# CHAIN: none. PRIME_DIRECTIVE: safe (read-only grep).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

hits=$(grep -rn '<your-namespace>' "$REPO_ROOT/scripts/" 2>/dev/null || true)
if [ -z "$hits" ]; then
	PASS=$((PASS + 1))
	echo "  ok: scripts/ carries no <your-namespace> placeholder path"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: scripts/ still ships <your-namespace> placeholder default(s):"
	echo "$hits" | sed 's/^/      /'
fi

echo "test-no-placeholder-paths.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
