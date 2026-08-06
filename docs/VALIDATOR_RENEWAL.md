# Validator 再登録手順(VALIDATOR_RENEWAL)

現バリデート期間終了前に **再 AddValidator tx を発行** し、同 NodeID で連続稼働させる手順書。月次サイクル(~30 日)で繰り返し実行する SOP。

> 期限を逃すと validator が P-Chain から消える。同 NodeID で再登録可能だが、消失期間中の uptime はカウント不能、delegator もリセット。

> **適用版バナー (2026-06-29 16:40 JST update)**:
> - **2026-07-04 cycle 3 開始 transition + 以降全 transition**: 本書末尾の **「新 SOP (= cycle-gate + resume 設計、 2026-06-29 deployed)」** section を使用。 手動 cron disable/enable は廃止、 operator 能動操作は wallet + passphrase + visual verify のみ。
> - **本書 Step 1 〜 Step 3 (= 旧 11-step) + Phase α canonical memo**: deploy 前の **歴史記録 / 緊急 rollback 時の fallback**。 cycle-gate state file rm + cycle-gate.sh chmod -x で旧 behavior に戻せる (= 3 段階 rollback 手順は `docs/CYCLE_GATE.md` Rollback section)。
> - 切替の根拠: `docs/CYCLE_GATE.md` 全文。 cycle-gate は 2026-06-29 15:09 JST に T-7 deploy 完了済 + 第 7 ラウンド独立監査 PASS。

---

## 全体タイムライン(各サイクル)

ntfy 通知 4 ポイント(JST 基準、1 サイクル 1 回ずつ発火):

| タイミング | アクション | 通知 priority |
|---|---|---|
| **T-7 日** | 来週判断: 次回 duration と stake 額を確定 | default |
| **T-1 日** | 明日 action day。Wallet ロード確認 + BLS PoP / NodeID 値の照合 | default |
| **T-0 日(当日)** | 旧 endTime まで wait。wallet を開いてフォームをコピー可能な状態に | default |
| **T-10 分前** | 旧 stake 解放間近 = 実 action moment。発行手順 Step 2 を即実行 | **urgent** |

**運用モード別の action moment**:
- **期間中発行モード**(P-Chain FREE ≥ 新 stake のとき、default): T-2 日中に Pending 投入してリトライ余裕 48h 確保
- **期間後発行モード**(P-Chain FREE < 新 stake のとき): T-0 の endTime 直後 = 旧 stake 解放後に発行

---

## Step 1: T-7 〜 T-1 — 準備

### 1.1 残日数確認

- サイト `https://metal.freedom-yield.com/` の "Period ends" 行で残日数 / endTime 確認
- または validator host で:
  ```sh
  ssh -i ~/.ssh/<your_validator_host_key> root@<vps-ip>
  cd /opt/metal-validator
  bash scripts/node-info.sh | grep -E "endTime|Self-stake|Total weight"
  ```

### 1.2 次回 duration の確定

| Duration | 適用条件 |
|---|---|
| **14 日(プロトコル最短)** | 短期で方針変更したい時 |
| **30 日** | 標準サイクル(default) |
| **3 ヶ月** | 運用負荷を下げたい |
| **1 年(最長)** | 長期 commitment |

判断軸の詳細は operator-local notes 参照。

### 1.3 wallet 残高と stake 額の決定

- Metal Wallet web で wallet をロード(reward 受取先の P-address は operator-local notes 参照)
- **FREE 残高チェック**(期間終了前に tx を出す場合の前提条件):
  - 現 self-stake は validator にロック中 → 新 tx は **別の FREE P-Chain 残高** から賄う必要あり
  - 必要 FREE 残高 ≥ **新 stake 額 + 0.001 METAL**(P-Chain tx fee マージン)
  - 不足時の事前 inject(T-7 day 中に完了させる):
    1. external source または別 wallet から **X-Chain** に transfer
    2. wallet の Cross-Chain で **X-Chain → P-Chain** export/import(5〜15 分 + 1 confirmation)
    3. P-Chain 着金を Metal Wallet web で確認、`scripts/check-validator.sh` でも cross check 可能
  - 期間終了後に発行する場合のみ: 解放された旧 stake + 報酬がそのまま新 tx の原資になるので事前 inject 不要
- **stake 額の決定方針**:
  - 前期間 self-stake + 前期間中報酬 + 外部 capital(その期間に流入した分)を合算
  - 結果値を新 tx の Stake Amount に入れる
  - `max_weight = 5 × self` のルール上、self-stake を増やすほど delegation 受入枠も連動拡大
- delegationFee は据え置きが原則(変更すると delegator から見て不安定に映る)

### 1.4 BLS Proof of Possession の取得

validator host で `info.getNodeID` を叩き `nodePOP` フィールドを取得。Metal Wallet web の Add Validator フォームに貼り付けるため。

```sh
ssh -i ~/.ssh/<your_validator_host_key> root@<vps-ip> \
  'curl -sS -X POST -H "content-type:application/json" \
     --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.getNodeID\"}" \
     http://localhost:9650/ext/info' | jq '.result.nodePOP'
```

期待される値(staker key 不変なら毎期同じ):
- `publicKey`: `0x8a95c07e0148b662505e1dd913cf988745050b27eb75f7bb81b02f298b5fa81d0cc8c7d0fff090342c4e61ed725787a8`
- `proofOfPossession`: `0x923efda8f4fcd1e2ad80a7ea5c467cf780aa22f9c6a689631735bb4b2c9aa4e4feb04108161c148d7ba6e9ce4d4b2baf0ffe93e85e3434e2cb9c756bc03e84d31db1c418221f2ea821a9b58a0b29147b3055d45ccbca37edd9c4b17d5ce6d023`

→ operator-local notes の確定値と一致するはず。差異があれば BLS key が変わっている = アラート、まず原因究明。

---

## Step 2: tx 発行(モード別)

- **期間中発行モード**(P-Chain FREE ≥ 新 stake): T-2 日中に Pending 投入が default、リトライ余裕 48h
- **期間後発行モード**(P-Chain FREE < 新 stake): T-0 日 endTime 直後に発行、解放された旧 stake + reward が新 tx の原資

### 2.1 Metal Wallet web を開く

`https://wallet.metalblockchain.org/` で wallet (24 語 mnemonic) をロード。**P-Chain** を選択。

WebAuth wallet は mnemonic 非互換(AddValidator は Metal Wallet web 専用)。

### 2.2 Add Validator フォーム入力

#### Time 計算

| 値 | 計算方法 |
|---|---|
| 旧期間 endTime | operator-local notes に記録された epoch |
| **新 Start Time** | **入力欄なし** — submit 後、wallet 側が自動で「submit 時刻 + 5 分」に確定する |
| **新 End Time** | date picker で「新 Start Time(≈ submit 時刻 + 5 分)+ duration」に相当する日付を選択 |

> 旧 11-step 時代の記述(`date +%s` で Unix 秒を計算して Start/End Time にコピペ)は実機の Metal Wallet web と不一致。実機観測(cycle 3 時点)では **Start Time 入力欄自体が無く**、submit 後の auto+5min で確定する。End Time は Unix 秒直接入力ではなく **date picker** で日付を選ぶ。
> **Wallet UI は変わり得るため、当日 Step 1 (準備 check) の段階で一度 Add Validator フォームを開き、Start Time 欄の有無 / End Time の入力形式を目視確認すること。**
> 期間後発行モードでは、旧期間 endTime を経過していることが大前提。発行前に画面右上の Available (P) が想定値(旧 stake + reward 解放後の額)に増えていることを目視確認。

#### Field 一覧

| Field | 値 |
|---|---|
| Node ID | `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v`(同 NodeID で連続) |
| BLS Public Key | (Step 1.4 で取得) |
| BLS Proof of Possession | (Step 1.4 で取得) |
| Start Time | **入力欄なし**(submit 後、自動で「submit 時刻 + 5 分」に確定) |
| End Time | date picker で上表の **新 End Time** に相当する日付を選択 |
| Stake Amount | operator-chosen METAL (= NN × 10^9 nMETAL) |
| Delegation Fee | operator-chosen % |
| Reward Address | operator-local notes 参照(自 P-Chain) |
| Delegation Reward Address | typically same as Reward Address |

> **2026-08-04 cycle-4 実測の追加注意**:
> - **Stake Amount に画面上の MAX/全額表示をそのまま入れない**: 手数料 + おつり分の余裕がなくなり
>   `UTXOSet.getMinimumSpendable: insufficient funds` で送信が失敗する。想定額から端数を
>   少し切り下げて入力する。
> - **End Time の「Max」表示は当てにならない**: 実測ではこの表示が 21 日相当だったが、
>   date picker では 30 日先の日付も選択可能だった。表示された Max を duration の上限だと
>   思い込まず、date picker で希望の日付を直接選ぶ。

### 2.3 Tx 確認 + 送信

- フォームを送信 → wallet 確認画面で **全 field を再確認**
- 特に **NodeID の typo** がないか、**Start Time が旧期間終了より後** か、**Stake Amount が想定通り** か
- 送信 → tx ID を operator-local notes に記録(リポには commit しない)
- explorer で tx が Committed になることを確認(通常 1-2 分)

### 2.4 P-Chain 登録の確認

```sh
ssh -i ~/.ssh/<your_validator_host_key> root@<vps-ip>
cd /opt/metal-validator
bash scripts/node-info.sh
```

期間終了前に発行した tx は **`platform.getPendingValidators`** に Pending として表示される。期間終了瞬間に Current へ昇格。

---

## Step 3: T-0(期間切替日)— 切替確認

### 3.1 旧期間終了 + 新期間昇格の確認

旧 endTime を過ぎたら:

```sh
bash scripts/node-info.sh
```

期待:
- `endTime` が新期間の値に切り替わっている
- `Self-stake` が新 stake 額(増額していれば)で表示される
- `Total weight` も新 self-stake に応じて更新
- 新 validator entry の uptime は 0% からスタート(chain レベルでは新 instance 扱い)
  - サイト側の歴史 uptime 表示は別途累積管理

### 3.2 ステーキング報酬の確認

Metal Wallet web の P-Chain で **旧期間の stake + 報酬** が解放されているか確認。

報酬概算: `stake × duration × 年率 × uptime_factor`

### 3.3 サイト validator.json の更新

cron で自動更新されるが、即時確認したい場合:

```sh
ssh -i ~/.ssh/<your_validator_host_key> root@<vps-ip>
cd /opt/metal-validator && bash scripts/node-info.sh
cat public/api/validator.json | jq '.endTime, .stake.self'
```

→ サイト `https://metal.freedom-yield.com/` をリロードして "N days left" の値が新 duration に基づいた数字になっているか目視。

### 3.4 ntfy 通知の確認

新期間に入ると `check-anomalies.sh` が `DAYS_LEFT > 14` を検知して period_alert_sent flags を全 false にリセットするため、次サイクルの T-7 / T-1 / T-0 / T-10min alert が自動的に再武装される。手動操作不要。

---

## 失敗ケースと復旧

### Case A: 旧期間 endTime を経過する前に submit してしまった

- Start Time は入力欄が無く submit 時刻 + 5 分で自動確定するため(Step 2.2 参照)、submit 自体を旧期間 endTime より十分後に行う必要がある
- 旧期間 endTime 経過前に submit すると、自動確定した Start Time も旧期間 endTime より前になり、tx は拒否される(同 NodeID で重複期間は不可)
- Metal Wallet web の Available (P) が想定値(旧 stake + reward 解放後の額)に増えていることを目視確認してから再度 submit。tx fee は還ってこないが大した金額ではない

### Case B: BLS Proof of Possession が間違っている

- tx は通るが新 entry の BLS が壊れる → validator が consensus に参加できない
- 期間中ロックなので待つしかない、または BLS key を回し直す([docs/KEY_ROTATION.md](KEY_ROTATION.md))

### Case C: 期限を完全に逃した

- 旧期間終了で validator entry が消える
- stake + 報酬は P-Chain wallet に解放(資金は失われない)
- 同 NodeID で改めて AddValidator(Start Time は即時 + duration 自由)
- ただし validator 消失期間中の uptime はゼロ評価、再開後ゼロから積み直し
- delegator がいた場合は連動解放

### Case D: VPS が落ちている

- まず VPS の復旧を優先([docs/DISASTER_RECOVERY.md](DISASTER_RECOVERY.md))
- 復旧後に Step 1.4 から再実行
- 復旧に時間がかかる場合は Case C の流れに移行

---

---

## 新 SOP (= cycle-gate + resume 設計、 2026-06-29 deployed、 2026-07-04 cycle 3 開始 transition から適用)

> **適用状況 (= 2026-06-29 16:40 JST update)**: ✅ **T-7 deploy 完了 2026-06-29 15:09 JST**、 production active。 2026-07-04 cycle 3 開始 transition (= 5 日後) から本 SOP を live で使用。 上記 Step 1 〜 Step 3 (= 旧 11-step) は historical reference + 緊急 rollback 時の fallback。

### 設計概要

2 component:

- `scripts/cycle-gate.sh` (= passive): 各 cron が broadcast 直前に「現サイクルは operator 承認済か」 を問い合わせる
- `scripts/resume-after-cycle-start.sh` (= active、v2 = 3 phase): Phase 1 新サイクル開始確認(6 check)+ Phase 2 state file atomic 更新 + Phase 3 report。**broadcast はしない**(anchor 刻印は本書「AI が裏で自走する技術 task」記載の別 Mac-side pipeline が担う)

State file: `/var/lib/freedom-yield/cycle-gate-state.json` (= operator 承認済の cycle signature + dag_root_hash を保持)

詳細仕様 + behavior matrix + rollback 手順は `docs/CYCLE_GATE.md` 参照。

### 廃止される手動操作 (= 旧 11-step との差分)

| 旧 step | 廃止理由 |
|---|---|
| 旧 step 2: `/etc/cron.d/metal-anchor-watch` 一時 disable | cycle-gate.sh が approval state を見て自動 defer、 cron 常時 enable で安全 |
| 旧 step 12: 同 re-enable | 上記の対称で廃止 |
| 旧 step 8: `uptime-history.sh` 手動 trigger | AI が resume orchestration 内で trigger |
| 旧 step 9: `gen-cycle-history.sh` + push 手動 trigger | 同上 |
| 旧 step 11: `post-anchor-event.sh` 手動 trigger | `post-anchor-event.sh` は v2 migration (2026-07-06) で retired。anchor 刻印は `resume-after-cycle-start.sh` とは独立した、Mac-side の `sign-anchor-event.sh` (via `bin/safe-broadcast`) が担う。`resume-after-cycle-start.sh` は cycle-gate 承認 state の書込のみ |

### operator の能動操作 (= 4 active actions のみ)

[[feedback_ai_full_orchestration_default]] model α 前提。 operator は以下 4 アクションのみを能動的に実行、 残りは AI が orchestrate:

| # | 操作 | 場所 | 入力 |
|---|---|---|---|
| 1 | AI に「cycle 切替お願い」 と依頼 | (= 任意の channel) | (= なし) |
| 2 | wallet 操作 (= 集約 → 送金 → cross-chain → AddValidator → on-chain Committed 確認) | Metal Wallet web | stake 額 + duration + reward address |
| 3 | 鍵 password / passphrase 入力 (= HOME=~/.metal-fy-proton proton key:unlock + identity key 復号) | AI が立ち上げる TTY prompt | Dashlane に保管された 2 secret |
| 4 | explorer URL を visual 確認 | XPR explorer (= AI が URL 報告) | (= 目視のみ) |

### AI が裏で自走する技術 task (= operator から見えない)

当日順序(厳守。cycle N の閉じ → cycle N+1 の開始):

⓪ **operator (Metal Wallet web)**: 新 AddValidator を submit → explorer で **Committed** を確認 → `platform.getCurrentValidators` に新 entry が見えることまで確認(host の `node-info.sh` 等)。**これだけが人の手による状態変更で、以降の全手順の前提**(form の field と timing は本書 Step 2 参照)。ブロックは慣習ではなく機械的: 新 entry が chain に出るまで手順⑤ `gen-anchor-source.sh` は **exit 4**(`NodeID ... not present in current validators`)、手順⑨ `resume-after-cycle-start.sh` は **exit 2**(`NodeID=... not in current validators (= AddValidator tx not yet observed?)`)で hard-block する。submit しただけで pipeline を始めない — Committed と chain read の両方を待つ

**AI が chain 状態を確認する手段の注記**: `scripts/broadcast-guard.sh`(tier-1)は `/ext/bc/[XPC]` や bare `/ext/[XP]` 宛の `curl`/`wget` を **read/write を区別せず shape だけで無条件 block** する — `platform.getCurrentValidators` の読み取り専用クエリであっても、AI session からの素の `curl .../ext/bc/P` は broadcast 試行と同様に拒否される。採用済みの回避策は chain に直接問い合わせず、5 分毎の `metal-node-info` cron (`node-info.sh`) が既に書いている `public/api/validator.json` を read し、`endTime` / `observedAt` フィールドをファイルの mtime(≤5 分 = fresh、cron 周期と一致)と突き合わせて鮮度確認すること。**この目的で `broadcast-guard.sh` を無効化しない** — guard は設計上無条件であり、cron 生成物を read するのが AI session から chain 状態を見る正しい経路。
① validator host: node-info tick 待ち — `public/api/validator.json` に新 endTime が反映されたことを確認(古い endTime のまま cycle-recording を走らせると記録がずれるため)
② validator host: `uptime-history.sh`(cycle N close)
③ validator host: `gen-cycle-history.sh` + push — 公開 `cycle-history.jsonl` が 1 行増えたことを実測確認
④ Mac local: `FY_EXPECT_CYCLE=<N> OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity bash scripts/operator-local/gen-identity.sh`(= operator passphrase prompt 発生時に 3 番目の active action)。`FY_EXPECT_CYCLE=<N>` はサイクル切替時 **MANDATORY**(N = 直前に閉じた cycle 番号。手順③の公開反映前に実行すると exit 7 で hard-stop)。続けて `git add` + `git commit` + `git push origin main`、`gh run watch` で deploy 完了監視
⑤ validator host: `FY_EXPECT_CYCLE=<N> bash scripts/gen-anchor-source.sh`(cycle-4 当日の例: `FY_EXPECT_CYCLE=3`)— 新 `anchor-source.json`(3-branch DAG)を compose。`cycle_number_observed` は 公開 `cycle-history.jsonl` の CLOSED_COUNT+1 から自己導出するが、`FY_EXPECT_CYCLE` を渡すと ordering guard が有効になり、CLOSED_COUNT と 不一致(= 手順③がまだ公開反映されていない)なら compose 前に **exit 9** で hard-stop する(未設定なら警告バナーのみで継続、初回 bootstrap 用)。**gen-identity.sh の exit 7 とは別条件** — `gen-anchor-source.sh` では exit 7 は既に「atomic write failed」の意味で使用中のため、意図的に番号を揃えていない(exit 7 と exit 9 を同じ意味と読まない)
⑥ Mac local: `export VALIDATOR_HOST=<validator host の IP or hostname>` + `export VALIDATOR_HOST_KEY=~/.ssh/<your_validator_host_key>` を先に設定した上で `scripts/operator-local/commit-anchor-source.sh --expect-cycle=<N+1>`(cycle-4 当日の例: `--expect-cycle=4`)で host 側 `anchor-source.json` を検証+commit、続けて push + deploy 完了監視(手順④と同じパターン)。**env 2 つは必須の SSH 座標**(repo には literal を置かない方針): `VALIDATOR_HOST` は未設定なら変数名を挙げて即 refuse、`VALIDATOR_HOST_KEY` は **default が literal placeholder** `~/.ssh/<your_validator_host_key>`(実在しない path)なので未設定だと `ERROR: SSH key not found` → **exit 3** になる(`VALIDATOR_HOST_USER` の default は `root`)。**手順⑤との意味の反転に注意**: `gen-anchor-source.sh` の `FY_EXPECT_CYCLE` は「直前に閉じた cycle 番号」(N)だが、このスクリプトの `--expect-cycle` は fetch した `anchor-source.json` の `observations_branch.cycle_number_observed`(= `gen-anchor-source.sh` が `CLOSED_COUNT + 1` として算出する値)と直接一致比較するため「これから刻む cycle 番号」(N+1)を渡す — `N` を渡すと exit 5 で mismatch する。**commit+push+deploy は必須** — 公開されないと手順⑨の Phase 1 polling が exit 3 でタイムアウトする
⑦ Mac local: **⑦ は全て Mac 上で、かつ手順⑥の commit + push が landed した後に実行する**(署名対象は commit / push / deploy 済の bytes でなければ、receipt の `url` + `sha256` が刻んだ `dag_root_computed` を含まないファイルを指してしまう)
  - **⑦-a gate 1 材料(testnet-first)**: `HOME=~/.metal-fy-proton-test proton key:unlock` → `HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<N+1>`(day-of は MANDATORY、`docs/PHASE_ALPHA_TESTNET_DRY_RUN.md` 参照。cycle-4 当日の例: `--expect-cycle=4`)。出力末尾の `TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>` を控える。**この rehearsal 自身の dry-run log は testnet 側の証拠にすぎない** — `target_chain: "testnet-a"` を記録しており、mainnet gate 4 は `--chain` と異なる chain の dry-run log を拒否する。手順⑥が既に landed 済のため、canonical `public/api/anchor-source.json` は既にこの cycle のファイル(`cycle_number_observed == N+1`)— `--source=` override も `--allow-fixture` も不要、default 選択のまま `--expect-cycle=<N+1>` がそのまま通る。**朝のうちに(手順⑥完了前に)hand-built fixture を用意して先に rehearsal する運用は行わない** — その時点の canonical source はまだ前 cycle(`N`)のままで、`N+1` の実 gate-1 evidence を得るには fixture を手作りする必要が生じる。2026-08-04 に実際にこの朝実行を行い、fixture 手作り + dag 再計算の手間とリスク(手順⑥ landed 後の実 source と後で突き合わせる二度手間)が発生した。7a は必ず手順⑥の後、実 canonical source に対して実行する。rehearsal 完了直後に `rm -f /tmp/fyd-broadcast-token` で後始末する(testnet 向けに bound された token は R16 により mainnet ⑦-c に流用できず、5 分 TTL でも自然失効するが、⑦-b/⑦-c の pre-flight 確認時に古い token が `/tmp` に残っているとノイズになるため掃除する)
  - **⑦-b gate 4 材料(mainnet dry run)**: 経路は 1 本だけ。Mac 上で、既に commit 済の `anchor-source.json` から、**recompose せずに** 生成する:
    ```sh
    FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
      bash scripts/preview-cycle-anchor-broadcast.sh \
        --source=public/api/anchor-source.json \
        --testnet-tx-id=<控えた tx id>
    ```
    このスクリプトは source が `git show HEAD:public/api/anchor-source.json` と byte 一致することを検証し(不一致なら exit 9 で拒否)、続けて公開 `anchor-source.json`(cache-bust 付きで fetch)がまだ同じ bytes を配信していなければ **exit 10** で拒否する(push+deploy 待ちしてから再実行。`--skip-published-check` はオフライン/劣化時専用の bypass)。その後 `$DRYLOG`(default `/tmp/fya-mainnet-dryrun.json`)を書き、gate1/gate3 の read-only pre-check を表示し、⑦-c のコマンドを両 gate 引数入りで出力する。compose も broadcast もしない。**validator host の `sudo -u deploy` では実行しない** — §3.5 keystore guard が login HOME を **exit 8** で拒否し、かつ host 側で recompose すると `dag_root_computed` が commit 済 bytes と変わる(artifacts branch は 5 分 cron が書き換える live feed を hash しているため)。pre-check 抜きで log だけ欲しい場合の同等形は `FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton bash scripts/sign-anchor-event.sh --chain=mainnet-a --anchor-source=public/api/anchor-source.json --dry-run > /tmp/fya-mainnet-dryrun.json` — こちらも `FY_CONFIG_DIR` は必須で、無いと exit 3 になり redirect が **0 byte** の log を残す(gate 4 まで気づけない)
  - **⑦-c 署名 + broadcast**: `HOME=~/.metal-fy-proton proton key:unlock` で mainnet keystore(testnet とは別)を unlock し、`FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton bash scripts/sign-anchor-event.sh --chain=mainnet-a --anchor-source=public/api/anchor-source.json --testnet-tx-id=<控えた tx id> --dry-run-log=/tmp/fya-mainnet-dryrun.json`(= operator の 4 番目の active action、`bin/safe-broadcast` 4-gate 経由。`--testnet-tx-id` / `--dry-run-log` は gate 1 / gate 4 の必須入力 — 欠くと safe-broadcast が REFUSE する)。**順序に注意**: どの env-prefix 行でも `FY_CONFIG_DIR=...` を `HOME=...` より前に書く。機序(2026-07-31 実測): **zsh**(operator の login shell)は prefix 代入を左→右で適用し、各代入が次の代入の展開に見えるため、`HOME=~/.metal-fy-proton` が先だと `FY_CONFIG_DIR=$HOME/...` の `$HOME` が keystore を指してしまう。bash は simple command の prefix 代入をコマンド実行前の環境に対して展開するので両順序とも動く(ただし pipeline 内では subshell 化して zsh と同じ挙動になる)。どの shell でも正しい順序で書く。**別の罠(2026-08-04 実測)**: `FY_CONFIG_DIR` の tilde は **quote しない**こと — `FY_CONFIG_DIR="~/.fy-mainnet-broadcast/config"` のように quote すると tilde が展開されず literal `~/...` path になり **exit 3**(config dir not readable)で失敗する。上記の順序を守り quote さえしなければ `~` と `$HOME` は同じ挙動になる(2026-08-04 実測、zsh/bash × 順序 正/誤 の全 4 パターン確認済)— 両者に別の分岐は無い。それでも堅牢性のため**絶対 path**(`/Users/<user>/...` 形)で書くことを推奨する — quote の罠も順序ルールも両方回避できる。`sign-anchor-event.sh` は `--output=<path>` も受け付ける — 未指定時は標準出力に加えて既定 path `/tmp/fya-mainnet-sign-output.json`(mainnet 実行の場合。testnet 実行なら `/tmp/fya-testnet-sign-output.json`)にも保存される。この fragment は **Mac 上で生成される**ため、手順⑦.5 で host へ転送してから手順⑧の `--input=` 値として使う。broadcast 後は mainnet keystore を re-lock する: `HOME=~/.metal-fy-proton proton key:lock`。プロンプトは `Enter 32 character password (leave empty to create new)` と表示されるが、**空 Enter は新規 password の作成になるため厳禁** — unlock 時と同じ 32 文字を入力する
⑦.5 Mac → host: 手順⑦-c の `sign-anchor-event.sh` 出力(既定 `--output=` 保存先 `/tmp/fya-mainnet-sign-output.json`)を host へ転送する。手順⑦-c の散文に埋没していた転送作業を独立 step として明示化(2026-08-06)。host 側で走る手順⑧の `gen-anchor-receipt.sh --input=` が読むのはこの転送先:
  ```sh
  scp -i ~/.ssh/<your_validator_host_key> \
      /tmp/fya-mainnet-sign-output.json \
      "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}:/home/deploy/.fya-sign-output.json"
  ssh -i ~/.ssh/<your_validator_host_key> \
      "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
      'chmod 644 /home/deploy/.fya-sign-output.json'
  ```
  `chmod` は防御的措置: `scp` は `root` として接続する(`VALIDATOR_HOST_USER` は未指定=default `root`)が、手順⑧の `gen-anchor-receipt.sh` は `sudo -u deploy` で走るため、host 側 root の umask 次第では `deploy` から読めないパーミッションになり得る。
⑧ validator host: `gen-anchor-receipt.sh`(7-gate verify、`--prev-anchor-tx-id=` に直前 anchor の tx_id を渡す必要あり)+ `FY_LIVE=1 bash append-anchor-history.sh`(**R18 archive の自動 push には `FY_LIVE=1` が必須**。append 自体は gate されないので FY_LIVE 無しでも台帳行は書かれるが、archive push は `DEFERRED: R18 publish …` として見送られ、手動 push コマンドが表示される。C3 rollout 2026-08-06)(= append 成功直後に R18 archive 2 本を自動 push する。詳細は手順⑧.5)
⑧.5 validator host: 正規(canonical)の flat file 2 本を push する — R18 archive の 2 本とは別物:
  ```sh
  bash scripts/push-to-web-host.sh anchor-receipt.json
  bash scripts/push-to-web-host.sh anchor-history.jsonl
  ```
  これを省くと、on-chain anchor は成功済みでも公開 `/api/anchor-receipt.json` / `/api/anchor-history.jsonl` が前 cycle の内容のまま止まる。手順⑨の Phase 1 は `anchor-source.json` の鮮度しか poll しないため、この push 漏れは検知されない。`anchor-source.json` 自体はこの push の対象外(手順⑥で git-deploy 済、`push-to-web-host.sh` では扱わない)。

  R18 per-anchor archive の 2 本(`archive/anchor-source-<dag_root>.json` / `archive/anchor-receipt-<tx_id>.json`)は、この手動 push の対象では**ない**: 2026-08-06(`77fd09d`)以降、`append-anchor-history.sh` が append 成功直後に自動で push する(best-effort — 失敗しても append 自体は失敗させない)。失敗時は stderr + `notify.sh high` alert に "R18 publish FAILED" / "R18 publish skipped" が出るので、その場合だけ表示された retry コマンドを手動実行する。`FYD_PUBLISH_ARCHIVES=0` で自動 push 自体を無効化できるが、通常の cycle 切替では使わない。
⑨ validator host: `FY_LIVE=1 bash scripts/resume-after-cycle-start.sh --apply`(**`FY_LIVE=1` 必須** — 無いと Phase 1 の前に exit 6 で拒否し、read も poll も write も一切しない。C3 rollout 2026-08-06)(= v2 3 phase: Phase 1 verify 6 check → Phase 2 atomic state write → Phase 3 report。**broadcast なし、explorer URL は出力しない**)

手順⑦の tx id を読取り、explorer URL を operator に報告(resume-after-cycle-start.sh の出力ではなく、手順⑦の broadcast 結果)。

### 緊急 fallback (= AI 不在時の operator 手動経路)

AI が応答不能な場合、 operator は本書「AI が裏で自走する技術 task」の当日順序 ⓪〜⑨(⑦.5 / ⑧.5 を含む)を以下の手順で手動実行する(anchor pipeline の手順を省くと anchor 刻印が欠落する、または刻印済みでも公開 feed が古いままになるので、⑦.5 / ⑧.5 を含め全 step を踏む):

```sh
# ⓪ Metal Wallet web で AddValidator を submit → explorer で Committed 確認 →
#   getCurrentValidators に新 entry が見えるまで待つ(コマンドなし、operator の手作業)。
#   これが済むまで ⑤ は exit 4、⑨ は exit 2 で hard-block する。

# ①②③ validator host で cycle-recording を閉じる(node-info tick 確認 → uptime-history → gen-cycle-history → 公開 push)
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy bash -c "cd /home/deploy/metal.freedom-yield.com && \
       bash scripts/node-info.sh && \
       bash scripts/uptime-history.sh && \
       bash scripts/gen-cycle-history.sh && \
       bash scripts/push-to-web-host.sh cycle-history.jsonl"'
# push-to-web-host.sh が無いと公開 URL の cycle-history.jsonl が進まず、手順④の exit 7 /
# 手順⑤の exit 9 ガードが古いままの行数を読んでしまう。公開 cycle-history.jsonl が 1 行
# 増えたことを実測確認(公開 URL を curl して行数比較)してから次に進む。

# ④ Mac で identity を再生成(N = 直前に閉じた cycle 番号。手順②③の公開反映前に走らせると exit 7)
cd ~/htdocs/01_PROJECTS/metal.freedom-yield.com
git pull origin main
export FY_EXPECT_CYCLE=<N>
export OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity
bash scripts/operator-local/gen-identity.sh
git add public/api/identity.json public/api/identity.json.sig \
        public/api/identity-history.jsonl \
        public/.well-known/operator-identity.pub
git commit -m "feat(identity): re-sign for new cycle"
git push origin main
# GitHub Actions Deploy 完了を待つ (= Actions tab 目視 or `gh run watch`)

# ⑤ validator host で anchor-source.json を compose (N = 直前に閉じた cycle 番号。
#    cycle-history.jsonl の CLOSED_COUNT と不一致なら compose 前に exit 9 で hard-stop)
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy env FY_EXPECT_CYCLE=<N> bash /home/deploy/metal.freedom-yield.com/scripts/gen-anchor-source.sh'

# ⑥ Mac で host 側 anchor-source.json を検証+commit、push+deploy
# --expect-cycle は「これから刻む cycle 番号」(N+1)— ⑤の FY_EXPECT_CYCLE=<N>(閉じた cycle
# 番号)とは意味が反転する。fetch した anchor-source.json の cycle_number_observed
# (= CLOSED_COUNT+1)と直接一致比較するため、N を渡すと exit 5 で mismatch する
# (cycle-4 当日の例: --expect-cycle=4)。
bash scripts/operator-local/commit-anchor-source.sh --expect-cycle=<N+1>
git push origin main
# GitHub Actions Deploy 完了を待つ。この push が無いと⑨の Phase 1 polling が exit 3 でタイムアウトする。

# ⑦-a Mac で gate 1 材料(testnet rehearsal)。day-of は --expect-cycle=<N+1> が MANDATORY
#     (docs/PHASE_ALPHA_TESTNET_DRY_RUN.md 参照。cycle-4 当日の例: --expect-cycle=4)
#     手順⑥が landed 済のため canonical source は既に cycle N+1 — --source=/--allow-fixture は
#     不要。朝(手順⑥前)に fixture を手作りして先行実行しない — 2026-08-04 に朝実行して
#     fixture 手作り + dag 再計算の手間とリスクが発生した。必ず手順⑥の後に実行する。
HOME=~/.metal-fy-proton-test proton key:unlock
HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<N+1>
# 出力末尾の `TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>` を控える(以下 <rehearsal-tx-id>)。
# 完了直後に後始末: testnet 向け token は R16 で mainnet ⑦-c に流用不能・TTL 5 分で失効するが、
# ⑦-b/⑦-c の pre-flight 確認時のノイズ源になるため掃除する。
rm -f /tmp/fyd-broadcast-token

# ⑦-b mainnet gate-4 dry-run-log を Mac 上で生成。手順⑥の commit + push が landed した後に実行し、
#     commit 済 bytes をそのまま使う(recompose しない)。validator host の sudo -u deploy では
#     実行しない — §3.5 keystore guard が login HOME を exit 8 で拒否し、host 側 recompose は
#     dag_root_computed を変えてしまう(artifacts branch は 5 分 cron が書き換える feed を hash)。
#     FY_CONFIG_DIR が無いと sign-anchor-event.sh は exit 3 になり 0 byte の log が残る。
FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
    bash scripts/preview-cycle-anchor-broadcast.sh \
        --source=public/api/anchor-source.json \
        --testnet-tx-id=<rehearsal-tx-id>
# source が git show HEAD:public/api/anchor-source.json と byte 一致しなければ exit 9 で止まる。
# $DRYLOG (default /tmp/fya-mainnet-dryrun.json) が gate 4 の入力。pre-check 抜きの同等形:
#   FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
#     bash scripts/sign-anchor-event.sh --chain=mainnet-a \
#         --anchor-source=public/api/anchor-source.json \
#         --dry-run > /tmp/fya-mainnet-dryrun.json

# ⑦-c Mac で mainnet keystore を unlock して署名+broadcast。
#     --testnet-tx-id / --dry-run-log は bin/safe-broadcast の gate 1 / gate 4 必須入力(欠くと REFUSE)。
#     順序注意: FY_CONFIG_DIR=... は HOME=... より前に書く。機序(2026-07-31 実測): zsh(operator の
#     login shell)は prefix 代入を左→右で適用し次の代入の展開に見えるため、HOME= が先だと
#     $HOME が keystore を指す。bash は simple command なら両順序とも動く(pipeline 内は zsh と同じ)。
#     別の罠(2026-08-04 実測): FY_CONFIG_DIR の tilde は quote しない。
#     FY_CONFIG_DIR="~/.fy-mainnet-broadcast/config" のように quote すると tilde が展開
#     されず literal ~/... path になり exit 3(config dir not readable)で失敗する。上記の
#     順序を守り quote さえしなければ ~ と $HOME は同じ挙動(2026-08-04 実測、zsh/bash ×
#     順序 正/誤 の全 4 パターン確認済)。堅牢性のため絶対 path(/Users/<user>/... 形)を推奨。
HOME=~/.metal-fy-proton proton key:unlock
FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
    bash scripts/sign-anchor-event.sh --chain=mainnet-a \
        --anchor-source=public/api/anchor-source.json \
        --testnet-tx-id=<rehearsal-tx-id> \
        --dry-run-log=/tmp/fya-mainnet-dryrun.json
# tx id を控えて explorer で visually verify。
# sign-anchor-event.sh は --output=<path> も受け付ける。未指定時は標準出力に加え既定 path
# /tmp/fya-mainnet-sign-output.json にも保存される。この fragment は Mac 上で生成されるため、
# 下の⑦.5 で host へ転送してから⑧の --input= 値として使う。

# broadcast 後は mainnet keystore を re-lock する。プロンプト `Enter 32 character password
# (leave empty to create new)` で空 Enter すると新規 password 作成になるため厳禁 — unlock
# 時と同じ 32 文字を入力する。
HOME=~/.metal-fy-proton proton key:lock

# ⑦.5 Mac → host: 上の⑦-c で作った署名 fragment を host へ転送する(2026-08-06 に独立 step 化)。
#     host 側で走る⑧の gen-anchor-receipt.sh --input= が読むのはこの転送先。
scp -i ~/.ssh/<your_validator_host_key> \
    /tmp/fya-mainnet-sign-output.json \
    "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}:/home/deploy/.fya-sign-output.json"
# scp は root として接続する(VALIDATOR_HOST_USER 未指定 = default root)が、⑧の
# gen-anchor-receipt.sh は sudo -u deploy で走る。host 側 root の umask 次第では deploy から
# 読めないパーミッションになり得るため、念のため読み取り権限を明示しておく。
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'chmod 644 /home/deploy/.fya-sign-output.json'

# ⑧ validator host で receipt 生成 + history append。
# gen-anchor-receipt.sh は --input=(上の⑦.5 で host に置いた JSON)と
# --anchor-source=(host 側 anchor-source.json)が必須(欠くと usage error で exit 1)。
# append-anchor-history.sh は --receipt=(gen-anchor-receipt.sh の --out、default
# public/api/anchor-receipt.json)が必須。--event-type はサイクル切替の文脈では
# cyclestart(gen-anchor-receipt.sh 側も --trigger=cyclestart を揃えること)。
# --prev-anchor-tx-id= は他のどこからも自動導出されない(欠くと null 扱いになり、genesis
# 以外では append-anchor-history.sh の invariant 6 で fail する)。値は host 側
# anchor-history.jsonl の最終行 tx_id: `tail -n 1 public/api/anchor-history.jsonl | jq -r '.tx_id'`
# append 成功直後、append-anchor-history.sh 自身が R18 archive 2 本(archive/anchor-source-
# <dag_root>.json / archive/anchor-receipt-<tx_id>.json)を自動 push する(2026-08-06 以降、
# best-effort — 失敗しても append 自体は失敗させない)。canonical な anchor-receipt.json /
# anchor-history.jsonl 本体の push は自動化されていない — 下の⑧.5 で別途行う。
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy bash -c "cd /home/deploy/metal.freedom-yield.com && \
       PREV_TX=\$(tail -n 1 public/api/anchor-history.jsonl | jq -r .tx_id) && \
       bash scripts/gen-anchor-receipt.sh \
         --input=/home/deploy/.fya-sign-output.json \
         --anchor-source=public/api/anchor-source.json \
         --trigger=cyclestart \
         --prev-anchor-tx-id=\$PREV_TX && \
       FY_LIVE=1 bash scripts/append-anchor-history.sh \
         --receipt=public/api/anchor-receipt.json \
         --event-type=cyclestart"'

# ⑧.5 validator host: 正規(canonical)の flat file 2 本を push する — R18 archive の 2 本とは別物。
#     これを省くと on-chain anchor は成功済みでも公開 /api/anchor-receipt.json /
#     /api/anchor-history.jsonl が前 cycle の内容のまま止まる。⑨の Phase 1 は
#     anchor-source.json の鮮度しか poll しないため、この push 漏れは検知されない。
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy bash -c "cd /home/deploy/metal.freedom-yield.com && \
       bash scripts/push-to-web-host.sh anchor-receipt.json && \
       bash scripts/push-to-web-host.sh anchor-history.jsonl"'

# ⑨ validator host で resume-after-cycle-start.sh を trigger(v2 = 3 phase、broadcast なし)
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy FY_LIVE=1 bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --apply'

# Phase 3 の report が出力される(state 更新のみ、broadcast も explorer URL も出さない)。
```

Phase 1 の identity.json polling は最大 10 分待ち、 deploy 完了 timing が不明でも安全に走る。同様に resume-after-cycle-start.sh の Phase 1 も anchor-source.json の polling を最大 `FY_POLL_MAX_SEC`(default 600 秒)待つ。

### dry-run 経路

承認前に Phase 1 の検証だけを行いたい場合:

```sh
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --dry-run'
```

Phase 2(state file 書込)は実行されず、Phase 1 verify(6 check: prior-state read / chain query / idempotency / endTime-in-future / anchor-source.json freshness poll / identity 署名 verify)の結果のみ報告。`resume-after-cycle-start.sh` はそもそも broadcast を行わない。

### rollback (= 設計を一時無効化)

3 段階、 軽い順:

1. `rm /var/lib/freedom-yield/cycle-gate-state.json` → 次回 `resume-after-cycle-start.sh` まで gate 無効化 (= backward compat)
2. **⚠ 使用禁止(通常の cycle transition では使わない)**: `chmod -x /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh`。「gate 無効化」ではなく、cycle 記録系 5 script(`gen-cycle-history.sh` / `uptime-history.sh` Job B / `node-info.sh` / `gen-evidence.sh` / `gen-renewal-ics.sh`)を fail-closed で skip させ公開 feed の記録が止まる操作。`cycle-artifact-write` は既に常時 green なので、この lever でしか relax できない対象はそもそも無い。承認 state を緩めたいだけなら lever 1(state file 退避)を使う
3. 全 commit revert → 旧 11-step に完全復帰

詳細は `docs/CYCLE_GATE.md` の Rollback section 参照。

---

## 関連

- `docs/CYCLE_GATE.md` — 2-component 設計詳細 + state file schema + behavior matrix + rollback
- `docs/MAINNET_REGISTRATION.md` — 初回登録時のチェックリスト
- `docs/KEY_ROTATION.md` — 鍵運用
- `docs/DISASTER_RECOVERY.md` — VPS 障害時の対応
