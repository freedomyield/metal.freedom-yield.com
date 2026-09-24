# Public-site probe: path classification, persistence gate, diagnostics — design

> **Status:** design spec, approved approach = "案 1" (validator-host-only, staged).
> **Origin:** 2026-09-24 investigation of three `公開サイトが応答しない` ntfy alerts
> (2026-09-21 18:00 / 19:50, 2026-09-23 17:50 JST). All three were real but
> 30–50 s path outages between the validator host (Singapore) and the web host;
> the origin (nginx + `caddy-static`) was healthy throughout. The location of the
> break (web-host ingress vs. international path) could not be determined from
> the evidence kept. Xserver maintenance was ruled out.
> **Out of scope (stage 2, only if needed):** a web-host self-probe (B2). It needs
> a new delivery path and notify config on a shared host, and the observed
> failures were not origin-side.

## 1. Problem

`scripts/check-anomalies.sh` (validator host, `/etc/cron.d/metal-anomalies`,
every 5 min) probes `https://metal.freedom-yield.com/health` once through
Cloudflare. If the probe fails, it waits 30 s and probes once more, and a
second failure raises a **high** push. This has four defects:

1. **One vantage, one path.** A Singapore→Tokyo path blip looks exactly like an
   origin outage.
2. **No persistence gate.** A 40 s blip that happens to span the 30 s re-probe
   pages the operator.
3. **No evidence captured.** Nothing records where the request died, so the
   cause can never be settled after the fact.
4. **No duration or classification.** State holds only `ok`/`warn`. The
   recovery push cannot say how long the outage lasted or what kind it was, and
   `/var/log/anomalies.log` keeps only 7 days.

## 2. Goals / non-goals

**Goals**
- G1: Short path blips (resolved before the next cron run) never push.
- G2: A real outage still pushes, with priority set by its classification.
  Latency rises from ~30 s to ~5 min (one extra cron run). This is accepted:
  about 6 real visits/day, and the operator's attention is the scarce resource.
- G3: Every failed observation stores enough diagnostics to tell Cloudflare-path,
  origin, and network-path failures apart.
- G4: The recovery push carries the outage duration and classification.
- G5: Anomaly log and diagnostics are kept for 90 days.

**Non-goals**
- No change to the web host, Cloudflare configuration, or `uptime.yml`.
- No change to the other anomaly checks (metalgo, caddy, disk, memory, peers,
  validator_present, period). The `api_freshness` web gate keeps its current
  semantics: it runs only when the Cloudflare probe returned 200 in this run.

## 3. Design

### 3.1 Probes (observation phase)

| Probe | Command shape | Meaning |
|---|---|---|
| `P_cf` | existing `curl … --max-time 10 ${WEB_URL}/health` | what a visitor sees (through Cloudflare, SIN colo from here) |
| `P_direct` | `curl --resolve ${WEB_HOST}:443:${WEB_ORIGIN_IP} https://${WEB_HOST}/health --max-time 10` | origin reachable from here, bypassing Cloudflare |

- `P_direct` runs only when `P_cf` is still failing after the existing 30 s
  re-probe. Healthy runs make no extra requests (polite access).
- `WEB_ORIGIN_IP` comes from the cron environment. It is **never committed**
  (host-identifier literal rule). If it is unset or empty, `P_direct` is
  skipped and its status is recorded as `skipped`.
- Every curl uses `-w` to record `http_code`, `time_namelookup`,
  `time_connect`, `time_appconnect`, `time_starttransfer`, `time_total`, and
  `remote_ip`. It also dumps response headers so that `cf-ray` (colo) is kept.

### 3.2 Classification

Classification uses only the second `P_cf` result (after the re-probe) and `P_direct`:

| P_cf (after re-probe) | P_direct | class | label (JA, used in pushes) |
|---|---|---|---|
| 200 | – | *(no incident / blip closed)* | – |
| fail | 200 | `cf_path` | Cloudflare 経路 (origin は正常) |
| fail | fail | `origin_or_path` | origin 停止 または シンガポール経路 (未判別) |
| fail | skipped | `unknown` | 判別不能 (origin 直接確認なし) |

When the class differs between runs of the same incident, the latest class
is kept and the history of classes is stored in `classes` (see 3.3).

### 3.3 State

A new **optional** top-level field is added to `anomaly-state.json`:

```json
"web_incident": {
  "started_at": 1789981200,   // epoch of the first failed observation
  "last_class": "origin_or_path",
  "classes": ["origin_or_path"],
  "runs": 1,                  // consecutive failed runs
  "pushed": false             // true once the outage push succeeded
}
```

- It is absent (or `null`) when no incident is open. The K-3.5 schema check
  **does not require it**, so existing state files stay valid and are not
  quarantined. If the field is present, the check validates its shape. A
  malformed `web_incident` is treated like any other schema mismatch
  (quarantine), consistent with §5.4 of `docs/MONITORING_OPS.md`.
- `.web` keeps its existing meaning: it is `warn` only once an outage push has
  succeeded. Its string type and its values do not change.
- All writes go through the existing candidate-state / `notify_or_keep`
  mechanism, so a field advances only when its notification succeeded
  (K-3 invariant).

### 3.4 Transitions

Let `now` be the run's observation epoch.

1. **P_cf == 200**
   - No incident is open. Nothing to do.
   - The incident is open and `pushed == false` (a blip that outlived one
     re-probe but not a whole cron interval). No push. Append one line to the
     blip log (3.5), then clear `web_incident`.
   - The incident is open and `pushed == true`. Push `default`
     `公開サイト復旧`, with a body giving the duration (`now - started_at`,
     shown as an upper bound: "約 N 分 (5 分刻みの観測)"), the classes seen, and
     the path of the diagnostics block. Set `.web` to `ok` and clear
     `web_incident`. Append to the blip log as well, so every incident is in
     one place.
2. **P_cf fails (after re-probe)**
   - Capture diagnostics (3.5).
   - No incident is open. Open one with `runs=1` and `pushed=false`. **No push.**
   - The incident is open and `runs >= 1`. Increment `runs`. If
     `pushed == false`, push, with the priority chosen by class:
     - `origin_or_path` or `unknown` → **high** `公開サイトが応答しない (5 分以上継続)`
     - `cf_path` → **default** `公開サイト: Cloudflare 経路で失敗継続 (origin は正常)`

     The body carries the class label, the duration so far, the key timings
     of both probes, the `cf-ray` colo, and the diagnostics path. On a
     successful push, set `pushed=true` and `.web="warn"`.
   - The incident is open and `pushed == true`. No new push, only
     diagnostics. This matches today's "already warn" behaviour.
3. **The existing 30 s re-probe** still runs only when there is no open
   incident and `.web == ok`. The rule is unchanged, just keyed on the
   incident too.

### 3.5 Diagnostics and logs

- **Diagnostics log** `/var/log/anomalies-web-diag.log`. There is one block
  per failed observation, delimited by `=== web-diag <UTC ISO> class=<c> ===`.
  Each block holds the timings and headers of both `P_cf` runs and of
  `P_direct`, plus `mtr -r -n -c 5 -w ${WEB_ORIGIN_IP}` (skipped when the IP is
  unset). The whole capture is bounded by `timeout 25`.
- **Blip log** `/var/log/anomalies-web-blips.log`. There is one line per closed
  incident: `<start UTC> <end UTC> duration_s=<n> classes=<a,b> pushed=<bool>`.
  This is what a future daily digest or a support inquiry to Xserver would
  read.
- **Retention (G5).** logrotate keeps `anomalies.log`,
  `anomalies-web-diag.log` and `anomalies-web-blips.log` for 90 days
  (`daily`, `rotate 90`, `compress`, `create 644 deploy deploy`). The single
  source is a new installer, `scripts/install-anomalies-logrotate.sh`
  (installer-script-first). The heredoc in `scripts/vps-bootstrap.sh` is
  updated to match, or changed to call the installer.
- **Worst-case runtime** is about 51 s today. It becomes about 51 + 10 + 25
  ≈ 90 s, well inside the 5-minute cadence, and K-4 flock already protects
  against overlap.

### 3.6 Configuration delivery

- `WEB_ORIGIN_IP` is added to `/etc/cron.d/metal-anomalies` as an env line.
  This goes through the existing cron env-header installer pattern
  (`scripts/install-cron-env-headers.sh`) or a small dedicated installer,
  whichever keeps `check-cron-file.sh` green. The value is supplied at install
  time and never committed.
- The script changes reach the validator host through the normal git advance
  on deploy, so **a push to `main` is a production change to monitoring** and
  is gated by operator approval. The logrotate and env installers are run on
  the host as root by the AI after that approval, and their effect is verified
  there.

## 4. Error handling

- A `P_direct` or `mtr` failure never aborts the run (`|| true`, with its own
  timeout). A diagnostics write failure is logged to stderr and never blocks
  the transition logic.
- A failed push leaves `pushed=false` and `.web` unchanged (K-3 invariant). The
  next run retries the push naturally.
- `WEB_ORIGIN_IP` unset → class `unknown` → behaviour is identical to
  `origin_or_path` (high after persistence). The failure is not hidden.

## 5. Testing

Unit tests go in `tests/anomalies/`. They extract the real block by its
`# === …` markers, stub `curl`, `mtr`, `timeout`, and the date, and use the
existing `notify_or_keep` / candidate helpers.

1. A blip that recovers inside the 30 s re-probe causes no incident and no push.
2. A blip that fails the re-probe and recovers on the next run causes no push,
   writes one blip-log line with `pushed=false`, and clears the incident.
3. `origin_or_path` persisting across 2 runs produces exactly one high push on
   run 2 and none on run 3.
4. `cf_path` persisting produces a default-priority push with the Cloudflare
   title.
5. Recovery after a push produces a default push whose body includes the
   duration and the classes, and resets `.web` to `ok`.
6. When the outage push fails (stub notify rc=2), `pushed` stays false and the
   next run pushes.
7. With `WEB_ORIGIN_IP` unset, `P_direct` is skipped, the class is `unknown`,
   and there is a high push on run 2.
8. A state file without `web_incident` passes K-3.5, and a malformed
   `web_incident` is quarantined.
9. The installer output passes `check-cron-file.sh` and `tests/cron-generators-lint`.

Every property test is proven by mutation, as the constitution requires:
break the property, watch the test fail, then restore. The Linux integration
suite (`integration-linux.sh`) gets one end-to-end case, where the local python
`/health` stub goes down for 2 runs.

## 6. Docs to update

- `docs/MONITORING_OPS.md`: the web probe section, the state schema (§5.4/§9),
  and the new log files.
- `docs/MONITORING_NOTIFY_CALLERS.md`: the new push titles.
- `reference_xserver_topology` memory: the container name is `caddy-static`.
  This is a memory update, not a repo change.

## 7. Rollout

1. Implement and test on a branch (SDD). Review, merge to `main`, and run the
   full suite green.
2. **Ask the operator before pushing.** The push advances the validator host
   via the deploy's git-advance.
3. After deploy, run the two installers on the validator host, then verify
   `check-cron-file.sh`, the logrotate dry run (`logrotate -d`), the new env in
   the cron file, and one live run's `rc=0` in `anomalies.log`.
4. Optional live check: none. The failure paths are covered by tests, and an
   outage is never induced on production.
