# Final fix wave report

## 1. Correctness I1 (T8 false urgency) — scripts/check-pulsevm-upstream.sh
- S7 unread branch (~:1140-1157): an unreadable page now carries the previous record's mentions/chain_ids forward (read:false); with no prior record mentions is null (unknown). prev_official_field moved above the loop.
- T8 mention rule (~:1340-1350): fires only when the last recorded reading was a successful "no mention" (`false`). No record / null = silent baseline; `true` falls through to the chain-id comparison. Alert text reworded accordingly.
- Tests (tests/pulsevm-upstream/test-pulsevm-upstream.sh, case 21a, 5 new assertions): first-run mention silent; single unread after mention silent; unread record carries mention; read->unread->read silent; unread-first then mention silent.
- Mutations: (A) rule reverted to `!= "true"` -> first-run and unknown->mention cases FAIL; (B) unread record not carrying (mentions false) -> carry + recovery cases FAIL. Both restored.

## 2. Constitution IMP-1 — gate-1 drift
- New tests/a-chain-profile/test-gate1-drift.sh (auto-discovered by run-all): committed pulsevm-* gate1_evidence_profile must be null; failure message names the §9 clarification requirement.
- Mutation: temp copy with pulsevm-mainnet = "pulsevm-testnet" (GATE1_DRIFT_CFG) -> FAIL, rc 1.
- docs/A_CHAIN_PULSEVM_CUTOVER.md §3(a): day-of procedure = §9 clarification approved by operator, cite in profile commit, update drift test in same commit. CONSTITUTION.md untouched.

## Verification
pulsevm-upstream suite RESULT: PASS; run-all: OVERALL total=125 pass=125 fail=0, ALL PASS.
