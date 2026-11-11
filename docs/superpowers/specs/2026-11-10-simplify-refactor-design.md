# Design: simplify refactor (2026-11-10)

vault を引いた結果: このプロジェクトのリファクタ・シェルの共通部品に当たるノートは vault に無し（命中は一般の記事と開発の雑記だけ）。設計は repo の文書と実物だけを根拠にした。
機械化した道具か、しない理由: 設計の下調べは 1 回限りなので、その場の集計の命令（git grep・sed・diff）と使い捨ての読み取り専用の python で数えた。進める時に繰り返す確かめは、§9 の門の道具 3 本（G1・G2・G3）にして機械に数えさせる。

**Status:** design only. Nothing was written to code, tests or existing documents, nothing was run against a network or a host, and nothing was broadcast while producing it. Citations are file:line as of main `0367552`. The public history starts at `2ecb799` (2026-10-29), so `git log` / `git blame` cannot explain anything older; reasons were read from the documents and code comments instead. Claims that could not be checked are marked **UNVERIFIED** (collected in §14).

**Key findings that change the survey (`.superpowers/sdd/2026-11-10-simplify/survey.md`):**

1. **Most "unused" scripts are manual or host-installed tools.** `scripts/check-validator-period.sh` is copied to the host's daily cron by `scripts/vps-bootstrap.sh:274-314`. `scripts/install-delegator-feed-started-at.sh` writes a host config file that `gen-anchor-source.sh` reads into the anchor source (`scripts/install-delegator-feed-started-at.sh:5-11`). Only one script can be removed on repo evidence alone (§4.2).
2. **Three of the 15 candidate documents are still load-bearing.** `docs/PHASE_ALPHA_AUDIT_HANDOFF.md` is a URL inside the generated public evidence (`scripts/gen-evidence.sh:231,239`) and two public pages. `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md` is named in runtime messages of a transition script (`scripts/run-testnet-rehearsal.sh:260,383`). `docs/REHEARSAL_2026-09-01.md` is cited by the canonical freeze rule (`docs/CYCLE_GATE.md:1747,1758`).
3. **The stated reason for copying `schema_validate_or_die` is stale.** Each copy says "no cross-script sourcing convention exists in this repo" (`scripts/append-anchor-history.sh:518-521`, `scripts/gen-anchor-source.sh:687-690`, `scripts/operator-local/commit-anchor-source.sh:282-286`). The same scripts already source libraries (`scripts/gen-anchor-receipt.sh:195,197`; `scripts/append-anchor-history.sh:143,150`; `scripts/gen-anchor-source.sh:60`). The differences between the copies have a documented reason: each script's own exit-code table (`scripts/gen-anchor-source.sh:21-32`: exit 7 is taken, so "no validator" is 8 there).
4. **Every holder of `sha256_pipe` and `schema_validate_or_die` is a transition script** under the script freeze (`docs/CYCLE_GATE.md:1715-1750`). By `docs/cycle-transition-steps.json`: the `sha256_pipe` holders run in units 7b, 7c, 8 and 10; the four `schema_validate_or_die` holders run in units 5, 6 and 8 (one table for those four: §5.4). Together, units 5, 6, 7b, 7c, 8, 10.
5. **`external-watch.sh` cannot read `side-effects.sh` as installed today.** The installer ships exactly two files to the web host as base64 (`scripts/install-web-host-external-watch.sh:468-469,848-849`), and CI's only web-host path is the `public/` rsync (`docs/CONSTITUTION.md:188`). It has its own opt-in, `WATCH_LIVE` (`scripts/external-watch.sh:19`).
6. **The duplicated notify retry policy is the same in all three copies:** rc 2, 4 or 5 is retryable (`scripts/check-anomalies.sh:557-562`, `scripts/check-watch-validators.sh:123-128`, `scripts/notify-anchor-transition.sh:115-120`). It encodes `notify.sh`'s exit codes, which `side-effects.sh` passes through verbatim (`scripts/lib/side-effects.sh:62-70`).

---

## 1. Intent and why

The operator asked (2026-11-10): "既存プロジェクトで、リファクタリングをして、シンプルにしたいです。整えれる箇所がないか、確認をお願いします。" The supervisor's recommended order (candidates 1·2 → 3 → 4·5; 6·7 after the 2026-12-07 transition) was accepted.

"Simpler" here means three things a reader feels:

- **Fewer live documents to read.** A finished audit or an executed plan sitting next to live runbooks is read as current. This repository has a history of sessions following the wrong document (memory notes on reading stale plans). Moving finished records out of the live set, unchanged, removes that trap.
- **One copy of each shared rule.** Four copies of the schema check carry the comment "keep the four in sync". A rule kept in sync by hand is the same root the 2026-08-06 design named: "the correct state is copied by hand into several places" (`docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md:11`). This design continues that work for shell functions.
- **A gate that keeps it that way.** Without a machine check, copies return. Each cut ships with its gate.

The Constitution forbids unrequested refactors (`docs/CONSTITUTION.md:87`). This one was requested; its scope is exactly this document.

## 2. Goals, non-goals, anti-goals

**Goals**

- G-1. Cut A: move 9 finished records (5,690 lines) out of the live document set, content byte-identical; delete one abandoned stub script.
- G-2. Cut B: one library copy of `fetch` (3 monitors) and of `schema_validate_or_die` (4 anchor scripts).
- G-3. Cut C: one library copy of the notify retry policy; one shared test-assertion helper for test suites.
- G-4. Three gate tools (§9) so that moved paths and removed copies cannot silently come back.

**Non-goals**

- Changing what any script does, prints, exits with, or writes.
- Unifying values whose difference has no recorded reason (for example `--max-time 15` vs `20`, §5.1). They are kept as arguments.
- Cut D items (§7). Each gets its own design after 2026-12-07.
- Fixing bugs found on the way. They go to `.superpowers/comments/` (a bug fix fixes the bug, in its own change).

**Anti-goals (the refactor has failed if any of these happens, even if it "works")**

- A-1. The bytes of any inscription input or output change: `anchor-source.json`, the receipt, the history line, the memo.
- A-2. Any exit code, stdout byte, or written file of a migrated script changes for the same inputs. stderr also stays byte-identical (§5.2 explains how), so the equivalence gate needs no exception list.
- A-3. The suite roster count, or any suite's count of passing cases, goes down.
- A-4. A public URL changes (`public/**`, generated `public/api/*.json`).
- A-5. A transition script changes inside the freeze without a re-rehearsal (§3 C-4).
- A-6. Any work needs a host login, a `proton` command, or a broadcast.

## 3. Constraints

- **C-1. PRIME DIRECTIVE** (`docs/CONSTITUTION.md:11-28`). No session broadcasts. Every test stubs `proton`, `curl` and `ssh`. The tier-1 hook blocks raw broadcast text (`scripts/broadcast-guard.sh`). Implementers do not type such text, even in a test.
- **C-2. Requested refactor only** (`docs/CONSTITUTION.md:87`). Nothing outside §4–§6 is touched.
- **C-3. Testnet first for a new script path** (`docs/CONSTITUTION.md:93`). Cut B's anchor part changes code in transition units. None of them broadcasts, but a changed transition script must be exercised by a rehearsal before its next mainnet day (C-4).
- **C-4. Script freeze and the next transition.** The next transition is 2026-12-07 13:00:20 JST (`docs/tasks/validator-renew-cycle-7.md:89`). After a rehearsal for it, a change to a transition script is allowed only with a re-rehearsal (`docs/CYCLE_GATE.md:1715-1727`). The freeze also covers `bin/safe-broadcast`, `scripts/lib/side-effects.sh`, `scripts/cycle-gate.sh`, `scripts/node-info.sh` (`:1737-1744`). The supervisor's rule adds: from 2026-11-23 (two weeks before), transition scripts are not changed at all (`.superpowers/sdd/2026-11-10-simplify/org.md:20`).
- **C-5. Pending higher-priority work on the same files.** The double-inscription guard (`docs/superpowers/specs/2026-10-16-anchor-double-inscription-guard-design.md`) is decided but not implemented (no `ahr_find_cycle_anchor` in the tree). It edits `bin/safe-broadcast`, `scripts/sign-anchor-event.sh`, `scripts/run-testnet-rehearsal.sh`, `scripts/lib/cycle-context.sh`, `scripts/lib/anchor-history-read.sh`, `scripts/preview-cycle-anchor-broadcast.sh` (its §9). This design does not touch those six files.
- **C-6. Public repository** (`docs/CONSTITUTION.md:114-176`). No host identifier, address, account name or personal name enters any file or commit message. `scripts/publish-guard.sh` and gitleaks run on every change (`.github/workflows/ci-main.yml:30`).
- **C-7. No host contact.** All work is in the repository. Changes reach the validator host only through CI's fast-forward of its checkout (W6). A changed cron script takes effect there **at the cron's next tick after deploy** (`docs/CONSTITUTION.md:186`). That is why the monitor changes in cut B are tier 2, not tier 1.
- **C-8. Append-only audit documents** (W11, `docs/OPERATING_MODEL.md:155-169`). Audit documents are never edited in place. A move with byte-identical content is not an edit. A dated note may be appended.
- **C-9. Rename discipline** (W9, `docs/OPERATING_MODEL.md:144`). Every surface that names a moved path changes in the same commit. G1 (§9) checks it.
- **C-10. Scripts that run without the repository beside them.** `scripts/advance-host-checkout.sh` is piped from the CI runner and resolves its library with a fallback (`scripts/advance-host-checkout.sh:278-293`). `scripts/external-watch.sh` runs from a two-file bundle (finding 5). Neither gets a new library dependency.

## 4. Cut A — finished documents and unused scripts

### 4.1 Documents: the list

Destination rule (design-room call, §13 D-1): **audit records go to `docs/audits/`**, the home W11 already names (`docs/OPERATING_MODEL.md:157`). **Executed plans go to `docs/archive/plans/`**, with a 5-line `docs/archive/README.md` that says "historical records; not instructions; the live runbooks are in `docs/`". File names do not change. Every move is `git mv` with content byte-identical (rename similarity 100%).

"Finished" means all of: the work it plans or audits is in main; a live document or spec carries the current design; no runtime message, public page or generated artifact names it; no open operator decision lives in it.

| # | File (lines) | Decision | Reason | Destination | References to fix (file:line) |
|---|---|---|---|---|---|
| 1 | `docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md` (326) | **move** | W11 audit of the June cycle-gate rollout (T-1..T-6), done 2026-06-29 per its own banner | `docs/audits/` | none live. Cited only by W11 records: `docs/CYCLE_GATE_DAILY_OBSERVATION.md:422`, files 2–3, `docs/audits/*`. Append a dated note (below) |
| 2 | `docs/CYCLE_GATE_T55_AUDIT.md` (299) | **move** | Same rollout, T-5.5 audit; banner "T-7 deploy 完了済 2026-06-29" (`:5`) | `docs/audits/` | none live. Cited by files 1, 3 and `docs/audits/*` |
| 3 | `docs/CYCLE_GATE_TRD2_AUDIT.md` (329) | **move** | Same rollout, 6th-round audit; same banner (`:5`) | `docs/audits/` | none live. `docs/CYCLE_GATE_DAILY_OBSERVATION.md:421` (W11, note below) |
| 4 | `docs/PHASE_ALPHA_AUDIT_HANDOFF.md` (195) | **keep** | Its GitHub URL is written into the generated public evidence (`scripts/gen-evidence.sh:231,239`; `public/api/evidence.example.json:64,72`) and linked from `public/selection-evidence/index.html:355`, `public/ja/selection-evidence/index.html:355`. Moving it changes public output (A-4) | — | — |
| 5 | `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md` (509) | **keep** | Live runbook. Named in runtime messages of a frozen script (`scripts/run-testnet-rehearsal.sh:71,245,260,383`), in `scripts/sign-anchor-event.sh:99`, `scripts/lib/cycle-context.sh:441`, `docs/CYCLE_GATE.md:1052,1732`, `docs/VALIDATOR_RENEWAL.md:308,414`; and the 10-16 design edits it (its §6) | — | — |
| 6 | `docs/REHEARSAL_2026-09-01.md` (461) | **keep** | W11 record still cited by the canonical freeze rule (`docs/CYCLE_GATE.md:260,1747,1758`) and by `scripts/install-rehearsal-preflight.sh:1574` (frozen) | — | — |
| 7 | `docs/superpowers/plans/2026-07-06-anchor-static-propagation-convergence.md` (582) | **move** | Executed plan; its spec stays in `specs/`; it already marks a step "Superseded 2026-07-13" (`:252`) | `docs/archive/plans/` | none live (`docs/audits/constitution-2026-07-07-C1-C6-audit.md:56` is W11) |
| 8 | `docs/superpowers/plans/2026-07-09-host-checkout-auto-advance.md` (138) | **move** | Executed plan; spec and `docs/HOST_CHECKOUT_AUTO_ADVANCE.md` carry the design | `docs/archive/plans/` | none |
| 9 | `docs/superpowers/plans/2026-07-13-deploy-git-sot-inversion.md` (336) | **move** | Executed; the current model is in `.github/workflows/deploy.yml` and `docs/CONSTITUTION.md:186` | `docs/archive/plans/` | `docs/superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md:91` → `docs/archive/plans/2026-07-13-deploy-git-sot-inversion.md`. (`plans/2026-07-06-…:252` moves with it) |
| 10 | `docs/superpowers/plans/2026-08-06-c3-completion-and-guard-coverage.md` (214) | **move** | Executed plan for C3 of the 08-06 spec; `scripts/lib/side-effects.sh` is live | `docs/archive/plans/` | none |
| 11 | `docs/superpowers/plans/2026-09-24-web-probe-path-classification.md` (2,871) | **move** | Executed plan; every live cite points at the **spec** of the same date (`scripts/check-anomalies.sh:20,646`, `scripts/lib/web-probe.sh:8`, …), not the plan | `docs/archive/plans/` | none |
| 12 | `docs/superpowers/plans/2026-09-29-external-watch-log-caps.md` (85) | **keep** | A "spec + plan" (`:1`): the only design record of the log caps of a live component | — | — |
| 13 | `docs/superpowers/plans/2026-09-29-external-watch.md` (192) | **keep** | "spec + plan" (`:1-3`) of the live external watch; its rules G1/G2 are cited by `plans/2026-09-30-…:32` and 12 | — | — |
| 14 | `docs/superpowers/plans/2026-09-30-pulsevm-migration-readiness.md` (126) | **keep** | Not finished: triggers T6/T8 still wait upstream and "OPEN operator decisions (a)…" (`:112-118`). Its rules P2/P5 are cited with line numbers by `docs/superpowers/specs/2026-10-16-anchor-double-inscription-guard-design.md:68,263` | — | — |
| 15 | `docs/superpowers/plans/2026-10-15-identity-pq-signature.md` (595) | **move** | Executed (main switched to ML-DSA-87); the spec of the same date is what code cites (`scripts/lib/identity-pq.sh:4`, `public/api/identity.schema.v2.json:33,38`) | `docs/archive/plans/` | none |

Totals: **move 9** (3 audits 954 lines + 6 plans 4,736 lines = 5,690 lines), **keep 6**.

Appended note (W11 allows appending, not editing): one dated line at the end of `docs/CYCLE_GATE_DAILY_OBSERVATION.md`: `**REVISION <UTC>**: the three audits cited at :421-422 moved unchanged to docs/audits/ (simplify cut A).`

Other `docs/` files the survey flagged as possible (all **keep** in this cut; design-room call D-3):

| File | Why it stays now |
|---|---|
| `docs/PHASE5_CHECKLIST.md` | Cited by `scripts/notify-evidence-health.sh:17`, `scripts/operator-local/README.md:98`, `docs/OPERATOR_IDENTITY_SETUP.md:46` |
| `docs/PHASE5_REGEN_EXECUTION_2026-06-22.md` | Linked from `public/verify/index.html:242` and `public/ja/verify/index.html:242` (A-4) |
| `docs/PHASE6_CHECKLIST.md` | 27-line tombstone, but listed in `README.md:14` and `docs/OPERATOR_IDENTITY_SETUP.md:48`; a later pass may move it with the README edit |
| `docs/MAINNET_MIGRATION.md`, `docs/TAHOE_PIPELINE.md` | `TAHOE_PIPELINE.md` is named on `public/delegate/index.html:237` and `public/ja/delegate/index.html:233`; the two cite each other |
| `docs/tasks/*` | `scripts/check-renewal-memo.sh:79` reads this directory (unit 11) |
| `docs/audits/*` | Already the archive of audits |

### 4.2 Scripts: the list

Evidence searched for every script: all tracked files (`git grep` of the file name, which covers the cron installers `scripts/install-*-cron.sh`, `docs/CRON_CONVENTIONS.md`, `deploy/publication.json`, `.github/workflows/*`, git hooks and `tests/`). The repository cannot see the host's cron directories: 7 production crons have no installer in the repo (`docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md:239`). So "no reference in the repo" proves "unused" only for a script that also cannot run (or says it is dead).

| Script (lines) | Decision | Evidence |
|---|---|---|
| `scripts/operator-local/archive/test-phase6-memo-mock.abandoned.sh` (15) | **delete** (`git rm`) | Says "ABANDONED 2026-06-20" and only prints that and exits 1 (`:4-15`); mode 100644, not executable; cited only by W11 audits `docs/audits/constitution-2026-07-06T10-54-audit.md:157` and `…T11-45-audit.md:146` (historical, not edited). The directory becomes empty and disappears with it |
| `scripts/sanitize-history.sh` (142) | **keep** | A manual emergency tool (history scrub after a leak; prints the force-push for the operator, `:1-22`). "Called from nowhere" is expected for a manual tool. Listed in `TOOLKIT.md:216` |
| `scripts/security-audit.sh` (110) | **keep** | Header: "Designed to be run via /etc/cron.monthly/ or via SSH" (`:6`). Whether the host has it installed is **UNVERIFIED** and needs a host read (Q3) |
| `scripts/check-validator-period.sh` (36) | **keep** | Installed on the host's daily cron by `scripts/vps-bootstrap.sh:274-314` |
| `scripts/install-delegator-feed-started-at.sh` (52) | **keep** | Writes the host config file that `gen-anchor-source.sh` puts into the anchor source (`:5-11`). Needed again on a host rebuild. (It is missing from `docs/DISASTER_RECOVERY.md`; that is a comment, not this cut) |
| `scripts/ops/b6-enable-metal-anomalies-cron.py` (986) | **keep** (operator may decide otherwise, Q2) | A one-time tool from 2026-06, but it has a suite (`tests/ops/test_b6_enable_cron.py`) and is cited as evidence by `docs/postmortems/2026-06-anomaly-monitoring-resume.md:27,86,107`. Removing it lowers the roster (A-3) |

### 4.3 Cut A, how it is built

- One commit for the 9 moves + the one reference fix + the appended note + `docs/archive/README.md`; one commit for the script deletion; one commit adding G1 (§9) and its suite. Order: G1 first, so the move commit is checked by it.
- No `TOOLKIT.md` change (the deleted stub is not listed there).
- CI deploy skips `docs/**` changes (`.github/workflows/deploy.yml:24-29`), so the move commit does not trigger a deploy; the deletion commit does (it touches `scripts/`), and that deploy only fast-forwards the host checkout.

## 5. Cut B — one copy of each duplicated function

### 5.1 What is consolidated, what is not

Measured with a throwaway read-only parser over `git ls-files scripts bin` (108 bash files): 29 function names are defined in two or more files. Cut B handles the survey's five; cut C handles the notify ones.

| Function | Copies | Same meaning? | Decision |
|---|---|---|---|
| `fetch` | `scripts/check-anchor-publish-health.sh:324-337`, `scripts/check-identity-pins.sh:445-458`, `scripts/check-pulsevm-upstream.sh:973-987` | Same retry loop (stop at the first 200; `FYD_FETCH_ATTEMPTS` default 3; `FYD_RETRY_SLEEP` default 3; print the final status code; body in the outfile). Two differences: `--max-time 15` in the first vs `20` in the other two (**reason UNVERIFIED**); pulsevm stops on any 4xx (reason written at `:967-972`: a moved page or an exhausted rate limit cannot succeed, and retrying is impolite to a third party) | **B-1: consolidate**, keeping both differences as arguments |
| `schema_validate_or_die` | `scripts/append-anchor-history.sh:522-572` = `scripts/gen-anchor-receipt.sh:431-481` (identical); `scripts/gen-anchor-source.sh:691-741`; `scripts/operator-local/commit-anchor-source.sh:287-337` | Same logic (ajv with a `.json` copy, then python3+jsonschema, else fail closed). Differences are only: message prefix `ERROR (6):`/`ERROR (7):` vs `ERROR:`; "no validator" returns 7 vs 8 (each script's exit table, finding 3); `commit-anchor-source` adds " (see scripts/setup-schema-validator.sh)" to one message | **B-2: consolidate**, keeping all three differences as options |
| `sha256_pipe`, `sha256_file`, `sha256_str` | 5 anchor scripts; `gen-anchor-source.sh:132-139`'s `sha256_file` is a different function (readability check, `exit 3`) | Same output; the "no tool" branch exits with each script's own code (1 or 2) | **Not consolidated** (D-6): one-line tool selection in broadcast-path scripts; a new sourced file would add a freeze-list member and a rehearsal dependency to save about 25 lines |
| `shq` | `scripts/install-web-host-external-watch.sh:776`, `scripts/install-web-host-subdir-allowlist.sh:354`, `scripts/web-host-caddy-apply.sh:415` | Identical one-liner | **Not consolidated** (D-6): one line each; the three scripts source nothing today |
| `url_to_public_path` / `url_to_registry_path` | `scripts/check-identity-pins.sh`, `scripts/operator-local/gen-identity.sh` | Kept apart on purpose, held by an expiring test (`scripts/check-identity-pins.sh:522-538`; `tests/publication-registry/` T22) | **Not consolidated**: the existing decision stands |

### 5.2 Library shape

New files, one concern each, like the existing libraries (`scripts/lib/*.sh` each say "the single …" on line 2). Bash 3.2 compatible (the Mac runs it). Each file: header with `# CHAIN: none` and `# PRIME_DIRECTIVE: TESTNET-FIRST` in the first 10 lines (`docs/CONSTITUTION.md:26` asks it only of broadcast paths; adding it costs nothing and matches `scripts/check-anchor-history-reachable.sh:6-15`), no side effects at source time, never `exit` (only `return`), no reads of `FY_LIVE`.

**B-1. `scripts/lib/fetch-retry.sh`**

```
fy_fetch_retry [--max-time=SECONDS] [--no-retry-4xx] -- URL OUTFILE
  stdout: the final attempt's HTTP status code ("000" on transport failure), no newline
  OUTFILE: the final attempt's body
  return: 0 always after a valid call; 64 on a usage error
  env (unchanged names): FYD_FETCH_ATTEMPTS (default 3), FYD_RETRY_SLEEP (default 3), CURL (the caller's)
```

Callers: `check-anchor-publish-health.sh` → `--max-time=15`; `check-identity-pins.sh` → `--max-time=20`; `check-pulsevm-upstream.sh` → `--max-time=20 --no-retry-4xx`. Each script's `fetch()` becomes a one-line wrapper with the same name and arguments, so no other line in the script changes. `--max-time` has no default: a missing value is a usage error (64), so a caller cannot silently change its timeout.

**B-2. `scripts/lib/schema-validate.sh`**

```
fy_schema_validate [--tagged] [--no-validator-rc=N] [--hint=TEXT] -- SCHEMA DATA_FILE LABEL
  return: 0 valid | 6 invalid or schema unreadable or temp-copy failure | N no validator (default 7)
  stderr: byte-identical to today's copy for the same options:
    --tagged          "ERROR (6): …" / "ERROR (N): …"  (append-anchor-history, gen-anchor-receipt)
    (no --tagged)     "ERROR: …"                        (gen-anchor-source, commit-anchor-source)
    --hint=TEXT       inserted before the final "." of the no-validator message (commit-anchor-source only)
```

Callers keep a one-line `schema_validate_or_die()` wrapper with today's name and arguments:
`append-anchor-history.sh` and `gen-anchor-receipt.sh` → `--tagged`; `gen-anchor-source.sh` → `--no-validator-rc=8`; `commit-anchor-source.sh` → `--no-validator-rc=8 --hint=' (see scripts/setup-schema-validator.sh)'` (exact bytes copied from `:335`). The stale "no cross-script sourcing" comments (finding 3) are replaced by one line naming the library. `docs/SCHEMA_VALIDATOR_CONVENTIONS.md:20-24` ("each carry an identical … function") is updated in the same commit (W9). `commit-anchor-source.sh` sources nothing today; it gains the load lines below, resolved from its own directory.

**When the library cannot be loaded.** The guard sits at the library-load lines near the top of each script, not inside the wrapper, so the wrapper stays one line (G2's wrapper rule, §9). Each script assigns the path, checks it is readable, and sources it:

```
SV_LIB="<repo root>/scripts/lib/schema-validate.sh"
[ -r "$SV_LIB" ] || { echo "<script>: FATAL: cannot load scripts/lib/schema-validate.sh — cannot validate" >&2; exit <rc>; }
. "$SV_LIB"      || { echo "<script>: FATAL: cannot load scripts/lib/schema-validate.sh — cannot validate" >&2; exit <rc>; }
```

| Script | Where the guard sits | `<rc>` | Why this code |
|---|---|---|---|
| `scripts/gen-anchor-receipt.sh` | after its existing loads (`:194-197`) | 7 | its "no JSON schema validator available" code (`:62`); exit-table row `scripts/lib/cycle-context.sh:471` |
| `scripts/append-anchor-history.sh` | after its existing loads (`:141-150`) | 7 | its "no validator" code (`:55`); row `scripts/lib/cycle-context.sh:479` |
| `scripts/gen-anchor-source.sh` | after its existing load (`:60`) | 8 | its "no validator" code (`:23`); row `scripts/lib/cycle-context.sh:435` |
| `scripts/operator-local/commit-anchor-source.sh` | before its first fetch | 4 | its "did not validate" code, which already folds in "no validator" (`:100-102`); it already exits 4 literally (`:342`) |

Each code already means "validation could not run", and each row already exists, so no exit code and no exit-table row is added (the table is in `scripts/lib/cycle-context.sh`, which this design does not edit, C-5). The new stderr line can appear only when a tracked library file is missing from the checkout, a state that cannot exist before the change; every equivalence scenario has the library present, so A-2 holds. B-P3's mutation (the library returns 0 with no validator) is unchanged.

### 5.3 Properties and how they are checked

| # | Property | Check | Mutation that must turn the check red |
|---|---|---|---|
| B-P1 | Inscription artifacts unchanged | G3 (§9): run each anchor script's existing fixture scenarios at the base commit and at head; `anchor-source.json`, receipt and history line byte-identical | make `fy_schema_validate` return 0 on the python path for invalid data |
| B-P2 | rc / stdout / stderr unchanged for every migrated script | G3 on the existing suites' scenarios: `tests/gen-anchor-source/`, `tests/gen-anchor-receipt/`, `tests/append-anchor-history/`, `tests/anchor-publish-health/`, `tests/identity-pins/`, `tests/pulsevm-upstream/` | drop `--tagged` in one caller (stderr changes); change `--no-validator-rc=8` to 7 (rc changes) |
| B-P3 | Fail closed when no validator | existing "no JSON schema validator available" cases (`tests/gen-anchor-source/test-gen-anchor-source.sh:314`, `tests/append-anchor-history/test-r13-r18-schema-archive.sh:152`, `tests/gen-anchor-receipt/test-r13-r18-schema-archive.sh:269`) stay green | lib returns 0 when neither validator exists |
| B-P4 | The ajv `.json`-copy rule holds | `tests/schema-validate-ajv-path/` is retargeted to the library, run once per caller option set (4 sets), so its case count stays at least the same (A-3) | remove the `.json` copy |
| B-P5 | 4xx behaviour differs exactly where it does today | new cases in `tests/pulsevm-upstream/` and `tests/anchor-publish-health/`: a stub curl returning 404 then 200 → pulsevm sees 404 after 1 call; publish-health sees 200 after 2 | ignore `--no-retry-4xx` |
| B-P6 | No copy remains | G2 (§9) passes with the rows for `fetch` and `schema_validate_or_die` removed from its allowlist (the one-line wrappers pass G2's wrapper rule) | re-add an inline `fetch()` body in one script |
| B-P7 | Libraries never exit and never touch side effects | a suite greps each new lib for `exit`, `fyd_notify`, `fyd_push`, `FY_LIVE` (fixed list) | add `exit 1` to a lib |

**The three validator paths of B-2, and where each is checked.** `fy_schema_validate` has three paths. B-P1 (artifact bytes) and B-P2 (rc/stdout/stderr) are run by G3 once per path that can be set up; B-P4 is per path too.

| Path | Real or stub | Where | Evidence |
|---|---|---|---|
| ajv | **Stub**: the fake `ajv` that mimics ajv-cli 5's extension-based parsing, already in `tests/schema-validate-ajv-path/test-schema-validate-ajv-path.sh:30-40` (moved to a shared fixture so G3 can use it). A real ajv is not checked on this Mac: it is not installed here (measured 2026-11-10) | Mac and CI | the fake: `tests/schema-validate-ajv-path/test-schema-validate-ajv-path.sh:1-10,30-40`. CI installs a validator with `scripts/setup-schema-validator.sh` (`.github/workflows/validate.yml:164-165`, `.github/workflows/ci-main.yml:59-60`), which keeps an existing ajv or python3+jsonschema and otherwise installs ajv first (`scripts/setup-schema-validator.sh:25-33,71-79`); which one a CI runner ends with is **UNVERIFIED**, so a real-ajv run is UNVERIFIED |
| python3 + jsonschema | **Real** | Mac (present, measured 2026-11-10); CI only if the runner ends with it (UNVERIFIED) | the python branch of the function (`scripts/append-anchor-history.sh:554-569`); `tests/run-all-tests.sh:133-175` refuses to run without ajv or python3+jsonschema |
| none | **Real absence**: a PATH farm without `ajv` and `python3`, as the existing no-validator cases do | Mac and CI | `tests/gen-anchor-source/test-gen-anchor-source.sh:304-314`; the same case in `tests/append-anchor-history/test-r13-r18-schema-archive.sh:152` and `tests/gen-anchor-receipt/test-r13-r18-schema-archive.sh:269` |

Tiers (§10): B-1 is tier 2; B-2 is tier 3.

### 5.4 Timing

- **B-1** touches three monitors on the validator host's cron, none in the transition set or the freeze extension. It may land before 2026-11-23. It takes effect on the host at the next cron tick after deploy (C-7). Nobody logs into the host to check it: the three monitors' own alerting is the signal, and a read-only log check would be a separate W7 change for the operator to approve.
- **B-2** touches the four transition scripts below (units 5, 6, 8). Two options; the operator chooses (Q1).

| Script holding `schema_validate_or_die` | Unit (`docs/cycle-transition-steps.json`) | Runs on | Under the freeze? |
|---|---|---|---|
| `scripts/gen-anchor-source.sh` | 5 (`:38`) | validator host (phase 3, `docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md:88`) | yes, named at `docs/CYCLE_GATE.md:1722` |
| `scripts/operator-local/commit-anchor-source.sh` | 6 (`:45`) | operator Mac (phase 3, same `:88`) | yes, named at `docs/CYCLE_GATE.md:1726` |
| `scripts/gen-anchor-receipt.sh` | 8 (`:87`) | validator host (phase 6, same spec `:97`) | yes, `docs/CYCLE_GATE.md:1724` |
| `scripts/append-anchor-history.sh` | 8 (`:87`) | validator host (phase 6, same spec `:97`) | yes, `docs/CYCLE_GATE.md:1725` |

## 6. Cut C — notify policy and test helpers

### 6.1 Candidate 4: log, alert, die, notify (part C-notify)

What the copies really are:

- `alert()` (7 copies) is one line of logic in five of them: `fyd_notify "$1" "$2" "$3" || log "WARN: notify failed (alert was: $2 — $3)"` (`scripts/check-host-drift.sh:88-96`, `scripts/check-identity-pins.sh:397-399`, `scripts/check-pulsevm-upstream.sh:802-807`, `scripts/check-anchor-publish-health.sh:192-201`, `scripts/run-anchor-pipeline.sh:153-163` with `LOG`). The rest of each copy is comments. The two others differ for a reason: `advance-host-checkout.sh` has a fallback for a missing library (C-10); `append-anchor-history.sh:649-659` writes to stderr with `echo` because it has no `log()`.
- `log()` and `die()` differ because each script writes to its own log file or prefix. `check-pulsevm-upstream.sh:788-800` gates its log-file append on `fyd_is_live`; `check-anchor-publish-health.sh:184-190` appends without that gate. That difference has no recorded reason; per the rule, it is not merged here (noted in comments for a separate fix).
- The notify retry policy is duplicated with the same meaning (finding 6), around slightly different wrappers: `attempt_notify` (4), `notify_or_keep` (3), `retryable_notify_rc` (3).

**Decision:** move only the **retry policy** into `scripts/lib/side-effects.sh`, next to `fyd_notify`, the single notify exit. Leave `log`, `alert`, `die` in each script (each is the script's adapter to its own log channel; merging them would change log bytes that host logs and tests read, A-2).

Connection (added functions; nothing existing in `side-effects.sh` changes):

```
fyd_notify_retryable_rc RC
  return 0 if RC is 2, 4 or 5 (transport / 429 / 5xx from notify.sh), else 1

fyd_notify_retry_once [--tags=T] [--sleep=SECONDS] -- PRIO TITLE BODY
  calls fyd_notify --strict [--tags=T] PRIO TITLE BODY >/dev/null
  if that rc is retryable: sleep SECONDS (default 5), call once more
  return: the final rc, verbatim (0 also in dry mode, as fyd_notify)
  prints nothing of its own
```

Callers: `check-anomalies.sh` (`--tags` when given; fixed 5 s; keeps its own `[K-3]` message and `rc_priority_set 6`), `check-watch-validators.sh` (`--sleep="${NOTIFY_RETRY_SLEEP:-5}"`; keeps its own message), `notify-anchor-transition.sh` (its `exit 5` mapping stays in the script). Their `attempt_notify`/`retryable_notify_rc` copies are deleted; `notify_or_keep` stays per script as a thin wrapper.

**`external-watch.sh` is out of scope** (finding 5). Bringing it in would mean shipping a third file and re-running the web-host installer, a W7 change needing the operator's per-change approval, for a script whose `WATCH_LIVE` opt-in already does the same job and is tested (`tests/external-watch/`).

**Timing:** `side-effects.sh` is in the freeze extension (`docs/CYCLE_GATE.md:1743`), so C-notify lands after 2026-12-07.

Properties: rc of each caller unchanged for notify rc 0, 1, 2, 3, 4, 5, 64 (table-driven cases in `tests/side-effects/`, mutation: treat 3 as retryable); exactly 2 attempts at most (call-count stub, mutation: retry twice); the DRY line still appears in dry mode (`tests/side-effects-callers/`, unchanged); G2 rows for `attempt_notify` and `retryable_notify_rc` removed (`notify_or_keep` stays per script, with its row). Tier 2.

### 6.2 Candidate 5: test helpers (part C-tests)

`tests/lib/` holds only `pq-test-key.sh`. Suites define their own `ok`/`bad`/`pass`/`fail`/`assert_eq` (survey: 72/70/34/20/20 definitions) in at least six spellings (two-space indent, padding `%-70s`, `✓`, stdout vs stderr). `cleanup`/`setup`/`teardown`/`run` are fixture-specific and stay.

The runner's contract with a suite is small (`tests/run-all-tests.sh:288-305`): the exit code; a summary line matching `^(test-.*summary:|RESULTS:|Ran [0-9]+ tests? in)`; failure lines matching `^[[:space:]]*(FAIL|FATAL)`.

New `tests/lib/assert.sh`:

```
t_pass NAME          -> "PASS  NAME" on stdout; PASS+=1
t_fail NAME [WHY]    -> "FAIL  NAME[  (WHY)]" on stderr; FAIL+=1
t_assert_eq NAME WANT GOT
t_summary SUITE      -> "test-SUITE summary: PASS=<n> FAIL=<m>"; return 0 iff FAIL=0
```

Migration: one test directory per commit. A suite keeps its own `ok`/`bad`/`no` names as one-line wrappers if that is shorter than renaming call sites. Properties per commit: the suite's exit code and its multiset of (status, case name) pairs are identical before and after, by G3 suite mode (§9), which reads `✓`/`✗` and `PASS`/`FAIL` as the same statuses and does not compare marker text; after the commit the suite's summary line matches the runner's pattern; the roster line is unchanged; for each migrated suite of a tier-3 script, one mutation of the script under test still turns the suite red (recorded in the report). Suites that print `✓`/`✗` today will print `PASS`/`FAIL`, which also makes their failures visible to the runner's FAIL grep (`tests/run-all-tests.sh:303`). Tier 1-equivalent (tests only), except the mutation spot checks for tier-3 suites. May run in parallel with B (separate files).

## 7. Cut D — direction only (after 2026-12-07, each with its own design)

- **Candidate 6, installer scripts.** Seven cron installers (91–174 lines) share most of their text; three web-host allowlist installers share large blocks. Direction: one generator per family driven by a small table (name, schedule, command, env), with `scripts/check-cron-file.sh` as the existing lint. Not now: every installer is re-run on a host, which is a W7 change per host and per cron, and the cron installers write the files that `FY_LIVE=1` depends on (`docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md:229`).
- **Candidate 7, very large scripts.** `scripts/cycle-transition.sh` (1,922 lines), `scripts/install-rehearsal-preflight.sh` (1,657), `scripts/check-pulsevm-upstream.sh` (1,493), `scripts/check-anomalies.sh` (1,271) and others. Direction: split by phase or by check into sourced parts behind the same entry point. Not now: the first two are transition tools under the freeze, and a split changes line numbers that runbooks and designs cite (`docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md:141-176`).
- **Compose files and Makefile.** Four Caddy compose files remain although the validator host has served no web server since v0.8 (`docs/CONSTITUTION.md:186`); the Makefile header still says "Tahoe testnet". Direction: find which of them the web host's `caddy-static` and the local preview still use (**UNVERIFIED**), move the rest, and update the "8443"/"ops dashboard" leftovers (survey). Not now: `docs/CONSTITUTION.md` and W7 tooling cite them, and the check needs the web host's state.
- **`TOOLKIT.md` (351 lines, hand-written).** Direction: generate it from a fixed header block in each script, with a gate that fails when a script has no block. Not now: it touches every script's header, including frozen ones.

## 8. Where it connects / how to remove it

| Cut | Seams (the only places parts talk) | How it is added | How it is removed |
|---|---|---|---|
| A | File paths only. G1 reads `git diff --name-status -M` and file contents | `git mv` in one commit; G1 in its own commit | `git revert` of the move commit restores every path and the one reference; the appended note stays (append-only; it then describes a move that was undone, and a second dated note says so). G1 can stay: with no moves in range it passes |
| B | A function name and its options (§5.2). The lib is reached by one `.` line per caller | **Add-only first:** commit 1 adds the lib + its suite and touches no caller. Then **one commit per caller** replaces the body of that caller's function with the one-line wrapper and removes its G2 allowlist row | `git revert` of one caller's commit brings back that caller's inline copy and its allowlist row; the other callers are untouched. The lib, with no callers, can stay or be reverted last |
| C-notify | `fyd_notify_retryable_rc`, `fyd_notify_retry_once` in `side-effects.sh` | Same pattern: add-only commit, then one commit per caller | Revert per caller |
| C-tests | `tests/lib/assert.sh` functions and the runner's three line patterns | Add-only commit, then one commit per test directory | Revert per directory |

**No runtime switch (design-room call D-7).** The house rule asks for an on/off config key (`~/.claude/CLAUDE.md`, design principles). A refactor that keeps both the old and the new body behind a key keeps the duplication it exists to remove, and doubles what a rehearsal must cover. Here the on/off unit is the commit: every caller switches in exactly one commit that a single `git revert` undoes. G2 makes a half-reverted state visible (an inline copy without its allowlist row fails).

## 9. Gate tools

All three are scripts. Each has a suite under `tests/` with fixtures and one mutation per failure condition, which `tests/run-all-tests.sh` runs (so both CI workflows run them: `.github/workflows/ci-main.yml:70-71`). G2 needs no base, so its suite also runs it on the real tree on every run. G1 and G3 compare against a base commit, so the integration step runs them on the real tree with `--base=<main before the merge>` as part of the pre-merge gate. Each fails closed: a missing input, an unreadable file, a git error or an unknown line form is a failure, never a pass.

**G1 `scripts/check-doc-moves.sh` (cut A)**

- Input: `--base=<commit>` (required; missing → exit 2), the tracked tree at HEAD.
- Reads `git diff --name-status -M <base> HEAD`.
- Fails (exit 1) when: a rename under `docs/` or `scripts/` has similarity below 100; a file under `docs/` is deleted; a moved file's basename appears in a tracked file outside the exempt set in any form other than its new path; a deleted script's path appears outside the exempt set.
- Exempt set (fixed in the script, not a parameter): `docs/audits/**`, `docs/archive/**`, `docs/CYCLE_GATE_DAILY_OBSERVATION.md` (W11 records; their citations are as of their date); and the records of this move itself: tracked files directly under `docs/superpowers/specs/` or `docs/superpowers/plans/` whose file name contains `simplify-refactor`. This design names the old paths on purpose (§4.1, §4.2) to say what moved, it is committed before the move commit, and the implementation plan will do the same, so both read like W11 records: their paths are as of their date. The implementation plan MUST therefore be saved with `simplify-refactor` in its file name. The rule stays narrow: two directories, one topic word, no other spec or plan. Hand check against §4.1 and §4.2: every old path written there is in this file, which the rule exempts, so the move commit has 0 violations from it; the only live reference to an old path, `docs/superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md:91`, is changed in the move commit (§4.1 row 9). G1 reads tracked files only; `.superpowers/` is excluded by `.git/info/exclude`.
- Output: one line per violation `VIOLATION <file>:<line> <old> -> <new>`, then `OK <n> moves` or `FAIL <k>`. Exit 0 / 1 / 2.

**G2 `scripts/check-duplicate-functions.sh` (cuts B, C)**

- Input: `git ls-files scripts bin` (bash files: `*.sh`, and `bin/*` whose first line names bash or sh); allowlist `scripts/duplicate-functions.allow` (TSV: `name`, `file`, `reason`; `#` comments).
- Wrapper rule (the only automatic exception, and only when all three hold): the body has exactly one line that is not blank or a comment; that line's first word is a function defined in `scripts/lib/`; and the same file contains, on a line that is not a comment, the literal path `scripts/lib/<file>` of the library that defines it (scripts load libraries through variables such as `SV_LIB` or `FYD_LIB`, so the check is on the literal path, not on the `.` line). Such a definition is a wrapper, not a copy. Anything else is a copy. The fail-closed guard for a missing library lives at the load lines (§5.2), outside the wrapper, which is why a wrapper can stay one line: for example `schema_validate_or_die() { fy_schema_validate --tagged -- "$@"; }` with `SV_LIB="…/scripts/lib/schema-validate.sh"` in the same file meets all three conditions.
- Fails (exit 1) when: a name is defined in two or more files and a copy outside `scripts/lib/` has no allowlist row; a name defined in `scripts/lib/` is also defined outside it (no allowlist can excuse this); an allowlist row matches no copy, or its name is no longer duplicated (`OBSOLETE`, so the list shrinks in the same commit that removes a copy).
- Exit 2 on a malformed row, an unreadable file or a git error.
- Initial allowlist: every current duplicate, with a reason (29 names by the design room's throwaway count; the tool's own count is the one that counts). Rows for `fetch`, `schema_validate_or_die`, `attempt_notify`, `retryable_notify_rc` disappear during B and C.

**G3 `scripts/check-refactor-equivalence.sh` (cuts B, C)**

- Input: `--base=<commit>` and `--cases=<tsv>` (columns: script path, args, env, fixture dir, output files to compare, validator path `ajv-stub|python|none` (§5.3), optional list of fields to normalize).
- Materializes the base tree with `git worktree add --detach` into a temp dir; runs base and head with the same fixtures, `HOME` and `TMPDIR` in a temp dir, `FY_LIVE` unset, and a stub directory first on `PATH` for `curl`, `ssh`, `scp`, `proton`, `cleos` (stubs record calls and fail unless the case provides a response). Before each run it checks that `command -v proton ssh` resolve to the stubs; otherwise exit 2. The validator is set by the case's validator column, as in the table in §5.3; a case whose validator path cannot be set up on this machine exits 2 (could not run), never "equal".
- Compares rc, stdout, stderr and each listed output file byte for byte. A field may be normalized only if the case row names it (for clocks); any other difference fails.
- Suite mode: `--suite=<dir>` runs an existing suite at base and head and compares two things only: the exit code, and the multiset of (status, case name) pairs. A case line is optional leading whitespace, then a marker, then whitespace, then the name (trailing whitespace trimmed, so `%-70s` padding does not count). The marker table is fixed: `PASS` and `✓` mean pass; `FAIL` and `✗` mean fail. Marker text, other lines and the summary line are not compared. So a suite that printed `  ✓ X` / `  ✗ X` before and prints `PASS  X` / `FAIL  X` after compares equal, and a lost, renamed or flipped case compares different. (The `✓` suites today: `tests/deploy/test-build-json-manifest.sh:42-43` prints `  ✓ %s` / `  ✗ %s` and `RESULTS: …` at `:124`; the same pair appears in six more suites under `tests/deploy/` and `tests/install-web-host-*/`.) → §15
- Exit 0 equal, 1 different, 2 could not run. Removes its worktree on every exit.
- **UNVERIFIED:** which anchor scripts accept a fixed clock. Task 0 of the plan measures it; a script without one is compared with named normalized fields only.

## 10. Audit tier per component

Tiers follow `.superpowers/sdd/mac-operations-rules.md` rule 19. In a mixed bundle each component keeps its own tier.

| Component | Tier | Why | How it is checked |
|---|---|---|---|
| A: document moves, stub deletion, `docs/archive/README.md` | 1-equivalent | Writes no state; changes no behaviour; no public URL changes (rows 4–6 stay) | Machine gates only: G1, `scripts/publish-guard.sh`, gitleaks, `bash tests/run-all-tests.sh`. No reviewer |
| G1, G2, G3 | 2 | They are judgment parts: a wrong pass hides a regression | Fail-closed design (§9); a mutation per failure condition, recorded red then green; one reviewer at the end of the bundle |
| B-1: `fetch-retry.sh` + 3 monitors | 2 | Host cron scripts that write state and logs and notify | G3 on their suites; B-P2, B-P5, B-P6 with mutations; one reviewer at the end of the bundle |
| B-2: `schema-validate.sh` + 4 anchor scripts | 3 | The check that stands between a malformed artifact and the inscription | G3 byte-identity of the artifacts (B-P1) and of rc/stdout/stderr (B-P2); mutation net B-P1..B-P4, B-P7; a blind reviewer who did not implement it; the real-thing gate is the testnet rehearsal before the next mainnet transition (the operator unlocks the testnet keystore; the AI never broadcasts) |
| C-notify: retry policy in `side-effects.sh` + 3 callers | 2 | Notification and the alert state that depends on it | Table-driven rc cases with mutations (§6.1); `tests/side-effects-callers/` unchanged and green; one reviewer at the end of the bundle |
| C-tests: `tests/lib/assert.sh` + suite migrations | 1-equivalent | Test code only | G3 suite mode (same case names and counts); for each migrated suite of a tier-3 script, one mutation of that script still turns the suite red |

Kept for every tier, whatever the supervisor decides about reviewers: the break-to-prove mutations, checking that each claimed commit exists (`git cat-file -t`), and the pre-merge gate.

## 11. No AI in the flow

Every gate and check above is a bash script run by `tests/run-all-tests.sh` locally and in CI. None calls Claude or any LLM API, and none reads an API key. G2's suite includes a case that greps the three gate scripts for `anthropic`, `openai`, `claude`, `API_KEY` and fails on any hit.

## 12. Open questions for the operator

1. **When should B-2 (the schema check in four transition scripts) land?**
   - (a) **After the 2026-12-07 transition (recommended).** Before 12/7 the same rehearsal window is needed by the double-inscription guard (C-5), which protects the inscription itself; the Constitution ranks speed last (`docs/CONSTITUTION.md:60`). B-1, A and C-tests can still land before 11/23.
   - (b) Before 2026-11-23, covered by the pre-12/7 testnet rehearsal. Faster, but one rehearsal then proves two changes at once, and a B-2 problem found on the rehearsal day delays the guard.
2. **`scripts/ops/b6-enable-metal-anomalies-cron.py` (986 lines, a one-time tool from 2026-06).**
   - (a) **Keep (recommended).** It is cited as evidence by the postmortem, and removing it lowers the suite count (anti-goal A-3).
   - (b) Delete it and `tests/ops/`, accepting a roster of one fewer suite.
3. **`scripts/security-audit.sh` may be installed on the host's monthly cron.** Knowing requires a read-only look at the host, which is a W7 change needing your per-change approval.
   - (a) **Do not look now; keep the script (recommended).** Cost of keeping: 110 lines.
   - (b) Approve a read-only check later; if it is not installed, delete it in a later pass.

## 13. Calls made by the design room

These are the design room's decisions. The operator has not agreed to them yet.

- D-1. Audit records move to `docs/audits/` (W11's home) and executed plans to `docs/archive/plans/`, instead of everything to `docs/archive/`. One home for audits; one clearly-labelled place for "do not follow".
- D-2. "spec + plan" files and plans with open decisions stay in `plans/` (rows 12–14).
- D-3. The extra `docs/` candidates stay in this cut (§4.1 second table).
- D-4. Script decisions in §4.2 (one deletion; the rest kept for the reasons given).
- D-5. Differences without a recorded reason (`--max-time` 15/20, the ungated log append) are kept as arguments or left alone, not merged.
- D-6. One-line helpers (`sha256_*`, `shq`) are not consolidated; they go into G2's allowlist with reasons.
- D-7. No runtime switch; the revert of one commit is the on/off unit (§8).
- D-8. stderr stays byte-identical in B-2 (hence the `--tagged`/`--hint` options), so G3 needs no exception list.
- D-9. `log`/`alert`/`die` stay per script; only the notify retry policy moves (§6.1). `external-watch.sh` and `advance-host-checkout.sh` stay out.
- D-10. G2 uses condition-based staleness (`OBSOLETE`), not dates, so it never fails on a calendar date alone.
- D-11. New library files carry the `# CHAIN: none` / `# PRIME_DIRECTIVE` header even though they are not broadcast paths.

## 14. UNVERIFIED

- Why `check-anchor-publish-health.sh` uses `--max-time 15` and the other two use 20.
- Whether the host runs `scripts/security-audit.sh` from its monthly cron.
- Whether anything outside the repository (the operator's own shell, a host cron with no installer) calls `test-phase6-memo-mock.abandoned.sh`. Its body only prints and exits 1, so a call would already fail today.
- Which anchor scripts accept a fixed clock for G3.
- Which compose files the web host and local preview still use (cut D).
- The duplicate-name count (29) is from a throwaway parser; G2's parser may count differently.
- Whether `scripts/sanitize-history.sh` still runs cleanly against the rebuilt public history (not run; it rewrites history).
- Which validator (ajv or python3+jsonschema) a CI runner ends with after `scripts/setup-schema-validator.sh`; therefore whether B-2 is ever run against a real ajv (this Mac has none).

## 15. Amendment 2026-11-11 — G3 suite mode

Status: design-room calls (D-12..D-18 below); the operator has not agreed to them yet. Nothing above this section is rewritten; §9's suite-mode bullet only gains the pointer "→ §15". Audit tier: G3 stays tier 2 (§10); the test-directory migrations stay 1-equivalent, with the tier-3 mutation spot checks of §6.2.

### 15.1 Why

C-tests migrated 68 test directories under G3 suite mode; 13 were left (`.superpowers/sdd/2026-11-10-simplify/cut-b1-gates-report.md`, "終わらなかった所"). They fall into three kinds (15.2). Two gaps were also recorded (`.superpowers/comments/2026-11-11.md`, [g3]): a run has no time limit, and the cases-mode env column reserves only `PATH HOME TMPDIR FY_LIVE` (`scripts/check-refactor-equivalence.sh:351`). Reading the suite-mode code for this amendment found a third, which is the most important: suite mode compares only the exit code and the case multiset (`:520-524`), so a suite that is **red at both sides with the same failing cases compares equal** (`OK`). That is a pass without evidence and contradicts §9's "fails closed". 15.3 closes it before anything else lands.

### 15.2 The 13 directories, by kind, and the call for each kind

| Kind | Directories | Call (recommended first) |
|---|---|---|
| T — a case name carries a time, a random number or a temp path, so it differs between two runs of the same commit | `external-watch`, `deploy`, `reward-tracker`, `preview-cycle-anchor-broadcast`, `pq-identity-tools`, `side-effects-callers` (6) | **Pin the name in the test** (D-12) |
| M — the marker has a colon (`  ok: X` / `  FAIL: X`, or `PASS: X` / `FAIL: X`), which the fixed table does not read | `cycle-transition`, `cycle-transition-steps`, `renewal-memo`, `notify-anchor-transition`, one suite in `sign-anchor-event` (5) | **Fix G3: an opt-in, named marker set `--markers=colon`** (D-13) |
| N — the suite needs the real `curl`, so under G3's stub it is red at base and at head | `watch-validators`, `agent-readability` (2) | **Do not prove in G3; do not migrate in this cut** (D-14) |

**Kind T — pin the name in the test (D-12).**
- Why not in G3: the name varies between two runs of the *same* commit, so the instability belongs to the test, not to the refactor (comment m2). Masking digits or paths in G3 would let two different cases compare equal in every suite, which loosens the gate for all 81 directories to help 6. Temp paths in case names also put work-machine absolute paths into CI logs (`.superpowers/sdd/mac-operations-rules.md` rule 8).
- How: per directory, commit 1 ("pin") replaces only the varying part of each affected case name with a fixed word; the varying value stays in the check itself and may stay in the failure reason. Commit 2 is the assert migration, proven by G3 suite mode like the other 68.
- How the pin commit is proven (G3 cannot compare it, since its base names vary), all by machine except (c):
  - (a) `check-refactor-equivalence.sh --base=HEAD --suite=<dir>` at the pin commit exits 0: two independent runs of one commit give the same multiset, so the names are now stable. The same command at the pin commit's parent exits 1, which is how a directory is classified as kind T (15.8, step 0). If it already exits 0 at the parent, the directory is not kind T: no pin commit.
  - (b) `--base=<parent>` at the pin commit: the `SUITE` line shows `base_rc=0 head_rc=0` and equal counts; every `DIFF` line is `case-only-at-base pass:` or `case-only-at-head pass:`; the two kinds are equal in number, and that number equals the number of pinned names written in the lane report.
  - (c) The commit's diff touches only that directory's suite files and only string literals in name position (the reviewer reads it; test code).
- Second option (not recommended): a G3 argument naming, per suite file, a literal name prefix compared by prefix only. Narrower than masking, but it adds a judgment part to a tier-2 gate for a property the test can simply have.
- Third option (not recommended): prove without G3. Weaker than (a)–(c), which already use G3.

**Kind M — `--markers=colon` (D-13).**
- Forms seen on main fc3c6b2: `  ok: $1` / `  FAIL: $1` (`tests/cycle-transition/test-cycle-transition.sh:46-47`, `tests/cycle-transition-steps/test-cycle-transition-steps.sh:49-50`, `tests/renewal-memo/test-check-renewal-memo.sh:49-50`); `PASS: $1` / `FAIL: $1` (`tests/notify-anchor-transition/test-notify-anchor-transition.sh:30-31`).
- Rule: with `--markers=colon`, a case line is also: optional leading whitespace, then exactly `ok:` or `PASS:` (pass) or `FAIL:` (fail), case-sensitive, then at least one whitespace, then the name (trailing whitespace trimmed). The default table of §9 is unchanged and still applies; the colon set is added to it at both sides. Without the argument nothing changes.
- Fail closed: an unknown set name, `--markers` given twice, `--markers` with `--cases`, or `--markers=colon` on a suite file that has no colon-form line at base → exit 2. The last rule keeps the option from being left on by habit (the same idea as G2's `OBSOLETE`, D-10).
- Why G3 and not the test: turning `ok:` into `PASS  ` *is* the migration; the base output stays unreadable to G3 whatever the test does. Why not "other proof": G3 can do it with a small named opt-in, and counting more lines can only add `DIFF`s, never hide a lost case.
- These suites test transition scripts (§3 C-4). The migration changes tests only, never a script under `scripts/` or `bin/`, so the freeze is not engaged. Call: land them before the pre-12/7 rehearsal, so the rehearsal runs the migrated suites, or else after 2026-12-07. `cycle-transition*` and `sign-anchor-event` cover tier-3 scripts: one mutation of the script still turns the suite red (§6.2).

**Kind N — not proven in G3, not migrated in this cut (D-14).**
- A `curl` pass-through in G3 would open the gate's main safety property (no network, no host, no broadcast, §9) on every run. Rejected.
- Shipping a curl stub inside the suite changes what it tests: `tests/watch-validators/test-check-watch-validators.sh:54` and `:228` use the real `curl file://` and its transport-error path on purpose. That is a test redesign, out of scope.
- A separate proof outside G3 would need a second copy of the marker table and extraction (two sources of truth), for two suites. The gain (two suites on the shared helper) is smaller than that cost. The two suites keep their own helpers; the roster and their counts do not change (A-3 holds). If they are ever redesigned not to need the real `curl`, G3 proves their migration then.
- With 15.3 in place, G3 on these directories exits 2 ("base is red"), never `OK`.

### 15.3 Suite mode: the base must be green (D-15)

- For each suite file: if the base run's rc is not 0, or the base output has any fail-status case line, G3 exits 2 with `check-refactor-equivalence: <id>: base is red (rc=<n>, fail cases=<k>): cannot prove equivalence`. No `OK` is printed.
- Base green and head red is unchanged: `DIFF <id> rc` and/or the case lines, exit 1 (a real difference, not "could not run").
- Cases mode is unchanged: a non-zero rc is a normal, compared result there.
- No switch to allow a red base (that switch would be the hole; D-7's reasoning).
- This tightens existing behaviour: a red/red suite that was `OK` becomes exit 2. It never turns a non-`OK` into `OK`. The G3 lane re-runs the new G3 over the 68 migrated directories (base = parent of each migration commit, head = that commit); every one must still exit 0. Any exit 2 means that migration was never proven: it is reported to the supervisor, not fixed in the lane.

### 15.4 Time limit per run (D-16)

- `--timeout=<seconds>`, optional, digits only, 1..3600; default 600. Given twice, empty, `0`, `3601`, a sign or a unit → exit 2.
- It bounds each single run: one script (cases mode) or one suite file (suite mode) at one side. The whole G3 call is bounded by runs × limit; an outer limit on the pre-merge step is not designed here.
- On expiry: TERM to the run's process group, KILL 5 s later if anything is left; then exit 2 with `check-refactor-equivalence: <id>: timeout after <n>s at base|head`. Never a `DIFF` that lets the run continue, never `OK`: a run that did not finish proves nothing.
- The run starts as the leader of its own process group (perl `setpgrp(0,0); exec …`; perl is already required by G3 for the PATH farm, `:193`; no new dependency). One background watchdog, whose PID G3 records, does the TERM/KILL. G3 signals only the recorded PID and process group, never by name (rule 1; hook `block-mass-kill.py`). The existing EXIT/INT/TERM trap also stops the recorded group and watchdog before it removes the worktree. macOS has no `timeout(1)` by default, so G3 must not depend on it.
- Why 600: no suite time under G3 has been measured (15.9). The G3 lane times every suite once (15.8, step 0); if the slowest exceeds 300 s, it returns to the design room before the default is fixed.

### 15.5 Reserved env keys (D-17)

- Rule: a key is reserved when it can make the shell run something other than the script under test, change which program answers a command, swap the validator's module, or point git at another repository. Both sides would then agree for a reason that is not the script — a false "equal".
- Cases mode, column 3 (exit 2 `env key <k> is reserved`), in addition to `PATH HOME TMPDIR FY_LIVE`:
  - exact: `ENV`, `IFS`, `CDPATH`, `GLOBIGNORE`, `SHELLOPTS`, `PS4`;
  - prefixes: `BASH` (covers `BASH_ENV`, `BASHOPTS`, `BASH_XTRACEFD`, …), `LD_`, `DYLD_`, `GIT_`, `PYTHON`, `PERL5`, `G3_`.
  - Still allowed (the "just outside"): `TZ` (needed for clocks), `LC_*` (G3 already exports `LC_ALL=C`; a row's value applies to both sides alike), `GITHUB_*` (does not start with `GIT_`), `FY_*`/`FYD_*` other than `FY_LIVE`.
- Suite mode passes no row env (`:491`) but inherits the caller's environment apart from `BASH_ENV ENV FY_LIVE` and the three it sets (`:259`). Add `-u` for `SHELLOPTS BASHOPTS BASH_XTRACEFD CDPATH GLOBIGNORE PS4` to both `env` lines (`:250`, `:259`). `env -u` cannot remove a prefix, so prefixes apply to rows only.
- Second option (not recommended now): an allowlist of key forms. Stronger in the 5.3 sense, but it would change which existing rows are legal; tracked cases files on main: 0 (`git ls-files`, 2026-11-11), yet the lanes' scratch rows and G3's own suite fixtures use keys not surveyed. Revisit when a cases file is first tracked.

### 15.6 Properties and the break-to-prove table

Each property gets at least one mutation of `scripts/check-refactor-equivalence.sh` that turns the G3 suite red, recorded red then green (§10). "Just outside" rows are the case closest to the exception that must keep the old result.

| # | Property | Case(s) in the G3 suite | Mutation that must turn it red |
|---|---|---|---|
| P1 | Red base → exit 2 | fixture suite red at both sides with the same fail cases (rc 1) → exit 2, no `OK` | remove the base-red check (today's behaviour → `OK`) |
| P1b | rc 0 but a fail case at base → exit 2 | fixture prints `FAIL  x`, exits 0 at both sides → exit 2 | check rc only |
| P1c | Just outside: base green, head red → exit 1 with `DIFF`, not exit 2 | fixture green at base, red at head | apply the red check to head too |
| P2 | Colon set is opt-in | colon-only suite without `--markers` → exit 2 "no case lines at base" (as today) | make the colon set the default |
| P2b | Colon set compares across forms | base `  ok: X`, head `PASS  X` → exit 0; base `  ok: X`, head `FAIL  X` → exit 1; base `PASS: X` with X missing at head → exit 1 | map `FAIL:` to pass; drop `PASS:` from the set |
| P2c | Just outside: not case lines under the colon set | `OK: X`, `ok X`, `ok:X`, `okay: X`, `not ok: X` at base only → no case from them (they cannot create a `DIFF` or a count) | case-insensitive match; `\s*` instead of `\s+` after the colon; unanchored match |
| P2d | Bad use → exit 2 | `--markers=tap`; `--markers` twice; with `--cases`; `--markers=colon` on a suite with no colon line at base | remove each check (one mutation per condition) |
| P3 | Timeout → exit 2 | `--timeout=2`, fixture sleeps 30 → exit 2 within 2+5+slack s, message names the side; the test bounds its own wait (perl `alarm`) so a broken G3 fails instead of hanging | disable the watchdog; never exit 2 on expiry |
| P3b | The whole process group is stopped | fixture starts a background child that writes its PID; after G3 returns, `kill -0 <pid>` fails | signal the leader PID only |
| P3c | Just outside: a run that ends in time is a normal result | `--timeout=5`, fixture ends in 1 s → exit 0 | fire at 0 s / treat limit as already expired |
| P3d | Argument check | `0`, `3601`, `10s`, `-1`, empty, twice → exit 2; `1` and `3600` accepted | widen or drop the range check |
| P4 | Reserved keys refused | one row each: `ENV`, `IFS`, `CDPATH`, `GLOBIGNORE`, `SHELLOPTS`, `PS4`, `BASH_ENV`, `BASHOPTS`, `LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`, `GIT_DIR`, `PYTHONPATH`, `PERL5LIB`, `G3_X` → exit 2 | drop one exact key; drop one prefix (one mutation each class) |
| P4b | Just outside: still accepted | `TZ=UTC`, `LC_ALL=C`, `GITHUB_SHA=x`, `XBASH_ENV=1`, `FYD_X=1` → run happens | prefix match unanchored (substring); `GIT` without `_` |
| P4c | Suite-mode child does not inherit the six shell keys | caller exports `SHELLOPTS=xtrace` etc.; the fixture suite prints whether each is set → unset | drop one `-u` |
| P5 | Instability is seen, not masked | fixture suite whose case name contains `$RANDOM`, `--base=HEAD` → exit 1 | any normalization of digits in names |
| P6 | Existing cases keep their meaning | the current G3 suite (`PASS=130`) stays green; any existing case whose expectation changes is listed in the lane report with its reason (only P1 may cause one) | — (regression, not a mutation) |

### 15.7 Where it connects / how to remove it

- Seams: G3's command line (`--markers=`, `--timeout=`), the env-key check of cases column 3, the case-line extraction (`g3_extract_cases`), the process start and the two `env` lines in `g3_run`, and the per-suite comparison in `g3_suite_mode`. Nothing else changes; no other script calls G3 at runtime.
- Added only: both arguments are optional. Without them, G3 behaves as §9 except three tightenings (red base → exit 2; a 600 s limit; more reserved keys). Each can only turn a former `OK` or hang into exit 2, never a former non-`OK` into `OK`. No existing cases row changes meaning unless it used a reserved key, and such a row was already unsafe.
- The G3 lane lands as four commits, each revertable alone: (1) red base, (2) timeout, (3) reserved keys, (4) `--markers=colon`. `git revert` of one restores §9's behaviour for that part only.
- The migrated suites never call G3; G3 is their proof at merge time, recorded in the lane report. Reverting (4) does not break the kind-M suites; only a later re-proof of those commits would need it back. Kind-T pin commits revert per directory (the names vary again; nothing else changes).
- No runtime switch, for D-7's reason; a switch for 15.3 would be the hole.

### 15.8 Lanes and the files each may touch

| Step / lane | Directories | Files it may touch | Depends on |
|---|---|---|---|
| 0 (inside L1, first, no code) | all 13 + the 68 | none; writes only its lane report | — |
| L1 G3 | — | `scripts/check-refactor-equivalence.sh`, `tests/check-refactor-equivalence/**`, the G3 row of `TOOLKIT.md` | — |
| T1 | `external-watch`, `deploy`, `reward-tracker` | `tests/<dir>/**` of these only | L1 reviewed |
| T2 | `preview-cycle-anchor-broadcast`, `pq-identity-tools`, `side-effects-callers` | `tests/<dir>/**` of these only | L1 reviewed |
| M1 | `cycle-transition`, `cycle-transition-steps` | `tests/<dir>/**` of these only | L1 reviewed |
| M2 | `renewal-memo`, `notify-anchor-transition`, `sign-anchor-event` (the colon suite only) | `tests/<dir>/**` of these only | L1 reviewed |
| (none) | `watch-validators`, `agent-readability` | — | — (D-14) |

- Step 0, by machine: for each of the 13, run the current G3 with `--base=HEAD --suite=<dir>` and record exit code and the time (`time`); this confirms the kind (T exits 1; M exits 2 "no case lines"; N shows `base_rc` ≠ 0) and finds which `sign-anchor-event` file is kind M. Also time the 68. A directory whose measured kind differs from 15.2 goes back to the supervisor before its lane starts.
- No lane touches `scripts/**` (other than L1's one file), `bin/**`, `tests/lib/assert.sh`, `tests/run-all-tests.sh`, any workflow, or another lane's directory. A lane that needs one of them stops and returns.
- T1, T2, M1, M2 may run in parallel (no shared file) after L1, within the headcount (`~/.claude/bin/org-headcount`). Each directory is one commit (kind M) or two (kind T: pin, then migrate). Merge order of the bundle: L1's four commits first, then the directory lanes in any order.
- Each lane's proof: kind T as 15.2 (a)–(c) then G3 OK; kind M: G3 `--markers=colon` OK; tier-3 directories (`preview-cycle-anchor-broadcast`, `pq-identity-tools`, `cycle-transition*`, `sign-anchor-event`): one script mutation still red, the script restored and not committed. One reviewer at the end of the bundle for L1 (tier 2).

### 15.9 UNVERIFIED

- Which `sign-anchor-event` suite file is kind M (the report says one; step 0 finds it).
- Why `agent-readability` is red under the stubs: its suite file shows no direct `curl`; it may reach `curl` through a script it calls (step 0 records `base_rc`).
- That `deploy` and `side-effects-callers` are kind T (from the report; not re-measured by the design room).
- That `--base=HEAD` runs with the current G3: nothing refuses base = HEAD (`:123-124` resolve both independently), but the design room ran nothing.
- Whether an existing G3 suite case expects `OK` for a red/red suite (P6 lists it if so).
- The slowest suite's time under G3 (step 0), and hence whether 600 s is right.

### 15.10 Calls made by the design room (2026-11-11)

- D-12. Kind T: pin names in the test; no name masking in G3.
- D-13. Kind M: an opt-in named marker set `--markers=colon`; the default table unchanged.
- D-14. Kind N: no curl pass-through; not migrated in this cut.
- D-15. Suite mode: a red base exits 2; no switch.
- D-16. A per-run limit, default 600 s, expiry exits 2; process group stopped by recorded PID only.
- D-17. Reserved env keys by exact name and prefix (cases column 3), plus six more `env -u` names in both run environments; an allowlist is left for when a cases file is first tracked.
- D-18. The G3 change lands as four separately revertable commits, before any directory lane.

Questions for the operator from this amendment: none. The calls above are listed so they can be checked while reading.
