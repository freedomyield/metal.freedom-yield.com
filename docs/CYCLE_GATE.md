# Cycle gate — 2-component cycle transition simplification

> **Status (= 2026-06-29 15:09 JST)**: **DEPLOYED to production**. T-7 deploy completed with 5 commits (= b4d4cfe + 221ca87 + 457a4dd + 55d7a9e + aac4934), GitHub Actions deploy + the validator host sync + cycle-gate-state.json initialized for current cycle 2 (= signature `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v-1780560117`, dag `0bd4e667…`). First live application is **2026-07-04 cycle 3 transition** (= the originally pressure-source day the design was built for). See `docs/CYCLE_GATE_DAILY_OBSERVATION.md` for ongoing production state snapshots.
>
> The "2026-08-04 first transition" framing in earlier drafts of this doc was the AI implementer's incorrect interpretation; operator intent was always 2026-07-04 from the start. Inline references to "~2026-08-04" below are historical and reflect the now-corrected plan.

## What problem this solves

The 2026-07-04 cycle 3 transition runbook contains two pieces of operator work that exist solely to prevent the anchor cron from broadcasting with a stale `dag_root_hash`:

- step 2: manually disable `/etc/cron.d/metal-anchor-watch` **before** the cycle closes at 13:00:27 JST
- step 12: manually re-enable it after the orchestrated handover finishes

Forgetting either step (or doing them in the wrong order) means the cron fires its 5-minute tick during the operator's hand-rolled gen-identity / commit / push window, observes the validator transition, and triggers `post-anchor-event.sh` with the **pre-update** `dag_root_hash`. That `dag_root_hash` is missing the cycle that just closed — broadcasting it would commit a memo on Metal A-chain that an independent auditor cannot reconcile with the contemporaneous `/api/cycles-history.json`. The action is irreversible (= broadcast is IRREV per Constitution §5).

The pressure source is therefore the **combination of a time-bounded operator action and an irreversible side effect**. The cycle-gate design removes this combination by making "broadcast safe to fire" a property of explicit operator approval state rather than of cron-on / cron-off scheduling.

## Architecture

Two components, separated by direction:

```
[ passive auto-defer ]                    [ active operator resume ]
  scripts/cycle-gate.sh                     scripts/resume-after-cycle-start.sh
  (= consulted by cron scripts)             (= invoked once per cycle)
        │                                          │
        │ reads                                    │ writes
        ▼                                          ▼
   /var/lib/freedom-yield/cycle-gate-state.json
   {
     "schemaVersion": 1,
     "approved_cycle_signature": "<NodeID>-<startTime_epoch>",
     "approved_dag_root_hash":   "<64-hex>",
     "approved_at":              "<ISO 8601 UTC>"
   }
```

`cycle-gate.sh` is **passive**: it does not change anything. It answers a yes/no question for the caller: "is the cycle currently visible on chain the one the operator approved?".

`resume-after-cycle-start.sh` is **active**: it is the single command the operator (or the AI on the operator's behalf) runs once per cycle. It verifies the new cycle is on chain, that the published artifacts (`identity.json`, `cycles-history.json`) carry the fresh `dag_root_hash`, atomically updates the state file, and triggers the anchor broadcast for the new cycle.

The cron continues to fire its 5-minute tick **without any operator action to enable or disable it**. Between cycle close and operator approval, the cron's broadcast attempt is silently deferred. After approval, the next tick — or the synchronous trigger inside `resume-after-cycle-start.sh` — broadcasts with the fresh `dag_root_hash`.

## State file schema

`${FY_STATE_DIR}/cycle-gate-state.json` (default `${FY_STATE_DIR}` = `/var/lib/freedom-yield`).

| field | type | meaning |
| --- | --- | --- |
| `schemaVersion` | integer | currently `1`. Bump on incompatible format change. |
| `approved_cycle_signature` | string | `<NodeID>-<startTime_epoch>`. Uniquely identifies the validator entry on chain that this approval covers. Two distinct AddValidator transactions produce two distinct startTime values, so the signature changes per cycle. |
| `approved_dag_root_hash` | 64-hex string | The `dag_root_hash` value present in `identity.json` at approval time. Used by `cycle-gate.sh` for the consistency check, and by `resume-after-cycle-start.sh` to detect "identity.json is still stale" during the polling phase. |
| `approved_at` | ISO 8601 UTC string | Wall-clock time the approval was written. Diagnostic only; not consumed by gate logic. |

File mode is `0644`. The file contains no SECRET-class data — both the `dag_root_hash` and the cycle signature are public on chain.

When the file is absent (= first deploy, before the first `resume-after-cycle-start.sh` has run, or after manual `rm` for rollback) `cycle-gate.sh` returns green for every side-effect type. This is the backward-compat behavior that preserves the pre-cycle-gate cron flow.

## `cycle-gate.sh`

Consulted by cron scripts immediately before a cycle-dependent side effect.

```sh
scripts/cycle-gate.sh --side-effect=<type>
```

| `--side-effect` value | semantics |
| --- | --- |
| `broadcast` | About to invoke `sign-anchor-event.sh` (= IRREV A-chain transfer). |
| `cycle-aware-notify` | About to emit a ntfy alert whose interpretation depends on whether we are mid-transition (= reserved for future use; no current consumer per the 2026-06-29 audit). |
| `observe` | About to perform read-only observation. Always returns green; provided so that future call-sites can declare intent uniformly. |

Exit codes:

| code | meaning |
| --- | --- |
| `0` | green — side effect safe to execute |
| `1` | deferred — transition window or unapproved cycle; skip the side effect |
| `2` | usage error |

Behavior matrix (= invariants):

| state | broadcast / cycle-aware-notify | observe |
| --- | --- | --- |
| state file absent | green (backward compat) | green |
| state matches chain signature | green | green |
| state mismatch chain signature | deferred | green |
| state file corrupt | fail-closed (deferred) | green |
| metalgo RPC unreachable | fail-closed (deferred) | green |
| validator absent from chain | deferred | green |

The RPC timeout default is `${FY_RPC_TIMEOUT:-6}` seconds. Setting it via env at call time lets test harnesses fail fast without depending on the system default.

## `resume-after-cycle-start.sh`

Single command run once per cycle, after AddValidator is Committed and the freshly signed `identity.json` is live on the web host.

```sh
scripts/resume-after-cycle-start.sh --dry-run    # verify only
scripts/resume-after-cycle-start.sh --apply      # full sequence
```

Phases:

1. **Phase 1 — verify.** Query metalgo RPC for the current validator entry, derive the cycle signature, idempotency-check against the prior approved signature, poll `${PUBLIC_BASE}/api/identity.json` until its `dag_root_hash` differs from the prior approved value (max `${FY_POLL_MAX_SEC:-600}` seconds at `${FY_POLL_INTERVAL:-30}` second intervals), verify the identity.json signature via `ssh-keygen -Y verify`, fetch `cycles-history.json`, confirm both artifacts agree on `dag_root_hash`. Phase 1 has no side effects.
2. **Phase 2 — atomic state write.** Compose the new `cycle-gate-state.json` via `jq -n` to a `.new` tempfile, then `mv` over the live file. Atomic on POSIX (same dir).
3. **Phase 3 — anchor broadcast trigger.** Invoke `post-anchor-event.sh --event-type cyclestart --cycle-n <N>` where `<N>` is `branches.cycles.leaf_count + 1` from `cycles-history.json` (= the in-progress cycle that just started). The downstream `post-anchor-event.sh` flock, idempotency check, and 3-state pending marker logic all carry over unchanged. `exit 2` from `post-anchor-event.sh` (= no-op idempotency) is treated as PASS.
4. **Phase 4 — 7-condition PASS check.** Fetch the freshly published `anchor-receipt.json` and verify the seven conditions from `project_phase_alpha_anchor_completion_2026_07_04` (= tx_id present, memo == `fyid1:<dag>`, signing_actor in {metalfreedom, freedomyield}, signing_permission == anchor, dag_root_hash matches, `$schema` field present, explorer URL HTTP-reachable).
5. **Phase 5 — report.** Print a one-block summary of the final state (cycle signature, dag_root_hash, cycle_n, cycle leaf_count) and the next operator step ("visually verify the explorer URL on the XPR explorer"). Exit 0.

Exit codes:

| code | meaning |
| --- | --- |
| `0` | PASS — state updated, broadcast complete, 7/7 PASS; OR `--dry-run` Phase 1 verification succeeded; OR idempotent skip |
| `1` | usage error |
| `2` | Phase 1 verification failed |
| `3` | Phase 1 polling timeout (= identity.json never went fresh) |
| `4` | Phase 2 state write failed |
| `5` | Phase 3 post-anchor-event.sh failed |
| `6` | Phase 4 7-condition check failed |

`--dry-run` runs only Phase 1. It does not write the state file, does not invoke the signer, and does not fetch `anchor-receipt.json`. Phase 2 / 3 / 4 emit "would do" log lines instead.

## post-anchor-event.sh modification (= the only existing-script edit)

The cycle-gate consultation is inserted into `scripts/post-anchor-event.sh` immediately after the existing idempotency check (= original line 327-330) and before the signer invocation (= original line 332). It is skipped when the script is in resume mode or when `--force` is set:

```bash
if [ -z "${RESUME_MODE}" ] && [ "${FORCE}" -eq 0 ]; then
    CYCLE_GATE_SCRIPT="${SCRIPT_DIR}/cycle-gate.sh"
    if [ -x "${CYCLE_GATE_SCRIPT}" ]; then
        if ! "${CYCLE_GATE_SCRIPT}" --side-effect=broadcast; then
            echo "deferred by cycle-gate: dag_root_hash=${DAG_ROOT_HASH:0:12}… not approved for broadcast" >&2
            exit 11
        fi
    fi
fi
```

Exit 11 is added to the documented exit-code list. RESUME_MODE bypasses the gate because partial-success mid-stream completion requires the broadcast to finish for state consistency (= the chain may already have the inscription; we must finalize the local state machine). `--force` bypasses because that flag is the operator's explicit emergency authority for manual replay.

Backward compatibility is structural: when `scripts/cycle-gate.sh` is absent or non-executable, the entire gate block is a no-op and the script's behavior matches the pre-cycle-gate version exactly. This means deploying the gate is safe regardless of state-file presence, and rolling back is as simple as removing `cycle-gate.sh` (or `chmod -x` it).

The `check-anomalies.sh` and `daily-status.sh` "optional gate" modifications proposed earlier were withdrawn after the T-1 read. The existing `EXPECTED_DROP` logic in `check-anomalies.sh` (line 638-651) already distinguishes the cycle-end-driven validator drop from a true unexpected drop, and `daily-status.sh` is pure observation (= no IRREV side effect). Neither benefits from gate consultation. Only `post-anchor-event.sh` is modified.

## Operator runbook (= cycle transitions starting 2026-07-04 cycle 3)

Under model α (= AI full orchestration; see `feedback_ai_full_orchestration_default` memo), the operator's runbook collapses to four active steps:

1. Operator asks AI to drive the cycle transition.
2. Operator, when AI signals it is the moment, performs the wallet flow in Metal Wallet web — collect METAL, fund the validator account, cross-chain to P-chain, submit AddValidator, confirm on-chain Committed. AI verifies on-chain state in parallel.
3. Operator, when AI prompts, enters the proton-cli keystore password (= for `proton key:unlock`) and the operator-identity-key passphrase (= for `gen-identity.sh`). AI handles every shell command around those prompts.
4. Operator visually verifies the explorer URL AI reports back. Done.

AI's hidden work between steps 2 and 4:

- ssh validator host: trigger `uptime-history.sh` + `gen-cycle-history.sh` + `push-to-web-host.sh cycle-history.jsonl`.
- Mac local: `bash scripts/operator-local/gen-identity.sh` (the operator passphrase prompt surfaces here).
- Mac local: `git add` the regenerated artifacts, commit, push.
- `gh run watch` for the Deploy workflow until completion.
- ssh validator host: `bash scripts/resume-after-cycle-start.sh --apply` (= polling Phase 1 finds fresh data on attempt 1 since AI already confirmed deploy completion; Phases 2-5 execute synchronously).
- Read back the Phase 5 summary, report explorer URL to operator.

## Emergency fallback (= AI unavailable)

If the operator must drive the transition without AI assistance:

1. Operator does the wallet flow + the Mac gen-identity + commit + push as usual.
2. After `git push`, wait for the GitHub Actions Deploy workflow to finish (= visible in the Actions tab of the repo).
3. SSH the validator host and run:

   ```sh
   ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
       'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --apply'
   ```

The Phase 1 polling tolerates uncertain deploy timing: if the operator runs the command before deploy completes, Phase 1 polls for up to 10 minutes for `identity.json` to refresh before failing. The operator does not need to know the exact deploy timing; the script discovers it.

If the operator wants to dry-run the verification first (= sanity check before approval), substitute `--dry-run` for `--apply`. Phase 1 runs in full; Phases 2-4 are skipped.

## Rollback

Three independent rollback levers, in increasing severity:

1. **Disable approval enforcement temporarily**: `rm /var/lib/freedom-yield/cycle-gate-state.json`. `cycle-gate.sh` returns green for every consultation until the file is recreated. The next `resume-after-cycle-start.sh --apply` recreates it. Use this to unblock an emergency manual `post-anchor-event.sh` invocation without `--force`.
2. **Disable the gate consultation entirely**: `chmod -x /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh`. `post-anchor-event.sh`'s gate block detects non-executable cycle-gate.sh and skips consultation, falling back to pre-cycle-gate behavior. Reverse with `chmod +x`.
3. **Remove the design entirely**: delete `scripts/cycle-gate.sh`, delete `scripts/resume-after-cycle-start.sh`, revert the post-anchor-event.sh diff (= the gate block + exit 11 documentation). The repo returns to its pre-2026-08-04 state. Use only if a fundamental design issue is found.

The state file is regenerable from any chain-visible cycle, so accidental deletion is not a data-loss event.

## Test coverage

`tests/cycle-gate/run-tests.sh` runs ten scenarios against the live shell scripts using a Python HTTP mock for metalgo RPC + Xserver responses. Scenarios cover green / deferred / fail-closed for each `--side-effect` type, idempotent resume skip, and resume against unreachable RPC. The current PASS rate is `10/10`. Run via `bash tests/cycle-gate/run-tests.sh`.

The tests cover the deterministic state-machine behavior. They do not cover:

- Live identity.json signature verification (= would require a real ed25519 signing key; covered by the operator-Mac `gen-identity.sh` self-verify at signing time)
- End-to-end A-chain broadcast through `proton-cli` (= covered by the operator's manual dry-run on the validator host before the first cycle 4 transition)

Both are scheduled to be exercised once on the validator host as part of T-8 (= 2026-07-04 cycle 3 transition validation — first live use of the cycle-gate design).

## Constitution alignment

- **§2 #1 validator health**: `cycle-gate.sh` hits metalgo RPC once per consultation (= same query as the existing `check-anomalies.sh` 5-minute tick, no incremental load). `resume-after-cycle-start.sh` runs at most once per cycle.
- **§3.3**: neither script reads or writes any SECRET-class data. The `cycle-gate-state.json` contents are all publicly observable on chain.
- **§5**: validator-host change; deployment is operator-approved. T-7 deploy completed 2026-06-29 15:09 JST per operator authorization; cycle-gate is now active on the validator host.

## Related

- `project_cycle_gate_resume_design` memo — strategic design summary.
- `project_cycle_gate_resume_tasks` memo — T-1 through T-8 task plan.
- `project_phase_alpha_anchor_completion_2026_07_04` memo — the runbook this design replaces, plus the seven-condition PASS list used in Phase 4.
- `feedback_ai_full_orchestration_default` memo — model α role distribution.
- `docs/VALIDATOR_RENEWAL.md` — operator-facing renewal SOP; updated alongside this document to point at the new flow.
