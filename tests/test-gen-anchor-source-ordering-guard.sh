#!/usr/bin/env bash
# test-gen-anchor-source-ordering-guard.sh — regression for the FY_EXPECT_CYCLE
# ordering guard added to scripts/gen-anchor-source.sh (W2, 8/4 cycle-4 prep).
#
# The guard: gen-anchor-source.sh derives CLOSED_COUNT from the number of
# lines on cycle-history.jsonl and composes CYCLE_NUMBER=CLOSED_COUNT+1,
# which becomes the memo prefix fya1c<N> at anchor time. If this script runs
# BEFORE the just-closed cycle's record is published, CLOSED_COUNT
# under-counts by one and the composed anchor-source would (once broadcast)
# re-inscribe an already-used memo prefix — unrecoverable on an append-only
# chain. scripts/operator-local/gen-identity.sh already carries an
# equivalent FY_EXPECT_CYCLE guard (design-stocktake #6, see
# tests/test-gen-identity-ordering-guard.sh, the model for this suite);
# gen-anchor-source.sh did not, until this change.
#
# Guard contract (mirrors gen-identity.sh's MESSAGE idiom, but NOT its exit
# code — see below):
#   - FY_EXPECT_CYCLE set   + CLOSED_COUNT mismatches it -> exit 9, message
#     names expected/actual/source/remediation.
#   - FY_EXPECT_CYCLE set   + CLOSED_COUNT matches it     -> guard passes,
#     script continues (past the guard; this suite does not need the run to
#     reach exit 0 — only that it did NOT hard-stop at the guard).
#   - FY_EXPECT_CYCLE unset                                -> loud stderr
#     "ordering guard DISABLED" banner, exit behavior unchanged (no hard
#     stop from the guard itself).
#   - cycle-history.jsonl unreachable from EVERY source (public URL, the
#     script's own repo-local mirror, and $CYCLE_HISTORY_JSONL)  -> treated
#     as CLOSED_COUNT=0 (pre-genesis), guard still evaluates against that.
#
# Exit code 9, not 7: gen-identity.sh's analogous ordering guard uses exit 7,
# but gen-anchor-source.sh's OWN exit-code table already assigns 7 to "atomic
# write failed" (see the script's header). One code, one meaning within a
# single script wins over verbatim parity between the two scripts' guards,
# so this suite asserts exit 9, deliberately NOT reusing gen-identity.sh's 7.
#
# The guard is placed BEFORE the P-chain RPC call in gen-anchor-source.sh
# specifically so it is reachable — and testable — without stubbing a live
# metalgo node: this suite only fixtures the pubkey URL, identity-history
# fetch, and cycle-history fetch (all read before the guard runs); the RPC
# POST is deliberately left unstubbed; the guard's own pass/fail messages
# are asserted from stderr, never the script's final exit code, on the two
# cases where the guard does not itself hard-stop.
#
# CHAIN: none. gen-anchor-source.sh performs no broadcast of its own (it
#        only composes a JSON artifact) and the guard cases in this suite
#        exit 9 (or continue toward the unstubbed RPC call, which fails
#        closed at exit 4) strictly before any anchor-source.json write.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No broadcast pathway is exercised.
#         All curl calls are routed to a local stub; zero network I/O.
#
# Method: curl stub + fixture docroot, same technique as
#         tests/gen-anchor-source/test-gen-anchor-source.sh (routes by URL
#         suffix; POST detection returns a canned RPC response so an
#         accidental match doesn't hang). All repo-default file paths
#         (IDENTITY_JSON, IDENTITY_HISTORY_JSONL, ANCHOR_HISTORY_JSONL,
#         CYCLE_HISTORY_JSONL, etc.) are pointed at nonexistent paths under
#         a per-run tmpdir so this suite can never read or write real repo
#         state (gen-anchor-source.sh's $ROOT is the script's own directory
#         and is not independently overridable, but this worktree carries
#         no public/api/cycle-history.jsonl, so fetch_api_file's internal
#         ROOT-hardcoded local-fallback path is confirmed unreadable here —
#         see report for the verification command).
#
# Usage:
#   bash tests/test-gen-anchor-source-ordering-guard.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/gen-anchor-source.sh"

PASS=0
FAIL=0
pass() { printf 'PASS  %-70s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %-70s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

skip_pass() {
	echo "SKIP: $1"
	echo
	echo "test-gen-anchor-source-ordering-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: PASS"
	exit 0
}

[ -x "$SCRIPT" ] || { echo "FATAL: gen-anchor-source.sh not executable at $SCRIPT" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || skip_pass "curl unavailable"
command -v jq   >/dev/null 2>&1 || skip_pass "jq unavailable"
command -v base64 >/dev/null 2>&1 || skip_pass "base64 unavailable"

WORK="$(mktemp -d -t fya-gas-guard.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FIX="$WORK/fixtures"
mkdir -p "$FIX"

# Pinned ed25519 OpenSSH pubkey (synthetic, DO-NOT-USE key; same fixture as
# tests/gen-anchor-source/test-gen-anchor-source.sh). Its exact hash is not
# asserted here (that suite already pins it) — this suite only needs the
# semantic-C extraction (base64-decode -> tail -c 32 -> sha256) to succeed
# so the script reaches the ordering guard at all.
cat > "$FIX/operator-identity.pub" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHbSbydeQ7/AxLU4BUaqA6rXTMb5y6wcTW2+nRtV/gnj fixture-test-key
EOF

printf '{"seq":1,"note":"fixture-identity-history"}\n' > "$FIX/identity-history.jsonl"

# ---- curl stub ------------------------------------------------------------
# Routes GET fetches by URL suffix to $CASE_DIR/cycle-history.jsonl (each
# case points $CASE_DIR at its own fixture dir, so this stub script itself
# never needs rewriting between cases). The P-chain RPC POST (detected via
# the literal "POST" arg) returns a fixed, syntactically valid-but-empty
# validators response — the guard cases below never depend on reaching or
# parsing it; it only exists so an accidental real POST doesn't hang or
# error confusingly. Any unmatched GET exits 22 (curl-like failure).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<STUBEOF
#!/usr/bin/env bash
FIX="$FIX"
URL=""; OUTFILE=""; IS_POST=0; prev=""
for a in "\$@"; do
	case "\$a" in http*) URL="\$a" ;; esac
	[ "\$prev" = "-o" ] && OUTFILE="\$a"
	[ "\$a" = "POST" ] && IS_POST=1
	prev="\$a"
done
if [ "\$IS_POST" -eq 1 ]; then
	echo '{"jsonrpc":"2.0","id":1,"result":{"validators":[]}}'
	exit 0
fi
case "\$URL" in
	*/operator-identity.pub)  cp "\$FIX/operator-identity.pub" "\$OUTFILE"; exit 0 ;;
	*/identity-history.jsonl) cp "\$FIX/identity-history.jsonl" "\$OUTFILE"; exit 0 ;;
	*/cycle-history.jsonl)
		if [ -n "\${CASE_DIR:-}" ] && [ -r "\${CASE_DIR}/cycle-history.jsonl" ]; then
			cp "\${CASE_DIR}/cycle-history.jsonl" "\$OUTFILE"; exit 0
		fi
		exit 22
		;;
	*) echo "STUB CURL: unmatched URL: \$URL" >&2; exit 22 ;;
esac
STUBEOF
chmod +x "$WORK/bin/curl"

# run_gas <FY_EXPECT_CYCLE|""> <cycle_history_line_count|"absent"> [CYCLE_HISTORY_JSONL_override]
# Runs the real script with the guard's inputs controlled; every other
# repo-default path is pinned at a nonexistent tmp path so the run can never
# touch real repo state.
run_gas() {
	local expect="$1" lines="$2" cyc_jsonl_override="${3:-}"
	local case_dir="$WORK/case-$$-$RANDOM"
	mkdir -p "$case_dir"
	if [ "$lines" != "absent" ]; then
		: > "$case_dir/cycle-history.jsonl"
		local i=1
		while [ "$i" -le "$lines" ]; do
			printf '{"cycle_n":%s}\n' "$i" >> "$case_dir/cycle-history.jsonl"
			i=$((i + 1))
		done
	fi
	local -a envp=(
		"PATH=${WORK}/bin:${PATH}"
		"CASE_DIR=${case_dir}"
		"NODE_ID=NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
		"API_BASE_URL=https://fixture.invalid/api"
		"PUBKEY_URL=https://fixture.invalid/.well-known/operator-identity.pub"
		"METALGO_API=http://127.0.0.1:9650"
		"IDENTITY_JSON=${WORK}/nonexistent-identity.json"
		"IDENTITY_HISTORY_JSONL=${WORK}/nonexistent-identity-history.jsonl"
		"ANCHOR_HISTORY_JSONL=${WORK}/nonexistent-anchor-history.jsonl"
		"CYCLE_HISTORY_JSONL=${cyc_jsonl_override:-${WORK}/nonexistent-cycle-history.jsonl}"
		"ANOMALY_STATE_DIR=${WORK}/state"
		"UPTIME_HISTORY_JSONL=${WORK}/state/nonexistent-uptime-history.jsonl"
		"DELEGATOR_EVENTS_JSONL=${WORK}/state/nonexistent-delegator-events.jsonl"
		"ANOMALIES_LOG=${WORK}/state/nonexistent-anomalies.log"
		"FY_CONFIG_DIR=${WORK}/cfg"
	)
	[ -n "$expect" ] && envp+=("FY_EXPECT_CYCLE=${expect}")
	env "${envp[@]}" bash "$SCRIPT" --dry-run
}

# ---- Case 1: CLOSED_COUNT=1 (public URL) vs FY_EXPECT_CYCLE=2 -> exit 9 ----
out="$(run_gas 2 1 2>&1)"; rc=$?
if [ "$rc" -eq 9 ]; then pass "mismatch: CLOSED_COUNT=1 vs FY_EXPECT_CYCLE=2 -> exit 9"; else fail "Case1: expected exit 9, got $rc"; fi
if echo "$out" | grep -q "FY_EXPECT_CYCLE=2 but cycle-history.jsonl's CLOSED_COUNT is 1"; then
	pass "mismatch: guard message names expected (2) and actual (1) CLOSED_COUNT"
else
	fail "Case1: guard message missing; got: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -q "source: public URL"; then
	pass "mismatch: guard message names the public URL as the source"
else
	fail "Case1: guard message missing public-URL source; got: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -q "exit 9, not 7"; then
	pass "mismatch: guard message disambiguates exit 9 vs gen-identity.sh's exit 7"
else
	fail "Case1: guard message missing the exit-9-vs-7 disambiguation note; got: $(echo "$out" | tr '\n' '|')"
fi

# ---- Case 2: CLOSED_COUNT=2 via LOCAL fallback (public URL unreachable) ----
# vs FY_EXPECT_CYCLE=2 -> guard passes (control). Also exercises the
# "fetch_api_file fell back to a local copy" messaging requirement: the
# public URL is made unreachable (no case_dir fixture) and CYCLE_HISTORY_JSONL
# points at a real local file instead, so CYCLE_HISTORY_SOURCE must say so.
LOCAL_CH="$WORK/local-cycle-history.jsonl"
printf '{"cycle_n":1}\n{"cycle_n":2}\n' > "$LOCAL_CH"
out="$(run_gas 2 absent "$LOCAL_CH" 2>&1)"; : "$?"
if echo "$out" | grep -q "ordering guard: cycle-history CLOSED_COUNT is fresh to expected cycle 2"; then
	pass "control: local-fallback CLOSED_COUNT=2 matches FY_EXPECT_CYCLE=2 -> guard passes"
else
	fail "Case2: fresh-guard message missing; got: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -q "the just-closed cycle is not on the published ledger"; then
	fail "Case2: control unexpectedly hit the exit-9 mismatch path"
else
	pass "control: no exit-9 mismatch message emitted"
fi
if echo "$out" | grep -q "local repo fallback"; then
	pass "control: guard message reports the local-repo-fallback source (fetch_api_file spec requirement)"
else
	fail "Case2: guard message missing 'local repo fallback' source note; got: $(echo "$out" | tr '\n' '|')"
fi

# ---- Case 3: FY_EXPECT_CYCLE unset -> loud warning, guard does not hard-stop
out="$(run_gas "" 0 2>&1)"; rc=$?
if [ "$rc" -ne 9 ]; then
	pass "unset FY_EXPECT_CYCLE: guard itself does not force exit 9"
else
	fail "Case3: guard hard-stopped (exit 9) despite FY_EXPECT_CYCLE being unset"
fi
if echo "$out" | grep -q "WARNING: ordering guard DISABLED"; then
	pass "unset FY_EXPECT_CYCLE: loud disabled-guard warning emitted"
else
	fail "Case3: disabled-guard warning missing; got: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -q "ordering guard: cycle-history CLOSED_COUNT is fresh"; then
	fail "Case3: unset run unexpectedly printed the set-path 'fresh' message"
else
	pass "unset FY_EXPECT_CYCLE: set-path 'fresh' message correctly absent"
fi

# ---- Case 4: cycle-history.jsonl unreachable from EVERY source -> CLOSED_COUNT=0
# Public URL fetch fails (no case_dir fixture), fetch_api_file's own
# ROOT-hardcoded repo-local mirror is confirmed absent in this worktree (see
# header), and CYCLE_HISTORY_JSONL points at a nonexistent path too. With
# FY_EXPECT_CYCLE=1 this must still mismatch (0 != 1) and exit 9, reporting
# CLOSED_COUNT=0 and the "no source reachable" wording — not crash or
# silently treat it as a match.
out="$(run_gas 1 absent 2>&1)"; rc=$?
if [ "$rc" -eq 9 ]; then pass "unreachable: no source anywhere -> CLOSED_COUNT=0, mismatches FY_EXPECT_CYCLE=1 -> exit 9"; else fail "Case4: expected exit 9, got $rc"; fi
if echo "$out" | grep -q "CLOSED_COUNT is 0"; then
	pass "unreachable: guard message reports CLOSED_COUNT=0"
else
	fail "Case4: guard message missing CLOSED_COUNT=0; got: $(echo "$out" | tr '\n' '|')"
fi
if echo "$out" | grep -q "no source reachable"; then
	pass "unreachable: guard message names the unreachable source explicitly"
else
	fail "Case4: guard message missing unreachable-source note; got: $(echo "$out" | tr '\n' '|')"
fi

echo
echo "----------------------------------------"
echo "test-gen-anchor-source-ordering-guard.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
