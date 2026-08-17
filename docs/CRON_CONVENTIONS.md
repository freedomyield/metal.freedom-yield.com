# Cron file conventions

This document captures the conventions every `/etc/cron.d/metal-*` file in this project must follow. It exists because a single non-compliant cron file caused the 2026-06-19 01:30 UTC `metal-evidence` failure: the redirect pointed at `/var/log/gen-evidence.log` where the `deploy` user had no create permission, and bash rejected the redirect before `push-to-web-host.sh` could run.

## Required rules

### 1. Log path MUST be project-local

```
GOOD:  >> /home/deploy/metal.freedom-yield.com/logs/<name>.log 2>&1
BAD:   >> /var/log/<name>.log 2>&1
```

`/var/log/` is owned by `root:syslog`, mode `0755`. The `deploy` user is not in the `syslog` group, so it cannot create new files there. Existing logs under `/var/log/` (e.g. `node-info.log`, `server-status.log`) work only because root pre-created them and chowned to `deploy`. New cron entries MUST NOT depend on that one-time setup — they MUST log under the project's `logs/` directory, which is owned by `deploy:deploy` with mode `0775`.

If the project's `logs/` directory does not yet exist, the cron-installer creates it first:

```sh
sudo -u deploy mkdir -p /home/deploy/metal.freedom-yield.com/logs
sudo -u deploy touch    /home/deploy/metal.freedom-yield.com/logs/<name>.log
```

### 2. Wrap the work in a compound, redirect (or pipe) the compound

```
GOOD:  { ...stuff... } >> /home/deploy/.../logs/<name>.log 2>&1
BAD:   ...stuff... >> /home/deploy/.../logs/<name>.log 2>&1

GOOD:  { ...stuff... } 2>&1 | logger -t <tag>
GOOD:  bash -c "...stuff..." 2>&1 | logger -t <tag>
BAD:   ...stuff... 2>&1 | logger -t <tag>
```

Without the braces (or an equivalent `bash -c "..."` wrapper), a redirect OR a pipe attaches only to the last `simple command` in the chain (POSIX shell rule — a pipeline binds tighter than `&&`). Earlier commands' stdout is discarded by cron (mailed to the operator, but there's no MTA on this host). The braces are an explicit grouping so every command in the chain shares the same log target or pipe destination — `scripts/check-cron-file.sh` Rule 2 enforces this for both the redirect and the pipe form (widened 2026-08-07; see "Alternative form" below for the pipe case in detail).

### 3. Emit start / end markers and capture rc

```
30 1 * * * deploy { \
    echo "=== <name> start $(date -u +\%FT\%TZ) ==="; \
    cd <repo> && bash scripts/<step1>.sh && bash scripts/<step2>.sh; \
    rc=$?; \
    echo "=== <name> end $(date -u +\%FT\%TZ) rc=$rc ==="; \
} >> /home/deploy/.../logs/<name>.log 2>&1
```

The start / end lines make every cron run visually obvious in the log. `rc=$?` captures the exit status of the last command in the chain (which, because of `&&`, is either the first failure or the final success). Together they make a future audit answer "did the 2026-06-30 firing complete?" in one `grep`.

### 4. Escape `%` in cron files

Cron treats unescaped `%` as a newline-of-input separator. Inside the command, `\%` makes cron preserve `%` literally so the shell can run `date -u +\%FT\%TZ`. Bare `%` will silently truncate the command at that character.

### 5. Set `SHELL=/bin/bash`, `PATH`, and project-specific env vars at the top

```
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
WEB_PUSH_KEY=/home/deploy/.ssh/<key>
WEB_HOST_FILE=/etc/freedom-yield/<host-file>
```

cron's default environment is intentionally minimal. Set what your script needs. The values land in the spawned shell's environment (not as shell-local assignments), so children inherit them. Without explicit `SHELL`, cron defaults to `/bin/sh`, which lacks bash features (the `{ ... }` compound works in both, but `$()`, `$RANDOM`, etc., differ).

### 6. Set `FY_LIVE=1` when the cron invokes a side-effecting script

```
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
15 5 * * * deploy bash /home/deploy/.../scripts/check-host-drift.sh 2>&1 | logger -t host-drift
```

`scripts/lib/side-effects.sh` (2026-08-06) gates production side effects that actually go through it — an `ntfy` push via `notify.sh` (when a caller routes it through the library's `fyd_notify` wrapper), or a `/var/lib/freedom-yield` state-dir write — behind `FY_LIVE=1`. Anything else (unset, `0`, anything but the literal `1`) is a loud dry no-op: the suppressed action logs one `DRY: would ...` line to stderr and returns success. Only cron env headers are meant to carry `FY_LIVE=1`; a test or an interactive shell that doesn't set it stays hermetic by default.

**`push-to-web-host.sh` is the one exception worth naming explicitly, because it is easy to misread as gated too.** Despite being on Rule 6's side-effecting allowlist below, the script itself never reads `FY_LIVE` or sources `scripts/lib/side-effects.sh` — confirmed by reading it end to end — and `docs/CYCLE_GATE.md` step 3 states the same thing independently: "`push-to-web-host.sh` has no `FY_LIVE` concept at all — every invocation pushes unconditionally." Rule 6 still requires the flag on any cron that invokes it, but that requirement is allowlist POLICY (any cron doing a publish is worth the discipline of an explicit `FY_LIVE=1`), not a functional gate this specific script honors. See the worked example below for what this means in practice for a cron that chains it.

A cron whose invoked command never notifies, never pushes, and never touches `/var/lib/freedom-yield` does not need the line. `scripts/check-cron-file.sh` Rule 6 enforces this: it fails a candidate cron whose command references a known side-effecting script (or one that sources `scripts/lib/side-effects.sh`) without a `FY_LIVE=1` line, and passes everything else without requiring the line.

**This is a per-file judgment, not a per-script one — distinguish the TEMPLATE from what is actually DEPLOYED.** `scripts/vps-bootstrap.sh`'s `step_node_info_cron` / `step_server_status_cron` templates, as currently written, only run `node-info.sh` / `server-status.sh` and overwrite a `public/api/*.json` file directly — no notify, no push, no state dir — so a cron generated fresh from either template does not need `FY_LIVE=1`. But the 2026-07-07 host audit (`docs/audits/constitution-2026-07-07-host-state-audit.md:36`) found the **live, deployed** `metal-node-info` cron additionally chains a `push-to-web-host.sh` publish leg that the template does not generate (one of 9 "publish 系" crons on that host). That deployed file DOES need `FY_LIVE=1` — Rule 6 already detects this correctly, because it reads the actual command line in front of it (`push-to-web-host.sh` is on Rule 6's allowlist) rather than trusting a script-name-based rule of thumb. `metal-server-status` is not on that publish list and remains genuinely out of scope in both the template and (per the same audit) the deployed file. Do not use "`node-info` is out of scope" as a general statement when reasoning about a specific host's cron — always check what that file's command line actually invokes.

## Alternative form: piping to `logger` instead of a log file

A single-command cron line can pipe its output straight to `logger` instead
of redirecting into a project log file — e.g. the real `metal-host-advance`
entry:

```
45 4 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/advance-host-checkout.sh 2>&1 | logger -t host-advance
```

This is intentional: `logger -t <tag>` writes each invocation straight into
syslog with its own timestamp, so there is no project log file to wrap a
redirect around, and syslog already gives per-invocation boundaries (e.g.
`journalctl -t host-advance`) without hand-rolled start/end markers.

The line above elides the env header to keep the focus on the piping style —
it is not the whole installed file. The real `/etc/cron.d/metal-host-advance`
(written by `scripts/install-metal-host-advance-cron.sh`) DOES carry
`FY_LIVE=1`, because `advance-host-checkout.sh` calls `alert()` on its
anomaly paths and is on Rule 6's side-effecting allowlist. Do not read that
as "the whole script is gated," though: per `advance-host-checkout.sh:143-166`,
`FY_LIVE=1` governs only the `alert()`/ntfy channel — the git mutations
(fetch, `checkout -- public/`, self-heal, `pull --ff-only`) that are this
cron's entire purpose are deliberately ungated and run the same either way.
A missing `FY_LIVE=1` here would silence anomaly alerts, not the advance
itself.

**What each rule actually checks, per line** (corrected 2026-08-07 — this
section previously said Rule 2 only looks at `>>`, which stopped being true
the day Rule 2 was widened to also catch a `&&` chain piped to `logger`):

- **Rule 3** (start/end markers + `rc=$?`) only ever applies to a line
  containing a literal `>>`. A `| logger` line has no `>>`, so Rule 3 never
  engages for it — this part is unchanged.
- **Rule 2** applies to any line with a **top-level `&&` chain**, not just
  lines containing `>>`. It requires the chain's sink — `>>`, a bare `>`, OR
  a `|` pipe — to cover the WHOLE chain: a pipeline binds tighter than
  `&&`, so `A && B 2>&1 | logger` pipes only `B`'s output; `A`'s is
  discarded by cron (mailed to the operator, but there's no MTA on this
  host) — the exact same POSIX-precedence problem as the un-braced `>>`
  case in rule 2 above, not a different one. A line with **no** `&&` — like
  `metal-host-advance` above, a single command — has no chain for Rule 2 to
  check at all, so it reports 0 violations for that line regardless of
  whether it redirects, pipes, or does neither. That part is still true and
  still by design, not a gap: there is nothing to scope-mismatch when there
  is only one command. **This is a guarantee about one `&&` chain, not about
  the whole line**: `;`- and `||`-joined statements are entirely outside
  Rule 2's scope, and a correctly-wrapped `{ ... } | sink` group elsewhere on
  the same line satisfies the check by itself, so an independent unwrapped
  `;`-separated chain sharing that line has the identical redirect-scope
  problem but is not detected (see `scripts/check-cron-file.sh`'s own "Known
  gaps" comment; no production cron line in this repo has ever had this
  shape).

**A chained command piped to `logger` MUST still be wrapped**, exactly like
the `>>` case — either with `{ ... }` (sink placed right after the closing
brace) or by running the whole chain inside a single `bash -c "..."`
invocation (the chain is then opaque to cron; the outer pipe scopes that one
process). The real `freedom-yield-peer-geo` entry uses the second form:

```
GOOD:  bash -c "cd <repo> && python3 scripts/peer-geo.py && bash scripts/push-to-web-host.sh peer-geo.json" 2>&1 | logger -t peer-geo
GOOD:  { cmd1 && cmd2 ; } 2>&1 | logger -t <tag>
BAD:   cmd1 && cmd2 2>&1 | logger -t <tag>          # only cmd2 reaches the tag
```

Use the plain `| logger -t <tag>` form (no wrapper needed) only for a
**single command with no `&&` chain**, when syslog is an acceptable
destination; use `{ ... } >> logs/<name>.log 2>&1` or a wrapped/`bash -c`
pipe form from rules 1-3 above when the entry chains multiple scripts with
`&&` and needs a project-local, greppable log file (or syslog with all
commands' output preserved).

## Worked example: `/etc/cron.d/metal-evidence`

This block was captured on 2026-06-19 when the file was live-patched to
fix the `/var/log` redirect bug (see "Related lessons" below) — compliant
with every rule that existed at the time. **It was never updated for Rule
6** (`FY_LIVE=1`, added 2026-08-06, above): the block as it stood until
2026-08-17 invoked `push-to-web-host.sh` without the flag, and ran
unchanged through `scripts/check-cron-file.sh` failing Rule 6
(`references side-effecting script(s) (push-to-web-host.sh) but the file
has no 'FY_LIVE=1' line`) — a worked example in the doc that teaches this
project's cron conventions was, itself, non-compliant with one of the five
rules it documents. Corrected below to also satisfy Rule 6.

**This is a reference shape, not a live transcript of the deployed file.**
This repo has no host access to confirm byte-for-byte what
`/etc/cron.d/metal-evidence` holds on the validator host at any given
moment — read the block below as "what a compliant `metal-evidence` cron
file must contain," not as a current-state claim about production. (The
mechanisms that keep a doc's prescribed shape and the deployed file in
sync at all — `scripts/check-cron-file.sh` at install time, and this doc's
own review process — are the actual guarantee; this doc cannot substitute
for re-reading the live file when that matters.)

```cron
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
FY_LIVE=1
WEB_PUSH_KEY=/home/deploy/.ssh/<key>
WEB_HOST_FILE=/etc/freedom-yield/<host-file>
30 1 * * * deploy { \
    echo "=== metal-evidence start $(date -u +\%FT\%TZ) ==="; \
    cd /home/deploy/metal.freedom-yield.com && \
        bash scripts/gen-evidence.sh && \
        bash scripts/push-to-web-host.sh evidence.json; \
    rc=$?; \
    echo "=== metal-evidence end $(date -u +\%FT\%TZ) rc=$rc ==="; \
} >> /home/deploy/metal.freedom-yield.com/logs/gen-evidence.log 2>&1
```

`FY_LIVE=1` is required here because `push-to-web-host.sh` is on Rule 6's
side-effecting allowlist above — not because either script this cron runs
actually reads the variable. Neither does: `push-to-web-host.sh` has zero
`FY_LIVE`/`side-effects.sh` references (see the note under Rule 6 above),
and `gen-evidence.sh` likewise has zero. Both scripts run identically with
or without the flag; the flag's only effect here is satisfying Rule 6's
allowlist policy.

(The file as installed is one logical line; the line continuations above
are for readability — and that distinction is not cosmetic for testing:
feeding `scripts/check-cron-file.sh` the pretty-printed multi-line form
above verbatim fails Rule 3 (it inspects the physical line carrying the
redirect in isolation and does not see the start/end markers and `rc=$?`
that sit on earlier physical lines of the same logical command); joining
it back to one physical line first, exactly as it would be installed, is
required before linting. Verified with the two `<placeholder>` values
filled in and the continuations joined: `Result: 0 violation(s)`
(measured 2026-08-17). If you copy this block to test it, join it to one
line first, the same way you would before installing it.)

## Before installing a new cron file

Run the pre-flight linter against the file you intend to install:

```sh
scripts/check-cron-file.sh /tmp/proposed-cron-file
```

The linter checks rules 1, 2, 3, 4, 5, 6 above and refuses files that violate them. Install only after the linter passes:

```sh
sudo cp -a /etc/cron.d/<name> /root/<name>.cron.bak.$(date -u +\%Y\%m\%dT\%H\%M\%SZ)
sudo cp /tmp/proposed-cron-file /etc/cron.d/<name>
sudo chmod 0644 /etc/cron.d/<name>
sudo systemctl reload cron 2>/dev/null  # optional; cron auto-reloads on next minute
```

## After installing

Run the cron-equivalent body manually as `deploy` with a clean environment to confirm the fix:

```sh
sudo -u deploy env -i \
    SHELL=/bin/bash \
    PATH=/usr/local/bin:/usr/bin:/bin \
    HOME=/home/deploy \
    LOGNAME=deploy \
    USER=deploy \
    <ALL_PROJECT_ENV_VARS> \
    bash -c '<exact-command-body-from-cron-file>'
echo "manual_rc=$?"
```

A `manual_rc=0` plus a fresh entry in the log file proves the chain works end-to-end. The next scheduled cron firing should reproduce the same result.

## Related lessons

- `scripts/operator-local/gen-identity.sh` validates JSON with `jq empty`, not `jq -e empty` — the `empty` filter produces no output, so `-e` returns exit 4 on valid JSON.
- `scripts/sync-to-validator-host.sh` refuses to run if `REMOTE_PATH` looks like a local macOS path; the old default chain resolved to `${LOCAL_REPO_ROOT}/scripts/` and tried to mkdir that on the validator host.
- `.github/workflows/deploy.yml` rsync `--delete` requires every runtime-generated `public/api/*.json` to be individually excluded; otherwise each main-branch push wipes them off the web host.
