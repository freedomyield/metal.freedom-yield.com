#!/usr/bin/env bash
# tests/a-chain-profile/test-a-chain-profile.sh — executable contract of
# scripts/lib/a-chain-profile.sh + config/a-chain-profiles.json.
#
# CHAIN: none. The library performs no chain or network access; this suite
#        only sources it and reads JSON files. No proton, no curl.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# What is proven here (each block names the property it protects):
#   V*  validation fails closed on every malformed file shape (rc 2)
#   S*  default + env selection, unknown profile, wrong-role profile (rc 3)
#   G*  getters return the committed values for the default profiles
#   N*  null / empty values refuse instead of degrading to "" (rc 4)
#   O*  FYD_*_CHAIN_ID override must equal the profile (rc 5)
#   A*  allowlist predicates are exact-match only
#   F*  failure paths print nothing on stdout
#
# Broken-file cases never touch the committed file: the library resolves the
# profile file relative to ITSELF, so each case copies the library plus a
# mutated JSON into a temporary tree and sources that copy.
#
# Usage: bash tests/a-chain-profile/test-a-chain-profile.sh   (exit 0 = all pass)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib/a-chain-profile.sh"
CFG="${REPO_ROOT}/config/a-chain-profiles.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

WORK="$(mktemp -d -t acp-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

MAIN_CID="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
TEST_CID="71ee83bcf52142d61019d95f9cc5427ba6a0d7ff8accd9e2088ae2abeaf3d3dd"

# run <cmd-string> — source the REAL library in a clean bash; prints
# "<rc>|<stdout>" (stdout newlines folded to spaces). stderr -> $WORK/err.
# EXTRA_ENV (word-split on purpose) adds NAME=value pairs for one call.
run() {
	local out rc
	# shellcheck disable=SC2086
	out="$(env -u FYD_A_CHAIN_PROFILE_MAINNET -u FYD_A_CHAIN_PROFILE_TESTNET \
		-u FYD_MAINNET_CHAIN_ID -u FYD_TESTNET_CHAIN_ID ${EXTRA_ENV:-} \
		bash -c ". '$LIB'; $1" 2>"$WORK/err")"
	rc=$?
	printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
}

# run_tree <jq-filter> <cmd-string> — same, against a temp tree whose
# config is the committed file transformed by <jq-filter>.
N=0
run_tree() {
	local filter="$1" cmd="$2" t out rc
	N=$((N + 1))
	t="$WORK/tree$N"
	mkdir -p "$t/scripts/lib" "$t/config"
	cp "$LIB" "$t/scripts/lib/a-chain-profile.sh"
	jq "$filter" "$CFG" > "$t/config/a-chain-profiles.json" || { printf 'JQFAIL|'; return; }
	out="$(env -u FYD_A_CHAIN_PROFILE_MAINNET -u FYD_A_CHAIN_PROFILE_TESTNET \
		-u FYD_MAINNET_CHAIN_ID -u FYD_TESTNET_CHAIN_ID \
		bash -c ". '$t/scripts/lib/a-chain-profile.sh'; $cmd" 2>"$WORK/err")"
	rc=$?
	printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
}

# run_raw <file-content> <cmd> — temp tree with a literal config file, or
# none at all when the first argument is the word NOFILE.
run_raw() {
	local content="$1" cmd="$2" t out rc
	N=$((N + 1))
	t="$WORK/tree$N"
	mkdir -p "$t/scripts/lib" "$t/config"
	cp "$LIB" "$t/scripts/lib/a-chain-profile.sh"
	[ "$content" = "NOFILE" ] || printf '%s' "$content" > "$t/config/a-chain-profiles.json"
	out="$(bash -c ". '$t/scripts/lib/a-chain-profile.sh'; $cmd" 2>"$WORK/err")"
	rc=$?
	printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
}

expect() { # expect <name> <actual> <wanted>
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2' want '$3' stderr: $(head -3 "$WORK/err" | tr '\n' ' ')"; fi
}

[ -r "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }
[ -r "$CFG" ] || { echo "FATAL: $CFG missing"; exit 1; }

# ---------------- V: validation ----------------
expect "V00 committed file validates"        "$(run 'acp_validate')" "0|"
expect "V00b unchanged copy validates"       "$(run_tree '.' 'acp_validate')" "0|"
V() { expect "$1" "$(run_tree "$2" 'acp_validate')" "2|"; }
V "V01 extra top-level key"                  '.extra = 1'
V "V02 missing schema_version"               'del(.schema_version)'
V "V03 schema_version 2"                     '.schema_version = 2'
V "V04 profiles not an object"               '.profiles = []'
V "V05 default xpr-mainnet missing"          'del(.profiles["xpr-mainnet"])'
V "V06 default xpr-testnet missing"          'del(.profiles["xpr-testnet"])'
V "V07 bad profile name"                     '.profiles["Bad_Name"] = .profiles["pulsevm-testnet"]'
V "V08 profile missing key"                  'del(.profiles["xpr-mainnet"].push_response)'
V "V09 profile extra key"                    '.profiles["xpr-mainnet"].endpoint = "https://x.example"'
V "V10 bad role"                             '.profiles["xpr-mainnet"].role = "main"'
V "V11 chain_id upper-case"                  '.profiles["xpr-mainnet"].chain_id |= ascii_upcase'
V "V12 chain_id short"                       '.profiles["xpr-mainnet"].chain_id = "384da888"'
V "V13 chain_id not string"                  '.profiles["xpr-mainnet"].chain_id = 1'
V "V14 node_hosts not array"                 '.profiles["xpr-mainnet"].node_hosts = "proton.eosusa.io"'
V "V15 node_hosts entry with scheme"         '.profiles["xpr-mainnet"].node_hosts += ["https://a.example"]'
V "V16 node_hosts entry upper-case"          '.profiles["xpr-mainnet"].node_hosts += ["A.example"]'
V "V17 node_hosts duplicate"                 '.profiles["xpr-mainnet"].node_hosts += ["proton.eosusa.io"]'
V "V18 history base trailing slash"          '.profiles["xpr-mainnet"].history_bases = ["https://proton.eosusa.io/"]'
V "V19 history base http"                    '.profiles["xpr-mainnet"].history_bases = ["http://proton.eosusa.io"]'
V "V20 history base userinfo"                '.profiles["xpr-mainnet"].history_bases = ["https://u@hist.example"]'
V "V21 history base port"                    '.profiles["xpr-mainnet"].history_bases = ["https://proton.eosusa.io:443"]'
V "V22 history base query"                   '.profiles["xpr-mainnet"].history_bases = ["https://proton.eosusa.io/?a=b"]'
V "V23 explorer_base http"                   '.profiles["xpr-mainnet"].explorer_base = "http://explorer.xprnetwork.org/transaction"'
V "V24 proton_network bad"                   '.profiles["xpr-mainnet"].proton_network = "proton test"'
V "V25 push_response unknown"                '.profiles["xpr-mainnet"].push_response = "trace"'
V "V26 lib_equals_head string"               '.profiles["xpr-mainnet"].lib_equals_head = "false"'
V "V27 cross-role chain_id"                  ".profiles[\"xpr-testnet\"].chain_id = \"$MAIN_CID\""
V "V28 cross-role node host"                 '.profiles["xpr-testnet"].node_hosts += ["proton.eosusa.io"]'
V "V29 cross-role history base"              '.profiles["pulsevm-testnet"].history_bases = ["https://proton.eosusa.io"]'
V "V30 profile not an object"                '.profiles["pulsevm-mainnet"] = "x"'
expect "V31 same-role shared chain_id allowed" \
	"$(run_tree ".profiles[\"pulsevm-testnet\"].chain_id = \"$TEST_CID\"" 'acp_validate')" "0|"
expect "V32 top level not object"            "$(run_tree '[1]' 'acp_validate')" "2|"
expect "V33 not JSON"                        "$(run_raw '{ not json' 'acp_chain_id mainnet')" "2|"
expect "V34 file missing"                    "$(run_raw NOFILE 'acp_chain_id mainnet')" "2|"
expect "V35 jq missing"                      "$(run 'PATH=/nonexistent acp_chain_id mainnet')" "2|"
# every getter refuses on an invalid file, not only acp_validate
for g in acp_profile_name acp_chain_id acp_expected_chain_id acp_node_hosts acp_history_bases \
         acp_explorer_base acp_proton_network acp_push_response acp_lib_equals_head; do
	expect "V36 $g refuses on invalid file" "$(run_tree '.profiles["xpr-mainnet"].role = "main"' "$g mainnet")" "2|"
done
expect "V37 host_allowed refuses on invalid file" \
	"$(run_tree '.profiles["xpr-mainnet"].role = "main"' 'acp_host_allowed mainnet proton.eosusa.io')" "2|"
expect "V38 invalid OTHER profile also refuses" \
	"$(run_tree '.profiles["pulsevm-testnet"].push_response = "x"' 'acp_chain_id mainnet')" "2|"

# ---------------- S: selection ----------------
expect "S01 default mainnet profile"   "$(run 'acp_profile_name mainnet')" "0|xpr-mainnet"
expect "S02 default testnet profile"   "$(run 'acp_profile_name testnet')" "0|xpr-testnet"
expect "S03 empty env = default"       "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=' run 'acp_profile_name mainnet')" "0|xpr-mainnet"
expect "S04 env selects pulsevm"       "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet' run 'acp_profile_name mainnet')" "0|pulsevm-mainnet"
expect "S05 env selects pulsevm-test"  "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet' run 'acp_profile_name testnet')" "0|pulsevm-testnet"
expect "S06 unknown profile"           "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=nope' run 'acp_chain_id mainnet')" "3|"
expect "S07 testnet profile as mainnet" "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=xpr-testnet' run 'acp_chain_id mainnet')" "3|"
expect "S08 mainnet profile as testnet" "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_TESTNET=xpr-mainnet' run 'acp_chain_id testnet')" "3|"
expect "S09 bad profile name chars"    "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=xpr-mainnet;x' run 'acp_chain_id mainnet')" "3|"
expect "S10 bad role"                  "$(run 'acp_chain_id main')" "3|"
expect "S11 empty role"                "$(run 'acp_chain_id')" "3|"
expect "S12 role_of_chain mainnet-a"   "$(run 'acp_role_of_chain mainnet-a; acp_role_of_chain proton; acp_role_of_chain xpr-mainnet')" "0|mainnet mainnet mainnet"
expect "S13 role_of_chain testnet-a"   "$(run 'acp_role_of_chain testnet-a; acp_role_of_chain proton-test; acp_role_of_chain xpr-testnet')" "0|testnet testnet testnet"
expect "S14 role_of_chain unknown"     "$(run 'acp_role_of_chain mainnet')" "3|"

# ---------------- G: getters on default profiles ----------------
expect "G01 mainnet chain_id"      "$(run 'acp_chain_id mainnet')" "0|$MAIN_CID"
expect "G02 testnet chain_id"      "$(run 'acp_chain_id testnet')" "0|$TEST_CID"
expect "G03 mainnet node_hosts"    "$(run 'acp_node_hosts mainnet')" "0|rpc.api.mainnet.metalx.com proton.cryptolions.io proton.eosusa.io"
expect "G04 testnet node_hosts"    "$(run 'acp_node_hosts testnet')" "0|rpc.api.testnet.metalx.com proton-testnet.eoscafeblock.com test.proton.eosusa.io"
expect "G05 mainnet history"       "$(run 'acp_history_bases mainnet')" "0|https://proton.eosusa.io"
expect "G06 testnet history"       "$(run 'acp_history_bases testnet')" "0|https://test.proton.eosusa.io"
expect "G07 mainnet explorer"      "$(run 'acp_explorer_base mainnet')" "0|https://explorer.xprnetwork.org/transaction"
expect "G08 testnet explorer"      "$(run 'acp_explorer_base testnet')" "0|https://testnet.protonscan.io/transaction"
expect "G09 mainnet network"       "$(run 'acp_proton_network mainnet')" "0|proton"
expect "G10 testnet network"       "$(run 'acp_proton_network testnet')" "0|proton-test"
expect "G11 push_response xpr"     "$(run 'acp_push_response mainnet; acp_push_response testnet')" "0|processed processed"
expect "G12 lib_equals_head xpr"   "$(run 'acp_lib_equals_head mainnet; acp_lib_equals_head testnet')" "0|false false"
expect "G13 push_response pulsevm" "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet' run 'acp_push_response mainnet')" "0|id-only"
expect "G14 lib_equals_head pulsevm" "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet' run 'acp_lib_equals_head testnet')" "0|true"

# ---------------- N: null / empty refuse ----------------
for g in acp_chain_id acp_expected_chain_id acp_explorer_base acp_proton_network acp_node_hosts acp_history_bases; do
	expect "N01 pulsevm-mainnet $g refuses" "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet' run "$g mainnet")" "4|"
	expect "N02 pulsevm-testnet $g refuses" "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_TESTNET=pulsevm-testnet' run "$g testnet")" "4|"
done
EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet' run 'acp_chain_id mainnet' >/dev/null
expect "N03 null chain_id message names the profile" "$(grep -c 'pulsevm-mainnet is null' "$WORK/err")" "1"
expect "N04 empty allowlist denies"  "$(EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet' run 'acp_host_allowed mainnet proton.eosusa.io')" "4|"
expect "N05 null chain_id + override still refuses" \
	"$(EXTRA_ENV="FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet FYD_MAINNET_CHAIN_ID=$MAIN_CID" run 'acp_expected_chain_id mainnet')" "4|"

# ---------------- O: override reconciliation ----------------
expect "O01 no override -> profile"  "$(run 'acp_expected_chain_id mainnet')" "0|$MAIN_CID"
expect "O02 equal override accepted" "$(EXTRA_ENV="FYD_MAINNET_CHAIN_ID=$MAIN_CID" run 'acp_expected_chain_id mainnet')" "0|$MAIN_CID"
expect "O03 differing override refused (mainnet)" "$(EXTRA_ENV="FYD_MAINNET_CHAIN_ID=$TEST_CID" run 'acp_expected_chain_id mainnet')" "5|"
expect "O04 differing override refused (testnet)" "$(EXTRA_ENV="FYD_TESTNET_CHAIN_ID=$MAIN_CID" run 'acp_expected_chain_id testnet')" "5|"
expect "O05 empty override = unset"  "$(EXTRA_ENV='FYD_TESTNET_CHAIN_ID=' run 'acp_expected_chain_id testnet')" "0|$TEST_CID"
expect "O06 other role's override ignored" "$(EXTRA_ENV="FYD_TESTNET_CHAIN_ID=$MAIN_CID" run 'acp_expected_chain_id mainnet')" "0|$MAIN_CID"
expect "O07 upper-case override refused" \
	"$(EXTRA_ENV="FYD_MAINNET_CHAIN_ID=$(printf '%s' "$MAIN_CID" | tr 'a-f' 'A-F')" run 'acp_expected_chain_id mainnet')" "5|"

# ---------------- A: exact-match predicates ----------------
expect "A01 listed host allowed"        "$(run 'acp_host_allowed mainnet proton.eosusa.io')" "0|"
expect "A02 other role host denied"     "$(run 'acp_host_allowed mainnet test.proton.eosusa.io')" "1|"
expect "A03 suffix host denied"         "$(run 'acp_host_allowed mainnet evil-proton.eosusa.io')" "1|"
expect "A04 prefix-extended denied"     "$(run 'acp_host_allowed mainnet proton.eosusa.io.attacker.tld')" "1|"
expect "A05 upper-case not folded"      "$(run 'acp_host_allowed mainnet PROTON.EOSUSA.IO')" "1|"
expect "A06 empty host denied"          "$(run 'acp_host_allowed mainnet ""')" "1|"
expect "A07 URL (not host) denied"      "$(run 'acp_host_allowed mainnet https://proton.eosusa.io')" "1|"
expect "A08 history base allowed"       "$(run 'acp_history_base_allowed testnet https://test.proton.eosusa.io')" "0|"
expect "A09 history trailing / denied"  "$(run 'acp_history_base_allowed testnet https://test.proton.eosusa.io/')" "1|"
expect "A10 history other role denied"  "$(run 'acp_history_base_allowed testnet https://proton.eosusa.io')" "1|"
expect "A11 history http denied"        "$(run 'acp_history_base_allowed testnet http://test.proton.eosusa.io')" "1|"
expect "A12 glob-looking host denied"   "$(run 'acp_host_allowed mainnet "*"')" "1|"

# ---------------- F: nothing on stdout when refusing ----------------
# shellcheck disable=SC2016  # the $(...) is meant for the inner bash
expect "F01 mismatch prints no chain_id" \
	"$(EXTRA_ENV="FYD_MAINNET_CHAIN_ID=$TEST_CID" run 'x="$(acp_expected_chain_id mainnet)"; printf "[%s]" "$x"')" "0|[]"
EXTRA_ENV='FYD_A_CHAIN_PROFILE_MAINNET=nope' run 'acp_chain_id mainnet' >/dev/null
expect "F02 stderr carries the reason prefix" "$(grep -c '^a-chain-profile: ' "$WORK/err")" "1"

echo "---"
echo "a-chain-profile: PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
