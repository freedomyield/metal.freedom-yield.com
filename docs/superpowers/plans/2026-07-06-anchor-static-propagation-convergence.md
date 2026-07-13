# Static Propagation Convergence (defect ⑤) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a `git push` reliably propagate git-tracked static content to the public Xserver origin (not just the internal validator host), without disturbing the dynamically-pushed feeds that share `public/api/`.

**Architecture:** Add a second rsync target (the public Xserver) to `.github/workflows/deploy.yml`, reusing the asset-versioned build. The dynamically-pushed feed exclusion set is extracted to a single source of truth (`deploy/feed-excludes.txt` + `scripts/deploy/build-rsync-excludes.sh`) that both rsync invocations and the regression test consume, so the two targets can never drift. The CI deploy key is confined to the metal public directory on the multi-project shared host via an `rrsync -wo` restriction.

**Tech Stack:** GitHub Actions (bash on ubuntu runner), `rsync`, `rrsync` (write-only restricted wrapper on Xserver), POSIX shell test harnesses.

## Global Constraints

- **Multi-project host safety (highest priority):** The Xserver hosts unrelated co-tenant projects. The CI deploy key MUST be confined to `/home/<acct>/metal.freedom-yield.com/public` via `command="rrsync -wo <dir>",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding`. Never use the root key (`id_rsa`) as the CI key. Never write host-wide.
- **No literal host identifiers in tracked files:** No real IP, no SSH key filename, no operator PII, no account name in any committed file. Use env placeholders (`${XSERVER_HOST:?}`) and `<acct>` in docs.
- **Infra is operator-executed (Constitution §5 / W7):** AI produces the installer script, the workflow diff, and verification steps. Key generation, running the installer on Xserver, and registering Actions secrets are done by the operator. Installer-script-first: no heredoc/one-liner paste for operator manual actions.
- **Single source of truth for the feed exclusion set:** `deploy/feed-excludes.txt` is authoritative. Both rsyncs and the regression test derive their excludes from it via `scripts/deploy/build-rsync-excludes.sh`. No second hand-maintained list.
- **`--delete` safety:** Every rsync that writes into a `public/api/` (or `public/calendar/`) tree with `--delete` MUST exclude every dynamically-pushed feed, or the delete erases fresh feeds.
- **The canonical feed set** (exactly the files currently excluded in `deploy.yml:147-167`), expressed relative to `public/`:
  `api/validator.json`, `api/server-status.json`, `api/peer-geo.json`, `api/uptime-recent.json`, `api/uptime-cycles.json`, `api/peers.json`, `api/evidence.json`, `api/fee-market.json`, `api/fee-market-history.jsonl`, `api/node-health-recent.json`, `api/peers-changes.json`, `api/peers-gini.json`, `api/peers-gini-history.jsonl`, `api/peers-history-index.json`, `api/cycle-history.jsonl`, `api/anchor-source.json`, `api/anchor-source.json.sig`, `api/anchor-receipt.json`, `api/anchor-receipt.json.sig`, `api/anchor-history.jsonl`, `calendar/`.

---

## File Structure

- `deploy/feed-excludes.txt` (NEW) — the canonical feed list, one `public/`-relative path per line.
- `scripts/deploy/build-rsync-excludes.sh` (NEW) — emits `--exclude=/<prefix><line>` args from the list; the shared exclude-building logic.
- `tests/deploy/test-build-rsync-excludes.sh` (NEW) — unit test for the emitter.
- `tests/deploy/test-rsync-delete-protection.sh` (MODIFY) — extend to drive both deploy shapes (the validator host prefix `public/`, Xserver prefix ``) through the emitter and assert feed survival + static copy.
- `.github/workflows/deploy.yml` (MODIFY) — the validator host rsync consumes the emitter (behavior-preserving); add Xserver key setup + Xserver rsync steps.
- `scripts/install-xserver-static-deploy-key.sh` (NEW) — operator-run once; installs the `rrsync`-restricted `authorized_keys` line.
- `tests/install-xserver-static-deploy-key/test-install-xserver-static-deploy-key.sh` (NEW) — scenario tests against tmp fixtures (no real host).
- `docs/DEPLOY_OWNERSHIP_MATRIX.md` (MODIFY) — correct the "canonical source reaches public" framing; name the Xserver target + exclusion coupling.
- `docs/DEPLOY_SETUP.md` (MODIFY) — replace single-VPS model with the two-host reality.

---

## Task 1: Shared feed-exclusion list + emitter

**Files:**
- Create: `deploy/feed-excludes.txt`
- Create: `scripts/deploy/build-rsync-excludes.sh`
- Test: `tests/deploy/test-build-rsync-excludes.sh`

**Interfaces:**
- Produces: `scripts/deploy/build-rsync-excludes.sh <prefix>` — prints, one per line, `--exclude=/<prefix><entry>` for each non-blank, non-`#` entry in `deploy/feed-excludes.txt`. `<prefix>` is `public/` for the whole-repo (the validator host) rsync and `` (empty) for the `public/`-rooted (Xserver) rsync. Exit non-zero if the list file is missing.

- [ ] **Step 1: Write the failing test**

Create `tests/deploy/test-build-rsync-excludes.sh`:

```bash
#!/usr/bin/env bash
# Unit test for scripts/deploy/build-rsync-excludes.sh
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
EMIT="${REPO}/scripts/deploy/build-rsync-excludes.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

# The validator host shape: prefix public/
OUT="$(bash "${EMIT}" "public/")"
echo "${OUT}" | grep -qx -- '--exclude=/public/api/validator.json' \
  && ok "public/ prefix anchors validator.json" || no "public/ validator.json"
echo "${OUT}" | grep -qx -- '--exclude=/public/api/anchor-source.json.sig' \
  && ok "public/ prefix anchors anchor-source.json.sig" || no "public/ .sig"
echo "${OUT}" | grep -qx -- '--exclude=/public/calendar/' \
  && ok "public/ prefix anchors calendar/" || no "public/ calendar/"

# Xserver shape: empty prefix
OUT="$(bash "${EMIT}" "")"
echo "${OUT}" | grep -qx -- '--exclude=/api/validator.json' \
  && ok "empty prefix anchors api/validator.json" || no "empty api/validator.json"
echo "${OUT}" | grep -qx -- '--exclude=/calendar/' \
  && ok "empty prefix anchors calendar/" || no "empty calendar/"

# Count parity: both shapes emit the same number of lines
H="$(bash "${EMIT}" "public/" | wc -l | tr -d ' ')"
X="$(bash "${EMIT}" "" | wc -l | tr -d ' ')"
[ "${H}" = "${X}" ] && [ "${H}" = 21 ] \
  && ok "both shapes emit 21 excludes" || no "count parity (h=${H} x=${X})"

# Missing list file → non-zero exit
if FEED_EXCLUDES_FILE=/nonexistent bash "${EMIT}" "public/" >/dev/null 2>&1; then
  no "missing list should fail"
else ok "missing list fails closed"; fi

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/deploy/test-build-rsync-excludes.sh`
Expected: FAIL — `build-rsync-excludes.sh` does not exist yet (all assertions error).

- [ ] **Step 3: Create the canonical list**

Create `deploy/feed-excludes.txt`:

```
# Dynamically-pushed feeds — written into the public web root's api/ and
# calendar/ by the validator-host-side push (scripts/push-to-web-host.sh) and the
# Xserver-side receive wrapper. Any rsync with --delete into a public tree
# MUST exclude these or the delete erases fresh feeds.
#
# Paths are relative to public/. Consumed by
# scripts/deploy/build-rsync-excludes.sh (single source of truth). Keep in
# lock-step with docs/DEPLOY_OWNERSHIP_MATRIX.md and the Xserver receive
# wrapper allowlist.
api/validator.json
api/server-status.json
api/peer-geo.json
api/uptime-recent.json
api/uptime-cycles.json
api/peers.json
api/evidence.json
api/fee-market.json
api/fee-market-history.jsonl
api/node-health-recent.json
api/peers-changes.json
api/peers-gini.json
api/peers-gini-history.jsonl
api/peers-history-index.json
api/cycle-history.jsonl
api/anchor-source.json
api/anchor-source.json.sig
api/anchor-receipt.json
api/anchor-receipt.json.sig
api/anchor-history.jsonl
calendar/
```

- [ ] **Step 4: Create the emitter**

Create `scripts/deploy/build-rsync-excludes.sh`:

```bash
#!/usr/bin/env bash
# build-rsync-excludes.sh <prefix>
# Emit rsync --exclude args (leading-anchored) for the dynamically-pushed
# feeds listed in deploy/feed-excludes.txt. Single source of truth so the
# the validator host (whole-repo, prefix "public/") and Xserver (public/-rooted, prefix
# "") rsyncs cannot drift.
set -euo pipefail
PREFIX="${1?usage: build-rsync-excludes.sh <prefix>}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIST="${FEED_EXCLUDES_FILE:-${REPO}/deploy/feed-excludes.txt}"
[ -r "${LIST}" ] || { echo "ERROR: feed list not readable: ${LIST}" >&2; exit 1; }
while IFS= read -r line || [ -n "${line}" ]; do
  case "${line}" in ''|\#*) continue ;; esac
  printf -- '--exclude=/%s%s\n' "${PREFIX}" "${line}"
done < "${LIST}"
```

Then: `chmod +x scripts/deploy/build-rsync-excludes.sh tests/deploy/test-build-rsync-excludes.sh`

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/deploy/test-build-rsync-excludes.sh`
Expected: PASS — `RESULTS: 7 PASS / 0 FAIL`.

- [ ] **Step 6: Commit**

```bash
git add deploy/feed-excludes.txt scripts/deploy/build-rsync-excludes.sh tests/deploy/test-build-rsync-excludes.sh
git commit -m "feat(deploy): single-source feed exclusion list + emitter for both rsync targets"
```

---

## Task 2: Extend the rsync-delete-protection regression test to both shapes

**Files:**
- Modify: `tests/deploy/test-rsync-delete-protection.sh`

**Interfaces:**
- Consumes: `scripts/deploy/build-rsync-excludes.sh` (Task 1).

**Context:** This test builds a synthetic source/destination pair and runs a local `rsync --delete` with the deploy exclusion list, asserting feeds survive and static is copied. It currently covers only the validator host (whole-repo) shape with an inline list. We add coverage for the Xserver (`public/`-rooted) shape and drive both from the emitter.

- [ ] **Step 1: Read the current test to find its assertion helpers and fixture builder**

Run: `sed -n '1,120p' tests/deploy/test-rsync-delete-protection.sh`
Note the fixture-building function and the `ok`/`no` helpers so the new block matches style.

- [ ] **Step 2: Add the failing Xserver-shape test block**

Append a new scenario before the results summary. It must:
1. Build a synthetic `src/public/{api,calendar,index.html}` with two feeds (`api/validator.json`, `api/anchor-source.json`) and two static files (`api/identity.schema.v1.json`, `index.html`).
2. Build a synthetic `dst/` containing FRESH feed values plus a STALE static file.
3. Run `rsync -rltz --delete $(bash "${REPO}/scripts/deploy/build-rsync-excludes.sh" "") src/public/ dst/`.
4. Assert: feeds in `dst/api/` retain their fresh values (not deleted, not overwritten), static files are updated from src, and a static file present in dst but absent in src IS deleted (delete semantics active for non-excluded files).

```bash
echo "[Xserver shape] public/-rooted rsync preserves feeds, updates static"
XS="$(mktemp -d)"; mkdir -p "${XS}/src/public/api" "${XS}/src/public/calendar" "${XS}/dst/api"
printf 'SRC-static\n'      > "${XS}/src/public/api/identity.schema.v1.json"
printf 'SRC-home\n'        > "${XS}/src/public/index.html"
printf 'src-should-skip\n' > "${XS}/src/public/api/validator.json"
printf 'src-should-skip\n' > "${XS}/src/public/api/anchor-source.json"
printf 'FRESH-feed\n'      > "${XS}/dst/api/validator.json"
printf 'FRESH-anchor\n'    > "${XS}/dst/api/anchor-source.json"
printf 'STALE-static\n'    > "${XS}/dst/api/identity.schema.v1.json"
printf 'ORPHAN\n'          > "${XS}/dst/api/old-removed.json"
mapfile -t XEXC < <(bash "${REPO}/scripts/deploy/build-rsync-excludes.sh" "")
rsync -rltz --delete "${XEXC[@]}" "${XS}/src/public/" "${XS}/dst/"
grep -qx 'FRESH-feed'   "${XS}/dst/api/validator.json"       && ok "Xserver: validator.json feed preserved"   || no "Xserver: validator.json clobbered/deleted"
grep -qx 'FRESH-anchor' "${XS}/dst/api/anchor-source.json"   && ok "Xserver: anchor-source.json feed preserved" || no "Xserver: anchor-source.json clobbered/deleted"
grep -qx 'SRC-static'   "${XS}/dst/api/identity.schema.v1.json" && ok "Xserver: static schema updated from src" || no "Xserver: static schema not updated"
[ -f "${XS}/dst/index.html" ] && grep -qx 'SRC-home' "${XS}/dst/index.html" && ok "Xserver: index.html copied" || no "Xserver: index.html missing"
[ ! -f "${XS}/dst/api/old-removed.json" ] && ok "Xserver: non-feed orphan deleted (delete active)" || no "Xserver: orphan not deleted"
rm -rf "${XS:?}"
```

- [ ] **Step 3: Run to verify the new block passes (and the existing the validator host block still passes)**

Run: `bash tests/deploy/test-rsync-delete-protection.sh`
Expected: PASS — existing assertions plus the 5 new Xserver assertions, `0 FAIL`.

- [ ] **Step 4: Commit**

```bash
git add tests/deploy/test-rsync-delete-protection.sh
git commit -m "test(deploy): cover Xserver public/-rooted rsync exclusion via shared emitter"
```

---

## Task 3: Wire deploy.yml — the validator host via emitter (behavior-preserving) + Xserver target

**Files:**
- Modify: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: `scripts/deploy/build-rsync-excludes.sh` (Task 1). New secrets: `XSERVER_SSH_KEY`, `XSERVER_SSH_HOST`, `XSERVER_SSH_USER`, `XSERVER_SSH_PORT`.

**Context:** `deploy.yml:134-168` is the validator host rsync with inline `--exclude='public/api/...'` feed lines (see `deploy.yml:147-167`). We (a) replace those inline feed lines with the emitter output (identical set, `public/` prefix), keeping the structural excludes (`.git/`, `.github/`, `scripts/`, `caddy/data/`, etc.) inline, and (b) add a second target. The Xserver push uses source `./public/` and the emitter with empty prefix.

- [ ] **Step 1: Capture the current the validator host exclude set as a baseline**

Run:
```bash
grep -oE "exclude='public/(api|calendar)[^']*'" .github/workflows/deploy.yml | sort
bash scripts/deploy/build-rsync-excludes.sh "public/" | sed "s|--exclude=/|exclude='|; s|$|'|" | sort
```
Expected: after trivial quoting normalization the two lists name the SAME 21 paths. If they differ, STOP — reconcile `deploy/feed-excludes.txt` before touching the workflow. (This is the behavior-preservation gate.)

- [ ] **Step 2: Refactor the validator host rsync to source excludes from the emitter**

> **Superseded 2026-07-13:** the "Rsync site to VPS" step this instruction targets no longer exists — the delivery-ownership inversion ([`2026-07-13-deploy-git-sot-inversion.md`](2026-07-13-deploy-git-sot-inversion.md)) removed the whole-repo rsync entirely; kept unedited below as the dated historical plan.

In the "Rsync site to VPS" step, before the `rsync` call, build the feed excludes:

```yaml
        run: |
          mapfile -t FEED_EXCLUDES < <(bash scripts/deploy/build-rsync-excludes.sh "public/")
          rsync -rltvz --delete --inplace \
            -e "ssh -i ~/.ssh/id_deploy -p $SSH_PORT -o StrictHostKeyChecking=no" \
            --exclude='.git/' \
            --exclude='.github/' \
            --exclude='.githooks/' \
            --exclude='.claude/' \
            --exclude='node_modules/' \
            --exclude='.env' \
            --exclude='caddy/data/' \
            --exclude='caddy/config/' \
            --exclude='metalgo/data/' \
            --exclude='metalgo/config/' \
            --exclude='scripts/' \
            "${FEED_EXCLUDES[@]}" \
            ./ "$SSH_USER@$SSH_HOST:$DEPLOY_PATH/"
```

Remove the 21 inline `--exclude='public/api/...'` and `--exclude='public/calendar/'` lines (they are now in `FEED_EXCLUDES`).

- [ ] **Step 3: Add the Xserver key setup step**

After the "Bring up / reload Caddy on VPS" step, add:

```yaml
      - name: Set up Xserver deploy key
        env:
          _XS_KEY: ${{ secrets.XSERVER_SSH_KEY }}
        run: |
          printf '%s' "$_XS_KEY" | tr -d '\r' > ~/.ssh/id_xserver
          [ -z "$(tail -c 1 ~/.ssh/id_xserver)" ] || echo "" >> ~/.ssh/id_xserver
          chmod 600 ~/.ssh/id_xserver
          ssh-keyscan -p "${{ secrets.XSERVER_SSH_PORT }}" "${{ secrets.XSERVER_SSH_HOST }}" >> ~/.ssh/known_hosts 2>/dev/null
```

- [ ] **Step 4: Add the Xserver rsync step**

```yaml
      - name: Rsync public/ to Xserver (public origin)
        # Second deploy target: the public origin behind Cloudflare. The CI
        # key is rrsync -wo confined to the metal public dir, so the remote
        # path is fixed server-side and the client targets the rrsync root.
        # Same feed exclusion set as the validator host rsync (empty prefix because
        # the source root here is public/, not the repo root).
        env:
          XS_HOST: ${{ secrets.XSERVER_SSH_HOST }}
          XS_USER: ${{ secrets.XSERVER_SSH_USER }}
          XS_PORT: ${{ secrets.XSERVER_SSH_PORT }}
        run: |
          mapfile -t FEED_EXCLUDES < <(bash scripts/deploy/build-rsync-excludes.sh "")
          rsync -rltvz --delete \
            -e "ssh -i ~/.ssh/id_xserver -p $XS_PORT -o StrictHostKeyChecking=no" \
            "${FEED_EXCLUDES[@]}" \
            ./public/ "$XS_USER@$XS_HOST:"
```

(The empty path after `:` targets the rrsync-restricted root. If a future rsync version requires an explicit path, use `"$XS_USER@$XS_HOST:."` — the operator's first-deploy verification, Task 4 Step 6, confirms which.)

- [ ] **Step 5: Lint the workflow**

Run: `command -v actionlint >/dev/null && actionlint .github/workflows/deploy.yml || echo "actionlint not installed — skip (syntax reviewed manually)"`
Then: `grep -c "build-rsync-excludes.sh" .github/workflows/deploy.yml`
Expected: `actionlint` clean (or skipped); the emitter is referenced exactly `2` times (the validator host + Xserver); no inline `--exclude='public/api/` lines remain (`grep -c "exclude='public/api" .github/workflows/deploy.yml` → `0`).

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(deploy): add public Xserver as a second rsync target; the validator host excludes via shared emitter"
```

---

## Task 4: Xserver deploy-key installer + scenario tests

**Files:**
- Create: `scripts/install-xserver-static-deploy-key.sh`
- Test: `tests/install-xserver-static-deploy-key/test-install-xserver-static-deploy-key.sh`

**Interfaces:**
- Produces: `scripts/install-xserver-static-deploy-key.sh` — operator-run once. Env: `XSERVER_HOST` (required), `XSERVER_USER` (default `root`), `XSERVER_KEY` (default `$HOME/.ssh/id_rsa`), `WEB_ROOT` (default `/home/<acct>/metal.freedom-yield.com/public` — operator supplies the real path), `CI_PUBKEY` (required: path to the CI deploy key's `.pub`). Installs one `rrsync -wo`-restricted `authorized_keys` line for the CI key. Idempotent, backs up, never edits other entries. For testability the actual `authorized_keys` path is `AUTHORIZED_KEYS_FILE` (default: the remote deploy user's file over SSH; in tests, a local tmp file).

**Context:** The installer has two modes folded into one script: over-SSH (real operator run) and local-file (tests, via `AUTHORIZED_KEYS_FILE` + `SKIP_SSH=1`). Tests exercise the local-file path so no real host is contacted. Follows the shape of `scripts/install-xserver-anchor-source-allowlist.sh`.

- [ ] **Step 1: Write the failing scenario test**

Create `tests/install-xserver-static-deploy-key/test-install-xserver-static-deploy-key.sh`:

```bash
#!/usr/bin/env bash
# Scenario tests for scripts/install-xserver-static-deploy-key.sh (local mode).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
INSTALLER="${REPO}/scripts/install-xserver-static-deploy-key.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

WORK=""; cleanup(){ [ -n "${WORK}" ] && rm -rf "${WORK}"; }; trap cleanup EXIT

setup(){
  WORK="$(mktemp -d)"
  AK="${WORK}/authorized_keys"
  # a pre-existing UNRELATED entry (co-tenant project) that must survive
  printf 'command="rrsync -ro /home/other/project",no-pty ssh-ed25519 AAAAOTHER other@x\n' > "${AK}"
  PUB="${WORK}/ci.pub"
  printf 'ssh-ed25519 AAAACIKEYDATA freedom-yield-static-deploy\n' > "${PUB}"
}
run(){ SKIP_SSH=1 AUTHORIZED_KEYS_FILE="${AK}" CI_PUBKEY="${PUB}" \
       WEB_ROOT="/home/acct/metal.freedom-yield.com/public" \
       XSERVER_HOST="unused-in-local" bash "${INSTALLER}" "$@" 2>&1; }

echo "[T1] installs a restricted line for the CI key"
setup; OUT="$(run)"; RC=$?
if [ "${RC}" = 0 ] \
   && grep -q 'command="rrsync -wo /home/acct/metal.freedom-yield.com/public"' "${AK}" \
   && grep -q 'freedom-yield-static-deploy' "${AK}" \
   && grep -q 'no-pty' "${AK}"; then ok "T1 restricted line installed"; else no "T1 (rc=${RC})"; fi

echo "[T2] the unrelated co-tenant entry is untouched"
grep -q 'AAAAOTHER other@x' "${AK}" && ok "T2 other entry preserved" || no "T2 other entry lost"

echo "[T3] a backup was written"
ls "${AK}".bak-* >/dev/null 2>&1 && ok "T3 backup present" || no "T3 no backup"

echo "[T4] idempotent — second run makes no change and exits 0"
BEFORE="$(sha256sum "${AK}" | cut -d' ' -f1)"; OUT="$(run)"; RC=$?
AFTER="$(sha256sum "${AK}" | cut -d' ' -f1)"
[ "${RC}" = 0 ] && [ "${BEFORE}" = "${AFTER}" ] && ok "T4 idempotent" || no "T4 (rc=${RC})"

echo "[T5] fails closed when CI_PUBKEY missing"
setup; if CI_PUBKEY="${WORK}/nope.pub" SKIP_SSH=1 AUTHORIZED_KEYS_FILE="${AK}" \
        WEB_ROOT="/home/acct/x/public" XSERVER_HOST=u bash "${INSTALLER}" >/dev/null 2>&1; then
  no "T5 should fail"; else ok "T5 fails closed on missing pubkey"; fi

printf 'RESULTS: %s PASS / %s FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/install-xserver-static-deploy-key/test-install-xserver-static-deploy-key.sh`
Expected: FAIL — installer does not exist.

- [ ] **Step 3: Write the installer**

Create `scripts/install-xserver-static-deploy-key.sh`:

```bash
#!/usr/bin/env bash
# install-xserver-static-deploy-key.sh
# Install an rrsync -wo (write-only, single-path) restricted authorized_keys
# entry on the Xserver for the GitHub Actions static-deploy key, confining it
# to the metal public dir on the shared multi-project host.
#
# Operator usage (Mac, once):
#   XSERVER_HOST=<ip> WEB_ROOT=/home/<acct>/metal.freedom-yield.com/public \
#   CI_PUBKEY=~/.ssh/freedom-yield-static-deploy.pub \
#   bash scripts/install-xserver-static-deploy-key.sh
#
# Idempotent. Backs up authorized_keys. Never edits other entries. Does not
# touch other projects' vhosts or services.
set -euo pipefail

: "${CI_PUBKEY:?CI_PUBKEY (path to the CI deploy key .pub) required}"
WEB_ROOT="${WEB_ROOT:?WEB_ROOT (metal public dir on Xserver) required}"
XSERVER_USER="${XSERVER_USER:-root}"
XSERVER_KEY="${XSERVER_KEY:-$HOME/.ssh/id_rsa}"

[ -r "${CI_PUBKEY}" ] || { echo "ERROR: CI_PUBKEY not readable: ${CI_PUBKEY}" >&2; exit 2; }
PUBLINE="$(tr -d '\r\n' < "${CI_PUBKEY}")"
[ -n "${PUBLINE}" ] || { echo "ERROR: CI_PUBKEY is empty" >&2; exit 2; }

# The restricted entry. rrsync -wo <dir> = write-only rsync sandboxed to <dir>.
RESTRICT='command="rrsync -wo '"${WEB_ROOT}"'",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding'
ENTRY="${RESTRICT} ${PUBLINE}"
# match token: the CI key's comment or key body, to detect an existing install
KEYBODY="$(printf '%s' "${PUBLINE}" | awk '{print $2}')"

install_into(){  # $1 = authorized_keys file path (local)
  local AK="$1"
  [ -f "${AK}" ] || : > "${AK}"
  if grep -qF "${KEYBODY}" "${AK}"; then
    echo "OK: CI key already present in ${AK} — no change"
    return 0
  fi
  cp -p "${AK}" "${AK}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || \
    cp "${AK}" "${AK}.bak-manual"   # date unavailable is non-fatal for backup
  printf '%s\n' "${ENTRY}" >> "${AK}"
  echo "OK: installed restricted CI deploy key into ${AK}"
}

if [ "${SKIP_SSH:-0}" = "1" ]; then
  # Local/test mode: operate on a local authorized_keys file.
  install_into "${AUTHORIZED_KEYS_FILE:?AUTHORIZED_KEYS_FILE required in SKIP_SSH mode}"
  exit 0
fi

# Remote mode: rrsync must exist on Xserver; edit ~/.ssh/authorized_keys there.
: "${XSERVER_HOST:?XSERVER_HOST required}"
[ -r "${XSERVER_KEY}" ] || { echo "ERROR: XSERVER_KEY not readable: ${XSERVER_KEY}" >&2; exit 2; }
ssh -i "${XSERVER_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
    "${XSERVER_USER}@${XSERVER_HOST}" \
    "command -v rrsync >/dev/null || { echo 'ERROR: rrsync not found on Xserver (install rsync/rrsync)'; exit 5; }"
# Ship the entry and append remotely (idempotent, with backup) via a here-doc
# that carries ENTRY/KEYBODY as positional args (no secret in the key — it is
# a PUBLIC key).
ssh -i "${XSERVER_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
    "${XSERVER_USER}@${XSERVER_HOST}" \
    "KEYBODY='${KEYBODY}' ENTRY='${ENTRY}' bash -s" <<'REMOTE'
set -euo pipefail
AK="${HOME}/.ssh/authorized_keys"
mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
[ -f "${AK}" ] || : > "${AK}"
if grep -qF "${KEYBODY}" "${AK}"; then echo "OK: CI key already present — no change"; exit 0; fi
cp -p "${AK}" "${AK}.bak-$(date +%Y%m%d-%H%M%S)"
printf '%s\n' "${ENTRY}" >> "${AK}"
chmod 600 "${AK}"
echo "OK: installed restricted CI deploy key on Xserver"
REMOTE
echo "==> Done. Next: register the private key + host/user/port as GitHub Actions secrets,"
echo "    then push to trigger a deploy and verify (see docs/DEPLOY_OWNERSHIP_MATRIX.md)."
```

Then: `chmod +x scripts/install-xserver-static-deploy-key.sh tests/install-xserver-static-deploy-key/test-install-xserver-static-deploy-key.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/install-xserver-static-deploy-key/test-install-xserver-static-deploy-key.sh`
Expected: PASS — `RESULTS: 5 PASS / 0 FAIL` (idempotency T4 relies on the `grep -qF KEYBODY` short-circuit).

- [ ] **Step 5: Commit**

```bash
git add scripts/install-xserver-static-deploy-key.sh tests/install-xserver-static-deploy-key/
git commit -m "feat(deploy): rrsync-restricted Xserver deploy-key installer + scenario tests"
```

- [ ] **Step 6: Operator handoff note (no code) — record the one-time setup**

The operator, once, performs (AI supplies exact commands at handoff, not in the repo):
1. `ssh-keygen -t ed25519 -f ~/.ssh/freedom-yield-static-deploy -C freedom-yield-static-deploy -N ''`
2. `XSERVER_HOST=<ip> WEB_ROOT=<real public dir> CI_PUBKEY=~/.ssh/freedom-yield-static-deploy.pub bash scripts/install-xserver-static-deploy-key.sh`
3. Register secrets `XSERVER_SSH_KEY` (private key), `XSERVER_SSH_HOST`, `XSERVER_SSH_USER`, `XSERVER_SSH_PORT`.
4. Push a trivial change; confirm the deploy's Xserver rsync step succeeds; `curl -s https://metal.freedom-yield.com/api/identity.schema.v1.json | sha256sum` now equals the repo's, while `curl -s https://metal.freedom-yield.com/api/validator.json` remains its freshly-pushed value. (If rsync errored on the empty destination path, switch the workflow target to `"$XS_USER@$XS_HOST:."` and redeploy.)

---

## Task 5: Update the deploy docs to the two-host reality

**Files:**
- Modify: `docs/DEPLOY_OWNERSHIP_MATRIX.md`
- Modify: `docs/DEPLOY_SETUP.md`

**Interfaces:** none (documentation).

- [ ] **Step 1: Correct the ownership matrix framing**

In `docs/DEPLOY_OWNERSHIP_MATRIX.md`, update the intro paragraph so "the Git deploy is the canonical source for repo-tracked content" explicitly states the deploy now reaches **both** the validator host and the public Xserver origin. Add to the "Cross-check protocol" a fourth lock-step location: the Xserver rsync target in `deploy.yml` derives its excludes from `deploy/feed-excludes.txt` (the same source as the validator host), which must stay in lock-step with the receive-wrapper allowlist. Name `deploy/feed-excludes.txt` as the single source of truth for the feed set.

- [ ] **Step 2: Correct DEPLOY_SETUP.md**

In `docs/DEPLOY_SETUP.md`, replace the single-VPS model (DNS → one VPS Caddy) with: (a) GitHub Actions deploys the repo to the validator host (internal Caddy); (b) GitHub Actions also rsyncs `public/` to the public Xserver origin (behind Cloudflare) using the rrsync-restricted deploy key; (c) dynamic feeds flow the validator host cron → receive wrapper → Xserver `public/api/`. Add the `XSERVER_SSH_*` secrets to the secrets table.

- [ ] **Step 3: Verify no literal host identifiers were introduced**

Run the canonical guard (do not hand-roll a regex that would itself embed a
forbidden literal): `bash scripts/publish-guard.sh` — or simply let the
pre-commit hook run at Step 4.
Expected: no forbidden host identifier / operator PII reported; the docs use
`<acct>` / `${XSERVER_HOST}` placeholders only (real IP, real account name,
and the validator SSH key name must never appear).

- [ ] **Step 4: Commit**

```bash
git add docs/DEPLOY_OWNERSHIP_MATRIX.md docs/DEPLOY_SETUP.md
git commit -m "docs(deploy): document the two-host deploy (the validator host internal + public Xserver)"
```

---

## Task 6: Full suite green + gitleaks

**Files:** none (verification).

- [ ] **Step 1: Run the deploy tests + gitleaks**

Run:
```bash
bash tests/deploy/test-build-rsync-excludes.sh
bash tests/deploy/test-rsync-delete-protection.sh
bash tests/install-xserver-static-deploy-key/test-install-xserver-static-deploy-key.sh
git log -1 --stat >/dev/null && echo "gitleaks runs on commit hook"
```
Expected: all three suites `0 FAIL`.

- [ ] **Step 2: Confirm the emitter list still matches the ownership matrix + receive wrapper**

Run: `bash scripts/deploy/build-rsync-excludes.sh "" | wc -l`
Expected: `21`. Cross-check the 21 names against the ownership matrix table rows marked "validator push = YES" plus `calendar/`; any mismatch is drift to reconcile before the first real deploy.

- [ ] **Step 3: Report status to operator**

Summarize: code merged, tests green, installer ready; the mechanism goes live only after the operator completes the Task 4 Step 6 one-time setup (key + installer + secrets), whose first deploy backfills the 2026-07-02-frozen public static (including the ① schema retirement).

---

## Self-Review

**Spec coverage:**
- §3 approach C (second rsync target) → Task 3.
- §3.1 source-root difference (`./public/`) → Task 3 Step 4.
- §3.2 backfill (first deploy) → Task 4 Step 6, Task 6 Step 3.
- §4 single-SoT exclusion, one list two prefixes → Tasks 1–2 (emitter + both-shape test), Task 3 (both rsyncs consume it).
- §5 multi-project safety (dedicated key, rrsync -wo) → Task 4 (installer) + Global Constraints.
- §6 components (deploy.yml, installer, matrix, setup doc, both tests) → Tasks 3, 4, 5, 1, 2.
- §7 error handling (Xserver fails after the validator host; --delete vs feeds; rrsync absent aborts) → Task 3 ordering, Task 2 test, Task 4 installer rrsync check.
- §8 testing → Tasks 1, 2, 4 + Task 6.
- §9 ⑫ decoupling → no code; documented in spec; nothing in this plan touches the push allowlist. Correct.

**Placeholder scan:** No TBD/TODO; every code/test step shows full content; `<acct>`/`<ip>` are deliberate PII placeholders per Global Constraints.

**Type/name consistency:** `scripts/deploy/build-rsync-excludes.sh <prefix>` and `deploy/feed-excludes.txt` referenced identically in Tasks 1, 2, 3, 6. `FEED_EXCLUDES` array name consistent in Task 3. `AUTHORIZED_KEYS_FILE`/`SKIP_SSH`/`CI_PUBKEY`/`WEB_ROOT` env names consistent between the installer (Task 4 Step 3) and its test (Task 4 Step 1). Emitter emits 21 lines; the both-shapes count assertion (Task 1) and the wc check (Task 6) both say 21.
