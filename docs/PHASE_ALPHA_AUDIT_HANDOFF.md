# Phase α audit handoff (C2 deliverables, 2026-06-21)

This document is the entry point for an independent auditor of the Phase α Merkle DAG anchor design for the Freedom Yield Metal validator. It lists what has been delivered, what is still pending from other parties before production activation, what the auditor can verify today, and what the auditor cannot verify until activation (= cycle 3 start, 2026-07-04 13:00 JST).

The Phase α work is split across three Claude sessions per [`project_phase_alpha_3_claude_delegation_brief`](../../../.claude/projects/-Users-admin-htdocs-01-PROJECTS-metal-freedom-yield-com/memory/project_phase_alpha_3_claude_delegation_brief.md) (off-tree memory). This handoff covers **C2** (schema + verification) deliverables specifically; the on-chain permission / signing setup (C3) and the integration / hook wiring (C1) are tracked separately.

## Status

**Delivered (= auditable now):**

- Byte-level Merkle DAG specification
- Five public JSON schemas (3 NEW + 2 additive extensions), all AJV-compile-clean
- Five example artifacts (1 per schema) validating against their schemas
- Verifier-side nine-step recipe
- Five synthetic test vectors with Python reference + portable shell equivalence proof

**Not yet delivered (= depends on other Claude sessions or operator decisions):**

- Live runtime `/api/identity.json` carrying a real `dag_root_hash` (gated on C1 extending `gen-identity.sh`)
- Live runtime `/api/anchor-receipt.json` carrying a real A-chain transaction id (gated on C3's signer + permission setup AND on the first inscription event at cycle 3 start)
- A-chain `freedomyield@anchor` permission deployed on XPR mainnet (gated on C3 + operator)
- Sink-account name for Phase α `eosio.token::transfer` `to` field (gated on operator judgment per [`project_phase_alpha_coordination_log`](../../../.claude/projects/-Users-admin-htdocs-01-PROJECTS-metal-freedom-yield-com/memory/project_phase_alpha_coordination_log.md) judgment #1)

## What an auditor can do today

### 1. Validate every schema and example

```sh
cd metal.freedom-yield.com

# Verify all five schemas compile under AJV draft-2020:
for f in public/api/anchor-receipt.schema.v1.json \
         public/api/cycles-history.schema.v1.json \
         public/api/identity-history.schema.v1.json \
         public/api/identity.schema.v1.json \
         public/api/cycle-history.schema.v1.json; do
  echo "=== $f ==="
  npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv compile \
    --strict=false -c=ajv-formats --spec=draft2020 -s "$f"
done

# Verify every example validates against its schema (object schemas):
for pair in \
  "public/api/anchor-receipt.schema.v1.json public/api/anchor-receipt.example.json" \
  "public/api/cycles-history.schema.v1.json public/api/cycles-history.example.json" \
  "public/api/identity.schema.v1.json public/api/identity.example.json"; do
  read S D <<< "$pair"
  echo "=== $D against $S ==="
  npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv validate \
    --strict=false -c=ajv-formats --spec=draft2020 -s "$S" -d "$D"
done

# JSONL per-line validation (identity-history and cycle-history are per-line):
for pair in \
  "public/api/identity-history.schema.v1.json public/api/identity-history.example.jsonl" \
  "public/api/cycle-history.schema.v1.json public/api/cycle-history.example.jsonl"; do
  read S D <<< "$pair"
  echo "=== $D per-line against $S ==="
  while IFS= read -r line; do
    printf '%s\n' "$line" > /tmp/_jsonl.json
    npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv validate \
      --strict=false -c=ajv-formats --spec=draft2020 -s "$S" -d /tmp/_jsonl.json
    rm -f /tmp/_jsonl.json
  done < "$D"
done
```

Expected outcome: every line prints `valid`. C2 confirmed these pass at commit time.

### 2. Re-derive the five test vectors

```sh
cd metal.freedom-yield.com
python3 tests/identity-verification-vectors/generate.py --verify
bash   tests/identity-verification-vectors/verify-shell-equivalence.sh
```

Expected outcome: both scripts print `OK` for v01 through v05 and exit zero. The Python script re-derives every `expected.json` value from the on-disk inputs and asserts match; the shell script proves the portable production implementation (`scripts/operator-local/gen-identity.sh::compute_merkle_root`) produces bit-for-bit equivalent results.

### 3. Write an independent third-language verifier

The five test vectors in `tests/identity-verification-vectors/v01-*` through `v05-*` carry deterministic inputs (`identity-history.jsonl` and/or `cycle-history.jsonl`) and a deterministic `expected.json` for each. An auditor implementing the verifier in any third language can:

1. Read the JSONL input.
2. For each non-empty line: compute SHA-256 of the **raw published bytes** (= NOT a re-serialisation of the parsed JSON).
3. Compute the Merkle root over the resulting leaf hashes following the rules in [`MERKLE_DAG_SPEC.md`](./MERKLE_DAG_SPEC.md) §3.
4. For `v05-full-dag`, also combine both branch roots per spec §4 to produce `dag_root_hash`.
5. Assert results match `expected.json`.

The pre-computed branch / DAG roots are listed in each vector's `expected.json`; e.g., `v05-full-dag` carries:

```
identity_branch_root: 8494a8e5a02ecf0fd7960acf9880a53feb9077b7a1745f3c04f2f750abf94524
cycles_branch_root:   b54356c13488519d6a9fe30f86f50465d0a9b8d3899c8fda2ca34d1ba9744c71
dag_root_hash:        c3f67f4aa9742691d73f9d2fcfea1c8fffcaa8d023718cb40da4c2b7c076a4a0
memo_for_anchor:      fyid1:c3f67f4aa9742691d73f9d2fcfea1c8fffcaa8d023718cb40da4c2b7c076a4a0
```

### 4. Read the verifier-side recipe

[`docs/IDENTITY_VERIFICATION.md`](./IDENTITY_VERIFICATION.md) walks the nine steps a real evaluator runs against the production endpoints (once they are live). Steps 1–3 are the existing `ssh-keygen -Y verify` ed25519 signature check that was in place pre-Phase α. Steps 4–9 are new: leaf hashing, branch-root computation, DAG combination, cross-document root equality, on-chain anchor cross-check, and identity ↔ cycles cross-reference integrity.

## What an auditor cannot verify today

The following can only be verified after Phase α activates (= first inscription broadcast at cycle 3 start, 2026-07-04 13:00 JST):

- The presence of `dag_root_hash` in the live `/api/identity.json`.
- The existence of `/api/anchor-receipt.json` with a real XPRNetwork `tx_id`.
- The on-chain inscription's `memo == "fyid1:<dag_root_hash>"` invariant on a public XPRNetwork explorer.
- The `freedomyield@anchor` permission's actual deployed scope (= `linkauth` to inscribe-class actions only).
- The choice of sink account for Phase α `eosio.token::transfer` `to` (= operator judgment pending; example uses placeholder `fyldsink`).

The auditor MAY register these as open items to re-check after activation.

## Deliverable inventory

### Spec

- `docs/MERKLE_DAG_SPEC.md` (180 lines, commit `1ee1f99` + `76ebef2`) — byte-level construction rules. Authoritative for everything below.

### Schemas

| Path | Status | Stability |
|---|---|---|
| `public/api/anchor-receipt.schema.v1.json` | NEW | additive-only-within-v1 |
| `public/api/cycles-history.schema.v1.json` | NEW | additive-only-within-v1 |
| `public/api/identity-history.schema.v1.json` | NEW | additive-only-within-v1 |
| `public/api/identity.schema.v1.json` | EXTENDED (additive: `dag_root_hash`, `cycles_history_url`, `anchor_receipt_url`) | additive-only-within-v1, baseline unchanged |
| `public/api/cycle-history.schema.v1.json` | EXTENDED (additive: `signed_by_key_seq`, `signed_by_pubkey_fingerprint`) | additive-only-within-v1 |

### Examples

| Path | Validates against |
|---|---|
| `public/api/anchor-receipt.example.json` | anchor-receipt.schema.v1.json |
| `public/api/cycles-history.example.json` | cycles-history.schema.v1.json |
| `public/api/identity-history.example.jsonl` (per line) | identity-history.schema.v1.json |
| `public/api/identity.example.json` | identity.schema.v1.json (updated for new additive fields) |
| `public/api/cycle-history.example.jsonl` (per line) | cycle-history.schema.v1.json (updated for new additive fields) |

### Recipe + audit trail

| Path | Purpose |
|---|---|
| `docs/IDENTITY_VERIFICATION.md` | Verifier-side nine-step recipe (full rewrite for Phase α) |
| `docs/IDENTITY_SCHEMA_CHANGELOG.md` | Design history; 2026-06-21 entry covers this revision |
| `docs/PHASE_ALPHA_AUDIT_HANDOFF.md` | This document |

### Test vectors

| Path | Coverage |
|---|---|
| `tests/identity-verification-vectors/generate.py` | Python reference implementation + vector generator |
| `tests/identity-verification-vectors/verify-shell-equivalence.sh` | Shell ↔ Python equivalence proof |
| `tests/identity-verification-vectors/README.md` | Audit instructions for the vector set |
| `tests/identity-verification-vectors/v01-single-leaf/` | 1-leaf branch |
| `tests/identity-verification-vectors/v02-three-leaf-odd/` | 3-leaf branch (odd-leaf duplicate) |
| `tests/identity-verification-vectors/v03-four-leaf/` | 4-leaf multi-level reduction |
| `tests/identity-verification-vectors/v04-empty-branch/` | Sentinel hash for zero leaves |
| `tests/identity-verification-vectors/v05-full-dag/` | End-to-end DAG + dag_root_hash |

## What an auditor should specifically scrutinise

These are the areas C2 considers most likely to surface a finding:

1. **Leaf canonical encoding** — spec §2 commits to hashing the **published JSONL line bytes verbatim**. An auditor should test the edge case where a generator emits inconsistent whitespace or differently-ordered JSON keys between two runs, and confirm that the spec's strict-publication discipline prevents this from silently breaking verification. Recommended attack to attempt: re-format `cycle-history.jsonl` (e.g., re-pretty-print or re-sort keys) and verify that the existing `cycles_branch_root` no longer reproduces — which would catch a re-formatter introduced into the publication pipeline.

2. **BLOCK-1 (self-transfer prohibition)** — confirm independently from XPRNetwork sources that `eosio.token::transfer` rejects `from == to`. Reference: `XPRNetwork/proton.contracts/contracts/eosio.token/src/eosio.token.cpp` line 99 `check( from != to, "cannot transfer to self" );`. This is the constraint that forced the separated `from`/`to` field design in `anchor-receipt.schema.v1.json`; if XPRNetwork's contract ever relaxes the check, the schema remains shape-compatible.

3. **DAG combination order** — spec §4 fixes `SHA-256( raw(identity_root) || raw(cycles_root) )`, NOT the reverse. An auditor implementing the verifier in another language should confirm their tooling honours this ordering. Inverting the order produces a different (and wrong) `dag_root_hash`; the test vector `v05-full-dag` will catch this.

4. **Empty-branch sentinel** — spec §5 chooses `SHA-256("") = e3b0c44…b855` as the sentinel for a branch with zero leaves. This is conventional but not the only possible choice; an auditor MAY register that they confirmed this convention is used consistently (= test vector `v04-empty-branch` covers it).

5. **Permission narrowness** — `anchor-receipt.json.anchor.inscribe_action.permission` is fixed to `{ actor: "freedomyield", permission: "anchor" }`. An auditor verifying a live inscription should confirm that the on-chain action was actually signed by this narrow permission and not by `freedomyield@active` or `freedomyield@owner`. If the actual on-chain signer is broader than the receipt declares, that is a finding.

6. **Schema additive policy** — both `identity.schema.v1.json` and `cycle-history.schema.v1.json` were extended additively. An auditor MAY confirm that no field was removed, no `required` list was extended, no type/pattern was narrowed, and no `const` value was changed. The 2026-06-21 changelog entry in `docs/IDENTITY_SCHEMA_CHANGELOG.md` makes this claim explicitly.

## Out of scope for this audit handoff

- The off-chain ed25519 signing key generation, holding, and rotation runbook (= `docs/OPERATOR_IDENTITY_SETUP.md`).
- The on-chain `freedomyield@anchor` permission deployment and key custody (= C3 deliverable, separate handoff at IC-2 deadline 2026-06-30).
- The integration of the new schemas into `scripts/operator-local/gen-identity.sh` and the new `scripts/post-anchor-event.sh` (= C1 deliverable, gated on C1 role assignment per coord-log judgment #4).
- The metal-watch-validators cron hook (= C1 deliverable).
- Any validator-host or web-host operational state — the C2 work touches only the schema / spec / vector artifacts and the docs that describe them.

## Document control

Author: C2 (= `phase-alpha-schema` branch session)
Branch: `phase-alpha-schema` of `github.com/freedomyield/metal.freedom-yield.com`
Commits relevant to this handoff: `1ee1f99`, `76ebef2`, `f833453`, `bf6057e`, and the test-vector commit immediately following this document. `git log phase-alpha-schema --oneline -- docs/MERKLE_DAG_SPEC.md docs/IDENTITY_VERIFICATION.md docs/IDENTITY_SCHEMA_CHANGELOG.md docs/PHASE_ALPHA_AUDIT_HANDOFF.md public/api/ tests/identity-verification-vectors/` enumerates the full set.

Out-of-tree references that the auditor MAY consult for cross-validation:

- `XPRNetwork/proton.contracts/contracts/eosio.token/src/eosio.token.cpp` line 99 (BLOCK-1)
- `MetalBlockchain/metalgo` `vms/components/avax/base_tx.go::VerifyMemoFieldLength` (= why the prior P-Chain memo design was abandoned; see `IDENTITY_SCHEMA_CHANGELOG.md` 2026-06-20 entry)
- `truthmark.io/scrapers/xpr/merkle.py::compute_merkle_root_from_hashes` (= sibling-project Merkle implementation, structurally equivalent)
