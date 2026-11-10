# Simplify refactor, cut A — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move 9 finished documents out of the live document set byte-identically, delete one abandoned stub script, and add the gate G1 that keeps moved paths from silently coming back.

**Architecture:** G1 is one bash script reading `git diff --name-status -M <base> HEAD` and `git grep` over tracked files; it fails closed. The moves are `git mv` only (similarity 100). Order: G1 first, so the move commit is checked by it (spec §4.3).

**Tech Stack:** bash, git. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-10-simplify-refactor-design.md` (§2, §3, §4, §8 row A, §9 G1, §10 rows A and G1).

This file's name contains `simplify-refactor` on purpose: G1 exempts it (spec §9). It names old paths as of 2026-11-10.

## Global Constraints

- Tier: moves and deletion are tier 1-equivalent (machine gates only). G1 is tier 2 (a suite with one mutation per failure condition, red then green; one reviewer at the end of the bundle).
- No host contact, no `proton`, no broadcast text, not even in a test (spec §3 C-1, C-7).
- No host identifier, address, account name or personal name in any file or commit message (§3 C-6).
- Do not touch the keep rows of §4.1 (4, 5, 6, 12, 13, 14) or §4.2 (5 scripts). Nothing from cuts B, C, D.
- Audit documents are append-only (§3 C-8): moves are byte-identical; the only edit to `docs/CYCLE_GATE_DAILY_OBSERVATION.md` is one appended line.
- No `TOOLKIT.md` change (§4.3).
- `git add` names files; never `git add -A` / `git add .`.

## Review Focus

1. A relative link to a moved file (`../audits/X.md`, `audits/X.md`) is "a form other than its new path" and must be a VIOLATION (fail closed), not a pass.
2. A line that contains both the new path and the bare old path must still be a VIOLATION (one good occurrence does not excuse the other).
3. A git error (unknown base, not a repo) must exit 2, never print `OK`.
4. A rename of similarity 100 outside `docs/` and `scripts/` is not checked for similarity, but its basename references still are.
5. File names with spaces must not split into two paths (use `-z` or tab splitting).

---

### Task 1: Commit the design and this plan

**Files:** Create `docs/superpowers/specs/2026-11-10-simplify-refactor-design.md` (copied unchanged; SHA-256 `da143f23d1865005f923bf737c97fbe2a0bc852d36127b43abc9a01ace359950`), `docs/superpowers/plans/2026-11-10-simplify-refactor-cut-a.md`.

- [ ] Check the hash, `git add` the two files, commit. Done by the supervisor before the implementer starts.

### Task 2: G1 `scripts/check-doc-moves.sh` and its suite

**Files:**
- Create: `scripts/check-doc-moves.sh` (mode 100755)
- Test: `tests/check-doc-moves/test-check-doc-moves.sh` (mode 100755; picked up by `tests/run-all-tests.sh` discovery — confirm whether the runner also needs a roster entry and add it if it does)

**Interface (fixed):**
- `bash scripts/check-doc-moves.sh --base=<commit>`; works on the git repository of the current directory.
- Exit 0: no violation, last line `OK <n> moves` (`<n>` = number of `R` lines in the diff).
- Exit 1: one line per violation, then `FAIL <k>`.
- Exit 2: missing `--base`, unknown argument, git error (bad base, not a repo), unreadable file, or a diff status letter other than `A`, `M`, `D`, `R`. Message on stderr. Never prints `OK`.
- Violation lines (exact forms):
  - rename under `docs/` or `scripts/` with similarity < 100: `VIOLATION <new>:0 <old> -> <new> similarity <nn>`
  - deleted file under `docs/`: `VIOLATION <old>:0 <old> -> (deleted)`
  - moved file's basename on a line of a tracked, non-exempt file, where at least one occurrence is not part of the full new path: `VIOLATION <file>:<line> <old> -> <new>`
  - deleted `scripts/` path on a line of a tracked, non-exempt file: `VIOLATION <file>:<line> <old> -> (deleted)`
- Exempt set (fixed in the script, not a parameter): `docs/audits/**`, `docs/archive/**`, `docs/CYCLE_GATE_DAILY_OBSERVATION.md`, and files directly under `docs/superpowers/specs/` or `docs/superpowers/plans/` whose file name contains `simplify-refactor`.

- [ ] **Step 1: Write the suite.** Each case builds a throwaway git repo in a `mktemp -d` directory (removed by `trap`), commits a base, makes the change, commits, runs G1 there. Cases and assertions:
  - `clean_move`: `git mv docs/A.md docs/audits/A.md`, no refs → rc 0, last line `OK 1 moves`.
  - `no_moves`: no change → rc 0, `OK 0 moves`.
  - `partial_similarity`: move + edit content of a `docs/` file → rc 1, a `similarity` VIOLATION line.
  - `docs_deleted`: `git rm docs/B.md` → rc 1, `VIOLATION docs/B.md:0 docs/B.md -> (deleted)`.
  - `stale_basename`: move, and `README.md` line 3 still names `docs/A.md` → rc 1, `VIOLATION README.md:3 docs/A.md -> docs/audits/A.md`.
  - `relative_link`: `docs/X.md` names `audits/A.md` → rc 1 (Review Focus 1).
  - `mixed_line`: one line has the new path and the bare old path → rc 1 (Review Focus 2).
  - `new_path_ok`: refs use only the full new path → rc 0.
  - `exempt_refs`: old path named in `docs/audits/old.md`, `docs/archive/x.md`, `docs/CYCLE_GATE_DAILY_OBSERVATION.md`, `docs/superpowers/plans/2099-simplify-refactor-x.md` → rc 0.
  - `exempt_narrow`: old path named in `docs/superpowers/plans/2099-other.md` and in `docs/superpowers/specs/sub/simplify-refactor.md` → rc 1.
  - `deleted_script_ref`: `git rm scripts/old.sh`, `TOOLKIT.md` names `scripts/old.sh` → rc 1; with the ref only in `docs/audits/` → rc 0.
  - `missing_base` → rc 2; `bad_base` (`--base=deadbeef`) → rc 2 and no `OK`; `not_a_repo` → rc 2.
  - `space_in_name`: a moved `docs/a b.md` with no refs → rc 0, `OK 1 moves` (Review Focus 5).
- [ ] **Step 2: Run the suite before the script exists.** Expected: the cases fail.
- [ ] **Step 3: Write `scripts/check-doc-moves.sh`.** `set -euo pipefail`; parse the diff with `git diff --name-status -M -z` (or tab-split, never space-split); search with `git grep -n -F -z` or equivalent over tracked files only. A line is a violation when the basename occurs at a position that is not the end of an occurrence of the full new path.
- [ ] **Step 4: Run the suite.** Expected: all cases pass.
- [ ] **Step 5: Break to prove.** For each failure condition, apply one mutation to the script, run the suite, see it go red, restore. At least: (m1) similarity check removed, (m2) docs-deletion check removed, (m3) basename check removed, (m4) deleted-script check removed, (m5) exempt set widened to all of `docs/superpowers/`, (m6) missing `--base` returns 0, (m7) git error ignored, (m8) unknown status letter accepted. Record each as `m<n> <what> -> <failing case names>` for the report. Restore with `git diff --exit-code scripts/check-doc-moves.sh` clean before committing.
- [ ] **Step 6: Run on the real tree.** `bash scripts/check-doc-moves.sh --base=0367552` → `OK 0 moves`.
- [ ] **Step 7: Commit** `scripts/check-doc-moves.sh` and the suite (plus the runner roster line if it was needed).

### Task 3: Move 9 documents, fix 1 reference, append 1 note, add `docs/archive/README.md`

**Files:** `git mv` exactly these (names unchanged):
- to `docs/audits/`: `docs/CYCLE_GATE_IMPLEMENTATION_AUDIT.md`, `docs/CYCLE_GATE_T55_AUDIT.md`, `docs/CYCLE_GATE_TRD2_AUDIT.md`
- to `docs/archive/plans/`: `docs/superpowers/plans/2026-07-06-anchor-static-propagation-convergence.md`, `…/2026-07-09-host-checkout-auto-advance.md`, `…/2026-07-13-deploy-git-sot-inversion.md`, `…/2026-08-06-c3-completion-and-guard-coverage.md`, `…/2026-09-24-web-probe-path-classification.md`, `…/2026-10-15-identity-pq-signature.md`
- Modify: `docs/superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md:91` — old plan path → `docs/archive/plans/2026-07-13-deploy-git-sot-inversion.md`; nothing else on the line or in the file.
- Append one line at the end of `docs/CYCLE_GATE_DAILY_OBSERVATION.md`: `**REVISION <UTC>**: the three audits cited at :421-422 moved unchanged to docs/audits/ (simplify cut A).` (`<UTC>` = `date -u +%Y-%m-%dT%H:%MZ` at writing time). No other byte of that file changes.
- Create `docs/archive/README.md`, 5 lines, saying: historical records; not instructions; the live runbooks are in `docs/`.

- [ ] Step 1: make the changes. Step 2: `git diff --cached -M --name-status 0367552` shows 9 `R100` lines. Step 3: `bash scripts/check-doc-moves.sh --base=0367552` → `OK 9 moves` (if a VIOLATION names a live reference the spec missed, stop and report it; do not edit a keep-row file). Step 4: commit.

### Task 4: Delete the abandoned stub

- [ ] `git rm scripts/operator-local/archive/test-phase6-memo-mock.abandoned.sh` (the directory disappears with it). G1 on the real tree → `OK 9 moves`. Commit.

### Task 5: Whole-suite gate

- [ ] `bash tests/run-all-tests.sh` → the last line is the result. If it does not finish in time, write "not run" — never claim it ran.
