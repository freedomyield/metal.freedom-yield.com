#!/usr/bin/env bash
# tests/side-effects-callers/test-feed-side-effects.sh
#
# C3-2c acceptance suite: the five FEED-GENERATION / HOST-FOLLOW callers of
# scripts/lib/side-effects.sh must be dry by default and gated by
# construction.
#
#   scripts/peer-validators.sh        scripts/check-identity-pins.sh
#   scripts/uptime-history.sh         scripts/advance-host-checkout.sh
#   scripts/peer-analytics.py
#
# CHAIN: none — no case reaches a broadcast-capable command.
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
# scripts/push-to-web-host.sh, a readable NTFY_TOPIC_FILE with a topic in it, a
# WEB_HOST and a readable ssh key file — everything those two delegates need in
# order to actually reach the network — and no delegate override at all. The
# only thing standing between the script under test and ntfy.sh / the web host
# is FY_LIVE. What is intercepted instead is one level lower: `curl` and `ssh`
# are replaced on PATH by recording tripwires, so "did a real notification or a
# real push leave the machine?" is answered by evidence (tripwire content)
# rather than by assumption.
#
# Part 2 then runs the SAME cases with FY_LIVE=1 and requires the opposite
# outcome — tripwire hits and real artefacts on disk. Without Part 2, Part 1
# would be satisfied by a script that is simply broken.
#
# ---------------------------------------------------------------------------
# WHAT IS DELIBERATELY *NOT* GATED (and is asserted to stay that way)
# ---------------------------------------------------------------------------
#   * advance-host-checkout.sh's git mutations. That script IS the delivery
#     mechanism for every git-tracked file on the validator host (2026-07-13
#     ownership inversion). A dry run that skipped the pull would stop
#     delivery — the same "went quiet and nobody noticed" failure the C3
#     rollout exists to prevent, reached from the opposite direction. Its
#     anchor-source preservation copies stay ungated in LOCK STEP with the
#     `git checkout -- public/` they protect: gating the copy while leaving
#     the discard live would turn a dry run into silent data loss.
#   * check-identity-pins.sh --mode=repo's VERDICT. That is the CI gate; if
#     FY_LIVE could change its exit code, CI would go silently green on a
#     machine that never sets it. Part 5 is entirely about this.
#
# ---------------------------------------------------------------------------
# PATH stand-ins (all test-local; nothing on this machine is modified)
# ---------------------------------------------------------------------------
#   curl   records argv, passes file:// URLs through to the real curl,
#          answers ntfy.sh with HTTP 200, fails everything else like an
#          unreachable host.
#   ssh    records argv, fails.
#   sleep  returns immediately. push-to-web-host.sh retries 3× with 5s/15s
#          backoff on a failing ssh; the tripwire ssh always fails, so the
#          live push case would otherwise spend 20 real seconds proving
#          something the FIRST tripwire line already proves.
#
# Usage:
#   bash tests/side-effects-callers/test-feed-side-effects.sh
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

SH_TARGETS="peer-validators.sh uptime-history.sh check-identity-pins.sh advance-host-checkout.sh"
PY_TARGET="peer-analytics.py"

for f in $SH_TARGETS $PY_TARGET; do
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

for tool in jq python3 gzip git; do
	command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: $tool not on PATH" >&2; exit 1; }
done

TMP="$(mktemp -d -t fy-c32c-callers.XXXXXX)"
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

cat >"${BIN}/sleep" <<'SLEEPEOF'
#!/usr/bin/env bash
# Test-local stand-in: returns immediately. See this suite's header.
exit 0
SLEEPEOF
chmod +x "${BIN}/sleep"

export PATH="${BIN}:${PATH}"

ntfy_hits() { grep -c 'ntfy\.sh' "$TRIPWIRE" 2>/dev/null | tr -d '[:space:]'; }
ssh_hits()  { grep -c '^ssh '   "$TRIPWIRE" 2>/dev/null | tr -d '[:space:]'; }
reset_tripwire() { : >"$TRIPWIRE"; }

# Count regular files under a set of roots that exist.
artefact_count() {
	local n=0 r
	for r in "$@"; do
		[ -e "$r" ] || continue
		n=$((n + $(find "$r" -type f 2>/dev/null | wc -l | tr -d '[:space:]')))
	done
	printf '%s' "$n"
}

# mk_repo <name> <file>...
#   Builds a self-contained sandbox repo whose scripts/ holds the REAL
#   side-effects library, the REAL notify.sh and push-to-web-host.sh, and the
#   named scripts under test. Sets $S to its path.
mk_repo() {
	local name="$1"; shift
	S="${TMP}/${name}"
	mkdir -p "${S}/scripts/lib" "${S}/public/api" "${S}/logs"
	cp "$LIB" "${S}/scripts/lib/side-effects.sh"
	cp "${SCRIPTS}/notify.sh" "${S}/scripts/notify.sh"
	cp "${SCRIPTS}/push-to-web-host.sh" "${S}/scripts/push-to-web-host.sh"
	local f
	for f in "$@"; do cp "${SCRIPTS}/${f}" "${S}/scripts/${f}"; done
	printf 'sandbox-topic-not-a-real-topic\n' >"${S}/topic"
	# Everything push-to-web-host.sh needs to reach ssh for real. The value
	# is an RFC 2606 reserved test name, never a real host.
	printf 'sandbox-key-not-a-real-key\n' >"${S}/web_push_key"
	chmod 600 "${S}/web_push_key"
}

echo "== Part 1/6: dry by default (no FY_LIVE, no stubs) =="

# ---- 1a peer-validators.sh (+ peer-analytics.py) ---------------------------
setup_peers() {
	mk_repo "$1" peer-validators.sh peer-analytics.py
	mkdir -p "${S}/rpc/ext/bc" "${S}/state"
	cat >"${S}/rpc/ext/bc/P" <<'RPCEOF'
{"jsonrpc":"2.0","id":1,"result":{"validators":[
 {"nodeID":"NodeID-sandboxAAA","weight":"2000000000000","delegatorWeight":"500000000000",
  "delegatorCount":"3","delegationFee":"3.0000","uptime":"99.9900","startTime":"1700000000",
  "endTime":"9999999999","connected":true,"validationRewardOwner":{"addresses":["P-sandbox1"]}},
 {"nodeID":"NodeID-sandboxBBB","weight":"1000000000000","delegatorWeight":"0",
  "delegatorCount":"0","delegationFee":"5.0000","uptime":"98.5000","startTime":"1700000000",
  "endTime":"9999999999","connected":true,"validationRewardOwner":{"addresses":["P-sandbox2"]}}
]}}
RPCEOF
	printf '[]\n' >"${S}/explorer.json"
}
run_peers() {   # <env assignments...>
	env "$@" \
		REPO_BASE="${S}" \
		METALGO_API="file://${S}/rpc" \
		EXPLORER_API="file://${S}/explorer.json" \
		UPTIME_STATE_DIR="${S}/state" \
		NTFY_TOPIC_FILE="${S}/topic" \
		WEB_HOST="sandbox@host.invalid" \
		WEB_PUSH_KEY="${S}/web_push_key" \
		bash "${S}/scripts/peer-validators.sh"
}

setup_peers peers-dry
reset_tripwire
run_peers FY_LIVE= >"${TMP}/1a.out" 2>"${TMP}/1a.err"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "1a peer-validators: dry run exits 0" \
	|| bad "1a peer-validators: dry run exits 0" "rc=$RC $(tail -3 "${TMP}/1a.err")"
[ "$(artefact_count "${S}/state" "${S}/public/api")" = "0" ] \
	&& ok "1a peer-validators: not one artefact written (state dir + public/api both empty)" \
	|| bad "1a peer-validators: not one artefact written" "$(find "${S}/state" "${S}/public/api" -type f 2>/dev/null | head -4 | tr '\n' ' ')"
grep -q 'DRY: would install the refreshed validator-set snapshot' "${TMP}/1a.err" \
	&& ok "1a peer-validators: the peers.json install is announced as suppressed" \
	|| bad "1a peer-validators: the peers.json install is announced as suppressed" "$(grep DRY: "${TMP}/1a.err" | head -3)"
grep -q "DRY: would write today's gzipped peers snapshot" "${TMP}/1a.err" \
	&& ok "1a peer-validators: the daily archive write is announced as suppressed" \
	|| bad "1a peer-validators: the daily archive write is announced as suppressed"
grep -q 'DRY: would publish peers-history/peers-' "${TMP}/1a.err" \
	&& ok "1a peer-validators: the publish is announced as suppressed (generation and publish stay together)" \
	|| bad "1a peer-validators: the publish is announced as suppressed"
grep -q 'DRY: would write the public peers-history index' "${TMP}/1a.err" \
	&& ok "1a peer-validators: the index write is announced as suppressed" \
	|| bad "1a peer-validators: the index write is announced as suppressed"
[ "$(ssh_hits)" = "0" ] \
	&& ok "1a peer-validators: nothing reached ssh" \
	|| bad "1a peer-validators: nothing reached ssh" "$(grep '^ssh ' "$TRIPWIRE" | head -2)"

# The Python companion is invoked unconditionally (reading is not a side
# effect) and gates its own six writes — so a dry tick's log must carry ITS
# announcements too, not go quiet about half the pipeline.
for desc in \
	'the validator-set changes feed' \
	'the previous-NodeID snapshot' \
	'the Gini master ledger' \
	'the public Gini preview' \
	'the fee-market master ledger' \
	'the public fee-market preview'
do
	grep -qF "DRY: would " "${TMP}/1a.err" && grep -qF "$desc" "${TMP}/1a.err" \
		&& ok "1a peer-analytics: suppressed write announced — ${desc}" \
		|| bad "1a peer-analytics: suppressed write announced — ${desc}"
done

# ---- 1b uptime-history.sh --------------------------------------------------
setup_uptime() {
	mk_repo "$1" uptime-history.sh
	mkdir -p "${S}/state"
	printf '#!/usr/bin/env bash\nexit 0\n' >"${S}/scripts/cycle-gate.sh"
	chmod +x "${S}/scripts/cycle-gate.sh"
	cat >"${S}/public/api/validator.json" <<'VALEOF'
{"nodeId":"NodeID-sandboxAAA","startTime":1700000000,"endTime":9999999999,
 "uptime":{"network":99.5},"stake":{"self":5900,"totalReceived":0},
 "bootstrap":{"pChain":true,"xChain":true,"cChain":true},
 "delegationFee":{"percent":3.0},"networkSize":{"totalValidators":200},
 "observedAt":"2026-08-06T00:00:00Z"}
VALEOF
}
run_uptime() {
	env "$@" UPTIME_STATE_DIR="${S}/state" bash "${S}/scripts/uptime-history.sh"
}

setup_uptime uptime-dry
run_uptime FY_LIVE= >"${TMP}/1b.out" 2>"${TMP}/1b.err"
RC=$?
[ "$RC" -eq 0 ] \
	&& ok "1b uptime-history: dry run exits 0" \
	|| bad "1b uptime-history: dry run exits 0" "rc=$RC $(tail -3 "${TMP}/1b.err")"
[ "$(artefact_count "${S}/state")" = "0" ] \
	&& ok "1b uptime-history: the master ledger and cycle state were not created" \
	|| bad "1b uptime-history: state dir untouched" "$(find "${S}/state" -type f | head -3 | tr '\n' ' ')"
[ ! -e "${S}/public/api/uptime-recent.json" ] && [ ! -e "${S}/public/api/uptime-cycles.json" ] \
	&& ok "1b uptime-history: no public artefact written" \
	|| bad "1b uptime-history: no public artefact written"
grep -q "DRY: would append to today's uptime master entry" "${TMP}/1b.err" \
	&& ok "1b uptime-history: the master append is announced as suppressed" \
	|| bad "1b uptime-history: the master append is announced as suppressed" "$(grep DRY: "${TMP}/1b.err" | head -3)"
grep -q 'DRY: would write the current cycle state' "${TMP}/1b.err" \
	&& ok "1b uptime-history: the cycle-state write is announced as suppressed" \
	|| bad "1b uptime-history: the cycle-state write is announced as suppressed"
grep -q 'DRY: would install the refreshed public uptime preview' "${TMP}/1b.err" \
	&& ok "1b uptime-history: the public preview is announced as suppressed" \
	|| bad "1b uptime-history: the public preview is announced as suppressed"
grep -q 'Appended daily entry' "${TMP}/1b.out" \
	&& bad "1b uptime-history: dry run must not claim it appended anything" "$(grep 'Appended' "${TMP}/1b.out")" \
	|| ok "1b uptime-history: dry run does not claim it appended anything"

# ---- 1c check-identity-pins.sh (live mode, no FY_LIVE) ---------------------
setup_pins() {
	mk_repo "$1" check-identity-pins.sh
	mkdir -p "${S}/deploy" "${S}/served"
	printf 'api/moving-feed.json\n' >"${S}/deploy/feed-excludes.txt"
	printf 'tracked bytes\n' >"${S}/public/api/tracked.json"
	local sha
	sha="$(printf 'DIFFERENT bytes\n' | (command -v shasum >/dev/null 2>&1 \
		&& shasum -a 256 || sha256sum) | awk '{print $1}')"
	jq -n --arg sha "$sha" '{
		artifact_manifest: {
			tracked_json: { url: "https://sandbox.invalid/api/tracked.json", sha256: $sha }
		}
	}' >"${S}/public/api/identity.json"
	cp "${S}/public/api/identity.json" "${S}/served/identity.json"
	cat >"${S}/curl-stub.sh" <<'CURLSTUB'
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
if [ -f "${STUB_DIR}/${base}" ]; then cp "${STUB_DIR}/${base}" "$out"; printf '200'; exit 0; fi
printf '404'
CURLSTUB
	chmod +x "${S}/curl-stub.sh"
}
run_pins_live() {
	env "$@" \
		FYD_REPO_ROOT="${S}" \
		FYD_IDENTITY_URL="https://sandbox.invalid/api/identity.json" \
		FYD_CURL="${S}/curl-stub.sh" \
		STUB_DIR="${S}/served" \
		FYD_FETCH_ATTEMPTS=1 FYD_RETRY_SLEEP=0 \
		IDENTITY_PIN_LOG="${S}/logs/pins.log" \
		IDENTITY_PIN_ALERT_STATE="${S}/logs/pin-alert-state.json" \
		NTFY_TOPIC_FILE="${S}/topic" \
		bash "${S}/scripts/check-identity-pins.sh" --mode=live
}

setup_pins pins-dry
cp "${S}/public/api/tracked.json" "${S}/served/tracked.json"
reset_tripwire
run_pins_live FY_LIVE= >"${TMP}/1c.out" 2>"${TMP}/1c.err"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "1c check-identity-pins: live-mode verdict is unchanged while dry (exit 3 on a new tracked break)" \
	|| bad "1c check-identity-pins: live-mode verdict unchanged while dry" "rc=$RC $(tail -3 "${TMP}/1c.err")"
grep -q 'DRY: would notify prio=high .*identity-pins: signed manifest broken' "${TMP}/1c.err" \
	&& ok "1c check-identity-pins: the break alert is announced as suppressed" \
	|| bad "1c check-identity-pins: the break alert is announced as suppressed" "$(grep DRY: "${TMP}/1c.err" | head -3)"
grep -q 'DRY: would record the identity-pin alert-dedup signature' "${TMP}/1c.err" \
	&& ok "1c check-identity-pins: the dedup record is suppressed in lock step with the alert" \
	|| bad "1c check-identity-pins: the dedup record is suppressed in lock step with the alert"
[ ! -e "${S}/logs/pin-alert-state.json" ] \
	&& ok "1c check-identity-pins: no dedup state file written (a dry alert must not claim 'already told them')" \
	|| bad "1c check-identity-pins: no dedup state file written"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1c check-identity-pins: nothing reached ntfy.sh" \
	|| bad "1c check-identity-pins: nothing reached ntfy.sh" "$(grep 'ntfy\.sh' "$TRIPWIRE" | head -2)"

# ---- 1d advance-host-checkout.sh ------------------------------------------
export GIT_AUTHOR_NAME="FYD Hermetic Test Suite"
export GIT_AUTHOR_EMAIL="fyd-hermetic-test@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)

setup_advance() {
	mk_repo "$1" advance-host-checkout.sh
	local seed="${S}/seed"
	mkdir -p "${seed}/scripts" "${seed}/public/api" "${seed}/docs"
	echo 'echo hello' >"${seed}/scripts/a.sh"
	echo '<html>' >"${seed}/public/index.html"
	echo '# doc' >"${seed}/docs/README.md"
	git -C "$seed" "${GITQ[@]}" init -q -b main
	git -C "$seed" "${GITQ[@]}" add -A
	git -C "$seed" "${GITQ[@]}" commit -qm seed
	git clone -q --bare "$seed" "${S}/origin.git"
	git clone -q "${S}/origin.git" "${S}/clone" 2>/dev/null
	git -C "${S}/clone" "${GITQ[@]}" remote set-url origin "${S}/origin.git"
	# One origin-only commit so the clone is genuinely behind and the FF
	# pull below has real work to do.
	local scratch="${S}/scratch"
	git clone -q "${S}/origin.git" "$scratch" 2>/dev/null
	echo 'origin change' >>"${scratch}/docs/README.md"
	git -C "$scratch" "${GITQ[@]}" commit -qam origin-change
	git -C "$scratch" push -q origin main
	rm -rf "$scratch"
	# Local dirt that is byte-identical to origin/main -> self_heal_lossless_
	# dirt absorbs it and fires its batched default-priority alert.
	echo 'echo hello' >"${S}/clone/scripts/a.sh"
	printf 'untracked but identical\n' >"${S}/clone/docs/new.md"
	local scratch2="${S}/scratch2"
	git clone -q "${S}/origin.git" "$scratch2" 2>/dev/null
	printf 'untracked but identical\n' >"${scratch2}/docs/new.md"
	git -C "$scratch2" "${GITQ[@]}" add -A
	git -C "$scratch2" "${GITQ[@]}" commit -qm add-new-md
	git -C "$scratch2" push -q origin main
	rm -rf "$scratch2"
}
run_advance() {
	env "$@" FYD_REPO_DIR="${S}/clone" NTFY_TOPIC_FILE="${S}/topic" \
		bash "${S}/scripts/advance-host-checkout.sh"
}

setup_advance advance-dry
reset_tripwire
BEFORE_HEAD="$(git -C "${S}/clone" rev-parse HEAD)"
run_advance FY_LIVE= >"${TMP}/1d.out" 2>"${TMP}/1d.err"
RC=$?
AFTER_HEAD="$(git -C "${S}/clone" rev-parse HEAD)"
[ "$RC" -eq 0 ] \
	&& ok "1d advance-host-checkout: dry run exits 0" \
	|| bad "1d advance-host-checkout: dry run exits 0" "rc=$RC $(tail -3 "${TMP}/1d.err")"
[ "$BEFORE_HEAD" != "$AFTER_HEAD" ] \
	&& ok "1d advance-host-checkout: THE PULL STILL HAPPENS while dry (delivery is not a gated side effect)" \
	|| bad "1d advance-host-checkout: the pull still happens while dry" "HEAD unchanged at $BEFORE_HEAD"
grep -q 'DRY: would notify prio=default .*self-healed' "${TMP}/1d.err" \
	&& ok "1d advance-host-checkout: the self-heal alert is announced as suppressed" \
	|| bad "1d advance-host-checkout: the self-heal alert is announced as suppressed" "$(grep DRY: "${TMP}/1d.err" | head -3)"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "1d advance-host-checkout: nothing reached ntfy.sh" \
	|| bad "1d advance-host-checkout: nothing reached ntfy.sh" "$(grep 'ntfy\.sh' "$TRIPWIRE" | head -2)"

echo
echo "== Part 2/6: FY_LIVE=1 differential (proves Part 1 is not vacuous) =="

setup_peers peers-live
reset_tripwire
run_peers FY_LIVE=1 >"${TMP}/2a.out" 2>"${TMP}/2a.err"
RC=$?
[ "$RC" -eq 0 ] && [ -s "${S}/public/api/peers.json" ] \
	&& ok "2a peer-validators: FY_LIVE=1 installs public/api/peers.json" \
	|| bad "2a peer-validators: FY_LIVE=1 installs public/api/peers.json" "rc=$RC $(tail -3 "${TMP}/2a.err")"
[ -s "${S}/public/api/peers-gini.json" ] && [ -s "${S}/public/api/fee-market.json" ] \
	&& ok "2a peer-analytics: FY_LIVE=1 writes the public previews" \
	|| bad "2a peer-analytics: FY_LIVE=1 writes the public previews"
[ -s "${S}/state/gini-history.jsonl" ] && [ -s "${S}/state/fee-market-history.jsonl" ] \
	&& ok "2a peer-analytics: FY_LIVE=1 appends both master ledgers" \
	|| bad "2a peer-analytics: FY_LIVE=1 appends both master ledgers"
ls "${S}/state/peers-history/"peers-*.json.gz >/dev/null 2>&1 \
	&& ok "2a peer-validators: FY_LIVE=1 stashes the daily gzipped archive" \
	|| bad "2a peer-validators: FY_LIVE=1 stashes the daily gzipped archive"
[ "$(ssh_hits)" != "0" ] \
	&& ok "2a peer-validators: FY_LIVE=1 does reach ssh (the push actually leaves)" \
	|| bad "2a peer-validators: FY_LIVE=1 does reach ssh" "$(tail -3 "${TMP}/2a.err")"
grep -q 'DRY:' "${TMP}/2a.err" \
	&& bad "2a peer-validators: no DRY: line under FY_LIVE=1" "$(grep DRY: "${TMP}/2a.err" | head -2)" \
	|| ok "2a peer-validators: no DRY: line under FY_LIVE=1"
# The push failed (tripwire ssh always does), so the ledger must stay empty
# and the index must not advertise the date — the 2026-08-05 invariant, still
# holding with the gate in the path.
[ ! -s "${S}/state/peers-history/.published" ] \
	&& ok "2a peer-validators: a failed push still records nothing in the ledger" \
	|| bad "2a peer-validators: a failed push still records nothing in the ledger" "$(cat "${S}/state/peers-history/.published")"
[ "$(jq -r '.count' "${S}/public/api/peers-history-index.json")" = "0" ] \
	&& ok "2a peer-validators: index advertises nothing that was not published" \
	|| bad "2a peer-validators: index advertises nothing that was not published"

setup_uptime uptime-live
run_uptime FY_LIVE=1 >"${TMP}/2b.out" 2>"${TMP}/2b.err"
RC=$?
[ "$RC" -eq 0 ] && [ -s "${S}/state/uptime-history.jsonl" ] && [ -s "${S}/state/current-cycle-state.json" ] \
	&& ok "2b uptime-history: FY_LIVE=1 writes the master ledger and the cycle state" \
	|| bad "2b uptime-history: FY_LIVE=1 writes the master ledger and the cycle state" "rc=$RC $(tail -3 "${TMP}/2b.err")"
[ -s "${S}/public/api/uptime-recent.json" ] && [ -s "${S}/public/api/uptime-cycles.json" ] \
	&& ok "2b uptime-history: FY_LIVE=1 writes both public artefacts" \
	|| bad "2b uptime-history: FY_LIVE=1 writes both public artefacts"
grep -q 'DRY:' "${TMP}/2b.err" \
	&& bad "2b uptime-history: no DRY: line under FY_LIVE=1" "$(grep DRY: "${TMP}/2b.err" | head -2)" \
	|| ok "2b uptime-history: no DRY: line under FY_LIVE=1"
# Idempotency must survive the gate: a second live run appends nothing.
LINES_1="$(wc -l <"${S}/state/uptime-history.jsonl" | tr -d '[:space:]')"
run_uptime FY_LIVE=1 >/dev/null 2>&1
LINES_2="$(wc -l <"${S}/state/uptime-history.jsonl" | tr -d '[:space:]')"
[ "$LINES_1" = "$LINES_2" ] \
	&& ok "2b uptime-history: still idempotent under FY_LIVE=1 (no duplicate daily row)" \
	|| bad "2b uptime-history: still idempotent under FY_LIVE=1" "${LINES_1} → ${LINES_2}"

setup_pins pins-live
cp "${S}/public/api/tracked.json" "${S}/served/tracked.json"
reset_tripwire
run_pins_live FY_LIVE=1 >"${TMP}/2c.out" 2>"${TMP}/2c.err"
RC=$?
[ "$RC" -eq 3 ] \
	&& ok "2c check-identity-pins: FY_LIVE=1 exits 3 on the same break (verdict is mode-independent)" \
	|| bad "2c check-identity-pins: FY_LIVE=1 exits 3 on the same break" "rc=$RC"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2c check-identity-pins: FY_LIVE=1 does reach ntfy.sh" \
	|| bad "2c check-identity-pins: FY_LIVE=1 does reach ntfy.sh" "$(tail -3 "${TMP}/2c.err")"
[ -s "${S}/logs/pin-alert-state.json" ] \
	&& ok "2c check-identity-pins: FY_LIVE=1 does record the dedup state" \
	|| bad "2c check-identity-pins: FY_LIVE=1 does record the dedup state"

setup_advance advance-live
reset_tripwire
run_advance FY_LIVE=1 >"${TMP}/2d.out" 2>"${TMP}/2d.err"
[ "$(ntfy_hits)" != "0" ] \
	&& ok "2d advance-host-checkout: FY_LIVE=1 does reach ntfy.sh" \
	|| bad "2d advance-host-checkout: FY_LIVE=1 does reach ntfy.sh" "$(tail -3 "${TMP}/2d.err")"

echo
echo "== Part 3/6: static gate — no ungated side effect in the five files =="

# gate_stream <file> — "N:text" lines with comment-only lines dropped and
# single-quoted literals blanked. Blanking the quoted runs keeps operator
# guidance prose inside `printf '… bash scripts/…'` from being mistaken for a
# call: text inside single quotes is never executed.
gate_stream() {
	grep -n '' "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s/'[^']*'//g"
}

DELEGATE_RE='(^[0-9]+:|[[:space:]{(;&|])(bash|sh|exec)[[:space:]]+"?[^"[:space:]]*(notify|push-to-web-host)\.sh'
DELEGATE_VAR_RE='(bash|sh|exec)[[:space:]]+"?\$\{?(NOTIFY|FYD_NOTIFY|ANCHOR_NOTIFY|WATCH_NOTIFY|PUSH_TO_WEB_HOST|FYD_PUSH_TO_WEB_HOST)\}?"?'
DURABLE='OUT|SNAPSHOT|SNAPSHOT_INDEX|PUBLISHED_LEDGER|HIST_JSONL|CYCLE_STATE|OUT_CYCLES|OUT_RECENT|ALERT_STATE'
DURABLE_DIR='STATE_DIR|SNAPSHOT_DIR|PUBLISH_DIR'
WRITE_RE="(>>?[[:space:]]*\"?\\\$\{?(${DURABLE}))|(\\b(mv|cp|rm|chmod|touch)\\b[^|;&]*\\\$\{?(${DURABLE})\\}?)|(\\b(mkdir|rm)\\b[^|;&]*\\\$\{?(${DURABLE_DIR})\\}?)"

# gate_check <file> — prints one line per violation; silence means clean.
gate_check() {
	local f="$1" n ctx
	gate_stream "$f" | grep -E "$DELEGATE_RE" | sed 's/^/G1 direct-delegate-invocation /'
	gate_stream "$f" | grep -E "$DELEGATE_VAR_RE" | sed 's/^/G1 direct-delegate-invocation /'
	gate_stream "$f" | grep -F '/var/lib/freedom-yield' | sed 's/^/G2 production-path-literal /'
	grep -qE '^[[:space:]]*\.[[:space:]]+"\$FYD_LIB"' "$f" || echo "G3 does-not-source-the-side-effects-library"

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		n="${line%%:*}"
		case "$line" in *fyd_live_write*|*fyd_live_run*|*fyd_notify*|*fyd_push*) continue ;; esac
		if [ "$n" -gt 1 ]; then ctx="$(sed -n "$((n - 1))p;${n}p" "$f")"; else ctx="$(sed -n '1p' "$f")"; fi
		case "$ctx" in *'FYD-GATE('*) continue ;; esac
		echo "G4 ungated-durable-write $line"
	done <<EOF
$(gate_stream "$f" | grep -E "$WRITE_RE")
EOF
}

for f in $SH_TARGETS; do
	V="$(gate_check "${SCRIPTS}/${f}")"
	if [ -z "$V" ]; then
		ok "3 gate clean: scripts/${f}"
	else
		bad "3 gate clean: scripts/${f}" "$(printf '%s' "$V" | head -4 | tr '\n' ' ')"
	fi
done

# ---- the Python gate -------------------------------------------------------
# peer-analytics.py cannot source a bash library, so its rules are separate:
#   P1  the FY_LIVE JUDGMENT exists exactly once, as the literal
#       `os.environ.get("FY_LIVE") == "1"` — the same comparison fyd_is_live
#       makes. A second copy is how the two languages drift apart.
#   P2  every file write goes through fy_write(); the only lines allowed to
#       call write_text / open(..., "a") directly are the ones inside
#       fy_write, which carry an FYD-GATE marker.
#   P3  fy_is_live() and fy_write() are both defined.
py_gate_check() {
	local f="$1" n ctx judgments
	# -o, not -c: two copies on ONE line must still count as two.
	judgments="$(grep -oF 'os.environ.get("FY_LIVE") == "1"' "$f" | wc -l | tr -d '[:space:]')"
	[ "$judgments" = "1" ] || echo "P1 fy-live-judgment-count=${judgments} (want exactly 1)"
	grep -qE '^def fy_is_live\(\):' "$f" || echo "P3 missing-def-fy_is_live"
	grep -qE '^def fy_write\(' "$f"     || echo "P3 missing-def-fy_write"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		n="${line%%:*}"
		if [ "$n" -gt 1 ]; then ctx="$(sed -n "$((n - 1))p;${n}p" "$f")"; else ctx="$(sed -n '1p' "$f")"; fi
		case "$ctx" in *'FYD-GATE('*) continue ;; esac
		echo "P2 ungated-python-write $line"
	done <<EOF
$(grep -nE '\.write_text\(|\.open\("a"\)' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'fy_write(')
EOF
}

V="$(py_gate_check "${SCRIPTS}/${PY_TARGET}")"
if [ -z "$V" ]; then
	ok "3 gate clean: scripts/${PY_TARGET}"
else
	bad "3 gate clean: scripts/${PY_TARGET}" "$(printf '%s' "$V" | head -4 | tr '\n' ' ')"
fi

# ---- the deliberate NON-gate ------------------------------------------------
# advance-host-checkout.sh's git mutations and its anchor-source preservation
# copies must stay ungated, and stay ungated TOGETHER. Gating the preservation
# copy while leaving `git checkout -- public/` live would turn a dry run into
# silent data loss, so this is asserted, not merely documented.
ADV="${SCRIPTS}/advance-host-checkout.sh"
if grep -nE 'fyd_live_(run|write)[^\n]*git .*(pull|checkout)' "$ADV" >/dev/null 2>&1; then
	bad "3 advance-host-checkout: the git advance must NOT be gated" "$(grep -nE 'fyd_live_(run|write)[^\n]*git ' "$ADV" | head -2)"
else
	ok "3 advance-host-checkout: the git advance is deliberately NOT gated (delivery must not depend on FY_LIVE)"
fi
if grep -nE 'fyd_live_(run|write)[^\n]*(ANCHOR_PRESERVE_DIR|durable_file)' "$ADV" >/dev/null 2>&1; then
	bad "3 advance-host-checkout: the durable preservation copy must NOT be gated" \
		"$(grep -nE 'fyd_live_(run|write)[^\n]*(ANCHOR_PRESERVE_DIR|durable_file)' "$ADV" | head -2)"
else
	ok "3 advance-host-checkout: the durable preservation copy stays ungated, in lock step with the discard"
fi

echo
echo "== Part 4/6: mutation — the gate must go red when a rule is broken =="

# mutate <label> <checker> <source file> <sed program>
mutate() {
	local label="$1" checker="$2" src="$3" prog="$4" out="${TMP}/mut-$(basename "$3")"
	sed "$prog" "$src" >"$out"
	if [ "$(cat "$out")" = "$(cat "$src")" ]; then
		bad "4 mutation applied: ${label}" "sed program matched nothing — the mutation test would be a tautology"
		return
	fi
	if [ -n "$("$checker" "$out")" ]; then
		ok "4 mutation caught: ${label}"
	else
		bad "4 mutation caught: ${label}" "gate stayed green against a deliberately broken file"
	fi
}

mutate "G1 — a raw push-to-web-host.sh call comes back" gate_check \
	"${SCRIPTS}/peer-validators.sh" \
	's@^\t\t&& fyd_push .*@\t\t\&\& bash "${ROOT}/scripts/push-to-web-host.sh" "peers-history/peers-${date}.json.gz"; then@'

mutate "G1 — a raw \$FYD_NOTIFY call comes back" gate_check \
	"${SCRIPTS}/check-identity-pins.sh" \
	's|^\tfyd_notify "\$1" "\$2" "\$3".*|\tbash "$FYD_NOTIFY" "$1" "$2" "$3"|'

mutate "G2 — a production path literal comes back" gate_check \
	"${SCRIPTS}/uptime-history.sh" \
	's|^STATE_DIR="\$(fyd_state_dir uptime)".*|STATE_DIR="${UPTIME_STATE_DIR:-/var/lib/freedom-yield}"|'

mutate "G3 — the library is no longer sourced" gate_check \
	"${SCRIPTS}/peer-validators.sh" \
	's|^\. "\$FYD_LIB"|true|'

mutate "G4 — a gated master-ledger append reverts to a raw redirect" gate_check \
	"${SCRIPTS}/uptime-history.sh" \
	's@^  printf .*fyd_live_write --append.*@  echo "$ENTRY" >> "$HIST_JSONL"@'

mutate "G4 — a gated snapshot install reverts to a raw mv" gate_check \
	"${SCRIPTS}/peer-validators.sh" \
	's@^fyd_live_run "install the refreshed validator-set snapshot.*@mv "$TMP" "$OUT"@'

mutate "G4 — the dedup state write loses its gate marker" gate_check \
	"${SCRIPTS}/check-identity-pins.sh" \
	's@^\t# FYD-GATE(branch): unreachable unless fyd_is_live.*@\t# (marker removed)@'

mutate "P2 — a gated Python write loses its gate marker" py_gate_check \
	"${SCRIPTS}/peer-analytics.py" \
	's@^        # FYD-GATE(branch): reached only after fy_is_live.*@        # (marker removed)@'

mutate "P1 — a second FY_LIVE judgment appears" py_gate_check \
	"${SCRIPTS}/peer-analytics.py" \
	's@^    return os.environ.get("FY_LIVE") == "1"@    return os.environ.get("FY_LIVE") == "1" and os.environ.get("FY_LIVE") == "1"@'

mutate "P2 — a raw write_text comes back" py_gate_check \
	"${SCRIPTS}/peer-analytics.py" \
	's@^fy_write("the public Gini preview", OUT_GINI,@Path(OUT_GINI).write_text(@'

mutate "P3 — fy_is_live is renamed away" py_gate_check \
	"${SCRIPTS}/peer-analytics.py" \
	's@^def fy_is_live():@def fy_live_check():@'

echo
echo "== Part 5/6: --mode=repo returns its verdict WITHOUT FY_LIVE (the CI gate) =="

# The CI gate (validate.yml + ci-main.yml) runs `check-identity-pins.sh
# --mode=repo` on a runner that has never heard of FY_LIVE. If the inversion
# could make that return 0 on a broken pin, CI would go silently green — the
# exact failure this whole rollout exists to prevent, introduced by the fix.
setup_pins pins-repo
reset_tripwire
# (a) a genuinely broken tracked pin must still be exit 3 with FY_LIVE unset.
RC=0
env -u FY_LIVE FYD_REPO_ROOT="${S}" IDENTITY_PIN_LOG="${S}/logs/pins.log" \
	bash "${S}/scripts/check-identity-pins.sh" --mode=repo >"${TMP}/5a.out" 2>&1 || RC=$?
[ "$RC" -eq 3 ] \
	&& ok "5 repo mode: a broken tracked pin is exit 3 with FY_LIVE unset" \
	|| bad "5 repo mode: a broken tracked pin is exit 3 with FY_LIVE unset" "rc=$RC $(tail -2 "${TMP}/5a.out")"
grep -q 'summary (mode=repo)' "${TMP}/5a.out" \
	&& ok "5 repo mode: still prints its summary line with FY_LIVE unset" \
	|| bad "5 repo mode: still prints its summary line with FY_LIVE unset"
grep -q 'DRY:' "${TMP}/5a.out" \
	&& bad "5 repo mode: must not emit DRY lines — it has no side effect to suppress" "$(grep DRY: "${TMP}/5a.out" | head -2)" \
	|| ok "5 repo mode: emits no DRY line (nothing to suppress)"
[ "$(ntfy_hits)" = "0" ] \
	&& ok "5 repo mode: never pushes, in either FY_LIVE state" \
	|| bad "5 repo mode: never pushes"

# (b) the verdict is IDENTICAL across all three FY_LIVE states, on both a
#     broken and a green manifest. This is the assertion CI depends on.
repo_rc() {   # <fy-live-spec> -> exit code
	local rc=0
	case "$1" in
		unset) env -u FY_LIVE FYD_REPO_ROOT="${S}" IDENTITY_PIN_LOG="${S}/logs/pins.log" \
			bash "${S}/scripts/check-identity-pins.sh" --mode=repo >/dev/null 2>&1 || rc=$? ;;
		*)     env FY_LIVE="$1" FYD_REPO_ROOT="${S}" IDENTITY_PIN_LOG="${S}/logs/pins.log" \
			bash "${S}/scripts/check-identity-pins.sh" --mode=repo >/dev/null 2>&1 || rc=$? ;;
	esac
	printf '%s' "$rc"
}
BROKEN_UNSET="$(repo_rc unset)"; BROKEN_ZERO="$(repo_rc 0)"; BROKEN_ONE="$(repo_rc 1)"
[ "$BROKEN_UNSET" = "3" ] && [ "$BROKEN_ZERO" = "3" ] && [ "$BROKEN_ONE" = "3" ] \
	&& ok "5 repo mode: broken-pin verdict identical for FY_LIVE unset / 0 / 1 (all 3)" \
	|| bad "5 repo mode: broken-pin verdict identical across FY_LIVE" "unset=$BROKEN_UNSET 0=$BROKEN_ZERO 1=$BROKEN_ONE"

# Re-pin to the real bytes -> green, and green must also be FY_LIVE-independent.
GOOD_SHA="$( (command -v shasum >/dev/null 2>&1 && shasum -a 256 "${S}/public/api/tracked.json" \
	|| sha256sum "${S}/public/api/tracked.json") | awk '{print $1}')"
jq -n --arg sha "$GOOD_SHA" '{artifact_manifest: {tracked_json: {url: "https://sandbox.invalid/api/tracked.json", sha256: $sha}}}' \
	>"${S}/public/api/identity.json"
GREEN_UNSET="$(repo_rc unset)"; GREEN_ZERO="$(repo_rc 0)"; GREEN_ONE="$(repo_rc 1)"
[ "$GREEN_UNSET" = "0" ] && [ "$GREEN_ZERO" = "0" ] && [ "$GREEN_ONE" = "0" ] \
	&& ok "5 repo mode: green verdict identical for FY_LIVE unset / 0 / 1 (all 3)" \
	|| bad "5 repo mode: green verdict identical across FY_LIVE" "unset=$GREEN_UNSET 0=$GREEN_ZERO 1=$GREEN_ONE"

# (c) the gate CI actually runs, against the committed repo, with FY_LIVE unset.
RC=0
( cd "$REPO_ROOT" && env -u FY_LIVE bash scripts/check-identity-pins.sh --mode=repo ) >"${TMP}/5c.out" 2>&1 || RC=$?
[ "$RC" -eq 0 ] \
	&& ok "5 repo mode: the real CI gate is green on the committed baseline with FY_LIVE unset" \
	|| bad "5 repo mode: the real CI gate is green with FY_LIVE unset" "rc=$RC $(tail -3 "${TMP}/5c.out")"

echo
echo "== Part 6/6: the bash and Python FY_LIVE judgments are the same judgment =="

# peer-analytics.py re-implements fyd_is_live()'s rule because a Python
# process cannot source a bash library. A re-implemented rule is a second
# source of truth unless something forces the two to agree — this is that
# something. Both sides are driven with the SAME input set (the one
# tests/side-effects/test-side-effects.sh uses for fyd_is_live, plus a few
# extra shapes) and must return the same verdict for every value.
bash_verdict() {   # <spec>
	case "$1" in
		unset) env -u FY_LIVE bash -c ". \"$LIB\"; if fyd_is_live; then echo live; else echo dry; fi" ;;
		*)     env FY_LIVE="$1" bash -c ". \"$LIB\"; if fyd_is_live; then echo live; else echo dry; fi" ;;
	esac
}
py_verdict() {     # <spec>
	case "$1" in
		unset) env -u FY_LIVE python3 "${SCRIPTS}/${PY_TARGET}" --fy-live-verdict ;;
		*)     env FY_LIVE="$1" python3 "${SCRIPTS}/${PY_TARGET}" --fy-live-verdict ;;
	esac
}

MISMATCH=""
CHECKED=0
LIVE_SEEN=0
DRY_SEEN=0
# 19 inputs: unset, empty, and 17 near-misses that a truthiness- or
# trim-based implementation would get wrong.
for spec in unset '' '0' '1' 'yes' 'no' 'true' 'false' 'TRUE' 'True' 'on' 'off' \
            '11' '01' ' 1' '1 ' $'1\n' '1.0' 'y'; do
	B="$(bash_verdict "$spec")"
	P="$(py_verdict "$spec")"
	CHECKED=$((CHECKED + 1))
	[ "$B" = "live" ] && LIVE_SEEN=$((LIVE_SEEN + 1))
	[ "$B" = "dry" ]  && DRY_SEEN=$((DRY_SEEN + 1))
	if [ "$B" != "$P" ]; then
		MISMATCH="${MISMATCH}[${spec}] bash=${B} python=${P}; "
	fi
done
[ -z "$MISMATCH" ] \
	&& ok "6 bash and Python agree on all ${CHECKED} FY_LIVE inputs" \
	|| bad "6 bash and Python agree on all ${CHECKED} FY_LIVE inputs" "$MISMATCH"
# Non-vacuity: the input set must actually contain both answers, or "they
# agree" would be satisfied by two implementations that always say dry.
[ "$LIVE_SEEN" -ge 1 ] && [ "$DRY_SEEN" -ge 17 ] \
	&& ok "6 the input set exercises both verdicts (live=${LIVE_SEEN} dry=${DRY_SEEN})" \
	|| bad "6 the input set exercises both verdicts" "live=${LIVE_SEEN} dry=${DRY_SEEN}"

# Mutation: a truthiness-based Python judgment must be caught by the
# comparison above. Proven against a mutated COPY — the real script is never
# modified.
MUT_PY="${TMP}/mutated-peer-analytics.py"
sed 's@^    return os.environ.get("FY_LIVE") == "1"@    return bool(os.environ.get("FY_LIVE"))@' \
	"${SCRIPTS}/${PY_TARGET}" >"$MUT_PY"
if cmp -s "$MUT_PY" "${SCRIPTS}/${PY_TARGET}"; then
	bad "6 mutation applied: truthiness judgment" "sed matched nothing — the mutation test would be a tautology"
else
	MUT_MISMATCH=""
	for spec in '0' 'yes' 'true' ' 1'; do
		B="$(bash_verdict "$spec")"
		P="$(env FY_LIVE="$spec" python3 "$MUT_PY" --fy-live-verdict)"
		[ "$B" != "$P" ] && MUT_MISMATCH="yes"
	done
	[ -n "$MUT_MISMATCH" ] \
		&& ok "6 mutation caught: a truthiness-based Python judgment disagrees with fyd_is_live" \
		|| bad "6 mutation caught: a truthiness-based Python judgment" "the differential stayed green against a deliberately wrong implementation"
fi

echo
echo "test-feed-side-effects.sh summary: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
printf '\nFailures:\n'
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
echo "RESULT: FAIL"
exit 1
