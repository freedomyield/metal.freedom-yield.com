# Operator identity key — setup runbook (Phase 5)

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

## Phase 5 to Phase 6 hand-off

Phase 5 leaves `chain_anchor.tx_id` as the all-zeros placeholder. To
move to Phase 6 at the next renewal cycle:

1. **Pre-flight byte-level snapshot of the published `.pub`.** The
   chain-memo hash is `shasum -a 256` of the `.pub` file bytes, so
   the operator side and the verifier side must agree on the exact
   byte sequence (trailing newline, comment, line endings). Before
   composing the memo, snapshot the file as the verifier will fetch
   it:
   ```sh
   curl -sS https://metal.freedom-yield.com/.well-known/operator-identity.pub \
     | tee /tmp/operator-identity.pub | wc -c
   xxd /tmp/operator-identity.pub | tail -1
   shasum -a 256 /tmp/operator-identity.pub
   ```
   Compare with the local file:
   ```sh
   wc -c ~/.ssh/freedom-yield-operator-identity.pub
   xxd ~/.ssh/freedom-yield-operator-identity.pub | tail -1
   shasum -a 256 ~/.ssh/freedom-yield-operator-identity.pub
   ```
   The byte counts, last-line `xxd` rows, and `shasum` values must
   all match between the live URL and the local file. If they differ,
   the web host has altered the bytes (CRLF rewrite, trailing-newline
   strip, etc.); fix the published file before continuing or the
   chain anchor will be unverifiable.
2. Compose the next-cycle `AddPermissionlessValidatorTx` in the
   Metal Wallet web UI as usual.
3. In the memo field, embed `identity-v1:sha256:<HEX64>`, where
   `<HEX64>` is the lowercase hex output of `shasum -a 256` against
   the published `.pub` file bytes (the value the verifier-side
   recipe at [`IDENTITY_VERIFICATION.md`](./IDENTITY_VERIFICATION.md)
   Step 3 will recompute and compare).

   **Important:** this is *not* the `SHA256:<base64>` value that
   `ssh-keygen -l -f` printed at Step 1. That value hashes the SSH
   wire-format key blob and lives in the manifest's
   `operator_identity_pubkey_fingerprint` field. The chain memo hashes
   the `.pub` file bytes themselves. Two distinct hashes commit to
   the same key via different byte sequences — that asymmetry is
   intentional and gives evaluators two cross-checkable bindings.
4. After the tx commits, re-run `gen-identity.sh` with the `tx_id`
   override:
   ```sh
   export OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity
   export CHAIN_ANCHOR_TX_ID=<the new tx_id, 64-hex>
   bash scripts/operator-local/gen-identity.sh
   ```
5. Commit + push the updated `identity.json` and `identity.json.sig`.
   The `chain_anchor` block now carries the real `tx_id` and the
   verifier can complete Step 1 of the seven-step recipe end-to-end.
