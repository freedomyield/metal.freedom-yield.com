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

echo "test-install-anomalies-logrotate.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
