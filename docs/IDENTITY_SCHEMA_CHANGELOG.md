# identity.schema.v1.json — design changelog

This document records the design history of the operator identity
manifest schema (`/api/identity.schema.v1.json`). Within this
repository it is the design-history reference for changes within
schema v1 and the rationale for any future major version bump. It is
not a chain-anchored attestation and not equivalent to an external
append-only log: see the retention note below.

## 2026-06-20 — schema v1 pre-production correction

### Summary

The `chain_anchor` block was removed from
`/api/identity.schema.v1.json` and `/api/identity.example.json`. The
identity v1 model is now an **operator-signed artifact snapshot
WITHOUT a P-Chain anchor**.

This revision is treated as a **pre-production correction**: the
runtime `/api/identity.json` was never published prior to this
revision, so the schema's content at the URL had not yet been bound
to any operator-tracked external consumer. The
`x-baseline-revision: "2026-06-20-pre-production-correction"`
metadata field on the schema marks this revision as the start point
for the `additive-only-within-v1` stability policy. Changes within v1
from this revision onward will be additive only.

The `x-baseline-revision` value is uniquely defined by this changelog
entry. Future revisions within v1 will, if they introduce a new
baseline, use distinct `x-baseline-revision` values mapped 1-to-1 to
their corresponding changelog entries.

### Why

The original v1 model was designed around a four-layer scheme whose
top layer was a `chain_anchor` populated from a P-Chain
`AddPermissionlessValidatorTx` memo at each renewal cycle. Read-only
verification of `MetalBlockchain/metalgo` source showed this is **not
possible on the current mainnet**:

- `vms/components/avax/base_tx.go` `VerifyMemoFieldLength` rejects
  any non-empty memo when Durango is active
  (`len(memo) != 0 -> ErrMemoTooLarge`).
- `vms/platformvm/txs/executor/staker_tx_verification.go`
  `verifyAddPermissionlessValidatorTx` applies this gate with the
  dynamic `isDurangoActive` flag.
- `upgrade/upgrade.go` sets Metal mainnet Durango activation to
  `2024-05-06 08:00:00 UTC` — already in effect.

Cycle 1 (committed 2026-05-19) and cycle 2 (committed 2026-06-04)
AddValidator transactions were submitted with empty memo fields as
required by the current protocol rules.

### What changed

| Surface | Change |
| --- | --- |
| `/api/identity.schema.v1.json` `chain_anchor` block (was at L148-162) | Removed. The block carried `chain`, `tx_type`, `tx_id`, `memo_prefix`, `explorer_url`. It was never listed in `required`. The top-level `additionalProperties: true` means a document still carrying `chain_anchor` continues to validate against the revised schema; the field is no longer documented as a declared property. |
| `/api/identity.schema.v1.json` `description` | Updated to describe the model as an operator-signed artifact snapshot without P-Chain anchor, to point at this changelog, and to note that the companion `/api/identity.example.json` is a synthetic schema example. |
| `/api/identity.schema.v1.json` `artifact_manifest.description` | "Merkle DAG hub" rephrased to "Merkle-rooted artifact manifest". The structure is a Merkle-rooted manifest, not a general Merkle DAG; the prior wording was inaccurate. |
| `/api/identity.schema.v1.json` `x-issued-at` | Updated to `2026-06-20T00:00:00Z`. |
| `/api/identity.schema.v1.json` `x-baseline-revision` | New metadata field set to `"2026-06-20-pre-production-correction"`. Marks the start point for the `additive-only-within-v1` policy. |
| `/api/identity.example.json` `chain_anchor` block | Removed. |
| `/api/identity.example.json` `_comment` | Rewritten to make explicit that the file is a synthetic schema example, not a production snapshot. All sha256, fingerprint, and timestamp values shown in the example are intentional placeholders. |
| `scripts/operator-local/gen-identity.sh` | `chain_anchor` JSON composition, `--argjson chain_anchor` invocation, the field on the output object, and the trailing display branch were removed. `CHAIN_ANCHOR_TX_ID` and `CHAIN_ANCHOR_EXPLORER` env vars are no longer documented or consumed. If either env is set, the script prints an ERROR line to stderr listing the retired variables and an `unset` hint, and exits non-zero before any output is produced. See "Retired env handling" below. |
| `scripts/operator-local/test-gen-identity.sh` | Assertions added: output identity.json must not contain `chain_anchor`; setting retired env must produce ERROR exit and no output file. Pre-commit schema validations were redirected from the live URL to the local revised schema. AJV compile + example validate + synthetic output validate are mandatory (pinned `ajv-cli@5.0.0` + `ajv-formats@3.0.1` via npx; pre-flight checked). |

### What did NOT change

- `$id` (still `https://metal.freedom-yield.com/api/identity.schema.v1.json`).
- `schema_version` (still `const: 1`).
- `required` field list (unchanged 13 entries; `chain_anchor` was never `required`).
- `additionalProperties: true` at the top level (unchanged).
- `artifact_manifest` and `artifact_root` field semantics. The Merkle
  root computation is unchanged: leaves are each entry.sha256,
  ordered alphabetically by key, odd counts duplicate the last leaf,
  parents are SHA-256 over raw-byte concatenation of children,
  hex-encoded at the root.
- All other identity manifest fields (operator key fingerprint,
  verification block, iat / exp / revoked block, brand, network,
  node_id, generated_at).
- The `x-stability: "additive-only-within-v1"` value. The semantics
  are scoped to revisions on or after the
  `x-baseline-revision: "2026-06-20-pre-production-correction"` date
  marker.

### Pre-production correction framing

Prior to 2026-06-20 the `/api/identity.schema.v1.json` URL served
content that documented a `chain_anchor` block intended for a P-Chain
memo embed. That intent was incompatible with current protocol rules.
The runtime `/api/identity.json` was never published during that
pre-correction window. Within this repository, the prior content is
treated as a pre-production draft. This revision establishes the v1
initial production contract; the `additive-only-within-v1` policy
applies from the `x-baseline-revision` date forward.

The operator does not know of any integration pinned to the prior
shape and does not know of any production consumer. The schema URL
is publicly reachable, and an external automated reviewer may have
fetched it; whether any such reviewer pinned to the prior
`chain_anchor` block is not knowable from the operator side.

A previously produced document containing `chain_anchor` would still
validate against the revised schema because the top-level schema
permits additional properties (`additionalProperties: true` at the
top level). A consumer that pinned the **prior schema document
bytes** is holding a different historical schema document and should
use that pinned digest, or the corresponding repository commit, as
the authority for that historical interpretation. The schema URL
itself reflects the currently declared canonical shape.

### Why v1 was revised in place rather than bumping to v2

- The runtime `/api/identity.json` was never published; no
  consumer-side migration path was needed.
- `chain_anchor` was not in `required`. Removing an optional,
  unused field is not a validation-breaking change for any document
  ever produced under v1.
- A new schema URL (`v2.json`) would have implied a meaningful
  semantic transition; this revision is a pre-production correction,
  not a new semantic. Bumping to v2 would also have required
  maintaining two schema endpoints with a deprecation timeline.

### Retired env handling

`scripts/operator-local/gen-identity.sh` previously consumed two
environment variables that controlled the `chain_anchor` block:
`CHAIN_ANCHOR_TX_ID` and `CHAIN_ANCHOR_EXPLORER`. Both are retired
as of this revision.

The script now prints an ERROR and exits non-zero (exit code 6)
before any output is produced if either retired variable is set in
the environment. This was chosen over a silent ignore or a stderr
warning because the script is intended for manual operator
execution; if a retired variable is set, the operator's mental model
still expects an anchored output, and producing a non-anchored
output without halting risks the operator publishing a manifest
under a misperceived shape. The ERROR message includes an
`unset CHAIN_ANCHOR_TX_ID CHAIN_ANCHOR_EXPLORER` hint so the
operator can clear the environment and re-run.

## Schema URL stability and immutability

The schema URL
`https://metal.freedom-yield.com/api/identity.schema.v1.json` is a
**stable discovery endpoint**. An automated reviewer can fetch this
URL to retrieve the currently declared canonical shape.

The URL is **not** an immutability guarantee. Content at this URL
may be revised within `schema_version: 1` (additive field
additions, description corrections, stability-metadata updates)
from the `x-baseline-revision` date forward. All such revisions are
recorded in this changelog.

A consumer that requires **immutable schema semantics** (for
example, a long-term audit baseline that needs to verify against
the exact schema document the operator declared at a known point in
time) SHOULD pin one or both of:

- the SHA-256 of the schema document bytes as fetched at a known
  time, and / or
- the specific repository commit SHA at
  `github.com/freedomyield/metal.freedom-yield.com` where the
  schema content was authored.

A consumer that only needs the currently declared canonical shape
MAY rely on the URL alone.

A future breaking change will use a new major-version schema URL.
Retention and deprecation policy for superseded schema versions
will be documented when such a version is introduced.

### Note on changelog retention

This changelog and the repository history are recorded in the
public Git repository and in each clone of it. Durability against
single-host loss improves with independent clones or mirrors.
Repository history is not an external timestamp service and is not
equivalent to an append-only public log: repository owners retain
the technical ability to rewrite or delete history. Consumers that
need a timestamped immutable record SHOULD combine the
repository-based design history with an external mechanism of
their own choosing.

## Future anchor model

If a chain anchor or external timestamp is introduced later, the
following constraints apply:

- The retired `chain_anchor` single-object field name will not be
  reintroduced.
- The future anchor will be a new versioned structure designed in
  its own audit cycle. Its concrete fields and shape are
  intentionally not fixed in advance of that audit.
- The future anchor design must not create a circular reference
  with the snapshot it anchors. The signed snapshot is content-
  addressed by its document SHA-256; an anchor that requires
  inserting its own reference back into the snapshot before signing
  is excluded by design.

Whether to introduce a chain anchor at all, and which mechanism to
use, is an open design question. Candidate mechanisms under
independent read-only review include but are not limited to:

- XPR Network transfer memo or a dedicated XPR contract action
- Metal C-Chain self-transaction calldata
- OpenTimestamps Bitcoin proof
- Sigstore Rekor transparency log entry
- Signed Git tag

None of these has been selected. Each mechanism has its own audit,
operational, and verification trade-offs that will be evaluated
before any introduction.

The v1 signed-snapshot model is independently verifiable without an
external anchor: an evaluator who fetches `/api/identity.json` and
its detached signature, plus the operator pubkey at
`/.well-known/operator-identity.pub`, can verify the snapshot via
`ssh-keygen -Y verify` against the operator-declared pubkey. The
snapshot does not provide an independently anchored existence-time
proof; whether to add one is an open extension under separate
review.

## Related

- `docs/IDENTITY_VERIFICATION.md` — verifier-side procedure.
- `docs/OPERATOR_IDENTITY_SETUP.md` — operator-side runbook.
- `docs/PHASE5_CHECKLIST.md` — Phase 5 (signed-manifest publish)
  execution checklist.
- Constitution §3.3 (key separation): the operator identity ed25519
  key is distinct from validator staking and BLS signing keys and
  is unaffected by this revision.
