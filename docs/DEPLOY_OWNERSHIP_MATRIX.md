# Deploy ownership matrix (`public/api/` runtime artifacts)

> **Status**: authoritative reference for `.github/workflows/deploy.yml`
> rsync `--delete` exclusions and operator runbooks. Per audit-C/F-E1.
>
> **Audience**: operator running `gen-identity.sh`, anyone reviewing
> the deploy workflow, anyone debugging "why did file X disappear/get
> reverted".

## Delivery ownership: git vs rsync

**Delivery ownership follows one rule** (since the 2026-07-13
delivery-ownership inversion): *if git tracks it, git delivers it; rsync
ships only deploy-derived artifacts.* The two deploy targets apply that
rule differently because only one of them is a git checkout:

- **Validator host** (internal Caddy): every git-tracked file outside
  `public/` — `docs/`, `scripts/`, `tests/`, `caddy/Caddyfile`,
  `docker-compose*.yml`, etc. — is delivered by
  `scripts/advance-host-checkout.sh`'s FF-only `git pull`, invoked at
  deploy time from `.github/workflows/deploy.yml`'s **"Advance host
  checkout to origin/main"** step (which runs before any rsync) and, as a
  backstop, by the daily 04:45 UTC cron. Only the deploy-transformed
  `public/` tree — cache-bust `?v=<sha>` markers stamped into the
  runner's copy — still travels by the **"Rsync public/ to VPS"** step:
  git cannot deliver a build artifact that deliberately diverges from the
  committed source.
- **Public Xserver origin** (behind the edge CDN): never runs a git
  checkout at all — the deploy key is `rrsync -wo`-confined to the metal
  public dir, so the **"Rsync public/ to Xserver (public origin)"** step
  is its only delivery path for repo-tracked content, unchanged by the
  inversion.

Validator-host runtime pushes (e.g. `push-to-web-host.sh`) remain the
**canonical source** for live operational data that is never git-tracked.
Both `public/` rsyncs use `rsync --delete`, which would otherwise wipe out
those runtime files between a validator push and the next deploy; both
derive their exclusion set from a **single source of truth** —
`deploy/feed-excludes.txt` via `scripts/deploy/build-rsync-excludes.sh` —
so the two targets cannot drift. The exclusion table below pins which
`public/api/` files each side owns and which the `public/` rsync MUST
leave alone.

**Three classes of working-tree dirt can appear on the validator host**,
and `scripts/advance-host-checkout.sh` treats them differently by design:

1. **Deploy-stamped `public/` cache-bust markers.** Every deploy writes
   `?v=<sha>` into the runner's copy of `public/*.html` before rsyncing
   it; on the host this always shows up as `public/` dirt against the
   freshly-pulled git content. The advance script discards it
   unconditionally (`git checkout -- public/`) before every pull —
   expected on every run, not an anomaly.
2. **Operator-run `scripts/sync-to-validator-host.sh` writing uncommitted
   content into `scripts/`.** That wrapper rsyncs exactly one path — the
   local Mac's `scripts/` directory — straight to the host outside git.
   If the bytes it writes are identical (content **and** mode) to what
   `origin/main` already has at that path, the self-heal absorbs it (if
   one or more files are absorbed in a run, a single batched
   `default`-priority ntfy notify fires, titled `host-advance:
   self-healed N file(s)`, naming every absorbed path) and the pull
   proceeds. If they
   differ — real local edits not yet committed anywhere — the advance
   script refuses the pull loudly (`alert high`, exit 1) **by design**:
   forcing it through would silently discard operator work that git
   cannot recover.
3. **Host-authored `public/api/anchor-source.json` dirt (added 2026-08,
   plan A4).** Unlike the other two, this dirt is neither routine nor a
   byproduct of another tool writing tracked bytes — it is the validator
   host's own `gen-anchor-source.sh` composing real anchor content that
   `scripts/operator-local/commit-anchor-source.sh` has not yet
   transferred to Git. `public/`'s otherwise-unconditional discard
   (item 1) special-cases exactly this one path: byte-identical-to-HEAD
   dirt is discarded same as any cache-bust marker (nothing lost either
   way), but real dirt is preserved (alert high) ahead of the discard and
   resolved once the FF pull's effect on that path is known — restored if
   the pull didn't touch it, self-healed if a `commit-anchor-source.sh`
   commit arrived via origin with identical bytes, or stashed to a
   `.host-<UTC timestamp>` sibling (origin wins on the canonical path) if
   it arrived with different bytes. See `scripts/advance-host-checkout.sh`'s
   header comment and `tests/host-advance/test-advance-host-checkout.sh`
   for the exact mechanics.

See [`docs/HOST_CHECKOUT_AUTO_ADVANCE.md`](HOST_CHECKOUT_AUTO_ADVANCE.md)
§2① "Self-heal" for the exact absorption criteria.

## Ownership table

| File | Canonical producer | Canonical source host | Git tracked | Validator push | Deploy workflow path | rsync `--delete` exclude | Recovery / rollback |
|---|---|---|---|---|---|---|---|
| `public/api/anchor-source.json` | `scripts/gen-anchor-source.sh` (= v2 3-branch DAG source; carries `dag_root_computed`) | validator host, then committed to Git | **YES** | NO | YES (deploy serves the Git version) | NO (git-deploy owned; NOT in `deploy/feed-excludes.txt`) | Re-derive on validator host via `gen-anchor-source.sh`, then commit; the deploy serves the Git version. The committed file is exactly the signed pre-image the on-chain anchor is derived from by `sign-anchor-event.sh`, so recomputing its three branch roots reproduces the on-chain memos. |
| `public/api/anchor-receipt.json` | `scripts/gen-anchor-receipt.sh` (= verifies `sign-anchor-event.sh` output; **not** the retired `post-anchor-event.sh`) | validator host | NO | YES (`push-to-web-host.sh anchor-receipt.json`) | NO | **YES** (added 2026-06-21 per audit-C/F-E1) | Re-derive on validator host from the signed anchor; carries `dag_root_hash` (= `anchor-source.json .dag_root_computed`). |
| `public/api/cycle-history.jsonl` | `scripts/gen-cycle-history.sh` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive from `uptime-cycles.json` + `incidents.json` on validator host. |
| `public/api/identity-history.jsonl` | `scripts/operator-local/gen-identity.sh` (bootstrap; append on rotation) | operator Mac | **YES** (after operator commits the bootstrap line) | NO | YES (deploy serves the Git version) | NO | From Git history; bootstrap is idempotent (= regenerates same line as long as the operator-identity ed25519 key has not rotated). || `public/api/identity.json` | `scripts/operator-local/gen-identity.sh` | operator Mac | YES | NO | YES | NO | From Git; regenerate via operator-Mac `gen-identity.sh`. |
| `public/api/identity.json.sig` | `scripts/operator-local/gen-identity.sh` (= `ssh-keygen -Y sign`) | operator Mac | YES | NO | YES | NO | From Git; produced atomically with `identity.json`. |
| `public/.well-known/operator-identity.pub` | `cp` from `~/.ssh/freedom-yield-operator-identity.pub` (= operator's Mac) | operator Mac | YES | NO | YES | NO | From Git; can re-copy from Mac if needed. |
| `public/api/validator.json` | `scripts/node-info.sh` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive from metalgo RPC on validator host. |
| `public/api/peer-geo.json` | `scripts/peer-geo.py` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/uptime-recent.json` | `scripts/node-info.sh` (uptime track) | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/uptime-cycles.json` | `scripts/node-info.sh` (uptime per cycle) | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/peers.json` | `scripts/peer-validators.sh` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/evidence.json` | `scripts/gen-evidence.sh` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/fee-market.json` | `scripts/node-info.sh` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/fee-market-history.jsonl` | `scripts/node-info.sh` (append) | validator host | NO | YES | NO | YES (pre-existing) | Append-only; loss of recent records is recoverable from metalgo RPC. |
| `public/api/node-health-recent.json` | `scripts/node-health-daily.sh` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/peers-changes.json` | `scripts/peer-analytics.py` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/peers-gini.json` | `scripts/peer-analytics.py` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/peers-gini-history.jsonl` | `scripts/peer-analytics.py` (append) | validator host | NO | YES | NO | YES (pre-existing) | Append-only; loss is recoverable from metalgo RPC. |
| `public/api/peers-history-index.json` | `scripts/peer-analytics.py` | validator host | NO | YES | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/server-status.json` | `scripts/server-status.sh` | validator host | NO | YES (out-of-band; not via `push-to-web-host.sh`) | NO | YES (pre-existing) | Re-derive on validator host. |
| `public/api/archive/anchor-source-<dag_root>.json` | Written locally by `scripts/gen-anchor-source.sh` (R18 archive block, content-addressed); **pushed automatically by `scripts/append-anchor-history.sh`** (2026-08-06, immediately after its append succeeds — not by the generator, and not a manual step) | validator host | NO | YES, automatic (`append-anchor-history.sh` → `push-to-web-host.sh archive/anchor-source-<64hex>.json`; best-effort — a push failure is logged loud, never fails the append; `FYD_PUBLISH_ARCHIVES=0` disables) | NO | **YES** (`api/archive/`, added 2026-08-05) | Re-derive by re-running `gen-anchor-source.sh` on the same inputs — the archive copy is byte-identical to the canonical `anchor-source.json` of that anchor event — then re-push manually if the automatic push failed (`append-anchor-history.sh` prints the exact retry command on failure). |
| `public/api/archive/anchor-receipt-<tx_id>.json` | Written locally by `scripts/gen-anchor-receipt.sh` (R18 archive block, keyed by `tx_id`); **pushed automatically by `scripts/append-anchor-history.sh`** (2026-08-06, immediately after its append succeeds — not by the generator, and not a manual step) | validator host | NO | YES, automatic (`append-anchor-history.sh` → `push-to-web-host.sh archive/anchor-receipt-<64hex>.json`; best-effort — a push failure is logged loud, never fails the append; `FYD_PUBLISH_ARCHIVES=0` disables) | NO | **YES** (`api/archive/`, added 2026-08-05) | Re-derive by re-running `gen-anchor-receipt.sh` against the same on-chain `tx_id` (7-PASS re-verification is what produces the file) — then re-push manually if the automatic push failed (`append-anchor-history.sh` prints the exact retry command on failure). |
| `public/api/peers-history/peers-YYYY-MM-DD.json.gz` | `scripts/peer-validators.sh` (writes into the host state dir, not the repo) | validator host | NO | YES (`push-to-web-host.sh peers-history/peers-YYYY-MM-DD.json.gz`) | NO | **YES** (`api/peers-history/`, added 2026-08-05) | Snapshots are historical observations and cannot be re-derived after the fact; the host state dir (`${UPTIME_STATE_DIR:-/var/lib/freedom-yield}/peers-history/`) is the master copy, the public tree is a mirror. |

## Note — the two subdirectory feeds (`api/archive/`, `api/peers-history/`)

Both are **push-owned end to end** and deliberately **not git-tracked** (see
`.gitignore`): their member filenames are content-addressed or date-keyed
and unbounded, so committing them would put the deploy and the runtime push
in joint ownership of the same paths — the exact silent-reversion class this
matrix exists to prevent. Because they are directories, the exclude entries
are whole-directory (`api/archive/`, `api/peers-history/`), the same shape
`calendar/` already uses.

Publishing them requires **three** lock-step pieces, all present as of
2026-08-05: the sender allowlist (`scripts/push-to-web-host.sh`, `archive/*`
and `peers-history/*` branches), the receiver allowlist (the Xserver wrapper,
installed by `scripts/install-xserver-subdir-allowlist.sh` from
`scripts/deploy/receive-subdir-allowlist.snippet.sh`), and the deploy
excludes above. Until the receiver half is installed on the web host, pushes
are rejected remotely even though the sender accepts the name.

## Note — `anchor-source.json` is git-deploy, not validator-pushed

`anchor-source.json` is **git-deploy owned**: committed to the repo and
distributed by the GitHub Actions deploy, the same path as
`identity.json`. It is **not** pushed by `scripts/push-to-web-host.sh`
(that wrapper's allowlist never carried `anchor-source.json`) and is
therefore **removed from** `deploy/feed-excludes.txt` — a file that the
Git deploy serves MUST NOT also be excluded from `--delete`, or the
deploy would revert it on every run. This closes the class of
stale-published-anchor failures that the unreliable validator-host push
path produced. `anchor-receipt.json` and `anchor-history.jsonl` remain
validator-pushed (they are produced only after the on-chain broadcast,
which happens off the deploy path) and stay in `feed-excludes.txt`.

## Note — no detached `.sig` exists for `anchor-source.json` or `anchor-receipt.json` (verified 2026-08-06)

Earlier drafts of this matrix and of `docs/ANCHOR_SOURCE.md` described
`anchor-source.json.sig` as git-deploy owned and committed atomically
with `anchor-source.json`, and `deploy/feed-excludes.txt` carried a
matching `api/anchor-receipt.json.sig` exclude line. Neither file has
ever existed: `scripts/gen-anchor-source.sh` and
`scripts/gen-anchor-receipt.sh` contain no signing step, `git ls-files`
has never tracked either `.sig` path, and no CI or cron job produces
one. Both were an aspirational carry-over from the pre-2026-07-07
publish design; the git-deploy migration and the R18 archive/history
work superseded the need without anyone going back to retract the
mention, leaving the URLs permanently 404 and the exclude line dead
weight protecting a file nothing ever writes.

This is now treated as a closed decision, not an open gap: a detached
signature specifically over `anchor-source.json` would be redundant
given the verification chain that already exists —
1. the on-chain XPR transaction that inscribes the anchor is itself
   cryptographically signed by the broadcasting account key
   (independently checkable via any Antelope/Hyperion history
   endpoint, read-only);
2. `anchor-source.json`'s three branch hashes and combined
   `dag_root_computed` are independently recomputable from the served
   bytes and checked against those on-chain memos by
   `scripts/check-anchor-publish-health.sh`; and
3. `identity.json.sig` (git-deploy owned, `ssh-keygen -Y sign` on the
   operator's Mac) already proves control of the operator identity key
   the anchor's `identity_branch` asserts.

`deploy/feed-excludes.txt` no longer carries `api/anchor-receipt.json.sig`
(removed 2026-08-06); `scripts/install-xserver-sig-allowlist.sh` and
`scripts/install-xserver-anchor-source-allowlist.sh` — the two Xserver
receive-wrapper installers that predate this decision — have been
retired to idempotent removal installers so a wrapper that was ever
extended with these dead names can be cleaned back to the sender's real
allowlist. See those scripts' headers for detail.

## Cross-check protocol

Add a new artifact to `public/api/` only after deciding its row in this
table, and applying the corresponding lock-step changes:

1. **Git-owned, deploy-served, NOT excluded from `--delete`**: just
   commit to repo; no workflow change. Deploy will copy each push.
2. **Validator-pushed, NOT git-owned, MUST be excluded from
   `--delete`**: add the `public/`-relative path to
   `deploy/feed-excludes.txt` (the single source **both** deploy rsyncs
   read via `scripts/deploy/build-rsync-excludes.sh`) AND extend the
   allowlist case statement in `scripts/push-to-web-host.sh` AND, on the
   Xserver, extend the `receive-metal-push` forced-command wrapper
   allowlist (out-of-tree). Three lock-step places, one filename — drift
   between them is the entire class of failures this matrix exists to
   catch.
3. **Owner is ambiguous**: BLOCK publication. Resolve the owner
   before the first deploy that would expose the file.

A file MUST NOT be claimed by both the Git deploy AND a runtime push:
the deploy would either delete the runtime version (= `--delete` not
excluded) or revert it on every push (= excluded but Git also has a
copy). Either is a class of silent reversion bugs that "the file was
fine yesterday" investigations chase for hours.

## Regression test

`tests/deploy/test-rsync-delete-protection.sh` builds a temp-dir
fixture mirroring the source/destination shapes and runs an
`rsync --delete` with the deploy workflow's exclusion list. It
asserts:

- Files in the validator-pushed exclude list remain on the
  "destination" side after the deploy rsync.
- Files in the Git-owned set are copied from the "source" side.
- Files not in either set are subject to `--delete` semantics
  (= deleted from the "destination" if absent from the "source").

The fixture is synthetic and does NOT contact any real host or SSH
key — `rsync` is run with a local-to-local source/destination pair.

## See also

- `.github/workflows/deploy.yml` — the actual deploy rsync command.
- `scripts/push-to-web-host.sh` — the validator-host push wrapper
  whose allowlist must stay in lock-step with this table.
- `tests/deploy/test-rsync-delete-protection.sh` — the fixture test
  that pins the protection contract.
- [`docs/HOST_CHECKOUT_AUTO_ADVANCE.md`](HOST_CHECKOUT_AUTO_ADVANCE.md) —
  a separate but related concern: this table is about deploy-rsync file
  *content* ownership within `public/`; that doc is about the validator
  host's git `HEAD` — how `.github/workflows/deploy.yml`'s git-advance step
  (§"Delivery ownership: git vs rsync" above) and the daily cron keep it
  current, and the self-heal + fail-closed gate that backstops it. Start
  there for "why did HEAD drift" (now rare: only when the FF pull itself
  refuses).
