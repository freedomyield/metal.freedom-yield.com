# Identity verification

This document describes how to verify the operator identity manifest published by Freedom Yield Metal.

## Key model (read first)

The identity manifest is signed with a **dedicated ed25519 operator identity key**. Specifically:

- The signing key is **not** the validator's BLS signing key.
- The signing key is **not** a staking key (`staker.key`).
- The signing key is **not** any private key used by the `metalgo` process.
- The operator identity key is generated, held, and rotated on an operator-controlled workstation — not on the validator host or the web host.

This separation is intentional. The operator identity key is a thin, dedicated key whose only purpose is to bind a public manifest to a stable operator identity. The validator's signing keys are never used for off-chain manifest signing.

## NodeID binding

A single signature does not by itself prove control of the validator. NodeID binding is established by the **collective evidence** across:

- `/api/identity.json` — signed identity manifest (this document's subject)
- `/api/evidence.json` — machine-readable selection-evidence manifest
- `/api/validator.json` — live validator state
- The validator registration record on the public explorer
- The operator-controlled site at `https://metal.freedom-yield.com/`

An evaluator should not treat any single artifact as conclusive. The whole set agreeing is the evidence.

## Verification procedure

Once `/api/identity.json` and `/api/identity.json.sig` are live, verification is:

```sh
curl -sSO https://metal.freedom-yield.com/api/identity.json
curl -sSO https://metal.freedom-yield.com/api/identity.json.sig
curl -sSO https://metal.freedom-yield.com/.well-known/operator-identity.pub
echo "freedom-yield $(cat operator-identity.pub)" > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I freedom-yield -n validator-identity -s identity.json.sig < identity.json
```

A successful verification prints `Good "freedom-yield" signature ...` and exits with status 0.

The four required parameters of `ssh-keygen -Y verify` are pinned:

| Parameter | Value | Source |
|---|---|---|
| `-I` (principal) | `freedom-yield` | `allowed_signers` line |
| `-n` (namespace) | `validator-identity` | manifest `verification.namespace` field |
| `-f` (signers file) | `allowed_signers` (built locally) | composed from `operator-identity.pub` |
| `-s` (signature) | `identity.json.sig` | served at `https://metal.freedom-yield.com/api/identity.json.sig` |

## Fingerprint cross-check

The manifest's `operator_identity_pubkey_fingerprint_sha256` field is the SHA-256 of the raw bytes of `operator-identity.pub`. A verifier can cross-check:

```sh
shasum -a 256 operator-identity.pub
# Expected to match the operator_identity_pubkey_fingerprint_sha256 field in identity.json.
```

This is redundant with the signature check (the signature already proves the key controls the manifest) but it catches accidental key-file substitution by intermediate caches.

## Rotation and revocation

If the operator identity key is rotated, the new manifest must reflect the new `operator_identity_pubkey_fingerprint_sha256` and a new `key_iat`. If the previous key is to be marked revoked, an interim manifest may be published with `"revoked": true` for the old key's fingerprint, signed by the new key.

The validator's on-chain signing keys are unaffected by operator identity key rotation; they have no relationship to this manifest.

## Why not BLS / staking key?

Three reasons:

1. **Separation of concerns.** The validator's signing keys exist to sign consensus messages. Reusing them for off-chain manifest signing widens their attack surface for no on-chain benefit.
2. **Operational safety.** Reading validator key material on a server-side process to produce an external signature is operationally risky; the operator identity key is intentionally kept off the validator and web hosts.
3. **Toolchain.** BLS12-381 (used by Metal validator signing keys) is not directly supported by common verification tooling on an evaluator's workstation. `ssh-keygen -Y verify` with ed25519 is universally available and produces a one-line, copy-pasteable verification.

## Scope limits

This identity manifest is a verifiable mapping from a stable public key to an operator brand and a NodeID. It is not:

- a compliance attestation
- a regulatory disclosure
- a KYC document
- a guarantee of any future operational behavior

For honest disclosure of known limitations, see `/risk-disclosure/`. For unilateral commitments, see `/commitments/`.
