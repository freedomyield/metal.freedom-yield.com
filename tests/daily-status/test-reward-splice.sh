#!/usr/bin/env bash
# tests/daily-status/test-reward-splice.sh — verifies daily-status.sh's
# [Reward] block (the reward-tracker.sh digest-line splice, added
# 2026-09-04) is included ONLY on the morning slot, and that a missing
# digest-line file is never an error.
#
# CHAIN: none — daily-status.sh's own RPC (fetch_balance) targets a
# METALGO_RPC pointed at an unreachable loopback port in every case below,
# so it degrades to "—" gracefully; no live node, no broadcast anywhere in
# this suite. cycle-gate.sh is stubbed to exit 0 (gate passes) so every
# case reaches the point where the push body is actually built — otherwise
# every case would short-circuit at the gate before ever touching the
# reward splice logic under test.
#
# Sandbox pattern mirrors tests/side-effects-callers/test-monitoring-side-
# effects.sh's mk_repo / status_fixture / validator_fixture helpers (the
# closest existing "daily-status 系" test precedent — no dedicated
# tests/daily-status/ suite existed before this file), rebuilt here
# self-contained rather than sourced, since each test-*.sh file in this repo
# is independently runnable.
#
# Cases:
#   1. SLOT=morning, reward-digest-line.txt present -> [Reward] block IS in
#      the push body, containing the digest line's own content
#   2. SLOT=evening, same file present -> [Reward] block is ABSENT (morning-
#      only gate)
#   3. SLOT=morning, reward-digest-line.txt ABSENT -> no [Reward] block, and
#      the run still exits 0 (never an error) — matching the task brief's
#      literal "ファイル無し → 行なし（エラーにしない）"

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="${REPO}/scripts"

PASS=0
FAIL=0
FAILURES=()
assert_true() {
	local label="$1" cond="$2"
	if [ "$cond" = "1" ]; then
		PASS=$((PASS + 1)); printf '  PASS  %s\n' "$label"
	else
		FAIL=$((FAIL + 1)); FAILURES+=("$label"); printf '  FAIL  %s\n' "$label"
	fi
}
assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1)); printf '  PASS  %-55s expected=%s actual=%s\n' "$label" "$expected" "$actual"
	else
		FAIL=$((FAIL + 1)); FAILURES+=("$label (expected=$expected, actual=$actual)")
		printf '  FAIL  %-55s expected=%s actual=%s\n' "$label" "$expected" "$actual"
	fi
}

TMP="$(mktemp -d -t fy-daily-status-reward-splice.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---- self-contained sandbox (mirrors mk_repo) ------------------------------
S="${TMP}/sandbox"
mkdir -p "${S}/scripts/lib" "${S}/public/api"
cp -R "${SCRIPTS}/lib/." "${S}/scripts/lib/"
cp "${SCRIPTS}/notify.sh" "${S}/scripts/notify.sh"
cp "${SCRIPTS}/daily-status.sh" "${S}/scripts/daily-status.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${S}/scripts/cycle-gate.sh"
chmod +x "${S}/scripts/cycle-gate.sh"

cat > "${S}/public/api/server-status.json" <<JSON
{
  "observedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "metalgo": { "containerStatus": "running", "peerCount": 120 },
  "caddy":   { "containerStatus": "running" },
  "host": {
    "cpu":    { "usedPercent": 15 },
    "memory": { "usedPercent": 30 },
    "disk":   { "usedPercent": 40 }
  }
}
JSON
cat > "${S}/public/api/validator.json" <<'JSON'
{ "nodeId": "NodeID-sandbox", "uptime": { "network": "99.0000" }, "stake": { "self": 12600, "totalReceived": 0 }, "endTime": 4102444800, "bootstrap": { "pChain": true, "xChain": true, "cChain": true } }
JSON
printf 'sandbox-topic-not-a-real-topic\n' > "${S}/topic"

BIN="${TMP}/bin"
mkdir -p "$BIN"
NTFY_BODY_LOG="${TMP}/ntfy-body.log"
: > "$NTFY_BODY_LOG"
cat > "${BIN}/curl" <<CURLEOF
#!/usr/bin/env bash
DATA=""
prev=""
URL=""
for a in "\$@"; do
	case "\$prev" in
		-d|--data) DATA="\$a" ;;
	esac
	case "\$a" in
		https://ntfy.sh/*) URL="\$a" ;;
	esac
	prev="\$a"
done
if [ -n "\$URL" ]; then
	{ echo "---"; printf '%s\n' "\$DATA"; } >> "${NTFY_BODY_LOG}"
	printf 'ntfy POST: %s\n' 200
	exit 0
fi
exit 7
CURLEOF
chmod +x "${BIN}/curl"
export PATH="${BIN}:${PATH}"

DIGEST_CONTENT="累積 1,234 METAL · Cycle 9 見込み +5.5 (10/33 days) · 25,000 まで残り 23,766.00"

run_daily_status() {
	# $1 = slot, $2 = state dir (reward-digest-line.txt lives here, or is
	# simply absent if the caller never wrote one there)
	local slot="$1" state_dir="$2"
	: > "$NTFY_BODY_LOG"
	env FY_LIVE=1 NTFY_TOPIC_FILE="${S}/topic" METALGO_RPC="http://127.0.0.1:1" \
		FY_STATE_DIR="$state_dir" \
		bash "${S}/scripts/daily-status.sh" "$slot"
}

echo "=== case 1: SLOT=morning, reward-digest-line.txt present -> [Reward] included ==="
STATE1="${TMP}/state1"
mkdir -p "$STATE1"
printf '%s\n' "$DIGEST_CONTENT" > "${STATE1}/reward-digest-line.txt"
run_daily_status morning "$STATE1" > "${TMP}/case1.out" 2>"${TMP}/case1.err"
RC1=$?
assert_eq "case 1: daily-status.sh exits 0" "0" "$RC1"
PUSH1="$(cat "$NTFY_BODY_LOG")"
assert_true "case 1: push body contains [Reward] section header" "$(printf '%s' "$PUSH1" | grep -qF '[Reward]' && echo 1 || echo 0)"
assert_true "case 1: push body contains the digest line's own content" "$(printf '%s' "$PUSH1" | grep -qF "$DIGEST_CONTENT" && echo 1 || echo 0)"

echo ""
echo "=== case 2: SLOT=evening, same file present -> [Reward] absent (morning-only) ==="
run_daily_status evening "$STATE1" > "${TMP}/case2.out" 2>"${TMP}/case2.err"
RC2=$?
assert_eq "case 2: daily-status.sh exits 0" "0" "$RC2"
PUSH2="$(cat "$NTFY_BODY_LOG")"
assert_true "case 2: push body has NO [Reward] section on a non-morning slot" "$(printf '%s' "$PUSH2" | grep -qF '[Reward]' && echo 0 || echo 1)"
assert_true "case 2: push body does not leak the digest content either" "$(printf '%s' "$PUSH2" | grep -qF "$DIGEST_CONTENT" && echo 0 || echo 1)"

echo ""
echo "=== case 3: SLOT=morning, reward-digest-line.txt ABSENT -> no [Reward], no error ==="
STATE3="${TMP}/state3"
mkdir -p "$STATE3"
# Deliberately no reward-digest-line.txt written here.
run_daily_status morning "$STATE3" > "${TMP}/case3.out" 2>"${TMP}/case3.err"
RC3=$?
assert_eq "case 3: daily-status.sh still exits 0 (file absence is never an error)" "0" "$RC3"
PUSH3="$(cat "$NTFY_BODY_LOG")"
assert_true "case 3: a push still went out (morning digest itself is unaffected)" "$([ -n "$PUSH3" ] && echo 1 || echo 0)"
assert_true "case 3: push body has NO [Reward] section" "$(printf '%s' "$PUSH3" | grep -qF '[Reward]' && echo 0 || echo 1)"

echo ""
echo "=== mutation kill check: the morning-only gate must have teeth ==="
echo "(a MUTANT copy with the SLOT=morning check removed must show [Reward]"
echo " on the evening push too — proving case 2 actually exercises the gate.)"
MUTANT="${S}/scripts/daily-status-mutant.sh"
python3 - "${SCRIPTS}/daily-status.sh" "$MUTANT" <<'PYEOF2'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = 'REWARD_BLOCK=""\nif [ "$SLOT" = "morning" ]; then'
new = 'REWARD_BLOCK=""\nif [ "1" = "1" ]; then'
assert old in text, "reward-splice guard not found at expected shape"
text = text.replace(old, new, 1)
open(dst, "w").write(text)
PYEOF2
chmod +x "$MUTANT"
if diff -q "${SCRIPTS}/daily-status.sh" "$MUTANT" >/dev/null 2>&1; then
	FAIL=$((FAIL + 1))
	FAILURES+=("mutation kill check: mutant sed produced no diff — guard not matched")
	echo "  FAIL  mutant produced no diff — guard not matched"
else
	: > "$NTFY_BODY_LOG"
	env FY_LIVE=1 NTFY_TOPIC_FILE="${S}/topic" METALGO_RPC="http://127.0.0.1:1" \
		FY_STATE_DIR="$STATE1" \
		bash "$MUTANT" evening >/dev/null 2>&1
	MUTANT_PUSH="$(cat "$NTFY_BODY_LOG")"
	if printf '%s' "$MUTANT_PUSH" | grep -qF '[Reward]'; then
		PASS=$((PASS + 1))
		printf '  PASS  mutant (morning-only guard removed) leaks [Reward] onto the evening push — the gate is load-bearing\n'
	else
		FAIL=$((FAIL + 1))
		FAILURES+=("mutation kill check: mutant still did not show [Reward] on evening")
		echo "  FAIL  mutant unexpectedly still hid [Reward] on evening"
	fi
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '\nFailures:\n'
	for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
	exit 1
fi
exit 0
