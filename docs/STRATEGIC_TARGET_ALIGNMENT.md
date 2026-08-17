# Strategic Target Alignment

**Status:** live, authoritative. Read this before designing or evaluating any anchor / disclosure / institutional-facing artifact.

**Purpose:** Fix the honest boundary of what this validator can and cannot reach under its current strategic constraints, so that anchor design, task planning, and communication all target the same reachable end-state instead of a rhetorical one.

## Executive summary (three claims)

1. **Under current anonymity policy, this validator cannot pass direct institutional vendor due-diligence** (bank / credit union / ETF issuer). The 2026 institutional procurement floor is SOC 2 Type II + ISO 27001:2022 + a KYC'd legal counterparty, and any provider without those does not advance in procurement regardless of technical merit. *(Qualified 2026-08-17: this claim is about **direct vendor procurement**, and must not be read as "anonymity closes every institutional-shaped path" — see [What PulseVM changed](#what-pulsevm-changed-measured-2026-08-17) below, which is the second of the two postures this document now holds.)*
2. **The reachable strategic surface is:** (a) selection into an A-Chain / PulseVM subnet's validator set, (b) organic delegator flow from pseudonymous evaluators, (c) tooling / data producer positioning inside the Metallicus orbit. All three tolerate pseudonymous operators with verifiable technical substance.
3. **Anchor design MUST therefore target (a)(b)(c), not direct institutional DD.** Every field in `anchor-source.json`, every disclosure in `docs/`, every task in the queue must be defensible as "this advances subnet-selection readiness or pseudonymous evaluator confidence" and not as "this satisfies a bank vendor questionnaire" — because it will never satisfy the latter.

## Institutional procurement reality (2026, external research)

External sources consistently identify the 2026 institutional validator selection floor:

- SOC 2 Type II attestation (= independent operational integrity, confidentiality, availability audit over a period)
- ISO 27001:2022 information security management certification
- NIST CSF alignment
- Legal counterparty with contractable identity
- Insurance (cyber liability + errors & omissions)
- Slashing controls + custody architecture (non-custodial or clearly-segregated)
- Uptime history sufficient to survive the fund's risk-committee scrutiny

Providers lacking any of the first four do not advance to technical scoring. Uptime records and rate advantages are irrelevant if the certifications gate is not cleared.

**Sources:**
- [SOC 2 Type II and ISO 27001 for Blockchain Infrastructure — Chainstack](https://chainstack.com/soc-2-type-ii-iso-27001-blockchain-node-infrastructure/)
- [Staking ETFs and Validator Infrastructure Demand — Everstake](https://everstake.one/resources/blog/staking-etfs-validator-demand)
- [Non-negotiable Certifications for Staking Providers — Moonlet](https://moonlet.io/resources/the-non-negotiable-certifications-to-look-for-in-your-staking-provider-iso-27001-soc-2-type-i-ii)

## Metallicus subnet selection (from official docs)

Metallicus documents subnet operator authority to impose requirements on validators wishing to serve a given subnet. Explicit example requirements listed by Metal Blockchain docs:

- Geographic location restrictions
- KYC/AML compliance checks
- Licensing requirements
- Hardware specifications

**Not documented** in public Metal Blockchain material as of 2026-07-01:
- A named evaluator tool or scoring system
- A machine-consumable spec that a validator can target
- An application / onboarding process for subnet operators to discover validators

**Update (2026-08-17, measured).** Two of those three gaps are now partly filled — but by `pulsevm.dev`, a community-run docs site, **not** by Metal Blockchain's own material, which still says nothing about any of this. `pulsevm.dev` publishes `/network/validator` ("Run a Validator") and `/network/launch` ("Launch Your Own Network") as first-class pages, and `/network/validator` states the participation model outright:

> 4. **Register**: the subnet owner adds your NodeID as a validator (consortium governance decides who validates).

So the shape of the work is now documented, and the **selection mechanism is confirmed to be appointment by the subnet owner** rather than an open registration. What is still unpublished: the subnet ID to track, any application or onboarding route (the page's closing line directs the reader to "ask in the community channels"), and any evaluator tool or scoring system. There is still nothing a validator can *submit*.

The practical read: this path is **nomination, not procurement**. That cuts in our favour under the anonymity policy — nomination weighs demonstrated operational substance, which is the one thing this project accumulates — and against us for planning, because there is no queue to join and no form to fill in. Discoverability is therefore the whole lever, which is what the anchor and the public feeds already target.

Metallicus's positioning is "Metal Blockchain For Banking" and their high-visibility subnet initiatives are banking-oriented. Banking subnets will almost certainly require the KYC + certifications gate above, closing that path for anonymous operators.

Non-banking subnets on Metal may be reachable. There is no public roster of these as of this document's date; discovering them is itself a task.

**Source:**
- [Metal Blockchain Subnets Documentation](https://docs.metalblockchain.org/subnets)

## What PulseVM changed (measured 2026-08-17)

PulseVM is a metalgo VM plugin that runs the Antelope execution model (Leap 5.0.3 lineage) on Avalanche Snowman as a Metal subnet. Its licence reads `Copyright (c) 2025-2026 Metallicus, Inc.` and its principal author is Metallicus's CTO. Its documentation describes it as the foundation layer of **A-Chain** — the chain this project broadcasts its cycle anchors to. That makes it the first external development since this document was written that changes what "reachable" means here, and it does so in two directions at once.

### The measurement

| item | measured |
|---|---|
| commits in the trailing 60 days | 226, across 3 authors |
| releases | v0.3.5 (2026-06-09) → v0.5.0 (2026-07-22) → **v0.6.2 (2026-08-12)**, Linux binaries attached |
| landed in the trailing 3 weeks | producer election / state sync / CPU billing — the ground floor of validator operation, finished only just now |
| A-Chain Alpine head block | **3406, unchanged** across 4 samples over 5m17s |
| Alpine lifetime actions | 4,218 — of which **4,092 (97%) are `pulse`↔`test` "churn #N" synthetic traffic** |
| Alpine's last action | 2026-08-13 |
| Alpine accounts | 28, all system / BP placeholders; **zero third-party accounts** |
| third-party node sync | officially **"not yet supported on this reset"** |
| subnets on Metal mainnet | **still zero** (the explorer says "More Subnets Coming Soon") |

**The code is real; the network is not running yet.** Both halves matter: a stalled chain is not a venue, and a repository landing producer election three weeks ago is not a dead project either.

**The official backing is thin.** `metallicus.com`, `metalblockchain.org`, `docs.metalblockchain.org`, `xprnetwork.org` and `MetalBlockchain/metal-docs` do not mention PulseVM at all. The "A-Chain will be PulseVM" claim exists in exactly one place — `pulsevm.dev`, a community developer's site. Metallicus's own primary statement is a single line in a 2025 Q3 report ("internal testing continues for PulseVM"). **No date has been published anywhere.** Treat the migration as certain in direction and unknown in timing.

*Provenance note.* Three rows above were re-measured directly in this checkout at implementation time on 2026-08-17 — the Alpine head block (3406), the chain ID, and the "third-party node sync is not yet supported" sentence — because `tests/pulsevm-upstream/` builds its fixtures from those exact response bodies. The remaining rows come from the same day's investigation and are recorded here without being re-measured. Do not cite the un-re-measured rows as current without re-running them.

### (A) The public venue is an A-Chain subnet, and its validator set is appointed

This replaces "Metallicus non-banking subnet selection" with something concrete. The venue is the A-Chain subnet — XPR Network's successor — and per the update in the previous section, **the subnet owner appoints validators**. This is nomination, not procurement: no form, no queue, no published subnet ID. What it rewards is exactly what this project produces and publishes.

### (B) Freedom Yield is on the *institution* side of PulseVM's own framing

`pulsevm.dev`'s front page reads "Financial infrastructure your institution can run on its own terms", and `/network/launch` ("Launch Your Own Network") sits beside `/network/validator` as a first-class page. The structure PulseVM sells to credit unions maps cleanly onto what this validator already is: members = delegators, deposits stay home = non-custodial delegation, rails = self-operated metalgo.

The consequence for this document: the "anonymity closes the institutional path" framing was **one-sided**. Anonymity is a *publication* policy — it is the absence of a published operator name, not the absence of a legal person. It closes direct vendor DD (claim 1 in the executive summary, still true). It does **not** close the posture of being an institution that runs its own rails.

### The separation (B) must never break: an anchor does not live on a chain we validate

If Freedom Yield ever launches its own PulseVM network, **cycle anchors do not move onto it.** The evidentiary value of an anchor is that an independent validator set — one this project cannot influence, reorganise, or replay — accepted and ordered the transaction. On a chain whose validator set we appoint or operate, that value is precisely zero, and the anchor degrades into a self-signed timestamp with extra steps.

**Own network ≠ anchor venue.** These are two separate roles and they must stay on two separate chains. Any future design that proposes anchoring to a Freedom-Yield-operated network is refused on this ground alone, regardless of how much cheaper or more convenient it is.

### What this does NOT change today

No date is published, third-party node sync is not yet supported, and Alpine has no third-party accounts — so there is nothing to build against, and no pre-emptive rewiring of the anchor pipeline is justified yet. The structural exposure is recorded (`bin/safe-broadcast` gate 1 reads `/v1/history/get_transaction` and gate 3 reads `proton chain:info`; PulseVM offers neither, and a permanently-failing gate 1 is a permanent `exit 3` under the Prime Directive) and the trigger to act is mechanical rather than a calendar reminder: `scripts/check-pulsevm-upstream.sh` watches daily and fires on T1 (third-party sync becomes supported) or T2 (a mainnet section or a new chain id appears).

## Explicit unreachable set (under current policy)

The following targets are constitutionally unreachable while [`feedback_no_operator_name`](../../../.claude/projects/-Users-admin-htdocs-01-PROJECTS-metal-freedom-yield-com/memory/feedback_no_operator_name.md) and [`feedback_no_personal_finance`](../../../.claude/projects/-Users-admin-htdocs-01-PROJECTS-metal-freedom-yield-com/memory/feedback_no_personal_finance.md) hold:

- Direct contract with a bank, credit union, or ETF issuer
- SOC 2 Type II report (requires named audit subject and legal counterparty)
- ISO 27001:2022 certification (same)
- FSA regulated status
- Participation in any KYC-required Metal subnet
- Any procurement path that requires a signed vendor contract with a legal entity

No amount of anchor sophistication, verb discipline, or hash-chain elegance moves this boundary. These are policy blockers, not technical gaps.

## Reachable set (the actual strategic surface)

1. **Selection into a public A-Chain subnet's validator set — XPR Network's successor, run on PulseVM.** Requires: substantive on-chain track record, cycle-boundary uptime discipline, technical maturity signals, discoverability. Reachable with pseudonymous identity if the specific subnet does not gate on KYC. **Selection is by appointment**, not application: `pulsevm.dev/network/validator` states that the subnet owner adds a NodeID to the validator set and that "consortium governance decides who validates" — so there is nothing to submit, and the only lever is being visibly, verifiably good at the job. Not yet actionable: third-party node sync is not supported on the current Alpine reset, and no subnet ID is published (see [What PulseVM changed](#what-pulsevm-changed-measured-2026-08-17)).
2. **Organic delegator inflow.** Requires: verifiable technical substance, honest disclosure, competitive-but-not-lowest fee, no red flags. The 2026-06-08 receipt of 23,428 METAL from an external delegator is empirical evidence this path works even at cycle-2 stake levels.
3. **Data / tooling producer positioning inside the Metallicus orbit.** Requires: machine-readable public artifacts, verification instructions, uptime for the data feed itself, no self-promotional posture. Aligns with the [Rated / Helius / Obol precedent](../../../.claude/projects/-Users-admin-htdocs-01-PROJECTS-metal-freedom-yield-com/memory/feedback_smallness_as_asset.md) of small operators positioning as tool / data providers before scaling stake.
4. **Foundation delegation (if such a program appears).** Requires: same substance as (1)(2), plus visibility inside Metallicus decision channels.

## What anchor design should target

Given the above, the `anchor-source.json` v1 schema and its A-chain broadcast should be optimized for:

- **Independent verifiability by any evaluator tool** — machine-readable JSON, published schema, standard-tool reproduction (curl / jq / sha256 / Hyperion). Already delivered.
- **Pseudonymous continuity proof** — hash chain, identity fingerprint, key-rotation history. Already delivered.
- **On-chain immutable record of operational observations** — uptime, incident count, fee, self-stake at cycle boundaries. Already delivered.
- **Discoverability inside Metallicus orbit** — Hyperion filter-friendly memo prefix, cross-references to public artifacts. Partially delivered (Hyperion prefix ready; discoverability metadata thin).
- **Honesty about the pseudonymous ceiling** — the anchor and the surrounding public artifacts should not imply institutional readiness we do not have. Currently violated by rhetoric in older docs; needs correction.

The anchor should NOT be optimized for:

- Satisfying SOC 2 controls (impossible without legal identity)
- Satisfying bank vendor questionnaires (impossible without contract counterparty)
- Meeting KYC requirements (in tension with anonymity policy)
- Replacing certifications we cannot obtain

Any task that claims to move us toward "institutional readiness" in the SOC 2 / bank DD sense is misdirected work and should be re-scoped or dropped.

## Task list re-scoping guidance

Tasks currently in the queue, evaluated against the reachable set:

| task | reachable target served | keep / rescope / drop |
|---|---|---|
| T-C-20260701 (sign-anchor-event rewrite, 4-action pack) | Metallicus subnet + evaluator discoverability | keep, with testnet-first mandatory per Constitution §3.4 |
| T-D-20260701 (3 anchor scripts update) | same | keep, same discipline |
| T-E-20260701 (test suite rewrite) | verification substance | keep |
| T-F-20260701 (independent audit round 1) | pseudonymous evaluator confidence | keep |
| T-I-20260701 (testnet full E2E rehearsal) | Constitution §3.4 mandatory | keep, execute before any mainnet broadcast |
| T-H-20260701 (7/4 mainnet first anchor) | pseudonymous continuity start | keep, gated on T-I success |
| T-B2-20260701 (delegator-events feed) | anchor observation completeness | keep |
| T-8.prep, T-8 (cycle-gate transition) | operational continuity | keep |
| T-9 (state file schemaVersion) | verification hardening | keep |
| T-RD4 (residual sanitize sweep) | operational hygiene | keep, post-7/4 |
| T-J-20260701 (the validator host git divergence) | operational hygiene | keep, post-7/4 |

No task in the current queue targets an unreachable set element; none needs to be dropped for strategic misalignment. However, several implicit claims in docs (older references to "institutional readiness" without the pseudonymous qualifier) need to be corrected in a docs-consistency pass — treated as a new task below.

## New tasks emerging from this alignment

- **T-K-20260701:** docs-consistency pass — grep every occurrence of "institutional", "compliance", "bank" in `/docs`, `/public`, and repo-level markdown; correct any wording that implies institutional-DD readiness to instead say pseudonymous / evaluator-tool readiness.
- **T-L-20260701:** Metallicus subnet discovery — enumerate current + announced Metal subnets, identify which permit pseudonymous validator selection, produce a shortlist of reachable subnet targets. Non-broadcast, research-only.
- **T-M-20260701:** anchor content — add discoverability metadata field to `observations_branch` (e.g., `evaluator_hints`, `subnet_targets_declared`) so a subnet operator scanning our chain footprint sees us as a candidate. Testnet-first per Constitution §3.4.

## Non-goals restated

This document does not:

- Recommend abandoning the anonymity policy. That is a first-order operator decision, separate from this alignment.
- Promise that a rewritten anchor will reach any specific institutional counterparty. The ceiling under current policy is real.
- Substitute for a formal risk assessment of the pseudonymous positioning. That is a separate document owed to the operator.

## Change log

- **v1 (2026-07-01):** Initial draft. Motivated by the post-broadcast incident and the operator's direct challenge on whether the current work product is submitable to credit unions and banks (answer: no, but this document explains what it IS suitable for).
- **v2 (2026-08-17):** Two postures, not one. v1's reachable set assumed a single stance — "be selected by someone else" — and read the anonymity policy as closing every institutional-shaped path. Measuring PulseVM (the metalgo VM plugin its docs describe as the foundation of A-Chain, the chain this project anchors to) showed both halves needed splitting. Added the section [What PulseVM changed](#what-pulsevm-changed-measured-2026-08-17) with the 2026-08-17 measurement, holding **(A)** the public venue = an A-Chain subnet whose validator set is *appointed* by the subnet owner, and **(B)** Freedom Yield sits on the *institution* side of PulseVM's own framing and could run its own network — with the non-negotiable separation that **an anchor never moves onto a chain we validate**, because third-party ordering is the entire evidentiary value. Concretised reachable-set item 1 from "Metallicus non-banking subnet selection" to the A-Chain subnet, with the appointment mechanism quoted from `pulsevm.dev/network/validator`. Updated the "Not documented" list: `pulsevm.dev` now publishes the shape of validator participation, while Metal Blockchain's own material still does not mention PulseVM at all, and no subnet ID, onboarding route, or migration date is published anywhere. Nothing in v1 is withdrawn — claim 1 (no direct vendor DD under anonymity) still holds and is annotated in place rather than rewritten. No pre-emptive anchor rewiring: the trigger is mechanical, via `scripts/check-pulsevm-upstream.sh` (T1/T2), added the same day.
