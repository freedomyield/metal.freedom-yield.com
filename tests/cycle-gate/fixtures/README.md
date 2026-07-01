# tests/cycle-gate/fixtures/

Static input fixtures for the cycle-gate unit test suite (`tests/cycle-gate/*.sh`).

## Files tracked in git

| file | purpose |
|---|---|
| `chain-empty.json` | RPC response with empty validators array (drives fail-closed branch) |
| `chain-matches.json` | RPC response containing our NodeID (drives green branch) |
| `state-matches.json` | cycle-gate-state.json with matching signature (drives green branch) |
| `state-old.json` | cycle-gate-state.json with stale signature (drives fail-closed branch) |

## Files git-ignored (see `../.gitignore`)

| file | purpose | rotation policy |
|---|---|---|
| `test-identity-key` | ed25519 private key for signing-test paths only | regenerable on demand; MUST NOT be reused as an operator identity key |
| `test-identity-key.pub` | matching public key | regenerated with the private half |

## Expected `gitleaks --no-git` (working-tree) hits

The working-tree scan (`gitleaks detect --no-git --source .`) is expected to report `test-identity-key` as an OPENSSH PRIVATE KEY match. This is an **acceptable false-positive**:

- The file is git-ignored (`tests/cycle-gate/.gitignore:5`).
- The file has never been tracked (`git ls-files tests/cycle-gate/fixtures/` does not include it).
- The key is a synthetic test fixture; no on-chain identity is derived from it, no runbook grants it any authority, no production script reads it.

Audit protocol acknowledgement: when the audit checklist runs a working-tree gitleaks scan, this hit is expected and MUST be enumerated as expected before advancing. Any additional hit is a genuine finding.

## Regenerating `test-identity-key`

If the local fixture is missing or needs rotation:

```sh
ssh-keygen -t ed25519 -N '' -C 'cycle-gate test fixture — NOT AN OPERATOR KEY' \
  -f tests/cycle-gate/fixtures/test-identity-key
```

The `-N ''` empty passphrase is intentional; the test suite reads the key without an unlock step.
