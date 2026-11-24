#!/usr/bin/env bash
# tests/notify-relay/test-notify-text.sh — contract of scripts/lib/notify-text.sh (P2).
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No network: a fake curl records what notify.sh would send.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_PATH="${NOTIFY_TEXT_LIB_OVERRIDE:-$REPO_ROOT/scripts/lib/notify-text.sh}"
NOTIFY_SH_REL="scripts/notify.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected [$2] got [$3])"; fi
}
rc() { # name expected_rc cmd...
  local name=$1 want=$2; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail "$name (rc want $want got $got)"; fi
}

TMP_ROOT="$(mktemp -d "$REPO_ROOT/.notify-text-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

if [ ! -r "$LIB_PATH" ]; then
  echo "FAIL - lib missing: scripts/lib/notify-text.sh"
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi
unset NTFY_TOPIC_FILE NOTIFY_UPTIME_SUFFIX
# shellcheck source=/dev/null
. "$LIB_PATH"

NL=$'\n'
ROOT="$TMP_ROOT/root"
mkdir -p "$ROOT/public/api" "$ROOT/scripts"
write_uptime() { printf '{"uptime":{"network":%s}}\n' "$1" > "$ROOT/public/api/validator.json"; }

# --- priority
for p in urgent high default low min; do eq "normalize $p" "$p" "$(fyd_notify_normalize_priority "$p")"; done
for p in urgent2 "" HIGH; do eq "normalize [$p] -> default" default "$(fyd_notify_normalize_priority "$p")"; done
eq "word urgent" 緊急 "$(fyd_relay_priority_word urgent)"
eq "word high" 高 "$(fyd_relay_priority_word high)"
eq "word default" 通常 "$(fyd_relay_priority_word default)"
eq "word low" 低 "$(fyd_relay_priority_word low)"
eq "word min" 最低 "$(fyd_relay_priority_word min)"
eq "word bogus" 通常 "$(fyd_relay_priority_word bogus)"

# --- render
write_uptime 87.31
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"
eq "render with footer" "【高】題${NL}本文 1 本文 2${NL}${NL}[Uptime] 87.31%" "$FYD_RELAY_TEXT"
NOTIFY_UPTIME_SUFFIX=' (予定 87.40%)' fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"
eq "render with suffix" "【高】題${NL}本文 1 本文 2${NL}${NL}[Uptime] 87.31% (予定 87.40%)" "$FYD_RELAY_TEXT"
want_plain="【高】題${NL}本文 1 本文 2"
rm -f "$ROOT/public/api/validator.json"
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"; eq "no footer: file missing" "$want_plain" "$FYD_RELAY_TEXT"
write_uptime null
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"; eq "no footer: null" "$want_plain" "$FYD_RELAY_TEXT"
write_uptime '""'
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"; eq "no footer: empty" "$want_plain" "$FYD_RELAY_TEXT"
printf '{broken' > "$ROOT/public/api/validator.json"
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"; eq "no footer: broken json" "$want_plain" "$FYD_RELAY_TEXT"
rm -f "$ROOT/public/api/validator.json"
fyd_relay_render_text "$ROOT"; eq "zero args" "【通常】Freedom Yield ops${NL}(no message)" "$FYD_RELAY_TEXT"
fyd_relay_render_text "$ROOT" low ""  "x"; eq "empty title -> default" "【低】Freedom Yield ops${NL}x" "$FYD_RELAY_TEXT"
fyd_relay_render_text "$ROOT" low "T" $'行\n'; eq "trailing newline kept" "【低】T${NL}行${NL}" "$FYD_RELAY_TEXT"
printf -v want_nl '【低】T\n行\n'
eq "trailing newline literal" "$want_nl" "$FYD_RELAY_TEXT"

# --- dir
eq "relay_dir unset" /etc/freedom-yield/notify-relay "$(fyd_relay_dir)"
eq "relay_dir empty" /etc/freedom-yield/notify-relay "$(NTFY_TOPIC_FILE='' fyd_relay_dir)"
eq "relay_dir custom" "$TMP_ROOT/a/notify-relay" "$(NTFY_TOPIC_FILE="$TMP_ROOT/a/topic" fyd_relay_dir)"

# --- url
for u in https://relay.example.invalid/notify-relay/put https://relay.example.invalid:8443/notify-relay/put http://127.0.0.1:18080/notify-relay/put; do
  rc "url ok $u" 0 fyd_relay_url_is_valid "$u"
done
BACKSLASH_URL='https://relay.example.invalid/notify-relay/put'"\\"
for u in http://relay.example.invalid/notify-relay/put https://relay.example.invalid/notify-relay/put/x https://relay.example.invalid/other \
  "https://a b/notify-relay/put" 'https://relay.example.invalid/notify-relay/put"' $'https://relay.example.invalid/notify-relay/put\nhttps://relay.example.invalid/notify-relay/put' \
  $'https://relay.example.invalid/notify-relay/put\n' "$BACKSLASH_URL" ""; do
  rc "url bad [$(printf %s "$u" | tr '\n' '|')]" 1 fyd_relay_url_is_valid "$u"
done

# --- token
tok43="$(head -c 64 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' | cut -c1-43)"
rc "token 43 ok" 0 fyd_relay_token_is_valid "$tok43"
rc "token 42" 1 fyd_relay_token_is_valid "${tok43%?}"
rc "token 44" 1 fyd_relay_token_is_valid "${tok43}a"
rc "token plus" 1 fyd_relay_token_is_valid "+${tok43#?}"
rc "token slash" 1 fyd_relay_token_is_valid "/${tok43#?}"
rc "token empty" 1 fyd_relay_token_is_valid ""

# --- equality with the real scripts/notify.sh (design 13-8)
EQ="$TMP_ROOT/eq"
mkdir -p "$EQ/scripts" "$EQ/public/api" "$EQ/bin"
cp "$REPO_ROOT/$NOTIFY_SH_REL" "$EQ/scripts/notify.sh"
printf 'testtopic-not-real\n' > "$EQ/topic"
cat > "$EQ/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# fake curl: records -H and -d values; ignores -K.
out="${FAKE_CURL_OUT:?}"; : > "$out.h"; : > "$out.d"
while [ $# -gt 0 ]; do
  case "$1" in
    -H) printf '%s\n' "$2" >> "$out.h"; shift 2 ;;
    -d) printf '%s' "$2" > "$out.d"; shift 2 ;;
    *) shift ;;
  esac
done
printf '204'
FAKE
chmod 755 "$EQ/bin/curl"

check_equal() { # label then argv...
  local label=$1; shift
  local out="$EQ/out"
  rm -f "$out".h "$out".d
  PATH="$EQ/bin:$PATH" FAKE_CURL_OUT="$out" NTFY_TOPIC_FILE="$EQ/topic" bash "$EQ/scripts/notify.sh" "$@" >/dev/null 2>&1
  fyd_relay_render_text "$EQ" "$@"
  local first="${FYD_RELAY_TEXT%%$'\n'*}" rest="${FYD_RELAY_TEXT#*$'\n'}"
  local sent_body; sent_body="$(cat "$out.d"; printf x)"; sent_body="${sent_body%x}"
  local sent_title sent_prio
  sent_title="$(sed -n 's/^Title: //p' "$out.h")"
  sent_prio="$(sed -n 's/^Priority: //p' "$out.h")"
  eq "equal body: $label" "$rest" "$sent_body"
  eq "equal title: $label" "${first#*】}" "$sent_title"
  eq "equal prio: $label" "$(fyd_notify_normalize_priority "${1:-default}")" "$sent_prio"
}
write_eq() { printf '{"uptime":{"network":87.31}}\n' > "$EQ/public/api/validator.json"; }
write_eq
for p in urgent high default low min bogus; do check_equal "prio $p" "$p" "T $p" "body $p"; done
rm -f "$EQ/public/api/validator.json"
check_equal "no footer" high "T" "b"
write_eq
NOTIFY_UPTIME_SUFFIX=' (予定 87.40%)' check_equal "suffix" high "T" "b"
check_equal "no args"
check_equal "title only" high "題だけ"

# --- default path text equals notify.sh's
notify_default="$(sed -n 's/.*NTFY_TOPIC_FILE:-\([^}]*\)}.*/\1/p' "$REPO_ROOT/$NOTIFY_SH_REL" | head -1)"
eq "topic default path equals notify.sh" "$notify_default" "$FYD_NTFY_TOPIC_FILE_DEFAULT"

echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
