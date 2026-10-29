#!/usr/bin/env bash
# test-uptime-body-check.sh — proves the "expected token" body check in
# .github/workflows/uptime.yml neither false-alarms on a large body nor loses
# its teeth on a body that really lacks the token.
#
# Why this exists: the check used to be `echo "$body" | grep -q "$TOKEN"`
# under `set -euo pipefail`. grep -q exits the moment it sees the token; when
# the body is bigger than the pipe buffer, echo is still writing and dies of
# SIGPIPE ("echo: write error: Broken pipe" in the failed runs of
# 2026-09-20T23:07Z and 2026-09-22T07:36Z), pipefail turns that into a
# non-zero pipeline, and the job reported "Body missing expected token" for a
# page that DID contain it — an intermittent false alarm.
#
# The check block is EXTRACTED from the workflow file at test time (never
# copied here), so if the workflow regresses to a pipe this suite goes red.
# Mutation proof (2026-09-24): restoring the old `echo "$body" | grep -q`
# line makes case 1 fail deterministically (body ~1 MiB >> pipe buffer).
#
# CHAIN: none — no network, no broadcast. Runs the extracted shell block
#        locally against synthetic bodies only.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Usage:
#   bash tests/uptime-workflow/test-uptime-body-check.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/uptime.yml"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

if [ ! -f "$WORKFLOW" ]; then
	echo "FATAL: workflow not found at $WORKFLOW" >&2
	exit 1
fi

WORK="$(mktemp -d -t uptime-body-check-test.XXXXXX)"
teardown() { rm -rf "$WORK"; }
trap teardown EXIT

# ---- extract the check block -------------------------------------------------
# From the `if ! ... EXPECTED_TOKEN ...; then` line to its closing `fi`,
# de-indented. Exactly one such block must exist, otherwise we would be
# testing nothing (or the wrong thing).
BLOCK_FILE="${WORK}/block.sh"
awk '
	!inblk && /^[[:space:]]*if ! .*EXPECTED_TOKEN.*; then[[:space:]]*$/ { inblk=1; n++ }
	inblk { sub(/^[[:space:]]+/, ""); print }
	inblk && /^[[:space:]]*fi[[:space:]]*$/ { inblk=0 }
	END { if (n != 1) exit 3 }
' "$WORKFLOW" > "$BLOCK_FILE"
EXTRACT_RC=$?
if [ "$EXTRACT_RC" -ne 0 ] || ! tail -1 "$BLOCK_FILE" | grep -qx 'fi'; then
	bad "extract: exactly one EXPECTED_TOKEN if-block found in uptime.yml (awk rc=$EXTRACT_RC) — reformatted?"
	echo "test-uptime-body-check.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: FAIL"
	exit 1
fi
ok "extract: exactly one EXPECTED_TOKEN if-block found in uptime.yml"

# run_check <body-file> <sigpipe-mode: default|ignore>
# Runs the extracted block exactly as the workflow step does (bash with
# -euo pipefail). "ignore" mirrors the GitHub runner, where SIGPIPE is ignored
# and echo reports "write error: Broken pipe" instead of being killed.
run_check() {
	local body_file="$1" mode="$2" pre=""
	[ "$mode" = "ignore" ] && pre="trap '' PIPE"
	EXPECTED_TOKEN="Freedom Yield" BODY_FILE="$body_file" \
		bash -c "set -euo pipefail
${pre}
body=\$(cat \"\$BODY_FILE\")
$(cat "$BLOCK_FILE")
echo CHECK_OK" 2>&1
}

# ---- fixtures ----------------------------------------------------------------
# ~1 MiB, far above any pipe buffer (64 KiB on Linux/macOS), so the old pipe
# form reliably hits SIGPIPE once grep -q exits on the first line.
make_big() {
	# $1 = out file, $2 = first line
	{
		printf '%s\n' "$2"
		local i=0
		while [ "$i" -lt 16384 ]; do
			printf '<p>filler line %06d lorem ipsum dolor sit amet consectetur</p>\n' "$i"
			i=$((i + 1))
		done
	} > "$1"
}
BIG_WITH="${WORK}/big-with-token.html"
BIG_WITHOUT="${WORK}/big-without-token.html"
SMALL_WITH="${WORK}/small-with-token.html"
make_big "$BIG_WITH" '<title>Metal Freedom Yield</title>'
make_big "$BIG_WITHOUT" '<title>Some Other Site</title>'
printf '<title>Metal Freedom Yield</title>\n' > "$SMALL_WITH"

BIG_BYTES=$(wc -c < "$BIG_WITH" | tr -d ' ')
if [ "$BIG_BYTES" -gt 524288 ]; then
	ok "fixture: large body is ${BIG_BYTES} bytes (> 512 KiB, well above pipe buffer)"
else
	bad "fixture: large body is only ${BIG_BYTES} bytes — too small to force SIGPIPE"
fi

# ---- case 1: large body WITH token near the start → must pass ----------------
# Repeated to catch any timing-dependent flake, under both SIGPIPE dispositions.
for mode in default ignore; do
	c1_fail=0
	for run in 1 2 3 4 5; do
		out="$(run_check "$BIG_WITH" "$mode")"
		rc=$?
		if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'CHECK_OK'; then
			c1_fail=1
			bad "case1[$mode] run $run: large body containing the token passes the check — actual rc=$rc, out:
$(printf '%s\n' "$out" | tail -5)"
			break
		fi
	done
	[ "$c1_fail" -eq 0 ] && ok "case1[$mode]: large body containing the token passes the check (5/5 runs)"
done

# ---- case 2: small body WITH token → must pass -------------------------------
out="$(run_check "$SMALL_WITH" default)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx 'CHECK_OK'; then
	ok "case2: small body containing the token passes the check"
else
	bad "case2: small body containing the token passes the check — actual rc=$rc, out: $out"
fi

# ---- case 3: large body WITHOUT token → must still fail (teeth) --------------
for mode in default ignore; do
	out="$(run_check "$BIG_WITHOUT" "$mode")"; rc=$?
	if [ "$rc" -ne 0 ] \
		&& printf '%s\n' "$out" | grep -q "::error::Body missing expected token 'Freedom Yield'" \
		&& ! printf '%s\n' "$out" | grep -qx 'CHECK_OK'; then
		ok "case3[$mode]: large body without the token fails with the missing-token error"
	else
		bad "case3[$mode]: large body without the token fails with the missing-token error — actual rc=$rc, out:
$(printf '%s\n' "$out" | tail -5)"
	fi
done

# ---- summary -----------------------------------------------------------------
echo "test-uptime-body-check.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
