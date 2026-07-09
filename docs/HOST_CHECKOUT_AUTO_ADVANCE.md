# Validator-host checkout auto-advance + fail-closed freshness gate

> **Status**: operational reference for `scripts/advance-host-checkout.sh`,
> `scripts/install-metal-host-advance-cron.sh`,
> `scripts/check-scripts-freshness.sh`, and the reconciled
> `scripts/check-host-drift.sh`. Design source:
> [`docs/superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md`](superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md).
>
> **Audience**: anyone debugging "why did the validator host's git `HEAD`
> fall behind `origin/main`", anyone installing or auditing the two host
> crons this doc describes, the operator performing the one-time recovery
> pull or the cron install.

## 1. Problem

Nothing in any deploy leg ever advances the validator host's git `HEAD`:
the GitHub Actions `deploy.yml` rsyncs files but excludes `.git/`,
`scripts/check-host-drift.sh` is read-only by design, and
`scripts/sync-to-validator-host.sh` only rsyncs `scripts/`. So `HEAD` drifts
behind `origin/main` as commits land on `main`. Compounding it, each deploy
stamps cache-bust markers (`?v=<sha>`) into the host's `public/*.html`,
dirtying the working tree so a naive `git pull --ff-only` aborts on the
dirty tree — there was no safe, automated way to close the gap.

## 2. Mechanism (defense in depth)

### ① Self-healing auto-advance (primary) — `scripts/advance-host-checkout.sh`

A cron-driven script that brings host `HEAD` to `origin/main` FF-only,
discarding only the deploy-caused `public/` dirt:

1. `git fetch origin main`.
2. Compute `ahead` (`origin/main..HEAD`) and `behind` (`HEAD..origin/main`).
3. If `ahead > 0`: refuse — make **no changes**, alert at high priority, exit
   1. A host must never author commits (Constitution infra-separation
   rules); this is the one condition the script treats as a hard stop
   rather than something to fix automatically.
4. If `behind == 0`: already in sync, log, exit 0.
5. Otherwise: `git checkout -- public/` (discard only the cache-bust dirt —
   see §3 for why this is safe), then `git pull --ff-only origin main`. On
   success, log the old→new `HEAD` and exit 0; on failure, alert at high
   priority and exit 1 (this can happen if a tracked file outside
   `public/` has uncommitted host-local edits the incoming diff would
   clobber — git itself refuses the merge rather than lose data, and the
   script surfaces that as a loud alert instead of forcing it).

It never runs `git reset --hard`, `git merge`, or discards anything outside
`public/`, and it never invokes any broadcast-capable command.

### ③ Fail-closed freshness gate (backstop) — `scripts/check-scripts-freshness.sh`

A read-only library check (never pulls, resets, or edits anything) that
`git fetch origin main` and reports whether local `HEAD` is behind:

- exit `0` — fresh (`HEAD == origin/main`)
- exit `1` — stale (behind; message names the commit count)
- exit `3` — fetch failed, freshness undetermined

`scripts/run-anchor-pipeline.sh` calls this as step 0, **before** any
anchor generation, signing, or broadcast step. Both exit `1` (stale) and
exit `3` (undetermined) fail the pipeline closed with exit `2` — an
undetermined freshness is never read as "go ahead" on a broadcast-critical
path. The sole bypass is `FYD_ALLOW_STALE_PIPELINE=1`, which is
emergency-only and fires a loud `alert high` on every use so the bypass is
never silent. This closes the risk that a stale host checkout runs an
already-superseded version of the anchor-generation or broadcast-guard
scripts against a live broadcast.

### Reconciled backstop — `scripts/check-host-drift.sh`

The original drift tripwire remains, re-framed as the **backstop** to ①:
it still only fetches and reports (never pulls or resets), and it now fires
only when the auto-advance has stopped working — a healthy auto-advance run
at 04:45 UTC clears drift 30 minutes before the backstop samples host state
at 05:15 UTC (see `scripts/install-metal-host-advance-cron.sh` and
`scripts/install-metal-host-drift-cron.sh` for the generated cron lines).

## 3. Why discarding `public/` on the host is safe

`git checkout -- public/` is scoped to `public/` only and is never applied
to any other path. This is safe specifically because the validator host is
**internal, not the public origin**: `docker-compose.behind-proxy.yml:20`
binds Caddy to `127.0.0.1:${BEHIND_PROXY_PORT:-8085}:80` — loopback only,
plain HTTP, not reachable from outside the host. Real users are served from
the Xserver public origin behind the edge CDN, which receives its own
independent rsync from the same deploy workflow (see
[`docs/DEPLOY_OWNERSHIP_MATRIX.md`](DEPLOY_OWNERSHIP_MATRIX.md)). So nothing
user-facing ever reads the host's `public/` working tree, and the next
deploy re-stamps the cache-bust markers regardless of what the auto-advance
discards now. The 2026-07-09 investigation that motivated this mechanism
confirmed zero public-feed impact from the drift this closes: served
content matched `origin/main` byte-for-byte on both targets even while the
host checkout itself was stale.

## 4. Operator-gated boundary

Everything above is repo code: scripts, tests, and installer scripts only.
Two actions are **operator-gated** and were deliberately left out of the
implementation work — this doc records the exact commands so the operator
can run them without further design decisions.

### 4.1 Install the auto-advance cron on the validator host

```sh
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
  'cd /home/deploy/metal.freedom-yield.com && sudo bash scripts/install-metal-host-advance-cron.sh'
```

This writes `/etc/cron.d/metal-host-advance` (`45 4 * * * deploy bash
.../scripts/advance-host-checkout.sh 2>&1 | logger -t host-advance`),
lint-checked by `scripts/check-cron-file.sh` before it is written, and
idempotent (a second run with unchanged content is a no-op). It requires
root (to write `/etc/cron.d/`) and requires
`scripts/advance-host-checkout.sh` to already be present on the host at the
resolved repo path — i.e. it must be run **after** a `main` merge that
carries this mechanism has reached the host (§4.2 or a subsequent deploy).

### 4.2 One-time recovery: FF-pull a host that is currently behind

Before the cron exists, a host that has already drifted behind
`origin/main` stays behind until something pulls it forward once. Running
the same script that the cron will run later is the safe way to do that —
it is read-only about intent (refuses if the host is ever ahead) and
FF-only:

```sh
ssh -i ~/.ssh/<your_validator_host_key> "root@${VALIDATOR_HOST:?set VALIDATOR_HOST first}" \
  'sudo -u deploy bash -c "cd /home/deploy/metal.freedom-yield.com && bash scripts/advance-host-checkout.sh"'
```

Expected output on a healthy recovery: `advanced: behind <N> → 0
(<old-sha>..<new-sha>)`, exit 0. If it instead logs `REFUSED: host is
<N> commit(s) ahead of origin/main`, stop and reconcile manually — do not
force a merge or reset; that condition means the host authored commits
that are not on `origin/main`, which needs a human read before any
correction.

### 4.3 Merging this mechanism to `main`

The scripts and this doc live on a feature branch until the operator
reviews and merges it. Only after `main` carries `scripts/advance-host-checkout.sh`
does the next deploy (or the recovery pull in §4.2) put it on the host, and
only after that can §4.1's installer find the script it wires into cron.
Merging to `main` is an operator decision made outside this doc's scope —
this section exists so the ordering (merge → recovery pull if needed →
install cron) is explicit.

## 5. See also

- `scripts/advance-host-checkout.sh` — the self-heal implementation.
- `scripts/install-metal-host-advance-cron.sh` — its cron installer.
- `scripts/check-scripts-freshness.sh` — the fail-closed freshness library
  check.
- `scripts/check-host-drift.sh` — the backstop tripwire.
- `scripts/run-anchor-pipeline.sh` — the broadcast-critical caller that
  wires the freshness gate as a preflight.
- [`docs/superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md`](superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md) —
  the design spec this doc summarizes for operational use.
- [`docs/DEPLOY_OWNERSHIP_MATRIX.md`](DEPLOY_OWNERSHIP_MATRIX.md) — why the
  host's `public/` copy is never the canonical source, which is the fact
  that makes §3's discard safe.
