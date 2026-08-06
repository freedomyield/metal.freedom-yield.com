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

### 2. Wrap the work in a compound, redirect the compound

```
GOOD:  { ...stuff... } >> /home/deploy/.../logs/<name>.log 2>&1
BAD:   ...stuff... >> /home/deploy/.../logs/<name>.log 2>&1
```

Without the braces, the redirect attaches only to the last `simple command` in the chain (POSIX shell rule). Earlier commands' stdout is discarded by cron (mailed to the operator, but there's no MTA on this host). The braces are an explicit grouping so every command in the chain shares the log target.

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

`scripts/lib/side-effects.sh` (2026-08-06) gates every production side effect — an `ntfy` push via `notify.sh`, a web-host publish via `push-to-web-host.sh`, or a `/var/lib/freedom-yield` state-dir write — behind `FY_LIVE=1`. Anything else (unset, `0`, anything but the literal `1`) is a loud dry no-op: the suppressed action logs one `DRY: would ...` line to stderr and returns success. Only cron env headers are meant to carry `FY_LIVE=1`; a test or an interactive shell that doesn't set it stays hermetic by default.

A cron whose invoked command never notifies, never pushes, and never touches `/var/lib/freedom-yield` does not need the line. `scripts/check-cron-file.sh` Rule 6 enforces this: it fails a candidate cron whose command references a known side-effecting script (or one that sources `scripts/lib/side-effects.sh`) without a `FY_LIVE=1` line, and passes everything else without requiring the line.

**This is a per-file judgment, not a per-script one — distinguish the TEMPLATE from what is actually DEPLOYED.** `scripts/vps-bootstrap.sh`'s `step_node_info_cron` / `step_server_status_cron` templates, as currently written, only run `node-info.sh` / `server-status.sh` and overwrite a `public/api/*.json` file directly — no notify, no push, no state dir — so a cron generated fresh from either template does not need `FY_LIVE=1`. But the 2026-07-07 host audit (`docs/audits/constitution-2026-07-07-host-state-audit.md:36`) found the **live, deployed** `metal-node-info` cron additionally chains a `push-to-web-host.sh` publish leg that the template does not generate (one of 9 "publish 系" crons on that host). That deployed file DOES need `FY_LIVE=1` — Rule 6 already detects this correctly, because it reads the actual command line in front of it (`push-to-web-host.sh` is on Rule 6's allowlist) rather than trusting a script-name-based rule of thumb. `metal-server-status` is not on that publish list and remains genuinely out of scope in both the template and (per the same audit) the deployed file. Do not use "`node-info` is out of scope" as a general statement when reasoning about a specific host's cron — always check what that file's command line actually invokes.

## Alternative form: piping to `logger` instead of a log file

Rules 2 and 3 above only apply to lines that redirect into a project log
file with `>>`. A single-command cron line that instead pipes its output
straight to `logger` — e.g. the real `metal-host-advance` entry:

```
45 4 * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/advance-host-checkout.sh 2>&1 | logger -t host-advance
```

— has neither `&&` nor `>>` in it. In `scripts/check-cron-file.sh`, rule 2's
loop skips any line without `&&` before it ever checks for `>>` or brace
wrapping, and rule 3's loop skips any line without `>>` before it checks
for start/end markers or `rc=$?` capture. A `| logger -t <tag>` line with
no `&&` chain and no `>>` redirect therefore never enters either check —
`check-cron-file.sh` reports 0 violations for it, by design, not by gap.

This is intentional: `logger -t <tag>` writes each invocation straight into
syslog with its own timestamp, so there is no project log file to wrap a
redirect around, and syslog already gives per-invocation boundaries (e.g.
`journalctl -t host-advance`) without hand-rolled start/end markers. Use the
`| logger -t <tag>` form for a single command with no `&&` chain when
syslog is an acceptable destination; use the `{ ... } >> logs/<name>.log
2>&1` compound form from rules 1-3 when the entry chains multiple scripts
with `&&` and needs a project-local, greppable log file.

## Worked example: `/etc/cron.d/metal-evidence`

This is the file that exists today, post-fix:

```cron
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
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

(The file as installed is one logical line; the line continuations above are for readability.)

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
