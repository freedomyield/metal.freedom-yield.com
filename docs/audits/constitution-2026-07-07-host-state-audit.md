# Constitution Audit — 2026-07-07T12:22 (JST) — Host-state 実機照合

## Summary

- **Overall**: 🟡 (項目 1–4 は MATCH、項目 5 に既知 1 件 + 新規 2 件の feed/log drift)
- **Range**: host 実機状態 vs local `origin/main` HEAD `da6fbc9` (2026-07-07T03:16–03:22 UTC 実測)
- **Scope**: host-state 照合 5 項目 (repo checkout / cron 実態 / orphan script / tripwire+watch / feed 鮮度)
- **Review preset**: N/A (実機照合専用、read-only)
- **Auditor**: constitution-auditor agent
- **接続**: `ssh -i ~/.ssh/<validator_host_key> root@<VALIDATOR_HOST>` (read-only command のみ実行。git 読み取りは dubious-ownership 回避のため `sudo -u deploy git -C ...` を使用 — `git config --global safe.directory` は書き込みのため実行していない)
- **PRIME DIRECTIVE**: broadcast-capable command は一切未実行 (実行したのは ssh 経由の `git log/status/diff`, `ls`, `cat`, `tail`, `grep`, `sha256sum`, `journalctl`, `crontab -l` と Mac 側 `curl` の読み取りのみ)

## 照合項目 1 — Host repo checkout

**Verdict**: ✅ MATCH

**Method**: `sudo -u deploy git -C /home/deploy/metal.freedom-yield.com log --oneline -1` / `status --porcelain` / `diff --unified=0` を host で実測、Mac 側 `git fetch` 後の `origin/main` と突合。

**Evidence**:
- Host HEAD: `da6fbc9 feat(watch): JST-daytime cron installer for the watch monitor`
- Local `origin/main`: `da6fbc9` — **一致**
- `status --porcelain`: **clean ではない**。中身の分類 (変更は一切していない):
  - ` M` 50 file — 全て `public/**` (html + hero-3d js)。diff 実測は `100 insertions(+), 100 deletions(-)` で、内容は全行 `?v=da6fbc95` cache-buster 刻印 (例: `public/index.html:13` `-href="/styles.css"` → `+href="/styles.css?v=da6fbc95"`)。既知の deploy 構造 drift (host-drift tripwire も `public/ excluded by design` と明記)
  - `??` 3 file — `public/api/anchor-history.jsonl` / `anchor-receipt.json` / `anchor-source.json` (runtime 生成 artifact、意図された untracked)
  - `??` 2 dir — `scripts/.retired-20260706-033840/` / `scripts/.retired-20260706-035124/` (repoint installer の quarantine dir、照合項目 3 参照)
- **code zone (scripts/docs/tests/deploy) の tracked drift: 0 件**

## 照合項目 2 — Cron 実態

**Verdict**: ✅ MATCH (minor note 1 件)

**Method**: `ls -la /etc/cron.d/` + 全 `metal-*` / `freedom-yield-*` file を `cat` で全文取得し、repo の installer heredoc (`install-metal-host-drift-cron.sh:50-60`, `install-watch-cron.sh:54-66`) と突合。`crontab -l -u deploy` / `-u root` も取得 (両方 "no crontab" — 全 schedule は /etc/cron.d/ 集約)。

**Evidence**:
- `/etc/cron.d/` の project cron は 15 file: `freedom-yield-peer-geo`, `metal-anchor-publish-health`, `metal-anchor-watch`, `metal-anomalies`, `metal-cycle-history`, `metal-daily-status`, `metal-evidence`, `metal-host-drift`, `metal-node-health`, `metal-node-info`, `metal-peer-validators`, `metal-renewal-ics`, `metal-server-status`, `metal-uptime-history`, `metal-watch-validators`
- **push-to-web-host repoint**: publish 系 9 cron (peer-geo / anchor-publish-health / cycle-history / evidence / node-health / node-info / peer-validators / renewal-ics / uptime-history) は全て `push-to-web-host.sh` を呼ぶ。`grep -rn "push-to-xserver" /etc/cron.d/` = **NONE** (実測)
- **SHELL/PATH env header**: 全 15 file に `SHELL=/bin/bash` + `PATH=/usr/local/bin:/usr/bin:/bin` あり (実測 cat で確認)
- **watch monitor JST 昼間 cron**: `/etc/cron.d/metal-watch-validators` の schedule 行 `0 0,4,8,12 * * * deploy cd /home/deploy/metal.freedom-yield.com && bash scripts/check-watch-validators.sh >> /var/log/check-watch.log 2>&1` — installer `install-watch-cron.sh` の heredoc と comment 含め全行一致 (REPO_DIR 展開済)
- **host-drift cron**: `/etc/cron.d/metal-host-drift` の `15 5 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-host-drift.sh 2>&1 | logger -t host-drift` — installer `install-metal-host-drift-cron.sh` の EXPECTED heredoc と comment 含め全行一致

**Minor note (指摘のみ)**: `/etc/cron.d/metal-watch-validators.bak-20260707-030021` (544 bytes、2026-07-07 03:00 の installer 実行時 backup) が cron.d 内に残存。cron.d は dot 含み file 名を無視するため機能上無害だが、`install-repoint-publish-crons.sh:42-44` 自身が「.bak file left in /etc/cron.d is clutter」として backup を cron.d 外に置く方針を採っており、`install-watch-cron.sh:83` の `cp -p "$CRON_FILE" "${CRON_FILE}.bak-${STAMP}"` はこの方針と不整合。

## 照合項目 3 — 旧 orphan script の残存

**Verdict**: ✅ MATCH (quarantine 済、cron 参照 0)

**Method**: host `scripts/` を `ls -la | grep -iE "xserver|retired|\.bak"` + `.retired-*` dir の中身 `ls`、`/etc/cron.d/` 全文 grep。

**Evidence**:
- `scripts/.retired-20260706-033840/`: `push-to-xserver.sh.bak-20260701-103515`, `push-to-xserver.sh.bak-sig-20260701-110835`, 旧 provider 名入り sync script 1 本 (file 名は provider literal を含むため redact、2615 bytes / 2026-05-20 版)
- `scripts/.retired-20260706-035124/`: `push-to-xserver.sh` (4272 bytes, 2026-07-01 11:08 版)
- 旧名 `push-to-xserver.sh` は scripts/ 直下に**存在しない** (grep hit は repo tracked の `install-xserver-*` 3 file のみで、これは正当)
- cron からの参照: **0 件** (`grep -rn "push-to-xserver" /etc/cron.d/` = NONE)

## 照合項目 4 — Host-drift tripwire + watch monitor の配置と cron 登録

**Verdict**: ✅ MATCH (tripwire の初回実行のみ未来時刻のため実行実績は未観測 = 構造上正常)

**Method**: host と local repo で `sha256sum` / `shasum -a 256` を実測比較、cron 登録は項目 2 の cat、実行実績は `journalctl -t host-drift` と `/var/log/check-watch.log` tail。

**Evidence**:
- sha256 完全一致 (host == local repo @ da6fbc9):
  - `check-host-drift.sh` = `7e2cb962394fd1ef0f173a7bfc014e43a36907010b4f3075dd68b2824514ae5a`
  - `check-watch-validators.sh` = `276a04e3336e50437cca4cb61415f3d231d42c5f46b7994daed21853cd6dc67d`
  - `push-to-web-host.sh` = `5fd4d51f47691b4f1b00bebcf6e7242f25ef18a594efa2f61c960de2a3054fe4`
- cron 登録: 両方あり (項目 2 で全文一致確認)
- **watch monitor 実行実績**: `/var/log/check-watch.log` mtime `2026-07-07 00:00:03` (直近 tick 00:00 UTC = 09:00 JST)、tail に `ntfy POST: 200` + `no changes on 4 watched validators` — 稼働中
- **host-drift 実行実績**: `journalctl -t host-drift` = "No entries"。cron file の install が 2026-07-06 09:11 UTC (当日の 05:15 UTC 発火後) のため、初回発火は 2026-07-07 05:15 UTC (監査時点 03:17 UTC ではまだ未来)。**未実行は時系列上正常**。初回発火後の実行実績は本監査では UNVERIFIED

## 照合項目 5 — Publish 経路の生死 (feed 鮮度)

**Verdict**: ⚠ PARTIAL — 主要 feed は生きているが、drift 3 件 (既知 1 + 新規 2)

**Method**: host の artifact/state/log の mtime を `ls --time-style=full-iso` で実測、`/var/log/syslog` の CRON 行 grep、Mac から公開 URL を `curl` して timestamp 突合。

**Evidence — 生きている経路**:
- `validator.json`: host mtime `2026-07-07 03:15:01`、公開 URL の `observedAt` = `2026-07-07T03:20:01Z` vs 実測現在時刻 `03:20:31Z` — **end-to-end 30 秒差で fresh** (5 分 cron 稼働)
- `uptime-history.jsonl` `2026-07-07 00:30:01` / `node-health-recent.json` `2026-07-07 00:35:01` / `cycle-history.jsonl` `2026-07-06 04:30:01` / `anchor-watcher-state.json` `2026-07-07 03:15:01` / `server-status.json` `2026-07-07 03:19:02` (毎分更新) — 全て schedule 通り
- `check-anchor-publish-health.sh`: syslog に `2026-07-07T03:15:01 CRON ... check-anchor-publish-health.sh` — 15 分毎に発火中

**Evidence — drift**:

1. **[既知・修正証明待ち] fee-market / gini 系 stale**: `public/api/fee-market.json` = `2026-06-18 04:00:02`、`fee-market-history.jsonl` / `gini-history.jsonl` / `peers-prev-nodeids.txt` も同日。公開 URL `fee-market.json` の `generated_at` = `2026-06-18T04:00:02Z`。一方 `peers.json` は `2026-07-06 04:00:02` (cron 自体は走っている)。fix `22f8656` の効果証明は 2026-07-07 04:00 UTC 発火後の ts で確定する設計 (監査時点 03:20 UTC のため **PENDING/UNVERIFIED**)
2. **[新規 🔴 相当] `${REPO}/logs/` dir が host に不在**: `ls /home/deploy/metal.freedom-yield.com/logs/` = "No such file or directory"。`metal-evidence` (01:30) と `metal-cycle-history` (04:30) の cron 行は `>> /home/deploy/metal.freedom-yield.com/logs/*.log 2>&1` へ redirect しており、redirect 先 dir 不在だと bash は command 本体を実行せず失敗する。`cycle-history.jsonl` は `2026-07-06 04:30` に成功している (= その時点で logs/ は存在) ため、dir 消失は 2026-07-06 04:30 以降 (07-06 の reconcile 作業帯と重なる)。**このままだと本日 04:30 の cycle-history 更新も失敗する**
3. **[新規] `evidence.json` stale**: host mtime = 公開 URL `generated_at` = `2026-07-03T01:30:01Z` — 4 日更新なし。本日 01:30 の失敗は上記 logs/ 不在で説明が付くが、07-04/07-05/07-06 分の失敗原因は log file が dir ごと消えており **UNVERIFIED** (当時 logs/ は存在していたはずのため別因の可能性)
4. **[minor] anchor-publish-health の durable log 不在**: cron header comment は「/var/log/anchor-publish-health.log に append」と主張するが file 不在。`check-anchor-publish-health.sh:49` の `log()` は `/var/log` が deploy-writable でない場合 silent skip する実装のため、monitor は稼働しているが恒久 log は残っていない (comment と実態の乖離)
5. **[判定変更なしの補足] `server-status.log` / `peer-validators.log` の mtime が古い件**: server-status は成功時無出力の script で artifact (`server-status.json`) は毎分更新されており正常。peer-validators は上記 1 と同根

## Statistics

- 照合項目: 5
- MATCH: 4 (項目 1, 2, 3, 4)
- PARTIAL DRIFT: 1 (項目 5 — 新規 drift 2 件 + 既知 pending 1 件 + minor 2 件)
- UNVERIFIED として分離: 3 点 (host-drift 初回発火実績 / fee-market fix 証明 = 本日 04:00 UTC 以降 / evidence 07-04〜06 失敗の原因)

## Suggested fixes (指摘のみ、auditor は実装しない)

1. `mkdir -p /home/deploy/metal.freedom-yield.com/logs` + `chown deploy:deploy` を installer 化 (または cron redirect を `/var/lib/freedom-yield/` 等の恒久 dir へ移す)。本日 04:30 UTC 前に対処しないと cycle-history も欠落する
2. `evidence.json` の 07-04 以降の失敗原因調査 (logs/ 復旧後の初回実行 log で判明する見込み)
3. `install-watch-cron.sh` の backup 先を repoint installer と同様 cron.d 外へ
4. `check-anchor-publish-health.sh` の log 先を deploy-writable な path へ (cron comment と実装の整合)

## Auditor note

- Fabrication: 0 件 (全 finding は ssh/curl/git/sha256sum の実測出力に基づく)
- 越権実装: 0 件 (host への書き込み・変更・restart・cron 編集は一切行っていない。`git config` の safe.directory 追加も回避)
- Broadcast-capable command: 0 件
- Host の実 IP / SSH key 名 / provider 名: 本 report では placeholder (`<VALIDATOR_HOST>` / `<validator_host_key>`) または redact 表記のみ使用
- Numeric claim: 全て実測 capture (「~」「約」不使用)
- Append-only: この report は新規 file、既存 audit doc は未 touch

> **operator へ**: この report の各 finding は `superpowers:receiving-code-review` の手続きに従い独立に verify してください。特に finding 5-2 (logs/ dir 不在) は本日 04:30 UTC の cycle-history 発火に影響するため、時刻依存の確認を推奨します。
