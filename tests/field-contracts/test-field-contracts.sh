#!/usr/bin/env bash
# test-field-contracts.sh — suite for scripts/check-field-contracts.py.
#
# CHAIN: none — builds throwaway synthetic repos in a tempdir and copies a
#        read-only subset of this repo; no network, no host, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# Two layers:
#
#   A. Synthetic fixtures — a minimal repo with one writer and one reader, so
#      each detection rule (guarded / unguarded / dead-alternative / JS /
#      --slurpfile scoping / waivers / comment handling) is exercised in
#      isolation and cannot be masked by real-repo content.
#
#   B. Mutation tests against a COPY of this repo — reintroduce, one at a
#      time, each field-name bug that has actually happened here and assert
#      the checker turns red. A static checker nobody has watched fail is not
#      evidence of anything; these are that evidence. B2 in particular
#      restores the exact 2026-08-04 anchor-history read that would have
#      severed the on-chain hash chain.
#
# Usage:
#   bash tests/field-contracts/test-field-contracts.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_ROOT}/scripts/check-field-contracts.py"

if [ ! -f "$CHECKER" ]; then
	echo "FATAL: checker not found at $CHECKER" >&2
	exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
	echo "FATAL: python3 required" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

BASE="$(mktemp -d -t field-contracts-test.XXXXXX)"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

# run <repo> [args...] -> sets RC and OUT
run() {
	local repo="$1"; shift
	OUT="$(python3 "$CHECKER" --repo="$repo" "$@" 2>&1)"
	RC=$?
}

# ---------------------------------------------------------------------------
# A. Synthetic fixture repo
# ---------------------------------------------------------------------------
# thing.json deliberately carries a key named "odi" that other.json does NOT.
# That is what makes case A7 meaningful: without --slurpfile scoping, a bad
# read of `.odi` on the slurped artifact would be silently excused by the main
# artifact's vocabulary.
new_fixture() {
	local t="$1"
	rm -rf "$t"
	mkdir -p "$t/scripts" "$t/public/api" "$t/public/assets"

	cat > "$t/public/api/thing.example.json" <<'EOF'
{"alpha": 1, "beta": 2, "odi": "z", "list": [{"gamma": 3}]}
EOF
	cat > "$t/public/api/other.example.json" <<'EOF'
{"items": [{"oid": "x"}]}
EOF

	cat > "$t/scripts/writer.sh" <<'EOF'
#!/usr/bin/env bash
OUT="${ROOT}/public/api/thing.json"
jq -n '{alpha: 1, beta: 2, odi: "z", list: [{gamma: 3}]}' > "$OUT"
EOF

	cat > "$t/scripts/reader.sh" <<'EOF'
#!/usr/bin/env bash
THING="${ROOT}/public/api/thing.json"
A="$(jq -r '.alpha' "$THING")"
EOF

	cat > "$t/public/assets/app.js" <<'EOF'
(function () {
	function render(it) { return it.gamma; }
	async function load() {
		var res = await fetch("/api/thing.json", { cache: "no-store" });
		var data = await res.json();
		var list = data.list || [];
		document.title = (data.alpha || "-") + list.map(render).join("");
	}
	load();
})();
EOF
}

T="$BASE/fixture"

# ---- A1: clean fixture -> exit 0, zero findings ----------------------------
new_fixture "$T"
run "$T" --strict
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "CRITICAL=0 HIGH=0 LOW=0" \
	&& ok "A1 clean fixture: exit 0, no findings" \
	|| bad "A1 clean fixture (rc=$RC): $OUT"

# ---- A2: guarded unknown key -> CRITICAL (the accident's disguise) ---------
new_fixture "$T"
sed -i.bak "s|jq -r '.alpha'|jq -r '.alfa // \"\"'|" "$T/scripts/reader.sh"
run "$T"
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q "^CRITICAL" && echo "$OUT" | grep -q "\.alfa" \
	&& ok "A2 guarded unknown jq key -> CRITICAL + exit 1" \
	|| bad "A2 guarded unknown jq key (rc=$RC): $OUT"

# ---- A3: unguarded unknown key -> HIGH -------------------------------------
new_fixture "$T"
sed -i.bak "s|jq -r '.alpha'|jq -r '.alfa'|" "$T/scripts/reader.sh"
run "$T"
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q "^HIGH" \
	&& ok "A3 unguarded unknown jq key -> HIGH + exit 1" \
	|| bad "A3 unguarded unknown jq key (rc=$RC): $OUT"

# ---- A4: dead later alternative -> LOW, non-fatal unless --strict ----------
new_fixture "$T"
sed -i.bak "s|jq -r '.alpha'|jq -r '.alpha // .alfa // \"\"'|" "$T/scripts/reader.sh"
run "$T"
RC_LOOSE="$RC"; OUT_LOOSE="$OUT"
run "$T" --strict
[ "$RC_LOOSE" -eq 0 ] && [ "$RC" -eq 1 ] && echo "$OUT_LOOSE" | grep -q "^LOW" \
	&& ok "A4 dead fallback -> LOW: exit 0 normally, exit 1 under --strict" \
	|| bad "A4 dead fallback (loose=$RC_LOOSE strict=$RC): $OUT_LOOSE"

# ---- A5: JS await-fetch reader, guarded unknown prop -> CRITICAL -----------
new_fixture "$T"
sed -i.bak 's|(data\.alpha |(data.alfa |' "$T/public/assets/app.js"
run "$T"
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q "\[js\]" && echo "$OUT" | grep -q "\.alfa" \
	&& ok "A5 JS await-fetch guarded unknown prop -> flagged" \
	|| bad "A5 JS await-fetch (rc=$RC): $OUT"

# ---- A6: JS callback passed BY NAME is followed into its function ----------
new_fixture "$T"
sed -i.bak 's|return it\.gamma;|return it.gama;|' "$T/public/assets/app.js"
run "$T"
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q "\.gama" \
	&& ok "A6 JS named-callback body analyzed (list.map(render))" \
	|| bad "A6 JS named callback (rc=$RC): $OUT"

# ---- A7: --slurpfile scoping attributes reads to the SLURPED artifact ------
# `.odi` is a real key of thing.json but NOT of other.json. Charged to the
# main operand it would be excused; scoped correctly it must be reported.
new_fixture "$T"
cat >> "$T/scripts/reader.sh" <<'EOF'
OTHER="${ROOT}/public/api/other.json"
B="$(jq -c --slurpfile o "$OTHER" '[ $o[0].items[]? | select(.odi == "x") ]' "$THING")"
EOF
run "$T"
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q "artifact : other.json" && echo "$OUT" | grep -q "\.odi" \
	&& ok "A7 --slurpfile read scoped to the slurped artifact, not the operand" \
	|| bad "A7 slurpfile scoping (rc=$RC): $OUT"

# ---- A8: waivers ------------------------------------------------------------
new_fixture "$T"
sed -i.bak "s|jq -r '.alpha'|jq -r '.alfa'|" "$T/scripts/reader.sh"
mkdir -p "$T/tests/field-contracts"
echo 'thing.json alfa  # test waiver: intentional' > "$T/tests/field-contracts/waivers.txt"
run "$T" --strict
[ "$RC" -eq 0 ] \
	&& ok "A8a justified waiver suppresses the finding" \
	|| bad "A8a justified waiver (rc=$RC): $OUT"

echo 'thing.json alfa' > "$T/tests/field-contracts/waivers.txt"
run "$T"
[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "without a \`# justification\`" \
	&& ok "A8b unjustified waiver is itself an error (exit 2)" \
	|| bad "A8b unjustified waiver (rc=$RC): $OUT"

# ---- A9: comments naming a field must not be parsed as reads ---------------
new_fixture "$T"
printf '# a .alfa fallback used to live here\n' >> "$T/scripts/reader.sh"
printf '\n// note: data.alfa was removed 2026-08-06\n' >> "$T/public/assets/app.js"
printf '\n/* block comment: inc.alfa is gone */\n' >> "$T/public/assets/app.js"
run "$T" --strict
[ "$RC" -eq 0 ] \
	&& ok "A9 field names inside comments are not treated as reads" \
	|| bad "A9 comment handling (rc=$RC): $OUT"

# ---- A10: --json is machine-readable ---------------------------------------
new_fixture "$T"
sed -i.bak "s|jq -r '.alpha'|jq -r '.alfa'|" "$T/scripts/reader.sh"
run "$T" --json
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["counts"]["HIGH"]>=1 and d["findings"][0]["key"]=="alfa" else 1)' \
	&& ok "A10 --json emits parseable findings with counts" \
	|| bad "A10 --json output: $OUT"

# ---------------------------------------------------------------------------
# B. Mutation tests against a copy of THIS repo
# ---------------------------------------------------------------------------
MIRROR="$BASE/mirror"
mkdir -p "$MIRROR/public"
cp -R "${REPO_ROOT}/scripts" "$MIRROR/scripts"
cp -R "${REPO_ROOT}/public/api" "$MIRROR/public/api"
mkdir -p "$MIRROR/public/assets"
# .js only, and never the vendored bundles (huge, and not our contract).
find "${REPO_ROOT}/public/assets" -maxdepth 1 -name '*.js' ! -name '*.min.js' \
	-exec cp {} "$MIRROR/public/assets/" \;
if [ -d "${REPO_ROOT}/public/ops" ]; then
	mkdir -p "$MIRROR/public/ops"
	find "${REPO_ROOT}/public/ops" -maxdepth 1 -name '*.js' \
		-exec cp {} "$MIRROR/public/ops/" \;
fi

restore_mirror() {
	cp "${REPO_ROOT}/scripts/gen-anchor-source.sh" "$MIRROR/scripts/gen-anchor-source.sh"
	cp "${REPO_ROOT}/scripts/gen-cycle-history.sh" "$MIRROR/scripts/gen-cycle-history.sh"
	cp "${REPO_ROOT}/public/assets/incidents.js"   "$MIRROR/public/assets/incidents.js"
}

# ---- B1: the repo as it stands is clean ------------------------------------
run "$MIRROR" --strict
[ "$RC" -eq 0 ] \
	&& ok "B1 repo mirror is clean under --strict" \
	|| bad "B1 repo mirror not clean (rc=$RC): $OUT"

# ---- B2: reintroduce the exact 2026-08-04 anchor-history bug ---------------
restore_mirror
sed -i.bak "s|'\.dag_root_hash // \"\"'|'.dag_root // .dag_root_computed // \"\"'|" \
	"$MIRROR/scripts/gen-anchor-source.sh"
if ! grep -q "dag_root //" "$MIRROR/scripts/gen-anchor-source.sh"; then
	bad "B2 setup: could not reintroduce the 2026-08-04 read shape"
else
	run "$MIRROR"
	[ "$RC" -eq 1 ] \
		&& echo "$OUT" | grep -q "^CRITICAL" \
		&& echo "$OUT" | grep -q "artifact : anchor-history.jsonl" \
		&& echo "$OUT" | grep -q "\.dag_root " \
		&& ok "B2 the 2026-08-04 anchor-history bug is caught as CRITICAL" \
		|| bad "B2 anchor-history mutation (rc=$RC): $OUT"
fi

# ---- B3: regress today's gen-cycle-history fix -----------------------------
restore_mirror
sed -i.bak 's|\.detectionDate >= \$c\.start_iso|.date >= $c.start_iso|g' \
	"$MIRROR/scripts/gen-cycle-history.sh"
run "$MIRROR"
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q "artifact : incidents.json" \
	&& ok "B3 gen-cycle-history .detectionDate -> .date regression is caught" \
	|| bad "B3 cycle-history mutation (rc=$RC): $OUT"

# ---- B4: regress today's incidents.js fix ----------------------------------
restore_mirror
sed -i.bak 's|inc\.detectionDate|inc.date|g' "$MIRROR/public/assets/incidents.js"
run "$MIRROR"
[ "$RC" -eq 1 ] && echo "$OUT" | grep -q "\[js\]" \
	&& ok "B4 incidents.js detectionDate -> date regression is caught" \
	|| bad "B4 incidents.js mutation (rc=$RC): $OUT"

restore_mirror

# ---------------------------------------------------------------------------
echo
echo "field-contracts: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
