#!/usr/bin/env bash
# archive-legacy-anchors.sh — preserve the raw on-chain record of every past
# anchor transaction before the Metal A-Chain (XPR Network) is migrated to
# PulseVM and pre-cut history stops being served.
#
# CHAIN: none — READ ONLY. This script issues HTTP reads (Hyperion v2
#        get_transaction, node get_info and get_block) and writes local files.
#        It never calls a push/send endpoint and never runs a signing CLI.
# PRIME_DIRECTIVE: safe — no broadcast-capable command anywhere in this file
#        (tests/legacy-anchor-archive/ greps the script to keep it that way).
#
# WHY: anchors are eosio.token transfer memos, i.e. HISTORY, not chain state.
#      A migration that does not carry history over leaves anchor-history.jsonl
#      pointing at transactions nobody can fetch. The verbatim response bodies
#      kept here let an evaluator re-check every anchor offline
#      (scripts/verify-legacy-anchor-archive.sh) without the old chain.
#
# INPUT: the list of anchor tx_ids comes from the published anchor ledger
#        (public/api/anchor-history.jsonl, a gitignored runtime file that the
#        live site serves):
#          --from-site=<base url>   default https://metal.freedom-yield.com
#          --from-file=<path>       a local copy (used by tests / offline)
#        Only lines whose network is a mainnet A-Chain network are archived.
#
# OUTPUT (default public/api/legacy-a-chain/):
#   <tx_id>.json   envelope: the two response bodies stored VERBATIM as JSON
#                  strings (history_body, block_body) plus their sha256s
#   manifest.json  one entry per tx: tx_id, block_num, block_id, chain_id,
#                  fetched_at, source hosts, sha256 of the file and of each body
#
# SAFETY:
#   - idempotent: a tx already archived and matching its manifest sha256 is
#     skipped without any network call
#   - never overwrites a file whose bytes differ from the manifest, and never
#     replaces recorded bodies with different ones: exit 4 (fail closed)
#   - chain identity is verified with get_info against the pinned chain_id
#     before any block is trusted; a different chain_id is exit 5
#   - polite: one request at a time, FYD_ARCHIVE_SLEEP seconds between calls
#
# HOSTS: script constants below (public XPR mainnet infrastructure). Task 5 of
#        the PulseVM readiness plan switches them to the chain profile.
#
# Usage:
#   archive-legacy-anchors.sh [--from-site=<url> | --from-file=<path>]
#                             [--out-dir=<dir>] [--dry-run]
#
# Exit codes:
#   0  every anchor archived (or already archived)
#   1  usage / dependency error
#   2  anchor list unreadable or malformed
#   3  one or more txs could not be fetched/validated (others were archived)
#   4  fail closed: existing file or manifest entry differs from what the
#      chain served now (nothing was overwritten)
#   5  chain_id mismatch (or no node reachable to confirm it)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- constants (Task 5 replaces these with the xpr-mainnet profile) ---------
CHAIN_ID="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"
HISTORY_HOSTS="proton.eosusa.io"
NODE_HOSTS="proton.eosusa.io rpc.api.mainnet.metalx.com proton.cryptolions.io"
DEFAULT_SITE="https://metal.freedom-yield.com"
SCHEMA="legacy-a-chain-archive/v1"

SITE="$DEFAULT_SITE"
FROM_FILE=""
OUT_DIR="${REPO_ROOT}/public/api/legacy-a-chain"
DRY_RUN=0
SLEEP="${FYD_ARCHIVE_SLEEP:-1}"
CURL="${FYD_CURL:-curl}"

for arg in "$@"; do
	case "$arg" in
		--from-site=*) SITE="${arg#*=}" ;;
		--from-file=*) FROM_FILE="${arg#*=}" ;;
		--out-dir=*)   OUT_DIR="${arg#*=}" ;;
		--dry-run)     DRY_RUN=1 ;;
		-h|--help)     sed -n '2,50p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)             echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

for bin in jq "$CURL"; do
	command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: $bin required" >&2; exit 1; }
done
if command -v sha256sum >/dev/null 2>&1; then
	sha256_file() { sha256sum "$1" | awk '{print $1}'; }
	sha256_pipe() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
	sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
	sha256_pipe() { shasum -a 256 | awk '{print $1}'; }
else
	echo "ERROR: sha256sum or shasum required" >&2; exit 1
fi
case "$SLEEP" in ''|*[!0-9.]*) echo "ERROR: FYD_ARCHIVE_SLEEP must be a number" >&2; exit 1 ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/legacy-anchors.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---- anchor list -----------------------------------------------------------
HISTORY_COPY="$TMP/anchor-history.jsonl"
if [ -n "$FROM_FILE" ]; then
	[ -r "$FROM_FILE" ] || { echo "ERROR (2): --from-file not readable: $FROM_FILE" >&2; exit 2; }
	cp "$FROM_FILE" "$HISTORY_COPY"
elif [ "$DRY_RUN" -eq 1 ]; then
	echo "DRY-RUN: would GET ${SITE%/}/api/anchor-history.jsonl (not fetched in dry-run;"
	echo "DRY-RUN: pass --from-file=<local copy> to see the per-tx plan)"
	exit 0
else
	"$CURL" -sS --fail --max-time 30 -o "$HISTORY_COPY" "${SITE%/}/api/anchor-history.jsonl" \
		|| { echo "ERROR (2): cannot read ${SITE%/}/api/anchor-history.jsonl" >&2; exit 2; }
fi

# tx_id<TAB>block_num for mainnet lines. NOTHING is dropped silently: every
# line whose network is a mainnet A-Chain network (per anchor-history.schema.v2
# the enum is xpr-mainnet|xpr-testnet|mainnet-a|testnet-a) must carry a valid
# tx_id and a positive integer block_num, and a tx_id that appears twice must
# carry the same block_num. Otherwise exit 2. Non-mainnet lines are counted.
LIST="$TMP/list.tsv"
if ! jq -rR --slurp '
	split("\n") | map(select(length > 0)) | map(fromjson)
	| map(select((.network // "") | test("^(mainnet-a|xpr-mainnet)$"))) as $m
	| ($m | map(select((.tx_id | type == "string") and (.tx_id | test("^[a-f0-9]{64}$"))
	                   and (.block_num | type == "number") and (.block_num > 0)
	                   and (.block_num == (.block_num | floor))))) as $v
	| if ($m | length) != ($v | length)
	  then error("\(($m | length) - ($v | length)) mainnet line(s) have a malformed tx_id or a non-positive-integer block_num")
	  else . end
	| if ($v | group_by(.tx_id) | map(select((map(.block_num) | unique | length) > 1)) | length) > 0
	  then error("a tx_id appears with two different block_num values")
	  else . end
	| $v | unique_by(.tx_id) | sort_by(.block_num) | .[] | "\(.tx_id)\t\(.block_num)"' \
	"$HISTORY_COPY" > "$LIST" 2>"$TMP/jq.err"; then
	echo "ERROR (2): anchor history rejected: $(head -c 300 "$TMP/jq.err")" >&2
	exit 2
fi
SKIPPED_OTHER="$(jq -rR --slurp 'split("\n") | map(select(length > 0)) | map(fromjson)
	| map(select(((.network // "") | test("^(mainnet-a|xpr-mainnet)$")) | not)) | length' "$HISTORY_COPY")"
echo "ledger: non-mainnet lines skipped: $SKIPPED_OTHER"
TOTAL="$(wc -l < "$LIST" | tr -d ' ')"
if [ "$TOTAL" -eq 0 ]; then
	echo "ERROR (2): no mainnet anchor tx_ids found in the anchor history" >&2
	exit 2
fi

MANIFEST="${OUT_DIR}/manifest.json"

# ---- dry run: print the plan, touch nothing --------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
	echo "DRY-RUN: $TOTAL anchor tx_ids -> ${OUT_DIR}"
	for h in $NODE_HOSTS; do
		echo "DRY-RUN: GET https://${h}/v1/chain/get_info   (chain_id check, first reachable host)"
		break
	done
	while IFS="$(printf '\t')" read -r tx bn; do
		for h in $HISTORY_HOSTS; do
			echo "DRY-RUN: GET https://${h}/v2/history/get_transaction?id=${tx}"
			break
		done
		for h in $NODE_HOSTS; do
			echo "DRY-RUN: POST https://${h}/v1/chain/get_block  {\"block_num_or_id\":${bn}}   (read call)"
			break
		done
	done < "$LIST"
	echo "DRY-RUN: nothing fetched, nothing written"
	exit 0
fi

# ---- helpers ---------------------------------------------------------------
polite() { [ "$SLEEP" = "0" ] || sleep "$SLEEP"; }
now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# http_get <url> <outfile>   /   http_post_json <url> <json> <outfile>
http_get() { "$CURL" -sS --fail --max-time 30 -H 'accept: application/json' -o "$2" "$1" 2>/dev/null; }
http_post_json() {
	"$CURL" -sS --fail --max-time 30 -H 'accept: application/json' \
		-H 'content-type: application/json' -d "$2" -o "$3" "$1" 2>/dev/null
}

CHAIN_OK_HOSTS=""
node_host_ok() { # confirm chain_id once per node host
	local h="$1"
	case " $CHAIN_OK_HOSTS " in *" $h "*) return 0 ;; esac
	local f="$TMP/get_info.$h.json" got
	http_get "https://${h}/v1/chain/get_info" "$f" || return 1
	got="$(jq -r '.chain_id // empty' "$f" 2>/dev/null || true)"
	[ -n "$got" ] || return 1
	if [ "$got" != "$CHAIN_ID" ]; then
		echo "ERROR (5): $h reports chain_id $got, expected $CHAIN_ID" >&2
		exit 5
	fi
	CHAIN_OK_HOSTS="${CHAIN_OK_HOSTS} ${h}"
	polite
	return 0
}

mkdir -p "$OUT_DIR"

# existing manifest (entries) — corrupt manifest is fail-closed
ENTRIES="$TMP/entries.json"
if [ -e "$MANIFEST" ]; then
	if ! jq -e --arg s "$SCHEMA" '.schema == $s and (.entries | type == "array")' "$MANIFEST" >/dev/null 2>&1; then
		echo "ERROR (4): existing manifest is unreadable or has the wrong schema: $MANIFEST (not touching it)" >&2
		exit 4
	fi
	jq -c '.entries' "$MANIFEST" > "$ENTRIES"
else
	echo '[]' > "$ENTRIES"
fi
ORIG_ENTRIES="$(cat "$ENTRIES")"

# Written after EVERY tx (tmp + mv) so an interrupted run never leaves a file
# without its entry. Rewritten only when the entries actually changed.
flush_manifest() {
	local sorted
	sorted="$(jq -c 'sort_by(.block_num, .tx_id)' "$ENTRIES")"
	if [ "$sorted" != "$ORIG_ENTRIES" ]; then
		jq -n --arg schema "$SCHEMA" --arg cid "$CHAIN_ID" --argjson e "$sorted" \
			'{schema:$schema, chain_id:$cid, entries:$e}' > "$MANIFEST.new"
		mv "$MANIFEST.new" "$MANIFEST"
		ORIG_ENTRIES="$sorted"
	fi
}

FAILED=0
ARCHIVED=0
SKIPPED=0
ADOPTED=0

while IFS="$(printf '\t')" read -r TX BN; do
	case "$BN" in ''|*[!0-9]*|0*) echo "ERROR (2): block_num '$BN' is not a positive integer" >&2; exit 2 ;; esac
	FILE="${OUT_DIR}/${TX}.json"
	REC="$(jq -c --arg t "$TX" '.[] | select(.tx_id == $t)' "$ENTRIES" | head -n1)"

	# -- already archived: verify against the manifest, no network ----------
	if [ -e "$FILE" ] && [ -n "$REC" ]; then
		want="$(printf '%s' "$REC" | jq -r '.sha256')"
		have="$(sha256_file "$FILE")"
		if [ "$want" != "$have" ]; then
			echo "ERROR (4): $FILE differs from the manifest sha256 (manifest $want, file $have) — not overwriting" >&2
			exit 4
		fi
		SKIPPED=$((SKIPPED + 1))
		continue
	fi

	# -- manifest entry but file gone: never re-fetch over a recorded hash ----
	if [ ! -e "$FILE" ] && [ -n "$REC" ]; then
		echo "ERROR (4): manifest records $TX but $FILE is missing — restore it from git, not re-fetch" >&2
		exit 4
	fi

	# -- file present, no entry (interrupted run): adopt without any network
	# call if it verifies against itself and the ledger. Re-fetching would
	# change volatile Hyperion fields (query_time_ms, lib, ...) and look like
	# tampering; a file that does NOT self-verify is fail-closed.
	if [ -e "$FILE" ]; then
		fh="$(jq -j '.history_body' "$FILE" 2>/dev/null | sha256_pipe || true)"
		fb="$(jq -j '.block_body' "$FILE" 2>/dev/null | sha256_pipe || true)"
		if ! jq -e --arg s "$SCHEMA" --arg t "$TX" --arg c "$CHAIN_ID" --argjson bn "$BN" \
				--arg fh "$fh" --arg fb "$fb" '
			. as $f | .schema == $s and .tx_id == $t and .chain_id == $c and .block_num == $bn
			and (.block_id | test("^[a-f0-9]{64}$"))
			and .history_sha256 == $fh and .block_sha256 == $fb
			and ((.history_body | fromjson) as $h
				| ($h.actions | length > 0)
				and ([$h.actions[] | .trx_id] | all(. == $t))
				and ([$h.actions[] | .block_num] | all(. == $bn))
				and ([$h.actions[] | .block_id // $f.block_id] | all(. == $f.block_id)))
			and ((.block_body | fromjson) as $b | $b.block_num == $bn and $b.id == $f.block_id)' \
			"$FILE" >/dev/null 2>&1; then
			echo "ERROR (4): $FILE exists without a manifest entry and does not verify against itself or the ledger — not overwriting" >&2
			exit 4
		fi
		NEW="$(jq -c --arg fs "$(sha256_file "$FILE")" '{tx_id, file:"\(.tx_id).json", block_num, block_id, chain_id, fetched_at,
			source_host:.source.history_host, node_host:.source.node_host, sha256:$fs, history_sha256, block_sha256}' "$FILE")"
		jq -c --argjson n "$NEW" 'map(select(.tx_id != $n.tx_id)) + [$n]' "$ENTRIES" > "$ENTRIES.new"
		mv "$ENTRIES.new" "$ENTRIES"
		flush_manifest
		ADOPTED=$((ADOPTED + 1))
		echo "ADOPT $TX block $BN (file self-verified, no network)"
		continue
	fi

	# -- fetch history ------------------------------------------------------
	HB="$TMP/$TX.history"; BB="$TMP/$TX.block"
	HIST_HOST=""
	for h in $HISTORY_HOSTS; do
		if http_get "https://${h}/v2/history/get_transaction?id=${TX}" "$HB"; then HIST_HOST="$h"; polite; break; fi
		polite
	done
	if [ -z "$HIST_HOST" ]; then
		echo "FAIL $TX: history not served by any allowlisted host" >&2; FAILED=$((FAILED + 1)); continue
	fi
	if ! jq -e --arg t "$TX" '(.actions | type == "array" and length > 0)
			and ([.actions[] | .trx_id] | all(. == $t))' "$HB" >/dev/null 2>&1; then
		echo "FAIL $TX: history response has no actions for this tx_id" >&2; FAILED=$((FAILED + 1)); continue
	fi
	H_BLOCK="$(jq -r '[.actions[].block_num] | unique | if length == 1 then .[0] else "" end' "$HB")"
	if [ "$H_BLOCK" != "$BN" ]; then
		echo "FAIL $TX: history block_num '$H_BLOCK' != ledger block_num '$BN'" >&2; FAILED=$((FAILED + 1)); continue
	fi

	# -- fetch block --------------------------------------------------------
	NODE_HOST=""
	for h in $NODE_HOSTS; do
		node_host_ok "$h" || { polite; continue; }
		if http_post_json "https://${h}/v1/chain/get_block" "{\"block_num_or_id\":${BN}}" "$BB"; then
			NODE_HOST="$h"; polite; break
		fi
		polite
	done
	if [ -z "$NODE_HOST" ]; then
		echo "FAIL $TX: block $BN not served (or no node confirmed the chain_id)" >&2; FAILED=$((FAILED + 1)); continue
	fi
	BLOCK_ID="$(jq -r 'select(.block_num == '"$BN"') | .id // empty' "$BB" 2>/dev/null || true)"
	if ! printf '%s' "$BLOCK_ID" | grep -Eq '^[a-f0-9]{64}$'; then
		echo "FAIL $TX: block response has no matching block_num/id" >&2; FAILED=$((FAILED + 1)); continue
	fi
	if ! jq -e --arg id "$BLOCK_ID" '[.actions[] | .block_id // $id] | all(. == $id)' "$HB" >/dev/null 2>&1; then
		echo "FAIL $TX: history block_id disagrees with the block response" >&2; FAILED=$((FAILED + 1)); continue
	fi

	H_SHA="$(sha256_file "$HB")"; B_SHA="$(sha256_file "$BB")"

	FETCHED_AT="$(now_utc)"
	ENV="$TMP/$TX.envelope"
	jq -n --arg schema "$SCHEMA" --arg tx "$TX" --arg cid "$CHAIN_ID" --arg at "$FETCHED_AT" \
		--arg hh "$HIST_HOST" --arg nh "$NODE_HOST" --argjson bn "$BN" --arg bid "$BLOCK_ID" \
		--rawfile hbody "$HB" --rawfile bbody "$BB" --arg hs "$H_SHA" --arg bs "$B_SHA" \
		'{schema:$schema, tx_id:$tx, chain_id:$cid, block_num:$bn, block_id:$bid, fetched_at:$at,
		  source:{history_host:$hh, node_host:$nh},
		  requests:{history:"GET /v2/history/get_transaction?id=\($tx)",
		            block:"POST /v1/chain/get_block {\"block_num_or_id\":\($bn)}"},
		  history_sha256:$hs, block_sha256:$bs,
		  history_body:$hbody, block_body:$bbody}' > "$ENV"
	mv "$ENV" "$FILE"
	F_SHA="$(sha256_file "$FILE")"
	NEW="$(jq -cn --arg tx "$TX" --argjson bn "$BN" --arg bid "$BLOCK_ID" --arg cid "$CHAIN_ID" \
		--arg at "$FETCHED_AT" --arg hh "$HIST_HOST" --arg nh "$NODE_HOST" \
		--arg fs "$F_SHA" --arg hs "$H_SHA" --arg bs "$B_SHA" \
		'{tx_id:$tx, file:"\($tx).json", block_num:$bn, block_id:$bid, chain_id:$cid, fetched_at:$at,
		  source_host:$hh, node_host:$nh, sha256:$fs, history_sha256:$hs, block_sha256:$bs}')"
	jq -c --argjson n "$NEW" 'map(select(.tx_id != $n.tx_id)) + [$n]' "$ENTRIES" > "$ENTRIES.new"
	mv "$ENTRIES.new" "$ENTRIES"
	flush_manifest
	ARCHIVED=$((ARCHIVED + 1))
	echo "OK   $TX block $BN"
done < "$LIST"

echo "archived=$ARCHIVED adopted=$ADOPTED already_present=$SKIPPED failed=$FAILED total=$TOTAL out=$OUT_DIR"
[ "$FAILED" -eq 0 ] || exit 3
exit 0
