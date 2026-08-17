# 単一の真実源へ — 公開・転換・副作用の設計是正

**日付**: 2026-08-06
**状態**: operator 承認済 (section 1-3)。実装は 9/4 の cycle 4→5 転換前に完了させる
**根拠**: 2026-08-04 の転換、8/5 の全数監査、8/6 の設計分析 3 観点 (公開所有権 / 月次転換 / test-prod 境界)

## 1. 問題

3 観点の分析はいずれも同一の根に到達した:

> **「正しい状態」が 1 つの形で存在せず、複数の場所に手書きでコピーされている。**

実測された証拠:

| 領域 | 実測 |
|---|---|
| 公開物 | feed を 1 つ増やすのに最大 **12 箇所**を lock-step で更新 (2 箇所は repo 外 = host の cron と受信 wrapper)。補うための `DEPLOY_OWNERSHIP_MATRIX.md` 203 行が、それ自体 **5 箇所実態とズレていた** |
| 月次転換 | runbook が謳う「9 step」は実際 **13 実行単位 / 3 マシン**。うち **step 7.5 (署名 fragment の scp) と 8.5 (公開 push ×4) が runbook に存在しない**。同じ cycle 番号が script により N と N+1、同じ順序違反が exit 7 と exit 9 |
| test/prod | 同じ「notify を止める変数」が **6 パターン** (`NOTIFY`/`FYD_NOTIFY`/`ANCHOR_NOTIFY`/`WATCH_NOTIFY`/ハードコード 2 本)。broadcast・SSH host・keystore は憲法の縛りで既に opt-in だが、notify・file 書込・state dir は **既定が本番**を指す |

この構造から、2 日で 4 件の本番副作用事故 (本番データ削除・実 ntfy 8 発・実 RPC POST) と、3 日で 3 回の同型 publish 事故が発生した。個々は「不注意」に見えるが、**構造が事故を生産している**。

特に重い 2 件:

- **通常の git commit が署名済み manifest を静かに壊せる**: `identity.json` は 8 artifact の sha256 を pin し ed25519 で署名しているが、2026-08-05 の通常の schema 修正 commit が前日署名の pin を無効化した。実測で **8 pin 中 4 個が 2 日で不一致**。CI にも cron にも検知機構がない。
- **broadcast guard が本番で一度もブロックしていなかった期間がある**: exit 1 で返していたが Claude Code hook 契約は exit 2 のみをブロックとみなす。2026-07-06 の controlled probe で発覚。

## 2. バグの 2 分類

症状は 1 つの class ではなく 2 つで、対策が異なる。

- **Class A「公示したが配信経路がない」(404 class)** — archive 404、peers-history 404。公示リストと配信リストが別々に手書きされているのが原因。**registry で構造的に消える。**
- **Class B「公示した状態が実態から drift する」(stale class)** — anchor-source の stale 公開、identity の pin 劣化、evidence の誤分類。**可変ストリームと不変レコードを同じ仕組みで扱っている**のが原因。registry だけでは消えず、`kind` の区別が要る。

## 3. 設計原理

> すべての「正しい状態」を機械可読な単一宣言に置き、そこから全経路を導出する。人が手で同期する箇所をゼロにする。

3 つの単一真実源 (SoT) を置く。

| SoT | 宣言内容 | 導出されるもの |
|---|---|---|
| `deploy/publication.json` | 公開物 × kind (stream/record/static) × owner × publisher × 公示関係 | feed-excludes、.gitignore ブロック、push allowlist、受信 allowlist、ownership matrix、各 script の artifact 一覧、CI gate |
| `scripts/lib/cycle-context.sh` | cycle 番号の唯一の導出 (刻む番号 = N+1 / 閉じた数 = N)、exit code 翻訳表 | orchestrator の全 phase、各 script へ渡す env |
| `scripts/lib/side-effects.sh` | 本番副作用の唯一の入口 (notify / push / state 書込) | opt-in 判定、DRY 出力、cron lint |

### kind 規律 (Class B の唯一の構造的解)

`anchor-source.json` は意味的に **record** (刻んだ瞬間の署名済み pre-image) だが、**stream の URL** (最新を指す可変 URL) で配られている。これが category error であり、2026-07-07 の stale 事故の真因である。

- **record** = 内容アドレスの**不変 URL** (`api/archive/<content-hash>.json`) に置き、hash で pin してよい
- **stream** = 日々変わる。**hash で pin してはならない** (pin すれば翌日必ず壊れる)

CI gate がこれを機械で強制する: `kind=stream` は `pinned_by` に入れられない。

## 4. コンポーネント

| # | 構成物 | 責務 | 依存 |
|---|---|---|---|
| C1 | `deploy/publication.json` + generator + CI gate | 公開物の宣言と全経路の導出 | なし |
| C2 | `scripts/lib/cycle-context.sh` + `scripts/cycle-transition.sh` | cycle 番号の単一導出 / 13 実行単位の orchestration | C1 |
| C3 | `scripts/lib/side-effects.sh` + cron lint | 本番副作用の唯一の入口 | なし |
| C4 | kind 規律の適用 (pin 対象の是正) | stream を pin しない / record を pin する | C1 |

## 5. 転換当日のデータフロー (C2)

13 実行単位(2026-08-17 時点の既知の差分: `scripts/cycle-transition.sh:113-116`
は 2026-08-14 追加の step 4b を含めて実質 **14** 単位と明記している。この節の
「13」という数え方と、それに基づく phase 構成・番号自体は本タスクの是正対象外
— brief の指示により変更しない。次回の spec 改版で 14 への更新を推奨する)を、
人の介入点で切れる 6 phase に整理する。

**読み方 (2026-08-17 是正、同日中に再訂正)**: 各 `⏸ 停止N` は、直後に続く
phase の**入口**(= その phase を実行するために先に必要な人の操作)として
描く。「phase を終えてから止まる」という exit の読みは誤り。**ただし停止4
だけは例外**: phase5 の入口ではなく phase5 **内部**(unit 7b と 7c の間)に
位置し、かつ性質の異なる 2 つのタイミング (a)/(b) を束ねている — 詳細は
下の根拠を参照。停止 4 つが phase 6 個に均等に付くわけではない点にも注意:
phase 3 (compose) と phase 6 (事後) は対応する停止を持たない (どちらも
host/Mac 側の自動処理のみで、operator の判断待ちが無い)。

```
⏸ 停止1: wallet 操作 (額の判断) → tx id
phase 1  記録      host: node-info tick → uptime-history → gen-cycle-history → 公開 push
⏸ 停止2: identity 鍵 passphrase
phase 2  identity  Mac: gen-identity → commit → push → deploy 着地確認
phase 3  compose   host: gen-anchor-source → Mac へ転送 → commit → push → deploy 着地確認
⏸ 停止3: testnet keystore unlock (broadcast 認可は script 起動そのもので自動成立)
phase 4  rehearsal Mac: testnet 通し稽古 (コマンドを印字して停止)
phase 5  刻印      Mac: preview(7b)
   ⏸ 停止4a: mainnet keystore unlock + broadcast 認可(7b 完了後・7c 直前 —
              phase5 の入口ではなく phase5 内部)
              → 署名+broadcast(7c) → fragment 転送(7.5)
   ⏸ 停止4b: explorer 目視確認(7c 完了後 — phase5 の外の事後確認)
phase 6  事後      host: receipt 7-gate → history append → 公開 push → resume --apply
```

根拠 (`docs/CYCLE_GATE.md` の step 番号 + `scripts/cycle-transition.sh` の
unit 本文で示す):

- **停止1 → phase1 の入口**: step 0 が「everything below の precondition」
  と明記。phase 1 の最初の単位 (step 1, node-info tick 待ち) は新
  AddValidator entry が chain に出るまで意味を成さない。`cycle-transition.sh`
  の phase1 stop テキストも「the precondition for unit 1 below」と同じ位置
  を明記しており、一致。
- **停止2 → phase2 の入口**: phase 2 は `gen-identity.sh` (step 4) そのもの
  で、passphrase はその script 自身が実行中に prompt する入力。「phase 2
  を終えてから passphrase」ではない。`cycle-transition.sh` の phase2 stop
  テキストも「a precondition of phase 2, not a review of it」と明記して
  おり、一致(停止4 のような「(a) は不成立」式の打ち消しは無い)。
- **停止3 → phase4 の入口。ただし「broadcast 認可」の書き方を訂正**:
  phase 4 (= testnet rehearsal, unit 7a) は unlock 済み keystore が無ければ
  実行できない (locked のまま叩くと exit 2) — ここは実装 (`cycle-transition.sh`
  の phase4 stop テキスト、`run-testnet-rehearsal.sh:340,385`) と一致。
  **前回の記述「testnet keystore unlock + broadcast 認可」は、認可を unlock
  とは別の operator アクションであるかのように読めた点で不正確だった**:
  `run-testnet-rehearsal.sh:41-45` によれば、testnet 側の broadcast 認可は
  operator が別途宣言するものではなく、**unlock 済みキーストアでこの
  script を起動すること自体が認可の成立経路**(script が
  `/tmp/fyd-broadcast-token` を自動生成し、`bin/safe-broadcast` がそれを
  admit する)。operator が手で行う前提条件は unlock のみ。
- **停止4 → phase5 の入口ではない。unit 7b と 7c の間、かつ 2 つの異なる
  タイミングを束ねている**(前回是正の Critical な誤り、今回訂正):
  - **(a) mainnet keystore unlock + broadcast 認可**: `scripts/cycle-transition.sh:280`
    が同じ stop についてこう明記している — `OPERATOR, TWICE — AND (a) IS
    NOT DUE YET AT THIS LINE. (a) Between unit 7b and unit 7c, NOT before
    7b: … give the PRIME DIRECTIVE gate-2 per-invocation authorization …
    but 7b is a dry run that needs the mainnet keystore HOME only for the
    separation guard, never an UNLOCKED one`。さらに
    `preview-cycle-anchor-broadcast.sh:329-373` を読むと、7b は認可が名指す
    対象そのもの(memo 4 本・`actor@permission`・quantity・`tx_sha256` に
    content-bound された R16 token)を**自分で生成**し、unlock 行も自身が
    印字する。認可の対象がまだ存在しない 7b の前で認可を与えることは
    機構上できない。よって (a) は phase5 の入口ではなく、phase5 内部・
    7b 完了後・7c 直前に位置する。
  - **(b) explorer 目視確認**: 7c (broadcast) が終わった後にしか行えない、
    正真正銘の事後確認。`docs/CYCLE_GATE.md` step 9 直後の結び文
    (「AI reads back step 7's tx id and reports the explorer URL … gate
    2's authorization happens before that step runs, not after」)が同じ
    区別をしている。

**前回是正の何が誤りだったか、正直に記録する**: 前回、停止4 を
「phase5 の入口として正しい」と書いた。これは「phase を終えてから止まる」
という**出口**の誤りを、「phase5 が始まる前に止まる」という**より具体的な
入口の誤り**に置き換えただけだった — 実装 (`cycle-transition.sh:280`) が
名指しで打ち消している位置に置いてしまっていた。`pstop` 列
(`scripts/cycle-transition.sh:274-282`) だけを見て「stop4 は phase5 に
対応する」という**phase 番号の対応**は合っていたが、phase5 の**どこ**に
位置するかを本文まで読んで照合していなかった。「`scripts/cycle-transition.sh`
と矛盾は見つからなかった」という前回の記述も、この (a)/(b) の打ち消し文を
落とした上での一致主張であり、**撤回する**。`docs/CYCLE_GATE.md` が canon
であることは `cycle-transition.sh:105` 自身が「docs/CYCLE_GATE.md — the
canonical runbook」と明記しており、本 spec の記述はそれを言い換えたもの
(逆ではない)。

### 再開は「記録を信じない」

state file は進捗を持つが、`--resume` は記録ではなく**事後条件を実測し直して** skip 判定する。

| phase | 完了と判定する実測 |
|---|---|
| 1 | 公開 cycle-history がちょうど +1 行、max cycle_n == N |
| 2 | 公開 identity.json の generated_at が cycle 開始後、かつ deploy success |
| 3 | 公開 anchor-source の sha256 が host copy と byte 一致 |
| 5 | mainnet tx が on-chain で解決でき memo prefix が一致 |
| 6 | cycle-gate-state の signature が現行 cycle と一致 |

2026-08-04 に人が手で curl して確かめた照合が、そのまま機械の再開判定になる。同日に実際に起きた「採用不可の中間成果物が host に残る」状況も、事後条件が満たされないため自動的に「やり直し」と判定される。

### broadcast を orchestrator に持たせない

phase 4/5 は env を完全解決したコマンドと R16 token ritual を**印字して停止**するのみ。`proton` / `cleos` / `safe-broadcast` の文字列が orchestrator に存在しないことを CI の grep test で恒久保証する (既存 `tests/broadcast-guard/` と同方式)。憲法の「cycle transition observed から broadcast への自動経路は意図的に存在しない」を維持する。

## 6. エラー処理

- **exit code は翻訳する。renumber しない。** 12 script の内部 code を変えるのは破壊的で、`retryable_notify_rc()` のように数値に依存する呼び出しが 3 箇所コピペされている。orchestrator が `phase → 実行体 → exit code → 意味 + 復旧手順` の表を持ち、`gen-anchor-source exit 9` を「公開 ledger が cycle N まで進んでいない → phase 1 を再実行」と提示する。
- **`broadcast-guard.sh` / `publish-guard.sh` の exit 0/2 は外部契約** (Claude Code hook プロトコル) なので、exit code の統一対象から明示的に除外する。
- **fail-closed の既定**: 前提が確認できないときは進めない。特に (a) 公開 URL が読めないとき local copy を黙って hash しない、(b) 検証 tool が無いとき「検証できない」を「信用する」に解決しない、(c) 非空の履歴から prev link が取れないとき genesis に落とさない。いずれも 2026-08 に実際に踏んだ形。
- **fail-safe を保つ箇所**: 公開 push の失敗で append-only の chain 記録を止めない。ただし loud に報告し、手動 retry コマンドを正確に出力する。

## 7. テスト戦略

- **新規の不変条件はすべて mutation で実証する**: 修正を戻して赤くなることを確認してから緑を報告する。2026-08 の実績で、mutation を通さない test は tautology になっていた例が複数ある。
- **本番副作用は test から到達不能にする** (C3): 既定が dry なので、stub を書き忘れても事故らない。cron 側だけが `FY_LIVE=1` を持つ。
- **C1 の受入条件は「生成物が現状と byte 一致」**: Phase 0 は何も変えないことを証明する commit とし、そこから consumer を 1 つずつ registry 駆動に倒す。
- **CI 配置**: `validate.yml` は `push: branches-ignore: [main]` で main 直 push を見ないため、main を守る gate は `ci-main.yml` にも二重配置する (既存慣行)。

## 8. 移行順序とリスク対策

```
今週    群1: 安い安全策 (runbook 欠落 step / peers-history index 順序 / 矛盾 installer / pin 破れ検知)
8月上   C3 side-effects opt-in 反転   ← 最優先で早期着地
8月上   C1 registry Phase 0 (byte 一致の証明) → CI gate
8月中   C4 kind 規律 / C2 orchestrator 開発
8月下   C2 着地 → testnet 全通し稽古
9月頭   最終 dry-run + --print-only を runbook と突合
9/4     cycle 4→5 転換を新仕組みで実施
```

**C3 を最初に落とす理由**: 「本番 cron が黙って no-op になる」が唯一の怖い失敗モードだから。ただし観測は長さより **cadence の網羅**が効く — 日次 cron が 3 回、月次相当の経路は手動 trigger で確認すれば、それ以上待っても新しい情報は出ない。よって観測は **3 日** (operator 判断、2026-08-06)。3 層で守る:

1. cron の env header に `FY_LIVE=1` が無ければ、既存の `check-cron-file.sh` lint が violation とする (9 本の installer が必ず通る経路)
2. dry 実行時は stderr に `DRY:` を出す (silent failure ではなく可視の dry-run)
3. 着地後 3 日間、**全 cron cadence を 1 周以上**観測して実 artifact の更新を実測確認する (`*/5` `*/15` `*/30` は初日で、日次は 3 回、`04:30` の cycle-history まで含めて mtime 前進・digest 到着・内容変化を確認)

**C2 の退路**: `--print-only` が 13 コマンドを env 完全解決で印字する。orchestrator が当日使えなくても、その出力をそのまま実行すれば現行手順と同一になる。`docs/CYCLE_GATE.md` は引き続き正典であり、phase list と doc の step list が乖離したら CI で fail させる。

## 9. この設計で消えない問題

正直に記録する。

- **registry は repo が生成しないものを支配できない。** 本番の project cron 15 本のうち **7 本は repo に installer が無く**、command body が repo から検証できない (`freedom-yield-peer-geo` / `metal-cycle-history` / `metal-evidence` / `metal-node-health` / `metal-peer-validators` / `metal-renewal-ics` / `metal-uptime-history`)。SoT を名乗る仕組みが本番の 47% を見ていないのに「カバー済み」と誤認するのが最も危険な失敗形なので、`/etc/cron.d` は **registry の外部 surface** として明示宣言し、alert-only の reconciler (registry が知らない cron / Rule 6 違反 / 前回観測からの content 変化を日次で通知) で補完する。書き込まないので事故らない。2026-08-06 に `freedom-yield-peer-geo` が是正手段の射程外だった件は、この盲点が具体化した最初の実例。
- **writer/reader の field 名不一致** (2026-08-04 に踏んだ形) は orchestrator でも registry でも消えない。同型箇所の棚卸しを別タスクで行う。
- **runtime の push 失敗そのもの**は消えない。公示 URL を定期的に HEAD で検査する reconciler (alert-only) で、永久 404 を最大 N 分の 404 に落とす。
- **kind 規律の適用は公開契約 (署名済み manifest の意味論) を変える**。検証ページ・schema・doc を同時に更新する必要がある。
