# Metallicus subnet shortlist

**Status:** discovery result, 2026-07-01.
**Purpose:** enumerate every Metal Blockchain subnet that a pseudonymous validator could realistically target for selection, and grade each for feasibility under our current anonymity policy.

## Observation summary

**As of 2026-07-01, Metal Blockchain has zero subnets registered beyond the Primary Network.** The explorer at `https://explorer.metalblockchain.org/subnets` displays only the three primary chains (C-Chain, P-Chain, X-Chain) with the note "More Subnets Coming Soon." No named subnet operators appear anywhere in the public surface.

This is the load-bearing finding. Every other assessment in this document is subordinate to it.

## What is public

**Explorer snapshot (`explorer.metalblockchain.org/subnets`):**
- Primary Network: 3 chains (C-Chain, P-Chain, X-Chain), 210 validators, 63k+ / 123k+ / 3.9k blocks respectively.
- Subnet count beyond Primary Network: **0**.
- Placeholder text: "Metal Blockchain supports permissioned and permissionless subnets. As new subnets are deployed they will appear here with their validators, blockchains, and activity."

**Metal Blockchain Banking Innovation Program (Metallicus blog, announced 2024-03-07; last confirmed post 2026-06-30):**
- Vibrant Credit Union enrolled (per 2024-03-07 announcement).
- Program vocabulary: "Digital Identity, Single Sign-On (SSO), Private Subnets, Tokenization of Assets."
- **No specific subnet is announced as live for any Banking Innovation Program participant.** Vibrant is described as "exploring blockchain solutions" — not operating a dedicated subnet.
- No validator selection criteria are published.

**Metallicus Q1 2026 report (via news search):**
- "Q1 2026 was a quarter of execution across Metallicus" — focus on "production-ready infrastructure for credit unions, wallet users, and the broader digital-asset ecosystem."
- No subnet launch dates.

**Metal L2 (separate from A-chain):**
- Metal L2 is an Optimism-derived rollup, not a Metal Blockchain subnet.
- Metal L2 Upgrade 19 scheduled 2026-07-08 16:00 UTC.
- Relevant only tangentially: Metal L2 has its own operator surface; not the anchor target of this project.

## Shortlist (with grades)

| # | subnet target | status | selection criteria (public) | pseudonymous OK? | our action |
|---|---|---|---|---|---|
| 1 | Any subnet launched by a Banking Innovation Program participant (Vibrant Credit Union or successors) | not yet live | not published; probable KYC + legal counterparty + jurisdictional constraint (banking regulatory) | **no** — banking subnets will almost certainly require KYC | monitor announcements; do not attempt to apply until requirements are published |
| 2 | Any non-banking permissionless subnet | not yet live | none exist as of 2026-07-01 | **unknown until announced** | monitor; announcement date + criteria set our first evaluable data |
| 3 | Any Metallicus-run subnet (e.g. tokenization sandbox, developer testbed) | not yet live | none exist | unknown | monitor |
| 4 | Foundation delegation on Primary Network (not a subnet, but same distribution channel) | live channel, no public program | none published | inherent to Primary Network — no additional selection gate beyond existing validator status | continue accumulating cycle history; passive availability |

**Everything on this shortlist is currently `not yet live`.** The shortlist is a placeholder for a future evaluation, not an action list.

## What this means for strategy

Direct implication for `docs/STRATEGIC_TARGET_ALIGNMENT.md`'s "reachable set":

- Path (a) "Metallicus non-banking subnet selection" — **theoretical**, no subnets exist to be selected for as of this document.
- Path (b) "Organic delegator inflow" — **empirically live**, evidenced by the 2026-06-08 receipt of 23,428 METAL (returned at duration expiry 2026-07-01). This is our only actively working path.
- Path (c) "Data / tooling producer positioning" — **aspirational**, dependent on us publishing verifiable machine-readable artifacts (this repo already does), but no external consumer has cited them.
- Path (d) "Foundation delegation" — **inactive**, no public program.

The shortlist confirms that the *technical readiness* work in this repo (anchor v2, verify gates, test suites, tier-1/tier-2 enforcement) is preparation for a market that does not yet exist. That is a valid strategic posture — the alternative (waiting to build until a subnet is announced) would leave us months behind whoever else is preparing — but the readiness must be presented as such: readiness, not activity.

## Monitoring cadence

Because the current shortlist is empty, this document doesn't need per-item tracking. Instead, monitor the following surfaces and re-run the discovery when any of them changes:

- `https://explorer.metalblockchain.org/subnets` — first-order canonical source. If subnet count changes from 0, re-run.
- `https://www.metallicus.com/news` and `https://www.metallicus.com/blog` — announcement channel.
- `@MetalNodes` (X/Twitter observation account) — sometimes surfaces validator-set-relevant changes before official channels.
- Metallicus Discord / community channels — indirect signals (per `feedback_no_self_intro_to_metallicus`, we monitor, we do not participate).

Suggested cadence: monthly re-run of this discovery. Faster if a Banking Innovation Program announcement surfaces.

## Non-goals

This document does not:

- Reach out to Metallicus, Vibrant, or any Banking Innovation Program participant. Per `feedback_no_self_intro_to_metallicus`, name-drop outreach without substance is desperation signaling.
- Recommend abandoning the anonymity policy in anticipation of a KYC-gated banking subnet. That is a separate operator decision documented in `docs/STRATEGIC_TARGET_ALIGNMENT.md`.
- Speculate on Foundation delegation program parameters. If a program is announced, it will get its own discovery pass.

## Sources

- [Metal Blockchain Explorer — Subnets](https://explorer.metalblockchain.org/subnets)
- [Metal Blockchain Subnets Documentation](https://docs.metalblockchain.org/subnets)
- [Vibrant Credit Union Joins Metal Blockchain's Banking Innovation Program — Metallicus, 2024-03-07 (last confirmed 2026-06-30)](https://www.metallicus.com/blog/vibrant-credit-union-blockchain)
- [Metallicus Newsroom](https://www.metallicus.com/news)
- [Metal Blockchain — Blockchain For Banking (landing)](https://metalblockchain.org/)

## Change log

- **v1 (2026-07-01):** Initial discovery result. Empty shortlist confirmed; no subnets registered on Metal Blockchain beyond the Primary Network.
