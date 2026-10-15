#!/usr/bin/env bash
# test-gen-identity-pq.sh — scripts/operator-local/gen-identity.sh signs
# identity.json with ML-DSA-65 (FIPS 204) as well as ed25519 (schema v2),
# publishes nothing unless BOTH signatures self-verify, and deletes the
# unlocked ML-DSA key on every exit path once it has resolved its path.
# Spec: docs/superpowers/specs/2026-10-15-identity-pq-signature-design.md.
#
# CHAIN: none. gen-identity.sh has no broadcast pathway. `curl` is stubbed
#        (zero network I/O), REPO_ROOT is a throwaway tree, and every key
#        (ed25519 and ML-DSA) is generated into mktemp -d at run time.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No broadcast pathway is exercised.
#
# Cases:
#   P1  normal run: exit 0, schema_version 2, verification_pq right after
#       verification, fingerprint = the committed .pub, PQ sig verifies,
#       ed25519 sig still verifies
#   P2  the unlocked key is already gone when the self-verify runs (auto-lock
#       right after signing) and after P1 exits
#   R1  second run without re-unlocking -> exit 5, names pq-identity-unlock.sh,
#       nothing written
#   R2  stale unlocked key -> exit 5 and the stale file is deleted
#   R3  committed .pub swapped for another key -> exit 11, nothing published,
#       unlocked file deleted
#   P3  FY_OPENSSL unusable -> exit 5, unlocked file deleted
#   P4  early non-PQ failure (exit 7) still deletes the unlocked file
#   P5  a generator whose context string is wrong produces a sig the real
#       context rejects (the published sig is bound to the real context)
#   P6  identity.json validates against identity.schema.v2.json
#   P7  the run's output never echoes private key material
#
# Usage:
#   bash tests/gen-identity-pq/test-gen-identity-pq.sh
#
# Exit codes:
#   0  all cases PASS (or prerequisites unavailable -> graceful skip)
#   1  any case FAILED

set -u

REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_SRC}/scripts/operator-local/gen-identity.sh"
SCHEMA_V2="${REPO_SRC}/public/api/identity.schema.v2.json"

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

skip_pass() {
	echo "SKIP: $1"
	echo
	echo "test-gen-identity-pq.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: PASS"
	exit 0
}

[ -f "$SCRIPT" ] || { echo "FATAL: gen-identity.sh not found at $SCRIPT" >&2; exit 1; }
# shellcheck source=../lib/pq-test-key.sh
. "${REPO_SRC}/tests/lib/pq-test-key.sh"

command -v jq         >/dev/null 2>&1 || skip_pass "jq unavailable"
command -v ssh-keygen >/dev/null 2>&1 || skip_pass "ssh-keygen unavailable"
command -v xxd        >/dev/null 2>&1 || skip_pass "xxd unavailable (needed for the >1-leaf Merkle path)"
fy_pq_prereq_or_skip skip_pass
OSSL="$(fyipq__resolve_openssl)"

HN="$(hostname -s 2>/dev/null || hostname)"
case "$HN" in
	*validator*|*web*|*-prod*|*deploy*) skip_pass "production-looking host '$HN'";;
esac

WORK="$(mktemp -d -t fya-genid-pq.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

KEYDIR="$WORK/keys"; mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
ssh-keygen -t ed25519 -N "" -C "genid-pq-test" -f "$KEYDIR/opkey" >/dev/null 2>&1 \
	|| skip_pass "ssh-keygen could not generate an ed25519 test key"
fy_pq_make_master "$KEYDIR" || { echo "FATAL: could not generate an ML-DSA test key" >&2; exit 1; }
UNLOCKED="$KEYDIR/${FYIPQ_UNLOCKED_BASENAME}"

# A second, unrelated ML-DSA key (R3: the committed .pub swapped under us).
OTHERDIR="$WORK/other"; mkdir -p "$OTHERDIR"
fy_pq_make_master "$OTHERDIR" || { echo "FATAL: could not generate the second ML-DSA key" >&2; exit 1; }

# ---- curl stub (same as tests/test-gen-identity-ordering-guard.sh) ----------
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

# ssh-keygen probe shim (P2): the ed25519 self-verify (`ssh-keygen -Y verify`)
# runs AFTER the ML-DSA signing step, so recording whether the unlocked key
# still exists at that moment shows the auto-lock happened right after
# signing — not merely in the EXIT trap at the very end.
REAL_SSH_KEYGEN="$(command -v ssh-keygen)"
cat > "$STUBBIN/ssh-keygen" <<SHIM
#!/usr/bin/env bash
case " \$* " in *" verify "*)
	if [ -n "\${FY_PROBE_OUT:-}" ]; then
		if [ -e "\${FY_PROBE_UNLOCKED:-/nonexistent}" ]; then echo present; else echo absent; fi > "\$FY_PROBE_OUT"
	fi ;;
esac
exec "${REAL_SSH_KEYGEN}" "\$@"
SHIM
chmod +x "$STUBBIN/ssh-keygen"

# One stream leaf + one static (pinnable) leaf; cycle ledger at cycle_n 1.
DOCROOT="$WORK/docroot"; mkdir -p "$DOCROOT/api"
printf '{"ok":true}\n'      > "$DOCROOT/api/evidence.json"
printf '{"incidents":[]}\n' > "$DOCROOT/api/incidents.json"
printf '{"cycle_n":1}\n'    > "$DOCROOT/api/cycle-history.jsonl"

# new_repo <name> -> prints a fresh fake REPO_ROOT path
new_repo() {
	local r="$WORK/repo-$1"
	rm -rf "$r"; mkdir -p "$r/public/api"
	printf '%s' "$r"
}

# run_genid <fake_repo> <stdout_file> <stderr_file> [VAR=value ...]
# Uses $GENID_SCRIPT when set (P5 runs a patched copy). Returns the exit code.
run_genid() {
	local repo="$1" so="$2" se="$3"
	shift 3
	env \
		PATH="${STUBBIN}:${PATH}" \
		FY_STUB_DOCROOT="$DOCROOT" \
		REPO_ROOT="$repo" \
		ARTIFACT_BASE="http://stub-host" \
		OPERATOR_IDENTITY_KEY="${KEYDIR}/opkey" \
		OPERATOR_PQ_UNLOCKED_KEY="$UNLOCKED" \
		"$@" \
		bash "${GENID_SCRIPT:-$SCRIPT}" >"$so" 2>"$se"
}

ALLOWED="$WORK/allowed_signers"
printf 'freedom-yield %s\n' "$(cat "${KEYDIR}/opkey.pub")" > "$ALLOWED"

# ajv_validate — the same call tests/anchor-history/test-ten-mandatory.sh T4
# uses. The caller checks AJV_INVOKE first and reports SKIP when it is empty.
AJV_INVOKE=()
if command -v ajv >/dev/null 2>&1; then
	AJV_INVOKE=(ajv)
elif command -v npx >/dev/null 2>&1; then
	AJV_INVOKE=(npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv)
fi
ajv_validate() {
	"${AJV_INVOKE[@]}" validate --strict=false -s "$1" -d "$2" \
		--spec=draft2020 -c ajv-formats >/dev/null 2>&1
}

# =============================================================================
# P1 — normal run
# =============================================================================
R_P1="$(new_repo p1)"
fy_pq_install "$KEYDIR" "$R_P1"
run_genid "$R_P1" "$WORK/p1.out" "$WORK/p1.err" \
	FY_PROBE_OUT="$WORK/p1.probe" FY_PROBE_UNLOCKED="$UNLOCKED"; RC=$?
J="$R_P1/public/api/identity.json"
PQSIG="$R_P1/${FYIPQ_SIG_REL}"
PUB="$R_P1/${FYIPQ_PUB_REL}"
if [ "$RC" -eq 0 ]; then pass "P1 normal run exits 0"; else fail "P1 expected exit 0, got $RC: $(tail -5 "$WORK/p1.err" | tr '\n' '|')"; fi

if [ -f "$J" ]; then
	[ "$(jq -r '.schema_version' "$J")" = "2" ] \
		&& pass "P1 identity.json has schema_version 2" \
		|| fail "P1 schema_version is $(jq -r '.schema_version' "$J"), expected 2"

	POS="$(jq -r 'keys_unsorted | (index("verification_pq") - index("verification"))' "$J" 2>/dev/null)"
	[ "$POS" = "1" ] \
		&& pass "P1 verification_pq sits immediately after verification" \
		|| fail "P1 verification_pq is not immediately after verification (offset ${POS:-none})"

	FP_WANT="$(fyipq__pub_fingerprint "$PUB")"
	FP_GOT="$(jq -r '.verification_pq.pubkey_fingerprint // ""' "$J")"
	[ -n "$FP_WANT" ] && [ "$FP_GOT" = "$FP_WANT" ] \
		&& pass "P1 verification_pq.pubkey_fingerprint == fingerprint of the committed .pub" \
		|| fail "P1 fingerprint mismatch: manifest '${FP_GOT}' vs .pub '${FP_WANT}'"

	VPQ_OK=1
	for pair in "algorithm|${FYIPQ_ALGORITHM}" "standard|${FYIPQ_STANDARD}" \
	            "context_string|${FYIPQ_CONTEXT}" "pubkey_url|${FYIPQ_PUB_URL}" \
	            "signature_url|${FYIPQ_SIG_URL}" "minimum_openssl_version|${FYIPQ_MIN_OPENSSL}"; do
		k="${pair%%|*}"; v="${pair#*|}"
		[ "$(jq -r --arg k "$k" '.verification_pq[$k] // ""' "$J")" = "$v" ] || { VPQ_OK=0; fail "P1 verification_pq.${k} != '${v}'"; }
	done
	METHOD="$(jq -r '.verification_pq.method // ""' "$J")"
	case "$METHOD" in
		*"-pkeyopt context-string:${FYIPQ_CONTEXT}") ;;
		*) VPQ_OK=0; fail "P1 verification_pq.method does not end with the context string: ${METHOD}" ;;
	esac
	[ "$VPQ_OK" -eq 1 ] && pass "P1 verification_pq fields equal the library constants"

	if [ -f "$PQSIG" ] && fyipq__verify "$OSSL" "$PUB" "$J" "$PQSIG"; then
		pass "P1 the ML-DSA-65 signature verifies against the committed .pub"
	else
		fail "P1 the ML-DSA-65 signature is missing or does not verify"
	fi

	if ssh-keygen -Y verify -f "$ALLOWED" -I freedom-yield \
		-n freedom-yield/validator-identity -s "${J}.sig" < "$J" >/dev/null 2>&1; then
		pass "P1 the ed25519 signature still verifies"
	else
		fail "P1 the ed25519 signature does not verify"
	fi
else
	fail "P1 no identity.json produced"
fi

# =============================================================================
# P2 — auto-lock on success
# =============================================================================
[ "$(cat "$WORK/p1.probe" 2>/dev/null)" = "absent" ] \
	&& pass "P2 the unlocked ML-DSA key is already gone when the self-verify runs (dropped right after signing)" \
	|| fail "P2 MUTATION NOT CAUGHT: the unlocked ML-DSA key still existed after signing (probe: $(cat "$WORK/p1.probe" 2>/dev/null || echo none))"
[ ! -e "$UNLOCKED" ] \
	&& pass "P2 after a successful run the unlocked ML-DSA key no longer exists" \
	|| fail "P2 MUTATION NOT CAUGHT: the unlocked ML-DSA key survived a successful run"

# =============================================================================
# P7 — no private key material in the output
# =============================================================================
SECRET_LINE="$(sed -n 2p "$KEYDIR/master.pem")"
if [ -n "$SECRET_LINE" ] && ! grep -qF -- "$SECRET_LINE" "$WORK/p1.out" "$WORK/p1.err"; then
	pass "P7 the run's stdout+stderr never contain private key material"
else
	fail "P7 private key material appeared in the run's output"
fi

# =============================================================================
# P6 — identity.json validates against identity.schema.v2.json
# =============================================================================
if [ -f "$J" ]; then
	if [ "${#AJV_INVOKE[@]}" -eq 0 ]; then
		echo "SKIP  P6 (ajv unavailable, npx unavailable)"
	elif [ ! -f "$SCHEMA_V2" ]; then
		fail "P6 public/api/identity.schema.v2.json does not exist"
	elif ajv_validate "$SCHEMA_V2" "$J"; then
		pass "P6 identity.json validates against public/api/identity.schema.v2.json"
	else
		fail "P6 identity.json does NOT validate against public/api/identity.schema.v2.json"
	fi
fi

# =============================================================================
# R1 — second run on the same day: the unlocked key is gone -> exit 5
# =============================================================================
R_R1="$(new_repo r1)"
mkdir -p "$R_R1/public/.well-known"; cp "$PUB" "$R_R1/${FYIPQ_PUB_REL}"
rm -f "$UNLOCKED"
run_genid "$R_R1" "$WORK/r1.out" "$WORK/r1.err"; RC=$?
[ "$RC" -eq 5 ] && pass "R1 second run without re-unlocking -> exit 5" || fail "R1 expected exit 5, got $RC"
grep -qF 'pq-identity-unlock.sh' "$WORK/r1.err" \
	&& pass "R1 the error tells the operator to run pq-identity-unlock.sh" \
	|| fail "R1 stderr does not name pq-identity-unlock.sh: $(tail -3 "$WORK/r1.err" | tr '\n' '|')"
[ ! -e "$R_R1/public/api/identity.json" ] \
	&& pass "R1 no identity.json written" \
	|| fail "R1 an identity.json was written without an unlocked key"

# =============================================================================
# R2 — unlocked key left over from a previous day -> exit 5 AND deleted
# =============================================================================
R_R2="$(new_repo r2)"
fy_pq_install "$KEYDIR" "$R_R2"
touch -t 202001010000 "$UNLOCKED"
run_genid "$R_R2" "$WORK/r2.out" "$WORK/r2.err"; RC=$?
[ "$RC" -eq 5 ] && pass "R2 stale unlocked key -> exit 5" || fail "R2 expected exit 5, got $RC"
[ ! -e "$UNLOCKED" ] \
	&& pass "R2 the stale unlocked key was deleted" \
	|| fail "R2 MUTATION NOT CAUGHT: the stale unlocked key was left on disk"
[ ! -e "$R_R2/public/api/identity.json" ] \
	&& pass "R2 no identity.json written" \
	|| fail "R2 an identity.json was written with a stale unlocked key"

# =============================================================================
# R3 — committed .pub swapped for another key -> exit 11, nothing published
# =============================================================================
R_R3="$(new_repo r3)"
fy_pq_install "$KEYDIR" "$R_R3"
"$OSSL" pkey -in "$OTHERDIR/master.pem" -pubout -out "$R_R3/${FYIPQ_PUB_REL}" </dev/null
run_genid "$R_R3" "$WORK/r3.out" "$WORK/r3.err"; RC=$?
[ "$RC" -eq 11 ] && pass "R3 .pub swapped -> exit 11 (PQ self-verify failed)" || fail "R3 expected exit 11, got $RC: $(tail -3 "$WORK/r3.err" | tr '\n' '|')"
R3_PUBLISHED=""
for f in identity.json identity.json.sig identity.json.mldsa65.sig; do
	[ -e "$R_R3/public/api/$f" ] && R3_PUBLISHED="${R3_PUBLISHED} $f"
done
[ -z "$R3_PUBLISHED" ] \
	&& pass "R3 nothing published (no identity.json, .sig or .mldsa65.sig)" \
	|| fail "R3 MUTATION NOT CAUGHT: published despite a failed PQ self-verify:${R3_PUBLISHED}"
[ ! -e "$UNLOCKED" ] \
	&& pass "R3 the unlocked key was deleted" \
	|| fail "R3 the unlocked key was left on disk after exit 11"

# =============================================================================
# P3 — unusable OpenSSL -> exit 5, unlocked key deleted
# =============================================================================
R_P3="$(new_repo p3)"
fy_pq_install "$KEYDIR" "$R_P3"
run_genid "$R_P3" "$WORK/p3.out" "$WORK/p3.err" FY_OPENSSL=/usr/bin/false; RC=$?
[ "$RC" -eq 5 ] && pass "P3 FY_OPENSSL=/usr/bin/false -> exit 5" || fail "P3 expected exit 5, got $RC"
grep -qF 'FY_OPENSSL' "$WORK/p3.err" \
	&& pass "P3 the error names FY_OPENSSL" \
	|| fail "P3 stderr does not name FY_OPENSSL"
[ ! -e "$UNLOCKED" ] && pass "P3 the unlocked key was deleted" || fail "P3 the unlocked key was left on disk after exit 5"

# =============================================================================
# P4 — an early NON-PQ failure (ordering guard, exit 7) still auto-locks
# =============================================================================
R_P4="$(new_repo p4)"
fy_pq_install "$KEYDIR" "$R_P4"
run_genid "$R_P4" "$WORK/p4.out" "$WORK/p4.err" FY_EXPECT_CYCLE=99; RC=$?
[ "$RC" -eq 7 ] && pass "P4 FY_EXPECT_CYCLE=99 vs ledger cycle_n 1 -> exit 7" || fail "P4 expected exit 7, got $RC"
[ ! -e "$UNLOCKED" ] \
	&& pass "P4 the unlocked key was deleted on a non-PQ failure" \
	|| fail "P4 MUTATION NOT CAUGHT: the unlocked key survived exit 7"

# =============================================================================
# P5 — the signature is bound to the real context string
# =============================================================================
SRC="$WORK/src"; mkdir -p "$SRC"
cp -R "${REPO_SRC}/scripts" "$SRC/scripts"
cp -R "${REPO_SRC}/deploy"  "$SRC/deploy"
sed 's|^FYIPQ_CONTEXT=.*$|FYIPQ_CONTEXT="other"|' "${REPO_SRC}/scripts/lib/identity-pq.sh" > "$SRC/scripts/lib/identity-pq.sh"
grep -q '^FYIPQ_CONTEXT="other"$' "$SRC/scripts/lib/identity-pq.sh" || fail "P5 setup: could not patch FYIPQ_CONTEXT in the copy"
R_P5="$(new_repo p5)"
fy_pq_install "$KEYDIR" "$R_P5"
GENID_SCRIPT="$SRC/scripts/operator-local/gen-identity.sh" \
	run_genid "$R_P5" "$WORK/p5.out" "$WORK/p5.err"; RC=$?
J5="$R_P5/public/api/identity.json"; S5="$R_P5/${FYIPQ_SIG_REL}"; P5PUB="$R_P5/${FYIPQ_PUB_REL}"
if [ "$RC" -eq 0 ] && [ -f "$S5" ]; then
	pass "P5 a generator with context 'other' runs to completion (self-verifies in its own context)"
	if ( FYIPQ_CONTEXT="other"; fyipq__verify "$OSSL" "$P5PUB" "$J5" "$S5" ); then
		pass "P5 control: that signature verifies under context 'other'"
	else
		fail "P5 control: the signature does not verify even under its own context"
	fi
	if fyipq__verify "$OSSL" "$P5PUB" "$J5" "$S5"; then
		fail "P5 MUTATION NOT CAUGHT: a signature made under context 'other' verifies under ${FYIPQ_CONTEXT}"
	else
		pass "P5 the real context (${FYIPQ_CONTEXT}) rejects it — the published sig is context-bound"
	fi
else
	fail "P5 the patched-context run failed (rc=$RC): $(tail -3 "$WORK/p5.err" | tr '\n' '|')"
fi

echo
echo "----------------------------------------"
echo "test-gen-identity-pq.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
