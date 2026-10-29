# Constitution Audit — 2026-07-03T11:58 (JST)

## Summary

- **Overall**: 🟡 (D1 PRIME DIRECTIVE core = ✅ pass; C2 review surfaces 3 defense-in-depth gaps, no active violation)
- **Range**: `HEAD` (`51430b12376a2ed0bb832b0867289268d208f5cb`) — full repo current state
- **Scope**: `prime-directive` → D1 + C2 only
- **Review preset**: `medium`
- **Violations**: D-series 0 件 (🔴 critical 0) / C-series 0 hard-violation, 3 🟡 findings
- **Auditor**: constitution-auditor agent

> 🔴 highlight: **なし**. broadcast-capable path に 現行 の unauthorized-broadcast 経路・fail-open 分岐 は 検出 されず. 全 sanctioned broadcast は 単一 choke point (`bin/safe-broadcast`) を 経由 する 構造 が 実 evidence で 確認 された.

## Constitution dimensions (D-series)

### D1 — PRIME DIRECTIVE 4 gate consistency + enforcement DEPLOYED

**Status**: ✅ pass (core) / ⚠ partial (gate 1/3/4 の 機械的 verify 深度 は C2 側 finding 参照)

**Method**: (1) `docs/CONSTITUTION.md` PRIME DIRECTIVE block を 実 Read し 4 gate spec を 把握、(2) `CLAUDE.md` summary と cross-diff、(3) tier-1 (`scripts/broadcast-guard.sh` + `.claude/settings.json` PreToolUse hook) と tier-2 (`bin/safe-broadcast`) を 実 Read、(4) 両 test suite を 実 invoke して PASS 数 を 実測、(5) 全 tracked file に broadcast-shape grep を かけ 実 invocation site を 網羅列挙.

**Evidence — 4 gate の doc spec**:
- `docs/CONSTITUTION.md:17-20`: gate 1 (identical shape testnet-first + operator observed) / gate 2 (per-invocation authz naming `{chain, actor, permission, action, memo, quantity}`) / gate 3 (pre-flight `chain:get` verified to match authorized chain) / gate 4 (`--dry-run`/offline-sign exhausted + composed tx JSON reviewed).
- `docs/CONSTITUTION.md:26`: 「Any script … that introduces a broadcast pathway MUST embed … `# PRIME_DIRECTIVE: TESTNET-FIRST` marker and MUST default to a testnet endpoint」.
- `CLAUDE.md:9`: 同 4 gate を 要約 (testnet-first / per-invocation authz / pre-flight `chain:get` / `--dry-run` exhaustion) — Constitution と 文言 整合.

**Evidence — tier-1 (PreToolUse hook + broadcast-guard + audit log) DEPLOYED + fail-closed**:
- `.claude/settings.json:5-14`: PreToolUse matcher `"Bash"` → `bash "$CLAUDE_PROJECT_DIR/scripts/broadcast-guard.sh"` に wire 済 (hook 実 配線 確認).
- `scripts/broadcast-guard.sh:53-56`: jq 不在 時 `exit 1` (fail-closed) — 「a broken guard MUST NOT default to allow」.
- `scripts/broadcast-guard.sh:75-86`: BROADCAST_PATTERNS 8 本 (`proton action`, `proton transaction(:push)`, `cleos … push_(action|transaction)`, `curl|wget … push_transaction`, `… issueTx`, `… eth_sendRawTransaction`, `… /ext/bc/[XPC]`, `metalgo … IssueTx`).
- `scripts/broadcast-guard.sh:103-158`: token 不在/expired = `exit 1` + PRIME_DIRECTIVE_VIOLATION message (fail-closed).
- `scripts/broadcast-guard.sh:160-181`: allow 時 audit log append (tier-4 cross-check 用).

**Evidence — tier-2 (safe-broadcast wrapper) DEPLOYED + 4 gate**:
- `bin/safe-broadcast:2`: 「the ONLY sanctioned broadcast pathway on this repo」.
- gate 1 `bin/safe-broadcast:128-152`: mainnet で `--testnet-tx-id` 必須 + 64hex 形式 check + testnet Hyperion `get_transaction` で 実在 resolve、resolve 不能 = `exit 3`.
- gate 2 `bin/safe-broadcast:165-191`: operator token 必須 + freshness (interactive 300s / non-interactive 60s tight TTL)、失効 = `exit 3`.
- gate 3 `bin/safe-broadcast:193-208`: `proton chain:set` + `proton chain:info` preflight、応答 異常 = `exit 4`.
- gate 4 `bin/safe-broadcast:154-162`: mainnet で `--dry-run-log` 必須 + 非空 check (`-s`)、欠如 = `exit 3`.
- interactive confirm `bin/safe-broadcast:211-229`: `BROADCAST <chain>` phrase 一致 必須、不一致 = `exit 5`.

**Evidence — single choke point (bypass path 不在)**:
- 実 `proton (transaction:push|action)` 呼び出し site を 全 tracked file grep した 結果、executable な mainnet-capable broadcast 呼び出し は `bin/safe-broadcast:255,261` (`PROTON_ARGS=(transaction:push …)`) の 1 箇所 のみ.
- `scripts/sign-anchor-event.sh`: 直接 `proton` invocation なし、`bin/safe-broadcast` に delegate (`sign-anchor-event.sh:311-323`). header marker (`sign-anchor-event.sh:3-9`) に `# CHAIN:` + `# PRIME_DIRECTIVE: TESTNET-FIRST` embed 済.
- `scripts/run-testnet-rehearsal.sh`: broadcast は `bin/safe-broadcast --chain=testnet-a` に delegate (`run-testnet-rehearsal.sh:182`)、直接 proton は `chain:set`/`chain:info` の read-only preflight のみ. header marker embed 済 (`run-testnet-rehearsal.sh:3-11`).
- `scripts/install-tier1-hook.sh:134` + `scripts/operator-local/contract/metalfreedom-anchor.spec.md:232` の `proton …` 出現 は それぞれ test 入力 string / doc spec で、実 invocation では ない.

**Evidence — test suite 実測 (fabrication なし、実 invoke output)**:
- `tests/broadcast-guard/test-broadcast-guard.sh`: **PASS=25 FAIL=0** (block 13 shape + allow 8 benign + token override 2 + audit-log 2-line + expired-token block). 実 invoke exit 0.
- `tests/safe-broadcast/test-safe-broadcast.sh`: **PASS=15 FAIL=0** (arg validation 7 + gate2 token 3 + gate1 mainnet 4 + audit-log-empty-on-refusal 1). 実 invoke exit 0.
- 合計 **40 assertion PASS / 0 FAIL** 実測.

**Finding**: D1 core = pass. 4 gate は Constitution / CLAUDE.md / broadcast-guard / safe-broadcast の 4 面 で 整合、tier-1 + tier-2 とも DEPLOYED + fail-closed、sanctioned broadcast は `bin/safe-broadcast` 単一 choke point を 経由. gate 1/3/4 の 機械的 verify 深度 に 残 gap が ある が それ は C2 側 で 分離 記載 (spec 違反 では なく defense-in-depth 弱点).

**Suggested fix (指摘 のみ、agent は 実装 しない)**: null (D1 core pass).

## Simplified review (C-series)

### C2 — Broadcast-capable code / script review (medium depth)

**Status**: ⚠ partial — hard violation 0、defense-in-depth 弱点 3 件 (🟡).

**Method**: 単一 broadcast choke point (`bin/safe-broadcast`) + tier-1 guard (`scripts/broadcast-guard.sh`) を 実 Read し、bypass 経路 / fail-open 分岐 / authorization skip / gate の 実効性 を review.

**Evidence + Finding**:

**C2-1 (🟡) — tier-1 guard の token override は 4 gate を 検証 しない (coarse authorization)**
- `scripts/broadcast-guard.sh:101-158`: broadcast shape 検出 後、要求 する のは token file の 存在 + freshness (= Constitution gate 2 相当) のみ. gate 1 (testnet-first) / gate 3 (chain match) / gate 4 (dry-run) の check は tier-1 に 存在 しない.
- test `tests/broadcast-guard/test-broadcast-guard.sh` の case 「override: proton transaction:push WITH fresh token → allow (rc=0)」 が これ を 実証: fresh token が あれば 生 の `proton transaction:push` (safe-broadcast 非経由) が tier-1 を 通過 する.
- 帰結: 4 gate 全 enforcement は tier-2 `bin/safe-broadcast` に のみ 存在 し、tier-2 は caller の opt-in. 生 の direct broadcast + fresh token の 組合せ は gate 1/3/4 を 機械的 に skip し得る.
- 分類 = 現行 violation では ない (sanctioned script は 全 tier-2 経由、memory `project_broadcast_enforcement_gate_plan.md` で tier-3 endpoint 隔離 + tier-4 cron cross-check が queue 済 = compensating control 予定). severity 🟡: この gap は 段3/段4 未 deploy の 間 は human/AI discipline に 依存.

**C2-2 (🟡) — gate 1 は testnet-tx-id の 実在 のみ verify、mainnet tx と の shape 一致 は 未 検証**
- `bin/safe-broadcast:138-148`: `--testnet-tx-id` を testnet Hyperion `get_transaction` で resolve し `.id` 一致 を 確認 する だけ. broadcast しようと する mainnet `--tx` の action 構成 / memo scheme と、その testnet tx の shape が 「identical」 (Constitution gate 1 の 要件) か の 比較 は しない.
- 帰結: 「identical command shape が testnet で 成功 済」 は operator の assertion に 依存、機械的 に は 「その tx-id が testnet に 存在 する」 まで しか 保証 しない (別 shape の 過去 testnet tx-id を 流用 する 余地).
- severity 🟡: gate 1 の 実効性 が 部分的.

**C2-3 (🟡) — gate 3 は chain liveness check であって chain-identity match では ない**
- `bin/safe-broadcast:202-208`: `proton chain:info` 出力 に `chain_id|server_version|head_block` の いずれ か の 文字列 が 含まれる か を grep する のみ. authorized chain の 期待 `chain_id` 値 と の 一致 比較 は して いない (`grep -nE 'chain_id|EXPECTED|MAINNET_CHAIN' bin/safe-broadcast` = presence-grep 1 hit のみ、value 比較 なし を 実測).
- 帰結: Constitution gate 3 「its output has been verified to match the authorized chain」 に 対し、実装 は 「plausible な chain 応答 が 返る」 まで の liveness 確認. proton-cli の chain:set が 想定外 の endpoint に mapping されて いる 場合 は 捕捉 できない.
- severity 🟡: gate 3 が identity-match でなく liveness-check の 段階.

**Evidence — positive (fail-open なし の 側面)**:
- tier-1: jq 不在 fail-closed (`broadcast-guard.sh:53`)、token 不在/失効 fail-closed (`:103-158`).
- tier-2: arg / actions array / chain 値 の baseline validation で 不正 は `exit 2/3/4` (`safe-broadcast:96-125`)、audit log pre/post 2-phase (`:231-274`)、broadcast 失敗 は `exit 6`.
- gate 4 は 非空 check のみ だが 少なくとも empty/欠如 は 弾く (`safe-broadcast:154-162`).

**Suggested fix (指摘 のみ、agent は 実装 しない)**:
- C2-1: 段3 (endpoint 隔離) + 段4 (cron cross-check) の deploy が 本 gap の 想定 compensating control. 併せて tier-1 guard で 「fresh token が あって も、`bin/safe-broadcast` 由来 の marker (例: env `FYD_SAFE_BROADCAST=1`) が ない 生 broadcast は block」 の 追加 検討 余地 (= 生 direct call を tier-1 で さらに 締める).
- C2-2: safe-broadcast gate 1 で testnet tx の action 構成 / memo prefix を fetch し、broadcast 対象 `--tx` の shape hash と 突合 する 検討 余地.
- C2-3: gate 3 で 期待 `chain_id` (mainnet-a / testnet-a それぞれ の 既知 値) を const 化 し `chain:info` の `chain_id` 値 と exact 比較 する 検討 余地.
- いずれ も mainnet T-H の hard blocker では なく、判断 は operator に 委ねる.

## Statistics

- Dimensions checked: 2 (D1 + C2)
- Passed: D1 core ✅ / C2 hard-violation 0
- Failed: 🔴 critical 0
- 🟡 findings: 3 (全 C2 = defense-in-depth 弱点、現行 violation では ない)
- N/A (out of scope): D2-D10, C1/C3-C12 (`--scope=prime-directive` により 対象外)
- Test assertions 実測: broadcast-guard 25/25 + safe-broadcast 15/15 = 40/40 PASS

## Auditor note

- Fabrication: 0 件 (全 finding は 実 Read / git grep / 実 test invoke output 付き。test PASS 数 は 実 invoke の summary 行 を 引用).
- mis-observation: 現時点 で 自己 検出 0 件.
- rubber-stamp: 0 件 (D1 を pass 断定 する 前 に tier-1/tier-2 実 Read + 両 suite 実 invoke + 全 broadcast site grep を 実施).
- 越権 実装: 0 件 (schema/script/doc 一切 未 touch、指摘 のみ).
- Numeric claim: 全 実測 (25 / 15 / 40 / 8 pattern は 実 grep・実 invoke 由来。「~」「約」 不使用).
- SECRET/CONFIDENTIAL: 本 review 中 に secret literal は 扱わず (D3/C1 は scope 外).
- Append-only: この report は 新 file (`docs/audits/constitution-2026-07-03T11-58-audit.md`)、既存 audit doc は 未 touch.

> **operator へ**: この report の 各 finding は、`superpowers:receiving-code-review` の 手続き に 従い technical rigor で 独立 verify して ください. performative agreement や blind implementation は 禁止. C2-1〜C2-3 は いずれ も 段3/段4 (endpoint 隔離 + cron cross-check) が queue 済 という前提 の 上 での defense-in-depth 弱点 であり、mainnet T-H の hard blocker では ありません. 疑問 の ある finding は `--review=thorough` で 再 監査 する か、agent に 追加 質問 で 深堀り して ください.
