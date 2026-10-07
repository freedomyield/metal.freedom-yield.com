# Cycle gate — passive defer / active resume for cycle transitions

> **Status (= 2026-07-06)**: v2 rewrite. This document describes the **live**
> model: the single 3-branch `anchor-source.json` DAG (`dag_root_computed`,
> memo prefix `fya<S>c<N>`), the alert-only watcher driver, and the
> `resume-after-cycle-start.sh` that **no longer broadcasts**. The v1 model
> this replaces (2-branch `cycles-history.json` / `dag_root_hash` /
> `fyid1:` memo / `post-anchor-event.sh` auto-broadcast) was retired across
> 2026-07-04 .. 2026-07-06 (design-stocktake #1/#3/#4; see
> `docs/audits/constitution-2026-07-04-design-stocktake.md`). For the v1
> design as originally deployed on 2026-06-29, see this file's git history.

## What problem this solves

A validator cycle transition (one AddValidator entry expiring, the next one
committing) is a window in which cycle-dependent automation can act on stale
state. The gate design removes two failure modes:

- **Cycle-aware alerts firing mid-transition.** The 5-minute anomaly tick
  observes the validator disappearing at cycle end — expected, not an
  incident. Alert automation must know whether the operator has acknowledged
  the new cycle.
- **Any future cycle-gated side effect running before the operator's
  approval state catches up.** The gate makes "safe to fire" a property of
  explicit approval state, not of cron-enable/disable scheduling that a
  human can forget.

What this design **no longer** does: gate or trigger the anchor broadcast.
In the v2 model the anchor inscription is produced by a separate,
operator-driven signing pipeline (below) whose safety rests on the PRIME
DIRECTIVE 4-gate discipline and `bin/safe-broadcast` — not on cron state.
There is deliberately **no** automated path from "cycle transition
observed" to "broadcast".

## Architecture

Two components, separated by direction:

```
[ passive auto-defer ]                    [ active operator resume ]
  scripts/cycle-gate.sh                     scripts/resume-after-cycle-start.sh
  (= consulted by cron scripts)             (= invoked once per cycle)
        │                                          │
        │ reads                                    │ writes
        ▼                                          ▼
   ${FY_STATE_DIR}/cycle-gate-state.json
   {
     "schemaVersion": 1,
     "approved_cycle_signature": "<NodeID>-<startTime_epoch>",
     "approved_dag_root_hash":   "<64-hex>",
     "approved_at":              "<ISO 8601 UTC>"
   }
```

`cycle-gate.sh` is **passive**: it answers a yes/no question for the caller —
"is the cycle currently visible on chain the one the operator approved?".

`resume-after-cycle-start.sh` is **active**: run once per cycle after the new
AddValidator entry is Committed. It verifies the new cycle on chain and the
published artifacts, then atomically updates the state file. It performs
**no broadcast**.

The 5-minute crons keep firing with no operator enable/disable action.
Between cycle close and operator approval, gated side effects are silently
deferred; after approval they resume on the next tick.

## Separation from the anchor pipeline

The anchor inscription is out of scope for the gate. `scripts/run-anchor-pipeline.sh`
exists as a single-host orchestrator for its four steps, but it **cannot run
end-to-end as one invocation** under the live topology: signing is Mac-only
(the anchor key never leaves the operator's Mac; `sign-anchor-event.sh`
refuses with exit 7 on any host that fails its signing-host assertion), while
composing and receipt-verification run on the validator host. In practice the
steps are run **manually, split across host and Mac**, with a git
commit/push/deploy hop in between so the Mac's local checkout sees the
host-composed `anchor-source.json`:

```
1. gen-anchor-source.sh          compose anchor-source.json           (validator host)
2. commit-anchor-source.sh       verify + COMMIT anchor-source.json.   (operator Mac —
   (scripts/operator-local/)     Push + deploy are a separate,          scripts/operator-local/,
                                 subsequent action (--push, or            never runs on the host)
                                 `git push origin main` by hand).
3. sign-anchor-event.sh          compose + sign + broadcast the        (operator Mac ONLY —
                                  4-action pack via bin/safe-broadcast   signing-host assertion, exit 7)
4. gen-anchor-receipt.sh         fetch tx + 7-gate verify + receipt    (validator host)
5. append-anchor-history.sh      append to anchor-history.jsonl        (validator host)
```

- The inscribed value is `anchor-source.json .dag_root_computed` (3-branch:
  `identity_branch` / `observations_branch` / `artifacts_branch`), carried in
  four `eosio.token::transfer` memos: `fya<S>c<N>-id:`, `-ob:`, `-ar:`, and
  the pivot `fya<S>c<N>:<dag_root_computed>`.
- Broadcast safety = PRIME DIRECTIVE 4 gates enforced by `bin/safe-broadcast`
  + per-invocation operator authorization. Never cron-triggered.
- Step 2's commit + push + deploy is **not optional**: `anchor-source.json`
  is published to the public site by the normal git-deploy path (not rsync),
  so until that deploy lands, `resume-after-cycle-start.sh`'s Phase 1 polling
  (below) never observes a fresh `dag_root_computed` and eventually times out
  with exit 3.
- The event watcher (`watch-anchor-events.sh`, 5-minute cron) dispatches
  transitions to `scripts/notify-anchor-transition.sh` — an **alert-only**
  driver that fires an ntfy push and **broadcasts nothing**. It exists so the
  operator learns "cycle transition observed; run the pipeline when ready".

## State file schema

`${FY_STATE_DIR}/cycle-gate-state.json` (default `${FY_STATE_DIR}` =
`/var/lib/freedom-yield`).

| field | type | meaning |
| --- | --- | --- |
| `schemaVersion` | integer | currently `1`. Bump on incompatible format change. |
| `approved_cycle_signature` | string | `<NodeID>-<startTime_epoch>`. Uniquely identifies the validator entry on chain that this approval covers. Two distinct AddValidator transactions produce two distinct startTime values, so the signature changes per cycle. |
| `approved_dag_root_hash` | 64-hex string | The `anchor-source.json .dag_root_computed` observed at approval time. (Field name retained from schemaVersion 1 for compatibility; since the v2 migration the stored value is the 3-branch `dag_root_computed`.) |
| `approved_at` | ISO 8601 UTC string | Wall-clock time the approval was written. Diagnostic only; not consumed by gate logic. |

File mode is `0644`. The file contains no SECRET-class data — both values are
public on chain.

When the file is absent (= first deploy, or after manual `rm` for rollback)
`cycle-gate.sh` returns green for every side-effect type — the backward-compat
behavior that preserves the pre-gate cron flow.

## `cycle-gate.sh`

Consulted by cron scripts immediately before a cycle-dependent side effect.

```sh
scripts/cycle-gate.sh --side-effect=<type>
```

| `--side-effect` value | semantics | live consumers |
| --- | --- | --- |
| `cycle-artifact-write` | Write to a cycle-recording artifact. **Always green** — recording a *closed* cycle is backward-looking and can never be premature. Gating it caused the 2026-07-04 transition deadlock (design-stocktake trouble #2); ungated since. Kept as a declared type for the distinct log marker. | `gen-cycle-history.sh`, `uptime-history.sh` (Job B), `node-info.sh`, `gen-evidence.sh`, `gen-renewal-ics.sh` |
| `cycle-aware-notify` | Validator-presence-based notification (ntfy). Signature-gated: deferred while the on-chain cycle differs from the approved one, so transition-window noise is suppressed until the operator acknowledges the new cycle. | `check-anomalies.sh`, `daily-status.sh` |
| `broadcast` | A-chain inscription (IRREV). Signature-gated. **No current consumer** — the v1 consumer (`post-anchor-event.sh`) was retired; the v2 pipeline does not consult the gate (its safety layer is `bin/safe-broadcast`). The type is retained defensively: any future automation declaring `--side-effect=broadcast` inherits fail-closed gating. | (none) |
| `observe` | Read-only observation. Always green; lets call-sites declare intent uniformly. | (declared only) |

Exit codes:

| code | meaning |
| --- | --- |
| `0` | green — side effect safe to execute |
| `1` | deferred — transition window or unapproved cycle; skip the side effect |
| `2` | usage error |

Behavior matrix (= invariants):

| state | broadcast / cycle-aware-notify | cycle-artifact-write / observe |
| --- | --- | --- |
| state file absent | green (backward compat) | green |
| state matches chain signature | green | green |
| state mismatch chain signature | deferred | green |
| state file corrupt | fail-closed (deferred) | green |
| metalgo RPC unreachable | fail-closed (deferred) | green |
| validator absent from chain | deferred | green |

The RPC timeout default is `${FY_RPC_TIMEOUT:-6}` seconds. Setting it via env
at call time lets test harnesses fail fast without depending on the system
default.

## `resume-after-cycle-start.sh`

Single command run once per cycle, after AddValidator is Committed and the
freshly published artifacts are live.

```sh
scripts/resume-after-cycle-start.sh --dry-run            # verify only
FY_LIVE=1 scripts/resume-after-cycle-start.sh --apply    # full sequence
```

**`--apply` requires `FY_LIVE=1`** (C3 rollout, 2026-08-06). Without it the
script REFUSES with exit 6 before Phase 1 — it does not read, poll or write
anything — and prints the corrected command. It refuses rather than degrading
to a silent no-op because a suppressed write here would report
`✓ ALL PHASES PASS` while leaving the gate unapproved, and every
cycle-dependent side effect would then defer with nobody having a reason to
look. `--dry-run` needs no opt-in: it reads and reports and writes nothing.

Phases:

1. **Phase 1 — verify.** Query metalgo RPC for the current validator entry,
   derive the cycle signature, idempotency-check against the prior approved
   signature, poll `${PUBLIC_BASE}/api/anchor-source.json` until its
   `dag_root_computed` differs from the prior approved value (max
   `${FY_POLL_MAX_SEC:-600}` seconds at `${FY_POLL_INTERVAL:-30}` second
   intervals), and verify the published `identity.json` signature via
   `ssh-keygen -Y verify`. Phase 1 has no side effects.
2. **Phase 2 — atomic state write.** Compose the new `cycle-gate-state.json`
   via `jq -n` to a `.new` tempfile, then `mv` over the live file. Atomic on
   POSIX (same dir).
3. **Phase 3 — report.** Print a one-block summary of the final state. Exit 0.

The v1 Phase 3 (broadcast trigger) and Phase 4 (`fyid1:` receipt field-match)
were removed in the v2 migration: the anchor pipeline broadcasts under its own
4-gate discipline, and `gen-anchor-receipt.sh` already verifies the four v2
memos + `dag_root_computed` at receipt time, so a second post-hoc check here
was redundant.

Exit codes:

| code | meaning |
| --- | --- |
| `0` | PASS — state updated; OR `--dry-run` Phase 1 verification succeeded; OR idempotent skip |
| `1` | usage error |
| `2` | Phase 1 verification failed |
| `3` | Phase 1 polling timeout (= anchor-source.json never went fresh) |
| `4` | Phase 2 state write failed |

`--dry-run` runs only Phase 1; Phase 2 emits a "would write" log line instead.

## Operator runbook (= cycle transitions, model α)

### 当日に渡す実値 (day-of value sheet)

各 step の本文は `<N>` / `<N+1>` の記法を保つが、**その意味は step 5 と step 6
の間で意図的に反転する** (step 6 の "Deliberate meaning switch from step 5")。
当日は暗算せず、この表を引く。誤った側を渡した場合の戻り値が step ごとに
別番号 (exit 7 / exit 9 / exit 5) なので、暗算違いは症状からは読み取れない。

この表は日付に依存しない。値は「その日に**閉じる** cycle = `<N>`」と
「その日に**刻む** cycle = `<N+1>`」の 2 つだけで決まる:

| step | 変数 / フラグ | 意味 | 渡す値 |
|---|---|---|---|
| — | `<N>` | その日 **閉じる** cycle | `N` |
| — | `<N+1>` | その日 **刻む** cycle | `N+1` |
| 4 | `FY_EXPECT_CYCLE=` | 閉じた cycle (= 公開台帳の `CLOSED_COUNT`) | `N` |
| 5 | `FY_EXPECT_CYCLE=` | 同上 | `N` |
| 6 | `commit-anchor-source.sh --expect-cycle=` | 刻む cycle | `N+1` |
| 7a | `run-testnet-rehearsal.sh --expect-cycle=` | 刻む cycle | `N+1` |
| (runbook 外) | `cycle-transition.sh --expect-cycle=` | 閉じる cycle | `N` |
| (runbook 外) | `install-rehearsal-preflight.sh --expect-cycle=` | 刻む cycle | `N+1` |

**当日の埋め方** (朝、step 0 より前に 1 回だけ。どれも read-only):

- `N` = **今日 `endTime` を迎える cycle の番号** = その朝の committed / 公開
  `public/api/anchor-source.json` の `observations_branch.cycle_number_observed`
  (= 現に刻まれている cycle)。
- 照合: 公開 `cycle-history.jsonl` の行数 (`CLOSED_COUNT`) は朝の時点で
  **`N-1`**、step 3 が走った後に **`N`** になる (`gen-anchor-source.sh` が
  `cycle_number_observed` を `CLOSED_COUNT + 1` として compose するため)。
  2 つが合わなければ表を埋めずに止まる。
- 埋めた値で `bash scripts/cycle-transition.sh --print-only --expect-cycle=<N>
  --ledger=<path>` を実行し、**その日の解決済みコマンドはこの出力を正とする**
  (この表は値の意味の説明、per-day の実コマンドの出所は `--print-only`)。
- 意味の権威は 2 系統: `scripts/cycle-transition.sh` の `--expect-cycle`
  ("The cycle that CLOSES today") と `scripts/install-rehearsal-preflight.sh` の
  header ("THIS SCRIPT TAKES THE REHEARSAL'S MEANING (M)" = 刻む cycle =
  `cycle-transition.sh` の値より 1 大きい)。
- `docs/pending-disclosures/` に公開待ちの開示 incident がある cycle では
  **step 2.5 が該当する** (step 2 の末尾、**step 3 より前**)。飛ばすと閉じる
  cycle の incident 件数が 1 件過少のまま append-only 台帳に確定し、後から
  直せない。
- **当日より前の稽古で渡す rehearsal フラグはこの表の値ではない** — 稽古の時点
  ではまだ cycle `N` が刻まれた最新なので、稽古のフラグは `N` で、当日の 7a
  (`N+1`) と 1 ずれる (前例: 2026-09-01 の稽古は 4、9/4 当日は 5 —
  `docs/REHEARSAL_2026-09-01.md` §3)。

**記入例 — 2026-10-07 (cycle 5 が閉じ、cycle 6 を刻んだ日):** 朝の
`cycle_number_observed` = 5、公開 `cycle-history.jsonl` = 4 行 → `N=5`。
step 4 / 5 の `FY_EXPECT_CYCLE=5`、step 6 と 7a の `--expect-cycle=6`、
`cycle-transition.sh --expect-cycle=5`、`install-rehearsal-preflight.sh
--expect-cycle=6`。step 3 の後に `cycle-history.jsonl` は 5 行。

### cycle 間のメンテナンス枠 (maintenance window between cycles)

**いつ**: cycle `<N>` の `endTime` を過ぎてから、step 0 の AddValidator を
submit するまでの間だけ。この間 validator は validator set に居ないので、
**停止しても uptime の評価対象にならない** (uptime は cycle の中でしか測られ
ない)。host の再起動・metalgo コンテナの作り直しはこの枠でだけ行い、cycle
中には行わない。終わったら step 0 へ進む (枠の確認項目がすべて揃う前に
AddValidator を出さない — 登録した瞬間から uptime が測られる)。

**誰が**: host 上の手順は **AI@host が実行する**。ただし着手前に operator の
**一言の承認** (例:「進めて」) を chat で取る (Operating Model W7 の承認は
operator に残る)。operator のキー操作はこの枠には無い。

**何を** (この順で。どの手順も、期待と違う出力が出たらそこで止まって報告):

- **着手前の確認 (read-only)** — 公開 `validator.json` で cycle `<N>` が
  current set から外れていること (`endTime` が過ぎている)、staker keys の
  暗号化 backup が揃っていること (`docs/DISASTER_RECOVERY.md`)、
  `bash scripts/check-compose-naming.sh` が **10 行すべて MATCH**・
  `RESULT: MATCH`・exit 0 (project / container / data / isolation / adopt /
  image / command / memory / nanocpus / restart) であること、現在の NodeID を
  `info.getNodeID` で控える。
- **OS の更新と再起動** — apt の更新 (docker / docker compose plugin を含む)
  → OS 再起動。再起動後、metalgo コンテナは restart policy で上がる。
  外部見張り (`docs/MONITORING_OPS.md`) の p2p alert は再起動中の想定内で、
  復帰後の recovery 通知で戻りを確認する。
- **metalgo の作り直し** — 必ず **3 ファイル** (`docker-compose.metalgo.yml` /
  `docker-compose.metalgo.prod.yml` / `docker-compose.metalgo.adopt.yml`) を
  `-f` で渡す。adopt override が `/data` volume を external にするので、
  compose は volume を作り直さず、`down -v` でも消さない。
  1. 先に `--dry-run up -d metalgo </dev/null`。期待は `Container …`
     の `Recreate / Recreated / Starting / Started` 4 行だけ。`Volume` の行、
     `Recreate (data will be lost)?`、`external volume … not found` が出たら
     止まる。
  2. 同じコマンドから `--dry-run` を外して実行する。**stdin は常に
     `</dev/null`、`-y` / `--yes` は絶対に付けない** (確認プロンプトに自動で
     yes を返す経路を作らない)。
- **事後確認** — `info.getNodeID` が控えた値と**一致** (不一致・空なら label で
  特定したコンテナを即 `docker stop` して報告)、`info.isBootstrapped` が
  **P / X / C すべて true**、peers 数が戻る、`check-compose-naming.sh` が
  再び **10/10 MATCH**・exit 0、外部見張りの p2p が PASS に戻る。

> **compose の版を上げた後の dry-run が `Recreate` を出すのは想定どおり。**
> docker compose は container の設定から `com.docker.compose.config-hash` を
> 計算しており、compose 本体の版が変わるとこの hash が変わる。そのため apt で
> compose plugin を更新した後は、設定を何も変えていなくても次の dry-run が
> `Container … Recreate` を出す。adopt override で `/data` が external に
> なっているので、この Recreate は**コンテナだけ**の作り直しで、volume
> (= staker keys) には触れない — 安全。止まるべきなのは上の 1. に挙げた
> `Volume` 行 / `data will be lost` / `external volume … not found` だけ。

### 当日の運用メモ (2026-10-07 の転換から)

- **testnet の tx は Hyperion の索引に出るまで数分かかることがある。** 7a の
  直後に 7b (`preview-cycle-anchor-broadcast.sh`) の gate-1 事前確認が
  testnet tx の `block_num` を MISS と出すことがある (2026-10-07 実測)。
  これは索引の遅れであって tx が無いのではない (7a は
  `TESTNET REHEARSAL COMPLETE testnet_tx_id=…` を出している)。**待って 7b を
  再実行する。7a をやり直して testnet に再 broadcast しない。** step 8 の
  gate 1 の一時的な失敗 (mainnet 側) と同じ形。
- **operator の手作業は、3 本の鍵の unlock とその lock だけ。** 呼び方は
  「unlock / lock」に揃える:
  ① identity 鍵 — unlock = `ssh-add` (step 4 の前操作)、
  ② testnet keystore — unlock / lock (7a)、
  ③ mainnet keystore — unlock / lock (7c)。
  password / passphrase はすべて operator が自分の TTY で打ち、AI には渡さない。
  これとは別に、現行の canon は 7a 本体の起動も operator@TTY としている
  (下の「実行者と実行場所」節)。
- **各鍵は最後に使った直後に lock する。** 開けたまま次の unit へ持ち越さない:
  - identity 鍵 → **unit 4 の直後**。最後の利用者は `gen-identity.sh` なので、
    それが exit 0 で終わったら **AI が `ssh-add -d` で agent から外す**
    (passphrase を伴わないので AI@Mac)。
  - testnet keystore → **7a の直後**。7b / 7c / 8 は testnet keystore を
    使わない (7b・7c は mainnet の HOME、gate 1 の testnet tx 確認は履歴の
    読み取り)。
  - mainnet keystore → **7c の直後**。
- **lock のプロンプトで空 Enter を押さない。** プロンプトは
  `Enter 32 character password (leave empty to create new)` で、空 Enter は
  既存 password での lock ではなく**新しい password の作成**になり、次回の
  unlock が通らなくなる。lock には必ずその keystore の unlock と同じ
  32 文字を入れる。

### 実行者と実行場所 (actor / location)

各 step の見出しにある「Mac」「host」は**マシン**の指定であって実行者では
ない。当日は次の 3 値で読む (憲法「operator 手動 = keystore の unlock / lock
のみ」と整合させるため):

| ラベル | 誰が打つか | どこで |
|---|---|---|
| **operator@TTY** | operator 自身が自分の terminal に打つ (password / passphrase を伴うため) | Mac |
| **AI@Mac** | AI が実行する。operator は出力を読むだけ | Mac の repo working copy |
| **AI@host** | AI が SSH 経由で実行する。operator は出力を読むだけ | validator host |

**operator@TTY はこの runbook 全体で 6 箇所**: ① step 4 前の `ssh-add`、
② 7a の testnet keystore unlock、③ **7a の `run-testnet-rehearsal.sh` 本体**、
④ 7c の mainnet keystore unlock、⑤ 7c 末尾の mainnet keystore re-lock、
⑥ **testnet keystore の re-lock** (② で開けたものを閉じる。**7a の直後** —
testnet keystore の最後の利用が 7a なので。遅くとも 7c 末尾)。
**残りの code block はすべて AI が実行する。**

> ⑥ は 2026-08-18 の三面突合 (K-7) で足した。それ以前この列挙は 5 箇所と
> 書いており、**testnet の re-lock だけが落ちていた** — 7c 末尾の散文
> (mainnet re-lock bullet の末尾に「7a の testnet keystore も同様に」と
> 1 節だけ埋まっていた) と完了 checklist ⑤ (`:1144-1145`) は最初から
> 要求していたのに、operator が当日数える一覧にだけ無かった。
> **canon 自身が「いちばん起きやすい取りこぼし」と呼んでいる操作を、canon の
> 操作一覧が落としていた**という形なので、数を書き換えるだけでなく 7c 末尾を
> 独立 bullet に分けた。

> 7a の rehearsal 本体が operator@TTY なのは password を伴うからではない。
> この script は `/tmp/fyd-broadcast-token` を**自分で**作り
> (`scripts/run-testnet-rehearsal.sh:413-428`)、`bin/safe-broadcast` を
> `--non-interactive` で呼ぶ (`:439-442`) ので、確認プロンプトが出ない。「**operator 自身がこの script を起動したこと**」が testnet
> broadcast の per-invocation 認可の実体であり
> (`docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`「What an AI session can verify, and
> what only the operator can」)、AI が起動した run は全 gate を通っても
> 認可にならない。

broadcast (mainnet) の per-invocation 認可は code block ではなく chat での
応答 — step 7c の「per-invocation 認可の手順」節。

**実行ディレクトリと実行ユーザ** (各 code block には `cd` を書かない — 既定は
ここで一度だけ宣言する):

- **operator@TTY / AI@Mac** — Mac の repo working copy の root。本文中の
  `bash scripts/…` という相対パスはすべてここが起点。別の場所で打つと
  `bash: scripts/…: No such file or directory` になる (どの step の exit 表にも
  無い症状なので、迷ったらまず現在地を疑う)。
- **AI@host** — repo は `/home/deploy/metal.freedom-yield.com`、**実行ユーザは
  `deploy`**。SSH は `root` で入るので、host 側の code block は実際には
  `sudo -u deploy bash -c 'cd /home/deploy/metal.freedom-yield.com && <block の中身>'`
  の形になる (この repo の host 実行の慣行 — `docs/CRON_CONVENTIONS.md:19-20`、
  `docs/HOST_CHECKOUT_AUTO_ADVANCE.md:316`)。**素の `bash` (= root) で走らせない**
  — 生成物の所有者が `deploy` から変わり、以降の cron 書き込みが落ちる。
  下の Emergency fallback 節が絶対パス + `sudo -u deploy env …` の形で書いて
  いるのは同じことを指しており、2 つの流儀があるわけではない。

Under model α (= AI full orchestration; see
`feedback_ai_full_orchestration_default` memo), the operator's active steps
are: ask AI to start, do the Metal Wallet web flow, supply two keystore
passwords + the identity-key passphrase when prompted, launch the testnet
rehearsal in 7a (its per-invocation authorization IS the operator having
started it — see the actor section above), and authorize the mainnet anchor
broadcast per invocation. Everything else — including which
machine each command runs on — is AI-orchestrated across a **2-host
topology (validator host + operator Mac)**, in this fixed day-of order
(cf. the cycle-3 → cycle-4 transition, `N=3`):

0. **operator (Metal Wallet web) — submit the new AddValidator, then
   confirm it landed.** The one human-driven state change of the day, and
   the precondition for everything below: fill in the Add Validator form
   (fields + timing: `docs/VALIDATOR_RENEWAL.md` Step 2), submit, watch
   the tx reach **Committed** on the explorer, and confirm the new entry
   is actually visible in `platform.getCurrentValidators` (e.g.
   `node-info.sh` on the host). The block is **mechanical, not a
   convention**: until the entry is on chain, step 5's
   `gen-anchor-source.sh` exits **4** (`NodeID … not present in current
   validators`) and step 9's `resume-after-cycle-start.sh` exits **2**
   (`NodeID=… not in current validators (= AddValidator tx not yet
   observed?)`). Do not start the pipeline on the submit alone — wait for
   Committed *and* the chain read.

   **How the AI checks chain state here without tripping the guard:**
   `scripts/broadcast-guard.sh` (tier-1) blocks any `curl`/`wget` shaped
   like a P-chain RPC hit (`/ext/bc/[XPC]`, the bare `/ext/[XP]` alias)
   **unconditionally, by command shape alone** — it does not distinguish
   a read-only `platform.getCurrentValidators` query from a broadcast, so
   an ad hoc `curl … /ext/bc/P` from the AI session is refused same as a
   real broadcast attempt would be. The adopted workaround is to read the
   already-running cron's output instead of querying the chain directly:
   `public/api/validator.json` is regenerated every 5 minutes by the
   `metal-node-info` cron (`node-info.sh`) — the same source "confirm the
   new entry is visible" above already points at. Fetch it (the public
   URL, or the host copy) and check its `endTime` / `observedAt` fields
   against the file's own mtime (≤5 minutes old = fresh, matching the
   cron cadence) rather than shelling out to the RPC. **Do not disable
   `broadcast-guard.sh` to work around this** — the guard is
   unconditional by design; reading the cron artifact is the correct way
   to observe chain state from an AI session, not a guard bypass.
1. **AI/host — wait for the node-info tick.** Poll (or wait for the next
   cron tick of) `node-info.sh` until `public/api/validator.json` reflects
   the new AddValidator entry's `endTime`. This confirms the new cycle is
   actually on chain before any cycle-recording script below runs against
   it — recording against a stale `endTime` would misdate the cycle
   boundary.
2. **host — `uptime-history.sh`**
   ```sh
   FY_LIVE=1 bash scripts/uptime-history.sh
   ```
   **要点 (根拠と例外は以下の長い節に書いてある — 当日はまずこの 4 行)**:
   ① **`FY_LIVE=1` は必須**。② 付け忘れても **exit 0 で静かに通る** ので、
   成功は「`DRY:` が無いこと」ではなく**肯定的な signal** で確認する —
   `Closed cycle #<N>: …` がこの step の存在理由そのものを名指しする最強の行。
   ③ 付け忘れの被害は step 3 の行が「間違う」ことではなく「**出ない**」こと
   (探すのは誤った行ではなく**欠けた行**)。④ **2026-09-04 は同じ日付で
   `Appended daily entry` が 2 回出るのが正常** — 重複実行ではない。
   ⑤ **この step の末尾に 2.5 (開示 incident の公開) がある。step 3 へ進む前に
   必ず読む** — 2026-09-04 は該当する。

   closes out cycle N's uptime record: the append-only master ledger entry,
   the in-flight `current-cycle-state.json`, the cycle-close summary row
   appended to `uptime-cycles.json`, and the refreshed public
   `uptime-recent.json` preview — **four artefacts**, not three (the script's
   own header, `scripts/uptime-history.sh:40-45`, is explicit: "before ANY of
   the four artefacts above is written"). **`FY_LIVE=1` is required for all
   four writes** (C3 rollout, 2026-08-06) — but unlike step 9's
   `resume-after-cycle-start.sh`, this script does **not refuse** without
   it. Omitting the env var is a **loud dry no-op that still exits 0**:
   every write becomes a `DRY: would …` line on stderr and the target file
   is left byte-for-byte untouched (measured 2026-08-17 against a fixture
   `validator.json`: no `FY_LIVE` → exit 0, zero files written, only `DRY:`
   lines on stderr).

   **To confirm a real (not dry) run, look for a positive signal — don't
   rely on the absence of `DRY:` alone.** `fyd_is_live`-guarded stdout lines
   that only a live run prints: `Appended daily entry for <date> …` on a run
   that actually appends a new daily row — gated by the `EXISTING` check at
   `scripts/uptime-history.sh:147-148`. **`EXISTING` is keyed on
   date + `period_end_unix` together, not date alone**: the grep pattern
   matches a row only if it has BOTH today's date AND the current run's
   `period_end_unix`. The script's own comment (`:142-146`) says why: "if
   the period rolled over today (rare), we accept two rows on the same
   date — one for the old period (its closing snap) and one for the new
   (its opening snap)." So the skip line, `Daily entry for $TODAY already
   present, skipping append` (`:171`), only fires when a row for THAT SAME
   `period_end_unix` is already present today — not merely "today already
   has some row" — and is **not** gated on `fyd_is_live`, so it appears in
   both dry and live runs — and, on a cycle boundary, `Closed cycle #<N>: …`
   (`:259-261`) plus `Wrote <uptime-recent.json> (<n> total …)` /
   `Wrote <uptime-cycles.json> (<n> cycles)` (`:287-290`). `Closed cycle
   #<N>: …` in particular names the exact thing this step exists to do —
   it is the strongest signal. The absence of `DRY:` lines is a weaker,
   negative-only check: a second, unrelated exit-0 path exists if
   `scripts/cycle-gate.sh` is missing or non-executable (this doc's
   Rollback lever 2, `chmod -x` — see below) — the cycle-boundary half of
   this script (Job B) then skips, independent of `FY_LIVE`. This is not
   silent: it prints its own named stderr line (`[uptime-history]
   cycle-gate.sh missing or non-executable → skip Job B (fail-closed)`,
   `:187`) — it simply carries no `DRY:` tag, so a check that greps only
   for `DRY:` would miss it.

   Run this step verbatim without `FY_LIVE=1` and cycle N's uptime record is
   never closed — but this does **not** silently pollute step 3's output
   with a wrong row. `gen-cycle-history.sh` maps `uptime-cycles.json`'s
   `.cycles` array to output rows 1:1 (`sort_by(.cycle_n) | .[]`,
   `scripts/gen-cycle-history.sh:153-190`), so with no cycle-N element
   present it emits **no cycle-N row at all** — no cycle-N row is added,
   full stop. Whether the regenerated `cycle-history.jsonl` is
   byte-identical to the previous run additionally depends on
   `incidents.json`, `gen-cycle-history.sh`'s other canonical input
   (`:105-106`): if that file is unchanged since the last regeneration the
   output is byte-identical; if it changed, existing rows' incident fields
   are recomputed and the bytes differ even though no cycle-N row exists.
   Either way the row count for cycle N does not grow. The failure surfaces
   downstream instead: `CLOSED_COUNT` stays at
   N-1, which step 3's own "grew by exactly one line" check (below) is
   designed to catch directly; even if that check were skipped, step 4's
   `gen-identity.sh` (**exit 7**) and step 5's `gen-anchor-source.sh`
   (**exit 9**) ordering guards hard-stop on the stale count before either
   script does anything further. What to hunt for after a missed
   `FY_LIVE=1` is therefore a **missing** cycle-N row in
   `cycle-history.jsonl`, not a wrong one.

   **2026-09-04 specifically needs care reading the `Appended daily entry`
   signal above.** If cycle 4→5's `AddValidator` confirmation (step 1
   above) lands mid-day, `uptime-history.sh` closing out cycle 4 in the
   morning and a later run picking up cycle 5's new `period_end_unix` are
   two DIFFERENT `EXISTING` combos on the SAME calendar date — the later
   run legitimately prints a second `Appended daily entry for 2026-09-04 …`
   line, not the skip line. **A second `Appended daily entry` for the same
   date that day is the expected success signal, not a duplicate-run
   symptom** — do not treat it as something to suppress or investigate on
   its own; if in doubt, compare each run's `period_end_unix` (in its
   `Appended …` line, or the corresponding `uptime-history.jsonl` row)
   against step 1's confirmed `endTime`.
   **2.5 — 開示 incident の公開 (該当する cycle だけ。2026-09-04 は該当する)。**
   その cycle に属する未公開の開示 incident があるなら、**step 3 より前に**
   `public/api/incidents.json` へ append し、公開まで届かせてから step 3 に進む。
   該当が無い cycle ではこのブロックは丸ごと飛ばしてよい。逆に、**step 3 の
   直前に「当 cycle 分の未 append entry が無いこと」を必ず 1 度確認する** —
   これが飛ばして良いかどうかの判定そのもの。

   > この節がトップレベルの `2.5.` マーカーではなく step 2 の sub-block として
   > 書かれているのは意図的。`tests/cycle-transition/` の drift gate が、この
   > runbook のトップレベル step マーカー集合を `scripts/cycle-transition.sh`
   > の unit 表と完全一致させている
   > (`tests/cycle-transition/test-cycle-transition.sh:286-300`)。これは毎 cycle
   > 走る実行単位ではなく該当時のみの挿入なので、orchestrator の unit を
   > 増やさずに canon 側だけに置く。

   **なぜ step 3 より前でなければならないか**: `gen-cycle-history.sh` は
   incident の cycle 帰属を `detectionDate` で決め
   (`scripts/gen-cycle-history.sh:175-184`)、その入力は **validator host の
   repo 内 `public/api/incidents.json`** (`:106`) であって公開 URL ではない。
   step 3 の時点で entry が無ければ、その cycle の行は
   `incidents_in_cycle_count` を 1 件過少にしたまま **append-only 台帳に確定**
   する。しかも同 `:205-214` の conservation check は**両辺とも append 前の
   同じファイル**から計算するので、この取りこぼしを検出できない。台帳の bytes
   は DAG に流れ込むので、後から直せない。

   手順 (この順序で。実行者ラベルは上の「実行者と実行場所」節):

   0. **本文は `docs/pending-disclosures/<id>.json` に tracked で置いてある。**
      scratch から拾わない。`find docs/pending-disclosures -name '*.json'` が
      その cycle に流す全量で、**2026-09-04 は
      `docs/pending-disclosures/2026-08-17-01.json` の 1 件**
      (`README.md` は常駐の説明文なので数えない)。**`*.json` が 1 件も
      返らなければ step 2.5 は非該当** (= 上の「該当が無い cycle」)。各ファイルは `incidents[]` に**そのまま入る entry
      オブジェクト**で、公開される bytes と同一 — 当日に整形し直す前提のもの
      ではない。中身は `tests/incidents/test-schema.sh` が毎回
      schema validate + 二重公開チェックにかけている。
   1. **AI@Mac** — その entry を `public/api/incidents.json` の `incidents[]`
      の**先頭**に挿入する (newest-first)。**手で貼らない**:
      ```sh
      P=docs/pending-disclosures/2026-08-17-01.json
      jq --slurpfile e "$P" '.incidents = ($e + .incidents)' \
        public/api/incidents.json > /tmp/incidents.new \
        && mv /tmp/incidents.new public/api/incidents.json
      ```
      `jq .` は現行の `incidents.json` を byte-for-byte round-trip する
      (2026-08-18 実測) ので、この 1 行の差分は **entry の挿入だけ**になる。
      **続けて同じ working tree で pending 側を消す** — 挿入と削除は
      **同じ commit** に入れる:
      ```sh
      git rm -q "$P"
      ```
      なぜ同じ commit か: pending file が残ったまま push すると、
      `tests/incidents/test-schema.sh` の「staged id が既に publish されている」
      検査が **exit 1** を返し、`ci-main.yml` (main 直 push を見る唯一の CI 経路、
      `find` の自動 discovery でこの suite を拾う) が **step 4b まで数時間赤くなる**。
      それは直下の一時 baseline entry が塞いでいるのと**同じ赤窓**で、片方を
      塞ぎながらもう片方を開けることになる。挿入と同じ commit で消せば窓は
      開かない (2026-08-18 に scratch clone で 3 gate 緑を実測)。**この削除は
      「公開後の後片付け」ではなく「公開そのものの一部」**と読むこと。

      **適用直前チェック (3 点)** — いずれも記憶で判断しない:

      ① `resolutionDate` が実際の配信日と一致するか
      (ずれるなら**先に pending 側を**直してから進む)。

      ② entry 本文が repo の現況とまだ合っているか。`2026-08-17-01` は
      「governing document に 1 箇所残る記述は operator の改定待ち」と書いて
      いるので、`grep -n PulseVM docs/CONSTITUTION.md` が **0 hit になっていたら
      その 1 文を削ってから**公開する (公開面に古い約束を残さない)。

      ③ **entry が「もう公開されている」と書いている事実を、公開面で裏取りする。**
      `2026-08-17-01` は「訂正済みの schema と example は**この記録より後には
      ならない形で**配信されている」と主張する。その主張は**公開面を curl して
      初めて真偽が決まる**:
      ```sh
      B=https://metal.freedom-yield.com/api
      # ③-1 example 4 本 (= chain_backend は全部で 6 値)
      for f in anchor-receipt.example.json anchor-receipt.v2.example.json \
               anchor-receipt.phase-beta.example.json; do
        curl -s "$B/$f" | jq -r '.anchor.chain_backend'
      done
      curl -s "$B/anchor-history.example.jsonl" | jq -r '.chain_backend'
      # ③-2 schema 4 本 — 訂正は description の書き換えなので文字列で見る
      #     (receipt 側は "NOT an execution engine"、history 側は小文字 → -i)
      for f in anchor-receipt.schema.v1.json anchor-receipt.schema.v2.json \
               anchor-history.schema.v1.json anchor-history.schema.v2.json; do
        printf '%s ' "$f"; curl -s "$B/$f" | grep -ci 'not an execution engine'
      done
      # ③-3 dated revision entry を持つのは v1 の 2 本だけ (v2 は x-revision-history 無し)
      for f in anchor-receipt.schema.v1.json anchor-history.schema.v1.json; do
        curl -s "$B/$f" | jq -r '.["x-revision-history"][-1].date'
      done
      ```
      合格条件は 3 つとも: **③-1 の 6 値がすべて `antelope`** /
      **③-2 の 4 行がすべて 1 以上** / **③-3 の 2 行がどちらも `2026-08-17`**。
      本文は「schemas と examples」と複数形で主張するので、**example だけ見て
      通さない** (2026-08-18 レビュー N3)。なお `scripts/` 配下の generator と
      ledger writer は**公開面に存在しない** (rsync 脚は `public/`-rooted、
      `deploy.yml:304` `:373`。2026-08-18 に 2 本とも **HTTP 404** を実測) ので、
      本文もそれらを「配信されている」側には数えていない — ここを確認対象に
      加えない。**まだ `pulsevm` が返るなら**、訂正 commit が
      公開面に届いていない (= main が未 push、または deploy 未完) ということ。
      その場合は **手順 4 の push が同じ deploy で訂正も配信する**ので、
      **手順 6 の配信確認でこの curl を再実行して `antelope` を確認するまで
      step 3 へ進まない**。どちらでも駄目なら、その 1 文を書き換えてから公開する。
      **「たぶんもう出ている」で通さない** — この entry が開示しているのは
      「将来形を現在形として公開した」ことそのもので、同じ形の文を載せたまま
      公開すると開示の信頼性を自分で壊す (2026-08-18 のレビュー I1)。
   2. **AI@Mac** — `public/api/incidents.schema.v1.json` に対して validate する。
      **検証単位は entry 単体ではなく `incidents.json` 文書全体** (entry 単体だと
      `'validatorSince' is a required property` で落ちる)。
   3. **AI@Mac** — **同じ commit に `deploy/identity-pin-baseline.json` の一時
      entry を同梱する** (次の小節)。これを忘れると main の CI が step 4 まで
      数時間赤くなる。**この commit が運ぶのは 3 つ**:
      `public/api/incidents.json` (entry 挿入) /
      `docs/pending-disclosures/<id>.json` (削除) /
      `deploy/identity-pin-baseline.json` (一時 entry 追加)。
   3.5 **AI@Mac** — **push する前にローカルで CI gate を 2 本回す**。
      片方だけでは赤窓の片側しか見えない:
      ```sh
      bash scripts/check-identity-pins.sh --mode=repo
      bash tests/incidents/test-schema.sh
      ```
      - 1 本目: **`BASELINED incidents_json.sha256` の 1 行が出て exit 0** なら
        正しい。**exit 3 (`MISMATCH …`) が返るなら push しない** — 原因は ①entry を
        `known_broken` の下ではなく top level に置いた ②2 つの sha256 の採り違え
        ③コピペ崩れ、のいずれか。この 1 コマンドが 3 つとも push 前に捕まえる。
      - 2 本目: **`INFO 0 staged disclosure(s) awaiting publication` が出て
        exit 0** なら正しい。`… is ALREADY published … delete the staged copy`
        で **exit 1** なら手順 1 の `git rm` を忘れている。**ここで捕まえないと
        push 後に main の CI が赤くなる** (この suite は
        `tests/run-all-tests.sh` の `find` 自動 discovery に乗っている)。

      (これを省くと「push して CI が赤くなって初めて気づく」= step 2.5 が
      防ごうとしている事象そのものになる。)
   4. **AI@Mac** — commit → push。**`push-to-web-host.sh` は使わない**:
      `deploy/publication.json` の `api/incidents.json` は
      `publisher: git-deploy` / `git_tracked: true` で、`push-to-web-host.sh` の
      allowlist に `incidents` は無く `ERROR: unrecognized filename` になる。
      配信経路は git-deploy 一本。
   5. **AI@Mac** — **deploy workflow の完了を `gh run watch` で待つ。これが
      本当の依存。** `.github/workflows/deploy.yml` の "Advance host checkout to
      origin/main" step (`:242`) が **push ごとに** host の checkout を前進させ、
      同 `:283` が `merge-base --is-ancestor $GITHUB_SHA HEAD` で到達を
      fail-closed に assert する (`docs/HOST_CHECKOUT_AUTO_ADVANCE.md:27-31`
      — 「not just once a day」)。したがって **`advance-host-checkout.sh` を
      手で叩く必要はなく** (叩いても `behind == 0` で exit 0 する冪等 no-op)、
      日次 cron `45 4 * * *` を待つ話でもない。手動実行は deploy が失敗した
      ときの fallback としてのみ。**deploy を待たずに手動前進で済ませると、
      rsync による公開面配信が起きないので手順 6 の `curl` が通らない。**
      なお `deploy.yml:24-29` の `paths-ignore` は `README*` / `.gitignore` /
      `CLAUDE.md` / `docs/**` だけなので、`public/api/incidents.json` の push は
      確実に deploy を trigger する。
   6. **AI@Mac + AI@host** — 配信確認を**両側**で取る。公開側:
      `curl -s https://metal.freedom-yield.com/api/incidents.json | jq -r '.incidents[0].id'`。
      host 側: host repo の `public/api/incidents.json` を
      `jq -r '.incidents[0].id'`。**両方**が新 entry の id を返して初めて次へ。
      公開側だけ通っても host 側が古ければ step 3 は過少のまま確定する。
      **手順 1 の③がまだ `pulsevm` を返していた場合は、ここで③-1〜③-3 を
      まるごと再実行する。** 同じ deploy が訂正済みの example と schema も
      配信しているので、**③の合格条件 3 つがすべて満たされて**いなければ
      ならない。満たされていなければ公開した本文が偽のまま出ているという
      ことなので、step 3 に進まずその場で扱う。
   7. → ここで **step 3** へ。書かれたその cycle の行が
      `incidents_in_cycle_ids` に**新 entry を含んで**いることを確認する
      (2026-09-04 なら新 entry + `2026-08-06-01` の 2 件)。1 件しか無ければ
      手順 5/6 が効いていない。
   8. 終了状態の確認: `find docs/pending-disclosures -name '*.json'` が
      **1 件も返さない** (手順 1 の `git rm` の結果)。`README.md` は常駐
      するので「ディレクトリが空」ではなく「**`*.json` が無い**」が正しい
      終了状態 (2026-08-18 レビュー N4/N5)。**step 4b では何もしない** —
      pending file の後片付けは step 2.5 の中で閉じている。同じ本文を
      2 箇所に残さないための削除であって、公開後の掃除ではない。

   **一時 baseline entry (手順 3 の中身)。** `public/api/incidents.json` は
   `deploy/feed-excludes.txt` に載っていない = **`tracked` 級**で、署名済み
   manifest の `artifact_manifest.incidents_json.sha256` に pin されている。
   手順 4 の push から step 4 の再署名までの数時間、repo 内の pin と実ファイル
   が乖離し、`scripts/check-identity-pins.sh --mode=repo` が **exit 3** を返す
   = `ci-main.yml` (main への直 push を見る唯一の CI 経路) が赤くなる。
   この赤は順序を入れ替えても消えない: `gen-identity.sh` は leaf を**公開 URL
   から curl** して pin するので、incidents.json は配信済みでなければならず、
   identity.json と同一 commit には入れられない。`deploy/identity-pin-baseline.json`
   はまさにこの acknowledgement のために存在する。同じ commit に、そのファイルの
   **`known_broken` オブジェクトの下に** (top level ではない) 次の entry を足す:

   ```json
   // deploy/identity-pin-baseline.json — "known_broken": { … } の中に足す。
   // top level に置くと check-identity-pins.sh:504 が読まず、exit 3 のまま
   // (= この step が塞ごうとしている赤窓が開く)。
   "incidents_json.sha256": {
     "path": "public/api/incidents.json",
     "class": "tracked",
     "pinned_sha256": "<現行 identity.json の artifact_manifest.incidents_json.sha256>",
     "observed_sha256": "<append 後の public/api/incidents.json の sha256>",
     "reason": "TEMPORARY, this cycle transition only. The disclosure entry must be published before step 3 reads it, but gen-identity.sh pins this file by curling the PUBLISHED copy, so the new sha256 cannot be re-signed in the same commit.",
     "resolution": "Deleted in the step-4 commit (step 4b). The step-4 re-issue pins the new bytes.",
     "gate_effect": "suppresses-exit-3-until-reissue"
   }
   ```

   2 つの sha256 は**記憶から書かない** —
   `jq -r '.artifact_manifest.incidents_json.sha256' public/api/identity.json` と
   `shasum -a 256 public/api/incidents.json` で当日採る。suppression の scope は
   この `(pinned_sha256, observed_sha256)` の pair に閉じている:
   `scripts/check-identity-pins.sh:719` が `class == "tracked"` **かつ**両方の
   sha が一致するときだけ suppress するので、どちらか一方でも動けば即座に赤へ
   戻る (= mute button ではない)。

   **実測 (2026-08-18、`6e172a2` の scratch clone で実走)**: 同一の
   `incidents.json` を置いた 2 arm で —
   entry **あり** → `BASELINED incidents_json.sha256 tracked …` / **exit 0**、
   entry **なし** → `MISMATCH … NEW break of the signed manifest` / **exit 3**。
   同じ中間状態で `tests/identity-pins/` 109/109、
   `tests/publication-registry/` 37/37、`tests/cycle-transition/` 125/125 も
   すべて緑であることを確認済み — この一時 entry は他の gate を壊さない。

   **step 3 に進む前に**: 直上の **step 2.5 (開示 incident の公開)** を通過したか
   確認する。該当 incident が無い cycle なら「無いことを確認した」で通過扱い。
   **ここを素通りすると incident 件数が過少のまま台帳に確定する** (step 2.5 の
   「なぜ step 3 より前でなければならないか」)。

3. **host — `gen-cycle-history.sh` + publish** appends cycle N's row to
   `cycle-history.jsonl` and ships it to the web host:
   ```sh
   bash scripts/gen-cycle-history.sh
   bash scripts/push-to-web-host.sh cycle-history.jsonl
   ```
   Neither script takes `FY_LIVE` — confirmed by reading both (2026-08-17):
   `gen-cycle-history.sh`'s own header states in so many words that it is
   "NOT GATED ON FY_LIVE" by deliberate design (it never touches
   `${FY_STATE_DIR}`, sends no notification, and its only write is a
   deterministic regeneration of a working-tree artifact already
   fail-closed behind `cycle-gate.sh`); `push-to-web-host.sh` has no
   `FY_LIVE` concept at all — every invocation pushes unconditionally. Do
   **not** add `FY_LIVE=1` to either command; it would not be read by
   either script and could be mistaken for a required gate that isn't
   there. The publish step is **not optional and not automatic**: steps 4
   and 5 read the *published* ledger, so without it `gen-identity.sh`
   (exit 7) and `gen-anchor-source.sh` (exit 9) both count a stale
   `CLOSED_COUNT`. Verify the published file grew by exactly one line
   (curl the public URL and compare line counts) before continuing.
   **「exactly one line 増えた」は事前の基準値が無ければ検証できない** — この
   step を実行する**前に**公開版の行数を 1 度採って控えておく
   (`curl -s https://metal.freedom-yield.com/api/cycle-history.jsonl | wc -l`)。
   この基準値は step 2 の完了確認としても使える。期待値は
   実行前 **`N-1` 行 → 実行後 `N` 行** (day-of value sheet の `CLOSED_COUNT`
   と同じこと。記入例の 2026-10-07 なら 4 → 5)。
4. **Mac —**

   **前操作 (operator@TTY) — identity 鍵を ssh-agent に載せる。**

   ```sh
   ssh-add ~/.ssh/freedom-yield-operator-identity
   ```

   - **打つ人**: **operator 自身**。passphrase を入力するため、AI には渡さない。
     Dashlane の entry 名はこの repo には書かない — ピング送付時に AI が添える。
   - **目視するもの**: `Identity added: /Users/…/freedom-yield-operator-identity`
     の 1 行。
   - **失敗したら**: `Bad passphrase` → entry 名を AI に確認して打ち直す。
     何も壊れないし何度でもやり直せる。
   - **なぜこれをやるか**: 下の `gen-identity.sh` は
     `ssh-keygen -Y sign -f "${OPERATOR_IDENTITY_KEY}"` を秘密鍵の path 直指定で
     呼ぶ (`scripts/operator-local/gen-identity.sh:895`)。agent に載っていれば
     以降の呼び出しで passphrase プロンプトが出ず、**AI が gen-identity を
     最後まで実行できる**。載せないと AI の非対話セッションがプロンプトで
     止まる。agent はセッションを跨がないので、**転換当日に改めて必要**
     (9/1 の稽古で 1 度やっていても、9/4 にもう 1 度要る)。

   **本体 (AI@Mac):**

   ```sh
   FY_EXPECT_CYCLE=<N> OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity \
     bash scripts/operator-local/gen-identity.sh
   ```
   then commit, push, `gh run watch` until deploy completes.

   **後操作 (AI@Mac) — identity 鍵を agent から外す。** identity 鍵の最後の
   利用は上の `gen-identity.sh` なので、それが exit 0 で終わり再実行の必要が
   無くなったら、AI が `ssh-add -d ~/.ssh/freedom-yield-operator-identity` で
   ssh-agent から外す (passphrase を伴わないので operator の手作業ではない)。
   `ssh-add -l` にその鍵が出ないことを確認する。
   **push は 4b の編集を取り込んでから** — step 4b は "MANDATORY, same commit
   as step 4" なので、正しい順序は「step 4 で生成 → 4b の registry 編集 →
   `tests/publication-registry/` を回す → **まとめて 1 commit** → push →
   deploy 待ち」。この行を読んだ時点で commit + push まで走ると、4b が次の
   commit に落ちて main が赤くなる (4b 自身の警告と同じ状態)。
   `FY_EXPECT_CYCLE=<N>` is **mandatory** at a cycle transition (N = the
   cycle that just closed, e.g. `FY_EXPECT_CYCLE=3` at the cycle-3 →
   cycle-4 transition): it hard-stops (exit 7) if step 3's published ledger
   has not caught up yet, turning "record the closed cycle before
   regenerating identity" into a machine-checked precondition instead of
   operator vigilance. Left unset, `gen-identity.sh` still runs (needed for
   first-run / bootstrap) but prints a loud stderr warning that the
   ordering guard is disabled for that run.

   **Two other hard-stops fire in this step, both BEFORE the exit-7
   ordering guard** (they sit in the artifact-probing section, which runs
   first — so if you see one of these, the ordering guard has not been
   evaluated yet and says nothing about your ledger):

   | exit | meaning | fix |
   |---|---|---|
   | **9** | `deploy/publication.json` is unreadable / unparseable, or an artifact the manifest names has no row in it. The script will not guess whether a digest is safe to sign. | Restore or fix the registry (it is git-tracked), or add the missing publication row with its `kind`. |
   | **10** | Artifacts are live, but every one of them is `kind=stream`, so `artifact_root` would commit to nothing. | Check that `/api/incidents.json` (kind=static) and the `/api/archive/` anchor-source record are actually being served. |

   Neither has ever fired in production; both exist because signing a
   manifest whose pins are unverifiable is worse than not signing one.

4b. **Mac — the C4 post-issuance cleanup (MANDATORY, same commit as step 4).**
   `gen-identity.sh` stopped pinning `kind=stream` publications on
   2026-08-14, but the acknowledgement lists that describe the *old* pins
   are not self-clearing. Land all of this in the commit that carries the
   new `identity.json`, or `tests/publication-registry/` goes red on main:

   - `deploy/identity-pin-baseline.json` — delete all three
     `known_broken` entries (`evidence_json.sha256`,
     `validator_json.sha256`, `uptime_cycles_json.sha256`) and the
     `c4_status` block with them. Those pins no longer exist.
   - `deploy/identity-pin-baseline.json` — **step 2.5 を実行した cycle では、
     そこで足した一時 entry `incidents_json.sha256` もこの commit で削除する。**
     step 4 の再署名で `pinned_sha256` 側が新しい値に変わるため entry は
     suppress しなくなり、`check-identity-pins.sh` は
     `OBSOLETE-BASELINE incidents_json.sha256 … delete this entry` を印字する
     (2026-08-18 に scratch clone で実測)。**ただしこの行は exit code を変えない
     report-only なので、削除忘れを CI は落としてくれない** — この bullet で
     必ず落とす。
   - `deploy/publication.json` — set
     `known_kind_violations.violations` to `{}` (all four entries expire
     at once), and clear `pinned_by` on `api/evidence.json`,
     `api/validator.json`, `api/cycle-history.jsonl` and
     `api/uptime-cycles.json`.
   - `deploy/publication.json` — declare the two pins that are new:
     `api/incidents.schema.v1.json` gains
     `"pinned_by": ["api/identity.json#artifact_manifest.incidents_json.schema_sha256"]`,
     and the `api/archive/` directory row gains
     `"pinned_by": ["api/identity.json#artifact_manifest.anchor_source_archive_json.sha256"]`
     (a content-addressed member is declared on its directory row —
     that is the only row that can carry it).

   Verify with `bash tests/publication-registry/test-publication-registry.sh`.
   Its `T19` case exercises exactly this before/after pair, and **both of its
   registry fixtures are synthesised rather than read off disk**, so T19 gives
   the same verdict before and after you apply this list — a green T19 after
   the cleanup is the expected result, not a sign the case stopped testing.
   The suite as a whole is the check that the cleanup was complete: `T6`, `T7`
   and `T14` read the real registry and the real manifest, and they are what
   go red if any bullet above is missed.

5. **host —**
   ```sh
   FY_EXPECT_CYCLE=<N> bash scripts/gen-anchor-source.sh
   ```
   > This step prints exactly one `side-effects: WARNING: state dir falls
   > back to the production default … while FY_LIVE is not "1"` line. That
   > is **expected and correct here**: this script only READS the two JSONL
   > streams under that directory, and reading production data is the whole
   > point of composing the anchor from live sources. **Do not act on the
   > line's suggestion to point `FY_STATE_DIR` at a sandbox** — that advice
   > is aimed at test authors and would compose the DAG from empty inputs.
   > Do not add `FY_LIVE=1` either: this script writes no production state,
   > and the opt-in is not what makes the read correct.
   composes the fresh `anchor-source.json` (3-branch DAG) on the validator
   host (cycle-4 day example: `FY_EXPECT_CYCLE=3`). It derives
   `cycle_number_observed` as `CLOSED_COUNT + 1` from the published
   `cycle-history.jsonl` line count, and carries its own ordering guard:
   if `FY_EXPECT_CYCLE` is set and does not match `CLOSED_COUNT` (= step 3
   has not landed on the published ledger yet), it hard-stops with
   **exit 9** before composing anything — checked before the P-chain RPC
   call, so it fails fast even if metalgo is unreachable. Left unset, it
   still runs (needed for first-run / bootstrap) but prints a loud stderr
   warning that the guard is disabled.
   **Exit 9 here is a different condition than `gen-identity.sh`'s exit 7**
   for its analogous guard — the two are not the same number by design:
   `gen-anchor-source.sh`'s own exit 7 already means "atomic write failed"
   (see its header's exit-code table), so its ordering guard had to take a
   different code. Do not read "exit 7" and "exit 9" as the same condition
   just because the two scripts' guards are conceptually parallel.
6. **Mac —** all three lines below are commented out on purpose: pasting
   this block as-is is a harmless no-op (every line is a `#` comment, so
   nothing executes). Uncommented, the unquoted `<...>` placeholders break
   shell parsing outright — `<`/`>` are redirection operators, not literal
   text, so pasting e.g. `export VALIDATOR_HOST_KEY=~/.ssh/<your_validator_host_key>`
   raises `syntax error near unexpected token 'newline'` before any script
   ever runs, not the clean script-level `ERROR: SSH key not found` / exit 3
   described below (that failure is what you get if `VALIDATOR_HOST_KEY` is
   simply left unset, letting the script's own default apply — not from
   pasting the placeholder text itself). Replace every placeholder with
   your real value, THEN remove all three leading `#`s.
   ```sh
   # export VALIDATOR_HOST=<validator host IP or hostname>
   # export VALIDATOR_HOST_KEY=~/.ssh/<your_validator_host_key>  # only if not using the default path
   # bash scripts/operator-local/commit-anchor-source.sh --expect-cycle=<N+1>
   ```
   verifies + commits the host-composed `anchor-source.json` (cycle-4 day
   example: `--expect-cycle=4`). The two exports are the SSH coordinates
   it fetches with — never literal in this repo, so both are yours to
   supply: `VALIDATOR_HOST` is **required** (unset → immediate refusal
   naming the variable), and `VALIDATOR_HOST_KEY` **defaults to the
   literal placeholder** `~/.ssh/<your_validator_host_key>`, a path that
   does not exist, so leaving it unset fails with `ERROR: SSH key not
   found` and **exit 3**. (`VALIDATOR_HOST_USER` defaults to `root`.) Deliberate meaning switch from step 5:
   `gen-anchor-source.sh`'s `FY_EXPECT_CYCLE` is the closed-cycle count,
   while this script's `--expect-cycle` is the cycle number being
   inscribed — it compares directly against the fetched file's
   `observations_branch.cycle_number_observed` (which `gen-anchor-source.sh`
   composes as `CLOSED_COUNT + 1`), so passing `<N>` here exits 5
   (mismatch). Push + wait for deploy is a separate, subsequent action
   (same pattern as step 4).
   **step 6 の完了条件は「push した」ではなく「公開サイトが同じ bytes を
   配っている」**: `gh run watch` で deploy の完了まで待ち、公開反映を
   確認してから step 7 へ進む。待たずに進むと **7b が exit 10** で落ちる
   (7b は LIVE な公開 `anchor-source.json` を cache-bust して取得し、
   committed bytes と一致しなければ拒否する)。exit 10 は 7b の説明中に
   あるが、**それは落ちてから読む場所**なので、ここで待つ。
   **Not optional**: `anchor-source.json` publishes via the normal
   git-deploy path, and until that deploy lands, step 9's Phase 1 polling
   never observes a fresh `dag_root_computed` and times out (exit 3).
7. **Mac — rehearse, produce the gate-4 material, then sign + broadcast.**
   Every command in this step runs on the operator's **Mac**, and the step
   runs **after step 6's commit + push have landed**: what gets signed must
   be the bytes that were committed, pushed and deployed, or the receipt's
   `url` + `sha256` will point at content that does not contain the
   inscribed `dag_root_computed`.

   **7a — gate-1 material (testnet-first).** A fresh testnet rehearsal of
   this cycle's exact memo shape. The day-of invocation MUST carry
   `--expect-cycle=<N+1>` (mandatory per
   `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`; cycle-4 day example: `4`):
   **この 2 行はどちらも operator@TTY** (打つのは operator、AI ではない):

   ```sh
   HOME=~/.metal-fy-proton-test proton key:unlock
   HOME=~/.metal-fy-proton-test bash scripts/run-testnet-rehearsal.sh --expect-cycle=<N+1>
   ```

   - **目視するもの (この順で)**: ① `step 1/10` の `cycle_number_observed:` と
     `derived memo_prefix:` ② `step 3/10` の
     `present: … (matches current on-chain key)` ③ `step 7/10` の
     `BROADCAST OK  tx_id=<64hex>` ④ `step 9/10` の `7-gate PASS`
     ⑤ 末尾の `TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>`。
   - **AI に渡すもの**: ⑤の 1 行を**そのまま chat に貼る**。これは script が
     自動で引き継ぐものではなく、**人が目で拾って貼る手渡し**であり、貼り
     間違いを検出する機構は無い (7b/7c の `--testnet-tx-id=` の入力になる)。
   - **失敗したら**: exit **2** = keystore が locked → 上の unlock をやり直す。
     exit **8** = `HOME=` prefix の付け忘れ → 付けて再実行。exit **1** は
     原因が多岐 (`fail()` 全部) に潰れるので、**まず「`step 7/10` の行が
     画面に出ていたか?」を確認する** — 出ていなければ broadcast は未発生、
     出ていれば testnet 上に tx が残っている場合がある。この 1 問が
     「やり直してよいか」の分岐そのもの。
   - **なぜ operator が打つのか**: 上の「実行者と実行場所」節の引用ブロック
     (認可の実体が「operator 自身の起動」であること)。
   - **中止したくなったら**: 打たなければよい。この時点では mainnet 側は
     何も起きていない。
   - **後操作 (operator@TTY) — testnet keystore を直後に re-lock する。**
     testnet keystore の最後の利用はこの 7a なので、`TESTNET REHEARSAL
     COMPLETE` を拾ったらすぐ閉じる (7b / 7c / 8 は testnet keystore を使わ
     ない)。手順と注意 (同じ 32 文字・**空 Enter 禁止**) は 7c の「後操作 2」と
     同じ。
   - **直後の 7b が testnet tx の `block_num` を MISS と出しても、7a を
     やり直さない。** testnet の Hyperion は tx を索引に出すまで数分かかる
     ことがある (2026-10-07 実測)。`COMPLETE` 行が出ていれば tx は在る —
     数分待って **7b だけ**を再実行する。7a の再実行は testnet への 2 度目の
     broadcast になる。

   Its closing `TESTNET REHEARSAL COMPLETE testnet_tx_id=<64hex>` line is
   the `--testnet-tx-id` gate-1 input below. Its own dry-run log is
   **testnet-side evidence only** — it records `target_chain: "testnet-a"`,
   and mainnet gate 4 refuses a dry-run log whose recorded chain differs
   from `--chain`.

   Because step 6 has already landed by the time this runs, the canonical
   `public/api/anchor-source.json` is already this cycle's file
   (`cycle_number_observed == N+1`) — the command above needs no
   `--source=` override and no `--allow-fixture` fixture; the default
   selection is correct on its own, and `--expect-cycle=<N+1>` passes
   cleanly against it. **Do not run 7a earlier in the day (e.g. in the
   morning, before step 6 has landed) against a hand-built fixture
   file** — at that point the canonical source is still last cycle's
   (`N`), and producing real gate-1 evidence for `N+1` before it exists
   would require hand-authoring a fixture and forcing a dag-root
   recompute. That is exactly what happened on 2026-08-04 (morning
   rehearsal run, before that day's step 6): a hand-built fixture plus a
   dag-root recompute that then had to be reconciled against the real
   source once step 6 landed — extra work and an extra chance to anchor
   the wrong bytes. Run 7a only after step 6, against the real file.

   Immediately after the rehearsal completes, clean up its leftover
   token: `rm -f /tmp/fyd-broadcast-token`. Step 6/10 of
   `run-testnet-rehearsal.sh` wrote that file bound to `chain=testnet-a`
   (R16) — it cannot be reused to authorize the mainnet broadcast in 7c
   even before it expires (`bin/safe-broadcast` gate 2 refuses a
   chain-bound mismatch outright), and its 5-minute TTL means it goes
   stale shortly regardless — but leaving it in place is needless noise
   when inspecting `/tmp` ahead of 7b/7c. This only removes a file the
   rehearsal itself created; it does not touch any gate.

   **7b — gate-4 material (mainnet dry run).** One path only: on the Mac,
   from the already-committed `anchor-source.json`, with **no recompose**:
   ```sh
   FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
     bash scripts/preview-cycle-anchor-broadcast.sh \
       --source=public/api/anchor-source.json \
       --testnet-tx-id=<rehearsal tx id>
   ```
   The script verifies the source is byte-for-byte
   `git show HEAD:public/api/anchor-source.json` (refuses with exit 9
   otherwise), then fetches the LIVE public `anchor-source.json`
   (cache-busted) and refuses with **exit 10** if the site does not yet
   serve those same bytes — push + deploy first, then re-run
   (`--skip-published-check` bypasses this for offline/degraded use only).
   It then writes the dry-run log to `$DRYLOG` (default
   `/tmp/fya-mainnet-dryrun.json`), runs the gate-1/gate-3 read-only
   pre-checks, and prints the 7c command below with both gate args already
   filled in. It composes nothing and broadcasts nothing.

   - **Do not run it on the validator host** (`sudo -u deploy … preview-…`).
     The §3.5 keystore guard refuses a login-HOME invocation with **exit 8**,
     and a host-side recompose would silently produce a *different*
     `dag_root_computed` than the committed bytes: `anchor-source.json`'s
     artifacts branch hashes live feeds that the 5-minute crons rewrite.
   - The equivalent bare form, if you want the log without the pre-checks:
     ```sh
     FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
       bash scripts/sign-anchor-event.sh --chain=mainnet-a \
         --anchor-source=public/api/anchor-source.json \
         --dry-run > /tmp/fya-mainnet-dryrun.json
     ```
     `FY_CONFIG_DIR` is **not optional** here either: without it the script
     exits 3 (config missing) and the redirect leaves a **0-byte** log that
     is only rejected later, at gate 4.

   **7b.5 — history reachability (host, read-only, before 7c).** Added
   2026-09-30 (A-Chain → PulseVM migration readiness). Step 8 resolves the
   broadcast tx from history **after** the irreversible broadcast, and it now
   reads its history bases and chain_id from the committed chain profile
   (`config/a-chain-profiles.json`, via `scripts/lib/a-chain-profile.sh`).
   So **before stop 4(a) — before the mainnet keystore is unlocked** — prove
   on the host, with the same reader code on the same machine as step 8,
   that it will be able to. Both lines run as `sudo -u deploy` in the host
   repo, exactly like step 8:
   ```sh
   # host preconditions (must exit 0): checkout advanced so the profile and
   # the libraries are present; jq printed (>= 1.6); no stale chain override
   git rev-parse --short HEAD && test -r config/a-chain-profiles.json \
     && test -r scripts/lib/a-chain-profile.sh \
     && test -r scripts/lib/anchor-history-read.sh && jq --version \
     && ! env | grep -e ^FYD_MAINNET_CHAIN_ID= -e ^FYD_TESTNET_CHAIN_ID= -e ^FYD_A_CHAIN_PROFILE_
   bash scripts/check-anchor-history-reachable.sh --chain=mainnet-a
   ```
   Exit 0 prints one `REACHABLE profile=xpr-mainnet … mode=known-tx` line:
   the newest anchor in the host ledger still resolves, with block number,
   time and chain, through the profile's history bases in the receipt's own
   order. **Any non-zero stops the day here** — 2 = the profile cannot
   supply what the receipt needs, 3 = no history base resolved the known
   anchor, 4 = a listed base answers for a different chain_id, 1 = usage or
   ledger problem. Nothing has been signed: do not unlock, do not run 7c;
   wait and re-run 7b.5. If the precondition line fails, advance the host
   checkout (the deploy's host-advance step, or
   `scripts/advance-host-checkout.sh` on the host) or remove the stale
   variable at its source — never add an override to make it pass (an
   override may only confirm the profile value). The jq floor is enforced
   by the check itself (exit 2 below 1.6).
   `scripts/cycle-transition.sh --print-only` prints this unit resolved.

   **7c — sign + broadcast.** Unlock the **separate** mainnet keystore, then
   sign (only after 7b.5 printed `REACHABLE`). `bin/safe-broadcast` gate 1 and gate 4 both REFUSE without
   `--testnet-tx-id` / `--dry-run-log`.

   **この code block は 2 人で分担する**: **1 行目
   (`HOME=~/.metal-fy-proton proton key:unlock`) は operator@TTY** — 32 文字 password を打つのは operator。**2 行目以降
   (`sign-anchor-event.sh` の呼び出し) は AI@Mac** — ただし実行は下の
   「per-invocation 認可の手順」が済んでから。
   unlock の **目視するもの**: エラーなくシェルに戻ること。
   **失敗したら**: 以降の署名が keystore locked で止まるだけで、何も壊れない
   (やり直せる)。**Dashlane entry 名はこの repo には書かない** — ピング時に
   AI が添える。
   ```sh
   HOME=~/.metal-fy-proton proton key:unlock
   FY_CONFIG_DIR=$HOME/.fy-mainnet-broadcast/config HOME=~/.metal-fy-proton \
     bash scripts/sign-anchor-event.sh --chain=mainnet-a \
       --anchor-source=public/api/anchor-source.json \
       --testnet-tx-id=<rehearsal tx id> \
       --dry-run-log=/tmp/fya-mainnet-dryrun.json
   ```
   `FY_CONFIG_DIR` holds `xpr-account` / `anchor-sink` / `xpr-quantity`.
   **Keep `FY_CONFIG_DIR=…` before `HOME=…`** on every one of these
   env-prefix lines. Mechanism (measured 2026-07-31): **zsh** — the
   operator's login shell — applies command-prefix assignments left to
   right and makes each visible to the *next* assignment's expansion, so
   `HOME=~/.metal-fy-proton` first makes `$HOME` in
   `FY_CONFIG_DIR=$HOME/…` resolve to the keystore dir, silently pointing
   the config dir inside the keystore. bash expands the prefix assignments
   of a *simple* command against the pre-command environment, so both
   orders happen to work there — but not inside a pipeline, where bash
   forks a subshell and behaves like zsh. Write the order that is correct
   in every shell.
   One more `FY_CONFIG_DIR` pitfall, distinct from the ordering rule
   above: **do not quote the tilde.** `FY_CONFIG_DIR="~/.fy-mainnet-broadcast/config"`
   does not expand at all — a quoted `~` is left as a literal `~` by the
   shell — producing a path that doesn't exist and fails with **exit 3**
   (config dir not readable). With the ordering rule above followed and
   no quotes, `~` and `$HOME` resolve identically (measured 2026-08-04,
   all four zsh/bash × correct/incorrect-order permutations) — there is
   no separate tilde-vs-`$HOME` divergence to worry about. For
   robustness, an **absolute path** (e.g.
   `FY_CONFIG_DIR=/Users/<user>/.fy-mainnet-broadcast/config`) is still
   the simplest choice: it sidesteps both the quoting pitfall above and
   the ordering rule entirely.
   Routed through `bin/safe-broadcast`'s 4-gate discipline (testnet-first,
   per-invocation operator authorization naming chain / actor / permission
   / action / memo / quantity, chain-info verify, dry-run exhaustion — PRIME
   DIRECTIVE). Testnet and mainnet are **two distinct keystores**
   (`HOME=~/.metal-fy-proton-test` / `HOME=~/.metal-fy-proton`) — never
   interchangeable (Constitution §3.5).

   **per-invocation 認可の手順 (当日 operator が実際にやること)。** 上の段落は
   認可の**性質**の説明であって手順ではない。当日の唯一の不可逆な承認なので、
   ここで手順として書き下す:

   - **AI が提示するもの (5 点)** — いずれも `bin/safe-broadcast:567-577` の
     `BROADCAST CONFIRMATION` ブロックと 7b の出力から取る、**AI の要約では
     なく実出力**: ① `chain:` (= `mainnet-a`)、② `token binding:`
     (`chain=…, tx_sha256=…` — R16 の content binding)、③ `action count:` と
     `actions:` 各行の `memo=…` (**anchor は 4 本**)、④ 同じ行の
     `authorization=<actor>@<permission>`、⑤ 7b が印字した
     `<actor>@<permission> → <to>  <quantity>` の `quantity`
     (`scripts/preview-cycle-anchor-broadcast.sh:340`)。
     加えて `MAINNET gates verified: testnet-tx-id=… / dry-run-log=…` の 2 行。
   - **operator が照合するもの** — ① memo prefix が**その日刻む cycle のもの**
     であること (day-of value sheet の `<N+1>`。記入例の 2026-10-07 なら cycle 6 側)、
     ② `chain` が `mainnet-a` であること、③ `quantity` が想定どおりであること、
     ④ `tx_sha256` が空 (`<unbound-legacy>`) でないこと。
     **1 つでも読めない・違って見えたら照合は不成立** — 「たぶん合っている」で
     通さない。
   - **認可の返答形式** — chat で、提示された
     `{chain, actor, permission, action, memo, quantity}` を**自分の言葉で
     復唱した上で**「認可する」と書く。「OK」「はい」だけでは認可にしない
     (復唱が PRIME DIRECTIVE gate 2 の実体)。認可が成立して初めて AI は
     上の `sign-anchor-event.sh` を実行してよい。実行すると
     `bin/safe-broadcast` が対話プロンプトを出し、確認フレーズは
     **`BROADCAST mainnet-a` の完全一致**である (`:579-584`)。
   - **中止の言い方** — chat で「**中止**」または「**止めて**」の一言で足りる。
     理由の説明は要らないし、求められない。プロンプトまで進んでいた場合は
     **確認フレーズ以外の任意の入力**が abort になる (exit 5)。中止で失われる
     のは 7b の dry-run log だけで、作り直せる。**broadcast は起きていない。**
     迷ったら中止が既定。
   `sign-anchor-event.sh` also accepts `--output=<path>`; left unset, its
   stdout is additionally saved to a default path
   `/tmp/fya-<testnet|mainnet>-sign-output.json` — `/tmp/fya-mainnet-sign-output.json`
   for this mainnet invocation. That fragment is produced **on the Mac**
   and must reach the host before step 8 runs, where it becomes step 8's
   `--input=` value below — step 7.5, immediately following, is that
   transfer.
   **後操作 (operator@TTY) — mainnet keystore を re-lock する。**
   `HOME=~/.metal-fy-proton proton key:lock`。

   - **打つ人**: **operator 自身** (password を打つため)。
   - **目視するもの**: プロンプト `Enter 32 character password (leave empty to
     create new)` に、**unlock と同じ 32 文字を入れる**。
   - **絶対にやらないこと**: **空 Enter**。既存 password でロックする代わりに
     **新しい password を作成してしまう** — 次回の unlock が通らなくなる。
   - **なぜこれをやるか**: mainnet keystore を unlock したまま放置しない
     (Constitution §3.5)。

   **後操作 2 (operator@TTY) — testnet keystore も re-lock する。**
   `HOME=~/.metal-fy-proton-test proton key:lock`。

   - **いつ**: **7a の直後が既定** (testnet keystore の最後の利用は 7a。
     7a の「後操作」)。7a の直後に済ませていれば、ここでは locked であることを
     確かめるだけ。済んでいなければここで必ず閉じる (遅くとも 7c 末尾)。
   - **打つ人**: **operator 自身** (password を打つため)。7a の ② で開けた
     keystore がまだ開いていれば、mainnet と同じ扱いで閉じる。
   - **目視するもの**: ⑤ と同じプロンプト `Enter 32 character password (leave
     empty to create new)`。ただし入れるのは **testnet keystore の 32 文字**で、
     ⑤ で打った mainnet のものではない (keystore は HOME ごと別、
     Constitution §3.5)。**プロンプト文字列が同一なので、直前に打った mainnet
     の password をそのまま繰り返す取り違えがここで起きうる。**
   - **空 Enter は同じく禁止** — 新しい password を作ってしまい、次回の 7a が
     通らなくなる。
   - **これは独立した 6 番目の operator 操作**であって mainnet re-lock の
     付随事項ではない。完了 checklist ⑤ が「**片方だけ re-lock して終える
     取りこぼしがいちばん起きやすい**」と名指ししているのがこの 1 手。
     以前はこの要求が mainnet 側 bullet の末尾 1 節に埋もれており、
     冒頭の operator@TTY 列挙からも落ちていた (2026-08-18 K-7)。

7.5. **Mac → host — scp the signing fragment.** Step 7c's
   `sign-anchor-event.sh` output landed on the **Mac** (its default
   `--output=` path, `/tmp/fya-mainnet-sign-output.json`); step 8's
   `gen-anchor-receipt.sh --input=` runs on the **host** and needs that
   same JSON there. This used to be a clause buried in step 7c's closing
   prose rather than its own line item — worth calling out on its own,
   since it is a distinct host-crossing action with its own failure modes
   (wrong destination path, a stale leftover from a prior cycle, or a
   permission the `deploy` user can't read):
   ```sh
   scp -i ~/.ssh/<your_validator_host_key> \
     /tmp/fya-mainnet-sign-output.json \
     "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}:/home/deploy/.fya-sign-output.json"
   ssh -i ~/.ssh/<your_validator_host_key> \
     "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
     'chmod 644 /home/deploy/.fya-sign-output.json'
   ```
   The `chmod` is defensive: the `scp` connects as `root` (no
   `VALIDATOR_HOST_USER` override here), and step 8's
   `gen-anchor-receipt.sh` runs as `sudo -u deploy` — a restrictive root
   umask on the target host could otherwise leave the file unreadable to
   `deploy` and step 8 would fail on a file that is sitting right there.
   Do this before step 8; its `--input=` value below is exactly this
   destination path.

8. **host — `gen-anchor-receipt.sh` (7-gate verify) + `append-anchor-history.sh`**
   independently re-fetch and verify the just-broadcast tx, then append the
   receipt to `anchor-history.jsonl`:
   ```sh
   bash scripts/gen-anchor-receipt.sh \
     --input=/home/deploy/.fya-sign-output.json \
     --anchor-source=public/api/anchor-source.json \
     --trigger=cyclestart \
     --prev-anchor-tx-id=<tx_id of the immediately preceding anchor event>
   FY_LIVE=1 bash scripts/append-anchor-history.sh \
     --receipt=public/api/anchor-receipt.json \
     --event-type=cyclestart
   ```
   **`FY_LIVE=1` is required on `append-anchor-history.sh`** (C3 rollout,
   2026-08-06). The append itself is deliberately NOT gated — it happens
   either way, because a forgotten opt-in must never cost a line in an
   append-only ledger derived from a one-shot receipt. What IS gated is the
   automatic R18 archive push described in step 8.5: without `FY_LIVE=1`
   both pushes are announced-and-skipped (`DEFERRED: R18 publish …`) and the
   exact manual push commands are printed instead. `gen-anchor-receipt.sh`
   needs no opt-in.
   **Gate 1 can fail transiently right after the broadcast.** Hyperion
   indexes a tx some tens of seconds behind the chain, and
   `gen-anchor-receipt.sh` queries each history base of the selected chain
   profile once, in profile order (Hyperion `get_actions` → Hyperion
   `get_transaction` → `/v1/history/get_transaction`, via
   `scripts/lib/anchor-history-read.sh`; no wait, no retry) — so it exits 3
   with `gate 1 — tx_id … not resolvable` even though the tx is on-chain.
   (Step 7b.5 proved the bases answer; it cannot prove the NEW tx is already
   indexed — that is this transient.) Observed on the 2026-09-01 testnet
   rehearsal: both v2 and v1 resolved the same tx about a minute later.
   **If step 7c exited 0 — `sign-anchor-event.sh` wrote its JSON receipt
   fragment with a 64-hex `tx_id` to stdout — the tx exists: wait about a
   minute and re-run THIS step 8 only. Never re-run 7c — that is a second
   inscription of the same cycle, and no gate refuses it.** (Only the
   testnet rehearsal script prints a `BROADCAST OK` banner; 7c does not.)
   `--prev-anchor-tx-id=` is **not derived from anything else** —
   `gen-anchor-receipt.sh` only reads it from this flag (or treats it as
   `null` if omitted); get the value from the host's own
   `anchor-history.jsonl` last line:
   `tail -n 1 public/api/anchor-history.jsonl | jq -r '.tx_id'`. Omitting
   it (or passing the wrong value) writes `prev_anchor_tx_id: null` (or a
   stale tx_id) into the receipt, which then fails
   `append-anchor-history.sh` invariant 6
   (`receipt.prev_anchor_tx_id != last history tx_id`) — genesis (empty
   history) is the only case where `null` is correct.
   `--input=` is step 7c's `sign-anchor-event.sh` stdout, saved as JSON
   and transferred to this path by step 7.5. Both `--input=` and
   `--anchor-source=` are required (usage error, exit 1, without them), as
   is `append-anchor-history.sh`'s `--receipt=`. At a cycle transition the
   event type is `cyclestart` on both scripts — `--trigger=cyclestart`
   here, `--event-type=cyclestart` there.

8.5. **host — push the two canonical flat files.** Two, not four:
   ```sh
   bash scripts/push-to-web-host.sh anchor-receipt.json
   bash scripts/push-to-web-host.sh anchor-history.jsonl
   ```
   These are the CURRENT/canonical copies `gen-anchor-receipt.sh` and
   `append-anchor-history.sh` just wrote locally in step 8. Skip this and
   the public `/api/anchor-receipt.json` and `/api/anchor-history.jsonl`
   keep serving the *previous* cycle's content even though the on-chain
   anchor already succeeded — step 9's Phase 1 only polls
   `anchor-source.json` freshness, so it will **not** catch a missed push
   here. `anchor-source.json` itself is not part of this step: it is
   git-deploy owned (committed in step 6), never pushed via this script.

   The other two publish targets step 8 also produces — the R18
   per-anchor archive copies (`archive/anchor-source-<dag_root>.json`,
   `archive/anchor-receipt-<tx_id>.json`) — are **not** a manual action
   here. As of 2026-08-06 (`77fd09d`), `append-anchor-history.sh` pushes
   both of them itself, automatically, immediately after its append
   succeeds (its "R18 publication" block). That push is best-effort — a
   failure is reported loudly (stderr + a `notify.sh high` alert) but
   never fails the append, and step 8's own exit code says nothing about
   whether the archive push succeeded. If stderr or an alert shows "R18
   publish FAILED" / "R18 publish skipped", re-run the printed manual
   retry command
   (`push-to-web-host.sh archive/anchor-source-<dag_root>.json` /
   `archive/anchor-receipt-<tx_id>.json`). `FYD_PUBLISH_ARCHIVES=0`
   disables the automatic push entirely — not used at a routine cycle
   transition.

9. **host —**
   ```sh
   FY_LIVE=1 bash scripts/resume-after-cycle-start.sh --apply
   ```
   `FY_LIVE=1` is required; without it the script refuses with exit 6 before
   Phase 1 and writes nothing (see the `resume-after-cycle-start.sh` section
   above).
   Phase 1 verify (6 checks: prior-state read, chain query, idempotency,
   endTime-in-future, `anchor-source.json` freshness poll, identity
   signature verify) → Phase 2 atomic state write → Phase 3 report.
   **No broadcast, no explorer URL** here — the anchor tx confirmation
   belongs to step 7; this script only records cycle-gate approval state.

10. **Mac — archive the new anchor's legacy-chain record.** Added
   2026-09-30. Anchors are `eosio.token` transfer memos — history, not chain
   state — and after the A-Chain moves to PulseVM the old chain's history
   may stop being served (`docs/A_CHAIN_PULSEVM_CUTOVER.md`). While it is
   still served, store today's anchor's raw history and block responses in
   the published, git-tracked archive `public/api/legacy-a-chain/`:
   ```sh
   curl -fsS 'https://metal.freedom-yield.com/api/anchor-history.jsonl' -o /tmp/fya-anchor-history.jsonl
   bash scripts/archive-legacy-anchors.sh --from-file=/tmp/fya-anchor-history.jsonl
   bash scripts/verify-legacy-anchor-archive.sh --history=/tmp/fya-anchor-history.jsonl
   git add public/api/legacy-a-chain/ && git diff --cached --name-status
   git commit -m 'data(legacy-a-chain): archive the cycle <N+1> anchor while the legacy chain is served'
   git push && gh run watch
   ```
   It reads the **published** ledger (so it needs step 8.5) and runs after
   step 9 so its deploy comes after the gate-state write. Read-only requests
   only; anchors already archived are skipped with no request. It reads the
   legacy profile **by name** (`xpr-mainnet`), so it keeps pointing at the
   old chain after a cutover. Done = archiver exit 0 **and** the verifier's
   `VERIFIED <n> anchor(s)` with n one higher than before; the staged set is
   exactly the new `<tx_id>.json` + `manifest.json`. Archiver exit 3 = a
   record could not be fetched this time (others kept) — re-run later, it
   resumes; exit 4/5 = fail closed (a recorded file disagrees with what the
   chain serves now, or the chain_id differs) — stop and report, never
   delete a file to make it pass. None of this touches the anchor itself.

AI reads back step 7's tx id and reports the explorer URL to the operator
for visual confirmation (PRIME DIRECTIVE gate 2's per-invocation
authorization happens before that step runs, not after). Step 0 is the
operator's own wallet action (no script, no gate). Steps 1-3 and 8-9 pass
the always-green `cycle-artifact-write` gate; no cycle-gate approval is
needed for them.

### 完了判定 checklist (この 5 点が揃ったら当日終了)

**`scripts/cycle-transition.sh --status` が全 green でも「終わった」ことには
ならない。** 16 実行単位のうち 7 つ (7a / 7b / 7b.5 / {7.5, 8, 8.5} / 10) はどの事後条件にも
入っておらず、7.5 / 8 / 8.5 を丸ごと飛ばしても `--status` は緑を返しうる
(その場合 on-chain には刻まれているのに公開 `anchor-receipt.json` /
`anchor-history.jsonl` は前 cycle を配り続ける)。また 4b の registry 編集を
**部分的に**やり忘れた場合も `--status` は気づかない。だから目視で 5 点を取る:

- **① `--status` が全 green** — `bash scripts/cycle-transition.sh --status
  --expect-cycle=<N>` (記入例の 2026-10-07 なら `5`)。必要条件であって十分条件では
  ないので、これ**だけ**では終了判定にしない。
- **② 公開 `cycle-history.jsonl` が 1 行増えている** — step 3 の前に控えた
  基準行数 +1 であること (記入例の 2026-10-07 なら 4 → **5**)。かつ増えた行の
  `incidents_in_cycle_ids` が step 2.5 の entry を含むこと (step 2.5 を
  実行した cycle のみ)。
- **③ explorer で anchor tx を目視** — step 7 の tx id を AI が読み返し、
  explorer URL 上で確認する。
- **④ identity 署名が検証できる** — 公開 `identity.json` / `.sig` / pubkey の
  3 点で `ssh-keygen -Y verify` が通ること
  (`docs/IDENTITY_VERIFICATION.md` の手順)。かつ
  `bash scripts/check-identity-pins.sh --mode=repo` が **exit 0**
  **かつ出力に `OBSOLETE-BASELINE` の行が無いこと** (= step 2.5 の一時 baseline
  entry が 4b で消えていることの確認)。**exit code だけでは兼ねられない** —
  削除を忘れても exit は 0 のままで、差が出るのは出力行だけ (2026-08-18 実測)。
- **⑤ keystore が 2 つとも locked** — testnet (7a) と mainnet (7c) の両方。
  片方だけ re-lock して終える取りこぼしがいちばん起きやすい。

公開面の 3 ファイル (`anchor-receipt.json` / `anchor-history.jsonl` /
`cycle-history.jsonl`) が**当 cycle の内容を配っていること**を curl で 1 度
確かめると、②と③を同時に満たせる。

## Emergency fallback (= AI unavailable)

If the operator must drive the transition without AI assistance:

1. Operator does the wallet flow + Mac `gen-identity.sh` + commit + push as
   usual, and runs the anchor pipeline manually (testnet-first; mainnet only
   with all four PRIME DIRECTIVE gates satisfied).
2. After `git push`, wait for the GitHub Actions Deploy workflow to finish.
3. SSH the validator host and run:

   ```sh
   ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
       'sudo -u deploy env FY_LIVE=1 bash /home/deploy/metal.freedom-yield.com/scripts/resume-after-cycle-start.sh --apply'
   ```

Phase 1 polling tolerates uncertain deploy timing: it polls up to 10 minutes
for `anchor-source.json` to refresh before failing. To sanity-check first,
substitute `--dry-run` for `--apply`.

## Script freeze around a rehearsed transition

Once a testnet rehearsal (`scripts/run-testnet-rehearsal.sh`) has been run
against a specific upcoming cycle transition, any change to a script that
`docs/cycle-transition-steps.json` names as one of that transition's
execution units (its `steps[].scripts` entries — e.g.
`run-testnet-rehearsal.sh`, `preview-cycle-anchor-broadcast.sh`,
`sign-anchor-event.sh`, `gen-anchor-source.sh`,
`operator-local/gen-identity.sh`, `uptime-history.sh`,
`gen-cycle-history.sh`, `push-to-web-host.sh`, `gen-anchor-receipt.sh`,
`append-anchor-history.sh`, `resume-after-cycle-start.sh`,
`operator-local/commit-anchor-source.sh`) is permitted only together with a
re-rehearsal of the affected execution unit(s).

Rationale: a rehearsal's value — whether as PRIME DIRECTIVE gate-1 evidence
for unit 7a specifically, or as evidence the pipeline shape has not silently
drifted for the other units — depends on the rehearsed code being the code
that actually runs on the day. `docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`'s
"Scope: what a rehearsal run actually proves" applies the same principle to
a single run's staleness window; this section extends it to the freeze
window between a rehearsal and the transition it gates.

The freeze ALSO covers the enforcement / shared-library scripts the named
execution units call, even where `docs/cycle-transition-steps.json`'s own
`steps[].scripts` entries do not name them (that file has known gaps: unit
1's entry is `[]` even though it reads `node-info.sh`'s output, unit 7.5's
entry is `[]` even though it is an scp round-trip, and unit 7c's entry names
only `sign-anchor-event.sh`, not the `bin/safe-broadcast` wrapper it always
invokes). Specifically: `bin/safe-broadcast`, `scripts/lib/side-effects.sh`,
`scripts/cycle-gate.sh`, and `scripts/node-info.sh` are in scope for the same
freeze. This matters concretely: `bin/safe-broadcast`'s gate 1 / gate 4
hardening is the one piece of code a testnet rehearsal cannot exercise at all
(mainnet-only gates — see `docs/REHEARSAL_2026-09-01.md` F1), so its "0
commits since the last hardening pass" is exactly the fact the freeze exists
to protect; leaving it outside the freeze's named scope would have made that
protection accidental rather than structural.

The freeze does not block work outside this scope (e.g.
`docs/STRATEGIC_TARGET_ALIGNMENT.md`, or tooling neither
`docs/cycle-transition-steps.json` nor the paragraph above names).

This is the canonical statement of the rule — both the base scope
(`steps[].scripts`) and the extension above. For the specific freeze window
and rehearsal it currently gates, see `docs/REHEARSAL_2026-09-01.md` §5 —
that section records the dates only and defers to this one for the rule
itself.

## Rollback

Independent rollback levers, in increasing severity:

1. **Disable approval enforcement temporarily**:
   `rm /var/lib/freedom-yield/cycle-gate-state.json`. `cycle-gate.sh` returns
   green for every consultation until the next
   `FY_LIVE=1 resume-after-cycle-start.sh --apply` recreates the file (the
   opt-in is required — without it the script refuses with exit 6 and the
   gate stays disabled).
2. **Kill switch — freeze all gated consumers. ⚠ USE PROHIBITED for routine
   cycle transitions** (including cycle-4, 2026-08-04):
   `chmod -x /home/deploy/metal.freedom-yield.com/scripts/cycle-gate.sh`.
   This does **not** mean "gate disabled" — the opposite. Every consumer
   detects the non-executable gate and **fails closed**: the five
   `cycle-artifact-write` scripts (`gen-cycle-history.sh`,
   `uptime-history.sh` Job B, `node-info.sh`, `gen-evidence.sh`,
   `gen-renewal-ics.sh`) skip their feed writes and `daily-status.sh` skips
   its digest push (each `exit 0`; `uptime-history.sh` first completes its
   ungated Job A — the daily snapshot append to the host-local master
   JSONL — and skips both public uptime feeds), while `check-anomalies.sh`
   keeps its non-cycle checks running and suppresses only the cycle-related
   alerts. This **stops public feed generation**
   (`validator.json` / `cycle-history` / `evidence` / `renewal-ics` /
   `uptime`) until reversed with `chmod +x`; it does *not* fall back to
   pre-gate "proceed" behavior — and since `cycle-artifact-write` is
   already unconditionally green (see the `cycle-gate.sh` table above),
   lever 2 buys nothing for that side-effect type and only breaks
   recording. If the goal is to relax approval enforcement while keeping
   feeds flowing, use **lever 1** (`rm` the state file) instead — that
   returns green for every side-effect type without touching the
   executable bit.
3. **Remove the design entirely**: delete `scripts/cycle-gate.sh` and
   `scripts/resume-after-cycle-start.sh` and drop the consultation blocks
   from the consumer scripts. Use only if a fundamental design issue is
   found.

The state file is regenerable from any chain-visible cycle, so accidental
deletion is not a data-loss event.

## Test coverage

`tests/cycle-gate/run-tests.sh` exercises the deterministic state-machine
behavior (green / deferred / fail-closed per side-effect type, idempotent
resume skip, resume against unreachable RPC) using a Python HTTP mock for
metalgo RPC + web-host responses. The repo-wide suite runs via
`bash tests/run-all-tests.sh`.

`tests/cycle-transition-steps/test-cycle-transition-steps.sh` guards the
**runbook itself** against silent drift from the pipeline it describes: it
checks every step in `docs/cycle-transition-steps.json` (the hand-maintained
ground truth for the 13 execution units a transition actually runs) has a
literal mention in both this doc's model α runbook and
`docs/VALIDATOR_RENEWAL.md`'s day-of list / emergency fallback — the
2026-08-06 gap that motivated it (steps 7.5 and 8.5 existing in the real
pipeline but nowhere in either doc) would have failed this test on sight.
Add a step to the pipeline → add it to the JSON and both docs in the same
commit, or this test goes red in CI.

Not covered here (covered elsewhere):

- identity.json signature verification against a real key — covered by the
  operator-Mac `gen-identity.sh` self-verify at signing time.
- A-chain broadcast — covered by the anchor pipeline's own testnet-first
  rehearsals and `gen-anchor-receipt.sh` 7-gate verification.

## Constitution alignment

- **§2 #1 validator health**: `cycle-gate.sh` hits metalgo RPC once per
  consultation (= same query as the existing 5-minute anomaly tick, no
  incremental load). `resume-after-cycle-start.sh` runs at most once per
  cycle.
- **§3.3**: neither script reads or writes any SECRET-class data.
- **§5 / PRIME DIRECTIVE**: the gate has no broadcast path. The anchor
  pipeline's mainnet broadcast requires testnet-first success, per-invocation
  operator authorization, pre-flight chain verification, and exhausted
  dry-run options — enforced by `bin/safe-broadcast` and the tiered
  broadcast-enforcement stack.

## Related

- `docs/ANCHOR_SOURCE.md` — the 3-branch anchor-source contract (single DAG
  source of truth).
- `docs/MERKLE_DAG_SPEC.md` — canonical hashing spec (`jq -cS`; the trailing
  newline (`0x0a`) that `jq` appends is included in the hashed bytes, per §2.1).
- `docs/IDENTITY_VERIFICATION.md` — the public seven-step verification
  recipe.
- `docs/audits/constitution-2026-07-04-design-stocktake.md` — the design
  stocktake that drove the v1 → v2 collapse.
- `docs/VALIDATOR_RENEWAL.md` — operator-facing renewal SOP.
