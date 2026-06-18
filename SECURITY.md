# Security Policy

Thank you for taking the time to look into the security of this project.
We treat reports seriously and respond promptly.

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security reports.**
Email the details to:

```
bp@freedom-yield.com
```

Please include:

- A description of the issue and its potential impact
- Step-by-step reproduction
- Any proof-of-concept code or sample requests
- Your name / handle if you'd like to be credited

We will acknowledge receipt within **48 hours** (business days, JST).
You will receive a triage update within **7 days** with severity assessment
and an indicative fix timeline.
(coming soon — until then, plain email is acceptable for non-critical issues).

## Disclosure policy

We follow **coordinated disclosure** with a **default 90-day embargo**:

1. You report privately → we acknowledge
2. We triage, fix, and prepare a patch / mitigation
3. We coordinate a release window with you
4. Public disclosure (advisory + commit reference) on release day, or after
   90 days if no fix is possible, whichever is sooner
5. If a fix requires a longer window (e.g. coordination with Metallicus or
   Metal Blockchain core team), we will discuss with the reporter

Public disclosure includes:

- Advisory in this repo (`SECURITY.md` "Advisories" section or
  GitHub Security Advisories)
- Mention in the operator-facing site `/incidents/` page if user-visible
- Credit to the reporter unless they request anonymity

## In scope

- This repository's code (`public/**`, `caddy/Caddyfile`, scripts, workflows)
- Configuration / IaC that exposes attack surface (`docker-compose*.yml`,
  `.github/workflows/**`)
- Documentation that could mislead operators into insecure configurations
- The production deployment at `https://metal.freedom-yield.com/`
- The Metal Blockchain validator operated by Freedom Yield
  (when the NodeID is published on the site)

## Out of scope

- Vulnerabilities in upstream `metalgo` / Metal Blockchain core
  (please report to <https://github.com/MetalBlockchain/metalgo/security>)
- edge CDN / validator host infrastructure issues (please report to those vendors
  directly; we will assist with coordination if needed)
- DoS by simple traffic flood (we rely on edge CDN for that perimeter)
- Best-practice recommendations without a demonstrable security impact
  (welcome as GitHub issues, but not under this policy)
- Phishing / social engineering of operators (these are reported via
  general operational channels, not as security vulnerabilities)

## Hall of Fame

Researchers who responsibly disclose verified issues will be listed here
(with their consent) once we receive our first valid report.

| Date | Reporter | Issue |
|---|---|---|
| — | — | (no reports yet) |

## Related

- [docs/INCIDENT_RESPONSE.md](docs/INCIDENT_RESPONSE.md) — internal SEV
  classification and response playbook
- [docs/KEY_ROTATION.md](docs/KEY_ROTATION.md) — validator key rotation /
  compromise response procedure

## Operator contact

Freedom Yield (Japan region, Japan) — `bp@freedom-yield.com`
