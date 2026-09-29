#!/usr/bin/env bash
# test-uptime-freshness.sh — proves the observedAt freshness gate in
# .github/workflows/uptime.yml is a hard backstop.
#
# Why: on 2026-09-24 the validator host was unreachable for ~100 h and this
# workflow stayed green, because stale data only produced ::warning:: after 24 h
# and a missing/unparseable observedAt passed silently. The gate now fails on
# age > 3600 s, except inside the renewal window (endTime-1800 .. endTime+21600).
#
# The block between the `BEGIN/END freshness-check` markers is EXTRACTED from
# the workflow (never copied here), exactly one block required.
# Mutation proof: see the task report (old 24h-warning logic makes cases 2-5,
# 8 fail).
#
# CHAIN: none — no network. Synthetic JSON + a fixed NOW_EPOCH only.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Usage: bash tests/uptime-workflow/test-uptime-freshness.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/uptime.yml"

# The workflow runs on Linux (GNU date). Locally use GNU date or skip.
DATE_DIR=""
if date -d @0 +%s >/dev/null 2>&1; then :
elif command -v gdate >/dev/null 2>&1; then
	DATE_DIR="$(mktemp -d -t uptime-fresh-date.XXXXXX)"
	ln -s "$(command -v gdate)" "${DATE_DIR}/date"
else
	echo "SKIP  no GNU date (date -d) or gdate available"
	exit 0
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

WORK="$(mktemp -d -t uptime-freshness-test.XXXXXX)"
# shellcheck disable=SC2329 # invoked via trap
teardown() { rm -rf "$WORK" ${DATE_DIR:+"$DATE_DIR"}; }
trap teardown EXIT

BLOCK_FILE="${WORK}/block.sh"
awk_ok=1
awk '
	/^[[:space:]]*# BEGIN freshness-check/ { inblk=1; n++; next }
	/^[[:space:]]*# END freshness-check/   { inblk=0; next }
	inblk { sub(/^[[:space:]]+/, ""); print }
	END { if (n != 1) exit 3 }
' "$WORKFLOW" > "$BLOCK_FILE" || awk_ok=0
if [ "$awk_ok" -ne 1 ] || [ ! -s "$BLOCK_FILE" ]; then
	bad "extract: exactly one freshness-check block found in uptime.yml"
	echo "RESULT: FAIL"; exit 1
fi
ok "extract: exactly one freshness-check block found in uptime.yml"

# run_case <json> <now-epoch> -> sets OUT, RC
run_case() {
	OUT="$(PATH="${DATE_DIR:+${DATE_DIR}:}$PATH" NOW_EPOCH="$2" JSON="$1" \
		bash -c "set -euo pipefail
json=\"\$JSON\"
$(cat "$BLOCK_FILE")
echo CHECK_OK" 2>&1)"
	RC=$?
}
expect_pass() { # name json now [needle]
	run_case "$2" "$3"
	if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx CHECK_OK \
		&& { [ -z "${4:-}" ] || printf '%s\n' "$OUT" | grep -q "$4"; }; then ok "$1"
	else bad "$1 — rc=$RC out: $OUT"; fi
}
expect_fail() {
	run_case "$2" "$3"
	if [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -q '^::error::' \
		&& ! printf '%s\n' "$OUT" | grep -qx CHECK_OK; then ok "$1"
	else bad "$1 — rc=$RC out: $OUT"; fi
}

NOW=1800000000                       # fixed "now"
iso() { PATH="${DATE_DIR:+${DATE_DIR}:}$PATH" date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
mk() { # observedAt-epoch [endTime]
	if [ -n "${2:-}" ]; then printf '{"phase":"x","network":"n","observedAt":"%s","endTime":%s}' "$(iso "$1")" "$2"
	else printf '{"phase":"x","network":"n","observedAt":"%s"}' "$(iso "$1")"; fi
}
FAR_END=$((NOW + 86400 * 20))        # renewal far away

expect_pass "fresh (60 s old) passes"                       "$(mk $((NOW-60)) $FAR_END)" $NOW "fresh"
expect_pass "exactly 3600 s old still passes"               "$(mk $((NOW-3600)) $FAR_END)" $NOW
expect_fail "3601 s old fails with ::error::"               "$(mk $((NOW-3601)) $FAR_END)" $NOW
expect_fail "100 h old fails (the 2026-09-24 shape)"        "$(mk $((NOW-360000)) $FAR_END)" $NOW
expect_fail "missing observedAt fails"                      '{"phase":"x","network":"n"}' $NOW
expect_fail "null observedAt fails"                         '{"phase":"x","network":"n","observedAt":null}' $NOW
expect_fail "unparseable observedAt fails"                  '{"phase":"x","network":"n","observedAt":"not-a-date"}' $NOW
expect_fail "stale and endTime missing fails"               "$(mk $((NOW-7200)))" $NOW

OLD=$(mk $((NOW-7200)) $((NOW+1800)))   # window opens at endTime-1800 == NOW
expect_pass "stale at window lower bound (endTime-1800) passes with ::notice::" "$OLD" $NOW "^::notice::"
expect_fail "stale 1 s before window opens fails"           "$(mk $((NOW-7200)) $((NOW+1801)))" $NOW
expect_pass "stale at window upper bound (endTime+21600) passes with ::notice::" "$(mk $((NOW-40000)) $((NOW-21600)))" $NOW "^::notice::"
expect_fail "stale 1 s after window closes fails"           "$(mk $((NOW-40000)) $((NOW-21601)))" $NOW
expect_fail "non-numeric endTime gives no window"           "{\"phase\":\"x\",\"network\":\"n\",\"observedAt\":\"$(iso $((NOW-7200)))\",\"endTime\":\"soon\"}" $NOW

echo "test-uptime-freshness.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
