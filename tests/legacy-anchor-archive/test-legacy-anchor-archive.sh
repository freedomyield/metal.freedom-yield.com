#!/usr/bin/env bash
# tests/legacy-anchor-archive/test-legacy-anchor-archive.sh — suite for
# scripts/archive-legacy-anchors.sh and scripts/verify-legacy-anchor-archive.sh.
#
# CHAIN: none. A fake `curl` on PATH serves fixtures and records every call;
#        nothing touches the network and nothing is broadcast.
#
# Fixture shapes: Hyperion v2 get_transaction (actions[] with act/trx_id/
# block_num/block_id, one entry per action) and v1 get_block ({id, block_num}),
# built to the same 4-action pack the gen-anchor-receipt suites use.
#
# Mutation runs: ARCHIVER= / VERIFIER= point the suite at a deliberately broken
# copy of a script (see the task report for the mutations and their results).
#
# Usage: bash tests/legacy-anchor-archive/test-legacy-anchor-archive.sh
# Exit: 0 all PASS / 1 any FAIL

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVER="${ARCHIVER:-${REPO_ROOT}/scripts/archive-legacy-anchors.sh}"
VERIFIER="${VERIFIER:-${REPO_ROOT}/scripts/verify-legacy-anchor-archive.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected='$2' actual='$3')"; fi; }

for f in "$ARCHIVER" "$VERIFIER"; do
	[ -x "$f" ] || { echo "FATAL: not executable: $f" >&2; exit 1; }
done
if command -v sha256sum >/dev/null 2>&1; then H() { sha256sum | awk '{print $1}'; }; else H() { shasum -a 256 | awk '{print $1}'; }; fi

TMP="$(mktemp -d -t legacy-anchor-archive.XXXXXX)"
trap 'rm -rf "${TMP:?}"' EXIT
FX="$TMP/fx"; BIN="$TMP/bin"; LOG="$TMP/curl.log"
mkdir -p "$FX" "$BIN"
CHAIN="384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0"

# --- fixtures: two anchors --------------------------------------------------
mk_tx() { # <idx> <tx_id> <block_num> <prefix>
	local i="$1" tx="$2" bn="$3" p="$4" id ob ar dg bid
	id="$(printf 'id%s' "$i" | H)"; ob="$(printf 'ob%s' "$i" | H)"; ar="$(printf 'ar%s' "$i" | H)"
	dg="$(printf '%s%s%s' "$id" "$ob" "$ar" | H)"
	bid="$(printf 'block%s' "$bn" | H)"
	local memos=("${p}-id:${id}" "${p}-ob:${ob}" "${p}-ar:${ar}" "${p}:${dg}") acts="" m
	for m in "${memos[@]}"; do
		acts="${acts}${acts:+,}{\"act\":{\"account\":\"eosio.token\",\"name\":\"transfer\",\"authorization\":[{\"actor\":\"metalfreedom\",\"permission\":\"anchor\"}],\"data\":{\"memo\":\"$m\"}},\"trx_id\":\"$tx\",\"block_num\":$bn,\"block_id\":\"$bid\",\"@timestamp\":\"2026-08-04T04:00:00.000\"}"
	done
	# deliberately non-canonical whitespace: verbatim storage must survive it
	printf '{ "query_time_ms": 1.5,  "executed": true, "trx_id": "%s", "lib": 999,\n "actions": [%s] }\n' "$tx" "$acts" > "$FX/hist-$tx.json"
	printf '{"id":"%s","block_num":%s,"timestamp":"2026-08-04T04:00:00.000"}' "$bid" "$bn" > "$FX/block-$bn.json"
	printf '{"schema_version":2,"event_type":"cyclestart","dag_root_hash":"%s","memo_prefix":"%s","network":"xpr-mainnet","chain":"metal-a-chain","tx_id":"%s","block_num":%s,"block_time":"2026-08-04T04:00:00Z","signing_actor":"metalfreedom","signing_permission":"anchor"}\n' "$dg" "$p" "$tx" "$bn" >> "$FX/history.jsonl"
	mkdir -p "$FX/receipts"
	jq -n --arg tx "$tx" --argjson bn "$bn" --argjson m "$(printf '%s\n' "${memos[@]}" | jq -R . | jq -s .)" \
		'{anchor:{tx_id:$tx, block_num:$bn, actions:($m | map({memo:.}))}}' > "$FX/receipts/anchor-receipt-$tx.json"
}
TX1="$(printf 'tx1' | H)"; TX2="$(printf 'tx2' | H)"
: > "$FX/history.jsonl"
mk_tx 1 "$TX1" 100 fya1c1
mk_tx 2 "$TX2" 250 fya1c2
# a testnet line must never be archived
printf '{"schema_version":2,"network":"testnet-a","tx_id":"%s","block_num":7}\n' "$(printf 'tn' | H)" >> "$FX/history.jsonl"
printf '{"chain_id":"%s","head_block_num":1}' "$CHAIN" > "$FX/get_info.json"

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""; data=""; url=""; method="GET"
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift ;;
		-d) data="$2"; method="POST"; shift ;;
		-H|--max-time) shift ;;
		https://*) url="$1" ;;
	esac
	shift
done
echo "$method $url $data" >> "$FX_LOG"
serve() { [ -f "$1" ] || exit 22; cp "$1" "$out"; exit 0; }
case "$url" in
	*/api/anchor-history.jsonl)          serve "$FX/history.jsonl" ;;
	*/v1/chain/get_info)                 serve "${FX_INFO:-$FX/get_info.json}" ;;
	*/v2/history/get_transaction\?id=*)  serve "$FX/hist-${url##*id=}.json" ;;
	*/v1/chain/get_block)                bn="$(printf '%s' "$data" | sed 's/[^0-9]//g')"; serve "$FX/block-$bn.json" ;;
esac
echo "STUB: unmatched $url" >&2; exit 22
STUB
chmod +x "$BIN/curl"
export FX FX_LOG="$LOG" PATH="$BIN:$PATH" FYD_ARCHIVE_SLEEP=0

run_archive() { : > "$LOG"; "$ARCHIVER" "$@" >"$TMP/out.txt" 2>"$TMP/err.txt"; echo $?; }
OUT="$TMP/out-dir"
calls() { wc -l < "$LOG" | tr -d ' '; }

# 1. dry-run: plan printed, no HTTP, no files
rc="$(run_archive --from-file="$FX/history.jsonl" --out-dir="$OUT" --dry-run)"
check "dry-run exits 0" 0 "$rc"
check "dry-run makes no HTTP call" 0 "$(calls)"
check "dry-run writes nothing" "no" "$([ -e "$OUT" ] && echo yes || echo no)"
check "dry-run lists a history GET per mainnet tx" 2 "$(grep -c 'GET https://.*/v2/history/get_transaction?id=' "$TMP/out.txt")"
check "dry-run skips the testnet ledger line" 0 "$(grep -c "$(printf 'tn' | H)" "$TMP/out.txt")"
run_archive --from-site=https://example.invalid --out-dir="$OUT" --dry-run >/dev/null
check "dry-run with --from-site does no network" 0 "$(calls)"

# 2. real run against stubs
rc="$(run_archive --from-file="$FX/history.jsonl" --out-dir="$OUT")"
check "archive run exits 0" 0 "$rc"
check "one file per tx plus manifest" 3 "$(find "$OUT" -type f | wc -l | tr -d ' ')"
check "history body stored verbatim" "$(H < "$FX/hist-$TX1.json")" "$(jq -j '.history_body' "$OUT/$TX1.json" | H)"
check "block body stored verbatim" "$(H < "$FX/block-100.json")" "$(jq -j '.block_body' "$OUT/$TX1.json" | H)"
check "manifest sha256 = file sha256" "$(H < "$OUT/$TX2.json")" "$(jq -r --arg t "$TX2" '.entries[] | select(.tx_id==$t) | .sha256' "$OUT/manifest.json")"
check "manifest carries block_id, chain_id, hosts" "true" "$(jq -r --arg t "$TX1" --arg c "$CHAIN" '.entries[] | select(.tx_id==$t) | (.block_id|length==64) and .chain_id==$c and (.source_host|length>0) and (.fetched_at|length>0)' "$OUT/manifest.json")"
check "no non-read endpoint was called" 0 "$(grep -Ec 'push|send|/ext/bc' "$LOG")"
check "only the 3 read endpoint kinds were called" 0 "$(grep -Evc '/v1/chain/get_info|/v2/history/get_transaction\?id=|/v1/chain/get_block' "$LOG")"

# 3. idempotent: no network, manifest byte-identical
M1="$(H < "$OUT/manifest.json")"
rc="$(run_archive --from-file="$FX/history.jsonl" --out-dir="$OUT")"
check "second run exits 0" 0 "$rc"
check "second run makes no HTTP call" 0 "$(calls)"
check "second run leaves the manifest byte-identical" "$M1" "$(H < "$OUT/manifest.json")"

# 4. never overwrite a differing file (fail closed)
cp "$OUT/$TX1.json" "$TMP/tx1.saved"
printf '{"tampered":true}\n' > "$OUT/$TX1.json"
rc="$(run_archive --from-file="$FX/history.jsonl" --out-dir="$OUT")"
check "tampered file: exit 4" 4 "$rc"
check "tampered file: left untouched" '{"tampered":true}' "$(cat "$OUT/$TX1.json")"
cp "$TMP/tx1.saved" "$OUT/$TX1.json"
# file present, manifest entry absent, chain now serves different bytes
jq --arg t "$TX1" '.entries |= map(select(.tx_id != $t))' "$OUT/manifest.json" > "$TMP/m.json" && cp "$TMP/m.json" "$OUT/manifest.json"
cp "$FX/hist-$TX1.json" "$TMP/hist1.orig"
sed 's/"lib": 999/"lib": 1000/' "$TMP/hist1.orig" > "$FX/hist-$TX1.json"
rc="$(run_archive --from-file="$FX/history.jsonl" --out-dir="$OUT")"
check "differing chain bytes vs recorded bodies: exit 4" 4 "$rc"
check "differing chain bytes: file untouched" "$(H < "$TMP/tx1.saved")" "$(H < "$OUT/$TX1.json")"
cp "$TMP/hist1.orig" "$FX/hist-$TX1.json"
rc="$(run_archive --from-file="$FX/history.jsonl" --out-dir="$OUT")"
check "same bytes + missing manifest entry: re-adopted, exit 0" 0 "$rc"
check "re-adopted entry restored" 2 "$(jq '.entries|length' "$OUT/manifest.json")"
check "re-adopted file bytes unchanged" "$(H < "$TMP/tx1.saved")" "$(H < "$OUT/$TX1.json")"

# 5. chain_id mismatch: exit 5, nothing written
printf '{"chain_id":"%s"}' "$(printf 'other' | H)" > "$TMP/info-bad.json"
rc="$(FX_INFO="$TMP/info-bad.json" run_archive --from-file="$FX/history.jsonl" --out-dir="$TMP/out-badchain")"
check "wrong chain_id: exit 5" 5 "$rc"
check "wrong chain_id: no archive file written" 0 "$( (ls "$TMP/out-badchain" 2>/dev/null || true) | grep -c json)"

# 6. one tx unresolvable: others archived, exit 3
mv "$FX/hist-$TX2.json" "$TMP/hist2.parked"
rc="$(run_archive --from-file="$FX/history.jsonl" --out-dir="$TMP/out-partial")"
check "one tx not served: exit 3" 3 "$rc"
check "the other tx is still archived" "yes" "$([ -f "$TMP/out-partial/$TX1.json" ] && echo yes || echo no)"
check "the failed tx has no file" "no" "$([ -f "$TMP/out-partial/$TX2.json" ] && echo yes || echo no)"
mv "$TMP/hist2.parked" "$FX/hist-$TX2.json"

# 7. history/block disagreement is refused
cp "$FX/block-100.json" "$TMP/block100.orig"
sed 's/"block_num":100/"block_num":101/' "$TMP/block100.orig" > "$FX/block-100.json"
rc="$(run_archive --from-file="$FX/history.jsonl" --out-dir="$TMP/out-mismatch")"
check "block response for a different block: exit 3" 3 "$rc"
check "block mismatch: no file for that tx" "no" "$([ -f "$TMP/out-mismatch/$TX1.json" ] && echo yes || echo no)"
cp "$TMP/block100.orig" "$FX/block-100.json"

# 7b. ledger block_num that the history response contradicts is refused
sed "s/\"block_num\":100,/\"block_num\":99,/" "$FX/history.jsonl" > "$TMP/history-wrongblock.jsonl"
cp "$FX/block-100.json" "$FX/block-99.json"
sed -i.bak 's/"block_num":100/"block_num":99/' "$FX/block-99.json" && rm "$FX/block-99.json.bak"
rc="$(run_archive --from-file="$TMP/history-wrongblock.jsonl" --out-dir="$TMP/out-wrongblock")"
check "ledger block_num contradicted by history response: exit 3" 3 "$rc"
check "contradicted tx has no file" "no" "$([ -f "$TMP/out-wrongblock/$TX1.json" ] && echo yes || echo no)"

# 8. --from-site reads the ledger over HTTP
rc="$(run_archive --from-site=https://site.test --out-dir="$TMP/out-site")"
check "--from-site run exits 0" 0 "$rc"
check "--from-site fetched /api/anchor-history.jsonl" 1 "$(grep -c 'GET https://site.test/api/anchor-history.jsonl' "$LOG")"

# 9. static: the archiver never names a push/send endpoint or proton-cli
check "archiver source has no push/send endpoint or proton-cli" 0 \
	"$(grep -Ec 'push_transaction|send_transaction|/v1/chain/push|/v1/chain/send|/ext/bc|proton[ -]|transaction:push|cleos' "$ARCHIVER")"
check "verifier source makes no network call" 0 "$(grep -Ec '(^|[^a-z_])(curl|wget)[ ]' "$VERIFIER")"

# --- verifier ----------------------------------------------------------------
verify() { "$VERIFIER" --archive-dir="$OUT" --history="$FX/history.jsonl" "$@" >"$TMP/v.out" 2>"$TMP/v.err"; echo $?; }
check "verifier accepts the archive" 0 "$(verify)"
check "verifier accepts the archive with receipts" 0 "$(verify --receipts-dir="$FX/receipts")"
check "verifier reports the anchor count" "VERIFIED 2 anchor(s)" "$(tail -n1 "$TMP/v.out")"

# rebuild a consistent (re-hashed) tampered archive so ONLY the semantic check can catch it
retamper() { # <jq filter on the history body>
	local f="$OUT/$TX1.json" body newb hs
	rm -rf "${TMP:?}/out-t"
	cp -R "$OUT" "$TMP/out-t"
	body="$(jq -j '.history_body' "$f")"
	newb="$(printf '%s' "$body" | jq -c "$1")"
	hs="$(printf '%s' "$newb" | H)"
	jq --arg b "$newb" --arg h "$hs" '.history_body=$b | .history_sha256=$h' "$f" > "$TMP/out-t/$TX1.json"
	jq --arg t "$TX1" --arg h "$hs" --arg s "$(H < "$TMP/out-t/$TX1.json")" \
		'(.entries[] | select(.tx_id==$t)) |= (.history_sha256=$h | .sha256=$s)' "$OUT/manifest.json" > "$TMP/out-t/manifest.json"
}
vt() { "$VERIFIER" --archive-dir="$TMP/out-t" --history="$FX/history.jsonl" >"$TMP/v.out" 2>"$TMP/v.err"; echo $?; }

# body order is id, ob, ar, dag — index 0 is the -id memo
retamper '.actions[0].act.data.memo |= sub("fya1c1-id:.*"; "fya1c1-id:" + ("0" * 64))'
check "verifier rejects a swapped id memo (dag_root != sha256(id||ob||ar))" 1 "$(vt)"
retamper '.actions[1].act.authorization[0].actor = "someoneelse"'
check "verifier rejects a wrong actor" 1 "$(vt)"
retamper 'del(.actions[3])'
check "verifier rejects a 3-action tx" 1 "$(vt)"
retamper '.actions[2].act.name = "issue"'
check "verifier rejects a non-transfer action" 1 "$(vt)"
retamper '.actions |= map(.block_num = 101)'
check "verifier rejects a block_num that differs from the ledger" 1 "$(vt)"
retamper '.actions[0].act.data.memo |= sub("fya1c1"; "fya9c9")'
check "verifier rejects a memo with the wrong prefix" 1 "$(vt)"
retamper '.'
check "control: an untouched re-hashed archive still passes" 0 "$(vt)"

# receipts: memos consistent with the archive but the receipt disagrees
cp -R "$FX/receipts" "$TMP/rc"
jq '.anchor.actions[0].memo = "fya1c1-id:" + ("f" * 64)' "$TMP/rc/anchor-receipt-$TX1.json" > "$TMP/rc.tmp" && mv "$TMP/rc.tmp" "$TMP/rc/anchor-receipt-$TX1.json"
check "verifier rejects memos that differ from the receipt" 1 "$(verify --receipts-dir="$TMP/rc")"
mv "$TMP/rc/anchor-receipt-$TX2.json" "$TMP/rc-parked.json"
check "verifier fails when a receipt is missing under --receipts-dir" 1 "$(verify --receipts-dir="$TMP/rc")"

# file / manifest integrity
cp "$OUT/$TX2.json" "$TMP/tx2.saved"
sed 's/eosio.token/eosio.tokeN/' "$TMP/tx2.saved" > "$OUT/$TX2.json"
check "verifier rejects a file whose sha256 differs from the manifest" 1 "$(verify)"
mv "$OUT/$TX2.json" "$TMP/tx2.parked"
check "verifier rejects a missing archive file" 1 "$(verify)"
cp "$TMP/tx2.saved" "$OUT/$TX2.json"
cp "$OUT/manifest.json" "$TMP/manifest.saved"
jq --arg t "$TX2" '.entries |= map(select(.tx_id != $t))' "$TMP/manifest.saved" > "$OUT/manifest.json"
check "verifier rejects a tx with no manifest entry" 1 "$(verify)"
cp "$TMP/manifest.saved" "$OUT/manifest.json"
# body edited (and the file re-hashed into the manifest) without updating the recorded body hash
cp "$OUT/$TX1.json" "$TMP/tx1.saved2"
jq '.block_body |= sub("\"id\":\"[a-f0-9]{4}"; "\"id\":\"0000")' "$TMP/tx1.saved2" > "$OUT/$TX1.json"
jq --arg t "$TX1" --arg s "$(H < "$OUT/$TX1.json")" '(.entries[]|select(.tx_id==$t)).sha256=$s' "$TMP/manifest.saved" > "$OUT/manifest.json"
check "verifier rejects a body that no longer matches its recorded hash" 1 "$(verify)"
cp "$TMP/tx1.saved2" "$OUT/$TX1.json"; cp "$TMP/manifest.saved" "$OUT/manifest.json"
# recorded history body edited while the file is re-hashed into the manifest
jq '.history_body |= sub("\"lib\": 999"; "\"lib\": 998")' "$TMP/tx1.saved2" > "$OUT/$TX1.json"
jq --arg t "$TX1" --arg s "$(H < "$OUT/$TX1.json")" '(.entries[]|select(.tx_id==$t)).sha256=$s' "$TMP/manifest.saved" > "$OUT/manifest.json"
check "verifier rejects a history body that no longer matches its recorded hash" 1 "$(verify)"
# envelope block_id altered (file re-hashed into the manifest; manifest and block body keep the real id)
jq '.block_id = ("0" * 64)' "$TMP/tx1.saved2" > "$OUT/$TX1.json"
jq --arg t "$TX1" --arg s "$(H < "$OUT/$TX1.json")" '(.entries[]|select(.tx_id==$t)) |= (.sha256=$s)' "$TMP/manifest.saved" > "$OUT/manifest.json"
check "verifier rejects a block_id that the block body does not carry" 1 "$(verify)"
cp "$TMP/tx1.saved2" "$OUT/$TX1.json"; cp "$TMP/manifest.saved" "$OUT/manifest.json"
check "verifier passes again after restoring" 0 "$(verify)"
check "verifier: missing history file is a usage error" 2 "$("$VERIFIER" --archive-dir="$OUT" --history="$TMP/none.jsonl" >/dev/null 2>&1; echo $?)"

echo "----"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
