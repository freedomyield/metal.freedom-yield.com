# Design: anchor double-inscription guard (2026-10-16)

## Decisions (operator, 2026-10-16)

The operator reviewed this design in chat on 2026-10-16 and decided:

- **Q7 timing — the code ships AFTER the 2026-11-06 cycle transition.** Order: implement (§9) → review → merge → testnet rehearsal (§8) → first mainnet use at the **December 2026** transition. No code path named in this design (`bin/safe-broadcast`, `scripts/sign-anchor-event.sh`, `scripts/run-testnet-rehearsal.sh`, `scripts/lib/anchor-history-read.sh`, …) changes before 2026-11-06, so the script freeze for that transition (C-4) is untouched.
- **Interim rule for 2026-11-06 — a runbook rule only.** Until this guard ships, `docs/CYCLE_GATE.md` unit 7c and step 8 carry an absolute rule: a 7c that exits non-zero, prints no 64-hex tx id, or whose outcome is in any doubt is never re-authorized or re-run until (a) at least 60 minutes have passed since the failed attempt (the CLI's 3000 s expiration, P-2) and (b) a read-only chain check shows no action with the cycle's memo prefix from the anchor account. "Exit 0" alone is not success (finding 1).
- **Q1 — (a).** Refuse by default on testnet too, with an explicit testnet-only `--allow-existing-cycle-anchor` override.
- **Q2 — 600 s** expiration.
- **Q3 — all broadcast shapes** get the expiration header and the outcome classification (so the key-rotation flow needs a testnet run on the new wrapper before its next mainnet use, §6).
- **Q4 — accepted.** An UNKNOWN outcome is tested hermetically only (B3, B5), never live.
- **Q5 — no NET pre-check now.** T6's NET part is dropped; the day-of policy stands: never buy resources on the day.
- **Q6 — no Constitution amendment.**
- **Q8 — the three items stay out of scope.**

The rest of this document is the design as reviewed. Where it says "before 2026-11-06", read it in the light of Q7 above.

---

Nothing was written, run against a network, or broadcast while producing the design. Every claim cites file:line as of main `0278edd` (the cited files are unchanged at `5b67980`). Claims that could not be checked are marked **UNVERIFIED**. Task 0 in §9 checks the network ones read-only. Citations into the installed `@proton/cli` 0.1.98 / `@proton/js` 27.13.0 packages are relative to the package root; `troubleshooting.md` and `cli-reference.md` are files of the xpr-network-dev reference used by the AI tooling, not of this repository.

**Key findings that change the task brief:**

1. **The CLI exits 0 even when the push fails.** It prints the error to stdout and returns normally, so the wrapper's `rc≠0` test almost never fires. Today every failure is detected only by "no tx_id". Sources: `@proton/cli/lib/commands/transaction/push.js:14-16`, `utils/detailsError.js:58-72`, `@oclif/command/lib/command.js:37-51`.
2. **@proton/js re-sends a failed push to the next endpoint on its own.** Its RPC timeout is 5 s (`@proton/js/dist/index.js:575`). On a timeout or a 200-with-`processed.except` it logs the error with `console.log(e)` (stdout) and retries `push_transaction` on another endpoint (`:599-624`). A later "rejection" message can therefore follow an earlier attempt that may have been accepted. A "duplicate transaction" message means the same transaction is already known, so it probably landed.
3. **On an ambiguous XPR failure the CLI prints no tx_id.** The tx is signed in-process. So recovery cannot be "look up the tx_id". It has to be a search by memo prefix, which is exactly check A.
4. **A tx_id on XPR does not prove the tx landed.** The API node can answer and relay, then the producer drops the tx (`troubleshooting.md:87-100`). This is the step-8 "dropped tx" case.
5. **Testnet already holds repeated memo prefixes.** Dress rehearsals re-inscribe a cycle's prefix on testnet (`docs/REHEARSAL_2026-09-01.md:114-131`; `scripts/install-rehearsal-preflight.sh:861-926`, "DRESS"). Enforcing check A on testnet changes current practice, so the testnet policy is an operator decision (§10 Q1).
6. **The 2026-09-01 rehearsal already wrote down this exact gap.** It recorded that a block passing all four gates would double-inscribe cycle 4, and that the wrapper has no "already inscribed" check (`docs/REHEARSAL_2026-09-01.md:113-127`).

---

## 1. Problem

**P-1. A rejection and an unknown outcome look the same.**
- On a `processed` (XPR) profile, `bin/safe-broadcast:1171-1181` reports any `rc≠0` or empty tx_id as `ERROR (6): broadcast failed`.
- The "BROADCAST OUTCOME UNKNOWN" banner (`:1158-1168`) fires only on id-only profiles (`:1177-1179`).
- The header gives exit 6 one meaning for both cases: "chain rejected the tx or transport error" (`:300`).
- `scripts/sign-anchor-event.sh:410-412` turns every wrapper failure into its own exit 5.
- The 7c row in the exit-meaning table already warns "Do not retry blindly … could double-inscribe" (`scripts/lib/cycle-context.sh:461`), but nothing enforces it.

**P-2. The CLI's 50-minute default expiration is the ambiguity window.**
- The wrapper sends `PROTON_ARGS=(transaction:push "$(cat "$TX_JSON_FILE")")` (`bin/safe-broadcast:1123`) with no header fields.
- The CLI signs with `useLastIrreversible: true, expireSeconds: 3000` (`@proton/cli/lib/storage/networks.js:37-46`).
- The expiration is the LIB block time + 3000 s (`@proton/js/dist/index.js:2389-2398`, `:3619-3626`, `:3655-3671`).
- So a push whose outcome is unknown can still land for about 50 minutes (`cli-reference.md:339-340`).

**P-3. Nothing checks the chain before sending.**
- None of gates 1-4 (`bin/safe-broadcast:668-1033`) asks whether this cycle's prefix `fya<S>c<N>` is already on chain.
- The ledger dedups only after the fact (`scripts/append-anchor-history.sh:18-22`, `:298-352`), and only for txs that reached it.
- The rehearsal preflight's check 8 reads the published ledger, not the chain (`scripts/install-rehearsal-preflight.sh:874-926`). An ambiguous push that landed is never in the ledger.

**P-4. The operator token can be reused.** The gate-2 token is checked for freshness (300 s interactive, 60 s non-interactive; `bin/safe-broadcast:925-934`) and content (`:936-991`). It is not consumed, so a re-run within its TTL needs no new token.

Taken together: an ambiguous 7c, then a re-authorized re-run within about 50 minutes, can inscribe the same cycle twice. That is the same class as the 2026-07-01 incident (`CLAUDE.md:11`; `docs/CONSTITUTION.md:22`).

**P-5. Step 8 has no "the tx was dropped" branch.**
- `docs/CYCLE_GATE.md:1374-1391` treats a gate-1 failure in `gen-anchor-receipt.sh` (exit 3, `scripts/gen-anchor-receipt.sh:244-247`) as indexing lag only: "re-run THIS step 8 only. Never re-run 7c … no gate refuses it".
- The table row says the same (`scripts/lib/cycle-context.sh:467`).
- No branch covers a tx that returned an id and was then dropped (finding 4).

**P-6. NET exhaustion looks like any other failure.** "transaction net usage is too high: X > Y" is a node rejection: safe to retry once the cause is fixed (`troubleshooting.md:102-112`). Today it surfaces as the generic exit 6 → sign-anchor exit 5.

## 2. Constraints from the Constitution and Operating Model

**C-1. PRIME DIRECTIVE** (`docs/CONSTITUTION.md:11-28`).
- The AI never invokes a broadcast-capable command. All tests stub `proton` and `curl`, following the existing harness (`tests/safe-broadcast/sb-harness.sh:1-12`) and plan rule P2 (`docs/superpowers/plans/2026-09-30-pulsevm-migration-readiness.md:28-29`: "gates … may only get stricter. No fail-open").
- The tier-1 hook blocks raw broadcast text and any HTTP call to a push endpoint (`scripts/broadcast-guard.sh:18-35`). Implementers must not type such text, even in a test (P6, plan `:36-38`).

**C-2. §3.4 bullet 1 (testnet first for any new mechanism)** (`docs/CONSTITUTION.md:93`). "The first execution on any new mechanism — new CLI flag, new script path, … new action shape … MUST be against a testnet."
- An explicit `expiration` header changes the bytes pushed. The new pre-push path in the wrapper is a new script path.
- **The changed wrapper must run end-to-end on testnet before any mainnet use.**
- Gate 1's "same library version" (`docs/CONSTITUTION.md:17`) points the same way.

**C-3. No amendment is needed.**
- The Constitution does not specify the wrapper's internals. Every change here adds a refusal or narrows a classification. None loosens.
- §9 governs edits to CONSTITUTION.md only (`:220-230`).
- If the operator wants the rule "unknown outcome → no resend until expiry + chain check" written into §3.4 itself, that is an optional **tightening** amendment, effective at merge (`:227`) (§10 Q6).
- Plan rule P7 says implementers do not edit `docs/CONSTITUTION.md` (plan `:39-40`).

**C-4. Script freeze** (`docs/CYCLE_GATE.md:1610-1647`). After a rehearsal for an upcoming transition, changes to its scripts are allowed only with a re-rehearsal. `bin/safe-broadcast` is named explicitly (`:1631-1641`). This design also puts `scripts/lib/anchor-history-read.sh` on the broadcast path, so add it to that list (§6).
- The next transition is 2026-11-06 (`docs/CYCLE_GATE.md:1479`; `scripts/cycle-transition.sh:154`).
- So: merge, then the testnet rehearsal (§8), then no further edits until after 2026-11-06. Otherwise ship after that transition (§10 Q7). **Decided: ship after that transition** (Decisions, top); the freeze for 2026-11-06 is therefore not touched, and the freeze before the December transition covers the new files.

**C-5. §3.3 last bullet: no unrequested refactors** (`docs/CONSTITUTION.md:87`). Leave the id-only health check (`bin/safe-broadcast:550-583`, `:1040-1069`) and `sb_history_lookup` (`:514-531`) untouched. Add, do not rewrite.

**C-6. §3.4 header markers and §3.5 keystore prefixes** (`docs/CONSTITUTION.md:99`, `:103-104`).
- The new read-only script carries `# CHAIN: none — READ ONLY` and `# PRIME_DIRECTIVE: TESTNET-FIRST` in its first 10 lines, like `scripts/check-anchor-history-reachable.sh:6-15`.
- Every runbook command that names the CLI must carry the `HOME=~/.metal-fy-proton[-test]` prefix.

**C-7. Operating Model.**
- The wrapper, rehearsal and signing run on the operator's Mac. The library reaches the validator host only through W6's checkout fast-forward (`docs/OPERATING_MODEL.md:100`). No W7 host change is needed.
- The new checker is read-only and runs where 7b.5 runs (AI@host) or on the Mac.
- W9: full search for renamed concepts (`:144`).
- W11: rehearsal records are append-only (`:155-169`). New results go in a new dated doc, not edits to `REHEARSAL_2026-09-01.md`.

**C-8. Text guards in existing tests.**
- `scripts/cycle-transition.sh` must not name the signing CLI (`tests/orchestrator-guard/`; `scripts/cycle-transition.sh:901`).
- `scripts/lib/cycle-context.sh` must not contain `pro``ton`, `safe-``broadcast` and similar (`tests/cycle-context/test-cycle-context.sh:1028-1037`).
- The table's exit rows must match the literal `exit N` codes of each listed script (`:707-721`, list at `:491`).
- The history-read library must keep no write path (`tests/anchor-history-read/test-check-anchor-history-reachable.sh:232-243`).

## 3. Where check A lives, and why

**Helper.** Extend `scripts/lib/anchor-history-read.sh`. Do not add a parallel reader.
- It calls itself "the ONE read path from an A-Chain history service" (`:2-19`).
- `gen-anchor-receipt.sh` uses it (`:188-197`, `:227-242`), and so does `check-anchor-history-reachable.sh` (`:108-115`).
- It takes its history bases from the chain profile (`ahr_select_bases`, `:68-94`).
- It already makes the account-scoped Hyperion request check A needs: `ahr_resolve_tx` step 1, `GET /v2/history/get_actions?account=<actor>&limit=50&sort=desc` (`:142-147`).
- The PulseVM plan already relies on that request on the new chain (`docs/A_CHAIN_PULSEVM_CUTOVER.md:172-175`; `ahr_probe_actions` `:164-178`).

Candidates rejected:
- `sb_history_lookup` (`bin/safe-broadcast:514-531`): lookup by tx_id only, and the ambiguous XPR case has no tx_id (finding 3).
- Preflight check 8 (`scripts/install-rehearsal-preflight.sh:874-926`): reads the published ledger, which is after the fact.

**Layering. Authoritative check in `bin/safe-broadcast`, keyed on the anchor memo shape. `sign-anchor-event.sh` maps exit codes only.**

Reasons:
- **"Immediately before sending" exists only in the wrapper.** The interactive prompt can sit for minutes (`:1071-1094`), and gates 1-3 run inside the wrapper after `sign-anchor-event.sh` hands off (`scripts/sign-anchor-event.sh:401-409`). The wrapper already re-checks the push endpoint right before the push for this reason (`bin/safe-broadcast:1129-1138`). Check A copies that pattern: one check before the prompt for an early, visible refusal, and a re-check immediately before the push.
- **One chokepoint covers both callers.** The testnet rehearsal calls the wrapper directly (`scripts/run-testnet-rehearsal.sh:493-497`), not through `sign-anchor-event.sh`. A check only in `sign-anchor-event.sh` would never run on testnet, so testnet-first (C-2) could not exercise the code mainnet uses.
- **The generic wrapper already has anchor-only sub-checks.** Gate 1(b) (`bin/safe-broadcast:824-846`) and gate 4 (`:870-903`) apply only when a memo matches `^fya[0-9]+c[0-9]+` (`:831`). Non-anchor shapes such as updateauth key rotation are exempt (`:826-830`, `:856-861`). Check A uses the same shape test, so the rotation flow is unaffected. Today that derivation exists only inside the mainnet block (`:668-904`); it must also run for testnet.
- **Not in both places.** A second copy in `sign-anchor-event.sh` would be the parallel implementation the brief rules out, and it could not be "immediately before sending" anyway.
- **Optional (T6):** the 7b preview could call the same library function as one more read-only pre-check (`scripts/preview-cycle-anchor-broadcast.sh:377`, "[4/5] read-only gate pre-checks").

**What counts as "this cycle's anchor" on chain (new `ahr_find_cycle_anchor <base> <actor> <prefix>`):**
- An action with `act.account == "eosio.token"`, `act.name == "transfer"`, `act.data.from == <actor>`, and a memo matching `^<prefix>($|[^0-9])`.
- The non-digit boundary stops `fya1c1` from matching `fya1c10:…`. It covers all four memo forms (`scripts/sign-anchor-event.sh:296-301`) and stray variants.
- Requiring `from == actor` matters: anyone can send a transfer *to* the actor with a fake `fya…` memo. Without the filter, that would block our anchor.
- Actor and sink come from the outgoing tx. All actions must share one authorization actor equal to `data.from`, and the tx must carry exactly one prefix. Otherwise refuse with exit 2.

**Scan rule.** Page newest first: `account=<actor>&filter=eosio.token:transfer&sort=desc&limit=100&skip=k·100`, at most 10 pages.
- Seeing the target prefix → **FOUND**.
- Seeing an anchor of the same schema with a **higher** cycle → **FOUND-LATER** (refuse; ledger invariant 4 would refuse later anyway, `scripts/append-anchor-history.sh:22`).
- Seeing an anchor of a **lower** cycle → **floor reached, CLEAR**. Cycles are inscribed in order, so cycle N's anchor is newer than cycle N-1's.
- A page shorter than the limit → history exhausted → **CLEAR** (first anchor ever, or first on a new chain).
- Any curl error, non-object, or missing `actions` array, or the page budget used up with no floor → **UNREADABLE** → refuse (fail closed).
- The Hyperion parameters `filter` and `skip` and the maximum `limit` are **UNVERIFIED** on `https://proton.eosusa.io` and `https://test.proton.eosusa.io` (`config/a-chain-profiles.json`). Task 0 checks them read-only. If `filter` is unsupported, drop it; the jq filter already restricts the matches.

**Freshness.** New `ahr_index_fresh <base> <max_lag>`: GET `<base>/v2/health`, using the same definition as `bin/safe-broadcast:565-574` (all services OK, `head - last_indexed ≤ 30`).
- It is new in the library. The wrapper's id-only copy is left alone (C-5).
- Whether XPR bases serve that body is **UNVERIFIED** (Task 0). A missing or stale health answer → UNREADABLE.
- Why this is needed: the "after expiry" rule in B is sound only if the index covers the expiry block.

## 4. Outcome rules for B, and the signals parsed

Exit codes are set before the push and after it. Every exit before the push call at `bin/safe-broadcast:1141` means **NOT SENT**: 2, 3, 4, 5, 7, 8, and the new 11, 12, 13. The audit log has a `phase=pre` line only if the run got that far.

After the push, on any profile, in this order. Output is stdout and stderr with ANSI codes stripped first. Whether `colors`/chalk emits ANSI on a non-TTY is **UNVERIFIED**; `styledJSON` is plain when `!chalk.level` (`@oclif/core/lib/cli-ux/styled/json.js:6-11`).

| # | Signal | Class | Exit |
|---|---|---|---|
| a | proton `rc ≠ 0` (crash, signal, unhandled). Handled errors exit 0 (finding 1). | UNKNOWN | **10** |
| b | Output contains an RPC-layer exception dump from `console.log(e)` (`index.js:614`): a stack line `^\s+at `, or `FetchError` / `AbortError` / `RpcError` / `isFetchError` / `ECONNRESET` / `ETIMEDOUT` / `socket hang up` / `aborted`. A fetch failed somewhere and the library may have re-sent elsewhere (`:616-621`). This overrides everything below, including a tx_id. | UNKNOWN | **10** |
| c | 64-hex `"transaction_id"` extracted (`bin/safe-broadcast:1144-1149`), and (processed profile) `processed.receipt.status` is absent or `"executed"` | SUBMITTED | 0 (processed); id-only goes to the existing confirmation, `:1189-1228`, → 0 or 9 |
| c′ | tx_id present but `processed.receipt.status` ≠ `executed` | UNKNOWN | **10** |
| d | No tx_id, exactly one error line (plus an optional `Hint:` line), and it matches the **rejection allowlist**: `assertion failure`, `transaction net usage is too high`, `tx_net_usage_exceeded`, `billed CPU time`, `tx_cpu_usage_exceeded`, `ram_usage_exceeded`, `insufficient ram`, `missing authority`, `missing required authority`, `overdrawn balance`, `unknown key`, `expired transaction`. **processed profiles only.** | REJECTED: nothing will land, retry safe once the cause is fixed | **6** (narrowed meaning) |
| e | `duplicate transaction` | UNKNOWN (likely landed) | **10** |
| f | Anything else, including `deadline exceeded`, empty output, `{}` | UNKNOWN | **10** |

Notes on the table:
- **Why one clean error line means a rejection.** A node rejection comes back as HTTP 500 with `error.details[0].message`. It is thrown outside the retry block (`index.js:625-627`), so it is not logged by `console.log(e)` and not retried. `RpcError` takes `details[0].message` (`:49-51`), and `parseDetailsError` prints it once (`detailsError.js:58-67`).
- **Where the allowlist strings come from.** The hint table in `detailsError.js:7-44` and `troubleshooting.md:102-120` / `cli-reference.md:343-348`. The exact XPR wording is field-observed in that skill (September 2026). It is **UNVERIFIED here** and live-checked in rehearsal R4.
- **id-only (PulseVM):** row d does not apply. PulseVM rejection wording is unmeasured, so every failure without a tx_id is UNKNOWN (10). This replaces today's "exit 6 + may-have banner" (`bin/safe-broadcast:1177-1179`). Exit 9 is unchanged (`:1223-1227`).
- **NET exhaustion** goes through row d. It is the one rejection with a runbook note (§6), because the fix — buying resources — is itself a broadcast.

**UNKNOWN (10)** prints the existing banner (`:1158-1168`), extended with the `expiration` we set (§5), "earliest possible retry: after the chain's last irreversible block time is past `<E>`", and the memo prefix.

**Audit log.**
- The pre line gains `memo_prefix=<p|none>`, `expiration=<E|none>`, `profile=<name>`.
- The post line gains `outcome=<submitted|rejected|unknown|refused-gate3-recheck>`.
- No external parser reads these lines (only the wrapper, its tests and the golden file: grep of `phase=pre` across scripts/tests/docs/bin).

**Mechanizing "do not resend until expiry is irreversibly past AND check A passes": a journal check, new exit 13.** For an anchor-shaped tx, before the prompt and again before the push, read the audit log (the same file as `:337-339`; unreadable → 13).
- Consider each `phase=pre` line with the same role and the same `memo_prefix`.
- Also consider legacy pre lines with no `memo_prefix` that are within 3600 s of now; this covers runs from before the change.
- Ignore a line if its post line (same TS and tx_sha256) has `outcome=rejected` or `refused-*`.
- Every other line blocks while `E ≥ LIB_time`. This covers `submitted`, `unknown`, a pre line with no post line (crash or Ctrl-C), and legacy `rc≠0`.
  - `E` is the recorded expiration. For legacy lines it is `TS + 3600 s`, a conservative bound on the CLI default of LIB + 3000 s.
  - `LIB_time` is `.last_irreversible_block_time` from `chain:info` read just before the push. On a `lib_equals_head` profile, use `head_block_time`.
  - Whether XPR's get_info carries `last_irreversible_block_time` is **UNVERIFIED** (`index.js:3655-3671` treats it as optional). If it is missing → 13 (fail closed).
- Once `E < LIB_time`, history is authoritative: check A decides.
  - A **submitted** line also blocks until expiry. That catches "7c exited 0, step 8 hit indexing lag, someone re-ran 7c", even when history has not indexed the tx yet.
  - A **dropped** tx becomes re-sendable once check A shows nothing after expiry.

**New wrapper exit codes:**
- **10** outcome unknown (processed or id-only).
- **11** this cycle's anchor, or a later cycle's, is already on chain; refused before signing. Prints the trx_id, block and time found.
- **12** cannot prove the cycle is absent (history unreadable, stale, or page budget used up).
- **13** an earlier attempt for this prefix on this chain may still land; refused until `<E>` is irreversibly past.
- **2** also for: caller-supplied header fields (§5), more than one prefix, or mixed actors.

**`sign-anchor-event.sh` mapping** (replaces `:410-412`; its current exits are at `:39-49`):
- Wrapper 2, 3, 4, 5, 6, 7, 8 → **5**: nothing landed (refused before sending, or rejected).
- Wrapper 9 or 10, any unlisted rc (for example 130 from SIGINT), or rc 0 with a malformed tx_id → new **9**: OUTCOME UNKNOWN.
- Wrapper 11 → new **10**: already inscribed.
- Wrapper 12 or 13 → new **11**: cannot prove absence, or an earlier attempt is still live.
- Each message repeats the wrapper's class in plain words.

**`run-testnet-rehearsal.sh` mapping** (`:498-506`): wrapper 9 or 10 → new exit **9**; 11 → **10**; 12 or 13 → **11**. Other failures stay `fail()` = 1 (`:199`).

## 5. Expiration

**Verified from source: the CLI has no expiration flag, but a header in the tx JSON wins.**
- `transaction:push` has only `-u/--endpoint` (`push.js:23-25`), which the wrapper forbids (`bin/safe-broadcast:373-397`). `expireSeconds: 3000` is hard-coded (`networks.js:42-45`).
- `generateTapos` returns `{ ...transactionHeader(block, expireSeconds), ...transaction }` (`index.js:3623-3626`), and `transact` spreads that object into the transaction it serializes (`:3445-3450`). So an `expiration` in the JSON passed to `transaction:push` replaces the CLI's. This matches `cli-reference.md:341-344`.
- Format: `time_point_sec` is serialized through `dateToTimePointSec(date + "Z")` (`index.js:1826-1830`, `:1399-1401`, `:1385-1391`). The value **must be `YYYY-MM-DDTHH:MM:SS` with no trailing `Z`**; a `Z` gives "Invalid time format". `ref_block_*` stay CLI-generated from LIB.

**Design (in the wrapper, every shape — §10 Q3):**
1. **Refuse** (exit 2) a `--tx` file with any of `expiration`, `ref_block_num`, `ref_block_prefix`, `max_net_usage_words`, `max_cpu_usage_ms`, `delay_sec`, `context_free_actions`, `transaction_extensions`. A caller-supplied 3600 s expiration would defeat the rule, and `delay_sec` would create a deferred tx. Today the only composer emits `{actions:[…]}` (`scripts/sign-anchor-event.sh:315-338`).
2. Immediately before the push, after the endpoint re-check at `:1133`, run `chain:info` a second time.
   - Re-assert `chain_id` against the expected value (same comparison as `:1027-1033`).
   - Take `head_block_time` and LIB time from it.
   - Compute `E = floor(head_block_time) + EXPIRE_SECONDS`, with `EXPIRE_SECONDS=600` as a code constant and no environment override (§10 Q2).
   - Basing E on chain time rather than the Mac's clock avoids clock skew, and sampling after the prompt keeps the full 600 s.
3. Push `jq -c --arg e "$E" '. + {expiration: $e}' "$TX_JSON_FILE"`. The file is never changed, so the gate-2b `tx_sha256` binding (`:972-991`) and the gate-1 and gate-4 derivations are unchanged. The header is not "content" the operator authorizes; the audit line records E. Print `expiration=<E>` on stderr on every outcome. Stdout stays the bare tx_id (`:1230-1232`), which the rehearsal and `sign-anchor-event.sh` parse.
4. The node limit is `max_transaction_lifetime` (**UNVERIFIED** on XPR; Antelope's default is 3600 s). 600 s is far inside it. A push delayed past E is rejected with `expired transaction` (row d), which is safe.

**Fallback if Task 0 or R1 shows the header is not honoured** (for example if `last_irreversible_block_time` or `head_block_time` is missing, or a future CLI changes the merge):
- Do not push. Exit 4 before signing.
- B's rule still holds with `E = TS_pre + 3600 s`, a conservative bound on the CLI default of LIB + 3000 s.
- Retry waits stretch to about 60 minutes.

**Alternative considered and deferred: pin `ref_block_num` and `ref_block_prefix` too.** The tx would then be fully determined, and a resend within E would be idempotent because the chain dedups by tx id. That removes the wait, but adds header computation in bash and depends on PulseVM honouring TAPOS and dedup (**UNVERIFIED**). It is not needed for safety (§10 Q8).

## 6. Runbook and text changes

- **`bin/safe-broadcast` header.**
  - Exit table (`:291-306`): narrow 6; add 10-13; add 2's new reasons.
  - New sections: "Cycle-anchor presence check", "Outcome classification", "Expiration".
  - Usage line `--allow-existing-cycle-anchor` (testnet-only).
- **`scripts/sign-anchor-event.sh` header.** Exit codes (`:39-49`) 5, 9, 10, 11 as in §4.
- **`docs/CYCLE_GATE.md`:**
  - **7a** failure bullets (`:1077-1088`): rehearsal exits 9, 10, 11. "9 = do not re-run 7a until the printed `<E>` is irreversibly past". Add `--allow-existing-cycle-anchor` guidance for a cycle already rehearsed on testnet (§10 Q1).
  - **7c** (`:1210-1330`): a new box, "If 7c exits non-zero". Exit 5 = nothing landed: read the wrapper class; a retry needs a **new** per-invocation authorization and a new token. Exit 9 = UNKNOWN: **do not re-authorize**; wait until LIB time > E, then run the checker (below); only exit 0 from it permits a new authorization. Exit 10 = already inscribed: stop the day's inscription and go to step 8 reconciliation. Exit 11 = wait and re-run (nothing sent).
  - **7c NET note:** "transaction net usage is too high" means the node rejected the tx and nothing will land. Do not improvise a resource purchase on the day: `resources::buyplan` is a separate broadcast with its own four gates (`docs/CONSTITUTION.md:15-20`). The default is to wait for NET to recover, then re-authorize. Optional pre-check in 7b (§10 Q5).
  - Fix the stale line cites: `bin/safe-broadcast:567-577` (`docs/CYCLE_GATE.md:1265`) is now `:1072-1094`; `:579-584` (`:1286`) is now `:1088-1093`.
  - **Step 8** (`:1374-1391`): replace the single "indexing lag" paragraph with a decision tree. (i) Re-run step 8 after about a minute, up to E. (ii) If gate 1 still fails, run the checker with `--not-before=<E>` (E from 7c's stderr, or the `expiration=` field in the Mac audit log). It exits 4 → wait; 3 → wait, never 7c; 10 with trx_id == the fragment's tx_id → indexing, re-run step 8; 10 with a different trx_id → **STOP, operator reconciliation** (the cycle was inscribed by another attempt, so the fragment's tx_id is wrong); 0 → **DROPPED**: nothing was inscribed, and 7c may be re-run with a fresh authorization. 7a and 7b evidence stays valid (same shape and prefix).
  - **Script freeze** (`:1631-1641`): add `scripts/lib/anchor-history-read.sh` and the new checker.
  - **Test coverage** (`:1697-…`): list the new suites.
- **`scripts/cycle-transition.sh`.** Text only, no signing-CLI name (C-8):
  - Phase row 5 / stop 4 (`:423`): add "(c) if unit 7c exits non-zero, the AI reports the class first; an UNKNOWN outcome is never re-authorized until the printed expiration is irreversibly past and the absence check exits 0".
  - Unit 7c notes (`:744-753`).
  - Unit 8 notes (`:758-762`): dropped-tx branch.
  - The brief's "stop 5" I read as phase row 5 (`:423`), which this script numbers stop 4 (`:101-111`). **UNVERIFIED interpretation.**
- **`scripts/lib/cycle-context.sh`.**
  - Revise row `5|7c|sign-anchor-event.sh|5` (`:461`); add rows 9, 10, 11.
  - Add `run-testnet-rehearsal.sh` rows 9, 10, 11 (after `:449`).
  - Revise `6|8|gen-anchor-receipt.sh|3` recovery (`:467`) to point at the dropped-tx branch.
  - Avoid the forbidden strings (C-8).
- **`docs/A_CHAIN_PULSEVM_CUTOVER.md`.** §4.2 (`:127-132`: exit 6 → 10, plus a note on expiration on PulseVM). §4.4 step 4 (`:176-181`: "reports every wrapper failure as its own exit 5" is no longer true).
- **`docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`.** Failure list (`:449-490`): step 7/10 exits 9, 10, 11.
- **`TOOLKIT.md`.** Add the checker.
- **`docs/ANCHOR_ACCOUNT_KEY_ROTATION.md`.** Only if expiration applies to every shape (§10 Q3): the rotation flow needs a testnet run on the new wrapper before its next mainnet use (C-2).

**New script `scripts/check-cycle-anchor-absent.sh`** (read-only; Mac or host; sources only the two libraries, like `check-anchor-history-reachable.sh:108-115`).
- Arguments: `--chain=…`, `--memo-prefix=fya<S>c<N>` or `--anchor-source=<file>` (prefix derived as in `sign-anchor-event.sh:220-230`, `:296`), `--actor=` (default `$FY_CONFIG_DIR/xpr-account`, as `check-anchor-history-reachable.sh:168-174`), `[--not-before=<E>]`.
- Exits: 0 absent (and E irreversibly past, if given); 10 present (prints trx_id, block_num, timestamp); 4 E not yet irreversibly past; 3 history unreadable or stale; 2 profile unusable; 1 usage.
- LIB time comes from `<base>/v1/chain/get_info` (new `ahr_chain_times`, next to `ahr_observed_chain_id` at `:193-200`). A base that does not serve it → 3.

## 7. Test plan

Each property below names its test and the mutation that must turn that test red, as rule P5 requires (`docs/superpowers/plans/2026-09-30-pulsevm-migration-readiness.md:36-38`). Record the red/green run per mutation in each task report. Everything is hermetic: `proton` and `curl` are stubs, HOME is a fixture (`tests/safe-broadcast/sb-harness.sh:62-140`).

**Harness extensions (T2):**
- Stub push modes that imitate the real CLI (stdout, rc 0): `processed`, `processed_soft` (status ≠ executed), `reject_assert`, `reject_net`, `dup`, `dump_then_assert` (a `console.log` dump with `    at …` lines, then an assertion line), `abort` (dump + "The user aborted a request."), `garbage`, `crash` (rc 1), `noid`.
- The stub saves its push argument, so tests can assert on `.expiration`.
- The existing `fail` mode (stderr, exit 1; `sb-harness.sh:136`) does not match real CLI behaviour. Keep it only as the `crash` case.
- `chain:info` controls: `STUB_HEAD_TIME`, `STUB_LIB_TIME`, plus an "omit LIB time" option.
- curl fixtures for paged get_actions (`hist/actions/<actor>/<skip>.json`), `/v2/health` (exists, `:42-43`), and per-call counters, so history can flip between the two checks.

| # | Property | Test | Mutation that must fail it |
|---|---|---|---|
| A1 | Prefix already on chain from the actor → exit 11, push never called | wrapper, both roles (no flag) | `ahr_find_cycle_anchor` always returns CLEAR, or the call is removed |
| A2 | Pre-push re-check: history flips to FOUND after the prompt → 11, no push | counter fixture | delete the pre-push re-check |
| A3 | Unreadable history → 12: curl fail, non-object, no `actions`, page budget used up with no floor, health stale or missing | 5 cases | treat UNREADABLE as CLEAR (each case separately) |
| A4 | Prefix boundary: send `fya1c1` with only `fya1c10` on chain → 11 (later cycle). Send `fya1c10` with `fya1c1` as floor → proceeds | 2 cases | match by `startswith(prefix)` |
| A5 | A prefix memo sent *to* the actor by a stranger → CLEAR | lib + wrapper | drop the `from == actor` filter |
| A6 | Floor ends the scan: proceeds with exactly the expected number of curl calls | call log | ignore the floor (scan everything) |
| A7 | updateauth shape: no get_actions call, no journal block | existing tx-upd fixture | apply check A to every shape |
| A8 | `--allow-existing-cycle-anchor` on mainnet → exit 2. On testnet with FOUND → proceeds with WARN | 2 cases | accept the flag on mainnet |
| B1 | Pushed JSON has `.expiration == head + 600`, matching `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$` (no Z); the tx file is unchanged; token tx_sha256 still matches | captured argument | omit injection / append `Z` / use wall clock (set the stub head time ≠ now) |
| B2 | Caller-supplied header fields → 2 | one case per field | remove the check |
| B3 | Classes: reject_assert → 6 `outcome=rejected`; reject_net → 6 with NET hint; dup → 10; dump_then_assert → 10; abort → 10; garbage → 10; crash → 10; noid → 10; processed_soft → 10; processed → 0 | 10 cases | "no tx_id ⇒ 6" (today's rule); drop dump detection; treat `duplicate` as rejected; ignore `rc` |
| B4 | id-only: no tx_id → 10 even with assertion text; existing 9 path unchanged | profiles suite | apply the allowlist on id-only |
| B5 | Journal: same-prefix pre with no post and E > LIB → 13, no push. `outcome=submitted` with E > LIB → 13. `outcome=rejected` → ignored, proceeds | 3 cases | skip the journal; treat rejected as blocking (catches over-blocking) |
| B6 | Journal compares against **LIB**, not head: head > E > LIB → 13 | 1 case | compare against `head_block_time` |
| B7 | After expiry (LIB > E) with history CLEAR → proceeds; with FOUND → 11 | 2 cases | after expiry, skip check A |
| B8 | Legacy pre line with no `expiration` within 3600 s → 13 | 1 case | ignore legacy lines |
| B9 | LIB time missing from `chain:info` → no push (exit 4 or 13) | 1 case | default LIB time to now |
| S1 | `sign-anchor-event.sh`: stub wrapper returning each rc (0 good, 0 malformed, 2-13, 130) → mapped exit | table-driven (`tests/sign-anchor-event/`) | "everything → 5" (today) |
| S2 | `run-testnet-rehearsal.sh` mapping 9, 10, 11 | `tests/run-testnet-rehearsal/` | "everything → fail 1" |
| K1 | Checker exits 0, 10, 4, 3, 2, 1 with fixtures; `--not-before` uses LIB time | `tests/check-cycle-anchor-absent/` | invert the LIB comparison; treat unreadable as 0 |
| L1 | The library stays read-only; the endpoint set is pinned, now including `/v2/health` | extend `test-check-anchor-history-reachable.sh:232-243` | add a write call |
| X1 | Equivalence: every scenario that refuses before the new code is byte-identical to the golden (`test-safe-broadcast-equivalence.sh:11-38`). Scenarios that reach the push move out of the golden. Delete their blocks; never regenerate from current code (`:31-33`). List them under "Deliberately NOT here" (`:40-45`) and pin them in the new outcome suite | equivalence | n/a (guards the rest) |
| X2 | `tests/cycle-context` literal-exit cross-check passes (rows exist for every new literal) | existing | drop one row |
| X3 | `tests/cycle-transition` and `tests/orchestrator-guard` pass (stop text, no CLI name) | existing | n/a |

Run `bash tests/run-all-tests.sh` and `shellcheck -x` (P5).

## 8. Testnet rehearsal plan (testnet first; the AI never broadcasts)

**Who does what.**
- The **operator** runs every command below that can push, personally, at the Mac's TTY. This is stricter than the 7a rule "AI starts after an explicit instruction" (`docs/CYCLE_GATE.md:1053-1056`), and follows the brief.
- The **AI** prepares the exact commands with the `HOME=~/.metal-fy-proton-test` prefix (§3.5). It runs only read-only steps: the checker, history GETs, reading the audit log. It verifies each output against the expected one.
- All runs use the testnet keystore and `--chain=testnet-a`.
- Timing: after merge, which is after 2026-11-06 (Decisions, Q7), and before the December 2026 transition, with no code edits afterwards (C-4).
- Results go in a new append-only doc, `docs/REHEARSAL_2026-10-xx.md` (W11).

**Pre-step: Task 0 is read-only and the AI may run it.** Confirm the following, and stop the design if any is false:
- Hyperion `get_actions` honours `filter`, `skip`, `sort=desc`, `limit=100` on both XPR bases.
- `/v2/health` has `service_data.head_block_num` and `last_indexed_block`.
- `HOME=~/.metal-fy-proton-test proton chain:info` (testnet; for the mainnet profile `HOME=~/.metal-fy-proton proton chain:info` — Constitution §3.5) output has `head_block_time` and `last_irreversible_block_time`.
- The non-TTY CLI output carries no ANSI codes. If this cannot be observed without a push, just strip them.

**Scenarios:**
- **R1 (positive).** A rehearsal for the next prefix (`--expect-cycle=<N+1>`). If testnet already holds that prefix from an earlier dress run, the first run gets **exit 10** — that is R2b's evidence; then do R3.
  - Expect: `BROADCAST OK`; the audit pre line carries `expiration=E` and `memo_prefix`.
  - The AI checks `GET <testnet base>/v2/history/get_transaction?id=<tx>` (read-only) and confirms the tx's `expiration` is about head + 600.
- **R2a (in-flight refusal, live).** Re-run the rehearsal for the same prefix **within 10 minutes** → wrapper 13 → rehearsal 11. The audit log has no push post line, and the testnet account shows no new transfer.
- **R2b (already-inscribed refusal, live).** After E + LIB lag, re-run without the flag → wrapper 11 → rehearsal 10, with R1's tx_id printed. No push.
- **R3 (testnet override).** Re-run with `--allow-existing-cycle-anchor` → pushes, with a WARN naming the FOUND tx. This is the flag the day-of 7a needs after R1 (§10 Q1).
- **R4 (live rejection classification, optional, operator's choice).**
  - With a rehearsal config whose `anchor-sink` is a non-existent account: the node rejects ("assertion failure" / "account does not exist"). Expect wrapper 6 `outcome=rejected`, and a journal line that does **not** block the next run.
  - This uses a deliberately broken config on testnet only. It changes nothing on mainnet.
- **R5 (checker).** The AI runs `check-cycle-anchor-absent.sh --chain=testnet-a --memo-prefix=<p> --not-before=<E from R1>` and expects 10 with R1's tx. The next unused prefix returns 0.
- **Not rehearsed live:** an UNKNOWN outcome (timeout, dropped connection). It cannot be caused safely or repeatably. It is covered only by B3 and B5 (hermetic). This residual risk should be accepted explicitly (§10 Q4).
- **Day of the December 2026 transition** (was "2026-11-06" before Q7 was decided). Unit 7a runs the merged code and produces gate-1 evidence from the new wrapper (C-2). Unit 7c is the first mainnet use. On 2026-11-06 the interim runbook rule (Decisions) applies instead.

## 9. Implementation tasks (file sets do not overlap)

| Task | Files (exclusive) | Depends on | Summary |
|---|---|---|---|
| **T0** (read-only measurement) | none (report only) | — | The §8 pre-step. Its result gates the §3 and §5 assumptions. |
| **T1** library | `scripts/lib/anchor-history-read.sh`; `tests/anchor-history-read/test-ahr-find-cycle-anchor.sh` (new); `tests/anchor-history-read/test-check-anchor-history-reachable.sh` (L1 pin only) | T0 | `ahr_find_cycle_anchor`, `ahr_index_fresh`, `ahr_chain_times`. Bash 3.2 (`:61`). Contract: print one JSON verdict `{verdict: found\|found_later\|clear, trx_id, block_num, timestamp, scanned, floor}`; rc 0 decided, 3 unreadable. Properties A3-A6, L1. |
| **T2** wrapper | `bin/safe-broadcast`; `tests/safe-broadcast/sb-harness.sh`; `tests/safe-broadcast/test-safe-broadcast-outcome.sh` (new); `test-safe-broadcast.sh`; `test-safe-broadcast-profiles.sh`; `test-safe-broadcast-equivalence.sh`; `fixtures/equivalence-golden.txt` (block deletions only) | T1 contract | Sections 3-5; exits 10-13; testnet flag; header refusal; journal; second `chain:info`; header docs. Properties A1, A2, A7, A8, B1-B9, X1. |
| **T3** callers and exit table | `scripts/sign-anchor-event.sh`; `scripts/run-testnet-rehearsal.sh`; `scripts/lib/cycle-context.sh`; `tests/sign-anchor-event/*`; `tests/run-testnet-rehearsal/*`; `tests/cycle-context/test-cycle-context.sh` (only if `BRIEF_SCRIPTS` changes) | the T2 exit contract in this doc | Mappings from §4; rehearsal passes the flag through (explicit option, §10 Q1); table rows. Properties S1, S2, X2. |
| **T4** checker | `scripts/check-cycle-anchor-absent.sh` (new); `tests/check-cycle-anchor-absent/test-*.sh` (new); `TOOLKIT.md` | T1 | §6 contract. Property K1. Not added to a cycle-transition unit, so no drift edits to `docs/cycle-transition-steps.json`. |
| **T5** runbooks | `docs/CYCLE_GATE.md`; `scripts/cycle-transition.sh` (text rows only); `docs/A_CHAIN_PULSEVM_CUTOVER.md`; `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`; `docs/ANCHOR_ACCOUNT_KEY_ROTATION.md` (if Q3 = all shapes) | the contracts in this doc | Everything in §6 except the script headers. Property X3. |
| **T6** (optional) | `scripts/preview-cycle-anchor-broadcast.sh` + its tests | T1 | An early check A in the 7b read-only pre-checks. (The NET-available pre-check is dropped: §10 Q5 decided "not now".) Needs a `cycle-context` row, which overlaps T3; sequence it after T3. |

Order: T0 → T1 → (T2 ∥ T4) → T3 → T5 → review (constitution-audit) → operator merge → §8 rehearsal → freeze.

## 10. Questions put to the operator (answered 2026-10-16 — see Decisions at the top)

1. **Testnet policy for an existing prefix.**
   - (a) Refuse by default on testnet, with an explicit `--allow-existing-cycle-anchor` (testnet-only, passed by hand in 7a when a dress run exists). This is recommended: the refusal branch is exercised live.
   - (b) Warn only on testnet.
2. **Expiration length.** 600 s is recommended. After an UNKNOWN outcome the minimum wait is E + XPR's LIB lag, which is **UNVERIFIED**.
3. **Scope of the expiration header and outcome classification.**
   - Every broadcast shape. This is recommended: one code path, but the key-rotation flow must then be re-run on testnet before its next mainnet use.
   - Or anchor-shaped txs only.
4. **Accept the residual risk** that an UNKNOWN outcome is tested only hermetically, never live.
5. **NET.** Add a read-only `get_account` NET-available pre-check to 7b (T6)? Confirm the day-of policy: never buy resources on the day, because that is a separate broadcast with its own four gates.
6. **Constitution text.** Do you want the rule "an UNKNOWN outcome is never re-sent until its expiration is irreversibly past and a chain check shows the cycle absent" as a tightening amendment to §3.4, effective at merge? It is not required for this change.
7. **Timing.** Ship before 2026-11-06, with the §8 rehearsal and a freeze afterwards? Or after that transition?
8. **Out of scope unless you say otherwise:**
   - Make the gate-2 token single-use for mainnet (rename it after any push attempt). This closes P-4 directly.
   - Pin `ref_block_*` for idempotent resends (§5).
   - Confirm "processed" pushes in history before exiting 0, as is already done for id-only.

### Critical files for implementation
- `bin/safe-broadcast`
- `scripts/lib/anchor-history-read.sh`
- `scripts/sign-anchor-event.sh`
- `docs/CYCLE_GATE.md`
- `tests/safe-broadcast/sb-harness.sh`

Also touched:
- `scripts/run-testnet-rehearsal.sh`
- `scripts/lib/cycle-context.sh`
- `scripts/cycle-transition.sh`
- `docs/A_CHAIN_PULSEVM_CUTOVER.md`
- `tests/safe-broadcast/test-safe-broadcast-equivalence.sh`

proton-cli source checked (installed package, @proton/cli 0.1.98, @proton/js 27.13.0):
- `@proton/cli/lib/commands/transaction/push.js`
- `@proton/cli/lib/storage/networks.js`
- `@proton/cli/lib/utils/detailsError.js`
- `@proton/js/dist/index.js`
