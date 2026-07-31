#!/usr/bin/env bash
# test-source-selection-and-pubkey-decode.sh — regression suite for the
# 2026-07-31 (cycle-4 w3) testnet-rehearsal repair:
#   1. scripts/lib/eosio-pubkey-raw-hex.js — the format-normalized public
#      key comparison that REPLACED the hardcoded PUB_K1_* pin list in
#      scripts/run-testnet-rehearsal.sh (which broke on the 2026-07-10 key
#      rotation, since it always compared against stale, now-invalid keys).
#   2. scripts/run-testnet-rehearsal.sh's anchor-source selection (step
#      1/10): default = canonical public/api/anchor-source.json;
#      anchor-source.substantive.json / anchor-source.example.json require
#      an explicit --allow-fixture flag (they used to be silently
#      auto-selected whenever the canonical file happened to be missing,
#      which is exactly how a stale cycle-2 fixture got inscribed in the
#      2026-07-01 pre-substantive rehearsal).
#
# CHAIN: none. Every case in this suite is designed to terminate INSIDE
#        step 1/10 (anchor-source selection) or step 2/10 (rehearsal
#        config check) of run-testnet-rehearsal.sh — i.e. BEFORE step 3/10
#        (the new chain-derived pubkey check, which does a real curl to
#        the read-only testnet get_account RPC) and well before any proton
#        or broadcast call. No case here invokes proton, curl, or node's
#        network stack for real.
#
# How determinism is achieved WITHOUT touching the operator's real
# ~/freedom-yield-rehearsal-config (which exists on this development
# machine — see w3-report.md): scripts/lib/require-keystore-home.sh's
# fyd_login_home() resolves the login home via `id -un` + `eval echo
# ~<user>`, independent of $HOME (by design, so it can't be spoofed via
# $HOME alone — that's the whole point of the §3.5 guard). This suite puts
# a STUB `id` on PATH (ahead of the real one) that always prints a
# guaranteed-nonexistent username. `eval echo "~<bogus-user>"` then
# resolves to the LITERAL, non-existent path
# "~<bogus-user>/freedom-yield-rehearsal-config" (verified empirically —
# see w3-report.md), so run-testnet-rehearsal.sh's step 2 (config check)
# fails deterministically and instantly on EVERY case below, on ANY
# machine, real rehearsal config or not. This never reads, writes, or
# deletes anything under the real login home.
#
# Usage:
#   bash tests/run-testnet-rehearsal/test-source-selection-and-pubkey-decode.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REHEARSAL_SCRIPT="${REPO_ROOT}/scripts/run-testnet-rehearsal.sh"
PUBKEY_HELPER="${REPO_ROOT}/scripts/lib/eosio-pubkey-raw-hex.js"

for f in "$REHEARSAL_SCRIPT" "$PUBKEY_HELPER"; do
	if [ ! -r "$f" ]; then
		echo "FATAL: expected file missing: $f" >&2
		exit 1
	fi
done
if ! command -v node >/dev/null 2>&1; then
	echo "FATAL: node required for this suite" >&2
	exit 1
fi

PASS=0
FAIL=0

pass() { printf 'PASS  %-78s%s\n' "$1" "${2:+ ($2)}"; PASS=$((PASS + 1)); }
fail_case() { printf 'FAIL  %-78s%s\n' "$1" "${2:+ ($2)}" >&2; FAIL=$((FAIL + 1)); }

# ============================================================
# Part 1: scripts/lib/eosio-pubkey-raw-hex.js (format-normalized decode)
# ============================================================
# Uses ONLY synthetic, fabricated key bytes (never real key material —
# per this repo's sanitize policy, real on-chain pubkeys must never be
# hardcoded in a fixture, even for testnet).

PART1_OUT="$(node -e '
const lib = require(process.argv[1]);
const assert = (cond, msg) => { if (!cond) { console.log("NG:" + msg); process.exitCode = 1; } };

const synthA = Buffer.from("02" + "11".repeat(32), "hex");
const synthB = Buffer.from("03" + "22".repeat(32), "hex");

const eosA = lib.encodeEosioPubkey(synthA, "EOS");
const k1A  = lib.encodeEosioPubkey(synthA, "PUB_K1_");
const eosB = lib.encodeEosioPubkey(synthB, "EOS");

// 1a. Legacy EOS format decodes back to the exact synthetic bytes.
assert(lib.decodeEosioPubkey(eosA).equals(synthA), "1a decode(EOS-format) != original bytes");
console.log("OK:1a");

// 1b. New PUB_K1_ format decodes back to the exact synthetic bytes.
assert(lib.decodeEosioPubkey(k1A).equals(synthA), "1b decode(PUB_K1_-format) != original bytes");
console.log("OK:1b");

// 1c. Cross-format equality: the SAME key in both encodings must decode
// to IDENTICAL raw hex — this is the exact property
// run-testnet-rehearsal.sh step 3/10 relies on to match a chain-returned
// EOS-format pubkey against a keystore-listed PUB_K1_-format pubkey.
assert(lib.decodeEosioPubkey(eosA).equals(lib.decodeEosioPubkey(k1A)), "1c cross-format decode mismatch for the SAME key");
console.log("OK:1c");

// 1d. A DIFFERENT key must decode to DIFFERENT raw hex (no false match).
assert(!lib.decodeEosioPubkey(eosB).equals(synthA), "1d different key decoded to the same bytes as synthA");
console.log("OK:1d");

// 1e. Malformed base58 (invalid character) is rejected, not silently
// coerced.
let threw = false;
try { lib.decodeEosioPubkey("EOS0invalidchar0000000000000000000000000000000000"); } catch (e) { threw = true; }
assert(threw, "1e malformed base58 did not throw");
console.log("OK:1e");

// 1f. Corrupted checksum (valid base58, wrong trailing bytes) is
// rejected — proves this is a real checksum-verifying decode, not a
// no-op truncation.
let threw2 = false;
try { lib.decodeEosioPubkey(eosA.slice(0, -1) + "1"); } catch (e) { threw2 = true; }
assert(threw2, "1f corrupted checksum did not throw");
console.log("OK:1f");

// 1g. Unsupported prefix is rejected fail-closed (never silently treated
// as a match or a no-op).
let threw3 = false;
try { lib.decodeEosioPubkey("PUB_R1_something"); } catch (e) { threw3 = true; }
assert(threw3, "1g unsupported prefix (PUB_R1_) did not throw");
console.log("OK:1g");
' "$PUBKEY_HELPER" 2>&1)"
PART1_RC=$?

for tag in 1a 1b 1c 1d 1e 1f 1g; do
	if printf '%s\n' "$PART1_OUT" | grep -q "^OK:${tag}$"; then
		pass "eosio-pubkey-raw-hex.js: case ${tag}"
	else
		fail_case "eosio-pubkey-raw-hex.js: case ${tag}" "$(printf '%s' "$PART1_OUT" | grep "^NG:" | head -1)"
	fi
done
if [ "$PART1_RC" -ne 0 ] && ! printf '%s\n' "$PART1_OUT" | grep -q "^NG:"; then
	fail_case "eosio-pubkey-raw-hex.js: harness itself" "unexpected non-assertion failure: $PART1_OUT"
fi

# 1h. CLI entrypoint (the exact invocation shape run-testnet-rehearsal.sh
# uses): prints 66 lowercase hex chars on success, exit 0.
CLI_SYNTH_EOS="$(node -e '
const lib = require(process.argv[1]);
process.stdout.write(lib.encodeEosioPubkey(Buffer.from("02"+"33".repeat(32),"hex"), "EOS"));
' "$PUBKEY_HELPER")"
CLI_OUT="$(node "$PUBKEY_HELPER" "$CLI_SYNTH_EOS" 2>&1)"
CLI_RC=$?
if [ "$CLI_RC" -eq 0 ] && printf '%s' "$CLI_OUT" | grep -qE '^[0-9a-f]{66}$'; then
	pass "eosio-pubkey-raw-hex.js: CLI entrypoint prints 66-hex on success" "rc=$CLI_RC"
else
	fail_case "eosio-pubkey-raw-hex.js: CLI entrypoint prints 66-hex on success" "rc=$CLI_RC out=[$CLI_OUT]"
fi

# 1i. CLI entrypoint: no arg → usage + exit 1 (not a crash/traceback).
NOARG_RC=0
NOARG_OUT="$(node "$PUBKEY_HELPER" 2>&1)" || NOARG_RC=$?
if [ "$NOARG_RC" -eq 1 ] && printf '%s' "$NOARG_OUT" | grep -qi usage; then
	pass "eosio-pubkey-raw-hex.js: CLI no-arg -> usage, exit 1"
else
	fail_case "eosio-pubkey-raw-hex.js: CLI no-arg -> usage, exit 1" "rc=$NOARG_RC out=[$NOARG_OUT]"
fi

# ============================================================
# Part 2: run-testnet-rehearsal.sh step 1/10 — anchor-source selection +
# --allow-fixture gating
# ============================================================

# ---- hermetic `id` stub (see file header for why) ----
STUB_DIR="$(mktemp -d -t rehearsal-src-sel-stub.XXXXXX)"
cat > "$STUB_DIR/id" <<'STUB'
#!/usr/bin/env bash
# Always report a guaranteed-nonexistent username, regardless of args.
# See file header: this makes LOGIN_HOME (and therefore REHEARSAL_CFG)
# resolve to a literal, nonexistent path, so step 2/10's config check
# fails deterministically without touching any real directory.
echo "fyd-test-fixture-user-does-not-exist-12345"
STUB
chmod +x "$STUB_DIR/id"

TEST_HOME="$(mktemp -d -t rehearsal-src-sel-home.XXXXXX)"

cleanup() { rm -rf "$STUB_DIR" "$TEST_HOME"; }
trap cleanup EXIT

FIXTURE_SUBSTANTIVE="${REPO_ROOT}/public/api/anchor-source.substantive.json"
FIXTURE_EXAMPLE="${REPO_ROOT}/public/api/anchor-source.example.json"
CANONICAL="${REPO_ROOT}/public/api/anchor-source.json"

run_rehearsal() {
	# Runs run-testnet-rehearsal.sh hermetically: id-stubbed PATH (so
	# REHEARSAL_CFG can never resolve to the real login home's config
	# dir), fresh throwaway HOME (passes the §3.5 keystore guard — not
	# the login home), a bounded timeout as belt-and-suspenders (no case
	# here should ever reach a network call, but this guarantees the
	# suite can't hang if that invariant is ever violated by a future
	# edit), stdin closed.
	PATH="${STUB_DIR}:${PATH}" HOME="$TEST_HOME" timeout 15 bash "$REHEARSAL_SCRIPT" "$@" </dev/null
}

# 2a. Default (no --source/--allow-fixture): canonical file selected,
# audit fields printed, NOT gated as a fixture, then fails deterministically
# at step 2/10 (config missing, via the id-stub) — a later, distinct
# failure from any fixture-refusal.
#
# Expected cycle_number/memo_prefix are read live from the CURRENT
# canonical anchor-source.json via jq (not hardcoded) — that file is
# expected to change at every cycle transition, and a hardcoded cycle
# number here would go stale for exactly the reason this whole repair
# exists (never re-pin a value the chain/repo state will rotate past).
if command -v jq >/dev/null 2>&1 && [ -r "$CANONICAL" ]; then
	EXPECT_SCHEMA_VER="$(jq -r '.schema_version // empty' "$CANONICAL")"
	EXPECT_CYCLE_NUM="$(jq -r '.observations_branch.cycle_number_observed // empty' "$CANONICAL")"
	EXPECT_MEMO_PREFIX="fya${EXPECT_SCHEMA_VER}c${EXPECT_CYCLE_NUM}"
else
	EXPECT_CYCLE_NUM=""
	EXPECT_MEMO_PREFIX=""
fi
OUT_2A="$(run_rehearsal 2>&1)"; RC_2A=$?
if [ "$RC_2A" -eq 1 ] \
   && printf '%s' "$OUT_2A" | grep -qF "origin:    default (canonical)" \
   && printf '%s' "$OUT_2A" | grep -qF "basename:  anchor-source.json" \
   && { [ -z "$EXPECT_CYCLE_NUM" ] || printf '%s' "$OUT_2A" | grep -qF "cycle_number_observed:  ${EXPECT_CYCLE_NUM}"; } \
   && { [ -z "$EXPECT_MEMO_PREFIX" ] || printf '%s' "$OUT_2A" | grep -qF "derived memo_prefix:    ${EXPECT_MEMO_PREFIX}"; } \
   && ! printf '%s' "$OUT_2A" | grep -qi "refusing fixture" \
   && printf '%s' "$OUT_2A" | grep -qF "FAIL: config file missing"; then
	pass "default (no args): canonical selected + audited, not fixture-gated" "rc=$RC_2A cycle=${EXPECT_CYCLE_NUM:-?}"
else
	fail_case "default (no args): canonical selected + audited, not fixture-gated" "rc=$RC_2A out=[$(printf '%s' "$OUT_2A" | tr '\n' '|')]"
fi

# 2b. --source=<substantive fixture> WITHOUT --allow-fixture -> refused
# INSIDE step 1/10, before step 2/10 is ever reached.
OUT_2B="$(run_rehearsal "--source=${FIXTURE_SUBSTANTIVE}" 2>&1)"; RC_2B=$?
if [ "$RC_2B" -eq 1 ] \
   && printf '%s' "$OUT_2B" | grep -qi "refusing fixture" \
   && printf '%s' "$OUT_2B" | grep -qi -- "--allow-fixture" \
   && ! printf '%s' "$OUT_2B" | grep -qF "config file missing"; then
	pass "substantive fixture without --allow-fixture -> refused at step 1" "rc=$RC_2B"
else
	fail_case "substantive fixture without --allow-fixture -> refused at step 1" "rc=$RC_2B out=[$(printf '%s' "$OUT_2B" | tr '\n' '|')]"
fi

# 2c. --source=<example fixture> WITHOUT --allow-fixture -> same refusal
# (both fixture basenames are gated, not just .substantive.json).
OUT_2C="$(run_rehearsal "--source=${FIXTURE_EXAMPLE}" 2>&1)"; RC_2C=$?
if [ "$RC_2C" -eq 1 ] && printf '%s' "$OUT_2C" | grep -qi "refusing fixture"; then
	pass "example fixture without --allow-fixture -> refused at step 1" "rc=$RC_2C"
else
	fail_case "example fixture without --allow-fixture -> refused at step 1" "rc=$RC_2C out=[$(printf '%s' "$OUT_2C" | tr '\n' '|')]"
fi

# 2d. --source=<substantive fixture> --allow-fixture -> step 1/10 PASSES
# (prints a WARNING, not a refusal), then fails at step 2/10 (a later,
# distinct, deterministic failure) — proves --allow-fixture is a real
# opt-in, not a no-op.
OUT_2D="$(run_rehearsal "--source=${FIXTURE_SUBSTANTIVE}" --allow-fixture 2>&1)"; RC_2D=$?
if [ "$RC_2D" -eq 1 ] \
   && printf '%s' "$OUT_2D" | grep -qi "WARNING: using FIXTURE" \
   && ! printf '%s' "$OUT_2D" | grep -qi "refusing fixture" \
   && printf '%s' "$OUT_2D" | grep -qF "FAIL: config file missing"; then
	pass "substantive fixture WITH --allow-fixture -> passes step 1, fails later" "rc=$RC_2D"
else
	fail_case "substantive fixture WITH --allow-fixture -> passes step 1, fails later" "rc=$RC_2D out=[$(printf '%s' "$OUT_2D" | tr '\n' '|')]"
fi

# 2e. ANCHOR_SOURCE_OVERRIDE env pointing at a fixture, WITHOUT
# --allow-fixture -> refused the same way as --source= (the gate applies
# regardless of how the fixture path was supplied).
OUT_2E="$(ANCHOR_SOURCE_OVERRIDE="${FIXTURE_EXAMPLE}" run_rehearsal 2>&1)"; RC_2E=$?
if [ "$RC_2E" -eq 1 ] && printf '%s' "$OUT_2E" | grep -qi "refusing fixture"; then
	pass "ANCHOR_SOURCE_OVERRIDE=fixture without --allow-fixture -> refused" "rc=$RC_2E"
else
	fail_case "ANCHOR_SOURCE_OVERRIDE=fixture without --allow-fixture -> refused" "rc=$RC_2E out=[$(printf '%s' "$OUT_2E" | tr '\n' '|')]"
fi

# 2f. --source=<nonexistent path> -> fails the readability check inside
# step 1/10 (distinct message, no fixture-gate text at all).
OUT_2F="$(run_rehearsal "--source=/nonexistent/path/anchor-source.json" 2>&1)"; RC_2F=$?
if [ "$RC_2F" -eq 1 ] \
   && printf '%s' "$OUT_2F" | grep -qi "not readable" \
   && ! printf '%s' "$OUT_2F" | grep -qi "refusing fixture"; then
	pass "--source=<nonexistent path> -> not-readable failure at step 1" "rc=$RC_2F"
else
	fail_case "--source=<nonexistent path> -> not-readable failure at step 1" "rc=$RC_2F out=[$(printf '%s' "$OUT_2F" | tr '\n' '|')]"
fi

# 2g. --source=<canonical path itself, explicit> -> NOT fixture-gated
# (only the two specific fixture basenames are gated; the canonical
# basename passed explicitly must behave identically to the default).
OUT_2G="$(run_rehearsal "--source=${CANONICAL}" 2>&1)"; RC_2G=$?
if [ "$RC_2G" -eq 1 ] \
   && printf '%s' "$OUT_2G" | grep -qF "origin:    --source=" \
   && ! printf '%s' "$OUT_2G" | grep -qi "refusing fixture" \
   && printf '%s' "$OUT_2G" | grep -qF "FAIL: config file missing"; then
	pass "--source=<canonical path explicit> -> not fixture-gated" "rc=$RC_2G"
else
	fail_case "--source=<canonical path explicit> -> not fixture-gated" "rc=$RC_2G out=[$(printf '%s' "$OUT_2G" | tr '\n' '|')]"
fi

# 2h. -h/--help -> exit 0, usage text mentions --allow-fixture (so the
# operator-facing docs actually mention the new flag).
OUT_2H="$(run_rehearsal --help 2>&1)"; RC_2H=$?
if [ "$RC_2H" -eq 0 ] && printf '%s' "$OUT_2H" | grep -qi -- "--allow-fixture"; then
	pass "-h/--help -> exit 0, mentions --allow-fixture"
else
	fail_case "-h/--help -> exit 0, mentions --allow-fixture" "rc=$RC_2H"
fi

# 2i. Unknown flag -> exit 1 (pre-existing arg-parsing behavior,
# unchanged by this repair).
OUT_2I="$(run_rehearsal --bogus-flag-xyz 2>&1)"; RC_2I=$?
if [ "$RC_2I" -eq 1 ] && printf '%s' "$OUT_2I" | grep -qi "unknown arg"; then
	pass "unknown flag -> exit 1"
else
	fail_case "unknown flag -> exit 1" "rc=$RC_2I out=[$(printf '%s' "$OUT_2I" | tr '\n' '|')]"
fi

# ---- Summary ----
echo
echo "----------------------------------------"
echo "test-source-selection-and-pubkey-decode.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
