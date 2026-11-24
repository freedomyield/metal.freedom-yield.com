#!/usr/bin/env bash
# tests/notify-relay/test-install-notify-relay.sh — contract of scripts/install-notify-relay.sh (P3).
# CHAIN: none.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. Only temp dirs; never touches the real cron dir or /etc.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
INSTALLER="${INSTALL_NOTIFY_RELAY_OVERRIDE:-$REPO_ROOT/scripts/install-notify-relay.sh}"
LINE="FYD_NOTIFY=${REPO_ROOT}/scripts/notify-relay-put.sh"
URL='https://relay.example.invalid/notify-relay/put'

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected [$2] got [$3])"; fi; }
chk() { local name=$1; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
same() { if cmp -s "$2" "$3"; then ok "$1"; else fail "$1 (bytes differ)"; fi; }

TMP_ROOT="$(mktemp -d "$REPO_ROOT/.install-relay-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT:?}"' EXIT
export TMPDIR="$TMP_ROOT"
mkdir -p "$TMP_ROOT/t"

TOKEN="$(LC_ALL=C tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 43)"

CRON="$TMP_ROOT/cron"
BACKUP="$TMP_ROOT/backup"
SECRET_PARENT="$TMP_ROOT/etc"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

# run <args...> — the installer against the temp dirs; stdout in $OUT, stderr in $ERR, rc in $RC.
run() {
  FYD_CRON_DIR="$CRON" FYD_BACKUP_DIR="$BACKUP" NTFY_TOPIC_FILE="$SECRET_PARENT/ntfy-topic" \
    bash "$INSTALLER" "$@" > "$OUT" 2> "$ERR" < /dev/null
  RC=$?
}
run_in() { # stdin_text args...
  local text="$1"; shift
  printf '%s' "$text" | FYD_CRON_DIR="$CRON" FYD_BACKUP_DIR="$BACKUP" NTFY_TOPIC_FILE="$SECRET_PARENT/ntfy-topic" \
    bash "$INSTALLER" "$@" > "$OUT" 2> "$ERR"
  RC=$?
}

reset_cron() {
  rm -rf "${CRON:?}" "${BACKUP:?}"
  mkdir -p "$CRON"
}
snap() { mkdir -p "$TMP_ROOT/snap"; rm -rf "${TMP_ROOT:?}/snap"; mkdir -p "$TMP_ROOT/snap"; cp -p "$CRON"/* "$TMP_ROOT/snap/" 2>/dev/null || true; }

HDR=$'# header\nSHELL=/bin/bash\nPATH=/usr/bin:/bin\nFY_LIVE=1\n\n'
make_files() {
  reset_cron
  printf '%s*/5 * * * * root /srv/a.sh\n0 1 * * * root /srv/b.sh\n' "$HDR" > "$CRON/metal-a"
  printf '%s@reboot root /srv/c.sh\n' "$HDR" > "$CRON/freedom-yield-b"
  printf 'SHELL=/bin/bash\n*/5 * * * * root /srv/nonl.sh' > "$CRON/metal-nonl"
  printf '%s*/5 * * * * root /srv/x.sh\n' "$HDR" > "$CRON/other-project"
  printf '%s*/5 * * * * root /srv/x.sh\n' "$HDR" > "$CRON/metal-x.bak-20261124"
  printf '%s*/5 * * * * root /srv/x.sh\n' "$HDR" > "$CRON/freedom-yield-y.disabled"
}

count_lines() { grep -cxF "$LINE" "$1" || true; }

# --- 1 enable: one line before the first command line, other bytes the same, backup exists
make_files; snap
run --enable-cron
eq "1 enable rc" 0 "$RC"
for n in metal-a freedom-yield-b metal-nonl; do
  eq "1 $n has one line" 1 "$(count_lines "$CRON/$n")"
  grep -vxF "$LINE" "$CRON/$n" > "$TMP_ROOT/t/rest"
  # grep -v adds a final newline; compare against the snapshot modulo that
  if [ "$n" = metal-nonl ]; then printf '%s' "$(cat "$TMP_ROOT/t/rest")" > "$TMP_ROOT/t/rest"; fi
  same "1 $n other bytes same" "$TMP_ROOT/snap/$n" "$TMP_ROOT/t/rest"
  chk "1 $n backup exists" [ -f "$BACKUP/$n" ]
done
ln_line="$(grep -nxF "$LINE" "$CRON/metal-a" | cut -d: -f1)"
eq "1 line is just before the first command" "*/5 * * * * root /srv/a.sh" "$(sed -n "$((ln_line + 1))p" "$CRON/metal-a")"
ln_line="$(grep -nxF "$LINE" "$CRON/freedom-yield-b" | cut -d: -f1)"
eq "1 @reboot: line just before the command" "@reboot root /srv/c.sh" "$(sed -n "$((ln_line + 1))p" "$CRON/freedom-yield-b")"
eq "1 summary line" "summary: added 3, ok 0, excluded 0, skipped (not cron-executed) 2" "$(grep '^summary:' "$OUT")"

# --- 2 idempotent
snap; rm -rf "${BACKUP:?}"
run --enable-cron
eq "2 second rc" 0 "$RC"
eq "2 ok words" 3 "$(grep -c '^ok:' "$OUT")"
eq "2 still one line" 1 "$(count_lines "$CRON/metal-a")"
chk "2 no backup taken" [ ! -e "$BACKUP" ]
same "2 file unchanged" "$TMP_ROOT/snap/metal-a" "$CRON/metal-a"

# --- 3 disable restores the bytes (incl. no trailing newline, @reboot, header lines)
make_files; snap
run --enable-cron; run --disable-cron
eq "3 disable rc" 0 "$RC"
for n in metal-a freedom-yield-b metal-nonl other-project; do
  same "3 $n restored" "$TMP_ROOT/snap/$n" "$CRON/$n"
done
run --disable-cron
eq "3 second disable: nothing removed" 0 "$(grep -c '^removed:' "$OUT")"

# --- 4 exclusion rules: bytes unchanged and the word is printed
reset_cron
HC='*/5 * * * * root /srv/a.sh'
printf 'ANCHOR_NOTIFY=/x/y.sh\n%s\n' "$HC" > "$CRON/metal-d1"
printf 'WATCH_NOTIFY=/x/y.sh\n%s\n' "$HC" > "$CRON/metal-d2"
printf 'NOTIFY=/x/y.sh\n%s\n' "$HC" > "$CRON/metal-d3"
printf 'FYD_NOTIFY=/other/place.sh\n%s\n' "$HC" > "$CRON/metal-d4"
printf 'NTFY_TOPIC_FILE=/x/topic\n%s\n' "$HC" > "$CRON/metal-topic"
printf '%s\n*/5 * * * * www-data /srv/b.sh\n' "$HC" > "$CRON/metal-user"
printf '@reboot www-data /srv/b.sh\n' > "$CRON/metal-user2"
printf '# only comments\nSHELL=/bin/bash\n' > "$CRON/metal-nocmd"
printf 'NOTIFY = /x\n%s\n' "$HC" > "$CRON/metal-sp1"
printf '  FYD_NOTIFY=/other/place.sh\n%s\n' "$HC" > "$CRON/metal-sp2"
printf '  NTFY_TOPIC_FILE =/y\n%s\n' "$HC" > "$CRON/metal-sp3"
printf 'ntfy_topic_file = /z\nSHELL = /bin/bash\n%s\n' "$HC" > "$CRON/metal-lower"
snap
run --enable-cron
eq "4 rc" 0 "$RC"
for n in metal-d1 metal-d2 metal-d3 metal-d4 metal-topic metal-user metal-user2 metal-nocmd metal-sp1 metal-sp2 metal-sp3; do
  same "4 $n bytes same" "$TMP_ROOT/snap/$n" "$CRON/$n"
done
for pair in metal-d1:other_delegate metal-d2:other_delegate metal-d3:other_delegate metal-d4:other_delegate \
            metal-topic:own_topic_file metal-user:non_root_user metal-user2:non_root_user metal-nocmd:no_commands metal-sp1:other_delegate metal-sp2:other_delegate metal-sp3:own_topic_file; do
  chk "4 word ${pair}" grep -qxF "excluded: ${pair%%:*} (${pair#*:})" "$OUT"
done
eq "4 lowercase name is no alias: relay line added" 1 "$(count_lines "$CRON/metal-lower")"
eq "4 lowercase: line is just before the command" "$HC" "$(grep -xF -A1 "$LINE" "$CRON/metal-lower" | tail -n 1)"
# disable must remove only the relay line, never another delegate's line
printf '%s\nANCHOR_NOTIFY=/x/y.sh\nWATCH_NOTIFY=/x/y.sh\nNOTIFY=/x/y.sh\nFYD_NOTIFY=/other/place.sh\n%s\n' "$LINE" "$HC" > "$CRON/metal-mix"
snap
run --disable-cron
eq "4 mix: other delegate lines kept" 4 "$(grep -cE '^(ANCHOR_NOTIFY|WATCH_NOTIFY|NOTIFY|FYD_NOTIFY)=' "$CRON/metal-mix")"
eq "4 mix: relay line gone" 0 "$(count_lines "$CRON/metal-mix")"
same "4 d4 untouched by disable" "$TMP_ROOT/snap/metal-d4" "$CRON/metal-d4"

# --- 5 out of scope files untouched (also in the 1 case above: names that cron would not run)
make_files; snap
run --enable-cron
same "5 other-project untouched" "$TMP_ROOT/snap/other-project" "$CRON/other-project"
same "5 .bak untouched" "$TMP_ROOT/snap/metal-x.bak-20261124" "$CRON/metal-x.bak-20261124"
same "5 .disabled untouched" "$TMP_ROOT/snap/freedom-yield-y.disabled" "$CRON/freedom-yield-y.disabled"
chk "5 skipped word" grep -q '^skipped (not a cron-executed filename): metal-x.bak-20261124$' "$OUT"

# --- 6 dry-run writes nothing
make_files; snap
rm -rf "${BACKUP:?}" "${SECRET_PARENT:?}"; mkdir -p "$SECRET_PARENT"
stamp="$TMP_ROOT/stamp"; : > "$stamp"; sleep 1
before="$(find "$TMP_ROOT" -not -path "$TMP_ROOT/out" -not -path "$TMP_ROOT/err" | sort | wc -l)"
run --enable-cron --dry-run
eq "6 enable dry rc" 0 "$RC"
chk "6 dry summary word" grep -q '^DRY-RUN summary:' "$OUT"
run --disable-cron --dry-run
run_in "$TOKEN
$URL
" --install-secrets --dry-run
eq "6 install dry rc" 0 "$RC"
run --uninstall-secrets --dry-run
after="$(find "$TMP_ROOT" -not -path "$TMP_ROOT/out" -not -path "$TMP_ROOT/err" | sort | wc -l)"
eq "6 no new paths" "$before" "$after"
eq "6 nothing newer than the stamp in cron/backup/secret dirs" 0 \
  "$(find "$CRON" "$SECRET_PARENT" -newer "$stamp" 2>/dev/null | wc -l | tr -d ' ')"
chk "6 no backup dir" [ ! -e "$BACKUP" ]
same "6 cron unchanged" "$TMP_ROOT/snap/metal-a" "$CRON/metal-a"
# disable dry-run with a line present must not write a copy either
printf '%s\n%s\n' "$LINE" "$HC" > "$CRON/metal-line"
run --disable-cron --dry-run
chk "6 disable dry: no backup dir" [ ! -e "$BACKUP" ]
eq "6 disable dry: line still there" 1 "$(count_lines "$CRON/metal-line")"

# --- 7 install-secrets
rm -rf "${SECRET_PARENT:?}"; mkdir -p "$SECRET_PARENT"
RDIR="$SECRET_PARENT/notify-relay"
run_in "$TOKEN
$URL
" --install-secrets
eq "7 rc" 0 "$RC"
eq "7 dir mode" 700 "$(stat -c '%a' "$RDIR" 2>/dev/null || stat -f '%Lp' "$RDIR")"
eq "7 token mode" 600 "$(stat -c '%a' "$RDIR/token" 2>/dev/null || stat -f '%Lp' "$RDIR/token")"
eq "7 url mode" 600 "$(stat -c '%a' "$RDIR/url" 2>/dev/null || stat -f '%Lp' "$RDIR/url")"
eq "7 token content" "$TOKEN" "$(cat "$RDIR/token")"
eq "7 token ends with one newline" 44 "$(wc -c < "$RDIR/token" | tr -d ' ')"
eq "7 url content" "$URL" "$(cat "$RDIR/url")"
eq "7 no stray temp files" 2 "$(find "$RDIR" -mindepth 1 | wc -l | tr -d ' ')"
if grep -qF -e "$TOKEN" -e "relay.example.invalid" "$OUT" "$ERR"; then fail "7 output leaks a secret"; else ok "7 output has no token or URL"; fi
eq "7 output words" "installed: token (600)" "$(sed -n 1p "$OUT")"
# overwrite replaces
TOKEN2="$(LC_ALL=C tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 43)"
run_in "$TOKEN2
$URL
" --install-secrets
eq "7 overwrite content" "$TOKEN2" "$(cat "$RDIR/token")"
# bad inputs: exit 4, nothing written
bad_case() { # name stdin
  rm -rf "${SECRET_PARENT:?}"; mkdir -p "$SECRET_PARENT"
  run_in "$2" --install-secrets
  eq "7 $1 rc" 4 "$RC"
  chk "7 $1 wrote nothing" [ ! -e "$RDIR" ]
  if grep -qF -e "$TOKEN" -e "relay.example.invalid" -e "evil.example" "$OUT" "$ERR"; then fail "7 $1 leaks"; else ok "7 $1 no leak"; fi
}
bad_case "short token" "abc
$URL
"
bad_case "http other host" "$TOKEN
http://evil.example/notify-relay/put
"
bad_case "three lines" "$TOKEN
$URL
extra
"
bad_case "only one line" "$TOKEN
"
bad_case "empty stdin" ""
bad_case "blank third line" "$TOKEN
$URL

"

# --- 8 uninstall
run_in "$TOKEN
$URL
" --install-secrets
run --uninstall-secrets
eq "8 rc" 0 "$RC"
chk "8 dir gone" [ ! -e "$RDIR" ]
run --uninstall-secrets
eq "8 second rc" 0 "$RC"
chk "8 absent word" grep -q '^absent: token$' "$OUT"

# --- 9 usage errors
run; eq "9 no mode" 1 "$RC"
run --enable-cron --disable-cron; eq "9 two modes" 1 "$RC"
run --enable-cron --enable-cron; eq "9 same mode twice" 1 "$RC"
run --dry-run; eq "9 only dry-run" 1 "$RC"
run --bogus; eq "9 unknown arg" 1 "$RC"
run --enable-cron extra; eq "9 extra arg" 1 "$RC"

# --- 10 root requirement (not pointed at temp dirs)
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP - 10 root requirement (running as root)"
else
  env -u FYD_CRON_DIR -u NTFY_TOPIC_FILE bash "$INSTALLER" --enable-cron > "$OUT" 2> "$ERR" < /dev/null; eq "10 enable as non-root" 2 "$?"
  env -u FYD_CRON_DIR -u NTFY_TOPIC_FILE bash "$INSTALLER" --disable-cron --dry-run > "$OUT" 2> "$ERR" < /dev/null; eq "10 disable dry as non-root" 2 "$?"
  printf '%s\n%s\n' "$TOKEN" "$URL" | env -u FYD_CRON_DIR -u NTFY_TOPIC_FILE bash "$INSTALLER" --install-secrets > "$OUT" 2> "$ERR"; eq "10 install as non-root" 2 "$?"
  env -u FYD_CRON_DIR -u NTFY_TOPIC_FILE bash "$INSTALLER" --uninstall-secrets > "$OUT" 2> "$ERR" < /dev/null; eq "10 uninstall as non-root" 2 "$?"
  # empty (not unset) values do not waive root
  FYD_CRON_DIR='' NTFY_TOPIC_FILE='' bash "$INSTALLER" --enable-cron > "$OUT" 2> "$ERR" < /dev/null; eq "10 empty FYD_CRON_DIR" 2 "$?"
  FYD_CRON_DIR='' NTFY_TOPIC_FILE='' bash "$INSTALLER" --uninstall-secrets > "$OUT" 2> "$ERR" < /dev/null; eq "10 empty NTFY_TOPIC_FILE" 2 "$?"
fi

echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
