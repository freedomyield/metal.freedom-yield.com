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

The anchor inscription is out of scope for the gate. `scripts/run-anchor-pipeline.sh`
exists as a single-host orchestrator for its four steps, but it **cannot run
end-to-end as one invocation** under the live topology: signing is Mac-only
(the anchor key never leaves the operator's Mac; `sign-anchor-event.sh`
refuses with exit 7 on any host that fails its signing-host assertion), while
composing and receipt-verification run on the validator host. In practice the
steps are run **manually, split across host and Mac**, with a git
commit/push/deploy hop in between so the Mac's local checkout sees the
host-composed `anchor-source.json`:

```
1. gen-anchor-source.sh          compose anchor-source.json           (validator host)
2. commit-anchor-source.sh       verify + commit anchor-source.json;   (operator Mac —
   (scripts/operator-local/)     push + deploy in the same step         scripts/operator-local/,
                                                                          never runs on the host)
3. sign-anchor-event.sh          compose + sign + broadcast the        (operator Mac ONLY —
                                  4-action pack via bin/safe-broadcast   signing-host assertion, exit 7)
4. gen-anchor-receipt.sh         fetch tx + 7-gate verify + receipt    (validator host)
5. append-anchor-history.sh      append to anchor-history.jsonl        (validator host)
```

- The inscribed value is `anchor-source.json .dag_root_computed` (3-branch:
  `identity_branch` / `observations_branch` / `artifacts_branch`), carried in
  four `eosio.token::transfer` memos: `fya<S>c<N>-id:`, `-ob:`, `-ar:`, and
  the pivot `fya<S>c<N>:<dag_root_computed>`.
- Broadcast safety = PRIME DIRECTIVE 4 gates enforced by `bin/safe-broadcast`
  + per-invocation operator authorization. Never cron-triggered.
- Step 2's commit + push + deploy is **not optional**: `anchor-source.json`
  is published to the public site by the normal git-deploy path (not rsync),
  so until that deploy lands, `resume-after-cycle-start.sh`'s Phase 1 polling
  (below) never observes a fresh `dag_root_computed` and eventually times out
  with exit 3.
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
| `cycle-artifact-write` | Write to a cycle-recording artifact. **Always green** — recording a *closed* cycle is backward-looking and can never be premature. Gating it caused the 2026-07-04 transition deadlock (design-stocktake trouble #2); ungated since. Kept as a declared type for the distinct log marker. | `gen-cycle-history.sh`, `uptime-history.sh` (Job B), `node-info.sh`, `gen-evidence.sh`, `gen-renewal-ics.sh` |
| `cycle-aware-notify` | Validator-presence-based notification (ntfy). Signature-gated: deferred while the on-chain cycle differs from the approved one, so transition-window noise is suppressed until the operator acknowledges the new cycle. | `check-anomalies.sh`, `daily-status.sh` |
| `broadcast` | A-chain inscription (IRREV). Signature-gated. **No current consumer** — the v1 consumer (`post-anchor-event.sh`) was retired; the v2 pipeline does not consult the gate (its safety layer is `bin/safe-broadcast`). The type is retained defensively: any future automation declaring `--side-effect=broadcast` inherits fail-closed gating. | (none) |
| `observe` | Read-only observation. Always green; lets call-sites declare intent uniformly. | (declared only) |

`scripts/prep-cycle-anchor-recording.sh` also calls `cycle-gate.sh --side-effect=cycle-artifact-write` but is **deprecated** — it hole-punched the old (pre-ungate) transition deadlock and has no remaining purpose now that `cycle-artifact-write` is unconditionally green. **Do not use it on cycle transition day.** It is left in `scripts/` for now and scheduled for deletion once cycle-4 has completed.

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
`feedback_ai_full_orchestration_default` memo), the operator's active steps
are: ask AI to start, do the Metal Wallet web flow, supply two keystore
passwords + the identity-key passphrase when prompted, and authorize the
mainnet anchor broadcast per invocation. Everything else — including which
machine each command runs on — is AI-orchestrated across a **2-host
topology (validator host + operator Mac)**, in this fixed day-of order
(cf. the cycle-3 → cycle-4 transition, `N=3`):

1. **AI/host — wait for the node-info tick.** Poll (or wait for the next
   cron tick of) `node-info.sh` until `public/api/validator.json` reflects
   the new AddValidator entry's `endTime`. This confirms the new cycle is
   actually on chain before any cycle-recording script below runs against
   it — recording against a stale `endTime` would misdate the cycle
   boundary.
2. **host — `uptime-history.sh`** closes out cycle N's uptime record.
3. **host — `gen-cycle-history.sh` + push** appends cycle N's row to the
   published `cycle-history.jsonl`. Verify the published file grew by
   exactly one line.
4. **Mac —**
   ```sh
   FY_EXPECT_CYCLE=<N> OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity \
     bash scripts/operator-local/gen-identity.sh
   ```
   then commit, push, `gh run watch` until deploy completes.
   `FY_EXPECT_CYCLE=<N>` is **mandatory** at a cycle transition (N = the
   cycle that just closed, e.g. `FY_EXPECT_CYCLE=3` at the cycle-3 →
   cycle-4 transition): it hard-stops (exit 7) if step 3's published ledger
   has not caught up yet, turning "record the closed cycle before
   regenerating identity" into a machine-checked precondition instead of
   operator vigilance. Left unset, `gen-identity.sh` still runs (needed for
   first-run / bootstrap) but prints a loud stderr warning that the
   ordering guard is disabled for that run.
5. **host —**
   ```sh
   FY_EXPECT_CYCLE=<N> bash scripts/gen-anchor-source.sh
   ```
   composes the fresh `anchor-source.json` (3-branch DAG) on the validator
   host (cycle-4 day example: `FY_EXPECT_CYCLE=3`). It derives
   `cycle_number_observed` as `CLOSED_COUNT + 1` from the published
   `cycle-history.jsonl` line count, and carries its own ordering guard:
   if `FY_EXPECT_CYCLE` is set and does not match `CLOSED_COUNT` (= step 3
   has not landed on the published ledger yet), it hard-stops with
   **exit 9** before composing anything — checked before the P-chain RPC
   call, so it fails fast even if metalgo is unreachable. Left unset, it
   still runs (needed for first-run / bootstrap) but prints a loud stderr
   warning that the guard is disabled.
   **Exit 9 here is a different condition than `gen-identity.sh`'s exit 7**
   for its analogous guard — the two are not the same number by design:
   `gen-anchor-source.sh`'s own exit 7 already means "atomic write failed"
   (see its header's exit-code table), so its ordering guard had to take a
   different code. Do not read "exit 7" and "exit 9" as the same condition
   just because the two scripts' guards are conceptually parallel.
6. **Mac —**
   ```sh
   bash scripts/operator-local/commit-anchor-source.sh --expect-cycle=<N+1>
   ```
   verifies + commits the host-composed `anchor-source.json` (cycle-4 day
   example: `--expect-cycle=4`). Deliberate meaning switch from step 5:
   `gen-anchor-source.sh`'s `FY_EXPECT_CYCLE` is the closed-cycle count,
   while this script's `--expect-cycle` is the cycle number being
   inscribed — it compares directly against the fetched file's
   `observations_branch.cycle_number_observed` (which `gen-anchor-source.sh`
   composes as `CLOSED_COUNT + 1`), so passing `<N>` here exits 5
   (mismatch). Push + wait for deploy is a separate, subsequent action
   (same pattern as step 4).
   **Not optional**: `anchor-source.json` publishes via the normal
   git-deploy path, and until that deploy lands, step 9's Phase 1 polling
   never observes a fresh `dag_root_computed` and times out (exit 3).
7. **Mac — unlock, then sign + broadcast.** Gate 1 (testnet-first) needs a
   fresh testnet rehearsal of this cycle's exact memo shape first, and the
   day-of invocation MUST carry `--expect-cycle=<N+1>` (mandatory per
   `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`; cycle-4 day example: `4`):
   ```sh
   HOME=~/.metal-fy-proton-test proton key:unlock
   HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<N+1>
   ```
   Its closing `TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>` line is
   the `--testnet-tx-id` gate-1 input below.

   Next, produce the mainnet gate-4 dry-run-log for this exact shape —
   either (recommended: also runs the gate-1/gate-3 read-only pre-checks
   and prints the exact STAGE 2 command below with both gate args already
   filled in), as the deploy user **on the validator host**:
   ```sh
   bash scripts/preview-cycle-anchor-broadcast.sh --testnet-tx-id=<rehearsal tx id>
   ```
   (writes `$DRYLOG`, default `/home/deploy/.fya-mainnet-dryrun.json` —
   copy its content across to the Mac), or directly **on the Mac** (using
   the `anchor-source.json` step 6 already committed locally):
   ```sh
   bash scripts/sign-anchor-event.sh --chain=mainnet-a --dry-run > /tmp/fya-mainnet-dryrun.json
   ```
   Once the rehearsal succeeded and the dry-run-log exists, unlock the
   **separate** mainnet keystore and sign. `bin/safe-broadcast` gate 1 and
   gate 4 both REFUSE without `--testnet-tx-id` / `--dry-run-log`:
   ```sh
   HOME=~/.metal-fy-proton proton key:unlock
   FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
     bash scripts/sign-anchor-event.sh --chain=mainnet-a \
       --testnet-tx-id=<rehearsal tx id> \
       --dry-run-log=/tmp/fya-mainnet-dryrun.json
   ```
   `FY_CONFIG_DIR` holds `xpr-account` / `anchor-sink` / `xpr-quantity`.
   **Order matters** in that env-prefix line: bash evaluates left-to-right,
   so `FY_CONFIG_DIR=$HOME/...` must come before `HOME=...` — swapping the
   order makes `$HOME` resolve to the just-assigned `~/.metal-fy-proton`
   first, silently pointing `FY_CONFIG_DIR` inside the keystore instead of
   the config dir.
   Routed through `bin/safe-broadcast`'s 4-gate discipline (testnet-first,
   per-invocation operator authorization naming chain / actor / permission
   / action / memo / quantity, chain-info verify, dry-run exhaustion — PRIME
   DIRECTIVE). Testnet and mainnet are **two distinct keystores**
   (`HOME=~/.metal-fy-proton-test` / `HOME=~/.metal-fy-proton`) — never
   interchangeable (Constitution §3.5).
8. **host — `gen-anchor-receipt.sh` (7-gate verify) + `append-anchor-history.sh`
   + feed push** independently re-fetches and verifies the just-broadcast
   tx, then appends the receipt to `anchor-history.jsonl`.
9. **host —**
   ```sh
   bash scripts/resume-after-cycle-start.sh --apply
   ```
   Phase 1 verify (6 checks: prior-state read, chain query, idempotency,
   endTime-in-future, `anchor-source.json` freshness poll, identity
   signature verify) → Phase 2 atomic state write → Phase 3 report.
   **No broadcast, no explorer URL** here — the anchor tx confirmation
   belongs to step 7; this script only records cycle-gate approval state.

AI reads back step 7's tx id and reports the explorer URL to the operator
for visual confirmation (PRIME DIRECTIVE gate 2's per-invocation
authorization happens before that step runs, not after). Steps 1-3 and 8-9
pass the always-green `cycle-artifact-write` gate; no cycle-gate approval
is needed for them.

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
2. **Kill switch — freeze all gated consumers. ⚠ USE PROHIBITED for routine
   cycle transitions** (including cycle-4, 2026-08-04):
   `chmod -x /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh`.
   This does **not** mean "gate disabled" — the opposite. Every consumer
   detects the non-executable gate and **fails closed**: the five
   `cycle-artifact-write` scripts (`gen-cycle-history.sh`,
   `uptime-history.sh` Job B, `node-info.sh`, `gen-evidence.sh`,
   `gen-renewal-ics.sh`) skip their feed writes and `daily-status.sh` skips
   its digest push (each `exit 0`; `uptime-history.sh` first completes its
   ungated Job A — the daily snapshot append to the host-local master
   JSONL — and skips both public uptime feeds), while `check-anomalies.sh`
   keeps its non-cycle checks running and suppresses only the cycle-related
   alerts. This **stops public feed generation**
   (`validator.json` / `cycle-history` / `evidence` / `renewal-ics` /
   `uptime`) until reversed with `chmod +x`; it does *not* fall back to
   pre-gate "proceed" behavior — and since `cycle-artifact-write` is
   already unconditionally green (see the `cycle-gate.sh` table above),
   lever 2 buys nothing for that side-effect type and only breaks
   recording. If the goal is to relax approval enforcement while keeping
   feeds flowing, use **lever 1** (`rm` the state file) instead — that
   returns green for every side-effect type without touching the
   executable bit.
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
- `docs/MERKLE_DAG_SPEC.md` — canonical hashing spec (`jq -cS`; the trailing
  newline (`0x0a`) that `jq` appends is included in the hashed bytes, per §2.1).
- `docs/IDENTITY_VERIFICATION.md` — the public seven-step verification
  recipe.
- `docs/audits/constitution-2026-07-04-design-stocktake.md` — the design
  stocktake that drove the v1 → v2 collapse.
- `docs/VALIDATOR_RENEWAL.md` — operator-facing renewal SOP.
