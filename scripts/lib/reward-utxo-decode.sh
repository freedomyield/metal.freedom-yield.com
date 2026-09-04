#!/usr/bin/env bash
# scripts/lib/reward-utxo-decode.sh — decode_reward_utxo_nmetal(), a pure
# decoder for the hex-encoded UTXO blobs `platform.getRewardUTXOs` returns.
#
# CHAIN: none — pure decoding of already-fetched bytes. No curl, no RPC, no
#        broadcast. reward-tracker.sh is the only caller that talks to a
#        node; this file only interprets what that call already returned.
#
# ---------------------------------------------------------------------------
# WHY A HAND-ROLLED DECODER
# ---------------------------------------------------------------------------
# `platform.getRewardUTXOs` is documented in metalgo's own service.go as a
# "deprecated API". Its response is NOT parsed JSON — it is an array of
# whole UTXOs, each serialized with metalgo's linear codec and then
# hex/cb58-encoded into an opaque string (`reply.UTXOs[]`). There is no
# `amount` field to read with jq; the amount is a fixed byte offset inside
# each blob. This file requests (and only supports) `encoding:"hex"` — see
# reward-tracker.sh's curl call — which sidesteps CB58's base58+checksum
# framing entirely; the hex string need only have its optional "0x" prefix
# stripped.
#
# BYTE LAYOUT (verified against metalgo source, fetched 2026-09-04, NOT
# guessed from generic Avalanche docs — every offset below traces to a
# specific struct in the actual repo this validator's node runs):
#
#   offset  bytes  field                          source
#   ------  -----  -----------------------------  --------------------------
#   0       2      codec version (must be 0x0000)  codec.Manager.Marshal
#   2       32     UTXOID.TxID                     vms/components/avax/utxo_id.go
#   34      4      UTXOID.OutputIndex (uint32 BE)   "
#   38      32     Asset.ID                         vms/components/avax/asset.go
#   70      4      Out type ID (uint32 BE)          codec interface tag
#   74      8      TransferOutput.Amt (uint64 BE)   vms/secp256k1fx/transfer_output.go
#   82      8      OutputOwners.Locktime            vms/secp256k1fx/output_owners.go
#   90      4      OutputOwners.Threshold
#   94      4      len(OutputOwners.Addrs)
#   98      20*N   OutputOwners.Addrs
#
#   This decoder reads ONLY through offset 82 (TxID, OutputIndex, AssetID,
#   type tag, Amt) — everything after Amt (locktime/threshold/addresses) is
#   irrelevant to "how much METAL did this UTXO carry" and is not parsed.
#
#   TYPE-ID CHECK IS NOT OPTIONAL. The out-type tag at offset 70 must equal
#   7 (secp256k1fx.TransferOutput's registration slot in
#   vms/platformvm/txs/codec.go's RegisterApricotTypes — traced by hand from
#   that file's registration order, not assumed). A reward UTXO is always a
#   freshly created TransferOutput (both the self-reward output and the
#   accrued-delegatee-reward output in
#   vms/platformvm/txs/executor/proposal_tx_executor.go's rewardValidatorTx()
#   are built via `Fx.CreateOutput`, which for a plain reward always returns
#   this type — never a StakeableLockOut). If a future upgrade ever changes
#   that, THIS DECODER MUST REFUSE rather than misparse a locked-output's
#   bytes as if they were Amt — a wrong type silently read at a fixed offset
#   would print a plausible-looking but wrong number, and this repo's
#   numeric-integrity discipline treats a wrong number as worse than no
#   number. See decode_reward_utxo_nmetal's exit code 3.
#
# ---------------------------------------------------------------------------

# decode_reward_utxo_nmetal <hex_utxo>
#   Prints the UTXO's amount in nMETAL (integer) to stdout. <hex_utxo> may
#   carry an optional "0x" prefix (metalgo's hex encoding includes one; this
#   accepts either form so a test fixture need not care).
#
#   Exit codes:
#     0  printed an amount
#     1  usage error (no argument, or argument is not a hex string)
#     2  too short to contain a full fixed-offset header (< 82 bytes / 164
#        hex chars after stripping "0x") — refuses rather than pad/guess
#     3  Out type ID != 7 (secp256k1fx.TransferOutput) — refuses rather than
#        misread a different output shape's bytes as Amt
decode_reward_utxo_nmetal() {
	if [ "$#" -ne 1 ]; then
		echo "decode_reward_utxo_nmetal: usage: decode_reward_utxo_nmetal <hex_utxo>" >&2
		return 1
	fi
	local hex="$1"
	hex="${hex#0x}"
	hex="${hex#0X}"
	if ! [[ "$hex" =~ ^[0-9a-fA-F]*$ ]]; then
		echo "decode_reward_utxo_nmetal: not a hex string" >&2
		return 1
	fi
	# 82 bytes = 164 hex chars is the minimum to reach the end of Amt.
	if [ "${#hex}" -lt 164 ]; then
		echo "decode_reward_utxo_nmetal: too short (${#hex} hex chars, need >= 164) to hold TxID+OutputIndex+AssetID+TypeID+Amt" >&2
		return 2
	fi

	# Out type ID: hex chars [140,148) = bytes [70,74).
	local type_id_hex="${hex:140:8}"
	local type_id=$((16#${type_id_hex}))
	if [ "$type_id" -ne 7 ]; then
		echo "decode_reward_utxo_nmetal: unsupported Out type ID ${type_id} (expected 7 = secp256k1fx.TransferOutput) — refusing to guess an amount" >&2
		return 3
	fi

	# Amt: hex chars [148,164) = bytes [74,82), uint64 big-endian.
	local amt_hex="${hex:148:16}"
	# bash arithmetic ($(( 16#... ))) is only safe up to 63 unsigned bits on
	# a 64-bit build; nMETAL amounts here are far below that (max supply is
	# 666,666,666 * 1e9 ≈ 6.7e17, comfortably inside int64), so this is safe
	# for every value this decoder will ever see. python3 is intentionally
	# NOT invoked here — hex-to-decimal of a bounded 8-byte value needs no
	# arbitrary-precision engine, and skipping the subprocess keeps this
	# fast when reward-tracker.sh calls it once per UTXO in a loop.
	echo $((16#${amt_hex}))
	return 0
}

# sum_reward_utxos_metal
#   Reads hex UTXO strings, one per line, from stdin. Prints the total
#   amount in METAL (9 decimal places) to stdout. A line that
#   decode_reward_utxo_nmetal refuses (wrong type, too short) is SKIPPED
#   with a warning on stderr and does NOT abort the sum — a reward event
#   with one decodable UTXO and one unexpected one should still report the
#   decodable part rather than nothing (fail-loud-but-partial, not
#   fail-silent-total). Blank lines are ignored. Prints "0.000000000" for
#   empty input (no UTXOs = no reward, which is a legitimate outcome, e.g.
#   an uptime-miss cycle).
sum_reward_utxos_metal() {
	local line total_n=0 rc=0 any_hit=0
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		local amt
		if amt="$(decode_reward_utxo_nmetal "$line")"; then
			total_n=$((total_n + amt))
			any_hit=1
		else
			rc=$?
			echo "sum_reward_utxos_metal: skipped one UTXO (decode rc=${rc})" >&2
		fi
	done
	local whole=$((total_n / 1000000000))
	local frac=$((total_n % 1000000000))
	printf '%d.%09d\n' "$whole" "$frac"
	[ "$any_hit" -eq 1 ] || return 0
	return 0
}
