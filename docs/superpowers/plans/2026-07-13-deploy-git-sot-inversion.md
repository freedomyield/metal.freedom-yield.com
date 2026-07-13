# Deploy Git-SoT Inversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permanently eliminate the "deploy rsync clobbers git-tracked files on the validator host → host `git pull --ff-only` aborts" recurrence class by inverting delivery ownership: git becomes the sole delivery path for all tracked files (advanced at deploy time, daily cron as backstop), and rsync ships only the deploy-transformed `public/` tree.

**Architecture:** Three mechanisms compose: (1) `scripts/advance-host-checkout.sh` gains a *lossless self-heal* — before the FF-only pull it silently absorbs working-tree dirt that is byte-identical to what the pull would write anyway (the rsync-clobber signature), while continuing to refuse on any real divergence; (2) `.github/workflows/deploy.yml`'s validator-host leg pipes the *pushed commit's* advance script to the host over SSH before rsync (no chicken-and-egg on rollout), then rsyncs only `public/`; (3) the Caddyfile single-file bind mount, whose inode a git pull replaces, is detected as stale by comparing in-container vs on-host content and healed with a scoped `--force-recreate`. Static grep tests pin all workflow invariants; the daily 04:45 UTC cron keeps running the (now self-healing) advance as backstop.

**Tech Stack:** bash (tab-indented, repo house style), GitHub Actions YAML, git plumbing (`status --porcelain -z`, `diff --quiet <commit> -- <path>`, `cat-file -e`, `show`), rsync, docker compose, pure-local test fixtures (tempdir git origin+clone pairs; static grep of workflow files).

## Global Constraints

- **PRIME DIRECTIVE (docs/CONSTITUTION.md top block): TESTNET-FIRST FOR ALL BROADCASTS.** No task in this plan may invoke, add, or test-invoke any broadcast-capable command (`proton action|transaction|transaction:push`, `cleos push_transaction`, RPC `push_transaction`/`issueTx`/`eth_sendRawTransaction`, `bin/safe-broadcast`, or equivalent). All tests are pure-local: tempdir git fixtures and static file greps. No network, no SSH, no real ntfy in tests.
- **No literal host identifiers** in any committed file: no validator-host IPs, no hosting-provider names, no SSH private-key filenames beyond the already-committed `~/.ssh/id_deploy` pattern inside deploy.yml. Hosts are referenced only via `${{ secrets.SSH_HOST }}` / `$SSH_USER` / `$DEPLOY_PATH`, or as "the validator host" / "the web host" in prose.
- **Scripts and tests carry the house header**: a `# CHAIN: none — …` line stating the script never broadcasts (see `scripts/check-scripts-freshness.sh:4` and `tests/host-advance/test-advance-host-checkout.sh:3` for the exact idiom). Bash is indented with TABS in `scripts/` (match `scripts/advance-host-checkout.sh`).
- **Suite must be green after every task**: `bash tests/run-all-tests.sh` exits 0 before each task's final commit. Run it, don't assume the baseline.
- **advance-host-checkout.sh invariants that MUST survive Task 1**: never `git reset --hard`, never `git merge`, never discard content outside `public/` **unless byte-identical (content+mode) to `origin/main`**, always refuse when host is ahead, always alert loudly on refusal/failure. The self-heal may only remove information that the immediately following pull re-creates identically.
- **Numeric claims in reports/commits are measured, never estimated** (run the command, paste the count).
- Commits are single-purpose and explain *why*.
- Do not touch `docs/audits/` untracked files, `.superpowers/`, or anything outside the files each task names.

## Rollout context (read once, applies to review judgment)

The live incident this fixes: the 2026-07-13 push `3446b9b..b54d2e6` touched `CLAUDE.md` + `bin/safe-broadcast`; deploy.yml's whole-repo rsync wrote both onto the host working tree; the 04:45 UTC advance cron's `git pull --ff-only` aborted ("Your local changes… would be overwritten"). The blacklist approach was already patched once (2026-07-06, for `tests/ docs/ TOOLKIT.md scripts/ logs/`) and recurred — hence this inversion. After merge+push, the first deploy run's piped advance script (with self-heal) is expected to absorb the current host dirt automatically because rsync wrote content byte-identical to `origin/main`.

---

### Task 1: Lossless self-heal in advance-host-checkout.sh

**Files:**
- Modify: `scripts/advance-host-checkout.sh` (insert self-heal between the `public/` discard and the FF-only pull; update header comment)
- Test: `tests/host-advance/test-advance-host-checkout.sh` (append cases; follow the existing `build_pair` harness exactly)

**Interfaces:**
- Produces: a shell function `self_heal_lossless_dirt` inside `scripts/advance-host-checkout.sh` (name is load-bearing: Task 4's static gate greps for it) and an informational notify title prefix `host-advance: self-healed` on the recording-stub log.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Read the current script and test suite fully** (`scripts/advance-host-checkout.sh`, `tests/host-advance/test-advance-host-checkout.sh`). Note the `build_pair` fixture (bare origin + clone in mktemp dir, notify stub recording to `$STUB_LOG`) and the existing case naming style.

- [ ] **Step 2: Append failing tests** to `tests/host-advance/test-advance-host-checkout.sh`, mirroring the existing case structure (each case: `build_pair`, arrange, run advancer with `FYD_REPO_DIR="$CLONE" FYD_NOTIFY="$STUB"`, assert, cleanup). Four cases:

```bash
# case: self-heal — tracked file modified but byte-identical to origin/main
# (the rsync-clobber signature) is absorbed and the pull succeeds.
#   arrange: commit a change to docs/README.md in origin (via a second clone
#   or a temp worktree of $ORIGIN), then write that SAME new content into
#   $CLONE/docs/README.md WITHOUT committing (simulates a deploy rsync).
#   assert: advancer exit 0; clone HEAD == origin main HEAD;
#           git -C "$CLONE" status --porcelain is empty;
#           $STUB_LOG contains "self-healed".

# case: self-heal — untracked file identical to an incoming NEW tracked file
#   arrange: add a brand-new tracked file scripts/new-tool.sh in origin;
#   create $CLONE/scripts/new-tool.sh with identical bytes, untracked.
#   assert: advancer exit 0; file tracked and clean afterwards;
#           $STUB_LOG contains "self-healed".

# case: refusal preserved — tracked file modified with REAL divergence
#   arrange: commit a change to docs/README.md in origin; write DIFFERENT
#   content into $CLONE/docs/README.md.
#   assert: advancer exit 1; $STUB_LOG contains "ff-only pull failed";
#           $CLONE/docs/README.md still contains the divergent content
#           (nothing was destroyed).

# case: staged change is NOT healed even if identical to origin/main
#   arrange: same as first case but `git -C "$CLONE" add docs/README.md`.
#   assert: advancer exit 1 (pull refused); staged change still present.
```

- [ ] **Step 3: Run the suite, verify the four new cases FAIL** (`bash tests/host-advance/test-advance-host-checkout.sh`; expect existing cases PASS, new cases FAIL).

- [ ] **Step 4: Implement `self_heal_lossless_dirt`** in `scripts/advance-host-checkout.sh`. Insert the function definition near the existing `log`/`alert` helpers, and call it after the `public/` discard block and before the `git pull --ff-only` block, inside the `BEHIND > 0` path. Exact code (tabs):

```bash
# self_heal_lossless_dirt — absorb working-tree dirt that is byte-identical
# (content AND mode) to what the incoming FF pull would write anyway.
# This is the rsync-clobber signature: a deploy leg (or manual rsync) wrote
# origin/main's bytes onto the host outside git, so git sees "local
# changes" and refuses the pull even though nothing would be lost.
# Reverting such a file to HEAD (or deleting such an untracked file) loses
# zero information — the pull that follows immediately re-creates the
# identical bytes. Anything NOT byte-identical (real local work, staged
# edits, deletions, mode drift) is deliberately left alone so git's own
# refusal keeps protecting it, exactly as before.
self_heal_lossless_dirt() {
	local healed=0 healed_list="" entry path
	while IFS= read -r -d '' entry; do
		[ "${#entry}" -ge 4 ] || continue
		path="${entry:3}"
		case "$path" in public/*) continue ;; esac
		case "$entry" in
		" M "*)
			# tracked, modified in the worktree only (index clean)
			if git -C "$REPO_DIR" diff --quiet origin/main -- "$path"; then
				git -C "$REPO_DIR" checkout -- "$path"
				log "self-heal: reverted lossless dirt (worktree == origin/main): ${path}"
				healed=$((healed + 1)); healed_list="${healed_list}${path} "
			fi
			;;
		"?? "*)
			# untracked file colliding with an incoming tracked path
			if git -C "$REPO_DIR" cat-file -e "origin/main:${path}" 2>/dev/null \
				&& git -C "$REPO_DIR" show "origin/main:${path}" | cmp -s - "${REPO_DIR}/${path}"; then
				rm -- "${REPO_DIR}/${path}"
				log "self-heal: removed untracked file identical to origin/main: ${path}"
				healed=$((healed + 1)); healed_list="${healed_list}${path} "
			fi
			;;
		esac
	done < <(git -C "$REPO_DIR" status --porcelain -z --untracked-files=all)
	if [ "$healed" -gt 0 ]; then
		alert default "host-advance: self-healed ${healed} file(s)" "Absorbed lossless working-tree dirt identical to origin/main before FF pull: ${healed_list}— something wrote git-tracked content outside git (rsync leg?); the pull proceeds, but the writer should be identified."
	fi
}
```

Call site (between the existing public/ discard and the pull):

```bash
self_heal_lossless_dirt
```

Notes for the implementer: the script runs under `set -euo pipefail`; every command above that can legitimately return non-zero is already inside an `if` guard or `case`. `git status --porcelain -z` emits `XY<space>path<NUL>`; rename entries (two NUL fields) only occur for staged renames, which match neither `" M "` nor `"?? "` patterns — the length guard skips any stray second field. Mode divergence is covered: `git diff --quiet origin/main -- path` is non-quiet on mode-only changes, so such files are not healed (the pull then refuses loudly — correct, conservative).

- [ ] **Step 5: Update the script's header comment**: extend the "Algorithm" block with a step 6.5 describing the self-heal and its lossless-only guarantee, and extend the "NEVER" block with "never discards content that differs from origin/main".

- [ ] **Step 6: Run the suite** — `bash tests/host-advance/test-advance-host-checkout.sh` (all cases PASS), then `bash tests/run-all-tests.sh` (exit 0).

- [ ] **Step 7: Commit** — `git add scripts/advance-host-checkout.sh tests/host-advance/test-advance-host-checkout.sh && git commit` with a message explaining *why* (rsync-clobber dirt is lossless; absorbing it closes the recurring pull-abort class without weakening the never-destroy-local-work invariant).

### Task 2: deploy.yml — deploy-time git advance + public/-only rsync

**Files:**
- Modify: `.github/workflows/deploy.yml` (validator-host leg only: insert advance step after "Ensure deploy path exists"; replace the whole-repo rsync step; rewrite its comment block. Do NOT touch the web-host public-origin steps, the cache-bust step, the gitleaks job, or the compose step — the compose step is Task 3's file area.)
- Modify: `tests/deploy/test-host-rsync-excludes.sh` (rewrite: the blacklist it pins no longer exists; it becomes the whitelist pin)
- Check-and-adjust if needed: `tests/deploy/test-rsync-delete-protection.sh`, `tests/deploy/test-build-rsync-excludes.sh` (they may pin the old `build-rsync-excludes.sh "public/"` prefix or the old rsync line; run them and update only assertions that reference the replaced validator-host rsync block)

**Interfaces:**
- Consumes: `scripts/advance-host-checkout.sh` with `FYD_REPO_DIR` / `FYD_NOTIFY` env overrides (exists today; Task 1 adds self-heal but the invocation contract is unchanged).
- Produces: a workflow step literally named `Advance host checkout to origin/main` that pipes the runner's script via `bash -s`, ordered BEFORE a step named `Rsync public/ to VPS` whose transfer source is exactly `public/`. Task 3 and Task 4 grep for these names.

- [ ] **Step 1: Read `.github/workflows/deploy.yml` fully** and run `bash scripts/deploy/build-rsync-excludes.sh ""` vs `"public/"` to understand the prefix argument (the web-host public-origin leg at the bottom already uses the empty prefix with transfer root `public/` — the new validator-host rsync uses the same shape).

- [ ] **Step 2: Rewrite `tests/deploy/test-host-rsync-excludes.sh` first (failing)**. Keep the filename (it is discovered by `tests/run-all-tests.sh`). New assertions, static grep of the workflow (keep the existing `ok`/`no` helper style and the file's `set -u` + CHAIN header):
  - the validator-host leg contains a step `Advance host checkout to origin/main`;
  - that step pipes the repo copy: a line matching `< scripts/advance-host-checkout.sh` (regex `<[[:space:]]*scripts/advance-host-checkout\.sh`);
  - that step sets both `FYD_REPO_DIR=` and `FYD_NOTIFY=`;
  - the validator-host rsync source/dest line is `public/ "$SSH_USER@$SSH_HOST:$DEPLOY_PATH/public/"` — and NO line in the file matches the old whole-repo shape `./ "$SSH_USER@$SSH_HOST:$DEPLOY_PATH/"`;
  - the new rsync still carries `--delete`, `--inplace`, and `"${FEED_EXCLUDES[@]}"` built with the empty prefix (`build-rsync-excludes.sh ""`) — host-generated feed files under `public/` must survive `--delete` exactly as before;
  - the advance step appears at a smaller line number than the public/ rsync step (order pin: `grep -n` both step names, compare).
  Update the header comment to explain the inversion (git = tracked files, rsync = transformed public/ only) and why the old four excludes are gone (nothing outside public/ is shipped at all).

- [ ] **Step 3: Run it, verify FAIL** — `bash tests/deploy/test-host-rsync-excludes.sh`.

- [ ] **Step 4: Edit `.github/workflows/deploy.yml`.** Insert after the "Ensure deploy path exists" step:

```yaml
      - name: Advance host checkout to origin/main
        # Delivery-ownership inversion (2026-07-13): git is the ONLY
        # delivery path for tracked files. We advance the host checkout
        # BEFORE any rsync so the compose/Caddy step below always runs
        # against the pushed commit's files. The script is piped from the
        # runner's checkout (bash -s) — the host executes the version this
        # push shipped, never a stale on-host copy, which also lets its
        # self-heal absorb dirt left behind by the pre-inversion rsync on
        # the very first run. Fail-closed: if the host cannot FF (real
        # local divergence, host ahead, fetch failure), the script alerts
        # via on-host ntfy AND this deploy fails loudly here.
        run: |
          ssh -i ~/.ssh/id_deploy -p "$SSH_PORT" -o StrictHostKeyChecking=no \
            "$SSH_USER@$SSH_HOST" \
            "FYD_REPO_DIR='$DEPLOY_PATH' FYD_NOTIFY='$DEPLOY_PATH/scripts/notify.sh' bash -s" \
            < scripts/advance-host-checkout.sh
```

  Then replace the "Rsync site to VPS" step (name it `Rsync public/ to VPS`): delete the whole `--exclude` blacklist and the old comment block, and rsync only the cache-busted `public/`:

```yaml
      - name: Rsync public/ to VPS
        # ONLY the deploy-transformed public/ tree travels by rsync — it is
        # the one artifact git cannot deliver (cache-bust ?v=<sha> markers
        # are stamped into the runner's copy above, deliberately diverging
        # from the committed files; the host-side advance discards public/
        # dirt before each pull, so this never blocks git). Every other
        # tracked file reaches the host via the git advance step above.
        # This replaces the pre-2026-07-13 whole-repo rsync whose exclude
        # blacklist repeatedly leaked git-tracked files (tests/docs/TOOLKIT
        # in 07-06, CLAUDE.md + bin/ in 07-13) and broke the host's
        # ff-only pull. Feed excludes (shared SoT: deploy/feed-excludes.txt
        # via the emitter) still protect host-generated feed files from
        # --delete; empty prefix because the transfer root is public/,
        # same as the web-host public-origin leg below.
        run: |
          mapfile -t FEED_EXCLUDES < <(bash scripts/deploy/build-rsync-excludes.sh "")
          rsync -rltvz --delete --inplace \
            -e "ssh -i ~/.ssh/id_deploy -p $SSH_PORT -o StrictHostKeyChecking=no" \
            "${FEED_EXCLUDES[@]}" \
            public/ "$SSH_USER@$SSH_HOST:$DEPLOY_PATH/public/"
```

- [ ] **Step 5: Run the rewritten test (PASS) and the other two deploy suites**; adjust their assertions ONLY where they pin the replaced block (e.g. a grep for the old `"public/"` emitter prefix in the validator leg). `bash tests/run-all-tests.sh` must exit 0.

- [ ] **Step 6: Commit** — workflow + tests together, message explaining the ownership inversion and naming the two recurrences (2026-07-06, 2026-07-13) it terminates.

### Task 3: Caddyfile stale-mount detection in the compose step

**Files:**
- Modify: `.github/workflows/deploy.yml` — ONLY the `Bring up / reload Caddy on VPS` step
- Create: `tests/deploy/test-caddyfile-stale-mount-heal.sh`

**Interfaces:**
- Consumes: Task 2's guarantee that the host checkout is already at the pushed commit when this step runs.
- Produces: nothing consumed later; Task 4 pins only this step's ordering, not its body.

**Why:** `caddy/Caddyfile` is a single-file bind mount (`docker-compose.yml:25`), pinned to the host inode at container creation. The old whole-repo rsync used `--inplace` precisely to write into that inode. A git pull replaces the file (new inode), so after the inversion the running container would keep reading the ORPHANED old inode and `caddy reload` would reload stale config. Detection is state-based (compare what the container sees vs what the host file says), so it also heals any pre-existing stale mount and is a no-op when nothing changed.

- [ ] **Step 1: Write the failing static test** `tests/deploy/test-caddyfile-stale-mount-heal.sh` (CHAIN header, `set -u`, `ok`/`no` helpers like siblings). Assert, in the `Bring up / reload Caddy on VPS` step's `run:` block:
  - a `cmp -s` comparing the container view (`docker compose … exec -T caddy cat /etc/caddy/Caddyfile`) against `caddy/Caddyfile`;
  - a `--force-recreate caddy` branch taken when they differ;
  - the `caddy reload` path still present for the no-change case;
  - the trailing `curl -fsS … /health` check still present.

- [ ] **Step 2: Run it, verify FAIL.**

- [ ] **Step 3: Rewrite the compose step's remote command.** Replace the current single `ssh … "cd … && docker compose … up -d … && … reload … && curl …"` with a heredoc-fed remote bash so the conditional is readable:

```yaml
      - name: Bring up / reload Caddy on VPS
        # up -d first (recreates on compose-config change as before). Then
        # stale-mount heal: the Caddyfile is a single-file bind mount
        # pinned to the inode present at container creation; the git
        # advance step above updates the file via git (new inode), so if
        # the container's view differs from the host file the mount is
        # stale and only a container recreate — not `caddy reload`, which
        # reads through the same stale mount — can pick up the new config.
        # State-based (content compare), so it is a no-op on unchanged
        # Caddyfiles and also heals a stale mount left by any earlier
        # deploy. Reload still covers the recreate-skipped path; the
        # health check guards both.
        run: |
          ssh -i ~/.ssh/id_deploy -p "$SSH_PORT" -o StrictHostKeyChecking=no \
            "$SSH_USER@$SSH_HOST" "DEPLOY_PATH='$DEPLOY_PATH' bash -s" <<'REMOTE'
          set -euo pipefail
          cd "$DEPLOY_PATH"
          COMPOSE="docker compose -f docker-compose.yml -f docker-compose.behind-proxy.yml"
          $COMPOSE up -d --remove-orphans --build
          if $COMPOSE exec -T caddy cat /etc/caddy/Caddyfile | cmp -s - caddy/Caddyfile; then
            $COMPOSE exec -T caddy caddy reload --config /etc/caddy/Caddyfile
          else
            echo "Caddyfile bind mount is stale (container view != host file) — recreating caddy"
            $COMPOSE up -d --force-recreate caddy
          fi
          sleep 2
          curl -fsS -o /dev/null http://127.0.0.1:8085/health
          REMOTE
```

  (Indentation caution: the heredoc body must sit inside the YAML block scalar; `<<'REMOTE'` with the quoted delimiter keeps `$COMPOSE` literal on the remote. Verify the file still parses — `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml'))"` or `actionlint` if available; state in the report which parser you ran. Note the existing step hardcodes port 8085 in its health check; keep that value.)

- [ ] **Step 4: Run the new test (PASS) and `bash tests/run-all-tests.sh` (exit 0).**

- [ ] **Step 5: Commit** — workflow + test, message explaining the inode-pinning failure mode the heal closes.

### Task 4: Structural regression gate for the inversion

**Files:**
- Create: `tests/deploy/test-deploy-git-sot-gate.sh`

**Interfaces:**
- Consumes: Task 1's function name `self_heal_lossless_dirt`; Task 2's step names.
- Produces: nothing; this is the permanent tripwire. (It is auto-discovered by `tests/run-all-tests.sh`, which BOTH `validate.yml` and `ci-main.yml` invoke — per the project rule that main-push and PR paths must carry the same gates. Verify both workflows still call `bash tests/run-all-tests.sh` and say so in the report.)

- [ ] **Step 1: Write the gate test** (CHAIN header, `set -u`, sibling style; support a `FYD_WORKFLOW_FILE` env override for the workflow path, defaulting to the repo's deploy.yml). Assertions beyond Task 2's per-block pins — these defend the ARCHITECTURE against regression by future edits:
  - `scripts/advance-host-checkout.sh` defines `self_heal_lossless_dirt` AND calls it exactly once outside the definition;
  - `.github/workflows/deploy.yml` contains NO rsync invocation whose transfer source is the repo root `./` (no line matching `\./ "\$SSH_USER@\$SSH_HOST:` anywhere) — the whole-repo shape must never come back;
  - every rsync destination in the validator-host leg (between the `Advance host checkout` step and the `Set up Xserver deploy key` step) matches `:\$DEPLOY_PATH/public/`;
  - step order: `Advance host checkout to origin/main` < `Rsync public/ to VPS` < `Bring up / reload Caddy on VPS` (compare `grep -n` line numbers);
  - the advance cron installer still exists and still points at the same script (`grep -q 'advance-host-checkout.sh' scripts/install-metal-host-advance-cron.sh`) — the daily backstop stays wired.

- [ ] **Step 2: Run it (PASS — Tasks 1–3 landed), run the full suite (exit 0).** Then prove the gate can fail: copy deploy.yml to a tempfile, `sed` one pinned invariant away (e.g. rename the advance step), run the test with `FYD_WORKFLOW_FILE=<tempfile>`, expect FAIL; show that red run in the report.

- [ ] **Step 3: Commit.**

### Task 5: Documentation propagation

**Files:**
- Modify: `docs/DEPLOY_OWNERSHIP_MATRIX.md` (delivery ownership table: git = all tracked files at deploy time + daily cron backstop; rsync = transformed `public/` only)
- Modify: `docs/HOST_CHECKOUT_AUTO_ADVANCE.md` (self-heal semantics: what is absorbed — byte-identical content+mode vs origin/main, unstaged/untracked only; what still refuses; the new deploy-time invocation via `bash -s`; the informational `self-healed` notify)
- Modify: `docs/DEPLOY_SETUP.md` (new-host bootstrap now requires a git clone at `$DEPLOY_PATH` — `mkdir -p` alone yields advance exit 2 "not a git checkout" and a failed deploy, which is the intended fail-closed signal; document the Caddyfile stale-mount heal)
- Modify: `TOOLKIT.md` (advance-host-checkout.sh entry: add self-heal one-liner)

**Interfaces:** consumes the exact behaviors landed in Tasks 1–3; produces nothing.

- [ ] **Step 1: Read the four files** and locate every statement describing the old model (whole-repo rsync, exclude blacklist, "host receives tests/docs via its own git checkout", manual-reconcile-on-abort instructions).

- [ ] **Step 2: Update all four files.** Content requirements (write in each doc's existing language/style):
  - the ownership matrix must state the single rule: *if git tracks it, git delivers it; rsync ships only deploy-derived artifacts (cache-busted `public/`)* — and name the two dirt classes that remain possible on the host: deploy-stamped `public/` (discarded by advance) and operator-run `scripts/sync-to-validator-host.sh` writing uncommitted local `scripts/` (absorbed by self-heal only if identical to origin/main; otherwise advance refuses loudly, by design);
  - HOST_CHECKOUT_AUTO_ADVANCE.md gets a "Self-heal" section with the exact absorption criteria and a note that a `host-advance: self-healed` notify after the inversion means *something unexpected wrote git-content outside git and should be identified*;
  - DEPLOY_SETUP.md notes that `paths-ignore` (README/CLAUDE.md/docs) pushes skip deploy, so those files reach the host at the next 04:45 UTC cron advance — expected, not drift;
  - keep heading nesting strict `h1 → h2 → h3`; no inline styles; no host IPs / provider names / SSH key names.

- [ ] **Step 3: Verify** — `grep -n 'exclude' docs/DEPLOY_OWNERSHIP_MATRIX.md` shows no stale blacklist description; `bash tests/run-all-tests.sh` exit 0 (docs are not tested, but run it anyway to catch accidental file damage).

- [ ] **Step 4: Commit** (docs-only, single purpose).

### Task 6: Repo-wide concept-propagation sweep

**Files:**
- Modify: any file (outside `docs/audits/`) whose comments/prose still assert the old delivery model — typical candidates: `scripts/check-host-drift.sh` header, `scripts/advance-host-checkout.sh` motivation comment (its lines ~5–15 describe the old deploy rsync + "sync-to-validator-host.sh only rsyncs scripts/" — verify still accurate, adjust only what the inversion changed), `scripts/deploy/build-rsync-excludes.sh` comments, `docs/superpowers/specs/2026-07-09-host-checkout-auto-advance-design.md` (append an addendum section — do NOT rewrite the historical spec body; it is a dated design record)

**Interfaces:** consumes Tasks 1–5 landed; produces the final clean state.

- [ ] **Step 1: Sweep.** Run and read every hit (exclude `.git`, `docs/audits/`, `.superpowers/`, `node_modules`):

```bash
grep -rn --exclude-dir=.git --exclude-dir=audits --exclude-dir=.superpowers \
  --exclude-dir=node_modules \
  -e 'whole-repo rsync' -e "exclude='tests/" -e "exclude='docs/" \
  -e 'rsync.*--exclude.*TOOLKIT' -e 'inplace-touch' \
  -e 'rsyncs files but excludes' .
grep -rn --exclude-dir=.git 'Rsync site to VPS' .
```

- [ ] **Step 2: Fix each stale statement** to describe the inverted model, preserving dated historical records (specs, audit docs) untouched except via clearly-marked addendum sections ("Addendum 2026-07-13: superseded by deploy git-SoT inversion, see docs/superpowers/plans/2026-07-13-deploy-git-sot-inversion.md").

- [ ] **Step 3: Full verification** — `bash tests/run-all-tests.sh` exit 0; paste the suite count. Re-run the Step 1 greps: zero un-annotated stale hits.

- [ ] **Step 4: Commit.**

---

## Self-review notes

- Spec coverage: recurrence class killed at the producer (Task 2 whitelist), the consumer hardened for any residual/legacy producer (Task 1 self-heal), the one file that legitimately needed `--inplace` handled state-based (Task 3), regression-gated (Task 4), documented (Task 5), and swept (Task 6).
- Deliberate non-goals: no change to the web-host public-origin leg (rrsync-confined, not a git-checkout problem); no change to `paths-ignore`; no host-side manual reconcile task (the first post-merge deploy self-heals; if it alerts instead, that is the fail-closed path and is handled as live-ops, not in this plan).
- Name consistency: `self_heal_lossless_dirt` (Tasks 1, 4), step names `Advance host checkout to origin/main` / `Rsync public/ to VPS` / `Bring up / reload Caddy on VPS` (Tasks 2, 3, 4), env overrides `FYD_REPO_DIR`/`FYD_NOTIFY` (Tasks 1, 2), gate override `FYD_WORKFLOW_FILE` (Task 4 only).
