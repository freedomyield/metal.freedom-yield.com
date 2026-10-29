#!/usr/bin/env bash
# scripts/lib/a-chain-profile.sh — the ONE reader of config/a-chain-profiles.json,
# the single committed source of every chain-specific value on the A-Chain
# anchor path (chain_id, node host allowlist, history bases, explorer base,
# proton-cli network name, push-response shape, finality model).
#
# CHAIN: none — this file defines shell functions only. It never invokes
#        proton, curl or any network client, and it never broadcasts.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe. It sits IN FRONT OF the broadcast
#        path (bin/safe-broadcast gate 3 reads its chain_id here), so every
#        function fails closed: on any doubt it prints a reason on stderr,
#        prints NOTHING on stdout, and returns non-zero.
#
# WHY IT EXISTS
#   The A-Chain is expected to move from the XPR Network (Antelope) to
#   PulseVM. Before this file, the chain_id, the host allowlists and the
#   history host were literals scattered across bin/safe-broadcast,
#   gen-anchor-receipt.sh, install-rehearsal-preflight.sh,
#   run-testnet-rehearsal.sh and preview-cycle-anchor-broadcast.sh. Changing
#   chains would mean editing all of them in lock-step on cutover day. With
#   profiles, the cutover is: publish the PulseVM values into
#   config/a-chain-profiles.json (reviewed commit) and select the profile.
#   Until the operator selects a PulseVM profile explicitly, the defaults are
#   the current XPR profiles and nothing changes.
#
# THE FILE (config/a-chain-profiles.json)
#   { "schema_version": 1,
#     "profiles": { "<name>": {
#         "role":            "mainnet" | "testnet",
#         "chain_id":        "<64 lowercase hex>" | null,   null = not yet published
#         "node_hosts":      ["<host>", ...],   allowlist for the endpoint proton-cli
#                                                pushes to (bare lowercase hostnames)
#         "history_bases":   ["https://<host>[/path]", ...],  history (Hyperion /v2,
#                                                /v1/history) base URLs, no trailing /
#         "explorer_base":   "https://<host>/<path>" | null,  tx URL prefix; the
#                                                tx URL is "<explorer_base>/<tx_id>"
#         "proton_network":  "<proton-cli chain name>" | null  (chain:set argument)
#         "push_response":   "processed" | "id-only",
#                            processed = push output carries the execution trace
#                                        (Antelope nodeos; current behaviour)
#                            id-only   = push output carries only transaction_id
#                                        (PulseVM); execution MUST be confirmed by
#                                        polling history_bases for the tx_id
#         "lib_equals_head": true | false   (PulseVM: LIB == head, no reversible window)
#         "gate1_evidence_profile": "<testnet profile name>" | null
#                            mainnet profiles: the testnet profile whose history
#                            is the APPROVED PRIME DIRECTIVE gate-1 evidence for
#                            this mainnet (the operator's committed answer to
#                            "which testnet corresponds"); null = undecided,
#                            gate 1 refuses. Testnet profiles: always null.
#     } } }
#   Profiles shipped: xpr-mainnet, xpr-testnet (current XPR values),
#   pulsevm-mainnet, pulsevm-testnet (chain_id/hosts/explorer/network null or
#   empty until Metallicus publishes official values — any use fails closed).
#
#   The file location is FIXED relative to this library (../../config/). There
#   is deliberately no env var that points the library at another file: an
#   allowlist that widens by exporting a variable is not an allowlist. Tests
#   copy the library and a fixture file into a temporary tree instead.
#
# VALIDATION (acp_validate — run by EVERY getter before it answers)
#   * file readable, jq present, valid JSON, EXACTLY ONE document (an empty
#     file or a concatenation of documents is refused)
#   * no duplicate object key anywhere (jq is last-wins; a duplicate could
#     show a reviewer one value and hand gate 3 another)
#   * top-level keys exactly {schema_version, profiles}; schema_version == 1
#   * the default profiles xpr-mainnet and xpr-testnet exist
#   * profile names match ^[a-z0-9][a-z0-9-]*$
#   * each profile has EXACTLY the nine keys above (missing or extra = invalid)
#   * gate1_evidence_profile: null, or (mainnet-role profiles only) the name
#     of an existing TESTNET-role profile with the same push_response and
#     lib_equals_head (same execution family)
#   * each value has the type/shape above; list entries unique; URL paths
#     carry no "." or ".." segment
#   * cross-role separation: no chain_id, node host or history base may appear
#     in both a mainnet-role and a testnet-role profile (otherwise a "testnet"
#     broadcast could pass gate 3 against mainnet). Same-role sharing is
#     allowed (a PulseVM profile may legitimately keep the XPR chain_id).
#
# SELECTION
#   role "mainnet": FYD_A_CHAIN_PROFILE_MAINNET, default xpr-mainnet
#   role "testnet": FYD_A_CHAIN_PROFILE_TESTNET, default xpr-testnet
#   Empty = unset = default. The selected profile must exist AND carry the
#   same role (selecting a testnet profile for the mainnet role is refused).
#
# INTERFACE (source it; every function takes the ROLE, not a profile name,
# except acp_validate_file)
#   . "${REPO_ROOT}/scripts/lib/a-chain-profile.sh"
#
#   acp_validate                       validate the committed file
#   acp_validate_file <path>           validate an arbitrary file (tests)
#   acp_role_of_chain <chain-arg>      mainnet-a|proton|xpr-mainnet -> mainnet
#                                      testnet-a|proton-test|xpr-testnet -> testnet
#                                      anything else -> refused (rc 3)
#   acp_profile_name <role>            selected profile name
#   acp_chain_id <role>                chain_id; null -> refused (rc 4)
#   acp_expected_chain_id <role>       chain_id reconciled with the legacy
#                                      override FYD_MAINNET_CHAIN_ID /
#                                      FYD_TESTNET_CHAIN_ID: unset/empty -> the
#                                      profile value; set -> must EQUAL the
#                                      profile value, else refused (rc 5). The
#                                      override can never substitute a chain_id
#                                      (in particular it cannot fill a null one).
#                                      This is what gate 3 compares against.
#   acp_node_hosts <role>              one host per line; empty list -> rc 4
#   acp_host_allowed <role> <host>     rc 0 iff <host> is EXACTLY one of
#                                      node_hosts (no case folding, no suffix
#                                      matching: the caller extracts and
#                                      lower-cases the host first, the way
#                                      install-rehearsal-preflight.sh
#                                      fyp_host_of does)
#   acp_history_bases <role>           one base URL per line; empty -> rc 4
#   acp_history_base_allowed <role> <url>  rc 0 iff <url> EXACTLY equals one of
#                                      history_bases
#   acp_explorer_base <role>           tx URL prefix; null -> rc 4
#   acp_proton_network <role>          proton-cli chain name; null -> rc 4
#   acp_push_response <role>           "processed" | "id-only"
#   acp_lib_equals_head <role>         "true" | "false"
#   acp_gate1_evidence_profile mainnet the approved gate-1 evidence testnet
#                                      profile name; null -> rc 4; role
#                                      other than mainnet -> rc 3
#
# RETURN CODES (callers MUST treat any non-zero as "refuse"; map it to their
# own exit-code table, e.g. gate 3 in bin/safe-broadcast)
#   0  ok (value on stdout, one line or one item per line)
#   1  negative answer of a predicate (acp_*_allowed: not in the list)
#   2  profile file missing / unreadable / invalid, the library
#      directory could not be resolved, or the validator itself failed
#      (message says "validator failure (jq ...)" — distinct from "invalid")
#   3  bad role / chain argument, or selected profile unknown / wrong role
#   4  value not available in the selected profile (null or empty list)
#   5  FYD_<ROLE>_CHAIN_ID override disagrees with the profile
#   6  jq missing, older than 1.6, or its version unparseable
#   On rc != 0 stdout is empty and stderr carries "a-chain-profile: <reason>".
#
# CALLER IDIOM (never let a failed getter degrade to an empty string):
#   CID="$(acp_expected_chain_id mainnet)" || exit 4
#   if ! acp_host_allowed mainnet "$host"; then ...refuse...; fi
#
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, no mapfile.
# REQUIRES jq >= 1.6 (every host that runs this has 1.6 or later). This is
# ENFORCED, not assumed: acp__require_jq parses `jq --version` (jq-1.5-1-a5b5cbe,
# jq-1.6, jq-1.7.1, jq-1.7.1-apple, jq-1.8.2 ...) before any other jq call, and
# refuses with rc 6 on a missing jq, a version below 1.6 or an unparseable
# version string — the library never silently runs on a jq it was not
# written for (measured: under jq 1.5 the validator misbehaves). Code stays
# within the jq 1.6 language (no pick, trim, abs, toarray, have_decnum,
# debug/1, --raw-output0 ...), pinned by test J01, because a host may have
# exactly 1.6. The version check result is cached per resolved jq path.
#
# Sourcing: `. lib || exit` — the source itself returns 2 if the library
# directory cannot be resolved (ACP_FILE is then empty and every getter
# refuses anyway).

# acp__resolve_file <lib-dir> — the profile file path for a library living in
# <lib-dir>, or rc 2 with nothing on stdout. Physical resolution (cd -P) so a
# symlinked or ".."-containing path cannot land the lookup in another tree;
# CDPATH cleared so a relative dirname cannot be redirected (and cd prints
# nothing). An empty <lib-dir> must NOT degrade to "/config/…".
acp__resolve_file() {
	local libdir="${1:-}" root
	[ -n "$libdir" ] || return 2
	root="$(CDPATH='' cd -P -- "${libdir}/../.." 2>/dev/null && pwd -P)" || return 2
	[ -n "$root" ] || return 2
	printf '%s/config/a-chain-profiles.json\n' "$root"
}

ACP_LIB_DIR="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
if ! ACP_FILE="$(acp__resolve_file "$ACP_LIB_DIR")"; then
	# Leave ACP_FILE empty: every getter then refuses with rc 2. Also make
	# the source itself fail so a caller written as `. lib || exit` stops.
	ACP_FILE=""
	printf 'a-chain-profile: cannot resolve the library directory; every getter will refuse\n' >&2
	# shellcheck disable=SC2317  # the exit is reached only when executed, not sourced
	return 2 2>/dev/null || exit 2
fi
ACP_DEFAULT_MAINNET="xpr-mainnet"
ACP_DEFAULT_TESTNET="xpr-testnet"

acp__fail() {
	local rc="$1"
	shift
	printf 'a-chain-profile: %s\n' "$*" >&2
	return "$rc"
}

# The jq program emits one line per violation; empty output = valid.
# shellcheck disable=SC2016  # $vars below are jq variables, not shell ones
ACP__VALIDATE_JQ='
def hostre: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$";
def isstr: type == "string";
def ishost: isstr and test(hostre);
def ishttps: isstr and test("^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(/[A-Za-z0-9._~-]+)*$")
  and (test("/\\.\\.?(/|$)") | not);
def uniqlist: (length == (unique | length));
def req: ["chain_id","explorer_base","gate1_evidence_profile","history_bases","lib_equals_head","node_hosts","proton_network","push_response","role"];
def check_profile($n):
  . as $p
  | if ($p | type) != "object" then "\($n): profile is not an object"
    else
      ( (req - ($p | keys)) | .[] | "\($n): missing key \(.)" ),
      ( (($p | keys) - req) | .[] | "\($n): unexpected key \(.)" ),
      ( if ($p | has("role")) and ($p.role | (. == "mainnet" or . == "testnet") | not)
          then "\($n): role must be mainnet or testnet" else empty end ),
      ( if ($p | has("chain_id")) and ($p.chain_id != null)
            and (($p.chain_id | isstr and test("^[0-9a-f]{64}$")) | not)
          then "\($n): chain_id must be null or 64 lowercase hex" else empty end ),
      ( if ($p | has("node_hosts")) and (($p.node_hosts | type == "array" and all(.[]; ishost) and uniqlist) | not)
          then "\($n): node_hosts must be an array of unique bare lowercase hostnames" else empty end ),
      ( if ($p | has("history_bases")) and (($p.history_bases | type == "array" and all(.[]; ishttps) and uniqlist) | not)
          then "\($n): history_bases must be an array of unique https://host[/path] URLs without trailing slash, port, query or userinfo" else empty end ),
      ( if ($p | has("explorer_base")) and ($p.explorer_base != null) and (($p.explorer_base | ishttps) | not)
          then "\($n): explorer_base must be null or an https://host[/path] URL without trailing slash" else empty end ),
      ( if ($p | has("proton_network")) and ($p.proton_network != null)
            and (($p.proton_network | isstr and test("^[a-z0-9][a-z0-9-]*$")) | not)
          then "\($n): proton_network must be null or ^[a-z0-9][a-z0-9-]*$" else empty end ),
      ( if ($p | has("push_response")) and ($p.push_response | (. == "processed" or . == "id-only") | not)
          then "\($n): push_response must be processed or id-only" else empty end ),
      ( if ($p | has("lib_equals_head")) and (($p.lib_equals_head | type) != "boolean")
          then "\($n): lib_equals_head must be a boolean" else empty end ),
      ( if ($p | has("gate1_evidence_profile")) and ($p.gate1_evidence_profile != null)
            and (($p.gate1_evidence_profile | isstr and test("^[a-z0-9][a-z0-9-]*$")) | not)
          then "\($n): gate1_evidence_profile must be null or a profile name" else empty end ),
      ( if ($p.role? == "testnet") and ($p.gate1_evidence_profile? != null)
          then "\($n): gate1_evidence_profile must be null on a testnet profile" else empty end )
    end;
# gate1_evidence_profile, when set, must name an existing TESTNET profile of
# the SAME execution family (equal push_response and lib_equals_head): a
# testnet with a different execution model is not evidence that the
# mainnet broadcast shape works, so such a file is refused outright.
def evidence_refs:
  .profiles as $all
  | $all | to_entries[] | select(.value | type == "object")
  | .key as $n | .value as $v | (.value.gate1_evidence_profile? // null) as $e
  | select($e != null and ($e | type) == "string")
  | if ($all[$e] | type) != "object" then "\($n): gate1_evidence_profile \($e) is not a profile"
    elif $all[$e].role? != "testnet" then "\($n): gate1_evidence_profile \($e) is not a testnet profile"
    elif ($all[$e].push_response? != $v.push_response?) or ($all[$e].lib_equals_head? != $v.lib_equals_head?)
      then "\($n): gate1_evidence_profile \($e) runs a different execution model (push_response / lib_equals_head differ)"
    else empty end;
def crossrole($field):
  [ .profiles | to_entries[] | select(.value | type == "object")
    | .value as $v
    | ($v[$field] // null) as $x
    | (if ($x | type) == "array" then $x[] elif $x == null then empty else $x end)
    | select(type == "string")
    | {role: ($v.role // ""), val: .} ]
  | group_by(.val)[]
  | select((map(.role) | unique | length) > 1)
  | "\($field) \(.[0].val) appears in both a mainnet and a testnet profile";
if type != "object" then "top level is not an object"
else
  ( (["profiles","schema_version"] - keys) | .[] | "missing top-level key \(.)" ),
  ( (keys - ["profiles","schema_version"]) | .[] | "unexpected top-level key \(.)" ),
  ( if has("schema_version") and .schema_version != 1 then "schema_version must be 1" else empty end ),
  ( if has("profiles") and (.profiles | type) != "object" then "profiles is not an object"
    elif has("profiles") then
      ( .profiles | keys[] | select(test("^[a-z0-9][a-z0-9-]*$") | not) | "bad profile name \(.)" ),
      ( ($defaults | split(" ")) - (.profiles | keys) | .[] | "default profile \(.) is missing" ),
      ( .profiles | to_entries[] | .key as $n | .value | check_profile($n) ),
      crossrole("chain_id"), crossrole("node_hosts"), crossrole("history_bases"),
      evidence_refs
    else empty end )
end
'

# acp_validate_file <path> — rc 0 valid, rc 2 invalid (reasons on stderr).
# acp__require_jq — rc 0 iff the jq on PATH reports version >= 1.6.
ACP__JQ_OK_PATH=""
acp__require_jq() {
	local jqpath ver major minor
	jqpath="$(command -v jq 2>/dev/null)" || jqpath=""
	[ -n "$jqpath" ] || { acp__fail 6 "jq is required (>= 1.6) and was not found on PATH"; return; }
	[ "$jqpath" = "$ACP__JQ_OK_PATH" ] && return 0
	ver="$(jq --version 2>/dev/null | head -1)"
	case "$ver" in
		jq-[0-9]*.[0-9]*) ;;
		*) acp__fail 6 "cannot parse jq version '${ver}' from ${jqpath}; jq >= 1.6 required, refusing"; return ;;
	esac
	major="${ver#jq-}"; major="${major%%.*}"
	minor="${ver#jq-*.}"; minor="${minor%%[!0-9]*}"
	case "$major" in ''|*[!0-9]*) acp__fail 6 "cannot parse jq version '${ver}'; jq >= 1.6 required, refusing"; return ;; esac
	case "$minor" in ''|*[!0-9]*) acp__fail 6 "cannot parse jq version '${ver}'; jq >= 1.6 required, refusing"; return ;; esac
	if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 6 ]; }; then
		acp__fail 6 "jq ${ver} at ${jqpath} is older than 1.6; refusing (this library requires jq >= 1.6)"
		return
	fi
	ACP__JQ_OK_PATH="$jqpath"
	return 0
}

acp_validate_file() {
	local file="${1:-}" errs ndocs nstream nparsed
	acp__require_jq || return
	[ -n "$file" ] && [ -f "$file" ] && [ -r "$file" ] \
		|| { acp__fail 2 "profile file not readable: ${file:-<empty>}"; return; }
	# 1. Parse only (a program that cannot fail to compile): a failure here
	#    is the FILE's fault. Slurp so empty and multi-document input are
	#    visible: jq would otherwise answer 0 lines for an empty file and
	#    run the program once per document for a concatenation.
	if ! ndocs="$(jq -s 'length' "$file" 2>/dev/null)"; then
		acp__fail 2 "profile file is not valid JSON: $file"
		return
	fi
	case "$ndocs" in
		1) ;;
		0) acp__fail 2 "profile file holds no JSON document (empty): $file"; return ;;
		*) acp__fail 2 "profile file holds ${ndocs} JSON documents, expected exactly 1: $file"; return ;;
	esac
	# 2. Duplicate object keys. jq keeps the LAST of duplicate keys, so a
	#    file could show a reviewer one chain_id and hand gate 3 another.
	#    The token stream (--stream, jq 1.5) still carries every duplicate;
	#    the parsed value does not. Each dropped duplicate removes at least
	#    one leaf, so the two leaf counts are equal iff there is no
	#    duplicate key anywhere in the document.
	nstream="$(jq -n --stream 'reduce (inputs | select(length == 2)) as $e (0; . + 1)' "$file" 2>/dev/null)" \
		|| { acp__fail 2 "validator failure (jq error) while scanning keys of $file"; return; }
	nparsed="$(jq '[paths(((type == "object" or type == "array") and length > 0) | not)] | length' "$file" 2>/dev/null)" \
		|| { acp__fail 2 "validator failure (jq error) while counting leaves of $file"; return; }
	if [ "$nstream" != "$nparsed" ]; then
		acp__fail 2 "profile file has duplicate object keys (last-wins would hide a value): $file"
		return
	fi
	# 3. Schema. The input is known-good JSON here, so a failure is the
	#    validator program's own (jq compile/runtime error, e.g. an older jq
	#    lacking a builtin) — reported as such, still refusing.
	if ! errs="$(jq -r --arg defaults "${ACP_DEFAULT_MAINNET} ${ACP_DEFAULT_TESTNET}" \
		"$ACP__VALIDATE_JQ" "$file" 2>&1)"; then
		acp__fail 2 "validator failure (jq compile/runtime error, jq $(jq --version 2>/dev/null)) on $file: $(printf '%s' "$errs" | head -1)"
		return
	fi
	if [ -n "$errs" ]; then
		printf '%s\n' "$errs" | while IFS= read -r line; do
			printf 'a-chain-profile: invalid %s: %s\n' "$file" "$line" >&2
		done
		return 2
	fi
	return 0
}

acp_validate() { acp_validate_file "$ACP_FILE"; }

# acp_role_of_chain <chain-arg> — map the chain names the scripts accept today.
acp_role_of_chain() {
	case "${1:-}" in
		mainnet-a|proton|xpr-mainnet) printf 'mainnet\n' ;;
		testnet-a|proton-test|xpr-testnet) printf 'testnet\n' ;;
		*) acp__fail 3 "unknown chain argument: '${1:-}' (expected mainnet-a|proton|xpr-mainnet|testnet-a|proton-test|xpr-testnet)" ;;
	esac
}

# acp_profile_name <role> — validates the file, then resolves the selection.
acp_profile_name() {
	local role="${1:-}" name envvar prole
	case "$role" in
		mainnet) envvar="FYD_A_CHAIN_PROFILE_MAINNET"; name="${FYD_A_CHAIN_PROFILE_MAINNET:-$ACP_DEFAULT_MAINNET}" ;;
		testnet) envvar="FYD_A_CHAIN_PROFILE_TESTNET"; name="${FYD_A_CHAIN_PROFILE_TESTNET:-$ACP_DEFAULT_TESTNET}" ;;
		*) acp__fail 3 "role must be mainnet or testnet, got: '${role}'"; return ;;
	esac
	acp_validate || return
	case "$name" in
		*[!a-z0-9-]*|-*) acp__fail 3 "${envvar}='${name}' is not a valid profile name"; return ;;
	esac
	prole="$(jq -r --arg n "$name" '.profiles[$n].role // empty' "$ACP_FILE")"
	if [ -z "$prole" ]; then
		acp__fail 3 "${envvar}='${name}': no such profile in ${ACP_FILE}"
		return
	fi
	if [ "$prole" != "$role" ]; then
		acp__fail 3 "${envvar}='${name}' is a ${prole} profile; refusing to use it for the ${role} role"
		return
	fi
	printf '%s\n' "$name"
}

# acp__scalar <role> <field> — non-null scalar or rc 4.
acp__scalar() {
	local role="$1" field="$2" name val
	name="$(acp_profile_name "$role")" || return
	val="$(jq -r --arg n "$name" --arg f "$field" \
		'.profiles[$n][$f] | if . == null then empty else tostring end' "$ACP_FILE")" \
		|| { acp__fail 2 "jq failed reading ${field} of ${name}"; return; }
	if [ -z "$val" ]; then
		acp__fail 4 "${field} of profile ${name} is null (not yet published); refusing"
		return
	fi
	printf '%s\n' "$val"
}

# acp__list <role> <field> — non-empty list, one item per line, or rc 4.
acp__list() {
	local role="$1" field="$2" name val
	name="$(acp_profile_name "$role")" || return
	val="$(jq -r --arg n "$name" --arg f "$field" '.profiles[$n][$f][]' "$ACP_FILE")" \
		|| { acp__fail 2 "jq failed reading ${field} of ${name}"; return; }
	if [ -z "$val" ]; then
		acp__fail 4 "${field} of profile ${name} is empty (not yet published); refusing"
		return
	fi
	printf '%s\n' "$val"
}

# acp__member <role> <field> <value> — rc 0 iff value is exactly a list item.
acp__member() {
	local role="$1" field="$2" want="$3" list item
	list="$(acp__list "$role" "$field")" || return
	[ -n "$want" ] || return 1
	while IFS= read -r item; do
		[ "$item" = "$want" ] && return 0
	done <<EOF
$list
EOF
	return 1
}

acp_chain_id()        { acp__scalar "${1:-}" chain_id; }
acp_explorer_base()   { acp__scalar "${1:-}" explorer_base; }
acp_proton_network()  { acp__scalar "${1:-}" proton_network; }
acp_push_response()   { acp__scalar "${1:-}" push_response; }
acp_lib_equals_head() { acp__scalar "${1:-}" lib_equals_head; }
# acp_gate1_evidence_profile mainnet — the testnet profile whose history is
# the APPROVED gate-1 evidence source for the selected mainnet profile (the
# operator's committed answer to "which testnet corresponds to this
# mainnet"). null → rc 4 (not decided yet); a testnet role → rc 3.
acp_gate1_evidence_profile() {
	case "${1:-}" in
		mainnet) acp__scalar mainnet gate1_evidence_profile ;;
		*) acp__fail 3 "gate1_evidence_profile is a mainnet-role field; got role '${1:-}'" ;;
	esac
}
acp_node_hosts()      { acp__list "${1:-}" node_hosts; }
acp_history_bases()   { acp__list "${1:-}" history_bases; }
acp_host_allowed()    { acp__member "${1:-}" node_hosts "${2:-}"; }
acp_history_base_allowed() { acp__member "${1:-}" history_bases "${2:-}"; }

# acp_expected_chain_id <role> — the chain_id gate 3 must see.
acp_expected_chain_id() {
	local role="${1:-}" cid override ovar
	cid="$(acp_chain_id "$role")" || return
	case "$role" in
		mainnet) ovar="FYD_MAINNET_CHAIN_ID"; override="${FYD_MAINNET_CHAIN_ID:-}" ;;
		testnet) ovar="FYD_TESTNET_CHAIN_ID"; override="${FYD_TESTNET_CHAIN_ID:-}" ;;
	esac
	if [ -n "$override" ] && [ "$override" != "$cid" ]; then
		acp__fail 5 "${ovar}=${override} disagrees with profile $(acp_profile_name "$role" 2>/dev/null) chain_id ${cid}; refusing (change the committed profile, not the env)"
		return
	fi
	printf '%s\n' "$cid"
}
