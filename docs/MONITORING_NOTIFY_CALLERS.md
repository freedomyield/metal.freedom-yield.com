# notify.sh — caller inventory and compatibility matrix

Reference for commits C3a → C3b → C4 in the anomaly hardening sequence. `scripts/notify.sh` is shared by multiple callers; before changing its exit-code semantics for K-3 (= C4), every caller must be enumerated and its behaviour under a non-zero exit from notify.sh must be assessed. This document is the result of that enumeration and the basis for selecting the compatibility strategy (= S1 / S2 / S3) used in C3b.

C3a (= this doc) makes no code change. C3b implements the chosen strategy. C4 uses the new contract.

## 1. Inventory method

```bash
grep -rn 'bash.*notify\.sh\|"\$NOTIFY"' --include='*.sh' scripts/
grep -rn 'NOTIFY=\|: "\${NOTIFY' --include='*.sh' scripts/
grep -rn 'notify\.sh' --include='*.md' .
grep -n 'set -e\|set +e\|set -u\|set +u' scripts/check-anomalies.sh scripts/daily-status.sh \
    scripts/notify-evidence-health.sh scripts/notify.sh
```

Repo snapshot at commit `316e8f1` (= post-C2 head).

## 2. Caller table

| # | Caller (file:line) | Form | `set` flags in effect at call site | Position in script | Exit-code handling | Behaviour under non-zero from notify.sh | Risk under exit-code change |
|---|---|---|---|---|---|---|---|
| 1 | `scripts/check-anomalies.sh:342` (= the in-line `notify()` wrapper used by all transition alerts) | `bash "$NOTIFY" "$@" \|\| true` | `set -uo pipefail` (no -e) | mid-script, inside many transition blocks | `\|\| true` explicitly swallows any non-zero | No observable change; wrapper returns 0 regardless of notify outcome | **None** (= the wrapper IS the place that swallows the exit code today; K-3 / C4 will replace this wrapper with `notify_and_state` that consumes the exit code intentionally) |
| 2 | `scripts/check-anomalies.sh:221` (= K-3.5 missing-state notify) | `bash "$NOTIFY" high "..." ... >/dev/null 2>&1 \|\| true` | `set -uo pipefail` | inside K-3.5 missing branch | `\|\| true` swallows | No change | **None** |
| 3 | `scripts/check-anomalies.sh:291` (= K-3.5 corruption-new-hash notify) | `bash "$NOTIFY" high "..." ... >/dev/null 2>&1 \|\| true` | `set -uo pipefail` | inside K-3.5 quarantine branch | `\|\| true` swallows | No change | **None** |
| 4 | `scripts/daily-status.sh:228` (= the digest push) | `bash "$NOTIFY" "$PRIO" "${TITLE_PREFIX} ${DATE_JP}" "$BODY"` | `set -uo pipefail` (top) + `set -e` re-enabled at line 173 → **`set -e` is ACTIVE at line 228** | **Last statement** of the script | No `\|\| true`; `set -e` would propagate non-zero | Script exits with notify.sh's exit code; visible in cron log; no further statements execute | **Low** — the cron log gains an occasional non-zero line when ntfy is degraded; no functional regression because no further code runs after line 228 |
| 5 | `scripts/notify-evidence-health.sh:145` (= push mode) | `bash "${ROOT}/scripts/notify.sh" "${PRIO}" "${TITLE}" "${MSG}"` | `set -euo pipefail` (file header) — `set -e` ACTIVE | **Last statement** of the script | No `\|\| true`; `set -e` propagates | Same as #4: script exits with notify.sh's code | **Low** — same rationale as #4. Note that in steady-state operation this script is called from daily-status morning slot in `--summary` mode, which does NOT call notify.sh (= line 145 is only hit in legacy standalone push mode) |

### 2.1 Set-flag inspection

| Script | Header `set` | Body changes | Effective state at notify.sh call |
|---|---|---|---|
| `check-anomalies.sh` | `set -uo pipefail` | none | `-u`, `-o pipefail`, **no -e** |
| `daily-status.sh` | `set -uo pipefail` | `set +e` at line 170 (around evidence subprocess), `set -e` at line 173 | At line 228: **`-e` active** (= last toggle was `set -e`) |
| `notify-evidence-health.sh` | `set -euo pipefail` | none | **`-e` active** |
| `notify.sh` | `set -euo pipefail` | none | (callee, not relevant to callers) |

## 3. Today's notify.sh exit-code contract

`scripts/notify.sh` currently returns:

- `exit 1` when `$NTFY_TOPIC_FILE` is missing or empty
- `exit 1` when `curl` itself returns a non-zero status (= network unreachable; `set -euo pipefail` propagates curl's exit)
- `exit 0` in all other cases, **including when ntfy.sh returns HTTP 4xx or 5xx** (= the `-w "%{http_code}\n"` flag only prints the status to stdout; it does not affect curl's exit code)

This means today's "success" exit can mask:

- ntfy.sh server-side errors (= 5xx)
- topic-not-found / auth-failed (= 4xx)
- silent drop (= 200 with empty body)

For at-least-once delivery semantics required by K-3 (commit C4), the caller needs the ability to distinguish "delivered" from "best-effort sent but unconfirmed". That distinction is impossible with today's contract.

## 4. Compatibility strategy options

### 4.1 S1 — env-gated strict mode (recommended)

`notify.sh` keeps today's default behaviour (= exit 0 unless missing topic or curl-level failure). A new env var `NOTIFY_RETURN_HTTP_STATUS=1` opts in to HTTP-aware exit codes:

```
NOTIFY_RETURN_HTTP_STATUS=1 bash notify.sh ...
  exit 0   HTTP 2xx
  exit 1   missing/empty topic file (= same as today)
  exit 2   curl transport failure (= timeout, DNS, connection refused)
  exit 3   HTTP 4xx
  exit 4   HTTP 5xx
```

Without the env var, behaviour is byte-identical to today. K-3 (= the C4 transition processing) sets this env var explicitly for every call. Daily-status, notify-evidence-health, K-3.5 best-effort notifies, and the existing check-anomalies wrapper do not.

**Pros**

- Strictly additive. No existing caller observes any change.
- Future callers can opt in independently.
- Easy to reason about: the default path is unchanged.

**Cons**

- Two contracts for one script.
- Requires K-3 callers to remember the env var (= small boilerplate).

**Effort**: low. ~30 lines added to notify.sh.

### 4.2 S2 — breaking (every call gets HTTP-aware codes)

`notify.sh` always returns the codes listed in S1. Existing callers see a behaviour change.

**Pros**

- Single contract, no env-var boilerplate.
- All operators (= the cron operator alone, in this case) see all notify failures, not just K-3's.

**Cons**

- Daily-status and notify-evidence-health gain occasional non-zero exits when ntfy is degraded, which appear in cron log. (= low blast radius because these scripts have nothing after the notify call.)
- Requires checking that no caller swallows the new codes silently in a way that masks a real issue.

**Effort**: low–medium. Notify.sh change is small; the validation step is the matrix above.

### 4.3 S3 — dual script (`notify.sh` + `notify-strict.sh`)

Keep `notify.sh` byte-identical. Add a sibling `notify-strict.sh` with the new contract. K-3 calls the strict version.

**Pros**

- Physical separation; existing callers can never accidentally observe the new contract.

**Cons**

- Two scripts maintaining the same `curl` + topic-file + tag-mapping logic.
- Drift risk: the two will diverge over time.
- More files in `scripts/`, larger surface to audit.

**Effort**: medium. Avoidable.

## 5. Recommendation (= subject to operator approval)

**S1** (env-gated). Reasons:

- Zero risk of regression in current callers. Audit confirms all 5 sites tolerate non-zero, but S1 doesn't even put that to the test for the existing paths.
- Trivially reversible (= delete the env-var path) if a future requirement makes it inconvenient.
- Lets K-3 evolve its own retry / classification logic without coupling to other consumers.

If operator prefers a single contract (= S2), the matrix above shows it is also safe to ship. The cron log will gain occasional non-zero exits for daily-status / notify-evidence-health when ntfy.sh is degraded; this is **observability**, not a regression.

S3 is not recommended (= maintenance cost outweighs the isolation benefit, since S1 already provides equivalent isolation).

## 6. K-3 expected use under S1

```bash
# inside scripts/check-anomalies.sh K-3 / notify_and_state (C4 commit)
attempt_notify() {
  local prio="$1" title="$2" body="$3"
  NOTIFY_RETURN_HTTP_STATUS=1 bash "$NOTIFY" "$prio" "$title" "$body"
  return $?
}

# retry policy (= 1 retry, 5s backoff, exits 2/3/4 retryable, exit 1 fatal)
notify_and_state() {
  local prio="$1" title="$2" body="$3" field="$4" new_val="$5"
  local rc
  attempt_notify "$prio" "$title" "$body"; rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    sleep 5
    attempt_notify "$prio" "$title" "$body"; rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    candidate_set "$field" "$new_val"
    return 0
  fi
  echo "[K-3] notify_and_state permanent fail (rc=$rc, field=$field); state field unchanged" >&2
  GLOBAL_NOTIFY_RC=6
  return "$rc"
}
```

(Pseudocode for C4; not part of the C3a commit.)

## 7. Out of scope for C3a

- Implementation of the strategy (= C3b).
- K-3 logic itself (= C4, depends on C3b).
- Fixture harness / tests (= C6).
- daily-status root-cause for the `/etc/<your-namespace>/ntfy-topic` placeholder errors (= deferred per operator Q9).
- A formal `ntfy` API stub library (= no current need; existing `STUB_NOTIFY_EXIT` env-driven stub is sufficient).
