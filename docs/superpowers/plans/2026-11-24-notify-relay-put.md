# VPS 発の知らせを ops へ 1 回渡す（P1〜P5）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `FYD_NOTIFY` に差し込む委ね先 `notify-relay-put.sh` を作り、ops へ put を 1 回送って 204 の時だけ終わり、それ以外の全てを今の `notify.sh` に同じ argv・env で渡す。あわせて文の部品の lib・host の installer・札を作る道具・試験を、新しいファイルだけで足す。

**Architecture:** P1（Decorator）が `notify.sh` の前に put を 1 回足す。文の部品・既定の値・札と URL の形・秘密の置き場の場所は P2（`scripts/lib/notify-text.sh`）の 1 か所に置き、P1・P3・P4 はそれを source する。P3 は `install-cron-env-headers.sh` の流儀で cron の env に 1 行を足し外しし、秘密の置き場を作る。

**Tech Stack:** bash（macOS の 3.2 と Linux の 5 の両方で動く）・curl・jq・`logger`（あれば）。python3 は P1〜P4 で使わない。

**Spec:** `docs/superpowers/specs/2026-11-24-notify-signal-relay-design.md`（commit 61b88ce・sha256 の先頭 16 字 5a839421280c517a。経営者が 2026-11-24 に承認・19 章の Q1〜Q3 は推奨どおり）。つなぎ目の正本は RF_BusinessStrategy commit 6aef5f3 の `docs/superpowers/plans/2026-11-24-notify-routing.md` の「Metal への渡し」の節

## Global Constraints

- 差分は新しいファイルだけ（`git diff --name-status main...HEAD` が全て `A`）。凍結の script（転換の script・`scripts/lib/side-effects.sh`・`bin/safe-broadcast`・`push-to-web-host.sh`）と `scripts/notify.sh`・`scripts/external-watch.sh`・`scripts/install-cron-env-headers.sh`・`tests/run-all-tests.sh`・`TOOLKIT.md` を 1 行も変えない（試験は `tests/**/test-*.sh` の自動の発見で入る）
- 触ってよいファイル（この一覧の外は門で止める）: `scripts/notify-relay-put.sh`・`scripts/lib/notify-text.sh`・`scripts/install-notify-relay.sh`・`scripts/operator-local/make-notify-relay-token.sh`・`tests/notify-relay/**`・この計画・設計書 `docs/superpowers/specs/2026-11-24-notify-signal-relay-design.md`（この branch で足した物）
- ops の名・URL・札・topic・host 名・IP・人名を repo に書かない。試験の札は試験の中で `/dev/urandom` から作る（43 字の並びを repo に literal で書かない）。試験の URL は `http://127.0.0.1:<port>/notify-relay/put` と `https://relay.example.invalid/notify-relay/put` だけ
- 札と URL を process の argv・stdout・stderr・`logger` に出さない。文は argv に出さず標準入力で渡す
- 判定の部品で、欠けを通る側の既定にする書き方（`${x:-<通る値>}`）を使わない。欠け・想定外は全て直の ntfy に倒す（設計書 8 章）
- 既定の topic のパス `/etc/freedom-yield/ntfy-topic` は P2 の定数 1 か所だけ（`notify.sh` と一字一句同じことを試験で照らす）。他のパスの文字も定義の行の外に書かない（`grep -rnE "['\"](/|\./|\.\./)[A-Za-z]"` が定義の行だけ）
- 関数の名は repo の他の script と重ねない（G2 `bash scripts/check-duplicate-functions.sh` が `OK`）。接頭辞は P1 `relay_put_`・P2 `fyd_relay_`/`fyd_notify_`（設計書 7.7 の名）・P3 `relay_install_`・P4 `relay_token_`
- shellcheck（`shellcheck -x`）が P1〜P4 で 0 件。P1・P3・P4 は git の mode 100755
- AI を呼ぶ段を持たない（設計書 12 章。`no-ai.patterns.json` の写しで機械が確かめる）
- 試験は手元の一時の dir と偽の `curl`・偽の `notify.sh`・偽の `logger` だけ。網に出ない・本物の syslog に書かない・host に触らない

## 設計書から足した決定（監督の裁定。報告で総監督に挙げる）

1. `RELAY_TOKEN_PATTERN`・`RELAY_URL_PATTERN` は P1 でなく P2 に置く（P1・P3・P4 が同じ物を読む。正本を 1 か所に）
2. 倒れる理由の語を 2 つ足す（足すだけ）: `no_lib`（P2 が読めない）・`bad_url_perms`（url のファイルを group か other が読める・書ける）
3. `RELAY_URL_PATTERN` の具体: `^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/notify-relay/put$` か `^http://127\.0\.0\.1:[0-9]{1,5}/notify-relay/put$`（ERE）
4. curl は `-q`（`.curlrc` を読まない）を先頭に付け、stderr を捨てる（名前解決の誤りの文に ops の名が出るため）
5. `notify.sh` の有無は倒れる時にだけ見る（put を先に試し、届けられる道を減らさない）
6. P4 の札の置き場の既定は `$HOME/.metal-fy-notify-relay/<送り手>.token`（環境変数 `FYD_RELAY_TOKEN_DIR` で差し替え）。sha256 は札の 43 字（改行なし）の 16 進の小文字

## Review Focus

1. 末尾が改行で終わる本文: `notify.sh` は `-d "$MSG"` でそのまま送る。P1 の文も末尾の改行を落とさない（Task 1 の `fyd_relay_render_text` は変数に代入し、`$(…)` を通さない）→ Task 1 の試験
2. 札のファイルが「43 字 ＋ 改行 1 つ」の時は通し、「43 字 ＋ 改行 2 つ」「先頭に空白」「CRLF」は `bad_token` → Task 2 の試験
3. `NTFY_TOPIC_FILE` が「設定されているが空」: `notify.sh` と同じく既定のパスに寄る → Task 1 の試験
4. 引数が 0 個・1 個（題名なし）で呼ばれた時も、`notify.sh` へ同じ argv（0 個・1 個のまま）で渡る → Task 2 の試験
5. cron のファイルの末尾に改行が無い・`@reboot` の行・空のファイル → Task 3 の試験

---

### Task 1: P2 文の部品の lib（`scripts/lib/notify-text.sh`）

**Files:**
- Create: `scripts/lib/notify-text.sh`（mode 100644・source される物。`set` を変えない）
- Test: `tests/notify-relay/test-notify-text.sh`（100755）

**Interfaces:**
- Produces（定数。全て readonly にしない＝試験で source し直せるように。値は一字一句この通り）:
  - `FYD_NTFY_TOPIC_FILE_DEFAULT='/etc/freedom-yield/ntfy-topic'`
  - `FYD_NOTIFY_TITLE_DEFAULT='Freedom Yield ops'`・`FYD_NOTIFY_MESSAGE_DEFAULT='(no message)'`
  - `FYD_VALIDATOR_JSON_REL='public/api/validator.json'`
  - `RELAY_DIR_NAME='notify-relay'`・`RELAY_TOKEN_FILE_NAME='token'`・`RELAY_URL_FILE_NAME='url'`
  - `RELAY_PRIORITY_WORDS='urgent=緊急 high=高 default=通常 low=低 min=最低'`
  - `RELAY_TOKEN_PATTERN='^[A-Za-z0-9_-]{43}$'`
  - `RELAY_URL_PATTERN_HTTPS='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/notify-relay/put$'`・`RELAY_URL_PATTERN_BENCH='^http://127\.0\.0\.1:[0-9]{1,5}/notify-relay/put$'`
- Produces（関数。どれも bash 3.2 で動く）:
  - `fyd_notify_normalize_priority <prio>` → stdout に `urgent|high|default|low|min` の 1 つ（他は `default`）
  - `fyd_relay_priority_word <prio>` → 寄せてから `RELAY_PRIORITY_WORDS` を引いた語 1 つ
  - `fyd_notify_uptime_footer <repo_root>` → `<repo_root>/$FYD_VALIDATOR_JSON_REL` が読めて `.uptime.network` が空でも null でもない時だけ `[Uptime] <値>%${NOTIFY_UPTIME_SUFFIX}` を出す（改行なし）。他は何も出さない。jq の式は `notify.sh` と同じ `.uptime.network // empty`
  - `fyd_relay_dir` → `${NTFY_TOPIC_FILE}` が空でなければその dir、空・未設定なら `FYD_NTFY_TOPIC_FILE_DEFAULT` の dir の下の `RELAY_DIR_NAME`（`notify.sh` の `${NTFY_TOPIC_FILE:-…}` と同じ寄り方）
  - `fyd_relay_url_is_valid <url>` → 2 つの URL の形のどちらかに合えば 0（1 行・空白や引用符や `\` を含まない）
  - `fyd_relay_token_is_valid <token>` → `RELAY_TOKEN_PATTERN` に合えば 0
  - `fyd_relay_render_text <repo_root> [argv…]` → 変数 `FYD_RELAY_TEXT` に代入（stdout に出さない）。argv は P1 が受けた argv そのもの（`<prio> <title> <message…>`、欠けてよい）。形は `【<語>】<題名>` 改行 `<本文>`。題名は `${2}` が空・欠けなら既定、本文は 3 つ目以降を空白で繋いだ物（空なら既定）、脚注が出る時は本文の後に改行 2 つと脚注（`notify.sh` の `MSG` と同じ）

- [ ] **Step 1: 試験を書く** `tests/notify-relay/test-notify-text.sh`。一時の dir に `public/api/validator.json` を作って source する。主張:
  - `fyd_notify_normalize_priority` の 5 つの値はそのまま・`urgent2`・空・`HIGH` は `default`
  - `fyd_relay_priority_word`: urgent→緊急・high→高・default→通常・low→低・min→最低・`bogus`→通常
  - 文: `fyd_relay_render_text "$root" high "題" "本文 1" "本文 2"` → `FYD_RELAY_TEXT` が `【高】題\n本文 1 本文 2\n\n[Uptime] 87.31%`（validator.json の `uptime.network` を `87.31` にした時）。脚注の無い時（ファイル無し・`null`・空・壊れた JSON の 4 通り）は `【高】題\n本文 1 本文 2` で終わる。`NOTIFY_UPTIME_SUFFIX=' (予定 87.40%)'` の時は脚注の末尾に付く
  - 欠け: 引数 0 個 → `【通常】Freedom Yield ops\n(no message)`。題名 `""` → 既定の題名。本文の末尾の改行が残る（`$'行\n'` を渡すと `FYD_RELAY_TEXT` の末尾が改行）
  - `fyd_relay_dir`: 未設定・空 → `/etc/freedom-yield/notify-relay`。`NTFY_TOPIC_FILE=$tmp/a/topic` → `$tmp/a/notify-relay`
  - URL の形: 通る `https://relay.example.invalid/notify-relay/put`・`https://relay.example.invalid:8443/notify-relay/put`・`http://127.0.0.1:18080/notify-relay/put`。落ちる `http://relay.example.invalid/notify-relay/put`・`https://relay.example.invalid/notify-relay/put/x`・`https://relay.example.invalid/other`・`https://a b/notify-relay/put`・`https://relay.example.invalid/notify-relay/put"`・改行を含む 2 行・空
  - 札の形: 試験の中で作る 43 字は通る・42 字・44 字・`+` か `/` を含む 43 字・空は落ちる
  - **等しさ（設計書 13 章の 8）**: 本物の `scripts/notify.sh` を一時の dir の `scripts/` に写し、隣の `public/api/validator.json`・一時の topic のファイル・PATH の先頭の偽の `curl`（`-H` と `-d` の値をファイルに書いて `204` を出す）で、既定のモードで打つ。同じ argv の 6 組（5 つの優先度 ＋ `bogus`・脚注あり／なし・`NOTIFY_UPTIME_SUFFIX` あり・引数 0 個・題名だけ）で、偽の curl が受けた `-d` の値 ＝ `FYD_RELAY_TEXT` の 2 行目以降、`Title:` の値 ＝ 1 行目の `】` の後、`Priority:` の値 ＝ `fyd_notify_normalize_priority` の値
  - 等しさ（字の照らし）: `notify.sh` の中の `NTFY_TOPIC_FILE:-` の後の既定のパスが `FYD_NTFY_TOPIC_FILE_DEFAULT` と同じ（grep で取り出して比べる）

- [ ] **Step 2: 走らせて落ちるのを見る** `bash tests/notify-relay/test-notify-text.sh` → lib が無いので FAIL
- [ ] **Step 3: `scripts/lib/notify-text.sh` を書く**（上の Interfaces のとおり。ファイルの頭に `CHAIN: none`・`PRIME_DIRECTIVE: TESTNET-FIRST — safe.` の注記と、`notify.sh` と 2 か所に在る理由（設計書 7.6）を書く）
- [ ] **Step 4: 走らせて全て通る**。`shellcheck -x scripts/lib/notify-text.sh` が 0 件
- [ ] **Step 5: 壊して落とす（break-to-prove）**: (a) `RELAY_PRIORITY_WORDS` の `高` を別の字に (b) 脚注の前の改行を 1 つに (c) 既定の題名の 1 字を変える (d) URL の形の末尾の `$` を外す — それぞれ一時の写しで試験が落ちることを見て、報告に落ちた試験の名を書く（repo には残さない）
- [ ] **Step 6: Commit** `git add scripts/lib/notify-text.sh tests/notify-relay/test-notify-text.sh` → `feat(notify-relay): add shared text/format lib for the relay put (P2)`

### Task 2: P1 委ね先（`scripts/notify-relay-put.sh`）と変異の網

**Files:**
- Create: `scripts/notify-relay-put.sh`（100755）
- Test: `tests/notify-relay/test-notify-relay-put.sh`（100755）・`tests/notify-relay/test-notify-relay-mutants.sh`（100755）・`tests/notify-relay/lib-fakes.sh`（100644。偽の curl・notify.sh・logger を一時の dir に作る試験の部品。Task 3〜5 も使ってよい）

**Interfaces:**
- Consumes: Task 1 の全て（`$(dirname "$0")/lib/notify-text.sh` を source）
- Produces: 入は `notify.sh` と同じ argv・env。出は、204 なら終了 0（`NOTIFY_STRICT_EXIT` が `1` でなければ stdout に `relay PUT: 204` の 1 行・`1` なら stdout に何も出さない）、それ以外は `exec bash "<P1 の dir>/notify.sh" "$@"`（元の argv のまま）の終了の番号。stderr は固定の 1 行 `notify-relay: put 204` か `notify-relay: fallback <理由の語>`。同じ 1 行を `logger -t notify-relay` に（`logger` が無い・失敗しても動きを変えない）
- 定数（P1 の中）: `RELAY_PUT_TIMEOUT_SECONDS=10`・`RELAY_PUT_MAX_BYTES=8192`・`RELAY_TEXT_MAX_CHARS=2000`・`RELAY_TEXT_MAX_LINES=30`・`RELAY_PUT_SCHEMA='notify.relay.put'`・`RELAY_PUT_SCHEMA_VERSION=1`・`RELAY_SUCCESS_HTTP_CODE='204'`・`RELAY_LOG_TAG='notify-relay'`・`RELAY_FALLBACK_REASONS='no_lib no_relay_dir no_token bad_token bad_token_perms no_url bad_url bad_url_perms no_curl no_jq bad_text too_long http_<3 桁> curl_<番号>'`

確かめる順（最初に当たった語で倒れる）: `no_lib` → `no_relay_dir`（無い・dir でない・読めない）→ `bad_token_perms`（dir を group か other が読める・書ける）→ `no_token`（無い・読めない・空）→ `bad_token`（中身が「札」か「札＋改行 1 つ」でない）→ `bad_token_perms`（ファイル）→ `no_url` → `bad_url`（中身が「URL」か「URL＋改行 1 つ」でない・形に合わない）→ `bad_url_perms` → `no_curl` → `no_jq` → `bad_text`（jq の往復で元の文とバイトが違う。不正な UTF-8 など）→ `too_long`（行数 ＞ 30・字数 ＞ 2000・本文の JSON のバイト数 ＞ 8192 のどれか。数えるのは jq と `LC_ALL=C wc -c`）→ put。権限は `find <path> -prune \( -perm -0040 -o -perm -0020 -o -perm -0004 -o -perm -0002 \)` が何か出したら緩い（Linux・macOS 同じ命令）

put の形（設計書 5 章）: `curl -q -K <(関数が printf で書く設定) -sS -o /dev/null -w '%{http_code}' --max-time "$RELAY_PUT_TIMEOUT_SECONDS" --data-binary @-`。設定は `url = "…"`・`header = "Authorization: Bearer …"`・`header = "X-Ops-Token: …"`・`header = "Content-Type: application/json"` の 4 行。本文は文を標準入力から読んで組む: `jq -Rsjc --arg s "$RELAY_PUT_SCHEMA" --argjson v "$RELAY_PUT_SCHEMA_VERSION" '{schema:$s,schema_version:$v,text:.}'`（文を argv に出さない）。本文は `printf '%s'` の管で curl の標準入力へ。curl の stderr は `/dev/null`。`-L` を付けない。答えの分け: curl の終了が 0 でない → `curl_<終了>`／0 で番号が `204` → 終わり／0 で番号が `^[1-9][0-9]{2}$` → `http_<番号>`／他（`000`・空）→ `curl_<終了>`

- [ ] **Step 1: 試験の部品 `lib-fakes.sh` を書く**: `relay_fake_setup` が一時の dir に `scripts/`（本物の P1・本物の lib を写す・偽の `notify.sh`）・`bin/`（偽の `curl`・偽の `logger`）・秘密の置き場（`NTFY_TOPIC_FILE=$dir/etc/ntfy-topic`・`$dir/etc/notify-relay/{token,url}` を 700/600）を作る。偽の curl は argv を 1 行ずつ・標準入力・`-K` の中身を別々のファイルに書き、`FAKE_CURL_CODE`（既定 204）を stdout に出し `FAKE_CURL_RC`（既定 0）で終わる。偽の notify.sh は argv と env の 4 つ（`NTFY_TAGS`・`NOTIFY_STRICT_EXIT`・`NTFY_TOPIC_FILE`・`NOTIFY_UPTIME_SUFFIX`。未設定と空を区別して `set`/`unset` で書く）をファイルに書き、`FAKE_NOTIFY_RC`（既定 0）で終わる。札は `/dev/urandom` から作る
- [ ] **Step 2: 試験を書く** `test-notify-relay-put.sh`（設計書 13 章の 1〜9 と 8 章の表の全ての行）:
  1. 204 → 偽の notify.sh が呼ばれない・終了 0・stdout が `relay PUT: 204`（strict の時は空）・stderr が `notify-relay: put 204`
  2. 200・201・202・301・400・401・429・503 → `fallback http_<番号>`・偽の notify.sh が 1 回
  3. 偽の curl の終了 7・28・52・56・60 → `fallback curl_<終了>`。終了 0 で番号 `000` → `fallback curl_0`
  4. 8 章の表の各行（dir 無し・dir がファイル・札無し・札が空・札 42 字・札 2 行・札 CRLF・札＋改行 2 つ・札 644・dir 755・url 無し・url が http の別の host・url 2 行・url 644・PATH に curl 無し・PATH に jq 無し・lib を消した写し）→ それぞれの語で倒れ、偽の curl が呼ばれない
  5. 倒れる全ての行で、偽の notify.sh の argv が P1 の argv と同じ（引数 0 個・1 個・空の題名・空白を含む本文・末尾の改行の本文を含む）、env の 4 つが同じ（未設定は未設定のまま）、P1 の終了が `FAKE_NOTIFY_RC` の 0〜5 の 6 通りと同じ
  6. 札 43 字 ＋ 改行 1 つは通る（put が送られる）
  7. 札と URL が偽の curl の argv にも env にも無い（argv のファイルと `env` の出力を札と URL の字で grep して 0 件）。P1 の stdout・stderr・偽の logger の記録にも無い
  8. 本文: 偽の curl の標準入力が JSON で、鍵がちょうど `schema`・`schema_version`・`text` の 3 つ、値が `notify.relay.put`・`1`・Task 1 の文。`-K` の中身に `Authorization: Bearer <札>` と `X-Ops-Token: <札>` と `Content-Type: application/json` と url が在る。argv に `-L` が無く、先頭が `-q`、`--max-time` の次が `10`
  9. 上限: 30 行ちょうどは送る・31 行は `too_long`。2000 字ちょうど（`あ` を使い、バイトは 6000 を超えるが JSON 8192 以下に収まる長さ）は送る・2001 字は `too_long`。JSON が 8192 バイトちょうどになる文（ASCII で長さを合わせる）は送る・8193 は `too_long`。`too_long` の時は偽の curl が呼ばれない
  10. 不正な UTF-8（`$'\xff'`）を含む本文 → `bad_text`
  11. 偽の notify.sh が P1 の隣に無い写しで倒れる → 終了 1・stderr に固定の 1 行
  12. 偽の logger が失敗（終了 1）しても終了の番号と stdout は同じ
  13. 外部の見張りの形: P1 を `bash` を付けずに直に実行しても同じ（mode 100755）
- [ ] **Step 3: 走らせて落ちるのを見る**（P1 が無い）
- [ ] **Step 4: `scripts/notify-relay-put.sh` を書く**（`set -u -o pipefail`。`set -e` は使わない。関数は 40 行を目安に分ける: 秘密の置き場を読む・文を組む・上限を見る・put する・倒れる・記録する）
- [ ] **Step 5: 走らせて全て通る**。`shellcheck -x scripts/notify-relay-put.sh` 0 件
- [ ] **Step 6: 変異の網 `test-notify-relay-mutants.sh` を書く**: P1 の一時の写しに 1 つずつ sed で変異を入れ、環境変数 `RELAY_P1_UNDER_TEST=<写しのパス>` で `test-notify-relay-put.sh` を走らせ、**全ての変異で FAIL** なら PASS（1 つでも生き残れば、その変異の名を出して FAIL）。`test-notify-relay-put.sh` は `RELAY_P1_UNDER_TEST` が在ればそれを試す（無ければ repo の P1）。変異の一覧（段 3 の判定の所。少なくとも次の 12）: 204 の比べを `2*` に／`-K` をやめて `-H "Authorization: Bearer …"` を argv に／権限の確かめを消す／URL の形の確かめを常に真に／札の形の確かめを常に真に／`too_long` の行数の比べを `-le 31` に／字数の上限を 2001 に／バイトの上限を 8193 に／`-L` を足す／`--max-time` を消す／倒れる時に argv の 1 つ目を落とす（`shift`）／`bad_text` の確かめを消す。各変異の sed が写しに当たらなかった（変わらなかった）時も FAIL にする（網が空振りしないように）
- [ ] **Step 7: 網を走らせて PASS**（変異ごとの FAIL の数を報告に）
- [ ] **Step 8: Commit** `feat(notify-relay): add the relay put delegate with ntfy fallback (P1)`

### Task 3: P3 host の installer（`scripts/install-notify-relay.sh`）

**Files:**
- Create: `scripts/install-notify-relay.sh`（100755）
- Test: `tests/notify-relay/test-install-notify-relay.sh`（100755）

**Interfaces:**
- Consumes: Task 1（`fyd_relay_dir`・`RELAY_*_FILE_NAME`・`fyd_relay_token_is_valid`・`fyd_relay_url_is_valid`）と `scripts/lib/cron-filename-guard.sh` の `is_cron_executed_filename`（source するだけ・変えない）
- Produces: 1 回の命令で 1 つのモード（2 つ以上・0 個は使い方の誤り 1）。`--dry-run` はどのモードにも付き、何も書かない
  - `--install-secrets`: 標準入力の 1 行目を札、2 行目を URL として読む（argv に出さない）。どちらかが形に合わない・3 行目がある → 終了 4・何も書かない。`fyd_relay_dir` を 700 で作り、`token`・`url` を umask 077 の一時のファイルから `mv` で 600 に置く（上書きは入れ替え）。出力はファイルの名と権限だけ（例 `installed: token (600)`）
  - `--uninstall-secrets`: `token`・`url` を消し、空なら dir を消す。無ければ `absent: …` で終了 0
  - `--enable-cron`: cron の dir（`FYD_CRON_DIR`・既定 `/etc/cron.d`）の `metal-*`・`freedom-yield-*` で、`is_cron_executed_filename` に合うファイルだけを見る。行 `FYD_NOTIFY=<P3 の repo の根>/scripts/notify-relay-put.sh` を、最初のコマンドの行（空行・`#`・`[A-Z_]+=` でない最初の行）の直前に 1 つ足す。外す（書かない）物と出力の語: 既に同じ行あり → `ok:`／`FYD_NOTIFY`・`ANCHOR_NOTIFY`・`WATCH_NOTIFY`・`NOTIFY` の env 行を既に持つ → `excluded: <名> (other_delegate)`／`NTFY_TOPIC_FILE=` の env 行を持つ → `excluded: <名> (own_topic_file)`／コマンドの行の利用者の欄（`@…` で始まる行は 2 つ目、他は 6 つ目）が `root` でない行が 1 つでも → `excluded: <名> (non_root_user)`／コマンドの行が無い → `excluded: <名> (no_commands)`／cron が実行しない名 → `skipped (not a cron-executed filename): <名>`。足す前に `FYD_BACKUP_DIR`（既定 `/var/backups/metal-notify-relay-<UTC の時刻>`）へ `cp -p`。足した後に行がちょうど 1 つ在ることを確かめ、違えば写しから戻して終了 3。最後に `summary:`（`DRY-RUN summary:`）の 1 行に数
  - `--disable-cron`: 同じ範囲のファイルから `^FYD_NOTIFY=.*/scripts/notify-relay-put\.sh$` の行だけを消す（写しを取ってから）。他の行はバイトで同じ
  - root の要否: cron のモードは `FYD_CRON_DIR` が既定の時、秘密のモードは `NTFY_TOPIC_FILE` が未設定の時に root でなければ終了 2
  - 定数（P3 の中）: `RELAY_CRON_DIR_DEFAULT='/etc/cron.d'`・`RELAY_CRON_FILE_GLOBS='metal-* freedom-yield-*'`・`RELAY_CRON_DELEGATE_VARS='FYD_NOTIFY ANCHOR_NOTIFY WATCH_NOTIFY NOTIFY'`・`RELAY_BACKUP_DIR_PREFIX='/var/backups/metal-notify-relay-'`・`RELAY_CRON_USER='root'`

- [ ] **Step 1: 試験を書く**（全て `FYD_CRON_DIR`・`FYD_BACKUP_DIR`・`NTFY_TOPIC_FILE` を一時の dir に向ける）:
  1. `--enable-cron` → 対象のファイルに行が 1 つ・コマンドの行の直前・他の行はバイトで同じ（足した行を消した物が元と `cmp` で同じ）・写しが在る
  2. 2 回打っても行は 1 つ（2 回目は `ok:`・写しを取らない）
  3. `--disable-cron` の後、ファイルが足す前と `cmp` で同じ（末尾に改行の無いファイル・`@reboot` の行のファイル・SHELL/PATH/FY_LIVE の行を持つファイルを含む）
  4. 外す規則 4 つ（other_delegate・own_topic_file・non_root_user・no_commands）でファイルがバイトで同じ・出力に語
  5. 範囲の外（`other-project`・`metal-x.bak-20261124`・`freedom-yield-y.disabled`）を触らない
  6. `--dry-run` は cron にも秘密の置き場にも写しの dir にも何も書かない（前後の `find … -newer` で 0 件・dir が増えない）
  7. `--install-secrets`: 正しい 2 行 → dir 700・ファイル 600・中身が札と URL＋改行。札が形違い・URL が http の別の host・3 行・1 行だけ → 終了 4・何も書かない。出力（stdout・stderr）に札と URL の字が無い
  8. `--uninstall-secrets` の後、dir が無い。2 回目は `absent:`
  9. モードが 0 個・2 個・知らない引数 → 終了 1
  10. root の要否: 一時の dir に向けない時は root でない手元で終了 2（`id -u` が 0 の機械では飛ばして `SKIP` と書く）
- [ ] **Step 2: 走らせて落ちるのを見る**
- [ ] **Step 3: `scripts/install-notify-relay.sh` を書く**（`install-cron-env-headers.sh` の流儀。`chmod --reference` が無い macOS は 644 に寄せる所まで同じ）
- [ ] **Step 4: 走らせて全て通る**。shellcheck 0 件
- [ ] **Step 5: 壊して落とす**: (a) 足す位置をファイルの頭に (b) `non_root_user` の確かめを消す (c) disable の正規表現を `^FYD_NOTIFY=` だけに（他の委ね先の行を消してしまう試験を 4 に含める） (d) `--dry-run` でも写しを取る — 一時の写しで落ちるのを見て報告に
- [ ] **Step 6: Commit** `feat(notify-relay): add the host installer for relay secrets and cron env (P3)`

### Task 4: P4 札を作る道具（`scripts/operator-local/make-notify-relay-token.sh`）

**Files:**
- Create: `scripts/operator-local/make-notify-relay-token.sh`（100755）
- Test: `tests/notify-relay/test-make-notify-relay-token.sh`（100755）

**Interfaces:**
- Consumes: Task 1 の `RELAY_TOKEN_PATTERN`・`fyd_relay_token_is_valid`（`$(dirname "$0")/../lib/notify-text.sh` を source）
- Produces: `make-notify-relay-token.sh <送り手>`。送り手は `metal-validator`・`metal-external-watch` だけ（他は終了 1）。札 = `/dev/urandom` の 32 バイトの base64url（`+/`→`-_`・`=` と改行を消す）43 字。形に合わなければ終了 3（作り直さない）。置き場 `${FYD_RELAY_TOKEN_DIR}`（空・未設定なら `$HOME/.metal-fy-notify-relay`）を 700、ファイル `<送り手>.token` を umask 077 で 600・中身は札＋改行。ファイルが既に在れば終了 2（上書きしない）。stdout はちょうど 1 行 `{"<sha256>":{"sender":"<送り手>","routes":["put"]}}`（sha256 は札 43 字・改行なしの 16 進の小文字。`sha256sum` か `shasum -a 256` の在る方）。stderr は置いたファイルの名だけ（札は出さない）
- 定数: `RELAY_TOKEN_SENDERS='metal-validator metal-external-watch'`・`RELAY_TOKEN_DIR_DEFAULT_NAME='.metal-fy-notify-relay'`・`RELAY_TOKEN_RANDOM_BYTES=32`

- [ ] **Step 1: 試験を書く**: 正しい送り手 → ファイルが 600・dir が 700・中身が形に合う 43 字＋改行・stdout の 1 行が JSON として読めて鍵が札の sha256（試験の側で計算）・`sender` と `routes` が期待どおり・stdout と stderr に札の字が無い／2 回目は終了 2 でファイルが変わらない／知らない送り手・引数 0 個 → 終了 1・何も作らない／2 回作った札が違う（2 つの置き場で）
- [ ] **Step 2: 落ちるのを見る** → **Step 3: 書く** → **Step 4: 通る・shellcheck 0 件**
- [ ] **Step 5: 壊して落とす**: (a) stdout に札を足す (b) umask を消して 644 に (c) 既存のファイルを上書き — 落ちるのを見て報告に
- [ ] **Step 6: Commit** `feat(notify-relay): add the operator-local token maker (P4)`

### Task 5: 機械の門（AI を呼ばない・札の literal が無い・パスの文字）

**Files:**
- Create: `tests/notify-relay/fixtures/no-ai.patterns.json`（共通の部品 `00_INFRA_TOOLS/conventions` の `no-ai.patterns.json` の写し。その dir の `SHA256SUMS` の行 `8c03079e6752b816149b467257dd527c34aa0022a235eaf6e385846937a3c53f` と同じであること）
- Test: `tests/notify-relay/test-notify-relay-hygiene.sh`（100755）

**Interfaces:**
- Consumes: P1〜P4 のパス（試験の中の一覧 1 か所）

- [ ] **Step 1: 試験を書く**:
  1. 写しの sha256 が上の 64 字と同じ（試験の中に 64 字を 1 か所）
  2. P1〜P4 の各ファイルに、写しの全ての `text` を ASCII の大小を無視した部分一致で当て（`boundary: word` は前後が `[A-Za-z0-9_]` でない時だけ当たる）、0 件。ファイルが 1 つでも無ければ FAIL
  3. 写しの各 pattern の `hit` が当たり `miss` が当たらない（照らしの道具そのものの確かめ）
  4. 壊して落とす（設計書 12 章）: P1 の一時の写しに `k=${ANTHROPIC_API_KEY:-}` の行を足すと 2 の照らしが 1 件を出す
  5. P1〜P4・`tests/notify-relay/` の中に `[A-Za-z0-9_-]{43}` の並び（前後が同じ字の集まりでない）が 0 件
  6. パスの文字: P1〜P4 に `grep -nE "['\"](/|\./|\.\./)[A-Za-z]"` を当て、当たった行が全て定数の定義の行（`^[A-Z_]+=`）
  7. 差分の門: `git diff --name-status main...HEAD` が取れる時（main が在る時）、全ての行が `A` で、パスが Global Constraints の「触ってよいファイル」の中。取れない時（CI の浅い取得など）は `SKIP` と書く（落とさない・通したとも書かない）
- [ ] **Step 2: 走らせて通る**（P1〜P4 が揃った後）。4 は試験の中で落ちて見せる
- [ ] **Step 3: Commit** `test(notify-relay): add no-AI, token-literal and path gates (P5)`

### Task 6: 手元の試し台（repo に入れない。設計書 13 章の 11）

scratchpad の lane の dir にだけ作る。`php -S 127.0.0.1:<空いている port>` の router（`RELAY_BENCH_MODE`: `unavailable` は 503・`slow` は 15 秒待って 204・`ok` は 204）と、`drop` は接続を受けて何も返さずに閉じる最小の受け口（php の `stream_socket_server` を `php` の CLI で）。本物の P1 を一時の秘密の置き場（url = `http://127.0.0.1:<port>/notify-relay/put`）と偽の notify.sh で 4 回打つ。

合格: `unavailable` → `fallback http_503`・偽の notify.sh 1 回／`slow` → `fallback curl_28`・10〜12 秒で終わる・偽の notify.sh 1 回／`drop` → `fallback curl_52` か `curl_56`・偽の notify.sh 1 回／`ok` → `put 204`・偽の notify.sh 0 回・受け口が受けた本文の鍵が 3 つで見出しに札が在る。立てた php の PID を記録し、終わったらその PID だけを止める。

### 確認（束の最後に 1 回・盲検）

新しい確認役（opus）に、設計書・この計画の Global Constraints と Review Focus・束の commit の範囲・確かめ方の一覧（Task 1〜5 の試験・変異の網・門）だけを渡す（担当の報告は渡さない）。判定は `MERGE` か `FIX FIRST` と型の一覧（指摘ごとに直ったかを確かめる命令と期待する結果、直し方の手がかり）。
