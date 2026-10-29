#!/usr/bin/env bash
# install-anomalies-web-origin-env.sh — set the WEB_ORIGIN_IP env line in
# /etc/cron.d/metal-anomalies, so check-anomalies.sh can probe the web host's
# origin directly (P_direct) when the Cloudflare probe fails.
#
# CHAIN: none — edits one env line of one cron file. No broadcast pathway.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Why (docs/superpowers/specs/2026-09-24-web-probe-path-classification-design.md
# §3.1, §3.6): a direct-to-origin probe is what tells a Cloudflare-path failure
# apart from an origin or network-path failure. The origin address is a host
# identifier, so it is NEVER committed: it is supplied when this installer is
# run and exists only in the host's cron file. This installer never echoes it.
#
# Behaviour:
#   - Edits an EXISTING cron file; it never creates metal-anomalies
#     (scripts/vps-bootstrap.sh does).
#   - Drops every existing WEB_ORIGIN_IP= line and inserts exactly one
#     immediately before the first command line (after the env header block),
#     so the position is deterministic and a re-run with the same value is a
#     byte-for-byte no-op. Every other line is preserved.
#   - The candidate is linted with scripts/check-cron-file.sh before install;
#     a lint failure changes nothing.
#   - A differing prior file is backed up to FYD_BACKUP_DIR — never into
#     /etc/cron.d, where cron would ignore it but a reader could mistake it.
#
# Usage (validator host, as root):
#   sudo bash scripts/install-anomalies-web-origin-env.sh --origin-ip=<IPv4>
#   (or with WEB_ORIGIN_IP=<IPv4> set in a root shell's environment)
#
# Env overrides (test harness):
#   FYD_CRON_TARGET   cron file to edit (default /etc/cron.d/metal-anomalies).
#                     When overridden, the root requirement is waived and root
#                     ownership is not enforced.
#   FYD_BACKUP_DIR    backup destination (default /var/backups)
#   FYD_REPO_PATH     repo whose scripts/check-cron-file.sh lints the
#                     candidate (default: the repo this script lives in)
#
# Exit codes:
#   0  installed, or already up to date
#   1  usage error, or the origin address is missing / not a dotted-quad IPv4
#   2  not root (and FYD_CRON_TARGET not overridden)
#   3  target cron file missing
#   4  candidate failed check-cron-file.sh (target untouched)
#   5  post-install verification failed (prior file restored)
#
# Operator-gated: committed so the host action is one command; running it on
# the host follows operator approval (Constitution §5 / Operating Model W7).

set -euo pipefail

PROD_TARGET="/etc/cron.d/metal-anomalies"
CRON_TARGET="${FYD_CRON_TARGET:-$PROD_TARGET}"
BACKUP_DIR="${FYD_BACKUP_DIR:-/var/backups}"
REPO_PATH="${FYD_REPO_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
ORIGIN_IP="${WEB_ORIGIN_IP:-}"

for arg in "$@"; do
	case "$arg" in
		--origin-ip=*) ORIGIN_IP="${arg#*=}" ;;
		-h | --help) sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

if [ "$CRON_TARGET" = "$PROD_TARGET" ] && [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: this installer must run as root (edits /etc/cron.d/metal-anomalies)" >&2
	echo "       usage: sudo bash scripts/install-anomalies-web-origin-env.sh --origin-ip=<IPv4>" >&2
	exit 2
fi

# Dotted-quad IPv4 only, no leading zeros (curl reads 010 as octal). Same
# rule as web_is_ipv4 in scripts/lib/web-probe.sh, which re-checks the value
# at run time and skips P_direct if it is malformed.
is_ipv4() {
	local ip="$1" o IFS=.
	case "$ip" in
		"" | *[!0-9.]* | .* | *. | *..*) return 1 ;;
	esac
	set -- $ip
	[ "$#" -eq 4 ] || return 1
	for o in "$@"; do
		case "$o" in
			0?*) return 1 ;;
		esac
		[ "${#o}" -le 3 ] || return 1
		[ "$o" -le 255 ] 2>/dev/null || return 1
	done
	return 0
}
if ! is_ipv4 "$ORIGIN_IP"; then
	echo "ERROR: origin address missing or not a dotted-quad IPv4 address (pass --origin-ip=<IPv4>)" >&2
	exit 1
fi

if [ ! -f "$CRON_TARGET" ]; then
	echo "ERROR: ${CRON_TARGET} missing — this installer edits it, it does not create it (see scripts/vps-bootstrap.sh)" >&2
	exit 3
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP" "${TMP}.lint"' EXIT
awk -v line="WEB_ORIGIN_IP=${ORIGIN_IP}" '
	/^WEB_ORIGIN_IP=/ { next }
	!done && $0 !~ /^[[:space:]]*(#|$)/ && $0 !~ /^[A-Z_]+=/ { print line; done = 1 }
	{ print }
	END { if (!done) print line }
' "$CRON_TARGET" >"$TMP"

if cmp -s "$TMP" "$CRON_TARGET"; then
	echo "ok: ${CRON_TARGET} already carries this WEB_ORIGIN_IP (no change)"
	exit 0
fi

if ! FYD_CRON_SCRIPTS_DIR="${REPO_PATH}/scripts" bash "${REPO_PATH}/scripts/check-cron-file.sh" "$TMP" >"${TMP}.lint" 2>&1; then
	echo "ERROR: candidate cron file failed check-cron-file.sh — nothing changed" >&2
	grep -F 'FAIL' "${TMP}.lint" >&2 || true
	exit 4
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${BACKUP_DIR}/$(basename "$CRON_TARGET").bak-${STAMP}"
mkdir -p "$BACKUP_DIR"
cp -p "$CRON_TARGET" "$BACKUP"
echo "backed up prior target to ${BACKUP}"

if [ "$CRON_TARGET" = "$PROD_TARGET" ]; then
	install -m 0644 -o root -g root "$TMP" "$CRON_TARGET"
else
	install -m 0644 "$TMP" "$CRON_TARGET"
fi

if [ "$(grep -c '^WEB_ORIGIN_IP=' "$CRON_TARGET")" != "1" ] \
	|| ! grep -qxF "WEB_ORIGIN_IP=${ORIGIN_IP}" "$CRON_TARGET"; then
	echo "ERROR: post-install verification failed — restoring ${BACKUP}" >&2
	cp -p "$BACKUP" "$CRON_TARGET"
	exit 5
fi
echo "installed: WEB_ORIGIN_IP set in ${CRON_TARGET} (value not echoed)"
echo "effect:    the next check-anomalies.sh run probes the origin directly when the Cloudflare probe fails"
