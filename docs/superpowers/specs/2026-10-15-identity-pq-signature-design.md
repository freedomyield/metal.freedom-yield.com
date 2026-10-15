# Operator identity: additive post-quantum (ML-DSA-87) signature — design

> **Revision 4 (2026-10-16).** Rev 3 chose ML-DSA-65 on the premise that it was
> "Metallicus' basic choice". That premise was wrong: Metallicus' CTO publicly
> stated that ML-DSA-44, -65 and -87 are all supported; ML-DSA-65 only appeared
> in examples. The operator re-selected the parameter on its own merits and
> chose **ML-DSA-87** (approved in chat 2026-10-16). Rev 4 replaces §3
> principle 1 and §3.1 with a selection rule that does not depend on
> Metallicus' examples, moves every description of the current key, its files
> and its command to ML-DSA-87, relaxes `verification_pq.algorithm` in schema
> v2 to `enum ["ML-DSA-65", "ML-DSA-87"]` (no v3; the 2026-10-15 manifest
> stays valid), and drops the example-parameter item from the watch list
> (§7). The ML-DSA-65 key and its published files of 2026-10-15 are replaced
> by a normal key rotation (§6).

> **Status:** design spec, approved in chat by the operator on 2026-10-15
> (brainstorming session), revised the same day after a touchpoint survey
> (rev 2: unlock model, CI runner, validator-host scope, Dashlane naming,
> public pages, registry rows). Stage 1 only.
> **Origin:** PulseVM PR #116 (2026-10-09, open) adds FIPS 204 ML-DSA account
> keys to PulseVM.
> **Out of scope (stage 2, decided later, only if needed):** a dedicated
> `identity_branch` field for the PQ key in `anchor-source.json`, and PQ entries
> in `identity-history.jsonl`. See §8.

## 1. Goal

Add a second, post-quantum signature over `public/api/identity.json`, next to
the existing ed25519 signature, so that:

1. **Readiness evidence.** A third party can see — and verify with a standard
   tool — that the operator identity already carries a NIST post-quantum
   signature.
2. **Forgery resistance.** If ed25519 is broken in the future, a forged
   identity manifest cannot also carry a valid signature from the PQ key that
   was published and anchored earlier.

The ed25519 signature stays primary. The PQ signature is **additive and
removable**.

## 2. Why this does not duplicate Metallicus' work

| Layer | Metallicus | This project |
|---|---|---|
| On-chain account keys (anchor account, owner) | PulseVM ML-DSA (PR #116) | **Not built here.** Adopt via `updateauth` after activation (future work, not this spec). |
| Validator staking / BLS keys (`metalgo`) | No PQ work | Not ours to change. |
| Operator identity manifest signature (this site's `identity.json`) | No equivalent | **This spec.** |

Partial overlap, stated honestly: once PulseVM ML-DSA is active and the anchor
account holds an ML-DSA key, the on-chain anchor would itself protect the
`identity.json` hash with a PQ signature. The off-chain PQ signature still
serves verifiers who check the site without the chain, which is an explicit
property of the v1 identity design (`docs/IDENTITY_SCHEMA_CHANGELOG.md`).

## 3. Design principles (operator-approved)

1. **ML-DSA-87.** The identity PQ key uses ML-DSA-87, the highest ML-DSA
   level and the level NSA CNSA 2.0 specifies for all classification levels
   (rule in §3.1).
2. **Removable.** ed25519 stays primary; the PQ signature is a separate file.
   Removing it is deleting one signature file, one public key and one manifest
   block.
3. **No bespoke verifier.** Verification uses stock OpenSSL ≥ 3.5
   (`openssl pkeyutl -verify`). No project-specific verification tool.
4. **Small public claim.** Public wording is limited to "identity.json also
   carries an ML-DSA-87 (FIPS 204) signature". No "quantum-safe validator"
   claim.

### 3.1 Parameter selection rule

- **Rule:** the identity PQ key uses ML-DSA-87, the highest ML-DSA level and
  the level NSA CNSA 2.0 specifies for all classification levels.
- **Trigger to change:** only if NIST / CNSA guidance changes or a weakness in
  ML-DSA-87 is published.
- **How to change:** a normal key rotation (§6). The manifest names the
  algorithm, so a change of algorithm is a rotation, not a schema bump (a new
  value in `verification_pq.algorithm` is a compatible relaxation within v2,
  as on 2026-10-16).

## 4. Verified feasibility (2026-10-15, throwaway keys only)

On the operator workstation (macOS 26.6.2, Apple silicon, Homebrew
`/opt/homebrew/bin/openssl` 3.6.3; `/usr/bin/openssl` is LibreSSL and must not
be used):

- ML-DSA-87 and ML-DSA-65 sign / verify with `openssl pkeyutl -rawin -pkeyopt
  context-string:freedom-yield/validator-identity`. ML-DSA-65 signature: 3,309
  bytes; ML-DSA-87 signature: 4,627 bytes (re-measured 2026-10-16, OpenSSL
  3.6.3, throwaway key). A different context string fails verification (domain separation
  from PulseVM's `PulseVM transaction` context).
- **Encrypted seed-only storage works:**
  `openssl genpkey -algorithm ML-DSA-87 -provparam ml-dsa.output_formats=seed-only
  | openssl pkcs8 -topk8 -v2 aes-256-cbc -scrypt -passout <src>
  -provparam ml-dsa.output_formats=seed-only -out <file>` → 290-byte PEM
  (same size for ML-DSA-87, re-measured 2026-10-16: the seed is 32 bytes at
  every level); the
  plaintext never touches disk. Public key derived from it matches the
  unencrypted original byte for byte.
- KDF: OpenSSL's default PBES2 for `genpkey -aes-256-cbc` is PBKDF2 with 2,048
  iterations — **rejected as weak**. scrypt is used instead; OpenSSL's 32 MiB
  `maxmem` caps it at N=16384, r=8, p=1 (N=32768 fails "Error setting PBE
  algorithm"). The passphrase is therefore a long Dashlane-generated one.
- Wrong passphrase → non-zero exit, no signature file written.
- Harness note: OpenSSL tries to open the console for a passphrase unless stdin
  is redirected; non-interactive calls redirect stdin from `/dev/null`.
- (Secure Enclave ML-DSA was also probed and works, but is **rejected**: the
  key is bound to a workstation the operator does not own and does not move
  with Migration Assistant.)
- **CI:** GitHub `ubuntu-latest` is 24.04 (OpenSSL 3.0, no ML-DSA). The
  `ubuntu-26.04` image is generally available with OpenSSL 3.5.5 (runner-images
  readme, image 20260927). GitHub has announced `ubuntu-latest` moves to 26.04
  in November 2026.

## 5. Components

### 5.1 Key

- Algorithm: **ML-DSA-87** (§3.1).
- At rest: the encrypted seed-only PEM of §4 (scrypt, AES-256-CBC), in a
  directory under the operator's home outside the repo (moves with Migration
  Assistant). Backup: the operator's Dashlane.
- **The Dashlane entry name is never written in this repo** (repo rule since
  2026-08-18, `scripts/install-rehearsal-preflight.sh:1489-1495`,
  `docs/CYCLE_GATE.md:851`). Scripts say "the Dashlane entry named in the AI's
  ping"; the AI adds the name to the ping.
- Never on the validator host, the web host, or CI.
- Generation is one operator command (`scripts/install-*.sh` pattern,
  installer-script-first): generate + encrypt in one pipe, derive and write
  the public key into `public/.well-known/`, print the fingerprint.
- `.gitignore` gains the private key's basename.
- Separate from every chain key (Constitution §3.3).

### 5.2 Unlock / sign / lock model (same role split as the proton keystores)

The operator's manual work stays "unlock / lock and passphrases"; the AI runs
`gen-identity.sh` non-interactively, as it does today with the ed25519 key in
`ssh-agent`.

1. **Stop 2 (operator, at a TTY):** the existing `ssh-add` for ed25519, then a
   new unlock script that asks for the PQ passphrase and writes the decrypted
   seed-only key to an "unlocked" file (mode 0600, in a 0700 directory under
   the operator's home, outside the repo).
2. **Unit 4 (AI):** `gen-identity.sh` signs with ed25519 (agent) and ML-DSA
   (unlocked file).
3. **Auto-lock:** `gen-identity.sh` deletes the unlocked file **immediately
   after signing, on every exit path** (success or failure). The AI then
   removes the ed25519 key from the agent as today.
4. **Manual lock (safety net):** a lock script deletes the unlocked file if
   unit 4 never ran. The AI tells the operator when to run it.
5. **Staleness guard:** `gen-identity.sh` refuses an unlocked file older than
   2 hours (fail-closed, nothing published).
6. **Location guard:** refuse if the unlocked or encrypted file resolves
   inside the repo or `public/`.

Accepted risk, stated: while unlocked, the decrypted key exists as a file on
the Mac — the same class of exposure as an unlocked proton keystore. Bounded
by 3, 5 and 6. Operator keystrokes on transition day go from five to six.

### 5.3 Published files

| Path | Content |
|---|---|
| `/.well-known/operator-identity-mldsa87.pub` | SubjectPublicKeyInfo PEM (`-----BEGIN PUBLIC KEY-----`). Not named `.pem`: `.gitignore:9` and the pre-commit filename check block `*.pem`. |
| `/api/identity.json.mldsa87.sig` | Raw detached ML-DSA-87 signature over the exact bytes of `identity.json` |
| `/api/identity.schema.v2.json` | Schema for `schema_version: 2` |

All are git-deploy owned (committed, delivered by the existing GitHub Actions
deploy), exactly like `identity.json.sig`. **No web-host manual change and no
push-to-web-host allowlist change** (`scripts/install-xserver-sig-allowlist.sh`
is retired since 2026-08-06 and stays untouched). Each gets a row in
`deploy/publication.json` (registry test T16 requires a row for every tracked
file under `public/api/` and `public/.well-known/`).

### 5.4 `identity.json` schema v2

- `schema_version: 2`.
- New block `verification_pq` next to the unchanged `verification` block:
  - `algorithm` (`"ML-DSA-87"`; the schema accepts `enum ["ML-DSA-65",
    "ML-DSA-87"]` since 2026-10-16 so that the 2026-10-15 manifest stays
    valid), `standard` (`"FIPS 204"`)
  - `context_string` (`"freedom-yield/validator-identity"`)
  - `pubkey_url`, `pubkey_fingerprint` (`sha256:` + hex of the DER SPKI)
  - `signature_url`
  - `method` (the OpenSSL verify command), `minimum_openssl_version` (`"3.5"`)
- `identity.schema.v2.json` = v1 with `schema_version` const 2 and a required
  `verification_pq`; v1 stays published for old manifests. Example file moves
  to v2. Every test that hard-codes the v1 schema path is updated to v2 (T4 in
  `tests/anchor-history/test-ten-mandatory.sh`, `scripts/operator-local/test-gen-identity.sh`,
  registry T20, which also gains the v2 copy of the record clause).
- Entry in `docs/IDENTITY_SCHEMA_CHANGELOG.md`.
- **Binding:** the ed25519 signature covers `verification_pq`, so the existing
  key vouches for the PQ key; the PQ signature over the same bytes proves
  possession; the next anchor commits `identity.json`'s hash via the existing
  `artifacts_branch.public_api_files_hashed` leaf (`gen-anchor-source.sh`
  `API_FILES`), fixing the time on chain. No change to the DAG format or the
  anchor pipeline.

### 5.5 Signing flow (`scripts/operator-local/gen-identity.sh`)

1. Resolve an OpenSSL ≥ 3.5 binary explicitly (never LibreSSL); check the
   unlocked key (exists, age ≤ 2 h, outside repo) and the committed PQ public
   key (exists, its DER SHA-256 is what goes in the manifest).
2. Build `identity.json` as today (plus `verification_pq`, `schema_version: 2`).
3. Sign with ed25519 (unchanged).
4. Sign the same bytes with ML-DSA-87; delete the unlocked file.
5. Self-verify **both** (the PQ one against the committed public key file).
6. Publish both atomically. **If any step fails, publish nothing**
   (fail-closed). No ed25519-only fallback. New dedicated exit codes (free:
   5, 11+).

### 5.6 Readers and surfaces to update

- **CI:** `.github/workflows/verify-identity.yml` verifies the PQ signature
  too, on `ubuntu-26.04`, and adds the new paths to its triggers; a missing PQ
  file fails instead of skipping once the manifest is v2. The existing `tests`
  jobs in `validate.yml` and `ci-main.yml` stay on their current runner (rev 3:
  four unrelated suites fail on Ubuntu 26.04 already at base, so moving them
  would couple this feature to a separate migration); instead each workflow
  gains a dedicated `identity-pq` job on the pinned `ubuntu-26.04` label with
  `FY_REQUIRE_PQ=1` that runs every PQ-dependent suite and
  `check-identity-pq.sh --require-sig-verify`. In the existing jobs those
  suites skip for lack of OpenSSL ≥ 3.5; the dedicated job is where they are
  enforced.
- **Validator host stays ed25519-only.** `scripts/resume-after-cycle-start.sh`
  runs there (Ubuntu 22.04, OpenSSL 3.0) and keeps its ed25519 check
  unchanged; it may log that the PQ check is done in CI. No OpenSSL change on
  that host.
- New `scripts/check-identity-pq.sh` (repo mode, no alerting): checks that
  `verification_pq.pubkey_fingerprint` equals the SHA-256 of the committed
  `.pub`'s DER (computed without OpenSSL, from the PEM body), and — when an
  OpenSSL ≥ 3.5 is available — verifies the PQ signature. Used by CI (the
  docs-command test verifies the documented OpenSSL line directly instead).
  `scripts/check-identity-pins.sh` (which also runs as
  a live cron with alerting) is deliberately left unchanged: one
  responsibility per checker.
- `scripts/cycle-transition.sh`: stop 2 adds the unlock line; unit 4b's
  `git add` and its "expect exactly FOUR entries" text include the PQ
  signature; the status phase checks the PQ signature published; caveat text.
  Mirrors: `docs/CYCLE_GATE.md` step 4/4b, `docs/cycle-transition-steps.json`,
  `docs/VALIDATOR_RENEWAL.md`, and their drift tests.
- `scripts/install-rehearsal-preflight.sh`: a check that the PQ key pair is in
  place (alongside its ed25519 check).
- `scripts/gen-evidence.sh` + `public/api/evidence.example.json` +
  `docs/EVIDENCE_MANIFEST.md`: list the PQ signature and public key.
- Docs: `docs/IDENTITY_VERIFICATION.md` (a PQ verification step),
  `docs/OPERATOR_IDENTITY_SETUP.md` (scope its "no BEGIN header" rule to the
  ed25519 file; PQ setup steps), `docs/DEPLOY_OWNERSHIP_MATRIX.md`,
  `public/.well-known/README.md` (also fix its stale "not yet published"
  text), `scripts/operator-local/README.md`, `TOOLKIT.md` rows for new
  `scripts/` entries.
- **Public pages:** `/verify/`, `/data/` and their `/ja/` versions show the
  OpenSSL verification next to the ssh-keygen one, worded per §3.4.
- `deploy/publication.json`: three new rows; stale `producer_evidence` line
  numbers and the `.well-known/README.md` row's "exactly two files" text fixed.

The plan re-greps for every reader before implementation; this list is the
starting point, not a claim of completeness.

## 6. Error handling and lifecycle

1. **Missing / stale / misplaced unlocked key, wrong OpenSSL, missing public
   key, fingerprint mismatch** → `gen-identity.sh` exits non-zero with a
   dedicated code, publishes nothing, and still deletes any unlocked file.
2. **Seed never printed or logged.**
3. **Key loss** → generate a new PQ key; the new manifest (signed by ed25519,
   still valid until 2027-06-22) introduces it. Recorded in the changelog.
4. **Rotation** (algorithm change per §3.1, or YubiKey ML-DSA support ships):
   same as key loss, but planned. The future move to a hardware key is a
   rotation, not a redesign.
5. **Removal** (if made redundant): delete the files and the block; bump
   schema; changelog entry.

## 7. Testing

Every property claimed below is proven by a mutation that makes its test fail
(Constitution-level rule; repo convention `MUTATION NOT CAUGHT`):

| Property | Mutation |
|---|---|
| Either signature failing self-verify → nothing published | flip one byte of the PQ signature; skip the PQ verify step |
| Wrong context string is rejected | change the context string |
| Manifest fingerprint matches the published PQ public key | publish a different key's public key |
| Unlocked key is deleted on success and on failure | remove the delete on one exit path |
| Stale unlocked key (> 2 h) is refused | widen or drop the age check |
| Seed never appears in output or logs | grep test over all output |
| The verification command in the docs works verbatim | run the documented line as-is in the test |

Watch list additions (baselines 2026-10-15): PR #116 merge state (OPEN);
activation height (none). (Rev 4: the former "ML-DSA parameter used in
official PulseVM examples" item is dropped — the parameter no longer follows
Metallicus' examples, §3.1.)

## 8. Stage 2 (not in this spec)

Decide after stage 1 has shipped: a dedicated `identity_branch` field for the
PQ public key hash, and PQ entries in `identity-history.jsonl`. Both touch the
anchored DAG and the append-only ledger, so they need their own testnet
rehearsal. Stage 1 already commits the PQ fingerprint on chain indirectly
(§5.4).

## 9. Delivery

1. Operator generates the key (one command; passphrase from Dashlane).
2. A normal (non-transition) `gen-identity.sh` run with the stop-2 unlock
   produces both signatures; commit.
3. CI deploy → **fetch the public URLs with curl and verify with OpenSSL** as a
   third party would.
4. Ship before cycle 6 ends (2026-11-06 JST) so cycle 7's anchor commits it,
   and the transition-day flow (§5.2) is exercised in the rehearsal before
   that day.

Push and deploy remain operator decisions.
