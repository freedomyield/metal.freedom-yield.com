# Evidence manifest (`/api/evidence.json`)

A daily machine-readable summary of the validator's identity, current operational state, and the set of public artefacts a reviewer can audit. The manifest is the single JSON document a due-diligence tool can fetch to discover everything else.

## Status

Live. The runtime file is generated daily on the validator host by `scripts/gen-evidence.sh`, pushed to the web host via the forced-command wrapper, and served from `https://metal.freedom-yield.com/api/evidence.json`. The committed schema example at `public/api/evidence.example.json` is kept in sync with the live shape.

## Schema (`schema_version: 1`)

| field | type | notes |
|---|---|---|
| `_comment` | string | embedded human-readable note describing how the file is generated |
| `schema_version` | integer | bumped on any breaking change |
| `brand` | string | constant `"Freedom Yield"` |
| `network` | string | constant `"metal-mainnet"` |
| `node_id` | string | NodeID on Metal Blockchain primary network |
| `validator_status` | string | `"active"` / `"unknown"` — set from live `validator.json` |
| `self_stake_metal` | integer | snapshot from live `validator.json` |
| `delegation_fee_percent` | number | snapshot from live `validator.json` |
| `public_pages` | object | map of stable public-page slugs to their canonical URLs (see below) |
| `operator_commitments` | object | the same unilateral commitments listed at `/commitments/` |
| `in_preparation_artifacts` | object | map of slugs to artefacts that are not yet live but whose schema is published — see below |
| `explorer_url` | string | upstream explorer entry point |
| `generated_at` | ISO 8601 UTC | when the manifest was written |
| `validator_state_observed_at` | ISO 8601 UTC | when the underlying `validator.json` was last refreshed |
| `stale_input_warning` | boolean | true if the underlying validator state is older than the freshness threshold |

The `public_pages` object lists the discovery surface for an automated reviewer. Current keys:

- `status` (home)
- `journal`
- `incidents`
- `commitments`
- `risk_disclosure`
- `jurisdiction`
- `continuity`
- `network`
- `selection_evidence`
- `subnet_readiness`
- `reference_architecture`
- `pledge`
- `data_catalog`

A consumer should treat `public_pages` as the authoritative discovery list: any new public page added to the operator's surface will appear here in the same daily cadence.

## In-preparation artifacts

The `in_preparation_artifacts` object surfaces artefacts whose **schema is published** but whose **runtime URL is not yet live**. It exists so an automated reviewer can discover what is coming without having to read prose anywhere. Each entry carries:

- `planned_url` — where the live artefact will be served.
- `schema_url` — the live schema preview (always reachable today).
- `format_guide_url` — the docs companion explaining the schema and intended consumption.
- (where applicable) `planned_signature_url`, `planned_pubkey_url` — for artefacts that come with detached signatures.

Current entries:

- `identity_manifest` — the dedicated-ed25519-signed identity binding documented at `docs/IDENTITY_VERIFICATION.md`.
- `cycle_history_jsonl` — the cycle-by-cycle audit packet documented at `docs/CYCLE_HISTORY.md`.

When an in-preparation artefact goes live, its entry moves out of `in_preparation_artifacts` and (for page-like artefacts) into `public_pages`. The `_comment` field is updated to call out the change so a diffing consumer sees the migration explicitly.

## How it is generated

`scripts/gen-evidence.sh` runs on the validator host as a daily cron at 01:30 UTC. The script:

1. Reads `public/api/validator.json` (live validator state, refreshed every five minutes by `scripts/node-info.sh`).
2. Composes the manifest with `jq`, injecting current state into the static project config.
3. Marks `stale_input_warning: true` and sets `validator_status: "unknown"` if `validator.json`'s `observedAt` is more than the freshness threshold old. This protects evaluators from being misled by a stale state file.
4. Atomically writes the new manifest via a tmp file + `jq` validation + `mv` swap.
5. Pushes the resulting file to the web host through `scripts/push-to-web-host.sh evidence.json`, which uses the forced-command wrapper's allowlist.

The script is deterministic given the same inputs and idempotent — re-running it within the same minute produces byte-identical output unless `validator.json` changed.

## Consumption

A simple due-diligence sweep:

```sh
curl -s https://metal.freedom-yield.com/api/evidence.json | jq '{
  status: .validator_status,
  fee:    .delegation_fee_percent,
  fresh:  (.stale_input_warning | not),
  pages:  (.public_pages | keys | length)
}'
```

Walking the public-pages map:

```sh
curl -s https://metal.freedom-yield.com/api/evidence.json \
  | jq -r '.public_pages | to_entries[] | "\(.key)\t\(.value)"'
```

Freshness gate before consuming any other field:

```sh
curl -s https://metal.freedom-yield.com/api/evidence.json \
  | jq -e 'select(.stale_input_warning == false and .validator_status == "active")' \
  >/dev/null && echo "ok to consume" || echo "stale or inactive — defer"
```

## What this file is not

It is not an attestation of compliance, a regulatory disclosure, an exhaustive list of operational state, or a substitute for the on-chain record. The on-chain explorer at `https://explorer.metalblockchain.org/` remains authoritative for stake, validator identity, and any value-bearing claim. The manifest is a convenience layer for automated discovery; cross-check against the explorer for anything that matters.

It is also not a frozen artefact. The `public_pages` map and the `operator_commitments` block are intentionally expected to grow. A consumer pinning the exact key set today will need to relax that pin when the operator publishes a new artifact.

## Operational invariants

- Daily cadence. The manifest is the slowest-moving public JSON the validator emits.
- `schema_version` is pinned at `1`. Breaking changes increment it and are announced in the cycle journal.
- `stale_input_warning: true` is itself authoritative — a consumer should treat a stale manifest as informational only and not act on the fields that depend on validator state.
- Atomic writes: the file as served is always either the previous valid manifest or the new one, never a partial document.

## Related artifacts

- `/api/validator.json` — live validator state, source of stake / uptime / fee fields (refreshed every five minutes).
- `/api/cycle-history.jsonl` (in preparation) — append-only cycle audit packet documented at `docs/CYCLE_HISTORY.md`.
- `/api/identity.json` — signed operator identity manifest (= live since Phase 5, 2026-06-22) documented at `docs/IDENTITY_VERIFICATION.md`. Companion artifacts: `/api/identity.json.sig`, `/api/cycles-history.json`, `/api/identity-history.jsonl`, `/.well-known/operator-identity.pub`.
- `/data/` — human-readable open-data catalog with one row per public endpoint.
- `/selection-evidence/` — evaluator-facing evidence index that links the manifest alongside other artefacts.
- `scripts/gen-evidence.sh` — the generator, committed in the public repository.
