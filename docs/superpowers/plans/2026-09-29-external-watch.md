# External watch (off-host validator watchdog) — spec + plan

Date: 2026-09-29. Status: approved direction by operator ("web host + GitHub reinforcement").

## Why

On 2026-09-24 10:56Z the validator host lost all connectivity beyond its
provider's edge for ~100 hours. metalgo kept running; every monitor we had
runs ON the validator host, so none of them could deliver a single push.
The GitHub `uptime.yml` stayed green the whole time (stale `validator.json`
only emits `::warning::` at >24h) and GitHub's `*/30` schedule actually fires
only every 4–8 hours. Nobody noticed for 4 days.

Goal: a watchdog that runs OFF the validator host, on the web host (different
provider, different region), and pushes to the operator's phone (ntfy) within
~10 minutes of the validator becoming unreachable, plus a recovery push.
GitHub `uptime.yml` becomes a slow, provider-independent backstop.

## Global Constraints (binding on every task)

G1. **Public repo.** No IP address, hostname of either host, ntfy topic,
    SSH user/key path of either host, or on-host path that reveals layout
    (Constitution §4.1 S5/S7/S8/S9) may appear in any committed file, commit
    message, test fixture, log line, or push body. Host-specific values come
    from install-time env on the operator's Mac and are stored only on the web
    host in mode-600 files. Tests use RFC5737 addresses (192.0.2.x /
    198.51.100.x / 203.0.113.x) and obviously fake topics.
    *Note (2026-09-29, final audit):* the relative web-host watch layout
    `$HOME/metal-fy-watch/{bin,etc,state,log,backup}` is published with
    operator approval (no host, no account identity); see the 2026-09-29
    entry under "Reclassifications" in `docs/CONSTITUTION.md`.
G2. **Provider/region names** (Constitution §4.2 C1) do not appear in new
    prose, identifiers, file names, titles or push bodies. Say "validator host"
    / "web host" / "外部見張り". (Existing `install-xserver-*` names are legacy;
    do not add new ones.)
G3. **Web host is multi-tenant** (Constitution §5). No system-wide change:
    no `/etc/cron.d`, no useradd, no firewall/nginx/service changes, no sudo.
    Everything lives under the site account's home in a project-prefixed
    directory `metal-fy-watch/`, runs as that account (`deploy`), and the only
    shared artifact touched is that account's crontab, edited strictly between
    the markers `# BEGIN metal-fy-external-watch` / `# END metal-fy-external-watch`.
    Lines outside the markers must be byte-identical before/after (verified).
G4. **No credentials toward the validator host on the web host** (Constitution
    §5). The watchdog only: reads a local file, opens a TCP connection, and
    reads a public RPC. It never listens on a port.
G5. **External API politeness** (docs/OPERATING_MODEL.md W9): the public
    P-chain RPC call is behind a TTL cache of 900 s. Requests filter by
    `nodeIDs` (otherwise delegators are omitted; see check-anomalies.sh
    L894-897).
G6. **No false urgency.** An alert fires only after the SAME check fails on 2
    consecutive runs. A recovery push fires on the first passing run after an
    alert, with the outage duration. State only advances if the push
    succeeded (mirror `notify_or_keep` in check-anomalies.sh).
G7. **Side-effect gate.** Nothing is sent unless `WATCH_LIVE=1`; otherwise print
    `DRY: would notify <prio> <title>` to stderr. Tests never set it.
G8. Tests: plain bash, `tests/<area>/test-*.sh`, executable, discovered by
    `bash tests/run-all-tests.sh`; stub `curl` via PATH like
    `tests/anomalies/test-api-freshness-broken.sh`. GNU date: Linux `date`, else
    `gdate`, else SKIP (existing pattern). `shellcheck -x` clean (validate.yml).
G9. **Every protective test is shown to fail once** against a deliberately
    broken implementation (mutation), and the report records the mutation, the
    failing output, and the restore. A test that cannot fail must say why.
G10. AI sessions cannot run shapes like `curl …/ext/bc/P` in Bash (broadcast-guard);
    the URL lives in the script, tests stub curl.

## Behaviour spec — `scripts/external-watch.sh`

Config: path `${WATCH_CONFIG:-$HOME/metal-fy-watch/etc/watch.env}`. Parsed as
strict `KEY=VALUE` lines (regex `^[A-Z_][A-Z0-9_]*=[^$\`;|&<>]*$`, comments and
blank lines allowed) — **never `source`d**. Unknown keys are an error.
Keys:
- `VALIDATOR_HOST` (required; IPv4 dotted quad or DNS name)
- `VALIDATOR_P2P_PORT` (default 9651)
- `VALIDATOR_JSON` (required; absolute path of the pushed validator.json)
- `NTFY_TOPIC_FILE` (required; absolute path, must be mode 600 or 400, owned by
  the running user — otherwise config error)
- `NODE_ID` (default the public NodeID already used in check-anomalies.sh)
- `RPC_URL` (default `https://api.metalblockchain.org/ext/bc/P`)
Runtime dirs (created 700 if missing): `$WATCH_HOME/state`, `$WATCH_HOME/log`
where `WATCH_HOME=${WATCH_HOME:-$HOME/metal-fy-watch}`. Non-blocking `flock`
on `$WATCH_HOME/state/lock`; if held, exit 0 silently.

Checks every run (cron `*/5`):
- **fresh** — `observedAt` of `VALIDATOR_JSON`. FAIL if file missing,
  unparseable, `observedAt` missing/unparseable, or age > 900 s. SUPPRESSED
  (treated as UNKNOWN, counter untouched, no push) when `.endTime` is present
  and `endTime-1800 <= now <= endTime+21600` (renewal window: node-info.sh
  legitimately stops refreshing while the cycle gate defers).
- **p2p** — TCP connect to `VALIDATOR_HOST:VALIDATOR_P2P_PORT`, 5 s timeout;
  on failure re-probe once after `${P2P_REPROBE_SLEEP:-10}` s; FAIL only if
  both fail. Never suppressed.
- **chain** — public RPC `platform.getCurrentValidators` with
  `{"nodeIDs":[NODE_ID]}`, `--max-time 10`, cached 900 s in
  `state/rpc-cache.json` (cache written only on a valid response). FAIL only
  if the response is valid, the validator entry is present and
  `.connected == false`. RPC error / invalid JSON / validator absent → UNKNOWN
  (no counter change, no push; logged).

State `state/state.json` per check: `{status:"ok"|"alerting", fails:int,
first_fail_at:epoch|null}`. Transitions:
- FAIL: `fails+=1`, set `first_fail_at` if null. If `fails>=2` and status ok →
  push; on push success status=alerting.
- PASS: if status alerting → recovery push (duration = now-first_fail_at,
  human "N時間M分"); on success reset `{ok,0,null}`. If status ok → reset
  counters.
- UNKNOWN: no change.
State written atomically (mktemp in state dir + mv, 600). Corrupt state →
moved aside to `state/state.json.corrupt-<epoch>` and re-initialised (logged).

Push content (Japanese, no host/IP/port/path/topic):
- p2p: urgent, title `外部見張り: validator に外から届かない`
- chain: urgent, title `外部見張り: ネットワーク上で未接続 (connected=false)`
- fresh: high, title `外部見張り: validator.json の更新が止まっている`
- recovery: default, title `外部見張り: 復旧 (<check>)`, body includes duration.
Body: which check, since when (UTC ISO), and "validator host の外 (web host) から検知".
Delivery through a bundled copy of `scripts/notify.sh` located next to the
watch script (`$(dirname "$0")/notify.sh`), with `NOTIFY_STRICT_EXIT=1` and
`NTFY_TOPIC_FILE` exported; retry once after 5 s on exit 2/4/5; overridable by
`WATCH_NOTIFY` (test stub). Push failure → exit 6, state not advanced.

Log: one line per run appended to `log/watch.log`:
`<ISO> fresh=<PASS|FAIL|UNKNOWN>(<age>s) p2p=<…> chain=<…> pushes=<n>` — no host,
no IP. Trim to last 5000 lines when > 6000. Exit: 0 ok, 1 config error, 6 push failed.

## Tasks

### Task 1: `scripts/external-watch.sh` + tests
Files: `scripts/external-watch.sh`, `tests/external-watch/test-*.sh` (new dir).
Implement the behaviour spec exactly. Tests must cover at least: config parser
rejects injection (`$(...)`, backticks, `;`), unknown key, loose topic-file
mode; fresh PASS/FAIL/renewal-suppressed; p2p PASS against a local listener and
FAIL against a closed local port (use 127.0.0.1 in tests — loopback is not a
host identifier) with re-probe; chain FAIL on connected=false, UNKNOWN on RPC
error and on validator absent, cache honoured within 900 s; 2-consecutive rule
(1 fail → no push, 2 → push, 3 → no second push); recovery push with duration;
push failure keeps state and exits 6; DRY without WATCH_LIVE; log line
contains no `VALIDATOR_HOST` value; lock contention exits 0. Apply G9.

### Task 2: `scripts/install-web-host-external-watch.sh` + tests (after Task 1)
> **Superseded in part (operator decision 2026-09-29, final fix wave):** the
> watch gets its OWN ntfy topic, generated on the web host by the installer
> and handed to the operator only through the Mac clipboard (`--copy-topic`).
> The installer never contacts the validator host: `VALIDATOR_SSH_USER`,
> `VALIDATOR_SSH_KEY` and step (1) below no longer exist. The current
> behaviour is documented in `docs/MONITORING_OPS.md` §14.5.

Mac-run installer, pattern of `scripts/install-xserver-subdir-allowlist.sh`
(ssh BatchMode, heredoc remote, `--dry-run`, `--print-remote`, backups,
idempotent, unified diff) plus `--uninstall`.
Env (all required unless noted, none echoed): `WEB_HOST`, `WEB_HOST_USER`
(default root), `WEB_HOST_KEY` (required, no default), `WATCH_ACCOUNT` (default
deploy), `VALIDATOR_HOST`, `VALIDATOR_SSH_USER`, `VALIDATOR_SSH_KEY`.
Steps: (1) read the ntfy topic from the validator host's topic file over ssh
and stream it straight into the web host's `etc/ntfy-topic` over ssh stdin —
never written to Mac disk, never in argv, never printed; (2) detect
`VALIDATOR_JSON` from the push wrapper's `__fy_root` like
install-xserver-subdir-allowlist.sh (override `FY_WEB_API_DIR`); (3) install
`bin/external-watch.sh`, `bin/notify.sh`, `etc/watch.env` under
`~WATCH_ACCOUNT/metal-fy-watch/` (dirs 700, files 600, scripts 700, owner
WATCH_ACCOUNT); (4) crontab block between the G3 markers:
`*/5 * * * * WATCH_LIVE=1 /bin/bash $HOME/metal-fy-watch/bin/external-watch.sh >>$HOME/metal-fy-watch/log/cron.err 2>&1`;
backup `crontab -l` to `metal-fy-watch/backup/crontab.bak-<ts>`, verify lines
outside the markers byte-identical, abort + restore otherwise; (5) run the
watch once WITHOUT WATCH_LIVE as the account and print its log line.
`--uninstall`: remove the block (same verification) and `metal-fy-watch/`
after backing up the crontab. Test mode `SKIP_SSH=1` with a fake home and a
fake `crontab` on PATH. Output masks host values (print `<validator host>`).
Apply G9 (e.g. breaking the outside-marker check must fail a test).

### Task 3: GitHub `uptime.yml` backstop + guard coverage (parallel with Task 1)
Files: `.github/workflows/uptime.yml`, `tests/uptime-workflow/test-uptime-freshness.sh`,
and if needed `scripts/publish-guard.sh` + its tests.
(a) Replace the >24h warning: missing/unparseable `observedAt` → `::error::`
fail; age > 3600 s → fail, EXCEPT inside the renewal window
(`endTime-1800 <= now <= endTime+21600`) → `::notice::`. Keep the step
extractable (single awk-extractable block, like test-uptime-body-check.sh).
(b) Verify `scripts/publish-guard.sh` (which CI already runs, ci-main.yml
L67-120) rejects an ntfy topic literal of the form `fy-metal-<32 hex>`; if
not, add that rule with a test. Do not weaken any existing rule.
Apply G9.

### Task 4: docs (after Tasks 1-3)
`docs/MONITORING_OPS.md` (new section: off-host watch, scope amendment of §1,
operator runbook: install / verify / uninstall commands with env placeholders
only), `docs/MONITORING_NOTIFY_CALLERS.md` (dated addendum: new caller),
`TOOLKIT.md` (script + installer entries), `docs/DEPLOY_OWNERSHIP_MATRIX.md`
(web host now runs one project-scoped cron under the site account). G1/G2 apply
to every line.

## Final audit team (after Task 4, independent, no implementation)
security (public repo + web host), constitution (constitution-auditor),
correctness (false alarm / missed alarm), test efficacy (mutations).
