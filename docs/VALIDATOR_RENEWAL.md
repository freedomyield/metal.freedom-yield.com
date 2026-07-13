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
| **新 Start Time** | **発行時の Unix 秒 + 600(10 分)** |
| **新 End Time** | **新 Start Time + duration in seconds**(30 日なら 2,592,000) |

> 発行時点で `date +%s` で「今の Unix 秒 + 600」を計算して Start Time にコピペ、End Time = Start Time + duration。
> Metal Wallet web の Start/End Time 欄は **Unix 秒入力** が確実(date picker は timezone 取り違え事故あり)。
> 期間後発行モードでは、旧期間 endTime を経過していることが大前提。発行前に画面右上の Available (P) が想定値(旧 stake + reward 解放後の額)に増えていることを目視確認。

#### Field 一覧

| Field | 値 |
|---|---|
| Node ID | `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v`(同 NodeID で連続) |
| BLS Public Key | (Step 1.4 で取得) |
| BLS Proof of Possession | (Step 1.4 で取得) |
| Start Time | 上表の **新 Start Time epoch** をコピペ |
| End Time | 上表の **新 End Time epoch** をコピペ |
| Stake Amount | operator-chosen METAL (= NN × 10^9 nMETAL) |
| Delegation Fee | operator-chosen % |
| Reward Address | operator-local notes 参照(自 P-Chain) |
| Delegation Reward Address | typically same as Reward Address |

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

### Case A: Start Time を旧期間終了より **前** に設定してしまった

- tx は拒否される(同 NodeID で重複期間は不可)
- 別の Start Time で再投入。tx fee は還ってこないが大した金額ではない

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
- `scripts/resume-after-cycle-start.sh` (= active): 新サイクル開始確認 + state file 更新 + broadcast trigger + 7 条件 PASS 検証

State file: `/var/lib/freedom-yield/cycle-gate-state.json` (= operator 承認済の cycle signature + dag_root_hash を保持)

詳細仕様 + behavior matrix + rollback 手順は `docs/CYCLE_GATE.md` 参照。

### 廃止される手動操作 (= 旧 11-step との差分)

| 旧 step | 廃止理由 |
|---|---|
| 旧 step 2: `/etc/cron.d/metal-anchor-watch` 一時 disable | cycle-gate.sh が approval state を見て自動 defer、 cron 常時 enable で安全 |
| 旧 step 12: 同 re-enable | 上記の対称で廃止 |
| 旧 step 8: `uptime-history.sh` 手動 trigger | AI が resume orchestration 内で trigger |
| 旧 step 9: `gen-cycle-history.sh` + push 手動 trigger | 同上 |
| 旧 step 11: `post-anchor-event.sh` 手動 trigger | `resume-after-cycle-start.sh` 内部の Phase 3 で sync trigger |

### operator の能動操作 (= 4 active actions のみ)

[[feedback_ai_full_orchestration_default]] model α 前提。 operator は以下 4 アクションのみを能動的に実行、 残りは AI が orchestrate:

| # | 操作 | 場所 | 入力 |
|---|---|---|---|
| 1 | AI に「cycle 切替お願い」 と依頼 | (= 任意の channel) | (= なし) |
| 2 | wallet 操作 (= 集約 → 送金 → cross-chain → AddValidator → on-chain Committed 確認) | Metal Wallet web | stake 額 + duration + reward address |
| 3 | 鍵 password / passphrase 入力 (= HOME=~/.metal-fy-proton proton key:unlock + identity key 復号) | AI が立ち上げる TTY prompt | Dashlane に保管された 2 secret |
| 4 | explorer URL を visual 確認 | XPR explorer (= AI が URL 報告) | (= 目視のみ) |

### AI が裏で自走する技術 task (= operator から見えない)

- ssh validator host: `uptime-history.sh` + `gen-cycle-history.sh` + `push-to-web-host.sh cycle-history.jsonl` を順次 trigger
- Mac local: `bash scripts/operator-local/gen-identity.sh` (= operator passphrase prompt 発生時に 3 番目の active action)
- Mac local: `git add` + `git commit` + `git push origin main`
- `gh run watch` で GitHub Actions Deploy workflow 完了監視
- ssh validator host: `bash scripts/resume-after-cycle-start.sh --apply` (= Phase 1 polling は attempt 1 で fresh data 発見、 Phase 2-5 同期実行)
- Phase 5 summary を読取、 explorer URL を operator に報告

### 緊急 fallback (= AI 不在時の operator 手動経路)

AI が応答不能な場合、 operator は以下を手動実行:

```sh
# Mac で全部実行
cd ~/htdocs/01_PROJECTS/metal.freedom-yield.com
git pull origin main
export OPERATOR_IDENTITY_KEY=~/.ssh/freedom_yield_operator
bash scripts/operator-local/gen-identity.sh
git add public/api/identity.json public/api/identity.json.sig \
        public/api/identity-history.jsonl \
        public/.well-known/operator-identity.pub
git commit -m "feat(identity): re-sign for new cycle"
git push origin main

# GitHub Actions Deploy 完了を待つ (= Actions tab 目視 or `gh run watch`)

# The validator host で resume-after-cycle-start.sh を 1 行で trigger
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --apply'

# Phase 5 summary に explorer URL が出力される。 visually verify。
```

Phase 1 の identity.json polling は最大 10 分待ち、 deploy 完了 timing が不明でも安全に走る。

### dry-run 経路

承認前に Phase 1 の検証だけを行いたい場合:

```sh
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
    'sudo -u deploy bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --dry-run'
```

state file 書込 / broadcast / 7 条件 check は実行されず、 Phase 1 PASS のみ報告。

### rollback (= 設計を一時無効化)

3 段階、 軽い順:

1. `rm /var/lib/freedom-yield/cycle-gate-state.json` → 次回 `resume-after-cycle-start.sh` まで gate 無効化 (= backward compat)
2. `chmod -x /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh` → gate consultation 完全無効化
3. 全 commit revert → 旧 11-step に完全復帰

詳細は `docs/CYCLE_GATE.md` の Rollback section 参照。

---

## 関連

- `docs/CYCLE_GATE.md` — 2-component 設計詳細 + state file schema + behavior matrix + rollback
- `docs/MAINNET_REGISTRATION.md` — 初回登録時のチェックリスト
- `docs/KEY_ROTATION.md` — 鍵運用
- `docs/DISASTER_RECOVERY.md` — VPS 障害時の対応
