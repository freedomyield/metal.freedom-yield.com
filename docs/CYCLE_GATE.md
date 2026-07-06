# Cycle gate — passive defer / active resume for cycle transitions

> **Status (= 2026-07-06)**: v2 rewrite. This document describes the **live**
> model: the single 3-branch `anchor-source.json` DAG (`dag_root_computed`,
> memo prefix `fya<S>c<N>`), the alert-only watcher driver, and the
> `resume-after-cycle-start.sh` that **no longer broadcasts**. The v1 model
> this replaces (2-branch `cycles-history.json` / `dag_root_hash` /
> `fyid1:` memo / `post-anchor-event.sh` auto-broadcast) was retired across
> 2026-07-04 .. 2026-07-06 (design-stocktake #1/#3/#4; see
> `docs/audits/constitution-2026-07-04-design-stocktake.md`). For the v1
> design as originally deployed on 2026-06-29, see this file's git history.

## What problem this solves

A validator cycle transition (one AddValidator entry expiring, the next one
committing) is a window in which cycle-dependent automation can act on stale
state. The gate design removes two failure modes:

- **Cycle-aware alerts firing mid-transition.** The 5-minute anomaly tick
  observes the validator disappearing at cycle end — expected, not an
  incident. Alert automation must know whether the operator has acknowledged
  the new cycle.
- **Any future cycle-gated side effect running before the operator's
  approval state catches up.** The gate makes "safe to fire" a property of
  explicit approval state, not of cron-enable/disable scheduling that a
  human can forget.

What this design **no longer** does: gate or trigger the anchor broadcast.
In the v2 model the anchor inscription is produced by a separate,
operator-driven signing pipeline (below) whose safety rests on the PRIME
DIRECTIVE 4-gate discipline and `bin/safe-broadcast` — not on cron state.
There is deliberately **no** automated path from "cycle transition
observed" to "broadcast".

## Architecture

Two components, separated by direction:

```
[ passive auto-defer ]                    [ active operator resume ]
  scripts/cycle-gate.sh                     scripts/resume-after-cycle-start.sh
  (= consulted by cron scripts)             (= invoked once per cycle)
        │                                          │
        │ reads                                    │ writes
        ▼                                          ▼
   ${FY_STATE_DIR}/cycle-gate-state.json
   {
     "schemaVersion": 1,
     "approved_cycle_signature": "<NodeID>-<startTime_epoch>",
     "approved_dag_root_hash":   "<64-hex>",
     "approved_at":              "<ISO 8601 UTC>"
   }
```

`cycle-gate.sh` is **passive**: it answers a yes/no question for the caller —
"is the cycle currently visible on chain the one the operator approved?".

`resume-after-cycle-start.sh` is **active**: run once per cycle after the new
AddValidator entry is Committed. It verifies the new cycle on chain and the
published artifacts, then atomically updates the state file. It performs
**no broadcast**.

The 5-minute crons keep firing with no operator enable/disable action.
Between cycle close and operator approval, gated side effects are silently
deferred; after approval they resume on the next tick.

## Separation from the anchor pipeline

The anchor inscription is out of scope for the gate. It is produced by the
v2 four-step pipeline (`scripts/run-anchor-pipeline.sh` orchestrates):

```
1. gen-anchor-source.sh      compose anchor-source.json      (validator host)
2. sign-anchor-event.sh      compose + sign + broadcast the   (operator Mac ONLY —
                             4-action pack via bin/safe-broadcast   signing-host assertion, exit 7)
3. gen-anchor-receipt.sh     fetch tx + 7-gate verify + receipt    (validator host)
4. append-anchor-history.sh  append to anchor-history.jsonl        (validator host)
```

- The inscribed value is `anchor-source.json .dag_root_computed` (3-branch:
  `identity_branch` / `observations_branch` / `artifacts_branch`), carried in
  four `eosio.token::transfer` memos: `fya<S>c<N>-id:`, `-ob:`, `-ar:`, and
  the pivot `fya<S>c<N>:<dag_root_computed>`.
- Broadcast safety = PRIME DIRECTIVE 4 gates enforced by `bin/safe-broadcast`
  + per-invocation operator authorization. Never cron-triggered.
- The event watcher (`watch-anchor-events.sh`, 5-minute cron) dispatches
  transitions to `scripts/notify-anchor-transition.sh` — an **alert-only**
  driver that fires an ntfy push and **broadcasts nothing**. It exists so the
  operator learns "cycle transition observed; run the pipeline when ready".

## State file schema

`${FY_STATE_DIR}/cycle-gate-state.json` (default `${FY_STATE_DIR}` =
`/var/lib/freedom-yield`).

| field | type | meaning |
| --- | --- | --- |
| `schemaVersion` | integer | currently `1`. Bump on incompatible format change. |
| `approved_cycle_signature` | string | `<NodeID>-<startTime_epoch>`. Uniquely identifies the validator entry on chain that this approval covers. Two distinct AddValidator transactions produce two distinct startTime values, so the signature changes per cycle. |
| `approved_dag_root_hash` | 64-hex string | The `anchor-source.json .dag_root_computed` observed at approval time. (Field name retained from schemaVersion 1 for compatibility; since the v2 migration the stored value is the 3-branch `dag_root_computed`.) |
| `approved_at` | ISO 8601 UTC string | Wall-clock time the approval was written. Diagnostic only; not consumed by gate logic. |

File mode is `0644`. The file contains no SECRET-class data — both values are
public on chain.

When the file is absent (= first deploy, or after manual `rm` for rollback)
`cycle-gate.sh` returns green for every side-effect type — the backward-compat
behavior that preserves the pre-gate cron flow.

## `cycle-gate.sh`

Consulted by cron scripts immediately before a cycle-dependent side effect.

```sh
scripts/cycle-gate.sh --side-effect=<type>
```

| `--side-effect` value | semantics | live consumers |
| --- | --- | --- |
| `cycle-artifact-write` | Write to a cycle-recording artifact. **Always green** — recording a *closed* cycle is backward-looking and can never be premature. Gating it caused the 2026-07-04 transition deadlock (design-stocktake trouble #2); ungated since. Kept as a declared type for the distinct log marker. | `gen-cycle-history.sh`, `uptime-history.sh` (Job B), `node-info.sh`, `gen-evidence.sh`, `gen-renewal-ics.sh`, `prep-cycle-anchor-recording.sh` |
| `cycle-aware-notify` | Validator-presence-based notification (ntfy). Signature-gated: deferred while the on-chain cycle differs from the approved one, so transition-window noise is suppressed until the operator acknowledges the new cycle. | `check-anomalies.sh`, `daily-status.sh` |
| `broadcast` | A-chain inscription (IRREV). Signature-gated. **No current consumer** — the v1 consumer (`post-anchor-event.sh`) was retired; the v2 pipeline does not consult the gate (its safety layer is `bin/safe-broadcast`). The type is retained defensively: any future automation declaring `--side-effect=broadcast` inherits fail-closed gating. | (none) |
| `observe` | Read-only observation. Always green; lets call-sites declare intent uniformly. | (declared only) |

Exit codes:

| code | meaning |
| --- | --- |
| `0` | green — side effect safe to execute |
| `1` | deferred — transition window or unapproved cycle; skip the side effect |
| `2` | usage error |

Behavior matrix (= invariants):

| state | broadcast / cycle-aware-notify | cycle-artifact-write / observe |
| --- | --- | --- |
| state file absent | green (backward compat) | green |
| state matches chain signature | green | green |
| state mismatch chain signature | deferred | green |
| state file corrupt | fail-closed (deferred) | green |
| metalgo RPC unreachable | fail-closed (deferred) | green |
| validator absent from chain | deferred | green |

The RPC timeout default is `${FY_RPC_TIMEOUT:-6}` seconds. Setting it via env
at call time lets test harnesses fail fast without depending on the system
default.

## `resume-after-cycle-start.sh`

Single command run once per cycle, after AddValidator is Committed and the
freshly published artifacts are live.

```sh
scripts/resume-after-cycle-start.sh --dry-run    # verify only
scripts/resume-after-cycle-start.sh --apply      # full sequence
```

Phases:

1. **Phase 1 — verify.** Query metalgo RPC for the current validator entry,
   derive the cycle signature, idempotency-check against the prior approved
   signature, poll `${PUBLIC_BASE}/api/anchor-source.json` until its
   `dag_root_computed` differs from the prior approved value (max
   `${FY_POLL_MAX_SEC:-600}` seconds at `${FY_POLL_INTERVAL:-30}` second
   intervals), and verify the published `identity.json` signature via
   `ssh-keygen -Y verify`. Phase 1 has no side effects.
2. **Phase 2 — atomic state write.** Compose the new `cycle-gate-state.json`
   via `jq -n` to a `.new` tempfile, then `mv` over the live file. Atomic on
   POSIX (same dir).
3. **Phase 3 — report.** Print a one-block summary of the final state. Exit 0.

The v1 Phase 3 (broadcast trigger) and Phase 4 (`fyid1:` receipt field-match)
were removed in the v2 migration: the anchor pipeline broadcasts under its own
4-gate discipline, and `gen-anchor-receipt.sh` already verifies the four v2
memos + `dag_root_computed` at receipt time, so a second post-hoc check here
was redundant.

Exit codes:

| code | meaning |
| --- | --- |
| `0` | PASS — state updated; OR `--dry-run` Phase 1 verification succeeded; OR idempotent skip |
| `1` | usage error |
| `2` | Phase 1 verification failed |
| `3` | Phase 1 polling timeout (= anchor-source.json never went fresh) |
| `4` | Phase 2 state write failed |

`--dry-run` runs only Phase 1; Phase 2 emits a "would write" log line instead.

## Operator runbook (= cycle transitions, model α)

Under model α (= AI full orchestration; see
`feedback_ai_full_orchestration_default` memo), the operator's active steps:

1. Operator asks AI to drive the cycle transition.
2. Operator, when AI signals it is the moment, performs the wallet flow in
   Metal Wallet web — collect METAL, fund the validator account, cross-chain
   to P-chain, submit AddValidator, confirm on-chain Committed. AI verifies
   on-chain state in parallel.
3. Operator, when AI prompts, enters the proton-cli keystore password (= for
   `proton key:unlock`, **required before signing** — see the keystore lock
   quirk memo) and the operator-identity-key passphrase (= for
   `gen-identity.sh`). AI handles every shell command around those prompts.
4. Operator authorizes the mainnet anchor broadcast **per invocation**
   (naming chain / actor / permission / action / memo / quantity — PRIME
   DIRECTIVE gate 2), then visually verifies the explorer URL AI reports
   back. Done.

AI's work around those steps:

- validator host: cycle-recording refresh (`uptime-history.sh`,
  `gen-cycle-history.sh`, feed pushes) — these pass the always-green
  `cycle-artifact-write` gate.
- Mac local: `gen-identity.sh` (with `FY_EXPECT_CYCLE` ordering guard),
  commit, push; `gh run watch` until deploy completes.
- validator host: `gen-anchor-source.sh` (compose). Mac:
  `sign-anchor-event.sh` via the pipeline (testnet first, then mainnet after
  gate-2 authorization). validator host: `gen-anchor-receipt.sh` 7-gate
  verify + `append-anchor-history.sh`.
- validator host: `resume-after-cycle-start.sh --apply` → cycle-aware alerts
  resume for the new cycle.
- Read back the summary, report the explorer URL to the operator.

## Emergency fallback (= AI unavailable)

If the operator must drive the transition without AI assistance:

1. Operator does the wallet flow + Mac `gen-identity.sh` + commit + push as
   usual, and runs the anchor pipeline manually (testnet-first; mainnet only
   with all four PRIME DIRECTIVE gates satisfied).
2. After `git push`, wait for the GitHub Actions Deploy workflow to finish.
3. SSH the validator host and run:

   ```sh
   ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
       'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --apply'
   ```

Phase 1 polling tolerates uncertain deploy timing: it polls up to 10 minutes
for `anchor-source.json` to refresh before failing. To sanity-check first,
substitute `--dry-run` for `--apply`.

## Rollback

Independent rollback levers, in increasing severity:

1. **Disable approval enforcement temporarily**:
   `rm /var/lib/freedom-yield/cycle-gate-state.json`. `cycle-gate.sh` returns
   green for every consultation until the next
   `resume-after-cycle-start.sh --apply` recreates the file.
2. **Disable gate consultation entirely**:
   `chmod -x /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh`.
   Consumers detect the non-executable gate and fail closed per their own
   handling (alert consumers suppress; artifact writers skip or proceed per
   their declared type). Reverse with `chmod +x`.
3. **Remove the design entirely**: delete `scripts/cycle-gate.sh` and
   `scripts/resume-after-cycle-start.sh` and drop the consultation blocks
   from the consumer scripts. Use only if a fundamental design issue is
   found.

The state file is regenerable from any chain-visible cycle, so accidental
deletion is not a data-loss event.

## Test coverage

`tests/cycle-gate/run-tests.sh` exercises the deterministic state-machine
behavior (green / deferred / fail-closed per side-effect type, idempotent
resume skip, resume against unreachable RPC) using a Python HTTP mock for
metalgo RPC + web-host responses. The repo-wide suite runs via
`bash tests/run-all-tests.sh`.

Not covered here (covered elsewhere):

- identity.json signature verification against a real key — covered by the
  operator-Mac `gen-identity.sh` self-verify at signing time.
- A-chain broadcast — covered by the anchor pipeline's own testnet-first
  rehearsals and `gen-anchor-receipt.sh` 7-gate verification.

## Constitution alignment

- **§2 #1 validator health**: `cycle-gate.sh` hits metalgo RPC once per
  consultation (= same query as the existing 5-minute anomaly tick, no
  incremental load). `resume-after-cycle-start.sh` runs at most once per
  cycle.
- **§3.3**: neither script reads or writes any SECRET-class data.
- **§5 / PRIME DIRECTIVE**: the gate has no broadcast path. The anchor
  pipeline's mainnet broadcast requires testnet-first success, per-invocation
  operator authorization, pre-flight chain verification, and exhausted
  dry-run options — enforced by `bin/safe-broadcast` and the tiered
  broadcast-enforcement stack.

## Related

- `docs/ANCHOR_SOURCE.md` — the 3-branch anchor-source contract (single DAG
  source of truth).
- `docs/MERKLE_DAG_SPEC.md` — canonical hashing spec (`jq -cS`, trailing
  newline included).
- `docs/IDENTITY_VERIFICATION.md` — the public seven-step verification
  recipe.
- `docs/audits/constitution-2026-07-04-design-stocktake.md` — the design
  stocktake that drove the v1 → v2 collapse.
- `docs/VALIDATOR_RENEWAL.md` — operator-facing renewal SOP.
