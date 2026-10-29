#!/usr/bin/env bash
# test-pre-push-scan.sh — suite for .githooks/pre-push -> scripts/pre-push-scan.sh
# (every commit being pushed is scanned ONE BY ONE by gitleaks and by
# scripts/publish-guard.sh; anything that cannot be scanned is refused).
#
# CHAIN: none. Every case builds a throwaway repo plus a throwaway BARE repo
#        under $TMPDIR and runs a real `git push` into that bare repo only.
#        Nothing here touches this repo's own git config, hooks or remotes.
#
# SAFETY: no real secret appears in this file. The gitleaks probe is an
# AWS-key-shaped value ASSEMBLED at runtime; the publish-guard probe is a
# throwaway word whose hash is injected through FYD_PUBLISH_WORD_HASHES
# (the same technique as tests/publish-guard/).
#
# MUTANTS: PREPUSH_SRC_ROOT=<dir> makes the suite copy the hook, scanner,
# range lib and publish-guard from <dir> instead of this repo, so a broken
# copy kept outside the repo can be run against the same cases.
#
# Usage:  bash tests/pre-push-scan/test-pre-push-scan.sh
# Exit:   0 all pass / 1 any fail

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${PREPUSH_SRC_ROOT:-$REPO_ROOT}"

for f in .githooks/pre-push scripts/pre-push-scan.sh scripts/lib/push-range.sh scripts/publish-guard.sh .gitleaks.toml; do
	if [ ! -f "$SRC/$f" ]; then
		echo "FATAL: missing $SRC/$f" >&2
		exit 1
	fi
done
if ! command -v gitleaks >/dev/null 2>&1; then
	echo "FATAL: gitleaks not on PATH (needed to run this suite)" >&2
	exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# ---- probes (assembled at runtime) -------------------------------------------
AWS_PROBE="AKIA$(printf '%s' QYLPMN5H)$(printf '%s' HHFPZAM2)"
GUARD_WORD="zzprepushprobezz"
export FYD_PUBLISH_WORD_HASHES
FYD_PUBLISH_WORD_HASHES="$(printf '%s' "$GUARD_WORD" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex(lc $_)')"
export FYD_PUBLISH_CJK_HASHES
FYD_PUBLISH_CJK_HASHES="$(printf '%s' "偽プッシュ標本" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')"
export FYD_PUBLISH_DENYLIST=/dev/null
unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML

# A PATH that has the base system tools but no gitleaks.
NO_GITLEAKS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ---- fixtures ----------------------------------------------------------------
WORK=""
R=""        # the working repo
B=""        # the bare remote
setup() {
	# $1 = "toml" to commit this repo's .gitleaks.toml in the seed commit.
	# The gate files are committed in the seed too: the hook runs the BASE
	# commit's copy of them, never the work tree's.
	WORK="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-scan-test.XXXXXX")"
	B="$WORK/remote.git"
	R="$WORK/repo"
	git init -q --bare "$B"
	git init -q "$R"
	mkdir -p "$WORK/nohooks"
	(
		cd "$R" || exit 1
		git config user.name tester
		git config user.email tester@example.invalid
		git config commit.gpgsign false
		git config core.hooksPath "$WORK/nohooks"
		git symbolic-ref HEAD refs/heads/main
		git remote add origin "$B"
		mkdir -p .githooks scripts/lib
		cp "$SRC/.githooks/pre-push" .githooks/pre-push
		cp "$SRC/scripts/pre-push-scan.sh" scripts/pre-push-scan.sh
		cp "$SRC/scripts/lib/push-range.sh" scripts/lib/push-range.sh
		cp "$SRC/scripts/publish-guard.sh" scripts/publish-guard.sh
		chmod +x .githooks/pre-push scripts/pre-push-scan.sh scripts/publish-guard.sh
		# SEED_TWEAK (optional) runs here to alter the seed's gate files
		if [ -n "${SEED_TWEAK:-}" ]; then eval "$SEED_TWEAK"; fi
		echo seed > README
		git add README
		for f in .githooks/pre-push scripts/pre-push-scan.sh scripts/lib/push-range.sh scripts/publish-guard.sh; do
			if [ -e "$f" ]; then git add "$f"; fi
		done
		if [ "${1:-}" = "toml" ]; then
			cp "$SRC/.gitleaks.toml" .gitleaks.toml
			git add .gitleaks.toml
		fi
		git commit -qm seed
	)
}
publish_seed() {
	# push the seed with NO hooks, then arm the hook under test
	(cd "$R" && git push -q origin main >/dev/null 2>&1 && git config core.hooksPath .githooks)
}
arm() { (cd "$R" && git config core.hooksPath .githooks); }
teardown() { rm -rf "$WORK"; }

commit_file() {
	# commit_file <path> <content> <msg>  -> prints the new commit's short hash
	(cd "$R" && printf '%s\n' "$2" > "$1" && git add "$1" && git commit -qm "$3" && git rev-parse --short HEAD)
}
remove_file() {
	(cd "$R" && git rm -q "$1" && git commit -qm "$2" && git rev-parse --short HEAD)
}
clean_commits() {
	local i
	for i in $(seq 1 "$1"); do commit_file "clean$i.txt" "line $i" "clean $i" >/dev/null; done
}
sha256_of_blob() {
	# sha256_of_blob <commit>:<path>  (inside $R) -> hex, or empty if absent
	(cd "$R" && git cat-file -e "$1" 2>/dev/null && git cat-file blob "$1" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')
}
set_pins() {
	# Test fixture only: give the throwaway repo the values the gate reads
	# when the remote is empty. (Recording them for a real repo is the
	# operator's own step, outside this repo; an AI never does it.)
	local name path v
	for name in gitleaks-toml:.gitleaks.toml pre-push-scan:scripts/pre-push-scan.sh push-range:scripts/lib/push-range.sh publish-guard:scripts/publish-guard.sh pre-push-hook:.githooks/pre-push; do
		path="${name#*:}"
		v="$(sha256_of_blob "HEAD:$path")"
		if [ -n "$v" ]; then (cd "$R" && git config --local "metal.prepush.pin.${name%%:*}" "$v"); fi
	done
	return 0
}
widen_toml_commit() {
	# commit a .gitleaks.toml that path-allowlists secret.txt -> short hash
	(cd "$R" && perl -0pi -e "s/paths = \\[\\n/paths = [\\n  '''secret\\\\.txt''',\\n/" .gitleaks.toml \
		&& git add .gitleaks.toml && git commit -qm "loosen" && git rev-parse --short HEAD)
}

OUT=""
RC=0
do_push() {
	# do_push <args to git push...>; honours PUSH_PATH if set
	OUT="$(cd "$R" && PATH="${PUSH_PATH:-$PATH}" git push "$@" 2>&1)"
	RC=$?
}
remote_sha() { git --git-dir="$B" rev-parse -q --verify "$1" 2>/dev/null || echo none; }

expect_block() {
	# expect_block <label> <needle-in-output> [<second needle>]
	local label="$1"
	if [ "$RC" -eq 0 ]; then
		bad "$label: push must be refused (rc=0)"
		return
	fi
	if ! printf '%s' "$OUT" | grep -qF -- "$2"; then
		bad "$label: refusal must name [$2] (out: $(printf '%s' "$OUT" | tail -5 | tr '\n' '|'))"
		return
	fi
	if [ -n "${3:-}" ] && ! printf '%s' "$OUT" | grep -qF -- "$3"; then
		bad "$label: refusal must name [$3] (out: $(printf '%s' "$OUT" | tail -5 | tr '\n' '|'))"
		return
	fi
	if printf '%s' "$OUT" | grep -qF -- "$AWS_PROBE"; then
		bad "$label: refusal must not print the secret value"
		return
	fi
	ok "$label"
}
expect_pass() {
	if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1: push must succeed (rc=$RC, out: $(printf '%s' "$OUT" | tail -5 | tr '\n' '|'))"; fi
}

# ---- case 1: secret only in a middle commit (removed in the next) ------------
setup toml; publish_seed
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
remove_file secret.txt "remove" >/dev/null
clean_commits 1
before="$(remote_sha refs/heads/main)"
do_push origin main
expect_block "case 1: secret in a middle commit -> refused" "gitleaks found a secret" "$H"
if [ "$(remote_sha refs/heads/main)" = "$before" ]; then ok "case 1: remote ref unchanged"; else bad "case 1: remote ref unchanged"; fi
teardown

# ---- case 1b: publish-guard probe only in a middle commit -------------------
setup toml; publish_seed
H="$(commit_file note.md "host is $GUARD_WORD here" "add")"
remove_file note.md "remove" >/dev/null
do_push origin main
expect_block "case 1b: publish-guard hit in a middle commit -> refused" "publish-guard found a forbidden value" "$H"
teardown

# ---- case 2: new branch, secret in an old ancestor ---------------------------
setup toml; publish_seed
(cd "$R" && git checkout -qb feature)
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
remove_file secret.txt "remove" >/dev/null
clean_commits 3
do_push origin feature
expect_block "case 2: new branch, secret in an old ancestor -> refused" "gitleaks found a secret" "$H"
if [ "$(remote_sha refs/heads/feature)" = "none" ]; then ok "case 2: branch not created on remote"; else bad "case 2: branch not created on remote"; fi
teardown

# ---- case 3: first push into an empty remote scans every ancestor ------------
setup toml
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
remove_file secret.txt "remove" >/dev/null
clean_commits 2
set_pins
arm
do_push origin main
expect_block "case 3: empty remote, secret deep in history -> refused" "gitleaks found a secret" "$H"
if [ "$(remote_sha refs/heads/main)" = "none" ]; then ok "case 3: nothing reached the empty remote"; else bad "case 3: nothing reached the empty remote"; fi
teardown

# ---- case 3b: first push into an empty remote, clean history -> allowed -------
setup toml
clean_commits 2
set_pins
arm
do_push origin main
expect_pass "case 3b: empty remote, clean history, pins match -> allowed"
teardown

# ---- case 18: the base rules cannot be chosen by the pusher ---------------------
# A loosened .gitleaks.toml sits in a commit the local repo merely CLAIMS is on
# the remote (a forged remote-tracking ref). The base must be the remote's
# default branch, so the loosened file differs from it and is refused.
setup toml; publish_seed
P="$(widen_toml_commit)"
(cd "$R" && git update-ref refs/remotes/origin/fake "$P")
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
do_push origin HEAD:refs/heads/feature
expect_block "case 18: base rules from a forged remote-tracking ref -> refused" "differs from the base" "$H"
teardown

# ---- case 18b: existing ref, loosen then secret -> base is the remote tip -------
setup toml; publish_seed
widen_toml_commit >/dev/null
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
do_push origin main
expect_block "case 18b: existing ref, loosened rules then a secret -> refused" "differs from the base" "$H"
teardown

# ---- case 19: new branch off a loosened remote branch -> base is the default ----
setup toml; publish_seed
(cd "$R" && git config core.hooksPath "$WORK/nohooks" && git checkout -qb loose)
widen_toml_commit >/dev/null
(cd "$R" && git push -q origin loose >/dev/null 2>&1 && git checkout -qb feat2)
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
arm
do_push origin feat2
expect_block "case 19: new branch on top of a loosened remote branch -> refused" "differs from the base" "$H"
teardown

# ---- case 20: empty remote, no pin recorded / pin mismatch -> refused -----------
setup toml
clean_commits 1
arm
do_push origin main
expect_block "case 20a: empty remote, no pin recorded -> refused" "no pin recorded for .gitleaks.toml"
# 20d: the refusal must not teach how to record a pin (an AI could follow it)
if printf '%s' "$OUT" | grep -qE 'git config|metal\.prepush\.pin'; then
	bad "case 20d: no-pin refusal must not show how to record a pin"
elif ! printf '%s' "$OUT" | grep -qF "経営者の操作が要る"; then
	bad "case 20d: no-pin refusal must say the operator's step is needed"
else
	ok "case 20d: no-pin refusal shows no way to record a pin"
fi
set_pins
(cd "$R" && git config --local metal.prepush.pin.gitleaks-toml "$(printf '%064d' 0)")
do_push origin main
expect_block "case 20b: empty remote, pin mismatch -> refused" "does not match"
if printf '%s' "$OUT" | grep -qE 'git config|metal\.prepush\.pin'; then
	bad "case 20d: pin-mismatch refusal must not show how to record a pin"
else
	ok "case 20d: pin-mismatch refusal shows no way to record a pin"
fi
set_pins
(cd "$R" && git config --local --unset metal.prepush.pin.pre-push-hook)
do_push origin main
expect_block "case 20c: empty remote, only the hook's pin missing -> refused" "no pin recorded for .githooks/pre-push"
teardown

# ---- case 25: a forged local refs/remotes/<remote>/main is not trusted ---------
# The base and the range's --not come from `git ls-remote`, not from the local
# remote-tracking refs, so pointing origin/main at a loosened commit changes
# nothing.
setup toml; publish_seed
P="$(widen_toml_commit)"
(cd "$R" && git update-ref refs/remotes/origin/main "$P")
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
do_push origin HEAD:refs/heads/feature
expect_block "case 25: forged local origin/main -> refused" "differs from the base"
teardown

# ---- case 28: a forged tracking ref cannot hide a secret commit from the range ---
setup toml; publish_seed
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
(cd "$R" && git update-ref refs/remotes/origin/hidden HEAD)
clean_commits 1
do_push origin HEAD:refs/heads/feature
expect_block "case 28: secret commit behind a forged tracking ref -> refused" "gitleaks found a secret" "$H"
teardown

# ---- case 31: a `-diff` attribute cannot hide a commit's content ------------------
# With `-diff`, git prints "Binary files differ" and no lines, so neither tool
# would see the value. Both the work tree's .gitattributes and
# .git/info/attributes are tried, for each tool.
for where in worktree info; do
	for probe in gitleaks guard; do
		setup toml; publish_seed
		if [ "$where" = worktree ]; then
			printf '* -diff\n' > "$R/.gitattributes"
			echo .gitattributes >> "$R/.git/info/exclude"
		else
			printf '* -diff\n' > "$R/.git/info/attributes"
		fi
		if [ "$probe" = gitleaks ]; then
			H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"; needle="gitleaks found a secret"
		else
			H="$(commit_file note.md "host is $GUARD_WORD here" "add")"; needle="publish-guard found a forbidden value"
		fi
		do_push origin main
		expect_block "case 31 ($where attributes, $probe): -diff does not hide the value -> refused" "$needle" "$H"
		teardown
	done
done

# ---- case 32: annotated tags — the tag body is scanned too ---------------------
# 32a/b: new commit + annotated tag whose MESSAGE carries the value -> refused
for probe in gitleaks guard; do
	setup toml; publish_seed
	clean_commits 1
	if [ "$probe" = gitleaks ]; then
		msg="release aws=$AWS_PROBE"; needle="gitleaks found a secret in the tag body"; label="case 32a"
	else
		msg="release host is $GUARD_WORD"; needle="publish-guard found a forbidden value in the tag body"; label="case 32b"
	fi
	(cd "$R" && git tag -a v1 -m "$msg")
	do_push origin v1
	expect_block "$label: annotated tag body carries a $probe value -> refused" "$needle"
	if [ "$(remote_sha refs/tags/v1)" = "none" ]; then ok "$label: tag not on remote"; else bad "$label: tag not on remote"; fi
	teardown
done
# 32c: annotated tag on an already-published commit, clean body -> allowed
setup toml; publish_seed
(cd "$R" && git tag -a v2 -m "clean release note")
do_push origin v2
expect_pass "case 32c: annotated tag on a published commit, clean body -> allowed"
teardown
# 32d: annotated tag on a published commit, secret in the body -> refused for the body
setup toml; publish_seed
(cd "$R" && git tag -a v3 -m "note aws=$AWS_PROBE")
do_push origin v3
expect_block "case 32d: annotated tag on a published commit, secret body -> refused" "gitleaks found a secret in the tag body"
teardown
# 32e: a tag of a tag — every tag body in the chain is scanned
setup toml; publish_seed
(cd "$R" && git tag -a inner -m "note aws=$AWS_PROBE" && git tag -a outer -m "clean" inner && git tag -d inner >/dev/null)
do_push origin outer
expect_block "case 32e: secret in the inner tag of a tag-of-tag -> refused" "gitleaks found a secret in the tag body"
teardown
# 32f: lightweight tags behave as before
setup toml; publish_seed
commit_file secret.txt "aws=$AWS_PROBE" "add" >/dev/null
(cd "$R" && git tag light1)
do_push origin light1
expect_block "case 32f: lightweight tag on a new secret commit -> refused" "gitleaks found a secret"
teardown
setup toml; publish_seed
(cd "$R" && git tag light2)
do_push origin light2
expect_block "case 32g: lightweight tag on a published commit -> refused (zero commits, as before)" "zero commits"
teardown

# ---- case 33: one push, two refs ------------------------------------------------
setup toml; publish_seed
(cd "$R" && git checkout -qb a && commit_file a.txt "a" "a" >/dev/null && git checkout -q main && git checkout -qb b)
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
do_push origin a b
expect_block "case 33a: two refs, one carries a secret -> refused" "gitleaks found a secret" "$H"
(cd "$R" && git checkout -q a)
do_push origin a main
expect_pass "case 33b: two clean refs -> allowed"
teardown

# ---- case 34: a force push that rewrites history is scanned in full --------------
setup toml; publish_seed
clean_commits 2
(cd "$R" && git config core.hooksPath "$WORK/nohooks" && git push -q origin main >/dev/null 2>&1 && git reset -q --hard HEAD~2)
arm
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
clean_commits 1
do_push --force origin main
expect_block "case 34: force push with a rewritten secret commit -> refused" "gitleaks found a secret" "$H"
teardown

# ---- case 35: exceptions cannot come from local files or the environment ---------
# 35a: a .gitleaksignore COMMITTED in the range (it is also in the work tree)
setup toml; publish_seed
commit_file secret.txt "aws=$AWS_PROBE" "add" >/dev/null
FULL="$(cd "$R" && git rev-parse HEAD)"
commit_file .gitleaksignore "$FULL:secret.txt:aws-access-token:1" "ignore it" >/dev/null
do_push origin main
expect_block "case 35a: committed .gitleaksignore does not exempt -> refused" "gitleaks found a secret" "${FULL:0:7}"
teardown
# 35b: a .gitleaksignore inside the git directory -> refused outright
setup toml; publish_seed
clean_commits 1
: > "$R/.git/.gitleaksignore"
do_push origin main
expect_block "case 35b: .gitleaksignore in the git dir -> refused" "a .gitleaksignore exists in the git directory"
teardown
# 35c: loosened rules handed in through GITLEAKS_CONFIG / GITLEAKS_CONFIG_TOML
for var in GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML; do
	setup toml; publish_seed
	printf '[allowlist]\npaths = [ %s ]\n' "'''secret\\.txt'''" > "$WORK/loose.toml"
	commit_file secret.txt "aws=$AWS_PROBE" "add" >/dev/null
	if [ "$var" = GITLEAKS_CONFIG ]; then val="$WORK/loose.toml"; else val="$(cat "$WORK/loose.toml")"; fi
	OUT="$(cd "$R" && env "$var=$val" git push origin main 2>&1)"
	RC=$?
	expect_block "case 35c: loosened rules via $var are ignored -> refused" "gitleaks found a secret"
	teardown
done

# ---- case 26: remote has refs but no base can be found -> refused, pins or not ---
setup toml; publish_seed
(cd "$R" && git checkout -q --orphan unrelated && git commit -qm "unrelated root")
set_pins
do_push origin unrelated
expect_block "case 26: remote has refs, no merge-base, pins match -> refused" "no base"
teardown

# ---- case 27: ls-remote fails -> refused ----------------------------------------
setup toml; publish_seed
clean_commits 1
# Push uses receive-pack, ls-remote uses upload-pack: an exec-path whose
# upload-pack always fails breaks ls-remote and nothing else.
mkdir -p "$WORK/ep"
for f in "$(git --exec-path)"/*; do ln -s "$f" "$WORK/ep/"; done
rm -f "$WORK/ep/git-upload-pack"
printf '#!/bin/sh\nexit 1\n' > "$WORK/ep/git-upload-pack"
chmod +x "$WORK/ep/git-upload-pack"
OUT="$(cd "$R" && GIT_EXEC_PATH="$WORK/ep" git push origin main 2>&1)"
RC=$?
expect_block "case 27: ls-remote fails -> refused" "ls-remote"
teardown

# ---- case 4: gitleaks not on PATH -> refused ---------------------------------
if PATH="$NO_GITLEAKS_PATH" command -v gitleaks >/dev/null 2>&1; then
	bad "case 4: fixture cannot hide gitleaks (found on $NO_GITLEAKS_PATH)"
else
	setup toml; publish_seed
	clean_commits 1
	PUSH_PATH="$NO_GITLEAKS_PATH" do_push origin main
	expect_block "case 4: gitleaks missing -> refused" "gitleaks is not on PATH"
	teardown
fi

# ---- case 5: the base's publish-guard fails -> refused ------------------------
SEED_TWEAK='printf "#!/bin/sh\nexit 3\n" > scripts/publish-guard.sh' setup toml; publish_seed
clean_commits 1
do_push origin main
expect_block "case 5: base publish-guard fails -> refused" "publish-guard failed"
teardown

# ---- case 6 / 6d: gitleaks hangs -> per-commit time limit refuses -------------
# Real gitleaks (Go) ignores SIGALRM, so the stand-in ignores it too (6), and
# then TERM as well (6d), which only a KILL can stop. Each stand-in would sleep
# 30s; the limit is 2s.
for mode in alrm term; do
	setup toml; publish_seed
	clean_commits 1
	mkdir -p "$WORK/slowbin"
	if [ "$mode" = alrm ]; then
		printf "#!/bin/sh\ntrap '' ALRM\nexec sleep 30\n" > "$WORK/slowbin/gitleaks"; label="case 6"
	else
		printf "#!/bin/sh\ntrap '' ALRM TERM\nexec sleep 30\n" > "$WORK/slowbin/gitleaks"; label="case 6d"
	fi
	chmod +x "$WORK/slowbin/gitleaks"
	t0=$(date +%s)
	FYD_PREPUSH_COMMIT_TIMEOUT=2 PUSH_PATH="$WORK/slowbin:$PATH" do_push origin main
	t1=$(date +%s)
	expect_block "$label: gitleaks ignoring ${mode} past the limit -> refused" "timed out"
	if [ $((t1 - t0)) -lt 20 ]; then ok "$label: refused within the time limit ($((t1 - t0))s)"; else bad "$label: refused within the time limit (took $((t1 - t0))s)"; fi
	teardown
done

# ---- case 6b: gitleaks exits abnormally -> refused ----------------------------
setup toml; publish_seed
clean_commits 1
mkdir -p "$WORK/errbin"
printf '#!/bin/sh\nexit 2\n' > "$WORK/errbin/gitleaks"
chmod +x "$WORK/errbin/gitleaks"
PUSH_PATH="$WORK/errbin:$PATH" do_push origin main
expect_block "case 6b: gitleaks abnormal exit -> refused" "gitleaks exited abnormally"
teardown

# ---- case 6c: gitleaks exits 0 but its report is unreadable -> refused ---------
setup toml; publish_seed
clean_commits 1
mkdir -p "$WORK/junkbin"
cat > "$WORK/junkbin/gitleaks" <<'EOF'
#!/bin/sh
# write junk wherever --report-path / -r points, then claim success
while [ $# -gt 0 ]; do
	case "$1" in -r|--report-path) shift; printf 'not json\n' > "$1" ;; esac
	shift
done
echo "1 commits scanned." >&2
exit 0
EOF
chmod +x "$WORK/junkbin/gitleaks"
PUSH_PATH="$WORK/junkbin:$PATH" do_push origin main
expect_block "case 6c: unreadable gitleaks report -> refused" "unreadable"
teardown

# ---- case 17: gitleaks says "clean" but scanned 0 commits of a non-empty one ---
setup toml; publish_seed
clean_commits 1
mkdir -p "$WORK/zerobin"
cat > "$WORK/zerobin/gitleaks" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
	case "$1" in -r|--report-path) shift; printf '[]\n' > "$1" ;; esac
	shift
done
echo "0 commits scanned." >&2
exit 0
EOF
chmod +x "$WORK/zerobin/gitleaks"
PUSH_PATH="$WORK/zerobin:$PATH" do_push origin main
expect_block "case 17: clean report but 0 commits scanned -> refused" "expected exactly this one"
teardown

# ---- case 7: deleting a remote branch -> allowed ------------------------------
setup toml; publish_seed
(cd "$R" && git config core.hooksPath "$WORK/nohooks" && git push -q origin main:refs/heads/old >/dev/null 2>&1)
arm
do_push origin :refs/heads/old
expect_pass "case 7: delete push -> allowed"
if [ "$(remote_sha refs/heads/old)" = "none" ]; then ok "case 7: remote branch deleted"; else bad "case 7: remote branch deleted"; fi
teardown

# ---- case 8: an ordinary clean push -> allowed (timed) ------------------------
setup toml; publish_seed
N_CLEAN=20
clean_commits "$N_CLEAN"
t0=$(date +%s)
do_push origin main
t1=$(date +%s)
expect_pass "case 8: clean push of $N_CLEAN commits -> allowed"
echo "TIMING case 8: $N_CLEAN commits in $((t1 - t0))s"
teardown

# ---- case 9: .gitleaks.toml changed in a middle commit -> refused --------------
setup toml; publish_seed
H="$(cd "$R" && printf '%s\n' "  '''zz-extra-path''',"  >> .gitleaks.toml && git add .gitleaks.toml && git commit -qm "widen" && git rev-parse --short HEAD)"
(cd "$R" && git checkout -q HEAD~1 -- .gitleaks.toml && git commit -qm "restore")
do_push origin main
expect_block "case 9: .gitleaks.toml changed mid-range -> refused" "separate gate" "$H"
teardown

# ---- case 10: remote sha not known locally -> refused --------------------------
setup toml; publish_seed
OTHER="$WORK/other"
git clone -q -b main "$B" "$OTHER" 2>/dev/null
(cd "$OTHER" && git config user.name o && git config user.email o@example.invalid && git config core.hooksPath "$WORK/nohooks" \
	&& echo x > x && git add x && git commit -qm other && git push -q origin main >/dev/null 2>&1)
clean_commits 1
do_push --force origin main
expect_block "case 10: remote sha missing locally -> refused" "not found locally"
teardown

# ---- case 11: ref advances with zero new commits -> refused --------------------
setup toml; publish_seed
do_push origin main:refs/heads/copy
expect_block "case 11: zero commits but ref advances -> refused" "zero commits"
teardown

# ---- case 12: inline gitleaks:allow does not exempt a commit -------------------
setup toml; publish_seed
H="$(commit_file secret.txt "aws=$AWS_PROBE # gitleaks:allow" "add")"
do_push origin main
expect_block "case 12: inline gitleaks:allow is ignored -> refused" "gitleaks found a secret" "$H"
teardown

# ---- case 13: merge commit whose second parent carries a secret -----------------
setup toml; publish_seed
(cd "$R" && git checkout -qb side)
H="$(commit_file secret.txt "aws=$AWS_PROBE" "side add")"
(cd "$R" && git checkout -q main && commit_file m.txt "m" "main work" >/dev/null && git merge -q --no-edit side)
do_push origin main
expect_block "case 13: secret arriving through a merge -> refused" "gitleaks found a secret" "$H"
teardown

# ---- case 13b/13c: value introduced only by the merge commit itself --------------
# Neither parent carries it, so only a scan of the merge's own diff sees it.
for probe in gitleaks guard; do
	setup toml; publish_seed
	(cd "$R" && git checkout -qb side && commit_file s.txt "s" "side work" >/dev/null && git checkout -q main \
		&& commit_file m.txt "m" "main work" >/dev/null && git merge -q --no-commit --no-ff side)
	if [ "$probe" = gitleaks ]; then
		(cd "$R" && printf 'aws=%s\n' "$AWS_PROBE" > evil.txt)
		needle="gitleaks found a secret"; label="case 13b: secret added only in the merge commit -> refused"
	else
		(cd "$R" && printf 'host is %s here\n' "$GUARD_WORD" > evil.txt)
		needle="publish-guard found a forbidden value"; label="case 13c: guard value added only in the merge commit -> refused"
	fi
	H="$(cd "$R" && git add evil.txt && git commit -qm "merge side" && git rev-parse --short HEAD)"
	do_push origin main
	expect_block "$label" "$needle" "$H"
	teardown
done

# ---- case 14: the base predates the gate -------------------------------------------
# 14a: no pins -> refused. 14b: even with the tip's pins recorded -> refused:
# the pin path is only for a remote that has no refs at all.
SEED_TWEAK='rm -f scripts/pre-push-scan.sh' setup toml; publish_seed
(cd "$R" && cp "$SRC/scripts/pre-push-scan.sh" scripts/pre-push-scan.sh && git add scripts/pre-push-scan.sh && git commit -qm "add gate")
do_push origin main
expect_block "case 14a: base without the gate, no pin -> refused" "has no usable gate"
set_pins
do_push origin main
expect_block "case 14b: base without the gate, tip pinned, remote not empty -> refused" "has no usable gate"
teardown

# ---- case 14c: the work tree has no scanner -> the base copy still runs -----------
setup toml; publish_seed
commit_file secret.txt "aws=$AWS_PROBE" "add" >/dev/null
rm -f "$R/scripts/pre-push-scan.sh"
do_push origin main
expect_block "case 14c: work tree without the scanner, base copy runs -> refused" "gitleaks found a secret"
teardown

# ---- case 21: a work-tree scanner that always passes is not used ------------------
setup toml; publish_seed
H="$(commit_file secret.txt "aws=$AWS_PROBE" "add")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/scripts/pre-push-scan.sh"
do_push origin main
expect_block "case 21: work-tree scanner rewritten to pass -> refused" "gitleaks found a secret" "$H"
teardown

# ---- case 22: a pushed commit that empties publish-guard is scanned by the base's --
setup toml; publish_seed
(cd "$R" && : > scripts/publish-guard.sh && git add scripts/publish-guard.sh && git commit -qm "empty guard")
H="$(commit_file note.md "host is $GUARD_WORD here" "add")"
do_push origin main
expect_block "case 22: guard emptied in the push -> refused (protected gate file)" "経営者の判断が要る" "scripts/publish-guard.sh"
teardown

# ---- case 23: a harmless change to a gate file is still refused -------------------
setup toml; publish_seed
(cd "$R" && printf '# harmless note\n' >> scripts/pre-push-scan.sh && git add scripts/pre-push-scan.sh && git commit -qm "touch gate")
clean_commits 1
do_push origin main
expect_block "case 23: gate file changed, clean content -> refused" "経営者の判断が要る" "scripts/pre-push-scan.sh"
teardown

# ---- case 29: each of the five protected files, changed alone -> refused ---------
for f in .gitleaks.toml scripts/pre-push-scan.sh scripts/lib/push-range.sh scripts/publish-guard.sh .githooks/pre-push; do
	setup toml; publish_seed
	(cd "$R" && printf '# note\n' >> "$f" && git add "$f" && git commit -qm "touch $f")
	do_push origin main
	expect_block "case 29: only $f changed -> refused" "経営者の判断が要る" "$f"
	teardown
done

# ---- case 30: two pushes cannot install a new gate --------------------------------
# Push 1 changes the gate and is refused, so the remote never takes it and it
# can never become the base of push 2.
setup toml; publish_seed
(cd "$R" && printf 'exit 0\n' > scripts/publish-guard.sh && git add scripts/publish-guard.sh && git commit -qm "neuter guard")
do_push origin main
expect_block "case 30: push 1 (gate changed) -> refused" "経営者の判断が要る"
H="$(commit_file note.md "host is $GUARD_WORD here" "add")"
do_push origin main
expect_block "case 30: push 2 on top -> still refused" "経営者の判断が要る"
if [ "$(remote_sha refs/heads/main)" = "$(cd "$R" && git rev-parse HEAD~2)" ]; then ok "case 30: remote never moved"; else bad "case 30: remote never moved"; fi
teardown

# ---- case 24: the base's scanner speaks another protocol -> refused ---------------
SEED_TWEAK='perl -pi -e "s/^FYD_PREPUSH_PROTOCOL_EXPECTED=[0-9]+\$/FYD_PREPUSH_PROTOCOL_EXPECTED=999/" scripts/pre-push-scan.sh; grep -q "^FYD_PREPUSH_PROTOCOL_EXPECTED=999\$" scripts/pre-push-scan.sh || echo "SEED_TWEAK did not apply" >&2' setup toml; publish_seed
clean_commits 1
do_push origin main
expect_block "case 24: base scanner protocol mismatch -> refused" "protocol"
teardown

# ---- case 15: a .gitleaksignore in the work tree does not exempt a commit ---------
setup toml; publish_seed
commit_file secret.txt "aws=$AWS_PROBE" "add" >/dev/null
FULL="$(cd "$R" && git rev-parse HEAD)"
printf '%s:secret.txt:aws-access-token:1\n' "$FULL" > "$R/.gitleaksignore"
echo .gitleaksignore >> "$R/.git/info/exclude"
do_push origin main
expect_block "case 15: work-tree .gitleaksignore is ignored -> refused" "gitleaks found a secret" "${FULL:0:7}"
teardown

# ---- case 16: rules come from the base commit, not from the work tree -------------
# An uncommitted edit of .gitleaks.toml that would exempt the file must not apply.
setup toml; publish_seed
commit_file secret.txt "aws=$AWS_PROBE" "add" >/dev/null
FULL="$(cd "$R" && git rev-parse HEAD)"
perl -0pi -e "s/paths = \\[\\n/paths = [\\n  '''secret\\\\.txt''',\\n/" "$R/.gitleaks.toml"
if (cd "$R" && git diff --quiet -- .gitleaks.toml); then
	bad "case 16: fixture failed to edit the work-tree .gitleaks.toml"
else
	do_push origin main
	expect_block "case 16: work-tree rule edit does not apply -> refused" "gitleaks found a secret" "${FULL:0:7}"
fi
teardown

# ---- case 36: forced colour in git config must not stop an ordinary push -------------
# color.ui / color.diff = always put escape codes into every diff the scanner
# takes, so gitleaks read "0 commits" and refused everything. (a) clean push ->
# allowed, (b) a secret -> still refused.
setup toml; publish_seed
(cd "$R" && git config --local color.ui always && git config --local color.diff always)
clean_commits 2
do_push origin main
expect_pass "case 36a: color.ui/color.diff=always, clean push -> allowed"
commit_file secret.txt "aws=$AWS_PROBE" "add" >/dev/null
FULL="$(cd "$R" && git rev-parse HEAD)"
do_push origin main
expect_block "case 36b: color.ui/color.diff=always, secret -> refused" "gitleaks found a secret" "${FULL:0:7}"
teardown

# ---- summary --------------------------------------------------------------------
echo "test-pre-push-scan.sh summary: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo "RESULT: PASS"
	exit 0
fi
echo "RESULT: FAIL"
exit 1
