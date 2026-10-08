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
- [`docs/OPERATING_MODEL.md`](docs/OPERATING_MODEL.md) — workflows (W1–W11) and the operator / AI / CI responsibility matrix.

When the two documents conflict, the Constitution prevails.

The pattern across all work: **AI proposes, operator approves (per change), the AI (or CI under the gate, or the operator personally) executes, AI verifies output against the prior expectation.**

## Available documentation

- `docs/` — runbooks for setup, deployment, incidents, key rotation, renewal, security layers, disaster recovery.
- `TOOLKIT.md` — catalog of operational scripts in `scripts/`.

## Conventions

- Inline `style="..."` is forbidden by the site CSP (`style-src 'self'`). Define utility classes in CSS.
- Headings follow strict `h1 → h2 → h3` nesting; do not skip levels.
- Per Constitution §3.3, validator private keys, signing keys, mnemonics, and passphrases MUST NOT appear in any commit, encrypted or otherwise. `.gitignore` enforces extension-level blocks.
- Per Constitution §3.5, any `proton-cli` command MUST carry an explicit project keystore prefix (`HOME=~/.metal-fy-proton` mainnet / `HOME=~/.metal-fy-proton-test` testnet); never present or run a bare `proton …` against the default shared keystore.
- Commits are single-purpose and explain *why*.

## Working with infrastructure

Per Constitution §5 (v0.7, narrowed by v0.8) and Operating Model W7, every validator-host change is approved by the operator **per change, explicitly, in chat**; the AI then executes it on the host and verifies the output against the stated expectation (a mismatch halts and returns to the operator). Approval always rests with the operator; silence, a keystore unlock, or a general instruction is not approval. The operator's own manual work is limited to keystore unlock / lock, passwords / passphrases, wallet-UI operations, and validator key generation / installation / destruction (Operating Model W5). CI touches the validator host only along W6's fixed path (deploy-path `mkdir`, host checkout fast-forward with its lossless self-heal, `public/` rsync); it delivers tracked files but never builds, starts, stops, recreates, reloads or configures any container there — no Caddy or other web server runs on the validator host since 2026-10-07 (v0.8, a tightening approved by the operator that day, effective at merge). Broadcasts remain governed solely by the PRIME DIRECTIVE. (v0.7: a clarification approved by the operator on 2026-10-07, effective immediately.)

Manual changes on the **web host** (Constitution §5 v0.9, Operating Model W7 web-host scope) follow the same pattern — per-change explicit operator approval in chat → AI executes → AI verifies — limited to this project's own container `caddy-static` and this project's own files on that shared host; §5's multi-tenant scoping still applies (no host-wide operation), and §3.3's per-action approval for destructive actions is unchanged. v0.9 is a loosening amendment approved by the operator in chat on 2026-10-08 and takes effect **seven days after merge (merged 2026-10-08 10:56 JST (merge commit 6da8456) → effective 2026-10-15 10:56 JST (merge + 7 days))**. Until then the AI MUST NOT execute any manual web-host change (including every web-host mode of `scripts/web-host-caddy-apply.sh`: `--check`, `--apply`, `--rollback`); the operator may run it personally. CI's web-host path is the `public/` rsync only.
