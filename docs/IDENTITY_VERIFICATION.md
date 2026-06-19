# Identity verification

This document describes how to verify the operator identity manifest published by Freedom Yield Metal.

> Companion runbook for the **operator side** (key generation, signing, publication, rollback) is in [`OPERATOR_IDENTITY_SETUP.md`](./OPERATOR_IDENTITY_SETUP.md). This document covers the **verifier side**.

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
- `/api/evidence.json` — machine-readable selection-evidence manifest, documented at `docs/EVIDENCE_MANIFEST.md`
- `/api/validator.json` — live validator state
- The validator registration record on the public explorer (`https://explorer.metalblockchain.org/`)
- The operator-controlled site at `https://metal.freedom-yield.com/`
- *(Future)* The `AddPermissionlessValidatorTx` memo at the next renewal cycle, embedding the SHA-256 fingerprint of the operator identity public key.

An evaluator should not treat any single artifact as conclusive. The whole set agreeing is the evidence.

## Machine-readable discovery

While preparation is in flight, an automated reviewer can discover this manifest entirely from `/api/evidence.json`. The `in_preparation_artifacts.identity_manifest` object lists, in one place: the planned `identity.json` URL, the signature URL, the operator public-key URL, the schema preview at `/api/identity.example.json`, and the link back to this document. The same object collapses out of `in_preparation_artifacts` and the runtime URLs go live in `public_pages` (or remain in a small `signed_artifacts` block, TBD) when activation completes.

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

## End-to-end verification recipe (4-layer Merkle DAG)

Once the operator identity key is live and the next-cycle AddValidator tx memo carries the fingerprint, an evaluator can verify the entire trust chain — on-chain anchor → signed identity manifest → Merkle DAG of artifacts → leaf bytes & schemas — in seven steps. This recipe works from a local cache: it does NOT require the Freedom Yield web infrastructure to be reachable at verification time.

### Step 1. Read the on-chain anchor

```sh
# Pull the most recent AddPermissionlessValidatorTx for the NodeID.
# The memo carries: identity-v1:sha256:<HEX64>
NODE_ID="NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"
TX_JSON=$(curl -sS "https://explorer.metalblockchain.org/api/validator/${NODE_ID}/latest-tx")
MEMO=$(printf '%s' "$TX_JSON" | jq -r '.memo')
echo "memo: ${MEMO}"
```

Reject if the memo does not match `identity-v1:sha256:[a-f0-9]{64}`.

### Step 2. Extract the expected pubkey fingerprint from memo

```sh
EXPECTED_FP="${MEMO#identity-v1:sha256:}"
echo "expected pubkey sha256: ${EXPECTED_FP}"
```

### Step 3. Confirm the live operator identity pubkey matches the chain anchor

```sh
curl -sS https://metal.freedom-yield.com/.well-known/operator-identity.pub > operator-identity.pub
LIVE_FP=$(shasum -a 256 operator-identity.pub | awk '{print $1}')
[ "${LIVE_FP}" = "${EXPECTED_FP}" ] && echo "ok: chain ↔ live pubkey match" || echo "FAIL: mismatch"
```

A mismatch means either the chain anchor or the live web has been tampered with; trust nothing further until resolved.

### Step 4. Verify the signed identity manifest

```sh
curl -sS https://metal.freedom-yield.com/api/identity.json     > identity.json
curl -sS https://metal.freedom-yield.com/api/identity.json.sig > identity.json.sig
echo "freedom-yield $(cat operator-identity.pub)" > allowed_signers
ssh-keygen -Y verify \
  -f allowed_signers \
  -I freedom-yield \
  -n freedom-yield/validator-identity \
  -s identity.json.sig < identity.json
```

Expected output: `Good "freedom-yield/validator-identity" signature ...`. Any other output is a fail.

### Step 5. Check each leaf artifact's sha256 against the manifest

```sh
jq -r '.artifact_manifest | to_entries[] | "\(.key) \(.value.url) \(.value.sha256)"' identity.json \
| while read name url want; do
    got=$(curl -sS "$url" | shasum -a 256 | awk '{print $1}')
    [ "$got" = "$want" ] && echo "ok   leaf ${name}" || echo "FAIL leaf ${name} (expected ${want}, got ${got})"
  done
```

Each leaf whose hash matches is proven tamper-free; the manifest signature in Step 4 already proved that the manifest itself (and therefore the expected hash) is operator-authorised.

### Step 6. Recompute the Merkle root and match `artifact_root`

```sh
# Collect leaf sha256 values in alphabetical key order, then build a binary tree.
# Odd counts duplicate the last leaf. Parent = SHA-256(left || right) over raw bytes.
python3 <<'PY'
import json, hashlib
with open("identity.json") as f: m = json.load(f)
items = sorted(m["artifact_manifest"].items())
leaves = [bytes.fromhex(v["sha256"]) for _, v in items]
while len(leaves) > 1:
    if len(leaves) % 2 == 1: leaves.append(leaves[-1])
    leaves = [hashlib.sha256(leaves[i] + leaves[i+1]).digest() for i in range(0, len(leaves), 2)]
root = leaves[0].hex() if leaves else ""
want = m["artifact_root"]
print(f"computed: {root}")
print(f"manifest: {want}")
print("ok" if root == want else "FAIL")
PY
```

### Step 7. Validate each leaf against its formal JSON Schema

```sh
# Using ajv-cli (Node.js) — works the same with Python jsonschema or any draft 2020-12 validator.
for slug in evidence validator identity cycle-history; do
  url_data=$(jq -r --arg s "${slug}_json"  '.artifact_manifest[$s].url // ""'  identity.json)
  url_data=${url_data:-$(jq -r --arg s "${slug}_jsonl" '.artifact_manifest[$s].url // ""' identity.json)}
  url_schema=$(jq -r --arg s "${slug}_json"  '.artifact_manifest[$s].schema_url // ""'  identity.json)
  url_schema=${url_schema:-$(jq -r --arg s "${slug}_jsonl" '.artifact_manifest[$s].schema_url // ""' identity.json)}
  [ -z "$url_schema" ] && continue   # leaves without a schema_url are out of scope here
  curl -sS "$url_data"   > "${slug}.json"
  curl -sS "$url_schema" > "${slug}.schema.json"
  npx --quiet --yes ajv-cli@latest validate --spec=draft2020 --strict=false \
    -c=ajv-formats -s "${slug}.schema.json" -d "${slug}.json" \
  && echo "ok   ${slug} matches contract"
done
```

### What the seven steps prove together

The chain memo binds the operator identity pubkey to the validator NodeID on Metal Blockchain (immutable). The signed manifest in Step 4 binds that same pubkey to claims about every leaf artifact (cryptographic). The Merkle root in Step 6 binds every leaf's content hash into the manifest signature (any change to any leaf flips the root). The schema check in Step 7 confirms each leaf still conforms to the published contract (no silent shape drift). Combined: a full chain of evidence from on-chain root down to leaf bytes, verifiable from a local cache without our infrastructure.

If `chain_anchor` is not yet populated (the next-cycle memo embed has not happened yet), Steps 1–3 are skipped and the trust ceiling drops to "signed by whoever holds the operator identity private key" — still resilient to website tampering, just not yet chain-anchored.

### Same pattern, different chain

This is the off-chain equivalent of the SC + ABI immutable pair: the JSON Schema is the ABI (immutable contract once published at a versioned URL), the runtime JSON is the typed instance, the Merkle root is the bundle integrity, and the chain memo is the SC-address-style anchor. An evaluator who has verified similar setups on EVM, Antelope, or Avalanche subnets can apply the same mental model unchanged.
