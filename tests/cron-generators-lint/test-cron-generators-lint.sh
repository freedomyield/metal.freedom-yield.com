#!/usr/bin/env bash
# test-cron-generators-lint.sh — proves every repo cron-content generator
# produces output that passes scripts/check-cron-file.sh in full (H2 task,
# 2026-08-06).
#
# Why this exists: the design spec (docs/superpowers/specs/
# 2026-08-06-single-source-of-truth-design.md §8) relies on check-cron-file.sh
# being a binary, always-green gate ("9 本の installer が必ず通る経路"). A
# same-day production audit found the opposite — 11 of 16 deployed files
# violated Rule 3, and the repo's OWN generators (scripts/vps-bootstrap.sh
# in particular) would have reproduced the defect on a fresh install,
# because check-cron-file.sh had never actually been run against their
# output. This suite closes that gap once, for every generator, instead of
# leaving it to each installer's own (partial, inconsistent) test coverage.
#
# CHAIN: none — every generator below is invoked in test-harness mode
#        (tempdir targets / synthetic fake repos via each installer's own
#        FYD_* override, or — for the two installers with no override at
#        all — by extracting and rendering their heredoc in an isolated
#        subshell, the exact technique tests/anchor-publish-health/
#        test-install-metal-anchor-publish-health-cron.sh already uses).
#        /etc/cron.d is never touched, and no file inside this checkout is
#        ever mutated (every FYD_REPO_DIR / FYD_REPO_PATH below points at
#        either a synthetic tmp fake-repo, or — read-only existence checks
#        only, never a write target — this checkout's own REPO_ROOT).
#
# Usage:
#   bash tests/cron-generators-lint/test-cron-generators-lint.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-cron-file.sh"
BOOTSTRAP="${REPO_ROOT}/scripts/vps-bootstrap.sh"

if [ ! -x "$CHECKER" ]; then
	echo "FATAL: checker not found/executable at $CHECKER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

WORK="$(mktemp -d -t cron-gen-lint-test.XXXXXX)"
teardown() { rm -rf "$WORK"; }
trap teardown EXIT

lint_file_is_clean() {
	# $1 = label, $2 = path to a candidate cron file
	local label="$1" f="$2" out rc
	out="$(bash "$CHECKER" "$f" 2>&1)"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		ok "lint: ${label} passes check-cron-file.sh (exit 0)"
	else
		bad "lint: ${label} passes check-cron-file.sh (exit 0) — actual rc=$rc, out:
$out"
	fi
}

# =============================================================================
# Group A: scripts/vps-bootstrap.sh's 4 embedded generators. No FYD_*
# override exists (curl-piped bootstrap script, always writes real
# /etc/cron.d/ + touches real /var/log/ as root) — so each heredoc BODY is
# extracted verbatim (between its `cat > /etc/cron.d/<name> <<EOF` line and
# the matching bare `EOF`) and rendered in an isolated subshell with
# DEPLOY_USER/DEPLOY_DIR set, exactly as the real function would interpolate
# them, minus the root-only write/chown/systemctl side effects.
# =============================================================================

extract_heredoc_body() {
	# $1 = cron basename (e.g. metal-server-status) -> prints the heredoc body
	local name="$1"
	awk -v pat="cat > /etc/cron.d/${name} <<EOF" \
		'index($0, pat){flag=1; next} flag && /^EOF$/{exit} flag{print}' \
		"$BOOTSTRAP"
}

render_bootstrap_cron() {
	# $1 = cron basename -> prints the rendered cron file content on stdout
	local name="$1" body render
	body="$(extract_heredoc_body "$name")"
	render="$(mktemp -p "$WORK")"
	{
		printf '#!/usr/bin/env bash\nset -euo pipefail\n'
		printf 'DEPLOY_USER="deploy"\nDEPLOY_DIR="/home/deploy/metal.freedom-yield.com"\n'
		printf 'cat <<EOF\n'
		printf '%s\n' "$body"
		printf 'EOF\n'
	} > "$render"
	bash "$render"
}

for name in metal-server-status metal-node-info metal-daily-status metal-anomalies; do
	BODY="$(extract_heredoc_body "$name")"
	[ -n "$BODY" ] \
		&& ok "extract: found the ${name} heredoc in scripts/vps-bootstrap.sh" \
		|| bad "extract: found the ${name} heredoc in scripts/vps-bootstrap.sh"

	OUT="$WORK/${name}"
	render_bootstrap_cron "$name" > "$OUT" 2>"$WORK/${name}.err"
	RC=$?
	[ "$RC" -eq 0 ] && [ ! -s "$WORK/${name}.err" ] \
		&& ok "render: ${name} heredoc renders cleanly (no stderr, rc=0)" \
		|| bad "render: ${name} heredoc renders cleanly (rc=$RC, stderr: $(cat "$WORK/${name}.err" 2>/dev/null))"

	lint_file_is_clean "vps-bootstrap.sh:${name}" "$OUT"
done

# ---- mutation check: the pre-fix shape (real production defect, quoted
# verbatim in the H2 brief) must FAIL lint — proves the detector actually
# catches the defect this generator fix closes, i.e. "revert one generator
# -> lint goes red".
cat > "$WORK/mutation-pre-fix-node-info" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
*/5 * * * * deploy cd /home/deploy/metal.freedom-yield.com && bash scripts/node-info.sh && bash scripts/push-to-web-host.sh validator.json >> /var/log/node-info.log 2>&1
EOF
bash "$CHECKER" "$WORK/mutation-pre-fix-node-info" >"$WORK/mutation.out" 2>&1
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "mutation: pre-fix metal-node-info shape (no markers, un-braced chain) fails lint" \
	|| bad "mutation: pre-fix metal-node-info shape fails lint (actual rc=$RC)"
grep -q 'found a chain that redirects only the last command' "$WORK/mutation.out" \
	&& ok "mutation: failure is specifically Rule 2 (un-braced chain), matching the cited defect" \
	|| bad "mutation: failure is specifically Rule 2 (out: $(cat "$WORK/mutation.out"))"

# =============================================================================
# Group B: standalone scripts/install-*-cron.sh installers that already
# support a test-harness target override. Run for real against a tempdir /
# synthetic fake repo (never this checkout's real files), then lint the
# result.
# =============================================================================

# ---- install-watch-cron.sh --------------------------------------------------
WATCH_OUT="$WORK/watch-cron-file"
FYD_CRON_FILE="$WATCH_OUT" FYD_BACKUP_DIR="$WORK/watch-backups" FYD_REPO_DIR="$WORK/watch-fake-repo" \
	bash "${REPO_ROOT}/scripts/install-watch-cron.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && [ -f "$WATCH_OUT" ] \
	&& ok "generate: install-watch-cron.sh writes a candidate file" \
	|| bad "generate: install-watch-cron.sh writes a candidate file (rc=$RC)"
lint_file_is_clean "install-watch-cron.sh" "$WATCH_OUT"

# ---- install-anchor-watch-alert-only.sh -------------------------------------
AW_FAKE_REPO="$WORK/anchor-watch-fake-repo"
mkdir -p "$AW_FAKE_REPO/scripts"
printf '#!/usr/bin/env bash\ntrue\n' > "$AW_FAKE_REPO/scripts/notify-anchor-transition.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$AW_FAKE_REPO/scripts/notify.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$AW_FAKE_REPO/scripts/watch-anchor-events.sh"
chmod +x "$AW_FAKE_REPO/scripts/notify.sh"
AW_OUT="$WORK/anchor-watch-cron-file"
REPO="$AW_FAKE_REPO" FYD_ANCHOR_WATCH_CRON="$AW_OUT" \
	bash "${REPO_ROOT}/scripts/install-anchor-watch-alert-only.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && [ -f "$AW_OUT" ] \
	&& ok "generate: install-anchor-watch-alert-only.sh writes a candidate file" \
	|| bad "generate: install-anchor-watch-alert-only.sh writes a candidate file (rc=$RC)"
lint_file_is_clean "install-anchor-watch-alert-only.sh" "$AW_OUT"

# ---- install-metal-host-drift-cron.sh (REPO_PATH is read-only-checked
# against this checkout's real scripts/check-host-drift.sh; nothing is
# written there) --------------------------------------------------------------
HD_OUT="$WORK/host-drift-cron-file"
FYD_CRON_TARGET="$HD_OUT" FYD_REPO_PATH="$REPO_ROOT" FYD_BACKUP_DIR="$WORK/hd-backups" \
	bash "${REPO_ROOT}/scripts/install-metal-host-drift-cron.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && [ -f "$HD_OUT" ] \
	&& ok "generate: install-metal-host-drift-cron.sh writes a candidate file" \
	|| bad "generate: install-metal-host-drift-cron.sh writes a candidate file (rc=$RC)"
lint_file_is_clean "install-metal-host-drift-cron.sh" "$HD_OUT"

# ---- install-metal-host-advance-cron.sh --------------------------------------
HA_OUT="$WORK/host-advance-cron-file"
FYD_CRON_TARGET="$HA_OUT" FYD_REPO_PATH="$REPO_ROOT" FYD_BACKUP_DIR="$WORK/ha-backups" \
	bash "${REPO_ROOT}/scripts/install-metal-host-advance-cron.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && [ -f "$HA_OUT" ] \
	&& ok "generate: install-metal-host-advance-cron.sh writes a candidate file" \
	|| bad "generate: install-metal-host-advance-cron.sh writes a candidate file (rc=$RC)"
lint_file_is_clean "install-metal-host-advance-cron.sh" "$HA_OUT"

# ---- install-metal-identity-pins-cron.sh -------------------------------------
IP_OUT="$WORK/identity-pins-cron-file"
FYD_CRON_TARGET="$IP_OUT" FYD_REPO_PATH="$REPO_ROOT" FYD_BACKUP_DIR="$WORK/ip-backups" \
	bash "${REPO_ROOT}/scripts/install-metal-identity-pins-cron.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && [ -f "$IP_OUT" ] \
	&& ok "generate: install-metal-identity-pins-cron.sh writes a candidate file" \
	|| bad "generate: install-metal-identity-pins-cron.sh writes a candidate file (rc=$RC)"
lint_file_is_clean "install-metal-identity-pins-cron.sh" "$IP_OUT"

# ---- install-metal-pulsevm-watch-cron.sh --------------------------------------
PV_OUT="$WORK/pulsevm-watch-cron-file"
FYD_CRON_TARGET="$PV_OUT" FYD_REPO_PATH="$REPO_ROOT" FYD_BACKUP_DIR="$WORK/pv-backups" \
	bash "${REPO_ROOT}/scripts/install-metal-pulsevm-watch-cron.sh" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && [ -f "$PV_OUT" ] \
	&& ok "generate: install-metal-pulsevm-watch-cron.sh writes a candidate file" \
	|| bad "generate: install-metal-pulsevm-watch-cron.sh writes a candidate file (rc=$RC)"
lint_file_is_clean "install-metal-pulsevm-watch-cron.sh" "$PV_OUT"
# Rule 6 is satisfied here DYNAMICALLY, not by an allowlist entry:
# check-pulsevm-upstream.sh sources scripts/lib/side-effects.sh, so
# check-cron-file.sh resolves it as side-effecting on its own. Assert both
# halves — that the generated file carries FY_LIVE=1, and that the linter
# names this script as the reason — so a future refactor that stops sourcing
# the lib cannot quietly turn Rule 6 into a no-op for this cron.
grep -qE '^FY_LIVE=1$' "$PV_OUT" \
	&& ok "install-metal-pulsevm-watch-cron.sh: env header carries FY_LIVE=1" \
	|| bad "install-metal-pulsevm-watch-cron.sh: env header missing FY_LIVE=1"
bash "$CHECKER" "$PV_OUT" 2>&1 | grep -q 'FY_LIVE=1 present (required by:.*check-pulsevm-upstream.sh' \
	&& ok "install-metal-pulsevm-watch-cron.sh: Rule 6 detects the checker dynamically (no allowlist entry needed)" \
	|| bad "install-metal-pulsevm-watch-cron.sh: Rule 6 did not name check-pulsevm-upstream.sh as the reason"

# =============================================================================
# Group C: install-metal-anchor-publish-health-cron.sh — no FYD_* override
# at all (always root, always /etc/cron.d/metal-anchor-publish-health), so
# extract + render its `read -r -d '' EXPECTED <<CRON ... CRON` heredoc the
# same way its own dedicated test does.
# =============================================================================

AH_INSTALLER="${REPO_ROOT}/scripts/install-metal-anchor-publish-health-cron.sh"
AH_HEREDOC="$WORK/ah-heredoc-block.sh"
awk '/<<CRON/{flag=1} flag{print} /^CRON$/{if (flag && NR>1) exit}' "$AH_INSTALLER" > "$AH_HEREDOC"
[ -s "$AH_HEREDOC" ] \
	&& ok "extract: found the EXPECTED heredoc in install-metal-anchor-publish-health-cron.sh" \
	|| bad "extract: found the EXPECTED heredoc in install-metal-anchor-publish-health-cron.sh"

AH_RENDER="$WORK/ah-render.sh"
{
	printf '#!/usr/bin/env bash\nset -euo pipefail\n'
	printf 'REPO_PATH="/home/deploy/metal.freedom-yield.com"\n'
	cat "$AH_HEREDOC"
	printf 'printf "%%s\\n" "$EXPECTED"\n'
} > "$AH_RENDER"
AH_OUT="$WORK/anchor-publish-health-cron-file"
bash "$AH_RENDER" > "$AH_OUT" 2>"$WORK/ah-render.err"
RC=$?
[ "$RC" -eq 0 ] && [ ! -s "$WORK/ah-render.err" ] \
	&& ok "render: install-metal-anchor-publish-health-cron.sh heredoc renders cleanly" \
	|| bad "render: install-metal-anchor-publish-health-cron.sh heredoc renders cleanly (rc=$RC, stderr: $(cat "$WORK/ah-render.err" 2>/dev/null))"
lint_file_is_clean "install-metal-anchor-publish-health-cron.sh" "$AH_OUT"

# ---- summary ------------------------------------------------------------------
echo "test-cron-generators-lint.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
