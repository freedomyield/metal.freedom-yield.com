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
> as the current **v2 anchor pipeline** (2026-07-01 design revision):
> the anchor content (`/api/anchor-source.json`) is composed on the
> validator host, the transaction is **signed on the operator's local
> Mac** (`scripts/sign-anchor-event.sh` with `metalfreedom@anchor`),
> and the receipt is written back and published. The validator host
> does **NOT** broadcast — its `scripts/watch-anchor-events.sh` monitor
> is **alert-only** (installed by
> `scripts/install-anchor-watch-alert-only.sh`): it notifies the
> operator of a cycle transition, and the operator drives signing from
> the Mac. The on-chain shape is an HC-single **4-action pack** in one
> `eosio.token::transfer` transaction on Metal A-chain (= PulseVM /
> XPRNetwork): three per-branch memos (`fya<S>c<N>-id:<hex>`,
> `-ob:<hex>`, `-ar:<hex>`) plus a summary memo
> `fya<S>c<N>:<dag_root_computed_hex>` — e.g. the cycle-3 summary
> `fya1c3:<dag_root_computed>`. The value committed on chain is
> `anchor-source.json.dag_root_computed` (a 3-branch Merkle DAG over the
> identity, observations, and artifacts branches), not a single
> per-cycle artifact hash.
>
> The former `scripts/post-anchor-event.sh` host-cron broadcast model
> and the single-action `fyid1:<dag_root_hash>` memo are **RETIRED**
> (`post-anchor-event.sh` was deleted; the `fyid1v1c*` namespace was
> abandoned after the 2026-07-01 mainnet accident, tx `997881e8…`).
> Sections that still describe them below are kept as historical record
> and are flagged in place; do not follow them as current procedure.
> See [`ANCHOR_SOURCE.md`](./ANCHOR_SOURCE.md) for the authoritative v2
> pipeline.
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
the Phase α A-chain Merkle DAG anchor (= the v2 HC-single 4-action pack
with summary memo `fya<S>c<N>:<dag_root_computed>` on
`eosio.token::transfer` signed by `metalfreedom@anchor`; the retired
`fyid1:<dag_root_hash>` single-action shape it replaced is described in
the banner above), which commits to `anchor-source.json.dag_root_computed`
— a 3-branch Merkle DAG over the identity, observations, and artifacts
branches (= a strictly broader commitment than the single-key hash). The `.pub` byte hash is still useful as an
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
  artifact leaves:      <listed> listed / <pinned> pinned
  unpinned (kind=stream): evidence_json, validator_json, cycle_history_jsonl, uptime_cycles_json
  registry:             .../deploy/publication.json
  artifact_root:   <64-hex>   (Merkle over the <pinned> pinned digest(s))
  identity_branch_root: <64-hex>   (= identity-history.jsonl Merkle root)
  cycles_branch_root:   <64-hex>   (= cycle-history.jsonl Merkle root)
  dag_root_hash:        <64-hex>   (= SHA-256(raw(id_root)||raw(cy_root)))
  anchor summary memo:  fya<S>c<N>:<dag_root_computed>  (v2 A-chain inscription; historical fyid1: shape retired — see banner)
```

Under the v2 pipeline the value inscribed on Metal A-chain (= PulseVM /
XPRNetwork) is `anchor-source.json.dag_root_computed` (the 3-branch DAG
root), signed on the operator's local Mac via
`scripts/sign-anchor-event.sh` — NOT via the deleted
`scripts/post-anchor-event.sh` host-cron path. Until an anchor is signed
for the cycle, `/api/anchor-receipt.json` is absent or stale.
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
    artifact_root (Merkle root over <N> leaves). Phase α A-chain
    inscription is performed separately by the v2 pipeline: composed on
    the validator host, signed on the operator Mac via
    scripts/sign-anchor-event.sh (the value inscribed is
    anchor-source.json.dag_root_computed, not a field on identity.json).
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

- **Time-of-flight skew.** ~~If `evidence.json` updates between the
  moment `gen-identity.sh` fetched it and the moment a verifier
  fetches it, the verifier's recomputed leaf sha256 will not match
  the manifest's claim. Re-run `gen-identity.sh` to refresh the
  manifest. For frequently-updated leaves this is unavoidable; the
  manifest binds the set at signing time, not in perpetuity.~~
  **REVISED 2026-08-14 (C4).** "Re-run to refresh" was never a real
  remedy: `validator.json` was measured changing twice inside one
  20-minute window on 2026-08-06, so no signing cadence could keep up.
  The manifest now declines to pin any publication whose
  `deploy/publication.json` kind is `stream`, so this skew has no
  surface left — those entries carry no digest to disagree with. The
  point-in-time digests still exist where they can be timestamped by
  something other than the operator: `anchor-source.json`
  `.artifacts_branch`, folded into the on-chain `dag_root_computed`.
  Skew remains possible only for `static` / `record` artifacts, where
  it means a genuine problem and `scripts/check-identity-pins.sh`
  reports it.

- **`.pub` content-type.** The web host serves `.well-known/*.pub`
  with whatever MIME type its config dictates. The verifier doesn't
  care about the MIME type — `ssh-keygen` parses the body — but if
  you find the response surprising, check the web host's `mime.types`
  for an explicit mapping. There is no requirement to add one.

## Repairing a broken artifact pin

`scripts/check-identity-pins.sh` runs TWO independent checks and can fail
CI / push a live alert for either one. They look similar in the log (both
name a pin id) but need different fixes — read the exit code and the line
prefix (`MISMATCH`/`MISSING` vs `KIND-VIOLATION`/`KIND-UNKNOWN`/
`KIND-INVALID`) before picking a repair path.

### Check 1 — a pinned digest no longer matches (exit 3)

`scripts/check-identity-pins.sh` fails CI (exit 3) when a **git-tracked**
file pinned by `artifact_manifest` no longer hashes to its pinned value, and
the daily `--mode=live` cron pushes one high-priority alert for the same
condition on the served site. That state means an ordinary commit changed a
file whose bytes a signed manifest had already committed to — which is how
`7dfc3c4` (2026-08-05, a schema widening) invalidated the manifest signed by
`90bcdd9` the day before, unnoticed for two days.

**CI cannot repair this.** `identity.json` is signed with the operator's
passphrase-protected ed25519 key on the operator's Mac, and per Constitution
§3.3 that key never reaches CI. Detection is automatic; the repair is manual.
Pick one:

**A — do not change the pinned file.** Revert the edit to the git-tracked
artifact. The pin becomes valid again with no re-signing.

**B — keep the change and re-issue the manifest.**

1. Land and deploy the artifact change first, so the live bytes are final.
   Re-signing against bytes that are about to change just moves the break.
2. On the operator Mac:

   ```sh
   export OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity
   bash scripts/operator-local/gen-identity.sh
   ```

   At a cycle transition add `FY_EXPECT_CYCLE=<the cycle just closed>` so the
   ordering guard runs (see step 3 above).
3. Commit `public/api/identity.json` + `public/api/identity.json.sig`.
4. Remove the now-obsolete entry from `deploy/identity-pin-baseline.json`.
   The checker prints an `OBSOLETE-BASELINE` line naming every entry that has
   become unnecessary — an obsolete entry is not an error, but leaving it
   there hides the next real break behind stale bookkeeping.
5. Remove the now-obsolete entry from `deploy/publication.json`'s
   `known_kind_violations.violations`. The checker prints an
   `OBSOLETE-KIND-ACK` line for each one, naming why it expired: the manifest
   no longer carries that pin, the entry's declared `path` is not what the
   manifest actually pins, or the target is no longer `kind=stream`. Same
   status as `OBSOLETE-BASELINE` — **report-only**: it never changes the exit
   code and never pushes, because an expired acknowledgement is bookkeeping
   rather than breakage. What *does* fail is `tests/publication-registry/`'s
   `T7`, in CI, inside the commit that left the entry behind. **At the
   2026-09-04 transition this is step 4b of `docs/CYCLE_GATE.md`** and the
   whole list expires at once, so you should see zero `OBSOLETE-KIND-ACK`
   lines both before that commit and after it — seeing them means one half of
   that commit landed without the other.

**What the checker deliberately stays quiet about.** Pins whose target is a
push-owned feed (`deploy/feed-excludes.txt`: `evidence.json`,
`validator.json`, `uptime-cycles.json`, `cycle-history.jsonl`) are rewritten
by host cron on their own cadence, so their pins are stale within minutes of
signing — the "time-of-flight skew" pitfall above, made permanent. Those are
recorded as `STRUCTURAL` in the log and never alert or fail; re-signing does
not fix them, because they break again immediately. Removing moving payloads
from the signed manifest is tracked separately as C4.

### Check 2 — the kind gate: a pin exists that should not (exit 6, added 2026-08-17)

`scripts/check-identity-pins.sh` also fails CI / pushes a live alert (exit 6,
line prefix `KIND-VIOLATION` / `KIND-UNKNOWN` / `KIND-INVALID`) when
`artifact_manifest` pins a publication that `deploy/publication.json`'s
`kind` says it must not, or cannot yet vouch for. Unlike Check 1, re-signing
against the CURRENT bytes never fixes this — the problem is not that the
digest is stale, it is that the digest should not exist at all. Read the
line prefix:

- **`KIND-VIOLATION`** — the pin targets a `kind=stream` publication (bytes
  can change without a commit — host cron, runtime push) and it is not
  acknowledged in `deploy/publication.json`'s `known_kind_violations`. Two
  valid fixes:
  - **Re-issue the manifest.** `scripts/operator-local/gen-identity.sh`
    never pins a `kind=stream` publication by construction (its own C4
    discipline), so simply re-running step B above (`gen-identity.sh` →
    commit `identity.json` + `.sig`) drops the pin. This is the expected
    fix for a NEW stream pin that should never have appeared.
  - **Acknowledge it**, only if it is a still-open, already-understood case
    (e.g. mid-transition, before the day's `gen-identity.sh` re-issue has
    landed): add an entry to `deploy/publication.json`'s
    `known_kind_violations.violations`, keyed by the EXACT pin id the
    `KIND-VIOLATION` line names (e.g. `"evidence_json.sha256"`), following
    the shape of the existing entries there. This is the SAME list
    `tests/publication-registry/test-publication-registry.sh`'s `T7` holds
    to account — an entry that stops describing a real violation (the pin
    disappears, or the path's kind changes) is caught there as `OBSOLETE`,
    so do not leave a stale acknowledgement behind once the manifest is
    re-issued. The checker tells you the same thing from its own side: it
    prints an `OBSOLETE-KIND-ACK` line naming every expired entry —
    report-only, no exit code, no push — so a run that is green apart from
    those lines is telling you the acknowledgement list, not the manifest,
    is what still needs the edit. See step 5 of Check 1 above.
- **`KIND-UNKNOWN`** — the pin's target has NO row at all in
  `deploy/publication.json`'s `publications[]`, so the checker cannot tell
  whether pinning it is safe and refuses to guess. Add a row for the
  publication with its correct `kind`. If that turns out to be `stream`,
  this becomes the `KIND-VIOLATION` case above.
- **`KIND-INVALID`** — a row exists, but its `kind` value is none of
  `stream` / `static` / `record` (a typo, or a genuinely new kind this
  checker predates). Fix the typo, or — if a new kind is actually being
  introduced — that requires a code change in BOTH
  `scripts/check-identity-pins.sh` (the `case "$RKIND" in` allowlist) and
  `scripts/operator-local/gen-identity.sh` (`kind_is_pinnable()`) in the
  SAME change; this is not an operator-side fix on the day of a transition.

**docs/CYCLE_GATE.md step 4b** (the mandatory post-issuance cleanup after
`gen-identity.sh`'s C4 landing, 2026-08-14) is the concrete instance of the
"re-issue the manifest" fix above, applied to the four pins the manifest
signed before C4 still carries: it clears
`known_kind_violations.violations` to `{}` in the SAME commit as the new
`identity.json`, because a re-issued manifest carrying none of those four
pins makes the acknowledgement entries `OBSOLETE` the instant it lands —
`T7` says so as `OBSOLETE` in CI, the checker says so as `OBSOLETE-KIND-ACK`
on the host. Landing only one half of that commit is exactly what makes
either of them speak.

---

# A-chain anchor account — permission setup (Phase α)

> This section is operationally distinct from the Phase 5 operator
> identity ed25519 setup above: different chain (Metal A-chain =
> PulseVM / XPRNetwork), different key family (EOSIO K1 secp256k1 +
> WebAuth P-256), different tooling (`proton-cli` / webauth.com). The
> `metalfreedom` XPR account is the on-chain anchor for the Merkle DAG
> identity model; permission structure follows the design in
> `project_merkle_dag_identity_anchor_design.md`.
>
> Phase α scope is **additive only**: a new narrow `anchor` permission
> is added as a child of `active`. Owner rotation and active tightening
> are deferred to Phase β.

## A1. Current state (live-verified 2026-06-20, XPR mainnet)

Read-only verification via the public chain RPC
(`https://api-xprnetwork-main.saltant.io/v1/chain/get_account` with
`{"account_name":"metalfreedom"}`) returns:

| field | value |
| --- | --- |
| `account_name` | `metalfreedom` |
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
metalfreedom
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
  is compromised: it can sign transfers from `metalfreedom`, but
  cannot change permissions, deploy contracts, or sign other system
  actions.
- Owner rotation to WebAuth-only and any active-permission tightening
  are explicitly Phase β work (see A9).

## A3. Prerequisites

- `proton-cli` 0.1.98+ installed on the operator Mac
  (verify: `proton --version`).
- `metalfreedom@active` signing capability — one of:
  - WebAuth biometric via `webauth.com` or Proton wallet app (uses
    the existing `PUB_WA_3hftgAo...` credential on `active`). No
    K1 private key required.
  - The K1 private key for `EOS6w1ufdiYuZs9Q...` imported via
    `HOME=~/.metal-fy-proton proton key:add`. Subject to Decision #2 in
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
NOT reused from any existing key on `metalfreedom`.

```sh
HOME=~/.metal-fy-proton proton key:generate
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
HOME=~/.metal-fy-proton-test proton chain:set proton-test

# Generate a throwaway test key and provision a test account
# (operator: signup via webauth.com testnet or proton testnet faucet).
# The test account name is local-only; do not name it after the
# planned production sink or any brand identifier.

# Reproduce A6 + A7 + A8 against the test account.
# All three steps MUST PASS, with explorer-visible permission and
# linkauth, before any mainnet command is issued.

# Keystore separation (§3.5): mainnet commands always run with
# HOME=~/.metal-fy-proton, which stays pinned to the mainnet chain
# context independent of this testnet keystore. No "switch back"
# step is needed or should be run here.
```

The testnet PASS is part of the IC-2 deliverable (C3 → C1 by
2026-06-30 per `project_phase_alpha_coordination_log.md`).

## A6. Add the `anchor` permission as a child of `active`

This action requires `metalfreedom@active`. The current active has
both a K1 key and a WebAuth credential; either is sufficient (single
key threshold).

**Path 1 — sign with WebAuth via the wallet UI:**

The action must be composed in `webauth.com` or the Proton wallet
app, because `proton-cli` does not sign with `PUB_WA_` credentials.
The action payload to compose is the `eosio` system contract
`updateauth` action, with the JSON payload shown in Path 2 below.

**Path 2 — sign with the K1 private key via `proton-cli`:**

Requires the K1 private key for `EOS6w1ufdiYuZs9Q...` to be present
in the local `proton-cli` keystore (`HOME=~/.metal-fy-proton proton key:add` first).

```sh
HOME=~/.metal-fy-proton proton action eosio updateauth '{
  "account": "metalfreedom",
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
}' metalfreedom@active
```

Expected: the CLI returns the transaction id; the chain accepts the
action; the new `anchor` permission appears under `metalfreedom` in
the next account read.

## A7. Link the `anchor` permission to `eosio.token::transfer`

```sh
HOME=~/.metal-fy-proton proton action eosio linkauth '{
  "account": "metalfreedom",
  "code": "eosio.token",
  "type": "transfer",
  "requirement": "anchor"
}' metalfreedom@active
```

Effect: for actions where `from = metalfreedom` on `eosio.token::transfer`,
the chain accepts `metalfreedom@anchor` as sufficient authorization
(in addition to the default `metalfreedom@active`). No other
`eosio.token` action and no other contract action is reached by this
linkauth.

`<action>` is restricted to `transfer` deliberately; omitting it
would link `anchor` to ALL actions of `eosio.token`, which would
unnecessarily widen `anchor`'s authority.

**Phase β preview** (not executed in Phase α): when the
`metalfreedom::inscribe` action is deployed (T-4 SC spec), an
additional `linkauth` will be issued:

```
{"account":"metalfreedom","code":"metalfreedom",
 "type":"inscribe","requirement":"anchor"}
```

This will give `anchor` the authority to call the SC inscribe action
without touching the `eosio.token::transfer` linkauth installed in
this Phase α step.

## A8. Post-mainnet verification

```sh
# Re-read the account; expect the new `anchor` permission to appear
# under `metalfreedom.permissions`, parent=active, with the
# <anchor_pubkey> from A4 as the sole key.
curl -sS -X POST -H 'Content-Type: application/json' \
  --data '{"json":true,"account_name":"metalfreedom"}' \
  https://api-xprnetwork-main.saltant.io/v1/chain/get_account \
  | jq '.permissions[] | select(.perm_name=="anchor")'

# Linkauth verification: a dry-run transfer signed by anchor should
# be accepted by chain rules (replace <sink_account> with the
# confirmed sink name; <root_hash> is any 64-hex placeholder for the
# verification dry-run).
HOME=~/.metal-fy-proton proton action eosio.token transfer '{
  "from": "metalfreedom",
  "to": "<sink_account>",
  "quantity": "0.0001 XPR",
  "memo": "fya<S>c<N>:<root_hash>"
}' metalfreedom@anchor --dry-run
```

Expected: the dry-run reports the action as well-formed and accepts
`metalfreedom@anchor` as the required authorization. No actual
broadcast occurs with `--dry-run`.

The corresponding live broadcast is the Phase α anchor path. Under the
v2 pipeline it is a 4-action pack signed on the operator's local Mac via
`scripts/sign-anchor-event.sh` (the deleted
`scripts/post-anchor-event.sh` host-cron driver is no longer part of
this path).

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
- **SC deploy on `metalfreedom`**: the contract spec is C3 T-4
  deliverable (`scripts/operator-local/contract/`
  `metalfreedom-anchor.spec.md`). Deploy is Phase β; the contract is
  NOT deployed during Phase α.
- **Additional linkauth for `metalfreedom::inscribe`**: see A7
  Phase β preview block.
- **Optional sink-account hardening**: e.g. multisig on the sink, a
  no-op contract on the sink that ignores or logs incoming transfers,
  etc. The minimal Phase α sink is a plain account with default
  permissions, sufficient to satisfy `eosio.token::transfer`'s
  `is_account(to)` check.

## A10. Anchor key validator host deploy

> **RETIRED (2026-07-01 anchor design revision / v2 Mac-sign model) —
> historical record, do NOT follow as current procedure.** This step,
> and the whole of section **B** below, describe the old model in which
> the `anchor` private key was deployed to the validator host and the
> anchor was signed *on the host*. That model is gone. Under the current
> v2 pipeline the anchor is **signed only on the operator's Mac**
> (`scripts/sign-anchor-event.sh`, using the Mac-local `proton-cli`
> keystore); the private key is **never distributed to the validator
> host**, and the host's `scripts/watch-anchor-events.sh` is
> **alert-only** (it notifies the operator of a cycle transition and
> broadcasts nothing). Deploying the key to the host and leaving the
> on-host wallet unlocked is precisely the configuration that caused the
> 2026-07-01 mainnet anchor-namespace pollution incident, so this model
> was retired deliberately. Authoritative current pipeline:
> [`ANCHOR_SOURCE.md`](./ANCHOR_SOURCE.md). The text below is preserved
> only as a historical record.

Historically: see section **B** below (now also RETIRED). Until B was
executed, the anchor private key remained on the operator Mac in the
Dashlane-backed transient state described in A4. Under that retired
model the mainnet `eosio.token::transfer` broadcast (= the production
Phase α inscription) could not run from the validator host until B was
complete. (Under the current v2 model there is no host deploy at all;
the broadcast is composed and signed on the operator Mac.)

---

# B. Validator-host deploy of the `anchor` private key (Phase α)

> **RETIRED (2026-07-01 anchor design revision / v2 Mac-sign model) —
> historical record, do NOT follow as current procedure.** This entire
> section (B1–B8) describes the old model in which the `anchor` private
> key was distributed to the validator host and the anchor was signed
> *on the host* (originally cron-triggered). That model has been retired.
> Under the current v2 pipeline:
>
> - The anchor is **signed only on the operator's Mac**
>   (`scripts/sign-anchor-event.sh`), using the Mac-local `proton-cli`
>   keystore. The `PVT_K1_…` anchor private key is **never deployed to
>   the validator host** — the transfer / import / keystore-password
>   steps below (B3, B4, B4.5) are not performed.
> - The validator host's `scripts/watch-anchor-events.sh` is
>   **alert-only** (installed by
>   `scripts/install-anchor-watch-alert-only.sh`): it notifies the
>   operator of a cycle transition and broadcasts nothing.
> - The authoritative description of the current pipeline is
>   [`ANCHOR_SOURCE.md`](./ANCHOR_SOURCE.md).
>
> **Why it was retired:** deploying the key to the host and leaving the
> on-host wallet unlocked so that a cron could sign unattended is exactly
> the configuration that led to the 2026-07-01 mainnet anchor-namespace
> pollution incident. The v2 model keeps the key on the operator Mac and
> puts a human in the loop for every signature by design. This section is
> preserved only to keep the historical record and its operational
> lessons. (§B5b already carries its own, more specific, RETIRED banner
> for the cron-triggered unlock model; it is not repeated here.)

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

> **RETIRED — historical record, do NOT follow as current procedure.**
> Part of the retired host-key-deploy model; see the RETIRED banner under
> section **B** above. Under the current v2 Mac-sign model no anchor key
> is deployed to the validator host.

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

> **RETIRED — historical record, do NOT follow as current procedure.**
> Part of the retired host-key-deploy model; see the RETIRED banner under
> section **B** above. Under the current v2 Mac-sign model no anchor key
> is deployed to the validator host.

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

> **RETIRED — historical record, do NOT follow as current procedure.**
> Part of the retired host-key-deploy model; see the RETIRED banner under
> section **B** above. Under the current v2 Mac-sign model the anchor
> private key is **never** transferred to the validator host — this step
> is not performed.

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

> **RETIRED — historical record, do NOT follow as current procedure.**
> Part of the retired host-key-deploy model; see the RETIRED banner under
> section **B** above. Under the current v2 Mac-sign model the anchor key
> lives only in the operator Mac's `proton-cli` keystore; it is not
> imported on the validator host.

```sh
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash -c "
  HOME=~/.metal-fy-proton proton chain:set proton
  HOME=~/.metal-fy-proton proton key:add \$(sudo cat /etc/freedom-yield/anchor.k1.key)
  HOME=~/.metal-fy-proton proton key:list
"'
```

Expected output: the new `PUB_K1_<anchor_pubkey>` appears in
`proton key:list`. The CLI keystore is per-OS-user; only `deploy`
holds it.

`proton key:add` stores the key in `~/.proton/keys` (or equivalent
per the CLI version). The `/etc/freedom-yield/anchor.k1.key` file is
retained as the canonical source for re-import after CLI reset.

## B4.5. Wallet keystore password (= 32-character secret created during B4)

> **RETIRED — historical record, do NOT follow as current procedure.**
> Part of the retired host-key-deploy model; see the RETIRED banner under
> section **B** above. Under the current v2 Mac-sign model there is no
> on-host wallet keystore, so no on-host keystore password is created.

`proton-cli` 0.1.98's `proton key:add` does not simply append the key
bytes to a plaintext file. On its first invocation for a given OS user,
it prompts to **create a wallet keystore** that wraps the K1 private key
with a symmetric password. Every subsequent `proton key:unlock` (B5b)
re-enters that password to decrypt the wrapper.

This password is a separate secret from the `PVT_K1_…` private key
itself. Both must be stored in Dashlane; either alone is insufficient
to broadcast.

### What to enter at the wallet-creation prompt

When `proton key:add` (B4) runs for the first time, the operator must:

1. Choose a **32-character** password. Use Dashlane's password
   generator: length 32, default character set (no symbol-class
   restrictions). 32 chars matches the operator-standard set elsewhere
   in this project and gives the operator-Mac side a uniform
   keystore-secret format.
2. Enter the password at the prompt (no echo).
3. Re-enter the password at the confirmation prompt.
4. Save the password to Dashlane immediately, under a distinct entry
   name from the `PVT_K1_…` entry. Suggested entry names:
   - K1 private key: `metalfreedom anchor K1 (PVT_K1_)`
   - Wallet keystore password: `metalfreedom anchor wallet (32-char keystore)`

### Why two separate Dashlane entries

Keeping the K1 private key and the wallet password in distinct entries
makes the runbook unambiguous at B5b (= the 13:00 JST cycle-trigger
window): "the 32-character keystore password from Dashlane" refers
exactly to the second entry, not to the K1 private key. Single-entry
storage tends to produce on-the-day confusion under time pressure.

### Verification

After B4 completes successfully, the operator can confirm the wallet
exists and that the password is known by running B5b's
`HOME=~/.metal-fy-proton proton key:unlock` once during initial setup (=
not waiting until cycle day). If `proton key:unlock` fails with
"incorrect password", the
operator has either mistyped the saved password in Dashlane, or
`proton key:add` did not in fact prompt for a wallet password on this
CLI version (older proton-cli builds store the key in plaintext under
`~/.proton/keys` instead). In the plaintext-storage case, B5b is moot
and the runbook can skip the unlock step on cycle day — but verifying
which case applies before cycle day is mandatory.

## B5. Self-test from the validator host

```sh
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash -c "
  HOME=~/.metal-fy-proton proton action eosio.token transfer '\''{
    \"from\": \"metalfreedom\",
    \"to\": \"<sink_account>\",
    \"quantity\": \"0.0001 XPR\",
    \"memo\": \"fya1c0:0000000000000000000000000000000000000000000000000000000000000000\"
  }'\'' metalfreedom@anchor --dry-run
"'
```

Expected: the dry-run reports the action as well-formed and accepts
`metalfreedom@anchor` as the required authorization. No actual
broadcast occurs.

If the dry-run fails with "permission not found" or "missing required
authorization", revisit A6 / A7 — the permission install or linkauth
did not propagate as expected. Do NOT proceed to a live broadcast
until the dry-run is clean.

## B5b. Pre-cycle keystore unlock (RETIRED — cron-triggered host broadcast model)

> **RETIRED (2026-07-01 anchor design revision) — historical record, do
> NOT follow as current procedure.** This entire section describes the
> old model in which the validator host ran a cron-triggered
> `scripts/post-anchor-event.sh` that broadcast the anchor from the host,
> requiring the on-host `proton-cli` keystore to be unlocked before each
> cycle. That model is gone: `scripts/post-anchor-event.sh` was deleted,
> and under the v2 pipeline the anchor is **signed on the operator's
> local Mac** (`scripts/sign-anchor-event.sh`). The host's
> `scripts/watch-anchor-events.sh` monitor is now **alert-only**
> (installed by `scripts/install-anchor-watch-alert-only.sh`): it
> notifies the operator of a cycle transition and performs no broadcast,
> so there is no on-host keystore to unlock and no cron-hang failure mode
> to recover from. The keystore that matters now lives on the operator
> Mac; unlock it there before signing. Everything below is preserved
> only to explain the historical behaviour and the 2026-06-24 testnet
> rehearsal. Authoritative current pipeline: [`ANCHOR_SOURCE.md`](./ANCHOR_SOURCE.md).

`proton-cli` 0.1.98 stores the K1 anchor private key in an encrypted
keystore on disk. Every `proton action ...` invocation requires the
keystore to be **unlocked** before signing.

The unlock state is held by `proton-cli`'s on-host runtime layer
(observed empirically: see §Persistence below). Once unlocked, it
survives across SSH disconnects and cron-spawned child processes, and
persists until the validator host reboots, `proton key:lock` is run,
or the holding process is killed. The 2026-06-24 testnet rehearsal
confirmed this: after the operator unlocked once in a TTY-attached
shell, the cron-triggered broadcast completed in ~30 seconds despite
running in a separate process group with no inherited shell state.

When the cron-triggered `scripts/post-anchor-event.sh` invokes
`scripts/sign-anchor-event.sh`, the underlying `proton action` call
will silently prompt for the keystore password if the keystore is
locked. The cron environment has no TTY, so the prompt is never
satisfied and the broadcast hangs indefinitely. This was observed in
the 2026-06-24 testnet rehearsal (memo: `fyid1:c999…9c9`, tx
`7ac64867…`): the first two invocations hung for >5 minutes each
until `proton key:unlock` was run manually in a TTY-attached
terminal, after which the broadcast completed in ~30 seconds.

### Required pre-cycle step

Before each cycle transition broadcast (= each time
`scripts/post-anchor-event.sh` is expected to fire), the operator
MUST manually unlock the keystore on the validator host:

```sh
ssh -t "${VALIDATOR_SSH_HOST}" 'sudo -u deploy HOME=~/.metal-fy-proton proton key:unlock'
# The -t flag forces remote PTY allocation so the password prompt has
# a controlling terminal to read from. Without -t, the prompt cannot
# be satisfied (it either errors out on /dev/tty open or echoes the
# password to the local terminal in cleartext). Enter the 32-character
# wallet keystore password from Dashlane when prompted (see B4.5 for
# where this password came from). The TTY is yours; this is the one
# place the prompt is satisfiable.
```

Expected output: `Success: Unlocked wallet`.

Verify the unlocked state:

```sh
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy HOME=~/.metal-fy-proton proton key:list'
# Expect every key tagged with `(unlocked)` rather than `(locked)`.
# -t not needed here — key:list does not prompt for input.
```

### Persistence

The keystore remains unlocked until:
- The validator host reboots, or
- `proton key:lock` is run, or
- The proton-cli process group that holds the unlocked state is
  killed.

In practice on a long-lived validator host, the operator only needs
to re-unlock after a reboot. For the **2026-07-04 cycle 3 start**
specifically, the operator should `HOME=~/.metal-fy-proton proton
key:unlock` at any point between system boot and the cycle's 13:00 JST
trigger window, and confirm via `HOME=~/.metal-fy-proton proton
key:list` immediately before the cron tick is expected.

### Failure mode if the operator forgets

If the cron triggers a broadcast with a locked keystore, the chain is:

1. cron fires `scripts/watch-anchor-events.sh` (= the cron-driven
   entry point, every 5 minutes) which polls metalgo and, on a
   detected presence-transition, synchronously invokes
   `scripts/post-anchor-event.sh`.
2. `post-anchor-event.sh` invokes `scripts/sign-anchor-event.sh`.
3. `sign-anchor-event.sh` invokes `proton action ...`.
4. The cron environment has no controlling terminal, so `proton
   action`'s password prompt — which the CLI satisfies by opening
   `/dev/tty` — cannot be answered. The call does not exit; the
   process hangs indefinitely.
5. No receipt is produced, no `last-anchored-root` state file is
   updated, and the cycle's anchor is missing on chain.

**Pile-up under `*/5 * * * *` cadence.** `scripts/watch-anchor-events.sh`
fires every 5 minutes with no `flock`, no `timeout`, no PID/self-check,
and no concurrency guard — and it only writes
`anchor-watcher-state.json` *after* the driver returns. While the first
invocation is blocked on the password prompt, the state file still shows
the pre-transition `is_present` value, so every subsequent 5-minute tick
re-detects the same transition and starts a fresh hung pipeline on top
of the previous one. The steady-state observation is therefore
**N ≥ (minutes-since-hang / 5) + 1** stacked hangs, not a single one.
The 2026-06-24 testnet rehearsal already saw N=2 within ~10 minutes.

### Detection

Within ~5 minutes of the expected cycle transition, check:

```sh
ssh "${VALIDATOR_SSH_HOST}" 'pgrep -af "proton action"'
```

A non-empty result (one or more entries) combined with the absence of
a fresh line in `/api/anchor-history.jsonl` indicates the locked-keystore
hang. The reported number of `proton action` entries grows by 1 every
5 minutes until recovery, so the count is also a rough age indicator.

Note: matching by the absolute interpreter path (e.g.
`node /usr/local/bin/proton action`) is install-path-specific and
fails under nvm, custom npm prefixes, yarn-global, or shell-wrapper
installs. Use the substring match shown above.

### Recovery

```sh
# 1. Enumerate the full pile of hung pipeline chains (typically N ≥ 2).
ssh "${VALIDATOR_SSH_HOST}" 'pgrep -af "proton action"'
ssh "${VALIDATOR_SSH_HOST}" 'pgrep -af anchor-event'
ssh "${VALIDATOR_SSH_HOST}" 'pgrep -af watch-anchor-events'

# 2. Kill every hung process across all three layers. Each cron tick
#    spawned a watch → post-anchor-event → sign-anchor-event → proton
#    chain, so killing only the leaf `proton` leaves the wrappers
#    holding their wait() — and the next 5-minute tick spawns yet another
#    chain on top.
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy pkill -f "proton action"'
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy pkill -f anchor-event'
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy pkill -f watch-anchor-events'

# 3. Unlock the keystore in a real TTY (see "Required pre-cycle step"
#    above for why -t is mandatory).
ssh -t "${VALIDATOR_SSH_HOST}" 'sudo -u deploy HOME=~/.metal-fy-proton proton key:unlock'

# 4. Before re-broadcasting, confirm no earlier attempt actually
#    landed on chain. The hang in step 4 of the failure chain above
#    is normally pre-broadcast (proton action stalls at /dev/tty
#    open BEFORE signing), but a chain that crashed AFTER signing
#    but BEFORE `last-anchored-root` updated would leave a real
#    inscription on chain. Re-broadcasting in that case produces a
#    duplicate `fyid1:<dag_root_hash>` memo. Check first:
ssh "${VALIDATOR_SSH_HOST}" "curl -sS -X POST \"\${XPR_RPC_BASE:-https://proton.eosusa.io}/v1/history/get_actions\" \
    -H 'Content-Type: application/json' \
    -d '{\"account_name\":\"metalfreedom\",\"pos\":-1,\"offset\":-50}' \
    | jq '[.actions[] | select(.action_trace.act.data.memo // \"\" | startswith(\"fyid1:\"))] | .[0:5] | .[] | {tx: .action_trace.trx_id, memo: .action_trace.act.data.memo, time: .block_time}'"
# If the table above already contains a row whose memo matches the
# expected `fyid1:<dag_root_hash>` of THIS cycle, the broadcast
# landed despite the hang. Update the state file manually instead of
# re-broadcasting:
#   ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash -c "echo <dag_root_hash> > /var/lib/freedom-yield/last-anchored-root"'

# 5. Re-trigger the broadcast manually. The script requires
#    --event-type and (for cyclestart / cycleend) --cycle-n; both
#    are documented in the script's header. For the 2026-07-04
#    cycle 3 start specifically:
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/post-anchor-event.sh \
    --event-type cyclestart --cycle-n 3'
# For other event types use:
#   --event-type cyclestart|cycleend|idrotate
#   --cycle-n N   (required for cyclestart and cycleend, omit for idrotate)
#   --key-seq K   (required for idrotate, omit for cyclestart/cycleend)
```

For the **pre-broadcast hang** that B5b describes (= the steady-state
failure mode where step 4 of the failure chain stalls at `/dev/tty`
open BEFORE the signer ever signs), the re-run cannot produce a
duplicate inscription because the chain has never seen this
`dag_root_hash` — the hung process never reached the broadcast call.
The state file being unchanged is what permits the retry (the
`post-anchor-event.sh` idempotency gate at line 214 takes the no-op
branch only when `last-anchored-root == dag_root_hash`), not what
guarantees no duplicate. For post-broadcast failure modes (= broadcast
landed but state file was not updated, e.g. SIGKILL between proton's
return and the state-file write), the explicit on-chain check in
step 4 above is the only safeguard.

### Why this is not automated away

A "store keystore password in a daemon" or "feed password from a
config file" model is technically possible but expands the secret
surface (= password lives in another file / service). For a single
monthly cycle transition the manual unlock is cheaper than the
operational complexity of automated key handling. Revisit if Phase
β changes the cadence.

## B6. Rotation (= replace the validator-host anchor key)

When the operator decides to rotate the anchor key (= routine cadence,
or in response to a suspected exposure), the procedure is:

```sh
# 1. Generate a new anchor K1 keypair on the operator Mac (per A4).
HOME=~/.metal-fy-proton proton key:generate    # captures PUB_K1_<new>; PVT_K1_<new> to Dashlane

# 2. From the operator Mac, sign updateauth replacing the old pubkey
#    on the metalfreedom@anchor permission. Either signing path
#    (WebAuth or K1) from A6 may be used; metalfreedom@active is the
#    required authorization.
HOME=~/.metal-fy-proton proton action eosio updateauth '{
  "account": "metalfreedom",
  "permission": "anchor",
  "parent": "active",
  "auth": {
    "threshold": 1,
    "keys": [{"key": "PUB_K1_<new>", "weight": 1}],
    "accounts": [],
    "waits": []
  }
}' metalfreedom@active

# 3. Verify on chain that anchor.keys[] now contains only PUB_K1_<new>.
curl -sS -X POST -H 'Content-Type: application/json' \
  --data '{"json":true,"account_name":"metalfreedom"}' \
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

# 5. Re-execute B4 (HOME=~/.metal-fy-proton proton key:add for the new key).
# 6. HOME=~/.metal-fy-proton proton key:remove PUB_K1_<old> from the CLI
#    keystore on the validator host.
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
**Dashlane**, in two distinct entries:

1. The K1 anchor private key (`PVT_K1_…`), created in A4.
2. The 32-character wallet keystore password, created in B4.5.

Both are required to broadcast: the K1 key alone cannot sign because
the on-host keystore wraps it; the wallet password alone cannot sign
because it is only a wrapper for a key that is also stored separately.
The `/etc/freedom-yield/anchor.k1.key` file on the validator host is a
live runtime copy of (1), regenerable from Dashlane via B3 + B4 (and
B4.5 re-establishes the wrapper). There is no second backup of either
secret:

- Not on the operator's other devices.
- Not in any cloud-synced directory.
- Not in any repository, encrypted or otherwise.
- Not in the operator's email or messaging history.

Recovery scenarios:

- **Validator host wipe + restore**: re-execute B3 + B4 + B4.5 from
  Dashlane, then run B5b before the next cron tick. The on-chain
  permission is unaffected. The freshly imported keystore is in the
  **locked** state until B5b's `proton key:unlock` runs — without
  it, the first cron-triggered broadcast after recovery will hang
  exactly as B5b's "Failure mode" subsection describes, and the
  cycle's anchor will be silently missed.
- **Operator Mac wipe**: Dashlane sync restores the key on the new
  Mac; B6 (rotation) is OPTIONAL — only required if the operator
  judges the Mac wipe might have leaked the key. Otherwise the
  Dashlane-restored key remains usable.
- **Dashlane account compromise**: this is a CRITICAL incident.
  Both secrets — the K1 private key and the wallet keystore password
  — are exposed; the adversary can decrypt and use the key on any
  clean machine. Execute B6 (rotation) immediately on a clean device
  with a fresh proton-cli keystore; assume the old anchor key is in
  adversary hands and the linkauth scope (= eosio.token::transfer with
  `from = metalfreedom`) is exploitable until the rotation lands.
  Note that the linkauth scope is intentionally narrow: the
  adversary cannot move tokens out of `metalfreedom` arbitrarily,
  cannot change permissions, and cannot deploy contracts. After
  rotation, generate a new 32-character wallet password (per B4.5) and
  save it to the new Dashlane account; do not reuse the compromised
  password.

## B8. What B does NOT change

- The operator identity ed25519 key on the operator Mac
  (= Phase 5 / Phase 6 key, used for `ssh-keygen -Y sign` on
  `identity.json`) is untouched.
- The validator's `staker.key` and BLS `signer.key` are untouched.
- The `metalfreedom@owner` and `metalfreedom@active` permissions on
  XPR mainnet are untouched (Phase β work; see A9).
- The web host has no awareness of the anchor key and never receives
  it (per Constitution §5: unidirectional data flow validator → web).


