# Constitution Audit — 2026-07-07T12:22 (JST) — C1–C6 専任

## Summary

- **Overall**: 🟡 (🔴 0 件 / 🟡 5 件、全て informational-to-low、broadcast/secret 系は全 pass)
- **Range**: `42797ae~1..HEAD` (= `42797ae`..`da6fbc9`、52 commits 実測)
- **Scope**: C1–C6 のみ (D-series / C7–C12 は別 auditor 担当)
- **Review preset**: thorough (C1–C6 限定)
- **Violations**: C-series 🔴 0 件 / 🟡 5 件 (C3=1, C4=1, C5=1, focus F1, F2)
- **Auditor**: constitution-auditor agent (C1–C6 専任)
- **HEAD at audit**: `da6fbc9`

特別 highlight (PRIME DIRECTIVE 関連): 本監査中、auditor 自身の grep command (broadcast shape 文字列を含む) が tier-1 PreToolUse hook に **exit 2 で live block された** (PRIME_DIRECTIVE_VIOLATION が stderr で feed back され tool call が実行されなかった)。commit `7b86977` (exit 1→2 fix) が live tool call を実際に block することの、テストではない in-session 実測 evidence である。

## Simplified review (C-series)

### C1 — Secret / literal の commit 追加

**Status**: ✅ pass 🟢

**Method**: `gitleaks git --log-opts="42797ae~1..HEAD"` (gitleaks 8.30.1) + 全 52 commit の追加行 5,678 行 (`git log -p | grep '^+'` 実測) に対する custom pattern grep (operator handle / `xoxb-` / `xoxp-` / `sk-proj-` / IPv4 literal / base64 40 文字以上)。

**Evidence**:
- gitleaks: `52 commits scanned. ... no leaks found` (336.58 KB scan、実出力)
- operator handle: 0 hit
- token pattern: 1 hit — added-lines L3468、audit doc 内の **pattern 名の説明 prose** であり値ではない
- IPv4: `127.0.0.1` 4 hit (loopback) + `203.0.113.11` 1 hit — RFC 5737 (TEST-NET-3) documentation 例で、audit doc 内の記述。実 host は `${VALIDATOR_HOST:?}` env var 経由のまま
- base64/hex 40+: 7 hit — 全て Merkle root hash / commit SHA / test dummy (`dddd…`) / publish-guard の WORD_HASH (sha256) で secret 値なし

**Finding**: なし。

### C2 — Broadcast-capable command の生追加 (+ focus: tier-1 exit-2 / cycle-gate ungating / guard 回帰)

**Status**: ✅ pass 🟢

**Method**: 追加行 5,678 行を broadcast shape 6 種 (obfuscated pattern) で grep → 帰属分類。`scripts/broadcast-guard.sh` の BROADCAST_PATTERNS 8 本を Read で実確認。focus 3 領域は commit diff Read + caller grep + test suite 実行。

**Evidence**:
1. **生追加 0 件**: 追加行の broadcast shape hit は (a) `tests/broadcast-guard/test-broadcast-guard.sh` の block assertion 14 行 (期待 exit=2)、(b) audit doc 内の pattern 記述のみ。実行可能 script への raw broadcast 追加は 0。
2. **tier-1 exit-2 fix (`7b86977`) の live 実証**: 監査中の Bash tool call (grep に `cleos push` 系文字列を含む) が hook に block され、stderr に `=== PRIME_DIRECTIVE_VIOLATION === Raw broadcast-capable command detected — blocked unconditionally. Detected shape: cleos[[:space:]]+.*push[[:space:]_]+(action|transaction)` が返り tool call は実行されなかった。exit 2 semantics が現 session で実際に block している。diff 実確認: broadcast-guard の block path 5 箇所全て `exit 1` → `exit 2`、`install-tier1-hook.sh` smoke test は block leg に exactly 2 を要求。
3. **guard 回帰なし (test 実測)**: test-broadcast-guard **27 PASS / 0 FAIL**、test-publish-guard **39 PASS / 0 FAIL**、test-safe-broadcast **16 PASS / 0 FAIL** (本監査で実行)。
4. **cycle-gate ungating (`42797ae`) は broadcast の穴を開けていない**: ungated `cycle-artifact-write` の caller は 5 本のみ (`gen-evidence.sh:56` / `uptime-history.sh:140` / `node-info.sh:27` / `gen-cycle-history.sh:60` / `gen-renewal-ics.sh:29`、grep 実測) — 全て backward-looking artifact writer で broadcast 経路なし。`broadcast` side-effect は signature-gated のまま (`cycle-gate.sh` case 分岐 Read 確認)。cycle-gate suite **20 PASS / 0 FAIL** (本監査で `tests/cycle-gate/run-tests.sh` 実行、T20/T22 で ungate 挙動を assert)。
5. **v1 auto-broadcast path の退役 (`2ae3519`)**: `scripts/post-anchor-event.sh` 691 行削除 (broadcast 経路の削減 = positive)。`resume-after-cycle-start.sh` は broadcast を `sign-anchor-event.sh (→ bin/safe-broadcast)` に委譲 (L7-14 header Read 確認)。
6. **PRIME_DIRECTIVE marker**: range 内追加 script 9 本に新規 broadcast pathway なし → marker 義務の対象なし。

**Finding**: なし (下記 F2 は関連 observation として focus 節に分離)。

### C3 — Heredoc / one-liner の手動 operator 指示

**Status**: ⚠ 🟡 informational (1 件)

**Method**: 追加行の `sudo` / `rm -rf` / `chown -R` grep → 帰属 file を `git log -S` + `git grep HEAD` で特定。

**Evidence**:
- `sudo` hit は全て installer script 自身の usage comment / root-check (`install-watch-cron.sh` / `install-watch-list.sh` / `install-metal-host-drift-cron.sh` / `install-cron-env-headers.sh` / `install-repoint-publish-crons.sh`) = installer-script-first rule **準拠 pattern**。`sudo -u deploy bash scripts/push-to-web-host.sh …` は `scripts/prep-cycle-anchor-recording.sh:199` (script 内部、doc paste ではない)。
- `rm -rf` hit は test teardown (変数 scoped) が大半。doc 内は 1 箇所: `docs/superpowers/plans/2026-07-06-anchor-static-propagation-convergence.md:214` の `rm -rf "${XS}"` (commit `9af3b6b` で追加)。

**Finding** (🟡): plan doc L214 の `rm -rf "${XS}"`。ただし `${XS}` = 一時 staging dir で変数 scoped、implementation plan の test-block 例 (implementer AI 向け Step 2) であり operator paste 1-liner ではない。前回 audit (2026-07-06T10-54 C3) と同一分類 (informational、低 severity)。

**Suggested fix (指摘のみ)**: plan doc は実装完了後 archive されるため対応不要。今後の plan doc では staging cleanup を `mktemp -d` + `trap` 形で書くと C3 grep の noise が減る。

### C4 — 追加 script の shebang + `set -euo pipefail`

**Status**: ⚠ 🟡 (1 件)

**Method**: range 内 `--diff-filter=A` で追加された `scripts/` 配下 9 本全てに head -1 + grep 実測。

**Evidence** (9 本実測):

| script | shebang | `set -euo pipefail` | mode |
|---|---|---|---|
| `scripts/check-host-drift.sh` | `#!/usr/bin/env bash` | **なし** (L49 = `set -uo pipefail`、`-e` 欠落) | 755 |
| `scripts/check-watch-validators.sh` | OK | OK | 755 |
| `scripts/deploy/build-rsync-excludes.sh` | OK | OK | 755 |
| `scripts/install-cron-env-headers.sh` | OK | OK | 755 |
| `scripts/install-metal-host-drift-cron.sh` | OK | OK | 755 |
| `scripts/install-repoint-publish-crons.sh` | OK | OK | 755 |
| `scripts/install-watch-cron.sh` | OK | OK | 755 |
| `scripts/install-watch-list.sh` | OK | OK | 755 |
| `scripts/install-xserver-static-deploy-key.sh` | OK | OK | 755 |

**Finding** (🟡): `check-host-drift.sh:49` は `set -uo pipefail` で `-e` を省略しているが、省略理由の comment がない。exit-code contract (0/1/2) と alert 経路の明示 handling から意図的省略と推定できるが、推定であって明文ではない。

**Suggested fix (指摘のみ)**: L49 直上に「`-e` を省かない場合 fetch 失敗が alert 発火前に abort するため意図的に省略」等の 1 行 comment を追加。

### C5 — JSON schema 変更の additive / breaking 判定 (+ focus: dag_root_hash 退役の残存参照)

**Status**: ⚠ 🟡 (breaking retirement 1 群、documented + 承認 track あり)

**Method**: `git diff --name-status 42797ae~1..HEAD -- '*.json'` → schema file 別 diff 精査 + `required` 配列 diff grep + `jq -c '.required'` 実測 + `git grep dag_root_hash HEAD` 全数分類。

**Evidence**:
- `public/api/identity.schema.v1.json` (M): `required` 配列 **無変更** (diff の required hit 0、現 required 12 項目に `dag_root_hash` 含まれず)。`dag_root_hash` / `cycles_history_url` は **削除せず optional のまま RETIRED と description 明記** (backward-compat 明文)。→ schema 構造としては additive/non-breaking。
- `public/api/evidence.schema.v1.json` (M): 1 insertion / 1 deletion、description 文字列 1 行のみ → additive。
- `public/api/cycles-history.example.json` / `cycles-history.json` / `cycles-history.schema.v1.json` (**D**): 公開 API surface の file 削除 = **外部 verifier に対して breaking**。ただし (a) `docs/IDENTITY_SCHEMA_CHANGELOG.md` に 2026-07-06 entry (L43-83) で retirement 全記述、(b) `docs/MERKLE_DAG_SPEC.md:7` / `docs/IDENTITY_VERIFICATION.md` / 公開 verify page (`36974a3`) まで propagation 済、(c) operator 承認済 design-stocktake wave① (`79ed3be`, `6952ac2`, `2d63a89`) の一部。
- 退役の残存参照 (live code): `gen-identity.sh` は emit しない (L383/L452 comment のみ)、`test-gen-identity.sh:148` は **absence を assert** (退役 invariant の test 化)。`append-anchor-history.sh` の `.dag_root_hash` 参照は **receipt schema の現役 field** (v2 の on-chain root 名) で退役対象外。`approved_dag_root_hash` (cycle-gate state) は互換のため意図的に field 名維持 (`docs/CYCLE_GATE.md:100` に明記)。→ 不整合な残存 0。

**Finding** (🟡): C5 定義上、公開 schema/file の削除は breaking = 🟡 flag 対象。本件は changelog + docs propagation + operator 承認 track が揃っており追加 action 不要と判断するが、dimension 規約に従い 🟡 として記録する。

**Suggested fix (指摘のみ)**: なし (対応済)。外部 verifier 向けには旧 URL への 410/redirect 配慮が将来検討可能 (低優先)。

### C6 — (auditor spec 未定義)

**Status**: N/A

**Method**: constitution-auditor dimension catalog は C1–C5 / C7–C9 / C11–C12 を定義し **C6 は未定義**。repo 内 precedent を grep 実測: `docs/audits/constitution-2026-07-03T15-43-audit.md:209` = `### C6 — (undefined in auditor spec)`、`docs/audits/constitution-2026-07-06T10-54-audit.md:197` = `### C6 — (spec 未定義)`。

**Finding**: 判定対象の基準が存在しないため verdict なし (fabricated 基準での判定は行わない)。過去 2 audit と同一取り扱い。

## Focus areas (依頼指定の注意領域 — dimension 外 finding)

### F1 (🟡) — Phase β contract spec に v2 未伝播の stale 記述

**Evidence**: `scripts/operator-local/contract/metalfreedom-anchor.spec.md:4-5` — 「The Phase α anchor **uses** `eosio.token::transfer` with a memo of the form `fyid1:<dag_root_hash>`」と現在形で記述。一方 `docs/MERKLE_DAG_SPEC.md:7` は fyid1 2-branch model を **retired** と宣言し、現行 memo family は `fya<S>c<N>:` (2026-07-04 cycle-3 実 broadcast も `fya1c3:` 系)。同 file L53/L66 の `root_hash` 説明も旧 spec 参照のまま。③ doc propagation (f2e9b17/72148f8/a568b93) がこの file に届いていない。

**Suggested fix (指摘のみ)**: 冒頭 blockquote の Phase α 記述を v2 (fya memo family、anchor-source `dag_root_computed`) に更新するか、file 冒頭に「Phase α 記述は歴史的 (fyid1 は退役済)」の 1 行 note を追加。

### F2 (🟡) — Aggregate test runner の discovery gap (cycle-gate suite が全体実行に入らない)

**Evidence**: `tests/run-all-tests.sh:22` の discovery pattern は `test-*.sh` のみ (L83 `find ... -name "$PATTERN"`)。`tests/cycle-gate/run-tests.sh` (20 case)、`tests/cycle-gate/scenario-test-endtime.sh`、`tests/ops/test_b6_enable_cron.py` は命名/拡張子が pattern 外で、本監査の全体実行 (31 suites) に含まれなかった (実行 list に不在を実測)。個別実行では 20/20 PASS のため現時点の実害はないが、broadcast gate に隣接する cycle-gate の回帰が全体 runner から不可視。

**Suggested fix (指摘のみ)**: `run-tests.sh` を `test-cycle-gate.sh` に rename する、または run-all-tests.sh に追加 pattern / 明示 list を持たせる。

### F3 (🟢 判定のみ) — cron installer 4 commit (fdaa179 / 533a4ff / 8fe6132 / da6fbc9) の相互整合

**Evidence**: (a) 新規 cron installer 2 本の emit 内容は両方 `SHELL=/bin/bash` + 明示 `PATH` header 込み (`install-watch-cron.sh:63-66`、`install-metal-host-drift-cron.sh:57-59`) → `install-cron-env-headers.sh` (欠落 header の補填、scope=`/etc/cron.d/metal-*` のみ) と競合しない。(b) 両 cron file 名 (`metal-watch-validators` / `metal-host-drift`) は project prefix `metal-*` 内。(c) `533a4ff` (wrong-value SHELL は warning のみで不変更) と `8fe6132` (repoint は「違反を**追加**する rewrite」だけ skip) は方針が同一 (既存状態を悪化させる書換のみ拒否)。test 実測: install-cron-env-headers **25/0**、install-watch-cron **13/0**、install-watch-list **18/0**、install-metal-host-drift-cron **17/0**、install-repoint-publish-crons PASS。不整合 0。

## Statistics

- Dimensions checked: 6 (C1–C6) + focus 3 (F1–F3)
- Passed: C1 🟢, C2 🟢 (+F3 🟢)
- Flagged 🟡: 5 件 — C3 (plan doc rm -rf、informational)、C4 (`check-host-drift.sh` の `-e` 省略 comment なし)、C5 (cycles-history 公開 file 削除 = documented breaking)、F1 (contract spec stale fyid1 記述)、F2 (aggregate runner が cycle-gate suite を拾わない)
- 🔴 critical: 0 件
- N/A: C6 (spec 未定義)

### Test suites executed (本監査での実測)

| suite | 結果 |
|---|---|
| `tests/run-all-tests.sh` (aggregate) | **31 suites / pass=31 / fail=0** (内訳: broadcast-guard 27/0、publish-guard 39/0、safe-broadcast 16/0、anchor-pipeline 26/0、host-drift 17/0 + installer 17/0、install-cron-env-headers 25/0、watch-validators 31/0 + 13/0 + 18/0、sign-anchor-event 19/0、gen-anchor-receipt 10/0、append-anchor-history 16/0、canonicalizer 9/0、config-paths 1/0、他 summary なし suite は PASS) |
| `tests/cycle-gate/run-tests.sh` (aggregate 外、個別実行) | **20 PASS / 0 FAIL** |

## Auditor note

- Fabrication: 0 件 (全 finding は git show / grep / Read / 実 test 実行の実測 evidence 付き)
- 越権実装: 0 件 (本 report file の新規作成のみ、他 file 未変更)
- Numeric claim: 全実測 (「~」「約」不使用)
- Append-only: この report は新規 file、既存 audit doc 未 touch
- Broadcast 経路: 未使用 (tier-1 hook による grep pattern の false-positive block 1 回を live evidence として記録。broadcast 実行の試行ではない)
- Untracked operator 作業 (docs/audits/ 配下の未 commit audit doc 群等): 未 touch

> **operator へ**: この report の各 finding は `superpowers:receiving-code-review` の手続きに従い independently verify してください。疑問のある finding は追加質問で深掘りするか再監査を依頼してください。
