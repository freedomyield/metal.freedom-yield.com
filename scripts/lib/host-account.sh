#!/usr/bin/env bash
# scripts/lib/host-account.sh — fyd_cron_user(), the single place that names
# the host account the project's crons and file ownership belong to.
#
# CHAIN: none — this file defines a shell function only. It never invokes
#        a broadcast-capable command and offers no route to one.
#
# Why this exists: the host installers used to hard-code the login name of
# the validator-host account in every cron line and chown. The checkout on
# the host belongs to that account (it is cloned and fast-forwarded as it:
# scripts/vps-bootstrap.sh, scripts/advance-host-checkout.sh), so the owner
# of the checkout IS the account. Reading it from there keeps the generated
# files byte-identical on the host without naming the account in the repo.
#
# fyd_cron_user REPO_PATH
#   prints the account name and returns 0.
#   Order: FYD_CRON_USER (explicit override, used by tests and by a host
#   whose checkout is owned by someone else), then the owner of REPO_PATH.
#   Fails closed (returns 1, prints nothing) when the name is empty, is
#   `root` or is `UNKNOWN`: a cron line for the wrong account is worse than
#   an installer that stops and says so.

fyd_cron_user() {
	local repo="${1:-}" user="${FYD_CRON_USER:-}"
	if [ -z "$user" ] && [ -n "$repo" ]; then
		user="$(stat -c '%U' "$repo" 2>/dev/null || stat -f '%Su' "$repo" 2>/dev/null || true)"
	fi
	case "$user" in
		""|root|UNKNOWN) return 1 ;;
	esac
	printf '%s\n' "$user"
}
