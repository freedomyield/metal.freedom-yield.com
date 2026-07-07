# Constitution Audit (D-series) — 2026-07-07T12:22 (JST)

## Summary

- **Overall**: 🟡 (🔴 0 件 / 🟡 1 件)
- **Range**: `42797ae~1..HEAD` (= 52 commits 実測、HEAD = `da6fbc9`、2026-07-04 design stocktake 以降)
- **Scope**: D-series 全次元 (D1–D10)。C-series は別 auditor 担当のため本 report の対象外。
- **Violations**: D-series 🔴 0 件 / 🟡 1 件 (D5)
- **Auditor**: constitution-auditor agent (read-only、broadcast 経路不使用。実行した外部アクセスは公開 API への read-only `curl` 2 回のみ)

| Dim | 内容 | Verdict |
|---|---|---|
| D1 | PRIME DIRECTIVE 4 gate 一致 | 🟢 |
| D2 | Broadcast shape 完全捕捉 | 🟢 |
| D3 | Secrets tracked 混入なし | 🟢 |
| D4 | 設計 target ↔ anchor schema 被覆 | 🟢 |
| D5 | Schema version consistency | 🟡 |
| D6 | Doc heading nesting | 🟢 |
| D7 | Inline style 禁止 | 🟢 |
| D8 | Commit single-purpose | 🟢 |
| D9 | TOOLKIT.md ↔ scripts/ 同期 | 🟢 |
| D10 | OPERATING_MODEL W1–W10 script 実在 | 🟢 |

## Constitution dimensions (D-series)

### D1 — PRIME DIRECTIVE 4 gate consistency

**Status**: ✅ pass

**Method**: 4 箇所 (CLAUDE.md / docs/CONSTITUTION.md / scripts/broadcast-guard.sh / bin/safe-broadcast) から 4 gate の文言と実装を Read + grep で抽出し相互突合。tier-2 wrapper は repo 実体が `scripts/safe-broadcast.sh` ではなく `bin/safe-broadcast` (tracked、`git ls-files` で確認)。

**Evidence**:
- `docs/CONSTITUTION.md:15-20`: PRIME DIRECTIVE block、gate (1) testnet-first identical shape / (2) per-invocation operator authorization `{chain, actor, permission, action, memo, quantity}` / (3) pre-flight `chain:get` / (4) `--dry-run` exhaustion。
- `CLAUDE.md:9`: 同 4 gate を non-authoritative summary として列挙 (「(1) testnet-first … (2) explicit per-invocation … (3) pre-flight `chain:get` … (4) exhausted `--dry-run`」)。
- `scripts/broadcast-guard.sh:135-137`: block message が「the four PRIME DIRECTIVE gates (testnet-first / per-invocation authorization / pre-flight chain match / dry-run)」を明記。raw broadcast は `FYD_SAFE_BROADCAST=1` marker なしで無条件 exit 2 block (L128-148)。exit 2 semantics fix (`7b86977`) が反映済 (L12-16 comment + L64/L148/L157/L169/L177 実装)。
- `bin/safe-broadcast`: gate 1 = `--testnet-tx-id` 必須 + testnet Hyperion 実 resolve (L141-163)、gate 2 = operator token 存在 + freshness (L177-202)、gate 3 = `proton chain:info` の `chain_id` を期待定数と完全一致比較・fail-closed (L205-226)、gate 4 = `--dry-run-log` 必須 + 非空 (L166-173)。冒頭 10 行内に `PRIME_DIRECTIVE: TESTNET-FIRST` marker あり (L6)、default chain は testnet (L4)。
- Constitution L19 の「`chain:get` (or equivalent)」に対し wrapper 実装は `proton chain:info` + chain_id 完全一致 — 「or equivalent」条項内で一致。

**Finding**: null (差分なし)。

### D2 — Broadcast-capable command shape の完全捕捉

**Status**: ✅ pass

**Method**: `scripts/broadcast-guard.sh:84-95` の `BROADCAST_PATTERNS` 配列を Read で抽出し、期待 list (proton action / proton transaction / proton transaction:push / cleos push_transaction / push action / push transaction / curl・wget の push_transaction / issueTx / eth_sendRawTransaction) と相互突合。test suite を実行。

**Evidence**:
- `scripts/broadcast-guard.sh:85`: `proton[[:space:]]+action[[:space:]]`
- `scripts/broadcast-guard.sh:86`: `proton[[:space:]]+transaction([[:space:]]|:push)` — `proton transaction` と `proton transaction:push` 両捕捉
- `scripts/broadcast-guard.sh:89`: `cleos[[:space:]]+.*push[[:space:]_]+(action|transaction)` — space/underscore 両 joiner で cleos 3 形態捕捉
- `scripts/broadcast-guard.sh:90-92`: curl/wget × `push_transaction` / `issueTx` / `eth_sendRawTransaction`
- `scripts/broadcast-guard.sh:93-94`: 期待 list 超過分 `(curl|wget).*/ext/bc/[XPC]` + `metalgo .*IssueTx` (追加防御、減点なし)
- `bash tests/broadcast-guard/test-broadcast-guard.sh` → **PASS=27 FAIL=0 / RESULT: PASS** (実行実測)

**Finding**: null。期待 8 shape 全収載 + 追加 2 pattern。

### D3 — Secrets の commit tracked 混入なし

**Status**: ✅ pass

**Method**: `gitleaks detect --no-git` (working tree) + `gitleaks detect --log-opts="42797ae~1..HEAD"` (range history) + custom pattern grep (operator personal literal / 実 host IP 形状 / `xoxb-`・`xoxp-`・`sk-proj-` / 秘密鍵 pattern / secret 拡張子 tracked)。

**Evidence**:
- `gitleaks detect --no-git`: 「scanned ~6669486 bytes … no leaks found」(実行実測。~ は gitleaks 出力の原文)
- `gitleaks detect --log-opts="42797ae~1..HEAD"`: 「52 commits scanned … no leaks found」(実行実測)
- operator personal literal (`git grep -il`): **0 file**
- token pattern grep: hit 1 件 = `docs/audits/constitution-2026-07-06T10-54-audit.md:95` — pattern 名の method 記述であり token 値ではない
- IP 形状 grep: hit 5 file、全出現値は `203.0.113.10` / `203.0.113.11` (RFC 5737 documentation range placeholder、実 host IP ではない) — `scripts/push-to-web-host.sh:78`、`scripts/sync-to-validator-host.sh:33`、`tests/publish-guard/test-publish-guard.sh:67`、audit doc 2 件 (25 行目 / 49 行目、sed + grep -oE で値抽出し確認)
- 秘密鍵 pattern (`PVT_K1_` 等) grep: hit は `docs/OPERATOR_IDENTITY_SETUP.md` (9) + `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md` (4) の手順説明文言のみ、鍵値なし (gitleaks 0 leak が裏付け)
- secret 拡張子 tracked: `git ls-files` → `.env.example` のみ (値は `DOMAIN` 公開値 + 空 `ACME_EMAIL`、Read で確認)。range 内 `.key`/`.pem`/`.env*` の追加 commit **0 件** (`git log --diff-filter=A`)
- forbidden provider word (commit `4992356` で forbidden 昇格した provider 名、本 report では redact): `git grep -il` → **0 file**

**Finding**: null。

### D4 — 設計 target が anchor schema で提供可

**Status**: ✅ pass

**Method**: `docs/STRATEGIC_TARGET_ALIGNMENT.md` L77-81 の 5 設計 target を Read で抽出、`docs/ANCHOR_SOURCE.md` の 3 branch schema 記述と cross-match。

**Evidence + coverage**:

| 設計 target (STRATEGIC_TARGET_ALIGNMENT.md) | anchor 側の被覆 (ANCHOR_SOURCE.md) |
|---|---|
| Independent verifiability (L77) | artifacts_branch (L48) + 標準 tool 再現手順 (L75-77 の jq/sha256sum recipe、L64-71 concatenation 規範) |
| Pseudonymous continuity proof (L78) | identity_branch 6 required fields (L20) + `prev_anchor_root` hash chain (L196) |
| On-chain observation record (L79) | observations_branch 8 required fields (L31): cycle/self-stake/fee/uptime/incident (L197-205) |
| Discoverability in Metallicus orbit (L80) | `evaluator_hints_declared_by_operator` (L43) + memo prefix scheme `fyid`/branch suffix (L95) |
| Honesty about pseudonymous ceiling (L81) | anchor が最適化「しない」対象の明文列挙 (STRATEGIC_TARGET_ALIGNMENT.md L83-88) + doc 全体の pseudonymous 前提記述 |

**Finding**: null。5 target 全被覆。

### D5 — Schema version consistency (namespace 別)

**Status**: ⚠ partial → **🟡**

**Method**: `git grep 'schema_version'` を tracked `*.json` 全体で実測し namespace 別に値を count。live 公開 feed を read-only `curl` で実測。公開 evaluator 向け page の schema pointer を grep。

**Evidence — namespace 内 consistency (pass 部分)**:
- source 系 (`anchor-source.example.json:4` / `anchor-source.substantive.json:3` / schema.v1): 全て `1` — 単一値 ✓
- identity 系 (`identity.json:3` / `identity.example.json:3` / schema.v1): 全て `1` ✓
- evidence / validator / cycle-history: 全て `1` ✓
- receipt 系: v1 example 2 件 = `1` (v1 schema に対応)、`anchor-receipt.v2.example.json:4` = `2` + `schema_version_of_source: 1` (v2 schema に対応) — version-file 別に内部一貫 ✓
- `scripts/append-anchor-history.sh:77`: live pipeline は receipt `schema_version == 2` を要求 (v1 fixture 3 件は `tests/anchor-history/` の legacy suite 専用で、suite 実行結果は「SKIP: legacy test — pre-2026-07-01 anchor design」= live 経路に不接続、実行実測)
- live 実測: `curl https://metal.freedom-yield.com/api/anchor-receipt.json` → `schema_version = 2`、`$schema = …/anchor-receipt.schema.v2.json`、tx `0b70d2aa…` (cycle-3 anchor と一致)。`anchor-history.jsonl` 先頭 entry も `schema_version = 2`

**Finding (🟡)**: **公開 evaluator 向け page の schema pointer が live runtime (v2) と不一致のまま**。

1. `public/selection-evidence/index.html:358` (ja 版 `public/ja/selection-evidence/index.html:358` も同様):「Anchor receipt schema」行が `/api/anchor-receipt.schema.v1.json` + v1 example を案内。live の `/api/anchor-receipt.json` は `$schema` = **v2** (curl 実測)。案内どおり v1 schema で live receipt を validate する evaluator は field 形状差で fail する。
2. 同 page:359 「Anchor history schema」行も `anchor-history.schema.v1.json` を案内、live entry は `schema_version: 2` (curl 実測)。v2 schema file (`public/api/anchor-history.schema.v2.json`、`const: 2`) は tracked 済なのに公開 page から未参照。
3. `public/selection-evidence/index.html:365` + `:485` + `public/verify/index.html` 相当行:「Scheduled anchor receipt … first broadcast at cycle 3 start, 2026-07-04 13:00 JST」と**未来形のまま** — broadcast は 2026-07-04 に完了済 (live tx `0b70d2aa…`)。Constitution §2-3 (public-facing data MUST be truthful, current) との齟齬。

**経緯 (in-range)**: この drift は range 前から存在 (`git show 42797ae~1:public/selection-evidence/index.html` L358/L365 で同一行を確認) し、range 内の `1cb65cc` commit body が「Deeper v1 narrative on the public verify pages … needs a dedicated v2 rewrite」と follow-up 明記、続く `36974a3` (「rewrite verify/selection-evidence pages to the v2 3-branch anchor model」、4 HTML +10/-10) は narrative 段落を書換えたが schema table 行と「Scheduled (2026-07-04)」行は未更新のまま HEAD に残存。既知 follow-up として文書化はされているが、live drift 自体は HEAD 時点で解消していないため 🟡。

**Suggested fix (指摘のみ、agent は実装しない)**: selection-evidence / verify (en+ja) の (a) receipt schema 行を `/api/anchor-receipt.schema.v2.json` + `anchor-receipt.v2.example.json` に (v1 は frozen legacy として併記可)、(b) history schema 行を v2 に、(c) 「Scheduled … 2026-07-04」行を broadcast 完了済の実 tx 参照 (過去形) に更新。deploy 後 live page で pointer → live feed の `$schema` 一致を curl で verify。

### D6 — Doc の h1→h2→h3 nesting 遵守

**Status**: ✅ pass

**Method**: tracked `docs/**/*.md` 47 file (`git ls-files | wc -l` 実測) を awk parser で走査 (code fence 内 heading は除外)、level+1 超の jump を検出。

**Evidence**: 検出 0 件 (scan 出力空、`D6_SCAN_DONE` sentinel まで無出力)。

**Finding**: null。

### D7 — Inline `style="..."` 禁止 (CSP 準拠)

**Status**: ✅ pass

**Method**: `git grep -nE 'style="' -- '*.html' '*.md'` (tracked HTML 45 file、`git ls-files | wc -l` 実測)。

**Evidence**: hit は全て **md file 内の rule 自体の言及** (`CLAUDE.md:35` の convention 行 + 過去 audit doc の D7 method 記述)。HTML file への hit **0 件**。実 inline style 属性 **0**。

**Finding**: null。

### D8 — Commit の single-purpose

**Status**: ✅ pass

**Method**: range 52 commit 全件で `git log --format='%h|%s'` + `git show --numstat` から commit 別変更 top-level dir を抽出し、subject の複数主題 marker (`+` / `;` / 列挙) と突合。機械 flag 分は body を `git log --format=%B` で精読。

**Evidence**:
- 機械 flag 4 件: `6e4a222` (salvage; repoint)、`ba7f86c` (PR #4 review 3 点)、`0b70b3b` (batch 通知 + sanity gate)、`5e73afe` (ordering guard + signing-host assertion)。
- 精読結果: 全て単一 theme の cohesive commit — `0b70b3b` は同一 incident (2026-07-07 01:00 JST の深夜通知) の delivery 設計 rework 一式、`5e73afe` は design-stocktake #6 の 2 precondition を機械化する単一項目、`ba7f86c` は単一 PR review への response、`6e4a222` は watch monitor salvage という単一目的。各 body は why を詳細に説明 (CLAUDE.md convention「single-purpose and explain *why*」充足)。
- 全く別主題 (無関係 2 系統) を混載した commit: **0 件**。dir 複数跨ぎは全て「script + 対応 test + TOOLKIT 行」の同一 feature 束。

**Finding**: null (violation なし。上記 4 件は borderline 記録のみ)。

### D9 — TOOLKIT.md と scripts/ の同期

**Status**: ✅ pass

**Method**: `ls scripts/*.sh` (51 file 実測) と `grep -oE '[a-z0-9_-]+\.sh' TOOLKIT.md` の双方向差集合を `comm` で実測。逆方向 hit は個別に find + 文脈確認。

**Evidence**:
- scripts → TOOLKIT 方向: 差集合 **空** (51/51 収載)
- TOOLKIT → disk 方向の残余 3 件は全て正当:
  - `build-rsync-excludes.sh` → `scripts/deploy/` に実在、TOOLKIT.md:176 は full path で記載
  - `ntfy.sh` → 外部 service domain 名の言及 (TOOLKIT.md:91,94,96)、script 参照ではない
  - `push-to-xserver.sh` → TOOLKIT.md:166 の「retired … を canonical へ repoint する installer」説明内の意図的 historical 参照
- `scripts/operator-local/` は `33ec147` で catalog 対象外と明示済 (commit subject で確認)

**Finding**: null。

### D10 — OPERATING_MODEL W1–W10 と実 script の対応

**Status**: ✅ pass (vacuous)

**Method**: `docs/OPERATING_MODEL.md` (200 行、W1–W10 heading L24-147 実在確認) から `.sh` file 参照を `grep -oE '[a-zA-Z0-9_/.-]+\.sh'` で全抽出し `scripts/` と突合。

**Evidence**: W1–W10 は個別 script 名を **1 件も参照していない** (抽出結果空)。script への言及は L42 の generic pointer「Implementing scripts live in `scripts/` in this repository」のみ。よって dangling 参照 0 (vacuous pass)。

**Finding**: null。個別 script 名参照が存在しないため fail し得ない構造である点は記録 (欠陥ではない — W 別の具体 script は `TOOLKIT.md` 側が catalog を持ち、D9 で同期 verify 済)。

## Statistics

- Dimensions checked: 10 (D1–D10)
- Passed: 9 (うち D10 は vacuous pass)
- 🟡: 1 (D5 — 公開 page の schema version pointer drift + stale future-tense copy)
- 🔴 critical: 0
- N/A (out of scope): C-series 全件 (別 auditor 担当)
- UNVERIFIED: 0 件 (全 claim 実測済)

## Auditor note

- Fabrication: 0 件 (全 finding は grep / git show / Read / test 実行 / read-only curl の実測 evidence 付き)
- 越権実装: 0 件 (本 report file 新規作成のみ、他 file 未変更。untracked の既存 audit doc も未 touch)
- Broadcast: 0 件 (broadcast-capable command 不使用。外部アクセスは公開 API への read-only curl 2 回のみ)
- Numeric claim: 全実測 (52 commits = `git log | wc -l`、51 scripts = `ls | wc -l`、47 docs md / 45 html = `git ls-files | wc -l`、test 27/27 = suite 実行出力)
- Append-only: この report は新規 file、既存 audit doc 未 touch
- Redaction: forbidden provider word は publish-guard 準拠で redact (初回 Write は guard に block され、redact 後に保存)

> **operator へ**: この report の各 finding は、`superpowers:receiving-code-review` の手続きに従い、technical rigor で独立 verify してください。performative agreement や blind implementation は禁止。疑問のある finding は追加質問で深堀りしてください。
