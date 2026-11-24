# 2026-11-20 testnet 稽古（二重刻印の守り）— 命令と期待の用意

> CHAIN: testnet
> PRIME_DIRECTIVE: TESTNET-FIRST — この文書の命令は全て testnet 用（鍵の命令は全て `HOME=~/.metal-fy-proton-test` つき）。本番のチェーンには 1 つも使わない
>
> **稽古日 2026-11-20（予定。日時は経営者が決める）。** 追記だけの文書（`docs/OPERATING_MODEL.md` W11）。今回書いたのは §0〜§4 と §6（用意）。§5（結果）は空欄の枠で、稽古の当日に追記する。書いた結果は書き換えず、打ち消し線と `REVISION` で直す。
> 守りの設計書は `docs/superpowers/specs/2026-10-16-anchor-double-inscription-guard-design.md`（§5・§8・§11.2・§11.3・§11.8・§11.10・§11.11）。運用の正本は `docs/CYCLE_GATE.md` の 7a。矛盾したら設計書の §11.10 と `docs/CYCLE_GATE.md` を正とする。

## 0. この文書でやること / やらないこと

- **やること**: 設計書 §8 の稽古を、束ねた実物（T2 `beb5061` の `bin/safe-broadcast`・T3 `c46894b` の `scripts/run-testnet-rehearsal.sh`・T4 `3670170` の `scripts/check-cycle-anchor-absent.sh`）の命令で、testnet に対して 1 度ずつ動かす。動かして見るのは、二重刻印の守りの判断（check A の床・試行の記録（journal）・有効期限・結果の分類・稽古の終了コードの対応）が、設計書の期待どおりに働くこと。
- **やらないこと**: 12/7 の当日の全実行単位の手順は再掲しない（`docs/CYCLE_GATE.md` の役目）。本番のチェーンへの送信を稽古しない。結果が分からない（UNKNOWN）出来事を起こさない（§6）。
- **打つ人（設計書 §8 の Who does what。7a の「AI が起動」より厳しい）**: 送れる命令（稽古の起動）と、キーストアの解錠・施錠は**全て経営者**が Mac の端末で打つ。AI が打つのは読み取りだけ（`curl` の GET と、チェーン情報の POST による読み取り・`scripts/check-cycle-anchor-absent.sh`・audit log を読む `grep`）。AI の命令には `proton` の命令・稽古の起動・`bin/safe-broadcast`・`scripts/sign-anchor-event.sh` を入れない。
- **「稽古したから 12/7 は大丈夫」と読める文は、この文書のどこにも書かない。** 稽古しても確かめられないものは §6 に並べる。

### 0.1 この文書が設計書 §8 と違う所（実物を正にした。実物の行は各項に）

| # | 設計書 §8（と §11.10 の表） | この文書 | 理由（実物の行） |
|---|---|---|---|
| D1 | R1 は `--expect-cycle=<N+1>`（まだ刻んでいない次の cycle） | `--expect-cycle=<C>`。C は当日の正本 `public/api/anchor-source.json` の `observations_branch.cycle_number_observed`（既に刻んだ cycle の稽古＝DRESS。9/1 と同じ） | 稽古は `--expect-cycle` が正本の値と違えば step 1/10 で止まる（`c46894b:scripts/run-testnet-rehearsal.sh:343-346`）。`--source=` の見本の file は `--allow-fixture` が要り、gate 1 の証拠にならない（同 `:306-318`） |
| D2 | R3（旗つきの再実行）が R1 と別 | R1 の 2 回目（旗つき）が R3 を兼ねる。R3 を別に打たない | DRESS では、旗なしで送るのは §3.1 の表の「床だけ見える」の時だけで、それ以外の状態は何も送らない（§3.1 の表の分岐。`docs/superpowers/specs/…-design.md` §11.10 の表） |
| D3 | （R2a の旗の有無は書かれていない） | R2a は**旗なし** | 呼ぶ順は journal が先、check A が後（`beb5061:bin/safe-broadcast:1659-1660`、2 回目は `:1720-1722`）。旗なしでも journal の断り（wrapper 13）が先に出る。旗をつけると、有効期限 E が過ぎた後に打った時に check A の「見つかった」を旗が通し、送らないはずの run が送ってしまう |
| D4 | R4 は「設定の `anchor-sink` を存在しない口座にした設定」で稽古を走らせる | **行わない**（2026-11-17 総監督の決定。経営者の指摘による） | ― |

## 1. 前提の確かめ（AI が打つ読み取りだけ）

**稽古を始める条件**: 1.1〜1.4 が全て期待どおり。(a)(b) のどれかが違う・`curl` が失敗した時は**稽古を始めない**（経営者へ 1 行で知らせる）。1.4 の 0 件は止めない（§3.1 の表の「持たない」側に入るだけ）。AI は読み取りの値（口座名・窓口の URL・設定の中身）を画面にも返事にも**出さない**。件数と判定だけを出す。

### 1.1 実物が束ねてあること（AI。ファイルの在り処と定数だけ読む）

打つ人: AI（読み取りだけ）。repo の root で。

```
git log -1 --format=%h && git status --short | wc -l && test -f scripts/check-cycle-anchor-absent.sh && grep -l '^EXPIRE_SECONDS=' bin/* | wc -l && grep -cE '^AHR_(SCAN_PAGE_LIMIT|INDEX_MAX_LAG_BLOCKS)=' scripts/lib/anchor-history-read.sh
```

- 期待: 作業ツリーの変更が 0 件（1 つ目の `wc -l` が 0）・checker が在る・`EXPIRE_SECONDS` の定義を持つ file が 1 つ（`bin/` の下の wrapper。2 つ目の `wc -l` が 1）・定数 2 つが各 1 行（数 2）。1 行目のハッシュは §5 の欄に写す。
- 設計書 §8 の約束は「合流の後・12 月の転換の前・その後にコードを変えない」。違えば稽古を始めない。

### 1.2 AI の読み取りの共通の定義（一度だけ作る。値は保存しない）

打つ人: AI（稽古の一時の定義のファイル `$RH_LOGS/rh-vars.sh` を作る 1 行。外には何も書かない）。`$RH_LOGS` は、当日のセッションの一時の置き場の中の稽古用のフォルダ（絶対 path はこの文書に書かない）。

```
mkdir -p "$RH_LOGS" && cat > "$RH_LOGS/rh-vars.sh" <<'EOF'
CFG="$HOME/freedom-yield-rehearsal-config"
PROFILES=config/a-chain-profiles.json
BASE="$(jq -r '.profiles["xpr-testnet"].history_bases[0]' "$PROFILES")"
CID="$(jq -r '.profiles["xpr-testnet"].chain_id' "$PROFILES")"
ACCT="$(head -n 1 "$CFG/xpr-account" | tr -d '\r\n\t ')"
LIM="$(sed -n 's/^AHR_SCAN_PAGE_LIMIT=//p' scripts/lib/anchor-history-read.sh)"
MAXLAG="$(sed -n 's/^AHR_INDEX_MAX_LAG_BLOCKS=//p' scripts/lib/anchor-history-read.sh)"
S="$(jq -r '.schema_version' public/api/anchor-source.json)"
C="$(jq -r '.observations_branch.cycle_number_observed' public/api/anchor-source.json)"
P="fya${S}c${C}"
NEXT="fya${S}c$((C + 1))"
EOF
```

- この file は**変数の定義だけ**で、値は入っていない（読むたびに設定の file と公開の file から読む）。以降の AI の命令は先頭で `. "$RH_LOGS/rh-vars.sh"` として使う。稽古が終わったら消す（§3.6）。
- **C は当日に読み直す。** 2026-11-17 に監督が読んだ値は 7 だったが、これは**例の読み**で、決め打ちしない。S と C は上の file から導く。P の次の「使っていない prefix」は NEXT（手で決め打ちしない）。
- 設定の `xpr-account` の 1 行目が稽古の口座、`anchor-sink` が送り先。この文書では指すだけで、中身を開かない・書かない。

### 1.3 (a) 窓口の健康と、(b) チェーンの同一性（AI）

打つ人: AI（読み取りだけ）。

```
. "$RH_LOGS/rh-vars.sh" && curl -sSf --max-time 20 "$BASE/v2/health" | jq --argjson n "$MAXLAG" '([.health[] | .service_data? | objects | .head_block_num? | numbers] | max) as $h | ([.health[] | .service_data? | objects | .last_indexed_block? | numbers] | max) as $l | {services_all_ok: (.health | all(.status == "OK")), lag_blocks: ($h - $l), within_limit: ((($h - $l) <= $n) and (($l - $h) <= $n))}'
```

打つ人: AI（読み取りだけ）。

```
. "$RH_LOGS/rh-vars.sh" && curl -sSf --max-time 20 -X POST "$BASE/v1/chain/get_info" | jq --arg id "$CID" '{chain_id_matches: (.chain_id == $id), head_block_time, last_irreversible_block_time}'
```

- (a) 期待: `services_all_ok` が true、`within_limit` が true（定数 `AHR_INDEX_MAX_LAG_BLOCKS` 以内。数はこの文書に書かない）。
- (b) 期待: `chain_id_matches` が true。
- どれかが違う・`curl` が失敗 → **稽古を始めない**。

### 1.4 (c) 稽古の口座の履歴（AI）

打つ人: AI（読み取りだけ）。

```
. "$RH_LOGS/rh-vars.sh" && curl -sSf --max-time 20 "$BASE/v2/history/get_actions?account=$ACCT&filter=eosio.token:transfer&sort=desc&limit=$LIM" | jq --arg s "$S" --argjson c "$C" '[.actions[] | (.act.data.memo? // "" | capture("^fya(?<s>[0123456789]+)c(?<n>[0123456789]+)")?) | select(.s == $s) | .n | tonumber] as $n | {total: .total.value, shown: (.actions | length), fya_entries: ($n | length), this_cycle: ($n | map(select(. == $c)) | length), earlier_cycles: ($n | map(select(. < $c)) | length), later_cycles: ($n | map(select(. > $c)) | length)}'
```

- 出た `total` は**基準の値**として §5 に写す（以降の「何も送っていない」の確かめで比べる）。
- 読み方（§3.1 の表の分岐に使う。止める条件ではない）:
  - `fya_entries` が 0 → **持たない**（床が見えない。設計書 §11.3 の今の状態）
  - `this_cycle` が 1 以上 → **持つ**（前の稽古で P が見える）
  - `this_cycle` が 0 で `earlier_cycles` が 1 以上 → **床だけ見える**（P は無く、前の cycle が見える）
  - `later_cycles` が 1 以上 → 止めて経営者へ（P より後の cycle が testnet に在ると、旗でも通らない。実物 `beb5061:bin/safe-broadcast:1020`）
- 設計書 §11.8: この窓口が稽古の口座の**新しい**刻印を索引するかは、送ってみないと分からない（未確認）。稽古の直前に、1.3 と 1.4 をもう一度読む。

## 2. 経営者の打鍵の前と後（解錠と施錠）

**1 回の稽古の起動ごとに、解錠 → 稽古 → 施錠を組にする。** 解錠したまま放置しない。run の間の待ち（E を待つ間など）は施錠している。

1. 経営者が、その run の直前に解錠する（パスワードは Dashlane の testnet キーストアの 32 文字。entry 名はこの文書に書かない。AI が依頼のたびに添える）。
2. 経営者が、稽古を起動する（§3 の命令。1 行ずつ、改行で割らずに貼る）。
3. 終わったら**すぐ**（AI の確かめより先に）施錠する。施錠のプロンプトには**解錠と同じ 32 文字**を入れる。**空 Enter 禁止**（空 Enter は、既存のパスワードで施錠する代わりに新しいパスワードを作ってしまう。`docs/CYCLE_GATE.md` 7a の後操作と同じ）。
4. 画面の出力（終了コードと、読み取った印字）を AI に渡す。AI の確かめはその後。

- **断られると分かっている run（R1 の 1 回目・R2a・R2b）も解錠が要る。** 稽古の step 3/10 が鍵の一覧を読み、step 4/10 が口座を読むので、錠がかかっていると終了コード 2 で止まる（`c46894b:scripts/run-testnet-rehearsal.sh:445-460`・`:512-519`。断る判断は step 7/10 の wrapper の中で、その後ろ）。
- **公開鍵の確かめ**: 稽古の step 3/10 が、チェーン上の現在の公開鍵が手元のキーストアに在ることを確かめる（`present: … (matches current on-chain key)`）。出なければ終了コード 1 で止まる。
- 経営者が打つ解錠・施錠の命令は、各 run の節にある（毎回同じ形）。この節では再掲しない。
- 依頼の粒度（1 ピング 1 判断）: ピング A = R1 の 1 回目。ピング B = R1 の 2 回目と R2a（有効期限に近いので続けて。§3.3）。ピング C = R2b（E が確定した後）。R5 は AI だけ。R4 は行わない（§4）。

## 3. R1〜R5 を 1 つずつ

**共通の止める条件（RR7）。** 次のどれかが出たら、**そこで止める。鍵を先に施錠する。次の run を打たない。** AI は出力をそのまま報告し、経営者が決める。
1. 各 R の期待の表に無い終了コード
2. 送るはずの無い run で `BROADCAST OK` が出た
3. 送らないはずの run の後に、稽古の口座の transfer の `total` が基準より増えた（§1.4 の読みで比べる）
4. 送らないはずの run の後に、audit log に新しい `phase=pre` の行が増えた（§3.1 の読み方）

**共通の確かめの命令（AI。読み取りだけ）**

audit log は、wrapper が書く先（`bin/safe-broadcast` の `AUDIT_LOG_PRIMARY` と `AUDIT_LOG_FALLBACK` の定義。`:476-478`）。主が書けなければ予備に書く。この文書に path は写さない。AI は両方の定義を読んで、書かれている方を `AUDIT_LOG` として使う。行の `invoker=` は**人の名前になりうるので画面に出さない**（下の `awk` は欄を選んで出す）。

打つ人: AI（読み取りだけ）。`phase=` の行は wrapper が書く pre と post の対。他の道具の行が混じる時は無視する。

```
grep -F 'phase=' "$AUDIT_LOG" | tail -n 6 | awk -F'\t' '{printf "%s", $1; for (i = 2; i <= NF; i++) if ($i ~ /^(phase|chain|memo_prefix|expiration|profile|rc|tx_id|outcome)=/) printf "  %s", $i; printf "\n"}'
```

稽古の口座の transfer の基準との比べ（件数だけ）:

打つ人: AI（読み取りだけ）。

```
. "$RH_LOGS/rh-vars.sh" && curl -sSf --max-time 20 "$BASE/v2/history/get_actions?account=$ACCT&filter=eosio.token:transfer&sort=desc&limit=$LIM" | jq '{total: .total.value}'
```

### 3.1 R1（1 回目: 旗なし）— 守りの断りを live で 1 回見る

**目的**: 旗なしで走らせ、床の無い・または既に在る cycle を wrapper が断ることを見る。旗なしで送るのは「床だけ見える」の時だけで、それ以外は何も送らない。

打つ人: 経営者

```
HOME=~/.metal-fy-proton-test proton key:unlock
```

打つ人: 経営者

```
cd <repo> && HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<C>
```

打つ人: 経営者

```
HOME=~/.metal-fy-proton-test proton key:lock
```

施錠には解錠と同じ 32 文字を入れる。**空 Enter 禁止**。

- `<C>` は §1.2 で読んだ値（AI が依頼に書く）。`--source=` と `--allow-fixture` は使わない。
- **目視するもの（この順で）**: `step 1/10` の `cycle_number_observed:` が C、`derived memo_prefix:` が P、`expect-cycle:` の行が `(matches — OK)` → `step 3/10` の `present: … (matches current on-chain key)`。

**期待（「床だけ見える」の行だけ送る。それ以外は何も送らない）**

| 状態（§1.4） | 稽古の終了コード | 画面の要点 | wrapper の終了コード |
|---|---|---|---|
| 持たない | 11 | `FAIL (11): NOT SENT — cannot prove the cycle is absent …` と `(wrapper exit 12)`。stderr に「床（前の cycle の刻印）が見えないまま履歴が尽きた」旨 | 12 |
| 持つ | 10 | `FAIL (10): ALREADY INSCRIBED ON TESTNET …` と `(wrapper exit 11)`。stderr に見つかった tx の trx_id・block_num・timestamp | 11 |
| 床だけ見える | 0 | `BROADCAST OK  tx_id=…` が出て送る（旗なしで通る道。これが R1 の送る run を兼ねる。§3.2 は打たない。R3 の証拠は取れなかったと §5 に書く） | 0 |

- 「持つ」の時、画面の trx_id が 11-06 の稽古の tx か、それとも別かを控える（§5）。
- **上の表に無い 11（`(wrapper exit 13)`）**: stderr が「audit log が読めない」旨なら、この Mac で主の audit log が書けず予備の audit log もまだ無い（最初の run の既知の止まり方。`docs/CYCLE_GATE.md` 7a）。何も送っていない。迂回せず、共通の止める条件の 1 として報告する。「前の試行が生きている」旨なら、journal が R1 の前に別の試行を見つけたので、これも止めて報告する。
- **AI が読み取りで確かめること**: ① 稽古の口座の transfer の `total` が基準と同じ（「床だけ見える」の時は増える）② audit log に新しい `phase=pre` の行が増えていない（断りは pre の行を書く前。`beb5061:bin/safe-broadcast:1659-1660` の check A は、pre を書く `:1750` より前）。③ 終了コードと、`(wrapper exit <n>)` の n が上の表と一致。
- **期待と違ったら**: 共通の止める条件。特に、`later_cycles` が 1 以上の状態で 10 が出たら旗に進まない（旗は後の cycle を通さない）。

### 3.2 R1（2 回目: 旗つき。設計書 §8 の R3 を兼ねる）

**目的**: 経営者の**新しい判断**で、旗つきで走らせ、WARN つきで `BROADCAST OK` になること。これが有効期限の E を作る。**3.1 が「床だけ見える」で送った時は打たない。**

**旗を付けてよい条件（ちょうど 2 つ。`docs/CYCLE_GATE.md` 7a と同じ）**: 3.1 で 10 が出て、印字された刻印がその日の cycle のもの（見つかった P）の時／3.1 で 11 が `(wrapper exit 12)` の床の無い尽きた走査の時。それ以外の 11（履歴が読めない・古い・前の試行がまだ生きている・audit log か LIB の時刻が読めない）には付けず、待って経営者の指示を取る。**最初の run から付けない。**

打つ人: 経営者

```
HOME=~/.metal-fy-proton-test proton key:unlock
```

打つ人: 経営者

```
cd <repo> && HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<C> --allow-existing-cycle-anchor
```

打つ人: 経営者

```
HOME=~/.metal-fy-proton-test proton key:lock
```

施錠には解錠と同じ 32 文字を入れる。**空 Enter 禁止**。施錠は 稽古が終わってすぐ（`TESTNET REHEARSAL COMPLETE` か失敗の行が出たらすぐ）。

- **目視するもの（この順で）**: `step 7/10` の `override: --allow-existing-cycle-anchor passed …` → `expiration=<E>`（**この 1 行を AI にそのまま渡す。E は R2a と R2b と R5 に使う**）→ `WARNING (check A): --allow-existing-cycle-anchor: …`（見つけた tx か、床の無い尽きた走査）→ `BROADCAST OK  tx_id=<64hex>` → `step 9/10` の `7-gate PASS` → 末尾の `TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>`（この 1 行を AI に渡す。これを `<tx1>` と呼ぶ）。

**期待**

| 稽古の終了コード | 意味 | 次 |
|---|---|---|
| 0 | `COMPLETE` まで通った | AI の確かめ → R2a |
| 1（`BROADCAST OK` の**後**。step 9/10 の `ERROR (3): gate 1 — tx_id … not resolvable` など） | 送った。窓口がまだ索引していない（設計書 §11.8 の未確認。`docs/CYCLE_GATE.md` 7a の注意と同じ） | **稽古を再実行しない**（2 度目の送信になる）。`step 7/10` の行が画面に出ていたことを確かめて記録し、R2a へ |

- 上の 2 つ以外（`BROADCAST OK` が出る前の 1・2・8・9・10・11）は共通の止める条件。**9 は特に、E（印字されていれば）が確定するまで何も打たない。**

**AI が読み取りで確かめること**（各 1 回。施錠の後）:
1. audit log の最後の行: `phase=pre` に `memo_prefix` が P・`expiration` が印字された E・`profile` が稽古の側、続く `phase=post` が `outcome=submitted`（§3 の共通の命令）
2. 窓口の tx の読み（索引されていれば）:

打つ人: AI（読み取りだけ）。

```
. "$RH_LOGS/rh-vars.sh" && curl -sSf --max-time 20 "$BASE/v2/history/get_transaction?id=<tx1>" | jq '{executed, n_actions: (.actions | length), block_time: .actions[0]["@timestamp"]}'
```

打つ人: AI（読み取りだけ）。

```
. "$RH_LOGS/rh-vars.sh" && curl -sSf --max-time 20 -X POST -H 'content-type: application/json' -d '{"id":"<tx1>"}' "$BASE/v1/history/get_transaction" | jq '{expiration: .trx.trx.expiration?, block_num}'
```

3. tx の `expiration`（v1 の答えに在る時）が E と同じこと。無い時は「読めなかった」と書く。E と、tx の入った block の時刻（`block_time`）の差が、`EXPIRE_SECONDS`（設計書 §5）を超えないことと、それに近いこと（head の時刻から数えた有効期限になっている）を、差の値を添えて記録する。**超えていたら止める**（上限が効いていない）。
4. 索引されていない（`executed` が false か、答えが空）時は、それも記録する（§5。R2b と R5 の読みが変わる）。

### 3.3 R2a（旗なし。有効期限の前の再実行）— journal の断りを live で見る

**目的**: 同じ prefix の前の試行が、まだ着地しうる間に再実行して、journal が断ること（wrapper 13 → 稽古 11）。送らない。**D3（旗なし）。**

**打つ前の AI の確かめ**（E がまだ確定していないこと。R1 の 2 回目から続けて、解錠する前に）:

打つ人: AI（読み取りだけ）。

```
. "$RH_LOGS/rh-vars.sh" && curl -sSf --max-time 20 -X POST "$BASE/v1/chain/get_info" | jq --arg e "<E>" '{lib: .last_irreversible_block_time, e: $e, lib_past_e: (.last_irreversible_block_time[0:19] > $e)}'
```

- `lib_past_e` が false で、稽古の step 1〜7 の所要に足りる見込みがある時だけ、経営者に打たせる。true、または足りない見込みなら **R2a は打たない**（R2b へ進み、§5 に「R2a の証拠は取れなかった」と書く）。

打つ人: 経営者

```
HOME=~/.metal-fy-proton-test proton key:unlock
```

打つ人: 経営者

```
cd <repo> && HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<C>
```

打つ人: 経営者

```
HOME=~/.metal-fy-proton-test proton key:lock
```

施錠には解錠と同じ 32 文字を入れる。**空 Enter 禁止**。

**期待**

| 稽古の終了コード | 画面の要点 | wrapper |
|---|---|---|
| 11 | `FAIL (11): NOT SENT — an earlier attempt for this memo prefix may still land (wrapper exit 13)`。stderr に前の試行の記録時刻・`expiration`・チェーンの LIB | 13 |

- journal が先に走るので、**13 が出ること自体が証拠**。`(wrapper exit 12)` や 10 が出たら、journal が断らなかった（E が過ぎた・または journal が働かなかった）。送ってはいないが、期待と違うので共通の止める条件。
- **AI が読み取りで確かめること**: ① audit log に新しい `phase=pre` の行が増えていない ② 稽古の口座の transfer の `total` が R1 の 2 回目の後のまま ③ 画面の `(wrapper exit 13)`。

### 3.4 R2b（旗なし。E が確定した後の再実行）— check A の「既に在る」の断りを live で見る

**目的**: E が irreversible に過ぎた後、旗なしで再実行して、journal を通り、check A が R1 の tx を見つけて断ること（wrapper 11 → 稽古 10）。送らない。**窓口が R1 の tx を索引していない時は別の結果になる（下の表）。**

**打つ前の AI の確かめ**（E が確定したこと。LIB の時刻が E より後）:

打つ人: AI（読み取りだけ）。

```
. "$RH_LOGS/rh-vars.sh" && curl -sSf --max-time 20 -X POST "$BASE/v1/chain/get_info" | jq --arg e "<E>" '{lib: .last_irreversible_block_time, e: $e, lib_past_e: (.last_irreversible_block_time[0:19] > $e)}'
```

- `lib_past_e` が true になってから経営者に打たせる。false の間は待つ（2 秒以上の間隔・最大 60 回）。待っても true にならなければ止めて知らせる。

打つ人: 経営者

```
HOME=~/.metal-fy-proton-test proton key:unlock
```

打つ人: 経営者

```
cd <repo> && HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<C>
```

打つ人: 経営者

```
HOME=~/.metal-fy-proton-test proton key:lock
```

施錠には解錠と同じ 32 文字を入れる。**空 Enter 禁止**。

**期待（どちらも何も送らない）**

| 窓口の状態 | 稽古の終了コード | wrapper | 記録 |
|---|---|---|---|
| R1 の tx を索引している | 10 | 11 | 画面の trx_id が `<tx1>` と同じ（R2b の証拠が取れた） |
| 索引していない（§3.2 の 4） | 11 | 12 | **「R2b の証拠は取れなかった」と §5 に書く。旗で取り直さない**（設計書 §11.10・§11.8） |

- **AI が読み取りで確かめること**: ① audit log に新しい `phase=pre` の行が増えていない ② 稽古の口座の transfer の `total` が変わっていない ③ 10 の時、画面の trx_id が `<tx1>` と一致。

### 3.5 R3（R1 の 2 回目が兼ねる）

設計書 §8 の R3（旗つきの再実行。WARN の確かめ）は、§3.2 が兼ねる（D2）。別に打たない。WARN が見つけた tx と床の無い尽きた走査のどちらを名指したかを、§5 に書く。

### 3.6 R5（checker。AI だけ。キーストアに触れない）

**目的**: 読み取りの checker が、同じ状態を、wrapper と同じ読みで答えること。

打つ人: AI（読み取りの checker を走らせ、出力を稽古の一時のファイル `$RH_LOGS/r5-*.out`・`.err` に書く）。repo の root で。

```
. "$RH_LOGS/rh-vars.sh" && FY_CONFIG_DIR="$CFG" bash scripts/check-cycle-anchor-absent.sh --chain=testnet-a --anchor-source=public/api/anchor-source.json --not-before=<E> > "$RH_LOGS/r5-this.out" 2> "$RH_LOGS/r5-this.err"; echo "rc=$?"; cut -d' ' -f1-4 "$RH_LOGS/r5-this.out"
```

打つ人: AI（読み取りの checker を走らせ、出力を稽古の一時のファイル `$RH_LOGS/r5-*.out`・`.err` に書く）。repo の root で。

```
. "$RH_LOGS/rh-vars.sh" && FY_CONFIG_DIR="$CFG" bash scripts/check-cycle-anchor-absent.sh --chain=testnet-a --memo-prefix="$NEXT" > "$RH_LOGS/r5-next.out" 2> "$RH_LOGS/r5-next.err"; echo "rc=$?"; cut -d' ' -f1-4 "$RH_LOGS/r5-next.out"
```

- `FY_CONFIG_DIR` は**必ず付ける**（既定の置き場は Mac に無い）。stdout の `base=<url>` と stderr の理由には窓口の URL が出うるので、**結果の欄に写さない**（上の `cut` は先頭の欄だけを出す。trx_id は `<tx1>` との比べに別に読む）。
- 旗は `--chain=`・`--anchor-source=`・`--memo-prefix=`・`--not-before=` だけ。他に無い。

**期待**

| 命令 | 終了コード | 意味 |
|---|---|---|
| P（`--anchor-source=`・`--not-before=<E>`） | 10 | `PRESENT`。R1 の tx（窓口が索引していれば）。窓口が R1 の tx をまだ索引していなくても、前の稽古の刻印が P として見えていれば 10（trx_id が `<tx1>` と違う。記録する） |
| P | 3 | 窓口に R1 の tx も P の刻印も見えない（床の無い尽きた走査。設計書 §11.10 の R5 の行） |
| P | 4 | E がまだ確定していない。**待ってから打ち直す**（止める条件ではない） |
| NEXT（`--memo-prefix=`） | 0 | `ABSENT`。P の刻印が床として見えている |
| NEXT | 3 | 床が見えない（P も見えない）。0 を期待するのは設計書 §8 の読みで、§11.10 は床が無ければ 3 と読む |

- **0 と 10 以外も止める条件にしない**（3 と 4 は §11.10 の期待の内）。ただし終了コード 2・1 は**止める**（checker の設定か使い方の誤り）。
- 稽古が全部終わったら、AI は共通の定義の file を消す（実値は入っていないが、残さない）。

打つ人: AI（稽古の一時の定義のファイル `$RH_LOGS/rh-vars.sh` を消す 1 行）。

```
rm -f "$RH_LOGS/rh-vars.sh"
```

## 4. R4: 行わない

**R4 は行わない**（2026-11-17 総監督の決定。経営者の指摘による）。R4 の命令・経路・記入の欄は、この文書から外した。

## 5. 結果を書く節（稽古の当日に追記する。空欄の枠）

**追記だけ。書いた結果は書き換えない**（W11）。直す時は打ち消し線と `REVISION` の追記。実値（口座名・窓口の URL・host・IP・作業機の path・人の名前）は書かない。tx id と終了コードと件数は書いてよい。

| 欄 | 記入 |
|---|---|
| 稽古の日時 | 2026-11-20 14:56〜15:43 JST（§1 の再確認 14:56、R2b の取り直しと R5 が 15:43） |
| 束ねた実物のコミット（§1.1 の 1 行目） | e0fc2ea（origin と一致・作業ツリーの変更 0） |
| C と P と NEXT（当日に読んだ値） | C=7・P=fya1c7・NEXT=fya1c8 |
| §1.3 (a)(b) の結果（判定だけ） | (a) 合格（services_all_ok true・within_limit true）／(b) 合格（chain_id_matches true） |
| §1.4 の基準（`total`）と状態（持たない／持つ／床だけ見える） | total 0（fya の項 0）・「持たない」 |

| R | 実際の終了コード（稽古／wrapper） | tx id（あれば） | 期待どおりか | 逸脱（あれば） |
|---|---|---|---|---|
| R1 の 1 回目（旗なし） | 11／12 | なし | はい（表の「持たない」と一致。total 0 のまま・audit の pre 15 のまま） | 1 度目は命令が貼る途中で割れて未実行（施錠は成功）、やり直しで上の結果 |
| R1 の 2 回目（旗つき。R3 を兼ねる） | 9／10 OUTCOME UNKNOWN | `4bf9536f…`（block 417296643・executed・4 action・memo fya1c7） | いいえ（送信は載ったが、終了コードが表に無い → RR7 で停止） | 判定の件（下の「逸脱と、経営者の判断」） |
| R2a | 11／13 | なし | はい（journal が断った） | 施錠は画面に表示が無く、経営者に施錠を依頼した |
| R2b | 10／11 | trx_id は R1 の 2 回目の tx と一致 | はい | 1 度目は総監督の誤り（E の確定を待つ読み取りが終わる前に、確定したと書いて打たせた）→ journal が 13 で断り、何も送っていない（total 4・pre 16 のまま）。E の確定を確かめてから取り直して上の結果 |
| R5（P） | rc=10・PRESENT | found trx_id は R1 の 2 回目の tx（`4bf9536f…`） | はい | なし |
| R5（NEXT） | rc=0・ABSENT・floor=fya1c7 | なし | はい | なし |

| 欄 | 記入 |
|---|---|
| 印字された `expiration=<E>` | 2026-11-20T06:13:36（UTC。LIB と比べた値。audit log の pre の行） |
| tx の `expiration` と E の一致／読めなかった | 記録無し（当日の台帳に無い） |
| E と block の時刻の差（`EXPIRE_SECONDS` との比べ） | 記録無し（当日の台帳に無い） |
| R1 の tx を窓口が索引したか（`executed`） | はい（executed。total 0→4。設計書 §11.8 は「索引する」側と判明。前日の読み取りでは「索引しない」側と見ていた） |
| WARN が名指したもの（見つけた tx／床の無い尽きた走査） | 記録無し（当日の台帳に無い） |
| 各 run の施錠を確かめた時刻（空 Enter でなかったこと） | 正確な時刻は記録無し（当日の台帳に無い）。台帳には R1 の 1 回目・2 回目・R2b（2 回とも）で「施錠済み」、R2a は「画面に無く経営者へ依頼」とある |
| 逸脱と、経営者の判断 | (1) R1 の 2 回目の OUTCOME UNKNOWN: proton CLI（@proton/js 27.13.0・cli 0.1.98）が push の stdout に JSON の前の行 `get abi for <口座>` を出し、`bin/safe-broadcast` の `sb_receipt_is_executed` が読めず unknown に倒れた（安全な側）。12/7 の 7c も同じ経路で exit 9 の見込み。(2) R2b の 1 度目の誤り（上の表）。(3) 2026-11-24 の経営者の判断「A」: 12/7 の前はコードを変えず `docs/CYCLE_GATE.md` の 7c の exit 9 の項に注記を足す。判定の直しは 12/7 の後（段 3・testnet の稽古をもう一度） |
| 後始末（共通の定義の file を消した） | 共通の定義の file（rh-vars.sh）と、一時の script 2 本を消した |

## 6. 正直な限界 — 稽古しても確かめられないもの

**この稽古が確かめるのは、testnet で 1 回ずつ動いた守りの判断だけ。** 12/7 の転換が安全だという証拠にはならない。

| # | 残るもの | 根拠 |
|---|---|---|
| L1 | **結果が分からない（UNKNOWN）出来事**（時間切れ・接続が切れた）は、安全に・繰り返し起こせない。守りの試験（B3・B5。部品の中だけの試験）でしか見ていない。この残りは、経営者が明示して受け入れる | 設計書 §8 の「Not rehearsed live」・§10 の Q4 |
| L2 | 稽古の口座の**新しい**刻印を、testnet の窓口が索引するか（R1 の後の tx の読み・R2b・R5・12/7 の 7a がこれに依る）は、送ってみないと分からない | 設計書 §11.8 |
| L3 | 送りの出力の色の制御文字（ANSI）の有無。観測できたのは読み取りの命令まで | 設計書 §11.2 の 4・§11.8 |
| L4 | チェーンの LIB の遅れは 1 回の標本。E が確定するまでの待ちの長さは、当日の値で決まる | 設計書 §11.2 の 3・§11.8 |
| L5 | 本番のチェーンの gate 1・gate 4・gate 3 は testnet の run では 1 行も動かない。本番の到達性・口座の状態も、稽古で保証されない | `docs/REHEARSAL_2026-09-01.md` §4 の F1・F2 |
| L6 | 旗なしで送れる道（床が見えて P が無い）は、今の testnet の状態では通らない（§3.1 の「床だけ見える」の時だけ通る）。DRESS では、旗つきの道が実際に通った道になる | 設計書 §11.10 の表 |
| L7 | cycle 境界でしか動かないコード・転換の画面操作（Wallet UI の入力・本番の送信の認可）は、この稽古で動かない | `docs/REHEARSAL_2026-09-01.md` §4 の F4・F5 |
| L8 | 稽古の日と 12/7 の間にコードを変えれば、稽古の証拠は外れる。§8 の約束（合流の後は変えない）を、当日の §1.1 で 1 度だけ確かめる。その後の変更は再稽古 | 設計書 §8 の Timing |
