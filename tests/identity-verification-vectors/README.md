# Phase α Merkle DAG — test vectors

Reference data for verifier implementations. Synthetic inputs only; no production identity, key, or validation cycle is represented here.

## What is in this directory

- `generate.py` — Python 3.8+, stdlib only. Reference implementation of the construction in [`docs/MERKLE_DAG_SPEC.md`](../../docs/MERKLE_DAG_SPEC.md). Also generates the vector files on disk.
- `verify-shell-equivalence.sh` — runs an inlined copy of the portable shell `compute_merkle_root` from `scripts/operator-local/gen-identity.sh` against every vector and asserts the resulting roots match what `generate.py` produced. This pins the cross-implementation equivalence claim made in the spec.
- `v01-single-leaf/`, `v02-three-leaf-odd/`, `v03-four-leaf/`, `v04-empty-branch/`, `v05-full-dag/` — one directory per vector. Each contains:
  - one or two JSONL input files (= the synthetic identity-history.jsonl and/or cycle-history.jsonl this vector exercises)
  - `expected.json` — all derived values (leaf hashes in order, branch root, Merkle proof for one designated leaf, and for v05 the full DAG including `dag_root_hash` and the corresponding A-chain memo string `fyid1:<dag_root_hash>`)

## How an auditor uses these vectors

1. **Re-derive in Python** (= sanity-check the reference itself):

   ```sh
   python3 generate.py --verify
   ```

   Re-derives every expected value from the on-disk JSONL inputs and asserts equality with the on-disk `expected.json`. Exits non-zero on any mismatch.

2. **Re-derive in shell** (= prove that the production shell implementation matches the Python reference):

   ```sh
   bash verify-shell-equivalence.sh
   ```

   Runs the inlined `compute_merkle_root` shell function against each vector's leaf set and confirms the same branch / DAG roots emerge.

3. **Re-derive in a third language** (= the actual point of the vectors):

   An auditor writes a verifier in any language (Rust, Go, JavaScript, OCaml, …) that consumes one of the JSONL inputs and computes:

   - The per-line SHA-256 hash of the raw bytes (= leaf hash).
   - The Merkle root over those leaves following the rules in [`docs/MERKLE_DAG_SPEC.md`](../../docs/MERKLE_DAG_SPEC.md) §3 (Bitcoin-style odd-leaf duplicate; `parent = SHA-256(raw_bytes(left) || raw_bytes(right))`).
   - For `v05-full-dag`, also compute `dag_root_hash = SHA-256(raw_bytes(identity_root) || raw_bytes(cycles_root))` per spec §4.

   The auditor's results MUST equal the values in `expected.json`. Any disagreement is either an auditor-implementation bug or — if the auditor is highly confident — a spec ambiguity that should be flagged.

## What each vector demonstrates

| Vector | Leaves | What it exercises |
|---|---|---|
| `v01-single-leaf` | 1 | branch_root equals the single leaf hash unchanged (no pairing). |
| `v02-three-leaf-odd` | 3 | The Bitcoin-style odd-leaf duplicate at level 0; intermediate parents reduce to root at level 2. |
| `v03-four-leaf` | 4 | Standard multi-level reduction with no duplication; two level-0 pairings → one level-1 pairing → root. |
| `v04-empty-branch` | 0 | The sentinel-hash convention from spec §5: empty branch root equals SHA-256("") = `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. |
| `v05-full-dag` | 2+4 | End-to-end: two-leaf identity_branch (with a key rotation) plus four-leaf cycles_branch (with cross-reference to identity_branch via `signed_by_key_seq` + `signed_by_pubkey_fingerprint`). Demonstrates the full chain through `dag_root_hash` and the A-chain anchor memo `fyid1:<dag_root_hash>`. |

## Leaf-byte convention (= the one trap)

Per spec §2, the bytes hashed for each leaf are the line bytes **as the operator publishes them**, including the trailing `\n` if the line is followed by another line, excluding any trailing `\n` on the final line. For these synthetic vectors the JSONL files are generated with a trailing newline after every line (= the form `gen-*.sh` emits); `generate.py` and the shell helper both handle the trailing-newline-on-last-line case gracefully by treating empty pieces as not-a-leaf.

A common verifier-implementation bug is to call `json.loads(line.strip())` and hash the re-serialised JSON rather than the published bytes. That will produce different leaf hashes whenever key order, whitespace, or number formatting differs between the operator's emitter and the verifier's serialiser. Always hash the **raw published bytes**, never a re-serialisation.

## Regenerating the vectors after a spec change

If [`docs/MERKLE_DAG_SPEC.md`](../../docs/MERKLE_DAG_SPEC.md) is amended in a way that changes any of the construction rules (within v1 this should not happen because the spec is `additive-only-within-v1`, but a v2 spec might), update `generate.py` to match and re-run:

```sh
python3 generate.py            # regenerate vector files in place
python3 generate.py --verify   # confirm self-consistency
bash verify-shell-equivalence.sh   # confirm shell still matches
```

Commit the resulting vector file changes together with the spec amendment so the audit trail is complete.

## See also

- [`docs/MERKLE_DAG_SPEC.md`](../../docs/MERKLE_DAG_SPEC.md) — canonical spec.
- [`docs/IDENTITY_VERIFICATION.md`](../../docs/IDENTITY_VERIFICATION.md) — verifier-side recipe (uses these vectors implicitly via §3–§5).
- `scripts/operator-local/gen-identity.sh` lines 186–230 — production shell implementation of `compute_merkle_root`.
- Sibling-project independent reference (= the `compute_merkle_root_from_hashes` function in `truthmark.io/scrapers/xpr/merkle.py`, out-of-tree relative to this repository, not redistributed here). Bit-for-bit equivalent to the production shell implementation.
