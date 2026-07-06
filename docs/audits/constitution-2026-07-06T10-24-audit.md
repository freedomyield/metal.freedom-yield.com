# Constitution Audit — 2026-07-06T10:24 (JST)

## Summary

- **Overall**: 🟡 (0 × 🔴 critical / 1 × 🟡 borderline)
- **Range**: `5ecf4b8..HEAD` (`c4c86ab`, 8 commits)
- **Scope**: `all` (D1–D10)
- **Review preset**: `thorough` (C1–C5, C7–C9, C11–C12 — C6/C10 undefined in agent spec)
- **Violations**: D-series 0 🔴 / 1 🟡 (D8 single-purpose, requires-judgment) — C-series 0
- **Auditor**: constitution-auditor agent (read-only; no fix implemented)

**D1/D2/C2 broadcast (special highlight)**: 🟢 CLEAN. No raw broadcast-capable shape
(`proton action|transaction`, `cleos push*`, RPC `push_transaction`/`issueTx`/`eth_sendRawTransaction`)
is added anywhere in the range. The new `sign-anchor-event.sh` pre-flight (exit 7) sits
*before* and does not bypass the `bin/safe-broadcast` delegation; `cycle-gate.sh` ungate
leaves `broadcast` signature-gated. No operator-per-invocation gate weakened.

---

## Constitution dimensions (D-series)

### D1 — PRIME DIRECTIVE 4-gate consistency

**Status**: ✅ pass

**Method**: grep the 4 gates in CLAUDE.md, docs/CONSTITUTION.md, scripts/broadcast-guard.sh,
bin/safe-broadcast; confirm range changes do not desync.

**Evidence**:
- `CLAUDE.md:L9`: four gates verbatim — (1) testnet-first, (2) per-invocation authz naming `{chain,actor,permission,action,memo,quantity}`, (3) pre-flight `chain:get`, (4) exhausted `--dry-run`/offline-sign.
- `docs/CONSTITUTION.md:L18-20,26`: same 4 gates + "any script/tool/doc introducing a broadcast pathway MUST embed `# PRIME_DIRECTIVE: TESTNET-FIRST` in first ten lines, default testnet."
- `scripts/broadcast-guard.sh:L118-138`: gates named; refers raw broadcasts to `bin/safe-broadcast`.
- `scripts/sign-anchor-event.sh:L32`: "§3.4 PRIME DIRECTIVE: broadcast goes through bin/safe-broadcast."

**Finding**: none. Range touches no gate text; new guards are strictly additive fail-early checks.

### D2 — Broadcast-capable command shape capture

**Status**: ✅ pass

**Method**: extract `BROADCAST_PATTERNS` array from broadcast-guard.sh; cross-match expected list.

**Evidence** — `scripts/broadcast-guard.sh:L80-89`:
`proton[[:space:]]+action`, `proton[[:space:]]+transaction([[:space:]]|:push)`,
`cleos ... push[[:space:]_]+(action|transaction)`, `(curl|wget) ... push_transaction`,
`... issueTx`, `... eth_sendRawTransaction`, `... /ext/bc/[XPC]`.

**Finding**: all expected shapes present; range adds no new chain/broadcast shape requiring coverage.

### D3 — Secrets / literals not in tracked files

**Status**: ✅ pass

**Method**: `gitleaks detect --no-git --config .gitleaks.toml` (8.30.1) + custom PII grep on added lines.

**Evidence**:
- gitleaks: `no leaks found` (scanned 6.35 MB).
- Added-line PII grep (IP/xoxb/xoxp/sk-proj/PRIVATE KEY/mnemonic/passphrase/&lt;operator-handle&gt;/&lt;company-name&gt;): 0 hits. Only IP-like token is `127.0.0.1:1` (`tests`/installer intentional unreachable-RPC loopback — not a host identifier).
- gitleaks allowlist add (`9846eb9`) is scoped to `tests/cycle-gate/fixtures/test-identity-key(\.pub)?` — a single git-untracked, `.gitignore`'d, test-time-regenerated ed25519 keypair. NOT over-broad: it is a path allowlist for one fixture, not a rule/regex disablement, so it cannot mask a real committed key elsewhere. Verified the key is also `.gitignore`'d (double lock).

**Finding**: none. See Observation-1 (informational) re. the provider word "Hetzner".

### D4 — Strategic-target axes ↔ anchor schema coverage

**Status**: ✅ pass (not impacted by range)

**Method**: inspect docs/STRATEGIC_TARGET_ALIGNMENT.md structure vs docs/ANCHOR_SOURCE.md.

**Evidence**: neither file is in `5ecf4b8..HEAD` (`git diff --name-status`). Current doc organizes the strategic surface under `## What anchor design should target` (L73) rather than a literal enumerated "10-axis" table.

**Finding**: no range impact. Pre-existing note (not a range finding): the agent-spec's "10 axis" literal framing is not present as a discrete enumeration in the current doc — out of scope here, flagged only for a future targeted `--scope` pass.

### D5 — schemaVersion consistency

**Status**: ✅ pass

**Method**: `grep -rhoE '"schemaVersion": *"?[0-9]+"?' --include=*.json --include=*.jsonl`.

**Evidence**: 2 occurrences, both `"schemaVersion": 1`. Single value.

**Finding**: none.

### D6 — Heading nesting h1→h2→h3

**Status**: ✅ pass

**Method**: extract heading levels from the two changed/added docs.

**Evidence**:
- spec `2026-07-06-anchor-static-propagation-convergence-design.md`: `# `(L1) → `## 1..10` → `### 3.1/3.2`. No skip.
- `docs/IDENTITY_SCHEMA_CHANGELOG.md`: `# `(L1) → `## <date>` → `### Summary/Why/…`. No skip.

**Finding**: none.

### D7 — Inline `style="..."` prohibition

**Status**: ✅ pass

**Method**: `git diff 5ecf4b8..HEAD | grep '^+' | grep -E 'style="'`.

**Evidence**: 0 hits on added lines.

**Finding**: none.

### D8 — Commit single-purpose

**Status**: ⚠ partial (1 × 🟡 requires-judgment)

**Method**: `git log --format=%s%n%b`; flag "+"/"and"/"," dual-subject + ≥2 distinct file systems.

**Evidence**:
- `42797ae` cycle-gate.sh + its test — single (ungate). ✅
- `155fb24` 5 scripts, all repointing one dead ref — single. ✅
- `9846eb9` .gitignore + .gitleaks.toml, both allowlisting the same fixture — single. ✅
- `d55ab04` TOOLKIT only — single. ✅
- `79ed3be` schema/example/gen/test/changelog, all one retirement (#1) — single theme. ✅
- `ddd0805` installer + its test + TOOLKIT row — single (new installer). ✅
- **`5e73afe`** subject: "ordering guard in gen-identity **+** signing-host assertion in signer" — two independent guards in two independent scripts (`scripts/operator-local/gen-identity.sh` ordering guard; `scripts/sign-anchor-event.sh` proton pre-flight). Joined by "+". 🟡
- `c4c86ab` spec only — single. ✅

**Finding**: `5e73afe` bundles two logically-distinct machine-checked preconditions. It is thematically unified as design-stocktake #6 ("two preconditions cycle-3 relied on operator vigilance for"), and the commit body clearly delimits (A)/(B) — cohesion is defensible. Flagged per D8's dual-subject rule for the record; lean **acceptable**, operator judgment.

**Suggested fix (指摘のみ, agent 実装せず)**: for strict single-purpose, future work of this shape could split into two commits (one per guard/script). Not required retroactively.

### D9 — TOOLKIT.md ↔ scripts/ sync

**Status**: ✅ pass (bidirectional)

**Method**: for each `scripts/*.sh` grep TOOLKIT; reverse: each `.sh` token in TOOLKIT vs filesystem.

**Evidence**:
- Forward: 0 scripts missing from TOOLKIT. New `install-repoint-publish-crons.sh` catalogued at `TOOLKIT.md:L166`; `sign-anchor-event.sh` at L138.
- Reverse "missing" hits (`ntfy.sh`, `push-to-xserver.sh`) are **false positives**: `ntfy.sh` is the notification *service* domain (`https://ntfy.sh`, `TOOLKIT.md:L90-95,210`), not a script; `push-to-xserver.sh` at L166 is an explicit reference to the *retired* script name in the repoint-installer description, not a claim it exists.

**Finding**: none.

### D10 — OPERATING_MODEL W1–W10 script existence

**Status**: ✅ pass

**Method**: extract `scripts/*.{sh,py}` refs from docs/OPERATING_MODEL.md; confirm each file exists.

**Evidence**: 0 missing (empty diff of referenced-vs-existing).

**Finding**: none.

---

## Simplified review (C-series, thorough)

### C1 — Secret/literal in additions

**Status**: ✅ pass

**Method**: D3 PII pattern + base64-32B grep on added lines. **Evidence**: 0 real secrets; gitleaks clean. Spec (`c4c86ab`) sanitizes the Xserver account as `/home/<acct>/…` and the deploy user as generic `deploy` — no host IP, no project SSH key name, no PII. `<acct>` sanitize is effective (no real account literal in the file). **Finding**: none (see Observation-1).

### C2 — Raw broadcast-capable command added

**Status**: ✅ pass

**Method**: grep all added lines for broadcast shapes; verify sign-anchor routing.
**Evidence**: `git diff 5ecf4b8..HEAD | grep '^+'` → 0 broadcast shapes. `sign-anchor-event.sh:L312` (new proton pre-flight, `command -v proton`, exit 7) precedes `L327` "delegate to bin/safe-broadcast" (`L335 bash "$SAFE_BROADCAST"`). The pre-flight does NOT invoke proton and does NOT bypass the tier-2 gate; it only fails early on a keyless host. **Finding**: none.

### C3 — Installer-first (no heredoc/1-liner operator manual)

**Status**: ✅ pass

**Method**: inspect `install-repoint-publish-crons.sh` for operator-1-command completeness.
**Evidence**: `#!/usr/bin/env bash` + `set -euo pipefail`; usage `sudo bash scripts/install-repoint-publish-crons.sh [--dry-run] [--purge-orphans]`; idempotent, backs up, `BROADCASTS NOTHING`. No `sudo`/`rm -rf`/`chown -R`/heredoc paste-block delegated to the operator's shell (the only `sudo` occurrence is the script's own documented invocation line). This is exactly the installer-first shape the memory rule prescribes. **Finding**: none.

### C4 — Added script shebang + `set -euo pipefail`

**Status**: ✅ pass

**Method**: head-of-file inspection of the one NEW script.
**Evidence**: `install-repoint-publish-crons.sh:L1` `#!/usr/bin/env bash`, `L30` `set -euo pipefail`. (`gen-identity.sh`/`sign-anchor-event.sh` are pre-existing files modified, not new.) **Finding**: none.

### C5 — JSON schema change additive vs breaking

**Status**: ✅ pass (additive / non-breaking)

**Method**: diff `identity.schema.v1.json`; check `required` array + `additionalProperties`.
**Evidence** (`79ed3be`): `dag_root_hash` is **kept** in `properties` as optional (description → RETIRED), NOT removed, NOT added to `required`, no type change; top-level `required` does not contain it; `additionalProperties: true`. Old snapshots carrying the field still validate; new snapshots omitting it also validate. `identity.example.json` field removal is example-only (not a compat surface). **Finding**: none — clean backward-compatible collapse.

### C7 — File mode

**Status**: ✅ pass

**Method**: `git ls-files -s` on changed files.
**Evidence**: `scripts/*.sh` = `100755` (install-repoint, cycle-gate, gen-identity, sign-anchor); test `*.sh` = `100755`; `*.schema.v1.json` = `100644`; spec `.md` = `100644`. No `.key`/`.pem`/`.env` tracked. **Finding**: none.

### C8 — Added script has test

**Status**: ✅ pass

**Method**: match new script to a test file.
**Evidence**: `install-repoint-publish-crons.sh` ↔ `tests/install-repoint-publish-crons/test-install-repoint-publish-crons.sh` (added in same commit `ddd0805`, `#!/usr/bin/env bash`). **Finding**: none.

### C9 — TOOLKIT.md sync for added script

**Status**: ✅ pass

**Evidence**: `install-repoint-publish-crons.sh` added to `TOOLKIT.md:L166` in the same commit; `d55ab04` additionally catalogued 25 prior scripts (Tier 4). **Finding**: none.

### C11 — Numeric-claim ambiguity markers

**Status**: ✅ pass

**Method**: grep `~[0-9]`/`約[0-9]`/`およそ`/`だいたい`/`おおよそ` in commit messages + spec.
**Evidence**: 0 hits in commit messages; 0 hits in the spec. (Commit bodies use exact figures: "22/22", "23/23", "29/29", "~88 lines behind" — note the spec/commit `~88 lines` appears in `install-repoint` header comment as a code comment, not a numeric *claim* line; see below.) **Finding**: none in scope. Minor note: `install-repoint-publish-crons.sh:L11` comment says "~88 lines behind" — this is a source-code comment (not a commit-message/audit numeric claim), outside C11's target surface; recorded for transparency.

### C12 — Audit-doc in-place edit

**Status**: ✅ pass

**Method**: `git diff --name-status` for `docs/audits/**`.
**Evidence**: no existing audit file modified in range. This report is a NEW file (`constitution-2026-07-06T10-24-audit.md`); append-only preserved. **Finding**: none.

---

## Observations (informational — not scored findings)

- **Observation-1 (provider name "Hetzner")**: the word "Hetzner" appears in the new `install-repoint-publish-crons.sh` (orphan reference `sync-to-hetzner.sh`, L22/L137). It is **pre-existing and widespread** in tracked scripts at the base `5ecf4b8` (check-anchor-publish-health.sh, gen-anchor-source.sh, install-*.sh, etc.), so it is not a net-new exposure and is not classified SECRET/CONFIDENTIAL under Constitution §3.3 (the protected literals are the validator host **IP** and **SSH key names** — neither present). Recorded only because it is mildly inconsistent with the de-branding intent of `155fb24` (`push-to-xserver.sh` → `push-to-web-host.sh`), where a retired orphan still carries the provider name. No action required for compliance.

- **Spec §1 remote-host claims (UNVERIFIED by this auditor)**: §1's empirical assertions about the Xserver (frozen mtime 2026-07-02, no `.git`, no metal cron, no site-root deploy script) rest on "a single authorized read-only root inspection on 2026-07-06." This auditor has **no SSH path to the Xserver in scope** and cannot independently re-verify those remote facts — they are separated here as **UNVERIFIED (out of auditor reach)**, not confirmed and not disputed. What IS repo-verifiable was checked and holds: `.github/workflows/deploy.yml` rsyncs to a single `$SSH_HOST`/`$DEPLOY_PATH` (L120,L134,L168); `docs/DEPLOY_OWNERSHIP_MATRIX.md:L11` does assert git deploy is the "canonical source for repo-tracked content"; `scripts/push-to-web-host.sh` exists. The §9 "⑫ decoupled from ⑤" correction is logically sound: approach C only re-syncs git-tracked static via a second rsync, while ⑫ concerns the dynamic-push (receive-wrapper allowlist) path — orthogonal channels, so C neither blocks nor unblocks ⑫.

- **Design integrity — identity.json dag_root_hash retirement (`79ed3be`)**: internally consistent across surfaces — schema (field retained optional, additionalProperties:true → live signed file stays valid until regen), example (field removed), gen-identity (jq object + console line dropped, 2-branch value redirected to cycles-history.json), test (asserts ABSENT), changelog (2026-07-06 entry). The circular-hash-dependency trap is correctly avoided by *removal* rather than a self-referential pointer. The one-time next-`dag_root_computed` shift is disclosed in the commit body and is self-consistent.

- **cycle-gate ungate (`42797ae`) does not weaken broadcast gate**: only `observe` and `cycle-artifact-write` short-circuit to green; `broadcast` (IRREV) remains signature-gated (`cycle-aware-notify` explicitly left gated pending a separate decision). Confirmed at `scripts/cycle-gate.sh` side-effect matrix + the `case observe|cycle-artifact-write` short-circuit.

---

## Statistics

- Dimensions checked: 20 (D1–D10 + C1–C5,C7–C9,C11–C12)
- Passed: 19 (D: 9 full + D4 n/a-range; C: 10)
- Flagged 🟡: 1 (D8 `5e73afe` dual-subject, requires-judgment; lean acceptable)
- Failed 🔴: 0
- N/A (out of scope / out of reach): D4 (range untouched); spec §1 remote-host facts (no SSH reach — separated as UNVERIFIED)

## Auditor note

- Fabrication: 0 — every finding cites real gitleaks/git/grep/Read output.
- 越権実装: 0 — no schema/script/doc/spec modified; findings recorded only.
- Numeric claims: all measured (gitleaks 6.35 MB, schemaVersion count = 2×"1", modes via `git ls-files -s`); no "~"/"約" markers used by the auditor.
- Append-only: this is a NEW file; no existing `docs/audits/**` touched.

> **operator へ**: 各 finding は `superpowers:receiving-code-review` の手続きで独立 verify してください。performative agreement / blind implementation は禁止。D8 の 🟡 (5e73afe) と Observation-1 (Hetzner 語) は operator 判断事項です。spec §1 の Xserver 実測は auditor 到達外のため UNVERIFIED 分離済 — 疑義あれば当該 host での再確認、または `--review=thorough --scope=` 再監査を。
