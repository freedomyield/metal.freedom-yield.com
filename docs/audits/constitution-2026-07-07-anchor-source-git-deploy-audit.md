# Constitution Audit — 2026-07-07T15:25 (JST)

Independent verification of the "anchor-source publish 是正 (B = git-deploy-only)" wave.

## Summary

- **Overall**: 🟢 pass
- **Range**: `07aec8a..d75531e` (5 commits, main HEAD = `d75531e`)
- **Scope**: custom 6-item task (public cryptographic integrity + publish-path coherence + health-check + gitleaks + regression + Constitution)
- **Review posture**: independent re-computation from served bytes + on-chain read-only cross-check
- **Violations**: 🔴 0 / 🟡 0
- **Auditor**: constitution-auditor agent (read-only; no implementation, no host writes, no broadcast)

Commits in range:

| sha | subject |
|---|---|
| `a2a0e0f` | fix(anchor): publish cycle-3 anchor-source.json via git-deploy (was stale on public) |
| `73bf346` | fix(anchor): content-verify anchor-source publish + drop dead auto-recover |
| `0983dd8` | docs(deploy-matrix): move anchor-source.json to git-deploy ownership |
| `b21b277` | docs(anchor-source): document git-deploy publish + on-chain memo cross-check |
| `d75531e` | test(deploy): align rsync-delete test with anchor-source git-deploy ownership |

Files touched (`git diff --numstat 07aec8a..d75531e`): `.gitleaks.toml` (+7/-6), `deploy/feed-excludes.txt` (+0/-2), `docs/ANCHOR_SOURCE.md` (+44/-1), `docs/DEPLOY_OWNERSHIP_MATRIX.md` (+17/-2), `public/api/anchor-source.json` (+77/-0), `scripts/check-anchor-publish-health.sh` (+105/-47), `tests/anchor-publish-health/test-check-anchor-publish-health.sh` (+214/-0), `tests/deploy/test-build-rsync-excludes.sh` (+10/-4), `tests/deploy/test-rsync-delete-protection.sh` (+18/-6).

---

## Item 1 — Public cryptographic integrity (最重要)

**Status**: 🟢 pass — 4/4 branch/combined roots independently reproduced, and additionally confirmed against on-chain memos.

**Method**: `curl` the live `https://metal.freedom-yield.com/api/anchor-source.json` (HTTP 200) and `.../anchor-receipt.json` (HTTP 200). Recompute each branch root from the *served* bytes using the exact `gen-anchor-source.sh:469-472` method (`jq -cS '.<branch>' | shasum -a 256`) and the combined via `printf '%s' "<id><ob><ar>" | shasum -a 256`. Then read the A-chain transaction memos read-only via a public Hyperion endpoint.

**Evidence — independent re-computation from served bytes**:

| branch | recomputed | expected (task) | match |
|---|---|---|---|
| identity_branch | `840665c70f72f55ae110a9ebd5dc6e397985c76b543af6e4ca6330fb5dacf763` | `840665c7…dacf763` | ✅ |
| observations_branch | `eab56e253ba172cea0a524c6b565c3988393d4e4c12ae0922d2f06c4bbc25c89` | `eab56e25…bbc25c89` | ✅ |
| artifacts_branch | `3e039f62f4ed60fc0b370bba2b0923fd602889707ded59cdee3a865b297dc4dd` | `3e039f62…97dc4dd` | ✅ |
| combined (dag_root) | `1862466b64ddd628df84d3e789d88f7366ec18912e7e4ed4f174b2716f2332dc` | `1862466b…6f2332dc` | ✅ |

- Served `.dag_root_computed` = `1862466b…6f2332dc` and equals the independently recomputed combined root (COMBINED==PUBLISHED: YES).
- Served `anchor-source.json` sha256 = `b260740e53b7beba4f00f334a5a0660153cee8c4a3655140b1cab1159f469b27`, which equals `anchor-receipt.json.anchor_source_sha256` → the served file IS the signed pre-image (byte-identical).
- Public `anchor-receipt.json` memos exactly match the four roots: `fya1c3-id:840665c7…`, `fya1c3-ob:eab56e25…`, `fya1c3-ar:3e039f62…`, `fya1c3:1862466b…`.
- **On-chain read-only** (`GET https://proton.eosusa.io/v2/history/get_transaction?id=0b70d2aa…`, block `390918553`) returned the same four memos. No broadcast performed — pure history read.

**Finding**: full chain of custody proven: served public source → independent recompute → public receipt → on-chain A-chain memos, all four values identical.

---

## Item 2 — Publish-path coherence (self-contradiction resolved?)

**Status**: 🟢 pass — anchor-source.json is uniformly git-deploy owned; the prior "in feed-excludes but rejected by push-to-web-host" contradiction is gone.

**Method**: `git ls-files`, read `deploy/feed-excludes.txt`, grep `scripts/push-to-web-host.sh` allowlist, and run `scripts/deploy/build-rsync-excludes.sh public/`.

**Evidence**:
- (a) `git ls-files` → `public/api/anchor-source.json` **is tracked**. `anchor-receipt.json` / `anchor-history.jsonl` are **not** tracked (host-pushed).
- (b) `deploy/feed-excludes.txt` — `anchor-source.json` is **absent**; `api/anchor-receipt.json`, `api/anchor-receipt.json.sig`, `api/anchor-history.jsonl` **remain present**.
- (c) `scripts/push-to-web-host.sh` allowlist (usage line + case) accepts `anchor-receipt.json`/`anchor-history.jsonl` but **not** `anchor-source.json` (`grep 'anchor-source'` → NOT in file).
- (d) `build-rsync-excludes.sh public/` output contains `--exclude=/public/api/anchor-receipt.json(.sig)` and `anchor-history.jsonl` but **no** `anchor-source` entry (grep count = 0).

**Finding**: the four conditions are consistent — anchor-source.json is git-tracked, deploy-served, not host-pushed, and not rsync-excluded (so the git copy authoritatively overwrites any stale dst). Receipt/history retain host-push + exclusion. The self-contradiction is resolved.

---

## Item 3 — Health-check content-verify + dead auto-recover removed

**Status**: 🟢 pass — content-verify present, stale-but-200 detected, dead recover removed, test 11/11 PASS.

**Method**: read `scripts/check-anchor-publish-health.sh`, diff `73bf346`, run the suite test.

**Evidence**:
- Script now fetches the served source and asserts `.dag_root_computed` reproduces the on-chain anchored root recorded in the receipt (`extract_anchored_root`: memo → root_hex → dag_root_hash). Exit codes: `0` verified, `2` not served, `3` **served-but-stale (content mismatch)**, `4` receipt unverifiable, `5` corrupt.
- `git show 73bf346` confirms the old validator-host auto-recover block (which invoked the host push wrapper with `anchor-source.json`, a filename that wrapper's allowlist rejects) was **removed**; the wrapper now appears only in an explanatory comment (line 28), no executable call.
- `tests/anchor-publish-health/test-check-anchor-publish-health.sh`: **PASS=11 FAIL=0**, including `stale: 200 + dag mismatch -> exit 3`, `stale: alert says content mismatch`, and `dead-recover: no executable push-to-web-host.sh call (auto-recover removed)`.

**Finding**: the exact three-day-silent failure class (200 + stale root) is now detected; recovery is deliberately alert-only, matching the git-deploy publish model.

---

## Item 4 — .gitleaks.toml allowlist change validity

**Status**: 🟢 pass — the broadening is minimal and scoped; not an over-broad hole.

**Method**: `git diff` the regex, analyze match scope with Python `re`, run `gitleaks detect`.

**Evidence**:
- Regex change: `public/api/anchor-source\.[^/]+\.json` → `public/api/anchor-source(\.[^/]+)?\.json` (makes the middle segment optional so the now-canonical `anchor-source.json` joins the existing `anchor-source.*.json` family).
- Scope analysis — MATCH: `anchor-source.json`, `anchor-source.substantive.json`, `anchor-source.v1.json`, `anchor-source.json.sig`. **no** match: `anchor-receipt.json`, `validator.json`, `scripts/secret.env`. The allowlist stays confined to the anchor-source hash-artifact family (64-char sha256 Merkle roots — irreversible, public-safe).
- `gitleaks 8.30.1 detect --no-git -c .gitleaks.toml` → **no leaks found** (scanned ~6.79 MB).

**Finding**: no path outside the generated anchor-source artifact family is whitelisted; real secrets are not passed through.

---

## Item 5 — Regression (full test suite)

**Status**: 🟢 pass.

**Method**: `bash tests/run-all-tests.sh`.

**Evidence**: `OVERALL: total=35 pass=35 fail=0 — RESULT: ALL PASS`. Notably green: `broadcast-guard` (27), `publish-guard` (39), `safe-broadcast` (16), `cycle-gate` (20), `build-rsync-excludes` (8), `rsync-delete-protection`, `anchor-publish-health` (11), `append-anchor-history` (16), `sign-anchor-event` (19). No existing enforcement test regressed.

**Finding**: none.

---

## Item 6 — Constitution compliance (secret / broadcast / host literal in the wave)

**Status**: 🟢 pass.

**Method**: scan added lines (`git diff 07aec8a..d75531e | grep '^+'`, 501 added lines) for raw broadcast shapes, dotted-quad host IPs, and personal/host identifier literals; `gitleaks` (item 4).

**Evidence**:
- Raw broadcast shape in added lines (`proton action|transaction`, RPC push shapes, cleos-push): **0** (comment/allowlist references excluded).
- Host IP literal (dotted-quad, excluding 0.0.0.0/127.0.0.1/example): **0**.
- Personal / leaked-host identifier literals (operator handle and the historically-leaked provider host token): **0 matches** in added lines. The word `Xserver` appears only as a generic host-role term already used publicly in `DEPLOY_OWNERSHIP_MATRIX.md` — not an identifier literal (no IP, no SSH key name).
- gitleaks tracked-tree scan: no leaks.
- Meta-confirmation: an audit grep whose pattern contained a cleos-push literal was itself blocked by `scripts/broadcast-guard.sh` tier-1 (PRIME_DIRECTIVE); this report Write was likewise fail-closed by `scripts/publish-guard.sh` when a literal identifier was drafted — both guards fire as designed.

**Finding**: none.

---

## Statistics

- Items checked: 6
- Passed: 6 (all 🟢)
- 🔴 critical: 0
- 🟡 warning: 0

## Auditor note

- Fabrication: 0 — every value is a live-captured `curl` / `shasum` / `jq` / `git show` / `gitleaks` / on-chain `get_transaction` result.
- 越権 implementation: 0 — indications only; no schema/script/doc/config changed by this audit.
- Numeric claims: measured (`git diff --numstat`, test summaries, sha256 recompute). No "~" / "約" markers.
- Append-only: this is a new report file; no existing audit doc was touched, and no untracked `docs/audits/*` was modified.
- No host writes; no broadcast pathway invoked (only read-only history GET).

> **operator へ**: 本 report の各 finding は `superpowers:receiving-code-review` の手続きに従い、technical rigor で独立 verify してください。特に Item 1 の 4 値一致は自身の端末で `curl … | jq -cS '.identity_branch' | shasum -a 256` を再走すれば再現できます。performative agreement / blind implementation は禁止。疑問があれば追加質問か再監査を。
