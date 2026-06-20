# Phase α testnet dry-run runbook

> **Purpose**: rehearse the full Phase α A-chain anchor pipeline on XPR
> testnet (= `proton-test` chain) before the first mainnet inscription
> at cycle 3 start (2026-07-04 13:00 JST).
>
> **Authority**: this runbook is an operator-executed sequence on
> XPR testnet only. Per Constitution §5, mainnet steps remain
> separately operator-approved; the dry-run does not unblock any
> mainnet step automatically. Successful completion of this runbook
> is the **IC-2 PASS** deliverable in the Phase α coordination plan.
>
> **Owner**: C2 (= drafted as part of the C3 takeover, T-9).
> **Scope**: testnet operations only. No mainnet command in this
> document is intended for unsupervised execution.

## Pass/fail criteria

The rehearsal passes when ALL of the following are observable in a
single end-to-end run:

1. A test `freedomyield`-style account exists on XPR testnet with the
   same three-permission shape (`owner` + `active` + `anchor`).
2. The `anchor` permission has a `linkauth` to `eosio.token::transfer`.
3. `scripts/sign-anchor-event.sh cyclestart <hex>` (no `--dry-run`)
   broadcasts a transfer on testnet, returns a JSON receipt fragment
   on stdout, exit code 0.
4. The receipt's `tx_id` resolves on a public XPR testnet explorer
   and shows the action with the correct `memo` field equal to
   `fyid1:<hex>`.
5. The receipt's `tx_id` resolves on the XPR testnet RPC endpoint
   (`https://api-xprnetwork-test.saltant.io/v1/history/get_transaction`)
   and the returned action data agrees with the receipt.
6. The receipt JSON fragment validates against
   `/api/anchor-receipt.schema.v1.json` once embedded in a full
   anchor-receipt document (verified via `ajv validate`).

The rehearsal fails on any of:

- The broadcast command exits non-zero.
- The receipt JSON parses but the explorer cannot find the `tx_id`.
- The memo on the explorer does not equal `fyid1:<hex>`.
- The signer permission shown on the explorer is not
  `freedomyield-style@anchor`.

A failure halts the mainnet activation; the cause is diagnosed and
the rehearsal is re-run before mainnet proceeds.

## Prerequisites

- The operator has reached B5 self-test PASS for the mainnet
  installation (= the mainnet anchor key is deployed and the dry-run
  validates). This is the gate that proves the operator-side keystore
  and CLI are functional; the testnet rehearsal then exercises the
  network-broadcast path that the B5 dry-run intentionally skipped.
- The validator host has `proton-cli` 0.1.98+ installed and
  reachable to the `deploy` user.
- The operator has access to the XPR testnet faucet (typically via
  `https://webauth.com/testnet` or the Proton testnet web wallet).

## Step 1 — Provision a test account on XPR testnet

```sh
# Switch CLI to testnet.
proton chain:set proton-test

# Create a fresh test account name. The name MUST NOT collide with the
# mainnet 'freedomyield' account; it MUST NOT include a brand identifier.
# Suggested form: a deterministic but anonymous name like 'fytestNNN'
# where NNN is a random three-digit suffix. Length 1..12, chars [a-z1-5.].

TEST_ACCOUNT="fytest$(printf '%03d' $((RANDOM % 1000)))"
echo "Test account: ${TEST_ACCOUNT}"

# Sign up via the testnet faucet for ${TEST_ACCOUNT}; the faucet
# provisions the account with an owner/active K1 keypair. Capture both
# keys for the rehearsal (transient — discard at end of run).
```

The test account is throwaway: it exists only for the duration of the
rehearsal and is discarded afterwards. The keys are not committed to
Dashlane or any persistent store.

## Step 2 — Reproduce A4 (anchor K1 key generation) for the test account

```sh
proton key:generate
# Capture:
#   PUB_K1_<test_anchor>
#   PVT_K1_<test_anchor>
# These are testnet keys; they are not stored in Dashlane and are
# discarded at end of rehearsal.
```

## Step 3 — Reproduce A6 + A7 (permission install + linkauth) on testnet

```sh
# A6 analog: add `anchor` as child of `active`.
proton action eosio updateauth '{
  "account": "'${TEST_ACCOUNT}'",
  "permission": "anchor",
  "parent": "active",
  "auth": {
    "threshold": 1,
    "keys": [{"key": "PUB_K1_<test_anchor>", "weight": 1}],
    "accounts": [],
    "waits": []
  }
}' ${TEST_ACCOUNT}@active

# A7 analog: linkauth anchor → eosio.token::transfer.
proton action eosio linkauth '{
  "account": "'${TEST_ACCOUNT}'",
  "code": "eosio.token",
  "type": "transfer",
  "requirement": "anchor"
}' ${TEST_ACCOUNT}@active
```

Verify both succeed; both produce testnet tx_ids resolvable on the
testnet explorer.

## Step 4 — Provision a test sink account

```sh
# Create a second testnet account (= the sink). Same naming
# constraints as Step 1 (anonymous, non-brand).
TEST_SINK="fysink$(printf '%03d' $((RANDOM % 1000)))"
echo "Test sink: ${TEST_SINK}"
# Sign up via faucet; capture the keys (also transient).
```

## Step 5 — Deploy the test anchor key on the validator host (TEST mode)

This mirrors §B3 + §B4 from `docs/OPERATOR_IDENTITY_SETUP.md` but
points the validator-host config at testnet. The mainnet config
under `/etc/freedom-yield/` is **not modified**; instead, a sibling
directory is used so the two coexist.

```sh
# Choose a non-collision config dir for the rehearsal.
TEST_CONFIG_DIR=/etc/freedom-yield/testnet

# As deploy user on the validator host:
ssh "${VALIDATOR_SSH_HOST}" 'sudo install -d -m 0755 -o root -g root '"${TEST_CONFIG_DIR}"

# Push the test anchor private key (PVT_K1_<test_anchor> from Step 2).
ANCHOR_KEY_TMP="$(mktemp -t anchor.k1.XXXXXX)"
# Paste PVT_K1_<test_anchor> into ${ANCHOR_KEY_TMP}.
scp -p "${ANCHOR_KEY_TMP}" \
    "${VALIDATOR_SSH_HOST}:${TEST_CONFIG_DIR}/anchor.k1.key.incoming"
ssh "${VALIDATOR_SSH_HOST}" 'sudo install -m 0600 -o deploy -g deploy \
    '"${TEST_CONFIG_DIR}"'/anchor.k1.key.incoming \
    '"${TEST_CONFIG_DIR}"'/anchor.k1.key && \
    sudo shred -u '"${TEST_CONFIG_DIR}"'/anchor.k1.key.incoming'
shred -u "${ANCHOR_KEY_TMP}"

# Write the sink + chain + quantity config files.
ssh "${VALIDATOR_SSH_HOST}" "sudo -u deploy bash -c \"
  printf '%s' '${TEST_SINK}'  > '${TEST_CONFIG_DIR}/anchor-sink' && \
  printf '%s' 'proton-test'    > '${TEST_CONFIG_DIR}/xpr-chain' && \
  printf '%s' '0.0001 XPR'     > '${TEST_CONFIG_DIR}/xpr-quantity' && \
  chmod 0600 '${TEST_CONFIG_DIR}'/anchor-sink '${TEST_CONFIG_DIR}'/xpr-chain '${TEST_CONFIG_DIR}'/xpr-quantity \
\""

# Import the test key into proton-cli (= note the chain context).
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash -c "
  proton chain:set proton-test
  proton key:add \$(sudo cat '"${TEST_CONFIG_DIR}"'/anchor.k1.key)
  proton key:list
"'
```

## Step 6 — End-to-end: invoke sign-anchor-event.sh in test mode

```sh
# As deploy user on the validator host, with FY_CONFIG_DIR pointing
# at the test config dir so the mainnet config under /etc/freedom-yield/
# is untouched.
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash -c "
  export FY_CONFIG_DIR='"${TEST_CONFIG_DIR}"'
  cd /home/deploy/metal.freedom-yield.com
  ./scripts/sign-anchor-event.sh cyclestart \
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    --dry-run
"'
```

Expected: exit code 0; stdout contains a JSON receipt fragment with
`tx_id: \"dry-run-no-broadcast\"`, `block_num: 0`, `block_time:
\"1970-01-01T00:00:00Z\"`, `network: \"xpr-testnet\"`, `method:
\"phase_alpha_token_transfer\"`, and the correct memo +
inscribe_action structure.

If the dry-run passes, repeat without `--dry-run`:

```sh
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash -c "
  export FY_CONFIG_DIR='"${TEST_CONFIG_DIR}"'
  cd /home/deploy/metal.freedom-yield.com
  ./scripts/sign-anchor-event.sh cyclestart \
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
"' | tee /tmp/testnet-receipt-fragment.json
```

Expected: exit code 0; stdout contains a JSON receipt fragment with
the real testnet `tx_id`, `block_num`, `block_time`.

## Step 7 — Cross-check the testnet inscription

```sh
# Extract the tx_id from the receipt fragment.
TX_ID="$(jq -r .tx_id /tmp/testnet-receipt-fragment.json)"

# Pull the transaction back from the testnet RPC.
curl -sS -X POST -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg id "${TX_ID}" '{id: $id}')" \
  https://api-xprnetwork-test.saltant.io/v1/history/get_transaction \
  | jq '.traces[0].act'
```

Expected: the returned action data shows
`account=eosio.token, name=transfer, data.from=${TEST_ACCOUNT}, data.to=${TEST_SINK}, data.memo="fyid1:0123...cdef"`,
and the signer permission is `${TEST_ACCOUNT}@anchor`.

Open the same `tx_id` on a public XPR testnet explorer and visually
confirm the same fields (= belt-and-braces, catches RPC vs explorer
divergence).

## Step 8 — Validate the receipt against the schema

Compose a full `anchor-receipt.json` document around the fragment
emitted by `sign-anchor-event.sh` and validate it against the
production schema:

```sh
DAG_ROOT="$(jq -r '.memo | sub("^fyid1:"; "")' /tmp/testnet-receipt-fragment.json)"
TX_ID="$(jq -r .tx_id /tmp/testnet-receipt-fragment.json)"
EXPLORER_URL="https://explorer.xprnetwork-test.metallicus.com/transaction/${TX_ID}"

jq -n \
  --argjson frag "$(cat /tmp/testnet-receipt-fragment.json)" \
  --arg dag "${DAG_ROOT}" \
  --arg expl "${EXPLORER_URL}" \
  '{
    schema_version: 1,
    dag_root_hash: $dag,
    memo: $frag.memo,
    anchor: ($frag + {explorer_url: $expl}),
    cycles_history_url: "https://metal.freedom-yield.com/api/cycles-history.json",
    identity_url: "https://metal.freedom-yield.com/api/identity.json",
    trigger_event: "cycle_start",
    generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  }' > /tmp/testnet-anchor-receipt.json

npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 ajv validate \
  --strict=false -c=ajv-formats --spec=draft2020 \
  -s public/api/anchor-receipt.schema.v1.json \
  -d /tmp/testnet-anchor-receipt.json
```

Expected: `valid`. If `invalid`, the receipt-fragment shape from
`sign-anchor-event.sh` has drifted from the schema and the fragment
emitter needs adjustment before mainnet.

## Step 9 — Tear down the rehearsal artifacts

```sh
# On the validator host:
ssh "${VALIDATOR_SSH_HOST}" 'sudo -u deploy bash -c "
  proton chain:set proton-test
  proton key:remove PUB_K1_<test_anchor>
  proton chain:set proton    # restore mainnet as the active chain context
"'
ssh "${VALIDATOR_SSH_HOST}" 'sudo shred -u '"${TEST_CONFIG_DIR}"'/anchor.k1.key && \
                              sudo rm -rf '"${TEST_CONFIG_DIR}"

# On the operator Mac:
rm -f /tmp/testnet-receipt-fragment.json /tmp/testnet-anchor-receipt.json
shred -u ${ANCHOR_KEY_TMP} 2>/dev/null || true
```

The testnet test account and sink are left to expire naturally on
testnet; no follow-up cleanup is needed on chain.

## After PASS

A passing rehearsal records:

- The testnet `tx_id` (= evidence the broadcast worked).
- The validated receipt JSON (= evidence the schema is correct).
- The chain context restored to `proton` (mainnet) and the testnet
  key removed from the keystore (= safe handoff back to mainnet ops).

The operator is then cleared to authorize the mainnet first
inscription at cycle 3 start. The mainnet broadcast uses the same
script and the same shape; only the chain context, the sink account
name, and the keystored key differ.

## Phase β note

When Phase β is activated (= the `freedomyield::inscribe` SC is
deployed per `scripts/operator-local/contract/freedomyield-anchor.spec.md`),
this rehearsal extends with a step that exercises the SC action via
`proton action freedomyield inscribe '{...}' freedomyield@anchor` and
asserts the resulting receipt has
`anchor.method == "phase_beta_sc_inscribe"`. The Phase α steps remain
valid as the fallback path while Phase β stabilizes.

## See also

- `docs/OPERATOR_IDENTITY_SETUP.md` §A4–A8 (= the analog operator-side
  permission install procedure for mainnet) and §B (= validator-host
  deploy procedure for mainnet).
- `scripts/sign-anchor-event.sh` — the wrapper invoked above.
- `public/api/anchor-receipt.schema.v1.json` — the receipt schema
  the rehearsal validates against.
- `docs/MERKLE_DAG_SPEC.md` §6 — A-chain anchor binding and
  BLOCK-1 (`from != to`) discipline.
- `scripts/operator-local/contract/freedomyield-anchor.spec.md` —
  Phase β SC inscribe spec (= the next-phase target of this same
  rehearsal pattern).
