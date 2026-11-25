# 設計書: VPS 発の知らせを ops へ 1 回渡す（204 なら終わり・それ以外は今の ntfy）

- 日付: 2026-11-24（設計室の監督。コードは書かない・書かせない）。第 2 版（第 1 版 1887c04 の「Metal の側に箱と振り分けを持つ」形は、経営者の方針に合わないので取り下げた）
- 状態: 設計（経営者の承認の前）。実装・host の変更・送信は一切していない
- 監査の段: **段 2**（送り先に渡す札。鍵の管理ではない。mainnet の broadcast は無し）。部品ごとの段は 15 章
- 正本のつなぎ目: 経営幹部の repo（RF_BusinessStrategy）commit 6aef5f3 の `docs/superpowers/plans/2026-11-24-notify-routing.md` の「Metal への渡し: put の形と札の渡し方」の節（以下「渡しの節」）と、同じ commit の `docs/superpowers/specs/2026-11-24-shared-mac-online-design.md`。この設計書は渡しの節を**呼ぶ側**の設計で、向こうの repo を変えない。put の形を変える時は渡しの節が先に変わり、この設計書はそれに合わせる
- 公開の repo なので、憲法 §4 に合わせて次を書かない: topic・番号・host 名・IP・人名・**ops の名と URL**・札・host の上の秘密の置き場の絶対パス（S5・S7・S8・S9・S10）。この文書では「ops」と役の名で書く
- 使ったスキル: research-vault-first・superpowers:brainstorming・coding-design（芯 ＋ design-sections.md）
- vault を引いた結果: `~/claude-obsidian` を `notify-relay`・`relay put`・`mac-online`・`ntfy`・`signal-cli` で引いた。この設計に関わる記録は 0 件（`ntfy` の命中 1 件は予見の note で、通知の作りに関わらない）。vault に無い。Web は引いていない
- 機械化した道具か、しない理由: 部品そのものが機械（cron が呼ぶ台本。AI を呼ばない。12 章）。cron の差し替えは installer 1 本（P3）が数えて書き、手で cron を読み回さない

## 0. 何をするか（1 文）

validator host（後に web host の外部の見張りも）の知らせを、**ops へ put で 1 回だけ渡し、答えが 204 なら終わり、それ以外の全ては今の `notify.sh` で ntfy に直接送る**。Signal か ntfy かの振り分け（平日の時刻・Mac が届くか）は、共通の部品 notify と mac-online が ops と Mac の上で受け持ち、Metal は判断しない。

## 1. 決まっていること（経営者と総監督。2026-11-24。変えない）

1. 振り分け（平日の時刻・Mac が届くか）は共通の部品 notify と mac-online が受け持つ。Metal はそれを判断しない。Metal がすることは、ops へ put を 1 回送り、204 なら終わり、それ以外は全て今の `notify.sh` で ntfy に直接送ることだけ
2. put の形・札・答えの番号・10 秒の締め切りは、渡しの節のとおり（5 章）。札は送り手ごとに 1 つ（`metal-validator`・`metal-external-watch`）
3. 総監督の 5 つの条件:
   1. validator host への全ての手（札を置く・送り先の設定を替える）は、憲法 §5 のとおり 1 つごとに経営者の 1 行の承認を取る
   2. 向きは一方向だけ。ops と Mac は validator host への資格を持たない。Metal は答えの番号しか読まず、本文で動きを変えない
   3. 札・ops の名・URL は公開 repo に書かない。host の秘密の置き場（700/600）にだけ置く（§4.1 の S10・Metal の匿名性）。札は process の引数（ps に見える所）に出さない。今の `notify.sh` の `curl -K <(…)` と同じ渡し方にする
   4. 届かない時は、今の `notify.sh` で ntfy に直接送る。札のファイルが無い・読めない・設定が空・curl が無い、も同じく倒す（安全な側に倒す作り。org.md §5.3）。`notify.sh` は消さず、予備として残す
   5. 時刻の条件は Metal に置かない
4. 時期: validator host の差し替えも 12/7 より前（目安 12/1 ごろ）に行う。12/7 の転換で使う script（`cycle-transition.sh` など転換の script・`scripts/lib/side-effects.sh`・`bin/safe-broadcast`・`push-to-web-host.sh`）は 12/7 まで凍結。中身を 1 行も変えず、**新しいファイルと host の設定（`FYD_NOTIFY`・`WATCH_NOTIFY` が指す先）だけ**で差し替える
5. 繋ぐ前の確かめ: (a) ops の箱と振り分けが動いている（notify の側で 11/28〜11/30 に確かめる）(b) 倒れる動きを、試し台（503・遅延・切断の 3 つの型）と本番で 1 回ずつ確かめる (c) 12/6〜12/8 は notify の側を変えない
6. 外す時: host の `FYD_NOTIFY`・`WATCH_NOTIFY` を元に戻すだけで、今の動きに戻る（10 章）

## 2. 目標・非目標・反目標

- 目標
  1. Metal の知らせが、ops に渡れば notify の振り分けで Signal（または ops の ntfy）に届き、渡らなければ今と同じ ntfy で届く
  2. どの部品が壊れても「黙って落ちる」より「今の ntfy で届く」に倒れる
  3. `FYD_NOTIFY`・`WATCH_NOTIFY` を外せば、今の動きにバイトで同じに戻る
  4. 凍結の script を 1 行も変えない
- 非目標
  - 振り分け・箱・Mac の取りに行く台本・見回り（全て notify と mac-online の持ち物。第 1 版の P3〜P7・P9 は消した）
  - ntfy の topic を無くすこと（予備の道として残る）
  - 封の署名（渡しの節の「問い 2」。ops に共有の秘密を置かない形で、`metal-validator` を `live:true` にする前に notify の側で足す。Metal の側の変更が要るかはその時に設計する）
  - 12/7 の転換の手順の変更
- 反目標（動いても失敗とみなす）
  - put を挟むことで、今なら届いた知らせが 1 通でも届かなくなる
  - 札・ops の名・URL が repo・記録・process の引数・cron の log に 1 バイトでも出る
  - ops・Mac が validator host に働きかける資格を持つ（憲法 §5）
  - Metal が ops の答えの本文を読む・本文で動きを変える
  - 流れの途中で AI を呼ぶ（憲法 6 章 #13）

## 3. 制約（今の repo と憲法から）

| 制約 | 中身 | この設計への効き |
|---|---|---|
| 凍結（`docs/CYCLE_GATE.md` の「Script freeze around a rehearsed transition」） | 転換の手順の script と `side-effects.sh`・`bin/safe-broadcast`・`push-to-web-host.sh` などは 12/7 の後まで変えない | 新しいファイルだけを足す。`notify.sh` は凍結の名に無いが、凍結の script（`append-anchor-history.sh` など）が `fyd_notify` 経由で呼ぶ下流なので、変えない（設計者の判断。17 章の 1） |
| `fyd_notify` の委ね先（`side-effects.sh` 434 行目） | `FYD_NOTIFY`・`ANCHOR_NOTIFY`・`WATCH_NOTIFY`・`NOTIFY` の順で委ね先を決め、`bash <委ね先> <priority> <title> <message...>` を `NTFY_TAGS`・`NOTIFY_STRICT_EXIT` の env 付きで呼び、終了の番号をそのまま返す | P1 は `notify.sh` と同じ argv・env・終了の番号を守る。cron の env の `FYD_NOTIFY` 1 行で差し替わる（`side-effects.sh` を変えない） |
| 外部の見張り（`scripts/external-watch.sh` 57 行目） | `NOTIFY="${WATCH_NOTIFY:-…/notify.sh}"` を `NTFY_TOPIC_FILE=… NOTIFY_STRICT_EXIT=1 "$NOTIFY" prio title body` で**直に実行**し、2・4・5 なら 1 回やり直す | P1 は実行の権限（700）を持ち、`NTFY_TOPIC_FILE` をそのまま `notify.sh` に渡す |
| 転換の手で打つ script | 転換の日に手で打つ script（`append-anchor-history.sh` など）は cron の env を持たない | cron の env に足す `FYD_NOTIFY` は手で打つ転換には効かない。転換の日の知らせは稽古と同じ `notify.sh` を通る（14.3） |
| main への合流 = validator host へ届く | CI は main の push で validator host の checkout を進める | 12/1 に差し替えるには、P1〜P3 を 12/1 より前に main へ入れる（push は経営者の 1 行。19 章 Q1）。入れても `FYD_NOTIFY` を足すまで誰も呼ばない |
| 憲法 §5 | 単方向・host の変更は 1 つずつ承認 → AI が実行 → AI が確かめる | 14 章の host の手は全て 1 手ずつ |
| 憲法 §4 | 公開の repo | 0 行目の書かない物。秘密の置き場の場所は `NTFY_TOPIC_FILE` の dir から導き、新しいパスの文字を repo に足さない（7.2） |
| 憲法 6 章 #21 | 知らせは notify だけで送る | この設計は Metal の知らせを notify（ops の口）へ寄せる工程。`notify.sh` の直の ntfy は「ops に渡らなかった時の予備」として残す（#21 の「既に動いている独自の知らせは…移す順を決める」に当たる） |
| ops の上限（渡しの節） | 本文（JSON）8192 バイト・ops が組む文 2000 字（行の数の上限は無い） | 6 章で Metal の側の扱いを決める |

## 4. Approaches（考えた案と選んだ理由）

| 案 | 形 | 引き換え | 扱い |
|---|---|---|---|
| **A（決定）** put を 1 回・204 なら終わり・他は今の `notify.sh` | 新しい委ね先 P1 が put を 1 回送り、204 以外は `notify.sh` を同じ argv・env で呼ぶ | Metal の部品は 1 つの台本と 1 つの横断の部品だけ。振り分けの変更は Metal に波及しない。時間切れの後に ops が受け取っていた時だけ 2 通になりうる | **経営者の決定**（振り分けは notify と mac-online。Metal は判断しない） |
| B（第 1 版）Metal の側に箱・振り分け・取りに行く台本を持つ | web host に箱、Mac が取りに行く、5 分で ntfy | 部品が 3 つの機械にまたがり、振り分けの規則が Metal と notify の 2 か所になる | **消えた**: 経営者の方針に合わない（振り分けは共通の部品の持ち物）。経営幹部が流用した節（第 1 版の 5.2・5.3・8・10・14・15）は向こうに写っている |
| C put と直の ntfy を両方いつも送る | 二重に送り、Signal に届けば ntfy を無視 | 作りは最も軽い。毎回 2 通届き、ntfy の弱さ（中継が読める）が残ったまま | 外した: 目的（中継に読ませない）に反する |
| D `notify.sh` の中に put を足す | `notify.sh` の頭で put を試す | 委ね先の差し替えが要らない。凍結の下流の `notify.sh` を変え、外すのに中身の書き戻しが要る | 外した: 凍結と「設定の鍵 1 つで外す」に反する |

## 5. put の形（渡しの節のとおり。Metal の側の見方）

- 行き先: `POST <URL>`。URL は ops の名を含むので、host の秘密の置き場の 1 行のファイル（`url`）にだけ置く
- 見出し: `Authorization: Bearer <札>` と `X-Ops-Token: <札>`（同じ札を両方）・`Content-Type: application/json`
- 本文: `{"project":"<名>","title":"<題名>","body":"<内容>"}` の 3 つの鍵だけ（3 つとも空でも空白だけでもない UTF-8 の文字列。`project` は P1 の定数 `RELAY_PUT_PROJECT` = `Metal`、`title` は「【優先度の語】題名」、`body` は本文と脚注）。caller は書かない（札が決める）
- 答え: **状態の番号だけを読む**。`204` → 終わり（直の ntfy を送らない）。それ以外の全て（4xx・5xx・2xx の 204 以外・3xx・時間切れ・TLS の誤り・接続できない・番号が読めない）→ 今の `notify.sh` で直の ntfy。答えの本文は捨てる（`-o /dev/null`）
- 締め切り: `RELAY_PUT_TIMEOUT_SECONDS` = 10 秒（curl の `--max-time`）。put は 1 回だけ（P1 の中でやり直さない）
- 札: 送り手ごとに 1 つ・形 `[A-Za-z0-9_-]{43}`。validator host の札は `metal-validator`、外部の見張りの札は `metal-external-watch`（web host の見張りの秘密の置き場）。共有しない

### 5.1 文の作り方（Metal の側で描く。ops は文を変えない）

```
【<優先度の語>】<題名>
<本文>
（稼働率の脚注。今の notify.sh と同じ条件・同じ文字で付く時だけ）
```

- 優先度の語: `urgent` → `緊急`・`high` → `高`・`default` → `通常`・`low` → `低`・`min` → `最低`。それ以外の値は `notify.sh` と同じく `default` に寄せてから引く
- 題名の既定は `notify.sh` と同じ（`Freedom Yield ops`）。本文の既定は題名と同じ文（notify は空の本文を受けないため）。本文が空・空白だけの時だけ `notify.sh`（`(no message)`・空白のまま）と違う。題名も空・空白だけなら本文は `Freedom Yield ops`
- 稼働率の脚注（`[Uptime] XX%` と `NOTIFY_UPTIME_SUFFIX`）は、`notify.sh` と同じ `validator.json` を同じ規則で読み、同じ文字で付ける（P2 の 1 か所。7.6）
- Tags（ntfy の絵文字）は文に入れない（Signal に欄が無い）。直の ntfy に倒れた時は `notify.sh` が今どおり付ける
- Mac の notify の登録の形（`【(?:緊急|高|通常|低|最低)】…`）に合わない文は、notify の側が ntfy へ回す（Metal は形を判断しない。ops の上限だけを 6 章で見る）

## 6. 上限（ops の 8192 バイト・2000 字に Metal の側でどう合わせるか。行の数の上限は無い）

- **決定（設計者の判断）: 切らない。上限を超える文は put を送らず、今の `notify.sh` で ntfy だけに送る**
  - 理由: 切った文が Signal に届くと、残りが落ちる（反目標「今なら届いた知らせが届かなくなる」）。ntfy なら全文が今どおり届く。分けて送る形は ops の回数の上限（1 時間 60 通）を食い、順番が崩れる
  - 確かめる順: (1) ops が組む文 `【<project>】<title>\n<body>` の字数（Unicode の文字の数。改行も 1 字）≤ `RELAY_TEXT_MAX_CHARS`（2000）(2) 組んだ本文の JSON のバイト数 ≤ `RELAY_PUT_MAX_BYTES`（8192）。1 つでも超えたら、理由の語 `too_long` で直の ntfy
  - 数え方は jq（`notify.sh` が既に使う道具）で行い、cron の locale に引きずられない（bash の `${#…}` は locale でバイトを数えるので使わない）
  - 毎朝の要約など長い文は、当面 ntfy で届く。どれが超えるかは実装の計画の最初の段で、送り手ごとの文の長さを数える台本で確かめ（手で読み回さない）、超える物が常用の知らせなら経営者に報告する
- 回数: Metal の側に回数の上限は置かない（ops が 1 時間 60 通で `429` を返し、Metal はそれを「204 以外」として直の ntfy に倒れる。落ちない）
- 時間: 1 通あたり最長は put の 10 秒 ＋ `notify.sh` の 10 秒。cron の 1 回の中で知らせが重なる時（障害の時）も、送り手の今の待ちの上限の中に入る（14.1 で実物の時間を測る）

## 7. 部品とコードの設計（coding-design の 7 つの節）

### 部品の一覧

| # | 部品（仮の名） | 置く所 | 1 つの仕事 | 段 |
|---|---|---|---|---|
| P1 | `scripts/notify-relay-put.sh`（新） | validator host（repo の checkout）・後に web host の見張りの bin | 1 通を ops に 1 回渡し、204 でなければ同じ argv・env で `notify.sh` を呼ぶ | 2（判定の部品。8 章の表のとおり倒す） |
| P2 | `scripts/lib/notify-text.sh`（新） | P1 の隣の lib | 優先度の寄せ・優先度の語・稼働率の脚注・既定の題名と本文を 1 か所に持つ | 2 |
| P3 | `scripts/install-notify-relay.sh`（新） | repo（validator host で AI が W7 の 1 手として打つ） | 秘密の置き場を作る・cron の各ファイルの env に `FYD_NOTIFY` を足す／外す・`--dry-run`・`--uninstall`。各モードは別の 1 手 | 2 |
| P4 | `scripts/operator-local/make-notify-relay-token.sh`（新） | 経営者の Mac | 札を 1 つ作り、Mac の手元の 700 の dir の 600 のファイルに書き、sha256 の 1 行だけを画面に出す | 2 |
| P5 | `tests/notify-relay/`（新） | repo・CI | 8 章の表・13 章の主張の試験 | ― |

外部の見張り（`metal-external-watch`）は 12/9 以降の工程（14.4）。そこで `install-web-host-external-watch.sh`（凍結の外）に P1 と P2 を同梱する変更を足す。この設計では形だけを決める（P1・P2 は同じ物を使う）。

### 7.1 フレームワーク・既存の部品

| 使う物 | 理由 |
|---|---|
| `fyd_notify` の `FYD_NOTIFY`（既存） | 委ね先を差し替える口が既に在り、`side-effects.sh` と各 script を変えずに道を替えられる（第 1 版の 16.1 で手元の写しを使って確かめた。`FYD_NOTIFY` が最優先で、終了の番号がそのまま返る） |
| 外部の見張りの `WATCH_NOTIFY`（既存） | 同じく env 1 つで委ね先が替わる |
| `notify.sh`（既存・変えない） | 直の ntfy の唯一の末端。P1 の倒れる道は全てこれを同じ argv・env で呼ぶ |
| `curl`（既存。`notify.sh` が使う） | put の 1 回。札と URL は `-K <(printf …)` の設定で渡し、本文は標準入力（`--data-binary @-`）。新しいソフトを入れない |
| `jq`（既存。`notify.sh` が使う） | 本文の JSON を標準入力から組む（`jq -Rs`）・字数と行数を数える。文を引数に出さない |
| `install-cron-env-headers.sh` の流儀（既存） | P3 の cron の env の足し方の手本（対象は `metal-*`・`freedom-yield-*` だけ・同じ結果なら触らない・書き換える前に写しを取る・cron が実行する名だけを対象にする）。この script は変えない |
| `00_INFRA_TOOLS/conventions` の `no-ai.patterns.json` と `tools/conv_copy.py`（既存） | 12 章の機械の確かめ。写しは SHA256 で照らす |

使わない物: python3（jq と curl で足りる。validator host の道具を増やさない）・ssh（ops への道は HTTPS だけ）・新しい常駐（cron の 1 回の中で終わる）・notify の Python の部品の import（Metal は put の形だけで話す）。

### 7.2 定義の表

| 名 | 値 | 置き場 | 使う所 |
|---|---|---|---|
| `RELAY_PUT_TIMEOUT_SECONDS` | 10 | P1 の定数 | P1 |
| `RELAY_PUT_MAX_BYTES` | 8192 | P1 の定数（渡しの節と同じ値。13 章の試験で照らす） | P1 |
| `RELAY_TEXT_MAX_CHARS` | 2000 | 同上 | P1 |
| `RELAY_PUT_PROJECT` | `Metal` | 同上（本文の `project` の値） | P1 |
| `RELAY_SUCCESS_HTTP_CODE` | `204` | 同上 | P1 |
| `RELAY_TOKEN_PATTERN` | `^[A-Za-z0-9_-]{43}$` | 同上 | P1・P3・P4 |
| `RELAY_URL_PATTERN` | `https://` で始まり、host の部分と `/notify-relay/put` で終わる 1 行（空白・引用符・改行・`\` を含まない）。試し台のために `http://127.0.0.1:<port>/notify-relay/put` だけは通す（17 章の 5） | 同上 | P1・P3 |
| `RELAY_DIR_NAME` | `notify-relay` | P2 の定数 | P1・P3 |
| `RELAY_TOKEN_FILE_NAME`・`RELAY_URL_FILE_NAME` | `token`・`url` | P2 の定数 | P1・P3 |
| 秘密の置き場（relay の dir） | `NTFY_TOPIC_FILE` の dir（未設定なら `notify.sh` の既定の topic のファイルの dir）の下の `RELAY_DIR_NAME`。dir 700・file 600。**repo に新しいパスの文字を足さない**（`notify.sh` の既定の値を P2 の定数 `FYD_NTFY_TOPIC_FILE_DEFAULT` に写し、13 章の試験で `notify.sh` と一字一句同じことを照らす） | P2 の関数 `fyd_relay_dir` | P1・P3 |
| `RELAY_PRIORITY_WORDS` | `urgent=緊急 high=高 default=通常 low=低 min=最低` | P2 の定数（表 1 つ） | P1 |
| `FYD_NOTIFY_TITLE_DEFAULT` | `Freedom Yield ops`（本文が空の時の本文の既定も、題名と同じ文で、題名も空ならこの値） | P2 の定数（題名は `notify.sh` と同じことを試験で照らす。本文が空の時だけ違うことも試験で照らす） | P1 |
| `RELAY_FALLBACK_REASONS` | `no_relay_dir no_token bad_token bad_token_perms no_url bad_url no_curl no_jq too_long bad_text http_<3 桁> curl_<番号>` | P1 の定数（記録の語の一覧。足すだけ） | P1 |
| `RELAY_CRON_ENV_LINE` | `FYD_NOTIFY=<repo の checkout>/scripts/notify-relay-put.sh`（`<repo の checkout>` は P3 が自分の位置から決める） | P3 | P3 |
| `RELAY_CRON_FILE_GLOBS` | `metal-*`・`freedom-yield-*`（`install-cron-env-headers.sh` と同じ範囲） | P3 の定数 | P3 |
| `RELAY_LOG_TAG` | `notify-relay`（OS の記録（`logger -t`）の札の名。新しい記録のファイルを作らない） | P1 の定数 | P1・14.2 の数える台本 |

- パスの文字列は定義の場所の外に書かない（`grep -rnE "['\"](/|\./|\.\./)[A-Za-z]"` を P1〜P4 に当て、定義の行以外で 0 件）
- ops の名・URL・札の値は repo のどこにも無い（P4 が作り、P3 が host の秘密の置き場に書く。13 章の試験で、repo の中に `RELAY_TOKEN_PATTERN` に合う 43 字の並びが新しく増えていないことを gitleaks とは別に数える）

### 7.3 入口／処理／保存（MVC の置き換え）

| 部品 | 入口 | 処理 | 保存 |
|---|---|---|---|
| P1 | `fyd_notify`・外部の見張りからの argv（`<priority> <title> <message...>`）と env（`NTFY_TAGS`・`NOTIFY_STRICT_EXIT`・`NTFY_TOPIC_FILE`・`NOTIFY_UPTIME_SUFFIX`） | 秘密の置き場を読む → P2 で文を描く → 上限を見る → put 1 回 → 番号で分ける | OS の記録（`logger -t notify-relay`）と stderr に固定の 1 行。札・URL・文は書かない。`logger` が無い・失敗しても動きは変えない |
| P2 | P1 からの関数の呼び出し | 寄せ・引き・脚注 | 無し |
| P3 | AI が host で打つ命令（モード 1 つ） | 秘密の置き場の作成と権限・cron の env の行の足し／外し | 秘密の置き場・cron の各ファイル（書く前に写し） |
| P4 | 経営者が Mac で打つ命令 | 札を作る | Mac の手元の 700 の dir の 600 のファイル 1 つ |

### 7.4 デザインパターン

| 所 | パターン | 効くこと |
|---|---|---|
| `fyd_notify`・外部の見張りの委ね先 | Strategy（既存の `FYD_NOTIFY`・`WATCH_NOTIFY` の差し替え） | 道を替えるのに `side-effects.sh`・`external-watch.sh` を変えない |
| P1 | Decorator（`notify.sh` の前に put を 1 回足す。204 以外は素通しで `notify.sh`） | 外せば元の `notify.sh` そのもの |
| P1 の答えの読み | 「204 だけが例外、他は全て倒れる」の 1 つの分け（allowlist） | 新しい番号・新しい失敗の形が来ても、何も足さずに直の ntfy に倒れる |

### 7.5 命名

- 語を混ぜない: 「渡す put」（ops へ）・「倒れる fallback」（直の ntfy へ）・「札 token」・「秘密の置き場 relay の dir」。notify の語（caller・send・route）は Metal の中で使わない（Metal は caller を書かない）
- 台本の名は `notify-relay-` で始める（host の上でこのプロジェクトの物と前方一致で分かる）
- 単位を名に入れる: `_SECONDS`・`_BYTES`・`_CHARS`・`_LINES`

### 7.6 横断の部品

| 部品 | 仕事 | 使う所 |
|---|---|---|
| `scripts/lib/notify-text.sh`（P2） | 優先度の寄せ・優先度の語・稼働率の脚注・既定の題名と本文・relay の dir の場所 | P1・P3（12/7 の後に `notify.sh` もこれに替える。19 章 Q4） |

- 同じ処理を 2 か所に書かない: 優先度の寄せと脚注は、12/7 の後に `notify.sh` を P2 に替えるまで、`notify.sh` と P2 の 2 か所に在る（`notify.sh` は凍結の下流で変えないため）。その間は 13 章の等しさの試験で、同じ入力から同じ文字が出ることを毎回 CI で照らす
- 既存の `fyd__resolve_env`・`install-cron-env-headers.sh` は変えない

### 7.7 部品の大きさとつなぎ目

| 部品 | 1 つの仕事 | つなぎ目 |
|---|---|---|
| P1 | 1 通を ops に 1 回渡すか、`notify.sh` に渡す | 入: `notify.sh` と同じ argv・env／出: 204 なら終了 0、それ以外は `notify.sh` の終了の番号そのもの（`exec` で同じ argv・env のまま渡す）。stdout は 204 の時、既定のモードで `notify.sh` と同じ形の 1 行（`relay PUT: 204`）、strict のモードでは出さない。stderr は固定の 1 行（`notify-relay: put 204` か `notify-relay: fallback <理由の語>`） |
| P2 | 文の部品を作る関数の集まり | `fyd_relay_priority_word <prio>`・`fyd_notify_uptime_footer <repo root>`・`fyd_relay_dir`。どれも標準出力に 1 つの値 |
| P3 | 1 回の命令で 1 つのモード（対象の決め方は 18 章の 2・3・5） | `--install-secrets`（札は標準入力から 1 行、URL は標準入力から 1 行。引数に出さない）・`--enable-cron`・`--disable-cron`・`--uninstall-secrets`・`--dry-run`（どのモードにも付く）。出: 変えたファイルの名の一覧と写しの場所（値は出さない） |
| P4 | 札を 1 つ作る | 出: Mac の手元のファイル 1 つと、画面に sha256 の 1 行（ops の `tokens.json` に足す行の形） |

## 8. 安全な側の表（入力ごとの欠け・想定外。org.md §5.3）

全ての条件が明示的に揃った時だけ put を送り、204 の時だけ終わる。他は全て直の ntfy。

| 所 | 欠け・想定外 | 振る舞い（理由の語） |
|---|---|---|
| relay の dir | 無い・dir でない・読めない | 直の ntfy（`no_relay_dir`） |
| 札のファイル | 無い・読めない・空 | 直の ntfy（`no_token`） |
| 札のファイル | 改行を除いて `RELAY_TOKEN_PATTERN` に合わない（43 字でない・2 行ある・空白を含む） | 直の ntfy（`bad_token`） |
| 札のファイル・dir | group か other が読める・書ける（`find -perm` で見る。Linux・macOS の両方で同じ命令） | 直の ntfy（`bad_token_perms`）。札は使わない |
| URL のファイル | 無い・読めない・空 | 直の ntfy（`no_url`） |
| URL のファイル | `RELAY_URL_PATTERN` に合わない（http・別の道・引用符・空白・2 行） | 直の ntfy（`bad_url`） |
| 道具 | `curl` か `jq` が無い | 直の ntfy（`no_curl`・`no_jq`） |
| 文 | 字数・JSON のバイト数のどちらかが上限を超える | 直の ntfy（`too_long`）。切らない |
| 文 | jq が組めない・組んだ文が元の文と同じ中身にならない（不正な UTF-8 など） | 直の ntfy（`bad_text`）。Signal の文と ntfy の文が違う中身になる形を作らない |
| 答え | `204` | 終わり（終了 0） |
| 答え | `204` 以外の番号（200・201・202 を含む・3xx・4xx・5xx） | 直の ntfy（`http_<番号>`）。転送に従わない（`-L` を付けない） |
| 答え | 時間切れ・接続できない・TLS の誤り・切断・番号が読めない（`000`） | 直の ntfy（`curl_<番号>`） |
| 環境 | `NOTIFY_STRICT_EXIT` の値 | P1 は見ない（put の分けに使わない）。`notify.sh` にそのまま渡る |
| `notify.sh` | P1 の隣に無い | 終了 1（`notify.sh` の「topic が無い」と同じ番号）。stderr に固定の 1 行 |

- 判定の部品の中で、欠けを通る側の既定にする書き方（`${x:-<通る値>}` など）を使わない。欠けは常にこの表の倒れる側
- 答えの本文は読まない（`-o /dev/null`）。番号の 3 桁だけを `-w '%{http_code}'` で受ける

## 9. 外に働きかける口の 5 つの節（憲法 6 章 #20。深さは標準）

新しく開く口は 1 つ: validator host（後に web host の外部の見張り）→ ops の HTTPS の put。

### 9.1 絞った権限（合鍵を渡さない）

- 札は送り手ごとに 1 つ。ops の側では `routes:["put"]` だけに結び付く（渡しの節。ops は sha256 だけを持つ）。札で読めるもの・消せるものは無く、できるのは「1 通を置く」ことだけ
- validator host は ops に札しか持たない。ops と Mac は validator host への資格を何も持たない（来る向きだけ。条件 2）
- 札は process の引数に出さない: `curl -K <(printf 'header = "Authorization: Bearer %s"\n…' …)`。printf は bash の組み込みなので、どの process の argv にも札と URL が載らない（`notify.sh` の `ntfy_url_config` と同じ形）。文は標準入力で渡す
- 札のファイルは root の 600、dir は 700。P1 は権限が緩いと札を使わない（8 章）
- web host の外部の見張りだけは形が違う: 札と URL は `etc/notify-relay/`（dir 750・ファイル 640・持ち主 root・group は見張りの topic のファイルの group）に置き、site アカウントがその group から読む（site の持ち物の木の中では root の 600 にできず、P1 の判定を満たす最小の形）。置くのは site 自身で、root は最後に `chown 0:G` だけを開いたファイルの記述子に対して行う（root が site の木で path を辿って書く・chmod する・消すことは無い）
- 封の署名の鍵は持たない（非目標。渡しの節の問い 2）

### 9.2 上限（額・回数）

- お金: 無し（どの部品もお金を動かさない）
- 回数: 1 通につき put は 1 回（P1 の中でやり直さない。送り手の今のやり直し（strict の 2・4・5）で P1 がもう 1 回呼ばれると put ももう 1 回）。ops の 1 時間 60 通を超えた物は `429` → 直の ntfy
- 大きさ: 本文 8192 バイト・2000 字（6 章。超えたら ntfy だけ）
- 時間: put 10 秒

### 9.3 許可の一覧

- 行き先: relay の dir の `url` の 1 行だけ（`RELAY_URL_PATTERN` に合う時）
- 方法・見出し: `POST`・`Authorization`・`X-Ops-Token`・`Content-Type: application/json` だけ
- 本文の鍵: `project`・`title`・`body` だけ
- 終わる答え: `204` だけ
- cron の env を書き換える範囲: `RELAY_CRON_FILE_GLOBS` に合い、cron が実行する名のファイルだけ。書く行は `RELAY_CRON_ENV_LINE` の 1 行だけ

### 9.4 読まれる記録とその読み手

| 記録 | 中身（札・URL・ops の名・文は入れない） | 読み手 |
|---|---|---|
| validator host の OS の記録（`logger -t notify-relay`。OS の記録の回し方のまま。新しいファイルを作らない） | P1 の固定の 1 行（`put 204` か `fallback <理由の語>`） | 経営者・総監督。14.2 の V6 で 1 日の数を数える台本が読む（送り手の多くは stderr を捨てるので、cron の log では数えない） |
| P3 の出力・写しの dir | 変えたファイルの名・写しの場所 | 承認した経営者・実行した AI |
| ops の記録・Mac の `relay-pull --report` | notify の設計のとおり | notify の側 |
| web host の外部の見張り（`logger -t notify-relay` と site アカウントの `~/metal-fy-watch/log/cron.err`。P1 の同じ固定の 1 行） | `put 204` か `fallback <理由の語>` | 18 時の点検の監督者（web host の log を読む手は経営者の 1 行の承認の後）。見張りの `log/watch.log` の `pushes=` と合わせて見る |

### 9.5 人の承認の所

全て 1 つずつ経営者の 1 行（条件 1・憲法 §5・#1）。14 章の表の「承認」の列が正本:

- P1〜P4 を main へ入れる push
- 札を作る（経営者が Mac で P4 を打つ）・ops の `tokens.json` に sha256 の行を足す（notify の側の手）
- validator host に秘密の置き場を作り、札と URL を置く（P3 `--install-secrets`）
- 本番の倒れる確かめ（ntfy に 1 通送る）
- cron の env に `FYD_NOTIFY` を足す（P3 `--enable-cron`）
- 外す時の各手（`--disable-cron`・`--uninstall-secrets`）
- web host の外部の見張り: `install-web-host-external-watch.sh --notify-relay`（P1・P2 の同梱と cron の WATCH_NOTIFY）と `--relay-secrets`（札と URL）は、各 1 手ずつ経営者が打つ（§5 v0.9 の変更ごとの承認。web host は自分の `metal-fy-watch/` と cron のブロックだけ）。外す手は旗なしの入れ直し・`--uninstall`

## 10. どこで繋ぐか・どう外すか

- **繋ぐ所（2 つ）**
  - validator host: cron の各ファイルの env に `FYD_NOTIFY=<checkout>/scripts/notify-relay-put.sh` の 1 行（P3 `--enable-cron`）。`fyd_notify` を通る全ての送り手がここで替わる。各 script は変えない
  - web host（12/9 以降）: 外部の見張りの env の `WATCH_NOTIFY` を見張りの bin の P1 に
- **入・切の鍵**: `FYD_NOTIFY`・`WATCH_NOTIFY` の行。在れば P1、無ければ今の `notify.sh`
  - 一時に止めたい時は、relay の dir の `url` を外すだけでも全て直の ntfy に倒れる（P1 は `no_url` で `notify.sh` を呼ぶ）。ops の側の `relay.enabled:false` でも全て `503` → 直の ntfy
- **外す**: P3 `--disable-cron`（`FYD_NOTIFY` の行だけを消す。他の行はバイトで同じ）→ 今の動きに戻る。続けて要るなら `--uninstall-secrets`（札と URL を消す）→ ops の `tokens.json` の行を消す（notify の側）。どの段で止めても、残りは今の直の ntfy で動く
- 外して戻る先は今の `notify.sh` の直の ntfy で、`fyd_notify`・各 script・`notify.sh` は繋ぐ前と同じ物。P1・P2 のファイルは repo に残るが、誰も呼ばない

## 11. 流れの図（文字）

```
validator host（cron）
 fyd_notify ──FYD_NOTIFY──▶ notify-relay-put.sh（P1）
                              │ 秘密の置き場・道具・文の上限が全て揃った
                              ├─ put 1 回（10 秒）──▶ ops ── 204 ──▶ 終わり（以後は notify と Mac の責任）
                              │                         └─ 204 以外・時間切れ ─┐
                              └─ 揃わない ─────────────────────────────────────┴─▶ notify.sh（今の直の ntfy）
 FYD_NOTIFY が無い ─────────────────────────────────────────────────────────────▶ notify.sh（今のまま）
```

## 12. この流れに AI を呼ぶ段が無いこと（機械で確かめる）

- P1〜P3 は cron と人の打つ命令だけで動き、AI（Claude・外部の LLM の API）を呼ぶ段は無い。ops と Mac の notify・mac-online も AI を呼ばない（それぞれの設計書）
- 確かめ: `00_INFRA_TOOLS/conventions/no-ai.patterns.json` を `tools/conv_copy.py` で repo に写し（SHA256 で照らす）、`tests/notify-relay/test-no-ai.sh` が P1〜P4 に当てて 0 件であることを見る。`tests/run-all-tests.sh` から呼ぶ（`ci-main.yml` と `validate.yml` の両方が通る）
- 壊して落とす: 試験の一時の写しに API キーの読み込みの行を足すと、検査が落ちる

## 13. 試験の計画（break-to-prove。全て偽の curl・一時の dir。網に出ない）

主張ごとに、壊した実装で 1 度落とす:

1. 偽の curl が `204` を返す時だけ、`notify.sh` が呼ばれない（P1 の 204 の枝を「2xx なら」に広げると、200 の試験で落ちる）
2. 8 章の表の全ての行で、`notify.sh` が**同じ argv・同じ `NTFY_TAGS`・`NOTIFY_STRICT_EXIT`・`NTFY_TOPIC_FILE`**で 1 回だけ呼ばれ、P1 の終了が `notify.sh` の終了と同じ（偽の `notify.sh` が 0・1・2・3・4・5 で終わる 6 通り。倒れる枝の 1 つを消すと落ちる）
3. 偽の curl の型: 503・遅延（`--max-time` で終了 28）・切断（終了 52・56）・TLS（60）・接続できない（7）・番号が読めない（`000`）。全て直の ntfy
4. 札と URL が、偽の curl の argv にも環境にも現れない（偽の curl が自分の argv を書き出し、43 字の札の並びが無いことを見る。`-K` をやめて `-H` に替えると落ちる）
5. 文が標準入力で渡り、本文の JSON の鍵がちょうど 3 つ（未知の鍵を足すと落ちる）
6. 上限: 2000 字・8192 バイトのちょうどと 1 つ超え（行は 31 行以上でも送る）（日本語の 3 バイトの字で字数とバイトの差を作る）。超えたら put を送らない（偽の curl が呼ばれない）
7. 文の作り方: 5 つの優先度と未知の値・既定の題名と本文・脚注の有無で、期待の文字と一字一句同じ
8. 等しさ: P2 の脚注・優先度の寄せ・既定の値・topic の既定のパスが、`notify.sh` の中の物と同じ（`notify.sh` を読む試験。P2 の 1 字を変えると落ちる）
9. 権限: 札のファイルが 644 の時は put を送らない
10. P3: 18 章の 2・3・5 の外す規則（他の委ね先の変数・root でない行・別の topic の dir）が効く・`--enable-cron` を 2 回打っても行は 1 つ・`--disable-cron` の後の cron のファイルが足す前とバイトで同じ・範囲の外の名のファイル（他のプロジェクト・`.bak-…`）を触らない・`--dry-run` は何も書かない
11. 試し台: notify の O4（`php -S` の試し台。`unavailable`・`slow`・`drop`・`ok`）に `http://127.0.0.1:<port>` で向けて、本物の curl で 3 つの倒れる型と 204 を 1 回ずつ（手元だけ。CI には入れない。`php` が無い機械では「試し台が無い」と報告して止まる）
12. AI の検査（12 章）

## 14. 時期と工程（各段は止めれば今の動きのまま）

### 14.1 12/1 より前（repo の中と手元・ops の側）

| 時期 | 工程 | 承認 |
|---|---|---|
| 11/25〜11/27 | 実装の計画（`superpowers:writing-plans`）→ branch の上で P1〜P5 の実装と試験・確認役 1 回 | ― |
| 11/27 ごろ | P1〜P5 を main へ（新しいファイルだけ。凍結の script は差分に無いことを門で見る: 差分のファイル ⊆ `scripts/notify-relay-put.sh`・`scripts/lib/notify-text.sh`・`scripts/install-notify-relay.sh`・`scripts/operator-local/make-notify-relay-token.sh`・`tests/notify-relay/**`・写した `no-ai.patterns.json`・この設計書）。CI が validator host の checkout に届けるが、誰も呼ばない | push は経営者の 1 行（19 章 Q1） |
| 11/28〜11/30 | (a) notify の側の実物の門（ops の箱と振り分け。notify の工程）。(b) 手元の試し台で 13 章の 11 を 1 回 | (a) は notify の側の承認 |

### 14.2 12/1 ごろ（validator host。1 手ずつ）

| # | 手 | 期待する結果 | 戻し方 | 承認 |
|---|---|---|---|---|
| V1 | 経営者が Mac で P4 を打ち、札を 1 つ作る。sha256 の 1 行を notify の側へ渡し、ops の `tokens.json` に足してもらう | 画面に sha256 の 1 行だけ | Mac のファイルを消す | 経営者の手・ops の手は notify の側の 1 行 |
| V2 | P3 `--install-secrets`（札と URL を標準入力で。AI は値を画面にも log にも出さない） | relay の dir 700・2 つのファイル 600。P3 の出力はファイルの名と権限だけ | `--uninstall-secrets` | 経営者の 1 行 |
| V3 | 本番の倒れる確かめ: ops の側が `relay.enabled:false` の間に、validator host で P1 を 1 回、試しの文で打つ | `fallback http_503` の 1 行と、スマホに ntfy で 1 通 | 無し（送るだけ） | 経営者の 1 行（外への送信） |
| V4 | ops の側が `relay.enabled:true` の後、P1 を 1 回、試しの文で打つ | `put 204` の 1 行と、notify の振り分けどおりの 1 通（`live:false` の間は ops の ntfy） | 無し | 経営者の 1 行 |
| V5 | P3 `--enable-cron`（`--dry-run` で対象のファイルの一覧を先に見せる） | 対象のファイルに `FYD_NOTIFY` の行が 1 つずつ。他の行はバイトで同じ | `--disable-cron` | 経営者の 1 行（19 章 Q2） |
| V6 | 12/1〜12/5、1 日 1 回、cron の log の `put 204`・`fallback <語>` の数を数える台本で数え、台帳に 1 行 | `fallback` が 0 か、理由の語が説明できる | `--disable-cron` | ― |

### 14.3 12/6〜12/8（転換をはさむ）

- notify の側は変えない（決定 5 の (c)）。Metal の側も P1・P2・P3 と cron の env を変えない
- 12/7 の転換で手で打つ script は cron の env を持たないので、`FYD_NOTIFY` は効かず、知らせは稽古と同じ `notify.sh` を通る。転換の手順の中で `FYD_NOTIFY` を付けて打たない
- cron の側の知らせは P1 を通る。ops が止まっても 204 以外になり、直の ntfy に倒れる
- `FYD_NOTIFY` を 12/6 に一時に外すかは 19 章 Q3

### 14.4 12/9 以降

1. 外部の見張り（`metal-external-watch`）: `install-web-host-external-watch.sh` に P1・P2 の同梱と `WATCH_NOTIFY`・見張りの秘密の置き場への札と URL を足す（凍結の外。別の設計の工程）。`metal-validator` が live になって 1 週の後（渡しの節の時期）
   - 2026-11-25 の決定で 12/7 の前に前倒し（`metal-validator` の live を待たない）。形: `install-web-host-external-watch.sh` の `--notify-relay`（P1 を `bin/`・P2 を `bin/lib/` に同梱し、cron の行に `WATCH_NOTIFY=<bin>/notify-relay-put.sh` を足す。外す時は旗なしで入れ直す）と `--relay-secrets`（P3 は使わない。site アカウントが `etc/notify-relay/` に札と URL を書き、root は開いた記述子へ `chown 0:G` だけ。9.1）。使い方は `docs/MONITORING_OPS.md` の 14.5
2. `notify.sh` を P2 に替え、優先度の寄せと脚注を 1 か所にする（出力がバイトで同じ試験つき。次の転換の稽古の前に）
3. 封の署名（渡しの節の問い 2）で Metal の側に変更が要るなら、その時に設計する

## 15. 部品ごとの監査の段（org.md §5.1）

| 部品 | 段 | 理由・確かめ |
|---|---|---|
| P1 | 2 | 判定の部品。8 章の表の行ごとの試験と、13 章の 1〜9 を壊して落とす。確認役は束の最後に 1 回 |
| P2 | 2 | 13 章の 7・8 |
| P3 | 2 | host の cron と秘密の置き場を書く。13 章の 10。本番は 14.2 の V2・V5 の期待する結果で 1 回ずつ確かめる |
| P4 | 2 | 札の形と権限・画面に sha256 だけが出ること |
| この設計書 | 1 | 機械の門だけ |

- 段 3 にしない理由: 札は送り先に渡す送りの札で、署名の鍵でもお金の鍵でもない。漏れた時にできるのは ops に 1 通を置くこと（偽の知らせ。17 章の弱さ）で、validator host にも資金にも届かない。迷いは報告に挙げた
- 取り消せない部品（外への送信）の実物の門は 14.2 の V3・V4

## 16. 残る弱さ（隠さない）

- **時間切れの後に ops が受け取っていた時は 2 通**（put の 10 秒の後に 204 が出る形）。渡しの節の残る弱さと同じ
- **送り手のやり直しで put がもう 1 回**: strict の送り手が `notify.sh` の失敗（2・4・5）でやり直すと、P1 が put をもう 1 回送る。1 回目の put が 204 でなかった時だけなので、ops に 2 通は置かれない（1 回目は置かれていない）
- **札が漏れた時**: 持つ者は ops に偽の知らせを置ける（Signal で「本物らしく」届く）。validator host と資金には届かない。札の入れ替えは渡しの節の手順（新しい sha256 を足す → host の札を替える → 古い行を消す）。封の署名（後の工程）で閉じる
- **ntfy の弱さは予備の道に残る**: 直の ntfy に倒れた知らせは、今と同じく中継が読める・topic を知る者が偽を送れる
- **ops が遅い時**: 1 通あたり最大 10 秒の待ちが足される。障害で知らせが重なる cron の 1 回は、その分だけ長くなる
- **長い文は ntfy のまま**（6 章）

## 17. 設計室で決めたこと（設計者の判断。builder と監督が確かめる所）

1. `notify.sh` を凍結の下流として変えない（凍結の名に無いが、凍結の script が呼ぶ）
2. 上限を超える文は切らずに ntfy だけ（6 章）
3. 204 だけが終わり。200・202 も倒れる（渡しの節は「204 以外の全ては ops は何も置いていない」）
4. 秘密の置き場は `NTFY_TOPIC_FILE` の dir の下に置き、repo に新しいパスの文字を足さない。外部の見張りでも同じ規則で見張りの秘密の dir の下になる
5. URL の形は https だけ。ただし `http://127.0.0.1:<port>` は試し台のために通す（url のファイルは root の 600 で、書けるのは root だけ。ふだんの validator host の url は https）
6. 札の権限が緩い時は札を使わない（`bad_token_perms`）
7. 数える・JSON を組むのは jq（新しい道具を足さない）
8. cron の env の足し外しは P3 の 1 つの installer（`install-cron-env-headers.sh` の流儀。その script は変えない）
9. 12/6〜12/8 も `FYD_NOTIFY` は残すのを推奨（19 章 Q3）

## 18. builder check の答え（2026-11-24。新しい確認役 1 回・6 つの問い。全て「答え済み」か「小さな問い（設計者の判断）」で、経営者の判断に上げる物は無かった）

1. **倒れた数を数える元（小さな問い・設計者の判断）**: 送り手の多くは P1 の stderr を捨てる（`check-anomalies.sh`・`external-watch.sh` の `attempt_notify`）。だから P1 は stderr に加えて OS の記録に `logger -t notify-relay` で固定の 1 行を書き、V6 はそれを数える（7.2 の `RELAY_LOG_TAG`・9.4）。新しい記録のファイル・パス・上限を作らず、回し方は OS のまま。`logger` が無い・失敗しても動きは変えない
2. **他の委ね先の変数を持つ cron（小さな問い・設計者の判断）**: P3 `--enable-cron` は、env に `FYD_NOTIFY`・`ANCHOR_NOTIFY`・`WATCH_NOTIFY`・`NOTIFY` のどれかを既に持つ cron のファイルを**対象から外し**、`--dry-run` の一覧に「外した・理由」を出す（明示の選択を上書きしない・`fyd__resolve_env` の WARNING を毎回の log に出さない）。外した物は今の道のまま。数が 0 でなければ実装の計画の報告で挙げる
3. **cron の実行の利用者（小さな問い・設計者の判断）**: 秘密の置き場は root の 700/600。P3 は cron の各行の利用者の欄を読み、root でない行を持つファイルを対象から外して一覧に出す（入れても `no_relay_dir` で倒れ続けるだけで、静かに ntfy のままになるのを避ける）。実装の計画の最初の段で、対象のファイルと利用者を P3 の `--dry-run` で数える（手で読み回さない）
4. **cron の生成の台本の再実行で行が消える（小さな問い・設計者の判断）**: 消えても今の直の ntfy に戻るだけ（安全な側）。12/1〜12/8 は生成の台本を再実行しない運用にし、V6 の数える台本が「`FYD_NOTIFY` の行を持つファイルの数」も毎日数えて、減ったら台帳に 1 行。生成の台本に行を足すのは 12/9 以降（凍結の外だが、この工程の範囲を新しいファイルだけに保つ）
5. **秘密の置き場の dir が 1 つに決まるか（小さな問い・設計者の判断）**: 札と URL は `notify.sh` の既定の topic のファイルの dir の下の 1 か所だけに置く。env に `NTFY_TOPIC_FILE` を明示して別の dir を指す cron のファイルは、P3 が対象から外して一覧に出す（入れても `no_relay_dir` で倒れる）。だから V2 は 1 回
6. **試し台 O4 の置き場（答え済み）**: 共通の部品 notify（`00_INFRA_TOOLS` の `notify/ops/tests/bench/router.php`。経営幹部の repo の計画 commit 6aef5f3 の Task O4）。合格の条件: `unavailable`・`slow`・`drop` で P1 が `fallback`（`http_503`・`curl_28`・`curl_52` か `curl_56`）を書き偽の `notify.sh` が 1 回呼ばれる、`ok` で `put 204` を書き `notify.sh` が呼ばれない。O4 がまだ無い・`php` が無い時は、13 章の 1〜10（偽の curl）だけで合流してよく、11 は 11/28〜11/30 の (b) で手元で 1 回打つ

## 19. 経営者の判断（推奨を先頭に）

| # | 問い | 推奨 | 引き換え |
|---|---|---|---|
| Q1 | P1〜P5（新しいファイルだけ）を 12/1 より前（11/27 ごろ）に main へ入れるか | **入れる**（新しいファイルだけ・凍結の script は差分に無いことを門で見る） | 入れないと 12/1 の差し替えができない（validator host には main しか届かない）。入れても `FYD_NOTIFY` を足すまで誰も呼ばない。代わりに転換の 10 日前に main の頭が動く（凍結の範囲の外） |
| Q2 | cron の env の差し替え（V5）を、全ての対象のファイルで 1 手にするか、1 つの cron から順にするか | **1 手で全て**（`--dry-run` の一覧を見せて 1 行の承認） | 倒れる先が今とバイトで同じなので、まとめても落ちない。順にすると承認の回数が cron の数（十数）に増え、12/5 までの数日の観察が短くなる |
| Q3 | 12/6〜12/8 の間、`FYD_NOTIFY` を残すか、12/6 に外して 12/8 に戻すか | **残す**（手で打つ転換には効かない・ops が止まっても直の ntfy に倒れる・notify の側も凍結） | 外せば転換の前後の知らせは全て今と同じ道になるが、host の手が 2 つ増え、戻した後の確かめがもう 1 回要る |

## 20. 完了の報告の 3 項目（この設計書の段）

- DB の変更: 無し
- 新しい依存: 無し（validator host に新しいソフトを入れない。curl と jq は既に `notify.sh` が使う。新しい外部のサービスは ops で、notify の側の持ち物。新しい秘密は送り手ごとの札 1 つずつ）
- 待っている判断: 19 章の Q1〜Q3・この設計書の承認
