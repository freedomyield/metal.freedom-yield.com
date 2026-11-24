# shellcheck shell=bash
# tests/notify-relay/lib-fakes.sh — fixture parts for the relay put tests (sourced, not executed).
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. Everything lives in one temp dir; no network.
#
# relay_fake_setup <parent_dir> [p1_path] builds a fake host:
#   $FAKE_DIR/scripts/{notify-relay-put.sh, lib/notify-text.sh, notify.sh(fake)}
#   $FAKE_DIR/bin/{curl,logger}(fakes)   $FAKE_TOOLS(+_NOJQ): symlinks to the few real tools P1 needs
#   $FAKE_DIR/etc/{ntfy-topic, notify-relay/{token,url}}   $FAKE_DIR/rec/  (what the fakes recorded)
# Fakes read: FAKE_REC, FAKE_CURL_CODE(204) FAKE_CURL_RC(0) FAKE_NOTIFY_RC(0) FAKE_LOGGER_RC(0).

FAKE_TOOL_NAMES='bash cat find wc dirname env tr'

# relay_fake_random_token — 43 chars of [A-Za-z0-9_-] from /dev/urandom.
relay_fake_random_token() {
  LC_ALL=C tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 43
}

relay_fake_link_tools() { # <dir> <with_jq 0|1>
  local tool_dir="$1" with_jq="$2" tool tool_path
  mkdir -p "$tool_dir"
  for tool in $FAKE_TOOL_NAMES; do
    tool_path="$(command -v "$tool")"
    ln -s "$tool_path" "$tool_dir/$tool"
  done
  if [ "$with_jq" = 1 ]; then ln -s "$(command -v jq)" "$tool_dir/jq"; fi
}

relay_fake_write_curl() {
  cat > "$FAKE_BIN/curl" <<'FAKE'
#!/bin/bash
rec="$FAKE_REC"
echo x >> "$rec/curl.count"
printf '%s\n' "$@" > "$rec/curl.argv"
prev=''
for arg in "$@"; do
  if [ "$prev" = "-K" ]; then cat "$arg" > "$rec/curl.config"; fi
  prev="$arg"
done
cat > "$rec/curl.stdin"
env > "$rec/curl.env"
printf '%s' "${FAKE_CURL_CODE-204}"
exit "${FAKE_CURL_RC:-0}"
FAKE
  chmod +x "$FAKE_BIN/curl"
}

relay_fake_write_logger() {
  cat > "$FAKE_BIN/logger" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_REC/logger.log"
exit "${FAKE_LOGGER_RC:-0}"
FAKE
  chmod +x "$FAKE_BIN/logger"
}

relay_fake_write_notify() {
  cat > "$FAKE_DIR/scripts/notify.sh" <<'FAKE'
#!/bin/bash
rec="$FAKE_REC"
echo x >> "$rec/notify.count"
if [ "$#" -eq 0 ]; then : > "$rec/notify.argv"; else printf '%s\0' "$@" > "$rec/notify.argv"; fi
: > "$rec/notify.env"
for name in NTFY_TAGS NOTIFY_STRICT_EXIT NTFY_TOPIC_FILE NOTIFY_UPTIME_SUFFIX; do
  if [ -n "${!name+x}" ]; then
    printf '%s=set:%s\n' "$name" "${!name}" >> "$rec/notify.env"
  else
    printf '%s=unset\n' "$name" >> "$rec/notify.env"
  fi
done
exit "${FAKE_NOTIFY_RC:-0}"
FAKE
  chmod +x "$FAKE_DIR/scripts/notify.sh"
}

# relay_fake_setup <parent> [p1_path]
relay_fake_setup() {
  local parent="$1" p1_src="${2:-$REPO_ROOT/scripts/notify-relay-put.sh}"
  FAKE_DIR="$(mktemp -d "$parent/relay-fake.XXXXXX")"
  FAKE_BIN="$FAKE_DIR/bin"
  FAKE_TOOLS="$FAKE_DIR/tools"
  FAKE_TOOLS_NOJQ="$FAKE_DIR/tools-nojq"
  FAKE_REC="$FAKE_DIR/rec"
  FAKE_RELAY_DIR="$FAKE_DIR/etc/notify-relay"
  FAKE_TOPIC_FILE="$FAKE_DIR/etc/ntfy-topic"
  FAKE_P1="$FAKE_DIR/scripts/notify-relay-put.sh"
  mkdir -p "$FAKE_DIR/scripts/lib" "$FAKE_BIN" "$FAKE_REC" "$FAKE_RELAY_DIR"
  chmod 700 "$FAKE_DIR/etc" "$FAKE_RELAY_DIR"
  cp "$p1_src" "$FAKE_P1"
  chmod 755 "$FAKE_P1"
  cp "$REPO_ROOT/scripts/lib/notify-text.sh" "$FAKE_DIR/scripts/lib/notify-text.sh"
  relay_fake_write_curl
  relay_fake_write_logger
  relay_fake_write_notify
  relay_fake_link_tools "$FAKE_TOOLS" 1
  relay_fake_link_tools "$FAKE_TOOLS_NOJQ" 0
  FAKE_TOKEN="$(relay_fake_random_token)"
  FAKE_URL="http://127.0.0.1:$((20000 + RANDOM % 20000))/notify-relay/put"
  printf '%s\n' 'fake-topic' > "$FAKE_TOPIC_FILE"
  relay_fake_write_secrets
}

# relay_fake_write_secrets — valid token and url files, 600 (also the reset after a broken case).
relay_fake_write_secrets() {
  printf '%s\n' "$FAKE_TOKEN" > "$FAKE_RELAY_DIR/token"
  printf '%s\n' "$FAKE_URL" > "$FAKE_RELAY_DIR/url"
  chmod 600 "$FAKE_RELAY_DIR/token" "$FAKE_RELAY_DIR/url"
}

# relay_fake_path <default|nojq|nocurl> — PATH value for running P1.
relay_fake_path() {
  case "$1" in
    nojq) printf '%s' "$FAKE_BIN:$FAKE_TOOLS_NOJQ" ;;
    nocurl) printf '%s' "$FAKE_TOOLS" ;;
    *) printf '%s' "$FAKE_BIN:$FAKE_TOOLS" ;;
  esac
}

# relay_fake_reset_rec — forget what the fakes recorded.
relay_fake_reset_rec() {
  rm -f "$FAKE_REC"/*
}

# relay_fake_cleanup — remove the fake host (re-opens a chmod 000 dir first).
relay_fake_cleanup() {
  [ -n "${FAKE_DIR:-}" ] || return 0
  chmod -R u+rwx "$FAKE_DIR" 2>/dev/null || true
  rm -rf "$FAKE_DIR"
  FAKE_DIR=''
}
