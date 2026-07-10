# Deploy ownership matrix (`public/api/` runtime artifacts)

> **Status**: authoritative reference for `.github/workflows/deploy.yml`
> rsync `--delete` exclusions and operator runbooks. Per audit-C/F-E1.
>
> **Audience**: operator running `gen-identity.sh`, anyone reviewing
> the deploy workflow, anyone debugging "why did file X disappear/get
> reverted".

The Git deploy (GitHub Actions) rsyncs repo-tracked content to **two**
targets: the validator host (internal Caddy) and the public Xserver
origin (behind the edge CDN). It is the **canonical source** for
repo-tracked content on both. Validator-host runtime pushes are the
**canonical source** for live operational data. Both deploy rsyncs use
`rsync --delete`, which would otherwise wipe out runtime files between
the validator push and the next deploy; both derive their exclusion set
from a **single source of truth** — `deploy/feed-excludes.txt` via
`scripts/deploy/build-rsync-excludes.sh` — so the two targets cannot
drift. The exclusion table below pins which files each side owns and
which the deploy MUST leave alone.

## Ownership table

| File | Canonical producer | Canonical source host | Git tracked | Validator push | Deploy workflow path | rsync `--delete` exclude | Recovery / rollback |
|---|---|---|---|---|---|---|---|
| `public/api/anchor-source.json` | `scripts/gen-anchor-source.sh` (= v2 3-branch DAG source; carries `dag_root_computed`) | validator host, then committed to Git | **YES** | NO | YES (deploy serves the Git version) | NO (git-deploy owned; NOT in `deploy/feed-excludes.txt`) | Re-derive on validator host via `gen-anchor-source.sh`, then commit; the deploy serves the Git version. The committed file is exactly the signed pre-image the on-chain anchor is derived from by `sign-anchor-event.sh`, so recomputing its three branch roots reproduces the on-chain memos. |
| `public/api/anchor-source.json.sig` | `scripts/gen-anchor-source.sh` (detached signature over the DAG source) | validator host, then committed to Git | **YES** | NO | YES (deploy serves the Git version) | NO (git-deploy owned; NOT in `deploy/feed-excludes.txt`) | Produced and committed atomically with `anchor-source.json`; the deploy serves the Git version. |
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

## Note — `anchor-source.json` is git-deploy, not validator-pushed

`anchor-source.json` (and its detached `.sig`) are **git-deploy owned**:
committed to the repo and distributed by the GitHub Actions deploy, the
same path as `identity.json`. They are **not** pushed by
`scripts/push-to-web-host.sh` (that wrapper's allowlist never carried
`anchor-source.json`) and are therefore **removed from**
`deploy/feed-excludes.txt` — a file that the Git deploy serves MUST NOT
also be excluded from `--delete`, or the deploy would revert it on every
run. This closes the class of stale-published-anchor failures that the
unreliable validator-host push path produced. `anchor-receipt.json`,
`anchor-receipt.json.sig`, and `anchor-history.jsonl` remain
validator-pushed (they are produced only after the on-chain broadcast,
which happens off the deploy path) and stay in `feed-excludes.txt`.

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
  a separate but related drift: this table is about deploy-rsync file
  *content* ownership; that doc is about the validator host's git `HEAD`
  falling behind `origin/main` (nothing in this deploy workflow ever
  advances it) and the self-heal + fail-closed gate that closes the loop.
  Start there for "why did HEAD drift".
