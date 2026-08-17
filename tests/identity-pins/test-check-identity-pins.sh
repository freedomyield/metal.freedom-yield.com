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
#   public/api/alpha.json           tracked  (pinned)   kind=static
#   public/api/alpha.schema.json    tracked  (pinned as schema_sha256) kind=static
#   public/api/stream.json          stream   (listed in feed-excludes.txt) kind=stream
#   public/api/identity.json        the manifest under test
#   deploy/publication.json         the kind-gate registry (see write_registry)
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

	write_registry
	write_identity
	cat > "$NOTIFY_STUB" <<STUBEOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$NOTIFY_LOG"
STUBEOF
	chmod +x "$NOTIFY_STUB"
}

# write_registry — the kind-gate authority (deploy/publication.json), fully
# SYNTHETIC (jq -n, never a `cp` of the real registry — see
# scripts/check-identity-pins.sh's "THE KIND GATE" section header: a frozen
# copy of the real file goes stale in the dangerous direction the day the
# real file's SHAPE changes, which is the exact trap this repo's C4 T19
# fixture fell into once before). Declares `kind` for exactly the three
# fixture paths this harness uses, plus ONE pre-acknowledged kind=stream
# violation for stream_json.sha256, mirroring the real repo's
# deploy/publication.json known_kind_violations block. That acknowledgement
# is required for every EXISTING case in this suite to keep passing: every
# one of them pins stream_json by default (write_identity below), and
# without an acknowledgement every one of them would go newly red for a
# reason unrelated to what it tests.
write_registry() {
	jq -n '{
		publications: [
			{ path: "api/alpha.json",        kind: "static" },
			{ path: "api/alpha.schema.json", kind: "static" },
			{ path: "api/stream.json",       kind: "stream" }
		],
		known_kind_violations: {
			violations: {
				"stream_json.sha256": {
					path: "api/stream.json",
					reason: "test fixture: pre-existing acknowledged stream pin, mirrors the real registry known_kind_violations block"
				}
			}
		}
	}' > "$FAKE/deploy/publication.json"
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
	FYD_REGISTRY="$FAKE/deploy/publication.json" \
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

# FY_LIVE=1 is what makes the recording notify stub actually get called and
# the dedup state actually get written: since the C3 inversion
# (scripts/lib/side-effects.sh, 2026-08-06) every production side effect is
# opt-in, so a run without it is a loud dry no-op and there is no push to
# assert on. Here we opt in because these cases are about WHAT is alerted and
# deduped, not WHETHER.
#
# run_repo above deliberately does NOT set it, and must not: --mode=repo is
# the CI gate and has no side effect at all, so every repo-mode case below
# doubles as proof that the inversion cannot make CI go silently green. The
# default-dry behaviour of live mode has its own coverage in
# tests/side-effects-callers/test-feed-side-effects.sh.
run_live() {
	FY_LIVE=1 \
	FYD_REPO_ROOT="$FAKE" \
	FYD_REGISTRY="$FAKE/deploy/publication.json" \
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

# ---- cases 20b–20d: exit-2 "cannot run" must PUSH in live mode -------------
# Under cron the only other channel is journald, so a silent exit 2 is
# indistinguishable from a healthy run on the operator's phone — "no
# notification" would read as "pins verified" while nothing was verified.
# Repo mode stays silent on purpose: there the non-zero exit already fails CI.

# 20b: corrupt baseline (live) → exit 2 + one push
build_fake_repo
make_curl_stub
serve "$FAKE/public/api/identity.json"     identity.json
serve "$FAKE/public/api/alpha.json"        alpha.json
serve "$FAKE/public/api/alpha.schema.json" alpha.schema.json
serve "$FAKE/public/api/stream.json"       stream.json
printf 'not json {{{' > "$FAKE/deploy/identity-pin-baseline.json"
OUT="$(run_live)"; RC=$?
[ "$RC" -eq 2 ] && ok "c20b live: corrupt baseline → exit 2" || bad "c20b live: corrupt baseline → exit 2 (actual=$RC)"
[ "$(alert_count)" -eq 1 ] \
	&& ok "c20b live: corrupt baseline PUSHES (not silent)" || bad "c20b live: expected 1 push, got $(alert_count)"
alerts | grep -q 'cannot run (exit 2)' \
	&& ok "c20b live: push names the cannot-run condition" || bad "c20b live: push title (log: $(alerts))"
teardown

# 20c: missing feed-excludes list (live) → exit 2 + one push
build_fake_repo
make_curl_stub
serve "$FAKE/public/api/identity.json" identity.json
rm -f "$FAKE/deploy/feed-excludes.txt"
OUT="$(run_live)"; RC=$?
[ "$RC" -eq 2 ] && ok "c20c live: missing feed-excludes → exit 2" || bad "c20c live: missing feed-excludes → exit 2 (actual=$RC)"
[ "$(alert_count)" -eq 1 ] \
	&& ok "c20c live: missing feed-excludes PUSHES (not silent)" || bad "c20c live: expected 1 push, got $(alert_count)"
teardown

# 20d: the same two conditions in REPO mode stay silent (CI already fails loud)
build_fake_repo
printf 'not json {{{' > "$FAKE/deploy/identity-pin-baseline.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 2 ] && [ "$(alert_count)" -eq 0 ] \
	&& ok "c20d repo: corrupt baseline exits 2 without pushing" || bad "c20d repo: exit 2 silent (rc=$RC, pushes=$(alert_count))"
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

# c24b/c24c — S3 kind gate, acceptance criterion "today's state is green":
# this is the REAL repo, REAL deploy/publication.json, REAL public/api/
# identity.json — not a fixture standing in for them. The real registry's
# known_kind_violations block currently acknowledges exactly the four
# kind=stream pins the manifest signed before C4 still carries, so the kind
# gate must report all four as KIND-BASELINED and kind-new=0.
echo "$OUT" | grep -q 'kind-new=0' \
	&& ok "c24b real repo: kind gate reports kind-new=0 (nothing unacknowledged)" \
	|| bad "c24b real repo: expected kind-new=0 (out: $OUT)"
N_KIND_BASELINE_LINES="$(echo "$OUT" | grep -c '^KIND-BASELINED ' || true)"
[ "$N_KIND_BASELINE_LINES" -eq 4 ] \
	&& ok "c24c real repo: all 4 known kind=stream pins reported as KIND-BASELINED" \
	|| bad "c24c real repo: expected 4 KIND-BASELINED lines, got ${N_KIND_BASELINE_LINES} (out: $OUT)"

# =============================================================================
# kind gate (S3) — deploy/publication.json's `kind` decides whether a pin may
# exist AT ALL, independent of the existing stream/tracked (feed-excludes)
# byte-mismatch checks above. See scripts/check-identity-pins.sh's "THE KIND
# GATE" section. Cases below use the synthetic fake-repo harness (k1-k7) plus
# one case jq-DERIVED from the real repo (k8) — see that case's own comment
# for why derivation, not a frozen fixture, is required here.
# =============================================================================

# ---- k1: default fixture (stream_json pre-acknowledged) -> green + KIND-BASELINED
build_fake_repo
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 0 ] && ok "k1 baselined kind=stream pin: exit 0" || bad "k1 baselined kind=stream pin: exit 0 (actual=$RC)"
echo "$OUT" | grep -q '^KIND-BASELINED .*stream_json.sha256' \
	&& ok "k1 stream_json.sha256 reported as KIND-BASELINED" || bad "k1 KIND-BASELINED line (out: $OUT)"
echo "$OUT" | grep -q 'kind-new=0' \
	&& ok "k1 summary reports kind-new=0" || bad "k1 summary kind-new=0 (out: $OUT)"
teardown

# ---- k2 MUTATION: a brand-new, UNACKNOWLEDGED kind=stream pin -> red -------
# This is the centrepiece proof (S3 acceptance #1): a pin over a kind=stream
# publication that nobody acknowledged must turn the gate red, not merely get
# noticed later as a byte mismatch.
build_fake_repo
jq '.publications += [{"path":"api/stream2.json","kind":"stream"}]' \
	"$FAKE/deploy/publication.json" > "$BASE/reg.tmp" && mv "$BASE/reg.tmp" "$FAKE/deploy/publication.json"
jq '.artifact_manifest.stream2_json = {url:"https://example.test/api/stream2.json", sha256:"deadbeef00000000000000000000000000000000000000000000000000000000"}' \
	"$FAKE/public/api/identity.json" > "$BASE/id.tmp" && mv "$BASE/id.tmp" "$FAKE/public/api/identity.json"
printf 'api/stream2.json\n' >> "$FAKE/deploy/feed-excludes.txt"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 6 ] && ok "k2 MUTATION: new unacknowledged kind=stream pin -> exit 6" || bad "k2 MUTATION: new unacknowledged kind=stream pin -> exit 6 (actual=$RC)"
echo "$OUT" | grep -q '^KIND-VIOLATION .*stream2_json.sha256' \
	&& ok "k2 MUTATION: names the offending pin as KIND-VIOLATION" || bad "k2 MUTATION: KIND-VIOLATION line (out: $OUT)"
echo "$OUT" | grep -q 'kind-new=1' \
	&& ok "k2 MUTATION: summary reports kind-new=1" || bad "k2 MUTATION: summary kind-new=1 (out: $OUT)"
teardown

# ---- k3: acknowledging that SAME new pin in known_kind_violations -> green -
# The other half of k2's proof: acknowledgement, not the pin's existence
# alone, is what the gate acts on — exactly mirroring how the real repo's
# four current stream pins stay green today.
build_fake_repo
jq '.publications += [{"path":"api/stream2.json","kind":"stream"}]
    | .known_kind_violations.violations["stream2_json.sha256"] = {path:"api/stream2.json", reason:"test"}' \
	"$FAKE/deploy/publication.json" > "$BASE/reg.tmp" && mv "$BASE/reg.tmp" "$FAKE/deploy/publication.json"
jq '.artifact_manifest.stream2_json = {url:"https://example.test/api/stream2.json", sha256:"deadbeef00000000000000000000000000000000000000000000000000000000"}' \
	"$FAKE/public/api/identity.json" > "$BASE/id.tmp" && mv "$BASE/id.tmp" "$FAKE/public/api/identity.json"
# api/stream2.json is genuinely kind=stream, so — same as every real
# kind=stream publication in this repo except api/archive/ — it also belongs
# on feed-excludes.txt (never git-tracked). Without this the UNRELATED
# mismatch check (Check 1, classify_path) sees a "tracked" pin over a file
# that does not exist on disk and reports it MISSING, which would make this
# case fail for a reason that has nothing to do with the kind gate.
printf 'api/stream2.json\n' >> "$FAKE/deploy/feed-excludes.txt"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 0 ] && ok "k3 newly-acknowledged kind=stream pin: exit 0" || bad "k3 newly-acknowledged kind=stream pin: exit 0 (actual=$RC)"
echo "$OUT" | grep -q '^KIND-BASELINED .*stream2_json.sha256' \
	&& ok "k3 reports the new acknowledgement as KIND-BASELINED" || bad "k3 KIND-BASELINED line (out: $OUT)"
teardown

# ---- k4: a pin targets a path with NO registry row at all -> red -----------
# "Undeclared" must never read as "probably fine" — same stance
# scripts/operator-local/gen-identity.sh takes (exit 9) when composing a
# manifest over an artifact the registry does not mention.
build_fake_repo
jq '.artifact_manifest.mystery_json = {url:"https://example.test/api/mystery.json", sha256:"deadbeef00000000000000000000000000000000000000000000000000000000"}' \
	"$FAKE/public/api/identity.json" > "$BASE/id.tmp" && mv "$BASE/id.tmp" "$FAKE/public/api/identity.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 6 ] && ok "k4 pin with no publication.json row: exit 6" || bad "k4 pin with no publication.json row: exit 6 (actual=$RC)"
echo "$OUT" | grep -q '^KIND-UNKNOWN .*mystery_json.sha256' \
	&& ok "k4 names the unresolved pin as KIND-UNKNOWN" || bad "k4 KIND-UNKNOWN line (out: $OUT)"
teardown

# ---- k5: registry file missing -> exit 2, cannot run (fail-closed) --------
build_fake_repo
rm -f "$FAKE/deploy/publication.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 2 ] && ok "k5 missing publication.json: exit 2" || bad "k5 missing publication.json: exit 2 (actual=$RC)"
teardown

# ---- k6: registry file present but not JSON -> exit 2 ----------------------
build_fake_repo
printf 'not json {{{' > "$FAKE/deploy/publication.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 2 ] && ok "k6 corrupt publication.json: exit 2" || bad "k6 corrupt publication.json: exit 2 (actual=$RC)"
teardown

# ---- k7: 'post-cleanup' SHAPE — empty known_kind_violations, no stream pin -
# Models what step 4b of docs/CYCLE_GATE.md requires in the same commit: the
# re-issued manifest carries no sha256 for the stream publication, AND the
# acknowledgement that named it is deleted. Both together must stay green;
# see k8 below for the same claim made against the REAL repo's files.
build_fake_repo
jq '.known_kind_violations.violations = {}' "$FAKE/deploy/publication.json" > "$BASE/reg.tmp" \
	&& mv "$BASE/reg.tmp" "$FAKE/deploy/publication.json"
jq 'del(.artifact_manifest.stream_json)' "$FAKE/public/api/identity.json" > "$BASE/id.tmp" \
	&& mv "$BASE/id.tmp" "$FAKE/public/api/identity.json"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 0 ] && ok "k7 post-cleanup shape (no ack list, no stream pin): exit 0" || bad "k7 post-cleanup shape: exit 0 (actual=$RC)"
echo "$OUT" | grep -qE '^(KIND-BASELINED|KIND-VIOLATION|KIND-UNKNOWN) ' \
	&& bad "k7 post-cleanup shape: unexpectedly still reports a kind-gate line" \
	|| ok "k7 post-cleanup shape: no kind-gate line at all (nothing left to gate)"
teardown

# ---- k7R: a DIRECTORY row (kind=record via member_pattern) resolves cleanly
# registry_kind_of() has TWO resolution paths: exact .path match (exercised
# by every case above) and a directory row (path ending "/") whose
# member_pattern matches the pin's basename — the SAME path
# api/archive/anchor-source-<64-hex>.json takes in the real registry. Every
# case above only exercised the exact-match path; this one is required, not
# decorative — it caught a real bug during development (a `select($p |
# startswith(.path))` that silently rebound `.` and made every directory-row
# lookup error out as "cannot run", never reaching the exact-match fallback
# used everywhere else, which is why every OTHER case here stayed green
# while this one alone would have failed).
build_fake_repo
jq '.publications += [{"path":"api/archive/","kind":"record","member_pattern":"^anchor-source-[a-f0-9]{64}\\.json$"}]' \
	"$FAKE/deploy/publication.json" > "$BASE/reg.tmp" && mv "$BASE/reg.tmp" "$FAKE/deploy/publication.json"
mkdir -p "$FAKE/public/api/archive"
RECORD_NAME="0000000000000000000000000000000000000000000000000000000000000001"
printf '{"archived":true}\n' > "$FAKE/public/api/archive/anchor-source-${RECORD_NAME}.json"
RECORD_SHA="$(sha "$FAKE/public/api/archive/anchor-source-${RECORD_NAME}.json")"
jq --arg sha "$RECORD_SHA" --arg name "$RECORD_NAME" \
	'.artifact_manifest.anchor_source_archive_json = {url: ("https://example.test/api/archive/anchor-source-" + $name + ".json"), sha256: $sha}' \
	"$FAKE/public/api/identity.json" > "$BASE/id.tmp" && mv "$BASE/id.tmp" "$FAKE/public/api/identity.json"
printf 'api/archive/\n' >> "$FAKE/deploy/feed-excludes.txt"
OUT="$(run_repo)"; RC=$?
[ "$RC" -eq 0 ] && ok "k7R directory-row kind=record pin: exit 0" || bad "k7R directory-row kind=record pin: exit 0 (actual=$RC, out: $OUT)"
echo "$OUT" | grep -qE '^(KIND-VIOLATION|KIND-UNKNOWN) .*anchor_source_archive_json' \
	&& bad "k7R directory-row kind=record pin: incorrectly flagged by the kind gate" \
	|| ok "k7R directory-row kind=record pin: not flagged (record is pinnable, resolution worked)"
teardown

# ---- k7L live: a kind violation fires exactly one high-priority alert -----
build_fake_repo
jq '.publications += [{"path":"api/stream2.json","kind":"stream"}]' \
	"$FAKE/deploy/publication.json" > "$BASE/reg.tmp" && mv "$BASE/reg.tmp" "$FAKE/deploy/publication.json"
jq '.artifact_manifest.stream2_json = {url:"https://example.test/api/stream2.json", sha256:"deadbeef00000000000000000000000000000000000000000000000000000000"}' \
	"$FAKE/public/api/identity.json" > "$BASE/id.tmp" && mv "$BASE/id.tmp" "$FAKE/public/api/identity.json"
make_curl_stub
serve "$FAKE/public/api/identity.json"     identity.json
serve "$FAKE/public/api/alpha.json"        alpha.json
serve "$FAKE/public/api/alpha.schema.json" alpha.schema.json
serve "$FAKE/public/api/stream.json"       stream.json
OUT="$(run_live)"; RC=$?
[ "$RC" -eq 6 ] && ok "k7L live: kind violation exits 6" || bad "k7L live: kind violation exit 6 (actual=$RC)"
[ "$(alert_count)" -eq 1 ] && ok "k7L live: kind violation fires exactly one push" || bad "k7L live: expected 1 push, got $(alert_count)"
alerts | grep -q '^high|' && ok "k7L live: push is high priority" || bad "k7L live: push priority (log: $(alerts))"
alerts | grep -q 'kind gate broken' && ok "k7L live: push names the kind gate" || bad "k7L live: push title (log: $(alerts))"
teardown

# =============================================================================
# k8 — real repo, SIMULATED post-9/4 state. jq-DERIVED from the REAL
# deploy/publication.json and the REAL public/api/identity.json — never a
# `cp`. A frozen copy would silently stop describing "post cleanup" the day
# the real files' SHAPE changes (this repo has hit exactly that trap before:
# tests/identity-kind-discipline/test-gen-identity-kind-discipline.sh and
# tests/publication-registry/test-publication-registry.sh T19 both exist
# because an earlier fixture was a frozen snapshot instead of a derivation).
# The derivation reproduces the two edits docs/CYCLE_GATE.md step 4b requires
# in the SAME commit:
#   (a) the re-issued manifest carries no sha256 for any publication the
#       REGISTRY currently marks kind=stream (schema pins are untouched,
#       since every schema in this repo is kind=static — C4's own
#       "schema_sha256 kept" case);
#   (b) known_kind_violations.violations is cleared, because the violations
#       it names no longer exist once (a) has happened.
# Asserting exit 0 here is the acceptance-criterion-2 "post step 4b" half;
# c24/c24b/c24c above are the "today" half, against the same real files
# unmodified.
# =============================================================================
K8_BASE="$(mktemp -d -t identity-pins-k8.XXXXXX)"
K8_REG="$K8_BASE/publication.json"
K8_ID="$K8_BASE/identity.json"

jq '.known_kind_violations.violations = {}' "${REPO_ROOT}/deploy/publication.json" > "$K8_REG"

jq --slurpfile reg "$K8_REG" '
	($reg[0].publications) as $pubs
	| def kind_of($u): ( ($u // "") | sub("^https?://[^/]+/"; "") ) as $rel
		| ( [ $pubs[] | select(.path == $rel) | .kind ] | first // "unknown" );
	.artifact_manifest |= with_entries(
		.value |= (
			( if (kind_of(.url)) == "stream" then del(.sha256) else . end )
			| ( if (has("schema_url") and (kind_of(.schema_url)) == "stream") then del(.schema_sha256) else . end )
		)
	)
' "${REPO_ROOT}/public/api/identity.json" > "$K8_ID"

# Sanity-check the derivation actually removed something, so this case cannot
# quietly degenerate into "green because nothing changed" if the jq above
# ever stops matching anything.
K8_REMOVED=$(( $(jq -r '.artifact_manifest | to_entries | map(select(.value.sha256 != null)) | length' "${REPO_ROOT}/public/api/identity.json") \
             - $(jq -r '.artifact_manifest | to_entries | map(select(.value.sha256 != null)) | length' "$K8_ID") ))
[ "$K8_REMOVED" -gt 0 ] \
	&& ok "k8 derivation actually strips ${K8_REMOVED} kind=stream payload pin(s) (not a no-op)" \
	|| bad "k8 derivation removed 0 pins — the simulation is not exercising anything"

OUT="$(FYD_REPO_ROOT="$REPO_ROOT" FYD_REGISTRY="$K8_REG" FYD_IDENTITY_FILE="$K8_ID" \
	IDENTITY_PIN_LOG="$K8_BASE/drift.log" IDENTITY_PIN_ALERT_STATE="$K8_BASE/state.json" \
	FYD_NOTIFY="$K8_BASE/nonexistent-notify.sh" \
	bash "$CHECKER" --mode=repo 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
	&& ok "k8 SIMULATED post-9/4 state (jq-derived from real files): exit 0" \
	|| bad "k8 SIMULATED post-9/4 state: exit 0 (actual=$RC, out: $OUT)"
echo "$OUT" | grep -qE '^(KIND-BASELINED|KIND-VIOLATION|KIND-UNKNOWN) ' \
	&& bad "k8 SIMULATED post-9/4 state: still reports a kind-gate line (cleanup incomplete in the simulation)" \
	|| ok "k8 SIMULATED post-9/4 state: no kind-gate line remains (matches the intended step-4b end state)"
echo "$OUT" | grep -q 'kind-new=0' \
	&& ok "k8 SIMULATED post-9/4 state: summary reports kind-new=0" || bad "k8 summary kind-new=0 (out: $OUT)"
rm -rf "$K8_BASE"

echo
echo "test-check-identity-pins.sh summary: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
