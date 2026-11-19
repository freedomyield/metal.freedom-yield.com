# 公開 repo から刻印のアカウント名を外す — 実装の計画（2026-11-19 監督 F）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 例外の場所（検証のページ・legacy の生データ・期限つきの凍結の 4 本）の外の tracked のファイルとパスから 4 つの名前を外し、再び入った束を門で落とす。

**Architecture:** lane ごとに別の worktree・別の branch（触るファイルが重ならない）。名前の置き換えは手元の `names.local` を読む道具で行い、値を画面にも commit にも出さない。最後に新しい門 `scripts/check-account-name-scope.sh` を木の全体に当てて `OK` を見る。

**Tech Stack:** bash・git・perl（Digest::SHA）・jq。新しい依存は無し。

**Spec:** `docs/superpowers/specs/2026-11-19-anchor-name-out-of-public-repo-design.md`（§15 で承認済み）

## Global Constraints

- 名前の値は、どのファイル・commit の文・報告・画面にも書かない。役の名前だけ: 刻印・送り先・稽古の刻印・稽古の送り先（`names.local` の role は `mainnet-anchor`・`mainnet-sink`・`testnet-anchor`・`testnet-sink`）
- 文書の placeholder: `<anchor-account>`・`<anchor-sink>`・`<rehearsal-anchor-account>`・`<rehearsal-anchor-sink>`（設計書 §6.4）
- 偽の名前: `fakeanchor12`・`fakesink1`・`fakeanchtest`・`fakesinktest`（設計書 §9.2）
- 契約の仕様の新しいパス: `scripts/operator-local/contract/anchor-contract.spec.md`
- 門: `scripts/check-account-name-scope.sh`・定義 `config/account-name-scope.tsv`・試験 `tests/account-name-scope/test-account-name-scope.sh`。凍結の行の `until` は `2026-12-08`
- 触らない: `public/verify/`・`public/ja/verify/`・`public/api/legacy-a-chain/`・凍結の 4 本（設計書 §8）・`docs/CYCLE_GATE.md`・`bin/safe-broadcast`・`scripts/publish-guard.sh`・pre-push の PROTECTED の 5 ファイル・`.githooks/`
- 送信できる命令を打たない。外へ接続しない。履歴を書き換えない。push しない

## Review Focus

1. 記録の文書（W11）で、置き換え以外の 1 文字が変わる → 置き換えだけの commit で、`git diff --word-diff` の変更の語が全て placeholder であること
2. 手順書の proton の命令から `HOME=~/.metal-fy-proton`（`-test`）が消える → 直す前と後で `HOME=~/.metal-fy-proton` の出現の数が同じ
3. example を偽の名前にした後に schema に通らない・example を読む試験が赤になる → 全体の試験の PASS／FAIL の組が直す前（`9c16547`）と同じ
4. 門が値を出力に出す・`git grep` の失敗を「0 件」と読む → 門の試験に「値が出力に出る実装」「git の失敗」の変異を入れる
5. 門の本物の木の段が、lane の branch 単独では VIOLATION を出す（他の lane の残り）→ 束ねの後に `OK` を見る。lane の branch では、出た VIOLATION のパスの組が「他の lane の持ち場」の一覧と等しいことを照らす

---

## 波 1a（`9c16547` から今すぐ。並べる）

### Task L1a: 記録の 4 本の置き換え（段 1）

**Files:** Modify: `docs/audits/constitution-2026-07-03T11-58-audit.md`・`docs/audits/constitution-2026-07-07-C1-C6-audit.md`・`docs/PHASE5_REGEN_EXECUTION_2026-06-22.md`・`docs/IDENTITY_SCHEMA_CHANGELOG.md`

- [ ] 名前を placeholder に置き換える（パスの中の名前も。記録はパスの文字列ごと書き換えず、名前の部分だけ placeholder に）
- [ ] 確かめ: 4 本で 4 つの名前が 0／`git diff --word-diff=porcelain` の `+` の語が全て placeholder（を含む語）
- [ ] commit（W11 の carve-out の目的だけの 1 commit）

### Task L1b: 手順書の 3 本と 5(c)（段 1）

**Files:** Modify: `docs/OPERATOR_IDENTITY_SETUP.md`・`docs/PHASE_ALPHA_TESTNET_DRY_RUN.md`・`docs/PHASE_ALPHA_AUDIT_HANDOFF.md`・`docs/IDENTITY_VERIFICATION.md`

- [ ] 名前を placeholder に、古い契約の仕様のパスを新しいパスに。各文書に「値は手元の設定 `${FY_CONFIG_DIR}/xpr-account`・`anchor-sink` を読む」を 1 行
- [ ] `docs/IDENTITY_VERIFICATION.md:21` を設計書 §6.2 の事実に合わせる
- [ ] 確かめ: 4 つの名前が 0／`HOME=~/.metal-fy-proton` の数が直す前と同じ／5(c) の文に `eosio.token::transfer` が在り、「token を動かせない」の主張が無い
- [ ] commit（置き換えと 5(c) は別の commit）

### Task L1c: 契約の仕様の md の移し（段 1）

**Files:** Rename: `scripts/operator-local/contract/<刻印>-anchor.spec.md` → `scripts/operator-local/contract/anchor-contract.spec.md`

- [ ] commit 1: `git mv` だけ（似ている度合い 100。`git show -M --stat` で `R100`）
- [ ] commit 2: 中身の名前を placeholder に
- [ ] 確かめ: ファイル名と中身に 4 つの名前が 0

### Task L2a: 検証の外の公開ページ（段 1）

**Files:** Modify: `public/selection-evidence/index.html`・`public/ja/selection-evidence/index.html`

- [ ] 名前を役の語（英: the anchor account／日: 刻印のアカウント）＋ `/verify/`（日本語は `/ja/verify/`）への link に
- [ ] 確かめ: 名前が 0／`scripts/apply-external-link-attrs.sh --check public` が通る／inline の `style=` が無い

### Task L2b: 例と schema（段 2）

**Files:** Modify: `public/api/anchor-history.example.jsonl`・`public/api/anchor-history.schema.v1.json`・`public/api/anchor-receipt.example.json`・`public/api/anchor-receipt.phase-beta.example.json`・`public/api/anchor-receipt.schema.v1.json`・`public/api/anchor-receipt.v2.example.json`

- [ ] 例は偽の名前（刻印 `fakeanchor12`・送り先 `fakesink1`）。schema の `description` は役の語 ＋「値は /verify/ を見る」。古い契約の仕様のパスは新しいパスに
- [ ] 確かめ: 名前が 0／example が schema に通る／`scripts/check-identity-pins.sh --mode=repo` が直す前と同じ／全体の試験の PASS／FAIL の組が `9c16547` と同じ

### Task L4: 門（段 3）

**Files:** Create: `scripts/check-account-name-scope.sh`・`config/account-name-scope.tsv`・`tests/account-name-scope/test-account-name-scope.sh`

**Interfaces:**
- Produces: `check-account-name-scope.sh [--index] [--messages=<base>]` → exit 0 `OK <n> files`／`DISABLED`、exit 1 `VIOLATION <path>:<line> <role>`・`VIOLATION commit:<short> <role>`・`EXPIRED`・`OBSOLETE`、exit 2 照らせない（設計書 §7）。環境変数 `FYD_NAME_SCOPE_CONFIG`・`FYD_NAME_SCOPE_TODAY`（試験だけ）
- 定義の最初の行: 設計書 §7「最初の行」（判断 1・2 は A）

- [ ] 試験を先に（mktemp の repo で、失敗の条件ごとに 1 つの変異。設計書 §10 の L4 の行の全項目）→ 落ちるのを見る
- [ ] 門を書く（関数 `ans_read_scope_rows`・`ans_scan_tracked_files`・`ans_scan_commit_messages`・`ans_judge`・`ans_report_violation`）
- [ ] 確かめ: 試験が通る／壊して落とす一覧／本物の木の段の VIOLATION のパスの組 = 他の lane の持ち場（Review Focus 5）

## 波 1b（束ね `dig-bundle` が main に入った後。総監督の合図で）

### Task L3: 試験の fixture と凍結の外の script（段 2）

**Files:** 設計書 §4.2 の ⑤ の 14 本・`scripts/notify-anchor-transition.sh`・`scripts/install-anchor-watch-alert-only.sh`

- [ ] 偽の名前に。Case G（testnet の receipt に mainnet の名前が乗らない）が偽の名前で生きていることを、偽の mainnet の名前が receipt に乗る実装で落として見せる
- [ ] 確かめ: 名前が 0／全体の試験の PASS／FAIL の組が直す前と同じ

### Task L1d: `docs/ANCHOR_ACCOUNT_KEY_ROTATION.md`（段 1）

- [ ] L1b と同じ形（placeholder・設定を読む 1 行・HOME の数が同じ）

## 波 2: 束ね

- [ ] 統合の担当: L1a・L1b・L1c・L2a・L2b・L3・L1d を入れ、最後に L4。木の全体で `check-account-name-scope.sh` が `OK`。契約の仕様の移しと G1（`scripts/check-doc-moves.sh`）の扱いは統合の監督が決める（設計書 §6.3）
- [ ] 全体の試験 → 盲検の確認役（opus）→ 総監督

## 12/7 の後（L5。この計画の外）

設計書 §8・§10 の L5 の行。
