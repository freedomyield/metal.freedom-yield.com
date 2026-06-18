# Freedom Yield Validator — Constitution

> **Status:** v0.1 (draft)
> **Scope:** Metal Blockchain mainnet validator operation under the "Freedom Yield" brand.
> **Authority:** This document is the supreme reference for the project. All other documents (`OPERATING_MODEL.md`, runbooks, scripts, public copy) MUST conform to it.

The key words **MUST**, **MUST NOT**, **SHALL**, **SHALL NOT**, **SHOULD**, **MAY** in this document are to be interpreted as described in RFC 2119.

---

## 0. Purpose and Authority

This Constitution defines the inviolable principles that govern this validator project.

- It is the **single source of truth** for what we will and will not do.
- All operational documents, code, scripts, public copy, AI assistance, and outward communication MUST be consistent with this document.
- Where any other source (runbook, memory note, suggestion from any AI, advice from a third party, prior commit message) conflicts with this Constitution, the Constitution prevails until amended under [§9](#9-amendment-process).
- This document is itself public. It SHALL NOT contain any item classified SECRET ([§4.1](#41-secret-classification)) and SHOULD NOT contain any item classified CONFIDENTIAL ([§4.2](#42-confidential-classification)) beyond categorical reference.

## 1. Mission and Identity

- The project operates a **Metal Blockchain mainnet validator** under the public brand **"Freedom Yield"**.
- The validator is independent infrastructure. It is **not** affiliated with Metallicus, Metal Pay, the Metal Blockchain Foundation, or any related entity.
- The operator is a private actor. The operator's legal entity name SHALL NOT appear in any public artifact. Only the "Freedom Yield" brand identifies this validator publicly.
- Public posture: **small, transparent, honest, jurisdictionally Japan**. The project prioritizes verifiable operational records over claims about scale.
- Strategic analysis, market interpretation, and future opportunity assessment are outside the scope of this Constitution. This Constitution governs conduct regardless of strategy.

## 2. Operating Priority Order

When two operating concerns conflict, the **lower-numbered** one wins. From highest to lowest:

1. **Validator health** — the `metalgo` process, peer connectivity, sealed-key integrity, and inclusion in the active validator set.
2. **Information hygiene** — preventing leakage of items defined in [§4.1 SECRET](#41-secret-classification).
3. **Disclosure integrity** — public-facing data MUST be truthful, current, and verifiable.
4. **Observation and monitoring** — dashboards, persistence streams, push notifications, alerts.
5. **User-facing site quality** — UI, copy, design polish.
6. **Velocity** — speed of shipping new features.

Anything not on this list ranks below all of the above. When in doubt, descend the list, not ascend.

## 3. Absolute Prohibitions

The following are forbidden without exception. Any of these is a **constitutional violation** and MUST be reverted immediately upon discovery.

### 3.1 Identity prohibitions

- MUST NOT publish the operator's legal entity name in any artifact: repository, site, docs, commit message, issue, pull request, public push notification, or any AI chat shared externally.
- MUST NOT publish the operator's personal income, other businesses, personal assets, or any financial figure not directly attributable to this validator's on-chain activity.
- The default posture is inbound-first. Outbound contact with network-related entities requires explicit operator approval and MUST be limited to a specific operational purpose.

### 3.2 Claim prohibitions

- MUST NOT make inflated capability claims (e.g. "institutional-ready", "multi-region", "subnet operator", "enterprise SLA") that exceed delivered reality.
- MUST NOT use superlative or boast language: "best", "strongest", "most reliable", "largest", "the only". The public narrative is collaboration, not competition.
- MUST NOT denigrate, name unfavorably, or compare against other validators in public materials.
- MUST NOT manufacture urgency in notifications, status pages, or push messages. Anomaly tone is reserved for real anomalies; scheduled events are not emergencies.

### 3.3 Operational prohibitions

- MUST NOT commit any validator private key, BLS signing key, certificate private part, wallet mnemonic, seed phrase, or passphrase to any repository, in any form, encrypted or plaintext.
- MUST NOT bypass the operating priority order ([§2](#2-operating-priority-order)). Observability or UX changes that risk validator health are rejected by default.
- MUST NOT take destructive infrastructure action — key rotation, host rebuild, snapshot deletion, force push, database drop, configuration wipe — without explicit operator approval for that specific action in that specific context.
- MUST NOT add or modify monetization channels (donations, paid services, retail marketing surfaces) without operator approval and conformance to [§7](#7-public-claims-and-disclosure-standard).
- MUST NOT introduce refactors, abstractions, or "while I'm here" cleanup that were not explicitly requested. A bug fix fixes the bug.

## 4. Information Hygiene

This is the most strictly enforced chapter. The repository is **public**; Git history is permanent and unforgivable.

### 4.1 SECRET classification

Items classified SECRET MUST NOT appear in any of:

- The repository (any branch, any commit, any path, including in history that could be rewritten).
- Public-facing site content, JSON endpoints, or logs served publicly.
- Issues, pull requests, code review comments, commit messages.
- AI chat transcripts shared with any third party, including other AI tools.
- Screenshots, recordings, or pasted content shared externally.
- Operating documents (`OPERATING_MODEL.md`, runbooks) committed to this repo.

**SECRET items:**

| # | Item |
|---|---|
| S1 | Validator staking private key, BLS private key, TLS certificate private parts |
| S2 | Any wallet mnemonic, seed phrase, or private key (any chain, any role) |
| S3 | Any wallet passphrase, file encryption passphrase, key-decryption phrase |
| S4 | BasicAuth credentials for operator dashboards, peers page, or any private endpoint |
| S5 | ntfy topic identifier (it is a bearer secret; possessing the name grants publish/subscribe) |
| S6 | Renewal calendar token URL or any component of it |
| S7 | Server login details: usernames, SSH key paths on the operator's workstation, SSH key fingerprints, SSH passwords, sudo passwords |
| S8 | Specific IP addresses and specific hostnames of the validator host and the web host |
| S9 | On-host filesystem paths in operator-controlled directories that store secrets, configuration containing secrets, or path patterns that reveal infrastructure layout |
| S10 | Any third-party API key, signing key, bearer token, OAuth secret, or webhook secret used by this project |
| S11 | Wallet addresses other than those the operator has chosen to publish on the public site; addresses MUST be reviewed before disclosure |

When in doubt about an item not listed, treat it as SECRET until classified otherwise.

### 4.2 CONFIDENTIAL classification

CONFIDENTIAL items are not bearer secrets, but their disclosure shapes infrastructure attackability or operational predictability. Default behavior is **do not publish**. Disclosure requires explicit operator approval, recorded per artifact.

| # | Item | Permitted form |
|---|---|---|
| C1 | Cloud provider name per infrastructure role, data center region, provider plan tier | Default: not published. Aggregate categorical reference only ("two-host separation across providers and regions"). Naming a provider or region requires per-artifact operator approval. |
| C2 | Specific VPS CPU model, RAM size, disk size | Architectural context only when materially relevant to a public artifact; never as a public commitment. |
| C3 | Specific monitoring tools, dependency versions known to carry CVEs | Refer by category in public docs ("a uptime-tracking daemon"); avoid specific tool names where they would expose attack surface. |
| C4 | Operating schedule details, on-call hours, vacation windows | Public-facing cadence statements MAY describe windows in the aggregate; specific times that reveal operator absence SHALL NOT be published. |
| C5 | Internal directory structure under operator-controlled paths | Refer abstractly; do not publish full paths even when files at those paths are themselves public. |

### 4.3 PUBLIC classification

Anything not classified above is PUBLIC, subject to truthfulness and to [§3](#3-absolute-prohibitions). PUBLIC items include:

- The brand name "Freedom Yield".
- The validator NodeID and its Proof of Possession.
- Self-stake amount, fee rate, delegator count, validation cycle metadata.
- Validator and delegation transaction IDs.
- Explorer URLs referencing public on-chain validator artifacts.
- Public site endpoints under `metal.freedom-yield.com`.
- High-level architecture descriptions (two-host separation, automated deploy, monitoring discipline).
- Operator jurisdiction stated as "Japan" without further specificity.

### 4.4 Disclosure decision rule

- When uncertain about the classification of an item, treat it as the **more restrictive** class.
- Moving an item to a less restrictive class requires explicit operator approval and a written justification at the bottom of this document under "Reclassifications".
- AI assistants encountering a potentially SECRET or CONFIDENTIAL item in chat MUST stop and ask before reproducing it in any artifact.

## 5. Infrastructure Separation

- The validator host and the web host MUST remain physically separate, on different providers, in different regions.
- Network data flow between them MUST be unidirectional — validator host outward to web host only — through a single, narrow, key-authenticated channel.
- The web host SHALL NOT possess credentials capable of acting on the validator host.
- On a multi-tenant host where this project shares space with other operator projects, every action MUST be scoped to this project's paths, unit names, and project-prefixed identifiers. Host-wide configuration changes (host-wide nginx, system-wide cron, system-wide firewall flush, host-wide package operations) are prohibited.
- Automated deploy pipelines apply to the web host only. Validator-host changes are operator-approved and operator-executed. AI assistance MAY produce commands, reviewable diffs, and verification steps; execution and approval rest with the operator.
- Infrastructure-altering changes (key rotation, host rebuild, provider migration, `metalgo` upgrade, dependency change affecting validator code path) MUST be planned with documented rollback steps before execution.

## 6. Communication Discipline

This chapter governs how the operator and AI assistants communicate during the work.

- **Verify before reporting.** "Done", "fixed", "deployed" claims MUST be backed by direct verification: the actual command output, the rendered page read back, the endpoint hit and inspected. Inference is not verification.
- **Propagate conceptual changes.** When a concept, alert definition, or model is renamed or restructured, every surface using it (scripts, public HTML, JSON, CI, calendar files, push notification templates, docs) MUST be located by full-repository search and updated in the same change.
- **Two failures, stop.** If the same operation fails twice in distinct attempts, halt. Surface the assumption that may be wrong before a third attempt under the same assumption.
- **No false urgency.** Scheduled events are not anomalies. Anomaly tone is reserved for real anomalies. Push notifications carry this discipline.
- **No silent scope expansion.** AI MUST NOT introduce refactors, abstractions, dependency changes, or "cleanup while I'm here" that were not explicitly requested.
- **Sanitize before pasting.** Before any operator or AI shares a transcript, screenshot, or excerpt externally — including to other AI tools — SECRET ([§4.1](#41-secret-classification)) items MUST be removed and CONFIDENTIAL ([§4.2](#42-confidential-classification)) items reviewed.

## 7. Public Claims and Disclosure Standard

Any public claim — on the site, in `/api/*` endpoints, in social posts, in third-party listings — MUST satisfy all of:

- **Truthful at time of writing.** No statement may exceed delivered reality.
- **Verifiable on chain or by the reader.** Where the claim references a measurable property (uptime, NodeID, stake, fee, cycle count, delegator count), the underlying data MUST be linked or exposed such that an independent reader can confirm it.
- **Current.** Stale claims (past-cycle data presented as current, deprecated commitments) MUST be removed or clearly relabeled within one week of becoming stale.
- **Honest about scale.** Disclosure of stake size, validator age, and delegator count MUST be plain and current. Inflation, padding, or omission designed to suggest larger scale is forbidden by [§3.2](#32-claim-prohibitions).
- **Honest about jurisdiction and structure.** Operator jurisdiction (Japan) MAY be stated. Operator legal entity name MUST NOT ([§3.1](#31-identity-prohibitions)). Affiliation language ("we are X", "we partner with Y") MUST NOT misrepresent independent operation.
- **Plain about absence.** When a capability is not present, the public site MUST NOT imply it. Silence is permitted; implication is not.

## 8. Scope Boundaries

- This Constitution applies only to the Freedom Yield Metal Blockchain validator project. Functionality, branding-specific copy, or financial framing from any other project SHALL NOT be merged into this repository.
- Other ventures operated by the same operator are **out of scope of this Constitution**. No reference to them appears here. No financial figure from them appears here. No code from them is imported here.
- Tax, accounting, insurance, corporate filings, and operator personal compliance matters are **out of scope of this Constitution**. They are handled outside this repository, in records not governed by this document.
- Future scope expansion (e.g. running a subnet, operating additional validators, offering paid services) requires constitutional amendment under [§9](#9-amendment-process), not a code change.

## 9. Amendment Process

- This Constitution may be amended only by the operator. AI assistance MAY draft proposed amendments but MAY NOT enact them.
- An amendment requires:
  1. A pull request that modifies this document.
  2. A version bump in the front-matter `Status:` line.
  3. A changelog entry at the bottom of this document summarizing what changed and why.
  4. Explicit operator approval at merge time.
- **Tightening amendments** (adding a prohibition, narrowing a classification, raising a priority) take effect at merge.
- **Loosening amendments** (removing a prohibition, broadening a classification, lowering a priority) take effect **seven days after merge**, during which window the operator may revert without further process.
- Suggestions from external advisors, AI tools, or community input do not amend this document; they may motivate the operator to open an amendment pull request.

---

## Changelog

- **v0.1** — Applied public-repository tone and information-hygiene cleanup before publication.
- **v0** — Initial draft. Establishes the ten chapters, the SECRET / CONFIDENTIAL / PUBLIC classification, and the operator-only amendment process.

## Reclassifications

*(none yet)*

---

## See also

- `docs/OPERATING_MODEL.md` — concrete workflows, cadences, and responsibility assignment that implement this Constitution. Where they conflict, this Constitution prevails.
- `docs/SECURITY_LAYERS.md` — defense-in-depth implementation for the web side.
- `docs/INCIDENT_RESPONSE.md` — incident runbook implementing the response side of W4.
- `docs/KEY_ROTATION.md` — key rotation runbook implementing W5.
- `docs/VALIDATOR_RENEWAL.md` — cycle renewal runbook implementing W3.
