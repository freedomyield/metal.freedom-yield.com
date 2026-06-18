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
  the operator's local ed25519 key. Never reads validator keys. Refuses
  to run on production hosts. See `docs/IDENTITY_VERIFICATION.md` for the
  signing model and verification procedure.
