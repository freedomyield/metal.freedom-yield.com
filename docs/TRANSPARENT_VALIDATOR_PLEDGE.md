# Transparent Validator Pledge — v1.0

> A minimum disclosure standard for blockchain validator operators.
> Status: Draft (v1.0)
> License: CC0 / public domain dedication
> Adoption is voluntary. Modification is welcome. No attribution to any specific operator is required.

## Why

Validators on proof-of-stake networks face a recurring evaluator burden: anyone considering a delegation, an institutional engagement, or a peer-collaboration ends up asking the same handful of questions — what is the uptime track record, how are incidents handled, how stable is the fee, what happens if the operator exits, and who is on the other side of the contract. Today every validator answers these in an ad-hoc way, or not at all, which means every reviewer redoes the same lookup work.

Anonymous operation is a valid choice. Many validators rationally choose it for security or personal-safety reasons, and this document does not condemn that posture. The Pledge is for validators who have chosen a public stance and want a shared minimum-disclosure pattern that reduces friction for the people who evaluate them.

The Pledge is a baseline, not a ceiling. Adopters can disclose more than it asks for. Forkers can tighten or relax it. There is no central registry, no compliance authority, and no required URL layout.

## Scope

Applies to: any validator on any proof-of-stake chain.
Does not require: identity disclosure beyond a brand identity + contact.
Does not impose: specific technical implementations — only the existence of disclosed artifacts.

## The five articles

### Article 1 — Uptime track record

**Definition.** The validator publishes a machine-readable record of uptime, organized by validation period / cycle, with each period's start, end, final uptime percentage, and an on-chain transaction reference that an independent reader can verify.

**Minimum form.** A static JSON or JSONL endpoint at a stable URL. Updated at least once per closed cycle.

**Why.** Uptime is a directly evaluable validator metric. A track record that the validator self-publishes — and that a reviewer can independently cross-check on chain — costs the validator little and saves every reviewer the same lookup work.

### Article 2 — Incident transparency

**Definition.** The validator publishes a log of operational incidents (downtime, key incidents, push pipeline failures) with: incident date (ISO 8601), severity classification, scope of impact, root cause summary, and resolution time.

**Minimum form.** A page or JSON endpoint at a stable URL. An empty list signals no incidents (not concealed).

**Why.** Incidents are how operators reveal whether they handle bad days predictably. Hiding them creates a worse signal than disclosing them.

### Article 3 — Fee stability

**Definition.** The validator's delegation fee is published, and changes to it are announced in advance with a defined notice period (suggested: at least one full cycle before the change takes effect).

**Minimum form.** Current fee shown on a stable URL. Notice of any future fee change posted at the same URL or a connected page.

**Why.** Delegators expect a stable contract. A change without notice is a unilateral re-pricing.

### Article 4 — Decommission notice

**Definition.** If the validator is going to stop operating, a public notice is committed in advance with a defined minimum lead time (suggested: at least 90 days for low-frequency delegators, longer if the validator hosts large or institutional delegations).

**Minimum form.** A statement of the policy on a stable URL. Activation of the notice (if it ever happens) at the same URL.

**Why.** Delegators have unbonding windows and reallocation lead-times. A surprise exit is the worst outcome for them.

### Article 5 — Identity disclosure standard

**Definition.** At minimum: a brand identity, a stable contact, and a jurisdictional disclosure (country level, not address). The validator may go further (legal entity name, individual operator name) but is not required to. Anonymous validators are not condemned by this article; they simply do not adopt the Pledge.

**Minimum form.** A statement on a stable URL identifying the brand, the contact, and the jurisdiction at country granularity.

**Why.** Reviewers need a stable way to reach the operator and to know which legal framework an engagement would fall under. Country-level granularity is enough to scope due diligence; finer detail is the operator's choice.

## Adoption mechanism

A validator adopts the Pledge by publishing:

1. A compliance statement on a stable URL on their own site.
2. A machine-readable adoption manifest (suggested filename: `/api/pledge-adoption.json`; schema sketch below).

### Adoption manifest schema sketch (informational)

```
{
  "pledge_version": "1.0",
  "adopter": { "brand": "...", "site": "...", "contact": "...", "jurisdiction": "..." },
  "articles": {
    "1_uptime_track_record": { "url": "...", "format": "json|jsonl|html" },
    "2_incident_transparency": { "url": "...", "format": "..." },
    "3_fee_stability": { "url": "...", "notice_period_cycles": 1 },
    "4_decommission_notice": { "url": "...", "notice_period_days": 90 },
    "5_identity_disclosure": { "url": "..." }
  },
  "adopted_at": "ISO 8601"
}
```

The schema is suggestive; the Pledge does not require this exact shape.

## Versioning

Semantic versioning.

- Patch (1.0.0 → 1.0.1): editorial / clarification.
- Minor (1.0 → 1.1): backwards-compatible addition (e.g. a new article that adopters can choose to add).
- Major (1.0 → 2.0): stricter requirements or removed articles.

Adopters declare which version they adhere to.

## License

This document is released into the public domain under CC0 1.0 Universal. No attribution required. Forks, derivatives, translations are all permitted. There is no central registry; adoption is signaled at the adopter's own URL.

## Freedom Yield specimen mapping

The Freedom Yield Metal validator adopts the Pledge. Mapping of Pledge articles to Freedom Yield artifacts:

| Article | Freedom Yield artifact |
|---|---|
| 1. Uptime track record | `/journal/` + `/api/uptime-cycles.json` |
| 2. Incident transparency | `/incidents/` + `/api/incidents.json` |
| 3. Fee stability | `/commitments/` (§ Fee policy) + `/api/validator.json` |
| 4. Decommission notice | `/commitments/` (§ Decommission notice) — 90 days |
| 5. Identity disclosure | `/jurisdiction/` + brand identity "Freedom Yield" + `bp@freedom-yield.com` |

The Freedom Yield specimen is one possible shape. Other adopters may map differently — there is no required URL layout.

## Contributing

Improvements, translations, and forks welcome via pull requests to the repository where this document lives. Maintainer authority is purely editorial; any disagreement that cannot be resolved editorially may be resolved by forking the Pledge.

## Acknowledgements

Inspired by the pattern of minimum-disclosure standards in adjacent fields: `CODE_OF_CONDUCT.md` and `SECURITY.md` for open-source projects; rating-agency disclosure templates for traditional finance; the Avalanche / Metal validator community's emerging norms around transparent operation.
