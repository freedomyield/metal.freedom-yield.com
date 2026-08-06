#!/usr/bin/env bash
# test-check-identity-pins.sh — suite for scripts/check-identity-pins.sh and
# scripts/install-metal-identity-pins-cron.sh.
#
# CHAIN: none — every case builds a throwaway fake repo in a tempdir. Live
#        mode is exercised against a curl STUB (FYD_CURL); no network, no real
#        ntfy (the notifier is a recording stub), no writes outside the
#        tempdir except the final real-repo regression case, which is
#        read-only.
#
# The centrepiece is the MUTATION proof (cases 4 and 5): the baseline in
# deploy/identity-pin-baseline.json must acknowledge exactly the break it
# records and nothing more, so changing a pinned git-tracked file by ONE BYTE
# turns the gate red even when that file already has a baseline entry.
#
# Usage:
#   bash tests/identity-pins/test-check-identity-pins.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-identity-pins.sh"
INSTALLER="${REPO_ROOT}/scripts/install-metal-identity-pins-cron.sh"

[ -f "$CHECKER" ]   || { echo "FATAL: checker not found at $CHECKER" >&2; exit 1; }
[ -f "$INSTALLER" ] || { echo "FATAL: installer not found at $INSTALLER" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

sha() {
	if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
	else sha256sum "$1" | awk '{print $1}'; fi
}

# ---- harness -----------------------------------------------------------------
# build_fake_repo: a minimal repo shaped like the real one.
#   public/api/alpha.json           tracked  (pinned)
#   public/api/alpha.schema.json    tracked  (pinned as schema_sha256)
#   public/api/stream.json          stream   (listed in feed-excludes.txt)
#   public/api/identity.json        the manifest under test
# No baseline file is written by default; write_baseline adds one.
BASE=""; FAKE=""; STUB_DIR=""; NOTIFY_STUB=""; NOTIFY_LOG=""; STATE=""; LOGFILE=""
build_fake_repo() {
	BASE="$(mktemp -d -t identity-pins-test.XXXXXX)"
	FAKE="$BASE/repo"
	STUB_DIR="$BASE/served"
	NOTIFY_STUB="$BASE/notify-stub.sh"
	NOTIFY_LOG="$BASE/notify.log"
	STATE="$BASE/alert-state.json"
	LOGFILE="$BASE/drift.log"
	mkdir -p "$FAKE/public/api" "$FAKE/deploy" "$FAKE/logs" "$STUB_DIR"

	printf '# push-owned feeds\napi/stream.json\napi/subfeed/\n' > "$FAKE/deploy/feed-excludes.txt"
	printf '{"alpha":true}\n'         > "$FAKE/public/api/alpha.json"
	printf '{"schema":"alpha","v":1}\n' > "$FAKE/public/api/alpha.schema.json"
	printf '{"moving":1}\n'           > "$FAKE/public/api/stream.json"

	write_identity
	cat > "$NOTIFY_STUB" <<STUBEOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$NOTIFY_LOG"
STUBEOF
	chmod +x "$NOTIFY_STUB"
}

# write_identity [alpha_sha] [alpha_schema_sha] [stream_sha]
# Defaults pin the CURRENT bytes of each file (= a freshly-issued manifest).
write_identity() {
	local a_sha s_sha t_sha
	a_sha="${1:-$(sha "$FAKE/public/api/alpha.json")}"
	s_sha="${2:-$(sha "$FAKE/public/api/alpha.schema.json")}"
	t_sha="${3:-$(sha "$FAKE/public/api/stream.json")}"
	jq -n --arg a "$a_sha" --arg s "$s_sha" --arg t "$t_sha" '{
		schema_version: 1,
		artifact_manifest: {
			alpha_json: {
				url: "https://example.test/api/alpha.json",
				sha256: $a,
				schema_url: "https://example.test/api/alpha.schema.json",
				schema_sha256: $s
			},
			stream_json: {
				url: "https://example.test/api/stream.json",
				sha256: $t
			}
		}
	}' > "$FAKE/public/api/identity.json"
}

# write_baseline <pin_id> <class> <pinned_sha> <observed_sha>
write_baseline() {
	jq -n --arg id "$1" --arg c "$2" --arg p "$3" --arg o "$4" '{
		schema_version: 1,
		known_broken: { ($id): { class: $c, pinned_sha256: $p, observed_sha256: $o,
		                          path: "public/api/x", reason: "test", resolution: "test" } }
	}' > "$FAKE/deploy/identity-pin-baseline.json"
}

teardown() { rm -rf "$BASE"; BASE=""; }

run_repo() {
	FYD_REPO_ROOT="$FAKE" \
	IDENTITY_PIN_LOG="$LOGFILE" \
	IDENTITY_PIN_ALERT_STATE="$STATE" \
	FYD_NOTIFY="$NOTIFY_STUB" \
	bash "$CHECKER" --mode=repo 2>&1
}

# ---- curl stub ---------------------------------------------------------------
# Emulates `curl -sS -o <out> -w "%{http_code}" --max-time N <url>`:
# serves $STUB_DIR/<basename-of-url>, or the status in
# $STUB_DIR/<basename>.code when that exists, else 404.
make_curl_stub() {
	cat > "$BASE/curl-stub.sh" <<'STUBEOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-w|--max-time) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
base="${url##*/}"
: > "$out"
if [ -f "${STUB_DIR}/${base}.code" ]; then
	printf '%s' "$(cat "${STUB_DIR}/${base}.code")"
	exit 0
fi
if [ -f "${STUB_DIR}/${base}" ]; then
	cp "${STUB_DIR}/${base}" "$out"
	printf '200'
	exit 0
fi
printf '404'
STUBEOF
	chmod +x "$BASE/curl-stub.sh"
}

run_live() {
	FYD_REPO_ROOT="$FAKE" \
	FYD_IDENTITY_URL="https://example.test/api/identity.json" \
	FYD_CURL="$BASE/curl-stub.sh" \
	STUB_DIR="$STUB_DIR" \
	FYD_FETCH_ATTEMPTS=1 FYD_RETRY_SLEEP=0 \
	IDENTITY_PIN_LOG="$LOGFILE" \
	IDENTITY_PIN_ALERT_STATE="$STATE" \
	FYD_NOTIFY="$NOTIFY_STUB" \
	bash "$CHECKER" --mode=live 2>&1
}

# serve <src-file> <served-basename>
serve() { cp "$1" "$STUB_DIR/$2"; }
alerts() { cat "$NOTIFY_LOG" 2>/dev/null; }
alert_count() { grep -c . "$NOTIFY_LOG" 2>/dev/null || echo 0; }

# =============================================================================
# repo mode
# =============================================================================

# ---- case 1: every pin matches → green --------------------------------------
build_fake_repo
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 0 ] && ok "c1 all pins match: exit 0" || bad "c1 all pins match: exit 0 (actual=$RC)"
echo "$OUT" | grep -q 'new=0' \
	&& ok "c1 summary reports new=0" || bad "c1 summary reports new=0 (out: $OUT)"
teardown

# ---- case 2: a tracked pin breaks, no baseline → red ------------------------
build_fake_repo
printf 'x' >> "$FAKE/public/api/alpha.schema.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 3 ] && ok "c2 unbaselined tracked break: exit 3" || bad "c2 unbaselined tracked break: exit 3 (actual=$RC)"
echo "$OUT" | grep -q '^MISMATCH .*alpha_json.schema_sha256' \
	&& ok "c2 names the broken pin" || bad "c2 names the broken pin (out: $OUT)"
teardown

# ---- case 3: baseline acknowledging the exact pair → green ------------------
build_fake_repo
PIN_S="$(sha "$FAKE/public/api/alpha.schema.json")"
printf 'x' >> "$FAKE/public/api/alpha.schema.json"
OBS_S="$(sha "$FAKE/public/api/alpha.schema.json")"
write_baseline "alpha_json.schema_sha256" "tracked" "$PIN_S" "$OBS_S"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 0 ] && ok "c3 baselined tracked break: exit 0" || bad "c3 baselined tracked break: exit 0 (actual=$RC)"
echo "$OUT" | grep -q '^BASELINED .*alpha_json.schema_sha256' \
	&& ok "c3 reports it as BASELINED, not silent" || bad "c3 reports it as BASELINED (out: $OUT)"

# ---- case 4: MUTATION PROOF — one more byte on a BASELINED file → red -------
# This is the case the whole design turns on: a baseline entry must accept a
# single known (pinned, observed) pair, never "this file may drift freely".
printf 'y' >> "$FAKE/public/api/alpha.schema.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 3 ] && ok "c4 MUTATION: 1 byte on a baselined file → exit 3" || bad "c4 MUTATION: 1 byte on a baselined file → exit 3 (actual=$RC)"
echo "$OUT" | grep -q '^MISMATCH .*alpha_json.schema_sha256' \
	&& ok "c4 MUTATION: reported as a NEW break" || bad "c4 MUTATION: reported as a NEW break (out: $OUT)"
teardown

# ---- case 5: baseline whose pinned side is stale (manifest re-signed) → red --
build_fake_repo
printf 'x' >> "$FAKE/public/api/alpha.schema.json"
OBS_S="$(sha "$FAKE/public/api/alpha.schema.json")"
write_baseline "alpha_json.schema_sha256" "tracked" "0000000000000000000000000000000000000000000000000000000000000000" "$OBS_S"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 3 ] && ok "c5 baseline with a stale pinned side does not apply: exit 3" || bad "c5 baseline with a stale pinned side: exit 3 (actual=$RC)"
teardown

# ---- case 6: a stream pin drifts → skipped in repo mode, green --------------
build_fake_repo
printf 'drifted' >> "$FAKE/public/api/stream.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 0 ] && ok "c6 stream pin drift is not a repo-mode failure: exit 0" || bad "c6 stream pin drift: exit 0 (actual=$RC)"
echo "$OUT" | grep -q '^SKIP .*stream_json.sha256' \
	&& ok "c6 stream pin is SKIPped with a reason" || bad "c6 stream pin SKIP line (out: $OUT)"
teardown

# ---- case 7: a pinned tracked file disappears → red -------------------------
build_fake_repo
rm -f "$FAKE/public/api/alpha.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 3 ] && ok "c7 pinned tracked file missing: exit 3" || bad "c7 pinned tracked file missing: exit 3 (actual=$RC)"
echo "$OUT" | grep -q '^MISSING .*alpha_json.sha256' \
	&& ok "c7 reports MISSING" || bad "c7 reports MISSING (out: $OUT)"
teardown

# ---- case 8: baseline entry for a pin that now matches → green + OBSOLETE ---
build_fake_repo
GOOD_S="$(sha "$FAKE/public/api/alpha.schema.json")"
write_baseline "alpha_json.schema_sha256" "tracked" "$GOOD_S" "deadbeef"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 0 ] && ok "c8 obsolete baseline entry stays green: exit 0" || bad "c8 obsolete baseline entry: exit 0 (actual=$RC)"
echo "$OUT" | grep -q '^OBSOLETE-BASELINE .*alpha_json.schema_sha256' \
	&& ok "c8 names the obsolete entry for removal" || bad "c8 OBSOLETE-BASELINE line (out: $OUT)"
teardown

# ---- case 9: unparseable baseline → refuse to run (exit 2), never green -----
build_fake_repo
printf 'not json {{{' > "$FAKE/deploy/identity-pin-baseline.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 2 ] && ok "c9 corrupt baseline: exit 2 (fails loud, not open)" || bad "c9 corrupt baseline: exit 2 (actual=$RC)"
teardown

# ---- case 10: missing / empty manifest → exit 2 -----------------------------
build_fake_repo
rm -f "$FAKE/public/api/identity.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 2 ] && ok "c10 missing manifest: exit 2" || bad "c10 missing manifest: exit 2 (actual=$RC)"
printf '{"schema_version":1,"artifact_manifest":{}}\n' > "$FAKE/public/api/identity.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 2 ] && ok "c10 empty artifact_manifest: exit 2" || bad "c10 empty artifact_manifest: exit 2 (actual=$RC)"
teardown

# ---- case 11: missing feed-excludes list → exit 2 (cannot classify) ---------
build_fake_repo
rm -f "$FAKE/deploy/feed-excludes.txt"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 2 ] && ok "c11 no feed-excludes list: exit 2" || bad "c11 no feed-excludes list: exit 2 (actual=$RC)"
teardown

# =============================================================================
# live mode — alert / silence split
# =============================================================================

# ---- case 12: only the stream pin drifts → green AND silent ----------------
build_fake_repo
make_curl_stub
printf 'drifted-on-the-host' > "$STUB_DIR/stream.json"
serve "$FAKE/public/api/identity.json"    identity.json
serve "$FAKE/public/api/alpha.json"       alpha.json
serve "$FAKE/public/api/alpha.schema.json" alpha.schema.json
OUT="$(run_live)"; RC=$?
[ "$RC" -eq 0 ] && ok "c12 live: stream drift alone is green" || bad "c12 live: stream drift alone is green (actual=$RC)"
echo "$OUT" | grep -q '^STRUCTURAL .*stream_json.sha256' \
	&& ok "c12 live: stream drift recorded as STRUCTURAL" || bad "c12 live: STRUCTURAL line (out: $OUT)"
[ "$(alert_count)" -eq 0 ] \
	&& ok "c12 live: stream drift fires NO notification" || bad "c12 live: stream drift fired $(alert_count) notification(s): $(alerts)"
teardown

# ---- case 13/14/15/16: tracked break alerts once, dedups, re-arms -----------
build_fake_repo
make_curl_stub
serve "$FAKE/public/api/identity.json"     identity.json
serve "$FAKE/public/api/alpha.json"        alpha.json
serve "$FAKE/public/api/stream.json"       stream.json
printf '{"schema":"alpha","v":2}\n'      > "$STUB_DIR/alpha.schema.json"
OUT="$(run_live)"; RC=$?
[ "$RC" -eq 3 ] && ok "c13 live: tracked break exits 3" || bad "c13 live: tracked break exits 3 (actual=$RC)"
[ "$(alert_count)" -eq 1 ] \
	&& ok "c13 live: tracked break fires exactly one push" || bad "c13 live: expected 1 push, got $(alert_count)"
alerts | grep -q '^high|' \
	&& ok "c13 live: push is high priority" || bad "c13 live: push priority (log: $(alerts))"

OUT="$(run_live)"; RC=$?
[ "$RC" -eq 3 ] && ok "c14 live: unchanged break still exits 3" || bad "c14 live: unchanged break exits 3 (actual=$RC)"
[ "$(alert_count)" -eq 1 ] \
	&& ok "c14 live: same break set does NOT re-push (dedup)" || bad "c14 live: dedup failed, $(alert_count) pushes"

printf '{"schema":"alpha","v":3}\n' > "$STUB_DIR/alpha.schema.json"
OUT="$(run_live)"; RC=$?
[ "$(alert_count)" -eq 2 ] \
	&& ok "c15 live: a CHANGED break set re-pushes" || bad "c15 live: changed break set should re-push, got $(alert_count)"

serve "$FAKE/public/api/alpha.schema.json" alpha.schema.json
OUT="$(run_live)"; RC=$?
[ "$RC" -eq 0 ] && ok "c16 live: recovery exits 0" || bad "c16 live: recovery exits 0 (actual=$RC)"
[ -f "$STATE" ] && bad "c16 live: recovery clears dedup state" || ok "c16 live: recovery clears dedup state"
printf '{"schema":"alpha","v":3}\n' > "$STUB_DIR/alpha.schema.json"
OUT="$(run_live)"; RC=$?
[ "$(alert_count)" -eq 3 ] \
	&& ok "c16 live: a break after recovery alerts immediately" || bad "c16 live: post-recovery alert, got $(alert_count)"
teardown

# ---- case 17: unreadable dedup state fails OPEN (alerts) --------------------
build_fake_repo
make_curl_stub
serve "$FAKE/public/api/identity.json" identity.json
serve "$FAKE/public/api/alpha.json"    alpha.json
serve "$FAKE/public/api/stream.json"   stream.json
printf '{"schema":"alpha","v":9}\n'  > "$STUB_DIR/alpha.schema.json"
printf 'corrupt-not-json' > "$STATE"
OUT="$(run_live)"; RC=$?
[ "$(alert_count)" -ge 1 ] \
	&& ok "c17 live: corrupt dedup state fails OPEN toward alerting" || bad "c17 live: corrupt dedup state suppressed the alert"
teardown

# ---- case 18: tracked URL unfetchable → exit 4 + alert ----------------------
build_fake_repo
make_curl_stub
serve "$FAKE/public/api/identity.json" identity.json
serve "$FAKE/public/api/alpha.json"    alpha.json
serve "$FAKE/public/api/stream.json"   stream.json
printf '503' > "$STUB_DIR/alpha.schema.json.code"
OUT="$(run_live)"; RC=$?
[ "$RC" -eq 4 ] && ok "c18 live: tracked URL unfetchable → exit 4" || bad "c18 live: tracked URL unfetchable → exit 4 (actual=$RC)"
[ "$(alert_count)" -eq 1 ] \
	&& ok "c18 live: unverifiable tracked pin alerts" || bad "c18 live: expected 1 push, got $(alert_count)"
teardown

# ---- case 19: stream URL unfetchable → not gated, green + silent -----------
build_fake_repo
make_curl_stub
serve "$FAKE/public/api/identity.json"     identity.json
serve "$FAKE/public/api/alpha.json"        alpha.json
serve "$FAKE/public/api/alpha.schema.json" alpha.schema.json
printf '502' > "$STUB_DIR/stream.json.code"
OUT="$(run_live)"; RC=$?
[ "$RC" -eq 0 ] && ok "c19 live: stream URL unfetchable is not a failure" || bad "c19 live: stream URL unfetchable → exit 0 (actual=$RC)"
[ "$(alert_count)" -eq 0 ] \
	&& ok "c19 live: stream URL unfetchable is silent" || bad "c19 live: fired $(alert_count) push(es)"
teardown

# ---- case 20: the manifest itself unfetchable → exit 4 + alert -------------
build_fake_repo
make_curl_stub
printf '000' > "$STUB_DIR/identity.json.code"
OUT="$(run_live)"; RC=$?
[ "$RC" -eq 4 ] && ok "c20 live: manifest unfetchable → exit 4" || bad "c20 live: manifest unfetchable → exit 4 (actual=$RC)"
[ "$(alert_count)" -eq 1 ] \
	&& ok "c20 live: manifest unfetchable alerts" || bad "c20 live: expected 1 push, got $(alert_count)"
teardown

# =============================================================================
# cron installer
# =============================================================================
build_fake_repo
mkdir -p "$FAKE/scripts"
cp "$CHECKER" "$FAKE/scripts/check-identity-pins.sh"
cp "${REPO_ROOT}/scripts/check-cron-file.sh" "$FAKE/scripts/check-cron-file.sh" 2>/dev/null || true
CRON_OUT="$BASE/metal-identity-pins"
OUT="$(FYD_CRON_TARGET="$CRON_OUT" FYD_REPO_PATH="$FAKE" FYD_BACKUP_DIR="$BASE/backups" bash "$INSTALLER" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "c21 installer: exit 0 in harness mode" || bad "c21 installer: exit 0 (actual=$RC, out: $OUT)"
grep -q '^0 1 \* \* \* deploy bash .*check-identity-pins.sh --mode=live' "$CRON_OUT" \
	&& ok "c21 installer: daily 01:00 UTC live-mode line" || bad "c21 installer: cron line (file: $(cat "$CRON_OUT" 2>/dev/null))"
grep -q 'logger -t identity-pin-drift' "$CRON_OUT" \
	&& ok "c21 installer: pipes to logger with a project tag" || bad "c21 installer: logger tag"
if [ -x "${REPO_ROOT}/scripts/check-cron-file.sh" ]; then
	bash "${REPO_ROOT}/scripts/check-cron-file.sh" "$CRON_OUT" >/dev/null 2>&1 \
		&& ok "c21 installer: output passes check-cron-file.sh" || bad "c21 installer: check-cron-file.sh rejected the output"
fi
OUT="$(FYD_CRON_TARGET="$CRON_OUT" FYD_REPO_PATH="$FAKE" FYD_BACKUP_DIR="$BASE/backups" bash "$INSTALLER" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'already up to date' \
	&& ok "c22 installer: idempotent second run" || bad "c22 installer: idempotent second run (rc=$RC, out: $OUT)"
rm -f "$FAKE/scripts/check-identity-pins.sh"
OUT="$(FYD_CRON_TARGET="$BASE/other-cron" FYD_REPO_PATH="$FAKE" FYD_BACKUP_DIR="$BASE/backups" bash "$INSTALLER" 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "c23 installer: refuses when the checker is absent (exit 3)" || bad "c23 installer: absent checker → exit 3 (actual=$RC)"
teardown

# =============================================================================
# real repo — the gate CI actually runs must be green on the committed baseline
# =============================================================================
OUT="$(bash "$CHECKER" --mode=repo 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "c24 real repo: --mode=repo gate is green on the committed baseline" \
	|| bad "c24 real repo: --mode=repo gate is green (actual=$RC, out: $OUT)"
echo "$OUT" | grep -q 'summary (mode=repo)' \
	&& ok "c24 real repo: emits a summary line" || bad "c24 real repo: summary line (out: $OUT)"

echo
echo "test-check-identity-pins.sh summary: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
