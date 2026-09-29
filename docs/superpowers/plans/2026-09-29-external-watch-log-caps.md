# External watch — size caps for everything it writes (spec + plan)

Date: 2026-09-29. Operator-approved values: 1 MB caps, keep newest 10.

## Why

The watch runs every 5 minutes on a shared web host with little free disk. `log/watch.log` is capped by line count only; `log/cron.err`,
`backup/*` and `state/state.json.corrupt-*` have no cap at all. A watch that
errors every run would grow `cron.err` without bound.

## Global Constraints (binding)

G1–G10 of `docs/superpowers/plans/2026-09-29-external-watch.md` still apply
(public repo hygiene, no provider names, multi-tenant scoping, DRY gate,
mutation-proven tests, shellcheck clean). No new cron line, no new file outside
`$HOME/metal-fy-watch/`.

## Behaviour spec (all inside `scripts/external-watch.sh`, every run, after the lock is held)

C1. `log/watch.log`: replace the 6000/5000-line trim with a byte cap. If the
    file exceeds `WATCH_LOG_MAX_BYTES` (default 1048576), keep only its newest
    half (by bytes, cut at a line boundary so no partial first line survives).
C2. `log/cron.err`: same cap and rule (`WATCH_CRONERR_MAX_BYTES`, default
    1048576). This file is held open with O_APPEND by the cron shell while the
    run executes, so it MUST be trimmed IN PLACE (write the kept tail to a temp
    file in `log/`, then `cat tmp > cron.err`, remove tmp) — never replaced by
    `mv`, which would orphan the open descriptor and lose this run's stderr.
C3. `backup/`: keep the newest 10 files by modification time
    (`WATCH_KEEP_BACKUPS`, default 10); delete older regular files only. Never
    follow symlinks; never delete outside `backup/`; directories untouched.
C4. `state/state.json.corrupt-*`: keep the newest 10 (same variable semantics,
    `WATCH_KEEP_CORRUPT`, default 10); never touch `state.json`, `lock`,
    `rpc-cache.json` or anything else in `state/`.
C5. Housekeeping failures never change the watch's alerting behaviour or exit
    code; they write one `note:` line to `watch.log` (no host values).
C6. Overrides are for tests; production uses defaults. Values must be positive
    integers, otherwise fall back to the default.
C7. Docs: `docs/MONITORING_OPS.md` §14 (log section) states the caps.

## Tasks

### Task 1: implement C1–C7 with tests
Files: `scripts/external-watch.sh`, `tests/external-watch/test-external-watch.sh`,
`docs/MONITORING_OPS.md`.
Tests (small override values): watch.log over the cap → ≤ cap and newest line
kept, first line complete; cron.err over the cap → trimmed and the SAME inode
(prove in-place: record inode before/after, and a descriptor opened for append
before the trim still lands its later write in the file); 12 backups → newest
10 kept; 12 corrupt files → newest 10 kept, state.json/lock/rpc-cache untouched;
a symlink in backup/ pointing outside is not followed and its target survives;
invalid override → default used; housekeeping failure (e.g. unreadable backup
dir) → alerting outcome and exit code unchanged. G9: break each rule and show a
test fails.

## As built (fix rounds after the Task 1 review and the final audit)

The spec above is the original plan; these rounds changed the behaviour.
`docs/MONITORING_OPS.md` §14.4 is the current description.

Fix round 1 (review minors):
- Leaked `log/.trim.XXXXXX` temps of a killed run are swept (exact 6-character
  suffix, regular files only).
- Names containing a tab or newline are skipped by the prune (the tab is the
  sort field separator).
- C1/C2 "newest half" means the newest cap/2 bytes cut at a line boundary; when
  the newest line alone is longer than cap/2, its last cap/2 bytes are kept
  verbatim (a partial first line rather than an empty file).

Fix round 2 (final audit: security, correctness, constitution):
- C1/C2: a file with more than one hard link, or in a symlinked `log/`, is not
  trimmed (the in-place write would truncate the other file); a hard link is
  reported with the housekeeping note. The trim re-verifies (no symlink, same
  device/inode, link count 1) immediately before its single write.
- C2: `cron.err` is also trimmed at the very start of every run, before the
  config is parsed, so config errors, a missing dependency or a `set -u` abort
  keep it bounded (at most one run's output over the cap).
- C3: only `*.bak-*` names (all the installer writes to `backup/`) are pruned,
  and the deletions run from inside the directory after verifying it is
  physically `<parent>/backup` (a symlink swapped in after the listing makes
  the prune refuse). The keep-10 count is shared by crontab and bin/etc backups.
- Leaked `state/state.XXXXXX` and `state/rpc-cache.XXXXXX` temps are swept too.
- The installer's `--uninstall` keeps only the newest 3
  `~/metal-fy-watch-crontab.bak-<ts>` files (exactly that name, regular files).
- Residual: a process running as the site account can still race a check and
  its action; no privilege boundary is crossed (MONITORING_OPS §14.4).
