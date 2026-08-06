# C3 完遂 + guard の穴埋め — 実装計画 (2026-08-06)

**上位 spec**: `docs/superpowers/specs/2026-08-06-single-source-of-truth-design.md`
**期限**: 全タスク 9/4 の cycle 4→5 転換前に着地 (operator 決定)
**着地済み**: C3-1 (lib) / C3-3 (cron の `FY_LIVE=1`) / C3-4 (backup 保護) / C3-2a (監視系 7 script)。
本番 host の cron 16 本は `FY_LIVE=1` 済み、Rule 6 は 16/16 緑 (実測済み)。

## Global Constraints (全タスク共通・違反は即 fix 対象)

1. **broadcast 系のコマンドを書かない・実行しない** — `proton` / `cleos` /
   `push_transaction` / `issueTx` / `eth_sendRawTransaction`。既存の
   `bin/safe-broadcast` / `scripts/broadcast-guard.sh` の本体を変更しない。
2. **本番 host に SSH しない。実 ntfy を飛ばさない。実 push をしない。**
   本番への適用はコーディネーターが担当する。
3. **実在の IP・ホスト名・SSH 鍵名・アカウント名・ウォレットアドレスを書かない。**
   公開 repo なので commit 前に grep 検査すること。
4. **既存 assertion を 1 つも削除・弱化しない。** `tests/` 側の `-` 行は
   環境依存記述の置換に限り、期待値の緩和は不可。
5. **新しい不変条件は必ず mutation で実証する** — 修正を戻して赤くなることを
   確認してから緑を報告する。tautology な assertion を作らない。
6. **exit code は翻訳してよいが renumber しない。** `retryable_notify_rc()` の
   ように数値に依存する呼び出しが複数箇所にコピペされている。
7. **`bash tests/run-all-tests.sh` を commit 前に通す** (このマシンでは
   linux 専用 suite が SKIP され total=83 が現在の基準)。
8. **push しない。** 統合はコーディネーターが行う。
9. 担当ファイル一覧の外に書き込まない (並列タスクと衝突する)。触る必要が
   生じたら報告に書いて相談する。

## Task 1 — C3-2b: anchor / cycle 経路を side-effects.sh 経由にする

**担当ファイル**:
```
scripts/append-anchor-history.sh
scripts/resume-after-cycle-start.sh
scripts/cycle-gate.sh
scripts/check-anchor-publish-health.sh
scripts/watch-anchor-events.sh
scripts/notify-anchor-transition.sh
scripts/gen-anchor-source.sh
scripts/gen-cycle-history.sh
scripts/run-anchor-pipeline.sh
```

**やること**: 本番副作用 (notify / 公開 push / state 書込) を
`scripts/lib/side-effects.sh` の公開 API 経由にする。

| 現状 | 移行後 |
|---|---|
| `bash scripts/notify.sh ...` の直接呼び出し | `fyd_notify [--strict] [--tags=...] <priority> <title> [msg...]` |
| `bash scripts/push-to-web-host.sh <file>` | `fyd_push <filename>` |
| `$STATE_DIR` / `$STATE_FILE` / `/var/lib/freedom-yield` への直接書込 | `fyd_state_dir [anomaly\|watch\|uptime\|cycle]` + `fyd_live_write [--append] <desc> <path>` (内容は stdin) |

API と挙動の正典は **`scripts/lib/side-effects.sh` の冒頭コメント**。必ず読むこと。
特に `fyd_live_run "..." cmd > file` は **redirection を gate できない**
(dry でも file が truncate される) ので、ファイル書込は必ず `fyd_live_write`。

**この経路固有の危険 (絶対に壊さないこと)**:

- **append-only の chain 記録を止めない。** 公開 push の失敗で
  `append-anchor-history.sh` の append を止めてはいけない (fail-safe)。
  ただし loud に報告し、手動 retry コマンドを正確に出力すること。
  同 script は R18 archive の自動公開も持つ (`FYD_PUBLISH_ARCHIVES=0` が kill switch)。
- **`cycle-gate.sh` は他の 7 script が consult する gate**。ここが dry で
  「gate 判定そのもの」を返さなくなると、転換当日に全記録系が止まる。
  **gate の判定は副作用ではない** — 判定は常に行い、gate される
  のは書込・通知だけであること。
- **`gen-anchor-source.sh` の順序 guard (exit 9) と fail-closed な
  prev-link 抽出 (exit 10)** を壊さない。exit 7 は「atomic write 失敗」で
  既に使われているので再利用しない。
- **`resume-after-cycle-start.sh`** は RPC 不達時 fail-closed。この性質を保つ。
- `notify-anchor-transition.sh` は転換の通知経路。priority / tags / retry 挙動を変えない。

**受入条件**:
1. `FY_LIVE` 未設定/`0`/空 のとき、担当 9 script のどれを走らせても実 notify・
   実 push・実 state 書込が 1 つも起きない。**stub を置かずに**実証すること。
2. `FY_LIVE=1` のとき、移行前と同じ副作用が同じ引数で起きる。移行前後で
   「何を・どの引数で呼ぶか」が一致することを実測で示す (引数記録 shim で
   呼び出し列を比較する等)。
3. **grep gate**: 担当 9 script に「`notify.sh` / `push-to-web-host.sh` の
   直接呼び出しゼロ」「gate されない `$STATE_DIR`/`$STATE_FILE`/
   `/var/lib/freedom-yield` 書込ゼロ」を assert する test を追加し、
   **その gate 自身を mutation で実証**する。
4. **cycle-gate の判定が dry でも変わらない**ことを test で保証する。

## Task 2 — C3-2c: feed 生成経路を side-effects.sh 経由にする

**担当ファイル**:
```
scripts/peer-validators.sh
scripts/uptime-history.sh
scripts/peer-analytics.py
scripts/check-identity-pins.sh
scripts/advance-host-checkout.sh
```

**やること**: Task 1 と同じ移行を、feed 生成・host 追従の経路に適用する。

**この経路固有の危険**:

- **`peer-validators.sh` は「生成と同時に公開」する形になっている** (2026-08-05 の
  修正で、push が cron に無いために毎日 1 件ずつ 404 になる問題を潰した)。
  この「生成と公開が離れない」性質を壊さないこと。index は成功台帳から
  組み立てられており、push 失敗が永久 404 を生まない設計。
- **`check-identity-pins.sh` は `--mode=repo` (CI gate) と `--mode=live`
  (ops 監視) の 2 モードを持つ**。`--mode=repo` は CI で走るので
  **`FY_LIVE` が無い環境でも判定結果を返さなければならない**。gate されるのは
  通知だけであること。`die()` が live mode で必ず alert する性質も保つ。
- **`peer-analytics.py` は Python**。`side-effects.sh` は bash lib なので、
  Python から直接は source できない。**どう gate するかを設計し、報告に
  根拠を書くこと** (例: 環境変数を Python 側で同じ規則で判定する / bash wrapper に
  寄せる)。**`FY_LIVE` の判定規則 (literal `1` のときだけ live) を bash 側と
  一字一句同じにすること** — ここがズレると 2 つの真実源が生まれる。
- **`advance-host-checkout.sh`** は host の checkout を進める。anchor-source の
  保護 (未 commit の新鮮な dirt を discard せず alert) を壊さない。

**受入条件**: Task 1 と同じ 1-3。加えて:
4. `check-identity-pins.sh --mode=repo` が `FY_LIVE` 無しでも従来どおり
   判定を返すことを test で保証する (CI が壊れないことの保証)。
5. Python 側の `FY_LIVE` 判定が bash 側と同一であることを、**両方に同じ
   入力集合を与えて比較する test** で保証する。

## Task 3 — H3: `is_cron_executed_filename()` の 3 重定義を解消する

**担当ファイル**:
```
scripts/install-cron-env-headers.sh
scripts/install-repoint-publish-crons.sh
scripts/lib/cron-filename-guard.sh
tests/check-cron-file/            (必要なら)
tests/install-cron-env-headers/
tests/install-repoint-publish-crons/
```

**背景 (2026-08-06 のレビューで実測)**: 同一の関数が **3 箇所**に定義されている。
`scripts/lib/cron-filename-guard.sh` が SoT として新設されたが、既存 2 本の
inline 定義は残ったまま。現時点で 3 実装は byte 一致だが、**どれか 1 つだけ
編集されても検知する仕組みが無い**。

さらに悪いことに、**既存 2 ファイルのコメントは「テストに lock-step の
整合性検査がある」と主張しているが、そのテストは実在しない**。各ファイルが
自分用に関数を inline で再定義して mutation test しているだけで、
ファイル間を突き合わせる自動検査はどこにも無い (grep で全参照を確認済み)。
**存在しない保証を主張するコメントは、無いより悪い。**

これは「正しい状態が 1 箇所に無い」という、このリファクタ計画そのものの対象。

**やること**:
1. 既存 2 本の inline 定義を削除し、`scripts/lib/cron-filename-guard.sh` を
   source する形にする。
2. **実ソースを突き合わせる cross-file consistency test を追加**する
   (「定義が lib の 1 箇所だけであること」を assert する形でもよい)。
3. 実在しない保証を主張しているコメントを、**実態に合わせて訂正**する。

**受入条件**:
1. `is_cron_executed_filename()` の**定義**が repo 全体で 1 箇所だけであることを
   自動テストで保証し、mutation (2 つ目の定義を足す) で赤くなることを実証する。
2. 既存の per-file mutation test が引き続き緑であること (source 元が変わっても
   同じ判定を検証しているので通るはず)。通らないなら理由を報告に書く。
3. **`.bak-*` / `.disabled` / `.orig` / `~` を loud に skip する挙動**が
   2 つの installer で不変であることを実測で示す。

## Task 4 — F8: 公開 feed の runtime 面に guard を通す

**担当ファイル**:
```
scripts/push-to-web-host.sh
scripts/sync-to-validator-host.sh
scripts/publish-guard.sh          (必要最小限の変更のみ)
tests/publish-guard/
tests/push-to-web-host/
```

**背景 (2026-08-06 のレビューで実測)**: `publish-guard` は 3 層構成のはずだが、
**公開 feed の runtime 面はどの層にも守られていない**。

- `scripts/push-to-web-host.sh` は **`git` を一切経由しない**。作業ツリーの path を
  読み (`:63` `REPO_BASE=$(cd "$(dirname "$0")/.." && pwd)` / `:137` / `:175`)、
  そのバイト列を公開ホストへ流す (`:191-197`)
- 対象 (`public/api/*.json` / `archive/` / `peers-history/` / `public/calendar/`) は
  **すべて gitignored** → 層 1 は skip、層 2/3 は原理的に見えない
- cron から自動発火し、`scripts/append-anchor-history.sh:492` からも呼ばれる
- `scripts/sync-to-validator-host.sh:66-73` は**作業ツリーの `scripts/` を本番 host に
  rsync** して cron 実行用に chown する = これも guard を通らない
- **CI でも publish-guard は一切走っていない** (`.github/` に hit 0)。
  `core.hooksPath` は clone ごとの設定で commit もされていない

**現状の実害はゼロ** (コーディネーターが公開 feed 11 本 + tracked 全 file を
走査して hit 0 を実測済み)。塞ぐのは機構の穴。

**やること**: 送出の直前に guard を通す層を足す。

**設計上の要求**:
- **fail-closed**: guard を実行できないときは送出しない。
- **送出対象そのものを検査する** (path の allowlist ではなく、流すバイト列)。
- **性能**: `push-to-web-host.sh` は 5 分周期の cron から呼ばれる。1 回あたりの
  実時間の増分を実測し、報告に書くこと。
- **既存の allowlist / fail-closed な JSON 検証 / retry 挙動を壊さない。**
  送受両側が独立に同一 allowlist を enforce している設計を維持する。
- `publish-guard.sh` 本体を触る場合は**必要最小限**にすること。2026-08-06 に
  4 round かけて安定させたばかりで、assertion が 184 ある。

**ついでに直すもの (同じテストファイルを触るため)**:
`tests/publish-guard/test-publish-guard.sh` の `info/exclude` 操作に
**trap が無い**。中断すると**全 worktree 共有の** `info/exclude` に test 用の行が
残り、`mktemp` の backup も `/tmp` に取り残される。trap で原状復帰させること。

**受入条件**:
1. 禁止パターン (host identifier 等) を含むバイト列を push しようとすると
   **送出前に落ちる**ことを実測で示す。mutation で実証すること。
2. 正当な feed が従来どおり送出されることを実測で示す (回帰なし)。
3. guard を実行できない状況 (依存 tool 不在等) で **fail-closed** になることを実測。
4. `test-publish-guard.sh` が中断されても `info/exclude` が原状復帰することを、
   **実際に途中で kill して**確認する。
5. 1 回あたりの実行時間の増分を実測して報告する。
