# `freedomyield::anchor` — Phase β smart-contract specification draft

> **Status**: design draft for Phase β. **NOT deployed in Phase α.**
> The Phase α anchor uses `eosio.token::transfer` with a memo of the
> form `fyid1:<dag_root_hash>` and does not require a contract. This
> document specifies the Phase β replacement: a custom contract on
> `freedomyield` (the existing XPR account) exposing an `inscribe`
> action backed by anti-replay-checked tables.
>
> **Scope**: C3 T-4 deliverable, the IC-3 handoff to C2 (anchor-receipt
> schema field alignment, per
> `project_phase_alpha_coordination_log.md`). C2's
> `/api/anchor-receipt.schema.v1.json` declares an `anchor.method`
> discriminator with the value `phase_beta_sc_inscribe`; this document
> is the source of truth for what that discriminator means.
>
> **Authority limits**: this document is a repo-internal design draft.
> Authoritative semantics on chain are set by the actual deployed
> contract code (= Phase β implementation, separate work). The XPR
> Network consensus rules remain authoritative for transaction validity.

---

## 1. Purpose

`freedomyield::anchor` (= the future contract code deployed at the
`freedomyield` XPR account) replaces the Phase α `eosio.token::transfer`
memo anchor with a typed, queryable, anti-replay-checked alternative.

Three improvements over Phase α:

1. **Typed payload**: action arguments are structured (`cycle_id`,
   `event_type`, `root_hash`, `prev_root`, `leaf_hash`, `payload`)
   instead of a free-form 64-hex string in a memo.
2. **Anti-replay**: a `prev_root` linked-list invariant ensures each
   inscription references the previous one; replay or fork attempts
   are rejected at contract level.
3. **Queryable**: three tables (`cycles`, `roots`, `leaves`) let an
   evaluator iterate inscriptions without parsing transaction memos.

Phase β does NOT remove Phase α inscriptions from history. The
Phase α memo inscriptions remain on chain and form the historical
prefix; Phase β tables are populated forward from the first
post-Phase-β cycle (or, optionally, backfilled by the operator from
the Phase α memo record).

## 2. Action signature

```cpp
ACTION inscribe(
    uint32_t      cycle_id,        // P-Chain cycle number (= validator period)
    name          event_type,      // enum: "cyclestart" | "cycleend" | "idrotate"
    checksum256   root_hash,       // dag_root_hash for this inscription
    checksum256   prev_root,       // = last accepted root_hash, OR zero for genesis
    checksum256   leaf_hash,       // the specific leaf being asserted in this event
    string        payload          // optional JSON metadata; MAY be empty string
);
```

### 2.1 Field types

| Field | Antelope type | JSON encoding | Notes |
| --- | --- | --- | --- |
| `cycle_id` | `uint32_t` | integer (≥ 1) | P-Chain cycle number; cycle 1 = `1`, cycle 2 = `2`, … |
| `event_type` | `name` | string, EOSIO name format `[a-z1-5.]{1,12}` | One of three: `"cyclestart"`, `"cycleend"`, `"idrotate"`. Constrained by `check()` in the action body. Antelope `name` packs into 64 bits, so the string-form encoding above is exactly what consumers see in tx history. |
| `root_hash` | `checksum256` | 64-hex string | dag_root_hash per `docs/MERKLE_DAG_SPEC.md`. SHA-256 hash. |
| `prev_root` | `checksum256` | 64-hex string | The most recently accepted `root_hash`, fetched from the `roots` table at inscription time. For the very first Phase β inscription (genesis), the operator passes 64 zeros (`"00...0"`); the contract enforces this via the genesis check (see §4). |
| `leaf_hash` | `checksum256` | 64-hex string | The specific leaf being asserted in this event. For a `cyclestart` event, this is the cycle-start leaf hash from the cycles branch of the DAG. For an `idrotate` event, this is the identity-history leaf hash. The contract does NOT validate this hash against the root (= off-chain verifiers do so). |
| `payload` | `string` | string, UTF-8, ≤ 256 bytes (= contract-enforced; see §3) | Optional structured metadata (JSON-encoded), e.g. `{"cycle_n":3,"start_iso":"2026-07-04T04:00:00Z"}`. MAY be empty (`""`). |

### 2.2 Authorization

The action requires `require_auth(get_self())` (= the contract account
itself), which is `freedomyield`. Combined with the Phase α / Phase β
permission setup at `docs/OPERATOR_IDENTITY_SETUP.md` § A6-A7, the
chain-side rule chain is:

- `freedomyield::inscribe` requires `freedomyield@active` by default.
- `linkauth(freedomyield, anchor, freedomyield, inscribe)` (= Phase β
  follow-up to the Phase α `linkauth eosio.token transfer anchor`)
  narrows the requirement to `freedomyield@anchor`.
- `freedomyield@anchor` is held by the validator-host-stored K1 key
  (see `docs/OPERATOR_IDENTITY_SETUP.md` § A4, T-2 deploy doc).

A leaked `anchor` key can therefore only call `inscribe` and the
existing Phase α `eosio.token::transfer`; it cannot deploy contracts,
modify permissions, or move XPR balance through other actions.

## 3. Tables

Three tables, all scoped by `get_self()` (= `freedomyield`).

### 3.1 `cycles`

Per-inscription row. Append-only via the `inscribe` action; never
modified or erased.

```cpp
TABLE cycles {
    uint64_t      id;                    // primary, monotone, contract-assigned
    uint32_t      cycle_id;              // input field
    name          event_type;            // input field
    checksum256   root_hash;             // input field
    checksum256   prev_root;             // input field
    checksum256   leaf_hash;             // input field
    string        payload;               // input field
    time_point    block_time;            // = current_time_point() at inscription
    uint64_t      block_num;             // = tapos block num at inscription

    uint64_t primary_key() const { return id; }
    uint64_t by_cycle()    const { return static_cast<uint64_t>(cycle_id); }
    uint64_t by_event()    const { return event_type.value; }
    checksum256 by_root()  const { return root_hash; }
};
typedef multi_index<"cycles"_n, cycles,
    indexed_by<"bycycle"_n,  const_mem_fun<cycles, uint64_t,  &cycles::by_cycle>>,
    indexed_by<"byevent"_n,  const_mem_fun<cycles, uint64_t,  &cycles::by_event>>,
    indexed_by<"byroot"_n,   const_mem_fun<cycles, checksum256, &cycles::by_root>>
> cycles_table;
```

### 3.2 `roots`

Index of accepted root hashes. Used both for anti-replay (prev_root
lookup) and for fast "is this root inscribed" queries.

```cpp
TABLE roots {
    checksum256   root_hash;             // primary
    uint64_t      cycles_id;             // = cycles.id of the inscription that established this root
    time_point    accepted_at;           // = current_time_point() at inscription

    checksum256 primary_key() const { return root_hash; }
};
typedef multi_index<"roots"_n, roots> roots_table;
```

Note: Antelope `multi_index` `primary_key` is canonically `uint64_t`.
For `checksum256` primary, the contract uses a singleton row pattern
keyed by `id` with a `byhash` secondary; or stores the root_hash in a
`uint64_t` derived from the first 8 bytes (collision-checked). The
draft above is conceptual; the implementing developer chooses the
concrete representation. The **invariant** is: a row exists iff that
root_hash was accepted by `inscribe`.

### 3.3 `leaves`

Index of accepted leaf hashes for fast lookup of "which inscription
asserted this leaf".

```cpp
TABLE leaves {
    uint64_t      id;                    // primary, monotone
    checksum256   leaf_hash;             // input field of inscribe
    checksum256   belongs_to_root;       // = the root_hash that committed to this leaf
    uint32_t      cycle_id;
    name          event_type;

    uint64_t primary_key() const { return id; }
    checksum256 by_leaf()  const { return leaf_hash; }
    checksum256 by_root()  const { return belongs_to_root; }
};
```

## 4. Invariants enforced by the contract

The `inscribe` action body enforces the following checks; any failure
returns an assertion error and the transaction is rejected:

1. **Authorization**: `require_auth(get_self())` succeeds (= signer
   holds `freedomyield@active` or, via linkauth, `freedomyield@anchor`).
2. **Event type allowlist**: `event_type` ∈ `{"cyclestart"_n,
   "cycleend"_n, "idrotate"_n}`; otherwise assert.
3. **Cycle monotonicity** (event-type-conditional):
   - For `cyclestart`: `cycle_id` must equal `(last_cyclestart_cycle_id + 1)`,
     or `1` for the genesis cyclestart. Allows exactly one start per cycle.
   - For `cycleend`: `cycle_id` must equal `last_cyclestart_cycle_id` AND
     no `cycleend` for that `cycle_id` exists yet. Allows exactly one end
     per started cycle.
   - For `idrotate`: `cycle_id` may equal any past or current
     `cyclestart`'s `cycle_id`. No monotonicity check (rotations may
     occur mid-cycle).
4. **Root anti-replay**: `roots[root_hash]` must NOT already exist.
   Each `root_hash` is accepted at most once globally.
5. **prev_root linkage**:
   - If this is the very first `inscribe` action (= `cycles` table is
     empty), `prev_root` must equal 64 zero bytes
     (`checksum256{0}`); this is the genesis check.
   - Otherwise, `prev_root` must equal the `root_hash` of the most
     recently accepted `cycles` row (= the highest `cycles.id`).
6. **Payload size**: `payload.size() <= 256` (= keep WASM cost bounded;
   matches the `eosio.token::transfer` memo limit for symmetry with
   Phase α).
7. **Self-consistency**: after the row is inserted, the contract
   inserts the corresponding `roots` and `leaves` rows in the same
   transaction; partial state is not possible.

## 5. Anti-replay rationale

The combination of invariants 4 and 5 makes the cycles table an
append-only linked list:

```
cycles[0] = (id=0, root_hash=R1, prev_root=ZERO)   ← genesis
cycles[1] = (id=1, root_hash=R2, prev_root=R1)
cycles[2] = (id=2, root_hash=R3, prev_root=R2)
…
```

Any attempt to:

- Re-submit the same `root_hash` (e.g. replay attack): rejected by
  invariant 4 (`roots[root_hash]` exists).
- Fork the chain (= submit a new inscription whose `prev_root` points
  to an earlier-than-tail root): rejected by invariant 5 (`prev_root`
  must equal the tail).
- Submit out-of-order cycles: rejected by invariant 3 (cycle
  monotonicity).

An off-chain verifier can confirm the chain integrity by:

1. Iterating `cycles` by `id` from 0 upward.
2. Asserting `cycles[i].prev_root == cycles[i-1].root_hash` for all `i > 0`.
3. Asserting `cycles[0].prev_root == ZERO`.
4. Asserting each `root_hash` matches the DAG construction in
   `docs/MERKLE_DAG_SPEC.md` (= off-chain Merkle re-compute from
   `cycles-history.json`).

## 6. Action invocation example (Phase β)

```sh
proton action freedomyield inscribe '{
  "cycle_id": 3,
  "event_type": "cyclestart",
  "root_hash":  "<64-hex dag_root_hash for cycle 3 start>",
  "prev_root":  "<64-hex dag_root_hash from previous inscribe, or 64 zeros for genesis>",
  "leaf_hash":  "<64-hex leaf hash of the cycle-3-start leaf in the cycles branch>",
  "payload":    "{\"cycle_n\":3,\"start_iso\":\"2026-07-04T04:00:00Z\",\"node_id\":\"NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v\"}"
}' freedomyield@anchor
```

Returns: transaction id (64-hex). The transaction trace contains the
contract's `inscribe` action with the structured payload above, and
the resulting `cycles`, `roots`, `leaves` table rows are visible via
`proton table get` or any Hyperion / XPR explorer.

## 7. Off-chain verifier path (= what consumers do)

```
1. Read /api/anchor-receipt.json
2. Extract: anchor.method == "phase_beta_sc_inscribe"
            anchor.tx_id
            anchor.dag_root_hash (= root_hash inscribed)
3. Query proton chain: get_transaction(anchor.tx_id)
   → action.account == "freedomyield"
   → action.name == "inscribe"
   → action.data.root_hash == anchor.dag_root_hash
   → action.data.payload (= optional metadata)
4. Optionally: get_table_rows(scope="freedomyield", code="freedomyield",
   table="cycles", lower_bound=anchor.cycles_id, limit=1) and assert
   prev_root linkage backward to genesis.
5. Confirm /api/cycles-history.json's dag_root_hash matches
   anchor.dag_root_hash.
6. Recompute dag_root_hash from cycles-history.json + identity-history.jsonl
   per MERKLE_DAG_SPEC.md; assert equality.
```

## 8. ABI fragment (= alignment with C2 anchor-receipt schema)

```json
{
  "version": "eosio::abi/1.2",
  "types": [],
  "structs": [
    {
      "name": "inscribe",
      "base": "",
      "fields": [
        {"name": "cycle_id",   "type": "uint32"},
        {"name": "event_type", "type": "name"},
        {"name": "root_hash",  "type": "checksum256"},
        {"name": "prev_root",  "type": "checksum256"},
        {"name": "leaf_hash",  "type": "checksum256"},
        {"name": "payload",    "type": "string"}
      ]
    }
  ],
  "actions": [
    {"name": "inscribe", "type": "inscribe", "ricardian_contract": ""}
  ],
  "tables": [
    {"name": "cycles", "type": "cycles_row", "index_type": "i64",
     "key_names": ["id"], "key_types": ["uint64"]},
    {"name": "roots",  "type": "roots_row",  "index_type": "i256",
     "key_names": ["root_hash"], "key_types": ["checksum256"]},
    {"name": "leaves", "type": "leaves_row", "index_type": "i64",
     "key_names": ["id"], "key_types": ["uint64"]}
  ]
}
```

C2's `/api/anchor-receipt.schema.v1.json`
`anchor.inscribe_action` block should mirror the `inscribe` struct
above when `anchor.method == "phase_beta_sc_inscribe"`. Specifically:

- `anchor.inscribe_action.account` (= "freedomyield")
- `anchor.inscribe_action.name` (= "inscribe")
- `anchor.inscribe_action.data` (= the six-field struct above)
- `anchor.inscribe_action.authorization[0].actor` (= "freedomyield")
- `anchor.inscribe_action.authorization[0].permission` (= "anchor")

(IC-3 deliverable: C3 confirms this struct; C2 finalizes the schema
`inscribe_action.data` properties to match.)

## 9. Open questions / TBD (= Phase β implementation deferrals)

| ID | Question | Owner |
| --- | --- | --- |
| Q1 | Should the contract emit an inline `eosio.token::transfer` of `0.0001 XPR` to the sink as a paired "ledger receipt", or is the `inscribe` action sufficient on its own? | operator + C3 in Phase β |
| Q2 | RAM cost of three tables — is `freedomyield` account RAM sufficient, or should the operator pre-purchase additional RAM? | C3 measurement during testnet rehearsal |
| Q3 | Should `payload` be a typed struct (e.g. `inscribe_payload` with named fields) instead of a free-form string, to enforce shape at consensus level? | trade-off: rigidity vs forward-compatibility |
| Q4 | Should `cycleend` carry a final uptime / delegator-count field that `cyclestart` does not? Or should `payload` carry that and the action remain symmetric? | C2 schema review |
| Q5 | Should the contract expose a read-only `getlast` action for verifiers, or rely solely on table reads? | low priority; tables are queryable as-is |

## 10. What this document does NOT specify

- The actual contract source code (= C++ for Antelope WASM). That is
  Phase β implementation work, separate authorization.
- Deployment procedure for the contract (= `setcode` + `setabi`
  actions). That is Phase β operational work.
- Migration of Phase α memo inscriptions into the Phase β tables.
  That is optional Phase β backfill work and is not required for
  forward-only operation.
- Any modification to Phase α (`eosio.token::transfer` memo) anchor
  procedure. Phase α and Phase β coexist; Phase α inscriptions
  before Phase β activation remain authoritative for their cycles.

## 11. Related

- `project_merkle_dag_identity_anchor_design` memory — anchor model
  source-of-truth (Phase α + Phase β breakdown).
- `project_phase_alpha_3_claude_delegation_brief` memory — C3 T-4
  scope and IC-3 handoff schedule.
- `project_phase_alpha_coordination_log` memory — current cross-Claude
  state, including BLOCK-1 (self-transfer禁止) awareness that informs
  Phase β `eosio.token::transfer`-independence.
- `docs/MERKLE_DAG_SPEC.md` (C2 deliverable) — canonical DAG
  construction; `root_hash` here is the `dag_root_hash` defined there.
- `docs/OPERATOR_IDENTITY_SETUP.md` § A1-A10 (C3 T-1) — `freedomyield`
  permission setup whose `anchor` permission is the signer for this
  action.
- `/api/anchor-receipt.schema.v1.json` (C2 deliverable) — public
  Phase α / β receipt schema whose `anchor.method ==
  "phase_beta_sc_inscribe"` discriminator references this spec.
