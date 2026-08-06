# Field-name contracts between writers and readers

Every JSON/JSONL artifact in this repo is written by one script and read by a
different script — or by the site's browser JavaScript. Nothing in the language
enforces that the two agree on field names: `jq` returns `null` for a key that
was never written, JavaScript returns `undefined`, and both keep going. A wrong
field name therefore does not fail — it produces a blank, a zero, or a default,
indefinitely, with no error anywhere.

Schema validation does not close this. A schema constrains what the **writer**
emits. The reader is not schema-aware and may ask for any name at all.

## The incident this discipline exists for

2026-08-04, mid cycle-transition. `scripts/append-anchor-history.sh` writes the
per-anchor JSONL field as `dag_root_hash`. `scripts/gen-anchor-source.sh` read
it back as:

```
jq -r '.dag_root // .dag_root_computed // ""'
```

Neither name exists on that line. Every read returned `""`, so
`prev_anchor_root` serialized as `null` — indistinguishable from genuine
genesis — and the on-chain hash chain would have been permanently severed at
cycle 4. A pre-inscription verify caught it.

It had been latent for a month only because cycle 3 was genesis: the history
file was empty, so the reader never ran against real data. The bug was invisible
in review because the `//` chain made three names look equally authoritative,
and invisible in testing because the failing path only executes on non-empty
input.

## Rules

1. **One writer name, one reader name.** If the writer emits `dag_root_hash`,
   the reader reads `dag_root_hash` — not a chain of candidates.
2. **Do not add a `//` or `||` alternative that no writer emits.** A fallback
   that cannot match defends nothing. It only obscures which name is
   authoritative, which is exactly what let the 2026-08-04 bug survive review.
   Every such alternative found on 2026-08-06 has been deleted.
3. **Prefer failing closed over defaulting.** `gen-anchor-source.sh`'s M-2
   guard (exit 10) is the model: a non-empty history file whose last line does
   not yield 64-hex is an error, never a silent degrade to `null`.
4. **When a public feed and a reader disagree, fix the reader.** The feed's
   schema, example and live data are the contract; renaming a published field
   breaks external verifiers. Both 2026-08-06 fixes changed readers.

## Mechanical enforcement

`scripts/check-field-contracts.py` compares, for every artifact, the union of
writer-side names (example file + checked-in live file + JSON schema + the
emitting script's own object construction) against every key any reader asks
for — jq paths in shell, property accesses in browser JS. Feeds and readers are
discovered automatically; there is no hand-maintained list to fall out of date.

Severity reflects how loudly the mismatch would fail:

| Severity | Shape | Why |
|---|---|---|
| `CRITICAL` | unknown key guarded by a default (`// ""`, `\|\| "—"`) | never errors; silently substitutes the default forever — the 2026-08-04 disguise |
| `HIGH` | unknown key, unguarded | evaluates to null/undefined and fails downstream — bad, but loud |
| `LOW` | unknown key as a later `//` alternative | dead debris; harmless today, but it is what hides the class above |

Run it directly, or rely on `tests/field-contracts/test-field-contracts.sh`
(auto-discovered by `tests/run-all-tests.sh`, so both `validate.yml` and
`ci-main.yml` gate on it):

```
python3 scripts/check-field-contracts.py --coverage
bash tests/field-contracts/test-field-contracts.sh
```

The test suite includes mutation cases that reintroduce each real bug — the
2026-08-04 anchor-history read among them — and assert the checker turns red.
A checker nobody has watched fail is not evidence.

Waivers live in `tests/field-contracts/waivers.txt` and require a written
justification; an unjustified waiver is itself an error. As of 2026-08-06 the
file is empty.

### Known limits

Stated so they are not mistaken for coverage:

- Vocabulary is over-approximated (four unioned sources, and writer harvesting
  takes every construction key in an emitting file). This can only suppress
  findings, never invent them — false positives are rare by construction, and
  the accepted cost is a miss when a wrong name collides with an unrelated
  sibling key in the same file.
- Matching is by key **name**, not full dotted path.
- Only jq programs and JS fetch callbacks bound to a known artifact are checked.
  jq against RPC responses and unbound variables are skipped; `--coverage`
  reports how many.
- `tests/` is excluded by default (synthetic fixtures would distort both the
  writer vocabulary and the reader set). `--include-tests` scans them for manual
  review.

## 2026-08-06 inventory

Full sweep of every writer/reader pair in the repo: `public/api/` feeds,
`/var/lib/freedom-yield/` state files, anchor-pipeline handoff artifacts, and
browser readers. Findings:

| Artifact | Reader | Wrong name | Real name | Severity | Effect |
|---|---|---|---|---|---|
| `incidents.json` | `scripts/gen-cycle-history.sh` | `.date` | `detectionDate` | CRITICAL | `incidents_in_cycle_count` and `incidents_in_cycle_ids` pinned to `0` / `[]` on **every** cycle of the public cycle-history feed, regardless of the record |
| `incidents.json` | `public/assets/incidents.js` | `inc.date` | `detectionDate` | CRITICAL | "Last incident" stat rendered `—` with an incident on record; every card heading showed a bare `—` where the date belongs; the sort comparator returned 0 for all pairs |
| `incidents.json` | `public/assets/incidents.js` | `inc.resolution` | `resolutionDate` | HIGH | "Resolution" row could never render |
| `incidents.json` | `public/assets/incidents.js` | `inc.durationMinutes` | *(no such field)* | HIGH | "Duration" row permanently dead; feed carries date-only strings, so no duration is derivable — row removed |
| `incidents.json` | `public/assets/incidents.js` | `inc.impact` | *(no such field)* | HIGH | "Impact" row permanently dead — row removed |
| `anchor-history.jsonl` | `scripts/gen-anchor-source.sh` | `.dag_root`, `.dag_root_computed` | `dag_root_hash` | LOW | dead alternatives left behind by the 2026-08-04 fix; unreachable, removed |
| `validator.json` | `public/assets/main.js` | `v.stake.amount` | `stake.self` | LOW | dead fallback, never emitted by any writer; removed |

Checked and found consistent: all `/var/lib/freedom-yield/` state files
(`anomaly-state.json`, `cycle-gate-state.json`, `current-cycle-state.json`,
`watch-prev-state.json`, `anchor-watcher-state.json`, `delegator-events.jsonl`,
`uptime-history.jsonl`, `node-health-history.jsonl`); every anchor-pipeline
handoff (`sign-anchor-event.sh` → `gen-anchor-receipt.sh` →
`append-anchor-history.sh`, the broadcast token read by `bin/safe-broadcast` and
`broadcast-guard.sh`, the dry-run blob read by
`preview-cycle-anchor-broadcast.sh`); the receipt→history pair that caused the
original incident; and the remaining browser readers of `validator.json`,
`server-status.json`, `peer-geo.json`, `peers.json`, `uptime-cycles.json` and
`peers-gini-history.jsonl`.

Note the shape of what was found: **every live finding was in the incidents
feed**, and every one was masked by a default (`// ""`, `|| "—"`, `? :`) so it
rendered as a plausible-looking zero or blank rather than an error. That is the
same failure mode as 2026-08-04, on a page whose entire purpose is showing the
operating record honestly.
