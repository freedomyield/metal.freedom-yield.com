# Design — static content propagation convergence (defect ⑤)

> Status: approved design, 2026-07-06. Feeds into an implementation plan
> (writing-plans). Design decision: **approach C** (GitHub Actions deploys
> git-tracked static to the public Xserver as a second rsync target).
>
> Audience: anyone implementing or reviewing the deploy pipeline change,
> and the operator performing the one-time Xserver key setup.

## 1. Problem — root cause (evidenced 2026-07-06)

The public site `https://metal.freedom-yield.com` is served by
**Cloudflare → Xserver** (web root `/home/<acct>/metal.freedom-yield.com/
public`). The GitHub Actions deploy (`.github/workflows/deploy.yml`)
rsyncs the repository to a **single** `SSH_HOST`, which is the **Hetzner
validator host** — an internal Caddy, **not** the public origin.

**There is no automated propagation of git-tracked static content to the
public Xserver.** Evidence gathered by a single authorized read-only root
inspection of the Xserver on 2026-07-06:

- The Xserver site root has **no `.git`** — it is not a git-pull target.
- Every git-tracked static file under `public/api/`
  (`identity.schema.v1.json`, `anchor-receipt.schema.v2.json`,
  `identity.json`, `cycles-history.json`, …) has **mtime 2026-07-02** and
  has not changed since — i.e. the public static tree is a **manual
  one-time snapshot** taken 2026-07-02.
- Neither the site-owning account's crontab nor root's crontab contains any
  metal `git pull` / `rsync` / deploy job (the only crons present belong to
  unrelated co-tenant projects, which are out of scope and untouched).
- There is no deploy/sync script at the site root.

Consequences:

- Any change to a git-tracked static file (HTML, JSON schemas,
  `identity.json`, `cycles-history.json`) **never reaches the public
  origin** until someone manually re-syncs. The defect-① schema retirement
  (`identity.schema.v1.json`, committed 2026-07-06) is invisible publicly
  and will stay invisible indefinitely.
- The `anchor-receipt.schema.v2.json` file *appears* current on the public
  site only because its last repo change (2026-07-01) predates the
  2026-07-02 snapshot — a coincidence, not propagation.
- `anchor-source.json` is the sole `public/api/` artifact that stays fresh,
  because it travels a **different** path: Hetzner cron →
  `push-to-web-host.sh` → the Xserver forced-command wrapper
  `/home/deploy/bin/receive-metal-push` (filename allowlist → web root).

`docs/DEPLOY_OWNERSHIP_MATRIX.md` asserts that the Git deploy is the
"canonical source for repo-tracked content." That was true under the
pre-2026-05-20 single-VPS topology, where the deploy target *was* the
public origin. After the web tier moved to Xserver, the deploy target
became the internal Hetzner host and the assertion silently became false.
This design restores the invariant the matrix already assumes.

## 2. Goal and non-goals

**Goal.** A `git push` to the default branch reliably updates the public
Xserver web root with the current git-tracked static content — the same
content, asset-versioned identically, that the deploy already ships to
Hetzner — without disturbing the dynamically-pushed feeds that share
`public/api/`.

**Non-goals.**

- Changing the dynamic-feed path (Hetzner cron → receive wrapper). It works
  and stays as-is.
- Migrating the public origin off Xserver, or introducing a CDN origin
  change.
- Retiring the receive-wrapper allowlist. `anchor-source.json` continues to
  arrive via that path (it is host-generated, not git-tracked).
- Any change to the anchor scheme, cycle-gate, or signing model.

## 3. Approach — C: second rsync target in GitHub Actions

The deploy workflow already: (a) checks out the repo, (b) asset-versions
`public/assets/**` by rewriting `?v=<SHORT_SHA>`, (c) rsyncs `./` to
Hetzner with `--delete` and an exclusion list that pins the
validator-pushed feeds. Approach C adds a **second rsync**, of the same
built tree, to the Xserver web root.

Two other approaches were considered and rejected:

- **B — Hetzner → Xserver static rsync.** Adds a new channel parallel to
  the dynamic push; requires re-implementing the feed exclusions in a
  second place and an rsync-over-forced-command shim. More wiring, more
  drift surface.
- **A — Xserver-side `git pull` cron.** Makes the docroot a git working
  tree, loses the CI asset-versioning step, and needs separate handling so
  the pull never clobbers the pushed feeds. Diverges from the existing
  pipeline.

Approach C is preferred because ⑤'s root cause is *drift* — the deploy
still points only at the old single-VPS target. C corrects the drift
directly and reuses the existing asset-versioning and exclusion machinery
rather than adding new machinery.

### 3.1 Data flow

```
git push (default branch)
  └─ GitHub Actions deploy.yml
       ├─ checkout + asset-version public/assets/** (?v=SHORT_SHA)
       ├─ rsync #1  --delete + <feed-excludes>   → Hetzner:DEPLOY_PATH/        (existing)
       └─ rsync #2  --delete + <feed-excludes>   → Xserver:.../metal…/public/  (NEW)

dynamic feeds (unchanged, parallel):
  Hetzner crons → push-to-web-host.sh → receive-metal-push (allowlist) → Xserver public/api/
```

**Ordering.** rsync #1 (Hetzner) runs first, then rsync #2 (Xserver). A
Xserver failure fails the workflow so the drift is visible, but only after
the Hetzner deploy has already succeeded. The two targets are independent;
neither partial state corrupts the other.

**Source root difference.** Hetzner receives `./` (the whole repo tree,
minus excludes) into `DEPLOY_PATH`, and Caddy serves `DEPLOY_PATH/public`.
The Xserver web root *is* `.../metal.freedom-yield.com/public` directly, so
rsync #2's source is **`./public/`**, not `./`. This keeps repository
source (scripts, workflows, compose files) off the shared public web host —
only `public/` lands there.

### 3.2 Backfill

The first deploy after C goes live re-syncs the entire 2026-07-02-frozen
static tree to the current repo state in one shot: the ① schema retirement,
the regenerated `identity.json`, `cycles-history.json`, and any drifted HTML
all become publicly current. No separate backfill step is needed — the
mechanism *is* the backfill.

## 4. Exclusion list — single source of truth

rsync #2 uses `--delete`, so it **must** exclude every artifact that is
written into the Xserver `public/api/` (and `public/calendar/`) by the
receive wrapper — otherwise `--delete` erases the fresh feeds between
deploys. That set is identical to the feeds already excluded from rsync #1
in `deploy.yml` (the `public/api/validator.json … anchor-history.jsonl` and
`public/calendar/` block).

**Constraint: the two rsyncs must not carry two independently-maintained
exclusion lists.** rsync #1's source is `./` so its patterns are
`public/api/<file>`; rsync #2's source is `./public/` so the equivalent
patterns are `api/<file>`. The implementation MUST derive both from one
declared feed list (single source of truth) so a newly-added feed cannot be
protected on one host and silently `--delete`d on the other. The concrete
mechanism (shared list variable, generated patterns, or basename-anchored
excludes) is an implementation-plan decision; the invariant is: **one list,
two prefixes, zero drift.**

This list is also mirrored in `docs/DEPLOY_OWNERSHIP_MATRIX.md`. That
three-way lock-step (deploy.yml Hetzner excludes ↔ deploy.yml Xserver
excludes ↔ ownership matrix ↔ receive-wrapper allowlist) is the exact class
of drift the matrix exists to catch; the matrix section is updated to name
the Xserver target explicitly.

## 5. Multi-project host safety (highest-priority constraint)

The Xserver is a **shared host with unrelated co-tenant projects**. The CI
deploy key's blast radius MUST be confined to the metal public directory.

- **Dedicated key.** Generate a new ed25519 key used only for this deploy.
  The root key (`id_rsa`) is **not** used — placing a root private key in
  GitHub Actions secrets on a multi-project host is disproportionate risk.
- **Restricted `authorized_keys`.** The key's Xserver entry is wrapped:

  ```
  command="rrsync -wo /home/<acct>/metal.freedom-yield.com/public",
  no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding <key>
  ```

  `rrsync -wo` (write-only, restricted to one path) means the key can rsync
  **only** into the metal public dir — no shell, no other vhost, no read of
  co-tenant data. A leaked CI secret cannot escalate beyond overwriting the
  metal public tree.
- **No host-wide actions.** The installer touches only this one
  `authorized_keys` line and backs the file up first; it never rewrites
  ownership, other projects' entries, or any shared service.

## 6. Components

| File | Change | Owner |
|---|---|---|
| `.github/workflows/deploy.yml` | Add "Set up Xserver key" + "Rsync public/ to Xserver" steps: source `./public/`, `--delete`, the shared feed-exclusion set (Xserver prefix), target from new secrets. Runs after the Hetzner rsync. | AI (diff), operator approves |
| `scripts/install-xserver-static-deploy-key.sh` (NEW) | Operator-run once. Installs the `rrsync`-restricted `authorized_keys` line for the CI deploy key on Xserver. Verifies `rrsync` is present; backs up `authorized_keys`; appends exactly one line; idempotent (re-run detects the line and exits 0); never edits other entries. Env-overridable (`XSERVER_HOST`, `XSERVER_USER`, `XSERVER_KEY`, `WEB_ROOT`) for testability, matching the existing `install-xserver-*-allowlist.sh` shape. | AI authors, operator executes |
| `docs/DEPLOY_OWNERSHIP_MATRIX.md` | Correct the "canonical source" framing: git deploy now reaches **both** Hetzner and the public Xserver. Add the Xserver rsync target and its exclusion coupling to the cross-check protocol. | AI |
| `docs/DEPLOY_SETUP.md` | Replace the obsolete single-VPS model (DNS→one VPS Caddy) with the two-host reality: Actions → Hetzner (internal) + Actions → Xserver (public origin behind Cloudflare); dynamic feeds via receive wrapper. | AI |
| `tests/deploy/test-rsync-delete-protection.sh` | Extend the synthetic fixture to also exercise the Xserver rsync (source `./public/`, its prefixed exclude set): assert feeds survive `--delete` and static files are copied. Local-to-local, no real host. | AI |

**Operator one-time setup** (Constitution §5 / Operating Model W7):

1. Generate the dedicated ed25519 deploy key (AI provides the exact
   command; the private key never enters the repo).
2. Run `scripts/install-xserver-static-deploy-key.sh` (installs the
   restricted `authorized_keys` line on Xserver).
3. Register GitHub Actions secrets: `XSERVER_SSH_KEY` (private key),
   `XSERVER_SSH_HOST`, `XSERVER_SSH_USER`, `XSERVER_SSH_PORT`,
   `XSERVER_WEB_ROOT`.

AI supplies the installer, the workflow diff, and the post-deploy
verification steps; the operator holds execution and final approval.

## 7. Error handling

- **Xserver rsync fails** (host unreachable, key rejected): the workflow
  fails *after* a successful Hetzner deploy, surfacing the drift rather than
  hiding it. Hetzner (validator-adjacent) is never blocked by a
  public-origin problem.
- **`--delete` vs feeds**: the shared exclusion set (§4) protects every
  dynamically-pushed feed; the regression test (§6) pins this.
- **Leaked CI key**: `rrsync -wo` confinement (§5) bounds the damage to the
  metal public tree on the shared host.
- **`rrsync` absent on Xserver**: the installer detects this and aborts with
  a clear message before touching `authorized_keys`, rather than installing
  a broken restriction.

## 8. Testing / verification

- `tests/deploy/test-rsync-delete-protection.sh` — extended per §6; runs in
  CI and locally, synthetic dirs only.
- Post-setup manual verification (operator, once): trigger a deploy, then
  `curl` a git-tracked static file (e.g. `identity.schema.v1.json`) and
  confirm the public sha256 now matches the repo, while a feed
  (`validator.json`) remains its freshly-pushed value.
- Installer scenario tests (`tests/install-xserver-static-deploy-key/…`):
  idempotent re-run, backup created, other `authorized_keys` entries
  untouched, abort when `rrsync` missing — mirroring the
  `install-repoint-publish-crons` test style.

## 9. Relationship to defects ⑫ and ①

- **① (dag_root_hash retirement)** becomes publicly visible on the first
  post-C deploy (backfill, §3.2). Until C ships, ①'s schema change is
  Hetzner-only.
- **⑫ (cron publish naming split)** is *decoupled* from this design: ⑫'s
  installer superset check was protecting the old `push-to-xserver.sh`
  allowlist's `anchor-source.json`/`.sig` push capability. Those artifacts
  reach the public origin via the receive wrapper (dynamic path), which C
  does not alter. C does **not** by itself make `push-to-web-host.sh` a
  superset of the old script; ⑫ remains its own item, to be resolved either
  by extending the canonical push allowlist or by switching ⑫'s check to
  usage-based. This design neither blocks nor unblocks ⑫; the earlier
  "⑫ coupled to ⑤" note is superseded — the coupling was to the dynamic
  push allowlist, not to this static-propagation fix.

## 10. Out of scope / follow-ups

- ③ (retire stranded auto-broadcast), ⑧ (runbook rewrite to Mac-sign model),
  ⑦ (e2e runbook test) remain separate design-debt items.
- Whether to also serve `anchor-source.json` / identity artifacts via git
  deploy (vs the current dynamic push) is intentionally left as-is —
  changing it is a ⑫-adjacent decision, not part of restoring static
  propagation.
