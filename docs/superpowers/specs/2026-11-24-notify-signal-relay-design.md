# 設計書: VPS 発の知らせを Signal へ（web host の箱 → Mac が取りに行く → 取られなければ ntfy）

- 日付: 2026-11-24（設計室の監督。コードは書かない・書かせない）
- 状態: 設計（経営者の承認の前）。実装・host の変更・送信は一切していない
- 監査の段: 部品ごとに 12 章（束の全体を一番上の段に引き上げない）
- 正本: この設計書。共通の部品 notify の正本は経営幹部の repo の `docs/superpowers/specs/2026-11-18-shared-notify-design.md`（以下「notify の設計書」）。この設計書は notify を**呼ぶ側**の設計で、notify の repo を変えない
- 公開の repo なので、憲法 §4 に合わせて次を書かない: topic・番号・host 名・IP・人名・Mac の鍵のパス・host の上の秘密の置き場の絶対パス（S5・S7・S8・S9）・不在の時間の具体（C4）。host の上の置き場は「箱の dir」などの役の名で書き、実際のパスは 4.2 の決まりで扱う

## 0. 何をするか（1 文）

validator host と web host の cron が出す経営者への知らせを、web host の上の「箱」に置き、Mac が 1 分ごとに取りに行って共通の部品 notify（Signal）で送り、**5 分取られなかった物と Mac が送れなかった物は web host が今までどおり ntfy で送る**。

## 1. 目的と、経営者と決めたこと（2026-11-24。変えない）

- 目的: 経営者への知らせを安全にする。中身を中継（ntfy の中継の server）に読ませない・偽の知らせを送らせない。知らせは notify で一元に管理する（憲法 6 章 #21）
- Signal の鍵は Mac だけに置く。VPS（validator host・web host）に signal-cli も Signal の資格も置かない
- validator host には新しいソフトを入れない
- 形: VPS の知らせは web host の箱に置く → Mac が取りに行き notify（Signal）で送る → **Mac が取りに来なければ ntfy**。切り替えは曜日でなく「取りに来たか」で決める（Mac が網に出ていない間も知らせは要る）
- 待ち時間: Mac は 1 分ごとに取りに行く。**5 分**取られなければ ntfy（外部の見張りの 5 分ごとに合わせた）
- 同じ知らせが 2 通届かない（Mac が取った印の付いた物は ntfy で送らない・ntfy で送った物は Mac が取らない）
- 安全な側（憲法 org.md 5.3）: validator host が web host の箱に置けなかった時は、validator host から今までどおり直に ntfy で送る（落とさない方を優先）
- 長い休み（Mac が 7 日以上つながらない）: 決まった再手続きはしない。明けて maintain が走る → `bin/notify check` → だめな時だけ経営者が `notify-register`（AI は PIN の段を打たない）。Signal の公式の確かめは 15 章
- 残る弱さを隠さない（14 章）

## 2. 目標・非目標・反目標

- 目標
  1. Mac が網に出ている間の VPS 発の知らせが、Signal で届く（中継が読めない・偽を差し込めない道）
  2. Mac が出ていない間も、知らせは今と同じ ntfy で、遅れは最大でおよそ 6 分（5 分＋箱の見回りの 1 分）
  3. どの部品が壊れても「黙って落ちる」より「ntfy で届く」に倒れる
  4. 入・切は host ごとの設定の鍵 1 つで、切れば今の動き（直の ntfy）にバイトで同じに戻る
- 非目標
  - VPS に Signal を置くこと・validator host に何かを入れること
  - ntfy の topic を無くすこと（Mac 不在の間の道として残る）
  - GitHub の失敗のメール・購読の .ics（洗い出しの (c)）を変えること
  - 12/7 の転換で使う手順の変更
- 反目標（動いても失敗とみなす）
  - 箱を通すことで、今なら届いた知らせが 1 通でも届かなくなる
  - 箱の中身が公開の dir（サイトが配る dir）に 1 バイトでも置かれる
  - web host が validator host に働きかける資格を持つ（憲法 §5）
  - 流れの途中で AI を呼ぶ（憲法 6 章 #13）

## 3. 制約（今の repo と憲法から）

| 制約 | 中身 | この設計への効き |
|---|---|---|
| 憲法 §5 単方向・1 本の道 | validator host → web host の向きだけ、鍵で認める狭い 1 本の道 | validator host から箱へ置くのは、今の push の道（専用の鍵 ＋ web host の forced command の受け口）に **許可の名を 1 つ足す**形にする。新しい鍵の道を足さない（足すなら憲法の改正が要る） |
| 憲法 §5 web host の資格 | web host は validator host に働きかける資格を持たない | 箱は受けるだけ。web host から validator host への接続は足さない（Mac への接続も無い。Mac が web host に来る） |
| 憲法 §5・W7 | host の変更は 1 つずつ経営者が承認 → AI が実行 → AI が確かめる | 16 章の段取りの host の手は全て W7 の 1 手ずつ |
| 憲法 §4 | 公開の repo。S5・S7・S8・S9・C4・C5 | 0 章の書かない物。箱の相対の置き場を公開する時は「Reclassifications」に経営者の承認が要る（19 章 Q8） |
| 凍結（`docs/CYCLE_GATE.md` の「Script freeze around a rehearsed transition」） | 転換の手順の script と `scripts/lib/side-effects.sh`・`bin/safe-broadcast` は 12/7 の後まで変えない | 16 章。`push-to-web-host.sh` も凍結の名に在る。`notify.sh` は名には無いが凍結の script が呼ぶ下流なので、安全な側で凍結として扱う（設計者の判断） |
| main への合流 = validator host へ届く | CI は main の push で validator host の checkout を進め、cron は次の回から新しい script を使う | 12/7 の前に main へ入れる物は「どこからも呼ばれない新しいファイル」に限っても届く。16 章で「12/7 の前は main へ入れない」を推奨 |
| 憲法 6 章 #21 | 新しい送り手は notify の `config/callers.json` に caller を `live:false` で足す。`live:true` は経営者の 1 行 | 17 章 |
| notify の決まり | 形（regex の全一致）に合わなければ送らない・他の道へ回らない・500 字・8 行まで・回数の上限 | Mac の台本が notify の `ok:false` を全て「ntfy へ返す」に写す（落とさない） |
| 憲法 6 章 #13 | 流れの途中で AI を呼ばない | 11 章 |

## 4. Approaches（考えた案と選んだ理由）

| 案 | 形 | 引き換え | 扱い |
|---|---|---|---|
| **A（選んだ）** web host の箱 ＋ Mac が引く ＋ 取られなければ web host が ntfy | validator host は今の push の道で箱に置く。Mac が専用に絞った鍵で 1 分ごとに取りに行き notify で送る。web host の見回りが 5 分取られない物を ntfy で送る | 部品が 3 つの機械にまたがる。Mac 不在の間は ntfy の弱さが残る。箱の中身が web host に数分置かれる | 経営者の決めた形。VPS に Signal の鍵を置かず、validator host に何も入れずに済む唯一の案 |
| B web host に signal-cli を置き、web host から Signal で送る | Signal の副端末を web host に | Mac 不在でも Signal で届く。代わりに Signal の資格が共有の web host に載る | **消えた**: 経営者「web に、キーを置くのも、セキュアな観点から、億劫です」 |
| C 曜日で切り替える（平日は Signal・それ以外は ntfy） | 予定の表で道を決める | 作りは軽い。予定と実際がずれた日（平日に Mac が出ていない・休みに出ている）に落ちるか二重になる | **消えた**: 「取りに来たか」で決める方が、ずれても正しく倒れる |
| D 常時つながる機械を別に置き、そこに Signal を置く | 小さな機械を常時の網に | Mac 不在でも Signal。置く所に常時の回線が無い | **消えた**: 置く所の回線が無い |
| E Mac が ntfy の topic を購読し、Signal に写す | ntfy をそのまま中継にし、Mac が受けて Signal へ | 作りは軽い。中身は ntfy の中継を通るので読まれる・topic を知る者が偽を差し込めば Signal で「本物らしく」届く | 目的（読ませない・偽を送らせない）に反するので外した |
| F ntfy の中継を自前にして認証を付ける | 自前の ntfy の server・鍵付きの topic | 偽は減る。自前の server の運用が増え、validator host に資格が増える。Mac 不在時の弱さは同じ | 目的に対して重い。外した |

## 5. 全体の形と流れ

### 5.1 図（文字）

```
validator host（cron）                     web host（このプロジェクトのアカウント）            Mac（網に出ている間）
 fyd_notify ──FYD_NOTIFY──▶ notify-relay.sh
   │ 設定の鍵が切 ─────────▶ notify.sh（今の直の ntfy）
   │ 入: 描く→封に入れる→
   └─push-to-web-host.sh relay/<id>.json ──▶ 受け口の relay の枝 ──▶ 箱/new/<id>.json
        置けない・時間切れ ──▶ notify.sh（直の ntfy。落とさない）
                                                    箱/new ◀──claim（専用の鍵・forced command）── relay-pull
                                                    箱/claimed ──内容──▶                         notify send（Signal）
                                                    箱/done ◀──ack sent ──────────────────────── 送れた
                                                    箱/handback ◀──handback <語> ─────────────── 送れなかった・空打ち
                                 relay-box-sweep（毎分）:
                                   new が 5 分を超えた物・handback の物・claimed が止まった物
                                   ──▶ 同梱の notify.sh（web host の既存の topic の ntfy）──▶ 箱/ntfy-sent
```

### 5.2 箱の状態（1 通 = 1 つのファイル。動きは全て同じ file system の上の rename で、1 つだけが勝つ）

| 今の所 | 次へ動かす者 | 次の所 | 条件 |
|---|---|---|---|
| （無い） | 受け口の relay の枝 | `new/` | 名・大きさ・形の門を全て通った（一時の名で書いてから rename） |
| `new/` | Mac（`claim`） | `claimed/` | rename が勝った時だけ中身を返す。負けたら「無し」を返す |
| `new/` | 見回り | `ntfy-pending/` | 箱に入ってから `RELAY_UNCLAIMED_FALLBACK_SECONDS`（300）を超えた。rename が勝った時だけ |
| `claimed/` | Mac（`ack <id> sent`） | `done/` | Mac が notify の結果を読んだ後。中身は消し、記録の行だけ残す |
| `claimed/` | Mac（`handback <id> <語>`） | `handback/` | notify が送らなかった（`ok:false`・空打ち・結果が読めない） |
| `claimed/` | 見回り | `ntfy-pending/` | `claim` から `RELAY_CLAIM_STALE_SECONDS`（180）を超えても ack も handback も無い（Mac が途中で止まった）。文の頭に 1 行「Signal で届いたかもしれない（重複の恐れ）」を足す |
| `handback/` | 見回り | `ntfy-pending/` | 次の回（最大 1 分） |
| `ntfy-pending/` | 見回り | `ntfy-sent/` | 同梱の notify.sh が strict で 0。0 以外は残して次の回に再び（`RELAY_NTFY_RETRY_MAX_MINUTES` 60 まで。超えたら `ntfy-failed/` に移し記録に 1 行） |

- 「5 分」は web host の時計で、箱に入った時刻（受け口が書いた時刻）から測る。validator host・Mac の時計を使わない
- Mac は `claim` が勝った物だけを送る。見回りは rename が勝った物だけを送る。だから「Mac が取った物を ntfy で送る」「ntfy で送った物を Mac が取る」は起きない。起きうる 2 通は 1 つだけ: Mac が Signal で送った直後に止まり ack が届かなかった時（`claimed/` が止まった行）。これは印を付けて ntfy で送る（落とさない方。19 章 Q4）
- ack が遅れて着いた（見回りが既に動かした）時は、`ack` が「もう無い」を返し、Mac が記録に「重複の恐れ」を 1 行書く

### 5.3 1 通の中身（封。schema `metal.relay.msg`・版 1）

| 項目 | 型 | 中身 |
|---|---|---|
| `schema`・`schema_version` | str・int | `"metal.relay.msg"`・`1` |
| `id` | str | `<UTC の YYYYmmddTHHMMSSZ>-<16 桁の 16 進の乱数>`（validator host が作る。名の門と同じ形） |
| `origin` | str | `validator-host` か `web-host`（決まった 2 つ。足すだけ） |
| `created_at_utc` | str | 作った時刻（ISO 8601・Z） |
| `priority` | str | `urgent`・`high`・`default`・`low`・`min`（notify.sh と同じ寄せ方で寄せた後の値） |
| `title` | str | ntfy の Title に今入れている文（改行なし・200 字まで） |
| `tags` | str | ntfy の Tags（今の決め方の結果。Signal では使わない。ntfy に戻る時に同じ見た目にするため） |
| `body` | str | 今の ntfy の本文と**バイトで同じ**（稼働率の脚注を付けた後の物。6 章 P8） |
| `sig` | str \| null | 19 章 Q2 で入れると決めた時だけ。validator host の封の HMAC-SHA256（16 進）。決まるまでは null |

- 大きさは封の全体で `RELAY_MSG_MAX_BYTES`（16384）まで。超える・項目が欠ける・型が違う・未知の項目が在る → 受け口が断る（validator host は直の ntfy に倒れる）
- 箱には文の中身を置くので、`done/`・`ntfy-sent/` に移す時に中身を消し、記録の行（id・時刻・結果の語・文の sha256）だけを残す

## 6. 部品の一覧

| # | 部品（仮の名） | 置く機械 | 1 つの仕事 | 段 |
|---|---|---|---|---|
| P1 | `scripts/notify-relay.sh` | validator host | `fyd_notify` の委ね先。設定の鍵が入なら封を作り箱へ置く。置けなければ・切なら `notify.sh` をそのまま呼ぶ | 2（判定の部品。倒れ方は 5.3） |
| P2 | `scripts/push-to-web-host.sh` の許可に `relay/<id>.json` を 1 つ足す（12/7 の後） | validator host | 今の push の道で封を運ぶ。送り元は公開の dir の外の送り出しの dir | 2 |
| P3 | 受け口の relay の枝（`scripts/deploy/receive-relay-box.snippet.sh` ＋ installer） | web host | 今の forced command の受け口に枝を 1 つ足し、名・大きさ・形の門を通った封だけを `new/` に置く。**公開の dir に書く道を持たない** | 2（門） |
| P4 | `relay-box-serve`（Mac 専用の鍵の forced command） | web host | `claim`・`ack`・`handback`・`ping` の 4 つの語だけを受ける。他は全て断る | 2（門） |
| P5 | `relay-box-sweep`（cron 毎分） | web host | 5.2 の表の見回りの行だけを動かし、同梱の `notify.sh` で ntfy に送る。古い記録を上限で消す | 2 |
| P6 | `relay-pull`（launchd 60 秒） | Mac | 1 通ずつ `claim` → notify send → `ack`/`handback`。1 回の起動で最大 `RELAY_PULL_MAX_PER_RUN`（10） | 2 |
| P7 | 外部の見張りの封の置き（`WATCH_NOTIFY` の差し替え先 `relay-box-put-local`） | web host | 外部の見張りの知らせを、同じ host の箱の `new/` に置く。置けなければ同梱の `notify.sh` を直に | 2（2 段目。19 章 Q5） |
| P8 | `scripts/lib/notify-render.sh` | validator host（と試験） | 優先度の寄せ・Tags の決め方・稼働率の脚注を 1 か所に。`notify.sh` と P1 が同じ物を使う（12/7 の後に `notify.sh` をこれに替え、出力がバイトで同じことを試験で見る） | 2 |
| P9 | 箱の見張り（外部の見張りに確かめを 1 つ足す） | web host | 見回りの心拍の時刻と、`new/`・`ntfy-pending/` の一番古い物の年齢を見て、15 分を超えたら直の ntfy で 1 通 | 2 |
| P10 | 封の署名（19 章 Q2 で入れる時だけ） | validator host（作る）・Mac（確かめる） | validator host の python3 の標準の `hmac` で封に署名し、Mac が確かめる。web host は鍵を持たない | 3（鍵の管理） |

## 7. 7 つの節（coding-design）

### 7.1 フレームワーク・既存の部品

| 使う物 | 理由 |
|---|---|
| `fyd_notify` の `FYD_NOTIFY`（既存） | 委ね先を差し替える口が既に在り、凍結の script を書き換えずに道を替えられる（16.1 で実物を確かめた） |
| `notify.sh`（既存） | 直の ntfy の唯一の末端。P1 の「切」と「置けなかった」の両方は、これを引数・env そのままで呼ぶ（今の動きとバイトで同じ） |
| `push-to-web-host.sh` と web host の forced command の受け口（既存） | 憲法 §5 の「1 本の道」。送る前の publish-guard の中身の検査も、そのまま封に効く |
| `scripts/deploy/receive-subdir-allowlist.snippet.sh` と `install-web-host-subdir-allowlist.sh`（既存の型） | 受け口に枝を足す形の手本。P3 は同じ型で、snippet を正本にして試験できる形にする |
| 外部の見張りの同梱の `notify.sh` と web host の既存の topic（既存） | P5 の ntfy はこれを使う。新しい curl・新しい topic を作らない（#21） |
| 共通の部品 notify の CLI（`bin/notify send`） | Mac の Signal の唯一の口。Mac の台本は notify の中を import しない（CLI の JSON だけで話す。notify の README の「呼ぶ側の決まり」） |
| python3 の標準ライブラリ（Mac） | P6 は JSON・ssh の子のプロセス・時刻だけ。依存を足さない |
| `00_INFRA_TOOLS/conventions` の `no-ai.patterns.json` と `tools/conv_copy.py` | 11 章の機械の確かめ。写しは SHA256 で照らす |

使わない物: ssh の多重化（ControlMaster。launchd の 1 回きりの起動では効きが小さく、残った socket が次の回を詰まらせる）・rsync（1 通の小さな JSON には重い）・新しいメッセージの待ち行列のソフト（validator host に入れない・web host に常駐を足さない）。

### 7.2 定義の表

| 名 | 値 | 置き場 | 使う所 |
|---|---|---|---|
| `RELAY_ENABLED` | `0`（既定）／`1` | validator host の `notify-relay.conf`（`/etc/freedom-yield/` の下。`notify.sh` の topic と同じ dir の流儀） | P1 |
| `RELAY_HMAC_ENABLED` | `0`（既定）／`1` | 同上 | P1・P10 |
| `RELAY_PUT_TIMEOUT_SECONDS` | 60 | P1 の定数 | P1（push の 3 回の試み ＋ 待ちの上限） |
| `RELAY_MSG_MAX_BYTES` | 16384 | 箱の定数のファイル 1 つ（`scripts/relay-box/relay-box.conf.sh`。P1・P3・P4・P7 が読む） | P1・P3・P7 |
| `RELAY_ID_PATTERN` | `^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$` | 同上 | P1・P3・P4 |
| `RELAY_BOX_STATES` | `new claimed done handback ntfy-pending ntfy-sent ntfy-failed` | 同上 | P3・P4・P5 |
| `RELAY_BOX_MAX_FILES`・`RELAY_BOX_MAX_BYTES` | 500・8 MiB（`new` ＋ `claimed` ＋ `handback` ＋ `ntfy-pending` の合計） | 同上 | P3（超えたら断る → 直の ntfy） |
| `RELAY_UNCLAIMED_FALLBACK_SECONDS` | 300 | 同上 | P5 |
| `RELAY_CLAIM_STALE_SECONDS` | 180（notify の Signal の送りの上限 60 秒 ＋ 余り） | 同上 | P5 |
| `RELAY_NTFY_RETRY_MAX_MINUTES` | 60 | 同上 | P5 |
| `RELAY_RECORD_KEEP_DAYS`・`RELAY_RECORD_MAX_LINES` | 7・10000 | 同上 | P5（記録と `done`・`ntfy-sent` の印を消す） |
| `RELAY_WATCH_STALE_SECONDS` | 900 | 同上 | P9 |
| `RELAY_PULL_INTERVAL_SECONDS` | 60 | launchd の plist の型（repo の型。値の埋め込みは installer） | P6 |
| `RELAY_PULL_MAX_PER_RUN` | 10 | P6 の定数 | P6 |
| `RELAY_PULL_AUTH_BACKOFF` | 認証の失敗が 3 回続いたら 15 分ごとに落とす | P6 の定数 | P6（web host の侵入の見張りに Mac の網を止められないため） |
| `RELAY_SIGNED_MAX_AGE_SECONDS`・`RELAY_SIGNED_MAX_FUTURE_SECONDS` | 86400・300 | P6・P10 の定数 | P10 |
| `NOTIFY_CALLER_VALIDATOR`・`NOTIFY_CALLER_WEBHOST` | `metal-validator`・`metal-external-watch` | P6 の定数（notify の `callers.json` と一字一句同じことを試験で見る） | P6 |
| Mac の設定・状態の置き場 | repo の外（Mac の手元の設定の dir・状態の dir）。**パスは repo に書かない**（S7）。plist の引数で P6 に渡す | installer が経営者の打った値で plist を作る（外部の見張りの installer と同じ流儀） | P6 |
| 箱の dir・記録の dir | このプロジェクトの web host のアカウントの home の下の、このプロジェクトの relay の dir（公開の dir の外。名は 19 章 Q8 の後に決める） | P3 の installer が 1 か所で決め、P3〜P5・P7 は installer が書いた設定のファイルから読む | P3〜P5・P7 |

- 箱の dir の home からの相対の置き場を公開の repo に書くことは（箱の中の状態の名 `new` などは手順の語なので書く）、外部の見張りの 2026-09-29 と同じく憲法の「Reclassifications」に経営者の承認が要る（19 章 Q8）。承認が出るまで、実装は installer の引数で受け、repo の文書には役の名だけを書く
- パスの文字列は定義の場所の外に書かない（`grep -rnE "['\"](/|\./|\.\./)[A-Za-z]"` を P1〜P9 の新しいファイルに当て、定義のファイル以外で 0 件）

### 7.3 入口／処理／保存（MVC の置き換え）

| 部品 | 入口 | 処理 | 保存 |
|---|---|---|---|
| P1 | `fyd_notify` からの argv（`<priority> <title> <message...>`）と env（`NTFY_TAGS`・`NOTIFY_STRICT_EXIT`） | 設定を読む → P8 で描く → 封を作る（P10）→ P2 で置く | 送り出しの dir に封の一時のファイル（置いた後に消す） |
| P3 | ssh の forced command の `SSH_ORIGINAL_COMMAND` と標準入力 | 名・大きさ・形の門 | `new/` へ rename |
| P4 | `SSH_ORIGINAL_COMMAND` の 4 つの語 | 状態の rename | 箱の dir・記録の行 |
| P5 | cron | 5.2 の見回りの行 | 箱の dir・記録の行・心拍のファイル |
| P6 | launchd | claim → notify → ack/handback | Mac の状態の dir の記録（id・結果の語・時刻だけ） |

### 7.4 デザインパターン

| 所 | パターン | 効くこと |
|---|---|---|
| `fyd_notify` の委ね先 | Strategy（委ね先の差し替え。既存の `FYD_NOTIFY`） | 道を足すのに `side-effects.sh` を変えない |
| P1 の「入／切」と「置けない時」 | Decorator（`notify.sh` の前に箱への置きを足す。切なら素通し） | 外せば元の `notify.sh` そのもの |
| P6 の notify の結果の読み | Adapter（notify の `notify.result` の JSON → 箱の 2 つの語 `ack sent`・`handback <語>`） | notify の失敗の語が増えても、知らない語は全て `handback` に倒れる（足すだけ） |
| 封の出どころ（`origin`） | 表で引く（`origin` → caller の名）。switch を書き換えない | 新しい出どころ（例: 別の VPS）は表に 1 行 |
| 5.2 の状態の動き | 状態の表を 1 か所に（`RELAY_BOX_STATES` と遷移の表）。P4・P5 はその表に無い動きをしない | 動きの増減は表の 1 行 |

### 7.5 命名

- 語を混ぜない: 「置く put」（箱へ入れる）・「取る claim」（Mac）・「返す handback」（Mac が送らなかった）・「済み ack」・「見回り sweep」・「封 envelope／msg」。notify の語（send・deliver・dry_run・caller）はそのまま使い、箱の語と混ぜない
- 単位と時刻の基準を名に入れる: `_SECONDS`・`_BYTES`・`created_at_utc`
- 台本の名は `relay-` で始める（host の上でこのプロジェクトの物と前方一致で分かる。憲法 §5 の多くの借り手の決まり）

### 7.6 横断の部品

| 部品 | 仕事 | 使う所 |
|---|---|---|
| `scripts/lib/notify-render.sh`（P8） | 優先度の寄せ・Tags・稼働率の脚注 | `notify.sh`（12/7 の後）・P1 |
| `scripts/relay-box/relay-box.conf.sh` | 7.2 の箱の定数 | P1・P3・P4・P5・P7 |
| `scripts/relay-box/lib/box-move.sh` | 「rename が勝った時だけ真」を返す 1 つの関数と、記録の 1 行を書く関数 | P3・P4・P5・P7 |
| 既存の `fyd__resolve_env` | env の解決 | 変えない（凍結） |

同じ処理を 2 か所に書かない: 優先度の寄せと脚注は P8 だけ。12/7 の前の枝の上では `notify.sh` を変えず、P8 は試験の中で `notify.sh` と出力が同じことを照らす（`tests/notify-relay/` の等しさの試験）。12/7 の後に `notify.sh` を P8 に替える。

### 7.7 部品の大きさとつなぎ目

| 部品 | 1 つの仕事 | つなぎ目 |
|---|---|---|
| P1 | 1 通を箱へ置くか、今の `notify.sh` に渡す | 入: `notify.sh` と同じ argv・env／出: `notify.sh` と同じ終了の語（strict の 0〜5）。箱に置けたら 0（「箱が受けた」。届けは箱の側が持つ） |
| P3 | 1 通の封を門に通して `new/` に置く | 入: 名 `relay/<id>.json` と標準入力／出: 0 か 0 以外（理由の固定の 1 行を stderr） |
| P4 | 1 つの語を 1 回の rename にする | `claim` → 1 通の封か `NONE`／`ack <id> sent` → `OK\|GONE`／`handback <id> <語>` → `OK\|GONE`／`ping` → `PONG` |
| P5 | 見回りの 1 回 | 入: 無し（cron）／出: 記録の行と心拍の時刻 |
| P6 | 1 回の起動で最大 10 通 | 入: plist の引数（設定のファイルの場所）／出: 記録の行。終了 0（記録できた）か 1 |
| P8 | 優先度・Tags・本文から ntfy に出す 3 つの値を作る | 入: 優先度・本文・env／出: 3 行（寄せた優先度・Tags・本文） |

## 8. 安全な側の表（入力ごとの欠け・想定外。憲法 org.md 5.3）

| 所 | 欠け・想定外 | 振る舞い |
|---|---|---|
| P1 設定のファイル | 無い・読めない・`RELAY_ENABLED` が `1` 以外 | 切（`notify.sh` をそのまま） |
| P1 置き | push が 0 以外・`RELAY_PUT_TIMEOUT_SECONDS` 超え・封が作れない（python3 が無い・P10 の鍵が読めない） | 直の ntfy（`notify.sh` をそのまま）。cron の stderr に固定の 1 行 |
| P1 置き | 時間切れだが実は箱に届いていた | 直の ntfy ＋ 箱の物も後で届く = 2 通（落とさない方。14 章） |
| P3 門 | 名が `RELAY_ID_PATTERN` に合わない・大きさ超え・JSON でない・項目の欠け・未知の項目・型違い・`origin` が許可の外・同じ id が既に在る・箱の上限超え・公開の dir の中を指す | 断る（0 以外）。validator host は直の ntfy |
| P4 | 4 つの語の外・引数の形の外・id が形の外・状態の dir に無い | 断る（`ERR` の固定の 1 行）。何も動かさない |
| P5 | 心拍の書きが失敗・ntfy が 0 以外 | 物は残し、次の回に再び。60 分を超えたら `ntfy-failed/` と記録（P9 が拾う） |
| P6 | ssh が失敗・`claim` の答えが封の形でない | その回をやめる（`new/` に残る → 5 分で ntfy） |
| P6 | notify の stdout が空・JSON でない・`schema` が違う・終了が 0〜3 の外 | `handback internal_error` |
| P6 | `ok:true` かつ `sent:true` | `ack sent` |
| P6 | `ok:true` かつ `sent:false`（空打ち・`live:false`） | `handback dry_run`（`live:false` の間も ntfy で届く） |
| P6 | `ok:false` かつ `error.code` が `duplicate` | `handback duplicate`（ntfy で届く。notify の `dedupe_seconds` は既定 3600 秒で、同じ文が 1 時間の中で別の出来事として出る警報を黙って捨てないため。builder check の後に `ack` から改めた。設計者の判断） |
| P6 | `ok:false` のその他の全ての語（`shape_mismatch`・`too_long`・`rate_limited`・`bad_text`・知らない語 …） | `handback <語>`。Mac の記録に語を残す |
| P6 | P10 が入なのに `sig` が無い・合わない・古すぎ・未来すぎ・既に見た id | notify に送らない。`handback bad_signature`（ntfy で届く。見回りが文の頭に「署名が合わない・偽の恐れ」の 1 行を足す）＋ Signal に固定の 1 通「箱に署名の合わない物が来た（id）」 |

## 9. どこで繋ぐか・どう外すか

- **繋ぐ所**
  - validator host: cron の各ファイルの env の行に `FYD_NOTIFY=<repo>/scripts/notify-relay.sh` を 1 行（`fyd_notify` を通る全ての送り手がここで替わる。各 script は変えない）
  - web host: 外部の見張りの `WATCH_NOTIFY` を P7 に（2 段目）
  - Mac: launchd の plist 1 つ（P6）
  - notify: `callers.json` の caller 2 つ（経営幹部の repo。17 章）
- **入・切の鍵（host ごとに 1 つ）**
  - validator host: `notify-relay.conf` の `RELAY_ENABLED`。`0` で P1 は `notify.sh` をそのまま呼ぶ = 今とバイトで同じ（試験で見る）
  - web host（外部の見張り）: P7 の設定の `RELAY_ENABLED`（同じ形）
  - Mac: plist を読み込むか（`launchctl bootout` で止まる。止まれば全ての封が 5 分で ntfy）
  - notify の側: caller の `live`（`false` の間は全て `handback dry_run` で ntfy に届く）
- **外す**: 上の鍵を切 → `FYD_NOTIFY` の行を消す → 箱の installer の `--uninstall`（受け口の枝を外し、見回りの cron の印の間を消し、Mac の鍵の行を `authorized_keys` から外し、箱の dir を消す）→ Mac の plist と鍵を消す → notify の caller を消す。どの段で止めても、残りは今の直の ntfy で動く
- 外して戻る先は「今の `notify.sh` の直の ntfy」で、`fyd_notify`・各 script・`notify.sh` は外す前と同じ物

## 10. 外に働きかける口の 5 つの節（憲法 6 章 #20。深さは標準）

### 10.1 絞った権限（合鍵を渡さない）

- Mac → web host: **今の root の鍵を使わない**。P6 専用の新しい鍵を作り、web host のこのプロジェクトのアカウントの `authorized_keys` に `restrict,command="<P4 の台本>"` で 1 行（pty・転送・agent を全て閉じる。`SSH_ORIGINAL_COMMAND` は P4 が 4 つの語だけ受ける）。root ではないアカウントで動く。発信元の網が決まらないので `from=` は付けない（14 章）
- Mac の ssh は `-F /dev/null`・`IdentitiesOnly=yes`・`StrictHostKeyChecking=yes`・専用の `UserKnownHostsFile` で、手元の ssh の設定に引きずられない
- validator host → web host: 今の push の専用の鍵と受け口のまま。足すのは受け口の枝 1 つで、枝は箱の `new/` 以外に書かない
- web host は validator host にも Mac にも資格を持たない（Mac が来る向きだけ）
- Signal の資格は Mac の notify の手元の設定だけ（変えない）
- P10 の鍵: validator host と Mac だけ。web host には置かない

### 10.2 上限（額・回数）

- お金: 無し（どの部品もお金を動かさない）
- 回数: 封 1 通 16 KiB・箱 500 通／8 MiB（超えると validator host は直の ntfy）・Mac は 1 分に最大 10 通・見回りの ntfy は 1 回に最大 30 通・notify の caller の回数の上限（17 章。超えた物は `handback rate_limited` で ntfy に届く）

### 10.3 許可の一覧

- P4 の語: `claim`・`ack <id> sent`・`handback <id> <語>`（語は `[a-z_]{1,32}`）・`ping`
- P3 の名: `relay/<RELAY_ID_PATTERN>.json` だけ。`origin` は `validator-host`・`web-host` だけ
- P6 の行き先: Mac の設定のファイルに書いた 1 つの host・1 つのアカウントだけ
- notify の caller: `metal-validator`・`metal-external-watch` だけ。形は 17 章の regex
- ntfy の行き先: 今の 2 つの topic（validator host の物・外部の見張りの物）だけ。新しい topic を作らない

### 10.4 読まれる記録とその読み手

| 記録 | 中身（文の中身・topic・番号は入れない） | 読み手 |
|---|---|---|
| web host の箱の記録（relay の dir の下の log。1 MiB で半分に切る。外部の見張りと同じ流儀） | id・時刻・動き・結果の語・文の sha256 | 経営者・総監督（頼まれた時に読む）・P9 |
| Mac の P6 の記録（Mac の状態の dir） | id・時刻・notify の結果の語（`shape_mismatch` を含む）・ack の答え | 経営者・総監督。`relay-pull --report` が直近 24 時間の数（Signal で届いた・ntfy に返した・語ごと）を出す |
| validator host の cron の stderr（今の log の流儀） | 「箱に置けず直に ntfy」の固定の 1 行 | 経営者・総監督 |
| notify の回数の状態 | notify の設計どおり | notify の `check` |

### 10.5 人の承認の所

- host の変更は 1 つずつ（W7）: validator host の cron の env の行・`notify-relay.conf`・web host の受け口の枝・見回りの cron・Mac の鍵の行・外部の見張りの差し替え
- Mac の launchd の読み込み（経営者の 1 行）
- notify の `live:true`（caller ごと・道ごとに経営者の 1 行。#1）
- P10 の鍵を作って 2 か所に置く（鍵の管理。#1 の扱いで単独の 1 行）
- 箱の相対の置き場の公開（Reclassifications。19 章 Q8）

## 11. この流れに AI を呼ぶ段が無いこと（機械で確かめる）

- P1〜P10 は全て cron・launchd・ssh の forced command で動き、AI（Claude・外部の LLM の API）を呼ぶ段は無い。notify も AI を呼ばない（notify の設計書 9 章）
- 確かめ: `00_INFRA_TOOLS/conventions/no-ai.patterns.json` を `tools/conv_copy.py` で metal の repo に写し（SHA256 で照らす）、`tests/notify-relay/test-no-ai.sh` が P1〜P10 の新しいファイルに当てて 0 件であることを見る。CI の `ci-main.yml` と `validate.yml` の両方に置く（片方だけだと main への直の push を見ない）
- 壊して落とす: 試験の一時の写しに API キーの読み込みの行を足すと、検査が落ちる

## 12. 部品ごとの監査の段（憲法 org.md 5.1）

| 部品 | 段 | 理由・確かめ |
|---|---|---|
| P1・P8 | 2 | 動的な判定と状態を持つ。8 章の行ごとの試験と、切の時に `notify.sh` とバイトで同じことの試験 |
| P3・P4（門） | 2（門なので 5.3 の安全な側の形で作る） | 許可の外を全て断ることを、行ごとに壊して落とす。公開の dir に書けないことは独立の試験 |
| P5 | 2 | 5.2 の表の行ごとの試験。rename の競り合い（Mac と見回りが同じ物を同時に）を 2 つのプロセスで 100 回回して、2 通にならないことを見る |
| P6 | 2 | notify の結果の全ての語と壊れた出力の写しの表（8 章）の試験。知らない語が `handback` に倒れることを壊して落とす |
| P7・P9 | 2 | 外部の見張りの既存の試験の型 |
| P10 | 3 | 鍵の管理。変異の網・盲検の確認役・実物で 1 回（testnet ではなく、Mac と validator host の間で偽の封を 1 つ作って断られることを見る） |
| 設計書・plist の型 | 1 | 機械の門だけ |

- 判定の部品で null の合体（`${x:-}` で欠けを既定の通る側にする書き方など）を使わない。欠けは常に 8 章の倒れる側
- 取り消せない部品（外への送信）は notify の `live` の門のまま。この設計の実物の門は「`live:false` のまま全ての道を回し、ntfy で届くこと」を経営者のスマホで 1 回見ること（16 章の 3）

## 13. 試験の計画（break-to-prove）

主張ごとに、壊した実装で 1 度落とす:

1. 切の時、P1 の出力（argv・env・終了）が `notify.sh` を直に呼んだ時と同じ（P1 の切の枝を消すと落ちる）
2. 置けない時は直の ntfy（偽の push が 1 を返す・時間切れ。P1 の倒れる枝を消すと落ちる）
3. P3 は公開の dir に書かない（受け口の枝の書き先を公開の dir にすり替えると落ちる）
4. P3 は名・大きさ・形・`origin` の外を断る（表の行ごと）
5. Mac と見回りが同じ封を競っても 1 通だけ（rename をコピーと削除に替えると落ちる）
6. `claimed/` が止まった物は印付きで ntfy（印の行を消すと落ちる）
7. notify の知らない語は `handback`（Adapter の既定を `ack` にすると落ちる）
8. `live:false` の間は全て ntfy で届く
9. P8 と今の `notify.sh` の出力がバイトで同じ（脚注の 1 字を変えると落ちる）
10. P10: 1 字変えた封・古い封・見た id の封は送られない
11. AI の検査（11 章）

偽の物だけで回す（偽の ssh・偽の notify の CLI・一時の箱の dir）。偽の試験は本物の sshd の `restrict` と forced command の振る舞いを保証しないので、16 章の 2 で実物を 1 回。

## 14. 残る弱さ（隠さない）

- **Mac が網に出ていない間は ntfy のまま**: topic が漏れたら中身を読める・偽を送れる。今と同じ弱さが、Mac が出ていない時間だけ残る
- **Mac が出ている間も、ntfy の topic への偽は防げない**: スマホが ntfy の topic を購読している限り、topic を知る者はいつでも ntfy に偽を送れる。Signal で届いた物は本物の道だが、ntfy で届いた物はいつでも偽でありうる（ntfy で届いた物に付ける印も偽が真似できる）
- **web host が乗っ取られた時**: 箱の中身（数分の間）を読める。P10 が無ければ、偽の封を箱に置いて Signal で「本物らしく」届けられる（P10 を入れれば validator host の出どころの物は防げる。web host の出どころ（外部の見張り）の物は防げない）
- **箱の中身は web host の disk に数分置かれる**: 終えた時に中身を消すが、disk の消し方までは保証しない。今も同じ中身が ntfy の中継の server を通っている
- **2 通になりうる所**: (1) Mac が Signal で送った直後に止まった（印付き）(2) validator host の置きが時間切れだが実は届いていた
- **遅れ**: Mac が出ていない時は今より最大でおよそ 6 分遅れる（5 分 ＋ 見回りの 1 分）。urgent も同じ
- **見回りの cron が止まり、Mac も出ていない時は、知らせが箱に溜まる**: P9（外部の見張り）が 15 分で直の ntfy に 1 通。ただし P9 も同じ host の cron で動くので、cron そのものが止まれば両方止まる（この形は今の外部の見張りと同じ。validator host の公開の site の見張りは web host の止まりを拾う）
- **Mac の P6 の鍵は合い言葉なし**（launchd が人なしで使うため）: Mac が乗っ取られれば箱を読める。ただしその時は Signal の資格も同じ Mac に在る
- **Mac の発信元の網が決まらない**ので `from=` で絞れない。鍵が漏れた時の範囲は P4 の 4 つの語だけ
- **web host の侵入の見張り**: Mac の鍵が合わない状態で 1 分ごとに来ると、Mac の網が締め出されうる（P6 の `RELAY_PULL_AUTH_BACKOFF` で減らす。締め出されても封は ntfy で届く）

## 15. 長い休みと Signal の登録の鍵（公式の支援のページで確かめた。2026-11-24）

確かめたページ（Signal の公式の支援の help center。版の日付は各ページの更新の時刻）:

- 「Signal PIN」 https://support.signal.org/hc/en-us/articles/360007059792-Signal-PIN （更新 2026-08-08）
- 「Re-registering using your Signal PIN」 https://support.signal.org/hc/en-us/articles/5440120029082-Re-registering-using-your-Signal-PIN （更新 2026-09-18）
- 「Delete Account」 https://support.signal.org/hc/en-us/articles/360007061192-Delete-Account （更新 2026-10-19）
- 「Open Signal on your phone to keep your account active」 https://support.signal.org/hc/en-us/articles/9021007554074-Open-Signal-on-your-phone-to-keep-your-account-active （更新 2026-08-02）

要点（公式の文の要約。括弧は原文）:

1. 登録の鍵は 7 日の非稼働で切れる（"Registration Lock expires after 7 days of inactivity."）。切れた後は新しい PIN を作れ、古い PIN とそれに結び付いた情報は使えなくなる（"After 7 days of inactivity, a new PIN can be created. The old PIN and information associated with it are no longer available."）
2. 登録の鍵は、番号が別の端末で登録されようとした時に 7 日の非稼働の時計を動かす（"Enabling a registration lock triggers a 7-day inactivity timer if your number is registered on another device."）。PIN を忘れて登録の鍵が有る時は、最大 7 日締め出されうる
3. PIN を思い出せない時は「Skip」で SMS の確かめに進める（再登録のページ）。ただし登録の鍵が有効な間は時計が切れるのを待つ
4. 口座そのものは 120 日の非稼働で消える（"Signal accounts are deleted after 120 days of inactivity."）。Signal の版は 90 日で期限が切れる（"Signal releases expire after 90 days"）

この設計への読み（設計者の判断。公式に書いていない所は「書いていない」と書く）:

- **7 日つながらないことそのもので、Mac の送り手の口座が消える・登録が外れるとは、公式には書いていない**。書いてあるのは「登録の鍵（PIN による守り）が切れる」こと。切れている間に誰かがその番号で SMS の確かめを通すと、PIN なしで登録を奪える。奪われると Mac の登録は無効になる
- だから休み明けは: maintain が走る → `bin/notify check` → (a) ready なら何もしない。登録の鍵は口座が動けば再び守る、と公式は明示していないので、**休みの後に PIN を設定し直すかは経営者の判断**（19 章 Q9。推奨: check が通れば何もしない。登録の鍵の再設定は notify の README の手順のまま）(b) だめなら経営者が `notify-register`（登録済みなら PIN の段だけ）
- 休みの間の知らせは、Mac が取りに来ないので全て 5 分で ntfy に届く（この設計の主な用途）
- 120 日・90 日は、notify の版の上げ（signal-cli の版を `SIGNAL_CLI_EXPECTED_VERSION` で止めている）と口座の保ち（maintain の 1 日 1 回）の側の話。この設計の外だが、90 日の版の期限は notify の版の固定とぶつかりうるので、経営幹部に伝える（19 章 Q10）

## 16. 12/7 の前の工程と後の工程

### 16.1 凍結の script を書き換えずに道を替えられるか（実物で確かめた。2026-11-24・main c882571）

手元の写しで、偽の委ね先（受けた argv と env を 1 行書く台本）を `FYD_NOTIFY` に指し、`FY_LIVE=1` で `scripts/lib/side-effects.sh` を読み込んで `fyd_notify` を呼んだ（網に出ない・host に繋がない・repo を変えていない。`git status` は空のまま）:

| 呼び方 | 偽の委ね先が受けた物 | `fyd_notify` の終了 |
|---|---|---|
| `fyd_notify --tags=tada high "T1" a b c` | argc 5・`high`・`T1`・`a b c`・`NTFY_TAGS=tada` | 0 |
| `fyd_notify --strict urgent "T2" x`（偽が 4 で終わる） | argc 3・`urgent`・`T2`・`x`・`NOTIFY_STRICT_EXIT=1` | 4（委ね先の終了がそのまま返る） |
| `NOTIFY=/nonexistent` と `FYD_NOTIFY=<偽>` を両方 | 偽が受けた。stderr に「NOTIFY は無視、FYD_NOTIFY が先」の 1 行 | 0 |

結論:

- `fyd_notify` を通る送り手（洗い出しの #3〜#12・#14）は、**`side-effects.sh` と各 script を変えずに、env の `FYD_NOTIFY` だけで P1 に替えられる**。P1 は `notify.sh` と同じ argv・env・終了の語を守れば、strict の再試行の分け（2・4・5 を再び）もそのまま効く
- 替えられない物: (1) 外部の見張り（`fyd_notify` を通らず `WATCH_NOTIFY` で `notify.sh` を直に呼ぶ。P7 は `WATCH_NOTIFY` の差し替えで同じく script を変えずに済む）(2) **P2（`push-to-web-host.sh` の許可に名を足す）は凍結の script の変更**なので 12/7 の後。`FYD_NOTIFY` の差し替えだけでは箱に運べない
- cron の中に `NOTIFY=` などを既に書いている行（例: `install-anchor-watch-alert-only.sh` は `NOTIFY` を設定する）は、`FYD_NOTIFY` が先に効き、log に警告の 1 行が出る。害は無いが、16.3 の 2 で行ごとに確かめる

### 16.2 12/7 13:00 の転換の前にしてよい工程（repo の中と手元だけ。host に触れない）

1. この設計書の承認（経営者）と、19 章の問いの答え
2. 実装の計画（`superpowers:writing-plans`）と、branch の上での実装・試験（P1・P3〜P10。P8 は `notify.sh` を変えずに、等しさの試験だけ）。**main へは入れない**（main に入れると CI が validator host へ届けるため。19 章 Q7）
3. Mac の上で、偽の箱（手元の一時の dir と偽の ssh）で P6 を回す（notify は `--dry-run`）
4. 経営幹部への依頼: notify の `callers.json` に `metal-validator` を `live:false` で（17 章）。長い文の上限の相談（19 章 Q6）
- してはいけない: validator host・web host への接続、cron の変更、`notify.sh`・`side-effects.sh`・`push-to-web-host.sh` の変更の main への合流、ntfy への送り、Signal の送り

### 16.3 12/7 の転換の後の工程（転換の完了（memo の記入まで）を確かめてから。各段は止めれば今の動きのまま）

1. main へ合流: P8 と `notify.sh` の P8 への替え（出力がバイトで同じ試験つき）・P2・P1（既定は切）・P3〜P5 の台本と installer。**次の転換の稽古の前に、P2 と `notify.sh` を含む単位を稽古し直す**（凍結の決まり）
2. validator host（W7）: `notify-relay.conf` を `RELAY_ENABLED=0` で置き、cron の env に `FYD_NOTIFY` を足す。1 日回して、ntfy の届き方が前と同じこと（log・スマホ）を確かめる
3. web host（W7）: 箱の installer（受け口の枝・箱の dir・見回りの cron・P9）。Mac の鍵の行を足す。Mac の launchd を読み込む（経営者の 1 行）。notify は `live:false` のまま → `RELAY_ENABLED=1` にする → **全ての知らせが「箱 → Mac → handback dry_run → web host の ntfy」で届くこと**を、経営者のスマホで 1 回見る。Mac の蓋を閉じた時に 5 分で届くことも 1 回見る
4. notify の `metal-validator` を `live:true`（経営者の 1 行。#1）。最初の 1 通がスマホで鳴ったことを台帳に 1 行
5. （19 章 Q5 で決めた時期に）外部の見張りの P7・`metal-external-watch`
6. （19 章 Q2 で入れると決めたら）P10

## 17. notify の caller の登録（経営幹部の repo。依頼で足してもらう）

- caller: `metal-validator`（validator host の出どころ）・`metal-external-watch`（web host の出どころ。2 段目）。1 caller = 1 つの道（`signal`）・1 つの形
- 始めは `live:false`。`live:true` は caller ごとに経営者の 1 行（notify の設計書 6.1）
- 文の形（題名と優先度を文の頭に入れる。Signal には題名と優先度の欄が無いため）:

```
【<優先度の語>】<題名>
<本文の行 …>
```

  - 優先度の語: `urgent` → `緊急`・`high` → `高`・`default` → `通常`・`low` → `低`・`min` → `最低`（P6 の定数の表 1 つ）
  - 広い形の例（例。値は実装の計画で notify の上限に合わせて決める）: `【(?:緊急|高|通常|低|最低)】[^\n]{1,200}(?:\n[^\n]{0,300}){0,7}`。広い形を明示して登録し、登録の差分で経営者に見えるようにする（notify の設計書 6 章）
- **`shape_mismatch` を metal の記録に必ず残す**（notify の設計書 10 章の「落とした事実を黙らない」）: P6 は `handback shape_mismatch` を Mac の記録と箱の記録に書き、その 1 通は web host の ntfy で届く。`relay-pull --report` が語ごとの数を出す
- 回数の上限: metal の警報は障害の時に重なる。caller の `rate` は実装の計画で notify の設定の決まり（上げられる向き）を確かめて決める。超えた物は `handback rate_limited` で ntfy に届く（落ちない）
- 文の長さ: notify の既定は 500 字・8 行。毎朝の要約など長い物は `too_long` で ntfy に届く（19 章 Q6）

## 18. 設計者の判断（builder と監督が確かめる所）

1. `notify.sh` を凍結の範囲として扱う（名に無いが、凍結の script の下流。安全な側）
2. validator host → 箱は今の push の道に名を 1 つ足す（憲法 §5 の「1 本の道」を保つ。新しい鍵を作らない）
3. Mac の取りは 1 通ずつ（`claim` → 送る → `ack`）。まとめて取らない（止まった時の待ちを 3 分に抑える）
4. `duplicate` も `handback`（ntfy で届く。落とさない方）。P4 の `ack` の語は `sent` だけ
5. 見回りの ntfy は web host の既存の topic と同梱の `notify.sh`（19 章 Q3 で替えうる）
6. P1 が箱に置けたら strict でも 0 を返す（届けの責めは箱の側。箱の側の倒れ方は 5.2）
7. 箱の中身は終えた時に消し、記録は sha256 だけ
8. 稼働率の脚注は validator host で付けてから封に入れる（ntfy に戻った時に今と同じ見た目）

### 18.1 builder check の答え（2026-11-24。新しい確認役 1 回）

1. **封の運び方（P2・P3）**: 今の `push-to-web-host.sh` は rsync ではなく、送る物を `cat … | ssh -i <専用の鍵> <web host> "<名>"` で標準入力に流し、web host の forced command の受け口が `SSH_ORIGINAL_COMMAND`（= 名）で分ける形（`scripts/push-to-web-host.sh` の ssh の段・`scripts/deploy/receive-subdir-allowlist.snippet.sh`）。P2 は許可の表と `case` に `relay/<id>.json` を足し、送り元を送り出しの dir の封にするだけ。P3 は subdir の snippet と同じ型で受け口の頭に入る枝で、名が `relay/` で始まる時だけ標準入力を読み、門を通して `new/` に置いて `exit` する（他の名は今の枝に落ちる）。道は 1 本のまま
2. **転換の完了の判定**: 総監督が台帳と転換の記録で確かめる（転換は memo の記入の単位まで済んで完了。project の決まり）。経営者の 1 行は要らない（host の手は別に W7 で 1 つずつ取る）
3. **時刻の持ち方（設計者の判断）**: 受け口が `new/` に rename した時の mtime を「箱に入った時刻」とする（rename は mtime を変えない）。P4 は `claim` の rename の直後に `claimed/` の物を `touch` し、その mtime を「取った時刻」とする。P5・P9 は mtime だけで年齢を測る。記録の行は箱の記録のファイル 1 つ（10.4）
4. **`duplicate`**: `handback` に改めた（8 章の表・18 の 4）
5. **差し込む cron の数え方**: 実装の計画の最初の段で、`scripts/vps-bootstrap.sh` と `scripts/install-*-cron.sh` が書く cron の各ファイルを grep で数え、`fyd_notify` を通る行と `NOTIFY=` などを既に持つ行を表にする（総監督の洗い出し 18 項の (b) の 13 項と照らす）。手で読み回さず、数える台本を 1 つ作る（憲法 6 章 #18）
6. **Mac の鍵（設計者の判断）**: P6 の installer（Mac で打つ。外部の見張りの `scripts/install-web-host-external-watch.sh` と同じ流儀: host の値はその 1 回の env で受け、出力に出さない）が、`ssh-keygen -t ed25519 -N ''` で Mac の手元の設定の dir に鍵を作り、公開の鍵の 1 行（`restrict,command=…`）を W7 の 1 手で web host のアカウントの `authorized_keys` に足す。plist も同じ installer が作る。鍵の作りと置きは 10.5 の承認の所
7. **Q1 を待つか**: 実装は設計の承認と Q1 の答えの後に始める（12/7 の前は main に入れないので急ぐ理由が無い）。Q1 の答えが遅れる時は、P4〜P6 を metal の `scripts/relay-box/` に置き、つなぎ目（4 つの語・封の形・notify の CLI）だけを固めて、後で共通の部品へ移せる形にする

## 19. 開いた問い（経営者が決める。推奨を先頭に）

| # | 問い | 推奨 | 引き換え |
|---|---|---|---|
| Q1 | **取りに行く台本（P6）・箱の口（P4）・見回り（P5）を、共通の部品（`00_INFRA_TOOLS`・経営幹部の持ち物）の汎用の部品にするか、metal の repo に置くか** | **汎用の部品にする**（例: notify の隣に「中継の箱」の部品。複数の箱を Mac の 1 つの launchd が回る形）。metal には P1・P2・P3・P7・P9 と installer だけを置く | 良い所: research の VPS の知らせも同じ形で入る（VPS の上に箱を置き、Mac が 2 つの箱を回る）・Mac の launchd が 1 つ・一元管理（#21）に合う。悪い所: 経営幹部の lane の順番を待つ・repo をまたぐ版の合わせが要る・metal の憲法の §4 の扱い（公開の repo）と共通の部品の扱いを両方守る。metal に置けば早いが、research で同じ物を 2 つ作ることになる |
| Q2 | validator host の封に署名（P10）を入れるか | **入れる**（16.3 の 6 で、Signal の道が動いた後に） | web host が乗っ取られても、validator host の出どころの偽を Signal で届けられなくなる。代わりに鍵が 1 つ増え（validator host と Mac）、鍵の管理（段 3）の手間が増える。validator host の python3 が標準の `hmac` を持つかを実装の前に読み取りで確かめる（新しいソフトは入れない） |
| Q3 | 見回りの ntfy をどの topic で送るか | **web host に既に在る外部の見張りの topic**（新しい秘密を web host に置かない） | validator host の topic を web host に写せば、ntfy の見え方は今と同じになるが、秘密が 1 つ web host に増える。推奨の形では、web host の topic が漏れた時の範囲が validator host の知らせにも広がる |
| Q4 | Mac が取った後に止まった時（Signal で届いたか分からない）に、印を付けて ntfy で送るか | **送る**（「重複の恐れ」の 1 行を付けて） | 落とさない（5.3）。代わりにまれに 2 通 |
| Q5 | 外部の見張り（web host の出どころ）も箱に入れるか・いつか | **入れる。validator host の出どころが live になって 1 週の後** | 外部の見張りは validator host と別の道であることに価値がある。箱に入れても代わりの ntfy が残るので独立は保てるが、同じ web host の上の箱に頼る分だけ部品が増える |
| Q6 | 毎朝の要約など長い文（notify の 500 字・8 行を超える）をどうするか | **経営幹部に、caller ごとの上限（字・行）を足す相談をする**。決まるまでは ntfy に届く | 文を分けて送る形は回数の上限を食い、順番が崩れる。要約だけ ntfy のまま、でもよい |
| Q7 | 12/7 の前に、どこからも呼ばれない新しいファイルだけでも main に入れるか | **入れない**（全て 12/7 の後） | 早く入れれば後の工程が短いが、main は validator host に届くので、転換の直前に host の中身を変えることになる |
| Q8 | 箱の dir の home からの相対の置き場を公開の repo に書いてよいか（憲法 §4.2 C5。外部の見張りの 2026-09-29 と同じ扱い） | **書いてよいとする**（外部の見張りと同じ理由: 相対の並びだけで host 名・秘密を含まない・試験と文書が具体になる） | 書かなければ installer の引数で受け、文書は役の名だけ。実装と試験が少し重くなる |
| Q9 | 長い休みの後、`bin/notify check` が通っても PIN（登録の鍵）を設定し直すか | **し直さない**（check が通れば何もしない） | 公式は「7 日で切れる」までしか書いておらず、口座が動いた後に守りが戻るかは書いていない。し直すなら休みのたびに経営者の手が要る |
| Q10 | Signal の版の 90 日の期限と、notify が signal-cli の版を固定していることの合わせ | **経営幹部に伝え、notify の版の上げの手順で扱ってもらう**（この設計の外） | 放っておくと、ある日から Signal が送れず全て ntfy に倒れる（落ちはしない） |

## 20. 後の仕事（この設計の外）

- 中継の数（Signal で届いた・ntfy に返した）を状態のページに出すか
- research の VPS の知らせ（Q1 の答えの後）
- ntfy の topic の購読をやめる時期（Signal が全ての時間で届く形ができるまで、やめない）

## 21. 完了の報告の 3 項目（この設計書の段）

- DB の変更: 無し
- 新しい依存: 無し（この段では何も入れていない。実装の段でも、validator host・web host に新しいソフトは入れない。Mac は既存の python3 と notify だけ）
- 待っている判断: 19 章の Q1〜Q10・この設計書の承認
