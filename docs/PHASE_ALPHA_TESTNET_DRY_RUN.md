# Phase α testnet rehearsal runbook (v2)

> **Supersedes v1.** Everything below this line reflects the **v2 HC-single
> 4-action pack pipeline** (`scripts/sign-anchor-event.sh` v2 +
> `bin/safe-broadcast` + `scripts/gen-anchor-receipt.sh` v2), current as of
> the 2026-07-31 cycle-4 testnet-rehearsal repair. The v1 revision of this
> document (single memo `fyid1:<hex>`, direct `sign-anchor-event.sh
> cyclestart <hex>` CLI, a retired `cycles-history.json` schema, the
> `anchor-receipt.schema.v1.json` shape, and a manual O1–O10 proton-cli
> output-parser observation checklist) described the pipeline in place
> **before 2026-07-01**. On that date an accidental mainnet inscription of
> memo `fyid1v1c2-test-single` (tx `997881e844befaf9c159c741988fe99e8ca566a52e539639ab83517b1f36100a`,
> see Constitution PRIME DIRECTIVE rationale) permanently occupied the v1
> memo namespace — the PRIME DIRECTIVE was written into the Constitution
> and this v1 pipeline was retired the SAME day, in direct response. None
> of the v1 steps below should be followed;
> they are retained nowhere in this file. The O1–O10 checklist is not
> carried forward either — v2's `gen-anchor-receipt.sh` 7-gate (§"Pass
> criteria" below) independently re-derives every field from the chain
> itself, structurally replacing that manual checklist.
>
> **Purpose**: produce **PRIME DIRECTIVE gate-1 evidence** — Constitution
> §3.4's testnet-first requirement, which every mainnet anchor broadcast
> (a cycle-transition anchor, an account key rotation `updateauth`, etc.)
> must satisfy before `bin/safe-broadcast --chain=mainnet-a` will accept
> `--testnet-tx-id=<this run's tx_id>`. Per Constitution §5, mainnet steps
> remain separately operator-approved; a passing rehearsal does not
> auto-trigger anything on mainnet.
>
> **Authority**: this runbook is an operator-executed sequence on XPR
> testnet (`proton-test` / chain `testnet-a`) only.
>
> **Scope**: testnet operations only. No command in this document targets
> mainnet.

## What this rehearses

`scripts/run-testnet-rehearsal.sh` runs the full anchor pipeline
end-to-end against XPR testnet:

```
public/api/anchor-source.json (identity + observations + artifacts branch roots)
  → scripts/sign-anchor-event.sh --chain=testnet-a --dry-run
      (composes a 4-action eosio.token::transfer tx; memos
       fya<schema>c<cycle>-{id,ob,ar}:<hex> + fya<schema>c<cycle>:<hex>)
  → bin/safe-broadcast --chain=testnet-a
      (the ONLY sanctioned broadcast pathway; enforces the operator-token
       gate + R16 content binding + chain-identity gate 3 — see its own
       header for the full gate list)
  → scripts/gen-anchor-receipt.sh
      (re-fetches the broadcast tx from testnet Hyperion/history and
       independently re-derives every field — the 7-gate verify chain,
       see "Pass criteria" below)
```

The account that signs (`<account>@anchor`) and the sink account are read
from the operator-local rehearsal config directory
(`~/freedom-yield-rehearsal-config/{xpr-account,anchor-sink,xpr-chain}`),
never from a hardcoded name in the script. By convention on this project
the rehearsal actor is the testnet account `frdomyieltst`, signing with
its `anchor` permission, transferring to sink account `fyhistorytst`
(both are public testnet account names already referenced throughout this
repo — see `docs/ANCHOR_ACCOUNT_KEY_ROTATION.md`).

## Prerequisites

- `proton-cli` installed on the **operator's Mac** (not the validator
  host — the v2 model signs only from the operator's local keystore; see
  `docs/OPERATOR_IDENTITY_SETUP.md`'s "current v2 Mac-sign model" note).
- `node` (Node.js) on PATH. Already a transitive prerequisite of
  `proton-cli` itself (an npm package); used directly by this rehearsal
  for public-key format verification
  (`scripts/lib/eosio-pubkey-raw-hex.js`, see "Rotation resilience"
  below).
- `jq`, `curl`, and `sha256sum` or `shasum` on PATH.
- The testnet proton-cli keystore (`HOME=~/.metal-fy-proton-test`) holds
  the CURRENT `frdomyieltst@anchor` private key, and is **unlocked**
  before running the rehearsal:
  ```
  HOME=~/.metal-fy-proton-test proton key:unlock
  ```
  Non-interactive shells (the rehearsal script itself) cannot unlock a
  locked keystore — a locked keystore causes `proton` to hang
  indefinitely on any signing-adjacent call. Unlock first, in a separate
  terminal, THEN run the rehearsal script (per Constitution §3.5, the
  unlock command above and every other `proton` invocation in this
  document MUST carry the `HOME=~/.metal-fy-proton-test` prefix — never
  a bare `proton …` against the default shared keystore).
- `~/freedom-yield-rehearsal-config/` exists with three files:
  `xpr-account` (`frdomyieltst`), `anchor-sink` (`fyhistorytst`),
  `xpr-chain` (`proton-test`). These are operator-local paths, resolved
  independent of the keystore-scoped `$HOME` (see
  `scripts/lib/require-keystore-home.sh`'s `fyd_login_home` for why).
- The canonical anchor-source file, `public/api/anchor-source.json`, is
  current for the cycle you are rehearsing (regenerated by
  `scripts/gen-anchor-source.sh`, normally on the validator host, then
  synced into this repo's tracked copy).

## Rotation resilience (why there is no key/account pin in this doc)

The rehearsal script verifies the `frdomyieltst@anchor` key dynamically:
it fetches the account's CURRENT on-chain permission structure via a
read-only testnet RPC call (`POST
https://rpc.api.testnet.metalx.com/v1/chain/get_account`) and checks that
the returned `anchor` permission's public key is present in the local
proton-cli keystore — comparing raw key bytes after normalizing both the
chain's legacy `EOS...` encoding and the keystore's `PUB_K1_...` encoding
(see `scripts/lib/eosio-pubkey-raw-hex.js`; the two encodings are
different base58check representations of the same underlying key and are
NOT reliably comparable as strings). If the RPC is unreachable or the
response is malformed, the script **fails closed** — it never guesses.

This means: a future key rotation (see
`docs/ANCHOR_ACCOUNT_KEY_ROTATION.md`) does **not** require editing this
script or this doc. The rehearsal always checks against whatever key is
CURRENTLY on-chain. (Prior to 2026-07-31 the script instead hardcoded
three specific `PUB_K1_...` public keys — one per `owner`/`active`/
`anchor` permission. Live `get_account` (2026-07-31) shows the 2026-07-10
key rotation only actually replaced the **`active`** permission's key on
`frdomyieltst`; the `owner` and `anchor` pins were, and still are,
byte-identical to their current on-chain keys. Step 1 was therefore
failing on the single stale `active` pin, not all three. The fix does
not re-verify all three permissions — it checks exactly the `anchor`
permission's current on-chain key, since that is the ONLY permission
`sign-anchor-event.sh` ever signs with (`authorization: actor@anchor`);
`owner` and `active` are not used for signing this pipeline and are out
of scope for this check. That hardcoded-pin design is retired — do not
reintroduce it, for any permission.)

## Cycle number must match the target mainnet cycle

A testnet rehearsal is only valid PRIME DIRECTIVE gate-1 evidence for a
mainnet broadcast targeting the **same** cycle. The hardened mainnet
`bin/safe-broadcast --chain=mainnet-a` gate 1 refuses cross-cycle
evidence — e.g. a rehearsal composed against `cycle_number_observed: 3`
(memo prefix `fya1c3`) cannot authorize a mainnet broadcast composed for
cycle 4 (`fya1c4`), even if the testnet tx itself resolves fine.

**Consequence for timing**: the rehearsal must run **after** the day-of
recompose of the canonical anchor-source (i.e. after
`scripts/gen-anchor-source.sh` has regenerated
`public/api/anchor-source.json` for the target cycle) — or against a
`--source=` file whose `cycle_number_observed` already equals the target
cycle. Running the rehearsal against last cycle's still-canonical file,
because the day-of recompose hasn't happened yet, produces testnet
evidence the mainnet gate will refuse. Catch this on testnet, not after
a wasted mainnet attempt.

**Mechanical enforcement**: pass `--expect-cycle=<N>` (see "Running the
rehearsal" below). Step 1/10 fails closed if the selected source's
`cycle_number_observed != N`. Mandatory for the day-of invocation;
optional (with a non-fatal reminder if omitted) for exploratory runs
with no specific target cycle.

## Running the rehearsal

For an **exploratory / pipeline-health** run (not gating any specific
mainnet broadcast), the canonical anchor-source is selected by default:

```
HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh
```

For the **day-of, real gate-1-evidence** run, `--expect-cycle=<N>` is
**mandatory** (`N` = the cycle number of the mainnet action this
rehearsal is meant to gate — see "Cycle number must match the target
mainnet cycle" below):

```
HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<N>
```

Step 1/10 prints the selected source's path, cycle number, and derived
memo prefix. **There is no interactive checkpoint in this script** —
`--expect-cycle=<N>` is the actual mechanical enforcement, not the
printed line: with it, step 1/10 fails closed immediately if the
source's `cycle_number_observed` does not equal `N`; without it, a
non-fatal reminder is printed but the run proceeds unverified against
any target cycle.

To point at a different (still real, non-fixture) anchor-source file:

```
HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh \
    --source=/path/to/anchor-source.json
```

`public/api/anchor-source.substantive.json` and
`public/api/anchor-source.example.json` are **fixtures** — stale,
placeholder-hash files frozen at whatever cycle they were last hand-built
for. They are refused unless you pass `--allow-fixture` explicitly:

```
HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh \
    --source=public/api/anchor-source.example.json --allow-fixture
```

**Never use `--allow-fixture` to produce real gate-1 evidence.** It
exists only for schema-shape testing (e.g. confirming the pipeline still
composes/broadcasts/verifies correctly against a known-fixed input,
independent of whatever the current cycle's real anchor-source looks
like). A rehearsal run with `--allow-fixture` does not satisfy PRIME
DIRECTIVE gate 1 for a real mainnet broadcast. (Passing `--allow-fixture`
when the selected source is not actually one of the two fixture files is
harmless — a non-fatal warning is printed, since the flag had no effect.)

### The 10 steps

1. **Anchor-source selection** — resolve + print the file to inscribe
   (path, `cycle_number_observed`, `computed_at`, derived memo prefix);
   refuse a fixture without `--allow-fixture`; fail closed if
   `--expect-cycle=<N>` was given and does not match.
2. **Rehearsal config** — read `~/freedom-yield-rehearsal-config/`
   (actor account, sink, chain).
3. **Chain-derived key check** — the rotation-resilient verification
   described above.
4. **Keystore unlock + chain preflight** — `proton chain:set proton-test`
   + `chain:info`, then a fast-timeout read of the actor account to
   detect a locked keystore.
5. **Compose the 4-action tx** — via `sign-anchor-event.sh --dry-run`
   (no broadcast; the dry-run log is retained as **testnet-side evidence
   only** — see "After PASS" below for where the mainnet gate-4 material
   actually comes from).
6. **Create the broadcast token** — `/tmp/fyd-broadcast-token`, 5-minute
   TTL, bound to `chain=testnet-a` and the exact composed tx's sha256
   (R16 — see `bin/safe-broadcast`'s header for the full ritual this
   automates).
7. **Invoke `bin/safe-broadcast --chain=testnet-a`** — the actual
   broadcast.
8. **Reassemble** the sign-anchor-event JSON shape for the receipt step.
9. **`gen-anchor-receipt.sh` 7-gate verify** — re-fetches the tx from
   testnet Hyperion/history and independently re-derives every field.
10. **Emit the sentinel line** — `TESTNET REHEARSAL COMPLETE
    testnet_tx_id=<64hex>` — copy this back to the AI session.

## Pass criteria

The rehearsal passes when `scripts/gen-anchor-receipt.sh` (invoked as
step 9/10, above) exits 0 — i.e. all 7 verify gates PASS:

1. The tx is reachable via `tx_id` at the testnet RPC.
2. The tx has exactly 4 actions.
3. All 4 actions are `eosio.token::transfer`.
4. All 4 actions' authorizations match the expected `actor@anchor`.
5. The 4 memos match the expected
   `{prefix}-{id|ob|ar}:<hex>` / `{prefix}:<hex>` set.
6. The `dag_root_summary` memo's hex equals
   `sha256(identity_root || observations_root || artifacts_root)`.
7. `block_num` and `block_time` are present on the resolved tx.

Any gate failing is a hard stop. Per `gen-anchor-receipt.sh`'s own exit
codes: gate 1 (tx unresolvable at the RPC) exits **3**; gates 2–7 (wrong
action count, wrong authorization, memo mismatch, etc.) exit **4**.
Either way the rehearsal script's own `fail()` then halts before
emitting the sentinel line. Diagnose and re-run — do not hand a partial
or failed run's `tx_id` to a mainnet `--testnet-tx-id=` argument.

Additionally confirm, by hand, on a public testnet explorer
(`https://testnet.protonscan.io/transaction/<tx_id>`, printed in the
step 10/10 output) that the 4 memos are visible and legible — this is a
visual cross-check against the automated gates, not a substitute for
them.

## After PASS: feeding the mainnet gate

The step 10/10 sentinel line's `testnet_tx_id` is the exact value the AI
session passes as `--testnet-tx-id=<that value>` to
`bin/safe-broadcast --chain=mainnet-a` for the corresponding mainnet
broadcast (a cycle-transition anchor, an `updateauth` key rotation, etc.
— whatever real mainnet action this rehearsal was run to gate). The
mainnet wrapper independently re-resolves that `tx_id` against the
testnet RPC itself before accepting it (its own gate 1) — the rehearsal
output is evidence, not a bypassable token.

**The rehearsal's own dry-run log does NOT feed the mainnet wrapper's
gate 4.** `~/.fya-testnet-dryrun-log.json` (printed at step 10/10)
records `target_chain: "testnet-a"` — under the hardened mainnet gate 4,
`bin/safe-broadcast --chain=mainnet-a` refuses a `--dry-run-log=<file>`
whose own recorded `target_chain` does not match `--chain`. The testnet
rehearsal's dry-run log is **testnet-side evidence only**: useful for
confirming the composed shape on testnet and as an input to the 7-gate
receipt above, but it is the wrong chain's dry run for the mainnet gate.

The actual mainnet gate-4 material comes from a **separate**
`--chain=mainnet-a` dry run, produced by
`scripts/preview-cycle-anchor-broadcast.sh` (or directly via
`sign-anchor-event.sh --chain=mainnet-a --dry-run`), targeting the
mainnet account for the same cycle. Generate that dry-run log alongside
this rehearsal, not from it, and pass it as
`bin/safe-broadcast`'s `--dry-run-log=<file>` when the mainnet broadcast
is authorized.

## Troubleshooting

- **Step 3/10 fails "not found in the local proton-cli testnet
  keystore"** — the on-chain `anchor` key and the local keystore
  disagree. Either the key was never imported, or it was rotated
  on-chain since the keystore was last updated. See
  `docs/ANCHOR_ACCOUNT_KEY_ROTATION.md` to import the matching private
  key (with the `HOME=~/.metal-fy-proton-test` prefix), then re-run.
- **Step 4/10 exits 2 with a keystore-locked warning** — run
  `HOME=~/.metal-fy-proton-test proton key:unlock` in a separate
  terminal, then re-run the rehearsal script.
- **Guard exits 8 (`ERROR (keystore guard, Constitution §3.5)`)** — the
  script was invoked without the `HOME=~/.metal-fy-proton-test` prefix
  (or with `HOME` unset). Re-invoke exactly as shown under "Running the
  rehearsal" above.
- **Step 9/10 (`gen-anchor-receipt.sh`) exits 3** — gate 1 (tx
  unresolvable at the RPC): the RPC is unreachable or the `tx_id`
  wasn't found. Check connectivity / broadcast success before re-running.
- **Step 9/10 (`gen-anchor-receipt.sh`) exits 4** — one of gates 2–7
  failed; the script prints which one and the expected vs. actual
  values. Do not proceed to mainnet with this run's `tx_id`.

## Phase β note

When Phase β is activated (the `metalfreedom::inscribe` smart-contract
action is deployed per
`scripts/operator-local/contract/metalfreedom-anchor.spec.md`), this
rehearsal is expected to gain a step exercising that SC action directly,
with the resulting receipt's `anchor.method ==
"phase_beta_sc_inscribe"`. Not yet implemented; the v2 Phase α steps
above remain the current rehearsal path.

## See also

- `scripts/run-testnet-rehearsal.sh` — the script this runbook documents.
- `scripts/sign-anchor-event.sh`, `bin/safe-broadcast`,
  `scripts/gen-anchor-receipt.sh` — the pipeline stages it drives.
- `scripts/preview-cycle-anchor-broadcast.sh` — produces the
  `--chain=mainnet-a` dry run that actually feeds the mainnet gate 4 (see
  "After PASS" above); NOT this rehearsal's own testnet-side dry-run log.
- `docs/ANCHOR_ACCOUNT_KEY_ROTATION.md` — how to rotate the
  `frdomyieltst`/`metalfreedom` account keys (testnet-first, same as
  every other broadcast).
- `docs/CONSTITUTION.md` — PRIME DIRECTIVE (§3.4) and keystore separation
  (§3.5).
- `docs/OPERATOR_IDENTITY_SETUP.md` — the mainnet analog of the
  operator-side permission install procedure.
