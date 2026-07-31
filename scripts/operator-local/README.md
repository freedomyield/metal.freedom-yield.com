# scripts/operator-local/

**This directory is excluded from `scripts/sync-to-validator-host.sh`.**

Anything inside `operator-local/` MUST NOT be deployed to the validator host
or the web host. Scripts here run on the operator's local Mac only.

These helpers may handle the operator identity key, an ed25519 keypair
independent of the validator's `staker.key` and BLS `signer.key`. The
private key MUST live only on the operator's local Mac and in the
operator's password manager backup. It MUST NEVER be copied to the
validator host, the web host, the repository, CI, or any cloud storage
outside the password manager.

The validator's `staker.key`, BLS `signer.key`, and any other `metalgo`
signing material are out of scope for everything in this directory.
These helpers MUST NEVER read, copy, or invoke `metalgo` signing keys.

## Sync exclusion

`scripts/sync-to-validator-host.sh` carries an `--exclude='operator-local/'`
rule. Before relying on it, confirm with a dry-run:

```sh
VALIDATOR_HOST=<host> ./scripts/sync-to-validator-host.sh --dry-run \
  | grep -i operator-local && echo "LEAK" || echo "OK"
```

A clean run prints `OK` and nothing else.

## Contents

- `gen-identity.sh` — composes and signs `public/api/identity.json` with
  the operator's local ed25519 key. Probes each leaf artifact URL,
  computes its content sha256, and binds the set under
  `artifact_manifest` + `artifact_root` (SHA-256 Merkle root, alphabetical
  key order, odd-duplicate, raw bytes). Never reads validator keys.
  Refuses to run on production hosts. See
  `docs/IDENTITY_VERIFICATION.md` for the signing model and the seven-
  step end-to-end verification procedure.

- `test-gen-identity.sh` — synthetic-key test harness for Phase 3
  Merkle DAG logic. Generates a throwaway ed25519 key in a tmp dir,
  runs `gen-identity.sh` against a fake `REPO_ROOT`, re-fetches every
  leaf and recomputes the Merkle root independently, then verifies
  the signature against the synthetic pubkey. Output never lands in
  the real repo.

- `commit-anchor-source.sh` — the host→git transfer path for
  `public/api/anchor-source.json` (plan A4). Fetches the validator
  host's current checkout of that file over SSH (or `--input-file` for
  manual/offline use), validates it (jq parse, schema, `--expect-cycle=N`
  match, non-null `identity_branch.prev_anchor_root`/`prev_anchor_tx`
  unless `--allow-genesis`), shows a diff summary against the repo copy,
  then `git add` + a single-purpose commit naming the cycle number and
  the `dag_root_computed` prefix. Never pushes unless `--push` is given.
  Same host-refusal guard as `gen-identity.sh`. Companion protection:
  `scripts/advance-host-checkout.sh` preserves host-composed
  anchor-source.json dirt from its own public/ discard while it waits
  for this script to run — see `docs/DEPLOY_OWNERSHIP_MATRIX.md`.

- `test-commit-anchor-source.sh` — hermetic test harness for
  `commit-anchor-source.sh`. Builds a throwaway git repo, feeds fixture
  JSON via `--input-file` / `FYD_ANCHOR_FETCH_STUB` — no real SSH
  connection is ever made — and asserts exit codes, commit presence/
  absence, and committed content across the validation, genesis-guard,
  idempotency, and push-failure paths.

## Phase 5 runbook

The end-to-end procedure for generating the real operator identity
key, signing the live `identity.json`, and publishing the three Phase 5
surfaces is in [`docs/OPERATOR_IDENTITY_SETUP.md`](../../docs/OPERATOR_IDENTITY_SETUP.md).
That runbook is the teaching reference: read it once for context.

At execution time, run from the compact one-page checklists instead:
[`docs/PHASE5_CHECKLIST.md`](../../docs/PHASE5_CHECKLIST.md) for the
signed-manifest publish. It carries the section-keyed gate checks,
command-by-command copy-paste blocks, live verification, rollback, and
symptom-keyed failure decision trees.
