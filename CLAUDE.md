# CLAUDE.md

Minimal guidance for AI assistance working in this repository.

## What this is

A Metal Blockchain mainnet validator project under the **"Freedom Yield"** brand. The validator has been live on mainnet since 2026-05-19.

## Governing documents

All work in this repository MUST conform to:

- [`docs/CONSTITUTION.md`](docs/CONSTITUTION.md) — the supreme reference for the project: operating priority order, absolute prohibitions, information classification (SECRET / CONFIDENTIAL / PUBLIC), infrastructure separation, communication discipline, public claims standard, scope boundaries, and amendment process.
- [`docs/OPERATING_MODEL.md`](docs/OPERATING_MODEL.md) — workflows (W1–W10) and the operator / AI / CI responsibility matrix.

When the two documents conflict, the Constitution prevails.

The pattern across all work: **AI proposes, operator approves, operator (or CI under the gate) executes, AI verifies output against the prior expectation.**

## Available documentation

- `docs/` — runbooks for setup, deployment, incidents, key rotation, renewal, security layers, disaster recovery.
- `TOOLKIT.md` — catalog of operational scripts in `scripts/`.

## Conventions

- Inline `style="..."` is forbidden by the site CSP (`style-src 'self'`). Define utility classes in CSS.
- Headings follow strict `h1 → h2 → h3` nesting; do not skip levels.
- Per Constitution §3.3, validator private keys, signing keys, mnemonics, and passphrases MUST NOT appear in any commit, encrypted or otherwise. `.gitignore` enforces extension-level blocks.
- Commits are single-purpose and explain *why*.

## Working with infrastructure

Per Constitution §5 and Operating Model W7, infrastructure changes are operator-approved and operator-executed. AI assistance produces commands, reviewable diffs, and verification steps; execution and final approval rest with the operator.
