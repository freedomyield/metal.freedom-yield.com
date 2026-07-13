# Host checkout auto-advance + fail-closed freshness gate — design

> **Status:** design spec for the permanent fix to validator-host git-checkout drift.
> **Origin:** 2026-07-09 investigation (4-team read-only audit) of the `host-drift: checkout diverging behind=21(>10)` ntfy alert.
> **Approach chosen:** ① self-healing auto-advance + ③ fail-closed freshness gate (defense in depth). Approach ② (separate checkout from deploy target) rejected as too large a change to live infra for the risk.

## 1. Problem

The validator host holds a git checkout at the deploy path. Nothing in any
deploy leg advances its `HEAD`:

- GitHub Actions `deploy.yml` rsyncs files but excludes `.git/` — never advances HEAD.
- `scripts/check-host-drift.sh` is a read-only tripwire — never pulls.
- `scripts/sync-to-validator-host.sh` rsyncs `scripts/` — never advances HEAD.
- The only `git pull --ff-only` lives in `scripts/vps-bootstrap.sh:99` (one-time provisioning).

So `HEAD` drifts behind `origin/main` as commits land. Compounding it, the
deploy rewrites `public/*.html` with cache-bust `?v=<sha>` markers, dirtying
the working tree, so a naive `git pull --ff-only` **aborts** on the dirty
tree (`deploy.yml:166-175` documents this as "structurally unavoidable").

### Confirmed blast radius (2026-07-09 investigation)
- **Public feed: zero impact.** The GitHub Actions deploy rsyncs to the host and Xserver independently of host HEAD, so served content matched `origin/main` HEAD (`?v=fe4400c7`, `anchor-source.json` byte-identical).
- **Frequent host cron feeds: zero impact.** None of the 21 drifted commits touched `node-info.sh` / peer / uptime scripts.
- **Real, time-boxed risk (Important):** the anchor pipeline scripts (`gen-anchor-source.sh`, `gen-anchor-receipt.sh`) and broadcast guards (`broadcast-guard.sh`, `bin/safe-broadcast`) WERE updated in the drifted commits. If the next anchor pipeline run (cycle-4 transition, 2026-08-04) executes on the host while it is stale, it runs **old versions missing R13/R18 schema-validation + durable-archive and R12/R16 broadcast hardening**. Mitigating factor: signing is Mac-only, so the host alone cannot complete a broadcast.
- **`computed_from_git_commit` provenance degradation (Important, NOT Critical):** `gen-anchor-source.sh:163,485` embeds the host-local `git rev-parse HEAD` into the `computed_from_git_commit` provenance field. When host HEAD is unreachable from origin, that SHA is a dangling pointer. **It is NOT hashed into `dag_root_computed`** (that is computed only from the three branch roots at `gen-anchor-source.sh:475-478`), so anchor integrity is unaffected (`docs/ANCHOR_SOURCE.md:261`). It is a provenance-quality defect only.

### Host role (decisive for the safe fix)
Host Caddy binds `127.0.0.1:${BEHIND_PROXY_PORT:-8085}:80` only
(`docker-compose.behind-proxy.yml:20`) — it is internal / behind proxy. Real
users hit the Xserver public origin + CDN. Therefore discarding the deploy's
cache-bust rewrites in the host's `public/` (to un-block the FF-pull) has
**no real-user impact**: the next deploy re-applies cache-bust, and public
traffic never touched the host copy.

## 2. Solution (defense in depth)

### ① Self-healing auto-advance (primary)
A host-side script + cron that periodically brings host `HEAD` to
`origin/main` FF-only, discarding only the deploy-caused `public/` dirt:

```
fetch origin main
ahead = rev-list --count origin/main..HEAD
behind = rev-list --count HEAD..origin/main
if ahead > 0:         refuse + alert high (host must never author) ; exit non-zero
if behind == 0:       log in-sync ; exit 0
git checkout -- public/     # discard deploy cache-bust dirt (safe: host is internal)
git pull --ff-only          # advance HEAD
on failure:           alert + exit non-zero
on success:           log behind→0
```

### ③ Fail-closed freshness gate (backstop)
Before the broadcast-critical anchor pipeline runs, a read-only check refuses
to proceed if local `HEAD` is behind `origin/main`, so stale
hardening-missing scripts never execute on the broadcast path even if ① failed.

### Reconcile the existing tripwire
`check-host-drift.sh` remains, re-framed as a backstop to ① (it detects if ①
ever stops working). Docs + TOOLKIT updated.

## 3. Global constraints (binding — reviewers copy verbatim)

1. **Host must NEVER author.** Any automation MUST refuse (make no changes, alert, exit non-zero) when `git rev-list --count origin/main..HEAD` > 0.
2. **FF-only.** Use `git pull --ff-only` only. NEVER `git reset --hard`, `git merge`, or any destructive git op in automation (CLAUDE.md: destructive VPS ops require a human).
3. **`public/`-only discard.** `git checkout -- public/` is permitted and MUST be justified inline by the host-internal fact (`docker-compose.behind-proxy.yml:20`). NEVER discard any path outside `public/`.
4. **No broadcast.** PRIME DIRECTIVE — none of these scripts may invoke `proton`, `cleos`, `bin/safe-broadcast`, or any broadcast-capable command.
5. **Conventions.** `set -euo pipefail` (document any deliberate exception, as `check-host-drift.sh` does); alerts via `notify.sh`; cron installers run `check-cron-file.sh` preflight + `logger` tagging + root-required guard; all host/repo paths env-overridable; NO literal host identifiers (IP / SSH key names) anywhere.
6. **Tests.** Every new script gets a test under `tests/` mirroring the nearest existing harness (`tests/host-drift/`, `tests/deploy/`). Tests must not contact any real host or run broadcast commands.
7. **Operator-gated boundary.** These deliverables are repo code + tests + installer scripts ONLY. Installing the cron on the host and merging to `main` (which fires the deploy) are operator-gated actions performed later — the SDD run must NOT run the installer against the host nor merge to main.

## 4. Out of scope
- The operational one-time recovery (FF-pull the currently-21-behind host) — separate operator-gated step, needs host connection.
- Approach ② (splitting the git checkout from the deploy target).
- Any change to the broadcast mechanism itself.

## 5. Related
- `scripts/check-host-drift.sh` — existing tripwire (the symptom detector this closes the loop behind).
- `.github/workflows/deploy.yml:166-175` — documents the dirty-`public/` abort.
- `docs/DEPLOY_OWNERSHIP_MATRIX.md` — deploy vs runtime ownership.
- Investigation findings: `scratchpad/drift-investigation/A–D`.

## 6. Addendum 2026-07-13: superseded by deploy git-SoT inversion

This spec's §1 "Problem" statement — "GitHub Actions `deploy.yml` rsyncs
files but excludes `.git/` — never advances HEAD" — was accurate when
written (2026-07-09) and remains accurate as history: at that time nothing
in any deploy leg advanced the host checkout. It is **no longer true of
`deploy.yml` today**. As of the 2026-07-13 delivery-ownership inversion
(see `docs/superpowers/plans/2026-07-13-deploy-git-sot-inversion.md`),
`deploy.yml`'s **"Advance host checkout to origin/main"** step pipes and
runs this very spec's own primary mechanism
(`scripts/advance-host-checkout.sh`) directly, at every deploy, before any
rsync — not only via the daily cron. The former whole-repo rsync described
implicitly throughout §1 is also gone: the sole remaining rsync
(**"Rsync public/ to VPS"**) ships only the deploy-transformed `public/`
tree; every other git-tracked file now reaches the host exclusively via
the git advance this spec designed.

None of this invalidates the mechanism itself — §2① (self-healing
auto-advance) and §3's global constraints still describe
`scripts/advance-host-checkout.sh` as shipped, now with an added
`self_heal_lossless_dirt` step (2026-07-13) to absorb rsync-clobber dirt
left by the retired whole-repo rsync on the first post-inversion run. For
the current operational picture, see
[`docs/HOST_CHECKOUT_AUTO_ADVANCE.md`](../../HOST_CHECKOUT_AUTO_ADVANCE.md)
rather than this spec's §1.
