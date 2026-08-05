# Cycle history audit packet (`/api/cycle-history.jsonl`)

This document describes the per-cycle audit packet that Freedom Yield publishes at `/api/cycle-history.jsonl`. It exists so a third-party reviewer can stream the full cycle-by-cycle record line by line, joining uptime, incident, and operating parameters into one compact format.

## Status

Live. `scripts/gen-cycle-history.sh` runs at every cycle transition, regenerating the file with one line per closed cycle. This document does not track how many cycles have closed — the feed itself is authoritative for that; query it directly (`curl -s https://metal.freedom-yield.com/api/cycle-history.jsonl | wc -l`) or see `/api/evidence.json` → `.live_artifacts.cycle_history_jsonl` for machine-readable discovery.

## Machine-readable discovery

An automated reviewer can discover this feed entirely from `/api/evidence.json` (documented at `docs/EVIDENCE_MANIFEST.md`). Since the runtime feed went live on 2026-06-22, the `live_artifacts.cycle_history_jsonl` object lists, in one place: the live `cycle-history.jsonl` URL, the schema preview at `/api/cycle-history.example.jsonl`, the formal JSON Schema at `/api/cycle-history.schema.v1.json`, and the link back to this document. (The entry sat under `in_preparation_artifacts` prior to 2026-06-22 and moved to `live_artifacts` in commit `6b20b56`.)

## Why JSONL, not JSON

JSON wraps records in an array. JSONL writes each record on its own line, terminated by `\n`. For a strictly append-only audit log that grows by one row per closed cycle, JSONL is operationally friendlier:

- `tail -n 1` is the latest cycle without parsing the whole file.
- `wc -l` counts cycles in constant time.
- A streaming consumer can read one record per line and never hold the whole file in memory.
- Diff-friendly under git or rsync (appends are line additions, not whole-file rewrites).

## Per-line schema

Every line is a complete JSON object. Fields:

| field | type | source |
|---|---|---|
| `schema_version` | integer | constant `1` (incremented on breaking changes) |
| `cycle_n` | integer | per `uptime-cycles.json` |
| `node_id` | string | NodeID (per-cycle invariant for this validator) |
| `network` | string | `metal-mainnet` |
| `start_iso` / `end_iso` | ISO 8601 UTC | period start / end recorded on chain |
| `duration_days` | integer | end − start, days |
| `final_uptime_pct` | number | uptime% as observed at cycle close |
| `days_recorded` | integer | sample-day count contributing to the uptime% |
| `final_self_stake_metal` | integer | self-stake at cycle close |
| `final_total_delegated_metal` | integer | sum of delegator stake at cycle close |
| `final_delegation_fee_pct` | number | delegation fee at cycle close |
| `avg_peer_count` | number | mean peer count over recorded samples |
| `min_peer_count` | integer | minimum peer count over recorded samples |
| `incidents_in_cycle_count` | integer | count of `incidents.json` entries with date inside `[start_iso, end_iso)` |
| `incidents_in_cycle_ids` | array of strings | the `id` values of those incidents (empty array if none) |
| `explorer_url` | string | explorer validator page URL for independent audit |
| `cycle_status` | string | `closed` (only closed cycles appear) |
| `notes` | string | operator-maintained free-text notes for the cycle |

> **`duration_days` vs `days_recorded` are two different definitions, not a
> consistency check.** `duration_days` is wall-clock: `(end − start) / 86400`,
> floored, straight from the on-chain period. `days_recorded` is a sample
> count: the number of `uptime-history.sh` daily-cron rows tagged with that
> cycle's end time in the master ledger. The two can legitimately differ for
> the same cycle (a missed daily tick during an outage undercounts
> `days_recorded`; an extra catch-up sample near the boundary can overcount
> it) — neither value corrects the other, and a mismatch alone is not a bug.

The example with one fully populated cycle lives at `/api/cycle-history.example.jsonl` and is committed to the repo so the schema is verifiable today.

## How the join works

The generator script (`scripts/gen-cycle-history.sh`) reads:

1. `public/api/uptime-cycles.json` — the canonical per-cycle uptime ledger.
2. `public/api/incidents.json` — the operator-maintained incident log.

For each cycle in `uptime-cycles.json.cycles[]`, sorted by `cycle_n`, it emits a JSON line whose `incidents_in_cycle_count` and `incidents_in_cycle_ids` come from selecting incidents whose `date` falls in the half-open interval `[start_iso, end_iso)`.

The generator is deterministic and idempotent: a re-run on the same inputs produces byte-identical output, validated by `md5` against the previous file.

## Consuming the file

A reviewer can stream-process the full audit packet:

```sh
curl -s https://metal.freedom-yield.com/api/cycle-history.jsonl \
  | jq -c '{cycle_n, final_uptime_pct, incidents_in_cycle_count, cycle_status}'
```

Or summarise across all cycles:

```sh
curl -s https://metal.freedom-yield.com/api/cycle-history.jsonl \
  | jq -s '{
      cycles_recorded: length,
      total_incidents: (map(.incidents_in_cycle_count) | add),
      uptime_min: (map(.final_uptime_pct) | min),
      uptime_max: (map(.final_uptime_pct) | max)
    }'
```

For a fixed, schema-stable shape independent of how many cycles the live feed currently has, the same query can be exercised against the committed example:

```sh
curl -s https://metal.freedom-yield.com/api/cycle-history.example.jsonl \
  | jq -c '{cycle_n, final_uptime_pct, incidents_in_cycle_count, cycle_status}'
```

## What this file is not

This is not a substitute for on-chain verification. Every cycle has an `explorer_url` field; an auditor verifying a claim should cross-check the on-chain validator page rather than treat the JSONL as authoritative on its own. The JSONL is a convenience layer — it makes the canonical record cheaper to consume, not more authoritative.

It is also not a complete operational log. It records closed cycles only — in-flight cycle state lives in `/api/uptime-recent.json`. If a cycle ends inside an incident, that incident appears here only after the cycle's `end_iso` rolls past the close threshold.

## Operational invariants

- One line per closed cycle. The file grows by one line per renewal.
- Append-only conceptually, regenerated wholly in practice. The generator re-derives the file from sources on every run; the result remains byte-identical to the previous run unless an input changed.
- Schema version is pinned at `1`. Any breaking change increments `schema_version` and is announced in the cycle journal.

## Current state (2026-06-20)

Cycle 2 is scheduled to end at its P-Chain-defined end time on 2026-07-04. The next renewal transaction is operator-executed and may be committed before or after that exact boundary. A delay does not extend cycle 2: the cycle's end is set by the P-Chain ledger when cycle 2 was registered, and the closed-cycle row is appended only after the cycle's end is observed on chain — separately from when (or whether) the next renewal transaction is committed. The closed-cycle audit packet therefore contains only cycle 1 during the cycle 2 active window; that is the expected steady state.

The P-Chain ledger is authoritative for cycle boundaries and validator transactions. `scripts/gen-cycle-history.sh` is the canonical generator of the published closed-cycle JSONL from its declared source artifacts. Operator-maintained `notes` are appended to a closed row after the generator emits it; manual notes never replace generator output.

## Related artifacts

- `/api/uptime-cycles.json` — canonical per-cycle uptime ledger (the primary source).
- `/api/incidents.json` — operator-maintained incident log (the join target).
- `/journal/` — the human-readable cycle journal.
- `/selection-evidence/` — the index that links to this JSONL alongside the other evidence artifacts.
- `scripts/gen-cycle-history.sh` — the generator script, committed in the public repository.
