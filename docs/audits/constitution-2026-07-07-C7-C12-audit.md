# Constitution Audit — 2026-07-07T12:24 (JST) — C7–C12 専任

## Summary

- **Overall**: 🟡
- **Range**: `42797ae~1..HEAD` (52 commits 実測、HEAD = `da6fbc95366c93ad8449312c1bd7c626696ee90e`)
- **Scope**: C7–C12 のみ + 依頼指定 focus area (doc/実装乖離・e2e 実質・schema/example 整合)。D-series / C1–C6 は別 auditor 担当
- **Review preset**: thorough
- **Violations**: 🔴 0 件 / 🟡 3 dimension (C11, C12, Focus-B) — 個別 finding 5 件 + note 1 件
- **Auditor**: constitution-auditor agent (read-only、指摘のみ、修正実装なし)

## Simplified review (C-series)

### C7 — File mode

**Status**: ✅ pass 🟢

**Method**: `git diff --raw 42797ae~1..HEAD` で全変更 file の new mode を全件抽出し、期待 mode (scripts/tests `*.sh` = 100755、docs/json/html = 100644) と突合。secret-extension file (`*.key`/`*.pem`/`.env*`/mnemonic/passphrase 名) の range 内追加と tracked 全体を `git diff --name-only` + `git ls-files` で grep。

**Evidence**:
- range 内で new mode が 100644 以外の file は 43 entries — 全て `scripts/**/*.sh`・`tests/**/*.sh` の 100755 (追加 9 script + 追加 12 test + 変更分) と削除 (`D`, mode 000000) のみ。100644 group は docs/*.md・public/*.json・*.html・workflow yml のみ。逸脱 0 件 (実測)。
- secret-extension file の range 内追加: 0 件 (grep 実測、exit 1)。
- tracked 全体で hit したのは `.env.example` のみ (11 行、placeholder template、range 外 pre-existing)。
- `tests/cycle-gate/fixtures/test-identity-key` は untracked + `.gitignore` + `.gitleaks.toml` allowlist (commit `9846eb9` message + diff で確認: "git-untracked (never in history)")。tracked 混入なし。

**Finding**: なし。

### C8 — 追加 script の対応 test 存在

**Status**: ✅ pass 🟢

**Method**: range 内追加の `scripts/**/*.sh` 9 本を `git diff --raw` から抽出し、各 script 名で `tests/` を grep。代表 suite の実 invoke (path 変数経由の実行) を Read で確認。e2e suite は実行して結果 capture。

**Evidence** (9/9):

| 追加 script | 対応 test (実在確認済) |
| --- | --- |
| `scripts/check-host-drift.sh` | `tests/host-drift/test-check-host-drift.sh` |
| `scripts/check-watch-validators.sh` | `tests/watch-validators/test-check-watch-validators.sh` (L22-23 で実 script を CHECKER として実行) |
| `scripts/deploy/build-rsync-excludes.sh` | `tests/deploy/test-build-rsync-excludes.sh` + `test-rsync-delete-protection.sh` |
| `scripts/install-cron-env-headers.sh` | `tests/install-cron-env-headers/test-install-cron-env-headers.sh` |
| `scripts/install-metal-host-drift-cron.sh` | `tests/host-drift/test-install-metal-host-drift-cron.sh` |
| `scripts/install-repoint-publish-crons.sh` | `tests/install-repoint-publish-crons/test-install-repoint-publish-crons.sh` |
| `scripts/install-watch-cron.sh` | `tests/watch-validators/test-install-watch-cron.sh` |
| `scripts/install-watch-list.sh` | `tests/watch-validators/test-install-watch-list.sh` |
| `scripts/install-xserver-static-deploy-key.sh` | `tests/install-xserver-static-deploy-key/test-install-xserver-static-deploy-key.sh` |

- `bash tests/anchor-pipeline/test-run-anchor-pipeline.sh` 実行 → `summary: PASS=26  FAIL=0` / `RESULT: PASS` (本 audit session で実測)。

**Finding**: なし。

### C9 — TOOLKIT.md ↔ scripts/ 同期

**Status**: ✅ pass 🟢

**Method**: `ls scripts/*.sh scripts/deploy/*.sh` (52 本、実測) vs `TOOLKIT.md` 内の script 名 grep を双方向突合。

**Evidence**:
- forward (実体 → catalog): 52/52 全 script が TOOLKIT.md に記載。NOT_IN_TOOLKIT = 0 件。
- reverse (catalog → 実体): TOOLKIT.md が参照する `scripts/…*.sh` path 52 件 (uniq 実測) 全て disk 上に実在。MISSING_FILE = 0 件。
- `scripts/operator-local/` の catalog 除外は `TOOLKIT.md:12` に明文の scope-out 宣言あり (`33ec147` 由来)、意図的除外として整合。

**Finding**: なし。

### C10 — (agent 定義に存在しない dimension)

**Status**: N/A — auditor spec は C1–C5, C7–C9, C11, C12 のみ定義。C10 は未定義のため check 対象なし (先行 audit T10-54 / T11-45 と同じ取り扱い)。

### C11 — Numeric claim の曖昧 marker

**Status**: ⚠ 🟡 (2 件 + note 1 件)

**Method**: `git log 42797ae~1..HEAD --format='%h %s%n%b'` と `git diff 42797ae~1..HEAD` の追加行を `~[0-9]|約[0-9]|およそ[0-9]|だいたい|おおよそ` で grep。hit の文脈を file:line で個別判定。

**Evidence / Finding**:
- **F1 🟡** — commit `0b70b3b` body: `EXPLORER_MIN_VALIDATORS (default 50 vs the ~208-validator network)`。commit message 中の fuzzy numeric marker (`~208`)。memory rule `numeric_claim_capture_before_writing` は「~」marker を禁止。
- **F2 🟡** — `scripts/check-watch-validators.sh:27`: `# (< EXPLORER_MIN_VALIDATORS, default 50 against a ~200-validator network)` (range 内追加行)。source comment だが fuzzy marker、かつ **同一量が commit message では `~208`、code comment では `~200` と不一致**。validator 総数は変動値なので実測時点値 + 観測日付での表記が適切。
- **F3 (note、判定は pass 側)** — `scripts/prep-cycle-anchor-recording.sh:9`: `until cycle-4 (~2026-08-04)` (`155fb24` で range 内追加)。将来 event の見込み日付であり実測不能な予定値 (cycle-4 開始は AddValidator 確定まで固定されない)。過去実測値への fuzzy とは性質が異なるため violation とはしないが、`(= 2026-08-04 見込み)` 等の明示形式が rule の趣旨に沿う。透明性のため記録。
- その他の hit (audit report 内の line-count 引用群、`7828e2e` message の引用) は全て **除去対象の quotation / de-fuzzing 文脈** であり新規 claim ではない (先行 audit T11-45 C11 と同判定)。docs/CYCLE_GATE_*_AUDIT.md 内の `~2026-08-04` は range 内追加行ではない (diff 実測 0)。

**Suggested fix (指摘のみ、agent は実装しない)**: F2 は「observed 208 validators as of 2026-07-07 (fluctuates)」の形式へ、F1 は今後の commit message で marker を使わない運用徹底。F3 は `(= 2026-08-04 見込み)` 形式への置換候補。

### C12 — Audit doc の in-place edit

**Status**: ⚠ 🟡 (新規違反 0、先行裁定の ratification-pending を引き継ぎ)

**Method**: `git diff --raw 42797ae~1..HEAD -- docs/audits/` で M (modification) を抽出、diff 全文を Read。T11-45 以降の追加 edit は `git diff --name-status 1854742..HEAD -- docs/audits/` で確認。

**Evidence**:
- range 内の既存 audit doc modification は `docs/audits/constitution-2026-07-04-design-stocktake.md` 1 本のみ (commit `4992356`、3 行変更 numstat 実測 3/3)。変更内容は forbidden-word purge (`<provider>` 語 → `validator host` / `the validator host`) の語置換のみで、追加行 4 のうち非関連変更 0 (grep 実測: 全変更行が当該語置換)。strike/REVISION 形式ではない = 機械的には C12 抵触。
- ただしこの edit は **T11-45 audit (`docs/audits/constitution-2026-07-06T11-45-audit.md:186-188, 44-49`) が既に 🟡 と裁定済**: forbidden-literal purge は strike 保存だと語が tracked content に残存し purge 目的と publish-guard を破るため物理的に共存不能、override は正当 — ただし **operator ratification (carve-out の成文化) が open のまま**。
- `1854742..HEAD` (T11-45 以降) の docs/audits/ 変更: **0 件** (実測、no output)。新規 in-place edit なし。
- 本 report は新規 file であり append-only 遵守。git status の untracked audit doc 群 (operator 未 commit 作業) には触れていない。

**Finding**: 新規違反なし。`4992356` の override doctrine (forbidden-literal purge > append-only) の成文化 ratification が引き続き operator 判断待ち。それが成文化されるまで機械的判定は 🟡 のまま。

## Focus areas (依頼指定の doc/実装乖離 verify)

### Focus A — CYCLE_GATE.md v2 rewrite (a04c003 系列) vs cycle-gate.sh 実装

**Status**: ✅ 一致 🟢

**Method**: `docs/CYCLE_GATE.md` (311 行) と `scripts/cycle-gate.sh` (180 行) を全文 Read、主張ごとに実装行と突合。consumer 一覧は `grep -rn 'cycle-gate' scripts/*.sh` で全数実測。

**Evidence** (doc 主張 → 実装):
- side-effect 4 型 + `cycle-artifact-write`/`observe` 無条件 green → `cycle-gate.sh:79-98` (state read も RPC もせず exit 0)。
- exit code 0/1/2 → `cycle-gate.sh:12-15` + 実装各所一致。
- behavior matrix (state 欠如=green `L112-115` / corrupt=fail-closed `L118-121` / schemaVersion≠1=fail-closed `L131-134` / RPC 不達=fail-closed `L148-151` / validator 不在=deferred `L160-163` / signature 比較 `L172-180`) → doc L133-142 の 6 行 matrix と全一致。
- `FY_RPC_TIMEOUT` default 6 → `cycle-gate.sh:105`。state file schema 4 field → `L48-54` = doc L96-101。
- consumer list: artifact-write = `gen-cycle-history.sh:55-62` / `uptime-history.sh:129-141` (Job A ungated + Job B gated、doc の記述通り) / `node-info.sh:22-28` / `gen-evidence.sh:51-57` / `gen-renewal-ics.sh:24-30` / `prep-cycle-anchor-recording.sh:129`; notify = `check-anomalies.sh:54-61` / `daily-status.sh:30-36`。doc L120-121 の列挙と完全一致 (過不足 0)。
- `broadcast` 型の consumer: **0 件** (`grep -rn 'side-effect=broadcast'` で scripts/tests/.github 全域 0 hit、doc L122 "No current consumer" の通り)。
- Rollback lever 2 (3681e32/68a755e/7650a27 の訂正 3 連): `chmod -x` 時に各 artifact writer が `[ ! -x ]` 検知で `exit 0` skip (gen-cycle-history L56-59 実 Read で確認)、`check-anomalies.sh` は exit せず `CYCLE_GATE_OK=0` flag で cycle 系 alert のみ suppress (L53-61、非 cycle 監視は継続 = doc の "suppresses, does not exit" 訂正と一致)、`uptime-history.sh` は Job A を gate 前に完了 (L129-141 = doc の "ungated Job A exception" と一致)。

**Finding**: なし。v2 rewrite は実装と一致 (訂正 commit 3 本の内容も全て実装に裏付けあり)。

### Focus B — MERKLE_DAG_SPEC / IDENTITY_VERIFICATION v2 rewrite vs gen-anchor-source.sh 実出力

**Status**: ⚠ 🟡 (計算 semantics は一致、citation off-by-one + trailing-newline 注記欠落)

**Method**: 両 doc の canonical form / branch root / dag root 記述を `gen-anchor-source.sh:469-472`・`sign-anchor-event.sh:176-178`・`sha256_str` (`gen-anchor-source.sh:94-96`) と突合。example file で実再計算。

**Evidence — 一致部分**:
- 3-branch 構造・`jq -cS` canonical・branch root = SHA-256(canonical bytes)・dag root = SHA-256(hex-ASCII 連結 192 bytes、raw digest ではない) — 全て実装 (`ID_ROOT/OB_ROOT/AR_ROOT` = `jq -cS | sha256`、`DAG_ROOT = sha256_str(hex連結)`、`sha256_str` は `printf '%s'` で newline なし) と一致。
- IDENTITY_VERIFICATION の verifier recipe (L99-101 branch root、Step 5 `printf '%s%s%s' | sha256sum`) は producer 実装と byte-level で等価。
- `sign-anchor-event.sh:176-178` の signer 再計算 citation は正確 (実測一致)。

**Finding**:
- **F4 🟡 (citation off-by-one)** — `docs/MERKLE_DAG_SPEC.md:52` は branch root 計算を `gen-anchor-source.sh:470-472` と cite するが実体は **469-471**; `docs/MERKLE_DAG_SPEC.md:69` は `gen-anchor-source.sh:473` と cite するが `sha256_str "${ID_ROOT}${OB_ROOT}${AR_ROOT}"` の実体は **472** (grep -n 実測)。spec 執筆後の script 変更 (`22f8656` 等) で 1 行ずれたと推定。計算内容の記述自体は正しい。
- **F5 🟡 (trailing-newline 0x0a 注記の欠落)** — `docs/ANCHOR_SOURCE.md:81` は「hash 対象 bytes は `jq -cS` 出力 **trailing newline (0x0a) 込み**。等価 canonicalizer は 0x0a を append MUST」と明示する (SPEC-1 close の成果)。しかし v2 rewrite 後の `MERKLE_DAG_SPEC.md` §2-§3 と `IDENTITY_VERIFICATION.md:106` (「non-jq JCS serializer MUST match jq's encoding」) には **0x0a 注記が存在しない** (`grep -n newline` 両 doc 0 hit 実測)。jq pipeline をそのまま実行する verifier は正しい root を得るが、spec prose だけを読んで newline なしで hash する非 jq verifier は mismatch する。さらに `docs/CYCLE_GATE.md:305-306` は「MERKLE_DAG_SPEC.md — canonical hashing spec (`jq -cS`, **trailing newline included**)」と cross-reference しており、spec 本体に無い記述を「ある」と主張する乖離。

**Suggested fix (指摘のみ)**: MERKLE_DAG_SPEC §2 に ANCHOR_SOURCE.md:81 相当の 0x0a 1 文を追記 (または §2 から ANCHOR_SOURCE.md:81 への normative 参照)、IDENTITY_VERIFICATION L106 にも同旨追記。line citation は行番号を外して関数/変数名 cite にすると drift 耐性が上がる。

### Focus C — e2e test suite (963cc66 / 11e9d46) の実質 vs 主張

**Status**: ✅ 主張と実質一致 🟢

**Method**: suite (246 行) の構造 grep + header Read、実行 (実測)、stub 機構の主張を orchestrator 実装と突合。

**Evidence**:
- 主張「9 scenario blocks / 26 runtime assertions」→ `case 1..9` の block header 9 個 grep 実測 + 実行 `PASS=26 FAIL=0` (assertion 単位 count、header L12-13 の明記通り)。`11e9d46` はこの曖昧さ (「26 case」) を PR review 指摘で明確化した +3 行のみの doc commit — diff 実測 3 insertions。
- 主張「REAL orchestrator + recording stubs、broadcast path 到達不能」→ `run-anchor-pipeline.sh:41` が `REPO_ROOT="$(dirname "$0")/.."` で自位置導出、suite L57 が orchestrator を harness へ `cp` — 主張の機構どおり全 sub-script call が harness 内 stub へ向く。fail-fast は per-case `order.log` で「後続 step が呼ばれていない」ことを assert (tautology 回避の主張も構造上成立)。
- 限界の自己申告も正確: 「wiring suite」であり実 RPC/署名/broadcast は対象外と header/commit の両方が明示 (過大主張なし)。

**Finding**: なし。

### Focus D — Schema と example の整合 (446f423 ほか)

**Status**: ✅ 一致 🟢

**Method**: `anchor-source.example.json` の `dag_root_computed` を spec 手順 (jq -cS → sha256 → hex 連結 → sha256) で独立再計算し stored 値と比較。range 内変更のあった schema/example 3 組の required field 充足を jq で全数 check。

**Evidence**:
- `anchor-source.example.json`: recomputed = `88c0fb7ad09cb75b5d4748df12ea692cc15dca7d11b686d5ba867e0e739b8754` = stored (**MATCH**、実測)。`446f423` の「manifest 編集後の dag_root_computed 訂正」は正しい値に修正済。
- required field 充足 (実測): anchor-source / identity / evidence の各 example → missing-required **全て 0**。
- `79ed3be` の `dag_root_hash` 退役: `identity.schema.v1.json:166-169` が RETIRED を明文化 (optional 維持は旧 snapshot 互換のためと理由明記)、`identity.example.json` は field 除去 + `_comment` で退役を説明。live `identity.json:52` に旧 field が残るのは「cycle-4 再生成待ち」として schema の backward-compat 条項と整合 (乖離ではなく文書化済の過渡状態)。

**Finding**: なし。

## Statistics

- Dimensions checked: 5 (C7, C8, C9, C11, C12) + focus area 4 (A–D)。C10 は spec 未定義で N/A
- Passed 🟢: C7, C8, C9 + Focus A, C, D = 6
- 🟡: C11 (finding 2 + note 1)、C12 (新規 0、ratification-pending 引き継ぎ 1)、Focus B (finding 2) = 3 dimension / 個別 finding 5 + note 1
- 🔴 critical: 0
- 実行 test: `tests/anchor-pipeline/test-run-anchor-pipeline.sh` → 26 PASS / 0 FAIL (実測)

## Auditor note

- Fabrication: 0 件 — 全 finding は git show / git diff / grep / Read / 実 test 実行 / 実 hash 再計算の出力に基づく
- 越権実装: 0 件 — 本 report file の新規作成のみ、他 file 無変更
- Numeric claim: 全て書く直前に実測 capture (52 commits、9 scripts、52/52 catalog、26 assertions、3/3 numstat 等)。「~」「約」不使用 (引用箇所を除く)
- Append-only: 本 report は新規 file。既存 audit doc・untracked operator 作業 未 touch
- Broadcast: 実行 0 (chain read すら不要だった — 全 verify が repo local で完結)
- Host identifier / secret 値: 本 report に literal 記載なし (provider 語は publish-guard 準拠で `<provider>` placeholder 表記)

> **operator へ**: この report の各 finding は `superpowers:receiving-code-review` の手続きに従い independent verify してください。特に C12 の override doctrine ratification (T11-45 から open) と Focus B の trailing-newline 注記欠落は operator 判断事項です。疑問のある finding は追加質問で深掘りしてください。
