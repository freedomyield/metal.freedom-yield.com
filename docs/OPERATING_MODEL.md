# Freedom Yield Validator — Operating Model

> **Status:** v0.1 (draft)
> **Conforms to:** `docs/CONSTITUTION.md`. If this document conflicts with the Constitution, the Constitution prevails.

This document describes **how** the validator is operated day to day. The Constitution describes **what is or is not permitted**; this Operating Model describes the workflows that operate within those bounds.

Like the Constitution, this document is itself public. SECRET items defined in Constitution §4.1 SHALL NOT appear here. CONFIDENTIAL items appear only in categorical form.

---

## Roles and responsibility

- **Operator** — the human accountable for the validator. Holds the staking keys, executes infrastructure changes, approves amendments, owns final judgment. The operator is the only party authorized to act on the validator host.
- **AI assistant** — may research, draft commands, produce reviewable diffs, write verification scripts, and propose plans. MAY NOT execute infrastructure changes on the validator host, MAY NOT approve its own work, MAY NOT initiate external outreach.
- **CI pipeline** — executes web-host deploys when authorized by a repository-level gate. Does not touch the validator host.

The pattern across every workflow below: **AI proposes, operator approves, operator (or CI under the gate) executes, AI verifies output against the prior expectation.**

---

## Workflows

### W1 — Daily health (automated)

The validator host runs a periodic job set that:

- Observes `metalgo` health: process up, peer count above threshold, chain tip lag within bound, disk and memory headroom above threshold.
- Appends uptime samples to an append-only journal (never overwritten, never truncated; this is a project asset).
- Regenerates the public `/api/*` JSON endpoints and pushes them to the web host through the unidirectional channel established under Constitution §5.
- Delivers a daily digest to the operator's mobile channel at a fixed multi-time cadence.

Anomaly thresholds:

- Process-down event.
- Peer-count drop below the configured floor.
- Disk above the configured ceiling.
- Validator absent from the active set.

When any anomaly fires, an out-of-band push is delivered in addition to the digest.

Implementing scripts live in `scripts/` in this repository; alert routing parameters live on the validator host outside the repository, per Constitution §4.1 S5.

### W2 — Weekly review (operator + AI)

Operator and AI together review, once per week:

- Persistence stream freshness across all five long-running streams.
- Web-host access log for anomalous patterns (sustained traffic spikes from non-bot sources, repeated probes of specific endpoints).
- Peers dashboard changes — relevant public validator-set changes such as new validators, departures, and fee or self-stake shifts.
- Any monitoring log entry from the past seven days.

Output: optional new entries to the monitoring log; optional threshold adjustments proposed by AI and approved by operator.

### W3 — Monthly cycle renewal

A registered validation cycle has a finite duration. Renewal happens before expiry so stake does not idle.

**Pre-notification cadence:** 14 / 7 / 3 / 1 day before expiry, delivered via push.

**Renewal steps:**

1. Operator confirms next-cycle parameters: self-stake, fee, duration, delegation receipt policy.
2. Operator executes the `AddPermissionlessValidatorTx` from a wallet of their choice on a UI of their choice.
3. Operator records the new transaction ID, start time, and end time in the public uptime history JSON via a normal repository commit.
4. AI verifies the new entry is reflected in `/api/validator.json`, in the renewal calendar feed, and on the public site after deploy.

Self-stake adjustments that materially shift public posture (large step up or step down) are constitutional decisions requiring a deliberate review. Smaller step adjustments are operating decisions.

Detailed runbook: `docs/VALIDATOR_RENEWAL.md`.

### W4 — Incident response

**Trigger sources:** `metalgo` process failure, peer-count drop below threshold, disk or memory saturation, sustained absence from the active set, web-host outage, push channel silent for longer than the digest cadence.

**Response priority follows Constitution §2:** validator health first.

- In a degraded state, the operator MAY disable observability components (dashboards, push notifications, persistence-stream writers) to protect the validator process. Observability outages SHALL NOT cause validator action.
- Every incident produces an entry on the public incident page summarizing what happened, when, scope of impact, and resolution. SECRET items (Constitution §4.1) MUST NOT appear in incident entries.
- A postmortem is written for any incident lasting longer than one hour or affecting active-set membership.

Detailed runbook: `docs/INCIDENT_RESPONSE.md`.

### W5 — Key rotation

**Cadence:** at least once per year, and on any suspected compromise.

**Operator-only:** rotation requires direct access to the validator host and to backup storage. AI MAY draft the procedure, document expected outputs, and verify post-rotation outputs against expectations, but cannot perform key generation, key installation, or backup updates.

**Post-rotation invariant:** at least three independent backups MUST exist in differing encryption states across differing storage media before the previous key material is destroyed.

Detailed runbook: `docs/KEY_ROTATION.md`.

### W6 — Web deploy

**Trigger:** push to `main` of this repository.

**Gating:** a repository-level variable enables the deploy job. When disabled, all deploy jobs skip cleanly.

**Flow:** the CI pipeline rsyncs to the web host and recreates the web container. The validator host is not touched.

**Discipline requirements:**

- Code changes affecting the cached shell (CSS, JS, service worker) MUST bump the cache version constant in the same commit. Absence of a bump is a release defect.
- The web container's behind-proxy mode MUST be preserved through deploy.
- Post-deploy, the operator verifies: the site responds, `/api/validator.json` returns current data, a representative subpage renders without console errors. AI verifies these same checks if requested.

Detailed runbook: `docs/DEPLOY_SETUP.md`.

### W7 — Validator-host change

**Scope:** any change to the validator host beyond what the daily health job manages — config edits, script updates, dependency upgrades, `metalgo` version bumps, cron table edits, host-level package installs, OS updates, firewall edits.

**Flow:**

1. AI drafts the change as a reviewable diff or a sequence of commands. Each command lists its expected output.
2. AI proposes a rollback plan.
3. Operator reviews and approves.
4. Operator executes — directly on the host or through an operator-controlled helper.
5. AI verifies post-change output against the expected output produced in step 1. A mismatch halts and surfaces for operator decision.

Validator-host changes are **not** part of the CI auto-deploy. They are operator-executed every time.

### W8 — Strategic review

At the end of each cycle, operator and AI review:

- Monitoring log signals accumulated during the cycle.
- Delegation patterns: new delegators, departures, duration choices, fee sensitivity.
- Peer-set changes: validator-set composition changes, fee-distribution shifts, notable arrivals or departures.
- External announcements relevant to the network, including protocol, foundation, or public infrastructure updates.

Output: optional updates to the backlog of public-facing improvements (disclosure standard upgrades, new public data feeds, runbook refinements).

Strategy framing itself is not amended in this Operating Model.

### W9 — Code-change discipline

For every code change merged to `main`:

- A change touching both EN and JA pages MUST audit both side by side before merge. Language leakage across surfaces is a recurring defect class and is caught only by parallel review.
- A change that renames a concept, alert definition, or model MUST be matched against a full-repository search of the old name; every surface using the old name MUST update in the same change.
- A change to shell assets (CSS, JS, service worker) MUST bump the cache version constant in the same commit.
- A change that adds an external API call MUST include a TTL cache layer; raw uncached calls to third-party services are prohibited by operating practice.
- A change that imports a new dependency MUST be reviewed for license, supply-chain reputation, and necessity. Default answer to new dependencies is "no".

### W10 — External communication

- Inbound inquiries are received through a single anonymous-safe channel. Aggregate metadata (count, week, broad category) MAY be published as a public artifact; specific sender information MUST NOT.
- The default posture is inbound-first. Outbound contact with network-related entities requires explicit operator approval and MUST be limited to a specific operational purpose.
- AI assistants MUST NOT independently initiate such outreach, MUST NOT draft outreach unsolicited, and MUST NOT suggest content for outreach unless the operator has decided to make contact and has asked for drafting help.

### W11 — Audit-document discipline (append-only)

Audit documents — the files under `docs/audits/`, and any file that records a compliance finding, a verification result, or a dated observation snapshot — are an **append-only audit trail**. The value of the trail is that it preserves *what was claimed, what was wrong, and what was corrected*, so it MUST NOT be rewritten to hide its own history.

- A published finding, snapshot, or verification result MUST NOT be edited in place. Corrections are made either by striking the old text (`~~old~~`) and appending a dated `**REVISION <UTC>**` note, or by appending a new snapshot/entry that supersedes the prior one behind a deprecation marker. The prior record stays readable.
- Numeric corrections, additions, and meaning changes are all covered by the rule above: they use strike + `REVISION`, never a silent in-place rewrite.
- Every audit label and every task label MUST be date-scoped, so a finding is never ambiguous about which cycle or day it belongs to.

**Carve-out — forbidden-literal purge (the only exception).** When an audit document contains a **secret, PII, or forbidden literal** — the categories protected by Constitution §3.3 (operational prohibitions) and §4.1 (SECRET), for example a service-provider name, a validator host IP address, or an SSH key name — the strike-and-`REVISION` rule cannot be applied, because striking the literal (`~~forbidden~~`) leaves it in tracked content. That defeats the purge and trips `scripts/publish-guard.sh`. Strike-preservation and forbidden-literal purge are physically incompatible for this class, so for this class only the purge overrides append-only:

- The forbidden literal MUST be removed by **in-place replacement**, not by strike.
- The replacement MUST preserve the record's meaning with a neutral generic term (for example, "the validator host") or a `<placeholder>`, so the audit value of the entry survives the redaction.
- The purge MUST be a **single-purpose commit** whose message states the purge reason. No other content change — numeric correction, addition, or meaning change — may be mixed into a purge commit; those remain subject to the strike + `REVISION` rule and belong in a separate commit.

**Basis.** This carve-out was adjudicated 🟡 in `docs/audits/constitution-2026-07-06T11-45-audit.md` (finding ①/C12) as "the override is justified but its codification remained open pending operator ratification". The operator **ratified the carve-out on 2026-07-07**; this subsection is that ratification in authoritative form. The pattern matches prior redactions of forbidden literals in this repository (for example, the 2026-07-03 handle/company purge).

---

## Cadence summary

| Workflow | Cadence | Primary owner | Automation |
|---|---|---|---|
| W1 Daily health | Continuous, sub-hour | Automated | Yes |
| W2 Weekly review | Weekly | Operator + AI | Manual |
| W3 Cycle renewal | Monthly | Operator | Pre-alerts automated; tx by operator |
| W4 Incident response | On trigger | Operator (decisions); AI (drafts) | Alerting automated |
| W5 Key rotation | Annual and on compromise | Operator | None |
| W6 Web deploy | On `main` push | Operator (PR) → CI | Yes, gated |
| W7 Validator-host change | On need | Operator | None |
| W8 Strategic review | Per cycle | Operator + AI | Manual |
| W9 Code discipline | Per change | Operator + AI | Some lints |
| W10 External communication | On trigger | Operator | None |
| W11 Audit-document discipline | Per audit / per correction | Operator + AI | `publish-guard` |

## Responsibility matrix (condensed)

| Activity | Operator | AI | CI |
|---|:-:|:-:|:-:|
| Approve a change | ✅ | ❌ | ❌ |
| Generate, install, or destroy a key | ✅ | ❌ | ❌ |
| Execute a validator-host command | ✅ | ❌ | ❌ |
| Execute a web-host deploy | ✅ (via PR merge) | ❌ | ✅ (when gate enabled) |
| Draft a command or diff | ✅ | ✅ | ❌ |
| Verify output against expectation | ✅ | ✅ | ❌ |
| Read repository state | ✅ | ✅ | ✅ |
| Initiate external outreach | ✅ | ❌ | ❌ |
| Open an amendment PR | ✅ | ✅ (proposal) | ❌ |
| Merge an amendment | ✅ | ❌ | ❌ |

---

## Out of scope for this document

- Defense layering for the web side — see `docs/SECURITY_LAYERS.md`.
- Disaster recovery procedures — see `docs/DISASTER_RECOVERY.md`.
- Initial setup and mainnet migration — see `docs/VALIDATOR_HOST_SETUP.md`, `docs/MAINNET_MIGRATION.md`, `docs/TAHOE_PIPELINE.md`.
- Tax, accounting, insurance, corporate compliance — out of scope of this entire repository per Constitution §8.

## See also

- `docs/CONSTITUTION.md` — the principles this document implements.
- `docs/INCIDENT_RESPONSE.md` — detailed runbook for W4.
- `docs/KEY_ROTATION.md` — detailed runbook for W5.
- `docs/VALIDATOR_RENEWAL.md` — detailed runbook for W3.
- `docs/DEPLOY_SETUP.md` — detailed runbook for W6.
