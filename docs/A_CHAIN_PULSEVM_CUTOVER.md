# A-Chain → PulseVM cutover runbook

Written 2026-09-30, when the operator decided to prepare the anchor path for the
Metal A-Chain's move from the XPR Network onto PulseVM (see
[`STRATEGIC_TARGET_ALIGNMENT.md`](STRATEGIC_TARGET_ALIGNMENT.md), "2026-09-30
update"). **Nothing in this file is active today.** The default chain profiles are
the current XPR network; every PulseVM value in `config/a-chain-profiles.json` is
`null`, and every path that would need one refuses (fails closed) until it is
filled in by a reviewed commit and the OPEN decisions below are made.

This runbook is subordinate to [`CONSTITUTION.md`](CONSTITUTION.md) — above all
the PRIME DIRECTIVE's four gates. Nothing here relaxes a gate; where PulseVM makes
a gate's wording unsatisfiable, the answer recorded here is "refuse, and ask the
operator".

## 1. What is already in place (and what each piece does on its own)

| piece | today (XPR profiles) | after a PulseVM profile is selected |
|---|---|---|
| `config/a-chain-profiles.json` + `scripts/lib/a-chain-profile.sh` | single source of every chain value | same file; PulseVM values must be committed first |
| `bin/safe-broadcast` | unchanged behaviour (pinned by an equivalence suite) | gate 3 also checks proton-cli's push endpoint against the profile's `node_hosts`; an **id-only** push is confirmed from history, and an unconfirmed one exits **9** — "a broadcast MAY have happened — verify before retrying"; gate 1 refuses (**exit 3**) while `gate1_evidence_profile` is null |
| `scripts/preview-cycle-anchor-broadcast.sh` | unchanged | exit **11** if the profile cannot be read |
| `scripts/gen-anchor-receipt.sh` | v2 receipt, with additive chain fields | a **v3** receipt is forced (`chain_id`, `chain_profile`, `block_id` required); `--rpc` must be exactly one of the profile's `history_bases` |
| `scripts/append-anchor-history.sh` | invariant 5 per chain_id | a new chain_id starts a new era; an unknown chain_id is exit 4 |
| `scripts/check-anchor-history-reachable.sh` | cycle-transition unit **7b.5**, rehearsal step 4/10, pipeline preflight 0b | same; on the first PulseVM anchor it runs in liveness mode (no ledger line on the new chain yet) |
| `scripts/archive-legacy-anchors.sh` + `verify-legacy-anchor-archive.sh` | cycle-transition unit **10**: every legacy anchor archived under `public/api/legacy-a-chain/` | reads the legacy profile **by name** — keeps pointing at the old chain |
| `scripts/check-pulsevm-upstream.sh` | daily watch, T1-T8 | T6/T7/T8 are the three facts this runbook waits for (§2) |

`FYD_MAINNET_CHAIN_ID` / `FYD_TESTNET_CHAIN_ID` are **confirm-only**: set, they must
equal the profile value or everything refuses. They can never substitute or fill
in a chain_id. Chain values change only through a reviewed commit to
`config/a-chain-profiles.json`.

## 2. Preconditions — do not start before all of these hold

1. **An official Metallicus statement** of the PulseVM A-Chain mainnet: chain_id,
   public node endpoints, history (Hyperion) endpoint(s), explorer, and the cutover
   window. Community pages (the 1:1 demo, `pulsevm.dev`) do not count — as of
   2026-09-30 they explicitly say they are not the plan. Watch trigger **T8**.
2. **A PulseVM GitHub Release ≥ v1.0.0** (trigger **T7**) and a **mainnet metalgo
   release able to run it** (the Granite line without the `-tahoe` suffix, trigger
   **T6**). The validator upgrade itself follows the usual validator runbooks.
3. **Every OPEN decision in §3 answered by the operator** and the answers
   committed (the profile file for (a)/(b); a Constitution amendment for (c) if
   needed).
4. **The legacy archive is complete**: `verify-legacy-anchor-archive.sh` prints
   `VERIFIED <n> anchor(s)` where n is the number of mainnet lines in the published
   ledger (§5).

## 3. OPEN operator decisions (the code refuses until they are made)

**(a) Which network satisfies PRIME DIRECTIVE gate 1 on PulseVM.** Gate 1 requires
the identical command shape to have succeeded on "the corresponding testnet". For
XPR that is the XPR testnet, recorded as `"gate1_evidence_profile": "xpr-testnet"`
on `xpr-mainnet`. For PulseVM there is no decided answer: the A-Chain Alpine
testnet had no working public RPC and no third-party accounts on 2026-09-30, the
community demo is a different chain, and the XPR testnet runs a different
execution model (its push returns a trace, PulseVM's does not). The profile
library therefore holds `pulsevm-mainnet.gate1_evidence_profile = null`, and
`bin/safe-broadcast` refuses a PulseVM mainnet broadcast with **exit 3 ("OPEN
operator decision")**. It also refuses an evidence testnet of a different
execution family (`push_response` / `lib_equals_head` must match). The operator
decides which network is the corresponding testnet; the answer goes into the
profile file by a reviewed commit, and a testnet profile for it must exist with
real values. Until then: no PulseVM mainnet anchor.

**(b) chain_id policy.** The upstream code merged on 2026-09-14 gives the migrated
chain a **new** chain_id (the MetalGo blockchain ID); the community path keeps the
XPR one. The code handles both, but differently:

- *new chain_id* (upstream path): the first PulseVM anchor starts a new ledger era
  (invariant 5 is per chain_id); receipts carry the new chain_id; pre-cut anchors
  remain verifiable only against the legacy archive and the old chain.
- *kept chain_id* (community path): the profile file allows two mainnet-role
  profiles to share a chain_id; the ledger era continues, which is correct only
  because block heights continue from the cut (H+1). If a migration kept the
  chain_id **and restarted heights**, invariant 5 would refuse every append (exit
  4) — that combination needs a code change before the first anchor.
- Either way, gate 3's chain_id compare alone cannot tell the old chain from the
  new one when the id is kept — the node host allowlist is what separates them.

The operator decides which policy the official statement actually describes; the
profile's `chain_id` is written from that statement and cross-checked against the
chain's own `get_info` from at least two of the listed endpoints before commit.

**(c) Constitution §3.5 — keystore and signing tool.** §3.5 binds every
signing-CLI invocation to the project keystore HOME. The anchor path signs through
proton-cli. The 2026-09-30 survey found proton-cli can likely push to PulseVM's
`/v1/chain` layer mechanically, but (1) proton-cli selects networks by built-in
name, and a PulseVM network is not among them; (2) pointing it at a custom node
means an `endpoints` override, which the rehearsal pre-flight's check 10 flags on
purpose; (3) PulseVM node URLs are per-blockchain paths that the AI-session
broadcast guard refuses to let an AI type. If proton-cli cannot be pointed at the
PulseVM mainnet cleanly, a different signing tool would be needed — that is a
Constitution-level change (amendment process), not a runbook step. Until decided:
`proton_network` stays `null` for PulseVM and every broadcast refuses.

**(d) If this validator is ever appointed to the A-Chain's own validator set.**
[`STRATEGIC_TARGET_ALIGNMENT.md`](STRATEGIC_TARGET_ALIGNMENT.md) forbids anchoring
to a chain whose validator set this project appoints or operates. If the A-Chain
on PulseVM ends up validated by a set that includes this validator, the operator
must decide whether anchoring there is still independent evidence before the
first PulseVM anchor.

## 4. Cutover day

### 4.1 Before the write freeze

1. Run the last legacy anchor of the cycle as usual (the 16-unit transition,
   including unit **10**, the legacy archive). Confirm `VERIFIED <n>` equals the
   number of mainnet ledger lines.
2. Do **not** schedule a cycle-transition anchor inside the announced window. If
   the window overlaps a transition day, the anchor waits: nothing in the cycle
   gate requires the anchor to land inside the window, and unit 9 does not read the
   anchor.

### 4.2 During the write freeze — fail closed, never broadcast into it

- Upstream keeps transaction admission closed for at least the maximum transaction
  lifetime (about an hour). **No anchor, testnet rehearsal or any other broadcast
  is attempted during the window.**
- What the code does if someone tries anyway: on the legacy profile a halted
  chain rejects the push (exit 6 — check the chain before any retry); on an
  id-only profile an admitted-but-never-executed transaction is reported as exit
  **9** with the tx_id on stderr ("a broadcast MAY have happened — verify before
  retrying"). Never re-push on exit 9: look the tx_id up in history first.
- After the cut, **never select `xpr-mainnet` for a broadcast again**. The legacy
  profile remains in the file for reading and verifying legacy records (the ledger,
  the archive) only.

### 4.3 Setting the PulseVM values

All of this lands as **one reviewed commit** to `config/a-chain-profiles.json`,
made only after §2 holds. Environment variables cannot do it.

- `pulsevm-mainnet`: `chain_id` (from the official statement, cross-checked per
  §3(b)), `node_hosts` (the official node hosts, bare host names), `history_bases`
  (the official Hyperion base URLs, exact, no trailing `/`), `explorer_base`,
  `proton_network` (per §3(c)), `gate1_evidence_profile` (per §3(a)).
  `push_response: "id-only"` and `lib_equals_head: true` are already set.
- The testnet profile named by `gate1_evidence_profile`, with real values.
- `tests/a-chain-profile/` must pass on the new file (it validates shape,
  cross-role separation and the gate-1 evidence family).

Selection is per process: `FYD_A_CHAIN_PROFILE_MAINNET=pulsevm-mainnet` (and the
matching `FYD_A_CHAIN_PROFILE_TESTNET`) in the shell that runs each step.

**Code still to change at cutover (engineering, reviewed):**

- `scripts/cycle-transition.sh` unit 7b.5 refuses any `FYD_A_CHAIN_PROFILE_*` in
  the host's deploy environment — correct until the cutover. At the cutover the
  plan must carry the selection explicitly on every unit that reads the chain
  (7a, 7b, 7b.5, 7c on the Mac side; 8 on the host) and 7b.5's precondition must
  instead require exactly the PulseVM selection.
- `scripts/gen-evidence.sh` advertises the v2 receipt schema URL; the first
  PulseVM receipt is v3. Update it in the same change so the evidence manifest
  does not describe the new receipt with the old schema.
- `docs/cycle-transition-steps.json`, `CYCLE_GATE.md` and `VALIDATOR_RENEWAL.md`
  follow the plan change (their drift tests enforce it).

### 4.4 The first PulseVM anchor — verification

1. Gate-1 material on the network decided in §3(a); the rehearsal script refuses
   while that testnet profile has null values.
2. Unit 7b (preview) must show the PulseVM chain_id and profile name.
3. Unit 7b.5 runs in **liveness** mode (no ledger line on the new chain yet): the
   signing account's newest action must resolve through the new history bases, and
   for a v3 receipt a `block_id` must be obtainable. If the account has no action on
   the new chain yet the check says so (block_id service not provable) — decide
   whether to proceed; the receipt will still fail closed if block_id is missing.
4. Unit 7c: `bin/safe-broadcast` pushes, receives only a transaction_id, and polls
   history until the transaction is seen executed with the composed memos. Exit 0
   = confirmed. Exit 9 = not confirmed in the bounded wait — the transaction MAY
   exist: look it up before anything else, and never re-push blindly. (Unit 7c
   calls the wrapper through `sign-anchor-event.sh`, which reports every wrapper
   failure as its own exit 5 — read the wrapper's message to tell 6 from 9.)
5. Unit 8 writes a **v3** receipt (`chain_id`, `chain_profile`, `block_id`) and
   the append starts a new chain_id era (or continues it, per §3(b)).
6. By hand, independently: fetch the transaction from one listed history base
   (`<history_base>/v2/history/get_transaction?id=<tx_id>`) and compare the four
   memos, the block number and the block id with the receipt; confirm the explorer
   shows the same. PulseVM has no reversible window (LIB = head), so a transaction
   seen in history is final.

## 5. The legacy archive

`public/api/legacy-a-chain/` holds, for every mainnet anchor on the XPR chain, the
Hyperion `get_transaction` body and the `get_block` body **verbatim**, with
SHA-256s and a manifest. It is published and git-tracked. It exists because
anchors are transaction history, and the new chain does not serve blocks from
before the cut; whether anyone keeps the old chain's history online afterwards
was unknown on 2026-09-30.

- Extended after every legacy anchor (cycle-transition unit 10) and once more
  right before the write freeze (§4.1).
- Verified offline by `scripts/verify-legacy-anchor-archive.sh`; the public
  procedure is on the `/verify/` page ("Legacy A-Chain anchor archive").
- Never delete or rewrite a record to make a check pass. A record that disagrees
  with what the chain serves later is a fail-closed stop (archiver exit 4) and a
  finding to report.
- After the cut, pre-cut anchors are verified against this archive (and against
  the old chain's history for as long as someone serves it), keyed by the OLD
  chain_id `384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0`.

## 6. Things not to do

- Do not put a chain_id, host or history base anywhere but the profile file.
- Do not satisfy a refusal by exporting an override, widening an allowlist, or
  running `proton endpoint:set`; each of those is exactly what the refusal is for.
- Do not type a PulseVM node URL (a per-blockchain path) into an AI session's shell
  — the broadcast guard blocks it, and it should. Put URLs in files.
- Do not retry a broadcast after exit 6 or 9 before the transaction id has been
  looked up.
