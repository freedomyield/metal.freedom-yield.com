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
# ---------------------------------------------------------------------------
# SELF / FEE SPLIT BY RELATIVE OutputIndex (added 2026-09-07)
# ---------------------------------------------------------------------------
# reward-tracker.sh originally recorded one combined reward_metal because the
# ABSOLUTE OutputIndex of each reward output depends on the original
# AddValidatorTx's own output/stake count, which this repo never decodes.
# The split below needs only the RELATIVE order, which is fixed by
# vms/platformvm/txs/executor/proposal_tx_executor.go rewardValidatorTx()
# (fetched from https://github.com/MetalBlockchain/metalgo master on
# 2026-09-07 — read, not assumed):
#
#   K := len(outputs) + len(stake)          (the unknown absolute base)
#   COMMIT (uptime met):
#     if PotentialReward > 0:  self  UTXO at index K         (utxosOffset++)
#     if delegateeReward > 0:  fee   UTXO at index K+offset  (= K+1 when both)
#   ABORT (uptime missed):
#     validator reward NOT paid; if delegateeReward > 0:
#                              fee   UTXO at index K  ("no [offset] if the
#                              RewardValidatorTx is aborted")
#
# Consequences this lib encodes, and nothing more:
#   2 UTXOs at consecutive indices  -> lower = self, higher = fee. Only the
#                                      commit path can produce two outputs.
#   1 UTXO                          -> AMBIGUOUS by shape alone: commit-with-
#                                      no-fee (self) and abort-with-fee (fee)
#                                      both put one output at index K. It is
#                                      decidable only against the validator's
#                                      PotentialReward, which the commit path
#                                      pays EXACTLY (`reward :=
#                                      validator.PotentialReward`): equal ->
#                                      self; different -> the abort-path fee
#                                      output. platform.getCurrentValidators
#                                      exposes that value as `potentialReward`
#                                      while the tx is current; reward-
#                                      tracker.sh records it in its in-flight
#                                      state for exactly this comparison.
#                                      Without the hint the split is REFUSED.
#   0 UTXOs                         -> self 0 / fee 0, known (nothing paid).
#   3+ UTXOs, a gap, a duplicate
#   index, an undecodable blob,
#   or a hint the lower output
#   contradicts                     -> split REFUSED (total still summed).
#                                      No shape the cited source produces
#                                      looks like this; do not guess.
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

# reward_utxo__checked_hex <caller> <hex_utxo>
#   Shared header validation for every decoder below: strips an optional
#   0x/0X prefix, refuses non-hex, refuses a blob too short to reach the end
#   of Amt, refuses any Out type ID other than 7. Prints the normalized hex
#   on success. Exit codes are the decoders' documented 1 / 2 / 3. The
#   type-ID guard applies to the OutputIndex decoder too, even though the
#   index lives before the type tag: a blob whose output is not a
#   secp256k1fx.TransferOutput is not a reward UTXO this lib understands,
#   and the self/fee split must not order outputs it would refuse to sum.
reward_utxo__checked_hex() {
	local caller="$1" hex="$2"
	hex="${hex#0x}"
	hex="${hex#0X}"
	if ! [[ "$hex" =~ ^[0-9a-fA-F]*$ ]]; then
		echo "${caller}: not a hex string" >&2
		return 1
	fi
	# 82 bytes = 164 hex chars is the minimum to reach the end of Amt.
	if [ "${#hex}" -lt 164 ]; then
		echo "${caller}: too short (${#hex} hex chars, need >= 164) to hold TxID+OutputIndex+AssetID+TypeID+Amt" >&2
		return 2
	fi

	# Out type ID: hex chars [140,148) = bytes [70,74).
	local type_id_hex="${hex:140:8}"
	local type_id=$((16#${type_id_hex}))
	if [ "$type_id" -ne 7 ]; then
		echo "${caller}: unsupported Out type ID ${type_id} (expected 7 = secp256k1fx.TransferOutput) — refusing to guess an amount" >&2
		return 3
	fi
	printf '%s\n' "$hex"
	return 0
}

# decode_reward_utxo_output_index <hex_utxo>
#   Prints the UTXO's UTXOID.OutputIndex (uint32, decimal) to stdout. Same
#   input rules and exit codes as decode_reward_utxo_nmetal (usage 1 / too
#   short 2 / wrong type 3). Offset: hex chars [68,76) = bytes [34,38) —
#   see the BYTE LAYOUT table in this file's header.
decode_reward_utxo_output_index() {
	if [ "$#" -ne 1 ]; then
		echo "decode_reward_utxo_output_index: usage: decode_reward_utxo_output_index <hex_utxo>" >&2
		return 1
	fi
	local hex
	hex="$(reward_utxo__checked_hex "decode_reward_utxo_output_index" "$1")" || return $?
	local idx_hex="${hex:68:8}"
	echo $((16#${idx_hex}))
	return 0
}

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
	local hex
	hex="$(reward_utxo__checked_hex "decode_reward_utxo_nmetal" "$1")" || return $?

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

# reward_utxo__nmetal_to_metal <nmetal_int> — "W.FFFFFFFFF" fixed 9 places.
reward_utxo__nmetal_to_metal() {
	printf '%d.%09d\n' "$(($1 / 1000000000))" "$(($1 % 1000000000))"
}

# split_reward_utxos_metal [potential_reward_nmetal] [--assert-no-delegators]
#   Reads hex UTXO strings, one per line, from stdin (same input contract as
#   sum_reward_utxos_metal) and prints ONE line:
#
#       <total_metal> <self_metal> <fee_metal> <known> <basis>
#
#   known=1: self/fee are 9-place METAL strings and self+fee == total.
#   known=0: self/fee are the literal "-" — the split was REFUSED; total is
#            still the (possibly partial) sum, exactly what
#            sum_reward_utxos_metal would have printed.
#   basis:   ONE token naming the evidence the split rests on (recorded in
#            the ledger row as split_basis — evidence-based discipline):
#              zero-outputs                  n=0, self 0 / fee 0
#              utxo-order                    n=2 adjacent, no hint
#              utxo-order+potential-reward   n=2 adjacent, lower == hint
#              potential-reward-match        n=1, == hint  -> self
#              potential-reward-mismatch     n=1, != hint  -> fee (abort)
#              operator-asserted-no-delegators
#                                            n=1, no hint, --assert-no-
#                                            delegators given -> self. The
#                                            CALLER must still apply a
#                                            magnitude sanity check before
#                                            recording this (see reward-
#                                            tracker.sh --backfill).
#            and for known=0, "refused:<reason>" with reason one of
#              undecodable / single-no-hint / nonadjacent / too-many /
#              hint-contradicted / no-delegators-contradicted.
#
#   The decision table is the "SELF / FEE SPLIT" block in this file's header
#   — every branch below is one row of it, nothing is inferred beyond what
#   rewardValidatorTx() is cited as doing. The first optional argument is
#   the validator's PotentialReward in nMETAL (metalgo's `potentialReward`
#   field); a non-integer argument is treated as absent (with a stderr
#   note), never as a value to compare against.
#
#   --assert-no-delegators (2026-09-07): the caller vouches that NO
#   delegation existed during the cycle, so delegateeReward == 0. From the
#   cited source that leaves exactly two shapes: commit -> ONE self output;
#   abort -> ZERO outputs (`if delegateeReward == 0 { return nil }` runs
#   after the validator-reward block, so no fee output can exist). Hence
#   under the flag one output IS the self reward, and two or more outputs
#   PROVE the assertion false — refused, never partially honoured. A hint,
#   when also given, still takes precedence (it is chain evidence; the
#   flag is operator testimony).
#
#   Always returns 0 — "refused" is a data outcome (known=0), not an error;
#   a caller that cannot read the line at all sees an empty stdout only if
#   this function was never reached.
split_reward_utxos_metal() {
	local hint="" no_delegators=0 a
	for a in "$@"; do
		case "$a" in
			--assert-no-delegators) no_delegators=1 ;;
			*) hint="$a" ;;
		esac
	done
	if [ -n "$hint" ] && ! [[ "$hint" =~ ^[0-9]+$ ]]; then
		echo "split_reward_utxos_metal: potential_reward_nmetal is not an unsigned integer — treating the hint as absent" >&2
		hint=""
	fi

	local line n=0 refused=0 total_n=0
	local -a idxs=() amts=()
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		local amt idx
		if amt="$(decode_reward_utxo_nmetal "$line")" \
			&& idx="$(decode_reward_utxo_output_index "$line" 2>/dev/null)"; then
			total_n=$((total_n + amt))
			idxs+=("$idx")
			amts+=("$amt")
			n=$((n + 1))
		else
			refused=1
			echo "split_reward_utxos_metal: skipped one undecodable UTXO — split refused, total is partial" >&2
		fi
	done

	local total self fee known=0 basis="refused:undecodable"
	total="$(reward_utxo__nmetal_to_metal "$total_n")"
	self="-"
	fee="-"

	if [ "$refused" -eq 0 ]; then
		case "$n" in
			0)
				self="$(reward_utxo__nmetal_to_metal 0)"
				fee="$self"
				known=1
				basis="zero-outputs"
				;;
			1)
				if [ -n "$hint" ]; then
					if [ "${amts[0]}" = "$hint" ]; then
						# commit path, no delegatee reward: the one output IS the
						# validator's own PotentialReward.
						self="$(reward_utxo__nmetal_to_metal "${amts[0]}")"
						fee="$(reward_utxo__nmetal_to_metal 0)"
						basis="potential-reward-match"
						known=1
					elif [ "$no_delegators" -eq 1 ]; then
						# The operator says no delegators, the chain says this is
						# not the self reward: the two cannot both hold. Refuse.
						echo "split_reward_utxos_metal: single output does not equal potentialReward while --assert-no-delegators is set — contradiction, split refused" >&2
						basis="refused:hint-contradicted"
					else
						# abort path: the validator reward is not paid; the only
						# output the cited source can emit is the delegatee cut.
						self="$(reward_utxo__nmetal_to_metal 0)"
						fee="$(reward_utxo__nmetal_to_metal "${amts[0]}")"
						basis="potential-reward-mismatch"
						known=1
					fi
				elif [ "$no_delegators" -eq 1 ]; then
					self="$(reward_utxo__nmetal_to_metal "${amts[0]}")"
					fee="$(reward_utxo__nmetal_to_metal 0)"
					basis="operator-asserted-no-delegators"
					known=1
				else
					basis="refused:single-no-hint"
				fi
				;;
			2)
				if [ "$no_delegators" -eq 1 ]; then
					echo "split_reward_utxos_metal: two outputs contradict --assert-no-delegators (a fee output exists) — split refused" >&2
					basis="refused:no-delegators-contradicted"
				else
					local lo_idx hi_idx lo_amt hi_amt
					if [ "${idxs[0]}" -le "${idxs[1]}" ]; then
						lo_idx="${idxs[0]}"; lo_amt="${amts[0]}"
						hi_idx="${idxs[1]}"; hi_amt="${amts[1]}"
					else
						lo_idx="${idxs[1]}"; lo_amt="${amts[1]}"
						hi_idx="${idxs[0]}"; hi_amt="${amts[0]}"
					fi
					if [ "$((hi_idx - lo_idx))" -ne 1 ]; then
						echo "split_reward_utxos_metal: two outputs at non-consecutive indices — not the commit-path self+fee pair, split refused" >&2
						basis="refused:nonadjacent"
					elif [ -n "$hint" ] && [ "$lo_amt" != "$hint" ]; then
						echo "split_reward_utxos_metal: lower output does not equal the recorded potentialReward — split refused" >&2
						basis="refused:hint-contradicted"
					else
						self="$(reward_utxo__nmetal_to_metal "$lo_amt")"
						fee="$(reward_utxo__nmetal_to_metal "$hi_amt")"
						known=1
						if [ -n "$hint" ]; then basis="utxo-order+potential-reward"; else basis="utxo-order"; fi
					fi
				fi
				;;
			*)
				if [ "$no_delegators" -eq 1 ]; then
					echo "split_reward_utxos_metal: ${n} outputs contradict --assert-no-delegators — split refused" >&2
					basis="refused:no-delegators-contradicted"
				else
					echo "split_reward_utxos_metal: ${n} reward outputs — the cited source emits at most two, split refused" >&2
					basis="refused:too-many"
				fi
				;;
		esac
	fi

	printf '%s %s %s %d %s\n' "$total" "$self" "$fee" "$known" "$basis"
	return 0
}
