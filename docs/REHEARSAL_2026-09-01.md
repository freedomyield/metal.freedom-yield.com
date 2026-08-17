# 9/1 testnet 通し稽古 — 実行手順

> **転換日 2026-09-04 / 稽古日 2026-09-01(月)。** 本書は 9/1 に operator が読む
> 実行手順。`docs/CYCLE_GATE.md`「Operator runbook (= cycle transitions, model
> α)」が当日 (9/4) の canon であり、本書はそれと矛盾しない — 矛盾する記述が
> あれば `docs/CYCLE_GATE.md` を正とする。

## 0. この文書でやること / やらないこと

- **やること**: 9/1 に operator が打つ最小限の操作と、AI が事前・当日に代行する
  範囲を確定する。
- **やらないこと**: 9/4 当日の全 14 実行単位の手順は再掲しない(それは
  `docs/CYCLE_GATE.md` と `docs/VALIDATOR_RENEWAL.md` の役目)。9/1 に**触れる
  範囲だけ**を扱う。
- **前提として持っておくこと**: 「通し稽古」という言葉が指すのは、当日 14
  実行単位のうち **unit 7a (`scripts/run-testnet-rehearsal.sh`) 1 本だけ**。
  9/1 に稽古できるのはそこに AI 事前作業を足した範囲であって、14 単位全部の
  リハーサルではない。稽古後も検証できずに残るものは §4 に列挙する — **「稽古
  したから 9/4 は大丈夫」と読める文はこの文書のどこにも書かない**。

---

## 1. AI が事前に済ませる部分(operator 不要)

### 1.1 preflight

9/1 に operator へ最初のピングを送る前に、AI は `scripts/install-rehearsal-preflight.sh`
(別タスクが用意する read-only installer)を実行し、出力が全 green であることを
確認する。個別の検査項目はここに転記しない — preflight 自身の出力に従う。green
にならない項目があれば、operator へピングする前に原因を特定し是正する(この
script 自体は何も変更しない)。

この script が 9/1 までに main へ着地していない場合、本節の手順は成立しない —
その場合は AI が個別に前提確認を行った上で、実行可否を先に報告する。

### 1.2 unit 7b(mainnet dry run)は AI が丸ごと稽古する

`scripts/preview-cycle-anchor-broadcast.sh`(= unit 7b、当日の gate-4 材料生成)
は「mainnet」と名の付く script だが、実際には **broadcast 経路を持たず、
operator token に触れない**
(`scripts/preview-cycle-anchor-broadcast.sh:41-42`「BROADCASTS NOTHING. Invokes
no `proton transaction` / real safe-broadcast call. Touches no operator
token.」)。**keystore の unlock も要求しない** — 本タスクで script 全体を通読
して確認: `proton` 呼び出しは `require_project_keystore_home` による §3.5
guard 判定(:123)と、read-only な `proton chain:info`(:348、proton が PATH に
無ければスキップされる、gate 3 の事前確認用)の 2 箇所だけで、いずれも署名や
unlock を要しない。`HOME=~/.metal-fy-proton` を渡すのは §3.5 keystore guard を
満たすためだけ。→ **9/1 の当日作業から operator を外し、AI が丸ごと実行する。**

実行タイミングは operator の操作③(下記 §2)が出す testnet tx id に依存する。
操作③の完了後、AI は次を実行する:

```
FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
  bash scripts/preview-cycle-anchor-broadcast.sh \
    --source=public/api/anchor-source.json \
    --testnet-tx-id=<操作③の testnet_tx_id>
```

このコマンドは **broadcast も recompose もしない**(script 自身のヘッダより)。
出力末尾の 3 行が operator の視認対象になる(§2 ピング 2)。

### 1.3 変更が集中した unit の dry 実行 + 既存 test での被覆確認

8/4 転換以降のコミット数が多い unit のうち、production を汚さずに検証できる
ものは AI が 9/1 前に実行しておく。実行しない unit は既存 test suite の被覆を
確認するに留める(実データ・実書込を伴うため)。

| unit | script | 9/1 に AI が安全に確認できること | 既存 test |
|---|---|---|---|
| 2 | `uptime-history.sh` | `FY_LIVE` を付けずに実行し、4 write すべてが `DRY: would …` になり実ファイルが 1 バイトも変わらないことを確認する(script 自身の設計どおり、`FY_LIVE` 無しは書込ゼロの loud dry no-op — `docs/CYCLE_GATE.md` 該当節参照)。cycle 境界 (Job B) は 9/4 まで発火しないため、この確認は「今日は何も壊れない」の確認であって cycle-close 経路の稽古ではない | `tests/side-effects-callers/`、`tests/cycle-gate/run-tests.sh` |
| 3 | `gen-cycle-history.sh` | **`push-to-web-host.sh` は実行しない**(公開先への実書込のため)。`gen-cycle-history.sh` 単体は `FY_LIVE` の概念を持たず決定的再生成(script 自身のヘッダで明言)なので、host 上で単体実行し、入力(`uptime-cycles.json` / `incidents.json`)が変わっていなければ出力が前回と byte 同一であることを確認する | `tests/gen-cycle-history/test-incident-attribution.sh` |
| 5 | `gen-anchor-source.sh` | `FY_EXPECT_CYCLE=<§3 のプレースホルダ>` を付けて host 上で実行し、ordering guard が **compose 前に** exit 9 で止まることを確認する。guard の判定は P-chain RPC 呼び出しより前にあるため(`gen-anchor-source.sh:391-399`)、この確認に副作用は無い | `tests/test-gen-anchor-source-ordering-guard.sh` |
| 8 | `gen-anchor-receipt.sh` / `append-anchor-history.sh` | **実行しない** — 実 signed input(mainnet broadcast の出力)が無いと意味のある検証にならず、本物の `--input=` を用意する手段が 9/1 には無い。`FYD_HISTORY_FILE` によるscratch 台帳退避と `FYD_PUBLISH_ARCHIVES=0` による R18 push 抑止の**機構自体**が存在することだけを、実装読解で確認する(`scripts/append-anchor-history.sh:78,124-128,574-575`) | `tests/gen-anchor-receipt/`、`tests/append-anchor-history/` |
| 8.5 | `push-to-web-host.sh` | **実行しない** — 公開先への実書込のため。既存 test で冪等性(同一 byte の再 push が副作用を生まないこと)が確認されていることのみ確認する | `tests/push-to-web-host/test-push-to-web-host.sh` |
| 9 | `resume-after-cycle-start.sh --dry-run` | 実行してよい(`FY_LIVE` 無しの `--dry-run` は state dir の mkdir すら行わない設計 — script ヘッダ「the one write it used to make regardless of mode … is now gated too」)。**ただし cycle 4 の承認 state は 2026-08-04 の転換時点で既に書かれているため、今日実行すると idempotency check (`:194-198`) が freshness poll (`:210-240`) と identity 署名検証 (`:243-279`) より先に一致し、`PASS: idempotent skip` で即終了する** — この 2 つは 9/1 には 1 行も動かない(§4-F3 参照) | `tests/cycle-gate/run-tests.sh`(状態遷移の mock 検証) |

unit 4(`gen-identity.sh`)と unit 6(`commit-anchor-source.sh`)はこの一覧から
意図的に外す: 4 は ordering guard が発火しなかった場合に**署名済み
`identity.json` を上書きする**リスクがあり、6 は validator host への実 SSH
座標(`VALIDATOR_HOST` / `VALIDATOR_HOST_KEY`)を要求する — どちらも 9/1 の
read-only 事前確認の範囲を超える。

---

## 2. operator の操作(5 回、ピング 2 回に集約)

**前提**: 9/1 は月曜、operator 稼働は平日 9:30–18:30。すべて operator の Mac
上での操作。各コマンドは **1 行の最短形**で渡す(改行分断で失敗した前例が
ある)。

### ピング 1 — 操作①②③④(連続してやる。unlock したまま放置しない)

①→②→③→④の順に自分の terminal で続けて実行し、**すべて終わってから**③の
末尾の `TESTNET REHEARSAL COMPLETE testnet_tx_id=…` の 1 行(と、途中で何か
失敗コードが出ていればそれ)をまとめて AI に報告する。④(re-lock)は③の tx id
を待たずに実行してよい — 後続の AI 作業(§1.2)は testnet keystore に触れない。

#### ① identity 鍵を ssh-agent に載せる

```
ssh-add ~/.ssh/freedom-yield-operator-identity
```

- **Dashlane entry 名**: 「<entry name withheld - handed over in the operator ping>」
- **目視するもの**: `Identity added: /Users/…/freedom-yield-operator-identity`
  の 1 行。
- **なぜこれをやるか**: `gen-identity.sh` は `ssh-keygen -Y sign -f
  "${OPERATOR_IDENTITY_KEY}"` を秘密鍵の path 直指定で呼ぶ
  (`scripts/operator-local/gen-identity.sh:893`)。ssh-agent に鍵を載せておくと
  以降の呼び出しで passphrase プロンプトが出ない(agent が実際の機構である
  ことは暗号化 ed25519 鍵での対照実験で確認済み — agent 有りは無プロンプトで
  成功、agent 無しはプロンプトを出して失敗)。**9/4 当日も同じ操作が必要**
  (agent はセッションを跨がない)。目的は当日の操作を 1 つ減らすことではなく、
  「passphrase を打つ場所を選べる」ようにすること。
- **失敗したら**: `Bad passphrase` → Dashlane entry 名を再確認。

#### ② testnet keystore を unlock

```
HOME=~/.metal-fy-proton-test proton key:unlock
```

- **Dashlane entry**: testnet keystore の 32 文字 password。**この文書には
  entry 名を記載しない**(repo からは特定できない) — ピングを送る直前に AI が
  memory / Dashlane 側で entry 名を確認し、そのピングに添えること。
- **目視するもの**: エラーなくシェルに戻ること。
- **失敗したら**: 以降③が exit 2 で止まり、`Run in a separate terminal:
  HOME=~/.metal-fy-proton-test proton key:unlock` を出す
  (`scripts/run-testnet-rehearsal.sh:336-341`, `:381-386`)。壊れない、やり直せる。

#### ③ testnet 通し稽古を実行する(= testnet broadcast の per-invocation 認可そのもの)

```
HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<!-- A1 確定値をここに: 9/1 = __ (根拠: task-a1-report.md) -->
```

- **なぜ operator が打つのか**: この script は `/tmp/fyd-broadcast-token` を
  自分で作って `bin/safe-broadcast` に渡す
  (`scripts/run-testnet-rehearsal.sh:413-429`)。「operator 自身がこの script
  を起動したこと」が testnet broadcast の per-invocation 認可の実体
  (`docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`「What an AI session can verify, and
  what only the operator can」)。AI が起動した run はたとえ全 gate を通っても
  認可にならない。
- **目視するもの(この順で)**:
  1. `step 1/10` の `cycle_number_observed:` と `derived memo_prefix:`
  2. `step 3/10` の `present: … (matches current on-chain key)`
  3. `step 7/10` の `BROADCAST OK  tx_id=<64hex>`
  4. `step 9/10` の `7-gate PASS`
  5. 末尾の `TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>` — **この 1 行を
     そのまま chat に貼る**(AI が §1.2 の 7b 実行にこの tx id を使う)
- **所要**: 未実測。RH 調査は chain 待ちを含め 3〜6 分と見積もっているが、実測
  値ではない。
- **失敗コードの意味**:

  | exit | 意味 | 対処 |
  |---|---|---|
  | **1** | `fail()` が呼ばれた全て — step 1/10 の `--expect-cycle` 不一致 / config 欠落 / fixture 拒否、または step 9/10 (`gen-anchor-receipt.sh`) 内部の 7-gate 不通過など。メッセージに従って修正し再実行する。**step 7/10 より前で exit 1 なら broadcast は未発生。step 9/10 経由の exit 1 は broadcast が既に成功している場合がある**(tx は testnet 上に残る) | メッセージを読んで修正、再実行 |
  | **2** | keystore が locked(step 3/10 または 4/10) | 操作②をやり直す |
  | **8** | §3.5 keystore guard — `HOME=` prefix を付け忘れた(`:188`) | `HOME=~/.metal-fy-proton-test` を付けて再実行 |

- **後始末(AI が行う、operator 操作ではない)**: `rm -f /tmp/fyd-broadcast-token`
  — testnet 向けに bound された token は R16 により mainnet 側 (7b/7c) に流用
  できず TTL 5 分で自然失効するが、`/tmp` に残るとノイズになるため掃除する。

#### ④ testnet keystore を re-lock

```
HOME=~/.metal-fy-proton-test proton key:lock
```

- **目視**: プロンプト `Enter 32 character password (leave empty to create
  new)` に、**unlock と同じ 32 文字を入れる**。**空 Enter は新規 password の
  作成になる**(既存 keystore の password が失われる意味ではなく、新しい
  password でロックし直すことになる — 次回 unlock 時に unlock 用 password と
  一致しなくなる)。厳禁。

### ピング 2 — 操作⑤(打つのは AI、見るのは operator)

7b(§1.2)の実行が済んだら、operator は出力の**3 行だけ**を目視する:

```
✓ byte-for-byte identical to git show HEAD:public/api/anchor-source.json
✓ published copy matches committed bytes
memo count (expect 4): 4
```

(`scripts/preview-cycle-anchor-broadcast.sh:195,286,332` — 実際の出力文字列と
一致することを本タスクで確認済み)

3 行とも上記の形であれば OK。1 行でも異なれば AI に報告する(commit/push/deploy
のタイミング差、または `anchor-source.json` の不一致の可能性がある — 原因の
切り分けは AI が行う)。

### 合計

| | 回数 | 備考 |
|---|---|---|
| passphrase / password を打つ操作 | 3(①②④) | すべて 1 分未満 |
| 実行して出力を見る操作 | 1(③) | 所要未実測 |
| 目視だけの操作 | 1(⑤) | 3 行の確認のみ |
| **operator へのピング** | **2 回** | ピング 1 = ①②③④、ピング 2 = ⑤ |

---

## 3. `--expect-cycle` の値

<!-- A1 確定値をここに: 9/1 = __ (根拠: task-a1-report.md) -->

上記の値は別タスク(A1)が実測で確定する。**この文書の執筆時点では未確定 —
推測値を書かない。** 9/1 当日にこのプレースホルダを A1 の確定値に置き換えて
から operator へピングを送ること。

参考(未確定であることの根拠): canonical `anchor-source.json` の
`cycle_number_observed` と公開 `cycle-history.jsonl` の行数は本書執筆時点でも
実測可能だが、**この文書には値を書かない** — 執筆時点の実測値をそのまま 9/1
当日の `--expect-cycle` に対応付けるのは早計であるため(9/1 までに公開台帳や
canonical `anchor-source.json` が別の理由で更新される可能性がある)。A1 が
当日直前に再実測して確定する。

---

## 4. 正直な限界 — 稽古しても検証できないもの

**「9/1 に稽古したから 9/4 は大丈夫」は成立しない。** 以下は 9/1 の稽古後も
未検証のまま残る。

| # | 残る不確実性 | 根拠 |
|---|---|---|
| **F1** | mainnet gate 1 と gate 4 は testnet 実行では 1 行も動かない。`bin/safe-broadcast:250` の `if [ "$IS_MAINNET" = "1" ]` が gate 1(`:251-374`)と gate 4(`:376-435`)の全体を囲む — testnet 実行(`IS_MAINNET=0`)が通るのは gate 2(`:438-466`)/ gate 2b(`:468-526`)/ §3.5 keystore guard(`:528-536`)/ gate 3(`:538-563`)のみ。**緩和材料**: このコードは 2026-07-31 以降 0 commit で、2026-08-04 の cycle-4 転換で実走済み(本タスクで再確認)。**残る不確実性**: 8/4 は memo prefix `fya1c4`、9/4 は `fya1c5` — 桁上がりの無い同型 shape のはずだが、これは推論であって実測ではない | `bin/safe-broadcast` 実装(本タスクで直接確認) |
| **F2** | mainnet の chain_id / RPC 到達性 / account 状態は稽古で一切保証されない。9/4 に `bin/safe-broadcast` の gate 3(`:538-563`)が初めて実測する | `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`「Scope: what a rehearsal run actually proves」 |
| **F3** | unit 9(`resume-after-cycle-start.sh`)の freshness poll と identity 署名検証は 9/1 に発火しない。idempotency check(`:194-198`)が先にあり、cycle 4 は 2026-08-04 の転換時点で既に承認済みのため、今日 `--dry-run` すると即 `PASS: idempotent skip` で抜ける。→ **公開 `anchor-source.json` の `dag_root_computed` 変化の poll と、`identity.json` / `.sig` / pubkey 3 点の `ssh-keygen -Y verify` は 9/4 が初回** | `resume-after-cycle-start.sh:139,194-279`(本タスクで再確認) |
| **F4** | cycle 境界でしか動かないコードは 9/1 に動かない — `uptime-history.sh` の Job B(`Closed cycle #<N>` / `uptime-cycles.json` 追記 / `uptime-recent.json` 再生成)、`gen-cycle-history.sh` の「新規行を 1 行追加する」経路、`append-anchor-history.sh` の invariant 4/6(cycle_number 単調増加 / prev_anchor_tx_id 連鎖)の実運用検証はいずれも境界が来るまで発火しない | `docs/CYCLE_GATE.md` step 2/3/8 |
| **F5** | step 0(Metal Wallet で AddValidator submit)と mainnet broadcast 認可(unit 7c)は、稽古する手段が**構造的に存在しない**。前者は wallet UI の仕様が当日まで確認できない(`docs/VALIDATOR_RENEWAL.md` 2.2 節が「当日 Step 1 の段階で一度フォームを開いて目視確認せよ」と明記しているのはこの不確実性のため)。後者は不可逆かつ per-invocation 認可を要する(§3.4 / PRIME DIRECTIVE) | `docs/VALIDATOR_RENEWAL.md`、`bin/safe-broadcast` gate 1 |
| **F6** | `--status` の green は「全部終わった」を意味しない。14 単位のうち **5 つ**(7a / 7b / {7.5, 8, 8.5} / 4b の registry 編集)がどの事後条件にも入らない — `scripts/cycle-transition.sh --status` を本タスクで実際に再実行して確認: 「FIVE OF THE FOURTEEN EXECUTION UNITS ARE COVERED BY NO POST-CONDITION」。とくに 7.5 / 8 / 8.5 を丸ごと飛ばしても、その日の `--status` は 5 条件すべて green を返しうる — その場合 on-chain には刻まれているのに公開 `anchor-receipt.json` / `anchor-history.jsonl` は前 cycle を配り続ける。稽古ではこの穴は埋まらない — 9/4 当日は目視 checklist で補う必要がある | `scripts/cycle-transition.sh --status`(現在の canonical cycle 番号を渡して)実行結果(2026-08-17、本タスクで実測。rc=70) |
| **F7** | 稽古と本番で「実行するファイル」が同一である保証は 9/1 時点では無い — `docs/cycle-transition-steps.json` が指す当日 script(9/1 以降に変更されれば稽古との差分になる)。凍結ポリシーは §5 | `docs/cycle-transition-steps.json` |

---

## 5. 凍結ポリシー

9/1 の稽古完了後から 9/4 の cycle 転換完了までの間、`docs/cycle-transition-steps.json`
が実行単位として名指す script(`run-testnet-rehearsal.sh` /
`preview-cycle-anchor-broadcast.sh` / `sign-anchor-event.sh` /
`gen-anchor-source.sh` / `gen-identity.sh` / `uptime-history.sh` /
`gen-cycle-history.sh` / `push-to-web-host.sh` / `gen-anchor-receipt.sh` /
`append-anchor-history.sh` / `resume-after-cycle-start.sh` など、同ファイルの
`steps[].scripts` に列挙されたもの)への変更は、**該当する実行単位の再稽古と
セットでのみ**許可する。

ルールの本体・適用範囲・根拠は `docs/CYCLE_GATE.md`「Script freeze around a
rehearsed transition」節を正とする(本節は具体的な適用ウィンドウの記録のみ —
二重管理はしない)。凍結の対象外(`docs/STRATEGIC_TARGET_ALIGNMENT.md` や本節が
列挙しない tooling 等)への変更はこの間も通常どおり可能。

---

## 6. 当日(9/1)の推奨実行順

| 誰 | 何 |
|---|---|
| AI(9/1 前) | §1.1 preflight を全 green にする。§3 のプレースホルダを A1 の確定値に置き換える |
| AI(9/1 午前) | §1.3 の dry 実行(unit 2/3/5/9)を行い、結果を記録する |
| operator(ピング 1) | 操作①→②→③→④(連続、passphrase 系のみ 3 分程度。③自体の所要は未実測) |
| AI | ③の testnet tx id を受け取り、§1.2(unit 7b)を丸ごと実行する |
| operator(ピング 2) | 操作⑤ — 7b 出力の 3 行を目視する |
| AI(9/1 夕) | 稽古結果を記録する。**「これは今日 canonical だった cycle の稽古であって、9/4 の gate-1 evidence そのものではない」を明記する**(9/4 当日は `--expect-cycle=<9/4 の値>` で改めて実行が必要) |

---

## 関連

- `docs/CYCLE_GATE.md` — 当日 (9/4) runbook の canon。凍結ポリシーの正本もここ。
- `docs/VALIDATOR_RENEWAL.md` — operator 向け手順書の文体・粒度の参照元。
- `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md` — `run-testnet-rehearsal.sh` の詳細
  runbook。「Scope: what a rehearsal run actually proves」節は本書 §4 の F1/F2
  と同じ原則を単発の稽古実行に適用したもの。
- `docs/cycle-transition-steps.json` — 当日 14 実行単位の機械可読な一覧。§5
  凍結ポリシーの対象範囲の定義そのもの。
