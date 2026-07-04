# Constitution Audit + Design Stock-take — 2026-07-04

**Trigger:** `/constitution-audit --review=thorough` after the cycle-3 mainnet anchor (operator rated the production run 50/100). Read-only; no file/host mutated, no broadcast. Auditor: `constitution-auditor` agent. Range `e71b1ac..HEAD` (session = 6 commits `70ac4ce..71bb2e8`). This document is the persisted record; findings must be independently verified before implementation (`superpowers:receiving-code-review`).

## Summary

- **Overall: 🟡 YELLOW.** Zero Constitution 🔴 violations in the session (no unauthorized broadcast, no secret literals, Prime Directive intact, new scripts alert-only/read-only). But the anchor + cycle-gate **subsystem carries multiple latent correctness-level design defects** that would block or corrupt a future automated anchor. Compliance is fine; the *design* is not. The 50/100 rating is accurate, if generous.
- **Single root cause:** the cycle-gate + auto-broadcast subsystem was built for the pre-2026-07-01 world (single-action `fyid1:<dag_root_hash>` memo, Hetzner-side signing, identity.json's dag as the inscribed value) and was **never migrated** when three things changed: (a) the v2 3-branch `fya<S>c<N>` scheme, (b) Mac-only signing (post-accident control), (c) the split into `anchor-source.json`.

## Part 1 — Constitution compliance (D1–D10)

| Dim | Verdict | Note |
|---|---|---|
| D1 PRIME DIRECTIVE 4-gate | ✅ | `bin/safe-broadcast:13,57` enforces; session added no broadcast path |
| D2 broadcast-shape capture | ✅ | `broadcast-guard.sh:80-88` covers proton/cleos/curl shapes; marker gate L124 |
| D3 secrets | ⚠ | session clean (only generic "operator" noun). 1 pre-existing gitleaks hit UNVERIFIED — operator to run `gitleaks detect --no-git -v` |
| D4 10-axis anchor coverage | N/A | not in session scope |
| D5 schemaVersion consistency | ✅ | cycle-gate.sh:112-120 / resume:267 / post-anchor:400 all v1 |
| D6 heading nesting | N/A | no .md in diff |
| D7 inline `style=` | ✅ | 0 hits |
| D8 single-purpose commits | ✅ | 6 commits each single subject |
| D9 TOOLKIT.md sync | 🟡 | 25/44 scripts absent from TOOLKIT.md (systemic, pre-existing) |
| D10 OPERATING_MODEL W-refs | — | not re-verified this run |

## Part 2 — Code review (C1–C12), session diff (9 files, +535/−17)

- ✅ C1 (only generic "operator"), C2 (preview only *prints* the STAGE-2 cmd, does not run it), C4 (`set -euo pipefail` in all 4 new scripts), C7 (modes correct), C12 (no audit-doc in-place edit).
- 🟡 C8 (only `notify-anchor-transition.sh` has a test; `prep-`/`preview-`/`install-` have none), C9 (4 new scripts missing from TOOLKIT.md), C11 (`preview-…` vague `~5 min` comment marker).
- **Concrete bug:** `prep-cycle-anchor-recording.sh:192,195,196` call **`push-to-xserver.sh`, which does not exist** (renamed to `push-to-web-host.sh`). Same dead reference pre-exists in `check-anchor-publish-health.sh:71`, `install-xserver-anchor-source-allowlist.sh:138`, `install-metal-anchor-publish-health-cron.sh:29`. **Verified 2026-07-04:** file absent; but cycle-2 data IS published + fresh on the public origin (the regular crons republish via the correct `push-to-web-host.sh`), so no data loss — the bug is latent.

## Part 3 — Design stock-take: the 7 production troubles

| # | Trouble | Class | Root cause (file:line) | Refactor |
|---|---|---|---|---|
| 1 | gen-identity ran before cycle-2 recorded → DAG didn't advance | **design** | no ordering guard; `gen-identity.sh:677-678` prints confident dag/memo over stale `cycle-history.jsonl` | assert freshness before emitting: abort unless last `cycle-history.jsonl` cycle_n == expected closed cycle |
| 2 | cycle-gate deadlock at transition | **design** | `cycle-gate.sh:68-69,160-166` routes `cycle-artifact-write` through the *same* signature gate as `broadcast`; at transition `OBS_SIG != APPROVED_SIG` wrongly defers the backward-looking record | **ungate `cycle-artifact-write` (always green)**; keep signature gate only on `broadcast`. Deletes the deadlock + retires `prep-…` |
| 3 | two DAG roots | **design** | `identity.json .dag_root_hash=c205c51b` = 2-branch (`gen-identity.sh:392`); `anchor-source.json .dag_root_computed=1862466b` = 3-branch (`gen-anchor-source.sh:470-473`) = the inscribed value. identity artifacts point to a root not on chain; `gen-identity.sh:678` prints retired `fyid1:` | **collapse to one DAG**: identity carries anchor-source's value (or drops its own); delete the `fyid1:` print |
| 4 | legacy/v2 half-migration | **design** | `post-anchor-event.sh:416` positional args → v2 flag-only `sign-anchor-event.sh:109-129` exit 1; `resume-…:357` `fyid1:` memo check + `:371` identity-dag check can never pass a v2 receipt. Documented SOP (`resume --apply`, `CYCLE_GATE.md:40,94-99`) cannot produce a valid v2 anchor | retire `post-anchor-event` signer path + `resume` Phase 3/4, or rewrite to v2 contract (read expected memo/dag from anchor-source, not constants) |
| 5 | Mac-only signing vs Hetzner pipeline | **arch mismatch** | key only in Mac keystore; `run-anchor-pipeline.sh`, `resume` Phase 3, anchor-watch cron all sign host-side (`post-anchor-event.sh:426`) — no key on Hetzner. Auto-broadcast half is dead code on the wrong host | accept the constraint as the axis: host detects/composes, Mac signs/broadcasts, host publishes. `notify-anchor-transition.sh` is the correct seed |
| 6 | stale-file / propagation gap | **design** | `push-to-web-host.sh` allowlist lacks `identity.json`/`anchor-source.json`/`cycles-history.json`; they reach public only via git-deploy, so host regen never propagates. `resume-…:167-199` polls `PUBLIC_BASE/api/identity.json` — a file the host can't push (hence the local-Caddy workaround) | pick ONE path: git-deploy-only for identity artifacts, and drop host-side polling of them |
| 7 | testnet rehearsal blind spots | **test-scope** | S11 validated only the 4-action memo *shape*; every real failure was integration/wiring/ordering/host — invisible to unit tests | add an end-to-end test that runs the documented runbook against stubs |

## Part 4 — Minimal clean design (under immovable Mac-only signing)

- **Single source of truth: `anchor-source.json`** (3-branch `dag_root_computed`). Everything references it; identity stops computing an independent root.
- **Three roles, one direction:** Host (Hetzner) = **compose + detect only** (holds no key, never broadcasts); Mac = **sign + broadcast** (one script: assert ordering → regen anchor-source → `sign-anchor-event --chain=mainnet-a` through safe-broadcast 4 gates → commit receipt + git-deploy); a small read-only **`verify-anchor.sh`** replaces resume Phase 4 (assert `receipt.memo == "fya<S>c<N>:" + anchor-source.dag_root_computed`, 4 memos present, actor/permission — no `fyid1:` constant, no identity-dag compare).
- **Delete:** cycle-gate's `broadcast` side-effect + `cycle-gate-state.json` approval dance; `post-anchor-event.sh` signer path; `resume` Phases 3–4; `run-anchor-pipeline.sh` host signing; `prep-cycle-anchor-recording.sh` (once artifact-write is ungated). `cycle-gate.sh` collapses to: `cycle-artifact-write` = always green, `broadcast` = removed. Dissolves troubles #2, #4, #5 at once.
- **Three enforced invariants** (replace the 7-condition theater): ordering (abort unless closed cycle recorded), one-root (`identity.dag == anchor-source.dag_root_computed`), signing-host assertion (fail-closed if run without the local key).

## Part 5 — Test-scope gap

The suite tests **units in isolation with correct inputs**; every real failure was an **integration/wiring/ordering/host defect** unit tests are blind to. Missing layers: end-to-end runbook test (run `resume --apply` against stubs — would fail on day one), signing-host assertion test, cross-artifact dag-reconciliation test (`identity.dag == anchor-source.dag == receipt.dag`), transition-sequence test.

## Part 6 — Prioritized recommendations

**MUST FIX (a future anchor is blocked/corrupted without these):**
1. `[design]` Collapse the two DAG roots (`identity.dag == anchor-source.dag_root_computed`); delete `gen-identity.sh:678` `fyid1:` print. *M / low.*
2. `[design]` Ungate `cycle-artifact-write` in `cycle-gate.sh` (unconditional green); signature gate only on broadcast. *S / low — dissolves the deadlock, retires prep-.*
3. `[design]` Retire the stranded auto-broadcast path (`post-anchor-event` signer, `resume` Phase 3/4, `run-anchor-pipeline` host signing); standardize on Mac-sign / host-alert-only. *L / medium — kills #4 + #5.*
4. `[bug]` Fix the `push-to-xserver.sh` dead reference (prep-… + 3 other callers) → `push-to-web-host.sh`. *S / low.*
5. `[design]` Resolve the identity-artifact propagation gap (git-deploy-only; drop host polling + local-Caddy workaround). *M / medium.*

**SHOULD FIX:**
6. `[design]` Add the record→regen→sign ordering guard to `gen-identity.sh` + signing-host assertion to the sign step. *M / low.*
7. `[test]` End-to-end runbook integration test + cross-artifact dag-reconciliation test + signing-host-negative test. *M / low — the layer that would have caught almost everything.*
8. `[doc]` Rewrite `docs/CYCLE_GATE.md` + anchor runbook to the Mac-sign model. *M.*

**HOUSEKEEPING:**
9. `[doc]` TOOLKIT.md — add the 25 missing scripts. *S.*
10. `[compliance]` Clear the 1 gitleaks hit (`gitleaks detect --no-git -v`). *S.*
11. Minor: drop `preview-…` `~5 min` marker; add tests for prep-/preview-/install- or mark one-shot.

## Session-edit assessment

- **`notify-anchor-transition.sh` + `watch-anchor-events.sh:77` + `install-anchor-watch-alert-only.sh` + its test — KEEPERS** (the correct host-detects / Mac-signs architecture; clean, tested, fail-safe).
- **`preview-cycle3-anchor-broadcast.sh` — KEEPER** (read-only STAGE-1 verifier; fold into future `verify-anchor.sh`).
- **`prep-cycle-anchor-recording.sh` — SYMPTOMATIC PATCH** (exists only to hole-punch trouble #2; delete once recommendation #2 lands; also ships the push-to-xserver bug).
