#!/usr/bin/env bash
# test-gen-identity-ordering-guard.sh — regression for the FY_EXPECT_CYCLE
# ordering guard (exit 7) added to scripts/operator-local/gen-identity.sh in
# commit 5e73afe (design-stocktake #6).
#
# The guard: after fetching the live /api/cycle-history.jsonl, gen-identity.sh
# prints the latest recorded cycle_n and — when FY_EXPECT_CYCLE is set —
# hard-stops (exit 7) unless the ledger's max cycle_n equals it. This turns
# "record the just-closed cycle before regenerating identity" from operator
# vigilance into a machine-checked precondition (the cycle-3 trouble #1 was a
# stale ledger whose DAG root did not advance).
#
# Also covered (added for the "R1" hardening pass): when FY_EXPECT_CYCLE is
# UNSET, the guard cannot machine-check anything, so gen-identity.sh prints a
# loud stderr warning that the guard is disabled — but exit behavior for an
# otherwise-valid run is unchanged (still 0), so first-run / bootstrap
# invocations (before any cycle has closed) are not blocked.
#
# CHAIN: none. gen-identity performs no broadcast at all. This test stubs `curl`
#        so there is zero network I/O and points REPO_ROOT at a throwaway tree so
#        the real repo's public/api/ is never written.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No broadcast pathway is exercised.
#
# Method: the guard sits deep in the script (after artifact probing + the
#        identity-history bootstrap), so we drive the real script end-to-end with
#        a curl shim that serves a one-leaf artifact set from a temp docroot. A
#        freshly generated, passphrase-free ed25519 key (outside the repo)
#        satisfies the key preconditions. The mismatch cases exit 7 strictly
#        before any signing.
#
# Usage:
#   bash tests/test-gen-identity-ordering-guard.sh
#
# Exit codes:
#   0  all cases PASS (or prerequisites unavailable -> graceful skip)
#   1  any case FAILED

set -u

REPO_SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_SRC}/scripts/operator-local/gen-identity.sh"

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

skip_pass() {
	echo "SKIP: $1"
	echo
	echo "test-gen-identity-ordering-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: PASS"
	exit 0
}

[ -x "$SCRIPT" ] || { echo "FATAL: gen-identity.sh not executable at $SCRIPT" >&2; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || skip_pass "ssh-keygen unavailable"
command -v xxd        >/dev/null 2>&1 || skip_pass "xxd unavailable (needed for the >1-leaf Merkle path)"

# Refuse to run on anything that looks like a production host — gen-identity.sh
# itself would exit 99 there, and this test has no business on such hosts.
HN="$(hostname -s 2>/dev/null || hostname)"
case "$HN" in
	*validator*|*web*|*-prod*|*deploy*) skip_pass "production-looking host '$HN'";;
esac

WORK="$(mktemp -d -t fya-genid-guard.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Throwaway operator key, passphrase-free, OUTSIDE the repo (the in-repo key
# guard would exit 98 otherwise).
KEYDIR="$WORK/keys"; mkdir -p "$KEYDIR"
if ! ssh-keygen -t ed25519 -N "" -C "genid-guard-test" -f "$KEYDIR/opkey" >/dev/null 2>&1; then
	skip_pass "ssh-keygen could not generate an ed25519 test key"
fi

# Stub docroot: one live leaf (evidence.json) so the artifact_manifest is
# non-empty. cycle-history.jsonl is added/removed per case to drive the guard.
DOCROOT="$WORK/docroot"; mkdir -p "$DOCROOT/api"
printf '{"ok":true}\n' > "$DOCROOT/api/evidence.json"

# curl shim: serves fixtures from $FY_STUB_DOCROOT keyed by URL path. Handles the
# two shapes gen-identity uses: `-sSLI -o /dev/null -w %{http_code}` (probe) and
# `-sSLf -o FILE` (fetch). Unknown paths -> 404 (probe) / 22 (fetch).
STUBBIN="$WORK/bin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/curl" <<'CURL'
#!/usr/bin/env bash
docroot="${FY_STUB_DOCROOT:?}"
url=""; outfile=""; want_code=0; prev=""
for a in "$@"; do
	case "$a" in http://*|https://*) url="$a" ;; esac
	[ "$prev" = "-o" ] && outfile="$a"
	[ "$prev" = "-w" ] && want_code=1
	prev="$a"
done
path="${url#*://}"; path="${path#*/}"
fixture="${docroot}/${path}"
if [ "$want_code" = "1" ]; then
	if [ -f "$fixture" ]; then echo 200; else echo 404; fi
	exit 0
fi
if [ -n "$outfile" ] && [ "$outfile" != "/dev/null" ]; then
	if [ -f "$fixture" ]; then cp "$fixture" "$outfile"; exit 0; fi
	exit 22
fi
exit 0
CURL
chmod +x "$STUBBIN/curl"

# Run gen-identity with a fresh isolated REPO_ROOT each time (so writes never
# accumulate and each case reaches the guard identically). $1 = FY_EXPECT_CYCLE.
run_genid() {
	local expect="$1"
	local fake_repo="$WORK/repo"
	rm -rf "$fake_repo"
	mkdir -p "$fake_repo/public/api"
	local -a envp=(
		"PATH=${STUBBIN}:${PATH}"
		"FY_STUB_DOCROOT=${DOCROOT}"
		"REPO_ROOT=${fake_repo}"
		"ARTIFACT_BASE=http://stub-host"
		"OPERATOR_IDENTITY_KEY=${KEYDIR}/opkey"
	)
	[ -n "$expect" ] && envp+=("FY_EXPECT_CYCLE=${expect}")
	env "${envp[@]}" bash "$SCRIPT"
}

# ---- Case 1: stale ledger (max cycle_n=1) vs FY_EXPECT_CYCLE=2 -> exit 7 ----
printf '%s\n' '{"cycle_n":1}' > "$DOCROOT/api/cycle-history.jsonl"
out="$(run_genid 2 2>&1)"; rc=$?
if [ "$rc" -eq 7 ]; then pass "stale ledger (max cycle_n=1) vs FY_EXPECT_CYCLE=2 -> exit 7"; else fail "Case1: expected exit 7, got $rc"; fi
if echo "$out" | grep -q "FY_EXPECT_CYCLE=2 but the live cycle-history.jsonl's latest cycle_n is 1"; then
	pass "guard message names the stale cycle_n (1)"
else
	fail "Case1: guard message missing; got: $(echo "$out" | tr '\n' '|')"
fi

# ---- Case 2: ledger unfetchable (404) vs FY_EXPECT_CYCLE=2 -> exit 7 ----
rm -f "$DOCROOT/api/cycle-history.jsonl"
out="$(run_genid 2 2>&1)"; rc=$?
if [ "$rc" -eq 7 ]; then pass "ledger unfetchable vs FY_EXPECT_CYCLE=2 -> exit 7"; else fail "Case2: expected exit 7, got $rc"; fi
if echo "$out" | grep -q "latest cycle_n is none"; then
	pass "guard message reports 'none' when the ledger cannot be fetched"
else
	fail "Case2: 'latest cycle_n is none' message missing; got: $(echo "$out" | tr '\n' '|')"
fi

# ---- Case 3 (control): matching FY_EXPECT_CYCLE passes the guard ----
# Fresh ledger max cycle_n=2 == FY_EXPECT_CYCLE=2. The guard prints its
# fresh-ledger line and does NOT emit the exit-7 mismatch error (the script then
# continues past the guard into signing; we assert only the guard's own output,
# which is produced before signing, so this stays deterministic).
printf '%s\n' '{"cycle_n":2}' > "$DOCROOT/api/cycle-history.jsonl"
out="$(run_genid 2 2>&1)"; : "$?"
if echo "$out" | grep -q "ordering guard: cycle-history is fresh to expected cycle 2"; then
	pass "control: matching FY_EXPECT_CYCLE=2 passes the guard (fresh)"
else
	fail "Case3: fresh-guard message missing; got: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -q "The just-closed cycle is not on the published ledger"; then
	fail "Case3: control unexpectedly hit the exit-7 mismatch path"
else
	pass "control: no exit-7 mismatch error emitted on a fresh ledger"
fi

# ---- Case 4: FY_EXPECT_CYCLE unset -> loud warning, but exit behavior is
# unchanged (0 for an otherwise-valid run). The guard cannot machine-check
# anything with nothing to compare against (e.g. first-run/bootstrap, before
# any cycle has closed), so this must degrade to a warning, never a hard
# stop -- unset must not become a de facto "always block" mode. Ledger
# content from Case 3 is irrelevant here: the guard block is skipped
# entirely when FY_EXPECT_CYCLE is unset, so it is not reset first.
out="$(run_genid "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
	pass "unset FY_EXPECT_CYCLE: otherwise-valid run still exits 0"
else
	fail "Case4: expected exit 0 on unset FY_EXPECT_CYCLE, got $rc; output: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -q "WARNING: ordering guard DISABLED"; then
	pass "unset FY_EXPECT_CYCLE: loud disabled-guard warning emitted"
else
	fail "Case4: disabled-guard warning missing; got: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -q "ordering guard: cycle-history is fresh"; then
	fail "Case4: unset run unexpectedly printed the set-path 'fresh' message"
else
	pass "unset FY_EXPECT_CYCLE: set-path 'fresh' message correctly absent"
fi

echo
echo "----------------------------------------"
echo "test-gen-identity-ordering-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
