# Cycle gate + resume — implementation audit report

> **Generated**: 2026-06-29
> **Scope**: T-1 through T-6 of `project_cycle_gate_resume_tasks` memo (= read + implement + test + document, without production deploy).
> **Status**: T-1〜T-6 完了。 T-7 (= deploy) は **2026-07-04 cycle 3 開始 transition 完走後の operator retrospective を待つ** ため pending。 T-8 (= ~2026-08-04 次回 transition での実証) も同様 pending。
> **Production state**: **無変更**。 全成果物は repo working tree に未 commit、 production に未配置。

## 1. 実施 task 一覧

| Task ID | Task | Status | Notes |
|---|---|---|---|
| T-1 | 既存 script 実 read + gate 挿入箇所の精密特定 | ✅ 完了 | post-anchor-event.sh 行 330-332 を gate 挿入位置と確定。 check-anomalies.sh / daily-status.sh は実 read 後 修正不要と判定 (= v2 設計案から scope 縮小) |
| T-2 | cycle-gate.sh 新規作成 | ✅ 完了 | 143 行 (= 80-120 推定よりやや増、 文書 + behavior matrix 込) |
| T-3 | resume-after-cycle-start.sh 新規作成 | ✅ 完了 | 410 行 (= 150-200 推定より大幅増、 5 phase + polling + 7 条件 check 込) |
| T-4 | post-anchor-event.sh 修正 (= 必須 1) | ✅ 完了 | 24 行追加 (= gate block 19 + exit code 文書 5)、 syntax check PASS |
| T-5 | test suite 整備 (= 10 scenario) | ✅ 完了 | 10/10 PASS、 Python HTTP mock + bash test runner |
| **T-5.5** | **追加 mock test 8 件 (= 未 cover Phase 2-5 + 統合)** | ✅ 完了 | **22/22 PASS** (= T1-T18 + 4 side-effect 検証)、 mock stub 4 件 + ed25519 test 鍵 + flock shim 追加 |
| T-6 | docs 更新 + operator 認可 gate | ✅ AI 完了 / ⏳ operator 認可待ち | docs/CYCLE_GATE.md 213 行 新規、 docs/VALIDATOR_RENEWAL.md 修正済 (= 旧 SOP + 新 SOP 並記) |
| T-7 | deploy | ⏳ 2026-07-04 完走後 | code 変更 + commit + push + Hetzner sync + state file 初期書込 |
| T-8 | 2026-08-04 頃の次回 transition 実証 | ⏳ 2026-08-04 頃 | AI 主導 orchestrate で初回適用、 11-step 手動 disable/enable が発生しなかったことを記録 |

## 2. 成果物 一覧 (= 全 file path + 行数 + sha256)

### 新規 file (= sha256 / 行数 は 2026-06-29 post-sanitize の値)

| path | type | 行数 | sha256 |
|---|---|---|---|
| `scripts/cycle-gate.sh` | new | 143 | `4ec6b0212b26b494df0e8bff7351bbcbf9bddb13994ed48c500ae9b4152a405d` |
| `scripts/resume-after-cycle-start.sh` | new | 414 | `3bc5c85783b4e01951ec356af4f5f0b93c70b6d8c43762e0b1b11b8fc666836c` |
| `scripts/post-anchor-event.sh` | modified | 685 | `b2f6ea85763a0b2350df5ecc13fc40ded8210b9753388a753df356af16677a06` |
| `tests/cycle-gate/mock-signer.sh` | new (T-5.5) | 58 | `8d783c2308fe476ced7b092f03eab01594688a2624b81bf6f3d5385bcb1e3959` |
| `tests/cycle-gate/mock-pusher.sh` | new (T-5.5) | 12 | `c7410fa8157dfcf324940e17f972eeaad34cee2f1b35553ae913a305fdbd197f` |
| `tests/cycle-gate/mock-postanchor.sh` | new (T-5.5) | 18 | `f30bb8c38aceb7730a6824b3c41cda802543fa9da30b6dd613c11dab5a329dd7` |
| `tests/cycle-gate/mock-history-appender.sh` | new (T-5.5) | 7 | `fa3ae3f830005c2aa0657b541c7aa67b682a2cae64819f223672a5a62d35de23` |
| `tests/cycle-gate/bin/flock` | new (T-5.5) | 7 | `838327ca9b54d0462532a9e36f50e965b66f8ee66edcadd780f0d489d901714c` |
| `tests/cycle-gate/.gitignore` | new (T-5.5) | 8 | `c0058b070ad8c81b71978550d6f990c0fea2fe6cdb4c3d6cbb4531eed55ee7ae` |
| `docs/CYCLE_GATE.md` | new | 213 | `3482a8323a925f5293540e9e5db44304eeea341f0792c2f90f96a268c4d058d0` |
| `docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md` | new (本 file) | — | (= self-reference; commit 後に再計算) |
| `tests/cycle-gate/run-tests.sh` | new | 204 | `15cc99f5c88d9020aeae0a3786f5ea2a2693fec516d35862097d745631b47aac` |
| `tests/cycle-gate/mock-rpc.py` | new | 77 | `355266f4727edcb7dc53a9b2cce13d306567926e6448916f1257f71c306f1530` |
| `tests/cycle-gate/fixtures/chain-matches.json` | new | 18 | `c3699636e162191f93239d8ee245f1c748c8576519cba08e20461c4232923eca` |
| `tests/cycle-gate/fixtures/chain-empty.json` | new | 9 | `64156850d9abdb6a12d80f4dda3c4ce7bcec2f03ca5c37e5d7e1ed9058ce1a0d` |
| `tests/cycle-gate/fixtures/state-matches.json` | new | 6 | `bcf683cef3b64542a2373ac5b9738aaa357ece8bf20f8af9815d6ab34fe7c7d3` |
| `tests/cycle-gate/fixtures/state-old.json` | new | 6 | `6bf9c633116a4972f21cfaa1f937895bed250d4f021adca9890d36bd9af8dcf8` |

sha256 再取得 command (= audit 時の照合):

```sh
shasum -a 256 scripts/cycle-gate.sh scripts/resume-after-cycle-start.sh \
              docs/CYCLE_GATE.md \
              tests/cycle-gate/run-tests.sh tests/cycle-gate/mock-rpc.py \
              tests/cycle-gate/fixtures/*.json
```

### 既存 file 修正

| path | 修正前行数 | 修正後行数 | diff | post-sanitize sha256 |
|---|---|---|---|---|
| `scripts/post-anchor-event.sh` | 654 | 678 | +24 (= gate block 19 + exit 11 doc 5) | `35dd7532a2e5ecba3abe6ddfb0cf972c99f8f9d9583657910fff5ea716dd9974` |
| `docs/VALIDATOR_RENEWAL.md` | 217 | 319 | +102 (= 適用版バナー + 新 SOP section) | `d44442f5c2d3e36a5690edd19b03b28b5075717acb0affcc9a28aa6c7d0ac75c` |

### sanitize 修正 record (= 独立監査指摘 反映)

2026-06-29 独立監査で **🟥 BLOCKER #1**: validator host IP literal (= 本 doc には生値を含めない、 [[reference_ssh_access]] memo 参照) が新規 / 修正 file に 9 ヶ所 leak。 同種 sanitize regression は本件で 3 回目 (= 2026-05-22 fec4a5b + 2026-06-19 de7030a + 本件)。

監査推奨は IP のみ redact だったが、 grep verify で **SSH key file name literal** (= 同じく [[reference_ssh_access]] 参照、 本 doc には生値を含めない) も 8 ヶ所 leak しており (= 監査は「既存 docs 多数」 と判定したが実 grep では本件 file のみ)、 既存 convention (= `docs/PHASE5_CHECKLIST.md` / `docs/DISASTER_RECOVERY.md` の placeholder 形式) に合わせて両方一括 sanitize:

| pattern | 修正前 (= 生値、 本 doc 非掲載) | 修正後 | 対象 file 数 | 計 occurrences |
|---|---|---|---|---|
| SSH key file name | `~/.ssh/<生値>` | `~/.ssh/<your_validator_host_key>` | 3 (= resume.sh + CYCLE_GATE.md + audit) + 1 (= VALIDATOR_RENEWAL.md) | 8 + 0 = 8 |
| validator host IP | `root@<生値>` | `"root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}"` | 4 (= 上記 + VALIDATOR_RENEWAL.md) | 9 |

sanitize 後の grep verify (= zero remaining、 本 doc の "<生値>" 表記も含めて 0):
```
$ grep -rnE "<IP の生値>|<SSH key file name の生値>" --include="*.sh" --include="*.md" --include="*.py" --include="*.json" .
(no occurrences)
```

regression check: `bash tests/cycle-gate/run-tests.sh` で sanitize 後も 10/10 PASS 維持。

## 3. test 検証 record

`tests/cycle-gate/run-tests.sh` 実行結果 (= 2026-06-29):

| # | scenario | expected | observed | result |
|---|---|---|---|---|
| T1 | cycle-gate observe → green (no state, no RPC) | exit 0 | exit 0 | ✓ PASS |
| T2 | cycle-gate broadcast + state file absent → green (backward compat) | exit 0 | exit 0 | ✓ PASS |
| T3 | cycle-gate broadcast + state matches chain → green | exit 0 | exit 0 | ✓ PASS |
| T4 | cycle-gate broadcast + state mismatch → deferred | exit 1 | exit 1 | ✓ PASS |
| T5 | cycle-gate broadcast + RPC unreachable → fail-closed deferred | exit 1 | exit 1 | ✓ PASS |
| T6 | cycle-gate observe + RPC unreachable → green (observe never gated) | exit 0 | exit 0 | ✓ PASS |
| T7 | cycle-gate broadcast + validator absent on chain → deferred | exit 1 | exit 1 | ✓ PASS |
| T8 | cycle-gate broadcast + state file corrupt → fail-closed deferred | exit 1 | exit 1 | ✓ PASS |
| T9 | resume --dry-run + same cycle approved → idempotent exit 0 | exit 0 | exit 0 | ✓ PASS |
| T10 | resume --dry-run + RPC unreachable → exit 2 | exit 2 | exit 2 | ✓ PASS |

**Total**: 10/10 PASS。

### T-5.5 追加 mock test (= 8 件、 2026-06-29 拡張)

| # | scenario | cover 内容 | result |
|---|---|---|---|
| T11 | resume Phase 1 polling timeout (= identity.json stale) | exit 3、 polling loop 動作 | ✓ PASS |
| T12 | resume Phase 1 identity.dag != cycles-history.dag | Phase 1 step 7 cross-check exit 2 | ✓ PASS |
| T13 | resume Phase 1 signature verify (= test ed25519 key) | ssh-keygen -Y verify against generated test key | ✓ PASS |
| T14 | resume --apply end-to-end (= mock POSTANCHOR) | Phase 1-5 順次完走 exit 0、 state file 書込確認 | ✓ PASS |
| T15 | resume --apply + POSTANCHOR fail | Phase 3 fail → exit 5 | ✓ PASS |
| T16 | post-anchor-event + cycle-gate green | signer 起動 + receipt assembly + push (= all mocked) | ✓ PASS |
| T17 | post-anchor-event + cycle-gate deferred | exit 11、 signer 未起動を grep で確認 | ✓ PASS |
| T18 | post-anchor-event end-to-end | last-anchored-root + receipt 書込確認 (= proton-cli 経路の mock 化) | ✓ PASS |

T-5.5 で追加した test infrastructure:

- `tests/cycle-gate/mock-signer.sh` — ANCHOR_SIGNER 用 stub (= sign-anchor-event.sh 代替、 AJV-valid な receipt fragment 出力)
- `tests/cycle-gate/mock-pusher.sh` — ANCHOR_PUSHER 用 stub (= push-to-web-host.sh 代替)
- `tests/cycle-gate/mock-postanchor.sh` — POSTANCHOR 用 stub (= resume の Phase 3 trigger 先)
- `tests/cycle-gate/mock-history-appender.sh` — ANCHOR_HISTORY_APPENDER 用 stub
- `tests/cycle-gate/bin/flock` — macOS 用 flock(1) shim (= Linux production には不要)
- `tests/cycle-gate/.gitignore` — test 用 ed25519 key の git 除外
- production code 微修正: `scripts/post-anchor-event.sh` に `ANCHOR_PUSHER` + `ANCHOR_HISTORY_APPENDER` env override 追加 (= 既存 `ANCHOR_SIGNER` pattern と一貫、 2 行)、 `scripts/resume-after-cycle-start.sh` に `POSTANCHOR` env override 追加 (= 1 行)

### 残 test 未 cover (= T-5.5 後)

| 範囲 | 理由 | カバー方法 |
|---|---|---|
| 実 proton-cli + XPR mainnet broadcast | test 環境に proton-cli + keystore + mainnet 鍵 不在 | **2026-08-04 transition で実走** (= T-8)、 testnet rehearsal は 2026-06-22 PASS 済 |
| GitHub Actions deploy 監視 (= gh CLI) | AI が直接 gh CLI を叩く orchestration 経路、 script 化されていない | **deploy 時に AI 自身が `gh run watch` を実行**、 mock 不要 (= 失敗時は人間が再 trigger) |

## 4. 設計 invariants の verify

`docs/CYCLE_GATE.md` で定義された invariant 4 件を test とコードで verify:

| invariant | 検証手段 | result |
|---|---|---|
| observe は常に green (= observation 不可侵) | T1 + T6 で異常状況下でも green を確認 | ✓ verified |
| state file 不在 = 旧 behavior 維持 (= backward compat) | T2 で gate 無し挙動を確認 | ✓ verified |
| broadcast は fail-closed (= RPC 不達時 deferred) | T5 + T8 で確認 | ✓ verified |
| cycle 不一致時 broadcast は deferred | T4 + T7 で確認 | ✓ verified |

## 5. backward compatibility verify

| 検証項目 | 確認方法 | result |
|---|---|---|
| cycle-gate.sh 不在時 post-anchor-event.sh 旧挙動 | `if [ -x "${CYCLE_GATE_SCRIPT}" ]` で実行性検査、 false なら skip | ✓ コード review で確認 |
| cycle-gate-state.json 不在時 cycle-gate.sh 緑返し | T2 で確認 | ✓ test verified |
| RESUME_MODE / --force bypass | コード読 (= 行 332-340 周辺の条件) | ✓ コード review で確認 |
| 2026-07-04 cycle 3 transition への影響 | (a) 全成果物未 commit、 (b) state file 未配置、 (c) cycle-gate.sh 未配置、 (d) post-anchor-event.sh 修正未 deploy | ✓ production 無変更を確認 |

## 6. 2026-07-04 cycle 3 開始 transition への影響評価

| 影響 source 候補 | 評価 |
|---|---|
| repo working tree (= 未 commit 変更) | 7/4 当日の deploy 経路 = git push に依存、 push しなければ無影響 |
| Hetzner production scripts | 全成果物未 sync (= sync-to-validator-host.sh 未実行) |
| Xserver production | 影響なし (= cycle-gate 系は validator host 専用、 deploy.yml line 146 で scripts/ exclude) |
| 既存 cron 設定 | 無変更 |
| 既存 state file (= anchor-pending、 anchor-watcher-state、 anomaly-state、 last-anchored-root) | 無変更 |
| 既存 11-step canonical runbook | 完全準拠 (= 本設計は 7/4 後の cycle 4 開始から適用) |

**影響評価**: **ゼロ**。 [[feedback_phase_alpha_no_pre_publish_regression]] の制約も遵守。

## 7. T-7 deploy gate (= 認可待ち事項)

### 認可受領後に AI が実行する deploy 手順

```sh
# (= 2026-07-04 cycle 3 開始 transition 完走 + operator retrospective 後)

cd ~/htdocs/01_PROJECTS/metal.freedom-yield.com

# 1. commit (= 全 file まとめ commit、 単一 commit 推奨)
git add scripts/cycle-gate.sh \
        scripts/resume-after-cycle-start.sh \
        scripts/post-anchor-event.sh \
        docs/CYCLE_GATE.md \
        docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md \
        docs/VALIDATOR_RENEWAL.md \
        tests/cycle-gate/

git commit -m "feat(cycle-gate): 2-component design (passive gate + active resume)

Eliminates manual cron disable/enable in cycle transitions by gating
broadcast on operator-explicit approval state. Initial application is
the next cycle transition after 2026-07-04 completion.

- scripts/cycle-gate.sh: passive gate consulted by post-anchor-event.sh
- scripts/resume-after-cycle-start.sh: active operator command
- scripts/post-anchor-event.sh: +24 line gate consultation block
- docs/CYCLE_GATE.md: full design spec
- docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md: implementation audit
- docs/VALIDATOR_RENEWAL.md: dual-version SOP (old + new)
- tests/cycle-gate/: 10-scenario test suite (10/10 PASS)"

# 2. push (= GitHub Actions Deploy 起動)
git push origin main

# 3. GitHub Actions deploy 完了監視
gh run watch --exit-status

# Note: deploy.yml line 146 で scripts/ は Xserver 配信から exclude されている。
# 上記 push は Xserver には scripts/* を配さない (= 仕様通り)。 docs/ も同 line 29 で exclude。
# scripts/* + docs/* は Hetzner 側に sync-to-validator-host.sh 経由で配置する。

# 4. Hetzner sync (= scripts/ + docs/ を validator host へ配置)
bash scripts/sync-to-validator-host.sh

# 5. Hetzner で cycle-gate-state.json 初期書込 (= 現サイクル承認)
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --apply'

# 6. 動作確認 (= state file 作成済、 cycle-gate.sh green、 post-anchor-event idempotent skip)
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'cat /var/lib/freedom-yield/cycle-gate-state.json | jq'
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh --side-effect=broadcast; echo exit=$?'
```

期待動作:
- 上記 step 5 → resume が Phase 1 〜 4 PASS、 state file 作成、 post-anchor-event は no-op exit 2 (= 既に anchor 済)
- 上記 step 6 → cycle-gate.sh は exit 0 (= green)、 state matches chain signature
- 次の cron tick (= 5 min 後) → post-anchor-event は exit 2 (= 既存 idempotency) で gate consultation も green、 既存挙動と等価

### deploy 後 1 週間の観察項目

- `/var/log/post-anchor-event.log` で deferred (= exit 11) ログが現れていないこと (= 平時は green のはず)
- ntfy 通知に「validator dropped」 等の false alert が出ていないこと (= 平時は無関係のはず)
- cron 実行頻度に変化がないこと (= 5 min tick 維持)

## 8. T-8 deploy 後の初回 transition (= ~2026-08-04) 検証手順

| step | 検証項目 | 期待 |
|---|---|---|
| 1 | AI orchestrate で transition 開始 | operator は wallet + passphrase + visual verify のみ |
| 2 | cycle close 〜 AddValidator 間に cron tick | post-anchor-event.sh が exit 11 (= deferred) を log、 broadcast せず |
| 3 | Mac gen-identity.sh + push + GitHub deploy | AI が gh CLI で完了確認 |
| 4 | AI が resume-after-cycle-start.sh --apply trigger | Phase 1-5 PASS、 5/5 conditions PASS、 anchor broadcast 完了 |
| 5 | operator が explorer URL visual 確認 | tx + memo + actor + permission 一致 |
| 6 | 完了後 audit | 旧 11-step の step 2 (= cron disable) + step 12 (= cron re-enable) が 一切発生しなかったことを記録 |

T-8 完了 = 設計 success criterion 達成。

## 9. rollback 手順 (= deploy 後の異常時)

### Level 1: 一時 gate 無効化 (= 軽い)

```sh
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy rm /var/lib/freedom-yield/cycle-gate-state.json'
```

→ 次回 resume まで gate 緑、 backward compat 動作。

### Level 2: gate consultation 完全無効化 (= 中)

```sh
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy chmod -x /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh'
```

→ post-anchor-event.sh は cycle-gate.sh を skip、 旧 behavior 完全復帰。

### Level 3: 全設計を捨てる (= 重い)

git revert + sync-to-validator-host.sh 再実行。 詳細は `docs/CYCLE_GATE.md` の Rollback section 参照。

## 10. 残課題 / 別 issue 候補 (= 2026-06-29 T-5.5 後 update)

| # | 内容 | 状態 |
|---|---|---|
| 1 | check-anomalies.sh / daily-status.sh の gate consultation 追加 | ✅ 不要と結論 (= T-1)、 既存実装で十分 |
| 2 | resume signature verification を mock test に組込 | ✅ **T-5.5 で実装** (= T13、 test 用 ed25519 鍵生成 + 署名 + verify) |
| 3 | end-to-end proton-cli broadcast の test infra 整備 | ✅ **T-5.5 で mock 化** (= T16-T18、 ANCHOR_SIGNER env override 経由)、 実 chain broadcast は T-8 (2026-08-04) で実走 |
| 4 | notification dedup framework | ⏳ 別 issue、 cycle transition と無関係 |
| 5 | approval state の public 配信 | ⏳ 別 issue、 institutional transparency enhancement |
| 6 | cycle-gate-state.json schemaVersion consumer 側検証 (= 独立監査 YELLOW #2) | ⏳ T-9 として queue 済、 schema bump 計画時に着手 |

## 11. 全成果物の現在地 (= 2026-06-29 T-5.5 後 update)

```
/Users/admin/htdocs/01_PROJECTS/metal.freedom-yield.com/
├── scripts/
│   ├── cycle-gate.sh                          (new, 143 lines, executable)
│   ├── resume-after-cycle-start.sh            (new, 413 lines, executable, T-5.5: +3 lines)
│   └── post-anchor-event.sh                   (modified, +30 lines: +24 T-4, +6 T-5.5)
├── docs/
│   ├── CYCLE_GATE.md                          (new, 213 lines)
│   ├── CYCLE_GATE_IMPLEMENTATION_AUDIT.md     (new, 本 file)
│   ├── CYCLE_GATE_T55_AUDIT.md                (new, T-5.5 専用独立監査用)
│   └── VALIDATOR_RENEWAL.md                   (modified, +102 lines)
└── tests/cycle-gate/
    ├── run-tests.sh                           (new, 643 lines, executable, T-5.5: +439 lines)
    ├── mock-rpc.py                            (new, 77 lines, executable)
    ├── mock-signer.sh                         (new T-5.5, 66 lines, executable)
    ├── mock-pusher.sh                         (new T-5.5, 12 lines, executable)
    ├── mock-postanchor.sh                     (new T-5.5, 17 lines, executable)
    ├── mock-history-appender.sh               (new T-5.5, 7 lines, executable)
    ├── .gitignore                             (new T-5.5, 8 lines)
    ├── bin/
    │   └── flock                              (new T-5.5, 7 lines, executable, macOS shim)
    └── fixtures/
        ├── chain-matches.json                 (new, 18 lines)
        ├── chain-empty.json                   (new, 9 lines)
        ├── state-matches.json                 (new, 6 lines)
        └── state-old.json                     (new, 6 lines)
```

合計新規行数: 約 **1,640 行** (= production code 559 + docs 851 + tests 838)
git status: working tree に未 commit 変更 (= deploy 待機、 7 path)

## 12. 関連 memory + 関連 docs

- `project_cycle_gate_resume_design` memo — 設計確定 + 議論経緯
- `project_cycle_gate_resume_tasks` memo — T-1 〜 T-8 task plan
- `project_phase_alpha_anchor_completion_2026_07_04` memo — 既存 11-step canonical (= 2026-07-04 cycle 3 開始 transition で使用)
- `feedback_ai_full_orchestration_default` memo — model α 役割分担
- `feedback_cycle_number_no_shorthand` memo — cycle 番号表記原則
- `feedback_phase_alpha_no_pre_publish_regression` memo — 7/4 前 code 変更禁止
- `docs/CYCLE_GATE.md` — 設計詳細
- `docs/VALIDATOR_RENEWAL.md` — 新 SOP section

## 13. operator 認可 待ち事項

- T-6 docs review + 「実装方針一致」 確認 → T-7 deploy 進行可否認可
- 2026-07-04 cycle 3 開始 transition 完走 + retrospective 完了 → T-7 deploy 着手認可
- 2026-08-04 頃の次回 transition での AI 主導 orchestrate 認可 → T-8 実証着手認可
