# A-Chain → PulseVM migration readiness — spec + plan

Date: 2026-09-30. Operator decisions (2026-09-30):
- The A-Chain migration to PulseVM is treated as near-certain. Prepare so nothing breaks.
- Do ①②③ now (not deferred past the 2026-10-07 cycle 5→6 transition).
- Publish the archived legacy anchor records on the public site.

Research inputs (read the relevant sections; do not re-derive):
- `.superpowers/sdd/2026-09-30-pulsevm-migration-readiness/pulsevm-migration-repo-exposure.md` (repo exposure map, file:line)
- `.superpowers/sdd/2026-09-30-pulsevm-migration-readiness/pulsevm-migration-upstream.md` (PulseVM upstream facts + client checklist)

## Why

Facts measured from PulseVM upstream code (see upstream report): on migration the chain_id becomes NEW (hex of the
MetalGo blockchain ID); accounts, permissions, linkauth and K1/R1/WebAuthn keys are imported; block numbers continue
at H+1; blocks before the cut are NOT on the new chain; push returns only `{transaction_id}`; the node exposes 14
`/v1/chain/*` endpoints at `/ext/bc/<blockchainID>/v1/chain/*` and NO `/v1/history/*`; history lives on a separate
Hyperion host; LIB == head. Cutover is stop-and-import, undated.
In this repo, mainnet anchoring (bin/safe-broadcast gates 1 and 3 and the push), receipt generation (hardcoded host,
runs after the irreversible broadcast), and third-party verification of past anchors (memos in history only) all break.

## Global Constraints (binding on every task)

P1. **The 2026-10-07 transition must not regress.** The default chain profile is the current XPR network. With the
    default profile, every existing command, output shape, exit code and gate decision on the XPR path stays the same
    — pinned by the existing tests plus new equivalence tests. Anything PulseVM-specific is dormant unless the
    operator selects the PulseVM profile explicitly.
P2. **PRIME DIRECTIVE.** No task broadcasts anything, on any chain. No task runs proton-cli against a network.
    Tests stub proton-cli and HTTP. The four gates keep their meaning; they may only get stricter. No fail-open.
P3. **Fail closed, before the broadcast.** Anything that must succeed after a broadcast (history lookup for the
    receipt) is checked for reachability BEFORE the broadcast, and a failure there stops before signing.
P4. **Public repo hygiene** (as in docs/superpowers/plans/2026-09-29-external-watch.md G1/G2): no host IPs, no
    provider/region names in new prose, no ntfy topic. Chain IDs, public RPC/history hostnames and explorer URLs of
    public chains ARE publishable (they are public infrastructure, and they are required for verification).
    Never write the operator's keystore paths beyond what Constitution §3.5 already publishes.
P5. **Tests**: plain bash under tests/<area>/, executable, discovered by `bash tests/run-all-tests.sh`; stubs on PATH;
    shellcheck -x clean (validate.yml). Every protective test is shown to fail once against a deliberately broken
    implementation (mutation), recorded in the task report. Keep suites fast.
P6. **AI-session guard**: a Claude PreToolUse guard (scripts/broadcast-guard.sh) blocks Bash command text that looks
    like a raw broadcast or an HTTP client call to `/ext/bc/[XPC]`. Never type such command text; put URLs in files and
    stub HTTP in tests. Note: PulseVM node URLs are `/ext/bc/<blockchainID>/…`, so never type them in Bash either.
P7. **Constitution**: do not edit docs/CONSTITUTION.md. Where PulseVM makes a rule unsatisfiable (gate 1 "corresponding
    testnet"), record it as an OPEN operator decision in the runbook, and keep the code fail-closed on it.

## Design

A single committed chain-profile file is the only place chain-specific values live:
`config/a-chain-profiles.json` — profiles keyed by name:
- `xpr-mainnet` (DEFAULT for mainnet): chain_id `384da888…` (current constant), node/push endpoint allowlist (hosts
  currently in scripts/install-rehearsal-preflight.sh MAINNET_HOST_ALLOWLIST), history (Hyperion v2) endpoint(s)
  (currently the hardcoded one in scripts/gen-anchor-receipt.sh), explorer base, proton-cli network name `proton`,
  `push_response`: "processed" (current behaviour).
- `xpr-testnet` (DEFAULT for testnet): same shape from the current testnet constants/allowlists.
- `pulsevm-mainnet`, `pulsevm-testnet`: chain_id `null` (unknown until published → any use fails closed with a clear
  message), endpoint/history allowlists empty or the publicly documented ones from the upstream report, `push_response`:
  "id-only" (confirm via history polling), `lib_equals_head`: true.
Selection: env `FYD_A_CHAIN_PROFILE_MAINNET` / `FYD_A_CHAIN_PROFILE_TESTNET` (defaults xpr-*). Existing
`FYD_*_CHAIN_ID` overrides keep working and must equal the profile value or fail closed.
A small library `scripts/lib/a-chain-profile.sh` reads the file with jq and exposes getters; it validates the file
(schema-like checks) and fails closed on anything missing.

## Tasks

### Task 1: archive the legacy anchor records (independent; do first)
Files: new `scripts/archive-legacy-anchors.sh`, `public/api/archive/legacy-a-chain/` (data), tests.
For every anchor tx_id already recorded in the public anchor history/receipts (public/api anchor-history.jsonl and
archived receipts as published on the site — read from the live public site or the repo's published copies; see
deploy/publication.json), fetch the raw Hyperion v2 `get_transaction` response (and the block via
`/v1/chain/get_block` from an allowlisted XPR node, block_id included) from the legacy XPR hosts, store each as
`public/api/archive/legacy-a-chain/<tx_id>.json` verbatim plus a `manifest.json` (tx_id, block_num, block_id,
chain_id 384da888…, fetched_at, source host, sha256 of each file). Idempotent; never overwrites a file whose sha256
differs (fail closed and report). Also a machine-checkable verifier `scripts/verify-legacy-anchor-archive.sh` that
checks each archived record against the receipt (tx_id, block_num, the 4 memos) offline.
The controller runs the fetch once after review (read-only HTTP GETs; not a broadcast). Publication follows the
normal deploy (public/). Hosts come from the xpr profile in config (Task 2 may land later — for Task 1 define the
two hosts as script constants and note that Task 5 switches them to the profile).

### Task 2: chain-profile config + library (interface for Tasks 3–5)
Files: `config/a-chain-profiles.json`, `scripts/lib/a-chain-profile.sh`, tests. Values for xpr-* are the CURRENT
constants/allowlists found in the repo (cite each source line in a comment in the report). PulseVM profiles as in
Design. Getters: chain_id, node_hosts (allowlist), history_bases, explorer_base, proton_network, push_response,
lib_equals_head. Validation fails closed. Include the repo's no-drift test: the constants still present elsewhere must
equal the profile (until Tasks 3–5 remove them).

### Task 3: bin/safe-broadcast on profiles (after Task 2)
- Gate 3: chain_id from the profile (FYD_* override must match); add a host check — the endpoint proton-cli will use
  (from the project keystore's proton-cli.json, the same method install-rehearsal-preflight.sh uses) must be in the
  profile's node_hosts allowlist, else exit 3. This closes the clone gap on the mainnet path (default xpr profile
  allowlist = current preflight MAINNET_HOST_ALLOWLIST).
- Gate 1: evidence source = the testnet profile's history_bases; accept both the v1 history shape and Hyperion v2
  `get_transaction` shape (`trx_id`/`actions`), same strictness as today.
- Push: for `push_response: id-only`, accept a push output that has only `transaction_id`, then confirm execution by
  polling the profile's history_bases for that tx_id (bounded retries, fail closed with the tx_id printed so the
  operator knows a broadcast may have happened).
- With default profiles, behaviour identical to today (equivalence tests).

### Task 4: receipts + history ledger on profiles (after Task 2; parallel with Task 3)
- scripts/gen-anchor-receipt.sh: history base from the profile (remove hardcoded host; keep `--rpc` override but it
  must be in the profile's history_bases unless an explicit `--allow-unlisted-rpc` for rehearsal is given — decide
  and document); record `chain_id`, `block_id` (from history or get_block), and `chain_profile` in the receipt.
- Schema: add a v3 receipt/history schema (additive fields; v2 consumers unaffected); publish example; keep v2 files.
- scripts/append-anchor-history.sh: invariant 5 keyed per chain_id (block_num monotonic within a chain_id; a new
  chain_id starts a new era and is allowed only if the new chain_id matches a known profile).
- Pre-broadcast reachability check: a new `scripts/check-anchor-history-reachable.sh` used by
  scripts/run-anchor-pipeline.sh and the cycle-transition day-of steps BEFORE signing (P3).
- Fix the dead v1 fallback (expects `.actions`; v1 has `.traces`).

### Task 5: rehearsal/preflight/steps/watch/docs (after Tasks 3–4)
- install-rehearsal-preflight.sh allowlists and run-testnet-rehearsal.sh endpoints from the profile (same values).
- docs/cycle-transition-steps.json and scripts/cycle-transition.sh day-of commands: add the reachability check;
  otherwise unchanged for the default profile.
- scripts/check-pulsevm-upstream.sh: new triggers — (T6) a MetalBlockchain/metalgo release without the `-tahoe`
  suffix at ≥ v1.14 (mainnet Granite), (T7) a PulseVM GitHub release ≥ v1.0.0, (T8) an official PulseVM mainnet
  chain_id / cutover document on Metallicus-owned properties. Fix the stale line references and "four changes" text.
- Archive fetch hosts switch to the profile.
- New runbook `docs/A_CHAIN_PULSEVM_CUTOVER.md`: what to set on cutover day (profile values once published), freeze
  behaviour (fail closed during the write freeze), verification of the first PulseVM anchor, legacy archive, and the
  OPEN operator decisions: (a) which network satisfies PRIME DIRECTIVE gate 1 on PulseVM, (b) whether chain_id policy
  differs from upstream code.
- Update docs/STRATEGIC_TARGET_ALIGNMENT.md "What PulseVM changed" with the 2026-09-30 facts (dated) and the operator
  decision superseding "no pre-emptive rewiring"; public/verify pages: add how to verify legacy anchors via the archive.

## After the tasks
Final audit team (security / PRIME DIRECTIVE & constitution / correctness incl. 10/7-path equivalence / test
efficacy, time-boxed). Then, BEFORE merging to main: an XPR testnet rehearsal of the full anchor pipeline with the new
code (operator unlocks the testnet keystore; no mainnet action). Then push.
