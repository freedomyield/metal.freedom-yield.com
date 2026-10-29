# Phase 6 execution checklist — abandoned 2026-06-20

This checklist previously described how to embed an operator identity
public-key fingerprint into the `AddPermissionlessValidatorTx` memo at
each renewal cycle.

The model has been **abandoned**. Read-only verification of
`MetalBlockchain/metalgo` source confirmed that:

- `VerifyMemoFieldLength` in `vms/components/avax/base_tx.go` rejects
  any non-empty memo when Durango is active.
- `verifyAddPermissionlessValidatorTx` in
  `vms/platformvm/txs/executor/staker_tx_verification.go` applies this
  gate with the dynamic `isDurangoActive` flag.
- Metal mainnet Durango activated at `2024-05-06 08:00:00 UTC`
  (`upgrade/upgrade.go`).

The cycle 1 (committed 2026-05-19) and cycle 2 (committed 2026-06-04)
AddValidator transactions were submitted with empty memo. Under the
currently active protocol rules, validator renewals must use an empty
memo. Future protocol changes are out of scope for this checklist.

The identity model has been revised to an **operator-signed artifact
snapshot without a P-Chain anchor**. The renewal runbook for the
signed-snapshot model lands in a follow-up commit.

Prior implementation of this checklist is preserved in git history.
