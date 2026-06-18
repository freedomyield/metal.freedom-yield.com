# Tahoe testnet 検証パイプライン

ローカル PC で Metal Blockchain validator パイプラインを資金ゼロで検証する完全な手順。
mainnet 移行前のリハーサル用([docs/MAINNET_MIGRATION.md](MAINNET_MIGRATION.md) と合わせて参照)。

## 全体の流れ

```
1. ローカル metalgo 起動 (make node-up)
   ↓
2. NodeID 取得 (make node-status → public/api/validator.json)
   ↓
3. Tahoe Wallet を作って X-Chain アドレスを得る ← ユーザー手動
   ↓
4. Faucet で testnet METAL を貰う ← ユーザー手動
   ↓
5. P-Chain にトークンを移す(X → P クロスチェーン送金) ← ユーザー手動
   ↓
6. 自分の NodeID にデレゲート tx 送信 ← ユーザー手動
   ↓
7. validator set に入ったか確認 (make check-validator)
```

ステップ 3-6 は wallet 操作なのでスクリプトで自動化できない。
ステップ 7 は P-Chain API で確認可能 → script で自動化済。

## 前提

- 本リポを clone 済み
- `make node-up` で metalgo が Tahoe で起動済
- `make node-status` で NodeID 取得済 (`public/api/validator.json` の `nodeId` 欄)

## ステップごとの詳細

### 1. ローカル metalgo を起動

```sh
make node-up
make node-status
```

`make node-status` の出力で NodeID が `NodeID-XXXX...` 形式で出ることを確認。
Bootstrap が P/X/C-Chain すべて `true` になるまで待つ(数十秒〜2 分)。

### 2. Tahoe Wallet を作成

ブラウザで [Metal Web Wallet](https://wallet.metalblockchain.org/) を開く。

⚠️ セキュリティ:
- **mnemonic / seed phrase は絶対にスクリーンショット撮影しない / クラウド同期しない / 平文で保存しない**
- 紙にメモ + offline で保管
- testnet 用と mainnet 用は別 wallet にする(後で混乱しないため)

手順:

1. "Create new wallet" を選択
2. パスフレーズ(24 単語)が表示される → 紙に書き留める
3. ネットワーク選択で "Tahoe" を選ぶ
4. X-Chain アドレス(`X-tahoe1...` で始まる)をコピー

### 3. Faucet で testnet METAL を取得

[Tahoe Faucet](https://faucet.metalblockchain.org/) を開く。

1. ステップ 2 でコピーした X-Chain アドレスを貼り付け
2. captcha 等を解いて request
3. 数秒〜数十秒で wallet に testnet METAL が届く(数値は時期で変動、validator 用に 1 METAL あれば足りる)

### 4. X-Chain → P-Chain にクロスチェーン送金

validator stake は **P-Chain** で行うので、X-Chain で受け取った METAL を P-Chain に移す。

Wallet 画面で:

1. "Cross-chain transfer" or "Move tokens" を選択
2. From: X-Chain, To: P-Chain
3. 金額を入力(後の手数料分も少し残す。例: 1.1 METAL 移動して 1 METAL を stake、残り 0.1 を手数料用)
4. 送信 → 数秒で完了

### 5. 自分の NodeID に delegation tx 送信

Wallet 画面で "Earn" → "Add Delegator" を選択。

1. **NodeID**: `make node-status` で取得したローカル PC の NodeID
2. **Start Time**: 5-10 分後を選ぶ(同期遅延を吸収)
3. **End Time**: 2 週間後(testnet 最短)
4. **Stake amount**: 1 METAL(testnet 最小)
5. Reward address は自分の P-Chain アドレスでよい
6. Confirm → tx 送信

📝 **delegator として送るのではなく、validator として送る場合**:
- "Earn" → "Add Validator" を選ぶ
- 同じパラメータ + delegation fee(testnet では任意。本番は operator-chosen, above 2% protocol floor)
- ⚠️ validator として登録するには **2 weeks lock** が始まる(stake は引き出せない)
- testnet なので失っても問題ないが、testnet METAL の供給は限定的なので消費に注意

### 6. validator set 入りを確認

```sh
make check-validator
```

(後述の `scripts/check-validator.sh` を Makefile 経由で呼ぶ)

出力例:
```
NodeID-9pBEMV9fmZQMJnUERvyJ6XWcA6bZGar3M を P-Chain で検索中...

Pending validators (start time 待ち): 1 件マッチ
  → 開始時刻: <start-time>
  → stake: 1000000000 nMETAL (= 1.0 METAL)
  → end time: <end-time>

Current validators (active): 0 件マッチ(まだ未開始)
```

start time 到達後に再度実行すると `Current validators` 側に出てくる。

### 7. uptime 観測

active 入り後、`make node-status` で `uptime.network` が反映されるようになる。
ローカル PC では port 9651 が外部から見えないので、**期待値は 0**(uptime ゼロ評価)。

これは仕様通り。「自分のノードからは正常動作している」だけが分かる状態。

## 想定エラー / トラブルシューティング

| 症状 | 対処 |
|---|---|
| Faucet で "address already funded" | 同じアドレスでは 24h くらい cooldown あり。別アドレスを作るか待つ |
| Wallet で X→P 移動が完了しない | 数分待つ。それでも reflect されなければブラウザ再読込・wallet 再ログイン |
| `addValidator` tx が "insufficient funds" | 手数料(0.001 METAL 程度)分を残してなかった。faucet で追加取得 |
| `make check-validator` で何も出ない | tx がまだ confirm されていない、または mempool で待機中。数分後に再試行 |
| `info.getCurrentValidators` で NodeID が出ない | start time にまだ到達していない可能性。指定した start time を確認 |
| validation 終了後に何もアクションが起きない | testnet 仕様。delegation/validation は自動で end time に終了し、stake と reward が wallet に戻る |

## delegation を解除したい / 早く切り上げたい

**できない**。Avalanche family の delegation/validation はロック期間中はキャンセル不可。
end time まで待つしかない。testnet では経済価値ゼロなので影響なし。

## 完了後

Tahoe で全プロセスを 1 回通したら、[docs/MAINNET_MIGRATION.md](MAINNET_MIGRATION.md) に
移って mainnet 用の手順に進む。同じ流れだが資金・サーバ・key の取り扱いがより厳格になる。

## 関連

- [docs/KEY_ROTATION.md](KEY_ROTATION.md) — staking key の場所・backup・漏洩対応
- [docs/MAINNET_MIGRATION.md](MAINNET_MIGRATION.md) — mainnet 移行の差分
- メモ `feedback_security_first.md` — seed phrase 等の取り扱い方針
