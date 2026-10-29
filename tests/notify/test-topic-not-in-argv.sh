#!/usr/bin/env bash
# tests/notify/test-topic-not-in-argv.sh
#
# scripts/notify.sh must never put the ntfy topic (a bearer secret) in curl's
# argv: on a shared host argv is readable by every local user through
# /proc/<pid>/cmdline or ps. The topic must still reach curl, through the
# -K config on an anonymous pipe, as exactly the URL the old argv form used.
#
# A recording stub curl on PATH logs its argv and the contents of the -K
# config it was handed. Real ntfy.sh is never contacted. The fake topic is
# assembled at run time from /dev/urandom, so this file holds no topic-shaped
# literal. Both modes are covered (default and NOTIFY_STRICT_EXIT=1), plus a
# topic containing `"` and `\` to prove the config escaping round-trips.
#
# Mutation proof (G9, recorded in the final-fix report): putting the URL back
# into argv makes the "argv" cases FAIL; dropping the escaping makes the
# escaping case FAIL.
#
# CHAIN: none. PRIME_DIRECTIVE: safe (no network, no broadcast).

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
NOTIFY="${NOTIFY_UNDER_TEST:-$REPO/scripts/notify.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

TOPIC="faketopic-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$TOPIC" > "$TMP/topic"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Recording stub: argv (NUL-free, one line) and every -K/--config file body.
printf '%s\n' "$*" >> "$STUB_ARGV_LOG"
prev=""
for a in "$@"; do
	if [ "$prev" = -K ] || [ "$prev" = --config ]; then cat -- "$a" >> "$STUB_CFG_LOG"; fi
	prev="$a"
done
case " $* " in *" -w %{http_code} "*) printf '200' ;; *) printf 'ntfy POST: 200\n' ;; esac
exit 0
STUB
chmod +x "$TMP/bin/curl"

run_notify() { # strict(0|1) topicfile -> RC
	: > "$TMP/argv.log"; : > "$TMP/cfg.log"
	env PATH="$TMP/bin:$PATH" NTFY_TOPIC_FILE="$2" NOTIFY_STRICT_EXIT="$1" \
		STUB_ARGV_LOG="$TMP/argv.log" STUB_CFG_LOG="$TMP/cfg.log" \
		bash "$NOTIFY" urgent "title" "body" >/dev/null 2>&1
	RC=$?
}

for strict in 0 1; do
	label="mode strict=$strict"
	run_notify "$strict" "$TMP/topic"
	if [ "$RC" -eq 0 ]; then ok "$label: exit 0"; else bad "$label: exit 0 (rc=$RC)"; fi
	if [ -s "$TMP/argv.log" ]; then ok "$label: curl was called"; else bad "$label: curl was called"; fi
	if ! grep -qF "$TOPIC" "$TMP/argv.log"; then ok "$label: topic absent from curl argv"
	else bad "$label: topic absent from curl argv"; fi
	if ! grep -qF "ntfy.sh" "$TMP/argv.log"; then ok "$label: no ntfy URL in argv at all"
	else bad "$label: no ntfy URL in argv at all"; fi
	if [ "$(cat "$TMP/cfg.log")" = "url = \"https://ntfy.sh/$TOPIC\"" ]; then ok "$label: URL delivered via -K config"
	else bad "$label: URL delivered via -K config (got: $(wc -c < "$TMP/cfg.log") bytes)"; fi
	if grep -qF -- "-H Title: title" "$TMP/argv.log" && grep -qF -- "-d body" "$TMP/argv.log"; then
		ok "$label: headers and body still passed"
	else bad "$label: headers and body still passed"; fi
done

# A topic with curl-config metacharacters must reach curl unchanged.
printf 'odd"top\\ic\n' > "$TMP/odd"
run_notify 1 "$TMP/odd"
if [ "$(cat "$TMP/cfg.log")" = 'url = "https://ntfy.sh/odd\"top\\ic"' ]; then ok "config escapes \" and \\"
else bad "config escapes \" and \\ (got: $(cat "$TMP/cfg.log"))"; fi

echo
echo "test-topic-not-in-argv.sh: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
