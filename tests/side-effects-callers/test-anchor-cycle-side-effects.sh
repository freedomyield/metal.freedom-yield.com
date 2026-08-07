#!/usr/bin/env bash
# tests/side-effects-callers/test-anchor-cycle-side-effects.sh
#
# C3-2b acceptance suite: the nine ANCHOR / CYCLE callers of
# scripts/lib/side-effects.sh must be dry by default and gated by
# construction.
#
#   scripts/append-anchor-history.sh      scripts/gen-anchor-source.sh
#   scripts/resume-after-cycle-start.sh   scripts/gen-cycle-history.sh
#   scripts/cycle-gate.sh                 scripts/run-anchor-pipeline.sh
#   scripts/check-anchor-publish-health.sh
#   scripts/watch-anchor-events.sh        scripts/notify-anchor-transition.sh
#
# CHAIN: none — no case reaches a broadcast-capable command. The one script
#        here that CAN broadcast (run-anchor-pipeline.sh, via
#        sign-anchor-event.sh → bin/safe-broadcast) is exercised only up to
#        its step-1 failure inside a sandbox that contains no signer at all,
#        so the broadcast path is not merely unused, it is absent.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (no chain interaction at all).
#
# ---------------------------------------------------------------------------
# WHY THIS SUITE DOES NOT STUB notify.sh OR push-to-web-host.sh
# ---------------------------------------------------------------------------
# The point of the C3 inversion is that a caller is inert WITHOUT anyone
# remembering to stub it. A suite that pointed FYD_NOTIFY / FYD_PUSH_TO_WEB_HOST
# at recording stubs would therefore prove nothing about the property under
# test: it would pass just as happily against the old opt-out code.
#
# So every sandbox here contains the REAL scripts/notify.sh and the REAL
# scripts/push-to-web-host.sh, a readable NTFY_TOPIC_FILE, a readable push key
# and a WEB_HOST value — everything those two need to actually go out — and no
# delegate override at all. The only thing standing between the script under
# test and the network is FY_LIVE. What is intercepted instead is one level
# lower: `curl` and `ssh` are replaced on PATH by recording tripwires, so "did
# a real notification / a real push leave the machine?" is answered by evidence
# (tripwire content) rather than by assumption.
#
# Part 2 then runs the SAME cases with FY_LIVE=1 and requires the opposite
# outcome — a tripwire hit and a real state mutation. Without Part 2, Part 1
# would be satisfied by a script that is simply broken.
#
# ---------------------------------------------------------------------------
# WHAT IS DELIBERATELY *NOT* GATED (asserted here so it cannot regress)
# ---------------------------------------------------------------------------
#   * append-anchor-history.sh's APPEND. A forgotten FY_LIVE must cost a
#     deferred publish (recoverable — the manual command is printed), never a
#     missing line in an append-only ledger derived from a one-shot receipt.
#     Case 1a asserts the line IS written while everything outbound is not.
#   * gen-cycle-history.sh's regeneration, and gen-anchor-source.sh's output.
#     Deterministic generators, run by hand at a transition, not covered by
#     the cron env-header guarantee — gating them would convert a visible
#     artifact into silent staleness. Cases 1g/1h assert they still produce
#     output while touching nothing outbound.
#   * cycle-gate.sh's VERDICT. Seven scripts consult it; a gate that went
#     quiet under a dry run would stop every recording path on transition
#     day. Part 3 pins the verdict identical in both modes, scenario by
#     scenario.
#
# ---------------------------------------------------------------------------
# PATH stand-ins (all test-local; nothing on this machine is modified)
# ---------------------------------------------------------------------------
#   curl  records argv; answers ntfy.sh with HTTP 200; answers a metalgo
#         /ext/bc/P POST from $FYD_TEST_RPC_JSON when that points at a
#         readable file; fails everything else like an unreachable host.
#   ssh   records argv, succeeds (exit 0) so push-to-web-host.sh's 5s/15s
#         retry backoff never runs — a suite must not sleep 40 seconds to
#         observe a push it already recorded.
#   ajv   always "valid": R13 schema validation is another suite's subject.
#
# Usage:
#   bash tests/side-effects-callers/test-anchor-cycle-side-effects.sh
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

TARGETS="append-anchor-history.sh resume-after-cycle-start.sh cycle-gate.sh check-anchor-publish-health.sh watch-anchor-events.sh notify-anchor-transition.sh gen-anchor-source.sh gen-cycle-history.sh run-anchor-pipeline.sh"

for f in $TARGETS; do
	if [ ! -r "${SCRIPTS}/${f}" ]; then
		echo "FATAL: expected file missing: ${SCRIPTS}/${f}" >&2
		exit 1
	fi
done
for f in "$LIB" "${SCRIPTS}/notify.sh" "${SCRIPTS}/push-to-web-host.sh" \
	"${SCRIPTS}/publish-guard.sh" \
	"${REPO_ROOT}/public/api/anchor-history.schema.v2.json" \
	"${REPO_ROOT}/public/api/anchor-receipt.v2.example.json"; do
	if [ ! -r "$f" ]; then
		echo "FATAL: expected file missing: $f" >&2
		exit 1
	fi
done

PASS=0
FAIL=0
SKIP=0
FAILURES=()
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILURES+=("$1${2:+ — $2}"); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}" >&2; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s%s\n' "$1" "${2:+ — $2}"; }

TMP="$(mktemp -d -t fy-c32b-callers.XXXXXX)"
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
# metalgo P-chain RPC: answer from a fixture when the case supplied one.
for a in "\$@"; do
	case "\$a" in
		*/ext/bc/P)
			if [ -n "\${FYD_TEST_RPC_JSON:-}" ] && [ -r "\${FYD_TEST_RPC_JSON}" ]; then
				cat "\${FYD_TEST_RPC_JSON}"
				exit 0
			fi
			;;
	esac
done
exit 7
CURLEOF
chmod +x "${BIN}/curl"

cat >"${BIN}/ssh" <<SSHEOF
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'ssh %s\n' "\$*" >>"${TRIPWIRE}"
exit 0
SSHEOF
chmod +x "${BIN}/ssh"

cat >"${BIN}/ajv" <<'AJVEOF'
#!/usr/bin/env bash
exit 0
AJVEOF
chmod +x "${BIN}/ajv"

export PATH="${BIN}:${PATH}"

ntfy_hits() { grep -c 'ntfy\.sh' "$TRIPWIRE" 2>/dev/null | tr -d '[:space:]'; }
ssh_hits()  { grep -c '^ssh '   "$TRIPWIRE" 2>/dev/null | tr -d '[:space:]'; }
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
	mkdir -p "${S}/scripts/lib" "${S}/public/api" "${S}/public/calendar" "${S}/logs"
	# Mirror scripts/lib/ as a WHOLE DIRECTORY, not a hand-picked file. Naming
	# just side-effects.sh here is exactly the bug that broke this suite when
	# push-to-web-host.sh grew a second hard dependency, scripts/lib/
	# publish-scan.sh, during the C3 integration (task h5, 2026-08-07): the
	# real repo ships scripts/lib/ as one git-tracked unit, so the sandbox
	# must carry it the same way — as a unit — or the NEXT scripts/lib/*.sh
	# addition silently repeats this failure. See the mirrored-growth
	# regression guard near the end of this file.
	cp -R "${SCRIPTS}/lib/." "${S}/scripts/lib/"
	cp "${SCRIPTS}/notify.sh" "${S}/scripts/notify.sh"
	cp "${SCRIPTS}/push-to-web-host.sh" "${S}/scripts/push-to-web-host.sh"
	# publish-scan.sh (mirrored above) requires this SIBLING of lib/ at
	# runtime — see FYD_PUBLISH_SCAN_GUARD in scripts/lib/publish-scan.sh.
	# Named explicitly, like notify.sh and push-to-web-host.sh above, because
	# it is a top-level delegate script, not a scripts/lib/ member.
	cp "${SCRIPTS}/publish-guard.sh" "${S}/scripts/publish-guard.sh"
	local s
	for s in "$@"; do cp "${SCRIPTS}/${s}" "${S}/scripts/${s}"; chmod +x "${S}/scripts/${s}"; done
	printf 'sandbox-topic-not-a-real-topic\n' >"${S}/topic"
	printf 'not-a-real-key\n' >"${S}/push-key"
	chmod 600 "${S}/push-key"
}

# Synthetic 64-hex identifiers (no real tx id / dag root ever appears here).
TX_ID="a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7"
DAG_ROOT="b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8"
DAG_OTHER="c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9c9"

# make_receipt <out> — a schema-valid v2 receipt derived from the tracked
# example (same shape as tests/append-anchor-history/'s builder; duplicated
# deliberately, this repo has no cross-test sourcing convention).
make_receipt() {
	jq --arg tx_id "$TX_ID" \
		--argjson block_num 100000001 \
		--argjson cycle_number 3 \
		--arg dag_root_hash "$DAG_ROOT" \
		'.anchor.tx_id = $tx_id
		 | .anchor.block_num = $block_num
		 | .cycle_number = $cycle_number
		 | .dag_root_hash = $dag_root_hash
		 | .anchor.actions[3].root_hex = $dag_root_hash
		 | .anchor.actions[3].memo = "\(.memo_prefix):\($dag_root_hash)"
		 | .prev_anchor_tx_id = null
		 | .trigger_event = "cyclestart"
		 | .verification_status = "live"' \
		"${REPO_ROOT}/public/api/anchor-receipt.v2.example.json" >"$1"
}

# ===========================================================================
echo "== Part 1/5: dry by default (no FY_LIVE, no stubs) =="
# ===========================================================================

# ---- 1a append-anchor-history.sh ------------------------------------------
# The append MUST still happen; only the two R18 pushes and the failure alert
# are suppressed. This is the one case in the suite whose "no side effect"
# expectation is deliberately partial.
setup_append() {
	mk_repo "$1" append-anchor-history.sh
	mkdir -p "${S}/public/api/archive"
	cp "${REPO_ROOT}/public/api/anchor-history.schema.v2.json" "${S}/public/api/"
	make_receipt "${S}/receipt.json"
	printf '{}\n' >"${S}/public/api/archive/anchor-source-${DAG_ROOT}.json"
	printf '{}\n' >"${S}/public/api/archive/anchor-receipt-${TX_ID}.json"
}
run_append() {   # <FY_LIVE value>
	env FY_LIVE="$1" \
		WEB_HOST="sandbox-user@sandbox-host.invalid" \
		WEB_PUSH_KEY="${S}/push-key" \
		NTFY_TOPIC_FILE="${S}/topic" \
		bash "${S}/scripts/append-anchor-history.sh" \
		--receipt="${S}/receipt.json" \
		--history="${S}/public/api/anchor-history.jsonl" \
		--event-type=cyclestart
}

setup_append append-dry
reset_tripwire
run_append "" >"${TMP}/1a.out" 2>"${TMP}/1a.err"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "1a append-anchor-history: dry run exits 0" \
	|| bad "1a append-anchor-history: dry run exits 0" "rc=$RC $(tail -3 "${TMP}/1a.err")"
[ "$(wc -l <"${S}/public/api/anchor-history.jsonl" | tr -d ' ')" = "1" ] \
	&& ok "1a append-anchor-history: THE APPEND STILL HAPPENS while dry (deliberate — see header)" \
	|| bad "1a append-anchor-history: THE APPEND STILL HAPPENS while dry"
grep -q "DRY: would push archive/anchor-source-${DAG_ROOT}.json" "${TMP}/1a.err" \
	&& ok "1a append-anchor-history: the source-archive push is announced as suppressed" \
	|| bad "1a append-anchor-history: the source-archive push is announced as suppressed" "$(grep DRY: "${TMP}/1a.err" | head -3)"
grep -q "DRY: would push archive/anchor-receipt-${TX_ID}.json" "${TMP}/1a.err" \
	&& ok "1a append-anchor-history: the receipt-archive push is announced as suppressed" \
	|| bad "1a append-anchor-history: the receipt-archive push is announced as suppressed"
grep -q 'DEFERRED: R18 publish' "${TMP}/1a.err" \
	&& ok "1a append-anchor-history: a suppressed push is NOT reported as published" \
	|| bad "1a append-anchor-history: a suppressed push is NOT reported as published" "$(grep -E 'OK: published|DEFERRED' "${TMP}/1a.err" | head -3)"
grep -q "bash '${S}/scripts/push-to-web-host.sh' 'archive/anchor-source-${DAG_ROOT}.json'" "${TMP}/1a.err" \
	&& ok "1a append-anchor-history: the exact manual push command is printed" \
	|| bad "1a append-anchor-history: the exact manual push command is printed"
grep -q 'OK: published' "${TMP}/1a.err" \
	&& bad "1a append-anchor-history: no false 'OK: published' while dry" \
	|| ok "1a append-anchor-history: no false 'OK: published' while dry"
[ "$(ssh_hits)" = "0" ] && [ "$(ntfy_hits)" = "0" ] \
	&& ok "1a append-anchor-history: nothing reached ssh or ntfy.sh" \
	|| bad "1a append-anchor-history: nothing reached ssh or ntfy.sh" "$(head -3 "$TRIPWIRE")"

# ---- 1b resume-after-cycle-start.sh --apply -------------------------------
mk_repo resume-dry resume-after-cycle-start.sh
reset_tripwire
env FY_LIVE= FY_STATE_DIR="${S}/state" METALGO_RPC="http://127.0.0.1:1" \
	PUBLIC_BASE="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	FY_POLL_INTERVAL=1 FY_POLL_MAX_SEC=3 \
	bash "${S}/scripts/resume-after-cycle-start.sh" --apply \
	>"${TMP}/1b.out" 2>"${TMP}/1b.err"
RC=$?
[ "$RC" -eq 6 ] \
	&& ok "1b resume --apply: refuses with exit 6 instead of running dry" \
	|| bad "1b resume --apply: refuses with exit 6" "rc=$RC $(tail -3 "${TMP}/1b.err")"
grep -q 'FY_LIVE=1 is required' "${TMP}/1b.err" \
	&& ok "1b resume --apply: refusal names the missing opt-in" \
	|| bad "1b resume --apply: refusal names the missing opt-in"
grep -q 'FY_LIVE=1 bash' "${TMP}/1b.err" \
	&& ok "1b resume --apply: refusal prints a corrected command" \
	|| bad "1b resume --apply: refusal prints a corrected command"
[ ! -e "${S}/state" ] \
	&& ok "1b resume --apply: refused before creating the state dir" \
	|| bad "1b resume --apply: refused before creating the state dir"
[ "$(ntfy_hits)" = "0" ] && [ ! -s "${TMP}/1b.out" ] \
	&& ok "1b resume --apply: refused before any RPC / artifact fetch" \
	|| bad "1b resume --apply: refused before any RPC / artifact fetch" "$(head -3 "$TRIPWIRE")"

# ---- 1c resume-after-cycle-start.sh --dry-run -----------------------------
# --dry-run needs no opt-in and must still reach Phase 1 (RPC down → exit 2),
# but must not create the production state dir on the way there.
mk_repo resume-dryrun resume-after-cycle-start.sh
reset_tripwire
env FY_LIVE= FY_STATE_DIR="${S}/state" METALGO_RPC="http://127.0.0.1:1" \
	PUBLIC_BASE="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	FY_POLL_INTERVAL=1 FY_POLL_MAX_SEC=3 \
	bash "${S}/scripts/resume-after-cycle-start.sh" --dry-run \
	>"${TMP}/1c.out" 2>"${TMP}/1c.err"
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "1c resume --dry-run: needs no opt-in, reaches Phase 1 (RPC down → 2)" \
	|| bad "1c resume --dry-run: needs no opt-in, reaches Phase 1 (RPC down → 2)" "rc=$RC"
[ ! -e "${S}/state" ] \
	&& ok "1c resume --dry-run: the state dir was not even created" \
	|| bad "1c resume --dry-run: the state dir was not even created"
grep -q 'DRY: would create the cycle-gate state dir' "${TMP}/1c.err" \
	&& ok "1c resume --dry-run: the mkdir is announced as suppressed" \
	|| bad "1c resume --dry-run: the mkdir is announced as suppressed" "$(grep DRY: "${TMP}/1c.err" | head -3)"

# ---- 1d check-anchor-publish-health.sh ------------------------------------
# Content mismatch (exit 3): the alert AND the dedup-state write must both be
# suppressed, and the verdict must not move.
setup_publish_health() {
	mk_repo "$1" check-anchor-publish-health.sh
	cat >"${S}/src.json" <<JSON
{ "dag_root_computed": "${DAG_ROOT}" }
JSON
	cat >"${S}/rcpt.json" <<JSON
{ "dag_root_hash": "${DAG_OTHER}",
  "anchor": { "actions": [ { "branch": "dag_root_summary", "memo": "fya1c3:${DAG_OTHER}", "root_hex": "${DAG_OTHER}" } ] } }
JSON
	cat >"${S}/curl-stub" <<STUBEOF
#!/usr/bin/env bash
out=""
url=""
prev=""
for a in "\$@"; do
	[ "\$prev" = "-o" ] && out="\$a"
	case "\$a" in http*) url="\$a" ;; esac
	prev="\$a"
done
case "\$url" in
	*anchor-source.json) cp "${S}/src.json"  "\$out" ;;
	*)                   cp "${S}/rcpt.json" "\$out" ;;
esac
printf '200'
STUBEOF
	chmod +x "${S}/curl-stub"
}
run_publish_health() {   # <FY_LIVE value>
	env FY_LIVE="$1" \
		FYD_CURL="${S}/curl-stub" \
		FYD_RETRY_SLEEP=0 FYD_FETCH_ATTEMPTS=1 \
		ANCHOR_SOURCE_URL="https://sandbox.invalid/api/anchor-source.json" \
		ANCHOR_RECEIPT_URL="https://sandbox.invalid/api/anchor-receipt.json" \
		ANCHOR_PUBLISH_HEALTH_LOG="${S}/logs/health.log" \
		ANCHOR_PUBLISH_HEALTH_MISMATCH_STATE="${S}/logs/mismatch-state.json" \
		NTFY_TOPIC_FILE="${S}/topic" \
		bash "${S}/scripts/check-anchor-publish-health.sh"
}

setup_publish_health health-dry
reset_tripwire
run_publish_health "" >"${TMP}/1d.out" 2>"${TMP}/1d.err"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "1d check-anchor-publish-health: the verdict is unchanged while dry (exit 3)" \
	|| bad "1d check-anchor-publish-health: the verdict is unchanged while dry (exit 3)" "rc=$RC $(tail -3 "${TMP}/1d.err")"
grep -q 'DRY: would notify prio=high .*content mismatch' "${TMP}/1d.err" \
	&& ok "1d check-anchor-publish-health: the alert is announced as suppressed" \
	|| bad "1d check-anchor-publish-health: the alert is announced as suppressed" "$(grep DRY: "${TMP}/1d.err" | head -3)"
grep -q 'DRY: would record the exit-3 mismatch dedup window' "${TMP}/1d.err" \
	&& ok "1d check-anchor-publish-health: the dedup-state write is announced as suppressed" \
	|| bad "1d check-anchor-publish-health: the dedup-state write is announced as suppressed"
[ ! -e "${S}/logs/mismatch-state.json" ] \
	&& ok "1d check-anchor-publish-health: no dedup state written (a dry tick cannot mute the next live one)" \
	|| bad "1d check-anchor-publish-health: no dedup state written"
[ -z "$(find "${S}/logs" -name '.anchor-publish-health-mismatch.*' 2>/dev/null)" ] \
	&& ok "1d check-anchor-publish-health: no stray mktemp scratch left behind" \
	|| bad "1d check-anchor-publish-health: no stray mktemp scratch left behind"
[ -s "${S}/logs/health.log" ] \
	&& ok "1d check-anchor-publish-health: the audit log line is still written (not gated)" \
	|| bad "1d check-anchor-publish-health: the audit log line is still written (not gated)"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1d check-anchor-publish-health: nothing reached ntfy.sh" \
	|| bad "1d check-anchor-publish-health: nothing reached ntfy.sh"

# ---- 1e watch-anchor-events.sh (+ its real driver) ------------------------
# Prior state says absent, the RPC says present → cyclestart. The driver is
# the REAL notify-anchor-transition.sh, so this case covers both scripts and
# proves the send and the baseline advance are suppressed TOGETHER.
setup_watch() {
	mk_repo "$1" watch-anchor-events.sh notify-anchor-transition.sh
	mkdir -p "${S}/state"
	cat >"${S}/rpc-present.json" <<JSON
{"jsonrpc":"2.0","id":1,"result":{"validators":[{"nodeID":"NodeID-sandboxwatcher1111111111111111111"}]}}
JSON
	printf '{"node_id":"NodeID-sandboxwatcher1111111111111111111","is_present":0,"last_check":"2026-01-01T00:00:00Z","last_event":"none"}\n' \
		>"${S}/state/anchor-watcher-state.json"
}
run_watch() {   # <FY_LIVE value>
	env FY_LIVE="$1" \
		NODE_ID="NodeID-sandboxwatcher1111111111111111111" \
		METALGO_RPC="http://sandbox.invalid:9650" \
		FYD_TEST_RPC_JSON="${S}/rpc-present.json" \
		FY_STATE_DIR="${S}/state" \
		NTFY_TOPIC_FILE="${S}/topic" \
		NOTIFY_RETRY_SLEEP=0 \
		bash "${S}/scripts/watch-anchor-events.sh"
}

setup_watch watch-dry
reset_tripwire
BEFORE_HASH="$(hashof "${S}/state/anchor-watcher-state.json")"
run_watch "" >"${TMP}/1e.out" 2>"${TMP}/1e.err"
RC=$?
AFTER_HASH="$(hashof "${S}/state/anchor-watcher-state.json")"
[ "$RC" -eq 0 ] \
	&& ok "1e watch-anchor-events: dry run exits 0" \
	|| bad "1e watch-anchor-events: dry run exits 0" "rc=$RC $(tail -3 "${TMP}/1e.err")"
grep -q 'transition: was=0 now=1 → event=cyclestart' "${TMP}/1e.out" \
	&& ok "1e watch-anchor-events: the transition is still DETECTED while dry" \
	|| bad "1e watch-anchor-events: the transition is still DETECTED while dry" "$(head -3 "${TMP}/1e.out")"
grep -q 'DRY: would notify prio=high .*Anchor: manual action required' "${TMP}/1e.err" \
	&& ok "1e notify-anchor-transition: the dispatch alert is announced as suppressed" \
	|| bad "1e notify-anchor-transition: the dispatch alert is announced as suppressed" "$(grep DRY: "${TMP}/1e.err" | head -3)"
grep -q 'DRY: would write the anchor-watcher state' "${TMP}/1e.err" \
	&& ok "1e watch-anchor-events: the state write is announced as suppressed" \
	|| bad "1e watch-anchor-events: the state write is announced as suppressed"
[ "$BEFORE_HASH" = "$AFTER_HASH" ] \
	&& ok "1e watch-anchor-events: baseline byte-identical after the dry run" \
	|| bad "1e watch-anchor-events: baseline byte-identical after the dry run"
[ ! -e "${S}/state/anchor-watcher-state.json.new" ] \
	&& ok "1e watch-anchor-events: no stray .new left in the state dir" \
	|| bad "1e watch-anchor-events: no stray .new left in the state dir"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1e watch-anchor-events: nothing reached ntfy.sh" \
	|| bad "1e watch-anchor-events: nothing reached ntfy.sh"

# ---- 1f notify-anchor-transition.sh (standalone) --------------------------
mk_repo driver-dry notify-anchor-transition.sh
reset_tripwire
env FY_LIVE= NTFY_TOPIC_FILE="${S}/topic" NOTIFY_RETRY_SLEEP=0 \
	bash "${S}/scripts/notify-anchor-transition.sh" --event-type=cycleend \
	>"${TMP}/1f.out" 2>"${TMP}/1f.err"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "1f notify-anchor-transition: dry run reports CONFIRMED (exit 0)" \
	|| bad "1f notify-anchor-transition: dry run reports CONFIRMED (exit 0)" "rc=$RC"
grep -q 'DRY: would notify prio=high' "${TMP}/1f.err" \
	&& ok "1f notify-anchor-transition: the alert is announced as suppressed" \
	|| bad "1f notify-anchor-transition: the alert is announced as suppressed"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1f notify-anchor-transition: nothing reached ntfy.sh" \
	|| bad "1f notify-anchor-transition: nothing reached ntfy.sh"

# The acceptance criterion names three shapes of "not live": unset, "0", and
# empty. The library's own suite proves fyd_is_live's exact-match rule; this
# checks the shapes end-to-end through a real caller, since a caller could in
# principle re-read FY_LIVE with looser semantics of its own.
for shape in unset zero empty; do
	reset_tripwire
	case "$shape" in
		unset) env -u FY_LIVE NTFY_TOPIC_FILE="${S}/topic" NOTIFY_RETRY_SLEEP=0 \
			bash "${S}/scripts/notify-anchor-transition.sh" --event-type=cycleend >/dev/null 2>"${TMP}/1f-${shape}.err" ;;
		zero)  env FY_LIVE=0 NTFY_TOPIC_FILE="${S}/topic" NOTIFY_RETRY_SLEEP=0 \
			bash "${S}/scripts/notify-anchor-transition.sh" --event-type=cycleend >/dev/null 2>"${TMP}/1f-${shape}.err" ;;
		empty) env FY_LIVE= NTFY_TOPIC_FILE="${S}/topic" NOTIFY_RETRY_SLEEP=0 \
			bash "${S}/scripts/notify-anchor-transition.sh" --event-type=cycleend >/dev/null 2>"${TMP}/1f-${shape}.err" ;;
	esac
	RC=$?
	if [ "$RC" -eq 0 ] && [ "$(ntfy_hits)" = "0" ] && grep -q 'DRY: would notify' "${TMP}/1f-${shape}.err"; then
		ok "1f notify-anchor-transition: FY_LIVE ${shape} is suppressed end-to-end"
	else
		bad "1f notify-anchor-transition: FY_LIVE ${shape} is suppressed end-to-end" "rc=$RC hits=$(ntfy_hits)"
	fi
done

# ---- 1g gen-anchor-source.sh ----------------------------------------------
# Read-only consumer of the state dir. It must never create it, and must
# reach nothing outbound, whatever else it does with an unreachable RPC.
mk_repo gensrc-dry gen-anchor-source.sh
reset_tripwire
env FY_LIVE= FY_STATE_DIR="${S}/state" METALGO_API="http://127.0.0.1:1" \
	API_BASE_URL="http://127.0.0.1:1/api" \
	PUBKEY_URL="http://127.0.0.1:1/pub" \
	NTFY_TOPIC_FILE="${S}/topic" \
	bash "${S}/scripts/gen-anchor-source.sh" >"${TMP}/1g.out" 2>"${TMP}/1g.err"
[ ! -e "${S}/state" ] \
	&& ok "1g gen-anchor-source: never creates the state dir (read-only consumer)" \
	|| bad "1g gen-anchor-source: never creates the state dir (read-only consumer)"
[ "$(ntfy_hits)" = "0" ] && [ "$(ssh_hits)" = "0" ] \
	&& ok "1g gen-anchor-source: nothing reached ssh or ntfy.sh" \
	|| bad "1g gen-anchor-source: nothing reached ssh or ntfy.sh" "$(head -3 "$TRIPWIRE")"

# ---- 1h gen-cycle-history.sh ----------------------------------------------
# NOT gated on purpose (see header): a dry run must still regenerate the feed.
mk_repo gencycle-dry gen-cycle-history.sh cycle-gate.sh
cat >"${S}/public/api/uptime-cycles.json" <<'JSON'
{ "cycles": [ { "cycle_n": 1, "node_id": "NodeID-sandbox", "start_iso": "2026-01-01T00:00:00Z",
  "end_iso": "2026-02-01T00:00:00Z", "duration_days": 31, "final_uptime_pct": 99.9,
  "days_recorded": 31, "final_self_stake_metal": 1, "final_total_delegated_metal": 0,
  "final_delegation_fee_pct": 3, "avg_peer_count": 100, "min_peer_count": 90,
  "explorer_url": "https://sandbox.invalid/v1", "notes": null } ] }
JSON
printf '{ "incidents": [] }\n' >"${S}/public/api/incidents.json"
reset_tripwire
env FY_LIVE= FY_STATE_DIR="${S}/state" NTFY_TOPIC_FILE="${S}/topic" \
	bash "${S}/scripts/gen-cycle-history.sh" >"${TMP}/1h.out" 2>"${TMP}/1h.err"
RC=$?
[ "$RC" -eq 0 ] && [ -s "${S}/public/api/cycle-history.jsonl" ] \
	&& ok "1h gen-cycle-history: STILL REGENERATES its feed while dry (deliberate — see header)" \
	|| bad "1h gen-cycle-history: STILL REGENERATES its feed while dry" "rc=$RC $(tail -3 "${TMP}/1h.err")"
[ ! -e "${S}/state" ] \
	&& ok "1h gen-cycle-history: touches no state dir" \
	|| bad "1h gen-cycle-history: touches no state dir"
[ "$(ntfy_hits)" = "0" ] && [ "$(ssh_hits)" = "0" ] \
	&& ok "1h gen-cycle-history: nothing reached ssh or ntfy.sh" \
	|| bad "1h gen-cycle-history: nothing reached ssh or ntfy.sh"

# ---- 1i run-anchor-pipeline.sh --------------------------------------------
# FYD_ALLOW_STALE_PIPELINE=1 fires the bypass alert, then step 1 fails because
# the sandbox has no generator (and, deliberately, no signer at all).
run_pipeline() {   # <FY_LIVE value>
	env FY_LIVE="$1" FYD_ALLOW_STALE_PIPELINE=1 NTFY_TOPIC_FILE="${S}/topic" \
		bash "${S}/scripts/run-anchor-pipeline.sh" --chain=testnet-a
}
mk_repo pipeline-dry run-anchor-pipeline.sh
reset_tripwire
run_pipeline "" >"${TMP}/1i.out" 2>"${TMP}/1i.err"
RC=$?
[ "$RC" -eq 11 ] \
	&& ok "1i run-anchor-pipeline: control flow unchanged while dry (step-1 failure → 11)" \
	|| bad "1i run-anchor-pipeline: control flow unchanged while dry (step-1 failure → 11)" "rc=$RC"
grep -q 'DRY: would notify prio=high .*freshness gate BYPASSED' "${TMP}/1i.err" \
	&& ok "1i run-anchor-pipeline: the bypass alert is announced as suppressed" \
	|| bad "1i run-anchor-pipeline: the bypass alert is announced as suppressed" "$(grep DRY: "${TMP}/1i.err" | head -3)"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1i run-anchor-pipeline: nothing reached ntfy.sh" \
	|| bad "1i run-anchor-pipeline: nothing reached ntfy.sh"

echo
# ===========================================================================
echo "== Part 2/5: FY_LIVE=1 differential (proves Part 1 is not vacuous) =="
# ===========================================================================

setup_append append-live
reset_tripwire
run_append 1 >"${TMP}/2a.out" 2>"${TMP}/2a.err"
RC=$?
[ "$(ssh_hits)" = "2" ] \
	&& ok "2a append-anchor-history: FY_LIVE=1 does push both archives (2 ssh)" \
	|| bad "2a append-anchor-history: FY_LIVE=1 does push both archives (2 ssh)" "rc=$RC hits=$(ssh_hits) $(tail -3 "${TMP}/2a.err")"
grep -q "ssh .*archive/anchor-source-${DAG_ROOT}.json" "$TRIPWIRE" \
	&& ok "2a append-anchor-history: the pushed remote command carries the source-archive path" \
	|| bad "2a append-anchor-history: the pushed remote command carries the source-archive path" "$(head -3 "$TRIPWIRE")"
grep -q 'OK: published anchor-source' "${TMP}/2a.err" \
	&& ok "2a append-anchor-history: a real push IS reported as published" \
	|| bad "2a append-anchor-history: a real push IS reported as published"
grep -q 'DRY:' "${TMP}/2a.err" \
	&& bad "2a append-anchor-history: no DRY: line under FY_LIVE=1" "$(grep DRY: "${TMP}/2a.err" | head -2)" \
	|| ok "2a append-anchor-history: no DRY: line under FY_LIVE=1"

mk_repo resume-live resume-after-cycle-start.sh
reset_tripwire
env FY_LIVE=1 FY_STATE_DIR="${S}/state" METALGO_RPC="http://127.0.0.1:1" \
	PUBLIC_BASE="http://127.0.0.1:1" FY_RPC_TIMEOUT=2 \
	FY_POLL_INTERVAL=1 FY_POLL_MAX_SEC=3 \
	bash "${S}/scripts/resume-after-cycle-start.sh" --apply \
	>"${TMP}/2b.out" 2>"${TMP}/2b.err"
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "2b resume --apply: FY_LIVE=1 passes the refusal and reaches Phase 1 (RPC down → 2)" \
	|| bad "2b resume --apply: FY_LIVE=1 passes the refusal and reaches Phase 1" "rc=$RC $(tail -3 "${TMP}/2b.err")"
[ -d "${S}/state" ] \
	&& ok "2b resume --apply: FY_LIVE=1 does create the state dir" \
	|| bad "2b resume --apply: FY_LIVE=1 does create the state dir"

setup_publish_health health-live
reset_tripwire
run_publish_health 1 >"${TMP}/2d.out" 2>"${TMP}/2d.err"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "2d check-anchor-publish-health: verdict identical under FY_LIVE=1 (exit 3)" \
	|| bad "2d check-anchor-publish-health: verdict identical under FY_LIVE=1 (exit 3)" "rc=$RC"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2d check-anchor-publish-health: FY_LIVE=1 does reach ntfy.sh" \
	|| bad "2d check-anchor-publish-health: FY_LIVE=1 does reach ntfy.sh" "$(tail -3 "${TMP}/2d.err")"
[ -s "${S}/logs/mismatch-state.json" ] \
	&& ok "2d check-anchor-publish-health: FY_LIVE=1 does write the dedup state" \
	|| bad "2d check-anchor-publish-health: FY_LIVE=1 does write the dedup state"

setup_watch watch-live
reset_tripwire
BEFORE_HASH="$(hashof "${S}/state/anchor-watcher-state.json")"
run_watch 1 >"${TMP}/2e.out" 2>"${TMP}/2e.err"
AFTER_HASH="$(hashof "${S}/state/anchor-watcher-state.json")"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2e watch-anchor-events: FY_LIVE=1 does reach ntfy.sh through the real driver" \
	|| bad "2e watch-anchor-events: FY_LIVE=1 does reach ntfy.sh through the real driver" "$(tail -3 "${TMP}/2e.err")"
[ "$BEFORE_HASH" != "$AFTER_HASH" ] \
	&& ok "2e watch-anchor-events: FY_LIVE=1 does advance the baseline" \
	|| bad "2e watch-anchor-events: FY_LIVE=1 does advance the baseline"
[ "$(jq -r '.is_present' "${S}/state/anchor-watcher-state.json")" = "1" ] \
	&& ok "2e watch-anchor-events: the advanced baseline carries the observed value" \
	|| bad "2e watch-anchor-events: the advanced baseline carries the observed value"

mk_repo driver-live notify-anchor-transition.sh
reset_tripwire
env FY_LIVE=1 NTFY_TOPIC_FILE="${S}/topic" NOTIFY_RETRY_SLEEP=0 \
	bash "${S}/scripts/notify-anchor-transition.sh" --event-type=cycleend \
	>"${TMP}/2f.out" 2>"${TMP}/2f.err"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2f notify-anchor-transition: FY_LIVE=1 does reach ntfy.sh" \
	|| bad "2f notify-anchor-transition: FY_LIVE=1 does reach ntfy.sh"

mk_repo pipeline-live run-anchor-pipeline.sh
reset_tripwire
run_pipeline 1 >"${TMP}/2i.out" 2>"${TMP}/2i.err"
RC=$?
[ "$RC" -eq 11 ] \
	&& ok "2i run-anchor-pipeline: control flow identical under FY_LIVE=1 (→ 11)" \
	|| bad "2i run-anchor-pipeline: control flow identical under FY_LIVE=1 (→ 11)" "rc=$RC"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2i run-anchor-pipeline: FY_LIVE=1 does reach ntfy.sh" \
	|| bad "2i run-anchor-pipeline: FY_LIVE=1 does reach ntfy.sh"

echo
# ===========================================================================
echo "== Part 3/5: cycle-gate's VERDICT must be identical dry and live =="
# ===========================================================================
# Seven scripts consult this gate before deciding whether to write or notify.
# If it started answering differently under a dry FY_LIVE, transition day
# would silently stop every recording path. Each scenario below is run twice
# — once with FY_LIVE unset, once with FY_LIVE=1 — and the two exit codes
# must match AND match the documented expectation.

mk_repo gate-verdict cycle-gate.sh
mkdir -p "${S}/state-empty" "${S}/state-corrupt" "${S}/state-valid"
printf 'not json at all\n' >"${S}/state-corrupt/cycle-gate-state.json"
cat >"${S}/state-valid/cycle-gate-state.json" <<JSON
{ "schemaVersion": 1,
  "approved_cycle_signature": "NodeID-sandboxgate11111111111111111111-1700000000",
  "approved_dag_root_hash": "${DAG_ROOT}",
  "approved_at": "2026-01-01T00:00:00Z" }
JSON
cat >"${S}/rpc-match.json" <<'JSON'
{"jsonrpc":"2.0","id":1,"result":{"validators":[{"nodeID":"NodeID-sandboxgate11111111111111111111","startTime":"1700000000"}]}}
JSON
cat >"${S}/rpc-other.json" <<'JSON'
{"jsonrpc":"2.0","id":1,"result":{"validators":[{"nodeID":"NodeID-sandboxgate11111111111111111111","startTime":"1799999999"}]}}
JSON

gate_run() {   # <FY_LIVE value> <state dir> <rpc fixture ('' = unreachable)> <args...>
	local live="$1" statedir="$2" rpc="$3"; shift 3
	env FY_LIVE="$live" \
		FY_STATE_DIR="${S}/${statedir}" \
		FY_RPC_TIMEOUT=2 \
		NODE_ID="NodeID-sandboxgate11111111111111111111" \
		METALGO_RPC="http://sandbox.invalid:9650" \
		FYD_TEST_RPC_JSON="${rpc:+${S}/${rpc}}" \
		bash "${S}/scripts/cycle-gate.sh" "$@" 2>"${TMP}/gate.err"
}

# verdict_same <label> <expected rc> <state dir> <rpc fixture> <args...>
verdict_same() {
	local label="$1" want="$2" statedir="$3" rpc="$4"; shift 4
	local rc_dry rc_live
	gate_run "" "$statedir" "$rpc" "$@"; rc_dry=$?
	local dry_err; dry_err="$(grep -c 'DRY:' "${TMP}/gate.err" 2>/dev/null | tr -d '[:space:]')"
	gate_run 1 "$statedir" "$rpc" "$@"; rc_live=$?
	if [ "$rc_dry" = "$rc_live" ] && [ "$rc_dry" = "$want" ]; then
		ok "3 verdict identical dry/live: ${label} → ${want}"
	else
		bad "3 verdict identical dry/live: ${label} → ${want}" "dry=$rc_dry live=$rc_live"
	fi
	if [ "${dry_err:-0}" = "0" ]; then
		ok "3 no side effect suppressed: ${label} emits no DRY: line"
	else
		bad "3 no side effect suppressed: ${label} emits no DRY: line" "$(grep 'DRY:' "${TMP}/gate.err" | head -2)"
	fi
}

verdict_same "observe"                          0 state-empty   ""          --side-effect=observe
verdict_same "cycle-artifact-write"             0 state-empty   ""          --side-effect=cycle-artifact-write
verdict_same "broadcast + state absent"         0 state-empty   ""          --side-effect=broadcast
verdict_same "broadcast + corrupt state"        1 state-corrupt ""          --side-effect=broadcast
verdict_same "broadcast + RPC unreachable"      1 state-valid   ""          --side-effect=broadcast
verdict_same "cycle-aware-notify + signature match"    0 state-valid rpc-match.json --side-effect=cycle-aware-notify
verdict_same "cycle-aware-notify + signature differs"  1 state-valid rpc-other.json --side-effect=cycle-aware-notify
verdict_same "invalid --side-effect"            2 state-empty   ""          --side-effect=bogus

# ---- 3z A MISSING LIBRARY MUST NOT SWITCH OBSERVATION OFF -----------------
# cycle-gate.sh sources the library AFTER the two unconditionally-green
# verdicts have already returned, so on a checkout where scripts/lib/ is
# absent `observe` and `cycle-artifact-write` keep answering green while the
# two state-consulting verdicts fail closed with exit 3. Every consumer spells
# the call `if ! cycle-gate.sh …`, so exit 3 is absorbed as "skip".
#
# This is the most load-bearing ordering property in the file — hoisting the
# source block a few lines up would arm a total observation outage on a host
# with a partial deploy — and it is asserted at RUNTIME, by deleting the
# library from a sandbox, because the property is about reachability, not
# text. (Until this case existed, that hoist passed the whole suite.)
mk_repo gate-nolib cycle-gate.sh
mkdir -p "${S}/state-empty"
rm -f "${S}/scripts/lib/side-effects.sh"
NOLIB_REPO="$S"
nolib_rc() {   # <args...> → exit code with the library absent
	env FY_LIVE= FY_STATE_DIR="${NOLIB_REPO}/state-empty" FY_RPC_TIMEOUT=2 \
		NODE_ID="NodeID-sandboxgate11111111111111111111" \
		METALGO_RPC="http://sandbox.invalid:9650" \
		bash "${NOLIB_REPO}/scripts/cycle-gate.sh" "$@" >/dev/null 2>&1
	printf '%s' "$?"
}
for pair in "observe:0" "cycle-artifact-write:0" "broadcast:3" "cycle-aware-notify:3"; do
	eff="${pair%%:*}"; want="${pair##*:}"; got="$(nolib_rc --side-effect="$eff")"
	if [ "$got" = "$want" ]; then
		ok "3z library absent: ${eff} → ${want}"
	else
		bad "3z library absent: ${eff} → ${want}" "got ${got}"
	fi
done

# Mutation: hoist the source block above the early return and the green
# verdicts die with it.
mk_repo gate-nolib-mut cycle-gate.sh
NOLIB_REPO="$S"
mkdir -p "${S}/state-empty"
rm -f "${S}/scripts/lib/side-effects.sh"
if python3 - "${S}/scripts/cycle-gate.sh" <<'PYEOF'
import io, re, sys
p = sys.argv[1]
src = io.open(p, encoding="utf-8").read()
m = re.search(r'SCRIPT_DIR="\$\(cd "\$\(dirname "\$0"\)" && pwd\)"\n'
              r'FYD_LIB=.*?\n\. "\$\{FYD_LIB\}"\n', src, re.S)
if not m:
    sys.exit("mutation anchor not found")
marker = 'case "${SIDE_EFFECT}" in\n\tobserve|cycle-artifact-write)'
if marker not in src:
    sys.exit("hoist target not found")
src = src.replace(m.group(0), "").replace(marker, m.group(0) + marker, 1)
io.open(p, "w", encoding="utf-8").write(src)
PYEOF
then
	if [ "$(nolib_rc --side-effect=observe)" = "0" ]; then
		bad "3z mutation caught: source block hoisted above the early return" \
			"observe stayed green against a deliberately broken file"
	else
		ok "3z mutation caught: source block hoisted above the early return kills observe"
	fi
else
	bad "3z mutation applied: source block hoisted above the early return" "sed/python anchor did not match"
fi

# ---- 3y the C3 library's FILENAME must not appear in gen-cycle-history.sh --
# scripts/check-cron-file.sh Rule 6 and scripts/install-cron-env-headers.sh
# both classify a script as side-effecting by grepping its RAW TEXT — comments
# included — for that filename. gen-cycle-history.sh deliberately ignores
# FY_LIVE and runs from /etc/cron.d/metal-cycle-history, a cron file with no
# FY_LIVE=1 header and no repo installer. So merely NAMING the library in a
# comment there flips that cron from PASS to FAIL and makes the lint demand a
# header that would be wrong to add.
#
# Asserted end-to-end against the REAL linter (not a re-implementation of its
# regex), so it cannot drift from the classifier it is protecting.
mk_repo cronlint gen-cycle-history.sh
cat >"${S}/cron-metal-cycle-history" <<CRONEOF
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
17 5 * * * deploy { echo "=== metal-cycle-history start \$(date -u +\%FT\%TZ) ==="; cd /home/deploy/metal.freedom-yield.com && bash scripts/gen-cycle-history.sh; rc=\$?; echo "=== metal-cycle-history end \$(date -u +\%FT\%TZ) rc=\$rc ==="; } >> /home/deploy/metal.freedom-yield.com/logs/cycle-history.log 2>&1
CRONEOF
if env FYD_CRON_SCRIPTS_DIR="${S}/scripts" \
	bash "${SCRIPTS}/check-cron-file.sh" "${S}/cron-metal-cycle-history" \
	>"${TMP}/3y.out" 2>&1; then
	ok "3y real cron lint: metal-cycle-history still PASSes without an FY_LIVE=1 header"
else
	bad "3y real cron lint: metal-cycle-history still PASSes without an FY_LIVE=1 header" \
		"$(grep -i 'FAIL' "${TMP}/3y.out" | head -2)"
fi
# Mutation: put the filename back into a COMMENT and the same lint goes red.
printf '\n# regression: naming scripts/lib/side-effects.sh here is what F1 was\n' \
	>>"${S}/scripts/gen-cycle-history.sh"
if env FYD_CRON_SCRIPTS_DIR="${S}/scripts" \
	bash "${SCRIPTS}/check-cron-file.sh" "${S}/cron-metal-cycle-history" \
	>"${TMP}/3y-mut.out" 2>&1; then
	bad "3y mutation caught: the library filename in a COMMENT breaks the cron gate" \
		"lint stayed green against a deliberately broken file"
else
	grep -q "no 'FY_LIVE=1' line" "${TMP}/3y-mut.out" \
		&& ok "3y mutation caught: the library filename in a COMMENT breaks the cron gate" \
		|| bad "3y mutation caught: the library filename in a COMMENT breaks the cron gate" \
			"lint failed, but not on Rule 6: $(tail -3 "${TMP}/3y-mut.out")"
fi

echo
# ===========================================================================
echo "== Part 4/5: static gate — no ungated side effect in the nine files =="
# ===========================================================================

# gate_stream <file> — "N:text" lines with comment-only lines dropped and
# single-quoted literals blanked. Blanking the quoted runs is what keeps the
# operator-guidance prose inside `echo "  bash '<path>' '<arg>'"` from being
# mistaken for a call: text inside single quotes is never executed.
gate_stream() {
	grep -n '' "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s/'[^']*'//g"
}

DELEGATE_RE='(^[0-9]+:|[[:space:]{(;&|])(bash|sh|exec)[[:space:]]+"?[^"[:space:]]*(notify|push-to-web-host)\.sh'
DELEGATE_VAR_RE='(bash|sh|exec)[[:space:]]+"?\$\{?(NOTIFY|FYD_NOTIFY|ANCHOR_NOTIFY|WATCH_NOTIFY|FYD_PUSH_TO_WEB_HOST|PUSH_TO_WEB_HOST|PUSH_HINT_BIN)\}?"?'
DURABLE='STATE_FILE|STATE_TMP|MISMATCH_STATE'
DURABLE_DIR='STATE_DIR'
WRITE_RE="(>>?[[:space:]]*\"?\\\$\{?(${DURABLE}))|(\\b(mv|cp|rm|chmod|touch)\\b[^|;&]*\\\$\{?(${DURABLE})\\}?)|(\\b(mkdir|rm)\\b[^|;&]*\\\$\{?(${DURABLE_DIR})\\}?)"

# gate_check <file> — prints one line per violation; silence means clean.
#
# G3 is stated as an IMPLICATION, not a membership list: a file must source
# the library IFF it calls into it. That keeps gen-cycle-history.sh — which
# deliberately calls nothing (see its header) — honest without carving out a
# named exemption that would silently cover a future raw side effect there.
gate_check() {
	local f="$1" refusal=0 n ctx
	refusal="$(grep -nF 'FYD-GATE(refusal)' "$f" | head -1 | cut -d: -f1)"
	[ -n "$refusal" ] || refusal=0

	gate_stream "$f" | grep -E "$DELEGATE_RE" | sed 's/^/G1 direct-delegate-invocation /'
	gate_stream "$f" | grep -E "$DELEGATE_VAR_RE" | sed 's/^/G1 direct-delegate-invocation /'
	gate_stream "$f" | grep -F '/var/lib/freedom-yield' | sed 's/^/G2 production-path-literal /'
	if gate_stream "$f" | grep -qE '\bfyd_(notify|push|state_dir|live_run|live_write|is_live)\b'; then
		grep -qE '^[[:space:]]*\.[[:space:]]+"\$\{?FYD_LIB\}?"' "$f" \
			|| echo "G3 calls-the-library-without-sourcing-it"
	fi

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		n="${line%%:*}"
		case "$line" in *fyd_live_write*|*fyd_live_run*|*fyd_notify*|*fyd_push*) continue ;; esac
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
		ok "4 gate clean: scripts/${f}"
	else
		bad "4 gate clean: scripts/${f}" "$(printf '%s' "$V" | head -4 | tr '\n' ' ')"
	fi
done

if grep -qF 'FYD-GATE(refusal)' "${SCRIPTS}/resume-after-cycle-start.sh"; then
	ok "4 resume-after-cycle-start carries the file-level hard-refusal marker"
else
	bad "4 resume-after-cycle-start carries the file-level hard-refusal marker"
fi

# gen-cycle-history.sh's exemption from G3 must stay EARNED, not asserted:
# the moment it grows an fyd_* call the implication above makes the library
# mandatory, and G1/G2/G4 already forbid the raw alternatives.
if gate_stream "${SCRIPTS}/gen-cycle-history.sh" | grep -qE '\bfyd_[a-z_]+\b'; then
	bad "4 gen-cycle-history's no-library exemption is still earned" "it now calls fyd_* — source the library"
else
	ok "4 gen-cycle-history's no-library exemption is still earned (calls no fyd_*)"
fi

echo
# ===========================================================================
echo "== Part 5/5: mutation — the gate must go red when a rule is broken =="
# ===========================================================================

# mutate <label> <source file> <sed program>  → expect gate_check to complain
mutate() {
	local label="$1" src="$2" prog="$3" out="${TMP}/mut-$(basename "$2")"
	sed "$prog" "$src" >"$out"
	if [ "$(cat "$out")" = "$(cat "$src")" ]; then
		bad "5 mutation applied: ${label}" "sed program matched nothing — the mutation test would be a tautology"
		return
	fi
	if [ -n "$(gate_check "$out")" ]; then
		ok "5 mutation caught: ${label}"
	else
		bad "5 mutation caught: ${label}" "gate stayed green against a deliberately broken file"
	fi
}

mutate "G1 — a raw notify.sh call comes back" \
	"${SCRIPTS}/check-anchor-publish-health.sh" \
	's|^\tfyd_notify "\$1" "\$2" "\$3".*|\tbash "${SCRIPT_DIR}/notify.sh" "$1" "$2" "$3"|'

mutate "G1 — a raw \$FYD_NOTIFY call comes back" \
	"${SCRIPTS}/run-anchor-pipeline.sh" \
	's|^\tfyd_notify "\$1" "\$2" "\$3".*|\tbash "$FYD_NOTIFY" "$1" "$2" "$3"|'

mutate "G1 — the R18 push reverts to a direct delegate invocation" \
	"${SCRIPTS}/append-anchor-history.sh" \
	's|^\tif fyd_push "\$push_arg" >&2; then|\tif bash "$PUSH_HINT_BIN" "$push_arg" >\&2; then|'

mutate "G1 — the operator hint stops being a hint and becomes a call" \
	"${SCRIPTS}/append-anchor-history.sh" \
	's@^\t\techo "      \${hint}" >&2@\t\tbash "$PUSH_HINT_BIN" "$push_arg"@'

mutate "G2 — a production path literal comes back" \
	"${SCRIPTS}/cycle-gate.sh" \
	's|^STATE_DIR="\$(fyd_state_dir cycle)".*|STATE_DIR="${FY_STATE_DIR:-/var/lib/freedom-yield}"|'

mutate "G3 — the library is no longer sourced" \
	"${SCRIPTS}/watch-anchor-events.sh" \
	's|^\. "\$FYD_LIB"|true|'

mutate "G4 — the gated watcher state write reverts to a raw redirect" \
	"${SCRIPTS}/watch-anchor-events.sh" \
	's@^\t\t| fyd_live_write "the anchor-watcher state" "\${STATE_FILE}.new"@\t\t> "${STATE_FILE}.new"@'

mutate "G4 — the gated watcher state rename reverts to a raw mv" \
	"${SCRIPTS}/watch-anchor-events.sh" \
	's@^\tfyd_live_run "install the new anchor-watcher state.*@\tmv "${STATE_FILE}.new" "${STATE_FILE}"@'

# resume-after-cycle-start.sh carries FYD-GATE(refusal), so every write below
# that marker is covered BY THE REFUSAL, not by a per-line gate — G4 skips
# them on purpose (a hard refusal is a stronger guarantee than a per-write
# gate, and annotating each line would just restate it). The two mutations
# below are therefore stated as a pair: the marker alone is load-bearing, and
# once it is gone the raw write underneath IS caught. Neither half is a
# tautology — the first (below, in the G4/G5 case) proves the marker is
# checked; this one proves the marker is the ONLY thing exempting the writes.
mutate "G4 — with the refusal marker gone, resume's raw state write is caught" \
	"${SCRIPTS}/resume-after-cycle-start.sh" \
	's@# FYD-GATE(refusal).*@#@; s@^\tif ! fyd_live_run "install the new cycle-gate state.*@\tif ! mv "${STATE_TMP}" "${STATE_FILE}"; then@'

mutate "G4 — the gated mismatch-dedup write reverts to a raw call" \
	"${SCRIPTS}/check-anchor-publish-health.sh" \
	's@^\tfyd_live_run "record the exit-3 mismatch dedup window.*@\tmv "$tmp" "$MISMATCH_STATE"@'

mutate "G4/G5 — the hard-refusal marker is removed from resume-after-cycle-start" \
	"${SCRIPTS}/resume-after-cycle-start.sh" \
	's@# FYD-GATE(refusal).*@#@'

# ---------------------------------------------------------------------------
# Sandbox regression guard (task h5, 2026-08-07)
# ---------------------------------------------------------------------------
# mk_repo above mirrors the ENTIRE real scripts/lib/ directory precisely so a
# FUTURE addition there is picked up with zero suite edits — the bug this
# task fixed was mk_repo hand-copying just side-effects.sh while
# push-to-web-host.sh grew a hard dependency on its sibling scripts/lib/
# publish-scan.sh (which in turn requires scripts/publish-guard.sh). Prove
# the mechanism actually generalizes instead of merely asserting it.
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
echo "test-anchor-cycle-side-effects.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
printf '\nFailures:\n'
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
echo "RESULT: FAIL"
exit 1
