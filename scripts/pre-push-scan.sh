#!/usr/bin/env bash
# SCOPE (what this gate protects against): the local pre-push gate stops
# ACCIDENTS — a secret or host identifier committed by mistake, by a person
# or by an AI session. A local user can always skip it (--no-verify), so a
# deliberate local user is OUT of scope. The receiving side's walls are
# GitHub push protection and CI.
#
# pre-push-scan.sh — scan EVERY commit a `git push` is about to send, one by
# one, with gitleaks and with publish-guard. Run by .githooks/pre-push, once
# per ref, as a COPY taken out of the base commit (never the work tree's
# file): the range lib and publish-guard it uses are the ones next to it in
# that copy. The hook passes:
#   FYD_PREPUSH_PROTOCOL    must equal FYD_PREPUSH_PROTOCOL_EXPECTED below;
#                           a hook and scanner that disagree = refused
#   FYD_PREPUSH_RULES_FROM  the commit whose .gitleaks.toml is the rule set
#                           (the base, or the pinned tip of an empty remote)
#   FYD_PREPUSH_REMOTE_SHAS file of the commits the remote advertised
#                           (from `git ls-remote`), the range's --not
#
# WHY ONE BY ONE: the previous hook diffed the whole range once
# (`git diff a..b`), so a secret added in a middle commit and removed in the
# next one never appeared in the diff — and was published in history anyway.
# A public repo publishes every commit, so every commit is scanned.
#
# Usage (the hook does this):  pre-push-scan.sh <remote-name> <remote-url>
#   stdin: <local ref> <local sha> <remote ref> <remote sha>
#
# Per commit c:
#   1. c's copy of each PROTECTED file (.gitleaks.toml and the five gate
#      files, see PROTECTED below) must be byte-identical (same blob) to the
#      rule commit's. The hook picks that commit from what the remote already
#      publishes (see .githooks/pre-push). A change is refused here: it needs
#      the operator's decision, never a plain push.
#   2. gitleaks scans c alone (`--log-opts="-1 -m --first-parent <c>"`) with
#      the rule commit's rules (no file there = gitleaks defaults), with
#      inline `gitleaks:allow` comments and any .gitleaksignore disabled, so
#      nothing inside the pushed commits can exempt itself.
#      gitleaks always also reads <source>/.gitleaksignore, whatever
#      --gitleaks-ignore-path says, so the source handed to it is the git
#      directory (never the work tree), and a .gitleaksignore found there is
#      itself a refusal.
#   3. publish-guard scans c's own diff (`git show -m --first-parent --root`).
#   Every diff (gitleaks, publish-guard, the added-line count) is taken with
#   DIFF_OPTS = --text --no-textconv --no-ext-diff --no-color, so a `-diff` attribute
#   (.gitattributes, .git/info/attributes) or a textconv / external diff
#   driver cannot turn the content into "Binary files differ".
#   Merge commits are diffed against their first parent, so content that
#   arrives through a merge is scanned even if no single side commit is new.
#
# FAIL-CLOSED: gitleaks / perl missing, publish-guard missing or not
# executable, a non-zero exit, a time-out (FYD_PREPUSH_COMMIT_TIMEOUT seconds
# per tool per commit, default 60; a watchdog sends TERM at the limit and
# KILL 2s later — not SIGALRM, which gitleaks (Go) ignores — and macOS has
# no `timeout`), an unreadable report, or a scanned-commit count
# that does not match the commit -> the push is REFUSED. Only the short hash
# and the reason are printed, never the matched value.
#
# Exit: 0 every commit clean / 1 refused.

set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	echo "pre-push-scan: not inside a git work tree — REFUSED" >&2
	exit 1
}
cd "$ROOT" || exit 1

FYD_PREPUSH_PROTOCOL_EXPECTED=3
if [[ "${FYD_PREPUSH_PROTOCOL:-}" != "$FYD_PREPUSH_PROTOCOL_EXPECTED" ]]; then
	echo "pre-push-scan: hook/scanner protocol mismatch (hook=${FYD_PREPUSH_PROTOCOL:-none}, scanner=${FYD_PREPUSH_PROTOCOL_EXPECTED}) — REFUSED" >&2
	exit 1
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
	echo "pre-push-scan: cannot resolve its own directory — REFUSED" >&2
	exit 1
}

# shellcheck source=scripts/lib/push-range.sh
if ! . "${HERE}/lib/push-range.sh" 2>/dev/null || ! declare -F fyd_push_range_commits >/dev/null; then
	echo "pre-push-scan: lib/push-range.sh missing or broken next to the scanner — REFUSED" >&2
	exit 1
fi

GUARD="${HERE}/publish-guard.sh"
REMOTE_SHAS="${FYD_PREPUSH_REMOTE_SHAS:-}"
if [[ -z "$REMOTE_SHAS" || ! -f "$REMOTE_SHAS" ]]; then
	echo "pre-push-scan: no remote-shas file given by the hook — REFUSED" >&2
	exit 1
fi
RULES_FROM="${FYD_PREPUSH_RULES_FROM:-}"
if [[ -z "$RULES_FROM" ]] || ! git cat-file -e "${RULES_FROM}^{commit}" 2>/dev/null; then
	echo "pre-push-scan: no rule commit given by the hook — REFUSED" >&2
	exit 1
fi
TIMEOUT="${FYD_PREPUSH_COMMIT_TIMEOUT:-60}"
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
	echo "pre-push-scan: FYD_PREPUSH_COMMIT_TIMEOUT must be a positive integer — REFUSED" >&2
	exit 1
fi
# Rules come only from the base commit, never from the environment.
unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-scan.XXXXXX")" || {
	echo "pre-push-scan: cannot create a temp dir — REFUSED" >&2
	exit 1
}
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/noignore"
GIT_DIR_ABS="$(git rev-parse --absolute-git-dir 2>/dev/null)" || {
	echo "pre-push-scan: cannot resolve the git directory — REFUSED" >&2
	exit 1
}

# Never let attributes or diff drivers hide content (see the header).
DIFF_OPTS=(--text --no-textconv --no-ext-diff --no-color)

REFUSED=0
refuse() {
	# refuse <commit or ref label> <reason>
	REFUSED=1
	echo "pre-push-scan: REFUSED ${1}: ${2}" >&2
}

TOOLS_CHECKED=0
TOOLS_OK=0
check_tools() {
	if [[ "$TOOLS_CHECKED" -eq 1 ]]; then
		[[ "$TOOLS_OK" -eq 1 ]]
		return
	fi
	TOOLS_CHECKED=1
	TOOLS_OK=1
	if ! command -v gitleaks >/dev/null 2>&1; then
		refuse "-" "gitleaks is not on PATH; the push cannot be scanned"
		TOOLS_OK=0
	fi
	if ! command -v perl >/dev/null 2>&1; then
		refuse "-" "perl is not on PATH; publish-guard cannot run"
		TOOLS_OK=0
	fi
	if [[ -e "$GIT_DIR_ABS/.gitleaksignore" ]]; then
		refuse "-" "a .gitleaksignore exists in the git directory; remove it (exceptions are not taken from local files)"
		TOOLS_OK=0
	fi
	if [[ ! -f "$GUARD" || ! -x "$GUARD" ]]; then
		refuse "-" "scripts/publish-guard.sh is missing or not executable"
		TOOLS_OK=0
	fi
	[[ "$TOOLS_OK" -eq 1 ]]
}

# run_limited <seconds> <stdin file> <stdout file> <stderr file> <cmd...>
# Runs cmd in the background with the given redirections. At the limit a
# watchdog sends TERM, then KILL 2s later (gitleaks ignores SIGALRM, so an
# alarm is not enough). Returns cmd's status, or 124 when it was cut off.
run_limited() {
	local secs="$1" in="$2" out="$3" err="$4" pid wd rc mark
	shift 4
	mark="$WORK/cut.$$.$RANDOM"
	rm -f "$mark"
	"$@" <"$in" >"$out" 2>"$err" &
	pid=$!
	(
		trap 'kill "$sp" 2>/dev/null; exit 0' TERM
		sleep "$secs" & sp=$!
		wait "$sp"
		: >"$mark"
		kill -TERM "$pid" 2>/dev/null
		sleep 2 & sp=$!
		wait "$sp"
		kill -KILL "$pid" 2>/dev/null
	) &
	wd=$!
	wait "$pid"
	rc=$?
	kill -TERM "$wd" 2>/dev/null
	wait "$wd" 2>/dev/null
	if [[ -e "$mark" ]]; then
		rm -f "$mark"
		return 124
	fi
	return "$rc"
}

blob_of() {
	# blob_of <commit> [path]  -> the blob id of path (default .gitleaks.toml), or "none"
	git rev-parse -q --verify "${1}:${2:-.gitleaks.toml}" 2>/dev/null || echo none
}

# The protected set: the exception list and the gate itself. A pushed commit
# whose copy of any of these differs from the rule commit's is refused —
# changing them needs the operator's decision, not a plain push. (Without
# this, push 1 could change the gate and push 2 would run that new gate.)
PROTECTED=(.gitleaks.toml scripts/pre-push-scan.sh scripts/lib/push-range.sh scripts/publish-guard.sh .githooks/pre-push)

scan_gitleaks() {
	# scan_gitleaks <commit> <config file>; returns 0 clean, 1 refused
	local c="$1" cfg="$2" short="${1:0:12}" rc report log body count added
	report="$WORK/report.json"
	log="$WORK/gitleaks.log"
	rm -f "$report"
	run_limited "$TIMEOUT" /dev/null "$log" "$log.err" gitleaks git \
		--no-banner --no-color --redact --ignore-gitleaks-allow \
		--log-level info --exit-code 0 \
		--config "$cfg" --gitleaks-ignore-path "$WORK/noignore" \
		--report-format json --report-path "$report" \
		--log-opts="-1 -m --first-parent ${DIFF_OPTS[*]} ${c}" \
		"$GIT_DIR_ABS"
	rc=$?
	cat "$log.err" >>"$log" 2>/dev/null
	if [[ "$rc" -eq 124 ]]; then
		refuse "$short" "gitleaks timed out after ${TIMEOUT}s"
		return 1
	fi
	if [[ "$rc" -ne 0 ]]; then
		refuse "$short" "gitleaks exited abnormally (rc=${rc})"
		return 1
	fi
	if [[ ! -s "$report" ]]; then
		refuse "$short" "gitleaks report unreadable (missing or empty)"
		return 1
	fi
	body="$(tr -d ' \t\r\n' <"$report")"
	if [[ "$body" == "[]" ]]; then
		:
	elif [[ "$body" == \[*\] && "$body" == *'"RuleID"'* ]]; then
		refuse "$short" "gitleaks found a secret in this commit"
		return 1
	else
		refuse "$short" "gitleaks report unreadable"
		return 1
	fi
	# The scan must have looked at this commit. A commit with no added text
	# lines (pure deletion, empty, binary-only) legitimately scans 0.
	count="$(sed -n -E 's/^(.*[^0-9])?([0-9]+) commits scanned.*/\2/p' "$log" | tail -1)"
	if [[ -z "$count" ]]; then
		refuse "$short" "gitleaks output unreadable (no scanned-commit count)"
		return 1
	fi
	added="$(git show --numstat --format= -m --first-parent --root "${DIFF_OPTS[@]}" "$c" 2>/dev/null \
		| awk '$1 ~ /^[0-9]+$/ { s += $1 } END { print s + 0 }')"
	if [[ "$count" -gt 1 ]] || { [[ "$added" -gt 0 ]] && [[ "$count" -ne 1 ]]; }; then
		refuse "$short" "gitleaks scanned ${count} commits, expected exactly this one"
		return 1
	fi
	return 0
}

scan_tag() {
	# scan_tag <tag object> <config file>: the tag's own text (header, message,
	# signature) through gitleaks (stdin) and publish-guard (--text).
	local tg="$1" cfg="$2" short="tag ${1:0:12}" body rc report text
	text="$WORK/tag.txt"
	report="$WORK/tag-report.json"
	if ! git cat-file tag "$tg" >"$text" 2>/dev/null; then
		refuse "$short" "cannot read the tag object"
		return 1
	fi
	rm -f "$report"
	# Run from the temp dir so no work-tree .gitleaksignore can apply.
	( cd "$WORK" && run_limited "$TIMEOUT" "$text" "$WORK/tag.log" "$WORK/tag.err" gitleaks stdin \
		--no-banner --no-color --redact --ignore-gitleaks-allow \
		--log-level info --exit-code 0 \
		--config "$cfg" --gitleaks-ignore-path "$WORK/noignore" \
		--report-format json --report-path "$report" )
	rc=$?
	if [[ "$rc" -eq 124 ]]; then
		refuse "$short" "gitleaks timed out after ${TIMEOUT}s on the tag body"
	elif [[ "$rc" -ne 0 ]]; then
		refuse "$short" "gitleaks exited abnormally on the tag body (rc=${rc})"
	elif [[ ! -s "$report" ]]; then
		refuse "$short" "gitleaks report unreadable for the tag body"
	else
		body="$(tr -d ' \t\r\n' <"$report")"
		if [[ "$body" == "[]" ]]; then
			:
		elif [[ "$body" == \[*\] && "$body" == *'"RuleID"'* ]]; then
			refuse "$short" "gitleaks found a secret in the tag body"
		else
			refuse "$short" "gitleaks report unreadable for the tag body"
		fi
	fi
	run_limited "$TIMEOUT" "$text" /dev/null "$WORK/tag-guard.log" "$GUARD" --text
	rc=$?
	case "$rc" in
		0) ;;
		1) refuse "$short" "publish-guard found a forbidden value in the tag body" ;;
		124) refuse "$short" "publish-guard timed out after ${TIMEOUT}s on the tag body" ;;
		*) refuse "$short" "publish-guard failed on the tag body (rc=${rc})" ;;
	esac
	return 0
}

scan_guard() {
	# scan_guard <commit>; returns 0 clean, 1 refused
	local c="$1" short="${1:0:12}" rc diff
	diff="$WORK/commit.diff"
	if ! git show --format= -U0 -m --first-parent --root "${DIFF_OPTS[@]}" "$c" >"$diff" 2>/dev/null; then
		refuse "$short" "cannot produce this commit's diff for publish-guard"
		return 1
	fi
	run_limited "$TIMEOUT" "$diff" /dev/null "$WORK/guard.log" "$GUARD" --diff
	rc=$?
	case "$rc" in
		0) return 0 ;;
		1) refuse "$short" "publish-guard found a forbidden value in this commit" ;;
		124) refuse "$short" "publish-guard timed out after ${TIMEOUT}s" ;;
		*) refuse "$short" "publish-guard failed (rc=${rc})" ;;
	esac
	return 1
}

while read -r lref lsha rref rsha; do
	[[ -z "${lref:-}" ]] && continue
	commits="$(fyd_push_range_commits "$REMOTE_SHAS" "$lsha" "$rsha" 2>"$WORK/range.err")"
	rc=$?
	if [[ "$rc" -eq 10 ]]; then
		continue
	fi
	if [[ "$rc" -ne 0 ]]; then
		refuse "$rref" "$(head -1 "$WORK/range.err")"
		continue
	fi
	# Annotated tags being sent: the tag object itself and every tag it
	# points through (a tag of a tag), down to the commit.
	tags=""
	obj="$lsha"
	while [[ "$(git cat-file -t "$obj" 2>/dev/null)" == tag ]]; do
		tags+="$obj"$'\n'
		obj="$(git cat-file tag "$obj" | sed -n '1s/^object //p')"
	done
	[[ -z "$commits" && -z "$tags" ]] && continue
	check_tools || break

	cfg="$WORK/base-gitleaks.toml"
	if git cat-file -e "${RULES_FROM}:.gitleaks.toml" 2>/dev/null; then
		git cat-file blob "${RULES_FROM}:.gitleaks.toml" >"$cfg"
		:
	else
		printf '[extend]\nuseDefault = true\n' >"$cfg"
		:
	fi

	while read -r c; do
		short="${c:0:12}"
		changed=0
		for f in "${PROTECTED[@]}"; do
			if [[ "$(blob_of "$c" "$f")" != "$(blob_of "$RULES_FROM" "$f")" ]]; then
				refuse "$short" "${f} differs from the base; changing the gate files needs the operator's decision (門のファイルの変更は経営者の判断が要る); exception changes go through a separate gate"
				changed=1
			fi
		done
		[[ "$changed" -eq 1 ]] && continue
		scan_gitleaks "$c" "$cfg"
		scan_guard "$c"
	done < <(printf '%s' "${commits:+$commits$'\n'}")

	while read -r tg; do
		[[ -z "$tg" ]] && continue
		scan_tag "$tg" "$cfg"
	done < <(printf '%s' "$tags")
done

if [[ "$REFUSED" -ne 0 ]]; then
	echo >&2
	echo "Push を中止しました。上の短い hash のコミットを直してから push してください（値は表示していません）。" >&2
	echo "--no-verify での回避は禁止です。.gitleaks.toml の例外の変更は、この門ではなく別の門で扱います。" >&2
	exit 1
fi
exit 0
