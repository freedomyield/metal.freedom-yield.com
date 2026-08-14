#!/usr/bin/env bash
# test-gen-identity-kind-discipline.sh — C4: scripts/operator-local/gen-identity.sh
# must never put a sha256 of a kind=stream publication into the signed manifest,
# and must pin the kinds that can actually hold a digest.
#
# CHAIN: none. gen-identity.sh has no broadcast pathway. Every case stubs `curl`
#        (zero network I/O), points REPO_ROOT at a throwaway tree so the real
#        repo's public/api/ is never written, and signs with a freshly generated
#        passphrase-free ed25519 key created outside the repo.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. No broadcast pathway is exercised.
#
# The centrepiece is the MUTATION proof (cases M1/M2): the decision must come
# from the registry's `kind`, not from a list of names baked into the script.
# Flipping api/incidents.json to kind=stream in a synthetic registry must make
# its pin DISAPPEAR, and flipping api/evidence.json to kind=static must make a
# pin APPEAR. A hardcoded allow/deny list passes neither.
#
# Usage:
#   bash tests/identity-kind-discipline/test-gen-identity-kind-discipline.sh
#
# Exit codes:
#   0  all cases PASS (or prerequisites unavailable -> graceful skip)
#   1  any case FAILED

set -u

REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_SRC}/scripts/operator-local/gen-identity.sh"
REAL_REGISTRY="${REPO_SRC}/deploy/publication.json"

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

skip_pass() {
	echo "SKIP: $1"
	echo
	echo "test-gen-identity-kind-discipline.sh summary: PASS=$PASS  FAIL=$FAIL"
	echo "RESULT: PASS"
	exit 0
}

[ -f "$SCRIPT" ]         || { echo "FATAL: gen-identity.sh not found at $SCRIPT" >&2; exit 1; }
[ -r "$REAL_REGISTRY" ]  || { echo "FATAL: registry not found at $REAL_REGISTRY" >&2; exit 1; }
command -v jq        >/dev/null 2>&1 || skip_pass "jq unavailable"
command -v ssh-keygen >/dev/null 2>&1 || skip_pass "ssh-keygen unavailable"
command -v xxd       >/dev/null 2>&1 || skip_pass "xxd unavailable (needed for the >1-leaf Merkle path)"

HN="$(hostname -s 2>/dev/null || hostname)"
case "$HN" in
	*validator*|*web*|*-prod*|*deploy*) skip_pass "production-looking host '$HN'";;
esac

WORK="$(mktemp -d -t fya-genid-kind.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

KEYDIR="$WORK/keys"; mkdir -p "$KEYDIR"
ssh-keygen -t ed25519 -N "" -C "genid-kind-test" -f "$KEYDIR/opkey" >/dev/null 2>&1 \
	|| skip_pass "ssh-keygen could not generate an ed25519 test key"

sha() {
	if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
	else sha256sum "$1" | awk '{print $1}'; fi
}

# ---- curl stub: serves $FY_STUB_DOCROOT by URL path --------------------------
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

# ---- fixture docroot: the full real leaf catalog + the archive record --------
# The archive record is content-addressed. gen-identity.sh RE-DERIVES the three
# branch roots from the fetched bytes (jq -cS canonical form incl. jq's
# trailing 0x0a, folded as hex-ASCII concatenation — docs/MERKLE_DAG_SPEC.md
# §2.1/§3/§4) and requires that they address the filename, AND that the file's
# own .dag_root_computed agrees with that derivation. So the fixture cannot be
# a hand-picked constant; it has to be built the way a real anchor-source is.
ARCHIVE_BRANCHES='{"identity_branch":{"k":"id"},"observations_branch":{"cycle_number_observed":4},"artifacts_branch":{"public_api_files_hashed":[]}}'

sha_stdin() {
	if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
	else sha256sum | awk '{print $1}'; fi
}

# derive_dag_root <file> -> the 64-hex root the published verifier recipe gives
derive_dag_root() {
	local f="$1" i o a
	i="$(jq -cS '.identity_branch'     "$f" | sha_stdin)"
	o="$(jq -cS '.observations_branch' "$f" | sha_stdin)"
	a="$(jq -cS '.artifacts_branch'    "$f" | sha_stdin)"
	printf '%s%s%s' "$i" "$o" "$a" | sha_stdin
}

# write_archive <archive-dir> <declared_root|AUTO> <filename_root|AUTO>
# AUTO = the honestly derived root. Passing anything else is a deliberate lie,
# used by M4/M5 below to prove each half of the check independently.
ARCHIVE_ROOT=""
write_archive() {
	local dir="$1" declared="$2" fname="$3" tmp real
	tmp="$(mktemp -t arcbody.XXXXXX)"
	printf '%s' "$ARCHIVE_BRANCHES" \
		| jq '. + {schema_version:1, computed_at:"2026-08-14T00:00:00Z"}' > "$tmp"
	real="$(derive_dag_root "$tmp")"
	[ "$declared" = "AUTO" ] && declared="$real"
	[ "$fname" = "AUTO" ] && fname="$real"
	jq --arg d "$declared" '. + {dag_root_computed:$d}' "$tmp" > "${dir}/anchor-source-${fname}.json"
	rm -f "$tmp"
	ARCHIVE_ROOT="$fname"
}

build_docroot() {
	# $1 = docroot path. Rebuilt per case so mutations do not leak.
	local d="$1"
	rm -rf "$d"; mkdir -p "$d/api/archive"
	printf '{"evidence":1}\n'  > "$d/api/evidence.json"
	printf '{"validator":1}\n' > "$d/api/validator.json"
	printf '{"cycle_n":1}\n'   > "$d/api/cycle-history.jsonl"
	printf '{"uptime":1}\n'    > "$d/api/uptime-cycles.json"
	printf '{"incidents":[]}\n'> "$d/api/incidents.json"
	local s
	for s in evidence validator cycle-history incidents; do
		printf '{"schema":"%s"}\n' "$s" > "$d/api/${s}.schema.v1.json"
	done
	write_archive "$d/api/archive" AUTO AUTO
	printf '{"cycle_n":1,"dag_root_hash":"%s","archived_source_path":"api/archive/anchor-source-%s.json"}\n' \
		"$ARCHIVE_ROOT" "$ARCHIVE_ROOT" > "$d/api/anchor-history.jsonl"
}

# run_genid <docroot> <registry> -> writes identity.json into $WORK/out/public/api
# Callers use `OUT="$(run_genid ...)"; RC=$?` — the function body runs in a
# command-substitution subshell, so it must not be relied on to export state.
# OUT_JSON is therefore a fixed path computed here in the parent, not inside.
OUT_JSON="$WORK/out/public/api/identity.json"
RC=0
run_genid() {
	local docroot="$1" registry="$2" out="$WORK/out"
	rm -rf "$out"; mkdir -p "$out/public/api"
	env \
		PATH="${STUBBIN}:${PATH}" \
		FY_STUB_DOCROOT="$docroot" \
		FY_PUBLICATION_REGISTRY="$registry" \
		REPO_ROOT="$out" \
		ARTIFACT_BASE="http://stub-host" \
		OPERATOR_IDENTITY_KEY="${KEYDIR}/opkey" \
		bash "$SCRIPT" 2>&1
}

has_sha()   { [ "$(jq -r --arg k "$1" '.artifact_manifest[$k].sha256 // "ABSENT"' "$OUT_JSON")" != "ABSENT" ]; }
kind_of()   { jq -r --arg k "$1" '.artifact_manifest[$k].kind // "ABSENT"' "$OUT_JSON"; }
listed()    { [ "$(jq -r --arg k "$1" '.artifact_manifest | has($k)' "$OUT_JSON")" = "true" ]; }

DOC="$WORK/docroot"

# =============================================================================
# Case 1 — the real registry: no kind=stream publication is pinned
# =============================================================================
build_docroot "$DOC"
OUT="$(run_genid "$DOC" "$REAL_REGISTRY")"; RC=$?
if [ "$RC" -eq 0 ]; then pass "c1 real registry: full catalog live -> exit 0"; else fail "c1 expected exit 0, got $RC: $(echo "$OUT" | tail -3 | tr '\n' '|')"; fi

if [ -f "$OUT_JSON" ]; then
	STREAM_PINS="$(jq -r '[.artifact_manifest | to_entries[] | select(.value.kind == "stream" and (.value | has("sha256"))) | .key] | join(",")' "$OUT_JSON")"
	[ -z "$STREAM_PINS" ] \
		&& pass "c1 ACCEPTANCE: no kind=stream entry carries a sha256" \
		|| fail "c1 ACCEPTANCE: kind=stream entries were pinned: ${STREAM_PINS}"

	for k in evidence_json validator_json cycle_history_jsonl uptime_cycles_json; do
		if listed "$k" && [ "$(kind_of "$k")" = "stream" ] && ! has_sha "$k"; then
			pass "c1 ${k}: listed as kind=stream with no sha256"
		else
			fail "c1 ${k}: expected listed+stream+unpinned, got kind=$(kind_of "$k") sha=$(jq -r --arg k "$k" '.artifact_manifest[$k].sha256 // "ABSENT"' "$OUT_JSON")"
		fi
	done

	if [ "$(kind_of incidents_json)" = "static" ] && has_sha incidents_json; then
		pass "c1 incidents_json: kind=static and PINNED (a real pin is still taken)"
	else
		fail "c1 incidents_json: expected static+pinned, got kind=$(kind_of incidents_json)"
	fi

	# Schema pins survive on stream payloads: the schema is its own publication.
	if [ "$(jq -r '.artifact_manifest.evidence_json.schema_sha256 // "ABSENT"' "$OUT_JSON")" != "ABSENT" ]; then
		pass "c1 evidence_json: schema_sha256 kept (static schema on a stream payload)"
	else
		fail "c1 evidence_json: schema_sha256 was dropped along with the payload pin"
	fi

	if [ "$(jq -r '.pin_policy.rule // ""' "$OUT_JSON")" != "" ]; then
		pass "c1 pin_policy is emitted in-band so the omission is self-describing"
	else
		fail "c1 pin_policy missing from the manifest"
	fi
else
	fail "c1 no identity.json produced"
fi

# =============================================================================
# Case 2 — the record leaf: content-addressed archive IS pinned
# =============================================================================
if [ -f "$OUT_JSON" ]; then
	if [ "$(kind_of anchor_source_archive_json)" = "record" ] && has_sha anchor_source_archive_json; then
		pass "c2 anchor_source_archive_json: kind=record and PINNED"
	else
		fail "c2 anchor_source_archive_json: expected record+pinned, got kind=$(kind_of anchor_source_archive_json)"
	fi
	ARCU="$(jq -r '.artifact_manifest.anchor_source_archive_json.url // ""' "$OUT_JSON")"
	case "$ARCU" in
		*"/api/archive/anchor-source-${ARCHIVE_ROOT}.json") pass "c2 record URL is the content-addressed archive URL" ;;
		*) fail "c2 record URL unexpected: ${ARCU}" ;;
	esac
	EXPECT_SHA="$(sha "$DOC/api/archive/anchor-source-${ARCHIVE_ROOT}.json")"
	[ "$(jq -r '.artifact_manifest.anchor_source_archive_json.sha256' "$OUT_JSON")" = "$EXPECT_SHA" ] \
		&& pass "c2 record pin equals the archive file's real sha256" \
		|| fail "c2 record pin does not match the archive file's sha256"
fi

# =============================================================================
# Case 3 — artifact_root is the Merkle root over exactly the PINNED digests
# =============================================================================
if [ -f "$OUT_JSON" ]; then
	LEAVES="$(jq -r '.artifact_manifest | to_entries | sort_by(.key)[] | select(.value | has("sha256")) | .value.sha256' "$OUT_JSON")"
	N="$(printf '%s\n' "$LEAVES" | grep -c .)"
	if [ "$N" -eq 2 ]; then
		L1="$(printf '%s\n' "$LEAVES" | sed -n 1p)"
		L2="$(printf '%s\n' "$LEAVES" | sed -n 2p)"
		EXPECT_ROOT="$( { printf '%s' "$L1" | xxd -r -p; printf '%s' "$L2" | xxd -r -p; } | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } | awk '{print $1}')"
		[ "$EXPECT_ROOT" = "$(jq -r .artifact_root "$OUT_JSON")" ] \
			&& pass "c3 artifact_root == SHA-256(raw(leaf1)||raw(leaf2)) over the 2 pinned digests" \
			|| fail "c3 artifact_root mismatch: expected ${EXPECT_ROOT}, got $(jq -r .artifact_root "$OUT_JSON")"
	else
		fail "c3 expected exactly 2 pinned digests, found ${N}"
	fi
fi

# =============================================================================
# Case 4 — signing + self-verification still work on the new shape
# =============================================================================
if [ -f "$OUT_JSON" ] && [ -f "${OUT_JSON}.sig" ]; then
	ALLOWED="$WORK/allowed_signers"
	printf 'freedom-yield %s\n' "$(cat "${KEYDIR}/opkey.pub")" > "$ALLOWED"
	if ssh-keygen -Y verify -f "$ALLOWED" -I freedom-yield \
		-n freedom-yield/validator-identity -s "${OUT_JSON}.sig" < "$OUT_JSON" >/dev/null 2>&1; then
		pass "c4 ssh-keygen -Y verify accepts the produced manifest (sign path unchanged)"
	else
		fail "c4 ssh-keygen -Y verify rejected the produced manifest"
	fi
else
	fail "c4 no manifest/signature pair produced"
fi

# =============================================================================
# MUTATION M1 — flip a STATIC path to stream in the registry: its pin must go
# =============================================================================
MUT="$WORK/registry-mut.json"
jq '(.publications[] | select(.path == "api/incidents.json") | .kind) = "stream"' "$REAL_REGISTRY" > "$MUT"
build_docroot "$DOC"
OUT="$(run_genid "$DOC" "$MUT")"; RC=$?
if [ -f "$OUT_JSON" ] && [ "$RC" -eq 0 ]; then
	if [ "$(kind_of incidents_json)" = "stream" ] && ! has_sha incidents_json; then
		pass "M1 MUTATION: api/incidents.json flipped to stream -> its sha256 disappears"
	else
		fail "M1 MUTATION: incidents_json still pinned after the flip (kind=$(kind_of incidents_json)) — the script is not reading kind"
	fi
	NP="$(jq -r '[.artifact_manifest[] | select(has("sha256"))] | length' "$OUT_JSON")"
	[ "$NP" -eq 1 ] \
		&& pass "M1 MUTATION: pinned count drops 2 -> 1 and artifact_root follows" \
		|| fail "M1 MUTATION: expected 1 pinned digest after the flip, got ${NP}"
else
	fail "M1 MUTATION: run failed (rc=$RC): $(echo "$OUT" | tail -3 | tr '\n' '|')"
fi

# =============================================================================
# MUTATION M2 — flip a STREAM path to static: a pin must APPEAR
# A deny-list implementation passes M1 and fails here.
# =============================================================================
jq '(.publications[] | select(.path == "api/evidence.json") | .kind) = "static"' "$REAL_REGISTRY" > "$MUT"
build_docroot "$DOC"
OUT="$(run_genid "$DOC" "$MUT")"; RC=$?
if [ -f "$OUT_JSON" ] && [ "$RC" -eq 0 ]; then
	if [ "$(kind_of evidence_json)" = "static" ] && has_sha evidence_json; then
		pass "M2 MUTATION: api/evidence.json flipped to static -> a sha256 APPEARS"
	else
		fail "M2 MUTATION: evidence_json still unpinned after the flip (kind=$(kind_of evidence_json)) — the exclusion is hardcoded, not registry-driven"
	fi
else
	fail "M2 MUTATION: run failed (rc=$RC): $(echo "$OUT" | tail -3 | tr '\n' '|')"
fi

# =============================================================================
# MUTATION M3 — a directory kind may not be claimed by a non-matching member.
# api/archive/ is kind=record ONLY for members matching its 64-hex
# member_pattern. Rename the archive to a date key and the pin must vanish.
# =============================================================================
build_docroot "$DOC"
mv "$DOC/api/archive/anchor-source-${ARCHIVE_ROOT}.json" "$DOC/api/archive/anchor-source-2026-08-14.json"
printf '{"cycle_n":1,"archived_source_path":"api/archive/anchor-source-2026-08-14.json"}\n' > "$DOC/api/anchor-history.jsonl"
OUT="$(run_genid "$DOC" "$REAL_REGISTRY")"; RC=$?
if [ -f "$OUT_JSON" ]; then
	listed anchor_source_archive_json \
		&& fail "M3 MUTATION: a date-keyed archive member was pinned as a record" \
		|| pass "M3 MUTATION: date-keyed archive member is not pinned (member_pattern governs the kind)"
	echo "$OUT" | grep -q 'skip anchor_source_archive_json' \
		&& pass "M3 MUTATION: the skip is printed with a reason, not silent" \
		|| fail "M3 MUTATION: no skip line for the rejected archive member"
else
	fail "M3 MUTATION: run produced no manifest (rc=$RC)"
fi

# =============================================================================
# MUTATION M4 — an archive whose BRANCHES do not fold to its filename must not
# be accepted as a record, even when the file's own dag_root_computed says they
# do. This is the load-bearing case: the check re-derives the three branch
# roots instead of reading .dag_root_computed, so a file that merely CLAIMS to
# address itself is refused. A declaration-trusting implementation passes every
# other case in this suite and fails only here.
# =============================================================================
build_docroot "$DOC"
LIAR="00000000000000000000000000000000000000000000000000000000deadbeef"
rm -f "$DOC/api/archive/"anchor-source-*.json
write_archive "$DOC/api/archive" "$LIAR" "$LIAR"      # declared == filename, branches disagree
printf '{"cycle_n":1,"archived_source_path":"api/archive/anchor-source-%s.json"}\n' "$LIAR" \
	> "$DOC/api/anchor-history.jsonl"
OUT="$(run_genid "$DOC" "$REAL_REGISTRY")"; RC=$?
if [ -f "$OUT_JSON" ]; then
	listed anchor_source_archive_json \
		&& fail "M4 MUTATION: an archive whose branches do not fold to its name was pinned (declared value trusted)" \
		|| pass "M4 MUTATION: self-consistent LIE refused — the root is re-derived, not read"
	echo "$OUT" | grep -q 're-derived DAG root does not address the file name' \
		&& pass "M4 MUTATION: refusal names the re-derivation, not the declared field" \
		|| fail "M4 MUTATION: refusal reason not printed: $(echo "$OUT" | grep skip | head -2 | tr '\n' '|')"
else
	fail "M4 MUTATION: run produced no manifest (rc=$RC)"
fi

# =============================================================================
# MUTATION M5 — the other half: branches fold to the filename correctly, but
# the file's declared dag_root_computed disagrees with them. The two must be
# checked independently, so this is also a refusal.
# =============================================================================
build_docroot "$DOC"
rm -f "$DOC/api/archive/"anchor-source-*.json
write_archive "$DOC/api/archive" "$LIAR" AUTO         # filename honest, declared field lies
printf '{"cycle_n":1,"archived_source_path":"api/archive/anchor-source-%s.json"}\n' "$ARCHIVE_ROOT" \
	> "$DOC/api/anchor-history.jsonl"
OUT="$(run_genid "$DOC" "$REAL_REGISTRY")"; RC=$?
if [ -f "$OUT_JSON" ]; then
	listed anchor_source_archive_json \
		&& fail "M5 MUTATION: an archive whose declared dag_root_computed disagrees with its branches was pinned" \
		|| pass "M5 MUTATION: declared root disagreeing with the re-derived root is refused"
	echo "$OUT" | grep -q 'disagrees with the re-derived root' \
		&& pass "M5 MUTATION: refusal names the declared/derived disagreement" \
		|| fail "M5 MUTATION: refusal reason not printed"
else
	fail "M5 MUTATION: run produced no manifest (rc=$RC)"
fi

# =============================================================================
# Case 5 — fail-closed: registry missing -> exit 9, nothing written
# =============================================================================
build_docroot "$DOC"
OUT="$(run_genid "$DOC" "$WORK/no-such-registry.json")"; RC=$?
[ "$RC" -eq 9 ] \
	&& pass "c5 registry missing -> exit 9 (fail-closed, does not guess)" \
	|| fail "c5 registry missing: expected exit 9, got $RC"
[ -f "$OUT_JSON" ] \
	&& fail "c5 registry missing: a manifest was written anyway" \
	|| pass "c5 registry missing: no manifest written"

# =============================================================================
# Case 6 — fail-closed: a catalog artifact with no registry row -> exit 9
# =============================================================================
jq 'del(.publications[] | select(.path == "api/incidents.json"))' "$REAL_REGISTRY" > "$MUT"
build_docroot "$DOC"
OUT="$(run_genid "$DOC" "$MUT")"; RC=$?
[ "$RC" -eq 9 ] \
	&& pass "c6 undeclared artifact -> exit 9 (unknown kind is never 'probably fine')" \
	|| fail "c6 undeclared artifact: expected exit 9, got $RC"
echo "$OUT" | grep -qF "'api/incidents.json' has no row in" \
	&& pass "c6 the error names the undeclared path" \
	|| fail "c6 error message did not name the undeclared path: $(echo "$OUT" | tail -6 | tr '\n' '|')"

# =============================================================================
# Case 7 — fail-closed: live artifacts but none pinnable -> exit 10
# =============================================================================
build_docroot "$DOC"
rm -f "$DOC/api/incidents.json" "$DOC/api/anchor-history.jsonl"
OUT="$(run_genid "$DOC" "$REAL_REGISTRY")"; RC=$?
[ "$RC" -eq 10 ] \
	&& pass "c7 all-stream artifact set -> exit 10 (artifact_root would commit to nothing)" \
	|| fail "c7 all-stream artifact set: expected exit 10, got $RC"
[ -f "$OUT_JSON" ] \
	&& fail "c7 a manifest pinning nothing was written" \
	|| pass "c7 no manifest written when nothing is pinnable"

# =============================================================================
# Case 8 — REAL registry drift guard: every URL in the shipped LEAF_CATALOG
# must resolve to a row in the shipped deploy/publication.json. This is what
# keeps case 6's exit 9 from first appearing on a transition day.
# =============================================================================
# Only the URLs the script actually composes — anchored on ${ARTIFACT_BASE} so
# that paths merely MENTIONED in comments cannot make this assertion pass or
# fail for the wrong reason.
CATALOG_PATHS="$(grep -oE '\$\{ARTIFACT_BASE\}/api/[A-Za-z0-9._-]+' "$SCRIPT" \
	| sed 's|^.*}/||' | sort -u)"
MISSING=""
for p in $CATALOG_PATHS; do
	case "$p" in
		api/archive/*) continue ;;   # covered by the directory row + member_pattern
	esac
	k="$(jq -r --arg p "$p" '[.publications[] | select(.path == $p) | .kind] | first // ""' "$REAL_REGISTRY")"
	[ -n "$k" ] || MISSING="${MISSING} ${p}"
done
[ -z "$MISSING" ] \
	&& pass "c8 every api/* path named by gen-identity.sh has a row in deploy/publication.json" \
	|| fail "c8 paths named by gen-identity.sh with no registry row:${MISSING}"

# The four leaves the spec names must still be kind=stream in the real registry;
# if one is ever reclassified, this suite's premise changed and must be re-read.
for p in api/evidence.json api/validator.json api/cycle-history.jsonl api/uptime-cycles.json; do
	k="$(jq -r --arg p "$p" '[.publications[] | select(.path == $p) | .kind] | first // ""' "$REAL_REGISTRY")"
	[ "$k" = "stream" ] \
		&& pass "c8 ${p} is still kind=stream in the shipped registry" \
		|| fail "c8 ${p} is kind=${k:-<none>}, not stream — premise changed"
done

echo
echo "----------------------------------------"
echo "test-gen-identity-kind-discipline.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "RESULT: FAIL"
	exit 1
fi
echo "RESULT: PASS"
exit 0
