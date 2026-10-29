#!/usr/bin/env bash
# sanitize-history.sh — one-command scrub of forbidden host identifiers AND
# operator PII (real name / company / handle / phone / personal email / host
# IP / SSH key name) from ALL git history via git-filter-repo.
#
# DESTRUCTIVE: rewrites every commit. Makes a backup bundle + safety tag first,
# and does NOT push — it prints the exact force-push command for the operator
# to run after review. (installer-script-first; force-push stays an explicit
# operator action.)
#
# Why: a deep audit (docs/audits/constitution-2026-07-03T16-33-audit.md) found
# a real host IP + SSH key name in an ALREADY-PUBLIC commit. A forward-fix
# commit does not remove such data from history; this does.
#
# Source of truth for the exact PII literals is the LOCAL, gitignored
# .publish-denylist (same file scripts/publish-guard.sh consults). This tracked
# script therefore contains NO real PII. Public IPv4 literals are additionally
# auto-discovered from history as a belt. After rewriting, it re-scans ALL
# history with publish-guard.sh and reports whether anything remains.
#
# Prereq: pip install git-filter-repo ; a clean working tree ; a populated
#         .publish-denylist (cp .publish-denylist.example .publish-denylist).

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
DENY="${FYD_PUBLISH_DENYLIST:-$ROOT/.publish-denylist}"
GUARD="$ROOT/scripts/publish-guard.sh"

if ! command -v git-filter-repo >/dev/null 2>&1 && ! python3 -c 'import git_filter_repo' 2>/dev/null; then
	echo "ERROR: git-filter-repo not found. Install with: pip install git-filter-repo" >&2
	exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "ERROR: working tree not clean. Commit or stash first (filter-repo rewrites committed history)." >&2
	git status --short >&2
	exit 1
fi

echo "== 1/5 backup =="
STAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE="${ROOT}/../$(basename "$ROOT")-prefilter-${STAMP}.bundle"
git bundle create "$BUNDLE" --all >/dev/null
# Backup is the bundle FILE only — deliberately NOT a git tag/ref: a pre-sanitize
# tag would still hold the PII and could be pushed by an accidental `--tags`.
echo "  backup bundle: $BUNDLE  (restore: git clone <bundle>)"

echo "== 2/5 build replacement rules (from .publish-denylist + auto IP discovery) =="
REPL="$(mktemp -t sanitize-repl.XXXXXX)"
trap 'rm -f "$REPL"' EXIT
: > "$REPL"

ipn=10
if [ -f "$DENY" ]; then
	while IFS= read -r e || [ -n "$e" ]; do
		[ -z "$e" ] && continue
		case "$e" in \#*) continue ;; esac
		if printf '%s' "$e" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
			printf '%s==>203.0.113.%d\n' "$e" "$ipn" >> "$REPL"; ipn=$((ipn+1))
		elif printf '%s' "$e" | grep -q '@'; then
			printf '%s==>redacted@example.com\n' "$e" >> "$REPL"
		elif printf '%s' "$e" | grep -qE '^0[0-9]{9,10}$'; then
			printf '%s==>REDACTED-PHONE\n' "$e" >> "$REPL"
		elif printf '%s' "$e" | LC_ALL=C grep -qE '^[!-~]+$'; then
			# ASCII word: use a word-boundary regex so we do NOT substring-replace
			# it inside unrelated words (e.g. a company slug inside "inspiring").
			printf 'regex:(?i)\\b%s\\b==>REDACTED\n' "$e" >> "$REPL"
		else
			# non-ASCII (CJK name / kana company): literal — unique enough, and
			# CJK has no ASCII word-boundary concept.
			printf '%s==>REDACTED\n' "$e" >> "$REPL"
		fi
	done < "$DENY"
else
	echo "  WARNING: $DENY not found — only auto-discovered public IPs will be scrubbed." >&2
	echo "           cp .publish-denylist.example .publish-denylist and add the real PII first." >&2
fi

# Belt: auto-discover any public IPv4 in history not already covered.
DISC_IPS="$(git log --all -p --no-color 2>/dev/null | perl -ne '
	while (/(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])/g) {
		my @o=($1,$2,$3,$4); next if grep {$_>255} @o; my ($a,$b,$c)=@o;
		next if $a==0||$a==10||$a==127; next if $a==172&&$b>=16&&$b<=31;
		next if $a==192&&$b==168; next if $a==169&&$b==254; next if $a==100&&$b>=64&&$b<=127;
		next if $a==192&&$b==0&&$c==2; next if $a==198&&$b==51&&$c==100; next if $a==203&&$b==0&&$c==113;
		next if $a>=224; print "$a.$b.$c.$o[3]\n";
	}' | sort -u)"
while IFS= read -r ip; do
	[ -z "$ip" ] && continue
	grep -qF "${ip}==>" "$REPL" 2>/dev/null && continue
	printf '%s==>203.0.113.%d\n' "$ip" "$ipn" >> "$REPL"; ipn=$((ipn+1))
done <<< "$DISC_IPS"

RULES=$(grep -c . "$REPL" || true)
if [ "$RULES" -eq 0 ]; then
	echo "  no replacement rules — nothing to rewrite (denylist empty and no public IP in history)."
	exit 0
fi
echo "  ${RULES} replacement rule(s) built (literals redacted)."

echo "== 3/5 filter-repo rewrite (DESTRUCTIVE) =="
# A prior filter-repo run (e.g. an earlier sanitize) leaves state under
# .git/filter-repo and would otherwise prompt interactively to "continue",
# which fails under non-interactive execution. We already made a full backup
# bundle above, so clear that state to run a clean fresh pass.
rm -rf "$ROOT/.git/filter-repo"
# --replace-text scrubs blob content; --replace-message scrubs commit messages
# (the two are independent in filter-repo, and PII lands in both).
git filter-repo --force --replace-text "$REPL" --replace-message "$REPL"

echo "== 4/5 verify branch content with publish-guard =="
# Scan the CONTENT that a push publishes: every branch's blob diffs + commit
# messages. Deliberately NOT `git log --all -p` — that would (a) traverse local
# backup refs that hold pre-sanitize PII by design, and (b) include git's own
# "commit <sha>" lines, whose hex can contain an 11-digit run the phone check
# would false-flag. Blobs + messages are exactly what ends up public.
if { git log --branches -p --no-color --format='' 2>/dev/null; \
     git log --branches --format='%B' 2>/dev/null; } | "$GUARD" --text >/dev/null 2>&1; then
	echo "  clean: no host IP / handle / name / phone / email in any branch's blobs or messages."
else
	echo "  WARNING: publish-guard still flags branch content — investigate before pushing." >&2
fi

echo "== 5/5 next step (operator action) =="
cat <<EOF

History rewritten LOCALLY. git-filter-repo removed the 'origin' remote for
safety. After reviewing, re-add origin and force-push ONLY the branch(es) you
publish — do NOT use --tags / --all, which would push local backup refs that
still hold the pre-sanitize PII:

  git remote add origin https://github.com/freedomyield/metal.freedom-yield.com.git
  git fetch origin                               # repopulate origin/main so --force-with-lease has a lease to check
  git push --force-with-lease origin main

Restore the pre-rewrite state if needed:
  git bundle verify "$BUNDLE"    # then: git clone "$BUNDLE" <dir>

Note: content already public before this rewrite may persist in GitHub forks /
caches / archives; this stops further propagation from the canonical repo.
EOF
