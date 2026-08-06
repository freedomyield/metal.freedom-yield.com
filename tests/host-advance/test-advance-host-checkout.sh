#!/usr/bin/env bash
# test-advance-host-checkout.sh — suite for scripts/advance-host-checkout.sh.
#
# CHAIN: none — builds throwaway local git repo pairs (origin + clone) in a
#        tempdir; no network, no real ntfy (notifier is a recording stub),
#        no real validator host, no broadcast-capable commands invoked.
#
# Usage:
#   bash tests/host-advance/test-advance-host-checkout.sh
#
# Exit codes:
#   0  all cases PASS
#   1  any case FAILED

set -u

# Hermeticity: force a resolvable git commit identity for every git command
# this suite runs, regardless of the ambient environment. GIT_AUTHOR_NAME /
# GIT_COMMITTER_NAME environment variables — if merely *set*, even to an
# empty string — take precedence over ALL config sources (system, global,
# local repo config, and the per-invocation `-c user.name=...` this suite
# already uses via GITQ alike). A CI runner with no global git identity and
# an empty GECOS name derives an empty name and `git commit` dies with
# "empty ident name ... not allowed"; GITQ's `-c user.name=` does NOT help
# in that case, because an explicitly-empty env var already won. Exporting
# non-empty values here is the one thing that actually wins in every
# environment (see scripts/operator-local/test-commit-anchor-source.sh for
# the case where this was first found to matter). Values are obviously fake
# test fixtures (.invalid is the RFC 2606 reserved-for-testing TLD) — never
# a real operator name/email.
export GIT_AUTHOR_NAME="FYD Hermetic Test Suite"
export GIT_AUTHOR_EMAIL="fyd-hermetic-test@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADVANCER="${REPO_ROOT}/scripts/advance-host-checkout.sh"

if [ ! -f "$ADVANCER" ]; then
	echo "FATAL: advancer not found at $ADVANCER" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# ---- harness -----------------------------------------------------------------
# build_pair: bare origin with one commit (scripts/ + public/ + docs/ content)
# + clone, mirroring tests/host-drift/test-check-host-drift.sh's fixture style.
BASE=""; ORIGIN=""; CLONE=""; STUB=""; STUB_LOG=""
GITQ=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)
build_pair() {
	BASE="$(mktemp -d -t host-advance-test.XXXXXX)"
	ORIGIN="$BASE/origin.git"
	CLONE="$BASE/clone"
	STUB="$BASE/notify-stub.sh"
	STUB_LOG="$BASE/notify.log"

	local seed="$BASE/seed"
	mkdir -p "$seed/scripts" "$seed/public/api" "$seed/docs"
	echo 'echo hello' > "$seed/scripts/a.sh"
	echo '<html>' > "$seed/public/index.html"
	echo '# doc' > "$seed/docs/README.md"
	# Minimal anchor-source.json seed. advance-host-checkout.sh never parses
	# this file's JSON — it only ever compares raw bytes — so a schema-valid
	# shape is unnecessary here; the content only needs to be distinguishable
	# across cycle numbers for the anchor-source-specific cases below.
	printf '{"cycle":1,"dag_root_computed":"seed0000"}\n' > "$seed/public/api/anchor-source.json"
	git -C "$seed" "${GITQ[@]}" init -q -b main
	git -C "$seed" "${GITQ[@]}" add -A
	git -C "$seed" "${GITQ[@]}" commit -qm seed

	git clone -q --bare "$seed" "$ORIGIN"
	git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
	git -C "$CLONE" "${GITQ[@]}" remote set-url origin "$ORIGIN"

	cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$STUB_LOG"
STUBEOF
	chmod +x "$STUB"
}
teardown() { rm -rf "$BASE"; BASE=""; }

run_advancer() {
	FYD_REPO_DIR="$CLONE" FYD_NOTIFY="$STUB" bash "$ADVANCER" "$@"
}
alerts() { cat "$STUB_LOG" 2>/dev/null; }

# push N commits to origin only (via a scratch clone), optionally touching a
# given file with given content per commit.
push_origin_commits() {
	# push_origin_commits <n> [file] [line-prefix]
	local n="$1" file="${2:-docs/README.md}" prefix="${3:-origin-change}"
	local scratch="$BASE/scratch-$$-$RANDOM"
	git clone -q "$ORIGIN" "$scratch" 2>/dev/null
	mkdir -p "$scratch/$(dirname "$file")"
	for i in $(seq 1 "$n"); do
		echo "${prefix} ${i}" >> "$scratch/$file"
		git -C "$scratch" "${GITQ[@]}" commit -qam "${prefix}-${i}"
	done
	git -C "$scratch" push -q origin main
	rm -rf "$scratch"
}

# push a single origin-only commit that OVERWRITES public/api/anchor-
# source.json with exact given bytes (unlike push_origin_commits, which
# only appends lines) — simulates a Mac-side commit-anchor-source.sh commit
# landing on origin while the host clone is behind and/or dirty at that
# same path. Uses printf '%s' (no added trailing newline) so callers can
# byte-match this against locally-written dirt exactly via cmp.
push_origin_anchor_source_commit() {
	local content="$1"
	local scratch="$BASE/scratch-anchor-$$-$RANDOM"
	git clone -q "$ORIGIN" "$scratch" 2>/dev/null
	printf '%s' "$content" > "$scratch/public/api/anchor-source.json"
	git -C "$scratch" "${GITQ[@]}" commit -qam "anchor-source: mac-side commit"
	git -C "$scratch" push -q origin main
	rm -rf "$scratch"
}

# ---- case 1: ahead>0 → refuses, no changes, alert fired, exit 1 ----------------
build_pair
echo 'echo edited-on-host' > "$CLONE/scripts/a.sh"
git -C "$CLONE" "${GITQ[@]}" commit -qam host-local-edit
SNAP_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
SNAP_A="$(cat "$CLONE/scripts/a.sh")"
OUT="$(run_advancer 2>&1)"
RC=$?
[ "$RC" -eq 1 ] \
	&& ok "ahead: exit 1" \
	|| bad "ahead: exit 1 (actual=$RC)"
[ "$(git -C "$CLONE" rev-parse HEAD)" = "$SNAP_HEAD" ] \
	&& ok "ahead: HEAD unchanged" \
	|| bad "ahead: HEAD unchanged"
[ "$(cat "$CLONE/scripts/a.sh")" = "$SNAP_A" ] \
	&& ok "ahead: working tree unchanged" \
	|| bad "ahead: working tree unchanged"
alerts | grep -q '^high|host-advance: refused (host has local commits)|.*ahead=1' \
	&& ok "ahead: high alert with ahead=1" \
	|| bad "ahead: high alert with ahead=1 (alerts: $(alerts))"
teardown

# ---- case 2: behind>0, clean tree → advances to origin/main, exit 0 -----------
build_pair
push_origin_commits 2
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "behind-clean: exit 0" \
	|| bad "behind-clean: exit 0 (actual=$RC, out=$OUT)"
NEW_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$ORIGIN" rev-parse main)"
[ "$NEW_HEAD" = "$ORIGIN_HEAD" ] \
	&& ok "behind-clean: HEAD advanced to origin/main" \
	|| bad "behind-clean: HEAD advanced to origin/main"
echo "$OUT" | grep -q 'advanced' \
	&& ok "behind-clean: advanced log line" \
	|| bad "behind-clean: advanced log line (out: $OUT)"
[ -s "$STUB_LOG" ] \
	&& bad "behind-clean: no alert fired" \
	|| ok "behind-clean: no alert fired"
teardown

# ---- case 3: behind>0, dirty public/ (cache-bust) → discards public/, advances, exit 0
build_pair
push_origin_commits 2
echo '<html>?v=stamped-cachebust</html>' > "$CLONE/public/index.html"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "behind-dirty-public: exit 0" \
	|| bad "behind-dirty-public: exit 0 (actual=$RC, out=$OUT)"
NEW_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$ORIGIN" rev-parse main)"
[ "$NEW_HEAD" = "$ORIGIN_HEAD" ] \
	&& ok "behind-dirty-public: HEAD advanced to origin/main" \
	|| bad "behind-dirty-public: HEAD advanced to origin/main"
[ "$(git -C "$CLONE" status --porcelain -- public/)" = "" ] \
	&& ok "behind-dirty-public: public/ cache-bust dirt discarded, tree clean" \
	|| bad "behind-dirty-public: public/ cache-bust dirt discarded (status: $(git -C "$CLONE" status --porcelain -- public/))"
teardown

# ---- case 4: behind>0, dirty tracked file OUTSIDE public/ → only public/ discard-eligible;
#      non-public edit is never silently discarded (pull proceeds if untouched by
#      the incoming diff, or fails loudly while preserving the edit otherwise).
#      This case exercises the "fails loudly, no data loss" branch by making the
#      incoming origin commit touch the SAME file that is dirty locally.
build_pair
push_origin_commits 1 "docs/README.md" "origin-change"
echo 'local hand-edit, never committed' >> "$CLONE/docs/README.md"
DIRTY_CONTENT="$(cat "$CLONE/docs/README.md")"
HEAD_BEFORE="$(git -C "$CLONE" rev-parse HEAD)"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 1 ] \
	&& ok "behind-dirty-nonpublic: exit 1 (pull refuses to clobber)" \
	|| bad "behind-dirty-nonpublic: exit 1 (actual=$RC, out=$OUT)"
[ "$(cat "$CLONE/docs/README.md")" = "$DIRTY_CONTENT" ] \
	&& ok "behind-dirty-nonpublic: non-public edit NOT discarded (no data loss)" \
	|| bad "behind-dirty-nonpublic: non-public edit NOT discarded (no data loss)"
[ "$(git -C "$CLONE" rev-parse HEAD)" = "$HEAD_BEFORE" ] \
	&& ok "behind-dirty-nonpublic: HEAD did not move (pull did not partially apply)" \
	|| bad "behind-dirty-nonpublic: HEAD did not move"
alerts | grep -q '^high|host-advance: ff-only pull failed' \
	&& ok "behind-dirty-nonpublic: high alert on pull failure" \
	|| bad "behind-dirty-nonpublic: high alert on pull failure (alerts: $(alerts))"
teardown

# ---- case 5: fetch failure → alert default, exit 2 ------------------------------
build_pair
rm -rf "$ORIGIN"
run_advancer >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "fetch-fail: exit 2" \
	|| bad "fetch-fail: exit 2 (actual=$RC)"
alerts | grep -q '^default|host-advance: fetch failed' \
	&& ok "fetch-fail: default-priority alert" \
	|| bad "fetch-fail: default-priority alert (alerts: $(alerts))"
teardown

# ---- case 6: in-sync → exit 0, no alert ------------------------------------------
build_pair
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "in-sync: exit 0" \
	|| bad "in-sync: exit 0 (actual=$RC, out=$OUT)"
echo "$OUT" | grep -qi 'sync' \
	&& ok "in-sync: healthy log line" \
	|| bad "in-sync: healthy log line (out: $OUT)"
[ -s "$STUB_LOG" ] \
	&& bad "in-sync: no alert fired" \
	|| ok "in-sync: no alert fired"
teardown

# ---- bonus: not a git dir → exit 2, no crash (defensive; mirrors check-host-drift) -
build_pair
NOTDIR="$BASE/plain"; mkdir -p "$NOTDIR"
FYD_REPO_DIR="$NOTDIR" FYD_NOTIFY="$STUB" bash "$ADVANCER" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] \
	&& ok "non-git dir: exit 2" \
	|| bad "non-git dir: exit 2 (actual=$RC)"
teardown

# ---- case 7: self-heal — tracked file modified but byte-identical to
#      origin/main (the rsync-clobber signature) is absorbed and the pull
#      succeeds. ------------------------------------------------------------
build_pair
push_origin_commits 1 "docs/README.md" "origin-change"
git -C "$ORIGIN" show main:docs/README.md > "$CLONE/docs/README.md"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "self-heal-tracked: exit 0" \
	|| bad "self-heal-tracked: exit 0 (actual=$RC, out=$OUT)"
NEW_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$ORIGIN" rev-parse main)"
[ "$NEW_HEAD" = "$ORIGIN_HEAD" ] \
	&& ok "self-heal-tracked: HEAD advanced to origin/main" \
	|| bad "self-heal-tracked: HEAD advanced to origin/main"
[ "$(git -C "$CLONE" status --porcelain)" = "" ] \
	&& ok "self-heal-tracked: working tree clean" \
	|| bad "self-heal-tracked: working tree clean (status: $(git -C "$CLONE" status --porcelain))"
alerts | grep -q 'self-healed' \
	&& ok "self-heal-tracked: notify log mentions self-healed" \
	|| bad "self-heal-tracked: notify log mentions self-healed (alerts: $(alerts))"
teardown

# ---- case 8: self-heal — untracked file identical to an incoming NEW
#      tracked file is absorbed (removed, then re-created clean by the
#      pull). push_origin_commits relies on `commit -am`, which does not
#      stage a brand-new path, so a new tracked file is added inline here
#      instead (explicit `git add`). ------------------------------------
build_pair
NEWFILE_SCRATCH="$BASE/scratch-newfile"
git clone -q "$ORIGIN" "$NEWFILE_SCRATCH" 2>/dev/null
mkdir -p "$NEWFILE_SCRATCH/scripts"
printf 'echo new-tool\n' > "$NEWFILE_SCRATCH/scripts/new-tool.sh"
git -C "$NEWFILE_SCRATCH" "${GITQ[@]}" add scripts/new-tool.sh
git -C "$NEWFILE_SCRATCH" "${GITQ[@]}" commit -qm add-new-tool
git -C "$NEWFILE_SCRATCH" push -q origin main
rm -rf "$NEWFILE_SCRATCH"
git -C "$ORIGIN" show main:scripts/new-tool.sh > "$CLONE/scripts/new-tool.sh"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "self-heal-untracked: exit 0" \
	|| bad "self-heal-untracked: exit 0 (actual=$RC, out=$OUT)"
git -C "$CLONE" ls-files --error-unmatch scripts/new-tool.sh >/dev/null 2>&1 \
	&& ok "self-heal-untracked: file now tracked" \
	|| bad "self-heal-untracked: file now tracked"
[ "$(git -C "$CLONE" status --porcelain -- scripts/new-tool.sh)" = "" ] \
	&& ok "self-heal-untracked: file clean afterwards" \
	|| bad "self-heal-untracked: file clean afterwards (status: $(git -C "$CLONE" status --porcelain -- scripts/new-tool.sh))"
alerts | grep -q 'self-healed' \
	&& ok "self-heal-untracked: notify log mentions self-healed" \
	|| bad "self-heal-untracked: notify log mentions self-healed (alerts: $(alerts))"
teardown

# ---- case 9: refusal preserved — tracked file modified with REAL
#      divergence from origin/main must NOT be self-healed; the pull still
#      refuses loudly and nothing is destroyed. -----------------------------
build_pair
push_origin_commits 1 "docs/README.md" "origin-change"
echo 'genuinely different local content, never seen by origin' > "$CLONE/docs/README.md"
DIVERGENT_CONTENT="$(cat "$CLONE/docs/README.md")"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 1 ] \
	&& ok "self-heal-real-divergence: exit 1 (pull refuses)" \
	|| bad "self-heal-real-divergence: exit 1 (actual=$RC, out=$OUT)"
alerts | grep -q '^high|host-advance: ff-only pull failed' \
	&& ok "self-heal-real-divergence: ff-only pull failed alert" \
	|| bad "self-heal-real-divergence: ff-only pull failed alert (alerts: $(alerts))"
[ "$(cat "$CLONE/docs/README.md")" = "$DIVERGENT_CONTENT" ] \
	&& ok "self-heal-real-divergence: divergent content preserved (no data loss)" \
	|| bad "self-heal-real-divergence: divergent content preserved (no data loss)"
teardown

# ---- case 10: staged change is NOT touched by self_heal_lossless_dirt even
#      when byte-identical to origin/main — only worktree-only dirt (status
#      " M ", not staged "M  ") is self-heal-eligible. Verified empirically
#      (two independent clean repros outside this suite) that git's own
#      `pull --ff-only` already resolves a staged change that is
#      byte-identical to the incoming commit as a trivial fast-forward
#      (exit 0, no conflict) — this is native git behavior, not something
#      self_heal_lossless_dirt does or needs to do. What this case actually
#      guards is the case-pattern boundary: if the " M "/"?? " matching ever
#      widened to catch staged "M  " entries too, self_heal_lossless_dirt
#      would run `git checkout -- path` against a staged file and/or fire a
#      spurious "self-healed" alert for something it never touched — this
#      case fails loudly if that regression is introduced. -----------------
build_pair
push_origin_commits 1 "docs/README.md" "origin-change"
git -C "$ORIGIN" show main:docs/README.md > "$CLONE/docs/README.md"
git -C "$CLONE" "${GITQ[@]}" add docs/README.md
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "self-heal-staged-not-healed: exit 0 (git's own ff-only resolves it, untouched by self-heal)" \
	|| bad "self-heal-staged-not-healed: exit 0 (actual=$RC, out=$OUT)"
NEW_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$ORIGIN" rev-parse main)"
[ "$NEW_HEAD" = "$ORIGIN_HEAD" ] \
	&& ok "self-heal-staged-not-healed: HEAD advanced to origin/main" \
	|| bad "self-heal-staged-not-healed: HEAD advanced to origin/main"
alerts | grep -q 'self-healed' \
	&& bad "self-heal-staged-not-healed: no self-healed alert (staged entry must not be claimed as healed) (alerts: $(alerts))" \
	|| ok "self-heal-staged-not-healed: no self-healed alert (staged entry must not be claimed as healed)"
teardown

# ---- case 11: self-heal mutating op fails → fail LOUDLY (exit 1 + high
#      alert), never a silent set -e hard-exit. Simulated by making the heal
#      target's parent directory read-only: `git checkout -- path` then
#      cannot unlink/recreate the file ("unable to unlink old ...:
#      Permission denied") — the permissions/read-only-fs failure class the
#      guard exists for. -----------------------------------------------------
build_pair
push_origin_commits 1 "docs/README.md" "origin-change"
git -C "$ORIGIN" show main:docs/README.md > "$CLONE/docs/README.md"
chmod -w "$CLONE/docs"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
chmod +w "$CLONE/docs"
[ "$RC" -eq 1 ] \
	&& ok "self-heal-op-fails: exit 1 (loud failure, not silent set -e exit)" \
	|| bad "self-heal-op-fails: exit 1 (actual=$RC, out=$OUT)"
alerts | grep -q '^high|host-advance: self-heal revert failed' \
	&& ok "self-heal-op-fails: high alert on revert failure" \
	|| bad "self-heal-op-fails: high alert on revert failure (alerts: $(alerts))"
teardown

# ---- case 13 (plan A4 / brief item a; revised fix-round-1 per C1/I5,
#      severity revised again in fix round 2): anchor-source.json host
#      dirt that DIFFERS from HEAD is durably preserved to
#      .anchor-source-preserve/ (never silently discarded by the blanket
#      public/ checkout) — capture itself is only `log`ged (I5), not
#      alerted — and since the incoming pull does not touch this path at
#      all (origin only advances an unrelated file), the resolution fires
#      `alert default` naming the durable path (fix round 2: this
#      untouched/still-pending state is EXPECTED mid-flow behavior on a
#      transition day, not an anomaly, so it must not page high), and the
#      scratch snapshot is restored on top in-place: still pending its
#      own commit-anchor-source.sh run, nothing lost either copy. --------
build_pair
ANCHOR_ABS="$CLONE/public/api/anchor-source.json"
LOCAL_DIRT="$(printf '{"cycle":2,"dag_root_computed":"hostdirt-untouched"}')"
printf '%s' "$LOCAL_DIRT" > "$ANCHOR_ABS"
push_origin_commits 1 "docs/README.md" "origin-change"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "anchor-preserve-untouched: exit 0" \
	|| bad "anchor-preserve-untouched: exit 0 (actual=$RC, out=$OUT)"
NEW_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$ORIGIN" rev-parse main)"
[ "$NEW_HEAD" = "$ORIGIN_HEAD" ] \
	&& ok "anchor-preserve-untouched: HEAD advanced to origin/main" \
	|| bad "anchor-preserve-untouched: HEAD advanced to origin/main"
alerts | grep -q '^default|host-advance: anchor-source.json pending commit|' \
	&& ok "anchor-preserve-untouched: default-priority alert at resolution (expected mid-flow state, not paged high)" \
	|| bad "anchor-preserve-untouched: default-priority alert at resolution (alerts: $(alerts))"
alerts | grep -q '^high|host-advance: anchor-source.json pending commit|' \
	&& bad "anchor-preserve-untouched: must NOT be high priority (alerts: $(alerts))" \
	|| ok "anchor-preserve-untouched: not high priority"
DURABLE_FILE="$(find "$CLONE/.anchor-source-preserve" -maxdepth 1 -type f -name 'anchor-source.json.host-*' 2>/dev/null | head -1)"
[ -n "$DURABLE_FILE" ] \
	&& ok "anchor-preserve-untouched: durable copy created in .anchor-source-preserve/" \
	|| bad "anchor-preserve-untouched: durable copy created in .anchor-source-preserve/"
[ -n "$DURABLE_FILE" ] && [ "$(cat "$DURABLE_FILE")" = "$LOCAL_DIRT" ] \
	&& ok "anchor-preserve-untouched: durable copy holds the host dirt" \
	|| bad "anchor-preserve-untouched: durable copy holds the host dirt"
alerts | grep -q "$DURABLE_FILE" \
	&& ok "anchor-preserve-untouched: alert names the durable path" \
	|| bad "anchor-preserve-untouched: alert names the durable path (alerts: $(alerts))"
[ "$(cat "$ANCHOR_ABS")" = "$LOCAL_DIRT" ] \
	&& ok "anchor-preserve-untouched: in-place convenience copy restored after pull (nothing lost)" \
	|| bad "anchor-preserve-untouched: in-place convenience copy restored after pull (got: $(cat "$ANCHOR_ABS"))"
[ -n "$(git -C "$CLONE" status --porcelain -- public/api/anchor-source.json)" ] \
	&& ok "anchor-preserve-untouched: path still shows as dirty (still pending its own commit)" \
	|| bad "anchor-preserve-untouched: path still shows as dirty"
teardown

# ---- case 14 (plan A4 / brief item b): anchor-source.json worktree copy
#      that is byte-identical to HEAD is ordinary discard territory —
#      no capture, no anchor-specific alert, and the routine public/
#      cache-bust dirt elsewhere still gets discarded normally. -----------
build_pair
ANCHOR_ABS="$CLONE/public/api/anchor-source.json"
SEED_ANCHOR_SNAPSHOT="$BASE/anchor-seed-snapshot.json"
cp "$ANCHOR_ABS" "$SEED_ANCHOR_SNAPSHOT"
push_origin_commits 1 "docs/README.md" "origin-change"
# Rewrite the file with IDENTICAL bytes (simulates gen-anchor-source.sh
# having re-run and produced byte-identical output) + dirty an unrelated
# public/ file the ordinary way (cache-bust marker). `cp`, not a `$(cat)`
# command substitution, preserves the seed's exact trailing newline —
# capturing through a subshell would silently strip it and make this
# "identical" rewrite NOT byte-identical after all (caught empirically:
# the first version of this case falsely triggered anchor-source dirt
# capture for exactly this reason).
cp "$SEED_ANCHOR_SNAPSHOT" "$ANCHOR_ABS"
echo '<html>?v=stamped-cachebust</html>' > "$CLONE/public/index.html"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "anchor-byte-identical: exit 0" \
	|| bad "anchor-byte-identical: exit 0 (actual=$RC, out=$OUT)"
NEW_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$ORIGIN" rev-parse main)"
[ "$NEW_HEAD" = "$ORIGIN_HEAD" ] \
	&& ok "anchor-byte-identical: HEAD advanced to origin/main" \
	|| bad "anchor-byte-identical: HEAD advanced to origin/main"
alerts | grep -qi 'anchor-source' \
	&& bad "anchor-byte-identical: no anchor-specific alert fired (alerts: $(alerts))" \
	|| ok "anchor-byte-identical: no anchor-specific alert fired"
[ "$(git -C "$CLONE" status --porcelain -- public/)" = "" ] \
	&& ok "anchor-byte-identical: public/ tree clean (cache-bust dirt discarded as usual)" \
	|| bad "anchor-byte-identical: public/ tree clean (status: $(git -C "$CLONE" status --porcelain -- public/))"
[ ! -d "$CLONE/.anchor-source-preserve" ] \
	&& ok "anchor-byte-identical: no durable preserve dir created (no real dirt existed)" \
	|| bad "anchor-byte-identical: no durable preserve dir created (found: $(ls "$CLONE/.anchor-source-preserve" 2>/dev/null))"
teardown

# ---- case 15 (plan A4 / brief item c): incoming pull DOES touch
#      anchor-source.json (a Mac-side commit-anchor-source.sh commit
#      arrived via origin) and its content is byte-identical to the
#      preserved host dirt -> self-heal: default-priority alert, dirt
#      discarded (redundant), nothing lost, no stash file created. --------
build_pair
ANCHOR_ABS="$CLONE/public/api/anchor-source.json"
DIRT_CONTENT="$(printf '{"cycle":2,"dag_root_computed":"hostdirt-matches-incoming"}')"
printf '%s' "$DIRT_CONTENT" > "$ANCHOR_ABS"
push_origin_anchor_source_commit "$DIRT_CONTENT"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "anchor-self-heal-match: exit 0" \
	|| bad "anchor-self-heal-match: exit 0 (actual=$RC, out=$OUT)"
NEW_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$ORIGIN" rev-parse main)"
[ "$NEW_HEAD" = "$ORIGIN_HEAD" ] \
	&& ok "anchor-self-heal-match: HEAD advanced to origin/main" \
	|| bad "anchor-self-heal-match: HEAD advanced to origin/main"
alerts | grep -q '^default|host-advance: self-healed anchor-source.json|' \
	&& ok "anchor-self-heal-match: default-priority self-healed alert" \
	|| bad "anchor-self-heal-match: default-priority self-healed alert (alerts: $(alerts))"
alerts | grep -qi 'stashed' \
	&& bad "anchor-self-heal-match: no stash alert fired (alerts: $(alerts))" \
	|| ok "anchor-self-heal-match: no stash alert fired"
[ "$(cat "$ANCHOR_ABS")" = "$DIRT_CONTENT" ] \
	&& ok "anchor-self-heal-match: working file holds the (now-shared) content" \
	|| bad "anchor-self-heal-match: working file holds the (now-shared) content"
[ "$(git -C "$CLONE" status --porcelain -- public/api/anchor-source.json)" = "" ] \
	&& ok "anchor-self-heal-match: path clean afterwards" \
	|| bad "anchor-self-heal-match: path clean afterwards"
NUM_STASH_FILES=$(find "$CLONE/public/api" -maxdepth 1 -name 'anchor-source.json.host-*' | wc -l | tr -d ' ')
[ "$NUM_STASH_FILES" -eq 0 ] \
	&& ok "anchor-self-heal-match: no in-place stash file created" \
	|| bad "anchor-self-heal-match: no in-place stash file created (found: $NUM_STASH_FILES)"
DURABLE_FILE="$(find "$CLONE/.anchor-source-preserve" -maxdepth 1 -type f -name 'anchor-source.json.host-*' 2>/dev/null | head -1)"
[ -n "$DURABLE_FILE" ] && [ "$(cat "$DURABLE_FILE")" = "$DIRT_CONTENT" ] \
	&& ok "anchor-self-heal-match: durable copy from capture time still retained (never auto-deleted)" \
	|| bad "anchor-self-heal-match: durable copy from capture time still retained"
teardown

# ---- case 16 (plan A4 / brief item d): incoming pull touches anchor-
#      source.json with content that DIFFERS from the preserved host
#      dirt -> origin wins on the canonical path, but the host dirt is
#      stashed to a `.host-<UTC timestamp>` sibling (alert high) rather
#      than discarded. ------------------------------------------------------
build_pair
ANCHOR_ABS="$CLONE/public/api/anchor-source.json"
LOCAL_DIRT="$(printf '{"cycle":2,"dag_root_computed":"hostdirt-LOCAL-divergent"}')"
REMOTE_CONTENT="$(printf '{"cycle":2,"dag_root_computed":"maccommit-DIFFERENT"}')"
printf '%s' "$LOCAL_DIRT" > "$ANCHOR_ABS"
push_origin_anchor_source_commit "$REMOTE_CONTENT"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "anchor-stash-diverged: exit 0" \
	|| bad "anchor-stash-diverged: exit 0 (actual=$RC, out=$OUT)"
NEW_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$ORIGIN" rev-parse main)"
[ "$NEW_HEAD" = "$ORIGIN_HEAD" ] \
	&& ok "anchor-stash-diverged: HEAD advanced to origin/main" \
	|| bad "anchor-stash-diverged: HEAD advanced to origin/main"
alerts | grep -q '^high|host-advance: anchor-source.json host dirt stashed|' \
	&& ok "anchor-stash-diverged: high alert on stash" \
	|| bad "anchor-stash-diverged: high alert on stash (alerts: $(alerts))"
[ "$(cat "$ANCHOR_ABS")" = "$REMOTE_CONTENT" ] \
	&& ok "anchor-stash-diverged: origin content wins on the canonical path" \
	|| bad "anchor-stash-diverged: origin content wins on the canonical path (got: $(cat "$ANCHOR_ABS"))"
STASH_FILE="$(find "$CLONE/public/api" -maxdepth 1 -name 'anchor-source.json.host-*' | head -1)"
[ -n "$STASH_FILE" ] \
	&& ok "anchor-stash-diverged: in-place convenience stash file created" \
	|| bad "anchor-stash-diverged: in-place convenience stash file created"
[ -n "$STASH_FILE" ] && [ "$(cat "$STASH_FILE")" = "$LOCAL_DIRT" ] \
	&& ok "anchor-stash-diverged: in-place stash file holds the diverged host dirt (nothing lost)" \
	|| bad "anchor-stash-diverged: in-place stash file holds the diverged host dirt (got: $([ -n "$STASH_FILE" ] && cat "$STASH_FILE"))"
DURABLE_FILE="$(find "$CLONE/.anchor-source-preserve" -maxdepth 1 -type f -name 'anchor-source.json.host-*' 2>/dev/null | head -1)"
[ -n "$DURABLE_FILE" ] \
	&& ok "anchor-stash-diverged: durable copy exists in .anchor-source-preserve/" \
	|| bad "anchor-stash-diverged: durable copy exists in .anchor-source-preserve/"
[ -n "$DURABLE_FILE" ] && [ "$(cat "$DURABLE_FILE")" = "$LOCAL_DIRT" ] \
	&& ok "anchor-stash-diverged: durable copy holds the diverged host dirt" \
	|| bad "anchor-stash-diverged: durable copy holds the diverged host dirt"
[ -n "$DURABLE_FILE" ] && alerts | grep -q "$DURABLE_FILE" \
	&& ok "anchor-stash-diverged: alert names the durable path as authoritative" \
	|| bad "anchor-stash-diverged: alert names the durable path as authoritative (alerts: $(alerts))"
teardown

# ---- case 17 (bonus — safety-net trap; revised fix-round-1 per C1/I5):
#      anchor-source.json dirt is captured (durable copy written, capture
#      only `log`s per I5 — no alert fires yet), but the FF pull itself
#      fails for an UNRELATED reason (a different tracked file has real,
#      non-absorbable divergence — same shape as case 4/9).
#      resolve_anchor_source_post_pull is never reached in this branch, so
#      the EXIT-trap safety net (restore_anchor_dirt_on_exit) must be what
#      restores the in-place convenience copy — verifying the trap covers
#      exit paths beyond the ones the brief enumerates explicitly — while
#      the durable copy (written at capture, untouched by the trap)
#      persists throughout. -----------------------------------------------
build_pair
ANCHOR_ABS="$CLONE/public/api/anchor-source.json"
LOCAL_DIRT="$(printf '{"cycle":2,"dag_root_computed":"hostdirt-safetynet"}')"
printf '%s' "$LOCAL_DIRT" > "$ANCHOR_ABS"
push_origin_commits 1 "docs/README.md" "origin-change"
echo 'genuinely different local content, never seen by origin' > "$CLONE/docs/README.md"
HEAD_BEFORE="$(git -C "$CLONE" rev-parse HEAD)"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 1 ] \
	&& ok "anchor-safety-net: exit 1 (unrelated pull failure)" \
	|| bad "anchor-safety-net: exit 1 (actual=$RC, out=$OUT)"
[ "$(git -C "$CLONE" rev-parse HEAD)" = "$HEAD_BEFORE" ] \
	&& ok "anchor-safety-net: HEAD did not move" \
	|| bad "anchor-safety-net: HEAD did not move"
DURABLE_FILE="$(find "$CLONE/.anchor-source-preserve" -maxdepth 1 -type f -name 'anchor-source.json.host-*' 2>/dev/null | head -1)"
[ -n "$DURABLE_FILE" ] && [ "$(cat "$DURABLE_FILE")" = "$LOCAL_DIRT" ] \
	&& ok "anchor-safety-net: durable copy written at capture time, unaffected by the later pull failure" \
	|| bad "anchor-safety-net: durable copy written at capture time"
alerts | grep -q '^high|host-advance: ff-only pull failed|' \
	&& ok "anchor-safety-net: high alert on pull failure" \
	|| bad "anchor-safety-net: high alert on pull failure (alerts: $(alerts))"
alerts | grep -qiE 'self-healed anchor-source|host dirt stashed|anchor-source.json pending commit|restore failed' \
	&& bad "anchor-safety-net: resolve_anchor_source_post_pull never ran, and the trap's own restore succeeded silently (alerts: $(alerts))" \
	|| ok "anchor-safety-net: resolve_anchor_source_post_pull never ran, and the trap's own restore succeeded silently (no anchor-resolution alert)"
[ "$(cat "$ANCHOR_ABS")" = "$LOCAL_DIRT" ] \
	&& ok "anchor-safety-net: in-place convenience copy restored by the EXIT trap (nothing lost)" \
	|| bad "anchor-safety-net: in-place convenience copy restored by the EXIT trap (got: $(cat "$ANCHOR_ABS"))"
teardown

# ---- case 18 (C1 fix, reviewer-requested): the durable preserve dir
#      survives a simulated public/-only rsync --delete — exactly
#      deploy.yml's "Rsync public/ to VPS" step, which runs moments after
#      this script exits in the same CI job. This is the vulnerability C1
#      exists to close: anything left only INSIDE public/ (an in-place
#      convenience stash) is destroyed by that rsync, while the durable
#      copy at .anchor-source-preserve/ (outside public/ entirely) is not
#      — confirmed here structurally, not just by reasoning. -------------
build_pair
ANCHOR_ABS="$CLONE/public/api/anchor-source.json"
# Snapshot a clean "runner build" of public/ (no host artifacts) BEFORE the
# advancer runs — this is what deploy.yml's rsync source actually looks
# like (the runner's own checkout, never touched by anything host-side).
RSYNC_SRC="$BASE/runner-public-build"
cp -r "$CLONE/public" "$RSYNC_SRC"
LOCAL_DIRT="$(printf '{"cycle":2,"dag_root_computed":"hostdirt-rsync-survival"}')"
REMOTE_CONTENT="$(printf '{"cycle":2,"dag_root_computed":"maccommit-rsync-survival"}')"
printf '%s' "$LOCAL_DIRT" > "$ANCHOR_ABS"
push_origin_anchor_source_commit "$REMOTE_CONTENT"
run_advancer >/tmp/.adv-out-$$.log 2>&1
RC=$?
OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
[ "$RC" -eq 0 ] \
	&& ok "rsync-survival: advancer exit 0" \
	|| bad "rsync-survival: advancer exit 0 (actual=$RC, out=$OUT)"
DURABLE_FILE="$(find "$CLONE/.anchor-source-preserve" -maxdepth 1 -type f -name 'anchor-source.json.host-*' 2>/dev/null | head -1)"
[ -n "$DURABLE_FILE" ] \
	&& ok "rsync-survival: durable copy exists before the simulated rsync" \
	|| bad "rsync-survival: durable copy exists before the simulated rsync"
INPLACE_STASH="$(find "$CLONE/public/api" -maxdepth 1 -name 'anchor-source.json.host-*' 2>/dev/null | head -1)"
[ -n "$INPLACE_STASH" ] \
	&& ok "rsync-survival: in-place convenience stash exists before the simulated rsync" \
	|| bad "rsync-survival: in-place convenience stash exists before the simulated rsync"

# Simulate deploy.yml's "Rsync public/ to VPS" step: rsync -a --delete
# from the runner's clean build onto the host's public/ tree.
rsync -a --delete "${RSYNC_SRC}/" "${CLONE}/public/" >/dev/null 2>&1

[ -n "$DURABLE_FILE" ] && [ -f "$DURABLE_FILE" ] && [ "$(cat "$DURABLE_FILE")" = "$LOCAL_DIRT" ] \
	&& ok "rsync-survival: durable copy SURVIVES the simulated public/ rsync --delete" \
	|| bad "rsync-survival: durable copy survives (missing, or content changed, after rsync)"
[ -n "$INPLACE_STASH" ] && [ ! -f "$INPLACE_STASH" ] \
	&& ok "rsync-survival: in-place convenience stash is destroyed by the rsync (expected — this is exactly why the durable copy exists)" \
	|| bad "rsync-survival: in-place convenience stash unexpectedly survived the rsync (test assumption wrong, or C1 regressed)"
teardown

# ---- case 12: concurrency lock (flock-gated — Linux host/CI only). macOS
#      has no flock, and the script deliberately skips the guard there
#      (same repo convention as tests/anomalies/integration-linux.sh), so
#      these cases SKIP rather than fake the behavior. 12a: a held lock +
#      short FYD_LOCK_TIMEOUT → loud exit 1 with the high "lock timeout"
#      alert, and the repo is NOT advanced. 12b: a briefly-held lock within
#      the timeout → the waiter proceeds normally once released. ----------
if command -v flock >/dev/null 2>&1; then
	# 12a: timeout path
	build_pair
	push_origin_commits 1
	( flock -x 200; sleep 5 ) 200>"$CLONE/.git/fyd-advance.lock" &
	HOLDER=$!
	sleep 0.3
	HEAD_BEFORE="$(git -C "$CLONE" rev-parse HEAD)"
	FYD_LOCK_TIMEOUT=1 run_advancer >/tmp/.adv-out-$$.log 2>&1
	RC=$?
	OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
	[ "$RC" -eq 1 ] \
		&& ok "lock-timeout: exit 1" \
		|| bad "lock-timeout: exit 1 (actual=$RC, out=$OUT)"
	alerts | grep -q '^high|host-advance: lock timeout' \
		&& ok "lock-timeout: high alert fired" \
		|| bad "lock-timeout: high alert fired (alerts: $(alerts))"
	[ "$(git -C "$CLONE" rev-parse HEAD)" = "$HEAD_BEFORE" ] \
		&& ok "lock-timeout: HEAD not advanced while lock held" \
		|| bad "lock-timeout: HEAD not advanced while lock held"
	wait $HOLDER 2>/dev/null
	teardown

	# 12b: wait-then-proceed path
	build_pair
	push_origin_commits 1
	( flock -x 200; sleep 1 ) 200>"$CLONE/.git/fyd-advance.lock" &
	HOLDER=$!
	sleep 0.3
	FYD_LOCK_TIMEOUT=10 run_advancer >/tmp/.adv-out-$$.log 2>&1
	RC=$?
	OUT="$(cat /tmp/.adv-out-$$.log)"; rm -f /tmp/.adv-out-$$.log
	wait $HOLDER 2>/dev/null
	[ "$RC" -eq 0 ] \
		&& ok "lock-wait: exit 0 after lock released within timeout" \
		|| bad "lock-wait: exit 0 after lock released within timeout (actual=$RC, out=$OUT)"
	[ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse main)" ] \
		&& ok "lock-wait: HEAD advanced to origin/main after waiting" \
		|| bad "lock-wait: HEAD advanced to origin/main after waiting"
	teardown
else
	echo "SKIP  case 12 (concurrency lock): flock not available on this host (macOS) — the script skips the guard here by design; covered on Linux CI"
fi

# ---- summary ----------------------------------------------------------------------
echo "test-advance-host-checkout.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
