# 2026-11-27 testnet 稽古（新しい鍵の置き場）— 記録

> CHAIN: testnet
> PRIME_DIRECTIVE: TESTNET-FIRST — この稽古は testnet だけ。mainnet の鍵・mainnet への送信には触れていない。
>
> 追記だけの文書（`docs/OPERATING_MODEL.md` W11）。書いた結果は書き換えず、直す時は打ち消し線と `REVISION` で直す。形は `docs/REHEARSAL_2026-11-20.md` に倣い、今日の分を最小にした。

## 0. 目的と範囲

- **目的**: 2026-11-25 に鍵と記録の置き場を `~/.config/metal.freedom-yield.com/` の下へ移した（`scripts/lib/operator-paths.sh`。憲法 v0.10 の §3.5）。12/7 の 7c と同じ道が、新しい置き場で動くことを確かめる。
- **必須の 4 つ**: (1) preflight が新しい道で通る (2) 解錠が `HOME=~/.config/metal.freedom-yield.com/key/testnet` で効く (3) testnet への 1 回の送信が、監査の記録（`backup/.fyd-broadcast-audit.log`）に pre と post の行を書く (4) receipt と dry-run の記録が `backup/` に書かれる。
- **やらないこと**: 判定の直し（2026-11-24 の決定 A のまま。送りの判定は 11-20 と同じく exit 9 の見込み）。R2a・R2b・R5 の繰り返し（11-20 で済み）。
- **打つ人**: 解錠・稽古の起動・施錠は経営者が Mac の端末で、起動ファイル 2 本（`~/.config/metal.freedom-yield.com/scripts/fy-reh-1-nosend.sh`・`fy-reh-2-send.sh`）で打った。AI は読み取りだけ（鍵の dir の中は読んでいない）。

## 1. 前提の確かめ（AI。読み取りだけ）

| 項目 | 結果 |
|---|---|
| 束ねた実物のコミット | 8fab7d9（作業ツリーの変更 0） |
| `key/rehearsal`・`backup/`・`key/testnet` | 在る（どれも 700。`test -d`・`stat` だけ） |
| 監査の記録の書く先 | 予備の `backup/.fyd-broadcast-audit.log`（主の `/var/log/…` は無い）。稽古の前は `phase=pre` 16・`phase=post` 16 |
| testnet の窓口 | chain_id 一致・health の全ての service が OK |
| C と P | C=7・P=fya1c7（公開の anchor-source。schema 1） |

## 2. 結果

| 稽古の日時 | 2026-11-27 13:2x JST（送りの pre の行 04:24:49Z） |
|---|---|

| run | 実際の終了コード | 期待どおりか | 要点 |
|---|---|---|---|
| その 1（`fy-reh-1-nosend.sh`）: preflight | 0 | はい | `PRE-FLIGHT GREEN`（新しい道の testnet の HOME で通った） |
| その 1: 稽古（旗なし） | 10（wrapper 11） | はい | `ALREADY INSCRIBED ON TESTNET`。何も送っていない。dry-run の記録が `backup/` に 11-27 13:22 に書かれた。解錠は新しい道で効いた（施錠も 0） |
| その 2（`fy-reh-2-send.sh`）: 稽古（`--allow-existing-cycle-anchor`） | 9（wrapper 10）OUTCOME UNKNOWN | はい（11-20 と同じ。決定 A） | testnet へ 1 回送った。施錠 0 |

| 欄 | 記入 |
|---|---|
| 監査の記録 | pre 17・post 17（各 1 行増えた）。pre の行: `chain=testnet-a`・`memo_prefix=fya1c7`・`expiration=2026-11-27T04:34:47`。post の行: `outcome=unknown` |
| 送った tx | `30f6f5a3bf3ebd705f2f9ed184a80b3b34fda839efd7a07d333254f8df19966a`（block 418494295・2026-11-27T04:24:52 UTC） |
| executed（Hyperion v2 の get_transaction） | はい。4 action（memo の頭 `fya1c7-id:`・`fya1c7-ob:`・`fya1c7-ar:`・`fya1c7:`）。稽古の口座の transfer の total 4→8 |
| tx の `expiration`（v1 の get_transaction） | 読めなかった（窓口が v1 の答えに値を返さない） |
| E と block の時刻の差 | 595 秒（`EXPIRE_SECONDS`=600 以内） |
| E の確定の後の読み直し | §3 |
| receipt（`backup/.fya-testnet-receipt.json`） | **書かれていない**（決定どおり）。稽古は送りが submitted の時にだけ step 9/10 で receipt を書く（`scripts/run-testnet-rehearsal.sh` の step 9）。今の送りの判定は exit 9（unknown）なので、その前で終わる。receipt の道は試験（`tests/operator-paths` の P1・P2）で確かめた。実物は判定を直した後（12/7 の後）の稽古で確かめる |

**必須の 4 つの判定**: (1) はい (2) はい (3) はい (4) dry-run の記録ははい・receipt は書かれていない（決定どおり。上の欄）。

## 3. E の確定の後の読み直し（追記）

- 13:37 JST に LIB が E を過ぎた（LIB 2026-11-27T04:35:29.500）。読み直し: tx `30f6f5a3…966a` は executed・4 action のまま。稽古の口座の transfer の total は 8 のまま（2 回目の送信は無い）。監査の記録は pre 17・post 17 のまま。
- 終了 9 の判定は 11-20 と同じく安全な側に倒れたもので、送信は 1 回だけ載った（12/7 の 7c の exit 9 の見込みどおり。`docs/CYCLE_GATE.md` 7c の注記）。

## 4. 正直な限界

- この稽古が確かめたのは、新しい置き場で、preflight・解錠・稽古・監査の記録・dry-run の記録の道が testnet で 1 回ずつ動いたことだけ。12/7 の転換が安全だという証拠にはならない（`docs/REHEARSAL_2026-11-20.md` §6 の L1〜L8 はそのまま残る）。
- mainnet の鍵の dir（`key/mainnet`）と `key/broadcast/config` の道は、この稽古では動いていない。preflight が mainnet の HOME の設定を読む check だけが通った。
- receipt の道は実物で動いていない（§2）。
