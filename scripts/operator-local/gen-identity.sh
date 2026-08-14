#!/usr/bin/env bash
# scripts/operator-local/gen-identity.sh
#
# Generate and sign the operator identity manifest for Freedom Yield Metal.
#
# MUST NOT BE RUN ON VALIDATOR HOST OR WEB HOST.
# This helper is for the operator's local Mac only.
# It must never read validator keys, staking keys, BLS keys, signer.key, or staker.key.
#
# Sync exclusion:
#   scripts/sync-to-validator-host.sh excludes operator-local/ so this file
#   is never shipped to the validator host or web host. Verify with --dry-run.
#
# What this helper does:
#   1. Probes each artifact URL (curl), reads its `kind` from the publication
#      registry, and computes a content sha256 ONLY for artifacts the registry
#      declares safe to pin (see "kind discipline" below).
#   2. Computes the SHA-256 Merkle root over the artifact_manifest leaves that
#      carry a sha256 (alphabetical key order, odd-duplicate, raw-bytes binary
#      tree — matches the algorithm documented in identity.schema.v1.json).
#   3. Composes identity.json with artifact_manifest + artifact_root.
#   4. Validates JSON with `jq empty`.
#   5. Signs with `ssh-keygen -Y sign` using namespace freedom-yield/validator-identity.
#   6. Self-verifies with `ssh-keygen -Y verify` before publishing.
#   7. Atomically places identity.json and identity.json.sig in public/api/.
#
# ---------------------------------------------------------------------------
# kind discipline (C4, spec docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md)
# ---------------------------------------------------------------------------
# A sha256 inside a SIGNED manifest is a claim about bytes. It can only hold
# for bytes that cannot change without a commit. deploy/publication.json is the
# single declaration of that property:
#
#   kind=stream   content changes without a commit (host cron / runtime push).
#                 A pin taken at signing time is stale by construction.
#                 -> listed in artifact_manifest with url + kind, NO sha256.
#   kind=static   changes only when a commit changes it. -> pinned.
#   kind=record   the URL's name is derived from a digest of the content it
#                 addresses, so whatever that digest covers cannot change
#                 without the name changing. It need NOT cover the whole file
#                 (for api/archive/ it is the three DAG branches and not the
#                 provenance fields beside them) — the sha256 written into the
#                 manifest is what binds every byte, as of signing.
#                 -> pinned. See the archive resolver's scope note below.
#
# `kind` is the registry's SAFE FLOOR, never a summary: a path is classified by
# its weakest moment. This script therefore reads `.kind` and nothing else — no
# `becomes_record_after`, no `record_caveat`. Those qualifiers may only WIDEN
# what a knowing consumer may do, so a consumer that ignores them is always
# correct (deploy/publication.json kind_definitions._kind_is_the_floor).
#
# For a directory entry (path ending in "/") the registry's kind applies only
# to members whose basename matches its declared `member_pattern`; anything
# else is treated as unpinnable. That is what makes api/archive/ usable: its
# member_pattern is keyed by a 64-hex content digest, which is the property
# tests/publication-registry/ T18 enforces before kind=record may be claimed.
#
# History: before 2026-08-14 this script pinned every leaf it fetched. Four of
# the five were kind=stream, so four of the eight pins in the manifest signed
# 2026-08-06 were already wrong when scripts/check-identity-pins.sh measured
# them the same day. See deploy/identity-pin-baseline.json.
#
# What this helper does NOT do:
#   - It does not generate the ed25519 key. Generate it on the operator Mac:
#       ssh-keygen -t ed25519 -f ~/.ssh/freedom-yield-operator-identity \
#                  -C "freedom-yield-operator-identity"
#     and never commit the private file.
#   - It does not commit anything. Run git add / git diff / git commit yourself.
#   - It does not copy the .pub into public/.well-known/. Do that manually so
#     the operator reviews exactly which bytes go public.
#
# Required env:
#   OPERATOR_IDENTITY_KEY   path to the operator's local private ed25519 key
#                           (mandatory; no hardcoded default — fail loud if absent).
#                           The corresponding .pub file is expected next to it.
#
# Optional env:
#   REPO_ROOT               path to repo (default: two levels above this script).
#   NODE_ID                 NodeID string (default: pinned mainnet NodeID).
#   NETWORK                 network label (default: metal-mainnet).
#   SITE                    canonical site URL (default: https://metal.freedom-yield.com/).
#   KEY_IAT                 issued-at ISO-8601 UTC (default: now).
#   KEY_EXP                 expiry ISO-8601 UTC (default: KEY_IAT + 365 days).
#   PRINCIPAL               allowed_signers principal (default: freedom-yield).
#   ARTIFACT_BASE           URL prefix for leaf artifacts (default:
#                           https://metal.freedom-yield.com).
#   FY_PUBLICATION_REGISTRY path to the publication registry that supplies each
#                           artifact's `kind` (default: deploy/publication.json
#                           inside THIS SCRIPT's own repo — deliberately not
#                           under REPO_ROOT, which tests point at a throwaway
#                           output tree).
#
# Usage:
#   export OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity
#   bash scripts/operator-local/gen-identity.sh
#
# Exit codes:
#   1   input/precondition error (missing key, missing OUT_DIR, bad fingerprint)
#   2   signing or self-verification failed
#   3   no live leaf artifact at all — refusing to publish an empty manifest
#   4   computed artifact_root is not 64-hex
#   6   a retired env var (CHAIN_ANCHOR_*) is set
#   7   FY_EXPECT_CYCLE ordering guard: the published cycle ledger is stale
#   8   KEY_IAT diverges from the identity-history ledger
#   9   publication registry unusable: unreadable, unparseable, or a catalog
#       artifact has no row in it. Fail-closed: without the registry this
#       script cannot know which digests are safe to sign, and guessing is the
#       failure this whole change removes.
#   10  live artifacts exist but NONE of them is pinnable, so artifact_root
#       would commit to nothing. Distinct from 3 (nothing live at all).
#   98  the operator identity private key path is inside the repo
#   99  refusing to run: this looks like the validator host or the web host

set -euo pipefail

# ---- 1. Refuse to run anywhere except the operator's local Mac. -------------

# Hostname guard. Match production-shaped hostnames by role / lifecycle,
# not by provider-name. Defense in depth: the filesystem + deploy-user
# guards below catch hosts whose hostnames do not match these patterns.
HN="$(hostname -s 2>/dev/null || hostname)"
case "$HN" in
	*validator*|*web*|*-prod*|*deploy*)
		echo "REFUSE: gen-identity.sh on production-looking host '$HN'." >&2
		echo "        This script must only run on the operator's local Mac." >&2
		exit 99
		;;
esac

# Filesystem guards — anything that looks like the validator or web host.
if [[ -f /etc/freedom-yield/web-host || -f /etc/freedom-yield/validator-host ]]; then
	echo "REFUSE: detected /etc/freedom-yield/{web-host,validator-host} — server detected." >&2
	exit 99
fi
if [[ -d /home/deploy ]] && id deploy >/dev/null 2>&1; then
	echo "REFUSE: detected 'deploy' user — refusing to run on what looks like a server." >&2
	exit 99
fi

# ---- 1.5. Retired env guard. -----------------------------------------------
#
# The CHAIN_ANCHOR_TX_ID and CHAIN_ANCHOR_EXPLORER environment variables
# were retired 2026-06-20 when the P-Chain memo anchor model was abandoned
# (the current Avalanche / Metal protocol rules forbid non-empty memos on
# AddPermissionlessValidatorTx). See docs/IDENTITY_SCHEMA_CHANGELOG.md.
#
# If either variable is set in the environment when gen-identity.sh is
# invoked, the operator's mental model still expects an anchored output.
# Continuing silently would risk publishing a manifest under a misperceived
# shape. Halt before any output is produced and ask the operator to unset
# the retired variables.
for retired_env in CHAIN_ANCHOR_TX_ID CHAIN_ANCHOR_EXPLORER; do
	if [ -n "${!retired_env:-}" ]; then
		echo "ERROR: ${retired_env} is set but was retired 2026-06-20." >&2
		echo "       The P-Chain memo anchor model was abandoned because the" >&2
		echo "       current protocol rules forbid non-empty memos on" >&2
		echo "       AddPermissionlessValidatorTx. See" >&2
		echo "       docs/IDENTITY_SCHEMA_CHANGELOG.md. To proceed:" >&2
		echo "         unset CHAIN_ANCHOR_TX_ID CHAIN_ANCHOR_EXPLORER" >&2
		echo "       then re-run." >&2
		exit 6
	fi
done

# ---- 2. Resolve inputs. -----------------------------------------------------

: "${OPERATOR_IDENTITY_KEY:?Set OPERATOR_IDENTITY_KEY to your local private key path}"

if [[ ! -f "${OPERATOR_IDENTITY_KEY}" ]]; then
	echo "ERROR: private key not found: ${OPERATOR_IDENTITY_KEY}" >&2
	exit 1
fi
if [[ ! -f "${OPERATOR_IDENTITY_KEY}.pub" ]]; then
	echo "ERROR: public key not found alongside private key: ${OPERATOR_IDENTITY_KEY}.pub" >&2
	exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

# The publication registry is resolved from THIS SCRIPT's own location, not
# from REPO_ROOT. REPO_ROOT is the *output* root and the test harnesses point
# it at a throwaway tree; the registry, by contrast, is the declaration that
# governs this script's behaviour and always ships beside it in the same repo.
SCRIPT_REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUBLICATION_REGISTRY="${FY_PUBLICATION_REGISTRY:-${SCRIPT_REPO_ROOT}/deploy/publication.json}"

OUT_DIR="${REPO_ROOT}/public/api"
OUT_JSON="${OUT_DIR}/identity.json"
OUT_SIG="${OUT_DIR}/identity.json.sig"
# ID_HISTORY_FILE is referenced from §2 (KEY_IAT / KEY_EXP resolution),
# §3.6 (Merkle DAG branch building + bootstrap path), and §5-prime
# (self-check before signing). Single source of truth here.
ID_HISTORY_FILE="${OUT_DIR}/identity-history.jsonl"

[[ -d "${OUT_DIR}" ]] || { echo "ERROR: ${OUT_DIR} not found — wrong REPO_ROOT?" >&2; exit 1; }

# Key-path-in-repo guard — refuse if the key file appears to live inside the repo.
KEY_REAL="$(cd "$(dirname "${OPERATOR_IDENTITY_KEY}")" && pwd)/$(basename "${OPERATOR_IDENTITY_KEY}")"
case "${KEY_REAL}" in
	"${REPO_ROOT}"/*|*"/public/"*)
		echo "REFUSE: operator identity private key path looks like it lives inside the repo:" >&2
		echo "        ${KEY_REAL}" >&2
		echo "        Move the key out of the repo before running." >&2
		exit 98
		;;
esac

NODE_ID="${NODE_ID:-NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v}"
NETWORK="${NETWORK:-metal-mainnet}"
SITE="${SITE:-https://metal.freedom-yield.com/}"
PRINCIPAL="${PRINCIPAL:-freedom-yield}"
NAMESPACE="freedom-yield/validator-identity"

NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- 3. Compute the SHA256:base64 SSH fingerprint. --------------------------
# ssh-keygen -l -f <pub> emits:  "<bits> SHA256:<base64> <comment> (ED25519)"
# This block was moved up from after §2 (= where it sat in the original
# layout) so the fingerprint is available to the §2 KEY_IAT / KEY_EXP
# ledger-lookup logic below. Early format validation also catches a
# corrupt pubkey before the ledger lookup runs (which uses ${FP}).
FP_LINE="$(ssh-keygen -l -f "${OPERATOR_IDENTITY_KEY}.pub")"
FP="$(printf '%s\n' "${FP_LINE}" | awk '{print $2}')"
case "${FP}" in
	SHA256:*) ;;
	*)
		echo "ERROR: unexpected fingerprint format from ssh-keygen -l: ${FP_LINE}" >&2
		exit 1
		;;
esac

# ---- 2.5. Resolve KEY_IAT / KEY_EXP from the ledger. ------------------------
# Semantics: key_iat = "issued at *the key*", NOT "manifest reissue moment".
# Therefore on a regeneration the value must come from the existing ledger
# entry for this exact pubkey, not from the regen wallclock. This fixes the
# HIGH-1 finding from the 2026-06-22 audit (= identity.json.key_iat drifted
# on every gen-identity.sh re-run, diverging from identity-history.jsonl).
#
# Resolution order: explicit env override > ledger match > NOW_UTC.
#   - env override: operator-forced (e.g. genuine key rotation prep).
#   - ledger match: pubkey matches a non-revoked entry; reuse its key_iat
#     and key_exp byte-for-byte so the manifest cannot diverge from the
#     ledger.
#   - NOW_UTC: first-time bootstrap, OR a genuinely new key whose entry
#     is about to be appended to the ledger (= rotation case).
LEDGER_KEY_IAT=""
LEDGER_KEY_EXP=""
if [ -f "${ID_HISTORY_FILE}" ]; then
	# Find the latest non-revoked ledger entry whose fingerprint matches.
	# `-R` reads the file line-by-line as raw strings, `(fromjson? // empty)`
	# parses each line and silently skips malformed JSONL lines (= the
	# robustness improvement requested by re-audit F4; without this, jq
	# dies on the first parse error and the lookup falls through to
	# NOW_UTC, where the §4.5 self-check then refuses to sign as a safe
	# fail-loud). `tail -n 1` handles the (out-of-spec) case where multiple
	# active entries share the same fingerprint by preferring the most recent.
	LEDGER_MATCH="$(jq -Rc --arg fp "${FP}" '
		(fromjson? // empty)
		| select(.revoked == false and .operator_identity_pubkey_fingerprint == $fp)
	' "${ID_HISTORY_FILE}" 2>/dev/null | tail -n 1)"
	if [ -n "${LEDGER_MATCH}" ]; then
		LEDGER_KEY_IAT="$(printf '%s' "${LEDGER_MATCH}" | jq -r '.key_iat // empty')"
		LEDGER_KEY_EXP="$(printf '%s' "${LEDGER_MATCH}" | jq -r '.key_exp // empty')"
	fi
fi

KEY_IAT="${KEY_IAT:-${LEDGER_KEY_IAT:-${NOW_UTC}}}"
if [[ -z "${KEY_EXP:-}" ]]; then
	if [ -n "${LEDGER_KEY_EXP}" ] && [ "${KEY_IAT}" = "${LEDGER_KEY_IAT}" ]; then
		# Reuse ledger's key_exp verbatim — guarantees byte-for-byte
		# identity with the published identity-history.jsonl entry.
		KEY_EXP="${LEDGER_KEY_EXP}"
	# LC_ALL=C forces POSIX locale so date does not emit a localized fallback
	# (= ja_JP would emit "2027年 6月22日 火曜日 ..." if the explicit +fmt
	# is not applied for any reason). -u placed BEFORE -f because macOS BSD
	# date treats -u as an option flag that must precede positional args.
	elif LC_ALL=C date -u -j -v+365d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
		# BSD date (macOS).
		KEY_EXP="$(LC_ALL=C date -u -j -v+365d -f "%Y-%m-%dT%H:%M:%SZ" "${KEY_IAT}" +%Y-%m-%dT%H:%M:%SZ)"
	else
		# GNU date (Linux).
		KEY_EXP="$(LC_ALL=C date -u -d "${KEY_IAT} +365 days" +%Y-%m-%dT%H:%M:%SZ)"
	fi
fi

# ---- 3.5. Build artifact_manifest + artifact_root. --------------------------
#
# Probe each leaf artifact + its companion schema (where applicable). Skip
# 4xx/5xx leaves (e.g., cycle-history.jsonl is HOLD until Task #28 / D10 gate
# clears) — they will be picked up automatically once they go live, and the
# Merkle root will change accordingly.
#
# A leaf is HASHED only when the publication registry declares it pinnable
# (kind=static / kind=record). kind=stream leaves are still listed — the URL is
# part of the published artifact set — but carry no sha256 and contribute no
# Merkle leaf. See "kind discipline" in the header.

ARTIFACT_BASE="${ARTIFACT_BASE:-https://metal.freedom-yield.com}"

# ---- publication registry (single source of `kind`) -------------------------
[ -r "${PUBLICATION_REGISTRY}" ] || {
	echo "ERROR: publication registry not readable: ${PUBLICATION_REGISTRY}" >&2
	echo "       Without it this script cannot tell which artifacts are safe to" >&2
	echo "       pin in a signed manifest, and it will not guess. Restore the" >&2
	echo "       file (it is git-tracked) or set FY_PUBLICATION_REGISTRY." >&2
	exit 9
}
jq empty "${PUBLICATION_REGISTRY}" >/dev/null 2>&1 || {
	echo "ERROR: publication registry is not valid JSON: ${PUBLICATION_REGISTRY}" >&2
	exit 9
}

# url_to_registry_path <url> -> path relative to public/ (e.g. api/evidence.json)
# Same normalisation scripts/check-identity-pins.sh uses, so the two agree on
# what a manifest URL points at.
url_to_registry_path() {
	local u="$1" rest
	case "$u" in *://*) ;; *) return 1 ;; esac
	rest="${u#*://}"                     # host/api/x.json
	case "$rest" in */*) ;; *) return 1 ;; esac
	rest="${rest#*/}"                    # api/x.json
	[ -n "${rest}" ] || return 1
	printf '%s' "${rest}"
}

# registry_kind_of_path <path-relative-to-public> -> kind on stdout, or empty.
#
# Exact rows win. Directory rows (path ending in "/") apply to a member ONLY
# when the member's basename matches the row's declared member_pattern — a
# directory that promises immutability for digest-named members promises
# nothing for anything else, and the safe floor for "anything else" is
# unpinnable. Returns empty for an unknown path; the caller treats that as
# fail-closed (exit 9), never as "probably fine".
registry_kind_of_path() {
	local p="$1"
	# `. as $row` first, then reference $row everywhere: inside startswith() /
	# endswith() / a slice index, `.` is the STRING being operated on, not the
	# publication object.
	jq -r --arg p "$p" '
		( [ .publications[] | select(.path == $p) | .kind ] | first // "" ) as $exact
		| if $exact != "" then $exact
		  else
			( [ .publications[]
				| . as $row
				| select($row.path | endswith("/"))
				| select(($row.member_pattern // "") != "")
				| select($p | startswith($row.path))
				| ($row.path | length) as $plen
				| ($p[$plen:]) as $member
				| select($member | test($row.member_pattern))
				| $row.kind
			  ] | first // "" )
		  end
	' "${PUBLICATION_REGISTRY}" 2>/dev/null
}

# kind_is_pinnable <kind> -> 0 when a sha256 of these bytes may be signed.
kind_is_pinnable() {
	case "$1" in
		static|record) return 0 ;;
		*)             return 1 ;;
	esac
}

# resolve_kind_or_die <url> <label> -> kind on stdout; exit 9 if unknown.
resolve_kind_or_die() {
	local url="$1" label="$2" rel kind
	rel="$(url_to_registry_path "${url}")" || {
		echo "ERROR: ${label}: malformed artifact URL: ${url}" >&2
		exit 9
	}
	kind="$(registry_kind_of_path "${rel}")"
	if [ -z "${kind}" ]; then
		echo "ERROR: ${label}: '${rel}' has no row in ${PUBLICATION_REGISTRY##*/}." >&2
		echo "       Every artifact this manifest names must be declared there so" >&2
		echo "       its pinnability is a machine-checked fact, not an assumption." >&2
		echo "       Add the publication (with its kind) and re-run." >&2
		exit 9
	fi
	printf '%s' "${kind}"
}

# Portable sha256: macOS ships `shasum`, Linux usually ships both; prefer
# `shasum -a 256` for cross-platform behaviour.
sha256_of_stdin() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		echo "ERROR: neither shasum nor sha256sum is installed" >&2
		exit 1
	fi
}

# Merkle root over hex sha256 leaves read from stdin (one per line, already
# in the desired alphabetical-key order). Output: 64-hex root on stdout.
#
# Convention (must match identity.schema.v1.json description and
# docs/IDENTITY_VERIFICATION.md Step 6):
#   - odd counts duplicate the LAST leaf at each level
#   - parent = SHA-256( raw_bytes(left) || raw_bytes(right) )
#   - single-leaf input returns that leaf unchanged
compute_merkle_root() {
	local cur nxt left right parent count
	cur="$(mktemp -t merkle.XXXXXX)"
	nxt="$(mktemp -t merkle.XXXXXX)"
	cat > "${cur}"

	count="$(wc -l < "${cur}" | tr -d ' ')"
	if [ "${count}" -eq 0 ]; then
		rm -f "${cur}" "${nxt}"
		echo "ERROR: compute_merkle_root received no leaves on stdin" >&2
		return 1
	fi

	while [ "${count}" -gt 1 ]; do
		# Duplicate last leaf if odd.
		if [ $((count % 2)) -eq 1 ]; then
			tail -n 1 "${cur}" >> "${cur}"
		fi

		: > "${nxt}"
		while IFS= read -r left && IFS= read -r right; do
			parent="$(
				{ printf '%s' "${left}"  | xxd -r -p
				  printf '%s' "${right}" | xxd -r -p
				} | sha256_of_stdin
			)"
			printf '%s\n' "${parent}" >> "${nxt}"
		done < "${cur}"

		mv "${nxt}" "${cur}"
		nxt="$(mktemp -t merkle.XXXXXX)"
		count="$(wc -l < "${cur}" | tr -d ' ')"
	done

	cat "${cur}"
	rm -f "${cur}" "${nxt}"
}

# Leaf catalog: <key>|<url>|<schema_url>
# Empty <schema_url> = no formal schema yet (manifest entry without schema_url
# is honest about that state; see identity.schema.v1.json artifact_manifest
# description "(where applicable)").
#
# Every URL here must have a row in the publication registry — a missing row is
# exit 9, and tests/identity-kind-discipline/ asserts the real catalog resolves
# against the real registry so that never first happens on a transition day.
LEAF_CATALOG="evidence_json|${ARTIFACT_BASE}/api/evidence.json|${ARTIFACT_BASE}/api/evidence.schema.v1.json
validator_json|${ARTIFACT_BASE}/api/validator.json|${ARTIFACT_BASE}/api/validator.schema.v1.json
cycle_history_jsonl|${ARTIFACT_BASE}/api/cycle-history.jsonl|${ARTIFACT_BASE}/api/cycle-history.schema.v1.json
uptime_cycles_json|${ARTIFACT_BASE}/api/uptime-cycles.json|
incidents_json|${ARTIFACT_BASE}/api/incidents.json|${ARTIFACT_BASE}/api/incidents.schema.v1.json"

LEAVES_TMP="$(mktemp -t leaves.XXXXXX)"      # sorted leaf body (pinned only)
MANIFEST_TMP="$(mktemp -t manifest.XXXXXX)"  # incremental manifest JSON
LIVE_COUNT=0                                 # leaves that answered 200
printf '%s' '{}' > "${MANIFEST_TMP}"

# manifest_put <key> <url> <kind> <sha|""> <schema_url|""> <schema_sha|"">
# Fields are added in a fixed order and omitted when empty, so an absent
# sha256 is a positive statement ("declared unpinnable"), not a truncation.
manifest_put() {
	jq --arg key "$1" --arg url "$2" --arg kind "$3" \
	   --arg sha "$4" --arg surl "$5" --arg ssha "$6" '
		.[$key] = (
			{url: $url, kind: $kind}
			+ (if $sha  != "" then {sha256: $sha}          else {} end)
			+ (if $surl != "" then {schema_url: $surl}     else {} end)
			+ (if $ssha != "" then {schema_sha256: $ssha}  else {} end)
		)
	' "${MANIFEST_TMP}" > "${MANIFEST_TMP}.next"
	mv "${MANIFEST_TMP}.next" "${MANIFEST_TMP}"
}

while IFS='|' read -r LEAF_KEY LEAF_URL LEAF_SCHEMA_URL; do
	[ -z "${LEAF_KEY}" ] && continue

	# Resolve the declared kind BEFORE any fetch. An artifact this manifest
	# names but the registry does not declare is a hard stop (exit 9).
	# `|| exit 9` is not decoration: resolve_kind_or_die's own `exit` runs in
	# the command-substitution subshell, so it must be re-raised here.
	LEAF_KIND="$(resolve_kind_or_die "${LEAF_URL}" "leaf ${LEAF_KEY}")" || exit 9

	# Probe leaf URL.
	LEAF_CODE="$(curl -sSLI -o /dev/null -w "%{http_code}" "${LEAF_URL}")"
	if [ "${LEAF_CODE}" != "200" ]; then
		echo "  skip ${LEAF_KEY}: HTTP ${LEAF_CODE} at ${LEAF_URL}" >&2
		continue
	fi
	LIVE_COUNT=$((LIVE_COUNT + 1))

	# Fetch + sha256 of the leaf body — ONLY when the kind permits a pin.
	# A stream is not fetched at all: its digest has no signed meaning, so
	# downloading it would only add a failure mode to the signing path.
	LEAF_SHA=""
	if kind_is_pinnable "${LEAF_KIND}"; then
		LEAF_BODY="$(mktemp -t leaf.XXXXXX)"
		if ! curl -sSLf -o "${LEAF_BODY}" "${LEAF_URL}"; then
			rm -f "${LEAF_BODY}"
			echo "  skip ${LEAF_KEY}: fetch failed at ${LEAF_URL}" >&2
			LIVE_COUNT=$((LIVE_COUNT - 1))
			continue
		fi
		LEAF_SHA="$(sha256_of_stdin < "${LEAF_BODY}")"
		rm -f "${LEAF_BODY}"
	else
		echo "  unpinned ${LEAF_KEY}: kind=${LEAF_KIND} — listed without sha256 (a signed pin on a stream is stale by construction)" >&2
	fi

	# Optional schema probe + sha256. The schema is a separate publication with
	# its own kind: a stream payload can still have a static, pinnable schema —
	# which is exactly what "pin the schema, not the payload" means here.
	LEAF_SCHEMA_SHA=""
	if [ -n "${LEAF_SCHEMA_URL}" ]; then
		LEAF_SCHEMA_KIND="$(resolve_kind_or_die "${LEAF_SCHEMA_URL}" "schema of ${LEAF_KEY}")" || exit 9
		SCHEMA_CODE="$(curl -sSLI -o /dev/null -w "%{http_code}" "${LEAF_SCHEMA_URL}")"
		if [ "${SCHEMA_CODE}" != "200" ]; then
			echo "  warn ${LEAF_KEY}: schema URL HTTP ${SCHEMA_CODE}; dropping schema fields for this leaf" >&2
			LEAF_SCHEMA_URL=""
		elif kind_is_pinnable "${LEAF_SCHEMA_KIND}"; then
			SCHEMA_BODY="$(mktemp -t schema.XXXXXX)"
			curl -sSLf -o "${SCHEMA_BODY}" "${LEAF_SCHEMA_URL}"
			LEAF_SCHEMA_SHA="$(sha256_of_stdin < "${SCHEMA_BODY}")"
			rm -f "${SCHEMA_BODY}"
		else
			echo "  unpinned ${LEAF_KEY} schema: kind=${LEAF_SCHEMA_KIND} — schema_url kept, schema_sha256 omitted" >&2
		fi
	fi

	# Only a pinned digest becomes a Merkle leaf.
	[ -n "${LEAF_SHA}" ] && printf '%s\t%s\n' "${LEAF_KEY}" "${LEAF_SHA}" >> "${LEAVES_TMP}"

	manifest_put "${LEAF_KEY}" "${LEAF_URL}" "${LEAF_KIND}" \
	             "${LEAF_SHA}" "${LEAF_SCHEMA_URL}" "${LEAF_SCHEMA_SHA}"
done <<EOF
${LEAF_CATALOG}
EOF

# ---- 3.55. Record leaf: the content-addressed anchor-source archive. --------
#
# The signed pre-image of the most recent anchor event. api/anchor-source.json
# serves the same object at a MUTABLE URL (the spec's category error, and the
# root cause of the 2026-07-07 stale publication); api/archive/ serves it at a
# URL named by the digest it commits to, which is what makes it pinnable.
#
# Discovery goes through api/anchor-history.jsonl (append-only, push-owned).
# That file is a stream, so it is trusted for DISCOVERY only: the archive is
# accepted as a record only after its own .dag_root_computed is confirmed equal
# to the 64-hex in its filename. A file that does not hash-address itself is
# not a record and is skipped.
#
# Every failure here is fail-open (skip the leaf, print why). The manifest must
# never fail to issue on a transition day because an optional record was
# unreachable.
ARCHIVE_LEAF_KEY="anchor_source_archive_json"

resolve_archive_record() {
	# stdout: "<url>\t<sha256>\t<kind>" on success. Return 1 otherwise.
	local hist_tmp code rel base hex arc_tmp arc_url arc_root arc_sha arc_kind
	hist_tmp="$(mktemp -t anchorhist.XXXXXX)"
	code="$(curl -sSLI -o /dev/null -w "%{http_code}" "${ARTIFACT_BASE}/api/anchor-history.jsonl" 2>/dev/null || printf '000')"
	if [ "${code}" != "200" ] || ! curl -sSLf -o "${hist_tmp}" "${ARTIFACT_BASE}/api/anchor-history.jsonl" 2>/dev/null; then
		rm -f "${hist_tmp}"
		echo "  skip ${ARCHIVE_LEAF_KEY}: anchor-history.jsonl not fetchable (HTTP ${code})" >&2
		return 1
	fi
	rel="$(jq -Rr '(fromjson? // empty) | .archived_source_path // empty' "${hist_tmp}" 2>/dev/null | tail -n 1)"
	rm -f "${hist_tmp}"
	if [ -z "${rel}" ]; then
		echo "  skip ${ARCHIVE_LEAF_KEY}: no archived_source_path on the last anchor-history line" >&2
		return 1
	fi

	# Shape gate: only the anchor-source half of api/archive/ is named by a
	# digest of any of its own content (deploy/publication.json record_caveat
	# — the receipt is named by a transaction id, which binds nothing about
	# the bytes, so its URL is stable by operating discipline alone and that
	# is not a property to sign). How far the anchor-source name actually
	# reaches is stated at the self-check below; it is narrower than the row's
	# kind=record on its own suggests.
	base="${rel##*/}"
	case "${base}" in
		anchor-source-*.json) hex="${base#anchor-source-}"; hex="${hex%.json}" ;;
		*) echo "  skip ${ARCHIVE_LEAF_KEY}: unexpected archive basename '${base}'" >&2; return 1 ;;
	esac
	case "${hex}" in
		*[!a-f0-9]*|"") echo "  skip ${ARCHIVE_LEAF_KEY}: archive name is not digest-addressed: ${base}" >&2; return 1 ;;
	esac
	[ "${#hex}" -eq 64 ] || { echo "  skip ${ARCHIVE_LEAF_KEY}: archive digest is not 64-hex: ${base}" >&2; return 1; }

	# The registry must independently declare this member a record.
	arc_kind="$(registry_kind_of_path "${rel}")"
	if ! kind_is_pinnable "${arc_kind:-unknown}"; then
		echo "  skip ${ARCHIVE_LEAF_KEY}: registry kind='${arc_kind:-<none>}' for ${rel} is not pinnable" >&2
		return 1
	fi

	arc_url="${ARTIFACT_BASE}/${rel}"
	code="$(curl -sSLI -o /dev/null -w "%{http_code}" "${arc_url}" 2>/dev/null || printf '000')"
	if [ "${code}" != "200" ]; then
		echo "  skip ${ARCHIVE_LEAF_KEY}: HTTP ${code} at ${arc_url}" >&2
		return 1
	fi
	arc_tmp="$(mktemp -t anchorarc.XXXXXX)"
	if ! curl -sSLf -o "${arc_tmp}" "${arc_url}" 2>/dev/null; then
		rm -f "${arc_tmp}"
		echo "  skip ${ARCHIVE_LEAF_KEY}: fetch failed at ${arc_url}" >&2
		return 1
	fi

	# Content-addressing self-check — this is what earns the record
	# classification. The three branch roots are RE-DERIVED from the fetched
	# bytes (jq -cS canonical form including jq's trailing 0x0a, per
	# docs/MERKLE_DAG_SPEC.md §2.1/§3/§4) and folded, instead of trusting the
	# file's own .dag_root_computed field: a self-declared digest proves
	# nothing about the bytes carrying it.
	local id_root ob_root ar_root derived
	id_root="$(jq -cS '.identity_branch'     "${arc_tmp}" 2>/dev/null | sha256_of_stdin || true)"
	ob_root="$(jq -cS '.observations_branch' "${arc_tmp}" 2>/dev/null | sha256_of_stdin || true)"
	ar_root="$(jq -cS '.artifacts_branch'    "${arc_tmp}" 2>/dev/null | sha256_of_stdin || true)"
	derived="$(printf '%s%s%s' "${id_root}" "${ob_root}" "${ar_root}" | sha256_of_stdin || true)"
	arc_root="$(jq -r '.dag_root_computed // empty' "${arc_tmp}" 2>/dev/null || true)"
	if [ "${derived}" != "${hex}" ]; then
		rm -f "${arc_tmp}"
		echo "  skip ${ARCHIVE_LEAF_KEY}: re-derived DAG root does not address the file name (derived='${derived:-<none>}' vs '${hex}')" >&2
		return 1
	fi
	if [ "${arc_root}" != "${derived}" ]; then
		rm -f "${arc_tmp}"
		echo "  skip ${ARCHIVE_LEAF_KEY}: declared dag_root_computed='${arc_root:-<none>}' disagrees with the re-derived root" >&2
		return 1
	fi

	# HONEST SCOPE OF THE NAME (measured 2026-08-14). The file name binds the
	# THREE BRANCHES and nothing else. anchor-source.json also carries
	# computed_at / computed_by_script / computed_from_git_commit, and none of
	# them sits inside a branch: editing computed_at leaves the re-derived root
	# unchanged while the file's sha256 changes, and gen-anchor-source.sh mv's
	# over an existing archive unconditionally. So this URL is NOT a promise
	# that its bytes are fixed forever — the sha256 recorded below is what
	# fixes them, as of this signing. deploy/publication.json's record_caveat
	# called this half "STRUCTURALLY immutable" until 2026-08-14, on the
	# strength of a grep for `generated_at` returning 0 hits — the field is
	# spelled computed_at, so that grep missed it. That row now states the
	# same scope as this comment and as docs/IDENTITY_VERIFICATION.md; keep
	# the three in step.
	arc_sha="$(sha256_of_stdin < "${arc_tmp}")"
	rm -f "${arc_tmp}"
	[ -n "${arc_sha}" ] || return 1
	printf '%s\t%s\t%s' "${arc_url}" "${arc_sha}" "${arc_kind}"
}

if ARCHIVE_RESOLVED="$(resolve_archive_record)" && [ -n "${ARCHIVE_RESOLVED}" ]; then
	IFS=$'\t' read -r ARC_URL ARC_SHA ARC_KIND <<< "${ARCHIVE_RESOLVED}"
	LIVE_COUNT=$((LIVE_COUNT + 1))
	printf '%s\t%s\n' "${ARCHIVE_LEAF_KEY}" "${ARC_SHA}" >> "${LEAVES_TMP}"
	manifest_put "${ARCHIVE_LEAF_KEY}" "${ARC_URL}" "${ARC_KIND}" "${ARC_SHA}" "" ""
	echo "  pinned ${ARCHIVE_LEAF_KEY}: kind=${ARC_KIND} ${ARC_URL##*/}" >&2
fi

# Require at least one live artifact so the manifest is not empty.
if [ "${LIVE_COUNT}" -eq 0 ]; then
	echo "ERROR: no live leaves found at ${ARTIFACT_BASE}/api/* — refusing to publish empty artifact_manifest." >&2
	rm -f "${LEAVES_TMP}" "${MANIFEST_TMP}"
	exit 3
fi

# Require at least one PINNABLE leaf so the Merkle tree is well-defined and
# artifact_root commits to something. Distinct from exit 3: here the artifacts
# are live, but every one of them is a stream, so the signature would assert
# nothing about any bytes.
if [ ! -s "${LEAVES_TMP}" ]; then
	echo "ERROR: ${LIVE_COUNT} live artifact(s), but none is pinnable (all kind=stream)." >&2
	echo "       artifact_root would commit to nothing, so the signature would" >&2
	echo "       assert nothing about any bytes. Refusing to publish." >&2
	echo "       Expected pinnable artifacts: api/incidents.json (kind=static)" >&2
	echo "       and the api/archive/ anchor-source record. Check that they are" >&2
	echo "       served at ${ARTIFACT_BASE}." >&2
	rm -f "${LEAVES_TMP}" "${MANIFEST_TMP}"
	exit 10
fi

# Merkle root over leaves sorted alphabetically by key.
ARTIFACT_ROOT="$(sort -t '	' -k1,1 "${LEAVES_TMP}" | awk -F'\t' '{print $2}' | compute_merkle_root)"
case "${ARTIFACT_ROOT}" in
	*[!a-f0-9]*|"") echo "ERROR: computed artifact_root is not 64-hex: ${ARTIFACT_ROOT}" >&2; exit 4 ;;
esac
if [ "${#ARTIFACT_ROOT}" -ne 64 ]; then
	echo "ERROR: computed artifact_root is not 64 chars: ${ARTIFACT_ROOT}" >&2
	exit 4
fi

ARTIFACT_MANIFEST_JSON="$(cat "${MANIFEST_TMP}")"
rm -f "${LEAVES_TMP}" "${MANIFEST_TMP}"

# ---- 3.6. Bootstrap identity-history.jsonl + cycle-ledger ordering guard. ----
#
# The Merkle DAG is no longer computed here (design-stocktake #1 collapse,
# 2026-07-06). The single authoritative DAG lives in anchor-source.json
# (.dag_root_computed, 3-branch) produced by scripts/gen-anchor-source.sh;
# identity.json carries no dag_root_hash and no cycles-history.json is written.
# This section retains the two responsibilities that stay identity generation's:
#   1. Bootstrap /api/identity-history.jsonl on the first Phase α run.
#   2. Ordering guard (design-stocktake #6): refuse to regenerate identity
#      before the just-closed cycle is on the published cycle-history.jsonl.

# Bootstrap identity-history.jsonl if absent (= first Phase α run).
# (ID_HISTORY_FILE is defined once at the top of the script alongside
# OUT_JSON / OUT_SIG; see §2.)
if [ ! -f "${ID_HISTORY_FILE}" ]; then
	echo "  bootstrap: ${ID_HISTORY_FILE} not present; writing key_seq=1 line" >&2
	# Single canonical line via jq -c (compact + sorted not enforced; the
	# bytes published here become the leaf forever, so any subsequent
	# re-format would break verification — operator MUST treat this file
	# as byte-for-byte append-only after the bootstrap commit).
	jq -nc \
		--arg fp        "${FP}" \
		--arg pub_url   "https://metal.freedom-yield.com/.well-known/operator-identity.pub" \
		--arg iat       "${KEY_IAT}" \
		--arg exp       "${KEY_EXP}" \
		'{
			schema_version: 1,
			key_seq: 1,
			operator_identity_pubkey_fingerprint: $fp,
			operator_identity_pubkey_url: $pub_url,
			key_iat: $iat,
			key_exp: $exp,
			revoked: false,
			revoked_at: null,
			revocation_reason: null,
			superseded_by_key_seq: null,
			comment: "initial Phase α operator identity key — bootstrapped by gen-identity.sh"
		}' > "${ID_HISTORY_FILE}"
	echo "  IMPORTANT: review ${ID_HISTORY_FILE} and git add it alongside identity.json." >&2
fi

# Cycle-ledger freshness — fetch /api/cycle-history.jsonl to feed the ordering
# guard below. Only the latest cycle_n (and a leaf count for the log line) is
# needed; no branch root is computed here (the DAG lives in anchor-source.json).
CY_BODY_TMP="$(mktemp -t cy_body.XXXXXX)"
CY_URL="${ARTIFACT_BASE}/api/cycle-history.jsonl"
CY_CODE="$(curl -sSLI -o /dev/null -w "%{http_code}" "${CY_URL}")"
if [ "${CY_CODE}" = "200" ] && curl -sSLf -o "${CY_BODY_TMP}" "${CY_URL}"; then
	CY_LEAF_COUNT="$(grep -c . "${CY_BODY_TMP}" 2>/dev/null || echo 0)"
	LAST_CYCLE_N="$(jq -s 'map(.cycle_n) | max // empty' "${CY_BODY_TMP}" 2>/dev/null || true)"
else
	echo "  warn: ${CY_URL} not live (HTTP ${CY_CODE}); ledger freshness not checkable" >&2
	CY_LEAF_COUNT=0
	LAST_CYCLE_N=""
fi
rm -f "${CY_BODY_TMP}"

# Ordering guard (design-stocktake #6). Make the just-closed cycle visible, and
# hard-stop if FY_EXPECT_CYCLE is set and the live ledger has not caught up. In
# cycle-3, gen-identity ran BEFORE the closed cycle was recorded, so the fetched
# cycle-history.jsonl was stale and the DAG root did not advance (trouble #1).
# Set FY_EXPECT_CYCLE=<the just-closed cycle> to make that a machine-checked
# precondition instead of operator vigilance.
echo "  cycles branch: latest recorded cycle_n = ${LAST_CYCLE_N:-none} (${CY_LEAF_COUNT} leaves)" >&2
if [ -n "${FY_EXPECT_CYCLE:-}" ]; then
	if [ "${LAST_CYCLE_N:-}" != "${FY_EXPECT_CYCLE}" ]; then
		echo "ERROR: FY_EXPECT_CYCLE=${FY_EXPECT_CYCLE} but the live cycle-history.jsonl's latest cycle_n is ${LAST_CYCLE_N:-none}." >&2
		echo "       The just-closed cycle is not on the published ledger yet, so the DAG would not advance." >&2
		echo "       Record + publish cycle ${FY_EXPECT_CYCLE} (uptime-history.sh -> gen-cycle-history.sh -> push-to-web-host.sh) first." >&2
		exit 7
	fi
	echo "  ✓ ordering guard: cycle-history is fresh to expected cycle ${FY_EXPECT_CYCLE}" >&2
else
	# FY_EXPECT_CYCLE is unset — the machine-checked ordering guard above
	# cannot run (nothing to compare the live ledger against), so this run
	# is NOT protected against the cycle-3 trouble #1 failure mode (a stale
	# cycle-history.jsonl silently producing an identity.json whose DAG root
	# does not advance). This is intentionally NOT a hard-stop: first-run /
	# bootstrap invocations (before any cycle has closed) have no cycle to
	# name yet, so the exit code and control flow here are unchanged from
	# before this warning existed. Loud stderr banner only.
	echo "  ################################################################" >&2
	echo "  #  WARNING: ordering guard DISABLED (FY_EXPECT_CYCLE unset)  #" >&2
	echo "  #  This run is NOT verifying the just-closed cycle is on the #" >&2
	echo "  #  live ledger. At a cycle transition, re-run with:          #" >&2
	echo "  #    FY_EXPECT_CYCLE=<the cycle just closed>                 #" >&2
	echo "  #  See docs/CYCLE_GATE.md, 'Operator runbook' section.       #" >&2
	echo "  ################################################################" >&2
fi

# The 2-branch dag_root_hash and /api/cycles-history.json are retired here
# (design-stocktake #1). The authoritative 3-branch dag_root_computed is built
# by scripts/gen-anchor-source.sh from anchor-source.json and inscribed on
# chain by scripts/sign-anchor-event.sh (memo fya<S>c<N>:).

# ---- 4. Compose identity.json into a tmp file. ------------------------------

TMP_JSON="$(mktemp -t identity.XXXXXX)"
trap 'rm -f "${TMP_JSON}" "${TMP_JSON}.sig"' EXIT

COMMENT_TEXT="Operator identity manifest for Freedom Yield Metal Blockchain validator. Signed with the operator identity key whose public form is at /.well-known/operator-identity.pub. Verification uses ssh-keygen -Y verify (OpenSSH 8.0+). The validator's staker.key / BLS signer.key are NOT used in this signature. The runtime file is regenerated by scripts/operator-local/gen-identity.sh on the operator's local Mac."

jq -n \
	--arg comment "${COMMENT_TEXT}" \
	--arg brand "Freedom Yield" \
	--arg node_id "${NODE_ID}" \
	--arg node_id_authority "https://explorer.metalblockchain.org/" \
	--arg network "${NETWORK}" \
	--arg site "${SITE}" \
	--arg pubkey_url "https://metal.freedom-yield.com/.well-known/operator-identity.pub" \
	--arg fp "${FP}" \
	--arg iat "${KEY_IAT}" \
	--arg exp "${KEY_EXP}" \
	--arg principal "${PRINCIPAL}" \
	--arg namespace "${NAMESPACE}" \
	--arg generated_at "${NOW_UTC}" \
	--argjson artifact_manifest "${ARTIFACT_MANIFEST_JSON}" \
	--arg artifact_root "${ARTIFACT_ROOT}" \
	--arg pin_policy_source "https://github.com/freedomyield/metal.freedom-yield.com/blob/main/deploy/publication.json" \
	--arg pin_policy_rule "An artifact_manifest entry carries sha256 only when the publication registry declares its kind as 'static' (bytes change only when a commit changes them) or 'record' (the URL's name is derived from a digest of the content it addresses, so whatever that digest covers cannot change without the name changing too). A record's name binds only what its digest covers, and that need NOT be the whole file: for /api/archive/anchor-source-<64-hex>.json the name is the fold of the three DAG branches and does not cover computed_at, computed_by_script or computed_from_git_commit sitting beside them. The sha256 recorded here is what binds every byte, as of signing. A verifier whose fetch disagrees with that digest should re-derive the three branch roots before concluding anything: if they still fold to the value in the file name, the three branch objects are canonically identical to the ones that were anchored and the anchored DAG is unaffected — the difference lies somewhere outside them, and the fold does not say where. Entries with kind 'stream' are published with url + kind and NO sha256: their bytes change without a commit, so a digest fixed at signing time would be false within minutes. The absence of sha256 is a deliberate declaration, not an omission, and a verifier MUST NOT treat it as a broken manifest. The same rule is applied independently to schema_url / schema_sha256." \
	--arg pin_policy_root "artifact_root is the Merkle root over exactly the sha256 values present in artifact_manifest, in alphabetical key order." \
	--arg anchor_receipt_url "https://metal.freedom-yield.com/api/anchor-receipt.json" \
	--arg anchor_history_url "https://metal.freedom-yield.com/api/anchor-history.jsonl" \
	'{
		_comment: $comment,
		schema_version: 1,
		brand: $brand,
		node_id: $node_id,
		node_id_authority: $node_id_authority,
		network: $network,
		site: $site,
		operator_identity_pubkey_url: $pubkey_url,
		operator_identity_pubkey_fingerprint: $fp,
		key_iat: $iat,
		key_exp: $exp,
		revoked: false,
		revoked_at: null,
		revocation_reason: null,
		verification: {
			method: "ssh-keygen -Y verify",
			minimum_openssh_version: "8.0",
			namespace: $namespace,
			principal: $principal,
			signature_url: "https://metal.freedom-yield.com/api/identity.json.sig"
		},
		artifact_manifest: $artifact_manifest,
		artifact_root: $artifact_root,
		pin_policy: {
			source: $pin_policy_source,
			rule: $pin_policy_rule,
			merkle_leaves: $pin_policy_root
		},
		anchor_receipt_url: $anchor_receipt_url,
		audit: {
			anchor_receipt: $anchor_receipt_url,
			anchor_history: $anchor_history_url
		},
		generated_at: $generated_at
	}' > "${TMP_JSON}"

# Validate the JSON we just wrote. (`jq empty` exits 0 on valid parse, non-zero
# on parse error. Do NOT use `jq -e empty` — the `empty` filter produces no
# output, and `-e` reads that as "no result" and returns exit code 4.)
jq empty "${TMP_JSON}" >/dev/null

# ---- 4.5. Self-check: payload must not diverge from the ledger. -------------
# Defense-in-depth gate against the HIGH-1 finding from the 2026-06-22 audit
# (= KEY_IAT silently re-derived from NOW_UTC on non-rotation regen,
# producing an identity.json whose key_iat disagreed with the published
# identity-history.jsonl). If §2 / §2.5 ever regress, this gate catches it
# before the signature is produced rather than after publication.
#
# Outcomes:
#   - ledger has an active entry for ${FP} and its key_iat matches: pass
#   - ledger has no active entry for ${FP}: pass (= rotation / bootstrap)
#   - ledger has an active entry but its key_iat ≠ ${KEY_IAT}: refuse
if [ -f "${ID_HISTORY_FILE}" ]; then
	LEDGER_ACTIVE_IAT="$(jq -Rr --arg fp "${FP}" '
		(fromjson? // empty)
		| select(.revoked == false and .operator_identity_pubkey_fingerprint == $fp)
		| .key_iat
	' "${ID_HISTORY_FILE}" 2>/dev/null | tail -n 1)"
	if [ -n "${LEDGER_ACTIVE_IAT}" ] && [ "${KEY_IAT}" != "${LEDGER_ACTIVE_IAT}" ]; then
		echo "ERROR: KEY_IAT=${KEY_IAT} diverges from ledger active entry for ${FP}:" >&2
		echo "       ledger says key_iat=${LEDGER_ACTIVE_IAT}" >&2
		echo "       Refusing to sign — this would reproduce the HIGH-1 divergence." >&2
		echo "       To proceed with a genuine rotation, append a new key_seq=N+1" >&2
		echo "       entry to ${ID_HISTORY_FILE} first (and supersede the old)." >&2
		echo "       To force-override without a rotation, run with explicit" >&2
		echo "       KEY_IAT=<value> matching your intent." >&2
		exit 8
	fi
fi

# ---- 5. Sign with ssh-keygen -Y sign. ---------------------------------------

# Use the file form: ssh-keygen -Y sign writes to <file>.sig in the same dir.
ssh-keygen -Y sign -f "${OPERATOR_IDENTITY_KEY}" -n "${NAMESPACE}" "${TMP_JSON}" >/dev/null

[[ -f "${TMP_JSON}.sig" ]] || { echo "ERROR: ssh-keygen did not produce ${TMP_JSON}.sig" >&2; exit 2; }

# ---- 6. Self-verify before publishing. --------------------------------------

ALLOWED="$(mktemp -t allowed_signers.XXXXXX)"
trap 'rm -f "${TMP_JSON}" "${TMP_JSON}.sig" "${ALLOWED}"' EXIT
PUB_LINE="$(cat "${OPERATOR_IDENTITY_KEY}.pub")"
printf '%s %s\n' "${PRINCIPAL}" "${PUB_LINE}" > "${ALLOWED}"

if ! ssh-keygen -Y verify \
	-f "${ALLOWED}" \
	-I "${PRINCIPAL}" \
	-n "${NAMESPACE}" \
	-s "${TMP_JSON}.sig" < "${TMP_JSON}"; then
	echo "ERROR: self-verify failed — refusing to publish." >&2
	exit 2
fi

# ---- 7. Atomic publish. -----------------------------------------------------

mv "${TMP_JSON}"     "${OUT_JSON}"
mv "${TMP_JSON}.sig" "${OUT_SIG}"
chmod 644 "${OUT_JSON}" "${OUT_SIG}"
trap - EXIT
rm -f "${ALLOWED}"

LEAF_COUNT="$(jq -r '.artifact_manifest | length' "${OUT_JSON}")"
PINNED_COUNT="$(jq -r '[.artifact_manifest[] | select(has("sha256"))] | length' "${OUT_JSON}")"
UNPINNED_KEYS="$(jq -r '[.artifact_manifest | to_entries[] | select(.value | has("sha256") | not) | .key] | join(", ")' "${OUT_JSON}")"

echo "✓ wrote ${OUT_JSON}"
echo "✓ wrote ${OUT_SIG}"
echo "  fingerprint:          ${FP}"
echo "  namespace:            ${NAMESPACE}"
echo "  principal:            ${PRINCIPAL}"
echo "  iat / exp:            ${KEY_IAT} / ${KEY_EXP}"
echo "  artifact leaves:      ${LEAF_COUNT} listed / ${PINNED_COUNT} pinned"
echo "  unpinned (kind=stream): ${UNPINNED_KEYS:-none}"
echo "  registry:             ${PUBLICATION_REGISTRY}"
echo "  artifact_root:        ${ARTIFACT_ROOT} (Merkle over the ${PINNED_COUNT} pinned digest(s))"
echo "  cycle ledger:         latest cycle_n = ${LAST_CYCLE_N:-none} (${CY_LEAF_COUNT} leaves)"
echo "  NOTE: identity.json carries no DAG root. The single authoritative anchor"
echo "        value is anchor-source.json .dag_root_computed (3-branch), memo"
echo "        fya<S>c<N>:, via gen-anchor-source.sh + sign-anchor-event.sh."
echo ""
echo "Next steps (manual):"
echo "  1. If not done yet, copy the public key into the repo:"
echo "       cp ${OPERATOR_IDENTITY_KEY}.pub ${REPO_ROOT}/public/.well-known/operator-identity.pub"
echo "  2. Stage the files produced by this run + the .pub copy:"
echo "       git add public/api/identity.json \\"
echo "               public/api/identity.json.sig \\"
echo "               public/api/identity-history.jsonl \\"
echo "               public/.well-known/operator-identity.pub"
echo "  3. Review the diff and commit."
echo "  4. After deploy, verify the live URLs with the command in docs/IDENTITY_VERIFICATION.md."
