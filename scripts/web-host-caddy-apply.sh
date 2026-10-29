#!/usr/bin/env bash
# web-host-caddy-apply.sh — bring a reviewed change of caddy/Caddyfile to the
# web host's `caddy-static` container, one operator-approved change at a time.
#
# CHAIN: none. PRIME_DIRECTIVE: safe (no broadcast-capable command).
# BROADCASTS NOTHING. Never contacts the validator host.
#
# Why this exists: the public site is served on the (multi-tenant) web host by
# host nginx -> 127.0.0.1:8085 -> the container `caddy-static`. The CI deploy
# only rsyncs public/ there (its key is confined to the public dir), so a
# Caddyfile change in this repository otherwise never reaches the site. This
# script is the supported path. It is run from the Mac by the AI after the
# operator has approved THAT change in chat (Constitution §5 v0.9, Operating
# Model W7, docs/DEPLOY_SETUP.md §9), and the approval is bound to the exact
# content by --approved-sha256. v0.9 is a loosening amendment: merged
# 2026-10-08 10:56 JST (merge commit 6da8456) -> effective 2026-10-15 10:56 JST
# (merge + 7 days). Before that moment the AI runs none of the remote modes —
# not even the read-only --check — and only the operator may run them.
#
# Modes:
#   (none) | --plan   local only: no ssh, no docker. Prints the repo
#                     Caddyfile's sha256, the commit it is in, and the
#                     commands to run next.
#   --check           read-only on the web host: scope guard (below), whether
#                     the rate_limit module is in the running image, health
#                     as information only, and a unified diff running ->
#                     repo. Exit 0 in sync, 10 drift.
#   --apply --approved-sha256=<64 hex>
#                     scope guard; the repo Caddyfile must be committed and
#                     its sha256 must equal the approved value; validate it in
#                     a throwaway container of the RUNNING image (--rm,
#                     --network none, read-only); back up the host file to
#                     <file>.bak-<UTC>; overwrite the host file IN PLACE (a
#                     single-file bind mount is pinned to the inode, so a
#                     rename would leave the container on the old file); check
#                     the container now sees the new bytes; `caddy reload`
#                     (admin API pinned to 127.0.0.1:2019, never localhost)
#                     inside the container; health (/health = ok and a CSP
#                     header on /). For --apply only, the same health check
#                     must already pass before anything is written (else
#                     refuse, exit 2). Any
#                     failure after the write restores the backup the same
#                     way (only if its sha256 is unchanged since it was
#                     taken) and reloads again. After success only the
#                     newest 5 Caddyfile.bak-<UTC> next to the file are kept.
#   --rollback --backup=Caddyfile.bak-<YYYYmmddTHHMMSSZ>
#                     same guard + validate + in-place write + reload + health,
#                     with a backup written next to the file by --apply. Works
#                     on a site whose health is already failing (that is when
#                     it is needed); if it then still fails and the site was
#                     failing before, it goes back to the file as found (exit 1).
#   --print-remote    print the remote half for review and exit.
#
# Scope guard (every remote mode, before anything else). Refuses (exit 2,
# nothing changed) unless ALL hold:
#   - a container named exactly `caddy-static` exists and is running
#     (the name is a constant here, not an input: this script cannot be
#     pointed at another project's container)
#   - its label com.docker.compose.project equals WEB_CADDY_PROJECT
#   - /etc/caddy/Caddyfile in it is a bind mount whose source is exactly
#     WEB_CADDY_FILE (a regular file named Caddyfile, not a symlink, parent
#     not a symlink)
#   - its only port binding is 80/tcp -> 127.0.0.1:8085
#   - the host file and the container's view of it are byte-identical
# The only docker commands it issues are `docker inspect --type container …
# caddy-static`, `docker run --rm --network none … caddy validate` (a
# throwaway container), and, through the single gate cexec(), exactly these
# inside caddy-static: `cat /etc/caddy/Caddyfile`, `caddy list-modules`,
# `caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --address
# 127.0.0.1:2019`. No other command runs inside it. It never runs
# docker compose, never builds, starts, stops, recreates or removes a
# container, never prunes, and never touches nginx, systemd, cron, packages or
# the firewall (Constitution §5 multi-tenant scoping). A caddy/Dockerfile
# change (image rebuild) is NOT handled here: see docs/DEPLOY_SETUP.md §9.4.
#
# Env:
#   WEB_HOST            web host address (required for remote modes)
#   WEB_HOST_KEY        ssh private key path (required, no default)
#   WEB_HOST_USER       ssh user (required, no default; needs docker access —
#                       the verified web-host fact is in docs/DEPLOY_SETUP.md §9.1)
#   WEB_CADDY_PROJECT   expected compose project label of caddy-static
#   WEB_CADDY_FILE      absolute host path bind-mounted at /etc/caddy/Caddyfile
#   The last two are web-host facts, verified 2026-10-08 (project = site;
#   the bind source is <deploy dir>/caddy/Caddyfile — docs/DEPLOY_SETUP.md §9.1,
#   with the read-only commands to re-check them). The path is never committed (§4.2 C5).
#   SKIP_SSH=1          tests only: run the remote half locally. Then
#                       WEB_CADDY_SRC may replace caddy/Caddyfile and the git
#                       "committed" check is skipped for that file.
#
# Exit codes:
#   0  ok (applied / rolled back on request / in sync / plan printed)
#   1  apply failed after the write and was ROLLED BACK (site on old config)
#   2  refused: precondition or validation failed; nothing was changed
#   3  ssh pre-check failed
#   4  URGENT: automatic rollback failed — site config state unknown
#   10 --check: running Caddyfile differs from the repo
#
# Usage (from the Mac, repo root):
#   bash scripts/web-host-caddy-apply.sh                       # plan
#   WEB_HOST=… WEB_HOST_KEY=… WEB_HOST_USER=… WEB_CADDY_PROJECT=… WEB_CADDY_FILE=… \
#     bash scripts/web-host-caddy-apply.sh --check
#   … --apply --approved-sha256=<sha from plan>
#   … --rollback --backup=Caddyfile.bak-20261008T010203Z

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODE=plan
APPROVED_SHA=""
BACKUP_NAME=""
for arg in "$@"; do
	case "$arg" in
		--plan)              MODE=plan ;;
		--check)             MODE=check ;;
		--apply)             MODE=apply ;;
		--rollback)          MODE=rollback ;;
		--print-remote)      MODE=print-remote ;;
		--approved-sha256=*) APPROVED_SHA="${arg#*=}" ;;
		--backup=*)          BACKUP_NAME="${arg#*=}" ;;
		-h|--help)           sed -n '2,85p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "ERROR (2): unknown argument: $arg" >&2; exit 2 ;;
	esac
done

# ---------------------------------------------------------------------------
# The remote half. Runs on the web host as WEB_HOST_USER via
#   bash -c "$REMOTE_SCRIPT" _ <mode> <project> <file> <approved_sha> <backup>
# For check / apply the candidate Caddyfile arrives on stdin.
# ---------------------------------------------------------------------------
# read -d '' (not $(cat <<…)): macOS bash 3.2 ends a $( ) at the first case-pattern ')' inside a heredoc.
REMOTE_SCRIPT=''
IFS= read -r -d '' REMOTE_SCRIPT <<'REMOTE' || true
set -uo pipefail
MODE="$1" PROJECT="$2" FILE="$3" APPROVED="$4" BACKUP="$5"
C=caddy-static
IN=/etc/caddy/Caddyfile
WANT_PORT='80/tcp=127.0.0.1:8085'
# The admin API listens on 127.0.0.1 only; "localhost" inside the container
# resolves to ::1 first and is refused (measured on the web host 2026-10-08).
ADMIN=127.0.0.1:2019

refuse() { echo "REFUSED: $*" >&2; exit 2; }
sha() { sha256sum "$1" | awk '{print $1}'; }

HEALTH_BEFORE=unknown
TMP="$(mktemp -d)" || refuse "mktemp failed"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# cexec: the ONLY way this script runs a command inside caddy-static. The
# allowed commands are listed exactly; anything else is refused (exit 2).
# (caddy validate runs in a separate throwaway container, see validate().)
cexec() {
	case "$*" in
		"cat $IN"|"caddy list-modules"|"caddy reload --config $IN --adapter caddyfile --address $ADMIN")
			docker exec "$C" "$@" ;;
		*) refuse "command inside $C not allowed: $*" ;;
	esac
}
view() { cexec cat "$IN"; }

guard() {
	local facts running project image mounts ports n
	facts="$(docker inspect --type container --format '
running={{.State.Running}}
project={{index .Config.Labels "com.docker.compose.project"}}
image={{.Image}}
{{range .Mounts}}mount={{.Type}} {{.Destination}} {{.Source}}
{{end}}{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}port={{$p}}={{.HostIp}}:{{.HostPort}}
{{end}}{{end}}{{range .Config.Env}}env={{.}}
{{end}}' "$C" 2>/dev/null)" || refuse "no container named $C"
	running="$(printf '%s\n' "$facts" | sed -n 's/^running=//p')"
	project="$(printf '%s\n' "$facts" | sed -n 's/^project=//p')"
	IMAGE="$(printf '%s\n' "$facts" | sed -n 's/^image=//p')"
	mounts="$(printf '%s\n' "$facts" | sed -n "s|^mount=\\([a-z]*\\) $IN |\\1 |p")"
	ports="$(printf '%s\n' "$facts" | sed -n 's/^port=//p')"
	DOMAIN_ENV="$(printf '%s\n' "$facts" | sed -n 's/^env=DOMAIN=//p')"
	[ "$running" = true ] || refuse "$C is not running"
	[ "$project" = "$PROJECT" ] || refuse "$C compose project is '$project', expected '$PROJECT'"
	n="$(printf '%s\n' "$mounts" | grep -c . || true)"
	[ "$n" = 1 ] || refuse "$C has $n mounts at $IN (need exactly one bind)"
	[ "$mounts" = "bind $FILE" ] || refuse "$IN in $C is '$mounts', expected 'bind $FILE'"
	[ "$ports" = "$WANT_PORT" ] || refuse "$C port bindings are '$(printf '%s' "$ports" | tr '\n' ' ')', expected '$WANT_PORT'"
	[ -n "$IMAGE" ] || refuse "$C image id empty"
	[ -n "$DOMAIN_ENV" ] || refuse "$C has no DOMAIN env (needed to validate)"
	[ -f "$FILE" ] && [ ! -L "$FILE" ] || refuse "host Caddyfile is not a regular file (or is a symlink)"
	[ ! -L "$(dirname "$FILE")" ] || refuse "host Caddyfile's directory is a symlink"
	view > "$TMP/view" 2>/dev/null || refuse "cannot read $IN inside $C"
	[ "$(sha "$TMP/view")" = "$(sha "$FILE")" ] \
		|| refuse "host file and $C's view of it differ (bind pinned to an old inode?) — not handled here; see runbook"
	if cexec caddy list-modules 2>/dev/null | grep -qx 'http.handlers.rate_limit'; then
		RL=present
	else
		RL=ABSENT
	fi
	echo "guard: ok (container $C, project ok, bind ok, port $WANT_PORT, image ${IMAGE#sha256:}, rate_limit module $RL)"
	# Health as found, before anything is written. Only --apply refuses on a
	# failing baseline (so "URGENT" is never reported for a site that was never
	# healthy); --rollback must work on a broken site, and --check only reports.
	if health; then HEALTH_BEFORE=ok; else HEALTH_BEFORE=FAILING; echo "health: FAILING before any change (/health or CSP header on 127.0.0.1:8085)"; fi
}

validate() { # <file>
	cp "$1" "$TMP/validate.Caddyfile"
	chmod 644 "$TMP/validate.Caddyfile"
	if docker run --rm --network none --read-only \
		--tmpfs /config --tmpfs /data --tmpfs /tmp \
		--cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges:true \
		--label metal-fy.purpose=caddy-validate \
		-e "DOMAIN=$DOMAIN_ENV" \
		-v "$TMP/validate.Caddyfile:$IN:ro" \
		--entrypoint caddy "$IMAGE" \
		validate --config "$IN" --adapter caddyfile > "$TMP/validate.log" 2>&1; then
		echo "validate: ok (running image)"
		return 0
	fi
	tail -n 20 "$TMP/validate.log" >&2
	return 1
}

health() {
	local body
	body="$(curl -fsS --max-time 10 http://127.0.0.1:8085/health 2>/dev/null)" || return 1
	[ "$body" = ok ] || return 1
	curl -sSI --max-time 10 http://127.0.0.1:8085/ 2>/dev/null \
		| grep -qi '^content-security-policy:' || return 1
	echo "health: ok (/health = ok, CSP header present)"
}

# put <src>: overwrite FILE in place (keeps the inode the bind mount is
# pinned to), confirm the container sees it, reload, health.
put() {
	local want
	want="$(sha "$1")"
	cat "$1" > "$FILE" || return 1
	view > "$TMP/after" 2>/dev/null || return 1
	[ "$(sha "$TMP/after")" = "$want" ] || { echo "container does not see the new bytes" >&2; return 1; }
	cexec caddy reload --config "$IN" --adapter caddyfile --address "$ADMIN" > "$TMP/reload.log" 2>&1 \
		|| { tail -n 20 "$TMP/reload.log" >&2; return 1; }
	echo "reload: ok"
	health || return 3
}

restore() { # <backup path> <sha256 it had when it was taken>
	echo "ROLLING BACK to $(basename "$1")" >&2
	if [ "$(sha "$1")" != "$2" ]; then
		echo "URGENT: backup $(basename "$1") changed since it was taken — NOT restoring from it; restore by hand (runbook §9.3)" >&2
		exit 4
	fi
	put "$1"; local rc=$?
	if [ "$rc" = 0 ]; then
		echo "ROLLED BACK: site is on the previous Caddyfile ($(basename "$1"))" >&2
		exit 1
	fi
	if [ "$rc" = 3 ] && [ "$HEALTH_BEFORE" = FAILING ]; then
		echo "ROLLED BACK to the Caddyfile as found ($(basename "$1")); health was already failing before this run and still fails" >&2
		exit 1
	fi
	echo "URGENT: rollback FAILED — restore $(basename "$1") by hand (runbook §9.3)" >&2
	exit 4
}

KEEP=5
# prune_backups: keep the newest $KEEP Caddyfile.bak-<UTC> next to FILE. Only
# names of exactly that shape, only regular non-symlink files, only that dir.
# Called after a successful change, never on failure (keeps the evidence).
prune_backups() {
	local d n
	d="$(dirname "$FILE")"
	ls -1 "$d" | grep -E '^Caddyfile\.bak-[0-9]{8}T[0-9]{6}Z$' | sort -r | tail -n +$((KEEP + 1)) \
	| while IFS= read -r n; do
		if [ -f "$d/$n" ] && [ ! -L "$d/$n" ]; then rm -f -- "$d/$n" && echo "pruned old backup: $n"; fi
	done
}

case "$MODE" in
check)
	cat > "$TMP/new"
	guard
	if cmp -s "$FILE" "$TMP/new"; then echo "IN SYNC: running Caddyfile = repo"; exit 0; fi
	echo "DRIFT: running Caddyfile differs from the repo (diff running -> repo):"
	diff -u --label running --label repo "$FILE" "$TMP/new" || true
	exit 10 ;;
apply)
	cat > "$TMP/new"
	[ "$(sha "$TMP/new")" = "$APPROVED" ] || refuse "received Caddyfile sha256 != approved sha256"
	guard
	[ "$HEALTH_BEFORE" = ok ] || refuse "site health fails BEFORE any change — --apply does not touch an unhealthy site (use --rollback to go back to a backup)"
	if cmp -s "$FILE" "$TMP/new"; then echo "NO CHANGE: running Caddyfile already equals the approved one"; exit 0; fi
	validate "$TMP/new" || refuse "caddy validate failed on the new Caddyfile — nothing changed"
	B="$FILE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
	[ ! -e "$B" ] || refuse "backup $(basename "$B") already exists"
	cp -p "$FILE" "$B" || refuse "backup failed"
	BSHA="$(sha "$B")"
	[ "$BSHA" = "$(sha "$FILE")" ] || refuse "backup verification failed"
	echo "BACKUP: $(basename "$B")"
	if put "$TMP/new"; then echo "APPLIED: sha256 $APPROVED"; prune_backups; exit 0; fi
	restore "$B" "$BSHA" ;;
rollback)
	case "$BACKUP" in
		Caddyfile.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
		*) refuse "backup name must be Caddyfile.bak-<YYYYmmddTHHMMSSZ>" ;;
	esac
	B="$(dirname "$FILE")/$BACKUP"
	[ -f "$B" ] && [ ! -L "$B" ] || refuse "backup $BACKUP not found (or is a symlink)"
	guard
	if cmp -s "$FILE" "$B"; then echo "NO CHANGE: running Caddyfile already equals $BACKUP"; exit 0; fi
	validate "$B" || refuse "caddy validate failed on $BACKUP — nothing changed"
	PRE="$FILE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
	[ ! -e "$PRE" ] || refuse "backup $(basename "$PRE") already exists"
	cp -p "$FILE" "$PRE" || refuse "backup failed"
	PSHA="$(sha "$PRE")"
	[ "$PSHA" = "$(sha "$FILE")" ] || refuse "backup verification failed"
	echo "BACKUP: $(basename "$PRE")"
	if put "$B"; then echo "ROLLBACK APPLIED: $BACKUP"; prune_backups; exit 0; fi
	restore "$PRE" "$PSHA" ;;
*)
	refuse "unknown remote mode" ;;
esac
REMOTE

if [ "$MODE" = print-remote ]; then
	printf '%s\n' "$REMOTE_SCRIPT"
	exit 0
fi

die2() { echo "ERROR (2): $*" >&2; exit 2; }

sha_local() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	else shasum -a 256 "$1" | awk '{print $1}'; fi
}

SKIP_SSH="${SKIP_SSH:-0}"
SRC="$REPO_ROOT/caddy/Caddyfile"
if [ -n "${WEB_CADDY_SRC:-}" ]; then
	[ "$SKIP_SSH" = 1 ] || die2 "WEB_CADDY_SRC is for tests only (SKIP_SSH=1)"
	SRC="$WEB_CADDY_SRC"
fi
[ -s "$SRC" ] || die2 "Caddyfile not found: $SRC"
SHA="$(sha_local "$SRC")"

# The applied content must be in git history (reviewable, revertible).
committed_note=""
if [ -z "${WEB_CADDY_SRC:-}" ]; then
	if git -C "$REPO_ROOT" diff --quiet HEAD -- caddy/Caddyfile 2>/dev/null \
		&& git -C "$REPO_ROOT" ls-files --error-unmatch caddy/Caddyfile >/dev/null 2>&1; then
		committed_note="committed in $(git -C "$REPO_ROOT" log -1 --format=%h -- caddy/Caddyfile)"
	else
		committed_note="UNCOMMITTED"
	fi
fi

if [ "$MODE" = plan ]; then
	echo "repo caddy/Caddyfile sha256: $SHA ${committed_note:+($committed_note)}"
	echo "Nothing was contacted. Next (docs/DEPLOY_SETUP.md §9):"
	echo "  1. --check            (read-only: scope guard + diff running -> repo)"
	echo "  2. operator approves this exact change in chat (diff + sha256 above)"
	echo "  3. --apply --approved-sha256=$SHA"
	echo "  4. public check: curl -fsS https://metal.freedom-yield.com/health"
	exit 0
fi

if [ "$MODE" = apply ]; then
	printf '%s' "$APPROVED_SHA" | grep -qE '^[0-9a-f]{64}$' \
		|| die2 "--apply needs --approved-sha256=<64 lowercase hex> (the sha the operator approved)"
	[ "$APPROVED_SHA" = "$SHA" ] || die2 "repo Caddyfile sha256 ($SHA) != approved ($APPROVED_SHA) — not the approved content"
	[ "$committed_note" != UNCOMMITTED ] || die2 "caddy/Caddyfile has uncommitted changes — commit first"
fi
if [ "$MODE" = rollback ]; then
	[ -n "$BACKUP_NAME" ] || die2 "--rollback needs --backup=Caddyfile.bak-<YYYYmmddTHHMMSSZ>"
fi

WEB_CADDY_PROJECT="${WEB_CADDY_PROJECT:-}"
WEB_CADDY_FILE="${WEB_CADDY_FILE:-}"
printf '%s' "$WEB_CADDY_PROJECT" | grep -qE '^[a-z0-9][a-z0-9_-]{0,63}$' \
	|| die2 "WEB_CADDY_PROJECT missing or malformed (web-host fact: site; see docs/DEPLOY_SETUP.md §9.1)"
printf '%s' "$WEB_CADDY_FILE" | grep -qE '^/[A-Za-z0-9._/-]+/Caddyfile$' \
	|| die2 "WEB_CADDY_FILE must be an absolute path ending in /Caddyfile (web-host fact; see docs/DEPLOY_SETUP.md §9.1)"
if printf '%s' "$WEB_CADDY_FILE" | grep -qE '(^|/)[.][.]?(/|$)|//'; then
	die2 "WEB_CADDY_FILE must not contain . / .. / // segments"
fi

WEB_HOST="${WEB_HOST:-}"
WEB_HOST_KEY="${WEB_HOST_KEY:-}"
WEB_HOST_USER="${WEB_HOST_USER:-}"
if [ "$SKIP_SSH" != 1 ]; then
	[ -n "$WEB_HOST" ] || die2 "WEB_HOST required"
	[ -n "$WEB_HOST_KEY" ] || die2 "WEB_HOST_KEY required (no default)"
	[ -r "$WEB_HOST_KEY" ] || die2 "WEB_HOST_KEY not readable"
	[ -n "$WEB_HOST_USER" ] || die2 "WEB_HOST_USER required (no default; web-host fact: docs/DEPLOY_SETUP.md §9.1)"
	printf '%s' "$WEB_HOST_USER" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' || die2 "WEB_HOST_USER malformed"
fi

# Mask host-identifying values in everything that comes back.
mask() {
	M1="$WEB_HOST_KEY" M2="$WEB_HOST" M3="$WEB_HOST_USER" LC_ALL=C awk 'BEGIN {
		n = split("M1 M2 M3", k, " "); split("<ssh key>|<web host>|<ssh user>", r, "|")
	}
	{
		for (i = 1; i <= n; i++) {
			v = ENVIRON[k[i]]; if (v == "" || (i == 3 && v == "root")) continue
			out = ""; s = $0
			while ((p = index(s, v)) > 0) { out = out substr(s, 1, p - 1) r[i]; s = substr(s, p + length(v)) }
			$0 = out s
		}
		gsub(/127\.0\.0\.1/, "\001")    # loopback is not host-identifying
		gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "<ip>")
		gsub(/\001/, "127.0.0.1")
		print
	}'
}

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR
	-o IdentitiesOnly=yes -o ForwardAgent=no -o ClearAllForwardings=yes)

web_run() { # <remote mode>; stdin passed through
	local args
	args="$(shq "$1") $(shq "$WEB_CADDY_PROJECT") $(shq "$WEB_CADDY_FILE") $(shq "$APPROVED_SHA") $(shq "$BACKUP_NAME")"
	if [ "$SKIP_SSH" = 1 ]; then
		eval "set -- $args"
		bash -c "$REMOTE_SCRIPT" _ "$@"
	else
		ssh -i "$WEB_HOST_KEY" "${SSH_OPTS[@]}" "${WEB_HOST_USER}@${WEB_HOST}" \
			"bash -c $(shq "$REMOTE_SCRIPT") _ ${args}"
	fi
}

if [ "$SKIP_SSH" != 1 ]; then
	rc=0
	ssh -i "$WEB_HOST_KEY" "${SSH_OPTS[@]}" "${WEB_HOST_USER}@${WEB_HOST}" 'exit 0' > /dev/null 2>&1 < /dev/null || rc=$?
	if [ "$rc" -ne 0 ]; then echo "ERROR (3): ssh pre-check failed: <web host> (ssh rc=$rc)" >&2; exit 3; fi
fi

echo "==> $MODE on <web host> (repo Caddyfile sha256 $SHA${committed_note:+, $committed_note})"
IN_FILE=/dev/null
[ "$MODE" = rollback ] || IN_FILE="$SRC"
set +e
web_run "$MODE" < "$IN_FILE" 2> >(mask >&2) | mask
rcs=("${PIPESTATUS[@]}")
set -e
rc="${rcs[0]}"
case "$rc" in
	0)  echo "==> done ($MODE)";;
	1)  echo "==> FAILED and ROLLED BACK — the site is on the previous Caddyfile" >&2 ;;
	2)  echo "==> REFUSED — nothing was changed" >&2 ;;
	4)  echo "==> URGENT: rollback failed — see docs/DEPLOY_SETUP.md §9.3 and docs/INCIDENT_RESPONSE.md §3.1" >&2 ;;
	10) echo "==> DRIFT (running != repo)" ;;
	*)  echo "==> remote exited $rc" >&2 ;;
esac
exit "$rc"
