#!/usr/bin/env bash
# scripts/operator-local/make-notify-relay-token.sh — make one notify-relay token (P4).
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No network, no broadcast, no AI call.
#
# MUST NOT BE RUN ON VALIDATOR HOST OR WEB HOST. Operator's local Mac only.
#
# Usage: make-notify-relay-token.sh <sender>
#   sender: metal-validator | metal-external-watch
# Effect: writes <dir>/<sender>.token (mode 600, token + newline) and prints ONE
#   JSON line on stdout: {"<sha256 of token>":{"sender":"<sender>","routes":["put"]}}
#   The token itself never goes to stdout, stderr or any argv.
# Exit: 0 ok / 1 usage or unknown sender / 2 token file already exists (never overwritten)
#       / 3 generated token has the wrong form (not retried) / 4 environment problem.
#
# Where to connect: the JSON line is added to the ops-side token table (notify side, by hand).
#   The raw token goes to the validator host via P3 --install-secrets on stdin.
# How to remove: delete this file and its test; nothing else reads it.

# --- definition table
RELAY_TOKEN_SENDERS='metal-validator metal-external-watch'
RELAY_TOKEN_RANDOM_BYTES=32
RELAY_TOKEN_FILE_SUFFIX='.token'
RELAY_TOKEN_TEXT_LIB_REL='../lib/notify-text.sh'
RELAY_TOKEN_OPERATOR_PATHS_LIB_REL='../lib/operator-paths.sh'

set -uo pipefail
umask 077

# shellcheck source=scripts/lib/notify-text.sh
# shellcheck source-path=SCRIPTDIR/../..
. "$(dirname "$0")/$RELAY_TOKEN_TEXT_LIB_REL" || exit 4
# shellcheck source=scripts/lib/operator-paths.sh
# shellcheck source-path=SCRIPTDIR/../..
. "$(dirname "$0")/$RELAY_TOKEN_OPERATOR_PATHS_LIB_REL" || exit 4

# relay_token_sender_is_known <sender>
relay_token_sender_is_known() {
  local candidate
  for candidate in $RELAY_TOKEN_SENDERS; do
    [ "$candidate" = "${1:-}" ] && return 0
  done
  return 1
}

# relay_token_resolve_dir — prints the token dir; empty/unset FYD_RELAY_TOKEN_DIR means the default under HOME.
relay_token_resolve_dir() {
  if [ -n "${FYD_RELAY_TOKEN_DIR:-}" ]; then
    printf '%s' "$FYD_RELAY_TOKEN_DIR"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/%s' "$HOME" "$FYD_NOTIFY_RELAY_DIR_REL"
  else
    return 1
  fi
}

# relay_token_generate — prints a base64url token (no newline) from the OS random source.
relay_token_generate() {
  head -c "$RELAY_TOKEN_RANDOM_BYTES" /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
}

# relay_token_sha256_stdin — sha256 hex of stdin.
relay_token_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# relay_token_store <dir> <file_name> <token> — 0 stored / 2 file exists / 4 other failure. Never overwrites.
relay_token_store() {
  local dir=$1 target
  mkdir -p "$dir" && chmod 700 "$dir" || return 4
  target="$dir/$2"
  [ -e "$target" ] && return 2
  # noclobber makes the redirect fail if the file appeared meanwhile.
  if ( set -o noclobber; printf '%s\n' "$3" >"$target" ) 2>/dev/null; then
    chmod 600 "$target" || return 4
    return 0
  fi
  [ -e "$target" ] && return 2
  return 4
}

# relay_token_print_entry <sender> <sha256> — the one JSON line.
relay_token_print_entry() {
  jq -cn --arg sha "$2" --arg sender "$1" '{($sha): {sender: $sender, routes: ["put"]}}'
}

relay_token_main() {
  local sender dir token sha file_name rc
  [ "$#" -eq 1 ] || return 1
  sender=$1
  relay_token_sender_is_known "$sender" || return 1
  dir="$(relay_token_resolve_dir)" || return 4
  token="$(relay_token_generate)"
  fyd_relay_token_is_valid "$token" || return 3
  file_name="$sender$RELAY_TOKEN_FILE_SUFFIX"
  relay_token_store "$dir" "$file_name" "$token"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  sha="$(printf '%s' "$token" | relay_token_sha256_stdin)"
  [ -n "$sha" ] || return 4
  relay_token_print_entry "$sender" "$sha" || return 4
  printf '%s\n' "$file_name" >&2
}

relay_token_main "$@"
exit $?
