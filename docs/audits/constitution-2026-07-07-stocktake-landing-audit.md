# Constitution Audit — Design-Stocktake Landing Verification — 2026-07-07T12:24 (JST)

## Summary

- **Overall**: 🟡 (LANDED 6 / PARTIAL 5 / OPEN 0 / REGRESSED 0)
- **Range**: `42797ae~1..HEAD` (52 commits 実測、HEAD = `da6fbc9`)
- **Scope**: `docs/audits/constitution-2026-07-04-design-stocktake.md` Part 6 の推奨 11 項目の着地 verify
- **Method**: 各項目につき (a) 該当 commit 実在 (`git log`/`git show`)、(b) HEAD 実ファイル現存 (grep/Read)、(c) 旧参照残骸の全 tree sweep (`git grep`)、(d) 関連 test の実実行
- **Auditor**: constitution-auditor agent (read-only、broadcast 経路不使用、修正実装なし)

### 判定一覧

| # | 項目 | 判定 | 主根拠 commit |
|---|---|---|---|
| 1 | two DAG roots collapse + `fyid1:` print 削除 | **PARTIAL** | `79ed3be`, `6952ac2`, `2d63a89`, `446f423` |
| 2 | cycle-artifact-write ungate | **LANDED** | `42797ae` |
| 3 | stranded auto-broadcast path retire | **LANDED** (repo 側) | `2ae3519`, `a0c2a2a` |
| 4 | push-to-xserver.sh dead reference fix | **LANDED** | `155fb24` |
| 5 | identity-artifact propagation gap | **PARTIAL** | `c4c86ab`, `9af3b6b`, `580edf0`..`7d9f9c4`, `f0b535d`, `22f8656` |
| 6 | ordering guard + signing-host assertion | **LANDED** | `5e73afe` |
| 7 | e2e + dag-reconciliation + signing-host-negative test | **PARTIAL** | `963cc66`, `11e9d46` |
| 8 | CYCLE_GATE.md + anchor runbook の Mac-sign rewrite | **PARTIAL** | `a04c003`, `72148f8`, `f2e9b17`, `36974a3` |
| 9 | TOOLKIT.md 25 missing scripts | **LANDED** | `d55ab04`, `33ec147`, `a0c2a2a` |
| 10 | gitleaks 1 hit clear | **LANDED** | `9846eb9` + 本日実測 0 hit |
| 11 | minor (`~5 min` marker / prep-・preview-・install- の test or one-shot mark) | **PARTIAL** | `155fb24` (prep- DEPRECATED mark) ほか |

### 🔴/想定外 finding (先頭 highlight)

- **F1 (項目 5、🟡 latent)**: `anchor-source.json` の feed publish 経路が repo 側で自己矛盾。`scripts/push-to-web-host.sh` の allowlist に `anchor-source.json` は **0 件** (`grep -c` = 0、`git log -S` でも一度も存在した履歴なし = 範囲内 regression ではなく pre-existing 未解消)。一方で `scripts/check-anchor-publish-health.sh:71` が `push-to-web-host.sh anchor-source.json` を auto-recover として呼び (→ `*)` case で "unrecognized filename" exit 1)、`docs/DEPLOY_OWNERSHIP_MATRIX.md:26-27` はこの経路を動作するものとして記載、`deploy/feed-excludes.txt` は rsync から除外 (= host push 前提)。resume Phase 1 (`scripts/resume-after-cycle-start.sh:173-180`) はこの feed の鮮度を poll する。stocktake #5 が指摘した gap のうち feed 側がこの形で残存。
- **F2 (項目 1、🟡 既知 deferral)**: tracked live artifact `public/api/identity.json:52-53` が retired 2-branch root `c205c51b…` (on-chain に存在しない値) と、tree から削除済みの `cycles-history.json` への URL を今も公開形で保持。`79ed3be` commit message 内で「live signed file valid until regen (cycle-4)」と明示された意図的 deferral だが、項目 1 が除去対象とした「chain 上に無い第二の root の公開」は cycle-4 再生成まで実際には続く。
- **F3 (項目 1 残骸、🟡)**: `public/api/anchor-history.schema.v1.json:82-83` が `^fyid1:` memo pattern を retirement banner なしの現行 contract として自称。`public/api/anchor-history.example.jsonl` も schema_version 1 + `fyid1:` の synthetic 行のまま。live appender `scripts/append-anchor-history.sh:77-78` は schema_version=2 (v2 schema) を強制しており矛盾。
- **F4 (項目 8、🟡)**: `docs/OPERATOR_IDENTITY_SETUP.md:14-21` の status banner が「the inscription is now performed by `scripts/post-anchor-event.sh` … with memo `fyid1:<dag_root_hash>`」と、`2ae3519` で物理削除済みの script を現行経路として案内。`docs/PHASE5_CHECKLIST.md:106-107` も同様 (`consumed by post-anchor-event`)。

REGRESSED (一度着地して後で消えたもの) は 11 項目中 **0 件**。

## 項目別 verify 詳細

### 1 — two DAG roots collapse (`identity.dag == anchor-source.dag_root_computed`、`fyid1:` print 削除)

**Status**: 🟡 PARTIAL

**(a) commit 実在**: `79ed3be` "fix(identity): retire identity.json dag_root_hash — collapse to one on-chain root" (2026-07-06)。stocktake の「identity carries anchor-source's value **(or drops its own)**」の後者を採用 (循環 hash 依存回避のため removal)。続いて `6952ac2` "collapse to single v2 DAG — retire cycles-history.json" (2-branch root の残る出力先 cycles-history.json ごと退役、gen-anchor-source の artifacts_branch からも除去)、`2d63a89` (docs/examples/schema への retirement 伝播)、`446f423` (example の dag_root_computed 訂正)。

**(b) HEAD 現存**: `scripts/operator-local/gen-identity.sh` に `dag_root_hash`/`fyid1` の出力コードなし — 残る 2 hit は retirement を説明する comment のみ (L383, L452 実測)。`fyid1:` console print 削除済み。`scripts/operator-local/test-gen-identity.sh` 実行 = **21 OK / 0 FAIL** (retirement invariant を assert)。

**(c) 残骸 sweep**: `git grep fyid1 -- ':!docs/audits'` の hit は (i) CONSTITUTION 事故記録・MERKLE_DAG_SPEC:7 等の「retired」明示文脈 = 正当、(ii) F3 の anchor-history v1 schema/example = banner なし残骸、(iii) F4 の OPERATOR_IDENTITY_SETUP / PHASE5_CHECKLIST / PHASE_ALPHA_TESTNET_DRY_RUN = live 手順としての残骸。(iv) F2: `public/api/identity.json:52-53` が retired root を保持。

**(d) test**: test-gen-identity 21 OK / 0 FAIL (上記)。

**判定理由**: generator/schema/主要 doc は着地。ただし公開 tracked artifact (F2) と v1 schema/example (F3) に「第二の root / fyid1 が現行」を示す残骸があり、項目の目的 (on-chain に無い root を公開しない) は cycle-4 regen まで未達成。

**Suggested fix (指摘のみ)**: cycle-4 の identity.json 再生成を確実に実施 (既定路線)。anchor-history.schema.v1.json / example.jsonl に retirement banner を付すか v2 example に差し替え。

### 2 — cycle-artifact-write ungate

**Status**: ✅ LANDED

**(a)**: `42797ae` "fix(cycle-gate): ungate cycle-artifact-write — dissolve the transition deadlock" (2026-07-04)。
**(b)**: `scripts/cycle-gate.sh:38-39` "cycle-artifact-write → always green (never gated)"、`:95` で `observe|cycle-artifact-write)` が state/RPC 参照前に short-circuit。signature gate は `broadcast` (+ operator 判断で `cycle-aware-notify`) のみ (`:41-42`, `:92-93`)。
**(c)**: prep-cycle-anchor-recording.sh (deadlock hole-punch) は `155fb24` で **DEPRECATED banner** 付与済み (「cycle-4 (~2026-08-04) validates the gate fix in production; delete after」と削除条件明記) — stocktake の「retires prep-」は banner 付き猶予として整合。
**(d)**: cycle-gate suite 本日実行 = **20 PASS / 0 FAIL** (commit 時 29/29 → `2ae3519` の v1 test 削除後 20/20、いずれも 0 FAIL)。

### 3 — stranded auto-broadcast path retire

**Status**: ✅ LANDED (repo 側; host cron の live 状態は UNVERIFIED)

**(a)**: `2ae3519` "retire v1 post-anchor broadcast path; resume → v2 (④)"、`a0c2a2a` (TOOLKIT から deleted row 除去)。
**(b)**: `scripts/post-anchor-event.sh` = **tree に不在** (物理削除)。`scripts/resume-after-cycle-start.sh:32-35` = Phase 1 verify / Phase 2 state write / Phase 3 report のみ、v1 Phase 3 (broadcast trigger)・Phase 4 (`fyid1:` field-match) 削除をヘッダ L14-16 で明記。`scripts/watch-anchor-events.sh:79` の DRIVER default = `notify-anchor-transition.sh` (alert-only)。`run-anchor-pipeline.sh` は残置だが convergence design (`docs/superpowers/specs/2026-07-06-anchor-v2-convergence-design.md:60`) の判断どおり「正しい v2 orchestrator」であり、host 側起動は項目 6 の signer exit 7 assertion で fail-closed。
**(c)**: `git grep post-anchor-event` の非-retired hit は歴史 doc (CYCLE_GATE_DAILY_OBSERVATION.md = append-only 観測 log、CYCLE_GATE_IMPLEMENTATION_AUDIT.md 等の監査記録) と F4 の runbook banner のみ。runbook 側は項目 8 で計上。
**(d)**: cycle-gate 20/20 PASS (T14 が resume --apply の v2 state write を assert、commit message + 実 suite 実行で確認)。

**UNVERIFIED**: validator host の live cron が実際に notify driver を指しているか (host 状態) は本監査では実測していない。

### 4 — push-to-xserver.sh dead reference fix

**Status**: ✅ LANDED

**(a)**: `155fb24` (2026-07-04) — 5 dangling callers を rename。
**(b)**: `scripts/push-to-xserver.sh` = 不在 (ls 実測 "No such file or directory")、`scripts/push-to-web-host.sh` = 実在。stocktake が挙げた 4 caller (prep- / check-anchor-publish-health / install-xserver-anchor-source-allowlist / install-metal-anchor-publish-health-cron) すべて修正済み。
**(c)**: `git grep push-to-xserver` の残 hit は `scripts/install-repoint-publish-crons.sh` (`OLD_NAME="push-to-xserver.sh"` = 旧名を repoint する installer 本来の目的で意図的) とその test、TOOLKIT 記載、propagation design doc の経緯記述のみ。dead reference 0。
**(d)**: repoint installer test は tests/install-repoint-publish-crons/ に実在 (項目 11 参照)。

### 5 — identity-artifact propagation gap

**Status**: 🟡 PARTIAL

**(a)**: 設計 `c4c86ab` (approach C) + 計画 `9af3b6b` → 実装 `580edf0` (feed-excludes 単一 SoT + emitter)、`ce09ce0` (両 rsync shape test)、`7c96709` (public Xserver を第二 rsync target 化)、`458ea18` (rrsync 制限 deploy-key installer + test)、`c716778` (two-host deploy doc)、`7d9f9c4` (secrets 未設定時 graceful skip)。復旧系 `f0b535d`/`22f8656` (placeholder path 事故 fix)。
**(b)**: `.github/workflows/deploy.yml:136-200` に validator-host rsync + Xserver rsync の 2 target、共通 `scripts/deploy/build-rsync-excludes.sh` 実在。identity artifacts (`identity.json`/`identity.json.sig`/`identity-history.jsonl`) は feed-excludes に **含まれない** = git-deploy-only ✓ (`docs/DEPLOY_OWNERSHIP_MATRIX.md:30-31` とも整合)。resume の local-Caddy workaround = `git grep -i caddy` で resume/関連 script に 0 hit (deploy.yml の Caddy 記述は validator-host の通常 container 運用で無関係) ✓。identity.json polling loop は廃止、resume は sig gate のための単発 fetch (`resume:208-209`) に縮退 ✓。
**(c) 未解消**: F1 のとおり `anchor-source.json` feed 経路が repo 側で矛盾 (push script allowlist 0 件 vs health-check:71 / DEPLOY_OWNERSHIP_MATRIX:26 / feed-excludes / resume poll:173-180)。`git log -S 'anchor-source.json' -- scripts/push-to-web-host.sh` = 空 (一度も allowlist に入った履歴なし = pre-existing、範囲内 REGRESSED ではない)。
**(d)**: tests/deploy/ の emitter test 実在 (`580edf0`/`ce09ce0` で追加)。

**UNVERIFIED**: GitHub secrets `XSERVER_SSH_*` の設定有無、公開 Xserver への実配信、host 側 cron/wrapper allowlist の live 状態。

**Suggested fix (指摘のみ)**: `push-to-web-host.sh` の allowlist に `anchor-source.json` (+ `.sig`) を追加し Xserver forced-command 側 allowlist と両輪で揃える、**または** anchor-source を git-deploy 側に寄せて feed-excludes / health-check / ownership matrix / resume poll を一貫化する。どちらに寄せるかは operator 判断。

### 6 — gen-identity ordering guard + signing-host assertion

**Status**: ✅ LANDED

**(a)**: `5e73afe` (2026-07-06)。
**(b)**: (A) `scripts/operator-local/gen-identity.sh:442-449` — `FY_EXPECT_CYCLE` 設定時に live ledger の最新 cycle_n 不一致で **exit 7** hard-stop、一致時 "ordering guard: cycle-history is fresh" print。(B) `scripts/sign-anchor-event.sh:312-324` — "signing-host assertion (design-stocktake #6)" block、`command -v proton` 不在で **exit 7** (exit code 表 L47 にも記載)。
**(c)**: 残骸なし (新規追加項目)。
**(d)**: guard 自体の負系 test は無い (項目 7 で計上)。gen-identity suite 21 OK / 0 FAIL、sign-anchor-event suite 19 PASS / 0 FAIL は既存経路の非破壊を確認。

### 7 — e2e runbook integration test + dag-reconciliation test + signing-host-negative test

**Status**: 🟡 PARTIAL

**(a)**: `963cc66` + `11e9d46` — tests/anchor-pipeline/test-run-anchor-pipeline.sh (9 scenario / 26 assertion)。
**(b)(d) 実測 pass count** (本日全実行):
- tests/anchor-pipeline: **PASS=26 / FAIL=0** (happy path、arg forwarding、step 失敗時の exit 11-14 + 後続 step 非起動)
- tests/cycle-gate: **20 PASS / 0 FAIL** (T14 = resume --apply v2 state write、`2ae3519` で v2 retarget 済)
- tests/sign-anchor-event: **PASS=19 / FAIL=0** — うち bad-dag scenario (`test-sign-anchor-event.sh:35-39`、`dag_root_computed` を wrong 64-hex に改竄して reject を assert) が source 内 dag 整合の負系。receipt 側は `scripts/gen-anchor-receipt.sh` gate 6 (L220、`dag_root_summary == sha256(id||ob||ar)`) が cross-artifact 整合を enforce。項目 1 の collapse により identity 脚の reconciliation は対象消滅。
- scripts/operator-local/test-gen-identity.sh: **21 OK / 0 FAIL**
**(c) 欠落 (実測)**: signing-host-negative test = `git grep 'exit 7'`/`-eq 7` が tests/sign-anchor-event/・tests/anchor-pipeline/ で **0 hit**。ordering-guard test = `git grep FY_EXPECT_CYCLE -- tests scripts/operator-local` の hit は gen-identity.sh 本体のみ (**test 側 0 件**)。stocktake #7 が名指しした「signing-host-negative test」は未着地。

**Suggested fix (指摘のみ)**: PATH から proton を外した環境で sign-anchor-event が exit 7 することと、stale ledger + `FY_EXPECT_CYCLE` で gen-identity が exit 7 することを assert する 2 本の負系 test 追加。

### 8 — CYCLE_GATE.md + anchor runbook の Mac-sign model rewrite

**Status**: 🟡 PARTIAL

**(a)**: `a04c003` "rewrite CYCLE_GATE.md to the live v2 model" + lever 訂正 3 連 (`3681e32`, `68a755e`, `7650a27`)。周辺 doc: `72148f8` (MERKLE_DAG_SPEC v2 化)、`f2e9b17` (IDENTITY_VERIFICATION recipe v2 化)、`a568b93` (ownership 登録 + stale 参照 fix)、`36974a3` (公開 verify/selection-evidence page v2 化)、`2cec869` (③④ design)。
**(b)**: `docs/CYCLE_GATE.md:3-11` header が v2 rewrite を宣言 (「resume-after-cycle-start.sh that **no longer broadcasts**」、v1 の retirement 経緯と stocktake 参照付き)、`:172` で v1 Phase 3/4 の除去を明記。✓
**(c) 未達**: F4 — `docs/OPERATOR_IDENTITY_SETUP.md:14-21` banner が削除済み `post-anchor-event.sh` + `fyid1:` memo を現行 inscription 経路として案内 (L544, L757, L911-917 に fyid1 手順も現存)。`docs/PHASE5_CHECKLIST.md:106-107`、`docs/PHASE_ALPHA_TESTNET_DRY_RUN.md` (fyid1 リハーサル手順) にも retirement banner なし。なお `a568b93` の commit message は「gen-identity 出力 block・Phase 3/4・post-anchor recovery の doc section は ①④ の code retirement 後に rewrite する (They follow the ④ pass)」と明示予告していたが、④ (`2ae3519`) 着地後にこれら runbook への追補 commit は範囲内に見当たらない。
**(d)**: N/A (doc 項目)。

**Suggested fix (指摘のみ)**: OPERATOR_IDENTITY_SETUP.md / PHASE5_CHECKLIST.md / PHASE_ALPHA_TESTNET_DRY_RUN.md の該当 section に v2 retirement banner を付す (MERKLE_DAG_SPEC.md:7 と同形式)。

### 9 — TOOLKIT.md 25 missing scripts

**Status**: ✅ LANDED

**(a)**: `d55ab04` "catalog the 25 missing anchor + cycle-gate scripts" + `33ec147` (operator-local を catalog scope 外と明文化、TOOLKIT.md:12 実在) + `a0c2a2a` (deleted script row 除去)。
**(b)(c) 双方向 sweep 実測**: `for f in scripts/*.sh` → TOOLKIT.md 不記載 = **0 件**。scripts/operator-local/*.sh の 2 件は TOOLKIT.md:12 の明示 scope-out で正当。逆方向 (TOOLKIT 記載で実 file 不在) は `a0c2a2a` が post-anchor-event row を除去済み、`git grep push-to-xserver TOOLKIT.md` の hit は repoint installer の説明文のみ。
**(d)**: N/A (doc 項目)。

### 10 — gitleaks hit clear

**Status**: ✅ LANDED

**(a)**: `9846eb9` "allowlist regenerated cycle-gate test key in gitleaks" (`.gitleaks.toml` +6 / `.gitignore` +4)。
**(b)(d) 本日実測**: `gitleaks detect --no-git` (2026-07-07 12:22 JST、working tree 全 scan 6.67 MB) = **"no leaks found" (0 hit)**。stocktake D3 の UNVERIFIED 1 hit は解消確認。

### 11 — minor (`~5 min` marker、prep-/preview-/install- の test or one-shot mark)

**Status**: 🟡 PARTIAL

- `~5 min` marker: `scripts/preview-cycle3-anchor-broadcast.sh:73` に `# gate-2, valid ~5 min from now` が**現存** (実測 1 hit) — この sub-item は未着地。
- prep-: `155fb24` で DEPRECATED banner + 削除期日 (cycle-4 後) を明記 = mark 済み ✓。test はなし (deprecated につき妥当)。
- preview-: header (L1-13) に「BROADCASTS NOTHING / STAGE 1 / cycle-3 専用」の性格記述はあるが、test なし・明示的 one-shot mark なし。
- install-: 範囲内で installer test が 4 系統追加 — tests/install-repoint-publish-crons/ (`0e4c1d4` 系)、tests/install-cron-env-headers/ (`fdaa179`/`533a4ff`)、tests/install-xserver-static-deploy-key/ (`458ea18`)、tests/host-drift/test-install-metal-host-drift-cron.sh (`ba7f86c`) — 部分的に前進 ✓。ただし install-xserver-anchor-source-allowlist.sh / install-metal-anchor-publish-health-cron.sh 等は test も one-shot mark もなし。

## Statistics

- Dimensions checked: 11 / 11 (skip なし)
- LANDED: 6 (項目 2, 3, 4, 6, 9, 10)
- PARTIAL: 5 (項目 1, 5, 7, 8, 11)
- OPEN: 0 / REGRESSED: 0
- Test suites executed: 4 (anchor-pipeline 26/26、cycle-gate 20/20、sign-anchor-event 19/19、gen-identity 21 OK/0 FAIL) — 全 0 FAIL
- gitleaks: 0 hit (本日実測)
- UNVERIFIED (host 側 live 状態のため本監査では実測せず): validator host cron の実 driver 指し先、GitHub secrets `XSERVER_SSH_*` 設定有無、公開 Xserver への実配信結果、Xserver forced-command wrapper allowlist の実内容

## Auditor note

- Fabrication: 0 件 (全 finding は git show / git grep / grep -c / ls / test 実実行の出力に基づく)
- 越権実装: 0 件 (本 report file の新規作成のみ、他 file 無変更)
- Numeric claim: 全て書く直前に実測 capture (「~」「約」不使用; 引用中の `~5 min` は被監査対象の原文)
- Append-only: この report は新規 file、既存 audit doc 未 touch。docs/audits/ 配下の untracked file にも未接触
- Secret/host identifier: 実 IP・SSH key 名・secret 値の literal 記載なし

> **operator へ**: この report の各 finding は `superpowers:receiving-code-review` の手続きに従い、technical rigor で独立 verify してください。特に F1 (anchor-source.json publish 経路の repo 側矛盾) は resume Phase 1 の poll と health-check auto-recover の実運用に関わるため、host 側 live 状態 (UNVERIFIED 群) と突き合わせての判断を推奨します。
