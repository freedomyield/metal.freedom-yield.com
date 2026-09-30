#!/usr/bin/env bash
# verify-legacy-anchor-archive.sh — OFFLINE check of the archived legacy
# A-Chain anchor records (written by scripts/archive-legacy-anchors.sh).
#
# CHAIN: none. No network, no proton-cli, no broadcast. Reads local files only.
# PRIME_DIRECTIVE: safe.
#
# For every mainnet tx_id in the anchor ledger (anchor-history.jsonl) it checks:
#   1. the archive file exists and its sha256 equals the manifest entry
#   2. the recorded bodies hash to the sha256s in the envelope and manifest
#   3. tx_id and block_num equal the ledger line; block_id equals the block
#      response's id; chain_id equals the pinned value
#   4. exactly 4 actions, all eosio.token::transfer, all authorized by the
#      ledger line's signing_actor@signing_permission
#   5. the 4 memos: with --receipts-dir, the set equals the receipt's memos
#      exactly; always, they must be <prefix>-id:/-ob:/-ar:<hex64> and
#      <prefix>:<dag_root_hash>, with dag_root_hash == sha256(id||ob||ar)
#      (hex concatenation) and equal to the ledger's dag_root_hash
# It fails (exit 1) on any missing record or any mismatch; extra archive files
# not in the ledger are reported but do not fail.
#
# Usage:
#   verify-legacy-anchor-archive.sh [--archive-dir=<dir>] [--history=<jsonl>]
#                                   [--receipts-dir=<dir>]
#   defaults: public/api/legacy-a-chain, public/api/anchor-history.jsonl
#   receipts: <dir>/anchor-receipt-<tx_id>.json (e.g. public/api/archive)
#
# Exit codes: 0 all verified / 1 verification failed / 2 usage or unreadable input

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHAIN_ID="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
SCHEMA="legacy-a-chain-archive/v1"

ARCHIVE_DIR="${REPO_ROOT}/public/api/legacy-a-chain"
HISTORY="${REPO_ROOT}/public/api/anchor-history.jsonl"
RECEIPTS_DIR=""

for arg in "$@"; do
	case "$arg" in
		--archive-dir=*)  ARCHIVE_DIR="${arg#*=}" ;;
		--history=*)      HISTORY="${arg#*=}" ;;
		--receipts-dir=*) RECEIPTS_DIR="${arg#*=}" ;;
		-h|--help)        sed -n '2,32p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)                echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
	esac
done

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then
	sha256_file() { sha256sum "$1" | awk '{print $1}'; }
	sha256_str()  { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
	sha256_pipe() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
	sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
	sha256_str()  { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
	sha256_pipe() { shasum -a 256 | awk '{print $1}'; }
else
	echo "ERROR: sha256sum or shasum required" >&2; exit 2
fi

[ -r "$HISTORY" ] || { echo "ERROR: anchor history not readable: $HISTORY" >&2; exit 2; }
MANIFEST="${ARCHIVE_DIR}/manifest.json"
[ -r "$MANIFEST" ] || { echo "ERROR: manifest not readable: $MANIFEST" >&2; exit 2; }
if ! jq -e --arg s "$SCHEMA" --arg c "$CHAIN_ID" \
	'.schema == $s and .chain_id == $c and (.entries | type == "array")' "$MANIFEST" >/dev/null 2>&1; then
	echo "FAIL manifest: wrong schema/chain_id or not valid JSON" >&2
	exit 1
fi

FAILS=0
bad() { echo "FAIL $1: $2" >&2; FAILS=$((FAILS + 1)); }

LEDGER="$(mktemp "${TMPDIR:-/tmp}/verify-legacy.XXXXXX")"
trap 'rm -f "$LEDGER"' EXIT
jq -rR --slurp '
	split("\n") | map(select(length > 0)) | map(fromjson)
	| map(select((.network // "") | test("^(mainnet-a|xpr-mainnet|proton)$")))
	| unique_by(.tx_id) | sort_by(.block_num) | .[] | @json' "$HISTORY" > "$LEDGER" \
	|| { echo "ERROR: anchor history is not valid JSONL" >&2; exit 2; }
[ -s "$LEDGER" ] || { echo "ERROR: no mainnet anchors in $HISTORY" >&2; exit 2; }

N=0
while IFS= read -r line; do
	row="$line"
	tx="$(printf '%s' "$row" | jq -r '.tx_id // empty')"
	if ! printf '%s' "$tx" | grep -Eq '^[a-f0-9]{64}$'; then bad "ledger" "line without a valid tx_id"; continue; fi
	N=$((N + 1))
	l_block="$(printf '%s' "$row" | jq -r '.block_num')"
	l_actor="$(printf '%s' "$row" | jq -r '.signing_actor')"
	l_perm="$(printf '%s' "$row" | jq -r '.signing_permission')"
	l_prefix="$(printf '%s' "$row" | jq -r '.memo_prefix')"
	l_dag="$(printf '%s' "$row" | jq -r '.dag_root_hash')"

	file="${ARCHIVE_DIR}/${tx}.json"
	if [ ! -r "$file" ]; then bad "$tx" "archive file missing"; continue; fi

	# 1. file vs manifest
	rec="$(jq -c --arg t "$tx" '[.entries[] | select(.tx_id == $t)] | if length == 1 then .[0] else empty end' "$MANIFEST")"
	if [ -z "$rec" ]; then bad "$tx" "no (or duplicate) manifest entry"; continue; fi
	if [ "$(sha256_file "$file")" != "$(printf '%s' "$rec" | jq -r '.sha256')" ]; then
		bad "$tx" "file sha256 differs from manifest"; continue
	fi
	if ! jq -e --arg s "$SCHEMA" --arg t "$tx" '.schema == $s and .tx_id == $t' "$file" >/dev/null 2>&1; then
		bad "$tx" "envelope schema/tx_id wrong"; continue
	fi

	# 2. bodies vs recorded hashes
	# hash straight from the pipe: $(...) would strip a trailing newline that is
	# part of the recorded body, and the hash covers the exact bytes
	h_now="$(jq -j '.history_body' "$file" | sha256_pipe)"; b_now="$(jq -j '.block_body' "$file" | sha256_pipe)"
	hbody="$(jq -j '.history_body' "$file")"; bbody="$(jq -j '.block_body' "$file")"
	e_h="$(jq -r '.history_sha256' "$file")"; e_b="$(jq -r '.block_sha256' "$file")"
	if [ "$h_now" != "$e_h" ] || [ "$e_h" != "$(printf '%s' "$rec" | jq -r '.history_sha256')" ]; then
		bad "$tx" "history body hash mismatch"; continue
	fi
	if [ "$b_now" != "$e_b" ] || [ "$e_b" != "$(printf '%s' "$rec" | jq -r '.block_sha256')" ]; then
		bad "$tx" "block body hash mismatch"; continue
	fi

	# 3. identity of the record
	if [ "$(jq -r '.chain_id' "$file")" != "$CHAIN_ID" ]; then bad "$tx" "chain_id"; continue; fi
	b_id="$(printf '%s' "$bbody" | jq -r 'select(.block_num == '"$l_block"') | .id // empty' 2>/dev/null || true)"
	if [ -z "$b_id" ] || [ "$b_id" != "$(jq -r '.block_id' "$file")" ] || [ "$b_id" != "$(printf '%s' "$rec" | jq -r '.block_id')" ]; then
		bad "$tx" "block_num/block_id mismatch against the block body"; continue
	fi
	if [ "$(jq -r '.block_num' "$file")" != "$l_block" ]; then bad "$tx" "block_num differs from ledger"; continue; fi
	if ! printf '%s' "$hbody" | jq -e --arg t "$tx" --argjson b "$l_block" --arg id "$b_id" '
		(.actions | type == "array")
		and ([.actions[] | .trx_id] | all(. == $t))
		and ([.actions[] | .block_num] | all(. == $b))
		and ([.actions[] | .block_id // $id] | all(. == $id))' >/dev/null 2>&1; then
		bad "$tx" "history body tx_id/block_num/block_id disagree with ledger or block"; continue
	fi

	# 4. action shape + authorization
	if ! printf '%s' "$hbody" | jq -e --arg a "$l_actor" --arg p "$l_perm" '
		(.actions | length) == 4
		and all(.actions[]; .act.account == "eosio.token" and .act.name == "transfer"
			and (.act.authorization | length) == 1
			and .act.authorization[0].actor == $a and .act.authorization[0].permission == $p)' >/dev/null 2>&1; then
		bad "$tx" "not exactly 4 eosio.token transfers authorized by ${l_actor}@${l_perm}"; continue
	fi

	# 5. memos
	memos="$(printf '%s' "$hbody" | jq -c '[.actions[].act.data.memo] | sort')"
	id_m="$(printf '%s' "$memos" | jq -r --arg p "$l_prefix" '.[] | select(startswith($p + "-id:"))')"
	ob_m="$(printf '%s' "$memos" | jq -r --arg p "$l_prefix" '.[] | select(startswith($p + "-ob:"))')"
	ar_m="$(printf '%s' "$memos" | jq -r --arg p "$l_prefix" '.[] | select(startswith($p + "-ar:"))')"
	dg_m="$(printf '%s' "$memos" | jq -r --arg p "$l_prefix" '.[] | select(startswith($p + ":"))')"
	id_r="${id_m#*-id:}"; ob_r="${ob_m#*-ob:}"; ar_r="${ar_m#*-ar:}"; dg_r="${dg_m#*:}"
	memo_ok=1
	for v in "$id_r" "$ob_r" "$ar_r" "$dg_r"; do
		printf '%s' "$v" | grep -Eq '^[a-f0-9]{64}$' || memo_ok=0
	done
	if [ -z "$id_m" ] || [ -z "$ob_m" ] || [ -z "$ar_m" ] || [ -z "$dg_m" ] || [ "$memo_ok" -ne 1 ] \
		|| [ "$(printf '%s' "$memos" | jq 'length')" -ne 4 ]; then
		bad "$tx" "the 4 memos do not have the <prefix>-id/-ob/-ar/<prefix> shape"; continue
	fi
	if [ "$dg_r" != "$l_dag" ] || [ "$(sha256_str "${id_r}${ob_r}${ar_r}")" != "$dg_r" ]; then
		bad "$tx" "dag_root_hash != sha256(id||ob||ar) or != ledger dag_root_hash"; continue
	fi
	if [ -n "$RECEIPTS_DIR" ]; then
		rf="${RECEIPTS_DIR}/anchor-receipt-${tx}.json"
		if [ ! -r "$rf" ]; then bad "$tx" "receipt not found: $rf"; continue; fi
		r_memos="$(jq -c '[.anchor.actions[].memo] | sort' "$rf" 2>/dev/null || true)"
		if [ "$r_memos" != "$memos" ]; then bad "$tx" "memos differ from the receipt"; continue; fi
		if [ "$(jq -r '.anchor.tx_id' "$rf")" != "$tx" ] || [ "$(jq -r '.anchor.block_num' "$rf")" != "$l_block" ]; then
			bad "$tx" "receipt tx_id/block_num differ"; continue
		fi
	fi
	echo "OK   $tx block $l_block"
done < "$LEDGER"

# manifest entries not in the ledger: informational
extra="$(jq -r --slurpfile l "$LEDGER" '[.entries[].tx_id] - [$l[].tx_id] | length' "$MANIFEST")"
[ "$extra" = "0" ] || echo "NOTE: $extra manifest entr(y/ies) not in the ledger"

if [ "$FAILS" -ne 0 ]; then
	echo "VERIFY FAILED: $FAILS problem(s) across $N anchor(s)" >&2
	exit 1
fi
echo "VERIFIED $N anchor(s)"
