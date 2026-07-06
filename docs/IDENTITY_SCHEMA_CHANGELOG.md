# identity.schema.v1.json — design changelog

This document records the design history of the operator identity
manifest schema (`/api/identity.schema.v1.json`). Within this
repository it is the design-history reference for changes within
schema v1 and the rationale for any future major version bump. It is
not a chain-anchored attestation and not equivalent to an external
append-only log: see the retention note below.

## 2026-07-06 — Retire cycles-history.json + cycles_history_url (design-stocktake #1: single-DAG completion)

### Summary

The 2-branch DAG snapshot `/api/cycles-history.json` and identity.json's
`cycles_history_url` pointer are removed. `gen-identity.sh` no longer computes
the 2-branch `dag_root_hash` nor writes cycles-history.json; it retains only the
`identity-history.jsonl` bootstrap and the `FY_EXPECT_CYCLE` ordering guard.
`gen-anchor-source.sh` no longer hashes cycles-history.json into
`artifacts_branch`, and `/api/cycles-history.schema.v1.json` + its example are
retired.

### Why

This completes the collapse begun in the entry below (retiring identity.json's
own `dag_root_hash`). cycles-history.json was the *published snapshot* of that
same retired 2-branch root; leaving it in place kept two competing DAG
namespaces alive across the generation pipeline and every doc/example pointing
at it. The single authoritative root is now
`anchor-source.json.dag_root_computed` (3-branch over identity / observations /
artifacts, memo `fya<S>c<N>:`), surfaced to verifiers via `anchor-receipt.json`.
Verifier cross-references that pointed at cycles-history.json now point at
anchor-source.json.

### Compatibility

No live consumer read *data* from cycles-history.json — the references were a
published-artifact hash entry (`gen-anchor-source.sh` `API_FILES`), a
cross-reference URL (`gen-evidence.sh`), and operator git-add / doc
instructions, all repointed or removed. Historical Phase-α snapshots and
on-chain receipts that recorded cycles-history.json remain valid as dated
records.

## 2026-07-06 — Retire `dag_root_hash` from identity.json (design-stocktake #1: DAG-root collapse)

### Summary

`identity.json` stops advertising its own `dag_root_hash`. The field is
retained in the schema as **optional / RETIRED** (for backward-compatibility
with earlier Phase-α snapshots that still carry it), and `gen-identity.sh` no
longer emits it.

### Why

The pre-v2 model treated identity.json's 2-branch root
`SHA-256(raw(identity_branch_root) || raw(cycles_branch_root))` as the value
anchored on-chain via memo `fyid1:<dag_root_hash>`. After the v2 migration this
became **false**: the value actually inscribed on Metal A-chain is
`anchor-receipt.json.dag_root_hash` (= `anchor-source.json.dag_root_computed`,
a 3-branch DAG over identity/observations/artifacts, memo `fya<S>c<N>:`).
identity.json was therefore publishing a **second root that appears nowhere
on-chain**, breaking the anchor's one job — a verifier reading identity.json's
`dag_root_hash` and searching for it on-chain would never find it. This is
trouble #1/#3 of the 2026-07-04 design stock-take.

### What changed

- `scripts/operator-local/gen-identity.sh`: removed the `dag_root_hash` field
  from the identity.json object; removed the misleading `anchor memo:
  fyid1:<dag>` console line (gen-identity does not produce the v2 memo).
  The 2-branch root is still computed and written to
  `cycles-history.json.dag_root_hash` (an un-advertised cycle summary).
- `public/api/identity.schema.v1.json`: `dag_root_hash` description rewritten to
  RETIRED; `artifact_root` and `cycles_history_url` descriptions corrected to
  stop asserting the 2-branch root is the on-chain value.
- `public/api/identity.example.json`: `dag_root_hash` removed; `_comment` updated.
- `scripts/operator-local/test-gen-identity.sh`: asserts `dag_root_hash` is
  **absent** from identity.json and that cycles-history.json still carries a
  64-hex 2-branch summary.

### Verification path (unchanged intent, now unambiguous)

A verifier reaches the on-chain root via `anchor_receipt_url` /
`audit.anchor_receipt` → `anchor-receipt.json.dag_root_hash` → the A-chain tx.
No competing root is advertised on identity.json.

### Transition note

The live signed `identity.json` still carries the old field until the operator
next runs `gen-identity.sh` (it cannot be edited without re-signing). Schema
`additionalProperties: true` + the retained optional property keep both the
current (field-present) and future (field-absent) snapshots valid. Removing the
old anchored value from identity.json's bytes will shift the next
`dag_root_computed` by one (identity.json is a hashed leaf of the artifacts
branch) — a one-time, self-consistent change, to land before the cycle-4 anchor.

## 2026-06-22 — Phase 5 pre-execution doc + .gitignore fixes (audit GAP-1 + GAP-3)

### Summary

Three small pre-Phase-5 fixes, triggered by an independent audit review
of the Phase 5 execution plan:

1. **GAP-1 (medium)**: `scripts/operator-local/gen-identity.sh` post-run
   "Next steps" message (lines 594-595) was inconsistent with the
   actual five files the script produces. The next-steps text listed
   only three (`identity.json`, `identity.json.sig`,
   `operator-identity.pub`) and silently omitted
   `cycles-history.json` + `identity-history.jsonl`. If an operator
   followed the on-screen guidance verbatim, the omitted two files
   would not be staged, and Phase α `post-anchor-event.sh` would 404
   on its `cycles-history.json` fetch. The HOLD reminder block at
   lines 599-602 had the same gap. Both blocks updated to list five
   files explicitly.

2. **GAP-1 (medium, cont.)**: `docs/PHASE5_CHECKLIST.md` Section E4
   carried the same 3-file `git add` command. Updated to five files
   with an inline comment explaining that the extra two are required
   by Phase α (deploy ownership matrix + verifier branch-root
   recompute).

3. **GAP-3 (medium)**: `.gitignore` claimed (via the Phase 5 audit
   report §4.5) to protect the operator identity ed25519 private key
   from accidental commit "via extension blocks", but the actual
   `.gitignore` patterns are `*.key` / `*.pem` / etc. — the operator
   identity file
   (`~/.ssh/freedom-yield-operator-identity`, no extension) would not
   match. The real protection is path-based (key lives outside the
   repo at `~/.ssh/`). Added explicit `.gitignore` patterns for
   `freedom-yield-operator-identity` and
   `freedom-yield-operator-identity.pub` as a defense-in-depth safety
   net against operator copy-paste error. The `.pub` published to the
   web is renamed to `public/.well-known/operator-identity.pub` during
   copy, so it does not match the newly-added patterns.

### What changed

| File | Change |
| --- | --- |
| `.gitignore` | added explicit `freedom-yield-operator-identity` + `.pub` patterns |
| `scripts/operator-local/gen-identity.sh` | Next-steps message (line 594) + HOLD reminder (line 599) updated to list 5 files |
| `docs/PHASE5_CHECKLIST.md` | Section E4 `git add` extended to 5 files with rationale comment |

### What did NOT change

- No schema constraint changed
- No script behaviour changed (= the 5-file output already happened; only the on-screen guidance text changed)
- No on-chain action taken
- No operator key material involved

### Migration impact

None. These are pre-Phase-5 doc + .gitignore hardening; no live
artifact references any of the changed text.

## 2026-06-22 — Production account names confirmed: operator `metalfreedom` + sink `fyhistory`

### Summary

Two related renames were applied in one revision:

1. **Operator XPR account**: in-repo references renamed from
   `freedomyield` to `metalfreedom`. The operator decided the
   production account name during the Phase α mainnet rollout
   (2026-06-22); the previous identifier `freedomyield` was held by
   an unrelated project.
2. **Sink account name** (Phase α `eosio.token::transfer` `to`):
   placeholder `fyldsink` reconciled to the confirmed mainnet sink
   `fyhistory` (testnet rehearsal sink remains `fyhistorytst`).
   Operator judgment #1 (sink name choice) is now resolved; the
   `_comment` in `anchor-receipt.example.json` no longer describes
   the sink as "candidate under operator judgment."

**No schema constraint changed** — `anchor-receipt.schema.v1.json`
`actor` / `from` / `to` fields had already been generalized to the
XPR account name pattern (`^[a-z1-5.]{1,12}$`) by the audit-C/F-E2
revision, so all forms (old `freedomyield`/`fyldsink`, new
`metalfreedom`/`fyhistory`) validate. This entry is recorded for
traceability only.

### What changed

| Surface | Change |
| --- | --- |
| `public/api/anchor-receipt.schema.v1.json` | descriptions updated (no constraint change) |
| `public/api/anchor-receipt.example.json` | example `from`/`actor` values + `to` value + `_comment` rewritten to drop "candidate" language |
| `public/api/anchor-receipt.phase-beta.example.json` | example `account`/`actor` values |
| `public/selection-evidence/index.html` (en + ja) | permission reference text |
| `scripts/sign-anchor-event.sh` | header comments only (code already reads xpr-account config) |
| `scripts/operator-local/contract/freedomyield-anchor.spec.md` | **file renamed** → `metalfreedom-anchor.spec.md`; Phase β contract namespace `freedomyield::inscribe` → `metalfreedom::inscribe` |
| `tests/post-anchor-event/fixtures/stub-signer.sh` | test fixture `actor` + `to` values |
| `tests/sign-anchor-event/test-xpr-account-config.sh` | test case names + assertion strings + sink config |
| `tests/sign-anchor-event/test-block-time-failclosed.sh` | comment + sink config |
| `tests/sign-anchor-event/test-quantity-config.sh` | sink config |
| `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md` | narrative + example commands |
| `docs/PHASE_ALPHA_AUDIT_HANDOFF.md` | narrative (sink: "pending" → "confirmed") |
| `docs/MERKLE_DAG_SPEC.md` | narrative |
| `docs/IDENTITY_VERIFICATION.md` | narrative + verification table |
| `docs/OPERATOR_IDENTITY_SETUP.md` | narrative + example commands + account-tree diagram |

### What did NOT change

- Brand name `Freedom Yield` (UI / copyright lines)
- Domain `freedom-yield.com` / `metal.freedom-yield.com`
- GitHub org `freedomyield` and repository path
  `freedomyield/metal.freedom-yield.com`
- Schema constraints (pattern `^[a-z1-5.]{1,12}$` accepted both
  `freedomyield` and `metalfreedom`)
- Schema `$id`, `schema_version`, `x-stability`,
  `x-baseline-revision`
- `anchor.inscribe_action.permission.permission` const value
  `"anchor"` (the permission name on the account remains `anchor`)

### Migration impact for evaluators

None at the data layer. Any anchor receipt or identity manifest
parser that pinned `actor == "freedomyield"` or `to == "fyldsink"`
(off-schema) needs to update its expected values to `metalfreedom`
and `fyhistory` respectively. The schema-conformant path (pattern
check) was unaffected.

### Rationale

XPR account names on Metal A-chain mainnet are operator choices and
are publicly visible on every anchor inscription. Both names are now
the production reality (operator-controlled `metalfreedom` and
receive-only sink `fyhistory`, both created 2026-06-22). The in-repo
design documents are aligned to reflect that production reality;
the placeholder language ("candidate", "pending") that was
appropriate during pre-rollout design is now retired.

## 2026-06-21 — Phase α additive: Merkle DAG anchor fields

### Summary

Three additive properties were added to `/api/identity.schema.v1.json`,
and three new sibling schemas were published, to support the Phase α
A-chain Merkle DAG anchor specified in `docs/MERKLE_DAG_SPEC.md`. No
fields were removed; no `required` list was changed; the `$id`,
`schema_version` `const`, `x-stability`, and `x-baseline-revision`
values are unchanged. The revision is **additive within v1**.

### What changed in /api/identity.schema.v1.json

| Property | Type | Status |
| --- | --- | --- |
| `dag_root_hash` | 64-hex pattern | added (additive, optional) |
| `cycles_history_url` | URI | added (additive, optional) |
| `anchor_receipt_url` | URI | added (additive, optional) |

The `artifact_root` field's description was expanded with a note
clarifying that `artifact_root` and `dag_root_hash` coexist within
v1 and commit to different evidentiary corpora (current-set vs
cumulative-DAG). No type, pattern, or semantics of `artifact_root`
itself was changed.

`x-issued-at` was advanced to `2026-06-21T00:00:00Z`. The
`x-baseline-revision` value remained `"2026-06-20-pre-production-correction"`
because additive field additions do not introduce a new baseline; the
2026-06-21 revision continues to honor the additive-only stability
contract established by the prior baseline.

### What changed in /api/cycle-history.schema.v1.json

Two additive optional properties were added:

| Property | Type | Status |
| --- | --- | --- |
| `signed_by_key_seq` | integer ≥ 1 | added (additive, optional) |
| `signed_by_pubkey_fingerprint` | `^SHA256:[A-Za-z0-9+/=]+$` | added (additive, optional) |

These fields bind each cycle leaf to the operator-identity key
authoritative at the cycle's `start_iso`. The schema `description`
was extended to reference `docs/MERKLE_DAG_SPEC.md §2.2`.
`x-issued-at` was advanced to `2026-06-21T00:00:00Z`. The
`required` list was not changed; operators SHOULD include these
fields for `cycle_n >= 3` (= first cycle after Phase α activation),
but the schema tolerates their absence on earlier cycle leaves.

### New sibling schemas published

| Schema | Purpose |
| --- | --- |
| `/api/anchor-receipt.schema.v1.json` | A-chain inscription receipt. Republishes the most recent A-chain transaction anchoring a `dag_root_hash`, including `tx_id`, `block_num`, `block_time`, `explorer_url`, and the structured `inscribe_action` (account / name / from / to / quantity / memo / permission). Discriminator `anchor.method` distinguishes Phase α (`phase_alpha_token_transfer`) from Phase β (`phase_beta_sc_inscribe`). || `/api/identity-history.schema.v1.json` | Per-line schema for `/api/identity-history.jsonl`. Each line represents one operator-identity ed25519 key entry, keyed by monotone `key_seq`. Append-only within v1; serves as the leaf source for the identity branch of the DAG. |

All three new schemas declare `x-stability: "additive-only-within-v1"`,
`x-issued-at: "2026-06-21T00:00:00Z"`, and
`x-baseline-revision: "2026-06-21-phase-alpha-initial"`.

### Anchor mechanism note (BLOCK-1 awareness)

The Phase α `anchor.inscribe_action.to` field is required to be
distinct from `from` because XPRNetwork's `eosio.token::transfer`
rejects self-transfer at the contract level
(`check( from != to, "cannot transfer to self" )`,
`eosio.token.cpp` line 99). The schema is shape-stable regardless of
which specific sink account the operator chooses; the schema's
`to` field is constrained only by the XPR account-name pattern
(`^[a-z1-5.]{1,12}$`). The example file uses a placeholder sink
name; the production receipt will substitute the operator-selected
sink account at first inscription.

### Why this is additive, not a v2 bump

- All new properties are optional; documents valid against the prior
  schema remain valid against this revision.
- No existing field's type, pattern, enum, or `const` was narrowed.
- `required` was not extended.
- The three sibling schemas are at new `$id` URLs; they do not affect
  the binding of `/api/identity.schema.v1.json`.

### IC-3 incorporation (anchor-receipt Phase β shape, same-day extension)

After the initial publication of `anchor-receipt.schema.v1.json`, the
IC-3 deliverable from the on-chain track (= `scripts/operator-local/contract/metalfreedom-anchor.spec.md`
§8 ABI fragment, lives on `phase-alpha-onchain`) landed. The
anchor-receipt schema was extended in-place (same baseline revision,
no x-issued-at change) with:

- New optional properties in `anchor.inscribe_action`:
  - `data` — six-field structured payload for Phase β
    (`cycle_id`, `event_type`, `root_hash`, `prev_root`,
    `leaf_hash`, `payload`), each constrained per the contract
    spec.
  - `authorization` — Antelope action.authorization array of
    `{actor, permission}` pairs (Phase β uses
    `authorization[0] = {actor: 'metalfreedom', permission: 'anchor'}`).
- Method-discriminated `if/then/else` blocks at the `anchor` object
  level that re-add the Phase α required list
  (`from`/`to`/`quantity`/`memo`/`permission`) when
  `method == "phase_alpha_token_transfer"` and add the Phase β
  required list (`data`/`authorization`) when
  `method == "phase_beta_sc_inscribe"`. The unconditional
  `inscribe_action.required` was relaxed from seven fields to two
  (`account`, `name`) so that the discriminator dispatch can apply
  the correct, non-overlapping requirements per method without a
  single document needing to satisfy both shapes.
- Existing Phase α documents continue to validate: the
  `phase_alpha_token_transfer` arm of the if/then/else re-imposes
  the same seven required fields the previous schema imposed
  unconditionally.
- Phase β documents now validate (= newly admissible), demonstrating
  the additive expansion.
- A new sibling example file `public/api/anchor-receipt.phase-beta.example.json`
  was added to document the Phase β shape concretely; the original
  `anchor-receipt.example.json` continues to demonstrate the
  Phase α shape.

Negative-test confirmation: a document with `method = phase_alpha_token_transfer`
but missing `from` is correctly rejected by the dispatched
requirement (verified at commit time).

### Related (this revision)

- `docs/MERKLE_DAG_SPEC.md` — canonical spec for the two-branch
  Merkle DAG, leaf canonical encoding, tree construction, and
  A-chain memo binding (`fyid1:<dag_root_hash>`).
- `scripts/operator-local/contract/metalfreedom-anchor.spec.md`
  (lives on `phase-alpha-onchain` branch as of 2026-06-21) —
  Phase β `metalfreedom::inscribe` action specification whose §8
  ABI fragment is the source for the `anchor.inscribe_action.data`
  structure in the IC-3 extension above.
- `project_merkle_dag_identity_anchor_design` memory — Phase α / β
  design memo (operator-side).
- `project_phase_alpha_coordination_log` memory — Phase α
  cross-Claude coordination state.

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
