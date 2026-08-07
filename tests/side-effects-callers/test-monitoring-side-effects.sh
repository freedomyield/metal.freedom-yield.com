#!/usr/bin/env bash
# tests/side-effects-callers/test-monitoring-side-effects.sh
#
# C3-2a acceptance suite: the seven MONITORING callers of
# scripts/lib/side-effects.sh must be dry by default and gated by
# construction.
#
#   scripts/check-anomalies.sh          scripts/daily-status.sh
#   scripts/anomaly-state-init.sh       scripts/node-health-daily.sh
#   scripts/check-watch-validators.sh   scripts/notify-evidence-health.sh
#   scripts/check-host-drift.sh
#
# CHAIN: none — no case reaches a broadcast-capable command.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction at all).
#
# ---------------------------------------------------------------------------
# WHY THIS SUITE DOES NOT STUB notify.sh
# ---------------------------------------------------------------------------
# The point of the C3 inversion is that a caller is inert WITHOUT anyone
# remembering to stub it. A suite that pointed FYD_NOTIFY at a recording stub
# would therefore prove nothing about the property under test: it would pass
# just as happily against the old opt-out code.
#
# So every sandbox here contains the REAL scripts/notify.sh and the REAL
# scripts/push-to-web-host.sh, a readable NTFY_TOPIC_FILE with a real topic in
# it, and no delegate override at all. The only thing standing between the
# script under test and ntfy.sh is FY_LIVE. What is intercepted instead is one
# level lower: `curl` and `ssh` are replaced on PATH by recording tripwires, so
# "did a real notification leave the machine?" is answered by evidence
# (tripwire content) rather than by assumption.
#
# Part 2 then runs the SAME cases with FY_LIVE=1 and requires the opposite
# outcome — a tripwire hit and a real state mutation. Without Part 2, Part 1
# would be satisfied by a script that is simply broken.
#
# ---------------------------------------------------------------------------
# PATH stand-ins (all test-local; nothing on this machine is modified)
# ---------------------------------------------------------------------------
#   curl   records argv, passes file:// URLs through to the real curl,
#          answers ntfy.sh with HTTP 200, fails everything else like an
#          unreachable host.
#   ssh    records argv, fails.
#   flock  only when the host has none (macOS). Always reports success; it
#          does NOT implement locking. Real contention semantics live in
#          tests/anomalies/integration-linux.sh, which only runs where flock
#          is real.
#   date   only when the host `date` cannot do GNU `-d` and gdate exists —
#          it execs the real gdate binary. When neither is available the
#          GNU-date-dependent cases SKIP rather than pretend.
#
# Usage:
#   bash tests/side-effects-callers/test-monitoring-side-effects.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

# SC2016: several patterns keep $VAR unexpanded on purpose (they are grep
#         expressions matching shell source, not values to interpolate).
# shellcheck disable=SC2016

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="${REPO_ROOT}/scripts"
LIB="${SCRIPTS}/lib/side-effects.sh"

TARGETS="check-anomalies.sh anomaly-state-init.sh check-watch-validators.sh check-host-drift.sh daily-status.sh node-health-daily.sh notify-evidence-health.sh"

for f in $TARGETS; do
	if [ ! -r "${SCRIPTS}/${f}" ]; then
		echo "FATAL: expected file missing: ${SCRIPTS}/${f}" >&2
		exit 1
	fi
done
if [ ! -r "$LIB" ]; then
	echo "FATAL: expected file missing: $LIB" >&2
	exit 1
fi

PASS=0
FAIL=0
SKIP=0
FAILURES=()
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILURES+=("$1${2:+ — $2}"); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}" >&2; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s%s\n' "$1" "${2:+ — $2}"; }

TMP="$(mktemp -d -t fy-c32a-callers.XXXXXX)"
cleanup() { chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

BIN="${TMP}/bin"
mkdir -p "$BIN"
TRIPWIRE="${TMP}/tripwire.log"
: >"$TRIPWIRE"

REAL_CURL="$(command -v curl || true)"
if [ -z "$REAL_CURL" ]; then
	echo "FATAL: curl not on PATH" >&2
	exit 1
fi

cat >"${BIN}/curl" <<CURLEOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"${TRIPWIRE}"
for a in "\$@"; do
	case "\$a" in
		file://*) exec "${REAL_CURL}" "\$@" ;;
	esac
done
for a in "\$@"; do
	case "\$a" in
		https://ntfy.sh/*) printf '200'; exit 0 ;;
	esac
done
exit 7
CURLEOF
chmod +x "${BIN}/curl"

cat >"${BIN}/ssh" <<SSHEOF
#!/usr/bin/env bash
printf 'ssh %s\n' "\$*" >>"${TRIPWIRE}"
exit 7
SSHEOF
chmod +x "${BIN}/ssh"

FLOCK_NOTE=""
if ! command -v flock >/dev/null 2>&1; then
	cat >"${BIN}/flock" <<'FLOCKEOF'
#!/usr/bin/env bash
# Test-local stand-in for util-linux flock. Always reports "acquired"; it does
# NOT implement locking. See this suite's header.
exit 0
FLOCKEOF
	chmod +x "${BIN}/flock"
	FLOCK_NOTE=" (flock stand-in in use)"
fi

GNU_DATE=1
if ! date -u -d '@0' +%s >/dev/null 2>&1; then
	if command -v gdate >/dev/null 2>&1; then
		printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(command -v gdate)" >"${BIN}/date"
		chmod +x "${BIN}/date"
	else
		GNU_DATE=0
	fi
fi

export PATH="${BIN}:${PATH}"

ntfy_hits() { grep -c 'ntfy\.sh' "$TRIPWIRE" 2>/dev/null | tr -d '[:space:]'; }
reset_tripwire() { : >"$TRIPWIRE"; }
hashof() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# mk_repo <name> <script.sh>...
#   Builds a self-contained sandbox repo whose scripts/ holds the REAL
#   side-effects library, the REAL notify.sh and push-to-web-host.sh, and the
#   named scripts under test. Sets $S to its path.
mk_repo() {
	local name="$1"; shift
	S="${TMP}/${name}"
	mkdir -p "${S}/scripts/lib" "${S}/public/api" "${S}/logs"
	# Mirror scripts/lib/ as a WHOLE DIRECTORY, not a hand-picked file. Naming
	# just side-effects.sh here is exactly the bug that broke the sibling
	# suites when push-to-web-host.sh grew a second hard dependency,
	# scripts/lib/publish-scan.sh, during the C3 integration (task h5,
	# 2026-08-07): the real repo ships scripts/lib/ as one git-tracked unit,
	# so the sandbox must carry it the same way — as a unit — or the NEXT
	# scripts/lib/*.sh addition silently repeats this failure here too (this
	# suite happened not to trip on it only because none of its callers
	# actually invoke push-to-web-host.sh at runtime). See the
	# mirrored-growth regression guard near the end of this file.
	cp -R "${SCRIPTS}/lib/." "${S}/scripts/lib/"
	cp "${SCRIPTS}/notify.sh" "${S}/scripts/notify.sh"
	cp "${SCRIPTS}/push-to-web-host.sh" "${S}/scripts/push-to-web-host.sh"
	# publish-scan.sh (mirrored above) requires this SIBLING of lib/ at
	# runtime — see FYD_PUBLISH_SCAN_GUARD in scripts/lib/publish-scan.sh.
	# Named explicitly, like notify.sh and push-to-web-host.sh above, because
	# it is a top-level delegate script, not a scripts/lib/ member.
	cp "${SCRIPTS}/publish-guard.sh" "${S}/scripts/publish-guard.sh"
	local s
	for s in "$@"; do cp "${SCRIPTS}/${s}" "${S}/scripts/${s}"; done
	printf 'sandbox-topic-not-a-real-topic\n' >"${S}/topic"
}

status_fixture() {   # <path> <metalgo container status>
	cat >"$1" <<JSON
{
  "observedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "metalgo": { "containerStatus": "$2", "peerCount": 120, "pChainHeight": 1, "cChainHeight": 2 },
  "caddy":   { "containerStatus": "running" },
  "host": {
    "load":   { "1m": 0.1, "5m": 0.2, "15m": 0.3 },
    "uptimeSec": 1000,
    "cpu":    { "usedPercent": 15 },
    "memory": { "usedPercent": 30, "totalKB": 16000000, "usedKB":  4800000 },
    "disk":   { "usedPercent": 40, "totalKB": 500000000, "usedKB": 200000000 }
  }
}
JSON
}

validator_fixture() {
	printf '%s\n' '{ "nodeId": "NodeID-sandbox", "uptime": { "network": "99.0000" }, "stake": { "self": 12600, "totalReceived": 0 }, "endTime": 4102444800, "bootstrap": { "pChain": true, "xChain": true, "cChain": true } }' >"$1"
}

anomaly_state_fixture() {
	# web/api_freshness start at "warn" so the 30s web re-probe and the
	# api_freshness branch are skipped: this case is about the metalgo
	# transition, and a sleeping test is a bad test.
	cat >"$1" <<'JSON'
{
  "metalgo": "running",
  "caddy": "running",
  "disk": "ok",
  "memory": "ok",
  "peers": "ok",
  "web": "warn",
  "api_freshness": "warn",
  "validator_present": "yes",
  "last_known_end_time": null,
  "delegator_count": null,
  "delegator_total_nmetal": null,
  "period_alert_sent": { "7": false, "1": false, "0": false, "10min": false }
}
JSON
}

echo "== Part 1/4: dry by default (no FY_LIVE, no stubs) ==${FLOCK_NOTE}"

# ---- 1a check-anomalies.sh -------------------------------------------------
run_anomalies() {   # <sandbox> [extra env assignments...]
	env "$@" \
		ANOMALY_STATE_DIR="${S}/state" \
		NTFY_TOPIC_FILE="${S}/topic" \
		METALGO_API="http://127.0.0.1:1" \
		WEB_URL="http://127.0.0.1:1" \
		FRESH_REPROBE_SLEEP=0 \
		bash "${S}/scripts/check-anomalies.sh"
}

setup_anomalies() {
	mk_repo "$1" check-anomalies.sh
	mkdir -p "${S}/state/locks"
	anomaly_state_fixture "${S}/state/anomaly-state.json"
	status_fixture "${S}/public/api/server-status.json" stopped
	validator_fixture "${S}/public/api/validator.json"
}

if [ "$GNU_DATE" -eq 0 ]; then
	skip "1a check-anomalies dry" "needs GNU date (-d); install coreutils or run on Linux"
	skip "2a check-anomalies live differential" "needs GNU date (-d)"
else
	setup_anomalies anomalies-dry
	reset_tripwire
	BEFORE_HASH="$(hashof "${S}/state/anomaly-state.json")"
	run_anomalies FY_LIVE= >"${TMP}/1a.out" 2>"${TMP}/1a.err"
	RC=$?
	AFTER_HASH="$(hashof "${S}/state/anomaly-state.json")"

	[ "$RC" -eq 0 ] \
		&& ok "1a check-anomalies: dry run exits 0" \
		|| bad "1a check-anomalies: dry run exits 0" "rc=$RC $(tail -3 "${TMP}/1a.err")"
	grep -q 'DRY: would notify prio=urgent .*title=\[metalgo 停止\]' "${TMP}/1a.err" \
		&& ok "1a check-anomalies: the metalgo alert is announced as suppressed" \
		|| bad "1a check-anomalies: the metalgo alert is announced as suppressed" "$(grep DRY: "${TMP}/1a.err" | head -3)"
	grep -q 'DRY: would commit the advanced anomaly state' "${TMP}/1a.err" \
		&& ok "1a check-anomalies: the state commit is announced as suppressed" \
		|| bad "1a check-anomalies: the state commit is announced as suppressed"
	[ "$BEFORE_HASH" = "$AFTER_HASH" ] \
		&& ok "1a check-anomalies: state file byte-identical after the dry run" \
		|| bad "1a check-anomalies: state file byte-identical after the dry run"
	[ "$(ntfy_hits)" = "0" ] \
		&& ok "1a check-anomalies: nothing reached ntfy.sh" \
		|| bad "1a check-anomalies: nothing reached ntfy.sh" "$(grep 'ntfy\.sh' "$TRIPWIRE" | head -2)"
	[ ! -e "${S}/state/.missing-notified.marker" ] && [ ! -d "${S}/state/quarantine" ] \
		&& ok "1a check-anomalies: no marker / quarantine artefact created" \
		|| bad "1a check-anomalies: no marker / quarantine artefact created"
fi

# ---- 1b anomaly-state-init.sh ---------------------------------------------
mk_repo init-dry anomaly-state-init.sh
mkdir -p "${S}/state/locks"
reset_tripwire
env FY_LIVE= ANOMALY_STATE_DIR="${S}/state" \
	bash "${S}/scripts/anomaly-state-init.sh" --confirm --baseline-status=running \
	>"${TMP}/1b.out" 2>"${TMP}/1b.err"
RC=$?
[ "$RC" -eq 6 ] \
	&& ok "1b anomaly-state-init: refuses with exit 6 instead of running dry" \
	|| bad "1b anomaly-state-init: refuses with exit 6" "rc=$RC"
grep -q 'FY_LIVE=1 is required' "${TMP}/1b.err" \
	&& ok "1b anomaly-state-init: refusal names the missing opt-in" \
	|| bad "1b anomaly-state-init: refusal names the missing opt-in"
grep -q 'FY_LIVE=1 ANOMALY_STATE_DIR=' "${TMP}/1b.err" \
	&& ok "1b anomaly-state-init: refusal prints a corrected command" \
	|| bad "1b anomaly-state-init: refusal prints a corrected command"
[ ! -e "${S}/state/anomaly-state.json" ] \
	&& ok "1b anomaly-state-init: no baseline written" \
	|| bad "1b anomaly-state-init: no baseline written"
[ ! -e "${S}/state/locks/check-anomalies.lock" ] \
	&& ok "1b anomaly-state-init: refused before even opening the lock file" \
	|| bad "1b anomaly-state-init: refused before even opening the lock file"

# ---- 1c check-watch-validators.sh -----------------------------------------
NID="NodeID-testwatch1111111111111111111111111"
setup_watch() {
	mk_repo "$1" check-watch-validators.sh
	mkdir -p "${S}/wstate"
	printf '[\n  "%s"\n]\n' "$NID" >"${S}/watch-list.json"
	printf '[{"nodeId": "%s", "name": "Acme Validator", "delegators": []}]' "$NID" >"${S}/explorer.json"
	# Pre-existing baseline WITHOUT the name, so this run detects a change
	# and wants to notify + advance. (A dry run cannot create a baseline for
	# itself, which is exactly the property under test.)
	printf '{"%s": {"active": true, "name": null, "delegators_count": 0}}' "$NID" >"${S}/wstate/watch-prev-state.json"
}
run_watch() {
	env "$@" \
		WATCH_LIST_FILE="${S}/watch-list.json" \
		WATCH_STATE_DIR="${S}/wstate" \
		EXPLORER_API="file://${S}/explorer.json" \
		EXPLORER_MIN_VALIDATORS=0 \
		NTFY_TOPIC_FILE="${S}/topic" \
		NOTIFY_RETRY_SLEEP=0 \
		bash "${S}/scripts/check-watch-validators.sh"
}

setup_watch watch-dry
reset_tripwire
BEFORE_HASH="$(hashof "${S}/wstate/watch-prev-state.json")"
run_watch FY_LIVE= >"${TMP}/1c.out" 2>"${TMP}/1c.err"
RC=$?
AFTER_HASH="$(hashof "${S}/wstate/watch-prev-state.json")"
[ "$RC" -eq 0 ] \
	&& ok "1c check-watch-validators: dry run exits 0" \
	|| bad "1c check-watch-validators: dry run exits 0" "rc=$RC $(tail -3 "${TMP}/1c.err")"
grep -q 'DRY: would notify prio=low' "${TMP}/1c.err" \
	&& ok "1c check-watch-validators: the batched alert is announced as suppressed" \
	|| bad "1c check-watch-validators: the batched alert is announced as suppressed" "$(grep DRY: "${TMP}/1c.err" | head -3)"
grep -q 'DRY: would write the watch baseline snapshot' "${TMP}/1c.err" \
	&& ok "1c check-watch-validators: the baseline write is announced as suppressed" \
	|| bad "1c check-watch-validators: the baseline write is announced as suppressed"
[ "$BEFORE_HASH" = "$AFTER_HASH" ] \
	&& ok "1c check-watch-validators: baseline byte-identical after the dry run" \
	|| bad "1c check-watch-validators: baseline byte-identical after the dry run"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1c check-watch-validators: nothing reached ntfy.sh" \
	|| bad "1c check-watch-validators: nothing reached ntfy.sh"

# ---- 1d check-host-drift.sh ------------------------------------------------
export GIT_AUTHOR_NAME="FYD Hermetic Test Suite"
export GIT_AUTHOR_EMAIL="fyd-hermetic-test@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)

setup_drift() {
	mk_repo "$1" check-host-drift.sh
	local seed="${S}/seed"
	mkdir -p "${seed}/scripts"
	echo 'echo hello' >"${seed}/scripts/a.sh"
	git -C "$seed" "${GITQ[@]}" init -q -b main
	git -C "$seed" "${GITQ[@]}" add -A
	git -C "$seed" "${GITQ[@]}" commit -qm seed
	git clone -q --bare "$seed" "${S}/origin.git"
	git clone -q "${S}/origin.git" "${S}/clone" 2>/dev/null
	git -C "${S}/clone" "${GITQ[@]}" remote set-url origin "${S}/origin.git"
	# Removing origin makes `git fetch` fail → the default-priority alert path.
	rm -rf "${S}/origin.git"
}

setup_drift drift-dry
reset_tripwire
env FY_LIVE= NTFY_TOPIC_FILE="${S}/topic" FYD_REPO_DIR="${S}/clone" \
	bash "${S}/scripts/check-host-drift.sh" >"${TMP}/1d.out" 2>"${TMP}/1d.err"
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "1d check-host-drift: fetch-failure exit code unchanged (2)" \
	|| bad "1d check-host-drift: fetch-failure exit code unchanged (2)" "rc=$RC"
grep -q 'DRY: would notify prio=default .*host-drift: fetch failed' "${TMP}/1d.err" \
	&& ok "1d check-host-drift: the alert is announced as suppressed" \
	|| bad "1d check-host-drift: the alert is announced as suppressed" "$(grep DRY: "${TMP}/1d.err" | head -3)"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1d check-host-drift: nothing reached ntfy.sh" \
	|| bad "1d check-host-drift: nothing reached ntfy.sh"

# ---- 1e daily-status.sh ----------------------------------------------------
setup_daily() {
	mk_repo "$1" daily-status.sh
	printf '#!/usr/bin/env bash\nexit 0\n' >"${S}/scripts/cycle-gate.sh"
	chmod +x "${S}/scripts/cycle-gate.sh"
	status_fixture "${S}/public/api/server-status.json" running
	validator_fixture "${S}/public/api/validator.json"
}

setup_daily daily-dry
reset_tripwire
env FY_LIVE= NTFY_TOPIC_FILE="${S}/topic" METALGO_RPC="http://127.0.0.1:1" \
	bash "${S}/scripts/daily-status.sh" evening >"${TMP}/1e.out" 2>"${TMP}/1e.err"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "1e daily-status: dry run exits 0" \
	|| bad "1e daily-status: dry run exits 0" "rc=$RC $(tail -3 "${TMP}/1e.err")"
grep -q 'DRY: would notify prio=.*夕方の運用状態' "${TMP}/1e.err" \
	&& ok "1e daily-status: the digest is announced as suppressed" \
	|| bad "1e daily-status: the digest is announced as suppressed" "$(grep DRY: "${TMP}/1e.err" | head -3)"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1e daily-status: nothing reached ntfy.sh" \
	|| bad "1e daily-status: nothing reached ntfy.sh"

# ---- 1f node-health-daily.sh ----------------------------------------------
setup_nodehealth() {
	mk_repo "$1" node-health-daily.sh
	status_fixture "${S}/public/api/server-status.json" running
}
run_nodehealth() {
	env "$@" \
		STATUS_JSON="${S}/public/api/server-status.json" \
		UPTIME_STATE_DIR="${S}/nhstate" \
		METALGO_API="http://127.0.0.1:1" \
		bash "${S}/scripts/node-health-daily.sh"
}

setup_nodehealth nodehealth-dry
reset_tripwire
run_nodehealth FY_LIVE= >"${TMP}/1f.out" 2>"${TMP}/1f.err"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "1f node-health-daily: dry run exits 0" \
	|| bad "1f node-health-daily: dry run exits 0" "rc=$RC $(tail -3 "${TMP}/1f.err")"
grep -q "DRY: would append to today's node-health entry" "${TMP}/1f.err" \
	&& ok "1f node-health-daily: the ledger append is announced as suppressed" \
	|| bad "1f node-health-daily: the ledger append is announced as suppressed" "$(grep DRY: "${TMP}/1f.err" | head -5)"
grep -q 'DRY: would regenerate the public node-health preview' "${TMP}/1f.err" \
	&& ok "1f node-health-daily: the public preview is announced as suppressed" \
	|| bad "1f node-health-daily: the public preview is announced as suppressed"
[ ! -e "${S}/nhstate" ] \
	&& ok "1f node-health-daily: the state dir was not even created" \
	|| bad "1f node-health-daily: the state dir was not even created"
[ ! -e "${S}/public/api/node-health-recent.json" ] && [ ! -e "${S}/public/api/node-health-recent.json.tmp" ] \
	&& ok "1f node-health-daily: no public artefact, not even a stray .tmp" \
	|| bad "1f node-health-daily: no public artefact, not even a stray .tmp"

# ---- 1g notify-evidence-health.sh -----------------------------------------
setup_evhealth() {
	mk_repo "$1" notify-evidence-health.sh
}
run_evhealth() {
	env "$@" \
		NTFY_TOPIC_FILE="${S}/topic" \
		EVIDENCE_URL="http://127.0.0.1:1/api/evidence.json" \
		bash "${S}/scripts/notify-evidence-health.sh"
}

setup_evhealth evhealth-dry
reset_tripwire
run_evhealth FY_LIVE= >"${TMP}/1g.out" 2>"${TMP}/1g.err"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "1g notify-evidence-health: dry push mode exits 0" \
	|| bad "1g notify-evidence-health: dry push mode exits 0" "rc=$RC $(tail -3 "${TMP}/1g.err")"
grep -q 'DRY: would notify prio=high .*evidence health: FAIL' "${TMP}/1g.err" \
	&& ok "1g notify-evidence-health: the push is announced as suppressed" \
	|| bad "1g notify-evidence-health: the push is announced as suppressed" "$(grep DRY: "${TMP}/1g.err" | head -3)"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1g notify-evidence-health: nothing reached ntfy.sh" \
	|| bad "1g notify-evidence-health: nothing reached ntfy.sh"

# --summary mode must be unaffected by FY_LIVE (it has no side effect).
env FY_LIVE= NTFY_TOPIC_FILE="${S}/topic" EVIDENCE_URL="http://127.0.0.1:1/api/evidence.json" \
	bash "${S}/scripts/notify-evidence-health.sh" --summary >"${TMP}/1g2.out" 2>/dev/null
grep -q 'A1 cron rc' "${TMP}/1g2.out" && grep -q 'A3 enriched' "${TMP}/1g2.out" \
	&& ok "1g notify-evidence-health: --summary still prints its 3 rows while dry" \
	|| bad "1g notify-evidence-health: --summary still prints its 3 rows while dry"

echo
echo "== Part 2/4: FY_LIVE=1 differential (proves Part 1 is not vacuous) =="

if [ "$GNU_DATE" -ne 0 ]; then
	setup_anomalies anomalies-live
	reset_tripwire
	BEFORE_HASH="$(hashof "${S}/state/anomaly-state.json")"
	run_anomalies FY_LIVE=1 >"${TMP}/2a.out" 2>"${TMP}/2a.err"
	RC=$?
	AFTER_HASH="$(hashof "${S}/state/anomaly-state.json")"
	[ "$(ntfy_hits)" != "0" ] \
		&& ok "2a check-anomalies: FY_LIVE=1 does reach ntfy.sh" \
		|| bad "2a check-anomalies: FY_LIVE=1 does reach ntfy.sh" "rc=$RC $(tail -3 "${TMP}/2a.err")"
	[ "$BEFORE_HASH" != "$AFTER_HASH" ] \
		&& ok "2a check-anomalies: FY_LIVE=1 does commit the state" \
		|| bad "2a check-anomalies: FY_LIVE=1 does commit the state"
	[ "$(jq -r '.metalgo' "${S}/state/anomaly-state.json")" = "stopped" ] \
		&& ok "2a check-anomalies: the committed field carries the observed value" \
		|| bad "2a check-anomalies: the committed field carries the observed value"
	grep -q 'DRY:' "${TMP}/2a.err" \
		&& bad "2a check-anomalies: no DRY: line under FY_LIVE=1" "$(grep DRY: "${TMP}/2a.err" | head -2)" \
		|| ok "2a check-anomalies: no DRY: line under FY_LIVE=1"
fi

mk_repo init-live anomaly-state-init.sh
mkdir -p "${S}/state/locks"
env FY_LIVE=1 ANOMALY_STATE_DIR="${S}/state" \
	bash "${S}/scripts/anomaly-state-init.sh" --confirm --baseline-status=running \
	>"${TMP}/2b.out" 2>"${TMP}/2b.err"
RC=$?
[ "$RC" -eq 0 ] && [ -f "${S}/state/anomaly-state.json" ] \
	&& ok "2b anomaly-state-init: FY_LIVE=1 writes the baseline and exits 0" \
	|| bad "2b anomaly-state-init: FY_LIVE=1 writes the baseline and exits 0" "rc=$RC $(tail -3 "${TMP}/2b.err")"

setup_watch watch-live
reset_tripwire
BEFORE_HASH="$(hashof "${S}/wstate/watch-prev-state.json")"
run_watch FY_LIVE=1 >"${TMP}/2c.out" 2>"${TMP}/2c.err"
AFTER_HASH="$(hashof "${S}/wstate/watch-prev-state.json")"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2c check-watch-validators: FY_LIVE=1 does reach ntfy.sh" \
	|| bad "2c check-watch-validators: FY_LIVE=1 does reach ntfy.sh" "$(tail -3 "${TMP}/2c.err")"
[ "$BEFORE_HASH" != "$AFTER_HASH" ] \
	&& ok "2c check-watch-validators: FY_LIVE=1 does advance the baseline" \
	|| bad "2c check-watch-validators: FY_LIVE=1 does advance the baseline"

setup_drift drift-live
reset_tripwire
env FY_LIVE=1 NTFY_TOPIC_FILE="${S}/topic" FYD_REPO_DIR="${S}/clone" \
	bash "${S}/scripts/check-host-drift.sh" >"${TMP}/2d.out" 2>"${TMP}/2d.err"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2d check-host-drift: FY_LIVE=1 does reach ntfy.sh" \
	|| bad "2d check-host-drift: FY_LIVE=1 does reach ntfy.sh"

setup_daily daily-live
reset_tripwire
env FY_LIVE=1 NTFY_TOPIC_FILE="${S}/topic" METALGO_RPC="http://127.0.0.1:1" \
	bash "${S}/scripts/daily-status.sh" evening >"${TMP}/2e.out" 2>"${TMP}/2e.err"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2e daily-status: FY_LIVE=1 does reach ntfy.sh" \
	|| bad "2e daily-status: FY_LIVE=1 does reach ntfy.sh"

setup_nodehealth nodehealth-live
run_nodehealth FY_LIVE=1 >"${TMP}/2f.out" 2>"${TMP}/2f.err"
RC=$?
[ "$RC" -eq 0 ] && [ -s "${S}/nhstate/node-health-history.jsonl" ] && [ -s "${S}/public/api/node-health-recent.json" ] \
	&& ok "2f node-health-daily: FY_LIVE=1 writes both the ledger and the preview" \
	|| bad "2f node-health-daily: FY_LIVE=1 writes both the ledger and the preview" "rc=$RC $(tail -3 "${TMP}/2f.err")"
[ ! -e "${S}/public/api/node-health-recent.json.tmp" ] \
	&& ok "2f node-health-daily: the live path leaves no .tmp behind either" \
	|| bad "2f node-health-daily: the live path leaves no .tmp behind either"

setup_evhealth evhealth-live
reset_tripwire
run_evhealth FY_LIVE=1 >"${TMP}/2g.out" 2>"${TMP}/2g.err"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2g notify-evidence-health: FY_LIVE=1 does reach ntfy.sh" \
	|| bad "2g notify-evidence-health: FY_LIVE=1 does reach ntfy.sh"

echo
echo "== Part 3/4: static gate — no ungated side effect in the seven files =="

# gate_stream <file> — "N:text" lines with comment-only lines dropped and
# single-quoted literals blanked. Blanking the quoted runs is what keeps the
# operator-guidance prose inside `body=$(printf '… bash scripts/…')` from
# being mistaken for a call: text inside single quotes is never executed.
gate_stream() {
	grep -n '' "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s/'[^']*'//g"
}

DELEGATE_RE='(^[0-9]+:|[[:space:]{(;&|])(bash|sh|exec)[[:space:]]+"?[^"[:space:]]*(notify|push-to-web-host)\.sh'
DELEGATE_VAR_RE='(bash|sh|exec)[[:space:]]+"?\$\{?(NOTIFY|FYD_NOTIFY|ANCHOR_NOTIFY|WATCH_NOTIFY|FYD_PUSH_TO_WEB_HOST)\}?"?'
DURABLE='STATE_FILE|PREV_FILE|HIST_JSONL|MISSING_MARKER|OUT_PUBLIC|COUNTER_FILE|CONTENTION_COUNTER|DELEGATOR_EVENTS_LOG|quar_target'
DURABLE_DIR='STATE_DIR|QUAR_DIR'
WRITE_RE="(>>?[[:space:]]*\"?\\\$\{?(${DURABLE}))|(\\b(mv|cp|rm|chmod|touch)\\b[^|;&]*\\\$\{?(${DURABLE})\\}?)|(\\b(mkdir|rm)\\b[^|;&]*\\\$\{?(${DURABLE_DIR})\\}?)"

# gate_check <file> — prints one line per violation; silence means clean.
gate_check() {
	local f="$1" refusal=0 n ctx
	refusal="$(grep -nF 'FYD-GATE(refusal)' "$f" | head -1 | cut -d: -f1)"
	[ -n "$refusal" ] || refusal=0

	gate_stream "$f" | grep -E "$DELEGATE_RE" | sed 's/^/G1 direct-delegate-invocation /'
	gate_stream "$f" | grep -E "$DELEGATE_VAR_RE" | sed 's/^/G1 direct-delegate-invocation /'
	gate_stream "$f" | grep -F '/var/lib/freedom-yield' | sed 's/^/G2 production-path-literal /'
	grep -qE '^[[:space:]]*\.[[:space:]]+"\$FYD_LIB"' "$f" || echo "G3 does-not-source-the-side-effects-library"

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		n="${line%%:*}"
		case "$line" in *fyd_live_write*|*fyd_live_run*|*fyd_notify*) continue ;; esac
		if [ "$refusal" -gt 0 ] && [ "$n" -gt "$refusal" ]; then continue; fi
		if [ "$n" -gt 1 ]; then ctx="$(sed -n "$((n - 1))p;${n}p" "$f")"; else ctx="$(sed -n '1p' "$f")"; fi
		case "$ctx" in *'FYD-GATE('*) continue ;; esac
		echo "G4 ungated-durable-write $line"
	done <<EOF
$(gate_stream "$f" | grep -E "$WRITE_RE")
EOF
}

for f in $TARGETS; do
	V="$(gate_check "${SCRIPTS}/${f}")"
	if [ -z "$V" ]; then
		ok "3 gate clean: scripts/${f}"
	else
		bad "3 gate clean: scripts/${f}" "$(printf '%s' "$V" | head -4 | tr '\n' ' ')"
	fi
done

if grep -qF 'FYD-GATE(refusal)' "${SCRIPTS}/anomaly-state-init.sh"; then
	ok "3 anomaly-state-init carries the file-level hard-refusal marker"
else
	bad "3 anomaly-state-init carries the file-level hard-refusal marker"
fi

echo
echo "== Part 4/4: mutation — the gate must go red when a rule is broken =="

# mutate <label> <source file> <sed program>  → expect gate_check to complain
mutate() {
	local label="$1" src="$2" prog="$3" out="${TMP}/mut-$(basename "$2")"
	sed "$prog" "$src" >"$out"
	if [ "$(cat "$out")" = "$(cat "$src")" ]; then
		bad "4 mutation applied: ${label}" "sed program matched nothing — the mutation test would be a tautology"
		return
	fi
	if [ -n "$(gate_check "$out")" ]; then
		ok "4 mutation caught: ${label}"
	else
		bad "4 mutation caught: ${label}" "gate stayed green against a deliberately broken file"
	fi
}

mutate "G1 — a raw notify.sh call comes back" \
	"${SCRIPTS}/check-host-drift.sh" \
	's|^\tfyd_notify "\$1" "\$2" "\$3".*|\tbash "${SCRIPT_DIR}/notify.sh" "$1" "$2" "$3"|'

mutate "G1 — a raw \$NOTIFY call comes back" \
	"${SCRIPTS}/daily-status.sh" \
	's|^fyd_notify "\$PRIO".*|bash "$NOTIFY" "$PRIO" "x" "y"|'

mutate "G2 — a production path literal comes back" \
	"${SCRIPTS}/check-watch-validators.sh" \
	's|^STATE_DIR="\$(fyd_state_dir watch)".*|STATE_DIR="${WATCH_STATE_DIR:-/var/lib/freedom-yield}"|'

mutate "G3 — the library is no longer sourced" \
	"${SCRIPTS}/node-health-daily.sh" \
	's|^\. "\$FYD_LIB"|true|'

mutate "G4 — a gated baseline write reverts to a raw redirect" \
	"${SCRIPTS}/check-watch-validators.sh" \
	's@^  printf .*fyd_live_write.*@  echo "$CURRENT_JSON" > "$PREV_FILE"@'

mutate "G4 — a gated ledger append reverts to a raw redirect" \
	"${SCRIPTS}/node-health-daily.sh" \
	's@^printf .*fyd_live_write.*@echo "$ENTRY" >> "$HIST_JSONL"@'

mutate "G4/G5 — the hard-refusal marker is removed from anomaly-state-init" \
	"${SCRIPTS}/anomaly-state-init.sh" \
	's@# FYD-GATE(refusal).*@#@'

# ---------------------------------------------------------------------------
# Sandbox regression guard (task h5, 2026-08-07)
# ---------------------------------------------------------------------------
# mk_repo above mirrors the ENTIRE real scripts/lib/ directory precisely so a
# FUTURE addition there is picked up with zero suite edits — the bug this
# task fixed was mk_repo hand-copying just side-effects.sh while
# push-to-web-host.sh grew a hard dependency on its sibling scripts/lib/
# publish-scan.sh (which in turn requires scripts/publish-guard.sh). None of
# THIS suite's callers happen to invoke push-to-web-host.sh at runtime, which
# is exactly why it did not fail when the sibling suites did — that is
# fragile, not safe, so this guard proves the mechanism generalizes here too
# instead of relying on today's callers never changing.
echo "== Sandbox regression guard: scripts/lib/ growth is picked up automatically =="

# 1) Growth: drop a brand-new file into a throwaway COPY of scripts/lib/ and
#    confirm mk_repo mirrors it into a fresh sandbox with NO suite changes.
MUT_SCRIPTS="${TMP}/mut-scripts-src"
mkdir -p "${MUT_SCRIPTS}/lib"
cp -R "${SCRIPTS}/lib/." "${MUT_SCRIPTS}/lib/"
cp "${SCRIPTS}/notify.sh" "${MUT_SCRIPTS}/notify.sh"
cp "${SCRIPTS}/push-to-web-host.sh" "${MUT_SCRIPTS}/push-to-web-host.sh"
cp "${SCRIPTS}/publish-guard.sh" "${MUT_SCRIPTS}/publish-guard.sh"
printf '#!/usr/bin/env bash\n# task-h5 mutation probe: proves mk_repo mirrors a NEW scripts/lib/ file.\n' \
	>"${MUT_SCRIPTS}/lib/zz-mutation-probe.sh"
_H5_REAL_SCRIPTS="$SCRIPTS"
SCRIPTS="$MUT_SCRIPTS"
mk_repo h5-libgrowth-probe
SCRIPTS="$_H5_REAL_SCRIPTS"
if [ -f "${S}/scripts/lib/zz-mutation-probe.sh" ]; then
	ok "sandbox-guard: a brand-new scripts/lib/*.sh file is mirrored into a fresh sandbox automatically"
else
	bad "sandbox-guard: a brand-new scripts/lib/*.sh file is mirrored into a fresh sandbox automatically" \
		"mk_repo did not copy it into ${S}/scripts/lib/"
fi

# 2) Non-vacuity: the real (unmutated) scripts/lib/ has N files and a freshly
#    built sandbox must have exactly N — not "at least one", not a
#    hard-coded number. An enumerated cp list regressing to fewer files
#    drops below N and fails loudly here instead of staying silently green.
real_lib_count=$(find "${SCRIPTS}/lib" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
mk_repo h5-libparity-probe
sandbox_lib_count=$(find "${S}/scripts/lib" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
if [ "$real_lib_count" -gt 0 ] && [ "$real_lib_count" = "$sandbox_lib_count" ]; then
	ok "sandbox-guard: sandbox scripts/lib/ file count matches the real one (${real_lib_count})"
else
	bad "sandbox-guard: sandbox scripts/lib/ file count matches the real one" \
		"real=${real_lib_count} sandbox=${sandbox_lib_count}"
fi

# 3) End-to-end: run push-to-web-host.sh FOR REAL against the sandbox mk_repo
#    just built and require it to reach the (stubbed) ssh, i.e. get PAST its
#    own publish-scan self-test, not die on "library not found". This is the
#    exact failure this task fixed, reproduced and re-asserted every run.
mkdir -p "${S}/public/api"
printf '{}\n' >"${S}/public/api/validator.json"
printf 'sandbox-guard-key-not-a-real-key\n' >"${S}/h5-guard-key"
chmod 600 "${S}/h5-guard-key"
reset_tripwire
H5_PUSHDEP_OUT="$(env REPO_BASE="${S}" WEB_HOST="sandbox@host.invalid" WEB_PUSH_KEY="${S}/h5-guard-key" \
	bash "${S}/scripts/push-to-web-host.sh" validator.json 2>&1 || true)"
if printf '%s' "$H5_PUSHDEP_OUT" | grep -qE 'library not found|publish-guard not found'; then
	bad "sandbox-guard: push-to-web-host.sh's full runtime dependency closure is present in the sandbox" \
		"$(printf '%s' "$H5_PUSHDEP_OUT" | head -3)"
else
	ok "sandbox-guard: push-to-web-host.sh's full runtime dependency closure is present in the sandbox"
fi
[ "$(grep -c '^ssh ' "$TRIPWIRE" 2>/dev/null | tr -d '[:space:]')" != "0" ] \
	&& ok "sandbox-guard: proved by actually REACHING ssh, not by a shortcut" \
	|| bad "sandbox-guard: proved by actually REACHING ssh, not by a shortcut" "$H5_PUSHDEP_OUT"

echo
echo "test-monitoring-side-effects.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
printf '\nFailures:\n'
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
echo "RESULT: FAIL"
exit 1
