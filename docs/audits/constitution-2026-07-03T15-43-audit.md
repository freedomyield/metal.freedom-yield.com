# Constitution Audit — 2026-07-03T15:43 (JST)

## Summary

- **Overall**: 🔴 (1 critical root: real validator host IP literal tracked in the PUBLIC repo)
- **Range**: committed HEAD = `763b13e` (unpushed; origin/main = `51430b1`) + operator working-tree C2 fix (uncommitted, examined but not modified)
- **Scope**: all (D1–D10)
- **Review preset**: `thorough` (C1–C12)
- **Violations**: D-series 🔴 1 (D3) / 🟡 2 (D8, D9) / UNVERIFIED 1 (D4) — C-series 🔴 1 (C1, same root as D3) / 🟡 1 (C2 residual)
- **Auditor**: constitution-auditor agent (read-only; no implementation performed)

All IPv4 host literals in this report are REDACTED as `<REDACTED-HOST-IP>`; only `file:line` positions and the fact of detection are recorded, per the redaction obligation.

---

## 🔴 CRITICAL — read first

**Real validator host IP literal is tracked in the PUBLIC repo, force-added by the unpushed HEAD commit.**

- File: `.claude/agents/constitution-auditor.md:74` and `:128` — both contain the real validator host IP (`<REDACTED-HOST-IP>`), presented as "example" text of the very pattern D3/C1 forbid.
- Tracked: yes. Gitignored: no. Only 1 tracked file carries this IP (`git grep` count = 1).
- Introducing commit: `763b13e` — **NOT pushed** (origin/main = `51430b1`; `git merge-base --is-ancestor` → NOT ancestor). The public GitHub remote (`github.com/freedomyield/metal.freedom-yield.com`) does not yet have it.
- Aggravating factor: the **same commit** `763b13e` also edited `.gitignore` to add `!.claude/agents/**` and `!.claude/commands/**` — negation rules that **deliberately un-ignore** these paths (`.claude/*` is ignored at `.gitignore:85`). So the commit that introduced the IP literal is also the commit that opts it into public-repo shipping.
- Violation basis: Constitution §4.1 S8 (infrastructure-identifier disclosure) + memory rule `feedback_no_literal_host_identifier` (validator host IP literal forbidden; use `${VALIDATOR_HOST:?}` + placeholder).
- **Redemption window is OPEN**: because `763b13e` is unpushed, this can be corrected by the operator before push (amend/rebase to redact the IP to a placeholder such as `203.0.113.10` / `<host-ip>`). The auditor does not implement the fix.

Same root also surfaces as **C1** below.

---

## Constitution dimensions (D-series)

### D1 — PRIME DIRECTIVE 4 gate consistency

**Status**: ✅ pass

**Method**: grep the 4 gates across the 4 canonical sources; independently re-fetch both chain_id constants via read-only `get_info`.

**Evidence**:
- `docs/CONSTITUTION.md:17-20`: gate 1 testnet-first (identical shape, operator-reviewed testnet tx), gate 2 explicit per-invocation authz naming `{chain, actor, permission, action, memo, quantity}`, gate 3 pre-flight `chain:get` match, gate 4 `--dry-run`/offline-sign exhausted.
- `CLAUDE.md:9`: all four gates listed identically (1 testnet-first / 2 per-invocation authz / 3 pre-flight `chain:get` / 4 `--dry-run` exhausted).
- Tier-1 `scripts/broadcast-guard.sh`: mechanical shape-block present.
- Tier-2 `bin/safe-broadcast:6`: `# PRIME_DIRECTIVE: TESTNET-FIRST` marker within first 10 lines; gate 1 (`--testnet-tx-id` 64hex resolvable, line 141+), gate 3 (chain_id exact match, line 121+), default chain testnet-a.

**Independent recompute (EXACT match)**:
- mainnet chain_id: fetched `proton.greymass.com/v1/chain/get_info` → `384da888112027f0321850a169f737c33e53b388aad48b5adace4bab97f437e0` — EXACT match to `bin/safe-broadcast:129` default `FYD_MAINNET_CHAIN_ID`.
- testnet chain_id: fetched `testnet.protonchain.com/v1/chain/get_info` → `71ee83bcf52142d61019d95f9cc5427ba6a0d7ff8accd9e2088ae2abeaf3d3dd` — EXACT match to `bin/safe-broadcast:127` default `FYD_TESTNET_CHAIN_ID`.

**Finding**: none. All four sources agree; both chain_id constants verified against live read-only endpoints.

### D2 — Broadcast-capable command shape coverage

**Status**: ✅ pass

**Method**: extract the `BROADCAST_PATTERNS` ERE array from `scripts/broadcast-guard.sh` (committed HEAD) and cross-match against the expected shape list.

**Evidence** (`scripts/broadcast-guard.sh:76-84`):
- `proton action` ✓ (`proton[[:space:]]+action`)
- `proton transaction` / `transaction:push` ✓ (`proton[[:space:]]+transaction([[:space:]]|:push)`)
- `cleos push action|transaction|push_transaction` ✓ (`cleos.*push[[:space:]_]+(action|transaction)`)
- `curl|wget ... push_transaction` ✓, `issueTx` ✓, `eth_sendRawTransaction` ✓
- metalgo `/ext/bc/[XPC]` ✓ (bonus coverage beyond the base list)

**Finding**: none. Every expected shape (proton / cleos / curl-wget / metalgo ext-bc) is present.

### D3 — Secrets: no tracked secret literal

**Status**: ❌ fail 🔴

**Method**: `gitleaks detect` (both `--no-git` working-tree and full git-history), plus custom `git grep` for host IP / `operator` / Slack / OpenAI token patterns across tracked files.

**Evidence**:
- 🔴 Real validator host IP literal: `.claude/agents/constitution-auditor.md:74`, `:128` (see CRITICAL block). Tracked, non-gitignored, public-repo bound.
- 🟡 `operator` personal handle in 3 tracked files: `.claude/agents/constitution-auditor.md`, `.claude/commands/constitution-audit.md`, `docs/audits/constitution-2026-07-03T11-58-audit.md` (all introduced by `763b13e`). The agent's own D3 rule states "新 commit で docs/*.md に `operator` 文字列 追加 = 🔴"; by that self-defined bar, shipping the operator's handle to a PUBLIC repo is a personal-identifier concern (memory `feedback_no_operator_name` / CONFIDENTIAL personal info).
- gitleaks full git-history scan (407 commits, 5.81 MB): **no leaks found**.
- gitleaks `--no-git` working-tree scan flagged `tests/cycle-gate/fixtures/test-identity-key` (private-key rule). **Out of scope**: this file is NOT tracked (`git ls-files --error-unmatch` errors: "did not match any file(s) known to git"), NOT in HEAD tree, has no git history, and IS gitignored. Per D3 spec, untracked fixtures are out-of-scope.
- `.gitleaks.toml` present with documented path allowlist (`scripts/dr-drill.sh` SHA-256 fingerprints, `public/api/anchor-source.*.json` Merkle roots) — sane, non-silencing.
- `.gitignore` blocks `*.key`, `*.pem`, `.env`, `.env.*` (with `!.env.example`).

**Finding**: 🔴 host IP literal (root issue). 🟡 `operator` personal handle in public-tracked files.

**Suggested fix (指摘 のみ)**: before pushing `763b13e`, amend to replace the real IP with a placeholder (`<host-ip>` / RFC-5737 `203.0.113.x`); decide whether `operator` handle belongs in the public-shipped agent/command files or should be genericized. Auditor does not implement.

### D4 — 10-axis ↔ anchor schema correspondence

**Status**: ⚠ UNVERIFIED (dimension premise does not match the actual document)

**Method**: enumerate the "10 axis" of `docs/STRATEGIC_TARGET_ALIGNMENT.md` and cross-map to `docs/ANCHOR_SOURCE.md` schema fields.

**Evidence**: both files exist. But `docs/STRATEGIC_TARGET_ALIGNMENT.md` contains **no enumerated "10 axis"** — its structure is 11 prose `##` sections (Executive summary, Institutional procurement reality, Metallicus subnet selection, Explicit unreachable set, Reachable set, What anchor design should target, Task list re-scoping, New tasks, Non-goals, Change log). `grep -c 'axis|Axis|軸'` = 0.

**Finding**: the D4 dimension's "10 axis" referent does not exist in the repo doc, so the cross-match cannot be verified as specified. This is a spec-vs-reality gap in the auditor definition itself (`.claude/agents/constitution-auditor.md` D4), not a repo content violation. Classified UNVERIFIED rather than pass/fail to avoid rubber-stamping a non-existent structure.

**Suggested fix (指摘 のみ)**: either (a) update the auditor D4 spec to match the actual strategic-doc structure, or (b) add an explicit 10-axis enumeration to `STRATEGIC_TARGET_ALIGNMENT.md` if that structure is intended.

### D5 — schemaVersion single-value consistency

**Status**: ✅ pass

**Method**: `git grep -hoE '"schemaVersion"...' -- '*.json' '*.jsonl'` → distinct value count.

**Evidence**: only value observed = `1` (2 tracked occurrences). Distinct numeric set = `{1}`.

**Finding**: none. (Observation: only 2 tracked json/jsonl carry `schemaVersion`; most state/receipt files are runtime-generated/untracked, so the tracked sample is small but internally consistent.)

### D6 — Heading h1→h2→h3 nesting

**Status**: ✅ pass

**Method**: Python scan of all `docs/**/*.md` + top-level `*.md`, code-fence aware, flagging any `h{n}` → `h{>n+1}` jump.

**Evidence**: heading-skip violations = 0.

**Finding**: none.

### D7 — Inline `style="..."` (CSP style-src 'self')

**Status**: ✅ pass

**Method**: `git grep -nE 'style="' -- '*.html' '*.md'`.

**Evidence**: 2 hits, both are rule-documentation text, not real inline-style attributes:
- `.claude/agents/constitution-auditor.md:96-99`: the D7 rule definition and its grep pattern.
- `CLAUDE.md:35`: the prohibition statement itself.

**Finding**: none. No actual inline `style="..."` attribute in any HTML/site content.

### D8 — Commit single-purpose

**Status**: 🟡 flag (borderline multi-purpose)

**Method**: examine the unpushed delta commit `763b13e` file spread and subject.

**Evidence**: subject = "feat(agents): add constitution-auditor agent + /constitution-audit slash command". Files touched:
- `.claude/agents/constitution-auditor.md` (+367)
- `.claude/commands/constitution-audit.md` (+52)
- `.gitignore` (+4, negation rules to force-track the above)
- `docs/audits/constitution-2026-07-03T11-58-audit.md` (+113) — an audit **output** report, not named in the subject.

**Finding**: 🟡 the commit bundles the auditor feature (agent + command + gitignore plumbing) together with an audit-report artifact (`docs/audits/…11-58`). The gitignore plumbing is arguably on-topic; the bundled audit report is a distinct artifact and slightly dilutes single-purpose. Judgment call — not critical, but worth noting since the same commit is the one carrying the 🔴 IP literal (which the review would ideally have caught before commit).

### D9 — TOOLKIT.md ↔ scripts/ sync

**Status**: 🟡 flag

**Method**: bidirectional diff — each `scripts/*.sh` basename (and stem) grepped in `TOOLKIT.md`; each `scripts/*.sh` reference in `TOOLKIT.md` checked for file existence.

**Evidence**: 19 of 39 scripts are NOT catalogued in `TOOLKIT.md` (stem match also misses all 19): `anomaly-state-init.sh`, `append-anchor-history.sh`, `broadcast-guard.sh`, `check-anchor-publish-health.sh`, `cycle-gate.sh`, `gen-anchor-receipt.sh`, `gen-anchor-source.sh`, `install-delegator-feed-started-at.sh`, `install-metal-anchor-publish-health-cron.sh`, `install-tier1-hook.sh`, `install-xserver-anchor-source-allowlist.sh`, `install-xserver-sig-allowlist.sh`, `notify-evidence-health.sh`, `post-anchor-event.sh`, `resume-after-cycle-start.sh`, `run-anchor-pipeline.sh`, `run-testnet-rehearsal.sh`, `sign-anchor-event.sh`, `watch-anchor-events.sh`. Reverse direction: 0 stale references (no TOOLKIT entry points at a missing file).

**Finding**: 🟡 the anchor-pipeline + broadcast-enforcement + install-* + cycle-gate families (largely added late-June/July) are not in the public `TOOLKIT.md` catalog, which explicitly states "Everything in `scripts/` is committed to this public repo so other Metal validators can fork what's useful". The catalog is 19 scripts behind. Not a security issue; a documentation-completeness gap.

### D10 — OPERATING_MODEL W1–W10 ↔ script existence

**Status**: ✅ pass (vacuous)

**Method**: extract `scripts/X.sh` references from each W-section of `docs/OPERATING_MODEL.md`; check existence.

**Evidence**: W1–W10 headings all present (`docs/OPERATING_MODEL.md:24,44,55,72,84,94,110,124,137,147`). The W-sections reference **runbook docs** (e.g. W3 → `docs/VALIDATOR_RENEWAL.md`) and JSON artifacts, but name **zero** `scripts/` paths (basename/stem grep across all 39 scripts → 0 matches).

**Finding**: none. No W-section references a script that is absent, so the "referenced script exists" invariant holds vacuously. (Observation: the operating model is intentionally script-agnostic and delegates to per-workflow runbooks.)

---

## Simplified review (C-series, thorough C1–C12)

### C1 — Secret / literal in additions

**Status**: 🔴 fail (same root as D3)

**Evidence** (`git show 763b13e` additions): real validator host IP literal added at `.claude/agents/constitution-auditor.md:74` (`+ 実 validator host IP literal (例: <REDACTED-HOST-IP> 系)`) and `:128` (`+ fail 例: … operator IP は <REDACTED-HOST-IP>`). `operator` personal handle added across the agent/command/audit-doc additions. No base64-32B+ literals found.

**Finding**: 🔴 host IP added; 🟡 `operator` handle added. See CRITICAL block + D3.

### C2 — Broadcast enforcement defense-in-depth

**Status**: 🟡 (residual C2-2 OPEN; C2-1 & C2-3 CLOSED in working tree)

**Method**: diff committed HEAD vs operator working-tree `scripts/broadcast-guard.sh` + `bin/safe-broadcast`; run both test suites (working-tree version); reconcile against prior residuals C2-1/C2-2/C2-3 recorded in `docs/audits/…11-58:67-91`.

**Evidence**:
- Committed HEAD `scripts/broadcast-guard.sh` = OLD token-override version (`git show HEAD:… | grep FYD_SAFE_BROADCAST` → absent). So at committed HEAD, a fresh token still lets a raw broadcast through (C2-1 open).
- Working-tree `scripts/broadcast-guard.sh` (uncommitted): raw broadcast shape now **refused UNCONDITIONALLY** unless `FYD_SAFE_BROADCAST=1` (set only by `bin/safe-broadcast`); token alone no longer overrides → **C2-1 CLOSED** in working tree.
- Working-tree `bin/safe-broadcast` (uncommitted): gate 3 now parses `.chain_id` via `jq` and compares **EXACTLY** to `EXPECTED_CHAIN_ID` (mainnet `384da888…` / testnet `71ee83bc…`, both independently verified in D1) → **C2-3 CLOSED**.
- **C2-2 residual OPEN (weakest)**: gate 1 still only verifies the `--testnet-tx-id` is 64-hex-shaped and resolvable on the testnet endpoint; it does NOT fetch the testnet tx's action/memo composition and compare its shape-hash against the mainnet `--tx` payload (test cases remain "wrong length" / "shape-valid but unresolvable"). So a resolvable-but-different testnet tx would still satisfy gate 1. Compensating control per `…11-58:89-91` = 段3 (endpoint isolation) + 段4 (cron cross-check), queued.
- Tests (working-tree version, actually invoked): `tests/broadcast-guard/test-broadcast-guard.sh` → **PASS=27 FAIL=0**; `tests/safe-broadcast/test-safe-broadcast.sh` → **PASS=16 FAIL=0** (incl. "gate 3: chain_id mismatch → refuse (exit 4)").

**Finding**: 🟡 substantial defense-in-depth improvement landed in the working tree (C2-1, C2-3 closed, 43 tests green), but (a) it is **uncommitted** — committed HEAD still ships the weaker token-override guard, and (b) **C2-2 remains OPEN**. Not a mainnet 7/5 T-H hard blocker given 段3/段4 are queued; disclosed per the residual-transparency requirement. Auditor did not touch the working-tree fix.

### C3 — Installer-script-first

**Status**: ✅ pass

**Evidence**: `git show 763b13e -- '*.md'` additions grepped for `sudo `/`rm -rf`/`chown -R` → the single hit (`:194`) is the C3 rule's own definition text, not a paste-ready operator one-liner.

**Finding**: none.

### C4 — Added-script shebang + `set -euo pipefail`

**Status**: ⚠ N/A in-range (no scripts added in `763b13e`) + informational note

**Evidence**: `git show --name-status 763b13e` → no `A scripts/*.sh`. Informational (operator working-tree files, not added-in-range): `scripts/broadcast-guard.sh` and `bin/safe-broadcast` both have `#!/usr/bin/env bash` shebang but declare `set -u` only (`:46` / `:68`) — no `-e` / `-o pipefail`. For a guard/wrapper that manages explicit exit codes (0/1/2/3/4 semantics), omitting `set -e` is a defensible deliberate choice; flagged only as an observation, not an in-range violation.

### C5 — JSON schema additive vs breaking

**Status**: N/A (no `schema*.json` / `*.schema.json` changed in range)

**Evidence**: `git show --stat 763b13e | grep -i schema` → matches are prose in the agent doc only; no schema file in the changeset.

### C6 — (undefined in auditor spec)

**Status**: N/A. The auditor definition (`.claude/agents/constitution-auditor.md`) does not define C6 (jumps C5 → C7). No criteria to apply.

### C7 — File mode

**Status**: ✅ pass

**Evidence**: `git ls-files -s` for the `763b13e` additions → `.claude/agents/constitution-auditor.md`, `.claude/commands/constitution-audit.md`, `docs/audits/…11-58`, `.gitignore` all `100644` (correct for .md/.gitignore). Working-tree `scripts/broadcast-guard.sh` + `bin/safe-broadcast` = `-rwxr-xr-x` (755, correct). No tracked `*.key`/`*.pem`/`.env*`.

**Finding**: none.

### C8 — Added-script test existence

**Status**: N/A (no scripts added in range).

### C9 — TOOLKIT.md sync for added scripts

**Status**: N/A in-range (no scripts added in `763b13e`). Standing catalog gap is captured under D9 (19 scripts).

### C10 — (undefined in auditor spec)

**Status**: N/A. Not defined in the auditor definition (jumps C9 → C11).

### C11 — Ambiguous numeric markers in additions

**Status**: ✅ pass

**Evidence**: `git show 763b13e -- '*.md'` additions grepped for `~[0-9]|約[0-9]|およそ[0-9]|だいたい|おおよそ` → all hits are false positives: git-range syntax `HEAD~5..HEAD` (`:79`, `:411`, `:445`, `:478`) and the C11 rule's own pattern/example text (`:234`, `:236`). No real ambiguous quantitative claim.

**Finding**: none.

### C12 — Audit-doc in-place edit

**Status**: ✅ pass

**Evidence**: `git show --name-status 763b13e -- 'docs/audits/**'` → only additions (`docs/audits/…11-58` new file), zero `M` on any existing audit doc. Working-tree `docs/audits/` changes are two brand-new untracked files (`…12-08`, `…15-24`), no modification of existing audit docs. Append-only respected. This report (`…15-43`) is likewise a new file.

**Finding**: none.

---

## Statistics

- Dimensions checked: 22 (D1–D10 + C1–C12; C6/C10 undefined in spec)
- **D-series**: pass 6 (D1, D2, D5, D6, D7, D10) / fail 1 🔴 (D3) / flag 2 🟡 (D8, D9) / UNVERIFIED 1 (D4)
- **C-series (thorough)**: 🔴 1 (C1) / 🟡 1 (C2) / pass 4 (C3, C7, C11, C12) / N/A 6 (C4, C5, C6, C8, C9, C10)
- Critical root causes: **1** (real validator host IP literal, surfaced in both D3 and C1)
- Independent recompute: 2/2 chain_id EXACT match (mainnet `384da888…`, testnet `71ee83bc…`)
- Tests actually invoked (working-tree C2 fix): broadcast-guard 27/27 PASS, safe-broadcast 16/16 PASS

## Auditor note

- **Fabrication**: 0 — every finding carries real `git show` / `git grep` / `gitleaks` / `Read` / `curl` / test-invoke evidence with file:line.
- **Rubber-stamp**: 0 — no pass asserted without evidence; D4 explicitly held as UNVERIFIED rather than passed against a non-existent 10-axis structure.
- **越権 (scope overreach)**: 0 — no schema/script/doc implementation changed; the operator's uncommitted C2 fix was examined (diff + test invoke) but not modified or reverted; this report is the only file written.
- **Mis-observation self-caught**: 1 — an earlier `git ls-files <path>` (exit 0 with empty output) briefly suggested `tests/cycle-gate/fixtures/test-identity-key` was TRACKED; corrected via `git ls-files --error-unmatch` → the fixture is untracked/gitignored/never-committed → D3 out-of-scope (gitleaks history scan clean).
- **UNVERIFIED**: 1 (D4 — 10-axis premise absent from `STRATEGIC_TARGET_ALIGNMENT.md`).
- **Numeric claims**: all measured (`git grep` counts, `wc`, test summaries, `git show --stat`); no "~"/"約" approximations used.
- **Redaction**: all validator host IP literals redacted to `<REDACTED-HOST-IP>`; this report is not itself a leak vector.
- **Append-only**: this is a new file (`constitution-2026-07-03T15-43-audit.md`); no existing audit doc was touched.

> **operator へ**: この report の 各 finding は `superpowers:receiving-code-review` の 手続き に 従い、technical rigor で 独立 verify して ください. performative agreement / blind implementation は 禁止. 最優先 は 🔴 の host IP literal (`.claude/agents/constitution-auditor.md:74,128`) — `763b13e` が **未 push** の 今 が amend/rebase で redact できる window です. auditor は fix を 実装 しません, 判断 は operator に 委ねます. C2-2 residual と D8/D9 は 7/5 T-H の hard blocker では ありません.
