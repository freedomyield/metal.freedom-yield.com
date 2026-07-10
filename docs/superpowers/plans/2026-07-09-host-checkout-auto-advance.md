# Plan: host checkout auto-advance + fail-closed freshness gate

Executes `docs/superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md`.
6 sequential tasks. Each: TDD, one focused commit set, implementer self-review, task review (spec + quality), fix loop.

## Global Constraints (bind every task — see spec §3)

1. Host must NEVER author: refuse (no changes, alert high, exit non-zero) when `git rev-list --count origin/main..HEAD` > 0.
2. FF-only: `git pull --ff-only` only. NEVER `git reset --hard` / `git merge` / destructive git in automation.
3. `public/`-only discard: `git checkout -- public/` permitted, justified inline by host-internal fact (`docker-compose.behind-proxy.yml:20`). NEVER discard outside `public/`.
4. No broadcast: no `proton` / `cleos` / `bin/safe-broadcast` / any broadcast-capable command.
5. Conventions: `set -euo pipefail` (document deliberate exceptions); alerts via `scripts/notify.sh`; cron installers use `check-cron-file.sh` preflight + `logger` + root guard; paths env-overridable; NO literal host identifiers.
6. Tests: every script gets a `tests/` test mirroring `tests/host-drift/` or `tests/deploy/`; no real host contact; no broadcast.
7. Operator-gated: deliverables are repo code + tests + installers ONLY. Do NOT run the installer on the host or merge to main during this run.

Reference existing patterns before writing: `scripts/check-host-drift.sh`, `scripts/install-metal-host-drift-cron.sh`, `scripts/notify.sh`, `scripts/check-cron-file.sh`, `tests/host-drift/*`.

---

## Task 1: `advance-host-checkout.sh` — safe self-healing advance

Create `scripts/advance-host-checkout.sh`: bring the local checkout to `origin/main` FF-only, safely, following the spec §2① algorithm exactly.

**Behavior (exact):**
- `set -uo pipefail` (mirror `check-host-drift.sh`'s documented no-`-e` rationale IF the drift-counting idiom needs it; otherwise `set -euo pipefail`). Justify the choice in a header comment.
- Env overrides: `FYD_REPO_DIR` (default: script's repo root), `FYD_NOTIFY` (default: `<script dir>/notify.sh`).
- `git -C "$REPO_DIR" fetch --quiet origin main`; on failure → `alert default` + exit 2 (transient; next tick retries) — mirror `check-host-drift.sh:77-81`.
- `AHEAD = git rev-list --count origin/main..HEAD`; `BEHIND = git rev-list --count HEAD..origin/main`.
- If `AHEAD` != 0 → `alert high "host-advance: refused (host has local commits)"` with the ahead count; make NO changes; exit 1. (Constraint 1.)
- If `BEHIND` == 0 → log "already in sync"; exit 0.
- Else: `git -C "$REPO_DIR" checkout -- public/` (discard deploy cache-bust dirt; inline comment citing `docker-compose.behind-proxy.yml:20` host-internal justification — Constraint 3). Then `git -C "$REPO_DIR" pull --ff-only origin main`.
  - On pull success → log "advanced: behind N → 0 (<old7>..<new7>)"; exit 0.
  - On pull failure → `alert high "host-advance: ff-only pull failed"` including stderr summary; exit 1.
- NEVER touch any path other than `public/`; NEVER reset/merge (Constraint 2).
- One-line log per run (healthy path), like `check-host-drift.sh`.

**Tests** — `tests/host-advance/test-advance-host-checkout.sh`, mirroring `tests/host-drift/test-check-host-drift.sh` fixture style (temp git repos, a fake `FYD_NOTIFY` recording script, no real host):
1. ahead>0 → refuses, makes no changes (HEAD unchanged), alert fired, exit 1.
2. behind>0 clean tree → advances to origin/main, exit 0.
3. behind>0 with dirty `public/` (simulated cache-bust edit) → discards public/, advances, exit 0.
4. behind>0 with a dirty tracked file OUTSIDE public/ → the FF pull path still only discards public/; assert the non-public change is NOT silently discarded (either pull proceeds because that file isn't in the incoming diff, or fails loudly — assert no data-loss of non-public edits).
5. fetch failure → alert default, exit 2.
6. in-sync → exit 0, no alert.

Model: standard.

---

## Task 2: `install-metal-host-advance-cron.sh` — cron installer

Create `scripts/install-metal-host-advance-cron.sh` mirroring `scripts/install-metal-host-drift-cron.sh` structure exactly (read that file first).

**Behavior:**
- Writes `/etc/cron.d/metal-host-advance` (env override `FYD_CRON_TARGET`).
- Root-required guard when target is the real `/etc/cron.d/` path (mirror the root-required guard in install-metal-host-drift-cron.sh).
- Cron line runs `advance-host-checkout.sh` as user `deploy`, piped to `logger -t host-advance`. Choose a schedule that runs BEFORE the daily drift check (`check-host-drift.sh` runs `15 5 * * *`) so a healthy auto-advance clears drift before the tripwire samples — e.g. `45 4 * * * deploy bash ${REPO_PATH}/scripts/advance-host-checkout.sh 2>&1 | logger -t host-advance`. State the ordering rationale in a comment.
- Pre-flight the generated file through `check-cron-file.sh` before installing (mirror the check-cron-file.sh pre-flight in install-metal-host-drift-cron.sh); refuse on failure.
- `FYD_REPO_PATH` env override for the repo path, same as the drift installer.
- Same exit-code contract as the drift installer.

**Tests** — `tests/host-advance/test-install-metal-host-advance-cron.sh` mirroring `tests/host-drift/test-install-metal-host-drift-cron.sh`: generated cron file passes `check-cron-file.sh`; contains the advance script path + `deploy` user + `logger -t host-advance`; non-root refusal path; missing-script refusal path.

Model: standard.

---

## Task 3: `check-scripts-freshness.sh` — read-only fail-closed freshness checker

Create `scripts/check-scripts-freshness.sh`: a read-only gate that reports whether the local checkout is behind `origin/main` (i.e. running stale scripts). It NEVER pulls or edits.

**Behavior:**
- `set -euo pipefail`.
- Env overrides: `FYD_REPO_DIR` (default script repo root).
- `git -C "$REPO_DIR" fetch --quiet origin main`; on failure → print a clear stderr message + exit 3 (cannot determine freshness; caller decides — but see Task 4 for fail-closed wiring). Do NOT alert here (this is a library-style check invoked by other scripts; the caller owns alerting).
- `BEHIND = git rev-list --count HEAD..origin/main`.
- If `BEHIND` > 0 → print `STALE: local HEAD is <N> commit(s) behind origin/main; run advance-host-checkout.sh before proceeding` to stderr; exit 1.
- Else → print `fresh: HEAD == origin/main` (stdout); exit 0.
- Exit codes: 0 fresh, 1 stale, 3 fetch-failed. Document them in the header.

**Tests** — `tests/scripts-freshness/test-check-scripts-freshness.sh`: fresh→exit 0; behind→exit 1 with STALE message; fetch-fail→exit 3. Temp git repos, no real host.

Model: standard.

---

## Task 4: Wire the freshness gate fail-closed into the anchor pipeline

Integrate `check-scripts-freshness.sh` (Task 3) as a fail-closed preflight in `scripts/run-anchor-pipeline.sh` at the broadcast-critical entry, BEFORE any anchor generation/broadcast step. Read `run-anchor-pipeline.sh` fully first to find the correct insertion point and its existing option/flag conventions.

**Behavior:**
- Near the top of the pipeline (after arg parsing, before any `gen-anchor-*`/sign/broadcast step), call `check-scripts-freshness.sh`.
- **Fail-closed:** if the checker exits non-zero (stale OR fetch-failed, i.e. exit 1 or 3), the pipeline MUST abort with a clear message ("refusing to run anchor pipeline on a stale/undetermined checkout — run advance-host-checkout.sh") and a non-zero exit. Fetch-failure is treated as fail-closed (do NOT proceed on unknown freshness on the broadcast path).
- Provide an explicit, documented override for emergencies only: env `FYD_ALLOW_STALE_PIPELINE=1` skips the gate with a loud `alert high` that it was bypassed. Default is enforce. (This mirrors the project's fail-closed-with-audited-override posture; justify in a comment.)
- Do NOT weaken any existing guard in the pipeline; only add the preflight.

**Tests** — extend/create `tests/anchor-pipeline/` coverage: pipeline aborts (non-zero, no anchor generated) when the freshness checker reports stale; pipeline proceeds past the gate when fresh; `FYD_ALLOW_STALE_PIPELINE=1` bypasses with an alert. Use a stubbed `check-scripts-freshness.sh` / stubbed git so the test never contacts a real host and never broadcasts.

Model: standard (broadcast-adjacent — review with care).

---

## Task 5: Reconcile `check-host-drift.sh` as a backstop

Now that ① exists, re-frame the tripwire. Minimal change — do NOT alter its read-only nature or its drift math.

**Behavior:**
- Update the header comment: `check-host-drift.sh` is now the BACKSTOP that detects if `advance-host-checkout.sh` has stopped working; the auto-advance cron is the primary self-heal. Reference `scripts/advance-host-checkout.sh`.
- Update the alert message text so an operator reading the push knows the first remedy is "check why auto-advance stopped" (not "manually reconcile"), while keeping the existing detail string.
- No threshold or logic change unless a test reveals an inconsistency introduced by the new wording.

**Tests** — update `tests/host-drift/test-check-host-drift.sh` expectations for any changed message string; keep all existing assertions green.

Model: cheap.

---

## Task 6: Docs, TOOLKIT, operator runbook

Document the mechanism and record the operator-gated boundary.

**Deliverables:**
- `TOOLKIT.md`: catalog `advance-host-checkout.sh`, `install-metal-host-advance-cron.sh`, `check-scripts-freshness.sh` following the existing entry format.
- A short ops doc `docs/HOST_CHECKOUT_AUTO_ADVANCE.md`: the problem (one paragraph), the ①+③ mechanism, the `public/`-discard safety justification (host-internal, `docker-compose.behind-proxy.yml:20`), the fail-closed gate, and — explicitly — that **installing the cron on the host and merging to main are operator-gated** (with the exact operator commands to install: `sudo bash scripts/install-metal-host-advance-cron.sh`, plus the one-time recovery FF-pull procedure for a currently-behind host).
- Cross-link from `docs/DEPLOY_OWNERSHIP_MATRIX.md` (see-also) to the new doc so the "why did HEAD drift" question lands on the mechanism.
- If a memory-worthy operational fact exists, note it in the doc, not in code.

**Tests:** none (docs). Run `bash scripts/check-cron-file.sh` sanity only if a cron sample is embedded; otherwise N/A.

Model: cheap.

---

## Dependency notes
- Task 2 depends on Task 1 (installs the script it runs).
- Task 4 depends on Task 3 (wires the checker).
- Task 5 depends on Task 1 (references it).
- Task 6 depends on all (documents them).
Execute in order 1→6.
