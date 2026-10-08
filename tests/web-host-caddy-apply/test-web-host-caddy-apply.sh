#!/usr/bin/env bash
# tests/web-host-caddy-apply/test-web-host-caddy-apply.sh
#
# scripts/web-host-caddy-apply.sh — the Mac-run, operator-approved path that
# brings a Caddyfile change to the web host's `caddy-static`.
#
# CHAIN: none — no network, no real SSH, no real docker. The remote half runs
# locally under SKIP_SSH=1 with `docker` and `curl` stubbed on PATH. The stub
# models the one docker behaviour that matters most: a single-file bind mount
# is pinned to the inode, so the container's view of the Caddyfile is a HARD
# LINK of the host file (a rename-style write leaves the container on the old
# bytes, exactly as on a real host). The real-mode ssh path is checked with a
# recording `ssh` stub that runs the remote command locally. Addresses are
# RFC5737. PRIME_DIRECTIVE: safe.
#
# What must never regress (each shown to fail under a mutation — see the
# commit message):
#   - plan (default) contacts nothing; --check writes nothing
#   - --apply refuses without an approved sha256 / with a different one
#   - a Caddyfile that fails `caddy validate` is never written
#   - scope guard: wrong compose project, wrong bind source, non-bind mount,
#     extra / different port binding, missing / stopped container, symlinked
#     host file -> refused, nothing changed, no reload
#   - the host file is overwritten in place (inode kept; container sees it)
#   - reload or health failure after the write -> automatic rollback (exit 1);
#     rollback itself failing -> exit 4
#   - every docker call targets caddy-static (or is the --rm --network none
#     validate run); no compose / build / stop / rm / prune ever
#   - the web host address never reaches the output
#
# Usage: tests/web-host-caddy-apply/test-web-host-caddy-apply.sh
# Exit:  0 all PASS / 1 any FAIL
#
# shellcheck disable=SC2016,SC2034,SC2012
# SC2016/SC2034: assertions are single-quoted strings eval'd by check(), so
# the variables they read look unused. SC2012: ls -i only on paths we made.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${SCRIPT_UNDER_TEST:-$REPO/scripts/web-host-caddy-apply.sh}"

T="$(mktemp -d -t web-caddy-apply-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
check() { # <name> <assertion>
	if eval "$2"; then PASS=$((PASS + 1)); echo "PASS: $1"
	else FAIL=$((FAIL + 1)); echo "FAIL: $1  [$2]"; fi
}

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
ino() { ls -i "$1" | awk '{print $1}'; }

# ---- stubs -----------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
F="$FAKE_DIR"
{ printf '%s' "$*" | tr '\n' ' '; echo; } >> "$F/docker.log"
case "${1:-}" in
inspect)
	[ "$2 $3 $4" = "--type container --format" ] || { echo "BADARGS inspect" >> "$F/docker.log"; exit 99; }
	[ "${6:-}" = caddy-static ] || exit 1
	[ ! -f "$F/no-container" ] || exit 1
	cat "$F/facts" ;;
exec)
	[ "${2:-}" = caddy-static ] || { echo "UNEXPECTED exec target ${2:-}" >> "$F/docker.log"; exit 99; }
	case "${3:-} ${4:-}" in
	"cat /etc/caddy/Caddyfile") cat "$F/view" ;;
	"caddy list-modules") echo http.handlers.file_server; [ -f "$F/no-rl" ] || echo http.handlers.rate_limit ;;
	"caddy reload")
		echo x >> "$F/reloads"
		# the real admin API listens on 127.0.0.1 only; "localhost" (the
		# caddy default) resolves to ::1 there and is refused
		case " $* " in *" --address 127.0.0.1:2019 "*) ;; *)
			echo "Error: dial tcp [::1]:2019: connect: connection refused" >&2; exit 1 ;; esac
		if [ -f "$F/reload-fail" ]; then
			[ "$(cat "$F/reload-fail")" = always ] || rm -f "$F/reload-fail"
			echo "Error: loading new config" >&2; exit 1
		fi
		cp "$F/view" "$F/live" ;;
	*) echo "UNEXPECTED exec $*" >> "$F/docker.log"; exit 99 ;;
	esac ;;
run)
	src=""
	while [ $# -gt 0 ]; do
		if [ "$1" = -v ]; then src="${2%%:*}"; fi
		shift
	done
	[ -n "$src" ] || exit 98
	if grep -q INVALID "$src"; then echo "Error: adapting config using caddyfile" >&2; exit 1; fi ;;
*) echo "UNEXPECTED docker $*" >> "$F/docker.log"; exit 99 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
F="$FAKE_DIR"
echo "$*" >> "$F/curl.log"
if grep -q BREAKS_HEALTH "$F/live"; then exit 22; fi
case "$*" in
*-sSI*) printf 'HTTP/1.1 200 OK\r\nContent-Security-Policy: default-src none\r\n\r\n' ;;
*/health*) printf ok ;;
esac
STUB
cat > "$T/bin/ssh" <<'STUB'
#!/usr/bin/env bash
F="$FAKE_DIR"
echo x >> "$F/ssh.calls"
printf '%s\n' "$@" > "$F/ssh.argv.$(wc -l < "$F/ssh.calls" | tr -d ' ')"
last="${*: -1}"
[ "$last" = "exit 0" ] && exit 0
exec bash -c "$last"
STUB
chmod +x "$T/bin/"*

OLD_CF="$T/old.Caddyfile"; NEW_CF="$T/new.Caddyfile"; BAD_CF="$T/bad.Caddyfile"; SICK_CF="$T/sick.Caddyfile"
printf ':80 {\n\trespond "old"\n}\n' > "$OLD_CF"
printf ':80 {\n\trespond "new"\n}\n' > "$NEW_CF"
printf ':80 {\n\tINVALID directive\n}\n' > "$BAD_CF"
printf ':80 {\n\trespond "BREAKS_HEALTH"\n}\n' > "$SICK_CF"

# fresh <name>: a fresh fake web host. Sets F, HOSTFILE.
fresh() {
	F="$T/case-$1"; mkdir -p "$F/srv/caddy"
	HOSTFILE="$F/srv/caddy/Caddyfile"
	cp "$OLD_CF" "$HOSTFILE"
	ln "$HOSTFILE" "$F/view"          # bind mount = same inode
	cp "$OLD_CF" "$F/live"
	: > "$F/docker.log"
	cat > "$F/facts" <<EOF

running=true
project=site
image=sha256:0123456789abcdef
mount=bind /etc/caddy/Caddyfile $HOSTFILE
mount=bind /srv $F/srv/public
mount=volume /data /var/lib/docker/volumes/site_caddy_data/_data
port=80/tcp=127.0.0.1:8085
env=PATH=/usr/bin
env=DOMAIN=:80
EOF
}

# run <case> <src> [args...]: run the script in SKIP_SSH mode.
run() {
	local src="$1"; shift
	OUT="$(env PATH="$T/bin:$PATH" FAKE_DIR="$F" SKIP_SSH=1 WEB_CADDY_SRC="$src" \
		WEB_CADDY_PROJECT="${PROJ:-site}" WEB_CADDY_FILE="${CFILE:-$HOSTFILE}" \
		"$SCRIPT" "$@" 2>&1)"
	RC=$?
}
nreloads() { [ -f "$F/reloads" ] && wc -l < "$F/reloads" | tr -d ' ' || echo 0; }
nbak() { find "$F/srv/caddy" -name 'Caddyfile.bak-*' | wc -l | tr -d ' '; }
docker_scoped() { # every docker call is one of the three allowed shapes
	! grep -vE '^(inspect --type container --format .* caddy-static|exec caddy-static (cat /etc/caddy/Caddyfile|caddy list-modules|caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --address 127.0.0.1:2019)|run --rm --network none --read-only .* --entrypoint caddy sha256:0123456789abcdef validate --config /etc/caddy/Caddyfile --adapter caddyfile)$' "$F/docker.log" | grep -q .
}
NEWSHA="$(sha "$NEW_CF")"

# ---- 1. plan contacts nothing ----------------------------------------------
fresh plan
run "$NEW_CF"
check "plan: exit 0" '[ "$RC" = 0 ]'
check "plan: prints the sha256" 'printf "%s" "$OUT" | grep -q "$NEWSHA"'
check "plan: no docker call" '[ ! -s "$F/docker.log" ]'
check "plan: no ssh call" '[ ! -f "$F/ssh.calls" ]'

# ---- 2. print-remote is valid bash -----------------------------------------
"$SCRIPT" --print-remote > "$T/remote.sh"
check "print-remote: bash -n" 'bash -n "$T/remote.sh"'

# ---- 3. check: in sync / drift, read-only ----------------------------------
fresh check-sync
run "$OLD_CF" --check
check "check in sync: exit 0" '[ "$RC" = 0 ]'
check "check in sync: says IN SYNC" 'printf "%s" "$OUT" | grep -q "IN SYNC"'
fresh check-drift
run "$NEW_CF" --check
check "check drift: exit 10" '[ "$RC" = 10 ]'
check "check drift: shows diff" 'printf "%s" "$OUT" | grep -q "^+	respond \"new\""'
check "check drift: host file untouched" 'cmp -s "$HOSTFILE" "$OLD_CF"'
check "check drift: no reload, no validate run, no backup" '[ "$(nreloads)" = 0 ] && ! grep -q "^run " "$F/docker.log" && [ "$(nbak)" = 0 ]'
check "check: reports rate_limit module" 'printf "%s" "$OUT" | grep -q "rate_limit module present"'
check "check: docker calls scoped" 'docker_scoped'

# ---- 4. apply approval binding ---------------------------------------------
fresh noapproval
run "$NEW_CF" --apply
check "apply without sha: exit 2" '[ "$RC" = 2 ]'
check "apply without sha: nothing contacted" '[ ! -s "$F/docker.log" ]'
fresh wrongsha
run "$NEW_CF" --apply --approved-sha256="$(sha "$OLD_CF")"
check "apply wrong sha: exit 2" '[ "$RC" = 2 ]'
check "apply wrong sha: host file untouched" 'cmp -s "$HOSTFILE" "$OLD_CF" && [ "$(nreloads)" = 0 ]'
check "apply wrong sha: refused locally, nothing contacted" '[ ! -s "$F/docker.log" ] && printf "%s" "$OUT" | grep -q "not the approved content"'
# the remote half re-checks the sha of what it received (defence in depth)
fresh remotesha
OUT="$("$SCRIPT" --print-remote)"
OUT="$(env PATH="$T/bin:$PATH" FAKE_DIR="$F" bash -c "$OUT" _ apply site "$HOSTFILE" "$(sha "$OLD_CF")" "" < "$NEW_CF" 2>&1)"; RC=$?
check "remote half, received sha != approved: exit 2, nothing contacted" '[ "$RC" = 2 ] && [ ! -s "$F/docker.log" ] && cmp -s "$HOSTFILE" "$OLD_CF"'

# ---- 5. apply happy path ---------------------------------------------------
fresh happy
INO0="$(ino "$HOSTFILE")"
run "$NEW_CF" --apply --approved-sha256="$NEWSHA"
check "apply: exit 0" '[ "$RC" = 0 ]'
check "apply: host file = new" 'cmp -s "$HOSTFILE" "$NEW_CF"'
check "apply: inode kept (container sees it)" '[ "$(ino "$HOSTFILE")" = "$INO0" ] && cmp -s "$F/view" "$NEW_CF"'
check "apply: reloaded once, live = new" '[ "$(nreloads)" = 1 ] && cmp -s "$F/live" "$NEW_CF"'
check "apply: one backup holding the old bytes" '[ "$(nbak)" = 1 ] && cmp -s "$F/srv/caddy/"Caddyfile.bak-* "$OLD_CF"'
check "apply: validated in a throwaway container first" 'grep -q "^run --rm --network none --read-only" "$F/docker.log"'
check "apply: docker calls scoped" 'docker_scoped'
check "apply: prints BACKUP name" 'printf "%s" "$OUT" | grep -qE "BACKUP: Caddyfile.bak-[0-9]{8}T[0-9]{6}Z"'
BAKNAME="$(basename "$(ls "$F/srv/caddy/"Caddyfile.bak-*)")"
# idempotent re-run
run "$NEW_CF" --apply --approved-sha256="$NEWSHA"
check "apply re-run: exit 0, NO CHANGE, no extra reload/backup" '[ "$RC" = 0 ] && printf "%s" "$OUT" | grep -q "NO CHANGE" && [ "$(nreloads)" = 1 ] && [ "$(nbak)" = 1 ]'
# requested rollback to the backup
sleep 1
run "$NEW_CF" --rollback --backup="$BAKNAME"
check "rollback: exit 0" '[ "$RC" = 0 ]'
check "rollback: host file + live = old" 'cmp -s "$HOSTFILE" "$OLD_CF" && cmp -s "$F/live" "$OLD_CF"'
check "rollback: inode kept" '[ "$(ino "$HOSTFILE")" = "$INO0" ]'
check "rollback: docker calls scoped" 'docker_scoped'
run "$NEW_CF" --rollback --backup="../../etc/passwd"
check "rollback bad name: exit 2" '[ "$RC" = 2 ]'
run "$NEW_CF" --rollback --backup="Caddyfile.bak-20000101T000000Z"
check "rollback missing backup: exit 2" '[ "$RC" = 2 ]'

# ---- 6. validation failure: nothing written --------------------------------
fresh invalid
run "$BAD_CF" --apply --approved-sha256="$(sha "$BAD_CF")"
check "invalid: exit 2" '[ "$RC" = 2 ]'
check "invalid: host file untouched, no backup, no reload" 'cmp -s "$HOSTFILE" "$OLD_CF" && [ "$(nbak)" = 0 ] && [ "$(nreloads)" = 0 ]'

# ---- 7. scope guard --------------------------------------------------------
guard_case() { # <name> <facts-sed-expr|special>
	fresh "guard-$1"
	case "$2" in
		NOCONTAINER) touch "$F/no-container" ;;
		SYMLINK) mv "$HOSTFILE" "$F/real"; ln -s "$F/real" "$HOSTFILE" ;;
		*) sed -i.orig "$2" "$F/facts" ;;
	esac
	run "$NEW_CF" --apply --approved-sha256="$NEWSHA"
	check "guard $1: exit 2" '[ "$RC" = 2 ]'
	check "guard $1: no write, no backup, no reload, no validate run" \
		'{ [ -L "$HOSTFILE" ] || cmp -s "$HOSTFILE" "$OLD_CF"; } && [ "$(nbak)" = 0 ] && [ "$(nreloads)" = 0 ] && ! grep -q "^run " "$F/docker.log"'
}
guard_case project 's/^project=site$/project=othersite/'
guard_case mountsrc "s|^mount=bind /etc/caddy/Caddyfile .*|mount=bind /etc/caddy/Caddyfile /elsewhere/caddy/Caddyfile|"
guard_case mounttype "s|^mount=bind /etc/caddy/Caddyfile|mount=volume /etc/caddy/Caddyfile|"
guard_case portaddr 's/^port=80\/tcp=127.0.0.1:8085$/port=80\/tcp=0.0.0.0:8085/'
guard_case portextra 's/^port=80\/tcp=127.0.0.1:8085$/port=80\/tcp=127.0.0.1:8085\
port=443\/tcp=0.0.0.0:443/'
guard_case stopped 's/^running=true$/running=false/'
guard_case nodomain '/^env=DOMAIN=/d'
guard_case nocontainer NOCONTAINER
guard_case symlink SYMLINK
# a WEB_CADDY_FILE that is not a Caddyfile is refused before any contact
fresh notcaddyfile
CFILE="$F/srv/caddy/other.conf" run "$NEW_CF" --apply --approved-sha256="$NEWSHA"
check "WEB_CADDY_FILE not */Caddyfile: exit 2, nothing contacted" '[ "$RC" = 2 ] && [ ! -s "$F/docker.log" ]'
fresh dotdot
CFILE="$F/srv/../srv/caddy/Caddyfile" run "$NEW_CF" --apply --approved-sha256="$NEWSHA"
check "WEB_CADDY_FILE with ..: exit 2, nothing contacted" '[ "$RC" = 2 ] && [ ! -s "$F/docker.log" ]'

# ---- 8. failures after the write roll back ---------------------------------
fresh reloadfail
echo once > "$F/reload-fail"
run "$NEW_CF" --apply --approved-sha256="$NEWSHA"
check "reload fail: exit 1 (rolled back)" '[ "$RC" = 1 ]'
check "reload fail: host file = old, live = old, reloaded twice" 'cmp -s "$HOSTFILE" "$OLD_CF" && cmp -s "$F/live" "$OLD_CF" && [ "$(nreloads)" = 2 ]'
fresh healthfail
run "$SICK_CF" --apply --approved-sha256="$(sha "$SICK_CF")"
check "health fail: exit 1 (rolled back)" '[ "$RC" = 1 ]'
check "health fail: host file = old, live = old" 'cmp -s "$HOSTFILE" "$OLD_CF" && cmp -s "$F/live" "$OLD_CF"'
fresh pinned
# the container's view is a separate inode (e.g. an earlier rename-style edit):
# equal bytes now, but an in-place write will not reach it
rm "$F/view"; cp "$OLD_CF" "$F/view"
run "$NEW_CF" --apply --approved-sha256="$NEWSHA"
check "pinned view: not reported as applied (exit 1, rolled back)" '[ "$RC" = 1 ] && ! printf "%s" "$OUT" | grep -q "APPLIED:"'
check "pinned view: host file = old, never reloaded onto new" 'cmp -s "$HOSTFILE" "$OLD_CF" && cmp -s "$F/live" "$OLD_CF"'
fresh rollbackfail
echo always > "$F/reload-fail"
run "$NEW_CF" --apply --approved-sha256="$NEWSHA"
check "rollback fail: exit 4 (URGENT)" '[ "$RC" = 4 ] && printf "%s" "$OUT" | grep -q URGENT'
check "rollback fail: host file restored to old bytes anyway" 'cmp -s "$HOSTFILE" "$OLD_CF"'

# ---- 9. real-mode ssh path: host masked, approval still bound --------------
fresh realssh
: > "$T/key"
OUT="$(env PATH="$T/bin:$PATH" FAKE_DIR="$F" WEB_HOST=192.0.2.10 WEB_HOST_KEY="$T/key" \
	WEB_CADDY_PROJECT=site WEB_CADDY_FILE="$HOSTFILE" "$SCRIPT" --check 2>&1)"; RC=$?
check "ssh check: runs remotely (exit 10 vs repo Caddyfile)" '[ "$RC" = 10 ] && [ "$(wc -l < "$F/ssh.calls" | tr -d " ")" = 2 ]'
check "ssh check: web host address never printed" '! printf "%s" "$OUT" | grep -q "192.0.2.10"'
check "ssh check: loopback binding still readable after masking" 'printf "%s" "$OUT" | grep -q "port 80/tcp=127.0.0.1:8085"'
check "ssh: BatchMode + IdentitiesOnly" 'cat "$F"/ssh.argv.* | grep -q "BatchMode=yes" && cat "$F"/ssh.argv.* | grep -q "IdentitiesOnly=yes"'
OUT="$(env PATH="$T/bin:$PATH" FAKE_DIR="$F" WEB_HOST=192.0.2.10 WEB_HOST_KEY="$T/key" WEB_CADDY_SRC="$NEW_CF" \
	WEB_CADDY_PROJECT=site WEB_CADDY_FILE="$HOSTFILE" "$SCRIPT" --apply --approved-sha256="$NEWSHA" 2>&1)"; RC=$?
check "WEB_CADDY_SRC outside tests: refused" '[ "$RC" = 2 ]'

# ---- 10. the repo Caddyfile must be committed to --apply ------------------
R="$T/repo"; mkdir -p "$R/scripts" "$R/caddy"
cp "$SCRIPT" "$R/scripts/web-host-caddy-apply.sh"
cp "$OLD_CF" "$R/caddy/Caddyfile"
git -C "$R" init -q
git -C "$R" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm init
cp "$NEW_CF" "$R/caddy/Caddyfile"
fresh uncommitted
OUT="$(env PATH="$T/bin:$PATH" FAKE_DIR="$F" SKIP_SSH=1 WEB_CADDY_PROJECT=site WEB_CADDY_FILE="$HOSTFILE" \
	"$R/scripts/web-host-caddy-apply.sh" --apply --approved-sha256="$NEWSHA" 2>&1)"; RC=$?
check "uncommitted Caddyfile: exit 2, nothing contacted" '[ "$RC" = 2 ] && printf "%s" "$OUT" | grep -q uncommitted && [ ! -s "$F/docker.log" ]'

echo "---"
echo "web-host-caddy-apply: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
