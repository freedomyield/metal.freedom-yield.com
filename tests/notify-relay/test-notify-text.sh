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
render_eq() { # name expected_title expected_body (checks FYD_RELAY_TITLE and FYD_RELAY_BODY)
  eq "$1: title" "$2" "$FYD_RELAY_TITLE"
  eq "$1: body" "$3" "$FYD_RELAY_BODY"
}
write_uptime 87.31
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"
render_eq "render with footer" "【高】題" "本文 1 本文 2${NL}${NL}[Uptime] 87.31%"
NOTIFY_UPTIME_SUFFIX=' (予定 87.40%)' fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"
render_eq "render with suffix" "【高】題" "本文 1 本文 2${NL}${NL}[Uptime] 87.31% (予定 87.40%)"
rm -f "$ROOT/public/api/validator.json"
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"; render_eq "no footer: file missing" "【高】題" "本文 1 本文 2"
write_uptime null
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"; render_eq "no footer: null" "【高】題" "本文 1 本文 2"
write_uptime '""'
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"; render_eq "no footer: empty" "【高】題" "本文 1 本文 2"
printf '{broken' > "$ROOT/public/api/validator.json"
fyd_relay_render_text "$ROOT" high "題" "本文 1" "本文 2"; render_eq "no footer: broken json" "【高】題" "本文 1 本文 2"
rm -f "$ROOT/public/api/validator.json"
fyd_relay_render_text "$ROOT" high; render_eq "one arg: body is the arg" "【高】Freedom Yield ops" "high"
fyd_relay_render_text "$ROOT"; render_eq "zero args" "【通常】Freedom Yield ops" "Freedom Yield ops"
fyd_relay_render_text "$ROOT" low "T"; render_eq "title only: body is the title" "【低】T" "T"
fyd_relay_render_text "$ROOT" low "T" ""; render_eq "empty body -> title" "【低】T" "T"
fyd_relay_render_text "$ROOT" low "T" "  "; render_eq "spaces-only body -> title" "【低】T" "T"
fyd_relay_render_text "$ROOT" low "T" $'\t\n'; render_eq "tab/newline-only body -> title" "【低】T" "T"
fyd_relay_render_text "$ROOT" low "  " "  "; render_eq "blank title and blank body -> default title body" "【低】  " "Freedom Yield ops"
fyd_relay_render_text "$ROOT" low ""; render_eq "empty title, no body -> default title twice" "【低】Freedom Yield ops" "Freedom Yield ops"
fyd_relay_render_text "$ROOT" low "T" " x "; render_eq "body with spaces and text kept" "【低】T" " x "
fyd_relay_render_text "$ROOT" low ""  "x"; render_eq "empty title -> default" "【低】Freedom Yield ops" "x"
fyd_relay_render_text "$ROOT" low "T" $'行\n'; render_eq "trailing newline kept" "【低】T" "行${NL}"
printf -v want_nl '行\n'
eq "trailing newline literal" "$want_nl" "$FYD_RELAY_BODY"
eq "FYD_RELAY_TEXT is gone" "" "${FYD_RELAY_TEXT:-}"

# --- dir
eq "relay_dir unset" /etc/freedom-yield/notify-relay "$(fyd_relay_dir)"
eq "relay_dir empty" /etc/freedom-yield/notify-relay "$(NTFY_TOPIC_FILE='' fyd_relay_dir)"
eq "topic_file unset" /etc/freedom-yield/ntfy-topic "$(fyd_relay_topic_file)"
eq "topic_file empty" /etc/freedom-yield/ntfy-topic "$(NTFY_TOPIC_FILE='' fyd_relay_topic_file)"
eq "topic_file custom" "$TMP_ROOT/a/topic" "$(NTFY_TOPIC_FILE="$TMP_ROOT/a/topic" fyd_relay_topic_file)"
: > "$TMP_ROOT/og"
og_real="$(stat -c '%u %g' "$TMP_ROOT/og" 2>/dev/null || stat -f '%u %g' "$TMP_ROOT/og")"
eq "owner_group of a real file" "$og_real" "$(fyd_relay_owner_group "$TMP_ROOT/og")"
eq "owner_group is two numbers" 1 "$([[ "$(fyd_relay_owner_group "$TMP_ROOT/og")" =~ ^[0-9]+\ [0-9]+$ ]] && echo 1 || echo 0)"
og_out="$(fyd_relay_owner_group "$TMP_ROOT/none")"; og_rc=$?
eq "owner_group missing: rc 1" 1 "$og_rc"
eq "owner_group missing: no output" "" "$og_out"
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
  local first="$FYD_RELAY_TITLE" rest="$FYD_RELAY_BODY"
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
check_equal "one arg" high

# Only difference from notify.sh: an empty/blank body. notify.sh sends "(no message)";
# (blank-only body: notify.sh sends the blanks as they are); the relay uses the title (notify no longer accepts an empty body). Title and priority still equal.
check_equal_except_body() { # label expected_notify_body expected_relay_body argv...
  local label=$1 want_notify=$2 want_body=$3; shift 3
  local out="$EQ/out"
  rm -f "$out".h "$out".d
  PATH="$EQ/bin:$PATH" FAKE_CURL_OUT="$out" NTFY_TOPIC_FILE="$EQ/topic" bash "$EQ/scripts/notify.sh" "$@" >/dev/null 2>&1
  fyd_relay_render_text "$EQ" "$@"
  local first="$FYD_RELAY_TITLE" rest="$FYD_RELAY_BODY"
  local sent_body; sent_body="$(cat "$out.d"; printf x)"; sent_body="${sent_body%x}"
  eq "differs from notify.sh: notify.sh body: $label" "${want_notify}${NL}${NL}[Uptime] 87.31%" "$sent_body"
  eq "differs from notify.sh: relay body is the title: $label" "${want_body}${NL}${NL}[Uptime] 87.31%" "$rest"
  eq "equal title (body differs): $label" "${first#*】}" "$(sed -n 's/^Title: //p' "$out.h")"
  eq "equal prio (body differs): $label" "$(fyd_notify_normalize_priority "${1:-default}")" "$(sed -n 's/^Priority: //p' "$out.h")"
}
check_equal_except_body "no args (relay: default title)" "(no message)" "Freedom Yield ops"
check_equal_except_body "title only (relay: title)" "(no message)" "題だけ" high "題だけ"
check_equal_except_body "blank body (relay: title)" "  " "T" high "T" "  "

# --- default path text equals notify.sh's
notify_default="$(sed -n 's/.*NTFY_TOPIC_FILE:-\([^}]*\)}.*/\1/p' "$REPO_ROOT/$NOTIFY_SH_REL" | head -1)"
eq "topic default path equals notify.sh" "$notify_default" "$FYD_NTFY_TOPIC_FILE_DEFAULT"

echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
