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

**Originally** (until the 2026-07-13 delivery-ownership inversion),
nothing in any deploy leg advanced the validator host's git `HEAD`: the
GitHub Actions `deploy.yml` rsynced files but excluded `.git/`,
`scripts/check-host-drift.sh` is read-only by design, and
`scripts/sync-to-validator-host.sh` only rsyncs `scripts/`. So `HEAD`
drifted behind `origin/main` as commits landed on `main`. Compounding it,
each deploy stamps cache-bust markers (`?v=<sha>`) into the host's
`public/*.html`, dirtying the working tree so a naive
`git pull --ff-only` aborts on the dirty tree — there was no safe,
automated way to close the gap.

**As of 2026-07-13**, `deploy.yml`'s **"Advance host checkout to
origin/main"** step closes this directly: it pipes the runner's own copy
of `scripts/advance-host-checkout.sh` to the host over SSH and runs it
*before* any rsync, so host `HEAD` is FF-current with every push that
reaches deploy — not just once a day. What makes that safe even though
rsync-written cache-bust dirt (and, on the very first inversion run,
leftover pre-inversion rsync dirt) still sits in the working tree is the
self-heal described in §2① below.

## 2. Mechanism (defense in depth)

### ① Self-healing auto-advance (primary) — `scripts/advance-host-checkout.sh`

Invoked two ways: by the daily cron (§4.1), and — since the 2026-07-13
delivery-ownership inversion — directly from `.github/workflows/deploy.yml`
at every deploy (see "Deploy-time invocation" below). Either way it brings
host `HEAD` to `origin/main` FF-only:

1. `git fetch origin main`.
2. Compute `ahead` (`origin/main..HEAD`) and `behind` (`HEAD..origin/main`).
3. If `ahead > 0`: refuse — make **no changes**, alert at high priority, exit
   1. A host must never author commits (Constitution infra-separation
   rules); this is the one condition the script treats as a hard stop
   rather than something to fix automatically.
4. If `behind == 0`: already in sync, log, exit 0.
5. Otherwise: `git checkout -- public/` — unconditionally discard the
   deploy cache-bust dirt (see §3 for why this is safe).
6. **Self-heal** (`self_heal_lossless_dirt`, added 2026-07-13): absorb any
   *other* working-tree dirt that is byte-identical to `origin/main` — see
   "Self-heal" below.
7. `git pull --ff-only origin main`. On success, log the old→new `HEAD`
   and exit 0; on failure, alert at high priority and exit 1 (this can
   happen if a tracked file outside `public/` has uncommitted host-local
   edits — not byte-identical to `origin/main` — that the incoming diff
   would clobber: git itself refuses the merge rather than lose data, and
   the script surfaces that as a loud alert instead of forcing it).

It never runs `git reset --hard`, `git merge`, or discards content that
differs from `origin/main`, and it never invokes any broadcast-capable
command. Discarding `public/` (step 5) is unconditional; discarding
anything else (step 6) is conditional on byte-for-byte equality — see
below.

#### Self-heal: absorbing lossless rsync-clobber dirt

`self_heal_lossless_dirt` runs between the `public/` discard and the FF
pull. It walks `git status --porcelain -z --untracked-files=all`, skips
every `public/*` path (already handled unconditionally in step 5), and
absorbs exactly two porcelain states:

- **` M ` (tracked, modified in the worktree, index clean):** absorbed
  only if `git diff --quiet origin/main -- <path>` is true — i.e. the
  worktree content **and mode** already match what the incoming pull
  would write anyway. Absorption reverts the file with `git checkout --
  <path>`.
- **`?? ` (untracked):** absorbed only if `origin/main` already tracks
  that path (`git cat-file -e origin/main:<path>`) **and** its content is
  byte-identical (`git show origin/main:<path> | cmp -s - <path>`).
  Absorption removes the file with `rm`.

Anything else — staged changes, real content divergence, deletions, mode
drift on an otherwise-identical file — is left untouched and falls
through to git's own FF-pull refusal in step 7 (loud, `alert high`, exit
1, `HEAD` unchanged). If a self-heal mutating op itself fails (the `git
checkout --` or `rm` call), the script alerts `high` immediately
("host-advance: self-heal revert failed" / "...removal failed") and exits
1 without attempting the pull.

Each absorbed path is logged individually; if one or more files were
absorbed, a single batched **`default`**-priority notify fires titled
`host-advance: self-healed N file(s)`, naming every absorbed path. This
is informational, not an incident — the pull that follows recreates the
identical bytes either way, so nothing was lost. But it is not routine
either: it means **something wrote git-tracked content onto the host
outside git** (an operator-run `scripts/sync-to-validator-host.sh`, or —
on the very first deploy after the 2026-07-13 inversion — leftover dirt
from the retired whole-repo rsync). A `host-advance: self-healed` notify
is the signal to go find that writer, not to dismiss the alert because
"it healed itself."

#### Deploy-time invocation

`.github/workflows/deploy.yml`'s **"Advance host checkout to
origin/main"** step runs before any rsync:

```sh
ssh ... "$SSH_USER@$SSH_HOST" \
  "FYD_REPO_DIR='$DEPLOY_PATH' FYD_NOTIFY='$DEPLOY_PATH/scripts/notify.sh' bash -s" \
  < scripts/advance-host-checkout.sh
```

It pipes the **runner's own checked-out copy** of the script (`bash -s`
over stdin) rather than invoking whatever copy already sits on the host —
so a deploy always runs the version of the self-heal that this exact push
shipped, never a stale on-host copy, even on the very first run after
this mechanism itself is deployed. Fail-closed: if the script exits
non-zero (refused, fetch failed, not-a-git-checkout, or a
non-absorbable pull conflict), the SSH command fails, the step fails, and
the deploy job stops there — the `public/` rsync and the Caddy step never
run against a host whose checkout the advance couldn't verify or bring
current.

The step then asserts `git merge-base --is-ancestor $GITHUB_SHA HEAD` on
the host: the host fetches `origin/main` from GitHub independently of the
runner, so if GitHub's ref advertisement lags the triggering push, the
advance can exit 0 with the host still short of the pushed commit — the
assertion fails the deploy loudly instead of letting the later steps run
against stale files. The two invocation paths (this step and the daily
cron) are also serialized against each other: the script takes a
per-checkout `flock` on `<git-dir>/fyd-advance.lock` (waiting up to 120 s;
timeout alerts `high` and exits 1), so an overlap never fires a spurious
git-lock alert. On systems without `flock` (macOS dev/test) the lock is
skipped.

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

> **Status (2026-07-10): both actions below are complete.** The mechanism
> merged to `main` (`702676c`), the host FF-pulled from 32 commits behind
> to zero (`546a0eb..09cc6bd`), and §4.1's cron installer ran successfully
> — `/etc/cron.d/metal-host-advance` has run daily at 04:45 UTC since. The
> runbooks in §4.1–§4.3 stay below as reference (reinstall, audit, or a
> future host rebuild); §4.3 is kept as the historical record of the
> merge ordering.

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

### 4.3 Merging this mechanism to `main` (historical — completed 2026-07-10)

The scripts and this doc lived on a feature branch (`fix/host-checkout-auto-advance`)
until the operator reviewed and merged it. `main` picked up
`scripts/advance-host-checkout.sh` and this doc via merge commit `702676c`
on 2026-07-10; that same day's follow-on deploy (plus a manual §4.2
recovery pull) brought the host from 32 commits behind to zero, landing at
`09cc6bd`, and §4.1's installer then found the script already on the host
and wrote the cron. This section is kept as the historical record of that
ordering (merge → recovery pull → install cron) for anyone auditing when
the mechanism went live; it is not a pending task.

## 5. Known edge cases

### 5.1 An untracked file in `public/` collides with a file `origin/main` newly tracks

`git checkout -- public/` (§2① step 5) only discards changes Git already
tracks under `public/` — it never touches untracked files anywhere. This
edge case is untouched by the 2026-07-13 self-heal: `self_heal_lossless_dirt`
(§2① step 6) explicitly skips every `public/*` path, so nothing under
`public/` is ever absorbed, byte-identical or not. `scripts/advance-host-checkout.sh`
never runs `git clean` or any other untracked-file deletion by design (see
the script's header: "NEVER: ... discarding anything outside `public/`
unless byte-identical to origin/main ... discarding content that differs
from origin/main"). If an untracked file already sits at a path that the
incoming `origin/main` diff wants to create as a newly-tracked file,
`git pull --ff-only origin main` refuses with git's own "untracked working
tree file would be overwritten by merge" guard, and the script takes the
same fail-loud branch as any other pull failure (§2① step 7): `alert high
"host-advance: ff-only pull failed"`, exit 1, `HEAD` left unchanged. Because
the script never deletes the colliding file and `HEAD` never advances, the
same alert fires again on every subsequent cron tick and every deploy (see
"Deploy-time invocation" in §2①) until an operator intervenes — this is
deliberate: the mechanism stops exactly at "would require deleting content
Git doesn't manage," it does not push through.

**Operator recovery**: move the colliding untracked file out of `public/`
to a scratch location, then let the next cron tick (or a manual `bash
scripts/advance-host-checkout.sh` run, or the next deploy) retry the pull.

### 5.2 Detached `HEAD` or a checkout on a branch other than `main`

The script has no explicit check for the current branch name or for a
detached `HEAD` state. It computes `ahead`/`behind` purely from
`origin/main..HEAD` / `HEAD..origin/main` rev-list counts and runs `git pull
--ff-only origin main` regardless of what `HEAD` currently points at. The
mechanism assumes the validator host checkout is always on `main` (the host
must never author commits — Constitution infra-separation rules — so it has
no reason to be elsewhere). If the host checkout were ever moved to another
branch or into a detached state by hand, this script would not detect or
flag that condition on its own; it would keep comparing against `main` and
behave however `git pull --ff-only origin main` behaves from that starting
state, which is outside this script's tested scenarios (`tests/host-advance/test-advance-host-checkout.sh`
covers ahead/behind/dirty-tree/fetch-failure cases, all starting from a
normal `main` checkout).

## 6. See also

- `.github/workflows/deploy.yml` — the validator-host deploy leg; its
  "Advance host checkout to origin/main" step is the deploy-time
  invocation of this same script (§2① "Deploy-time invocation").
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
