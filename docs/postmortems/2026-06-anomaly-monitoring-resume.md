# Postmortem: anomaly monitoring maintenance pause and delayed resume (2026-06-24)

**Status**: resolved
**Severity**: Minor
**Classification**: operational monitoring incident — NOT a validator service incident
**Detection date**: 2026-06-24
**Resolution timestamp**: 2026-06-24T11:20:02Z (UTC)
**Affected system**: auxiliary anomaly monitoring cron pipeline (= `scripts/check-anomalies.sh` invoked by `/etc/cron.d/metal-anomalies`)
**Not affected (in records reviewed)**: validator operation, on-chain validator entry, delegations, recorded uptime, notification channel for non-anomaly traffic

## Summary

On 2026-06-24 the auxiliary anomaly-monitoring cron pipeline failed to resume after an intentional maintenance pause. The pipeline's runtime requirement and its cron environment were out of sync, which prevented the scheduled job from completing on its first execution. The four events that compose this incident are:

1. an intentional maintenance pause (in effect by 2026-06-18);
2. a dormant configuration mismatch (introduced 2026-06-20);
3. a failed resume attempt (2026-06-24);
4. a successful corrected resume (2026-06-24T11:20:02Z).

The condition was resolved at 2026-06-24T11:20:02Z. The validator service and its on-chain artefacts were not the affected system.

## Event timeline (= chronological)

1. **Intentional maintenance pause**. The cron entry for the anomaly cron in `/etc/cron.d/metal-anomalies` was commented out. The maintenance pause was known to be in effect by 2026-06-18. The exact activation timestamp could not be reconstructed from the records reviewed; the cron file mtime is suggestive but does not unambiguously represent the operator pause action.
2. **Dormant configuration mismatch**. Commit `57378ec` (2026-06-20) introduced a `${ANOMALY_STATE_DIR:?...}` requirement to `scripts/check-anomalies.sh`. The cron template in `scripts/vps-bootstrap.sh` and the live `/etc/cron.d/metal-anomalies` were not updated in the same change to define this environment variable. Because the cron line was already commented out, the mismatch remained dormant — the runtime requirement never executed.
3. **Failed resume attempt**. On 2026-06-24 an initial resume attempt uncommented the cron line; the very first natural cron tick produced a bash diagnostic `line 45: ANOMALY_STATE_DIR: ANOMALY_STATE_DIR is required` and exited non-zero. An earlier mutation attempt during the same recovery sequence also produced a malformed concatenation in the cron file for a brief window; the cron daemon silently skipped the malformed line so no fire occurred during that window, and an automated rollback restored the baseline byte-perfectly within minutes.
4. **Successful corrected resume**. A repo-managed helper (`scripts/ops/b6-enable-metal-anomalies-cron.py`) executed two explicitly-separated atomic transitions: a "install env line, stay paused" stage followed by an "uncomment the entry" stage. The first natural cron tick after activation was launched by the cron daemon at 2026-06-24T11:20:01Z and the script's own `[K-2]` log captured its execution at 2026-06-24T11:20:02Z, with `[K-4] lock acquired` and `[K-3] candidate == original (canonical); no commit, mtime preserved`, and no rollback-trigger fires.

## Post-resolution publication validation gate

The resolution above is the recovery event itself. The publication validation gate that follows is separate and is used to decide whether the incident record is safe to publish; it is not part of the incident resolution.

- Baseline anchor: 2026-06-24T11:20:02Z (= script-recorded successful execution).
- Observation launch window: 2026-06-24T11:20:01Z → 2026-06-25T00:20:01Z (= cron daemon job-launch records, inclusive of both endpoints).
- Observation length: 13 hours of continuous observation. The originally defined window was 24 hours; the operator approved an early gate close at 13 hours based on the consistent clean signal across the observed window.
- Tick total: 157 successful natural cron runs, inclusive of both the start and end scheduled launches within the stated window (= 153 in the daily-rotated archive `/var/log/anomalies.log.1.gz` + 4 in the post-rotation current log). Cron daemon launch records show zero missing launches within the stated inclusive window.
- Rollback-trigger fires across the window: zero, across K-1, K-2, K-3.5, K-4-open-fail, K-3-permanent-fail, K-3-commit, K-4-SKIP, and runtime error categories.
- Invariants across the window: cron file SHA, state file SHA and mtime, ntfy topic SHAs, lock file SHA, contention counter (absent), quarantine directory (absent), helper file SHA, and `cron.service` (active) — all unchanged or limited to expected per-tick mutation (= lock file mtime advances per tick; anomaly log appends per tick; daily logrotate moves the anomaly log to a compressed archive).

## Timestamp conventions used in this record

Multiple timestamps in this incident are close to one another but record different observations. They are recorded distinctly to avoid conflation:

- **2026-06-24T11:20:01Z** — cron daemon job-launch evidence (from `journalctl -u cron`).
- **2026-06-24T11:20:02Z** — script-recorded successful execution / `now` evidence (from the script's own `[K-2]` log line).
- **2026-06-24T11:20:02Z** — `confirmedPauseWindowEnd` and resolution timestamp in the published incident record. The script-recorded execution is the chosen resolution anchor because it confirms that the runtime requirement was satisfied and the body of the job completed.
- **2026-06-24T11:20:01Z → 2026-06-25T00:20:01Z** — observation launch window for the publication validation gate (= inclusive of both endpoints).

## Periodisation (= what is and is not known)

- **detectionDate** = `2026-06-24` (= the date the configuration mismatch became an observable incident condition via the failed resume attempt). Not 2026-06-18 (= pause start) or 2026-06-20 (= mismatch introduction).
- **confirmedPauseWindowStart** = field omitted in the published record. The pause was known to be in effect by 2026-06-18, but a second-precision activation timestamp cannot be reconstructed from the records reviewed.
- **confirmedPauseWindowEnd** = `2026-06-24T11:20:02Z`.
- **potentiallyAffectedStart** = `null`, with `potentiallyAffectedStartStatus` = `"undetermined"` (= the earliest start of auxiliary-monitoring impact cannot be reconstructed; the pause-start evidence is too weak to assert).
- **resolutionDate** = `2026-06-24`.

## Constraints on what is and is not known

- No assertion is made about false positives, false negatives, or alerting timeliness during the affected window.
- The empty prior contents of `/api/incidents.json` are not used as evidence of no prior incidents.
- Absence-of-record is not treated as evidence-of-absence.
- The exact intentional-pause activation timestamp is intentionally not asserted.

## Validator state observations

The on-chain validator entry, recorded uptime, delegations, and primary push-pipeline freshness remained within their normal ranges across the period reviewed. Within records reviewed, no impact on the validator service was identified. Records reviewed do not span every possible failure mode; this is the available evidence, not a proof of absence.

## Co-occurring degradation (= separate open workstream)

A separate daily-status monitoring degradation was already open when this incident was reviewed. It remains open as an independent workstream and is explicitly NOT in scope of this resolution.

During the publication validation gate, the system-level `logrotate.service` failed at 2026-06-25T00:00:01Z. The direct error in the journal was `failed to rename /var/log/daily-status.log to /var/log/daily-status.log.1: Permission denied`, and the service exited with a non-zero status. The same logrotate run successfully rotated `/var/log/anomalies.log` (= the anomaly cron pipeline's log) to a compressed archive within the same invocation. The logrotate failure is recorded here as an observation; its root cause is not within the scope of this postmortem and is tracked as part of the separate daily-status workstream.

The phrase "monitoring fully restored" is intentionally NOT used. The resolution scope is the anomaly cron pipeline only.

## Root cause

A runtime-contract change to `scripts/check-anomalies.sh` (= commit `57378ec`, 2026-06-20) introduced a `${ANOMALY_STATE_DIR:?required}` bash guard, but the corresponding cron environment definition was not added to the cron template (`scripts/vps-bootstrap.sh`) nor to the live `/etc/cron.d/metal-anomalies` in the same atomic change. Detection was delayed because the cron line was already commented out as part of an unrelated intentional pause.

## Detection gap

The dormant nature of the mismatch during the pause meant a runtime-contract regression went unnoticed for four days between its introduction (2026-06-20) and the resume attempt (2026-06-24). A guardrail that detects runtime-contract / cron-env desync as part of CI or pre-deployment review is a follow-up candidate.

## Recovery design

A repo-managed helper at `scripts/ops/b6-enable-metal-anomalies-cron.py` was developed to perform the resume safely. Key properties:

- Sed-based mutation is banned. All mutation uses Python `splitlines(keepends=True)` element-equality replacement so that line matching is unambiguous.
- The transition from "paused without env" to "active" is explicitly split into two stages: one stage adds the environment line while leaving the target cron line commented, and a second stage uncomments the target line. Each stage performs an atomic write, a byte-perfect post-write SHA verification, and a fail-closed precondition check.
- The activation stage observes the first natural cron tick within a fixed wait window and evaluates ten named rollback triggers. Any trigger fires an atomic restore to the post-install paused baseline. A previous helper's single broad trigger was redesigned into two narrower triggers — one scoped to cron daemon journal output for crontab load failures, and one scoped to the job's own log for job runtime error evidence.
- The helper underwent unit testing in the repository and a separate in-process self-test, and operates only against three SHA-asserted embedded baselines.

## Procedural deviations (= recorded for posterity)

- During recovery, an earlier mutation attempt produced a malformed concatenation in `/etc/cron.d/metal-anomalies` for a brief window. The cron daemon silently skipped the malformed line so no fire occurred during that window, and an automated rollback restored the baseline byte-perfectly within minutes. No production state was affected.

## Lessons learned + follow-ups (= non-blocking)

- Runtime-contract-changing commits should include the cron / deployment-template sync in the same atomic change. Adding a pre-deployment guardrail to detect cron-env desync is a candidate.
- A `datetime.datetime.utcnow()` DeprecationWarning emitted by the helper under Python 3.12+ is functionally inert and is tracked as non-blocking cleanup.
- The daily-status notification-channel degradation and the related `logrotate.service` failure are tracked as a separate open workstream.

## References

- `public/api/incidents.schema.v1.json`
- `public/api/incidents.example.json`
- `scripts/ops/b6-enable-metal-anomalies-cron.py`
- `tests/ops/test_b6_enable_cron.py`
- `docs/MONITORING_OPS.md`
- `docs/INCIDENT_RESPONSE.md`
