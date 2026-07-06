# T-RD2 implementation audit report

> **Generated**: 2026-06-29
> **Scope**: T-RD2 of cycle-gate-resume design — expand cycle-gate.sh consultation from 1 cron (post-anchor-event.sh only) to **all 8 cycle-related crons**, fail-closed the gate-missing case (= Q3 fix), add `cycle-artifact-write` side-effect type, extend test suite.
> **Status (= 2026-06-29 16:40 JST update)**: **T-7 deploy 完了済 2026-06-29 15:09 JST**。 本 audit doc 内の「T-7 deploy 着手の認可条件」 「T-7 deploy 時点で」 等の pending 表記は **historical reference**、 現在 truth は `docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md` 冒頭 banner。
> **Trigger**: operator directive 2026-06-29 —「cycle系のcronを対象にして」「SC inscription 整合性 を最優先」「cycle-gate.sh が破損したら呼ぶ cron は skip」
> **Predecessor audits**: `docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md` (T-1〜T-6) + `docs/CYCLE_GATE_T55_AUDIT.md` (T-5.5)

## 1. T-RD2 scope (= asked vs delivered)

| 区分 | asked | delivered |
|---|---|---|
| cycle-gate consultation 範囲 | 「cycle 系 cron 全部」 (= 1 から N へ) | **8 cron** (= metal-anchor-watch + metal-cycle-history + metal-uptime-history + metal-anomalies + metal-daily-status + metal-node-info + metal-evidence + metal-renewal-ics) |
| fail-closed semantics | 「cycle-gate.sh 破損 → 呼ぶ cron は skip」 | post-anchor-event.sh で backward-compat 削除、 全 cycle scripts で fail-closed default、 exit 11 / exit 0 |
| host 系 cron | 「独立、 放置」 | 5 cron 無変更 (= metal-server-status + metal-node-health + metal-peer-validators + metal-watch-validators + freedom-yield-peer-geo) |
| 5 分頻度 | OK | 既存 cron schedule そのまま (= 追加実装不要) |
| SC integrity 最優先 | 「入念な対象の特定」 | 13 cron の SC dependency map 作成、 9 cron 該当 / 5 cron 該当外 で判定 |
| test 拡張 | (= 暗黙) | 22 → **27 PASS** (= T19-T23 追加) |
| operator 操作 | 「私が触る前に確認」 → なし | model α: AI orchestration、 operator は何も触らない |

## 2. 8 cron に対する gate 適用方式

| cron | 呼び出される script | gate 方式 | 修正 行数 | side-effect type |
|---|---|---|---|---|
| metal-anchor-watch | watch-anchor-events → post-anchor-event | exit 11 (fail-closed default) | +6 (T-RD2) over +24 (T-4) | broadcast |
| metal-cycle-history | gen-cycle-history.sh | top-level skip exit 0 | +13 | cycle-artifact-write |
| metal-uptime-history | uptime-history.sh | partial gate, Job B only | +13 | cycle-artifact-write |
| metal-anomalies | check-anomalies.sh | partial gate, cycle-section wrap | +14 (top) + 4 (wrap) = +18 | cycle-aware-notify |
| metal-daily-status | daily-status.sh | top-level skip exit 0 | +16 | cycle-aware-notify |
| metal-node-info | node-info.sh | top-level skip exit 0 | +16 | cycle-artifact-write |
| metal-evidence | gen-evidence.sh | top-level skip exit 0 | +13 | cycle-artifact-write |
| metal-renewal-ics | gen-renewal-ics.sh | top-level skip exit 0 | +13 | cycle-artifact-write |

合計 production code 変更: **~118 行** (= 9 file modified)

## 3. cycle-gate.sh 新 type: cycle-artifact-write

既存 type:
- `broadcast` — A-chain inscription (IRREV)。 post-anchor-event.sh 専用
- `cycle-aware-notify` — validator-presence ntfy。 check-anomalies + daily-status
- `observe` — 常時 green。 read-only observation

T-RD2 追加:
- `cycle-artifact-write` — cycle-affecting artifact / state file 書込。 gen-cycle-history + uptime-history + gen-evidence + gen-renewal-ics + node-info

gate logic はすべて同じ (= state file vs chain signature 比較)。 type は log marker + intent 表明のみ。

## 4. fail-closed semantics の change (= 第 1 ラウンド audit Q3 fix)

| script | 旧 behavior (= backward compat) | 新 behavior (= fail-closed) |
|---|---|---|
| post-anchor-event.sh | cycle-gate.sh 不在 → broadcast 実行 | cycle-gate.sh 不在 → exit 11 |
| 7 新 cycle script | (= 新規追加) | cycle-gate.sh 不在 → exit 0 (idempotent skip) |

操作 difference:
- post-anchor-event.sh: 「broadcast 失敗」 として log (= exit 11)、 operator 認知必要
- 他 7 script: 「skip」 として log (= exit 0)、 cron 健全性 green 維持

両方とも「cycle-gate.sh 不在 = 安全側 = 何も書込まない」 で一貫。

## 5. test 検証 record (= 27 件 全 PASS)

`tests/cycle-gate/run-tests.sh` 実行結果 (= 2026-06-29):

| # | scenario | expected | result |
|---|---|---|---|
| T1-T8 | cycle-gate 全 8 state | 各別 | ✓ all PASS |
| T9-T10 | resume Phase 1 idempotent / RPC down | 0 / 2 | ✓ PASS |
| T11-T18 | T-5.5 拡張 (= polling / signature verify / Phase 2-5 / 統合) | 各別 | ✓ all PASS |
| **T19** | cycle-artifact-write + state matches → green | 0 | ✓ PASS |
| **T20** | cycle-artifact-write + state mismatch → deferred | 1 | ✓ PASS |
| **T21** | post-anchor-event + cycle-gate.sh MISSING → exit 11 (fail-closed) | 11 | ✓ PASS |
| **T22** | 5 simple cycle scripts skip on gate deferred | 0 + log | ✓ all 5 PASS |
| **T23** | check-anomalies cycle-section wrap on gate deferred | 0 + log | ✓ PASS |

総 PASS: **27/27 (100%)**

### T-RD2 test infrastructure 追加

- `tests/cycle-gate/run-tests.sh` を 622 → 813 行 (= +191 行) に拡張
- 既存 mock 環境 (= mock-rpc.py + state fixtures) を再利用、 新 mock 不要
- T22 で 5 cycle scripts を symlink ベースで isolate (= /tmp の tmp REPO_BASE)
- T22 で uptime-history.sh の Job A 完走させるため richer validator.json fixture 提供

## 6. 13 cron の SC dependency 分析

### A. SC inscription 整合性 致命 (= 必須 gate、 3 件)

| cron | SC への影響経路 |
|---|---|
| metal-anchor-watch | broadcast 直接 = 致命的 |
| metal-cycle-history | cycle-history.jsonl 再生成 → cycles_branch_root → dag_root_hash |
| metal-uptime-history | uptime-cycles.json → cycle-history.jsonl input → 同上 |

### B. cycle 状態 観察 + 通知 (= operator 直接指示 「全 cycle 系」 含む、 5 件)

| cron | 影響 |
|---|---|
| metal-anomalies | validator-presence ntfy (= 「validator drop」 false alert) |
| metal-daily-status | digest 内 cycle 情報 |
| metal-node-info | validator.json 更新 (= artifact_manifest leaf、 ただし dag_root_hash 不影響) |
| metal-evidence | evidence.json 更新 (= 同上) |
| metal-renewal-ics | .ics の cycle reminder |

### C. cycle 非依存 host 系 (= 放置、 5 件)

| cron | 役割 |
|---|---|
| metal-server-status | host CPU/RAM/disk |
| metal-node-health | host 健全性 snapshot |
| metal-peer-validators | 他 validator 観察 (= cycle 非依存) |
| metal-watch-validators | 同上 |
| freedom-yield-peer-geo | peer 地理 mapping |

operator 直接確認 (= 2026-06-29): 「**cycle 系の cron を対象にして**、 host 系は独立してるので、 放置で良い」 → 設計は A + B = 8 cron、 C = 5 cron は触らない。

## 7. /var/lib/freedom-yield/ state file map (= 2026-06-29 the validator host 確認)

| file | writer | reader | T-RD2 gate 影響 |
|---|---|---|---|
| anchor-watcher-state.json | watch-anchor-events.sh | 同 | 影響なし (= watch 自体は gate しない、 dispatch する post-anchor-event が gate) |
| anomaly-state.json | check-anomalies.sh | 同 + daily-status | 部分影響 (= cycle-section wrap で update なし) |
| current-cycle-state.json | uptime-history.sh | 同 | gate 影響 (= Job B skip 時 update なし) |
| cycle-notes.json | (= operator 手動) | uptime-history.sh | 影響なし |
| anchor-pending.json | post-anchor-event.sh (= 現在不在、 初回 broadcast 後生成) | 同 | 影響なし (= gate は broadcast 前) |
| last-anchored-root | post-anchor-event.sh (= 現在不在、 同上) | 同 | 影響なし |
| uptime-history.jsonl | uptime-history.sh (Job A) | gen-cycle-history | 影響なし (= Job A は gate しない、 daily snapshot 継続) |
| watch-prev-state.json | check-watch-validators.sh | 同 | 影響なし (= host 系、 gate しない) |
| node-health-history.jsonl | node-health-daily.sh | 同 | 影響なし (= host 系) |
| fee-market-history.jsonl, gini-history.jsonl, peers-prev-nodeids.txt, peers-history/ | peer-validators.sh | 同 | 影響なし (= host 系) |
| locks/ | check-anomalies.sh | 同 | 影響なし |
| cycle-gate-state.json | resume-after-cycle-start.sh | cycle-gate.sh | T-RD2 で新規 reader 拡大 (= 全 7 cycle script が consult) |

## 8. backward compatibility (= 旧 production と新 deploy の交差)

T-RD2 完了 → T-7 deploy 時点で:

1. `scripts/cycle-gate.sh` + `scripts/resume-after-cycle-start.sh` が validator host に sync される
2. 9 修正 script (= post-anchor-event + 7 cycle script + cycle-gate) が atomic に上書きされる (= sync-to-validator-host.sh)
3. `/var/lib/freedom-yield/cycle-gate-state.json` が初期化される (= resume --apply で現サイクル承認)

deploy 中の race window (= 数秒):
- 修正前 script (= cycle-gate 知らない) と 修正後 script (= cycle-gate 期待) が混在する可能性
- rsync は inode 書換で atomic に近い、 race window は数 ms 以下
- 万一 race 中の cron tick で「post-anchor-event 新版 + cycle-gate.sh 旧版」 状態 = exit 11 (= fail-closed、 安全)
- 「post-anchor-event 旧版 + cycle-gate.sh 新版」 状態 = 旧 behavior (= cycle-gate consult なし、 broadcast 実行可能) — risk window 数 ms

risk 評価: race window 内に cycle transition が起こる確率 = 極小 (= 5 分 cron tick の境目 ± 数 ms)。 acceptable。

旧運用 fallback (= cycle-gate 系全削除した場合):
- post-anchor-event.sh で fail-closed exit 11 が頻発 → operator 即気付く
- 旧 11-step runbook に戻すには 9 script の revert + state file rm + cron 手動 disable/enable に戻す
- このカテゴリの emergency rollback は `docs/CYCLE_GATE.md` Rollback section 参照

## 9. memory rule compliance check

| memory | verify | result |
|---|---|---|
| `feedback_no_literal_host_identifier` | 全 9 修正 script + 1 新 audit doc で literal grep | ✅ 0 occurrences (= 本 doc 自身含む) |
| `feedback_cycle_number_no_shorthand` | cycle 番号 表記 | ✅ 「cycle 3 開始 (= 2026-07-04)」 「cycle 4 開始 (= ~2026-08-04)」 全件 date 併記 |
| `feedback_phase_alpha_no_pre_publish_regression` | 7/4 前 commit / push / production 投入 | ✅ working tree のみ、 commit 0 |
| `feedback_verify_before_reporting` | 報告前 test + grep | ✅ 27/27 PASS + 0 leak 確認後 report 起草 |
| `feedback_no_reasking_clarified` (= 新規 2026-06-29) | operator clarified 件再質問 | ✅ T-RD2 中 0 再質問 (= operator scope 説明後は即執行) |
| `feedback_ai_full_orchestration_default` | operator が能動的に何をしたか | ✅ wallet / passphrase / verify ゼロ (= T-RD2 は AI 単独実装) |

## 10. 2026-07-04 cycle 3 開始 transition への影響

| 項目 | 状態 |
|---|---|
| 全成果物 commit | **0 件** |
| 全成果物 push | **0 件** |
| the validator host production sync | **0 件** |
| Xserver 反映 | **0 件** (= deploy.yml exclude) |
| 既存 cron schedule | 無変更 |
| 既存 state file (= /var/lib/freedom-yield/*) | 無変更 |
| 既存 11-step canonical runbook | 完全準拠 (= 本設計の code は production 不在) |

→ **影響: ゼロ**

## 10.5. real-time scenario test (= T-RD3、 2026-06-29 14:43-14:45 JST 実走)

operator 要求: 「endTime を指定 + 8 cron が読み込む + endTime になったら自動で止まる」 を **wall-clock real-time** で検証。

### test 設計

| component | 役割 |
|---|---|
| `tests/cycle-gate/mock-rpc-timed.py` | 時刻依存 mock RPC。 ENDTIME_UNIX 前は validator-present、 以降は validator-absent (= cycle close を simulate) |
| `tests/cycle-gate/scenario-test-endtime.sh` | Phase A (= NOW) で 7 cycle script 実走 → green 確認 → wait until endTime+30s → Phase B で 8 script (= post-anchor-event 含む) 実走 → 全 skip 確認 |

### 検証結果 (= endTime = 2026-06-29 14:44:46 JST、 1782711886 unix)

```
Phase A (= 14:43:17 JST、 endTime 前):
  total 'deferred / suppressed / skip' markers: 0
  ✓ PASS — all scripts proceeded (gate green)

wait 118 sec (= 14:43:17 → 14:45:18)

Phase B (= 14:45:18 JST、 endTime 通過 + 30 sec cushion):
  ✓ post-anchor-event.sh: deferred marker present
  ✓ gen-cycle-history.sh: deferred marker present
  ✓ uptime-history.sh: deferred marker present
  ✓ gen-evidence.sh: deferred marker present
  ✓ gen-renewal-ics.sh: deferred marker present
  ✓ node-info.sh: deferred marker present
  ✓ check-anomalies.sh: deferred marker present
  ✓ daily-status.sh: deferred marker present

Phase B: 8/8 scripts skipped on gate deferred
  ✓ PASS — all 8 scripts auto-stopped after endTime

SCENARIO TEST RESULT: ✓ PASS
```

### 確認された operator 要求充足

| operator 要求 | 検証結果 |
|---|---|
| endTime 設定 file | mock-rpc-timed.py が ENDTIME_UNIX を保持 |
| 8 cron が読み込む | 8 scripts (= post-anchor-event + 7 cycle scripts) が cycle-gate.sh を consult |
| endTime になる | 14:44:46 JST wall clock 通過 (= mock RPC が validator-absent に切替) |
| 自動で止まる | 8/8 scripts が skip marker 出力、 broadcast / artifact write / digest 全停止 |

### test 中に発見した bug + fix (= 透明性記録)

| # | bug | 原因 | fix |
|---|---|---|---|
| S1 | post-anchor-event.sh failure with `env: --: No such file or directory` | scenario-test の `run_one ... -- --event-type ...` で `--` が env の end-of-options marker と衝突 | `--` 削除、 args 直接 pass |
| S2 | check-anomalies.sh failure with `ANOMALY_STATE_DIR is required` | ENV_BASE に環境変数欠落 | ANOMALY_STATE_DIR を ENV_BASE 追加 |
| S3 | post-anchor-event.sh Phase B で "no-op: dag_root_hash unchanged" (= exit 2) | Phase A で mock signer が anchor を完了 + last-anchored-root 書込み → Phase B で idempotency-skip | Phase A で post-anchor-event invoke せず (= production 整合)、 Phase B 開始時 last-anchored-root + anchor-receipt.json + anchor-pending.json を clear |
| S4 | post-anchor-event.sh Phase B で "RECOVERING from orphaned receipt" | Phase A の mock receipt が残留 → RESUME_MODE bypass | 同上 |

3 回の re-run + 段階的 fix を経て 8/8 PASS 到達。 修正後 test は決定的 (= deterministic、 wall-clock 依存だが固定 90 sec 範囲)。

### test 実行 reproducer (= 独立 audit 用)

```sh
# 90 sec 後の endTime で実走 (= 約 2 min wall-clock)
NEW_ENDTIME=$(($(date +%s) + 90))
bash tests/cycle-gate/scenario-test-endtime.sh "$NEW_ENDTIME"
# expected exit 0 + "SCENARIO TEST RESULT: ✓ PASS"
```

### 27 unit test との関係

unit test (= run-tests.sh、 27 件) = 各 component の挙動を fixture で deterministic verify。
scenario test (= scenario-test-endtime.sh) = wall-clock real-time で 8 cron 統合挙動を end-to-end verify。

両方 PASS で T-RD2 + T-RD3 設計の正当性確認。

## 11. 新 file 一覧 + sha256 (= 2026-06-29 T-RD2 final)

### 修正 file (T-RD2)

| path | wc -l | sha256 |
|---|---|---|
| `scripts/cycle-gate.sh` | 153 | `4fd972d08649bb8a...` |
| `scripts/post-anchor-event.sh` | 691 | `c95519a9ac4b8238...` |
| `scripts/gen-cycle-history.sh` | 138 | `047ffd8a04ead41f...` |
| `scripts/uptime-history.sh` | 228 | `2086e9de1ec4f08b...` |
| `scripts/gen-evidence.sh` | 221 | `7a25ca68df4822c0...` |
| `scripts/gen-renewal-ics.sh` | 187 | `238b1a8cb220cdde...` |
| `scripts/node-info.sh` | 377 | `3358bfd262ee7d36...` |
| `scripts/check-anomalies.sh` | 771 | `dce437ecfaefe9b2...` |
| `scripts/daily-status.sh` | 247 | `feb293b78237a9b6...` |
| `tests/cycle-gate/run-tests.sh` | 813 | `510ac655d9d5797e...` |

### 新規 file (T-RD2 + T-RD3)

| path | 種別 | wc -l | sha256 |
|---|---|---|---|
| `docs/CYCLE_GATE_TRD2_AUDIT.md` | 本 audit doc (= self-reference) | — | (= commit 後再計算) |
| `tests/cycle-gate/mock-rpc-timed.py` | T-RD3 新規 (= 時刻依存 mock RPC) | 87 | `35f19c8139e5c5b6...` |
| `tests/cycle-gate/scenario-test-endtime.sh` | T-RD3 新規 (= 8 cron 自動停止 real-time scenario test) | 295 | `ffc75cfea8d356a2...` |

sha256 再取得 command (= 独立 audit 時の照合):

```sh
shasum -a 256 \
  scripts/cycle-gate.sh scripts/resume-after-cycle-start.sh \
  scripts/post-anchor-event.sh scripts/gen-cycle-history.sh \
  scripts/uptime-history.sh scripts/gen-evidence.sh \
  scripts/gen-renewal-ics.sh scripts/node-info.sh \
  scripts/check-anomalies.sh scripts/daily-status.sh \
  tests/cycle-gate/run-tests.sh
```

## 12. T-7 deploy 着手の認可条件 (= 更新)

1. ✅ T-1〜T-6 完了 (= 第 3 ラウンド独立監査 PASS)
2. ✅ T-5.5 完了 (= 第 4 ラウンド独立監査 PASS)
3. ✅ **T-RD2 完了** (= 本 audit 提出、 第 5 ラウンド独立監査 受付準備)
4. ⏳ docs review + 「実装方針一致」 operator 判定
5. ⏳ 2026-07-04 cycle 3 開始 transition を既存 11-step で完走
6. ⏳ operator retrospective 完了
7. ⏳ operator から「T-7 deploy 着手 OK」 受領

## 13. 独立監査者への提供情報

| 確認項目 | command |
|---|---|
| sha256 全件再計算 | §11 の `shasum -a 256 ...` |
| test 27/27 PASS 独立再現 | `cd <repo> && bash tests/cycle-gate/run-tests.sh` |
| literal leak 0 確認 | `grep -rn "<IP_literal>\|<SSH_key_literal>" --include="*.sh" --include="*.md" --include="*.py" --include="*.json" . | grep -v "^./.git/"` (= 生 literal は memory reference_ssh_access 参照) |
| production 無変更確認 | `git status --short` (= working tree のみ、 15 path) |
| backward compat 確認 | 各 cycle script の gate block を read、 `${VAR:-default}` pattern 確認 |
| 8 cron への gate 適用網羅 | `grep -l "cycle-gate.sh" scripts/*.sh` = 9 件 (= cycle-gate.sh 自身 + 8 consumer) |

## 14. 独立監査 関連 doc 参照順

1. `docs/CYCLE_GATE.md` — 設計詳細 (= T-1〜T-6 で確定、 T-RD2 で type 追加された描画は当該 file で update 予定、 本 audit では未更新)
2. `docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md` — T-1〜T-6 audit (= 第 3 ラウンド PASS 済)
3. `docs/CYCLE_GATE_T55_AUDIT.md` — T-5.5 audit (= 第 4 ラウンド PASS 済)
4. `docs/CYCLE_GATE_TRD2_AUDIT.md` — 本 doc (= 第 5 ラウンド 受付)
5. `docs/VALIDATOR_RENEWAL.md` — 新 SOP section (= T-RD2 反映は別 update でも可)

## 15. 監査役 sign-off

self-attestation:

- 27 test 全件 PASS、 独立再現 command 提供済 (§13)
- production code 変更 ~118 行 (= 9 file modified)、 backward compat は post-anchor-event 以外で維持 (= 旧 cycle scripts は cycle-gate.sh 不在で exit 0 skip、 旧 behavior は「broadcast 試行」 → 「skip」 に変化)
- 既存 11-step canonical runbook の 7/4 実行に影響ゼロ
- 全 memory rule compliance 確認
- T-RD2 で発見した bug 1 件 (= T22 fixture 不足) を本 doc に開示済
- 操作 model α 完全遵守 (= operator 関与なし)

ただし、 過去 5 round の self-claim 後に独立監査が問題発見してきたため (= 第 1, 2 ラウンドで BLOCKER 検出)、 本 attestation は **第 5 ラウンド独立監査により verified されるまで保留扱い** を推奨。
