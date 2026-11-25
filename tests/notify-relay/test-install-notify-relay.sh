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

# Fake chown/stat in front of PATH: a non-root test user cannot chown to 0.
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
REAL_STAT="$(command -v stat)"
CHOWN_LOG="$TMP_ROOT/chown.log"
cat > "$FAKEBIN/chown" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$CHOWN_LOG"
[ -z "${CHOWN_FAIL:-}" ]
FAKE
cat > "$FAKEBIN/stat" <<FAKE
#!/usr/bin/env bash
if [ -n "\${STAT_GID0:-}" ] && [ "\${2:-}" = '%u %g' ]; then echo "0 0"; exit 0; fi
if [ -n "\${TOPIC_GID_FAKE:-}" ] && [ "\${2:-}" = '%u %g' ] && [ "\${@: -1}" = "\${NTFY_TOPIC_FILE:-}" ]; then echo "0 \$TOPIC_GID_FAKE"; exit 0; fi
exec "$REAL_STAT" "\$@"
FAKE
chmod +x "$FAKEBIN/chown" "$FAKEBIN/stat"
export CHOWN_LOG PATH="$FAKEBIN:$PATH"
TOPIC_FILE="$SECRET_PARENT/ntfy-topic"
# <G>: a supplementary group of the runner that is neither the primary group, 0, nor a group of user nobody,
# so reading <G> from anywhere but the topic file changes the results. No such group -> every group scene FAILs.
RUN_GID="$(id -g)"
GID_G=''
for g in $(id -G); do
  [ "$g" != "$RUN_GID" ] && [ "$g" != 0 ] || continue
  case " $(id -G nobody 2>/dev/null) " in *" $g "*) continue ;; esac
  GID_G="$g"; break
done
if [ -n "$GID_G" ]; then ok "0 fake topic group $GID_G differs from primary $RUN_GID"; else fail "0 no supplementary group usable as <G> (scenes below FAIL)"; GID_G=999999; fi
export TOPIC_GID_FAKE="$GID_G"
fresh_secret_parent() { rm -rf "${SECRET_PARENT:?}"; mkdir -p "$SECRET_PARENT"; : > "$TOPIC_FILE"; : > "$CHOWN_LOG"; }

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
rm -rf "${BACKUP:?}"; fresh_secret_parent
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
eq "6 dry-run never calls chown" 0 "$(wc -l < "$CHOWN_LOG" | tr -d ' ')"
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
fresh_secret_parent
RDIR="$SECRET_PARENT/notify-relay"
run_in "$TOKEN
$URL
" --install-secrets
eq "7 rc" 0 "$RC"
eq "7 dir mode" 750 "$(stat -c '%a' "$RDIR" 2>/dev/null || stat -f '%Lp' "$RDIR")"
eq "7 token mode" 640 "$(stat -c '%a' "$RDIR/token" 2>/dev/null || stat -f '%Lp' "$RDIR/token")"
eq "7 url mode" 640 "$(stat -c '%a' "$RDIR/url" 2>/dev/null || stat -f '%Lp' "$RDIR/url")"
eq "7 token content" "$TOKEN" "$(cat "$RDIR/token")"
eq "7 token ends with one newline" 44 "$(wc -c < "$RDIR/token" | tr -d ' ')"
eq "7 url content" "$URL" "$(cat "$RDIR/url")"
eq "7 no stray temp files" 2 "$(find "$RDIR" -mindepth 1 | wc -l | tr -d ' ')"
eq "7 chown called 3 times" 3 "$(wc -l < "$CHOWN_LOG" | tr -d ' ')"
eq "7 chown always 0:G" 3 "$(grep -c "^0:${GID_G} " "$CHOWN_LOG")"
chk "7 chown on the dir" grep -qxF "0:${GID_G} ${RDIR}" "$CHOWN_LOG"
chk "7 stderr empty" [ ! -s "$ERR" ]
if grep -qF -e "$TOKEN" -e "relay.example.invalid" "$OUT" "$ERR"; then fail "7 output leaks a secret"; else ok "7 output has no token or URL"; fi
eq "7 output words" "installed: token (640)" "$(sed -n 1p "$OUT")"
# overwrite replaces
TOKEN2="$(LC_ALL=C tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 43)"
run_in "$TOKEN2
$URL
" --install-secrets
eq "7 overwrite content" "$TOKEN2" "$(cat "$RDIR/token")"
# bad inputs: exit 4, nothing written
bad_case() { # name stdin
  fresh_secret_parent
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

# re-run over an old 700/600 install: modes are repaired
fresh_secret_parent; mkdir -p "$RDIR"; chmod 700 "$RDIR"; echo old > "$RDIR/token"; echo old > "$RDIR/url"; chmod 600 "$RDIR/token" "$RDIR/url"
run_in "$TOKEN
$URL
" --install-secrets
eq "7b old dir repaired rc" 0 "$RC"
eq "7b old dir mode" 750 "$(stat -c '%a' "$RDIR" 2>/dev/null || stat -f '%Lp' "$RDIR")"
eq "7b old token mode" 640 "$(stat -c '%a' "$RDIR/token" 2>/dev/null || stat -f '%Lp' "$RDIR/token")"
eq "7b old url mode" 640 "$(stat -c '%a' "$RDIR/url" 2>/dev/null || stat -f '%Lp' "$RDIR/url")"
eq "7b old dir chown'd" 1 "$(grep -cxF "0:${GID_G} ${RDIR}" "$CHOWN_LOG")"
# topic file missing -> exit 5, nothing written
fresh_secret_parent; rm -f "$TOPIC_FILE"
run_in "$TOKEN
$URL
" --install-secrets
eq "7c no topic file rc" 5 "$RC"
chk "7c wrote nothing" [ ! -e "$RDIR" ]
eq "7c one fixed stderr line" "ERROR: topic file group unusable" "$(cat "$ERR")"
# group 0 -> exit 5, nothing written, no chown
fresh_secret_parent
STAT_GID0=1 run_in "$TOKEN
$URL
" --install-secrets
eq "7d group 0 rc" 5 "$RC"
chk "7d wrote nothing" [ ! -e "$RDIR" ]
eq "7d no chown" 0 "$(wc -l < "$CHOWN_LOG" | tr -d ' ')"
# group 0 also stops a dry run
STAT_GID0=1 run_in "$TOKEN
$URL
" --install-secrets --dry-run
eq "7d dry group 0 rc" 5 "$RC"
# chown fails -> exit 3, nothing left
fresh_secret_parent
CHOWN_FAIL=1 run_in "$TOKEN
$URL
" --install-secrets
eq "7e chown fail rc" 3 "$RC"
chk "7e nothing left (new dir)" [ ! -e "$RDIR" ]
fresh_secret_parent; mkdir -p "$RDIR"
CHOWN_FAIL=1 run_in "$TOKEN
$URL
" --install-secrets
eq "7e chown fail rc (existing dir)" 3 "$RC"
eq "7e no stray files (existing dir)" 0 "$(find "$RDIR" -mindepth 1 | wc -l | tr -d ' ')"
if grep -qF -e "$TOKEN" "$OUT" "$ERR"; then fail "7e leaks"; else ok "7e no leak"; fi

# --- 8 uninstall
fresh_secret_parent
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

# --- 11 enable-cron: a cron user is eligible only when root or in the topic file group
ME="$(id -un)"
fresh_secret_parent
reset_cron
printf '%s*/5 * * * * root /srv/a.sh\n*/5 * * * * %s /srv/a.sh\n' "$HDR" "$ME" > "$CRON/metal-grp"
printf '%s*/5 * * * * nobody /srv/a.sh\n' "$HDR" > "$CRON/metal-nobody"
printf '%s*/5 * * * * no_such_user_zz /srv/a.sh\n' "$HDR" > "$CRON/metal-nouser"
printf '%s*/5 * * * * root /srv/a.sh\n' "$HDR" > "$CRON/metal-root"
printf '%s*/5 * * * * root /srv/a.sh\n*/5 * * * * nobody /srv/a.sh\n' "$HDR" > "$CRON/metal-mixed"
snap
run --enable-cron
eq "11 rc" 0 "$RC"
eq "11 group member + root: added" 1 "$(count_lines "$CRON/metal-grp")"
chk "11 root only: added" grep -qxF "added:   metal-root" "$OUT"
chk "11 nobody: non_root_user" grep -qxF "excluded: metal-nobody (non_root_user)" "$OUT"
chk "11 missing user: non_root_user" grep -qxF "excluded: metal-nouser (non_root_user)" "$OUT"
chk "11 one outsider line excludes the file" grep -qxF "excluded: metal-mixed (non_root_user)" "$OUT"
same "11 nobody bytes same" "$TMP_ROOT/snap/metal-nobody" "$CRON/metal-nobody"
same "11 mixed bytes same" "$TMP_ROOT/snap/metal-mixed" "$CRON/metal-mixed"
# group unreadable (no topic file) or 0: root-only files only
for mode in nofile gid0; do
  fresh_secret_parent; [ "$mode" = nofile ] && rm -f "$TOPIC_FILE"
  rm -rf "${BACKUP:?}"; cp -p "$TMP_ROOT/snap"/* "$CRON/"
  if [ "$mode" = gid0 ]; then STAT_GID0=1 run --enable-cron; else run --enable-cron; fi
  chk "11 $mode: member file excluded" grep -qxF "excluded: metal-grp (non_root_user)" "$OUT"
  chk "11 $mode: root-only file added" grep -qxF "added:   metal-root" "$OUT"
done

# --- 12 own NTFY_TOPIC_FILE line: not excluded when it is exactly the default topic file
DEF="$(. "$REPO_ROOT/scripts/lib/notify-text.sh" >/dev/null 2>&1; printf '%s' "$FYD_NTFY_TOPIC_FILE_DEFAULT")"
chk "12 default constant read from the lib" [ -n "$DEF" ]
fresh_secret_parent
reset_cron
printf 'NTFY_TOPIC_FILE=%s\n%s\n' "$DEF" "$HC" > "$CRON/metal-t-same"
printf 'NTFY_TOPIC_FILE = %s \n%s\n' "$DEF" "$HC" > "$CRON/metal-t-space"
printf "NTFY_TOPIC_FILE='%s'\n%s\n" "$DEF" "$HC" > "$CRON/metal-t-sq"
printf 'NTFY_TOPIC_FILE="%s"\n%s\n' "$DEF" "$HC" > "$CRON/metal-t-dq"
printf 'NTFY_TOPIC_FILE=/etc/freedom-yield/other-topic\n%s\n' "$HC" > "$CRON/metal-t-other"
printf 'NTFY_TOPIC_FILE=\n%s\n' "$HC" > "$CRON/metal-t-empty"
printf 'NTFY_TOPIC_FILE=%s\nNTFY_TOPIC_FILE=%s\n%s\n' "$DEF" "$DEF" "$HC" > "$CRON/metal-t-two"
# shellcheck disable=SC2016 # the literal $ is the point of this case
printf 'NTFY_TOPIC_FILE=$X/ntfy-topic\n%s\n' "$HC" > "$CRON/metal-t-var"
printf 'NTFY_TOPIC_FILE=~/ntfy-topic\n%s\n' "$HC" > "$CRON/metal-t-tilde"
printf 'NTFY_TOPIC_FILE="%s\n%s\n' "$DEF" "$HC" > "$CRON/metal-t-halfq"
printf 'NTFY_TOPIC_FILE=%sx\n%s\n' "$DEF" "$HC" > "$CRON/metal-t-longer"
printf 'NTFY_TOPIC_FILE=%s\n%s\n*/5 * * * * nobody /srv/b.sh\n' "$DEF" "$HC" > "$CRON/metal-t-nonroot"
snap
run --enable-cron
eq "12 rc" 0 "$RC"
for n in metal-t-same metal-t-space metal-t-sq metal-t-dq; do
  chk "12 $n added" grep -qxF "added:   $n" "$OUT"
  eq "12 $n has one relay line" 1 "$(count_lines "$CRON/$n")"
  eq "12 $n line is just before the command" "$HC" "$(grep -xF -A1 "$LINE" "$CRON/$n" | tail -n 1)"
  chk "12 $n env line kept" grep -qE '^NTFY_TOPIC_FILE' "$CRON/$n"
done
for n in metal-t-other metal-t-empty metal-t-two metal-t-var metal-t-tilde metal-t-halfq metal-t-longer; do
  chk "12 $n own_topic_file" grep -qxF "excluded: $n (own_topic_file)" "$OUT"
  same "12 $n bytes same" "$TMP_ROOT/snap/$n" "$CRON/$n"
done
chk "12 default value + outsider user: non_root_user" grep -qxF "excluded: metal-t-nonroot (non_root_user)" "$OUT"
same "12 nonroot bytes same" "$TMP_ROOT/snap/metal-t-nonroot" "$CRON/metal-t-nonroot"
run --disable-cron
for n in metal-t-same metal-t-space metal-t-sq metal-t-dq; do
  same "12 disable restores $n" "$TMP_ROOT/snap/$n" "$CRON/$n"
done

echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
