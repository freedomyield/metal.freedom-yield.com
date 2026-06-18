# Identity verification

This document describes how to verify the operator identity manifest published by Freedom Yield Metal.

## Key model (read first)

The identity manifest is signed with a **dedicated ed25519 operator identity key**. Specifically:

- The signing key is **not** the validator's BLS signing key.
- The signing key is **not** a staking key (`staker.key`).
- The signing key is **not** any private key used by the `metalgo` process.
- The operator identity key is generated, held, and rotated on the operator's local Mac — not on the validator host or the web host. CI never receives the private key.

This separation is intentional. The operator identity key is a thin, dedicated key whose only purpose is to bind a public manifest to a stable operator identity. The validator's signing keys are never used for off-chain manifest signing.

## NodeID binding

A single signature does not by itself prove control of the validator. NodeID binding is established by the **collective evidence** across:

- `/api/identity.json` — signed identity manifest (this document's subject)
- `/api/evidence.json` — machine-readable selection-evidence manifest
- `/api/validator.json` — live validator state
- The validator registration record on the public explorer (`https://explorer.metalblockchain.org/`)
- The operator-controlled site at `https://metal.freedom-yield.com/`
- *(Future)* The `AddPermissionlessValidatorTx` memo at the next renewal cycle, embedding the SHA-256 fingerprint of the operator identity public key.

An evaluator should not treat any single artifact as conclusive. The whole set agreeing is the evidence.

## Verification procedure

Requires **OpenSSH 8.0+** (the `-Y` subcommand was added in OpenSSH 8.0, 2019-04). macOS 11+, modern Linux distros, and Windows OpenSSH 8.0+ are all supported. WSL or Git Bash works on older Windows.

Once `/api/identity.json` and `/api/identity.json.sig` are live, verification is:

```sh
curl -sSO https://metal.freedom-yield.com/api/identity.json
curl -sSO https://metal.freedom-yield.com/api/identity.json.sig
curl -sSO https://metal.freedom-yield.com/.well-known/operator-identity.pub

echo "freedom-yield $(cat operator-identity.pub)" > allowed_signers
ssh-keygen -Y verify \
  -f allowed_signers \
  -I freedom-yield \
  -n freedom-yield/validator-identity \
  -s identity.json.sig < identity.json
```

A successful verification prints `Good "freedom-yield/validator-identity" signature for freedom-yield with ED25519 key SHA256:…` and exits with status 0.

The four required parameters of `ssh-keygen -Y verify` are pinned:

| Parameter | Value | Source |
|---|---|---|
| `-I` (principal) | `freedom-yield` | `allowed_signers` line; matches manifest `verification.principal` |
| `-n` (namespace) | `freedom-yield/validator-identity` | manifest `verification.namespace` field |
| `-f` (signers file) | `allowed_signers` (built locally) | composed from `operator-identity.pub` |
| `-s` (signature) | `identity.json.sig` | served at `https://metal.freedom-yield.com/api/identity.json.sig` |

## Fingerprint cross-check

The manifest's `operator_identity_pubkey_fingerprint` field uses the OpenSSH standard `SHA256:<base64>` form. A verifier can cross-check:

```sh
ssh-keygen -l -f operator-identity.pub
# 256 SHA256:Abc123…  freedom-yield-operator-identity (ED25519)
#         ^^^^^^^^^^^^
#         must equal operator_identity_pubkey_fingerprint in identity.json
```

This is redundant with the signature check (the signature already proves the key controls the manifest) but it catches accidental key-file substitution by intermediate caches.

## Rotation and revocation

If the operator identity key is rotated, the new manifest reflects the new `operator_identity_pubkey_fingerprint` and a new `key_iat`. The recommended cadence is 12 months, aligned to a renewal-cycle boundary.

If the previous key is to be marked revoked, an interim manifest may be published with `"revoked": true`, `"revoked_at"` set, and `"revocation_reason"` populated, signed by the new key.

The validator's on-chain signing keys are unaffected by operator identity key rotation; they have no relationship to this manifest.

Note: `ssh-keygen -Y verify` does **not** check `key_iat` / `key_exp`. These fields are operator-declared lifetime metadata; consumers may enforce them as policy.

## Why not BLS / staking key?

Three reasons:

1. **Separation of concerns.** The validator's signing keys exist to sign consensus messages. Reusing them for off-chain manifest signing widens their attack surface for no on-chain benefit.
2. **Operational safety.** Reading validator key material on a server-side process to produce an external signature is operationally risky. The operator identity key is intentionally kept off the validator host, the web host, and CI.
3. **Toolchain.** BLS12-381 (used by Metal validator signing keys) is not directly supported by common verification tooling on an evaluator's workstation. `ssh-keygen -Y verify` with ed25519 is universally available and produces a one-line, copy-pasteable verification.

## Scope limits

This identity manifest is a verifiable mapping from a stable public key to an operator brand and a NodeID. It is not:

- a compliance attestation
- a regulatory disclosure
- a KYC document
- a guarantee of any future operational behavior

For honest disclosure of known limitations, see `/risk-disclosure/`. For unilateral commitments, see `/commitments/`.
