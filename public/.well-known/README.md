# `/.well-known/` directory

This directory is reserved for well-known resources served at `https://metal.freedom-yield.com/.well-known/`.

## Resources

- `operator-identity.pub` — the OpenSSH-format ed25519 public key used to verify `/api/identity.json` via `ssh-keygen -Y verify` with namespace `freedom-yield/validator-identity` and principal `freedom-yield`.
- `operator-identity-mldsa87.pub` — the PEM-format ML-DSA-87 (FIPS 204) public key used to verify `/api/identity.json` against `/api/identity.json.mldsa87.sig` via `openssl pkeyutl -verify` (OpenSSL 3.5 or later) with context string `freedom-yield/validator-identity`.

## Current status

`operator-identity.pub` has been published since the Phase 5 identity manifest (2026-06-22). `operator-identity-mldsa87.pub` is published together with the first `identity.json` signed with ML-DSA-87 (2026-10-16 onward; it replaces the ML-DSA-65 key used for the 2026-10-15 manifest, which is no longer published); until that manifest is issued it is absent, and an absent file is deliberate — an empty key file would appear broken to a verifier and is worse than its absence.

## Out of scope (will never be served from here)

The following keys are **never** placed under `/.well-known/`:

- Validator BLS signing keys
- Validator staking keys (`staker.key`, `staker.crt`)
- `metalgo` signer.key / staker.key
- Any private key material of any kind

The operator identity key is a dedicated key, generated for the sole purpose of signing the public identity manifest. It has no relationship to the validator's on-chain signing keys.

See `docs/IDENTITY_VERIFICATION.md` for the verification procedure.
