# Constitution Audit — 2026-07-06T11:45 (JST)

## Summary

- **Overall**: 🟢 GREEN — **Constitution 🔴 = 0**. One 🟡 operator-ratification item (documented append-only override in `4992356`); one 🟡 pre-existing/out-of-range TOOLKIT omission (informational).
- **Range**: `169f58a..7d9f9c4` (7 commits since prior audit)
- **Scope**: all (D1–D10)
- **Review preset**: `thorough` (C1–C12 全)
- **Violations**: D-series 🔴 0 / 🟡 1 (append-only override, operator judgment) — C-series 🔴 0 / 🟡 0
- **HEAD**: `7d9f9c47ead91116d76b6de62d99768fcf2f93fc`
- **Auditor**: constitution-auditor agent (read-only; findings only, no fix implemented)

This audit re-verifies the prior-audit (`constitution-2026-07-06T10-54-audit.md`) findings against the fixes in `169f58a..7d9f9c4`, plus a full thorough sweep.

---

## Priority verification (前回指摘への対応)

### ① Append-only 規律との整合 — `4992356` (最重要・矛盾解決)

**Status**: 🟡 documented operator-directed override (両解釈提示、operator ratification 事項)

**Method**: `git show 4992356 --stat` + per-file `git show 4992356 -- <append-only docs>`; current-state `grep -n` on `ANCHOR_SOURCE.md`.

**実測 — 何がどう書き換わったか (in-place, no strike/REVISION)**:

`4992356` は "<provider>" → "the validator host" / "validator host" / `<provider>` の **in-place 直接置換**を、以下の append-only 記録に対して strike+REVISION 手順**なし**で適用:

| file | 置換箇所 | 種別 |
|---|---|---|
| `docs/ANCHOR_SOURCE.md` | L166 (live prose), L177/L180 (reproducer prose), **L194 (既存 `~~strike~~ **REVISION** ` block の内部)**, L214-217 (Note block) | mixed — うち **L194 は確定済 REVISION 内容の in-place 書換** |
| `docs/CYCLE_GATE_DAILY_OBSERVATION.md` | snapshot #1/#2/#3 の L1 label 群 (append-only observation log) | append-only record |
| `docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md` | Production banner, task table, deploy 手順 | audit record |
| `docs/CYCLE_GATE_T55_AUDIT.md` / `docs/CYCLE_GATE_TRD2_AUDIT.md` | blast-radius table cells, state map heading | audit record |
| `docs/audits/constitution-2026-07-04-design-stocktake.md` | Summary + defect table cells | **audit report** |
| `docs/audits/constitution-2026-07-06T10-24-audit.md` | D3 Finding + Observation-1 + operator note → `<provider>` placeholder | **audit report** |
| `docs/STRATEGIC_TARGET_ALIGNMENT.md` | T-J-20260701 row | dated row |

**Evidence (crux — finalized REVISION content edited in-place)**:
- `ANCHOR_SOURCE.md:L194` (現状): `` ...b10fac6... ~~(the validator host git head; local main was at a1476a2, sync gap unrelated to T-B)~~ **REVISION 2026-07-01T04:07Z**: ... the validator host is diverged (not behind)... `` — 打消線内テキストと REVISION 本文の両方で語が置換されている。= 確定済 append-only revision 内容の silent rewrite。

**判定 — 両解釈**:

- **解釈 A (機械的 C12 違反)**: memory rule `audit_log_append_only_and_label_scoping` は audit doc の cell 内 in-place edit を禁止し、修正は `~~strike~~` + REVISION line のみ許可。`4992356` は 2 本の実 audit report + 確定済 REVISION block を含む append-only 記録を strike なしで直接書換えた → 機械的読みでは **C12/D-append-only 違反**。
- **解釈 B (forbidden-word override が carve-out を正当に上書き)**: commit message が明示的に "Forbidden-word sanitization overrides the audit-log append-only rule" と宣言し、operator directive として "<provider>" を handle/company と同格の must-not-publish 語に昇格。**技術的に決定的な点**: forbidden literal を `~~<provider>~~` で strike 保存すると tracked content に語が残存し purge の目的を破壊 (publish-guard も trip する)。つまり append-only の strike-preservation と forbidden-literal purge は**物理的に共存不能**であり、この class では override は許容ではなく強制される。加えて (a) 記録の意味は "validator host" 汎用語で忠実に保存、(b) audit report は `<provider>` placeholder で meta-記述の意味を保持、(c) 先行事例 (2026-07-03 の handle/company redaction, memory `project_audit_report_20260703_pm_claude_tooling_leak`) と同一 pattern。

**Finding**: 🟡 — 機械的には append-only carve-out に抵触するが、forbidden-literal purge という上位 security 判断が override を正当化 (かつ strike 保存不能ゆえ他に手段がない)。先行 redaction 事例により pattern は既に前例化しており、🔴 には該当しない。**operator 判断ポイント**: この "forbidden-word purge が append-only を override する" doctrine を明示的に ratify するか (commit message での宣言で足りるとするか、Constitution/memory 側に carve-out 条項として成文化するか)。成文化されれば以降 🟢。

**Suggested fix (指摘のみ)**: memory `feedback_audit_log_append_only_and_label_scoping` に「forbidden-literal (secret/handle/company/provider) の purge は append-only を override してよい (strike 保存が語を残すため)。ただし置換は意味保存 + commit message で override を明示」の carve-out を 1 文追記。auditor は実装しない。

**ANCHOR_SOURCE.md L169/L180/L214-217 live prose 残存の解消**: ✅ 解消。`git grep -i <provider> -- .` = **0 hits** (実測、後述 ②)。

### ② publish-guard 回帰

**Status**: ✅ pass

**Evidence**:
- `printf '<provider>' | shasum -a 256` = `294aa8d75483b8331e3ba6a7f24aea15202747f36de65197e7bc6194880b2558` — `scripts/publish-guard.sh:47` の新規 WORD_HASHES 末尾要素と**完全一致**。
- `git grep -i <provider> -- .` (tracked) = **0 hits**。case 変種 `<provider>`/`<provider>`/`<provider>`/`<provider>` すべて 0。
- 機能 test: `printf 'we deploy to <provider> cloud' | bash scripts/publish-guard.sh --text` → **RC=1** (block); `sync-to-<provider>.sh` → **RC=1**; `the validator host` → **RC=0** (allow)。
- 全 tracked content scan: `git ls-files -z | xargs -0 cat | publish-guard.sh --text` → **RC=0**。range diff `publish-guard.sh --diff` → **RC=0**。
- `gitleaks detect --no-git` → **no leaks found** (scanned 6.43 MB, RC=0)。

**Finding**: none.

### ③ 新規 deploy script 群 C4/C7/C8/C9

**Status**: ✅ pass

新規 script (`git diff --diff-filter=A`):
- `scripts/deploy/build-rsync-excludes.sh` — mode **755**、shebang `#!/usr/bin/env bash`、`set -euo pipefail` (L7)、`bash -n` clean。test `tests/deploy/test-build-rsync-excludes.sh` = **7 PASS / 0 FAIL**。TOOLKIT.md L170 記載 ✅。
- `scripts/install-xserver-static-deploy-key.sh` — mode **755**、shebang、`set -euo pipefail` (L17 + remote heredoc L63)、`bash -n` clean。test `tests/install-xserver-static-deploy-key/test-install-xserver-static-deploy-key.sh` = **5 PASS / 0 FAIL**。TOOLKIT.md L171 記載 ✅。

前回 🟡 だった `build-rsync-excludes.sh` の **TOOLKIT 追記は解消** (L170、`458ea18` 差分で確認)。付随 test 全 PASS: build-rsync-excludes 7/7、rsync-delete-protection 18/18、install-xserver-static-deploy-key 5/5、install-repoint-publish-crons 8/8。`deploy/feed-excludes.txt` = mode 644 (data、正)。

**Finding**: none.

### ④ redact 維持 (audit report commit `1533b87`)

**Status**: ✅ pass

**Evidence**:
- `1533b87` (T10-54 report) は追加のみ、以降 in-place 編集なし (`git log --diff-filter=A` = 同一 commit)。
- 全 tracked content の `publish-guard.sh --text` scan = RC=0 → 禁止 handle/company/IP/phone/email/CJK literal は全 tracked file で **0**。T10-54 + T10-24 audit report 単独 scan も RC=0。
- range diff scan (`--diff`) RC=0 → 追加行に禁止 literal 混入 0。

**Finding**: none.

---

## Constitution dimensions (D-series)

### D1 — PRIME DIRECTIVE 4 gate consistency
**Status**: ✅ pass
**Method**: range で `CLAUDE.md`/`docs/CONSTITUTION.md`/`broadcast-guard.sh`/`safe-broadcast.sh` の touch 有無確認 + gate keyword grep。
**Evidence**: `git diff --name-only 169f58a..7d9f9c4 --` 上記 4 file = **空 (untouched)**。`CLAUDE.md:9` に 4 gate (testnet-first / per-invocation authz / `chain:get` / `--dry-run` exhausted) 列挙、`docs/CONSTITUTION.md:11-26,95-98` と一致。
**Finding**: none (range 内で PRIME DIRECTIVE 経路の変更なし)。

### D2 — Broadcast-capable command shape 捕捉
**Status**: ✅ pass
**Evidence**: `broadcast-guard.sh:81-88` regex — `proton action`, `proton transaction([[:space:]]|:push)`, `cleos .*push[[:space:]_]+(action|transaction)`, `(curl|wget).*push_transaction|issueTx|eth_sendRawTransaction` 全期待 shape を含む。range で未変更。
**Finding**: none。

### D3 — Secrets の commit tracked 混入
**Status**: ✅ pass
**Evidence**: gitleaks no-git = no leaks (6.43 MB, RC=0)。publish-guard 全 tracked scan RC=0。新規 `install-xserver-static-deploy-key.sh` は `CI_PUBKEY` を**実行時 path 経由で読む** (`tr -d '\r\n' < "${CI_PUBKEY}"`)、鍵 literal を commit せず、`<ip>`/`<acct>` placeholder 使用、公開鍵のみ扱い ("BROADCASTS NOTHING")。`deploy.yml` の Xserver 鍵は `${{ secrets.XSERVER_SSH_KEY }}` (commit 非含有) を `~/.ssh/id_xserver` chmod 600 へ、unset 時 graceful skip。
**Finding**: none。two-host deploy feature は §5 infra separation を遵守 (rrsync -wo で metal public dir に confine、他 project vhost 非干渉)。

### D4 — Strategic-target 10 axis ↔ anchor schema
**Status**: ✅ pass (range で構造未変更)
**Evidence**: `STRATEGIC_TARGET_ALIGNMENT.md` の range 変更は T-J-20260701 row の 1 語置換のみ (axis 構造・schema 対応に非干渉)。表構造 intact。
**Finding**: none。

### D5 — Schema version consistency
**Status**: ✅ pass
**Evidence**: `grep -rhoE '"schemaVersion"...' --include='*.json' --include='*.jsonl'` → **`"schemaVersion": 1` のみ (2 occurrences)**、他値なし。
**Finding**: none。

### D6 — Doc heading h1→h2→h3 nesting
**Status**: ✅ pass
**Method**: fence-aware Python parser (```` ``` ````/`~~~` code block を除外)。
**Evidence**: fence-aware scan = **real skips 0**。(naive scan の 30 hit は全て ```sh block 内の `# comment` 行を h1 と誤認した false positive、fence 除外で消滅。) 新規/変更 doc (`DEPLOY_SETUP.md`, `DEPLOY_OWNERSHIP_MATRIX.md`) も 1→2→3 順守。
**Finding**: none。

### D7 — Inline `style="..."` 禁止
**Status**: ✅ pass
**Evidence**: `grep -rnE 'style="' --include='*.html' --include='*.md'` = 8 hit、**全て rule 自体の言及** (`CLAUDE.md:35` convention 行 + audit report の D7 method 記述)。実 inline style 属性 **0**。
**Finding**: none。

### D8 — Commit single-purpose
**Status**: ✅ pass
**Evidence**: range 7 commit の subject + touched top-dir:
- `580edf0` feat(deploy) single-source exclusion list — deploy/scripts/tests (1 feature)
- `ce09ce0` test(deploy) — tests のみ
- `7c96709` feat(deploy) second rsync target — .github のみ
- `458ea18` feat(deploy) deploy-key installer — scripts/tests/TOOLKIT (1 feature + doc)
- `c716778` docs(deploy) two-host doc — docs のみ
- `4992356` security(publish-guard) <provider> purge — docs/scripts/tests だが **単一の atomic security purpose** (forbidden word 昇格 + purge)
- `1533b87` docs(audit) — docs のみ
- `7d9f9c4` fix(deploy) graceful skip — .github のみ
全 commit 単一主題。`4992356` は dir 横断だが論理的に不可分の 1 purpose ゆえ flag せず。
**Finding**: none。

### D9 — TOOLKIT.md ↔ scripts/ 同期
**Status**: 🟡 partial (pre-existing、out-of-range)
**Evidence**: `scripts/*.sh` 全数 vs TOOLKIT → 差分 3 件: `scripts/operator-local/gen-identity.sh`, `.../test-gen-identity.sh`, `.../archive/test-phase6-memo-mock.abandoned.sh`。いずれも **`operator-local/` subtree の既存 script (range 外)** で、operator-local phase-α tooling (memory 上 gen-identity は 11-step 専用) ゆえ意図的に TOOLKIT catalog 対象外の可能性が高い。**本 range で追加された 2 script は両方 TOOLKIT 記載済** (C9 pass)。
**Finding**: 🟡 informational — 本 range 起因ではない既存 3 件。operator-local を TOOLKIT scope 外と明示するか、記載するかは operator 判断。auditor は実装しない。

### D10 — OPERATING_MODEL W1-W10 ↔ scripts 実存
**Status**: ✅ pass
**Evidence**: `OPERATING_MODEL.md` 内 `scripts/*.sh` 参照を全 resolve → MISSING 0 (all exist)。
**Finding**: none。

---

## Simplified review (C-series, thorough C1–C12)

### C1 — Secret/literal 追加混入
**Status**: ✅ pass — range diff の base64 32+byte literal 0、publish-guard `--diff` RC=0。

### C2 — Broadcast-capable command 生追加
**Status**: ✅ pass — 追加行に `proton action|transaction`/`cleos push`/`push_transaction|issueTx|eth_sendRawTransaction` の生使用 **0** (guard/directive 記述除く)。

### C3 — Heredoc/1-liner の手動 operator 指示
**Status**: ✅ pass (1 件 🟡 informational は非該当)
追加 doc 行の `sudo`/`rm -rf`/`chown -R` grep hit は **audit report (T10-54) 自身の C3 記述 1 行のみ** (`${XS}`-scoped `rm -rf` を design plan 例として 🟡 分類する auditor prose)。two-host deploy doc (`c716778`) に operator-paste 用 sudo/rm block なし。

### C4 — 追加 script の shebang + `set -euo pipefail`
**Status**: ✅ pass — 新規 2 script 両方 shebang + `set -euo pipefail` + `bash -n` clean (③参照)。

### C5 — JSON schema additive/breaking
**Status**: ✅ N/A pass — range で `schema*.json`/`*.schema.json` 変更 **0**。

### C7 — File mode
**Status**: ✅ pass — 新規 script 755 (`build-rsync-excludes.sh`, `install-xserver-static-deploy-key.sh`)、test 755、`deploy/feed-excludes.txt` 644、doc/json 644。secret 疑い file の tracked 追加なし。

### C8 — 追加 script の対応 test
**Status**: ✅ pass — `build-rsync-excludes.sh`→`tests/deploy/test-build-rsync-excludes.sh` (7/7)、`install-xserver-static-deploy-key.sh`→`tests/install-xserver-static-deploy-key/...` (5/5)。両方 PASS。

### C9 — TOOLKIT.md 同期 (range-scoped)
**Status**: ✅ pass — 新規 2 script とも TOOLKIT.md L170/L171 追記済 (前回 🟡 の `build-rsync-excludes.sh` 解消)。

### C11 — Numeric claim の曖昧 marker
**Status**: ✅ pass — 追加行の `~[0-9]`/`約[0-9]` hit は T10-54 audit report 内の **`"~88 lines"` の引用** (= 除去対象を documenting する de-fuzzing 文脈、`7828e2e` で除去済の literal を引用) のみ。新規 fuzzy claim ではない。

### C12 — Audit doc in-place edit
**Status**: 🟡 → 見解は ① に集約
`4992356` が `docs/audits/constitution-2026-07-04-design-stocktake.md` + `...T10-24-audit.md` を strike/REVISION なしで in-place 編集。機械的には C12 抵触だが、forbidden-literal purge (strike 保存不能) による正当 override。**operator ratification 事項** (① 参照)。T10-54 report (`1533b87`) 自身は追加のみで無改変。

---

## Statistics

- Dimensions checked: 22 (D1–D10 = 10、C1–C12 の thorough 対象 12 中 C6/C10 は本 preset 定義になく N/A、実 check 11)
- Passed (🟢): D1,D2,D3,D4,D5,D6,D7,D8,D10 + C1,C2,C3,C4,C5,C7,C8,C9,C11 = 18
- 🟡 (operator judgment / informational): D9 (pre-existing TOOLKIT omission)、①/C12 (append-only override — 両解釈提示) = 2
- 🔴 critical: **0**
- N/A: C5 (schema 無変更)、C6/C10 (preset 定義外)

---

## Auditor note

- Fabrication: 0 件 (全 finding は実 evidence 付き — git show / grep / shasum / bash -n / 実 test 実行)。
- 特筆: D6 は naive scan の 30 skip が全て ```sh code-fence 内 `#` comment の false positive と判明したため fence-aware 再scan (real skips 0) で確定 — 誤検出を report に持ち込まない検証を実施。
- 越権実装: 0 件 (指摘のみ、修正未実装)。
- Numeric claim: 全実測 (<provider> sha256 実算、test PASS 数 = 実行出力、hit 数 = 実 grep)。「~」「約」不使用。
- SECRET/CONFIDENTIAL: audit report に禁止 literal を一切出力せず (guard/gitleaks は「検出なし」の事実のみ記載)。
- Append-only: この report は **新規 file** (`docs/audits/constitution-2026-07-06T11-45-audit.md`)。既存 audit doc は未 touch。

> **operator へ**: 各 finding は `superpowers:receiving-code-review` の手続きで独立 verify してください。performative agreement / blind implementation は禁止。本 audit の唯一の判断事項は **①/C12 の "forbidden-word purge が append-only を override する doctrine" を明示 ratify するか** (現状 commit message 宣言 + 先行 handle/company redaction 前例で defensible、🔴 非該当) と、**D9 の operator-local script を TOOLKIT scope 外と明示するか** の 2 点。両方とも security/anonymity 上は既に正しい方向であり、成文化すれば以降 🟢。疑義あれば `--scope=` 絞り再監査を。
