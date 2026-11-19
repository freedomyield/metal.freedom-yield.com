# 公開 repo から刻印のアカウント名を外す — 設計書（2026-11-19 設計室）

> 状態: 承認済み（2026-11-19。§15）。計画は `docs/superpowers/plans/2026-11-19-anchor-name-out.md`。
> 名前の値はこの文書に書かない。役の名前で書く: **刻印のアカウント**（mainnet の anchor 権限を持つアカウント）・**送り先のアカウント**（mainnet の sink）・**稽古の刻印のアカウント**／**稽古の送り先のアカウント**（testnet）。
> 監査の段（部品ごと）: 文書・公開の面 = 段 1／例・schema・試験の fixture = 段 2／門の script・凍結の script = 段 3。

## 1. 目的と理由

- 規則（全体の憲法 6 章 #4 と `public-repo-sanitize`）: 本人のプロジェクトのアカウント名は公開 repo に書かない。例外は **刻印のアカウント名を、公開サイトの検証のページにだけ** 書くこと（理由: 公開している刻印の tx id から誰でも引けるので伏せても守れず、伏せると検証だけが壊れる）。
- 事実（監査室 2026-11-19 の 5(a)(b)(c)）: 例外の外に名前が在る。直して、二度と入らないように門で止める。あわせて `docs/IDENTITY_VERIFICATION.md:21` の事実の誤りを直す。
- 期限: 凍結（転換の script）の前の稼働日 11/21 18:30 までに合流。凍結を危うくする所は 12/7 の後へ回す。履歴は書き換えない（前に進む直しだけ。`public-repo-sanitize` 2 の「作り直し」は、混入が本人の保有ウォレットなど例外で守れないものの時の手で、今回は当たらない — 刻印と送り先の名前は既に公開の tx から引ける）。

## 2. ゴール・やらないこと・失敗の形

- ゴール: (G1) 例外の場所の外の tracked のファイル・ファイル名に 4 つの名前が 0。(G2) 例外の外に名前が入った束は、合流の前の門と CI で落ちる。(G3) 5(c) の文が実物の権限（`linkauth: eosio.token::transfer`）と合う。(G4) 12/7 の転換を 1 行も危うくしない。
- やらないこと: 履歴の書き換え・repo の作り直し・PRIME DIRECTIVE の 4 つの門と `broadcast-guard` の変更・`bin/safe-broadcast` の変更・`publish-guard.sh` と pre-push の PROTECTED の 5 ファイルの変更・刻印の仕組みの変更。
- 失敗の形（動いても失敗）: 検証のページや legacy の生データを伏せて検証が壊れる／門が 12/7 の転換の commit（unit 6・unit 10）を止める／凍結の script を稽古なしで変える／fixture を偽にして試験が「何を守るか」を失う。

## 3. 制約（読んだ事実）

| # | 事実 | 置き場 |
|---|---|---|
| C1 | 凍結: 稽古の後、`docs/cycle-transition-steps.json` の `steps[].scripts` と、`bin/safe-broadcast`・`scripts/lib/side-effects.sh`・`scripts/lib/anchor-history-read.sh`・`scripts/cycle-gate.sh`・`scripts/node-info.sh`・`scripts/check-cycle-anchor-absent.sh` の変更は再稽古と組でだけ。稽古は 2026-11-20 予定 | `docs/CYCLE_GATE.md`「Script freeze」（束ね `718bad8` の `:1725-`）・`docs/REHEARSAL_2026-11-20.md`（束ね） |
| C2 | legacy の 5 ファイルは、チェーンの応答の本文をそのまま持ち、本文の sha256 が封筒と `manifest.json` に入る。1 文字でも変えると検証が落ちる。unit 10 が転換ごとに 1 つ足す | `scripts/verify-legacy-anchor-archive.sh:9-17`・`scripts/archive-legacy-anchors.sh` |
| C3 | 署名した `artifact_manifest`（`public/api/identity.json`）は anchor-receipt・anchor-history の schema と例を pin していない（pin は evidence・validator・cycle-history の schema・incidents・anchor-source の archive）。artifacts_branch の対象は `API_FILES` の 8 つで、今回の対象と重ならない | `public/api/identity.json`・`scripts/gen-anchor-source.sh:570-579` |
| C4 | `deploy.yml` の deploy は `secret-scan`・`publish-guard` だけを待つ。試験の job の赤は deploy を止めない | `.github/workflows/deploy.yml`（`needs:`） |
| C5 | 刻印の script は既に名前を手元の設定から読む（`${FY_CONFIG_DIR:-/etc/freedom-yield}/xpr-account`・`anchor-sink`、無ければ exit 3）。script の中の名前は、コメントと `preview` の期待の 1 行だけ | `scripts/sign-anchor-event.sh:253-290`・`scripts/preview-cycle-anchor-broadcast.sh:398-411,428` |
| C6 | W11: 監査の記録は追記だけ。ただし禁止の文字列は、同じ意味の役の語・`<placeholder>` に置き換えてよい（その目的だけの commit で） | `docs/OPERATING_MODEL.md` W11 の Carve-out |
| C7 | G1（`scripts/check-doc-moves.sh`）: `docs/`・`scripts/` の rename は似ている度合い 100 でないと落ちる。古い basename が例外の外に残っても落ちる | `docs/superpowers/specs/2026-11-10-simplify-refactor-design.md` §9 |
| C8 | 束ね（`dig-bundle` `718bad8`）が、凍結の 3 本・`tests/safe-broadcast/*`・`docs/ANCHOR_ACCOUNT_KEY_ROTATION.md` を触り、`tests/safe-broadcast/fixtures/equivalence-golden.txt` を消す | `git diff --name-only 9c16547 718bad8` |
| C9 | `publish-guard.sh` は層 B で語の sha256 を持つ（値は書かない）。ただしパスを見ない（`--diff` は差分の全文を 1 つに読む）ので、「この場所だけ許す」が書けない | `scripts/publish-guard.sh:50-56,560-563` |

## 4. 機械で分けた表（名前の値は書かない。ファイルと行の数だけ）

道具: `/private/tmp/claude-501/-Users-admin-htdocs-01-PROJECTS-metal-freedom-yield-com/e677490a-ce8b-4541-bd84-15712df7f421/scratchpad/anchor-name-design/classify-name-files.sh`（手元の `names.local` の 4 つの名前を、`git grep -w -F` で数え、場所で分ける。値は出さず、パスの中の名前も `<役>` に伏せる）。実装の担当はこの道具を写して使ってよいが、門（§7）は別に作る（道具は名前の値を読むので repo に入れない）。

数の基準: 束ね `718bad8`（合流の後の main になる木）。main `9c16547` との違いは、刻印のアカウントの試験 1 つ（`equivalence-golden.txt`、4 行。束ねで消える）だけ。main では刻印のアカウントのファイルは 41（監査室の数と一致）。

### 4.1 役 × 分け（ファイル数 / 行数）

| 分け | 刻印 | 送り先 | 稽古の刻印 | 稽古の送り先 |
|---|---|---|---|---|
| ① 検証のページ（`public/verify/`・`public/ja/verify/`） | 2 / 2 | 0 | 0 | 0 |
| ①b 検証の外の公開ページ（`selection-evidence` 英日） | 2 / 2 | 0 | 0 | 0 |
| ② 検証の道具が読むデータ（`public/api/legacy-a-chain/*.json`） | 5 / 10 | 5 / 10 | 0 | 0 |
| ② 同（`public/api/` の正本の json） | 0 | 0 | 0 | 0 |
| ③ 例と schema（`public/api/*.example.*`・`*.schema.*`） | 6 / 25 | 2 / 4 | 0 | 0 |
| ④ script（契約の仕様の md を含む） | 5 / 24 ＋ファイル名 1 | 1 / 1 | 2 / 2 | 1 / 1 |
| ⑤ 試験の fixture と試験 | 12 / 50 | 12 / 14 | 1 / 1 | 0 |
| ⑥ 文書 | 8 / 72 | 3 / 9 | 2 / 17 | 4 / 7 |

ファイルの和（4 つの役を合わせて）: 44（①2・①b 2・② 5・③ 6・④ 7・⑤ 14・⑥ 8）。`public/api/` の正本の json（`anchor-receipt.json`・`anchor-history.jsonl`）は gitignore で、repo に無い（サイトには在る。§5 の判断 1）。

### 4.2 ファイルの一覧と扱い

| 分け | ファイル | 扱い（§5） | lane |
|---|---|---|---|
| ① | `public/verify/index.html`・`public/ja/verify/index.html` | 残す（例外そのもの） | ― |
| ①b | `public/selection-evidence/index.html`・`public/ja/selection-evidence/index.html` | 役の語 ＋ 検証のページへの link | L2 |
| ② | `public/api/legacy-a-chain/<tx>.json` ×5（今後 unit 10 で増える） | 残す（判断 1 の推奨。変えると C2 で検証が落ちる） | ― |
| ③ | `anchor-history.example.jsonl`・`anchor-history.schema.v1.json`・`anchor-receipt.example.json`・`anchor-receipt.phase-beta.example.json`・`anchor-receipt.schema.v1.json`・`anchor-receipt.v2.example.json` | 例は偽の名前（§6.1）、schema の `description` は役の語 ＋「値は /verify/ を見る」 | L2 |
| ④ 凍結 | `scripts/preview-cycle-anchor-broadcast.sh`（7b）・`scripts/sign-anchor-event.sh`（7c）・`scripts/run-testnet-rehearsal.sh`（7a）・`scripts/lib/eosio-pubkey-raw-hex.js`（7a が呼ぶ） | 12/7 の後（判断 2）。それまで門の期限つきの例外 | L5 |
| ④ 凍結の外 | `scripts/notify-anchor-transition.sh`・`scripts/install-anchor-watch-alert-only.sh`（どちらもコメント 1 行） | 役の語 | L3 |
| ④ 凍結の外 | `scripts/operator-local/contract/<刻印のアカウント>-anchor.spec.md`（中身 19 行 ＋ファイル名） | 新しいパス `scripts/operator-local/contract/anchor-contract.spec.md` へ移し、中身は役の語（§6.3 の 2 段） | L1 |
| ⑤ | `tests/anchor-history/fixtures/receipt-live-cycle{3-end,3-start,4-start}.json`・`tests/doc-key-cli-args/test-no-private-key-on-cmdline.sh`・`tests/gen-anchor-receipt/test-gen-anchor-receipt.sh`・`tests/gen-anchor-receipt/test-r13-r18-schema-archive.sh`・`tests/legacy-anchor-archive/test-legacy-anchor-archive.sh`・`tests/safe-broadcast/sb-harness.sh`・`tests/safe-broadcast/test-safe-broadcast.sh`・`tests/sign-anchor-event/test-{block-time-failclosed,quantity-config,sign-anchor-event,signing-host-assertion,xpr-account-config}.sh` | 偽の名前（§6.1） | L3 |
| ⑥ 手順書 | `docs/ANCHOR_ACCOUNT_KEY_ROTATION.md`（5(a)）・`docs/OPERATOR_IDENTITY_SETUP.md`・`docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`・`docs/PHASE_ALPHA_AUDIT_HANDOFF.md`・`docs/IDENTITY_VERIFICATION.md`（5(c)、名前は無い） | 役の語・`<anchor-account>` 等の placeholder ＋「値は手元の設定 `xpr-account`／`anchor-sink` を読む」 | L1 |
| ⑥ 記録 | `docs/audits/constitution-2026-07-03T11-58-audit.md`・`docs/audits/constitution-2026-07-07-C1-C6-audit.md`・`docs/PHASE5_REGEN_EXECUTION_2026-06-22.md`・`docs/IDENTITY_SCHEMA_CHANGELOG.md` | W11 の carve-out（C6）で置き換え。その目的だけの commit | L1 |

## 5. 分けごとの扱い

- **① 検証のページ**: 残す。門の永久の例外（§7）。
- **② 検証の道具が読むデータ**: legacy の生データは、名前がチェーンの応答の本文の一部で、本文の sha256 が検証の対象（C2）。伏せると検証が壊れ、例外の理由（「伏せると検証だけが壊れる」）にそのまま当たる。**例外に含めるかは経営者の判断（§11 の 1）**。推奨は含める。送り先の名前もこの生データの中にだけ在る（同じ理由）。
- **①b・③**: 検証に要らない。①b は役の語 ＋ `/verify/`（`/ja/verify/`）への link。③ の例は偽の名前、schema は文だけ。
- **④**: 凍結の外は今、凍結の 4 本は 12/7 の後（§8）。
- **⑤**: 偽の名前。試験の守る性質（「設定の値が receipt に乗る」「testnet の receipt に mainnet の名前が乗らない」等）は、偽の名前でもそのまま成り立つ（script は名前を設定から読む。C5）。
- **⑥**: 手順書は placeholder、記録は carve-out。
- **稽古（testnet）の 2 つの名前**: 本人のアカウントなので例外に入れない（判断 3）。

## 6. 中身の決め

### 6.1 偽の名前（定義の表は §9.2）

EOSIO の名前の形（`a-z1-5`、12 文字まで）で、長さを実物と同じにする（`test-xpr-account-config.sh` の Case F は「12 文字が通る」を見ている）。偽の名前がチェーンに実在するかは確かめない（外へ接続しない。試験はチェーンに触れない）。

### 6.2 5(c) の文（`docs/IDENTITY_VERIFICATION.md:21`）

今: 「`linkauth` で inscribe 系の action に絞るので、anchor の鍵が漏れても token を動かせない・権限を変えられない・契約を配れない」。
実物（`docs/OPERATOR_IDENTITY_SETUP.md:592`・`:601-603`・`:719-725`）: anchor は `eosio.token::transfer` に linkauth されている。漏れた鍵は、刻印のアカウントからの transfer に署名できる（＝そのアカウントの残高は動かせる）。権限の変更・契約の配備・他の system action はできない。
直した後の文（英文の芯。言い回しは担当）: "It is linked via `linkauth` to `eosio.token::transfer` only. A compromise of the anchor key can therefore sign token transfers out of the anchor account (its balance is exposed), but cannot change permissions, deploy contracts, or sign other system actions." 置き換えは文の中身の直しなので、W11 の記録ではない手順書として普通の commit で直す（この文書は記録ではない）。残高の運用（少なく置く等）は 12/7 の後の候補（総監督の 11-19 の裁定 (c)）で、この設計の外。

### 6.3 契約の仕様の md の移し（C7）

2 段に分ける: (1) `git mv` だけの commit（似ている度合い 100）(2) 中身の置き換えの commit。古いパスを指す文（schema v1 `:176`・⑥ の文書）は新しいパスに替える（L1 と L2 が自分のファイルの中で替える。新しいパスは §9.2 で決め打ち）。G1 は base..HEAD を 1 度に見るので、(1)(2) が同じ範囲だと rename と変更が合わさり 100 を割る。よって **統合は (1) を先に main へ入れる束と、残りの束の 2 回に分ける**か、G1 をこの合流に回さない（G1 は simplify の切りの門）。どちらにするかは統合の担当の監督が決める（§10 の「ビルダーに任せる所」）。

### 6.4 文書の placeholder

`<anchor-account>`（刻印）・`<anchor-sink>`（送り先）・`<rehearsal-anchor-account>`・`<rehearsal-anchor-sink>`。命令の例には `HOME=~/.metal-fy-proton`（`-test`）を残す（§3.5）。値は「手元の設定 `${FY_CONFIG_DIR}/xpr-account`・`anchor-sink` を読む」と 1 行。

## 7. 二度と入らない門（新しい部品）

`scripts/check-account-name-scope.sh`（段 3）。

- 入力: 定義のファイル `config/account-name-scope.tsv`（tracked）。列: `name_sha256`・`role`・`allowed_path_glob`・`until`（`YYYY-MM-DD` か `-`）・`reason`。`#` はコメント。1 行目の非コメントは `enabled<TAB>1|0`。名前の値はどこにも書かず、`sha256(小文字の語)` だけ（`publish-guard.sh` の層 B と同じ形。C9）。
- 照らす物: (a) tracked のファイルの中身（既定 `HEAD` の木。`--index` で staged）(b) tracked のファイルのパス (c) `--messages=<base>` の時、`<base>..HEAD` の commit の文。語の切り方は層 B と同じ `[A-Za-z0-9_]{3,}`（小文字にして sha256）。
- 判定（安全な側に倒す）:
  - exit 2（照らせなかった）: 定義が無い・読めない・形が違う行・名前の行が 0・`enabled` の行が無い・git の失敗・perl と Digest::SHA が無い・走査の完了の印（層 B と同じ末尾の印）が無い。
  - exit 1（落とす）: 名前が、その名前の行の `allowed_path_glob` のどれにも当たらない場所に在る（`VIOLATION <path>:<line> <role>`、値は出さない）／`until` が今日（UTC）より前の行（`EXPIRED`）／どのファイルにも当たらない行（`OBSOLETE`。一覧を縮める）／commit の文に名前（`VIOLATION commit:<short> <role>`）。
  - exit 0: `OK <n> files`。`enabled 0` の時だけ `DISABLED` を出して 0（外し方。§9.8）。
- 最初の行（L4 が作る）: 刻印 × `public/verify/index.html`・`public/ja/verify/index.html`（`-`）／刻印と送り先 × `public/api/legacy-a-chain/*.json`（`-`。判断 1 が A の時だけ）／刻印・送り先・稽古の 2 つ × 凍結の 4 本（`until 2026-12-08`。判断 2 が A の時）。
- 試験のための日付: `FYD_NAME_SCOPE_TODAY`（試験の時だけ）。逃げ道になりうる（未来を過去に見せる）が、門の目的は事故の防止（`pre-push-scan.sh` の SCOPE と同じ）で、わざとの迂回は範囲の外。
- 公開の前に止める所: 合流の前の全体の試験と、統合の担当が push の前に手で 1 回走らせる `--messages=origin/main`（§14 の 2・3）。CI は後ろの網。
- 繋ぐ所: (1) `tests/account-name-scope/test-account-name-scope.sh`（mktemp の repo で、失敗の条件ごとに 1 つの変異で落ちることを見せ、最後に本物の木に `--messages` なしで走らせる。G2 と同じ形）。`tests/run-all-tests.sh` は `test-*.sh` を自動で拾うので、両方の CI（`ci-main.yml`・`validate.yml`）と合流の前の全体の試験に入る。(2) **12/7 の後に** `.githooks/pre-commit` へ `--index` の呼び出し 1 行（L5）。凍結の間に足さない理由: 転換の unit 6（`commit-anchor-source.sh`）と unit 10 が commit を打つので、新しい門の exit 2 が転換を止めうる（G4）。CI だけなら C4 により deploy も止めない。
- 名前のハッシュを公開する害: 刻印は検証のページに値が在り、送り先と稽古の名前は語の組み合わせで推しうる。層 B と同じ受け入れ（事故の防止が目的）。別案（ハッシュも置かず、手元の gitignore の設定と GitHub の secrets から読む）は、CI に secrets の口が 1 つ増え、fork・手元で照らせない。設計室の決め（§10）。

## 8. 凍結に触る所（判断 2）

触る script は 4 本: `preview-cycle-anchor-broadcast.sh`（7b、期待の 1 行 `:428`）・`sign-anchor-event.sh`（7c、コメント 2 行）・`run-testnet-rehearsal.sh`（7a、コメント 1 行）・`scripts/lib/eosio-pubkey-raw-hex.js`（7a が呼ぶ、コメント 1 行）。

- 推奨（A）: 4 本は 12/7 の後の lane L5 で直す。それまで門の期限つきの行で通す。転換の手順書（`docs/CYCLE_GATE.md`）は 12/7 までは 1 行も変わらない。
- L5 の中身（12/7 の後）: コメントは役の語。`preview :428` の「期待」は、今は名前の文字で、設定とは別の出所として経営者の目の照らしに使われている（門 2 で経営者が actor を名指す）。設定から読むと「設定から作った tx を、同じ設定と比べる」になり、照らしが弱くなる。よって期待は **公開の刻印の履歴（`/api/anchor-history.jsonl`）の直前の行の `signing_actor`・送り先** から読み、設定の値と違えば `MISMATCH` で止める（読めなければ止める）。これは 7b の新しい形なので、12/7 の後の最初の稽古で 7b を通してから使う（PRIME DIRECTIVE の門 1 の考え方。7b は送らないが送る道の一部）。`docs/CYCLE_GATE.md` の 7b の照らしの文はその時に変わる（L5 で一緒に）。
- 別案（B）: 11/20 の稽古の前に 4 本を直して稽古に含める。コメントだけなら害は小さいが、稽古の前日に凍結の script を動かす・束ね（C8）と同じファイルを触るので並べにくい。
- 別案（C）: 門そのものを 12/7 の後に回す。11/21 までに外せる 40 近いファイルの直しを門なしで入れることになり、再び入るのを止められない。

## 9. コーディングの設計の 7 つの節

### 9.1 フレームワーク・既存の部品

- 使う: `publish-guard.sh` の層 B の形（語の sha256・完了の印・fail-closed）を写す形で同じ考えを使う。G2（`check-duplicate-functions.sh`）の形（allow の TSV・`OBSOLETE`・本物の木に走らせる試験）。`tests/run-all-tests.sh` の自動の拾い。
- 使わない: `publish-guard.sh` に層を足す（パスを見ないので場所の例外が書けない。C9。しかも pre-push の PROTECTED で、変えるには経営者の判断が要る）。gitleaks の規則（`.gitleaks.toml` は PROTECTED、`[[allowlists]]` の paths で場所の例外は書けるが、名前の値か正規表現を tracked に書くことになる）。新しい依存は無し（bash・git・perl の Digest::SHA は既に門で使っている）。

### 9.2 定義の表

| 名前 | 値 | 置き場 |
|---|---|---|
| 門の定義のファイル | `config/account-name-scope.tsv` | 門の script の先頭の定数 1 つ（`ANS_CONFIG`。試験は `FYD_NAME_SCOPE_CONFIG` で替える） |
| 入・切 | `enabled<TAB>1` | 定義のファイルの 1 行目 |
| 凍結の行の期限 | `2026-12-08` | 定義のファイルの `until` 列（script に書かない） |
| 偽の刻印のアカウント | `fakeanchor12`（12 文字） | 各試験の先頭の変数 1 つ（試験のファイルごとに 1 か所） |
| 偽の送り先 | `fakesink1`（9 文字） | 同上 |
| 偽の稽古の刻印 | `fakeanchtest`（12 文字） | 同上 |
| 偽の稽古の送り先 | `fakesinktest`（12 文字） | 同上 |
| 契約の仕様の新しいパス | `scripts/operator-local/contract/anchor-contract.spec.md` | この設計書（参照する文はこのパスを書く） |
| 文書の placeholder | `<anchor-account>`・`<anchor-sink>`・`<rehearsal-anchor-account>`・`<rehearsal-anchor-sink>` | この設計書 |
| 例外のページ | `public/verify/index.html`・`public/ja/verify/index.html` | 定義のファイル |

### 9.3 MVC（入口／処理／保存）

門: 入口 = 引数の読み（`--index`・`--messages=`）／処理 = 定義の読みと形の検査・走査（perl）・判定／保存 = 無し（標準出力と終了コードだけ）。定義のファイルは Model（データと規則）。

### 9.4 デザインパターン

場所の例外は「データ（TSV の行）を足すだけ」で増える。種類が増える所は無い（照らす物は 3 つで固定）ので Strategy 等の層は置かない（1 回しか使わない所に層を重ねない）。

### 9.5 命名

script は動詞 + 対象（`check-account-name-scope.sh`、既存の `check-*.sh` に合わせる）。関数の接頭辞 `ans_`（`ans_read_scope_rows`・`ans_scan_tracked_files`・`ans_scan_commit_messages`・`ans_report_violation`）。役の語は repo の中で `anchor-account`・`anchor-sink`（既存の設定の鍵 `xpr-account`・`anchor-sink` と対応を文書に 1 行）。

### 9.6 横断の部品

語の sha256 の切り方は `publish-guard.sh` と同じ規則だが、`publish-guard.sh` は PROTECTED で `scripts/lib/` に出せない。門の中に 1 つ持ち、G2 の `scripts/duplicate-functions.allow` に行が要るかを担当が G2 で確かめる（perl の式は関数でないので当たらない見込み）。

### 9.7 部品の大きさとつなぎ目

- `ans_read_scope_rows`: 定義を読み、形が違えば exit 2。返すのは 1 行 1 つの「ハッシュ・役・glob・期限」。
- `ans_scan_tracked_files`: tracked の中身とパスを走査し、「ハッシュ・パス・行」を返す（値は返さない）。
- `ans_scan_commit_messages`: 範囲の commit の文を走査。
- `ans_judge`: 2 つを照らして VIOLATION／EXPIRED／OBSOLETE を出す。
- つなぎ目は標準出力の行の形だけ。外す時は §9.8。

### 9.8 どこで繋ぐか・どう外すか

- 繋ぐ所: `tests/account-name-scope/test-account-name-scope.sh`（CI 2 つと合流の前の全体の試験）、12/7 の後に `.githooks/pre-commit` の 1 行。
- 外し方: 定義の 1 行目を `enabled 0`（門は `DISABLED` で 0。試験の本物の木の段は `DISABLED` を「外された」と表示して通す）。完全に外すなら試験の dir と script と定義の 3 つを消せば元の動きに戻る（他の部品は何も読まない）。
- 例外の足し外し: 定義の行を足す・消すだけ（script を書き換えない）。

### 9.9 憲法 #20（AI が外に働きかける口の 5 つの節）

無し（新しい口を作らない。門は手元と CI で tracked のファイルを読むだけで、外へ送らない・鍵もお金も扱わない）。

## 10. 持ち場の切り方（触るファイルが重ならない）

前提: 束ね（`dig-bundle`）が main に入った後の main から切る。入っていなければ始めず総監督に 1 行（C8）。

| lane | 触ってよいファイル | 段 | 守る性質 | 壊して落とす項目 | 見込み |
|---|---|---|---|---|---|
| L1 文書 | ⑥ の 9 本・契約の仕様の md（移しと中身） | 1 | 4 つの名前が 0／proton の命令の HOME は全て残る（数が直す前と同じ）／記録の 4 本は置き換えだけの commit／5(c) が §6.2 の事実と合う | 置き換えの 1 つを戻すと、L4 の門（手元で `--index` なしで走らせる）が VIOLATION を出す | 60 分 |
| L2 公開の面 | ①b の 2 本・③ の 6 本 | 1〜2 | 検証のページと legacy に触らない（`git diff --name-only` で 0）／example が schema に通る（`scripts/setup-schema-validator.sh` の検査）／`check-identity-pins.sh --mode=repo` の結果が直す前と同じ／`apply-external-link-attrs.sh --check public` が通る | example の名前を 1 つ戻す → 門が落ちる／link の属性を外す → link の検査が落ちる | 45 分 |
| L3 試験と凍結の外の script | ⑤ の 14 本・`notify-anchor-transition.sh`・`install-anchor-watch-alert-only.sh` | 2 | 全体の試験の PASS／FAIL の組が直す前と同じ（G3 の suite の形で照らせる所は照らす）／Case G（testnet の receipt に mainnet の名前が乗らない）が偽の名前で生きている | Case G の確かめを、偽の mainnet の名前が receipt に乗る実装で落とす／fixture の名前を 1 つ戻す → 門が落ちる | 60 分 |
| L4 門 | `scripts/check-account-name-scope.sh`・`config/account-name-scope.tsv`・`tests/account-name-scope/*` | 3 | §7 の判定を全て。値を出力に出さない | 失敗の条件ごとに 1 つ（定義なし・形違い・名前 0・enabled なし・perl なし・完了の印なし・場所の外・期限切れ・OBSOLETE・commit の文・パスの中の名前）、出力に値が出る実装 | 90 分 |
| L5（12/7 の後） | 凍結の 4 本・`docs/CYCLE_GATE.md` の 7b の照らし・`.githooks/pre-commit`・定義の期限つきの行を消す・対応する試験 | 3 | §8 の L5 の中身。7b を稽古で通してから使う | 期待の行を設定から読む実装・履歴が読めない時に通す実装を落とす | 12/7 の後に見積もる |

L1〜L4 は並べてよい。束ねる時の順: L4 の門を最後に足し、木の全体で `OK` を見る（L1〜L3 の残りが在れば L4 の本物の木の段で落ちる）。

## 11. 経営者の判断の束（推奨を先頭に）

1. **検証のために要るデータ（legacy の生データ 5 つと、今後 unit 10 で増える分）を例外に含めるか。**
   - A（推奨）: 含める。例外は「検証のページ ＋ 検証の道具が読む生データ（`public/api/legacy-a-chain/`）」。送り先の名前もこの生データの中だけ例外。サイトが配る正本の receipt・history（repo の外）も同じ扱いと明記。トレードオフ: 例外の場所が 1 つ増える。事業: 第三者が古いチェーンの記録を自分で照らせることがそのまま残る（この validator の「確かめられる記録」の売り）。
   - B: legacy を repo から外して別の置き場で配る。12/7 の unit 10 の作りを変える（凍結）、置き場が 1 つ増える、検証の道具の読み先が変わる。
   - C: 伏せる。本文の sha256 が合わなくなり、legacy の検証が壊れる（例外の理由そのもの）。
2. **凍結の 4 本（7a・7b・7c と 7a が呼ぶ lib）を、いつ直すか。**
   - A（推奨）: 12/7 の後（L5）。それまで門の期限つきの行（2026-12-08 まで）で通す。7b の期待の 1 行は、後で公開の刻印の履歴から読む形にし、稽古で通してから使う。トレードオフ: 3 週間ほど 4 本に名前が残る（コメント 3 行・期待 1 行）。事業: 12/7 の転換を 1 行も危うくしない（報酬の流れの土台が先）。
   - B: 11/20 の稽古の前に直して稽古に含める。速いが、稽古の前日に凍結の script を動かし、束ねと同じファイルが重なる。
   - C: 門ごと 12/7 の後。今の直しが守られないまま 3 週間。
3. **稽古（testnet）の 2 つの名前と、mainnet の送り先の名前を例外に入れるか。**
   - A（推奨）: 入れない（送り先は判断 1 の生データの中だけ）。全部を役の語・偽の名前に替える。トレードオフ: 手順書が placeholder になり、命令を写して打つ時に値を手元の設定から読む 1 手が増える。事業: 本人のアカウントの範囲（ブランドに結びつく名前）を公開 repo に増やさない。
   - B: 稽古の名前は資金の無い testnet なので守る対象の外にする。手順書は今のまま打てるが、規則（#4）の文に「testnet は除く」を足すことになる（全プロジェクトの規則の変更）。

## 12. 設計室が決めた所（経営者が読む時に確かめる所）

- 門は名前のハッシュを tracked の定義に置く（§7 の最後。別案は secrets）。
- 門を pre-commit に繋ぐのは 12/7 の後。凍結の間は CI と合流の前の全体の試験だけ。
- 新しい門と定義を pre-push の PROTECTED に入れない（入れるには PROTECTED の 5 ファイルを変えることになり、経営者の判断が要る。次の工程の候補）。
- 偽の名前は実物と同じ長さ（§9.2）。
- 5(c) の文は手順書の直しとして普通の commit（記録ではない）。
- 記録の 4 本は W11 の carve-out で置き換え（本人のアカウントの名前は「禁止の文字列」に当たると読む。根拠は全体の憲法 #4）。

## 13. ビルダーに任せる所

- 偽の名前に替えた試験で、PASS の数が変わらないことの照らし方（G3 の suite の形が使えるか）。
- 契約の仕様の md の移しを、統合で 2 回に分けるか、G1 を回さないか（§6.3）。
- 門の `--index` の staged の読み方（`git cat-file --batch` 等）と、大きなファイルの扱い。
- 文書の言い回し（英語の文書は英語、日本語の文書は日本語）。

## 14. builder check の答え

2026-11-19 に新しい担当（opus）が読んだ。問い 5 つの扱い:

| # | 問い | 扱い | 答え |
|---|---|---|---|
| 1 | §11 の判断 1〜3 は決まったか | 経営者の判断 | §11 のまま経営者に上げる。答えが出るまで計画を書かない（brainstorming の門）。推奨と違う答えなら §10 の lane を切り直す |
| 2 | 門の「落ちる」は公開の前か後か | 設計室の決め | **公開の前に止める所は、合流の前の全体の試験**（統合の担当が手元で、push の前に回す。lane の branch は push しない）。CI は後ろの網（経営者が直に push した時に気づく所）。12/7 までは、統合の担当が push の前の手順として `check-account-name-scope.sh --messages=origin/main` を手で 1 回走らせ、結果を台帳に 1 行（PROTECTED を変えない）。12/7 の後は pre-commit に繋ぐ（L5）。PROTECTED に入れるかは次の工程の候補（§12） |
| 3 | `--messages` を誰がどの base で呼ぶか | 設計室の決め | 統合の担当が、push の前に `--messages=origin/main`（遠くが既に公開している先）で呼ぶ。新しく送る commit の文だけを見る。過去の文は見ない（書き換えないので照らしても直せない）。CI では呼ばない |
| 4 | 束ねが 11/21 までに入らなかったら | 設計室の決め（日程は総監督） | 束ねと重ならない L2・L4 と、L1 のうち `docs/ANCHOR_ACCOUNT_KEY_ROTATION.md` を除いた残りは `9c16547` から切ってよい。L3（`tests/safe-broadcast/*` が束ねと重なる）と ROTATION は束ねの後。どちらを待つかは総監督が決める |
| 5 | 12/7 の転換が延びた時の `until` | 設計室の決め | 延びた時は、統合の担当が定義の `until` を延ばす 1 行の直しを入れる（総監督の承認・台帳に 1 行。外へ出す一手ではないので経営者に上げない）。期限を転換の完了に自動で結び付けない（門が転換の状態を読むと、新しいつなぎ目が増える） |

担当が機械で確かめて問いから外したもの（設計書の前提と合う）: 4 つの名前に `.` は無く、語の切り方で取りこぼしは出ない／unit 6 が commit するのは `public/api/anchor-source.json` だけで名前は入らない、unit 10 の書く先は `public/api/legacy-a-chain/` の中だけ／`receipt-live-*` の fixture は試験の中で jq で書き換えて使うので、偽の名前に替えても署名・ハッシュの検査は壊れない。

## 15. 承認

- 日付: 2026-11-19
- 判断: §11 の 1 = A・2 = A・3 = A（全て推奨）
- 経営者の言葉: 「SDD増員+30良いので、並行して進めてね。」（総監督はこれを「推奨で承認・並行で進める」と読み、その読みを経営者へ報告した）
- 計画: `docs/superpowers/plans/2026-11-19-anchor-name-out.md`
