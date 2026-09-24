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

# --- T9/T10/T11: validation is joined with the host's main config POSITIONALLY ----
# Reproduces the validator host (2026-09-24 fix, round 1): the log dir is
# group-writable by a group that is not "root" (/var/log there is
# root:syslog 0775), which logrotate treats as insecure UNLESS a `su`
# directive is in effect. On the host that `su root adm` lives in
# /etc/logrotate.conf's global section, BEFORE its `include /etc/logrotate.d`
# — and logrotate applies directives top-to-bottom, so only what precedes an
# `include` applies to what it pulls in. T9 is the "found, before" case
# (must pass); T10 moves `su` to AFTER the include (must fail, matching real
# logrotate); T11 adds a trailing broken stanza after the include (must not
# affect validation, since it's never in scope either).
#
# All three share one sandbox shape: <base>/log (group-writable, the log
# dir) and <base>/logrotate.d (the directory the candidate is installed
# into AND that the main config's `include` names — mirroring
# /var/log + /etc/logrotate.d exactly), with a broken sibling snippet
# pre-seeded in <base>/logrotate.d so a real `include` of that directory
# would fail hard.
t9_family_setup() {
	base="$WORK/$1"
	mkdir -p "$base/log" "$base/logrotate.d"
	TESTUSER="$(id -un)"
	TESTGRP="$(id -gn)"
	# Must not be "root": logrotate only calls a group-writable dir insecure
	# when the writing group isn't "root", so root's own primary group would
	# defeat the reproduction when this suite runs as root (as the task's
	# docker instructions do).
	[ "$TESTGRP" = "root" ] && TESTGRP="nogroup"
	chmod 0775 "$base/log"
	chgrp "$TESTGRP" "$base/log"
	# A sibling stanza that fails validation hard (unresolvable create user)
	# if the directory it lives in is ever actually included.
	cat >"$base/logrotate.d/broken" <<BROKEN
${base}/log/does-not-exist-either.log {
  create 644 totally-bogus-nonexistent-user totally-bogus-nonexistent-group
}
BROKEN
}

t9_family_expected() {
	cat <<CONF
# Managed by scripts/install-anomalies-logrotate.sh — edit the installer, not this file.
# 90-day retention: web-probe design spec 2026-09-24 §3.5 (G5).
${1}/log/anomalies.log ${1}/log/anomalies-web-diag.log ${1}/log/anomalies-web-blips.log {
  daily
  rotate 90
  compress
  missingok
  notifempty
  create 644 ${2} ${2}
}
CONF
}

if command -v logrotate >/dev/null 2>&1; then
	# === T9: su BEFORE the include of the candidate's directory → PASS ===
	t9_family_setup t9
	# su targets the CURRENT user, not a literal "root": logrotate can only
	# switch euid/egid to an identity the invoking process can actually hold
	# (a no-op switch to itself, or anything at all if already root). On the
	# real host the daily cron job already runs as root, so its `su root
	# adm` is exactly this same pattern.
	cat >"$base/main.conf" <<MAINCONF
su ${TESTUSER} ${TESTGRP}
weekly
rotate 4
create
compress
include ${base}/logrotate.d
MAINCONF
	EXPECTED9="$(t9_family_expected "$base" "$TESTUSER")"

	OUT="$(FYD_LOGROTATE_TARGET="$base/logrotate.d/anomalies" FYD_LOG_DIR="$base/log" FYD_DEPLOY_USER="$TESTUSER" \
		FYD_BACKUP_DIR="$WORK/t9-backups" FYD_LOGROTATE_MAIN_CONF="$base/main.conf" bash "$INSTALLER" 2>&1)"; RC=$?
	[ "$RC" -eq 0 ] \
		&& ok "T9 (su before include) install succeeds on a group-writable log dir whose safety comes only from the main config's su" \
		|| bad "T9 (su before include) install succeeds" "rc=$RC $OUT"
	[ "$(cat "$base/logrotate.d/anomalies" 2>/dev/null)" = "$EXPECTED9" ] \
		&& ok "T9 installed snippet is still exactly the 90-day contract (validation context change doesn't alter it)" \
		|| bad "T9 installed snippet is still exactly the 90-day contract" "$(diff <(printf '%s\n' "$EXPECTED9") "$base/logrotate.d/anomalies" 2>&1 | head -5)"
	for name in anomalies-web-diag.log anomalies-web-blips.log; do
		[ -f "$base/log/$name" ] && ok "T9 ${name} provisioned" || bad "T9 ${name} provisioned"
	done

	# Proof this scenario is real, not vacuous: the exact installed candidate,
	# checked fully standalone (no main config at all), must fail on this
	# group-writable dir. Root-only: logrotate's insecure-permissions check
	# is skipped when the checking process is itself a member of the
	# directory's group (no escalation risk), so a non-root process can
	# never construct a directory whose group it isn't a member of (chgrp to
	# a foreign group requires root) — verified empirically, not assumed.
	if [ "$(id -u)" -eq 0 ]; then
		if logrotate -d -s "$WORK/t9-standalone.state" "$base/logrotate.d/anomalies" >/tmp/t9-standalone.out 2>&1; then
			bad "T9 sanity: the installed candidate is insecure when checked standalone (no su in scope)" \
				"expected logrotate -d to fail standalone but it passed"
		else
			ok "T9 sanity: the installed candidate is insecure when checked standalone (no su in scope) — proves T9's join is doing real work"
		fi
	else
		skip "T9 sanity: standalone-insecure reproduction" "needs root (non-root is always a member of its own group, so it can't construct a foreign-group-writable dir)"
	fi

	# Proof the include was not honored: the candidate is now physically
	# installed in the SAME directory as the pre-seeded broken sibling, so
	# running logrotate natively on the real main.conf (which does contain a
	# real `include` of that directory) exercises actual logrotate
	# semantics, not a hand-built approximation. It must fail — and since
	# the installer's own run above (rc=0) used the identical main.conf and
	# succeeded, that proves its join never let the include take effect.
	if logrotate -d -s "$WORK/t9-native-include.state" "$base/main.conf" >/tmp/t9-native-include.out 2>&1; then
		bad "T9 include line was not honored during validation" \
			"expected a native logrotate run on the real main.conf (which does include the broken sibling) to fail, but it passed"
	else
		ok "T9 include line was not honored during validation (native run on the real main.conf, which does include the broken sibling, fails; the installer's own run above used the same main.conf and succeeded)"
	fi

	# === T10: su AFTER the include of the candidate's directory → FAIL, nothing installed ===
	# Root-only, for the same reason as the "T9 sanity" check above: this
	# scenario's failure mode IS the insecure-permissions check, which
	# logrotate skips whenever the checking process is itself a member of
	# the directory's group. A non-root process's own primary group is
	# always "trusted" that way, so a non-root run of this exact scenario
	# would validate successfully with or without su in scope, before or
	# after the include — it would prove nothing about position. Verified
	# empirically (see the "Fix round 1" section of the SDD report), not
	# assumed.
	if [ "$(id -u)" -eq 0 ]; then
		t9_family_setup t10
		cat >"$base/main.conf" <<MAINCONF
weekly
rotate 4
create
compress
include ${base}/logrotate.d
su ${TESTUSER} ${TESTGRP}
MAINCONF

		OUT="$(FYD_LOGROTATE_TARGET="$base/logrotate.d/anomalies" FYD_LOG_DIR="$base/log" FYD_DEPLOY_USER="$TESTUSER" \
			FYD_BACKUP_DIR="$WORK/t10-backups" FYD_LOGROTATE_MAIN_CONF="$base/main.conf" bash "$INSTALLER" 2>&1)"; RC=$?
		[ "$RC" -eq 4 ] \
			&& ok "T10 (su AFTER include) install refuses (exit 4) — matches real logrotate, which never applies a directive placed after the include to files it pulls in" \
			|| bad "T10 (su AFTER include) install refuses (exit 4)" "rc=$RC $OUT"
		[ ! -e "$base/logrotate.d/anomalies" ] \
			&& ok "T10 nothing installed" \
			|| bad "T10 nothing installed" "found $base/logrotate.d/anomalies"
		for name in anomalies-web-diag.log anomalies-web-blips.log; do
			[ ! -e "$base/log/$name" ] \
				&& ok "T10 ${name} NOT provisioned (validation failed before provisioning)" \
				|| bad "T10 ${name} NOT provisioned" "found $base/log/$name"
		done
	else
		skip "T10 (su AFTER include) install refuses (exit 4)" "needs root (non-root is always a member of its own group, so the group-writable dir here is never actually insecure to it, with or without su)"
		skip "T10 nothing installed" "needs root (see above)"
		for name in anomalies-web-diag.log anomalies-web-blips.log; do
			skip "T10 ${name} NOT provisioned" "needs root (see above)"
		done
	fi

	# === T11: su BEFORE include, but a broken stanza AFTER include → PASS, unaffected ===
	t9_family_setup t11
	cat >"$base/main.conf" <<MAINCONF
su ${TESTUSER} ${TESTGRP}
weekly
rotate 4
create
compress
include ${base}/logrotate.d
${base}/log/some-other-host-log-does-not-exist.log {
  create 644 totally-bogus-nonexistent-user totally-bogus-nonexistent-group
}
MAINCONF
	EXPECTED11="$(t9_family_expected "$base" "$TESTUSER")"

	OUT="$(FYD_LOGROTATE_TARGET="$base/logrotate.d/anomalies" FYD_LOG_DIR="$base/log" FYD_DEPLOY_USER="$TESTUSER" \
		FYD_BACKUP_DIR="$WORK/t11-backups" FYD_LOGROTATE_MAIN_CONF="$base/main.conf" bash "$INSTALLER" 2>&1)"; RC=$?
	[ "$RC" -eq 0 ] \
		&& ok "T11 (broken inline stanza after include) install succeeds — the trailing stanza is never in scope" \
		|| bad "T11 install succeeds despite a broken inline stanza after the include" "rc=$RC $OUT"
	[ "$(cat "$base/logrotate.d/anomalies" 2>/dev/null)" = "$EXPECTED11" ] \
		&& ok "T11 installed snippet is still exactly the 90-day contract" \
		|| bad "T11 installed snippet is still exactly the 90-day contract" "$(diff <(printf '%s\n' "$EXPECTED11") "$base/logrotate.d/anomalies" 2>&1 | head -5)"
	for name in anomalies-web-diag.log anomalies-web-blips.log; do
		[ -f "$base/log/$name" ] && ok "T11 ${name} provisioned" || bad "T11 ${name} provisioned"
	done
	# Proof the trailing stanza is real (not vacuously harmless): a native
	# run on the real main.conf (broken trailing stanza included) must fail.
	if logrotate -d -s "$WORK/t11-native.state" "$base/main.conf" >/tmp/t11-native.out 2>&1; then
		bad "T11 sanity: the trailing broken stanza would fail validation if it were in scope" \
			"expected a native logrotate run on the real main.conf to fail, but it passed"
	else
		ok "T11 sanity: the trailing broken stanza would fail validation if it were in scope — proves T11's exclusion of it is doing real work"
	fi
else
	skip "T9/T10/T11 validation joined with main config" "logrotate not installed here (verified on the validator host at rollout)"
fi

echo "test-install-anomalies-logrotate.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
