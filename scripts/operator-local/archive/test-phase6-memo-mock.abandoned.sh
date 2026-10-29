#!/usr/bin/env bash
# scripts/operator-local/archive/test-phase6-memo-mock.abandoned.sh
#
# ABANDONED 2026-06-20. P-Chain AddPermissionlessValidatorTx memo embed
# is forbidden post-Durango (MetalBlockchain/metalgo
# vms/components/avax/base_tx.go VerifyMemoFieldLength). Metal mainnet
# Durango activated 2024-05-06 08:00 UTC.
#
# The current identity model is an operator-signed artifact snapshot
# without P-Chain anchor. Prior mock implementation is in git history.

echo "This Phase 6 mock was abandoned 2026-06-20." >&2
echo "P-Chain memo embed is not possible post-Durango." >&2
echo "See git history for prior implementation." >&2
exit 1
