# Operator identity key — setup runbook (Phase 5 + Phase α)

> **Status note (2026-06-21)**: this document teaches the off-chain
> ed25519 operator-identity flow originally introduced as Phase 5.
> The downstream **chain anchor** was redesigned 2026-06-20 / 21:
> the prior "P-Chain memo at Phase 6" model was retired (forbidden by
> Metal mainnet Durango protocol rules) and replaced by the **Phase α
> A-chain Merkle DAG anchor** documented in
> [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md). Section **B** of this
> document covers the validator-host deploy of the Phase α anchor key;
> [`PHASE_ALPHA_TESTNET_DRY_RUN.md`](./PHASE_ALPHA_TESTNET_DRY_RUN.md)
> is the rehearsal runbook before the first mainnet inscription.
>
> When sections below reference "Phase 6 chain-anchor memo", interpret
> as: the inscription is now performed by `scripts/post-anchor-event.sh`
> on the validator host, signing an `eosio.token::transfer` on Metal
> A-chain (= PulseVM / XPRNetwork) with memo `fyid1:<dag_root_hash>`
> using `freedomyield@anchor`. The hash committed on chain is
> `dag_root_hash` (= a DAG roll-up of the operator identity-key
> history and the validation-cycle history), not a single per-cycle
> artifact hash.
>
> At execution time, prefer the compact one-page action list for the
> phase you are about to run:
> [`PHASE5_CHECKLIST.md`](./PHASE5_CHECKLIST.md) for the signed-
> manifest publish. The historical
> `PHASE6_CHECKLIST.md` (= retired P-Chain memo flow) is superseded
> by [`PHASE_ALPHA_TESTNET_DRY_RUN.md`](./PHASE_ALPHA_TESTNET_DRY_RUN.md)
> + section B below. This document is the teaching reference — read
> it once for context, then run from the matching checklist on the
> day.

This is the operator-side runbook for Phase 5 of the
[`project_merkle_dag_identity_anchor_design`](./IDENTITY_VERIFICATION.md)
flow. It walks through generating the dedicated operator identity key
on a local workstation, producing a signed `identity.json` with a real
`artifact_root`, and publishing the three live surfaces:

- `https://metal.freedom-yield.com/api/identity.json`
- `https://metal.freedom-yield.com/api/identity.json.sig`
- `https://metal.freedom-yield.com/.well-known/operator-identity.pub`

A separate document, [`IDENTITY_VERIFICATION.md`](./IDENTITY_VERIFICATION.md),
covers the verifier side (how a third party can independently confirm
the signature and the Merkle DAG over the artifact set).

## Prerequisites

Before Phase 5 begins, both of the following must be true:

1. **Phase 1–4 landed.** The four formal JSON schemas
   (`*.schema.v1.json`) are live, the `identity.example.json` has the
   Merkle DAG hub shape, the seven-step verification recipe is in
   `IDENTITY_VERIFICATION.md`, and `gen-identity.sh` implements the
   Merkle DAG computation.

2. **Task #28 cron auto-fire gate cleared.** The validator-host cron
   that produces `/api/evidence.json` has fired at least once
   un-attended and the resulting log entry plus updated
   `generated_at` are observable. The first scheduled un-attended fire
   after the 2026-06-19 cron fix is 2026-06-20 01:30 UTC.

If either is not true, stop here. Publishing an `identity.json` whose
referenced `/api/evidence.json` is stale or absent would be honest
about the signature but dishonest about the artifact set it binds.

## What is generated and where it lives

| Artifact | Location | Permissions |
| --- | --- | --- |
| Operator identity private key | `~/.ssh/freedom-yield-operator-identity` on the local Mac only | `0600`, owner-readable only |
| Operator identity public key | `~/.ssh/freedom-yield-operator-identity.pub` on the local Mac, and `public/.well-known/operator-identity.pub` in the repo | `0644`, world-readable |
| Identity manifest | `public/api/identity.json` (generated locally, then committed) | `0644` |
| Detached signature | `public/api/identity.json.sig` (generated locally, then committed) | `0644` |
| Passphrase backup | Password manager only (not in repo, not in cloud storage outside the manager) | n/a |

The private key **never** leaves the local Mac and the password manager
backup. It is never copied to the validator host, the web host, the
repository, CI, or any cloud sync (iCloud / Dropbox / Drive). The
validator's `staker.key` and BLS `signer.key` are unrelated to this
key and are not touched at any point in this runbook.

## Step 1 — Generate the ed25519 identity key

On the local Mac, outside any cloud-synced directory:

```sh
ssh-keygen -t ed25519 \
  -f ~/.ssh/freedom-yield-operator-identity \
  -C "freedom-yield-operator-identity"
```

Choose a strong passphrase. Save it to the password manager
immediately. The passphrase is not recoverable; losing it means
generating a new key and publishing a key-rotation event.

Confirm the keypair landed where intended:

```sh
ls -l ~/.ssh/freedom-yield-operator-identity*
ssh-keygen -l -f ~/.ssh/freedom-yield-operator-identity.pub
```

The second command prints `<bits> SHA256:<base64> <comment> (ED25519)`.
Record the `SHA256:…` value — this is the **manifest fingerprint** and
will appear as `operator_identity_pubkey_fingerprint` in
`identity.json`. It hashes the SSH wire-format key blob, not the
`.pub` file bytes.

**Historical note (= for context only)**: the prior "Phase 6 chain-
anchor memo" was designed to commit to a different hash of the same
key (SHA-256 of the published `.pub` bytes) on the Metal P-Chain.
That design was retired 2026-06-20 — Metal mainnet Durango forbids
non-empty memos on AddPermissionlessValidatorTx. The replacement is
the Phase α A-chain Merkle DAG anchor (= `fyid1:<dag_root_hash>` memo
on `eosio.token::transfer` signed by `freedomyield@anchor`), which
commits to a hash over the cumulative identity-key history AND the
validation-cycle history (= a strictly broader commitment than the
single-key hash). The `.pub` byte hash is still useful as an
out-of-band fingerprint cross-check; compute and record it now:

```sh
shasum -a 256 ~/.ssh/freedom-yield-operator-identity.pub
```

The two hashes commit to the same key via different byte sequences
(wire-format blob vs. file bytes) and give an evaluator two
independent cross-checks. Do not confuse them: the ssh-keygen
`SHA256:<base64>` value goes in the manifest field, and the
`shasum -a 256 .pub` hex value goes in the chain memo.

## Step 2 — Dry-run with the synthetic-key harness

Before touching the real key, confirm the local toolchain works by
running the synthetic-key test:

```sh
bash scripts/operator-local/test-gen-identity.sh
```

The expected tail is:

```
PASS: gen-identity.sh Phase 3 Merkle DAG output is internally consistent
      (leaves re-hash match, Merkle root reproducible, signature verifies)
```

If this prints `FAIL`, stop and resolve the failure before running
against the real key. Common causes:

- Missing `jq`, `shasum`, `xxd` — install via Homebrew.
- Network egress blocked to `metal.freedom-yield.com` — fix DNS / VPN.
- `ssh-keygen` older than 8.0 — Apple Silicon Macs ship 9.x by default;
  bash 3.2 on `/bin/bash` is fine.

## Step 3 — Run `gen-identity.sh` with the real key

```sh
export OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity
bash scripts/operator-local/gen-identity.sh
```

Expected tail (your `fingerprint` and `artifact_root` will differ):

```
✓ wrote .../public/api/identity.json
✓ wrote .../public/api/identity.json.sig
  fingerprint:     SHA256:<your-fingerprint>
  namespace:       freedom-yield/validator-identity
  principal:       freedom-yield
  iat / exp:       <today> / <today+365d>
  leaves bound:    <count>           # 5 if cycle-history.jsonl is live, else 4
  artifact_root:   <64-hex>
  identity_branch_root: <64-hex>   (= identity-history.jsonl Merkle root)
  cycles_branch_root:   <64-hex>   (= cycle-history.jsonl Merkle root)
  dag_root_hash:        <64-hex>   (= SHA-256(raw(id_root)||raw(cy_root)))
  anchor memo:          fyid1:<dag_root_hash>     (Phase α A-chain inscription)
```

Once Phase α activates, `dag_root_hash` is inscribed on Metal A-chain
(= PulseVM / XPRNetwork) via `scripts/post-anchor-event.sh`. Before
that, the field is computed and emitted but the on-chain inscription
has not yet occurred (= `/api/anchor-receipt.json` is absent or stale).
The historical `chain_anchor: all-zeros placeholder — bind at Phase 6`
text was removed when the P-Chain memo design was retired
([`IDENTITY_SCHEMA_CHANGELOG.md`](./IDENTITY_SCHEMA_CHANGELOG.md)
2026-06-20 entry).

## Step 4 — Copy the public key into the repo

```sh
cp ~/.ssh/freedom-yield-operator-identity.pub \
   public/.well-known/operator-identity.pub
chmod 644 public/.well-known/operator-identity.pub
```

Inspect the file to confirm only the public half is in it: it should
be exactly one line beginning with `ssh-ed25519 AAAAC3Nz…`. It must
not contain any of the dash-delimited block headers that mark a
private key (`OpenSSH` or `PEM` style). If the file is multi-line or
contains a `BEGIN`-style header, you copied the private file by
mistake — delete it immediately and copy the `.pub` file instead.

## Step 5 — Review the diff and commit

```sh
git status
git diff -- public/api/identity.json
git diff -- public/.well-known/operator-identity.pub
```

The three files to add are:

```sh
git add public/api/identity.json \
        public/api/identity.json.sig \
        public/.well-known/operator-identity.pub
```

Commit message style for this project: explain the *why*, single-purpose.
A suggested form:

```text
feat(identity): Phase 5 — publish signed operator identity manifest

Adds the operator identity manifest produced by gen-identity.sh:

  - public/api/identity.json — operator identity + artifact_manifest +
    artifact_root (Merkle root over <N> leaves) + dag_root_hash
    (Phase α A-chain Merkle DAG anchor; chain inscription is performed
    separately by scripts/post-anchor-event.sh on the validator host).
  - public/api/identity.json.sig — detached signature produced by
    ssh-keygen -Y sign with namespace freedom-yield/validator-identity.
  - public/.well-known/operator-identity.pub — public half of the
    operator identity ed25519 key, served as text/plain on the web.

The validator's staker.key and BLS signer.key are unrelated to this
key and were not touched. Phase 5 gate (Task #28 cron auto-fire PASS)
cleared at <timestamp>.
```

## Step 6 — Push and observe deploy

```sh
git push origin main
```

The GitHub Actions deploy job picks up the three files (none of them
are in the rsync exclude list) and rsyncs them to the web host.

## Step 7 — Live verification

After deploy completes, run the seven-step recipe from
[`IDENTITY_VERIFICATION.md`](./IDENTITY_VERIFICATION.md). The
shortest end-to-end check is:

```sh
# 1. Fetch the manifest and its detached signature.
curl -sS https://metal.freedom-yield.com/api/identity.json   > /tmp/id.json
curl -sS https://metal.freedom-yield.com/api/identity.json.sig > /tmp/id.json.sig
curl -sS https://metal.freedom-yield.com/.well-known/operator-identity.pub > /tmp/operator.pub

# 2. Verify the live pubkey fingerprint matches the manifest's claim.
LIVE_FP=$(ssh-keygen -l -f /tmp/operator.pub | awk '{print $2}')
CLAIMED_FP=$(jq -r .operator_identity_pubkey_fingerprint /tmp/id.json)
[ "$LIVE_FP" = "$CLAIMED_FP" ] && echo "fingerprint match OK"

# 3. Verify the detached signature.
printf 'freedom-yield %s\n' "$(cat /tmp/operator.pub)" > /tmp/allowed
ssh-keygen -Y verify \
  -f /tmp/allowed \
  -I freedom-yield \
  -n freedom-yield/validator-identity \
  -s /tmp/id.json.sig < /tmp/id.json \
  && echo "signature verifies OK"
```

If either check prints anything other than the expected `OK` line,
roll back.

## Rollback

To revert Phase 5 cleanly:

```sh
git rm public/api/identity.json \
       public/api/identity.json.sig \
       public/.well-known/operator-identity.pub
git commit -m "revert: pull Phase 5 identity artifacts pending re-issue"
git push origin main
```

On the next deploy, the three URLs return 404 again. The keypair on
the local Mac is unaffected; you can re-run `gen-identity.sh` and
republish whenever the underlying issue is resolved.

## Common pitfalls

- **Cache invalidation.** Schema files and identity artifacts are not
  in the Service Worker shell cache. Browsers may still hold a CDN
  copy briefly; verify with `curl` rather than browser reload.

- **Leaf count drift.** If you publish Phase 5 with N=4 (cycle-history
  still HOLD), then `cycle-history.jsonl` goes live later, the
  `artifact_root` will change on the next `gen-identity.sh` run. This
  is correct behaviour — the Merkle root reflects the bound set at the
  time of signing. Re-running `gen-identity.sh` and re-committing is
  the way to extend the bound set.

- **Time-of-flight skew.** If `evidence.json` updates between the
  moment `gen-identity.sh` fetched it and the moment a verifier
  fetches it, the verifier's recomputed leaf sha256 will not match
  the manifest's claim. Re-run `gen-identity.sh` to refresh the
  manifest. For frequently-updated leaves this is unavoidable; the
  manifest binds the set at signing time, not in perpetuity.

- **`.pub` content-type.** The web host serves `.well-known/*.pub`
  with whatever MIME type its config dictates. The verifier doesn't
  care about the MIME type — `ssh-keygen` parses the body — but if
  you find the response surprising, check the web host's `mime.types`
  for an explicit mapping. There is no requirement to add one.

---

# A-chain anchor account — permission setup (Phase α)

> This section is operationally distinct from the Phase 5 operator
> identity ed25519 setup above: different chain (Metal A-chain =
> PulseVM / XPRNetwork), different key family (EOSIO K1 secp256k1 +
> WebAuth P-256), different tooling (`proton-cli` / webauth.com). The
> `freedomyield` XPR account is the on-chain anchor for the Merkle DAG
> identity model; permission structure follows the design in
> `project_merkle_dag_identity_anchor_design.md`.
>
> Phase α scope is **additive only**: a new narrow `anchor` permission
> is added as a child of `active`. Owner rotation and active tightening
> are deferred to Phase β.

## A1. Current state (live-verified 2026-06-20, XPR mainnet)

Read-only verification via the public chain RPC
(`https://api-xprnetwork-main.saltant.io/v1/chain/get_account` with
`{"account_name":"freedomyield"}`) returns:

| field | value |
| --- | --- |
| `account_name` | `freedomyield` |
| `created` | `2026-04-09T05:43:36 UTC` |
| `owner` permission | threshold=1, keys=[`EOS6w1ufdiYuZs9Q...` (K1)] |
| `active` permission | threshold=1, keys=[`EOS6w1ufdiYuZs9Q...` (K1), `PUB_WA_3hftgAoXi...` (WebAuth)], parent=`owner` |
| `last_code_update` | unset (no contract deployed) |

The `PUB_WA_` prefix indicates a WebAuth (P-256) credential registered
on `active`. The current owner key is a K1; whether the operator holds
the corresponding private key is a coord-log Decision (see
`project_phase_alpha_coordination_log.md` Decision #2).

## A2. Target state (Phase α minimal)

```
freedomyield
├── owner    (unchanged from A1; rotation deferred to Phase β)
├── active   (unchanged from A1)
└── anchor   (NEW, parent=active, threshold=1,
             keys=[PUB_K1_<anchor_pubkey>])
    └── linkauth: eosio.token::transfer  (Phase α automated broadcast)
```

Rationale:

- Phase α adds **only** what is needed for automated anchor broadcast.
- `anchor` is a child of `active`, so the existing active signers
  (WebAuth biometric, optionally the K1) can authorize its creation
  without touching the owner permission.
- Narrowing `anchor` via `linkauth` to `eosio.token::transfer` limits
  the blast radius if the validator-host-stored `anchor` private key
  is compromised: it can sign transfers from `freedomyield`, but
  cannot change permissions, deploy contracts, or sign other system
  actions.
- Owner rotation to WebAuth-only and any active-permission tightening
  are explicitly Phase β work (see A9).

## A3. Prerequisites

- `proton-cli` 0.1.98+ installed on the operator Mac
  (verify: `proton --version`).
- `freedomyield@active` signing capability — one of:
  - WebAuth biometric via `webauth.com` or Proton wallet app (uses
    the existing `PUB_WA_3hftgAo...` credential on `active`). No
    K1 private key required.
  - The K1 private key for `EOS6w1ufdiYuZs9Q...` imported via
    `proton key:add`. Subject to Decision #2 in
    `project_phase_alpha_coordination_log.md`.
- A receiver account for Phase α broadcasts (Decision #1 in the
  coord-log; placeholder `<sink_account>` below until naming is
  confirmed by the operator). Self-transfer is forbidden by
  `eosio.token::transfer` at contract level
  (`from != to` check in `XPRNetwork/proton.contracts/contracts/`
  `eosio.token/src/eosio.token.cpp` line 99), so a second account is
  unavoidable.
- The testnet rehearsal (A5) MUST complete with PASS before any
  mainnet step is executed (A6 / A7).
- No mainnet step in this section is to be executed without explicit
  operator approval per Constitution §5.

## A4. Generate the anchor K1 keypair (operator Mac, offline)

The `anchor` key is a fresh K1 (secp256k1) keypair, NOT WebAuth and
NOT reused from any existing key on `freedomyield`.

```sh
proton key:generate
# Output (record both):
#   Private key: PVT_K1_...      ← store in Dashlane only
#   Public key:  PUB_K1_...      ← used below as <anchor_pubkey>
```

Constraints:

- Run on the operator Mac, outside any cloud-synced directory
  (no iCloud / Dropbox / Google Drive path).
- The private key MUST be stored ONLY in Dashlane on the Mac side.
  It MUST NOT be committed to any repository, written to any cloud
  sync, pasted into any AI chat, or held in any password manager
  outside Dashlane.
- The Mac-side copy is transient: after the validator-host deploy
  (T-2, separate section below), the Mac copy is shredded and only
  the Dashlane backup + the validator-host live copy remain.
- The corresponding public key is PUBLIC and may be copied freely.

## A5. Testnet rehearsal (mandatory before any mainnet step)

```sh
# Switch CLI to proton-test (= XPR testnet).
proton chain:set proton-test

# Generate a throwaway test key and provision a test account
# (operator: signup via webauth.com testnet or proton testnet faucet).
# The test account name is local-only; do not name it after the
# planned production sink or any brand identifier.

# Reproduce A6 + A7 + A8 against the test account.
# All three steps MUST PASS, with explorer-visible permission and
# linkauth, before any mainnet command is issued.

# Switch CLI back to mainnet only after the testnet PASS is recorded.
proton chain:set proton
```

The testnet PASS is part of the IC-2 deliverable (C3 → C1 by
2026-06-30 per `project_phase_alpha_coordination_log.md`).

## A6. Add the `anchor` permission as a child of `active`

This action requires `freedomyield@active`. The current active has
both a K1 key and a WebAuth credential; either is sufficient (single
key threshold).

**Path 1 — sign with WebAuth via the wallet UI:**

The action must be composed in `webauth.com` or the Proton wallet
app, because `proton-cli` does not sign with `PUB_WA_` credentials.
The action payload to compose is the `eosio` system contract
`updateauth` action, with the JSON payload shown in Path 2 below.

**Path 2 — sign with the K1 private key via `proton-cli`:**

Requires the K1 private key for `EOS6w1ufdiYuZs9Q...` to be present
in the local `proton-cli` keystore (`proton key:add` first).

```sh
proton action eosio updateauth '{
  "account": "freedomyield",
  "permission": "anchor",
  "parent": "active",
  "auth": {
    "threshold": 1,
    "keys": [
      {"key": "PUB_K1_<anchor_pubkey from A4>", "weight": 1}
    ],
    "accounts": [],
    "waits": []
  }
}' freedomyield@active
```

Expected: the CLI returns the transaction id; the chain accepts the
action; the new `anchor` permission appears under `freedomyield` in
the next account read.

## A7. Link the `anchor` permission to `eosio.token::transfer`

```sh
proton action eosio linkauth '{
  "account": "freedomyield",
  "code": "eosio.token",
  "type": "transfer",
  "requirement": "anchor"
}' freedomyield@active
```

Effect: for actions where `from = freedomyield` on `eosio.token::transfer`,
the chain accepts `freedomyield@anchor` as sufficient authorization
(in addition to the default `freedomyield@active`). No other
`eosio.token` action and no other contract action is reached by this
linkauth.

`<action>` is restricted to `transfer` deliberately; omitting it
would link `anchor` to ALL actions of `eosio.token`, which would
unnecessarily widen `anchor`'s authority.

**Phase β preview** (not executed in Phase α): when the
`freedomyield::inscribe` action is deployed (T-4 SC spec), an
additional `linkauth` will be issued:

```
{"account":"freedomyield","code":"freedomyield",
 "type":"inscribe","requirement":"anchor"}
```

This will give `anchor` the authority to call the SC inscribe action
without touching the `eosio.token::transfer` linkauth installed in
this Phase α step.

## A8. Post-mainnet verification

```sh
# Re-read the account; expect the new `anchor` permission to appear
# under `freedomyield.permissions`, parent=active, with the
# <anchor_pubkey> from A4 as the sole key.
curl -sS -X POST -H 'Content-Type: application/json' \
  --data '{"json":true,"account_name":"freedomyield"}' \
  https://api-xprnetwork-main.saltant.io/v1/chain/get_account \
  | jq '.permissions[] | select(.perm_name=="anchor")'

# Linkauth verification: a dry-run transfer signed by anchor should
# be accepted by chain rules (replace <sink_account> with the
# confirmed sink name; <root_hash> is any 64-hex placeholder for the
# verification dry-run).
proton action eosio.token transfer '{
  "from": "freedomyield",
  "to": "<sink_account>",
  "quantity": "0.0001 XPR",
  "memo": "fyid1:<root_hash>"
}' freedomyield@anchor --dry-run
```

Expected: the dry-run reports the action as well-formed and accepts
`freedomyield@anchor` as the required authorization. No actual
broadcast occurs with `--dry-run`.

A successful mainnet broadcast of the same action (without
`--dry-run`) is the Phase α automated-anchor path; production use
is wired via `scripts/operator-local/sign-anchor-event.sh` (T-3) and
`scripts/post-anchor-event.sh` (C1 T-3 / T-4).

## A9. Phase β preview (deferred, NOT executed in Phase α)

Phase β items are intentionally out of scope for the Phase α
deadline (2026-07-04 cycle 3 start). They are listed here so the
operator knows what is deliberately deferred and what will require
attention later.

- **Owner rotation**: replace `owner=[EOS6w1u...]` with
  `owner=[PUB_WA_...]` (WebAuth-only cold key). Requires the
  CURRENT owner K1 private key to sign the owner-change action
  (EOSIO rule: `updateauth owner` requires the current owner's
  signature). Blocked on coord-log Decision #2.
- **Active tightening**: if the K1 `EOS6w1u...` on active is no
  longer needed after owner rotation, remove it from active so the
  only active signer is the WebAuth credential.
- **SC deploy on `freedomyield`**: the contract spec is C3 T-4
  deliverable (`scripts/operator-local/contract/`
  `freedomyield-anchor.spec.md`). Deploy is Phase β; the contract is
  NOT deployed during Phase α.
- **Additional linkauth for `freedomyield::inscribe`**: see A7
  Phase β preview block.
- **Optional sink-account hardening**: e.g. multisig on the sink, a
  no-op contract on the sink that ignores or logs incoming transfers,
  etc. The minimal Phase α sink is a plain account with default
  permissions, sufficient to satisfy `eosio.token::transfer`'s
  `is_account(to)` check.

## A10. Anchor key validator host deploy

See section **B** below. Until B is executed, the anchor private key
remains on the operator Mac in the Dashlane-backed transient state
described in A4. The mainnet `eosio.token::transfer` broadcast (= the
production Phase α inscription) cannot run from the validator host
until B is complete.

---

# B. Validator-host deploy of the `anchor` private key (Phase α)

> **Authorization gate**: every command in this section affects the
> validator host. Per Constitution §5, validator-host changes are
> operator-approved and operator-executed. The AI side (C2 acting as
> drafter) produces this runbook; the operator executes. No step in
> this section is a default-allowed AI action.
>
> **Sequencing gate**: A6 + A7 + A8 (= mainnet permission install and
> linkauth) MUST complete and verify on chain before B is executed.
> A misconfigured permission combined with a deployed key creates a
> bricked anchor pipeline that takes another mainnet round-trip to
> recover.

## B1. Deploy target

| field | value | note |
| --- | --- | --- |
| host role | validator host | Constitution §5: distinct from the web host. Reached via the operator's documented SSH path (see operator's private SSH-access note). |
| OS user that runs the anchor pipeline | `deploy` | Matches the convention used by other Phase α / β cron-driven scripts on the validator host (e.g. `metal-watch-validators` uses the same user). |
| directory | `/etc/freedom-yield/` | Established convention; the existing per-host config files (`/etc/freedom-yield/web-host`, `/etc/freedom-yield/validator-host`, `/etc/freedom-yield/ntfy-topic`, etc.) all live here. |
| key file path | `/etc/freedom-yield/anchor.k1.key` | Active anchor private key (PVT_K1_…). One file, one key, no rotation generations stored side-by-side here. |
| previous-key archive path | `/etc/freedom-yield/anchor.k1.key.<key_seq>.retired` | After rotation; see B6. |
| file mode | `0600` | Read+write owner only. |
| file owner / group | `deploy:deploy` | Matches the OS user that runs the anchor pipeline. |

The path family `/etc/freedom-yield/` is referenced from
`docs/CRON_CONVENTIONS.md`, `scripts/operator-local/gen-identity.sh`,
and existing public scripts; using it for the anchor key is
consistent and does not introduce a new convention.

## B2. Prerequisites on the validator host

The operator confirms or installs:

- `proton-cli` 0.1.98+ (verify: `proton --version`).
- `jq` (already a Phase 1+ requirement for the existing JSON-handling
  scripts).
- `curl` (already present).
- The `deploy` user exists and runs the anchor-driving cron entries.
- `/etc/freedom-yield/` exists, owner `root:root`, mode `0755` (= the
  established convention for the per-host config dir).
- Outbound network egress to `api-xprnetwork-main.saltant.io` (and to
  the operator's preferred secondary XPR mainnet RPC; the script in
  C3 T-3 lets the operator pin the endpoint).

If any prerequisite is missing the operator installs it before B3.

## B3. Transfer the private key from Mac to validator host

The transfer is one-shot and uses the operator's existing
SSH-to-validator-host path. The exact SSH invocation depends on the
operator's `~/.ssh/config` and is documented in the operator's
private SSH-access note (= classified SECRET per Constitution §4.1
S7, deliberately not reproduced in this public document).

On the operator Mac:

```sh
# 1. Read the anchor private key from Dashlane into a transient file
#    in a NON-cloud-synced directory (see A4).
ANCHOR_KEY_TMP="$(mktemp -t anchor.k1.XXXXXX)"
# Paste the PVT_K1_... value into this file; ensure no trailing whitespace.
# The file contains ONE line:  PVT_K1_<base58>

# 2. Push to the validator host with restrictive transient permissions.
scp -p "${ANCHOR_KEY_TMP}" \
    "${VALIDATOR_SSH_HOST}:/etc/freedom-yield/anchor.k1.key.incoming"
#    └─ VALIDATOR_SSH_HOST is the operator's host alias from ~/.ssh/config.
#       Do NOT inline the host or IP in any committed script per Constitution §4.1 S8.

# 3. Atomic install + harden mode/owner via a single remote sudo step.
ssh "${VALIDATOR_SSH_HOST}" 'sudo install -m 0600 -o deploy -g deploy \
    /etc/freedom-yield/anchor.k1.key.incoming \
    /etc/freedom-yield/anchor.k1.key && \
    sudo shred -u /etc/freedom-yield/anchor.k1.key.incoming'

# 4. Shred the local Mac copy.
shred -u "${ANCHOR_KEY_TMP}"
```

The `install -m 0600 -o deploy -g deploy` step makes the placement
atomic (= the file is fully owned and mode-restricted before any
other process could observe it in a permissive state). The
`shred -u` calls overwrite then unlink the source files on both
sides. The original Dashlane copy remains as the operator's
backup-of-record.

## B4. Import the key into `proton-cli` on the validator host

```sh
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash -c "
  proton chain:set proton
  proton key:add \$(sudo cat /etc/freedom-yield/anchor.k1.key)
  proton key:list
"'
```

Expected output: the new `PUB_K1_<anchor_pubkey>` appears in
`proton key:list`. The CLI keystore is per-OS-user; only `deploy`
holds it.

`proton key:add` stores the key in `~/.proton/keys` (or equivalent
per the CLI version). The `/etc/freedom-yield/anchor.k1.key` file is
retained as the canonical source for re-import after CLI reset.

## B5. Self-test from the validator host

```sh
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash -c "
  proton action eosio.token transfer '\''{
    \"from\": \"freedomyield\",
    \"to\": \"<sink_account>\",
    \"quantity\": \"0.0001 XPR\",
    \"memo\": \"fyid1:0000000000000000000000000000000000000000000000000000000000000000\"
  }'\'' freedomyield@anchor --dry-run
"'
```

Expected: the dry-run reports the action as well-formed and accepts
`freedomyield@anchor` as the required authorization. No actual
broadcast occurs.

If the dry-run fails with "permission not found" or "missing required
authorization", revisit A6 / A7 — the permission install or linkauth
did not propagate as expected. Do NOT proceed to a live broadcast
until the dry-run is clean.

## B6. Rotation (= replace the validator-host anchor key)

When the operator decides to rotate the anchor key (= routine cadence,
or in response to a suspected exposure), the procedure is:

```sh
# 1. Generate a new anchor K1 keypair on the operator Mac (per A4).
proton key:generate    # captures PUB_K1_<new>; PVT_K1_<new> to Dashlane

# 2. From the operator Mac, sign updateauth replacing the old pubkey
#    on the freedomyield@anchor permission. Either signing path
#    (WebAuth or K1) from A6 may be used; freedomyield@active is the
#    required authorization.
proton action eosio updateauth '{
  "account": "freedomyield",
  "permission": "anchor",
  "parent": "active",
  "auth": {
    "threshold": 1,
    "keys": [{"key": "PUB_K1_<new>", "weight": 1}],
    "accounts": [],
    "waits": []
  }
}' freedomyield@active

# 3. Verify on chain that anchor.keys[] now contains only PUB_K1_<new>.
curl -sS -X POST -H 'Content-Type: application/json' \
  --data '{"json":true,"account_name":"freedomyield"}' \
  https://api-xprnetwork-main.saltant.io/v1/chain/get_account \
  | jq '.permissions[] | select(.perm_name=="anchor")'

# 4. Re-execute B3 with the new private key, atomically replacing
#    /etc/freedom-yield/anchor.k1.key. Before installing, rename the
#    existing file to /etc/freedom-yield/anchor.k1.key.<old_key_seq>.retired
#    (chmod 000) for 30 days as a recovery hedge, then shred.
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u root bash -c "
  mv /etc/freedom-yield/anchor.k1.key \
     /etc/freedom-yield/anchor.k1.key.\$(date +%s).retired && \
  chmod 000 /etc/freedom-yield/anchor.k1.key.*.retired
"'

# 5. Re-execute B4 (proton key:add for the new key).
# 6. proton key:remove PUB_K1_<old> from the CLI keystore on the
#    validator host.
# 7. Self-test (B5) with the new key. Once clean, the rotation is
#    complete; the linkauth from A7 carries over (it references the
#    permission name 'anchor', not a specific pubkey).
```

A successful rotation does not regenerate `identity-history.jsonl`'s
operator identity key entry (= those are independent ed25519 keys);
it does NOT change `dag_root_hash`. The anchor inscription pipeline
keeps running uninterrupted from the next event.

If the rotation is triggered by suspected exposure of the old key,
the operator should additionally:

- Broadcast an immediate inscription with the new key to establish
  the rotation event on chain (= `event_type` is informational at
  the Phase α memo level; Phase β SC adds a dedicated `idrotate`
  event).
- Note the rotation in the operator's incident log.

## B7. Backup-of-record and recovery

The single source of truth for the anchor private key over time is
**Dashlane**. The `/etc/freedom-yield/anchor.k1.key` file on the
validator host is a live runtime copy, regenerable from Dashlane via
B3 + B4. There is no second backup of the key:

- Not on the operator's other devices.
- Not in any cloud-synced directory.
- Not in any repository, encrypted or otherwise.
- Not in the operator's email or messaging history.

Recovery scenarios:

- **Validator host wipe + restore**: re-execute B3 + B4 from
  Dashlane. The on-chain permission is unaffected; the anchor
  inscription pipeline resumes on the next event.
- **Operator Mac wipe**: Dashlane sync restores the key on the new
  Mac; B6 (rotation) is OPTIONAL — only required if the operator
  judges the Mac wipe might have leaked the key. Otherwise the
  Dashlane-restored key remains usable.
- **Dashlane account compromise**: this is a CRITICAL incident.
  Execute B6 (rotation) immediately on a clean device with a fresh
  proton-cli keystore; assume the old anchor key is in adversary
  hands and the linkauth scope (= eosio.token::transfer with
  `from = freedomyield`) is exploitable until the rotation lands.
  Note that the linkauth scope is intentionally narrow: the
  adversary cannot move tokens out of `freedomyield` arbitrarily,
  cannot change permissions, and cannot deploy contracts.

## B8. What B does NOT change

- The operator identity ed25519 key on the operator Mac
  (= Phase 5 / Phase 6 key, used for `ssh-keygen -Y sign` on
  `identity.json`) is untouched.
- The validator's `staker.key` and BLS `signer.key` are untouched.
- The `freedomyield@owner` and `freedomyield@active` permissions on
  XPR mainnet are untouched (Phase β work; see A9).
- The web host has no awareness of the anchor key and never receives
  it (per Constitution §5: unidirectional data flow validator → web).


