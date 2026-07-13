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
	mkdir -p "$seed/scripts" "$seed/public" "$seed/docs"
	echo 'echo hello' > "$seed/scripts/a.sh"
	echo '<html>' > "$seed/public/index.html"
	echo '# doc' > "$seed/docs/README.md"
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

# ---- summary ----------------------------------------------------------------------
echo "test-advance-host-checkout.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
