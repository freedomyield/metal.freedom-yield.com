# Mainnet Validator Registration — チェックリスト

**目的**: wallet から AddValidator tx を発行し、Metal Blockchain mainnet で validator として登録される。

**⚠️ 重要**: tx 送信後、**パラメータは一切変更不可**。期間中(最短 14 日)stake はロック。**1 行ずつチェック**しながら進める。

---

## Pre-flight チェック(tx 送信前)

### サーバ側

- [ ] `metalgo` コンテナが Up かつ healthy
  ```sh
  docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml ps
  ```
- [ ] 3 chain すべて bootstrap 完了
  ```sh
  bash scripts/node-info.sh
  ```
  期待: `P-Chain: true, X-Chain: true, C-Chain: true`
- [ ] NodeID が一致(変わってないこと): `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v`
- [ ] サイトが見える: `https://metal.freedom-yield.com/` が 200

### wallet 側

- [ ] wallet で **Metal mainnet 表示**(testnet ではない)
- [ ] P-Chain 残高 ≥ stake 予定額 + tx fee
- [ ] Wallet アドレスが運用者が記録した値と一致(operator-local notes 参照):
  - C-address (`0x…`)
  - X-address (`X-metal1…`)
  - P-address (`P-metal1…`)

### 文書側

- [ ] 本ファイルを開いた状態で tx 実行(1 行ずつ参照)
- [ ] BLS PoP / NodeID の確定値は operator-local notes で確認(BLS Public Key と Proof of Possession は wallet が自動入力する場合あり)

---

## AddValidator パラメータ表

| 項目 | 値 | 備考 |
|---|---|---|
| **NodeID** | `NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v` | コピペ厳守、typo NG |
| **BLS Public Key** | `0x8a95c07e0148b662505e1dd913cf988745050b27eb75f7bb81b02f298b5fa81d0cc8c7d0fff090342c4e61ed725787a8` | wallet が自動入力する場合あり |
| **BLS Proof of Possession** | `0x923efda8f4fcd1e2ad80a7ea5c467cf780aa22f9c6a689631735bb4b2c9aa4e4feb04108161c148d7ba6e9ce4d4b2baf0ffe93e85e3434e2cb9c756bc03e84d31db1c418221f2ea821a9b58a0b29147b3055d45ccbca37edd9c4b17d5ce6d023` | 同上 |
| **Stake Amount** | operator-chosen, minimum 2,000 METAL | プロトコル下限 = 2,000 METAL |
| **Start Time** | tx 送信時刻 + 余裕(数分〜30 分) | wallet が自動設定する場合あり、必ず未来時刻 |
| **End Time** | Start + duration | 14 日〜1 年で operator が選択 |
| **Delegation Fee** | operator-chosen | プロトコル下限 2%、超過分は operator 判断 |
| **Reward Address** | operator-chosen P-address | 報酬の受取先(自 P-Chain)、operator-local notes 参照 |
| **Delegation Reward Address** | typically same as Reward Address | 委任手数料の受取先 |

---

## 実行手順(wallet で)

1. wallet を開いて **Metal mainnet 表示**を確認
2. **Metal P-Chain** を開く
3. メニューに **「Stake」** or **「Earn」** or **「Add Validator」** がある
4. **Add Validator** を選択
5. 上の **パラメータ表** を 1 行ずつ入力し、各項目を ✅ で確認
6. **Confirm / Review** 画面で **もう一度全項目確認**
7. **Submit / Sign** を押す
8. wallet がトランザクション署名
9. tx hash を記録(operator-local notes へ。本リポには commit しない)

---

## tx 後の検証(数分以内)

- [ ] wallet の Activity に AddValidator tx が表示される
- [ ] `https://explorer.metalblockchain.org/` で NodeID 検索 → 当 validator が表示
- [ ] `bash scripts/node-info.sh` で stake と fee が反映
  ```sh
  bash scripts/node-info.sh
  cat public/api/validator.json | jq '.stake, .delegationFee'
  ```
- [ ] サイト `https://metal.freedom-yield.com/` リロード → Self-stake と Delegation fee に値が入る

---

## 失敗時の対処

| 症状 | 対処 |
|---|---|
| `insufficient funds` エラー | balance < stake + fee。送金不足の可能性、追加送金 |
| `invalid signature` | wallet とサーバの key 不一致(本来あり得ない)。NodeID と署名 key の整合性確認 |
| `validator already exists` | 既に登録済み(再送)。explorer で確認、重複登録の必要なし |
| tx 送信できない / 進まない | wallet の network 設定を確認、 testnet で動作確認してから本番再試行 |
| wallet フリーズ | wallet 再起動、 mnemonic の compatibility を operator-local notes で確認 |

---

## 完了条件

すべて満たせば **登録完了**:

- ✅ `explorer.metalblockchain.org` で NodeID 検索 → "current validator" として表示
- ✅ Self-stake: 入力値
- ✅ Delegation Fee: 入力値
- ✅ Stake End Time: 入力値
- ✅ サイト `/api/validator.json` に反映
- ✅ サイト `/delegate/` に表示

---

## 関連 docs

- [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md) — 登録後の障害対応
- [KEY_ROTATION.md](KEY_ROTATION.md) — staker key 管理
- [VALIDATOR_RENEWAL.md](VALIDATOR_RENEWAL.md) — cycle 終了前の再登録
