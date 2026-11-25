#!/usr/bin/env bash
# tests/notify-relay/test-make-notify-relay-token.sh — contract of scripts/operator-local/make-notify-relay-token.sh (P4).
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No network. FYD_RELAY_TOKEN_DIR always points at a temp dir.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL_REL="scripts/operator-local/make-notify-relay-token.sh"
TOOL_PATH="${MAKE_TOKEN_TOOL_OVERRIDE:-$REPO_ROOT/$TOOL_REL}"
SENDER_A='metal-validator'
SENDER_B='metal-external-watch'

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected [$2] got [$3])"; fi; }

TMP_ROOT="$(mktemp -d "$REPO_ROOT/.make-token-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

if [ ! -r "$TOOL_PATH" ]; then
  echo "FAIL - tool missing: $TOOL_REL"
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# run_tool <dir> <out> <err> args... — runs with the token dir pointed at <dir>; returns the tool's rc.
run_tool() {
  local dir=$1 out=$2 err=$3; shift 3
  FYD_RELAY_TOKEN_DIR="$dir" bash "$TOOL_PATH" "$@" >"$out" 2>"$err"
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
sha_of_file_content() { # sha256 of the token without its newline
  printf '%s' "$(head -n 1 "$1")" | shasum -a 256 | cut -d' ' -f1
}

D1="$TMP_ROOT/d1"
run_tool "$D1" "$TMP_ROOT/o1" "$TMP_ROOT/e1" "$SENDER_A"; rc=$?
eq "valid sender exits 0" 0 "$rc"
TOKFILE="$D1/$SENDER_A.token"
eq "token file mode 600" 600 "$(mode_of "$TOKFILE")"
eq "token dir mode 700" 700 "$(mode_of "$D1")"
eq "token file has exactly one line" 1 "$(wc -l <"$TOKFILE" | tr -d ' ')"
TOK="$(head -n 1 "$TOKFILE")"
if [[ "$TOK" =~ ^[A-Za-z0-9_-]{43}$ ]]; then ok "token is 43 base64url chars"; else fail "token form"; fi
eq "stdout is exactly one line" 1 "$(wc -l <"$TMP_ROOT/o1" | tr -d ' ')"
SHA="$(sha_of_file_content "$TOKFILE")"
eq "stdout key is sha256 of token" "$SHA" "$(jq -r 'keys[0]' "$TMP_ROOT/o1")"
eq "stdout has one key" 1 "$(jq -r 'keys | length' "$TMP_ROOT/o1")"
eq "stdout sender" "$SENDER_A" "$(jq -r '.[keys[0]].sender' "$TMP_ROOT/o1")"
eq "stdout routes" '["put"]' "$(jq -c '.[keys[0]].routes' "$TMP_ROOT/o1")"
if grep -qFf "$TOKFILE" "$TMP_ROOT/o1"; then fail "token leaked to stdout"; else ok "no token in stdout"; fi
if grep -qFf "$TOKFILE" "$TMP_ROOT/e1"; then fail "token leaked to stderr"; else ok "no token in stderr"; fi
eq "stderr names the file only" "$SENDER_A.token" "$(tr -d '\n' <"$TMP_ROOT/e1" | sed 's#.*/##')"

# second run: refuses, file unchanged
BEFORE="$(shasum -a 256 <"$TOKFILE")"
run_tool "$D1" "$TMP_ROOT/o2" "$TMP_ROOT/e2" "$SENDER_A"; rc=$?
eq "second run exits 2" 2 "$rc"
eq "file unchanged after second run" "$BEFORE" "$(shasum -a 256 <"$TOKFILE")"
eq "no stdout on refusal" 0 "$(wc -c <"$TMP_ROOT/o2" | tr -d ' ')"

# existing dir without file: created
D2="$TMP_ROOT/d2"; mkdir "$D2"
run_tool "$D2" "$TMP_ROOT/o3" "$TMP_ROOT/e3" "$SENDER_B"; rc=$?
eq "existing dir, no file: exits 0" 0 "$rc"
eq "existing dir forced to 700" 700 "$(mode_of "$D2")"
if [ "$(head -n 1 "$D2/$SENDER_B.token")" = "$TOK" ]; then fail "two tokens equal"; else ok "two tokens differ"; fi

# bad senders
D3="$TMP_ROOT/d3"
run_tool "$D3" "$TMP_ROOT/o4" "$TMP_ROOT/e4" "someone-else"; rc=$?
eq "unknown sender exits 1" 1 "$rc"
run_tool "$D3" "$TMP_ROOT/o5" "$TMP_ROOT/e5"; rc=$?
eq "no args exits 1" 1 "$rc"
run_tool "$D3" "$TMP_ROOT/o6" "$TMP_ROOT/e6" "$SENDER_A" extra; rc=$?
eq "extra arg exits 1" 1 "$rc"
if [ -e "$D3" ]; then fail "bad sender created the dir"; else ok "bad sender creates nothing"; fi

# default dir: no FYD_RELAY_TOKEN_DIR -> under HOME at the definition's place.
# The expected place is spelled out (not read from the definition), so a change
# of the definition or of the tool's default is what this catches.
DEFAULT_RELAY_DIR_REL='.config/metal.freedom-yield.com/key/notify-relay'
H5="$TMP_ROOT/h5"; mkdir "$H5"
env -u FYD_RELAY_TOKEN_DIR HOME="$H5" bash "$TOOL_PATH" "$SENDER_A" >"$TMP_ROOT/o7" 2>"$TMP_ROOT/e7"; rc=$?
eq "default dir: exits 0" 0 "$rc"
if [ -f "$H5/$DEFAULT_RELAY_DIR_REL/$SENDER_A.token" ]; then ok "default dir: token under HOME/$DEFAULT_RELAY_DIR_REL"; else fail "default dir: token under HOME/$DEFAULT_RELAY_DIR_REL"; fi
eq "default dir: nothing else at HOME's top" "$(basename "${DEFAULT_RELAY_DIR_REL%%/*}")" "$(ls -A "$H5" | tr '\n' ' ' | sed 's/ $//')"

echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
