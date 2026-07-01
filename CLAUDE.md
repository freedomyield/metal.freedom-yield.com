# CLAUDE.md

Minimal guidance for AI assistance working in this repository.

## ⛔ PRIME DIRECTIVE — READ FIRST, BEFORE ANY OTHER ACTION ⛔

**Before invoking any command, tool, or API call in this repository, every AI session MUST read [`docs/CONSTITUTION.md`](docs/CONSTITUTION.md) — specifically the `PRIME DIRECTIVE — TESTNET-FIRST FOR ALL BROADCASTS` block at the top of that file.**

**Summary of the Prime Directive (non-authoritative — the Constitution is authoritative):** you MUST NOT invoke any broadcast-capable command (`proton action`, `proton transaction`, `proton transaction:push`, `cleos push_transaction`, RPC `push_transaction` / `issueTx` / `eth_sendRawTransaction`, or any equivalent) against any mainnet unless all four gates in the Prime Directive are simultaneously satisfied: (1) testnet-first success on the identical command shape, (2) explicit per-invocation operator authorization naming the exact `{chain, actor, permission, action, memo, quantity}`, (3) pre-flight `chain:get` verification, (4) exhausted `--dry-run` / offline-sign options. On any ambiguity: refuse, stop, ask.

This directive was written on 2026-07-01 immediately after an AI session in this same repository invoked `proton transaction:push` without a chain check and permanently polluted the anchor namespace on Metal A-chain mainnet (tx `997881e844befaf9c159c741988fe99e8ca566a52e539639ab83517b1f36100a`). The failure occurred despite the session having authored the exact rule it then broke. Codification in a low-priority sub-section was demonstrably insufficient. If you are reading this and about to invoke any broadcast-capable command against mainnet, this is the moment to stop and confirm.

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
