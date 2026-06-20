# Operator identity key — setup runbook (Phase 5)

> At execution time, prefer the compact one-page action list for the
> phase you are about to run:
> [`PHASE5_CHECKLIST.md`](./PHASE5_CHECKLIST.md) for the signed-
> manifest publish, [`PHASE6_CHECKLIST.md`](./PHASE6_CHECKLIST.md) for
> the per-cycle chain-anchor embed. This document is the teaching
> reference — read it once for context, then run from the matching
> checklist on the day.

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

The **chain-anchor memo** at Phase 6 commits to a *different* hash
of the same key: the SHA-256 of the published `.pub` file bytes,
which is what
[`IDENTITY_VERIFICATION.md`](./IDENTITY_VERIFICATION.md) Step 3 has
the verifier recompute. Compute and record it now so you have it
ready for Phase 6:

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
  chain_anchor:    placeholder (all-zeros) — bind at Phase 6 (next renewal)
```

The `chain_anchor` is intentionally left as the all-zeros placeholder
at Phase 5. Phase 6 (the next renewal cycle) overwrites it with the
real `tx_id` once the renewal `AddPermissionlessValidatorTx` carries
the fingerprint in its memo.

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
    artifact_root (Merkle root over <N> leaves) + chain_anchor with
    all-zeros placeholder (Phase 6 fills tx_id at next renewal).
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

The procedure to transfer the `PUB_K1_<anchor_pubkey>` private half
from the Mac to the validator host at `/etc/freedom-yield/...`, set
mode `0600 deploy:deploy`, and configure backup and rotation is
C3 T-2 and ships in a separate doc section (to be appended below
this one in a subsequent commit on the same `phase-alpha-onchain`
branch). Until T-2 lands, the anchor private key remains on the
operator Mac in the Dashlane-backed transient state described in
A4.


