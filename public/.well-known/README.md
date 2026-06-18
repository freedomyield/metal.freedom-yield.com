# `/.well-known/` directory

This directory is reserved for well-known resources served at `https://metal.freedom-yield.com/.well-known/`.

## Planned resources

- `operator-identity.pub` — the OpenSSH-format ed25519 public key used to verify `/api/identity.json` via `ssh-keygen -Y verify` with namespace `validator-identity`.

## Current status

The operator identity public key is **not yet published**. It will be added after the operator generates a dedicated ed25519 identity key on a local workstation.

No empty `operator-identity.pub` is placed here on purpose — an empty key file would appear broken to a verifier and is worse than its absence.

## Out of scope (will never be served from here)

The following keys are **never** placed under `/.well-known/`:

- Validator BLS signing keys
- Validator staking keys (`staker.key`, `staker.crt`)
- `metalgo` signer.key / staker.key
- Any private key material of any kind

The operator identity key is a dedicated key, generated for the sole purpose of signing the public identity manifest. It has no relationship to the validator's on-chain signing keys.

See `docs/IDENTITY_VERIFICATION.md` for the verification procedure.
