# Strategic Target Alignment

**Status:** live, authoritative. Read this before designing or evaluating any anchor / disclosure / institutional-facing artifact.

**Purpose:** Fix the honest boundary of what this validator can and cannot reach under its current strategic constraints, so that anchor design, task planning, and communication all target the same reachable end-state instead of a rhetorical one.

## Executive summary (three claims)

1. **Under current anonymity policy, this validator cannot pass direct institutional vendor due-diligence** (bank / credit union / ETF issuer). The 2026 institutional procurement floor is SOC 2 Type II + ISO 27001:2022 + a KYC'd legal counterparty, and any provider without those does not advance in procurement regardless of technical merit.
2. **The reachable strategic surface is:** (a) Metallicus non-banking subnet selection, (b) organic delegator flow from pseudonymous evaluators, (c) tooling / data producer positioning inside the Metallicus orbit. All three tolerate pseudonymous operators with verifiable technical substance.
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

Metallicus's positioning is "Metal Blockchain For Banking" and their high-visibility subnet initiatives are banking-oriented. Banking subnets will almost certainly require the KYC + certifications gate above, closing that path for anonymous operators.

Non-banking subnets on Metal may be reachable. There is no public roster of these as of this document's date; discovering them is itself a task.

**Source:**
- [Metal Blockchain Subnets Documentation](https://docs.metalblockchain.org/subnets)

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

1. **Metallicus non-banking subnet selection.** Requires: substantive on-chain track record, cycle-boundary uptime discipline, technical maturity signals, discoverability. Reachable with pseudonymous identity if the specific subnet does not gate on KYC.
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
| T-J-20260701 (Hetzner git divergence) | operational hygiene | keep, post-7/4 |

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
