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
token. Writes only a temp dry-run-log.」)。**keystore の unlock も要求しない**
— 本タスクで script 全体を通読して確認: `proton` 呼び出しは
`require_project_keystore_home` による §3.5 guard 判定(:123)と、read-only な
`proton chain:info`(:348、proton が PATH に無ければスキップされる、gate 3 の
事前確認用)の 2 箇所だけで、いずれも署名や unlock を要しない。
`HOME=~/.metal-fy-proton` を渡すのは §3.5 keystore guard を満たすためだけ。
→ **9/1 の当日作業から operator を外し、AI が丸ごと実行する。**

**⚠ この script の出力の末尾は、operator が見る 3 行ではない。** 末尾は
`── [5/5] STAGE 2 — broadcast command (review + authorize FIRST; do NOT
auto-run here) ──`(`:355`)から始まる、mainnet broadcast の「貼れる形」の
手順一式 — mainnet 用 operator token 生成 1 行(`:370`)、`HOME=~/.metal-fy-proton
proton key:unlock` 1 行(`:373`)、`sign-anchor-event.sh --chain=mainnet-a …` の
呼び出し 6 行(`:374-379`)。script 自身は compose も broadcast もしないと
明言する(`:384`「STAGE 1 complete. NOTHING was broadcast, NOTHING was
recomposed.」)が、**9/1 に AI がこの STAGE 2 ブロックの中身を実行することは
絶対にない**。9/1 の作業対象は出力の途中にある 3 行(`:195` / `:286` /
`:332` — 下記 §2 ピング 2)だけであり、AI はこの STAGE 2 ブロックを実行せず、
operator にも見せない(視認を求めるのは §2 ピング 2 の 3 行のみ)。

実行タイミングは operator の操作③(下記 §2)が出す testnet tx id に依存する。
操作③の完了後、AI は次を実行する。`DRYLOG` は 9/4 が使う既定 path
(`/tmp/fya-mainnet-dryrun.json`)と衝突しない scratch path に明示的に向ける
(理由は下記の後始末を参照):

```
FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
  DRYLOG=/tmp/fya-mainnet-dryrun-rehearsal-0901.json \
  bash scripts/preview-cycle-anchor-broadcast.sh \
    --source=public/api/anchor-source.json \
    --testnet-tx-id=<操作③の testnet_tx_id>
```

このコマンドは **broadcast も recompose もしない**(script 自身のヘッダより)。
operator の視認対象は §2 ピング 2 の 3 行(出力の中ほど、末尾ではない)。

**後始末(AI が行う)**: ピング 2 の視認が済んだら
`rm -f /tmp/fya-mainnet-dryrun-rehearsal-0901.json`。この dry-run log は
今日の cycle 用の `memo_prefix` を記録したものであり、**9/4 の gate-4 材料
ではない**(9/4 は改めて同じ script を実行して新しい log を作る — 9/4 用の
`DRYLOG` は既定 path のままでよい)。`/tmp` に残しておくと、9/4 に「gate-4
材料らしきファイルが既にある」と誤認される囮になり得る — RH 調査が 7b の
実行そのものを見送った理由(付録「しなかったこと」)はまさにこれ。

### 1.3 変更が集中した unit の dry 実行 + 既存 test での被覆確認

8/4 転換以降のコミット数が多い unit のうち、production を汚さずに検証できる
ものは AI が 9/1 前に実行しておく。実行しない unit は既存 test suite の被覆を
確認するに留める(実データ・実書込を伴うため)。

| unit | script | 9/1 に AI が安全に確認できること | 既存 test |
|---|---|---|---|
| 2 | `uptime-history.sh` | `FY_LIVE` を付けずに実行し、script のヘッダが列挙する 4 artefact(master ledger append / `current-cycle-state.json` / cycle-close summary / 公開 `uptime-recent.json` preview)がすべて `DRY: would …` になり実ファイルが 1 バイトも変わらないことを確認する(`FY_LIVE` 無しは書込ゼロの loud dry no-op — `docs/CYCLE_GATE.md` 該当節参照)。cycle 境界 (Job B) は 9/4 まで発火しないため、この確認は「今日は何も壊れない」の確認であって cycle-close 経路の稽古ではない | `tests/side-effects-callers/`、`tests/cycle-gate/run-tests.sh` |
| 3 | `gen-cycle-history.sh` | **`push-to-web-host.sh` は実行しない**(公開先への実書込のため)。`gen-cycle-history.sh` 単体は `FY_LIVE` の概念を持たず決定的再生成(script 自身のヘッダで明言)だが、既定では host の `public/api/cycle-history.jsonl` に実書込する(`gen-cycle-history.sh:107`)。**`OUT_JSONL=<scratch path>` を付けて実行し**(同ファイル同行の env override)、canonical ファイルに触れずに出力を得た上で、公開版(`curl` で取得)と byte 同一であることを確認する | `tests/gen-cycle-history/test-incident-attribution.sh` |
| 5 | `gen-anchor-source.sh` | **`FY_EXPECT_CYCLE` に §3 のプレースホルダをそのまま使わない**(`docs/CYCLE_GATE.md` step 6 が明示する「deliberate meaning switch」どおり、`gen-anchor-source.sh` の `FY_EXPECT_CYCLE` は closed-cycle count、§3 の値 = `run-testnet-rehearsal.sh --expect-cycle` は「これから刻む cycle 番号」= closed-cycle count + 1 で、1 ずれる — `gen-anchor-source.sh:391-397` が `CLOSED_COUNT` と比較する側)。unit 5 用の値は `<!-- unit5 用 FY_EXPECT_CYCLE = §3 の値 − 1(根拠: docs/CYCLE_GATE.md「Deliberate meaning switch from step 5」) -->` で別途プレースホルダ化する。実行は **`OUT_FILE=<scratch path>` を必ず付ける**(`gen-anchor-source.sh:100,107` が `OUT_FILE` env / `--out=` flag を受ける)— guard が発火すれば(期待どおり `CLOSED_COUNT != FY_EXPECT_CYCLE` で **exit 9**、compose 前に止まる、`:391-399` は P-chain RPC 呼び出し `:419-421` より前)副作用は無いが、**万一 guard が通ってしまう(exit 0)と `:751 mv "$TMP_OUT" "$OUT_FILE"` で host の canonical `public/api/anchor-source.json` を上書きする** — `OUT_FILE` を scratch に向けておけば guard の発火有無にかかわらず canonical ファイルは触れない。exit 9 以外(とくに exit 0 で `✓ ordering guard` が出た場合)は値の取り違えの兆候なので即座に AI から報告する | `tests/test-gen-anchor-source-ordering-guard.sh` |
| 8 | `gen-anchor-receipt.sh` / `append-anchor-history.sh` | **実行しない** — 実 signed input(mainnet broadcast の出力)が無いと意味のある検証にならず、本物の `--input=` を用意する手段が 9/1 には無い。`FYD_HISTORY_FILE` によるscratch 台帳退避と `FYD_PUBLISH_ARCHIVES=0` による R18 push 抑止の**機構自体**が存在することだけを、実装読解で確認する(`scripts/append-anchor-history.sh:78,124-128,574-575`) | `tests/gen-anchor-receipt/`、`tests/append-anchor-history/` |
| 8.5 | `push-to-web-host.sh` | **実行しない** — 公開先への実書込のため。既存 test で冪等性(同一 byte の再 push が副作用を生まないこと)が確認されていることのみ確認する | `tests/push-to-web-host/test-push-to-web-host.sh` |
| 9 | `resume-after-cycle-start.sh --dry-run` | **host 上で**実行してよい(`FY_LIVE` 無しの `--dry-run` は state dir の mkdir すら行わない設計 — script ヘッダ「the one write it used to make regardless of mode … is now gated too」、`:139`)。**ただし cycle 4 の承認 state は 2026-08-04 の転換時点で既に書かれているため、host 上で今日実行すると idempotency check (`:194-198`) が freshness poll (`:210-240`) と identity 署名検証 (`:243-279`) より先に一致し、`PASS: idempotent skip` で即終了する** — この 2 つは 9/1 には 1 行も動かない(§4-F3 参照)。**Mac 上では実行しない** — host の `/var/lib/freedom-yield` state が無いため idempotency check がスキップされず freshness poll に進み、既定 `METALGO_RPC=http://127.0.0.1:9650` に届かず別の理由で失敗する(この確認の意味が変わってしまう) | `tests/cycle-gate/run-tests.sh`(状態遷移の mock 検証) |

unit 4(`gen-identity.sh`)と unit 6(`commit-anchor-source.sh`)はこの一覧から
意図的に外す: 4 は ordering guard が発火しなかった場合に**署名済み
`identity.json` を上書きする**リスクがある。6(`commit-anchor-source.sh`)は
unit 3/5 と違って「host 上で実行」では済まず — 成功時(= `--expect-cycle` が
一致した場合)に**必ず `git add` + `git commit` を実 tracked repo に対して
実行する**(script 自身のヘッダ `:38-40`「Copies the fetched (now-validated)
bytes into the repo path, `git add`, and a single-purpose commit …」) — たとえ
中身が既存と同一でも working tree に新規 commit が生まれてしまい、これは
本タスクの編集許可(`docs/REHEARSAL_2026-09-01.md` と `docs/CYCLE_GATE.md`
凍結節のみ)を超える。加えて実行には実 SSH 座標(`VALIDATOR_HOST` /
`VALIDATOR_HOST_KEY`)も要る。どちらも 9/1 の read-only 事前確認の範囲を
超える。

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
  (`scripts/operator-local/gen-identity.sh:895`)。ssh-agent に鍵を載せておくと
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
- **9/4 当日も改めて必要**: 今日の tx は今日 canonical な cycle の shape の
  稽古であって、9/4 の PRIME DIRECTIVE gate-1 evidence ではない —
  `bin/safe-broadcast` gate 1 は cross-cycle の evidence を拒否する
  (`:363-374`、memo prefix 集合の一致検査)。9/4 は `--expect-cycle=<9/4 の
  値>` で本操作をもう一度実行する。
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
  | **1** | `fail()` が呼ばれた全て — step 1/10 の `--expect-cycle` 不一致 / config 欠落 / fixture 拒否、step 7/10 の `bin/safe-broadcast` 失敗(`:451`。直前に `safe-broadcast exit rc=<内部の rc>` 行が出る — 内部 rc 自体は表からは読めないのでこの行を見る)、step 8/10 の tx_id 抽出失敗(`:456`、broadcast は既に成功している)、または step 9/10 (`gen-anchor-receipt.sh`) 内部の 7-gate 不通過など、原因は様々でも**すべて exit 1 に潰れる**。メッセージに従って修正し再実行する。**step 7/10 より前(safe-broadcast 呼び出し前)の exit 1 なら broadcast は未発生。step 7/10 以降(safe-broadcast 自体の失敗を含む)の exit 1 は broadcast が既に成功している場合がある**(tx は testnet 上に残る) | メッセージ(と `safe-broadcast exit rc=` 行があればその値)を読んで修正、再実行 |
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
  new)` に、**unlock と同じ 32 文字を入れる**。空 Enter は**既存の password
  でロックする代わりに新規 password を作成する**(`docs/CYCLE_GATE.md:617-618`
  「an empty Enter here creates a NEW password instead of locking with the
  existing one」)。厳禁。

### ピング 2 — 操作⑤(打つのは AI、見るのは operator)

7b(§1.2)の実行が済んだら、operator は出力**中ほど**(末尾ではない —
§1.2 の warning 参照)の 3 行を目視する。以下は実装の verbatim 出力
(`scripts/preview-cycle-anchor-broadcast.sh:195,286,332` — 本タスクで
`grep -n` して確認済み。先頭の空白 2 個を含む):

```
  ✓ byte-for-byte identical to git show HEAD:public/api/anchor-source.json
  ✓ published copy matches committed bytes — the receipt's url+sha256 will agree
  memo count (expect 4): 4
```

1 行目の直後には continuation の 2 行(`(= the bytes step 6 committed
locally. …)`)が続くが、これは同じ `✓` 行の説明であって別のチェック項目では
ない — 無視してよい。

3 行とも上記の形(`✓`/`memo count` で始まり、上記の文言を含む)であれば OK。
1 行でも文言が丸ごと違えば(欠落・`✗`・エラー等)AI に報告する
(commit/push/deploy のタイミング差、または `anchor-source.json` の不一致の
可能性がある — 原因の切り分けは AI が行う)。

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
| **F1** | mainnet gate 1 と gate 4 は testnet 実行では 1 行も動かない。`bin/safe-broadcast:250` の `if [ "$IS_MAINNET" = "1" ]` が gate 1(`:251-374`)と gate 4(`:376-435`)の全体を囲む — testnet 実行(`IS_MAINNET=0`)が通るのは gate 2(`:438-466`)/ gate 2b(`:468-526`)/ §3.5 keystore guard(`:528-536`)/ gate 3(`:538-563`)のみ(行範囲は本タスクで実装を直接確認)。**緩和材料**: このコードは 2026-07-31 以降 0 commit(`git rev-list --count`、本タスクで実測)。2026-08-04 の cycle-4 転換で実走済みという記録は RH 調査 / project memory 由来で、本タスクでは再実行して確認していない。**残る不確実性**: 8/4 は memo prefix `fya1c4`、9/4 は `fya1c5` — 桁上がりの無い同型 shape のはずだが、これは推論であって実測ではない | `bin/safe-broadcast` 実装(行範囲は本タスクで直接確認、8/4 実走の事実は RH 調査由来) |
| **F2** | mainnet の chain_id / RPC 到達性 / account 状態は稽古で一切保証されない。9/4 に `bin/safe-broadcast` の gate 3(`:538-563`)が初めて実測する | `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`「Scope: what a rehearsal run actually proves」 |
| **F3** | unit 9(`resume-after-cycle-start.sh`)の freshness poll と identity 署名検証は 9/1 に発火しない。idempotency check(`:194-198`)が先にあり、cycle 4 は 2026-08-04 の転換時点で既に承認済みのため、今日 `--dry-run` すると即 `PASS: idempotent skip` で抜ける。→ **公開 `anchor-source.json` の `dag_root_computed` 変化の poll と、`identity.json` / `.sig` / pubkey 3 点の `ssh-keygen -Y verify` は 9/4 が初回** | `resume-after-cycle-start.sh:139,194-279`(本タスクで再確認) |
| **F4** | cycle 境界でしか動かないコードは 9/1 に動かない — `uptime-history.sh` の Job B(`Closed cycle #<N>` / `uptime-cycles.json` 追記 / `uptime-recent.json` 再生成)、`gen-cycle-history.sh` の「新規行を 1 行追加する」経路、`append-anchor-history.sh` の invariant 4/6(cycle_number 単調増加 / prev_anchor_tx_id 連鎖)の実運用検証はいずれも境界が来るまで発火しない | `docs/CYCLE_GATE.md` step 2/3/8 |
| **F5** | step 0(Metal Wallet で AddValidator submit)と mainnet broadcast 認可(unit 7c)は、稽古する手段が**構造的に存在しない**。前者は wallet UI の仕様が当日まで確認できない — `docs/VALIDATOR_RENEWAL.md:112` の verbatim 引用:「**Wallet UI は変わり得るため、当日 Step 1 (準備 check) の段階で一度 Add Validator フォームを開き、Start Time 欄の有無 / End Time の入力形式を目視確認すること。**」。後者は不可逆かつ per-invocation 認可を要する(§3.4 / PRIME DIRECTIVE) | `docs/VALIDATOR_RENEWAL.md:112`、`bin/safe-broadcast` gate 1 |
| **F6** | `--status` の green は「全部終わった」を意味しない。14 単位のうち **5 つ**(7a / 7b / {7.5, 8, 8.5})がどの事後条件にも入らない — `scripts/cycle-transition.sh --status` を本タスクで実際に実行して確認、出力 verbatim:「FIVE OF THE FOURTEEN EXECUTION UNITS ARE COVERED BY NO POST-CONDITION」「1. UNIT 7a … 2. UNIT 7b … 3. UNITS 7.5, 8 AND 8.5 …」。とくに 7.5 / 8 / 8.5 を丸ごと飛ばしても、その日の `--status` は 5 条件すべて green を返しうる — その場合 on-chain には刻まれているのに公開 `anchor-receipt.json` / `anchor-history.jsonl` は前 cycle を配り続ける。**別種の穴として** unit 4b の registry 編集がある — これは「5 つ」の一員ではなく、**部分実施のときだけ**観測されない: 出力 verbatim「a wholly skipped 4b **does** show up — but doing the commit WITHOUT the … edits leaves every post-condition here green while `tests/publication-registry/` goes red on main」。つまり identity.json の commit に 4b の registry 編集を**含め忘れた**場合だけ `--status` は気づかない(4b をまるごとやらなかった場合は Phase 2 が観測する)。どちらの穴も稽古では埋まらない — 9/4 当日は目視 checklist で補う必要がある | `scripts/cycle-transition.sh --status`(現在の canonical cycle 番号を渡して)実行結果(2026-08-17、本タスクで実測。rc=70) |
| **F7** | 稽古と本番で「実行するファイル」が同一である保証は 9/1 時点では無い — `docs/cycle-transition-steps.json` が指す当日 script(9/1 以降に変更されれば稽古との差分になる)。凍結ポリシーは §5 | `docs/cycle-transition-steps.json` |

---

## 5. 凍結ポリシー

**適用ウィンドウ**: 9/1 の稽古完了後から 9/4 の cycle 転換完了まで。

**対象・ルール本体**は `docs/CYCLE_GATE.md`「Script freeze around a rehearsed
transition」節を正とする(script の一覧はここでは再掲しない — 一覧を 2 箇所に
持つと片方が古くなる。正本は `docs/cycle-transition-steps.json` の
`steps[].scripts`、および `docs/CYCLE_GATE.md` の当該節がそれに追加で明記する
enforcement / 共有ライブラリの範囲)。凍結の対象外への変更(上記正本が列挙しない
もの、例: `docs/STRATEGIC_TARGET_ALIGNMENT.md`)はこの間も通常どおり可能。

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
