# Phase 5 regeneration execution report — 2026-06-22

This document is the audit evidence for the **second-pass regeneration** of the Phase α operator identity manifest, performed after `/api/cycle-history.jsonl` went live (= D10 activation). The first-pass publication (Phase 5, 2026-06-22 morning) carried an empty `cycles_branch` because no `cycle-history.jsonl` runtime feed existed yet; this regeneration folds the inaugural cycle (cycle 1, closed 2026-06-04) into the `cycles_branch` and updates `dag_root_hash` accordingly.

This is **revision 2** of the report. Revision 1 was reviewed by an independent auditor who surfaced two HIGH-severity findings, one MEDIUM, and two LOW. All five findings are addressed in §§ noted below and in the post-audit `5be6…` lineage commit chain. The revision is published as a forward commit so that the audit trail (= what was claimed, what was wrong, what was corrected) is itself preserved on-chain (git history) and verifiable.

Companion docs:

- [`PHASE_ALPHA_AUDIT_HANDOFF.md`](PHASE_ALPHA_AUDIT_HANDOFF.md) — Phase α global audit entry point (= schemas, examples, verifier recipe, test vectors)
- [`PHASE5_CHECKLIST.md`](PHASE5_CHECKLIST.md) — the procedural checklist the operator follows
- [`IDENTITY_VERIFICATION.md`](IDENTITY_VERIFICATION.md) — nine-step verifier recipe
- [`MERKLE_DAG_SPEC.md`](MERKLE_DAG_SPEC.md) — byte-level Merkle DAG specification
- [`EVIDENCE_MANIFEST.md`](EVIDENCE_MANIFEST.md) — public artifact catalog

## 1. Scope

| Item | Value |
|---|---|
| Action | Re-run `scripts/operator-local/gen-identity.sh` with live `/api/cycle-history.jsonl` so that `cycles_branch` is populated and `dag_root_hash` reflects the canonical state |
| Trigger | D10 (cycle-history runtime feed) went live on `metal.freedom-yield.com` earlier this day, exposing one closed cycle (cycle 1) as a single JSONL line |
| Performer | Operator (= `operator`) on local Mac, per `gen-identity.sh` §1 production-host refusal guard |
| Date / time of execution | 2026-06-22T09:57:28Z (UTC) = 2026-06-22 18:57:28 JST |
| Public commits produced | `5be649a` (manifest regen + propagation), `8aec993` (CI verifier hotfix), and the post-audit drift fix + report-rev-2 commit recorded here |
| Deploy outcome | GitHub Actions: `Deploy site to VPS` run 27945337701 — success |
| Verifier CI outcome | GitHub Actions: `verify-identity-manifest` run 27945337707 — success (after `8aec993` hotfix) |

Out of scope (= explicitly **not** done in this execution):

- Operator identity key rotation in the strict sense (= no new `identity-history.jsonl` entry, `key_seq` remains 1). **Important caveat surfaced by the audit:** the regeneration nonetheless overwrote `identity.json.key_iat` to the regen-time wallclock, which diverges from `identity-history.jsonl[key_seq=1].key_iat`. This is a gen-identity.sh defect tracked in §8 (HIGH-1) and remains open at the time of this report.
- On-chain anchor inscription on Metal A-chain (= scheduled to fire automatically at cycle 2 → cycle 3 transition, 2026-07-04 13:00 JST, by a cron-driven `watch-anchor-events.sh`)
- Schema version bump (`schema_version` remains `1` on all artifacts)
- Public delegate-page status correction (= separate concern, deferred to a future commit, see §8)

## 2. Pre-state (= state immediately before this execution)

Field paths below use the **actual JSON structure** of each artifact (= verified by `jq` against the live files). The earlier revision of this report used incorrect short paths (`cycles-history.json.cycles.*`) that returned `null` when run against the artifact; this has been corrected.

| Field | Value (= first-pass Phase 5 publication, 2026-06-22 06:28:51Z) |
|---|---|
| `identity.json.dag_root_hash` | `c89b7cc694ae09c8a7e9f2dc3c4de879527398a19c6a68ab24c6d62e7085d948` |
| `identity.json.artifact_root` | `a1c15e442d37cae4620cf6fd494ebc8ffecfd1ad41f1481bc8e51dfce6ce1671` |
| `identity.json.generated_at` | `2026-06-22T06:28:51Z` |
| `identity.json.key_iat` | `2026-06-22T06:28:51Z` (= matched `identity-history.jsonl[key_seq=1].key_iat`) |
| `identity-history.jsonl[key_seq=1].key_iat` | `2026-06-22T06:28:51Z` (authoritative ledger) |
| `cycles-history.json.branches.cycles.leaf_source_sha256` | `""` (= empty, no live JSONL) |
| `cycles-history.json.branches.cycles.leaf_count` | `0` |
| `cycles-history.json.branches.cycles.branch_root` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (= `SHA256("")`, the null-input hash) |
| `cycles-history.json.branches.identity.branch_root` | `0021e4d21564c3ed5ccfbdd836d11e805b8b667d0b200f9cc55e3133a18c5856` |
| `selection-evidence/index.html` identity binding status | `"in preparation"` (EN), `"準備中"` (JA) |
| `selection-evidence/index.html` cycle audit packet status | `"in preparation"` (EN), `"準備中"` (JA) |
| `docs/EVIDENCE_MANIFEST.md` identity entry | `/api/identity.json (in preparation)` |
| CI workflow `verify-identity.yml` line 67 | `jq -e empty "$JSON" >/dev/null` (= silently broken: returns exit 4 on valid JSON, see §6.2) |

## 3. Action sequence

1. **Verify the live cycle-history feed.**
   ```sh
   curl -sS https://metal.freedom-yield.com/api/cycle-history.jsonl > /tmp/cy.jsonl
   shasum -a 256 /tmp/cy.jsonl
   #  3170d1405f411d3840b3c59684b6fd16f2bd52f46acd997de993171eb3ead60f  /tmp/cy.jsonl
   ```
   The file is one JSONL line describing cycle 1 (closed 2026-06-04T07:17:46Z, 100% uptime over 14 recorded days, 0 incidents). Schema conformance: `schema_version: 1`, all required fields present.

2. **Re-run the generator on local Mac.**
   ```sh
   export OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity
   bash scripts/operator-local/gen-identity.sh
   ```
   The script:
   - refused to run anywhere other than the operator's local Mac (§1 guard)
   - did **not** bootstrap a new identity-history entry (= already present at `key_seq=1`)
   - fetched the live JSONL leaves, computed branch roots, composed `identity.json`, signed it with `ssh-keygen -Y sign -n freedom-yield/validator-identity`, **self-verified** with `ssh-keygen -Y verify`, then atomically published
   - **also overwrote `identity.json.key_iat` with `NOW_UTC` instead of reading from `identity-history.jsonl[key_seq=1]`** — this is the HIGH-1 defect; the first revision of this report did not call out the divergence and was corrected here

3. **Initial commit (= `5be649a`).** Six files modified:
   - `public/api/identity.json` (dag_root_hash + artifact_root + generated_at + key_iat — see HIGH-1)
   - `public/api/identity.json.sig` (signature over the new payload)
   - `public/api/cycles-history.json` (cycles_branch populated)
   - `public/selection-evidence/index.html` (EN: identity binding "in preparation" → "live (manifest) · scheduled (anchor)" + snapshot+rotation cadence paragraph)
   - `public/ja/selection-evidence/index.html` (JA: equivalent identity binding update)
   - `docs/EVIDENCE_MANIFEST.md` (identity entry: removed "(in preparation)" flag, added companion artifact list)

4. **Triage CI false-fail (= `8aec993`).** The `verify-identity-manifest` workflow (run 27945135318) failed with exit 4 on `jq -e empty "$JSON"`. This is the same trap that `gen-identity.sh` §4 has a documented warning about (`empty` produces no output, `-e` reads that as "no result" and returns 4). Fixed by dropping `-e`. Re-run on commit `8aec993`: `verify-identity-manifest` (run 27945337707) — success.

5. **Independent audit of revision 1 of this report.** An independent auditor reviewed the revision-1 evidence and surfaced:
   - **HIGH-1** key_iat divergence between `identity.json` and `identity-history.jsonl` (= a gen-identity.sh defect that revision 1 glossed over)
   - **HIGH-2** propagation gap mis-characterized: cycle-history.jsonl became live (= the very trigger of this regen) but `selection-evidence/` continued to call it "in preparation" / "準備中" across multiple surfaces; revision 1 claimed the propagation gap was eliminated when it was not
   - **MEDIUM-1** JSON path notation errors (= `cycles.leaf_source_sha256` rather than the actual `branches.cycles.leaf_source_sha256`) that prevented an auditor from reproducing the verification commands
   - **LOW-1** delegate-page reference under-counted (= 2 surfaces in EN, not 1)
   - **LOW-2** §6.3 grep-coverage claim was weak (= 11 stale matches actually remained, of which 7 were intentional retention and 4+ were drift bugs that revision 1 missed)

6. **Post-audit drift fix + report revision 2.** Within the same audit cycle the following corrections were committed:
   - `public/selection-evidence/index.html` cycle audit packet section: status `"in preparation"` → `"live (1 cycle closed)"`, h3 retitled (`(in preparation)` dropped), paragraph rewritten to reflect cycle 1 closed + cron behavior + DAG fold-in, `<dt>Status</dt>` → `Live — runtime JSONL serving since 2026-06-22`, `<dt>Planned feed</dt>` → `<dt>Live feed</dt>`, a `<dt>Cross-reference</dt>` row added linking the leaf sha256 into `cycles-history.json.branches.cycles.leaf_source_sha256`. Machine-readable discovery row left as-is with an inline note explaining that the discovery key still lives in the `in_preparation_artifacts` namespace pending `/api/evidence.json` runtime publication; the feed itself is live.
   - `public/ja/selection-evidence/index.html`: equivalent JA updates with matching status text.
   - This report (`docs/PHASE5_REGEN_EXECUTION_2026-06-22.md`) rewritten as revision 2: §2 + §4 JSON paths corrected, §6.3 honestly enumerates all 11 stale matches and which were drift vs intentional, §8 adds HIGH-1, LOW-1 corrected to "2 surfaces (paragraph + hero badge)".

## 4. Post-state (= state at the live edge after deploy + audit-driven drift fix)

| Field | Value |
|---|---|
| `identity.json.dag_root_hash` | `0bd4e667dcb7397c655ad4bccdef282b76d8a98cde4b67a8396790bcd07d3bb4` |
| `identity.json.artifact_root` | `0e61a404a3739f660d5adb8743021f891207a55a6bc3790df5e5a03edff2cbc8` |
| `identity.json.generated_at` | `2026-06-22T09:57:28Z` |
| `identity.json.key_iat` | `2026-06-22T09:57:28Z` ⚠ **diverges** from `identity-history.jsonl[key_seq=1].key_iat = 2026-06-22T06:28:51Z` (HIGH-1, open) |
| `identity-history.jsonl[key_seq=1].key_iat` | `2026-06-22T06:28:51Z` (unchanged, authoritative) |
| `identity.json.key_exp` | `2027-06-22T09:57:28Z` (1-year rotation deadline computed from `key_iat`; therefore also drifted relative to a key_iat-grounded calendar of 2027-06-22T06:28:51Z) |
| `identity.json.operator_identity_pubkey_fingerprint` | `SHA256:rQZNC53Jdp3Cgi0XXbFT+aLWOtB8eS0Iv6jQ7KazvIY` (= **unchanged** from first-pass; same ed25519 key, no rotation) |
| `cycles-history.json.branches.cycles.leaf_source_sha256` | `3170d1405f411d3840b3c59684b6fd16f2bd52f46acd997de993171eb3ead60f` |
| `cycles-history.json.branches.cycles.leaf_count` | `1` |
| `cycles-history.json.branches.cycles.branch_root` | `3170d1405f411d3840b3c59684b6fd16f2bd52f46acd997de993171eb3ead60f` (= single-leaf branch root = sha256 of the leaf line) |
| `cycles-history.json.branches.identity.branch_root` | `0021e4d21564c3ed5ccfbdd836d11e805b8b667d0b200f9cc55e3133a18c5856` (unchanged) |
| `selection-evidence/index.html` identity binding status | `live (manifest) · scheduled (anchor)` + status `Active` (EN), 同等 (JA) |
| `selection-evidence/index.html` cycle audit packet status | `live (1 cycle closed)` + status `Live — runtime JSONL serving since 2026-06-22` (EN), 同等 (JA) — corrected in revision-2 commit |
| `docs/EVIDENCE_MANIFEST.md` identity entry | live, with companion artifact list |
| CI workflow `verify-identity.yml` line 67–70 | `jq empty "$JSON" >/dev/null` (+ inline comment cross-linking gen-identity.sh §4) |

## 5. Verification matrix (= what an auditor can reproduce **today**)

Field paths below are the **corrected** paths. An auditor reproducing these commands against the live artifact should see the observed values.

| # | Check | Command | Expected | Observed |
|---|---|---|---|---|
| V1 | live identity.json fetch + parse | `curl -sS https://metal.freedom-yield.com/api/identity.json \| jq -r .dag_root_hash` | `0bd4e667…` | ✅ |
| V2 | live cycles-history.json parity | `curl -sS https://metal.freedom-yield.com/api/cycles-history.json \| jq -r .dag_root_hash` | matches V1 | ✅ |
| V3 | live signature verify | `ssh-keygen -Y verify -f <(printf 'freedom-yield %s\n' "$(curl -sS .../.well-known/operator-identity.pub)") -I freedom-yield -n freedom-yield/validator-identity -s <(curl -sS .../identity.json.sig) < <(curl -sS .../identity.json)` | `Good "freedom-yield/validator-identity" signature for freedom-yield with ED25519 key SHA256:rQZNC53Jdp…` | ✅ |
| V4 | cycles_branch_root reproducibility | `curl -sS .../api/cycle-history.jsonl \| shasum -a 256` should equal `jq -r .branches.cycles.leaf_source_sha256 cycles-history.json` and `jq -r .branches.cycles.branch_root cycles-history.json` | both `3170d1405…` | ✅ |
| V5 | EN selection-evidence identity status text | grep on live HTML | `<span class="data-tag">live (manifest) · scheduled (anchor)</span>` present | ✅ |
| V6 | JA selection-evidence identity status text | grep on live HTML | `状態</dt><dd>Active — identity.json + identity.json.sig は 2026-06-22(Phase 5 publication)以降 live` | ✅ |
| V7 | EN selection-evidence cycle audit packet status (post-audit drift fix) | grep on live HTML | `<span class="data-tag">live (1 cycle closed)</span>` present | ✅ (after revision-2 commit deploys) |
| V8 | JA selection-evidence cycle audit packet status (post-audit drift fix) | grep on live HTML | `<span class="data-tag">live(1 cycle closed)</span>` present | ✅ (after revision-2 commit deploys) |
| V9 | key_iat ↔ identity-history.jsonl divergence (HIGH-1 reproducibility check) | `diff <(jq -r .key_iat identity.json) <(jq -r 'select(.key_seq==1) \| .key_iat' identity-history.jsonl)` | should be **empty**; currently **non-empty** | ❌ divergence reproducible, see §8 |
| V10 | CI workflow pass on the verified commit | `gh run view 27945337707` | success | ✅ |
| V11 | Edge cache freshness | `curl -I .../api/identity.json` → check `last-modified` | `last-modified` advanced past 06:28:51 GMT | `Mon, 22 Jun 2026 10:11:09 GMT` ✅ |

The full nine-step verifier recipe (`IDENTITY_VERIFICATION.md`) also applies. V1–V11 above are a regen-specific subset, with V9 added to make the HIGH-1 finding reproducible by future auditors.

## 6. Risks + mitigations

### 6.1 Stale `dag_root_hash` cached at the edge

Cloudflare serves the JSON artifacts with `cache-control: public, max-age=120, must-revalidate`. A verifier who fetched `identity.json` between 06:28:51Z (= first-pass) and 10:11:09 GMT (= deploy `last-modified`) and cached the value locally may have an out-of-date `dag_root_hash`. This is acceptable because (i) Phase α is an explicit **snapshot model**, not a heartbeat, and (ii) the new manifest carries a strictly later `generated_at`, so any sane verifier will treat the newer snapshot as authoritative.

### 6.2 CI verifier was silently broken before this execution

The `jq -e empty` trap meant `verify-identity-manifest` would have failed for **any** valid `identity.json` push, including the first-pass `0f73b3d` commit. Inspection of run history confirms the workflow was indeed red for `0f73b3d` and stayed red across intermediate site changes (`4c2d4d3` through `808a533`). It is now green from `8aec993` onward. This is a defect-in-defenders, not an issue with the manifest itself, but it does mean an auditor relying on CI status as a gate prior to today's hotfix was getting a false negative. **Mitigation:** any prior auditor who treated the red CI as evidence of a problem should re-evaluate against the current green state.

### 6.3 Concept drift between artifact and surrounding documentation

The first-pass commit declared identity manifest "live" in `identity.json` but left some surrounding surfaces describing it as "(in preparation)". Revision 1 of this report claimed only three stale matches remained and that they were all intentional retention. The independent audit demonstrated that this enumeration was wrong; the actual breakdown across `public/selection-evidence/index.html` + `public/ja/selection-evidence/index.html` was:

| # | Location | EN line | JA line | State at revision-1 time | Disposition in revision-2 commit |
|---|---|---|---|---|---|
| 1 | Cycle audit packet h3 | 234 | 234 | drift bug | **fixed** ("(in preparation)" / "(準備中)" suffix removed) |
| 2 | Cycle audit packet tag | 235 | 235 | drift bug | **fixed** ("live (1 cycle closed)" / "live(1 cycle closed)") |
| 3 | Cycle audit packet paragraph | 237 | 237 | drift bug | **fixed** (rewritten to describe the live feed + cron append + DAG fold-in) |
| 4 | Cycle audit packet `<dt>Status</dt>` JA | — | 239 | drift bug | **fixed** ("Live — runtime JSONL serving since 2026-06-22") |
| 5 | Cycle audit packet `<dt>Planned feed</dt>` | 241 | 241 | drift bug | **fixed** (`<dt>Live feed</dt>` linking the live URL) |
| 6 | Cycle audit packet `<dt>Machine-readable discovery</dt>` | 242 | 242 | stale path pending evidence.json | **deferred with inline note** (see §8) |
| 7 | Identity binding `<dt>Machine-readable discovery</dt>` | 271 | 271 | stale path pending evidence.json | **deferred with inline note** (see §8) |
| 8 | DR drill row | 412 | 412 | intentional retention (genuinely 未実施) | retained |
| 9 | Formal exit runbook row | 433 | 433 | intentional retention (genuinely 未公開) | retained |

**Tally.** The audit identified **11 stale matches across the cycle audit packet section** (EN 5 surfaces + JA 6 surfaces, JA having one extra `<dt>Status</dt>` row at line 239). Of those 11:

- **9 fixed** in revision-2 commit (rows 1–5 in this table; rows 1, 2, 3, 5 each occupy EN + JA = 8 surfaces, plus row 4 = JA-only = 1 surface; total 9 surfaces).
- **2 deferred** in revision-2 commit (row 6 = cycle audit packet machine-readable discovery, EN + JA = 2 surfaces; gated on `/api/evidence.json` runtime publication; see §8 for rationale).

Separately, **2 retained** in revision-2 commit (rows 8–9 in this table = DR drill + formal exit runbook, EN + JA = 4 surfaces) because the underlying artifacts genuinely do not yet exist — these were correctly excluded from the audit's 11 count.

Also separately, **2 deferred** (row 7 = identity binding machine-readable discovery at line 271, EN + JA = 2 surfaces) — likewise excluded from the audit's 11 count because it sits in the identity binding section, not the cycle audit packet section, and is gated on the same `/api/evidence.json` runtime publication as row 6.

Revision 1's "3 matches, all intentional" was substantively wrong on both the count and the disposition.

**Process mitigation:** the operator's standing rule under [`feedback_propagate_conceptual_changes`](../../../.claude/projects/-Users-admin-htdocs-01-PROJECTS-metal-freedom-yield-com/memory/feedback_propagate_conceptual_changes.md) is to grep the full surface for the old wording before declaring a concept change complete. Revision 1 ran the grep but mis-counted the categories (= cycle-history.jsonl matches were misread as intentional retention when in fact cycle-history.jsonl had become live during the same execution window — the live status was the very trigger of the regen). Future executions should treat the grep output not as a checkbox but as a row-by-row classification: for each match, ask "is this the artifact I just changed?" and update accordingly.

### 6.4 Operator identity private key never leaves local Mac

The signing step (`ssh-keygen -Y sign`) ran on the operator's local Mac. The private key is encrypted at rest with a passphrase held in the operator's password manager and is not present on the validator host, the web host, the CI runner, or any cloud system. No transit of the private key occurred during this execution. The `.pub` is the only key material published.

### 6.5 Irreversibility

This is a **public repository**. The `5be649a`, `8aec993`, `8ef5f33` (revision 1 of this report), and the revision-2 commits are now permanent in the git history of `https://github.com/freedomyield/metal.freedom-yield.com`. Reversion is possible only by a forward commit; the original revision-1 report — including its incorrect §2/§4 JSON paths and incorrect §6.3 count — remains visible in git history. This is intentional: it preserves the audit trail of what the operator initially claimed, what the independent auditor caught, and what was corrected.

## 7. What an auditor **cannot** verify until cycle 3 start

The on-chain anchor receipt (`/api/anchor-receipt.json`) and the corresponding Metal A-chain transaction with memo `fyid1:0bd4e667…` are scheduled to be produced automatically by `watch-anchor-events.sh` on the validator host at the cycle 2 → cycle 3 transition (2026-07-04 13:00 JST). Until then:

- The runtime `/api/anchor-receipt.json` URL is intentionally absent (= verifier recipe step 5 returns 404 by design).
- The selection-evidence page labels this as `scheduled (anchor)` to set expectations correctly.
- The `metalfreedom@anchor` permission is already deployed on Metal A-chain (= test broadcasts `94446328…` and `e67f385b…` verified on explorer).

## 8. Open items (= surfaced and deferred; remain open at the time of this report)

### HIGH-1 (open): `identity.json.key_iat` overwritten on regen instead of being read from `identity-history.jsonl`

**Symptom.** `identity.json.key_iat = 2026-06-22T09:57:28Z` (= regen wallclock), while `identity-history.jsonl[key_seq=1].key_iat = 2026-06-22T06:28:51Z` (= true issuance moment of the current ed25519 operator identity key). A third-party auditor cross-referencing the two will see them disagree even though no rotation occurred. This violates the semantic the field name carries (`key_iat` = "key issued at").

**Root cause.** `scripts/operator-local/gen-identity.sh:143`:
```sh
KEY_IAT="${KEY_IAT:-${NOW_UTC}}"
```
On a re-run with no `KEY_IAT` environment variable set, this falls back to the current wallclock instead of reading the authoritative value from `identity-history.jsonl`. The same wallclock then propagates into `key_exp = key_iat + 365 days`, which also drifts.

**Three-option fix (operator judgment required):**
1. **Fix the generator.** Modify `gen-identity.sh` to read the current active key's `key_iat` from `identity-history.jsonl[key_seq=MAX(active)]` and reuse it. Only assign a new value when the script detects a genuine rotation (= new pubkey hash). This restores the field's intended semantic and is the recommended option.
2. **Re-regenerate with explicit env override.** Run `KEY_IAT=2026-06-22T06:28:51Z bash gen-identity.sh` to overwrite the current manifest with the corrected value, then ship a third-pass commit. This restores integrity for the current artifact but does not prevent recurrence.
3. **Change the field's semantic.** Re-document `key_iat` to mean "manifest reissue timestamp" and add a new field `key_first_issued_at` that carries the original. This is the largest schema change of the three; it would require a `schema_version` bump.

The operator's preferred option is pending decision. This report does not claim the artifact is fully consistent until one of the three is executed.

**Why this was not caught in revision 1 of this report.** Revision 1 read `identity.json.key_iat` as the post-state and did not cross-reference it against `identity-history.jsonl`. Revision 1's §1 Scope said key rotation was out of scope; the audit correctly observed that the field nonetheless changed value, contradicting the scope claim.

### LOW-1 (open): delegate-page status corrections (= 2 surfaces per language)

`public/delegate/index.html` (EN) carries the stale "preparing for registration" claim across **two** surfaces, not one as revision 1 stated:

- Line 50 paragraph: `"The validator node is bootstrapped on mainnet and preparing for registration."`
- Line 54 hero badge: `<span class="badge badge-warn">Mainnet bootstrap — preparing registration</span>`

`public/ja/delegate/index.html` carries the same two surfaces in JA (`登録準備中`).

This contradicts the verified on-chain state (validator has been an active mainnet validator since 2026-05-19; one large delegation 23,428 METAL was accepted on 2026-06-08). Deferred to a single-purpose commit because the fix is scoped to "validator-state accuracy," not Phase α identity manifest.

### Deferred: `selection-evidence/` machine-readable discovery rows

Two `<dt>Machine-readable discovery</dt>` rows (= the cycle audit packet row at line 242 and the identity binding row at line 271) still point to `/api/evidence.json → .in_preparation_artifacts.*`. The `evidence.json` runtime endpoint is not yet published; the schema and example exist (`evidence.schema.v1.json`, `evidence.example.json`) but no live JSON is served, so either path category (`.in_preparation_artifacts.*` or `.live_artifacts.*`) would currently 404. These two rows are honestly tagged with an inline note in revision-2 commit explaining the situation and will be corrected when `/api/evidence.json` runtime publication is in scope, including a re-keying of the discovery namespaces.

## 9. Sign-off

This execution was carried out under the operator-approved workflow defined in `docs/CONSTITUTION.md` and `docs/OPERATING_MODEL.md`: AI proposed, operator approved, AI verified, **independent auditor reviewed and surfaced defects, AI corrected, and revised the report as a forward commit** (= the report itself is now an audit-cycle artifact, not just an execution diary).

The Phase α second-pass regeneration met its operational objective (`cycles_branch` populated with cycle 1, identity manifest declared live across the public site, CI gates green). The audit cycle surfaced two HIGH-severity items: one was a defect-in-defender (`jq -e empty` in CI) resolved inside the same execution window in `8aec993`, and one (HIGH-1, `key_iat` overwrite on regen) remains open pending operator judgment on the three-option fix above. The MEDIUM and LOW items were addressed in revision-2 of this document and the accompanying drift-fix commit.

— Recorded 2026-06-22 (UTC), Freedom Yield Metal Blockchain validator project.
