# Simplify refactor, cut B-1 and C-tests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add gates G2 and G3, one library copy of `fetch` (`scripts/lib/fetch-retry.sh`) used by the three monitors, and one shared test-assertion helper (`tests/lib/assert.sh`) adopted one test directory at a time.

**Architecture:** Every part is added first with its own suite and touches no caller (add-only commit); then callers switch one commit at a time, each undone by one `git revert`. G2 keeps removed copies from coming back; G3 proves each switch changed nothing (rc, stdout, stderr, files; or a suite's case multiset).

**Tech Stack:** bash (3.2 compatible), git, sed/awk. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-10-simplify-refactor-design.md` (§2, §3, §5.1 `fetch` row, §5.2 B-1, §5.3 B-P2 B-P5 B-P6 B-P7, §6.2, §8 rows B and C-tests, §9 G2 G3, §10, §11).

This file's name contains `simplify-refactor` on purpose: G1 exempts it (spec §9).

## Global Constraints

- Tiers (spec §10): G2, G3, B-1 (lib + 3 monitors) are tier 2 — a suite with one mutation per failure condition, recorded red then green; one blind reviewer at the end of the bundle. C-tests is tier 1-equivalent, except one mutation of the script under test for each migrated suite of a tier-3 script.
- No host contact, no `proton`, no broadcast text, not even in a test (spec §3 C-1, C-7). No network: every test stubs `curl`, `ssh`, `proton`.
- No host identifier, address, account name or personal name in any file or commit message (§3 C-6).
- Do not touch: `scripts/lib/side-effects.sh`, the four B-2 scripts (`gen-anchor-source.sh`, `gen-anchor-receipt.sh`, `append-anchor-history.sh`, `operator-local/commit-anchor-source.sh`), the six C-5 files, any transition script, any existing lint or test config (`phpunit.xml*`, `phpstan*`, `.eslintrc*`, `eslint.config.*`), `tests/run-all-tests.sh`.
- Gate scripts call no AI or LLM API and read no API key (§11).
- Every new suite: an executable `test-*.sh` (mode 755 in git), prints a line matching `^(test-.*summary:|RESULTS:|Ran [0-9]+ tests? in)`, failure lines matching `^[[:space:]]*(FAIL|FATAL)`, exits 0 iff all pass.
- New function names in G2, G3 and test files must not collide with any function defined elsewhere in `scripts/` or `bin/` (prefix `g2_`, `g3_`, `_fy_fetch_retry_`, `t_`), so G2 on the real tree stays green.
- `git add` names files; never `git add -A` / `git add .`.

## Lanes (who touches what)

| lane | branch | worktree (scratchpad `cut-b1/`) | may touch | starts when |
|---|---|---|---|---|
| g2 | `simplify-cut-b1-g2` | `wt-g2` | `scripts/check-duplicate-functions.sh`, `scripts/duplicate-functions.allow`, `tests/check-duplicate-functions/**` | now |
| g3 | `simplify-cut-b1-g3` | `wt-g3` | `scripts/check-refactor-equivalence.sh`, `tests/check-refactor-equivalence/**`, `tests/fixtures/ajv-stub/ajv` | now |
| lib | `simplify-cut-b1-lib` | `wt-lib` | `scripts/lib/fetch-retry.sh`, `tests/fetch-retry/**` | now |
| assert | `simplify-c-tests` | `wt-assert` | `tests/lib/assert.sh`, `tests/assert-lib/**` | now |
| callers | `simplify-cut-b1` (after g3 and lib are cherry-picked onto it) | `wt` | the 3 monitors, `tests/anchor-publish-health/**`, `tests/identity-pins/**`, `tests/pulsevm-upstream/**`, `scripts/duplicate-functions.allow` (fetch rows only) | g2, g3, lib commits exist and their suites are green |
| m1..m6 | `simplify-c-tests-m<i>` from `simplify-c-tests` (after g3 is cherry-picked onto it) | `wt-m<i>` | only the directories of its row in the split table below | g3 and assert commits exist and their suites are green |
| toolkit | `simplify-cut-b1` | `wt` | `TOOLKIT.md` | after g2, g3, lib |

The supervisor cherry-picks lane commits onto the bundle branches. Order on `simplify-cut-b1`: plan → G3 → G2 → lib → callers' tests commit → 3 caller commits → TOOLKIT. G3 lands before G2 because G2's suite greps all three gate scripts (Task 1, case `no-ai`). Order on `simplify-c-tests`: plan → assert → G3 (cherry-pick) → m1..m6 commits, in lane order.

---

### Task 1: G2 `scripts/check-duplicate-functions.sh` + `scripts/duplicate-functions.allow`

**Files:** Create `scripts/check-duplicate-functions.sh`, `scripts/duplicate-functions.allow`, `tests/check-duplicate-functions/test-check-duplicate-functions.sh`.

**Interfaces:**
- Produces: `bash scripts/check-duplicate-functions.sh` (no arguments; any argument is exit 2), run in the repository to check. Stdout lines `COPY <name> <file>`, `LIBDUP <name> <file>`, `OBSOLETE <name> <file>`, then `OK <n> names <m> rows` (exit 0) or `FAIL <k>` (exit 1). Exit 2: one line `check-duplicate-functions: <reason>` on stderr, no `OK`.
- Allowlist: TSV `name<TAB>file<TAB>reason`, `#` comment lines and blank lines ignored.

Decisions:
- Scanned files: `git ls-files scripts bin` → every `*.sh`, plus each `bin/*` whose first line is a `#!` line naming `bash` or `sh` (`/bin/bash`, `/bin/sh`, `/usr/bin/env bash`, `/usr/bin/env sh`). Library files = scanned files under `scripts/lib/`.
- A definition is a non-comment line matching `^[[:space:]]*(function[[:space:]]+)?NAME[[:space:]]*\(\)` or `^[[:space:]]*function[[:space:]]+NAME[[:space:]]*\{`, NAME `[A-Za-z_][A-Za-z0-9_]*`. Heredoc text is not excluded (a definition inside a heredoc counts for its file).
- A name "is duplicated" when defined in two or more scanned files.
- Wrapper (all three, else it is a copy): (1) body has exactly one line that is not blank or a comment — one-line form `NAME() { CMD; }` counts as one line; multi-line form ends at the first later line that is `}` alone at the definition's indentation; no such line, or a `(` subshell body, is not a wrapper; (2) that line's first word is a name defined in a library file; (3) the same file has, on a non-comment line, the literal `scripts/lib/<that library file's basename>` bounded by a character outside `[A-Za-z0-9._-]` (or line start/end) on both sides of the literal.
- Fails (exit 1): `COPY` — a non-wrapper definition outside `scripts/lib/` of a duplicated name without a row for (name, file); `LIBDUP` — a library name defined outside `scripts/lib/` (wrapper or not; no row excuses it) or defined in two library files; `OBSOLETE` — a row whose (name, file) is not a non-wrapper definition of a duplicated name.
- Exit 2: any argument; not a git repository or a git command fails; allowlist missing or unreadable; malformed row (not exactly 3 tab-separated fields, an empty field, name not `[A-Za-z_][A-Za-z0-9_]*`, file not starting `scripts/` or `bin/`, the same (name, file) twice); a scanned file unreadable.
- Initial allowlist: one row per current non-wrapper copy outside `scripts/lib/` of every duplicated name (the tool's own count). Reasons in English: `fetch` → `B-1: moves to scripts/lib/fetch-retry.sh (spec 5.1)`; `schema_validate_or_die` → `B-2: decision Q1 (spec 5.4)`; `attempt_notify`, `retryable_notify_rc`, `notify_or_keep` → `C-notify: after 2026-12-07 (spec 6.1)`; `sha256_pipe`, `sha256_file`, `sha256_str`, `shq` → `kept (spec 5.1, D-6)`; `url_to_public_path`, `url_to_registry_path` → `kept apart on purpose (spec 5.1)`; `log`, `alert`, `die` → `each script's own log channel (spec 6.1)`; any other → `existing duplicate as of 2026-11-11; no decision yet`.

Input table (each row is a suite case; result in brackets):

| input | missing | unexpected |
|---|---|---|
| arguments | none given [run] | any argument [2] |
| repository | not a repo [2] | git fails [2] |
| allowlist | absent [2] | unreadable [2]; 2 or 4 fields [2]; empty reason [2]; name with a space [2]; file outside scripts/ bin/ [2]; duplicate row [2]; comment and blank lines [ignored, 0] |
| scanned file | — | unreadable [2] |
| row | — | file has no such definition [OBSOLETE 1]; name now in one file only [OBSOLETE 1]; definition there is a wrapper [OBSOLETE 1] |

Cases that must exist (each on a throwaway repo, `mktemp -d`, removed by trap): two copies with rows [0]; one copy without row [COPY 1]; lib name redefined outside lib [LIBDUP 1, even with a row]; same name in two lib files [LIBDUP 1]; wrapper meeting all three [0, no row needed]; and the immediate outside of each wrapper condition while the other two hold — body of 2 lines [COPY]; first word is a command or a non-library function [COPY]; literal path only on a comment line [COPY]; literal path of a different library file [COPY]; literal path with a suffix such as `scripts/lib/x.sh.bak` [COPY]; `bin/` file with a bash shebang is scanned, one with a python shebang is not; `real-tree`: G2 on this repository exits 0; `no-ai`: `grep -niE 'anthropic|openai|claude|api_key'` over `scripts/check-doc-moves.sh`, `scripts/check-duplicate-functions.sh`, `scripts/check-refactor-equivalence.sh` finds nothing, and a missing one of the three is FAIL.

Mutations (each recorded red, then restored green): wrapper rule ignores condition 1; ignores condition 2; ignores condition 3; accepts the literal on a comment line; LIBDUP excused by a row; OBSOLETE check removed; malformed row treated as comment; unreadable file skipped; git failure ignored; an argument accepted. In lane g2's worktree G3 does not exist yet, so `no-ai` is FAIL there for that one path only; it is green on `simplify-cut-b1` after G3 lands first.

- [ ] Steps: write the suite (red) → implement → suite green → mutations red/green recorded → `bash scripts/check-duplicate-functions.sh` on the real tree, last line recorded → commit `feat(check-duplicate-functions): add gate G2 and the initial allowlist`.

### Task 2: G3 `scripts/check-refactor-equivalence.sh`

**Files:** Create `scripts/check-refactor-equivalence.sh`, `tests/check-refactor-equivalence/test-check-refactor-equivalence.sh`, `tests/fixtures/ajv-stub/ajv` (a byte copy of the fake ajv in `tests/schema-validate-ajv-path/test-schema-validate-ajv-path.sh`; that test is not edited — B-2 retargets it).

**Interfaces:**
- Produces: `bash scripts/check-refactor-equivalence.sh --base=<commit> (--cases=<tsv> | --suite=<dir>)` in the repository to check. Base side = `<commit>`, head side = `HEAD` (the commit, not the working tree). Stdout: `DIFF <id> <what>` per difference (`<id>` = `L<line>` of the cases file, or the suite file path), info lines `SUITE <file> base_rc=<n> head_rc=<n> cases=<n>/<n>` in suite mode, then `OK <n> equal` (exit 0) or `FAIL <k>` (exit 1). Exit 2: one line `check-refactor-equivalence: <reason>` on stderr, no `OK`.

Decisions:
- Both sides run one after the other at the same paths: `git worktree add --detach <T>/tree <side commit>` → run → `git worktree remove --force <T>/tree`, where `<T>` is one `mktemp -d` under `$TMPDIR`. A trap on EXIT, INT, TERM removes the worktree and `<T>` on every exit; `git worktree prune` after removal.
- Each run: fresh `<T>/fx` (fixture copy), `<T>/home`, `<T>/tmp`; `HOME=<T>/home`, `TMPDIR=<T>/tmp`, `FY_LIVE` unset; `PATH=<T>/stubs:<farm or original PATH>`; cwd `<T>/fx`; command `bash <T>/tree/<script> <args> </dev/null`.
- Stubs `curl ssh scp proton cleos` in `<T>/stubs`: append `<cmd> <args>` to `<T>/calls.log`, then exec `<T>/fx/stubs/<cmd>` if that file is executable, else print `g3-stub: <cmd> not provided by the case` to stderr and exit 1. Before each run, `command -v proton` and `command -v ssh` under the run's PATH must print `<T>/stubs/proton` and `<T>/stubs/ssh`; otherwise exit 2.
- Cases file (tab-separated, 6 or 7 columns, `#` and blank lines ignored, `-` = empty): 1 script (repo-relative, tracked at both sides, else 2); 2 args (space-separated words); 3 env (space-separated `KEY=VALUE`, KEY `[A-Z_][A-Z0-9_]*`, KEY in `PATH HOME TMPDIR FY_LIVE` is 2); 4 fixture dir (repo-relative, taken from `HEAD` via `git archive`, same bytes for both sides; absent in HEAD is 2); 5 output files (comma-separated, relative to the fixture copy; present on one side only is a DIFF; absent on both is 2); 6 validator `ajv-stub|python|none|-`; 7 normalize (optional, comma-separated keys `[A-Za-z0-9_]+`). In args and env values the token `{FIXTURE}` becomes `<T>/fx`; any of `' " \ $ \` ; | & < > ( )` is 2. Zero case rows is 2.
- Validator column: `-` = PATH unchanged after the stubs; `ajv-stub` = farm without `ajv`, plus `tests/fixtures/ajv-stub/ajv` (from HEAD) in the stubs dir; `python` = farm without `ajv`, and `python3 -c 'import jsonschema'` must succeed (else 2); `none` = farm without `ajv`, `python`, `python3`, `python3.*`. Farm = `<T>/farm`, one symlink per executable name found on the original PATH (first wins), minus the excluded names.
- Normalize: for each listed key, in stdout, stderr and each output file, `"KEY"[[:space:]]*:[[:space:]]*"[^"]*"` becomes `"KEY":"<NORMALIZED>"` on both sides before comparing. Nothing else is normalized.
- Compared in cases mode: rc, stdout, stderr, each output file, byte for byte.
- Suite mode: every executable `test-*.sh` directly in `<dir>` at each side (none at a side is 2; a file at one side only is a DIFF), run as `bash <file> </dev/null` with the same environment as above, stdout and stderr both parsed. Case line = `^[[:space:]]*(PASS|FAIL|✓|✗)[[:space:]]+(.+)$`, name = group 2 with trailing whitespace trimmed; `PASS`, `✓` = pass; `FAIL`, `✗` = fail. Compared: exit code and the multiset of (status, name). A side with zero case lines is 2.
- Exit 2 also: `--base` missing or unresolvable; neither or both of `--cases`/`--suite`; unknown argument; not a git repository; cases file missing/unreadable; malformed row; worktree add fails.

Cases that must exist (throwaway repo with a toy script at two commits): equal → 0; rc differs → 1; stdout differs → 1; stderr differs → 1; output file differs → 1; output file on one side only → 1; output absent on both → 2; named normalize key differs only in its value → 0; an unnamed key differs → 1; normalize names a key but another byte differs → 1; reserved env key → 2; forbidden character in args → 2; 5 columns → 2; 8 columns → 2; unknown validator value → 2; `{FIXTURE}` substituted; stub records calls and fails without a fixture stub; fixture stub is used when present; script missing at base → 2; zero rows → 2; missing `--base` → 2; both modes → 2; suite mode: `  ✓ X` before and `PASS  X` after → 0; padded `%-70s` name equal → 0; lost case → 1; renamed case → 1; flipped status → 1; rc differs → 1; zero case lines → 2; after every exit code (0, 1, 2) and after SIGTERM, `git worktree list` is back to one entry and the test's `$TMPDIR` is empty.

Mutations (each recorded red, then restored green): skip the stub check; drop the stub dir from PATH; compare rc only; ignore stderr; normalize every key; skip worktree removal on exit 2; treat zero suite case lines as equal; treat `✓` as fail; accept a reserved env key; read head from the working tree instead of `HEAD`.

- [ ] Steps: suite (red) → implement → green → mutations recorded → commit `feat(check-refactor-equivalence): add gate G3`.

### Task 3: `scripts/lib/fetch-retry.sh` (add-only)

**Files:** Create `scripts/lib/fetch-retry.sh`, `tests/fetch-retry/test-fetch-retry.sh`.

**Interfaces:**
- Produces (spec §5.2 B-1, verbatim): `fy_fetch_retry [--max-time=SECONDS] [--no-retry-4xx] -- URL OUTFILE`; stdout = the final attempt's HTTP status code (`000` on transport failure), no newline; OUTFILE = the final attempt's body; return 0 after a valid call, 64 on a usage error; env `FYD_FETCH_ATTEMPTS` (default 3), `FYD_RETRY_SLEEP` (default 3), `CURL` (the caller's). `--max-time` has no default: missing is 64. Internal helpers are named `_fy_fetch_retry_*`.
- The curl invocation, loop and stop rules are the bytes of today's copies (`scripts/check-anchor-publish-health.sh:324-337`, `scripts/check-identity-pins.sh:445-458`, `scripts/check-pulsevm-upstream.sh:973-987`) with only the two differences of spec §5.1 made into options. Any third difference found: stop and report.
- Header: `# CHAIN: none` and `# PRIME_DIRECTIVE: TESTNET-FIRST` in the first 10 lines; no side effect when sourced; never `exit`; no `FY_LIVE`.

Cases: 200 at once → `200`, 1 call; 500,500,200 → `200`, 3 calls; 500 ×3 → `500`, 3 calls; transport failure → `000`; 404 then 200 with `--no-retry-4xx` → `404`, 1 call; without it → `200`, 2 calls; `FYD_FETCH_ATTEMPTS=1` → 1 call; `--max-time=15` reaches curl as today's copies pass it; missing `--max-time` → 64; non-integer `--max-time` → 64; unknown option → 64; missing `--`, URL or OUTFILE → 64; stdout has no newline; OUTFILE holds the last body; sourcing prints nothing and defines only `fy_fetch_retry` and `_fy_fetch_retry_*`; B-P7: `grep -nE '\bexit\b|fyd_notify|fyd_push|FY_LIVE'` over the lib finds nothing.

Mutations: retry on 4xx despite `--no-retry-4xx`; stop retrying on 5xx; default `--max-time`; return 0 on a usage error; add `exit 1`; print a newline.

- [ ] Steps: suite (red) → implement → green → mutations → commit `feat(lib): add fetch-retry, the single fetch loop (add-only)`.

### Task 4: `tests/lib/assert.sh` (add-only)

**Files:** Create `tests/lib/assert.sh`, `tests/assert-lib/test-assert-lib.sh`.

**Interfaces (spec §6.2):** `t_pass NAME` → stdout `PASS  NAME`, PASS+=1; `t_fail NAME [WHY]` → stderr `FAIL  NAME` or `FAIL  NAME  (WHY)`, FAIL+=1; `t_assert_eq NAME WANT GOT` → `t_pass NAME` if equal, else `t_fail NAME "want=<WANT> got=<GOT>"`; `t_summary SUITE` → stdout `test-SUITE summary: PASS=<n> FAIL=<m>`, return 0 iff FAIL=0. On source: `PASS=${PASS:-0}`, `FAIL=${FAIL:-0}`; nothing else runs; works under `set -u`; never `exit`.

Cases: each line's exact bytes and stream; counters; equal/unequal strings including empty and with spaces; summary line matches `^test-.*summary:`; return codes of `t_summary`; sourcing under `set -u` with PASS unset; a suite using it parses in G3 suite mode (`PASS  X`). Mutations: t_fail to stdout; WHY dropped; t_summary returns 0 with FAIL>0; counter not incremented; one space instead of two.

- [ ] Steps: suite (red) → implement → green → mutations → commit `feat(tests): add tests/lib/assert.sh (add-only)`.

### Task 5: callers (on `simplify-cut-b1`, after G3 and lib are cherry-picked onto it)

**Files:** Modify `scripts/check-anchor-publish-health.sh`, `scripts/check-identity-pins.sh`, `scripts/check-pulsevm-upstream.sh`, their suites under `tests/anchor-publish-health/`, `tests/identity-pins/`, `tests/pulsevm-upstream/`, and the `fetch` rows of `scripts/duplicate-functions.allow`.

- Commit 5a (tests only, green on the current inline copies): B-P5 cases (stub curl 404 then 200: pulsevm prints/acts on 404 after 1 call; publish-health on 200 after 2) and, in each of the 3 suites, one case that the curl stub sees `--max-time` with 15 / 20 / 20.
- Commits 5b, 5c, 5d (one per script): `fetch() { fy_fetch_retry --max-time=<15|20> [--no-retry-4xx] -- "$@"; }`, the library loaded near the top through a variable holding the literal `scripts/lib/fetch-retry.sh`, with the same guard form and exit code the script already uses for its existing library load (no such guard → stop and report); its `fetch` row removed from the allowlist in the same commit. After each: G3 `--suite=<that suite's dir> --base=<previous commit>` → `OK`; G2 on the real tree → `OK`.
- Mutations: ignore `--no-retry-4xx` in the lib (B-P5 red); wrong `--max-time` in one wrapper (5a case red); inline `fetch()` body back in one script (G2 red, B-P6).

### Task 6: C-tests migrations (m1..m6)

One commit per directory, in the order of the row. Per directory: source `"$REPO_ROOT/tests/lib/assert.sh"`; keep the suite's own helper names as one-line wrappers where shorter than renaming call sites; a helper that does more than print and count (exit, extra output) keeps that extra in its wrapper; the summary line comes from `t_summary`. Proof per commit: G3 `--suite=<dir> --base=<previous commit>` → `OK` with `base_rc=0 head_rc=0` and case count > 0; the suite run directly exits 0. For a suite of a tier-3 script (an anchor, broadcast, keystore or cycle-gate script), one mutation of the script under test (not committed) turns the migrated suite red. A directory whose output G3 cannot parse (exit 2) is skipped and reported. Not migrated in this bundle: `tests/cycle-gate` (own runner), `tests/lib`, `tests/fixtures`, `tests/anchor-publish-health`, `tests/identity-pins`, `tests/pulsevm-upstream` (lane callers), `tests/schema-validate-ajv-path` (B-2), the four new suites of Tasks 1–4, the 8 directories that define none of the helpers, and `scripts/operator-local/test-commit-anchor-source.sh`.

Split (balanced by test line count; directories never overlap):

| lane | dirs | lines | directories, in commit order |
|---|---|---|---|
| m1 | 13 | 7550 | `tests/side-effects-callers`, `tests/sign-anchor-event`, `tests/gen-anchor-receipt`, `tests/a-chain-profile`, `tests/identity-kind-discipline`, `tests/agent-readability`, `tests/keystore-guard`, `tests/legacy-anchor-archive`, `tests/host-account`, `tests/watch-anchor-events`, `tests/anchor-watch`, `tests/node-health`, `tests/identity-pq-lib` |
| m2 | 13 | 7511 | `tests/anomalies`, `tests/external-watch`, `tests/side-effects`, `tests/check-cron-file`, `tests/gen-renewal-ics`, `tests/install-cron-audit-markers`, `tests/field-contracts`, `tests/run-all-tests-preflight`, `tests/check-doc-moves`, `tests/dr-drill`, `tests/notify-anchor-transition`, `tests/identity-pq-check`, `tests/install-web-host-static-deploy-key` |
| m3 | 13 | 7467 | `tests/cycle-transition`, `tests/run-testnet-rehearsal`, `tests/push-to-web-host`, `tests/install-web-host-external-watch`, `tests/install-cron-env-headers`, `tests/notify`, `tests/apply-external-link-attrs`, `tests/peer-validators`, `tests/sync-to-validator-host`, `tests/anchor-history-read`, `tests/identity-verification-vectors`, `tests/cycle-transition-steps`, `tests/staker-backup-encrypt` |
| m4 | 14 | 7522 | `tests/safe-broadcast`, `tests/cycle-context`, `tests/deploy`, `tests/pre-push-scan`, `tests/daily-status`, `tests/reward-backfill-discover`, `tests/gen-identity-pq`, `tests/host-drift`, `tests/cron-filename-guard`, `tests/uptime-workflow`, `tests/gen-evidence`, `tests/anchor-source-canonicalizer`, `tests/install-git-hooks`, `tests/identity-pq-docs` |
| m5 | 14 | 7550 | `tests/reward-tracker`, `tests/append-anchor-history`, `tests/backup-host-config`, `tests/install-web-host-subdir-allowlist`, `tests/run-all-tests-roster`, `tests/preview-cycle-anchor-broadcast`, `tests/anchor-pipeline`, `tests/renewal-memo`, `tests/install-anomalies-logrotate`, `tests/cron-generators-lint`, `tests/incidents-page`, `tests/gen-cycle-history`, `tests/scripts-freshness`, `tests/pq-identity-tools` |
| m6 | 14 | 7516 | `tests/rehearsal-preflight`, `tests/publication-registry`, `tests/host-advance`, `tests/watch-validators`, `tests/compose-naming`, `tests/gen-anchor-source`, `tests/install-web-host-anchor-source-allowlist`, `tests/setup-schema-validator`, `tests/vps-bootstrap`, `tests/install-web-host-sig-allowlist`, `tests/orchestrator-guard`, `tests/install-anomalies-web-origin-env`, `tests/audit-cron-dir`, `tests/doc-key-cli-args` |

### Task 7: TOOLKIT.md

Add one entry each for `scripts/check-doc-moves.sh` (G1, `--base=`; finding F1), `scripts/check-duplicate-functions.sh` (G2), `scripts/check-refactor-equivalence.sh` (G3) and `scripts/lib/fetch-retry.sh`, in the same form as the existing `check-*.sh` entries. No other entry changes. Commit `docs(toolkit): list gates G1 G2 G3 and fetch-retry`.

## Where it connects / how to remove it

| part | seam | remove |
|---|---|---|
| G2 | `scripts/duplicate-functions.allow` rows and its suite | `git revert` of its commit |
| G3 | `--base`, `--cases`, `--suite`; used by hand and by the pre-merge step | `git revert` of its commit |
| fetch-retry | `fy_fetch_retry` and its options | revert each caller's commit (its inline copy and row return), then the lib |
| assert.sh | `t_pass`, `t_fail`, `t_assert_eq`, `t_summary` and the runner's three line patterns | revert per directory, then the lib |

## Review Focus

1. A wrapper whose library literal sits only in a comment, or names a different library, must be a copy (G2).
2. A stub that cannot be shown to shadow `proton`/`ssh` must stop G3 with 2, before any script runs.
3. A suite whose output has no case lines must not compare equal (G3 exit 2).
4. G3 must leave no worktree and no temp dir behind on any exit, including a signal.
5. A usage error in `fy_fetch_retry` must return 64 and not call curl.
