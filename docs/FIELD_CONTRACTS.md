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
- **Value domains are not checked at all** — only names. An enum whose case the
  reader gets wrong reads as a valid field and passes. See the value-domain
  section below for why a general rule here is harder than it looks.
- Only jq programs and JS fetch callbacks bound to a known artifact are checked.
  jq against RPC responses and unbound variables are skipped; `--coverage`
  reports how many, including jq calls with no single-quoted program (107 in
  this repo — `jq empty`, `jq .`, and double-quoted programs, which carry no
  analyzable reads).
- Reads on a jq variable (`$c.start_iso`, where `. as $c` binds the input
  element) are not attributed. Only `--slurpfile`/`--argfile` variables, which
  name a second artifact, are followed.
- JS: callbacks are followed when passed inline, or by name to a `function f(x)`
  or **block-body** arrow `var f = x => { … }` declaration. A *concise-body*
  arrow (`var f = x => x.foo`) is not followed — the body extractor requires a
  `{`. Nor is a callback reached any other way (a method on an object, a value
  in a dispatch table). Reads inside any of those are invisible.
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
| `validator.json` | `public/assets/main.js` | `v.stake.amount` | `stake.self` | LOW | dead fallback. `stake.amount` was real once (`dc80dab`, always `null`); `1c81178` moved the feed to `stake.self` and kept this branch as deliberate back-compat. No writer has emitted it since, so it had been unreachable for the whole life of the current schema; removed |

### Value-domain findings (a different class, same silence)

Field names being right does not mean the values are understood. Found in the
same sweep, in a file already being edited for the field-name fixes:

| Artifact | Reader | Problem | Severity | Effect |
|---|---|---|---|---|
| `incidents.json` | `public/assets/incidents.js` | `severity` enum is `["Critical","Major","Minor","Info"]`; the I18N tables were keyed lowercase and the badge test read `sev === "critical"` | **HIGH** | every lookup missed. The JA page rendered the raw English enum value (locale leak), and a **Critical or Major incident was painted `badge-ok` — green**. The page signalled "all fine" for the most serious event class it exists to report |
| `incidents.json` | `public/assets/incidents.js` | `status` enum `["open","under_remediation","resolved"]` was about to be rendered raw | MEDIUM | a visitor would have read `under_remediation` verbatim, in both locales |

Both are now normalized at the single point of use, and
`tests/incidents-page/test-incidents-i18n-enums.sh` reads the enums straight
out of the schema and fails if any value would render unlabelled — so adding a
severity level to the schema now demands a label rather than silently
degrading.

**Can `check-field-contracts.py` catch this class?** Not reliably, and it
should not pretend to. `severity` IS a real field read under its real name;
only the value domain was wrong, and the checker compares names. A workable
heuristic exists — JSON Schema `enum` values are machine-readable, so one could
flag any source file whose object-literal keys or string comparisons match ≥2
values of an enum case-insensitively but none exactly. That would have caught
this exact bug. It is not implemented, for a specific reason: the correct fix
is to normalize case at the lookup, which leaves the lowercase table in place,
so the heuristic keeps firing on correct code. Suppressing that requires
recognizing "a normalization call governs this lookup" — real dataflow
analysis, and getting it wrong produces persistent false positives on code that
is already right. That trade is bad for a gate whose entire value is that a red
run means something. The targeted per-page test above closes the case with no
false-positive surface; a general rule remains an open option if this class
recurs elsewhere.

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

## Republishing a feed whose bytes are pinned by a signed manifest

**A corrected feed cannot simply be regenerated and pushed.** Several public
feeds are content-pinned by a signed manifest whose own hash is inscribed
on-chain, so republishing one in isolation puts the published state into
provable disagreement with a signature and with the chain.

The live chain, as measured on 2026-08-06:

```
public/api/cycle-history.jsonl
  sha256 475bd9127b6c0a8dd2c531e78b3ac611899f9fd32bf3c0977030b6e2a3a75b0c
      ↓ pinned by
public/api/identity.json  .artifact_manifest.cycle_history_jsonl.sha256   (same value)
      ↓ identity.json's own sha256 is a leaf of
public/api/anchor-source.json  .artifacts_branch.public_api_files_hashed[]
      ↓ folded into
  .dag_root_computed = 063f753e…
      ↓ inscribed as dag_root_hash on the last anchor-history line
  Metal A-chain tx 32529f4a… block 396269445
```

`scripts/gen-cycle-history.sh` already refuses to run when the cycle gate is
deferred, precisely because its bytes flow into that chain. The gate protects
the *transition window*; it does not make an out-of-band republish safe.

### Two delivery mechanisms — do not mix them up

The files in this procedure do **not** travel the same way, and using the wrong
command silently fails:

| File | Delivered by | Command |
|---|---|---|
| `cycle-history.jsonl` | **push** (host-side, listed in `deploy/feed-excludes.txt` so the deploy rsync never touches it) | `scripts/push-to-web-host.sh cycle-history.jsonl` |
| `identity.json`, `identity.json.sig`, `identity-history.jsonl` | **git** (absent from `feed-excludes.txt`, so `deploy.yml`'s rsync delivers them) | `git add` → commit → push → deploy |

`push-to-web-host.sh` accepts a fixed 16-filename allowlist plus two
subdirectory prefixes. `identity.json` is not on it and never was:

```
$ bash scripts/push-to-web-host.sh identity.json
ERROR: unrecognized filename: identity.json      # exit 1
```

`docs/DEPLOY_OWNERSHIP_MATRIX.md` records the same split ("From Git; regenerate
via operator-Mac `gen-identity.sh`"), and `gen-identity.sh` itself ends by
printing the `git add` list. Three independent sources agree.

### Procedure

Run **outside a cycle-transition window**, and take the steps in this order.
The order is not stylistic: `scripts/operator-local/gen-identity.sh` hashes each
artifact by **fetching its live URL** (it `curl`s each leaf), so it must not run
until the corrected bytes are already being served. Re-signing first would
faithfully pin the old content again.

1. **Regenerate on the validator host, through the gate.**
   `bash scripts/gen-cycle-history.sh` — it exits 0 without writing if the gate
   is deferred, which is the correct outcome; wait and retry rather than
   bypassing it. The conservation check (exit 4) must pass.
   Then record the hash you are about to publish, so step 6 has a target that
   does not depend on any constant written down here:
   `shasum -a 256 public/api/cycle-history.jsonl`
2. **Publish the corrected feed** (push path):
   `bash scripts/push-to-web-host.sh cycle-history.jsonl`
   From here until step 4 lands, the served feed and the signed manifest
   disagree. Keep the window short; this is why it is done outside a transition.
3. **Re-sign the manifest on the operator Mac** (not on any host — the identity
   key lives only there):
   `OPERATOR_IDENTITY_KEY=<path> bash scripts/operator-local/gen-identity.sh`
   It re-fetches every leaf, picks up the new `cycle-history.jsonl` hash,
   recomputes `artifact_root`, re-signs, and self-verifies.
4. **Deliver the manifest through git** — the script prints this exact list when
   it finishes; do not substitute `push-to-web-host.sh`, which will refuse:

   ```
   git add public/api/identity.json \
           public/api/identity.json.sig \
           public/api/identity-history.jsonl \
           public/.well-known/operator-identity.pub
   ```

   Review the diff, commit, push. `deploy.yml`'s rsync delivers all of them.

   `identity-history.jsonl` is not optional here: it is **itself a leaf** of
   `anchor-source.json .artifacts_branch.public_api_files_hashed[]` (currently
   `0021e4d2…`). Committing `identity.json` while leaving it behind
   re-introduces exactly the manifest-vs-served divergence this procedure exists
   to close.
5. **Let the next anchor pick it up.** `identity.json`'s new hash changes the
   artifacts branch and therefore `dag_root_computed`; the next scheduled anchor
   inscribes the new root. Do not force an extra anchor for this — the previous
   inscription is not invalidated, it simply records the state as of its own
   time, which is what an append-only chain is for.
6. **Verify**, in this order:
   - the served `cycle-history.jsonl` sha256 equals the value captured in step 1
     **and** equals `identity.json .artifact_manifest.cycle_history_jsonl.sha256`;
   - `ssh-keygen -Y verify` accepts `identity.json` against `identity.json.sig`;
   - the served `identity-history.jsonl` sha256 equals the
     `artifacts_branch` leaf.

   A review pass on 2026-08-06 measured the corrected feed as
   `e8001d204a8dd0ed41a5755a84dadd36814b4dfda4a394db569449351e210765`. Treat
   that as a cross-check, not as the authority: it was measured before the
   incident-attribution boundary fix landed, and this repo has no copy of the
   live `cycle-history.jsonl` to re-measure it against. The step-1 capture is
   the authoritative target. If the two disagree, the boundary fix changed which
   cycle an incident belongs to — confirm that against the incident log rather
   than assuming corruption.

Skipping step 3–4, or doing them before step 2, leaves a published feed whose
hash contradicts a signature that is itself committed to the chain — exactly
the kind of unexplained inconsistency an evaluator is entitled to read as
tampering.
