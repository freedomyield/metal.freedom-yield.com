# Anchor account (proton A-chain) key rotation runbook

metalfreedom / frdomyieltst など **proton (Metal A-chain) account の permission 公開鍵**を
`updateauth` で差し替える手順。metalgo の staking 鍵 (`staker.key`/`signer.key`) の
ローテーションは別物 — それは [`KEY_ROTATION.md`](KEY_ROTATION.md) を参照。

> **性質**: これは **mainnet broadcast (`updateauth`)** を含む。PRIME DIRECTIVE が全面適用。
> broadcast は operator が `bin/safe-broadcast` 経由でのみ実行。AI は payload 設計・dry-run・
> `get_account` 検証・手順提示に徹し、**broadcast も新秘密鍵の取扱いも一切しない**。

## いつ使うか

- account permission の秘密鍵が露出した疑い (会話ログ・scrollback・screenshot 等)
- 定期ローテーション
- owner/active/anchor の鍵分離をやり直したいとき

## 対象 account の構造 (2026-07-10 実測)

両ネット同型: `owner(root, parent="") → active(parent=owner) → anchor(parent=active)`、各 threshold 1・鍵 1 本。

| account | net | owner | active | anchor |
|---|---|---|---|---|
| metalfreedom | mainnet | 旧74Ec (owner=active 共有) | 旧74Ec | 旧5MMA |
| frdomyieltst | testnet | 旧8fLk (owner=active 共有) | 旧8fLk | 旧6crX |

resource: metalfreedom は CPU/NET/RAM とも潤沢 → updateauth のチャージ不要。

## 到達目標 (owner/active/anchor を全て別鍵に・両ネット構造一致)

各 account で **3 permission = 3 別鍵**。sink 用 account (fyhistory / fyhistorytst) は
**秘密鍵が露出していないので据置** (回さない)。

**鍵の生成元と保管 (重要)**:
- **owner = WebAuth 由来 (新 12word 派生)・cold 保管**。WebAuth 管理/復旧の線を保つため生鍵にしない。
  proton-cli keystore には **置かない** (日常の署名面から root 鍵を外す)。
- **active / anchor = proton key:generate 由来・hot** (proton-cli keystore で自己管理)。

## 絶対規則

1. **owner を最後に回す**。owner を差し替えた瞬間に旧鍵は完全無効。途中失敗しても owner が
   生きていれば復旧できる順序にする。
2. **新しい秘密鍵をチャットに貼らない**。operator が `key:generate` で生成し、vault に保存。
   AI に渡すのは **公開鍵のみ**。
3. **各 updateauth の前に testnet-first** (PRIME DIRECTIVE gate1)。同型 tx を testnet で成功させ、
   その tx_id を mainnet broadcast の `--testnet-tx-id` に渡す。
4. **broadcast は `bin/safe-broadcast` のみ**。生 `proton action`/`transaction:push` は tier-1
   guard が無条件 block。
5. **各段の後に `get_account` で着地検証**してから次へ。
6. keystore の内容更新は **`key:remove` を使わない** (暗号化済 keystore に remove すると IV 破壊の
   proton-cli バグ)。「退避 → 正しい鍵で作り直し」。cf. `reference_proton_keystore_per_project_network_separation`。

## updateauth payload テンプレート

tx JSON (`bin/safe-broadcast --tx=<file>` に渡す形)。`<NEW_*_PUB>` は Phase 0 で生成した**公開鍵**に置換。

active を差し替える例 (owner 権限で署名):

```json
{"actions":[{
  "account":"eosio","name":"updateauth",
  "authorization":[{"actor":"metalfreedom","permission":"owner"}],
  "data":{
    "account":"metalfreedom","permission":"active","parent":"owner",
    "auth":{"threshold":1,"keys":[{"key":"<NEW_ACTIVE_PUB>","weight":1}],"accounts":[],"waits":[]}
  }
}]}
```

- anchor: `"permission":"anchor","parent":"active"` に変え、key を `<NEW_ANCHOR_PUB>`。
- owner: `"permission":"owner","parent":""` に変え、key を `<NEW_OWNER_PUB>`。**最後**。
- testnet は `actor`/`account` を `frdomyieltst`、chain を `testnet-a` にする。

## Phase 0 — 新鍵生成 (broadcast なし・operator)

permission ごとに生成元が違う。**owner は WebAuth (新 12word 派生)、active/anchor は proton key:generate**。
いずれも **秘密鍵/12word は vault へ、公開鍵だけ AI に共有** (チャットに貼らない)。

- **owner (mainnet 用 1 + testnet 用 1)** — **WebAuth** で新しい鍵 (新 12word) を作成 → 12word を vault 保存 →
  **公開鍵を控えて AI に渡す**。生鍵 (`key:generate`) は owner に使わない。proton-cli keystore にも入れない (cold)。
- **active / anchor (mainnet 用 2 + testnet 用 2)** — proton-cli で生成:
  ```bash
  HOME=~/.metal-fy-proton      proton key:generate   # ×2 (mainnet active, anchor)
  HOME=~/.metal-fy-proton-test proton key:generate   # ×2 (testnet active, anchor)
  ```
  出力の Public を控え、Private は vault へ。

> vault のラベルは既存流儀 (`Owner/active/anchor × Main/testNet`) に合わせ、
> 「(rotated 2026-07-10)」等で新旧を区別。

## Phase 1 — testnet (frdomyieltst) を先に完走 = gate1 + testnet 構成完成

1. **frdomyieltst の active/owner 秘密鍵を復元** (現 testnet keystore は anchor しか無い)。
   vault の frdomyieltst 12word を wallet で開いて active/owner の PVT を取り出し:
   ```bash
   HOME=~/.metal-fy-proton-test proton key:add <frdomyieltst active/owner PVT>
   ```
2. 各 permission を `bin/safe-broadcast --chain=testnet-a` で差し替え (**active → anchor → owner**)。
   例 (active):
   ```bash
   # token を tx にバインド (scripts/run-testnet-rehearsal.sh のリチュアル参照)
   printf '{"chain":"testnet-a","tx_sha256":"%s"}' \
     "$(jq -c . rotate-fdt-active.json | shasum -a 256 | awk '{print $1}')" > /tmp/fyd-broadcast-token
   HOME=~/.metal-fy-proton-test \
     bin/safe-broadcast --tx=rotate-fdt-active.json --chain=testnet-a
   ```
3. 各段後に検証:
   ```bash
   curl -s -X POST https://rpc.api.testnet.metalx.com/v1/chain/get_account \
     -H 'content-type: application/json' -d '{"account_name":"frdomyieltst"}' \
     | jq '.permissions[]|{name:.perm_name,keys:[.required_auth.keys[].key]}'
   ```
4. 3 permission が新鍵になれば testnet 完成。**各 tx_id を控える** (mainnet gate1 で使用)。

## Phase 2 — mainnet (metalfreedom) 差し替え (operator broadcast・owner 最後)

順序: **2a active → 2b anchor → 2c owner**。各回:

1. dry-run ログ取得 (mainnet gate4)。
2. token を mainnet-a + tx_sha256 にバインド。
3. broadcast:
   ```bash
   HOME=~/.metal-fy-proton \
     bin/safe-broadcast --tx=rotate-mf-active.json --chain=mainnet-a \
       --testnet-tx-id=<Phase1 active の testnet tx_id> \
       --dry-run-log=<dry-run ログ path>
   ```
4. `get_account metalfreedom` で着地検証してから次へ。

**owner (2c) の前に安全確認**:
- 2c の署名は **旧 owner (74Ec)** で行う (今の proton keystore にある旧鍵で署名し、新 owner 公開鍵を据える)。
- 新 owner は **WebAuth 由来**。updateauth に入れる公開鍵が WebAuth で作った新 owner の公開鍵と一致し、
  その **12word が vault に確実に保存済**であることを確認してから 2c を実行 (owner を失うと復旧不能)。
- owner 差し替え後に旧74Ec は完全無効化される。新 owner は WebAuth 側のみで保持 (cold)。

## Phase 3 — keystore を新鍵で作り直し (remove 不使用)

**owner は proton keystore に入れない** (WebAuth で cold 保管)。keystore は active/anchor/sink のみ。

```bash
mv ~/.metal-fy-proton ~/.metal-fy-proton-PRE-ROTATE
HOME=~/.metal-fy-proton proton chain:set proton
HOME=~/.metal-fy-proton proton key:add <NEW active PVT>
HOME=~/.metal-fy-proton proton key:add <NEW anchor PVT>
HOME=~/.metal-fy-proton proton key:add <fyhistory PVT (据置・MainNet)>
# owner は追加しない — root 鍵を日常署名面から外す
chmod 600 ~/.metal-fy-proton/Library/Preferences/@proton/cli-nodejs/proton-cli.json
HOME=~/.metal-fy-proton proton key:list   # 公開のみ。active/anchor/fyhistory を確認
HOME=~/.metal-fy-proton proton key:lock
```

testnet keystore も同様 (active/anchor/fyhistorytst のみ、owner は WebAuth cold)。

## Phase 4 — 事後検証

- `get_account` で metalfreedom / frdomyieltst の 3 permission が全て新鍵・旧鍵消滅を確認。
- `key:list` (公開のみ) が新 active/anchor と一致 (owner は keystore に無いのが正)。
- **WebAuth で新 owner の 12word を開き、metalfreedom / frdomyieltst が正しく見える・管理できる**ことを確認
  (owner を WebAuth 由来にした狙いはこの管理/復旧線の維持)。
- **新 anchor 鍵で testnet-first anchor を 1 本署名**し、anchor pipeline が新鍵で通ることを実証。
- 旧 keystore 退避物 (`*-PRE-ROTATE`) は、上記確認後に operator 判断で破棄。旧鍵は on-chain で
  無効化済みなので残っても署名権限はない。
- 重大インシデント (露出起因) の場合は [`INCIDENT_RESPONSE.md`](INCIDENT_RESPONSE.md) の開示方針も検討。

## 関連

- [`KEY_ROTATION.md`](KEY_ROTATION.md) — metalgo staking 鍵 (別物)
- `bin/safe-broadcast` — 唯一の broadcast 経路 (4 gate 強制)
- `scripts/run-testnet-rehearsal.sh` — token バインドのリファレンス
- memory: `reference_proton_keystore_per_project_network_separation` (remove-on-encrypted バグ / 4 象限分離)
