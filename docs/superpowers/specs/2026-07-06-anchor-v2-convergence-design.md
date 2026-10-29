# Anchor v2 convergence (design-debt ③ + ④) — design

**Goal:** finish the migration to the v2 3-branch anchor contract by (a) propagating the
already-done code fix for ③ into the authoritative external docs, and (b) physically retiring
the dead host-side auto-broadcast code for ④, so no path, test, or doc still presents the
retired 2-branch `fyid1:` model as canonical.

**Status of the two items (verified 2026-07-06):**
- **③ two DAG roots — code-resolved, doc-lagging.** `79ed3be` removed `dag_root_hash` from
  `identity.json`; the single on-chain root is `anchor-source.json .dag_root_computed`
  (3-branch), surfaced as `anchor-receipt.json .dag_root_hash`. Residual: the live *signed*
  `identity.json` still carries the old field and self-heals at cycle-4 regen (no code change).
  **The gap is docs:** `MERKLE_DAG_SPEC.md` and `IDENTITY_VERIFICATION.md` still describe the
  2-branch `fyid1:` DAG as the on-chain commitment.
- **④ legacy/v2 half-migration — operationally neutralized, structurally present.** Production
  cron dispatches to alert-only `notify-anchor-transition.sh` (broadcasts nothing), so the
  stranded auto-broadcast cannot fire. But `post-anchor-event.sh` (positional → v2 signer
  rejects, exit 1), `resume-after-cycle-start.sh` Phase 1/3/4 (`fyid1:` memo + retired
  identity-dag checks), and the `watch-anchor-events.sh:77` default driver still point at the
  dead path — and legacy-contract test stubs keep it green.

## The v2 path that MUST be preserved (do not touch)

Four flag-based scripts, orchestrated by `run-anchor-pipeline.sh` (single-box) or split across
machines (compose on validator host / **sign on Mac only** / receipt on host):
1. `gen-anchor-source.sh` → `anchor-source.json` (3-branch `dag_root_computed`).
2. `sign-anchor-event.sh --chain=… --anchor-source=…` → 4 actions via `bin/safe-broadcast`
   (4 gates); host-side fails closed (exit 7) where no proton key. **Broadcast stays here.**
3. `gen-anchor-receipt.sh` → 7-PASS verify → `anchor-receipt.json`.
4. `append-anchor-history.sh` → `anchor-history.jsonl`.
Detection-only companion: `watch-anchor-events.sh` → `notify-anchor-transition.sh` (ntfy).

## Retirement design (recommended)

1. **Delete `post-anchor-event.sh`** (its entire `SIGNER` machinery is the dead positional
   path). Preserve its only live concern — none broadcast-related; confirm the cycle-gate
   "deferred" note (`:365`) has no live reader before deletion.
2. **Gut `resume-after-cycle-start.sh`**: delete Phase 3 (host-side sign), Phase 4
   (`fyid1:`/identity-dag verify), and the Phase-1 identity-dag poll. Replace Phase 4 with a
   new **read-only `verify-anchor.sh`** that asserts, against `anchor-receipt.json`:
   `memo == "fya<S>c<N>:" + anchor-source.dag_root_computed`, all 4 memos present, actor +
   permission — **no `fyid1:` constant, no identity-dag compare, no signing, no broadcast.**
3. **Flip `watch-anchor-events.sh:77`** default `DRIVER` to `notify-anchor-transition.sh`
   (or drop the default) so nothing depends on the alert-only cron env being set.
4. **`cycle-gate.sh` state coupling:** it reads `approved_dag_root_hash` from a state file only
   `resume` wrote. Repoint the writer to `verify-anchor.sh` (or confirm the passive gate is not
   gating anything live and drop the coupling). Fail-closed must not become fail-forever.
5. **Tests:** delete/retarget the legacy-contract suites that keep the dead path green —
   `tests/post-anchor-event/`, `tests/cycle-gate/mock-signer.sh`, the 2-branch/`fyid1:` vectors
   in `tests/identity-verification-vectors/` and `tests/anchor-history/` fixtures. Add a test
   for `verify-anchor.sh`.
6. **Docs — rewrite to v2 3-branch (highest external value):** `MERKLE_DAG_SPEC.md`,
   `IDENTITY_VERIFICATION.md`, plus SOP references in `CYCLE_GATE.md`,
   `OPERATOR_IDENTITY_SETUP.md`, `PHASE*` docs, and the Phase-β contract spec. Anyone following
   the published SOP must compute the **3-branch** root and the `fya<S>c<N>:` memo.

## Non-goals
- No change to the live v2 signing/broadcast path (§ "MUST be preserved").
- No history rewrite; no live-`identity.json` edit (self-heals at cycle-4).
- `run-anchor-pipeline.sh` stays (it is the correct v2 orchestrator, not dead code).

## Sequencing
Docs propagation (③) is independent and highest external-value → can land first.
Code retirement (④) = delete dead code + `verify-anchor.sh` + flip driver + cycle-gate repoint,
paired with its test retargeting (must be one change so the suite never goes green-on-dead).
Doc SOP rewrite for ④ folds into the ③ doc pass.

## Testing
- New `tests/verify-anchor/` for `verify-anchor.sh` (v2 receipt PASS, `fyid1:`/wrong-dag FAIL).
- Deleted suites: assert the retired scripts are gone (no dangling references in cron installers).
- `cycle-gate.sh` regression: state written by the new writer, fail-closed still fires on missing.
