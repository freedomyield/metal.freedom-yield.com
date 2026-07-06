# Constitution Audit — 2026-07-06T10:54 (JST)

## Summary

- **Overall**: 🟡 (🔴 critical = 0)
- **Range**: `HEAD` 全体 / 主軸 `169f58a`, `7828e2e`, `a06861b`. **NB**: 監査開始時 checkout は `main@169f58a`、実行途中で `feat/anchor-static-propagation@580edf0` に移動。全 grep / gitleaks / publish-guard は live tree `580edf0` (= 3 主軸 commit の superset + `580edf0` 1 件) に対して実測。
- **Scope**: all (D1–D10)
- **Review preset**: thorough (C1–C12; C6/C10 は spec 未定義のため N/A)
- **Violations**: D-series 🟡 1 件 (D9) / C-series 🟡 2 件 (C3 informational, C9) / 🔴 = 0。加えて operator 指定 point 1 で de-brand 網羅性の 🟡 gap 1 件 (ANCHOR_SOURCE.md live prose)。
- **Auditor**: constitution-auditor agent

---

## Operator-specified verification points

### Point 1 — de-brand 置換網羅性 (`169f58a`)

**Status**: 🟡 partial gap (secret ではない branding-consistency)

**Method**: `git grep -n '<provider>'` (case-sensitive, 全 tracked) + `git grep '<provider>'` (lowercase orphan) + 各 hit の file 種別分類。

**Evidence**:
- 大文字 `<provider>` 残存 = **30 件**。内訳: `CYCLE_GATE_DAILY_OBSERVATION.md`(7), `ANCHOR_SOURCE.md`(7), `CYCLE_GATE_IMPLEMENTATION_AUDIT.md`(6), `docs/audits/*`(3+3), `CYCLE_GATE_TRD2_AUDIT.md`(2), `STRATEGIC_TARGET_ALIGNMENT.md`(1), `CYCLE_GATE_T55_AUDIT.md`(1)。
- live/forward path (稼働 script + forward doc) の 大文字 <provider> = **0**。3 forward doc (`CYCLE_GATE.md`, `MONITORING_OPS.md`, `VALIDATOR_RENEWAL.md`) + 2 spec doc + 10 script は全て `validator host` に置換済 (§Point 2 参照)。
- 除外判断の妥当性: `docs/audits/*` / `CYCLE_GATE_*_AUDIT.md` / `CYCLE_GATE_DAILY_OBSERVATION.md` / `STRATEGIC_TARGET_ALIGNMENT.md:108`(`T-J-20260701` dated tracking row) の残存は **append-only 規律に照らして妥当** — これらを in-place 書換えれば append-only 違反 (C12) になる。除外は正しい。
- **gap**: `ANCHOR_SOURCE.md` の <provider> 7 件のうち **strike/REVISION 行は L194 の 1 件のみ**。L169 / L180 / L214 / L215 / L216 / L217 は **live prose**（design 説明・code block 例・Note 段落）で strike/REVISION carve-out の外側。operator の除外条件 (「ANCHOR_SOURCE.md の strike/REVISION 履歴」) に該当せず、de-brand sweep が拾い漏らした live 記述。

**Finding**: ANCHOR_SOURCE.md の live prose 6 行に大文字 `<provider>` が残る。ただし `<provider>` は Constitution §3.3 の保護 literal (validator host **IP** / **SSH key 名**) ではない (a06861b Observation-1 で同判定)。よって **secret 露出ではなく branding-consistency の 🟡**。除外判断は audit/dated 系については妥当、ANCHOR_SOURCE live prose のみ carve-out の隙間。

**Suggested fix (指摘のみ)**: ANCHOR_SOURCE.md L169/L180/L214-217 の live prose を `validator host` へ置換する後続 commit を single-purpose で。strike/REVISION 済の L194 は触れない。

### Point 2 — script 機能不変 (`169f58a`)

**Status**: ✅ pass

**Method**: touch した 10 file 全てに `bash -n`; `git show 169f58a -- 'scripts/*' 'tests/*'` の ± 行を目視分類; orphan 名の tracked/disk 実在確認。

**Evidence**:
- `bash -n` : 10/10 file OK (check-anchor-publish-health / gen-anchor-source / install-anchor-watch-alert-only / install-delegator-feed-started-at / install-metal-anchor-publish-health-cron / install-xserver-anchor-source-allowlist / notify-anchor-transition / run-testnet-rehearsal / watch-anchor-events / test-state-init)。
- 全 ± 行は comment (`#`) または echo 文字列。variable / command / regex / 分岐の機能パス変更は **0**。
- orphan 名 `sync-to-<provider>.sh`: `git ls-files` 非追跡・local disk 非存在 = host 側 orphan。`install-repoint-publish-crons.sh:L22/L137` が purge 対象として literal 保持しているのは **正しい**（存在しない real orphan 名を消せなければ意味がない）。

**Finding**: 機能不変。軽微 cosmetic のみ — comment 内に double-"the" 文法傷 2 箇所混入 (`instead of the stranded the validator host ...`, 他 1)。機能無影響。

### Point 3 — publish-guard 通過

**Status**: ✅ pass

**Evidence**: `bash scripts/publish-guard.sh` → **RC=0** (silent success) on live HEAD `580edf0`。`gitleaks detect --no-git --redact` → **no leaks found** (6.41 MB scan)。host IP literal `203.0.113.11` の 2 hit は `push-to-web-host.sh:L78` / `sync-to-validator-host.sh:L33` の **RFC 5737 (TEST-NET-3) documentation 例**で、実 host は `${VALIDATOR_HOST:?}` / `WEB_HOST` env var 経由 = memory rule `no_literal_host_identifier` 準拠。PII / company / handle 残存 0。

### Point 4 — redact 完全性 (`a06861b`)

**Status**: ✅ pass

**Evidence**: `grep -niE '<operator-handle>|<company-name>|...'` → 0 hit。company 名 / operator handle literal は `<operator-handle>` / `<company-name>` placeholder に redact 済。IP literal は `127.0.0.1:1` (loopback, intentional unreachable-RPC) のみ。auditor が自身の method 記述で保護語を書く際も placeholder で表現。

### Point 5 — `~88 lines` fuzzy 除去 (`7828e2e`)

**Status**: ✅ pass

**Evidence**: diff = `-# ... is ~88 lines behind the` → `+# ... has diverged from the`。定量 fuzzy claim 除去、定性表現 (`has diverged`) へ置換。`grep -nE '~[0-9]|約[0-9]|...'` on `install-repoint-publish-crons.sh` → **residual 0**。commit message 内の `"~88 lines"` は削除対象の引用であり新規 fuzzy claim ではない (C11 参照)。

---

## Constitution dimensions (D-series)

### D1 — PRIME DIRECTIVE 4 gate consistency

**Status**: ✅ pass

**Method**: CLAUDE.md / CONSTITUTION.md の gate 文言を grep 相互 diff; `broadcast-guard.sh` enforcement; wrapper `bin/safe-broadcast` (= dimension の `scripts/safe-broadcast.sh` 相当、実配置 `bin/`) の gate 実装確認 + `bash -n`。

**Evidence**:
- `CLAUDE.md:L9`: (1) testnet-first 同一 shape / (2) per-invocation authz `{chain,actor,permission,action,memo,quantity}` / (3) `chain:get` / (4) `--dry-run`・offline-sign。
- `docs/CONSTITUTION.md:L17-20`: 同一 4 gate (identical shape testnet / per-invocation authz 同一 tuple / pre-flight `chain:get` / `--dry-run`・offline-sign)。→ **4 gate 完全一致**。
- `scripts/broadcast-guard.sh:L81-88`: broadcast shape enforcement 実在。`FYD_SAFE_BROADCAST` marker 無しの生 broadcast を無条件 refuse。
- `bin/safe-broadcast:L4-58`: `PRIME_DIRECTIVE: TESTNET-FIRST` marker、default testnet、mainnet opt-in、gate1(`--testnet-tx-id`) / gate3(`chain:get` chain_id fail-closed) / gate4(`--dry-run-log`) 実装。`bash -n` OK。

**Finding**: none。(補足: wrapper は `scripts/` ではなく `bin/safe-broadcast`。dimension の path 前提とは異なるが機能存在。)

### D2 — Broadcast-capable command shape 完全捕捉

**Status**: ✅ pass

**Method**: `broadcast-guard.sh` の pattern 配列抽出 → 期待 list 突合。

**Evidence** (`scripts/broadcast-guard.sh:L81-88`): `proton action` ✓ / `proton transaction(:push)` ✓ / `cleos push[ _](action|transaction)` ✓ (push_transaction / push action / push transaction 網羅) / `(curl|wget) push_transaction` ✓ / `issueTx` ✓ / `eth_sendRawTransaction` ✓。期待 9 shape 全捕捉。

**Finding**: none。

### D3 — Secrets の commit tracked 混入なし

**Status**: ✅ pass

**Method**: `gitleaks detect --no-git --redact` + custom pattern grep (`xoxb-`/`xoxp-`/`sk-proj-`/host IP/handle)。

**Evidence**: gitleaks → **no leaks found**。Slack/OpenAI token 0。IP hit は RFC5737 doc placeholder + `127.0.0.1` loopback のみ (Point 3)。

**Finding**: none。

### D4 — 信用組合期待 10 axis ↔ anchor schema

**Status**: ⚠ partial (violation なし・full row-by-row 未達)

**Method**: `STRATEGIC_TARGET_ALIGNMENT.md` axis 抽出 → `ANCHOR_SOURCE.md` schema field cross-match。

**Evidence**: `ANCHOR_SOURCE.md:L20` `identity_branch (6 required fields)` + observations / artifacts branch 実在 (`L12-13` の pseudonymous identity / observations / artifact-hash 記述に構造対応)。ただし STRATEGIC_TARGET_ALIGNMENT.md は番号付 10-axis table ではなく prose 構成のため、10↔field の 1:1 coverage table は本 pass で機械抽出不能。

**Finding**: coverage 欠落は未検出だが row-by-row 検証は **UNVERIFIED (mechanical extraction 不能)**。fabrication 回避のため partial 分離。

### D5 — Schema version consistency

**Status**: ✅ pass

**Evidence**: `git grep -hoE '"schemaVersion":...' -- '*.json' '*.jsonl'` → `"schemaVersion": 1` × 2、他値 0。**1 種のみ**。

**Finding**: none。

### D6 — Doc heading h1→h2→h3 nesting

**Status**: ✅ pass

**Method**: awk で code-block 除外の上、level jump > 1 を全 `docs/**/*.md` で検出。

**Evidence**: skip 検出 **0 件**。

**Finding**: none。

### D7 — Inline `style="..."` 禁止

**Status**: ✅ pass

**Method**: `git grep -nE 'style="' -- '*.html' '*.md'`。

**Evidence**: 3 hit は全て rule 本文 (`CLAUDE.md:L35`) / method 記述 (audit doc 2 件)。実 attribute **0**。

**Finding**: none。

### D8 — Commit single-purpose

**Status**: ✅ pass (note 付)

**Evidence**:
- `169f58a`: 5 系統 dir (docs / superpowers/plans / superpowers/specs / scripts / tests) に跨るが **単一 semantic theme = 機械的 de-brand sweep**。単一目的。
- `7828e2e`: 1 file。✓
- `a06861b`: `docs/audits` 1 file。✓
- `580edf0`: subject に `+` (`exclusion list + emitter`) だが単一 feature (single-source feed exclusion)。

**Finding**: none (mechanical sweep の多 dir は単一目的の正当形)。

### D9 — TOOLKIT.md ↔ scripts/ 同期

**Status**: 🟡

**Method**: `git ls-files 'scripts/*.sh'` (49 件) basename を `TOOLKIT.md` に grep。

**Evidence**: TOOLKIT 未記載 = 4 件 — `build-rsync-excludes.sh` (**`580edf0` で session-new**), `gen-identity.sh` (既存), `test-gen-identity.sh` (既存 test), `test-phase6-memo-mock.abandoned.sh` (abandoned)。

**Finding**: 🟡。うち `build-rsync-excludes.sh` は本 session 追加分で C9 と重複。他 3 は pre-existing (本 session 由来ではない)。

**Suggested fix (指摘のみ)**: `build-rsync-excludes.sh` を TOOLKIT.md に追記 (single-purpose commit)。既存 3 件は operator 判断 (test/abandoned は TOOLKIT 対象外という運用なら除外明記)。

### D10 — OPERATING_MODEL W1-W10 ↔ scripts 実在

**Status**: ✅ pass

**Evidence**: `OPERATING_MODEL.md` は W-section 10 個を持つが具体 script 名を列挙せず (`L42` で `scripts/` を総称参照のみ)。dangling script 参照 **0**。

**Finding**: none (検証対象 script 名の参照なし = 不整合発生余地なし)。

---

## Simplified review (C-series, thorough)

### C1 — Secret / literal の混入追加

**Status**: ✅ pass。`git diff 5ecf4b8..HEAD` 追加行の secret pattern grep → 唯一 hit は `a06861b` audit doc 内の PII-grep method 記述 (実 secret ではない)。

### C2 — Broadcast-capable command 生追加

**Status**: ✅ pass。追加行の broadcast shape hit 3 件は全て `a06861b` audit doc の guard-regex 説明 prose。生の broadcast 呼び出し **0**。

### C3 — Heredoc / one-liner の手動 operator 指示

**Status**: 🟡 informational。`docs/superpowers/plans/2026-07-06-...convergence.md:L214` に `rm -rf "${XS}"`。ただし変数 scoped (`${XS}` = staging dir、cleanup trap 併用) の **design plan 例**であり、sudo 付 operator paste 1-liner ではない。installer-first rule (operator 手動実行) の対象外。低 severity。

**Suggested fix (指摘のみ)**: plan doc の例なら現状可。将来 operator 実行に昇格する際は `scripts/install-*.sh` 化。

### C4 — 追加 script の shebang + `set -euo pipefail`

**Status**: ✅ pass。新規 2 script 双方で確認 — `build-rsync-excludes.sh` (`#!/usr/bin/env bash` + `set -euo pipefail:L7`), `install-repoint-publish-crons.sh` (shebang + `set -euo pipefail:L30`)。

### C5 — JSON schema additive/breaking

**Status**: N/A。range 内で `*.schema.json` / `schema*.json` の変更 **0**。

### C6 — (spec 未定義)

**Status**: N/A (dimension 未定義)。

### C7 — File mode

**Status**: ✅ pass。range 追加 8 file の mode 実測 — `.txt`/`docs/*.md` = `100644` ✓、`scripts/*.sh`/`tests/*.sh` = `100755` ✓。secret 疑い file の tracked 化 0。

### C8 — 追加 script に対応 test

**Status**: ✅ pass。`build-rsync-excludes.sh` → `tests/deploy/test-build-rsync-excludes.sh` (**7 PASS / 0 FAIL** 実行確認)。`install-repoint-publish-crons.sh` → `tests/install-repoint-publish-crons/test-...sh` 実在。

### C9 — TOOLKIT.md 同期 (追加 script)

**Status**: 🟡。`build-rsync-excludes.sh` (580edf0 追加) が TOOLKIT.md 未記載 (`grep -c` = 0)。`install-repoint-publish-crons.sh` は記載済 (D9 で未 flag)。

**Suggested fix (指摘のみ)**: `build-rsync-excludes.sh` を TOOLKIT.md に追記。

### C11 — Numeric claim の曖昧 marker

**Status**: ✅ pass。range 追加行 / 直近 6 commit message の fuzzy marker hit は `7828e2e` message の `"~88 lines"` 1 件のみ、かつこれは **除去対象の引用** (de-fuzzing) であり新規 fuzzy claim ではない。

### C12 — Audit doc の in-place edit

**Status**: ✅ pass。`git diff --name-status 5ecf4b8..HEAD -- docs/audits/**` → 変更は全て `A` (addition)。既存 audit doc の in-place 書換え **0**。本 report も新規 file (append-only 遵守)。

---

## Statistics

- Dimensions checked: 22 (D1–D10 + C1–C5,C7–C9,C11,C12; C6/C10 undefined)
- Passed: 17 ✅ (D1,D2,D3,D5,D6,D7,D8,D10 / C1,C2,C4,C7,C8,C11,C12) + partial D4
- 🟡 flagged: 3 (D9 / C3 / C9) + operator-point-1 de-brand gap (ANCHOR_SOURCE live prose)
- 🔴 critical: **0**
- N/A / partial: C5, C6, C10 (N/A) + D4 (partial-UNVERIFIED)

## Auditor note

- Fabrication: 0 件 (全 finding は git show / grep / gitleaks / bash -n / 実行 RC の実測 evidence 付き)。
- 越権実装: 0 件 (read-only、指摘のみ、fix 未実施)。
- Numeric claim: 全実測 (30 / 10 / 49 / 4 / 7 PASS 等は grep/wc/実行 capture)。「~」「約」不使用。
- Append-only: 本 report は新規 file、既存 audit doc 未 touch。
- 特記: 監査途中で checkout が `main@169f58a` → `feat/anchor-static-propagation@580edf0` に移動。全 live 実測は `580edf0` (3 主軸 commit の superset) に対して実施。3 主軸 commit は全て `580edf0` の ancestor。

> **operator へ**: 各 finding は `superpowers:receiving-code-review` の手続きに従い technical rigor で独立 verify してください。performative agreement / blind implementation は禁止。🟡 事項 (D9/C9 の TOOLKIT 追記、C3 の plan 例、Point 1 の ANCHOR_SOURCE live prose de-brand) は operator 判断事項です。D4 は mechanical 抽出不能のため UNVERIFIED 分離済 — 疑義あれば `--scope` 指定での再監査を。
