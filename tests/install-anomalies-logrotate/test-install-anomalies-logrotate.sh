#!/usr/bin/env bash
# tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh —
# suite for scripts/install-anomalies-logrotate.sh (web-probe design spec
# 2026-09-24 §3.5, G5: 90-day retention for anomalies.log and the two
# public-site probe logs).
#
# CHAIN: none — the installer runs in test-harness mode against a tempdir
#        (FYD_LOGROTATE_TARGET / FYD_LOG_DIR / FYD_BACKUP_DIR); /etc and
#        /var/log are never touched.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Usage:
#   bash tests/install-anomalies-logrotate/test-install-anomalies-logrotate.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install-anomalies-logrotate.sh"
BOOTSTRAP="${REPO_ROOT}/scripts/vps-bootstrap.sh"

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP  $1${2:+ — $2}"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

WORK="$(mktemp -d -t anomalies-logrotate-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/logrotate.d" "$WORK/log"
TARGET="$WORK/logrotate.d/anomalies"
LOGD="$WORK/log"

run_inst() {
	FYD_LOGROTATE_TARGET="$TARGET" FYD_LOG_DIR="$LOGD" FYD_DEPLOY_USER=deploy \
		FYD_BACKUP_DIR="$WORK/backups" bash "$INSTALLER"
}

# The expected config, written out independently of the installer: this is
# the spec's retention contract, not a copy of the installer's heredoc.
EXPECTED="$(cat <<CONF
# Managed by scripts/install-anomalies-logrotate.sh — edit the installer, not this file.
# 90-day retention: web-probe design spec 2026-09-24 §3.5 (G5).
${LOGD}/anomalies.log ${LOGD}/anomalies-web-diag.log ${LOGD}/anomalies-web-blips.log {
  daily
  rotate 90
  compress
  missingok
  notifempty
  create 644 deploy deploy
}
CONF
)"

printf 'existing line\n' >"$LOGD/anomalies.log"

# --- T1 fresh install ---------------------------------------------------------
OUT="$(run_inst 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "T1 fresh install exits 0" || bad "T1 fresh install exits 0" "rc=$RC $OUT"
[ "$(cat "$TARGET" 2>/dev/null)" = "$EXPECTED" ] \
	&& ok "T1 config is exactly the 90-day contract (daily / rotate 90 / compress / create 644 deploy deploy)" \
	|| bad "T1 config is exactly the 90-day contract" "$(diff <(printf '%s\n' "$EXPECTED") "$TARGET" 2>&1 | head -5)"
[ "$(mode_of "$TARGET")" = "644" ] && ok "T1 config mode 0644" || bad "T1 config mode 0644" "$(mode_of "$TARGET")"

# --- T2 provisioning --------------------------------------------------------------
for name in anomalies-web-diag.log anomalies-web-blips.log; do
	[ -f "$LOGD/$name" ] && [ ! -s "$LOGD/$name" ] \
		&& ok "T2 ${name} provisioned (empty)" \
		|| bad "T2 ${name} provisioned (empty)"
	[ "$(mode_of "$LOGD/$name")" = "644" ] && ok "T2 ${name} mode 0644" || bad "T2 ${name} mode 0644"
done
[ "$(cat "$LOGD/anomalies.log")" = "existing line" ] \
	&& ok "T2 an existing log is never truncated" \
	|| bad "T2 an existing log is never truncated" "$(cat "$LOGD/anomalies.log")"

# --- T3 idempotent ----------------------------------------------------------------
OUT="$(run_inst 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'already up to date' <<<"$OUT" \
	&& ok "T3 re-run is a no-op" || bad "T3 re-run is a no-op" "rc=$RC $OUT"
[ ! -d "$WORK/backups" ] || [ -z "$(ls -A "$WORK/backups")" ] \
	&& ok "T3 no backup on a no-op" || bad "T3 no backup on a no-op" "$(ls "$WORK/backups")"

# --- T4 differing prior config (the old 7-day stanza) is backed up and replaced ----
printf '/var/log/anomalies.log {\n  daily\n  rotate 7\n}\n' >"$TARGET"
OUT="$(run_inst 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$TARGET")" = "$EXPECTED" ] \
	&& ok "T4 old 7-day config replaced" || bad "T4 old 7-day config replaced" "rc=$RC"
[ "$(ls "$WORK/backups" 2>/dev/null | grep -c '^logrotate-anomalies\.bak-')" = "1" ] \
	&& ok "T4 prior config backed up once" || bad "T4 prior config backed up once" "$(ls "$WORK/backups" 2>&1)"
[ "$(ls "$WORK/logrotate.d")" = "anomalies" ] \
	&& ok "T4 no sidecar left in the logrotate dir (logrotate would load it)" \
	|| bad "T4 no sidecar left in the logrotate dir" "$(ls "$WORK/logrotate.d")"

# --- T5 root gate ---------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	env -u FYD_LOGROTATE_TARGET bash "$INSTALLER" >/dev/null 2>&1; RC=$?
	[ "$RC" -eq 2 ] && ok "T5 production target without root → exit 2" || bad "T5 production target without root → exit 2" "rc=$RC"
else
	skip "T5 root gate" "running as root"
fi

# --- T6 missing log dir -------------------------------------------------------------
FYD_LOGROTATE_TARGET="$WORK/other" FYD_LOG_DIR="$WORK/no-such-dir" bash "$INSTALLER" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 3 ] && [ ! -e "$WORK/other" ] && ok "T6 missing log dir → exit 3, nothing written" || bad "T6 missing log dir → exit 3" "rc=$RC"

# --- T7 vps-bootstrap.sh delegates to the installer (single source) ----------------
[ "$(grep -c 'cat > /etc/logrotate.d/anomalies' "$BOOTSTRAP")" = "0" ] \
	&& ok "T7 vps-bootstrap.sh no longer carries its own anomalies logrotate heredoc" \
	|| bad "T7 vps-bootstrap.sh no longer carries its own anomalies logrotate heredoc"
STEP="$(awk '/^step_anomaly_cron\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$BOOTSTRAP")"
grep -qF 'FYD_DEPLOY_USER="$DEPLOY_USER" bash "$DEPLOY_DIR/scripts/install-anomalies-logrotate.sh"' <<<"$STEP" \
	&& ok "T7 step_anomaly_cron runs the installer with the bootstrap's deploy user" \
	|| bad "T7 step_anomaly_cron runs the installer with the bootstrap's deploy user"

# --- T8 logrotate itself parses the generated config (where logrotate exists) ------
# Rendered for the CURRENT user so `create` resolves on any machine; the
# retention stanza is otherwise identical to T1's.
if command -v logrotate >/dev/null 2>&1; then
	mkdir -p "$WORK/t8"
	FYD_LOGROTATE_TARGET="$WORK/t8/anomalies" FYD_LOG_DIR="$LOGD" FYD_DEPLOY_USER="$(id -un)" \
		FYD_BACKUP_DIR="$WORK/t8-backups" bash "$INSTALLER" >/dev/null 2>&1
	LR_OUT="$(logrotate -d -s "$WORK/lr.state" "$WORK/t8/anomalies" 2>&1)"; RC=$?
	[ "$RC" -eq 0 ] && ok "T8 logrotate -d accepts the config" || bad "T8 logrotate -d accepts the config" "$(tail -3 <<<"$LR_OUT")"
else
	skip "T8 logrotate -d" "logrotate not installed here (verified on the validator host at rollout)"
fi

# --- T9 validation runs joined with the host's main config, not standalone --------
# Reproduces the validator host (2026-09-24 fix): the log dir is
# group-writable by a group that is not "root" (/var/log there is
# root:syslog 0775), which logrotate treats as insecure UNLESS a `su`
# directive is in effect. On the host that `su root adm` lives in
# /etc/logrotate.conf's global section, not in this snippet, so a standalone
# `logrotate -d` on the candidate alone false-positives — this is also true
# of the config's `include` line: it must NOT be honored during validation,
# so a broken sibling snippet can never block this installer.
if command -v logrotate >/dev/null 2>&1; then
	mkdir -p "$WORK/t9/log" "$WORK/t9/broken-includes"
	TESTUSER="$(id -un)"
	TESTGRP="$(id -gn)"
	# Must not be "root": logrotate only calls a group-writable dir insecure
	# when the writing group isn't "root", so root's own primary group would
	# defeat the reproduction when this suite runs as root (as the task's
	# docker instructions do).
	[ "$TESTGRP" = "root" ] && TESTGRP="nogroup"

	chmod 0775 "$WORK/t9/log"
	chgrp "$TESTGRP" "$WORK/t9/log"

	# A stanza that fails validation hard (unresolvable create user) if it is
	# ever actually read.
	cat >"$WORK/t9/broken-includes/broken" <<BROKEN
${WORK}/t9/log/does-not-exist-either.log {
  create 644 totally-bogus-nonexistent-user totally-bogus-nonexistent-group
}
BROKEN

	# su targets the CURRENT user, not a literal "root": logrotate can only
	# switch euid/egid to an identity the invoking process can actually hold
	# (a no-op switch to itself, or anything at all if already root). On the
	# real host the daily cron job already runs as root, so its `su root
	# adm` is exactly this same pattern — a same-euid switch plus an egid
	# change to a group root can always assume.
	cat >"$WORK/t9/main.conf" <<MAINCONF
su ${TESTUSER} ${TESTGRP}
weekly
rotate 4
create
compress
include ${WORK}/t9/broken-includes
MAINCONF

	EXPECTED9="$(cat <<CONF
# Managed by scripts/install-anomalies-logrotate.sh — edit the installer, not this file.
# 90-day retention: web-probe design spec 2026-09-24 §3.5 (G5).
${WORK}/t9/log/anomalies.log ${WORK}/t9/log/anomalies-web-diag.log ${WORK}/t9/log/anomalies-web-blips.log {
  daily
  rotate 90
  compress
  missingok
  notifempty
  create 644 ${TESTUSER} ${TESTUSER}
}
CONF
)"

	OUT="$(FYD_LOGROTATE_TARGET="$WORK/t9/anomalies" FYD_LOG_DIR="$WORK/t9/log" FYD_DEPLOY_USER="$TESTUSER" \
		FYD_BACKUP_DIR="$WORK/t9-backups" FYD_LOGROTATE_MAIN_CONF="$WORK/t9/main.conf" bash "$INSTALLER" 2>&1)"; RC=$?
	[ "$RC" -eq 0 ] \
		&& ok "T9 install succeeds on a group-writable log dir whose safety comes only from the main config's su" \
		|| bad "T9 install succeeds on a group-writable log dir whose safety comes only from the main config's su" "rc=$RC $OUT"
	[ "$(cat "$WORK/t9/anomalies" 2>/dev/null)" = "$EXPECTED9" ] \
		&& ok "T9 installed snippet is still exactly the 90-day contract (validation context change doesn't alter it)" \
		|| bad "T9 installed snippet is still exactly the 90-day contract" "$(diff <(printf '%s\n' "$EXPECTED9") "$WORK/t9/anomalies" 2>&1 | head -5)"
	for name in anomalies-web-diag.log anomalies-web-blips.log; do
		[ -f "$WORK/t9/log/$name" ] \
			&& ok "T9 ${name} provisioned" \
			|| bad "T9 ${name} provisioned"
	done

	# Proof this scenario is real, not vacuous: the exact installed candidate,
	# checked fully standalone (no main config at all), must fail on this
	# group-writable dir — otherwise T9 passing would prove nothing about the
	# fix. logrotate's insecure-permissions check is skipped when the
	# checking process is itself a member of the directory's group (no
	# escalation risk), so this only reproduces when run as root: root has
	# no such membership in a group it didn't create for itself (e.g.
	# "nogroup"), which is exactly why the real host — root's cron running
	# logrotate against a syslog-group /var/log — needs the main config's
	# `su` at all. Non-root can't construct that condition (chgrp to a
	# foreign group requires root), so it's skipped rather than asserted.
	if [ "$(id -u)" -eq 0 ]; then
		if logrotate -d -s "$WORK/t9-standalone.state" "$WORK/t9/anomalies" >/tmp/t9-standalone.out 2>&1; then
			bad "T9 sanity: the installed candidate is insecure when checked standalone (no su in scope)" \
				"expected logrotate -d to fail standalone but it passed"
		else
			ok "T9 sanity: the installed candidate is insecure when checked standalone (no su in scope) — proves T9's join is doing real work"
		fi
	else
		skip "T9 sanity: standalone-insecure reproduction" "needs root (non-root is always a member of its own group, so it can't construct a foreign-group-writable dir)"
	fi

	# Proof the include line was not honored: had it been read, the broken
	# sibling snippet above would fail validation hard. Build that "include
	# honored" variant by hand (the installer's own logic must NOT do this)
	# and confirm it fails, which — together with T9's rc=0 above — proves
	# the installer skipped it.
	cat "$WORK/t9/main.conf" "$WORK/t9/anomalies" >"$WORK/t9-include-honored.conf"
	if logrotate -d -s "$WORK/t9-include-honored.state" "$WORK/t9-include-honored.conf" >/tmp/t9-include-honored.out 2>&1; then
		bad "T9 include line was not honored during validation" \
			"expected the broken included snippet to fail validation if it were ever read, but it passed"
	else
		ok "T9 include line was not honored during validation (the installer's own run above succeeded only because it drops include lines)"
	fi
else
	skip "T9 validation joined with main config" "logrotate not installed here (verified on the validator host at rollout)"
fi

echo "test-install-anomalies-logrotate.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
