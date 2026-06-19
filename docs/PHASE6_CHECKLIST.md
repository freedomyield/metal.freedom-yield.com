# Phase 6 execution checklist

One-page checklist for the chain-anchor embed at the next renewal
cycle. Sibling to [`PHASE5_CHECKLIST.md`](./PHASE5_CHECKLIST.md);
teaching reference is the "Phase 5 → Phase 6 hand-off" section in
[`OPERATOR_IDENTITY_SETUP.md`](./OPERATOR_IDENTITY_SETUP.md); verifier
recipe is in [`IDENTITY_VERIFICATION.md`](./IDENTITY_VERIFICATION.md).

Total wall-clock estimate: **~30–45 min** spread across pre-flight
(days before the cycle ends), the renewal moment, and the post-tx
manifest refresh.

## When this runs

Phase 6 runs at every renewal cycle once Phase 5 has landed. The
first execution is **2026-07-04 13:00 JST (04:00 UTC)** — the cycle 2
→ cycle 3 boundary. Repeat the same flow at every subsequent renewal;
the only thing that changes cycle-over-cycle is the new `tx_id`.

Phase 6 has no validator-host gate — it depends only on Phase 5
already being live and the operator's regular cycle-end renewal
operation. If Phase 5 has not landed, do not run Phase 6.

## A. Pre-flight (1–2 days before renewal)

```sh
# A1. Confirm Phase 5 surfaces are still live and consistent. All three
# must return 200; identity.json must validate against the live formal
# schema; signature must verify.
curl -sSI https://metal.freedom-yield.com/api/identity.json       | head -1
curl -sSI https://metal.freedom-yield.com/api/identity.json.sig   | head -1
curl -sSI https://metal.freedom-yield.com/.well-known/operator-identity.pub | head -1
# Expect three HTTP/2 200 lines.

# A2. Snapshot the live .pub bytes as the verifier would fetch them.
# Same exact byte sequence (no CRLF rewrite / trailing newline strip)
# must reach the chain memo, or every verifier mismatch silently.
curl -sS https://metal.freedom-yield.com/.well-known/operator-identity.pub \
  > /tmp/live-operator-identity.pub
wc -c /tmp/live-operator-identity.pub
xxd /tmp/live-operator-identity.pub | tail -1
LIVE_HEX64=$(shasum -a 256 /tmp/live-operator-identity.pub | awk '{print $1}')
echo "live shasum: ${LIVE_HEX64}"
```

Compare the printed `LIVE_HEX64` value to the **B4 value** recorded in
the password manager at Phase 5 § B (the chain memo binding hash).
They must match. If they differ, the published `.pub` has been
altered server-side; do not embed a memo against a drifted hash —
fix the publication first (re-deploy the local `.pub`, check nginx
mime + line ending policy), then re-snapshot.

```sh
# A3. Sanity-check that gen-identity.sh accepts the override env var
# without breaking — run a synthetic harness pass before the real cycle.
bash scripts/operator-local/test-gen-identity.sh
# Expect: PASS: gen-identity.sh Phase 3 Merkle DAG output is internally consistent
```

If A1 / A2 / A3 all pass, the chain anchor is safe to embed at the
renewal moment. Print or note the `LIVE_HEX64` value somewhere you
can read it during the wallet UI step (do not type it from memory).

## B. The renewal moment (2026-07-04 13:00 JST / 04:00 UTC)

Cycle 2 ends at this moment. Within roughly the next 5 minutes, the
operator composes the cycle 3 `AddPermissionlessValidatorTx` from the
existing wallet (Wallet 2 — Metal Wallet web). Quick reminders about
the Add Validator form layout (verified against the live UI):

- **BLS Proof of Possession** is split into two separate fields:
  `publicKey` and `signature`. Paste each into its matching field.
- **Start Date** has no input — it is auto-set to submission time +
  5 minutes.
- **End Date** is a date picker; set it for the next renewal cycle's
  boundary using the renewal calendar.

```text
B1. Open Metal Wallet web → Add Validator.
B2. Fill NodeID, BLS PoP fields, start/end as usual for renewal.
B3. In the Memo field, paste exactly (no surrounding spaces / quotes):

      identity-v1:sha256:<LIVE_HEX64>

    where <LIVE_HEX64> is the 64 lowercase hex characters from A2.
    Example shape (NOT the real value):
      identity-v1:sha256:0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f7081920a1b2c
B4. Review the entire form once. Submit.
B5. From the submission confirmation, copy the new tx_id (64-hex).
    Save it to the password manager next to the cycle 3 entry.
```

Common mis-paste at B3: a trailing newline in the memo. Some wallet
forms strip them, some don't. After submission, before celebrating,
hit the explorer URL and confirm the memo field reads exactly
`identity-v1:sha256:<the 64 hex chars you intended>` with no trailing
whitespace.

## C. Refresh the manifest with the real tx_id (~5 min)

```sh
export OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity
export CHAIN_ANCHOR_TX_ID=<the 64-hex tx_id from B5>
bash scripts/operator-local/gen-identity.sh
```

Expected tail — note the `chain_anchor:` line is no longer the
placeholder:

```
✓ wrote .../public/api/identity.json
✓ wrote .../public/api/identity.json.sig
  fingerprint:     SHA256:<your B3 manifest fingerprint>
  ...
  chain_anchor:    <the same 64-hex tx_id you passed>
```

If `chain_anchor:` line still says `placeholder (all-zeros)`, the env
var did not propagate — re-export and rerun.

## D. Commit + push (~3 min)

```sh
git diff -- public/api/identity.json | head -30
# Expect the chain_anchor.tx_id field to flip from 0000... to the new value.

git add public/api/identity.json public/api/identity.json.sig
git commit -m "chore(identity): bind chain_anchor to cycle 3 renewal tx"
git push origin main
```

## E. Live-verify the chain binding (~5 min)

After deploy, run the full seven-step recipe from
[`IDENTITY_VERIFICATION.md`](./IDENTITY_VERIFICATION.md). Step 1
(chain memo) and Step 2 (extract `EXPECTED_FP` from the memo) must
now actually complete — pre-Phase-6 they were skipped because the
anchor was a placeholder. The end-to-end summary line:

```sh
# All seven steps in one paste-able block:
NODE_ID="NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
EXPLORER_API="https://explorer.metalblockchain.org/api"

MEMO=$(curl -sS "${EXPLORER_API}/validator/${NODE_ID}/latest-tx" | jq -r .memo)
EXPECTED_FP="${MEMO#identity-v1:sha256:}"
curl -sS https://metal.freedom-yield.com/.well-known/operator-identity.pub > /tmp/pub
LIVE_FP=$(shasum -a 256 /tmp/pub | awk '{print $1}')
[ "$LIVE_FP" = "$EXPECTED_FP" ] && echo "OK chain-anchor↔pubkey"

curl -sS https://metal.freedom-yield.com/api/identity.json > /tmp/id.json
curl -sS https://metal.freedom-yield.com/api/identity.json.sig > /tmp/id.sig
printf 'freedom-yield %s\n' "$(cat /tmp/pub)" > /tmp/allowed
ssh-keygen -Y verify -f /tmp/allowed -I freedom-yield \
  -n freedom-yield/validator-identity \
  -s /tmp/id.sig < /tmp/id.json \
  && echo "OK signature"
```

Two `OK` lines = the four-layer Merkle DAG anchor is fully bound.
The validator is now chain-anchored.

## Failure decision tree

| Symptom | Action |
| --- | --- |
| A1: any of three 404 | Phase 5 is broken; abort, fix Phase 5 first |
| A2: live shasum ≠ B4 record | `.pub` bytes drifted server-side; fix publication, re-snapshot, do NOT embed memo against stale hash |
| A3: test-gen-identity.sh FAIL | Toolchain regress; investigate before touching real key |
| B3 paste error | Caught at B5 explorer check; if memo wrong on-chain, **do not** "fix" by re-submitting — the original tx is on-chain forever. Submit a corrective tx in the next cycle (= chain anchor is bound to the NEXT cycle, this one stays placeholder-equivalent) |
| C: chain_anchor still all-zeros | env var did not propagate; re-export, rerun |
| D: GitHub Actions red | Allowlist drift; fix and push again, do NOT amend |
| E: `FAIL chain-anchor↔pubkey` | Memo and live `.pub` shasum mismatch — either pub was rewritten or memo was wrong; compare bytes, decide whether to rollback C/D and wait for next cycle |
| E: `FAIL signature` | Live identity.json or .sig was rewritten; rollback |

## Rollback

To revert just the chain_anchor refresh (keeping Phase 5 surfaces
live):

```sh
git revert HEAD     # the cycle 3 chain-bind commit
git push origin main
```

After the next deploy, `identity.json.chain_anchor.tx_id` returns to
all-zeros. The Phase 5 signature still verifies; the trust ceiling
just drops back to "signed by whoever holds the operator identity
private key" (= off-chain). Re-attempt at the next cycle boundary.

## Per-cycle repetition

Phase 6 is not a one-time event. Run sections A → E **every** renewal
cycle. The only inputs that change cycle-over-cycle are:

- `CHAIN_ANCHOR_TX_ID` — the new cycle's tx_id (B5 → C)
- `chain_anchor.explorer_url` — derived automatically by gen-identity.sh

The `.pub` bytes, the `LIVE_HEX64`, the manifest fingerprint, and the
memo prefix all stay constant for the lifetime of the operator
identity key. They only change if the operator rotates the key
(separate Phase 7-class procedure — out of scope here).
