#!/usr/bin/env bash
# tests/host-account/test-host-account.sh — scripts/lib/host-account.sh
# (fyd_cron_user) and the installers' derived defaults.
#
# CHAIN: none — writes only inside a tempdir; no host, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# The installers no longer carry the host account's login name or its home
# path. They take the repo path from their own location and the account from
# the checkout's owner. This suite proves both derivations, and that an
# owner that cannot be trusted (root, unknown, missing) stops the installer
# instead of writing a cron line for the wrong account.

set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/host-account.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

BASE="$(mktemp -d -t host-account-test.XXXXXX)"
trap 'rm -rf "$BASE"' EXIT
ME="$(id -un)"

# shellcheck source=/dev/null
. "$LIB"
unset FYD_CRON_USER

# 1. the explicit override wins over the owner
[ "$(FYD_CRON_USER=someone fyd_cron_user "$BASE")" = "someone" ] \
	&& ok "override: FYD_CRON_USER wins over the checkout owner" \
	|| bad "override: FYD_CRON_USER wins over the checkout owner"

# 2. without an override, the owner of the path is the account
[ "$(fyd_cron_user "$BASE")" = "$ME" ] \
	&& ok "owner: a path owned by the invoking user names that user" \
	|| bad "owner: a path owned by the invoking user names that user"

# 3. fail closed: root-owned, missing, empty
OUT="$(fyd_cron_user / 2>&1)"; RC=$?
{ [ "$RC" -ne 0 ] && [ -z "$OUT" ]; } \
	&& ok "fail-closed: a root-owned path names nobody (rc!=0, no output)" \
	|| bad "fail-closed: a root-owned path names nobody (rc=$RC out='$OUT')"
OUT="$(fyd_cron_user "$BASE/no-such-dir" 2>&1)"; RC=$?
{ [ "$RC" -ne 0 ] && [ -z "$OUT" ]; } \
	&& ok "fail-closed: a missing path names nobody" \
	|| bad "fail-closed: a missing path names nobody (rc=$RC out='$OUT')"
OUT="$(fyd_cron_user "" 2>&1)"; RC=$?
{ [ "$RC" -ne 0 ] && [ -z "$OUT" ]; } \
	&& ok "fail-closed: no path and no override names nobody" \
	|| bad "fail-closed: no path and no override names nobody (rc=$RC out='$OUT')"

# 4. an installer run from a copy of the tree, from another cwd, with no
#    FYD_REPO_PATH: the path in the generated cron line is the copy's own
#    location and the account is its owner.
TREE="$BASE/tree"
mkdir -p "$TREE/scripts/lib" "$TREE/logs"
cp "${REPO_ROOT}/scripts/install-metal-host-drift-cron.sh" "${REPO_ROOT}/scripts/check-cron-file.sh" "$TREE/scripts/"
cp "$LIB" "$TREE/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TREE/scripts/check-host-drift.sh"
chmod +x "$TREE/scripts/"*.sh
(cd / && env -u FYD_REPO_PATH -u FYD_CRON_USER FYD_CRON_TARGET="$BASE/cron-out" FYD_BACKUP_DIR="$BASE/bk" \
	bash "$TREE/scripts/install-metal-host-drift-cron.sh") >"$BASE/inst.out" 2>&1
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "installer: runs from a copied tree with no FYD_REPO_PATH (rc=0)" \
	|| bad "installer: runs from a copied tree with no FYD_REPO_PATH (rc=$RC: $(cat "$BASE/inst.out"))"
grep -qF " ${ME} bash ${TREE}/scripts/check-host-drift.sh " "$BASE/cron-out" \
	&& ok "installer: cron line carries the checkout's own path and its owner" \
	|| bad "installer: cron line carries the checkout's own path and its owner"

# 5. the same installer refuses (exit 5) when the owner cannot be trusted
# A checkout whose owner is root (stubbed: a real chown needs root):
FAKE_ROOT_TREE="$BASE/rootish"
mkdir -p "$FAKE_ROOT_TREE/scripts/lib"
cp "$TREE/scripts/install-metal-host-drift-cron.sh" "$FAKE_ROOT_TREE/scripts/"
cp "$LIB" "$FAKE_ROOT_TREE/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT_TREE/scripts/check-host-drift.sh"
# a stub `stat` that reports root for any path, standing in for a root-owned checkout
STUBBIN="$BASE/stubbin"; mkdir -p "$STUBBIN"
printf '#!/bin/sh\necho root\n' > "$STUBBIN/stat"; chmod +x "$STUBBIN/stat"
(cd / && env -u FYD_CRON_USER PATH="$STUBBIN:$PATH" FYD_CRON_TARGET="$BASE/cron-out3" FYD_BACKUP_DIR="$BASE/bk" \
	bash "$FAKE_ROOT_TREE/scripts/install-metal-host-drift-cron.sh") >"$BASE/inst3.out" 2>&1
RC=$?
{ [ "$RC" -eq 5 ] && [ ! -e "$BASE/cron-out3" ]; } \
	&& ok "installer: a root-owned checkout stops it with exit 5 and writes nothing" \
	|| bad "installer: a root-owned checkout stops it with exit 5 and writes nothing (rc=$RC)"

echo "test-host-account.sh summary: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
