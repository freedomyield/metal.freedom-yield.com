# DAG anchor specification (v2, 3-branch)

> **Status:** canonical spec for the on-chain identity/observation/artifact commitment.
> **Audience:** verifier (= evaluator / automated reviewer), implementer of the anchor pipeline, schema reviewer.
> **Authority:** this document is the canonical byte-level spec for the DAG root and its A-chain binding. Operator-facing recipe steps live in `docs/IDENTITY_VERIFICATION.md`; the byte-level rules stay here.
>
> **Supersedes the retired 2-branch `fyid1:` model.** Earlier revisions of this file defined a two-branch Merkle DAG (`identity` ‖ `cycles`) rooted at `dag_root_hash`, inscribed as `fyid1:<hex>`. That model is **retired** — it is no longer computed or inscribed. The single on-chain commitment is now the 3-branch `dag_root_computed` described below, inscribed with the `fya<schema>c<cycle>` memo family. See `docs/IDENTITY_SCHEMA_CHANGELOG.md`.

This document defines the **three-branch DAG** rooted at `dag_root_computed`, the value anchored on Metal A-chain (PulseVM / XPRNetwork) via a set of `eosio.token::transfer` memos of the form `fya<schema>c<cycle>:<dag_root_computed 64hex>`.

The DAG commits the operator to three parallel facts as of a given validation cycle: **who the operator is** (identity branch), **what was observed on-chain that cycle** (observations branch), and **which artifacts are published** (artifacts branch).

## 1. Branches

```
dag_root_computed
├── identity_branch      → identity_root      (who the operator is)
├── observations_branch  → observations_root  (this cycle's on-chain observations)
└── artifacts_branch     → artifacts_root     (the published artifact set)
```

The three branches are the top-level objects `identity_branch`, `observations_branch`, and `artifacts_branch` inside a single published document, `/api/anchor-source.json`. Each branch is a self-contained JSON object; **there is no per-branch Merkle tree of JSONL leaves** (that was the retired 2-branch model). A branch root is one SHA-256 over the branch object's canonical bytes. The DAG root combines the three branch roots with one final SHA-256.

## 2. Canonical form

A branch root is computed over the branch object's **canonical JSON bytes**, defined as the output of `jq -cS` (compact + sorted keys):

- `-c` — compact: no insignificant whitespace.
- `-S` — sort object keys lexicographically at every level.

```
canonical(branch) = bytes of ( jq -cS '.<branch>'  < anchor-source.json )
```

This is a deterministic, JCS-style (RFC 8785-ish) canonicalization: any verifier that reproduces jq's compact + sorted-key serialization of the same logical JSON value obtains the same bytes, regardless of the key order or whitespace in the served file. Unlike the retired JSONL-leaf model (which hashed served bytes verbatim and forbade re-serialization), the v2 branch hash **requires** canonical re-serialization — served key order and whitespace are intentionally normalized away by `jq -cS`.

A verifier MUST:

- Fetch `/api/anchor-source.json` with `curl -sSLf` and parse it as JSON.
- For each branch, serialize that branch object with `jq -cS` (or an equivalent compact + sorted-key JCS serializer that matches jq's number/string encoding) before hashing.

A verifier MUST NOT hash the branch's served bytes verbatim — the served document may carry a different key order or pretty-print whitespace than the canonical form; only the `jq -cS` bytes are authoritative.

### 2.1 Trailing newline (`0x0a`)

The canonical bytes that get hashed are the `jq -cS` output **including the trailing newline (`0x0a`) that `jq` appends by default**. The reference pipeline `jq -cS '.<branch>' | sha256sum` carries that newline into the digest, so the authoritative branch root is `sha256(canonical + "\n")`, not `sha256(canonical)`.

A verifier that uses a non-jq canonicalizer — RFC 8785, Python `json.dumps(sort_keys=True, separators=(',', ':'), ensure_ascii=False)`, JavaScript `JSON.stringify(sortDeep(...))`, or any other `jq -cS`-equivalent serializer that emits the same sorted-key bytes **but omits the trailing newline** — MUST append one `0x0a` byte before hashing. Omitting it yields a digest that does not match the on-chain memo hex. This is the same rule stated in [`ANCHOR_SOURCE.md`](./ANCHOR_SOURCE.md) (§ Dag root composition); the cross-canonicalizer regression check lives at `tests/anchor-source-canonicalizer/test-canonicalizer-newline.sh`.

## 3. Branch root computation

```
identity_root     = SHA-256( jq -cS '.identity_branch'     ) → 64 hex, lowercase
observations_root = SHA-256( jq -cS '.observations_branch' ) → 64 hex, lowercase
artifacts_root    = SHA-256( jq -cS '.artifacts_branch'    ) → 64 hex, lowercase
```

Each branch root is the lowercase hex SHA-256 digest of that branch's canonical bytes (§2). This is the exact computation performed by `scripts/gen-anchor-source.sh:469-471` (producer) and re-verified by `scripts/sign-anchor-event.sh:176-178` (signer, belt-and-suspenders).

### Branch object contents (informative)

The precise field set is defined by `gen-anchor-source.sh` and evolves additively; a verifier does not need to know the fields to check the root (it hashes the whole branch object), but for orientation:

- **`identity_branch`** — the operator identity commitment: `operator_ed25519_pubkey_sha256_hex` (semantic C: SHA-256 of the raw 32-byte ed25519 key served at `/.well-known/operator-identity.pub`) and `identity_history_root` (SHA-256 of the authoritative `identity-history.jsonl`), plus fingerprint/URL metadata.
- **`observations_branch`** — what the node observed on-chain this cycle, including `cycle_number_observed` (the cycle whose start this anchor records) and feed timestamps.
- **`artifacts_branch`** — the published artifact set as a list of `{path, sha256}` entries, each `sha256` being SHA-256 of the artifact body as served.

## 4. DAG root computation

```
dag_root_computed = SHA-256( ascii(identity_root) || ascii(observations_root) || ascii(artifacts_root) )
                  → hex-encoded (64 chars, lowercase)
```

**The three inputs are concatenated as their 64-character lowercase-hex ASCII strings** (not as raw 32-byte digests), producing a 192-byte ASCII buffer, hashed once with SHA-256. This differs from the retired model, which concatenated raw digest bytes. Reference: `gen-anchor-source.sh:472` (`sha256_str "${ID_ROOT}${OB_ROOT}${AR_ROOT}"`).

This single `dag_root_computed` is the value:

- Stored as `dag_root_computed` in `/api/anchor-source.json`.
- Inscribed on Metal A-chain as the memo of the fourth anchor action (§6): `fya<schema>c<cycle>:<dag_root_computed>`.
- Republished in `/api/anchor-receipt.json` as `dag_root_hash`, together with the A-chain `tx_id`, block height, and timestamp.

## 5. Determinism and append-only discipline

The branches are recomputed each cycle from live sources; `dag_root_computed` is deterministic given the served `anchor-source.json`. The verifiability discipline is:

- `identity-history.jsonl` (the source of `identity_history_root`) MUST be treated as **byte-for-byte append-only** within a schema version — editing a past line rather than appending changes `identity_history_root`, hence `identity_root`, hence `dag_root_computed`, orphaning any prior anchor.
- Each artifact's served body MUST match the `sha256` recorded in `artifacts_branch` at anchor time.
- Because branch roots are canonical (`jq -cS`), reordering keys or reformatting `anchor-source.json` in transit does **not** change any root — only the logical JSON values matter.

## 6. A-chain anchor binding

The anchor is a set of **four** `eosio.token::transfer` actions on Metal A-chain (PulseVM / XPRNetwork), signed by the narrow `<xpr-account>@anchor` permission (config `xpr-account`), each a transfer of a small amount (default `0.0001 XPR`, config `xpr-quantity`) from `<xpr-account>` to a **dedicated sink account distinct from `<xpr-account>`** (config `anchor-sink`). Self-transfer (`from == to`) is rejected by `eosio.token` (`check(from != to, "cannot transfer to self")`), so a second account is required. The four memos carry the binding.

Let `schema` = `anchor-source.json .schema_version` (= 1) and `cycle` = `anchor-source.json .observations_branch.cycle_number_observed`. The memo prefix is:

```
PREFIX = "fya" + schema + "c" + cycle          (= "freedom yield anchor", schema major, cycle number)
```

The four memos, one per action, in order:

```
action 1 memo = PREFIX + "-id:" + identity_root       (fya<schema>c<cycle>-id:<64hex>)
action 2 memo = PREFIX + "-ob:" + observations_root    (fya<schema>c<cycle>-ob:<64hex>)
action 3 memo = PREFIX + "-ar:" + artifacts_root       (fya<schema>c<cycle>-ar:<64hex>)
action 4 memo = PREFIX + ":"    + dag_root_computed     (fya<schema>c<cycle>:<64hex>)
```

Publishing the three branch roots alongside the DAG root lets a verifier confirm each branch independently and recompute the DAG root from on-chain data alone. Each memo stays well under the 256-byte `eosio.token` memo limit (asserted ≤ 200 at `sign-anchor-event.sh:242`).

**Memo prefix history:** the prefix was `fyid1:` (single memo, 2-branch) in the retired model, pivoted to the `fya<schema>c<cycle>` family on 2026-07-01 — both to carry the 3-branch structure and to isolate our inscriptions from an accidental mainnet tx (`fyid1v1c2-test-single`) that polluted the old namespace. A breaking change to the DAG construction increments `schema`, so the memo family self-describes its format version.

Verifier check, given an `/api/anchor-receipt.json`:

1. Fetch `/api/anchor-source.json`; recompute `identity_root`, `observations_root`, `artifacts_root` (§3) and `dag_root_computed` (§4).
2. Look up `tx_id` on a public XPR explorer; read the four action memos.
3. Assert the four memos equal the four strings in §6 (branch roots + DAG root), with `schema`/`cycle` matching `anchor-source.json`.
4. Assert `anchor-receipt.json .dag_root_hash == dag_root_computed`.
5. Assert each action's signer permission is `<xpr-account>@anchor`.

## 7. Document set

| Path | Role | Shape |
|---|---|---|
| `/api/anchor-source.json` | DAG source + root | One JSON object: `schema_version`, the three branch objects (`identity_branch`, `observations_branch`, `artifacts_branch`), and `dag_root_computed`. The authoritative input for §3–§4. |
| `/api/anchor-receipt.json` | A-chain inscribe receipt | One JSON object: `dag_root_hash` (= the on-chain `dag_root_computed`), `tx_id`, block height / timestamp, the four memos verbatim, signing account + permission. |
| `/api/anchor-history.jsonl` | Append-only anchor log | One line per broadcast anchor (cycle → tx_id → dag). |
| `/api/identity.json` | Signed identity manifest | One JSON object, signed by ed25519 (`ssh-keygen -Y sign`). **Does not carry the DAG root** (the `dag_root_hash` field was retired; the on-chain root lives in `anchor-source.json`/`anchor-receipt.json`). |
| `/api/identity-history.jsonl` | `identity_history_root` source | JSONL, one line per identity key entry, byte-for-byte append-only. |
| `/.well-known/operator-identity.pub` | Current operator identity public key | One-line OpenSSH `ssh-ed25519 …`. Stable URL across rotations. |

**Naming convention:** files ending in `.jsonl` are append-only leaf/log sources; files ending in `.json` are regenerated snapshots or signed manifests.

## 8. Stability and versioning

- The memo family `fya<schema>c<cycle>` encodes its format version in `schema` (= `anchor-source.json .schema_version`). A breaking change to the branch or root construction increments `schema`; the old corpus stays verifiable under the old `schema` value.
- All v1 schemas are additive-only within v1; verifiers MUST tolerate unknown fields in any branch object.
- `dag_root_computed` is deterministic given the served `anchor-source.json`; the append-only discipline of §5 preserves the reproducibility of past anchors.

## 9. Test vectors

Reference coverage lives in:

- `tests/sign-anchor-event/` — the 4-memo composition + 3-branch recomputation + dry-run wire format.
- `tests/gen-anchor-receipt/` — receipt 7-PASS verification against a signer output.
- `tests/append-anchor-history/` — history-line append shape.

Each exercises the §3–§6 contract against fixtures rather than the retired 2-branch vectors.

## See also

- `docs/IDENTITY_SCHEMA_CHANGELOG.md` — design history, including the retirement of the 2-branch `fyid1:` binding and of `identity.json.dag_root_hash`.
- `docs/IDENTITY_VERIFICATION.md` — the operator/evaluator recipe that walks from `anchor-source.json` through the four on-chain memos.
- `scripts/gen-anchor-source.sh` — the producer (branch construction + §3–§4 computation).
- `scripts/sign-anchor-event.sh` — the signer (independent §3–§4 recomputation + §6 memo composition + `bin/safe-broadcast` delegation).
