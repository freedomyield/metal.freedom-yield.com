# Phase 5 execution checklist

One-page checklist for the operator at execution time. The full
walkthrough with rationale is in
[`OPERATOR_IDENTITY_SETUP.md`](./OPERATOR_IDENTITY_SETUP.md); the
verifier-side recipe is in
[`IDENTITY_VERIFICATION.md`](./IDENTITY_VERIFICATION.md). Read both
once before Phase 5. After that, this checklist is the only thing you
need open during execution.

Total wall-clock estimate: **~12 minutes** if everything is healthy.

## A. Cron-stability gate (before Step 1)

Three checks. **All three must pass** before key generation. If any
fails, stop and investigate. Do not start Step 1.

```sh
# A1. Cron fired cleanly at the scheduled time (01:30 UTC).
ssh -i ~/.ssh/REDACTED root@203.0.113.10 \
  'tail -20 /home/deploy/metal.freedom-yield.com/logs/gen-evidence.log'
# Expect a recent block ending: === metal-evidence end <ts> rc=0 ===

# A2. Live evidence.json carries a fresh generated_at.
curl -sS https://metal.freedom-yield.com/api/evidence.json | jq -r .generated_at
# Expect a timestamp from today (within the last few hours).

# A3. Live evidence.json carries the new in_preparation field
# (= Hetzner gen-evidence.sh sync from 8ec1887 landed correctly).
curl -sS https://metal.freedom-yield.com/api/evidence.json \
  | jq -r '.in_preparation_artifacts.identity_manifest.formal_schema_url'
# Expect: https://metal.freedom-yield.com/api/identity.schema.v1.json
```

If A1 prints `rc=0`, A2 prints today's date, and A3 prints the schema
URL above, the gate has cleared. Proceed.

## B. Key generation (Step 1, ~3 min)

```sh
# B1. Generate the ed25519 identity key. Strong passphrase mandatory.
ssh-keygen -t ed25519 \
  -f ~/.ssh/freedom-yield-operator-identity \
  -C "freedom-yield-operator-identity"

# B2. Sanity-check both halves of the keypair exist and are owner-only readable.
ls -l ~/.ssh/freedom-yield-operator-identity*
# Expect two files: private (mode 600) and .pub (mode 644).

# B3. Record the MANIFEST FINGERPRINT (= ssh-keygen wire-format hash).
# Goes into operator_identity_pubkey_fingerprint in identity.json.
ssh-keygen -l -f ~/.ssh/freedom-yield-operator-identity.pub
# Output shape: "256 SHA256:<44-char base64> <comment> (ED25519)"

# B4. Record the CHAIN MEMO BINDING HASH (= shasum of .pub file bytes).
# Used at Phase 6 in the AddValidator memo: identity-v1:sha256:<HEX64>.
# This is a DIFFERENT value from B3 — do not confuse them.
shasum -a 256 ~/.ssh/freedom-yield-operator-identity.pub
# Output shape: "<64 lowercase hex>  <path>"
```

**Password manager entry** — create immediately after B1, store all of:

| Field | Value |
| --- | --- |
| Name | Freedom Yield operator identity (production) |
| Issued | today's date (ISO 8601) |
| Passphrase | the secret you just typed |
| Manifest fingerprint (SHA256:base64) | output of B3 |
| Chain memo binding hash (64-hex) | output of B4 |
| Private key path | `~/.ssh/freedom-yield-operator-identity` |
| Comment field | `freedom-yield-operator-identity` |

Both hash forms must be saved. Phase 6 (next renewal cycle) needs the
B4 value and the manifest signature on identity.json claims the B3
value. Losing either is recoverable but expensive.

## C. Synthetic dry-run (Step 2, ~1 min)

```sh
cd ~/htdocs/01_PROJECTS/metal.freedom-yield.com
bash scripts/operator-local/test-gen-identity.sh
```

Must print `PASS: gen-identity.sh Phase 3 Merkle DAG output is internally
consistent`. If FAIL, stop here; the toolchain is wrong. Common causes
listed in `OPERATOR_IDENTITY_SETUP.md` § Common pitfalls.

## D. Real generator run (Step 3, ~1 min)

```sh
export OPERATOR_IDENTITY_KEY=~/.ssh/freedom-yield-operator-identity
bash scripts/operator-local/gen-identity.sh
```

Expected tail:

```
✓ wrote .../public/api/identity.json
✓ wrote .../public/api/identity.json.sig
  fingerprint:     SHA256:<your B3 value>
  namespace:       freedom-yield/validator-identity
  principal:       freedom-yield
  iat / exp:       <today> / <today+365d>
  leaves bound:    5     (or 4 if cycle-history.jsonl still 404)
  artifact_root:   <64-hex>
  chain_anchor:    placeholder (all-zeros) — bind at Phase 6 (next renewal)
```

If `fingerprint` shown does not match your B3 record, stop and
investigate — likely wrong key file picked up.

## E. Publish prep (Steps 4–5, ~3 min)

```sh
# E1. Copy the .pub into the repo. Operator reviews exactly which bytes go public.
cp ~/.ssh/freedom-yield-operator-identity.pub \
   public/.well-known/operator-identity.pub
chmod 644 public/.well-known/operator-identity.pub

# E2. Sanity-check the file is the public half only. It must be ONE line that
# begins with "ssh-ed25519 AAAA..." and contains no dash-delimited block headers.
wc -l public/.well-known/operator-identity.pub          # expect: 1
head -c 13 public/.well-known/operator-identity.pub     # expect: "ssh-ed25519 "

# E3. Review the diff.
git status
git diff -- public/api/identity.json | head -40

# E4. Stage and commit.
git add public/api/identity.json \
        public/api/identity.json.sig \
        public/.well-known/operator-identity.pub
git commit -m "feat(identity): Phase 5 — publish signed operator identity manifest"
```

## F. Deploy and live-verify (Steps 6–7, ~3 min)

```sh
# F1. Push.
git push origin main
# Watch GitHub Actions tab for green deploy.

# F2. Live verification (paste as a single block).
curl -sS https://metal.freedom-yield.com/api/identity.json     > /tmp/id.json
curl -sS https://metal.freedom-yield.com/api/identity.json.sig > /tmp/id.sig
curl -sS https://metal.freedom-yield.com/.well-known/operator-identity.pub > /tmp/operator.pub

LIVE_FP=$(ssh-keygen -l -f /tmp/operator.pub | awk '{print $2}')
CLAIMED_FP=$(jq -r .operator_identity_pubkey_fingerprint /tmp/id.json)
[ "$LIVE_FP" = "$CLAIMED_FP" ] && echo "OK fingerprint" || echo "FAIL fingerprint"

printf 'freedom-yield %s\n' "$(cat /tmp/operator.pub)" > /tmp/allowed
ssh-keygen -Y verify \
  -f /tmp/allowed \
  -I freedom-yield \
  -n freedom-yield/validator-identity \
  -s /tmp/id.sig < /tmp/id.json \
  && echo "OK signature" || echo "FAIL signature"
```

Both `OK fingerprint` and `OK signature` mean Phase 5 has landed. If
either line prints `FAIL`, run G immediately.

## G. Rollback path

```sh
git rm public/api/identity.json \
       public/api/identity.json.sig \
       public/.well-known/operator-identity.pub
git commit -m "revert: pull Phase 5 identity artifacts pending re-issue"
git push origin main
```

After the next deploy, the three URLs return 404 again. The keypair on
the local Mac is unaffected — re-run `gen-identity.sh` and republish
once the underlying issue is resolved.

## Failure decision tree

| Symptom | Action |
| --- | --- |
| A1: `rc=` not 0, or no recent block | Stop. Read the log, fix the cron, defer Phase 5 |
| A2: `generated_at` is yesterday or older | Stop. cron silently failed; investigate |
| A3: `formal_schema_url` is `null` | Stop. Hetzner sync of `gen-evidence.sh` is stale |
| C: `test-gen-identity.sh` FAIL | Stop. Toolchain issue; see `OPERATOR_IDENTITY_SETUP.md` pitfalls |
| D: leaves bound 0 | Web host transiently down. Wait 5 min, retry |
| D: fingerprint ≠ B3 | Wrong key path picked up. Re-export OPERATOR_IDENTITY_KEY |
| E2: `wc -l` ≠ 1 or first 13 bytes ≠ `ssh-ed25519 ` | You copied the wrong file. Stop, re-copy the `.pub` half |
| F1: GitHub Actions red | Read job log; common cause is allowlist drift, fix and push again — do NOT amend |
| F2: `FAIL fingerprint` | Live `.pub` was rewritten by web host. Compare bytes, fix nginx mime + push again |
| F2: `FAIL signature` | Live `identity.json` or `.sig` was rewritten. Same diagnosis — bytes drift |

## After Phase 5 lands

Update `docs/OPERATOR_IDENTITY_SETUP.md` Phase 5 → Phase 6 hand-off
section with the actual landing date so the next runbook reader sees
"Phase 5 landed YYYY-MM-DD, Phase 6 fires at next renewal cycle".
