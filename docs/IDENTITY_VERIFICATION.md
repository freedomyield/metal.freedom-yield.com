# Identity verification

This document describes how a third-party evaluator verifies the operator identity manifest published by Freedom Yield Metal, end-to-end, from the signed manifest through the on-chain anchor.

> Companion runbook for the **operator side** (key generation, signing, publication, rollback) is in [`OPERATOR_IDENTITY_SETUP.md`](./OPERATOR_IDENTITY_SETUP.md). Byte-level construction rules for the Merkle DAG are in [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md). This document covers the **verifier side**.

## Key model (read first)

The identity manifest is signed with a **dedicated ed25519 operator identity key**. Specifically:

- The signing key is **not** the validator's BLS signing key.
- The signing key is **not** a staking key (`staker.key`).
- The signing key is **not** any private key used by the `metalgo` process.
- The operator identity key is generated, held, and rotated on the operator's local Mac — not on the validator host or the web host. CI never receives the private key.

A separate `metalfreedom@anchor` key (XPRNetwork K1 / EOSIO format) lives on the validator host and signs A-chain inscriptions only. It is scoped via `linkauth` to inscribe-class actions, so a compromise of the anchor key cannot move tokens, change permissions, or deploy contracts. The signing key and the anchor key are independent; the chain of trust binds them through `identity.json`'s `operator_identity_pubkey_fingerprint` (signed by the operator identity key) and `anchor-receipt.json`'s `anchor.inscribe_action.permission.actor` (= `metalfreedom`, with the `anchor` permission).

This separation is intentional. Each key has one job; reuse for off-chain manifest signing or for unrelated on-chain actions is excluded by design.

## NodeID binding

A single signature does not by itself prove control of the validator. NodeID binding is established by the **collective evidence** across:

- `/api/identity.json` — signed identity manifest (this document's subject)
- `/api/identity.json.sig` — detached ed25519 signature
- `/.well-known/operator-identity.pub` — current operator identity public key
- `/api/identity-history.jsonl` — per-key-rotation leaf source for the identity branch of the Merkle DAG
- `/api/cycle-history.jsonl` — per-validation-cycle leaf source for the cycles branch of the Merkle DAG
- `/api/cycles-history.json` — Merkle DAG snapshot publishing both branch roots and the combined `dag_root_hash`
- `/api/anchor-receipt.json` — Metal A-chain (PulseVM / XPRNetwork) inscription receipt anchoring `dag_root_hash`
- `/api/evidence.json` — machine-readable selection-evidence manifest, documented at `docs/EVIDENCE_MANIFEST.md`
- `/api/validator.json` — live validator state
- The validator registration record on the public Metal explorer (`https://explorer.metalblockchain.org/`)
- A public XPRNetwork explorer entry for the inscribing transaction (e.g. `https://explorer.xprnetwork.org/transaction/<tx_id>`)
- The operator-controlled site at `https://metal.freedom-yield.com/`

An evaluator should not treat any single artifact as conclusive. The whole set agreeing — and the on-chain inscription matching the off-chain DAG root — is the evidence.

## Machine-readable discovery

While preparation is in flight, an automated reviewer can discover the manifest set entirely from `/api/evidence.json`. The `in_preparation_artifacts.identity_manifest` object lists the planned URLs in one place. Once Phase α activates, the runtime URLs go live in `public_pages` (or in a small `signed_artifacts` block) and `in_preparation_artifacts` collapses out.

## Verification procedure (nine steps)

Requires **OpenSSH 8.0+** (the `-Y` subcommand was added in OpenSSH 8.0, 2019-04), `curl`, `sha256sum` or `shasum -a 256`, and `xxd` (or any tool that converts hex to raw bytes). macOS 11+, modern Linux distros, and Windows OpenSSH 8.0+ are all supported.

The byte-level construction rules cited below are specified once in [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md). This document is the recipe; the spec is the authority. If the two disagree, the spec is the source of truth and this document is a bug.

### Step 1 — Fetch the artifact set

```sh
BASE=https://metal.freedom-yield.com
curl -sSLfO ${BASE}/api/identity.json
curl -sSLfO ${BASE}/api/identity.json.sig
curl -sSLfO ${BASE}/.well-known/operator-identity.pub
curl -sSLfO ${BASE}/api/identity-history.jsonl
curl -sSLfO ${BASE}/api/cycle-history.jsonl
curl -sSLfO ${BASE}/api/cycles-history.json
curl -sSLfO ${BASE}/api/anchor-receipt.json
```

A 404 on any of the seven URLs is a verification failure: the set must be complete for the chain of evidence to hold.

### Step 2 — Verify the operator's signature on identity.json

```sh
echo "freedom-yield $(cat operator-identity.pub)" > allowed_signers
ssh-keygen -Y verify \
  -f allowed_signers \
  -I freedom-yield \
  -n freedom-yield/validator-identity \
  -s identity.json.sig < identity.json
```

A successful verification prints `Good "freedom-yield/validator-identity" signature for freedom-yield with ED25519 key SHA256:…` and exits with status 0. The four required parameters are pinned:

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

Redundant with step 2 (the signature already proves the key controls the manifest) but catches accidental key-file substitution by intermediate caches.

### Step 4 — Compute the identity branch root

```sh
# Per-line SHA-256 of identity-history.jsonl, in file order (= key_seq ascending).
while IFS= read -r line; do
  printf '%s\n' "$line" | sha256sum | awk '{print $1}'
done < identity-history.jsonl > identity-leaves.txt
```

Then build the Merkle root over `identity-leaves.txt` following the construction in [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md) §3: at each level, duplicate the last leaf if the count is odd; pair adjacent leaves; `parent = SHA-256( raw_bytes(left) || raw_bytes(right) )` where the inputs are 32-byte raw digests (not the 64-char hex strings); the single remaining hex digest is `identity_branch_root`.

The shell construction is implemented portably in `scripts/operator-local/gen-identity.sh::compute_merkle_root` and a Python equivalent is in `truthmark.io/scrapers/xpr/merkle.py::compute_merkle_root_from_hashes`. A verifier MAY reuse either.

Assert: the computed value equals `cycles-history.json.branches.identity.branch_root`.

### Step 5 — Compute the cycles branch root

Same procedure as step 4, applied to `cycle-history.jsonl`:

```sh
while IFS= read -r line; do
  printf '%s\n' "$line" | sha256sum | awk '{print $1}'
done < cycle-history.jsonl > cycles-leaves.txt
```

Then build the Merkle root over `cycles-leaves.txt` per the same rules.

Assert: the computed value equals `cycles-history.json.branches.cycles.branch_root`.

### Step 6 — Combine into dag_root_hash

```sh
IB_ROOT=$(jq -r '.branches.identity.branch_root' cycles-history.json)
CY_ROOT=$(jq -r '.branches.cycles.branch_root' cycles-history.json)
DAG_ROOT=$( { printf '%s' "$IB_ROOT" | xxd -r -p
              printf '%s' "$CY_ROOT" | xxd -r -p
            } | sha256sum | awk '{print $1}' )
echo "$DAG_ROOT"
```

This is `SHA-256( raw_bytes(identity_branch_root) || raw_bytes(cycles_branch_root) )` per [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md) §4.

Empty-branch convention: if either branch has zero leaves, its root is the sentinel `SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (spec §5).

### Step 7 — DAG-root equality across the three documents

Assert all three of:

```sh
jq -r .dag_root_hash identity.json
jq -r .dag_root_hash cycles-history.json
jq -r .dag_root_hash anchor-receipt.json
```

equal the `DAG_ROOT` computed in step 6. Any disagreement breaks the chain; the operator has either published an inconsistent set or the anchor receipt is stale relative to the manifest.

### Step 8 — On-chain anchor cross-check

Read the inscription on a public XPRNetwork explorer:

```sh
TX_ID=$(jq -r .anchor.tx_id anchor-receipt.json)
EXPLORER_URL=$(jq -r .anchor.explorer_url anchor-receipt.json)
# Load EXPLORER_URL in a browser, or query the chain API directly.
```

On the explorer entry, assert all of:

| Field | Expected |
|---|---|
| action `account` | `eosio.token` (Phase α) or `metalfreedom` (Phase β) |
| action `name` | `transfer` (Phase α) or `inscribe` (Phase β) |
| action `memo` | exactly `fyid1:<DAG_ROOT>` (70 chars total, lowercase hex) |
| signer permission | `metalfreedom@anchor` |
| `from` | `metalfreedom` (Phase α `eosio.token::transfer`) |
| `to` | NOT equal to `from`; matches `anchor-receipt.json.anchor.inscribe_action.to` |
| block_num / block_time | matches receipt fields |

The `from != to` invariant is forced by the XPRNetwork `eosio.token` contract (`eosio.token.cpp` L99 `check( from != to, "cannot transfer to self" )`) and is therefore observable on every Phase α receipt.

The signer permission is the binding that ties the on-chain action to `metalfreedom@anchor`. If the action was signed by `metalfreedom@active` or `metalfreedom@owner` instead, the receipt is not honoring the narrow-permission discipline declared by the operator and the evaluator SHOULD flag it.

### Step 9 — Cross-reference integrity (cycles ↔ identity)

For each line of `cycle-history.jsonl` that carries `signed_by_key_seq` and `signed_by_pubkey_fingerprint` (= operators SHOULD set these from `cycle_n >= 3`; earlier cycles MAY omit them per the additive-only schema policy):

1. Find the line in `identity-history.jsonl` whose `key_seq` matches.
2. Assert `operator_identity_pubkey_fingerprint` matches `signed_by_pubkey_fingerprint`.
3. Assert `key_iat ≤ start_iso` of the cycle.
4. If the identity entry is `revoked == true`, assert `revoked_at > start_iso` (= the key was still authoritative when the cycle began).

A cycle line that fails any of these checks indicates either a publication bug or a deliberate misrepresentation; either way, the evaluator SHOULD treat that cycle's claims as unverified.

Cycles published before this binding was introduced (cycle 1 and cycle 2) may legitimately lack the `signed_by_*` fields. Their authenticity rests on the live-validator and on-chain record (= step 8 covers the anchor, the explorer covers the validator entry); the missing cross-ref is honest about the absence of the binding metadata, not an integrity failure.

## Rotation and revocation

If the operator identity key is rotated, the new `identity.json` reflects the new `operator_identity_pubkey_fingerprint` and a new `key_iat`; a new line appends to `identity-history.jsonl` with the next `key_seq`; the prior key's line is updated with `superseded_by_key_seq` populated (and `revoked` / `revoked_at` / `revocation_reason` set if the rotation is for cause rather than for routine cadence). Both branches' roots change, `dag_root_hash` changes, and a new anchor inscription is broadcast.

The recommended rotation cadence is 12 months, aligned to a validation-cycle boundary.

If the previous key is to be marked revoked, an interim `identity.json` may be published with `"revoked": true`, `"revoked_at"` set, and `"revocation_reason"` populated, signed by the new key.

`ssh-keygen -Y verify` does **not** check `key_iat` / `key_exp`. These are operator-declared lifetime metadata; consumers MAY enforce them as policy.

The validator's on-chain signing keys (staker / BLS) are unaffected by operator identity key rotation; they have no relationship to this manifest. The `metalfreedom@anchor` key is independent and rotates on its own schedule, via `metalfreedom@active` invoking `updateauth anchor`.

## Why a Merkle DAG anchor rather than just a signed manifest

A signed manifest alone proves only that the operator (= holder of the identity private key) wrote the manifest at the moment of signing. It does not prove the manifest existed at any specific earlier time, and a malicious operator could in principle silently re-sign a different history later. The Merkle DAG anchor adds an **independent existence-time proof**: once `dag_root_hash` is committed to Metal A-chain in transaction `tx_id` at block `block_num` (block timestamp `block_time`), the operator cannot later modify `identity-history.jsonl` or `cycle-history.jsonl` without producing a different `dag_root_hash` that contradicts the on-chain memo.

The anchor does not prevent the operator from publishing a new, contradicting DAG later; it commits the operator to a specific history at a specific time, and lets evaluators detect contradictions trivially (= the prior on-chain memo is still there, pointing to a different root).

The on-chain mechanism for Phase α is an `eosio.token::transfer` with the binding in the `memo` field. Phase β replaces this with a dedicated `metalfreedom::inscribe` smart-contract action; both forms produce equivalent commitment to `dag_root_hash` via the memo field, and the `anchor-receipt.json.anchor.method` discriminator lets verifier tooling know which on-chain action shape to read.

## Why not BLS / staking key for the off-chain signature?

Three reasons:

1. **Separation of concerns.** The validator's signing keys exist to sign consensus messages. Reusing them for off-chain manifest signing widens their attack surface for no on-chain benefit.
2. **Operational safety.** Reading validator key material on a server-side process to produce an external signature is operationally risky. The operator identity key is intentionally kept off the validator host, the web host, and CI.
3. **Toolchain.** BLS12-381 (used by Metal validator signing keys) is not directly supported by common verification tooling on an evaluator's workstation. `ssh-keygen -Y verify` with ed25519 is universally available and produces a one-line, copy-pasteable verification.

## Scope limits

This identity manifest and DAG anchor are a verifiable binding from a stable public key to an operator brand and a NodeID, plus a cumulative on-chain commitment to the identity-key history and validation-cycle history. They are not:

- a compliance attestation
- a regulatory disclosure
- a KYC document
- a guarantee of any future operational behavior

For honest disclosure of known limitations, see `/risk-disclosure/`. For unilateral commitments, see `/commitments/`.

## See also

- [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md) — canonical byte-level construction rules referenced by this recipe.
- [`OPERATOR_IDENTITY_SETUP.md`](./OPERATOR_IDENTITY_SETUP.md) — operator-side runbook for the off-chain signing key.
- [`IDENTITY_SCHEMA_CHANGELOG.md`](./IDENTITY_SCHEMA_CHANGELOG.md) — design history of the manifest schema and DAG anchor extensions.
- `tests/identity-verification-vectors/` — synthetic reference data for verifier-implementation self-test.
