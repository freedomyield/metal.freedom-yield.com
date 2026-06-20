# Merkle DAG specification (Phase α)

> **Status:** working spec, branch `phase-alpha-schema`, deliverable for Phase α A-chain anchor (cycle 3 start = 2026-07-04 13:00 JST).
> **Audience:** verifier (= evaluator / automated reviewer), implementer of `gen-identity.sh`, schema reviewer.
> **Authority:** within Phase α this document is the canonical spec for the DAG. Once `docs/IDENTITY_VERIFICATION.md` is rewritten (T-4) the recipe sections move there; the byte-level rules stay here.

This document defines the **two-branch Merkle DAG** rooted at `dag_root_hash`, which is the value anchored on Metal A-chain (PulseVM / XPRNetwork) in Phase α via an `eosio.token::transfer` memo of the form `fyid1:<dag_root_hash 64hex>`.

The DAG is independent of, and additive to, the existing `artifact_root` field in `identity.schema.v1.json`. `artifact_root` commits the operator to **which artifacts are published right now**. `dag_root_hash` commits the operator to **the cumulative state of the identity key history and the validation-cycle history**.

## 1. Branches

```
dag_root_hash
├── identity_branch_root
│   leaves = lines of /api/identity-history.jsonl
│   one leaf per operator-identity key entry (key_seq = 1, 2, 3, ...)
└── cycles_branch_root
    leaves = lines of /api/cycle-history.jsonl
    one leaf per closed validation cycle (cycle_n = 1, 2, 3, ...)
```

Each branch is an independent Merkle tree. The DAG root combines the two branch roots with one final SHA-256.

## 2. Leaf canonical form

Each leaf is a **single line of a JSONL document published at a stable URL under `/api/`**. The leaf's bytes are exactly the bytes the operator serves at that line position, **including the trailing newline `\n` if the line is followed by another line, and excluding any trailing newline on the final line**.

An evaluator verifies a leaf by:

1. Fetching the JSONL document with `curl -sSLf`.
2. Splitting on `\n` (each non-empty resulting element is one leaf).
3. Computing `SHA-256(leaf_bytes_as_served)` for each.

This is identical in spirit to the existing `artifact_manifest.<key>.sha256` field, which is `SHA-256(artifact_body_as_served)`. We do not introduce a new canonical encoding — we hash the operator-published bytes verbatim.

**Implication for the operator:** the `gen-*.sh` scripts must emit JSONL with stable line ordering and no trailing whitespace; pretty-printing or re-formatting after publication would invalidate the leaf hashes. The publication pipeline treats `*.jsonl` files as **byte-for-byte append-only** within a schema version.

### 2.1 identity-history.jsonl leaf shape

One line per operator-identity key entry. Sorted by `key_seq` ascending. Append-only: a new key rotation appends a new line; an existing line is rewritten only when its `revoked` / `revoked_at` / `revocation_reason` transitions from `false` to `true`.

| Field | Type | Description |
|---|---|---|
| `schema_version` | int = 1 | Pinned to v1. |
| `key_seq` | int ≥ 1 | Monotone integer. `key_seq=1` is the first operator-identity key. |
| `operator_identity_pubkey_fingerprint` | string | OpenSSH `SHA256:<base64>=` form, same value type as `identity.json.operator_identity_pubkey_fingerprint`. |
| `operator_identity_pubkey_url` | URI string | URL where the public key bytes (OpenSSH `ssh-ed25519 …` line) are served at the time `key_iat`. For `key_seq=1` and any active key this is `/.well-known/operator-identity.pub`. For a superseded key, the operator MAY publish at `/.well-known/operator-identity.v<key_seq>.pub` after a rotation to preserve verifiability of past cycles. |
| `key_iat` | RFC 3339 UTC | When this key became authoritative. |
| `key_exp` | RFC 3339 UTC | Operator-declared expiry. |
| `revoked` | bool | `false` if still authoritative or naturally superseded; `true` only after explicit revocation. |
| `revoked_at` | RFC 3339 UTC or `null` | Required iff `revoked=true`. |
| `revocation_reason` | string or `null` | Required iff `revoked=true`. |
| `superseded_by_key_seq` | int or `null` | Non-null on a key that has been rotated out by a higher `key_seq` for ANY reason (revocation OR routine rotation). |

The schema is **additive within v1**: new fields MAY appear in future lines. Verifiers MUST tolerate unknown fields.

### 2.2 cycle-history.jsonl leaf shape (extension)

The existing `cycle-history.schema.v1.json` defines per-line shape for closed cycles. Phase α extends it additively with **two cross-ref fields** that bind each cycle leaf to the identity key authoritative at the cycle's start.

| Field | Type | Description |
|---|---|---|
| `signed_by_key_seq` | int ≥ 1 | The `key_seq` from `identity-history.jsonl` that was authoritative on `start_iso`. |
| `signed_by_pubkey_fingerprint` | string | The corresponding `operator_identity_pubkey_fingerprint` (= same hash that appears in the matching identity-history line). |

Both fields are `required` in the v1 schema **for any cycle leaf written after this spec's adoption (cycle ≥ 3)**. Earlier closed cycles (1, 2) MAY be reissued with these fields populated by reference to the key authoritative at the time, **or** MAY be left without them (additive-only stability means absence is not invalid).

Cross-ref integrity check (verifier-side):

1. Find the identity-history line with matching `key_seq`.
2. Confirm `operator_identity_pubkey_fingerprint` matches `signed_by_pubkey_fingerprint`.
3. Confirm `key_iat ≤ start_iso` and (if `revoked=true`) `revoked_at > start_iso`.

## 3. Merkle tree construction (per branch)

Identical to the existing implementation in `scripts/operator-local/gen-identity.sh` lines 186–230 (`compute_merkle_root`). For each branch:

1. **Leaves**: take each line's `SHA-256(leaf_bytes_as_served)` in the order the lines appear in the JSONL document.
   - identity_branch leaves are ordered by `key_seq` ascending (= file order, since lines are append-only by `key_seq`).
   - cycles_branch leaves are ordered by `cycle_n` ascending (= file order, since lines are append-only by `cycle_n`).
2. **While** more than one leaf remains at the current level:
   - If the count is odd, **duplicate the last leaf** (Bitcoin convention).
   - Pair adjacent leaves and compute the parent: `parent = SHA-256( raw_bytes(left) || raw_bytes(right) )`. The inputs are the 32-byte raw digests, not the 64-char hex strings.
3. The single remaining hex digest is the branch root.

Single-leaf branch: the branch root equals the single leaf hash unchanged.

Zero-leaf branch: see §5.

This is bit-for-bit equivalent to `truthmark.io/scrapers/xpr/merkle.py::compute_merkle_root_from_hashes`. A Python or any-language verifier may reuse that function directly against our 64-hex leaf hashes (converted to 32 raw bytes).

## 4. DAG root computation

```
dag_root_hash = SHA-256( raw_bytes(identity_branch_root) || raw_bytes(cycles_branch_root) )
              → hex-encoded (64 chars, lowercase)
```

The two inputs are 32 raw bytes each, concatenated into a 64-byte buffer, hashed once with SHA-256, hex-encoded for publication.

This single `dag_root_hash` is the value:

- Stored as `dag_root_hash` in `/api/identity.json` (additive field in `identity.schema.v1.json`).
- Inscribed on Metal A-chain in Phase α as `eosio.token::transfer.memo = "fyid1:<dag_root_hash>"`.
- Republished in `/api/anchor-receipt.json` together with the A-chain `tx_id`, block height, and timestamp.

## 5. Empty-branch convention

A branch with zero leaves SHALL use the sentinel hash:

```
NULL_BRANCH_HASH = SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

This avoids leaving the field unset and lets verifiers always run the §4 computation.

At Phase α start, both branches have ≥ 1 leaf (identity-history has at least `key_seq=1`; cycles-history has at least cycles 1 and 2 closed). The empty-branch case is documented for future robustness and for synthetic test vectors.

## 6. A-chain anchor binding (Phase α)

Phase α uses an `eosio.token::transfer` transaction on Metal A-chain (PulseVM / XPRNetwork), signed by the narrow `freedomyield@anchor` permission. The minimum-cost form is a self-transfer of an arbitrarily small token amount; the memo carries the binding.

```
memo = "fyid1:" + lowercase_hex(dag_root_hash)
       = "fyid1:<64 hex chars>"   (= 5 + 1 + 64 = 70 chars)
```

The memo prefix `fyid1:` (= "Freedom Yield identity, format version 1") lets future on-chain parsers distinguish our inscriptions and lets us migrate to `fyid2:` if a breaking change is ever needed without colliding with intervening unrelated memos.

Phase β SHALL move to a dedicated `freedomyield::inscribe` smart-contract action; the memo format is retained as the canonical commitment form so that the Phase α corpus remains verifiable after migration.

Verifier check, given an `anchor-receipt.json`:

1. Look up `tx_id` on a public XPR explorer.
2. Read the action's `memo` field.
3. Assert `memo == "fyid1:" + dag_root_hash` from the receipt.
4. Assert the action's signer permission is `freedomyield@anchor` (or, in Phase β, `freedomyield@anchor` invoking `freedomyield::inscribe`).

## 7. Document set

| Path | Role | Shape |
|---|---|---|
| `/api/identity.json` | Document 1 — signed manifest | One JSON object. Adds `dag_root_hash` field; retains `artifact_root` and `artifact_manifest` unchanged. Signed by ed25519 via `ssh-keygen -Y sign`. |
| `/api/identity.json.sig` | Detached signature | Output of `ssh-keygen -Y sign -n freedom-yield/validator-identity`. |
| `/api/identity-history.jsonl` | identity_branch leaf source | JSONL, one line per identity key entry, sorted by `key_seq`. **NEW in Phase α.** |
| `/api/cycle-history.jsonl` | cycles_branch leaf source | JSONL, one line per closed cycle, sorted by `cycle_n`. **Existing; extended with `signed_by_key_seq` + `signed_by_pubkey_fingerprint`.** |
| `/api/cycles-history.json` | DAG summary | One JSON object. Contains `identity_branch_root`, `cycles_branch_root`, `dag_root_hash`, leaf counts, source URLs, generated_at. **NEW in Phase α.** (Naming chosen to match the design memory; the trailing `s` distinguishes this summary doc from the existing per-line leaf source `cycle-history.jsonl`.) |
| `/api/anchor-receipt.json` | A-chain inscribe receipt | Document 2 per the brief. Contains `dag_root_hash`, A-chain `tx_id`, block height / timestamp, memo verbatim, signing account + permission. **NEW in Phase α.** |
| `/.well-known/operator-identity.pub` | Current operator identity public key | One-line OpenSSH `ssh-ed25519 …` form. Stable URL across rotations. Historical keys at `/.well-known/operator-identity.v<key_seq>.pub` if the operator chooses to preserve them. |

## 8. Stability and versioning

- All v1 schemas are `additive-only-within-v1` (= existing policy, `x-stability` field).
- A breaking change creates a new major version: `*.schema.v2.json` at a distinct URL.
- The memo prefix `fyid1:` is part of the wire contract; a breaking change to the DAG construction MUST use `fyid2:`.
- `dag_root_hash` is computed deterministically from the current contents of both JSONL documents at the moment `gen-identity.sh` runs. If any leaf line is edited after publication (rather than appended), the DAG root changes and any A-chain anchor pointing at the prior root becomes orphaned. Operators MUST treat published `*.jsonl` files as byte-for-byte append-only within a schema version.

## 9. Test vectors

Reference vectors live in `tests/identity-verification-vectors/` (T-5). Each vector provides:

- One synthetic `identity-history.jsonl`
- One synthetic `cycle-history.jsonl`
- The expected `identity_branch_root`, `cycles_branch_root`, `dag_root_hash` (64 hex each)
- For one specified leaf: the expected per-line `leaf_hash`, the Merkle proof (sibling hashes), and the resulting reconstructed branch root

Cases covered: 1-leaf branch (= single leaf, root = leaf), 2-leaf branch, 3-leaf branch (= odd, last leaf duplicated), 4-leaf branch, zero-leaf branch (= sentinel hash from §5), cross-ref integrity (= cycles_branch leaf referencing identity_branch entry).

## 10. Open items for the rest of Phase α

- **IC-3 (C3 → C2, deadline 2026-06-23):** confirm Phase β `freedomyield::inscribe` action signature so `anchor-receipt.schema.v1.json` can declare a stable `inscribe_action` block (currently captured as `eosio.token::transfer` for Phase α; Phase β additive fields will live alongside).
- **C1 (gen-identity.sh extension):** consume `/api/identity-history.jsonl` and `/api/cycle-history.jsonl`, compute the two branch roots via the existing `compute_merkle_root` shell function (= already implements §3), concatenate raw bytes per §4, emit `dag_root_hash` into `identity.json` as an additive field.
- **C2 (T-4):** rewrite `docs/IDENTITY_VERIFICATION.md` into a 9-step recipe that walks an evaluator from `identity.json` through `dag_root_hash` to the A-chain explorer cross-check. Cite this document for byte-level rules.

## See also

- `docs/IDENTITY_SCHEMA_CHANGELOG.md` — design history of `identity.schema.v1.json` including the 2026-06-20 retirement of the prior P-Chain memo binding.
- `scripts/operator-local/gen-identity.sh` lines 186–230 — the reference Merkle root implementation reused by both branches.
- `/Users/admin/htdocs/01_PROJECTS/truthmark.io/scrapers/xpr/merkle.py` — sibling project's Merkle implementation, bit-for-bit equivalent to ours; useful as an independent reference for verifier implementations.
