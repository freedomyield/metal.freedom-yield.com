# Monitoring operations — anomaly pipeline hardening

This document is the design reference for the validator-host anomaly notification pipeline (`scripts/check-anomalies.sh` + supporting scripts). It describes the input/output gates (K-1 through K-4), the candidate-state commit model used by transition processing, the lock-file lifecycle, the operator-only state initialisation script, and the exit-code contract. It is the source of truth for the implementation; if the code disagrees, the code is wrong.

The doc covers design only. It does not change cron schedules, production state files, production thresholds, or any live infrastructure.

## 1. Scope and non-goals

**In scope**

- The flow used by `scripts/check-anomalies.sh` (= 5-minute cron on the validator host) to read inputs, validate state, process transitions, and emit notifications.
- The supporting operator-only script `scripts/anomaly-state-init.sh` used to bootstrap or reset the baseline state.
- The lock, counter, and quarantine files that live outside the state file but are part of the pipeline's persistent footprint.

**Out of scope (= tracked elsewhere)**

- The validator itself, its on-chain artefacts, the renewal pipeline, the anchor pipeline, the cycle history pipeline.
- The site / web host / Caddy / nginx layer.
- The disaster-recovery drill (= separate workstream, tracked in `docs/DISASTER_RECOVERY.md` + the residual T1 follow-up).

## 2. Pipeline overview

```
cron (every 5 min, deploy user)
   │
   ▼
[K-1]  STATUS_JSON syntax + schema gate          ─ exit 2 on fail
   │
   ▼
[K-2]  STATUS_JSON freshness gate                ─ exit 2 or 3 on fail
   │
   ▼
[K-4]  Non-blocking flock                        ─ exit 0 (skip, +counter) | exit 5 (lock dir not openable)
   │
   ▼
[K-3.5] State-file presence + schema validation  ─ exit 4 (corrupt) | exit 7 (missing)
   │
   ▼
[K-3]  Transition processing                     ─ exit 0 | exit 6 (notify perm-fail) | exit 8 (state commit fail)
   │   (each transition: detect → notify → tentatively update candidate state)
   │
   ▼
       Atomic commit of candidate state          ─ single mktemp + mv at end of run
   │
   ▼
       exit 0 (success) / 6 (some transition notify failed) / 8 (state commit failed)
```

K-1, K-2 are already implemented and unchanged. K-4 is added in commit C1. K-3.5 is added in commit C2. K-3 (= candidate-state model) is the C4 commit; it is documented here so K-3.5 and K-4 can be designed in alignment with it.

## 3. Exit code contract

| Code | Meaning | State mutation | Notify side effect |
|---|---|---|---|
| 0 | Normal completion **or** K-4 skip (= previous run still holds lock) | normal / none | normal (= when reached K-3) / none (= when skipped) |
| 2 | K-1: STATUS_JSON missing / unreadable / not JSON / missing fields / wrong types | none | none |
| 3 | K-2: STATUS_JSON stale (age > MAX_AGE_SEC) or future skew (> FUTURE_SKEW_MAX_SEC) | none | none |
| 4 | K-3.5: state file present but invalid (= JSON parse fail or schema fail) | none (= original file preserved) | best-effort, only on new SHA-256 |
| 5 | Structural: lock dir missing / unopenable, or state dir missing | none | none |
| 6 | K-3: one or more transitions' notify attempts permanently failed (= still failing after one in-run retry) | per-transition: failed transitions keep old value; succeeded transitions keep new value; atomic commit at end | (per-transition outcome) |
| 7 | K-3.5: state file missing | none | best-effort, only on first detection after init (= missing-marker dedup) |
| 8 | State commit failure (= mktemp / jq / mv / chmod) | partial possible only if commit succeeded for some other process; for this run, final commit failed → no fields advanced | (= notifies already sent; next run may re-detect → duplicate) |

When multiple conditions apply, the script exits with the highest applicable code in this priority order: `8 > 7 > 6 > 5 > 4 > 3 > 2 > 0`.

## 4. K-4: non-blocking flock + contention observability

### 4.1 Lock placement

- File: `${ANOMALY_LOCK_FILE:-/var/lib/freedom-yield/locks/check-anomalies.lock}`
- Dir:  `/var/lib/freedom-yield/locks/` (= owner `deploy:deploy`, mode 0700, persistent across reboots)
- The lock dir is sibling to the state dir, not nested inside it. This isolates lock lifecycle from any state mutation operation (= state init, quarantine, reset).
- The lock file is **never deleted** by any pipeline script. `flock` acts on an open file descriptor; the file's existence is the durable handle. State init / reset / quarantine operations do not touch the lock file.
- Lock dir must be created once during operator setup (= `sudo mkdir -p /var/lib/freedom-yield/locks && sudo chown deploy:deploy /var/lib/freedom-yield/locks && sudo chmod 0700 /var/lib/freedom-yield/locks`). The lock file is auto-created on first open by `check-anomalies.sh` (`exec 9>"$LOCK_FILE"`).

### 4.2 Acquisition

```bash
LOCK_FILE="${ANOMALY_LOCK_FILE:-/var/lib/freedom-yield/locks/check-anomalies.lock}"
LOCK_DIR="$(dirname "$LOCK_FILE")"

# Lock dir must exist; missing dir is a structural error, not a transient skip.
if [ ! -d "$LOCK_DIR" ]; then
  echo "[K-4] lock dir missing: $LOCK_DIR (run anomaly-state-init.sh on a fresh host); exit 5" >&2
  exit 5
fi

# Try to open the lock file for write (creates if absent). Failure here = perms.
if ! exec 9>"$LOCK_FILE"; then
  echo "[K-4] cannot open lock file: $LOCK_FILE; exit 5" >&2
  exit 5
fi

# Non-blocking exclusive lock.
if ! flock -n 9; then
  echo "[K-4-SKIP] previous run still holds lock ($LOCK_FILE); incrementing contention counter; exit 0" >&2
  bump_contention_counter
  exit 0
fi

echo "[K-4] lock acquired" >&2
# Lock is released automatically when fd 9 closes on process exit.
```

### 4.3 Contention counter

- File: `${ANOMALY_CONTENTION_COUNTER:-/var/lib/freedom-yield/anomaly-contention-counter}` (= sibling to state dir, plain integer, single line)
- Increment uses its own flock on `${counter}.lock` to avoid concurrent write races.
- Counter file is created on first bump if absent. Initial value 0.
- Failure to bump the counter is logged to stderr but **does not abort the main pipeline** (= observability is best-effort; the cron's primary job is anomaly detection, not its own observability).

Reset is operator-driven (`scripts/anomaly-contention-reset.sh` may be added later but is out of scope for the C1 commit). Reading the counter is operator-driven (`cat /var/lib/freedom-yield/anomaly-contention-counter`).

Why a counter rather than a JSONL log: cheaper write, no log rotation needed, sufficient for the only known consumer (= weekly operator glance). JSONL with per-event timestamp is an explicit future enhancement, deferred until a use case actually requires it.

### 4.4 Test surface

- `K4-1` pre-held lock → next process skips (exit 0, counter +1, no state mutation, no transition processing)
- `K4-2` lock dir non-writable → exit 5
- `K4-3` consecutive normal runs (= 2 runs back-to-back, both complete)
- `K4-4` pre-held → released → next run completes normally (= 1st skip, 2nd normal, counter +1 once)
- `K4-5` 3 consecutive contentions → counter +3

CI runs all five with `$TMP/lock` and `$TMP/counter` (= no touch of production files).

## 5. K-3.5: state-file presence + schema validation + SHA-256 dedup

### 5.1 Sub-cases

| Case | Trigger | State | Quarantine | Notify | Exit |
|---|---|---|---|---|---|
| 5.1.a | State dir missing | (= operator never ran init or it was deleted) | none | none | none | 5 |
| 5.1.b | State file missing, no missing-marker | first detection after init or after manual removal | none | none | best-effort 1 (= one push) + create marker | 7 |
| 5.1.c | State file missing, marker present | recurring missing | none | none | none (= stderr log only) | 7 |
| 5.1.d | State file invalid (= JSON parse fail or schema fail), new SHA-256 | first detection of this exact corruption | unchanged | new quarantine dir | best-effort 1 | 4 |
| 5.1.e | State file invalid, recurring SHA-256 | same exact bytes as a previously quarantined corruption | unchanged | none | none (= stderr log only) | 4 |

### 5.2 Quarantine dir layout

```
${ANOMALY_STATE_DIR}/quarantine/
├── README.md                                           # one-time, life-cycle note
└── <full-sha256-of-corrupt-state>/                    # = directory identity is full SHA-256
    ├── state.json                                      # exact copy of the corrupted file
    ├── diag.txt                                        # parse/schema error + first 400 bytes
    └── first-seen-at.txt                               # ISO-8601 UTC timestamp of first detection
```

- Identity = **full 64-char SHA-256 hex** of the corrupted file's bytes. This is the dedup key and the directory name.
- The 8-char prefix (= `sha8`) is included in stderr log lines and notification bodies for human readability only. It is never used as a dedup key — collisions in the 8-char space are not impossible, and the on-disk identity must be deterministic.
- Existence check is a deterministic path test: `[ -d "${QUAR_DIR}/${FULL_SHA}" ]`. No glob, no listing.
- A recurrence (= same full SHA) writes nothing new, increments nothing, sends no notification. It only emits a stderr log line so the operator can see the recurrence rate via the cron log if they look.

### 5.3 Missing-marker file

- Path: `${ANOMALY_STATE_DIR}/.missing-notified.marker`
- Purpose: dedup the "state file missing" notification so the operator is not paged every 5 minutes when the file has been removed (= e.g. operator started reset and was interrupted).
- Created when 5.1.b fires.
- **Removed by `scripts/anomaly-state-init.sh` on successful init.** This is the only path that clears the marker; the cron never clears it. After init, a future re-disappearance reopens the dedup → a new push fires (= correct re-notification on re-occurrence).
- The marker is **not** placed under `quarantine/`; it is a sibling of the state file under the state dir root.

### 5.4 State-file schema (= minimum the cron requires)

The state JSON must be parseable and must contain at least:

```jsonc
{
  "metalgo": "running|stopped|<arbitrary string>",
  "caddy": "running|stopped|<arbitrary string>",
  "disk": "ok|warn",
  "memory": "ok|warn",
  "peers": "ok|warn",
  "web": "ok|warn",
  "api_freshness": "ok|warn",
  "validator_present": "yes|no",
  "last_known_end_time": <integer or null>,
  "delegator_count": <integer or null>,
  "delegator_total_nmetal": <integer or null>,
  "period_alert_sent": {
    "7": <boolean>, "1": <boolean>, "0": <boolean>, "10min": <boolean>
  }
}
```

K-3.5 validation: top-level fields present with the expected types. The script's K-3 transition logic relies on every top-level field; missing field → schema fail → quarantine.

### 5.5 Bootstrap is operator-only

The cron does **not** auto-create a baseline state. That responsibility lives in `scripts/anomaly-state-init.sh`, run manually by the operator. See §7.

### 5.6 Notify behaviour

For 5.1.b and 5.1.d: the notification attempt is best-effort. Its success or failure does **not** change:

- the exit code (= still 7 or 4 respectively)
- the on-disk preservation (= original state file or quarantine dir remains unchanged regardless of notify outcome)
- the marker creation (= 5.1.b creates the marker whether or not the notify succeeded — the dedup is about the operator's pager, not about the diagnostic on disk)

Rationale: notification delivery is a separately-degraded path. The durable record is on disk. The operator can discover quarantine dirs / marker files even if every push for the last week was dropped on the floor.

## 6. K-3: transition processing with candidate-state commit

### 6.1 Model

Each cron run:

1. Read on-disk state into an in-memory candidate (= a temp JSON file copy of the live state).
2. Process every transition rule. For each rule:
   - Read the current field value from the **candidate** (not from disk).
   - Detect whether a transition fires.
   - If yes, call `notify_and_state(prio, title, body, jq_field_path, new_value_json)`:
     - At most 2 attempts in a single run: 1 initial + 1 in-run retry on retryable failures.
     - Retry is gated by exit code or HTTP status. Curl `--max-time` provides a bounded per-attempt timeout.
     - On success (= notify delivered): mutate the **candidate** field to the new value.
     - On permanent failure: do **not** mutate the candidate field; record the failure into `GLOBAL_NOTIFY_RC=6`.
3. After all transitions have been processed: atomically commit the candidate to disk:
   - `mktemp -p "$STATE_DIR" .state.commit.XXXXXX`
   - `cp` candidate → tmp
   - Best-effort `sync` of tmp (= durability is best-effort, see §6.5)
   - `mv tmp "$STATE_FILE"` (= same-filesystem atomic rename)
   - Best-effort `sync` of state dir
   - On any commit step failure: leave `$STATE_FILE` untouched, set `GLOBAL_NOTIFY_RC=8`, log to stderr.
4. Exit with `GLOBAL_NOTIFY_RC` (= 0 on full success; 6 if any transition permanently failed; 8 if the final commit itself failed).

### 6.2 Independence of transitions

A failure of one transition's notify does not affect the next transition's processing. Each transition reads from the candidate and writes to the candidate independently. The script never aborts mid-run on a single notify failure; it continues to the next transition.

This implies the candidate may end up with a heterogeneous mix of new and old field values: successful transitions advance, failed transitions stay. The single end-of-run commit writes this heterogeneous candidate atomically.

### 6.3 Duplicate semantics

There is **no fixed upper bound** on how many notifications a single event may produce over its lifetime. The correct way to state the bound:

- **Per single cron run**: at most 2 attempts per transition (= 1 initial + 1 retry).
- **Per event lifetime**: if a transition keeps failing across cron runs (= permanent notify failure each run), the same transition re-detects + re-attempts every 5 minutes. There is no in-script counter that caps the lifetime attempts. At-least-once delivery means there is also no guarantee against duplicates, and at-most-once is not provided.

Operator-side dedup is provided by ntfy.sh's own ~12-hour history cache (= identical message bodies appear once in the Android client over that window). This is not a script-level guarantee.

### 6.4 Atomic commit details

```bash
commit_candidate_state() {
  local candidate="$1"   # path to the in-memory candidate temp file
  local target="$STATE_FILE"
  local tmp
  tmp=$(mktemp -p "$STATE_DIR" ".state.commit.XXXXXX") || {
    echo "[state] mktemp failed in $STATE_DIR; commit aborted" >&2
    return 8
  }
  if ! cp "$candidate" "$tmp"; then
    rm -f "$tmp"
    echo "[state] cp candidate -> tmp failed" >&2
    return 8
  fi
  # Best-effort durability. `sync` of a single file is supported on Linux but
  # not on all platforms; ignore errors. See §6.5 for the honest framing.
  sync "$tmp" 2>/dev/null || true
  if ! mv "$tmp" "$target"; then
    rm -f "$tmp"
    echo "[state] atomic rename $tmp -> $target failed" >&2
    return 8
  fi
  chmod 0644 "$target" 2>/dev/null || true
  sync "$STATE_DIR" 2>/dev/null || true
  return 0
}
```

### 6.5 Durability framing

The commit is **atomic from the perspective of any concurrent reader** of `$STATE_FILE` (= POSIX same-filesystem rename guarantees the reader sees either the old inode or the new one, never a partial write). It is **best-effort durable** with respect to a system crash between the rename and the underlying filesystem flush: we call `sync` on the tmp and the dir, but the actual durability depends on the kernel + filesystem combination and is not guaranteed by this script. The script does not call `fsync(2)` directly (= bash has no portable wrapper) and does not advertise "fsync guarantee". If a crash occurs between rename and flush, the state may revert to the pre-commit value on next boot. This is acceptable for the cron's use case (= 5-minute cadence; next run re-detects and re-notifies if anything was lost).

### 6.6 Counter / non-state mutations

The `delegator_count` and `delegator_total_nmetal` fields are written every run regardless of notify outcome (= they are observed values, not transition states). In the candidate model they are still written via candidate field set + atomic commit at end. They do not participate in retry semantics.

## 7. anomaly-state-init.sh (operator-only)

### 7.1 Purpose

Single operator-driven entry point to:

- Create state dir + lock dir + counter file (if absent) with correct ownership and permissions.
- Write a baseline state JSON.
- Remove the missing-marker file (= unblock future "missing" notifications).
- Optionally clear stale quarantine dirs (= behind an explicit `--clear-quarantine` flag, off by default).

### 7.2 Concurrency

The init script **acquires the same `ANOMALY_LOCK_FILE` non-blocking** as the cron. If the lock is held, init refuses to proceed and exits non-zero without touching state. This guarantees init and cron never run concurrently.

The lock is **not deleted** by init. Init opens it for write (creating if absent) and holds it via `exec 9>"$LOCK_FILE"; flock -n 9`. On exit, the fd closes and the lock releases. The file persists.

### 7.3 Sequence (= within a single lock hold)

```
1. acquire ANOMALY_LOCK_FILE non-blocking (exit if held)
2. mkdir -p state dir + lock dir (= idempotent; chmod 0700 lock dir, 0750 state dir)
3. validate operator confirmation flag (--confirm required; refuse otherwise)
4. construct baseline state JSON in a tmp file
5. atomic mv tmp -> $STATE_FILE
6. remove ${ANOMALY_STATE_DIR}/.missing-notified.marker if present
7. (optional, --clear-quarantine) rm -rf ${ANOMALY_STATE_DIR}/quarantine/*
8. log success + recap (= state path, lock path, counter path, marker removed yes/no)
9. release lock (= fd close on exit)
```

Init does **not** modify the contention counter, does **not** touch any in-progress quarantine dirs unless `--clear-quarantine` is passed.

### 7.4 Required flags

- `--confirm` — operator must pass this explicitly. Without it, the script prints what it would do and exits non-zero. Prevents accidental run from history.
- `--baseline-status=running|stopped` — operator declares the baseline assumption for the metalgo/caddy fields (= default `running` when bootstrapping after a known-good cycle; `stopped` only when bootstrapping after a known-down recovery).
- `--clear-quarantine` (optional) — wipe quarantine dirs as part of init. Default off.
- `--clear-counter` (optional) — reset contention counter to 0. Default off.

### 7.5 Cron integration

The init script must **not** appear in any cron file. The cron in `/etc/cron.d/metal-anomalies` runs `check-anomalies.sh` only. Init is a manual operator step, documented as part of the resume-from-pause runbook.

## 8. Test harness policy

### 8.1 Environment isolation

| Resource | Production | CI test | Operator manual E2E |
|---|---|---|---|
| State dir | `/var/lib/freedom-yield/` (Hetzner) | `$TMP/state` (mktemp) | `$TMP/state` (mktemp) |
| Lock file | `/var/lib/freedom-yield/locks/check-anomalies.lock` | `$TMP/locks/test.lock` | `$TMP/locks/test.lock` |
| Counter file | `/var/lib/freedom-yield/anomaly-contention-counter` | `$TMP/counter` | `$TMP/counter` |
| STATUS_JSON | `public/api/server-status.json` (live) | fixture under `tests/anomalies/fixtures/` | fixture under `tests/anomalies/fixtures/` |
| VALIDATOR_JSON | `public/api/validator.json` (live) | fixture | fixture |
| ntfy topic file | `/etc/freedom-yield/ntfy-topic` | unused (= notify path stubbed) | `/etc/freedom-yield/ntfy-topic-test` (= operator-placed, test-only topic) |
| ntfy transport | real ntfy.sh | **stub** (= no HTTP call) | real ntfy.sh on test-only topic |
| Thresholds (MAX_AGE_SEC, peer min, disk pct, etc.) | production values | fixture-aligned overrides via env | production values, but **never write to production state / lock / counter** |

### 8.2 CI uses stub notify

`tests/anomalies/stub-notify.sh` mimics notify.sh's argv but does not call `curl`. It appends invocation records to `$TMP/notify-calls.log` and returns an exit code controlled by `STUB_NOTIFY_EXIT` (= default 0). CI test harness sets `NOTIFY=$TMP/stub-notify.sh`. Production `scripts/notify.sh` is never invoked by CI.

### 8.3 Operator-manual E2E

A small subset of tests (= INT-1 single transition end-to-end) runs against the real ntfy.sh transport. Required pre-conditions:

- Operator has created `/etc/freedom-yield/ntfy-topic-test` containing a topic distinct from the production topic.
- Test messages carry a `TEST:` prefix in the title and an `evt-<8hex>` unique event id in the body, so a delivered test push is unambiguously identifiable.
- Production state, lock, counter, marker, and quarantine dir are not touched at any point.

This subset runs only when the operator explicitly invokes the manual E2E entry point. CI does not run it.

## 9. Schema-stability discipline

This pipeline maintains three on-disk JSON shapes that consumers depend on:

- `${ANOMALY_STATE_DIR}/anomaly-state.json` — the live state; consumed only by `check-anomalies.sh` itself, so the shape is private to this pipeline. Changes that add fields are additive; changes that remove fields require migration of all in-the-wild state files.
- `${ANOMALY_STATE_DIR}/quarantine/<sha>/state.json` — exact copy of the corrupted state file; no schema (= it is by construction not conformant).
- `${ANOMALY_STATE_DIR}/quarantine/<sha>/diag.txt` — free-form diagnostic; not schema-stable.

The cron writes ISO-8601 UTC for the few timestamp fields it owns (= `first-seen-at.txt`).

## 10. Operator setup runbook (= one-time per host)

```bash
# All commands run as root unless prefixed sudo -u deploy.
DEPLOY_USER=deploy
STATE_BASE=/var/lib/freedom-yield

mkdir -p "$STATE_BASE"
mkdir -p "$STATE_BASE/locks"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$STATE_BASE"
chmod 0750 "$STATE_BASE"
chmod 0700 "$STATE_BASE/locks"

# Initialise baseline state (operator-driven, not cron-driven).
sudo -u "$DEPLOY_USER" bash scripts/anomaly-state-init.sh \
  --confirm \
  --baseline-status=running

# Optional: wipe any prior quarantine dirs / reset counter at the same time.
# sudo -u "$DEPLOY_USER" bash scripts/anomaly-state-init.sh \
#   --confirm --baseline-status=running \
#   --clear-quarantine --clear-counter

# Confirm baseline:
sudo -u "$DEPLOY_USER" jq . "$STATE_BASE/anomaly-state.json"
ls -la "$STATE_BASE/locks/"
[ -f "$STATE_BASE/.missing-notified.marker" ] && echo "marker still present (bug)" || echo "marker cleared OK"
```

After this setup, the cron line in `/etc/cron.d/metal-anomalies` may be un-commented by the operator. The cron uses the same `ANOMALY_STATE_DIR=/var/lib/freedom-yield` env (= or whatever path the operator standardised).

## 11. Resume-from-pause checklist (= operator-driven)

1. Confirm K-3.5, K-3, K-4 are implemented in `scripts/check-anomalies.sh` at the expected commit SHA.
2. Confirm `scripts/anomaly-state-init.sh` exists and is executable.
3. Run a dry-run on the validator host with the cron line still commented:
   - `sudo -u deploy ANOMALY_STATE_DIR=/var/lib/freedom-yield bash scripts/check-anomalies.sh; echo "rc=$?"`
   - Expect rc=0 in steady state, or rc 2/3/4/5/7 with clear stderr indicating the cause.
4. Verify lock file is created and contention counter behaves (= run twice in quick succession; expect second invocation to skip).
5. Run the operator-manual E2E single-transition test (= optional but recommended), confirm Android receives a TEST-prefixed push.
6. Un-comment the cron line in `/etc/cron.d/metal-anomalies`.
7. Mark the public incident `under_remediation → resolved` once 24 hours of clean cron behaviour are recorded.

## 12. Out of scope for the C0..C3a batch

The current commit batch does not implement:

- K-3 (= the candidate-state commit transition processing). Implementation lands in commit C4, after caller compatibility for `notify.sh` (= C3a inventory + C3b exit-code change) is decided.
- The fixture test harness (= commit C6).
- The formal `incidents.schema.v1.json` and incident drafts (= commits C7, C8).
- The daily-status root-cause fix (= deferred to a separate session per operator decision Q9).

These are tracked separately and require additional operator approval before they are implemented.

## 13. Cross-references

- `docs/CONSTITUTION.md` §3.3 — secrets policy (state files contain no secrets, but the `/etc/freedom-yield/ntfy-topic` file is treated as a shared secret and is not in any repo file).
- `docs/INCIDENT_RESPONSE.md` — operator playbook for SEV-1..4 events; the cron's role is detection, not response.
- `docs/DISASTER_RECOVERY.md` — separate workstream; not invoked by this pipeline.
- `docs/CRON_CONVENTIONS.md` — output capture, log paths, env injection conventions used by every cron entry on the validator host.
