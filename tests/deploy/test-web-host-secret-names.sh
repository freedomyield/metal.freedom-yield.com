#!/usr/bin/env bash
# tests/deploy/test-web-host-secret-names.sh
#
# Invariant: the GitHub secrets that deploy.yml reads for the web host leg are
# exactly WEB_HOST_SSH_KEY / _HOST / _PORT / _USER, and no other *_SSH_*
# secret feeds a web host step.
#
# Why: the web host leg skips itself ("secrets not set") when its key or host
# secret is empty. A name that drifts from what is registered in GitHub makes
# the public deploy stop silently, with the validator-host leg still green.
# Nothing else pinned these names.
#
# Checks (each is also run against a mutant and must fail on it):
#   N1 the set of WEB_HOST_SSH_* secret names referenced is exactly the four
#   N3 each env variable in the two web host steps maps to its own
#      WEB_HOST_SSH_* name, and exactly six references exist (HOST and PORT are
#      used in both steps, so a one-sided drift is caught)
#   N2 no secret named *_SSH_{KEY,HOST,PORT,USER} other than WEB_HOST_* and the
#      validator-host leg's plain SSH_* is referenced (a renamed-by-accident
#      or leftover old name)
#
# CHAIN: none. PRIME_DIRECTIVE: TESTNET-FIRST — safe.

set -uo pipefail
exec </dev/null

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REPO/.github/workflows/deploy.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; FAILURES=()
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILURES+=("$1 ($2)"); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
finish() {
  echo
  echo "PASS=$PASS FAIL=$FAIL"
  if [ "$FAIL" -ne 0 ]; then printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
  exit 0
}
report() {
  if [ -z "$2" ]; then ok "$1"
  else while IFS= read -r l; do bad "$1" "$l"; done <<<"$2"; fi
}
expect_caught() {
  if [ -n "$2" ]; then ok "mutant caught: $1"
  else bad "mutant NOT caught: $1" "check printed nothing"; fi
}

# Secret names referenced in code (comment lines excluded).
refs() { grep -v -E '^[[:space:]]*#' "$1" | grep -o -E 'secrets\.[A-Z0-9_]+' | sed 's/^secrets\.//' | sort -u; }

check_exact() {
  local got want
  got="$(refs "$1" | grep '^WEB_HOST_SSH_' | tr '\n' ' ')"
  want="WEB_HOST_SSH_HOST WEB_HOST_SSH_KEY WEB_HOST_SSH_PORT WEB_HOST_SSH_USER "
  [ "$got" = "$want" ] || echo "WEB_HOST_SSH_* names are [${got}] expected [${want}]"
  return 0
}
check_no_other() {
  # Any *_SSH_KEY/HOST/PORT/USER secret that is neither WEB_HOST_* nor the plain
  # validator-host SSH_* names.
  refs "$1" | grep -E '_SSH_(KEY|HOST|PORT|USER)$' | grep -v '^WEB_HOST_SSH_' | sed 's/^/other web-host-style secret referenced: /'
  return 0
}

# Per-reference pairs (env variable -> secret name) in the web host steps.
pairs() {
  # LC_ALL=C keeps the sort order the same on every machine
  grep -v -E '^[[:space:]]*#' "$1" |
    sed -n -E 's/^[[:space:]]*(_?XS_[A-Z]+):[[:space:]]*\$\{\{[[:space:]]*secrets\.([A-Z0-9_]+)[[:space:]]*\}\}.*/\1=\2/p' | LC_ALL=C sort
}
check_pairs() {
  local got want
  got="$(pairs "$1" | tr '\n' ' ')"
  want="XS_HOST=WEB_HOST_SSH_HOST XS_HOST=WEB_HOST_SSH_HOST XS_PORT=WEB_HOST_SSH_PORT XS_PORT=WEB_HOST_SSH_PORT XS_USER=WEB_HOST_SSH_USER _XS_KEY=WEB_HOST_SSH_KEY "
  [ "$got" = "$want" ] || echo "web host step env pairs are [${got}] expected [${want}]"
  return 0
}

echo "N1: deploy.yml references exactly the four WEB_HOST_SSH_* secrets"
report "N1 exact WEB_HOST_SSH_* set" "$(check_exact "$WORKFLOW")"
echo "N2: no other *_SSH_* secret name"
report "N2 no old / other prefixed secret" "$(check_no_other "$WORKFLOW")"

# Mutant 1: one reference renamed.
perl -pe 's/secrets\.WEB_HOST_SSH_PORT/secrets.WEB_HOST_SSH_PRT/ if /secrets\.WEB_HOST_SSH_PORT/ && !$d++' "$WORKFLOW" >"$TMP/m1.yml"
if cmp -s "$TMP/m1.yml" "$WORKFLOW"; then bad "mutant 1 changed deploy.yml" "sed matched nothing"
else expect_caught "one reference renamed (N1)" "$(check_exact "$TMP/m1.yml")"; fi
# Mutant 2: one reference given an old-style prefix.
perl -pe 's/secrets\.WEB_HOST_SSH_HOST/secrets.OLDHOST_SSH_HOST/ if /secrets\.WEB_HOST_SSH_HOST/ && !$d++' "$WORKFLOW" >"$TMP/m2.yml"
if cmp -s "$TMP/m2.yml" "$WORKFLOW"; then bad "mutant 2 changed deploy.yml" "sed matched nothing"
else
  expect_caught "old-style name present (N2)" "$(check_no_other "$TMP/m2.yml")"
fi

echo "N3: every web host step reference maps variable -> the matching WEB_HOST_SSH_* name"
report "N3 per-reference pairs (6 refs)" "$(check_pairs "$WORKFLOW")"

# Mutants for N3: one of two HOST refs -> validator-leg name; one of two PORT refs
# -> a name without _SSH_; one reference removed.
mut() { # <out> <perl-expr>
  perl -ne "$2" "$WORKFLOW" >"$1"
  if cmp -s "$1" "$WORKFLOW"; then return 1; fi
}
if mut "$TMP/m3.yml" 'if (/XS_HOST: .*secrets\.WEB_HOST_SSH_HOST/ && !$d++) { s/WEB_HOST_SSH_HOST/SSH_HOST/ } print'
then expect_caught "one HOST ref -> SSH_HOST (N3)" "$(check_pairs "$TMP/m3.yml")"
else bad "mutant 3 changed deploy.yml" "perl matched nothing"; fi
if mut "$TMP/m4.yml" 'if (/XS_PORT: .*secrets\.WEB_HOST_SSH_PORT/ && !$d++) { s/WEB_HOST_SSH_PORT/WEBPORT/ } print'
then expect_caught "one PORT ref -> name without _SSH_ (N3)" "$(check_pairs "$TMP/m4.yml")"
else bad "mutant 4 changed deploy.yml" "perl matched nothing"; fi
if mut "$TMP/m5.yml" 'if (/XS_USER: .*secrets\.WEB_HOST_SSH_USER/ && !$d++) { next } print'
then expect_caught "one reference removed (N3)" "$(check_pairs "$TMP/m5.yml")"
else bad "mutant 5 changed deploy.yml" "perl matched nothing"; fi

finish
