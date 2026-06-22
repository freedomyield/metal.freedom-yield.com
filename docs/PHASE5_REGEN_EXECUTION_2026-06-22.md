# Phase 5 regeneration execution report — 2026-06-22

This document is the audit evidence for the **second-pass regeneration** of the Phase α operator identity manifest, performed after `/api/cycle-history.jsonl` went live (= D10 activation). The first-pass publication (Phase 5, 2026-06-22 morning) carried an empty `cycles_branch` because no `cycle-history.jsonl` runtime feed existed yet; this regeneration folds the inaugural cycle (cycle 1, closed 2026-06-04) into the `cycles_branch` and updates `dag_root_hash` accordingly.

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
| Public commits produced | `5be649a` (manifest regen + propagation), `8aec993` (CI verifier hotfix) |
| Deploy outcome | GitHub Actions: `Deploy site to VPS` run 27945337701 — success |
| Verifier CI outcome | GitHub Actions: `verify-identity-manifest` run 27945337707 — success (after `8aec993` hotfix) |

Out of scope (= explicitly **not** done in this execution):

- Operator identity key rotation (= same ed25519 key, no new `identity-history.jsonl` entry)
- On-chain anchor inscription on Metal A-chain (= scheduled to fire automatically at cycle 2 → cycle 3 transition, 2026-07-04 13:00 JST, by a cron-driven `watch-anchor-events.sh`)
- Schema version bump (`schema_version` remains `1` on all artifacts)
- Public delegate-page status correction (= separate concern, deferred to a future commit)

## 2. Pre-state (= state immediately before this execution)

| Field | Value (= first-pass Phase 5 publication, 2026-06-22 06:28:51Z) |
|---|---|
| `identity.json.dag_root_hash` | `c89b7cc694ae09c8a7e9f2dc3c4de879527398a19c6a68ab24c6d62e7085d948` |
| `identity.json.artifact_root` | `a1c15e442d37cae4620cf6fd494ebc8ffecfd1ad41f1481bc8e51dfce6ce1671` |
| `identity.json.generated_at` | `2026-06-22T06:28:51Z` |
| `cycles-history.json.cycles.leaf_source_sha256` | `""` (= empty, no live JSONL) |
| `cycles-history.json.cycles.leaf_count` | `0` |
| `cycles-history.json.cycles.branch_root` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (= `SHA256("")`, the null-input hash) |
| `selection-evidence/index.html` identity binding status | `"in preparation"` (EN), `"準備中"` (JA) |
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
   - bootstrapped no new identity-history entry (= `identity-history.jsonl` already existed at `key_seq=1`)
   - fetched the live JSONL leaves, computed branch roots, composed `identity.json`, signed it with `ssh-keygen -Y sign -n freedom-yield/validator-identity`, **self-verified** with `ssh-keygen -Y verify`, then atomically published.

3. **Reviewed the diff.** Six files modified:
   - `public/api/identity.json` (dag_root_hash + artifact_root + generated_at)
   - `public/api/identity.json.sig` (signature over the new payload)
   - `public/api/cycles-history.json` (cycles_branch populated)
   - `public/selection-evidence/index.html` (EN: "in preparation" → "live (manifest) · scheduled (anchor)" + snapshot+rotation cadence paragraph)
   - `public/ja/selection-evidence/index.html` (JA: equivalent)
   - `docs/EVIDENCE_MANIFEST.md` (identity entry: removed "(in preparation)" flag, added companion artifact list)

4. **Local integrity sweep before commit:**
   - `jq empty` on both JSON artifacts: pass
   - `ssh-keygen -Y verify` against the live `.pub`: pass
   - `dag_root_hash` parity check between `identity.json` and `cycles-history.json`: pass

5. **Commit + push.**
   - `5be649a feat(identity): regen manifest (cycle 2 leaf) + propagate live status` — gitleaks scan: 0 leaks
   - `git push origin main`

6. **Triage the CI false-fail.** The `verify-identity-manifest` workflow (run 27945135318) failed with exit 4 on `jq -e empty "$JSON"`. This is the same trap that `gen-identity.sh` §4 has a documented warning about (`empty` produces no output, `-e` reads that as "no result" and returns 4). Fixed in:
   - `8aec993 fix(ci): verify-identity workflow — jq -e empty false-fail`
   - Re-run on commit `8aec993`: `verify-identity-manifest` (run 27945337707) — success.

## 4. Post-state (= state at the live edge after deploy)

| Field | Value |
|---|---|
| `identity.json.dag_root_hash` | `0bd4e667dcb7397c655ad4bccdef282b76d8a98cde4b67a8396790bcd07d3bb4` |
| `identity.json.artifact_root` | `0e61a404a3739f660d5adb8743021f891207a55a6bc3790df5e5a03edff2cbc8` |
| `identity.json.generated_at` | `2026-06-22T09:57:28Z` |
| `identity.json.key_iat` | `2026-06-22T09:57:28Z` |
| `identity.json.key_exp` | `2027-06-22T09:57:28Z` (1-year rotation deadline) |
| `identity.json.operator_identity_pubkey_fingerprint` | `SHA256:rQZNC53Jdp3Cgi0XXbFT+aLWOtB8eS0Iv6jQ7KazvIY` (= **unchanged** from first-pass) |
| `cycles-history.json.cycles.leaf_source_sha256` | `3170d1405f411d3840b3c59684b6fd16f2bd52f46acd997de993171eb3ead60f` |
| `cycles-history.json.cycles.leaf_count` | `1` |
| `cycles-history.json.cycles.branch_root` | `3170d1405f411d3840b3c59684b6fd16f2bd52f46acd997de993171eb3ead60f` (= single-leaf branch root = sha256 of the leaf line) |
| `cycles-history.json.identity.branch_root` | `0021e4d21564c3ed5ccfbdd836d11e805b8b667d0b200f9cc55e3133a18c5856` (unchanged) |
| `selection-evidence/index.html` identity binding status | `live (manifest) · scheduled (anchor)` + status `Active` (EN), 同等 (JA) |
| `docs/EVIDENCE_MANIFEST.md` identity entry | live, with companion artifact list |
| CI workflow `verify-identity.yml` line 67–70 | `jq empty "$JSON" >/dev/null` (+ inline comment cross-linking gen-identity.sh §4) |

## 5. Verification matrix (= what an auditor can reproduce **today**)

| # | Check | Command | Expected | Observed |
|---|---|---|---|---|
| V1 | live identity.json fetch + parse | `curl -sS https://metal.freedom-yield.com/api/identity.json \| jq -r .dag_root_hash` | `0bd4e667…` | ✅ |
| V2 | live cycles-history.json parity | `curl -sS https://metal.freedom-yield.com/api/cycles-history.json \| jq -r .dag_root_hash` | matches V1 | ✅ |
| V3 | live signature verify | `ssh-keygen -Y verify -f <(printf 'freedom-yield %s\n' "$(curl -sS .../.well-known/operator-identity.pub)") -I freedom-yield -n freedom-yield/validator-identity -s <(curl -sS .../identity.json.sig) < <(curl -sS .../identity.json)` | `Good "freedom-yield/validator-identity" signature for freedom-yield with ED25519 key SHA256:rQZNC53Jdp…` | ✅ |
| V4 | cycles_branch_root reproducibility | `curl -sS .../api/cycle-history.jsonl \| shasum -a 256` | `3170d1405…` (= matches `cycles-history.json.cycles.branch_root`) | ✅ |
| V5 | EN selection-evidence status text | grep on live HTML | `<span class="data-tag">live (manifest) · scheduled (anchor)</span>` present | ✅ |
| V6 | JA selection-evidence status text | grep on live HTML | `状態</dt><dd>Active — identity.json + identity.json.sig は 2026-06-22(Phase 5 publication)以降 live` | ✅ |
| V7 | CI workflow pass on the new commit | `gh run view 27945337707` | success | ✅ |
| V8 | Edge cache freshness | `curl -I .../api/identity.json` → check `last-modified` | `last-modified` advanced past 06:28:51 GMT | `Mon, 22 Jun 2026 10:11:09 GMT` ✅ |

The full nine-step verifier recipe (`IDENTITY_VERIFICATION.md`) also applies and yields the same conclusion. V1–V8 above are a subset specific to this regeneration.

## 6. Risks + mitigations

### 6.1 Stale `dag_root_hash` cached at the edge

Cloudflare serves the JSON artifacts with `cache-control: public, max-age=120, must-revalidate`. A verifier who fetched `identity.json` between 06:28:51Z (= first-pass) and 10:11:09 GMT (= deploy `last-modified`) and cached the value locally may have an out-of-date `dag_root_hash`. This is acceptable because (i) Phase α is an explicit **snapshot model**, not a heartbeat, and (ii) the new manifest carries a strictly later `generated_at`, so any sane verifier will treat the newer snapshot as authoritative.

### 6.2 CI verifier was silently broken before this execution

The `jq -e empty` trap meant `verify-identity-manifest` would have failed for **any** valid `identity.json` push, including the first-pass `0f73b3d` commit. Inspection of run history confirms the workflow was indeed red for `0f73b3d` and stayed red across intermediate site changes (`4c2d4d3` through `808a533`). It is now green from `8aec993` onward. This is a defect-in-defenders, not an issue with the manifest itself, but it does mean an auditor relying on CI status as a gate prior to today's hotfix was getting a false negative. **Mitigation:** any prior auditor who treated the red CI as evidence of a problem should re-evaluate against the current green state.

### 6.3 Concept drift between artifact and surrounding documentation

The first-pass commit declared identity manifest "live" in the artifact (`identity.json`) but left `selection-evidence/` and `EVIDENCE_MANIFEST.md` describing it as "(in preparation)". This regeneration propagates the live status to those surfaces, eliminating the drift. **Mitigation:** the operator's standing rule is to grep the full surface for the old wording before declaring a concept change complete; that grep was performed during this execution and three lingering "(in preparation)" / "準備中" matches were intentionally retained because they describe distinct artifacts (`cycle-history.jsonl` runtime feed, DR drill report, formal exit runbook) that genuinely are not yet live.

### 6.4 Operator identity private key never leaves local Mac

The signing step (`ssh-keygen -Y sign`) ran on the operator's local Mac. The private key is encrypted at rest with a passphrase held in the operator's password manager and is not present on the validator host, the web host, the CI runner, or any cloud system. No transit of the private key occurred during this execution. The `.pub` is the only key material published.

### 6.5 Irreversibility

This is a **public repository**. The `5be649a` and `8aec993` commits are now permanent in the git history of `https://github.com/freedomyield/metal.freedom-yield.com`. Reversion is possible only by a forward commit; the original `5be649a` content cannot be erased without an orphan-reset of the entire history. No remediation is needed since the contents are intentional and verified, but this is acknowledged for the audit record.

## 7. What an auditor **cannot** verify until cycle 3 start

The on-chain anchor receipt (`/api/anchor-receipt.json`) and the corresponding Metal A-chain transaction with memo `fyid1:0bd4e667…` are scheduled to be produced automatically by `watch-anchor-events.sh` on the validator host at the cycle 2 → cycle 3 transition (2026-07-04 13:00 JST). Until then:

- The runtime `/api/anchor-receipt.json` URL is intentionally absent (= verifier recipe step 5 returns 404 by design).
- The selection-evidence page labels this as `scheduled (anchor)` to set expectations correctly.
- The `metalfreedom@anchor` permission is already deployed on Metal A-chain (= test broadcasts `94446328…` and `e67f385b…` verified on explorer).

## 8. Open items (= surfaced during this execution but deferred)

| Item | Reason for deferral | Suggested handler |
|---|---|---|
| `public/delegate/index.html` + `public/ja/delegate/index.html` hero status (`"preparing for registration"` / `"登録準備中"`) contradicts the verified on-chain state (validator has been active since 2026-05-19 with one large delegation already accepted) | Independent concern (= validator-state accuracy, not identity manifest). Separate commit keeps scopes clean. | Operator-approved single-purpose commit, future session |
| `selection-evidence/` machine-readable discovery line still points to `/api/evidence.json → .in_preparation_artifacts.identity_manifest` despite identity_manifest now being live | `/api/evidence.json` runtime endpoint is itself not yet published; the line should be updated when evidence.json runtime publishing is in scope | Track with evidence.json runtime publication work |

## 9. Sign-off

This execution was carried out under the operator-approved workflow defined in `docs/CONSTITUTION.md` and `docs/OPERATING_MODEL.md`: AI proposed (= drafted the commit, ran integrity checks, surfaced the CI false-fail and the propagation gap), operator approved (= entered the passphrase, authorised the push, confirmed the live verify result), and the AI verified the post-state matches expectations against the spec in `docs/MERKLE_DAG_SPEC.md`.

The execution record is complete. The Phase α second-pass regeneration met its objective (`cycles_branch` populated with cycle 1, identity manifest declared live across the public site, CI gates green) and surfaced one defect-in-defender (`jq -e empty` in CI) that was resolved within the same execution window.

— Recorded 2026-06-22 (UTC), Freedom Yield Metal Blockchain validator project.
