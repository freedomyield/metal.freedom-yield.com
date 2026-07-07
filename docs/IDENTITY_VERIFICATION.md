# Identity verification

This document describes how a third-party evaluator verifies the operator identity manifest published by Freedom Yield Metal, end-to-end, from the signed manifest through the on-chain anchor.

> Companion runbook for the **operator side** (key generation, signing, publication, rollback) is in [`OPERATOR_IDENTITY_SETUP.md`](./OPERATOR_IDENTITY_SETUP.md). Byte-level construction rules for the DAG are in [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md). This document covers the **verifier side**.

## Key model (read first)

The identity manifest is signed with a **dedicated ed25519 operator identity key**. Specifically:

- The signing key is **not** the validator's BLS signing key.
- The signing key is **not** a staking key (`staker.key`).
- The signing key is **not** any private key used by the `metalgo` process.
- The operator identity key is generated, held, and rotated on the operator's local Mac — not on the validator host or the web host. CI never receives the private key.

A separate `<xpr-account>@anchor` key (XPRNetwork K1 / EOSIO format) lives on the operator's signing machine and signs A-chain inscriptions only. It is scoped via `linkauth` to inscribe-class actions, so a compromise of the anchor key cannot move tokens, change permissions, or deploy contracts. The signing key and the anchor key are independent; the chain of trust binds them through `identity.json`'s `operator_identity_pubkey_fingerprint` (signed by the operator identity key) and the on-chain anchor action's signer permission (`<xpr-account>@anchor`).

This separation is intentional. Each key has one job; reuse for off-chain manifest signing or for unrelated on-chain actions is excluded by design.

## NodeID binding

A single signature does not by itself prove control of the validator. NodeID binding is established by the **collective evidence** across:

- `/api/identity.json` — signed identity manifest (this document's subject)
- `/api/identity.json.sig` — detached ed25519 signature
- `/.well-known/operator-identity.pub` — current operator identity public key (its SHA-256 is committed inside the DAG's identity branch)
- `/api/anchor-source.json` — the DAG source: the three branch objects (identity / observations / artifacts) and the combined `dag_root_computed`
- `/api/anchor-receipt.json` — Metal A-chain (PulseVM / XPRNetwork) inscription receipt anchoring `dag_root_computed`
- `/api/anchor-history.jsonl` — append-only log of every broadcast anchor (cycle → tx_id → dag)
- `/api/evidence.json` — machine-readable selection-evidence manifest, documented at `docs/EVIDENCE_MANIFEST.md`
- `/api/validator.json` — live validator state
- The validator registration record on the public Metal explorer (`https://explorer.metalblockchain.org/`)
- A public XPRNetwork explorer entry for the inscribing transaction (e.g. `https://explorer.xprnetwork.org/transaction/<tx_id>`)
- The operator-controlled site at `https://metal.freedom-yield.com/`

An evaluator should not treat any single artifact as conclusive. The whole set agreeing — and the on-chain inscription matching the off-chain DAG root — is the evidence.

## Machine-readable discovery

An automated reviewer can discover the manifest set from `/api/evidence.json`. The `live_artifacts.identity_manifest` object lists the manifest URLs (`url`, `signature_url`, `pubkey_url`, `schema_url`, …); the anchor artifacts (`anchor-source.json`, `anchor-receipt.json`, `anchor-history.jsonl`) carry the on-chain binding.

## Verification procedure (seven steps)

Requires **OpenSSH 8.0+** (the `-Y` subcommand was added in OpenSSH 8.0), `curl`, `jq`, and `sha256sum` or `shasum -a 256`. macOS 11+, modern Linux distros, and Windows OpenSSH 8.0+ are all supported.

The byte-level construction rules cited below are specified once in [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md). This document is the recipe; the spec is the authority. If the two disagree, the spec is the source of truth and this document is a bug.

### Step 1 — Fetch the artifact set

```sh
BASE=https://metal.freedom-yield.com
curl -sSLfO ${BASE}/api/identity.json
curl -sSLfO ${BASE}/api/identity.json.sig
curl -sSLfO ${BASE}/.well-known/operator-identity.pub
curl -sSLfO ${BASE}/api/anchor-source.json
curl -sSLfO ${BASE}/api/anchor-receipt.json
```

A 404 on any of the five URLs is a verification failure: the set must be complete for the chain of evidence to hold.

### Step 2 — Verify the operator's signature on identity.json

```sh
echo "freedom-yield $(cat operator-identity.pub)" > allowed_signers
ssh-keygen -Y verify \
  -f allowed_signers \
  -I freedom-yield \
  -n freedom-yield/validator-identity \
  -s identity.json.sig < identity.json
```

A successful verification prints `Good "freedom-yield/validator-identity" signature for freedom-yield with ED25519 key SHA256:…` and exits 0. The four required parameters are pinned:

| Parameter | Value | Source |
|---|---|---|
| `-I` (principal) | `freedom-yield` | manifest `verification.principal` |
| `-n` (namespace) | `freedom-yield/validator-identity` | manifest `verification.namespace` |
| `-f` (signers file) | `allowed_signers` (built locally) | composed from `operator-identity.pub` |
| `-s` (signature) | `identity.json.sig` | served at `/api/identity.json.sig` |

A signature failure at this step ends verification; nothing downstream is trustworthy without it.

### Step 3 — Fingerprint cross-check

```sh
ssh-keygen -l -f operator-identity.pub
# 256 SHA256:Abc123… freedom-yield-operator-identity (ED25519)
#         ^^^^^^^^^^^^
#         must equal identity.json.operator_identity_pubkey_fingerprint
```

Redundant with step 2 (the signature already proves the key controls the manifest) but catches accidental key-file substitution by intermediate caches. The same public key's raw-bytes SHA-256 is also committed inside the DAG at `anchor-source.json .identity_branch.operator_ed25519_pubkey_sha256_hex` (reproduce with `cat operator-identity.pub | awk '{print $2}' | base64 -d | tail -c 32 | sha256sum`).

### Step 4 — Recompute the three branch roots

Each branch root is the SHA-256 of the branch object's canonical bytes (`jq -cS` = compact + sorted keys), per [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md) §3. There is no per-branch Merkle tree — that was the retired 2-branch model.

```sh
ID_ROOT=$(jq -cS '.identity_branch'     anchor-source.json | sha256sum | awk '{print $1}')
OB_ROOT=$(jq -cS '.observations_branch' anchor-source.json | sha256sum | awk '{print $1}')
AR_ROOT=$(jq -cS '.artifacts_branch'    anchor-source.json | sha256sum | awk '{print $1}')
printf 'id=%s\nob=%s\nar=%s\n' "$ID_ROOT" "$OB_ROOT" "$AR_ROOT"
```

These three values are what the on-chain branch memos commit to (step 7). The `jq -cS … | sha256sum` pipeline above hashes the `jq -cS` output **including the trailing newline (`0x0a`) that `jq` appends by default** — the authoritative branch root is `sha256(canonical + "\n")`. A verifier that uses a non-jq JCS serializer MUST match jq's compact + sorted-key encoding **and** append one `0x0a` byte if its serializer omits the trailing newline; otherwise the digest will not match the on-chain memo hex. See [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md) §2.1.

### Step 5 — Recompute dag_root_computed

The DAG root is SHA-256 of the three branch roots concatenated **as their 64-char lowercase-hex ASCII strings** (not raw digest bytes), per [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md) §4.

```sh
DAG=$(printf '%s%s%s' "$ID_ROOT" "$OB_ROOT" "$AR_ROOT" | sha256sum | awk '{print $1}')
echo "$DAG"
```

### Step 6 — DAG-root equality across source and receipt

Assert both of:

```sh
jq -r .dag_root_computed anchor-source.json
jq -r .dag_root_hash     anchor-receipt.json
```

equal the `DAG` computed in step 5. Any disagreement breaks the chain: the operator has either published an inconsistent `anchor-source.json` or the receipt is stale relative to the source.

### Step 7 — On-chain anchor cross-check (four memos)

The anchor is **four** `eosio.token::transfer` actions, one memo each. Compose the expected memos from the source's schema + cycle:

```sh
S=$(jq -r .schema_version                             anchor-source.json)
N=$(jq -r .observations_branch.cycle_number_observed  anchor-source.json)
printf 'action1  %s\naction2  %s\naction3  %s\naction4  %s\n' \
  "fya${S}c${N}-id:${ID_ROOT}" \
  "fya${S}c${N}-ob:${OB_ROOT}" \
  "fya${S}c${N}-ar:${AR_ROOT}" \
  "fya${S}c${N}:${DAG}"
```

Look up the transaction on a public XPRNetwork explorer and assert:

| Field | Expected |
|---|---|
| tx_id | `anchor-receipt.json .tx_id` (or `.anchor.tx_id`) |
| four action memos | exactly the four strings above (branch roots `-id`/`-ob`/`-ar` + the DAG root), in the four `eosio.token::transfer` actions |
| signer permission | `<xpr-account>@anchor` on each action |
| `from` | `<xpr-account>` (config `xpr-account`) |
| `to` | NOT equal to `from`; the dedicated sink (config `anchor-sink`) |
| block height / timestamp | matches the receipt fields |

The `from != to` invariant is forced by the XPRNetwork `eosio.token` contract (`eosio.token.cpp` L99 `check(from != to, "cannot transfer to self")`) and is observable on every receipt. The signer permission binds the actions to `<xpr-account>@anchor`; if signed by `@active` or `@owner` instead, the receipt is not honoring the narrow-permission discipline the operator declared, and the evaluator SHOULD flag it.

Publishing the three branch roots on-chain alongside the DAG root lets an evaluator confirm each branch independently and recompute the DAG root (step 5) from chain data alone.

## Rotation and revocation

If the operator identity key is rotated, the new `identity.json` reflects the new `operator_identity_pubkey_fingerprint` and a new `key_iat`; a new line appends to `identity-history.jsonl` (the source of `identity_branch.identity_history_root`) with the next `key_seq`; the prior key's line is updated with `superseded_by_key_seq` populated (and `revoked` / `revoked_at` / `revocation_reason` set if the rotation is for cause). The identity branch root changes, hence `dag_root_computed` changes, and the next cycle's anchor commits the new root.

The recommended rotation cadence is 12 months, aligned to a validation-cycle boundary. `ssh-keygen -Y verify` does **not** check `key_iat` / `key_exp`; consumers MAY enforce them as policy.

The validator's on-chain signing keys (staker / BLS) are unaffected by operator identity key rotation; they have no relationship to this manifest. The `<xpr-account>@anchor` key is independent and rotates on its own schedule.

## Why a DAG anchor rather than just a signed manifest

A signed manifest alone proves only that the operator wrote the manifest at the moment of signing. It does not prove the manifest existed at any specific earlier time, and a malicious operator could silently re-sign a different history later. The DAG anchor adds an **independent existence-time proof**: once `dag_root_computed` is committed to Metal A-chain at a block with a known timestamp, the operator cannot later modify any branch source without producing a different DAG root that contradicts the on-chain memos.

The anchor does not prevent the operator from publishing a new, contradicting DAG later; it commits the operator to a specific state at a specific time, and lets evaluators detect contradictions trivially (the prior on-chain memos still point at a different root).

## Why not BLS / staking key for the off-chain signature?

1. **Separation of concerns.** The validator's signing keys exist to sign consensus messages. Reusing them for off-chain manifest signing widens their attack surface for no on-chain benefit.
2. **Operational safety.** Reading validator key material to produce an external signature is operationally risky. The operator identity key is intentionally kept off the validator host, the web host, and CI.
3. **Toolchain.** BLS12-381 is not directly supported by common verification tooling. `ssh-keygen -Y verify` with ed25519 is universally available and produces a one-line, copy-pasteable verification.

## Scope limits

This identity manifest and DAG anchor are a verifiable binding from a stable public key to an operator brand and a NodeID, plus a cumulative on-chain commitment to the identity-key history, the cycle observations, and the published artifact set. They are not:

- a compliance attestation
- a regulatory disclosure
- a KYC document
- a guarantee of any future operational behavior

For honest disclosure of known limitations, see `/risk-disclosure/`. For unilateral commitments, see `/commitments/`.

## See also

- [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md) — canonical byte-level construction rules referenced by this recipe.
- [`OPERATOR_IDENTITY_SETUP.md`](./OPERATOR_IDENTITY_SETUP.md) — operator-side runbook for the off-chain signing key.
- [`IDENTITY_SCHEMA_CHANGELOG.md`](./IDENTITY_SCHEMA_CHANGELOG.md) — design history, including the retirement of the 2-branch `fyid1:` model.
